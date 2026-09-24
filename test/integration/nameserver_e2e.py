#!/usr/bin/env python3
"""End-to-end challenge-auth registration test against the real dana-nameserver binary.

Spins the nameserver from ~/projects/dana-nameserver @ 4eb6d2e with the Cloudflare
API mocked via a local wiremock-faithful HTTP server (same fixture shape as the
nameserver's own `test(cf): mock Cloudflare API ...` tests @ 36643e8: the binary
honours CLOUDFLARE_API_BASE_URL), drives /challenge => sign via the wallet-side
T1 rust fn `sign_challenge` => /register, and asserts:

  1. /challenge returns 200 + the exact `dana-register:{net}:{nonce}:{user}@{domain}`
     message string.
  2. /register with the sign_challenge attestation returns 200 + dana_address echo
     (the server-side verify_schnorr_signature ACCEPTED it => the SHA-256
     pre-hash contract between wallet and nameserver is locked).
  3. Negative: /register with a structurally-valid BIP-340 signature over the
     RAW PREIMAGE (no SHA-256) of the same message, same spend key, is 401.
     Bonus: the corrected signature still registers afterwards (R7
     verify-before-claim: a rejected signature must not burn the nonce).

The signing runs INSIDE the dana rust crate (zero new deps): the #[ignore]d
oracle test at the bottom of rust/src/api/wallet/challenge.rs reads
DANA_ORACLE_SCAN/SPEND/MSG and prints SPADDR=/SIG=(/RAWSIG=) lines.

How to run
----------
  cd <repo>/rust
  python3 ../test/integration/nameserver_e2e.py            # cargo build of the NS + full loop
  NS_BIN=~/projects/dana-nameserver/target/debug/dana_nameserver \
      python3 ../test/integration/nameserver_e2e.py        # reuse a pre-built binary

The nameserver repo is NOT modified (different board owns it): we only exec its
binary with env overrides. Exits non-zero with the failing step + response bodies.
"""
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))          # dana repo root
RUST = os.path.join(REPO, "rust")
NS_REPO = os.path.expanduser(os.environ.get("NS_REPO", "~/projects/dana-nameserver"))
NS_BIN = os.path.expanduser(os.environ.get("NS_BIN", os.path.join(NS_REPO, "target/debug/dana_nameserver")))

ZONE = "e2ezone123"
TOKEN = "e2e-token"
DOMAIN = "e2e.test"
USER = "integertestuser"
# Fixed keys for the throwaway testnet SP address (sk = 0x11 / 0x22).
SCAN_HEX = "0" * 62 + "11"
SPEND_HEX = "0" * 62 + "22"

# --- Cloudflare wiremock fixture (same shapes as nameserver commit 36643e8) ---
RECORD_ID = "rec-e2e-" + uuid.uuid4().hex[:8]


class CFHandler(BaseHTTPRequestHandler):
    """POST /zones/{zone}/dns_records => {success, result:{id}};
    GET /zones/{zone}/dns_records?type=TXT... => {success, result:[...]}.
    Mirrors the wiremock mocks mounted by the nameserver's cf tests."""

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
        if "/dns_records" in self.path:
            self._json(200, {"success": True, "result": {"id": RECORD_ID}})
        else:
            self._json(404, {"success": False})

    def do_GET(self):
        if "/dns_records" in self.path:
            # No registrations on record yet: the startup populate pass and the
            # in-handler duplicate check both see an empty zone.
            self._json(200, {"success": True, "result": []})
        else:
            self._json(404, {"success": False})

    def _json(self, code, body):
        raw = json.dumps(body).encode()
        # send_response(code) alone, then explicit headers — the second
        # positional arg is a *reason phrase*, passing a dict there emitted a
        # malformed status line reqwest rejected ("invalid HTTP version").
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
        self.wfile.flush()

    def log_message(self, *args):
        pass


