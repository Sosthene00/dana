//! Dana encrypted file backup container — format v1.
//!
//! Implements `docs/specs/encrypted-file-backup.md` (ratified v1.0, commit
//! 0592280): §3.1–3.4 container format, §4 key derivation.
//!
//! Deliverable is the round trip: `file_bytes = encrypt(payload, password)`
//! and `payload = decrypt(file_bytes, password)`. No wallet wiring, no
//! BIP-139 logic, no Dart lives here — the payload is opaque bytes.
//!
//! Format summary (normative per spec §3):
//! `cleartext authenticated header || ciphertext || AEAD tag`, the entire
//! header supplied as AAD, all integers little-endian, one-shot AEAD.

use std::fmt;

use aes_gcm::aead::generic_array::GenericArray;
use argon2::Argon2;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::XChaCha20Poly1305;

/// Magic bytes, spec §3.2.
pub const MAGIC: [u8; 8] = *b"DANABKP1";
/// Format version written by v1, spec §3.3.
pub const FORMAT_VERSION: u8 = 0x01;
/// Length of the fixed (escrow-free) header, spec §3.3: `header_len = 0x51 + 32 * escrow_entry_count`.
pub const HEADER_BASE_LEN: usize = 0x51;
/// AEAD tag length — Poly1305 (XChaCha) or GHASH (AES-GCM), 16 bytes either way, spec §3.4.
pub const TAG_LEN: usize = 16;
/// cipher_id 0x01: XChaCha20-Poly1305 (RustCrypto), the only v1 writer cipher, spec §3.4.
pub const CIPHER_XCHACHA20_POLY1305: u8 = 0x01;
/// cipher_id 0x02: AES-256-GCM, reader-side only, spec §3.4.
pub const CIPHER_AES_256_GCM: u8 = 0x02;
/// Default Argon2id memory in KiB (64 MiB), RFC 9106 constrained profile, spec §6.3 / §10 (b).
pub const ARGON2_DEFAULT_M_KIB: u32 = 65536;
/// Default Argon2id passes, spec §6.3 / §10 (b).
pub const ARGON2_DEFAULT_T: u32 = 3;
/// Default Argon2id lanes, spec §6.3 / §10 (b).
pub const ARGON2_DEFAULT_P: u32 = 1;
/// HKDF salt = magic || format_version, spec §4.
const HKDF_SALT: &[u8] = b"DANABKP1\x01";
/// HKDF info = versioned purpose string, spec §4.
const HKDF_INFO: &[u8] = b"Dana backup v1 AEAD key";

/// Everything that can go wrong, with the spec's error semantics (§3.2, §3.3, §3.4, §9).
///
/// A wrong password and a tampered header both collapse into
/// [`BackupError::AuthenticationFailed`] — the AEAD verdict is terminal and no
/// partial plaintext is ever exposed (§9 vectors 4–5). Structural parse
/// failures (bad magic, newer version, truncation) have their own variants so
/// callers can distinguish them internally; the UI maps all of them to one
/// generic message per §7.2 (no oracle).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BackupError {
    /// File is shorter than the fixed header requires (§3.1/§3.3).
    TruncatedFile,
    /// First 8 bytes are not `"DANABKP1"` — rejected before any further parsing (§3.2).
    BadMagic,
    /// `format_version != 0x01`; includes v2 files, which a v1 reader MUST reject (§3.3).
    UnsupportedFormatVersion(u8),
    /// `cipher_id` is not 0x01 or 0x02 (§3.4).
    UnsupportedCipherId(u8),
    /// `nonce_len` is inconsistent with the selected cipher: 24 for XChaCha, 12 for AES-GCM (§3.4).
    InvalidNonceLen { cipher_id: u8, nonce_len: u8 },
    /// Non-zero bytes in a reserved/padding region (§3.1: "readers MUST treat
    /// nonzero reserved bytes as a parse error").
    NonZeroReserved,
    /// `escrow_entry_count > 0`: the file was written by a newer version (§3.3).
    NewerVersion,
    /// File ends before the declared header + ciphertext + tag do (§3.1).
    TruncatedPayload,
    /// AEAD authentication failed: wrong password or any header/AAD tampering (§3.1, §9).
    AuthenticationFailed,
    /// Argon2 parameters taken from the header are unusable (§4).
    InvalidKdfParams(String),
    /// OS entropy source failed while generating salt/nonce.
    EntropySource(String),
}

