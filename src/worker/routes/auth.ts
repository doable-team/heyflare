import { Hono } from "hono";
import type { AppEnv } from "../env";
import type { UserRow, AccountRow } from "../db";
import { uid, now, toUser } from "../db";
import { hashPassword, verifyPassword, createSession, destroySession, getSessionUser } from "../auth";
import { googleAuthUrl, googleConfigured, exchangeCode, fetchUserInfo } from "../google";
import { verifyTotp, matchRecoveryCode } from "../totp";

const auth = new Hono<AppEnv>();

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

async function userCount(db: D1Database): Promise<number> {
  const r = await db.prepare(`SELECT COUNT(*) AS n FROM users`).first<{ n: number }>();
  return r?.n ?? 0;
}

// Single-owner instance: /auth/status tells the client whether first-run setup is still needed.
auth.get("/status", async (c) => {
  const n = await userCount(c.env.DB);
  return c.json({ setup_required: n === 0, google_configured: googleConfigured(c.env) });
});

// One-time setup: creates the sole owner. Disabled forever once a user exists.
auth.post("/setup", async (c) => {
  const body = await c.req.json<{ email?: string; name?: string; password?: string }>().catch(() => ({}) as any);
  const email = (body.email ?? "").trim().toLowerCase();
  const name = (body.name ?? "").trim();
  const password = body.password ?? "";
  if (!EMAIL_RE.test(email)) return c.json({ error: "invalid_email" }, 400);
  if (password.length < 8) return c.json({ error: "password_too_short" }, 400);
  const db = c.env.DB;
  if ((await userCount(db)) > 0) return c.json({ error: "setup_done" }, 403);

  const user: UserRow = {
    id: uid(),
    email,
    name: name || email.split("@")[0],
    password_hash: await hashPassword(password),
    role: "owner",
    disabled: 0,
    settings_json: "{}",
    created_at: now(),
    last_login_at: now(),
  };
  await db
    .prepare(`INSERT INTO users (id, email, name, password_hash, role, disabled, settings_json, created_at, last_login_at) VALUES (?, ?, ?, ?, ?, 0, '{}', ?, ?)`)
    .bind(user.id, user.email, user.name, user.password_hash, user.role, user.created_at, user.last_login_at)
    .run();
  await createSession(c, user.id);
  return c.json({ user: toUser(user) });
});

auth.post("/login", async (c) => {
  const body = await c.req.json<{ email?: string; password?: string }>().catch(() => ({}) as any);
  const email = (body.email ?? "").trim().toLowerCase();
  const password = body.password ?? "";
  const user = await c.env.DB.prepare(`SELECT * FROM users WHERE email = ?`).bind(email).first<UserRow>();
  if (!user || !(await verifyPassword(password, user.password_hash))) return c.json({ error: "invalid_credentials" }, 401);
  if (user.totp_enabled) {
    // Second factor required: hand out a short-lived ticket instead of a session.
    const t = now();
    const ticket = uid() + uid().replace(/-/g, "");
    await c.env.DB.batch([
      c.env.DB.prepare(`DELETE FROM mfa_tickets WHERE expires_at < ?`).bind(t),
      c.env.DB.prepare(`INSERT INTO mfa_tickets (id, user_id, attempts, created_at, expires_at) VALUES (?, ?, 0, ?, ?)`).bind(ticket, user.id, t, t + 5 * 60_000),
    ]);
    return c.json({ mfa_required: true, ticket });
  }
  await c.env.DB.prepare(`UPDATE users SET last_login_at = ? WHERE id = ?`).bind(now(), user.id).run();
  await createSession(c, user.id);
  return c.json({ user: toUser(user) });
});

const MFA_MAX_ATTEMPTS = 6;

