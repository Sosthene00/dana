import 'dart:async';
import 'dart:io';

import 'package:danawallet/constants.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/services/backend_apply_result.dart';
import 'package:danawallet/services/foreground_sync_service.dart';
import 'package:danawallet/services/frigate_subscription_controller.dart';
import 'package:danawallet/services/service_liveness.dart';
import 'package:danawallet/services/sync_engine.dart';
import 'package:danawallet/services/sync_host.dart';
import 'package:danawallet/services/writer_lease.dart';
import 'package:danawallet/states/chain_state.dart';
import 'package:danawallet/states/frigate_state.dart';
import 'package:danawallet/states/sync_progress_state.dart';
import 'package:danawallet/states/wallet_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logger/logger.dart';

class SyncService {
  final ChainState _chainState;
  final SyncProgressState _syncProgress;
  final WalletState _walletState;
  final FrigateState _frigateState;

  /// Called when the background isolate sends [bgKeyFatalError]. The backend
  /// has already committed to the foreground-service path by the time this
  /// fires, so the caller must trigger a restart to recover into fallback mode.
  late Future<void> Function() onFatalError;

  bool _callbacksRegistered = false;
  bool _foregroundHost = false;

  SyncHost? _appHost;

  /// Test seam: treat this isolate as Android for the service-lease probe.
  @visibleForTesting
  bool? debugIsAndroid;

  /// Test seam: replaces [waitForServiceWriterClaim].
  @visibleForTesting
  Future<bool> Function()? debugServiceClaimProbe;

  /// Test seam: replaces the real scanners the in-process host would build.
  @visibleForTesting
  SyncScanner Function(ChainBackendKind kind, WriterLease lease)?
      debugBuildScanner;

  /// Test seam: replaces the app-host stand-down probe (the service-claim
  /// liveness watch).
  @visibleForTesting
  Future<bool> Function()? debugStandDownProbe;

  /// Test seam: whether the in-process host currently holds the writer
  /// lease (a stand-down releases it).
  @visibleForTesting
  bool get debugAppHostRunning => _appHost?.isRunning ?? false;

  SyncService({
    required ChainState chainState,
    required SyncProgressState syncProgress,
    required WalletState walletState,
    required FrigateState frigateState,
    this.debugIsAndroid,
    this.debugServiceClaimProbe,
    this.debugBuildScanner,
    this.debugStandDownProbe,
  })  : _chainState = chainState,
        _syncProgress = syncProgress,
        _walletState = walletState,
        _frigateState = frigateState;

  Future<bool> startForeground() async {
    if (!_callbacksRegistered) {
      FlutterForegroundTask.addTaskDataCallback(_onServiceData);
      _callbacksRegistered = true;
    }

    final serviceStart = await ForegroundSyncService.start();

    if (serviceStart != ForegroundServiceStart.failed) {
      _foregroundHost = true;
      await _alignWakePoller();
      return true;
    }

    Logger().w('Foreground service unavailable');
    return false;
  }

  /// In-process host. On Android, a fresh service writer lease means the
  /// service is the host and this isolate starts no scanner.
  ///
  /// [serviceKnownUnavailable] (M-b): true when app-host startup already
  /// knows the foreground service is unavailable — the service-start result
  /// reported failure, or the notification permission is denied so no
  /// service was ever started. There is nothing to race then, so instead of
  /// awaiting the bounded [waitForServiceWriterClaim] window the gate does
  /// a single immediate lease check and the committed scanner starts right
  /// away; the stand-down probe below remains the safety net if a service
  /// appears later.
  Future<void> startInProcess({bool serviceKnownUnavailable = false}) async {
    final android = debugIsAndroid ?? Platform.isAndroid;
    if (android) {
      final claimed = debugServiceClaimProbe != null
          ? await debugServiceClaimProbe!()
          : serviceKnownUnavailable
              ? await serviceWriterClaimIsFresh()
              : await waitForServiceWriterClaim();
      if (claimed) {
        Logger().i('sync host: foreground service holds the writer lease — '
            'app starts no scanner');
        _foregroundHost = true;
        await _alignWakePoller();
        return;
      }
    }

    _appHost = SyncHost(
      lease: WriterLease(writerId: WriterLease.appWriterId),
      buildScanner: debugBuildScanner ?? _buildAppScanner,
      // App-host stand-down (review blocker B1): while we hold the lease,
      // watch for the service writer's claim. The service is the sole
      // writer while alive (B2.3) — when it claims, stop our scanner and
      // release the lease so its acquisition retry succeeds.
      standDownProbe:
          android ? (debugStandDownProbe ?? _serviceWriterClaimed) : null,
      onStandDown: () {
        _foregroundHost = true;
        _appHost = null;
      },
    );
    final acquired = await _appHost!.start();
    if (!acquired) {
      Logger().w('in-process sync host did not acquire the writer lease');
    }
    await _alignWakePoller();
  }

