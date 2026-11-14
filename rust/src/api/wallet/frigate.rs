use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::Result;
use futures::{Stream, StreamExt as _};
use frigate_scanner::FrigateScanner;
use lazy_static::lazy_static;
use log::{info, warn};
use spdk_wallet::bitcoin::absolute::Height;
use spdk_wallet::bitcoin::secp256k1::SecretKey;
use spdk_wallet::bitcoin::{OutPoint, ScriptBuf};
use spdk_wallet::silentpayments::receiving::Receiver;

use super::SpWallet;
use crate::api::structs::frigate_event::{map_frigate_event, FrigateEventDto};
use crate::api::structs::owned_output::OwnedOutput;
use crate::stream::send_frigate_event;

/// Delay before a re-subscribe attempt after the subscription ends (B2.4).
const RECONNECT_DELAY: Duration = Duration::from_secs(5);

/// Outcome of forwarding one subscription's event stream.
#[derive(Debug, PartialEq)]
pub(crate) enum PumpOutcome {
    /// The connection ended (a `Disconnected` event arrived or the stream
    /// ended). The supervisor re-subscribes from the committed checkpoint
    /// (B2.4). `CaughtUp` never produces this outcome (B2.6).
    Disconnected(String),
}

/// Forward a frigate subscription's events across the FRB stream.
///
/// The pump is the B2.6 guarantee holder: `CaughtUp` is forwarded like any
/// other event and the loop KEEPS RUNNING afterwards (the mempool leg must
/// continue); only a `Disconnected` event or the end of the stream ends it.
/// Every event is mapped through [`map_frigate_event`] and handed to `emit`
/// (in production, the FRB sink; in tests, a capture buffer).
pub(crate) async fn forward_events<S, F>(events: &mut S, emit: &mut F) -> PumpOutcome
where
    S: Stream<Item = frigate_scanner::FrigateEvent> + Unpin,
    F: FnMut(FrigateEventDto),
{
    while let Some(event) = events.next().await {
        match event {
            frigate_scanner::FrigateEvent::Disconnected(reason) => {
                return PumpOutcome::Disconnected(reason);
            }
            other => emit(map_frigate_event(other)),
        }
    }
    PumpOutcome::Disconnected("frigate event stream ended".to_owned())
}

/// Everything one subscription attempt needs. Rebuilt identically on every
/// re-subscribe: history replays from the SAME committed checkpoint, already
/// confirmed outputs are re-reported and deduped Dart-side (B2.4, B3.4).
struct SubscriptionArgs {
    host_url: String,
    start_height: u32,
    scan_key: SecretKey,
    receiver: Receiver,
    labels: Option<Vec<u32>>,
    /// Owned outputs known when the subscription (re)starts — re-subscribed
    /// for spend monitoring so pre-checkpoint spends still surface (B1.4's
    /// shared confirmed-state layer; the frigate path never writes `lastscan`).
    previous_outputs: HashMap<ScriptBuf, HashSet<OutPoint>>,
}

struct SubscriptionState {
    stop: Arc<AtomicBool>,
    task: tokio::task::JoinHandle<()>,
}

impl SubscriptionState {
    fn alive(&self) -> bool {
        !self.stop.load(Ordering::Relaxed) && !self.task.is_finished()
    }
}

lazy_static! {
    /// Dedicated runtime so the supervisor's lifetime is independent of the
    /// isolate/async context that started it (it must survive the caller).
    static ref FRIGATE_RUNTIME: tokio::runtime::Runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()
        .expect("frigate supervisor runtime");
    static ref FRIGATE_SUBSCRIPTION: Mutex<Option<SubscriptionState>> = Mutex::new(None);
}

impl SpWallet {
    /// Start the held frigate subscription from the wallet's committed
    /// checkpoint (B1.2). Idempotent: a wake on a wallet whose subscription is
    /// alive does nothing observable (B1.3). The supervisor holds the
    /// subscription across `CaughtUp` (B2.6) and re-subscribes with the same
    /// checkpoint on any disconnect (B2.4).
    pub async fn start_frigate_subscription(
        &self,
        host_url: String,
        start_height: u32,
        owned_outputs: Vec<OwnedOutput>,
        labels: Option<Vec<u32>>,
    ) -> Result<()> {
        let mut state = FRIGATE_SUBSCRIPTION.lock().unwrap();
        if let Some(current) = state.as_ref() {
            if current.alive() {
                info!("frigate subscription already alive; wake is a no-op (B1.3)");
                return Ok(());
            }
        }

        let start = Height::from_consensus(start_height)?;
        let args = SubscriptionArgs {
            host_url,
            start_height: start.to_consensus_u32(),
            scan_key: self.client.scan_key(),
            receiver: self.client.receiver(),
            labels,
            previous_outputs: build_previous_outputs(owned_outputs),
        };

        let stop = Arc::new(AtomicBool::new(false));
        let task = FRIGATE_RUNTIME
            .handle()
            .spawn(supervise_subscription(args, stop.clone()));
        info!("frigate subscription held from checkpoint height {start_height}");
        *state = Some(SubscriptionState { stop, task });
        Ok(())
    }
}

