import 'package:danawallet/repositories/database_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:sqflite/sqflite.dart';

/// Lifecycle state of a frigate candidate (B3.1).
enum FrigateCandidateStatus {
  pending,
  confirmed,
  dropped;

  String get dbValue => name;

  static FrigateCandidateStatus fromDb(String value) =>
      FrigateCandidateStatus.values.firstWhere((s) => s.name == value);
}

/// An unconfirmed receipt candidate observed on the frigate path (B3.1).
/// Identity is the outpoint (txid, vout). A candidate never enters
/// `owned_outputs` and is never spendable (B3.2); it counts toward the
/// unconfirmed balance only while `pending` and only graduates to the
/// confirmed state via the phase-3 confirmation path (B3.3).
class FrigateCandidate {
  final String txid;
  final int vout;
  final Uint8List tweak;
  final Uint8List script;
  final int amountSat;
  final int firstSeen;
  final String source;
  final FrigateCandidateStatus status;

  FrigateCandidate({
    required this.txid,
    required this.vout,
    required this.tweak,
    required this.script,
    required this.amountSat,
    required this.firstSeen,
    required this.source,
    this.status = FrigateCandidateStatus.pending,
  });

  FrigateCandidate copyWith({FrigateCandidateStatus? status}) =>
      FrigateCandidate(
        txid: txid,
        vout: vout,
        tweak: tweak,
        script: script,
        amountSat: amountSat,
        firstSeen: firstSeen,
        source: source,
        status: status ?? this.status,
      );

  @override
  String toString() =>
      'FrigateCandidate(${txid}x$vout, $amountSat sat, $source, $status)';
}

class FrigateCandidatesRepository {
  // private constructor
  FrigateCandidatesRepository._();

  // singleton
  static final instance = FrigateCandidatesRepository._();

  /// test seam: when set, unit tests source the database from here instead of
  /// the DatabaseHelper singleton (which needs the asset bundle).
  @visibleForTesting
  static Future<Database> Function()? testDatabaseOverride;

  Future<Database> get _db async {
    final override = testDatabaseOverride;
    if (override != null) {
      return override();
    }
    return DatabaseHelper.instance.database;
  }

  /// reset all candidates
  Future<void> reset() async {
    final db = await _db;
    await db.rawDelete('DELETE FROM frigate_candidates');
  }

  /// Insert or update a candidate, deduplicating on the outpoint (B3.4).
  ///
  /// On conflict the material fields are refreshed but the original
  /// first_seen is kept. A re-delivered mempool entry for a dropped
  /// outpoint reactivates the row to `pending` (B3.5); a confirmed
  /// candidate stays confirmed — it is a dedupe input, not new state
  /// (B3.3).
  Future<void> upsertCandidate(FrigateCandidate candidate) async {
    final db = await _db;
    await db.rawInsert('''
      INSERT INTO frigate_candidates (
        txid, vout, tweak, script, amount_sat, first_seen, source, status
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(txid, vout) DO UPDATE SET
        tweak = excluded.tweak,
        script = excluded.script,
        amount_sat = excluded.amount_sat,
        source = excluded.source,
        status = CASE
          WHEN frigate_candidates.status = 'confirmed'
            THEN 'confirmed'
          ELSE 'pending'
        END
    ''', [
      candidate.txid,
      candidate.vout,
      Uint8List.fromList(candidate.tweak),
      Uint8List.fromList(candidate.script),
      candidate.amountSat,
      candidate.firstSeen,
      candidate.source,
      candidate.status.dbValue,
    ]);
  }

  /// Get a candidate by outpoint, or null if absent.
  Future<FrigateCandidate?> getCandidate(String txid, int vout) async {
    final db = await _db;
    final rows = await db.query(
      'frigate_candidates',
      where: 'txid = ? AND vout = ?',
      whereArgs: [txid, vout],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Get all candidates currently in `pending` status (reconciliation input).
  Future<List<FrigateCandidate>> getPendingCandidates() async {
    final db = await _db;
    final rows = await db.query(
      'frigate_candidates',
      where: 'status = ?',
      whereArgs: [FrigateCandidateStatus.pending.dbValue],
    );
    return rows.map(_fromRow).toList();
  }

  /// Sum of pending candidates in satoshis (unconfirmed balance derivation).
  /// Confirmed and dropped candidates never count (B3.2/B4.2).
  Future<int> getPendingBalance() async {
    final db = await _db;
    final result = await db.rawQuery('''
      SELECT COALESCE(SUM(amount_sat), 0) as total
      FROM frigate_candidates
      WHERE status = ?
    ''', [FrigateCandidateStatus.pending.dbValue]);
    return result.first['total'] as int;
  }

  /// Mark a candidate confirmed (graduation, B3.3). Idempotent.
  Future<void> markConfirmed(String txid, int vout) =>
      _mark(txid, vout, FrigateCandidateStatus.confirmed);

  /// Mark a candidate dropped (evicted/replaced, B3.5). Idempotent.
  Future<void> markDropped(String txid, int vout) =>
      _mark(txid, vout, FrigateCandidateStatus.dropped);

  Future<void> _mark(
      String txid, int vout, FrigateCandidateStatus status) async {
    final db = await _db;
    final count = await db.update(
      'frigate_candidates',
      {'status': status.dbValue},
      where: 'txid = ? AND vout = ?',
      whereArgs: [txid, vout],
    );
    if (count == 0) {
      Logger().w('mark$status marked no candidate: ${txid}x$vout');
    }
  }

  FrigateCandidate _fromRow(Map<String, Object?> row) => FrigateCandidate(
        txid: row['txid'] as String,
        vout: row['vout'] as int,
        tweak: row['tweak'] as Uint8List,
        script: row['script'] as Uint8List,
        amountSat: row['amount_sat'] as int,
        firstSeen: row['first_seen'] as int,
        source: row['source'] as String,
        status: FrigateCandidateStatus.fromDb(row['status'] as String),
      );
}
