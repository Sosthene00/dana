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
  forcestop the B8.3 kill-window acceptance (t_99f8cc8d; B2.5 + B7.1/B7.2
            device legs): confirmed receipt visible at the UI, then
            `am force-stop` (app AND service die together), a payment mined
            INSIDE the kill window + frigate restarted per the rig quirk
            (B8.5 step 7), relaunch -> REQUIRE service re-establishment
            (B2.5), no lost receipts (B7.1: pre-kill receipts still at the
            UI and in the DB, kill-window payment delivered via history
            replay), writer-lease takeover without a stale-lease block
            (B7.2: fresh lease row + writes resumed), then a NEW payment
            after relaunch lands and graduates normally. Any miss -> exit 1.
  forcestop-control
            positive control for the forcestop leg: same shape up to the
            force-stop, then CORRUPT the writer-lease record in dana.db
            (foreign writer with a far-future heartbeat — permanently
            "fresh"), relaunch and REQUIRE the DB-receipt assertion to FAIL
            (the poisoned lease must stand the write path down, B2.8, so
            the kill-window payment never lands). If the receipt lands
            anyway, the assertions do not bite -> exit 1. Restores the
            lease record afterwards so later runs start clean.

PASS criteria wired into the acceptance script (see rig_b81_acceptance.rs):
  faucet payment -> DB receipt -> UI balance>0 + incoming tx visible ->
  survives app kill + relaunch with balance intact.
The control stage is the regression alarm: on a build with pre-4494028
semantics (DB written, UI never repainted) the full stage's live assertion
fails exactly like this control proves it can.

Usage (on the code host, rig up, device attached):
  python3 rust/tests/rig_b81_device_ui.py --stage control --serial emulator-5556
  python3 rust/tests/rig_b81_device_ui.py --stage full   --serial emulator-5556
  python3 rust/tests/rig_b81_device_ui.py --stage forcestop --serial emulator-5556 \
      --evidence-dir /tmp/ut-t99f8cc8d-evidence
  python3 rust/tests/rig_b81_device_ui.py --stage forcestop-control --serial emulator-5556 \
      --evidence-dir /tmp/ut-t99f8cc8d-evidence

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
FRIGATE = "127.0.0.1:50002"  # regtest frigate instance (rig quirk: history indexed at process start)
FRIGATE_BIN = "/home/hermes/tools/frigate-1.4.1/frigate/bin/frigate"
FRIGATE_ARGS = ["--dir", "/home/hermes/.frigate-regtest", "-n", "regtest", "-l", "INFO"]
FRIGATE_PGREP = "frigate/bin/frigate.real --dir /home/hermes/.frigate-regtest"
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


def save_logcat(serial, name):
    out = adb(serial, "logcat", "-d", check=False)
    with open(f"{ARGS.evidence_dir}/{name}.log", "w") as f:
        f.write(out)
    return out


def app_pid(serial, pkg):
    return adb(serial, "shell", "pidof", pkg, check=False).strip()


def pull_db(serial, pkg, dest_dir):
    """Pull dana.db (+wal+shm) to dest_dir; returns the local main-db path."""
    import os
    os.makedirs(dest_dir, exist_ok=True)
    for suffix in ["", "-wal", "-shm"]:
        data = adb(serial, "shell", "run-as", pkg, "cat",
                   f"databases/{DB_NAME}{suffix}", check=False, binary=True)
        if isinstance(data, str):
            data = data.encode()
        with open(os.path.join(dest_dir, DB_NAME + suffix), "wb") as f:
            f.write(data)
    return os.path.join(dest_dir, DB_NAME)


def push_db(serial, pkg, local_db):
    """Push a locally-edited dana.db back (app MUST be force-stopped) and
    drop the stale device-side wal/shm so the pushed image is authoritative.
    Scoped storage blocks /sdcard reads for the app uid, so the bytes go
    through adb-stdin into `run-as sh -c 'cat > databases/dana.db'` (the
    quoted payload must ride ONE adb argument — adb joins argv with spaces
    and the device shell re-parses the quotes)."""
    import subprocess
    with open(local_db, "rb") as f:
        subprocess.run([ADB, "-s", serial, "shell", "run-as", pkg,
                        f"sh -c 'cat > databases/{DB_NAME}'"],
                       stdin=f, capture_output=True, text=True, check=True)
    adb(serial, "shell", "run-as", pkg, "rm", "-f",
        f"databases/{DB_NAME}-wal", f"databases/{DB_NAME}-shm")


