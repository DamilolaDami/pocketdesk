import { motion } from "motion/react";
import { AppleIcon, DOWNLOAD, TESTFLIGHT, Reveal } from "../ui.jsx";

export function Closing() {
  return (
    <section className="closing">
      <div className="closing-light" aria-hidden="true" />
      <Reveal>
        <img src="assets/icon.png" alt="" width="96" height="96" />
      </Reveal>
      <Reveal as="h2" delay={0.05}>
        Ready to leave<br /><em>the desk?</em>
      </Reveal>
      <Reveal delay={0.12}>
        <div className="cta-row closing-actions">
          <motion.a className="button button-primary cta-mac" href={DOWNLOAD} whileHover={{ scale: 1.03 }} whileTap={{ scale: 0.97 }}>
            <AppleIcon /> Download for Mac
          </motion.a>
          <motion.a className="button button-glass cta-iphone" href={TESTFLIGHT} whileHover={{ scale: 1.03 }} whileTap={{ scale: 0.97 }}>
            Get the iPhone beta
          </motion.a>
        </div>
        <p className="fineprint">Free · macOS 26 or later · iPhone beta on TestFlight</p>
      </Reveal>
    </section>
  );
}
