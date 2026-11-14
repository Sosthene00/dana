# Dana Wallet — Frigate Backend Behavior Specification

**Status: DRAFT v0.2 (2026-11-13) — first deliverable of the spec-first restart (decision D13).
Normative basis: "Frigate Dana restart decision record (2026-11-13)" (Obsidian vault) and the
2026-11-09 decision record it supersedes. Owner sign-off of this file is a HARD GATE: no
implementation starts until Sosthene has approved it (decision D2). Owner corrections are
authoritative and REPLACE the drafted line in full.**

This document defines what the frigate sync backend in Dana is supposed to do. It replaces
`docs/BEHAVIOR.md` DRAFT v0.1 from the `feat/frigate-v2` line, which was drafted alongside the
old implementation and is consulted only as input (decision D7). The old implementation
(feat/frigate-sync, feat/frigate-v2, PR #511 line) is discarded; this spec starts from a clean
branch cut from `dev`.

## How this document is used

1. **Authoritative for implementation and testing.** Every acceptance case cites behavior IDs
   (`B<n>.<m>`). A case PASSes when observed behavior matches the cited lines. No case may
   assert behavior not written here — a missing rule gets added here first.
2. **Honest about gaps.** Lines marked `[OPEN]` describe behavior not yet implemented. They
   convert to plain contract lines when implemented and verified.
3. **Pinned, not floating.** Test verdicts are always "PASS against spec @ <sha>".
4. **Not weakenable to go green.** This file changes only via owner correction or a
   landed-and-verified fix — never in the same commit as a change that was failing a case.

## 0. Conventions and rig facts

- Regtest rig (must be healthy before any acceptance run): bitcoind v30.3 regtest :18443,
  electrs 0.11.1 :60401, frigate regtest :50002, sp-pay funding helper. Regtest address hrp is
  `sprt1` (BIP-352 v0, bech32m).
- **Rig quirks that are facts, not bugs** (production code may rely on them; tests must
  account for them): frigate indexes mempool ONLY at process start — a payment entering the
  mempool of a running frigate is delivered to NEW subscriptions in the subscribe response
  (height ≤ 0), never pushed to a held subscription. `block_height()` is eventually consistent
  (~35 s poll); the authoritative tip for assertions is bitcoind RPC.
- Frigate 1.4.1 wire facts: `server.version` must be the first message; subscribe response
  carries `{subscription, progress, history}`; history entries are `{height, tx_hash,
  tweak_key}`; mempool entries carry height ≤ 0.
- The spdk frigate scanner (`feat/frigate-backend`, event-driven `FrigateScanner` →
  `FrigateEvent::{Tip, Confirmed, Unconfirmed, CaughtUp, Spent, Disconnected}`) is a FIXED
  given. Its API, wire handling, and PR are out of scope for this document.

## 1. Sync architecture — two backends, two shapes

- **B1.1** Blindbit remains the default backend. Its wake-cycle one-shot scan
  (`lastscan` vs tip, batch history) is blindbit's shape and is unchanged by this restart.
- **B1.2** The frigate backend is **subscription-driven end to end**. There is NO Dana-initiated
  batch scan on the frigate path: no wake probe, no `lastscan`-vs-tip comparison, no
  scan-range loop. One held subscription with `start_height` = the wallet's committed
  checkpoint delivers BOTH the historic leg (server-side history replay) and the live leg
  (mempool entries, height ≤ 0) through the same key-bearing subscription.
- **B1.3** The frigate "wake" action reduces to: ensure the subscription is alive (re-subscribe
  if dropped). A wake on an already-caught-up wallet with a healthy subscription does nothing
  observable.
- **B1.4** Both backends write the same confirmed-state layer (`owned_outputs` +
  `tx_spent_outpoints`); balance semantics are backend-independent. The blindbit checkpoint
  (`lastscan`) is never written by the frigate path.
- **B1.5** Switching frigate → blindbit: blindbit scans from the wallet's last confirmed
  height. Switching blindbit → frigate: the fresh subscription's `start_height` is the same
  committed height. No wallet state is rebuilt or lost across switches.

## 2. Frigate subscription lifecycle — foreground service

- **B2.1** The frigate subscription lives inside the Android **foreground service** (the same
  pattern blindbit uses). It starts when the wallet starts, holds the subscription while the
  device is up, and survives main-app process death.
- **B2.2** The service consumes `FrigateEvent`s and **writes state directly to the DB**:
  confirmed receipts → `owned_outputs` (via the existing graduation path, §3); mempool
  discoveries → `frigate_candidates` (§3). The main app on reopen READS what is already
  there; it does not rescan.
- **B2.3** Single-writer rule: while the service is alive it is the SOLE writer of sync state.
  The app process takes over writing only after it confirms the service is down (probe
  mechanism specified in the implementation; a required sub-task of the spec pass — see
  §9-O4). Concurrent writers of the same table are a spec violation.
- **B2.4** On any `Disconnected`: the service re-subscribes automatically. History replays from
  `start_height` (already-confirmed outputs are re-reported and deduped, never double-counted);
  the current mempool snapshot re-arrives in the subscribe response. There is no separate
  gap-detection protocol and no data-loss window: anything confirmed during the outage is in
  the replayed history; anything mempool-resident is in the re-delivered snapshot.
- **B2.5** Service death (Android reclaims it) is not a correctness event: on next service
  start the subscription is re-established from the committed checkpoint (B2.4 semantics).
  No receipt is ever lost to monitor downtime.
- **B2.6** `CaughtUp` is reported to the UI; after it, the service stays subscribed (mempool
  leg continues). Dropping the subscription at CaughtUp is a violation — it would break the
  mempool phase.

- **B2.7** [DRAFT-OWNER-REVIEW] FFI split for service-side scanning (drafts §9-O3): the Rust
  side is exactly the fixed spdk scanner surface — wire protocol, subscription lifecycle, and
  `FrigateEvent` emission over the existing flutter_rust_bridge stream. No new Rust surface in
  v1: no DB access from Rust, no candidate/graduation logic in Rust. ALL `FrigateEvent`
  handling that touches state lives in Dart inside the foreground service: candidate registry
  writes (§3), graduation into `owned_outputs` (B3.3), dedupe (B3.4), the phase-3 electrum
  monitor (§3), and the writer lease (B2.8). Rationale: the confirmed-state layer and the
  graduation path are Dart/sqflite; a single Dart writer keeps the B2.3 single-writer rule
  enforceable in one place.
- **B2.8** [DRAFT-OWNER-REVIEW] Single-writer handoff probe (drafts §9-O4; precision of
  B2.3): writer exclusion is a DB **writer lease** — one lease row (writer identity +
  last-heartbeat timestamp) in the wallet state store. The live writer (the service, or the
  app after takeover) renews it every 5 s. A process may take over writing only after it
  observes the lease stale for ≥ 10 s (two missed heartbeats); that staleness observation IS
  the confirmation that the previous writer (the foreground service) is down. A best-effort
  bind probe to the service MAY be used as a fast path but never replaces the staleness
  check. The lease check sits inside the sync-state write path, so concurrent writers are
  structurally prevented, not merely discouraged.

## 3. Receipt pipeline and the candidate registry

- **B3.1** Unconfirmed (mempool, height ≤ 0) receipts are a state class that exists ONLY on
  the frigate path. They are stored in a dedicated `frigate_candidates` sqflite table
  (one new migration; the confirmed-state schema is untouched):
  identity = outpoint `(txid, vout)`; fields include tweak_key/script material, first_seen,
  source, status (`pending` | `confirmed` | `dropped`).
- **B3.2** A mempool entry NEVER advances any checkpoint, never enters `owned_outputs`, and is
  NEVER spendable.
- **B3.3** **Graduation = electrum confirmation alone.** When the phase-3 electrum server
  notifies that a candidate's transaction is confirmed in a block, the candidate graduates:
  the output is derived and written into `owned_outputs` (normal confirmed-state path), and
  the candidate row is marked `confirmed`. The scanner's later `Confirmed` re-report of the
  same output (history replay) is a DEDUPE input — it must not create state a second time.
  (Founder correction, binding: frigate does not re-notify on mining; that is why phase 3
  exists.)
- **B3.4** Deduplication invariant: across subscription reconnects, service restarts, and
  app restarts, a given outpoint is counted into balance exactly once. Dedupe key is the
  outpoint.
- **B3.5** A mempool tx that vanishes (evicted/replaced, detected via the phase-3 electrum
  path) marks the candidate `dropped`; a dropped candidate leaves no trace in balance. The
  concrete eviction-detection rule is an open spec item (§9-O2).
- **B3.6** Phase-3 confirmation tracking registers the scripthashes of DERIVED candidate
  outputs with the electrum server (default: the wallet's configured blindbit
  electrum-compatible API; self-hosted electrs as an advanced override). The electrum
  connection carries no scan key and reveals only outputs the frigate operator already saw.

- **B3.7** [DRAFT-OWNER-REVIEW] Phase-3 scripthash subscribe strategy (drafts §9-O1;
  precision of B3.6): on candidate creation the monitor subscribes the electrum scripthash of
  that candidate's own output script (one subscription per candidate; each derived candidate
  output carries its own tweak key and therefore its own script, so per-candidate is the
  granularity). Only `pending` candidates are subscribed; on graduation (`confirmed`) or drop
  (`dropped`) the scripthash is unsubscribed — the live subscription set is exactly the
  pending candidate set. There is no address-gap lookahead on this path (BIP-352 outputs are
  derived from observed tweak keys, not from an address chain); the bound is a hard cap of
  1024 concurrent subscriptions, with candidates beyond the cap falling back to per-block
  `blockchain.scripthash.get_history` polling until a slot frees. The candidate table is the
  source of truth: on any electrum connect or reconnect the subscription set is rebuilt from
  `frigate_candidates WHERE status = 'pending'`, never from in-memory state.
