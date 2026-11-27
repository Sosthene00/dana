// M-c (review t_a38b7193): the public-warning path — a failed apply after
// the ack must not silently pretend success.
//
// The pre-ruling migration path (FrigatePublicWarningWatcher) acks the
// warning and asks the sync host to apply the committed backend. When no
// host receives that request (service path dropped, host error), the user
// must see it — the app's existing SnackBar error surface — instead of the
// watcher silently moving on.
import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/generated/rust/frb_generated.dart';
import 'package:danawallet/services/sync_orchestrator.dart';
import 'package:danawallet/states/chain_state.dart';
import 'package:danawallet/states/frigate_state.dart';
import 'package:danawallet/states/permission_state.dart';
import 'package:danawallet/states/sync_progress_state.dart';
import 'package:danawallet/states/wallet_state.dart';
import 'package:danawallet/widgets/wallet/frigate_public_warning.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Serves exactly the Rust api the orchestrator construction touches (the
/// sync-progress stream SyncProgressState subscribes to).
class _WarningRustApi implements RustLibApi {
  @override
  Stream<int> crateApiStreamCreateSyncProgressStream() =>
      const Stream<int>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    RustLib.initMock(api: _WarningRustApi());
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(const {});
    FlutterSecureStorage.setMockInitialValues(const {});
  });

  testWidgets(
      'M-c: a failed apply after the ack surfaces the divergence — no '
      'silent success on the public-warning path', (tester) async {
    final frigateState = FrigateState();
    final chainState = ChainState();
    chainState.initialize(Network.regtest, 'http://127.0.0.1:1');
    // A real orchestrator with no running host: on this (non-Android) test
    // platform the service path reports not-delivered.
    final orchestrator = SyncOrchestrator(
      chainState: chainState,
      frigateState: frigateState,
      permissionState: PermissionState(),
      syncProgress: SyncProgressState.create(),
      walletState: WalletState.create(),
    );
    frigateState.setPublicWarningPending(true);

    await tester.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider.value(value: frigateState),
      Provider.value(value: orchestrator),
    ], child: MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      return FrigatePublicWarningWatcher(
          child: Scaffold(body: Container()));
    })))));

    // The pending flag opens the blocking warning.
    await tester.pump();
    expect(find.text('Sync through a public backend?'), findsOneWidget);

    await tester.tap(find.text('Yes — I understand, sync publicly'));
    await tester.pumpAndSettle();

    expect(frigateState.publicWarningPending, isFalse,
        reason: 'the ack lands as before');
    expect(find.byType(SnackBar), findsOneWidget,
        reason: 'M-c: the failed apply is user-visible, not a log line');
    expect(find.textContaining('could not be switched'), findsOneWidget);

    // The real applyBackend aligned the chain poller (10 s timer); stop it
    // so no timer outlives the test.
    chainState.stopChainPoller();
  });
}
