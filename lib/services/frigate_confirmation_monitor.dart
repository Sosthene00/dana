import 'dart:async';
import 'dart:typed_data';

import 'package:danawallet/generated/rust/api/structs/amount.dart';
import 'package:danawallet/generated/rust/api/structs/owned_output.dart';
import 'package:danawallet/generated/rust/api/structs/outpoint.dart';
import 'package:danawallet/generated/rust/lib.dart';
import 'package:danawallet/repositories/frigate_candidates_repository.dart';
import 'package:danawallet/repositories/owned_outputs_repository.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/services/electrum_client.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

/// What the electrum history says about a candidate's tx (B3.3/B3.5, the
/// O2 rule): present confirmed -> graduate; present in the mempool -> stay
/// pending; present in NEITHER -> evicted, dropped.
enum CandidateObservation { confirmed, pending, evicted }

CandidateObservation classifyHistory(
    List<ElectrumHistoryEntry> history, String txid) {
  for (final entry in history) {
    if (entry.txHash == txid) {
      return entry.isMempool
          ? CandidateObservation.pending
          : CandidateObservation.confirmed;
    }
  }
  return CandidateObservation.evicted;
}

/// Phase-3 confirmation tracking (B3.6-B3.8, the B8.2 hard gate): the
/// electrum leg that turns mempool candidates into owned outputs.
///
/// On candidate creation the monitor subscribes the electrum scripthash of
/// that candidate's own output script (B3.7 — one subscription per
/// candidate; each derived output carries its own tweak, so per-candidate
/// is the granularity). Only `pending` candidates are subscribed; the live
/// subscription set is exactly the pending set, rebuilt from
/// `frigate_candidates` on every connect/reconnect (the table is the source
/// of truth, never in-memory state). Hard cap of 1024 concurrent
/// subscriptions; candidates beyond the cap are reconciled per block via
/// `get_history` until a slot frees (B3.7 fallback).
///
/// On a scripthash status change the monitor reads `get_history` and
/// applies the O2 rule ([classifyHistory]): a candidate whose tx is
/// confirmed graduates — the output is written into `owned_outputs` via the
/// normal confirmed-state path and the row is marked `confirmed` (B3.3,
/// electrum confirmation alone is the graduation condition; the scanner's
/// later `Confirmed` re-report is a dedupe input, never a second state
/// creation, B3.4). A candidate whose tx is in neither the confirmed
/// history nor the mempool is evicted → `dropped` (B3.5/B3.8). A new-block
/// notification additionally reconciles over-cap and stale (>10 min)
/// pending candidates (B3.8 timeout path).
class FrigateConfirmationMonitor {
  /// B3.7: hard cap on concurrent scripthash subscriptions.
  static const int maxSubscriptions = 1024;

  /// B3.8: pending candidates older than this are reconciled on every new
  /// electrum block (fallback for missed notifications).
  static const Duration staleReconcileAge = Duration(minutes: 10);

  final FrigateCandidatesRepository _candidatesRepository;
  final OwnedOutputsRepository _ownedOutputsRepository;

  /// test seam (and rig wiring): builds the electrum client for an endpoint.
  final Future<ElectrumClient> Function(String endpoint)? clientFactory;

  /// Called after the candidate registry changed (pending balance / line).
  final void Function()? onChanged;

  /// Called when a candidate graduated into `owned_outputs` (B3.3) — the
  /// wallet state refreshes its confirmed balance from the repository.
  final void Function()? onGraduated;

  /// Delay before a reconnect attempt after a disconnect (B3.7 rebuild).
  final Duration reconnectDelay;

  /// test seam: deterministic clock for the B3.8 staleness check.
  final int Function()? nowMillis;

  ElectrumClient? _client;
  StreamSubscription<ElectrumNotification>? _notificationSub;
  Timer? _reconnectTimer;
  bool _stopped = false;
  bool _connecting = false;
  String? _endpoint;

  /// Scripthashes currently subscribed on the live connection.
  final Set<String> _subscribed = {};

  /// Pending candidates beyond the subscription cap (B3.7): reconciled via
  /// get_history per block instead of held subscriptions.
  List<FrigateCandidate> _polled = const [];

  FrigateConfirmationMonitor({
    FrigateCandidatesRepository? candidatesRepository,
    OwnedOutputsRepository? ownedOutputsRepository,
    this.clientFactory,
    this.onChanged,
    this.onGraduated,
    this.reconnectDelay = const Duration(seconds: 5),
    this.nowMillis,
  })  : _candidatesRepository =
            candidatesRepository ?? FrigateCandidatesRepository.instance,
        _ownedOutputsRepository =
            ownedOutputsRepository ?? OwnedOutputsRepository.instance;

