import 'dart:io';
import 'dart:typed_data';

import 'package:danawallet/repositories/frigate_candidates_repository.dart';
import 'package:danawallet/repositories/owned_outputs_repository.dart';
import 'package:danawallet/repositories/transactions_repository.dart';
import 'package:danawallet/services/electrum_client.dart';
import 'package:danawallet/services/frigate_confirmation_monitor.dart';
import 'package:danawallet/repositories/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'mock_electrum_server.dart';

/// Applies the real migration assets from the repo, mirroring how
/// DatabaseHelper._performMigrations executes them.
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

const _txid =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

FrigateCandidate candidate({
  String txid = _txid,
  int vout = 0,
  int amountSat = 1500,
  List<int>? script,
  int firstSeen = 1000,
}) {
  return FrigateCandidate(
    txid: txid,
    vout: vout,
    tweak: Uint8List.fromList(List.filled(32, 7)),
    script: Uint8List.fromList(script ?? [0x51, 0x20, 0xaa]),
    amountSat: amountSat,
    firstSeen: firstSeen,
    source: 'frigate-mempool',
  );
}

/// Poll until [probe] returns true; fails with [description] on timeout.
Future<void> waitUntil(String description, Future<bool> Function() probe,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await probe()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('timed out waiting for: $description');
}

