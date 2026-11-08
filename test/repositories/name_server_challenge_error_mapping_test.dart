import 'package:danawallet/repositories/name_server_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('challengeRegisterExceptionFor (typed repository boundary)', () {
    test('401 ERR_NO_CHALLENGE -> NoChallengeException', () {
      final error = challengeRegisterExceptionFor(
        401,
        '{"id":"req-1","message":"Invalid or missing nonce. Please call '
        '/challenge first.","dana_address":null,"sp_address":null}',
      );
      expect(error, isA<NoChallengeException>());
      expect(error!.statusCode, 401);
      expect(
        error.serverMessage,
        'Invalid or missing nonce. Please call /challenge first.',
      );
    });

    test('401 ERR_EXPIRED -> ChallengeExpiredOnServerException', () {
      final error = challengeRegisterExceptionFor(
        401,
        '{"id":"req-1","message":"Challenge nonce expired. Please request '
        'a new one.","dana_address":null,"sp_address":null}',
      );
      expect(error, isA<ChallengeExpiredOnServerException>());
      expect(error!.statusCode, 401);
      expect(
        error.serverMessage,
        'Challenge nonce expired. Please request a new one.',
      );
    });

    test('401 ERR_MISMATCH -> NonceMismatchException', () {
      final error = challengeRegisterExceptionFor(
        401,
        '{"id":"req-1","message":"Nonce does not match this request. '
        'Request a new one.","dana_address":null,"sp_address":null}',
      );
      expect(error, isA<NonceMismatchException>());
      expect(error!.statusCode, 401);
      expect(
        error.serverMessage,
        'Nonce does not match this request. Request a new one.',
      );
    });

    test(
      '401 unrecognized message falls back to RegisterRejectedException',
      () {
        final error = challengeRegisterExceptionFor(
          401,
          '{"message":"Signature verification failed"}',
        );
        expect(error!.runtimeType, RegisterRejectedException);
        expect(error.serverMessage, 'Signature verification failed');
      },
    );

    test('401 non-JSON body falls back carrying the raw body', () {
      final error = challengeRegisterExceptionFor(401, 'bad gateway');
      expect(error!.runtimeType, RegisterRejectedException);
      expect(error.serverMessage, 'bad gateway');
    });

    test('429 -> RegisterRateLimitedException (distinct back-off class)', () {
      final error = challengeRegisterExceptionFor(
        429,
        '{"message":"slow down"}',
      );
      expect(error, isA<RegisterRateLimitedException>());
      expect(error, isNot(isA<RegisterRejectedException>()));
      expect(error!.statusCode, 429);
      expect(error.serverMessage, 'slow down');
    });

    test('400 -> RegisterValidationException', () {
      final error = challengeRegisterExceptionFor(
        400,
        '{"message":"invalid user_name"}',
      );
      expect(error, isA<RegisterValidationException>());
      expect(error!.statusCode, 400);
      expect(error.serverMessage, 'invalid user_name');
    });

    test('JSON body without a message field carries the raw body', () {
      final error = challengeRegisterExceptionFor(429, '{"id":"req-1"}');
      expect(error!.serverMessage, '{"id":"req-1"}');
    });

    test('statuses outside the typed surface return null (generic path)', () {
      expect(challengeRegisterExceptionFor(500, 'oops'), isNull);
      expect(challengeRegisterExceptionFor(404, 'nope'), isNull);
      expect(challengeRegisterExceptionFor(409, 'conflict'), isNull);
    });
  });
}
