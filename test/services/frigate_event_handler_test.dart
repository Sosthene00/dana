import 'dart:io';
import 'dart:typed_data';

import 'package:danawallet/generated/rust/api/structs/amount.dart';
import 'package:danawallet/generated/rust/api/structs/frigate_event.dart';
import 'package:danawallet/generated/rust/api/structs/owned_output.dart';
import 'package:danawallet/generated/rust/api/structs/outpoint.dart';
import 'package:danawallet/generated/rust/lib.dart';
import 'package:danawallet/repositories/frigate_candidates_repository.dart';
import 'package:danawallet/repositories/owned_outputs_repository.dart';
import 'package:danawallet/repositories/transactions_repository.dart';
import 'package:danawallet/repositories/wallet_repository.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:danawallet/services/frigate_event_handler.dart';
import 'package:danawallet/repositories/database_helper.dart';
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
    final statements = splitSqlStatements(sql);
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
  // WalletRepository.instance (SharedPreferencesAsync) initializes at first
  // access — before any group setUp — so the platform mock must be in place
  // before main() declares the groups.
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  group('FrigateEventHandler', () {
    late Database db;
    final repo = FrigateCandidatesRepository.instance;
    late FrigateEventHandler handler;
    late int changeCount;
    late int confirmedCount;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute('PRAGMA foreign_keys = ON');
      await applyMigrations(db);
      FrigateCandidatesRepository.testDatabaseOverride = () async => db;
      OwnedOutputsRepository.testDatabaseOverride = () async => db;
      TransactionsRepository.testDatabaseOverride = () async => db;
      changeCount = 0;
      confirmedCount = 0;
      handler = FrigateEventHandler(
        candidatesRepository: repo,
        onChanged: () => changeCount++,
        onConfirmed: () => confirmedCount++,
        // deterministic first_seen for assertions
        nowMillis: () => 1700000000000,
      );
    });

    tearDown(() async {
      FrigateCandidatesRepository.testDatabaseOverride = null;
      OwnedOutputsRepository.testDatabaseOverride = null;
      TransactionsRepository.testDatabaseOverride = null;
      await db.close();
    });

    test('B3.1: an Unconfirmed event creates pending candidate rows', () async {
      await handler.handleEvent(unconfirmedEvent(
        txid: _txidA,
        outputs: [
          ownedOutput(txid: _txidA, vout: 0, amountSat: 1500),
          ownedOutput(txid: _txidA, vout: 1, amountSat: 2500),
        ],
      ));

      final rows = await db.query('frigate_candidates', orderBy: 'vout');
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
      expect(rows, hasLength(2),
          reason: 'one row per outpoint, not per delivery');
      expect(await repo.getPendingBalance(), 5500,
          reason: 'balance counted exactly once (B3.4)');
    });

    test(
        'R3 scope: lifecycle events (Tip/CaughtUp/Disconnected) touch no state',
        () async {
      await handler
          .handleEvent(const FrigateEventDto.tip(height: 100, hash: 'ab'));
      await handler.handleEvent(const FrigateEventDto.caughtUp());
      await handler.handleEvent(
          const FrigateEventDto.disconnected(reason: 'connection reset'));
      // Spent is no longer lifecycle-only — it writes the confirmed-state
      // layer (B1.4); its behavior is covered by the 'spent leg (B1.4)' group.

      final rows = await db.query('frigate_candidates');
      expect(rows, isEmpty);
      final owned = await db.query('owned_outputs');
      expect(owned, isEmpty);
      expect(changeCount, 0);
      expect(confirmedCount, 0);
    });

    test('R3: a Confirmed history event writes the receipt into owned_outputs',
        () async {
      await handler.handleEvent(FrigateEventDto.confirmed(
          blkheight: 900,
          blkhash: 'ab',
          foundOutputs: [ownedOutput(txid: _txidA, vout: 0, amountSat: 1500)]));

      final owned = await db.query('owned_outputs');
      expect(owned, hasLength(1));
      expect(owned.first['txid'], _txidA);
      expect(owned.first['vout'], 0);
      expect(owned.first['amount_sat'], 1500);
      expect(owned.first['tweak'], Uint8List.fromList(List.filled(32, 7)));
      expect(owned.first['script'], Uint8List.fromList([0x51, 0x20]));
      // the existing confirmed-state path also records the incoming
      // transaction (same as the blindbit sync engine)
      final tx = await db
          .query('transactions', where: 'txid = ?', whereArgs: [_txidA]);
      expect(tx, hasLength(1));
      expect(tx.first['confirmation_height'], 900);
      expect(tx.first['confirmation_blockhash'], 'ab');
      expect(confirmedCount, 1,
          reason: 'the confirmed balance refreshes from the repository');
      expect(changeCount, 1, reason: 'the registry/UI state refreshes');
    });

    test(
        'B3.4: a re-delivered Confirmed event (history replay / re-subscribe) counts exactly once',
        () async {
      FrigateEventDto event() => FrigateEventDto.confirmed(
          blkheight: 900,
          blkhash: 'ab',
          foundOutputs: [ownedOutput(txid: _txidA, vout: 0, amountSat: 1500)]);

      // first subscription replays the history leg...
      await handler.handleEvent(event());
      // ...a re-subscribe re-delivers the SAME confirmed output...
      await handler.handleEvent(event());
      // ...and the supervisor retry after another reconnect does too.
      await handler.handleEvent(event());

      final owned = await db.query('owned_outputs');
      expect(owned, hasLength(1),
          reason: 'one row per outpoint, not per delivery (B3.4)');
      final balance = await OwnedOutputsRepository.instance.getUnspentBalance();
      expect(balance.field0, BigInt.from(1500),
          reason: 'balance counted exactly once (B3.4)');
    });

    test(
        'R3: a Confirmed event whose outpoint is a pending candidate marks the candidate confirmed',
        () async {
      // the payment was seen in the mempool first (phase-2 leg)...
      await handler.handleEvent(unconfirmedEvent(txid: _txidA, outputs: [
        ownedOutput(txid: _txidA, vout: 0, amountSat: 1500),
      ]));
      expect(await repo.getPendingBalance(), 1500);

      // ...then the scanner reports it confirmed (mempool entry got mined).
      await handler.handleEvent(FrigateEventDto.confirmed(
          blkheight: 900,
          blkhash: 'ab',
          foundOutputs: [ownedOutput(txid: _txidA, vout: 0, amountSat: 1500)]));

      final row = await repo.getCandidate(_txidA, 0);
      expect(row, isNotNull);
      expect(row!.status, FrigateCandidateStatus.confirmed,
          reason:
              'the outpoint is confirmed state — it must not also sit in the unconfirmed line (B3.4/B4.1)');
      // repo returns the SUM (0 when no pending rows remain); the null
      // absent-line mapping (B4.1) lives in FrigateState.refresh
      expect(await repo.getPendingBalance(), 0);
      final owned = await db.query('owned_outputs');
      expect(owned, hasLength(1));
      expect(confirmedCount, 1);
    });
  });

  // Owner ruling R14 (2026-11-26): "we should assume that whatever height is
  // synced with one [backend] is ok with the other." The frigate path must
  // advance the SHARED lastscan checkpoint monotonically — switching
  // frigate -> blindbit must never re-derive a stale checkpoint and rescan.
  group('FrigateEventHandler — shared sync checkpoint (R14)', () {
    late Database db;
    final walletRepo = WalletRepository.instance;
    late FrigateEventHandler handler;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute('PRAGMA foreign_keys = ON');
      await applyMigrations(db);
      FrigateCandidatesRepository.testDatabaseOverride = () async => db;
      OwnedOutputsRepository.testDatabaseOverride = () async => db;
      TransactionsRepository.testDatabaseOverride = () async => db;
      handler = FrigateEventHandler(
        candidatesRepository: FrigateCandidatesRepository.instance,
        nowMillis: () => 1700000000000,
      );
    });

    tearDown(() async {
      FrigateCandidatesRepository.testDatabaseOverride = null;
      OwnedOutputsRepository.testDatabaseOverride = null;
      TransactionsRepository.testDatabaseOverride = null;
      await db.close();
    });

    test(
        'R14: a Confirmed event advances the shared lastscan checkpoint to its blkheight',
        () async {
      await walletRepo.saveLastSync(10909);
      await handler.handleEvent(FrigateEventDto.confirmed(
          blkheight: 14644,
          blkhash: 'ab',
          foundOutputs: [ownedOutput(txid: _txidA, vout: 0, amountSat: 1500)]));
      expect(await walletRepo.readLastSync(), 14644);
    });

    test('R14: the checkpoint never rewinds (a lower height is ignored)',
        () async {
      await walletRepo.saveLastSync(15000);
      await handler.handleEvent(FrigateEventDto.confirmed(
          blkheight: 14644,
          blkhash: 'ab',
          foundOutputs: [ownedOutput(txid: _txidA, vout: 0, amountSat: 1500)]));
      expect(await walletRepo.readLastSync(), 15000);
    });

    test('R14: CaughtUp advances the checkpoint to the last seen Tip height',
        () async {
      await walletRepo.saveLastSync(10909);
      await handler
          .handleEvent(const FrigateEventDto.tip(height: 14644, hash: 'cd'));
      // the scanner emits Confirmed only on discovery: a quiet chain delivers
      // no Confirmed events, so the Tip->CaughtUp pair is the only source of
      // the synced-through height on quiet blocks
      await handler.handleEvent(const FrigateEventDto.caughtUp());
      expect(await walletRepo.readLastSync(), 14644);
    });

    test('R14: CaughtUp without a Tip never moves the checkpoint', () async {
      await walletRepo.saveLastSync(15000);
      await handler.handleEvent(const FrigateEventDto.caughtUp());
      expect(await walletRepo.readLastSync(), 15000);
    });

    test('R14: Unconfirmed (mempool) events never touch the checkpoint',
        () async {
      await walletRepo.saveLastSync(15000);
      await handler.handleEvent(unconfirmedEvent(txid: _txidA, outputs: [
        ownedOutput(txid: _txidA, vout: 0, amountSat: 1500),
      ]));
      expect(await walletRepo.readLastSync(), 15000);
    });
  });

  // B1.4: "Both backends write the same confirmed-state layer (owned_outputs
  // + tx_spent_outpoints); balance semantics are backend-independent." The
  // blindbit path records spends (SyncEngine._onSyncResult foundInputs);
  // the frigate path MUST do the same from the scanner's Spent events —
  // the scanner carries no block height, so the confirmation leg uses the
  // last seen Tip (height + hash, the first event of every subscription).
  // The Spent leg never advances the checkpoint (R14 stays where it is).
  group('FrigateEventHandler — spent leg (B1.4)', () {
    late Database db;
    late FrigateEventHandler handler;
    late int changeCount;
    late int confirmedCount;

    const spendTxid =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    const spentOutpoint = OutPoint(txid: _txidA, vout: 0);

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await db.execute('PRAGMA foreign_keys = ON');
      await applyMigrations(db);
      FrigateCandidatesRepository.testDatabaseOverride = () async => db;
      OwnedOutputsRepository.testDatabaseOverride = () async => db;
      TransactionsRepository.testDatabaseOverride = () async => db;
      changeCount = 0;
      confirmedCount = 0;
      handler = FrigateEventHandler(
        candidatesRepository: FrigateCandidatesRepository.instance,
        onChanged: () => changeCount++,
        onConfirmed: () => confirmedCount++,
        nowMillis: () => 1700000000000,
      );
    });

    tearDown(() async {
      FrigateCandidatesRepository.testDatabaseOverride = null;
      OwnedOutputsRepository.testDatabaseOverride = null;
      TransactionsRepository.testDatabaseOverride = null;
      await db.close();
    });

    Future<void> seedOwnedOutput({int amountSat = 100000}) async {
      // owned_outputs carries a FK to transactions(txid) — record the
      // incoming transaction that produced the output first.
      await TransactionsRepository.instance.addIncomingTransaction(
        txid: _txidA,
        confirmationHeight: 14800,
        confirmationBlockhash: 'seed',
      );
      await OwnedOutputsRepository.instance
          .insertOutput(output: ownedOutput(amountSat: amountSat));
    }

    test(
        'B1.4: a Spent event confirms a pending outgoing transaction (self-spend leg)',
        () async {
      await seedOwnedOutput();
      // the Pay flow already recorded the outgoing tx (unconfirmed) with its
      // spent outpoint; the scanner then reports the spend from history.
      await TransactionsRepository.instance.addOutgoingTransaction(
        txid: spendTxid,
        spentOutpoints: [spentOutpoint],
        recipients: [],
      );
      // the broadcast already wrote the spent outpoint, so the balance has
      // already dropped — what the Spent leg adds is the CONFIRMATION of the
      // outgoing transaction (height/hash), which the stub never wrote.
      expect(
          (await OwnedOutputsRepository.instance.getUnspentBalance()).field0,
          BigInt.zero);

      await handler
          .handleEvent(const FrigateEventDto.tip(height: 14847, hash: 'hh'));
      await handler
          .handleEvent(const FrigateEventDto.spent(outpoints: [spentOutpoint]));

      final tx = await db.query('transactions',
          where: 'txid = ?', whereArgs: [spendTxid]);
      expect(tx, hasLength(1));
      expect(tx.first['confirmation_height'], 14847,
          reason: 'the outgoing tx confirms at the last seen Tip height');
      expect(tx.first['confirmation_blockhash'], 'hh');
      final spent = await db.query('tx_spent_outpoints');
      expect(spent, hasLength(1));
      expect(spent.first['outpoint_txid'], _txidA);
      expect(spent.first['outpoint_vout'], 0);
      // device-observable (B1.4): the balance drops by the spent amount.
      expect(
          (await OwnedOutputsRepository.instance.getUnspentBalance()).field0,
          BigInt.zero);
      expect(confirmedCount, 1,
          reason: 'the confirmed balance refreshes from the repository');
      expect(changeCount, 1, reason: 'the UI state refreshes');
    });

    test(
        'B1.4: a Spent event with no matching outgoing tx records an unknown spend',
        () async {
      // no outgoing tx row: the spend came from a foreign broadcast
      // (multi-wallet import). The outpoint must still leave the balance.
      await seedOwnedOutput();
      expect(
          (await OwnedOutputsRepository.instance.getUnspentBalance()).field0,
          BigInt.from(100000));

      await handler
          .handleEvent(const FrigateEventDto.tip(height: 14847, hash: 'hh'));
      await handler
          .handleEvent(const FrigateEventDto.spent(outpoints: [spentOutpoint]));

      final tx = await db.query('transactions', where: 'txid IS NULL');
      expect(tx, hasLength(1));
      expect(tx.first['txid'], isNull,
          reason: 'mirrors the blindbit unknown-spend branch: txid null');
      expect(tx.first['confirmation_height'], 14847);
      expect(tx.first['confirmation_blockhash'], 'hh');
      final spent = await db.query('tx_spent_outpoints');
      expect(spent, hasLength(1));
      expect(spent.first['outpoint_txid'], _txidA);
      expect(spent.first['outpoint_vout'], 0);
      expect(
          (await OwnedOutputsRepository.instance.getUnspentBalance()).field0,
          BigInt.zero,
          reason: 'balance drops by the spent amount (B1.4)');
      expect(confirmedCount, 1);
      expect(changeCount, 1);
    });

    test(
        'B3.4: a re-delivered Spent event (re-subscribe history sweep) records exactly once',
        () async {
      await seedOwnedOutput();
      await handler
          .handleEvent(const FrigateEventDto.tip(height: 14847, hash: 'hh'));
      const event = FrigateEventDto.spent(outpoints: [spentOutpoint]);
      await handler.handleEvent(event);
      await handler.handleEvent(event);

      final tx = await db.query('transactions', where: 'txid IS NULL');
      expect(tx, hasLength(1),
          reason: 'one outgoing row, not one per delivery');
      final spent = await db.query('tx_spent_outpoints');
      expect(spent, hasLength(1), reason: 'one spent row (B3.4 dedupe)');
      expect(
          (await OwnedOutputsRepository.instance.getUnspentBalance()).field0,
          BigInt.zero);
    });

    test(
        'a Spent event before any Tip still records the spend (unconfirmed height)',
        () async {
      await seedOwnedOutput();
      await handler
          .handleEvent(const FrigateEventDto.spent(outpoints: [spentOutpoint]));

      final tx = await db.query('transactions', where: 'txid IS NULL');
      expect(tx, hasLength(1));
      expect(tx.first['confirmation_height'], isNull,
          reason: 'no tip seen — the spend is recorded, height unknown');
      final spent = await db.query('tx_spent_outpoints');
      expect(spent, hasLength(1));
      expect(
          (await OwnedOutputsRepository.instance.getUnspentBalance()).field0,
          BigInt.zero);
    });
  });
}
