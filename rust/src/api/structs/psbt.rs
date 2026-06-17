use std::collections::{HashMap, HashSet};

use anyhow::{Error, Result};
use flutter_rust_bridge::frb;
use rand::{RngCore, rng};
use spdk_wallet::{DATA_CARRIER_SIZE, silentpayments};
use spdk_wallet::bitcoin::bip32::{DerivationPath, Fingerprint};
use spdk_wallet::bitcoin::consensus::encode::serialize_hex;
use spdk_wallet::bitcoin::key::{Keypair, Parity, Secp256k1};
use spdk_wallet::bitcoin::params::Params;
use spdk_wallet::bitcoin::script::PushBytesBuf;
use spdk_wallet::bitcoin::{Address, CompressedPublicKey, ScriptBuf, TxOut, XOnlyPublicKey};
use spdk_wallet::bitcoin::secp256k1::{PublicKey, Scalar};
use spdk_wallet::client::RecipientAddress;
use spdk_wallet::psbt::core::utils::{to_psbt_dleq, to_rust_dleq};
use spdk_wallet::psbt::core::Output;
use spdk_wallet::psbt::{self};
use spdk_wallet::psbt::roles::signer::extract_eligible_input_pubkey;
use spdk_wallet::psbt::roles::{ConstructorPsbtExt, ExtractorPsbtExt, InputWitnessFinalizerPsbtExt, SignerPsbtExt};
use spdk_wallet::silentpayments::sending::generate_recipient_pubkeys;
use spdk_wallet::silentpayments::utils::sending::{NormalizedSecretKey, PartialSenderEcdhShare};
use spdk_wallet::silentpayments::utils::OutPoint as SpOutPoint;
use spdk_wallet::silentpayments::{
    NonEmptyArray, TransactionInputs, TransactionSharedSecret, SILENT_PAYMENT_ADDRESS_BYTE_LEN,
};
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

/// For SP P2TR inputs, BIP-352 ECDH uses the tweaked output key from the funding script.
/// `sp_spend_bip32_derivations` still carries the untweaked spend key for signing.
fn extract_ecdh_input_pubkey(
    input: &spdk_wallet::psbt::core::Input,
) -> Result<Option<PublicKey>> {
    let funding_utxo = input
        .funding_utxo()
        .map_err(|_| Error::msg("Input missing funding utxo"))?;

    if funding_utxo.script_pubkey.is_p2tr() && input.sp_tweak.is_some() {
        let taproot_output_key =
            XOnlyPublicKey::from_slice(&funding_utxo.script_pubkey.as_bytes()[2..])?;
        Ok(Some(PublicKey::from_x_only_public_key(
            taproot_output_key,
            Parity::Even,
        )))
    } else {
        extract_eligible_input_pubkey(input).map_err(|e| Error::msg(e.to_string()))
    }
}

