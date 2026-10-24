import { useEffect, useState } from "react";
import { motion } from "motion/react";
import { Marquee, Phone, Reveal, ease } from "../ui.jsx";

const PHONES = [
  {
    src: "shots/s-new.jpg",
    alt: "The New Shortcut sheet: ready-made tiles for websites like Netflix and YouTube, apps like Xcode, Slack and Spotify, and Mac controls like Spotlight and Mission Control",
    title: "Start from a gallery.",
    text: "Ready-made tiles for sites, apps and Mac controls, with their real icons.",
    rotate: -6,
  },
  {
    src: "shots/s-editor.jpg",
    alt: "Editing the Netflix shortcut: its name, a Website action set to netflix.com, Add Step, and Show the Mac turned on",
    title: "Or make your own.",
    text: "Open a site, an app, a Mac Shortcut or a key combo. Put {text} in a link to be asked each time.",
    rotate: 0,
  },
  {
    src: "shots/s-steps.jpg",
    alt: "Adding a step to a shortcut: Wait, Mac Control, Run Mac Shortcut, Open App or Open Website",
    title: "Chain steps into routines.",
    text: "Open Netflix, wait a moment, go full screen: one tap from the sofa.",
    rotate: 6,
  },
];

// The ready-made tiles from the app's gallery, with the icons it shows for them.
const TILES = [
  ["Netflix", "netflix"], ["Xcode", "xcode"], ["Mission Control", "mission-control"], ["Spotify", "spotify"],
  ["Search YouTube", "search-youtube"], ["Slack", "slack"], ["Spotlight", "spotlight"], ["Prime Video", "prime-video"],
  ["Terminal", "terminal"], ["Find in Maps", "maps"], ["VS Code", "vscode"], ["Messages", "messages"],
  ["Disney+", "disney"], ["Notes", "notes"], ["GitHub", "github"], ["Safari", "safari"],
  ["Search Google", "search-google"], ["Photos", "photos"], ["Twitch", "twitch"], ["Finder", "finder"],
  ["Gmail", "gmail"], ["Music", "music"], ["Calendar", "calendar"], ["Mail", "mail"],
  ["YouTube", "youtube"], ["Search Netflix", "search-netflix"],
];

const fan = {
  hidden: { opacity: 0, y: 120, rotate: 0 },
  show: (p) => ({ opacity: 1, y: 0, rotate: p.rotate, transition: { duration: 1.1, ease, delay: p.delay } }),
};

// The fan tilt reads well side by side, but not with the phones stacked on a narrow screen.
function useNarrow() {
  const [narrow, setNarrow] = useState(() => window.matchMedia("(max-width: 900px)").matches);
  useEffect(() => {
    const query = window.matchMedia("(max-width: 900px)");
    const update = () => setNarrow(query.matches);
    query.addEventListener("change", update);
    return () => query.removeEventListener("change", update);
  }, []);
  return narrow;
}

export function Shortcuts() {
  const narrow = useNarrow();
  const half = Math.ceil(TILES.length / 2);
  const tile = ([name, icon]) => (
    <span className="tile-chip">
      <img src={`tiles/${icon}.png`} alt="" width="28" height="28" decoding="async" />
      {name}
    </span>
  );
  return (
    <section className="shortcuts" id="shortcuts">
      <Reveal as="p" className="label">Shortcuts</Reveal>
      <Reveal as="h2" className="section-title" delay={0.05}>
        One tap for the things<br /><em>you do every day.</em>
      </Reveal>
      <Reveal as="p" className="intro" delay={0.1}>
        Open Netflix on the big screen, jump into Xcode, bring up Mission Control, or run any
        Shortcut you've made on your Mac. Each tile runs on the Mac you pick, from the app, Siri,
        a widget or Control Center.
      </Reveal>

      <div className="shortcut-row">
        {PHONES.map((p, i) => (
          <motion.figure
            key={p.src}
            variants={fan}
            custom={{ rotate: narrow ? 0 : p.rotate, delay: narrow ? 0 : i * 0.12 }}
            initial="hidden"
            whileInView="show"
            viewport={{ once: true, margin: "-120px" }}
            whileHover={{ y: -12, rotate: 0, transition: { duration: 0.4, ease } }}
          >
            <Phone src={p.src} alt={p.alt} />
            <figcaption><b>{p.title}</b> {p.text}</figcaption>
          </motion.figure>
        ))}
      </div>

      <div className="tile-marquees" aria-label="Some of the ready-made tiles">
        <Marquee items={TILES.slice(0, half)} render={tile} duration={45} />
        <Marquee items={TILES.slice(half)} render={tile} duration={50} reverse />
      </div>

      <Reveal className="siri" delay={0.1}>
        <span className="siri-orb" aria-hidden="true">
          <i className="blob blob-a" />
          <i className="blob blob-b" />
          <i className="blob blob-c" />
          <i className="blob blob-d" />
        </span>
        <p>“Open Netflix with PocketDesk”</p>
        <span className="label">Siri · Widgets · Control Center</span>
      </Reveal>
    </section>
  );
}
