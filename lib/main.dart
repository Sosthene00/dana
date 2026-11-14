import 'dart:async';
import 'dart:io';

import 'package:danawallet/constants.dart';
import 'package:danawallet/extensions/network.dart';
import 'package:danawallet/generated/rust/frb_generated.dart';

import 'package:danawallet/global_functions.dart';
import 'package:danawallet/services/foreground_sync_service.dart';
import 'package:danawallet/services/frigate_subscription_controller.dart';
import 'package:danawallet/repositories/database_helper.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/screens/home/home.dart';
import 'package:danawallet/screens/onboarding/introduction.dart';
import 'package:danawallet/screens/onboarding/register_dana_address.dart';
import 'package:danawallet/services/app_info_service.dart';
import 'package:danawallet/services/logging_service.dart';
import 'package:danawallet/services/writer_lease.dart';
import 'package:danawallet/states/chain_state.dart';
import 'package:danawallet/states/contacts_state.dart';
import 'package:danawallet/states/display_preferences_state.dart';
import 'package:danawallet/states/fiat_exchange_rate_state.dart';
import 'package:danawallet/states/frigate_state.dart';
import 'package:danawallet/states/home_state.dart';
import 'package:danawallet/states/permission_state.dart';
import 'package:danawallet/services/sync_orchestrator.dart';
import 'package:danawallet/states/sync_progress_state.dart';
import 'package:danawallet/states/wallet_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_svg/svg.dart';
import 'package:logger/logger.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:sizer/sizer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  LoggingService.create();

  if (Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  } else if (Platform.isAndroid) {
    ForegroundSyncService.initialize();
  } else {
    Logger().e('Dana wallet is not supported on this platform');
    exit(1);
  }

  final appInfo = AppInfoService(packageInfo: await PackageInfo.fromPlatform());

  // Initialize database
  await DatabaseHelper.instance.database;

  final walletState = WalletState.create();
  final permissionState = await PermissionState.create();
  final syncProgress = SyncProgressState.create();
  final chainState = ChainState();
  final contactsState = ContactsState();
  final displayPreferencesState = await DisplayPreferencesState.create();
  final fiatExchangeRate = FiatExchangeRateState();
  final frigateState = FrigateState();
  final frigateController = FrigateSubscriptionController(
    frigateState: frigateState,
    // B2.3/B2.8: the app isolate is only the FALLBACK writer — it takes
    // over from the foreground service exclusively through the writer lease
    // (stale >= 10 s = service confirmed down).
    writerLease: WriterLease(writerId: WriterLease.appWriterId),
    // phase 3 (B3.3): a graduation moved satoshis into owned_outputs —
    // refresh the confirmed balance from the repository.
    onGraduated: () {
      unawaited(walletState.refreshAfterSync());
    },
  );

  final syncOrchestrator = SyncOrchestrator(
    chainState: chainState,
    syncProgress: syncProgress,
    walletState: walletState,
    permissionState: permissionState,
  );

  // fetch the exchange rate, but don't await the response
  fiatExchangeRate.updateExchangeRates();

  await precacheImages();

  final bool walletLoaded;
  try {
    walletLoaded = await walletState.initialize();
  } catch (e) {
    // todo: show an error screen when wallet is present but fails to load
    rethrow;
  }

  Widget landingPage;
  if (walletLoaded) {
    final network = walletState.network;
    final blindbitUrl = await SettingsRepository.instance.getBlindbitUrl() ??
        network.defaultBlindbitUrl;

    chainState.initialize(network);

    await chainState.connect(blindbitUrl);

    final addressRegistrationNeeded =
        await walletState.checkDanaAddressRegistrationNeeded();

    // initialize contacts with the 'you' contact
    contactsState.initialize(
        walletState.receivePaymentCode, walletState.danaAddress);

    syncOrchestrator.start();

    // Frigate leg (B2.1): the subscription lives in the foreground service —
    // the service isolate claims the writer lease and writes sync state
    // directly to the DB (B2.2). The app refreshes its UI state from the
    // repositories and takes over writing only when the service is confirmed
    // down (B2.3/B2.8). On Linux there is no foreground service, so the app
    // isolate is the writer.
    frigateState.refresh();
    unawaited(startFrigateAppSide(frigateController));
    if (Platform.isAndroid) {
      // the service wrote sync state — re-read the registry/balance from the
      // DB instead of rescanning (B2.2)
      FlutterForegroundTask.addTaskDataCallback((data) {
        if (data is Map && data[bgKeyFrigateRefresh] == true) {
          unawaited(frigateState.refresh());
        }
      });
    }

    if (addressRegistrationNeeded) {
      landingPage = const RegisterDanaAddressScreen();
    } else {
      landingPage = const HomeScreen();
    }
  } else {
    // no wallet is loaded, so we go to the introduction screen
    landingPage = const IntroductionScreen();
  }

  runApp(
    MultiProvider(
      providers: [
        // simple providers for static/immutable data
        Provider.value(value: appInfo),
        Provider.value(value: syncOrchestrator),
        // providers for mutable data
        ChangeNotifierProvider.value(value: walletState),
        ChangeNotifierProvider.value(value: syncProgress),
        ChangeNotifierProvider.value(value: frigateState),
        ChangeNotifierProvider.value(value: chainState),
        ChangeNotifierProvider.value(value: HomeState()),
        ChangeNotifierProvider.value(value: permissionState),
        ChangeNotifierProvider.value(value: fiatExchangeRate),
        ChangeNotifierProvider.value(value: contactsState),
        ChangeNotifierProvider.value(value: displayPreferencesState)
      ],
      child: SilentPaymentApp(landingPage: landingPage),
    ),
  );
}

