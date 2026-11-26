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
import 'package:danawallet/services/frigate_warning_gate.dart';
import 'package:danawallet/services/writer_lease.dart';
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
/// The sync host acquires [writerLease] before it chooses this scanner
/// (B2.3 / B2.8). [start] re-checks that same lease and refuses when a
/// different writer holds it. [stopSubscription] ends the subscription and
/// the confirmation monitor and does not release the lease — the host
/// releases it only when the host itself stops, so a backend swap cannot
/// invite the other isolate in mid-switch.
class FrigateSubscriptionController {
  late final FrigateEventHandler _handler;
  final FrigateState _frigateState;
  final FrigateConfirmationMonitor _monitor;
  final WriterLease? writerLease;

  /// B5.2-B5.4: the public-warning gate deciding whether the subscription
  /// may start. Since owner ruling R12 (2026-11-18) the warning normally
  /// fires at SAVE time in ChainBackendScreen; this gate remains only as
  /// the migration path for installs whose public unacked URL predates the
  /// ruling (injectable for tests; defaults to the real repositories).
  final FrigateWarningGate warningGate;

  /// Called after every processed event — the foreground-service wiring
  /// pings the main isolate so the UI re-reads the DB (B2.2).
  final void Function()? onEventProcessed;
  StreamSubscription<FrigateEventDto>? _events;
  bool _starting = false;

  FrigateSubscriptionController({
    required FrigateState frigateState,
    FrigateEventHandler? handler,
    FrigateConfirmationMonitor? confirmationMonitor,
    this.writerLease,
    FrigateWarningGate? warningGate,

    /// Called when a candidate graduated into `owned_outputs` (B3.3) — the
    /// app refreshes the confirmed balance from the repository.
    void Function()? onGraduated,

    /// Called after every processed event (used by the foreground-service
    /// wiring to ping the main isolate so the UI refreshes from the DB).
    this.onEventProcessed,
  })  : _frigateState = frigateState,
        _monitor = confirmationMonitor ??
            FrigateConfirmationMonitor(
              onGraduated: onGraduated,
              writerLease: writerLease,
            ),
        warningGate = warningGate ?? FrigateWarningGate() {
    _handler = handler ??
        FrigateEventHandler(
          writerLease: writerLease,
          onChanged: () {
            unawaited(frigateState.refresh());
          },
          onCandidatesRecorded: () {
            // Phase 3 (B3.7): subscribe the new candidates' scripthashes.
            unawaited(_monitor.registerCandidates());
          },
          // R3: history-leg receipts also land in `owned_outputs` — the
          // confirmed balance refreshes through the same channel as a
          // phase-3 graduation.
          onConfirmed: onGraduated,
        );
  }

  bool get isRunning => _events != null;

  /// Start the subscription and become the sync-state writer. Returns true
  /// when the subscription is running (we hold the writer lease), false when
  /// it was not started (no wallet, no backend URL, or a live foreign writer
  /// holds the lease — read-only mode, B2.2/B2.3).
  Future<bool> start() async {
    if (_events != null || _starting) return isRunning;
    _starting = true;
    try {
      final wallet = await WalletRepository.instance.readWallet();
      if (wallet == null) {
        Logger().i('frigate: no wallet, subscription not started');
        return false;
      }

      final settings = SettingsRepository.instance;
      final hostUrl = await settings.getFrigateUrl();
      if (hostUrl == null || hostUrl.isEmpty) {
        Logger()
            .i('frigate: no backend URL configured, subscription not started');
        return false;
      }

      // B5.2-B5.4: the one-time public warning. Since ruling R12 the
      // warning fires at SAVE time, so this gate only trips for state saved
      // before the ruling: a public unacked URL still blocks the first
      // public sync and fires the warning exactly once (B5.4), in both the
      // app isolate and the foreground-service path (B2.2 snapshot flag).
      // A private URL proceeds untouched (the gate probes nothing).
      final decision = await warningGate.evaluate();
      switch (decision) {
        case FrigateGateDecision.proceed:
          break;
        case FrigateGateDecision.warningRequired:
        case FrigateGateDecision.warningHold:
          _frigateState.setPublicWarningPending(true);
          return false;
      }

      // Single-writer handoff (B2.3/B2.8): acquire the writer lease BEFORE
      // any subscription state is touched. A live foreign writer (the
      // foreground service) keeps us read-only; a stale lease IS the
      // confirmation that the previous writer is down — we take over.
      if (writerLease != null && !await writerLease!.tryAcquire()) {
        Logger().i('frigate: writer lease held by a live writer — '
            'staying read-only (B2.2/B2.3)');
        return false;
      }

      // start_height = the committed checkpoint (B1.2); a fresh wallet that
      // never synced replays from 0.
      final startHeight = await WalletRepository.instance.readLastSync() ?? 0;
      final ownedOutputs =
          await OwnedOutputsRepository.instance.getUnspentOutputs();

      // Single owner of the frigate event stream (one sink on the Rust side).
      _events = createFrigateEventStream().listen((event) async {
        // B4.3/B4.4: the catch-up bar and the unreachable banner track the
        // subscription lifecycle (Tip/Confirmed/CaughtUp/Disconnected).
        _frigateState.applyLifecycle(event);
        await _handler.handleEvent(event);
        await _frigateState.refresh();
        onEventProcessed?.call();
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
      // whenever the frigate path runs. The frigate URL was required above,
      // so the monitor's endpoint resolution cannot come up empty here —
      // and if it ever did, monitor.start() THROWS (B8.2 hard gate: never
      // run without the electrum path) and the failed-start cleanup below
      // tears the subscription back down.
      await _monitor.start();
      return true;
    } catch (e) {
      Logger().e('frigate subscription failed to start: $e');
      // B4.4: a failed start means the backend (or its connection) is
      // unreachable — the banner shows and clears on the next successful
      // interaction.
      _frigateState.markUnreachable();
      await _events?.cancel();
      _events = null;
      // The host owns the lease. Releasing it here would let the other
      // isolate start a second writer while this host is still up.
      rethrow;
    } finally {
      _starting = false;
    }
  }

  /// End the subscription and the confirmation monitor. Does not release
  /// the writer lease.
  Future<void> stopSubscription() async {
    await _events?.cancel();
    _events = null;
    await _monitor.stop();
    await frigate_api.stopFrigateSubscription();
  }

  /// [stopSubscription], then release the writer lease. Callers that are
  /// not the sync host (tests, a direct teardown) use this. The host calls
  /// [stopSubscription] and releases the lease itself when it stops.
  Future<void> stop() async {
    await stopSubscription();
    await writerLease?.release();
  }
}
