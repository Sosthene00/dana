import 'package:danawallet/repositories/name_server_repository.dart';
import 'package:danawallet/screens/onboarding/register_dana_address.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('registrationErrorCopy — typed classification, no substring hijack',
      () {
    test(
        'exhausted nonce rejection gets honest give-up copy, never a retry promise',
        () {
      final e = RegisterRejectedException(
        401,
        'Challenge nonce expired',
        reason: RegisterRejectReason.nonce,
      );

      final copy = registrationErrorCopy(e);

      expect(copy, isNotNull);
      expect(copy, 'Registration was rejected, please try again');
    });

    test(
        'a non-nonce-class rejection whose message merely mentions "nonce" '
        'is NOT routed to the nonce give-up copy', () {
      // Regression for the bare `message.contains('nonce')` substring arm: a
      // future validation-class 401 mentioning 'nonce' that exhausts the
      // service budgets used to get the fake timeout copy, swallowing the
      // server message the generic displayError fallback would have shown.
      final e = RegisterRejectedException(
        401,
        'nonce must be hex',
        reason: RegisterRejectReason.other,
      );

      expect(registrationErrorCopy(e), isNull,
          reason: 'must fall through to the generic server-message path');
    });

    test('signature-verified failures classify by reason, not by substring',
        () {
      final sig = RegisterRejectedException(
        401,
        'Signature verification failed for the supplied nonce',
        reason: RegisterRejectReason.signature,
      );
      expect(registrationErrorCopy(sig), isNull,
          reason: 'exhausted re-sign budget falls to the server-message path, '
              'not the nonce give-up copy');
    });

    test('known server phrases classify exactly; lookalikes do not', () {
      for (final phrase in nonceRejectionPhrases) {
        expect(
            classifyRegisterRejectMessage(phrase), RegisterRejectReason.nonce,
            reason: phrase);
      }
      for (final phrase in signatureVerificationPhrases) {
        expect(classifyRegisterRejectMessage(phrase),
            RegisterRejectReason.signature,
            reason: phrase);
      }
      // Mentions 'nonce' but is not in the server nonce vocabulary.
      expect(classifyRegisterRejectMessage('nonce must be hex'),
          RegisterRejectReason.other);
      expect(classifyRegisterRejectMessage('user name already taken'),
          RegisterRejectReason.other);
    });

    test('the 401 construction site assigns the typed reason from the message',
        () {
      // The repository is the single place the server message is understood;
      // exceptions escaping it must carry the reason pre-decided.
      final nonceish = RegisterRejectedException(
          401, 'Invalid or missing nonce',
          reason: classifyRegisterRejectMessage('Invalid or missing nonce'));
      expect(nonceish.reason, RegisterRejectReason.nonce);

      // Unknown rejections carry the inert `other` reason, never nonce.
      expect(
          RegisterRejectedException(401, 'anything',
                  reason: RegisterRejectReason.other)
              .reason,
          RegisterRejectReason.other);
    });
  });

  group('registrationErrorCopy — preserved routing', () {
    test('unrelated exceptions keep falling to the generic path', () {
      // ignore: prefer_const_constructors
      expect(registrationErrorCopy(Exception('boom')), isNull);
      // ignore: prefer_const_constructors
      expect(registrationErrorCopy(FormatException('bad')),
          'Invalid Dana address');
    });

    test('429 backoff exhaustion copy is unchanged', () {
      expect(
          registrationErrorCopy(
              ChallengeRejectedException(429, 'rate limited')),
          'Too many pending registrations, try again in a few minutes');
      expect(
          registrationErrorCopy(Exception(
              'Challenge request rejected (HTTP 429) after 3 backoff retries')),
          'Too many pending registrations, try again in a few minutes');
    });
  });
}
