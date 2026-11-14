import 'package:danawallet/services/frigate_url_probe.dart';
import 'package:danawallet/services/frigate_warning_gate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// B5.2 (default private, public opt-in), B5.3 (blocking one-time warning
/// before the first public sync), B5.4 (fires exactly once per wallet, on a
/// REACHABLE public URL — an unreachable URL never fires it).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // The gate's default hooks touch the settings singletons — give them an
    // in-memory platform so construction works (the tests inject their own
    // hooks, the defaults are never consulted).
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('FrigateWarningGate (B5.2-B5.4)', () {
    test('no URL configured: proceed without probing', () async {
      var probeCalls = 0;
      final gate = FrigateWarningGate(
        getUrl: () async => null,
        probe: (url) async => probeCalls++,
      );

      expect(await gate.evaluate(), FrigateGateDecision.proceed);
      expect(probeCalls, 0);
    });

    test('private declaration (B5.2 default): proceed, probe never called',
        () async {
      var probeCalls = 0;
      var warningCalls = 0;
      final gate = FrigateWarningGate(
        getUrl: () async => 'frigate.lan:50002',
        isPublic: () async => false,
        isAcked: () async => false,
        probe: (url) async => probeCalls++,
        onWarningRequired: () => warningCalls++,
      );

      expect(await gate.evaluate(), FrigateGateDecision.proceed);
      expect(probeCalls, 0, reason: 'a private sync needs no warning gate');
      expect(warningCalls, 0);
    });

    test('public, unacked, unreachable URL: no warning fired (B5.4)',
        () async {
      var warningCalls = 0;
      var probeCalls = 0;
      final gate = FrigateWarningGate(
        getUrl: () async => 'down.lan:50002',
        isPublic: () async => true,
        isAcked: () async => false,
        probe: (url) async {
          probeCalls++;
          throw const FrigateProbeUnreachable('can\'t connect');
        },
        onWarningRequired: () => warningCalls++,
      );

      expect(await gate.evaluate(), FrigateGateDecision.unreachable);
      expect(probeCalls, 1);
      expect(warningCalls, 0,
          reason: 'an unreachable URL never fires the warning (B5.4) — '
              'the harm happens at first successful use');
    });

    test('public, unacked, reachable: warning fires exactly once, held',
        () async {
      var warningCalls = 0;
      final gate = FrigateWarningGate(
        getUrl: () async => 'frigate.lan:50002',
        isPublic: () async => true,
        isAcked: () async => false,
        probe: (url) async {},
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
      var probeCalls = 0;
      final gate = FrigateWarningGate(
        getUrl: () async => 'other.frigate.lan:50002',
        isPublic: () async => true,
        isAcked: () async => true,
        probe: (url) async => probeCalls++,
        onWarningRequired: () => warningCalls++,
      );

      expect(await gate.evaluate(), FrigateGateDecision.proceed);
      expect(warningCalls, 0);
      expect(probeCalls, 0,
          reason: 'an acked wallet needs no further gating or probing');
    });

    test('after the ack lands, the gate resets and proceeds', () async {
      var acked = false;
      var warningCalls = 0;
      final gate = FrigateWarningGate(
        getUrl: () async => 'frigate.lan:50002',
        isPublic: () async => true,
        isAcked: () async => acked,
        probe: (url) async {},
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
