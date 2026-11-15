import 'package:bitcoin_ui/bitcoin_ui.dart';
import 'package:danawallet/global_functions.dart';
import 'package:danawallet/screens/settings/widgets/info_text_container.dart';
import 'package:danawallet/services/backup_service.dart';
import 'package:danawallet/states/wallet_state.dart';
import 'package:danawallet/utils/backup_password_policy.dart';
import 'package:danawallet/widgets/buttons/footer/footer_button.dart';
import 'package:danawallet/widgets/skeletons/screen_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// §7.1 Backup (export) flow.
///
/// Always encrypted — there is no plaintext export option in v1 (D3, §7.1
/// step 1). Steps: help text -> password step (enter per §6.1 or generate a
/// 6-word passphrase per §6.2, shown once with a store-it-safely warning and
/// never persisted) -> encrypt (fresh salt, fresh nonce, one-shot AEAD) ->
/// save via the platform file picker under a user-chosen filename -> mark
/// backup status with the current date (§7.3 deletion-gate feed).
class ExportBackupScreen extends StatefulWidget {
  const ExportBackupScreen({super.key});

  @override
  State<ExportBackupScreen> createState() => _ExportBackupScreenState();
}

class _ExportBackupScreenState extends State<ExportBackupScreen> {
  final _backupService = BackupService();
  final _passwordController = TextEditingController();
  final _passwordFocusNode = FocusNode();

  bool _obscurePassword = true;
  bool _reducedKdf = false;
  bool _exporting = false;

  /// §6.2: the generated passphrase lives only in this field (displayed
  /// once) and is dropped when the screen is disposed — never persisted.
  String? _generatedPassphrase;
  bool _confirmedGeneratedStored = false;

  @override
  void initState() {
    super.initState();
    _loadDeviceClass();
  }

