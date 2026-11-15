//! Backup export at the wallet level — spec §5 payload assembly + §7.1
//! step 3 encryption.
//!
//! End to end at the Rust API level: wallet handle -> BIP-139 export section
//! (§5.1, watch-only `sp()` descriptor built from the wallet keys) -> Dana
//! secrets block (§5.2, full encoded `sp()` spend descriptor) -> section
//! framing (§5, `crate::backup_payload`) -> BK-01 container encrypt
//! (`crate::backup`). After this, `create_backup_file(wallet, password)`
//! yields file bytes that decrypt back into a spec-valid BIP-139 export plus
//! the spend descriptor.

use crate::backup;
use crate::backup_payload::{self, PayloadError};

use super::SpWallet;

impl SpWallet {
    /// Produces the encrypted backup file bytes for this wallet.
    ///
    /// The BIP-139 section carries the private scan key (allowed on mainnet)
    /// in the watch-only `sp()` descriptor form and MUST NOT carry spend
    /// keys or mnemonics (D2, §5.1); the spend secret travels only in the
    /// secrets block (§5.2), which never exists outside the encrypted
    /// payload. The password is validated per §6.1 before any bytes are
    /// written.
    pub fn create_backup_file(&self, password: &str) -> Result<Vec<u8>, PayloadError> {
        backup_payload::validate_password(password)?;

        let spend_descriptor = self
            .get_encoded_descriptor()
            .ok_or(PayloadError::WatchOnlyWallet)?;
        let scan_descriptor = self.get_encoded_descriptor_watch_only();
        let bip139_export =
            backup_payload::build_bip139_export(self.get_network(), &scan_descriptor, None);
        let secrets_block = backup_payload::build_secrets_block(&spend_descriptor);
        // v1 has no companion content to store yet (§5.3: implementations
        // with nothing to store simply omit the section).
        let payload = backup_payload::build_payload(&bip139_export, &secrets_block, None)?;

        backup::encrypt(&payload, password).map_err(PayloadError::Container)
    }

    /// Device-class fallback variant (§6.3.2, encrypt-side only): identical
    /// to [`SpWallet::create_backup_file`] but with explicit Argon2id
    /// parameters, recorded in the header (§3.3) and honored as written by
    /// every reader (§4). The caller decides the device-class question; the
    /// password policy (§6.1) applies unchanged.
    pub fn create_backup_file_with_kdf(
        &self,
        password: &str,
        argon2_m_kib: u32,
        argon2_t: u32,
        argon2_p: u32,
    ) -> Result<Vec<u8>, PayloadError> {
        backup_payload::validate_password(password)?;

        let spend_descriptor = self
            .get_encoded_descriptor()
            .ok_or(PayloadError::WatchOnlyWallet)?;
        let scan_descriptor = self.get_encoded_descriptor_watch_only();
        let bip139_export =
            backup_payload::build_bip139_export(self.get_network(), &scan_descriptor, None);
        let secrets_block = backup_payload::build_secrets_block(&spend_descriptor);
        let payload = backup_payload::build_payload(&bip139_export, &secrets_block, None)?;

        backup::encrypt_with(
            backup::CIPHER_XCHACHA20_POLY1305,
            argon2_m_kib,
            argon2_t,
            argon2_p,
            &payload,
            password,
        )
        .map_err(PayloadError::Container)
    }
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use spdk_wallet::bitcoin::key::Secp256k1;

    use bip392::Sp;
    use serde_json::Value;

    use crate::api::structs::network::Network;
    use crate::api::wallet::{ApiScanKey, ApiSpendKey, SpWallet};
    use crate::backup;
    use crate::backup_payload;
    use crate::backup_payload::{
        PayloadError, SECTION_TYPE_BIP139, SECTION_TYPE_SECRETS, parse_sections,
    };
    use spdk_wallet::bitcoin::secp256k1::SecretKey;
    use spdk_wallet::client::SpendKey;

    const PASSWORD: &str = "backup passphrase 12";

    fn keypair() -> (SecretKey, SecretKey) {
        (
            SecretKey::from_slice(&[0x11; 32]).unwrap(),
            SecretKey::from_slice(&[0x22; 32]).unwrap(),
        )
    }

