import 'dart:math';

import 'package:bitcoin_ui/bitcoin_ui.dart';
import 'package:danawallet/data/models/bip353_address.dart';
import 'package:danawallet/data/models/recommended_fee_model.dart';
import 'package:danawallet/extensions/api_amount.dart';
import 'package:danawallet/extensions/input_selection.dart';
import 'package:danawallet/data/enums/selected_fee.dart';
import 'package:danawallet/constants.dart';
import 'package:danawallet/states/contacts_state.dart';
import 'package:danawallet/data/models/contact.dart';
import 'package:danawallet/generated/rust/api/structs/amount.dart';
import 'package:danawallet/generated/rust/api/structs/psbt.dart';
import 'package:danawallet/generated/rust/api/structs/input_selection.dart';
import 'package:danawallet/generated/rust/api/structs/recipient.dart';
import 'package:danawallet/generated/rust/api/wallet/coin_selection.dart';
import 'package:danawallet/global_functions.dart';
import 'package:danawallet/screens/spend/ready_to_send.dart';
import 'package:danawallet/widgets/skeletons/screen_skeleton.dart';
import 'package:danawallet/screens/spend/custom_fee_screen.dart';
import 'package:danawallet/states/chain_state.dart';
import 'package:danawallet/states/fiat_exchange_rate_state.dart';
import 'package:danawallet/states/wallet_state.dart';
import 'package:danawallet/widgets/buttons/footer/footer_button.dart';
import 'package:flutter/material.dart';
import 'package:logger/web.dart';
import 'package:provider/provider.dart';

class FeeSelectionScreen extends StatefulWidget {
  final Recipient recipient;
  final Bip353Address? providedBip353;

  const FeeSelectionScreen(
      {super.key, required this.recipient, this.providedBip353});
  @override
  State<FeeSelectionScreen> createState() {
    return FeeSelectionScreenState();
  }
}

class FeeSelectionScreenState extends State<FeeSelectionScreen> {
  RecommendedFeeResponse? _currentFeeRates;
  SelectedFee _selected = SelectedFee.normal;
  final Map<SelectedFee, Amount> _feeAmounts = {};
  final Map<SelectedFee, InputSelection> _inputSelections = {};

  // Privacy UX selection (the actual transaction-building behavior depends on
  // rust-side coin selection returning the requested properties).
  _PrivacyMode _privacyMode = _PrivacyMode.standard;

  // Changeless-only candidate (single recipient).
  final Map<SelectedFee, InputSelection> _changelessInputSelections = {};
  final Map<SelectedFee, bool> _changelessAvailable = {};

  // Donate-to-contact (two recipients).
  Contact? _donateContact;

  // Extra-fee constraints for the privacy options.
  static const int _maxPrivacyExtraFeeSat = 2000;
  static const int _minDonateSat = defaultDustLimit;

  @override
  void initState() {
    super.initState();
    _computeFeeAmounts();
  }

  bool _canAvoidDrainForSent(BigInt totalSent) {
    // Keep consistent with WalletState.selectInputsForRecipients drain decision.
    // When total sent exceeds (balance - 546), the rust wallet currently uses
    // a drain selection strategy.
    final walletState = Provider.of<WalletState>(context, listen: false);
    return totalSent <= walletState.amount.field0 - BigInt.from(546);
  }

  // Try to force "changeless" selection for the primary recipient only.
  InputSelection? _trySelectChangelessPrimary({
    required int feerate,
  }) {
    final walletState = Provider.of<WalletState>(context, listen: false);
    final totalSent = widget.recipient.amount.field0;
    if (!_canAvoidDrainForSent(totalSent)) return null;

    try {
      return selectUtxosToSpend(
        ownedOutputs: walletState.unspentOutputs,
        recipients: [widget.recipient],
        nChangeOutputs: BigInt.zero,
        feerate: feerate.toDouble(),
        network: walletState.network,
        drain: false,
      ).pickChangeless();
    } catch (_) {
      return null;
    }
  }

  bool _extraFeeWithinCap({
    required InputSelection candidate,
    required Amount baselineFee,
  }) {
    final extra = candidate.fee.field0 - baselineFee.field0;
    if (extra < BigInt.zero) return true; // candidate cheaper than baseline
    return extra <= BigInt.from(_maxPrivacyExtraFeeSat);
  }

