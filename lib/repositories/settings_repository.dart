import 'package:danawallet/data/enums/amount_display_unit.dart';
import 'package:danawallet/data/enums/fiat_currency.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _keyBlindbitUrl = "blindbiturl";
const String _keyDustLimit = "dustlimit";
const String _keyFiatCurrency = "fiatcurrency";
const String _keyBlockExplorerUrl = "blockexplorerurl";
const String _keyAmountDisplayUnit = "amountdisplayunit";
const String _keyLastBackupDate = "lastbackupdate";
const String _keyLastBackupVerified = "lastbackupverified";

class SettingsRepository {
  final SharedPreferencesAsync prefs = SharedPreferencesAsync();

  // private constructor
  SettingsRepository._();

  // singleton instance
  static final instance = SettingsRepository._();

  Future<void> resetAll() async {
    await prefs.clear(allowList: {
      _keyBlindbitUrl,
      _keyDustLimit,
      _keyFiatCurrency,
      _keyBlockExplorerUrl,
      _keyAmountDisplayUnit,
      _keyLastBackupDate,
      _keyLastBackupVerified,
    });
  }

  Future<void> setBlindbitUrl(String? url) async {
    if (url != null) {
      return await prefs.setString(_keyBlindbitUrl, url);
    } else {
      return await prefs.remove(_keyBlindbitUrl);
    }
  }

  Future<String?> getBlindbitUrl() async {
    return await prefs.getString(_keyBlindbitUrl);
  }

  Future<void> setBlockExplorerUrl(String? url) async {
    if (url != null) {
      return await prefs.setString(_keyBlockExplorerUrl, url);
    } else {
      return await prefs.remove(_keyBlockExplorerUrl);
    }
  }

  Future<String?> getBlockExplorerUrl() async {
    return await prefs.getString(_keyBlockExplorerUrl);
  }

  Future<void> setDustLimit(int? value) async {
    if (value != null) {
      return await prefs.setInt(_keyDustLimit, value);
    } else {
      return await prefs.remove(_keyDustLimit);
    }
  }

  Future<int?> getDustLimit() async {
    return await prefs.getInt(_keyDustLimit);
  }

  Future<void> setFiatCurrency(FiatCurrency? currency) async {
    if (currency != null) {
      return await prefs.setString(_keyFiatCurrency, currency.name);
    } else {
      return await prefs.remove(_keyFiatCurrency);
    }
  }

  Future<FiatCurrency?> getFiatCurrency() async {
    final currency = await prefs.getString(_keyFiatCurrency);

    return currency != null ? FiatCurrency.values.byName(currency) : null;
  }

  Future<void> setAmountDisplayUnit(AmountDisplayUnit? unit) async {
    if (unit != null) {
      return await prefs.setString(_keyAmountDisplayUnit, unit.name);
    } else {
      return await prefs.remove(_keyAmountDisplayUnit);
    }
  }

  Future<AmountDisplayUnit?> getAmountDisplayUnit() async {
    final unit = await prefs.getString(_keyAmountDisplayUnit);

    return unit != null ? AmountDisplayUnit.values.byName(unit) : null;
  }

  /// §7.1 step 5: after a successful export the backup status is marked
  /// with the current date; this feeds the §7.3 deletion gate (none /
  /// exists / verified-with-date).
  Future<void> setLastBackupDate(DateTime? date) async {
    if (date != null) {
      return await prefs.setString(_keyLastBackupDate, date.toIso8601String());
    } else {
      return await prefs.remove(_keyLastBackupDate);
    }
  }

  /// Whether the current backup has been verified by an actual restore
  /// test (§7.1 step 5: "Verified" status requires a restore). v1 defers
  /// the verify flow itself; the flag exists so the §7.3 deletion gate can
  /// already distinguish `exists` from `verified`.
  Future<void> setLastBackupVerified(bool verified) async {
    return await prefs.setBool(_keyLastBackupVerified, verified);
  }

  Future<bool> isLastBackupVerified() async {
    return await prefs.getBool(_keyLastBackupVerified) ?? false;
  }

  Future<DateTime?> getLastBackupDate() async {
    final stored = await prefs.getString(_keyLastBackupDate);
    return stored != null ? DateTime.parse(stored) : null;
  }
}
