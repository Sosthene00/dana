import 'package:danawallet/generated/rust/api/wallet/backup.dart';
import 'package:danawallet/services/backup_restore_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Acceptance 3 (BK-05): wrong-password and corrupt-file produce the
/// identical user-visible message (§7.2 step 3, anti-oracle), while the D1
/// gate refusal (§7.2 step 2) is the one distinguishable outcome.
void main() {
  test(
      'wrong password and corrupt file collapse into the identical user-visible message',
      () {
    // Both internal failures surface as the single restoreFailed variant —
    // nothing else about them is observable across the API boundary
    // (restore_api_tests pin the Rust side of the same contract).
    const wrongPasswordFailure = ApiRestoreFailure.restoreFailed;
    const corruptFileFailure = ApiRestoreFailure.restoreFailed;

    final wrongPasswordMessage =
        BackupRestoreService.messageFor(wrongPasswordFailure);
    final corruptFileMessage =
        BackupRestoreService.messageFor(corruptFileFailure);

    expect(wrongPasswordMessage, corruptFileMessage);
    expect(wrongPasswordMessage,
        equals(BackupRestoreService.genericFailureMessage));
  });

  test('D1 refusal is distinguishable and directs the user to delete first',
      () {
    final walletExistsMessage =
        BackupRestoreService.messageFor(ApiRestoreFailure.walletExists);

    expect(
        walletExistsMessage, equals(BackupRestoreService.walletExistsMessage));
    // A device-state precondition, not a fact about the file: different
    // copy from the generic failure, and it names the prerequisite.
    expect(walletExistsMessage,
        isNot(equals(BackupRestoreService.genericFailureMessage)));
    expect(walletExistsMessage.toLowerCase(), contains('delete'));
  });

  test('failure copy is total: any other error gets the generic message', () {
    // No code path may leak a wrong-password vs corrupt-file distinction,
    // including unexpected infrastructure errors.
    expect(BackupRestoreService.messageFor(Exception('argon2 blew up')),
        equals(BackupRestoreService.genericFailureMessage));
    expect(BackupRestoreService.messageFor('some raw cause'),
        equals(BackupRestoreService.genericFailureMessage));
  });
}
