import 'dart:async';

import 'package:danawallet/generated/rust/api/wallet.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/services/frigate_subscription_controller.dart';
import 'package:danawallet/services/sync_engine.dart';
import 'package:danawallet/services/writer_lease.dart';
import 'package:logger/logger.dart';

/// The one scan slot the sync host runs.
///
/// [start] brings the scanner up. [wake] is a height-range scan for Blindbit
/// and an ensure-subscription for Frigate (B1.3) — it does not grow a scan
/// range. [stop] ends the scanner and does not release the writer lease.
abstract class SyncScanner {
  ChainBackendKind get kind;

  Future<void> start();

  Future<void> stop({bool drain = true});

  Future<void> wake();
}

/// Blindbit wake-cycle scan. [start] kicks one scan and returns; the host
/// awaits [stop], which interrupts an in-flight scan, before it starts
/// another scanner.
class BlindbitScanner implements SyncScanner {
  BlindbitScanner(this._engine);

  final SyncEngine _engine;

  @override
  ChainBackendKind get kind => ChainBackendKind.blindbit;

  bool get isSyncing => _engine.isSyncing;

  @override
  Future<void> start() {
    unawaited(wake());
    return Future.value();
  }

  @override
  Future<void> wake() async {
    try {
      await _engine.trySync();
    } on WriterLeaseLostException catch (e) {
      Logger().e('blindbit scan aborted, writer lease lost: $e');
    }
  }

  @override
  Future<void> stop({bool drain = true}) async {
    _engine.closeIncoming();
    if (drain && _engine.isSyncing) {
      SpWallet.interruptSync();
      try {
        // M-a: waitForIdle THROWS on timeout — the drain FAILED (Rust has
        // not honoured interruptSync, the scan may still be writing).
        // Dispose here so no further scan events are written, but let the
        // failure propagate: the host must never start another writer over
        // an undrained scan.
        await _engine.waitForIdle();
      } finally {
        _engine.dispose();
      }
    } else {
      _engine.dispose();
    }
  }
}

/// Held frigate subscription. [wake] re-subscribes only when the
/// subscription is down (B1.3).
class FrigateScanner implements SyncScanner {
  FrigateScanner(this._controller);

  final FrigateSubscriptionController _controller;

  @override
  ChainBackendKind get kind => ChainBackendKind.frigate;

  bool get isRunning => _controller.isRunning;

  @override
  Future<void> start() async {
    await _controller.start();
  }

  @override
  Future<void> wake() async {
    if (_controller.isRunning) return;
    await _controller.start();
  }

  @override
  Future<void> stop({bool drain = true}) => _controller.stopSubscription();
}

/// Thrown when a scanner drain does not finish within the host's bounded
/// timeout (M-a): the in-flight scan may still be writing, so the swap
/// FAILED — the host did not start another scanner, the slot is left empty
/// and the lease stays held.
class SyncDrainTimeoutException extends TimeoutException {
  SyncDrainTimeoutException({String? message, Duration? duration})
      : super(message, duration);
}

/// Lease-acquisition retry policy (review blocker B1: one-shot acquisition
/// left a live service scannerless forever).
///
/// [SyncHost] with a policy retries `tryAcquire` with exponential backoff
/// (`initialDelay`, grown by `backoffMultiplier`, capped at `maxDelay`)
/// until it succeeds or `maxAttempts` is exhausted (`null` = retry while
/// the host runs — a live service never gives up its one slot). Without a
/// policy the host attempts exactly once (the app isolate keeps its
/// one-shot semantics; its handoff to the service is the stand-down watch).
class LeaseAcquirePolicy {
  const LeaseAcquirePolicy({
    this.maxAttempts,
    this.initialDelay = const Duration(seconds: 5),
    this.backoffMultiplier = 2,
    this.maxDelay = const Duration(seconds: 30),
  });

  /// Total acquisition attempts; `null` = unbounded.
  final int? maxAttempts;

  /// Delay before the second attempt (the first is immediate).
  final Duration initialDelay;

  final double backoffMultiplier;

  final Duration maxDelay;
}

/// One writer, one scanner.
///
/// Acquires [lease] before it reads the committed backend, then starts that
/// scanner only. [applyBackend] stops the occupant and starts the other
/// without releasing the lease. [stop] is the only path that releases it.
class SyncHost {
  SyncHost({
    required this.lease,
    required this.buildScanner,
    this.acquirePolicy,
    this.onAcquireBlocked,
    this.standDownProbe,
    this.onStandDown,
    this.standDownInterval = const Duration(seconds: 5),
    this.drainTimeout = const Duration(seconds: 10),
  });

  final WriterLease lease;
  final SyncScanner Function(ChainBackendKind kind, WriterLease lease)
      buildScanner;

  /// Retry policy for lease acquisition (service host). `null` = one-shot.
  final LeaseAcquirePolicy? acquirePolicy;

  /// Called after every blocked acquisition attempt (with the attempt
  /// number, 1-based). The service host uses this to mark its liveness so
  /// the app host can stand down.
  final Future<void> Function(int attempt)? onAcquireBlocked;

