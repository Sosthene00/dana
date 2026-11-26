import 'package:shared_preferences/shared_preferences.dart';

/// Liveness marker for the foreground-service writer (review blocker B1:
/// one-shot service lease acquisition).
///
/// The service isolate writes this marker whenever it is alive but cannot
/// take the writer lease (a live app writer holds it, B2.3). The app
/// isolate's sync host polls the marker: a FRESH service marker means the
/// service is live and waiting for its slot — the app host must stand down
/// (stop its scanner, release the writer lease) so the service's next
/// acquisition attempt succeeds. While the service is alive it is the sole
/// writer; the app host is only a fallback for when the service is down.
///
/// Stored in shared (DataStore) preferences, not the writer-lease table:
/// this is a presence signal, not a lease — it never grants write access
/// and the sync-state write path never consults it (the B2.8 guard is
/// untouched).
class ServiceLiveness {
  ServiceLiveness._();

  /// Shared-preferences key holding the last-seen epoch millis.
  static const String prefsKey = 'service_writer_seen_ms';

  /// A marker newer than this counts as a live, waiting service.
  static const Duration freshWindow = Duration(seconds: 15);

  /// The service writer is alive: refresh the marker.
  static Future<void> mark({int Function()? nowMillis}) async {
    final now = nowMillis?.call() ?? DateTime.now().millisecondsSinceEpoch;
    await SharedPreferencesAsync().setInt(prefsKey, now);
  }

  /// True when a service writer announced itself within [window] (default
  /// [freshWindow]).
  static Future<bool> isFresh(
      {Duration? window, int Function()? nowMillis}) async {
    final seen = await SharedPreferencesAsync().getInt(prefsKey);
    if (seen == null) return false;
    final now = nowMillis?.call() ?? DateTime.now().millisecondsSinceEpoch;
    return now - seen < (window ?? freshWindow).inMilliseconds;
  }

  /// Clear the marker (test hygiene only; staleness makes it moot).
  static Future<void> clear() => SharedPreferencesAsync().remove(prefsKey);
}