impl fmt::Display for BackupError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TruncatedFile => write!(f, "backup file is truncated"),
            Self::BadMagic => write!(f, "not a Dana backup file (bad magic)"),
            Self::UnsupportedFormatVersion(v) => {
                write!(f, "unsupported backup format version {v}")
            }
            Self::UnsupportedCipherId(id) => write!(f, "unsupported cipher id {id}"),
            Self::InvalidNonceLen { cipher_id, nonce_len } => write!(
                f,
                "nonce length {nonce_len} invalid for cipher id {cipher_id}"
            ),
            Self::NonZeroReserved => write!(f, "non-zero reserved header bytes"),
            Self::NewerVersion => write!(
                f, "file written by a newer version (escrow entries present)"
            ),
            Self::TruncatedPayload => write!(f, "backup payload is truncated"),
            Self::AuthenticationFailed => write!(f, "decryption failed (wrong password or corrupted file)"),
            Self::InvalidKdfParams(e) => write!(f, "invalid KDF parameters in header: {e}"),
            Self::EntropySource(e) => write!(f, "entropy source failure: {e}"),
        }
    }
}

impl std::error::Error for BackupError {}

/// Parsed v1 header. `raw` is the full `header_len` byte region — the exact
/// bytes that must be supplied as AAD (§3.1).
#[derive(Debug, Clone, PartialEq, Eq)]
struct Header {
    format_version: u8,
    cipher_id: u8,
    argon2_m_kib: u32,
    argon2_t: u32,
    argon2_p: u32,
    salt: [u8; 16],
    nonce_len: u8,
    nonce: [u8; 24],
    payload_len: u64,
    raw: Vec<u8>,
}

impl Header {
    /// Write a fresh v1 header, spec §3.3. All integers little-endian, all
    /// reserved/padding regions zero.
    #[allow(clippy::too_many_arguments)]
    fn write(
        cipher_id: u8,
        argon2_m_kib: u32,
        argon2_t: u32,
        argon2_p: u32,
        salt: &[u8; 16],
        nonce: &[u8; 24],
        nonce_len: usize,
        payload_len: u64,
    ) -> Vec<u8> {
        let mut h = vec![0u8; HEADER_BASE_LEN];
        h[0x00..0x08].copy_from_slice(&MAGIC);
        h[0x08] = FORMAT_VERSION;
        h[0x09] = cipher_id;
        h[0x0A..0x0C].copy_from_slice(&(HEADER_BASE_LEN as u16).to_le_bytes());
        // 0x0C..0x10 reserved: already zero.
        h[0x10..0x14].copy_from_slice(&argon2_m_kib.to_le_bytes());
        h[0x14..0x18].copy_from_slice(&argon2_t.to_le_bytes());
        h[0x18..0x1C].copy_from_slice(&argon2_p.to_le_bytes());
        h[0x1C..0x2C].copy_from_slice(salt);
        h[0x2C] = nonce_len as u8;
        h[0x2D..0x2D + nonce_len].copy_from_slice(&nonce[..nonce_len]);
        // Remainder of the 24-byte aead_nonce field is zero-padded (§3.3).
        h[0x2D + nonce_len..0x45].fill(0);
        h[0x45..0x49].copy_from_slice(&0u32.to_le_bytes()); // escrow_entry_count = 0
        h[0x49..0x51].copy_from_slice(&payload_len.to_le_bytes());
        h
    }

