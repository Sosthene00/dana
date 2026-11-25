// Regression contract test for 4494028: the foreground-service frigate
// writer announces graduation with sendDataToMain({bgKeyRefresh: ...}).
// The main isolate's SyncService._onServiceData maps that flag onto
// WalletState.refreshAfterSync(lastSyncOnly:) — and lastSyncOnly=true
// early-returns BEFORE re-reading the DB. The original bug: graduation was
// announced with `true`, so owned_outputs held the satoshis but the UI
// balance never repainted.
//
// What is pinned here is the CONTRACT across the isolate boundary, not the
// wire encoding:
//   1. the graduation message (bgKeyRefresh: RefreshKind.full) must
//      trigger a FULL DB re-read: walletState.amount and transactions must
//      reflect a receipt seeded directly into owned_outputs/transactions;
//   2. lastSyncOnly semantics must NOT re-read the DB — this is the
//      4494028 bug reproduced in the harness, proving the positive contract
//      would go red if the graduation path ever sent lastSyncOnly again.
//
// The wire payload is the RefreshKind.wireName string ('full' /
// 'lastSyncOnly'); tests pass it as a literal to pin the encoding itself,
// and assert observable wallet state, never the enum instance.
//
// ignore_for_file: unimplemented_noSuchMethod
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:danawallet/constants.dart';
import 'package:danawallet/generated/rust/api/structs/amount.dart';
import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/generated/rust/api/structs/owned_output.dart';
import 'package:danawallet/generated/rust/api/structs/outpoint.dart';
import 'package:danawallet/generated/rust/api/structs/silent_payment_code.dart';
import 'package:danawallet/generated/rust/api/wallet.dart';
import 'package:danawallet/extensions/api_amount.dart';
import 'package:danawallet/generated/rust/frb_generated.dart';
import 'package:danawallet/generated/rust/lib.dart';
import 'package:danawallet/repositories/owned_outputs_repository.dart';
import 'package:danawallet/repositories/transactions_repository.dart';
import 'package:danawallet/services/sync_service.dart';
import 'package:danawallet/states/chain_state.dart';
import 'package:danawallet/states/sync_progress_state.dart';
import 'package:danawallet/states/wallet_state.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'frigate_event_handler_test.dart' show applyMigrations;

// storage keys (private constants in the repositories)
const _keyNetwork = 'network';
const _keyLastSync = 'lastscan';
const _keyScanSk = 'scansk';
const _keySpendKey = 'spendkey';

const _txidReceipt =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

class _FakeScanKey implements ApiScanKey {
  @override
  String encode() => 'fake-scan-key';

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;
}

class _FakeSpendKey implements ApiSpendKey {
  @override
  String encode() => 'fake-spend-key';

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;
}

class _FakePaymentCode implements SilentPaymentCode {
  @override
  String encode() => 'sprt1qfakepaymentcode';

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Stand-in for the Rust SpWallet opaque: serves fake payment codes so
/// WalletState.initialize() can populate its payment-code fields without
/// the native library.
class _FakeSpWallet implements SpWallet {
  final _FakePaymentCode receiving = _FakePaymentCode();
  final _FakePaymentCode change = _FakePaymentCode();

  @override
  SilentPaymentCode getReceivingAddress() => receiving;

  @override
  SilentPaymentCode getChangeAddress() => change;

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Recording flutter_rust_bridge api mock: everything the refresh path
/// touches is served here; anything else is collected and asserted empty.
class _RecordingRustApi implements RustLibApi {
  final _FakeSpWallet wallet = _FakeSpWallet();

  final List<String> unexpectedApiCalls = [];

  void reset() {
    unexpectedApiCalls.clear();
  }

  @override
  ApiScanKey crateApiWalletApiScanKeyDecode({required String encoded}) =>
      _FakeScanKey();

  @override
  ApiSpendKey crateApiWalletApiSpendKeyDecode({required String encoded}) =>
      _FakeSpendKey();

  @override
  SpWallet crateApiWalletSpWalletNew({
    required ApiScanKey scanKey,
    required ApiSpendKey spendKey,
    required Network network,
  }) =>
      wallet;

  @override
  Amount crateApiStructsAmountAmountZero() => Amount(field0: BigInt.zero);

  @override
  Stream<int> crateApiStreamCreateSyncProgressStream() =>
      const Stream<int>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedApiCalls.add(invocation.memberName.toString());
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final api = _RecordingRustApi();

  setUpAll(() {
    RustLib.initMock(api: api);
    sqfliteFfiInit();
  });

  late Database db;
  late Directory tmpDir;
  late WalletState walletState;
  late SyncService syncService;

