//! Dana backup restore — file bytes + password -> onboarded wallet.
//!
//! Implements spec `docs/specs/encrypted-file-backup.md` (ratified v1.0,
//! commit 0592280) §7.2 steps 3–6: container decrypt (§3/§4), payload
//! section parse (§5), standalone BIP-139 validation BEFORE anything is
//! committed (§7.2 step 4), and onboarding from the secrets-block descriptor
//! through the same restore-by-pasted-descriptor path used when pasting an
//! `sp()` descriptor at onboarding (§7.2 step 5, §5.2/D11).
//!
//! Error surface (§7.2 step 3, anti-oracle): every file/password failure —
//! wrong password, corrupted header, truncated file, invalid payload —
//! collapses into the single caller-visible [`RestoreError::RestoreFailed`].
//! The API MUST NOT distinguish wrong-password from corrupt-file. The exact
//! internal cause (§9) is preserved only in the log, never in the returned
//! error. The D1 gate refusal ([`RestoreError::WalletExists`], §7.2 step 2)
//! is the one distinguishable outcome: it is a precondition on device state,
//! not a fact about the file, and the user must be told to delete first.

use std::fmt;

use log::warn;

use crate::api::structs::network::Network;
use crate::api::wallet::setup::{WalletSetupArgs, WalletSetupType};
use crate::api::wallet::{ApiScanKey, ApiSpendKey, SpWallet};
use crate::backup::{self, BackupError};
use crate::backup_payload::{
    self, PayloadError, WalletScanState, SECTION_TYPE_BIP139, SECTION_TYPE_COMPANION,
    SECTION_TYPE_SECRETS,
};

/// Caller-visible restore failures (§7.2 steps 2–3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RestoreError {
    /// D1 gate (§7.2 step 2): a wallet already exists on the device. Deletion
    /// is a restore prerequisite — no merge, no overwrite, no bypass.
    WalletExists,
    /// The single generic failure for everything wrong with the file or the
    /// password (§7.2 step 3). Deliberately opaque: wrong password, corrupted
    /// header, truncated file and invalid payload are indistinguishable to
    /// callers (anti-oracle).
    RestoreFailed,
}

impl fmt::Display for RestoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::WalletExists => write!(
                f,
                "a wallet already exists on this device — delete it before restoring a backup"
            ),
            Self::RestoreFailed => write!(
                f,
                "restore failed: this file could not be opened with the given password"
            ),
        }
    }
}

impl std::error::Error for RestoreError {}

/// Internal failure causes (§9). Never exposed through [`RestoreError`];
/// logged so wrong-password / corrupt-file stay distinguishable internally
/// only.
#[derive(Debug)]
enum InternalError {
    Container(BackupError),
    Payload(PayloadError),
    /// The BIP-139 network name has no Dana wallet network equivalent.
    UnsupportedNetwork(String),
    /// The required sections are not exactly one BIP-139 + one secrets block.
    Structure(&'static str),
    /// Onboarding via the pasted-descriptor path failed.
    Onboard(String),
}

impl fmt::Display for InternalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Container(e) => fmt::Display::fmt(e, f),
            Self::Payload(e) => fmt::Display::fmt(e, f),
            Self::UnsupportedNetwork(name) => {
                write!(f, "BIP-139 network \"{name}\" has no Dana equivalent")
            }
            Self::Structure(what) => write!(f, "payload structure invalid: {what}"),
            Self::Onboard(e) => write!(f, "descriptor onboarding failed: {e}"),
        }
    }
}

impl From<BackupError> for InternalError {
    fn from(e: BackupError) -> Self {
        Self::Container(e)
    }
}

impl From<PayloadError> for InternalError {
    fn from(e: PayloadError) -> Self {
        Self::Payload(e)
    }
}

/// Everything a successful restore hands back (§7.2 restore promise). The
/// wallet keys come from the secrets-block descriptor via the pasted-
/// descriptor onboarding path; the scan state comes from the BIP-139
/// section, so scanning resumes from the backup point with no rescan (D9).
#[derive(Debug)]
pub struct RestoredWallet {
    pub scan_key: ApiScanKey,
    pub spend_key: ApiSpendKey,
    pub network: Network,
    /// The validated standalone BIP-139 export (§5.1), carried verbatim.
    pub bip139_export: String,
    /// Scan state parsed back out of the BIP-139 section: scan position,
    /// `bip352_labels`, per-coin `tweak`/`sp_label` attribution (§5.1).
    pub scan_state: WalletScanState,
    /// The optional §5.3 companion section body, when present. Its absence
    /// is not an error (§7.2 restore promise).
    pub companion: Option<String>,
}

