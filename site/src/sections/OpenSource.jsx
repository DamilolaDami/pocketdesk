import { motion } from "motion/react";
import { REPO, Reveal, ease } from "../ui.jsx";

const STACK = ["Swift 6", "SwiftUI", "QUIC", "HEVC", "ScreenCaptureKit", "TLS 1.3"];

export function OpenSource() {
  return (
    <section className="open">
      <Reveal as="p" className="label">Open source</Reveal>
      <Reveal as="h2" className="section-title" delay={0.05}>Built in the open.</Reveal>
      <Reveal as="p" className="intro" delay={0.1}>
        PocketDesk is free, and all of it is on GitHub under the Apache License: the Swift, the
        protocol, and how it fits together. Read it, build it yourself, or help make it better.
      </Reveal>
      <div className="stack">
        {STACK.map((s, i) => (
          <motion.span
            key={s}
            initial={{ opacity: 0, y: 16, scale: 0.9 }}
            whileInView={{ opacity: 1, y: 0, scale: 1 }}
            viewport={{ once: true }}
            transition={{ duration: 0.6, ease, delay: 0.15 + i * 0.06 }}
          >
            {s}
          </motion.span>
        ))}
      </div>
      <Reveal delay={0.2}>
        <motion.a className="button button-quiet" href={REPO} whileHover={{ scale: 1.03 }} whileTap={{ scale: 0.97 }}>
          View on GitHub
        </motion.a>
      </Reveal>
    </section>
  );
}
