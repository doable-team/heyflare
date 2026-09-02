import type { Env } from "./env";

let cached: Promise<string> | null = null;

function randomHex(bytes: number): string {
  const b = crypto.getRandomValues(new Uint8Array(bytes));
  return Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
}

/**
 * The secret used to encrypt stored AI keys. `SESSION_SECRET` from the environment wins; otherwise one is generated on
 * first use and persisted in `app_secrets`, so one-click deploys need no manual secret setup.
 */
export function getSessionSecret(env: Env): Promise<string> {
  if (env.SESSION_SECRET) return Promise.resolve(env.SESSION_SECRET);
  if (!cached) {
    cached = (async () => {
      const db = env.DB;
      const row = await db.prepare(`SELECT value FROM app_secrets WHERE key = 'session_secret'`).first<{ value: string }>();
      if (row?.value) return row.value;
      await db.prepare(`INSERT OR IGNORE INTO app_secrets (key, value, created_at) VALUES ('session_secret', ?, ?)`).bind(randomHex(32), Date.now()).run();
      const again = await db.prepare(`SELECT value FROM app_secrets WHERE key = 'session_secret'`).first<{ value: string }>();
      if (!again?.value) throw new Error("session_secret_missing");
      return again.value;
    })().catch((e) => {
      cached = null;
      throw e;
    });
  }
  return cached;
}
