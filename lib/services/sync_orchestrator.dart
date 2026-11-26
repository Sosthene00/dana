import 'dart:async';
import 'dart:io';

import 'package:danawallet/services/sync_service.dart';
import 'package:danawallet/states/chain_state.dart';
import 'package:danawallet/states/frigate_state.dart';
import 'package:danawallet/states/permission_state.dart';
import 'package:danawallet/states/sync_progress_state.dart';
import 'package:danawallet/states/wallet_state.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

class SyncOrchestrator {
  final SyncService _service;
  final PermissionState _permissionState;

  bool _running = false;
  bool _permissionRestartInFlight = false;

  /// Test seam: forces the Android foreground-service path off-device so
  /// unit tests can drive the wallet-start service lifecycle (B2.1) on the
  /// host. Never set outside tests.
  @visibleForTesting
  static bool debugIsAndroidOverride = false;

  bool get isRunning => _running;

  SyncOrchestrator({
    required ChainState chainState,
    required FrigateState frigateState,
    required PermissionState permissionState,
    required SyncProgressState syncProgress,
    required WalletState walletState,
  })  : _service = SyncService(
          chainState: chainState,
          frigateState: frigateState,
          syncProgress: syncProgress,
          walletState: walletState,
        ),
        _permissionState = permissionState {
    _permissionState.addListener(_onPermissionStateChanged);
    _service.onFatalError = () => restart(forceInProcess: true);
  }

  Future<void> start({bool forceInProcess = false}) async {
    if (_running) return;

    bool tryForegroundTask = (debugIsAndroidOverride || Platform.isAndroid) &&
        _permissionState.notificationGranted &&
        !forceInProcess;

    if (tryForegroundTask) {
      final success = await _service.startForeground();
      if (success) {
        Logger().i("Successfully started foreground sync service");
      } else {
        Logger().w("Starting in-process service as a fallback");
        await _service.startInProcess();
      }
    } else {
      // for non-android platforms, we always start the sync service in-process
      await _service.startInProcess();
      Logger().i("Successfully started in-process sync service");
    }
    _running = true;
  }

  /// Settings saved a backend. The host that holds the writer lease swaps
  /// scanners; this isolate does not start a second one.
  Future<void> applyBackend() => _service.applyBackend();

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _service.stop();
  }

  Future<void> restart({bool forceInProcess = false}) async {
    await stop();

    await start(forceInProcess: forceInProcess);
  }

  void _onPermissionStateChanged() {
    if (!_running || _permissionRestartInFlight) return;
    _permissionRestartInFlight = true;
    unawaited(() async {
      try {
        await restart();
      } finally {
        _permissionRestartInFlight = false;
      }
    }());
  }
}
