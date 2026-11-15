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

    use bip392::Sp;
    use serde_json::Value;

    use crate::api::structs::network::Network;
    use crate::api::wallet::{ApiScanKey, ApiSpendKey, SpWallet};
    use crate::backup;
    use crate::backup_payload;
    use crate::backup_payload::{
        PayloadError, SECTION_TYPE_BIP139, SECTION_TYPE_SECRETS, parse_sections,
    };
    use spdk_wallet::bitcoin::key::Secp256k1;
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