void main() {
  sqfliteFfiInit();
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // ONE platform instance for the whole file: the SettingsRepository
    // singleton captures it at first construction (same pattern as the
    // frigate disclosure tests).
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('classifyHistory (B3.3/B3.5/O2 decision)', () {
    test('txid in a confirmed entry graduates', () {
      expect(
        classifyHistory(
            const [ElectrumHistoryEntry(height: 800, txHash: _txid)], _txid),
        CandidateObservation.confirmed,
      );
    });

    test('txid in a mempool entry (height <= 0) stays pending', () {
      expect(
        classifyHistory(
            const [ElectrumHistoryEntry(height: 0, txHash: _txid)], _txid),
        CandidateObservation.pending,
      );
      expect(
        classifyHistory(
            const [ElectrumHistoryEntry(height: -1, txHash: _txid)], _txid),
        CandidateObservation.pending,
      );
    });

    test('txid in neither confirmed nor mempool entries is evicted', () {
      expect(
        classifyHistory(
            [ElectrumHistoryEntry(height: 800, txHash: 'ff' * 32)], _txid),
        CandidateObservation.evicted,
      );
      expect(classifyHistory(const [], _txid), CandidateObservation.evicted);
    });
  });

  group('FrigateConfirmationMonitor', () {
    late Database db;
    late MockElectrumServer server;
    late int port;

    setUp(() async {
      await SharedPreferencesAsync().clear();
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await applyMigrations(db);
      // Mirror production: DatabaseHelper opens the real DB with
      // `PRAGMA foreign_keys = ON` — the device failure this file guards
      // is exactly FK 787 on owned_outputs. Without the pragma the test
      // DB silently accepts parentless output rows and the regression is
      // invisible.
      await db.execute('PRAGMA foreign_keys = ON');
      FrigateCandidatesRepository.testDatabaseOverride = () async => db;
      OwnedOutputsRepository.testDatabaseOverride = () async => db;
      TransactionsRepository.testDatabaseOverride = () async => db;
      server = MockElectrumServer();
      port = await server.start();
      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return null;
          case 'blockchain.scripthash.get_history':
            return const [];
          default:
            throw Exception('unexpected method $method');
        }
      };
    });

    tearDown(() async {
      FrigateCandidatesRepository.testDatabaseOverride = null;
      OwnedOutputsRepository.testDatabaseOverride = null;
      TransactionsRepository.testDatabaseOverride = null;
      await server.stop();
      await db.close();
    });

    FrigateConfirmationMonitor makeMonitor({
      void Function()? onGraduated,
      int? maxSubscriptions,
      int Function()? nowMillis,
    }) {
      return FrigateConfirmationMonitor(
        clientFactory: (endpoint) async => ElectrumClient.connect(endpoint,
            timeout: const Duration(seconds: 5)),
        onGraduated: onGraduated,
        maxSubscriptions: maxSubscriptions ??
            FrigateConfirmationMonitor.maxSubscriptionsDefault,
        nowMillis: nowMillis,
        reconnectDelay: const Duration(milliseconds: 20),
      );
    }

    test('subscribes the scripthash of every pending candidate on start (B3.7)',
        () async {
      final c = candidate();
      await FrigateCandidatesRepository.instance.upsertCandidate(c);

      final monitor = makeMonitor();
      await monitor.start(endpoint: '127.0.0.1:$port');

      final expected = electrumScripthash(c.script);
      await waitUntil(
          'subscribe request for $expected',
          () async => server
              .paramsFor('blockchain.scripthash.subscribe')
              .contains(expected));
      await monitor.stop();
    });

    test(
        'no configured electrum endpoint falls back to the frigate URL '
        '(interim default until the R7 endpoint UI)', () async {
      // The frigate backend IS an electrum endpoint (the B5.1 probe
      // handshakes server.version against the same host:port), so with no
      // `frigateelectrumurl` the monitor must reuse the frigate URL.
      await SharedPreferencesAsync().setString('frigateurl', '127.0.0.1:$port');

      final c = candidate();
      await FrigateCandidatesRepository.instance.upsertCandidate(c);

      final monitor = makeMonitor();
      await monitor.start();

      final expected = electrumScripthash(c.script);
      await waitUntil(
          'subscribe request for $expected',
          () async => server
              .paramsFor('blockchain.scripthash.subscribe')
              .contains(expected));
      await monitor.stop();
    });

    test('an explicit frigateelectrumurl wins over the frigate URL fallback',
        () async {
      await SharedPreferencesAsync().setString('frigateurl', '127.0.0.1:1');
      await SharedPreferencesAsync()
          .setString('frigateelectrumurl', '127.0.0.1:$port');

      final c = candidate();
      await FrigateCandidatesRepository.instance.upsertCandidate(c);

      final monitor = makeMonitor();
      await monitor.start();

      final expected = electrumScripthash(c.script);
      await waitUntil(
          'subscribe request for $expected',
          () async => server
              .paramsFor('blockchain.scripthash.subscribe')
              .contains(expected));
      await monitor.stop();
    });

    test('never subscribes confirmed or dropped candidates', () async {
      final confirmed = candidate(vout: 1, script: [0x51, 0x20, 0x01]);
      await FrigateCandidatesRepository.instance.upsertCandidate(confirmed);
      await FrigateCandidatesRepository.instance
          .markConfirmed(confirmed.txid, confirmed.vout);
      final dropped = candidate(vout: 2, script: [0x51, 0x20, 0x02]);
      await FrigateCandidatesRepository.instance.upsertCandidate(dropped);
      await FrigateCandidatesRepository.instance
          .markDropped(dropped.txid, dropped.vout);

      final monitor = makeMonitor();
      await monitor.start(endpoint: '127.0.0.1:$port');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        server.requestMethods
            .where((m) => m == 'blockchain.scripthash.subscribe'),
        isEmpty,
      );
      await monitor.stop();
    });

    test(
        'confirmation notification graduates into owned_outputs exactly '
        'once (B3.3/B3.4)', () async {
      final c = candidate();
      await FrigateCandidatesRepository.instance.upsertCandidate(c);
      final sh = electrumScripthash(c.script);

      // The candidate exists because its tx is IN THE MEMPOOL: history is
      // the mempool entry until it is mined.
      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return 'mempool-status';
          case 'blockchain.scripthash.get_history':
            return [
              {'height': 0, 'tx_hash': c.txid},
            ];
          default:
            throw Exception('unexpected method $method');
        }
      };

      var graduations = 0;
      final monitor = makeMonitor(onGraduated: () => graduations++);
      await monitor.start(endpoint: '127.0.0.1:$port');
      await waitUntil(
          'initial subscribe',
          () async => server.requestMethods
              .contains('blockchain.scripthash.subscribe'));

      // Mine: the tx now appears in confirmed history; electrs notifies.
      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return 'status-after-confirm';
          case 'blockchain.scripthash.get_history':
            return [
              {'height': 869, 'tx_hash': c.txid},
            ];
          default:
            throw Exception('unexpected method $method');
        }
      };
      server.pushNotification(
          'blockchain.scripthash.subscribe', [sh, 'status-after-confirm']);

      // Candidate is confirmed in the registry…
      await waitUntil(
          'candidate confirmed',
          () async =>
              (await FrigateCandidatesRepository.instance
                      .getCandidate(c.txid, c.vout))
                  ?.status ==
              FrigateCandidateStatus.confirmed);
      // …and the output exists in owned_outputs.
      final owned = await db.query('owned_outputs',
          where: 'txid = ? AND vout = ?', whereArgs: [c.txid, c.vout]);
      expect(owned, hasLength(1));
      expect(owned.first['amount_sat'], c.amountSat);
      expect(graduations, 1);

      // Dedupe: a re-delivered notification (history replay / scanner
      // re-report) must not create state a second time (B3.3/B3.4).
      server.pushNotification(
          'blockchain.scripthash.subscribe', [sh, 'status-after-confirm']);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final ownedAgain = await db.query('owned_outputs',
          where: 'txid = ? AND vout = ?', whereArgs: [c.txid, c.vout]);
      expect(ownedAgain, hasLength(1));
      expect(graduations, 1);
      await monitor.stop();
    });

    test(
        'graduation writes the transactions parent row before owned_outputs '
        '(FK 787 regression: change sats must not vanish)', () async {
      // owned_outputs REFERENCES transactions(txid) and the real DB runs
      // with `PRAGMA foreign_keys = ON`: an output inserted without its
      // parent row fails with FK 787, the failure was swallowed, and the
      // candidate was confirmed anyway — the sats became permanently
      // invisible to the balance. Graduation must mirror the sibling
      // confirmed path (_recordConfirmedReceipts): parent row first.
      final c = candidate();
      await FrigateCandidatesRepository.instance.upsertCandidate(c);
      final sh = electrumScripthash(c.script);

      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return 'mempool-status';
          case 'blockchain.scripthash.get_history':
            return [
              {'height': 0, 'tx_hash': c.txid},
            ];
          default:
            throw Exception('unexpected method $method');
        }
      };

      final monitor = makeMonitor();
      await monitor.start(endpoint: '127.0.0.1:$port');
      await waitUntil(
          'initial subscribe',
          () async => server.requestMethods
              .contains('blockchain.scripthash.subscribe'));

      // Mine: the tx is now confirmed at height 869.
      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return 'status-after-confirm';
          case 'blockchain.scripthash.get_history':
            return [
              {'height': 869, 'tx_hash': c.txid},
            ];
          default:
            throw Exception('unexpected method $method');
        }
      };
      server.pushNotification(
          'blockchain.scripthash.subscribe', [sh, 'status-after-confirm']);

      await waitUntil(
          'candidate confirmed',
          () async => (await FrigateCandidatesRepository.instance
                  .getCandidate(c.txid, c.vout))
              ?.status ==
          FrigateCandidateStatus.confirmed);

      // The FK parent row exists, with the height the electrum history
      // carried (blockhash is unknown on the electrum leg — nullable).
      final parent = await db.query('transactions',
          where: 'txid = ?', whereArgs: [c.txid]);
      expect(parent, hasLength(1),
          reason: 'graduation must create the transactions parent row');
      expect(parent.first['confirmation_height'], 869);
      expect(parent.first['confirmation_blockhash'], isNull);

      // The output itself is present — the sats are in the balance.
      final owned = await db.query('owned_outputs',
          where: 'txid = ? AND vout = ?', whereArgs: [c.txid, c.vout]);
      expect(owned, hasLength(1));
      expect(owned.first['amount_sat'], c.amountSat);
      await monitor.stop();
    });

    test(
        'a failed owned_outputs insert does NOT confirm the candidate '
        '(swallow-and-confirm regression)', () async {
      // insertOutput used to swallow every failure; graduation then marked
      // the candidate confirmed regardless — a hard state-write failure
      // became a silent graduation. With the insert failing and the
      // outpoint ABSENT, the candidate must stay pending (retry on the
      // next reconcile), never confirmed.
      final c = candidate(script: [0x51, 0x20, 0xb1]);
      await FrigateCandidatesRepository.instance.upsertCandidate(c);
      final sh = electrumScripthash(c.script);

      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return 'mempool-status';
          case 'blockchain.scripthash.get_history':
            return [
              {'height': 0, 'tx_hash': c.txid},
            ];
          default:
            throw Exception('unexpected method $method');
        }
      };

      final monitor = makeMonitor();
      await monitor.start(endpoint: '127.0.0.1:$port');
      await waitUntil(
          'initial subscribe',
          () async => server.requestMethods
              .contains('blockchain.scripthash.subscribe'));

      // Force the owned_outputs insert to fail at the DB layer for THIS
      // txid only (RAISE(ABORT) — a genuine state-write failure, not a
      // B3.4 dedupe): the parent row is written, then the insert aborts.
      // The trigger is in place BEFORE the tx is mined so no graduation
      // attempt can slip past it.
      await db.execute('''
        CREATE TRIGGER fail_owned_output_insert
        BEFORE INSERT ON owned_outputs
        WHEN NEW.txid = '${c.txid}'
        BEGIN
          SELECT RAISE(ABORT, 'forced test failure');
        END;
      ''');

      // Mine: the tx is now confirmed; the graduation insert will abort.
      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return 'status-after-confirm';
          case 'blockchain.scripthash.get_history':
            return [
              {'height': 869, 'tx_hash': c.txid},
            ];
          default:
            throw Exception('unexpected method $method');
        }
      };
      server.pushNotification(
          'blockchain.scripthash.subscribe', [sh, 'status-after-confirm']);

      // Give the graduation attempt time to run and fail.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final row = await FrigateCandidatesRepository.instance
          .getCandidate(c.txid, c.vout);
      expect(row?.status, FrigateCandidateStatus.pending,
          reason: 'a failed state write must not confirm the candidate');
      final owned = await db.query('owned_outputs',
          where: 'txid = ? AND vout = ?', whereArgs: [c.txid, c.vout]);
      expect(owned, isEmpty);
      expect(await FrigateCandidatesRepository.instance.getPendingBalance(),
          c.amountSat);
      await monitor.stop();
    });

    test(
        'a re-delivered graduation dedupes on the outpoint and still '
        'confirms (B3.4)', () async {
      // The scanner's Confirmed leg may have written the output first: the
      // INSERT OR FAIL then fails on the duplicate outpoint — a dedupe,
      // not a failure. The candidate must still be marked confirmed.
      final c = candidate(script: [0x51, 0x20, 0xb2]);
      await FrigateCandidatesRepository.instance.upsertCandidate(c);
      // The scanner's Confirmed leg writes the parent row first
      // (_recordConfirmedReceipts order) — mirror it exactly.
      await db
          .insert('transactions', {'txid': c.txid, 'confirmation_height': 869});
      await db.insert('owned_outputs', {
        'txid': c.txid,
        'vout': c.vout,
        'tweak': Uint8List.fromList(List.filled(32, 7)),
        'amount_sat': c.amountSat,
        'script': Uint8List.fromList(c.script),
      });

      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return 'status-after-confirm';
          case 'blockchain.scripthash.get_history':
            return [
              {'height': 869, 'tx_hash': c.txid},
            ];
          default:
            throw Exception('unexpected method $method');
        }
      };

      final monitor = makeMonitor();
      await monitor.start(endpoint: '127.0.0.1:$port');
      await waitUntil(
          'candidate confirmed',
          () async => (await FrigateCandidatesRepository.instance
                  .getCandidate(c.txid, c.vout))
              ?.status ==
          FrigateCandidateStatus.confirmed);

      // Exactly one row — the dedupe created no second state.
      final owned = await db.query('owned_outputs',
          where: 'txid = ? AND vout = ?', whereArgs: [c.txid, c.vout]);
      expect(owned, hasLength(1));
      await monitor.stop();
    });

    test('mempool-only history keeps the candidate pending', () async {
      final c = candidate(script: [0x51, 0x20, 0x33]);
      await FrigateCandidatesRepository.instance.upsertCandidate(c);
      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return 'mempool-status';
          case 'blockchain.scripthash.get_history':
            return [
              {'height': 0, 'tx_hash': c.txid},
            ];
          default:
            throw Exception('unexpected method $method');
        }
      };

      final monitor = makeMonitor();
      await monitor.start(endpoint: '127.0.0.1:$port');
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final row = await FrigateCandidatesRepository.instance
          .getCandidate(c.txid, c.vout);
      expect(row?.status, FrigateCandidateStatus.pending);
      expect(await FrigateCandidatesRepository.instance.getPendingBalance(),
          c.amountSat);
      final owned = await db.query('owned_outputs',
          where: 'txid = ? AND vout = ?', whereArgs: [c.txid, c.vout]);
      expect(owned, isEmpty);
      await monitor.stop();
    });

    test('evicted txid drops the candidate, no state is created (B3.5/O2)',
        () async {
      final c = candidate(script: [0x51, 0x20, 0x44]);
      await FrigateCandidatesRepository.instance.upsertCandidate(c);
      final sh = electrumScripthash(c.script);
      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return 'mempool-status';
          case 'blockchain.scripthash.get_history':
            return [
              {'height': 0, 'tx_hash': c.txid},
            ];
          default:
            throw Exception('unexpected method $method');
        }
      };

      final monitor = makeMonitor();
      await monitor.start(endpoint: '127.0.0.1:$port');
      await waitUntil(
          'initial subscribe',
          () async => server.requestMethods
              .contains('blockchain.scripthash.subscribe'));

      // The tx vanishes (evicted/RBF-replaced): history no longer contains it.
      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return 'empty-status';
          case 'blockchain.scripthash.get_history':
            return const [];
          default:
            throw Exception('unexpected method $method');
        }
      };
      server.pushNotification(
          'blockchain.scripthash.subscribe', [sh, 'empty-status']);

      await waitUntil(
          'candidate dropped',
          () async =>
              (await FrigateCandidatesRepository.instance
                      .getCandidate(c.txid, c.vout))
                  ?.status ==
              FrigateCandidateStatus.dropped);
      final owned = await db.query('owned_outputs',
          where: 'txid = ? AND vout = ?', whereArgs: [c.txid, c.vout]);
      expect(owned, isEmpty);
      expect(await FrigateCandidatesRepository.instance.getPendingBalance(), 0);
      await monitor.stop();
    });

    test('reconnect rebuilds the subscription set from the registry (B3.7)',
        () async {
      final c = candidate(script: [0x51, 0x20, 0x55]);
      await FrigateCandidatesRepository.instance.upsertCandidate(c);

      // The candidate's tx is in the mempool: serve the mempool entry so the
      // initial reconcile keeps the candidate pending (a txid absent from
      // history would drop it — correct behavior, wrong fixture here).
      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return 'mempool-status';
          case 'blockchain.scripthash.get_history':
            return [
              {'height': 0, 'tx_hash': c.txid},
            ];
          default:
            throw Exception('unexpected method $method');
        }
      };

      final monitor = makeMonitor();
      await monitor.start(endpoint: '127.0.0.1:$port');
      final firstSubscribes = server.requestMethods
          .where((m) => m == 'blockchain.scripthash.subscribe')
          .length;
      expect(firstSubscribes, greaterThanOrEqualTo(1));

      server.dropClients();

      await waitUntil('re-subscribe after reconnect', () async {
        final subscribes = server.requestMethods
            .where((m) => m == 'blockchain.scripthash.subscribe')
            .length;
        return subscribes > firstSubscribes;
      });
      await monitor.stop();
    });

    test(
        'no electrum endpoint configured: start() throws, phase 3 does '
        'not run (B3.6 soft leg at the wiring, B8.2 hard gate at the API)',
        () async {
      // Neither `frigateelectrumurl` nor `frigateurl` is set (prefs are
      // cleared in setUp): the B3.6 soft leg lives at the WIRING level —
      // FrigateSubscriptionController does not start the monitor without a
      // frigate URL — and at the monitor API boundary the attempt is the
      // B8.2 HARD gate: a thrown error, not a logged skip. No client is
      // built, no connection is opened, and candidates stay pending until
      // an endpoint is configured.
      final c = candidate(script: [0x51, 0x20, 0x77]);
      await FrigateCandidatesRepository.instance.upsertCandidate(c);

      var factoryCalls = 0;
      final monitor = FrigateConfirmationMonitor(
        clientFactory: (endpoint) async {
          factoryCalls++;
          return ElectrumClient.connect(endpoint,
              timeout: const Duration(seconds: 5));
        },
        reconnectDelay: const Duration(milliseconds: 20),
      );
      await expectLater(monitor.start(), throwsStateError);

      expect(factoryCalls, 0,
          reason: 'monitor must not build any electrum client when no '
              'endpoint is configured');
      expect(server.requestMethods, isEmpty,
          reason: 'no electrum connection may be opened');
      final row = await FrigateCandidatesRepository.instance
          .getCandidate(c.txid, c.vout);
      expect(row?.status, FrigateCandidateStatus.pending,
          reason: 'candidates stay pending without an endpoint');
      expect(await FrigateCandidatesRepository.instance.getPendingBalance(),
          c.amountSat);
    });

    test(
        'subscription cap: over-cap candidates poll get_history, never '
        'silently dropped (B3.7)', () async {
      expect(FrigateConfirmationMonitor.maxSubscriptionsDefault, 1024,
          reason: 'B3.7 hard-cap spec constant');

      final c1 = candidate(
          txid: '11' * 32, script: [0x51, 0x20, 0x81], firstSeen: 1000);
      final c2 = candidate(
          txid: '22' * 32, script: [0x51, 0x20, 0x82], firstSeen: 2000);
      final c3 = candidate(
          txid: '33' * 32, script: [0x51, 0x20, 0x83], firstSeen: 3000);
      for (final c in [c1, c2, c3]) {
        await FrigateCandidatesRepository.instance.upsertCandidate(c);
      }
      final shByScript = {
        for (final c in [c1, c2, c3]) electrumScripthash(c.script): c,
      };

      // Every candidate's tx is in the mempool: polling keeps them pending
      // (an empty history would drop them — correct O2 rule, wrong fixture).
      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return null;
          case 'blockchain.scripthash.get_history':
            final c = shByScript[params.first as String]!;
            return [
              {'height': 0, 'tx_hash': c.txid},
            ];
          default:
            throw Exception('unexpected method $method');
        }
      };

      // Cap lowered to 2: exactly two pendings subscribe, the third is
      // beyond the cap and must fall back to per-block polling.
      final monitor = makeMonitor(maxSubscriptions: 2);
      await monitor.start(endpoint: '127.0.0.1:$port');

      final allScripts = shByScript.keys.toSet();
      final subscribed = server
          .paramsFor('blockchain.scripthash.subscribe')
          .toSet()
          .intersection(allScripts);
      expect(subscribed, hasLength(2),
          reason: 'the cap bounds the live subscription set');
      final overCap = allScripts.difference(subscribed);
      expect(overCap, hasLength(1));
      expect(server.paramsFor('blockchain.scripthash.get_history'),
          containsAll(overCap),
          reason: 'beyond-cap candidate is reconciled via get_history '
              'polling, not dropped');

      // Never silently dropped: all three stay pending.
      for (final c in [c1, c2, c3]) {
        final row = await FrigateCandidatesRepository.instance
            .getCandidate(c.txid, c.vout);
        expect(row?.status, FrigateCandidateStatus.pending,
            reason: '${c.txid} must stay pending (polled, not dropped)');
      }
      expect(await FrigateCandidatesRepository.instance.getPendingBalance(),
          c1.amountSat + c2.amountSat + c3.amountSat);
      await monitor.stop();
    });

    test(
        'RBF replacement: replaced candidate drops, replacement stays '
        'pending — no zombie (B3.8)', () async {
      // The RBF replacement re-pays the same derived output: same script
      // (same scripthash), new txid -> new outpoint. Phase 2 upserts the
      // replacement candidate; phase 3 must drop the replaced tx's row on
      // the scripthash status change and keep the replacement pending.
      const replacedTxid = _txid;
      final replacementTxid = 'bb' * 32;
      final script = [0x51, 0x20, 0x91];
      final replaced = candidate(txid: replacedTxid, script: script);
      await FrigateCandidatesRepository.instance.upsertCandidate(replaced);
      final sh = electrumScripthash(Uint8List.fromList(script));

      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return 'pre-rbf-status';
          case 'blockchain.scripthash.get_history':
            return [
              {'height': 0, 'tx_hash': replacedTxid}, // pre-RBF mempool
            ];
          default:
            throw Exception('unexpected method $method');
        }
      };

      final monitor = makeMonitor();
      await monitor.start(endpoint: '127.0.0.1:$port');
      await waitUntil(
          'initial subscribe',
          () async => server.requestMethods
              .contains('blockchain.scripthash.subscribe'));

      // RBF: the replaced tx vanishes from the mempool, the replacement
      // appears; phase 2 upserts the new candidate (new outpoint) and the
      // monitor re-syncs.
      final replacement =
          candidate(txid: replacementTxid, vout: 0, script: script);
      await FrigateCandidatesRepository.instance.upsertCandidate(replacement);
      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return 'post-rbf-status';
          case 'blockchain.scripthash.get_history':
            return [
              {'height': 0, 'tx_hash': replacementTxid}, // replacement only
            ];
          default:
            throw Exception('unexpected method $method');
        }
      };
      await monitor.registerCandidates();
      server.pushNotification(
          'blockchain.scripthash.subscribe', [sh, 'post-rbf-status']);

      await waitUntil(
          'replaced candidate dropped',
          () async =>
              (await FrigateCandidatesRepository.instance
                      .getCandidate(replacedTxid, 0))
                  ?.status ==
              FrigateCandidateStatus.dropped);

      // The replacement is alive and pending; the replaced row is no
      // zombie: dropped, out of the pending balance, no owned state.
      final row = await FrigateCandidatesRepository.instance
          .getCandidate(replacementTxid, 0);
      expect(row?.status, FrigateCandidateStatus.pending);
      expect(await FrigateCandidatesRepository.instance.getPendingBalance(),
          replacement.amountSat);
      final owned = await db
          .query('owned_outputs', where: 'txid = ?', whereArgs: [replacedTxid]);
      expect(owned, isEmpty);
      await monitor.stop();
    });

    test(
        'block/10-minute reconciliation: stale pending is reconciled on a '
        'new block, fresh pending is not (B3.8)', () async {
      const now = 1700000000000;
      // Stale: older than the 10-minute window. Fresh: inside it.
      final stale = candidate(
          txid: 'cc' * 32,
          script: [0x51, 0x20, 0xa1],
          firstSeen: now - 11 * 60 * 1000);
      final fresh = candidate(
          txid: 'dd' * 32,
          script: [0x51, 0x20, 0xa2],
          firstSeen: now - 60 * 1000);
      await FrigateCandidatesRepository.instance.upsertCandidate(stale);
      await FrigateCandidatesRepository.instance.upsertCandidate(fresh);

      final shStale = electrumScripthash(stale.script);
      final shFresh = electrumScripthash(fresh.script);
      // Both txs are in the mempool at start (nothing to reconcile yet).
      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return 'mempool-status';
          case 'blockchain.scripthash.get_history':
            final txid =
                (params.first as String) == shStale ? stale.txid : fresh.txid;
            return [
              {'height': 0, 'tx_hash': txid},
            ];
          default:
            throw Exception('unexpected method $method');
        }
      };

      final monitor = makeMonitor(nowMillis: () => now);
      await monitor.start(endpoint: '127.0.0.1:$port');
      await waitUntil(
          'initial subscribes',
          () async =>
              server
                  .paramsFor('blockchain.scripthash.subscribe')
                  .contains(shStale) &&
              server
                  .paramsFor('blockchain.scripthash.subscribe')
                  .contains(shFresh));

      // A block is mined: the stale candidate's tx is now confirmed; the
      // fresh candidate's tx has vanished (it would be evicted if the
      // block path reconciled it — it must not).
      server.handler = (method, params) {
        switch (method) {
          case 'server.version':
            return ['MockElectrum 1.0', '1.4'];
          case 'blockchain.scripthash.subscribe':
            return 'mempool-status';
          case 'blockchain.scripthash.get_history':
            if (params.first as String == shStale) {
              return [
                {'height': 900, 'tx_hash': stale.txid},
              ];
            }
            return const [];
          default:
            throw Exception('unexpected method $method');
        }
      };
      server.pushNotification('blockchain.headers.subscribe', [
        {'height': 900, 'hex': '00'},
      ]);

      // The stale pending is reconciled against the fresh chain state…
      await waitUntil(
          'stale candidate graduated',
          () async =>
              (await FrigateCandidatesRepository.instance
                      .getCandidate(stale.txid, 0))
                  ?.status ==
              FrigateCandidateStatus.confirmed);
      final owned = await db
          .query('owned_outputs', where: 'txid = ?', whereArgs: [stale.txid]);
      expect(owned, hasLength(1));
      // …while the fresh pending is NOT reconciled on the block path: its
      // (evicted) chain state is untouched — the staleness gate holds.
      final freshRow = await FrigateCandidatesRepository.instance
          .getCandidate(fresh.txid, 0);
      expect(freshRow?.status, FrigateCandidateStatus.pending);
      await monitor.stop();
    });

    group('B8.2 hard gate', () {
      test(
          'start() without any resolvable electrum endpoint throws — '
          'the monitor never runs without the electrum path (B8.2)', () async {
        // Neither `frigateelectrumurl` nor `frigateurl` is set (prefs are
        // cleared in setUp): starting the monitor is a HARD failure at the
        // API boundary — a thrown error, not a logged skip. Deliberately
        // stronger than the B3.6 soft leg (the wiring level does not even
        // start the monitor without a frigate URL): the gate exists so no
        // code path can reach a RUNNING monitor with a missing electrum
        // path (the old breach: receipts found only after restart).
        final c = candidate(script: [0x51, 0x20, 0x90]);
        await FrigateCandidatesRepository.instance.upsertCandidate(c);

        var factoryCalls = 0;
        final monitor = FrigateConfirmationMonitor(
          clientFactory: (endpoint) async {
            factoryCalls++;
            return ElectrumClient.connect(endpoint,
                timeout: const Duration(seconds: 5));
          },
          reconnectDelay: const Duration(milliseconds: 20),
        );

        await expectLater(monitor.start(), throwsStateError);

        // The gate fires BEFORE any electrum work: no client built, no
        // connection opened, candidates untouched.
        expect(factoryCalls, 0,
            reason: 'the hard gate must fire before any client is built');
        expect(server.requestMethods, isEmpty,
            reason: 'no electrum connection may be opened');
        final row = await FrigateCandidatesRepository.instance
            .getCandidate(c.txid, c.vout);
        expect(row?.status, FrigateCandidateStatus.pending,
            reason: 'candidates stay pending without an endpoint');
        expect(await FrigateCandidatesRepository.instance.getPendingBalance(),
            c.amountSat);
      });

      test(
          'an explicit empty endpoint throws too — the gate is not '
          'bypassable via start(endpoint: ...)', () async {
        // Mutation check: an empty-string endpoint must not sneak past the
        // resolution chain (it is not a resolvable electrum path).
        var factoryCalls = 0;
        final monitor = FrigateConfirmationMonitor(
          clientFactory: (endpoint) async {
            factoryCalls++;
            return ElectrumClient.connect(endpoint,
                timeout: const Duration(seconds: 5));
          },
          reconnectDelay: const Duration(milliseconds: 20),
        );

        await expectLater(monitor.start(endpoint: ''), throwsStateError);
        expect(factoryCalls, 0);
        expect(server.requestMethods, isEmpty);
      });

      test(
          'after the throw the monitor is inert — registerCandidates '
          'never reaches a running monitor (B8.2)', () async {
        // The failed start must leave no live monitor behind: late
        // candidate registration (B3.7) cannot conjure an electrum path.
        final c = candidate(script: [0x51, 0x20, 0x91]);
        await FrigateCandidatesRepository.instance.upsertCandidate(c);

        var factoryCalls = 0;
        final monitor = FrigateConfirmationMonitor(
          clientFactory: (endpoint) async {
            factoryCalls++;
            return ElectrumClient.connect(endpoint,
                timeout: const Duration(seconds: 5));
          },
          reconnectDelay: const Duration(milliseconds: 20),
        );

        await expectLater(monitor.start(), throwsStateError);
        await monitor.registerCandidates();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(factoryCalls, 0,
            reason: 'a gated monitor must never build a client');
        expect(server.requestMethods, isEmpty);
        expect(await FrigateCandidatesRepository.instance.getPendingBalance(),
            c.amountSat);
      });
    });
  });
}
