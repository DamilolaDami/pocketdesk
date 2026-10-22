# PocketDesk architecture

Your Mac, usable from your phone with your thumb. Two native apps share one Swift package.

```
 iPhone (PocketDesk)                              Mac (PocketDesk Host, menu bar)
 ┌───────────────────────────┐   QUIC (TLS 1.3)  ┌───────────────────────────────┐
 │ SwiftUI views             │◀── video stream ──│ ScreenCaptureKit (SCStream)   │
 │   ↑ reads                 │                   │   → VideoToolbox HEVC encoder │
 │ SessionStore (@Observable)│── control stream ▶│ HostSession actor             │
 │   ↑ events                │── input datagram ▶│   → InputInjector (CGEvent)   │
 │ Engine actors             │                   │ Permissions, Bonjour listener │
 │  decode → AVSampleBuffer- │                   │                               │
 │  DisplayLayer             │                   │                               │
 └───────────────────────────┘                   └───────────────────────────────┘
                    └──── Packages/PocketDeskKit (PDProtocol, PDSecurity, PDTransport) ────┘
```

## Platform floor: iOS 26 / macOS 26

Moving the floor to 26 is what lets us use the new Swift-native Network.framework API
(`NetworkConnection`, `NetworkListener`, `NetworkBrowser` with `QUIC`, `QUICStream`,
`QUICDatagram`, `TLV` and `Coder`). That means async/await networking with no
third-party dependencies and no WebRTC.

## Repo layout

| Path | What |
|---|---|
| `Apps/Host` | macOS menu bar app. Thin: wiring + UI only. |
| `Apps/Mobile` | iOS/iPadOS app. Thin: wiring + UI only. |
| `Packages/PocketDeskKit` | All logic, as SwiftPM modules (fast `swift test`, no simulator). |
| `Services/relay` | Phase 2 rendezvous/relay server for off-network access. |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated and never committed. |

### Modules

| Module | Depends on | Rule |
|---|---|---|
| `PDProtocol` | nothing | Pure wire format. No Apple frameworks, so the relay can mirror it. |
| `PDSecurity` | CryptoKit | Identity, pairing, key derivation. |
| `PDTransport` | PDProtocol, Network | `PeerSession` protocol + QUIC impl + `LoopbackSession` for tests. |
| `PDHostCore` | the above + ScreenCaptureKit, VideoToolbox, CoreGraphics | macOS only. |
| `PDClientCore` | the above + VideoToolbox, AVFoundation | Session state machine, decode, render. |

## Transport

One QUIC connection per session, ALPN `pocketdesk/1`, three logical channels:

| Channel | QUIC primitive | Payload | Why |
|---|---|---|---|
| control | bidirectional stream | `ControlMessage` via `Coder` (Codable) over TLV | Reliable, ordered, easy to evolve |
| input | datagrams | `InputEvent`, ≤11 bytes binary | Lost pointer moves are superseded by the next one, so no retransmit lag |
| video | unidirectional stream | `VideoFrameHeader` (21 B) + HEVC access unit | Reliable, but the encoder drops frames under backpressure |

Discovery: Bonjour `_pocketdesk._udp` on the LAN. Off-LAN (phase 2): the relay brokers a
direct path and only forwards traffic as a fallback.

## Video pipeline (latency budget target: < 60 ms glass-to-glass on LAN)

1. **Capture**: `SCStream` of a display or a single window (`SCContentFilter`), at the
   client's viewport size × scale, so we never encode pixels the phone can't show.
   Lower the frame rate when the screen is static.
2. **Encode**: `VTCompressionSession`, HEVC, `EnableLowLatencyRateControl`, no B-frames,
   real-time, infinite GOP with keyframes on demand (`requestKeyframe` after loss or
   a source change).
3. **Backpressure**: if the video stream isn't writable, drop the frame *before* encoding.
   Never queue stale frames.
4. **Decode/render**: hand `CMSampleBuffer`s to `AVSampleBufferDisplayLayer` (hardware
   decode, display-synced, no Metal work for v1). Move to `VTDecompressionSession` + Metal
   only if we need custom compositing (cursor overlay, zoom lens).

## State management

The rule: **actors own side effects, `@Observable` models own UI state, pure reducers own
transitions.** No third-party architecture framework.

- **Engines are actors** (`CaptureEngine`, `EncoderEngine`, `HostSession`, `ClientSession`,
  `Decoder`). They talk over `AsyncStream`s and never touch the UI.
- **One `@MainActor @Observable` store per app** (`SessionStore` on the phone, `HostStore` on
  the Mac). Views read it through `@Environment` and call `send(event)`.
- **Transitions are pure** (`SessionState.reduce(_:)`): value in, value out, fully unit
  tested. The store applies the reducer and then starts or cancels engine tasks based
  on the new state.
- **Hot-path data never goes through the store.** Frames go from transport to decoder to
  layer directly. The store only gets throttled stats (a few Hz), so SwiftUI never
  re-renders per frame.
- **Persistence**: paired devices and settings in SwiftData. Private keys in the Keychain
  (on iPhone, the Secure Enclave where possible).

We're skipping TCA (The Composable Architecture) because it adds a big dependency and
learning curve, and Observation + actors + a reducer gives the same testability for an app
this size. Revisit if feature count explodes.

## Security

- **Pairing**: the host shows a QR code (`PairingInvite`: host ID, Curve25519 public key,
  one-time token). The phone scans it, both sides derive an HKDF key bound to the token, and
  both show a 6-digit code to confirm.
- **Every session**: QUIC/TLS 1.3 with mutually pinned keys from pairing. Unknown devices
  can't even complete a handshake.
- **Host controls**: a menu bar indicator while someone's connected, one-click disconnect,
  per-device revoke.
- **Relay** (phase 2) only ever sees ciphertext.

## Distribution

- **iOS app**: App Store.
- **Mac host**: Developer ID + notarization, direct download (and later Sparkle for updates).
  CGEvent input injection and Accessibility need a non-sandboxed app, which rules out the
  Mac App Store. Jump Desktop and Screens ship their host agents the same way.

## Roadmap

1. **v0.1 – LAN mirror**: Bonjour discovery, QR pairing, full-display stream, tap/drag/scroll,
   keyboard.
2. **v0.2 – Window picker**: stream one window fitted to the phone, app switcher UI.
3. **v0.3 – Thumb UI**: read the frontmost app's menus/toolbar via AX APIs and render them as
   native controls.
4. **v1.0 – Anywhere**: relay + hole punching, wake-on-LAN, subscription.
5. **Later – Agent**: natural-language tasks executed on the Mac with a live view.
