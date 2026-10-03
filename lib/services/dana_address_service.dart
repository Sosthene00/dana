import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:danawallet/data/models/bip353_address.dart';
import 'package:danawallet/data/models/name_server_challenge_response.dart';
import 'package:danawallet/data/models/prefix_search_response.dart';
import 'package:danawallet/generated/rust/api/bip39.dart';
import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/repositories/name_server_repository.dart';
import 'package:danawallet/services/bip353_resolver.dart';
import 'package:logger/logger.dart';

// --- Challenge-auth registration flow (finding: registerUser never wired) --
// Server-side counterpart: dana-nameserver challenge-auth
// (Sosthene00/dana-nameserver #20). Verify-before-burn semantics: a failed
// signature *verification* keeps the nonce spendable, so the same challenge
// may be re-signed; any nonce-class rejection burns the nonce and requires a
// fresh /challenge. All counters are fixed small integers so a clock-skewed
// device or a misbehaving server can never drive an unbounded loop.
const int _maxSignAttemptsPerChallenge = 3; // initial + two re-signs
// Hard cap on the total number of POST /challenge requests per registerUser
// call. Sized to the matrix: initial challenge + one retry per recovery leg
// (expiry, nonce-class 401, unclassified 401, non-401 transport) — a fixed
// small constant, NOT an unbounded loop, so a clock-skewed device can never
// spin here.
const int _maxChallengesPerRegistration = 6;
const int _maxChallengeRequestsPerStep = 2; // initial + one retry (e.g. 429)
// Back-off before the single /challenge retry (per-peer and server-wide rate
// limits on the nameserver). Milliseconds, kept small on purpose: the loop
// is capped, a long sleep here only delays the user without changing the
// outcome of a rate-limited server.
const List<int> _challengeBackoffMilliseconds = [1000];
// Server NONCE_TTL_SECS = 300; the confirm screen can sit open past it, so
// refresh proactively inside this margin (epoch-seconds comparison).
const int _challengeExpirySafetyMarginSeconds = 10;

/// Server 401 messages that indicate the challenge *signature* failed
/// verification (dana-nameserver challenge-auth verification branch).
/// These do not burn the nonce, so re-signing the same message may succeed.
const List<String> _signatureVerificationPhrases = [
  'Signature verification failed',
  'Invalid signature hex',
  'Invalid signature encoding',
  'Signature must be 64 bytes',
];

/// Server 401 messages that indicate the *nonce* itself is
/// spent/stale/foreign (dana-nameserver ERR_EXPIRED / ERR_NO_CHALLENGE /
/// ERR_MISMATCH). These burn the nonce: the next attempt must start from a
/// fresh /challenge.
const List<String> _nonceRejectionPhrases = [
  'Challenge nonce expired',
  'Invalid or missing nonce',
  'Nonce does not match',
];

/// Raised when the challenge-auth retry matrix consumed the fixed
/// per-registration challenge budget of a
/// [DanaAddressService.registerUser] call. Safe to retry from scratch: the
/// server-side challenge is either burned or expired by then.
class ChallengeRegistrationException implements Exception {
  ChallengeRegistrationException(this.message);

  /// Human-readable summary of why the matrix gave up.
  final String message;

  @override
  String toString() => 'ChallengeRegistrationException: $message';
}

/// Raised when [DanaAddressService.isValidDanaUsername] rejects a username.
class InvalidUsernameException implements Exception {
  InvalidUsernameException(this.message);

  /// Human-readable description of the violated canonical-label rules.
  final String message;

  @override
  String toString() => 'InvalidUsernameException: $message';
}

class DanaAddressService {
  NameServerRepository nameServerRepository;

