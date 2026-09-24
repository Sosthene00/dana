import 'dart:convert';

import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/repositories/name_server_repository.dart';
import 'package:danawallet/services/bip353_resolver.dart';
import 'package:danawallet/services/dana_address_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

class _Call {
  _Call(this.method, this.path, this.body);

  final String method;
  final String path;
  final Map<String, dynamic> body;
}

/// Recorded HTTP traffic against the fake name server (MockClient from the
/// existing `http` dependency — `package:http/testing.dart`; no new
/// dev_dependency required). Injected through the repository's `client`
/// seam: the smallest change that intercepts the formerly inline
/// `http.Client()` construction.
class _Recorded {
  final List<_Call> calls = [];

  void add(String method, Uri url, String? body) {
    calls.add(_Call(
      method,
      url.pathSegments.last,
      (body == null || body.isEmpty)
          ? <String, dynamic>{}
          : jsonDecode(body) as Map<String, dynamic>,
    ));
  }

  List<String> get pathSequence => calls.map((c) => c.path).toList();

  List<Map<String, dynamic>> get registerBodies =>
      calls.where((c) => c.path == 'register').map((c) => c.body).toList();
}

typedef _Handler = Future<Response> Function(Request request);

/// Builds the fake name server. [queues] maps a path (e.g. "challenge",
/// "register") to a queue of handlers consumed in order; while the queue
/// holds more than one entry the head is popped, otherwise the last entry
/// repeats. The `/info` route answers with a fixed domain by default
/// (`danaAddressDomain` lazy-fetches it before the handshake).
NameServerRepository _repoWith(
  Map<String, List<_Handler>> queues,
  _Recorded recorded,
) {
  final repo = NameServerRepository(network: Network.signet);
  queues.putIfAbsent('info', () => [
        _json(200, {'domain': 'dana.example', 'network': 'signet'})
      ]);
  final client = MockClient((request) async {
    final path = request.url.pathSegments.last;
    final body = utf8.decode(request.bodyBytes);
    recorded.add(request.method, request.url, body);
    final queue = queues[path]!;
    final handler = queue.length > 1 ? queue.removeAt(0) : queue.first;
    return handler(request);
  });
  repo.client = () => client;
  return repo;
}

_Handler _json(int status, Map<String, dynamic> body) => (request) async =>
    Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

_Handler _raw(int status, String body) =>
    (request) async => Response(body, status);

const String _username = 'alice-1';
const String _paymentCode = 'sp1qqernutv8ar5g7m2x';

/// Success-shaped register handler (server echoes the claimed address;
/// parsed by NameServerRegisterResponse.fromJson via the repository).
_Handler _registerOk() => (request) async => Response(
      '{"id":"r1","message":"ok","dana_address":"$_username@dana.example","sp_address":"$_paymentCode"}',
      200,
      headers: {'content-type': 'application/json'},
    );

/// The production signer seam is the `Future<String> Function(String)`
/// parameter of `registerUser`; `WalletState.signChallenge` is the thin
/// delegate onto the Rust bridge
/// (`wallet.signRegistrationChallenge(message:)`,
/// lib/generated/rust/api/wallet.dart). Tests inject a pure-Dart fake at
/// exactly that wrapper boundary — the bridge stubs there, so no FFI loads.
Future<String> Function(String message) _signerReturning(
  String signature,
  List<String> signedMessages,
) {
  return (message) async {
    signedMessages.add(message);
    return signature;
  };
}

