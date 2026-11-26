import 'package:danawallet/extensions/network.dart';
import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/generated/rust/api/wallet.dart';
import 'package:danawallet/repositories/mempool_api_repository.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/services/electrum_client.dart';
import 'package:logger/logger.dart';

/// Where a signed transaction is broadcast.
///
/// R14/B1.2 consumer rule (same rule as [SyncEngine.trySync]): the SINGLE
/// committed chain-backend decision decides the broadcast path. Before the
/// fix this file exists for, the spend path broadcast by NETWORK: a
/// frigate-backend wallet fell back to the network's default blindbit URL,
/// which returned an empty body the client failed to parse
/// ("EOF while parsing a value at line 1 column 0"), dropping the
/// already-signed transaction.
sealed class BroadcastRoute {
  const BroadcastRoute();
}

/// Frigate backend: broadcast via the frigate electrum endpoint
/// (`blockchain.transaction.broadcast` over the `server.version`-first
/// wire contract).
class FrigateBroadcastRoute extends BroadcastRoute {
  /// Electrum endpoint as host:port.
  final String endpoint;

  const FrigateBroadcastRoute(this.endpoint);
}

/// Blindbit backend on regtest: POST the tx to the configured blindbit
/// instance (the Rust `forward_tx` path).
class BlindbitHttpBroadcastRoute extends BroadcastRoute {
  final String blindbitUrl;

  const BlindbitHttpBroadcastRoute(this.blindbitUrl);
}

/// Blindbit backend on mainnet/testnet: p2p broadcast (no third-party API —
/// privacy).
class P2pBroadcastRoute extends BroadcastRoute {
  const P2pBroadcastRoute();
}

/// Blindbit backend on signet: the signet mempool API.
class MempoolBroadcastRoute extends BroadcastRoute {
  const MempoolBroadcastRoute();
}

/// Resolves the broadcast route from the committed backend decision
/// (R14/B1.2, the same consumer rule trySync applies). There is NO
/// silent network-default fallback for the frigate
/// backend: with no endpoint configured it throws — a user-visible hard
/// failure — instead of broadcasting a frigate wallet to some default
/// blindbit instance.
Future<BroadcastRoute> resolveBroadcastRoute(
  Network network, {
  SettingsRepository? settings,
}) async {
  final s = settings ?? SettingsRepository.instance;
  if (await s.getChainBackend() == ChainBackendKind.frigate) {
    var endpoint = await s.getFrigateElectrumUrl();
    if (endpoint == null || endpoint.isEmpty) {
      // Interim default (same pattern as the B3.6 confirmation monitor):
      // the frigate backend endpoint IS an electrum endpoint — the B5.1
      // probe handshakes `server.version` against the same host:port —
      // so the frigate URL is reused until the R7 electrum endpoint UI.
      endpoint = await s.getFrigateUrl();
    }
    if (endpoint == null || endpoint.isEmpty) {
      throw StateError(
          'frigate backend is committed but no electrum endpoint is '
          'configured (frigateelectrumurl / frigateurl); refusing to fall '
          'back to a network-default broadcast endpoint');
    }
    return FrigateBroadcastRoute(endpoint);
  }

  // Blindbit backend: its own broadcast path per network.
  switch (network) {
    case Network.regtest:
      final blindbitUrl =
          await s.getBlindbitUrl() ?? network.defaultBlindbitUrl;
      return BlindbitHttpBroadcastRoute(blindbitUrl);
    case Network.mainnet:
    case Network.testnet3:
    case Network.testnet4:
      return const P2pBroadcastRoute();
    case Network.signet:
      return const MempoolBroadcastRoute();
  }
}

/// Broadcasts a signed raw transaction (hex) along the route the committed
/// backend decision resolves to. Returns the txid.
///
/// A broadcast failure THROWS — the caller surfaces it as user-visible state
/// (the tx stays "signed, not broadcast" and the send screen offers a retry);
/// it is never log-and-dropped.
Future<String> broadcastSignedTx(
  String txHex,
  Network network, {
  SettingsRepository? settings,
}) async {
  final route = await resolveBroadcastRoute(network, settings: settings);
  Logger().i('broadcast route: $route');

  if (route is FrigateBroadcastRoute) {
    final client = await ElectrumClient.connect(route.endpoint);
    try {
      final txid = await client.broadcast(txHex);
      Logger().i('frigate backend broadcast result: $txid');
      return txid;
    } finally {
      await client.close();
    }
  }
  if (route is BlindbitHttpBroadcastRoute) {
    return SpWallet.broadcastUsingBlindbit(
        blindbitUrl: route.blindbitUrl, tx: txHex);
  }
  if (route is P2pBroadcastRoute) {
    return SpWallet.broadcastTx(tx: txHex, network: network);
  }
  if (route is MempoolBroadcastRoute) {
    return MempoolApiRepository(network: network).postTransaction(txHex);
  }
  throw StateError('unhandled broadcast route: $route');
}