fn collect_output_scan_keys(psbt: &spdk_wallet::psbt::core::Psbt) -> Result<Vec<CompressedPublicKey>> {
    psbt.outputs
        .iter()
        .filter_map(|o| o.sp_v0_info.as_ref())
        .map(|sp_info| {
            if sp_info.len() != 66 {
                return Err(Error::msg("Invalid SP info length"));
            }
            CompressedPublicKey::from_slice(&sp_info.as_slice()[..33])
                .map_err(|e| Error::msg(format!("Invalid scan public key in output: {}", e)))
        })
        .collect()
}

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
    /// - per-input ECDH shares and DLEQ proofs
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
        let outputs_scan_keys: Vec<PublicKey> = collect_output_scan_keys(&psbt)?
            .into_iter()
            .map(|k| k.0)
            .collect();
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
            let input_index = psbt
                .inputs
                .iter()
                .position(|i| {
                    i.previous_txid.to_string() == output.outpoint.txid
                        && i.spent_output_index == output.outpoint.vout
                })
                .ok_or_else(|| {
                    Error::msg(format!(
                        "Input not found for output {}:{}",
                        output.outpoint.txid, output.outpoint.vout
                    ))
                })?;
            let input = &mut psbt.inputs[input_index];
            // Compute the tweaked key and check that it matched the spend key
            let tweaked_key = sp_spend_key
                .secret_key()
                .add_tweak(&Scalar::from_be_bytes(output.tweak)?)?;

            let normalized_key = NormalizedSecretKey::new(&secp, tweaked_key, true);

            if normalized_key.as_inner().x_only_public_key(&secp).0.serialize() != output.script[2..] {
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

            for scan_key in &outputs_scan_keys {
                let mut aux_rand = [0u8; 32];
                rng.fill_bytes(&mut aux_rand);
                let partial_share = PartialSenderEcdhShare::new(
                    &secp,
                    *scan_key,
                    input_index,
                    normalized_key.clone(),
                    &aux_rand,
                )
                .map_err(|e| Error::msg(format!("ECDH share generation failed: {}", e)))?;
                input.sp_ecdh_shares.insert(
                    CompressedPublicKey(*scan_key),
                    CompressedPublicKey(*partial_share.as_ecdh_shared_secret()),
                );
                input.sp_dleq_proofs.insert(
                    CompressedPublicKey(*scan_key),
                    to_psbt_dleq(*partial_share.dleq_proof()),
                );
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
        }

        Ok(psbt.into())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn fill_up_outputs_key(&self) -> Result<Psbt> {
        let mut psbt: spdk_wallet::psbt::core::Psbt = self.into();
        let secp = Secp256k1::new();
        let scan_keys = collect_output_scan_keys(&psbt)?;
        if scan_keys.is_empty() {
            return Ok(psbt.into());
        }

        let mut sp_addresses_bytes: Vec<Option<[u8; SILENT_PAYMENT_ADDRESS_BYTE_LEN]>> =
            Vec::with_capacity(psbt.global.output_count);
        for output in psbt.outputs.iter() {
            let Some(sp_info) = output.sp_v0_info.as_ref() else {
                sp_addresses_bytes.push(None);
                continue;
            };
            if sp_info.len() != 66 {
                return Err(Error::msg("Invalid SP info length"));
            }
            let mut sp_address_bytes = [0u8; SILENT_PAYMENT_ADDRESS_BYTE_LEN];
            sp_address_bytes[1..].copy_from_slice(sp_info.as_slice());
            sp_addresses_bytes.push(Some(sp_address_bytes));
        }

        let mut transaction_inputs = TransactionInputs::with_capacity(psbt.global.input_count);
        for input in psbt.inputs.iter() {
            let outpoint = SpOutPoint::from_txid_and_vout(
                input.previous_txid.to_string(),
                input.spent_output_index,
            )
            .map_err(|e| Error::msg(e.to_string()))?;
            let spk = &input
                .funding_utxo()
                .map_err(|e| Error::msg(e.to_string()))?
                .script_pubkey;
            let pubkey = extract_ecdh_input_pubkey(input)?;
            transaction_inputs.push(outpoint, spk.to_bytes(), pubkey);
        }
        let eligible_vins = transaction_inputs.eligible_vins();

        let mut scan_key_to_shared_secret: HashMap<PublicKey, TransactionSharedSecret> =
            HashMap::with_capacity(scan_keys.len());
        for scan_key in &scan_keys {
            let mut partial_shares = Vec::with_capacity(psbt.global.input_count);
            for (vin, input) in psbt.inputs.iter().enumerate() {
                if !eligible_vins.contains(&vin) {
                    continue;
                }
                let shared_secret = input.sp_ecdh_shares.get(scan_key).ok_or_else(|| {
                    Error::msg(format!(
                        "No shared secret found for input {vin} and scan key {scan_key}"
                    ))
                })?;
                let dleq_proof = input.sp_dleq_proofs.get(scan_key).ok_or_else(|| {
                    Error::msg(format!(
                        "No dleq proof found for input {vin} and scan key {scan_key}"
                    ))
                })?;
                let partial_share = PartialSenderEcdhShare::new_unchecked(
                    scan_key.0,
                    vin,
                    shared_secret.0,
                    to_rust_dleq(*dleq_proof),
                );
                partial_shares.push(partial_share);
            }
            let shared_secret = TransactionSharedSecret::new_from_partial_shares(
                &secp,
                scan_key.0,
                NonEmptyArray::new(&partial_shares).map_err(|e| Error::msg(e.to_string()))?,
                &transaction_inputs,
            )
            .map_err(|e| Error::msg(e.to_string()))?;
            scan_key_to_shared_secret.insert(scan_key.0, shared_secret);
        }

        let recipients: Vec<[u8; SILENT_PAYMENT_ADDRESS_BYTE_LEN]> = sp_addresses_bytes
            .into_iter()
            .filter_map(|x| x)
            .collect();
        let xonly_map = generate_recipient_pubkeys(&secp, &recipients, &scan_key_to_shared_secret)
            .map_err(|e| Error::msg(e.to_string()))?;
        psbt.set_sp_scriptpubkey(xonly_map)?;
        Ok(psbt.into())
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
