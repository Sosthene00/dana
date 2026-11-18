// WT-02 (t_7efd3024) acceptance tests for the spec sections 4-7 registration
// flow in [DanaAddressService.registerUser]:
//
// - D3: the retry matrix branches on machine-readable codes only; the prose
//   classifier is deleted outright (grep-clean is asserted by CI-less review,
//   the service file no longer contains any phrase list).
// - D6: expiry is TTL-from-receipt (300 s), proactive re-challenge inside the
//   30 s remaining margin, expires_at display-only and never compared to the
//   client clock.
// - D10: already-registered self-match confirmed by the machine-readable
//   nameserver /lookup check, not local DNS inference; username_taken is a
//   distinct terminal code for the first-commit-wins race loser.
// - D12: the flow fail-closes without the challenge-auth:v1 capability from
//   /info, before the first /challenge call.
//
// HTTP layer: MockClient through the repository's `client` seam. Signing:
// the REAL wallet-held FFI signer (SpWallet.signRegistrationChallenge) —
// the same surface the app uses — so the signatures in the recorded
// /register bodies are genuine BIP-340 signatures produced with fresh aux
// randomness. The FFI-dependent groups are skipped unless the bridge dylib
// is made loadable via FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR.
import 'dart:convert';
import 'dart:io';

import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/generated/rust/api/structs/silent_payment_code.dart';
import 'package:danawallet/generated/rust/api/wallet.dart';
import 'package:danawallet/generated/rust/api/wallet/setup.dart';
import 'package:danawallet/generated/rust/frb_generated.dart';
import 'package:danawallet/repositories/name_server_repository.dart';
import 'package:danawallet/services/dana_address_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

const String username = 'alice';
const String domain = 'danawallet.app';
const String networkKey = 'tsp'; // pinned testnet key (D7)

final bool ffiConfigured =
    Platform.environment['FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR'] !=
        null;
const String ffiSkipReason =
    'FFI bridge not configured; set FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR '
    'to a directory containing librust_lib_danawallet.so';

Response _json(Object body,
        {int status = 200, Map<String, String> headers = const {}}) =>
    Response(jsonEncode(body), status,
        headers: {...headers, 'content-type': 'application/json'});

/// Scripted name server: default routes for /info, /lookup, /challenge and
/// /register, overridable via response queues; records every request.
class FakeNameServer {
  final requests = <Request>[];

  List<String> capabilities = const ['challenge-auth:v1'];
  String infoDomain = domain;
  List<String> ownedAddresses = const [];
  String lookupMessage = 'ok';

  /// Scripted POST /challenge outcomes, consumed in order (last repeats).
  final List<Response Function()> challengeResponses = [];

  /// Scripted POST /register outcomes, consumed in order (last repeats).
  final List<Response Function()> registerResponses = [];

  int challengeCalls = 0;
  int registerCalls = 0;

  /// 64-char lowercase-hex nonce, distinct per challenge call (spec grammar).
  String nonceFor(int i) => 'ab' * 30 + i.toRadixString(16).padLeft(4, '0');

  String challengeMessage(String nonce, String spCode) =>
      'dana-register:v1:$networkKey:$nonce:$username:$domain:$spCode';

  Future<Response> dispatch(Request request, String spCode) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET' && path == '/info') {
      return _json({
        'domain': infoDomain,
        'network': 'testnet',
        'capabilities': capabilities,
      });
    }
    if (request.method == 'GET' && path == '/lookup') {
      return _json({
        'id': 'req',
        'message': lookupMessage,
        'dana_addresses': ownedAddresses,
        'sp_address': spCode,
      });
    }
    if (request.method == 'POST' && path == '/challenge') {
      challengeCalls++;
      if (challengeResponses.isNotEmpty) {
        return challengeResponses.removeAt(0)();
      }
      final nonce = nonceFor(challengeCalls);
      return _json({
        'id': 'req',
        'message': challengeMessage(nonce, spCode),
        'nonce': nonce,
        'network_key': networkKey,
        'expires_at': 4000000000, // display-only; never read by the flow
      });
    }
    if (request.method == 'POST' && path == '/register') {
      registerCalls++;
      if (registerResponses.isNotEmpty) {
        return registerResponses.removeAt(0)();
      }
      return _json({
        'id': 'req',
        'message': 'registered',
        'dana_address': '$username@$domain',
        'sp_address': spCode,
        'dns_record_id': null,
      });
    }
    return _json({'message': 'unrouted'}, status: 500);
  }

  MockClient toClient(String spCode) =>
      MockClient((request) => dispatch(request, spCode));

  List<Request> callsTo(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path).toList();

  /// The JSON body of the n-th (0-based) POST /register request.
  Map<String, dynamic> registerBody(int n) =>
      jsonDecode(callsTo('POST', '/register')[n].body) as Map<String, dynamic>;
}

