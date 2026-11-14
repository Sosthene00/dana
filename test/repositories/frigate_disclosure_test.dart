import 'package:danawallet/repositories/frigate_disclosure_repository.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// B5.2 (per-URL public/private declaration, default private), B5.4
/// (permanent per-URL+date disclosure record, per-wallet warning ack).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // ONE platform instance for the whole file: the repository singletons
    // capture it at first construction, so per-test replacement would not
    // reach them — isolate via a full wipe instead.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  setUp(() async {
    await SharedPreferencesAsync().clear();
  });

  group('frigate declaration (B5.2)', () {
    test('default is PRIVATE — public is always opt-in', () async {
      expect(await SettingsRepository.instance.isFrigatePublic(), isFalse,
          reason: 'B5.2: default selection is private');
    });

    test('declaration round-trips and can be revoked', () async {
      final settings = SettingsRepository.instance;
      await settings.setFrigatePublic(true);
      expect(await settings.isFrigatePublic(), isTrue);
      await settings.setFrigatePublic(false);
      expect(await settings.isFrigatePublic(), isFalse);
    });
  });

  group('public warning ack (B5.3/B5.4)', () {
    test('default: not acked', () async {
      expect(await FrigateDisclosureRepository.instance.isPublicWarningAcked(),
          isFalse);
    });

    test('ack persists', () async {
      final repo = FrigateDisclosureRepository.instance;
      await repo.ackPublicWarning();
      expect(await repo.isPublicWarningAcked(), isTrue);
    });

    test('wallet reset clears the ack (per-wallet warning) but the '
        'disclosure record stays permanent (B5.4)', () async {
      final repo = FrigateDisclosureRepository.instance;
      await repo.ackPublicWarning();
      await repo.recordIfNew('public.frigate.lan:50002');

      await SettingsRepository.instance.resetAll();

      expect(await repo.isPublicWarningAcked(), isFalse,
          reason: 'a NEW wallet gets its own one-time warning');
      expect((await repo.getEntries()).length, 1,
          reason: 'the disclosure record is permanent — past disclosures '
              'survive the wallet');
    });
  });

  group('disclosure record (B5.4)', () {
    test('starts empty', () async {
      expect(await FrigateDisclosureRepository.instance.getEntries(), isEmpty);
    });

    test('each public URL is recorded once, with its date', () async {
      final repo = FrigateDisclosureRepository.instance;
      await repo.recordIfNew('public.frigate.lan:50002');
      await repo.recordIfNew('other.frigate.lan:50002');
      await repo.recordIfNew(
          'public.frigate.lan:50002'); // same URL, later sync — no duplicate

      final entries = await repo.getEntries();
      expect(entries.length, 2,
          reason: 'B5.4: each public URL + date is logged — deduped per URL');
      expect(entries.map((e) => e.url).toSet(),
          {'public.frigate.lan:50002', 'other.frigate.lan:50002'});
      for (final entry in entries) {
        expect(entry.date.isBefore(DateTime.now()), isTrue);
      }
    });

    test('entries survive wallet reset (permanent record)', () async {
      final repo = FrigateDisclosureRepository.instance;
      await repo.recordIfNew('p:1');

      await SettingsRepository.instance.resetAll();

      final entries = await repo.getEntries();
      expect(entries.length, 1);
      expect(entries.single.url, 'p:1');
    });
  });
}
