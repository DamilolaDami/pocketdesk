//! Live Activity pushes to Apple, for Macs that ask (`push`). The key is the operator's: it
//! comes from the environment (Fly secrets), never from a client, an argument or a log.
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use p256::ecdsa::{Signature, SigningKey, signature::Signer};
use p256::pkcs8::DecodePrivateKey;
use std::{
    collections::HashSet,
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

/// What Apple accepts for a Live Activity push.
pub const MAX_PAYLOAD: usize = 4096;
/// Apple wants a fresh provider token at least hourly and no more than every 20 minutes.
const TOKEN_LIFETIME: Duration = Duration::from_secs(50 * 60);

pub struct Apns {
    key: SigningKey,
    key_id: String,
    team_id: String,
    /// `apns-topic`s Macs may push to: the operator's apps, `<bundle ID>.push-type.liveactivity`.
    pub topics: HashSet<String>,
    client: reqwest::Client,
    token: Mutex<Option<(String, Instant)>>,
}

impl Apns {
    /// From `APNS_KEY` (the .p8's PEM), `APNS_KEY_ID`, `APNS_TEAM_ID` and `APNS_TOPICS`
    /// (comma separated). `None` when there's no key: pushes are then refused.
    pub fn from_env() -> anyhow::Result<Option<Self>> {
        let Ok(pem) = std::env::var("APNS_KEY") else {
            return Ok(None);
        };
        let var = |name: &str| {
            std::env::var(name)
                .ok()
                .filter(|v| !v.trim().is_empty())
                .ok_or_else(|| anyhow::anyhow!("{name} must be set with APNS_KEY"))
        };
        let topics = var("APNS_TOPICS")?
            .split(',')
            .map(|t| t.trim().to_owned())
            .filter(|t| !t.is_empty())
            .collect();
        Self::new(&pem, &var("APNS_KEY_ID")?, &var("APNS_TEAM_ID")?, topics).map(Some)
    }

    pub fn new(
        pem: &str,
        key_id: &str,
        team_id: &str,
        topics: HashSet<String>,
    ) -> anyhow::Result<Self> {
        let key = SigningKey::from_pkcs8_pem(pem.trim())
            .map_err(|_| anyhow::anyhow!("APNS_KEY isn't a PKCS#8 P-256 key"))?;
        let client = reqwest::Client::builder()
            .http2_prior_knowledge()
            .timeout(Duration::from_secs(10))
            .build()?;
        Ok(Self {
            key,
            key_id: key_id.into(),
            team_id: team_id.into(),
            topics,
            client,
            token: Mutex::new(None),
        })
    }

    fn bearer(&self) -> String {
        let mut cached = self.token.lock().unwrap();
        if let Some((token, made)) = cached.as_ref()
            && made.elapsed() < TOKEN_LIFETIME
        {
            return token.clone();
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        let token = jwt(&self.key, &self.key_id, &self.team_id, now);
        *cached = Some((token.clone(), Instant::now()));
        token
    }

    /// Apple's HTTP status and, when it refused, its reason ("BadDeviceToken").
    pub async fn send(
        &self,
        sandbox: bool,
        token: &str,
        topic: &str,
        payload: String,
        priority: u8,
    ) -> (u16, Option<String>) {
        let host = if sandbox {
            "api.sandbox.push.apple.com"
        } else {
            "api.push.apple.com"
        };
        let response = self
            .client
            .post(format!("https://{host}/3/device/{token}"))
            .header("authorization", format!("bearer {}", self.bearer()))
            .header("apns-topic", topic)
            .header("apns-push-type", "liveactivity")
            .header("apns-priority", priority.to_string())
            .body(payload)
            .send()
            .await;
        match response {
            Ok(response) => {
                let status = response.status().as_u16();
                if status == 200 {
                    return (200, None);
                }
                let reason = response
                    .bytes()
                    .await
                    .ok()
                    .and_then(|body| serde_json::from_slice::<serde_json::Value>(&body).ok())
                    .and_then(|v| v.get("reason").and_then(|r| r.as_str()).map(str::to_owned));
                if status == 403 {
                    // A stale or rejected provider token: make a new one next time.
                    *self.token.lock().unwrap() = None;
                }
                (status, reason)
            }
            Err(_) => (502, Some("apnsUnreachable".into())),
        }
    }
}

/// An ES256 provider token: `{"alg":"ES256","kid":…}.{"iss":team,"iat":…}`, signed raw r‖s.
pub fn jwt(key: &SigningKey, key_id: &str, team_id: &str, issued_at: u64) -> String {
    let header =
        URL_SAFE_NO_PAD.encode(serde_json::json!({"alg": "ES256", "kid": key_id}).to_string());
    let claims =
        URL_SAFE_NO_PAD.encode(serde_json::json!({"iss": team_id, "iat": issued_at}).to_string());
    let input = format!("{header}.{claims}");
    let signature: Signature = key.sign(input.as_bytes());
    format!("{input}.{}", URL_SAFE_NO_PAD.encode(signature.to_bytes()))
}

/// A push a Mac asked for, checked before anything goes to Apple. The phone must be one the
/// Mac allows (it paired them), the topic one of the operator's, and the token and payload
/// what Apple would take.
pub fn check(
    phone_allowed: bool,
    token: &str,
    environment: &str,
    topic: &str,
    payload: &str,
    topics: &HashSet<String>,
    priority: Option<u8>,
) -> Result<(), &'static str> {
    if priority.is_some_and(|p| p != 5 && p != 10) {
        return Err("badPriority");
    }
    if !phone_allowed {
        return Err("notPaired");
    }
    if !(64..=200).contains(&token.len())
        || !token.len().is_multiple_of(2)
        || !token.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err("badToken");
    }
    if environment != "sandbox" && environment != "production" {
        return Err("badEnvironment");
    }
    if !topics.contains(topic) {
        return Err("badTopic");
    }
    let is_object = serde_json::from_str::<serde_json::Value>(payload)
        .is_ok_and(|v| v.get("aps").is_some_and(|a| a.is_object()));
    if payload.len() > MAX_PAYLOAD || !is_object {
        return Err("badPayload");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::ecdsa::{VerifyingKey, signature::Verifier};
    use p256::pkcs8::EncodePrivateKey;

    #[test]
    fn provider_tokens_are_es256_and_verify() {
        let key = SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
        let token = jwt(&key, "ABC123DEFG", "TEAM123456", 1_700_000_000);
        let parts: Vec<_> = token.split('.').collect();
        assert_eq!(parts.len(), 3);
        let header: serde_json::Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[0]).unwrap()).unwrap();
        assert_eq!(
            header,
            serde_json::json!({"alg": "ES256", "kid": "ABC123DEFG"})
        );
        let claims: serde_json::Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
        assert_eq!(
            claims,
            serde_json::json!({"iss": "TEAM123456", "iat": 1_700_000_000})
        );
        let signature = Signature::from_slice(&URL_SAFE_NO_PAD.decode(parts[2]).unwrap()).unwrap();
        VerifyingKey::from(&key)
            .verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &signature)
            .unwrap();
    }

    #[test]
    fn pushes_are_checked_before_apple_sees_them() {
        let topics: HashSet<String> =
            ["app.pocketdesk.app.push-type.liveactivity".to_owned()].into();
        let topic = "app.pocketdesk.app.push-type.liveactivity";
        let token = "ab".repeat(40);
        let payload = r#"{"aps":{"event":"start"}}"#;
        assert_eq!(
            check(true, &token, "sandbox", topic, payload, &topics, None),
            Ok(())
        );
        assert_eq!(
            check(false, &token, "sandbox", topic, payload, &topics, None),
            Err("notPaired")
        );
        assert_eq!(
            check(true, "xyz", "sandbox", topic, payload, &topics, None),
            Err("badToken")
        );
        assert_eq!(
            check(true, &token, "staging", topic, payload, &topics, None),
            Err("badEnvironment")
        );
        assert_eq!(
            check(
                true,
                &token,
                "sandbox",
                "com.other.app.push-type.liveactivity",
                payload,
                &topics,
                None
            ),
            Err("badTopic")
        );
        assert_eq!(
            check(true, &token, "sandbox", topic, "[1]", &topics, None),
            Err("badPayload")
        );
        for priority in [0, 1, 9, 11, 255] {
            assert_eq!(
                check(
                    true,
                    &token,
                    "sandbox",
                    topic,
                    payload,
                    &topics,
                    Some(priority)
                ),
                Err("badPriority")
            );
        }
        for priority in [5, 10] {
            assert_eq!(
                check(
                    true,
                    &token,
                    "production",
                    topic,
                    payload,
                    &topics,
                    Some(priority)
                ),
                Ok(())
            );
        }
        let huge = format!(r#"{{"aps":{{"x":"{}"}}}}"#, "a".repeat(MAX_PAYLOAD));
        assert_eq!(
            check(true, &token, "sandbox", topic, &huge, &topics, None),
            Err("badPayload")
        );
    }

    #[test]
    fn keys_must_be_p256_pkcs8() {
        assert!(Apns::new("not a key", "K", "T", HashSet::new()).is_err());
        let key = SigningKey::random(&mut p256::elliptic_curve::rand_core::OsRng);
        let pem = key.to_pkcs8_pem(p256::pkcs8::LineEnding::LF).unwrap();
        assert!(Apns::new(&pem, "K", "T", HashSet::new()).is_ok());
    }
}
