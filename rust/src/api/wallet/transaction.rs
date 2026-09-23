use crate::api::structs::amount::Amount as ApiAmount;
use crate::api::structs::input_selection::InputSelection;
use crate::api::structs::network::Network;
use crate::api::structs::outpoint::OutPoint as ApiOutPoint;
use crate::api::structs::owned_output::{OwnedOutput, WalletUtxo};
use crate::api::structs::recipient::Recipient;

use anyhow::{Error, Result};
use bip39::rand::seq::SliceRandom;
use bip39::rand::thread_rng;
use flutter_rust_bridge::frb;
use psbt_v2::psbt::{Creator, Finalizer, GetKey, GetKeyError, KeyRequest, Psbt};
use psbt_v2::{Extractor, Input, Output as PsbtOutput, SpV0Info};
use spdk_wallet::backend_blindbit_v1::BlindbitClient;
use spdk_wallet::bitcoin::bip32;
use spdk_wallet::bitcoin::consensus::encode::{deserialize_hex, serialize};
use spdk_wallet::bitcoin::hex::DisplayHex;
use spdk_wallet::bitcoin::secp256k1::{Secp256k1, SecretKey, Signing};
use spdk_wallet::bitcoin::{
    script::PushBytesBuf, Amount, CompressedPublicKey, NetworkKind, PrivateKey, ScriptBuf,
    Transaction, TxOut, XOnlyPublicKey,
};
use spdk_wallet::client::RecipientAddress;
use spdk_wallet::psbt::roles::{Bip375UpdaterExt, ShareMode, SpSignerExt};
use spdk_wallet::silentpayments::receiving::{Label, Receiver};
use spdk_wallet::silentpayments::utils::receiving::{get_pubkey_from_input, PublicTweakData};
use spdk_wallet::silentpayments::utils::OutPoint as SpOutPoint;
use spdk_wallet::silentpayments::{
    Network as SpNetwork, SpVersion, TransactionInputs, TransactionSharedSecret,
};
use spdk_wallet::DATA_CARRIER_SIZE;

use super::SpWallet;

/// The PSBT built for a payment, together with the final recipient list
/// (payment recipient plus any change outputs), used to record the outgoing
/// transaction once it is broadcast.
#[derive(Debug, Clone)]
#[frb]
pub struct CreatedPsbt {
    pub psbt: Vec<u8>,
    pub recipients: Vec<Recipient>,
}

fn to_utxos_and_recipients(
    owned_outputs: Vec<OwnedOutput>,
    api_recipients: Vec<Recipient>,
) -> Result<(Vec<WalletUtxo>, Vec<spdk_wallet::client::Recipient>)> {
    let available_utxos = owned_outputs
        .into_iter()
        .map(|o| o.try_into_utxo())
        .collect::<Result<Vec<_>>>()?;
    let recipients = api_recipients
        .into_iter()
        .map(|r| r.try_into())
        .collect::<Result<Vec<spdk_wallet::client::Recipient>>>()?;
    Ok((available_utxos, recipients))
}

/// Spend-key provider for the PSBT signer role. Returns the untweaked spend
/// key only when the BIP-32 key request matches this wallet's origin. The
/// signer applies the per-input `sp_tweak` itself.
struct SpendKeyProvider {
    spend: SecretKey,
    fingerprint: bip32::Fingerprint,
    derivation_path: bip32::DerivationPath,
    network: NetworkKind,
}

impl GetKey for SpendKeyProvider {
    type Error = GetKeyError;

    fn get_key<C: Signing>(
        &self,
        key_request: KeyRequest,
        _secp: &Secp256k1<C>,
    ) -> Result<Option<PrivateKey>, Self::Error> {
        match key_request {
            KeyRequest::Bip32((fingerprint, path))
                if fingerprint == self.fingerprint && path == self.derivation_path =>
            {
                Ok(Some(PrivateKey::new(self.spend, self.network)))
            }
            // Pubkey requests carry the tweaked spend key (the PSBT map key).
            // Serving them would skip the origin check; the signer still
            // applies `sp_tweak` to whatever we return.
            _ => Ok(None),
        }
    }
}

