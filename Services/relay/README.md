# PocketDesk relay

Rust server using Quinn, Tokio and rustls. Implements the forwarding phase of
[the relay design](../../docs/RELAY.md): device registration, replacement allow lists,
authorized connection requests, and opaque datagram forwarding between the two devices'
QUIC connections. State stays in memory.

The apps include the Mac relay agent and loopback shim, the iPhone LAN-first fallback,
and Remote Access settings. Remote access is off by default. Run a relay with a valid TLS
certificate, save the same hostname/port on both devices, then enable it on each. Pair on
the LAN first and keep the Mac awake. There is no bundled public relay address.

Direct candidate exchange/hole punching, multi-region presence and production monitoring
remain future work.

## Run

Install Rust, obtain a server certificate for your relay hostname, then:

```sh
cargo run --release --locked -- \
  --listen 0.0.0.0:4433 --cert fullchain.pem --key privkey.pem
```

Run from this directory. Allow UDP 4433 in the host firewall; a TCP-only proxy will not
work. Deploy on a host with a public address and direct UDP access. All traffic, control and
forwarded, uses that one port. IPv4 and IPv6 deployments can run separate instances. Ctrl-C
closes control connections and sessions.

Use a PEM private key in PKCS#8 format with named curves for EC keys.
Clients must validate the relay's hostname/certificate. The relay requires client certificates
and TLS 1.3 proof of private-key possession, but deliberately does not require a CA chain or
certificate validity dates for device identities. It hashes the exact DER leaf certificate
with SHA-256. Only the registered Mac's allow list grants forwarding access. This follows
PocketDesk's existing pinned-certificate identity model; local pairing creates trust.
The inner phone-to-Mac session retains its existing mutual TLS and certificate pinning.

## Wire contract (`pocketdesk-relay/2`)

One client-opened bidirectional stream, four-byte unsigned big-endian length followed by
UTF-8 JSON (1–16384 bytes). The discriminator is `type`, camel case. UUID values are strings;
fingerprints are exactly 64 lowercase hex digits of SHA-256 DER (not the UI abbreviation).

Client requests:

```json
{"type":"register","hostID":"00000000-0000-0000-0000-000000000001"}
{"type":"allow","fingerprints":["0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"]}
{"type":"connect","host":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
{"type":"allocate","session":"00000000-0000-0000-0000-000000000002"}
{"type":"close","session":"00000000-0000-0000-0000-000000000002"}
{"type":"ping"}
```

Macs can also ask the relay to deliver a Now Playing Live Activity push to Apple (see
"Live Activity pushes" below):

```json
{"type":"push","id":"00000000-0000-0000-0000-000000000003","phone":"<64 hex>","token":"<device token hex>","environment":"sandbox","topic":"app.pocketdesk.app.push-type.liveactivity","payload":"{\"aps\":{…}}"}
{"type":"pushed","id":"00000000-0000-0000-0000-000000000003","status":200}
```

Register/allow reply with `pong`. Connect replies `ready(session)` to the phone and
`incoming(phone, session)` to the Mac; absent and unauthorized hosts both return `notFound`.
Allocate replies `forward(session)` to both. Only the requesting control connection can
allocate. Close is allowed for either session participant. Revocation, expiry and
disconnect send `close(session)`. Duplicate registration closes the newer control connection.
Invalid messages close the control connection; exhausted session capacity returns
`error(reason: "sessionLimit")`. No direct candidates are exchanged in this phase.

Once forwarding is on, both devices send the session's packets as QUIC DATAGRAM frames on
their relay connection, and the relay passes each one to the other device's connection
unchanged. It forwards only between the session's two participants, and only while the Mac
allows the phone; datagrams from any other connection are dropped. Version 1 carried the
phone's packets as raw UDP with a 16-byte token on a separate port; version 2 removes the
token and the port pool, and keeps every public UDP packet within 1,200 bytes.

Datagram wire packets, in both directions: **16 raw session UUID bytes + 16 raw
packet UUID bytes + one fragment index byte + one fragment count byte + payload fragment**.
Payloads up to 1000 bytes have index 0/count 1. Larger packets split into a 1000-byte first
fragment and remainder, index 0/1, count 2. Each packet gets a fresh UUID. The receiving
device reassembles before passing to its loopback shim; the relay doesn't reassemble. The inner UDP payload limit is 1500 bytes; configure the shim's
inner QUIC MTU accordingly. Fragmentation lets 1200-byte QUIC Initial packets fit inside the
outer QUIC connection without increasing its minimum MTU. Devices expire incomplete packets
after one second and buffer one pending packet per session.
Datagrams are lossy; inner QUIC handles loss and retransmission.

