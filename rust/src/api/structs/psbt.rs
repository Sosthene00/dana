use std::collections::HashSet;

use anyhow::{Error, Result};
use flutter_rust_bridge::frb;
use rand::{RngCore, rng};
use spdk_wallet::bitcoin::bip32::{DerivationPath, Fingerprint};
use spdk_wallet::bitcoin::consensus::encode::serialize_hex;
use spdk_wallet::bitcoin::key::{Keypair, Secp256k1};
use spdk_wallet::bitcoin::params::Params;
use spdk_wallet::bitcoin::{Address, CompressedPublicKey, ScriptBuf, TxOut};
use spdk_wallet::bitcoin::secp256k1::{PublicKey, Scalar};
use spdk_wallet::client::{FeeRate, RecipientAddress};
use spdk_wallet::psbt::crypto::dleq_generate_proof;
use spdk_wallet::psbt::roles::SignerPsbtExt;
use spdk_wallet::silentpayments;
use spdk_wallet::silentpayments::utils::common::{Raw, SILENT_PAYMENT_ADDRESS_BYTE_LEN};
use spdk_wallet::silentpayments::utils::sending::TypedSecretKey;
use spdk_wallet::updater::DiscoveredOutput;
use spdk_wallet::{
    bitcoin::{self},
    silentpayments::SilentPaymentAddress,
};

use crate::api::structs::network::Network;
use crate::api::structs::owned_output::OwnedOutput;
use crate::api::structs::recipient::Recipient;
use crate::api::structs::{amount::Amount, outpoint::OutPoint};
use crate::api::wallet::SpWallet;

pub struct Psbt(pub Vec<u8>);

impl From<spdk_wallet::psbt::core::Psbt> for Psbt {
    fn from(value: spdk_wallet::psbt::core::Psbt) -> Self {
        Self(value.serialize())
    }
}

impl From<Psbt> for spdk_wallet::psbt::core::Psbt {
    fn from(value: Psbt) -> Self {
        spdk_wallet::psbt::core::Psbt::deserialize(&value.0).unwrap()
    }
}

impl From<&Psbt> for spdk_wallet::psbt::Psbt {
    fn from(value: &Psbt) -> Self {
        spdk_wallet::psbt::Psbt::deserialize(&value.0).unwrap()
    }
}

impl Psbt {
    fn add_amounts(
        outputs: &[spdk_wallet::bitcoin::Amount],
    ) -> Result<spdk_wallet::bitcoin::Amount> {
        outputs
            .iter()
            .fold(Ok(spdk_wallet::bitcoin::Amount::ZERO), |acc, x| {
                acc.and_then(|sum| sum.checked_add(*x).ok_or_else(|| Error::msg("Overflow")))
            })
    }

    #[frb(sync)]
    pub fn get_total_outputs_amount(&self) -> Result<Amount> {
        let psbt: spdk_wallet::psbt::core::Psbt = self.into();
        let amounts: Vec<spdk_wallet::bitcoin::Amount> =
            psbt.outputs.iter().map(|o| o.amount).collect();
        Self::add_amounts(&amounts).map(|a| a.into())
    }

    #[frb(sync)]
    pub fn get_send_amount(&self, change_code: String) -> Result<Amount> {
        let psbt: spdk_wallet::psbt::core::Psbt = self.into();
        let change_sp_code = SilentPaymentAddress::try_from(change_code.as_str())?;
        let change_sp_code_bytes = change_sp_code.to_byte_array();
        let change_scan_key: &[u8] = &change_sp_code_bytes[1..34];
        let change_spend_key: &[u8] = &change_sp_code_bytes[34..];

        let amounts: Vec<_> = psbt
            .outputs
            .iter()
            .filter_map(|o| {
                if let Some(sp_info) = &o.sp_v0_info {
                    if sp_info.as_slice()[..33] == *change_scan_key
                        && sp_info.as_slice()[33..] == *change_spend_key
                    {
                        return None;
                    }
                }
                Some(o.amount)
            })
            .collect();
        Self::add_amounts(&amounts).map(|a| a.into())
    }