def db_lease(serial, pkg):
    """The writer_lease row (B2.8) as {writer_id, heartbeat_ms, age_ms} or None."""
    import tempfile, os
    with tempfile.TemporaryDirectory() as td:
        path = pull_db(serial, pkg, td)
        con = sqlite3.connect(path)
        try:
            row = con.execute("SELECT writer_id, heartbeat_ms FROM writer_lease "
                              "WHERE id = 1").fetchone()
        except sqlite3.OperationalError:
            row = None
        con.close()
    if row is None:
        return None
    return {"writer_id": row[0], "heartbeat_ms": row[1],
            "age_ms": int(time.time() * 1000) - row[1]}


def edit_lease(serial, pkg, mode):
    """Corrupt/clear the writer_lease row (id=1) in dana.db on the device.
    mode='poison': foreign writer with a far-future heartbeat — permanently
    'fresh' under the B2.8 staleness rule, so NO process may take over and
    every ensureOwnership() stands the write path down. mode='restore':
    delete the row (next writer acquires immediately). App must be dead."""
    d = f"{ARGS.evidence_dir}/dbedit"
    path = pull_db(serial, pkg, d)
    con = sqlite3.connect(path)
    now = int(time.time() * 1000)
    if mode == "poison":
        con.execute(
            "INSERT INTO writer_lease(id, writer_id, heartbeat_ms) VALUES(1, 'ghost-writer', ?) "
            "ON CONFLICT(id) DO UPDATE SET writer_id='ghost-writer', heartbeat_ms=excluded.heartbeat_ms",
            (now + 3_600_000,))
    elif mode == "restore":
        con.execute("DELETE FROM writer_lease WHERE id = 1")
    else:
        raise ValueError(mode)
    con.commit()
    con.close()
    push_db(serial, pkg, path)
    log("lease_" + mode, f"writer_lease row {mode}d via run-as db edit")


def frigate_pids():
    r = subprocess.run(["pgrep", "-f", FRIGATE_PGREP], capture_output=True, text=True)
    return [int(l) for l in r.stdout.split() if l.strip().isdigit()]


def frigate_port_open():
    import socket
    try:
        socket.create_connection(("127.0.0.1", 50002), timeout=2).close()
        return True
    except OSError:
        return False


def frigate_tip():
    # wire contract: server.version FIRST on the SAME connection, then
    # headers.subscribe (frigate 1.4.1 rejects headers.subscribe as the
    # first message). Response shape is loose — no int height = "no tip".
    try:
        import socket
        s = socket.create_connection(("127.0.0.1", 50002), timeout=8)
        s.settimeout(8)
        reqs = [json.dumps({"jsonrpc": "2.0", "id": 0, "method": "server.version",
                            "params": ["rig_b83_ui", "1.0"]}),
                json.dumps({"jsonrpc": "2.0", "id": 1, "method":
                            "blockchain.headers.subscribe", "params": []})]
        buf = b""
        for req in reqs:
            s.sendall((req + "\n").encode())
            while buf.count(b"\n") < (1 if req is reqs[0] else 2):
                chunk = s.recv(4096)
                if not chunk:
                    break
                buf += chunk
        s.close()
        lines = [l for l in buf.decode(errors="replace").splitlines() if l.strip()]
        r = json.loads(lines[-1])
        res = r.get("result") if isinstance(r, dict) else None
        if isinstance(res, dict) and isinstance(res.get("height"), int):
            return res["height"]
        log("frigate_tip_shape", json.dumps(r)[:300])
        return -1
    except Exception as e:
        log("frigate_err", repr(e))
        return -1


def restart_frigate():
    """Rig quirk enabler (B8.5 step 7): restart the regtest frigate instance.
    Gated on electrs having indexed the current bitcoind tip — a restart
    before indexing permanently misses the block (indexed at process start)."""
    pids = frigate_pids()
    if not pids:
        raise RuntimeError("no regtest frigate process found")
    et, bt = electrs_tip(), btc_height()
    if et < bt:
        raise RuntimeError(f"electrs tip {et} < bitcoind {bt}: restarting frigate "
                           f"now would permanently miss a block")
    for pid in pids:
        subprocess.run(["kill", str(pid)], capture_output=True)
    deadline = time.time() + 20
    while frigate_port_open() and time.time() < deadline:
        time.sleep(0.25)
    for pid in pids:
        subprocess.run(["kill", "-9", str(pid)], capture_output=True)
    with open(f"{ARGS.evidence_dir}/frigate-restart.log", "ab") as lf:
        subprocess.Popen([FRIGATE_BIN] + FRIGATE_ARGS, stdout=lf, stderr=lf,
                         start_new_session=True)
    deadline = time.time() + 120
    while not frigate_port_open() and time.time() < deadline:
        time.sleep(0.5)
    if not frigate_port_open():
        raise RuntimeError("frigate did not come back on :50002")
    time.sleep(5)  # listening precedes scan-backend warm; settle before replay
    tip = frigate_tip()
    log("frigate_restart", f"pids {pids} respawned, frigate tip {tip}")
    return tip


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


