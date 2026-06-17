use std::collections::HashSet;

use anyhow::{Error, Result};
use flutter_rust_bridge::frb;
use rand::{RngCore, rng};
use spdk_wallet::{DATA_CARRIER_SIZE, silentpayments};
use spdk_wallet::bitcoin::bip32::{DerivationPath, Fingerprint};
use spdk_wallet::bitcoin::consensus::encode::serialize_hex;
use spdk_wallet::bitcoin::key::{Keypair, Secp256k1};
use spdk_wallet::bitcoin::params::Params;
use spdk_wallet::bitcoin::script::PushBytesBuf;
use spdk_wallet::bitcoin::{Address, CompressedPublicKey, ScriptBuf, TxOut};
use spdk_wallet::bitcoin::secp256k1::{PublicKey, Scalar};
use spdk_wallet::client::RecipientAddress;
use spdk_wallet::psbt::core::Output;
use spdk_wallet::psbt::core::utils::to_psbt_dleq;
use spdk_wallet::psbt::{self, generate_dleq_proof};
use spdk_wallet::psbt::roles::{ConstructorPsbtExt, ExtractorPsbtExt, InputWitnessFinalizerPsbtExt, SignerPsbtExt};
use spdk_wallet::silentpayments::utils::common::{Raw, SILENT_PAYMENT_ADDRESS_BYTE_LEN};
use spdk_wallet::silentpayments::utils::sending::TypedSecretKey;
use spdk_wallet::{
    bitcoin::{self},
    silentpayments::SilentPaymentAddress,
};

use crate::api::structs::network::Network;
use crate::drain_change_split::random_split_sats;
use crate::api::structs::owned_output::OwnedOutput;
use crate::api::structs::recipient::Recipient;
use crate::api::structs::{
    amount::Amount, input_selection::InputSelection, outpoint::OutPoint,
};
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

    fn recipients_to_outputs(recipients: Vec<Recipient>, network: Network) -> Result<Vec<Output>> {
        let recipients: Vec<spdk_wallet::client::Recipient> = recipients
            .into_iter()
            .map(|r| r.try_into().unwrap())
            .collect();

        let address_sp_network = match network {
            Network::Mainnet => silentpayments::Network::Mainnet,
            Network::Testnet3 | Network::Testnet4 | Network::Signet => silentpayments::Network::Testnet,
            Network::Regtest => silentpayments::Network::Regtest,
        };

        let network: bitcoin::Network = network.into();
        let outputs: Vec<Output> = recipients
            .iter()
            .map(|recipient| match &recipient.address {
                RecipientAddress::LegacyAddress(unchecked_address) => {
                    let amount = recipient.amount;
                    let script_pubkey = unchecked_address
                        .clone()
                        .require_network(network.into())?
                        .script_pubkey();

                    let output = Output {
                        script_pubkey,
                        amount,
                        ..Default::default()
                    };

                    Ok(output)
                }
                RecipientAddress::SpAddress(sp_address) => {
                    let amount = recipient.amount;
                    if sp_address.get_network() != address_sp_network {
                        return Err(Error::msg(format!(
                            "Wrong network for address {}",
                            sp_address
                        )));
                    }

                    let mut sp_v0_info = [0u8; 66];
                    sp_v0_info.copy_from_slice(&sp_address.to_byte_array()[1..]);

                    let output = Output {
                        sp_v0_info: Some(sp_v0_info),
                        amount,
                        ..Default::default()
                    };

                    Ok(output)
                }
                RecipientAddress::Data(data) => {
                    let amount = recipient.amount;
                    let data_len = data.len();
                    if amount > spdk_wallet::bitcoin::Amount::ZERO {
                        Err(Error::msg("Data output must have an amount of 0!"))
                    } else if data_len > DATA_CARRIER_SIZE {
                        Err(Error::msg(format!(
                            "Can't embed data of length {}. Max length: {}",
                            data_len, DATA_CARRIER_SIZE
                        )))
                    } else if data_len == 0 {
                        Err(Error::msg(format!(
                            "No data to embed"
                        ))) 
                    } else {
                        let mut op_return = PushBytesBuf::with_capacity(data_len);
                        op_return.extend_from_slice(data)?;
                        let script_pubkey = ScriptBuf::new_op_return(op_return);

                        let output = Output {
                            script_pubkey,
                            amount,
                            ..Default::default()
                        };

                        Ok(output)
                    }
                }
            })
            .collect::<Result<Vec<_>>>()?;

        Ok(outputs)
    }

    #[frb(sync)]
    pub fn create_new_transaction(
        recipients: Vec<Recipient>,
        network: Network,
    ) -> Result<Self> {
        let outputs = Self::recipients_to_outputs(recipients, network)?;
        Ok(psbt::Psbt::create_new_transaction(outputs)?.into())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn add_inputs(&self, input_selection: InputSelection) -> Result<Psbt> {
        let input_selection: spdk_wallet::client::InputSelection = input_selection.into();
        let psbt: spdk_wallet::psbt::core::Psbt = self.into();
        let new_psbt = psbt.add_inputs(input_selection.selected_utxos)?;
        Ok(new_psbt.into())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn add_change(&self, input_selection: InputSelection, change_address: String) -> Result<Psbt> {
        let input_selection: spdk_wallet::client::InputSelection = input_selection.into();
        let mut psbt: spdk_wallet::psbt::core::Psbt = self.into();

        let new_psbt: spdk_wallet::psbt::core::Psbt;

        // If we are draining, spread the change amount over the outputs with randomized amounts.
        if input_selection.strategy == spdk_wallet::client::Strategy::Drain {
            let change = input_selection.change;
            if change.to_sat() == 0 {
                return Err(Error::msg("Cannot drain with zero change (inputs consumed by fees)"));
            }
            if input_selection.n_change_outputs != psbt.outputs.len() {
                return Err(Error::msg("Number of change outputs mismatch"));
            }
            let splits = random_split_sats(change.to_sat(), input_selection.n_change_outputs)?;
            for (output, sat) in psbt.outputs.iter_mut().zip(splits) { // we ignore whatever amounts we wrote here before
                output.amount = bitcoin::Amount::from_sat(sat);
            }
            new_psbt = psbt;
        } else {
            let change = input_selection.change;
            // Changeless selections still request n_change_outputs from the UI, but
            // must not add a zero-value output: PSBT decode rejects Amount::ZERO outputs.
            // n_change_outputs should be set to 0 in case of changeless selection, but we play it safe
            if change.to_sat() == 0 || input_selection.n_change_outputs == 0 {
                new_psbt = psbt;
            } else {
                let splits = random_split_sats(change.to_sat(), input_selection.n_change_outputs)?;
                let change_keys: [u8; 66] =
                    SilentPaymentAddress::try_from(change_address.as_str())?.to_byte_array()[1..]
                        .try_into()
                        .unwrap();
                let mut outputs = Vec::with_capacity(input_selection.n_change_outputs);
                for split in splits {
                    outputs.push(Output {
                        amount: bitcoin::Amount::from_sat(split),
                        sp_v0_info: Some(change_keys),
                        sp_v0_label: Some(0),
                        ..Default::default()
                    });
                }
                new_psbt = psbt.add_outputs(outputs)?;
            }
        }

        Ok(new_psbt.into())
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
                    
                    let dleq_proof = generate_dleq_proof(
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
                        .insert(CompressedPublicKey(*scan_key), to_psbt_dleq(dleq_proof));
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
