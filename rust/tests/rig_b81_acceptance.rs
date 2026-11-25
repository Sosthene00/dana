//! R10a — B8.1 acceptance (B8.5 steps 1-6) on the regtest rig.
//!
//! NOT a unit test. Run on the code host with the rig up:
//!   CARGO_TARGET_DIR=/tmp/dana-restart/rust/target \
//!     cargo test --test rig_b81_acceptance -- --ignored --nocapture
//!
//! Exercises the ratification-script flow end to end at the wire level
//! against the REAL frigate regtest instance (127.0.0.1:50002):
//!   fresh wallet -> subscribe from checkpoint 0 -> (fund, MINE, frigate
//!   restart quirk) -> history replay delivers Confirmed exactly once ->
//!   held subscription + sp-faucet -> Unconfirmed push -> frigate restart ->
//!   re-subscribe response carries the mempool entry (Unconfirmed) exactly
//!   once -> tip consistency vs bitcoind (~35 s budget) -> graduation window
//!   (held subscription live during the electrs wire check + mine).
//!
//! Evidence is appended to /tmp/r10a-evidence/rig_events.jsonl.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use futures::StreamExt;
use frigate_scanner::{FrigateEvent, FrigateScanner};
use spdk_wallet::bitcoin::absolute::Height;
use spdk_wallet::bitcoin::secp256k1::{PublicKey, Secp256k1, SecretKey};
use spdk_wallet::bitcoin::{OutPoint, ScriptBuf};
use spdk_wallet::client::{SpClient, SpendKey};
use spdk_wallet::silentpayments::{Network as SpNetwork, SilentPaymentCode};

const FRIGATE_HOST: &str = "127.0.0.1:50002";
const BITCOIND_DATADIR: &str = "/home/hermes/regtest-frigate/bitcoind";
const SP_PAY: &str = "/home/hermes/tools/sp-faucet/sp_faucet/target/release/sp_faucet";
const FRIGATE_BIN: &str = "/home/hermes/tools/frigate-1.4.1/frigate/bin/frigate";
const FRIGATE_ARGS: &[&str] = &[
    "--dir",
    "/home/hermes/.frigate-regtest",
    "-n",
    "regtest",
    "-l",
    "INFO",
];
const EVIDENCE: &str = "/tmp/r10a-evidence/rig_events.jsonl";
const TIP_BUDGET: Duration = Duration::from_secs(35);