/// Stop the held subscription, if any. Dropping the supervisor aborts the
/// scanner worker (the spdk handle contract).
pub fn stop_frigate_subscription() {
    let mut state = FRIGATE_SUBSCRIPTION.lock().unwrap();
    if let Some(current) = state.take() {
        current.stop.store(true, Ordering::Relaxed);
        current.task.abort();
        info!("frigate subscription stopped");
    }
}

/// Whether a subscription is currently held (alive).
pub fn is_frigate_subscription_running() -> bool {
    let state = FRIGATE_SUBSCRIPTION.lock().unwrap();
    state.as_ref().is_some_and(|s| s.alive())
}

/// Keep a subscription alive until stopped: connect, subscribe from the
/// committed checkpoint, forward events; on any disconnect, re-subscribe
/// after a short delay (B2.4). `CaughtUp` never ends the loop (B2.6).
async fn supervise_subscription(args: SubscriptionArgs, stop: Arc<AtomicBool>) {
    let mut attempt: u64 = 0;
    loop {
        if stop.load(Ordering::Relaxed) {
            break;
        }
        match run_subscription(&args).await {
            Ok(()) => break,
            Err(reason) => {
                if stop.load(Ordering::Relaxed) {
                    break;
                }
                attempt += 1;
                warn!(
                    "frigate subscription ended ({reason}); re-subscribing from checkpoint (attempt {attempt}) (B2.4)"
                );
                tokio::time::sleep(RECONNECT_DELAY).await;
            }
        }
    }
    info!("frigate supervisor exiting");
}

/// One subscription attempt: connect (handshake with `server.version` as the
/// FIRST message is handled inside the fixed scanner's client), subscribe with
/// `start_height` = the committed checkpoint, forward the event stream.
async fn run_subscription(args: &SubscriptionArgs) -> Result<(), String> {
    let start = Height::from_consensus(args.start_height).map_err(|e| e.to_string())?;
    let scanner = FrigateScanner::new(
        args.host_url.clone(),
        args.scan_key,
        args.receiver.clone(),
        args.labels.clone(),
        args.previous_outputs.clone(),
    )
    .await
    .map_err(|e| format!("frigate connect failed: {e}"))?;

    let mut handle = scanner.start(start);
    let outcome = {
        let mut emit = |dto: FrigateEventDto| {
            // A closed sink means the main isolate died (app closed while the
            // service kept running); the sink is replaced on the next
            // createFrigateEventStream() call. Keep the subscription held.
            if let Err(e) = send_frigate_event(dto) {
                warn!("frigate event sink unavailable: {e}");
            }
        };
        forward_events(&mut handle, &mut emit).await
    };
    drop(handle); // aborts the scanner worker for this attempt

    match outcome {
        PumpOutcome::Disconnected(reason) => Err(reason),
    }
}

