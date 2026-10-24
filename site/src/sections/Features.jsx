import { motion, useReducedMotion } from "motion/react";
import { Reveal, ease } from "../ui.jsx";

const icon = (d) => (
  <svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
    {d}
  </svg>
);

const FEATURES = [
  {
    label: "Clipboard",
    text: "Copy on your iPhone, paste on your Mac. Copy on the Mac, paste on the phone. Text and images.",
    icon: icon(<><rect x="6" y="4" width="12" height="17" rx="2.5" /><path d="M9 4.5h6M9 10h6M9 14h4" /></>),
  },
  {
    label: "Files",
    text: "Send photos and files to your Mac's Downloads, or browse its folders and bring a file back.",
    icon: icon(<><path d="M3.5 7.5a2 2 0 0 1 2-2h4l2 2h7a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z" /><path d="M12 11v5M9.5 13.5 12 11l2.5 2.5" /></>),
  },
  {
    label: "Now playing",
    text: "See what's playing, with the artwork, and play, skip or change the volume from your Mac's card.",
    icon: icon(<><circle cx="7" cy="17" r="2.5" /><circle cx="17" cy="15" r="2.5" /><path d="M9.5 17V6l10-2v11" /></>),
  },
  {
    label: "Wake from sleep",
    text: "A sleeping Mac wakes up when you tap it, then connects as soon as it's up.",
    icon: icon(<><path d="M12 3v3M12 18v3M4.6 4.6l2.1 2.1M17.3 17.3l2.1 2.1M3 12h3M18 12h3" /><circle cx="12" cy="12" r="3.5" /></>),
  },
  {
    label: "Face ID lock",
    text: "Keep a Mac behind Face ID, so picking up your iPhone isn't enough to use it.",
    icon: icon(<><path d="M4 8V6a2 2 0 0 1 2-2h2M16 4h2a2 2 0 0 1 2 2v2M20 16v2a2 2 0 0 1-2 2h-2M8 20H6a2 2 0 0 1-2-2v-2" /><path d="M9 9v1.5M15 9v1.5M12 9v4h-1M9.5 16a4 4 0 0 0 5 0" /></>),
  },
  {
    label: "Sound",
    text: "Hear your Mac on your iPhone: a video, a call, a song. Or keep it on the Mac's speakers.",
    icon: icon(<><path d="M4 10v4h3.5L12 18V6L7.5 10z" /><path d="M15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11" /></>),
  },
];

export function Features() {
  return (
    <section className="features" id="features">
      <Reveal as="h2" className="section-title center">
        All the little things<br /><em>your Mac does.</em>
      </Reveal>
      <div className="bento">
        {FEATURES.map((f, i) => (
          <motion.article
            key={f.label}
            className="card"
            initial={{ opacity: 0, y: 40 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, margin: "-60px" }}
            transition={{ duration: 0.8, ease, delay: (i % 3) * 0.08 }}
            whileHover={{ y: -6 }}
          >
            <span className="card-icon">{f.icon}</span>
            <p className="label">{f.label}</p>
            <p>{f.text}</p>
          </motion.article>
        ))}
        <motion.article
          className="card card-full"
          initial={{ opacity: 0, y: 40 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-60px" }}
          transition={{ duration: 0.8, ease }}
        >
          <div>
            <p className="label">Any display, any window</p>
            <p>
              Pick which display to show, or a single window fitted to your phone. The picture adapts
              to your Wi-Fi: sharp when it can be, smooth when it has to be, and gentle on your
              battery in Low Power Mode.
            </p>
          </div>
          <QualityPicker />
        </motion.article>
      </div>
    </section>
  );
}

// A little segmented control that cycles on its own, to show the three quality modes.
function QualityPicker() {
  const reducedMotion = useReducedMotion();
  const options = ["Best", "Balanced", "Battery Saver"];
  return (
    <div className="quality" aria-hidden="true">
      <motion.span
        className="quality-thumb"
        animate={reducedMotion ? { x: 0 } : { x: ["0%", "100%", "200%", "100%", "0%"] }}
        transition={{ duration: 9, ease, repeat: Infinity, times: [0, 0.25, 0.5, 0.75, 1] }}
      />
      {options.map((o) => <span key={o}>{o}</span>)}
    </div>
  );
}
