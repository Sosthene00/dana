import 'dart:async';

import 'package:danawallet/repositories/frigate_disclosure_repository.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/screens/settings/chainbackend/chain_backend_screen.dart';
import 'package:danawallet/services/backend_apply_result.dart';
import 'package:danawallet/services/frigate_url_probe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

// B5.1-B5.4 acceptance against the owner ruling R12 (2026-11-18): the
// public warning gates the SAVE, not the first sync.
//
// Re-derived R10c/B8.4 acceptance: fresh install -> choose Frigate +
// reachable -> warning fires AT SAVE exactly once -> "No" leaves the old
// settings fully intact -> "Yes" saves and writes the disclosure record at
// save time -> an already-acked wallet never re-fires.
//
// R11 (owner ruling, 2026-11-18): "modifying the settings to a frigate
// backend should trigger the subscription immediately, without having to
// restart the app." A successful Frigate save starts the subscription
// in-session. There is no public/private toggle: saving a Frigate URL is
// the public path.

/// Records the single applyBackend command the screen sends after a
/// committed save. [future] can hang or [error] throw so the screen's
/// timeout and error path stay covered; [result] simulates the typed
/// not-delivered outcomes (M-c).
class _ApplyProbe {
  _ApplyProbe(
      {this.future, this.error, this.result = BackendApplyResult.delivered});

  final Future<void>? future;
  final Object? error;
  final BackendApplyResult result;
  int calls = 0;