  /// Signs the server-issued challenge message verbatim and returns the
  /// 64-byte lowercase-hex BIP-340 signature. The production wiring is
  /// [WalletState.signRegistrationChallenge] -> the FRB-exported wallet-held
  /// signer `SpWallet::sign_registration_challenge` (the spend secret never
  /// crosses the FFI boundary). It arrives through the constructor seam,
  /// never a global, so tests inject a fake and the orchestration test file
  /// never imports the FRB bridge.
  ///
  /// Nullable only because the pure-lookup/search/generation call sites
  /// (searchPrefix, lookupDanaAddress, generateAvailableDanaAddress) need no
  /// signer at all; [registerUser] refuses to run without one, so no
  /// registration can be attempted unproven.
  final Future<String> Function(String message)? signChallenge;

  /// Clock seam for the expiry guard and the request-id generator. Tests
  /// inject a frozen/stepped clock instead of sleeping or waiting on wall
  /// time; production keeps [DateTime.now].
  final DateTime Function() _clock;

  /// DNS pre-check seam used by [registerUser]. The production default
  /// is [Bip353Resolver.resolve]; it is a constructor seam because that
  /// helper opens its OWN `http.Client` and is therefore NOT reachable
  /// through the repository's injectable `client` seam — an
  /// orchestration test that injects a MockClient into the repository
  /// would still hit the live DNS-over-HTTPS wire here. Tests inject a
  /// fake so the round-trip legs stay hermetic.
  final Future<String?> Function(Bip353Address address, Network network) _resolve;

  final Network network;
  final Random _random = Random.secure();
  String? _domain;

  DanaAddressService({
    required this.network,
    this.signChallenge,
    Future<String?> Function(Bip353Address address, Network network)? resolve,
    DateTime Function()? clock,
  })  : nameServerRepository = NameServerRepository(network: network),
        _resolve = resolve ?? Bip353Resolver.resolve,
        _clock = clock ?? DateTime.now;

  /// Test seam (mirrors ContactsRepository.forTesting()): injects a complete
  /// [NameServerRepository] (whose own `client` field takes a MockClient),
  /// the DNS pre-check [resolve] fake and, optionally, a fixed [clock].
  /// It never touches the FRB bridge — callers pass [signChallenge] as a
  /// plain fake closure, or leave it null to assert the fail-fast path.
  DanaAddressService.forTesting({
    required this.network,
    this.signChallenge,
    required this.nameServerRepository,
    Future<String?> Function(Bip353Address address, Network network)? resolve,
    DateTime Function()? clock,
  })  : _resolve = resolve ?? Bip353Resolver.resolve,
        _clock = clock ?? DateTime.now;

  /// Character set for a canonical Dana username label: lowercase ASCII
  /// alphanumeric and hyphens, 1 to 63 characters (the nameserver's
  /// `validate_dns_name` contract — the README "Validation Rules" section is
  /// authoritative). Uppercase is rejected, never lowercased: folding case
  /// would fork a second label next to the one the server stored.
  static final RegExp _danaUsernameLabel = RegExp(r"^[a-z0-9-]{1,63}$");

  /// Validates a Dana username against the nameserver-equivalent canonical
  /// DNS-label contract:
  /// - `[a-z0-9-]` only, 1-63 characters
  /// - no leading, trailing, or consecutive hyphens
  /// - uppercase is **rejected**, never silently lowercased
  static bool isValidDanaUsername(String name) {
    if (!_danaUsernameLabel.hasMatch(name)) return false;
    if (name.startsWith("-") || name.endsWith("-")) return false;
    if (name.contains("--")) return false;
    return true;
  }

  Future<String> get danaAddressDomain async {
    // lazy initialization of domain
    _domain ??= (await nameServerRepository.getInfo()).domain;

    return _domain!;
  }

