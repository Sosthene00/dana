import 'package:danawallet/generated/rust/api/structs/input_selection.dart';

extension InputSelectionList on List<InputSelection> {
  InputSelection? byStrategy(String strategy) {
    for (final selection in this) {
      if (selection.strategy == strategy) {
        return selection;
      }
    }
    return null;
  }

  /// Prefer lowest-fee strategies that keep change; fall back if needed.
  /// Never returns a changeless selection — that strategy is opt-in via the UI.
  InputSelection pickStandard() {
    return byStrategy('lowest_fee') ??
        byStrategy('greedy') ??
        first;
  }

  InputSelection? pickChangeless() => byStrategy('changeless');
}
