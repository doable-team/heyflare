import { Hono, type Context } from "hono";
import type { AppEnv, Env } from "../env";
import type { AccountRow, DomainRow } from "../db";
import { uid, now, safeJson, toAccount } from "../db";
import type { Domain, DnsRecord } from "@shared/types";
import {
  cfConfigured,
  findZone,
  getRoutingSettings,
  enableRouting,
  routingDns,
  getCatchAll,
  setCatchAllToWorker,
  catchAllTargetsWorker,
  lookupMx,
  isCloudflareMx,
  defaultRoutingDns,
  CfError,
} from "../cloudflare";

const domains = new Hono<AppEnv>();

const DOMAIN_RE = /^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;
const LOCAL_RE = /^[a-z0-9._+-]{1,64}$/;

const workerName = (env: Env) => env.WORKER_NAME || "hey-far-hn";

function sendingMode(env: Env): Domain["sending"] {
  if (env.EMAIL && typeof env.EMAIL.send === "function") return "cloudflare";
  if (env.RESEND_API_KEY) return "resend";
  return "none";
}

function instructionsFor(env: Env, d: DomainRow): string[] {
  const out: string[] = [];
  if (d.routing !== "enabled") {
    if (cfConfigured(env)) {
      out.push(`Run "Verify" to re-check Email Routing for ${d.name}.`);
    } else {
      out.push(`In the Cloudflare dashboard open the zone ${d.name} → Email → Email Routing and click "Enable Email Routing" (Cloudflare adds and locks the MX + SPF records).`);
      out.push(`Under Routing rules, set the Catch-all address to "Send to a Worker" → ${workerName(env)}, and enable it.`);
      out.push(`Alternatively add a CF_API_TOKEN secret (Zone:Read, Email Routing Settings:Edit, Email Routing Rules:Edit) and press "Verify" to let heyflare do this for you.`);
    }
  }
  if (sendingMode(env) === "none") {
    out.push(`Outbound mail is not configured: enable Cloudflare Email Sending for ${d.name} (Workers Paid) and add the send_email binding, or set a RESEND_API_KEY secret with ${d.name} verified in Resend.`);
  }
  return out;
}

async function mailboxesFor(db: D1Database, domainId: string): Promise<AccountRow[]> {
  const rows = await db.prepare(`SELECT * FROM accounts WHERE domain_id = ? AND provider = 'domain' ORDER BY created_at ASC`).bind(domainId).all<AccountRow>();
  return rows.results;
}

async function toDomain(env: Env, d: DomainRow): Promise<Domain> {
  const mailboxes = await mailboxesFor(env.DB, d.id);
  return {
    id: d.id,
    name: d.name,
    zone_id: d.zone_id,
    status: d.status,
    routing: d.routing,
    sending: sendingMode(env),
    catch_all_account_id: d.catch_all_account_id,
    error: d.error,
    dns: safeJson<DnsRecord[]>(d.dns_json, []),
    instructions: instructionsFor(env, d),
    mailboxes: mailboxes.map(toAccount),
    created_at: d.created_at,
  };
}

async function ownDomain(c: Context<AppEnv>, id: string): Promise<DomainRow | null> {
  return (await c.env.DB.prepare(`SELECT * FROM domains WHERE id = ? AND user_id = ?`).bind(id, c.get("user").id).first<DomainRow>()) ?? null;
}

/**
 * With CF_API_TOKEN: find the zone, enable Email Routing, point the catch-all at this Worker.
 * Mutates `d` in place (status/routing/zone_id/dns_json/error) and persists it.
 */
async function configureWithCloudflare(env: Env, d: DomainRow): Promise<void> {
  const db = env.DB;
  const name = workerName(env);
  try {
    const zone = await findZone(env, d.name);
    if (!zone) throw new Error(`Zone ${d.name} was not found on this Cloudflare account. Add the domain to Cloudflare (full setup) first.`);
    if (zone.status !== "active") throw new Error(`Zone ${d.name} is "${zone.status}" — Email Routing needs an active zone.`);
    if (zone.type && zone.type !== "full") throw new Error(`Zone ${d.name} uses a ${zone.type} setup; Email Routing requires Cloudflare nameservers (full setup).`);
    d.zone_id = zone.id;
    let settings = await getRoutingSettings(env, zone.id);
    if (!settings.enabled) settings = await enableRouting(env, zone.id);
    let rule = null;
    try {
      rule = await getCatchAll(env, zone.id);
    } catch {
      rule = null;
    }
    if (!catchAllTargetsWorker(rule, name)) rule = await setCatchAllToWorker(env, zone.id, name);
    try {
      d.dns_json = JSON.stringify(await routingDns(env, zone.id));
    } catch {
      d.dns_json = JSON.stringify(defaultRoutingDns(d.name));
    }
    const ready = settings.enabled && catchAllTargetsWorker(rule, name);
    d.routing = ready ? "enabled" : "unconfigured";
    d.status = ready ? "active" : "pending";
    d.error = ready ? null : `Email Routing status: ${settings.status}`;
  } catch (e) {
    d.status = "error";
    d.error = e instanceof CfError ? e.message : ((e as Error).message ?? "setup failed").slice(0, 500);
    if (d.routing === "enabled") d.routing = "unconfigured";
  }
  d.updated_at = now();
  await db
    .prepare(`UPDATE domains SET zone_id = ?, status = ?, routing = ?, error = ?, dns_json = ?, updated_at = ? WHERE id = ?`)
    .bind(d.zone_id, d.status, d.routing, d.error, d.dns_json, d.updated_at, d.id)
    .run();
}

