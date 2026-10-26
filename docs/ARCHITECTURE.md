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

One QUIC connection per session, ALPN `pocketdesk/<protocolVersion>` (now 21), four logical channels:

| Channel | QUIC primitive | Payload | Why |
|---|---|---|---|
| control | bidirectional stream, opened by the phone | `ControlMessage` as JSON via `Coder` | Reliable, ordered, easy to evolve |
| input | datagrams (max frame 1200 B) | `InputEvent`, ≤11 bytes binary | Lost pointer moves are superseded by the next one, so no retransmit lag. Keys go on the control stream (`ControlMessage.key`): a lost key-up would leave ⌘ held down |
| video | unidirectional stream, opened by the Mac on its first frame; initial byte `0` | `VideoFrameHeader` (21 B) + payload | Reliable, but the host drops frames *before* encoding under backpressure |
| audio | independent unidirectional stream, opened by the Mac on its first packet; initial byte `1` | `AudioFrameHeader` (16 B) + raw AAC-LC packet | Timestamped audio cannot block video delivery |

Discovery: Bonjour `_pocketdesk._udp` on the LAN, TXT record `id=<hostID>`, `v=<protocolVersion>`.
Off-LAN (phase 2): the relay brokers a direct path and only forwards traffic as a fallback.
See [RELAY.md](RELAY.md) for the design.

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
Media keys (protocol v9): `MacAction.media` (Play/Pause, next, previous, volume, mute) is
posted as the keyboard's system-defined media-key events, so Play/Pause pauses whatever is
playing (Netflix in Safari, Music, YouTube) whichever app is in front.

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

### Quality modes (protocol v15)

The phone sends a `StreamQuality` in `hello`, and `setQuality` when it changes. Each mode is a
ceiling (`QualityCeiling`) that link adaptation steps down from:

| Mode | Resolution | Frame rate | Bitrate |
|---|---|---|---|
| Best | 1.5× the phone's pixels per side (zoom headroom) | 60 | full |
| Balanced | the phone's pixels | 60 | 0.8× |
| Battery Saver | 0.75× the phone's pixels | 30 | 0.6× |

Low Power Mode on the phone means Battery Saver whatever the setting
(`StreamQuality.effective`). A change restarts the stream at the new size.

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

## Keyboard (protocol v10)

- **Key bar:** the stream view's `inputAccessoryView` (`KeyBar`, SwiftUI in a hosting view)
  has Esc, Tab, ⌃ ⌥ ⇧ ⌘, arrows, ⌦, Home/End, Page Up/Down and F1–F12. Modifiers stick
  (`StickyModifiers`): one tap for the next key, a quick double tap to lock. With a modifier
  on, a letter typed on the iOS keyboard goes as its key (`KeyMap.stroke`) instead of as text.
  The stream view owns the sticky state and pushes it into the bar: observation didn't
  reliably re-render a hosting controller used as an input accessory.
- **Hardware keyboards:** `pressesBegan` and `pressesEnded` send every key as a real key-down
  and key-up, mapping HID usages to Mac key codes (`KeyMap.macKey`). Both are positional, so
  layouts match when the phone and the Mac use the same one. Modifier keys go down and up on
  their own, so ⌘-Tab-Tab cycles apps. While `GCKeyboard.coalesced` is set, the stream view
  stays first responder without the on-screen keyboard.
- **Repeat:** keys posted with `CGEvent` don't auto-repeat, so `SessionController.sendKey`
  repeats a held key itself (450 ms, then every 40 ms).
- **Safety:** every key rides the reliable control stream, and the Mac lets go of any keys
  still down when a stream stops (`InputSink.releaseKeys`).
- **Limits:** iOS keeps some combinations for itself, like ⌘-Space and, on iPad, ⌘-Tab. Use
  the bar for those. Text typed without a modifier still goes as Unicode (`insertText`), so
  any language works.

## Routines and Mac Shortcuts (protocol v11)