class SilentPaymentApp extends StatelessWidget {
  final Widget landingPage;

  const SilentPaymentApp({
    super.key,
    required this.landingPage,
  });

  @override
  Widget build(BuildContext context) {
    return Sizer(builder: (context, orientation, screenType) {
      return MaterialApp(
          title: 'Dana wallet',
          navigatorKey: globalNavigatorKey,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: danaBlue),
            useMaterial3: true,
            fontFamily: 'Space Grotesk',
            // SatoshiSymbol provides the sat glyph (U+E006) via PUA fallback
            fontFamilyFallback: const [satFontFamily],
          ),
          home: landingPage);
    });
  }
}

/// App-side frigate writer handoff (B2.3/B2.8): on Android, give the
/// foreground-service isolate a head start to claim the writer lease; if a
/// fresh service claim appears, the app stays read-only (B2.1/B2.2). If the
/// lease stays unclaimed/stale past the grace window, the service is
/// confirmed down and the app takes over writing in-process. On Linux there
/// is no foreground service — the app isolate is the writer.
Future<void> startFrigateAppSide(
    FrigateSubscriptionController controller) async {
  if (Platform.isAndroid) {
    final serviceWriterLive = await waitForServiceWriterClaim();
    if (serviceWriterLive) {
      Logger().i('frigate: foreground service holds the writer lease — '
          'app stays read-only (B2.1/B2.3)');
      return;
    }
    Logger().i('frigate: no live service writer after the grace window — '
        'app takes over writing (B2.3/B2.8)');
  }
  try {
    await controller.start();
  } catch (e) {
    Logger().e('frigate app-side writer failed to start: $e');
  }
}

Future<void> precacheImages() async {
  await precacheSvgPicture("assets/icons/rocket.svg");
  await precacheSvgPicture("assets/icons/address-book.svg");
  await precacheSvgPicture("assets/icons/hidden.svg");
}

Future precacheSvgPicture(String svgPath) async {
  final logo = SvgAssetLoader(svgPath);
  await svg.cache.putIfAbsent(logo.cacheKey(null), () => logo.loadBytes(null));
}
