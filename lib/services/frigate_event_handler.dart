import 'dart:typed_data';

import 'package:danawallet/generated/rust/api/structs/frigate_event.dart';
import 'package:danawallet/generated/rust/api/structs/outpoint.dart';
import 'package:danawallet/generated/rust/api/structs/owned_output.dart';
import 'package:danawallet/repositories/frigate_candidates_repository.dart';
import 'package:danawallet/repositories/wallet_repository.dart';
import 'package:danawallet/repositories/owned_outputs_repository.dart';
import 'package:danawallet/repositories/transactions_repository.dart';
import 'package:danawallet/services/writer_lease.dart';
import 'package:logger/logger.dart';

/// Dart-side consumer of the frigate event stream.
///
/// The MEMPOOL leg (phase 2, B3.1/B3.4; the state-touching handling lives in
/// Dart per B2.7): `Unconfirmed` events (height <= 0, delivered in the
/// subscribe response — frigate indexes mempool only at process start) are
/// written into the `frigate_candidates` registry. Dedupe is the outpoint
/// upsert (B3.4): a re-subscribe re-delivers the whole mempool snapshot and
/// the registry collapses it back to one row per outpoint.
///
/// The HISTORY leg (R3, B1.2/B3.4): `Confirmed` events (historic AND live
/// legs) write their receipts through the existing confirmed-state path —
/// `owned_outputs` INSERT OR FAIL, so a re-delivered confirmed output from a
/// re-subscribe's history replay dedupes on the outpoint (B3.4: counted
/// exactly once). A confirmed outpoint that still sits as a pending
/// candidate leaves the unconfirmed line (B4.1) — it is confirmed state now.
///
/// The SPENT leg (B1.4): `Spent` events write the same confirmed-state layer
/// the blindbit sync engine writes — `tx_spent_outpoints` — so balance
/// semantics are backend-independent. A spend of a pending outgoing
/// transaction confirms it (at the last seen Tip height — the scanner's
/// Spent event carries no block height); a spend with no matching outgoing
/// transaction records an unknown-spend row (foreign broadcast, e.g. a
/// multi-wallet import), exactly as SyncEngine._onSyncResult does. A
/// re-delivered Spent (a re-subscribe's history sweep re-detects the same
/// spend) dedupes on the outpoint (B3.4: counted exactly once). The spent
/// leg never advances the checkpoint (R14 stays where it is).
///
/// Phase scope: Disconnected touches no state here — the catch-up bar
/// and the unreachable banner are lifecycle UI state (B4.3/B4.4, handled by
/// FrigateState.applyLifecycle); graduation of mempool candidates is phase 3
/// (B3.3, electrum confirmation alone). R14: Tip/CaughtUp advance the SHARED
/// lastscan checkpoint (monotonically, via WalletRepository.advanceLastSync)
/// — the frigate path and the blindbit path keep one checkpoint, so a
/// backend switch never rewinds it.
class FrigateEventHandler {
  final FrigateCandidatesRepository _candidatesRepository;
  final OwnedOutputsRepository _ownedOutputsRepository;
  final TransactionsRepository _transactionsRepository;

  /// Called after the candidate registry may have changed, so the UI state
  /// can refresh (unconfirmed balance line, B4.1).
  final void Function()? onChanged;

  /// Called after new candidates were recorded, so the phase-3 confirmation
  /// monitor can subscribe their scripthashes (B3.7).
  final void Function()? onCandidatesRecorded;

  /// Called after confirmed receipts were written into `owned_outputs` (R3) —
  /// the confirmed balance refreshes from the repository.
  final void Function()? onConfirmed;

  /// test seam: deterministic clock for `first_seen`.
  final int Function()? nowMillis;

  /// The single-writer guard (B2.8): when set, the sync-state writes below
  /// go through [WriterLease.ensureOwnership] so a live foreign writer can
  /// never record candidates concurrently (B2.3). Null only in unit tests
  /// without a writer.
  final WriterLease? writerLease;

  final WalletRepository? _walletRepositoryOverride;

  /// Resolved lazily so tests/handlers that never touch checkpoint state
  /// never construct WalletRepository's SharedPreferencesAsync.
  WalletRepository get _walletRepository =>
      _walletRepositoryOverride ?? WalletRepository.instance;

