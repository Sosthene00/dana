use flutter_rust_bridge::frb;
use spdk_wallet::{
    bitcoin::{
        consensus::{deserialize, serialize},
        hex::{DisplayHex, FromHex},
        Network,
    },
    silentpayments::utils::sending::PartialSecret,
};

use crate::api::structs::amount::Amount;
use crate::api::structs::discovered_output::DiscoveredOutput;
use crate::api::structs::recipient::{PaymentCode, PaymentCodeKind, Recipient};
use crate::api::structs::silent_payment_code::SilentPaymentCode;

pub struct SilentPaymentUnsignedTransaction {
    pub selected_utxos: Vec<(super::outpoint::OutPoint, DiscoveredOutput)>,
    pub recipients: Vec<Recipient>,
    pub partial_secret: [u8; 32],
    pub unsigned_tx: Option<String>,
    pub network: String,
}

impl From<spdk_wallet::client::SilentPaymentUnsignedTransaction>
    for SilentPaymentUnsignedTransaction
{
    fn from(value: spdk_wallet::client::SilentPaymentUnsignedTransaction) -> Self {
        Self {
            selected_utxos: value
                .selected_utxos
                .into_iter()
                .map(|(outpoint, output)| (outpoint.into(), output.into()))
                .collect(),
            recipients: value.recipients.into_iter().map(|r| r.into()).collect(),
            partial_secret: value.partial_secret.secret_bytes(),
            unsigned_tx: value
                .unsigned_tx
                .map(|tx| serialize(&tx).to_lower_hex_string()),
            network: value.network.to_core_arg().to_string(),
        }
    }
}

impl From<SilentPaymentUnsignedTransaction>
    for spdk_wallet::client::SilentPaymentUnsignedTransaction
{
    fn from(value: SilentPaymentUnsignedTransaction) -> Self {
        Self {
            selected_utxos: value
                .selected_utxos
                .into_iter()
                .map(|(outpoint, output)| (outpoint.into(), output.into()))
                .collect(),
            recipients: value.recipients.into_iter().map(|r| r.into()).collect(),
            partial_secret: PartialSecret::from_slice(&value.partial_secret).unwrap(),
            unsigned_tx: value
                .unsigned_tx
                .map(|tx| deserialize(&Vec::from_hex(&tx).unwrap()).unwrap()),
            network: Network::from_core_arg(&value.network).unwrap(),
        }
    }
}

impl SilentPaymentUnsignedTransaction {
    #[frb(sync)]
    pub fn get_send_amount(&self, change_code: &SilentPaymentCode) -> Amount {
        // Mainline accounting: every output that is not our own change
        // counts toward what was sent — including Data/OP_RETURN payloads and
        // degraded unparseable rows carried by legacy DB entries. The typed
        // refactor had narrowed this to kind-parseable codes only via
        // get_recipients()/is_payment_recipient(), silently dropping them.
        let amount = self
            .recipients
            .iter()
            .filter(|recipient| !is_change(&recipient.payment_code, change_code))
            .map(|recipient| recipient.amount.0)
            .sum();

        Amount(amount)
    }

    #[frb(sync)]
    pub fn get_change_amount(&self, change_code: &SilentPaymentCode) -> Amount {
        let amount = self
            .recipients
            .iter()
            .filter(|r| is_change(&r.payment_code, change_code))
            .map(|r| r.amount.0)
            .sum();
        Amount(amount)
    }

    #[frb(sync)]
    pub fn get_fee_amount(&self) -> Amount {
        let input_sum: u64 = self.selected_utxos.iter().map(|(_, o)| o.value.0).sum();

        let output_sum: u64 = self.recipients.iter().map(|r| r.amount.0).sum();

        Amount(input_sum - output_sum)
    }

    #[frb(sync)]
    pub fn get_recipients(&self, change_code: &SilentPaymentCode) -> Vec<Recipient> {
        self.recipients
            .iter()
            .filter(|r| is_payment_recipient(&r.payment_code, change_code))
            .cloned()
            .collect()
    }
}

