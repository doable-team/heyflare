import { Hono, type Context } from "hono";
import type { AppEnv } from "../env";
import type { AccountRow } from "../db";
import { toAccount } from "../db";
import { syncAccount } from "../sync";
import { syncContactPhotos } from "../people";
import { deleteAccountData } from "./domains";
import { appOrigin, HANDOFF_PREFIX, CAL_PREFIX } from "./auth";
import { googleConfigured, hasMailScope } from "../google";
import { hasMsMailScope, microsoftConfigured } from "../microsoft";
import { configFor, verifyBoth, encryptPassword, passwordHint, loadImapRow } from "../imapbox";
import type { ImapSecurity } from "../imap";
import type { SmtpSecurity } from "../smtp";
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
  // Best-effort token revocation. Google-only: Microsoft has no equivalent revoke endpoint for a
  // delegated refresh token, and posting one to Google's would leak it to the wrong provider.
  if (acc.provider === "gmail" && acc.refresh_token) {
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
  // Connected for calendar only: there is no mail to fetch, and that is not a failure.
  const scoped = acc.provider === "imap" ? true : acc.provider === "outlook" ? hasMsMailScope(acc.scopes) : hasMailScope(acc.scopes);
  if (!scoped) return c.json({ ok: true, added: 0, status: "ok", account: toAccount(acc) });
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
       delta_link = NULL, sync_status = 'idle', sync_error = NULL, photos_synced_at = NULL WHERE id = ?`
  )
    .bind(acc.id)
    .run();
  let syncError: string | null = null;
  if (acc.provider === "imap") {
    await c.env.DB.prepare(`UPDATE imap_accounts SET uid_validity = 0, last_uid = 0 WHERE account_id = ?`).bind(acc.id).run();
  }
  const canResync =
    acc.provider === "gmail" ? hasMailScope(acc.scopes) : acc.provider === "outlook" ? hasMsMailScope(acc.scopes) : acc.provider === "imap";
  if (canResync) {
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
 * Mints a one-time link that starts a provider's consent flow in the *system browser*. The native
 * apps call this (they hold the session), then open the URL outside the webview — Google refuses to
 * sign people in inside embedded web views, and Microsoft blocks it under some Conditional Access
 * policies, so both go the same way rather than guessing which webview will be accepted.
 */
accounts.post("/connect-link", async (c) => {
  const user = c.get("user");
  const body = await c.req
    .json<{ login_hint?: string; calendar?: boolean; provider?: string }>()
    .catch(() => ({}) as { login_hint?: string; calendar?: boolean; provider?: string });
  const provider = body.provider === "microsoft" ? "microsoft" : "google";
  if (provider === "microsoft") {
    if (!(await microsoftConfigured(c.env))) return c.json({ error: "microsoft_not_configured", message: "Set MS_CLIENT_ID and MS_CLIENT_SECRET secrets." }, 500);
  } else if (!(await googleConfigured(c.env))) {
    return c.json({ error: "google_not_configured", message: "Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET secrets." }, 500);
  }
  const state = `${HANDOFF_PREFIX}${provider === "google" && body.calendar ? CAL_PREFIX : ""}${uid()}`;
  await c.env.DB.prepare(`INSERT INTO oauth_states (state, user_id, created_at) VALUES (?, ?, ?)`).bind(state, user.id, now()).run();
  c.executionCtx.waitUntil(c.env.DB.prepare(`DELETE FROM oauth_states WHERE created_at < ?`).bind(now() - 3600_000).run());
  const hint = (body.login_hint ?? "").trim();
  const url = `${appOrigin(c)}/auth/${provider}/handoff?state=${encodeURIComponent(state)}${hint ? `&login_hint=${encodeURIComponent(hint)}` : ""}`;
  return c.json({ url });
});

// ---------- Third-party IMAP/SMTP mailboxes ----------

const EMAIL_RE = /^[^@\s]+@[^@\s.]+\.[^@\s]+$/;

interface ImapBody {
  email?: string;
  display_name?: string;
  imap_host?: string;
  imap_port?: number;
  imap_security?: string;
  smtp_host?: string;
  smtp_port?: number;
  smtp_security?: string;
  username?: string;
  password?: string | null;
  folder?: string;
}

function sec(v: unknown, fallback: "tls" | "starttls"): ImapSecurity & SmtpSecurity {
  return v === "starttls" || v === "tls" ? v : fallback;
}

function validPort(n: number): boolean {
  return Number.isInteger(n) && n > 0 && n < 65536;
}

/** Shape a request body into a config, without touching the database. */
function readBody(b: ImapBody) {
  const email = String(b.email ?? "").trim().toLowerCase();
  const username = String(b.username ?? "").trim() || email;
  return {
    email,
    username,
    display_name: String(b.display_name ?? "").trim().slice(0, 100),
    imap_host: String(b.imap_host ?? "").trim(),
    imap_port: Number(b.imap_port ?? 993),
    imap_security: sec(b.imap_security, "tls"),
    smtp_host: String(b.smtp_host ?? "").trim(),
    smtp_port: Number(b.smtp_port ?? 465),
    smtp_security: sec(b.smtp_security, "tls"),
    folder: String(b.folder ?? "INBOX").trim() || "INBOX",
  };
}

/**
 * Add a mailbox on someone else's IMAP/SMTP server. The credentials are verified against both
 * servers *before* anything is written, so a typo never leaves a broken account behind.
 */
accounts.post("/imap", async (c) => {
  const user = c.get("user");
  const b = await c.req.json<ImapBody>().catch(() => ({}) as ImapBody);
  const cfg = readBody(b);
  const password = String(b.password ?? "");
  if (!EMAIL_RE.test(cfg.email)) return c.json({ error: "invalid_email" }, 400);
  if (!cfg.imap_host || !cfg.smtp_host) return c.json({ error: "missing_host" }, 400);
  if (!password) return c.json({ error: "missing_password" }, 400);
  if (!validPort(cfg.imap_port) || !validPort(cfg.smtp_port)) return c.json({ error: "invalid_port" }, 400);
  if (cfg.smtp_port === 25) return c.json({ error: "smtp_port_25_blocked", message: "Cloudflare blocks port 25. Use 465 or 587." }, 400);

  const dup = await c.env.DB.prepare(`SELECT id FROM accounts WHERE user_id = ? AND email = ?`).bind(user.id, cfg.email).first();
  if (dup) return c.json({ error: "account_exists" }, 409);

  const creds = {
    imap: { host: cfg.imap_host, port: cfg.imap_port, security: cfg.imap_security, username: cfg.username, password },
    smtp: { host: cfg.smtp_host, port: cfg.smtp_port, security: cfg.smtp_security, username: cfg.username, password },
  };
  try {
    await verifyBoth(creds);
  } catch (e) {
    return c.json({ error: "connection_failed", message: (e as Error).message?.slice(0, 300) }, 400);
  }

  let enc: string;
  try {
    enc = await encryptPassword(c.env, password);
  } catch (e) {
    return c.json({ error: (e as Error).message }, 500);
  }

  const id = uid();
  const t = now();
  await c.env.DB.prepare(
    `INSERT INTO accounts (id, user_id, provider, email, display_name, access_token, refresh_token, token_expires_at, scopes,
       history_id, delta_link, initial_sync_done, initial_sync_page_token, initial_sync_count, sync_status, sync_error,
       last_synced_at, signature, cover_art, avatar_url, created_at)
     VALUES (?, ?, 'imap', ?, ?, NULL, NULL, NULL, '', NULL, NULL, 0, NULL, 0, 'idle', NULL, NULL, '', '', '', ?)`
  )
    .bind(id, user.id, cfg.email, cfg.display_name, t)
    .run();
  await c.env.DB.prepare(
    `INSERT INTO imap_accounts (account_id, imap_host, imap_port, imap_security, smtp_host, smtp_port, smtp_security,
       username, password_enc, password_hint, folder, uid_validity, last_uid, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?)`
  )
    .bind(id, cfg.imap_host, cfg.imap_port, cfg.imap_security, cfg.smtp_host, cfg.smtp_port, cfg.smtp_security,
          cfg.username, enc, passwordHint(password), cfg.folder, t)
    .run();

  // The first sync only records where the folder stands; nothing historical is imported.
  const fresh = await ownAccount(c, id);
  if (fresh) {
    const { syncAccount } = await import("../sync");
    c.executionCtx.waitUntil(syncAccount(c.env, fresh));
  }
  return c.json({ ok: true, account: toAccount(fresh!) });
});

/** The stored settings for a mailbox, with the password reduced to a hint. */
accounts.get("/:id/imap", async (c) => {
  const acc = await ownAccount(c, c.req.param("id"));
  if (!acc || acc.provider !== "imap") return c.json({ error: "not_found" }, 404);
  const row = await loadImapRow(c.env, acc.id);
  if (!row) return c.json({ error: "not_found" }, 404);
  const { password_enc, ...safe } = row;
  return c.json(safe);
});

/**
 * Update a mailbox in place. Rotating a mail password must not mean deleting the account, because
 * `deleteAccountData` takes the synced mail with it. Omitting `password` keeps the stored one, so
 * changing a host or port does not require re-typing the secret.
 */
accounts.patch("/:id/imap", async (c) => {
  const acc = await ownAccount(c, c.req.param("id"));
  if (!acc || acc.provider !== "imap") return c.json({ error: "not_found" }, 404);
  const row = await loadImapRow(c.env, acc.id);
  if (!row) return c.json({ error: "not_configured" }, 400);

  const b = await c.req.json<ImapBody>().catch(() => ({}) as ImapBody);
  const next = {
    imap_host: typeof b.imap_host === "string" && b.imap_host.trim() ? b.imap_host.trim() : row.imap_host,
    imap_port: typeof b.imap_port === "number" ? b.imap_port : row.imap_port,
    imap_security: b.imap_security ? sec(b.imap_security, row.imap_security) : row.imap_security,
    smtp_host: typeof b.smtp_host === "string" && b.smtp_host.trim() ? b.smtp_host.trim() : row.smtp_host,
    smtp_port: typeof b.smtp_port === "number" ? b.smtp_port : row.smtp_port,
    smtp_security: b.smtp_security ? sec(b.smtp_security, row.smtp_security) : row.smtp_security,
    username: typeof b.username === "string" && b.username.trim() ? b.username.trim() : row.username,
    folder: typeof b.folder === "string" && b.folder.trim() ? b.folder.trim() : row.folder,
  };
  if (!validPort(next.imap_port) || !validPort(next.smtp_port)) return c.json({ error: "invalid_port" }, 400);
  if (next.smtp_port === 25) return c.json({ error: "smtp_port_25_blocked", message: "Cloudflare blocks port 25. Use 465 or 587." }, 400);

  const typed = typeof b.password === "string" ? b.password : "";
  const password = typed || (await configFor(c.env, acc.id))?.imap.password || "";
  if (!password) return c.json({ error: "missing_password" }, 400);

  // Verify before writing, so a wrong value cannot leave a working mailbox broken.
  try {
    await verifyBoth({
      imap: { host: next.imap_host, port: next.imap_port, security: next.imap_security, username: next.username, password },
      smtp: { host: next.smtp_host, port: next.smtp_port, security: next.smtp_security, username: next.username, password },
    });
  } catch (e) {
    return c.json({ error: "connection_failed", message: (e as Error).message?.slice(0, 300) }, 400);
  }

  // A different folder invalidates the stored UIDs, so re-baseline rather than replaying old ones.
  const folderChanged = next.folder !== row.folder;
  const enc = typed ? await encryptPassword(c.env, typed) : row.password_enc;
  await c.env.DB.prepare(
    `UPDATE imap_accounts SET imap_host = ?, imap_port = ?, imap_security = ?, smtp_host = ?, smtp_port = ?, smtp_security = ?,
       username = ?, password_enc = ?, password_hint = ?, folder = ?, uid_validity = ?, last_uid = ?, updated_at = ?
     WHERE account_id = ?`
  )
    .bind(next.imap_host, next.imap_port, next.imap_security, next.smtp_host, next.smtp_port, next.smtp_security,
          next.username, enc, passwordHint(password), next.folder,
          folderChanged ? 0 : row.uid_validity, folderChanged ? 0 : row.last_uid, now(), acc.id)
    .run();

  // Working credentials retire the disconnected state the sync loop may have set.
  await c.env.DB.prepare(`UPDATE accounts SET sync_status = 'idle', sync_error = NULL WHERE id = ?`).bind(acc.id).run();
  const fresh = await ownAccount(c, acc.id);
  return c.json({ ok: true, account: toAccount(fresh!) });
});

/** Re-check the stored credentials against both servers. */
accounts.post("/:id/imap/test", async (c) => {
  const acc = await ownAccount(c, c.req.param("id"));
  if (!acc || acc.provider !== "imap") return c.json({ error: "not_found" }, 404);
  const cfg = await configFor(c.env, acc.id);
  if (!cfg) return c.json({ error: "not_configured" }, 400);
  try {
    await verifyBoth(cfg);
    return c.json({ ok: true });
  } catch (e) {
    return c.json({ ok: false, error: (e as Error).message?.slice(0, 300) }, 400);
  }
});

export default accounts;
