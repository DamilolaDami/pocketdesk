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
`QUICDatagram` and `Coder`). That means structured async/await networking with no WebRTC.
The only third-party dependency is Apple's open-source `swift-certificates` (Apache-2.0),
used to mint each device's self-signed certificate.

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
| `PDSecurity` | Security, CryptoKit, swift-certificates | Device identity, fingerprints, pairing, trust store. |
| `PDTransport` | PDProtocol, PDSecurity, Network | `PeerSession` + QUIC impl, Bonjour listener/browser, `LoopbackSession`. |
| `PDHostCore` | the above + ScreenCaptureKit, VideoToolbox, CoreGraphics | macOS only. Capture, encode, input, `HostSession`, `HostService`. |
| `PDClientCore` | the above + VideoToolbox, AVFoundation | Session state machine, decode, render. |

## Transport

One QUIC connection per session, ALPN `pocketdesk/5`, four logical channels:

| Channel | QUIC primitive | Payload | Why |
|---|---|---|---|
| control | bidirectional stream, opened by the phone | `ControlMessage` as JSON via `Coder` | Reliable, ordered, easy to evolve |
| input | datagrams (max frame 1200 B) | `InputEvent`, ≤11 bytes binary | Lost pointer moves are superseded by the next one, so no retransmit lag |
| video | unidirectional stream, opened by the Mac on its first frame; initial byte `0` | `VideoFrameHeader` (21 B) + payload | Reliable, but the host drops frames *before* encoding under backpressure |
| audio | independent unidirectional stream, opened by the Mac on its first packet; initial byte `1` | `AudioFrameHeader` (16 B) + raw AAC-LC packet | Timestamped audio cannot block video delivery |

Discovery: Bonjour `_pocketdesk._udp` on the LAN, TXT record `id=<hostID>`, `v=<protocolVersion>`.
Off-LAN (phase 2): the relay brokers a direct path and only forwards traffic as a fallback.

