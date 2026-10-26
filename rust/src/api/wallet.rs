pub mod challenge;
mod info;
pub mod setup;
mod sync;
mod transaction;

use crate::{api::structs::network::Network, wallet::WalletFingerprint};
use anyhow::Result;
use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};
use spdk_wallet::bitcoin::secp256k1::SecretKey;
use spdk_wallet::client::{SpClient, SpendKey};

#[derive(Debug, Clone)]
#[frb(opaque)]
pub struct SpWallet {
    client: SpClient,
    #[allow(unused)]
    wallet_fingerprint: WalletFingerprint,
}

impl SpWallet {
    #[frb(sync)]
    pub fn new(scan_key: ApiScanKey, spend_key: ApiSpendKey, network: Network) -> Result<Self> {
        let client = SpClient::new(scan_key.into(), spend_key.into(), network.into())?;

        let wallet_fingerprint = client.client_fingerprint()?;

        Ok(Self {
            client,
            wallet_fingerprint,
        })
    }

    #[frb(sync)]
    pub fn get_scan_key(&self) -> ApiScanKey {
        ApiScanKey(self.client.scan_key())
    }

    #[frb(sync)]
    pub fn get_spend_key(&self) -> ApiSpendKey {
        ApiSpendKey(self.client.spend_key())
    }

    /// Signs a name-server registration challenge attestation with the
    /// wallet's own spend secret (BIP-340 schnorr over the SHA-256 digest,
    /// `CHALLENGE_PREFIX` enforced inside the shared core). The secret
    /// never crosses the FFI boundary: Dart passes the message string in
    /// and receives only the 64-byte signature hex.
    ///
    /// `SpendKey`->`SecretKey` route: `SpClient::try_secret_spend_key`
    /// (pinned spdk c1262f0, spdk-wallet/src/client/client.rs:72) clones the
    /// held key and errors on watch-only (`SpendKey::Public`) wallets.
    /// This is the only `#[frb]`-marked challenge signer: the spend secret
    /// stays inside Rust and only the signature hex is returned. It shares
    /// the `challenge::sign_challenge_inner` core *and* the `challenge::to_hex`
    /// rendering used by the crate-internal `challenge::sign_challenge`
    /// helper, so signatures and their hex encoding are byte-identical by
    /// construction.
    #[frb(sync)]
    pub fn sign_registration_challenge(&self, message: String) -> Result<String> {
        let sk = self.client.try_secret_spend_key()?;
        let sig = challenge::sign_challenge_inner(&sk, &message)?;
        Ok(challenge::to_hex(&sig.serialize()))
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct ApiScanKey(pub(crate) SecretKey);

impl ApiScanKey {
    #[frb(sync)]
    pub fn decode(encoded: String) -> Result<Self> {
        Ok(serde_json::from_str(&encoded)?)
    }

    #[frb(sync)]
    pub fn encode(&self) -> Result<String> {
        Ok(serde_json::to_string(&self)?)
    }
}

impl From<ApiScanKey> for SecretKey {
    fn from(scan_key: ApiScanKey) -> Self {
        scan_key.0
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct ApiSpendKey(pub(crate) SpendKey);

impl ApiSpendKey {
    #[frb(sync)]
    pub fn decode(encoded: String) -> Result<Self> {
        Ok(serde_json::from_str(&encoded)?)
    }

    #[frb(sync)]
    pub fn encode(&self) -> Result<String> {
        Ok(serde_json::to_string(&self)?)
    }
}

impl From<ApiSpendKey> for SpendKey {
    fn from(spend_key: ApiSpendKey) -> Self {
        spend_key.0
    }
}
