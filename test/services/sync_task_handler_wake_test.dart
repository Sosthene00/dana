// B1.3 wake-path test: the wake trigger handled by SynchronizationTaskHandler
// must run the sync/scan pipeline cycle, and an already-current tip must
// produce a no-op cycle, not a rescan.
//
// The wake paths into the service are `onReceiveData({bgKeySync: true})` (the
// main isolate's wake action) and `onRepeatEvent` (the periodic heartbeat);
// both reduce to `_onReceiveSyncRequest`/`trySync` on the service's engine.
// What is pinned here are the OBSERVABLE effects across the isolate boundary
// and at the bridge, never log text:
//   1. a wake while idle with a stale checkpoint runs a fresh scan cycle —
//      the batch scan is invoked (lastscan+1 -> tip) and the lifecycle
//      messages (bgKeyStartHeight/bgKeyEndHeight, bgKeyComplete) ship to the
//      main isolate;
//   2. a wake on an already-current tip is a no-op cycle: no scan invocation,
//      no bridge traffic, lastscan untouched;
//   3. a wake while a sync is already in flight does not rescan — it re-sends
//      the in-flight progress state to the main isolate;
//   4. with the frigate backend committed a wake does no blindbit work
//      (B1.2/B1.3: the frigate path is subscription-driven; the wake reduces
//      to keeping the subscription alive) and never writes lastscan (B1.4).
//
// The handler is driven for real (onStart -> onReceiveData); the bridge
// messages are captured by registering a ReceivePort under the same
// IsolateNameServer name flutter_foreground_task's sendDataToMain looks up.
// All blindbit network and batch-scan work lives behind the
// flutter_rust_bridge api, so the test injects a recording RustLib mock
// (RustLib.initMock) whose unexpected calls are collected and asserted empty.
// Storage backends use the in-memory platform mocks and the ffi sqlite
// database already used elsewhere in this suite.
//
// ignore_for_file: unimplemented_noSuchMethod
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:danawallet/constants.dart';
import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/generated/rust/api/structs/outpoint.dart';
import 'package:danawallet/generated/rust/api/structs/state_update.dart';
import 'package:danawallet/generated/rust/api/wallet.dart';
import 'package:danawallet/generated/rust/frb_generated.dart';
import 'package:danawallet/repositories/owned_outputs_repository.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/repositories/transactions_repository.dart';
import 'package:danawallet/repositories/wallet_repository.dart';
import 'package:danawallet/services/sync_task_handler.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
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

// private to flutter_foreground_task: the IsolateNameServer name
// FlutterForegroundTask.sendDataToMain sends under.
const _bridgePortName = 'flutter_foreground_task/isolateComPort';

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
/// [pendingScan] parks a scan in flight (wake-while-syncing branch).
class _FakeSpWallet implements SpWallet {
  int syncCalls = 0;
  int? fromHeight;
  int? toHeight;
  Completer<void>? pendingScan;

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
    final pending = pendingScan;
    if (pending != null && !pending.isCompleted) {
      await pending.future;
    }
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

  int tip = 150;

