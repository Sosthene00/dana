import 'dart:io';
import 'dart:typed_data';

import 'package:danawallet/repositories/frigate_candidates_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Applies the real migration assets from the repo, mirroring how
/// DatabaseHelper._performMigrations executes them (alphabetical order,
/// statements split on ';').
Future<void> applyMigrations(Database db) async {
  final dir = Directory('assets/sql/migrations');
  final files = dir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final sql = await f.readAsString();
    final statements =
        sql.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty);
    for (final stmt in statements) {
      await db.execute(stmt);
    }
  }
}

const _txidA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _txidB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

FrigateCandidate candidate({
  String txid = _txidA,
  int vout = 0,
  int amountSat = 1000,
  String source = 'mempool_scan',
  int firstSeen = 1700000000,
  FrigateCandidateStatus status = FrigateCandidateStatus.pending,
}) {
  return FrigateCandidate(
    txid: txid,
    vout: vout,
    tweak: Uint8List.fromList(List.filled(32, 1)),
    script: Uint8List.fromList([0x51, 0x20]),
    amountSat: amountSat,
    firstSeen: firstSeen,
    source: source,
    status: status,
  );
}

Map<String, Object> candidateRow({
  String txid = _txidA,
  int vout = 0,
  int amountSat = 1000,
  String source = 'mempool_scan',
  String status = 'pending',
}) {
  return {
    'txid': txid,
    'vout': vout,
    'tweak': Uint8List.fromList(List.filled(32, 1)),
    'script': Uint8List.fromList([0x51, 0x20]),
    'amount_sat': amountSat,
    'first_seen': 1700000000,
    'source': source,
    'status': status,
  };
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('migration 002 — frigate_candidates table (B3.1)', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute('PRAGMA foreign_keys = ON');
      await applyMigrations(db);
    });

    tearDown(() async => db.close());

    test('frigate_candidates table exists with the B3.1 fields', () async {
      final cols = await db.rawQuery('PRAGMA table_info(frigate_candidates)');
      final names = cols.map((c) => c['name'] as String).toSet();
      expect(
        names,
        containsAll([
          'txid',
          'vout',
          'tweak',
          'script',
          'amount_sat',
          'first_seen',
          'source',
          'status',
        ]),
      );
    });

    test('identity is the outpoint: (txid, vout) is unique', () async {
      await db.insert('frigate_candidates', candidateRow());
      await expectLater(
        db.insert('frigate_candidates', candidateRow(source: 'history_replay')),
        throwsA(anything),
      );
      final rows = await db.query('frigate_candidates');
      expect(rows, hasLength(1));
    });

    test('status is restricted to pending|confirmed|dropped', () async {
      await expectLater(
        db.insert(
          'frigate_candidates',
          candidateRow(status: 'graduated'),
        ),
        throwsA(anything),
      );
    });

    test('status defaults to pending', () async {
      final row = candidateRow()..remove('status');
      await db.insert('frigate_candidates', row);
      final rows = await db.query('frigate_candidates');
      expect(rows.single['status'], 'pending');
    });

    test('confirmed-state schema is untouched by the migration', () async {
      final owned = await db.rawQuery('PRAGMA table_info(owned_outputs)');
      final ownedNames = owned.map((c) => c['name'] as String).toSet();
      expect(
        ownedNames,
        containsAll(['txid', 'vout', 'tweak', 'amount_sat', 'script', 'label']),
      );
      final spent = await db.rawQuery('PRAGMA table_info(tx_spent_outpoints)');
      expect(spent, isNotEmpty);
    });
  });

  group('FrigateCandidatesRepository', () {
    late Database db;
    final repo = FrigateCandidatesRepository.instance;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute('PRAGMA foreign_keys = ON');
      await applyMigrations(db);
      FrigateCandidatesRepository.testDatabaseOverride = () async => db;
    });

    tearDown(() async {
      FrigateCandidatesRepository.testDatabaseOverride = null;
      await db.close();
    });

    group('upsert dedupes on the outpoint (B3.4)', () {
      test('re-upserting the same outpoint keeps a single row', () async {
        await repo.upsertCandidate(candidate());
        await repo.upsertCandidate(
          candidate(source: 'history_replay', amountSat: 2000),
        );

        final rows = await db.query('frigate_candidates');
        expect(rows, hasLength(1));
        final stored = await repo.getCandidate(_txidA, 0);
        expect(stored, isNotNull);
        expect(stored!.source, 'history_replay');
        expect(stored.amountSat, 2000);
      });

      test('different vouts are distinct candidates', () async {
        await repo.upsertCandidate(candidate(vout: 0));
        await repo.upsertCandidate(candidate(vout: 1));

        final rows = await db.query('frigate_candidates');
        expect(rows, hasLength(2));
      });

      test('re-upsert keeps the original first_seen', () async {
        await repo.upsertCandidate(candidate(firstSeen: 1000));
        await repo.upsertCandidate(candidate(firstSeen: 2000));

        final stored = await repo.getCandidate(_txidA, 0);
        expect(stored!.firstSeen, 1000);
      });
    });

    group('status transitions', () {
      test('pending -> confirmed', () async {
        await repo.upsertCandidate(candidate());
        await repo.markConfirmed(_txidA, 0);

        final stored = await repo.getCandidate(_txidA, 0);
        expect(stored!.status, FrigateCandidateStatus.confirmed);
      });

      test('pending -> dropped', () async {
        await repo.upsertCandidate(candidate());
        await repo.markDropped(_txidA, 0);

        final stored = await repo.getCandidate(_txidA, 0);
        expect(stored!.status, FrigateCandidateStatus.dropped);
      });

      test('mark transitions are idempotent', () async {
        await repo.upsertCandidate(candidate());
        await repo.markConfirmed(_txidA, 0);
        await repo.markConfirmed(_txidA, 0);

        final stored = await repo.getCandidate(_txidA, 0);
        expect(stored!.status, FrigateCandidateStatus.confirmed);
      });
    });

    group('re-delivery semantics (B3.3/B3.5)', () {
      test('re-delivered mempool entry reactivates a dropped outpoint',
          () async {
        await repo.upsertCandidate(candidate());
        await repo.markDropped(_txidA, 0);
        await repo.upsertCandidate(candidate(source: 'mempool_scan'));

        final stored = await repo.getCandidate(_txidA, 0);
        expect(stored!.status, FrigateCandidateStatus.pending);
      });

      test('re-delivery never re-pends a confirmed candidate (B3.3)', () async {
        await repo.upsertCandidate(candidate());
        await repo.markConfirmed(_txidA, 0);
        await repo.upsertCandidate(candidate(source: 'history_replay'));

        final stored = await repo.getCandidate(_txidA, 0);
        expect(stored!.status, FrigateCandidateStatus.confirmed);
      });
    });

    group('unconfirmed-balance derivation', () {
      test('sums pending candidates only', () async {
        await repo.upsertCandidate(candidate(txid: _txidA, amountSat: 1000));
        await repo.upsertCandidate(candidate(txid: _txidB, amountSat: 500));
        await repo.markConfirmed(_txidA, 0);
        await repo.upsertCandidate(candidate(vout: 2, amountSat: 700));
        await repo.markDropped(_txidA, 2);
        await repo.upsertCandidate(candidate(vout: 3, amountSat: 250));

        expect(await repo.getPendingBalance(), 250 + 500);
      });

      test('empty registry sums to zero', () async {
        expect(await repo.getPendingBalance(), 0);
      });
    });

    group('pending candidate listing', () {
      test('getPendingCandidates returns only pending rows', () async {
        await repo.upsertCandidate(candidate(txid: _txidA, vout: 0));
        await repo.upsertCandidate(candidate(txid: _txidA, vout: 1));
        await repo.upsertCandidate(candidate(txid: _txidB, vout: 0));
        await repo.markConfirmed(_txidA, 0);
        await repo.markDropped(_txidA, 1);

        final pending = await repo.getPendingCandidates();
        expect(pending, hasLength(1));
        expect(pending.single.txid, _txidB);
      });
    });

    group('B3.2 — candidates never enter the confirmed state', () {
      test('candidate rows never appear in owned_outputs', () async {
        await repo.upsertCandidate(candidate());
        await repo.markConfirmed(_txidA, 0);

        final owned = await db.query('owned_outputs');
        expect(owned, isEmpty);
      });
    });
  });
}
