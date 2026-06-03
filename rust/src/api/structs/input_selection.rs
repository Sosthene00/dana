use serde::{Deserialize, Serialize};
use spdk_wallet::client::FeeRate;

use crate::api::structs::amount::Amount;
use crate::api::structs::outpoint::OutPoint;

fn strategy_from_spdk(strategy: spdk_wallet::client::Strategy) -> String {
    match strategy {
        spdk_wallet::client::Strategy::Changeless => "changeless",
        spdk_wallet::client::Strategy::LowestFee => "lowest_fee",
        spdk_wallet::client::Strategy::Greedy => "greedy",
        spdk_wallet::client::Strategy::Drain => "drain",
    }
    .to_string()
}

fn strategy_to_spdk(strategy: &str) -> spdk_wallet::client::Strategy {
    match strategy {
        "changeless" => spdk_wallet::client::Strategy::Changeless,
        "lowest_fee" => spdk_wallet::client::Strategy::LowestFee,
        "greedy" => spdk_wallet::client::Strategy::Greedy,
        "drain" => spdk_wallet::client::Strategy::Drain,
        other => panic!("unknown strategy: {other}"),
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InputSelection {
    pub selected_utxos: Vec<OutPoint>,
    pub change: Amount,
    pub n_change_outputs: usize,
    pub fee: Amount,
    /// Fee rate in satoshis per virtual byte.
    pub actual_fee_rate: f32,
    pub strategy: String,
}

impl From<spdk_wallet::client::InputSelection> for InputSelection {
    fn from(value: spdk_wallet::client::InputSelection) -> Self {
        Self {
            selected_utxos: value
                .selected_utxos
                .into_iter()
                .map(Into::into)
                .collect(),
            change: value.change.into(),
            n_change_outputs: value.n_change_outputs,
            fee: value.fee.into(),
            actual_fee_rate: value.actual_fee_rate.as_sat_vb(),
            strategy: strategy_from_spdk(value.strategy),
        }
    }
}

impl From<InputSelection> for spdk_wallet::client::InputSelection {
    fn from(value: InputSelection) -> Self {
        Self {
            selected_utxos: value
                .selected_utxos
                .into_iter()
                .map(Into::into)
                .collect(),
            change: value.change.into(),
            n_change_outputs: value.n_change_outputs,
            fee: value.fee.into(),
            actual_fee_rate: FeeRate::from_sat_per_vb(value.actual_fee_rate),
            strategy: strategy_to_spdk(&value.strategy),
        }
    }
}
