import 'dart:typed_data';

import 'package:danawallet/generated/rust/api/structs/amount.dart';
import 'package:danawallet/generated/rust/api/structs/owned_output.dart';
import 'package:danawallet/generated/rust/api/structs/outpoint.dart';
import 'package:danawallet/generated/rust/lib.dart' show U8Array32;
import 'package:danawallet/repositories/frigate_candidates_repository.dart';
import 'package:danawallet/repositories/owned_outputs_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'frigate_candidates_test.dart' show applyMigrations;

/// B6.1/B4.2 — send-availability is computed from CONFIRMED balance only.
///
/// The send path funds payments from `owned_outputs` exclusively:
/// `WalletState._updateWalletState` caches `amount` =
/// `OwnedOutputsRepository.getUnspentBalance()` and `unspentOutputs` =
/// `OwnedOutputsRepository.getUnspentOutputs()`, and both feed
/// `proposeCoinSelection`/`_isDrainPayment`. Frigate candidates live in the
/// separate `frigate_candidates` table (B3.2) and must never leak into either
/// surface until graduation (B3.3) writes them into `owned_outputs`.
const _txidA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _txidB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

FrigateCandidate _candidate({String txid = _txidB, int amountSat = 7000}) {
  return FrigateCandidate(
    txid: txid,
    vout: 0,
    tweak: Uint8List.fromList(List.filled(32, 1)),
    script: Uint8List.fromList([0x51, 0x20]),
    amountSat: amountSat,
    firstSeen: 1700000000,
    source: 'frigate-mempool',
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('PRAGMA foreign_keys = ON');
    await applyMigrations(db);
    OwnedOutputsRepository.testDatabaseOverride = () async => db;
    FrigateCandidatesRepository.testDatabaseOverride = () async => db;
  });

  tearDown(() async {
    OwnedOutputsRepository.testDatabaseOverride = null;
    FrigateCandidatesRepository.testDatabaseOverride = null;
    await db.close();
  });

  /// The confirmed-state write path (B3.3/R3): the transaction row first
  /// (owned_outputs has an FK on transactions.txid), then the output.
  Future<void> insertConfirmedReceipt(
      String txid, int vout, int amountSat) async {
    await db.insert('transactions', {
      'txid': txid,
      'confirmation_height': 900,
      'confirmation_blockhash':
          '0000000000000000000000000000000000000000000000000000000000000001',
    });
    await OwnedOutputsRepository.instance.insertOutput(
      output: OwnedOutput(
        outpoint: OutPoint(txid: txid, vout: vout),
        tweak: U8Array32(Uint8List.fromList(List.filled(32, 2))),
        amount: Amount(field0: BigInt.from(amountSat)),
        script: Uint8List.fromList([0x51, 0x20]),
      ),
    );
  }

  group('B6.1/B4.2 — send-availability from confirmed balance only', () {
    test(
        '(a) a pending candidate never joins availability: confirmed X '
        'stays X, and the candidate outpoint is absent from the spendable set',
        () async {
      await insertConfirmedReceipt(_txidA, 0, 50000);
      await FrigateCandidatesRepository.instance
          .upsertCandidate(_candidate(amountSat: 7000));

      final balance = await OwnedOutputsRepository.instance.getUnspentBalance();
      expect(balance.field0, BigInt.from(50000),
          reason:
              'pending candidate sats leaked into the send-availability balance');

      final outputs = await OwnedOutputsRepository.instance.getUnspentOutputs();
      expect(outputs.map((o) => o.outpoint).toList(),
          [const OutPoint(txid: _txidA, vout: 0)],
          reason: 'the pending candidate outpoint must not be spendable');
    });

    test('(b) after graduation the sats become available (B3.3/B4.2)',
        () async {
      await insertConfirmedReceipt(_txidA, 0, 50000);
      await FrigateCandidatesRepository.instance
          .upsertCandidate(_candidate(amountSat: 7000));

      // Graduation (B3.3): the confirmed-state write into owned_outputs,
      // then the candidate row is marked confirmed.
      await insertConfirmedReceipt(_txidB, 0, 7000);
      await FrigateCandidatesRepository.instance.markConfirmed(_txidB, 0);

      final balance = await OwnedOutputsRepository.instance.getUnspentBalance();
      expect(balance.field0, BigInt.from(57000),
          reason: 'graduated sats must join the send-availability balance');

      final outputs = await OwnedOutputsRepository.instance.getUnspentOutputs();
      expect(
        outputs.map((o) => o.outpoint),
        containsAll([
          const OutPoint(txid: _txidA, vout: 0),
          const OutPoint(txid: _txidB, vout: 0),
        ]),
      );
      expect(outputs, hasLength(2),
          reason: 'the graduated outpoint must appear exactly once');

      final pending =
          await FrigateCandidatesRepository.instance.getPendingBalance();
      expect(pending, 0,
          reason:
              'a confirmed candidate no longer counts as unconfirmed (B4.1)');
    });

    test('(c) a dropped candidate never affects availability (B3.5/B4.2)',
        () async {
      await insertConfirmedReceipt(_txidA, 0, 50000);
      await FrigateCandidatesRepository.instance
          .upsertCandidate(_candidate(amountSat: 7000));
      await FrigateCandidatesRepository.instance.markDropped(_txidB, 0);

      var balance = await OwnedOutputsRepository.instance.getUnspentBalance();
      expect(balance.field0, BigInt.from(50000),
          reason: 'a dropped candidate must never count as spendable');

      // A re-delivered mempool entry re-pends the row (B3.5) — the registry
      // mirrors observation, availability is still unaffected.
      await FrigateCandidatesRepository.instance
          .upsertCandidate(_candidate(amountSat: 7000));
      balance = await OwnedOutputsRepository.instance.getUnspentBalance();
      expect(balance.field0, BigInt.from(50000));

      final outputs = await OwnedOutputsRepository.instance.getUnspentOutputs();
      expect(outputs.map((o) => o.outpoint).toList(),
          [const OutPoint(txid: _txidA, vout: 0)]);
    });
  });
}
