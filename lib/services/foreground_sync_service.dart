import 'dart:io';

import 'package:danawallet/constants.dart';
import 'package:danawallet/services/sync_task_handler.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:logger/logger.dart';
import 'package:package_info_plus/package_info_plus.dart';

class ForegroundSyncService {
  static const String _notificationChannelId = 'dana_sync';
  static const String _notificationChannelName = 'Dana background sync';
  static const String _notificationChannelDescription =
      'Keeps your wallet up to date in the background';
  static const String _foregroundNotificationText =
      'Keeping your wallet up to date';

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

  /// Start the foreground service. Safe to call even if already running.
  /// Does not block startup — await this fire-and-forget with unawaited().
  static Future<void> start() async {
    if (await FlutterForegroundTask.isRunningService) {
      Logger().i('Android foreground service already running');
      return;
    }

    final appInfo = await PackageInfo.fromPlatform();

    final result = await FlutterForegroundTask.startService(
      serviceId: 1000,
      notificationTitle: appInfo.appName,
      notificationText: _foregroundNotificationText,
      callback: startCallback,
    );

    if (result is ServiceRequestSuccess) {
      Logger().i('Android foreground service started');
    } else if (result is ServiceRequestFailure) {
      Logger().w(
        'Failed to start Android foreground service: ${result.error}',
      );
    }
  }

  static Future<void> stop() async {
    if (!await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.stopService();
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
