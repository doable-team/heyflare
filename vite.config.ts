import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "node:path";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: { alias: { "@shared": path.resolve(__dirname, "src/shared"), "@": path.resolve(__dirname, "src/web") } },
  build: { outDir: "dist", emptyOutDir: true },
  server: {
    port: 5173,
    proxy: { "/api": "http://localhost:8787", "/auth": "http://localhost:8787" },
  },
});
