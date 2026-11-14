import 'dart:convert';

import 'package:danawallet/repositories/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One entry of the permanent per-wallet disclosure record (B5.4): each
/// public frigate URL, with the date of its first successful public
/// subscription.
class FrigateDisclosureEntry {
  final String url;
  final DateTime date;

  const FrigateDisclosureEntry({required this.url, required this.date});
}

/// The per-wallet disclosure record and the one-time public-warning ack
/// (B5.3/B5.4).
///
/// Storage lives in the app's shared preferences. The ack key is part of
/// `SettingsRepository.resetAll`'s allow-list (a NEW wallet gets its own
/// one-time warning); the disclosure log is deliberately NOT — the record
/// is permanent and survives the wallet (B5.4).
class FrigateDisclosureRepository {
  static final FrigateDisclosureRepository instance =
      FrigateDisclosureRepository._();

  FrigateDisclosureRepository._();

  /// Permanent disclosure log key — deliberately NOT in
  /// `SettingsRepository.resetAll`'s allow-list (the record survives the
  /// wallet, B5.4).
  static const String disclosureLogKey = 'frigatedisclosurelog';

  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  Future<bool> isPublicWarningAcked() async {
    return await _prefs.getBool(keyFrigateWarningAcked) ?? false;
  }

  Future<void> ackPublicWarning() async {
    await _prefs.setBool(keyFrigateWarningAcked, true);
  }

  Future<List<FrigateDisclosureEntry>> getEntries() async {
    final raw = await _prefs.getStringList(disclosureLogKey) ?? const [];
    return [
      for (final line in raw)
        FrigateDisclosureEntry(
          url: (jsonDecode(line) as Map<String, dynamic>)['url'] as String,
          date: DateTime.parse(
              (jsonDecode(line) as Map<String, dynamic>)['date'] as String),
        ),
    ];
  }

  /// Records (url, now) unless [url] is already in the record — each public
  /// URL + date is logged permanently, deduped per URL (B5.4).
  Future<void> recordIfNew(String url) async {
    final entries = await getEntries();
    if (entries.any((entry) => entry.url == url)) return;
    final raw = await _prefs.getStringList(disclosureLogKey) ?? const [];
    await _prefs.setStringList(disclosureLogKey, [
      ...raw,
      jsonEncode({'url': url, 'date': DateTime.now().toIso8601String()}),
    ]);
  }
}
