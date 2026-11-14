import 'dart:async';

import 'package:danawallet/repositories/frigate_disclosure_repository.dart';
import 'package:danawallet/services/frigate_subscription_controller.dart';
import 'package:danawallet/states/frigate_state.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// B5.3: the BLOCKING one-time public warning.
///
/// Watches [FrigateState.publicWarningPending] — the flag is set by the
/// frigate subscription controller when the warning gate demands the
/// warning (first public sync on a REACHABLE public URL, B5.4), in either
/// the app isolate or the foreground-service isolate (which ships the flag
/// to the main isolate through its lifecycle snapshot, B2.2).
///
/// While the warning is pending, the first public sync is blocked: the
/// dialog is not dismissible and only an explicit acknowledgement
/// (the two-harms warning below, plus the "create a new wallet"
/// mitigation line) lets the subscription proceed. The ack is persisted
/// per wallet (B5.4 — it never fires again) and the URL enters the
/// permanent disclosure record via the controller on the next start.
class FrigatePublicWarningWatcher extends StatefulWidget {
  final Widget child;

  const FrigatePublicWarningWatcher({super.key, required this.child});

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
    await showDialog(
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
            // B5.3: "Go back" does NOT acknowledge — the first public sync
            // stays blocked and the warning re-shows on the next gate
            // evaluation.
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Go back'),
            ),
            TextButton(
              onPressed: () async {
                // B5.4: the per-wallet ack — the warning never fires
                // again after this lands.
                await FrigateDisclosureRepository.instance.ackPublicWarning();
                if (!dialogContext.mounted) return;
                dialogContext
                    .read<FrigateState>()
                    .setPublicWarningPending(false);
                // Restart the gated frigate leg with the ack in place
                // (the service isolate re-evaluates on its own retry
                // loop; this covers the app-isolate fallback writer).
                try {
                  final controller =
                      dialogContext.read<FrigateSubscriptionController>();
                  unawaited(controller.start());
                } catch (_) {}
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text('I understand — sync publicly'),
            ),
          ],
        ),
      ),
    );
    if (mounted) {
      setState(() => _dialogOpen = false);
    } else {
      _dialogOpen = false;
    }
  }
}
