import { useState } from "react";
import { Reveal, REPO, TESTFLIGHT } from "../ui.jsx";
import { smoothLink } from "../smooth.js";

const source = (path) => `${REPO}/blob/main/${path}`;
const kit = "Packages/PocketDeskKit/Sources/";

const LANES = [
  { id: "video", name: "Picture", tag: "HEVC · one-way stream", direction: "Mac → iPhone", text: "ScreenCaptureKit captures a display or window. VideoToolbox encodes it with the Mac’s hardware, and the iPhone displays the HEVC frames using Apple’s media stack.", path: `${kit}PDHostCore/HEVCEncoder.swift` },
  { id: "audio", name: "Sound", tag: "AAC-LC · one-way stream", direction: "Mac → iPhone", text: "Timestamped audio has its own stream, separate from video. A large video frame doesn’t sit ahead of an audio packet in the same ordered queue.", path: `${kit}PDClientCore/AudioAssembler.swift` },
  { id: "input", name: "Touch", tag: "Binary · datagrams", direction: "iPhone → Mac", text: "Pointer movement travels in small datagrams. An old position can give way to a newer one. Key presses and releases use the reliable control stream so a lost key-up won’t leave a modifier held down.", path: `${kit}PDProtocol/InputEvent.swift` },
  { id: "control", name: "Control", tag: "JSON · reliable stream", direction: "Both ways", text: "Keys, shortcuts, menus, clipboard messages and session settings need to arrive reliably and in order. File data uses additional streams, keeping large transfers out of the control queue.", path: `${kit}PDTransport/QUICPeerSession.swift` },
];

const PIPELINE = [
  ["01", "Capture", "ScreenCaptureKit", "The Mac captures the display or window you choose. Frames arrive in a pixel format the encoder can use directly.", `${kit}PDHostCore/ScreenCaptureSource.swift`],
  ["02", "Encode", "VideoToolbox · HEVC", "Hardware encoding is tuned for interaction, with no frame reordering. Under pressure, the host drops captured frames before encoding rather than building a queue of old pictures.", `${kit}PDHostCore/HEVCEncoder.swift`],
  ["03", "Carry", "Network.framework · QUIC", "Picture, sound and control use separate channels over an encrypted session. The host adjusts bitrate, frame rate and resolution as the connection changes.", `${kit}PDTransport/QUICPeerSession.swift`],
  ["04", "Display", "AVSampleBufferDisplayLayer", "The iPhone assembles the frames and hands them to Apple’s media stack. Your touches travel back to the Mac, mapped to the display or window being streamed.", `${kit}PDClientCore/FrameAssembler.swift`],
];

const MODULES = [
  ["PDProtocol", "The shared language", "Messages, frame headers and binary input events. The wire format lives apart from the UI.", "01"],
  ["PDSecurity", "Identity & trust", "Device keys, certificates, fingerprints, pairing and the record of devices you’ve approved.", "02"],
  ["PDTransport", "Getting there", "Bonjour discovery, QUIC sessions, independent channels and the optional relay path.", "03"],
  ["PDHostCore", "The Mac’s work", "Screen capture, encoding, input injection and host sessions. macOS-specific work stays here.", "04"],
  ["PDClientCore", "The phone’s work", "Discovery, connection state, frame assembly, audio playback and the client session.", "05"],
];

function Device({ phone = false }) {
  return <div className="build-device">
    <svg viewBox="0 0 64 64" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
      {phone ? <><rect x="19" y="7" width="26" height="50" rx="7" /><path d="M27 13h10M28 51h8" /><circle cx="32" cy="32" r="6" /></> : <><rect x="8" y="12" width="48" height="32" rx="4" /><path d="M4 51h56l-4-7H8z" /><circle cx="32" cy="28" r="6" /></>}
    </svg>
    <b>{phone ? "Your iPhone" : "Your Mac"}</b><span>{phone ? "SwiftUI client" : "Native menu bar host"}</span>
  </div>;
}

