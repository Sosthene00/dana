// B2.1 (foreground-service lifecycle) — the start legs.
//
// The frigate subscription lives inside the Android foreground service
// (docs/BEHAVIOR.md B2.1). The wallet-start path — the first isolate
// bring-up after login, driven by SyncOrchestrator.start() — must start
// the service EXACTLY ONCE, and a service that is already live (e.g. the
// main isolate died and restarted while the service survived) must be
// RE-ATTACHED, never started a second time.
//
// Assertions are on service lifecycle CALLS, counted by the injected
// ForegroundServiceAdapter seam (lib/services/foreground_sync_service.dart),
// never on log text:
//   started  — startService requests actually issued to the platform
//   attached — start requests that found the service already live
//
// The survives-main-app-death leg is device-level (B8.3 acceptance run).
// ignore_for_file: unimplemented_noSuchMethod

import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/generated/rust/frb_generated.dart';
import 'package:danawallet/services/foreground_sync_service.dart';
import 'package:danawallet/services/sync_orchestrator.dart';
import 'package:danawallet/services/sync_service.dart';
import 'package:danawallet/states/chain_state.dart';
import 'package:danawallet/states/permission_state.dart';
import 'package:danawallet/states/sync_progress_state.dart';
import 'package:danawallet/states/wallet_state.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Serves exactly the Rust api the start path touches (the sync-progress
/// stream the SyncProgressState subscribes to); anything else is a bug.
class _LifecycleRustApi implements RustLibApi {
  @override
  Stream<int> crateApiStreamCreateSyncProgressStream() =>
      const Stream<int>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Test seam: counts the foreground-service lifecycle calls the wallet
/// makes. [started] counts startService requests issued to the platform
/// (a double-start increments it); [attached] counts start requests that
/// found the service already live (the re-attach path).
class _CountingServiceAdapter implements ForegroundServiceAdapter {
  int started = 0;
  int attached = 0;

  /// Whether the (fake) platform currently has the service running.
  bool serviceLive = false;

  /// ForegroundSyncService.start() probes isRunning() exactly once per
  /// start request, so a live probe IS the re-attach path.
  @override
  Future<bool> isRunning() async {
    if (serviceLive) attached++;
    return serviceLive;
  }

  @override
  Future<bool> startService() async {
    started++;
    serviceLive = true;
    return true;
  }

  @override
  Future<void> stopService() async {
    serviceLive = false;
  }
}

/// The orchestrator only takes the foreground-service path when the
/// notification permission is granted; the real check is a platform
/// channel, so the test pins the granted state directly.
class _NotificationGrantedPermissionState extends PermissionState {
  @override
  bool get notificationGranted => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    RustLib.initMock(api: _LifecycleRustApi());
    // WalletState.create() pulls the WalletRepository singleton, whose
    // constructor instantiates the storage backends: serve in-memory ones.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(const {});
    FlutterSecureStorage.setMockInitialValues(const {});
  });

  late _CountingServiceAdapter adapter;

  setUp(() {
    adapter = _CountingServiceAdapter();
    ForegroundSyncService.serviceAdapter = adapter;
    // Exercise the Android foreground-service path off-device.
    SyncOrchestrator.debugIsAndroidOverride = true;
  });

  tearDown(() {
    ForegroundSyncService.resetServiceAdapter();
    SyncOrchestrator.debugIsAndroidOverride = false;
  });

  /// Drives the wallet-start path exactly as main.dart does after login:
  /// chain state initialized, then SyncOrchestrator.start() (B2.1 start
  /// leg). The immediate chain-poll tick is drained and the poller stopped
  /// so no timer outlives the test; its connect fails fast against an
  /// unreachable URL and the error is swallowed by ChainState.connect.
  Future<SyncOrchestrator> walletStart(
      {bool serviceAlreadyLive = false}) async {
    adapter.serviceLive = serviceAlreadyLive;

    final chainState = ChainState();
    chainState.initialize(Network.regtest, 'http://127.0.0.1:1');

    final orchestrator = SyncOrchestrator(
      chainState: chainState,
      permissionState: _NotificationGrantedPermissionState(),
      syncProgress: SyncProgressState.create(),
      walletState: WalletState.create(),
    );

    await orchestrator.start();
    await pumpEventQueue();
    chainState.stopChainPoller();
    return orchestrator;
  }

  group('B2.1: the wallet-start path starts the foreground service once', () {
    test('wallet start starts the foreground service exactly once', () async {
      final orchestrator = await walletStart();

      expect(orchestrator.isRunning, isTrue);
      expect(adapter.started, 1, reason: 'exactly one startService request');
      expect(adapter.attached, 0);
    });

    test(
        're-entry/navigation: a second wallet start while running never re-starts',
        () async {
      final orchestrator = await walletStart();

      // Re-entry after navigation re-calls orchestrator.start() (e.g. the
      // network settings screen). No second startService request may be
      // issued, and nothing is re-attached either — the service is already
      // owned by this orchestrator.
      await orchestrator.start();

      expect(orchestrator.isRunning, isTrue);
      expect(adapter.started, 1);
      expect(adapter.attached, 0);
    });

    test(
        'service already live (isolate restart, service survives): the fresh wallet start re-attaches, never re-starts',
        () async {
      // The service outlived the main app: it is live before the wallet
      // starts. The wallet must attach to it and proceed to sync —
      // WITHOUT issuing a startService request.
      final orchestrator = await walletStart(serviceAlreadyLive: true);

      expect(orchestrator.isRunning, isTrue,
          reason: 'the wallet must attach to the live service and sync');
      expect(adapter.started, 0,
          reason: 'a live service is re-attached, not started again');
      expect(adapter.attached, 1);
    });

    test(
        'service layer: startForeground onto a live service re-attaches without a second start request',
        () async {
      final chainState = ChainState();
      chainState.initialize(Network.regtest, 'http://127.0.0.1:1');

      final service = SyncService(
        chainState: chainState,
        syncProgress: SyncProgressState.create(),
        walletState: WalletState.create(),
      );

      // Two consecutive startForeground() calls bypass the orchestrator's
      // _running guard (isolate restart / re-registration): the second must
      // re-attach, not double-start.
      expect(await service.startForeground(), isTrue);
      expect(await service.startForeground(), isTrue);

      await pumpEventQueue();
      chainState.stopChainPoller();

      expect(adapter.started, 1,
          reason: 'no second startService request on the live service');
      expect(adapter.attached, 1);
    });
  });
}