UI_REFLECT = lambda pre, sats: (lambda s: (s["balance_sats"] or 0) >= pre + sats
                                and s["incoming_rows"] > 0)


def require(cond, msg):
    if not cond:
        log("FAIL", msg)
        sys.exit(1)


def stage_forcestop():
    """B8.3 kill-window acceptance on the device (B2.5 + B7.1/B7.2 legs)."""
    st0 = baseline(ARGS.serial, what="snap0")
    addr = resolve_address(st0)
    sats = ARGS.sats
    db0 = db_receipts(ARGS.serial, ARGS.pkg)
    lease0 = db_lease(ARGS.serial, ARGS.pkg)
    log("pre_state", f"db0={db0} lease={lease0}")
    adb(ARGS.serial, "logcat", "-c", check=False)

    # 1. wallet receiving on frigate: confirmed receipt visible at the UI
    txid = sp_pay(addr, sats)
    log("paid_pre_kill", f"{sats} sats -> {addr} txid={txid}")
    h = mine_one()
    log("mined_pre_kill", f"tip {h}")
    wait_electrs_indexed(h)
    db1 = wait_db_at_least(db0, sats)
    st1 = wait_ui(ARGS.serial, UI_REFLECT(st0["balance_sats"] or 0, sats),
                  ARGS.ui_budget, "pre-kill confirmed receipt at the UI")
    require((st1["balance_sats"] or 0) >= (st0["balance_sats"] or 0) + sats
            and st1["incoming_rows"] > 0,
            f"pre-kill receipt never showed at the UI: {st1['balance_sats']} sats, "
            f"incoming={st1['incoming_rows']}")
    pre_balance = st1["balance_sats"]
    pre_lease = db_lease(ARGS.serial, ARGS.pkg)
    log("pre_kill", f"balance={pre_balance} db={db1} lease={pre_lease}")
    screencap(ARGS.serial, "pre-kill")

    # 2. the kill window: app AND service die together
    adb(ARGS.serial, "shell", "am", "force-stop", ARGS.pkg)
    time.sleep(3)
    require(app_pid(ARGS.serial, ARGS.pkg) == "",
            f"force-stop left a process: pid={app_pid(ARGS.serial, ARGS.pkg)}")
    log("kill_window", f"app force-stopped (pid gone); window opens at tip {btc_height()}")
    adb(ARGS.serial, "logcat", "-c", check=False)

    # 3. payment mined INSIDE the kill window + frigate restart (B8.5 step 7)
    txid2 = sp_pay(addr, sats)
    log("paid_in_window", f"{sats} sats txid={txid2}")
    h2 = mine_one()
    log("mined_in_window", f"tip {h2}")
    wait_electrs_indexed(h2)
    restart_frigate()
    lease_during = db_lease(ARGS.serial, ARGS.pkg)
    log("lease_during_kill", str(lease_during))

    # 4. relaunch: service re-establishment on next start (B2.5)
    st2 = restart_app(ARGS.serial, ARGS.pkg)
    lc = save_logcat(ARGS.serial, "relaunch-logcat")
    sub_hits = len(re.findall(r"subscrib", lc, re.I))
    # B2.8 semantics: the killed writer's lease is stale; the relaunched
    # service renews it once its sync cycle starts. POLL for a fresh lease
    # (a live writer renews every 5 s, so a live lease samples age <= ~6 s).
    lease_post = None
    deadline = time.time() + 90
    while time.time() < deadline:
        lease_post = db_lease(ARGS.serial, ARGS.pkg)
        if lease_post and lease_post["age_ms"] <= 10_000 \
                and lease_post["writer_id"] in ("foreground-service", "app"):
            break
        time.sleep(5)
    log("post_relaunch", f"transact-visible lease={lease_post} "
                         f"logcat-subscribe-hits={sub_hits}")
    require(lease_post is not None and lease_post["age_ms"] <= 10_000
            and lease_post["writer_id"] in ("foreground-service", "app"),
            f"B2.5/B7.2: no fresh writer lease within 90 s of relaunch "
            f"(lease={lease_post}) — service did not re-establish its write path")

    # 5. B7.1 leg: no lost receipts — kill-window payment delivered via
    #    history replay, pre-kill receipts still present. UI observable is
    #    the BALANCE (the tx list caps at 3 rows once history exists —
    #    observed on the rig; balance still repaints live).
    db2 = wait_db_at_least(db1, sats)
    st3 = wait_ui(ARGS.serial,
                  lambda s: (s["balance_sats"] or 0) >= pre_balance + sats,
                  ARGS.ui_budget, "kill-window receipt after relaunch (B7.1)")
    require((st3["balance_sats"] or 0) >= pre_balance + sats,
            f"B7.1: kill-window payment not reflected after relaunch: "
            f"balance={st3['balance_sats']} expected >= {pre_balance + sats}")
    require(st3["incoming_rows"] >= 1,
            f"B7.1: transaction list renders no rows after relaunch: {st3}")
    log("no_lost_receipts", f"pre-kill {pre_balance} + window {sats} = "
                            f"{st3['balance_sats']} sats at the UI, db={db2}, "
                            f"tx-list rows={st3['incoming_rows']} (list caps)")

    # 6. B7.2 leg: fresh start took over the write path cleanly — proven by
    #    the writes above + a fresh lease; now a NEW payment lands + graduates
    txid3 = sp_pay(addr, sats)
    log("paid_post_relaunch", f"{sats} sats txid={txid3}")
    h3 = mine_one()
    log("mined_post_relaunch", f"tip {h3}")
    wait_electrs_indexed(h3)
    db3 = wait_db_at_least(db2, sats)
    st4 = wait_ui(ARGS.serial,
                  lambda s: (s["balance_sats"] or 0) >= st3["balance_sats"] + sats,
                  ARGS.ui_budget, "post-relaunch payment graduation")
    require((st4["balance_sats"] or 0) >= st3["balance_sats"] + sats,
            f"post-relaunch payment never graduated to the UI: "
            f"balance={st4['balance_sats']} expected >= {st3['balance_sats'] + sats}")
    lease_end = None
    deadline = time.time() + 30
    while time.time() < deadline:
        lease_end = db_lease(ARGS.serial, ARGS.pkg)
        if lease_end and lease_end["age_ms"] <= 10_000:
            break
        time.sleep(5)
    require(lease_end is not None and lease_end["age_ms"] <= 10_000,
            f"B7.2: writer lease not fresh after post-relaunch writes "
            f"(lease={lease_end}) — stale lease blocked or lost the write path")
    hyg = logcat_hygiene(ARGS.serial)
    # ISS-004 log hygiene, scoped: this card IS a test of the reconnect path
    # (B2.4/B2.5) and the scripted scenario restarts frigate (rig quirk) and
    # replays history — frigate 1.4.1 ends the stream on each such event, so
    # subscription-ended/re-subscribe/stream-ended occurrences are the
    # EXPECTED reconnect signature and are whitelisted here (recorded, not
    # gated). Uncaught exceptions remain a hard gate. The not-wedged proof
    # is cross-source (ISS-004 rule 3): the app-reported tip must equal the
    # bitcoind tip after the window.
    require(hyg["Uncaught exception|FATAL EXCEPTION"] == 0,
            f"uncaught exceptions in the window: {hyg}")
    log("hygiene_whitelist", f"reconnect signature counts (whitelisted, "
                             f"reconnect path under test): {hyg}")
    # Cross-source tip (ISS-004 rule 3), delivery-anchored: the LAST payment
    # was mined at bitcoind tip h3 and its confirmed receipt is in
    # owned_outputs (db3 above) — a confirmed receipt cannot exist without
    # the wallet having scanned block h3 — and the frigate scanner reports
    # "scan caught up" on the live chain afterwards. ("updating tip:" is a
    # blindbit-ChainState-only line; this rig wallet's blindbit URL is
    # misconfigured — 192.168.1.44:8001, no scheme — so that source can
    # never confirm here; surfaced as a finding, not gated.)
    lc_end = adb(ARGS.serial, "logcat", "-d", check=False)
    caught_up = len(re.findall(r"Frigate scan caught up", lc_end))
    require(caught_up >= 1,
            f"cross-source tip check: no 'Frigate scan caught up' after the "
            f"final mine — wallet wedged below tip {h3}")
    require(db3["receipts"] > db2["receipts"],
            f"cross-source tip check: receipt for the payment mined at tip "
            f"{h3} never landed (db {db2} -> {db3})")
    log("tip_equality", f"payment mined at bitcoind tip {h3} delivered as a "
                        f"confirmed receipt ({db3}) and scanner caught up "
                        f"({caught_up} lines) — wallet tip >= {h3} == bitcoind tip")
    obs = re.findall(r"updating tip: (\d+)", lc_end)
    note = "none (blindbit URL misconfigured on this rig wallet)" if not obs else str(obs)
    log("app_tip_note", f"blindbit 'updating tip' lines: {note}")
    screencap(ARGS.serial, "final")
    log("PASS", f"B8.3 force-stop chain OK: pre-kill {pre_balance} sats visible -> "
                f"force-stop (no pid) -> window payment {txid2} mined + frigate "
                f"restarted -> relaunch re-established service (lease {lease_post}) -> "
                f"no lost receipts (UI {st3['balance_sats']}, db {db2}) -> "
                f"post-relaunch payment {txid3} graduated (UI {st4['balance_sats']}, "
                f"db {db3}, lease {lease_end})")
    sys.exit(0)