/// Restores a wallet from backup file bytes + password (§7.2).
///
/// `wallet_exists_on_device` is the D1 gate input (§7.2 step 2): pass whether
/// a wallet already exists on the device. Restore refuses when it does —
/// deletion is a prerequisite, there is no merge/overwrite/bypass.
///
/// Per §7.2 steps 3–6: parse header -> derive key from the header KDF params
/// (never hardcoded) -> AEAD decrypt/verify -> parse sections -> validate the
/// BIP-139 section as a standalone BIP-139 export BEFORE committing anything
/// -> onboard from the secrets-block descriptor via
/// [`WalletSetupType::Descriptor`] — the same code path as pasting an `sp()`
/// descriptor at onboarding.
pub fn restore_backup_file(
    file: &[u8],
    password: &str,
    wallet_exists_on_device: bool,
) -> Result<RestoredWallet, RestoreError> {
    // D1 gate first (§7.2 step 2): refuse before touching the file at all.
    if wallet_exists_on_device {
        return Err(RestoreError::WalletExists);
    }
    restore_internal(file, password).map_err(|e| {
        // Internal distinction only (§9): the caller sees one generic error
        // regardless of what exactly failed.
        warn!(target: "dana_backup", "restore failed internally: {e}");
        RestoreError::RestoreFailed
    })
}

fn restore_internal(file: &[u8], password: &str) -> Result<RestoredWallet, InternalError> {
    // Step 3: header parse -> KDF from header params -> AEAD decrypt/verify.
    // Every container failure (bad magic, newer version, truncation, wrong
    // password, tampered AAD) is terminal with no partial output (§9).
    let payload = backup::decrypt(file, password)?;

    // Section parse (§5): fixed-order type/len/body framing; unknown types
    // are returned untouched and ignored here (forward compatibility).
    let sections = backup_payload::parse_sections(&payload)?;

    let mut bip139: Option<Vec<u8>> = None;
    let mut secrets: Option<Vec<u8>> = None;
    let mut companion: Option<Vec<u8>> = None;
    for (section_type, body) in sections {
        match section_type {
            SECTION_TYPE_BIP139 => {
                if bip139.is_some() {
                    return Err(InternalError::Structure("duplicate BIP-139 section"));
                }
                bip139 = Some(body);
            }
            SECTION_TYPE_SECRETS => {
                if secrets.is_some() {
                    return Err(InternalError::Structure("duplicate secrets section"));
                }
                secrets = Some(body);
            }
            SECTION_TYPE_COMPANION if companion.is_none() => {
                companion = Some(body);
            }
            // Unrecognized section types are ignored (§5, forward compat).
            _ => {}
        }
    }
    // Both v1 sections marked REQUIRED (§5) must be present.
    let bip139 = bip139.ok_or(InternalError::Structure("missing BIP-139 section"))?;
    let secrets = secrets.ok_or(InternalError::Structure("missing secrets section"))?;

    // Step 4: validate the BIP-139 section as a standalone BIP-139 export
    // BEFORE committing anything (§7.2 step 4) — this runs before onboarding.
    let bip139_export = std::str::from_utf8(&bip139)
        .map_err(|_| PayloadError::SectionNotUtf8(SECTION_TYPE_BIP139))?
        .to_string();
    backup_payload::validate_bip139_export(&bip139_export)?;
    let scan_state = backup_payload::parse_bip139_scan_state(&bip139_export)?;
    let network_name = backup_payload::parse_bip139_network(&bip139_export)?;
    let network = network_from_bip139_name(&network_name)?;

    // Secrets block (§5.2): the full encoded sp() spend descriptor. Only
    // ever handled here, inside the decrypted payload — never logged, never
    // serialized to any plaintext surface.
    let secrets_body = std::str::from_utf8(&secrets)
        .map_err(|_| PayloadError::SectionNotUtf8(SECTION_TYPE_SECRETS))?;
    let spend_descriptor = backup_payload::parse_secrets_block(secrets_body)?;

    // Step 5: onboard from the secrets-block descriptor through the exact
    // restore-by-pasted-descriptor path (setup.rs `WalletSetupType::Descriptor`).
    let onboarded = SpWallet::setup_wallet(WalletSetupArgs {
        setup_type: WalletSetupType::Descriptor(spend_descriptor),
        network: network.clone(),
    })
    .map_err(|e| InternalError::Onboard(e.to_string()))?;

    Ok(RestoredWallet {
        scan_key: onboarded.scan_key,
        spend_key: onboarded.spend_key,
        network,
        bip139_export,
        scan_state,
        companion: companion.map(|c| String::from_utf8_lossy(&c).into_owned()),
    })
}

