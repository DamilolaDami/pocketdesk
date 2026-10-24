import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { MotionConfig } from "motion/react";
import "lenis/dist/lenis.css";
import "./fonts.js";
import "./styles.css";
import "./built.css";
import { Nav } from "./sections/Nav.jsx";
import { Footer } from "./sections/Footer.jsx";
import { HowItsBuilt } from "./pages/HowItsBuilt.jsx";
import { useSmoothScroll } from "./smooth.js";

function BuiltApp() {
  useSmoothScroll();
  return <MotionConfig reducedMotion="user"><Nav home="./" page="built" /><main><HowItsBuilt /></main><Footer home="./" /></MotionConfig>;
}

createRoot(document.getElementById("root")).render(<StrictMode><BuiltApp /></StrictMode>);