  /// App-host stand-down probe (B2.3 handoff): when it returns true the
  /// host stops its scanner and releases the lease so the service writer
  /// can take over. `null` disables the watch (service host never stands
  /// down to the app).
  final Future<bool> Function()? standDownProbe;

  /// Called after a stand-down completed (scanner stopped, lease released).
  final void Function()? onStandDown;

  /// How often the stand-down probe runs while the host holds the lease.
  final Duration standDownInterval;

  /// Bounded wait for the occupant's drain during a backend swap (M-a). A
  /// drain outlasting this fails the swap.
  final Duration drainTimeout;

  SyncScanner? _scanner;
  bool _running = false;
  bool _stoodDown = false;
  bool _abortAcquire = false;
  Timer? _standDownTimer;

  SyncScanner? get scanner => _scanner;
  bool get isRunning => _running;

  /// True when this host observed the service writer's claim and stepped
  /// down (stopped the scanner, released the lease).
  bool get stoodDown => _stoodDown;

  /// Become the writer and start the committed scanner. Returns false when
  /// a live foreign writer holds the lease and no retry policy is configured
  /// (or the retry budget is exhausted) — this isolate stays read-only and
  /// starts nothing.
  Future<bool> start() async {
    if (_running) return true;
    if (!await _acquireLease()) return false;
    _running = true;
    _startStandDownWatch();
    await _occupy();
    return true;
  }

  /// Acquire the lease, retrying per [acquirePolicy] while blocked.
  Future<bool> _acquireLease() async {
    final policy = acquirePolicy;
    var delay = policy?.initialDelay ?? Duration.zero;
    var attempt = 0;
    while (true) {
      if (_abortAcquire) return false;
      if (await lease.tryAcquire()) return true;
      attempt++;
      await onAcquireBlocked?.call(attempt);
      if (policy == null) return false;
      if (policy.maxAttempts != null && attempt >= policy.maxAttempts!) {
        return false;
      }
      await Future<void>.delayed(delay);
      delay = Duration(
          milliseconds:
              (delay.inMilliseconds * policy.backoffMultiplier).round());
      if (delay > policy.maxDelay) delay = policy.maxDelay;
    }
  }

  /// Stop the occupant, re-read the committed backend, start that scanner.
  /// The lease stays held across the swap.
  ///
  /// M-a: a drain that does not finish within [drainTimeout] is a FAILED
  /// swap, not a proceed — the in-flight scan may still be writing (Rust
  /// has not honoured interruptSync). The host does NOT start the other
  /// scanner; the slot is left EMPTY (empty-slot policy: no scanner runs,
  /// the host keeps the lease, this isolate stays read-only until a later
  /// [start]/[applyBackend] succeeds) and [SyncDrainTimeoutException] is
  /// thrown to the caller.
  Future<void> applyBackend() async {
    if (!_running) return;
    final old = _scanner;
    _scanner = null;
    try {
      await old?.stop().timeout(drainTimeout);
    } on TimeoutException {
      throw SyncDrainTimeoutException(
          message: 'scanner drain timed out — swap failed, slot left empty '
              '(M-a two-writer hole)',
          duration: drainTimeout);
    }
    await _occupy();
  }

  Future<void> wake() async {
    if (!_running) return;
    await _scanner?.wake();
  }

  /// Stop the occupant and release the lease. [drain] false skips waiting
  /// out an in-flight Blindbit scan (service timeout reclaim).
  Future<void> stop({bool drain = true}) async {
    _abortAcquire = true;
    _standDownTimer?.cancel();
    _standDownTimer = null;
    await _scanner?.stop(drain: drain);
    _scanner = null;
    _running = false;
    await lease.release();
  }

  Future<void> _occupy() async {
    final kind = await SettingsRepository.instance.getChainBackend();
    final scanner = buildScanner(kind, lease);
    _scanner = scanner;
    try {
      await scanner.start();
    } catch (e, st) {
      Logger().e('sync host: $kind scanner failed to start: $e\n$st');
    }
  }

  /// Watch for the service writer's claim while we hold the lease (app-host
  /// stand-down, B2.3 handoff). The probe is checked once immediately (a
  /// service may have claimed before we started) and then every
  /// [standDownInterval].
  void _startStandDownWatch() {
    if (standDownProbe == null) return;
    _stoodDown = false;
    _standDownTimer =
        Timer.periodic(standDownInterval, (_) => unawaited(_checkStandDown()));
    unawaited(_checkStandDown());
  }

  Future<void> _checkStandDown() async {
    final probe = standDownProbe;
    if (!_running || _stoodDown || probe == null) return;
    if (!await probe()) return;
    _stoodDown = true;
    _standDownTimer?.cancel();
    _standDownTimer = null;
    Logger().i('sync host: service writer claim observed — standing down, '
        'releasing the lease (B2.3)');
    await stop();
    onStandDown?.call();
  }
}
