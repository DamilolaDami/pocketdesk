import { useState } from "react";
import { AnimatePresence, motion, useMotionValueEvent, useScroll } from "motion/react";
import { AppleIcon, DOWNLOAD, ease } from "../ui.jsx";

// The download pill that rides along the bottom once the hero's own button is gone,
// and steps aside for the closing section's.
export function Dock() {
  const { scrollY } = useScroll();
  const [shown, setShown] = useState(false);
  useMotionValueEvent(scrollY, "change", () => {
    const hero = document.querySelector(".hero");
    const closing = document.querySelector(".closing");
    const pastHero = hero && hero.getBoundingClientRect().bottom < window.innerHeight * 0.35;
    const atClosing = closing && closing.getBoundingClientRect().top < window.innerHeight * 0.8;
    setShown(Boolean(pastHero && !atClosing));
  });

  return (
    <AnimatePresence>
      {shown && (
        <motion.div
          className="dock"
          initial={{ y: 120, opacity: 0 }}
          animate={{ y: 0, opacity: 1 }}
          exit={{ y: 120, opacity: 0 }}
          transition={{ duration: 0.55, ease }}
        >
          <motion.a href={DOWNLOAD} whileHover={{ scale: 1.03 }} whileTap={{ scale: 0.97 }} tabIndex={-1}>
            <AppleIcon /> Download PocketDesk for free
          </motion.a>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
