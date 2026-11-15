import 'dart:typed_data';

import 'package:danawallet/generated/rust/api/wallet/backup.dart';
import 'package:danawallet/repositories/wallet_repository.dart';

/// Copy + flow glue for the restore side of the §7.2 backup flow.
///
/// Anti-oracle (§7.2 step 3): [genericFailureMessage] is THE failure copy.
/// Wrong password, corrupted header, truncated file and invalid payload all
/// surface as the single `ApiRestoreFailure.restoreFailed` outcome and
/// produce exactly this message — the UI must never distinguish them. The
/// D1 gate refusal ([walletExistsMessage], §7.2 step 2) is the one
/// distinguishable outcome, because it is a device-state precondition the
/// user must act on (delete first), not a fact about the file.
class BackupRestoreService {
  BackupRestoreService({WalletRepository? walletRepository})
      : _walletRepository = walletRepository ?? WalletRepository.instance;

  final WalletRepository _walletRepository;

  static const String genericFailureMessage =
      'Restore failed. The file could not be opened with this password. '
      'Check the password and the file, then try again.';

  static const String walletExistsMessage =
      'A wallet already exists on this device. Delete the existing wallet '
      'before restoring a backup.';

  /// D1 gate input (§7.2 step 2): whether a wallet already exists on this
  /// device. Restore refuses when it does; deletion is the prerequisite
  /// (no merge, no overwrite, no bypass).
  Future<bool> walletExistsOnDevice() async =>
      await _walletRepository.readWallet() != null;

  /// §7.2 via the Rust restore core. Throws [ApiRestoreFailure] — the
  /// complete caller-visible failure surface — on refusal or failure; any
  /// other exception is an infrastructure error, not a fact about the file.
  Future<ApiRestoredWallet> restoreFromBytes(
      Uint8List bytes, String password) async {
    final walletExists = await walletExistsOnDevice();
    return restoreBackupFileDart(
      file: bytes,
      password: password,
      walletExistsOnDevice: walletExists,
    );
  }

  /// The one user-visible message per outcome (§7.2 step 3). Total over
  /// all inputs on purpose: an unexpected error gets the same generic copy,
  /// so no code path can leak a wrong-password vs corrupt-file distinction.
  static String messageFor(Object error) => switch (error) {
        ApiRestoreFailure.walletExists => walletExistsMessage,
        _ => genericFailureMessage,
      };
}
