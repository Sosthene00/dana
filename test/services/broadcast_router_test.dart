// Broadcast-backend regression tests (t_e19071db, live-rig e2e 2026-11-26).
//
// Bug: the spend path broadcast by NETWORK, not by the committed backend —
// a frigate-backend wallet fell back to the network's default blindbit URL,
// which returned an empty body the client failed to parse
// ("AnyhowException(EOF while parsing a value at line 1 column 0)"), and the
// already-signed transaction was dropped (log-and-drop, no recoverable state).
//
// Contract under test (R14/B1.2 consumer rule — same rule as trySync):
// the SINGLE committed chain-backend decision decides the broadcast path:
//   frigate backend  -> the frigate electrum endpoint
//                       (`blockchain.transaction.broadcast`, server.version
//                       handshake FIRST), with the frigate URL itself as the
//                       interim default when no electrum override is set
//                       (same pattern as the B3.6 confirmation monitor) and a
//                       HARD refusal — never a network-default blindbit
//                       fallback — when neither is configured;
//   blindbit backend -> its own broadcast path (configured blindbit URL on
//                       regtest, p2p on mainnet/testnet, mempool on signet).
//
// ignore_for_file: unimplemented_noSuchMethod
import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/services/broadcast_router.dart';
import 'package:danawallet/services/electrum_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'mock_electrum_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsRepository settings;

  // ONE shared in-memory prefs store for the whole suite:
  // SharedPreferencesAsync captures its platform instance at construction,
  // so the repository singleton keeps whatever store was live at its first
  // use. Reassigning a fresh instance per setUp would diverge from the
  // singleton's captured store (see sync_engine_backend_gate_test.dart) —
  // the same instance is assigned every test and cleared per test instead.
  final sharedPrefs = InMemorySharedPreferencesAsync.withData(const {});

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance = sharedPrefs;
    await SharedPreferencesAsync().clear();
    settings = SettingsRepository.instance;
  });

  group('resolveBroadcastRoute — committed-backend selection', () {
    test('frigate backend broadcasts via the frigate electrum endpoint, '
        'never the network-default blindbit URL', () async {
      await settings.setChainBackend(ChainBackendKind.frigate);
      await settings.setFrigateElectrumUrl('127.0.0.1:50002');

      final route = await resolveBroadcastRoute(Network.regtest);

      expect(route, isA<FrigateBroadcastRoute>());
      expect((route as FrigateBroadcastRoute).endpoint, '127.0.0.1:50002');
    });

    test('frigate backend without an electrum override falls back to the '
        'frigate URL itself (interim default, B3.6 monitor pattern)',
        () async {
      await settings.setChainBackend(ChainBackendKind.frigate);
      await settings.setFrigateUrl('192.168.1.44:50002');

      final route = await resolveBroadcastRoute(Network.regtest);

      expect(route, isA<FrigateBroadcastRoute>());
      expect((route as FrigateBroadcastRoute).endpoint, '192.168.1.44:50002');
    });

    test('frigate backend with no endpoint configured REFUSES to fall back '
        'to the network-default broadcast endpoint', () async {
      await settings.setChainBackend(ChainBackendKind.frigate);

      await expectLater(
        resolveBroadcastRoute(Network.regtest),
        throwsStateError,
      );
    });

    test('blindbit backend on regtest uses the configured blindbit URL',
        () async {
      await settings.setChainBackend(ChainBackendKind.blindbit);
      await settings.setBlindbitUrl('http://my-blindbit:8000');

      final route = await resolveBroadcastRoute(Network.regtest);

      expect(route, isA<BlindbitHttpBroadcastRoute>());
      expect(
          (route as BlindbitHttpBroadcastRoute).blindbitUrl,
          'http://my-blindbit:8000');
    });

    test('blindbit backend on regtest without a configured URL keeps its own '
        'network default (the blindbit backend default, not a cross-backend '
        'fallback)', () async {
      await settings.setChainBackend(ChainBackendKind.blindbit);

      final route = await resolveBroadcastRoute(Network.regtest);

      expect(route, isA<BlindbitHttpBroadcastRoute>());
      expect((route as BlindbitHttpBroadcastRoute).blindbitUrl, isNotEmpty);
    });

    test('blindbit backend on mainnet uses the p2p broadcast path', () async {
      await settings.setChainBackend(ChainBackendKind.blindbit);

      final route = await resolveBroadcastRoute(Network.mainnet);

      expect(route, isA<P2pBroadcastRoute>());
    });
  });

  group('ElectrumClient.broadcast — frigate-backend broadcast wire', () {
    late MockElectrumServer server;
    late int port;

    setUp(() async {
      server = MockElectrumServer();
      port = await server.start();
    });

    tearDown(() async {
      await server.stop();
    });

    test('broadcasts via blockchain.transaction.broadcast and returns the '
        'txid (server.version handshake still FIRST)', () async {
      const txid =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      server.handler = (method, params) {
        if (method == 'server.version') return ['MockElectrum 1.0', '1.4'];
        if (method == 'blockchain.transaction.broadcast') return txid;
        throw Exception('unexpected method $method');
      };

      final client = await ElectrumClient.connect('127.0.0.1:$port');
      final result = await client.broadcast('0200abcd');
      expect(result, txid);

      await server.firstRequestMethod.future
          .timeout(const Duration(seconds: 5));
      expect(server.requestMethods.first, 'server.version');
      expect(server.paramsFor('blockchain.transaction.broadcast'),
          ['0200abcd']);

      await client.close();
    });

    test('a server rejection surfaces as a catchable ElectrumServerException '
        '(the failure is user-visible, never silently dropped)', () async {
      server.handler = (method, params) {
        if (method == 'server.version') return ['MockElectrum 1.0', '1.4'];
        if (method == 'blockchain.transaction.broadcast') {
          throw Exception('tx-already-in-mempool');
        }
        throw Exception('unexpected method $method');
      };

      final client = await ElectrumClient.connect('127.0.0.1:$port');
      await expectLater(
        client.broadcast('0200abcd'),
        throwsA(isA<ElectrumServerException>()),
      );
      await client.close();
    });
  });
}
