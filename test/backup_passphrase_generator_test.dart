import 'dart:math';

import 'package:danawallet/data/wordlists/eff_large_wordlist.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/services/backup_passphrase_generator.dart';
import 'package:danawallet/services/backup_service.dart';
import 'package:danawallet/utils/backup_password_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// §6.2 generated passphrase acceptance:
///  - passes the §6.1 policy programmatically (every sample),
///  - is a 6-word space-separated passphrase from a wordlist that carries
///    digit-bearing entries (the digit-suffix mechanism of §6.2),
///  - is never persisted anywhere (no storage write on the generate path).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackupPassphraseGenerator (spec §6.2)', () {
    test('generates a 6-word space-separated passphrase', () {
      final generator =
          BackupPassphraseGenerator(random: RandomStub(firstDigitWord: 0));
      final passphrase = generator.generate();
      final words = passphrase.split(' ');
      expect(words, hasLength(6));
      expect(passphrase, isNot(contains('  ')));
    });

    test('passes the §6.1 policy programmatically over many samples', () {
      // Deterministic stream so failures are reproducible.
      var counter = 0;
      final generator = BackupPassphraseGenerator(
        random: _CounterRandom(() => counter++),
      );
      for (var i = 0; i < 500; i++) {
        final passphrase = generator.generate();
        final violation = BackupPasswordPolicy.violationOf(passphrase);
        expect(violation, isNull,
            reason: 'sample $i violated §6.1: "$passphrase" ($violation)');
      }
    });

    test('every sample contains a digit (wordlist digit-bearing mechanism)',
        () {
      var counter = 0;
      final generator = BackupPassphraseGenerator(
        random: _CounterRandom(() => counter++),
      );
      for (var i = 0; i < 200; i++) {
        expect(BackupPasswordPolicy.hasDigit(generator.generate()), isTrue);
      }
    });

    test('wordlist entries are lowercase [a-z]+ words', () {
      expect(kEffLargeWordlist.length, greaterThanOrEqualTo(7770));
      final re = RegExp(r'^[a-z]+$');
      for (final word in kEffLargeWordlist.take(500)) {
        expect(re.hasMatch(word), isTrue, reason: word);
      }
      expect(kEffLargeWordlist.toSet().length, kEffLargeWordlist.length);
    });

    test('generation is deterministic under a fixed Random', () {
      final a = BackupPassphraseGenerator(
          random: RandomStub(firstDigitWord: 2, wordSeed: 7));
      final b = BackupPassphraseGenerator(
          random: RandomStub(firstDigitWord: 2, wordSeed: 7));
      expect(a.generate(), b.generate());
    });

    test('generator output differs across samples (not constant)', () {
      var counter = 0;
      final generator = BackupPassphraseGenerator(
        random: _CounterRandom(() => counter++),
      );
      final seen = <String>{for (var i = 0; i < 50; i++) generator.generate()};
      expect(seen.length, greaterThan(40));
    });
  });

  group('generate path never persists (spec §6.2: MUST NOT persist)', () {
    late InMemorySharedPreferencesAsync backend;

    setUp(() {
      backend = InMemorySharedPreferencesAsync.empty();
      SharedPreferencesAsyncPlatform.instance = backend;
    });

    test('BackupService.generatePassphrase writes nothing to storage', () async {
      final service = BackupService();

      for (var i = 0; i < 100; i++) {
        final passphrase = service.generatePassphrase();
        expect(passphrase, isNotEmpty);
      }

      // Read back everything the generate path could have touched: the
      // backup status date and the raw backing store are both untouched.
      final repo = SettingsRepository.instance;
      expect(await repo.getLastBackupDate(), isNull);
      final keys = await SharedPreferencesAsync().getKeys();
      expect(keys, isEmpty);
    });

    test('the generator itself has no storage dependency', () {
      // The generator is constructed with only a Random and a wordlist —
      // there is no repository, no platform channel and no I/O object in
      // its constructor signature, so persistence is impossible by shape.
      final generator = BackupPassphraseGenerator(random: RandomStub());
      expect(generator.generate(), isNotEmpty);
    });
  });
}

/// Fully deterministic Random: returns [wordSeed] for word picks and puts
/// the digit suffix on word [firstDigitWord].
class RandomStub implements Random {
  RandomStub({this.wordSeed = 0, this.firstDigitWord = 0});

  final int wordSeed;
  final int firstDigitWord;
  bool _suffixed = false;

  @override
  int nextInt(int max) {
    if (max == 10) {
      // The digit pick: any digit works; return 7.
      return 7;
    }
    if (!_suffixed) {
      // Word-position pick (max == 6): put the suffix on firstDigitWord.
      _suffixed = true;
      return firstDigitWord;
    }
    return wordSeed % max;
  }

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0.0;
}

/// Cycles through increasing values so every sample differs.
class _CounterRandom implements Random {
  _CounterRandom(this._next);

  final int Function() _next;

  @override
  int nextInt(int max) => _next() % max;

  @override
  bool nextBool() => _next().isOdd;

  @override
  double nextDouble() => 0.5;
}