- **Mac Shortcuts:** `MacAction.runShortcut(id:name:)` runs one from the Mac's Shortcuts app
  with `/usr/bin/shortcuts run`, by identifier so a rename doesn't break the tile. The catalog
  connection also sends `listMacShortcuts` (answered from `shortcuts list --show-identifiers`)
  for the editor's picker and the quick-picks sheet. The Mac waits up to 4 s for the result,
  so "Couldn't find shortcut" reaches the phone; a longer shortcut counts as started. Its
  output is discarded, since a big one would fill the pipe and stall it.
- **Steps:** `MacAction.steps([MacAction])` runs actions in order and stops at the first that
  fails ("Step 2: …"). One level deep, at most 20 steps, `wait(milliseconds:)` up to 30 s,
  checked on the Mac (`MacAction.isValid`) before anything runs.
- **Players:** `mediaIn(key, player:)` sends Play / Pause, Next or Previous straight to
  Music, Spotify or TV with `osascript` (`tell application id … to playpause`), whatever else
  is playing. It never launches a closed player, and macOS asks once per player before the
  first command. Browsers can't be addressed, so they stay "whatever's playing" (`media`).
- **Volume:** `setVolume(0–100)` goes through Core Audio (`SystemVolume`). AppleScript's
  `set volume` silently does nothing from the hardened-runtime host.
- Running a Mac Shortcut adds no new power: the person at the Mac made it, and a paired phone
  could already click it in the Mac's menu bar. Arbitrary shell commands are deliberately not
  an action.

## Shortcuts that ask (no protocol change)

A website shortcut with `{text}` in its link (`MacAction.textPlaceholder`) asks for words when
it runs: `SessionController.run` puts a `TextRequest` in the store, the app shows a prompt,
then `MacAction.filling(_:)` percent-encodes the words into every `{text}` (in every step of
a routine) and the Mac gets a plain link. Siri asks through the intent's optional `text`
parameter (`needsValueError`). Quick picks include Search YouTube, Netflix, Google and Maps.

## Live tiles (protocol v12)

- While the Shortcuts tab is on screen and the app is in front, `SessionController.watchStatus`
  holds a catalog-mode connection (no video, no "connected") and sends `watchStatus`. While
  streaming, it asks over the stream instead.
- The Mac checks every second (`Configuration.statusInterval`) and sends `macStatus` only when
  it changes. Closing the connection stops the polling.
- `MacStatus`: volume and mute from Core Audio, plus `nowPlaying` from the private MediaRemote
  framework. Since macOS 15.4 MediaRemote answers only Apple's processes, so the host bundles
  `PocketDeskNowPlaying.dylib` (`Apps/NowPlaying`, never linked into the host) and loads it
  into `/usr/bin/perl` as an XSUB, which prints one JSON line. This is a known workaround,
  not an API: if Apple closes it, `nowPlaying` is `nil` and tiles show volume alone. Without
  the bundled helper (tests, command line) the reader asks MediaRemote directly.
- Tiles: Play / Pause shows the title and artist and swaps between play and pause; volume tiles
  show the level or "Muted".

## More shortcut actions (protocol v19)

- New `MacAction`s: `typeText` (Unicode key events, so any keyboard layout; new lines press
  Return), `copyText` (the Mac's clipboard), `quitApp` (`terminate()`, as ⌘Q, so apps can ask
  to save; already closed counts as done) and `system(MacCommand)`: lock (⌃⌘Q), sleep display
  and sleep (`pmset`; sleep waits 2 s so the phone hears it worked), dark mode (System Events,
  which macOS asks about once) and a silent screenshot to the Desktop. Text is capped at
  `MacAction.maxTextLength`. None of this grants anything new: a paired phone can already
  type, press ⌘Q and click the Apple menu.
