//  Table-driven coverage for the client-side binding validation in
// [NameServerRepository.requestChallenge] (finding t_972f6cc3, updated for
// spec v1 in t_7efd3024): a buggy/compromised nameserver must not be able
// to hand back a
// `dana-register:v1:{network_key}:{nonce}:{user_name}:{domain}:{sp_address}`
// message whose fields differ from what the user actually requested,
// because that exact string is what goes on to be signed by the spend key.
// The expected message is rebuilt from the CLIENT-PINNED per-network
// network_key (D7) passed by the caller - the server-echoed `network_key`
// field is never trusted.
//
// Fake HTTP layer: MockClient from the existing `http` dependency
// (`package:http/testing.dart`) injected through the repository's `client`
// seam — the same route as the sibling repository tests.
import 'dart:convert';

import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/repositories/name_server_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';

const String _userName = 'alice';
const String _domain = 'danawallet.app';
const String _networkKey = 'tsp'; // pinned client constant for signet (D7)
final String _nonce = 'ab' * 32; // 64 lowercase hex chars per the grammar
const String _spAddress = 'tsp1qqernutv8ar5g7m2x';
const String _requestId = 'req-1';

/// The honest server message for the constants above, in the server's exact
/// field order (dana-nameserver `challenge_message()`, spec v1).
String _validMessage() =>
    'dana-register:v1:$_networkKey:$_nonce:$_userName:$_domain:$_spAddress';

/// POST /challenge responder with overridable fields; each override stays
/// internally consistent (the `nonce`/`network_key` JSON fields follow the
/// arguments), so a tampered `message` is the only thing that is dishonest.
/// Sentinel distinguishing "not overridden" from "explicitly absent".
const Object _absent = Object();

MockClient _challengeClient({
  String? message,
  Object? networkKey = _absent,
  Object? nonce = _absent,
}) {
  return MockClient((request) async {
    final body = <String, dynamic>{'id': _requestId};
    if (message != null) body['message'] = message;
    if (!identical(nonce, _absent)) {
      if (nonce != null) body['nonce'] = nonce as String;
    } else {
      body['nonce'] = _nonce;
    }
    if (!identical(networkKey, _absent)) {
      if (networkKey != null) body['network_key'] = networkKey as String;
    } else {
      body['network_key'] = _networkKey;
    }
    body['expires_at'] = 1791036000;
    return Response(jsonEncode(body), 200,
        headers: {'content-type': 'application/json'});
  });
}

NameServerRepository _repoWith(MockClient client) {
  final repo = NameServerRepository(network: Network.signet);
  repo.client = () => client;
  return repo;
}

/// Runs requestChallenge against [client] and returns the thrown object, or
/// null when it completed.
Future<Object?> _captureError(MockClient client) async {
  try {
    await _repoWith(client).requestChallenge(
      userName: _userName,
      domain: _domain,
      spAddress: _spAddress,
      requestId: _requestId,
      networkKey: _networkKey,
    );
    return null;
  } catch (e) {
    return e;
  }
}

