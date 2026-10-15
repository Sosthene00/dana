import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/states/wallet_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUpAll(() {
    // WalletRepository (a singleton WalletState builds eagerly) constructs a
    // SharedPreferencesAsync, which throws 'instance must be set' without a
    // registered platform. The regtest guard short-circuits before any read,
    // but the constructor alone needs the in-memory stub present.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('WalletState.checkDanaAddressRegistrationNeeded', () {
    test('regtest skips the registration flow entirely', () async {
      // Regtest has no dana address support: the check must short-circuit
      // to false and clear the in-memory address without touching storage
      // or the name server. If the regtest guard were removed, the call
      // would fall through into WalletRepository.readDanaAddress
      // (FlutterSecureStorage) and fail in a plugin-less test environment.
      final walletState = WalletState.create();
      walletState.network = Network.regtest;
      walletState.receivePaymentCode = 'sp1regtestplaceholder';

      final needsRegistration =
          await walletState.checkDanaAddressRegistrationNeeded();

      expect(needsRegistration, false);
      expect(walletState.danaAddress, isNull);
    });
  });
}
