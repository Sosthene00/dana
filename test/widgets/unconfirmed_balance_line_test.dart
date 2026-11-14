import 'package:danawallet/constants.dart';
import 'package:danawallet/data/enums/amount_display_unit.dart';
import 'package:danawallet/widgets/wallet/unconfirmed_balance_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('B4.1: with no pending candidates the line is absent (not zero)',
      (tester) async {
    await tester.pumpWidget(wrap(const UnconfirmedBalanceLine(
      pendingBalanceSat: null,
      unit: AmountDisplayUnit.btc,
    )));

    expect(find.byType(Text), findsNothing,
        reason: 'the line is absent when there are no candidates');
  });

  testWidgets('B4.1: renders the pending amount with an unconfirmed label',
      (tester) async {
    await tester.pumpWidget(wrap(const UnconfirmedBalanceLine(
      pendingBalanceSat: 15000,
      unit: AmountDisplayUnit.sats,
    )));

    final text = tester.widget<Text>(find.byType(Text)).data!;
    expect(text, contains('unconfirmed'));
    expect(text, contains('15000'),
        reason: 'the pending amount is shown in the selected unit');
  });

  testWidgets('amount privacy: hidden balance is masked', (tester) async {
    await tester.pumpWidget(wrap(const UnconfirmedBalanceLine(
      pendingBalanceSat: 15000,
      unit: AmountDisplayUnit.btc,
      hideAmount: true,
    )));

    final text = tester.widget<Text>(find.byType(Text)).data!;
    expect(text, contains(hideAmountFormat));
    expect(text, isNot(contains('15000')));
  });
}
