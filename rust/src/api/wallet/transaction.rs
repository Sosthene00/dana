use std::collections::HashSet;

use crate::api::structs::network::Network;
use crate::api::structs::owned_output::OwnedOutput;
use crate::api::structs::psbt::Psbt;
use crate::api::structs::recipient::Recipient;
use crate::api::structs::unsigned_transaction::SilentPaymentUnsignedTransaction;

use anyhow::Result;
use bip39::rand::{thread_rng, RngCore};
use spdk_wallet::backend_blindbit_v1::BlindbitClient;
use spdk_wallet::bitcoin::bip32::{DerivationPath, Fingerprint};
use spdk_wallet::bitcoin::key::{Keypair, Secp256k1};
use spdk_wallet::bitcoin::secp256k1::{PublicKey, Scalar};
use spdk_wallet::bitcoin::{consensus::serialize, hex::DisplayHex, OutPoint};
use spdk_wallet::bitcoin::{CompressedPublicKey, ScriptBuf, TxOut};
use spdk_wallet::client::{FeeRate, RecipientAddress};
use spdk_wallet::psbt::crypto::dleq::dleq_generate_proof;
use spdk_wallet::psbt::roles::Bip375OutputConstructorExt;
use spdk_wallet::silentpayments::utils::common::Raw;
use spdk_wallet::silentpayments::utils::sending::TypedSecretKey;
use spdk_wallet::updater::DiscoveredOutput;

use super::SpWallet;

