import 'dart:io';

import 'package:danawallet/constants.dart';
import 'package:danawallet/services/sync_task_handler.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logger/logger.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Outcome of a wallet start request against the platform foreground
/// service (B2.1): a live service is re-attached, never started twice.
enum ForegroundServiceStart { started, attached, failed }

/// Seam between the wallet and the platform foreground-service plugin.
/// The default adapter talks to flutter_foreground_task; unit tests
/// inject a counting fake via [ForegroundSyncService.serviceAdapter]
/// (see test/services/foreground_service_lifecycle_test.dart).
abstract interface class ForegroundServiceAdapter {
  /// Whether the foreground service is currently running.
  Future<bool> isRunning();

  /// Starts the service with the wallet's sync notification.
  /// Returns true when the service ends up running.
  Future<bool> startService();

  /// Stops the service. Only called after a live [isRunning] probe.
  Future<void> stopService();
}

class _PluginForegroundServiceAdapter implements ForegroundServiceAdapter {
  const _PluginForegroundServiceAdapter();

  @override
  Future<bool> isRunning() => FlutterForegroundTask.isRunningService;

  @override
  Future<bool> startService() async {
    final appInfo = await PackageInfo.fromPlatform();

    final result = await FlutterForegroundTask.startService(
      serviceId: 1000,
      notificationTitle: appInfo.appName,
      notificationText: ForegroundSyncService._foregroundNotificationText,
      callback: startCallback,
    );

    if (result is ServiceRequestFailure) {
      Logger().w(
        'Failed to start Android foreground service: ${result.error}',
      );
    }

    return result is ServiceRequestSuccess;
  }

  @override
  Future<void> stopService() => FlutterForegroundTask.stopService();
}

class ForegroundSyncService {
  static const String _notificationChannelId = 'dana_sync';
  static const String _notificationChannelName = 'Dana background sync';
  static const String _notificationChannelDescription =
      'Keeps your wallet up to date in the background';
  static const String _foregroundNotificationText =
      'Keeping your wallet up to date';

  static ForegroundServiceAdapter _adapter =
      const _PluginForegroundServiceAdapter();

  /// Test seam: replace the platform adapter with a counting fake so
  /// lifecycle calls (started/attached) can be asserted without a device.
  @visibleForTesting
  static set serviceAdapter(ForegroundServiceAdapter adapter) =>
      _adapter = adapter;

  @visibleForTesting
  static void resetServiceAdapter() =>
      _adapter = const _PluginForegroundServiceAdapter();

  /// Call once at app startup, before runApp().
  static void initialize() {
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _notificationChannelId,
        channelName: _notificationChannelName,
        channelDescription: _notificationChannelDescription,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: synchronizationTaskOptions,
    );
  }

  /// Start the foreground service. Safe to call even if already running:
  /// a live service is re-attached ([ForegroundServiceStart.attached]),
  /// never started a second time. Does not block startup — await this
  /// fire-and-forget with unawaited().
  static Future<ForegroundServiceStart> start() async {
    if (await _adapter.isRunning()) {
      Logger().i('Android foreground service already running — re-attaching');
      return ForegroundServiceStart.attached;
    }

    final started = await _adapter.startService();

    if (started) {
      Logger().i('Android foreground service started');
      return ForegroundServiceStart.started;
    }

    return ForegroundServiceStart.failed;
  }

  static Future<void> stop() async {
    if (!await _adapter.isRunning()) return;
    await _adapter.stopService();
    Logger().i('Android foreground service stopped');
  }

  /// R11: ask the live foreground service to re-evaluate the frigate
  /// settings in-session and restart the subscription from the freshly
  /// committed settings. The subscription lives in the service isolate
  /// (B2.1) and the app isolate stays read-only while the service holds the
  /// writer lease (B2.3) — an app-isolate start() would be refused and the
  /// saved URL would not apply until the next service start. Returns true
  /// when the request was delivered to a running service — the caller must
  /// then NOT also stop()/start() in-process (two writers is a spec
  /// violation, B2.3).
  static Future<bool> requestFrigateRestart() async {
    if (!Platform.isAndroid) return false;
    if (!await FlutterForegroundTask.isRunningService) return false;
    FlutterForegroundTask.sendDataToTask({bgKeyRestartFrigate: true});
    return true;
  }
}