Connection lifetime is structured (that's how the new Network API works): a connection lives
while `QUICHostListener.run`'s handler or `QUICClient.connect`'s body runs. `connect` fails
on `.failed` or if not ready within its timeout. Otherwise a rejected handshake sits in
`.waiting` forever.

Media streams carry an explicit kind byte; stream arrival order is unspecified. The ALPN
tracks the protocol version so incompatible peers cannot interpret changed messages or framing.

### Session flow

```
phone                                   Mac
  ── QUIC handshake, both certs pinned ──▶   (unpinned phones only while an invite is open)
  pairRequest(token, name)  ───────────▶   (unpaired only) token checked, code shown on Mac
  ◀───────────────────────  pairResult(accepted)
  hello(version, name, viewport) ──────▶
  ◀───────────────────────  helloAck(hostName, displays)
  ◀───────────────────────  streamConfig(hevc, w, h, fps, kbps)
  ◀═══════════════════════  video: keyframe (VPS/SPS/PPS + slices), deltas…
  input datagrams  ════════════════════▶   CGEvent injection, mapped into the source's screen rect
  listWindows / selectSource / requestKeyframe / insertText / run(MacAction) / ping / bye
  ◀───────────────────────  actionFailed(reason)   (a shortcut the Mac couldn't run)
```

**Shortcuts** (protocol v2): phone tiles that send `run(MacAction)`: open a URL, open an app
(bundle ID, falling back to its name), or press one key combination. Tapping one while not
streaming connects to the chosen Mac and sends it once the first `streamConfig` arrives. The
library is a JSON file on the phone (`ShortcutLibrary`). Website tiles show the site's own
icon, fetched from that site (never a favicon service) and cached.

**App catalog**: the editor's app picker opens a short `hello(mode: .catalog)` connection: no
video, input or Screen Recording, and the Mac's menu doesn't show it as connected. The phone
sends `listApps` (apps in the usual folders, named as Finder shows them), then
`requestAppIcons` for the bundle IDs whose icons it hasn't cached. The Mac answers each with
an `appIcon` holding a 128 px PNG. The app list (per Mac) and the icons are cached on the
phone, and refreshed at most every five minutes.

## Video pipeline (latency budget target: < 60 ms glass-to-glass on LAN)

1. **Capture** (`ScreenCaptureSource`): `SCStream` of a display (our own windows excluded)
   or a single window, in NV12 (what the encoder takes natively). The size comes from
   `StreamSizing.fit`: the source's aspect ratio inside the phone's pixel box, never
   upscaled. Only `.complete` frames are forwarded, so a static screen costs no bandwidth.
2. **Encode** (`HEVCEncoder`): hardware HEVC, low-latency rate control (falls back if
   unavailable), real-time, no frame reordering, keyframes on demand plus a 60 s safety net.
3. **Backpressure** (`HostSession`): at most 2 frames between "submitted to encoder" and
   "accepted by QUIC". Beyond that, captured frames are dropped *before* encoding. Never
   queue stale frames. The encoder's output is unbounded on purpose, so a keyframe is never dropped.
4. **Payload**: length-prefixed (4-byte big-endian) HEVC NAL units, the HVCC layout
   VideoToolbox emits. Keyframes start with VPS/SPS/PPS and set `.parameterSets`, enough for
   `CMVideoFormatDescriptionCreateFromHEVCParameterSets` on the phone. A source switch bumps
   `sourceGeneration` and sends `streamConfig` before the first frame.
5. **Decode/render** (phone, `FrameAssembler` + `VideoDisplay`): hand `CMSampleBuffer`s to `AVSampleBufferDisplayLayer` (hardware
   decode, display-synced, no Metal work for v1). Move to `VTDecompressionSession` + Metal
   only if we need custom compositing (cursor overlay, zoom lens).

## Link adaptation (protocol v5)

`HostSession` refits the stream to the network every 500 ms (`RateController`, a pure value
with tests). Signals: frames dropped at the in-flight gate, how long QUIC takes to accept a
frame, and round trips from the host's own `ping`s, compared with the best seen. On trouble it
steps down a ladder at once: bitrate (70%, 50%), then 30 fps, then about the phone's own
resolution (2/3 of the zoom-headroom size), then 20 fps. It steps back up only after a quiet
stretch that doubles each time a step up fails within ~5 s, so a link at its limit doesn't flap.
Bitrate and frame rate change in place (`HEVCEncoder.setRate`, frames skipped before encoding);
resolution restarts the stream, and the window after any restart is ignored because it opens
with a keyframe burst. A still screen sends nothing and so never counts as a quiet window.
Each change goes to the phone as `linkQuality`; from the second rung down the phone shows a
"Weak connection" pill. Frames the encoder skips at low bitrates come back as dropped
`EncodedFrame`s so they free their in-flight slot.

To try it on a fast LAN, launch the Mac app with `POCKETDESK_SIMULATE_KBPS=300` (see
`ThrottledSession`). If a resize can't find the source (the screen locked, say), the stream
keeps its size and only bitrate and frame rate drop.

## Display selection (protocol v4)

The stream screen has **Displays** beside **Windows**. `helloAck` provides display names,
pixel sizes, the main-display marker, numeric capture IDs, and persistent monitor identities.
Opening the picker refreshes the list with `listDisplays` / `displays`; choosing a row sends
`selectDisplay(id)` over the existing control connection. `HostSession` resolves it, changes
input mapping to that display's global screen rectangle, and starts a new source generation
with `streamConfig.displayID` and a keyframe. Audio restarts with the same generation.
The phone only marks and saves a display after the host confirms it in `streamConfig`.
A window config has no display ID and preserves the last whole-display choice; **Whole
Display** returns to it. Audio setting changes preserve the selected display as well.

`DisplayPreferences` persists the monitor identity under the paired Mac's host UUID in
Application Support (`PocketDesk/displays.json`). A reconnect sends it in
`hello.preferredDisplayID`; the Mac maps it to the current numeric capture ID before the
first frame. An unavailable saved monitor falls back to the main display. An invalid picker
selection refreshes the list and reports a notice while keeping the session connected.
Forgetting a Mac removes its display preference. Connection IDs prevent a cancelled Mac's
late events from overwriting another Mac's selection or saved preference.

Validation covers real QUIC with two synthetic monitors (including negative screen origins),
new-generation keyframes, input mapping, returning from windows, audio toggles, removed
monitors, and preference persistence. ScreenCaptureKit tests capture each connected physical
display when Screen Recording permission is available. Verify the picker on the phone with
an external monitor attached, select both screens, reconnect, and confirm the saved choice.

## Audio pipeline (protocol v3)

- `Hello.audioEnabled` carries the persisted phone preference. Settings → Streaming →
  **Play Mac Audio** sends `setAudioEnabled` during an active connection. The host restarts
  the current capture source with a new generation and keyframe. Catalog sessions never
  capture audio. The microphone and this host process's own audio are excluded.
- ScreenCaptureKit captures 48 kHz stereo PCM with video's host monotonic timestamps.
  `AACEncoder`, confined to the capture queue, converts to 128 kbps AAC-LC. Partial PCM
  survives callbacks; packet timestamps advance by 1024 samples without rounding drift.
  Timestamps subtract the encoder's reported leading priming frames (44 ms on Apple's
  AAC encoder), so decoded content aligns with video. Capture discontinuities reset the converter. Capture and receive queues hold at most eight
  packets and shed old audio under pressure. Raw AAC packets are independently framed and
  limited to 8192 bytes before allocation on the receiver.
