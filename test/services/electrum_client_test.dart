import 'dart:async';
import 'dart:io';
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

    test('surfaces server notifications on the notifications stream', () async {
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

    test('a server error response completes the call with an error', () async {
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

    test('F-R12a: connect times out on a connected-but-silent socket',
        () async {
      // A listen-only socket: accepts and never replies (no data, no FIN) —
      // the exact half-open shape that hung the B5.1 save forever. The
      // handshake `server.version` must surface a catchable TimeoutException
      // instead of hanging the caller.
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      silent.listen((_) {}); // swallow everything, never respond
      addTearDown(silent.close);

      await expectLater(
        ElectrumClient.connect(
          '127.0.0.1:${silent.port}',
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<TimeoutException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 5)));

    test('F-R12a: a call with no reply times out and tears down the socket',
        () async {
      server.silentMethods.add('blockchain.scripthash.get_history');
      server.handler = (method, params) {
        if (method == 'server.version') return ['MockElectrum 1.0', '1.4'];
        throw Exception('unexpected method $method');
      };

      final client = await ElectrumClient.connect(
        '127.0.0.1:$port',
        timeout: const Duration(milliseconds: 300),
      );

      await expectLater(
        client.getHistory('cafe'),
        throwsA(isA<TimeoutException>()),
      );
      // The stalled connection must be torn down so the B3.7 reconnect (the
      // confirmation-monitor path) fires instead of limping on half-open.
      await expectLater(client.done, completes);
    }, timeout: const Timeout(Duration(seconds: 5)));

    test(
        'F-R12b: an idle blackholed connection is torn down so done completes',
        () async {
      // The audit finding (t_037006b4) second half: after the handshake and a
      // subscription there are NO in-flight calls — the F-R12a per-call
      // timeout never arms, and a half-open socket (mobile network transition)
      // leaves the connection silently dead: done never completes, the B3.7
      // reconnect never fires, confirmation monitoring stalls until app
      // restart. The server here swallows every further request and never
      // replies — the client MUST notice on its own (keepalive) and tear down.
      server.handler = (method, params) {
        if (method == 'server.version') return ['MockElectrum 1.0', '1.4'];
        if (method == 'blockchain.scripthash.subscribe') return 'statusA';
        throw Exception('unexpected method $method');
      };

      final client = await ElectrumClient.connect(
        '127.0.0.1:$port',
        timeout: const Duration(milliseconds: 300),
        keepaliveInterval: const Duration(milliseconds: 200),
      );
      await client.subscribeScripthash('cafe');

      // From now on the connection is a blackhole: the keepalive probe is
      // swallowed (no reply, no FIN) — exactly a half-open NAT/conntrack drop.
      server.silentMethods.add('server.ping');

      // The next keepalive ping goes unanswered; the per-call timeout tears
      // the connection down well inside this window.
      await expectLater(client.done, completes);
    }, timeout: const Timeout(Duration(seconds: 8)));

    test('F-R12b: keepalive pings the server periodically while idle',
        () async {
      server.handler = (method, params) {
        if (method == 'server.version') return ['MockElectrum 1.0', '1.4'];
        if (method == 'server.ping') return null;
        if (method == 'blockchain.scripthash.subscribe') return 'statusA';
        throw Exception('unexpected method $method');
      };

      final client = await ElectrumClient.connect(
        '127.0.0.1:$port',
        keepaliveInterval: const Duration(milliseconds: 150),
      );
      await client.subscribeScripthash('cafe');

      await Future<void>.delayed(const Duration(milliseconds: 700));

      final pings = server.requestMethods.where((m) => m == 'server.ping');
      expect(pings.length, greaterThanOrEqualTo(3));
      await client.close();
    }, timeout: const Timeout(Duration(seconds: 5)));

    test(
        'F-R12b: a server error reply to the ping keeps the connection alive',
        () async {
      // electrs builds without ping support answer `server.ping` with a
      // JSON-RPC error — that is a REPLY, so the socket is alive and must
      // NOT be torn down.
      server.handler = (method, params) {
        if (method == 'server.version') return ['MockElectrum 1.0', '1.4'];
        if (method == 'server.ping') {
          throw Exception('method server.ping not supported');
        }
        if (method == 'blockchain.scripthash.get_history') return [];
        throw Exception('unexpected method $method');
      };

      final client = await ElectrumClient.connect(
        '127.0.0.1:$port',
        keepaliveInterval: const Duration(milliseconds: 150),
      );

      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Still usable...
      expect(await client.getHistory('cafe'), isEmpty);
      // ...and done has NOT completed.
      await expectLater(
        client.done.timeout(const Duration(milliseconds: 300)),
        throwsA(isA<TimeoutException>()),
      );
      await client.close();
    }, timeout: const Timeout(Duration(seconds: 5)));
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