  Future<BackendApplyResult> call() async {
    calls++;
    if (error != null) throw error!;
    if (future != null) await future;
    return result;
  }
}

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

  Future<_ApplyProbe> saveFrigate(WidgetTester tester,
      {required _ApplyProbe apply,
      Duration applyTimeout = const Duration(seconds: 1),
      String url = 'f-r12b.lan:50002'}) async {
    await tester.pumpWidget(wrap(ChainBackendScreen(
      probe: (url) async {},
      applyTimeout: applyTimeout,
      applyBackend: apply.call,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Frigate'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), url);
    await tester.tap(find.text('Save backend'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes — I understand, sync publicly'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle(const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
    return apply;
  }

  Future<void> declarePublicAndSave(WidgetTester tester,
      {required Future<void> Function(String url) probe,
      Future<BackendApplyResult> Function()? apply}) async {
    await tester
        .pumpWidget(wrap(ChainBackendScreen(probe: probe, applyBackend: apply)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Frigate'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'new.lan:50002');
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
    await settings.setChainBackend(ChainBackendKind.blindbit);

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
    expect(await settings.getChainBackend(), ChainBackendKind.blindbit,
        reason: 'a declined Frigate save does not switch the backend');
    expect(await FrigateDisclosureRepository.instance.isPublicWarningAcked(),
        isFalse,
        reason: 'the ack state is untouched');
    expect(await FrigateDisclosureRepository.instance.getEntries(), isEmpty,
        reason: 'no disclosure record without consent');
    // The screen stays open (no pop), the dialog is gone.
    expect(find.byType(ChainBackendScreen), findsOneWidget);
    expect(find.text('Sync through a public backend?'), findsNothing);
  });

  testWidgets(
      'B5.4/B8.4 (R12): "Yes" at save persists ack + URL + declaration and '
      'writes the disclosure record AT SAVE TIME', (tester) async {
    final settings = SettingsRepository.instance;
    final disclosure = FrigateDisclosureRepository.instance;

    await declarePublicAndSave(tester,
        probe: (url) async {},
        apply: () async => BackendApplyResult.delivered);

    expect(find.text('Sync through a public backend?'), findsOneWidget);
    await tester.tap(find.text('Yes — I understand, sync publicly'));
    await tester.pumpAndSettle();

    expect(await disclosure.isPublicWarningAcked(), isTrue,
        reason: 'the ack is persisted at save');
    expect(await settings.getFrigateUrl(), 'new.lan:50002');
    expect(await settings.isFrigatePublic(), isTrue);
    expect(await settings.getChainBackend(), ChainBackendKind.frigate);
    final entries = await disclosure.getEntries();
    expect(entries.length, 1,
        reason: 'J2: the disclosure record is written at save time, not at '
            'first successful subscription');
    expect(entries.single.url, 'new.lan:50002');
    // The screen pops after a committed save.
    expect(find.byType(ChainBackendScreen), findsNothing);
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

  testWidgets(
      'saving a Frigate URL fires the privacy warning with no public/private '
      'choice', (tester) async {
    await tester.pumpWidget(wrap(ChainBackendScreen(probe: (url) async {})));
    await tester.pumpAndSettle();

    expect(find.text('Private'), findsNothing);
    expect(find.text('Public'), findsNothing);

    await tester.tap(find.text('Frigate'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'private.lan:50002');
    await tester.tap(find.text('Save backend'));
    await tester.pumpAndSettle();

    expect(find.text('Sync through a public backend?'), findsOneWidget);
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
    expect(find.byType(ChainBackendScreen), findsOneWidget);
  });

  // A committed save of either backend is one applyBackend command. The
  // host, not this screen, decides which isolate swaps the scanner.

  testWidgets(
      'B5.2 (R11): a successful Frigate save applies the backend '
      'in-session — the post-ack trigger needs no restart', (tester) async {
    final apply = _ApplyProbe();
    await saveFrigate(tester,
        apply: apply, url: 'public.lan:50002', applyTimeout: const Duration(seconds: 5));

    expect(apply.calls, 1,
        reason: 'R11: the acked public save asks the host to apply the '
            'committed backend in-session');
    expect(await SettingsRepository.instance.getFrigateUrl(), 'public.lan:50002');
    expect(await SettingsRepository.instance.isFrigatePublic(), isTrue);
    expect(await SettingsRepository.instance.getChainBackend(),
        ChainBackendKind.frigate);
    expect(await FrigateDisclosureRepository.instance.isPublicWarningAcked(),
        isTrue);
    expect(find.byType(ChainBackendScreen), findsNothing);
  });

  testWidgets(
      'F-R12b/M-c: a hanging apply never wedges the save — the settings '
      'are committed and the unconfirmed swap is surfaced inline',
      (tester) async {
    final settings = SettingsRepository.instance;
    final apply = _ApplyProbe(future: Completer<void>().future);

    await saveFrigate(tester, apply: apply);

    expect(await settings.getFrigateUrl(), 'f-r12b.lan:50002',
        reason: 'the save is committed before the host swap returns');
    expect(find.byType(ChainBackendScreen), findsOneWidget,
        reason: 'M-c: the screen must not pop silently on an unconfirmed '
            'swap — the divergence is surfaced inline');
    expect(find.text(backendApplyDivergenceMessage), findsOneWidget);
    expect(apply.calls, 1);
  });

  // M-c (review t_a38b7193): a failed apply after a committed save is a
  // settings/scanner divergence — it must be user-visible inline, never a
  // silent pop. RED against the base: the screen pops with no feedback.
  testWidgets(
      'M-c: a failed apply after a committed save surfaces the divergence '
      'inline and does not pretend success', (tester) async {
    final settings = SettingsRepository.instance;
    final apply = _ApplyProbe(error: StateError('host busy'));

    await saveFrigate(tester, apply: apply);

    expect(apply.calls, 1);
    expect(await settings.getChainBackend(), ChainBackendKind.frigate,
        reason: 'the save itself is committed before the apply');
    expect(find.byType(ChainBackendScreen), findsOneWidget,
        reason: 'a failed apply must not pop silently — the screen stays '
            'open with the divergence message');
    expect(
        find.text('Saved, but the running scanner could not be switched — '
            'it will switch on next service start'),
        findsOneWidget,
        reason: 'the divergence is user-visible inline, not a log line');
  });

  // M-c service-path variant: the typed not-delivered result (no live
  // service to receive the request) is surfaced the same way as a thrown
  // apply — the committed setting and the scanner diverge.
  testWidgets(
      'M-c: a not-delivered apply (service path) surfaces the divergence '
      'inline', (tester) async {
    final apply = _ApplyProbe(result: BackendApplyResult.noService);

    await saveFrigate(tester, apply: apply);

    expect(apply.calls, 1);
    expect(find.byType(ChainBackendScreen), findsOneWidget);
    expect(find.text(backendApplyDivergenceMessage), findsOneWidget);
  });
}
