use std::collections::HashMap;

use flutter_rust_bridge::frb;
use frigate_scanner::FrigateEvent;

use crate::api::structs::outpoint::OutPoint;
use crate::api::structs::owned_output::OwnedOutput;

/// Mirror of the fixed spdk [`FrigateEvent`] stream, shaped for the FRB
/// crossing into Dart (B2.7: no wallet-native types cross the bridge;
/// everything here is plain data the Dart service can consume).
///
/// Variants map 1:1 to the scanner's events:
/// - `Tip` — the chain tip; also the first event of every subscription.
/// - `Confirmed` — owned outputs confirmed in a block (historic AND live legs).
/// - `Unconfirmed` — owned outputs seen in the mempool (height <= 0, B1.2).
/// - `CaughtUp` — the historical leg reached the tip. The subscription stays
///   held after this (B2.6); the mempool leg continues.
/// - `Spent` — confirmed outpoints spent in a transaction.
/// - `Disconnected` — the connection ended; the supervisor re-subscribes
///   from the committed checkpoint (B2.4).
#[derive(Debug, Clone)]
#[frb]
pub enum FrigateEventDto {
    Tip { height: u32, hash: String },
    Confirmed {
        blkheight: u32,
        blkhash: String,
        found_outputs: Vec<OwnedOutput>,
    },
    Unconfirmed {
        txid: String,
        outputs: Vec<OwnedOutput>,
    },
    CaughtUp,
    Spent { outpoints: Vec<OutPoint> },
    Disconnected { reason: String },
}

/// Map a fixed spdk [`FrigateEvent`] into its FRB mirror.
///
/// Pure mapping only: no DB writes, no checkpoint updates, no dedupe — all of
/// that lives on the Dart side of the bridge (B2.7).
pub(crate) fn map_frigate_event(event: FrigateEvent) -> FrigateEventDto {
    match event {
        FrigateEvent::Tip { height, hash } => FrigateEventDto::Tip {
            height: height.to_consensus_u32(),
            hash: hash.to_string(),
        },
        FrigateEvent::Confirmed(result) => FrigateEventDto::Confirmed {
            blkheight: result.blkheight.to_consensus_u32(),
            blkhash: result.blkhash.to_string(),
            found_outputs: map_discovered_outputs(&result.discovered_outputs),
        },
        FrigateEvent::Unconfirmed {
            txid,
            discovered_outputs,
        } => FrigateEventDto::Unconfirmed {
            txid: txid.to_string(),
            outputs: map_discovered_outputs(&discovered_outputs),
        },
        FrigateEvent::CaughtUp => FrigateEventDto::CaughtUp,
        FrigateEvent::Spent(outpoints) => {
            let mut mapped: Vec<OutPoint> = outpoints.iter().map(|op| (*op).into()).collect();
            // deterministic order: HashSet iteration order must not leak into
            // the event stream (stable wire shape for tests and consumers).
            mapped.sort_by(|a, b| (&a.txid, a.vout).cmp(&(&b.txid, b.vout)));
            FrigateEventDto::Spent { outpoints: mapped }
        }
        FrigateEvent::Disconnected(reason) => FrigateEventDto::Disconnected { reason },
    }
}

