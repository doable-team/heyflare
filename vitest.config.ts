import fs from "node:fs";
import path from "node:path";
import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

/**
 * Wrangler bundles migrations/*.sql as Text modules (see the `rules` entry in wrangler.jsonc).
 * Vite has no such rule, so mirror it here or `migrations.ts` cannot be imported under test.
 */
const sqlAsText = {
  name: "sql-as-text",
  transform(_code: string, id: string) {
    if (!id.endsWith(".sql")) return null;
    return { code: `export default ${JSON.stringify(fs.readFileSync(id, "utf8"))};`, map: null };
  },
};

// Tests run inside workerd against a real (in-memory) D1, so migrations, SQL and the ingest
// pipeline are exercised for real rather than against a hand-written stub.
export default defineWorkersConfig({
  plugins: [sqlAsText],
  resolve: { alias: { "@shared": path.resolve(__dirname, "src/shared") } },
  test: {
    include: ["test/**/*.test.ts"],
    poolOptions: {
      workers: {
        singleWorker: true,
        miniflare: {
          compatibilityDate: "2025-09-01",
          compatibilityFlags: ["nodejs_compat"],
          d1Databases: { DB: "test-db" },
          bindings: { APP_NAME: "heyflare", SESSION_SECRET: "test-session-secret" },
        },
      },
    },
  },
});