  /// Start the monitor against the configured electrum endpoint (B3.6):
  /// the wallet's configured electrum-compatible API URL (settings key
  /// `frigateelectrumurl`; a self-hosted electrs is the advanced override
  /// value). Without a configured endpoint the monitor does not start
  /// (logged) — candidates stay pending until it is configured; declaring
  /// the endpoint UI is R7 (same pattern as the frigate URL key).
  Future<void> start({String? endpoint}) async {
    _stopped = false;
    _endpoint =
        endpoint ?? await SettingsRepository.instance.getFrigateElectrumUrl();
    if (_endpoint == null || _endpoint!.isEmpty) {
      Logger()
          .i('frigate confirmation tracking: no electrum endpoint configured, '
              'phase 3 not started');
      return;
    }
    await _connectAndSubscribe();
  }

  Future<void> stop() async {
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _notificationSub?.cancel();
    _notificationSub = null;
    await _client?.close();
    _client = null;
    _subscribed.clear();
    _polled = const [];
  }

  /// Called on candidate creation (B3.7): subscribe any not-yet-subscribed
  /// pending candidate. Cheap no-op when nothing new is pending.
  Future<void> registerCandidates() async {
    if (_client == null || _stopped) return;
    await _syncSubscriptions();
  }

  Future<ElectrumClient> _buildClient() async {
    final factory = clientFactory;
    if (factory != null) return factory(_endpoint!);
    return ElectrumClient.connect(_endpoint!);
  }