fn map_discovered_outputs(
    outputs: &HashMap<spdk_wallet::bitcoin::OutPoint, spdk_wallet::scanner::DiscoveredOutput>,
) -> Vec<OwnedOutput> {
    let mut mapped: Vec<OwnedOutput> = outputs
        .iter()
        .map(|(outpoint, output)| OwnedOutput {
            outpoint: (*outpoint).into(),
            tweak: output.tweak.to_be_bytes(),
            amount: output.txout.value.into(),
            script: output.txout.script_pubkey.to_bytes(),
            label: output.label.as_ref().map(|l| l.as_inner().to_be_bytes()),
        })
        .collect();
    mapped.sort_by(|a, b| (&a.outpoint.txid, a.outpoint.vout).cmp(&(&b.outpoint.txid, b.outpoint.vout)));
    mapped
}

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, HashSet};
    use std::str::FromStr;

    use spdk_wallet::bitcoin::absolute::Height;
    use spdk_wallet::bitcoin::secp256k1::{Scalar, SecretKey};
    use spdk_wallet::bitcoin::{BlockHash, OutPoint, ScriptBuf, TxOut, Txid};
    use spdk_wallet::scanner::{DiscoveredOutput, ScanResult};
    use spdk_wallet::silentpayments::receiving::Label;

    use super::*;

    const BLOCK_HASH_HEX: &str =
        "0000000000000000000000000000000000000000000000000000000000000001";

    fn block_hash() -> BlockHash {
        BlockHash::from_str(BLOCK_HASH_HEX).unwrap()
    }

    fn height(h: u32) -> Height {
        Height::from_consensus(h).unwrap()
    }

    fn scalar(b: u8) -> Scalar {
        Scalar::from_be_bytes([b; 32]).unwrap()
    }

    /// One owned output discovered at `OutPoint { txid, vout }`.
    fn discovered_output(txid_hex: &str, vout: u32, value_sat: u64) -> (OutPoint, DiscoveredOutput) {
        (
            OutPoint {
                txid: Txid::from_str(txid_hex).unwrap(),
                vout,
            },
            DiscoveredOutput {
                txout: TxOut {
                    value: spdk_wallet::bitcoin::Amount::from_sat(value_sat),
                    // a minimal valid p2tr script: OP_1 <32 bytes>
                    script_pubkey: ScriptBuf::from_hex(
                        "51200102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
                    )
                    .unwrap(),
                },
                tweak: scalar(0x42),
                label: None,
            },
        )
    }

    fn labeled_discovered_output(
        txid_hex: &str,
        vout: u32,
        value_sat: u64,
        label: u32,
    ) -> (OutPoint, DiscoveredOutput) {
        let (outpoint, mut output) = discovered_output(txid_hex, vout, value_sat);
        let scan_sk = SecretKey::from_slice(&[0x11; 32]).unwrap();
        output.label = Some(Label::new(scan_sk, label));
        (outpoint, output)
    }

    fn owned_of(outpoint: &OutPoint, output: &DiscoveredOutput) -> OwnedOutput {
        OwnedOutput {
            outpoint: (*outpoint).into(),
            tweak: output.tweak.to_be_bytes(),
            amount: output.txout.value.into(),
            script: output.txout.script_pubkey.to_bytes(),
            label: output.label.as_ref().map(|l| l.as_inner().to_be_bytes()),
        }
    }

    #[test]
    fn maps_tip_event() {
        let dto = map_frigate_event(FrigateEvent::Tip {
            height: height(1234),
            hash: block_hash(),
        });
        match dto {
            FrigateEventDto::Tip { height, hash } => {
                assert_eq!(height, 1234);
                assert_eq!(hash, BLOCK_HASH_HEX);
            }
            other => panic!("expected Tip, got {other:?}"),
        }
    }

    #[test]
    fn maps_confirmed_event_with_owned_outputs() {
        let (o1, d1) = discovered_output(
            "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16",
            0,
            21_000,
        );
        let (o2, d2) = discovered_output(
            "a1075db55d416d3ca199f55b9345e16c5cf302fc80e9d5fbf5d48d0000000000",
            1,
            5_000,
        );
        let mut outputs = HashMap::new();
        outputs.insert(o1, d1.clone());
        outputs.insert(o2, d2.clone());

        let dto = map_frigate_event(FrigateEvent::Confirmed(ScanResult {
            blkheight: height(900),
            blkhash: block_hash(),
            discovered_inputs: HashSet::new(),
            discovered_outputs: outputs,
        }));

        match dto {
            FrigateEventDto::Confirmed {
                blkheight,
                blkhash,
                found_outputs,
            } => {
                assert_eq!(blkheight, 900);
                assert_eq!(blkhash, BLOCK_HASH_HEX);
                assert_eq!(found_outputs.len(), 2);
                for found in &found_outputs {
                    let (want_op, want_out) = if found.outpoint.vout == 0 {
                        (&o1, &d1)
                    } else {
                        (&o2, &d2)
                    };
                    let want = owned_of(want_op, want_out);
                    assert_eq!(found.outpoint, want.outpoint);
                    assert_eq!(found.tweak, want.tweak);
                    assert_eq!(found.amount, want.amount);
                    assert_eq!(found.script, want.script);
                    assert_eq!(found.label, None);
                }
            }
            other => panic!("expected Confirmed, got {other:?}"),
        }
    }

    #[test]
    fn maps_confirmed_event_label_to_32_byte_label() {
        let (op, out) = labeled_discovered_output(
            "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16",
            3,
            700,
            7,
        );
        let dto = map_frigate_event(FrigateEvent::Confirmed(ScanResult {
            blkheight: height(1),
            blkhash: block_hash(),
            discovered_inputs: HashSet::new(),
            discovered_outputs: HashMap::from([(op, out.clone())]),
        }));
        match dto {
            FrigateEventDto::Confirmed { found_outputs, .. } => {
                assert_eq!(found_outputs.len(), 1);
                assert_eq!(
                    found_outputs[0].label,
                    Some(out.label.as_ref().unwrap().as_inner().to_be_bytes())
                );
            }
            other => panic!("expected Confirmed, got {other:?}"),
        }
    }

    #[test]
    fn maps_unconfirmed_mempool_event() {
        let txid_hex = "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16";
        let (op, out) = discovered_output(txid_hex, 0, 1_000);
        let dto = map_frigate_event(FrigateEvent::Unconfirmed {
            txid: Txid::from_str(txid_hex).unwrap(),
            discovered_outputs: HashMap::from([(op, out.clone())]),
        });
        match dto {
            FrigateEventDto::Unconfirmed { txid, outputs } => {
                assert_eq!(txid, txid_hex);
                assert_eq!(outputs.len(), 1);
                assert_eq!(outputs[0].outpoint.txid, txid_hex);
                assert_eq!(outputs[0].outpoint.vout, 0);
                assert_eq!(outputs[0].amount, out.txout.value.into());
            }
            other => panic!("expected Unconfirmed, got {other:?}"),
        }
    }

    #[test]
    fn maps_caught_up_event() {
        assert!(matches!(
            map_frigate_event(FrigateEvent::CaughtUp),
            FrigateEventDto::CaughtUp
        ));
    }

    #[test]
    fn maps_spent_event_outpoints() {
        let op = OutPoint {
            txid: Txid::from_str("f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16")
                .unwrap(),
            vout: 2,
        };
        let dto = map_frigate_event(FrigateEvent::Spent(HashSet::from([op])));
        match dto {
            FrigateEventDto::Spent { outpoints } => {
                assert_eq!(outpoints.len(), 1);
                assert_eq!(
                    outpoints[0].txid,
                    "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e16"
                );
                assert_eq!(outpoints[0].vout, 2);
            }
            other => panic!("expected Spent, got {other:?}"),
        }
    }

    #[test]
    fn maps_disconnected_event_with_reason() {
        let dto = map_frigate_event(FrigateEvent::Disconnected("connection reset".to_owned()));
        match dto {
            FrigateEventDto::Disconnected { reason } => assert_eq!(reason, "connection reset"),
            other => panic!("expected Disconnected, got {other:?}"),
        }
    }
}