impl SpWallet {
    /// Builds a BIP-375 PSBT (v2) for a previously chosen [InputSelection].
    ///
    /// The returned PSBT has all inputs and outputs set, with silent payment
    /// outputs still carrying placeholder scriptPubKeys (the SP output keys
    /// are only derived at signing time, see [SpWallet::sign_psbt]).
    ///
    /// Also returns the final recipient list (payment recipient plus any
    /// change outputs), so the outgoing transaction can be recorded once the
    /// signed transaction is broadcast.
    #[flutter_rust_bridge::frb(sync)]
    pub fn create_psbt(
        &self,
        owned_outputs: Vec<OwnedOutput>,
        api_recipients: Vec<Recipient>,
        selection: InputSelection,
        network: Network,
    ) -> Result<CreatedPsbt> {
        let (available_utxos, mut recipients) =
            to_utxos_and_recipients(owned_outputs, api_recipients)?;
        let network = spdk_wallet::bitcoin::Network::from(network);

        let sp_network = match network {
            spdk_wallet::bitcoin::Network::Bitcoin => SpNetwork::Mainnet,
            spdk_wallet::bitcoin::Network::Testnet | spdk_wallet::bitcoin::Network::Signet => {
                SpNetwork::Testnet
            }
            spdk_wallet::bitcoin::Network::Regtest => SpNetwork::Regtest,
            _ => unreachable!(),
        };

        for r in &recipients {
            if let RecipientAddress::SpCode(sp_code) = &r.address {
                if sp_code.network() != sp_network {
                    return Err(Error::msg(format!(
                        "Wrong network for silent payment code {}",
                        sp_code
                    )));
                }
            }
        }

        if recipients.len() != selection.n_sent_outputs {
            return Err(Error::msg(format!(
                "Number of outputs mismatch between recipients and selection: recipients {}, expected n_sent {}",
                recipients.len(), selection.n_sent_outputs,
            )));
        }

        let change = Amount::from(selection.change);

        // append change outputs (drain selections never have change)
        if change > Amount::ZERO {
            recipients.push(spdk_wallet::client::Recipient {
                address: RecipientAddress::SpCode(self.client.change_code()),
                amount: change,
            });
        }

        let total_outputs_amt: Amount = recipients.iter().map(|r| r.amount).sum();
        let expected_outputs_amt = Amount::from(selection.sent) + change;
        if total_outputs_amt != expected_outputs_amt {
            return Err(Error::msg(format!(
                "Amount mismatch between recipients and selection: recipients total {}, expected sent+change {}",
                total_outputs_amt, expected_outputs_amt,
            )));
        }

        let mut outputs = recipients
            .iter()
            .map(|recipient| match &recipient.address {
                RecipientAddress::LegacyAddress(address) => Ok(PsbtOutput::new(TxOut {
                    value: recipient.amount,
                    script_pubkey: address.clone().require_network(network)?.script_pubkey(),
                })),
                RecipientAddress::SpCode(sp_code) => {
                    // BIP-375: the scriptPubKey stays empty at this stage, it is
                    // derived from the ECDH shares at signing time.
                    let sp_info = SpV0Info::new(
                        CompressedPublicKey(sp_code.scan_key()),
                        CompressedPublicKey(sp_code.m_pubkey()),
                    );
                    let output = PsbtOutput {
                        sp_v0_info: Some(sp_info),
                        amount: recipient.amount,
                        ..Default::default()
                    };
                    Ok(output)
                }
                RecipientAddress::Data(data) => {
                    if recipient.amount > Amount::ZERO {
                        return Err(Error::msg("Data output must have an amount of 0!"));
                    }
                    if data.len() > DATA_CARRIER_SIZE {
                        return Err(Error::msg(format!(
                            "Can't embed data of length {}. Max length: {}",
                            data.len(),
                            DATA_CARRIER_SIZE
                        )));
                    }
                    let mut op_return = PushBytesBuf::with_capacity(data.len());
                    op_return.extend_from_slice(data)?;
                    Ok(PsbtOutput::new(TxOut {
                        value: recipient.amount,
                        script_pubkey: ScriptBuf::new_op_return(op_return),
                    }))
                }
            })
            .collect::<Result<Vec<_>>>()?;

        let selected_utxos: Vec<WalletUtxo> = selection
            .selected_utxos
            .into_iter()
            .map(|op| {
                let op = spdk_wallet::bitcoin::OutPoint::from(op);
                available_utxos
                    .iter()
                    .find(|(o, _)| *o == op)
                    .map(|(o, d)| (*o, d.clone()))
                    .ok_or_else(|| {
                        Error::msg(format!("outpoint {} not found in available_utxos", op))
                    })
            })
            .collect::<Result<_>>()?;

        outputs.shuffle(&mut thread_rng());

        let secp = Secp256k1::new();
        let b_spend = self.client.try_secret_spend_key()?;
        let (fingerprint, derivation_path) = self.psbt_key_source()?;
        let (spend_xonly, _) = b_spend.x_only_public_key(&secp);

        let mut constructor = Creator::new().constructor_modifiable();
        for output in outputs {
            constructor = constructor
                .output(output)
                .map_err(|e| Error::msg(e.to_string()))?;
        }
        for (outpoint, output) in &selected_utxos {
            let mut input = Input::new(outpoint);
            input.witness_utxo = Some(TxOut {
                value: output.value,
                script_pubkey: output.script_pubkey.clone(),
            });
            input.set_sp_tweak(output.tweak.to_be_bytes());
            // BIP-376: the map key is the untweaked spend key B_spend; the signer
            // applies sp_tweak and negates d if odd (see psbt_v2 sign_with_tweaked_key).
            input.set_sp_spend_bip32_derivation(
                CompressedPublicKey(b_spend.public_key(&secp)),
                fingerprint,
                derivation_path.clone(),
            );
            // BIP-375 signer checks look at tap_key_origins (not the BIP-376 map)
            // for P2TR inputs that carry a DLEQ proof. SP inputs have no internal
            // key, so declare the untweaked spend key's origin here.
            input.tap_key_origins.insert(
                spend_xonly,
                (Vec::new(), (fingerprint, derivation_path.clone())),
            );
            constructor = constructor.input(input);
        }
        let psbt = constructor.psbt().map_err(|e| Error::msg(e.to_string()))?;

        Ok(CreatedPsbt {
            psbt: psbt.serialize(),
            recipients: recipients.into_iter().map(Into::into).collect(),
        })
    }

