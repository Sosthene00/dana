import 'package:bitcoin_ui/bitcoin_ui.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/screens/onboarding/introduction.dart';
import 'package:danawallet/states/chain_state.dart';
import 'package:danawallet/states/contacts_state.dart';
import 'package:danawallet/states/display_preferences_state.dart';
import 'package:danawallet/states/home_state.dart';
import 'package:danawallet/services/sync_orchestrator.dart';
import 'package:danawallet/states/wallet_state.dart';
import 'package:danawallet/utils/backup_status.dart';
import 'package:danawallet/widgets/buttons/footer/footer_button.dart';
import 'package:danawallet/widgets/icons/circular_icon.dart';
import 'package:danawallet/widgets/skeletons/screen_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

const Color pageColor = Colors.redAccent;

const String titleText = "Wipe wallet from this device";
const String info1Text =
    "This cannot be undone. Your recovery phrase and all other wallet data will be erased from this device.";
const String info2Text =
    "Please make sure you have backed up your seed phrase beforehand!";
const String buttonText = "Wipe wallet";

const String deletionAckInstruction =
    'No verified backup exists. Type "erase my wallet" to confirm you understand what you are losing.';

/// §7.3 Deletion gate (D10).
///
/// Displays the current backup status as one of three states — none /
/// exists / verified (with date) — and requires a typed acknowledgment
/// exactly when no verified backup exists. Deletion is never blocked
/// outright: once the acknowledgment is satisfied (trivially, when a
/// verified backup exists), the wipe always proceeds.
class ConfirmWalletDeletionScreen extends StatefulWidget {
  const ConfirmWalletDeletionScreen({super.key});

  @override
  State<ConfirmWalletDeletionScreen> createState() =>
      _ConfirmWalletDeletionScreenState();
}

class _ConfirmWalletDeletionScreenState
    extends State<ConfirmWalletDeletionScreen> {
  final _ackController = TextEditingController();

  /// Null until loaded; while unknown, the acknowledgment is required
  /// (fail safe toward the warning, never toward silent deletion).
  BackupStatusInfo? _backupStatus;

  @override
  void initState() {
    super.initState();
    _loadBackupStatus();
    _ackController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _ackController.removeListener(() => setState(() {}));
    _ackController.dispose();
    super.dispose();
  }

  Future<void> _loadBackupStatus() async {
    final settings = SettingsRepository.instance;
    final date = await settings.getLastBackupDate();
    final verified = await settings.isLastBackupVerified();
    if (mounted) {
      setState(() {
        _backupStatus =
            computeBackupStatus(lastBackupDate: date, verified: verified);
      });
    }
  }

  /// §7.3: the typed acknowledgment is required exactly when no verified
  /// backup exists — and it never blocks deletion outright.
  bool get _acknowledgmentSatisfied =>
      typedAcknowledgmentSatisfied(_backupStatus, _ackController.text);

  Future<void> onConfirmWipeWallet(BuildContext context) async {
    final walletState = Provider.of<WalletState>(context, listen: false);
    final homeState = Provider.of<HomeState>(context, listen: false);
    final chainState = Provider.of<ChainState>(context, listen: false);
    final orchestrator = Provider.of<SyncOrchestrator>(context, listen: false);
    final contacts = Provider.of<ContactsState>(context, listen: false);
    final displayPreferences =
        Provider.of<DisplayPreferencesState>(context, listen: false);

    await orchestrator.stop();
    chainState.reset();
    await walletState.reset();
    await SettingsRepository.instance.resetAll();
    contacts.reset();
    homeState.reset();
    displayPreferences.reset();

    if (context.mounted) {
      Navigator.pushReplacement(context,
          MaterialPageRoute(builder: (context) => const IntroductionScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    const icon = CircularIcon(
        icon: Icon(
          Icons.close,
          color: Colors.white,
          size: 20,
        ),
        radius: 25,
        color: pageColor);

    final header = Text(
      titleText,
      style: BitcoinTextStyle.title3(Bitcoin.black),
    );

    final text1 = Text(
      info1Text,
      style: BitcoinTextStyle.body3(Bitcoin.neutral8),
    );

    final text2 = Text(
      info2Text,
      style: BitcoinTextStyle.body3(Bitcoin.neutral8),
    );

    // §7.3: backup status — exactly one of none / exists / verified.
    final status = _backupStatus;
    final backupStatusWidget = status == null
        ? const SizedBox.shrink()
        : Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Bitcoin.neutral2,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              backupStatusText(status),
              style: BitcoinTextStyle.body4(Bitcoin.neutral8),
            ),
          );

    final typedAcknowledgment =
        (status != null && status.requiresTypedAcknowledgment)
            ? Column(
                children: [
                  Text(
                    deletionAckInstruction,
                    style: BitcoinTextStyle.body4(Bitcoin.neutral7),
                    textAlign: TextAlign.center,
                  ),
                  TextField(
                    controller: _ackController,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: BitcoinTextStyle.body5(Bitcoin.neutral8).copyWith(
                      fontFamily: 'Inter',
                    ),
                    decoration: const InputDecoration(
                      hintText: deletionAckPhrase,
                    ),
                  ),
                ],
              )
            : const SizedBox.shrink();

    final items = Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        icon,
        header,
        text1,
        backupStatusWidget,
        typedAcknowledgment,
        text2,
      ],
    );

    final body = Column(children: [
      Expanded(
        child: SingleChildScrollView(child: items),
      ),
      const Spacer(),
    ]);

    final footer = FooterButton(
      title: buttonText,
      onPressed:
          _acknowledgmentSatisfied ? () => onConfirmWipeWallet(context) : null,
      enabled: _acknowledgmentSatisfied,
      color: pageColor,
    );

    return ScreenSkeleton(
      body: body,
      showBackButton: true,
      footer: footer,
    );
  }
}
