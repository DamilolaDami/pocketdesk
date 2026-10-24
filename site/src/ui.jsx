import { motion } from "motion/react";

export const ease = [0.22, 1, 0.36, 1];
// Always the newest notarized DMG: each release uploads it as PocketDesk.dmg.
export const DOWNLOAD = "https://github.com/DamilolaDami/pocketdesk/releases/latest/download/PocketDesk.dmg";
export const REPO = "https://github.com/DamilolaDami/pocketdesk";

// Fades and lifts its content in the first time it scrolls into view.
export function Reveal({ as = "div", delay = 0, y = 28, children, ...rest }) {
  const Tag = motion[as];
  return (
    <Tag
      initial={{ opacity: 0, y }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: "-80px" }}
      transition={{ duration: 0.9, ease, delay }}
      {...rest}
    >
      {children}
    </Tag>
  );
}

// An iPhone frame. Pass `src` for a single screenshot, or children to fill the screen.
export function Phone({ src, alt = "", landscape = false, eager = false, className = "", children }) {
  return (
    <div className={`phone ${landscape ? "phone-landscape" : "phone-portrait"} ${className}`}>
      <div className="phone-screen">
        {children ?? <img src={src} alt={alt} loading={eager ? "eager" : "lazy"} decoding="async" />}
      </div>
    </div>
  );
}

// An endless horizontal strip. The items are doubled so the loop has no seam.
export function Marquee({ items, render, reverse = false, duration = 40 }) {
  const doubled = [...items, ...items];
  return (
    <div className="marquee">
      <motion.div
        className="marquee-track"
        animate={{ x: reverse ? ["-50%", "0%"] : ["0%", "-50%"] }}
        transition={{ duration, ease: "linear", repeat: Infinity }}
      >
        {doubled.map((item, i) => (
          <div className="marquee-item" key={i} aria-hidden={i >= items.length}>
            {render(item)}
          </div>
        ))}
      </motion.div>
    </div>
  );
}

export function AppleIcon() {
  return (
    <svg className="apple" viewBox="0 0 17 20" aria-hidden="true">
      <path d="M14.1 10.6c0-2.6 2.1-3.8 2.2-3.9-1.2-1.8-3.1-2-3.7-2-1.6-.2-3.1.9-3.9.9-.8 0-2-.9-3.4-.9C3.6 4.8 1.9 5.8 1 7.5c-1.9 3.3-.5 8.1 1.3 10.8.9 1.3 2 2.7 3.4 2.7 1.3-.1 1.9-.9 3.5-.9s2.1.9 3.5.8c1.4 0 2.3-1.3 3.2-2.6 1-1.5 1.4-2.9 1.4-3-.1 0-2.7-1-2.7-4.7zM11.5 3c.7-.9 1.2-2.1 1.1-3.3-1 0-2.3.7-3 1.6-.7.8-1.2 2-1.1 3.2 1.1.1 2.3-.6 3-1.5z" />
    </svg>
  );
}
