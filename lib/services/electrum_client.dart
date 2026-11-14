import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:logger/logger.dart';

/// A history entry of `blockchain.scripthash.get_history`: `height` is the
/// confirmation height, or <= 0 for an unconfirmed (mempool) entry.
class ElectrumHistoryEntry {
  final int height;
  final String txHash;

  const ElectrumHistoryEntry({required this.height, required this.txHash});

  bool get isMempool => height <= 0;
}

/// A server-initiated electrum notification (a JSON-RPC message with a
/// `method` but no `id`).
class ElectrumNotification {
  final String method;
  final List<dynamic> params;

  const ElectrumNotification({required this.method, required this.params});
}

/// The server answered a request with a JSON-RPC error object.
class ElectrumServerException implements Exception {
  final String message;
  ElectrumServerException(this.message);

  @override
  String toString() => 'ElectrumServerException: $message';
}

/// The electrum scripthash of [script]: sha256, byte-reversed, hex-encoded.
String electrumScripthash(Uint8List script) {
  final digest = sha256.convert(script).bytes;
  return digest.reversed.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Minimal electrum-protocol client over a TCP socket (newline-delimited
/// JSON-RPC), speaking the subset phase 3 needs (B3.6): `server.version`
/// handshake FIRST (wire contract — electrs rejects anything else first),
/// `blockchain.scripthash.subscribe`/`get_history`, and
/// `blockchain.headers.subscribe` for block-driven reconciliation (B3.8).
///
/// This is the wallet's configured blindbit electrum-compatible API (or a
/// self-hosted electrs as the advanced override) — both speak this protocol.
/// The connection carries no scan key and reveals only scripthashes the
/// frigate operator already saw (B3.6).
class ElectrumClient {
  final String host;
  final int port;
  final Socket _socket;

  int _nextId = 0;
  final Map<int, Completer<dynamic>> _pending = {};
  final _notifications = StreamController<ElectrumNotification>.broadcast();
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  ElectrumClient._(this.host, this.port, this._socket) {
    _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: () {
      if (!_done.isCompleted) _done.complete();
    }, onError: (Object e) {
      if (!_done.isCompleted) _done.completeError(e);
    });
  }

  /// Connect and complete the `server.version` handshake (sent as the FIRST
  /// message on the wire) before the client is handed out.
  static Future<ElectrumClient> connect(
    String endpoint, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final colon = endpoint.lastIndexOf(':');
    if (colon <= 0 || colon == endpoint.length - 1) {
      throw ArgumentError.value(endpoint, 'endpoint', 'expected host:port');
    }
    final host = endpoint.substring(0, colon);
    final port = int.parse(endpoint.substring(colon + 1));

    final socket = await Socket.connect(host, port, timeout: timeout);
    final client = ElectrumClient._(host, port, socket);
    // Wire contract: server.version is the first message on a fresh socket.
    await client._call('server.version', ['danawallet-frigate', '1.4']);
    return client;
  }

  /// Resolves when the underlying socket is closed (server disconnect) —
  /// the monitor uses this to schedule a reconnect (B3.7 rebuild).
  Future<void> get done => _done.future;

  /// Server-initiated notifications (scripthash status changes, new block
  /// headers, ...).
  Stream<ElectrumNotification> get notifications => _notifications.stream;

  Future<dynamic> _call(String method, List<dynamic> params) {
    if (_closed) {
      return Future.error(StateError('electrum client closed'));
    }
    final id = ++_nextId;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _socket.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
      'id': id,
    }));
    return completer.future;
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Map<String, dynamic> message;
    try {
      message = jsonDecode(line) as Map<String, dynamic>;
    } catch (e) {
      Logger().w('electrum: undecodable line: $line');
      return;
    }
    final id = message['id'];
    if (id != null) {
      final completer = _pending.remove(id as int);
      if (completer == null) return;
      if (message.containsKey('error')) {
        final error = message['error'] as Map<String, dynamic>;
        completer.completeError(ElectrumServerException(
            (error['message'] ?? 'unknown error').toString()));
      } else {
        completer.complete(message['result']);
      }
    } else if (message['method'] is String) {
      _notifications.add(ElectrumNotification(
        method: message['method'] as String,
        params: (message['params'] as List?) ?? const [],
      ));
    }
  }

  /// Subscribe a scripthash; the response carries the current status (null
  /// when the server has no history for it yet). Status changes then arrive
  /// as notifications on [notifications].
  Future<String?> subscribeScripthash(String scripthash) async {
    final result = await _call('blockchain.scripthash.subscribe', [scripthash]);
    return result as String?;
  }

  /// Remove a subscription (graduation/drop — B3.7 keeps the live set
  /// exactly at the pending candidates).
  Future<void> unsubscribeScripthash(String scripthash) async {
    try {
      await _call('blockchain.scripthash.unsubscribe', [scripthash]);
    } on ElectrumServerException {
      // electrs < some versions don't implement unsubscribe; the
      // subscription is harmless (no pending candidate maps to it) and the
      // set is rebuilt from the table on every reconnect anyway.
    }
  }

  /// Confirmation history of a scripthash: confirmed entries carry
  /// height > 0, mempool entries height <= 0 (B3.8 classification input).
  Future<List<ElectrumHistoryEntry>> getHistory(String scripthash) async {
    final result =
        await _call('blockchain.scripthash.get_history', [scripthash]);
    final entries = (result as List?) ?? const [];
    return [
      for (final entry in entries)
        ElectrumHistoryEntry(
          height: (entry['height'] as num).toInt(),
          txHash: entry['tx_hash'] as String,
        ),
    ];
  }

  /// Subscribe to block headers; new blocks arrive as notifications on
  /// [notifications] (method `blockchain.headers.subscribe`) and drive the
  /// B3.8 fallback reconciliation.
  Future<void> subscribeHeaders() async {
    await _call('blockchain.headers.subscribe', const []);
  }

  Future<void> close() async {
    _closed = true;
    for (final completer in _pending.values) {
      completer.completeError(StateError('electrum client closed'));
    }
    _pending.clear();
    await _notifications.close();
    _socket.destroy();
  }
}
