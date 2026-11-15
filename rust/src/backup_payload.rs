//! Dana backup inner payload — sections, BIP-139 export, secrets block.
//!
//! Implements spec `docs/specs/encrypted-file-backup.md` (ratified v1.0,
//! commit 0592280): §5 inner payload layout (fixed-order length-prefixed
//! sections), §5.1 BIP-139 payload section, §5.2 Dana secrets block, and the
//! export-time password policy of §6.1. The container crypto lives in
//! [`crate::backup`]; this module turns wallet state into the payload bytes
//! that [`crate::backup::encrypt`] wraps.

use std::fmt;
use std::str::FromStr;

use bip392::Sp;
use serde_json::{Value, json};

use crate::api::structs::network::Network;
use crate::backup::BackupError;

/// Section type 0x00000001: BIP-139 payload (REQUIRED), spec §5.
pub const SECTION_TYPE_BIP139: u32 = 0x0000_0001;
/// Section type 0x00000002: Dana secrets block (REQUIRED), spec §5.
pub const SECTION_TYPE_SECRETS: u32 = 0x0000_0002;
/// Section type 0x00000003: companion fields (OPTIONAL; omitted when there
/// is nothing to store), spec §5 / §5.3.
pub const SECTION_TYPE_COMPANION: u32 = 0x0000_0003;

/// Everything the payload layer can fail with. Container-level failures are
/// carried verbatim in [`PayloadError::Container`] so the caller sees the
/// [`BackupError`] semantics unchanged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PayloadError {
    /// A section header or body runs past the end of the payload (§5).
    TruncatedSection,
    /// A section body is not valid UTF-8 (§5: all v1 sections are JSON).
    SectionNotUtf8(u32),
    /// A "JSON" payload is not a JSON object at all.
    NotAJsonObject,
    /// A mandatory field is absent (BIP-139 import guideline: mandatory
    /// fields must be present).
    MissingField(&'static str),
    /// A field is present but malformed.
    InvalidField { field: &'static str },
    /// Mainnet BIP-139 section carries spend keys — forbidden by D2 / §5.1.
    MainnetSpendKeyInBip139,
    /// The wallet cannot be backed up: it is watch-only, so the REQUIRED
    /// secrets block (§5.2) has no spend descriptor to store.
    WatchOnlyWallet,
    /// Password shorter than 16 Unicode scalar values (§6.1 rule 1).
    PasswordTooShort,
    /// Password without a lowercase character (§6.1 rule 2).
    PasswordNoLowercase,
    /// Password without a digit (§6.1 rule 3).
    PasswordNoDigit,
    /// The BK-01 container encrypt failed; the inner error keeps the exact
    /// spec semantics (§3–§4, §9).
    Container(BackupError),
}

impl fmt::Display for PayloadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TruncatedSection => write!(f, "payload section is truncated"),
            Self::SectionNotUtf8(t) => write!(f, "section {t} body is not UTF-8"),
            Self::NotAJsonObject => write!(f, "payload is not a JSON object"),
            Self::MissingField(field) => write!(f, "missing mandatory field {field}"),
            Self::InvalidField { field } => write!(f, "invalid value for field {field}"),
            Self::MainnetSpendKeyInBip139 => {
                write!(f, "mainnet BIP-139 section must not contain spend keys")
            }
            Self::WatchOnlyWallet => write!(f, "watch-only wallet cannot be backed up"),
            Self::PasswordTooShort => write!(f, "password must be at least 16 characters"),
            Self::PasswordNoLowercase => write!(f, "password must contain a lowercase character"),
            Self::PasswordNoDigit => write!(f, "password must contain a digit"),
            Self::Container(e) => fmt::Display::fmt(e, f),
        }
    }
}

impl std::error::Error for PayloadError {}

impl From<BackupError> for PayloadError {
    fn from(e: BackupError) -> Self {
        Self::Container(e)
    }
}

