import { useEffect, useState } from "react";
import { AnimatePresence, motion } from "motion/react";
import { Reveal, ease } from "../ui.jsx";

const POINTS = [
  {
    title: "Home Wi-Fi comes first",
    text: "When your Mac is nearby, PocketDesk connects straight to it, as it always has. The relay is only used when it isn't.",
  },
  {
    title: "Sealed end to end",
    text: "Your screen, typing and files are encrypted between your iPhone and your Mac. The relay passes sealed data along and can't read any of it.",
  },
  {
    title: "Set up once",
    text: "Pair at home, then turn on Remote Access on your Mac and your iPhone. Keep your Mac awake with PocketDesk open.",
  },
];

const icon = (d) => (
  <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
    {d}
  </svg>
);
const PHONE = icon(<><rect x="7" y="2.5" width="10" height="19" rx="2.5" /><path d="M10.5 18.5h3" /></>);
const MAC = icon(<><rect x="3.5" y="5" width="17" height="11" rx="1.5" /><path d="M2 19h20" /></>);
const GLOBE = icon(<><circle cx="12" cy="12" r="9" /><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18" /></>);

// Packets flowing along a link: dots that slide across and fade at the ends.
function Link({ active, delay = 0 }) {
  return (
    <span className={`ra-link ${active ? "on" : ""}`} aria-hidden="true">
      {active &&
        [0, 1, 2].map((i) => (
          <motion.i
            key={i}
            initial={{ left: "0%", opacity: 0 }}
            animate={{ left: ["0%", "100%"], opacity: [0, 1, 1, 0] }}
            transition={{ duration: 1.6, ease: "linear", repeat: Infinity, delay: delay + i * 0.53, times: [0, 0.15, 0.85, 1] }}
          />
        ))}
    </span>
  );
}

export function RemoteAccess() {
  // The diagram alternates between the two ways a session runs.
  const [away, setAway] = useState(false);
  useEffect(() => {
    const timer = setInterval(() => setAway((a) => !a), 4200);
    return () => clearInterval(timer);
  }, []);

  return (
    <section className="remote" id="remote">
      <Reveal as="p" className="label">
        Remote Access <span className="beta">Beta</span>
      </Reveal>
      <Reveal as="h2" className="section-title" delay={0.05}>
        Your Mac,<br /><em>from anywhere.</em>
      </Reveal>
      <Reveal as="p" className="intro" delay={0.1}>
        Out on cellular, at a friend's, across town: reach the Mac you left at home the same way you
        do on the sofa.
      </Reveal>

      <Reveal className="ra-diagram" delay={0.15}>
        <div className="ra-row" role="img" aria-label="At home your iPhone connects straight to your Mac; away, it connects through an encrypted relay.">
          <span className="ra-device">{PHONE}<small>iPhone</small></span>
          {away ? (
            <>
              <Link active />
              <motion.span
                className="ra-relay"
                key="relay"
                initial={{ scale: 0.6, opacity: 0 }}
                animate={{ scale: 1, opacity: 1 }}
                transition={{ duration: 0.5, ease }}
              >
                {GLOBE}
                <small>Relay</small>
              </motion.span>
              <Link active delay={0.8} />
            </>
          ) : (
            <Link active />
          )}
          <span className="ra-device">{MAC}<small>Mac</small></span>
        </div>
        <AnimatePresence mode="wait">
          <motion.p
            key={away ? "away" : "home"}
            className="ra-caption"
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -8 }}
            transition={{ duration: 0.4, ease }}
          >
            {away ? (
              <><b>Away:</b> through an encrypted relay that only passes sealed data along.</>
            ) : (
              <><b>At home:</b> straight to your Mac over your own Wi-Fi.</>
            )}
          </motion.p>
        </AnimatePresence>
      </Reveal>

      <div className="ra-points">
        {POINTS.map((p, i) => (
          <Reveal key={p.title} className="ra-point" delay={0.1 + i * 0.08}>
            <b>{p.title}</b>
            <p>{p.text}</p>
          </Reveal>
        ))}
      </div>
      <Reveal as="p" className="fineprint" delay={0.2}>
        Off until you turn it on · Use PocketDesk's relay or run your own: it's open source
      </Reveal>
    </section>
  );
}
