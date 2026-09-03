import { Hono } from "hono";
import type { AppEnv, Env } from "./env";
import type { AccountRow } from "./db";
import { requireUser, requireAccount, getSessionUser } from "./auth";
import { syncAccount, processBubbleUps } from "./sync";
import { processScheduledSends } from "./send";
import authRoutes from "./routes/auth";
import meRoutes from "./routes/me";
import accountRoutes from "./routes/accounts";
import mailRoutes from "./routes/mail";
import screenerRoutes from "./routes/screener";
import contactRoutes from "./routes/contacts";
import labelRoutes from "./routes/labels";
import collectionRoutes from "./routes/collections";
import clipRoutes from "./routes/clips";
import composeRoutes from "./routes/compose";
import bundleRoutes from "./routes/bundles";
import aiRoutes from "./routes/ai";
import { runLearning } from "./ai/memory";
import domainRoutes from "./routes/domains";
import { handleInboundEmail } from "./inbound";
import { ensureMigrations } from "./migrations";
import { VERSION, COMMIT, BUILT_AT } from "@shared/version";

const app = new Hono<AppEnv>();

app.onError((err, c) => {
  console.error("Unhandled error", err);
  return c.json({ error: "internal_error", message: (err as Error).message?.slice(0, 300) }, 500);
});

app.route("/auth", authRoutes);

const api = new Hono<AppEnv>();
// Anonymous GET /api/me -> { user: null, registration_open } (used by the register page)
api.get("/me", async (c, next) => {
  const user = await getSessionUser(c);
  if (user) return next();
  const n = await c.env.DB.prepare(`SELECT COUNT(*) AS n FROM users`).first<{ n: number }>();
  return c.json({ user: null, accounts: [], setup_required: (n?.n ?? 0) === 0, google_configured: !!(c.env.GOOGLE_CLIENT_ID && c.env.GOOGLE_CLIENT_SECRET) });
});
// What this deployment is running (used by the update check).
api.get("/version", (c) => c.json({ version: VERSION, commit: COMMIT, built_at: BUILT_AT, latest: null }));
api.use("*", requireUser);
api.route("/me", meRoutes);
api.route("/accounts", accountRoutes);
api.route("/domains", domainRoutes);
api.route("/ai", aiRoutes);


const scoped = new Hono<AppEnv>();
for (const p of ["/counts", "/imbox", "/threads", "/threads/*", "/feed", "/search", "/messages/*", "/files", "/screener", "/screener/*", "/contacts", "/contacts/*", "/labels", "/labels/*", "/collections", "/collections/*", "/clips", "/clips/*", "/drafts", "/drafts/*", "/send", "/send/*", "/bundles", "/bundles/*", "/power-through", "/power-through/*"]) {
  scoped.use(p, requireAccount);
}
scoped.route("/", mailRoutes); // counts, imbox, threads, feed, search, messages/*/attachments, files
scoped.route("/screener", screenerRoutes);
scoped.route("/contacts", contactRoutes);
scoped.route("/labels", labelRoutes);
scoped.route("/collections", collectionRoutes);
scoped.route("/clips", clipRoutes);
scoped.route("/bundles", bundleRoutes);
scoped.route("/", composeRoutes); // drafts, send
api.route("/", scoped);

api.notFound((c) => c.json({ error: "not_found" }, 404));
app.route("/api", api);

app.all("*", async (c) => {
  if (c.req.path.startsWith("/api/") || c.req.path.startsWith("/auth/")) return c.json({ error: "not_found" }, 404);
  return c.env.ASSETS.fetch(c.req.raw);
});

async function runCron(env: Env) {
  const db = env.DB;
  try {
    await processBubbleUps(db);
  } catch (e) {
    console.error("bubble up failed", e);
  }
  try {
    await processScheduledSends(env);
  } catch (e) {
    console.error("scheduled sends failed", e);
  }
  try {
    await runLearning(env);
  } catch (e) {
    console.error("ai learning failed", e);
  }
  const accounts = await db
    .prepare(
      `SELECT * FROM accounts WHERE provider = 'gmail' AND sync_status <> 'disconnected' AND refresh_token IS NOT NULL ORDER BY initial_sync_done ASC, COALESCE(last_synced_at, 0) ASC LIMIT 8`
    )
    .all<AccountRow>();
  for (const acc of accounts.results) {
    // Skip accounts that are mid-sync from another invocation (stale 'syncing' > 10 min is retried).
    if (acc.sync_status === "syncing" && acc.last_synced_at && Date.now() - acc.last_synced_at < 10 * 60_000) continue;
    try {
      await syncAccount(env, acc);
    } catch (e) {
      console.error("sync failed", acc.email, e);
    }
  }
}

export default {
  fetch: async (request: Request, env: Env, ctx: ExecutionContext) => {
    const { pathname } = new URL(request.url);
    // Static assets never need the database; everything else gets a migrated schema first (cached after the first call).
    if (pathname.startsWith("/api/") || pathname.startsWith("/auth/")) {
      try {
        await ensureMigrations(env);
      } catch (e) {
        return Response.json({ error: "migration_failed", message: (e as Error).message?.slice(0, 300) }, { status: 500 });
      }
    }
    return app.fetch(request, env, ctx);
  },
  scheduled: (_event: ScheduledEvent, env: Env, ctx: ExecutionContext) => {
    ctx.waitUntil(ensureMigrations(env).then(() => runCron(env)));
  },
  // Cloudflare Email Routing → custom-domain mailboxes.
  email: async (message: ForwardableEmailMessage, env: Env, _ctx: ExecutionContext) => {
    await ensureMigrations(env);
    return handleInboundEmail(message, env);
  },
};