    /// Signs a PSBT created by [SpWallet::create_psbt]: generates the ECDH
    /// shares (with DLEQ proofs), derives the SP output scriptPubKeys, signs
    /// every input, finalizes and extracts the transaction.
    #[flutter_rust_bridge::frb(sync)]
    pub fn sign_psbt(&self, psbt: Vec<u8>) -> Result<String> {
        let mut psbt =
            Psbt::deserialize(&psbt).map_err(|e| Error::msg(format!("invalid psbt: {}", e)))?;

        let secp = Secp256k1::new();
        let b_spend = self.client.try_secret_spend_key()?;
        let (fingerprint, derivation_path) = self.psbt_key_source()?;

        let keys = SpendKeyProvider {
            spend: b_spend,
            fingerprint,
            derivation_path,
            network: NetworkKind::from(self.client.network()),
        };
        psbt.add_ecdh_shares(&secp, &mut thread_rng(), &keys, ShareMode::Global)
            .map_err(|e| Error::msg(e.to_string()))?;
        psbt.commit_sp_outputs(&secp)
            .map_err(|e| Error::msg(e.to_string()))?;
        psbt.sign_silent_payment_inputs(&keys, &secp)
            .map_err(|e| Error::msg(e.to_string()))?;
        let psbt = Finalizer::new(psbt)
            .map_err(|e| Error::msg(e.to_string()))?
            .finalize(&secp)
            .map_err(|e| Error::msg(e.to_string()))?;
        let tx = Extractor::new(psbt)
            .map_err(|e| Error::msg(e.to_string()))?
            .extract_tx()
            .map_err(|e| Error::msg(e.to_string()))?;
        Ok(serialize(&tx).to_lower_hex_string())
    }

