import { useState } from "react";
import { AnimatePresence, motion, useMotionValueEvent, useScroll } from "motion/react";
import { smoothLink } from "../smooth.js";
import { AppleIcon, DOWNLOAD, REPO, ease } from "../ui.jsx";

const LINKS = [
  ["#how", "How it works"],
  ["#shortcuts", "Shortcuts"],
  ["#features", "Features"],
  ["#privacy", "Privacy"],
];

// `home` is "" on the home page, where links scroll in place, and "./" on other pages,
// where they lead back to the home page's sections.
export function Nav({ home = "" }) {
  const onLink = home ? undefined : smoothLink;
  const { scrollY } = useScroll();
  const [scrolled, setScrolled] = useState(false);
  useMotionValueEvent(scrollY, "change", (y) => setScrolled(y > 120));

  return (
    <header className="nav">
      <motion.nav
        className="nav-pill"
        aria-label="Main"
        initial={{ y: -24, opacity: 0 }}
        animate={{ y: 0, opacity: 1 }}
        transition={{ duration: 0.8, ease, delay: 0.1 }}
      >
        <a className="nav-logo" href={home || "#top"} onClick={onLink}>
          <img src="assets/icon.png" alt="" width="28" height="28" />
          <span>PocketDesk</span>
        </a>
        <span className="nav-links">
          {LINKS.map(([href, label]) => (
            <a key={href} href={home + href} onClick={onLink}>{label}</a>
          ))}
          <a href={REPO}>GitHub</a>
        </span>
      </motion.nav>
      <AnimatePresence>
        {scrolled && (
          <motion.a
            className="nav-download"
            href={DOWNLOAD}
            initial={{ opacity: 0, y: -10, scale: 0.96 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: -10, scale: 0.96 }}
            transition={{ duration: 0.35, ease }}
          >
            <AppleIcon /> Download
          </motion.a>
        )}
      </AnimatePresence>
    </header>
  );
}
