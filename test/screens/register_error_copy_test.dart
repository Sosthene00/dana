import 'package:danawallet/repositories/name_server_repository.dart';
import 'package:danawallet/screens/onboarding/register_dana_address.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('registrationErrorCopy — typed classification, no substring hijack',
      () {
    test(
        'exhausted nonce rejection gets honest give-up copy, never a retry promise',
        () {
      // The service burns its single automatic nonce refresh and rethrows, so
      // by the time this reaches the UI nothing will retry on its own. The old
      // copy ('Registration timed out, retrying...') promised a retry that
      // never happens and called a 401 rejection a timeout.
      final e = RegisterRejectedException(
        401,
        'Challenge nonce expired',
        reason: RegisterRejectReason.nonce,
      );

      final copy = e.registrationErrorCopy();

      expect(copy, isNotNull);
      expect(copy!.toLowerCase(), isNot(contains('retrying')));
      expect(copy.toLowerCase(), isNot(contains('timed out')));
      expect(copy.toLowerCase(), isNot(contains('timeout')));
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

      expect(e.registrationErrorCopy(), isNull,
          reason: 'must fall through to the generic server-message path');
    });

    test('signature-verified failures classify by reason, not by substring',
        () {
      final sig = RegisterRejectedException(
        401,
        'Signature verification failed for the supplied nonce',
        reason: RegisterRejectReason.signature,
      );
      expect(sig.registrationErrorCopy(), isNull,
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

      // Default for hand-constructed/unknown rejections is inert, not nonce.
      expect(RegisterRejectedException(401, 'anything').reason,
          RegisterRejectReason.other);
    });
  });

  group('registrationErrorCopy — preserved routing (table test)', () {
    // Each of the four known server reject strings must keep routing to the
    // same-or-better copy it had before. The service retries signature-class
    // phrases once and nonce-class phrases once; when the budget is already
    // spent the rejection rethrows with its typed reason intact and the UI
    // shows the give-up/server-message path for each class — never the old
    // false 'timed out, retrying...' promise.
    final table = <String, RegisterRejectReason>{
      'Signature verification failed': RegisterRejectReason.signature,
      'Invalid signature hex': RegisterRejectReason.signature,
      'Invalid signature encoding': RegisterRejectReason.signature,
      'Signature must be 64 bytes': RegisterRejectReason.signature,
      'Challenge nonce expired': RegisterRejectReason.nonce,
      'Invalid or missing nonce': RegisterRejectReason.nonce,
      'Nonce does not match': RegisterRejectReason.nonce,
    };

    table.forEach((message, expectedReason) {
      test('"$message" keeps its class and never the fake-timeout copy', () {
        final reason = classifyRegisterRejectMessage(message);
        expect(reason, expectedReason);

        final copy = RegisterRejectedException(401, message, reason: reason)
            .registrationErrorCopy();
        if (reason == RegisterRejectReason.nonce) {
          expect(copy, 'Registration was rejected, please try again');
        } else {
          expect(copy, isNull);
        }
        expect(copy?.toLowerCase(), isNot(contains('retrying')));
      });
    });

    test('unrelated exceptions keep falling to the generic path', () {
      // ignore: prefer_const_constructors
      expect(Exception('boom').registrationErrorCopy(), isNull);
      // ignore: prefer_const_constructors
      expect(FormatException('bad').registrationErrorCopy(),
          'Invalid Dana address');
    });

    test('429 backoff exhaustion copy is unchanged', () {
      expect(
          ChallengeRejectedException(429, 'rate limited')
              .registrationErrorCopy(),
          'Too many pending registrations, try again in a few minutes');
      expect(
          Exception(
                  'Challenge request rejected (HTTP 429) after 3 backoff retries')
              .registrationErrorCopy(),
          'Too many pending registrations, try again in a few minutes');
    });
  });
}
