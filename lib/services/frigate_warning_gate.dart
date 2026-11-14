import 'package:danawallet/repositories/frigate_disclosure_repository.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/services/frigate_url_probe.dart';

/// What the warning gate decided the subscription start should do.
enum FrigateGateDecision {
  /// No gating applies — start the subscription normally.
  proceed,

  /// The URL is declared public, unacked, and UNREACHABLE: never start, and
  /// never fire the warning (B5.4 — an unreachable URL does not count).
  unreachable,

  /// The URL is declared public, unacked, and reachable: fire the blocking
  /// warning (exactly once, B5.4) and do NOT start the subscription until
  /// the user acknowledges (B5.3).
  warningRequired,

  /// The warning already fired this session and is still unacknowledged:
  /// keep holding the subscription, do not re-fire the dialog.
  warningHold,
}

/// B5.2/B5.3/B5.4 decision core for the one-time public warning.
///
/// Injected function hooks default to the real repositories and the B5.1
/// probe; the controller wires the decisions into the subscription start
/// path (both the foreground-service writer and the app-isolate fallback).
class FrigateWarningGate {
  final Future<String?> Function() getUrl;
  final Future<bool> Function() isPublic;
  final Future<bool> Function() isAcked;
  final Future<void> Function(String url) probe;
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
    Future<void> Function(String url)? probe,
    this.onWarningRequired,
  })  : getUrl = getUrl ?? SettingsRepository.instance.getFrigateUrl,
        isPublic = isPublic ?? SettingsRepository.instance.isFrigatePublic,
        isAcked = isAcked ??
            FrigateDisclosureRepository.instance.isPublicWarningAcked,
        probe = probe ?? probeFrigateUrl;

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

    // B5.4: it never fires again, for any URL — an acked wallet proceeds.
    if (await isAcked()) {
      _fired = false;
      return FrigateGateDecision.proceed;
    }

    // B5.4: probe BEFORE firing — an unreachable URL does not count (the
    // harm happens at first successful use, not first attempt). The probe
    // never subscribes, so it never burns the scan key (B5.1).
    try {
      await probe(url);
    } on FrigateProbeException {
      return FrigateGateDecision.unreachable;
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
