import 'dart:async';

import 'package:danawallet/repositories/writer_lease_repository.dart';
import 'package:logger/logger.dart';

/// Thrown from the sync-state write path (B2.8) when another writer holds a
/// fresh lease: the caller must stand down immediately. Concurrent writers
/// of the same table are a spec violation (B2.3) — this exception is the
/// structural guard, not a suggestion.
class WriterLeaseLostException implements Exception {
  final String holder;

  WriterLeaseLostException(this.holder);

  @override
  String toString() => 'WriterLeaseLostException: lease held by $holder';
}

/// The single-writer handoff probe and guard (B2.3 / B2.8).
///
/// One lease row (writer identity + last-heartbeat timestamp) in the wallet
/// state store. The live writer — the foreground service, or the app after
/// takeover — renews it every [heartbeatPeriod] (5 s). A process may take
/// over writing only after it observes the lease stale for >= [staleAfter]
/// (10 s — two missed heartbeats); that staleness observation IS the
/// confirmation that the previous writer (the foreground service) is down
/// (B2.8). A best-effort bind probe to the service may be used as a fast
/// path but never replaces the staleness check.
///
/// [ensureOwnership] sits inside the sync-state write path, so concurrent
/// writers are structurally prevented, not merely discouraged.
class WriterLease {
  /// The live writer renews the lease at this cadence (B2.8).
  static const Duration heartbeatPeriod = Duration(seconds: 5);

  /// A lease older than this is stale — two missed heartbeats; observing it
  /// IS the confirmation that the previous writer is down (B2.8).
  static const Duration staleAfter = Duration(seconds: 10);

  /// Writer identity of the foreground-service isolate (B2.1).
  static const String serviceWriterId = 'foreground-service';

  /// Writer identity of the app isolate (in-process fallback / takeover).
  static const String appWriterId = 'app';

  final WriterLeaseRepository _repo;

  /// Identity this process writes under.
  final String writerId;

  /// test seam: deterministic clock.
  final int Function()? nowMillis;

  Timer? _heartbeat;
  bool _ownsLease = false;

  WriterLease({
    WriterLeaseRepository? repository,
    this.writerId = appWriterId,
    this.nowMillis,
  }) : _repo = repository ?? WriterLeaseRepository.instance;

  int _now() => nowMillis?.call() ?? DateTime.now().millisecondsSinceEpoch;

  bool get ownsLease => _ownsLease;

  /// Try to become the writer. Succeeds — and takes over — when there is no
  /// lease, we already hold it, or the foreign lease is stale for >=
  /// [staleAfter] (the staleness observation confirms the previous writer is
  /// down, B2.8). Fails when another writer is live; the caller stays
  /// read-only (B2.2/B2.3).
  Future<bool> tryAcquire() async {
    final row = await _repo.read();
    final now = _now();
    if (row != null &&
        row.writerId != writerId &&
        now - row.heartbeatMs < staleAfter.inMilliseconds) {
      Logger().i('writer lease: $writerId stays read-only, live writer '
          '${row.writerId} holds the lease (B2.3)');
      return false;
    }
    if (row != null && row.writerId != writerId) {
      Logger().i('writer lease: $writerId takes over, lease of ${row.writerId} '
          'stale for ${now - row.heartbeatMs} ms (B2.8)');
    }
    await _repo.write(writerId, now);
    _ownsLease = true;
    _startHeartbeat();
    return true;
  }

  /// Renew the heartbeat. Only the holder may renew: a fresh foreign row is
  /// left untouched and the local writer stands down (returns false).
  Future<bool> renew() async {
    final row = await _repo.read();
    if (row != null && row.writerId != writerId) {
      _ownsLease = false;
      _stopHeartbeat();
      return false;
    }
    await _repo.write(writerId, _now());
    return true;
  }

  /// The structural check inside the sync-state write path (B2.8): renew our
  /// lease, or throw [WriterLeaseLostException] when a foreign writer holds
  /// a fresh lease.
  Future<void> ensureOwnership() async {
    if (!await renew()) {
      final row = await _repo.read();
      throw WriterLeaseLostException(row?.writerId ?? '<released>');
    }
  }

  /// Release the lease on graceful stop so the next writer can take over
  /// without waiting for staleness (B2.5 semantics for planned restarts).
  Future<void> release() async {
    _stopHeartbeat();
    if (!_ownsLease) return;
    final row = await _repo.read();
    if (row == null || row.writerId == writerId) {
      await _repo.clear();
    }
    _ownsLease = false;
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeat = Timer.periodic(heartbeatPeriod, (_) {
      unawaited(renew().catchError((Object e) {
        Logger().w('writer lease: heartbeat renewal failed: $e');
        return false;
      }));
    });
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }
}

/// App-side takeover probe (B2.3): on Android the subscription lives in the
/// foreground service (B2.1), so the app gives the service isolate a head
/// start to claim the writer lease before considering an in-process
/// takeover. Returns true as soon as a fresh service-writer lease is
/// observed (the app must stay read-only, B2.2), or false once [timeout]
/// elapsed without a fresh claim (the service is confirmed down — stale or
/// absent lease — and the app may take over writing, B2.8).
Future<bool> waitForServiceWriterClaim({
  Duration timeout = const Duration(seconds: 15),
  Duration pollPeriod = const Duration(seconds: 1),
  int Function()? nowMillis,
  WriterLeaseRepository? repository,
}) async {
  final repo = repository ?? WriterLeaseRepository.instance;

  int tick() => nowMillis?.call() ?? DateTime.now().millisecondsSinceEpoch;
  final deadline = tick() + timeout.inMilliseconds;

  while (tick() < deadline) {
    final row = await repo.read();
    if (row != null &&
        row.writerId == WriterLease.serviceWriterId &&
        tick() - row.heartbeatMs < WriterLease.staleAfter.inMilliseconds) {
      return true;
    }
    await Future<void>.delayed(pollPeriod);
  }
  return false;
}