fn log_evidence(kind: &str, detail: &str) {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let line = format!("{{\"ts\":{ts},\"kind\":\"{kind}\",\"detail\":{detail}}}\n");
    println!("EVIDENCE {kind}: {detail}");
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(EVIDENCE)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

fn btc(args: &[&str]) -> serde_json::Value {
    for attempt in 0..3 {
        let out = Command::new("bitcoin-cli")
            .arg(format!("-datadir={BITCOIND_DATADIR}"))
            .args(args)
            .output()
            .expect("bitcoin-cli spawn");
        if out.status.success() {
            match serde_json::from_slice(&out.stdout) {
                Ok(v) => return v,
                Err(e) => eprintln!(
                    "btc {:?} attempt {attempt}: parse error {e}; stdout={:?} stderr={:?}",
                    args,
                    String::from_utf8_lossy(&out.stdout),
                    String::from_utf8_lossy(&out.stderr)
                ),
            }
        } else {
            eprintln!(
                "btc {:?} attempt {attempt}: rc={:?} stderr={:?} stdout={:?}",
                args,
                out.status.code(),
                String::from_utf8_lossy(&out.stderr),
                String::from_utf8_lossy(&out.stdout)
            );
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    panic!("bitcoin-cli {args:?} failed after retries");
}

fn btc_height() -> u64 {
    btc(&["getblockchaininfo"])["blocks"].as_u64().unwrap()
}

fn btc_raw(args: &[&str]) -> String {
    let out = Command::new("bitcoin-cli")
        .arg(format!("-datadir={BITCOIND_DATADIR}"))
        .args(args)
        .output()
        .expect("bitcoin-cli spawn");
    assert!(
        out.status.success(),
        "bitcoin-cli {:?} failed: {}",
        args,
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn mine_one() -> u64 {
    let miner_addr = btc_raw(&["-rpcwallet=miner", "getnewaddress", "", "bech32"]);
    btc(&["-rpcwallet=miner", "generatetoaddress", "1", &miner_addr]);
    btc_height()
}

fn sp_pay(amount_btc: &str, addr: &str) -> String {
    // sender swapped: sp-pay's tx construction was the zero-discovery suspect;
    // sp-faucet (sp-client based, proven in the signet era) builds the payment.
    let sats: u64 = (amount_btc.parse::<f64>().expect("bad amount") * 100_000_000.0).round() as u64;
    let out = Command::new(SP_PAY)
        .arg(addr)
        .arg(sats.to_string())
        .current_dir("/home/hermes/tools/sp-faucet/sp_faucet")
        .env(
            "SP_FAUCET_RPC_USERPASS",
            "frigate:ceeec00f4a1b8a4bcb6c33814430b706",
        )
        .env("SP_FAUCET_WALLET", "miner")
        .output()
        .expect("sp-faucet spawn");
    assert!(
        out.status.success(),
        "sp-faucet failed: stderr={} stdout={}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

fn frigate_pids() -> Vec<u32> {
    let out = Command::new("pgrep")
        .arg("-f")
        .arg("frigate/bin/frigate.real --dir /home/hermes/.frigate-regtest")
        .output()
        .expect("pgrep");
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.trim().parse().ok())
        .collect()
}

fn port_open() -> bool {
    std::net::TcpStream::connect(FRIGATE_HOST).is_ok()
}

fn json_rpc_once(host: &str, method: &str, params: serde_json::Value) -> Option<serde_json::Value> {
    use std::io::BufRead;
    let stream = std::net::TcpStream::connect(host).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(10))).ok()?;
    let req = serde_json::json!({"jsonrpc": "2.0", "id": 0, "method": method, "params": params});
    let mut stream2 = stream.try_clone().ok()?;
    writeln!(stream2, "{req}").ok()?;
    let mut reader = std::io::BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    serde_json::from_str::<serde_json::Value>(&line).ok()
}

/// Authoritative electrs tip: the block source frigate indexes from. A
/// frigate restart BEFORE electrs has indexed a fresh block permanently
/// misses it (indexed at process start) — every restart in this script is
/// therefore gated on electrs tip == bitcoind tip (B8.5 step 5 discipline).
fn electrs_tip() -> u64 {
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        // server.version first (wire contract); 1.4.1 answers it with an
        // internal error but the first-message slot is consumed either way.
        let _ = json_rpc_once("127.0.0.1:60401", "server.version", serde_json::json!(["r10a", "1.0"]));
        if let Some(resp) =
            json_rpc_once("127.0.0.1:60401", "blockchain.headers.subscribe", serde_json::json!([]))
        {
            if let Some(h) = resp["result"]["height"].as_u64() {
                return h;
            }
        }
        assert!(Instant::now() < deadline, "electrs tip unreachable on :60401");
        std::thread::sleep(Duration::from_secs(1));
    }
}

fn wait_electrs_indexed(height: u64, label: &str) {
    let deadline = Instant::now() + TIP_BUDGET;
    loop {
        let tip = electrs_tip();
        if tip >= height {
            log_evidence("electrs_indexed", &format!("{label}: electrs tip {tip} >= {height}"));
            return;
        }
        assert!(
            Instant::now() < deadline,
            "{label}: electrs tip {tip} never reached {height} within budget"
        );
        std::thread::sleep(Duration::from_secs(1));
    }
}

/// Rig quirk enabler: restart the regtest frigate instance (indexed at
/// process start). Sanctioned by B8.5 steps 3/4 — this IS the script.
fn restart_frigate() {
    let pids = frigate_pids();
    assert!(!pids.is_empty(), "no regtest frigate process found");
    for pid in &pids {
        let _ = Command::new("kill").arg(pid.to_string()).output();
    }
    let deadline = Instant::now() + Duration::from_secs(20);
    while port_open() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(250));
    }
    assert!(!port_open(), "frigate port still open after kill");
    for pid in &pids {
        let _ = Command::new("kill")
            .arg("-9")
            .arg(pid.to_string())
            .output();
    }
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open("/tmp/r10a-evidence/frigate-restart.log")
        .expect("frigate log file");
    Command::new(FRIGATE_BIN)
        .args(FRIGATE_ARGS)
        .stdout(Stdio::from(log.try_clone().expect("log clone")))
        .stderr(Stdio::from(log))
        .process_group(0)
        .spawn()
        .expect("frigate respawn");
    let deadline = Instant::now() + Duration::from_secs(120);
    while !port_open() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(500));
    }
    assert!(port_open(), "frigate did not come back on :50002");
    // Frigate listens BEFORE its CUDA scan backend finishes warming (the
    // "Generator LUT built" line lands after "listening"); give it a settle
    // window so a history replay is not raced (B8.5 step 5 eventual
    // consistency budget covers this).
    std::thread::sleep(Duration::from_secs(5));
    log_evidence("frigate_restart", &format!("restarted pids {pids:?}"));
}

