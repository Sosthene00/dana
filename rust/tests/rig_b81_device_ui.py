#!/usr/bin/env python3
"""B8.1 device-UI acceptance step (rig_b81_acceptance companion, t_66016976).

Closes the rig acceptance loop AT THE UI: the wire-level rig_b81_acceptance
test stops at "receipts in owned_outputs", which was green on 2026-11-25 while
the phone screen showed balance 0 (the DB-correct / UI-reflects-it gap). This
driver asserts the Transact tab on the device over adb, so a DB-green/UI-zero
run FAILS the acceptance instead of warning.

Stages (choose with --stage):
  snapshot  print the current Transact-tab state (balance, funding screen,
            incoming rows, DB receipt count) and exit.
  control   positive control on a STALE-UI build: pay the wallet, mine,
            verify the DB receipt lands (DB-green), then REQUIRE the UI
            assertion to FAIL (balance unchanged / no incoming row). If the
            UI reflects the payment, the control is useless -> exit 1.
  full      the acceptance leg on the fixed build: pay, mine, DB receipt,
            then REQUIRE the UI to reflect it LIVE (no restart): balance up
            by the paid amount AND the incoming row visible; then force-stop
            + relaunch and REQUIRE the balance intact. Any miss -> exit 1.

PASS criteria wired into the acceptance script (see rig_b81_acceptance.rs):
  faucet payment -> DB receipt -> UI balance>0 + incoming tx visible ->
  survives app kill + relaunch with balance intact.
The control stage is the regression alarm: on a build with pre-4494028
semantics (DB written, UI never repainted) the full stage's live assertion
fails exactly like this control proves it can.

Usage (on the code host, rig up, device attached):
  python3 rust/tests/rig_b81_device_ui.py --stage control --serial emulator-5556
  python3 rust/tests/rig_b81_device_ui.py --stage full   --serial emulator-5556

The wallet address is taken from --address or extracted from the Transact-tab
funding screen (fresh zero-balance wallet). Evidence (UI dumps, screencaps,
jsonl log) lands in --evidence-dir (default /tmp/ut-t66016976-evidence).
"""

import argparse
import json
import re
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

ADB = "/opt/android-sdk/platform-tools/adb"
BTC_CLI = ["bitcoin-cli", "-datadir=/home/hermes/regtest-frigate/bitcoind"]
SP_FAUCET = "/home/hermes/tools/sp-faucet/sp_faucet/target/release/sp_faucet"
SP_FAUCET_CWD = "/home/hermes/tools/sp-faucet/sp_faucet"
ELECTRS = "127.0.0.1:60401"
DB_NAME = "dana.db"
UI_STABLE = 5000  # populated Flutter dump threshold (bytes); funding screen ~7909

BTC_RE = re.compile(r"^₿\s?([\d .,]+)$")
SAT_RE = re.compile(r"^[\uE007\ue000]\s?([\d .,]+)$")


def log(ev, detail):
    line = f"{datetime.now(timezone.utc).isoformat()} {ev}: {detail}"
    print(f"[{ev}] {detail}", flush=True)
    with open(f"{ARGS.evidence_dir}/ui_leg.jsonl", "a") as f:
        f.write(json.dumps({"ts": time.time(), "kind": ev, "detail": detail}) + "\n")


def adb(serial, *args, check=True, binary=False):
    r = subprocess.run([ADB, "-s", serial] + list(args),
                       capture_output=True, text=not binary)
    if check and r.returncode != 0:
        raise RuntimeError(f"adb {args} rc={r.returncode}: {r.stderr.strip()}")
    return r.stdout


def dump_xml(serial):
    """uiautomator dump with the Flutter empty-at-launch nudge retry."""
    xml = ""
    for _ in range(5):
        adb(serial, "shell", "uiautomator", "dump", "/sdcard/ui.xml", check=False)
        xml = adb(serial, "shell", "cat", "/sdcard/ui.xml", check=False)
        if "<hierarchy" in xml and len(xml) > UI_STABLE:
            return xml
        adb(serial, "shell", "input", "swipe", "540", "1500", "540", "1400", "200",
            check=False)
        time.sleep(2)
    raise RuntimeError(f"UI dump never populated (len={len(xml)}); app on the "
                       f"Transact tab? last dump kept in evidence dir")


def screencap(serial, name):
    adb(serial, "shell", "screencap", "-p", "/sdcard/ev.png", check=False)
    adb(serial, "pull", "/sdcard/ev.png", f"{ARGS.evidence_dir}/{name}.png",
        check=False)


