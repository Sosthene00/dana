// WT-03 (t_11619ec3) acceptance tests — D11 UI contract:
//
// - named states challenging / confirming / retrying (countdown) are
//   reported to the flow observer at every transition, including the
//   backoff and refresh paths;
// - any background re-challenge (proactive TTL refresh, nonce-class
//   refresh) visibly resets the confirmation so an approval always matches
//   a challenge the user saw fetched;
// - exhaustion is terminal with no auto-retry; a controller restart is the
//   only path back and re-enters with fresh retry budgets.
//
// The controller + panel groups are pure Dart (fake flow runner). The
// service-level groups reuse the WT-02 scripted name server with the REAL
// wallet-held FFI signer and are skipped unless the bridge dylib is made
// loadable via FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR.
import 'dart:async';
import 'dart:convert';

import 'package:danawallet/data/models/bip353_address.dart';
import 'package:danawallet/data/models/name_server_challenge_response.dart';
import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/generated/rust/api/structs/silent_payment_code.dart';
import 'package:danawallet/generated/rust/api/wallet.dart';
import 'package:danawallet/generated/rust/api/wallet/setup.dart';
import 'package:danawallet/generated/rust/frb_generated.dart';
import 'package:danawallet/repositories/name_server_repository.dart';
import 'package:danawallet/services/dana_address_service.dart';
import 'package:danawallet/services/registration_flow.dart';
import 'package:danawallet/widgets/registration_status_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';

import 'dana_address_registration_test.dart'
    show FakeNameServer, ffiConfigured, ffiSkipReason, username, domain;

final Bip353Address anyAddress =
    Bip353Address(username: username, domain: domain);

NameServerChallengeResponse challengeFor(String nonce) =>
    NameServerChallengeResponse(
      message: 'dana-register:v1:tsp:$nonce:$username:$domain:sp',
      nonce: nonce,
      networkKey: 'tsp',
    );

// --- scripted server responses ---------------------------------------------

Response _resp(Object body, int status, {Map<String, String> headers = const {}}) =>
    Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json', ...headers});

/// Section-6 rejection: the body `message` field exactly matches the code.
Response registerReject(String code, {int status = 401}) =>
    _resp({'id': 'req', 'message': code}, status);

Response registerOk(String spCode) => _resp({
      'id': 'req',
      'message': 'registered',
      'dana_address': '$username@$domain',
      'sp_address': spCode,
      'dns_record_id': null,
    }, 200);

Response rateLimited(int retryAfterSeconds) => _resp(
      {'id': 'req', 'message': 'rate_limited'},
      429,
      headers: {'retry-after': '$retryAfterSeconds'},
    );

Response challengeOk(String spCode, String nonce) => _resp({
      'id': 'req',
      'message': 'dana-register:v1:tsp:$nonce:$username:$domain:$spCode',
      'nonce': nonce,
      'network_key': 'tsp',
      'expires_at': 4000000000, // display-only; never read by the flow
    }, 200);

// --- test doubles -----------------------------------------------------------

/// Ordered record of every flow callback (the D11 observable surface).
class _Ev {
  const _Ev(this.kind,
      {this.nonce,
      this.remaining,
      this.code,
      this.countdown,
      this.attempt,
      this.max});

  final String kind;
  final String? nonce;
  final int? remaining;
  final NameServerErrorCode? code;
  final int? countdown;
  final int? attempt;
  final int? max;

  @override
  String toString() => [
        kind,
        nonce ?? '',
        remaining != null ? 'rem=$remaining' : '',
        code?.wire ?? '',
        countdown != null ? 'cd=$countdown' : '',
        attempt != null ? '$attempt/$max' : '',
      ].where((s) => s.isNotEmpty).join(' ');
}

class RecordingFlow implements RegistrationFlow {
  final events = <_Ev>[];
  bool approve = true;

  @override
  Future<void> onChallenging() async => events.add(const _Ev('challenging'));

  @override
  Future<bool> onChallengeReceived({
    required NameServerChallengeResponse challenge,
    required int remainingSeconds,
  }) async {
    events.add(_Ev('challengeReceived',
        nonce: challenge.nonce, remaining: remainingSeconds));
    return approve;
  }

  @override
  Future<void> onConfirming() async => events.add(const _Ev('confirming'));

  @override
  Future<void> onRetrying({
    required NameServerErrorCode? code,
    required int countdownSeconds,
    required int attempt,
    required int maxAttempts,
  }) async =>
      events.add(_Ev('retrying',
          code: code,
          countdown: countdownSeconds,
          attempt: attempt,
          max: maxAttempts));