/// Framing per spec §5: for each section, 4-byte LE `section_type` +
/// 4-byte LE `section_len` + body, sections concatenated in the order given
/// (v1 writers use the fixed order BIP-139, secrets block, companion).
pub fn frame_sections(sections: &[(u32, &[u8])]) -> Vec<u8> {
    let mut out = Vec::new();
    for (section_type, body) in sections {
        out.extend_from_slice(&section_type.to_le_bytes());
        out.extend_from_slice(&(body.len() as u32).to_le_bytes());
        out.extend_from_slice(body);
    }
    out
}

/// Inverse of [`frame_sections`]: returns `(section_type, body)` pairs in
/// file order. Unknown section types are returned untouched — readers MUST
/// ignore types they do not recognize (§5, forward compatibility).
pub fn parse_sections(payload: &[u8]) -> Result<Vec<(u32, Vec<u8>)>, PayloadError> {
    let mut sections = Vec::new();
    let mut rest = payload;
    while !rest.is_empty() {
        if rest.len() < 8 {
            return Err(PayloadError::TruncatedSection);
        }
        let section_type = u32::from_le_bytes(rest[0..4].try_into().expect("4 bytes"));
        let section_len =
            u32::from_le_bytes(rest[4..8].try_into().expect("4 bytes")) as usize;
        let body = rest
            .get(8..8 + section_len)
            .ok_or(PayloadError::TruncatedSection)?;
        sections.push((section_type, body.to_vec()));
        rest = &rest[8 + section_len..];
    }
    Ok(sections)
}

/// Scan state carried inside the BIP-139 section (§5.1): scan position and
/// per-coin attribution. There is deliberately no `lastScan` field anywhere
/// in the container — BIP-139 owns scan state (D9).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WalletScanState {
    /// Height this wallet has been synced to (BIP-139 account field
    /// `last_height`).
    pub last_height: Option<u32>,
    /// The silent payment label indices in use (BIP-139 `bip352_labels`).
    pub bip352_labels: Option<Bip352Labels>,
    /// Owned outputs (BIP-139 `coins`), silent payment outputs included.
    pub coins: Vec<BackupCoin>,
}

/// BIP-139 `bip352_labels`: either an array of integers or a `{"start",
/// "end"}` range with exclusive end (field registry).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Bip352Labels {
    Indices(Vec<u32>),
    Range { start: u32, end: u32 },
}

/// A BIP-139 coin object (field registry): one owned output. `tweak` and
/// `sp_label` are the silent payment attribution scalars, encoded as 64
/// lowercase hex characters in big-endian order; absent when not applicable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackupCoin {
    pub outpoint: String,
    pub amount_sats: Option<u64>,
    pub tweak: Option<[u8; 32]>,
    pub sp_label: Option<[u8; 32]>,
    pub block_height: Option<u32>,
    pub is_change: Option<bool>,
    pub derivation_index: Option<u32>,
}

fn lower_hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(s, "{b:02x}");
    }
    s
}

fn coin_to_json(coin: &BackupCoin) -> Value {
    let mut m = serde_json::Map::new();
    m.insert("outpoint".into(), json!(coin.outpoint));
    if let Some(amount) = coin.amount_sats {
        m.insert("amount".into(), json!(amount));
    }
    if let Some(tweak) = coin.tweak {
        m.insert("tweak".into(), json!(lower_hex(&tweak)));
    }
    if let Some(sp_label) = coin.sp_label {
        m.insert("sp_label".into(), json!(lower_hex(&sp_label)));
    }
    if let Some(h) = coin.block_height {
        m.insert("block_height".into(), json!(h));
    }
    if let Some(c) = coin.is_change {
        m.insert("is_change".into(), json!(c));
    }
    if let Some(i) = coin.derivation_index {
        m.insert("derivation_index".into(), json!(i));
    }
    Value::Object(m)
}