/// Maps a BIP-139 export `network` name to a Dana wallet network. The export
/// validator (§5.1 import guidelines) also admits `mutinynet`, which no Dana
/// wallet network corresponds to — a Dana v1 backup can never contain it, so
/// it fails the restore.
fn network_from_bip139_name(name: &str) -> Result<Network, InternalError> {
    match name {
        "bitcoin" => Ok(Network::Mainnet),
        "testnet3" => Ok(Network::Testnet3),
        "testnet4" => Ok(Network::Testnet4),
        "signet" => Ok(Network::Signet),
        "regtest" => Ok(Network::Regtest),
        other => Err(InternalError::UnsupportedNetwork(other.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use bip392::{Sp, SpKey, SpSpendKey};
    use serde_json::{json, Value};
    use spdk_wallet::bitcoin::key::Secp256k1;
    use spdk_wallet::bitcoin::secp256k1::SecretKey;
    use spdk_wallet::client::SpendKey;
    use spdk_wallet::silentpayments::Network as SpNetwork;

    use super::*;

    use crate::api::structs::network::Network;
    use crate::api::wallet::{ApiScanKey, ApiSpendKey, SpWallet};
    use crate::backup;
    use crate::backup_payload::{
        frame_sections, parse_sections, BackupCoin, Bip352Labels, WalletScanState,
        SECTION_TYPE_BIP139,
    };

    const PASSWORD: &str = "restore passphrase 7";

    /// `Network` carries no `PartialEq`; compare via the BIP-139 network name
    /// (the same names the §5.1 export uses).
    fn net_name(network: &Network) -> &'static str {
        match network {
            Network::Mainnet => "bitcoin",
            Network::Testnet3 => "testnet3",
            Network::Testnet4 => "testnet4",
            Network::Signet => "signet",
            Network::Regtest => "regtest",
        }
    }

    fn keypair() -> (SecretKey, SecretKey) {
        (
            SecretKey::from_slice(&[0x11; 32]).unwrap(),
            SecretKey::from_slice(&[0x22; 32]).unwrap(),
        )
    }

    /// A live wallet built exactly like the BK-02 tests build theirs.
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

    /// Backup file bytes from a live wallet via the BK-02 API.
    fn wallet_backup_file(network: Network) -> (Vec<u8>, SecretKey, SecretKey, SpWallet) {
        let (wallet, scan, spend) = wallet(network);
        let file = wallet.create_backup_file(PASSWORD).unwrap();
        (file, scan, spend, wallet)
    }

    fn restored_of(file: &[u8]) -> RestoredWallet {
        restore_backup_file(file, PASSWORD, false).unwrap()
    }

    #[test]
    fn round_trip_restores_the_original_wallet() {
        // Acceptance 1: wallet -> file -> restore -> state equivalent.
        let (file, scan, spend, original) = wallet_backup_file(Network::Mainnet);
        let restored = restored_of(&file);

        assert_eq!(restored.scan_key.0, scan);
        assert_eq!(restored.spend_key.0, SpendKey::Secret(spend));
        assert_eq!(net_name(&restored.network), "bitcoin");
        assert_eq!(
            net_name(&restored.network),
            net_name(&original.get_network())
        );

        // The restored keys are the ones carried by the secrets-block
        // descriptor (the value BK-02 stored, byte-identical after restore).
        let descriptor = original.get_encoded_descriptor().unwrap();
        let value: Value = serde_json::from_str(
            &String::from_utf8(
                parse_sections(&backup::decrypt(&file, PASSWORD).unwrap()).unwrap()[1]
                    .1
                    .clone(),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(value["descriptor"], descriptor);
    }

    #[test]
    fn restored_descriptor_matches_the_secrets_block_via_the_pasted_path() {
        // §7.2 step 5: onboarding goes through the same code path as pasting
        // an sp() descriptor — the result must equal parsing that descriptor
        // directly (setup.rs semantics).
        let (file, _scan, _spend, _wallet) = wallet_backup_file(Network::Testnet3);
        let payload = backup::decrypt(&file, PASSWORD).unwrap();
        let sections = parse_sections(&payload).unwrap();
        let secrets_body = String::from_utf8(sections[1].1.clone()).unwrap();
        let descriptor = backup_payload::parse_secrets_block(&secrets_body).unwrap();

        let direct = SpWallet::setup_wallet(WalletSetupArgs {
            setup_type: WalletSetupType::Descriptor(descriptor.clone()),
            network: Network::Testnet3,
        })
        .unwrap();
        let restored = restored_of(&file);
        assert_eq!(restored.scan_key.0, direct.scan_key.0);
        assert_eq!(restored.spend_key.0, direct.spend_key.0);

        let sp = Sp::from_str(&descriptor).unwrap();
        assert_eq!(restored.scan_key.0, sp.scan_key());
        assert_eq!(
            restored.spend_key.0,
            SpendKey::Secret(sp.spend_secret().unwrap())
        );
        assert_eq!(net_name(&restored.network), "testnet3");
    }

    #[test]
    fn scan_state_round_trips_through_the_file() {
        // Restore promise (§7.2): scan position, bip352 labels and per-coin
        // tweak/sp_label attribution come back exactly as they went in.
        let (scan, spend) = keypair();
        let scan_key = SpKey::Scan(bip392::SpScanKey {
            scan_key: scan,
            spend_key: spend.public_key(&Secp256k1::signing_only()),
            network: SpNetwork::Mainnet,
        });
        let watch_descriptor = Sp::from_sp_key(scan_key).to_string();
        let spend_key = SpKey::Spend(SpSpendKey {
            scan_key: scan,
            spend_key: spend,
            network: SpNetwork::Mainnet,
        });
        let secrets_descriptor = Sp::from_sp_key(spend_key).to_string();

        let state = WalletScanState {
            last_height: Some(912_345),
            bip352_labels: Some(Bip352Labels::Indices(vec![3, 17, 42])),
            coins: vec![
                BackupCoin {
                    outpoint: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1"
                        .into(),
                    amount_sats: Some(55_000),
                    tweak: Some([0xAB; 32]),
                    sp_label: Some([0x02; 32]),
                    block_height: Some(912_000),
                    is_change: Some(false),
                    derivation_index: Some(11),
                },
                BackupCoin {
                    outpoint: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:0"
                        .into(),
                    amount_sats: Some(1_000),
                    tweak: Some([0xCD; 32]),
                    sp_label: None,
                    block_height: Some(912_340),
                    is_change: Some(true),
                    derivation_index: Some(12),
                },
            ],
        };
        let export =
            backup_payload::build_bip139_export(Network::Mainnet, &watch_descriptor, Some(&state));
        let payload = backup_payload::build_payload(
            &export,
            &backup_payload::build_secrets_block(&secrets_descriptor),
            None,
        )
        .unwrap();
        let file = backup::encrypt(&payload, PASSWORD).unwrap();

        let restored = restored_of(&file);
        assert_eq!(restored.scan_state.last_height, Some(912_345));
        assert_eq!(
            restored.scan_state.bip352_labels,
            Some(Bip352Labels::Indices(vec![3, 17, 42]))
        );
        assert_eq!(restored.scan_state.coins, state.coins);
        // Scan state lives only in the BIP-139 section — no lastScan field
        // anywhere in the container (D9).
        assert!(!restored.bip139_export.contains("lastScan"));
        assert!(restored.companion.is_none());
    }

    #[test]
    fn label_range_round_trips() {
        // bip352_labels may also be a {start, end} range (field registry).
        let (scan, spend) = keypair();
        let watch = Sp::from_sp_key(SpKey::Scan(bip392::SpScanKey {
            scan_key: scan,
            spend_key: spend.public_key(&Secp256k1::signing_only()),
            network: SpNetwork::Testnet,
        }))
        .to_string();
        let full = Sp::from_sp_key(SpKey::Spend(SpSpendKey {
            scan_key: scan,
            spend_key: spend,
            network: SpNetwork::Testnet,
        }))
        .to_string();
        let export = backup_payload::build_bip139_export(
            Network::Testnet3,
            &watch,
            Some(&WalletScanState {
                last_height: Some(100),
                bip352_labels: Some(Bip352Labels::Range { start: 0, end: 5 }),
                coins: vec![],
            }),
        );
        let payload = backup_payload::build_payload(
            &export,
            &backup_payload::build_secrets_block(&full),
            None,
        )
        .unwrap();
        let file = backup::encrypt(&payload, PASSWORD).unwrap();
        let restored = restored_of(&file);
        assert_eq!(
            restored.scan_state.bip352_labels,
            Some(Bip352Labels::Range { start: 0, end: 5 })
        );
    }

    #[test]
    fn optional_companion_section_absent_is_not_an_error() {
        // Restore promise: contacts/settings only if the §5.3 section is
        // present; its absence is not an error.
        let (file, _scan, _spend, _wallet) = wallet_backup_file(Network::Mainnet);
        let restored = restored_of(&file);
        assert!(restored.companion.is_none());
    }

    #[test]
    fn optional_companion_section_present_is_carried() {
        let (wallet, _scan, _spend) = wallet(Network::Testnet3);
        let spend_descriptor = wallet.get_encoded_descriptor().unwrap();
        let watch_descriptor = wallet.get_encoded_descriptor_watch_only();
        let export =
            backup_payload::build_bip139_export(Network::Testnet3, &watch_descriptor, None);
        let companion = json!({"contacts": [{"name": "satoshi", "address": "SP1..."}]}).to_string();
        let payload = backup_payload::build_payload(
            &export,
            &backup_payload::build_secrets_block(&spend_descriptor),
            Some(&companion),
        )
        .unwrap();
        let file = backup::encrypt(&payload, PASSWORD).unwrap();

        let restored = restored_of(&file);
        assert_eq!(restored.companion.as_deref(), Some(companion.as_str()));
    }

    #[test]
    fn unknown_section_types_are_ignored() {
        // §5: readers MUST ignore section types they do not recognize.
        let (wallet, _scan, _spend) = wallet(Network::Mainnet);
        let spend_descriptor = wallet.get_encoded_descriptor().unwrap();
        let watch_descriptor = wallet.get_encoded_descriptor_watch_only();
        let export = backup_payload::build_bip139_export(Network::Mainnet, &watch_descriptor, None);
        let mut payload = backup_payload::build_payload(
            &export,
            &backup_payload::build_secrets_block(&spend_descriptor),
            None,
        )
        .unwrap();
        payload.extend_from_slice(&frame_sections(&[(
            0x0000_00FF,
            b"some v2 future section".as_slice(),
        )]));
        let file = backup::encrypt(&payload, PASSWORD).unwrap();

        let restored = restored_of(&file);
        assert_eq!(net_name(&restored.network), "bitcoin");
        assert!(restored.companion.is_none());
    }

    #[test]
    fn d1_gate_refuses_when_a_wallet_already_exists() {
        // Acceptance 3 / §7.2 step 2: existing wallet on device -> restore
        // refused. The gate fires before the file is even looked at.
        let (file, _scan, _spend, _wallet) = wallet_backup_file(Network::Mainnet);
        assert_eq!(
            restore_backup_file(&file, PASSWORD, true).unwrap_err(),
            RestoreError::WalletExists
        );
        // And not even a valid file can bypass it: garbage in, same refusal.
        assert_eq!(
            restore_backup_file(b"not a file", PASSWORD, true).unwrap_err(),
            RestoreError::WalletExists
        );
    }

    #[test]
    fn anti_oracle_all_failure_paths_collapse_to_one_error() {
        // Acceptance 4 / §7.2 step 3: wrong password and corrupted file
        // return the IDENTICAL caller-visible error.
        let (file, _scan, _spend, _wallet) = wallet_backup_file(Network::Mainnet);

        // Wrong password (policy-valid, so the password rules are not what
        // failed — the AEAD verdict is).
        let wrong_password = restore_backup_file(&file, "another passphrase", false).unwrap_err();

        // Corrupted ciphertext (one flipped bit past the header).
        let mut corrupted = file.clone();
        let last = corrupted.len() - 1;
        corrupted[last] ^= 0x01;
        let corrupted_ciphertext = restore_backup_file(&corrupted, PASSWORD, false).unwrap_err();

        // Corrupted header AAD (flip a bit in argon2_t — §9 vector 5).
        let mut tampered = file.clone();
        tampered[0x14] ^= 0x01;
        let corrupted_header = restore_backup_file(&tampered, PASSWORD, false).unwrap_err();

        // Corrupted magic (§9 vector 5 companion case).
        let mut magic = file.clone();
        magic[3] ^= 0x01;
        let bad_magic = restore_backup_file(&magic, PASSWORD, false).unwrap_err();

        // Truncated file (header cut, and payload+tag cut).
        let truncated_header = restore_backup_file(&file[..0x30], PASSWORD, false).unwrap_err();
        let truncated_tail =
            restore_backup_file(&file[..file.len() - 9], PASSWORD, false).unwrap_err();

        // Invalid payload behind a valid container (empty sections).
        let empty_payload_file = backup::encrypt(b"", PASSWORD).unwrap();
        let empty_payload = restore_backup_file(&empty_payload_file, PASSWORD, false).unwrap_err();

        for err in [
            &wrong_password,
            &corrupted_ciphertext,
            &corrupted_header,
            &bad_magic,
            &truncated_header,
            &truncated_tail,
            &empty_payload,
        ] {
            assert_eq!(err, &RestoreError::RestoreFailed);
            // The caller-visible string is identical for every path — no
            // oracle on Display either.
            assert_eq!(err.to_string(), RestoreError::RestoreFailed.to_string());
        }
    }

    #[test]
    fn v1_reader_rejects_escrow_entries() {
        // Acceptance 5 / §3.3: escrow_entry_count > 0 means "file written by
        // a newer version" — the v1 reader must fail restore.
        let (file, _scan, _spend, _wallet) = wallet_backup_file(Network::Mainnet);
        let mut escrow = file.clone();
        escrow[0x45..0x49].copy_from_slice(&1u32.to_le_bytes());

        // Internally distinguished (§9): the container reports NewerVersion,
        // not an authentication failure.
        assert_eq!(
            backup::decrypt(&escrow, PASSWORD).unwrap_err(),
            BackupError::NewerVersion
        );
        // Caller-visible: the same generic error as every other failure.
        assert_eq!(
            restore_backup_file(&escrow, PASSWORD, false).unwrap_err(),
            RestoreError::RestoreFailed
        );
    }

    #[test]
    fn header_kdf_params_are_honored_not_hardcoded() {
        // §3.3 note / §6.3.2: decrypt MUST use the header values as written.
        // A file written with non-default params still restores, proving no
        // default was assumed on the read side.
        let (wallet, _scan, _spend) = wallet(Network::Testnet3);
        let spend_descriptor = wallet.get_encoded_descriptor().unwrap();
        let watch_descriptor = wallet.get_encoded_descriptor_watch_only();
        let payload = backup_payload::build_payload(
            &backup_payload::build_bip139_export(Network::Testnet3, &watch_descriptor, None),
            &backup_payload::build_secrets_block(&spend_descriptor),
            None,
        )
        .unwrap();
        let file = backup::encrypt_with(
            backup::CIPHER_XCHACHA20_POLY1305,
            8,
            1,
            1,
            &payload,
            PASSWORD,
        )
        .unwrap();
        let restored = restore_backup_file(&file, PASSWORD, false).unwrap();
        assert_eq!(net_name(&restored.network), "testnet3");
        assert_eq!(restored.spend_key.0, wallet.get_spend_key().0);

        // Reader-side AES-256-GCM capability (§3.4, cipher_id 0x02).
        let file =
            backup::encrypt_with(backup::CIPHER_AES_256_GCM, 8, 1, 1, &payload, PASSWORD).unwrap();
        restore_backup_file(&file, PASSWORD, false).unwrap();
    }

    #[test]
    fn nonzero_reserved_bytes_reject_the_restore() {
        // §3.1: readers MUST treat nonzero reserved bytes as a parse error.
        let (file, _scan, _spend, _wallet) = wallet_backup_file(Network::Mainnet);
        let mut reserved = file.clone();
        reserved[0x0C] = 0x01;
        assert_eq!(
            restore_backup_file(&reserved, PASSWORD, false).unwrap_err(),
            RestoreError::RestoreFailed
        );
    }

    #[test]
    fn missing_required_section_rejects_the_restore() {
        // §5: the BIP-139 and secrets sections are both REQUIRED.
        let (wallet, _scan, _spend) = wallet(Network::Mainnet);
        let watch_descriptor = wallet.get_encoded_descriptor_watch_only();
        let export = backup_payload::build_bip139_export(Network::Mainnet, &watch_descriptor, None);
        let bip139_only = frame_sections(&[(SECTION_TYPE_BIP139, export.as_bytes())]);
        let file = backup::encrypt(&bip139_only, PASSWORD).unwrap();
        assert_eq!(
            restore_backup_file(&file, PASSWORD, false).unwrap_err(),
            RestoreError::RestoreFailed
        );
    }

    #[test]
    fn invalid_bip139_section_rejects_before_onboarding() {
        // §7.2 step 4: the BIP-139 section must validate as a standalone
        // BIP-139 export BEFORE anything is committed. A mainnet export
        // carrying spend keys is spec-invalid (D2) and must fail the restore
        // even though the descriptor in the secrets block is fine.
        let (scan, spend) = keypair();
        let full = Sp::from_sp_key(SpKey::Spend(SpSpendKey {
            scan_key: scan,
            spend_key: spend,
            network: SpNetwork::Mainnet,
        }))
        .to_string();
        let payload = backup_payload::build_payload(
            &backup_payload::build_bip139_export(Network::Mainnet, &full, None),
            &backup_payload::build_secrets_block(&full),
            None,
        )
        .unwrap();
        let file = backup::encrypt(&payload, PASSWORD).unwrap();
        assert_eq!(
            restore_backup_file(&file, PASSWORD, false).unwrap_err(),
            RestoreError::RestoreFailed
        );
    }

    #[test]
    fn mutinynet_export_has_no_dana_equivalent() {
        // validate_bip139_export admits "mutinynet" (BIP-139 import
        // guidelines), but no Dana wallet network corresponds to it; a v1
        // Dana backup can never contain one, so restore fails.
        let (scan, spend) = keypair();
        let watch = Sp::from_sp_key(SpKey::Scan(bip392::SpScanKey {
            scan_key: scan,
            spend_key: spend.public_key(&Secp256k1::signing_only()),
            network: SpNetwork::Testnet,
        }))
        .to_string();
        let full = Sp::from_sp_key(SpKey::Spend(SpSpendKey {
            scan_key: scan,
            spend_key: spend,
            network: SpNetwork::Testnet,
        }))
        .to_string();
        let mut export_value: Value = serde_json::from_str(&backup_payload::build_bip139_export(
            Network::Testnet3,
            &watch,
            None,
        ))
        .unwrap();
        export_value["network"] = json!("mutinynet");
        let payload = backup_payload::build_payload(
            &export_value.to_string(),
            &backup_payload::build_secrets_block(&full),
            None,
        )
        .unwrap();
        let file = backup::encrypt(&payload, PASSWORD).unwrap();
        assert_eq!(
            restore_backup_file(&file, PASSWORD, false).unwrap_err(),
            RestoreError::RestoreFailed
        );
    }

    #[test]
    fn corrupted_bip139_json_rejects_the_restore() {
        // The BIP-139 section must survive as valid JSON after decrypt.
        let (file, _scan, _spend, _wallet) = wallet_backup_file(Network::Mainnet);
        let payload = backup::decrypt(&file, PASSWORD).unwrap();
        let mut sections = parse_sections(&payload).unwrap();
        sections[0].1 = b"{\"version\": \"BIP139-1\"".to_vec(); // truncated JSON
        let corrupted_payload = frame_sections(
            &sections
                .iter()
                .map(|(t, b)| (*t, b.as_slice()))
                .collect::<Vec<_>>(),
        );
        let corrupted_file = backup::encrypt(&corrupted_payload, PASSWORD).unwrap();
        assert_eq!(
            restore_backup_file(&corrupted_file, PASSWORD, false).unwrap_err(),
            RestoreError::RestoreFailed
        );
    }
}
