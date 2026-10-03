import 'dart:convert';
import 'dart:io' as dio;

import 'package:danawallet/data/models/bip353_address.dart';
import 'package:danawallet/data/models/name_server_register_request.dart';
import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/repositories/name_server_repository.dart';
import 'package:danawallet/services/dana_address_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

/// Orchestration coverage for the challenge -> sign -> register round-trip
/// in [DanaAddressService.registerUser] (finding: registerUser posted
/// unprovable bodies that a challenge-enforcing nameserver
/// [dana-nameserver #20] 401s).
///
/// Fake layers (the spec's injectability requirement):
/// - HTTP: MockClient from the existing `http` dependency, assigned to the
///   repository `client` seam and injected via DanaAddressService.forTesting.
/// - Signer: a plain closure recording the signed bytes and returning a
///   canned signature. This file NEVER imports the FRB bridge
///   (`lib/generated/**` is gitignored and absent in a fresh worktree).
/// - Clock: the service `clock` seam is stepped manually, so the
///   expired-TTL leg asserts the re-challenge WITHOUT sleeping.
///
/// The DNS pre-check is faked through the service's injectable `resolve`
/// seam (Bip353Resolver opens its OWN http.Client, so the repository's
/// MockClient seam cannot intercept it — without this fake every leg would
/// hit live DNS-over-HTTPS and the suite would be network-dependent).
/// Any unexpected request on the repository client trips an explicit fail,
/// so the challenge/register legs cannot be polluted by an accidental hit.
const String _domain = 'danawallet.app';
const String _networkKey = '9f2c7a4e1b8d';
const String _sp = 'sp1qqernutv8ar5g7m2x';
const String _username = 'alice';
final String _fakeSignature = 'ab' * 64;

/// Server-shaped challenge message for the constants above (field order of
/// the nameserver's `challenge_message()`).
String _messageFor(String userName, String nonce) =>
    'dana-register:$_networkKey:$nonce:$userName:$_domain';

/// Mutable clock: tests move [now] instead of sleeping on wall time.
class _FakeClock {
  DateTime now = DateTime.utc(2026, 10, 3, 12);
  DateTime call() => now;
  int get epochSeconds => now.toUtc().millisecondsSinceEpoch ~/ 1000;
  void advanceSeconds(int s) => now = now.add(Duration(seconds: s));
}

/// The signer fake. Records every message it was asked to sign; the real
/// FRB signer is never imported here.
class _SignerSpy {
  final List<String> signed = [];

  Future<String> call(String message) async {
    signed.add(message);
    return _fakeSignature;
  }
}

class _MockNameserver {
  _MockNameserver({int ttlSeconds = 300, required _FakeClock clock})
      : _ttlSeconds = ttlSeconds,
        _clock = clock;

  /// expires_at is stamped from the SHARED fake clock at serve time, so
  /// advancing the clock really ages an issued nonce. The server's own
  /// contract value is NONCE_TTL_SECS = 300 (the default here).
  final int _ttlSeconds;
  final _FakeClock _clock;

  int challengeCalls = 0;
  int registerCalls = 0;
  final List<Map<String, dynamic>> registerBodies = [];
  final List<String> challengeUserNames = [];

  /// Queue of canned 401 `message` strings for /register; empty => 200.
  final List<String> register401Messages = [];

  /// When set, the NEXT /register answers this status/body (one-shot).
  int? registerOverrideStatus;
  String? registerOverrideBody;

  /// When set, EVERY /register answers this status/body (persistent outage).
  int? persistentStatus;
  String? persistentBody;

  /// When > 0, the next N /challenge responses fail with [challengeFailureStatus].
  int challengeFailuresLeft = 0;
  int challengeFailureStatus = 429;
  String challengeFailureBody = '{"message":"Too many requests"}';

  /// When set, right after the n-th /challenge is served OK, the shared
  /// clock jumps by these many seconds — the deterministic stand-in for
  /// "the confirm screen sat open for 5 minutes" (server NONCE_TTL_SECS=300).
  Map<int, int> advanceAfterChallengeServed = const {};

  /// When > 0, the next N /challenge responses are stamped ALREADY expired
  /// (expires_at == now): the deterministic stand-in for a clock-skewed
  /// server whose issued nonce is dead from our clock's perspective.
  int staleChallengesLeft = 0;

