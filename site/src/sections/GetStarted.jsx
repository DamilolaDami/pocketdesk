import { useState } from "react";
import { AnimatePresence, motion } from "motion/react";
import { Reveal, ease } from "../ui.jsx";

const SETUP = [
  ["Install PocketDesk on your Mac", "Download it, drag it to Applications and open it. It walks you through two permissions and lives in your menu bar."],
  ["Get the iPhone app", "PocketDesk for iPhone is in beta on TestFlight. Ask for an invite on GitHub."],
  ["Scan the code", "Your Mac shows a code; your iPhone scans it. You confirm the same six digits on both, once."],
];

const FAQ = [
  ["Does it work away from home?", "Not yet. Your iPhone and Mac need to be on the same network for now. Reaching your Mac from anywhere is the next big thing we're working on."],
  ["Why does it need Screen Recording and Accessibility?", "Screen Recording lets your iPhone see the screen; Accessibility lets your taps and typing become clicks and keystrokes. The picture only goes to iPhones you've paired, and only while one is connected."],
  ["Can it show Netflix or other films?", "The sound and controls work, but protected video shows as black. macOS keeps it out of every screen capture, and we wouldn't get around that."],
  ["What does it cost?", "Nothing. PocketDesk is free and open source."],
];

function Question({ q, a }) {
  const [open, setOpen] = useState(false);
  return (
    <div className={`faq-item ${open ? "open" : ""}`}>
      <button type="button" aria-expanded={open} onClick={() => setOpen(!open)}>
        {q}
        <motion.span className="faq-plus" animate={{ rotate: open ? 45 : 0 }} transition={{ duration: 0.35, ease }}>+</motion.span>
      </button>
      <AnimatePresence initial={false}>
        {open && (
          <motion.div
            className="faq-answer"
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: "auto", opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            transition={{ duration: 0.45, ease }}
          >
            <p>{a}</p>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}

export function GetStarted() {
  return (
    <section className="get" id="get">
      <Reveal as="h2" className="section-title">
        Set up in<br /><em>two minutes.</em>
      </Reveal>
      <ol className="setup">
        {SETUP.map(([title, text], i) => (
          <Reveal as="li" key={title} delay={i * 0.1}>
            <motion.span
              className="setup-line"
              initial={{ scaleX: 0 }}
              whileInView={{ scaleX: 1 }}
              viewport={{ once: true }}
              transition={{ duration: 1, ease, delay: 0.2 + i * 0.1 }}
            />
            <span className="step-num">0{i + 1}</span>
            <b>{title}</b>
            <p>{text}</p>
          </Reveal>
        ))}
      </ol>
      <Reveal className="faq">
        {FAQ.map(([q, a]) => <Question key={q} q={q} a={a} />)}
      </Reveal>
    </section>
  );
}