domains.get("/", async (c) => {
  const rows = await c.env.DB.prepare(`SELECT * FROM domains WHERE user_id = ? ORDER BY created_at ASC`).bind(c.get("user").id).all<DomainRow>();
  const out: Domain[] = [];
  for (const d of rows.results) out.push(await toDomain(c.env, d));
  return c.json(out);
});

domains.post("/", async (c) => {
  const db = c.env.DB;
  const b = await c.req.json<{ name?: string; confirm?: boolean }>().catch(() => ({}) as any);
  const name = String(b.name ?? "").trim().toLowerCase().replace(/\.$/, "");
  if (!DOMAIN_RE.test(name)) return c.json({ error: "invalid_domain" }, 400);
  const existing = await db.prepare(`SELECT id FROM domains WHERE name = ?`).bind(name).first();
  if (existing) return c.json({ error: "domain_exists" }, 409);

  // Guard: taking over a domain whose mail currently goes elsewhere.
  const mx = await lookupMx(name);
  if (mx.length && !isCloudflareMx(mx) && !b.confirm) return c.json({ error: "mx_in_use", mx }, 409);

  const t = now();
  const d: DomainRow = {
    id: uid(),
    user_id: c.get("user").id,
    name,
    zone_id: null,
    status: "pending",
    routing: cfConfigured(c.env) ? "unconfigured" : "manual",
    sending: sendingMode(c.env),
    catch_all_account_id: null,
    error: null,
    dns_json: JSON.stringify(defaultRoutingDns(name)),
    created_at: t,
    updated_at: t,
  };
  await db
    .prepare(`INSERT INTO domains (id, user_id, name, zone_id, status, routing, sending, catch_all_account_id, error, dns_json, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
    .bind(d.id, d.user_id, d.name, d.zone_id, d.status, d.routing, d.sending, d.catch_all_account_id, d.error, d.dns_json, d.created_at, d.updated_at)
    .run();
  if (cfConfigured(c.env)) await configureWithCloudflare(c.env, d);
  return c.json(await toDomain(c.env, d));
});

domains.post("/:id/verify", async (c) => {
  const d = await ownDomain(c, c.req.param("id"));
  if (!d) return c.json({ error: "not_found" }, 404);
  if (cfConfigured(c.env)) {
    await configureWithCloudflare(c.env, d);
  } else {
    // Manual mode: infer from public DNS only.
    const mx = await lookupMx(d.name);
    const cfMx = isCloudflareMx(mx);
    d.routing = "manual";
    d.status = cfMx ? "active" : "pending";
    d.error = cfMx ? null : mx.length ? `MX currently points to ${mx.join(", ")}` : "No MX records found yet";
    d.updated_at = now();
    await c.env.DB.prepare(`UPDATE domains SET status = ?, routing = ?, error = ?, updated_at = ? WHERE id = ?`).bind(d.status, d.routing, d.error, d.updated_at, d.id).run();
  }
  return c.json(await toDomain(c.env, d));
});

domains.patch("/:id", async (c) => {
  const d = await ownDomain(c, c.req.param("id"));
  if (!d) return c.json({ error: "not_found" }, 404);
  const b = await c.req.json<{ catch_all_account_id?: string | null }>().catch(() => ({}) as any);
  if (b.catch_all_account_id !== undefined) {
    if (b.catch_all_account_id) {
      const mb = await c.env.DB.prepare(`SELECT id FROM accounts WHERE id = ? AND domain_id = ? AND provider = 'domain'`).bind(b.catch_all_account_id, d.id).first();
      if (!mb) return c.json({ error: "invalid_mailbox" }, 400);
    }
    d.catch_all_account_id = b.catch_all_account_id || null;
    await c.env.DB.prepare(`UPDATE domains SET catch_all_account_id = ?, updated_at = ? WHERE id = ?`).bind(d.catch_all_account_id, now(), d.id).run();
  }
  return c.json(await toDomain(c.env, d));
});

domains.delete("/:id", async (c) => {
  const d = await ownDomain(c, c.req.param("id"));
  if (!d) return c.json({ error: "not_found" }, 404);
  const db = c.env.DB;
  const boxes = await mailboxesFor(db, d.id);
  for (const acc of boxes) await deleteAccountData(db, acc.id);
  await db.prepare(`DELETE FROM domains WHERE id = ?`).bind(d.id).run();
  return c.json({ ok: true });
});

domains.post("/:id/mailboxes", async (c) => {
  const d = await ownDomain(c, c.req.param("id"));
  if (!d) return c.json({ error: "not_found" }, 404);
  const db = c.env.DB;
  const b = await c.req.json<{ local_part?: string; display_name?: string; catch_all?: boolean }>().catch(() => ({}) as any);
  const local = String(b.local_part ?? "").trim().toLowerCase();
  if (!LOCAL_RE.test(local) || local.startsWith(".") || local.endsWith(".")) return c.json({ error: "invalid_local_part" }, 400);
  const email = `${local}@${d.name}`;
  const dup = await db.prepare(`SELECT id FROM accounts WHERE user_id = ? AND email = ?`).bind(d.user_id, email).first();
  if (dup) return c.json({ error: "mailbox_exists" }, 409);
  const id = uid();
  const t = now();
  await db
    .prepare(
      `INSERT INTO accounts (id, user_id, provider, email, display_name, access_token, refresh_token, token_expires_at, history_id, initial_sync_done, initial_sync_page_token, initial_sync_count, sync_status, sync_error, last_synced_at, signature, cover_art, created_at, domain_id)
       VALUES (?, ?, 'domain', ?, ?, NULL, NULL, NULL, NULL, 1, NULL, 0, 'idle', NULL, ?, '', '', ?, ?)`
    )
    .bind(id, d.user_id, email, String(b.display_name ?? "").trim().slice(0, 100), t, t, d.id)
    .run();
  if (b.catch_all) await db.prepare(`UPDATE domains SET catch_all_account_id = ?, updated_at = ? WHERE id = ?`).bind(id, t, d.id).run();
  const row = await db.prepare(`SELECT * FROM accounts WHERE id = ?`).bind(id).first<AccountRow>();
  return c.json(toAccount(row!));
});

/** Remove an account and everything under it (shared with DELETE /api/accounts/:id). */
export async function deleteAccountData(db: D1Database, accountId: string, opts: { keepAccount?: boolean } = {}) {
  await db.batch([
    db.prepare(`DELETE FROM thread_labels WHERE thread_id IN (SELECT id FROM threads WHERE account_id = ?)`).bind(accountId),
    db.prepare(`DELETE FROM collection_threads WHERE thread_id IN (SELECT id FROM threads WHERE account_id = ?)`).bind(accountId),
    db.prepare(`DELETE FROM clips WHERE account_id = ?`).bind(accountId),
    db.prepare(`DELETE FROM collections WHERE account_id = ?`).bind(accountId),
    db.prepare(`DELETE FROM labels WHERE account_id = ?`).bind(accountId),
    db.prepare(`DELETE FROM drafts WHERE account_id = ?`).bind(accountId),
    db.prepare(`DELETE FROM attachment_blobs WHERE attachment_id IN (SELECT id FROM attachments WHERE account_id = ?)`).bind(accountId),
    db.prepare(`DELETE FROM attachments WHERE account_id = ?`).bind(accountId),
    db.prepare(`DELETE FROM messages WHERE account_id = ?`).bind(accountId),
    db.prepare(`DELETE FROM threads WHERE account_id = ?`).bind(accountId),
    db.prepare(`DELETE FROM contacts WHERE account_id = ?`).bind(accountId),
    db.prepare(`DELETE FROM sync_log WHERE account_id = ?`).bind(accountId),
    ...(opts.keepAccount
      ? []
      : [
          db.prepare(`UPDATE domains SET catch_all_account_id = NULL WHERE catch_all_account_id = ?`).bind(accountId),
          // Explicit, not relying on the FK cascade: D1 does not enforce foreign keys everywhere,
          // and leaving this row behind would strand an encrypted password.
          db.prepare(`DELETE FROM imap_accounts WHERE account_id = ?`).bind(accountId),
          db.prepare(`DELETE FROM accounts WHERE id = ?`).bind(accountId),
        ]),
  ]);
}

export default domains;
