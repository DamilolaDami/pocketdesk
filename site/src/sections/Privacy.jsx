import { Marquee, Reveal } from "../ui.jsx";

// Settings-style rows, scrolling past like the reference's privacy toggles.
const ROW_ONE = [
  { label: "Account needed", on: false },
  { label: "End-to-end encryption", on: true },
  { label: "Relay can see your screen", on: false },
  { label: "Pinned keys", on: true },
  { label: "Tracking", on: false },
];
const ROW_TWO = [
  { label: "Pairing code on both", on: true },
  { label: "Analytics", on: false },
  { label: "Open source", on: true },
  { label: "Ads", on: false },
  { label: "Face ID lock", on: true },
];

function Setting({ label, on }) {
  return (
    <span className="setting">
      {label}
      <span className={`toggle ${on ? "on" : ""}`}><i /></span>
    </span>
  );
}

export function Privacy() {
  return (
    <section className="privacy" id="privacy">
      <Reveal className="privacy-card">
        <svg className="privacy-lock" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.5">
          <rect x="5" y="10.5" width="14" height="10" rx="2.5" />
          <path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" />
        </svg>
        <h2 className="section-title center">
          Only you and your Mac<br /><em>can see it.</em>
        </h2>
        <div className="privacy-rows" aria-hidden="true">
          <Marquee items={ROW_ONE} render={(s) => <Setting {...s} />} duration={38} />
          <Marquee items={ROW_TWO} render={(s) => <Setting {...s} />} duration={44} reverse />
        </div>
        <p>
          At home your iPhone talks straight to your Mac over your own network. Away, Remote Access
          passes sealed data through a relay that can't read it. There's no account to make and
          nothing to track. Every connection is encrypted with TLS 1.3, and each side only trusts the
          exact key it saw when you paired.
        </p>
        <p className="privacy-links">
          <a className="text-link" href="privacy.html">Read the privacy policy <span aria-hidden="true">→</span></a>
          <a className="text-link" href="https://github.com/DamilolaDami/pocketdesk/blob/main/SECURITY.md">How it's secured <span aria-hidden="true">→</span></a>
        </p>
      </Reveal>
    </section>
  );
}
