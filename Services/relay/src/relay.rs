use crate::protocol::{self, Message};
use quinn::Connection;
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::sync::mpsc;
use uuid::Uuid;

/// A forwarded piece: 16-byte session ID, 16-byte packet ID, index and count bytes, and up to
/// 1,000 payload bytes. Both devices split and reassemble packets themselves; the relay only
/// checks the session and passes each piece to the other side unchanged.
pub const MIN_PIECE: usize = 35;
pub const MAX_PIECE: usize = 1034;

type Outbox = mpsc::Sender<Message>;
struct Host {
    connection: Connection,
    outbox: Outbox,
    allowed: HashSet<String>,
}
struct Session {
    host: String,
    phone: String,
    owner: usize,
    phone_connection: Connection,
    phone_out: Outbox,
    created: Instant,
    /// Set once the phone asks to forward; the last time the phone sent a piece.
    forwarding: Option<Instant>,
}
#[derive(Default)]
struct State {
    hosts: HashMap<String, Host>,
    sessions: HashMap<Uuid, Session>,
}
impl State {
    fn remove(&mut self, id: Uuid) {
        if let Some(session) = self.sessions.remove(&id) {
            let _ = session.phone_out.try_send(Message::Close { session: id });
            if let Some(h) = self.hosts.get(&session.host) {
                let _ = h.outbox.try_send(Message::Close { session: id });
            }
        }
    }
    fn prune(&mut self) {
        let expired: Vec<_> = self
            .sessions
            .iter()
            .filter(|(_, s)| match s.forwarding {
                None => s.created.elapsed() > Duration::from_secs(60),
                Some(last) => last.elapsed() > Duration::from_secs(60),
            })
            .map(|(id, _)| *id)
            .collect();
        for id in expired {
            self.remove(id);
        }
    }
    /// Where a piece from this connection goes: the session's other side, if the connection
    /// is one of its two participants and the Mac still allows the phone.
    fn route(&mut self, id: Uuid, fp: &str, connection: usize) -> Option<Connection> {
        let session = self.sessions.get_mut(&id)?;
        session.forwarding?;
        let host = self.hosts.get(&session.host)?;
        if !host.allowed.contains(&session.phone) {
            return None;
        }
        if session.owner == connection && session.phone == fp {
            session.forwarding = Some(Instant::now());
            Some(host.connection.clone())
        } else if session.host == fp && host.connection.stable_id() == connection {
            Some(session.phone_connection.clone())
        } else {
            None
        }
    }
}
pub struct Relay {
    state: Mutex<State>,
}
impl Relay {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(State::default()),
        }
    }
    pub async fn serve(self: Arc<Self>, connection: Connection) {
        let fingerprint = {
            let Some(identity) = connection.peer_identity() else {
                return;
            };
            let Some(certs) =
                identity.downcast_ref::<Vec<rustls::pki_types::CertificateDer<'static>>>()
            else {
                return;
            };
            let Some(leaf) = certs.first() else { return };
            hex::encode(Sha256::digest(leaf.as_ref()))
        };
        let (out, mut messages) = mpsc::channel(32);
        let result = async {
            let (mut send, mut recv) =
                tokio::time::timeout(Duration::from_secs(10), connection.accept_bi()).await??;
            let reader = async {
                let mut window = Instant::now();
                let mut requests = 0;
                loop {
                    let message =
                        tokio::time::timeout(Duration::from_secs(60), protocol::read(&mut recv))
                            .await??;
                    if window.elapsed() >= Duration::from_secs(60) {
                        window = Instant::now();
                        requests = 0;
                    }
                    requests += 1;
                    anyhow::ensure!(requests <= 120, "control rate exceeded");
                    self.message(&fingerprint, &connection, &out, message)?;
                }
                #[allow(unreachable_code)]
                Ok::<(), anyhow::Error>(())
            };
            let writer = async {
                while let Some(message) = messages.recv().await {
                    tokio::time::timeout(
                        Duration::from_secs(10),
                        protocol::write(&mut send, &message),
                    )
                    .await??;
                }
                Ok::<(), anyhow::Error>(())
            };
            let datagrams = async {
                // One budget per connection, shared by its sessions: 2 MiB/s, no unbounded queues.
                let mut budget = Budget::new();
                loop {
                    let bytes = connection.read_datagram().await?;
                    if bytes.len() < MIN_PIECE
                        || bytes.len() > MAX_PIECE
                        || !budget.take(bytes.len())
                    {
                        continue;
                    }
                    let Ok(id) = Uuid::from_slice(&bytes[..16]) else {
                        continue;
                    };
                    let target =
                        self.state
                            .lock()
                            .unwrap()
                            .route(id, &fingerprint, connection.stable_id());
                    if let Some(target) = target {
                        // Datagrams are lossy: a full send buffer drops, and the inner session retransmits.
                        let _ = target.send_datagram(bytes);
                    }
                }
                #[allow(unreachable_code)]
                Ok::<(), anyhow::Error>(())
            };
            tokio::select! { r = reader => r, r = writer => r, r = datagrams => r }
        }
        .await;
        let _ = result; // Never log device identities, addresses, or packet content.
        connection.close(0u32.into(), b"control connection ended");
        let mut state = self.state.lock().unwrap();
        if state
            .hosts
            .get(&fingerprint)
            .is_some_and(|h| h.connection.stable_id() == connection.stable_id())
        {
            state.hosts.remove(&fingerprint);
        }
        let ids: Vec<_> = state
            .sessions
            .iter()
            .filter(|(_, s)| {
                s.owner == connection.stable_id()
                    || (s.host == fingerprint && !state.hosts.contains_key(&fingerprint))
            })
            .map(|(id, _)| *id)
            .collect();
        for id in ids {
            state.remove(id);
        }
    }
    fn message(
        self: &Arc<Self>,
        fp: &str,
        conn: &Connection,
        out: &Outbox,
        message: Message,
    ) -> anyhow::Result<()> {
        let mut state = self.state.lock().unwrap();
        state.prune();
        match message {
            Message::Register { .. } => {
                anyhow::ensure!(!state.hosts.contains_key(fp), "already registered");
                state.hosts.insert(
                    fp.into(),
                    Host {
                        connection: conn.clone(),
                        outbox: out.clone(),
                        allowed: HashSet::new(),
                    },
                );
                out.try_send(Message::Pong)?;
            }
            Message::Allow { fingerprints } => {
                anyhow::ensure!(
                    fingerprints.len() <= 64
                        && fingerprints.iter().all(|s| protocol::fingerprint(s)),
                    "invalid allow list"
                );
                let host = state
                    .hosts
                    .get_mut(fp)
                    .ok_or_else(|| anyhow::anyhow!("register first"))?;
                anyhow::ensure!(
                    host.connection.stable_id() == conn.stable_id(),
                    "registration owned by another connection"
                );
                host.allowed = fingerprints.into_iter().collect();
                let revoked: Vec<_> = state
                    .sessions
                    .iter()
                    .filter(|(_, s)| s.host == fp && !state.hosts[fp].allowed.contains(&s.phone))
                    .map(|(id, _)| *id)
                    .collect();
                for id in revoked {
                    state.remove(id);
                }
                out.try_send(Message::Pong)?;
            }
            Message::Connect { host } => {
                let target = state.hosts.get(&host).filter(|h| h.allowed.contains(fp));
                let Some(target) = target else {
                    out.try_send(Message::NotFound)?;
                    return Ok(());
                };
                if state.sessions.values().filter(|s| s.host == host).count() >= 2 {
                    out.try_send(Message::Error {
                        reason: "sessionLimit".into(),
                    })?;
                    return Ok(());
                }
                let id = Uuid::new_v4();
                target.outbox.try_send(Message::Incoming {
                    phone: fp.into(),
                    session: id,
                })?;
                out.try_send(Message::Ready { session: id })?;
                state.sessions.insert(
                    id,
                    Session {
                        host,
                        phone: fp.into(),
                        owner: conn.stable_id(),
                        phone_connection: conn.clone(),
                        phone_out: out.clone(),
                        created: Instant::now(),
                        forwarding: None,
                    },
                );
            }
            Message::Allocate { session: id } => {
                let session = state.sessions.get(&id).filter(|s| {
                    s.phone == fp && s.owner == conn.stable_id() && s.forwarding.is_none()
                });
                let host = session
                    .and_then(|s| state.hosts.get(&s.host).filter(|h| h.allowed.contains(fp)));
                let Some(host) = host else {
                    out.try_send(Message::NotFound)?;
                    return Ok(());
                };
                host.outbox.try_send(Message::Forward { session: id })?;
                out.try_send(Message::Forward { session: id })?;
                state.sessions.get_mut(&id).unwrap().forwarding = Some(Instant::now());
            }
            Message::Close { session } => {
                if state.sessions.get(&session).is_some_and(|s| {
                    s.owner == conn.stable_id()
                        || (s.host == fp
                            && state
                                .hosts
                                .get(fp)
                                .is_some_and(|h| h.connection.stable_id() == conn.stable_id()))
                }) {
                    state.remove(session);
                }
            }
            Message::Ping => {
                out.try_send(Message::Pong)?;
            }
            _ => anyhow::bail!("unexpected control message"),
        }
        Ok(())
    }
}
struct Budget {
    start: Instant,
    bytes: usize,
}
impl Budget {
    fn new() -> Self {
        Self {
            start: Instant::now(),
            bytes: 0,
        }
    }
    fn take(&mut self, count: usize) -> bool {
        if self.start.elapsed() >= Duration::from_secs(1) {
            self.start = Instant::now();
            self.bytes = 0;
        }
        if self.bytes + count > 2 * 1024 * 1024 {
            return false;
        }
        self.bytes += count;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustls::pki_types::{CertificateDer, PrivatePkcs8KeyDer};
    use std::net::SocketAddr;
    struct Peer {
        _endpoint: quinn::Endpoint,
        conn: Connection,
        send: quinn::SendStream,
        recv: quinn::RecvStream,
        fp: String,
    }
    fn identity() -> (
        CertificateDer<'static>,
        rustls::pki_types::PrivateKeyDer<'static>,
    ) {
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
        (
            cert.cert.der().clone(),
            PrivatePkcs8KeyDer::from(cert.signing_key.serialize_der()).into(),
        )
    }
    /// A piece as the devices send it: session ID, packet ID, index, count, payload.
    fn piece(session: Uuid, index: u8, count: u8, payload: &[u8]) -> Vec<u8> {
        let mut bytes = session.as_bytes().to_vec();
        bytes.extend_from_slice(Uuid::new_v4().as_bytes());
        bytes.extend_from_slice(&[index, count]);
        bytes.extend_from_slice(payload);
        bytes
    }
    impl Peer {
        async fn new(addr: SocketAddr, root: CertificateDer<'static>) -> Self {
            let (cert, key) = identity();
            let fp = hex::encode(Sha256::digest(cert.as_ref()));
            let mut roots = rustls::RootCertStore::empty();
            roots.add(root).unwrap();
            let mut tls = rustls::ClientConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap()
            .with_root_certificates(roots)
            .with_client_auth_cert(vec![cert], key)
            .unwrap();
            tls.alpn_protocols = vec![crate::tls::ALPN.to_vec()];
            let config = quinn::ClientConfig::new(Arc::new(
                quinn::crypto::rustls::QuicClientConfig::try_from(tls).unwrap(),
            ));
            let mut endpoint = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
            endpoint.set_default_client_config(config);
            let conn = endpoint.connect(addr, "localhost").unwrap().await.unwrap();
            let (send, recv) = conn.open_bi().await.unwrap();
            Self {
                _endpoint: endpoint,
                conn,
                send,
                recv,
                fp,
            }
        }
        async fn send(&mut self, m: Message) {
            protocol::write(&mut self.send, &m).await.unwrap();
        }
        async fn next(&mut self) -> Message {
            tokio::time::timeout(Duration::from_secs(3), protocol::read(&mut self.recv))
                .await
                .unwrap()
                .unwrap()
        }
        async fn datagram(&self) -> Vec<u8> {
            tokio::time::timeout(Duration::from_secs(3), self.conn.read_datagram())
                .await
                .unwrap()
                .unwrap()
                .to_vec()
        }
        async fn no_datagram(&self) -> bool {
            tokio::time::timeout(Duration::from_millis(150), self.conn.read_datagram())
                .await
                .is_err()
        }
    }

    #[tokio::test]
    async fn quic_forwarding_authorization_revocation_and_disconnect() {
        let (cert, key) = identity();
        let endpoint = quinn::Endpoint::server(
            crate::tls::server(vec![cert.clone()], key).unwrap(),
            "127.0.0.1:0".parse().unwrap(),
        )
        .unwrap();
        let addr = endpoint.local_addr().unwrap();
        let relay = Arc::new(Relay::new());
        let r = relay.clone();
        let accept = tokio::spawn(async move {
            while let Some(incoming) = endpoint.accept().await {
                let r = r.clone();
                tokio::spawn(async move {
                    if let Ok(c) = incoming.await {
                        r.serve(c).await;
                    }
                });
            }
        });
        let mut host = Peer::new(addr, cert.clone()).await;
        host.send(Message::Register {
            host_id: Uuid::new_v4(),
        })
        .await;
        assert!(matches!(host.next().await, Message::Pong));
        let mut phone = Peer::new(addr, cert.clone()).await;
        phone
            .send(Message::Connect {
                host: host.fp.clone(),
            })
            .await;
        assert!(matches!(phone.next().await, Message::NotFound));
        host.send(Message::Allow {
            fingerprints: vec![phone.fp.clone()],
        })
        .await;
        assert!(matches!(host.next().await, Message::Pong));
        phone
            .send(Message::Connect {
                host: host.fp.clone(),
            })
            .await;
        let Message::Ready { session } = phone.next().await else {
            panic!("expected ready")
        };
        assert!(matches!(host.next().await, Message::Incoming { .. }));
        // Pending sessions count toward the same per-host capacity as forwarded ones.
        phone
            .send(Message::Connect {
                host: host.fp.clone(),
            })
            .await;
        let Message::Ready { session: second } = phone.next().await else {
            panic!("expected ready")
        };
        assert!(matches!(host.next().await, Message::Incoming { .. }));
        phone
            .send(Message::Connect {
                host: host.fp.clone(),
            })
            .await;
        assert!(
            matches!(phone.next().await, Message::Error { reason } if reason == "sessionLimit")
        );
        phone.send(Message::Close { session: second }).await;
        assert!(matches!(phone.next().await, Message::Close { .. }));
        assert!(matches!(host.next().await, Message::Close { .. }));

        // Nothing is forwarded before the phone asks.
        let early = piece(session, 0, 1, &[1; 100]);
        phone.conn.send_datagram(early.into()).unwrap();
        assert!(host.no_datagram().await);

        let mut stranger = Peer::new(addr, cert).await;
        stranger.send(Message::Allocate { session }).await;
        assert!(matches!(stranger.next().await, Message::NotFound));
        phone.send(Message::Allocate { session }).await;
        assert!(matches!(phone.next().await, Message::Forward { session: s } if s == session));
        assert!(matches!(host.next().await, Message::Forward { session: s } if s == session));

        // Full-size pieces pass unchanged both ways.
        let up = piece(session, 0, 2, &[42; 1000]);
        phone.conn.send_datagram(up.clone().into()).unwrap();
        assert_eq!(host.datagram().await, up);
        let down = piece(session, 1, 2, &[7; 200]);
        host.conn.send_datagram(down.clone().into()).unwrap();
        assert_eq!(phone.datagram().await, down);

        // A connection outside the session can't inject into it, even knowing its ID.
        stranger
            .conn
            .send_datagram(piece(session, 0, 1, &[9; 50]).into())
            .unwrap();
        assert!(host.no_datagram().await);
        assert!(phone.no_datagram().await);

        host.send(Message::Allow {
            fingerprints: vec![],
        })
        .await;
        assert!(matches!(phone.next().await, Message::Close { .. }));
        assert!(matches!(host.next().await, Message::Close { .. }));
        assert!(matches!(host.next().await, Message::Pong));
        assert!(relay.state.lock().unwrap().sessions.is_empty());
        phone
            .conn
            .send_datagram(piece(session, 0, 1, &[3; 50]).into())
            .unwrap();
        assert!(host.no_datagram().await);
        phone.send(Message::Allocate { session }).await;
        assert!(matches!(phone.next().await, Message::NotFound));
        host.conn.close(0u32.into(), b"test");
        tokio::time::timeout(Duration::from_secs(3), async {
            while !relay.state.lock().unwrap().hosts.is_empty() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        accept.abort();
    }
}