fn is_change(address: &PaymentCode, change_code: &SilentPaymentCode) -> bool {
    address.silent_payment_code().as_ref() == Some(change_code)
}

/// Silent payment outputs other than change, plus bech32/bech32m and Base58Check.
/// OP_RETURN is left out.
fn is_payment_recipient(address: &PaymentCode, change_code: &SilentPaymentCode) -> bool {
    match address.kind() {
        Ok(PaymentCodeKind::SilentPayment) => !is_change(address, change_code),
        Ok(PaymentCodeKind::Bech32 | PaymentCodeKind::Base58) => true,
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use spdk_wallet::bitcoin::hex::FromHex;
    use spdk_wallet::client::RecipientAddress as SpRecipientAddress;

    const CHANGE_SP: &str = "sp1qq2xewwk5u02gxxurdzr6r6jerelncw82rlyvw2kpggxt3pum4kp6yq62utdcljdtmxpy3vs7c940hvjuzedhhsf7h2y5lflk7zp2xhgz3vryqw4n";
    const PAY_SP: &str = "tsp1qq2d4vvramh9n3qrg5kaac7mjwdhfs402hg2msphmxuq3xqnw7hyj5qu9y636sf85v6uekr3vt3dcrzva64af9wct25y3wj0y4dgavjcp2uwsljny";
    /// OP_RETURN payload as an older build stored it in tx_recipients.
    const OP_RETURN_HEX: &str = "6a057468652074616c6b";

    fn unsigned_tx(recipients: Vec<Recipient>) -> SilentPaymentUnsignedTransaction {
        SilentPaymentUnsignedTransaction {
            selected_utxos: vec![],
            recipients,
            partial_secret: [0u8; 32],
            unsigned_tx: None,
            network: "bitcoin".to_string(),
        }
    }

    /// Gate-(a) / mainline parity: the send total must sum EVERY non-change
    /// recipient, including Data/OP_RETURN-shaped legacy rows. Pinned RED at
    /// the audit pin: `is_payment_recipient`'s `Err(_) => false` arm dropped
    /// the 10_000 OP_RETURN output, so the total read 50_000 where mainline
    /// (change-index filter over all recipients) summed 60_000.
    #[test]
    fn get_send_amount_sums_all_non_change_recipients_including_op_return() {
        let change = SilentPaymentCode::parse_as_str(CHANGE_SP).unwrap();
        let pay = SilentPaymentCode::parse_as_str(PAY_SP).unwrap();
        let payload = Vec::from_hex(OP_RETURN_HEX).unwrap();
        let tx = unsigned_tx(vec![
            Recipient::new(pay.into(), Amount(50_000)),
            Recipient::new(
                PaymentCode::from(SpRecipientAddress::Data(payload)),
                Amount(10_000),
            ),
            Recipient::new(change.into(), Amount(30_000)),
        ]);

        assert_eq!(tx.get_send_amount(&change).0, 50_000 + 10_000);
        assert_eq!(tx.get_change_amount(&change).0, 30_000);
        // The payment view (UI "who I paid") keeps excluding OP_RETURN:
        assert_eq!(tx.get_recipients(&change).len(), 1);
    }

    /// A zero-value Data/OP_RETURN row (the common wallet-built shape) must
    /// also survive the total unchanged: mainline summed it as 0, the typed
    /// build must not crash nor shift the total on it either.
    #[test]
    fn get_send_amount_zero_amount_op_return_never_breaks_total() {
        let change = SilentPaymentCode::parse_as_str(CHANGE_SP).unwrap();
        let pay = SilentPaymentCode::parse_as_str(PAY_SP).unwrap();
        let tx = unsigned_tx(vec![
            Recipient::new(pay.into(), Amount(42_000)),
            Recipient::new(
                PaymentCode::from(SpRecipientAddress::Data(vec![])),
                Amount(0),
            ),
            Recipient::new(change.into(), Amount(9_000)),
        ]);
        assert_eq!(tx.get_send_amount(&change).0, 42_000);
    }
}
