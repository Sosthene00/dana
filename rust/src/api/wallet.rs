pub mod challenge;
pub mod coin_selection;
mod info;
pub mod setup;
mod sync;
mod transaction;

use crate::{api::structs::network::Network, wallet::WalletFingerprint};
use anyhow::{anyhow, Result};
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

    /// Signs a nameserver registration challenge attestation with the
    /// wallet's own spend secret (BIP-340 schnorr, SHA-256-prehashed,
    /// spec v1 grammar enforced inside the shared core, and the message
    /// network_key cross-checked against this wallet's pinned per-network
    /// constant (D7) before anything is signed). The secret
    /// never crosses the FFI boundary: Dart passes the message string in
    /// and receives only the 64-byte signature hex.
    ///
    /// `SpendKey`->`SecretKey` route: the direct public accessor
    /// `SpClient::try_secret_spend_key` (pinned spdk c1262f0,
    /// spdk-wallet/src/client/client.rs:71) — it clones the held key and
    /// errors on watch-only (`SpendKey::Public`) wallets, so the
    /// base64/hex re-import fallback via `ApiSpendKey::encode` was not
    /// Signs through the shared `challenge::sign_challenge_inner` core with
    /// fresh per-call BIP-340 auxiliary random data (D9: uniform random,
    /// constant zero-array fallback when no RNG is available).
    #[frb(sync)]
    pub fn sign_registration_challenge(&self, message: String) -> Result<String> {
        // Grammar first (spec section 3): a message outside the v1 grammar
        // never reaches the signer. Then the per-network binding (D7): the
        // network_key inside the message must equal this wallet's own pinned
        // client constant - any mismatch fails closed before signing.
        let expected = match self.client.network() {
            spdk_wallet::bitcoin::Network::Bitcoin => challenge::NETWORK_KEY_MAINNET,
            spdk_wallet::bitcoin::Network::Testnet
            | spdk_wallet::bitcoin::Network::Testnet4
            | spdk_wallet::bitcoin::Network::Signet => challenge::NETWORK_KEY_TESTNET,
            spdk_wallet::bitcoin::Network::Regtest => {
                return Err(anyhow!(
                    "regtest wallets have no challenge-auth network_key constant; refusing to sign"
                ));
            }
        };
        if challenge::challenge_network_key(&message)? != expected {
            return Err(anyhow!(
                "challenge network_key does not match this wallet's network constant \
                 '{expected}'; refusing to sign (D7)"
            ));
        }
        // INV-3/D4: this is the only signing entry point on the FFI
        // surface. A watch-only wallet has no spend secret and must error
        // clearly, never succeed silently.
        let sk = self.client.try_secret_spend_key().map_err(|_| {
            anyhow!(
                "watch-only wallet has no spend secret; refusing to sign the registration challenge"
            )
        })?;
        // D9: fresh uniform-random aux per signing call (zero-array fallback
        // when no RNG is available).
        let sig = challenge::sign_challenge_inner(&sk, &message, &challenge::fresh_aux_rand())?;
        Ok(sig.serialize().iter().map(|b| format!("{b:02x}")).collect())
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