  bool _isDonateChangeAvailable() {
    final change = _inputSelections[_selected]?.change;
    return change != null && change.field0 >= BigInt.from(_minDonateSat);
  }

  Amount? _donateChangeAmount() => _inputSelections[_selected]?.change;

  List<Contact> _eligibleDonateContacts() {
    final contacts = Provider.of<ContactsState>(context, listen: false);
    final recipientCode = widget.recipient.paymentCode;
    return contacts
        .getOtherContacts()
        .where((contact) => contact.paymentCode != recipientCode)
        .toList();
  }

  Contact? _pickRandomDonateContact([List<Contact>? eligible]) {
    final contacts = eligible ?? _eligibleDonateContacts();
    if (contacts.isEmpty) return null;
    return contacts[Random().nextInt(contacts.length)];
  }

  _PrivacyChoice? _cheapestPrivacyChoice() {
    final baselineFee = _inputSelections[_selected]?.fee;
    if (baselineFee == null) return null;

    _PrivacyChoice? cheapest;

    void consider(_PrivacyMode mode, BigInt extraCostSat) {
      if (extraCostSat == BigInt.zero) return;

      final choice = _PrivacyChoice(
        mode: mode,
        extraCost: Amount(field0: extraCostSat),
      );
      if (cheapest == null) {
        cheapest = choice;
        return;
      }
      final comparison =
          choice.extraCost.field0.compareTo(cheapest!.extraCost.field0);
      if (comparison < 0) {
        cheapest = choice;
      } else if (comparison == 0 && mode == _PrivacyMode.changeless) {
        cheapest = choice;
      }
    }

    if (_changelessAvailable[_selected] == true) {
      final changelessFee = _changelessInputSelections[_selected]!.fee;
      final extra = changelessFee.field0 - baselineFee.field0;
      consider(
        _PrivacyMode.changeless,
        extra < BigInt.zero ? BigInt.zero : extra,
      );
    }

    if (_eligibleDonateContacts().isNotEmpty && _isDonateChangeAvailable()) {
      consider(_PrivacyMode.donate, _donateChangeAmount()!.field0);
    }

    return cheapest;
  }

  void _enableCheapestPrivacy() {
    final choice = _cheapestPrivacyChoice();
    if (choice == null) return;

    _privacyMode = choice.mode;
    if (choice.mode == _PrivacyMode.donate) {
      _donateContact = _pickRandomDonateContact();
    } else {
      _donateContact = null;
    }
  }

  InputSelection _inputSelectionWithoutSelfChange(InputSelection standard) {
    return InputSelection(
      selectedUtxos: standard.selectedUtxos,
      change: Amount(field0: BigInt.zero),
      nChangeOutputs: BigInt.zero,
      fee: standard.fee,
      actualFeeRate: standard.actualFeeRate,
      strategy: standard.strategy,
    );
  }

  void _syncPrivacySelection() {
    if (_privacyMode == _PrivacyMode.standard) return;

    final choice = _cheapestPrivacyChoice();
    if (choice == null) {
      _privacyMode = _PrivacyMode.standard;
      _donateContact = null;
      return;
    }

    _privacyMode = choice.mode;
    if (choice.mode == _PrivacyMode.donate) {
      final eligible = _eligibleDonateContacts();
      final contactStillValid = _donateContact != null &&
          eligible.any(
              (contact) => contact.paymentCode == _donateContact!.paymentCode);
      if (!contactStillValid) {
        _donateContact = _pickRandomDonateContact(eligible);
      }
    } else {
      _donateContact = null;
    }
  }

  Future<void> _computeFeeAmounts() async {
    final chainState = Provider.of<ChainState>(context, listen: false);
    final walletState = Provider.of<WalletState>(context, listen: false);

    // fetch fee rates from mempool
    final currentFeeRates = await chainState.getCurrentFeeRates();

    for (SelectedFee fee in [
      SelectedFee.fast,
      SelectedFee.normal,
      SelectedFee.slow
    ]) {
      final feerate = fee.getFeeRate(currentFeeRates);
      final inputSelection = walletState.selectInputsForRecipients(
          [widget.recipient], feerate);
      if (feerate.toDouble() != inputSelection.actualFeeRate) {
        Logger().w('Fee rate mismatch: expected $feerate, actual ${inputSelection.actualFeeRate}');
      }
      _feeAmounts[fee] = inputSelection.fee;
      _inputSelections[fee] = inputSelection;

      // Changeless candidate for the primary recipient only.
      final changelessSelection = _trySelectChangelessPrimary(
        feerate: feerate,
      );
      final baselineFee = inputSelection.fee;
      final available = changelessSelection != null &&
          changelessSelection.change.field0 == BigInt.zero &&
          changelessSelection.strategy == 'changeless' &&
          _extraFeeWithinCap(
              candidate: changelessSelection, baselineFee: baselineFee);

      if (changelessSelection != null && available) {
        _changelessInputSelections[fee] = changelessSelection;
        _changelessAvailable[fee] = true;
      } else {
        _changelessAvailable[fee] = false;
      }
    }

    setState(() {
      _currentFeeRates = currentFeeRates;
    });
  }