async fn connect_scanner(
    scan_sk: SecretKey,
    spend_sk: SecretKey,
    previous_outputs: HashMap<ScriptBuf, HashSet<OutPoint>>,
) -> futures::stream::BoxStream<'static, FrigateEvent> {
    let deadline = Instant::now() + Duration::from_secs(120);
    loop {
        let client =
            SpClient::new(scan_sk, SpendKey::Secret(spend_sk), spdk_wallet::bitcoin::Network::Regtest)
                .expect("SpClient::new");
        match FrigateScanner::new(
            FRIGATE_HOST.to_owned(),
            scan_sk,
            client.receiver(),
            None,
            previous_outputs.clone(),
        )
        .await
        {
            Ok(scanner) => {
                let handle = scanner.start(Height::from_consensus(0).unwrap());
                return Box::pin(handle);
            }
            Err(e) => {
                if Instant::now() > deadline {
                    panic!("frigate connect failed persistently: {e}");
                }
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
        }
    }
}

async fn next_event(
    stream: &mut futures::stream::BoxStream<'static, FrigateEvent>,
    what: &str,
    budget: Duration,
) -> FrigateEvent {
    match tokio::time::timeout(budget, stream.next()).await {
        Ok(Some(ev)) => ev,
        Ok(None) => panic!("event stream ended while waiting for {what}"),
        Err(_) => panic!("timeout ({budget:?}) waiting for {what}"),
    }
}

/// Drain events until CaughtUp. Returns (tips, confirmed outpoints,
/// unconfirmed txids, first confirmed output script hex).
async fn drain_until_caught_up(
    stream: &mut futures::stream::BoxStream<'static, FrigateEvent>,
    label: &str,
) -> (Vec<u64>, Vec<String>, Vec<String>, Option<String>) {
    let mut tips = Vec::new();
    let mut confirmed_outpoints = Vec::new();
    let mut unconfirmed = Vec::new();
    let mut first_script = None;
    loop {
        let ev = next_event(stream, &format!("{label}: CaughtUp"), Duration::from_secs(120)).await;
        match ev {
            FrigateEvent::Tip { height, .. } => tips.push(height.to_consensus_u32() as u64),
            FrigateEvent::CaughtUp => {
                log_evidence("caught_up", &format!("{label} reached CaughtUp"));
                break;
            }
            FrigateEvent::Confirmed(sr) => {
                for (op, dout) in &sr.discovered_outputs {
                    confirmed_outpoints.push(format!("{}:{}", op.txid, op.vout));
                    if first_script.is_none() {
                        first_script = Some(dout.txout.script_pubkey.to_hex_string());
                    }
                }
                log_evidence(
                    "confirmed",
                    &format!("{label}: {} output(s)", sr.discovered_outputs.len()),
                );
            }
            FrigateEvent::Unconfirmed { txid, .. } => {
                unconfirmed.push(txid.to_string());
                log_evidence("unconfirmed", &format!("{label}: tx {txid}"));
            }
            FrigateEvent::Disconnected(r) => panic!("{label}: disconnected before CaughtUp: {r}"),
            FrigateEvent::Spent(_) => log_evidence("spent", label),
        }
    }
    (tips, confirmed_outpoints, unconfirmed, first_script)
}

#[tokio::test]
#[ignore = "requires the regtest rig — diagnostic: replay history for the R10A_RUN wallet"]
async fn rig_b81_history_probe() {
    let run: u8 = std::env::var("R10A_RUN").ok().and_then(|v| v.parse().ok()).unwrap_or(3);
    let scan_sk = SecretKey::from_slice(&[0xA0u8.wrapping_add(run); 32]).unwrap();
    let spend_sk = SecretKey::from_slice(&[0xB0u8.wrapping_add(run); 32]).unwrap();
    if std::env::var("R10A_RESTART").is_ok() {
        restart_frigate();
    }
    let mut s = connect_scanner(scan_sk, spend_sk, HashMap::new()).await;
    let (tips, conf, unconf, script) = drain_until_caught_up(&mut s, "probe").await;
    log_evidence(
        "probe_result",
        &format!("run {run}: tips={tips:?} confirmed={conf:?} unconfirmed={unconf:?} script={script:?}"),
    );
}

