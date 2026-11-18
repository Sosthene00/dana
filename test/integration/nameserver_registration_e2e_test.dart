// WT-02 (t_7efd3024) end-to-end demo: one complete registration through the
// REAL Dart flow (capability gate -> nameserver already-registered check ->
// /challenge -> real FFI wallet signing -> /register) against a LIVE
// NS-01-server build (dana-nameserver spec-v1 branch) with a Cloudflare stub.
//
// GATED: skipped unless DANA_NS_E2E_URL is set (base URL of the running
// server, e.g. http://127.0.0.1:18080/v1) AND the FFI dylib is loadable. The
// companion shell runner (scratch t_7efd3024/run_e2e.sh) starts the server
// + stub, builds the dylib, and exports both.
//
// Network note: the NS-01 server structurally rejects regtest SP addresses
// ("Can't issue a challenge for regtest addresses", src/main.rs) — regtest
// has no pinned network_key by ruling D7, fail closed. The demo therefore
// registers a TESTNET (tsp) wallet against the locally-run NS-01 server,
// which is the nearest runnable network for a full end-to-end pass.
import 'dart:io';

import 'package:danawallet/generated/rust/api/structs/network.dart';
import 'package:danawallet/generated/rust/api/structs/silent_payment_code.dart';
import 'package:danawallet/generated/rust/api/wallet.dart';
import 'package:danawallet/generated/rust/api/wallet/setup.dart';
import 'package:danawallet/generated/rust/frb_generated.dart';
import 'package:danawallet/repositories/name_server_repository.dart';
import 'package:danawallet/services/dana_address_service.dart';
import 'package:flutter_test/flutter_test.dart';

final String? e2eBaseUrl = Platform.environment['DANA_NS_E2E_URL'];
final bool ffiConfigured =
    Platform.environment['FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR'] !=
        null;
final bool e2eEnabled = e2eBaseUrl != null && ffiConfigured;

void main() {
  group('NS-01 live end-to-end (DANA_NS_E2E_URL=$e2eBaseUrl)', () {
    late SpWallet walletA;
    late SpWallet walletB;
    late SilentPaymentCode codeA;
    late SilentPaymentCode codeB;
    late String username;

    setUpAll(() async {
      await RustLib.init();
      Future<SpWallet> newWallet() {
        final setup = SpWallet.setupWallet(
          setupArgs: const WalletSetupArgs(
            setupType: WalletSetupType.newWallet(),
            network: Network.testnet3,
          ),
        );
        return Future.value(SpWallet(
          scanKey: setup.scanKey,
          spendKey: setup.spendKey,
          network: Network.testnet3,
        ));
      }

      walletA = await newWallet();
      walletB = await newWallet();
      codeA = walletA.getReceivingAddress();
      codeB = walletB.getReceivingAddress();
      // RFC-1035-safe, unique per run so re-runs never collide with the
      // server's in-memory state or a stale DNS cache.
      username =
          'wt02e2e${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}';
    });

    DanaAddressService serviceFor() {
      final service = DanaAddressService(network: Network.testnet3);
      service.nameServerRepository.baseUrl = e2eBaseUrl!;
      return service;
    }

    Future<String> Function(String message) signerFor(SpWallet wallet) =>
        (message) async => wallet.signRegistrationChallenge(message: message);

    test('one complete registration succeeds end-to-end', () async {
      final service = serviceFor();
      final info = await service.nameServerRepository.getInfo();
      final registered = await service.registerUser(
        username: username,
        paymentCode: codeA,
        signChallenge: signerFor(walletA),
      );
      expect(registered.username, username);
      expect(registered.domain, info.domain);
      expect(info.capabilities, contains('challenge-auth:v1'),
          reason: 'the live server must advertise the capability the flow '
              'gate requires');
    });

    test(
        're-registration is a no-op self-match via the machine-readable '
        'nameserver check (D10)', () async {
      final service = serviceFor();
      final registered = await service.registerUser(
        username: username,
        paymentCode: codeA,
        signChallenge: signerFor(walletA),
      );
      expect(registered.username, username,
          reason: 'the nameserver lookup for our own payment code must '
              'confirm the self-match and no-op');
    });

    test(
        'first-commit-wins race: the loser gets the distinct '
        'username_taken code (D10)', () async {
      final service = serviceFor();
      try {
        await service.registerUser(
          username: username,
          paymentCode: codeB,
          signChallenge: signerFor(walletB),
        );
        fail('the race loser must not succeed');
      } on RegisterRejectedException catch (e) {
        expect(e.code, NameServerErrorCode.usernameTaken,
            reason: 'loser surfaces the distinct username_taken code');
      }
    });
  },
      skip: e2eEnabled
          ? false
          : 'e2e not enabled: set DANA_NS_E2E_URL (live NS-01 server) and '
              'FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR');
}
