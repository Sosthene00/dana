import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/services/dana_address_service.dart';
import 'package:flutter_test/flutter_test.dart';

final _a63 = 'a'.padRight(63, 'a');
final _a64 = 'a'.padRight(64, 'a');

void main() {
  group('isValidDanaUsername - canonical DNS labels accepted', () {
    const valid = <String>[
      'a',
      '0',
      '9',
      'a1',
      'a-b',
      'a-1',
      'alice',
      'word-word-123',
      '1a2b3c',
      'a-1-b-2',
      '00000000',
    ];
    for (final name in valid) {
      test('accepts "\$name"', () {
        expect(DanaAddressService.isValidDanaUsername(name), isTrue);
      });
    }
    test('accepts 63-char label (upper bound)', () {
      expect(DanaAddressService.isValidDanaUsername(_a63), isTrue);
    });
  });

  group('isValidDanaUsername - non-canonical labels rejected', () {
    const invalid = <String>[
      '',
      '-a',
      'a-',
      'a--b',
      '-',
      '--',
      '-a-',
      'a b',
      'a_b',
      'a.b',
      'a@b',
      'alice!',
      'ALICE',
      'Alice',
    ];
    for (final name in invalid) {
      test('rejects "\$name"', () {
        expect(DanaAddressService.isValidDanaUsername(name), isFalse);
      });
    }
    test('rejects 64-char label (over length bound)', () {
      expect(DanaAddressService.isValidDanaUsername(_a64), isFalse);
    });
  });

  test('uppercase is rejected without being silently lowercased', () {
    expect(DanaAddressService.isValidDanaUsername('Alice'), isFalse);
    // The canonical lowercase form is accepted on its own merits -
    // validation never mutates the input.
    expect(DanaAddressService.isValidDanaUsername('alice'), isTrue);
  });

  group('generated candidate regression', () {
    test('>=20 generated candidates all pass the validator', () {
      final candidates = DanaAddressService.generateDanaAddressCandidates(
        paymentCode:
            'SP1qqd6d2jff6n3gqk8n0t3m7v9x2z5c8b1d4f7h0j3m6p9s2v5x8zq',
        count: 30,
      );
      expect(candidates.length, greaterThanOrEqualTo: 20);
      final shape = RegExp(r'^[a-z]+-[a-z]+-[0-9]{1,3}$');
      for (final candidate in candidates) {
        expect(candidate.length, lessThanOrEqualTo: 63,
            reason: 'candidate "\$candidate" exceeds 63 chars');
        expect(DanaAddressService.isValidDanaUsername(candidate), isTrue,
            reason: 'candidate "\$candidate" fails isValidDanaUsername');
        expect(candidate, matches(shape));
      }
    });
  });

  test('registerUser throws FormatException before any network call',
      () async {
    final service = DanaAddressService(network: Network.mainnet);
    Object? error;
    try {
      await service.registerUser(
        username: 'Alice',
        paymentCode: 'SP1qqd6d2jff6n3gqk8n0t3m7v9x2z5c8b1d4f7h0j3m6p9s2v5x8zq',
        signChallenge: (_) async => '',
      );
    } catch (e) {
      error = e;
    }
    expect(error, isA<FormatException>());
  });
}
