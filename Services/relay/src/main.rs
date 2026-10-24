mod packets;
mod protocol;
mod relay;
mod tls;

use clap::Parser;
use std::{net::SocketAddr, path::PathBuf, sync::Arc};

#[derive(Parser)]
struct Options {
    #[arg(long, default_value = "0.0.0.0:4433")]
    listen: SocketAddr,
    #[arg(long)]
    cert: PathBuf,
    #[arg(long)]
    key: PathBuf,
    /// Maximum concurrent control connections (including incomplete handshakes).
    #[arg(long, default_value_t = 1024)]
    max_connections: usize,
}
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let options = Options::parse();
    let certs = rustls_pemfile::certs(&mut std::io::BufReader::new(std::fs::File::open(
        options.cert,
    )?))
    .collect::<Result<Vec<_>, _>>()?;
    let key = rustls_pemfile::private_key(&mut std::io::BufReader::new(std::fs::File::open(
        options.key,
    )?))?
    .ok_or_else(|| anyhow::anyhow!("missing private key"))?;
    let endpoint = quinn::Endpoint::server(tls::server(certs, key)?, options.listen)?;
    let relay = Arc::new(relay::Relay::new(options.listen.ip()));
    let permits = Arc::new(tokio::sync::Semaphore::new(options.max_connections));
    eprintln!("PocketDesk relay listening on {}", endpoint.local_addr()?);
    loop {
        tokio::select! {
            incoming = endpoint.accept() => {
                let Some(incoming) = incoming else { break };
                let Ok(permit) = permits.clone().try_acquire_owned() else { incoming.refuse(); continue };
                if !incoming.remote_address_validated() { let _ = incoming.retry(); continue; }
                let relay = relay.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    if let Ok(Ok(connection)) = tokio::time::timeout(std::time::Duration::from_secs(10), incoming).await {
                        relay.serve(connection).await;
                    }
                });
            }
            _ = tokio::signal::ctrl_c() => break,
        }
    }
    endpoint.close(0u32.into(), b"shutdown");
    endpoint.wait_idle().await;
    Ok(())
}
