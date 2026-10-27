import { useState } from "react";
import { AppleIcon, REPO, TESTFLIGHT } from "../ui.jsx";

import { RELEASES, latestMac, latestIPhone } from "../release-data.js";

export function Releases() {
  const [platform, setPlatform] = useState("all");
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
        <div className="release-download-heading"><h2 id="latest-downloads">Get the latest.</h2><span className="release-current">Version {latestMac.version}{latestMac.build && ` · Build ${latestMac.build}`}</span></div>
        <div className="release-download-grid">
          <article>
            <span className="release-platform-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><rect x="4" y="4" width="16" height="12" rx="2" /><path d="M2 20h20l-2-4H4z" /></svg></span>
            <div><h3>PocketDesk for Mac</h3><p>Developer ID signed. Apple notarized.<br />macOS 26 or later.</p></div>
            <a className="button button-primary" href={latestMac.macURL}><AppleIcon /> Download for Mac</a>
          </article>
          <article>
            <span className="release-platform-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5"><rect x="7" y="2" width="10" height="20" rx="3" /><path d="M10 18.5h4" /></svg></span>
            <div><h3>PocketDesk for iPhone <span>Beta</span></h3><p>{latestIPhone.iphoneStatus === "available" ? "Join the public beta on TestFlight." : "The next iPhone build is awaiting review."}<br />iOS 26 or later.</p></div>
            <a className="button button-quiet" href={TESTFLIGHT}>Get the iPhone beta <span aria-hidden="true">↗</span></a>
          </article>
        </div>
        <p className="release-install-note">New here? Install PocketDesk on both devices, then pair on the same Wi-Fi. The apps guide you through it.</p>
      </section>

      <section className="release-history" aria-labelledby="release-history-title">
        <div className="release-history-top"><h2 id="release-history-title">The changes, as they happen.</h2><div className="release-filters" role="group" aria-label="Filter releases by platform">{[["all", "Everything"], ["mac", "Mac"], ["iphone", "iPhone"]].map(([id, label]) => <button key={id} type="button" aria-pressed={platform === id} onClick={() => setPlatform(id)}>{label}</button>)}</div></div>
        <p className="release-result" aria-live="polite">{shown.length} {platform === "all" ? "releases" : `${platform === "mac" ? "Mac" : "iPhone"} releases`}</p>
        <div className="release-list">{shown.map((release) => <article className="release-entry" key={release.id} id={release.id}>
          <div className="release-entry-meta"><time dateTime={release.date}>{new Date(`${release.date}T12:00:00Z`).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" })}</time><span>{release.macStatus === "preview" ? "Preview · iPhone review pending" : release.latest ? "Latest release" : "Earlier release"}</span><a href={`#${release.id}`} aria-label={`Link to version ${release.version}${release.build ? ` build ${release.build}` : ""}`}>#{release.build || release.version}</a></div>
          <div className="release-entry-body">
            <div className="release-version"><span>Version {release.version}</span>{release.build && <span>Build {release.build}</span>}{[...new Set(release.changes.map((change) => change.platform))].map((item) => <span key={item}>{item === "mac" ? (release.macStatus === "preview" ? "Mac preview" : "Mac") : release.iphoneStatus === "awaiting-review" ? "iPhone · Awaiting review" : "iPhone beta"}</span>)}</div>
            <h3>{release.title}</h3><p className="release-summary">{release.summary}</p>
            <ul>{release.changes.filter((change) => platform === "all" || change.platform === platform).map((change) => <li key={change.title}><span className="label">{change.platform === "mac" ? "Mac" : "iPhone"}</span><h4>{change.title}</h4><p>{change.text}</p></li>)}</ul>
            <div className="release-entry-links">{release.source && <a className="text-link" href={release.source}>Release on GitHub ↗</a>}{release.macURL && (platform === "all" || platform === "mac") && <a className="text-link" href={release.macURL}>{release.macStatus === "preview" ? "Download Mac preview ↗" : "Download this Mac version ↗"}</a>}</div>
          </div>
        </article>)}</div>
      </section>
      <aside className="release-feedback"><h2>Found something we can make better?</h2><p>Tell us what happened, which version you’re using and what you expected. TestFlight feedback works too.</p><a className="button button-quiet" href={`${REPO}/issues`}>Report a problem <span aria-hidden="true">↗</span></a></aside>
    </div>
  </>;
}