    /// Parse and validate a v1 header, spec §3.2/§3.3/§3.4.
    ///
    /// Order of checks: magic before anything else (§3.2 "readers MUST reject
    /// anything else before parsing further"), then version, structural
    /// bounds, reserved regions, cipher/nonce consistency, escrow count
    /// ("file written by a newer version", §3.3), and finally full-length
    /// consistency.
    fn parse(file: &[u8]) -> Result<Self, BackupError> {
        if file.len() < MAGIC.len() {
            return Err(BackupError::TruncatedFile);
        }
        if file[..MAGIC.len()] != MAGIC {
            return Err(BackupError::BadMagic);
        }
        if file.len() < HEADER_BASE_LEN {
            return Err(BackupError::TruncatedFile);
        }

        let format_version = file[0x08];
        if format_version != FORMAT_VERSION {
            return Err(BackupError::UnsupportedFormatVersion(format_version));
        }

        let header_len = u16::from_le_bytes([file[0x0A], file[0x0B]]) as usize;
        if header_len < HEADER_BASE_LEN || file.len() < header_len {
            return Err(BackupError::TruncatedFile);
        }
        let raw = file[..header_len].to_vec();

        if file[0x0C..0x10].iter().any(|&b| b != 0) {
            return Err(BackupError::NonZeroReserved);
        }

        let cipher_id = file[0x09];
        let expected_nonce_len = match cipher_id {
            CIPHER_XCHACHA20_POLY1305 => 24,
            CIPHER_AES_256_GCM => 12,
            other => return Err(BackupError::UnsupportedCipherId(other)),
        };
        let nonce_len = file[0x2C];
        if nonce_len != expected_nonce_len {
            return Err(BackupError::InvalidNonceLen { cipher_id, nonce_len });
        }
        // Nonce remainder must be zero-padded (§3.3).
        if file[0x2D + nonce_len as usize..0x45].iter().any(|&b| b != 0) {
            return Err(BackupError::NonZeroReserved);
        }

        let escrow_entry_count = u32::from_le_bytes([
            file[0x45], file[0x46], file[0x47], file[0x48],
        ]);
        if escrow_entry_count > 0 {
            return Err(BackupError::NewerVersion);
        }
        // header_len must match the escrow count exactly (§3.3).
        if header_len != HEADER_BASE_LEN + 32 * escrow_entry_count as usize {
            return Err(BackupError::TruncatedFile);
        }

        let payload_len = u64::from_le_bytes([
            file[0x49], file[0x4A], file[0x4B], file[0x4C],
            file[0x4D], file[0x4E], file[0x4F], file[0x50],
        ]);
        let body_len = header_len
            .checked_add(payload_len as usize)
            .and_then(|n| n.checked_add(TAG_LEN))
            .ok_or(BackupError::TruncatedPayload)?;
        if file.len() != body_len {
            return Err(BackupError::TruncatedPayload);
        }

        let mut salt = [0u8; 16];
        salt.copy_from_slice(&file[0x1C..0x2C]);
        let mut nonce = [0u8; 24];
        nonce.copy_from_slice(&file[0x2D..0x45]);

        Ok(Self {
            format_version,
            cipher_id,
            argon2_m_kib: u32::from_le_bytes(file[0x10..0x14].try_into().unwrap()),
            argon2_t: u32::from_le_bytes(file[0x14..0x18].try_into().unwrap()),
            argon2_p: u32::from_le_bytes(file[0x18..0x1C].try_into().unwrap()),
            salt,
            nonce_len,
            nonce,
            payload_len,
            raw,
        })
    }
}

/// Key derivation, spec §4: Argon2id (params from the header, never
/// hardcoded) over the UTF-8 password with no trimming, then HKDF-SHA256 with
/// the versioned salt and purpose string.
///
/// Public so the §9 test vectors can state the derived AEAD key ("so
/// implementers can debug KDF drift independently of AEAD issues") and so the
/// checked-in vectors can be verified key-by-key, not only end to end.
pub fn derive_aead_key(
    password: &[u8],
    salt: &[u8],
    argon2_m_kib: u32,
    argon2_t: u32,
    argon2_p: u32,
) -> Result<[u8; 32], BackupError> {
    let params = argon2::Params::new(argon2_m_kib, argon2_t, argon2_p, Some(32))
        .map_err(|e| BackupError::InvalidKdfParams(e.to_string()))?;
    let argon = Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params);
    let mut ikm = [0u8; 32];
    argon
        .hash_password_into(password, salt, &mut ikm)
        .map_err(|e| BackupError::InvalidKdfParams(e.to_string()))?;
    let hkdf = hkdf::Hkdf::<sha2::Sha256>::new(Some(HKDF_SALT), &ikm);
    let mut key = [0u8; 32];
    // L=32 == SHA-256 output size, cannot fail per HKDF bounds.
    hkdf.expand(HKDF_INFO, &mut key).expect("32-byte HKDF expand");
    Ok(key)
}