function ConnectionExplorer() {
  const [away, setAway] = useState(false);
  const [lane, setLane] = useState("video");
  const selected = LANES.find((item) => item.id === lane);
  return <div className="build-explorer">
    <div className="build-explorer-top">
      <span className="label">Follow the connection</span>
      <div className="build-switch" role="group" aria-label="Connection route">
        <button type="button" aria-pressed={!away} onClick={() => setAway(false)}>At home</button>
        <button type="button" aria-pressed={away} onClick={() => setAway(true)}>Away <span>Beta</span></button>
      </div>
    </div>
    <div className="build-route" role="img" aria-label={away ? "Your Mac and iPhone keep their pinned encrypted session through a forwarding relay." : "Your Mac and iPhone connect directly over your local network."}>
      <Device />
      <div className="build-route-middle">
        <div className="build-route-line"><span aria-hidden="true">↔</span>{away && <b>Relay</b>}<span aria-hidden="true">↔</span></div>
        <span>{away ? "Sealed packets forwarded" : "Direct on your local network"}</span>
        <small>QUIC · TLS 1.3 · pinned certificates</small>
      </div>
      <Device phone />
    </div>
    <p className="build-route-note" aria-live="polite">{away ? "Remote Access wraps the existing device-to-device session in a relay path. The relay forwards encrypted packets; it doesn’t get the keys to the screen or sound. Pair locally first, enable Remote Access on both devices, and keep your Mac awake." : "Bonjour finds nearby Macs. After pairing, the phone connects straight to the Mac over your own network. There’s no account server in the middle."}</p>
    <div className="build-lanes" role="group" aria-label="Explore session channels">
      {LANES.map((item) => <button type="button" key={item.id} aria-pressed={lane === item.id} aria-controls="channel-description" onClick={() => setLane(item.id)}>{item.name}<span aria-hidden="true">↗</span></button>)}
    </div>
    <div className="build-lane-detail" id="channel-description" aria-live="polite" aria-atomic="true">
      <div><span className="label">{selected.direction}</span><h3>{selected.tag}</h3></div>
      <div><p>{selected.text}</p><a className="text-link" href={source(selected.path)}>See the implementation <span aria-hidden="true">↗</span></a></div>
    </div>
  </div>;
}