- Placeholders: `{text}` asks (links percent-encode it, text actions don't), and `{date}` and
  `{time}` are filled on the phone when it runs (`fillingClock`).
- Per shortcut (phone only, optional fields so older libraries load): `asksFirst` puts up a
  "Run …?" dialog (Siri uses `requestConfirmation`), `macID` always runs it on one Mac, even
  while streaming another.
- Sharing: `Shortcut.sharingURL` is `pocketdesk://add?shortcut=<base64url JSON>` without its ID
  or Mac. Opening one never saves it: it opens in the editor to look over first, and links
  the Mac would refuse (`isValid`) or over `maxSharedLength` are ignored.
- Siri and the Shortcuts app also get Type on Computer, Control Computer (lock, sleep,
  display, dark mode, screenshot) and Set Computer Volume.

## Now Playing Live Activity (protocol v21)

What the watched Mac plays, on the Lock Screen and in the Dynamic Island, from the same
`MacStatus` live tiles use.

- `NowPlayingActivityModel` (pure, tested) turns each status into a step: start (only for
  something playing, not a paused song), update (only on change), replace (another Mac) or
  end (playback stopped, the Mac missing for two status checks, or switched off in Settings).
  `SessionController` sends the steps, in order, to a `NowPlayingPresenter`; on iOS that's
  `LiveActivityPresenter`, which adopts an activity left by an earlier launch.
- Content stays under ActivityKit's 4 KB: the cover is saved in the App Group
  (`NowPlayingArtwork`, one file named by its hash) and the card carries its name and average
  color. The widget extension (`NowPlayingLiveActivity`) reads the file.
- Buttons are `NowPlayingControlIntent`, a `LiveActivityIntent` compiled into both targets but
  run in the app's process (`WIDGET_EXTENSION` leaves out the app-only part). Play / Pause
  flips the card at once, sends the media key over a short catalog connection, then listens
  to the Mac's status for 3 s to catch the new song. A cold-started button first waits for
  activity adoption, binds the request to that activity's Mac, and uses an acknowledged
  one-shot connection rather than a streaming socket that may have been suspended. Failure
  restores the previous card exactly; end-when-paused waits for confirmed delivery.
  The latest attempt's phase/error is kept locally in `now-playing-control.json`, without
  titles, tokens or fingerprints, for device diagnosis.
- From a browser, the card shows the site ("netflix.com on Studio") and its icon: on a white
  tile without a cover, as a badge on one with a cover, and its color when there's no cover.
  macOS only says the browser, so the host (`PlayingSite`) asks Safari, Chrome, Arc, Brave,
  Edge or Vivaldi for their tabs (JXA through `osascript`, once per song; macOS asks the person
  at the Mac once) and picks the tab whose title holds what's playing. `NowPlaying.site` is
  optional, sent from v19. The phone fetches the icon from the site itself (`FaviconLoader`),
  shrinks it to 96 px and saves it next to the cover.
- **Push-to-start (protocol v20).** `Hello.nowPlayingPush` gives the Mac
  the activity's APNs push-to-start token, the running activity's own token, what it shows,
  the look (`NowPlayingActivityPreferences`) and site icon colors; it travels only inside the
  encrypted session, on stream and status connections (left out means no change, a `nil`
  start token withdraws). On by default (Settings › Now Playing › Start When Music Plays).
  The Mac (`NowPlayingPushes`) keeps tokens per phone (0600 file, dropped when the phone is
  forgotten), runs the same `NowPlayingActivityModel`, and builds Apple's Live Activity
  payloads; phones that are connected draw their own card and get none. Covers keep the
  phone's names (SHA-256 of the JPEG) so a pushed card shows one the phone already saved;
  site icons are named by site and kept. The APNs key can't ship in the Mac app, so the relay
  sends: the Mac's `RelayAgent` asks with `push` and the relay signs and posts to Apple
  (`Services/relay/README.md`, "Live Activity pushes"). With Remote Access off nothing is
  sent and nothing watches while phones are away. A dead token (410, `BadDeviceToken`) drops
  the start token, or just the closed card's, so the next song starts a new one. Push content isn't end-to-end
  encrypted: the relay and Apple see titles and sites when Show Details in Pushes is on.
  With it off, every push (including the alert and end state) has only “Playing on <Mac>”,
  playback state and appearance preferences; no artist, app, site, artwork identifiers,
  artwork/site color, or timeline. The phone restores details through its encrypted session.
  Missing `showsDetailsInPushes` decodes as true for older saved registrations.
- Priority is 10 for start/end and playback-state changes, 5 for other updates. The relay
  accepts optional `priority` (5 or 10, default 10). Deploy it before Macs that send priority.
- Progress (v21): MediaRemote elapsed/duration/timestamp become a rounded stable `startedAt`,
  `duration` and, while paused, `pausedElapsed`. Status and activity models coalesce at most
  one second of sampling drift against the last sent timeline; seeks and playback changes
  still update. System timer views animate Lock Screen and expanded Island progress without
  periodic pushes. Unknown durations, live streams and non-unit playback rates omit progress.
- macOS sleep/power-off notifications suspend the push watcher and immediately send end pushes
  for known cards with activity tokens; wake resumes polling and can start fresh cards.
  Delivery before the network sleeps is best effort. Content still goes stale after 15 minutes
  if the Mac or relay disappears unexpectedly.
- Settings › Now Playing: on/off, style (album colors, PocketDesk blue, classic), album art,
  skip buttons, end when paused. They travel in the card, so a change redraws it at once.

### Relay availability in Settings

The iPhone's Remote Access settings check the configured relay with an authenticated QUIC
`ping`/`pong`, bounded to eight seconds. This tests the actual control path and supports
custom ports; enabling Remote Access alone never means “ready”. `RelayHealthState` ignores
out-of-order results after a retry/server change. Checks stop when the settings page is
inactive and repeat every 30 seconds while visible. A failure means this phone couldn't
reach the relay, which may be a phone/network problem; a successful check doesn't mean its
Mac is awake. The Mac uses its live `RelayAgent` registration state and can retry manually.
No marketing-site indicator, email monitor, or public health listener is added.

## Files (protocol v16)

Photos and files go to the Mac's Downloads folder; the phone browses and fetches files from the
folders the Mac shares.

- **Channel**: file data never rides the control stream, so a big file can't hold up keys.
  Mac → phone: a unidirectional stream tagged `2` carrying binary `FileChunk`s (21-byte header +
  up to 256 KB). Phone → Mac: a second stream the phone opens; the host reads every phone stream
  as JSON messages, so chunks go as `ControlMessage.fileData` (base64), and its reader routes
  them to `PeerSession.fileChunks` instead of the control channel.
- **Flow control and progress**: the receiver acknowledges with `fileProgress` at least every
  1 MB; `FileSender` stays within `FileChunk.window` (4 MB) of the last acknowledgement, which
  bounds memory on both sides (the channels themselves are unbounded).
- **Resume**: `FileReceiver` keeps a part file under the transfer ID and answers with where to
  carry on. Fetches use `FileEntry.transferID` (a hash of path, size and date), so fetching the
  same file again resumes; uploads resume when retried with the same ID.
- **Sending** (`sendFile` → `fileAccepted(offset)` → chunks → `fileSaved`): saved under a safe,
  unused name (`FileOffer.safeName`, "name 2"…) and quarantined like an AirDrop. The Mac shows a
  notification; clicking it reveals the file in Finder.
- **Browsing** (`listFiles` / `getFile` → `fileOffer` → chunks): only Desktop, Documents and
  Downloads, each off until switched on in the menu bar panel (which also triggers macOS's
  folder-access prompt then, not while you're away). `SharedFolders.url(for:)` takes names
  only and refuses anything that resolves outside the shared folder, links included.
- **Outside a stream**: `ClientConnection.openFiles` holds a catalog-mode connection (no video)
  while the browser is open or files are sending; on the Mac, "Ask Before Each Connection"
  applies to files as it does to shortcuts.
- **Share sheet**: the `PocketDeskShare` extension sends to the most recently used Mac. It uses
  the app's TLS identity (same keychain access group) and its pairings, which now live in the
  App Group container (`SharedStorage`, moved there on first launch).

## Mac cards and the clipboard without streaming (protocol v17)

The Macs tab does things without opening a stream, over short catalog connections:

- **Status**: `watchStatus` sends `MacStatus` as it changes: volume, now playing (with a cover
  shrunk to 240 px and the app playing it, with its icon) and the battery. The phone pings
  the same connection every 2 s for the round trip it shows (`ConnectionGrade`).
- **Wallpaper**: `HelloAck.wallpaper` carries the desktop picture at 480 px, cached on the
  Mac until the file changes. The phone keeps the last one per Mac, so a sleeping Mac is still
  drawn with it.
- **Clipboard**: the phone sends `clipboard` to paste and `getClipboard` to copy (the Mac
  answers `clipboard`, or `actionFailed` when nothing's copied). Both count as using the Mac,
  so "Ask Before Each Connection" applies, once per connection.

On these connections the Mac confirms each `run` or `clipboard` with `actionDone` (or
`actionFailed`), and the phone waits for it before its `bye`: an answer sent just before the
Mac hangs up could otherwise be lost.

The status, artwork and wallpaper fields are optional; `getClipboard` and `actionDone` needed
the bump.

**Locked Macs** (phone only, `MacLocks`): a Mac can be locked behind Face ID or the passcode.
`SessionController` asks (through the app's `authenticate`) before anything uses a locked
Mac (connecting, waking, shortcuts, files, the clipboard) and keeps it unlocked until the app
leaves the screen. Siri and widgets that can't ask fail with "locked" rather than skip it.

## Mac menus on the phone (protocol v14)

- The stream's Menus button opens `MenusSheet`, which sends `watchMenus(true)` (and `false` when
  it closes). The Mac answers with `menuBar` straight away, then again when another app comes
  forward (checked every `Configuration.menusInterval`) or after `pressMenuItem`.
- `AccessibilityMenus` reads the frontmost app's `AXMenuBar` without opening any menu, so the
  Mac's screen doesn't change. One `AXUIElementCopyMultipleAttributeValues` per item keeps it
  to one round trip each. Reading stops at `MenuBar.maxDepth` levels, `maxItemsPerMenu` and
  `maxItems` in all (History and Bookmarks can be huge). Menus an app fills only when opened
  (Open Recent, say) come through empty.
- Items are addressed by `path`: child indexes from the bar down. `MenuPress` also carries the
  title, and the Mac presses (`AXPress`) only if it still matches, so a stale sheet can't
  choose the wrong thing.
- Enabled states and checkmarks are what the app last validated; some apps update them only
  when a menu opens, so an item can look enabled and do nothing.

## Shortcuts outside the app (protocol v8)

- **Siri and the Shortcuts app:** `RunShortcutIntent` takes a `ShortcutEntity` and runs in the
  app's process (`AppModel.controller`). The phrase is "Open Netflix on my Mac with PocketDesk";
  App Shortcut phrases must name the app. If a stream is up, the action goes through it.
  Otherwise `SessionController.runInBackground` waits up to 4 s for the Mac (25 s, with wake
  packets, if it's asleep) and uses `ClientConnection.perform`: a catalog-mode connection
  that sends one `run` and no picture. The Mac applies "Ask Before Each Connection" to it.
- **Widgets and Control Center:** in the `PocketDeskWidgets` extension, Home Screen tiles, Lock
  Screen accessories and a configurable control open `pocketdesk://run?id=…`, and the app
  runs the shortcut and shows the stream. A tap on a tile that has nothing to look at
  (`MacAction.needsPicture` is false, for media keys) runs it in the background instead. The extension can't hold a QUIC connection or the
  phone's identity, so the app does the work.
- **Sharing:** shortcuts live in the App Group `group.com.pocketdesk.app`
  (`ShortcutLibrary.sharedURL`; an older copy is moved across once). When they change, the
  app reloads widget timelines and controls, and calls `updateAppShortcutParameters()`.

## Clipboard (protocol v7)

`clipboard(ClipboardItem)` (text, or a base64 PNG) goes both ways while a stream is live.
Items over 1 MB of text or 8 MB of image are refused, not truncated.

- **Mac → phone:** `HostSession` polls `NSPasteboard.changeCount` every 500 ms (`ClipboardSink`,
  faked in tests) and sends anything copied after the stream started. On the phone it lands
  on `UIPasteboard`, which never prompts for writes.
- **Phone → Mac:** the stream's paste button is the system `PasteButton`, so reading the
  phone's clipboard needs no "Allow Paste" prompt: the tap is the consent. The Mac writes the
  item and records the new change count, so it never echoes back.
- **Off switch:** Settings › Share Clipboard (`Hello.clipboardEnabled`,
  `setClipboardEnabled` mid-session). Turning it on never sends what was copied while it was off.

## Waking the Mac (protocol v6)

Each `helloAck` carries `WakeInfo`, sent only inside the encrypted session:
- each `en*` interface's MAC, IPv4 and subnet broadcast address,
- whether `pmset`'s `womp` ("Wake for network access") is on.

The phone keeps the last useful one per Mac (`PerMac<WakeInfo>`, `wake.json`). A paired Mac
that isn't advertising shows as Asleep with **Wake & Use**. That sends magic packets
(`WakeOnLAN`, `WakeSender`) to the subnet broadcast, 255.255.255.255 and the Mac's last
address, on ports 9 and 7, at 0, 3, 8 and 15 s. The phone connects as soon as the Mac shows
up in Bonjour, or gives up after 40 s with a hint about the setting (`WakeAttempts`, a pure
value with tests). When the setting is off, the Mac's menu bar panel says so.

**iOS limit:** broadcasting needs Apple's `com.apple.developer.networking.multicast`
entitlement, which Apple grants on request. Until the app has it, a real iPhone's broadcasts
fail and only the direct packet goes out. That direct packet reliably reaches a Mac on
Ethernet, but often not one asleep on Wi-Fi. The Simulator isn't restricted. A Bonjour Sleep
Proxy (an Apple TV or HomePod) keeps a sleeping Mac advertised and wakes it on connect,
with no packets needed.

The Mac also advertises what kind of Mac it is in its TXT record (`k`: laptop, imac, mini,
studio, pro, desktop; `MacModel`), so the phone draws the right device, even while it's asleep.

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
  On iOS, the TLS key and paired certificate pins are available after the first device
  unlock so Lock Screen intents can authenticate. The pairing JSON contains no private key;
  existing pairing files migrate to UntilFirstUserAuthentication protection on a successful
  read while unlocked. Per-Mac Face ID locks still apply to background commands.
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
     keyboard via `UIKeyInput`, window picker. Trackpad mode (`TrackpadPointer`: relative,
     accelerated pointer; hold then drag = click-drag; two-finger tap = right-click) with a
     zoomed view that follows the pointer (`ZoomViewport.reveal`), and three-finger swipes
     sent as Mission Control's ⌃-arrow shortcuts (`MacGesture`). A zoomed view also follows
     the text caret while typing (protocol v18): after a keystroke settles (`caretDelay`) the
     host reads the focused element's caret through Accessibility (`AccessibilityCaret`:
     `AXSelectedTextRange` → `AXBoundsForRange`), maps it onto the streamed picture
     (`Caret(frame:in:)`) and sends `caret` if it moved; the phone pans to it, clear of the
     keyboard. It goes straight to the stream view (`SessionController.onCaret`), not
     through the store. Apps that don't expose text ranges just don't send one.
2. **v0.2 – Window picker**: stream one window fitted to the phone, app switcher UI.
3. **v0.3 – Thumb UI**: read the frontmost app's menus/toolbar via AX APIs and render them as
   native controls. Menus done (protocol v14); toolbars to come.
4. **v1.0 – Anywhere**: relay + hole punching, wake-on-LAN, subscription. Design and checklist in
   [RELAY.md](RELAY.md).
5. **Later – Agent**: natural-language tasks executed on the Mac with a live view.
