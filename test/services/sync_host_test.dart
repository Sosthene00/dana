// Host contract: one scanner, apply swaps without releasing the lease,
// a live service lease keeps the app isolate from starting a scanner,
// and a Blindbit confirmed-state write throws when a foreign lease is fresh.
//
// ignore_for_file: unimplemented_noSuchMethod
import 'dart:async';
import 'dart:io';

import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/generated/rust/api/structs/state_update.dart';
import 'package:danawallet/generated/rust/api/wallet.dart';
import 'package:danawallet/generated/rust/frb_generated.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/repositories/wallet_repository.dart';
import 'package:danawallet/repositories/writer_lease_repository.dart';
import 'package:danawallet/services/service_liveness.dart';
import 'package:danawallet/services/sync_engine.dart';
import 'package:danawallet/services/sync_host.dart';
import 'package:danawallet/services/sync_service.dart';
import 'package:danawallet/services/writer_lease.dart';
import 'package:danawallet/states/chain_state.dart';
import 'package:danawallet/states/frigate_state.dart';
import 'package:danawallet/states/sync_progress_state.dart';
import 'package:danawallet/states/wallet_state.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'frigate_event_handler_test.dart' show applyMigrations;

const _keyNetwork = 'network';
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

class _FakeWallet implements SpWallet {
  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _RustApi implements RustLibApi {
  @override
  Stream<int> crateApiStreamCreateSyncProgressStream() =>
      const Stream<int>.empty();

  @override
  Stream<StateUpdate> crateApiStreamCreateSyncResultStream() =>
      const Stream<StateUpdate>.empty();

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
      _FakeWallet();

  @override
  Future<bool> crateApiChainCheckNetwork(
          {required String blindbitUrl, required Network network}) async =>
      true;

  @override
  Future<int> crateApiChainGetChainHeight(
          {required String blindbitUrl}) async =>
      50;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeScanner implements SyncScanner {
  _FakeScanner(this.kind, this.log);

  @override
  final ChainBackendKind kind;
  final List<String> log;
  Completer<void>? stopGate;

  @override
  Future<void> start() async {
    log.add('${kind.name}.start');
  }

  @override
  Future<void> stop({bool drain = true}) async {
    log.add('${kind.name}.stop-begin');
    final gate = stopGate;
    if (gate != null) await gate.future;
    log.add('${kind.name}.stop-end');
  }

  @override
  Future<void> wake() async {
    log.add('${kind.name}.wake');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sharedPrefs = InMemorySharedPreferencesAsync.withData(const {
    _keyNetwork: 'regtest',
  });

  setUpAll(() {
    RustLib.initMock(api: _RustApi());
    sqfliteFfiInit();
  });

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = sharedPrefs;
  });

  group('SyncHost slot', () {
    late Database db;
    late Directory tmpDir;
    late WriterLease lease;
    final log = <String>[];
    final constructed = <ChainBackendKind>[];
    _FakeScanner? blindbit;
    SyncHost? host;

    setUp(() async {
      log.clear();
      constructed.clear();
      blindbit = null;
      await SharedPreferencesAsync().clear();
      await SharedPreferencesAsync().setString(_keyNetwork, 'regtest');
      await SettingsRepository.instance
          .setChainBackend(ChainBackendKind.blindbit);

      tmpDir = await Directory.systemTemp.createTemp('sync-host-');
      db = await databaseFactoryFfi.openDatabase('${tmpDir.path}/test.db');
      await db.execute('PRAGMA foreign_keys = ON');
      await applyMigrations(db);
      WriterLeaseRepository.testDatabaseOverride = () async => db;

      lease = WriterLease(writerId: WriterLease.appWriterId);
      host = SyncHost(
        lease: lease,
        buildScanner: (kind, _) {
          final scanner = _FakeScanner(kind, log);
          constructed.add(kind);
          if (kind == ChainBackendKind.blindbit) blindbit = scanner;
          return scanner;
        },
      );
    });

    tearDown(() async {
      await host?.stop();
      WriterLeaseRepository.testDatabaseOverride = null;
      await db.close();
      await tmpDir.delete(recursive: true);
    });

    test('startup constructs only the committed scanner', () async {
      await host!.start();
      expect(constructed, [ChainBackendKind.blindbit]);
      expect(log, ['blindbit.start']);
      expect(lease.ownsLease, isTrue);
    });

    test(
        'applyBackend stops the occupant before starting the other and '
        'does not release the lease', () async {
      await host!.start();
      final gate = Completer<void>();
      blindbit!.stopGate = gate;

      await SettingsRepository.instance
          .setChainBackend(ChainBackendKind.frigate);
      final apply = host!.applyBackend();

      final end = DateTime.now().add(const Duration(seconds: 5));
      while (!log.contains('blindbit.stop-begin')) {
        if (DateTime.now().isAfter(end)) {
          fail('apply did not begin stopping the occupant');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(log.contains('frigate.start'), isFalse,
          reason: 'the next scanner must not start before stop finishes');
      expect(lease.ownsLease, isTrue);

      gate.complete();
      await apply;

      expect(log, [
        'blindbit.start',
        'blindbit.stop-begin',
        'blindbit.stop-end',
        'frigate.start',
      ]);
      expect(constructed, [
        ChainBackendKind.blindbit,
        ChainBackendKind.frigate,
      ]);
      expect(lease.ownsLease, isTrue,
          reason: 'a backend swap keeps the writer lease');

      await host!.wake();
      expect(log.where((entry) => entry.endsWith('.wake')), ['frigate.wake'],
          reason: 'a wake goes to the occupant only');
    });
  });

  group('app isolate host', () {
    test('a live service lease keeps the app host from starting a scanner',
        () async {
      final built = <ChainBackendKind>[];
      final service = SyncService(
        chainState: ChainState(),
        frigateState: FrigateState(),
        syncProgress: SyncProgressState.create(),
        walletState: WalletState.create(),
        debugIsAndroid: true,
        debugServiceClaimProbe: () async => true,
        debugBuildScanner: (kind, _) {
          built.add(kind);
          return _FakeScanner(kind, []);
        },
      );

      await service.startInProcess();

      expect(built, isEmpty);
      expect(service.debugIsAndroid, isTrue);
    });
  });

  group('lease handoff (review blocker B1: one-shot service acquisition)', () {
    late Database db;
    late Directory tmpDir;

    setUp(() async {
      await SharedPreferencesAsync().clear();
      await SharedPreferencesAsync().setString(_keyNetwork, 'regtest');

      tmpDir = await Directory.systemTemp.createTemp('sync-handoff-');
      db = await databaseFactoryFfi.openDatabase('${tmpDir.path}/test.db');
      await db.execute('PRAGMA foreign_keys = ON');
      await applyMigrations(db);
      WriterLeaseRepository.testDatabaseOverride = () async => db;
    });

    tearDown(() async {
      WriterLeaseRepository.testDatabaseOverride = null;
      await db.close();
      await tmpDir.delete(recursive: true);
    });

    Future<void> waitFor(bool Function() cond,
        {String reason = 'condition'}) async {
      final end = DateTime.now().add(const Duration(seconds: 10));
      while (!cond()) {
        if (DateTime.now().isAfter(end)) fail('$reason within 10 s');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test(
        'service host retries while the app host holds the lease and takes '
        'over once the app host observes the service claim (stand-down)',
        () async {
      final appLog = <String>[];
      final serviceLog = <String>[];
      var blockedAttempts = 0;

      // App host becomes the writer first (service down at app start).
      final appHost = SyncHost(
        lease: WriterLease(writerId: WriterLease.appWriterId),
        buildScanner: (kind, _) => _FakeScanner(kind, appLog),
        standDownProbe: () => ServiceLiveness.isFresh(),
        standDownInterval: const Duration(milliseconds: 10),
      );
      expect(await appHost.start(), isTrue);
      expect(appLog, ['blindbit.start']);

      // The service isolate starts while the app host is live: the one-shot
      // acquisition fails, so it retries with backoff and advertises itself
      // (liveness marker) on every blocked attempt.
      final serviceHost = SyncHost(
        lease: WriterLease(writerId: WriterLease.serviceWriterId),
        buildScanner: (kind, _) => _FakeScanner(kind, serviceLog),
        acquirePolicy: const LeaseAcquirePolicy(
          initialDelay: Duration(milliseconds: 10),
          maxDelay: Duration(milliseconds: 10),
        ),
        onAcquireBlocked: (attempt) async {
          blockedAttempts = attempt;
          await ServiceLiveness.mark();
        },
      );

      final serviceStart = serviceHost.start();
      await waitFor(() => serviceHost.isRunning,
          reason: 'the service host never took over the writer lease');
      await serviceStart;

      // The handoff happened: the app host stood down...
      expect(appHost.isRunning, isFalse);
      expect(appHost.stoodDown, isTrue);
      expect(appLog, [
        'blindbit.start',
        'blindbit.stop-begin',
        'blindbit.stop-end',
      ]);
      // ...released the lease, and the service owns it with a live scanner.
      final row = await WriterLeaseRepository.instance.read();
      expect(row, isNotNull);
      expect(row!.writerId, WriterLease.serviceWriterId);
      expect(serviceLog, ['blindbit.start']);
      expect(blockedAttempts, greaterThanOrEqualTo(1),
          reason: 'the service must have been blocked before the handoff');

      await appHost.stop();
      await serviceHost.stop();
    });

    test('a bounded retry policy gives up after maxAttempts with no scanner',
        () async {
      final serviceLog = <String>[];
      final attempts = <int>[];

      // A fresh foreign (app) lease blocks every attempt.
      await WriterLeaseRepository.instance.write(
          WriterLease.appWriterId, DateTime.now().millisecondsSinceEpoch);

      final serviceHost = SyncHost(
        lease: WriterLease(writerId: WriterLease.serviceWriterId),
        buildScanner: (kind, _) => _FakeScanner(kind, serviceLog),
        acquirePolicy: const LeaseAcquirePolicy(
          maxAttempts: 3,
          initialDelay: Duration(milliseconds: 5),
          maxDelay: Duration(milliseconds: 5),
        ),
        onAcquireBlocked: (attempt) async => attempts.add(attempt),
      );

      expect(await serviceHost.start(), isFalse);
      expect(attempts, [1, 2, 3]);
      expect(serviceLog, isEmpty,
          reason: 'a blocked service host must not start a scanner');
      expect(serviceHost.isRunning, isFalse);
    });

    test('app host stands down when the service claims (B2.3 sole writer)',
        () async {
      final built = <ChainBackendKind>[];
      final service = SyncService(
        chainState: ChainState(),
        frigateState: FrigateState(),
        syncProgress: SyncProgressState.create(),
        walletState: WalletState.create(),
        debugIsAndroid: true,
        // Service down at app start: the claim probe times out, the app
        // isolate becomes the writer.
        debugServiceClaimProbe: () async => false,
        debugBuildScanner: (kind, _) {
          built.add(kind);
          return _FakeScanner(kind, []);
        },
        debugStandDownProbe: () => ServiceLiveness.isFresh(),
      );

      await service.startInProcess();
      expect(service.debugAppHostRunning, isTrue);
      expect(built, [ChainBackendKind.blindbit]);

      // The service isolate comes alive and waits for the lease.
      await ServiceLiveness.mark();

      await waitFor(() => !service.debugAppHostRunning,
          reason: 'the app host did not stand down to the service claim');
      final row = await WriterLeaseRepository.instance.read();
      expect(row, isNull,
          reason: 'the stand-down must release the lease for the service');
    });
  });

  group('Blindbit writer lease', () {
    late Database db;
    late Directory tmpDir;
    var now = 1700000000000;

    setUp(() async {
      await SharedPreferencesAsync().clear();
      await SharedPreferencesAsync().setString(_keyNetwork, 'regtest');
      FlutterSecureStorage.setMockInitialValues(const {
        _keyScanSk: 'encoded-scan-key',
        _keySpendKey: 'encoded-spend-key',
      });

      tmpDir = await Directory.systemTemp.createTemp('sync-lease-');
      db = await databaseFactoryFfi.openDatabase('${tmpDir.path}/test.db');
      await db.execute('PRAGMA foreign_keys = ON');
      await applyMigrations(db);
      WriterLeaseRepository.testDatabaseOverride = () async => db;
      now = 1700000000000;
      await WriterLeaseRepository.instance
          .write(WriterLease.serviceWriterId, now);
    });

    tearDown(() async {
      WriterLeaseRepository.testDatabaseOverride = null;
      await db.close();
      await tmpDir.delete(recursive: true);
    });

    test('a Blindbit write throws when a foreign lease is fresh', () async {
      final engine = SyncEngine(
        writerLease: WriterLease(
          writerId: WriterLease.appWriterId,
          nowMillis: () => now,
        ),
        onSyncStarted: (_, __) {},
        onSyncComplete: (_) {},
        onStateUpdated: (_) async {},
      );

      await expectLater(
        engine.trySync(),
        throwsA(isA<WriterLeaseLostException>()),
      );
      expect(await WalletRepository.instance.readLastSync(), isNull,
          reason: 'the refused write must not advance lastscan');
      engine.dispose();
    });
  });
}
