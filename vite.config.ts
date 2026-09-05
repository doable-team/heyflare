import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "node:path";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: { alias: { "@shared": path.resolve(__dirname, "src/shared"), "@": path.resolve(__dirname, "src/web") } },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    // Vite's default target (Safari 14 and up) stays: the Mac app runs on macOS 12's WebKit, which
    // is Safari 15 and has no class static blocks — a newer target would break it for no measured gain.
    modulePreload: { polyfill: false },
    rollupOptions: {
      output: {
        // A module shared by two lazy pages becomes its own chunk, however small — which turned
        // single icons into twenty one-kilobyte requests. Grouping the libraries below is what
        // fixes that; Rollup's minimum-chunk-size merge was tried and rejected, because it folds a
        // lazy tree into its own lazy children and undoes the split.
        //
        // Group the libraries by how often they change. `vendor` (React, the router, the query
        // client) changes only on a dependency bump, so with immutable caching a deploy costs a
        // returning visitor the app code alone, not React again. `icons` and `ui` are shared by
        // nearly every page, so each page needs two well-cached files rather than a dozen tiny ones.
        manualChunks(id) {
          if (!id.includes("node_modules/")) return;
          if (/node_modules\/(react|react-dom|scheduler|react-router|react-router-dom|@remix-run|@tanstack)\//.test(id)) return "vendor";
          if (id.includes("node_modules/lucide-react/")) return "icons";
          if (/node_modules\/(@radix-ui|@floating-ui|react-remove-scroll|react-remove-scroll-bar|aria-hidden|use-callback-ref|use-sidecar|react-style-singleton|get-nonce)\//.test(id)) return "ui";
        },
      },
    },
  },
  server: {
    port: 5173,
    proxy: { "/api": "http://localhost:8787", "/auth": "http://localhost:8787" },
  },
});
