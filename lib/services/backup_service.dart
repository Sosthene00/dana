import 'dart:typed_data';

import 'package:danawallet/generated/rust/api/wallet.dart';
import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/services/backup_passphrase_generator.dart';
import 'package:danawallet/services/device_capability_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:logger/logger.dart';

/// Argon2id profiles for the export flow.
///
/// Default: spec §6.3 (D8, RFC 9106 constrained profile). Reduced: the
/// §6.3.2 encrypt-side device-class fallback — constant ~time·memory
/// product, recorded in the file header and honored as written by readers.
class BackupKdfProfile {
  final int mKib;
  final int t;
  final int p;

  const BackupKdfProfile._(this.mKib, this.t, this.p);

  static const BackupKdfProfile standard = BackupKdfProfile._(65536, 3, 1);
  static const BackupKdfProfile reduced = BackupKdfProfile._(32768, 4, 1);
}

/// The §7.1 export flow: password/generate -> one-shot AEAD encrypt via the
/// BK-01/BK-02 Rust API -> platform file picker -> backup status date
/// (§7.3 deletion-gate feed).
///
/// Export is always encrypted — there is no plaintext export option in v1
/// (D3, §7.1 step 1); this service offers none.
class BackupService {
  BackupService({
    SettingsRepository? settingsRepository,
    DeviceCapabilityService? deviceCapabilityService,
  })  : _settings = settingsRepository ?? SettingsRepository.instance,
        _device = deviceCapabilityService ?? DeviceCapabilityService.instance;

  final SettingsRepository _settings;
  final DeviceCapabilityService _device;

  /// §6.2 generated option. Pure in-memory generation — the passphrase is
  /// returned to the caller once and MUST NOT be persisted anywhere (§6.2);
  /// no storage call happens on this path.
  String generatePassphrase() => BackupPassphraseGenerator().generate();

  /// §6.3.2: which KDF profile this device should encrypt with. True only
  /// for low-RAM (Go-class) devices; the export UI shows the reduced
  /// profile prominently when this returns true — never silently.
  Future<bool> shouldUseReducedKdf() => _device.isLowRamDevice();

  /// §7.1 steps 3–5. Encrypts the wallet into fresh-salt/fresh-nonce
  /// one-shot-AEAD container bytes, saves them via the platform file picker
  /// under a user-chosen filename, and on success marks the backup status
  /// with the current date (§7.3 deletion-gate feed).
  ///
  /// Returns the destination URI, or null when the user cancelled the
  /// picker (no file written, no status recorded). Throws on encryption or
  /// write failure — the status date is only recorded after a successful
  /// write.
  Future<Uri?> exportBackup({
    required SpWallet wallet,
    required String password,
    required BackupKdfProfile kdfProfile,
    String? fileName,
  }) async {
    final Uint8List bytes;
    if (kdfProfile == BackupKdfProfile.reduced) {
      bytes = await wallet.createBackupFileWithKdf(
        password: password,
        argon2MKib: kdfProfile.mKib,
        argon2T: kdfProfile.t,
        argon2P: kdfProfile.p,
      );
    } else {
      bytes = await wallet.createBackupFile(password: password);
    }

    final destination = await FilePicker.saveFile(
      fileName: fileName ?? defaultBackupFileName(),
      bytes: bytes,
      mimeType: 'application/octet-stream',
    );

    if (destination == null) {
      Logger().i('Backup export cancelled at the file picker');
      return null;
    }

    // §7.1 step 5: mark backup status with the current date.
    await _settings.setLastBackupDate(DateTime.now());
    Logger().i('Encrypted backup written to $destination');
    return destination;
  }

  static String defaultBackupFileName() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return 'dana-backup-$y-$m-$d.danabkp';
  }
}