- **B3.8** [DRAFT-OWNER-REVIEW] Eviction detection (drafts §9-O2; precision of B3.5): the
  primary signal is the electrum negative read — on any subscribed scripthash status change,
  fetch `blockchain.scripthash.get_history`; a `pending` candidate whose txid appears in
  NEITHER the confirmed history NOR the mempool entries of its scripthash is evicted → status
  `dropped` (B3.5 status transition). An RBF replacement that pays the wallet creates a NEW
  candidate (new outpoint); the replaced tx's candidate is dropped. Fallback for missed
  notifications (timeout path): on every new electrum block, and at least every 10 minutes,
  every `pending` candidate older than 10 minutes is reconciled through the same
  get_history read. A candidate is NEVER dropped while its txid is present in any history
  response, and a re-delivered mempool entry for a dropped outpoint reactivates the row to
  `pending` (the registry mirrors current observation; balance is unaffected either way —
  candidates never count until graduation, B3.2/B4.2). `dropped` with no re-delivery is
  terminal.

## 4. Balances and UI

- **B4.1** The main screen shows the confirmed balance as today (sum of unspent
  `owned_outputs`), and, on the frigate path when candidates exist, an **unconfirmed balance**
  line directly below it, derived from `frigate_candidates`. The line is absent (not zero)
  when there are no candidates.
