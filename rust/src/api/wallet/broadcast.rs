use crate::api::structs::{
    network::Network,
};

use anyhow::Result;
use spdk_wallet::{backend_blindbit_v1::BlindbitClient};

use super::SpWallet;

impl SpWallet {
    // note: should only be used when using regtest, else there is privacy loss!
    pub async fn broadcast_using_blindbit(blindbit_url: String, tx: String) -> Result<String> {
        let blindbit_client = BlindbitClient::new(&blindbit_url)?;

        let res = blindbit_client.forward_tx(tx).await?;

        Ok(res.to_string())
    }

    pub async fn broadcast_tx(tx: String, network: Network) -> Result<String> {
        let tx: pushtx::Transaction = tx.parse().unwrap();

        let txid = tx.txid();

        let network = match network {
            Network::Mainnet => pushtx::Network::Mainnet,
            Network::Testnet3 => pushtx::Network::Testnet,
            Network::Testnet4 => pushtx::Network::Testnet,
            Network::Signet => pushtx::Network::Signet,
            Network::Regtest => pushtx::Network::Regtest,
        };

        let opts = pushtx::Opts {
            network,
            ..Default::default()
        };

        tokio::task::spawn_blocking(move || {
            let receiver = pushtx::broadcast(vec![tx], opts);

            loop {
                match receiver.recv() {
                    Ok(pushtx::Info::Done(Ok(report))) => {
                        if report.success.len() > 0 {
                            log::info!("broadcasted {} transactions", report.success.len());
                            break;
                        } else {
                            return Err(anyhow::Error::msg("Failed to broadcast transaction, probably unable to connect to Tor peers"));
                        }
                    }
                    Ok(pushtx::Info::Done(Err(err))) => return Err(anyhow::Error::msg(err.to_string())),
                    Ok(_) => {} // Continue for other Info variants
                    Err(recv_err) => {
                        log::error!("Channel recv error: {:?}", recv_err);
                        return Err(anyhow::Error::msg(format!(
                            "Channel closed unexpectedly while waiting for broadcast result: {:?}", 
                            recv_err
                        )));
                    }
                }
            }
            Ok(())
        })
        .await??;

        Ok(txid.to_string())
    }
}
