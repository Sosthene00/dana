import 'dart:io';
import 'dart:typed_data';

import 'package:danawallet/generated/rust/api/structs/amount.dart';
import 'package:danawallet/generated/rust/api/structs/frigate_event.dart';
import 'package:danawallet/generated/rust/api/structs/owned_output.dart';
import 'package:danawallet/generated/rust/api/structs/outpoint.dart';
import 'package:danawallet/generated/rust/lib.dart';
import 'package:danawallet/repositories/frigate_candidates_repository.dart';
import 'package:danawallet/services/frigate_event_handler.dart';
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

OwnedOutput ownedOutput({
  String txid = _txidA,
  int vout = 0,
  int amountSat = 1500,
}) {
  return OwnedOutput(
    outpoint: OutPoint(txid: txid, vout: vout),
    tweak: U8Array32(Uint8List.fromList(List.filled(32, 7))),
    amount: Amount(field0: BigInt.from(amountSat)),
    script: Uint8List.fromList([0x51, 0x20]),
  );
}

FrigateEventDto unconfirmedEvent({
  String txid = _txidA,
  List<OwnedOutput> outputs = const [],
}) {
  return FrigateEventDto.unconfirmed(txid: txid, outputs: outputs);
}

void main() {
  group('FrigateEventHandler', () {
    late Database db;
    final repo = FrigateCandidatesRepository.instance;
    late FrigateEventHandler handler;
    late int changeCount;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute('PRAGMA foreign_keys = ON');
      await applyMigrations(db);
      FrigateCandidatesRepository.testDatabaseOverride = () async => db;
      changeCount = 0;
      handler = FrigateEventHandler(
        candidatesRepository: repo,
        onChanged: () => changeCount++,
        // deterministic first_seen for assertions
        nowMillis: () => 1700000000000,
      );
    });

    tearDown(() async {
      FrigateCandidatesRepository.testDatabaseOverride = null;
      await db.close();
    });

    test('B3.1: an Unconfirmed event creates pending candidate rows',
        () async {
      await handler.handleEvent(unconfirmedEvent(
        txid: _txidA,
        outputs: [
          ownedOutput(txid: _txidA, vout: 0, amountSat: 1500),
          ownedOutput(txid: _txidA, vout: 1, amountSat: 2500),
        ],
      ));

      final rows = await db.query('frigate_candidates',
          orderBy: 'vout');
      expect(rows, hasLength(2));
      final first = await repo.getCandidate(_txidA, 0);
      expect(first, isNotNull);
      expect(first!.status, FrigateCandidateStatus.pending);
      expect(first.amountSat, 1500);
      expect(first.txid, _txidA);
      expect(first.vout, 0);
      expect(first.firstSeen, 1700000000000);
      expect(first.source, 'frigate-mempool');
      expect(first.tweak, Uint8List.fromList(List.filled(32, 7)));
      final second = await repo.getCandidate(_txidA, 1);
      expect(second!.amountSat, 2500);
      expect(changeCount, 1, reason: 'onChanged fires after the event');
    });

    test(
        'B3.4: a re-delivered mempool snapshot (re-subscribe) does not double-count',
        () async {
      final snapshot = [
        ownedOutput(txid: _txidA, vout: 0, amountSat: 1500),
        ownedOutput(txid: _txidB, vout: 0, amountSat: 4000),
      ];

      // first subscription delivers the mempool snapshot
      await handler.handleEvent(unconfirmedEvent(outputs: snapshot));
      // re-subscribe re-delivers the SAME snapshot
      await handler.handleEvent(unconfirmedEvent(outputs: snapshot));
      // and again after another reconnect
      await handler.handleEvent(unconfirmedEvent(outputs: snapshot));

      final rows = await db.query('frigate_candidates');
      expect(rows, hasLength(2), reason: 'one row per outpoint, not per delivery');
      expect(await repo.getPendingBalance(), 5500,
          reason: 'balance counted exactly once (B3.4)');
    });

    test('phase-2 scope: non-Unconfirmed events create no candidate rows',
        () async {
      await handler
          .handleEvent(const FrigateEventDto.tip(height: 100, hash: 'ab'));
      await handler.handleEvent(const FrigateEventDto.caughtUp());
      await handler.handleEvent(const FrigateEventDto.disconnected(
          reason: 'connection reset'));
      await handler.handleEvent(FrigateEventDto.confirmed(
          blkheight: 101,
          blkhash: 'ab',
          foundOutputs: [ownedOutput(txid: _txidA, vout: 0)]));
      await handler.handleEvent(const FrigateEventDto.spent(outpoints: [
        OutPoint(txid: _txidA, vout: 0),
      ]));

      final rows = await db.query('frigate_candidates');
      expect(rows, isEmpty,
          reason: 'graduation/confirmation is phase 3 (R5); not this handler');
      expect(changeCount, 0);
    });
  });
}