export function HowItsBuilt() {
  return <>
    <header className="build-hero" id="top">
      <div className="build-wrap">
        <p className="eyebrow">How it’s built</p>
        <h1>A little closer<br />to <em>the metal.</em></h1>
        <p className="build-lede">Two native apps. One shared Swift package. Here’s how your Mac’s screen becomes something you can touch on your iPhone.</p>
        <div className="build-hero-meta"><span>Swift 6</span><span>iOS 26 / macOS 26</span><span>Apache 2.0</span></div>
        <a href="#connection" onClick={smoothLink} className="build-scroll">Follow a session <span aria-hidden="true">↓</span></a>
      </div>
      <div className="build-hero-mark" aria-hidden="true">&lt; / &gt;</div>
    </header>

    <div className="build-wrap build-content">
      <nav className="build-index" aria-label="On this page">{[["connection", "The connection"], ["pipeline", "The picture"], ["trust", "The trust"], ["code", "The code"]].map(([id, text]) => <a key={id} href={`#${id}`} onClick={smoothLink}>{text}<span aria-hidden="true">↘</span></a>)}</nav>

      <section id="connection" className="build-section">
        <Reveal><p className="label">01 / The connection</p><h2 className="section-title">One session.<br /><em>Room for everything.</em></h2><p className="build-intro">A picture shouldn’t hold up a key press. PocketDesk uses QUIC through Apple’s Network framework, with different channels for different kinds of work. Choose a route, then a channel to look inside.</p></Reveal>
        <ConnectionExplorer />
      </section>

      <section id="pipeline" className="build-section">
        <Reveal><p className="label">02 / The picture</p><h2 className="section-title">From pixels<br /><em>to your pocket.</em></h2><p className="build-intro">The Mac does the capture and encoding. The iPhone handles the display. Apple’s hardware media APIs do the heavy lifting at both ends.</p></Reveal>
        <ol className="build-pipeline">{PIPELINE.map(([number, title, tech, text, path]) => <li key={number}><span className="build-node">{number}</span><div><h3>{title}</h3><span className="build-tech">{tech}</span><p>{text}</p><a href={source(path)} className="text-link">Read the source <span aria-hidden="true">↗</span></a></div></li>)}</ol>
        <p className="build-aside"><b>Quality is a moving target.</b> Best, Balanced and Battery Saver set the ceiling. Link adaptation can step down from there. Low Power Mode on the iPhone selects the Battery Saver ceiling.</p>
      </section>

      <section id="trust" className="build-section">
        <Reveal><p className="label">03 / The trust</p><h2 className="section-title">Recognise the device.<br /><em>Not just the address.</em></h2><p className="build-intro">A familiar name on the network isn’t proof of identity. Pairing establishes which cryptographic keys your devices should trust.</p></Reveal>
        <div className="build-trust">
          <article><span className="step-num">01</span><h3>A key of its own.</h3><p>Each device creates a P-256 identity key in its Keychain and a self-signed certificate. Its fingerprint identifies the certificate the other device will remember.</p><a className="text-link" href={source(`${kit}PDSecurity/DeviceIdentity.swift`)}>Device identity ↗</a></article>
          <article><span className="step-num">02</span><h3>A deliberate introduction.</h3><p>The Mac’s QR code includes its fingerprint and a short-lived, single-use token. Both devices show a six-digit code, and you approve the pairing on the Mac.</p><a className="text-link" href={source(`${kit}PDSecurity/Pairing.swift`)}>Pairing flow ↗</a></article>
          <article><span className="step-num">03</span><h3>Trust, checked again.</h3><p>Later sessions use mutual TLS and pinned certificates. An optional relay carries the packets without replacing that inner trust relationship. Forgetting a phone revokes its access.</p><a className="text-link" href={`${REPO}/blob/main/SECURITY.md`}>Security notes ↗</a></article>
        </div>
        <a className="build-privacy-link" href="privacy.html">What stays on your devices, and what travels between them <span aria-hidden="true">→</span></a>
      </section>

      <section id="code" className="build-section">
        <Reveal><p className="label">04 / The code</p><h2 className="section-title">Small apps.<br /><em>Shared foundations.</em></h2><p className="build-intro">The app targets handle the interface and wiring. The main logic lives in PocketDeskKit, split into five modules so the protocol, security and sessions can be tested apart from the screens.</p></Reveal>
        <div className="build-modules">{MODULES.map(([name, title, text, number]) => <a key={name} href={`${REPO}/tree/main/${kit}${name}`} className="build-module"><span className="label">{number} / {name}</span><h3>{title}<span aria-hidden="true">↗</span></h3><p>{text}</p></a>)}</div>
        <div className="build-relay-note"><span className="label">And, optionally, a relay</span><h3>A small Rust server.</h3><p>Quinn, Tokio and rustls provide the forwarding service. It authorizes sessions against the Mac’s allowed phones and forwards opaque datagrams. Off-network direct hole punching is still future work; the current remote path is relay forwarding.</p><a className="text-link" href={`${REPO}/tree/main/Services/relay`}>Explore the relay ↗</a></div>
      </section>

      <section className="build-finish">
        <p className="label">Nothing behind the curtain</p><h2 className="section-title">Don’t take our word.<br /><em>Read the code.</em></h2><p>The apps, shared package and relay are open source. Start with the architecture, run the tests, or make something better.</p>
        <div className="cta-row"><a className="button button-primary" href={REPO}>Explore on GitHub ↗</a><a className="button button-quiet" href={source("CONTRIBUTING.md")}>Build it yourself ↗</a></div>
        <a className="text-link" href={TESTFLIGHT}>Just want to try it? Get the iPhone beta ↗</a>
      </section>
    </div>
  </>;
}