- `AudioAssembler` builds compressed audio sample buffers. `VideoDisplay` owns an
  `AVSampleBufferAudioRenderer` and an `AVSampleBufferRenderSynchronizer` shared with the
  view's video renderer. The first media timestamp anchors to the local clock with 120 ms
  of startup headroom. With audio enabled, video uses timestamps instead of
  `DisplayImmediately`; with audio disabled, video remains immediate. The iOS playback
  audio session is activated only for a streaming connection and deactivated on exit.
- Source generations reject old audio; disconnect flushes both renderers and their clock.
  Mac speaker muting is not implemented; the Mac continues playing locally.

### Audio verification

Automated coverage includes real PCM → AAC → PCM conversion, packet timestamp spacing,
malformed wire lengths, actual four-channel QUIC delivery, and toggling audio while a
window remains selected. Simulator builds verify API and UI integration. They do not
establish the physical lip-sync acceptance target.

To verify issue #7 on devices, run both updated apps, pair, and play a local test clip
with simultaneous flashes and clicks (then dialogue). Record the phone screen and speaker
at high frame rate; measure flash versus click over the start and after several minutes.
Require an absolute offset of about 50 ms or less. Repeat for display/window capture,
source switching, audio off/on, disconnect/reconnect, and wired/Bluetooth output changes.
Confirm disabling audio silences the phone and disabling it before connecting avoids Mac
audio capture. Confirm the microphone is never captured.

## State management

The rule: **actors own side effects, `@Observable` models own UI state, pure reducers own
transitions.** No third-party architecture framework.

- **Engines are actors** (`ScreenCaptureSource`, `HostSession`, `HostService`, and on the phone
  `ClientConnection`). They talk over `AsyncStream`s and never touch the UI.
  Hardware wrappers that VideoToolbox calls back on its own threads (`HEVCEncoder`) are
  lock-guarded classes.
- **Seams for tests**: `PeerSession`, `FrameSource`, `InputSink` and `PairingAuthority` are
  protocols, so `HostSession` runs end to end in tests against synthetic frames.
- **One `@MainActor @Observable` store per app** (`SessionStore` on the phone, `HostStore` on
  the Mac). Views read it and call `send(event)`. On the Mac, `HostService` emits `HostEvent`s
  and `HostController` forwards them to the store; on the phone, `SessionController` does the
  same for `ClientConnection`'s `ClientEvent`s. UI → Mac input goes through an ordered
  `AsyncStream`, never ad-hoc Tasks, so a button-down can't overtake its button-up.
- **Transitions are pure** (`SessionState.reduce(_:)`, `HostState.reduce(_:)`): value in,
  value out, fully unit tested. The store applies the reducer and then starts or cancels engine tasks based
  on the new state.
- **Hot-path data never goes through the store.** Frames go from transport to decoder to
  layer directly. The store only gets throttled stats (a few Hz), so SwiftUI never
  re-renders per frame.
- **Persistence**: pinned peers in a JSON `TrustStore` file (Application Support). Device keys
  in the Keychain, never exported.

We're skipping TCA (The Composable Architecture) because it adds a big dependency and
learning curve, and Observation + actors + a reducer gives the same testability for an app
this size. Revisit if feature count explodes.

## Mac-side session controls

The person at the Mac always knows and controls who is using it:

- **Notifications.** "“iPhone” is now viewing this Mac" when a stream starts, with a
  Disconnect action. It is removed when the session ends. Pairing and connection requests
  are notified too, because the menu bar panel is often closed (`SessionNotifier`, in the app).
- **Disconnect.** `HostService.disconnect(peer)` sends `bye(reason:)` to each of that phone's
  sessions, so the phone shows why. If the phone doesn't hang up within 2 s, the connection
  is closed. Forgetting a connected phone disconnects it.
- **Ask Before Each Connection** (gear menu, off by default). A paired phone's stream waits on
  `PairingAuthority.allowSession`, shown as an approval with no code. Silence after the
  approval timeout is a no. A phone that has just been paired isn't asked a second time.
- The menu bar icon changes while any phone is connected.

