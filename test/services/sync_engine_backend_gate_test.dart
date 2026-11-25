// B1.2 regression test (f49c0b7): the frigate backend gates the blindbit
// scan engine.
//
// SyncEngine.trySync() is the periodic sync heartbeat. When the chain backend
// is committed to frigate, the frigate path is subscription-driven end to end
// (B1.2): Dana performs NO blindbit work per heartbeat — no blindbit HTTP
// request, no Rust batch scan invocation, no sync-state DB write. The blindbit
// engine resumes untouched when the backend is switched back (B1.5).
//
// The positive control keeps the backend on blindbit and asserts the same
// heartbeat DOES walk the chain api and invoke the batch scan, so this suite
// cannot silently pass on a broken fixture.
//
// All blindbit network and batch-scan work lives behind the
// flutter_rust_bridge api, so the test injects a recording RustLib mock
// (RustLib.initMock) whose unexpected calls are collected and asserted empty —
// the frigate case proves ABSENCE of blindbit work, not merely absence of the
// three named calls. Storage backends use the in-memory platform mocks and the
// ffi sqlite database already used elsewhere in this suite.
//
// ignore_for_file: unimplemented_noSuchMethod
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:danawallet/generated/rust/api/structs/frigate_event.dart';
import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/generated/rust/api/structs/owned_output.dart';
import 'package:danawallet/generated/rust/api/structs/outpoint.dart';
import 'package:danawallet/generated/rust/api/structs/state_update.dart';
import 'package:danawallet/generated/rust/api/wallet.dart';
import 'package:danawallet/generated/rust/frb_generated.dart';
import 'package:danawallet/repositories/frigate_candidates_repository.dart';
import 'package:danawallet/repositories/owned_outputs_repository.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/repositories/transactions_repository.dart';
import 'package:danawallet/repositories/wallet_repository.dart';
import 'package:danawallet/services/frigate_confirmation_monitor.dart';
import 'package:danawallet/services/frigate_subscription_controller.dart';
import 'package:danawallet/services/sync_engine.dart';
import 'package:danawallet/states/frigate_state.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'frigate_event_handler_test.dart' show applyMigrations;

// storage keys (private constants in the repositories)
const _keyChainBackend = 'chainbackend';
const _keyNetwork = 'network';
const _keyLastSync = 'lastscan';
const _keyScanSk = 'scansk';
const _keySpendKey = 'spendkey';

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

/// Stand-in for the Rust SpWallet opaque: records batch-scan invocations.
class _FakeSpWallet implements SpWallet {
  int syncCalls = 0;
  int? fromHeight;
  int? toHeight;
  String? blindbitUrl;
  int frigateStartCalls = 0;
  String? frigateHostUrl;
  int? frigateStartHeight;
  int frigateOwnedOutputs = 0;

  @override
  Future<void> syncToHeight({
    required int fromHeight,
    required int toHeight,
    required String blindbitUrl,
    required BigInt dustLimit,
    required List<OutPoint> ownedOutpoints,
  }) async {
    syncCalls++;
    this.fromHeight = fromHeight;
    this.toHeight = toHeight;
    this.blindbitUrl = blindbitUrl;
  }

