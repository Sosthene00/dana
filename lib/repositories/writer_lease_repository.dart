import 'package:danawallet/repositories/database_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

/// One row of the writer lease (B2.8): the identity of the current
/// sync-state writer and the epoch-millis of its last heartbeat.
class WriterLeaseRow {
  final String writerId;
  final int heartbeatMs;

  const WriterLeaseRow({required this.writerId, required this.heartbeatMs});
}

/// DB plumbing for the single-writer lease (B2.8): exactly one row in the
/// `writer_lease` table (migration 003). The lease POLICY (acquire / renew /
/// staleness takeover) lives in `WriterLease` (services/writer_lease.dart).
class WriterLeaseRepository {
  // private constructor
  WriterLeaseRepository._();

  // singleton
  static final instance = WriterLeaseRepository._();

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

  /// The current lease row, or null when no writer holds the lease.
  Future<WriterLeaseRow?> read() async {
    final rows = await (await _db).query(
      'writer_lease',
      where: 'id = 1',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return WriterLeaseRow(
      writerId: rows.first['writer_id'] as String,
      heartbeatMs: rows.first['heartbeat_ms'] as int,
    );
  }

  /// Upsert the lease row (single-row table, id = 1).
  Future<void> write(String writerId, int heartbeatMs) async {
    await (await _db).insert(
      'writer_lease',
      {'id': 1, 'writer_id': writerId, 'heartbeat_ms': heartbeatMs},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Clear the lease (graceful release by its holder).
  Future<void> clear() async {
    await (await _db).delete('writer_lease', where: 'id = 1');
  }
}