void main() {
  group('requestChallenge binding validation (spec v1)', () {
    test('all-fields-equal => returns; server bytes pass through verbatim',
        () async {
      final serverMessage = _validMessage();
      final repo = _repoWith(_challengeClient(message: serverMessage));

      final challenge = await repo.requestChallenge(
        userName: _userName,
        domain: _domain,
        spAddress: _spAddress,
        requestId: _requestId,
        networkKey: _networkKey,
      );

      // Validation-only contract: what we hand on to signing is the exact
      // bytes the server returned, never the client-reassembled string.
      expect(challenge.message, serverMessage);
      expect(challenge.nonce, _nonce);
      expect(challenge.networkKey, _networkKey);
    });

    // Each row tampers exactly one aspect of an otherwise-honest message.
    final fieldsJoinedByUnderscores = [
      _networkKey,
      _nonce,
      _userName,
      _domain,
      _spAddress,
    ].join('_');
    final tampered = <String, String>{
      'missing v1 tag':
          'dana-register:$_networkKey:$_nonce:$_userName:$_domain:$_spAddress',
      'domain swapped for an attacker domain':
          'dana-register:v1:$_networkKey:$_nonce:$_userName:evil.example:$_spAddress',
      'user_name swapped for another user':
          'dana-register:v1:$_networkKey:$_nonce:mallory:$_domain:$_spAddress',
      'nonce swapped (message disagrees with the nonce column)':
          'dana-register:v1:$_networkKey:${'cd' * 32}:$_userName:$_domain:$_spAddress',
      'network_key swapped (message disagrees with the pinned constant)':
          'dana-register:v1:sp:$_nonce:$_userName:$_domain:$_spAddress',
      'sp_address swapped (message binds a different payment code)':
          'dana-register:v1:$_networkKey:$_nonce:$_userName:$_domain:tsp1qqattacker',
      'prefix replaced':
          'dana-transfer:v1:$_networkKey:$_nonce:$_userName:$_domain:$_spAddress',
      'wrong separator count (fields joined by underscores)':
          'dana-register:v1:$fieldsJoinedByUnderscores',
      'wrong separator count (extra trailing field)':
          'dana-register:v1:$_networkKey:$_nonce:$_userName:$_domain:$_spAddress:extra',
    };

    for (final entry in tampered.entries) {
      test('tampered: ${entry.key} => throws FormatException', () async {
        final error =
            await _captureError(_challengeClient(message: entry.value));
        expect(error, isA<FormatException>(),
            reason: 'tampered message must be rejected before signing');
        final text = error.toString();
        expect(text, contains('does not match the requested binding'));
        // The rejection names the message the client expected, so the log
        // carries the honest binding.
        expect(text, contains('Expected: ${_validMessage()}'));
      });
    }

    test('garbage message => throws FormatException', () async {
      final error =
          await _captureError(_challengeClient(message: 'not-a-challenge'));
      expect(error, isA<FormatException>());
      expect(
          error.toString(), contains('does not match the requested binding'));
    });

    test('absent message field => throws FormatException (model parse guard)',
        () async {
      final error = await _captureError(_challengeClient(message: null));
      expect(error, isA<FormatException>());
    });

    test('nonce mismatch between message and nonce column => rejected',
        () async {
      final error = await _captureError(_challengeClient(
        message: _validMessage(),
        nonce: 'cd' * 32,
      ));
      expect(error, isA<FormatException>());
    });

    test('absent nonce field => throws FormatException (model parse guard)',
        () async {
      // requestChallenge never rebuilds a message from a null nonce: the
      // sibling response model rejects the response outright.
      final error = await _captureError(_challengeClient(
        message: _validMessage(),
        nonce: null,
      ));
      expect(error, isA<FormatException>());
    });

    test('non-200 raises ChallengeRejectedException with the parsed code',
        () async {
      final client = MockClient((request) async => Response(
          jsonEncode({'id': _requestId, 'message': 'rate_limited'}), 429,
          headers: {'retry-after': '3'}));
      final error = await _captureError(client);
      expect(error, isA<ChallengeRejectedException>());
      final rejected = error as ChallengeRejectedException;
      expect(rejected.status, 429);
      expect(rejected.code, NameServerErrorCode.rateLimited);
      expect(rejected.retryAfter, const Duration(seconds: 3));
    });

    test(
        'non-200 with a prose body maps 429 to the rate_limited code and '
        'carries no Retry-After when the header is absent', () async {
      final client = MockClient((request) async => Response(
          jsonEncode({'id': _requestId, 'message': 'Too many pending'}), 429));
      final error = await _captureError(client);
      expect(error, isA<ChallengeRejectedException>());
      final rejected = error as ChallengeRejectedException;
      expect(rejected.code, NameServerErrorCode.rateLimited);
      expect(rejected.retryAfter, isNull);
    });

    test(
        'a server-echoed network_key field cannot smuggle a binding: the '
        'pinned constant decides', () async {
      // Server echoes our pinned key in the column but the message was
      // minted for mainnet — the exact-match rebuild catches it.
      final error = await _captureError(_challengeClient(
        message: 'dana-register:v1:sp:$_nonce:$_userName:$_domain:$_spAddress',
        networkKey: _networkKey,
      ));
      expect(error, isA<FormatException>());
    });
  });
}