auth.post("/login/2fa", async (c) => {
  const db = c.env.DB;
  const body = await c.req.json<{ ticket?: string; code?: string }>().catch(() => ({}) as any);
  const t = now();
  const ticket = await db
    .prepare(`SELECT * FROM mfa_tickets WHERE id = ? AND expires_at > ?`)
    .bind(body.ticket ?? "", t)
    .first<{ id: string; user_id: string; attempts: number }>();
  if (!ticket) return c.json({ error: "mfa_ticket_expired" }, 401);
  if (ticket.attempts >= MFA_MAX_ATTEMPTS) {
    await db.prepare(`DELETE FROM mfa_tickets WHERE id = ?`).bind(ticket.id).run();
    return c.json({ error: "mfa_too_many_attempts" }, 429);
  }
  const user = await db.prepare(`SELECT * FROM users WHERE id = ?`).bind(ticket.user_id).first<UserRow>();
  if (!user || !user.totp_enabled || !user.totp_secret) return c.json({ error: "mfa_ticket_expired" }, 401);
  const code = (body.code ?? "").trim();
  let ok = await verifyTotp(user.totp_secret, code);
  if (!ok) {
    const list = JSON.parse(user.recovery_codes_json || "[]") as string[];
    const idx = await matchRecoveryCode(code, list);
    if (idx >= 0) {
      list.splice(idx, 1);
      await db.prepare(`UPDATE users SET recovery_codes_json = ? WHERE id = ?`).bind(JSON.stringify(list), user.id).run();
      ok = true;
    }
  }
  if (!ok) {
    await db.prepare(`UPDATE mfa_tickets SET attempts = attempts + 1 WHERE id = ?`).bind(ticket.id).run();
    return c.json({ error: "invalid_code", attempts_left: MFA_MAX_ATTEMPTS - ticket.attempts - 1 }, 401);
  }
  await db.batch([
    db.prepare(`DELETE FROM mfa_tickets WHERE id = ?`).bind(ticket.id),
    db.prepare(`UPDATE users SET last_login_at = ? WHERE id = ?`).bind(t, user.id),
  ]);
  await createSession(c, user.id);
  return c.json({ user: toUser(user) });
});

auth.post("/logout", async (c) => {
  await destroySession(c);
  return c.json({ ok: true });
});

/** Where this deployment lives, as the browser sees it (localhost wins over APP_URL in dev). */
export function appOrigin(c: any): string {
  const url = new URL(c.req.url);
  return url.hostname === "localhost" || url.hostname === "127.0.0.1" ? url.origin : c.env.APP_URL || url.origin;
}

function redirectUriFor(c: any): string {
  return `${appOrigin(c)}/auth/google/callback`;
}

/**
 * States minted for the "open Google in the real browser" handoff carry this prefix, so the callback
 * knows to finish with a plain confirmation page instead of redirecting into the app's webview.
 */
export const HANDOFF_PREFIX = "hx_";

auth.get("/google/start", async (c) => {
  const user = await getSessionUser(c);
  if (!user) return c.redirect("/login?next=/settings/accounts");
  if (!googleConfigured(c.env)) {
    return c.json({ error: "google_not_configured", message: "Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET secrets." }, 500);
  }
  const state = uid();
  await c.env.DB.prepare(`INSERT INTO oauth_states (state, user_id, created_at) VALUES (?, ?, ?)`).bind(state, user.id, now()).run();
  // Prune old states opportunistically.
  c.executionCtx.waitUntil(c.env.DB.prepare(`DELETE FROM oauth_states WHERE created_at < ?`).bind(now() - 3600_000).run());
  const hint = c.req.query("login_hint") ?? undefined;
  return c.redirect(googleAuthUrl(c.env, state, redirectUriFor(c), hint));
});

