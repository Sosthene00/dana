import 'package:danawallet/repositories/frigate_disclosure_repository.dart';
import 'package:danawallet/repositories/settings_repository.dart';

/// What the warning gate decided the subscription start should do.
///
/// Owner ruling R12 (2026-11-18): the public warning is a SAVE-TIME gate —
/// the declaration screen probes (B5.1), warns, and only commits the save on
/// acknowledgement. An unreachable public URL therefore can never exist in
/// settings anymore, and the former `unreachable` decision (which probed at
/// subscription start) is removed (J3).
enum FrigateGateDecision {
  /// No gating applies — start the subscription normally.
  proceed,

  /// The URL is declared public and unacked: fire the blocking warning
  /// (exactly once, B5.4) and do NOT start the subscription until the user
  /// acknowledges (B5.3). Only reachable for state saved BEFORE ruling R12 —
  /// a post-ruling save acks before it persists (B5.2/B5.3).
  warningRequired,

  /// The warning already fired in this controller instance and is still
  /// unacknowledged: keep holding the subscription, do not re-fire the
  /// dialog.
  warningHold,
}

/// B5.2/B5.3/B5.4 decision core — the SUBSCRIPTION-START leg of the
/// one-time public warning.
///
/// Since ruling R12 the warning normally fires in [ChainBackendScreen] at
/// SAVE time (before the save commits). This gate remains only so installs
/// whose public unacked URL predates the ruling still get the warning before
/// their first public sync — in both the app isolate and the
/// foreground-service path (B2.2 snapshot flag). It never probes: the save
/// path is probe-gated (B5.1), so reachability is not this gate's job
/// anymore.
///
/// Injected hooks default to the real repositories; the controller wires the
/// decisions into the subscription start path.
class FrigateWarningGate {
  final Future<String?> Function() getUrl;
  final Future<bool> Function() isPublic;
  final Future<bool> Function() isAcked;
  final void Function()? onWarningRequired;

  /// The warning fired at most once per ack-cycle in this controller
  /// instance — the service's start-retry loop re-evaluates every few
  /// seconds and must not re-open the dialog (the persistent per-wallet
  /// once-only guarantee itself lives in the acked flag, B5.4).
  bool _fired = false;

  FrigateWarningGate({
    Future<String?> Function()? getUrl,
    Future<bool> Function()? isPublic,
    Future<bool> Function()? isAcked,
    this.onWarningRequired,
  })  : getUrl = getUrl ?? SettingsRepository.instance.getFrigateUrl,
        isPublic = isPublic ?? SettingsRepository.instance.isFrigatePublic,
        isAcked = isAcked ??
            FrigateDisclosureRepository.instance.isPublicWarningAcked;

  Future<FrigateGateDecision> evaluate() async {
    final url = await getUrl();
    if (url == null || url.isEmpty) {
      return FrigateGateDecision.proceed;
    }

    // B5.2: the default declaration is private — public is always a
    // deliberate user act. Private syncs are never gated.
    if (!await isPublic()) {
      return FrigateGateDecision.proceed;
    }

    // B5.4 (J1): it never fires again, for any URL — an acked wallet
    // proceeds.
    if (await isAcked()) {
      _fired = false;
      return FrigateGateDecision.proceed;
    }

    if (!_fired) {
      _fired = true;
      onWarningRequired?.call();
      return FrigateGateDecision.warningRequired;
    }
    // Still unacked after the dialog fired — keep the sync blocked (B5.3)
    // without re-firing the dialog.
    return FrigateGateDecision.warningHold;
  }
}
