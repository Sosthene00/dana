use crate::api::structs::{
    input_selection::InputSelection, network::Network, owned_output::OwnedOutput,
    recipient::Recipient,
};

use anyhow::{Error, Result};
use spdk_wallet::{DATA_CARRIER_SIZE, bitcoin::{self, ScriptBuf, TxOut, key::TapTweak, script::PushBytesBuf}, client::{FeeRate, RecipientAddress, pick_utxos_for_fee_rate, select_all_utxos_for_fee_rate}, silentpayments::utils::NUMS_H};
use spdk_wallet::silentpayments::Network as SpNetwork;

#[flutter_rust_bridge::frb(sync)]
pub fn select_utxos_to_spend(
    owned_outputs: Vec<OwnedOutput>,
    recipients: Vec<Recipient>,
    n_change_outputs: usize,
    feerate: f32,
    network: Network,
    drain: bool,
) -> Result<InputSelection> {
    let fee_rate = FeeRate::from_sat_per_vb(feerate);

    let recipients: Vec<spdk_wallet::client::Recipient> = recipients
        .into_iter()
        .map(|r| r.try_into().unwrap())
        .collect();

    let available_utxos: Vec<(bitcoin::OutPoint, TxOut)> = owned_outputs
        .into_iter()
        .map(|output| {
            let outpoint: bitcoin::OutPoint = output.outpoint.into();
            let txout = TxOut {
                script_pubkey: ScriptBuf::from_bytes(output.script),
                value: output.amount.into(),
            };
            Ok((outpoint, txout))
        })
        .collect::<Result<Vec<_>>>()?;

    let sp_network = match network {
        Network::Mainnet => SpNetwork::Mainnet,
        Network::Testnet3 | Network::Testnet4 | Network::Signet => SpNetwork::Testnet,
        Network::Regtest => SpNetwork::Regtest,
    };

    let dummy_spk = ScriptBuf::new_p2tr_tweaked(
        spdk_wallet::bitcoin::XOnlyPublicKey::from_slice(&NUMS_H)
            .expect("NUMS is always valid")
            .dangerous_assume_tweaked(),
    );

    let tx_outs: Vec<TxOut> = recipients.iter().map(|r| {
        match &r.address {
            RecipientAddress::LegacyAddress(unchecked_address) => {
                let script_pubkey = unchecked_address
                    .clone()
                    .require_network((network.clone()).into())?
                    .script_pubkey();
                Ok(TxOut {
                    script_pubkey: script_pubkey,
                    value: r.amount.into(),
                })
            }
            RecipientAddress::SpAddress(sp_address) => {
                if sp_address.get_network() != sp_network {
                    return Err(anyhow::Error::msg("Recipient address network mismatch"));
                }
                Ok(TxOut {
                    script_pubkey: dummy_spk.clone(),
                    value: r.amount.into(),
                })
            }
            RecipientAddress::Data(data) => {
                let amount = r.amount;
                let data_len = data.len();
                if amount != spdk_wallet::bitcoin::Amount::ZERO {
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

                    let txout = TxOut {
                        script_pubkey,
                        value: amount,
                    };
                    Ok(txout)
                }
            }
        }
    })
    .collect::<Result<Vec<_>>>()?;

    let input_selection = if drain {
        select_all_utxos_for_fee_rate(available_utxos, tx_outs, fee_rate)?
    } else {
        pick_utxos_for_fee_rate(available_utxos, tx_outs, n_change_outputs, fee_rate)?
    };

    Ok(input_selection.into())
}