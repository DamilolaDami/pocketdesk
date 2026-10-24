# PocketDesk relay

Rust server using Quinn, Tokio and rustls. Implements the forwarding phase of
[the relay design](../../docs/RELAY.md): device registration, replacement allow lists,
authorized connection requests, and opaque UDP forwarding. State stays in memory.

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

Run from this directory. Allow UDP 4433 and ephemeral UDP forwarding ports in the host
firewall; a TCP-only proxy will not work. Deploy on a host with a public address and direct
UDP access. `--listen` also selects the interface/address family for forwarding sockets.
Clients use that same public relay address with the returned port. IPv4 and IPv6 deployments
can run separate instances. Ctrl-C closes control connections and allocations.

Use a PEM private key in PKCS#8 format with named curves for EC keys.
Clients must validate the relay's hostname/certificate. The relay requires client certificates
and TLS 1.3 proof of private-key possession, but deliberately does not require a CA chain or
certificate validity dates for device identities. It hashes the exact DER leaf certificate
with SHA-256. Only the registered Mac's allow list grants forwarding access. This follows
PocketDesk's existing pinned-certificate identity model; local pairing creates trust.
The inner phone-to-Mac session retains its existing mutual TLS and certificate pinning.

## Wire contract (`pocketdesk-relay/1`)

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

Register/allow reply with `pong`. Connect replies `ready(session)` to the phone and
`incoming(phone, session)` to the Mac; absent and unauthorized hosts both return `notFound`.
Allocate replies `forward(session, port, token)` to both. The token is a random 128-bit secret,
encoded as 32 hex digits; it must never be logged. Only the requesting control connection
can allocate. Close is allowed for either session participant. Revocation, expiry and
disconnect send `close(session)`. Duplicate registration closes the newer control connection.
Invalid messages close the control connection; exhausted session capacity returns
`error(reason: "sessionLimit")`. No direct candidates are exchanged in this phase.

Phone UDP wire packets: **16 raw token bytes + opaque inner UDP payload**. The phone shim
adds/removes the token. The allocation locks to the first valid token-bearing sender's IP
and port; source changes require a new allocation. Unauthenticated packets cannot claim a port.

Mac QUIC DATAGRAM wire packets, in both directions: **16 raw session UUID bytes + 16 raw
packet UUID bytes + one fragment index byte + one fragment count byte + payload fragment**.
Payloads up to 1000 bytes have index 0/count 1. Larger packets split into a 1000-byte first
fragment and remainder, index 0/1, count 2. Each packet gets a fresh UUID. Reassemble before
passing to the loopback shim. The inner UDP payload limit is 1500 bytes; configure the shim's
inner QUIC MTU accordingly. Fragmentation lets 1200-byte QUIC Initial packets fit inside the
outer QUIC connection without increasing its minimum MTU. Incomplete packets expire after
one second; only one pending packet per session and two sessions per host are buffered.
Datagrams are lossy; inner QUIC handles loss and retransmission.

## Limits and validation

- 1024 concurrent control connections/handshakes by default (`--max-connections`).
- 10-second handshake/first-stream/write deadlines; 60-second control inactivity timeout.
  Send ping every 25 seconds (transport keepalive does not replace application ping).
- At most 64 allowed phones and two pending/forwarded sessions per Mac.
- 120 control messages per minute per connection, with a bounded 32-message output queue.
- Pending requests expire after 60 seconds; forwarding expires after 60 seconds without
  accepted phone packets. Invalid packets do not refresh the deadline.
- 2 MiB/s per allocation phone→Mac and 2 MiB/s per host Mac→phone, dropping excess.
- Forget/replaced allow lists and control disconnects tear down forwarding tasks and sockets.
- No device, address, payload or token logging; only startup listen address is printed.

```sh
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
cargo fmt --check
```

Tests use real local Quinn mutual-TLS connections and UDP sockets: unknown/unpaired hosts,
session ownership, full-size packet forwarding both ways, fragmentation, address locking,
revocation and host disconnect cleanup. Rust and Swift decode and re-encode the same JSON
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
existing settings. Cellular/NAT and physical-device verification remain outstanding.
This is a single-instance implementation, not a production launch.

## Fly.io

See [deploy/FLY.md](deploy/FLY.md) and `fly.toml`. The container includes automatic public
certificate management and non-disruptive certificate reloads. Use `--forward-ports START-END`
to keep allocations inside the public UDP port pool; omit it for direct hosts with unrestricted
ephemeral ports. `--listen` accepts a hostname, including Fly's `fly-global-services` alias.