  /// Generates a unique ID for requests without external dependencies
  /// Format: timestamp-randomhex (e.g., "1699889234567-a3f2c9d8")
  String _generateUniqueId() {
    final timestamp = _clock().microsecondsSinceEpoch;
    final randomHex =
        _random.nextInt(0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    return '$timestamp-$randomHex';
  }

  /// Generates a deterministic 3-word alias from entropy using BIP39 wordlist
  /// The alias is generated by using the entropy bytes to select words
  /// [entropy] - The entropy bytes (typically from a SHA-256 hash)
  /// [offset] - Byte offset into the entropy (0, 6, 12, 18, etc.) to use different parts
  String _generateRandomDanaAddress(
      {required String paymentCode, required int offset}) {
    final entropy = _generateEntropyFromPaymentCode(paymentCode);

    final wordlist = getEnglishWordlist();
    final wordlistSize = wordlist.length;

    // Ensure we have enough bytes for the offset
    if (offset + 6 > entropy.length) {
      // If offset is too large, wrap around using modulo
      offset = offset % (entropy.length - 5);
    }

    // Use different parts of the entropy to select 2 words and 1 number
    // This ensures deterministic selection while avoiding collisions
    final word1Index =
        (entropy[offset] << 8 | entropy[offset + 1]) % wordlistSize;
    final word2Index =
        (entropy[offset + 2] << 8 | entropy[offset + 3]) % wordlistSize;
    final numericValue =
        (entropy[offset + 4] << 8 | entropy[offset + 5]) % 1000;

    return '${wordlist[word1Index]}-${wordlist[word2Index]}-$numericValue';
  }

  /// Generates entropy (SHA-256 hash) from an address
  List<int> _generateEntropyFromPaymentCode(String paymentCode) {
    final bytes = utf8.encode(paymentCode);
    final hash = sha256.convert(bytes);
    return hash.bytes;
  }

  /// Generate an available dana address by trying different username candidates
  /// Returns the first available username found within maxRetries attempts, or null if all are taken
  ///
  /// Availability is probed via DNS only (Bip353Resolver), never via
  /// /challenge: a challenge (and its nonce) is bound to one exact
  /// user_name, so each candidate would need its OWN /challenge anyway —
  /// probing here must not pre-fetch or reuse one across candidates.
  Future<String?> generateAvailableDanaAddress({
    required String paymentCode,
    required int maxRetries,
  }) async {
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      final username = _generateRandomDanaAddress(
        paymentCode: paymentCode,
        offset:
            attempt * 6, // Each attempt uses 6 bytes (2 bytes per word/number)
      );
      final isAvailable = await isDanaUsernameAvailable(username);
      if (isAvailable) {
        return username;
      }
    }
    return null;
  }

