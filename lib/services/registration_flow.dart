// WT-03 (t_11619ec3) — D11 UI contract: named registration states surfaced
// from the WT-02 flow in [DanaAddressService.registerUser].
//
// D11 ruling: named states `challenging` / `confirming` / `retrying
// (countdown)` are visible to the user; any background re-challenge visibly
// resets the confirmation so an approval always matches a challenge the user
// saw fetched; retry backoffs surface as the `retrying` state with a
// countdown rather than silent log lines; exhaustion lands on a terminal
// error screen naming the error category with a single explicit
// user-initiated restart that resets retry budgets; no automatic retry after
// exhaustion. Persistence/resumption of an in-progress registration is out
// of scope per D11 (process death means the flow restarts).
import 'dart:async';

import 'package:danawallet/data/models/bip353_address.dart';
import 'package:danawallet/data/models/name_server_challenge_response.dart';
import 'package:danawallet/repositories/name_server_repository.dart';
import 'package:danawallet/services/dana_address_service.dart';
import 'package:flutter/foundation.dart';

/// Thrown by the flow when the UI withheld its approval for a challenge
/// ([RegistrationFlow.onChallengeReceived] returned false). Not an error:
/// the controller folds it back into [RegistrationIdle].
class RegistrationAbortedException implements Exception {
  const RegistrationAbortedException();

  @override
  String toString() => 'Registration aborted before signing';
}

/// Observation + control surface the flow calls into. Implemented by
/// [RegistrationController]; the service only awaits it and never knows
/// about widgets.
abstract class RegistrationFlow {
  /// A /challenge request is about to go out (first fetch and every
  /// refresh). D11 named state: `challenging`.
  Future<void> onChallenging();

  /// A challenge was fetched and is shown to the user. The returned bool is
  /// the user's approval to sign + register THIS exact challenge; false
  /// aborts the flow. D11: an approval always matches a challenge the user
  /// saw fetched.
  Future<bool> onChallengeReceived({
    required NameServerChallengeResponse challenge,
    required int remainingSeconds,
  });

  /// The approved challenge is being signed and registered. D11 named
  /// state: `confirming`.
  Future<void> onConfirming();

  /// A retry decision was made. [countdownSeconds] is the visible backoff
  /// countdown (0 = immediate retry, e.g. re-sign / fresh challenge).
  /// D11 named state: `retrying (countdown)`.
  Future<void> onRetrying({
    required NameServerErrorCode? code,
    required int countdownSeconds,
    required int attempt,
    required int maxAttempts,
  });

  /// A background re-challenge (proactive TTL refresh or nonce-class
  /// refresh) is about to discard the shown challenge: the confirmation is
  /// visibly reset so no stale approval can survive it (D11).
  Future<void> onConfirmationReset();
}

/// Terminal error categories named on the D11 terminal screen.
enum RegistrationErrorCategory {
  nameServerUnsupported('Name server unsupported'),
  usernameTaken('Username taken'),
  usernameInvalid('Invalid username'),
  signatureRejected('Signature rejected'),
  challengeExpired('Challenge expired'),
  rateLimited('Rate limited'),
  challengeFailed('Challenge failed'),
  unknown('Unknown error');

  const RegistrationErrorCategory(this.label);

  /// Human-readable category name shown on the terminal screen (D11).
  final String label;
}

/// Maps a terminal flow exception to its D11 category.
RegistrationErrorCategory categorizeRegistrationError(Object error) {
  if (error is ChallengeAuthUnavailableException) {
    return RegistrationErrorCategory.nameServerUnsupported;
  }
  if (error is RegisterRejectedException) {
    switch (error.code) {
      case NameServerErrorCode.usernameTaken:
        return RegistrationErrorCategory.usernameTaken;
      case NameServerErrorCode.usernameInvalid:
        return RegistrationErrorCategory.usernameInvalid;
      case NameServerErrorCode.signatureInvalid:
        return RegistrationErrorCategory.signatureRejected;
      case NameServerErrorCode.nonceExpired:
      case NameServerErrorCode.nonceMismatch:
      case NameServerErrorCode.nonceUnknown:
        return RegistrationErrorCategory.challengeExpired;
      case NameServerErrorCode.rateLimited:
        return RegistrationErrorCategory.rateLimited;
      case NameServerErrorCode.unknown:
      case null:
        return RegistrationErrorCategory.unknown;
    }
  }
  if (error is ChallengeRejectedException) {
    return error.code == NameServerErrorCode.rateLimited
        ? RegistrationErrorCategory.rateLimited
        : RegistrationErrorCategory.challengeFailed;
  }
  return RegistrationErrorCategory.unknown;
}

