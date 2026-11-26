import 'dart:async';

import 'package:danawallet/constants.dart';
import 'package:danawallet/generated/rust/frb_generated.dart';
import 'package:danawallet/generated/rust/api/wallet.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/services/frigate_subscription_controller.dart';
import 'package:danawallet/services/sync_engine.dart';
import 'package:danawallet/services/sync_host.dart';
import 'package:danawallet/services/writer_lease.dart';
import 'package:danawallet/states/frigate_state.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logger/logger.dart';

final ForegroundTaskOptions synchronizationTaskOptions = ForegroundTaskOptions(
  eventAction:
      ForegroundTaskEventAction.repeat(const Duration(hours: 1).inMilliseconds),
  autoRunOnBoot: false,
  autoRunOnMyPackageReplaced: false,
  allowWakeLock: false,
  allowWifiLock: false,
);

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(SynchronizationTaskHandler());
}

class SynchronizationTaskHandler extends TaskHandler {
  Future<void>? _initFuture;
  SyncHost? _host;
  int? _startHeight;
  int? _endHeight;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    if (_host != null) {
      Logger().e('[BG] service already started, skipping');
      return;
    }

    Logger().i('[BG] service started (starter: ${starter.name})');
    try {
      await _ensureInit();
    } catch (e) {
      Logger()
          .e('[BG] Rust library failed to initialize — stopping service: $e');
      FlutterForegroundTask.sendDataToMain({bgKeyFatalError: true});
      await FlutterForegroundTask.stopService();
      return;
    }

    _host = SyncHost(
      lease: WriterLease(writerId: WriterLease.serviceWriterId),
      buildScanner: _buildScanner,
    );
    final acquired = await _host!.start();
    if (!acquired) {
      Logger().w('[BG] writer lease held by a live writer — service starts '
          'no scanner (B2.3)');
    }
  }

  SyncScanner _buildScanner(ChainBackendKind kind, WriterLease lease) {
    switch (kind) {
      case ChainBackendKind.blindbit:
        return BlindbitScanner(SyncEngine(
          logTag: 'BG',
          writerLease: lease,
          onSyncStarted: (start, end) {
            _startHeight = start;
            _endHeight = end;
            FlutterForegroundTask.sendDataToMain({
              bgKeyStartHeight: start,
              bgKeyEndHeight: end,
            });
          },
          onSyncComplete: (ok) {
            _startHeight = null;
            _endHeight = null;
            FlutterForegroundTask.sendDataToMain({bgKeyComplete: ok});
          },
          onStateUpdated: (refreshKind) async =>
              FlutterForegroundTask.sendDataToMain(
                  {bgKeyRefresh: refreshKind.wireName}),
        ));
      case ChainBackendKind.frigate:
        final serviceFrigateState = FrigateState();
        return FrigateScanner(FrigateSubscriptionController(
          frigateState: serviceFrigateState,
          writerLease: lease,
          onGraduated: () => FlutterForegroundTask.sendDataToMain(
              {bgKeyRefresh: RefreshKind.full.wireName}),
          onEventProcessed: () => FlutterForegroundTask.sendDataToMain(
              {bgKeyFrigateRefresh: true, ...serviceFrigateState.snapshot()}),
        ));
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    Logger().i('[BG] heartbeat $timestamp');
    unawaited(_onRepeatEventAsync());
  }

  Future<void> _onRepeatEventAsync() async {
    await _ensureInit();
    await _onWake();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    Logger().i('[BG] service destroyed (isTimeout: $isTimeout)');
    // Graceful release: the writer lease is cleared so the next writer
    // proceeds immediately (B2.8). An abrupt reclaim skips the drain and
    // leaves the lease to go stale (B2.5).
    await _host?.stop(drain: !isTimeout);
    _host = null;
    _startHeight = null;
    _endHeight = null;
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map) {
      if (data[bgKeySync] == true) {
        unawaited(_onWake());
      } else if (data[bgKeyInterrupt] == true) {
        Logger().i('[BG] interrupt requested');
        SpWallet.interruptSync();
      } else if (data[bgKeyApplyBackend] == true) {
        Logger().i('[BG] apply backend requested by the main isolate');
        unawaited(_applyBackend());
      } else {
        Logger().e('[BG] invalid data received: $data');
      }
    } else {
      Logger().e('[BG] invalid data received: $data');
    }
  }

  Future<void> _applyBackend() async {
    await _ensureInit();
    _startHeight = null;
    _endHeight = null;
    await _host?.applyBackend();
  }

  Future<void> _ensureInit() {
    if (RustLib.instance.initialized) {
      return Future.value();
    }
    _initFuture ??= RustLib.init();
    return _initFuture!;
  }

  Future<void> _onWake() async {
    final scanner = _host?.scanner;
    if (scanner is BlindbitScanner &&
        scanner.isSyncing &&
        _startHeight != null &&
        _endHeight != null) {
      Logger().i('[BG] sync already running, re-sending progress state');
      FlutterForegroundTask.sendDataToMain({
        bgKeyStartHeight: _startHeight,
        bgKeyEndHeight: _endHeight,
      });
      return;
    }
    Logger().i('[BG] sync triggered by main isolate');
    await _ensureInit();
    await _host?.wake();
  }
}
