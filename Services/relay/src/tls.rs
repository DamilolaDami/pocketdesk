//! Device certificates are identities, not CA-issued accounts. CertificateVerify must still
//! prove possession of the private key; authorization uses the SHA-256 leaf fingerprint.
/// Version 2 carries the phone's traffic as QUIC datagrams, like the Mac's, instead of UDP.
pub const ALPN: &[u8] = b"pocketdesk-relay/2";

use rustls::{
    DigitallySignedStruct, DistinguishedName, Error, SignatureScheme,
    client::danger::HandshakeSignatureValid,
    pki_types::{CertificateDer, UnixTime},
    server::danger::{ClientCertVerified, ClientCertVerifier},
};
use std::sync::Arc;

#[derive(Debug)]
pub struct DeviceVerifier;
impl ClientCertVerifier for DeviceVerifier {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }
    fn verify_client_cert(
        &self,
        _: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: UnixTime,
    ) -> Result<ClientCertVerified, Error> {
        // No CA trust is asserted here. rustls parses the leaf and checks CertificateVerify
        // below. A caller cannot choose somebody else's fingerprint without their key.
        Ok(ClientCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}
pub fn server(
    certs: Vec<CertificateDer<'static>>,
    key: rustls::pki_types::PrivateKeyDer<'static>,
) -> anyhow::Result<quinn::ServerConfig> {
    let mut tls = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])?
    .with_client_cert_verifier(Arc::new(DeviceVerifier))
    .with_single_cert(certs, key)?;
    tls.alpn_protocols = vec![ALPN.to_vec()];
    let mut config = quinn::ServerConfig::with_crypto(Arc::new(
        quinn::crypto::rustls::QuicServerConfig::try_from(tls)?,
    ));
    let transport = Arc::get_mut(&mut config.transport).unwrap();
    // Keep every outer UDP datagram below Fly's public UDP MTU.
    transport
        .initial_mtu(1200)
        .mtu_discovery_config(None)
        .enable_segmentation_offload(false)
        .max_concurrent_bidi_streams(1u8.into())
        .max_concurrent_uni_streams(0u8.into())
        .max_idle_timeout(Some(std::time::Duration::from_secs(60).try_into()?))
        .keep_alive_interval(Some(std::time::Duration::from_secs(25)))
        .datagram_receive_buffer_size(Some(256 * 1024))
        .datagram_send_buffer_size(256 * 1024);
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn missing_device_certificate_is_rejected() {
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
        let der = cert.cert.der().clone();
        let key = rustls::pki_types::PrivatePkcs8KeyDer::from(cert.signing_key.serialize_der());
        let endpoint = quinn::Endpoint::server(
            server(vec![der.clone()], key.into()).unwrap(),
            "127.0.0.1:0".parse().unwrap(),
        )
        .unwrap();
        let address = endpoint.local_addr().unwrap();
        let mut roots = rustls::RootCertStore::empty();
        roots.add(der).unwrap();
        let mut tls = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_protocol_versions(&[&rustls::version::TLS13])
        .unwrap()
        .with_root_certificates(roots)
        .with_no_client_auth();
        tls.alpn_protocols = vec![ALPN.to_vec()];
        let mut client = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client.set_default_client_config(quinn::ClientConfig::new(Arc::new(
            quinn::crypto::rustls::QuicClientConfig::try_from(tls).unwrap(),
        )));
        let attempt = client.connect(address, "localhost").unwrap();
        let rejected = async { endpoint.accept().await.unwrap().await.is_err() };
        let (_, rejected) = tokio::time::timeout(std::time::Duration::from_secs(3), async {
            tokio::join!(attempt, rejected)
        })
        .await
        .unwrap();
        assert!(rejected);
    }
}