  String nonceFor(int call) => 'nonce$call';

  MockClient client() {
    return MockClient((BaseRequest request) async {
      final url = request.url.toString();
      if (url.contains('/info')) {
        return Response(jsonEncode({'domain': _domain, 'network': 'signet'}),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (url.contains('/challenge')) {
        challengeCalls++;
        final served = challengeCalls;
        final body = jsonDecode((request as Request).body)
            as Map<String, dynamic>;
        challengeUserNames.add(body['user_name'] as String);
        if (challengeFailuresLeft > 0) {
          challengeFailuresLeft--;
          return Response(challengeFailureBody, challengeFailureStatus,
              headers: {'content-type': 'application/json'});
        }
        final nonce = nonceFor(served);
        final expiresAt = staleChallengesLeft > 0
            ? _clock.epochSeconds
            : _clock.epochSeconds + _ttlSeconds;
        if (staleChallengesLeft > 0) staleChallengesLeft--;
        final advance = advanceAfterChallengeServed[served];
        if (advance != null) _clock.advanceSeconds(advance);
        return Response(
            jsonEncode({
              'id': body['id'],
              'message': _messageFor(body['user_name'] as String, nonce),
              'nonce': nonce,
              'network_key': _networkKey,
              'expires_at': expiresAt,
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (url.contains('/register')) {
        registerCalls++;
        final body = jsonDecode((request as Request).body)
            as Map<String, dynamic>;
        registerBodies.add(body);
        if (registerOverrideStatus != null) {
          final status = registerOverrideStatus!;
          final respBody = registerOverrideBody ?? '{}';
          registerOverrideStatus = null;
          registerOverrideBody = null;
          return Response(respBody, status,
              headers: {'content-type': 'application/json'});
        }
        if (register401Messages.isNotEmpty) {
          return Response(
              jsonEncode({'message': register401Messages.removeAt(0)}), 401,
              headers: {'content-type': 'application/json'});
        }
        if (persistentStatus != null) {
          return Response(persistentBody ?? '{}', persistentStatus!,
              headers: {'content-type': 'application/json'});
        }
        return Response(
            jsonEncode({
              'id': body['id'],
              'message': 'Registered',
              'dana_address': '${body['user_name']}@$_domain',
              'sp_address': _sp,
              'dns_record_id': 'rec-1',
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (url.contains('type=TXT')) {
        // NXDOMAIN: the username is not registered yet (DNS pre-check).
        return Response(jsonEncode({'Status': 3}), 200,
            headers: {'content-type': 'application/dns-json'});
      }
      throw StateError('Unexpected request to $url');
    });
  }
}

/// DNS pre-check fake: every candidate reports 'not registered yet'
/// (Bip353Resolver.resolve's null return), so registerUser proceeds to
/// the challenge handshake without touching the wire.
Future<String?> _notRegistered(Bip353Address a, Network n) async => null;

DanaAddressService _serviceWith(
    _MockNameserver ns, _SignerSpy signer, _FakeClock clock) {
  final repo = NameServerRepository(network: Network.signet)
    ..client = () => ns.client();
  return DanaAddressService.forTesting(
    network: Network.signet,
    signChallenge: signer.call,
    nameServerRepository: repo,
    resolve: _notRegistered,
    clock: clock.call,
  );
}

/// Flattens a ProcessResult's stdout+stderr to text. The `flutter test`
/// VM patches dart:io such that ProcessResult.stdout surfaces as a String at
/// runtime while the unpatched analyzer still types it List<int>; accepting
/// either representation keeps this guard honest in both worlds.
String _processOutput(dynamic result) {
  String flat(Object? v) => v is String
      ? v
      : v is List<int>
          ? utf8.decode(v)
          : '<no output>';
  return '${flat((result as dynamic).stdout as Object?)}'
      '${flat((result as dynamic).stderr as Object?)}';
}

/// [expectLater] alternative that keeps the suite dependency-free beyond
/// flutter_test: runs [actual], expects it to throw, and returns the error.
Future<Object> _captureError(Future<void> Function() actual) async {
  try {
    await actual();
  } catch (e) {
    return e;
  }
  throw StateError('expected a throw, but the call completed normally');
}

void main() {
  group('registerUser challenge round-trip', () {
    late _FakeClock clock;
    late _MockNameserver ns;
    late _SignerSpy signer;
    late DanaAddressService service;

    setUp(() {
      clock = _FakeClock();
      ns = _MockNameserver(clock: clock);
      signer = _SignerSpy();
      service = _serviceWith(ns, signer, clock);
    });

    test('happy path: /challenge -> sign verbatim -> /register with proof',
        () async {
      final result = await service.registerUser(
          username: _username, paymentCode: _sp);

      expect(result, Bip353Address(username: _username, domain: _domain));
      expect(ns.challengeCalls, 1);
      expect(ns.registerCalls, 1);
      // Exactly one signature, over the message the server returned verbatim.
      expect(signer.signed, [_messageFor(_username, 'nonce1')]);
      final body = ns.registerBodies.single;
      expect(body['user_name'], _username);
      expect(body['domain'], _domain);
      expect(body['sp_address'], _sp);
      expect(body['nonce'], 'nonce1');
      expect(body['signature'], _fakeSignature);
    });

    test(
        'a missing signer fails fast BEFORE any network call: no /challenge, '
        'no /register (an unprovable body can never reach the wire)', () async {
      final repo = NameServerRepository(network: Network.signet)
        ..client = () => ns.client();
      final signerless = DanaAddressService.forTesting(
        network: Network.signet,
        // No signChallenge injection at all: the service cannot prove anything.
        nameServerRepository: repo,
        resolve: _notRegistered,
        clock: clock.call,
      );

      final error = await _captureError(
          () => signerless.registerUser(username: _username, paymentCode: _sp));
      expect(error, isA<StateError>());
      expect('$error', contains('signChallenge'));
      expect(ns.challengeCalls, 0);
      expect(ns.registerCalls, 0);
    });

    test(
        '401 with a nonce-class message burns the nonce -> full re-challenge '
        'from scratch (fresh nonce on the retry)', () async {
      ns.register401Messages.add('Challenge nonce expired');

      final result = await service.registerUser(
          username: _username, paymentCode: _sp);

      expect(result.username, _username);
      expect(ns.challengeCalls, 2);
      expect(ns.registerCalls, 2);
      expect(signer.signed.length, 2);
      expect(ns.registerBodies[0]['nonce'], 'nonce1');
      expect(ns.registerBodies[1]['nonce'], 'nonce2');
    });

    test(
        '401 on an UNCLASSIFIED message is treated as burned -> one full '
        're-challenge; the fresh challenge then registers', () async {
      ns.register401Messages.add('Server-side challenge state unknown');

      final result = await service.registerUser(
          username: _username, paymentCode: _sp);

      expect(result.username, _username);
      expect(ns.challengeCalls, 2);
      expect(ns.registerCalls, 2);
      expect(ns.registerBodies[0]['nonce'], 'nonce1');
      expect(ns.registerBodies[1]['nonce'], 'nonce2');
    });

    test(
        'bad-signature 401 does NOT burn the nonce: re-signed inside the TTL '
        'with EXACTLY ONE /challenge call', () async {
      // Signature-verification failures keep the nonce spendable
      // (verify-before-burn server semantics): both retries must stay on
      // the SAME challenge.
      ns.register401Messages.addAll([
        'Signature verification failed',
        'Invalid signature hex',
      ]);

      final result = await service.registerUser(
          username: _username, paymentCode: _sp);

      expect(result.username, _username);
      // The heart of the spec: one /challenge despite two failed registers.
      expect(ns.challengeCalls, 1);
      expect(ns.registerCalls, 3);
      // Every signing call re-used the same server message, same nonce.
      expect(signer.signed, List.filled(3, _messageFor(_username, 'nonce1')));
      for (final body in ns.registerBodies) {
        expect(body['nonce'], 'nonce1');
      }
    });

    test(
        'confirm screen past the 300 s TTL => full re-challenge BEFORE '
        'signing: zero bytes spent on the aged nonce', () async {
      // Right after challenge #1 is served, the shared clock jumps 311 s:
      // by the time the loop re-checks expiry, nonce1 is past TTL + margin.
      ns.advanceAfterChallengeServed = const {1: 311};

      final result = await service.registerUser(
          username: _username, paymentCode: _sp);

      expect(result.username, _username);
      expect(ns.challengeCalls, 2);
      // NOTHING was ever signed on the aged nonce1 message...
      expect(signer.signed, isNot(contains(_messageFor(_username, 'nonce1'))));
      // ...only the fresh challenge #2 was signed and registered.
      expect(signer.signed, [_messageFor(_username, 'nonce2')]);
      expect(ns.registerBodies, hasLength(1));
      expect(ns.registerBodies.single['nonce'], 'nonce2');
    });

    test(
        'a challenge that is BORN stale (clock-skewed server) is never '
        'signed: re-challenge from scratch, then register', () async {
      // First /challenge is stamped already expired; the loop must notice
      // BEFORE signing and replace it outright.
      ns.staleChallengesLeft = 1;

      final result = await service.registerUser(
          username: _username, paymentCode: _sp);

      expect(result.username, _username);
      expect(signer.signed, isNot(contains(_messageFor(_username, 'nonce1'))),
          reason: 'an expired challenge must never be signed');
      expect(signer.signed, [_messageFor(_username, 'nonce2')]);
      expect(ns.challengeCalls, 2);
      expect(ns.registerBodies.single['nonce'], 'nonce2');
    });

    test(
        'a 429 on /challenge is retryable: back off, then re-challenge '
        '(bounded)', () async {
      ns.challengeFailuresLeft = 1; // first /challenge -> 429, second -> 200

      final result = await service.registerUser(
          username: _username, paymentCode: _sp);

      expect(result.username, _username);
      expect(ns.challengeCalls, 2);
      expect(ns.registerCalls, 1);
      expect(ns.registerBodies.single['nonce'], 'nonce2');
    });

    test(
        'persisting 429 surfaces the rejection and NEVER spins: the '
        'challenge loop is hard-bounded', () async {
      ns.challengeFailuresLeft = 99; // every /challenge -> 429

      final error = await _captureError(
          () => service.registerUser(username: _username, paymentCode: _sp));
      expect(error, isA<ChallengeRejectedException>());
      expect((error as ChallengeRejectedException).status, 429);
      // Bounded: initial + the single per-step retry, no unbounded spin.
      expect(ns.challengeCalls, 2);
      expect(ns.registerCalls, 0);
    });

    test(
        'non-401 failure after signing burns the nonce: re-challenge once, '
        'and a persisting failure resurfaces the ORIGINAL transport error',
        () async {
      // Every /register answers 5xx (nonce burned under server semantics):
      // the matrix re-challenges once, registers again, still 5xx — and the
      // caller must still see the REAL transport problem, not a budget error.
      ns.persistentStatus = 503;
      ns.persistentBody = 'Cloudflare origin unreachable (HTTP 503)';

      final error = await _captureError(
          () => service.registerUser(username: _username, paymentCode: _sp));
      expect(error, isA<Exception>());
      expect('$error', contains('503'));
      expect('$error', isNot(contains('budget')));
      // Bounded matrix: 6 challenges (the fixed cap), then the original
      // transport error resurfaces — never an unbounded spin.
      expect(ns.registerCalls, 6);
      expect(ns.challengeCalls, 6);
      expect(ns.registerBodies.map((b) => b['nonce']).toList(),
          ['nonce1', 'nonce2', 'nonce3', 'nonce4', 'nonce5', 'nonce6']);
    });

    test(
        'bad-signature re-signing is bounded: once the fixed re-sign cap is '
        'spent the flow gives up with a ChallengeRegistrationException (no '
        'fresh /challenge fetch on a still-good nonce)', () async {
      // Four consecutive signature-verification 401s exceed the fixed cap of
      // two re-signs (initial + two): the loop must NOT keep hammering the
      // same challenge forever, and must not treat a still-spendable nonce
      // as burned by going back to /challenge.
      ns.register401Messages.addAll(List.filled(4, 'Signature verification failed'));

      final error = await _captureError(
          () => service.registerUser(username: _username, paymentCode: _sp));
      expect(error, isA<ChallengeRegistrationException>());
      expect(ns.challengeCalls, 1,
          reason: 'verify-before-burn: the nonce was never burned, so no '
              'fresh /challenge may be fetched');
      // initial signature + two bounded re-signs = exactly 3 register posts.
      expect(ns.registerCalls, 3);
      expect(signer.signed, List.filled(3, _messageFor(_username, 'nonce1')));
    });

    test(
        'the per-registration challenge budget is a hard cap: a server that '
        're-burns every nonce cannot drive an unbounded loop', () async {
      // Every /register answers with a burned-nonce 401 => the matrix keeps
      // re-challenging until the fixed budget throws.
      ns.register401Messages
          .addAll(List.filled(20, 'Invalid or missing nonce'));

      final error = await _captureError(
          () => service.registerUser(username: _username, paymentCode: _sp));
      expect(error, isA<ChallengeRegistrationException>());
      // Hard cap, not a guess: initial + recovery re-challenges, fixed small
      // constant (_maxChallengesPerRegistration). The exact value is owned by
      // the service; the test only pins that it is finite and small.
      expect(ns.challengeCalls, lessThanOrEqualTo(10));
      expect(ns.challengeCalls, greaterThanOrEqualTo(2));
    });

    test(
        'nonce is never reused across candidate usernames: each /challenge '
        'is bound to its own user_name and its own nonce', () async {
      // Two independent registerUser calls (the availability-probe loop
      // registers whichever candidate it picked). A nonce fetched for one
      // candidate is invalid for the next: the message the server signs
      // embeds the user_name, so both legs must fetch their own challenge.
      await service.registerUser(username: _username, paymentCode: _sp);
      await service.registerUser(username: 'bob-2', paymentCode: _sp);

      expect(ns.challengeUserNames, [_username, 'bob-2']);
      expect(ns.registerBodies[0]['user_name'], _username);
      expect(ns.registerBodies[0]['nonce'], 'nonce1');
      expect(ns.registerBodies[1]['user_name'], 'bob-2');
      expect(ns.registerBodies[1]['nonce'], 'nonce2');
      // The signed bytes carry the per-candidate binding: distinct messages,
      // hence a reused nonce across candidates is cryptographically impossible.
      expect(signer.signed, [
        _messageFor(_username, 'nonce1'),
        _messageFor('bob-2', 'nonce2'),
      ]);
    });

    test('invalid usernames are rejected before ANY network call', () async {
      for (final bad in <String>[
        '', // empty
        'Alice', // uppercase must be REJECTED, never folded
        '-lead', // leading hyphen
        'trail-', // trailing hyphen
        'a--b', // consecutive hyphens
        'x' * 64, // longer than 63 characters
        'under_score', // disallowed punctuation
      ]) {
        final error = await _captureError(
            () => service.registerUser(username: bad, paymentCode: _sp));
        expect(error, isA<InvalidUsernameException>(),
            reason: 'must reject "$bad"');
      }
      expect(ns.challengeCalls, 0);
      expect(ns.registerCalls, 0);
    });

    test('a lowercase canonical label passes the gate unchanged', () async {
      final result = await service.registerUser(
          username: 'abc-123-def', paymentCode: _sp);
      expect(result.username, 'abc-123-def');
      expect(ns.challengeUserNames, ['abc-123-def']);
    });
  });

  group('NameServerRegisterRequest nonce/signature atomicity', () {
    test('the plain constructor carries NO proof at all', () {
      const r = NameServerRegisterRequest(
        id: 'r1',
        userName: _username,
        domain: _domain,
        spAddress: _sp,
      );
      expect(r.toJson().containsKey('nonce'), isFalse);
      expect(r.toJson().containsKey('signature'), isFalse);
    });

    test(
        'the ONLY proof-carrying constructor requires BOTH fields and emits '
        'both', () {
      final r = NameServerRegisterRequest.withChallenge(
        id: 'r1',
        userName: _username,
        domain: _domain,
        spAddress: _sp,
        nonce: 'n1',
        signature: _fakeSignature,
      );
      final json = r.toJson();
      expect(json['nonce'], 'n1');
      expect(json['signature'], _fakeSignature);
    });

    test('empty-string halves are refused (no silent gap through the back '
        'door)', () {
      expect(
          () => NameServerRegisterRequest.withChallenge(
              id: 'r1',
              userName: _username,
              domain: _domain,
              spAddress: _sp,
              nonce: '',
              signature: _fakeSignature),
          throwsFormatException);
      expect(
          () => NameServerRegisterRequest.withChallenge(
              id: 'r1',
              userName: _username,
              domain: _domain,
              spAddress: _sp,
              nonce: 'n1',
              signature: ''),
          throwsFormatException);
    });

    test('fromJson refuses a wire body carrying exactly one of the pair', () {
      final half = {
        'id': 'r1',
        'user_name': _username,
        'domain': _domain,
        'sp_address': _sp,
        'nonce': 'n1',
      };
      expect(() => NameServerRegisterRequest.fromJson(half),
          throwsFormatException);
      final otherHalf = {
        'id': 'r1',
        'user_name': _username,
        'domain': _domain,
        'sp_address': _sp,
        'signature': _fakeSignature,
      };
      expect(() => NameServerRegisterRequest.fromJson(otherHalf),
          throwsFormatException);
      // ...and round-trips both extremes of the atomic pair.
      final none = {
        'id': 'r1',
        'user_name': _username,
        'domain': _domain,
        'sp_address': _sp,
      };
      final parsedNone = NameServerRegisterRequest.fromJson(none).toJson();
      expect(parsedNone.containsKey('nonce'), isFalse);
      expect(parsedNone.containsKey('signature'), isFalse);
      final both = {
        ...none,
        'nonce': 'n1',
        'signature': _fakeSignature,
      };
      expect(
          NameServerRegisterRequest.fromJson(both).toJson()['nonce'], 'n1');
    });

    test(
        'COMPILE-TIME trap, executed: a half-proven request does not '
        'compile — the violation is unrepresentable in the type', () async {
      // The atomicity guarantee lives in the CONSTRUCTOR SIGNATURE:
      // withChallenge declares nonce AND signature as required, non-nullable
      // parameters, and Dart checks required named parameters at compile
      // time. This test writes that very program to a scratch file inside
      // the package, runs the analyzer on it, and requires the analyzer to
      // REJECT it with the missing-required-argument diagnostic — while the
      // control (a fully-proven request) must analyze clean. A regression
      // that re-optionalises either field flips this test red.
      final dir = dio.Directory('.dart_tool/atomicity_trap')
        ..createSync(recursive: true);
      final trap = dio.File('${dir.path}/half_proven_request.dart')
        ..writeAsStringSync('''
// ignore_for_file: all
import 'package:danawallet/data/models/name_server_register_request.dart';

NameServerRegisterRequest buildIt() {
  return NameServerRegisterRequest.withChallenge(
    id: 'r1',
    userName: '$_username',
    domain: '$_domain',
    spAddress: '$_sp',
    nonce: 'n1',
    // `signature:` is required and deliberately missing here.
  );
}
''');
      final control = dio.File('${dir.path}/fully_proven_request.dart')
        ..writeAsStringSync('''
// ignore_for_file: all
import 'package:danawallet/data/models/name_server_register_request.dart';

NameServerRegisterRequest buildIt() {
  return NameServerRegisterRequest.withChallenge(
    id: 'r1',
    userName: '$_username',
    domain: '$_domain',
    spAddress: '$_sp',
    nonce: 'n1',
    signature: '$_fakeSignature',
  );
}
''');

      final trapResult = await dio.Process.run(
          'dart',
          ['analyze', '--fatal-warnings', trap.path],
          workingDirectory: dio.Directory.current.path);
      final String trapOutput = _processOutput(trapResult);
      expect(trapResult.exitCode, isNot(0),
          reason: 'the half-proven request MUST fail to compile:\n'
              '$trapOutput');
      expect(trapOutput.toLowerCase(), contains('signature'),
          reason: 'the analyzer must name the missing required field; got:\n'
              '$trapOutput');

      final controlResult = await dio.Process.run(
          'dart',
          ['analyze', '--fatal-warnings', control.path],
          workingDirectory: dio.Directory.current.path);
      final String controlOutput = _processOutput(controlResult);
      expect(controlResult.exitCode, 0,
          reason: 'the fully-proven request must analyze clean:\n'
              '$controlOutput');

      trap.deleteSync();
      control.deleteSync();
      dir.deleteSync();
    });
  });
}
