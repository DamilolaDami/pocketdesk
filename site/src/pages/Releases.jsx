import { useState } from "react";
import { AppleIcon, REPO, TESTFLIGHT } from "../ui.jsx";

// Keep release history explicit: versions, dates and links refer to published artifacts.
const RELEASES = [
  {
    id: "1-0-74", version: "1.0", build: "74", date: "2026-10-25", latest: true,
    title: "A warmer welcome. A better way to find your files.",
    summary: "A little guidance to get connected, and a few useful tools once you’re there.",
    macURL: `${REPO}/releases/download/v1.0.0/PocketDesk.dmg`, source: `${REPO}/releases/tag/v1.0.0`,
    changes: [
      { platform: "iphone", title: "A guided first connection", text: "New iPhone setup walks you through getting the Mac app ready and finding your Mac, then hands over to the familiar scan-and-confirm pairing screens. Skip it any time; paired users go straight to their Macs." },
      { platform: "iphone", title: "Find the file you came for", text: "Search filenames in the current Mac folder, filter by file type, and sort by name, date modified or size. Folders stay first, and a reset gets you back to the full listing." },
      { platform: "iphone", title: "A little help, when you need it", text: "Your first connection offers a dismissible touch and keyboard guide. Setup and controls help are also available in Settings. Download errors keep your file browser in place." },
      { platform: "mac", title: "Get the iPhone app before pairing", text: "Mac onboarding now includes a TestFlight QR code, an Open button and a copyable link. The installation code is separate from the private pairing code that follows." },
    ],
  },
  {
    id: "1-0-69", version: "1.0", build: "69", date: "2026-10-24", title: "The iPhone beta, updated.",
    summary: "An update to the public TestFlight beta.",
    changes: [{ platform: "iphone", title: "Try PocketDesk on your own iPhone", text: "Pair with your Mac, stream its screen and sound, use shortcuts, and send files. Remote Access is available as an optional beta setup for connections away from home." }],
  },
  {
    id: "0-1-0", version: "0.1.0", date: "2026-10-24", title: "Hello, Mac.",
    summary: "The first public Mac release: a small app in your menu bar, ready for your iPhone.",
    macURL: `${REPO}/releases/download/v0.1.0/PocketDesk.dmg`, source: `${REPO}/releases/tag/v0.1.0`,
    changes: [{ platform: "mac", title: "The Mac host arrives", text: "A Developer ID-signed, Apple-notarized download with setup for Screen Recording and Accessibility, plus a pairing code for the iPhone app. Requires macOS 26 or later." }],
  },
];

export function Releases() {
  const [platform, setPlatform] = useState("all");
  const latest = RELEASES[0];
  const shown = RELEASES.filter((release) => platform === "all" || release.changes.some((change) => change.platform === platform));

  return <>
    <header className="release-hero" id="top">
      <div className="release-wrap">
        <p className="eyebrow">Releases</p>
        <h1>Small improvements.<br /><em>More room to roam.</em></h1>
        <p>What’s new in PocketDesk, for the Mac on your desk and the iPhone in your pocket.</p>
      </div>
    </header>
    <div className="release-wrap release-content">
      <section className="release-downloads" aria-labelledby="latest-downloads">
        <div className="release-download-heading"><h2 id="latest-downloads">Get the latest.</h2><span className="release-current">Version 1.0 · Build 74</span></div>
        <div className="release-download-grid">
          <article>
            <span className="release-platform-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><rect x="4" y="4" width="16" height="12" rx="2" /><path d="M2 20h20l-2-4H4z" /></svg></span>
            <div><h3>PocketDesk for Mac</h3><p>Developer ID signed. Apple notarized.<br />macOS 26 or later.</p></div>
            <a className="button button-primary" href={latest.macURL}><AppleIcon /> Download for Mac</a>
          </article>
          <article>
            <span className="release-platform-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><rect x="7" y="2" width="10" height="20" rx="3" /><path d="M10 18.5h4" /></svg></span>
            <div><h3>PocketDesk for iPhone <span>Beta</span></h3><p>Join the public beta on TestFlight.<br />iOS 26 or later.</p></div>
            <a className="button button-quiet" href={TESTFLIGHT}>Get the iPhone beta <span aria-hidden="true">↗</span></a>
          </article>
        </div>
        <p className="release-install-note">New here? Install PocketDesk on both devices, then pair on the same Wi-Fi. The apps guide you through it.</p>
      </section>

      <section className="release-history" aria-labelledby="release-history-title">
        <div className="release-history-top"><h2 id="release-history-title">The changes, as they happen.</h2><div className="release-filters" role="group" aria-label="Filter releases by platform">{[["all", "Everything"], ["mac", "Mac"], ["iphone", "iPhone"]].map(([id, label]) => <button key={id} type="button" aria-pressed={platform === id} onClick={() => setPlatform(id)}>{label}</button>)}</div></div>
        <p className="release-result" aria-live="polite">{shown.length} {platform === "all" ? "releases" : `${platform === "mac" ? "Mac" : "iPhone"} releases`}</p>
        <div className="release-list">{shown.map((release) => <article className="release-entry" key={release.id} id={release.id}>
          <div className="release-entry-meta"><time dateTime={release.date}>{new Date(`${release.date}T12:00:00Z`).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" })}</time><span>{release.latest ? "Latest release" : "Earlier release"}</span><a href={`#${release.id}`} aria-label={`Link to version ${release.version}${release.build ? ` build ${release.build}` : ""}`}>#{release.build || release.version}</a></div>
          <div className="release-entry-body">
            <div className="release-version"><span>Version {release.version}</span>{release.build && <span>Build {release.build}</span>}{[...new Set(release.changes.map((change) => change.platform))].map((item) => <span key={item}>{item === "mac" ? "Mac" : "iPhone beta"}</span>)}</div>
            <h3>{release.title}</h3><p className="release-summary">{release.summary}</p>
            <ul>{release.changes.filter((change) => platform === "all" || change.platform === platform).map((change) => <li key={change.title}><span className="label">{change.platform === "mac" ? "Mac" : "iPhone"}</span><h4>{change.title}</h4><p>{change.text}</p></li>)}</ul>
            <div className="release-entry-links">{release.source && <a className="text-link" href={release.source}>Release on GitHub ↗</a>}{release.macURL && (platform === "all" || platform === "mac") && <a className="text-link" href={release.macURL}>Download this Mac version ↗</a>}</div>
          </div>
        </article>)}</div>
      </section>
      <aside className="release-feedback"><h2>Found something we can make better?</h2><p>Tell us what happened, which version you’re using and what you expected. TestFlight feedback works too.</p><a className="button button-quiet" href={`${REPO}/issues`}>Report a problem <span aria-hidden="true">↗</span></a></aside>
    </div>
  </>;
}