def post_json(url, payload):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def run_oracle(env_extra):
    """Invoke the #[ignore]d wallet-side signing oracle; returns its stdout+stderr."""
    env = dict(os.environ, PATH=os.path.expanduser("~/.cargo/bin") + ":" + os.environ.get("PATH", ""))
    env.update(env_extra)
    p = subprocess.run(
        ["cargo", "test", "--workspace", "--",
         "--exact", "api::wallet::challenge::e2e_oracle::nameserver_e2e_oracle",
         "--ignored", "--nocapture"],
        cwd=RUST, env=env, capture_output=True, text=True)
    out = p.stdout + p.stderr
    if p.returncode != 0 or "test result: ok" not in out:
        fail("signing oracle cargo test failed", out)
    return out


def fail(step, detail):
    print(f"FAIL: {step}")
    print(detail)
    sys.exit(1)


def main():
    if not os.path.exists(NS_BIN):
        print(f"building nameserver binary from {NS_REPO} (pass NS_BIN to reuse one)")
        env = dict(os.environ, PATH=os.path.expanduser("~/.cargo/bin") + ":" + os.environ.get("PATH", ""))
        b = subprocess.run(["cargo", "build"], cwd=NS_REPO, env=env,
                           capture_output=True, text=True)
        if b.returncode != 0:
            fail("nameserver build red at the pinned rev", b.stdout + b.stderr)

    # 1. Mock Cloudflare + pick nameserver port.
    cf = HTTPServer(("127.0.0.1", 0), CFHandler)
    threading.Thread(target=cf.serve_forever, daemon=True).start()
    cf_port = cf.server_address[1]

    ns_port_env = os.environ.get("NS_PORT")
    if ns_port_env:
        ns_port = int(ns_port_env)
    else:
        import socket
        s = socket.socket(); s.bind(("127.0.0.1", 0)); ns_port = s.getsockname()[1]; s.close()

    ns_env = dict(os.environ,
                  RUST_LOG="warn",
                  CLOUDFLARE_ZONE_ID=ZONE,
                  CLOUDFLARE_API_TOKEN=TOKEN,
                  CLOUDFLARE_API_BASE_URL=f"http://127.0.0.1:{cf_port}",
                  DOMAIN_NAME=DOMAIN,
                  SERVER_HOST="127.0.0.1",
                  SERVER_PORT=str(ns_port),
                  NETWORK="Testnet")
    # dotenv() ERRORS (exits 1) when no .env exists in the CWD and none of its
    # ancestors, so run the binary from a scratch dir holding an empty .env.
    # (The nameserver repo itself is never touched: its own dir has no .env.)
    import tempfile
    ns_run_dir = tempfile.mkdtemp(prefix="dana-e2e-nsrun-")
    open(os.path.join(ns_run_dir, ".env"), "w").close()
    ns = subprocess.Popen([NS_BIN], cwd=ns_run_dir, env=ns_env,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    nslog = []

    def pump():
        for line in ns.stdout:
            nslog.append(line)
    threading.Thread(target=pump, daemon=True).start()

    base = f"http://127.0.0.1:{ns_port}"
    for _ in range(100):
        try:
            with urllib.request.urlopen(base + "/v1/info", timeout=2):
                break
        except urllib.error.HTTPError:
            break       # any HTTP answer means the server is up
        except Exception:
            if ns.poll() is not None:
                fail("nameserver exited during startup", "".join(nslog))
            time.sleep(0.2)
    else:
        ns.kill()
        fail("nameserver never answered /info", "".join(nslog))

    try:
        # 2. Ask the oracle (wallet T1 code path) for the SP address first.
        sp_out = run_oracle({"DANA_ORACLE_SCAN": SCAN_HEX, "DANA_ORACLE_SPEND": SPEND_HEX,
                             "DANA_ORACLE_MSG": "dana-register:probe"})
        spaddr = re.search(r"^SPADDR=(\S+)$", sp_out, re.MULTILINE)
        if not spaddr:
            fail("oracle printed no SPADDR line", sp_out)
        spaddr = spaddr.group(1)
        if not spaddr.startswith("tsp1"):
            fail("oracle-derived address is not a testnet SP address", spaddr)

        # 3. /challenge
        req_id = uuid.uuid4().hex
        code, body = post_json(base + "/v1/challenge", {
            "id": req_id, "domain": DOMAIN, "user_name": USER, "sp_address": spaddr})
        if code != 200:
            fail(f"/challenge expected 200, got {code}", json.dumps(body))
        message = body.get("message", "")
        if not message.startswith("dana-register:tsp:"):
            fail("unexpected challenge message", json.dumps(body))

        # 4. Sign via the wallet-side T1 fn (and the raw-preimage path for the negative leg).
        sig_out = run_oracle({"DANA_ORACLE_SCAN": SCAN_HEX, "DANA_ORACLE_SPEND": SPEND_HEX,
                              "DANA_ORACLE_MSG": message, "DANA_ORACLE_RAW": "1"})
        sig = re.search(r"^SIG=(\S+)$", sig_out, re.MULTILINE)
        rawsig = re.search(r"^RAWSIG=(\S+)$", sig_out, re.MULTILINE)
        if not sig or not rawsig:
            fail("oracle printed no SIG/RAWSIG line", sig_out)
        sig, rawsig = sig.group(1), rawsig.group(1)
        if sig == rawsig:
            fail("digest and raw-preimage signatures identical — oracle broken", "")

        # 5. Positive /register: server-side verify_schnorr_signature must ACCEPT.
        code, body = post_json(base + "/v1/register", {
            "id": req_id, "domain": DOMAIN, "user_name": USER, "sp_address": spaddr,
            "nonce": body["nonce"], "signature": sig})
        if code != 200 or body.get("dana_address") != f"{USER}@{DOMAIN}":
            fail("positive /register must be 200 with dana_address echo",
                 f"code={code} body={json.dumps(body)}\nNS log:\n" + "".join(nslog))
        if body.get("dns_record_id") != RECORD_ID:
            fail("dns_record_id not the mock's", json.dumps(body))

        # 6. Negative: fresh challenge (the good nonce is consumed), then present
        #    the raw-preimage signature => 401, and the nonce must NOT be burned
        #    (R7 verify-before-claim) so the corrected signature still registers.
        code, body2 = post_json(base + "/v1/challenge", {
            "id": req_id, "domain": DOMAIN, "user_name": USER, "sp_address": spaddr})
        if code != 200:
            fail("second /challenge expected 200", json.dumps(body2))
        # Re-sign over THIS challenge's message: the signature is bound to
        # the nonce inside it, so the first round's sig/rawsig are dead here.
        sig_out2 = run_oracle({"DANA_ORACLE_SCAN": SCAN_HEX, "DANA_ORACLE_SPEND": SPEND_HEX,
                               "DANA_ORACLE_MSG": body2["message"], "DANA_ORACLE_RAW": "1"})
        sig2 = re.search(r"^SIG=(\S+)$", sig_out2, re.MULTILINE)
        rawsig2 = re.search(r"^RAWSIG=(\S+)$", sig_out2, re.MULTILINE)
        if not sig2 or not rawsig2:
            fail("oracle round-2 printed no SIG/RAWSIG line", sig_out2)
        sig2, rawsig2 = sig2.group(1), rawsig2.group(1)
        code, body = post_json(base + "/v1/register", {
            "id": req_id, "domain": DOMAIN, "user_name": USER, "sp_address": spaddr,
            "nonce": body2["nonce"], "signature": rawsig2})
        if code != 401:
            fail("raw-preimage signature must be rejected with 401",
                 f"code={code} body={json.dumps(body)}\nNS log:\n" + "".join(nslog))
        print("ok: raw-preimage signature rejected with 401:", body.get("message"))

        code, body = post_json(base + "/v1/register", {
            "id": req_id, "domain": DOMAIN, "user_name": USER, "sp_address": spaddr,
            "nonce": body2["nonce"], "signature": sig2})
        if code != 200:
            fail("R7 violated: nonce burned by the rejected (401) raw-preimage attempt — "
                 "corrected signature must still be accepted until TTL",
                 f"code={code} body={json.dumps(body)}\nNS log:\n" + "".join(nslog))

        print("PASS: nameserver e2e challenge=>sign(T1)=>register 200 + dana_address echo, "
              "raw-preimage 401, verify-before-claim preserved")
    finally:
        ns.terminate()
        try:
            ns.wait(timeout=5)
        except Exception:
            ns.kill()
        cf.shutdown()


if __name__ == "__main__":
    main()
