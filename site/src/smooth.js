import Lenis from "lenis";
import { useEffect } from "react";

// One Lenis instance for the page. Motion's scroll hooks read the real scroll position,
// which Lenis drives, so they stay in step with the smoothing.
let lenis = null;

export function useSmoothScroll() {
  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    lenis = new Lenis({ lerp: 0.09 });
    let frame;
    const raf = (time) => {
      lenis.raf(time);
      frame = requestAnimationFrame(raf);
    };
    frame = requestAnimationFrame(raf);
    return () => {
      cancelAnimationFrame(frame);
      lenis.destroy();
      lenis = null;
    };
  }, []);
}

export function scrollToTarget(target) {
  if (lenis) {
    lenis.scrollTo(target, { offset: typeof target === "number" ? 0 : -72, duration: 1.4 });
    return;
  }
  if (typeof target === "number") window.scrollTo({ top: target, behavior: "smooth" });
  else document.querySelector(target)?.scrollIntoView({ behavior: "smooth" });
}

// For in-page links: <a href="#features" onClick={smoothLink}>.
export function smoothLink(event) {
  const hash = event.currentTarget.getAttribute("href");
  if (!hash?.startsWith("#")) return;
  event.preventDefault();
  scrollToTarget(hash === "#top" ? 0 : hash);
}