    #[frb(sync)]
    pub fn get_change_amount(&self, change_code: String) -> Result<Amount> {
        let psbt: spdk_wallet::psbt::core::Psbt = self.into();
        let change_sp_code = SilentPaymentAddress::try_from(change_code.as_str())?;
        let change_sp_code_bytes = change_sp_code.to_byte_array();
        let change_scan_key: &[u8] = &change_sp_code_bytes[1..34];
        let change_spend_key: &[u8] = &change_sp_code_bytes[34..];

        let amounts: Vec<_> = psbt
            .outputs
            .iter()
            .filter_map(|o| {
                if let Some(sp_info) = &o.sp_v0_info {
                    if sp_info.as_slice()[..33] == *change_scan_key
                        && sp_info.as_slice()[33..] == *change_spend_key
                    {
                        return Some(o.amount);
                    }
                }
                None
            })
            .collect();
        Self::add_amounts(&amounts).map(|a| a.into())
    }

    /// Compute the fee paid by adding up all the inputs amounts and substracting outputs
    /// Require that every input has a funding_utxo
    #[frb(sync)]
    pub fn get_fee_amount(&self) -> Result<Amount> {
        let psbt: spdk_wallet::psbt::core::Psbt = self.into();
        let inputs_amt: Vec<_> = psbt
            .inputs
            .iter()
            .map(|i| {
                if let Some(ref w) = i.witness_utxo {
                    Ok(w.value)
                } else if let Some(ref tx) = i.non_witness_utxo {
                    tx.output
                        .get(i.spent_output_index as usize)
                        .map(|o| o.value)
                        .ok_or_else(|| Error::msg("Input is spending a non existing vout"))
                } else {
                    Err(Error::msg("Missing funding utxo for input"))
                }
            })
            .collect::<Result<Vec<_>>>()?;
        let input_sum = Self::add_amounts(&inputs_amt)?;
        let output_amt: Vec<_> = psbt.outputs.iter().map(|o| o.amount).collect();
        let output_sum = Self::add_amounts(&output_amt)?;
        Ok((input_sum - output_sum).into())
    }

    #[frb(sync)]
    pub fn get_selected_utxos(&self) -> Vec<OutPoint> {
        let psbt: spdk_wallet::psbt::core::Psbt = self.into();
        psbt.inputs
            .iter()
            .map(|input| {
                bitcoin::OutPoint::new(input.previous_txid, input.spent_output_index).into()
            })
            .collect()
    }

    #[frb(sync)]
    pub fn get_recipients(&self, network: Network) -> Result<Vec<Recipient>> {
        let psbt: spdk_wallet::psbt::core::Psbt = self.into();
        let bitcoin_network: bitcoin::Network = network.into();
        let sp_network = silentpayments::Network::try_from(bitcoin_network.to_core_arg())
            .expect("Can't fail that one");
        let recipients: Result<Vec<Recipient>> = psbt
            .outputs
            .iter()
            .map(|o| -> Result<Recipient> {
                if let Some(sp_info) = &o.sp_v0_info {
                    let mut sp_info_array = [0u8; SILENT_PAYMENT_ADDRESS_BYTE_LEN];
                    if sp_info.len() != SILENT_PAYMENT_ADDRESS_BYTE_LEN - 1 {
                        return Err(Error::msg("Invalid SP info length"));
                    }
                    sp_info_array[1..].copy_from_slice(sp_info.as_slice());
                    Ok(Recipient {
                        payment_code: SilentPaymentAddress::try_from_byte_array(
                            &sp_info_array,
                            sp_network,
                        )?
                        .to_string(),
                        amount: o.amount.into(),
                    })
                } else if !o.script_pubkey.is_empty() {
                    let address =
                        Address::from_script(&o.script_pubkey, Params::from(bitcoin_network))?;
                    Ok(Recipient {
                        payment_code: address.to_string(),
                        amount: o.amount.into(),
                    })
                } else {
                    Err(Error::msg("Invalid output state"))
                }
            })
            .collect();
        Ok(recipients?)
    }

