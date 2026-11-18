use anyhow::{anyhow, Result};
use spdk_wallet::bitcoin::hashes::{sha256, Hash};
use spdk_wallet::bitcoin::secp256k1::{self, Keypair, Message, SecretKey};

/// All challenge messages signed by the wallet-held signer must carry this prefix as
/// their first colon-separated field. The nameserver (Sosthene00/
/// dana-nameserver issue #20) only ever accepts attestations over messages
/// beginning with it; refusing anything else keeps this from turning into an
/// arbitrary-string signing oracle on the spend key.
pub const CHALLENGE_PREFIX: &str = "dana-register:";

/// The prefix without its trailing colon: the exact text of the first
/// colon-separated field of a v1 message (`split(':')` yields it bare).
const CHALLENGE_SCHEME: &str = "dana-register";

/// Spec v1 tag: a signable message is
/// `dana-register:v1:{network_key}:{nonce}:{user_name}:{domain}:{sp_address}`
/// (spec section 3). The Rust core is the authority on this grammar: a
/// message outside it never reaches the signer. The Dart rebuild-and-exact-
/// match check in `name_server_repository.dart` stays as a redundant second
/// guard in front of this one.
pub const V1_TAG: &str = "v1";

/// Pinned per-network client network_key constants (D7). These mirror the
/// values the nameserver derives from the registered SP address's network
/// (dana-nameserver src/main.rs `/challenge`): Mainnet => "sp",
/// Testnet => "tsp". The server refuses regtest challenges outright, so a
/// regtest wallet has no acceptable network_key and fails closed.
pub const NETWORK_KEY_MAINNET: &str = "sp";
pub const NETWORK_KEY_TESTNET: &str = "tsp";

/// Username grammar bounds (spec section 3): 1..=64 bytes.
const USER_NAME_MIN: usize = 1;
const USER_NAME_MAX: usize = 64;

/// The nonce is the lowercase-hex encoding of the server's 32 random bytes
/// (dana-nameserver src/main.rs: `hex::encode(32 bytes)`) — 64 chars.
const NONCE_LEN: usize = 64;

/// Byte-level grammar of the spec section 3 v1 challenge message. Returns
/// the seven `:`-separated fields
/// `[prefix, tag, network_key, nonce, user_name, domain, sp_address]`.
///
/// Rules, all enforced byte-for-byte with no case-folding and no Unicode
/// normalization (D5, D8 — anything outside the grammar is rejected, never
/// repaired):
/// - the whole message is pure ASCII;
/// - exactly seven colon-separated fields;
/// - field 0 is [`CHALLENGE_PREFIX`], field 1 is [`V1_TAG`] (v1 prefix);
/// - `network_key` is one of the pinned per-network client constants (D7);
/// - `nonce` is exactly [`NONCE_LEN`] lowercase hex chars;
/// - `user_name` is [`USER_NAME_MIN`]..=[`USER_NAME_MAX`] chars of
///   `[a-z0-9-]`;
/// - `domain` is non-empty lowercase DNS-name chars `[a-z0-9.-]`;
/// - `sp_address` is present (non-empty).
fn split_v1(message: &str) -> Result<[&str; 7]> {
    if !message.is_ascii() {
        return Err(anyhow!(
            "challenge message must be pure ASCII (D5/D8: no case folding, \
             no Unicode normalization — non-ASCII is rejected outright)"
        ));
    }
    let parts: Vec<&str> = message.split(':').collect();
    if parts.len() != 7 {
        return Err(anyhow!(
            "challenge message must have exactly 6 ':'-separated fields \
             after the prefix, found {}",
            parts.len().saturating_sub(1)
        ));
    }
    let [prefix, tag, network_key, nonce, user_name, domain, sp_address] =
        parts.try_into().expect("length checked above");
    if prefix != CHALLENGE_SCHEME || tag != V1_TAG {
        return Err(anyhow!(
            "challenge message must start with '{CHALLENGE_PREFIX}{V1_TAG}:'"
        ));
    }
    if network_key != NETWORK_KEY_MAINNET && network_key != NETWORK_KEY_TESTNET {
        return Err(anyhow!(
            "unknown network_key '{network_key}': must be '{NETWORK_KEY_MAINNET}' \
             (mainnet) or '{NETWORK_KEY_TESTNET}' (testnet) (D7)"
        ));
    }
    if nonce.len() != NONCE_LEN
        || !nonce
            .bytes()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
    {
        return Err(anyhow!(
            "nonce must be exactly {NONCE_LEN} lowercase hex chars (the server \
             mints the hex encoding of 32 random bytes)"
        ));
    }
    if !is_valid_user_name(user_name) {
        return Err(anyhow!(
            "user_name must be {}..={} chars of [a-z0-9-] (D5/D8: no case \
             folding, no Unicode normalization)",
            USER_NAME_MIN,
            USER_NAME_MAX
        ));
    }
    if domain.is_empty()
        || !domain
            .bytes()
            .all(|b| matches!(b, b'a'..=b'z' | b'0'..=b'9' | b'.' | b'-'))
    {
        return Err(anyhow!(
            "domain must be non-empty lowercase DNS-name chars [a-z0-9.-]"
        ));
    }
    if sp_address.is_empty() {
        return Err(anyhow!("sp_address field must be present (non-empty)"));
    }
    Ok([
        prefix,
        tag,
        network_key,
        nonce,
        user_name,
        domain,
        sp_address,
    ])
}

