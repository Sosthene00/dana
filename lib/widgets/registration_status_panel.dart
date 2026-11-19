// WT-03 (t_11619ec3) — D11 UI contract: renders the named registration
// states from [RegistrationController]. Every state the flow reports is
// visible to the user: `challenging`, the challenge confirmation (with the
// receipt-relative TTL countdown), `confirming`, `retrying` with its
// backoff countdown, the confirmation reset after a background re-challenge,
// and the terminal error screen naming the error category with a single
// user-initiated restart that resets retry budgets. No automatic retry ever
// follows exhaustion (D11).
import 'package:danawallet/services/registration_flow.dart';
import 'package:flutter/material.dart';

class RegistrationStatusPanel extends StatelessWidget {
  const RegistrationStatusPanel({super.key, required this.controller});

  final RegistrationController controller;

  static const Key challengingKey = Key('registration_state_challenging');
  static const Key awaitingConfirmationKey =
      Key('registration_state_awaiting_confirmation');
  static const Key confirmingKey = Key('registration_state_confirming');
  static const Key retryingKey = Key('registration_state_retrying');
  static const Key confirmationResetKey =
      Key('registration_state_confirmation_reset');
  static const Key terminalKey = Key('registration_state_terminal');

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.state;
        switch (state) {
          case RegistrationIdle():
          case RegistrationSuccess():
            return const SizedBox.shrink();
          case RegistrationChallenging():
            return const _StatusRow(
              key: challengingKey,
              label: 'Fetching registration challenge…',
            );
          case RegistrationAwaitingConfirmation():
            return _ConfirmationPanel(
              key: awaitingConfirmationKey,
              remainingSeconds: state.remainingSeconds,
              onConfirm: controller.confirm,
              onCancel: controller.cancelConfirmation,
            );
          case RegistrationConfirming():
            return const _StatusRow(
              key: confirmingKey,
              label: 'Signing and confirming registration…',
            );
          case RegistrationRetrying():
            return _RetryingPanel(
              key: retryingKey,
              state: state,
            );
          case RegistrationConfirmationReset():
            return const _StatusRow(
              key: confirmationResetKey,
              label:
                  'Confirmation reset — fetching a fresh challenge for you to '
                  'approve…',
            );
          case RegistrationTerminal():
            return _TerminalPanel(
              key: terminalKey,
              state: state,
              onRestart: controller.restart,
            );
        }
      },
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    super.key,
    required this.label,
  });

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

/// The confirmation the user approves against the exact challenge they saw
/// fetched, with the receipt-relative TTL countdown (D6 display, D11).
class _ConfirmationPanel extends StatelessWidget {
  const _ConfirmationPanel({
    super.key,
    required this.remainingSeconds,
    required this.onConfirm,
    required this.onCancel,
  });

  final int remainingSeconds;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  String get _countdown {
    final minutes = (remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (remainingSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Challenge received — valid for $_countdown',
            key: const Key('registration_confirmation_countdown'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          const Text(
            'Confirm to sign and register this challenge.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('registration_confirm_cancel'),
                  onPressed: onCancel,
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const Key('registration_confirm_approve'),
                  onPressed: onConfirm,
                  child: const Text('Confirm'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// D11 named state `retrying (countdown)`: the backoff is visible instead
/// of a silent log line.
class _RetryingPanel extends StatelessWidget {
  const _RetryingPanel({super.key, required this.state});

  final RegistrationRetrying state;

  String get _codeLabel {
    final code = state.code;
    return code == null ? 'retrying' : code.wire;
  }

  @override
  Widget build(BuildContext context) {
    final countdown = state.countdownSeconds > 0
        ? 'Retrying ($_codeLabel) in ${state.countdownSeconds}s'
        : 'Retrying ($_codeLabel)…';
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              key: const Key('registration_retrying_label'),
              '$countdown (attempt ${state.attempt}/${state.maxAttempts})',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

/// D11 terminal error screen: names the error category, carries the single
/// user-initiated restart, and never retries automatically.
class _TerminalPanel extends StatelessWidget {
  const _TerminalPanel({
    super.key,
    required this.state,
    required this.onRestart,
  });

  final RegistrationTerminal state;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Registration failed — ${state.category.label}',
            key: const Key('registration_terminal_category'),
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            state.detail,
            key: const Key('registration_terminal_detail'),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('registration_restart'),
            onPressed: onRestart,
            child: const Text('Start over'),
          ),
        ],
      ),
    );
  }
}
