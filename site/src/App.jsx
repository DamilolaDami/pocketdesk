import { MotionConfig } from "motion/react";
import { useSmoothScroll } from "./smooth.js";
import { Nav } from "./sections/Nav.jsx";
import { Hero } from "./sections/Hero.jsx";
import { Steps } from "./sections/Steps.jsx";
import { Gallery } from "./sections/Gallery.jsx";
import { Shortcuts } from "./sections/Shortcuts.jsx";
import { Features } from "./sections/Features.jsx";
import { Privacy } from "./sections/Privacy.jsx";
import { OpenSource } from "./sections/OpenSource.jsx";
import { GetStarted } from "./sections/GetStarted.jsx";
import { Closing } from "./sections/Closing.jsx";
import { Footer } from "./sections/Footer.jsx";
import { Dock } from "./sections/Dock.jsx";

export default function App() {
  useSmoothScroll();
  return (
    <MotionConfig reducedMotion="user">
      <Nav />
      <main>
        <Hero />
        <Steps />
        <Gallery />
        <Shortcuts />
        <Features />
        <Privacy />
        <OpenSource />
        <GetStarted />
        <Closing />
      </main>
      <Footer />
      <Dock />
    </MotionConfig>
  );
}
