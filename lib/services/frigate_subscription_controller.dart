import 'dart:async';

import 'package:danawallet/generated/rust/api/stream.dart';
import 'package:danawallet/generated/rust/api/structs/frigate_event.dart';
import 'package:danawallet/generated/rust/api/wallet/frigate.dart'
    as frigate_api;
import 'package:danawallet/repositories/owned_outputs_repository.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/repositories/wallet_repository.dart';
import 'package:danawallet/services/frigate_confirmation_monitor.dart';
import 'package:danawallet/services/frigate_event_handler.dart';
import 'package:danawallet/states/frigate_state.dart';
import 'package:logger/logger.dart';

/// Owns the app-side leg of the held frigate subscription (phase 2) and the
/// phase-3 confirmation monitor.
///
/// Starts the Rust-held subscription from the wallet's committed checkpoint
/// (B1.2) when a frigate URL is configured, and listens to the frigate event
/// stream. Every event is handed to [FrigateEventHandler], which writes the
/// mempool leg into `frigate_candidates` (B3.1); the [FrigateState] is
/// refreshed after each event so the unconfirmed balance line tracks the
/// registry (B4.1).
///
/// Phase 3 (B3.6-B3.8, the B8.2 hard gate): alongside the subscription the
/// [FrigateConfirmationMonitor] holds the electrum leg — it subscribes the
/// pending candidates' scripthashes (B3.7), and on confirmation
/// notifications graduates them into `owned_outputs` (B3.3) via
/// [onGraduated] (the confirmed balance refreshes from the repository);
/// evicted mempool txs drop their candidate (B3.5/B3.8).
///
/// Idempotent: a second start while the stream is already owned is a no-op
/// (mirrors B1.3 on the Rust side, which holds a single subscription).
///
/// Scope note: the subscription currently starts in-process with the app.
/// Moving it into the foreground service with the writer lease is R6's card
/// (B2.1/B2.3/B2.8); the event handling itself already lives here, in Dart,
/// per B2.7.
class FrigateSubscriptionController {
  late final FrigateEventHandler _handler;
  final FrigateState _frigateState;
  final FrigateConfirmationMonitor _monitor;
  StreamSubscription<FrigateEventDto>? _events;
  bool _starting = false;

  FrigateSubscriptionController({
    required FrigateState frigateState,
    FrigateEventHandler? handler,
    FrigateConfirmationMonitor? confirmationMonitor,

    /// Called when a candidate graduated into `owned_outputs` (B3.3) — the
    /// app refreshes the confirmed balance from the repository.
    void Function()? onGraduated,
  })  : _frigateState = frigateState,
        _monitor = confirmationMonitor ??
            FrigateConfirmationMonitor(onGraduated: onGraduated) {
    _handler = handler ??
        FrigateEventHandler(
          onChanged: () {
            unawaited(frigateState.refresh());
          },
          onCandidatesRecorded: () {
            // Phase 3 (B3.7): subscribe the new candidates' scripthashes.
            unawaited(_monitor.registerCandidates());
          },
        );
  }

  bool get isRunning => _events != null;

  Future<void> start() async {
    if (_events != null || _starting) return;
    _starting = true;
    try {
      final wallet = await WalletRepository.instance.readWallet();
      if (wallet == null) {
        Logger().i('frigate: no wallet, subscription not started');
        return;
      }

      final hostUrl = await SettingsRepository.instance.getFrigateUrl();
      if (hostUrl == null || hostUrl.isEmpty) {
        Logger()
            .i('frigate: no backend URL configured, subscription not started');
        return;
      }

      // start_height = the committed checkpoint (B1.2); a fresh wallet that
      // never synced replays from 0.
      final startHeight = await WalletRepository.instance.readLastSync() ?? 0;
      final ownedOutputs =
          await OwnedOutputsRepository.instance.getUnspentOutputs();

      // Single owner of the frigate event stream (one sink on the Rust side).
      _events = createFrigateEventStream().listen((event) async {
        await _handler.handleEvent(event);
        await _frigateState.refresh();
      });

      await wallet.startFrigateSubscription(
        hostUrl: hostUrl,
        startHeight: startHeight,
        ownedOutputs: ownedOutputs,
      );
      await _frigateState.refresh();
      Logger().i(
          'frigate subscription started from checkpoint height $startHeight (B1.2)');

      // Phase 3 (B8.2 hard gate): the electrum confirmation path runs
      // whenever the frigate path runs. No-op unless an electrum endpoint is
      // configured.
      await _monitor.start();
    } catch (e) {
      Logger().e('frigate subscription failed to start: $e');
      await _events?.cancel();
      _events = null;
      rethrow;
    } finally {
      _starting = false;
    }
  }

  Future<void> stop() async {
    await _events?.cancel();
    _events = null;
    await _monitor.stop();
    await frigate_api.stopFrigateSubscription();
  }
}
