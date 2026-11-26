// POC (card t_ded648da) — scenario "service-restarts-while-app-host-live",
// the empirical red-at-29d979b / green-at-44427a6 proof of review blocker B1.
//
// Before 44427a6 the service-isolate SyncHost acquired the writer lease
// one-shot at startup: started while the app isolate's in-process host held
// a FRESH appWriterId lease, it stayed scannerless for its whole lifetime
// (no retry), the app host never stood down, and background sync died once
// the app was killed. The fix adds LeaseAcquirePolicy (the service host
// retries with backoff) and the app-host standDownProbe (a fresh service
// claim stops the app scanner and releases the lease).
//
// Desired behavior asserted here:
//   (a) the service host EVENTUALLY acquires the lease and starts its
//       committed scanner (bounded retry wait, injected fast backoff —
//       no real 5-15 s sleeps);
//   (b) the app host stands down — its scanner stops and its lease is
//       released (renewals cease; the row names the service writer);
//   (c) there is NO window with two live writers — the service scanner
//       starts only after the app scanner has fully stopped.
import 'dart:io';

import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/repositories/writer_lease_repository.dart';
import 'package:danawallet/services/service_liveness.dart';
import 'package:danawallet/services/sync_host.dart';
import 'package:danawallet/services/writer_lease.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'frigate_event_handler_test.dart' show applyMigrations;

const _keyNetwork = 'network';

/// Scanner that records into a per-host log and a shared ordered timeline
/// (used for the no-two-live-writers ordering assertion).
class _RecordingScanner implements SyncScanner {
  _RecordingScanner(this.kind, this.log, this.timeline, this.label);

  @override
  final ChainBackendKind kind;
  final List<String> log;
  final List<String> timeline;
  final String label;

  @override
  Future<void> start() async {
    log.add('${kind.name}.start');
    timeline.add('$label.start');
  }

  @override
  Future<void> stop({bool drain = true}) async {
    log.add('${kind.name}.stop-begin');
    timeline.add('$label.stop-begin');
    log.add('${kind.name}.stop-end');
    timeline.add('$label.stop-end');
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
    sqfliteFfiInit();
  });

  setUp(() {
    SharedPreferencesAsyncPlatform.instance = sharedPrefs;
  });

  group('service-restarts-while-app-host-live (B1 POC)', () {
    late Database db;
    late Directory tmpDir;

    setUp(() async {
      await SharedPreferencesAsync().clear();
      await SharedPreferencesAsync().setString(_keyNetwork, 'regtest');
      await ServiceLiveness.clear();
      await SettingsRepository.instance
          .setChainBackend(ChainBackendKind.blindbit);

      tmpDir = await Directory.systemTemp.createTemp('sync-takeover-');
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
        'the service host starting under a live app host eventually takes '
        'over; the app host stands down and never overlaps the service', () async {
      final appLog = <String>[];
      final serviceLog = <String>[];
      final timeline = <String>[];
      var blockedAttempts = 0;

      // 1. The app isolate's in-process host is live FIRST and holds a
      //    fresh appWriterId lease with a running scanner.
      final appHost = SyncHost(
        lease: WriterLease(writerId: WriterLease.appWriterId),
        buildScanner: (kind, _) =>
            _RecordingScanner(kind, appLog, timeline, 'app'),
        standDownProbe: () => ServiceLiveness.isFresh(),
        standDownInterval: const Duration(milliseconds: 10),
      );
      expect(await appHost.start(), isTrue);
      expect(appLog, ['blindbit.start']);
      final held = await WriterLeaseRepository.instance.read();
      expect(held, isNotNull);
      expect(held!.writerId, WriterLease.appWriterId,
          reason: 'the app host must hold the writer lease before the '
              'service restarts');

      // 2. The service-isolate host starts WHILE the app host is live: the
      //    first acquisition is blocked, so it retries with backoff and
      //    advertises its liveness on every blocked attempt.
      final serviceHost = SyncHost(
        lease: WriterLease(writerId: WriterLease.serviceWriterId),
        buildScanner: (kind, _) =>
            _RecordingScanner(kind, serviceLog, timeline, 'service'),
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
      await waitFor(
        () => serviceHost.isRunning,
        reason: 'the service host never acquired the writer lease and never '
            'started its scanner (B1: scannerless service forever)',
      );
      await serviceStart;

      // (a) the service took over and started its committed scanner.
      expect(serviceLog, ['blindbit.start']);
      expect(blockedAttempts, greaterThanOrEqualTo(1),
          reason: 'the service must have been blocked by the live app host '
              'before the handoff');

      // (b) the app host stood down: scanner stopped, lease released.
      expect(appHost.isRunning, isFalse);
      expect(appHost.stoodDown, isTrue,
          reason: 'the app host must step down to the fresh service claim');
      expect(appLog, [
        'blindbit.start',
        'blindbit.stop-begin',
        'blindbit.stop-end',
      ]);
      final row = await WriterLeaseRepository.instance.read();
      expect(row, isNotNull);
      expect(row!.writerId, WriterLease.serviceWriterId,
          reason: 'the app lease is released; renewals cease and the '
              'service owns the slot');

      // (c) no window with two live writers: the service scanner starts
      //     only after the app scanner has fully stopped.
      final appStopEnd = timeline.indexOf('app.stop-end');
      final serviceStartIdx = timeline.indexOf('service.start');
      expect(appStopEnd, greaterThanOrEqualTo(0));
      expect(serviceStartIdx, greaterThan(appStopEnd),
          reason: 'two live writers must never overlap (B2.3)');

      await appHost.stop();
      await serviceHost.stop();
    });
  });
}
