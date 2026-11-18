import 'dart:io';

import 'package:danawallet/services/frigate_url_probe.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_electrum_server.dart';

/// B5.1: configuring a frigate URL probes parse + reachability, NEVER a
/// subscribe handshake (a probe must not burn the scan key).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('probeFrigateUrl (B5.1)', () {
    test('reachable server: completes, handshake is server.version FIRST',
        () async {
      final server = MockElectrumServer();
      final port = await server.start();
      addTearDown(server.stop);

      await probeFrigateUrl('127.0.0.1:$port');

      expect(await server.firstRequestMethod.future, 'server.version');
      expect(
        server.requestMethods,
        everyElement('server.version'),
        reason: 'a probe must never send a subscribe handshake (B5.1) — '
            'it must not burn the scan key',
      );
    });

    test('server rejecting server.version: human-readable probe error',
        () async {
      final server = MockElectrumServer();
      server.handler = (method, params) => throw 'internal error';
      final port = await server.start();
      addTearDown(server.stop);

      await expectLater(
        probeFrigateUrl('127.0.0.1:$port'),
        throwsA(isA<FrigateProbeException>()),
      );
    });

    test('unreachable port: probe error, message is human-readable', () async {
      // A bound-then-closed loopback port reliably refuses connections.
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();

      await expectLater(
        probeFrigateUrl('127.0.0.1:$port'),
        throwsA(isA<FrigateProbeException>()),
      );
      await expectLater(
        probeFrigateUrl('127.0.0.1:$port'),
        throwsA(
          isA<FrigateProbeException>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('Exception')),
          ),
        ),
        reason: 'B4.4: user-visible errors are human-readable',
      );
    });

    test('F-R12a: silent backend surfaces FrigateProbeUnreachable, no hang',
        () async {
      // Connected-but-silent socket (accepts, never replies): the save flow
      // used to hang in "Probing backend…" forever. The probe must return to
      // the editable screen with the inline error within the probe timeout.
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      silent.listen((_) {}); // swallow everything, never respond
      addTearDown(silent.close);

      final sw = Stopwatch()..start();
      await expectLater(
        probeFrigateUrl(
          '127.0.0.1:${silent.port}',
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<FrigateProbeUnreachable>()),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'a stalled probe must fail fast, not hang the save');
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('malformed URLs fail as parse errors (B5.1)', () async {
      for (final bad in const [
        '',
        'localhost',
        'host:',
        ':50002',
        'host:notaport',
      ]) {
        await expectLater(
          probeFrigateUrl(bad),
          throwsA(isA<FrigateProbeException>()),
          reason: "'$bad' must be rejected as a parse error",
        );
      }
    });
  });
}