/// Full grammar check: `Ok(())` iff the message matches the spec section 3
/// v1 byte-level grammar.
pub(crate) fn validate_challenge_grammar(message: &str) -> Result<()> {
    split_v1(message).map(|_| ())
}

/// Validated `network_key` field of a spec v1 challenge message. The
/// wallet-held signer cross-checks this against its own network's pinned
/// client constant before signing (D7).
pub(crate) fn challenge_network_key(message: &str) -> Result<&str> {
    Ok(split_v1(message)?[2])
}

/// Username grammar (spec section 3, D5, D8): 1-64 chars of `[a-z0-9-]`.
/// No case-folding and no Unicode normalization happen here: anything the
/// rule rejects is rejected byte-for-byte.
pub(crate) fn is_valid_user_name(user_name: &str) -> bool {
    let len = user_name.len();
    (USER_NAME_MIN..=USER_NAME_MAX).contains(&len)
        && user_name
            .bytes()
            .all(|b| matches!(b, b'a'..=b'z' | b'0'..=b'9' | b'-'))
}

/// The SHA-256 digest the nameserver expects under a BIP-340 `Message`
/// (README @ fe1c49d defines this pre-hash contract).
fn challenge_digest(message: &str) -> [u8; 32] {
    sha256::Hash::hash(message.as_bytes()).to_byte_array()
}

/// D9: the BIP-340 auxiliary random data fallback — the constant 32-byte
/// zero array, used verbatim when the signing environment has no RNG and
/// pinned by tests so fixed vectors stay byte-for-byte reproducible.
pub(crate) const ZERO_AUX: [u8; 32] = [0u8; 32];

/// D9: fresh uniform-random 32 bytes of auxiliary data per signing call.
/// Falls back to the constant 32-byte zero array ([`ZERO_AUX`]) when no RNG
/// is available. The aux source is injectable — [`sign_challenge_inner`]
/// takes the aux bytes — so tests pin a constant and stay reproducible.
pub(crate) fn fresh_aux_rand() -> [u8; 32] {
    use rand::{rngs::OsRng, TryRngCore};
    aux_rand_from(|buf| {
        OsRng.try_fill_bytes(buf)
            .map_err(|e| std::io::Error::other(format!("no RNG available: {e}")))
    })
}

/// Seam for [`fresh_aux_rand`]: fills the buffer from the injected source;
/// any failure yields the constant zero array (D9 fallback). The failure
/// branch of the injected source lets tests cover the fallback directly.
pub(crate) fn aux_rand_from(fill: impl FnOnce(&mut [u8; 32]) -> std::io::Result<()>) -> [u8; 32] {
    let mut aux = ZERO_AUX;
    if fill(&mut aux).is_err() {
        aux = ZERO_AUX;
    }
    aux
}

