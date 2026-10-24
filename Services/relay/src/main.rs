mod packets;
mod protocol;
mod relay;
mod tls;

use clap::Parser;
use sha2::{Digest, Sha256};
use std::{
    ops::RangeInclusive,
    path::{Path, PathBuf},
    sync::Arc,
};

#[derive(Parser)]
struct Options {
    #[arg(long, default_value = "0.0.0.0:4433")]
    listen: String,
    /// Fixed public forwarding ports (required behind Fly's UDP routing).
    #[arg(long, value_parser = parse_ports)]
    forward_ports: Option<RangeInclusive<u16>>,
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
    let listen = tokio::net::lookup_host(options.listen.as_str())
        .await?
        .next()
        .ok_or_else(|| anyhow::anyhow!("listen hostname has no addresses"))?;
    anyhow::ensure!(
        options.max_connections > 0,
        "max-connections must be positive"
    );
    anyhow::ensure!(
        !options
            .forward_ports
            .as_ref()
            .is_some_and(|ports| ports.contains(&listen.port())),
        "forwarding pool overlaps control port"
    );
    let (config, mut tls_digest) = load_tls(&options.cert, &options.key)?;
    let endpoint = quinn::Endpoint::server(config, listen)?;
    let relay = Arc::new(relay::Relay::new(listen.ip(), options.forward_ports));
    let permits = Arc::new(tokio::sync::Semaphore::new(options.max_connections));
    let mut refresh = tokio::time::interval(std::time::Duration::from_secs(60));
    eprintln!("PocketDesk relay listening on {}", endpoint.local_addr()?);
    loop {
        tokio::select! {
            _ = refresh.tick() => {
                match load_tls(&options.cert, &options.key) {
                    Ok((config, digest)) if digest != tls_digest => {
                        endpoint.set_server_config(Some(config));
                        tls_digest = digest;
                    }
                    Ok(_) => {},
                    Err(_) => eprintln!("TLS certificate reload failed; keeping the current certificate"),
                }
            }
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

/// Validate both files before swapping configs. A partial renewal keeps the last good config.
fn load_tls(cert: &Path, key: &Path) -> anyhow::Result<(quinn::ServerConfig, [u8; 32])> {
    let cert_bytes = std::fs::read(cert)?;
    let key_bytes = std::fs::read(key)?;
    let mut digest = Sha256::new();
    digest.update(&cert_bytes);
    digest.update(&key_bytes);
    let certs = rustls_pemfile::certs(&mut cert_bytes.as_slice()).collect::<Result<Vec<_>, _>>()?;
    let key = rustls_pemfile::private_key(&mut key_bytes.as_slice())?
        .ok_or_else(|| anyhow::anyhow!("missing private key"))?;
    Ok((tls::server(certs, key)?, digest.finalize().into()))
}

fn parse_ports(value: &str) -> Result<RangeInclusive<u16>, String> {
    let (start, end) = value.split_once('-').ok_or("use START-END")?;
    let start: u16 = start.parse().map_err(|_| "invalid start port")?;
    let end: u16 = end.parse().map_err(|_| "invalid end port")?;
    if start == 0 || end < start || u32::from(end) - u32::from(start) >= 1024 {
        return Err("use 1 to 1024 nonzero ports in ascending order".into());
    }
    Ok(start..=end)
}

#[cfg(test)]
#[test]
fn forwarding_port_range_validation() {
    assert_eq!(parse_ports("50000-50031").unwrap(), 50000..=50031);
    for value in ["0-10", "50001-50000", "1-2000", "65535-65536", "50000"] {
        assert!(parse_ports(value).is_err());
    }
}

#[cfg(test)]
#[test]
fn tls_reload_rejects_partial_rotation_and_accepts_a_complete_pair() {
    let directory =
        std::env::temp_dir().join(format!("pocketdesk-relay-tls-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let cert = directory.join("cert.pem");
    let key = directory.join("key.pem");
    let first = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
    let second = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
    std::fs::write(&cert, first.cert.pem()).unwrap();
    std::fs::write(&key, first.signing_key.serialize_pem()).unwrap();
    let (_, before) = load_tls(&cert, &key).unwrap();
    std::fs::write(&key, second.signing_key.serialize_pem()).unwrap();
    assert!(load_tls(&cert, &key).is_err());
    std::fs::write(&cert, second.cert.pem()).unwrap();
    let (_, after) = load_tls(&cert, &key).unwrap();
    assert_ne!(before, after);
    std::fs::remove_dir_all(directory).unwrap();
}
