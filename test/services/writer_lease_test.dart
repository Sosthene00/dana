import 'dart:io';

import 'package:danawallet/repositories/frigate_candidates_repository.dart';
import 'package:danawallet/repositories/writer_lease_repository.dart';
import 'package:danawallet/services/frigate_event_handler.dart';
import 'package:danawallet/services/writer_lease.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'frigate_event_handler_test.dart'
    show applyMigrations, ownedOutput, unconfirmedEvent;

const _serviceId = WriterLease.serviceWriterId;
const _appId = WriterLease.appWriterId;

Future<Database> openTestDb() async {
  // A unique temp FILE per test, not ':memory:': the ffi factory keys
  // single-instance ':memory:' databases per isolate, so the second group's
  // applyMigrations would collide with the first group's tables.
  final tmp = await Directory.systemTemp.createTemp('r6-lease-');
  tempDirs.add(tmp);
  final db = await databaseFactoryFfi.openDatabase('${tmp.path}/test.db');
  await db.execute('PRAGMA foreign_keys = ON');
  await applyMigrations(db);
  return db;
}

final List<Directory> tempDirs = [];

Future<void> cleanupTempDirs() async {
  for (final dir in tempDirs) {
    await dir.delete(recursive: true).catchError((_) => dir);
  }
  tempDirs.clear();
}