    #[frb(sync)]
    pub fn create_new_transaction(
        wallet: SpWallet,
        owned_outputs: Vec<OwnedOutput>,
        api_recipients: Vec<Recipient>,
        feerate: f32,
        network: Network,
    ) -> Result<Psbt> {
        let client = wallet.get_client();
        let available_utxos: Result<Vec<(bitcoin::OutPoint, DiscoveredOutput)>> = owned_outputs
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
        wallet: SpWallet,
        owned_outputs: Vec<OwnedOutput>,
        wipe_address: String,
        feerate: f32,
        network: Network,
    ) -> Result<Psbt> {
        let client = wallet.get_client();
        let available_utxos: Result<Vec<(bitcoin::OutPoint, DiscoveredOutput)>> = owned_outputs
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

        let recipient_address = RecipientAddress::try_from(wipe_address)?;
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
    pub fn fill_up_inputs(&self, wallet: SpWallet, owned_outputs: Vec<OwnedOutput>) -> Result<Psbt> {
        let selected_utxos: HashSet<crate::api::structs::outpoint::OutPoint> = self
            .get_selected_utxos()
            .into_iter()
            .map(|o| o.into())
            .collect();

        let selected_outputs: Vec<OwnedOutput> = owned_outputs
            .into_iter()
            .filter(|o| selected_utxos.contains(&o.outpoint))
            .collect();

        let mut psbt: spdk_wallet::psbt::core::Psbt = self.into();
        let outputs_scan_keys: Vec<PublicKey> = psbt
            .outputs
            .iter()
            .filter_map(|o| o.sp_v0_info.as_ref())
            .map(|sp_info| {
                if sp_info.len() != 66 {
                    return Err(anyhow::Error::msg("Invalid SP info length"));
                };
                let scan_key_bytes = sp_info.as_slice().get(..33).unwrap();
                PublicKey::from_slice(scan_key_bytes).map_err(|e| {
                    anyhow::Error::msg(format!("Invalid scan public key in output: {}", e))
                })
            })
            .collect::<Result<Vec<PublicKey>>>()?;
        let secp = Secp256k1::new();
        let mut rng = rng();
        let client = wallet.get_client();
        let sp_spend_key =
            Keypair::from_secret_key(&secp, &client.get_spend_key().try_into()?);
        let compressed_sp_spend_key = CompressedPublicKey(sp_spend_key.public_key());
        let fingerprint = if let Some(fingerprint) = wallet.get_fingerprint() {
            fingerprint.into()
        } else {
            // just put a zero fingerprint
            Fingerprint::from([0u8; 4])
        };
        let derivation_path = if let Some(derivation_path) = wallet.get_derivation_path() {
            derivation_path.into()
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
    pub fn aggregate_ecdh_shares(&self) -> Result<Psbt> {
        let mut psbt: spdk_wallet::psbt::core::Psbt = self.into();
        let secp = Secp256k1::new();
        psbt.aggregate_ecdh_shares(&secp)?;
        Ok((psbt.into()))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn fill_up_outputs_key(&self) -> Result<Psbt> {
        let mut psbt: spdk_wallet::psbt::core::Psbt = self.into();
        let secp = Secp256k1::new();
        let outputs = psbt.compute_sp_outputs(&secp)?;
        psbt.set_sp_scriptpubkey(outputs)?;
        Ok((psbt.into()))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn sign_transaction(&self, wallet: SpWallet) -> Result<Psbt> {
        let psbt: spdk_wallet::psbt::core::Psbt = self.into();
        let signed_psbt = wallet.get_client().sign_transaction(psbt)?;
        Ok(signed_psbt.into())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn finalize_transaction(&self) -> Result<Psbt> {
        let mut psbt: spdk_wallet::psbt::core::Psbt = self.into();
        psbt.finalize()?;
        Ok(psbt.into())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn extract_tx(&self) -> Result<String> {
        let psbt: spdk_wallet::psbt::core::Psbt = self.into();
        let tx = psbt.extract_tx()?;
        Ok(serialize_hex(&tx))
    }
}
