import 'dart:typed_data';

import 'package:danawallet/generated/rust/api/structs/frigate_event.dart';
import 'package:danawallet/generated/rust/api/structs/owned_output.dart';
import 'package:danawallet/repositories/frigate_candidates_repository.dart';
import 'package:danawallet/services/writer_lease.dart';
import 'package:logger/logger.dart';

/// Dart-side consumer of the frigate event stream for the mempool leg
/// (phase 2, B3.1/B3.4; the state-touching handling lives in Dart per B2.7).
///
/// `Unconfirmed` events (height <= 0, delivered in the subscribe response —
/// frigate indexes mempool only at process start) are written into the
/// `frigate_candidates` registry. Dedupe is the outpoint upsert (B3.4): a
/// re-subscribe re-delivers the whole mempool snapshot and the registry
/// collapses it back to one row per outpoint.
///
/// Phase scope: ONLY the mempool leg. Confirmed/Spent/Tip/CaughtUp/
/// Disconnected events are deliberately not handled here — the confirmed leg
/// is phase 1 (R3) and graduation is phase 3 (R5, B3.3).
class FrigateEventHandler {
  final FrigateCandidatesRepository _candidatesRepository;

  /// Called after the candidate registry may have changed, so the UI state
  /// can refresh (unconfirmed balance line, B4.1).
  final void Function()? onChanged;

  /// Called after new candidates were recorded, so the phase-3 confirmation
  /// monitor can subscribe their scripthashes (B3.7).
  final void Function()? onCandidatesRecorded;

  /// test seam: deterministic clock for `first_seen`.
  final int Function()? nowMillis;

  /// The single-writer guard (B2.8): when set, the sync-state writes below
  /// go through [WriterLease.ensureOwnership] so a live foreign writer can
  /// never record candidates concurrently (B2.3). Null only in unit tests
  /// without a writer.
  final WriterLease? writerLease;

  FrigateEventHandler({
    FrigateCandidatesRepository? candidatesRepository,
    this.onChanged,
    this.onCandidatesRecorded,
    this.nowMillis,
    this.writerLease,
  }) : _candidatesRepository =
            candidatesRepository ?? FrigateCandidatesRepository.instance;

  Future<void> handleEvent(FrigateEventDto event) async {
    switch (event) {
      case FrigateEventDto_Unconfirmed(:final txid, :final outputs):
        await _recordCandidates(txid, outputs);
      case FrigateEventDto_Confirmed():
      case FrigateEventDto_Tip():
      case FrigateEventDto_CaughtUp():
      case FrigateEventDto_Spent():
      case FrigateEventDto_Disconnected():
        // out of phase-2 scope (see class doc); candidates are untouched.
        break;
    }
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
