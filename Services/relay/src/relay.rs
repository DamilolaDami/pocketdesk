use crate::protocol::{self, MAX_PACKET, Message};
use quinn::Connection;
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    net::{IpAddr, SocketAddr},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::{net::UdpSocket, sync::mpsc};
use uuid::Uuid;

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
    phone_out: Outbox,
    created: Instant,
    allocation: Option<Allocation>,
}
struct Allocation {
    socket: Arc<UdpSocket>,
    token: Uuid,
    peer: Option<SocketAddr>,
    task: tokio::task::AbortHandle,
}
#[derive(Default)]
struct State {
    hosts: HashMap<String, Host>,
    sessions: HashMap<Uuid, Session>,
}
impl State {
    fn remove(&mut self, id: Uuid) {
        if let Some(session) = self.sessions.remove(&id) {
            if let Some(a) = session.allocation {
                a.task.abort();
            }
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
            .filter(|(_, s)| {
                s.allocation.is_none() && s.created.elapsed() > Duration::from_secs(60)
            })
            .map(|(id, _)| *id)
            .collect();
        for id in expired {
            self.remove(id);
        }
    }
}
pub struct Relay {
    bind: IpAddr,
    state: Mutex<State>,
}
impl Relay {
    pub fn new(bind: IpAddr) -> Self {
        Self {
            bind,
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
                    self.message(&fingerprint, &connection, &out, message)
                        .await?;
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
                // Shared budget for all sessions on this host: 2 MiB/s, no unbounded queues.
                let mut budget = Budget::new();
                let mut assembly = crate::packets::Assembler::default();
                loop {
                    let bytes = connection.read_datagram().await?;
                    if bytes.len() <= 34 || bytes.len() > 1034 || !budget.take(bytes.len()) {
                        continue;
                    }
                    let id = Uuid::from_slice(&bytes[..16])?;
                    let target = {
                        let state = self.state.lock().unwrap();
                        state
                            .sessions
                            .get(&id)
                            .filter(|s| s.host == fingerprint)
                            .and_then(|s| s.allocation.as_ref())
                            .and_then(|a| a.peer.map(|p| (a.socket.clone(), p, a.token)))
                    };
                    if let Some((socket, peer, token)) = target {
                        let Some(payload) = assembly.push(&bytes) else {
                            continue;
                        };
                        let mut packet = Vec::with_capacity(bytes.len());
                        packet.extend_from_slice(token.as_bytes());
                        packet.extend_from_slice(&payload);
                        let _ = socket.send_to(&packet, peer).await;
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
    async fn message(
        self: &Arc<Self>,
        fp: &str,
        conn: &Connection,
        out: &Outbox,
        message: Message,
    ) -> anyhow::Result<()> {
        if let Message::Allocate { session } = message {
            return self.allocate(fp, conn, out, session).await;
        }
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
                        phone_out: out.clone(),
                        created: Instant::now(),
                        allocation: None,
                    },
                );
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
    async fn allocate(
        self: &Arc<Self>,
        fp: &str,
        conn: &Connection,
        out: &Outbox,
        id: Uuid,
    ) -> anyhow::Result<()> {
        // Bind before taking the state lock; recheck ownership and authorization after awaiting.
        let socket = Arc::new(UdpSocket::bind(SocketAddr::new(self.bind, 0)).await?);
        let port = socket.local_addr()?.port();
        let token = Uuid::new_v4();
        let mut state = self.state.lock().unwrap();
        state.prune();
        let Some(session) = state
            .sessions
            .get(&id)
            .filter(|s| s.phone == fp && s.owner == conn.stable_id() && s.allocation.is_none())
        else {
            out.try_send(Message::NotFound)?;
            return Ok(());
        };
        let Some(host) = state
            .hosts
            .get(&session.host)
            .filter(|h| h.allowed.contains(fp))
        else {
            out.try_send(Message::NotFound)?;
            return Ok(());
        };
        host.outbox.try_send(Message::Forward {
            session: id,
            port,
            token: token.simple().to_string(),
        })?;
        out.try_send(Message::Forward {
            session: id,
            port,
            token: token.simple().to_string(),
        })?;
        let host_conn = host.connection.clone();
        let relay = self.clone();
        let task_socket = socket.clone();
        let task = tokio::spawn(async move {
            let mut bytes = [0u8; MAX_PACKET + 17];
            let mut last = Instant::now();
            let mut budget = Budget::new();
            loop {
                let read =
                    tokio::time::timeout(Duration::from_secs(1), task_socket.recv_from(&mut bytes))
                        .await;
                if last.elapsed() >= Duration::from_secs(60) {
                    break;
                }
                let Ok(Ok((len, peer))) = read else { continue };
                if len <= 16
                    || len > MAX_PACKET + 16
                    || bytes[..16] != token.as_bytes()[..]
                    || !budget.take(len)
                {
                    continue;
                }
                let accepted = {
                    let mut state = relay.state.lock().unwrap();
                    let Some(a) = state
                        .sessions
                        .get_mut(&id)
                        .and_then(|s| s.allocation.as_mut())
                    else {
                        break;
                    };
                    if a.peer.is_none() {
                        a.peer = Some(peer);
                    }
                    a.peer == Some(peer)
                };
                if !accepted {
                    continue;
                }
                last = Instant::now();
                for packet in crate::packets::encode(id, &bytes[16..len]) {
                    let _ = host_conn.send_datagram(packet.into());
                }
            }
            relay.state.lock().unwrap().remove(id);
        });
        state.sessions.get_mut(&id).unwrap().allocation = Some(Allocation {
            socket,
            token,
            peer: None,
            task: task.abort_handle(),
        });
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
            tls.alpn_protocols = vec![b"pocketdesk-relay/1".to_vec()];
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
        let relay = Arc::new(Relay::new(addr.ip()));
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
        // Pending sessions count toward the same per-host capacity as allocations.
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
        let mut stranger = Peer::new(addr, cert).await;
        stranger.send(Message::Allocate { session }).await;
        assert!(matches!(stranger.next().await, Message::NotFound));
        phone.send(Message::Allocate { session }).await;
        let Message::Forward { port, token, .. } = phone.next().await else {
            panic!("expected forwarding")
        };
        assert!(matches!(host.next().await, Message::Forward { .. }));
        let udp = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let token = hex::decode(token).unwrap();
        let payload = vec![42; 1500];
        let mut packet = token.clone();
        packet.extend_from_slice(&payload);
        udp.send_to(&packet, SocketAddr::new(addr.ip(), port))
            .await
            .unwrap();
        let mut assembler = crate::packets::Assembler::default();
        let received = tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let fragment = host.conn.read_datagram().await.unwrap();
                if let Some(packet) = assembler.push(&fragment) {
                    break packet;
                }
            }
        })
        .await
        .unwrap();
        assert_eq!(received, payload);
        for p in crate::packets::encode(session, &payload) {
            host.conn.send_datagram(p.into()).unwrap();
        }
        let mut bytes = [0; 1600];
        let (len, _) = tokio::time::timeout(Duration::from_secs(3), udp.recv_from(&mut bytes))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&bytes[..len], packet.as_slice());
        // The allocation cannot be redirected by another UDP sender, even with the token.
        let other = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        other
            .send_to(&packet, SocketAddr::new(addr.ip(), port))
            .await
            .unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(100), host.conn.read_datagram())
                .await
                .is_err()
        );
        host.send(Message::Allow {
            fingerprints: vec![],
        })
        .await;
        assert!(matches!(phone.next().await, Message::Close { .. }));
        assert!(matches!(host.next().await, Message::Close { .. }));
        assert!(matches!(host.next().await, Message::Pong));
        assert!(relay.state.lock().unwrap().sessions.is_empty());
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