def node_texts(xml):
    out = []
    for m in re.finditer(r"<node[^>]*>", xml):
        n = m.group(0)
        t = re.search(r' text="([^"]*)"', n)
        d = re.search(r' content-desc="([^"]*)"', n)
        txt = (t.group(1) if t else "") or (d.group(1) if d else "")
        txt = txt.replace("&#10;", " ")
        if txt.strip():
            out.append(txt.strip())
    return out


def parse_sats(txt):
    m = re.search(r"₿\s?([0-9.][0-9. ]*)", txt)
    if m:
        dec = m.group(1).strip().replace(" ", "")
        if "." in dec:
            whole, frac = dec.split(".", 1)
        else:
            whole, frac = dec, ""
        return int(whole) * 100_000_000 + int(frac.ljust(8, "0")[:8])
    m = SAT_RE.match(txt)
    if m:
        return int(m.group(1).replace(" ", "").replace(",", ""))
    return None


def snapshot_state(serial):
    xml = dump_xml(serial)
    with open(f"{ARGS.evidence_dir}/dump-{time.time():.0f}.xml", "w") as f:
        f.write(xml)
    texts = node_texts(xml)
    st = {"funding_screen": any("Fund your wallet" in t for t in texts),
          "balance_sats": None,
          "incoming_rows": sum(t.startswith("Incoming") for t in texts),
          "sp_address": None, "texts": texts}
    for t in texts:
        if st["sp_address"] is None and t.startswith(("sprt1q", "sp1q", "tsp1q")):
            st["sp_address"] = t.replace(" ", "")
        # the balance node merges the fiat line ('₿ 0.04 000 000\n$ ---') —
        # first ₿-bearing node in dump order is the main balance display
        if st["balance_sats"] is None and "₿" in t:
            v = parse_sats(t)
            if v is not None:
                st["balance_sats"] = v
    if st["funding_screen"]:
        st["balance_sats"] = 0
    return st


def db_receipts(serial, pkg):
    """Pull dana.db (+wal) via run-as and report receipt count / sum(amount_sat)."""
    import tempfile, os
    with tempfile.TemporaryDirectory() as td:
        for suffix in ["", "-wal", "-shm"]:
            data = adb(serial, "shell", "run-as", pkg,
                       "cat", f"databases/{DB_NAME}{suffix}", check=False,
                       binary=True)
            with open(os.path.join(td, DB_NAME + suffix), "wb") as f:
                f.write(data if isinstance(data, bytes) else data.encode())
        con = sqlite3.connect(os.path.join(td, DB_NAME))
        n = con.execute("SELECT count(*), coalesce(sum(amount_sat),0) "
                        "FROM owned_outputs").fetchone()
    return {"receipts": n[0], "amount_sat_sum": n[1]}


def btc_json(args):
    r = subprocess.run(BTC_CLI + args, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"bitcoin-cli {args}: {r.stderr.strip()}")
    return json.loads(r.stdout)


def btc_height():
    return btc_json(["-rpcwallet=miner", "getblockchaininfo"])["blocks"]


def mine_one():
    r = subprocess.run(BTC_CLI + ["-rpcwallet=miner", "getnewaddress", "",
                                  "bech32"], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"getnewaddress: {r.stderr.strip()}")
    addr = r.stdout.strip().splitlines()[-1]
    btc_json(["-rpcwallet=miner", "generatetoaddress", "1", addr])
    return btc_height()


def electrs_tip():
    # server.version first (frigate/electrs wire contract), then headers.subscribe
    try:
        _rpc(ELECTRS, "server.version", ["rig_b81_ui", "1.0"])
        r = _rpc(ELECTRS, "blockchain.headers.subscribe", [])
        return r["result"]["height"]
    except Exception as e:
        log("electrs_err", repr(e))
        return -1