/// Sealed D11 UI states.
sealed class RegistrationUiState {
  const RegistrationUiState();
}

class RegistrationIdle extends RegistrationUiState {
  const RegistrationIdle();
}

/// D11 named state `challenging`: a /challenge request is in flight.
class RegistrationChallenging extends RegistrationUiState {
  const RegistrationChallenging();
}

/// A fetched challenge awaits the user's approval; [remainingSeconds] is the
/// receipt-relative TTL countdown displayed next to it (D6 display).
class RegistrationAwaitingConfirmation extends RegistrationUiState {
  const RegistrationAwaitingConfirmation({
    required this.message,
    required this.remainingSeconds,
  });

  final String message;
  final int remainingSeconds;
}

/// D11 named state `confirming`: the approved challenge is being signed and
/// registered.
class RegistrationConfirming extends RegistrationUiState {
  const RegistrationConfirming();
}

/// D11 named state `retrying (countdown)`: a retry decision is visible with
/// its backoff countdown instead of a silent log line.
class RegistrationRetrying extends RegistrationUiState {
  const RegistrationRetrying({
    required this.code,
    required this.countdownSeconds,
    required this.attempt,
    required this.maxAttempts,
  });

  final NameServerErrorCode? code;
  final int countdownSeconds;
  final int attempt;
  final int maxAttempts;
}

/// A background re-challenge discarded the shown challenge: the confirmation
/// was visibly reset (D11) and a fresh challenge is being fetched.
class RegistrationConfirmationReset extends RegistrationUiState {
  const RegistrationConfirmationReset();
}

/// Terminal D11 error screen state: names the error category. Retry budgets
/// are NOT reset by this state; only an explicit user restart does that.
class RegistrationTerminal extends RegistrationUiState {
  const RegistrationTerminal({
    required this.category,
    required this.detail,
  });

  final RegistrationErrorCategory category;
  final String detail;
}

class RegistrationSuccess extends RegistrationUiState {
  const RegistrationSuccess(this.address);

  final Bip353Address address;
}

/// ChangeNotifier driving the D11 registration UI.
///
/// [runner] performs the actual registration (the service's `registerUser`
/// with the wallet signer) and receives this controller as its
/// [RegistrationFlow]. Retry budgets live inside `registerUser`, so every
/// [start]/[restart] invocation runs with fresh budgets — restart is the
/// only path back into the flow after a terminal state, and it is strictly
/// user-initiated: no automatic retry ever follows exhaustion (D11).
class RegistrationController extends ChangeNotifier {
  RegistrationController({required this.runner});

  final Future<Bip353Address> Function(RegistrationFlow flow) runner;

  RegistrationUiState _state = const RegistrationIdle();
  RegistrationUiState get state => _state;

  Completer<bool>? _confirmation;
  Timer? _ticker;
  bool _starting = false;
  int _generation = 0;

  bool get isActive => state is! RegistrationIdle && state is! RegistrationTerminal;

  /// Starts one registration run with fresh retry budgets.
  Future<void> start() async {
    if (_starting || isActive) {
      return;
    }
    _starting = true;
    final generation = ++_generation;
    try {
      final address = await runner(_Session(this, generation));
      if (_isCurrent(generation)) {
        _stopTicker();
        _setState(RegistrationSuccess(address));
      }
    } on RegistrationAbortedException {
      if (_isCurrent(generation)) {
        _stopTicker();
        _setState(const RegistrationIdle());
      }
    } catch (e) {
      if (_isCurrent(generation)) {
        _stopTicker();
        _setState(RegistrationTerminal(
          category: categorizeRegistrationError(e),
          detail: e.toString(),
        ));
      }
    } finally {
      _starting = false;
    }
  }

  /// The single user-initiated restart (D11): only reachable from the
  /// terminal state, drops nothing in flight, and re-enters the flow with
  /// fresh retry budgets (budgets are locals of each `registerUser` run).
  Future<void> restart() async {
    if (state is! RegistrationTerminal) {
      return;
    }
    _stopTicker();
    _setState(const RegistrationIdle());
    await start();
  }

  /// Approves the challenge currently shown for confirmation.
  void confirm() {
    if (state is RegistrationAwaitingConfirmation) {
      _confirmation?.complete(true);
    }
  }

