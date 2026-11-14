import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal in-process electrum-protocol server for client/monitor tests:
/// newline-delimited JSON, responses matched by request id, notifications
/// pushed verbatim to every connected client.
class MockElectrumServer {
  /// Request handler: receives (method, params), returns the JSON `result`
  /// value, or throws to answer with a JSON-RPC error object.
  dynamic Function(String method, List<dynamic> params) handler =
      (method, params) => null;

  /// Methods seen on the wire, in arrival order (across all connections).
  final List<String> requestMethods = [];

  /// Params of each request, aligned with [requestMethods].
  final List<List<dynamic>> requestParams = [];

  /// All params ever seen (flattened) for a given method.
  List<dynamic> paramsFor(String method) => [
        for (var i = 0; i < requestMethods.length; i++)
          if (requestMethods[i] == method) ...requestParams[i],
      ];

  /// Fires once for the first request received on any connection — used to
  /// assert wire-order properties (e.g. `server.version` first) without
  /// racing the response path.
  final Completer<String> firstRequestMethod = Completer<String>();

  ServerSocket? _server;
  final List<Socket> _sockets = [];

  Future<int> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_onConnection);
    return _server!.port;
  }

  void _onConnection(Socket socket) {
    _sockets.add(socket);
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isEmpty) return;
      final req = jsonDecode(line) as Map<String, dynamic>;
      final method = req['method'] as String;
      requestMethods.add(method);
      requestParams.add(((req['params'] as List?) ?? const []).toList());
      if (!firstRequestMethod.isCompleted) firstRequestMethod.complete(method);
      final params = (req['params'] as List?) ?? const [];
      final id = req['id'];
      try {
        final result = handler(method, params);
        socket.writeln(jsonEncode({
          'jsonrpc': '2.0',
          'result': result,
          'id': id,
        }));
      } catch (e) {
        socket.writeln(jsonEncode({
          'jsonrpc': '2.0',
          'error': {'code': 1, 'message': e.toString()},
          'id': id,
        }));
      }
    });
  }

  /// Push a server-initiated notification (no id) to every connected client.
  void pushNotification(String method, List<dynamic> params) {
    for (final socket in List<Socket>.from(_sockets)) {
      socket.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      }));
    }
  }

  /// Drop every client connection (simulates a server-side disconnect).
  void dropClients() {
    for (final socket in List<Socket>.from(_sockets)) {
      socket.destroy();
    }
    _sockets.clear();
  }

  Future<void> stop() async {
    dropClients();
    await _server?.close();
    _server = null;
  }
}
