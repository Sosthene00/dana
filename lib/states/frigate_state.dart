import 'package:danawallet/generated/rust/api/structs/frigate_event.dart';
import 'package:danawallet/repositories/frigate_candidates_repository.dart';
import 'package:flutter/foundation.dart';

/// UI state for the frigate unconfirmed balance line (B4.1/B4.2), the
/// subscription catch-up progress bar (B4.3) and the unreachable-backend
/// banner (B4.4).
///
/// [pendingBalanceSat] is the sum of the pending frigate candidates. It is
/// NULL when there are no pending candidates — the line is ABSENT, not zero
/// (B4.1). The unconfirmed balance is informational only: it never enters
/// the spendable balance (which is derived from `owned_outputs` alone) and
/// never funds a send (B3.2/B4.2/B6.1).
///
/// The catch-up bar (B4.3) tracks subscription catch-up only: it is
/// indeterminate until the scanner reports progress (the scanner-reported
/// `Confirmed` block height against the latest `Tip` height), hidden at
/// `CaughtUp`, never interpolated, and mempool events never touch it.
///
/// The banner (B4.4) shows while the frigate backend is unreachable and
/// clears on the next successful interaction (the first live event of the
/// re-established subscription). No crash, no data loss, no silent
/// fallback; errors stay human-readable.
class FrigateState extends ChangeNotifier {
  final FrigateCandidatesRepository _candidatesRepository;

  /// Sum of pending candidates in satoshis, or null when there are none.
  int? pendingBalanceSat;

  /// B4.3: whether the catch-up progress bar is currently shown.
  bool catchUpBarVisible = false;

  /// B4.3: determinate progress in [0, 1], or null for indeterminate.
  /// Derived ONLY from scanner-reported heights — never interpolated.
  double? catchUpProgress;

  /// Latest scanner-reported tip height (the determinate denominator).
  int? _tipHeight;

  /// B4.4: whether the frigate backend is currently unreachable.
  bool backendUnreachable = false;

  FrigateState({FrigateCandidatesRepository? candidatesRepository})
      : _candidatesRepository =
            candidatesRepository ?? FrigateCandidatesRepository.instance;

  /// Re-read the pending candidate set from the registry and notify listeners
  /// when the displayed value changed.
  Future<void> refresh() async {
    final pending = await _candidatesRepository.getPendingCandidates();
    final newBalance = pending.isEmpty
        ? null
        : pending.fold<int>(0, (sum, candidate) => sum + candidate.amountSat);
    if (newBalance != pendingBalanceSat) {
      pendingBalanceSat = newBalance;
      notifyListeners();
    }
  }

  /// B4.3/B4.4: route a subscription event through the catch-up bar and the
  /// reachability banner. Safe to call for every event; `Unconfirmed` and
  /// `Spent` are deliberately no-ops for the bar (B4.3: mempool events never
  /// touch it).
  void applyLifecycle(FrigateEventDto event) {
    switch (event) {
      case FrigateEventDto_Tip(:final height):
        // A live event from the backend — the unreachable banner clears on
        // this successful interaction (B4.4).
        _tipHeight = height;
        _setBar(visible: true, progress: catchUpProgress);
        if (backendUnreachable) {
          backendUnreachable = false;
          notifyListeners();
        }
      case FrigateEventDto_Confirmed(:final blkheight):
        final tip = _tipHeight;
        if (tip != null && tip > 0 && blkheight <= tip) {
          // Determinate from scanner-reported heights only (B4.3): the
          // historical leg's confirmed block against the reported tip.
          _setBar(visible: true, progress: blkheight / tip);
        }
      case FrigateEventDto_CaughtUp():
        // Catch-up finished — the bar is hidden, and the value is reset so
        // the next history replay starts fresh (never stale/interpolated).
        _tipHeight = null;
        _setBar(visible: false, progress: null);
      case FrigateEventDto_Disconnected():
        backendUnreachable = true;
        notifyListeners();
      case FrigateEventDto_Unconfirmed():
      case FrigateEventDto_Spent():
        break; // mempool events never touch the bar (B4.3)
    }
  }

  /// B4.4: the backend could not be reached at all (failed connect/start) —
  /// same banner as a mid-subscription disconnect.
  void markUnreachable() {
    if (!backendUnreachable) {
      backendUnreachable = true;
      notifyListeners();
    }
  }

  /// Snapshot of the lifecycle-derived UI state, shipped from the foreground
  /// service isolate to the main isolate with the refresh ping (B2.2): the
  /// subscription lives in the service, the banner/bar live in the app.
  Map<String, Object?> snapshot() => {
        'frigateBarVisible': catchUpBarVisible,
        'frigateBarProgress': catchUpProgress,
        'frigateUnreachable': backendUnreachable,
      };

  /// Apply a snapshot produced by [snapshot] in another isolate.
  void applySnapshot(Map<String, Object?> data) {
    final visible = data['frigateBarVisible'];
    final progress = data['frigateBarProgress'];
    final unreachable = data['frigateUnreachable'];
    var changed = false;
    if (visible is bool && visible != catchUpBarVisible) {
      catchUpBarVisible = visible;
      changed = true;
    }
    if (progress is double? && progress != catchUpProgress) {
      catchUpProgress = progress;
      changed = true;
    }
    if (unreachable is bool && unreachable != backendUnreachable) {
      backendUnreachable = unreachable;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void _setBar({required bool visible, required double? progress}) {
    if (catchUpBarVisible != visible || catchUpProgress != progress) {
      catchUpBarVisible = visible;
      catchUpProgress = progress;
      notifyListeners();
    }
  }
}