/// The single signing core: enforces the full spec v1 grammar (D5/D7/D8)
/// before anything is signed and pre-hashes the message with SHA-256 — the
/// digest, never the raw preimage, goes into the BIP-340 `Message` (see
/// `raw_preimage_signature_does_not_verify`, which locks that contract with
/// the nameserver). `aux_rand` is injected (D9): the wallet-held call site
/// ([`super::SpWallet::sign_registration_challenge`]) passes
/// [`fresh_aux_rand`]; tests pin a constant for byte-for-byte reproducibility.
pub(crate) fn sign_challenge_inner(
    sk: &SecretKey,
    message: &str,
    aux_rand: &[u8; 32],
) -> Result<secp256k1::schnorr::Signature> {
    validate_challenge_grammar(message)?;

    let secp = secp256k1::Secp256k1::signing_only();
    let keypair = Keypair::from_secret_key(&secp, sk);
    let msg = Message::from_digest(challenge_digest(message));
    Ok(secp.sign_schnorr_with_aux_rand(&msg, &keypair, aux_rand))
}

#[cfg(test)]
mod tests {
    use super::*;
    use spdk_wallet::bitcoin::secp256k1::schnorr::Signature;
    use spdk_wallet::bitcoin::secp256k1::{Secp256k1, XOnlyPublicKey};
    use std::str::FromStr;

    /// Test-only stand-in for the hex-secret signing oracle removed from the
    /// release FFI surface (D4, INV-3): signs through the shared
    /// `sign_challenge_inner` core with the pinned D9 aux (the zero array) so
    /// every pre-existing assertion keeps its exact meaning.
    fn sign_challenge(spend_secret: &str, message: &str) -> Result<String> {
        let sk = SecretKey::from_str(spend_secret)?;
        let sig = sign_challenge_inner(&sk, message, &ZERO_AUX)?;
        Ok(sig
            .serialize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect())
    }

    /// Fixed spend secret (sk = 1) so the produced signature is a
    const SK_HEX: &str = "0000000000000000000000000000000000000000000000000000000000000001";
    /// A valid spec v1 challenge message (testnet network_key): the server's
    /// 64-char lowercase-hex nonce, a grammar-clean username, a lowercase
    /// domain and a present sp_address, in the exact field order.
    const MSG: &str = "dana-register:v1:tsp:9f2c7a4e1b8d3f6a05c2e8b47d1a9f3c6e0b2a8d4f17c3e9a2b5d8f0c1e4a7b9:satoshi:danawallet.app:sp1qqgste7k9hx0qftg6t50mu0vsgu27y8u9rw6e3mvffpd";
    const VALID_NONCE: &str = "9f2c7a4e1b8d3f6a05c2e8b47d1a9f3c6e0b2a8d4f17c3e9a2b5d8f0c1e4a7b9";

    /// Builds a v1 message from explicit fields (test-matrix helper).
    fn v1_with(
        network_key: &str,
        nonce: &str,
        user_name: &str,
        domain: &str,
        sp_address: &str,
    ) -> String {
        format!("{CHALLENGE_PREFIX}{V1_TAG}:{network_key}:{nonce}:{user_name}:{domain}:{sp_address}")
    }

    /// The (x-only, even-parity-normalised) verification key belonging to
    /// `sk`, via the 0.29 `SecretKey::x_only_public_key` path.
    fn xonly_even(sk: &SecretKey) -> XOnlyPublicKey {
        let secp = Secp256k1::signing_only();
        sk.x_only_public_key(&secp).0
    }

    fn hex_val(c: u8) -> Option<u8> {
        match c {
            b'0'..=b'9' => Some(c - b'0'),
            b'a'..=b'f' => Some(c - b'a' + 10),
            _ => None,
        }
    }

    fn from_hex(s: &str) -> Option<Vec<u8>> {
        if !s.len().is_multiple_of(2) {
            return None;
        }
        s.as_bytes()
            .chunks(2)
            .map(|c| Some(hex_val(c[0])? * 16 + hex_val(c[1])?))
            .collect::<Option<Vec<u8>>>()
    }

    fn verify(sig: &Signature, msg: &Message, sk: &SecretKey) -> Result<(), secp256k1::Error> {
        let secp = Secp256k1::verification_only();
        secp.verify_schnorr(sig, msg, &xonly_even(sk))
    }