    fn wallet(network: Network) -> (SpWallet, SecretKey, SecretKey) {
        let (scan, spend) = keypair();
        let wallet = SpWallet::new(
            ApiScanKey(scan),
            ApiSpendKey(SpendKey::Secret(spend)),
            network,
        )
        .unwrap();
        (wallet, scan, spend)
    }

    fn decrypt_sections(file: &[u8]) -> Vec<(u32, Vec<u8>)> {
        let payload = backup::decrypt(file, PASSWORD).unwrap();
        parse_sections(&payload).unwrap()
    }

    #[test]
    fn wallet_backup_file_round_trips_to_valid_bip139_export() {
        let (wallet, scan, _spend) = wallet(Network::Mainnet);
        let file = wallet.create_backup_file(PASSWORD).unwrap();

        let sections = decrypt_sections(&file);
        assert_eq!(
            sections.iter().map(|(t, _)| *t).collect::<Vec<_>>(),
            vec![SECTION_TYPE_BIP139, SECTION_TYPE_SECRETS]
        );

        // Acceptance 1: the BIP-139 section validates as a standalone
        // BIP-139 export.
        let bip139_body = String::from_utf8(sections[0].1.clone()).unwrap();
        backup_payload::validate_bip139_export(&bip139_body).unwrap();

        let export: Value = serde_json::from_str(&bip139_body).unwrap();
        assert_eq!(export["network"], "bitcoin");
        let section_descriptor = export["accounts"][0]["descriptor"].as_str().unwrap();
        let section_sp = Sp::from_str(section_descriptor).unwrap();
        // D2 / §5.1: no spend keys in the BIP-139 section; the private scan
        // key MAY be present and must be this wallet's.
        assert!(!section_sp.has_spend_key());
        assert!(section_sp.is_mainnet());
        assert_eq!(section_sp.scan_key().display_secret().to_string(), scan.display_secret().to_string());
    }

    #[test]
    fn secrets_block_descriptor_is_identical_before_and_after() {
        let (wallet, _scan, spend) = wallet(Network::Mainnet);
        let file = wallet.create_backup_file(PASSWORD).unwrap();

        let sections = decrypt_sections(&file);
        let secrets_body = String::from_utf8(sections[1].1.clone()).unwrap();
        let secrets: Value = serde_json::from_str(&secrets_body).unwrap();

        // Acceptance 2: the descriptor string is identical before/after.
        let expected = wallet.get_encoded_descriptor().unwrap();
        assert_eq!(secrets["descriptor"], expected);
        // And it really is the full `SpKey::Spend` descriptor: it parses and
        // carries exactly this wallet's spend secret.
        let sp = Sp::from_str(secrets["descriptor"].as_str().unwrap()).unwrap();
        assert!(sp.has_spend_key());
        assert_eq!(
            sp.spend_secret().unwrap().display_secret().to_string(),
            spend.display_secret().to_string()
        );
    }

    #[test]
    fn mainnet_bip139_section_leaks_no_spend_material() {
        let (wallet, _scan, spend) = wallet(Network::Mainnet);
        let file = wallet.create_backup_file(PASSWORD).unwrap();

        let sections = decrypt_sections(&file);
        let bip139_body = String::from_utf8(sections[0].1.clone()).unwrap();
        let secrets_body = String::from_utf8(sections[1].1.clone()).unwrap();

        // Acceptance 3: no spend key material in the BIP-139 section body —
        // neither the full secrets descriptor nor the raw spend secret hex
        // nor a mnemonic field.
        assert!(!bip139_body.contains(&secrets_body));
        assert!(!bip139_body.contains(&spend.display_secret().to_string()));
        let export: Value = serde_json::from_str(&bip139_body).unwrap();
        assert!(export.get("bip39_mnemonic").is_none());
        assert!(export["accounts"][0].get("bip39_mnemonic").is_none());
        // The secrets block, by contrast, sits in its own section and holds
        // the spend descriptor.
        assert!(secrets_body.contains("descriptor"));
    }

