import 'dart:io';
import 'dart:typed_data';

import 'package:danawallet/repositories/frigate_candidates_repository.dart';
import 'package:danawallet/repositories/owned_outputs_repository.dart';
import 'package:danawallet/services/electrum_client.dart';
import 'package:danawallet/services/frigate_confirmation_monitor.dart';
import 'package:flutter_test/flutter_test.dart';
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
    final statements =
        sql.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty);
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
}) {
  return FrigateCandidate(
    txid: txid,
    vout: vout,
    tweak: Uint8List.fromList(List.filled(32, 7)),
    script: Uint8List.fromList(script ?? [0x51, 0x20, 0xaa]),
    amountSat: amountSat,
    firstSeen: 1000,
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
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await applyMigrations(db);
      FrigateCandidatesRepository.testDatabaseOverride = () async => db;
      OwnedOutputsRepository.testDatabaseOverride = () async => db;
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
      await server.stop();
      await db.close();
    });

    FrigateConfirmationMonitor makeMonitor({void Function()? onGraduated}) {
      return FrigateConfirmationMonitor(
        clientFactory: (endpoint) async =>
            ElectrumClient.connect(endpoint, timeout: const Duration(seconds: 5)),
        onGraduated: onGraduated,
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
      await waitUntil('subscribe request for $expected', () async =>
          server.paramsFor('blockchain.scripthash.subscribe').contains(expected));
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

    test('confirmation notification graduates into owned_outputs exactly '
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
      await waitUntil('initial subscribe', () async => server.requestMethods
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
      await waitUntil('candidate confirmed', () async =>
          (await FrigateCandidatesRepository.instance.getCandidate(c.txid, c.vout))
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
      await waitUntil('initial subscribe', () async => server.requestMethods
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

      await waitUntil('candidate dropped', () async =>
          (await FrigateCandidatesRepository.instance.getCandidate(c.txid, c.vout))
                  ?.status ==
              FrigateCandidateStatus.dropped);
      final owned = await db.query('owned_outputs',
          where: 'txid = ? AND vout = ?', whereArgs: [c.txid, c.vout]);
      expect(owned, isEmpty);
      expect(
          await FrigateCandidatesRepository.instance.getPendingBalance(), 0);
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
  });
}