  /// Last height reported by a Tip event; the CaughtUp handler advances the
  /// shared checkpoint to it (the scanner emits Confirmed only on discovery,
  /// so quiet blocks advance the checkpoint only here).
  int? _lastTipHeight;

  /// Last block hash reported by a Tip event — the Spent leg's confirmation
  /// blockhash (the scanner's Spent event carries no block data of its own).
  String? _lastTipHash;

  FrigateEventHandler({
    FrigateCandidatesRepository? candidatesRepository,
    OwnedOutputsRepository? ownedOutputsRepository,
    TransactionsRepository? transactionsRepository,
    WalletRepository? walletRepository,
    this.onChanged,
    this.onCandidatesRecorded,
    this.onConfirmed,
    this.nowMillis,
    this.writerLease,
  })  : _candidatesRepository =
            candidatesRepository ?? FrigateCandidatesRepository.instance,
        _ownedOutputsRepository =
            ownedOutputsRepository ?? OwnedOutputsRepository.instance,
        _transactionsRepository =
            transactionsRepository ?? TransactionsRepository.instance,
        _walletRepositoryOverride = walletRepository;

  Future<void> handleEvent(FrigateEventDto event) async {
    switch (event) {
      case FrigateEventDto_Unconfirmed(:final txid, :final outputs):
        await _recordCandidates(txid, outputs);
      case FrigateEventDto_Confirmed(
          :final blkheight,
          :final blkhash,
          :final foundOutputs
        ):
        await _recordConfirmedReceipts(blkheight, blkhash, foundOutputs);
      case FrigateEventDto_Tip(:final height, :final hash):
        // R14: remember the tip so the following CaughtUp can advance the
        // shared checkpoint to it (CaughtUp itself carries no height).
        _lastTipHeight = height;
        _lastTipHash = hash;
      case FrigateEventDto_CaughtUp():
        // R14: the history replay is complete — everything through the last
        // seen tip is synced, so the shared checkpoint may move there.
        final tip = _lastTipHeight;
        if (tip != null) {
          await _walletRepository.advanceLastSync(tip);
        }
      case FrigateEventDto_Spent(:final outpoints):
        await _recordSpentOutpoints(outpoints);
      case FrigateEventDto_Disconnected():
        // lifecycle-only event (see class doc); sync state is untouched.
        break;
    }
  }

  /// Spent leg (B1.4): write the scanner-reported spends through the EXISTING
  /// confirmed-state path, exactly as the blindbit sync engine does for its
  /// foundInputs: a pending outgoing transaction that spent the outpoint is
  /// confirmed; a spend with no matching transaction records an
  /// unknown-spend row (foreign broadcast). The scanner's Spent event carries
  /// no block height, so the confirmation leg uses the last seen Tip
  /// (height + hash — always the first event of every subscription); without
  /// a tip the spend is still recorded, unconfirmed. A re-delivered Spent
  /// (re-subscribe's history sweep) dedupes on the outpoint (B3.4). The
  /// checkpoint never moves here (R14).
  Future<void> _recordSpentOutpoints(List<OutPoint> outpoints) async {
    if (outpoints.isEmpty) return;
    // B2.8: the lease check sits inside the sync-state write path — a live
    // foreign writer must never see this registry written concurrently.
    await writerLease?.ensureOwnership();
    final height = _lastTipHeight;
    final hash = _lastTipHash;
    if (height == null || hash == null) {
      Logger().w(
          'frigate spent leg: no Tip seen yet — spends recorded without a confirmation height');
    }

    final unknownSpends = <OutPoint>[];
    for (final outpoint in outpoints) {
      if (height != null && hash != null) {
        // Confirm the pending outgoing transaction that spent the outpoint.
        // This is also the B3.4 dedupe for a re-delivered Spent event: any
        // already-recorded spend (pending OR unknown-spend row) matches here
        // and the UPDATE re-applies the same confirmation — no second row.
        final confirmed =
            await _transactionsRepository.confirmOutgoingTransaction(
          confirmedOutpointTxid: outpoint.txid,
          confirmedOutpointVout: outpoint.vout,
          confirmationHeight: height,
          confirmationBlockhash: hash,
        );

        // this output does not have an associated transaction — a foreign
        // broadcast (e.g. the seed imported in multiple wallets); record it
        // so the outpoint leaves the balance (same as SyncEngine
        // ._onSyncResult's unknown-spend branch).
        if (!confirmed) {
          unknownSpends.add(outpoint);
        }
      } else {
        // No Tip seen: the confirmation leg cannot run, so the explicit
        // outpoint dedupe guard keeps a re-delivered Spent from piling up
        // unknown-spend rows.
        if (await _transactionsRepository.isOutpointSpent(
            outpoint.txid, outpoint.vout)) {
          continue;
        }
        unknownSpends.add(outpoint);
      }
    }

    if (unknownSpends.isNotEmpty) {
      Logger().w(
          'frigate spent leg: ${unknownSpends.length} spend(s) with no matching outgoing transaction, recording as unknown spends');
      await _transactionsRepository.addOutgoingTransaction(
        spentOutpoints: unknownSpends,
        recipients: [],
        txid: null,
        confirmationHeight: height,
        confirmationBlockhash: hash,
      );
    }
    if (outpoints.isNotEmpty) {
      Logger().i(
          'frigate spent leg: ${outpoints.length} spent outpoint(s) written to tx_spent_outpoints (B1.4)');
      onChanged?.call();
      onConfirmed?.call();
    }
  }

