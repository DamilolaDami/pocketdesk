import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Relative base, so the built site works from any path (GitHub Pages, a subfolder, a CDN).
export default defineConfig({
  base: "./",
  plugins: [react()],
  build: {
    rollupOptions: {
      input: {
        main: "index.html",
        privacy: "privacy.html",
        terms: "terms.html",
        security: "security.html",
        built: "how-its-built.html",
        releases: "releases.html",
      },
    },
  },
});
