import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { MotionConfig } from "motion/react";
import "lenis/dist/lenis.css";
import "./fonts.js";
import "./styles.css";
import { useSmoothScroll } from "./smooth.js";
import { Nav } from "./sections/Nav.jsx";
import { Footer } from "./sections/Footer.jsx";
import { PrivacyPolicy } from "./legal/PrivacyPolicy.jsx";
import { Terms } from "./legal/Terms.jsx";

// privacy.html and terms.html share this entry; each says which document it is on <body>.
const PAGES = { privacy: PrivacyPolicy, terms: Terms };

function LegalApp() {
  useSmoothScroll();
  const Page = PAGES[document.body.dataset.page];
  return (
    <MotionConfig reducedMotion="user">
      <Nav home="./" />
      <main><Page /></main>
      <Footer home="./" />
    </MotionConfig>
  );
}

createRoot(document.getElementById("root")).render(
  <StrictMode>
    <LegalApp />
  </StrictMode>,
);