void main() {
  group('D6 expiry math (pure, no FFI)', () {
    test('receipt-relative countdown: 300 s TTL from receipt', () {
      final t0 = DateTime.parse('2026-11-18T12:00:00Z');
      expect(
        challengeRemainingSeconds(receivedAt: t0, now: t0),
        300,
      );
      expect(
        challengeRemainingSeconds(
            receivedAt: t0, now: t0.add(const Duration(seconds: 299))),
        1,
      );
      expect(
        challengeRemainingSeconds(
            receivedAt: t0, now: t0.add(const Duration(seconds: 301))),
        -1,
      );
    });

    test('30 s proactive refresh threshold boundary', () {
      // <= 30 s remaining => re-challenge; 31 s => keep the challenge.
      expect(shouldRechallenge(30), isTrue);
      expect(shouldRechallenge(29), isTrue);
      expect(shouldRechallenge(0), isTrue);
      expect(shouldRechallenge(-5), isTrue);
      expect(shouldRechallenge(31), isFalse);
      expect(shouldRechallenge(300), isFalse);
    });
  });

  group('registration flow (FFI signer + scripted name server)', () {
    late SpWallet wallet;
    late SilentPaymentCode paymentCode;
    late String spCode;
    late Future<String> Function(String message) signer;

    setUpAll(() async {
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
      signer =
          (message) async => wallet.signRegistrationChallenge(message: message);
    });

    DanaAddressService serviceWith(FakeNameServer ns) {
      final service = DanaAddressService(network: Network.testnet3);
      service.nameServerRepository.baseUrl = 'http://ns.test';
      service.nameServerRepository.client = () => ns.toClient(spCode);
      // No real sleeps under test; the Retry-After honoring is asserted via
      // the header value itself (also 0 s here).
      service.rateLimitBackoffSeconds = [0, 0, 0];
      return service;
    }

    test('D12: missing capability aborts the flow before /challenge', () async {
      final ns = FakeNameServer()..capabilities = const ['other:v9'];
      final service = serviceWith(ns);

      await expectLater(
        service.registerUser(
          username: username,
          paymentCode: paymentCode,
          signChallenge: signer,
        ),
        throwsA(isA<ChallengeAuthUnavailableException>()),
      );
      expect(ns.callsTo('POST', '/challenge'), isEmpty,
          reason: 'fail-closed gate must fire before the first /challenge');
      expect(ns.callsTo('POST', '/register'), isEmpty);
    });

    test('D12: absent capabilities list fails closed before /challenge',
        () async {
      final ns = FakeNameServer()..capabilities = const [];
      final service = serviceWith(ns);

      await expectLater(
        service.registerUser(
          username: username,
          paymentCode: paymentCode,
          signChallenge: signer,
        ),
        throwsA(isA<ChallengeAuthUnavailableException>()),
      );
      expect(ns.callsTo('POST', '/challenge'), isEmpty);
    });

    test('happy path: one complete registration with a real signature',
        () async {
      final ns = FakeNameServer();
      final service = serviceWith(ns);

      final registered = await service.registerUser(
        username: username,
        paymentCode: paymentCode,
        signChallenge: signer,
      );

      expect(registered.username, username);
      expect(registered.domain, domain);
      expect(ns.challengeCalls, 1);
      expect(ns.registerCalls, 1);

      final body = ns.registerBody(0);
      expect(body['user_name'], username);
      expect(body['domain'], domain);
      expect(body['sp_address'], spCode);
      expect(body['nonce'], ns.nonceFor(1));
      // BIP-340 signature over SHA-256(message): 64 bytes lowercase hex.
      final signature = body['signature'] as String;
      expect(signature, matches(RegExp(r'^[0-9a-f]{128}$')));
    });

    test(
        'D10: already-registered self-match confirmed by the nameserver '
        'check, no /challenge and no /register', () async {
      final ns = FakeNameServer()..ownedAddresses = ['$username@$domain'];
      final service = serviceWith(ns);

      final registered = await service.registerUser(
        username: username,
        paymentCode: paymentCode,
        signChallenge: signer,
      );

      expect(registered.username, username);
      expect(ns.callsTo('POST', '/challenge'), isEmpty,
          reason: 'self-match must come from the machine-readable /lookup '
              'answer, never by attempting the flow');
      expect(ns.callsTo('POST', '/register'), isEmpty);
    });

    test(
        'D10: our payment code owning OTHER names does not block '
        'registering a new one', () async {
      final ns = FakeNameServer()..ownedAddresses = ['othername@$domain'];
      final service = serviceWith(ns);

      final registered = await service.registerUser(
        username: username,
        paymentCode: paymentCode,
        signChallenge: signer,
      );
      expect(registered.username, username);
      expect(ns.challengeCalls, 1);
      expect(ns.registerCalls, 1);
    });

    test('D6: expires_at in the past is ignored for decisions (display-only)',
        () async {
      final ns = FakeNameServer();
      // The default scripted challenge carries expires_at = 4000000000
      // (year 2096); here make it absurdly STALE — the flow must still
      // sign it without a re-challenge because the countdown is
      // receipt-relative, not expires_at-based.
      final stale = _json({
        'id': 'req',
        'message': ns.challengeMessage(ns.nonceFor(1), spCode),
        'nonce': ns.nonceFor(1),
        'network_key': networkKey,
        'expires_at': 1000,
      });
      ns.challengeResponses.add(() => stale);
      final service = serviceWith(ns);

      final registered = await service.registerUser(
        username: username,
        paymentCode: paymentCode,
        signChallenge: signer,
      );
      expect(registered.username, username);
      expect(ns.challengeCalls, 1,
          reason: 'a fresh receipt must win over a stale expires_at');
    });

    test('D6: proactive re-challenge inside the 30 s remaining margin',
        () async {
      final ns = FakeNameServer()
        ..registerResponses.addAll([
          // First register attempt fails on the signature; by the time the
          // flow comes around again, the fake clock says only 29 s remain
          // of the receipt-relative TTL -> the flow must re-challenge.
          () =>
              _json({'id': 'req', 'message': 'signature_invalid'}, status: 401),
        ]);
      final service = serviceWith(ns);

      final t0 = DateTime.parse('2026-11-18T12:00:00Z');
      var now = t0;
      service.clock = () => now;
      var registerSeen = 0;
      service.nameServerRepository.client = () => MockClient((request) async {
            final response = await ns.dispatch(request, spCode);
            if (request.url.path == '/register' && request.method == 'POST') {
              registerSeen++;
              if (registerSeen == 1) {
                now = t0.add(const Duration(seconds: 271));
              } else {
                now = t0;
              }
            }
            return response;
          });

      final registered = await service.registerUser(
        username: username,
        paymentCode: paymentCode,
        signChallenge: signer,
      );
      expect(registered.username, username);
      expect(ns.challengeCalls, 2,
          reason: '29 s remaining is inside the 30 s margin: the flow must '
              're-challenge before burning a signature on a doomed nonce');
      // The successful register carried the SECOND challenge's nonce.
      expect(ns.registerBody(1)['nonce'], ns.nonceFor(2));
    });

    test(
        'D3: signature_invalid allows exactly one re-sign of the SAME '
        'challenge, then succeeds', () async {
      final ns = FakeNameServer()
        ..registerResponses.addAll([
          () =>
              _json({'id': 'req', 'message': 'signature_invalid'}, status: 401),
        ]);
      final service = serviceWith(ns);

      final registered = await service.registerUser(
        username: username,
        paymentCode: paymentCode,
        signChallenge: signer,
      );
      expect(registered.username, username);

      expect(ns.registerCalls, 2);
      expect(ns.challengeCalls, 1,
          reason: 'verify-before-burn: no fresh challenge on a pure '
              'signature failure');
      // Same nonce both times: the same challenge was re-signed.
      expect(ns.registerBody(0)['nonce'], ns.registerBody(1)['nonce']);
      // Fresh aux rand (D9) => the two signatures differ.
      expect(ns.registerBody(0)['signature'],
          isNot(ns.registerBody(1)['signature']));
    });

    test(
        'D3: two consecutive signature_invalid rejections exhaust the '
        'budget and rethrow terminal', () async {
      final ns = FakeNameServer()
        ..registerResponses.addAll(List.generate(
            2,
            (_) => () => _json({'id': 'req', 'message': 'signature_invalid'},
                status: 401)));
      final service = serviceWith(ns);

      await expectLater(
        service.registerUser(
          username: username,
          paymentCode: paymentCode,
          signChallenge: signer,
        ),
        throwsA(isA<RegisterRejectedException>()),
      );
      final rejected = ns.registerBody(0)['signature'] != null;
      expect(rejected, isTrue);
      expect(ns.registerCalls, 2);
      expect(ns.challengeCalls, 1);
    });

    test('D3: nonce-class code allows one fresh challenge, then succeeds',
        () async {
      for (final code in ['nonce_expired', 'nonce_mismatch', 'nonce_unknown']) {
        final ns = FakeNameServer()
          ..registerResponses.addAll([
            () => _json({'id': 'req', 'message': code}, status: 401),
          ]);
        final service = serviceWith(ns);

        final registered = await service.registerUser(
          username: username,
          paymentCode: paymentCode,
          signChallenge: signer,
        );
        expect(registered.username, username, reason: code);
        expect(ns.registerCalls, 2, reason: code);
        expect(ns.challengeCalls, 2, reason: '$code: one fresh challenge');
        // The retry carried the NEW nonce from the fresh challenge.
        expect(ns.registerBody(1)['nonce'], ns.nonceFor(2), reason: code);
      }
    });

    test('D3: nonce-class exhaustion rethrows terminal', () async {
      final ns = FakeNameServer()
        ..registerResponses.addAll(List.generate(
            2,
            (_) => () =>
                _json({'id': 'req', 'message': 'nonce_expired'}, status: 401)));
      final service = serviceWith(ns);

      await expectLater(
        service.registerUser(
          username: username,
          paymentCode: paymentCode,
          signChallenge: signer,
        ),
        throwsA(isA<RegisterRejectedException>()),
      );
      expect(ns.challengeCalls, 2);
      expect(ns.registerCalls, 2);
    });

    test(
        'D3: rate_limited honors Retry-After (header present) with at '
        'most 3 retries, then succeeds', () async {
      final ns = FakeNameServer()
        ..registerResponses.addAll([
          () => _json({'id': 'req', 'message': 'rate_limited'},
              status: 429, headers: {'retry-after': '0'}),
          () => _json({'id': 'req', 'message': 'rate_limited'},
              status: 429, headers: {'retry-after': '0'}),
          () => _json({'id': 'req', 'message': 'rate_limited'},
              status: 429, headers: {'retry-after': '0'}),
        ]);
      final service = serviceWith(ns);

      final registered = await service.registerUser(
        username: username,
        paymentCode: paymentCode,
        signChallenge: signer,
      );
      expect(registered.username, username);
      expect(ns.registerCalls, 4, reason: '3 backoff retries then success');
    });

    test(
        'D3: rate_limited without Retry-After falls back to the local '
        '2/5/15 schedule', () async {
      final ns = FakeNameServer()
        ..registerResponses.addAll([
          () => _json({'id': 'req', 'message': 'rate_limited'}, status: 429),
          () => _json({'id': 'req', 'message': 'rate_limited'}, status: 429),
          () => _json({'id': 'req', 'message': 'rate_limited'}, status: 429),
        ]);
      final service = serviceWith(ns);

      final registered = await service.registerUser(
        username: username,
        paymentCode: paymentCode,
        signChallenge: signer,
      );
      expect(registered.username, username);
      expect(ns.registerCalls, 4);
    });

    test('D3: rate_limited budget exhaustion rethrows terminal', () async {
      final ns = FakeNameServer()
        ..registerResponses.addAll(List.generate(
            4,
            (_) => () => _json({'id': 'req', 'message': 'rate_limited'},
                status: 429, headers: {'retry-after': '0'})));
      final service = serviceWith(ns);

      await expectLater(
        service.registerUser(
          username: username,
          paymentCode: paymentCode,
          signChallenge: signer,
        ),
        throwsA(isA<RegisterRejectedException>()),
      );
      expect(ns.registerCalls, 4);
    });

    test(
        'D3: /challenge rate_limited backs off per Retry-After then '
        'succeeds (status-derived code, no prose matching)', () async {
      final ns = FakeNameServer()
        ..challengeResponses.addAll([
          () => _json({'id': 'req', 'message': 'Too many pending challenges'},
              status: 429, headers: {'retry-after': '0'}),
        ]);
      final service = serviceWith(ns);

      final registered = await service.registerUser(
        username: username,
        paymentCode: paymentCode,
        signChallenge: signer,
      );
      expect(registered.username, username);
      expect(ns.challengeCalls, 2);
    });

    test('D3: /challenge rate_limited exhaustion rethrows terminal', () async {
      final ns = FakeNameServer()
        ..challengeResponses.addAll(List.generate(
            4,
            (_) => () => _json({'id': 'req', 'message': 'Too many pending'},
                status: 429, headers: {'retry-after': '0'})));
      final service = serviceWith(ns);

      await expectLater(
        service.registerUser(
          username: username,
          paymentCode: paymentCode,
          signChallenge: signer,
        ),
        throwsA(isA<ChallengeRejectedException>()),
      );
      expect(ns.challengeCalls, 4);
      expect(ns.callsTo('POST', '/register'), isEmpty);
    });

    test(
        'D10: username_taken is terminal and surfaces the distinct code '
        '(first-commit-wins loser)', () async {
      final ns = FakeNameServer()
        ..registerResponses.add(() => _json({
              'id': 'req',
              'message': 'username_taken',
              'dana_address': '$username@$domain',
              'sp_address': spCode,
              'dns_record_id': null,
            }, status: 409));
      final service = serviceWith(ns);

      RegisterRejectedException? caught;
      try {
        await service.registerUser(
          username: username,
          paymentCode: paymentCode,
          signChallenge: signer,
        );
        fail('username_taken must not succeed');
      } on RegisterRejectedException catch (e) {
        caught = e;
      }
      expect(caught.code, NameServerErrorCode.usernameTaken);
      expect(ns.registerCalls, 1,
          reason: 'terminal: no retry after losing the race');
    });

    test('D3: unknown and unrecognized codes are terminal (no retry)',
        () async {
      for (final message in ['unknown', 'some-future-code-not-in-the-spec']) {
        final ns = FakeNameServer()
          ..registerResponses
              .add(() => _json({'id': 'req', 'message': message}, status: 400));
        final service = serviceWith(ns);

        await expectLater(
          service.registerUser(
            username: username,
            paymentCode: paymentCode,
            signChallenge: signer,
          ),
          throwsA(isA<RegisterRejectedException>()),
        );
        expect(ns.registerCalls, 1, reason: message);
      }
    });

    test('D3: username_invalid is terminal (no retry)', () async {
      final ns = FakeNameServer()
        ..registerResponses.add(() =>
            _json({'id': 'req', 'message': 'username_invalid'}, status: 400));
      final service = serviceWith(ns);

      await expectLater(
        service.registerUser(
          username: username,
          paymentCode: paymentCode,
          signChallenge: signer,
        ),
        throwsA(isA<RegisterRejectedException>()),
      );
      expect(ns.registerCalls, 1);
    });

    test('D7: regtest network fails closed with no HTTP traffic', () async {
      final ns = FakeNameServer();
      final service = DanaAddressService(network: Network.regtest);
      service.nameServerRepository.baseUrl = 'http://ns.test';
      service.nameServerRepository.client = () => ns.toClient(spCode);

      await expectLater(
        service.registerUser(
          username: username,
          paymentCode: paymentCode,
          signChallenge: signer,
        ),
        throwsA(isA<StateError>()),
      );
      expect(ns.callsTo('POST', '/challenge'), isEmpty);
    });

    test('D5: a tampered challenge message never reaches the signer', () async {
      final ns = FakeNameServer();
      final tamperedMessage =
          'dana-register:v1:$networkKey:${ns.nonceFor(1)}:mallory'
          ':$domain:$spCode';
      ns.challengeResponses.add(() => _json({
            'id': 'req',
            'message': tamperedMessage,
            'nonce': ns.nonceFor(1),
            'network_key': networkKey,
            'expires_at': 4000000000,
          }));
      final service = serviceWith(ns);

      await expectLater(
        service.registerUser(
          username: username,
          paymentCode: paymentCode,
          signChallenge: signer,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(ns.callsTo('POST', '/register'), isEmpty);
    });

    test(
        'D7: a challenge carrying a foreign network_key is rejected before '
        'signing', () async {
      final ns = FakeNameServer();
      final foreignKeyMessage = ns
          .challengeMessage(ns.nonceFor(1), spCode)
          .replaceFirst(':tsp:', ':sp:');
      ns.challengeResponses.add(() => _json({
            'id': 'req',
            // honest fields EXCEPT the message embeds the mainnet key
            'message': foreignKeyMessage,
            'nonce': ns.nonceFor(1),
            'network_key': networkKey,
            'expires_at': 4000000000,
          }));
      final service = serviceWith(ns);

      await expectLater(
        service.registerUser(
          username: username,
          paymentCode: paymentCode,
          signChallenge: signer,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(ns.callsTo('POST', '/register'), isEmpty);
    });
  }, skip: ffiConfigured ? false : ffiSkipReason);
}
