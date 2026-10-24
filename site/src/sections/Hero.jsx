import { useRef, useState } from "react";
import { motion, useReducedMotion } from "motion/react";
import { AppleIcon, DOWNLOAD, TESTFLIGHT, ease } from "../ui.jsx";

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
  const reducedMotion = useReducedMotion();

  return (
    <section className="hero hero-with-film" id="top">
      <div className="hero-light" aria-hidden="true">
        {LIGHTS.map((l, i) => (
          <motion.span
            key={i}
            style={{ left: l.left, top: l.top, width: l.size, height: l.size }}
            animate={reducedMotion ? undefined : { x: l.x, y: l.y }}
            transition={{ duration: l.duration, ease: "easeInOut", repeat: Infinity }}
          />
        ))}
      </div>

      <motion.p
        className="hero-wordmark"
        aria-hidden="true"
        initial={{ opacity: 0, y: 60 }}
        animate={{ opacity: 1 }}
        transition={{ duration: 1.4, ease, delay: 0.2 }}
      >
        PocketDesk
      </motion.p>

      <div className="hero-inner">
        <motion.div
          className="hero-copy"
          variants={stagger}
          initial="hidden"
          animate="show"
        >
          <motion.p className="eyebrow" variants={rise}>For Mac and iPhone</motion.p>
          <motion.h1 variants={rise}>
            Your Mac,<br /><em>in your pocket.</em>
          </motion.h1>
          <motion.p className="lede" variants={rise}>
            Your Mac’s screen, sound and shortcuts, right on your iPhone.
            From the sofa or across town, encrypted end to end.
          </motion.p>
          <motion.div className="cta-row" variants={rise}>
            <motion.a className="button button-light cta-mac" href={DOWNLOAD} whileHover={{ scale: 1.03 }} whileTap={{ scale: 0.97 }}>
              <AppleIcon /> Download for Mac
            </motion.a>
            <motion.a className="button button-glass cta-iphone" href={TESTFLIGHT} whileHover={{ scale: 1.03 }} whileTap={{ scale: 0.97 }}>
              Get the iPhone beta
            </motion.a>
          </motion.div>
          <motion.p className="fineprint" variants={rise}>Free & open source <span aria-hidden="true">·</span> No account needed<br />Requires a Mac and iPhone running macOS 26 / iOS 26</motion.p>
        </motion.div>

        <LaunchFilm />
      </div>

      <div className="hero-arc" aria-hidden="true" />
    </section>
  );
}

function LaunchFilm() {
  const video = useRef(null);
  const [started, setStarted] = useState(false);
  const [failed, setFailed] = useState(false);
  const play = async () => {
    setFailed(false);
    try {
      await video.current.play();
    } catch {
      setFailed(true);
    }
  };

  return <figure className="launch-film">
    <div className="launch-player">
      <video ref={video} controls={started} playsInline preload="none" width="1920" height="1080"
        poster="media/pocketdesk-launch-poster.jpg" aria-label="PocketDesk launch film"
        onPlay={() => setStarted(true)} onError={() => setFailed(true)}>
        <source src="media/pocketdesk-launch.mp4" type="video/mp4" />
        Your browser doesn’t support embedded video. <a href="media/pocketdesk-launch.mp4">Watch the launch film.</a>
      </video>
      {!started && !failed && <button type="button" className="launch-play" onClick={play} aria-label="Play PocketDesk launch film">
        <span className="launch-play-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z" /></svg></span>
        <span>Play the launch film<small>22 seconds</small></span>
      </button>}
      {failed && <div className="launch-error" role="status"><p>The film couldn’t play here.</p><a href="media/pocketdesk-launch.mp4">Open the video directly ↗</a></div>}
    </div>
    <figcaption><span className="launch-dot" aria-hidden="true" />PocketDesk, in motion.<span>Picture. Sound. A little freedom.</span></figcaption>
  </figure>;
}