/// One-shot AEAD seal/open over the header-as-AAD, spec §3.1/§3.4.
///
/// The entire header is passed as AAD via `Payload { msg, aad }` — passing
/// the plaintext bare would coerce to an empty-AAD payload and leave the
/// header unauthenticated, violating §3.1 ("Any header modification … fails
/// authentication").
fn aead_seal(
    cipher_id: u8,
    key: &[u8; 32],
    nonce: &[u8],
    plaintext: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, BackupError> {
    let payload = Payload { msg: plaintext, aad };
    match cipher_id {
        CIPHER_XCHACHA20_POLY1305 => {
            let cipher = XChaCha20Poly1305::new(key.into());
            cipher
                .encrypt(GenericArray::from_slice(nonce), payload)
                .map_err(|_| BackupError::AuthenticationFailed)
        }
        CIPHER_AES_256_GCM => {
            let cipher = aes_gcm::Aes256Gcm::new(key.into());
            cipher
                .encrypt(GenericArray::from_slice(&nonce[..12]), payload)
                .map_err(|_| BackupError::AuthenticationFailed)
        }
        other => Err(BackupError::UnsupportedCipherId(other)),
    }
}

fn aead_open(
    cipher_id: u8,
    key: &[u8; 32],
    nonce: &[u8],
    ciphertext_with_tag: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, BackupError> {
    let payload = Payload { msg: ciphertext_with_tag, aad };
    let result = match cipher_id {
        CIPHER_XCHACHA20_POLY1305 => {
            let cipher = XChaCha20Poly1305::new(key.into());
            cipher.decrypt(GenericArray::from_slice(nonce), payload)
        }
        CIPHER_AES_256_GCM => {
            let cipher = aes_gcm::Aes256Gcm::new(key.into());
            cipher.decrypt(GenericArray::from_slice(&nonce[..12]), payload)
        }
        other => return Err(BackupError::UnsupportedCipherId(other)),
    };
    // Terminal failure, no partial output ever exposed (§3.4, §9).
    result.map_err(|_| BackupError::AuthenticationFailed)
}

/// Encrypt a payload into a complete v1 backup file (spec §3.1–3.4, §4, §7.1).
///
/// Writes the v1 writer profile: XChaCha20-Poly1305 (`cipher_id = 0x01`),
/// Argon2id m=64 MiB / t=3 / p=1, fresh 16-byte salt, fresh 24-byte nonce,
/// `escrow_entry_count = 0` (§3.3), entire header as AAD.
pub fn encrypt(payload: &[u8], password: &str) -> Result<Vec<u8>, BackupError> {
    encrypt_with(
        CIPHER_XCHACHA20_POLY1305,
        ARGON2_DEFAULT_M_KIB,
        ARGON2_DEFAULT_T,
        ARGON2_DEFAULT_P,
        payload,
        password,
    )
}

/// Full-parameter variant. Public for the device-class KDF fallback (§6.3.2)
/// and used by tests to prove decrypt honors header-written params.
pub fn encrypt_with(
    cipher_id: u8,
    argon2_m_kib: u32,
    argon2_t: u32,
    argon2_p: u32,
    payload: &[u8],
    password: &str,
) -> Result<Vec<u8>, BackupError> {
    let mut salt = [0u8; 16];
    getrandom::fill(&mut salt).map_err(|e| BackupError::EntropySource(e.to_string()))?;
    // 24-byte field; AES-GCM readers consume only the first 12 (§3.4).
    let mut nonce = [0u8; 24];
    getrandom::fill(&mut nonce).map_err(|e| BackupError::EntropySource(e.to_string()))?;
    let nonce_len = match cipher_id {
        CIPHER_XCHACHA20_POLY1305 => 24usize,
        CIPHER_AES_256_GCM => 12usize,
        other => return Err(BackupError::UnsupportedCipherId(other)),
    };

    let header = Header::write(
        cipher_id,
        argon2_m_kib,
        argon2_t,
        argon2_p,
        &salt,
        &nonce,
        nonce_len,
        payload.len() as u64,
    );

    let key = derive_aead_key(
        password.as_bytes(),
        &salt,
        argon2_m_kib,
        argon2_t,
        argon2_p,
    )?;
    let ciphertext_with_tag = aead_seal(cipher_id, &key, &nonce, payload, &header)?;

    let mut file = header;
    file.extend_from_slice(&ciphertext_with_tag);
    Ok(file)
}

/// Deterministic encrypt: identical to [`encrypt_with`], but the salt and
/// nonce are supplied by the caller instead of drawn from the OS entropy
/// source.
///
/// Exists for spec §9 test-vector generation: vectors MUST be byte-reproducible
/// from the reference implementation, which requires pinning the otherwise
/// random salt/nonce. Not for production use — production callers MUST use
/// [`encrypt`] / [`encrypt_with`], which generate fresh randomness per file.
#[allow(clippy::too_many_arguments)]
pub fn encrypt_deterministic(
    cipher_id: u8,
    argon2_m_kib: u32,
    argon2_t: u32,
    argon2_p: u32,
    salt: &[u8; 16],
    nonce: &[u8; 24],
    payload: &[u8],
    password: &str,
) -> Result<Vec<u8>, BackupError> {
    let nonce_len = match cipher_id {
        CIPHER_XCHACHA20_POLY1305 => 24usize,
        CIPHER_AES_256_GCM => 12usize,
        other => return Err(BackupError::UnsupportedCipherId(other)),
    };
    let header = Header::write(
        cipher_id,
        argon2_m_kib,
        argon2_t,
        argon2_p,
        salt,
        nonce,
        nonce_len,
        payload.len() as u64,
    );
    let key = derive_aead_key(
        password.as_bytes(),
        salt,
        argon2_m_kib,
        argon2_t,
        argon2_p,
    )?;
    let ciphertext_with_tag = aead_seal(cipher_id, &key, nonce, payload, &header)?;
    let mut file = header;
    file.extend_from_slice(&ciphertext_with_tag);
    Ok(file)
}

/// Decrypt a v1 backup file back to the payload (spec §3, §4, §7.2).
///
/// All KDF parameters are read from the header — never hardcoded. Any
/// failure (wrong password, tampered header/AAD, truncation) is terminal
/// with no partial output (§9).
pub fn decrypt(file: &[u8], password: &str) -> Result<Vec<u8>, BackupError> {
    let header = Header::parse(file)?;
    let key = derive_aead_key(
        password.as_bytes(),
        &header.salt,
        header.argon2_m_kib,
        header.argon2_t,
        header.argon2_p,
    )?;
    let header_len = header.raw.len();
    let ciphertext_with_tag = &file[header_len..];
    if ciphertext_with_tag.len() as u64 != header.payload_len + TAG_LEN as u64 {
        return Err(BackupError::TruncatedPayload);
    }
    // AES-GCM consumes the first nonce_len bytes of the shared field (§3.4);
    // XChaCha consumes all 24.
    let nonce_len = header.nonce_len as usize;
    aead_open(header.cipher_id, &key, &header.nonce[..nonce_len], ciphertext_with_tag, &header.raw)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Flip one bit of the header byte at `offset` in a valid file.
    fn flip_header_bit(file: &mut [u8], offset: usize) {
        file[offset] ^= 0x01;
    }

    #[test]
    fn round_trip_xchacha() {
        let payload = b"hello dana backup payload \xF0\x9F\x94\x92".to_vec();
        let file = encrypt(&payload, "correct horse battery staple 42").unwrap();
        let recovered = decrypt(&file, "correct horse battery staple 42").unwrap();
        assert_eq!(recovered, payload);
    }

    #[test]
    fn round_trip_aes_gcm_reader_cipher() {
        let payload = vec![7u8; 1000];
        let file = encrypt_with(CIPHER_AES_256_GCM, ARGON2_DEFAULT_M_KIB, ARGON2_DEFAULT_T, ARGON2_DEFAULT_P, &payload, "another fine password 1").unwrap();
        let recovered = decrypt(&file, "another fine password 1").unwrap();
        assert_eq!(recovered, payload);
    }

    #[test]
    fn round_trip_empty_payload() {
        let file = encrypt(b"", "an empty payload test 7").unwrap();
        assert_eq!(decrypt(&file, "an empty payload test 7").unwrap(), b"");
    }

    #[test]
    fn wrong_password_fails_without_partial_output() {
        let payload = b"secret payload".to_vec();
        let file = encrypt(&payload, "a valid long password 1").unwrap();
        // Policy-valid but wrong password (§6.1 rules respected).
        let err = decrypt(&file, "a valid long password 2").unwrap_err();
        assert_eq!(err, BackupError::AuthenticationFailed);
    }

    #[test]
    fn tampered_argon2_t_fails_aead() {
        let payload = b"payload".to_vec();
        let mut file = encrypt(&payload, "tamper the t param 3").unwrap();
        flip_header_bit(&mut file, 0x14); // argon2_t
        assert_eq!(decrypt(&file, "tamper the t param 3").unwrap_err(), BackupError::AuthenticationFailed);
    }

    #[test]
    fn tampered_magic_rejects_before_parsing() {
        let payload = b"payload".to_vec();
        let mut file = encrypt(&payload, "tamper the magic 5").unwrap();
        flip_header_bit(&mut file, 0x00); // magic
        assert_eq!(decrypt(&file, "tamper the magic 5").unwrap_err(), BackupError::BadMagic);
    }

    #[test]
    fn truncated_file_rejects() {
        let file = encrypt(b"some payload", "truncate me not 11").unwrap();
        assert_eq!(decrypt(&file[..file.len() - 1], "truncate me not 11").unwrap_err(), BackupError::TruncatedPayload);
        assert_eq!(decrypt(&file[..20], "truncate me not 11").unwrap_err(), BackupError::TruncatedFile);
        assert_eq!(decrypt(&[], "truncate me not 11").unwrap_err(), BackupError::TruncatedFile);
    }

    #[test]
    fn truncated_tag_rejects() {
        let file = encrypt(b"some payload", "tag truncation 13").unwrap();
        // Drop exactly one tag byte from the end.
        assert_eq!(decrypt(&file[..file.len() - 1], "tag truncation 13").unwrap_err(), BackupError::TruncatedPayload);
    }

    #[test]
    fn escrow_entries_rejected_as_newer_version() {
        let mut file = encrypt(b"payload", "escrow future 17").unwrap();
        // Mark escrow_entry_count = 1 even though header_len stays 0x51.
        file[0x45] = 1;
        assert_eq!(decrypt(&file, "escrow future 17").unwrap_err(), BackupError::NewerVersion);
        // Same verdict even if the file is additionally truncated: the
        // newer-version gate fires before length accounting (§3.3).
        let mut truncated = file.clone();
        truncated.truncate(truncated.len() - 5);
        assert_eq!(decrypt(&truncated, "escrow future 17").unwrap_err(), BackupError::NewerVersion);
    }

    #[test]
    fn bad_magic_rejects() {
        let mut file = encrypt(b"payload", "bad magic 19").unwrap();
        file[0] = b'X';
        assert_eq!(decrypt(&file, "bad magic 19").unwrap_err(), BackupError::BadMagic);
    }

    #[test]
    fn header_layout_byte_for_byte() {
        let payload = b"layout check".to_vec();
        let file = encrypt(&payload, "layout inspection 23").unwrap();
        assert_eq!(&file[0x00..0x08], b"DANABKP1");
        assert_eq!(file[0x08], 0x01); // format_version
        assert_eq!(file[0x09], CIPHER_XCHACHA20_POLY1305);
        assert_eq!(&file[0x0A..0x0C], &[0x51, 0x00]); // header_len LE
        assert_eq!(&file[0x0C..0x10], &[0, 0, 0, 0]); // reserved
        assert_eq!(&file[0x10..0x14], &65536u32.to_le_bytes()); // argon2_m_kib
        assert_eq!(&file[0x14..0x18], &3u32.to_le_bytes()); // argon2_t
        assert_eq!(&file[0x18..0x1C], &1u32.to_le_bytes()); // argon2_p
        assert_eq!(file[0x2C], 24); // nonce_len
        assert_eq!(&file[0x45..0x49], &0u32.to_le_bytes()); // escrow_entry_count
        let payload_len = u64::from_le_bytes(file[0x49..0x51].try_into().unwrap());
        assert_eq!(payload_len, payload.len() as u64);
        // payload_len counts ciphertext only; the 16-byte tag follows (§3.3).
        assert_eq!(file.len() as u64, HEADER_BASE_LEN as u64 + payload_len + TAG_LEN as u64);
    }

    #[test]
    fn nonzero_reserved_is_parse_error() {
        let mut file = encrypt(b"payload", "reserved bits 29").unwrap();
        file[0x0C] = 1;
        assert_eq!(decrypt(&file, "reserved bits 29").unwrap_err(), BackupError::NonZeroReserved);
    }

    #[test]
    fn unsupported_version_and_cipher_reject() {
        let mut file = encrypt(b"payload", "version drift 31").unwrap();
        file[0x08] = 0x02; // v2 file
        assert_eq!(decrypt(&file, "version drift 31").unwrap_err(), BackupError::UnsupportedFormatVersion(0x02));

        let mut file = encrypt(b"payload", "cipher drift 37").unwrap();
        file[0x09] = 0x03;
        assert_eq!(decrypt(&file, "cipher drift 37").unwrap_err(), BackupError::UnsupportedCipherId(0x03));
    }

    #[test]
    fn kdf_params_are_read_from_header_not_hardcoded() {
        // Encrypt with non-default params (§6.3.2 device-class fallback shape:
        // m=32 MiB, t=4) and prove decrypt uses the header values.
        let payload = b"header-driven params".to_vec();
        let file = encrypt_with(CIPHER_XCHACHA20_POLY1305, 32768, 4, 1, &payload, "device fallback 41").unwrap();
        let header = Header::parse(&file).unwrap();
        assert_eq!(header.format_version, FORMAT_VERSION);
        assert_eq!(header.argon2_m_kib, 32768);
        assert_eq!(header.argon2_t, 4);
        assert_eq!(header.argon2_p, 1);
        assert_eq!(decrypt(&file, "device fallback 41").unwrap(), payload);
    }

    #[test]
    fn reduced_params_header_is_honored() {
        // Minimal legal Argon2 memory (m=8) must decrypt too — proving nothing
        // on the read path assumes the defaults of §6.3.
        let payload = b"tiny params".to_vec();
        let file = encrypt_with(CIPHER_XCHACHA20_POLY1305, 8, 1, 1, &payload, "tiny params 43").unwrap();
        assert_eq!(decrypt(&file, "tiny params 43").unwrap(), payload);
    }

    #[test]
    fn impossible_kdf_params_reject_cleanly() {
        let mut file = encrypt(b"payload", "bad params 47").unwrap();
        // argon2_m_kib = 0 is not a legal Argon2 parameter set.
        file[0x10..0x14].copy_from_slice(&0u32.to_le_bytes());
        assert!(matches!(
            decrypt(&file, "bad params 47"),
            Err(BackupError::InvalidKdfParams(_))
        ));
    }

    #[test]
    fn fresh_salt_and_nonce_per_file() {
        let a = encrypt(b"same payload", "same password 53").unwrap();
        let b = encrypt(b"same payload", "same password 53").unwrap();
        assert_ne!(&a[0x1C..0x2C], &b[0x1C..0x2C], "salt must be fresh per file");
        assert_ne!(&a[0x2D..0x45], &b[0x2D..0x45], "nonce must be fresh per file");
        assert_ne!(a, b);
    }

    #[test]
    fn nonce_tail_is_zero_padded_for_aes_files() {
        let file = encrypt_with(CIPHER_AES_256_GCM, 8, 1, 1, b"payload", "aes padding 59").unwrap();
        assert_eq!(file[0x2C], 12); // nonce_len
        assert_eq!(&file[0x2D + 12..0x45], &[0u8; 12]); // remainder zero
    }
}