  /// Creates a dana address by calling the external name_server
  ///
  /// Runs the full challenge handshake that the nameserver's challenge-auth
  /// (dana-nameserver #20) requires before it accepts a registration:
  ///
  ///   POST /challenge  ->  sign the server message EXACTLY as returned
  ///   (FRB wallet-held signer)  ->  POST /register
  ///   {id, domain, user_name, sp_address, nonce, signature}
  ///
  /// Retry matrix (every leg is exercised by
  /// test/services/dana_challenge_registration_test.dart):
  /// - 401 whose server message matches a signature-verification failure
  ///   does NOT burn the nonce: the same challenge is re-signed (bounded by
  ///   [_maxSignAttemptsPerChallenge]), no fresh /challenge is fetched;
  /// - a challenge whose `expiresAt` is at/past the (margin-adjusted) clock
  ///   — the "confirm screen sat open longer than the 300 s TTL" case — is
  ///   replaced by a FULL re-challenge from scratch BEFORE signing; the
  ///   server never told us an expired nonce stays spendable, so the client
  ///   must assume the worst;
  /// - 401 with a nonce-class message (expired / unknown / mismatched)
  ///   burns the nonce: full re-challenge from scratch;
  /// - any NON-401 failure (5xx / Cloudflare / DNS / parse) after the
  ///   signature was produced also burns the nonce under server semantics:
  ///   one re-challenge, and if the original error persists it resurfaces
  ///   verbatim so the caller still sees the transport problem;
  /// - 429 (per-peer / server-wide rate limit) on POST /challenge: back off
  ///   once, then re-challenge; exhaustion surfaces the originating
  ///   [ChallengeRejectedException] — the client never spins on a rate
  ///   limiter;
  /// - the total number of /challenge requests is hard-capped
  ///   ([_maxChallengesPerRegistration]) so a clock-skewed device cannot loop
  ///   unbounded.
  ///
  /// [username] must already be a canonical lowercase label; it is validated
  /// via [isValidDanaUsername] and never silently rewritten (uppercase is
  /// rejected, not folded, to avoid forking a second label next to the
  /// registered one).
  ///
  /// [danaAddress] - The address to register.
  /// [requestId] - The unique id for this request, can be useful for tracking requests.
  ///
  /// Returns [DanaAddressCreationResponse] with the created address or error details
  Future<Bip353Address> registerUser({
    required String username,
    required String paymentCode,
  }) async {
    if (!isValidDanaUsername(username)) {
      throw InvalidUsernameException(
          'Username must be a lowercase DNS label (1-63 characters of '
          '[a-z0-9-], no leading, trailing or consecutive hyphens): '
          '"$username" was rejected');
    }

    // The challenge proof is mandatory: a registration without a signer can
    // only ever post an unprovable body, which a challenge-enforcing
    // nameserver (dana-nameserver #20) 401s. Fail before touching the
    // network — even before the lazy GET /info that [danaAddressDomain]
    // triggers — instead of forking an unauthenticated registration attempt.
    final signer = signChallenge;
    if (signer == null) {
      throw StateError(
          'registerUser requires the signChallenge injection: a dana '
          'registration must be proven with a challenge signature');
    }

    final requestId = _generateUniqueId();
    final domain = await danaAddressDomain;
    final Bip353Address danaAddress;

    // We try to resolve the address first to see if it already exists
    try {
      danaAddress = Bip353Address(username: username, domain: domain);
      final resolvedPaymentCode =
          await _resolve(danaAddress, network);
      if (resolvedPaymentCode == null) {
        // Address not registered yet, proceed with registration
        Logger().i(
            'Address $username@$domain not found, proceeding with registration');
      } else if (resolvedPaymentCode == paymentCode) {
        // If we find our address, return success there's nothing more to do
        return danaAddress;
      } else if (resolvedPaymentCode != paymentCode) {
        // If we find another address, return error, user must try with a different username
        throw Exception("Dana address already in use");
      }
    } catch (e) {
      // Network or parsing error - we'll let name server try and if it exists it will return an error
      Logger().e('Failed to resolve address for user $username: $e');
      rethrow;
    }

    final challengeBudget = _ChallengeBudget(_maxChallengesPerRegistration);

    var challenge = await _requestChallenge(
      userName: username,
      domain: domain,
      spAddress: paymentCode,
      budget: challengeBudget,
    );

    var signAttemptsUsed = 0;

    while (true) {
      // Proactive expiry guard: the server issued this nonce with
      // NONCE_TTL_SECS = 300; if the confirm screen sat open past (or near)
      // it, re-challenge before burning a signature on a doomed nonce.
      // Deliberately NOT routed through the 401 matrix: absence/presence of
      // `expiresAt` is a server contract detail, and a client-measured
      // expiry must always be treated as burned => a full re-challenge
      // from scratch (see the retry matrix above).
      if (_isChallengeExpired(challenge)) {
        Logger().i(
            'Challenge nonce at/past expiry (expiresAt=${challenge.expiresAt} '
            'vs clock), re-challenging from scratch');
        challenge = await _requestChallenge(
          userName: username,
          domain: domain,
          spAddress: paymentCode,
          budget: challengeBudget,
        );
        signAttemptsUsed = 0;
        continue;
      }

      // Sign the message EXACTLY as the server returned it, with the
      // wallet-held spend key through the FRB bridge (the secret never
      // crosses the FFI boundary). The bytes we sign are the bytes the
      // server must have produced — requestChallenge already verified the
      // binding before handing the message over.
      final signature = await signer(challenge.message);
      signAttemptsUsed++;

      try {
        return await nameServerRepository.registerDanaAddress(
          danaAddress: danaAddress,
          paymentCode: paymentCode,
          requestId: requestId,
          nonce: challenge.nonce,
          signature: signature,
        );
      } on RegisterRejectedException catch (e) {
        final message = e.message;
        if (_matchesAny(message, _signatureVerificationPhrases)) {
          if (signAttemptsUsed < _maxSignAttemptsPerChallenge) {
            // Verify-before-burn: the nonce is still good, so re-sign the
            // SAME challenge (no fresh /challenge call) — bounded by
            // _maxSignAttemptsPerChallenge.
            Logger().w(
                'Registration rejected on signature verification, re-signing '
                'the same challenge ($signAttemptsUsed/$_maxSignAttemptsPerChallenge): $message');
            continue;
          }
          throw ChallengeRegistrationException(
              'Signature kept failing verification on the same challenge '
              'after $signAttemptsUsed signing attempt(s): $message');
        }
        if (_matchesAny(message, _nonceRejectionPhrases)) {
          // Nonce-class rejection: the nonce is burned; full re-challenge
          // from scratch, bounded by the per-registration budget.
          Logger().w(
              'Registration rejected on nonce, re-challenging from scratch: $message');
          challenge = await _requestChallenge(
            userName: username,
            domain: domain,
            spAddress: paymentCode,
            budget: challengeBudget,
          );
          signAttemptsUsed = 0;
          continue;
        }
        // Unknown 401 semantics: the server proved nothing about the nonce,
        // so we must assume it burned. Re-challenge once (budget-bounded);
        // if the same unknown 401 comes back, the originating rejection
        // resurfaces verbatim for the caller to surface.
        Logger().w(
            'Registration rejected with unclassified 401 message, treating '
            'the nonce as burned and re-challenging once: $message');
        try {
          challenge = await _requestChallenge(
            userName: username,
            domain: domain,
            spAddress: paymentCode,
            budget: challengeBudget,
          );
        } on ChallengeRejectedException {
          throw e; // surface the originating registration rejection
        }
        signAttemptsUsed = 0;
        continue;
      } catch (e) {
        // Any non-401 failure (5xx / Cloudflare / DNS / parse) after the
        // signature was produced burns the nonce under server semantics:
        // re-challenge once, budget-bounded. The original error is kept as
        // the fall-back so the caller still sees the real transport problem.
        Logger().w(
            'Registration attempt failed without a challenge verdict ($e); '
            'treating the nonce as burned and re-challenging once');
        try {
          challenge = await _requestChallenge(
            userName: username,
            domain: domain,
            spAddress: paymentCode,
            budget: challengeBudget,
          );
        } on ChallengeRejectedException {
          throw e; // surface the originating transport error
        } on ChallengeRegistrationException {
          throw e; // surface the originating transport error, not the budget
        }
        signAttemptsUsed = 0;
        continue;
      }
    }
  }

