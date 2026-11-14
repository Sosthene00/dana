import 'package:danawallet/constants.dart';
import 'package:danawallet/data/enums/amount_display_unit.dart';
import 'package:danawallet/extensions/api_amount.dart';
import 'package:danawallet/generated/rust/api/structs/amount.dart';
import 'package:bitcoin_ui/bitcoin_ui.dart';
import 'package:flutter/material.dart';

/// The unconfirmed balance line shown directly below the main balance on the
/// home screen when the frigate path has pending candidates (B4.1).
///
/// Absent (not zero) when there are no pending candidates; informational
/// only — never spendable, never part of the send balance (B4.2/B6.1).
class UnconfirmedBalanceLine extends StatelessWidget {
  /// Sum of pending candidates in satoshis, or null when there are none.
  final int? pendingBalanceSat;

  final AmountDisplayUnit unit;

  /// Mirrors the main balance's privacy toggle: the amount is masked but the
  /// line itself stays visible.
  final bool hideAmount;

  const UnconfirmedBalanceLine({
    super.key,
    required this.pendingBalanceSat,
    required this.unit,
    this.hideAmount = false,
  });

  @override
  Widget build(BuildContext context) {
    final sat = pendingBalanceSat;
    if (sat == null) {
      return const SizedBox.shrink();
    }
    final amountText = hideAmount
        ? hideAmountFormat
        : Amount(field0: BigInt.from(sat)).display(unit);
    return Text(
      '+$amountText unconfirmed',
      style: BitcoinTextStyle.body3(Bitcoin.neutral6),
    );
  }
}
