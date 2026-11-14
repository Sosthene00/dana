import 'dart:typed_data';

import 'package:danawallet/services/electrum_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_electrum_server.dart';

void main() {
  group('ElectrumClient', () {
    late MockElectrumServer server;
    late int port;

    setUp(() async {
      server = MockElectrumServer();
      port = await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    /// B3.6/wire contract: `server.version` is the FIRST message on a fresh
    /// connection (electrs and the rig frigate both require it).
    test('sends server.version as the first message on connect', () async {
      server.handler = (method, params) => ['MockElectrum 1.0', '1.4'];

      await ElectrumClient.connect('127.0.0.1:$port');

      await server.firstRequestMethod.future
          .timeout(const Duration(seconds: 5));
      expect(server.requestMethods.first, 'server.version');
    });

    test('subscribeScripthash returns the initial status', () async {
      server.handler = (method, params) {
        if (method == 'server.version') return ['MockElectrum 1.0', '1.4'];
        if (method == 'blockchain.scripthash.subscribe') return 'statusA';
        throw Exception('unexpected method $method');
      };

      final client = await ElectrumClient.connect('127.0.0.1:$port');
      final status = await client.subscribeScripthash('cafe');
      expect(status, 'statusA');
      await client.close();
    });

    test('getHistory parses confirmed and mempool entries', () async {
      const txidConfirmed =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const txidMempool =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      server.handler = (method, params) {
        if (method == 'server.version') return ['MockElectrum 1.0', '1.4'];
        if (method == 'blockchain.scripthash.get_history') {
          return [
            {'height': 800, 'tx_hash': txidConfirmed},
            {'height': 0, 'tx_hash': txidMempool},
          ];
        }
        throw Exception('unexpected method $method');
      };

      final client = await ElectrumClient.connect('127.0.0.1:$port');
      final history = await client.getHistory('cafe');
      expect(history, hasLength(2));
      expect(history[0].height, 800);
      expect(history[0].txHash, txidConfirmed);
      expect(history[1].height, 0);
      expect(history[1].txHash, txidMempool);
      await client.close();
    });

    test('surfaces server notifications on the notifications stream',
        () async {
      server.handler = (method, params) {
        if (method == 'server.version') return ['MockElectrum 1.0', '1.4'];
        if (method == 'blockchain.scripthash.subscribe') return null;
        throw Exception('unexpected method $method');
      };

      final client = await ElectrumClient.connect('127.0.0.1:$port');
      final notifications = client.notifications;

      await client.subscribeScripthash('cafe');
      server.pushNotification(
          'blockchain.scripthash.subscribe', ['cafe', 'statusB']);

      final notification =
          await notifications.first.timeout(const Duration(seconds: 5));
      expect(notification.method, 'blockchain.scripthash.subscribe');
      expect(notification.params[0], 'cafe');
      expect(notification.params[1], 'statusB');
      await client.close();
    });

    test('a server error response completes the call with an error',
        () async {
      server.handler = (method, params) {
        if (method == 'server.version') return ['MockElectrum 1.0', '1.4'];
        throw Exception('boom');
      };

      final client = await ElectrumClient.connect('127.0.0.1:$port');
      await expectLater(
        client.getHistory('cafe'),
        throwsA(isA<ElectrumServerException>()),
      );
      await client.close();
    });

    });

  group('electrumScripthash', () {
    test('is sha256 of the script, byte-reversed, hex-encoded', () {
      // sha256 of the empty script is
      // e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855;
      // the electrum scripthash is that value with the HASH BYTES reversed.
      final sh = electrumScripthash(Uint8List(0));
      expect(sh,
          '55b852781b9995a44c939b64e441ae2724b96f99c8f4fb9a141cfc9842c4b0e3');
    });
  });
}
