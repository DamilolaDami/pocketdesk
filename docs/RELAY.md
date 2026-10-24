# Relay: reaching your Mac away from home

Status: **forwarding server and native app integration implemented; network validation pending.** This is the plan for roadmap item v1.0 "Anywhere". It covers how
the relay works, what it can and can't see, what has to change in the apps, and the steps to
ship it. The checklist at the end tracks progress.

## Goal

Today the iPhone finds its Mac with Bonjour and connects straight to it, so both have to be on
the same network. The relay lets a paired iPhone reach its Mac from anywhere (another Wi-Fi
network, cellular, a hotel) with the same security it has at home.

**Non-goals for the first version:**

- Waking a sleeping Mac from outside the home network (see [Sleep](#sleep)).
- Accounts, sign-in or syncing anything through the relay.
- Reaching a Mac that isn't running PocketDesk.

## At a glance

```
                ┌────────────────────────────┐
                │           Relay            │
                │  rendezvous  +  forwarder  │
                └───▲─────────────────────▲──┘
   1. "Mac F, please" │                     │ 0. Mac registers, keeps a
      (signed)        │                     │    connection open (signed)
                 ┌────┴───┐             ┌───┴────┐
                 │ iPhone │═════════════│  Mac   │  2. direct QUIC, end to end (usual case)
                 └────┬───┘             └───┬────┘
                      └══════ Relay ════════┘      3. forwarded QUIC packets (fallback)
```

1. While PocketDesk for Mac runs, it keeps a small connection to the relay and says which iPhones
   may reach it.
2. Away from home, the iPhone asks the relay for its Mac. The relay gives each side the other's
   public address, and both try to connect directly (hole punching).
3. If a direct path can't be made, the relay forwards packets between them.

Either way the iPhone and Mac run **the same QUIC session as at home**, with TLS 1.3 and both
certificates pinned, end to end. The relay carries packets it can't read or change.

## Principles

- **The session doesn't change.** The relay sits below QUIC. `ControlMessage`, the media
  streams, input datagrams, the ALPN and pinning all stay exactly as they are on the LAN. A
  relayed session is just a QUIC connection to a different address.
- **The relay is a dumb pipe.** It never terminates the devices' TLS and holds no keys that could
  decrypt it. Compromising the relay gives an attacker metadata, not content or control.
- **Keys are the identity.** Devices prove who they are with the P-256 keys they already have
  (`DeviceIdentity`). There's no account, email or password.
- **Least metadata.** The relay keeps only what forwarding needs, in memory where it can, and
  logs no traffic.
- **The LAN always comes first.** If Bonjour finds the Mac, the relay isn't used.
- **Open source, self-hostable.** The server lives in `Services/relay`, and the apps can point
  at another relay address.

## Components

| Piece | Where | Job |
|---|---|---|
| Relay server | `Services/relay` | Rendezvous (who is where), the allow list, and UDP forwarding |
| Relay protocol | `PDProtocol` (new `Relay` types) | Messages between devices and the relay. No Apple frameworks, so the server can mirror them |
| Mac relay agent | `PDHostCore` (`RelayAgent`) | Registers the Mac, publishes the allow list, answers connection requests, punches, and runs the forwarding shim |
| Phone path picker | `PDClientCore` (`PathFinder`) | Tries Bonjour, then the relay: direct first, then forwarded. Hands `QUICClient.connect` an endpoint |
| Settings | both apps | "Reach this Mac from anywhere" on the Mac; the path in use shown on the phone |

## Identity and who may connect

Both devices connect to the relay over QUIC with mutual TLS using their **existing**
self-signed certificates. The relay learns each device's `Fingerprint` from the handshake and
never needs a password.

- **The Mac registers** its fingerprint and host ID, and sends an **allow list**: the
  fingerprints of the iPhones it has pinned. The list is replaced whenever pairing changes, so
  **Forget** on the Mac revokes relay access within seconds.
- **The iPhone asks** for a Mac by its fingerprint, which it pinned when pairing.
- **The relay only introduces** an iPhone to a Mac whose allow list includes it. Anyone else
  gets the same "not found" as for a Mac that doesn't exist, so the relay can't be used to probe
  which Macs are online.
- **Pairing stays local.** You still pair on the same network, in person, with the QR code and
  the six-digit code. The relay can't create trust; it only connects devices that already trust
  each other.

Even if the relay were compromised and introduced the wrong device, the end-to-end handshake
would fail, because each side only accepts the exact certificate it pinned.

## Connection flow

```
phone                          relay                             Mac
  │                              │ ◀── register(hostID, allow=[…]) ─│  (kept open, keepalive)
  │── Bonjour, 1.5 s ──▶ (nothing found)                            │
  │── connect(hostFP) ──────────▶│  allowed? yes                    │
  │                              │── incoming(phoneFP, phoneAddr) ─▶│
  │◀─ candidates(macAddr) ───────│◀─ candidates(macAddr) ───────────│
  │═══ punch: both send to each other at the same time ════════════▶│
  │═══ QUIC to macAddr, pinned, ALPN pocketdesk/<v> ═══════════════▶│  direct ✓
  │                              │                                  │
  │   (no answer after ~2 s)     │                                  │
  │── allocate ─────────────────▶│── open forward(phoneFP) ────────▶│
  │◀─ relayAddr:port ────────────│                                  │
  │═══ QUIC to relayAddr:port ══▶│═══ same packets, untouched ═════▶│  forwarded ✓
```

1. The phone tries Bonjour first, as it does today. Only if the Mac isn't found within a short
   timeout does it ask the relay.
2. The relay checks the allow list and tells the Mac a phone is coming.
3. Both learn each other's public address (from what the relay sees) and their local addresses,
   and try to reach each other directly.
4. If no direct path works within about two seconds, the phone asks the relay to forward, and
   its normal QUIC session runs through the relay.

## Forwarding

The relay forwards **sealed packets**, not decrypted data, much like a TURN server:

- On each device, the inner QUIC session talks to a loopback **shim**. The shim splits each
  packet into at most two pieces and sends them as QUIC datagrams on the device's relay
  connection (protocol version 2).
- The relay passes each piece to the other device's relay connection unchanged; the receiving
  shim reassembles it. Every public UDP packet stays within 1,200 bytes, Fly's limit.
- On the Mac, the agent's **shim** delivers those datagrams through one loopback UDP socket
  per relayed phone to an unadvertised `QUICHostListener`. It uses the same `HostService`
  handlers, bounds inner UDP packets and only accepts pinned phones. The Bonjour listener's
  settings and the end-to-end `HostSession` protocol stay unchanged.
- The relay forwards only between the session's two participants, while the Mac allows the
  phone, and ends forwarding when the session ends or after 60 seconds idle. (Version 1 carried
  the phone's packets as raw UDP with a token on a separate port; full-size packets came to 1,213
  bytes, over Fly's limit, so version 2 moved them onto the phone's QUIC connection.)

Why not let the relay terminate TLS and re-encrypt? Because then it could read and inject input
into your Mac. Forwarding sealed packets keeps the relay out of the trust boundary.

## Hole punching

A direct path is cheaper (no relay bandwidth) and faster (one less hop). The approach:

- The Mac's listener keeps a **fixed UDP port** while relay access is on, and the agent sends
  its relay keepalives from that same port, so the relay sees the Mac's public mapping for it.
- On a connection request, both sides send a few small punch packets to each other's public
  and local addresses at the same moment, opening a mapping in each NAT. Then the phone starts
  QUIC to the Mac's public address.
- This works with most home routers and mobile networks. It fails with symmetric NATs and
  strict firewalls, which is what forwarding is for.

**Risk to check first (spike):** sending punch packets from the same port the
`NetworkListener` is bound to. Network.framework allows shared local endpoints
(`allowLocalEndpointReuse`), but QUIC listeners haven't been tried this way. If it can't be
done, the fallback is to run hole punching through the shim as well: the Mac's agent owns the
public port, and the listener only ever sees loopback.

## Relay protocol

The devices talk to the relay over QUIC with ALPN `pocketdesk-relay/2`, with JSON messages on
one bidirectional stream, the same style as `ControlMessage`.

| Message | From | Meaning |
|---|---|---|
| `register(hostID, name?)` | Mac | "This is my fingerprint's Mac." The name is optional and never shown to others |
| `allow([Fingerprint])` | Mac | The iPhones that may reach this Mac. Replaces the previous list |
| `connect(host: Fingerprint, local: [Address])` | phone | Asks for a Mac, with the phone's local addresses |
| `incoming(phone: Fingerprint, public: Address, local: [Address], session)` | relay → Mac | A paired phone wants to connect |
| `candidates(public: Address, local: [Address], session)` | relay → both | The other side's addresses, to punch |
| `allocate(session)` | phone | Direct didn't work, so the phone asks for forwarding |
| `forward(session)` | relay → both | Forwarding is on for this session |
| `datagram(session, bytes)` | relay ↔ both | A forwarded piece, carried as a QUIC datagram |
| `notFound` / `error(reason)` | relay | No allowed Mac by that fingerprint, or a limit was hit |
| `ping` / `pong` | any | Keepalive |

`PDProtocol` gets these types so the Swift apps and the server agree on one definition. The
relay protocol has its own version, separate from the session's `protocolVersion`.

## Moving between networks

- **The phone switches networks** (Wi-Fi to cellular): QUIC can carry a connection across an
  address change. If Network.framework's QUIC doesn't migrate the session, the phone reconnects
  through the relay automatically, as it already does after a dropped LAN connection.
- **The Mac's address changes:** the agent re-registers, and its keepalive (every 25 seconds,
  under typical NAT timeouts) keeps its mapping fresh.
- **Back home:** a new session tries Bonjour first, so it moves back to the LAN.

## Sleep

A sleeping Mac drops its relay connection, so the first version can only reach Macs that are
awake. The Mac setting will explain that, and offer to keep the Mac awake while it's on power.
Later options:

- Ask another paired device on the home network (another Mac, or an Apple TV running a small
  helper) to send the existing Wake-on-LAN packet (`WakeInfo`, protocol v6) on the phone's behalf.
- macOS's own Bonjour Sleep Proxy, if a Mac's registration can be kept alive by it. Needs
  research.

## Abuse, limits and cost

- The relay only forwards between devices on each other's allow lists, so it can't be used as
  an open proxy.
- Per-device limits: connection attempts per minute, concurrent forwarded sessions per Mac (2),
  and a bandwidth cap per forwarded session.
- **Cost:** direct sessions cost almost nothing. A forwarded screen stream is about 2–8 Mbps,
  so forwarding is the real cost. It's why hole punching comes early, why quality drops on
  relayed sessions when the link is slow (link adaptation already does this), and why the
  roadmap pairs "Anywhere" with a subscription.

## Privacy

What the relay handles, and for how long:

| Data | Why | Kept |
|---|---|---|
| Device fingerprints and the Mac's allow list | To decide who may be introduced | While the Mac is registered, in memory |
| Public IP addresses and ports | To punch and forward | For the length of a session, in memory |
| Packet counts and bytes per session | Limits and capacity planning | Aggregated, without addresses |
| Content (screen, input, files, clipboard) | Never available: it's encrypted end to end | Never |

Before this ships, the privacy policy (`site/src/legal/PrivacyPolicy.jsx`, section "When the
apps use the internet") must describe the relay, as it already promises.

## Server

- **Language:** Rust with `quinn` (selected). The forwarding server is in `Services/relay`.
  Its README specifies the implemented version-2 wire contract, datagram forwarding and
  packet fragmentation. The messages in the protocol section describe the wider target design; candidate
  exchange is not implemented yet. Native clients implement the forwarding contract.
- **Hosting:** small instances in a few regions (for example on Fly.io, near users), with the
  apps picking the nearest by latency.
- **State:** in memory per instance. Macs connect to their nearest instance, and instances share
  "which Mac is where" through a small shared store, so a phone can land on any of them.
- **Self-hosting:** the server is a single binary with a config file. The apps take a custom
  relay address in an advanced setting.
- **Observability:** counts of registrations, direct versus forwarded sessions, failures by
  reason, and bandwidth. No per-device logs.

## Testing

- **Unit:** relay message coding (Swift and server agree on the same JSON fixtures), allow-list
  rules, `PathFinder` decisions.
- **Integration:** a local relay and both apps in one test (the package already uses QUIC on
  127.0.0.1), covering: allowed phone connects; unpaired phone gets `notFound`; forgotten phone
  is cut off; forwarded session streams video; the relay can't complete a TLS handshake as either
  device.
- **Networks:** home Wi-Fi to cellular (CGNAT), hotel/captive Wi-Fi, a symmetric NAT (forwarding
  must work), an office firewall that blocks UDP (must fail clearly), and switching networks
  mid-session.
- **Load:** many idle registered Macs (keepalive cost) and several forwarded 8 Mbps streams per
  instance.

## Plan and checklist

### Already in place

- [x] Each device has its own P-256 identity and self-signed certificate (`DeviceIdentity`).
- [x] Sessions use QUIC with mutual TLS and pinned fingerprints, so they're safe on untrusted paths.
- [x] The ALPN carries the protocol version, so mismatched apps fail cleanly.
- [x] `PDProtocol` uses no Apple frameworks, so a server can mirror it.
- [x] Macs have stable host IDs (Bonjour TXT record and pairing invite).
- [x] The phone already reconnects after a dropped connection.
- [x] Link adaptation lowers quality on slow links, which relayed sessions will need.
- [x] Wake details (`WakeInfo`, protocol v6) exist for the later wake helper.
- [x] The privacy policy says the relay is coming and will be described before it ships.
- [x] This design.

### Phase 1: spikes (decide before building)

- [ ] Send UDP from a `NetworkListener`'s bound port, or settle on the shim-owned port.
- [ ] Check whether Network.framework's QUIC migrates a session when the phone changes network.
- [x] Select Rust/Quinn and implement a tested local forwarding server.

### Phase 2: forwarding relay (works everywhere)

- [x] `Relay` message types in `PDProtocol`, with JSON fixtures shared with the server.
- [x] Relay server: registration, allow lists, `connect`, `allocate`, datagram forwarding, limits.
  See `Services/relay/README.md` for the implemented contract and remaining deployment work.
- [x] `RelayAgent` on the Mac: register, keep alive, publish the allow list on every pairing change.
- [x] Forwarding shim on the Mac: one loopback socket per relayed phone into `QUICHostListener`.
- [x] `PathFinder` on the phone: Bonjour first, then forwarded relay.
- [x] Mac setting: "Reach this Mac from anywhere" (off by default), with a custom relay address.
- [ ] Keep-awake-on-power option.
- [x] Phone: a relay connection option on paired Mac cards and "Via relay" in stream info.
- [x] Local Quinn/Apple QUIC integration tests for allowed, unpaired and forgotten phones.
- [x] Deploy to Fly (London) and verify a pinned session end to end through it.
- [ ] Fix throughput through the deployed relay: about one full-size packet in five is lost
  while streaming, which holds video near 0.1 Mbps (a local relay runs at 40 Mbps). Ruled out:
  packet size, piece ordering, drops in the apps, and this connection's plain packet loss.
- [ ] Validate physical devices across the real network matrix.

### Phase 3: direct connections

- [ ] Address candidates (public from the relay, local from the device) and simultaneous punching.
- [ ] `PathFinder` tries direct first, then falls back to forwarding after about two seconds.
- [ ] Measure the direct-path success rate across the network test matrix.

### Phase 4: moving and polish

- [ ] Survive Wi-Fi ↔ cellular changes (migration or a fast reconnect).
- [ ] Re-register the Mac when its network changes; tune the keepalive.
- [ ] Relay-aware quality defaults (start at Balanced on forwarded paths).

### Phase 5: launch

- [ ] Update the privacy policy and the in-app Privacy page to describe the relay.
- [ ] Multi-region hosting, shared presence store, dashboards without per-device logs.
- [ ] Abuse limits and alerting.
- [ ] Decide pricing (the roadmap pairs "Anywhere" with a subscription) and App Store setup.
- [ ] Self-hosting docs and a custom relay address in advanced settings.
- [ ] Bump `protocolVersion` only if the session itself changes (the relay shouldn't need it).

## Open questions

- Where are full-size packets lost while streaming through the deployed relay? Next step:
  aggregate per-leg loss counters on the relay (no identities), to tell the Mac → relay leg
  from the relay → phone leg.
- Should forwarding be free with a cap, and direct always free?
- Is a helper on the home network (for waking) worth building, or is "keep awake on power" enough?
- Do we want IPv6 first? Many mobile networks give phones public IPv6 addresses, which makes
  direct paths far easier when the home network has IPv6 too.