/// Builds the BIP-139 export JSON for the §5.1 section body: a spec-valid
/// BIP-139 wallet export (version `BIP139-1`, one `bip392` account whose
/// descriptor is the watch-only `sp()` descriptor built from the wallet
/// keys). Mainnet constraint D2: the caller MUST pass a descriptor without
/// spend keys; [`validate_bip139_export`] re-checks this on the result.
pub fn build_bip139_export(
    network: Network,
    scan_descriptor: &str,
    scan_state: Option<&WalletScanState>,
) -> String {
    let mut account = json!({
        "type": "bip392",
        "descriptor": scan_descriptor,
    });
    if let Some(state) = scan_state {
        let obj = account.as_object_mut().expect("object literal");
        if let Some(height) = state.last_height {
            obj.insert("last_height".into(), json!(height));
        }
        if let Some(labels) = &state.bip352_labels {
            let labels = match labels {
                Bip352Labels::Indices(indices) => json!(indices),
                Bip352Labels::Range { start, end } => json!({"start": start, "end": end}),
            };
            obj.insert("bip352_labels".into(), labels);
        }
        if !state.coins.is_empty() {
            let coins = state.coins.iter().map(coin_to_json).collect::<Vec<_>>();
            obj.insert("coins".into(), json!(coins));
        }
    }
    let network_name = match network {
        Network::Mainnet => "bitcoin",
        Network::Testnet3 => "testnet3",
        Network::Testnet4 => "testnet4",
        Network::Signet => "signet",
        Network::Regtest => "regtest",
    };
    json!({
        "version": "BIP139-1",
        "network": network_name,
        "accounts": [account],
    })
    .to_string()
}

/// Structural validation of a BIP-139 export per the BIP-139 import
/// guidelines: a single JSON object with `version` (`BIP139-<int>`),
/// `network` (one of the six permitted names), and a non-empty `accounts`
/// array whose entries carry `type` and `descriptor`. For `bip392` accounts
/// the descriptor must parse as an `sp()` descriptor, and a mainnet export
/// MUST NOT contain spend keys (BIP-139 security considerations, D2).
pub fn validate_bip139_export(export: &str) -> Result<(), PayloadError> {
    let value: Value = serde_json::from_str(export).map_err(|_| PayloadError::NotAJsonObject)?;
    let obj = value.as_object().ok_or(PayloadError::NotAJsonObject)?;

    let version = obj
        .get("version")
        .and_then(Value::as_str)
        .ok_or(PayloadError::MissingField("version"))?;
    let digits = version.strip_prefix("BIP139-").ok_or(PayloadError::InvalidField { field: "version" })?;
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return Err(PayloadError::InvalidField { field: "version" });
    }

    let network = obj
        .get("network")
        .and_then(Value::as_str)
        .ok_or(PayloadError::MissingField("network"))?;
    const NETWORKS: [&str; 6] = ["bitcoin", "testnet3", "testnet4", "signet", "mutinynet", "regtest"];
    if !NETWORKS.contains(&network) {
        return Err(PayloadError::InvalidField { field: "network" });
    }

    let accounts = obj
        .get("accounts")
        .and_then(Value::as_array)
        .ok_or(PayloadError::MissingField("accounts"))?;
    if accounts.is_empty() {
        return Err(PayloadError::InvalidField { field: "accounts" });
    }
    const ACCOUNT_TYPES: [&str; 4] = ["bip380", "multi_bip380", "bip388", "bip392"];
    for account in accounts {
        let account = account
            .as_object()
            .ok_or(PayloadError::InvalidField { field: "accounts" })?;
        let account_type = account
            .get("type")
            .and_then(Value::as_str)
            .ok_or(PayloadError::MissingField("type"))?;
        if !ACCOUNT_TYPES.contains(&account_type) {
            return Err(PayloadError::InvalidField { field: "type" });
        }
        let descriptor = account
            .get("descriptor")
            .ok_or(PayloadError::MissingField("descriptor"))?;
        if account_type == "multi_bip380" {
            if !descriptor.is_array() {
                return Err(PayloadError::InvalidField { field: "descriptor" });
            }
        } else {
            let descriptor = descriptor
                .as_str()
                .ok_or(PayloadError::InvalidField { field: "descriptor" })?;
            if account_type == "bip392" {
                let sp = Sp::from_str(descriptor)
                    .map_err(|_| PayloadError::InvalidField { field: "descriptor" })?;
                if network == "bitcoin" && sp.has_spend_key() {
                    return Err(PayloadError::MainnetSpendKeyInBip139);
                }
            }
        }
    }
    Ok(())
}