  /// Seeds an incoming receipt the way the frigate history leg writes it:
  /// a transactions row, then the owned_outputs rows paying it
  /// (owned_outputs has an FK to transactions.txid).
  Future<void> seedReceipt(String txid, int vout, int sats) async {
    await TransactionsRepository.instance.addIncomingTransaction(
      txid: txid,
      confirmationHeight: 500,
      confirmationBlockhash: 'ab' * 32,
    );
    await OwnedOutputsRepository.instance.insertOutput(
      output: OwnedOutput(
        outpoint: OutPoint(txid: txid, vout: vout),
        tweak: U8Array32(Uint8List.fromList(List.filled(32, 1))),
        amount: Amount(field0: BigInt.from(sats)),
        script: Uint8List.fromList([0x51, 0x20]),
      ),
    );
  }

  setUp(() async {
    api.reset();

    // in-memory prefs for the Wallet repository singleton: a wallet exists
    // (keys in secure storage), lastSync = 100, network = regtest.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(const {
      _keyNetwork: 'regtest',
      _keyLastSync: 100,
    });

    FlutterSecureStorage.setMockInitialValues(const {
      _keyScanSk: 'encoded-scan-key',
      _keySpendKey: 'encoded-spend-key',
    });

    // a unique temp FILE per test, not ':memory:': the ffi factory keys
    // single-instance ':memory:' databases per isolate (see writer_lease_test).
    tmpDir = await Directory.systemTemp.createTemp('refresh-contract-');
    db = await databaseFactoryFfi.openDatabase('${tmpDir.path}/test.db');
    await db.execute('PRAGMA foreign_keys = ON');
    await applyMigrations(db);
    OwnedOutputsRepository.testDatabaseOverride = () async => db;
    TransactionsRepository.testDatabaseOverride = () async => db;

    walletState = WalletState.create();
    expect(await walletState.initialize(), isTrue,
        reason: 'the seeded wallet must initialize');

    syncService = SyncService(
      chainState: ChainState(),
      syncProgress: SyncProgressState.create(),
      walletState: walletState,
    );
  });

  tearDown(() async {
    OwnedOutputsRepository.testDatabaseOverride = null;
    TransactionsRepository.testDatabaseOverride = null;
    await db.close();
    await tmpDir.delete(recursive: true);
  });

  group('isolate-boundary refresh contract (4494028 regression)', () {
    test('graduation message (bgKeyRefresh: full) triggers a full DB re-read',
        () async {
      // pre-receipt baseline: the wallet is up, balance is 0
      expect(walletState.amount.toSat(), 0);
      expect(walletState.transactions, isEmpty);

      // the frigate writer graduates a mempool candidate and lands the
      // receipt in the DB while the UI isolate holds a stale WalletState
      await seedReceipt(_txidReceipt, 0, 21000);

      // the graduation message the service-side writer sends (4494028 fix).
      // The handler refreshes asynchronously (unawaited); the re-read is
      // complete when WalletState notifies its listeners (end of
      // refreshAfterSync) — wait for that signal, not for pump ordering.
      var repainted = Completer<void>();
      walletState.addListener(() {
        if (!repainted.isCompleted) repainted.complete();
      });
      syncService.handleServiceData({bgKeyRefresh: 'full'});
      await repainted.future.timeout(const Duration(seconds: 5),
          onTimeout: () =>
              fail('graduation message never triggered the UI refresh'));
      await pumpEventQueue();

      // the full re-read happened: balance and history repaint
      expect(walletState.amount.toSat(), 21000,
          reason: 'graduation must trigger a full owned_outputs re-read');
      expect(walletState.unspentOutputs.length, 1,
          reason: 'unspent outputs cache must be refreshed too');
      expect(walletState.transactions.length, 1,
          reason: 'transaction history must be re-read for the UI');
      expect(api.unexpectedApiCalls, isEmpty);
    });

    test('lastSyncOnly semantics (the 4494028 bug) skip the DB re-read',
        () async {
      expect(walletState.amount.toSat(), 0);

      await seedReceipt(_txidReceipt, 0, 21000);

      // the buggy graduation announcement: the payload carries lastSyncOnly
      // semantics, which early-returns before touching the DB — exactly the
      // stale-balance bug 4494028 fixed.
      syncService.handleServiceData({bgKeyRefresh: 'lastSyncOnly'});
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // no re-read: the balance stays stale. This is the red state the
      // positive contract above would land in if graduation ever sent
      // lastSyncOnly=true semantics again.
      expect(walletState.amount.toSat(), 0,
          reason: 'lastSyncOnly must skip the DB re-read (bug repro)');
      expect(walletState.transactions, isEmpty,
          reason: 'lastSyncOnly must not re-read history either');
    });

    test('untyped bool payload (pre-refactor wire format) is ignored',
        () async {
      expect(walletState.amount.toSat(), 0);

      await seedReceipt(_txidReceipt, 0, 21000);

      // the pre-refactor bool must not silently re-enter the typed path:
      // the payload is logged and dropped, never misinterpreted as a kind.
      syncService.handleServiceData({bgKeyRefresh: false});
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(walletState.amount.toSat(), 0,
          reason: 'a bool payload must not trigger any refresh');
      expect(walletState.transactions, isEmpty,
          reason: 'a bool payload must not trigger a history re-read');
    });
  });
}
