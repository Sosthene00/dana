// M-a (review card t_a38b7193): a timed-out Blindbit drain is a FAILED
// swap, not a proceed. SyncEngine.waitForIdle used to swallow its timeout,
// so SyncHost.applyBackend disposed the occupant and started the other
// scanner while the in-flight scan was still writing (saveLastSync /
// owned_outputs) — the two-writer hole the one-host design exists to
// prevent.
//
// Empty-slot policy (documented here and in sync_host.dart): on a timed-out
// drain the swap FAILS — the other scanner is never constructed/started,
// the slot stays EMPTY, the host keeps the writer lease and the isolate
// stays read-only; a typed failure is surfaced to the caller.
import 'dart:async';
import 'dart:io';

import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/repositories/writer_lease_repository.dart';
import 'package:danawallet/services/sync_host.dart';
import 'package:danawallet/services/writer_lease.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'frigate_event_handler_test.dart' show applyMigrations;

const _keyNetwork = 'network';

/// A scanner whose drain ignores the interrupt and outlasts the host's
/// bounded drain timeout — the M-a condition: Rust has not honoured
/// interruptSync, the in-flight scan may still be writing.
class _SlowDrainScanner implements SyncScanner {
  _SlowDrainScanner(this.kind, this.log, {required this.drainDelay});

  @override
  final ChainBackendKind kind;
  final List<String> log;
  final Duration drainDelay;

  @override
  Future<void> start() async {
    log.add('${kind.name}.start');
  }

  @override
  Future<void> stop({bool drain = true}) async {
    log.add('${kind.name}.stop-begin');
    await Future<void>.delayed(drainDelay);
    log.add('${kind.name}.stop-end');
  }

  @override
  Future<void> wake() async {
    log.add('${kind.name}.wake');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late Directory tmpDir;
  late WriterLease lease;
  final log = <String>[];
  final constructed = <ChainBackendKind>[];
  SyncHost? host;

  setUp(() async {
    log.clear();
    constructed.clear();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(const {
      _keyNetwork: 'regtest',
    });
    await SharedPreferencesAsync().clear();
    await SharedPreferencesAsync().setString(_keyNetwork, 'regtest');
    await SettingsRepository.instance
        .setChainBackend(ChainBackendKind.blindbit);

    tmpDir = await Directory.systemTemp.createTemp('sync-host-apply-');
    db = await databaseFactoryFfi.openDatabase('${tmpDir.path}/test.db');
    await db.execute('PRAGMA foreign_keys = ON');
    await applyMigrations(db);
    WriterLeaseRepository.testDatabaseOverride = () async => db;

    lease = WriterLease(writerId: WriterLease.appWriterId);
    host = SyncHost(
      lease: lease,
      buildScanner: (kind, _) {
        // 12 s drain: outlasts the host's bounded drain timeout.
        final scanner = _SlowDrainScanner(kind, log,
            drainDelay: const Duration(seconds: 12));
        constructed.add(kind);
        return scanner;
      },
    );
  });

  tearDown(() async {
    WriterLeaseRepository.testDatabaseOverride = null;
    await db.close();
    await tmpDir.delete(recursive: true);
  });

  test(
      'applyBackend: a drain outlasting the bounded timeout is a FAILED '
      'swap — empty-slot policy: the other scanner is never started, the '
      'slot stays empty and the lease is held', () async {
    await host!.start();
    expect(constructed, [ChainBackendKind.blindbit]);
    expect(lease.ownsLease, isTrue);

    await SettingsRepository.instance.setChainBackend(ChainBackendKind.frigate);

    // The failed swap must surface a typed failure, not be swallowed.
    await expectLater(
      host!.applyBackend(),
      throwsA(isA<TimeoutException>()),
      reason: 'a timed-out drain is a failed swap — applyBackend must '
          'report the failure (M-a), not proceed',
    );

    expect(constructed, [ChainBackendKind.blindbit],
        reason: 'the other scanner must never be constructed on a '
            'timed-out drain (two-writer hole, M-a)');
    expect(log.contains('frigate.start'), isFalse,
        reason: 'no second writer may start over an undrained scan');
    expect(log, ['blindbit.start', 'blindbit.stop-begin'],
        reason: 'the occupant stop began but the other scanner never ran');
    expect(host!.scanner, isNull,
        reason: 'empty-slot policy: the slot stays empty after a failed '
            'swap');
    expect(host!.isRunning, isTrue,
        reason: 'the host stays up holding the lease');
    expect(lease.ownsLease, isTrue,
        reason: 'a failed swap must not release the lease (M-a/d)');
  });
}