/// Builds the Dana secrets block JSON (§5.2): `{"descriptor": "<full
/// encoded sp() spend descriptor>"}` — the string from
/// `WalletInfo::get_encoded_descriptor()` (`SpKey::Spend` form). The block
/// exists only inside the encrypted payload; it is never serialized to the
/// BIP-139 section, to logs, or to any plaintext surface.
pub fn build_secrets_block(spend_descriptor: &str) -> String {
    json!({"descriptor": spend_descriptor}).to_string()
}

/// Assembles the v1 payload (§5): BIP-139 section, secrets block, and the
/// optional companion section, in the fixed order.
pub fn build_payload(
    bip139_export: &str,
    secrets_block: &str,
    companion: Option<&str>,
) -> Result<Vec<u8>, PayloadError> {
    let mut sections: Vec<(u32, &[u8])> = vec![
        (SECTION_TYPE_BIP139, bip139_export.as_bytes()),
        (SECTION_TYPE_SECRETS, secrets_block.as_bytes()),
    ];
    if let Some(companion) = companion {
        sections.push((SECTION_TYPE_COMPANION, companion.as_bytes()));
    }
    for (section_type, body) in &sections {
        if std::str::from_utf8(body).is_err() {
            return Err(PayloadError::SectionNotUtf8(*section_type));
        }
    }
    Ok(frame_sections(&sections))
}