  /// The foreground-service isolate announced itself while we hold the
  /// writer lease (review blocker B1): the service is live and waiting for
  /// its slot.
  Future<bool> _serviceWriterClaimed() => ServiceLiveness.isFresh();

  /// Stop the occupant and start the scanner for the committed backend.
  /// The in-process host does this directly. Otherwise the request goes to
  /// the foreground service, which holds the lease. The result is typed
  /// (M-c): a not-delivered outcome names its reason so callers surface
  /// the divergence instead of discarding a bool.
  Future<BackendApplyResult> applyBackend() async {
    final kind = await SettingsRepository.instance.getChainBackend();
    if (kind != ChainBackendKind.blindbit) {
      _chainState.stopChainPoller();
    }
    BackendApplyResult result;
    if (_appHost?.isRunning == true) {
      try {
        await _appHost!.applyBackend();
        result = BackendApplyResult.delivered;
      } catch (e, st) {
        Logger().w('in-process applyBackend failed: $e\n$st');
        result = BackendApplyResult.hostError;
      }
    } else {
      // M-c: the service path is best-effort — a dying or not-yet-started
      // service silently drops the request. Surface that instead of
      // discarding it.
      result = await ForegroundSyncService.requestApplyBackend();
    }
    await _alignWakePoller();
    return result;
  }

  SyncScanner _buildAppScanner(ChainBackendKind kind, WriterLease lease) {
    switch (kind) {
      case ChainBackendKind.blindbit:
        return BlindbitScanner(SyncEngine(
          logTag: 'in-process',
          writerLease: lease,
          onSyncStarted: (start, end) => _syncProgress.activate(start, end),
          onSyncComplete: (success) => _syncProgress.deactivate(success),
          onStateUpdated: (refreshKind) => _walletState.refreshAfterSync(
              lastSyncOnly: refreshKind == RefreshKind.lastSyncOnly),
        ));
      case ChainBackendKind.frigate:
        return FrigateScanner(FrigateSubscriptionController(
          frigateState: _frigateState,
          writerLease: lease,
          onGraduated: () {
            unawaited(_walletState.refreshAfterSync());
          },
        ));
    }
  }

  /// The Blindbit tip poller is that scanner's wake. It does not run while
  /// Frigate occupies the slot, and a tick does not wake Frigate.
  Future<void> _alignWakePoller() async {
    final kind = await SettingsRepository.instance.getChainBackend();
    _chainState.setScanBackend(kind);
    if (kind != ChainBackendKind.blindbit) {
      _chainState.stopChainPoller();
      return;
    }
    if (!_chainState.initiated) return;
    _chainState.startChainPoller(
      true,
      onTipUpdated: _wakeActiveScanner,
      shouldSkipTick: () => _syncProgress.isSyncing,
    );
  }

  Future<void> _wakeActiveScanner() async {
    if (_appHost?.isRunning == true) {
      await _appHost!.wake();
      return;
    }
    if (_foregroundHost) {
      FlutterForegroundTask.sendDataToTask({bgKeySync: true});
    }
  }

  /// test seam: deliver a data message exactly as the foreground-task plugin
  /// would from the background isolate (direct mirror of _onServiceData).
  /// Unit tests use this to pin the isolate-boundary refresh contract
  /// without spinning up the foreground service.
  @visibleForTesting
  void handleServiceData(Object data) => _onServiceData(data);

  void _onServiceData(Object data) {
    if (data is! Map) return;

    if (data[bgKeyFatalError] == true) {
      Logger().e('Background isolate reported a fatal error');
      unawaited(onFatalError());
    }

    // sync progress update
    if (data.containsKey(bgKeyStartHeight) &&
        data.containsKey(bgKeyEndHeight)) {
      int startHeight = (data[bgKeyStartHeight] as num).toInt();
      int endHeight = (data[bgKeyEndHeight] as num).toInt();
      _syncProgress.activate(startHeight, endHeight);
    } else if (data.containsKey(bgKeyComplete)) {
      bool success = data[bgKeyComplete] as bool;
      _syncProgress.deactivate(success);
    }

    // walletState update
    if (data.containsKey(bgKeyRefresh)) {
      final kind = RefreshKind.tryFromWire(data[bgKeyRefresh]);
      if (kind == null) {
        Logger().e('invalid bgKeyRefresh payload: ${data[bgKeyRefresh]}');
      } else {
        switch (kind) {
          case RefreshKind.full:
            unawaited(_walletState.refreshAfterSync(lastSyncOnly: false));
          case RefreshKind.lastSyncOnly:
            unawaited(_walletState.refreshAfterSync(lastSyncOnly: true));
        }
      }
    }
  }

  Future<void> stop() async {
    _chainState.stopChainPoller();
    if (_appHost != null) {
      await _appHost!.stop();
      _appHost = null;
    } else if (_foregroundHost) {
      FlutterForegroundTask.sendDataToTask({bgKeyInterrupt: true});
      await _syncProgress.waitForCompletion();
      await ForegroundSyncService.stop();
      _foregroundHost = false;
    }
  }
}
