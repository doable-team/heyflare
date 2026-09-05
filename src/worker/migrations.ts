// Self-applying migrations: the SQL files are bundled as text (wrangler `rules` → Text modules) and applied on first use,
// tracked in wrangler's own `d1_migrations` table so `wrangler d1 migrations apply` stays compatible.
// Add every new migrations/*.sql file here (Workers can't read the directory at runtime).
import type { Env } from "./env";
import m0001 from "../../migrations/0001_init.sql";
import m0002 from "../../migrations/0002_single_owner.sql";
import m0003 from "../../migrations/0003_domains.sql";
import m0004 from "../../migrations/0004_avatars.sql";
import m0005 from "../../migrations/0005_brand_logos.sql";
import m0006 from "../../migrations/0006_address_book.sql";
import m0007 from "../../migrations/0007_bundles.sql";
import m0008 from "../../migrations/0008_two_factor.sql";
import m0009 from "../../migrations/0009_bundle_batches.sql";
import m0010 from "../../migrations/0010_ai.sql";
import m0011 from "../../migrations/0011_calendar.sql";
import m0012 from "../../migrations/0012_calendar_default_view.sql";
import m0013 from "../../migrations/0013_day_covers.sql";
import m0014 from "../../migrations/0014_calendar_views.sql";
import m0015 from "../../migrations/0015_calendar_error.sql";
import m0016 from "../../migrations/0016_outlook.sql";
import m0017 from "../../migrations/0017_imap.sql";
import m0018 from "../../migrations/0018_oauth_credentials.sql";
import m0019 from "../../migrations/0019_oauth_override.sql";

export const MIGRATIONS: { name: string; sql: string }[] = [
  { name: "0001_init.sql", sql: m0001 },
  { name: "0002_single_owner.sql", sql: m0002 },
  { name: "0003_domains.sql", sql: m0003 },
  { name: "0004_avatars.sql", sql: m0004 },
  { name: "0005_brand_logos.sql", sql: m0005 },
  { name: "0006_address_book.sql", sql: m0006 },
  { name: "0007_bundles.sql", sql: m0007 },
  { name: "0008_two_factor.sql", sql: m0008 },
  { name: "0009_bundle_batches.sql", sql: m0009 },
  { name: "0010_ai.sql", sql: m0010 },
  { name: "0011_calendar.sql", sql: m0011 },
  { name: "0012_calendar_default_view.sql", sql: m0012 },
  { name: "0013_day_covers.sql", sql: m0013 },
  { name: "0014_calendar_views.sql", sql: m0014 },
  { name: "0015_calendar_error.sql", sql: m0015 },
  { name: "0016_outlook.sql", sql: m0016 },
  { name: "0017_imap.sql", sql: m0017 },
  { name: "0018_oauth_credentials.sql", sql: m0018 },
  { name: "0019_oauth_override.sql", sql: m0019 },
];

/** Split a migration file into statements: full-line comments dropped, split on `;` at end of line. */
export function splitStatements(sql: string): string[] {
  const noComments = sql
    .split("\n")
    .filter((l) => !/^\s*--/.test(l))
    .join("\n");
  return noComments
    .split(/;\s*(?:\n|$)/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

let ready: Promise<void> | null = null;

/** Apply pending migrations once per isolate. Cheap after the first call (a single SELECT, then cached). */
export function ensureMigrations(env: Env): Promise<void> {
  if (!ready) {
    ready = run(env).catch((e) => {
      ready = null;
      throw e;
    });
  }
  return ready;
}

async function run(env: Env) {
  const db = env.DB;
  await db.batch([
    db.prepare(`CREATE TABLE IF NOT EXISTS d1_migrations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL)`),
    db.prepare(`CREATE TABLE IF NOT EXISTS app_secrets (key TEXT PRIMARY KEY, value TEXT NOT NULL, created_at INTEGER NOT NULL)`),
  ]);
  const rows = await db.prepare(`SELECT name FROM d1_migrations`).all<{ name: string }>();
  const applied = new Set(rows.results.map((r) => r.name));
  const pending = MIGRATIONS.filter((m) => !applied.has(m.name));
  for (const m of pending) {
    const stmts = splitStatements(m.sql).map((s) => db.prepare(s));
    stmts.push(db.prepare(`INSERT INTO d1_migrations (name) VALUES (?)`).bind(m.name));
    await db.batch(stmts);
    try {
      await db.prepare(`INSERT INTO sync_log (account_id, level, message, created_at) VALUES (NULL, 'info', ?, ?)`).bind(`Applied migration ${m.name}`, Date.now()).run();
    } catch {
      /* sync_log may not exist yet on very early migrations */
    }
  }
}
