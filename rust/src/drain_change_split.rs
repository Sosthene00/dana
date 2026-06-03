//! Strategies for splitting drain change across multiple outputs.
//!
//! **Active:** [`random_split_sats`]
//!
//! **Parked:** [`fixed_denom`] — 1–2–5 denomination ladder, output count chosen before
//! coin selection, remainder below 1000 sats paid as extra fee.

use anyhow::{Error, Result};
use rand::{Rng, rng};
use spdk_wallet::bitcoin::{OutPoint, ScriptBuf, TxOut};
use spdk_wallet::client::{FeeRate, select_all_utxos_for_fee_rate};

pub const MIN_DRAIN_OUTPUT_SAT: u64 = 1000;

/// Split `total_sat` into `n` parts that sum exactly to `total_sat`, each at least
/// 1000 sats when `n > 1`.
pub fn random_split_sats(total_sat: u64, n: usize) -> Result<Vec<u64>> {
    if n == 0 {
        return Err(Error::msg("Cannot split change across zero outputs"));
    }
    if n == 1 {
        return Ok(vec![total_sat]);
    }
    if total_sat == 0 {
        return Ok(vec![0; n]);
    }

    let min_total = MIN_DRAIN_OUTPUT_SAT
        .checked_mul(n as u64)
        .ok_or_else(|| Error::msg("Change split overflow"))?;
    if total_sat < min_total {
        return Err(Error::msg(format!(
            "Change ({} sats) is too small to split across {} outputs (need at least {} sats)",
            total_sat, n, min_total
        )));
    }

    let extra = total_sat - min_total;

    let mut rng = rng();
    let mut weights: Vec<u64> = (0..n).map(|_| rng.random()).collect();
    if weights.iter().all(|&w| w == 0) {
        weights[0] = 1;
    }
    let weight_sum: u128 = weights.iter().map(|&w| w as u128).sum();

    let mut remaining = extra;
    let mut amounts = Vec::with_capacity(n);
    for i in 0..n - 1 {
        let share = ((extra as u128) * (weights[i] as u128) / weight_sum) as u64;
        amounts.push(share + MIN_DRAIN_OUTPUT_SAT);
        remaining -= share;
    }
    amounts.push(remaining + MIN_DRAIN_OUTPUT_SAT);
    Ok(amounts)
}

/// Fixed 1–2–5 denomination splitting. Not used in production yet.
#[allow(dead_code)]
pub mod fixed_denom {
    use super::*;

    /// 1–2–5 per decade from 1k to 1M sats.
    pub const DRAIN_DENOMS: &[u64] = &[
        1_000,
        2_000,
        5_000,
        10_000,
        20_000,
        50_000,
        100_000,
        200_000,
        500_000,
        1_000_000,
    ];

    /// Greedy decomposition of `sats` (must be a multiple of 1000) into [`DRAIN_DENOMS`].
    pub fn decompose_denom_sats(mut sats: u64) -> Vec<u64> {
        let mut amounts = Vec::new();
        for &denom in DRAIN_DENOMS.iter().rev() {
            while sats >= denom {
                amounts.push(denom);
                sats -= denom;
            }
        }
        amounts
    }

    pub fn owned_outputs_to_tx_utxos(
        owned_outputs: &[crate::api::structs::owned_output::OwnedOutput],
    ) -> Result<Vec<(spdk_wallet::bitcoin::OutPoint, TxOut)>> {
        owned_outputs
            .iter()
            .map(|output| {
                let outpoint: spdk_wallet::bitcoin::OutPoint = output.outpoint.clone().into();
                let txout = TxOut {
                    script_pubkey: ScriptBuf::from_bytes(output.script.clone()),
                    value: spdk_wallet::bitcoin::Amount::from_sat(output.amount.0),
                };
                Ok((outpoint, txout))
            })
            .collect()
    }

    pub fn outputs_to_fee_tx_outs(
        outputs: &[spdk_wallet::psbt::core::Output],
        nums: &str,
    ) -> Result<Vec<TxOut>> {
        use std::str::FromStr;

        use spdk_wallet::bitcoin::key::TapTweak;

        outputs
            .iter()
            .map(|o| {
                if !o.script_pubkey.is_empty() {
                    Ok(TxOut {
                        script_pubkey: o.script_pubkey.clone(),
                        value: o.amount,
                    })
                } else if o.sp_v0_info.is_some() {
                    let dummy_spk = ScriptBuf::new_p2tr_tweaked(
                        spdk_wallet::bitcoin::XOnlyPublicKey::from_str(nums)
                            .expect("NUMS is always valid")
                            .dangerous_assume_tweaked(),
                    );
                    Ok(TxOut {
                        script_pubkey: dummy_spk,
                        value: o.amount,
                    })
                } else {
                    Err(Error::msg(
                        "psbt is missing script pubkey/sp_v0_info at least on one output",
                    ))
                }
            })
            .collect()
    }

    /// Plan drain output amounts (fixed denoms) and fee dust before coin selection.
    ///
    /// `pool = total_input - network_fee`, `dust_fee = pool % 1000`, outputs sum to
    /// `pool - dust_fee`. The dust is paid as extra fee (not assigned to an output).
    pub fn plan_drain_output_amounts(
        available_utxos: &[(OutPoint, TxOut)],
        fee_rate: FeeRate,
        template_tx_out: TxOut,
    ) -> Result<Vec<u64>> {
        let total_input: u64 = available_utxos
            .iter()
            .map(|(_, o)| o.value.to_sat())
            .try_fold(0u64, |acc, v| acc.checked_add(v))
            .ok_or_else(|| Error::msg("Input sum overflow"))?;

        if total_input < MIN_DRAIN_OUTPUT_SAT {
            return Err(Error::msg("Not enough funds to drain"));
        }

        let mut network_fee_est = 0u64;
        for _ in 0..32 {
            let pool = total_input
                .checked_sub(network_fee_est)
                .ok_or_else(|| Error::msg("Fee exceeds wallet balance"))?;
            let dust_fee = pool % MIN_DRAIN_OUTPUT_SAT;
            let decomposable = pool - dust_fee;

            if decomposable < MIN_DRAIN_OUTPUT_SAT {
                return Err(Error::msg(format!(
                    "Not enough funds after fees ({} sats left for outputs)",
                    decomposable
                )));
            }

            let amounts = decompose_denom_sats(decomposable);
            if amounts.is_empty() {
                return Err(Error::msg("Could not decompose drain outputs"));
            }

            let tx_outs: Vec<TxOut> = amounts
                .iter()
                .map(|&sat| TxOut {
                    script_pubkey: template_tx_out.script_pubkey.clone(),
                    value: spdk_wallet::bitcoin::Amount::from_sat(sat),
                })
                .collect();

            let selection = select_all_utxos_for_fee_rate(
                available_utxos.to_vec(),
                tx_outs,
                fee_rate,
            )?;
            let actual_network_fee = selection.fee.to_sat();
            let output_sum: u64 = amounts.iter().sum();

            if actual_network_fee == network_fee_est
                && selection.change.to_sat() == output_sum
                && output_sum + actual_network_fee + dust_fee == total_input
            {
                return Ok(amounts);
            }

            network_fee_est = actual_network_fee;
        }

        Err(Error::msg(
            "Could not converge on drain output plan for the given fee rate",
        ))
    }
}