    #[test]
    fn framing_matches_section_5_byte_for_byte() {
        let (wallet, _scan, _spend) = wallet(Network::Mainnet);
        let file = wallet.create_backup_file(PASSWORD).unwrap();

        let payload = backup::decrypt(&file, PASSWORD).unwrap();
        // Acceptance 4: section order, lengths, types per §5.
        let bip139_len = u32::from_le_bytes(payload[4..8].try_into().unwrap()) as usize;
        assert_eq!(&payload[0..4], &1u32.to_le_bytes());
        let secrets_offset = 8 + bip139_len;
        assert_eq!(&payload[secrets_offset..secrets_offset + 4], &2u32.to_le_bytes());
        let secrets_len =
            u32::from_le_bytes(payload[secrets_offset + 4..secrets_offset + 8].try_into().unwrap())
                as usize;
        // Sections are contiguous and exactly tile the payload (no
        // companion section was stored, §5.3).
        assert_eq!(payload.len(), secrets_offset + 8 + secrets_len);

        let sections = parse_sections(&payload).unwrap();
        assert_eq!(sections[0].1.len(), bip139_len);
        assert_eq!(sections[1].1.len(), secrets_len);
        assert_eq!(String::from_utf8(sections[0].1.clone()).unwrap(), String::from_utf8(payload[8..8 + bip139_len].to_vec()).unwrap());
    }

    #[test]
    fn wrong_password_yields_terminal_aead_failure() {
        let (wallet, _scan, _spend) = wallet(Network::Mainnet);
        let file = wallet.create_backup_file(PASSWORD).unwrap();
        assert_eq!(
            backup::decrypt(&file, "wrong passphrase 3").unwrap_err(),
            backup::BackupError::AuthenticationFailed
        );
    }

    #[test]
    fn watch_only_wallet_cannot_be_backed_up() {
        let (scan, _spend) = keypair();
        let spend_pk = scan.public_key(&Secp256k1::signing_only());
        let wallet = SpWallet::new(
            ApiScanKey(scan),
            ApiSpendKey(SpendKey::Public(spend_pk)),
            Network::Mainnet,
        )
        .unwrap();
        assert_eq!(
            wallet.create_backup_file(PASSWORD).unwrap_err(),
            PayloadError::WatchOnlyWallet
        );
    }

    #[test]
    fn password_policy_applies_at_export_time() {
        let (wallet, _scan, _spend) = wallet(Network::Mainnet);
        assert_eq!(
            wallet.create_backup_file("short1").unwrap_err(),
            PayloadError::PasswordTooShort
        );
        assert_eq!(
            wallet.create_backup_file("no digits in this one").unwrap_err(),
            PayloadError::PasswordNoDigit
        );
        assert_eq!(
            wallet.create_backup_file("0123456789123456").unwrap_err(),
            PayloadError::PasswordNoLowercase
        );
    }

    #[test]
    fn testnet_export_names_the_testnet_network() {
        let (wallet, _scan, _spend) = wallet(Network::Testnet3);
        let file = wallet.create_backup_file(PASSWORD).unwrap();
        let sections = decrypt_sections(&file);
        let export: Value =
            serde_json::from_str(&String::from_utf8(sections[0].1.clone()).unwrap()).unwrap();
        assert_eq!(export["network"], "testnet3");
    }

    /// §6.3.2: the reduced fallback (m=32 MiB, t=4, p=1) is written to the
    /// header (§3.3, offsets 0x10..0x1C little-endian) and the resulting file
    /// still decrypts with the header params honored as written (§4).
    #[test]
    fn reduced_kdf_fallback_is_recorded_in_header_and_still_round_trips() {
        const REDUCED_M_KIB: u32 = 32768; // 32 MiB
        const REDUCED_T: u32 = 4;
        const REDUCED_P: u32 = 1;

        let (wallet, _scan, _spend) = wallet(Network::Mainnet);
        let file = wallet
            .create_backup_file_with_kdf(PASSWORD, REDUCED_M_KIB, REDUCED_T, REDUCED_P)
            .unwrap();

        // Header fields per §3.3: m at 0x10..0x14, t at 0x14..0x18, p at
        // 0x18..0x1C, little-endian.
        assert_eq!(&file[0x10..0x14], &REDUCED_M_KIB.to_le_bytes());
        assert_eq!(&file[0x14..0x18], &REDUCED_T.to_le_bytes());
        assert_eq!(&file[0x18..0x1C], &REDUCED_P.to_le_bytes());

        // Reader side: no device-class logic — header params used as written.
        let payload = backup::decrypt(&file, PASSWORD).unwrap();
        let sections = parse_sections(&payload).unwrap();
        assert_eq!(
            sections.iter().map(|(t, _)| *t).collect::<Vec<_>>(),
            vec![SECTION_TYPE_BIP139, SECTION_TYPE_SECRETS]
        );
    }