def _rpc(host, method, params, timeout=8):
    import socket
    s = socket.create_connection((host.split(":")[0], int(host.split(":")[1])),
                                 timeout=timeout)
    s.settimeout(timeout)
    s.sendall((json.dumps({"jsonrpc": "2.0", "id": 0, "method": method,
                           "params": params}) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf.splitlines()[0])


def wait_electrs_indexed(height, budget=90):
    deadline = time.time() + budget
    while time.time() < deadline:
        tip = electrs_tip()
        if tip >= height:
            log("electrs_indexed", f"tip {tip} >= {height}")
            return tip
        time.sleep(2)
    raise RuntimeError(f"electrs tip never reached {height}")


def sp_pay(address, sats):
    import os
    env = dict(os.environ)
    env.setdefault("SP_FAUCET_RPC_USERPASS",
                   "frigate:ceeec00f4a1b8a4bcb6c33814430b706")
    env.setdefault("SP_FAUCET_WALLET", "miner")
    r = subprocess.run([SP_FAUCET, address, str(sats)], cwd=SP_FAUCET_CWD,
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"sp-faucet failed: {r.stderr.strip()} {r.stdout.strip()}")
    return r.stdout.strip()


def wait_db_at_least(db0, sats, budget=240):
    deadline = time.time() + budget
    last = db0
    while time.time() < deadline:
        last = db_receipts(ARGS.serial, ARGS.pkg)
        if last["receipts"] > db0["receipts"] and \
           last["amount_sat_sum"] >= db0["amount_sat_sum"] + sats:
            log("db_receipt", f"DB-green: {last}")
            return last
        time.sleep(5)
    raise RuntimeError(f"DB receipt never landed (last={last}) — frigate "
                       f"pipeline did not deliver; this is a rig-level failure")


def wait_ui(serial, pred, budget, what):
    deadline = time.time() + budget
    st = snapshot_state(serial)
    while time.time() < deadline:
        if pred(st):
            log("ui_ok", f"{what}: {st['balance_sats']} sats, "
                         f"incoming={st['incoming_rows']}, funding={st['funding_screen']}")
            return st
        time.sleep(6)
        st = snapshot_state(serial)
    log("ui_stale", f"{what} NEVER reflected: balance={st['balance_sats']} sats, "
                    f"incoming={st['incoming_rows']}, funding={st['funding_screen']}")
    screencap(serial, f"stale-{time.time():.0f}")
    return st


def restart_app(serial, pkg):
    adb(serial, "shell", "am", "force-stop", pkg)
    time.sleep(3)
    adb(serial, "shell", "monkey", "-p", pkg,
        "-c", "android.intent.category.LAUNCHER", "1", check=False)
    deadline = time.time() + 90
    while time.time() < deadline:
        try:
            st = snapshot_state(serial)
            if any("Transact" in t for t in st["texts"]):
                log("relaunched", "app back on the Transact tab")
                return st
        except RuntimeError:
            pass
        time.sleep(5)
    raise RuntimeError("app did not come back to the Transact tab after relaunch")


def logcat_hygiene(serial):
    out = adb(serial, "logcat", "-d", check=False)
    bad = {p: len(re.findall(p, out)) for p in
           ["subscription ended", "re-subscribing", "stream ended",
            "Uncaught exception|FATAL EXCEPTION"]}
    log("logcat_hygiene", json.dumps(bad))
    return bad


def baseline(serial, budget=90, what="baseline"):
    """Poll until the wallet screen actually renders (balance parsed or the
    funding screen present) — the skeleton/loading state parses as None."""
    deadline = time.time() + budget
    try:
        st = snapshot_state(serial)
    except RuntimeError:
        st = {"balance_sats": None, "funding_screen": False,
              "incoming_rows": 0, "sp_address": None, "texts": []}
    if not any("Transact" in t for t in st["texts"]):
        log(what, "no Transact tab visible — (re)launching the app")
        restart_app(serial, ARGS.pkg)
        st = snapshot_state(serial)
    while time.time() < deadline and st["balance_sats"] is None \
            and not st["funding_screen"]:
        time.sleep(5)
        st = snapshot_state(serial)
    log(what, f"balance={st['balance_sats']} funding={st['funding_screen']} "
              f"incoming={st['incoming_rows']}")
    if st["balance_sats"] is None and not st["funding_screen"]:
        raise RuntimeError(f"{what}: wallet screen never rendered a parsable "
                           f"state; texts={st['texts'][:12]}")
    return st


def resolve_address(st):
    import os
    cache = f"{ARGS.evidence_dir}/address.txt"
    if ARGS.address:
        return ARGS.address
    if os.environ.get("RIG_B81_UI_ADDRESS"):
        return os.environ["RIG_B81_UI_ADDRESS"]
    if st["sp_address"]:
        with open(cache, "w") as f:
            f.write(st["sp_address"] + "\n")
        return st["sp_address"]
    if os.path.exists(cache):
        return open(cache).read().strip()
    raise RuntimeError("no --address / RIG_B81_UI_ADDRESS, no funding screen, "
                       "and no cached address")


def stage_control():
    st0 = baseline(ARGS.serial, what="snap0")
    addr = resolve_address(st0)
    sats = ARGS.sats
    db0 = db_receipts(ARGS.serial, ARGS.pkg)
    log("db0", str(db0))
    adb(ARGS.serial, "logcat", "-c", check=False)

    txid = sp_pay(addr, sats)
    log("paid", f"{sats} sats -> {addr} txid={txid}")
    h = mine_one()
    log("mined", f"tip {h}")
    wait_electrs_indexed(h)
    db1 = wait_db_at_least(db0, sats)  # DB-green: receipt is IN owned_outputs

    # Give the stale build every chance: poll the UI for the full window.
    st1 = wait_ui(ARGS.serial,
                  lambda s: (s["balance_sats"] or 0) >= st0["balance_sats"] + sats
                  and s["incoming_rows"] > st0["incoming_rows"],
                  ARGS.ui_budget, "control UI assertion (balance up + incoming)")
    reflected = (st1["balance_sats"] or 0) >= st0["balance_sats"] + sats \
        and st1["incoming_rows"] > st0["incoming_rows"]
    logcat_hygiene(ARGS.serial)
    if reflected:
        log("control_useless", "UI reflected the payment on this build — the "
                               "assertion did NOT bite; positive control FAILED")
        sys.exit(1)
    log("control_bites", f"DB-green ({db1}) but UI-zero/stale — the device-UI "
                         f"assertion FAILS this build, exactly as required")
    sys.exit(0)


def stage_full():
    # Clean baseline: force-stop + relaunch first (the APK install kills the
    # process; on the fixed build this relaunch also repaints prior DB
    # receipts — the pre-4494028 gap only on the stale build).
    st0 = baseline(ARGS.serial, what="snap0")
    addr = resolve_address(st0)
    sats = ARGS.sats
    db0 = db_receipts(ARGS.serial, ARGS.pkg)
    log("db0", str(db0))
    adb(ARGS.serial, "logcat", "-c", check=False)

    # 1. faucet payment -> mine -> frigate pipeline delivers -> DB receipt
    txid = sp_pay(addr, sats)
    log("paid", f"{sats} sats -> {addr} txid={txid}")
    h = mine_one()
    log("mined", f"tip {h}")
    wait_electrs_indexed(h)
    db1 = wait_db_at_least(db0, sats)

    # 2. LIVE UI assertion (no restart): balance up AND incoming row visible
    st1 = wait_ui(ARGS.serial,
                  lambda s: (s["balance_sats"] or 0) >= st0["balance_sats"] + sats
                  and s["incoming_rows"] > st0["incoming_rows"],
                  ARGS.ui_budget, "live UI repaint")
    if not ((st1["balance_sats"] or 0) >= st0["balance_sats"] + sats
            and st1["incoming_rows"] > st0["incoming_rows"]):
        log("FAIL", "DB-green but UI did NOT reflect the payment live "
                    "(4494028 class) — acceptance FAILED")
        sys.exit(1)
    live_balance = st1["balance_sats"]

    # 3. survives app kill + relaunch with balance intact
    st2 = restart_app(ARGS.serial, ARGS.pkg)
    if st2["balance_sats"] != live_balance or st2["funding_screen"]:
        log("FAIL", f"balance not intact after relaunch: pre={live_balance} "
                    f"post={st2['balance_sats']} funding={st2['funding_screen']}")
        sys.exit(1)
    logcat_hygiene(ARGS.serial)
    log("PASS", f"full chain OK: paid {sats} sats -> DB {db1} -> live UI "
                f"{live_balance} sats with incoming row -> intact after restart "
                f"({st2['balance_sats']} sats)")
    screencap(ARGS.serial, "final")
    sys.exit(0)


def stage_snapshot():
    st = snapshot_state(ARGS.serial)
    db = db_receipts(ARGS.serial, ARGS.pkg)
    log("snapshot", json.dumps({k: v for k, v in st.items() if k != "texts"}))
    log("db", str(db))
    print(json.dumps({k: v for k, v in st.items() if k != "texts"}, indent=2))
    print(json.dumps(db))


def main():
    global ARGS
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stage", choices=["snapshot", "control", "full"],
                    required=True)
    ap.add_argument("--serial", default="emulator-5556")
    ap.add_argument("--pkg", default="dev.silentpayments.danawallet.dev")
    ap.add_argument("--address", default=None,
                    help="wallet SP address; default: extract from funding screen")
    ap.add_argument("--amount-btc", type=float, default=0.02)
    ap.add_argument("--ui-budget", type=int, default=90,
                    help="seconds to poll the UI before declaring it stale")
    ap.add_argument("--evidence-dir", default="/tmp/ut-t66016976-evidence")
    ARGS = ap.parse_args()
    ARGS.sats = int(round(ARGS.amount_btc * 100_000_000))
    import os
    os.makedirs(ARGS.evidence_dir, exist_ok=True)
    log("stage", f"{ARGS.stage} serial={ARGS.serial} pkg={ARGS.pkg} "
                 f"sats={ARGS.sats}")
    {"snapshot": stage_snapshot, "control": stage_control,
     "full": stage_full}[ARGS.stage]()


if __name__ == "__main__":
    main()