- **B4.2** The unconfirmed balance is informational only: it is never spendable, never included
  in send-availability checks, and transitions into the confirmed balance at graduation
  without user action.
- **B4.3** Progress bar (frigate path): tracks subscription catch-up only — indeterminate
  until the first `Tip`, determinate from scanner-reported progress, hidden at `CaughtUp`.
  Never interpolated; mempool events never touch it; no separate "live" indicator in v1.
- **B4.4** While the backend is unreachable: explicit banner ("Frigate unreachable — will
  retry"), no crash, no data loss, no silent fallback; the banner clears on the next
  successful interaction. All user-visible errors are human-readable (no `AnyhowException`,
  no os error N).

## 5. Backend configuration and privacy

- **B5.1** Configuring a frigate URL: the URL is probed (parse + reachability probe, never a
  subscribe handshake — a probe must not burn the scan key) before saving. On probe failure
  the dialog stays open with a persistent inline field error; the typed URL is preserved.
- **B5.2** The user declares each frigate URL **public or private**; default selection is
  private. Public is always opt-in — a deliberate user act, never a default or a promotion.
- **B5.3** The one-time public warning is **blocking**: before the first public sync proceeds,
  the user must acknowledge the two-harms warning (historical: the scan key links outputs
  permanently; ongoing: the operator observes every future sync live, surviving key rotation).
  Mitigation line: "create a new wallet".
- **B5.4** The warning fires exactly ONCE per wallet, on the first **successful** public
  subscription (an unreachable URL does not count — the harm happens at first successful use,
  not first attempt). It never fires again, for any URL. Each public URL + date is still
  logged permanently in the per-wallet disclosure record.
- **B5.5** While a custom backend URL is configured, the app talks to that endpoint only — no
  silent fallback to defaults. The chain tip comes ONLY from the selected backend's session;
  foreign tips are rejected (carried from v0.1 B5.1-B5.2).

## 6. Send / spend (unchanged by the restart; carried as contract)

- **B6.1** Send requires sufficient CONFIRMED balance; unconfirmed candidates never fund a
  send. Attempting more shows an inline error and broadcasts nothing.
- **B6.2** The built transaction: sender secret = sum of eligible input private keys (BIP-352);
  SP output = valid tweaked P2TR for the destination; change returns to the wallet.
- **B6.3** Broadcast goes through the selected backend; success means the tx is in the
  regtest mempool (verifiable via `getrawmempool`). Balance decreases by amount + fee; fee
  shown before confirmation. A failed broadcast leaves balance/history unchanged.

## 7. Resilience and recovery (frigate path summary)

- **B7.1** Disconnect → auto re-subscribe (B2.4). Service death → re-establish on next start
  (B2.5). Backend outage → banner + retry (B4.4). In all three cases: no lost receipts
  (§3 invariant), no duplicate state, no manual intervention.
- **B7.2** Forced main-app kill while the service holds the subscription: the service keeps
  consuming events and updating the DB; on reopen the app shows the current state including
  anything received during the kill window. This is the D6 device acceptance scenario.

## 8. Definition of done (v1)

- **B8.1** Full three-phase flow passes on the regtest rig: subscribe with start_height →
  history replayed into confirmed state; mempool payment (frigate restarted per rig quirk) →
  candidate + unconfirmed balance; mined → electrum notification → graduation into
  `owned_outputs`, exactly once, confirmed balance updated, unconfirmed line gone.
- **B8.2** Phase 3 (electrum confirmation tracking) is a HARD GATE: the monitor without the
  electrum path does not ship (it would recreate the old breach: receipts found only after
  restart).
- **B8.3** One device run of B7.2 passes: main app force-killed, payment sent during the kill
  window, wallet opened later shows the receipt confirmed — without app interaction beyond
  opening.
- **B8.4** The one-time public warning fires on first successful public subscription and never
  again (regtest: two public URLs, two successful syncs, exactly one ack).

- **B8.5** [DRAFT-OWNER-REVIEW] Regtest acceptance script outline (drafts §9-O5; the
  execution contract for B8.1 and B8.3 on the rig of §0):
  1. Preflight: bitcoind RPC `getblockchaininfo` answers; electrs listens on :60401; frigate
     :50002 handshake — `server.version` sent FIRST, then `blockchain.headers.subscribe`.
  2. Fresh wallet onboarded; frigate URL configured private (B5.1 probe, never a subscribe
     handshake); subscribe with `start_height` = the wallet's committed checkpoint (0 on a
     fresh wallet).
  3. History leg: fund via sp-pay, MINE the payment, restart frigate (rig quirk: indexed at
     process start), subscribe → history replay → output in `owned_outputs`, confirmed
     balance updated, counted exactly once (B3.4).
  4. Mempool leg: with the subscription HELD, sp-pay a second payment → assert NO push (rig
     quirk: never pushed to a held subscription); restart frigate, re-subscribe → the
     subscribe response carries the mempool entry (height ≤ 0) → candidate row + unconfirmed
     balance line (B4.1), never spendable (B6.1).
  5. Tip consistency: the authoritative tip for every height assertion is bitcoind RPC; wait
     for frigate's `block_height` to agree, budget ~35 s (eventual consistency); timeout
     without agreement = FAIL.
  6. Graduation: mine one block, wait for electrs to index → electrum notification →
     candidate `confirmed`, output in `owned_outputs` exactly once, confirmed balance
     updated, unconfirmed line gone (B3.3/B4.2).
  7. B8.3 leg: force-stop the main app (`adb shell am force-stop`) while the service holds
     the subscription; during the kill window repeat steps 4-6 (payment, frigate restart per
     quirk, mine); reopen the app → confirmed receipt visible without interaction; the app's
     write takeover follows the B2.8 lease (no concurrent writers observed).
  Every verdict is recorded "PASS against spec @ <sha>".

