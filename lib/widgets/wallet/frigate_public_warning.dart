import 'dart:async';

import 'package:danawallet/repositories/frigate_disclosure_repository.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/services/backend_apply_result.dart';
import 'package:danawallet/services/sync_orchestrator.dart';
import 'package:danawallet/states/frigate_state.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

/// B5.3: the BLOCKING two-harms public-backend warning. The harm text and
/// the mitigation line are normative (B5.3); the dialog is not dismissible
/// and only an explicit acknowledgement lets a public save commit (R12) or
/// a held pre-ruling sync proceed.
///
/// Owner ruling R12 (2026-11-18): the warning gates the SAVE —
/// ChainBackendScreen shows it before a Frigate save commits; "No — go
/// back" (returns `false`) aborts the save with the settings untouched.
///
/// It also still surfaces for installs whose public unacked URL predates
/// the ruling: [FrigatePublicWarningWatcher] watches
/// [FrigateState.publicWarningPending] — the flag is set by the frigate
/// subscription controller when the warning gate demands the warning, in
/// either the app isolate or the foreground-service isolate (which ships
/// the flag to the main isolate through its lifecycle snapshot, B2.2) — and
/// shows the same dialog.
///
/// Returns true ONLY on the explicit acknowledgement
/// ("Yes — I understand, sync publicly"); "No — go back" returns false.
Future<bool> showFrigatePublicWarningDialog(BuildContext context) async {
  final acknowledged = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Sync through a public backend?'),
        content: const Text(
            'You are about to sync through a PUBLIC frigate backend. '
            'This harms your privacy:\n\n'
            'Historical: the scan key you share links your '
            'silent-payment outputs permanently — payments to your '
            'wallet can be tied together.\n\n'
            'Ongoing: the operator observes every future sync live, '
            'even after you rotate your keys.\n\n'
            'To keep this wallet private, use a private backend — or '
            'create a new wallet.'),
        actions: [
          // B5.3: "No" never acknowledges — the save aborts (R12) / the
          // first public sync stays blocked.
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('No — go back'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Yes — I understand, sync publicly'),
          ),
        ],
      ),
    ),
  );
  return acknowledged ?? false;
}

/// B5.3: shows the blocking warning whenever the subscription start path
/// reports a pending pre-ruling public unacked URL (B2.2 snapshot flag).
/// While the warning is pending, the first public sync is blocked; the ack
/// is persisted per wallet (B5.4 — it never fires again) and the URL enters
/// the permanent disclosure record at ack time (J2 migration path — new
/// saves record it in the screen at save time).
class FrigatePublicWarningWatcher extends StatefulWidget {
  final Widget child;

  /// Test seam: the post-ack apply command. Production reads
  /// [SyncOrchestrator] from the tree. Typed result (M-c): a
  /// not-delivered apply is surfaced, never silently dropped.
  final Future<BackendApplyResult> Function()? applyBackend;

  const FrigatePublicWarningWatcher(
      {super.key, required this.child, this.applyBackend});

  @override
  State<FrigatePublicWarningWatcher> createState() =>
      _FrigatePublicWarningWatcherState();
}

class _FrigatePublicWarningWatcherState
    extends State<FrigatePublicWarningWatcher> {
  bool _dialogOpen = false;

  @override
  Widget build(BuildContext context) {
    final frigateState = Provider.of<FrigateState>(context);
    if (frigateState.publicWarningPending && !_dialogOpen) {
      _dialogOpen = true;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => unawaited(_showWarningDialog()));
    }
    return widget.child;
  }

  Future<void> _showWarningDialog() async {
    if (!mounted) {
      _dialogOpen = false;
      return;
    }
    final acknowledged = await showFrigatePublicWarningDialog(context);
    if (mounted) {
      setState(() => _dialogOpen = false);
    } else {
      _dialogOpen = false;
    }
    if (!acknowledged) {
      // "No": the first public sync stays blocked and the warning re-shows
      // on the next gate evaluation (B5.3).
      return;
    }

    // B5.4: the per-wallet ack — the warning never fires again after this
    // lands.
    await FrigateDisclosureRepository.instance.ackPublicWarning();
    // Ruling R12/J2: at the moment of consent the pending URL enters the
    // permanent disclosure record (pre-ruling migration path; new saves
    // record it in the screen at save time).
    final url = await SettingsRepository.instance.getFrigateUrl();
    if (url != null && url.isNotEmpty) {
      await FrigateDisclosureRepository.instance.recordIfNew(url);
    }
    if (!mounted) return;
    context.read<FrigateState>().setPublicWarningPending(false);
    // The host that holds the lease re-reads settings and starts the
    // subscription. This isolate does not start a second scanner.
    // M-c: a failed apply after the ack must not silently pretend
    // success — the divergence surfaces on the app's existing SnackBar
    // error surface.
    try {
      final result = await _applyBackend();
      if (!result.isDelivered) {
        Logger().w('applyBackend after the public-warning ack was not '
            'delivered: ${result.name}');
        _showDivergence();
      }
    } catch (e) {
      Logger().w('applyBackend after the public-warning ack failed: $e');
      _showDivergence();
    }
  }

  Future<BackendApplyResult> _applyBackend() async {
    final injected = widget.applyBackend;
    if (injected != null) return injected();
    return context.read<SyncOrchestrator>().applyBackend();
  }

  void _showDivergence() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text(backendApplyDivergenceMessage),
    ));
  }
}