  Future<void> onContinue() async {
    final walletState = Provider.of<WalletState>(context, listen: false);
    final changeCode = walletState.changePaymentCode;

    final feerate = _selected.getFeeRate(_currentFeeRates!);

    Psbt newTx;
    InputSelection inputSelection;

    if (_privacyMode == _PrivacyMode.standard) {
      inputSelection = _inputSelections[_selected]!;
      newTx = walletState.createUnsignedTxToThisRecipient(
          widget.recipient, inputSelection, feerate);
    } else if (_privacyMode == _PrivacyMode.changeless) {
      inputSelection = _changelessInputSelections[_selected]!;
      newTx = walletState.createUnsignedTxToThisRecipient(
          widget.recipient, inputSelection, feerate);
    } else {
      // Donate mode: sponsor receives the change from the standard selection.
      final standardSelection = _inputSelections[_selected]!;
      final donateAmount = standardSelection.change;
      if (_donateContact == null ||
          donateAmount.field0 < BigInt.from(_minDonateSat)) {
        throw Exception('Donate option not ready');
      }

      final sponsorRecipient = Recipient(
        paymentCode: _donateContact!.paymentCode,
        amount: donateAmount,
      );

      inputSelection = standardSelection;
      newTx = Psbt.createNewTransaction(
        recipients: [widget.recipient, sponsorRecipient],
        network: walletState.network,
      );
      newTx = newTx.addInputs(inputSelection: standardSelection);
      newTx = newTx.addChange(
        inputSelection: _inputSelectionWithoutSelfChange(standardSelection),
        changeAddress: changeCode,
      );
    }

    final fundedTx = await walletState.fillUpInputsFundingUtxo(newTx);

    // Build UI recipients from funded PSBT outputs.
    // `getSendAmount` excludes change outputs, but for donate mode we need to
    // show the primary amount and the donation amount separately.
    final psbtRecipients = fundedTx.getRecipients(network: walletState.network);
    final nonChangeRecipients = psbtRecipients
        .where((r) => r.paymentCode != changeCode)
        .toList(growable: false);

    Recipient updatedRecipient;
    Recipient? sponsorRecipient;

    if (_privacyMode == _PrivacyMode.donate) {
      updatedRecipient = nonChangeRecipients.firstWhere(
          (r) => r.paymentCode == widget.recipient.paymentCode,
          orElse: () => Recipient(
              paymentCode: widget.recipient.paymentCode,
              amount: Amount(field0: BigInt.zero)));

      sponsorRecipient = nonChangeRecipients.firstWhere(
          (r) => r.paymentCode == _donateContact!.paymentCode,
          orElse: () => Recipient(
              paymentCode: _donateContact!.paymentCode,
              amount: Amount(field0: BigInt.zero)));
    } else {
      updatedRecipient = Recipient(
        paymentCode: widget.recipient.paymentCode,
        amount: fundedTx.getSendAmount(changeCode: changeCode),
      );
    }

    if (mounted) {
      goToScreen(
          context,
          ReadyToSendScreen(
            recipient: updatedRecipient,
            sponsorRecipient: sponsorRecipient,
            providedBip353: widget.providedBip353,
            fee: _selected,
            psbt: fundedTx,
          ));
    }
  }