  /// POST /challenge, at most [_maxChallengeRequestsPerStep] requests per
  /// step (initial + one back-offed retry), overall capped by [budget].
  /// A never-succeeding step rethrows the originating error verbatim; a
  /// spent budget raises [ChallengeRegistrationException].
  Future<NameServerChallengeResponse> _requestChallenge({
    required String userName,
    required String domain,
    required String spAddress,
    required _ChallengeBudget budget,
  }) async {
    budget.take();
    for (var attempt = 0;; attempt++) {
      Object error;
      try {
        return await nameServerRepository.requestChallenge(
          userName: userName,
          domain: domain,
          spAddress: spAddress,
          requestId: _generateUniqueId(),
        );
      } catch (e) {
        // 429 (per-peer 10 outstanding / server-wide), malformed 200 bodies
        // and transport failures all land here: they are transient-by-design
        // retryable rejections, so back off once and ask again. Anything
        // still failing after the single retry surfaces verbatim.
        error = e;
      }
      if (attempt >= _maxChallengeRequestsPerStep - 1) {
        throw error;
      }
      final ms = _challengeBackoffMilliseconds[
          attempt.clamp(0, _challengeBackoffMilliseconds.length - 1)];
      Logger().w('Challenge request rejected ($error), '
          'backing off ${ms}ms and retrying once');
      await Future<void>.delayed(Duration(milliseconds: ms));
    }
  }

