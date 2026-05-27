use anyhow::{Error, Result};
use flutter_rust_bridge::frb;
use spdk_wallet::psbt::roles::Bip375OutputConstructorExt;
use spdk_wallet::{
    bitcoin::{self},
    silentpayments::SilentPaymentAddress,
};

use crate::api::structs::{amount::Amount, outpoint::OutPoint};

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
    pub fn get_selected_utxos(&self) -> Result<Vec<OutPoint>> {
        let psbt: spdk_wallet::psbt::core::Psbt = self.into();
        Ok(psbt
            .inputs
            .iter()
            .map(|input| {
                bitcoin::OutPoint::new(input.previous_txid, input.spent_output_index).into()
            })
            .collect())
    }
}