  Future<void> _loadDeviceClass() async {
    final reduced = await _backupService.shouldUseReducedKdf();
    if (mounted && reduced != _reducedKdf) {
      setState(() => _reducedKdf = reduced);
    }
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  String? get _passwordViolation {
    if (_generatedPassphrase != null) {
      // The generated option satisfies §6.1 by construction (§6.2).
      return null;
    }
    return BackupPasswordPolicy.violationOf(_passwordController.text);
  }

  bool get _canExport =>
      !_exporting &&
      (_generatedPassphrase != null
          ? _confirmedGeneratedStored
          : _passwordViolation == null && _passwordController.text.isNotEmpty);

  void _generatePassphrase() {
    setState(() {
      _generatedPassphrase = _backupService.generatePassphrase();
      _confirmedGeneratedStored = false;
      _passwordController.clear();
      _obscurePassword = true;
    });
  }

  void _useOwnPassword() {
    setState(() {
      _generatedPassphrase = null;
      _confirmedGeneratedStored = false;
    });
    _passwordFocusNode.requestFocus();
  }

  Future<void> _export() async {
    final password = _generatedPassphrase ?? _passwordController.text;
    if (password.isEmpty || !_canExport) return;

    setState(() => _exporting = true);
    try {
      final wallet = await Provider.of<WalletState>(context, listen: false)
          .getWalletFromSecureStorage();

      final destination = await _backupService.exportBackup(
        wallet: wallet,
        password: password,
        kdfProfile: _reducedKdf
            ? BackupKdfProfile.reduced
            : BackupKdfProfile.standard,
      );

      if (!mounted) return;
      if (destination == null) {
        // User cancelled the picker; nothing written, nothing recorded.
        return;
      }

      // §7.1 step 5: status date recorded by the service. The UI SHOULD
      // encourage a verify-by-restore; the actual verification is a restore
      // (§7.2) the user runs separately.
      await showVerificationEncouragement(context);
      if (mounted) {
        displayNotification('Encrypted backup saved');
        goBack(context);
      }
    } catch (e) {
      if (mounted) {
        displayError('Backup export failed', e);
      }
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  Future<void> showVerificationEncouragement(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Backup saved'),
        content: const Text(
          'Keep the file and its password somewhere safe — the password '
          'cannot be recovered. For full peace of mind, verify the backup '
          'by restoring it on this device after deleting the wallet, or on '
          'another device.',
        ),
        actions: [
          TextButton(
            child: const Text('OK'),
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
      ),
    );
  }

  static const _helpText =
      'This exports your entire wallet — keys, scan state, labels and '
      'transaction history — into one encrypted file. The file is always '
      'encrypted with your password; there is no unencrypted export. '
      'Anyone with the file can try to guess the password offline, so use '
      'the generated passphrase or a long password you will not forget: '
      'if you lose the password, the file cannot be opened. The '
      'destination you pick (cloud drive, USB stick, …) is treated as '
      'public from the moment the file is written.';

  static const _reducedKdfText =
      'Reduced KDF settings for this device: this device cannot afford the '
      'standard encryption memory cost, so the backup uses a lower-memory '
      'profile (32 MiB, 4 passes instead of 64 MiB, 3 passes). The file '
      'records which settings were used and restores normally anywhere.';

  @override
  Widget build(BuildContext context) {
    return ScreenSkeleton(
      showBackButton: true,
      title: 'Export encrypted backup',
      body: ListView(
        children: [
          const InfoTextContainer(infoText: _helpText),
          const SizedBox(height: 16),
          if (_reducedKdf) ...[
            const _ReducedKdfBanner(text: _reducedKdfText),
            const SizedBox(height: 16),
          ],
          _buildPasswordSection(),
          const SizedBox(height: 24),
        ],
      ),
      footer: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: FooterButton(
          title: _exporting ? 'Encrypting…' : 'Save backup file…',
          onPressed: _canExport ? _export : null,
          isLoading: _exporting,
          enabled: _canExport,
        ),
      ),
    );
  }

  Widget _buildPasswordSection() {
    if (_generatedPassphrase != null) {
      return _buildGeneratedPassphraseView(_generatedPassphrase!);
    }
    return _buildOwnPasswordView();
  }

  Widget _buildOwnPasswordView() {
    final violation = _passwordController.text.isEmpty
        ? null
        : _passwordViolation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Choose a password',
            style: BitcoinTextStyle.title4(Bitcoin.black)),
        const SizedBox(height: 4),
        const Text(
          'At least 16 characters, with a lowercase letter and a digit. '
          'This password is the only way to open the backup file.',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          focusNode: _passwordFocusNode,
          obscureText: _obscurePassword,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: 'Backup password',
            errorText: violation,
            suffixIcon: IconButton(
              icon: Icon(_obscurePassword
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Generate a strong passphrase'),
                onPressed: _generatePassphrase,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildGeneratedPassphraseView(String passphrase) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your generated passphrase',
            style: BitcoinTextStyle.title4(Bitcoin.black)),
        const SizedBox(height: 4),
        const Text(
          'Write these six words down and keep them safe. They are shown '
          'only this once and cannot be recovered or viewed again.',
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          decoration: ShapeDecoration(
            color: Bitcoin.neutral2,
            shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(10))),
          ),
          child: Padding(
            padding: const EdgeInsets.all(15),
            child: SelectableText(
              passphrase,
              style: const TextStyle(fontSize: 18, letterSpacing: 1),
            ),
          ),
        ),
        const SizedBox(height: 12),
        CheckboxListTile(
          value: _confirmedGeneratedStored,
          onChanged: (checked) =>
              setState(() => _confirmedGeneratedStored = checked ?? false),
          title: const Text('I have stored these words safely'),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
        ),
        TextButton(
          onPressed: _useOwnPassword,
          child: const Text('Type my own password instead'),
        ),
      ],
    );
  }
}

/// §6.3.2: the device-class fallback MUST be visible in the export UI,
/// never silent.
class _ReducedKdfBanner extends StatelessWidget {
  final String text;

  const _ReducedKdfBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: ShapeDecoration(
        color: Bitcoin.neutral3,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10))),
      ),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.speed, size: 22),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }
}
