import { useRef, useState } from "react";
import { AnimatePresence, motion, useMotionValueEvent, useScroll } from "motion/react";
import { Phone, Reveal, ease } from "../ui.jsx";

const STEPS = [
  {
    title: "Every Mac, at a glance",
    text: "Each Mac gets a card: whether it's awake, how good the connection is, its battery, and what it's playing. One tap on Use This Mac and you're on its screen.",
    src: "shots/home.jpg",
    alt: "PocketDesk's home screen with a MacBook Pro card",
  },
  {
    title: "Do it without opening the screen",
    text: "Paste what you copied, bring back the Mac's clipboard, send photos and files, or browse its folders, all from the card. Pick touch or trackpad, and lock any Mac behind Face ID.",
    src: "shots/card-menu.jpg",
    alt: "The Mac card's menu: Paste, Copy from Mac, Send Photos, Send Files, Mac Files, Lock with Face ID",
  },
  {
    title: "Tiles for what you do most",
    text: "Netflix on the big screen, Spotlight, Mission Control, any Mac Shortcut. Your tiles run on the Mac you pick, from the app, Siri, widgets and Control Center.",
    src: "shots/shortcuts.jpg",
    alt: "The Shortcuts tab with tiles for Netflix, YouTube, Music, Safari, Spotlight and Mission Control",
  },
];

// The text scrolls normally and the phone stays pinned beside it. The step whose middle is
// nearest the reading line is the one the phone shows, so the change follows the text the
// reader is looking at and a quick flick can't skip one.
export function Steps() {
  const items = useRef([]);
  const [active, setActive] = useState(0);
  const { scrollY } = useScroll();
  useMotionValueEvent(scrollY, "change", () => {
    // On a phone the pinned phone covers the top of the screen, so read lower down.
    const narrow = window.matchMedia("(max-width: 900px)").matches;
    const line = window.innerHeight * (narrow ? 0.78 : 0.5);
    let nearest = 0;
    let best = Infinity;
    items.current.forEach((el, i) => {
      if (!el) return;
      const r = el.getBoundingClientRect();
      const distance = Math.abs(r.top + r.height / 2 - line);
      if (distance < best) {
        best = distance;
        nearest = i;
      }
    });
    setActive(nearest);
  });

  return (
    <section className="steps" id="how">
      <Reveal as="h2" className="section-title center">
        Your Macs,<br /><em>one tap away.</em>
      </Reveal>
      <div className="steps-grid">
        <ol className="step-list">
          {STEPS.map((step, i) => (
            <li
              key={step.title}
              ref={(el) => { items.current[i] = el; }}
              className={`step ${i === active ? "is-active" : ""}`}
            >
              <span className="step-num">0{i + 1}</span>
              <h3>{step.title}</h3>
              <p>{step.text}</p>
            </li>
          ))}
        </ol>
        <div className="step-stage">
          <div className="step-glow" aria-hidden="true" />
          <Phone>
            <AnimatePresence initial={false}>
              <motion.img
                key={active}
                src={STEPS[active].src}
                alt={STEPS[active].alt}
                initial={{ opacity: 0, scale: 1.04 }}
                animate={{ opacity: 1, scale: 1 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 0.5, ease }}
              />
            </AnimatePresence>
          </Phone>
          <div className="step-dots" aria-hidden="true">
            {STEPS.map((s, i) => <span key={s.title} className={i === active ? "on" : ""} />)}
          </div>
        </div>
      </div>
    </section>
  );
}