/** Standalone page shown in the browser tab that finished a handoff (the app is a separate window). */
function handoffPage(title: string, detail: string, ok: boolean): string {
  const esc = (v: string) => v.replace(/[&<>"]/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[ch]!);
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)} · heyflare</title><style>
:root{color-scheme:light dark}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#fff;color:#37352f;
font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
main{max-width:22rem;padding:2rem;text-align:center}
.mark{width:40px;height:40px;border-radius:10px;background:#37352f;color:#fff;display:flex;align-items:center;
justify-content:center;font-weight:700;margin:0 auto 1.25rem}
h1{font-size:17px;margin:0 0 .4rem;font-weight:600}
p{margin:0;color:rgba(55,53,47,.65)}
@media (prefers-color-scheme:dark){body{background:#191919;color:#d4d4d4}.mark{background:#d4d4d4;color:#191919}p{color:rgba(255,255,255,.55)}}
</style></head><body><main><div class="mark">h</div><h1>${esc(title)}</h1><p>${esc(detail)}</p></main></body></html>`;
}

/**
 * Unauthenticated entry point for the Mac app: the app (which *is* signed in) mints a state through
 * `POST /api/accounts/connect-link`, then opens this URL in the system browser, which has no session.
 * The state row identifies the user, so no cookie is needed here.
 */
auth.get("/google/handoff", async (c) => {
  const state = c.req.query("state") ?? "";
  if (!googleConfigured(c.env)) {
    return c.json({ error: "google_not_configured", message: "Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET secrets." }, 500);
  }
  if (!state.startsWith(HANDOFF_PREFIX)) return c.json({ error: "invalid_state" }, 400);
  const st = await c.env.DB.prepare(`SELECT state FROM oauth_states WHERE state = ? AND created_at > ?`).bind(state, now() - 3600_000).first<{ state: string }>();
  if (!st) return c.json({ error: "invalid_state" }, 400);
  const hint = c.req.query("login_hint") ?? undefined;
  return c.redirect(googleAuthUrl(c.env, state, redirectUriFor(c), hint));
});

auth.get("/google/callback", async (c) => {
  const code = c.req.query("code");
  const state = c.req.query("state");
  const err = c.req.query("error");
  if (err) {
    if ((c.req.query("state") ?? "").startsWith(HANDOFF_PREFIX)) {
      return c.html(handoffPage("Not connected", "Google reported: " + err + ". You can close this tab and try again from heyflare.", false), 200);
    }
    return c.redirect(`/?connect_error=${encodeURIComponent(err)}`);
  }
  if (!code || !state) return c.json({ error: "missing_code_or_state" }, 400);
  const db = c.env.DB;
  const handoff = state.startsWith(HANDOFF_PREFIX);
  const st = await db.prepare(`SELECT * FROM oauth_states WHERE state = ? AND created_at > ?`).bind(state, now() - 3600_000).first<{ user_id: string }>();
  if (!st) return c.json({ error: "invalid_state" }, 400);
  await db.prepare(`DELETE FROM oauth_states WHERE state = ?`).bind(state).run();
  const user = await db.prepare(`SELECT * FROM users WHERE id = ?`).bind(st.user_id).first<UserRow>();
  if (!user) return c.json({ error: "unauthorized" }, 401);

  try {
    const tok = await exchangeCode(c.env, code, redirectUriFor(c));
    const info = await fetchUserInfo(tok.access_token);
    if (!info.email) return c.json({ error: "no_email_from_google" }, 400);
    const expiresAt = now() + (tok.expires_in ?? 3600) * 1000;
    const existing = await db.prepare(`SELECT * FROM accounts WHERE user_id = ? AND email = ?`).bind(user.id, info.email).first<AccountRow>();
    let accountId: string;
    if (existing) {
      accountId = existing.id;
      await db
        .prepare(
          `UPDATE accounts SET access_token = ?, refresh_token = COALESCE(?, refresh_token), token_expires_at = ?, sync_status = 'idle', sync_error = NULL, display_name = CASE WHEN display_name = '' THEN ? ELSE display_name END, avatar_url = CASE WHEN ? <> '' THEN ? ELSE avatar_url END, photos_synced_at = NULL WHERE id = ?`
        )
        .bind(tok.access_token, tok.refresh_token ?? null, expiresAt, info.name, info.picture, info.picture, existing.id)
        .run();
    } else {
      accountId = uid();
      await db
        .prepare(
          `INSERT INTO accounts (id, user_id, provider, email, display_name, access_token, refresh_token, token_expires_at, history_id, initial_sync_done, initial_sync_page_token, initial_sync_count, sync_status, sync_error, last_synced_at, signature, cover_art, avatar_url, created_at)
           VALUES (?, ?, 'gmail', ?, ?, ?, ?, ?, NULL, 0, NULL, 0, 'idle', NULL, NULL, '', '', ?, ?)`
        )
        .bind(accountId, user.id, info.email, info.name, tok.access_token, tok.refresh_token ?? null, expiresAt, info.picture, now())
        .run();
    }
    // Kick off the first sync chunk in the background.
    const account = await db.prepare(`SELECT * FROM accounts WHERE id = ?`).bind(accountId).first<AccountRow>();
    if (account) {
      const { syncAccount } = await import("../sync");
      c.executionCtx.waitUntil(syncAccount(c.env, account));
    }
    if (handoff) {
      return c.html(handoffPage("Connected", `${info.email} is now syncing. You can close this tab and go back to heyflare.`, true), 200);
    }
    return c.redirect(`/?connected=1&account=${accountId}`);
  } catch (e) {
    const msg = ((e as Error).message ?? "oauth_failed").slice(0, 200);
    if (handoff) return c.html(handoffPage("Not connected", `${msg}. You can close this tab and try again from heyflare.`, false), 200);
    return c.redirect(`/?connect_error=${encodeURIComponent(msg)}`);
  }
});

export default auth;
