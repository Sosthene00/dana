import 'package:danawallet/repositories/frigate_candidates_repository.dart';
import 'package:flutter/foundation.dart';

/// UI state for the frigate unconfirmed balance line (B4.1/B4.2).
///
/// [pendingBalanceSat] is the sum of the pending frigate candidates. It is
/// NULL when there are no pending candidates — the line is ABSENT, not zero
/// (B4.1). The unconfirmed balance is informational only: it never enters
/// the spendable balance (which is derived from `owned_outputs` alone) and
/// never funds a send (B3.2/B4.2/B6.1).
class FrigateState extends ChangeNotifier {
  final FrigateCandidatesRepository _candidatesRepository;

  /// Sum of pending candidates in satoshis, or null when there are none.
  int? pendingBalanceSat;

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
}
