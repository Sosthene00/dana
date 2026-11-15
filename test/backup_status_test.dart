import 'package:danawallet/utils/backup_status.dart';
import 'package:flutter_test/flutter_test.dart';

/// Acceptance 4 (BK-05): the §7.3 deletion gate renders exactly three
/// backup-status states, and the typed acknowledgment is required exactly
/// when no verified backup exists — never blocking deletion outright.
void main() {
  final date = DateTime.utc(2026, 11, 15, 12);

  test('no backup date renders the none state', () {
    final info = computeBackupStatus(lastBackupDate: null);
    expect(info.status, BackupStatus.none);
    expect(info.date, isNull);
    expect(backupStatusText(info), contains('No backup'));
  });

  test('a backup date without a restore test renders exists (with date)', () {
    final info = computeBackupStatus(lastBackupDate: date, verified: false);
    expect(info.status, BackupStatus.exists);
    expect(info.date, date);
    expect(backupStatusText(info), contains('not yet verified'));
  });

  test('a verified backup renders verified (with date)', () {
    final info = computeBackupStatus(lastBackupDate: date, verified: true);
    expect(info.status, BackupStatus.verified);
    expect(info.date, date);
    expect(backupStatusText(info), contains('Verified backup'));
  });

  test('typed acknowledgment required exactly when no verified backup', () {
    expect(
        computeBackupStatus(lastBackupDate: null).requiresTypedAcknowledgment,
        isTrue);
    expect(
        computeBackupStatus(lastBackupDate: date).requiresTypedAcknowledgment,
        isTrue);
    expect(
        computeBackupStatus(lastBackupDate: date, verified: true)
            .requiresTypedAcknowledgment,
        isFalse);
  });

  test('typed acknowledgment satisfied only by the fixed phrase', () {
    final noBackup = computeBackupStatus(lastBackupDate: null);
    final verified = computeBackupStatus(lastBackupDate: date, verified: true);

    // With a verified backup the gate never asks for the phrase.
    expect(typedAcknowledgmentSatisfied(verified, ''), isTrue);
    expect(typedAcknowledgmentSatisfied(verified, 'anything'), isTrue);

    // Without one, only the exact fixed phrase (trimmed) satisfies it.
    expect(typedAcknowledgmentSatisfied(noBackup, ''), isFalse);
    expect(typedAcknowledgmentSatisfied(noBackup, 'erase my wallet'), isTrue);
    expect(
        typedAcknowledgmentSatisfied(noBackup, '  erase my wallet '), isTrue);
    expect(
        typedAcknowledgmentSatisfied(noBackup, 'erase my wallet now'), isFalse);

    // Unknown status fails safe toward requiring the acknowledgment.
    expect(typedAcknowledgmentSatisfied(null, ''), isTrue);
  });

  test('deletion is never blocked outright: refusal is impossible', () {
    // The gate can only delay (phrase not typed yet) — with the phrase
    // typed, deletion always proceeds, whatever the status.
    for (final info in [
      computeBackupStatus(lastBackupDate: null),
      computeBackupStatus(lastBackupDate: DateTime.utc(2026, 1, 1)),
      computeBackupStatus(
          lastBackupDate: DateTime.utc(2026, 1, 1), verified: true),
    ]) {
      expect(typedAcknowledgmentSatisfied(info, deletionAckPhrase), isTrue);
    }
  });
}
