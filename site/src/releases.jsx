import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { MotionConfig } from "motion/react";
import "lenis/dist/lenis.css";
import "./fonts.js";
import "./styles.css";
import "./releases.css";
import { Nav } from "./sections/Nav.jsx";
import { Footer } from "./sections/Footer.jsx";
import { Releases } from "./pages/Releases.jsx";
import { useSmoothScroll } from "./smooth.js";

function ReleasesApp() {
  useSmoothScroll();
  return <MotionConfig reducedMotion="user"><Nav home="./" page="releases" /><main><Releases /></main><Footer home="./" /></MotionConfig>;
}
createRoot(document.getElementById("root")).render(<StrictMode><ReleasesApp /></StrictMode>);