    #[test]
    fn fixed_vectors_sign_and_verify() {
        let sig_hex = sign_challenge(SK_HEX, MSG).unwrap();
        // 64-byte signature => 128 lowercase-hex chars.
        assert_eq!(sig_hex.len(), 128);
        assert!(sig_hex
            .chars()
            .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)));
        let bytes = from_hex(&sig_hex).expect("output is even-length hex");
        assert_eq!(bytes.len(), 64);

        let sig = Signature::from_slice(&bytes).unwrap();
        // Verification goes through the SAME sha256-digest path the wallet
        // signed: Message::from_digest(sha256(message)), rebuilt here
        // independently of the signing helper.
        let digest = sha256::Hash::hash(MSG.as_bytes()).to_byte_array();
        let msg = Message::from_digest(digest);
        let sk = SecretKey::from_str(SK_HEX).unwrap();
        verify(&sig, &msg, &sk).expect("fixed-vector signature must verify");
    }

    #[test]
    fn raw_preimage_signature_does_not_verify() {
        // Locks the sha256 pre-hash contract with the nameserver (README @
        // fe1c49d): a signature made over the RAW message bytes (no sha256)
        // must fail verification against the digest the wallet actually signs.
        // A BIP-340 `Message` is exactly 32 bytes, so "raw" here is the
        // first 32 bytes of the preimage taken verbatim, un-hashed.
        let sk = SecretKey::from_str(SK_HEX).unwrap();
        let secp = Secp256k1::signing_only();
        let keypair = Keypair::from_secret_key(&secp, &sk);
        let raw = Message::from_digest_slice(&MSG.as_bytes()[..32]).unwrap();
        let raw_sig = secp.sign_schnorr_no_aux_rand(&raw, &keypair);

        let digest_msg = Message::from_digest(challenge_digest(MSG));
        assert!(
            verify(&raw_sig, &digest_msg, &sk).is_err(),
            "signature over the raw preimage must NOT verify against the sha256 digest"
        );

        // ... and the wallet-produced signature *does* verify against the
        // digest — so the mismatch above is about the pre-hash, not a key bug.
        let wallet_sig = sign_challenge_inner(&sk, MSG, &ZERO_AUX).unwrap();
        verify(&wallet_sig, &digest_msg, &sk)
            .expect("wallet signature verifies against the digest path");
    }

    #[test]
    fn malformed_secret_hex_is_rejected() {
        // Err, never panic.
        assert!(sign_challenge("not-hex", MSG).is_err());
        assert!(sign_challenge("", MSG).is_err());
        assert!(sign_challenge("00", MSG).is_err()); // wrong length
        assert!(sign_challenge("0", MSG).is_err()); // odd length
        let over_long = "ff".repeat(64);
        assert!(sign_challenge(&over_long, MSG).is_err()); // > 32 bytes
    }

    #[test]
    fn valid_v1_message_parses_with_exact_field_order() {
        let [prefix, tag, network_key, nonce, user_name, domain, sp_address] =
            split_v1(MSG).unwrap();
        assert_eq!(prefix, "dana-register");
        assert_eq!(tag, "v1");
        assert_eq!(network_key, "tsp");
        assert_eq!(nonce, VALID_NONCE);
        assert_eq!(user_name, "satoshi");
        assert_eq!(domain, "danawallet.app");
        assert!(sp_address.starts_with("sp1q"));
        assert!(validate_challenge_grammar(MSG).is_ok());
        assert_eq!(challenge_network_key(MSG).unwrap(), "tsp");
    }

    #[test]
    fn messages_outside_the_v1_grammar_are_rejected() {
        // No arbitrary-string signing oracle on the spend key.
        assert!(sign_challenge(SK_HEX, "please send coins").is_err());
        assert!(sign_challenge(SK_HEX, "").is_err());
        // Missing v1 tag: the pre-v1 wire shape is rejected byte-for-byte.
        let pre_v1 = format!("{CHALLENGE_PREFIX}tsp:{VALID_NONCE}:satoshi:danawallet.app:sp1qabc");
        assert!(sign_challenge(SK_HEX, &pre_v1).is_err());
        // Bare prefix (accepted pre-v1) is no longer signable.
        assert!(sign_challenge(SK_HEX, CHALLENGE_PREFIX).is_err());
        // Prefix case is exact — no case-folding rescue (D5).
        let case_folded = format!(
            "Dana-register:{}:tsp:{VALID_NONCE}:satoshi:danawallet.app:sp1qabc",
            V1_TAG
        );
        assert!(sign_challenge(SK_HEX, &case_folded).is_err());
        // Wrong field count (one field short) is outside the grammar.
        let short = format!("{CHALLENGE_PREFIX}{V1_TAG}:tsp:{VALID_NONCE}:satoshi:danawallet.app");
        assert!(sign_challenge(SK_HEX, &short).is_err());
    }

    #[test]
    fn each_field_violation_is_rejected() {
        // network_key: unknown value, wrong case, empty — fail closed (D7).
        for network_key in ["btc", "SP", "Tsp", "sp1q", ""] {
            let msg = v1_with(network_key, VALID_NONCE, "satoshi", "danawallet.app", "sp1qabc");
            assert!(
                sign_challenge(SK_HEX, &msg).is_err(),
                "network_key {network_key:?} must be rejected"
            );
        }
        // nonce: empty, wrong length, non-hex, uppercase hex.
        for nonce in [
            "",
            "abc",
            &"ab".repeat(63),
            &"ab".repeat(65),
            &"F".repeat(64),
            &"g".repeat(64),
        ] {
            let msg = v1_with("tsp", nonce, "satoshi", "danawallet.app", "sp1qabc");
            assert!(sign_challenge(SK_HEX, &msg).is_err(), "nonce {nonce:?} must be rejected");
        }
        // user_name: empty, uppercase, underscore, space, invalid unicode
        // (no normalization rescue — D8), over-long.
        for user_name in [
            "",
            "Satoshi",
            "sat_oshi",
            "sat oshi",
            "sätoshi",
            "satoshí",
            &"a".repeat(65),
        ] {
            let msg = v1_with("tsp", VALID_NONCE, user_name, "danawallet.app", "sp1qabc");
            assert!(
                sign_challenge(SK_HEX, &msg).is_err(),
                "user_name {user_name:?} must be rejected"
            );
        }
        // domain: empty, uppercase (no case folding), spaces.
        for domain in ["", "Danawallet.app", "dana wallet.app"] {
            let msg = v1_with("tsp", VALID_NONCE, "satoshi", domain, "sp1qabc");
            assert!(
                sign_challenge(SK_HEX, &msg).is_err(),
                "domain {domain:?} must be rejected"
            );
        }
        // sp_address absent (empty field).
        let no_sp = v1_with("tsp", VALID_NONCE, "satoshi", "danawallet.app", "");
        assert!(sign_challenge(SK_HEX, &no_sp).is_err());
    }

    #[test]
    fn charset_violations_are_rejected() {
        // Non-ASCII anywhere fails closed before any normalization could run
        // (D5/D8): a full-width colon cannot fake a field separator either.
        let fullwidth = format!(
            "{}{}:tsp:{VALID_NONCE}:satoshi:danawallet.app:sp1qabc",
            CHALLENGE_PREFIX, V1_TAG
        )
        .replacen(':', "：", 2);
        assert!(sign_challenge(SK_HEX, &fullwidth).is_err());
        assert!(sign_challenge(
            SK_HEX,
            &v1_with("tsp", VALID_NONCE, "satoshi", "danawallet.app", "sp1qué")
        )
        .is_err());
    }

    #[test]
    fn length_violations_are_rejected() {
        // 64-char username is the inclusive upper bound; 65 is rejected
        // (no length forgiveness, no truncation).
        let ok64 = "a".repeat(64);
        assert!(sign_challenge(
            SK_HEX,
            &v1_with("tsp", VALID_NONCE, &ok64, "danawallet.app", "sp1qabc")
        )
        .is_ok());
        let bad65 = "a".repeat(65);
        assert!(sign_challenge(
            SK_HEX,
            &v1_with("tsp", VALID_NONCE, &bad65, "danawallet.app", "sp1qabc")
        )
        .is_err());
    }

    #[test]
    fn sp_address_absent_is_rejected() {
        // Trailing colon => the sp_address field is present but empty.
        let m = format!(
            "{CHALLENGE_PREFIX}{V1_TAG}:tsp:{VALID_NONCE}:satoshi:danawallet.app:"
        );
        assert!(sign_challenge(SK_HEX, &m).is_err());
        // A dropped field entirely changes the field count and is rejected.
        let m = format!("{CHALLENGE_PREFIX}{V1_TAG}:tsp:{VALID_NONCE}:satoshi:danawallet.app");
        assert!(sign_challenge(SK_HEX, &m).is_err());
    }

    #[test]
    fn output_is_always_canonical_64_bytes() {
        // BIP-340 signatures are fixed-size; anything this fn emits must
        // round-trip through `Signature::from_slice` (which only accepts the
        // canonical 64-byte serialization) and verify. A non-canonical
        // 64-byte output is therefore never produced.
        let s1 = "01".repeat(63);
        let s2 = "6b".repeat(64);
        for secret in [SK_HEX, &s1[..], &s2[..]] {
            if let Ok(sig_hex) = sign_challenge(secret, MSG) {
                let bytes = from_hex(&sig_hex).expect("output is even-length lowercase hex");
                assert_eq!(bytes.len(), 64);
                let sig = Signature::from_slice(&bytes)
                    .expect("output must be a canonical 64-byte schnorr signature");
                let sk = SecretKey::from_str(secret).unwrap();
                let msg = Message::from_digest(challenge_digest(MSG));
                verify(&sig, &msg, &sk).unwrap();
            }
        }
    }

    /// The wallet-held signer (`SpWallet::sign_registration_challenge`,
    /// wallet.rs) is the ONLY signing entry point on the FFI surface
    /// (D4, INV-3 — the standalone hex-secret oracle was removed). It runs
    /// the same `sign_challenge_inner` core with fresh per-call D9 aux, so
    /// its output must still be a valid 64-byte schnorr signature over the
    /// digest path with the wallet's own key. `SpClient::new` is a pure
    /// local key-derivation constructor (no network I/O), so the real call
    /// site is exercised directly.
    #[test]
    fn wallet_held_signer_output_verifies() {
        use crate::api::structs::network::Network;
        use crate::api::wallet::{ApiScanKey, ApiSpendKey, SpWallet};
        use spdk_wallet::client::SpendKey;

        let sk = SecretKey::from_str(SK_HEX).unwrap();
        // Testnet3 wallet <=> "tsp" network_key in MSG (the pinned D7
        // constant for every testnet flavor).
        let wallet = SpWallet::new(
            ApiScanKey(sk),
            ApiSpendKey(SpendKey::Secret(sk)),
            Network::Testnet3,
        )
        .unwrap();

        let sig_hex = wallet.sign_registration_challenge(MSG.into()).unwrap();
        assert_eq!(sig_hex.len(), 128); // 64-byte schnorr sig, lowercase hex
        let bytes = from_hex(&sig_hex).expect("output is even-length lowercase hex");
        let sig = Signature::from_slice(&bytes)
            .expect("output must be a canonical 64-byte schnorr signature");
        verify(&sig, &Message::from_digest(challenge_digest(MSG)), &sk)
            .expect("wallet-held signer output verifies against the digest path");
    }

    #[test]
    fn network_key_mismatch_fails_closed() {
        use crate::api::structs::network::Network;
        use crate::api::wallet::{ApiScanKey, ApiSpendKey, SpWallet};
        use spdk_wallet::client::SpendKey;

        let sk = SecretKey::from_str(SK_HEX).unwrap();
        // D7: the message's network_key must equal the wallet's own pinned
        // client constant. Mismatch => fail closed: Err surfaced, nothing
        // signed.
        let testnet_wallet = SpWallet::new(
            ApiScanKey(sk),
            ApiSpendKey(SpendKey::Secret(sk)),
            Network::Testnet3,
        )
        .unwrap();
        let mainnet_msg = v1_with("sp", VALID_NONCE, "satoshi", "danawallet.app", "sp1qabc");
        let err = testnet_wallet
            .sign_registration_challenge(mainnet_msg)
            .unwrap_err();
        assert!(
            err.to_string().contains("network_key"),
            "error must surface the network_key mismatch: {err}"
        );

        let mainnet_wallet = SpWallet::new(
            ApiScanKey(sk),
            ApiSpendKey(SpendKey::Secret(sk)),
            Network::Mainnet,
        )
        .unwrap();
        let testnet_msg = v1_with("tsp", VALID_NONCE, "satoshi", "danawallet.app", "sp1qabc");
        let err = mainnet_wallet
            .sign_registration_challenge(testnet_msg)
            .unwrap_err();
        assert!(
            err.to_string().contains("network_key"),
            "error must surface the network_key mismatch: {err}"
        );

        // A regtest wallet has no challenge-auth network_key constant at all
        // (the server refuses regtest challenges): fail closed unconditionally.
        let regtest_wallet = SpWallet::new(
            ApiScanKey(sk),
            ApiSpendKey(SpendKey::Secret(sk)),
            Network::Regtest,
        )
        .unwrap();
        let testnet_msg = v1_with("tsp", VALID_NONCE, "satoshi", "danawallet.app", "sp1qabc");
        let err = regtest_wallet
            .sign_registration_challenge(testnet_msg)
            .unwrap_err();
        assert!(err.to_string().contains("regtest"), "error: {err}");
    }

    /// D9 acceptance: the constant (zero-array) aux reproduces the fixed
    /// vectors byte-for-byte — (sk, message, aux) fully determines the
    /// BIP-340 signature, and this exact triple is locked here.
    #[test]
    fn constant_aux_reproduces_fixed_vectors_byte_for_byte() {
        const EXPECTED_SIG_HEX: &str = "df6217f62540ad76c6f42d2a4a0198d4f5f627daa99033b1bf18dda29071d5ffbc94b732d336598645d7e857fd6c94a1ee1dc616d97d766ef3872460a195ade2";
        let first = sign_challenge(SK_HEX, MSG).unwrap();
        let second = sign_challenge(SK_HEX, MSG).unwrap();
        assert_eq!(first, second, "pinned aux must be reproducible");
        assert_eq!(first, EXPECTED_SIG_HEX);
    }

    /// D9 acceptance: the default path uses fresh randomness — two signing
    /// calls over the same message yield different signatures.
    #[test]
    fn default_path_uses_fresh_randomness_per_call() {
        let sk = SecretKey::from_str(SK_HEX).unwrap();
        let s1 = sign_challenge_inner(&sk, MSG, &fresh_aux_rand()).unwrap();
        let s2 = sign_challenge_inner(&sk, MSG, &fresh_aux_rand()).unwrap();
        assert_ne!(
            s1.serialize(),
            s2.serialize(),
            "fresh aux per call must not repeat signatures"
        );
        let digest_msg = Message::from_digest(challenge_digest(MSG));
        verify(&s1, &digest_msg, &sk).unwrap();
        verify(&s2, &digest_msg, &sk).unwrap();
    }

    /// D9 acceptance: the no-RNG fallback path is covered — a failing aux
    /// source yields the constant 32-byte zero array, never a panic.
    #[test]
    fn no_rng_fallback_yields_zero_aux() {
        let aux = aux_rand_from(|_buf| Err(std::io::Error::other("no rng")));
        assert_eq!(aux, ZERO_AUX);
        // A working source is passed through untouched.
        let aux = aux_rand_from(|buf| {
            buf.fill(0xAB);
            Ok(())
        });
        assert_eq!(aux, [0xAB; 32]);
    }

    /// D4/INV-3 acceptance: a watch-only wallet (public-only spend key) has
    /// no spend secret; the signing call must error clearly instead of
    /// succeeding silently.
    #[test]
    fn watch_only_wallet_signing_fails_closed() {
        use crate::api::structs::network::Network;
        use crate::api::wallet::{ApiScanKey, ApiSpendKey, SpWallet};
        use spdk_wallet::client::SpendKey;

        let sk = SecretKey::from_str(SK_HEX).unwrap();
        let pk = sk.public_key(&Secp256k1::signing_only());
        let wallet = SpWallet::new(
            ApiScanKey(sk),
            ApiSpendKey(SpendKey::Public(pk)),
            Network::Testnet3,
        )
        .unwrap();
        let err = wallet
            .sign_registration_challenge(MSG.into())
            .unwrap_err();
        assert!(
            err.to_string().contains("watch-only"),
            "error must name the watch-only condition: {err}"
        );
    }
}