  @override
  Future<void> startFrigateSubscription({
    required String hostUrl,
    required int startHeight,
    required List<OwnedOutput> ownedOutputs,
    Uint32List? labels,
  }) async {
    frigateStartCalls++;
    frigateHostUrl = hostUrl;
    frigateStartHeight = startHeight;
    frigateOwnedOutputs = ownedOutputs.length;
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Recording flutter_rust_bridge api mock.
class _RecordingRustApi implements RustLibApi {
  final _FakeSpWallet wallet = _FakeSpWallet();

  int scanKeyDecodes = 0;
  int spendKeyDecodes = 0;
  int checkNetworkCalls = 0;
  int getChainHeightCalls = 0;
  final List<String> unexpectedApiCalls = [];

  int tip = 500;

  void reset() {
    wallet.syncCalls = 0;
    wallet.fromHeight = null;
    wallet.toHeight = null;
    wallet.blindbitUrl = null;
    wallet.frigateStartCalls = 0;
    wallet.frigateHostUrl = null;
    wallet.frigateStartHeight = null;
    wallet.frigateOwnedOutputs = 0;
    scanKeyDecodes = 0;
    spendKeyDecodes = 0;
    checkNetworkCalls = 0;
    getChainHeightCalls = 0;
    unexpectedApiCalls.clear();
  }

  @override
  ApiScanKey crateApiWalletApiScanKeyDecode({required String encoded}) {
    scanKeyDecodes++;
    return _FakeScanKey();
  }

  @override
  ApiSpendKey crateApiWalletApiSpendKeyDecode({required String encoded}) {
    spendKeyDecodes++;
    return _FakeSpendKey();
  }

  @override
  SpWallet crateApiWalletSpWalletNew({
    required ApiScanKey scanKey,
    required ApiSpendKey spendKey,
    required Network network,
  }) =>
      wallet;

  @override
  Stream<StateUpdate> crateApiStreamCreateSyncResultStream() =>
      const Stream<StateUpdate>.empty();

  @override
  Stream<FrigateEventDto> crateApiStreamCreateFrigateEventStream() =>
      const Stream<FrigateEventDto>.empty();

  @override
  Future<void> crateApiWalletFrigateStopFrigateSubscription() async {}

  @override
  Future<bool> crateApiChainCheckNetwork(
      {required String blindbitUrl, required Network network}) async {
    checkNetworkCalls++;
    return true;
  }

  @override
  Future<int> crateApiChainGetChainHeight({required String blindbitUrl}) async {
    getChainHeightCalls++;
    return tip;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedApiCalls.add(invocation.memberName.toString());
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ONE shared in-memory prefs store for the whole suite:
  // SharedPreferencesAsync captures its platform instance at construction,
  // so the repository singletons keep whatever store was live at their
  // first use. Assigning this same instance in every setUp keeps the
  // singletons' store, the setUp seed data and the raw seedPrefs() helper
  // in this file pointing at the same backing map.
  final sharedPrefs = InMemorySharedPreferencesAsync.withData(const {
    _keyNetwork: 'regtest',
    _keyLastSync: 100,
    _keyChainBackend: 'blindbit',
  });

  final api = _RecordingRustApi();

  setUpAll(() {
    RustLib.initMock(api: api);
    sqfliteFfiInit();
  });

  late Database db;
  late Directory tmpDir;
  var syncStarted = 0;
  var syncComplete = 0;

  SyncEngine buildEngine() {
    syncStarted = 0;
    syncComplete = 0;
    return SyncEngine(
      onSyncStarted: (start, end) => syncStarted++,
      onSyncComplete: (success) => syncComplete++,
      onStateUpdated: (_) async {},
    );
  }

  setUp(() async {
    api.reset();

    // in-memory prefs for the Settings/Wallet repository singletons: a wallet
    // exists (keys in secure storage), lastSync = 100, network = regtest.
    // The SAME instance is reused every test (see sharedPrefs above) so the
    // singletons' captured store and the seed data cannot diverge.
    SharedPreferencesAsyncPlatform.instance = sharedPrefs;

    FlutterSecureStorage.setMockInitialValues(const {
      _keyScanSk: 'encoded-scan-key',
      _keySpendKey: 'encoded-spend-key',
    });

    // a unique temp FILE per test, not ':memory:': the ffi factory keys
    // single-instance ':memory:' databases per isolate (see writer_lease_test).
    tmpDir = await Directory.systemTemp.createTemp('b12-gate-');
    db = await databaseFactoryFfi.openDatabase('${tmpDir.path}/test.db');
    await db.execute('PRAGMA foreign_keys = ON');
    await applyMigrations(db);
    OwnedOutputsRepository.testDatabaseOverride = () async => db;
    TransactionsRepository.testDatabaseOverride = () async => db;
    FrigateCandidatesRepository.testDatabaseOverride = () async => db;
  });

  tearDown(() async {
    FrigateCandidatesRepository.testDatabaseOverride = null;
    OwnedOutputsRepository.testDatabaseOverride = null;
    TransactionsRepository.testDatabaseOverride = null;
    await db.close();
    await tmpDir.delete(recursive: true);
  });

  group('B1.2: frigate backend gates the blindbit scan engine', () {
    test('frigate committed: one heartbeat does no blindbit work', () async {
      await SettingsRepository.instance
          .setChainBackend(ChainBackendKind.frigate);

      final engine = buildEngine();
      await engine.trySync();
      await engine.waitForIdle();

      // no blindbit HTTP request: the chain api is the only network surface
      expect(api.checkNetworkCalls, 0,
          reason: 'no blindbit reachability probe may run');
      expect(api.getChainHeightCalls, 0,
          reason: 'no blindbit tip fetch may run');
      // no Rust batch scan invocation
      expect(api.wallet.syncCalls, 0,
          reason: 'no blindbit batch scan may run (B1.2)');
      // nothing else reached the bridge either
      expect(api.unexpectedApiCalls, isEmpty);
      // no sync-state DB write: lastscan still at its pre-heartbeat value
      expect(await WalletRepository.instance.readLastSync(), 100,
          reason: 'no sync-state DB write may happen');
      // and no sync lifecycle callbacks fired
      expect(syncStarted, 0);
      expect(syncComplete, 0,
          reason: 'the gate returns before any sync lifecycle runs');
    });

    test('blindbit committed (positive control): the heartbeat scans',
        () async {
      await SettingsRepository.instance
          .setChainBackend(ChainBackendKind.blindbit);

      final engine = buildEngine();
      await engine.trySync();
      await engine.waitForIdle();

      expect(api.checkNetworkCalls, 1,
          reason: 'the blindbit engine probes the server network');
      expect(api.getChainHeightCalls, 1,
          reason: 'the blindbit engine reads the tip');
      expect(api.wallet.syncCalls, 1,
          reason: 'the scan path MUST be invoked, otherwise this fixture '
              'cannot distinguish a working gate from a broken one');
      expect(api.wallet.fromHeight, 101);
      expect(api.wallet.toHeight, 500);
      expect(api.wallet.blindbitUrl, isNotEmpty);
      expect(syncStarted, 1);
      expect(syncComplete, 1);
    });
  });

  group('B1.1: backend-default selection (fresh state, no committed backend)',
      () {
    test(
        'nothing configured: the default resolves to blindbit and the '
        'heartbeat walks the blindbit wake-cycle scan', () async {
      // fresh selection state: no committed backend, no frigate URL
      await seedPrefs({_keyNetwork: 'regtest', _keyLastSync: 100});

      final engine = buildEngine();
      await engine.trySync();
      await engine.waitForIdle();

      // B1.1: Blindbit remains the default backend — with nothing committed
      // and nothing configured the selection resolves to (and stays)
      // blindbit.
      expect(await SettingsRepository.instance.getChainBackend(),
          ChainBackendKind.blindbit);
      // the resulting scan path shape is blindbit's wake-cycle one-shot
      // scan: reachability probe, tip fetch, then the batch history scan
      // (lastscan -> tip), with the sync lifecycle callbacks fired.
      expect(api.checkNetworkCalls, 1);
      expect(api.getChainHeightCalls, 1);
      expect(api.wallet.syncCalls, 1,
          reason: 'B1.1: the default backend scans in the blindbit '
              'wake-cycle shape (batch history), not the frigate '
              'subscription shape');
      expect(api.wallet.fromHeight, 101);
      expect(api.wallet.toHeight, 500);
      expect(api.unexpectedApiCalls, isEmpty);
      expect(syncStarted, 1);
      expect(syncComplete, 1);
    });

    test(
        'frigate URL configured, backend never committed: the default '
        'resolves to the frigate backend (R13: the frigate URL is the '
        'electrum-compatible backend)', () async {
      // fresh selection state: no committed backend, but a frigate backend
      // URL is configured — the unset choice must not lose the frigate
      // subscription (the frigate endpoint IS the electrum endpoint, R13).
      await seedPrefs({
        _keyNetwork: 'regtest',
        _keyLastSync: 100,
        'frigateurl': '127.0.0.1:50002',
      });

      final engine = buildEngine();
      await engine.trySync();
      await engine.waitForIdle();

      expect(await SettingsRepository.instance.getChainBackend(),
          ChainBackendKind.frigate);
      // scan path shape: NO blindbit work — the frigate path is
      // subscription-driven end to end (B1.2), the heartbeat gates the
      // blindbit engine off.
      expect(api.checkNetworkCalls, 0,
          reason: 'no blindbit reachability probe under the frigate default');
      expect(api.getChainHeightCalls, 0);
      expect(api.wallet.syncCalls, 0);
      expect(api.unexpectedApiCalls, isEmpty);
      expect(syncStarted, 0);
      expect(syncComplete, 0);
    });
  });

  group('B1.5: blindbit -> frigate switch', () {
    test(
        'a committed blindbit wallet flips to frigate: no blindbit work '
        'after the flip and the fresh subscription starts from the same '
        'committed height', () async {
      // pre-switch: committed blindbit, committed checkpoint lastSync = 100
      await seedPrefs({_keyNetwork: 'regtest', _keyLastSync: 100});
      await SettingsRepository.instance
          .setChainBackend(ChainBackendKind.blindbit);
      final engine = buildEngine();
      await engine.trySync();
      await engine.waitForIdle();
      expect(api.wallet.syncCalls, 1,
          reason: 'pre-switch positive control: the blindbit engine scanned');
      expect(await WalletRepository.instance.readLastSync(), 100);

      // the flip: committed blindbit -> frigate
      await SettingsRepository.instance
          .setChainBackend(ChainBackendKind.frigate);
      await SettingsRepository.instance.setFrigateUrl('127.0.0.1:50002');
      api.reset();

      // post-switch heartbeat: the blindbit engine stays off after the flip
      await engine.trySync();
      await engine.waitForIdle();
      expect(api.checkNetworkCalls, 0,
          reason: 'no blindbit reachability probe after the flip');
      expect(api.getChainHeightCalls, 0,
          reason: 'no blindbit tip fetch after the flip');
      expect(api.wallet.syncCalls, 0,
          reason: 'no blindbit batch scan after the flip (B1.5: no blindbit '
              'work once frigate is committed)');

      // the frigate path resumes from the SAME committed height: the fresh
      // subscription's start_height is the wallet's committed checkpoint
      // (B1.5) — not a rebuild from 0 and not a blindbit lastscan reset.
      final controller = FrigateSubscriptionController(
        frigateState: FrigateState(),
        // phase 3 (the electrum leg) is separately covered by
        // frigate_confirmation_monitor_test.dart; no-op it here so this
        // test stays focused on the switch/start_height semantics.
        confirmationMonitor: _NoopConfirmationMonitor(),
      );
      expect(await controller.start(), isTrue);
      expect(api.wallet.frigateStartCalls, 1);
      expect(api.wallet.frigateStartHeight, 100,
          reason: 'B1.5: start_height on the blindbit->frigate switch is '
              'the committed height (100)');
      expect(api.wallet.frigateHostUrl, '127.0.0.1:50002');
      // no wallet state rebuilt or lost across the switch
      expect(await WalletRepository.instance.readLastSync(), 100);
      await controller.stop();
    });
  });
}

/// NOTE: SharedPreferencesAsync captures its platform instance at
/// construction, and the repository singletons build theirs on first use —
/// reassigning SharedPreferencesAsyncPlatform.instance mid-run does NOT
/// retarget them. Fresh selection state is therefore established through
/// the same captured store (a new SharedPreferencesAsync wrapper over it),
/// not by swapping the platform.
Future<void> seedPrefs(Map<String, Object> data) async {
  final raw = SharedPreferencesAsync();
  await raw.clear();
  for (final entry in data.entries) {
    final v = entry.value;
    if (v is int) {
      await raw.setInt(entry.key, v);
    } else if (v is String) {
      await raw.setString(entry.key, v);
    } else if (v is bool) {
      await raw.setBool(entry.key, v);
    } else {
      throw UnsupportedError('seedPrefs: ${v.runtimeType}');
    }
  }
}

/// Phase-3 no-op for switch tests: the electrum confirmation leg is covered
/// by frigate_confirmation_monitor_test.dart and needs no live endpoint
/// here.
class _NoopConfirmationMonitor extends FrigateConfirmationMonitor {
  @override
  Future<void> start({String? endpoint}) async {}
}