void main() {
  setUp(() {
    // No address exists yet: registerUser proceeds to the challenge flow.
    Bip353Resolver.resolveOverride = (address, network) async => null;
  });

  tearDown(() {
    Bip353Resolver.resolveOverride = null;
  });

  group('registerUser challenge handshake', () {
    test('happy path: challenge -> sign -> register once, body carries proof',
        () async {
      final recorded = _Recorded();
      final repo = _repoWith({
        'challenge': [
          _json(200, {
            'message': 'sign-this-msg-1',
            'nonce': 'nonce-aaa',
            'expires_at': 9999999999,
          })
        ],
        'register': [_registerOk()],
      }, recorded);
      final service = DanaAddressService(network: Network.signet)
        ..nameServerRepository = repo;

      final signed = <String>[];
      final result = await service.registerUser(
        username: _username,
        paymentCode: _paymentCode,
        signChallenge: _signerReturning('deadbeef', signed),
      );

      expect(result.username, _username);
      // Request ORDER and COUNTS: domain lookup, then exactly one challenge,
      // then exactly one register.
      expect(recorded.pathSequence, ['info', 'challenge', 'register']);
      expect(recorded.calls.map((c) => c.method).toList(),
          ['GET', 'POST', 'POST']);
      // The signed message is the server-issued challenge verbatim.
      expect(signed, ['sign-this-msg-1']);
      // Register body carries nonce + signature proof fields.
      final registerBody = recorded.registerBodies.single;
      expect(registerBody['nonce'], 'nonce-aaa');
      expect(registerBody['signature'], 'deadbeef');
      expect(registerBody['user_name'], _username);
      expect(registerBody['sp_address'], _paymentCode);
    });

    test(
        '401 bad signature => exactly one re-sign retry, SAME nonce (not re-challenged)',
        () async {
      final recorded = _Recorded();
      final repo = _repoWith({
        'challenge': [
          _json(200, {
            'message': 'msg-x',
            'nonce': 'nonce-keep',
            'expires_at': 9999999999,
          })
        ],
        'register': [
          _json(401, {'message': 'Signature verification failed'}),
          _registerOk(),
        ],
      }, recorded);
      final service = DanaAddressService(network: Network.signet)
        ..nameServerRepository = repo;

      final signed = <String>[];
      await service.registerUser(
        username: _username,
        paymentCode: _paymentCode,
        signChallenge: _signerReturning('sig2', signed),
      );

      // One challenge only (NOT re-challenged), two registers (verify-before-
      // burn: a pure signature failure does not burn the nonce).
      expect(recorded.pathSequence,
          ['info', 'challenge', 'register', 'register']);
      expect(signed, ['msg-x', 'msg-x']); // same message re-signed, once
      final registers = recorded.registerBodies;
      expect(registers[0]['nonce'], 'nonce-keep');
      expect(registers[1]['nonce'], 'nonce-keep'); // SAME nonce re-presented
      expect(registers[1]['signature'], 'sig2');
    });

    test('401 expired nonce => one re-challenge, new nonce used', () async {
      final recorded = _Recorded();
      final repo = _repoWith({
        'challenge': [
          _json(200, {
            'message': 'msg-old',
            'nonce': 'nonce-old',
            'expires_at': 9999999999,
          }),
          _json(200, {
            'message': 'msg-new',
            'nonce': 'nonce-new',
            'expires_at': 9999999999,
          }),
        ],
        'register': [
          _json(401, {'message': 'Challenge nonce expired'}),
          _registerOk(),
        ],
      }, recorded);
      final service = DanaAddressService(network: Network.signet)
        ..nameServerRepository = repo;

      final signed = <String>[];
      await service.registerUser(
        username: _username,
        paymentCode: _paymentCode,
        signChallenge: _signerReturning('sig3', signed),
      );

      // challenge, register(expired), challenge again, register with NEW nonce.
      expect(recorded.pathSequence,
          ['info', 'challenge', 'register', 'challenge', 'register']);
      final registers = recorded.registerBodies;
      expect(registers[0]['nonce'], 'nonce-old');
      expect(registers[1]['nonce'], 'nonce-new');
      // New challenge => the new server message is the one signed second.
      expect(signed, ['msg-old', 'msg-new']);
    });

    test(
        '429 on challenge => backoff then re-challenge; cap 3 then server msg',
        () async {
      final recorded = _Recorded();
      final repo = _repoWith({
        'challenge': [
          _json(429, {'message': 'slow down please'}),
          _json(429, {'message': 'slow down please'}),
          _json(429, {'message': 'slow down please'}),
          _json(429, {'message': 'slow down please'}), // 4th: cap exhausted
        ],
        'register': [_registerOk()], // must never be reached
      }, recorded);
      final service = DanaAddressService(network: Network.signet)
        ..nameServerRepository = repo;

      final signed = <String>[];
      Object? error;
      try {
        await service.registerUser(
          username: _username,
          paymentCode: _paymentCode,
          signChallenge: _signerReturning('x', signed),
        );
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull);
      // Give up after the 3-entry backoff schedule (2s/5s/15s): 4 challenge
      // attempts total, register never reached, server message surfaced.
      expect(recorded.pathSequence,
          ['info', 'challenge', 'challenge', 'challenge', 'challenge']);
      expect(error.toString(), contains('slow down please'));
      expect(signed, isEmpty);
    });

    test(
        'proactive expiry: expires_at <= now+10 re-challenges before register',
        () async {
      final recorded = _Recorded();
      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final repo = _repoWith({
        'challenge': [
          // First challenge already inside the 10 s safety margin.
          _json(200, {
            'message': 'msg-stale',
            'nonce': 'nonce-stale',
            'expires_at': nowSec + 5,
          }),
          _json(200, {
            'message': 'msg-fresh',
            'nonce': 'nonce-fresh',
            'expires_at': nowSec + 300,
          }),
        ],
        'register': [_registerOk()],
      }, recorded);
      final service = DanaAddressService(network: Network.signet)
        ..nameServerRepository = repo;

      final signed = <String>[];
      await service.registerUser(
        username: _username,
        paymentCode: _paymentCode,
        signChallenge: _signerReturning('sig5', signed),
      );

      // Stale nonce must never reach the server: two challenges, ONE register,
      // and the stale message is never signed.
      expect(recorded.pathSequence,
          ['info', 'challenge', 'challenge', 'register']);
      expect(recorded.registerBodies.single['nonce'], 'nonce-fresh');
      expect(signed, ['msg-fresh']);
    });

    test('401 with unparseable body => error surfaced, no crash', () async {
      final recorded = _Recorded();
      final repo = _repoWith({
        'challenge': [
          _json(200, {
            'message': 'msg-e',
            'nonce': 'nonce-e',
            'expires_at': 9999999999,
          })
        ],
        'register': [_raw(401, '<<not json at all>>')],
      }, recorded);
      final service = DanaAddressService(network: Network.signet)
        ..nameServerRepository = repo;

      final signed = <String>[];
      Object? error;
      try {
        await service.registerUser(
          username: _username,
          paymentCode: _paymentCode,
          signChallenge: _signerReturning('sigE', signed),
        );
      } catch (e) {
        error = e;
      }
      // The raw body surfaces as the exception message (no JSON crash, no
      // silent retry loop): exactly one challenge and one register.
      expect(error, isA<RegisterRejectedException>());
      expect((error as RegisterRejectedException).status, 401);
      expect((error as RegisterRejectedException).message,
          '<<not json at all>>');
      expect(recorded.pathSequence, ['info', 'challenge', 'register']);
    });
  });
}
