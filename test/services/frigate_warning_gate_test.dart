import 'package:danawallet/services/frigate_warning_gate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// B5.2-B5.4 (owner ruling R12, 2026-11-18): the public warning is a
/// SAVE-TIME gate — the declaration screen probes, warns, and only commits
/// on acknowledgement. The subscription-start gate exists ONLY as the
/// migration path for pre-ruling installs (a public unacked URL saved under
/// the old semantics still fires the warning at subscription start, B2.2).
///
/// The save path is probe-gated, so the gate no longer probes at start and
/// the `unreachable` decision is gone (J3): an unreachable public URL can
/// never exist in settings anymore.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // The gate's default hooks touch the settings singletons — give them an
    // in-memory platform so construction works (the tests inject their own
    // hooks, the defaults are never consulted).
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('FrigateWarningGate (B5.2-B5.4, R12 semantics)', () {
    test('no URL configured: proceed', () async {
      var warningCalls = 0;
      final gate = FrigateWarningGate(
        getUrl: () async => null,
        onWarningRequired: () => warningCalls++,
      );

      expect(await gate.evaluate(), FrigateGateDecision.proceed);
      expect(warningCalls, 0);
    });

    test('private declaration (B5.2 default): proceed', () async {
      var warningCalls = 0;
      final gate = FrigateWarningGate(
        getUrl: () async => 'frigate.lan:50002',
        isPublic: () async => false,
        isAcked: () async => false,
        onWarningRequired: () => warningCalls++,
      );

      expect(await gate.evaluate(), FrigateGateDecision.proceed);
      expect(warningCalls, 0, reason: 'a private sync needs no warning gate');
    });

    test('public, unacked (pre-ruling state): warning fires once, held',
        () async {
      var warningCalls = 0;
      final gate = FrigateWarningGate(
        getUrl: () async => 'frigate.lan:50002',
        isPublic: () async => true,
        isAcked: () async => false,
        onWarningRequired: () => warningCalls++,
      );

      expect(await gate.evaluate(), FrigateGateDecision.warningRequired);
      expect(warningCalls, 1);

      // Still unacked on the next start attempt (service retry loop): the
      // warning must NOT fire again, the subscription stays held (B5.3).
      expect(await gate.evaluate(), FrigateGateDecision.warningHold);
      expect(warningCalls, 1, reason: 'the warning fires exactly ONCE');
    });

    test('public, already acked: proceed, no warning (B5.4 never again)',
        () async {
      var warningCalls = 0;
      final gate = FrigateWarningGate(
        getUrl: () async => 'other.frigate.lan:50002',
        isPublic: () async => true,
        isAcked: () async => true,
        onWarningRequired: () => warningCalls++,
      );

      expect(await gate.evaluate(), FrigateGateDecision.proceed);
      expect(warningCalls, 0,
          reason: 'an acked wallet needs no further gating (J1: per wallet '
              'across all URLs)');
    });

    test('after the ack lands, the gate resets and proceeds', () async {
      var acked = false;
      var warningCalls = 0;
      final gate = FrigateWarningGate(
        getUrl: () async => 'frigate.lan:50002',
        isPublic: () async => true,
        isAcked: () async => acked,
        onWarningRequired: () => warningCalls++,
      );

      expect(await gate.evaluate(), FrigateGateDecision.warningRequired);
      expect(await gate.evaluate(), FrigateGateDecision.warningHold);
      expect(warningCalls, 1);

      acked = true; // the user acknowledged the blocking warning (B5.3)
      expect(await gate.evaluate(), FrigateGateDecision.proceed);
    });
  });
}