## Live Activity pushes

The APNs key can't ship in the open-source Mac app, so the relay holds it and sends for Macs.
A `push` is sent only if it comes from the connection that registered the Mac, for a phone on
that Mac's allow list, to a topic in `APNS_TOPICS`, with a hex token and an `aps` object of at
most 4 KB. The relay signs an ES256 provider token (refreshed every 50 minutes), posts it over
HTTP/2 to Apple's sandbox or production server with `apns-push-type: liveactivity`, and replies
`pushed` with Apple's status and reason. It refuses with its own: `400` (`notPaired`,
`badToken`, `badEnvironment`, `badTopic`, `badPayload`), `429` (`pushLimit`, 60 per Mac per
minute) and `503` (`pushUnavailable`, no key). Payloads are never logged.

Push content isn't end-to-end encrypted: the relay and Apple can read the titles and site
names in it. Phones turn this off in Settings › Now Playing.

Configure with environment variables (Fly secrets), never arguments or files in the image:

| Variable | What |
|---|---|
| `APNS_KEY` | The `.p8` auth key's PEM text. Without it pushes are refused. |
| `APNS_KEY_ID` | Its Key ID. |
| `APNS_TEAM_ID` | The Apple team that owns the key and the app. |
| `APNS_TOPICS` | Comma-separated topics Macs may push to: `<bundle ID>.push-type.liveactivity`. |

## Limits and validation

- 1024 concurrent control connections/handshakes by default (`--max-connections`).
- 10-second handshake/first-stream/write deadlines; 60-second control inactivity timeout.
  Send ping every 25 seconds (transport keepalive does not replace application ping).
- At most 64 allowed phones and two pending/forwarded sessions per Mac.
- 120 control messages per minute per connection, with a bounded 32-message output queue.
- Pending requests expire after 60 seconds; forwarding expires after 60 seconds without
  forwarded phone packets. Dropped packets do not refresh the deadline.
- 2 MiB/s of datagrams per connection, dropping excess.
- Forget/replaced allow lists and control disconnects end the session.
- No device, address or payload logging; only the startup listen address is printed.

```sh
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
cargo fmt --check
```

Tests use real local Quinn mutual-TLS connections: unknown/unpaired hosts, session ownership,
full-size piece forwarding both ways, no forwarding before allocation, refusing pieces from
outside the session, revocation and host disconnect cleanup. Rust and Swift decode and re-encode the same JSON
fixtures under `Packages/PocketDeskKit/Tests/PDProtocolTests/Fixtures`.

For the native Apple QUIC ↔ Quinn integration test, run from the repository root on macOS:

```sh
cargo build --locked --manifest-path Services/relay/Cargo.toml
POCKETDESK_RELAY_BINARY="$PWD/Services/relay/target/debug/pocketdesk-relay" \
  swift test --package-path Packages/PocketDeskKit --filter RelayIntegrationTests
```

That test creates throwaway certificates/Keychain identities and a local relay process. It
verifies LAN failure → relay fallback, the pinned inner session, video/audio/input,
unpaired rejection and revocation. CI runs it before the broader native package tests.
The Mac uses a separate unadvertised, packet-bounded QUIC listener for relayed sessions,
with the same HostService handlers and a pinned-only TLS gate. The LAN listener retains its
existing settings. A session through the deployed relay works end to end, but is slow: about
one full-size packet in five is lost while streaming (see "Open questions" in the design).
This is a single-instance implementation, not a production launch.

To measure throughput, `RelayThroughputTests` streams 1.2 MB of video through a local relay
(`POCKETDESK_RELAY_BINARY`) or the deployed one (`POCKETDESK_RELAY_REMOTE=host:port`).

## Fly.io

See [deploy/FLY.md](deploy/FLY.md) and `fly.toml`. The container includes automatic public
certificate management and non-disruptive certificate reloads. `--listen` accepts a hostname,
including Fly's `fly-global-services` alias.