impl SpWallet {
    #[flutter_rust_bridge::frb(sync)]
    pub fn create_new_transaction(
        &self,
        owned_outputs: Vec<OwnedOutput>,
        api_recipients: Vec<Recipient>,
        feerate: f32,
        network: Network,
    ) -> Result<Psbt> {
        let client = &self.client;
        let available_utxos: Result<Vec<(OutPoint, DiscoveredOutput)>> = owned_outputs
            .into_iter()
            .map(|output| {
                let outpoint = output.outpoint.into();
                let label = match output.label {
                    Some(l) => Some(Scalar::from_be_bytes(l)?.into()),
                    None => None,
                };
                let output = DiscoveredOutput {
                    tweak: Scalar::from_be_bytes(output.tweak)?,
                    value: output.amount.into(),
                    script_pubkey: ScriptBuf::from_bytes(output.script),
                    label,
                };
                Ok((outpoint, output))
            })
            .collect();
        let recipients: Vec<spdk_wallet::client::Recipient> = api_recipients
            .into_iter()
            .map(|r| r.try_into().unwrap())
            .collect();
        let res = client.create_new_transaction(
            available_utxos?,
            recipients,
            FeeRate::from_sat_per_vb(feerate),
            network.into(),
        )?;

        Ok(res.into())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn create_drain_transaction(
        &self,
        owned_outputs: Vec<OwnedOutput>,
        wipe_address: String,
        feerate: f32,
        network: Network,
    ) -> Result<Psbt> {
        let client = &self.client;
        let available_utxos: Result<Vec<(OutPoint, DiscoveredOutput)>> = owned_outputs
            .into_iter()
            .map(|output| {
                let outpoint = output.outpoint.into();
                let label = match output.label {
                    Some(l) => Some(Scalar::from_be_bytes(l)?.into()),
                    None => None,
                };
                let output = DiscoveredOutput {
                    tweak: Scalar::from_be_bytes(output.tweak)?,
                    value: output.amount.into(),
                    script_pubkey: ScriptBuf::from_bytes(output.script),
                    label,
                };
                Ok((outpoint, output))
            })
            .collect();

        let recipient_address: RecipientAddress = RecipientAddress::try_from(wipe_address)?;
        let res = client.create_drain_transaction(
            available_utxos?,
            recipient_address,
            FeeRate::from_sat_per_vb(feerate),
            network.into(),
        )?;

        Ok(res.into())
    }

    /// Fill in data for our inputs:
    /// - Funding utxo
    /// - bip32 derivation
    /// - tweak
    /// - ecdh shares
    #[flutter_rust_bridge::frb(sync)]
    pub fn fill_up_inputs(&self, psbt: Psbt, owned_outputs: Vec<OwnedOutput>) -> Result<Psbt> {
        let selected_utxos: HashSet<crate::api::structs::outpoint::OutPoint> = psbt
            .get_selected_utxos()?
            .into_iter()
            .map(|o| o.into())
            .collect();

        let selected_outputs: Vec<OwnedOutput> = owned_outputs
            .into_iter()
            .filter(|o| selected_utxos.contains(&o.outpoint))
            .collect();

        let mut psbt: spdk_wallet::psbt::core::Psbt = psbt.into();
        let outputs_scan_keys: Vec<PublicKey> = psbt
            .outputs
            .iter()
            .filter_map(|o| {
                if let Some((scan_key, _spend_key)) = o.get_sp_info() {
                    Some(scan_key)
                } else {
                    None
                }
            })
            .collect();
        let secp = Secp256k1::new();
        let mut rng = thread_rng();
        let sp_spend_key =
            Keypair::from_secret_key(&secp, &self.client.get_spend_key().try_into()?);
        let compressed_sp_spend_key = CompressedPublicKey(sp_spend_key.public_key());
        let fingerprint = if let Some(fingerprint) = self.fingerprint {
            fingerprint
        } else {
            // just put a zero fingerprint
            Fingerprint::from([0u8; 4])
        };
        let derivation_path = if let Some(derivation_path) = &self.derivation_path {
            derivation_path.clone()
        } else {
            // just put a master derivation path
            DerivationPath::master()
        };
        for output in selected_outputs {
            // Find the input that spend this output
            let input = psbt.inputs.iter_mut().find(|i| {
                i.previous_txid.to_string() == output.outpoint.txid
                    && i.spent_output_index == output.outpoint.vout
            });
            if let Some(input) = input {
                // Compute the tweaked key and check that it matched the spend key
                let tweaked_key = sp_spend_key
                    .secret_key()
                    .add_tweak(&Scalar::from_be_bytes(output.tweak)?)?;

                if tweaked_key.x_only_public_key(&secp).0.serialize() != output.script[2..] {
                    return Err(anyhow::Error::msg(format!(
                        "Tweaked key mismatch for input {}:{}",
                        input.previous_txid, input.spent_output_index
                    )));
                }

                if input.sp_tweak.is_none() {
                    input.sp_tweak = Some(output.tweak);
                } else {
                    if input.sp_tweak.unwrap() != output.tweak {
                        return Err(anyhow::Error::msg(format!(
                            "Tweaked key mismatch for input {}:{}",
                            input.previous_txid, input.spent_output_index
                        )));
                    }
                }

                if !input
                    .sp_spend_bip32_derivations
                    .contains_key(&compressed_sp_spend_key)
                {
                    input.sp_spend_bip32_derivations.insert(
                        compressed_sp_spend_key,
                        (fingerprint, derivation_path.clone()),
                    );
                } else {
                    if let Some((f, dp)) = input
                        .sp_spend_bip32_derivations
                        .get(&compressed_sp_spend_key)
                    {
                        if *f != fingerprint || *dp != derivation_path {
                            return Err(anyhow::Error::msg(format!(
                                "Bip32 derivation mismatch for input {}:{}",
                                input.previous_txid, input.spent_output_index
                            )));
                        }
                    }
                }

                let txout = TxOut {
                    value: output.amount.into(),
                    script_pubkey: ScriptBuf::from_bytes(output.script),
                };

                // compute the ecdh share and DLEQ proof for each sp address in outputs
                for scan_key in &outputs_scan_keys {
                    let normalized_key = TypedSecretKey::<Raw>::new(tweaked_key)
                        .normalize_for_input(&secp, txout.script_pubkey.is_p2tr());
                    let shared_secret = normalized_key.calculate_ecdh_shared_secret(&scan_key);
                    input.sp_ecdh_shares.insert(
                        CompressedPublicKey(*scan_key),
                        CompressedPublicKey(shared_secret.into_inner()),
                    );

                    let mut aux_rand = [0u8; 32];
                    rng.fill_bytes(&mut aux_rand);
                    let dleq_proof = dleq_generate_proof(
                        &secp,
                        normalized_key.as_inner(),
                        scan_key,
                        &aux_rand,
                        None,
                    )
                    .map_err(|e| {
                        anyhow::Error::msg(format!("DLEQ proof generation failed: {}", e))
                    })?;
                    input
                        .sp_dleq_proofs
                        .insert(CompressedPublicKey(*scan_key), dleq_proof);
                }

                // Then check that we don't have already filled the funding utxo
                if let Ok(funding_utxo) = input.funding_utxo() {
                    if *funding_utxo == txout {
                        continue;
                    } else {
                        return Err(anyhow::Error::msg(format!(
                            "Funding utxo mismatch for input {}:{}",
                            input.previous_txid, input.spent_output_index
                        )));
                    }
                } else {
                    input.witness_utxo = Some(txout);
                }
            } else {
                // Very unlikely
                return Err(anyhow::Error::msg(format!(
                    "Input not found for output {}:{}",
                    output.outpoint.txid, output.outpoint.vout
                )));
            }
        }

        Ok(psbt.into())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn sign_transaction(
        &self,
        unsigned_transaction: SilentPaymentUnsignedTransaction,
    ) -> Result<String> {
        let mut aux_rand = [0u8; 32];

        let mut rng = thread_rng();
        rng.fill_bytes(&mut aux_rand);

        let client = &self.client;
        let tx = client.sign_transaction(unsigned_transaction.into(), &aux_rand)?;
        Ok(serialize(&tx).to_lower_hex_string())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn finalize_transaction(psbt: Psbt) -> Result<Psbt> {
        // let res = SpClient::finalize_transaction(psbt.into())?;
        // Ok(res.into())
        Ok(psbt)
    }

    // note: should only be used when using regtest, else there is privacy loss!
    pub async fn broadcast_using_blindbit(blindbit_url: String, tx: String) -> Result<String> {
        let blindbit_client = BlindbitClient::new(&blindbit_url)?;

        let res = blindbit_client.forward_tx(tx).await?;

        Ok(res.to_string())
    }

    pub async fn broadcast_tx(tx: String, network: Network) -> Result<String> {
        let tx: pushtx::Transaction = tx.parse().unwrap();

        let txid = tx.txid();

        let network = match network {
            Network::Mainnet => pushtx::Network::Mainnet,
            Network::Testnet3 => pushtx::Network::Testnet,
            Network::Testnet4 => pushtx::Network::Testnet,
            Network::Signet => pushtx::Network::Signet,
            Network::Regtest => pushtx::Network::Regtest,
        };

        let opts = pushtx::Opts {
            network,
            ..Default::default()
        };

        tokio::task::spawn_blocking(move || {
            let receiver = pushtx::broadcast(vec![tx], opts);

            loop {
                match receiver.recv() {
                    Ok(pushtx::Info::Done(Ok(report))) => {
                        if report.success.len() > 0 {
                            log::info!("broadcasted {} transactions", report.success.len());
                            break;
                        } else {
                            return Err(anyhow::Error::msg("Failed to broadcast transaction, probably unable to connect to Tor peers"));
                        }
                    }
                    Ok(pushtx::Info::Done(Err(err))) => return Err(anyhow::Error::msg(err.to_string())),
                    Ok(_) => {} // Continue for other Info variants
                    Err(recv_err) => {
                        log::error!("Channel recv error: {:?}", recv_err);
                        return Err(anyhow::Error::msg(format!(
                            "Channel closed unexpectedly while waiting for broadcast result: {:?}", 
                            recv_err
                        )));
                    }
                }
            }
            Ok(())
        })
        .await??;

        Ok(txid.to_string())
    }
}