  ListTile toListTile(SelectedFee fee, FiatExchangeRateState exchangeRate) {
    switch (fee) {
      case SelectedFee.fast:
      case SelectedFee.normal:
      case SelectedFee.slow:
        String subtitleBtc;
        String subtitleFiat;
        if (_currentFeeRates == null) {
          subtitleBtc = 'Loading...';
          subtitleFiat = 'Loading...';
        } else {
          final estimatedFee = _feeAmounts[fee];
          if (estimatedFee == null) {
            throw Exception('Fee amount not computed for $fee');
          }
          subtitleBtc = estimatedFee.displaySats();
          subtitleFiat = exchangeRate.displayFiat(estimatedFee);
        }

        return ListTile(
          title: Row(
            children: [
              Text(
                fee.toName,
                style: BitcoinTextStyle.body3(Bitcoin.black),
              ),
              const Spacer(),
              Text(fee.toEstimatedTime,
                  style: BitcoinTextStyle.body3(Bitcoin.black)),
            ],
          ),
          subtitle: Row(
            children: [
              Text(subtitleBtc,
                  style: BitcoinTextStyle.body5(Bitcoin.neutral7)),
              const Spacer(),
              Text(subtitleFiat,
                  style: BitcoinTextStyle.body5(Bitcoin.neutral7)),
            ],
          ),
          leading: Radio<SelectedFee>(
            value: fee,
          ),
          onTap: () {
            setState(() {
              _selected = fee;
            });
          },
        );
      case SelectedFee.custom:
        return ListTile(
          title: Text(
            SelectedFee.custom.toName,
            style: BitcoinTextStyle.body3(Bitcoin.black),
          ),
          trailing: const Image(
            image: AssetImage("icons/caret_right.png", package: "bitcoin_ui"),
          ),
          onTap: () {
            goToScreen(
                context,
                CustomFeeScreen(
                  recipient: widget.recipient,
                  providedBip353: widget.providedBip353,
                ));
          },
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final exchangeRate =
        Provider.of<FiatExchangeRateState>(context, listen: false);

    _syncPrivacySelection();

    final privacyChoice = _cheapestPrivacyChoice();
    final bool privacyEnabled = _privacyMode != _PrivacyMode.standard;

    final bool canContinue = _currentFeeRates != null &&
        (!privacyEnabled || privacyChoice != null);

    return ScreenSkeleton(
      showBackButton: true,
      title: 'Confirmation time',
      body: RadioGroup(
          groupValue: _selected,
          onChanged: (SelectedFee? value) {
            if (value != null) {
              setState(() {
                _selected = value;
                _syncPrivacySelection();
              });
            }
          },
          child: SingleChildScrollView(
            child: Column(children: [
            const Divider(),
            toListTile(SelectedFee.fast, exchangeRate),
            const Divider(),
            toListTile(SelectedFee.normal, exchangeRate),
            const Divider(),
            toListTile(SelectedFee.slow, exchangeRate),
            const Divider(),
            if (isDevEnv) toListTile(SelectedFee.custom, exchangeRate),
            if (isDevEnv) const Divider(),

            if (privacyChoice != null) ...[
              const SizedBox(height: 8),
              _PrivacyOptionsBox(
                privacyEnabled: privacyEnabled,
                extraCost: privacyChoice.extraCost,
                onPrivacyToggled: (enabled) {
                  setState(() {
                    if (enabled) {
                      _enableCheapestPrivacy();
                    } else {
                      _privacyMode = _PrivacyMode.standard;
                      _donateContact = null;
                    }
                  });
                },
              ),
            ],

            const SizedBox(height: 8),
          ]),
          )),
      footer: Column(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          const SizedBox(
            height: 10.0,
          ),
          FooterButton(
            title: 'Continue',
            onPressed: onContinue,
            enabled: canContinue,
          )
        ],
      ),
    );
  }
}

enum _PrivacyMode { standard, changeless, donate }

class _PrivacyChoice {
  const _PrivacyChoice({required this.mode, required this.extraCost});

  final _PrivacyMode mode;
  final Amount extraCost;
}

class _PrivacyOptionsBox extends StatelessWidget {
  const _PrivacyOptionsBox({
    required this.privacyEnabled,
    required this.extraCost,
    required this.onPrivacyToggled,
  });

  final bool privacyEnabled;
  final Amount extraCost;
  final void Function(bool enabled) onPrivacyToggled;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Bitcoin.neutral1,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Privacy',
            style: BitcoinTextStyle.title3(Bitcoin.black),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              'You can improve your privacy by spending ${extraCost.displaySats()} more',
              style: BitcoinTextStyle.body4(Bitcoin.black),
            ),
            value: privacyEnabled,
            onChanged: onPrivacyToggled,
          ),
        ],
      ),
    );
  }
}
