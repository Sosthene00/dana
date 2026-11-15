/// Export-time password policy, spec `encrypted-file-backup.md` §6.1 (D8).
///
/// Plain boolean predicates over the entered string — no entropy meter, no
/// scoring, no blocklist (explicitly rejected in the ruling). The same rules
/// are enforced again inside the Rust export API (`backup_payload::
/// validate_password`, §6.1), so the UI checks must agree with it exactly.
class BackupPasswordPolicy {
  BackupPasswordPolicy._();

  /// §6.1 rule 1: at least 16 Unicode scalar values (not bytes, not UTF-16
  /// code units).
  static const int minLength = 16;

  static bool hasMinLength(String password) => password.runes.length >= minLength;

  /// §6.1 rule 2: at least one lowercase character.
  static bool hasLowercase(String password) =>
      password.runes.any(_isLowercaseScalar);

  /// §6.1 rule 3: at least one digit.
  static bool hasDigit(String password) =>
      password.runes.any(_isDigitScalar);

  /// True when the password satisfies §6.1 as written.
  static bool satisfies(String password) =>
      hasMinLength(password) && hasLowercase(password) && hasDigit(password);

  /// The first §6.1 rule the password violates, or null when it passes.
  /// Used for the plain per-rule error copy in the export UI.
  static String? violationOf(String password) {
    if (!hasMinLength(password)) {
      return 'Use at least $minLength characters.';
    }
    if (!hasLowercase(password)) {
      return 'Add at least one lowercase letter.';
    }
    if (!hasDigit(password)) {
      return 'Add at least one digit.';
    }
    return null;
  }

  static bool _isLowercaseScalar(int rune) {
    final c = String.fromCharCode(rune);
    final lower = c.toLowerCase();
    return lower != c.toUpperCase() && lower == c;
  }

  static bool _isDigitScalar(int rune) => rune >= 0x30 && rune <= 0x39;
}