  /// Withholds approval: the flow aborts before signing anything.
  void cancelConfirmation() {
    if (state is RegistrationAwaitingConfirmation) {
      _confirmation?.complete(false);
    }
  }

  /// Returns to idle from a non-terminal active state (abandons the run).
  /// Bumps the generation so the abandoned run is fully ignored from here
  /// on; its flow session withholds approval and the service aborts before
  /// signing.
  void abandon() {
    if (state is RegistrationTerminal || state is RegistrationIdle) {
      return;
    }
    cancelConfirmation();
    _stopTicker();
    _generation++;
    _setState(const RegistrationIdle());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    if (!(_confirmation?.isCompleted ?? true)) {
      _confirmation!.complete(false);
    }
    super.dispose();
  }

  bool _isCurrent(int generation) => generation == _generation;

  void _setState(RegistrationUiState next) {
    _state = next;
    notifyListeners();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final current = _state;
      if (current is RegistrationAwaitingConfirmation &&
          current.remainingSeconds > 0) {
        _state = RegistrationAwaitingConfirmation(
          message: current.message,
          remainingSeconds: current.remainingSeconds - 1,
        );
        notifyListeners();
      } else if (current is RegistrationRetrying &&
          current.countdownSeconds > 0) {
        _state = RegistrationRetrying(
          code: current.code,
          countdownSeconds: current.countdownSeconds - 1,
          attempt: current.attempt,
          maxAttempts: current.maxAttempts,
        );
        notifyListeners();
      }
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  Future<void> _onChallenging() async {
    _setState(const RegistrationChallenging());
  }

  Future<bool> _onChallengeReceived({
    required NameServerChallengeResponse challenge,
    required int remainingSeconds,
  }) async {
    _setState(RegistrationAwaitingConfirmation(
      message: challenge.message,
      remainingSeconds: remainingSeconds,
    ));
    final completer = Completer<bool>();
    _confirmation = completer;
    _startTicker();
    final approved = await completer.future;
    _stopTicker();
    _confirmation = null;
    return approved;
  }

  Future<void> _onConfirming() async {
    _setState(const RegistrationConfirming());
  }

  Future<void> _onRetrying({
    required NameServerErrorCode? code,
    required int countdownSeconds,
    required int attempt,
    required int maxAttempts,
  }) async {
    _setState(RegistrationRetrying(
      code: code,
      countdownSeconds: countdownSeconds,
      attempt: attempt,
      maxAttempts: maxAttempts,
    ));
    if (countdownSeconds > 0) {
      _startTicker();
    }
  }

  Future<void> _onConfirmationReset() async {
    _stopTicker();
    // A reset invalidates any approval still pending for the discarded
    // challenge (defensive: the service only resets after an approval, but
    // a stale approval must never survive a re-challenge).
    if (!(_confirmation?.isCompleted ?? true)) {
      _confirmation!.complete(false);
    }
    _setState(const RegistrationConfirmationReset());
  }
}

/// Per-run [RegistrationFlow] view of the controller: callbacks from a run
/// that is no longer current (superseded by restart/abandon) are dropped —
/// a stale run can never repaint the UI or resurrect a stale confirmation.
class _Session implements RegistrationFlow {
  _Session(this._owner, this._generation);

  final RegistrationController _owner;
  final int _generation;

  bool get _current => _owner._generation == _generation;

  @override
  Future<void> onChallenging() async {
    if (_current) {
      await _owner._onChallenging();
    }
  }

  @override
  Future<bool> onChallengeReceived({
    required NameServerChallengeResponse challenge,
    required int remainingSeconds,
  }) async {
    if (!_current) {
      // Superseded run: withhold approval so the stale flow aborts before
      // signing.
      return false;
    }
    return _owner._onChallengeReceived(
      challenge: challenge,
      remainingSeconds: remainingSeconds,
    );
  }

  @override
  Future<void> onConfirming() async {
    if (_current) {
      await _owner._onConfirming();
    }
  }

  @override
  Future<void> onRetrying({
    required NameServerErrorCode? code,
    required int countdownSeconds,
    required int attempt,
    required int maxAttempts,
  }) async {
    if (_current) {
      await _owner._onRetrying(
        code: code,
        countdownSeconds: countdownSeconds,
        attempt: attempt,
        maxAttempts: maxAttempts,
      );
    }
  }

  @override
  Future<void> onConfirmationReset() async {
    if (_current) {
      await _owner._onConfirmationReset();
    }
  }
}
