import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danawallet/data/models/recorded_transaction.dart';
import 'package:danawallet/generated/rust/api/structs/amount.dart';
import 'package:danawallet/generated/rust/frb_generated.dart';
import 'package:danawallet/repositories/database_helper.dart';
import 'package:danawallet/repositories/transactions_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Gate-(d) companion of the lossy-marshal fix: a tx_recipients row whose
// payment_code is OP_RETURN-shaped (lowercase hex - the text form older builds
// wrote for a wallet Data address) or outright unparseable must load through
// getAllTransactions as a degraded Recipient carrying the raw payload, instead
// of the PaymentCode.parse throw that aborted the whole transaction read.
// Amounts must survive on the recipients list (mainline parity: a non-change
// row always counts toward the send total).
const _txid = 'aa11bb22cc33dd44ee55ff6677889900aa11bb22cc33dd44ee55ff6677889900';
const _spPayee =
    'sp1qq2xewwk5u02gxxurdzr6r6jerelncw82rlyvw2kpggxt3pum4kp6yq62utdcljdtmxpy3vs7c940hvjuzedhhsf7h2y5lflk7zp2xhgz3vryqw4n';
const _opReturnPayload = '6a057468652074616c6b';
const _garbageCode = 'SP1QOURS-GARBAGE';
const _receiveCode = 'rc@dana.example';
const _changeCode = 'cc@dana.example';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await RustLib.init();
    // Stale on-disk databases poison later runs; DatabaseHelper resolves
    // $HOME/.dana on linux, the ffi fallback lives under .dart_tool.
    final home = Platform.environment['HOME'] ?? '.';
    for (final p in [
      '$home/.dana/dana.db',
      '.dart_tool/sqflite_common_ffi/databases/dana.db',
    ]) {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    }
  });

  tearDownAll(() async => DatabaseHelper.instance.close());

  group(
      'getAllTransactions loads legacy OP_RETURN / unparseable recipient rows',
      () {
    late Database db;

    setUp(() async {
      db = await DatabaseHelper.instance.database;
      await db.delete('tx_recipients');
      await db.delete('tx_spent_outpoints');
      await db.delete('owned_outputs');
      await db.delete('transactions');

      await db.insert('transactions', {
        'txid': _txid,
        'confirmation_height': 800000,
        'confirmation_blockhash': '00' * 32,
        'confirmation_timestamp': 1700000000,
      });
      final txRow =
          (await db.query('transactions', where: 'txid = ?', whereArgs: [_txid]))
              .first;
      final transactionId = txRow['id'] as int;

      // A self-owned input this tx spends: spentSum > 0 pushes the row into
      // the outgoing branch that marshals tx_recipients through the frb layer.
      await db.insert('owned_outputs', {
        'txid': _txid,
        'vout': 0,
        'tweak': Uint8List.fromList(<int>[1, 2, 3]),
        'amount_sat': 100000,
        'script': Uint8List.fromList(<int>[0, 14, 99]),
      });
      await db.insert('tx_spent_outpoints', {
        'transaction_id': transactionId,
        'outpoint_txid': _txid,
        'outpoint_vout': 0,
      });

      final rows = <List<Object>>[
        [_spPayee, 50000],
        [_opReturnPayload, 10000],
        [_garbageCode, 7],
      ];
      for (final r in rows) {
        await db.insert('tx_recipients', {
          'transaction_id': transactionId,
          'payment_code': r[0] as String,
          'amount_sat': r[1] as int,
        });
      }
    });

    test(
        'OP_RETURN-shaped and garbage rows load degraded instead of aborting the read',
        () async {
      final txs = await TransactionsRepository.instance
          .getAllTransactions(_receiveCode, _changeCode);

      expect(txs, hasLength(1));
      final outgoing = txs.single as RecordedTransactionOutgoing;
      // Pre-fix, marshalling threw at the first unparseable row and the whole
      // read died; all three rows must survive now.
      expect(outgoing.recipients, hasLength(3));

      final encoded =
          outgoing.recipients.map((r) => r.paymentCode.encode()).toList();
      expect(encoded, containsAll([_spPayee, _opReturnPayload, _garbageCode]));

      Amount amountOf(String code) => outgoing.recipients
          .firstWhere((r) => r.paymentCode.encode() == code)
          .amount;
      expect(amountOf(_opReturnPayload).field0, BigInt.from(10000));
      expect(amountOf(_garbageCode).field0, BigInt.from(7));
    });
  });
}
