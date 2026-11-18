import 'package:danawallet/repositories/frigate_disclosure_repository.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/screens/settings/network/frigate_backend_screen.dart';
import 'package:danawallet/services/frigate_url_probe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// B5.1-B5.4 acceptance against the owner ruling R12 (2026-11-18): the
/// public warning gates the SAVE, not the first sync.
///
/// Re-derived R10c/B8.4 acceptance: fresh install -> declare public +
/// reachable -> warning fires AT SAVE exactly once -> "No" leaves the old
/// settings fully intact -> "Yes" saves and writes the disclosure record at
/// save time -> an already-acked wallet never re-fires.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  setUp(() async {
    await SharedPreferencesAsync().clear();
  });

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  Future<void> declarePublicAndSave(WidgetTester tester,
      {required Future<void> Function(String url) probe}) async {
    await tester.pumpWidget(wrap(FrigateBackendScreen(probe: probe)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'new.lan:50002');
    await tester.tap(find.text('Public'));
    await tester.pump();
    await tester.tap(find.text('Save backend'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'B5.3 (R12): public save fires the warning AT SAVE; "No" aborts with '
      'the old settings fully intact', (tester) async {
    final settings = SettingsRepository.instance;
    // A pre-existing private configuration that must survive the abort.
    await settings.setFrigateUrl('old.lan:50002');
    await settings.setFrigatePublic(false);

    await declarePublicAndSave(tester, probe: (url) async {});

    // The warning fires BEFORE the save commits — and only after the probe.
    expect(find.text('Sync through a public backend?'), findsOneWidget);

    await tester.tap(find.text('No — go back'));
    await tester.pumpAndSettle();

    // J2/owner ruling: NOTHING is persisted on "No".
    expect(await settings.getFrigateUrl(), 'old.lan:50002',
        reason: 'the old URL is untouched');
    expect(await settings.isFrigatePublic(), isFalse,
        reason: 'the declaration is untouched');
    expect(await FrigateDisclosureRepository.instance.isPublicWarningAcked(),
        isFalse,
        reason: 'the ack state is untouched');
    expect(await FrigateDisclosureRepository.instance.getEntries(), isEmpty,
        reason: 'no disclosure record without consent');
    // The screen stays open (no pop), the dialog is gone.
    expect(find.byType(FrigateBackendScreen), findsOneWidget);
    expect(find.text('Sync through a public backend?'), findsNothing);
  });

  testWidgets(
      'B5.4/B8.4 (R12): "Yes" at save persists ack + URL + declaration and '
      'writes the disclosure record AT SAVE TIME', (tester) async {
    final settings = SettingsRepository.instance;
    final disclosure = FrigateDisclosureRepository.instance;

    await declarePublicAndSave(tester, probe: (url) async {});

    expect(find.text('Sync through a public backend?'), findsOneWidget);
    await tester.tap(find.text('Yes — I understand, sync publicly'));
    await tester.pumpAndSettle();

    expect(await disclosure.isPublicWarningAcked(), isTrue,
        reason: 'the ack is persisted at save');
    expect(await settings.getFrigateUrl(), 'new.lan:50002');
    expect(await settings.isFrigatePublic(), isTrue);
    final entries = await disclosure.getEntries();
    expect(entries.length, 1,
        reason: 'J2: the disclosure record is written at save time, not at '
            'first successful subscription');
    expect(entries.single.url, 'new.lan:50002');
    // The screen pops after a committed save.
    expect(find.byType(FrigateBackendScreen), findsNothing);
  });

  testWidgets(
      'B5.4/J1 (R12): an already-acked wallet saves another public URL '
      'without ever re-firing the warning', (tester) async {
    final settings = SettingsRepository.instance;
    final disclosure = FrigateDisclosureRepository.instance;
    await disclosure.ackPublicWarning(); // warned on an earlier URL

    await declarePublicAndSave(tester, probe: (url) async {});

    expect(find.text('Sync through a public backend?'), findsNothing,
        reason: 'B5.4: it never fires again, for any URL');
    expect(await settings.getFrigateUrl(), 'new.lan:50002');
    expect(await settings.isFrigatePublic(), isTrue);
    final entries = await disclosure.getEntries();
    expect(entries.single.url, 'new.lan:50002',
        reason: 'each public URL still enters the permanent record');
  });

  testWidgets('B5.2: a private save never fires the warning', (tester) async {
    final settings = SettingsRepository.instance;

    await tester.pumpWidget(wrap(FrigateBackendScreen(probe: (url) async {})));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'private.lan:50002');
    await tester.tap(find.text('Save backend'));
    await tester.pumpAndSettle();

    expect(find.text('Sync through a public backend?'), findsNothing);
    expect(await settings.getFrigateUrl(), 'private.lan:50002');
    expect(await settings.isFrigatePublic(), isFalse);
    expect(await FrigateDisclosureRepository.instance.isPublicWarningAcked(),
        isFalse);
    expect(await FrigateDisclosureRepository.instance.getEntries(), isEmpty);
  });

  testWidgets(
      'B5.1 regression: a probe failure on a public save shows the inline '
      'error and saves nothing (no warning either)', (tester) async {
    final settings = SettingsRepository.instance;

    await declarePublicAndSave(tester,
        probe: (url) async =>
            throw const FrigateProbeUnreachable('Could not reach it'));

    expect(find.text('Sync through a public backend?'), findsNothing,
        reason: 'the warning only fires after the probe passes');
    expect(find.text('Could not reach it'), findsOneWidget);
    expect(await settings.getFrigateUrl(), isNull);
    expect(await FrigateDisclosureRepository.instance.getEntries(), isEmpty);
    expect(find.byType(FrigateBackendScreen), findsOneWidget);
  });
}