  Future<void> _connectAndSubscribe() async {
    if (_stopped || _connecting || _endpoint == null) return;
    _connecting = true;
    try {
      final client = await _buildClient();
      if (_stopped) {
        await client.close();
        return;
      }
      _client = client;
      _subscribed.clear();
      unawaited(client.done.then((_) {
        if (identical(_client, client) && !_stopped) {
          Logger().w(
              'frigate confirmation electrum connection lost; reconnecting (B3.7 rebuild)');
          _onConnectionLost();
        }
      }));
      _notificationSub =
          client.notifications.listen(_onNotification, onError: (Object e) {
        Logger().w('frigate confirmation electrum stream error: $e');
      }, onDone: () {
        if (identical(_client, client) && !_stopped) _onConnectionLost();
      });
      // No headers subscription on blindbit-compat servers that lack it;
      // wrap in a guarded call so the core path still works.
      try {
        await client.subscribeHeaders();
      } catch (e) {
        Logger().i('electrum headers.subscribe unavailable: $e');
      }
      // Rebuild the subscription set FROM THE TABLE (B3.7).
      await _syncSubscriptions();
      Logger().i('frigate confirmation tracking connected to $_endpoint '
          '(${_subscribed.length} subscribed, ${_polled.length} polled)');
    } catch (e) {
      Logger().w('frigate confirmation electrum connect failed: $e');
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _onConnectionLost() {
    _client = null;
    _subscribed.clear();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_stopped || _reconnectTimer != null) return;
    _reconnectTimer = Timer(reconnectDelay, () {
      _reconnectTimer = null;
      if (!_stopped) _connectAndSubscribe();
    });
  }

  /// Rebuild the subscription set from the candidate table (B3.7): the live
  /// set is exactly the pending set (bounded by [maxSubscriptions]); the
  /// remainder is reconciled per block.
  Future<void> _syncSubscriptions() async {
    final client = _client;
    if (client == null || _stopped) return;
    try {
      final pending = await _candidatesRepository.getPendingCandidates();
      final bounded = pending.take(maxSubscriptions).toList();
      _polled = pending.skip(maxSubscriptions).toList();

      final targetScripts = <String>{};
      for (final candidate in bounded) {
        final scripthash =
            electrumScripthash(Uint8List.fromList(candidate.script));
        targetScripts.add(scripthash);
        if (_subscribed.contains(scripthash)) continue;
        await client.subscribeScripthash(scripthash);
        _subscribed.add(scripthash);
        // The subscribe response already reflects any history that exists —
        // reconcile immediately so a candidate created after its tx was
        // mined (or while the monitor was down) still graduates.
        await _reconcileScripthash(scripthash);
      }

      // Prune subscriptions whose candidates are no longer pending.
      for (final scripthash in _subscribed.toList()) {
        if (!targetScripts.contains(scripthash)) {
          await client.unsubscribeScripthash(scripthash);
          _subscribed.remove(scripthash);
        }
      }

      // Over-cap candidates are polled, not subscribed (B3.7 fallback).
      for (final candidate in _polled) {
        await _reconcileCandidate(candidate);
      }
    } on StateError {
      _onConnectionLost();
    } catch (e) {
      Logger().w('frigate confirmation subscription sync failed: $e');
    }
  }

  void _onNotification(ElectrumNotification notification) {
    switch (notification.method) {
      case 'blockchain.scripthash.subscribe':
        final scripthash = notification.params.first as String?;
        if (scripthash != null) {
          unawaited(_reconcileScripthash(scripthash));
        }
      case 'blockchain.headers.subscribe':
        unawaited(_reconcileStale());
      default:
        break;
    }
  }

  /// Reconcile every pending candidate mapped to [scripthash] (B3.8).
  Future<void> _reconcileScripthash(String scripthash) async {
    final client = _client;
    if (client == null || _stopped) return;
    try {
      final pending = await _candidatesRepository.getPendingCandidates();
      for (final candidate in pending) {
        if (electrumScripthash(Uint8List.fromList(candidate.script)) !=
            scripthash) {
          continue;
        }
        await _reconcileCandidate(candidate, client: client);
      }
    } on StateError {
      _onConnectionLost();
    } catch (e) {
      Logger().w('frigate confirmation reconcile failed for $scripthash: $e');
    }
  }

  /// B3.8 timeout path: on a new block, reconcile over-cap (polled) pending
  /// candidates and subscribed pendings older than [staleReconcileAge].
  Future<void> _reconcileStale() async {
    final client = _client;
    if (client == null || _stopped) return;
    try {
      final now = nowMillis?.call() ?? DateTime.now().millisecondsSinceEpoch;
      for (final candidate in _polled.toList()) {
        await _reconcileCandidate(candidate, client: client);
      }
      final pending = await _candidatesRepository.getPendingCandidates();
      for (final candidate in pending) {
        if (now - candidate.firstSeen < staleReconcileAge.inMilliseconds) {
          continue;
        }
        await _reconcileCandidate(candidate, client: client);
      }
    } catch (e) {
      Logger().w('frigate confirmation stale reconcile failed: $e');
    }
  }

  /// Apply the O2 decision for one candidate against the electrum history.
  Future<void> _reconcileCandidate(
    FrigateCandidate candidate, {
    ElectrumClient? client,
  }) async {
    final active = client ?? _client;
    if (active == null || _stopped) return;

    // Re-read the row: it may have graduated/dropped/been re-pended since
    // the triggering event (the registry mirrors current observation).
    final row = await _candidatesRepository.getCandidate(
        candidate.txid, candidate.vout);
    if (row == null || row.status != FrigateCandidateStatus.pending) return;

    final history = await active
        .getHistory(electrumScripthash(Uint8List.fromList(row.script)));
    switch (classifyHistory(history, row.txid)) {
      case CandidateObservation.confirmed:
        await _graduate(row);
      case CandidateObservation.pending:
        break; // still in the mempool — keep watching
      case CandidateObservation.evicted:
        await _drop(row);
    }
  }

  /// Graduation (B3.3): the output is derived and written into
  /// `owned_outputs` via the normal confirmed-state path (INSERT OR FAIL —
  /// a re-delivered graduation or the scanner's later Confirmed re-report
  /// dedupes on the outpoint, B3.4), and the candidate row is marked
  /// `confirmed`. Electrum confirmation alone is the graduation condition.
  Future<void> _graduate(FrigateCandidate candidate) async {
    await _ownedOutputsRepository.insertOutput(
      output: OwnedOutput(
        outpoint: OutPoint(txid: candidate.txid, vout: candidate.vout),
        tweak: U8Array32(candidate.tweak),
        amount: Amount(field0: BigInt.from(candidate.amountSat)),
        script: Uint8List.fromList(candidate.script),
      ),
    );
    await _candidatesRepository.markConfirmed(candidate.txid, candidate.vout);
    final scripthash = electrumScripthash(Uint8List.fromList(candidate.script));
    await _client?.unsubscribeScripthash(scripthash);
    _subscribed.remove(scripthash);
    Logger()
        .i('frigate graduation: ${candidate.txid}x${candidate.vout} confirmed '
            'via electrum notification (B3.3)');
    onChanged?.call();
    onGraduated?.call();
  }

  /// Eviction (B3.5/B3.8): the tx is in neither the confirmed history nor
  /// the mempool — mark the candidate `dropped` and unsubscribe. Dropped
  /// leaves no trace in balance; a re-delivered mempool entry re-pends the
  /// row via the phase-2 upsert path.
  Future<void> _drop(FrigateCandidate candidate) async {
    await _candidatesRepository.markDropped(candidate.txid, candidate.vout);
    final scripthash = electrumScripthash(Uint8List.fromList(candidate.script));
    await _client?.unsubscribeScripthash(scripthash);
    _subscribed.remove(scripthash);
    Logger().i(
        'frigate candidate dropped (evicted): ${candidate.txid}x${candidate.vout} '
        '(B3.5/B3.8)');
    onChanged?.call();
  }
}