## Network.framework on iOS

Releasing a QUIC stream or datagram flow after the connection is gone traps on iOS
("nw_connection_set_queue called after nw_connection_start"). The host tears connections
down whenever it likes (its TLS gate turns away unknown phones, or the Mac quits), so the
phone never releases its streams: `QUICPeerSession` parks them in `Retired`. The host opens
its media streams on first use and sends each frame to completion even when its pump is
cancelled, since half a frame would corrupt the stream.

## Security

The design assumes attackers can read this code (it's open source). Security rests on keys
and pinning, never on obscurity.

- **Identity**: each device generates a P-256 key *inside* the Keychain and a self-signed
  certificate over it (`DeviceIdentity`). Its `Fingerprint` is the SHA-256 of the certificate.
- **Pairing**: the Mac's "Pair a Phone" window shows a QR code (`PairingInvite`:
  host ID, name, host fingerprint, 128-bit one-time token, 5-minute expiry). The phone pins the
  host fingerprint from the QR, connects, and sends `pairRequest(token)`. The token is
  compared in constant time, and a wrong one is refused without prompting. Both screens show a
  6-digit code (HMAC of both fingerprints keyed by the token), and the Mac's user accepts. Only
  then is the phone pinned. Invites are single use.
- **Every session**: QUIC/TLS 1.3 with mutual certificate authentication. Each side's
  validator accepts only the pinned fingerprint. The host's TLS gate admits unpinned phones
  only while an invite is open, and they still need the token.
- **Shortcuts** grant nothing new: a paired phone can already click and type anything.
  The host refuses `file:` URLs so a shortcut can't open local files by path.
- **Host controls**: menu bar icon changes while connected; per-phone "Forget" (revoke).
- **Relay** (phase 2) only ever sees ciphertext.

### Gotchas we hit (so you don't)

- TLS 1.3 pre-shared keys don't work with QUIC on Apple's stack (handshake fails, `-9858`),
  hence certificates.
- `peerAuthentication(.none)` on the client **skips the certificate validator entirely**: it
  would trust any host. Both sides use `.required`. `phoneRejectsImpostorHost` guards this.
- The macOS file keychain ignores `kSecAttrLabel` on certificates (it labels them by common
  name), so the certificate's CN *is* the storage label. It also fails key generation under
  concurrent use, so `DeviceIdentity` serializes Keychain writes.
- Never drop *encoded* video anywhere (transport buffers, encoder output): every delta frame
  references the previous one, and one missing frame smears the picture until the next
  keyframe. Pace by dropping *captured* frames before the encoder.
- ScreenCaptureKit only delivers frames when pixels change, so a quickly coded frame never gets
  refined on a still screen. `HostSession` re-encodes the last frame a few times once it's still.
- Closing a QUIC connection discards unsent stream data: send `bye(reason)` and wait for the
  phone to hang up (`sayGoodbye`), or the phone only ever sees "connection reset".
- Local Mac builds: sign with a stable identity (your Apple Development certificate, passed on
  the `xcodebuild` command line, never committed). Ad-hoc signatures change every build, and
  macOS then re-asks for the keychain key and silently drops the Screen Recording grant.

## Distribution

- **iOS app**: App Store.
- **Mac host**: Developer ID + notarization, direct download (and later Sparkle for updates).
  CGEvent input injection and Accessibility need a non-sandboxed app, which rules out the
  Mac App Store. Jump Desktop and Screens ship their host agents the same way.
  The host keeps its identity in the file-based login keychain for now. Moving to the data
  protection keychain needs a signed build with a keychain access group.

## Roadmap

1. **v0.1 – LAN mirror**:
   - Done on the Mac: QUIC transport, Bonjour, certificate pairing, capture, HEVC encode,
     input injection, window switching (protocol), menu bar app with pairing QR.
   - Done on the phone: Bonjour host list, pairing (VisionKit QR scan, paste link, or a
     `pocketdesk://pair` URL), `FrameAssembler` → `AVSampleBufferDisplayLayer`, direct touch
     (tap = click, long press = right-click, drag = click-drag, two fingers = scroll),
     keyboard via `UIKeyInput`, window picker.
2. **v0.2 – Window picker**: stream one window fitted to the phone, app switcher UI.
3. **v0.3 – Thumb UI**: read the frontmost app's menus/toolbar via AX APIs and render them as
   native controls.
4. **v1.0 – Anywhere**: relay + hole punching, wake-on-LAN, subscription.
5. **Later – Agent**: natural-language tasks executed on the Mac with a live view.