## 9. Open items (spec pass, blocking implementation)

Drafted 2026-11-14 (R0a): every item below now has a normative draft line marked
[DRAFT-OWNER-REVIEW] with a recommended default; the owner rules on the drafts via R0b and an
owner ruling replaces the drafted line in full. No undrafted items remain; no item was left
OPEN — where a parameter is a judgment call it is stated as a recommended default inside the
draft line, which the [DRAFT-OWNER-REVIEW] flag holds for owner decision.

- **O1** Scripthash subscribe strategy for phase 3: which candidate scripthashes get
  subscribed, lookahead/gap limit, unsubscription on graduation/drop.
  → Drafted as **B3.7** [DRAFT-OWNER-REVIEW]: per-candidate subscription, no address-gap
  lookahead, 1024-subscription cap with per-block polling fallback, unsubscribe on
  graduation/drop, table-driven rebuild on reconnect.
- **O2** Candidate eviction-detection rule (electrum negative signal vs timeout).
  → Drafted as **B3.8** [DRAFT-OWNER-REVIEW]: electrum negative read is primary,
  block/10-minute reconciliation is the fallback, never drop while the txid is present,
  reactivation on re-delivery, terminal otherwise.
- **O3** FFI surface for service-side scanning: which FrigateEvent handling lives in Rust vs
  Dart inside the service context.
  → Drafted as **B2.7** [DRAFT-OWNER-REVIEW]: Rust = fixed scanner surface only; all
  state-touching handling in Dart inside the service.
- **O4** Single-writer handoff probe: how the app process confirms the foreground service is
  down before taking over writes (B2.3).
  → Drafted as **B2.8** [DRAFT-OWNER-REVIEW]: DB writer lease, 5 s heartbeat, takeover after
  10 s staleness; bind probe as fast path only.
- **O5** Regtest acceptance script for B8.1/B8.3 (frigate restart quirk handling, ~35 s
  block_height consistency budget).
  → Drafted as **B8.5** [DRAFT-OWNER-REVIEW]: seven-step outline; the frigate-restart quirk
  and the ~35 s block_height budget are normative inside it.

## 10. Out of scope (v1)

Coin control; multi-backend simultaneous operation; Tor; frigate 1.6 / dual-shape subscribe
response handling (spdk follow-up PR territory); incoming-payment push notifications (the
unconfirmed balance line covers v1 visibility).