#[tokio::test]
#[ignore = "requires the regtest rig (bitcoind + frigate :50002 + electrs + sp-pay)"]
async fn rig_b81_three_phase_acceptance() {
    let secp = Secp256k1::new();
    // Fresh wallet per run: keys derived from the run number (env R10A_RUN,
    // default 1) so every run is a genuinely unused wallet on this rig.
    let run: u8 = std::env::var("R10A_RUN").ok().and_then(|v| v.parse().ok()).unwrap_or(1);
    let scan_sk = SecretKey::from_slice(&[0xA0u8.wrapping_add(run); 32]).unwrap();
    let spend_sk = SecretKey::from_slice(&[0xB0u8.wrapping_add(run); 32]).unwrap();
    log_evidence("run", &format!("acceptance run {run}"));
    let scan_pub = PublicKey::from_secret_key(&secp, &scan_sk);
    let spend_pub = PublicKey::from_secret_key(&secp, &spend_sk);
    let address: String = SilentPaymentCode::new_v0(scan_pub, spend_pub, SpNetwork::Regtest).into();
    log_evidence("wallet", &format!("fresh wallet address {address}"));

    // ---- Steps 1-2: fresh wallet subscribes from checkpoint 0; no history.
    let h0 = btc_height();
    let mut s1 = connect_scanner(scan_sk, spend_sk, HashMap::new()).await;
    log_evidence("subscribe", &format!("fresh wallet subscribed from 0, bitcoind height {h0}"));
    let first = next_event(&mut s1, "first event (Tip)", Duration::from_secs(60)).await;
    match first {
        FrigateEvent::Tip { height, .. } => {
            log_evidence("tip", &format!("first event Tip height {}", height.to_consensus_u32()));
            assert_eq!(
                height.to_consensus_u32() as u64,
                h0,
                "frigate tip != bitcoind height at subscribe"
            );
        }
        other => panic!("expected Tip as first event, got {other:?}"),
    }
    let (_, conf1_ops, unconf1, _) = drain_until_caught_up(&mut s1, "fresh-wallet leg").await;
    assert!(conf1_ops.is_empty(), "fresh wallet must have NO confirmed history: {conf1_ops:?}");
    assert!(unconf1.is_empty(), "fresh wallet must have NO mempool entries");
    log_evidence("checkpoint", "fresh wallet: subscribe from 0, CaughtUp, zero history (B1.2)");

    // ---- Step 3: history leg — fund, MINE, frigate restart (quirk), re-subscribe.
    let txid1 = sp_pay("0.05", &address);
    log_evidence("sp_pay", &format!("history-leg funding tx {txid1}"));
    let mempool = btc(&["getrawmempool"]);
    assert!(
        mempool.as_array().unwrap().iter().any(|t| t == &txid1),
        "txid1 not in mempool after sp-pay"
    );
    let h1 = mine_one();
    log_evidence("mine", &format!("history leg mined to height {h1}"));
    // Rig quirk gate: frigate indexes at process start, from electrs. Restart
    // only after electrs has indexed the mined block, or the history replay
    // permanently misses the pre-fund (this gate was missing in run 16 and
    // produced the confirmed=[] red state).
    wait_electrs_indexed(h1, "history-leg mine");

    restart_frigate();
    // Held subscription must observe the disconnect (B2.4 trigger).
    let ev = next_event(&mut s1, "Disconnected after frigate restart", Duration::from_secs(30)).await;
    assert!(
        matches!(ev, FrigateEvent::Disconnected(_)),
        "expected Disconnected on held subscription after restart, got {ev:?}"
    );
    log_evidence("disconnected", "held subscription observed disconnect after frigate restart (B2.4)");
    drop(s1);

    let mut s2 = connect_scanner(scan_sk, spend_sk, HashMap::new()).await;
    let (tips1, conf2_ops, unconf2, _) = drain_until_caught_up(&mut s2, "history leg").await;
    log_evidence(
        "history_leg",
        &format!("tips={tips1:?} confirmed={conf2_ops:?} unconfirmed={unconf2:?}"),
    );
    assert_eq!(conf2_ops.len(), 1, "history leg must deliver the pre-fund EXACTLY once: {conf2_ops:?}");
    assert!(
        conf2_ops.iter().any(|op| op.starts_with(&format!("{txid1}:"))),
        "confirmed outpoint does not belong to funding tx {txid1}: {conf2_ops:?}"
    );
    assert!(unconf2.is_empty(), "no mempool entries expected in history leg");
    // Tip consistency (B8.5 step 5): frigate tip == bitcoind height within budget.
    let last_tip = *tips1.last().unwrap_or(&0);
    assert_eq!(
        last_tip, h1,
        "frigate tip {last_tip} != bitcoind height {h1} after history replay"
    );
    log_evidence(
        "tip_consistency",
        &format!("frigate tip {last_tip} == bitcoind {h1} (within {:?})", TIP_BUDGET),
    );

    // ---- Step 4: mempool leg — subscription HELD, conformant payment MUST push.
    // The historical "no-push quirk" was an artifact of sp-pay's non-conformant
    // transactions; with a conformant sender (sp-faucet), frigate 1.4.1 pushes
    // Unconfirmed on the held subscription, as the Dana spec (phase-2) requires.
    let txid2 = sp_pay("0.02", &address);
    log_evidence("sp_pay", &format!("mempool-leg payment tx {txid2} (subscription held)"));
    let ev = next_event(&mut s2, "Unconfirmed push on held subscription", Duration::from_secs(12)).await;
    assert!(
        matches!(&ev, FrigateEvent::Unconfirmed { txid, .. } if txid.to_string() == txid2),
        "held subscription must be pushed Unconfirmed for the mempool payment, got {ev:?}"
    );
    log_evidence("mempool_push", "held subscription received Unconfirmed push for the mempool payment (phase-2 contract)");

    restart_frigate();
    let ev = next_event(&mut s2, "Disconnected after 2nd restart", Duration::from_secs(30)).await;
    assert!(
        matches!(ev, FrigateEvent::Disconnected(_)),
        "expected Disconnected on held subscription, got {ev:?}"
    );
    drop(s2);

    let mut s3 = connect_scanner(scan_sk, spend_sk, HashMap::new()).await;
    // Watch for Unconfirmed(txid2) delivered in/from the subscribe response,
    // then the history replay (Confirmed txid1 again) and CaughtUp.
    let mut unconfirmed2_seen = 0usize;
    let mut confirmed_txid1 = 0usize;
    let mut confirmed_txid2 = 0usize;
    let mut candidate_script_hex: Option<String> = None;
    let mut caught_up = false;
    let deadline = Instant::now() + Duration::from_secs(240);
    while !caught_up && Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_secs(60), s3.next()).await {
            Ok(Some(FrigateEvent::Unconfirmed { txid, discovered_outputs })) => {
                assert_eq!(txid.to_string(), txid2, "unexpected mempool entry {txid}");
                unconfirmed2_seen += 1;
                for (_op, dout) in &discovered_outputs {
                    candidate_script_hex = Some(dout.txout.script_pubkey.to_hex_string());
                }
                log_evidence(
                    "unconfirmed",
                    &format!("re-subscribe delivered mempool entry {txid} (height<=0 leg, B4.1 input)"),
                );
            }
            Ok(Some(FrigateEvent::Confirmed(sr))) => {
                for (op, dout) in &sr.discovered_outputs {
                    if op.txid.to_string() == txid1 {
                        confirmed_txid1 += 1;
                    }
                    if op.txid.to_string() == txid2 {
                        confirmed_txid2 += 1;
                    }
                    if candidate_script_hex.is_none() {
                        candidate_script_hex = Some(dout.txout.script_pubkey.to_hex_string());
                    }
                }
                log_evidence(
                    "confirmed",
                    &format!("re-subscribe history replay: {} output(s)", sr.discovered_outputs.len()),
                );
            }
            Ok(Some(FrigateEvent::Tip { height, .. })) => {
                log_evidence("tip", &format!("Tip {}", height.to_consensus_u32()));
            }
            Ok(Some(FrigateEvent::CaughtUp)) => {
                caught_up = true;
                log_evidence("caught_up", "re-subscribe leg reached CaughtUp");
            }
            Ok(Some(other)) => log_evidence("event", &format!("{other:?}")),
            Ok(None) => panic!("re-subscribe stream ended before CaughtUp"),
            Err(_) => panic!("timeout waiting for re-subscribe events"),
        }
    }
    assert!(caught_up, "re-subscribe leg never reached CaughtUp");
    assert_eq!(
        unconfirmed2_seen, 1,
        "mempool entry must be delivered EXACTLY once on re-subscribe (B3.4)"
    );
    assert_eq!(
        confirmed_txid1, 1,
        "history replay must re-deliver txid1 exactly once per connection (dedupe is Dart-side, B2.4/B3.4)"
    );
    assert_eq!(
        confirmed_txid2, 0,
        "txid2 is still in the mempool — must NOT be reported as Confirmed"
    );

    let script_hex = candidate_script_hex.expect("candidate script hex from Unconfirmed event");
    log_evidence("candidate_script", &format!("{{\"txid\":\"{txid2}\",\"script\":\"{script_hex}\"}}"));
    log_evidence(
        "wire_summary",
        &format!("{{\"steps\":\"1-5 OK\",\"txid1\":\"{txid1}\",\"txid2\":\"{txid2}\",\"h0\":{h0},\"h1\":{h1}}}"),
    );

    // ---- Step 6: graduation — mine one block while the subscription is
    // HELD. Contract-conformant expectation (D3: graduation is electrum-side;
    // frigate 1.4.1 ENDS the event stream when a watched mempool tx mines —
    // it does not push Confirmed on the held stream).
    log_evidence("holding", "subscription held; mining graduation block");
    let miner = std::thread::spawn(|| {
        std::thread::sleep(Duration::from_secs(8));
        let h2 = mine_one();
        log_evidence("mine", &format!("graduation leg mined to height {h2}"));
        wait_electrs_indexed(h2, "graduation mine");
        h2
    });
    let mut disconnected_seen = false;
    let deadline = Instant::now() + Duration::from_secs(120);
    while !disconnected_seen && Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_secs(10), s3.next()).await {
            Ok(Some(FrigateEvent::Disconnected(_))) => {
                log_evidence("event", "Disconnected on held stream after graduation mining (documented mining-time behavior)");
                disconnected_seen = true;
            }
            Ok(Some(FrigateEvent::Confirmed(sr))) => {
                let ops: Vec<String> = sr
                    .discovered_outputs
                    .keys()
                    .map(|op| format!("{}:{}", op.txid, op.vout))
                    .collect();
                log_evidence("confirmed_live", &format!("held scanner: {ops:?}"));
            }
            Ok(Some(other)) => log_evidence("event", &format!("{other:?}")),
            Ok(None) => {
                log_evidence("stream_end", "held subscription stream ended");
                disconnected_seen = true;
            }
            Err(_) => {} // quiet window
        }
    }
    assert!(
        disconnected_seen,
        "graduation: held stream neither pushed Confirmed nor ended within budget"
    );
    let h2 = miner.join().expect("miner thread");

    // Replay leg: a fresh subscription must deliver Confirmed(txid1) and
    // Confirmed(txid2) each EXACTLY once, with no Unconfirmed(txid2) line.
    std::thread::sleep(Duration::from_secs(10)); // let frigate settle on the new tip
    let mut s4 = connect_scanner(scan_sk, spend_sk, HashMap::new()).await;
    let mut confirmed_txid1_replay = 0usize;
    let mut confirmed_txid2_replay = 0usize;
    let mut unconfirmed_after_graduation = 0usize;
    let mut caught_up = false;
    let deadline = Instant::now() + Duration::from_secs(240);
    while !caught_up && Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_secs(60), s4.next()).await {
            Ok(Some(FrigateEvent::Tip { height, .. })) => {
                log_evidence("tip", &format!("Tip {}", height.to_consensus_u32()));
            }
            Ok(Some(FrigateEvent::Confirmed(sr))) => {
                for (op, _dout) in &sr.discovered_outputs {
                    if op.txid.to_string() == txid1 {
                        confirmed_txid1_replay += 1;
                    }
                    if op.txid.to_string() == txid2 {
                        confirmed_txid2_replay += 1;
                    }
                }
                log_evidence(
                    "confirmed",
                    &format!("replay history: {} output(s)", sr.discovered_outputs.len()),
                );
            }
            Ok(Some(FrigateEvent::Unconfirmed { txid, .. })) => {
                if txid.to_string() == txid2 {
                    unconfirmed_after_graduation += 1;
                }
                log_evidence("event", &format!("Unconfirmed {txid} in replay"));
            }
            Ok(Some(FrigateEvent::CaughtUp)) => {
                caught_up = true;
                log_evidence("caught_up", "replay leg reached CaughtUp");
            }
            Ok(Some(other)) => log_evidence("event", &format!("{other:?}")),
            Ok(None) => panic!("replay stream ended before CaughtUp"),
            Err(_) => panic!("timeout waiting for replay events"),
        }
    }
    assert!(caught_up, "replay leg never reached CaughtUp");
    assert_eq!(
        confirmed_txid1_replay, 1,
        "replay must deliver Confirmed(txid1) exactly once (dedupe is Dart-side)"
    );
    assert_eq!(
        confirmed_txid2_replay, 1,
        "replay must deliver Confirmed(txid2) exactly once (scanner-side input; graduation itself is electrum-side per D3)"
    );
    assert_eq!(
        unconfirmed_after_graduation, 0,
        "unconfirmed line must be gone after graduation (B4.2/B8.1)"
    );
    log_evidence(
        "wire_summary",
        &format!("{{\"steps\":\"1-6 OK\",\"txid1\":\"{txid1}\",\"txid2\":\"{txid2}\",\"h0\":{h0},\"h1\":{h1},\"h2\":{h2}}}"),
    );
    log_evidence("verdict", "B8.1 steps 1-6 PASS against spec @ d7f275d7 (wire level)");
    drop(s4);
    log_evidence("done", "acceptance driver finished");
}

