import { Hono, type Context } from "hono";
import type { AppEnv } from "../env";
import type { AccountRow } from "../db";
import { toAccount } from "../db";
import { syncAccount } from "../sync";
import { syncContactPhotos } from "../people";
import { deleteAccountData } from "./domains";
import { appOrigin, HANDOFF_PREFIX } from "./auth";
import { googleConfigured } from "../google";
import { uid, now } from "../db";

const accounts = new Hono<AppEnv>();

async function ownAccount(c: Context<AppEnv>, id: string): Promise<AccountRow | null> {
  const user = c.get("user");
  return (await c.env.DB.prepare(`SELECT * FROM accounts WHERE id = ? AND user_id = ?`).bind(id, user.id).first<AccountRow>()) ?? null;
}

accounts.get("/", async (c) => {
  const user = c.get("user");
  const rows = await c.env.DB.prepare(`SELECT * FROM accounts WHERE user_id = ? ORDER BY created_at ASC`).bind(user.id).all<AccountRow>();
  return c.json(rows.results.map(toAccount));
});

accounts.patch("/:id", async (c) => {
  const acc = await ownAccount(c, c.req.param("id"));
  if (!acc) return c.json({ error: "not_found" }, 404);
  const body = await c.req.json<{ signature?: string; cover_art?: string; display_name?: string }>().catch(() => ({}) as any);
  const signature = typeof body.signature === "string" ? body.signature.slice(0, 20_000) : acc.signature;
  const cover = typeof body.cover_art === "string" ? body.cover_art.slice(0, 2000) : acc.cover_art;
  const dn = typeof body.display_name === "string" ? body.display_name.trim().slice(0, 100) : acc.display_name;
  await c.env.DB.prepare(`UPDATE accounts SET signature = ?, cover_art = ?, display_name = ? WHERE id = ?`).bind(signature, cover, dn, acc.id).run();
  const fresh = await ownAccount(c, acc.id);
  return c.json(toAccount(fresh!));
});

accounts.delete("/:id", async (c) => {
  const acc = await ownAccount(c, c.req.param("id"));
  if (!acc) return c.json({ error: "not_found" }, 404);
  // Explicit cleanup (D1 may not have FK enforcement on for all statements).
  await deleteAccountData(c.env.DB, acc.id);
  // Best-effort token revocation.
  if (acc.refresh_token) {
    c.executionCtx.waitUntil(
      fetch(`https://oauth2.googleapis.com/revoke?token=${encodeURIComponent(acc.refresh_token)}`, { method: "POST" }).catch(() => {})
    );
  }
  return c.json({ ok: true });
});

accounts.post("/:id/sync", async (c) => {
  const acc = await ownAccount(c, c.req.param("id"));
  if (!acc) return c.json({ error: "not_found" }, 404);
  if (acc.provider === "domain") return c.json({ ok: true, added: 0, status: "ok", account: toAccount(acc) });
  const r = await syncAccount(c.env, acc);
  const fresh = await ownAccount(c, acc.id);
  return c.json({ ok: r.status === "ok", added: r.added, status: r.status, account: toAccount(fresh!) });
});

// "Start fresh": wipe everything synced for this account and watch for new mail from now on.
accounts.post("/:id/reset", async (c) => {
  const acc = await ownAccount(c, c.req.param("id"));
  if (!acc) return c.json({ error: "not_found" }, 404);
  await deleteAccountData(c.env.DB, acc.id, { keepAccount: true });
  await c.env.DB.prepare(
    `UPDATE accounts SET initial_sync_done = 0, initial_sync_count = 0, initial_sync_page_token = NULL, history_id = NULL,
       sync_status = 'idle', sync_error = NULL, photos_synced_at = NULL WHERE id = ?`
  )
    .bind(acc.id)
    .run();
  let syncError: string | null = null;
  if (acc.provider === "gmail") {
    const fresh = await ownAccount(c, acc.id);
    const r = await syncAccount(c.env, fresh!);
    if (r.status !== "ok") syncError = (await ownAccount(c, acc.id))?.sync_error ?? r.status;
  }
  const after = await ownAccount(c, acc.id);
  return c.json({ ok: true, account: toAccount(after!), sync_error: syncError });
});

// Force a Google People photo sync now.
accounts.post("/:id/sync-photos", async (c) => {
  const acc = await ownAccount(c, c.req.param("id"));
  if (!acc) return c.json({ error: "not_found" }, 404);
  if (acc.provider !== "gmail") return c.json({ ok: true, updated: 0 });
  try {
    const r = await syncContactPhotos(c.env, acc);
    const fresh = await ownAccount(c, acc.id);
    return c.json({ ok: true, updated: r.updated, account: toAccount(fresh!) });
  } catch (e) {
    return c.json({ error: "photos_failed", message: (e as Error).message?.slice(0, 300) }, 502);
  }
});

// Recent sync activity for one of the owner's accounts.
accounts.get("/:id/logs", async (c) => {
  const acc = await ownAccount(c, c.req.param("id"));
  if (!acc) return c.json({ error: "not_found" }, 404);
  const rows = await c.env.DB.prepare(`SELECT id, account_id, level, message, created_at FROM sync_log WHERE account_id = ? ORDER BY created_at DESC LIMIT 200`).bind(acc.id).all();
  return c.json(rows.results);
});

/**
 * Mints a one-time link that starts Google's consent flow in the *system browser*. The Mac app calls
 * this (it holds the session), then opens the URL outside the webview — Google increasingly refuses
 * to sign people in inside embedded web views, and the browser has the user's Google session anyway.
 */
accounts.post("/connect-link", async (c) => {
  const user = c.get("user");
  if (!googleConfigured(c.env)) return c.json({ error: "google_not_configured", message: "Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET secrets." }, 500);
  const body = await c.req.json<{ login_hint?: string }>().catch(() => ({}) as { login_hint?: string });
  const state = `${HANDOFF_PREFIX}${uid()}`;
  await c.env.DB.prepare(`INSERT INTO oauth_states (state, user_id, created_at) VALUES (?, ?, ?)`).bind(state, user.id, now()).run();
  c.executionCtx.waitUntil(c.env.DB.prepare(`DELETE FROM oauth_states WHERE created_at < ?`).bind(now() - 3600_000).run());
  const hint = (body.login_hint ?? "").trim();
  const url = `${appOrigin(c)}/auth/google/handoff?state=${encodeURIComponent(state)}${hint ? `&login_hint=${encodeURIComponent(hint)}` : ""}`;
  return c.json({ url });
});

export default accounts;
