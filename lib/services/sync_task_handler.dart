import 'dart:async';

import 'package:danawallet/constants.dart';
import 'package:danawallet/generated/rust/frb_generated.dart';
import 'package:danawallet/generated/rust/api/wallet.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/services/frigate_subscription_controller.dart';
import 'package:danawallet/services/sync_engine.dart';
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
  SyncEngine? _engine;
  FrigateSubscriptionController? _frigateWriter;
  int? _startHeight;
  int? _endHeight;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // First guard against accidental double calls
    if (_engine != null) {
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
    _engine = SyncEngine(
      logTag: 'BG',
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
      onStateUpdated: (lastSyncOnly) async =>
          FlutterForegroundTask.sendDataToMain({bgKeyRefresh: lastSyncOnly}),
    );
    unawaited(_engine!.trySync());

    // B2.1: the frigate subscription lives in this foreground service. The
    // service isolate claims the writer lease (B2.8) and writes sync state
    // directly to the DB (B2.2); it is the SOLE writer while alive (B2.3).
    unawaited(_startFrigateWriter());
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    Logger().i('[BG] heartbeat $timestamp');
    unawaited(_onRepeatEventAsync());
  }

  Future<void> _onRepeatEventAsync() async {
    await _ensureInit();
    unawaited(_engine?.trySync());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    Logger().i('[BG] service destroyed (isTimeout: $isTimeout)');
    // graceful release: the writer lease is cleared so the next writer (a
    // restarted service, or the app after takeover) proceeds immediately
    // (B2.8); an abrupt reclaim leaves it to go stale instead (B2.5).
    await _frigateWriter?.stop();
    _frigateWriter = null;
    if (_engine?.isSyncing == true) {
      SpWallet.interruptSync();
      if (!isTimeout) {
        // Wait for trySync to drain so its onSyncComplete callback sends
        // bgKeyComplete to the main isolate before we cancel the subscription
        // in dispose(). This also prevents a double bgKeyComplete send.
        // Skipped on timeout: the OS is reclaiming the service immediately and
        // IPC delivery is not guaranteed; the main isolate's waitForCompletion
        // timeout will deactivate the progress bar on its own.
        await _engine!.waitForIdle();
      }
    }
    _engine?.dispose();
    _engine = null;
    _startHeight = null;
    _endHeight = null;
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map) {
      if (data[bgKeySync] == true) {
        unawaited(_onReceiveSyncRequest());
      } else if (data[bgKeyInterrupt] == true) {
        Logger().i('[BG] interrupt requested');
        SpWallet.interruptSync();
        // onSyncComplete fires naturally once interruptSync() takes effect,
        // which sends bgKeyComplete to the main isolate and resolves its completer.
      } else {
        Logger().e('[BG] invalid data received: $data');
      }
    } else {
      Logger().e('[BG] invalid data received: $data');
    }
  }

  Future<void> _ensureInit() {
    _initFuture ??= RustLib.init();
    return _initFuture!;
  }

  /// B2.1/B2.2/B2.3: start the frigate subscription in this service isolate
  /// under the service writer identity. No-op when no frigate URL is
  /// configured. If the writer lease is held by a live foreign writer (the
  /// app-isolate fallback writer), retry briefly, then wait for the next
  /// service start (B2.5) rather than ever writing concurrently (B2.3).
  Future<void> _startFrigateWriter() async {
    try {
      final frigateUrl = await SettingsRepository.instance.getFrigateUrl();
      if (frigateUrl == null || frigateUrl.isEmpty) return;

      final controller = FrigateSubscriptionController(
        frigateState: FrigateState(),
        writerLease: WriterLease(writerId: WriterLease.serviceWriterId),
        // graduation moved satoshis into owned_outputs — the app refreshes
        // the confirmed balance from the repository.
        onGraduated: () =>
            FlutterForegroundTask.sendDataToMain({bgKeyRefresh: true}),
        // every processed event may have changed the candidate registry —
        // the app re-reads it from the DB (B2.2).
        onEventProcessed: () =>
            FlutterForegroundTask.sendDataToMain({bgKeyFrigateRefresh: true}),
      );
      _frigateWriter = controller;

      for (var attempt = 0; attempt < 12; attempt++) {
        if (await controller.start()) {
          Logger().i('[BG] frigate subscription started in the foreground '
              'service (B2.1) — sole sync-state writer (B2.3)');
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 5));
      }
      Logger().w('[BG] frigate writer lease still held after 60 s — '
          'subscription not started in the service (B2.3 read-only)');
    } catch (e) {
      Logger().e('[BG] frigate service writer failed to start: $e');
    }
  }

  Future<void> _onReceiveSyncRequest() async {
    if (_engine?.isSyncing == true &&
        _startHeight != null &&
        _endHeight != null) {
      Logger().i('[BG] sync already running, re-sending progress state');
      FlutterForegroundTask.sendDataToMain({
        bgKeyStartHeight: _startHeight,
        bgKeyEndHeight: _endHeight,
      });
    } else {
      Logger().i('[BG] sync triggered by main isolate');
      await _ensureInit();
      unawaited(_engine?.trySync());
    }
  }
}
