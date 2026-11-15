import 'dart:typed_data';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:bitcoin_ui/bitcoin_ui.dart';
import 'package:danawallet/data/enums/warning_type.dart';
import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/generated/rust/api/wallet/backup.dart';
import 'package:danawallet/global_functions.dart';
import 'package:danawallet/screens/onboarding/recovery/restore_flow.dart';
import 'package:danawallet/services/backup_restore_service.dart';
import 'package:danawallet/states/wallet_state.dart';
import 'package:danawallet/widgets/buttons/footer/footer_button.dart';
import 'package:danawallet/widgets/loading_widget.dart';
import 'package:danawallet/widgets/skeletons/screen_skeleton.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sizer/sizer.dart';

/// §7.2 Restore (import) flow: pick file -> password -> restored wallet.
///
/// Restore-promise copy asymmetry (§7.2, normative): this path restores
/// "everything, exactly as it was" — funds, addresses, scan state, history
/// and labels, no rescan for pre-backup state — while the seed/descriptor
/// paths restore "your bitcoin, not your history". The asymmetry stays
/// visible on the restore-method screen where both paths are offered, and
/// in this screen's help text.
///
/// Failure copy: every wrong-password / corrupt-file failure shows the one
/// generic message (§7.2 step 3, anti-oracle); the D1 gate (§7.2 step 2)
/// refusal is the only distinguishable outcome, and it directs the user to
/// delete the existing wallet first — no merge, no overwrite, no bypass.
class BackupFileRestoreScreen extends StatefulWidget {
  final Network network;

  const BackupFileRestoreScreen({super.key, required this.network});

  @override
  State<BackupFileRestoreScreen> createState() =>
      _BackupFileRestoreScreenState();
}

class _BackupFileRestoreScreenState extends State<BackupFileRestoreScreen> {
  final _backupRestoreService = BackupRestoreService();
  final _passwordController = TextEditingController();
  final _passwordFocusNode = FocusNode();

  String? _fileName;
  Uint8List? _fileBytes;
  bool _obscurePassword = true;
  bool _restoring = false;

  bool get _canRestore =>
      !_restoring && _fileBytes != null && _passwordController.text.isNotEmpty;

  @override
  void dispose() {
    _passwordController.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final files = await FilePicker.pickFiles(type: FileType.any);
    if (files.isEmpty) {
      // Picker cancelled; nothing chosen.
      return;
    }
    try {
      final file = files.first;
      final bytes = await file.readAsBytes();
      setState(() {
        _fileBytes = bytes;
        _fileName = file.name;
      });
    } catch (e) {
      // Reading the picked file failed; keep whatever was chosen before.
      displayError('Could not read file', e);
    }
  }

  Future<void> _restore() async {
    final bytes = _fileBytes;
    final password = _passwordController.text;
    if (bytes == null || password.isEmpty || !_canRestore) {
      return;
    }

    setState(() => _restoring = true);
    try {
      final restored =
          await _backupRestoreService.restoreFromBytes(bytes, password);
      if (!mounted) return;
      await Provider.of<WalletState>(context, listen: false)
          .restoreWalletFromBackup(restored);
      if (!mounted) return;
      await openWalletAfterRestore(context, widget.network);
    } on ApiRestoreFailure catch (e) {
      // D1 refusal (§7.2 step 2) or the generic failure (§7.2 step 3) —
      // the message comes from the single-copy mapper, never from the
      // internal cause.
      if (mounted) {
        setState(() => _restoring = false);
        await showWarningDialog(
            BackupRestoreService.messageFor(e), WarningType.warn);
      }
    } catch (e) {
      // Unexpected infrastructure failure (file picker, storage) — not a
      // fact about the file, but the same copy discipline applies.
      if (mounted) {
        setState(() => _restoring = false);
        displayError('Restore failed', e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_restoring) {
      return const LoadingWidget();
    }

    final subtitle = AutoSizeText(
      'Restore from a backup file. Everything comes back exactly as it was '
      'at the time of the backup: funds, addresses, scan state, history and '
      'labels. No rescan is needed for the pre-backup state.',
      style: BitcoinTextStyle.body3(Bitcoin.neutral7).copyWith(
        fontFamily: 'Inter',
      ),
      textAlign: TextAlign.center,
      maxLines: 6,
    );

    final body = SingleChildScrollView(
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.symmetric(
              vertical: Adaptive.h(3),
              horizontal: Adaptive.w(2),
            ),
            child: subtitle,
          ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: Icon(Icons.file_open_outlined, color: Bitcoin.blue),
            title: Text(
              _fileName ?? 'Choose backup file',
              style: BitcoinTextStyle.body3(Bitcoin.neutral8),
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Icon(Icons.chevron_right, color: Bitcoin.neutral6),
            onTap: _pickFile,
          ),
          Padding(
            padding: EdgeInsets.symmetric(
              vertical: Adaptive.h(1),
              horizontal: Adaptive.w(2),
            ),
            child: TextField(
              controller: _passwordController,
              focusNode: _passwordFocusNode,
              obscureText: _obscurePassword,
              autocorrect: false,
              enableSuggestions: false,
              style: BitcoinTextStyle.body5(Bitcoin.neutral8).copyWith(
                fontFamily: 'Inter',
              ),
              decoration: InputDecoration(
                labelText: 'Backup password',
                labelStyle: BitcoinTextStyle.body4(Bitcoin.neutral6),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    color: Bitcoin.neutral6,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
    );

    final footer = FooterButton(
      title: 'Restore',
      onPressed: _canRestore ? () => _restore() : null,
      enabled: _canRestore,
    );

    return ScreenSkeleton(
      title: 'Restore from backup file',
      showBackButton: true,
      body: body,
      footer: footer,
    );
  }
}
