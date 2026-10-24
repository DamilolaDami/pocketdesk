import { useRef } from "react";
import { motion, useScroll, useTransform } from "motion/react";
import { smoothLink } from "../smooth.js";
import { AppleIcon, Phone, RELEASES, ease } from "../ui.jsx";

const stagger = { hidden: {}, show: { transition: { staggerChildren: 0.09, delayChildren: 0.15 } } };
const rise = {
  hidden: { opacity: 0, y: 28, filter: "blur(6px)" },
  show: { opacity: 1, y: 0, filter: "blur(0px)", transition: { duration: 0.9, ease } },
};

// Soft patches of light drifting over the blue, like sun through leaves.
const LIGHTS = [
  { left: "8%", top: "12%", size: 520, x: [0, 60, -20, 0], y: [0, 30, 60, 0], duration: 22 },
  { left: "55%", top: "-8%", size: 640, x: [0, -70, 30, 0], y: [0, 50, -10, 0], duration: 26 },
  { left: "30%", top: "45%", size: 460, x: [0, 40, -50, 0], y: [0, -40, 20, 0], duration: 19 },
  { left: "75%", top: "50%", size: 380, x: [0, -30, 40, 0], y: [0, 30, -30, 0], duration: 24 },
];


export function Hero() {
  const ref = useRef(null);
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start start", "end start"] });
  const copyY = useTransform(scrollYProgress, [0, 1], [0, 120]);
  const copyOpacity = useTransform(scrollYProgress, [0, 0.55], [1, 0]);
  const devicesY = useTransform(scrollYProgress, [0, 1], [0, 180]);
  const devicesRotate = useTransform(scrollYProgress, [0, 1], [0, -3]);
  const wordY = useTransform(scrollYProgress, [0, 1], [0, -80]);

  return (
    <section className="hero" id="top" ref={ref}>
      <div className="hero-light" aria-hidden="true">
        {LIGHTS.map((l, i) => (
          <motion.span
            key={i}
            style={{ left: l.left, top: l.top, width: l.size, height: l.size }}
            animate={{ x: l.x, y: l.y }}
            transition={{ duration: l.duration, ease: "easeInOut", repeat: Infinity }}
          />
        ))}
      </div>

      <motion.p
        className="hero-wordmark"
        aria-hidden="true"
        style={{ y: wordY }}
        initial={{ opacity: 0, y: 60 }}
        animate={{ opacity: 1 }}
        transition={{ duration: 1.4, ease, delay: 0.2 }}
      >
        PocketDesk
      </motion.p>

      <div className="hero-inner">
        <motion.div
          className="hero-copy"
          style={{ y: copyY, opacity: copyOpacity }}
          variants={stagger}
          initial="hidden"
          animate="show"
        >
          <motion.p className="eyebrow" variants={rise}>For Mac and iPhone</motion.p>
          <motion.h1 variants={rise}>
            Your Mac,<br /><em>in your pocket.</em>
          </motion.h1>
          <motion.p className="lede" variants={rise}>
            See it, touch it, type on it, play its music and send it files, from the sofa or the
            next room. Straight from your iPhone to your Mac, encrypted end to end.
          </motion.p>
          <motion.div className="cta-row" variants={rise}>
            <motion.a className="button button-light" href={RELEASES} whileHover={{ scale: 1.03 }} whileTap={{ scale: 0.97 }}>
              <AppleIcon /> Download for Mac
            </motion.a>
            <motion.a className="button button-glass" href="#get" onClick={smoothLink} whileHover={{ scale: 1.03 }} whileTap={{ scale: 0.97 }}>
              Get the iPhone app
            </motion.a>
          </motion.div>
          <motion.p className="fineprint" variants={rise}>Free and open source · macOS 26 and iOS 26</motion.p>
        </motion.div>

        <motion.div className="hero-devices" style={{ y: devicesY, rotate: devicesRotate }}>
          <motion.div
            className="hero-landscape"
            initial={{ opacity: 0, x: 120, rotate: 6 }}
            animate={{ opacity: 1, x: 0, rotate: 0 }}
            transition={{ duration: 1.3, ease, delay: 0.3 }}
          >
            <Phone landscape eager src="shots/stream-xcode.jpg" alt="Xcode on a Mac, streamed sharp to an iPhone held sideways, with PocketDesk's controls along the bottom" />
          </motion.div>
          <motion.div
            className="hero-portrait"
            initial={{ opacity: 0, y: 140, rotate: -14 }}
            animate={{ opacity: 1, y: 0, rotate: -7 }}
            transition={{ duration: 1.3, ease, delay: 0.55 }}
          >
            <Phone eager src="shots/home.jpg" alt="PocketDesk's home screen: a MacBook Pro card that's online, with Use This Mac and the song playing on the Mac" />
          </motion.div>
        </motion.div>
      </div>

      <div className="hero-arc" aria-hidden="true" />
    </section>
  );
}
