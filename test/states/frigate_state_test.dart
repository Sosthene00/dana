import 'dart:io';
import 'dart:typed_data';

import 'package:danawallet/repositories/frigate_candidates_repository.dart';
import 'package:danawallet/states/frigate_state.dart';
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
  FrigateCandidateStatus status = FrigateCandidateStatus.pending,
}) {
  return FrigateCandidate(
    txid: txid,
    vout: vout,
    tweak: Uint8List.fromList(List.filled(32, 1)),
    script: Uint8List.fromList([0x51, 0x20]),
    amountSat: amountSat,
    firstSeen: 1700000000,
    source: 'frigate-mempool',
    status: status,
  );
}

void main() {
  group('FrigateState', () {
    late Database db;
    final repo = FrigateCandidatesRepository.instance;
    late FrigateState state;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute('PRAGMA foreign_keys = ON');
      await applyMigrations(db);
      FrigateCandidatesRepository.testDatabaseOverride = () async => db;
      state = FrigateState(candidatesRepository: repo);
    });

    tearDown(() async {
      FrigateCandidatesRepository.testDatabaseOverride = null;
      await db.close();
    });

    test('B4.1: with no candidates the unconfirmed balance is absent (null)',
        () async {
      await state.refresh();
      expect(state.pendingBalanceSat, isNull,
          reason: 'absent, not zero, when there are no candidates (B4.1)');
    });

    test('B4.1: pending candidates sum into the unconfirmed balance',
        () async {
      await repo.upsertCandidate(candidate(amountSat: 1500));
      await repo.upsertCandidate(candidate(txid: _txidB, amountSat: 2500));

      await state.refresh();
      expect(state.pendingBalanceSat, 4000);
    });

    test('B4.2/B3.2: only pending candidates count; confirmed/dropped never',
        () async {
      await repo.upsertCandidate(candidate(amountSat: 1500));
      await repo.upsertCandidate(
          candidate(txid: _txidB, amountSat: 9999, status: FrigateCandidateStatus.dropped));
      await repo.upsertCandidate(candidate(
          txid: _txidB, vout: 1, amountSat: 7777, status: FrigateCandidateStatus.confirmed));

      await state.refresh();
      expect(state.pendingBalanceSat, 1500);
    });

    test('refresh() updates after the candidate set changes', () async {
      await repo.upsertCandidate(candidate(amountSat: 1500));
      await state.refresh();
      expect(state.pendingBalanceSat, 1500);

      await repo.markConfirmed(_txidA, 0);
      await state.refresh();
      expect(state.pendingBalanceSat, isNull,
          reason: 'graduation clears the unconfirmed line (B4.2)');
    });
  });
}
