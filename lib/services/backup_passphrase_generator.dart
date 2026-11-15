import 'dart:math';

import 'package:danawallet/data/wordlists/eff_large_wordlist.dart';

/// §6.2 generated passphrase option for the export flow.
///
/// A 6-word passphrase sampled uniformly from the EFF large diceware
/// wordlist (7772 lowercase entries here — 77.5 bits over 6 picks, above the
/// ~77-bit target of §6.2). One uniformly chosen word carries a random
/// digit-suffix (the "digit-suffixed entries" mechanism of §6.2, sampling
/// from the wordlist extended with `word.0 … word.9`), so the §6.1 digit
/// rule always passes without user surgery, and adds ~5.9 bits — total
/// ~83 bits per generated passphrase.
///
/// Pure and in-memory: the result is displayed once in the export UI and
/// MUST NOT be persisted anywhere (§6.2). The class holds no storage
/// dependencies by construction; the injectable [Random] and wordlist make
/// the policy conformance testable deterministically.
class BackupPassphraseGenerator {
  BackupPassphraseGenerator({Random? random, List<String>? wordlist})
      : _random = random ?? Random.secure(),
        _wordlist = wordlist ?? kEffLargeWordlist;

  final Random _random;
  final List<String> _wordlist;

  static const int wordCount = 6;

  String generate() {
    final words = List<String>.generate(
        wordCount, (_) => _wordlist[_random.nextInt(_wordlist.length)]);

    // Digit-suffix one uniformly chosen word with one uniform digit (§6.2).
    final position = _random.nextInt(words.length);
    final digit = _random.nextInt(10);
    words[position] = '${words[position]}$digit';

    return words.join(' ');
  }
}
