import 'dart:async';
import 'dart:io';

import 'package:danawallet/services/electrum_client.dart';

/// The result of probing a frigate backend URL failed — the message is
/// human-readable and shown inline in the declaration dialog (B5.1/B4.4).
class FrigateProbeException implements Exception {
  final String message;
  const FrigateProbeException(this.message);

  @override
  String toString() => message;
}

/// Thrown by [probeFrigateUrl] when the probe cannot reach the backend
/// (distinct signal: an unreachable URL must never fire the warning, B5.4).
class FrigateProbeUnreachable extends FrigateProbeException {
  const FrigateProbeUnreachable(super.message);
}

/// B5.1: parse + reachability probe for a frigate backend URL.
///
/// The probe is a plain electrum-protocol handshake — `server.version` sent
/// FIRST on a fresh socket (the wire contract) — and NOTHING else: it never
/// subscribes, so it never burns the scan key (B5.1). The scan key crosses
/// the wire only on a real subscribe.
///
/// Throws [FrigateProbeException] with a human-readable message when the
/// URL does not parse (expected `host:port`) or the backend is unreachable.
Future<void> probeFrigateUrl(
  String url, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final trimmed = url.trim();
  final colon = trimmed.lastIndexOf(':');
  if (trimmed.isEmpty || colon <= 0 || colon == trimmed.length - 1) {
    throw const FrigateProbeException(
        'Invalid backend URL — expected host:port (e.g. frigate.lan:50002)');
  }
  final port = int.tryParse(trimmed.substring(colon + 1));
  if (port == null || port < 1 || port > 65535) {
    throw const FrigateProbeException(
        'Invalid backend URL — the port must be a number between 1 and 65535');
  }

  ElectrumClient? client;
  try {
    client = await ElectrumClient.connect(trimmed, timeout: timeout);
  } on TimeoutException {
    // F-R12a: connected but silent (no server.version reply) — this used to
    // hang the save forever. Surface the existing unreachable path so the
    // save flow returns to the editable screen with the inline error.
    throw FrigateProbeUnreachable(
        'Backend at $trimmed did not respond within ${timeout.inSeconds}s');
  } on FrigateProbeException {
    rethrow;
  } on ArgumentError {
    throw FrigateProbeException(
        'Invalid backend URL — expected host:port, got "$url"');
  } on SocketException catch (e) {
    throw FrigateProbeUnreachable(
        'Could not reach the backend at $trimmed: ${e.message}');
  } on Exception catch (e) {
    final text = e.toString();
    // B4.4: strip the exception-class noise from user-visible errors.
    final message = text.replaceFirst(RegExp(r'^[A-Za-z0-9_.]+:\s*'), '');
    throw FrigateProbeException('Backend probe failed for $trimmed: $message');
  } finally {
    // Never leak the probe socket on a failure path (stalled connections
    // included — the client tears itself down, close() is idempotent).
    await client?.close();
  }
}
