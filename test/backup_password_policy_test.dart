import 'package:danawallet/utils/backup_password_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// §6.1 password-policy acceptance: rejected under-length / no-digit /
/// no-lowercase; accepted at the boundary (16 Unicode scalar values,
/// lowercase + digit). Plain boolean predicates — no scoring.
void main() {
  group('BackupPasswordPolicy (spec §6.1)', () {
    test('rejects under-length passwords', () {
      expect(BackupPasswordPolicy.hasMinLength('abcdef012345678'), isFalse);
      expect(BackupPasswordPolicy.satisfies('abcdef012345678'), isFalse);
      expect(
        BackupPasswordPolicy.violationOf('abcdef012345678'),
        contains('16'),
      );
      expect(BackupPasswordPolicy.satisfies(''), isFalse);
    });

    test('rejects passwords without a digit', () {
      expect(BackupPasswordPolicy.hasDigit('abcdefghijklmnop'), isFalse);
      expect(BackupPasswordPolicy.satisfies('abcdefghijklmnop'), isFalse);
      expect(
        BackupPasswordPolicy.violationOf('abcdefghijklmnop'),
        contains('digit'),
      );
    });

    test('rejects passwords without a lowercase letter', () {
      expect(BackupPasswordPolicy.hasLowercase('0123456789ABCDEF'), isFalse);
      expect(BackupPasswordPolicy.satisfies('0123456789ABCDEF'), isFalse);
      expect(
        BackupPasswordPolicy.violationOf('0123456789ABCDEF'),
        contains('lowercase'),
      );
    });

    test('accepts the boundary: exactly 16 scalar values, lowercase + digit',
        () {
      expect(BackupPasswordPolicy.hasMinLength('abcdef0123456789'), isTrue);
      expect(BackupPasswordPolicy.satisfies('abcdef0123456789'), isTrue);
      expect(BackupPasswordPolicy.violationOf('abcdef0123456789'), isNull);
    });

    test('counts Unicode scalar values, not bytes or UTF-16 code units', () {
      // 20 Cyrillic scalar values (40 UTF-8 bytes): length rule passes.
      const cyrillic = 'парольпарольпароль42';
      expect(cyrillic.runes.length, 20);
      expect(BackupPasswordPolicy.hasMinLength(cyrillic), isTrue);
      expect(BackupPasswordPolicy.satisfies(cyrillic), isTrue);

      // 20 emoji are 40 UTF-16 code units but 20 scalar values: passes.
      final emoji = '🙂' * 19 + '1';
      expect(emoji.runes.length, 20);
      expect(BackupPasswordPolicy.hasMinLength(emoji), isTrue);
    });

    test('predicates are plain booleans (no scoring side channels)', () {
      // The class exposes only boolean predicates and a first-violation
      // string; no numeric strength value exists to build a meter from.
      expect(BackupPasswordPolicy.satisfies('abcdef0123456789'), isTrue);
      expect(BackupPasswordPolicy.satisfies('aaaaaaaaaaaaaaaa1'), isTrue);
      // Both pass identically — no distinction beyond §6.1's three rules.
    });
  });
}