  @override
  Future<void> onConfirmationReset() async =>
      events.add(const _Ev('confirmationReset'));
}

/// Simulates the user approving at every confirmation gate.
void autoConfirm(RegistrationController controller) {
  controller.addListener(() {
    if (controller.state is RegistrationAwaitingConfirmation) {
      scheduleMicrotask(controller.confirm);
    }
  });
}

/// Busy-waits (bounded) until the controller reaches a state of [type].
Future<void> waitForState(RegistrationController controller, Type type,
    {Duration timeout = const Duration(seconds: 2)}) async {
  final deadline = DateTime.now().add(timeout);
  while (controller.state.runtimeType != type) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $type, state: ${controller.state}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  group('D11 controller states (pure Dart, fake runner)', () {
    test('named transitions: challenging -> awaiting -> confirming -> success',
        () async {
      final history = <Type>[];
      final controller = RegistrationController(
        runner: (flow) async {
          await flow.onChallenging();
          final approved = await flow.onChallengeReceived(
            challenge: challengeFor('n1'),
            remainingSeconds: 300,
          );
          expect(approved, isTrue);
          await flow.onConfirming();
          return anyAddress;
        },
      );
      autoConfirm(controller);
      controller.addListener(() => history.add(controller.state.runtimeType));
      await controller.start();

      // the full named-state sequence is reported, in order (D11)
      expect(history, [
        RegistrationChallenging,
        RegistrationAwaitingConfirmation,
        RegistrationConfirming,
        RegistrationSuccess,
      ]);
      controller.dispose();
    });

    test('withheld approval aborts the flow before signing (back to idle)',
        () async {
      var signed = false;
      final history = <Type>[];
      final controller = RegistrationController(
        runner: (flow) async {
          await flow.onChallenging();
          final approved = await flow.onChallengeReceived(
            challenge: challengeFor('n1'),
            remainingSeconds: 300,
          );
          if (!approved) {
            throw const RegistrationAbortedException();
          }
          signed = true;
          return anyAddress;
        },
      );
      controller.addListener(() => history.add(controller.state.runtimeType));
      final done = controller.start();
      await waitForState(controller, RegistrationAwaitingConfirmation);
      controller.cancelConfirmation();
      await done;

      expect(signed, isFalse);
      expect(history, [
        RegistrationChallenging,
        RegistrationAwaitingConfirmation,
        RegistrationIdle,
      ]);
      controller.dispose();
    });

    test('background re-challenge resets the confirmation', () async {
      final approvals = <bool>[];
      final history = <Type>[];
      final controller = RegistrationController(
        runner: (flow) async {
          await flow.onChallenging();
          approvals.add(await flow.onChallengeReceived(
            challenge: challengeFor('n1'),
            remainingSeconds: 300,
          ));
          // background re-challenge: the first challenge is discarded
          await flow.onConfirmationReset();
          await flow.onChallenging();
          approvals.add(await flow.onChallengeReceived(
            challenge: challengeFor('n2'),
            remainingSeconds: 295,
          ));
          await flow.onConfirming();
          return anyAddress;
        },
      );
      autoConfirm(controller);
      controller.addListener(() => history.add(controller.state.runtimeType));
      await controller.start();

      // the reset is visible between the two confirmations: the approval
      // always matches the challenge the user saw fetched
      expect(history, [
        RegistrationChallenging,
        RegistrationAwaitingConfirmation,
        RegistrationConfirmationReset,
        RegistrationChallenging,
        RegistrationAwaitingConfirmation,
        RegistrationConfirming,
        RegistrationSuccess,
      ]);
      expect(approvals, [true, true]);
      controller.dispose();
    });

    test('exhaustion lands on a terminal state naming the category',
        () async {
      final controller = RegistrationController(
        runner: (flow) async {
          await flow.onChallenging();
          throw RegisterRejectedException(
            429,
            'rate_limited',
            code: NameServerErrorCode.rateLimited,
          );
        },
      );
      await controller.start();
      final state = controller.state;
      expect(state, isA<RegistrationTerminal>());
      expect((state as RegistrationTerminal).category.label, 'Rate limited');
      controller.dispose();
    });

    test('terminal mapping: username_taken names the Username taken '
        'category', () async {
      final controller = RegistrationController(
        runner: (flow) async => throw RegisterRejectedException(
          409,
          'username_taken',
          code: NameServerErrorCode.usernameTaken,
        ),
      );
      await controller.start();
      expect(
        (controller.state as RegistrationTerminal).category.label,
        'Username taken',
      );
      controller.dispose();
    });

    test('no automatic retry after exhaustion; restart is the only path '
        'back and re-enters with fresh budgets', () async {
      var runs = 0;
      final controller = RegistrationController(
        runner: (flow) async {
          runs++;
          if (runs == 1) {
            await flow.onChallenging();
            throw RegisterRejectedException(
              429,
              'rate_limited',
              code: NameServerErrorCode.rateLimited,
            );
          }
          await flow.onChallenging();
          await flow.onConfirming();
          return anyAddress;
        },
      );

      await controller.start();
      expect(controller.state, isA<RegistrationTerminal>());
      expect(runs, 1);

      // no automatic retry follows exhaustion
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(runs, 1);

      await controller.restart();
      expect(controller.state, isA<RegistrationSuccess>());
      expect(runs, 2);

      // restart outside the terminal state is a no-op
      await controller.restart();
      expect(runs, 2);
      expect(controller.state, isA<RegistrationSuccess>());
      controller.dispose();
    });
  });

  group('D11 status panel (widget)', () {
    late RegistrationController controller;

    tearDown(() {
      controller.dispose();
    });

    Future<void> pumpPanel(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RegistrationStatusPanel(controller: controller),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('renders challenging, confirmation countdown, confirming',
        (tester) async {
      final step = Completer<void>();
      final confirmed = Completer<void>();
      controller = RegistrationController(
        runner: (flow) async {
          await flow.onChallenging();
          await step.future;
          final approved = await flow.onChallengeReceived(
            challenge: challengeFor('n1'),
            remainingSeconds: 300,
          );
          if (!approved) {
            throw StateError('approval lost');
          }
          await flow.onConfirming();
          await confirmed.future;
          return anyAddress;
        },
      );
      unawaited(controller.start());
      await pumpPanel(tester);

      expect(find.byKey(RegistrationStatusPanel.challengingKey),
          findsOneWidget);

      step.complete();
      await tester.pump();
      await tester.pump();

      // the confirmation panel is visible with the TTL countdown
      expect(find.byKey(RegistrationStatusPanel.awaitingConfirmationKey),
          findsOneWidget);
      expect(find.text('Challenge received — valid for 05:00'),
          findsOneWidget);

      // the countdown ticks down one second per second
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Challenge received — valid for 04:59'),
          findsOneWidget);

      // approving resolves the gate; the flow moves to confirming
      await tester.tap(find.byKey(const Key('registration_confirm_approve')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(RegistrationStatusPanel.confirmingKey),
          findsOneWidget);
      confirmed.complete();
      await tester.pump();
    });

    testWidgets('retrying state renders the visible backoff countdown',
        (tester) async {
      final gate = Completer<void>();
      controller = RegistrationController(
        runner: (flow) async {
          await flow.onRetrying(
            code: NameServerErrorCode.rateLimited,
            countdownSeconds: 5,
            attempt: 1,
            maxAttempts: 3,
          );
          await gate.future;
          return anyAddress;
        },
      );
      unawaited(controller.start());
      await pumpPanel(tester);

      expect(find.byKey(RegistrationStatusPanel.retryingKey), findsOneWidget);
      expect(find.text('Retrying (rate_limited) in 5s (attempt 1/3)'),
          findsOneWidget);

      // the countdown ticks visibly
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Retrying (rate_limited) in 3s (attempt 1/3)'),
          findsOneWidget);
      gate.complete();
      await tester.pump();
    });

    testWidgets('confirmation reset is rendered after a background '
        're-challenge', (tester) async {
      final gate = Completer<void>();
      final done = Completer<void>();
      controller = RegistrationController(
        runner: (flow) async {
          // park the approval: the user is looking at the confirmation panel
          unawaited(flow.onChallengeReceived(
            challenge: challengeFor('n1'),
            remainingSeconds: 300,
          ));
          await gate.future;
          // background re-challenge discards the shown challenge
          await flow.onConfirmationReset();
          await done.future;
          return anyAddress;
        },
      );
      unawaited(controller.start());
      await pumpPanel(tester);
      expect(find.byKey(RegistrationStatusPanel.awaitingConfirmationKey),
          findsOneWidget);

      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(RegistrationStatusPanel.confirmationResetKey),
          findsOneWidget);
      expect(
        find.text(
            'Confirmation reset — fetching a fresh challenge for you to '
            'approve…'),
        findsOneWidget,
      );
      done.complete();
      await tester.pump();
    });

    testWidgets('terminal screen names the category and the restart button '
        're-enters the flow', (tester) async {
      var runs = 0;
      final run2 = Completer<void>();
      controller = RegistrationController(
        runner: (flow) async {
          runs++;
          if (runs == 1) {
            await flow.onChallenging();
            throw RegisterRejectedException(
              429,
              'rate_limited',
              code: NameServerErrorCode.rateLimited,
            );
          }
          await flow.onConfirming();
          await run2.future;
          return anyAddress;
        },
      );
      unawaited(controller.start());
      await pumpPanel(tester);

      expect(find.byKey(RegistrationStatusPanel.terminalKey), findsOneWidget);
      expect(find.text('Registration failed — Rate limited'), findsOneWidget);
      expect(runs, 1, reason: 'no automatic retry after exhaustion');

      await tester.tap(find.byKey(const Key('registration_restart')));
      await tester.pump();
      await tester.pump();
      expect(
          find.byKey(RegistrationStatusPanel.confirmingKey), findsOneWidget);
      expect(runs, 2);
      run2.complete();
      await tester.pump();
    });
  });

  group('D11 flow observation over the real service (FFI signer)', () {
    late SpWallet wallet;
    late SilentPaymentCode paymentCode;
    late String spCode;
    late Future<String> Function(String message) signer;

    setUpAll(() async {
      // without the dylib the whole group is skipped; do not attempt init
      if (!ffiConfigured) {
        return;
      }
      await RustLib.init();
      final setupResult = SpWallet.setupWallet(
        setupArgs: const WalletSetupArgs(
          setupType: WalletSetupType.newWallet(),
          network: Network.testnet3,
        ),
      );
      wallet = SpWallet(
        scanKey: setupResult.scanKey,
        spendKey: setupResult.spendKey,
        network: Network.testnet3,
      );
      paymentCode = wallet.getReceivingAddress();
      spCode = paymentCode.encode();
      signer = (message) async =>
          wallet.signRegistrationChallenge(message: message);
    });

    DanaAddressService serviceWith(FakeNameServer ns) {
      final service = DanaAddressService(network: Network.testnet3);
      service.nameServerRepository.baseUrl = 'http://ns.test';
      service.nameServerRepository.client = () => ns.toClient(spCode);
      // no real sleeps under test except where a countdown is asserted
      service.rateLimitBackoffSeconds = [0, 0, 0];
      return service;
    }

    test('happy path reports challenging, confirmation, confirming',
        () async {
      final ns = FakeNameServer();
      final service = serviceWith(ns);
      final flow = RecordingFlow();

      final registered = await service.registerUser(
        username: username,
        paymentCode: paymentCode,
        signChallenge: signer,
        flow: flow,
      );
      expect(registered.username, username);

      expect(flow.events.map((e) => e.toString()).toList(), [
        'challenging',
        'challengeReceived ${ns.nonceFor(1)} rem=300',
        'confirming',
      ]);
      // the approval was captured against the exact challenge registered
      expect(ns.registerBody(0)['nonce'], ns.nonceFor(1));
    }, skip: !ffiConfigured ? ffiSkipReason : false);

    test('withheld approval aborts before /register', () async {
      final ns = FakeNameServer();
      final service = serviceWith(ns);
      final flow = RecordingFlow()..approve = false;

      await expectLater(
        service.registerUser(
          username: username,
          paymentCode: paymentCode,
          signChallenge: signer,
          flow: flow,
        ),
        throwsA(isA<RegistrationAbortedException>()),
      );
      expect(ns.callsTo('POST', '/register'), isEmpty);
      expect(ns.callsTo('POST', '/challenge'), hasLength(1));
    }, skip: !ffiConfigured ? ffiSkipReason : false);

    test('re-sign retry and proactive TTL re-challenge visibly reset the '
        'confirmation', () async {
      final ns = FakeNameServer()
        ..registerResponses.addAll([
          () => registerReject('signature_invalid'),
          () => registerOk(spCode),
        ]);
      final service = serviceWith(ns);

      // scripted clock: receipt t0; the third clock() read (after the
      // re-sign continue) is 280 s later, inside the 30 s refresh margin.
      final t0 = DateTime.parse('2026-11-18T12:00:00Z');
      var clockReads = 0;
      service.clock = () {
        final read = clockReads++;
        return read < 2 ? t0 : t0.add(const Duration(seconds: 280));
      };

      final flow = RecordingFlow();
      final registered = await service.registerUser(
        username: username,
        paymentCode: paymentCode,
        signChallenge: signer,
        flow: flow,
      );
      expect(registered.username, username);

      expect(flow.events.map((e) => e.toString()).toList(), [
        'challenging',
        'challengeReceived ${ns.nonceFor(1)} rem=300',
        'confirming',
        'retrying signature_invalid cd=0 1/1',
        'confirmationReset',
        'challenging',
        'challengeReceived ${ns.nonceFor(2)} rem=300',
        'confirming',
      ]);
      expect(ns.challengeCalls, 2);
      // the registered nonce matches the challenge the user approved LAST
      expect(ns.registerBody(1)['nonce'], ns.nonceFor(2));
    }, skip: !ffiConfigured ? ffiSkipReason : false);

    test('nonce-class refresh renders retrying then a reset confirmation',
        () async {
      final ns = FakeNameServer()
        ..registerResponses.addAll([
          () => registerReject('nonce_expired'),
          () => registerOk(spCode),
        ]);
      final service = serviceWith(ns);
      final flow = RecordingFlow();

      await service.registerUser(
        username: username,
        paymentCode: paymentCode,
        signChallenge: signer,
        flow: flow,
      );

      expect(flow.events.map((e) => e.toString()).toList(), [
        'challenging',
        'challengeReceived ${ns.nonceFor(1)} rem=300',
        'confirming',
        'retrying nonce_expired cd=0 1/1',
        'confirmationReset',
        'challenging',
        'challengeReceived ${ns.nonceFor(2)} rem=300',
        'confirming',
      ]);
      expect(ns.registerBody(1)['nonce'], ns.nonceFor(2));
    }, skip: !ffiConfigured ? ffiSkipReason : false);

    test('rate_limited backoff renders the retrying state with the '
        'Retry-After countdown (challenge path)', () async {
      final ns = FakeNameServer();
      ns.challengeResponses.addAll([
        () => rateLimited(1),
        () => challengeOk(spCode, ns.nonceFor(2)),
      ]);
      final service = serviceWith(ns);
      final flow = RecordingFlow();

      await service.registerUser(
        username: username,
        paymentCode: paymentCode,
        signChallenge: signer,
        flow: flow,
      );

      expect(flow.events.map((e) => e.toString()).toList(), [
        'challenging',
        'retrying rate_limited cd=1 1/3',
        'challenging',
        'challengeReceived ${ns.nonceFor(2)} rem=300',
        'confirming',
      ]);
    }, skip: !ffiConfigured ? ffiSkipReason : false);

    test('rate_limited backoff renders the retrying state with the '
        'Retry-After countdown (register path)', () async {
      final ns = FakeNameServer()
        ..registerResponses.addAll([
          () => rateLimited(0),
          () => registerOk(spCode),
        ]);
      final service = serviceWith(ns);
      final flow = RecordingFlow();

      await service.registerUser(
        username: username,
        paymentCode: paymentCode,
        signChallenge: signer,
        flow: flow,
      );

      expect(flow.events.map((e) => e.toString()).toList(), [
        'challenging',
        'challengeReceived ${ns.nonceFor(1)} rem=300',
        'confirming',
        'retrying rate_limited cd=0 1/3',
        // the loop re-enters at the confirmation gate after the backoff
        'challengeReceived ${ns.nonceFor(1)} rem=300',
        'confirming',
      ]);
      expect(ns.registerCalls, 2);
    }, skip: !ffiConfigured ? ffiSkipReason : false);

    test('exhaustion is terminal with no auto third attempt; a controller '
        'restart re-enters with fresh budgets', () async {
      final ns = FakeNameServer()
        ..registerResponses.addAll(
            List.generate(4, (i) => () => rateLimited(0)));
      final service = serviceWith(ns);

      final controller = RegistrationController(
        runner: (flow) => service.registerUser(
          username: username,
          paymentCode: paymentCode,
          signChallenge: signer,
          flow: flow,
        ),
      );
      autoConfirm(controller);

      await controller.start();
      final state = controller.state;
      expect(state, isA<RegistrationTerminal>());
      expect((state as RegistrationTerminal).category.label, 'Rate limited');
      // initial attempt + 3 budgeted retries; no automatic 5th call
      expect(ns.registerCalls, 4);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ns.registerCalls, 4);

      // the queue is drained: a restart runs with FRESH budgets and
      // succeeds against the default success route.
      await controller.restart();
      expect(controller.state, isA<RegistrationSuccess>());
      expect(ns.registerCalls, 5);
      controller.dispose();
    }, skip: !ffiConfigured ? ffiSkipReason : false);
  });
}