  /// History leg (R3): write the scanner-reported confirmed receipts through
  /// the EXISTING confirmed-state path, exactly as the blindbit sync engine
  /// does: the incoming transaction row first (transactions FK + history),
  /// then `owned_outputs` INSERT OR FAIL on the outpoint — the B3.4 dedupe:
  /// a re-delivered confirmed output (a re-subscribe's history replay)
  /// inserts nothing a second time. A matching pending candidate is marked
  /// confirmed — the satoshis now live in the confirmed balance and must not
  /// also sit in the unconfirmed line (B4.1).
  Future<void> _recordConfirmedReceipts(
      int blkheight, String blkhash, List<OwnedOutput> outputs) async {
    // B2.8: the lease check sits inside the sync-state write path — a live
    // foreign writer must never see this registry written concurrently.
    await writerLease?.ensureOwnership();
    for (final output in outputs) {
      final outpoint = output.outpoint;
      await _transactionsRepository.addIncomingTransaction(
        txid: outpoint.txid,
        confirmationHeight: blkheight,
        confirmationBlockhash: blkhash,
      );
      await _ownedOutputsRepository.insertOutput(output: output);
      final candidate = await _candidatesRepository.getCandidate(
          outpoint.txid, outpoint.vout);
      if (candidate != null &&
          candidate.status == FrigateCandidateStatus.pending) {
        await _candidatesRepository.markConfirmed(outpoint.txid, outpoint.vout);
      }
    }
    if (outputs.isNotEmpty) {
      Logger().i(
          'frigate history leg: ${outputs.length} confirmed receipt(s) written to owned_outputs (R3/B3.4)');
      onChanged?.call();
      onConfirmed?.call();
    }
    // R14: the confirmed leg reached blkheight — advance the SHARED lastscan
    // checkpoint (monotonic) so a backend switch never re-derives a stale
    // checkpoint and rescans. Confirmed events fire only on discovery; quiet
    // blocks advance via the Tip->CaughtUp pair in [handleEvent].
    await _walletRepository.advanceLastSync(blkheight);
  }

  Future<void> _recordCandidates(
      String eventTxid, List<OwnedOutput> outputs) async {
    // B2.8: the lease check sits inside the sync-state write path — a live
    // foreign writer must never see this registry written concurrently.
    await writerLease?.ensureOwnership();
    final firstSeen =
        nowMillis?.call() ?? DateTime.now().millisecondsSinceEpoch;
    for (final output in outputs) {
      final outpoint = output.outpoint;
      await _candidatesRepository.upsertCandidate(FrigateCandidate(
        txid: outpoint.txid,
        vout: outpoint.vout,
        tweak: Uint8List.fromList(output.tweak.toList()),
        script: output.script,
        amountSat: output.amount.field0.toInt(),
        firstSeen: firstSeen,
        source: 'frigate-mempool',
      ));
    }
    if (outputs.isNotEmpty) {
      Logger().i(
          'frigate mempool leg: ${outputs.length} candidate(s) recorded for tx $eventTxid (B3.1)');
      onChanged?.call();
      // Phase 3 (B3.7): the confirmation monitor subscribes the new
      // candidates' scripthashes.
      onCandidatesRecorded?.call();
    }
  }
}
