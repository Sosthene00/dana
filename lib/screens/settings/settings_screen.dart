import 'package:bitcoin_ui/bitcoin_ui.dart';
import 'package:danawallet/global_functions.dart';
import 'package:danawallet/screens/settings/about/about_screen.dart';
import 'package:danawallet/screens/settings/chain_backend_screen.dart';
import 'package:danawallet/screens/settings/network/network_settings_screen.dart';
import 'package:danawallet/screens/settings/personalization/personalisation_settings_screen.dart';
import 'package:danawallet/screens/settings/widgets/settings_list_tile.dart';
import 'package:danawallet/widgets/skeletons/main_screen_skeleton.dart';
import 'package:danawallet/screens/settings/wallet/wallet_settings_screen.dart';
import 'package:flutter/material.dart';

const String pageTitle = "Settings";
const String chainBackendTitle = "Chain backend";
const String chainBackendSubtitle = "Choose a Blindbit or Frigate server";
const String networkSettingsTitle = "Network settings";
const String networkSettingsSubtitle = "Sync height and dust limit";
const String walletSettingsTitle = "Wallet settings";
const String walletSettingsSubtitle = "Backup, reset or wipe wallet";
const String personalizationSettingsTitle = "Personalization settings";
const String personalizationSettingsSubtitle =
    "Set bitcoin unit & fiat currency";
const String aboutSettingsTitle = "About";
const String aboutSettingsSubtitle = "About Dana";

const IconData chainBackendIcon = Icons.dns_outlined;
const IconData networkSettingsIcon = Icons.settings_ethernet;
const IconData walletSettingsIcon = Icons.account_balance_wallet_outlined;
const IconData personalizationSettingsIcon = Icons.tune;
const IconData aboutSettingsIcon = Icons.info_outlined;

const Widget chainBackendScreen = ChainBackendScreen();
const Widget networkSettingScreen = NetworkSettingsScreen();
const Widget walletSettingsScreen = WalletSettingsScreen();
const Widget personalizationSettingsScreen = PersonalisationSettingsScreen();
const Widget aboutSettingsScreen = AboutSettingsScreen();

/// Main settings screen showing all setting categories
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settingsTiles = [
      SettingsListTile(
        icon: chainBackendIcon,
        title: chainBackendTitle,
        subtitle: chainBackendSubtitle,
        onTap: () => goToScreen(context, chainBackendScreen),
      ),
      if (isDevEnv)
        SettingsListTile(
          icon: networkSettingsIcon,
          title: networkSettingsTitle,
          subtitle: networkSettingsSubtitle,
          onTap: () => goToScreen(context, networkSettingScreen),
        ),
      SettingsListTile(
        icon: walletSettingsIcon,
        title: walletSettingsTitle,
        subtitle: walletSettingsSubtitle,
        onTap: () => goToScreen(context, walletSettingsScreen),
      ),
      SettingsListTile(
        icon: personalizationSettingsIcon,
        title: personalizationSettingsTitle,
        subtitle: personalizationSettingsSubtitle,
        onTap: () => goToScreen(context, personalizationSettingsScreen),
      ),
      SettingsListTile(
        icon: aboutSettingsIcon,
        title: aboutSettingsTitle,
        subtitle: aboutSettingsSubtitle,
        onTap: () => goToScreen(context, aboutSettingsScreen),
      )
    ];

    return MainScreenSkeleton(
      title: pageTitle,
      body: ListView.separated(
        itemCount: settingsTiles.length,
        separatorBuilder: (context, index) => Divider(
          height: 1,
          thickness: 1,
          color: Bitcoin.neutral3,
          indent: 56,
        ),
        itemBuilder: (context, index) => settingsTiles[index],
      ),
    );
  }
}
