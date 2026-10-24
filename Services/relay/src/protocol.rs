use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const MAX_MESSAGE: usize = 16 * 1024;
/// JSON objects framed by a four-byte, big-endian byte length. Fingerprints are lowercase
/// hex SHA-256 of DER leaf certificates (not display abbreviations). No client-supplied identity.
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase", deny_unknown_fields)]
pub enum Message {
    Register {
        #[serde(rename = "hostID")]
        host_id: Uuid,
    },
    Allow {
        fingerprints: Vec<String>,
    },
    Connect {
        host: String,
    },
    Incoming {
        phone: String,
        session: Uuid,
    },
    Ready {
        session: Uuid,
    },
    Allocate {
        session: Uuid,
    },
    /// Forwarding is on: from now the phone's and the Mac's pieces for this session are
    /// passed between their QUIC connections as datagrams.
    Forward {
        session: Uuid,
    },
    Close {
        session: Uuid,
    },
    NotFound,
    Error {
        reason: String,
    },
    Ping,
    Pong,
}
pub fn fingerprint(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub async fn read(recv: &mut quinn::RecvStream) -> anyhow::Result<Message> {
    let mut header = [0; 4];
    recv.read_exact(&mut header).await?;
    let length = u32::from_be_bytes(header) as usize;
    anyhow::ensure!(length > 0 && length <= MAX_MESSAGE, "invalid message size");
    let mut bytes = vec![0; length];
    recv.read_exact(&mut bytes).await?;
    Ok(serde_json::from_slice(&bytes)?)
}
pub async fn write(send: &mut quinn::SendStream, message: &Message) -> anyhow::Result<()> {
    let bytes = serde_json::to_vec(message)?;
    anyhow::ensure!(bytes.len() <= MAX_MESSAGE, "message too large");
    send.write_all(&(bytes.len() as u32).to_be_bytes()).await?;
    send.write_all(&bytes).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn strict_messages_and_full_fingerprints() {
        assert!(fingerprint(&"a1".repeat(32)));
        assert!(!fingerprint(&"A1".repeat(32)));
        assert!(!fingerprint("3F9A·C21B·77D0"));
        assert!(
            serde_json::from_str::<Message>(
                r#"{"type":"connect","host":"abc","identity":"forged"}"#
            )
            .is_err()
        );
        let register = Message::Register {
            host_id: Uuid::nil(),
        };
        assert_eq!(
            serde_json::to_value(register).unwrap(),
            serde_json::json!({"type":"register","hostID":"00000000-0000-0000-0000-000000000000"})
        );
    }
}

#[cfg(test)]
#[test]
fn swift_fixtures_match_server_contract() {
    let fixtures: Vec<serde_json::Value> = serde_json::from_str(include_str!(
        "../../../Packages/PocketDeskKit/Tests/PDProtocolTests/Fixtures/relay-messages.json"
    ))
    .unwrap();
    for value in fixtures {
        let message: Message = serde_json::from_value(value.clone()).unwrap();
        assert_eq!(serde_json::to_value(message).unwrap(), value);
    }
}