  /// True when [challenge] carries an `expiresAt` at or before the
  /// margin-adjusted clock. A null `expiresAt` is treated as *not* expired:
  /// the nameserver always sends the field today, and its absence is no
  /// reason to refuse to register (the 401 matrix still covers a stale
  /// nonce).
  bool _isChallengeExpired(NameServerChallengeResponse challenge) {
    final expiresAt = challenge.expiresAt;
    if (expiresAt == null) return false;
    final nowSeconds = _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
    return nowSeconds >= expiresAt - _challengeExpirySafetyMarginSeconds;
  }

  bool _matchesAny(String message, List<String> phrases) =>
      phrases.any((p) => message.toLowerCase().contains(p.toLowerCase()));

  /// Looks up dana addresses associated with a silent payment address.
  /// Also verifies if the returned Dana address by doing a DNS query
  ///
  /// [paymentCode] - The Silent Payment address to lookup
  ///
  /// Returns the first valid dana address that is found.
  /// Returns a list of dana addresses in the format `user_name@danawallet.app`
  /// Returns an empty list if no addresses are found
  /// Throws an exception for network errors, invalid responses, or malformed data
  Future<Bip353Address?> lookupDanaAddress(String paymentCode) async {
    if (paymentCode.isEmpty) {
      throw ArgumentError("Silent payment address cannot be empty");
    }

    final requestId = _generateUniqueId();
    final addresses =
        await nameServerRepository.lookupDanaAddresses(paymentCode, requestId);

    Logger().i('Found ${addresses.length} dana address(es) for SP address');

    for (var candidate in addresses) {
      if (await Bip353Resolver.verifyPaymentCode(
          candidate, paymentCode, network)) {
        // we just return the first valid candidate
        return candidate;
      } else {
        Logger()
            .w("Name server returned an address that doesn't resolve to ours");
      }
    }
    return null;
  }

  /// Check if a dana address is available for registration
  /// Returns true if the dana address is not taken, false otherwise
  Future<bool> isDanaUsernameAvailable(String username) async {
    try {
      final domain = await danaAddressDomain;
      final parsed = Bip353Address(username: username, domain: domain);
      return await Bip353Resolver.isBip353AddressPresent(parsed, network);
    } catch (e) {
      // If we can't resolve due to network error, assume it's taken to be safe
      Logger().e('Error checking address availability: $e');
      return false;
    }
  }

  /// Searches for dana addresses by prefix
  ///
  /// [prefix] - The prefix to search for (e.g., "alice" to find "alice@domain.com")
  ///
  /// Returns [PrefixSearchResponse] with matching dana addresses
  /// Throws an exception for network errors, invalid responses, or malformed data
  Future<List<Bip353Address>> searchPrefix(String prefix) async {
    if (prefix.isEmpty) {
      throw ArgumentError("Prefix cannot be empty");
    }

    try {
      final requestId = _generateUniqueId();
      final response = await nameServerRepository.searchDanaAddressesWithPrefix(
          prefix, requestId);
      return response.danaAddresses;
    } catch (e) {
      Logger().e('Prefix search request failed for prefix "$prefix": $e');
      throw Exception('Prefix search request failed: $e');
    }
  }
}

/// Hard cap on the total number of POST /challenge requests a single
/// registerUser call may issue, so no server behaviour and no clock skew can
/// drive the retry matrix into an unbounded loop.
class _ChallengeBudget {
  _ChallengeBudget(this._remaining);

  int _remaining;

  /// Consumes one unit; throws [ChallengeRegistrationException] when the
  /// budget is spent.
  void take() {
    if (_remaining <= 0) {
      throw ChallengeRegistrationException(
          'Challenge-auth registration gave up: the fixed per-registration '
          'challenge budget was exhausted');
    }
    _remaining--;
  }
}
