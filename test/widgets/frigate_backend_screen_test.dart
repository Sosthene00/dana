import 'dart:async';

import 'package:danawallet/repositories/frigate_disclosure_repository.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/screens/settings/chain_backend_screen.dart';
import 'package:danawallet/services/frigate_subscription_controller.dart';
import 'package:danawallet/services/frigate_url_probe.dart';
import 'package:danawallet/states/frigate_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
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

/// Controller stub overriding only the lifecycle seams the screen touches
/// (the R11 seam): start()/stop() are recorded, never run; urlAtStart/
/// publicAtStart capture what the settings held when start() was invoked.
class _RecordingController extends FrigateSubscriptionController {
  /// F-R12b seams: [stopFuture] makes stop() hang (the exact on-device
  /// deadlock) or return late; [stopError] makes it throw; [startCalled]
  /// records whether a fresh start() ever ran.
  _RecordingController({this.stopFuture, this.stopError})
      : super(frigateState: FrigateState());

  final Future<void>? stopFuture;
  final Object? stopError;
  bool startCalled = false;
  int startCalls = 0;
  int stopCalls = 0;
  String? urlAtStart;
  bool? publicAtStart;

  @override
  Future<void> stop() async {
    stopCalls++;
    if (stopError != null) throw stopError!;
    if (stopFuture != null) await stopFuture;
  }

  @override
  Future<bool> start() async {
    startCalls++;
    startCalled = true;
    urlAtStart = await SettingsRepository.instance.getFrigateUrl();
    publicAtStart = await SettingsRepository.instance.isFrigatePublic();
    return true;
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

  /// A save with an injected controller (the R11 seam): start()/stop() are
  /// recorded, never run; [urlAtStart] captures what the settings held at
  /// the moment start() was invoked.
  Widget wrapWithController(Widget child,
          {required FrigateSubscriptionController controller}) =>
      MaterialApp(
          home: Scaffold(
              body: Provider<FrigateSubscriptionController>.value(
                  value: controller, child: child)));

  /// A save with an injected controller and a short [restartStopTimeout]
  /// (the F-R12b seam): the post-save restart must never wedge the flow.
  Future<_RecordingController> saveWithController(WidgetTester tester,
      {required _RecordingController controller,
      Duration restartStopTimeout = const Duration(seconds: 1)}) async {
    await tester.pumpWidget(wrapWithController(
      ChainBackendScreen(
        probe: (url) async {},
        restartStopTimeout: restartStopTimeout,
      ),
      controller: controller,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Frigate'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'f-r12b.lan:50002');
    await tester.tap(find.text('Save backend'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes — I understand, sync publicly'));
    // Flush the probe + persist, then advance fake time past the restart's
    // stop() bound so a timed-out teardown resolves before the assertions.
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    // Bounded: in the F-R12b red state the screen never pops — fail fast
    // instead of the framework's 10-minute default timeout.
    await tester.pumpAndSettle(const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
    return controller;
  }

  Future<void> declarePublicAndSave(WidgetTester tester,
      {required Future<void> Function(String url) probe}) async {
    await tester.pumpWidget(wrap(ChainBackendScreen(probe: probe)));
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

    await declarePublicAndSave(tester, probe: (url) async {});

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

  // --- R11: a successful save starts the subscription immediately ---
  testWidgets(
      'B5.2 (R11): a successful Frigate save starts the subscription '
      'in-session — the post-ack trigger needs no restart', (tester) async {
    final controller = _RecordingController();

    await tester.pumpWidget(wrapWithController(
      ChainBackendScreen(probe: (url) async {}),
      controller: controller,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Frigate'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'public.lan:50002');
    await tester.tap(find.text('Save backend'));
    await tester.pumpAndSettle();

    // R12's save-time warning composes with R11: the ack lands BEFORE the
    // subscription start, so the start proceeds without a warning hold.
    expect(find.text('Sync through a public backend?'), findsOneWidget);
    await tester.tap(find.text('Yes — I understand, sync publicly'));
    await tester.pumpAndSettle();

    expect(controller.startCalls, 1,
        reason: 'R11: the acked public save also starts the subscription '
            'in-session');
    expect(controller.urlAtStart, 'public.lan:50002');
    expect(controller.publicAtStart, isTrue);
    expect(await FrigateDisclosureRepository.instance.isPublicWarningAcked(),
        isTrue,
        reason: 'the ack is persisted before the start, so the gate '
            'proceeds instead of holding the subscription');
    expect(find.byType(ChainBackendScreen), findsNothing);
  });
  // --- F-R12b: the save flow must never hang on the post-persist restart ---
  //
  // On-device (F-R12b, 3/3 repros): after the settings are PERSISTED the
  // restart's `await controller.stop()` never returns, so the screen stays
  // stuck on "Probing backend…" forever. The save is committed; the UI must
  // pop regardless of what the restart teardown does. The restart is
  // best-effort: bounded by a timeout, and a stop that never returned never
  // races a fresh start() (a late-completing stop would tear the new
  // subscription down).

  testWidgets(
      'F-R12b: a hanging controller.stop() never wedges the save — the '
      'settings are committed and the screen pops', (tester) async {
    final settings = SettingsRepository.instance;
    // The exact on-device hang: stop() never returns.
    final controller =
        _RecordingController(stopFuture: Completer<void>().future);

    await saveWithController(tester, controller: controller);

    expect(await settings.getFrigateUrl(), 'f-r12b.lan:50002',
        reason: 'the save is committed before the restart');
    expect(find.byType(ChainBackendScreen), findsNothing,
        reason: 'the screen must not stay stuck on "Probing backend…" '
            'when the restart teardown never returns');
    expect(controller.startCalled, isFalse,
        reason: 'a stop that never returned must not race a fresh start() — '
            'a late-completing stop would tear the new subscription down');
  });

  testWidgets(
      'F-R12b: a slow-but-returning stop still restarts the subscription '
      'in the background after the pop', (tester) async {
    final controller = _RecordingController(
        stopFuture: Future<void>.delayed(const Duration(milliseconds: 200)));

    await saveWithController(tester, controller: controller);

    expect(find.byType(ChainBackendScreen), findsNothing);
    expect(controller.startCalled, isTrue,
        reason: 'the restart still runs (unawaited) once stop() returns');
  });

  testWidgets(
      'F-R12b: a throwing stop() still pops the screen and never starts '
      '(the pre-existing catch path)', (tester) async {
    final controller = _RecordingController(stopError: StateError('boom'));

    await saveWithController(tester, controller: controller);

    expect(find.byType(ChainBackendScreen), findsNothing);
    expect(controller.startCalled, isFalse);
  });
}