/// Export-time password policy, enforced deterministically (§6.1): at least
/// 16 Unicode scalar values, at least one lowercase character, at least one
/// digit. No entropy meter, no scoring.
pub fn validate_password(password: &str) -> Result<(), PayloadError> {
    if password.chars().count() < 16 {
        return Err(PayloadError::PasswordTooShort);
    }
    if !password.chars().any(char::is_lowercase) {
        return Err(PayloadError::PasswordNoLowercase);
    }
    if !password.chars().any(|c| c.is_ascii_digit()) {
        return Err(PayloadError::PasswordNoDigit);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backup;

    fn body(tag: &[u8]) -> Vec<u8> {
        let mut b = b"body-".to_vec();
        b.extend_from_slice(tag);
        b
    }

    #[test]
    fn framing_is_type_len_body_in_order() {
        let b1 = body(b"one");
        let b2 = body(b"two");
        let framed = frame_sections(&[(SECTION_TYPE_BIP139, &b1), (SECTION_TYPE_SECRETS, &b2)]);
        assert_eq!(&framed[0..4], &1u32.to_le_bytes());
        assert_eq!(&framed[4..8], &(b1.len() as u32).to_le_bytes());
        assert_eq!(&framed[8..8 + b1.len()], &b1[..]);
        let off = 8 + b1.len();
        assert_eq!(&framed[off..off + 4], &2u32.to_le_bytes());
        assert_eq!(&framed[off + 4..off + 8], &(b2.len() as u32).to_le_bytes());
        assert_eq!(&framed[off + 8..], &b2[..]);
        assert_eq!(framed.len(), 8 + b1.len() + 8 + b2.len());
    }

    #[test]
    fn parse_round_trips_framing_and_keeps_unknown_types() {
        let b1 = body(b"one");
        let b2 = body(b"two");
        let unknown = b"v2 future".to_vec();
        let framed = frame_sections(&[
            (SECTION_TYPE_BIP139, &b1),
            (0x0000_00FF, &unknown),
            (SECTION_TYPE_SECRETS, &b2),
        ]);
        let parsed = parse_sections(&framed).unwrap();
        assert_eq!(
            parsed,
            vec![
                (SECTION_TYPE_BIP139, b1.clone()),
                (0x0000_00FF, unknown),
                (SECTION_TYPE_SECRETS, b2.clone()),
            ]
        );
    }

    #[test]
    fn truncated_section_rejects() {
        let b1 = body(b"one");
        let framed = frame_sections(&[(SECTION_TYPE_BIP139, &b1)]);
        // Header cut short.
        assert_eq!(parse_sections(&framed[..5]).unwrap_err(), PayloadError::TruncatedSection);
        // Body cut short.
        assert_eq!(
            parse_sections(&framed[..framed.len() - 1]).unwrap_err(),
            PayloadError::TruncatedSection
        );
        assert_eq!(parse_sections(&[]).unwrap(), vec![]);
    }

    /// A real watch-only `sp()` descriptor, built the same way the wallet
    /// API builds them (`SpKey::Scan` form).
    fn watch_only_descriptor(network: spdk_wallet::silentpayments::Network) -> String {
        let scan = spdk_wallet::bitcoin::secp256k1::SecretKey::from_slice(&[0x11; 32]).unwrap();
        let spend_pk = scan.public_key(&spdk_wallet::bitcoin::key::Secp256k1::signing_only());
        let key = bip392::SpKey::Scan(bip392::SpScanKey {
            scan_key: scan,
            spend_key: spend_pk,
            network,
        });
        bip392::Sp::from_sp_key(key).to_string()
    }

    #[test]
    fn bip139_export_validates_standalone() {
        let descriptor = watch_only_descriptor(spdk_wallet::silentpayments::Network::Mainnet);
        let export = build_bip139_export(Network::Mainnet, &descriptor, None);
        validate_bip139_export(&export).unwrap();
        let value: Value = serde_json::from_str(&export).unwrap();
        assert_eq!(value["version"], "BIP139-1");
        assert_eq!(value["network"], "bitcoin");
        assert_eq!(value["accounts"][0]["type"], "bip392");
        assert_eq!(value["accounts"][0]["descriptor"], descriptor);
    }

    #[test]
    fn scan_state_lands_in_the_export() {
        let descriptor = "sp(spscan1qqqq9untzdg64yz2nkm3s6mzga7vceh5htemskv4mu2kesvft3r5w2pskvzq4yyh6zpy3t9j2c8kkfnzp8hw52d2q73yksfez9x9efqkwsc6zvcq)";
        let state = WalletScanState {
            last_height: Some(870_000),
            bip352_labels: Some(Bip352Labels::Indices(vec![0, 1, 2])),
            coins: vec![BackupCoin {
                outpoint: "0a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20212223242526272829:0".into(),
                amount_sats: Some(21_000),
                tweak: Some([0xAB; 32]),
                sp_label: Some([0x01; 32]),
                block_height: Some(869_999),
                is_change: Some(false),
                derivation_index: Some(7),
            }],
        };
        let export = build_bip139_export(Network::Testnet3, descriptor, Some(&state));
        let value: Value = serde_json::from_str(&export).unwrap();
        assert_eq!(value["network"], "testnet3");
        let account = &value["accounts"][0];
        assert_eq!(account["last_height"], 870_000);
        assert_eq!(account["bip352_labels"], json!([0, 1, 2]));
        let coin = &account["coins"][0];
        assert_eq!(coin["outpoint"], "0a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20212223242526272829:0");
        assert_eq!(coin["tweak"], json!("ab".repeat(32)));
        assert_eq!(coin["sp_label"], json!("01".repeat(32)));
        assert_eq!(coin["amount"], 21_000);
        assert_eq!(coin["block_height"], 869_999);
        assert_eq!(coin["derivation_index"], 7);
        assert_eq!(coin["is_change"], false);
        // Optional members stay absent when unknown.
        let bare = build_bip139_export(Network::Testnet3, descriptor, Some(&WalletScanState::default()));
        let value: Value = serde_json::from_str(&bare).unwrap();
        assert!(value["accounts"][0].get("last_height").is_none());
        assert!(value["accounts"][0].get("coins").is_none());
    }

    #[test]
    fn bip139_export_validation_rejects_broken_structures() {
        let valid = build_bip139_export(
            Network::Mainnet,
            &watch_only_descriptor(spdk_wallet::silentpayments::Network::Mainnet),
            None,
        );
        validate_bip139_export(&valid).unwrap();

        let not_json = "definitely not json";
        assert_eq!(validate_bip139_export(not_json).unwrap_err(), PayloadError::NotAJsonObject);
        assert_eq!(validate_bip139_export("[1,2]").unwrap_err(), PayloadError::NotAJsonObject);

        let scan_descriptor = watch_only_descriptor(spdk_wallet::silentpayments::Network::Mainnet);
        let missing_version = json!({"network": "bitcoin", "accounts": [{"type": "bip392", "descriptor": scan_descriptor}]});
        assert_eq!(
            validate_bip139_export(&missing_version.to_string()).unwrap_err(),
            PayloadError::MissingField("version")
        );

        let bad_version = json!({"version": "BIP139", "network": "bitcoin", "accounts": [{"type": "bip392", "descriptor": "sp(spscan1qqqq9untzdg64yz2nkm3s6mzga7vceh5htemskv4mu2kesvft3r5w2pskvzq4yyh6zpy3t9j2c8kkfnzp8hw52d2q73yksfez9x9efqkwsc6zvcq)"}]});
        assert_eq!(
            validate_bip139_export(&bad_version.to_string()).unwrap_err(),
            PayloadError::InvalidField { field: "version" }
        );

        let bad_network = json!({"version": "BIP139-1", "network": "litecoin", "accounts": [{"type": "bip392", "descriptor": "sp(spscan1qqqq9untzdg64yz2nkm3s6mzga7vceh5htemskv4mu2kesvft3r5w2pskvzq4yyh6zpy3t9j2c8kkfnzp8hw52d2q73yksfez9x9efqkwsc6zvcq)"}]});
        assert_eq!(
            validate_bip139_export(&bad_network.to_string()).unwrap_err(),
            PayloadError::InvalidField { field: "network" }
        );

        let empty_accounts = json!({"version": "BIP139-1", "network": "bitcoin", "accounts": []});
        assert_eq!(
            validate_bip139_export(&empty_accounts.to_string()).unwrap_err(),
            PayloadError::InvalidField { field: "accounts" }
        );

        let missing_descriptor = json!({"version": "BIP139-1", "network": "bitcoin", "accounts": [{"type": "bip392"}]});
        assert_eq!(
            validate_bip139_export(&missing_descriptor.to_string()).unwrap_err(),
            PayloadError::MissingField("descriptor")
        );
    }

    #[test]
    fn mainnet_spend_key_in_bip139_section_is_rejected() {
        // A full `spspend` descriptor carries the spend secret — legal as a
        // descriptor, forbidden inside a mainnet BIP-139 section (D2, §5.1).
        let scan = spdk_wallet::bitcoin::secp256k1::SecretKey::from_slice(&[0x11; 32]).unwrap();
        let spend = spdk_wallet::bitcoin::secp256k1::SecretKey::from_slice(&[0x22; 32]).unwrap();
        let key = bip392::SpKey::Spend(bip392::SpSpendKey {
            scan_key: scan,
            spend_key: spend,
            network: spdk_wallet::silentpayments::Network::Mainnet,
        });
        let full_descriptor = bip392::Sp::from_sp_key(key).to_string();
        let export = build_bip139_export(Network::Mainnet, &full_descriptor, None);
        assert_eq!(
            validate_bip139_export(&export).unwrap_err(),
            PayloadError::MainnetSpendKeyInBip139
        );
        // The same descriptor is structurally fine on testnet.
        let testnet_key = bip392::SpKey::Spend(bip392::SpSpendKey {
            scan_key: scan,
            spend_key: spend,
            network: spdk_wallet::silentpayments::Network::Testnet,
        });
        let testnet_export =
            build_bip139_export(Network::Testnet3, &bip392::Sp::from_sp_key(testnet_key).to_string(), None);
        validate_bip139_export(&testnet_export).unwrap();
    }

    #[test]
    fn secrets_block_is_exactly_the_descriptor() {
        let descriptor = "sp(spspend1qqqq9untzdg64yz2nkm3s6mzga7vceh5htemskv4mu2kesvft3r5w2pskvzq4yyh6zpy3t9j2c8kkfnzp8hw52d2q73yksfez9x9efqkwsc6zvcq)";
        assert_eq!(
            build_secrets_block(descriptor),
            json!({"descriptor": descriptor}).to_string()
        );
    }

    #[test]
    fn payload_sections_in_fixed_order_companion_optional() {
        let bip139 = build_bip139_export(Network::Mainnet, "sp(spscan1qqqq9untzdg64yz2nkm3s6mzga7vceh5htemskv4mu2kesvft3r5w2pskvzq4yyh6zpy3t9j2c8kkfnzp8hw52d2q73yksfez9x9efqkwsc6zvcq)", None);
        let secrets = build_secrets_block("sp(spspend1qqqq)");
        let companion = r#"{"contacts": []}"#;

        let two_section = build_payload(&bip139, &secrets, None).unwrap();
        let parsed = parse_sections(&two_section).unwrap();
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].0, SECTION_TYPE_BIP139);
        assert_eq!(parsed[1].0, SECTION_TYPE_SECRETS);

        let three_section = build_payload(&bip139, &secrets, Some(companion)).unwrap();
        let parsed = parse_sections(&three_section).unwrap();
        assert_eq!(
            parsed.iter().map(|(t, _)| *t).collect::<Vec<_>>(),
            vec![SECTION_TYPE_BIP139, SECTION_TYPE_SECRETS, SECTION_TYPE_COMPANION]
        );
        assert_eq!(String::from_utf8(parsed[2].1.clone()).unwrap(), companion);
    }

    #[test]
    fn password_policy_is_boolean_predicates() {
        assert_eq!(validate_password("short9").unwrap_err(), PayloadError::PasswordTooShort);
        // 16 scalar values, no digit.
        assert_eq!(
            validate_password("no digits here ok").unwrap_err(),
            PayloadError::PasswordNoDigit
        );
        // Has digits but no lowercase.
        assert_eq!(
            validate_password("0123456789123456").unwrap_err(),
            PayloadError::PasswordNoLowercase
        );
        // 16+ Unicode scalar values (multibyte counts as one).
        validate_password("парольпарольпароль42").unwrap();
        validate_password("a long enough password1").unwrap();
    }

    #[test]
    fn full_payload_encrypts_and_sections_survive_the_container() {
        let bip139 = build_bip139_export(Network::Mainnet, "sp(spscan1qqqq9untzdg64yz2nkm3s6mzga7vceh5htemskv4mu2kesvft3r5w2pskvzq4yyh6zpy3t9j2c8kkfnzp8hw52d2q73yksfez9x9efqkwsc6zvcq)", None);
        let secrets = build_secrets_block("sp(spspend1qqqq)");
        let payload = build_payload(&bip139, &secrets, None).unwrap();
        let file = backup::encrypt(&payload, "container check 12").unwrap();
        let round_tripped = backup::decrypt(&file, "container check 12").unwrap();
        let parsed = parse_sections(&round_tripped).unwrap();
        assert_eq!(parsed.len(), 2);
        assert_eq!(String::from_utf8(parsed[0].1.clone()).unwrap(), bip139);
        assert_eq!(String::from_utf8(parsed[1].1.clone()).unwrap(), secrets);
    }
}
