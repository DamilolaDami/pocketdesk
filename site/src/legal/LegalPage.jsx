import { useState } from "react";
import { motion, useMotionValueEvent, useScroll } from "motion/react";
import { scrollToTarget } from "../smooth.js";
import { ease } from "../ui.jsx";

// A long document with a contents list that follows along. `sections` is a list of
// { id, title, body }, and `summary` is shown above them as the short version.
export function LegalPage({ eyebrow, title, updated, intro, summary, sections }) {
  const [current, setCurrent] = useState(sections[0].id);
  const { scrollY } = useScroll();
  useMotionValueEvent(scrollY, "change", () => {
    let last = sections[0].id;
    for (const s of sections) {
      const el = document.getElementById(s.id);
      if (el && el.getBoundingClientRect().top < window.innerHeight * 0.3) last = s.id;
    }
    setCurrent(last);
  });

  const go = (event, id) => {
    event.preventDefault();
    scrollToTarget(`#${id}`);
    history.replaceState(null, "", `#${id}`);
  };

  return (
    <>
      <header className="legal-hero">
        <div className="legal-hero-inner">
          <motion.p className="eyebrow" initial={{ opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.8, ease }}>
            {eyebrow}
          </motion.p>
          <motion.h1 initial={{ opacity: 0, y: 24 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.9, ease, delay: 0.08 }}>
            {title}
          </motion.h1>
          <motion.p className="legal-intro" initial={{ opacity: 0, y: 24 }} animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.9, ease, delay: 0.16 }}>
            {intro}
          </motion.p>
          <motion.p className="fineprint" initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ duration: 0.9, delay: 0.3 }}>
            Last updated {updated}
          </motion.p>
        </div>
        <div className="hero-arc" aria-hidden="true" />
      </header>

      {summary && (
        <section className="legal-summary">
          <p className="label">The short version</p>
          <ul>
            {summary.map(([heading, text], i) => (
              <motion.li
                key={heading}
                initial={{ opacity: 0, y: 24 }}
                whileInView={{ opacity: 1, y: 0 }}
                viewport={{ once: true }}
                transition={{ duration: 0.7, ease, delay: i * 0.06 }}
              >
                <b>{heading}</b>
                <span>{text}</span>
              </motion.li>
            ))}
          </ul>
        </section>
      )}

      <div className="legal-body">
        <nav className="legal-toc" aria-label="Contents">
          <p className="label">Contents</p>
          <ol>
            {sections.map((s) => (
              <li key={s.id} className={s.id === current ? "on" : ""}>
                <a href={`#${s.id}`} onClick={(e) => go(e, s.id)}>{s.title}</a>
              </li>
            ))}
          </ol>
        </nav>
        <article className="legal-text">
          {sections.map((s, i) => (
            <section key={s.id} id={s.id}>
              <h2><span className="step-num">{String(i + 1).padStart(2, "0")}</span>{s.title}</h2>
              {s.body}
            </section>
          ))}
        </article>
      </div>
    </>
  );
}