/// Owned outputs grouped by script for the scanner's spend monitoring.
fn build_previous_outputs(owned_outputs: Vec<OwnedOutput>) -> HashMap<ScriptBuf, HashSet<OutPoint>> {
    let mut map: HashMap<ScriptBuf, HashSet<OutPoint>> = HashMap::new();
    for output in owned_outputs {
        let script = ScriptBuf::from_bytes(output.script);
        let outpoint: OutPoint = output.outpoint.into();
        map.entry(script).or_default().insert(outpoint);
    }
    map
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use futures::stream;

    use spdk_wallet::bitcoin::BlockHash;

    use super::*;

    const BLOCK_HASH_HEX: &str =
        "0000000000000000000000000000000000000000000000000000000000000001";

    fn tip(height: u32) -> frigate_scanner::FrigateEvent {
        frigate_scanner::FrigateEvent::Tip {
            height: Height::from_consensus(height).unwrap(),
            hash: BlockHash::from_str(BLOCK_HASH_HEX).unwrap(),
        }
    }

    fn disconnected(reason: &str) -> frigate_scanner::FrigateEvent {
        frigate_scanner::FrigateEvent::Disconnected(reason.to_owned())
    }

    fn collect_dtos(
        events: Vec<frigate_scanner::FrigateEvent>,
    ) -> (PumpOutcome, Vec<FrigateEventDto>) {
        let mut emitted: Vec<FrigateEventDto> = Vec::new();
        let mut stream_events = stream::iter(events);
        let outcome = futures::executor::block_on(forward_events(
            &mut stream_events,
            &mut |dto| emitted.push(dto),
        ));
        (outcome, emitted)
    }

    /// B2.6: after `CaughtUp` the pump keeps running — events arriving after
    /// the catch-up marker are still forwarded, and the pump only ends when
    /// the connection actually ends.
    #[tokio::test]
    async fn pump_continues_after_caught_up() {
        let (outcome, emitted) = collect_dtos(vec![
            tip(100),
            frigate_scanner::FrigateEvent::CaughtUp,
            tip(101),
        ]);

        assert!(
            matches!(outcome, PumpOutcome::Disconnected(_)),
            "stream ended normally -> supervisor will re-subscribe"
        );
        assert_eq!(emitted.len(), 3, "CaughtUp must not stop the pump (B2.6)");
        assert!(matches!(emitted[1], FrigateEventDto::CaughtUp));
        match &emitted[2] {
            FrigateEventDto::Tip { height, .. } => assert_eq!(*height, 101),
            other => panic!("expected post-catch-up Tip, got {other:?}"),
        }
    }

    /// A `Disconnected` event ends the pump, carries the reason to the
    /// supervisor, and nothing is forwarded after it.
    #[tokio::test]
    async fn pump_stops_on_disconnected() {
        let (outcome, emitted) =
            collect_dtos(vec![tip(100), disconnected("connection reset"), tip(101)]);

        assert_eq!(outcome, PumpOutcome::Disconnected("connection reset".into()));
        assert_eq!(emitted.len(), 1);
        match &emitted[0] {
            FrigateEventDto::Tip { height, .. } => assert_eq!(*height, 100),
            other => panic!("expected Tip before the disconnect, got {other:?}"),
        }
    }

    /// Rig probe (NOT a unit test): on the regtest rig the subscription must
    /// reach CaughtUp and REMAIN HELD after it (B2.6). Run on the code host:
    ///   cargo test --lib rig_subscription -- --ignored --nocapture
    #[tokio::test]
    #[ignore = "requires the regtest rig (frigate on 127.0.0.1:50002)"]
    async fn rig_subscription_reaches_caughtup_and_stays_held() {
        use std::collections::HashMap;

        use spdk_wallet::bitcoin::Network;
        use spdk_wallet::client::{SpClient, SpendKey};

        let _ = simplelog::WriteLogger::init(
            log::LevelFilter::Info,
            simplelog::Config::default(),
            std::io::stdout(),
        );

        let scan_sk = SecretKey::from_slice(&[0x2a; 32]).unwrap();
        let spend_sk = SecretKey::from_slice(&[0x2b; 32]).unwrap();
        let client = SpClient::new(scan_sk, SpendKey::Secret(spend_sk), Network::Regtest).unwrap();
        let receiver = client.receiver();

        let scanner = FrigateScanner::new(
            "127.0.0.1:50002".to_owned(),
            scan_sk,
            receiver,
            None,
            HashMap::new(),
        )
        .await
        .expect("connect to regtest frigate");

        let mut handle = scanner.start(Height::from_consensus(0).unwrap());

        // First event is the current tip.
        let first = tokio::time::timeout(std::time::Duration::from_secs(30), handle.next())
            .await
            .expect("tip within 30s")
            .expect("event stream open");
        assert!(matches!(first, frigate_scanner::FrigateEvent::Tip { .. }));

        // The historical leg replays from height 0 and must reach CaughtUp.
        loop {
            let ev = tokio::time::timeout(std::time::Duration::from_secs(300), handle.next())
                .await
                .expect("event within 5 min")
                .expect("stream open before CaughtUp");
            match ev {
                frigate_scanner::FrigateEvent::CaughtUp => break,
                frigate_scanner::FrigateEvent::Disconnected(reason) => {
                    panic!("disconnected before CaughtUp: {reason}")
                }
                _ => {}
            }
        }
        info!("RIG PROBE: CaughtUp reached");

        // B2.6: the subscription is still held after CaughtUp — the worker is
        // still alive, so the stream must not end. A None here is a violation;
        // a timeout (pending) or another arriving event is proof it is held.
        match tokio::time::timeout(std::time::Duration::from_secs(5), handle.next()).await {
            Err(_elapsed) => info!("RIG PROBE: stream still pending after CaughtUp — subscription held (B2.6)"),
            Ok(Some(ev)) => info!("RIG PROBE: event after CaughtUp: {ev:?} — subscription held (B2.6)"),
            Ok(None) => panic!("subscription dropped after CaughtUp (B2.6 violation)"),
        }
    }
}
