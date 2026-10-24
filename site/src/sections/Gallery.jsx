import { useRef } from "react";
import { motion, useScroll, useTransform } from "motion/react";
import { Phone, Reveal } from "../ui.jsx";

const SHOTS = [
  {
    src: "shots/stream-keyboard.jpg",
    alt: "The key bar under the stream: esc, tab, control, option, shift, command, arrows, undo, cut, copy and paste",
    title: "Every key a Mac has.",
    text: "Escape, tab, the modifiers, arrows and the edit keys sit above the keyboard, and you choose which rows show.",
  },
  {
    src: "shots/stream-menus.jpg",
    alt: "Xcode's menu bar as a native iPhone sheet with File, Edit, View, Editor, Product and Debug tabs",
    title: "Its menus, made native.",
    text: "The app in front hands its menu bar to your iPhone, so File, Edit and View become big, tappable lists.",
  },
];

// Each phone tips up from the table as it scrolls into view.
function TiltShot({ shot }) {
  const ref = useRef(null);
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start end", "center center"] });
  const rotateX = useTransform(scrollYProgress, [0, 1], [32, 0]);
  const scale = useTransform(scrollYProgress, [0, 1], [0.84, 1]);
  const opacity = useTransform(scrollYProgress, [0, 0.4], [0, 1]);
  return (
    <figure className="tilt" ref={ref}>
      <motion.div style={{ rotateX, scale, opacity, transformPerspective: 1400 }}>
        <Phone landscape src={shot.src} alt={shot.alt} />
      </motion.div>
      <Reveal as="figcaption">
        <b>{shot.title}</b> {shot.text}
      </Reveal>
    </figure>
  );
}

export function Gallery() {
  return (
    <section className="gallery">
      <Reveal as="h2" className="section-title center">
        Made for your thumbs,<br /><em>not a mouse.</em>
      </Reveal>
      <div className="gallery-list">
        {SHOTS.map((shot) => <TiltShot key={shot.src} shot={shot} />)}
      </div>
    </section>
  );
}