void main() {
  tearDownAll(cleanupTempDirs);

  group('WriterLease (B2.8 single-writer handoff probe)', () {
    late Database db;
    // deterministic clock, advanced explicitly by the tests
    int clockMs = 1700000000000;

    setUp(() async {
      db = await openTestDb();
      WriterLeaseRepository.testDatabaseOverride = () async => db;
      clockMs = 1700000000000;
    });

    tearDown(() async {
      WriterLeaseRepository.testDatabaseOverride = null;
      await db.close();
    });

    WriterLease lease({String writerId = _appId}) => WriterLease(
          writerId: writerId,
          nowMillis: () => clockMs,
        );

    Future<void> seedLease(String writerId, int ageMs) async {
      await WriterLeaseRepository.instance.write(writerId, clockMs - ageMs);
    }

    test('acquiring on an empty store succeeds and writes the lease row',
        () async {
      final lease1 = lease();
      expect(await lease1.tryAcquire(), isTrue);
      expect(lease1.ownsLease, isTrue);

      final row = await WriterLeaseRepository.instance.read();
      expect(row, isNotNull);
      expect(row!.writerId, _appId);
      expect(row.heartbeatMs, clockMs);
    });

    test('a live foreign writer holds the lease — the caller stays read-only',
        () async {
      await seedLease(_serviceId, 1000); // fresh heartbeat 1 s ago
      final lease1 = lease();

      expect(await lease1.tryAcquire(), isFalse,
          reason: 'B2.3: the app takes over only after the service is down');
      expect(lease1.ownsLease, isFalse);

      final row = await WriterLeaseRepository.instance.read();
      expect(row!.writerId, _serviceId,
          reason: 'the foreign lease must not be overwritten');
    });

    test('stale foreign lease (>= 10 s, two missed heartbeats) is taken over',
        () async {
      await seedLease(_serviceId, WriterLease.staleAfter.inMilliseconds);
      final lease1 = lease();

      expect(await lease1.tryAcquire(), isTrue,
          reason: 'the staleness observation IS the confirmation that the '
              'service is down (B2.8)');
      final row = await WriterLeaseRepository.instance.read();
      expect(row!.writerId, _appId);
    });

    test('staleness boundary: 9.9 s is fresh, 10 s is stale', () async {
      await seedLease(_serviceId, WriterLease.staleAfter.inMilliseconds - 1);
      expect(await lease().tryAcquire(), isFalse);

      await seedLease(_serviceId, WriterLease.staleAfter.inMilliseconds);
      expect(await lease().tryAcquire(), isTrue);
    });

    test('re-acquiring our own lease is a no-op success', () async {
      final lease1 = lease();
      expect(await lease1.tryAcquire(), isTrue);
      clockMs += 100;
      expect(await lease1.tryAcquire(), isTrue);
      final row = await WriterLeaseRepository.instance.read();
      expect(row!.writerId, _appId);
      expect(row.heartbeatMs, clockMs);
    });

    test('renew refreshes our own heartbeat only', () async {
      final ours = lease();
      await ours.tryAcquire();
      clockMs += 5000;
      expect(await ours.renew(), isTrue);
      final row = await WriterLeaseRepository.instance.read();
      expect(row!.writerId, _appId);
      expect(row.heartbeatMs, clockMs);
    });

    test('a foreign holder cannot renew a lease it does not own', () async {
      await seedLease(_serviceId, 1000);
      final intruder = lease();
      expect(await intruder.renew(), isFalse);
      expect(intruder.ownsLease, isFalse);
      final row = await WriterLeaseRepository.instance.read();
      expect(row!.writerId, _serviceId);
    });

    test(
        'ensureOwnership throws WriterLeaseLostException on a fresh foreign lease',
        () async {
      await seedLease(_serviceId, 1000);
      final stranger = lease();
      await expectLater(
        stranger.ensureOwnership(),
        throwsA(isA<WriterLeaseLostException>()
            .having((e) => e.holder, 'holder', _serviceId)),
      );
    });

    test('ensureOwnership renews while we hold the lease', () async {
      final ours = lease();
      await ours.tryAcquire();
      clockMs += 5000;
      await ours.ensureOwnership();
      final row = await WriterLeaseRepository.instance.read();
      expect(row!.heartbeatMs, clockMs);
    });

    test('release clears our lease so the next writer acquires immediately',
        () async {
      final ours = lease();
      await ours.tryAcquire();
      await ours.release();
      expect(await WriterLeaseRepository.instance.read(), isNull);

      final next = lease(writerId: _serviceId);
      expect(await next.tryAcquire(), isTrue);
    });

    test('release does not clear a foreign lease', () async {
      await seedLease(_serviceId, 1000);
      final stranger = lease();
      // stranger never acquired; release must be a no-op
      await stranger.release();
      final row = await WriterLeaseRepository.instance.read();
      expect(row!.writerId, _serviceId);
    });
  });

  group('FrigateEventHandler writer-lease enforcement (B2.8 in the write path)',
      () {
    late Database db;
    int clockMs = 1700000000000;
    final repo = FrigateCandidatesRepository.instance;
    late WriterLease lease;

    setUp(() async {
      db = await openTestDb();
      FrigateCandidatesRepository.testDatabaseOverride = () async => db;
      WriterLeaseRepository.testDatabaseOverride = () async => db;
      clockMs = 1700000000000;
      lease = WriterLease(writerId: _serviceId, nowMillis: () => clockMs);
    });

    tearDown(() async {
      FrigateCandidatesRepository.testDatabaseOverride = null;
      WriterLeaseRepository.testDatabaseOverride = null;
      await db.close();
    });

    FrigateEventHandler handler() => FrigateEventHandler(
          candidatesRepository: repo,
          writerLease: lease,
        );

    test(
        'an Unconfirmed event is REFUSED while a foreign writer holds a fresh lease',
        () async {
      await WriterLeaseRepository.instance
          .write(_appId, clockMs - 1000); // app writer is live

      await expectLater(
        handler().handleEvent(unconfirmedEvent(outputs: [
          ownedOutput(txid: 'a' * 64, vout: 0, amountSat: 1500),
        ])),
        throwsA(isA<WriterLeaseLostException>()),
        reason: 'B2.3: concurrent writers are a spec violation — the write '
            'path must refuse, not merely discourage',
      );
      expect(await repo.getPendingCandidates(), isEmpty,
          reason: 'the refused event must not touch the registry');
    });

    test('an Unconfirmed event is written while WE hold the lease', () async {
      expect(await lease.tryAcquire(), isTrue);
      clockMs += 1000;

      await handler().handleEvent(unconfirmedEvent(outputs: [
        ownedOutput(txid: 'a' * 64, vout: 0, amountSat: 1500),
      ]));

      final pending = await repo.getPendingCandidates();
      expect(pending, hasLength(1));
      expect(pending.first.amountSat, 1500);
    });

    test('an Unconfirmed event is written after taking over a stale lease',
        () async {
      // the previous writer died 10+ s ago — tryAcquire takes the stale row
      // over (the staleness observation IS the confirmation it is down,
      // B2.8), and the write path then proceeds under OUR ownership.
      await WriterLeaseRepository.instance
          .write(_appId, clockMs - WriterLease.staleAfter.inMilliseconds);
      expect(await lease.tryAcquire(), isTrue);
      clockMs += 1000;

      await handler().handleEvent(unconfirmedEvent(outputs: [
        ownedOutput(txid: 'a' * 64, vout: 0, amountSat: 1500),
      ]));

      expect(await repo.getPendingCandidates(), hasLength(1));
    });
  });

  group('waitForServiceWriterClaim (app-side takeover probe, B2.3)', () {
    late Database db;
    int clockMs = 1700000000000;

    setUp(() async {
      db = await openTestDb();
      WriterLeaseRepository.testDatabaseOverride = () async => db;
      clockMs = 1700000000000;
    });

    tearDown(() async {
      WriterLeaseRepository.testDatabaseOverride = null;
      await db.close();
    });

    test('returns true as soon as the service writer holds a fresh lease',
        () async {
      await WriterLeaseRepository.instance.write(_serviceId, clockMs);
      expect(
        await waitForServiceWriterClaim(
          timeout: const Duration(seconds: 30),
          pollPeriod: const Duration(milliseconds: 1),
          nowMillis: () => clockMs,
        ),
        isTrue,
      );
    });

    test('returns false when no service claim appears within the timeout',
        () async {
      // the fake clock advances 100 ms per poll; timeout 2 s -> ~20 polls
      expect(
        await waitForServiceWriterClaim(
          timeout: const Duration(milliseconds: 2000),
          pollPeriod: const Duration(milliseconds: 1),
          nowMillis: () => clockMs += 100,
        ),
        isFalse,
      );
    });

    test('a stale service lease does not count as a live claim', () async {
      await WriterLeaseRepository.instance.write(
        _serviceId,
        clockMs - WriterLease.staleAfter.inMilliseconds,
      );
      expect(
        await waitForServiceWriterClaim(
          timeout: const Duration(milliseconds: 2000),
          pollPeriod: const Duration(milliseconds: 1),
          nowMillis: () => clockMs += 100,
        ),
        isFalse,
        reason: 'stale = service down; the app may take over (B2.8)',
      );
    });

    test('a fresh APP lease does not count as a service claim', () async {
      await WriterLeaseRepository.instance.write(_appId, clockMs);
      expect(
        await waitForServiceWriterClaim(
          timeout: const Duration(milliseconds: 2000),
          pollPeriod: const Duration(milliseconds: 1),
          nowMillis: () => clockMs += 100,
        ),
        isFalse,
      );
    });
  });
}
