import 'package:danawallet/repositories/settings_repository.dart';

/// Chain tip shown for confirmations and "blocks to scan".
///
/// While Frigate is the scanner the tip is the subscription's last accepted
/// tip. A missing Frigate tip stays unknown — it is not filled from Blindbit
/// (B5.5). While Blindbit is the scanner the tip is that session's tip.
int? displayedChainTip({
  required ChainBackendKind backend,
  required bool blindbitAvailable,
  required int? blindbitTip,
  required int? frigateTip,
}) {
  if (backend == ChainBackendKind.frigate) return frigateTip;
  if (!blindbitAvailable) return null;
  return blindbitTip;
}

/// The Blindbit offline banner follows the Blindbit scanner only. While
/// Frigate is selected, reachability is the Frigate banner.
bool showBlindbitOfflineBanner({
  required ChainBackendKind backend,
  required bool blindbitAvailable,
}) =>
    backend == ChainBackendKind.blindbit && !blindbitAvailable;
