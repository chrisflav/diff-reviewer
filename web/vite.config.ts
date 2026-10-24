import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The backend `npm run dev` proxies `/api` to.
const backend = process.env.DIFF_REVIEWER_URL ?? "http://127.0.0.1:8090";

export default defineConfig({
  plugins: [react()],
  build: {
    // Served by `diff-reviewer serve --site web/dist`.
    outDir: "dist",
    emptyOutDir: true,
    // Fingerprinted, which is what lets the server cache `assets/` immutably.
    assetsDir: "assets",
    sourcemap: true,
  },
  server: {
    // Same-origin in development too: the session cookie is `SameSite=Strict`.
    proxy: { "/api": { target: backend, changeOrigin: false } },
  },
});
