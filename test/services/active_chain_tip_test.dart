import 'package:danawallet/repositories/settings_repository.dart';
import 'package:danawallet/services/active_chain_tip.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('displayed chain tip (B5.5)', () {
    test('frigate tip is used and a missing one is not filled from blindbit',
        () {
      expect(
        displayedChainTip(
          backend: ChainBackendKind.frigate,
          blindbitAvailable: true,
          blindbitTip: 500,
          frigateTip: 420,
        ),
        420,
      );
      expect(
        displayedChainTip(
          backend: ChainBackendKind.frigate,
          blindbitAvailable: true,
          blindbitTip: 500,
          frigateTip: null,
        ),
        isNull,
        reason: 'a missing frigate tip stays unknown',
      );
    });

    test('blindbit tip is used only while that scanner is selected', () {
      expect(
        displayedChainTip(
          backend: ChainBackendKind.blindbit,
          blindbitAvailable: true,
          blindbitTip: 500,
          frigateTip: 420,
        ),
        500,
      );
      expect(
        displayedChainTip(
          backend: ChainBackendKind.blindbit,
          blindbitAvailable: false,
          blindbitTip: 500,
          frigateTip: 420,
        ),
        isNull,
      );
    });

    test('the blindbit offline banner is hidden while frigate is selected',
        () {
      expect(
        showBlindbitOfflineBanner(
          backend: ChainBackendKind.frigate,
          blindbitAvailable: false,
        ),
        isFalse,
      );
      expect(
        showBlindbitOfflineBanner(
          backend: ChainBackendKind.blindbit,
          blindbitAvailable: false,
        ),
        isTrue,
      );
    });
  });
}
