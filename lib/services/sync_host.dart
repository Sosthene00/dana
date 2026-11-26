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
      await _engine.waitForIdle();
    }
    _engine.dispose();
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

/// One writer, one scanner.
///
/// Acquires [lease] before it reads the committed backend, then starts that
/// scanner only. [applyBackend] stops the occupant and starts the other
/// without releasing the lease. [stop] is the only path that releases it.
class SyncHost {
  SyncHost({
    required this.lease,
    required this.buildScanner,
  });

  final WriterLease lease;
  final SyncScanner Function(ChainBackendKind kind, WriterLease lease)
      buildScanner;

  SyncScanner? _scanner;
  bool _running = false;

  SyncScanner? get scanner => _scanner;
  bool get isRunning => _running;

  /// Become the writer and start the committed scanner. Returns false when
  /// a live foreign writer holds the lease — this isolate stays read-only
  /// and starts nothing.
  Future<bool> start() async {
    if (_running) return true;
    if (!await lease.tryAcquire()) return false;
    _running = true;
    await _occupy();
    return true;
  }

  /// Stop the occupant, re-read the committed backend, start that scanner.
  /// The lease stays held across the swap.
  Future<void> applyBackend() async {
    if (!_running) return;
    await _scanner?.stop();
    _scanner = null;
    await _occupy();
  }

  Future<void> wake() async {
    if (!_running) return;
    await _scanner?.wake();
  }

  /// Stop the occupant and release the lease. [drain] false skips waiting
  /// out an in-flight Blindbit scan (service timeout reclaim).
  Future<void> stop({bool drain = true}) async {
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
}