    /// Scan a signed transaction for silent-payment outputs belonging to this wallet.
    ///
    /// [prevout_scripts] must be the funding scriptPubKeys of each input, in vin order.
    /// Those scripts are not in the raw transaction; they come from the spent UTXOs.
    #[flutter_rust_bridge::frb(sync)]
    pub fn scan_signed_tx(
        &self,
        tx_hex: String,
        prevout_scripts: Vec<Vec<u8>>,
    ) -> Result<Vec<OwnedOutput>> {
        let tx: Transaction = deserialize_hex(&tx_hex)
            .map_err(|e| Error::msg(format!("invalid transaction hex: {e}")))?;

        if prevout_scripts.len() != tx.input.len() {
            return Err(Error::msg(format!(
                "prevout_scripts length {} does not match input count {}",
                prevout_scripts.len(),
                tx.input.len()
            )));
        }

        let secp = Secp256k1::new();
        let mut inputs = TransactionInputs::new();
        for (vin, (txin, script)) in tx.input.iter().zip(prevout_scripts.iter()).enumerate() {
            let outpoint = SpOutPoint::from_txid_and_vout(
                &txin.previous_output.txid.to_string(),
                txin.previous_output.vout,
            )
            .map_err(|e| Error::msg(format!("input {vin} outpoint: {e}")))?;
            let witness: Vec<Vec<u8>> = txin.witness.to_vec();
            let pubkey = get_pubkey_from_input(txin.script_sig.as_bytes(), &witness, script)
                .map_err(|e| Error::msg(format!("input {vin} pubkey: {e}")))?;
            inputs.push(outpoint, script.clone(), pubkey);
        }

        let tweak_data = PublicTweakData::new(&secp, &inputs)
            .map_err(|e| Error::msg(format!("tweak data: {e}")))?;
        let shared_secret = TransactionSharedSecret::new_from_public_tweak_data(
            &secp,
            &tweak_data,
            &self.client.scan_key(),
        )
        .map_err(|e| Error::msg(format!("shared secret: {e}")))?;

        let output_keys: Vec<XOnlyPublicKey> = tx
            .output
            .iter()
            .filter(|o| o.script_pubkey.is_p2tr())
            .map(|o| {
                XOnlyPublicKey::from_slice(&o.script_pubkey.as_bytes()[2..])
                    .map_err(|e| Error::msg(format!("invalid p2tr output key: {e}")))
            })
            .collect::<Result<_>>()?;

        // SpClient::sp_receiver is crate-private; rebuild the same default Receiver.
        let scan_sk = self.client.scan_key();
        let sp_network = match self.client.network() {
            spdk_wallet::bitcoin::Network::Bitcoin => SpNetwork::Mainnet,
            spdk_wallet::bitcoin::Network::Testnet | spdk_wallet::bitcoin::Network::Signet => {
                SpNetwork::Testnet
            }
            spdk_wallet::bitcoin::Network::Regtest => SpNetwork::Regtest,
            _ => unreachable!(),
        };
        let receiver = Receiver::new(
            SpVersion::ZERO,
            scan_sk.public_key(&secp),
            (&self.client.spend_key()).into(),
            Label::new(scan_sk, 0),
            sp_network,
        )
        .map_err(|e| Error::msg(format!("receiver: {e}")))?;
        let ours = receiver
            .scan_transaction(&shared_secret, &output_keys)
            .map_err(|e| Error::msg(format!("scan_transaction: {e}")))?;

        let txid = tx.compute_txid();
        let mut found = Vec::new();
        for (vout, txout) in tx.output.iter().enumerate() {
            if !txout.script_pubkey.is_p2tr() {
                continue;
            }
            let xonly = XOnlyPublicKey::from_slice(&txout.script_pubkey.as_bytes()[2..])?;
            for (label, map) in &ours {
                if let Some(tweak) = map.get(&xonly) {
                    found.push(OwnedOutput {
                        outpoint: ApiOutPoint {
                            txid: txid.to_string(),
                            vout: vout as u32,
                        },
                        tweak: tweak.to_be_bytes(),
                        amount: ApiAmount(txout.value.to_sat()),
                        script: txout.script_pubkey.to_bytes(),
                        label: label.as_ref().map(|l| l.as_inner().to_be_bytes()),
                    });
                    break;
                }
            }
        }

        Ok(found)
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
                        if !report.success.is_empty() {
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
