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
import calendarRoutes from "./routes/calendar";
import { runCalendarSync } from "./calendar/sync";
import { MAIL_SCOPE_SQL } from "./google";
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

/**
 * Conditional GETs for JSON. The Imbox, counts and lists are polled every minute and mostly have
 * not changed; with an ETag the browser sends `If-None-Match` and an unchanged answer is a 304 with
 * no body. `no-cache` (not `no-store`) is what lets the browser keep the copy it revalidates
 * against. Attachments set their own Cache-Control and are left alone, as is anything that is not
 * JSON — hashing a multi-megabyte file to save nothing would be a poor trade.
 */
api.use("*", async (c, next) => {
  await next();
  if (c.req.method !== "GET" || c.res.status !== 200) return;
  if (!/^application\/json/i.test(c.res.headers.get("content-type") ?? "")) return;
  const body = await c.res.clone().arrayBuffer();
  const digest = await crypto.subtle.digest("SHA-1", body);
  const tag = `W/"${[...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("")}"`;
  const headers = new Headers(c.res.headers);
  headers.set("etag", tag);
  if (!headers.has("cache-control")) headers.set("cache-control", "private, no-cache");
  const match = c.req.header("if-none-match");
  if (match && match.split(",").some((m) => m.trim() === tag)) {
    c.res = new Response(null, { status: 304, headers });
    return;
  }
  c.res = new Response(body, { status: 200, headers });
});

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
api.route("/calendar", calendarRoutes);


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
  try {
    await runCalendarSync(env);
  } catch (e) {
    console.error("calendar sync failed", e);
  }
  // Accounts connected for calendar only carry no mail scope, so they are not mail accounts to sync.
  // MAIL_SCOPE_SQL mirrors hasMailScope: an empty `scopes` predates the column and does have mail.
  const accounts = await db
    .prepare(
      `SELECT * FROM accounts WHERE provider = 'gmail' AND sync_status <> 'disconnected' AND refresh_token IS NOT NULL AND ${MAIL_SCOPE_SQL} ORDER BY initial_sync_done ASC, COALESCE(last_synced_at, 0) ASC LIMIT 8`
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