def stage_forcestop_control():
    """Positive control: corrupt the writer-lease record and REQUIRE the
    forcestop leg's DB-receipt assertion to FAIL (the assertions bite)."""
    st0 = baseline(ARGS.serial, what="snap0")
    addr = resolve_address(st0)
    sats = ARGS.sats
    db0 = db_receipts(ARGS.serial, ARGS.pkg)
    adb(ARGS.serial, "logcat", "-c", check=False)
    txid = sp_pay(addr, sats)
    log("paid", f"{sats} sats txid={txid}")
    h = mine_one()
    wait_electrs_indexed(h)
    db1 = wait_db_at_least(db0, sats)
    log("baseline_green", f"db={db1}")

    adb(ARGS.serial, "shell", "am", "force-stop", ARGS.pkg)
    time.sleep(3)
    require(app_pid(ARGS.serial, ARGS.pkg) == "",
            f"force-stop left a process: pid={app_pid(ARGS.serial, ARGS.pkg)}")
    edit_lease(ARGS.serial, ARGS.pkg, "poison")
    adb(ARGS.serial, "logcat", "-c", check=False)
    restart_app(ARGS.serial, ARGS.pkg)

    landed = True
    try:
        db2 = wait_db_at_least(db1, sats, budget=ARGS.control_budget)
    except RuntimeError as e:
        landed = False
        log("control_blocked_writes", str(e))
    if landed:
        log("control_useless", f"kill-window receipt LANDED despite the poisoned "
                               f"lease ({db2}) — the B2.8 write-path gate did not "
                               f"stand down and the assertion did NOT bite")
        sys.exit(1)
    st2 = snapshot_state(ARGS.serial)
    log("control_bites", f"poisoned lease blocked the write path: no receipt after "
                         f"{ARGS.control_budget}s (db unchanged from {db1}), UI at "
                         f"{st2['balance_sats']} sats — the forcestop assertions "
                         f"FAIL this tampered state, exactly as required")
    screencap(ARGS.serial, "control-poisoned")

    # restore a clean lease so later runs start unpoisoned
    adb(ARGS.serial, "shell", "am", "force-stop", ARGS.pkg)
    time.sleep(3)
    edit_lease(ARGS.serial, ARGS.pkg, "restore")
    restart_app(ARGS.serial, ARGS.pkg)
    lease_r = db_lease(ARGS.serial, ARGS.pkg)
    log("control_restored", f"lease row re-acquired after restore: {lease_r}")
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
    ap.add_argument("--stage",
                    choices=["snapshot", "control", "full", "forcestop",
                             "forcestop-control"],
                    required=True)
    ap.add_argument("--serial", default="emulator-5556")
    ap.add_argument("--pkg", default="dev.silentpayments.danawallet.dev")
    ap.add_argument("--address", default=None,
                    help="wallet SP address; default: extract from funding screen")
    ap.add_argument("--amount-btc", type=float, default=0.02)
    ap.add_argument("--ui-budget", type=int, default=90,
                    help="seconds to poll the UI before declaring it stale")
    ap.add_argument("--control-budget", type=int, default=150,
                    help="seconds the forcestop-control waits for a receipt it "
                         "REQUIRES never to arrive (poisoned lease)")
    ap.add_argument("--evidence-dir", default="/tmp/ut-t66016976-evidence")
    ARGS = ap.parse_args()
    ARGS.sats = int(round(ARGS.amount_btc * 100_000_000))
    import os
    os.makedirs(ARGS.evidence_dir, exist_ok=True)
    log("stage", f"{ARGS.stage} serial={ARGS.serial} pkg={ARGS.pkg} "
                 f"sats={ARGS.sats}")
    {"snapshot": stage_snapshot, "control": stage_control,
     "full": stage_full, "forcestop": stage_forcestop,
     "forcestop-control": stage_forcestop_control}[ARGS.stage]()


if __name__ == "__main__":
    main()