    /// §6.1 boundary acceptance: exactly 16 scalar values with a lowercase
    /// and a digit is the accepted minimum; 15 values, no-digit and
    /// no-lowercase are all rejected. (Mirrors the payload-level test at the
    /// wallet API level, where the export UI's checks must agree.)
    #[test]
    fn password_policy_boundaries_at_the_wallet_api() {
        let (wallet, _scan, _spend) = wallet(Network::Mainnet);

        // Exactly 16 scalar values: accepted.
        wallet
            .create_backup_file("abcdef0123456789")
            .unwrap_or_else(|e| panic!("16-char lowercase+digit must pass: {e:?}"));
        // 15 scalar values: rejected.
        assert_eq!(
            wallet.create_backup_file("abcdef012345678").unwrap_err(),
            PayloadError::PasswordTooShort
        );
        // 16 scalar values, no digit.
        assert_eq!(
            wallet
                .create_backup_file("abcdefghijklmnop")
                .unwrap_err(),
            PayloadError::PasswordNoDigit
        );
        // 16 scalar values, no lowercase.
        assert_eq!(
            wallet
                .create_backup_file("0123456789ABCDEF")
                .unwrap_err(),
            PayloadError::PasswordNoLowercase
        );
    }
}

// ---------------------------------------------------------------------------
// Dart-facing restore API (§7.2) — wires the BK-03 restore core to the app's
// restore flow.
// ---------------------------------------------------------------------------

use crate::api::structs::network::Network;
use crate::backup_restore::{self, RestoreError};
use super::{ApiScanKey, ApiSpendKey};

/// The wallet material a successful restore hands to the Dart onboarding
/// flow (§7.2 restore promise). The keys come from the secrets block via
/// the pasted-descriptor onboarding path (§7.2 step 5); `last_height` is
/// the BIP-139 scan position (`last_height`, §5.1), which the app stores as
/// its sync position so scanning resumes from the backup point with no
/// rescan of pre-backup state (D9). v1 exports written by
/// `SpWallet::create_backup_file` carry no scan state yet, so the field
/// is null for those files and the app falls back to its birthday-rescan
/// path. BIP-352 label indices and per-coin attribution are parsed and
/// validated by the restore core but have no Dart-side storage in v1, so
/// they are not surfaced here.
pub struct ApiRestoredWallet {
    pub scan_key: ApiScanKey,
    pub spend_key: ApiSpendKey,
    pub network: Network,
    pub last_height: Option<u32>,
    /// The optional §5.3 companion section body, when present. Its absence
    /// is not an error (§7.2 restore promise).
    pub companion: Option<String>,
}

/// The complete caller-visible failure surface (§7.2 steps 2-3): the D1
/// gate refusal, or the single generic failure. There is deliberately no
/// richer error taxonomy — the anti-oracle rule (§7.2 step 3) forbids
/// distinguishing a wrong password from a corrupt file at this boundary.
#[derive(Debug)]
pub enum ApiRestoreFailure {
    WalletExists,
    RestoreFailed,
}

