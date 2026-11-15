import 'package:danawallet/extensions/date_time.dart';

/// Backup status for the §7.3 deletion gate (D10): the wallet-deletion
/// screen displays exactly one of these three states.
///
/// `verified` requires an actual restore test (§7.1 step 5); the underlying
/// flag lives in SettingsRepository so a future verify flow can set it
/// without a schema change. v1 defers the verify flow itself.
enum BackupStatus { none, exists, verified }

class BackupStatusInfo {
  const BackupStatusInfo({required this.status, this.date});

  final BackupStatus status;

  /// When the backup file was written (§7.1 step 5); null for `none`.
  final DateTime? date;

  /// §7.3: the typed acknowledgment is required exactly when no verified
  /// backup exists. The gate warns hard and refuses nothing — deletion is
  /// never blocked outright (a refusal would push users to wipe via OS
  /// settings with no warning at all).
  bool get requiresTypedAcknowledgment => status != BackupStatus.verified;
}

/// Computes the §7.3 deletion-gate status from the stored backup state:
/// no backup date -> `none`; a date without a successful restore test ->
/// `exists`; a date plus a verified flag -> `verified (with date)`.
BackupStatusInfo computeBackupStatus(
    {DateTime? lastBackupDate, bool verified = false}) {
  if (lastBackupDate == null) {
    return const BackupStatusInfo(status: BackupStatus.none);
  }
  return BackupStatusInfo(
    status: verified ? BackupStatus.verified : BackupStatus.exists,
    date: lastBackupDate,
  );
}

/// Display copy for the three §7.3 states, with the date where one exists.
String backupStatusText(BackupStatusInfo info) => switch (info.status) {
      BackupStatus.none => 'No backup file found for this wallet.',
      BackupStatus.exists =>
        'Backup created ${info.date!.toDisplayString()} — not yet verified by a restore test.',
      BackupStatus.verified =>
        'Verified backup from ${info.date!.toDisplayString()}.',
    };

/// §7.3 (D10) typed acknowledgment: when no verified backup exists, the
/// user must type this fixed phrase to proceed. The gate warns hard and
/// refuses nothing — the phrase is friction, not a lock, because a refusal
/// would push users to wipe the app via OS settings with no warning at all.
const String deletionAckPhrase = 'erase my wallet';

/// §7.3 gate rule in one testable place: the typed acknowledgment is
/// required exactly when no verified backup exists, and it is satisfied by
/// the fixed phrase (trimmed). An unknown status fails safe toward
/// requiring the acknowledgment.
bool typedAcknowledgmentSatisfied(BackupStatusInfo? status, String input) {
  if (status == null || !status.requiresTypedAcknowledgment) {
    return true;
  }
  return input.trim() == deletionAckPhrase;
}