// ---------------------------------------------------------------------------
// Device-UI acceptance leg (t_66016976) — closes the acceptance loop AT THE UI.
//
// The wire-level tests above stop at "receipts in owned_outputs", which was
// green on 2026-11-25 while the phone screen showed balance 0 (both bugs lived
// between DB-correct and UI-reflects-it). This leg drives the on-device
// Transact tab over adb (Pixel 6a emulator rig) via the python driver
// `rust/tests/rig_b81_device_ui.py` and is part of this acceptance script's
// PASS criteria: a DB-green/UI-zero run FAILS the acceptance, not just warns.
//
// Stages (env RIG_B81_UI_STAGE, default `full`):
//   control — positive control on a stale-UI build: pay, mine, verify the DB
//     receipt lands (DB-green), then REQUIRE the UI assertion to FAIL. If the
//     UI ever reflects the payment, the control is useless and this test
//     fails — the alarm that the assertion no longer bites.
//   full — faucet payment -> DB receipt -> UI balance>0 + incoming tx visible
//     LIVE (no restart; the 4494028 class) -> survives app kill + relaunch
//     with the balance intact.
//
// Run (code host, rig up, device attached, dev package installed):
//   RIG_B81_UI_STAGE=control cargo test --test rig_b81_acceptance \
//     rig_b81_device_ui -- --ignored --nocapture
//   RIG_B81_UI_STAGE=full   cargo test --test rig_b81_acceptance \
//     rig_b81_device_ui -- --ignored --nocapture
// ---------------------------------------------------------------------------

#[test]
#[ignore = "requires the regtest rig AND the emulator device over adb (Pixel 6a rig)"]
fn rig_b81_device_ui_acceptance() {
    let stage = std::env::var("RIG_B81_UI_STAGE").unwrap_or_else(|_| "full".into());
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/rig_b81_device_ui.py");
    let out = Command::new("python3")
        .arg(script)
        .arg("--stage")
        .arg(&stage)
        .output()
        .expect("spawn device-UI driver (python3)");
    println!("--- rig_b81_device_ui.py (stage {stage}) ---");
    print!("{}", String::from_utf8_lossy(&out.stdout));
    eprint!("{}", String::from_utf8_lossy(&out.stderr));
    assert!(
        out.status.success(),
        "device-UI acceptance leg FAILED (stage {stage}): the UI assertion must \
         bite on a stale-UI build (control) and the full chain payment -> DB \
         receipt -> live UI balance>0 + incoming tx -> intact after restart \
         must hold on the acceptance build"
    );
}