/// Restores from backup file bytes + password (§7.2). The D1 gate input
/// (`wallet_exists_on_device`) is supplied by the caller from the device's
/// wallet state; the core re-checks it before touching the file.
pub fn restore_backup_file_dart(
    file: Vec<u8>,
    password: String,
    wallet_exists_on_device: bool,
) -> Result<ApiRestoredWallet, ApiRestoreFailure> {
    match backup_restore::restore_backup_file(&file, &password, wallet_exists_on_device) {
        Ok(restored) => Ok(ApiRestoredWallet {
            scan_key: restored.scan_key,
            spend_key: restored.spend_key,
            network: restored.network,
            last_height: restored.scan_state.last_height,
            companion: restored.companion,
        }),
        Err(RestoreError::WalletExists) => Err(ApiRestoreFailure::WalletExists),
        Err(RestoreError::RestoreFailed) => Err(ApiRestoreFailure::RestoreFailed),
    }
}

#[cfg(test)]
mod restore_api_tests {
    use spdk_wallet::bitcoin::secp256k1::SecretKey;
    use spdk_wallet::client::SpendKey;

    use super::*;
    use crate::api::wallet::{ApiScanKey, ApiSpendKey, SpWallet};

    const PASSWORD: &str = "restore api passphrase 5";

    fn wallet(network: Network) -> SpWallet {
        let scan = SecretKey::from_slice(&[0x33; 32]).unwrap();
        let spend = SecretKey::from_slice(&[0x44; 32]).unwrap();
        SpWallet::new(
            ApiScanKey(scan),
            ApiSpendKey(SpendKey::Secret(spend)),
            network,
        )
        .unwrap()
    }

    fn restore(
        file: &[u8],
        password: &str,
        wallet_exists: bool,
    ) -> Result<ApiRestoredWallet, ApiRestoreFailure> {
        restore_backup_file_dart(file.to_vec(), password.to_string(), wallet_exists)
    }

    #[test]
    fn d1_gate_refuses_before_the_file_is_examined() {
        // §7.2 step 2: the refusal is a precondition on device state, not a
        // fact about the file — even garbage bytes yield WalletExists, never
        // RestoreFailed.
        assert!(matches!(
            restore(b"not a backup file", PASSWORD, true),
            Err(ApiRestoreFailure::WalletExists)
        ));
    }

    #[test]
    fn wrong_password_and_corrupt_file_collapse_into_one_outcome() {
        let wallet = wallet(Network::Mainnet);
        let file = wallet.create_backup_file(PASSWORD).unwrap();

        // §7.2 step 3 anti-oracle: both failures are the same single
        // RestoreFailed variant; nothing else about them is observable.
        let wrong_password = restore(&file, "wrong passphrase 9", false);
        let mut corrupt = file.clone();
        corrupt[0x15] ^= 0x01; // flip a bit inside argon2_t (AAD-covered)
        let corrupt_file = restore(&corrupt, PASSWORD, false);
        let truncated = restore(&file[..file.len() - 8], PASSWORD, false);

        assert!(matches!(
            wrong_password,
            Err(ApiRestoreFailure::RestoreFailed)
        ));
        assert!(matches!(corrupt_file, Err(ApiRestoreFailure::RestoreFailed)));
        assert!(matches!(truncated, Err(ApiRestoreFailure::RestoreFailed)));
    }

    #[test]
    fn success_round_trips_keys_and_network() {
        let wallet = wallet(Network::Signet);
        let file = wallet.create_backup_file(PASSWORD).unwrap();

        match restore(&file, PASSWORD, false) {
            Ok(restored) => {
                assert!(matches!(restored.network, Network::Signet));
                // The restored keys onboard back into an equivalent wallet.
                let rewallet = SpWallet::new(restored.scan_key, restored.spend_key, restored.network)
                    .unwrap();
                assert_eq!(
                    rewallet.get_encoded_descriptor_watch_only(),
                    wallet.get_encoded_descriptor_watch_only()
                );
                // v1 exports carry no scan state yet (struct doc above).
                assert_eq!(restored.last_height, None);
                assert_eq!(restored.companion, None);
            }
            Err(e) => panic!("expected success, got {e:?}"),
        }
    }

    #[test]
    fn wrong_password_on_wallet_exists_device_still_refuses_with_d1() {
        // The D1 refusal wins regardless of what is wrong with the file.
        assert!(matches!(
            restore(b"junk", "no digits at all here", true),
            Err(ApiRestoreFailure::WalletExists)
        ));
    }
}