  void reset() {
    wallet.syncCalls = 0;
    wallet.fromHeight = null;
    wallet.toHeight = null;
    wallet.pendingScan = null;
    scanKeyDecodes = 0;
    spendKeyDecodes = 0;
    checkNetworkCalls = 0;
    getChainHeightCalls = 0;
    unexpectedApiCalls.clear();
    tip = 150;
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
  // first use (see sync_engine_backend_gate_test.dart).
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

  // bridge messages the handler sent to the "main isolate"; the port is
  // created fresh per test (single-subscription stream)
  final bridgeMessages = <Object>[];
  ReceivePort? bridgePort;

  int messageCount(bool Function(Map<Object, Object?> message) match) =>
      bridgeMessages.where((m) => m is Map && match(m.cast())).length;

  /// Polls until [cond] holds; fails with [reason] after [timeout].
  Future<void> waitFor(
    bool Function() cond, {
    required String reason,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final end = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(end)) {
        fail('$reason within ${timeout.inMilliseconds} ms');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Lets the initial (service-start) cycle finish and returns the number of
  /// completed scans so far.
  Future<int> startServiceAndSettle(SynchronizationTaskHandler handler,
      {bool scanCompletes = true}) async {
    await handler.onStart(DateTime.now(), TaskStarter.developer);
    if (scanCompletes) {
      await waitFor(() => messageCount((m) => m[bgKeyComplete] == true) >= 1,
          reason: 'service-start cycle did not complete');
    }
    return api.wallet.syncCalls;
  }

  setUp(() async {
    api.reset();

    SharedPreferencesAsyncPlatform.instance = sharedPrefs;

    FlutterSecureStorage.setMockInitialValues(const {
      _keyScanSk: 'encoded-scan-key',
      _keySpendKey: 'encoded-spend-key',
    });

    // a unique temp FILE per test, not ':memory:': the ffi factory keys
    // single-instance ':memory:' databases per isolate (see writer_lease_test).
    tmpDir = await Directory.systemTemp.createTemp('b13-wake-');
    db = await databaseFactoryFfi.openDatabase('${tmpDir.path}/test.db');
    await db.execute('PRAGMA foreign_keys = ON');
    await applyMigrations(db);
    OwnedOutputsRepository.testDatabaseOverride = () async => db;
    TransactionsRepository.testDatabaseOverride = () async => db;

    // capture what the handler sends to the main isolate
    bridgeMessages.clear();
    IsolateNameServer.removePortNameMapping(_bridgePortName);
    bridgePort = ReceivePort();
    expect(
        IsolateNameServer.registerPortWithName(
            bridgePort!.sendPort, _bridgePortName),
        isTrue,
        reason: 'the bridge port must be registered so sendDataToMain is '
            'observable');
    bridgePort!.listen((message) => bridgeMessages.add(message as Object));
  });

  tearDown(() async {
    IsolateNameServer.removePortNameMapping(_bridgePortName);
    bridgePort?.close();
    bridgePort = null;
    OwnedOutputsRepository.testDatabaseOverride = null;
    TransactionsRepository.testDatabaseOverride = null;
    await db.close();
    await tmpDir.delete(recursive: true);
  });

  group('B1.3: the wake path (SynchronizationTaskHandler)', () {
    test(
        'wake while idle and lastscan stale: the trigger runs a fresh '
        'scan cycle', () async {
      final handler = SynchronizationTaskHandler();
      // the service-start cycle runs on its own (unawaited trySync in
      // onStart) and completes: blindbit tip 150 vs lastscan 100.
      final scansAtStart = await startServiceAndSettle(handler);
      expect(scansAtStart, 1,
          reason: 'fixture sanity: the service-start cycle scanned once');

      // THE wake trigger from the main isolate
      handler.onReceiveData({bgKeySync: true});

      // the wake runs its own cycle: a second batch scan...
      await waitFor(() => api.wallet.syncCalls == scansAtStart + 1,
          reason: 'the wake trigger did not run a scan cycle');
      // ...for the still-stale checkpoint (the fake scan emits no
      // StateUpdate, so lastscan stays 100 -> from = 101)
      expect(api.wallet.fromHeight, 101);
      expect(api.wallet.toHeight, 150);
      // ...with the full lifecycle shipped to the main isolate: progress
      // for the wake cycle and its completion
      await waitFor(() => messageCount((m) => m[bgKeyComplete] == true) >= 2,
          reason: 'the wake-driven cycle did not report completion');
      expect(messageCount((m) => m[bgKeyStartHeight] == 101),
          greaterThanOrEqualTo(2),
          reason: 'the wake cycle must announce its progress to the main '
              'isolate');
      expect(api.getChainHeightCalls, greaterThanOrEqualTo(2));
      expect(api.unexpectedApiCalls, isEmpty);
    });

    test('wake on an already-current tip: the cycle no-ops, no rescan',
        () async {
      api.tip = 100; // lastscan (100) is already current
      final handler = SynchronizationTaskHandler();
      await startServiceAndSettle(handler, scanCompletes: false);
      final messagesAtWake = List<Object>.of(bridgeMessages);

      handler.onReceiveData({bgKeySync: true});

      // give both no-op cycles (service start + wake) time to run
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(api.wallet.syncCalls, 0,
          reason: 'an already-current tip must not rescan');
      expect(api.checkNetworkCalls, greaterThanOrEqualTo(1),
          reason: 'fixture sanity: the cycle ran (reachability probe) but '
              'stopped at the currentness check');
      expect(api.getChainHeightCalls, greaterThanOrEqualTo(1));
      expect(bridgeMessages, messagesAtWake,
          reason: 'a no-op cycle ships nothing to the main isolate');
      expect(await WalletRepository.instance.readLastSync(), 100,
          reason: 'lastscan bookkeeping is untouched by a no-op cycle');
      expect(api.unexpectedApiCalls, isEmpty);
    });

    test(
        'wake while a sync is in flight: progress state re-sent, no '
        'rescan', () async {
      // park the service-start scan in flight
      final inFlight = Completer<void>();
      api.wallet.pendingScan = inFlight;
      final handler = SynchronizationTaskHandler();
      await handler.onStart(DateTime.now(), TaskStarter.developer);
      await waitFor(() => api.wallet.syncCalls == 1,
          reason: 'the service-start cycle did not reach the scan');
      await waitFor(() => messageCount((m) => m[bgKeyStartHeight] == 101) >= 1,
          reason: 'the in-flight sync did not announce its progress');
      final messagesAtWake = bridgeMessages.length;

      // THE wake trigger arrives while the sync is running
      handler.onReceiveData({bgKeySync: true});

      await waitFor(() => bridgeMessages.length > messagesAtWake,
          reason: 'the wake did not re-send the in-flight progress state');
      final resent = bridgeMessages.sublist(messagesAtWake);
      expect(resent, hasLength(1));
      expect(resent.first, isA<Map>());
      final resentMessage = (resent.first as Map).cast<Object, Object?>();
      expect(resentMessage[bgKeyStartHeight], 101);
      expect(resentMessage[bgKeyEndHeight], 150);
      expect(api.wallet.syncCalls, 1,
          reason: 'a wake during a running sync must not rescan');

      // drain the parked scan so nothing dangles past the test
      inFlight.complete();
      await waitFor(() => messageCount((m) => m[bgKeyComplete] == true) >= 1,
          reason: 'the in-flight cycle did not complete after drain');
    });

    test(
        'frigate backend committed: a wake does no blindbit work '
        '(B1.2/B1.3)', () async {
      await SettingsRepository.instance
          .setChainBackend(ChainBackendKind.frigate);
      final handler = SynchronizationTaskHandler();
      await handler.onStart(DateTime.now(), TaskStarter.developer);
      // the frigate-gated cycle still enters (reads the wallet) before the
      // gate returns — wait for that, then wake.
      await waitFor(() => api.scanKeyDecodes >= 1,
          reason: 'the service-start cycle did not run');
      final messagesAtWake = List<Object>.of(bridgeMessages);

      handler.onReceiveData({bgKeySync: true});
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(api.checkNetworkCalls, 0,
          reason: 'no blindbit reachability probe on the frigate wake path');
      expect(api.getChainHeightCalls, 0,
          reason: 'no blindbit tip fetch on the frigate wake path');
      expect(api.wallet.syncCalls, 0,
          reason: 'B1.2: no Dana-initiated batch scan on the frigate path');
      expect(bridgeMessages, messagesAtWake,
          reason: 'B1.3: a wake on the frigate path does nothing observable');
      expect(await WalletRepository.instance.readLastSync(), 100,
          reason: 'B1.4: the frigate path never writes lastscan');
      expect(api.unexpectedApiCalls, isEmpty);
    });
  });
}
