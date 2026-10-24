import { useRef, useState } from "react";
import { AnimatePresence, motion, useMotionValueEvent, useScroll } from "motion/react";
import { smoothLink } from "../smooth.js";
import { AppleIcon, DOWNLOAD, TESTFLIGHT, REPO, ease } from "../ui.jsx";

const LINKS = [
  ["#how", "How it works"],
  ["#remote", "Remote Access"],
  ["#shortcuts", "Shortcuts"],
  ["#features", "Features"],
  ["#privacy", "Privacy"],
];

// `home` is "" on the home page, where links scroll in place, and "./" on other pages,
// where they lead back to the home page's sections.
export function Nav({ home = "" }) {
  const [menuOpen, setMenuOpen] = useState(false);
  const menuButton = useRef(null);
  const onLink = home ? undefined : smoothLink;
  const { scrollY } = useScroll();
  const [scrolled, setScrolled] = useState(false);
  useMotionValueEvent(scrollY, "change", (y) => setScrolled(y > 120));

  return (
    <header className="nav" onKeyDown={(event) => {
      if (event.key === "Escape" && menuOpen) {
        setMenuOpen(false);
        menuButton.current?.focus();
      }
    }}>
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
        <button ref={menuButton} type="button" className="nav-toggle" aria-expanded={menuOpen} aria-controls="mobile-menu" onClick={() => setMenuOpen(!menuOpen)}>
          {menuOpen ? "Close" : "Explore"}
          <span aria-hidden="true">{menuOpen ? "−" : "+"}</span>
        </button>
        {menuOpen && (
          <div id="mobile-menu" className="mobile-menu">
            <p className="label">Make yourself at home</p>
            {LINKS.map(([href, label]) => (
              <a key={href} href={home + href} onClick={(event) => { onLink?.(event); setMenuOpen(false); }}>{label}<span aria-hidden="true">↗</span></a>
            ))}
            <a href={REPO}>GitHub<span aria-hidden="true">↗</span></a>
            <a className="mobile-menu-cta" href={TESTFLIGHT}>Get the iPhone beta<span aria-hidden="true">→</span></a>
          </div>
        )}
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
