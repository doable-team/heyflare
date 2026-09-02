import { Hono } from "hono";
import type { AppEnv } from "../env";
import { uid, now, safeJson, inClause, ownedRow, ownedAccount, accountForThread } from "../db";
import type { AccountRow } from "../db";
import { creationAccountId } from "./labels";
import { sendMail } from "../send";
import type { Address, Draft } from "@shared/types";
import type { OutgoingAttachment } from "../mime";

const compose = new Hono<AppEnv>();

function mapDraft(r: any): Draft {
  return {
    id: r.id,
    account_id: r.account_id,
    thread_id: r.thread_id,
    reply_to_message_id: r.reply_to_message_id,
    to: safeJson<Address[]>(r.to_json, []),
    cc: safeJson<Address[]>(r.cc_json, []),
    bcc: safeJson<Address[]>(r.bcc_json, []),
    subject: r.subject,
    body_html: r.body_html,
    send_at: r.send_at,
    status: r.status,
    error: r.error,
    created_at: r.created_at,
    updated_at: r.updated_at,
  };
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
function cleanAddrs(list: unknown): Address[] {
  if (!Array.isArray(list)) return [];
  const out: Address[] = [];
  for (const x of list) {
    if (typeof x === "string") {
      const e = x.trim().toLowerCase();
      if (EMAIL_RE.test(e)) out.push({ email: e, name: "" });
    } else if (x && typeof x === "object" && typeof (x as any).email === "string") {
      const e = (x as any).email.trim().toLowerCase();
      if (EMAIL_RE.test(e)) out.push({ email: e, name: String((x as any).name ?? "").slice(0, 200) });
    }
  }
  return out;
}

compose.get("/drafts", async (c) => {
  const sc = inClause(c.get("accountIds"));
  const rows = await c.env.DB.prepare(`SELECT * FROM drafts WHERE account_id IN ${sc.sql} AND status IN ('draft','scheduled','failed') ORDER BY updated_at DESC LIMIT 200`).bind(...sc.params).all<any>();
  return c.json(rows.results.map(mapDraft));
});

compose.post("/drafts", async (c) => {
  const b = await c.req.json<any>().catch(() => ({}));
  const accountId = await creationAccountId(c, b);
  if (!accountId) return c.json({ error: "invalid_account" }, 400);
  const id = uid();
  const t = now();
  await c.env.DB.prepare(
    `INSERT INTO drafts (id, account_id, thread_id, reply_to_message_id, to_json, cc_json, bcc_json, subject, body_html, send_at, status, error, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 'draft', NULL, ?, ?)`
  )
    .bind(id, accountId, b.thread_id ?? null, b.reply_to_message_id ?? null, JSON.stringify(cleanAddrs(b.to)), JSON.stringify(cleanAddrs(b.cc)), JSON.stringify(cleanAddrs(b.bcc)), String(b.subject ?? "").slice(0, 500), String(b.body_html ?? "").slice(0, 500_000), t, t)
    .run();
  const row = await c.env.DB.prepare(`SELECT * FROM drafts WHERE id = ?`).bind(id).first<any>();
  return c.json(mapDraft(row));
});

compose.patch("/drafts/:id", async (c) => {
  const row = await ownedRow<any>(c.env.DB, "drafts", c.req.param("id"), c.get("user").id);
  if (!row) return c.json({ error: "not_found" }, 404);
  const b = await c.req.json<any>().catch(() => ({}));
  // Optionally move the draft to another owned account (changing the From).
  let accountId: string = row.account_id;
  if (typeof b.account_id === "string" && b.account_id && b.account_id !== row.account_id) {
    const a = await ownedAccount(c.env.DB, c.get("user").id, b.account_id);
    if (!a) return c.json({ error: "invalid_account" }, 400);
    accountId = a.id;
  }
  await c.env.DB.prepare(`UPDATE drafts SET account_id = ?, thread_id = ?, reply_to_message_id = ?, to_json = ?, cc_json = ?, bcc_json = ?, subject = ?, body_html = ?, updated_at = ? WHERE id = ?`)
    .bind(
      accountId,
      b.thread_id !== undefined ? b.thread_id : row.thread_id,
      b.reply_to_message_id !== undefined ? b.reply_to_message_id : row.reply_to_message_id,
      b.to !== undefined ? JSON.stringify(cleanAddrs(b.to)) : row.to_json,
      b.cc !== undefined ? JSON.stringify(cleanAddrs(b.cc)) : row.cc_json,
      b.bcc !== undefined ? JSON.stringify(cleanAddrs(b.bcc)) : row.bcc_json,
      b.subject !== undefined ? String(b.subject).slice(0, 500) : row.subject,
      b.body_html !== undefined ? String(b.body_html).slice(0, 500_000) : row.body_html,
      now(),
      row.id
    )
    .run();
  const fresh = await c.env.DB.prepare(`SELECT * FROM drafts WHERE id = ?`).bind(row.id).first<any>();
  return c.json(mapDraft(fresh));
});

compose.delete("/drafts/:id", async (c) => {
  const row = await ownedRow<any>(c.env.DB, "drafts", c.req.param("id"), c.get("user").id);
  if (!row) return c.json({ error: "not_found" }, 404);
  await c.env.DB.prepare(`DELETE FROM drafts WHERE id = ?`).bind(row.id).run();
  return c.json({ ok: true });
});

compose.post("/send", async (c) => {
  const db = c.env.DB;
  const user = c.get("user");
  const b = await c.req.json<any>().catch(() => ({}));
  // From account: body.account_id (owned) → the thread's account for replies → primary.
  let acc: AccountRow | null = null;
  if (typeof b.account_id === "string" && b.account_id) {
    acc = await ownedAccount(db, user.id, b.account_id);
    if (!acc) return c.json({ error: "invalid_account" }, 400);
  } else if (typeof b.thread_id === "string" && b.thread_id) {
    acc = await accountForThread(db, user.id, b.thread_id);
    if (!acc) return c.json({ error: "thread_not_found" }, 404);
  } else {
    acc = c.get("account");
  }
  if (!acc) return c.json({ error: "no_account" }, 400);
  if (acc.sync_status === "disconnected") return c.json({ error: "account_disconnected" }, 400);
  // A reply must go out from the account that owns the thread (Gmail threadId is account-specific).
  if (typeof b.thread_id === "string" && b.thread_id) {
    const owner = await accountForThread(db, user.id, b.thread_id);
    if (!owner) return c.json({ error: "thread_not_found" }, 404);
    if (owner.id !== acc.id) return c.json({ error: "reply_from_other_account" }, 400);
  }
  const to = cleanAddrs(b.to);
  const cc = cleanAddrs(b.cc);
  const bcc = cleanAddrs(b.bcc);
  if (!to.length && !cc.length && !bcc.length) return c.json({ error: "no_recipients" }, 400);
  const subject = String(b.subject ?? "").slice(0, 500);
  const body_html = String(b.body_html ?? "").slice(0, 500_000);
  const sendAt = b.send_at ? Number(b.send_at) : null;
  const attachments: OutgoingAttachment[] = Array.isArray(b.attachments)
    ? b.attachments
        .filter((a: any) => a && typeof a.data_base64 === "string")
        .slice(0, 10)
        .map((a: any) => ({ filename: String(a.filename ?? "attachment").slice(0, 200), mime_type: String(a.mime_type ?? "application/octet-stream"), data_base64: a.data_base64 }))
    : [];

  if (sendAt && sendAt > now() + 30_000) {
    if (attachments.length) return c.json({ error: "scheduled_send_no_attachments" }, 400);
    let id = uid();
    if (b.draft_id && typeof b.draft_id === "string") {
      // Reuse the draft id only if it is ours (or doesn't exist yet).
      const existing = await db.prepare(`SELECT account_id FROM drafts WHERE id = ?`).bind(b.draft_id).first<{ account_id: string }>();
      if (!existing || (c.get("allAccountIds") ?? []).includes(existing.account_id)) id = b.draft_id;
    }
    const t = now();
    await db
      .prepare(
        `INSERT INTO drafts (id, account_id, thread_id, reply_to_message_id, to_json, cc_json, bcc_json, subject, body_html, send_at, status, error, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'scheduled', NULL, ?, ?)
         ON CONFLICT(id) DO UPDATE SET account_id = excluded.account_id, thread_id = excluded.thread_id, reply_to_message_id = excluded.reply_to_message_id, to_json = excluded.to_json, cc_json = excluded.cc_json, bcc_json = excluded.bcc_json, subject = excluded.subject, body_html = excluded.body_html, send_at = excluded.send_at, status = 'scheduled', error = NULL, updated_at = excluded.updated_at`
      )
      .bind(id, acc.id, b.thread_id ?? null, b.reply_to_message_id ?? null, JSON.stringify(to), JSON.stringify(cc), JSON.stringify(bcc), subject, body_html, sendAt, t, t)
      .run();
    return c.json({ ok: true, scheduled: true, draft_id: id, send_at: sendAt, account_id: acc.id });
  }

  try {
    const r = await sendMail(c.env, acc, { thread_id: b.thread_id ?? null, reply_to_message_id: b.reply_to_message_id ?? null, to, cc, bcc, subject, body_html, attachments });
    if (b.draft_id) {
      const own = inClause(c.get("allAccountIds"));
      await db.prepare(`DELETE FROM drafts WHERE id = ? AND account_id IN ${own.sql}`).bind(b.draft_id, ...own.params).run();
    }
    return c.json({ ok: true, thread_id: r.thread_id, message_id: r.message_id, account_id: acc.id });
  } catch (e) {
    const msg = (e as Error).message ?? "";
    if (msg === "sending_not_configured") return c.json({ error: "sending_not_configured", message: "No outbound provider for this mailbox. Enable Cloudflare Email Sending or set RESEND_API_KEY." }, 400);
    return c.json({ error: "send_failed", message: msg.slice(0, 500) }, 502);
  }
});

compose.post("/send/cancel", async (c) => {
  const b = await c.req.json<{ draft_id?: string }>().catch(() => ({}) as any);
  const own = inClause(c.get("allAccountIds"));
  const r = await c.env.DB.prepare(`UPDATE drafts SET status = 'draft', send_at = NULL, updated_at = ? WHERE id = ? AND account_id IN ${own.sql} AND status = 'scheduled'`)
    .bind(now(), b.draft_id ?? "", ...own.params)
    .run();
  if (!r.meta.changes) return c.json({ error: "not_scheduled" }, 404);
  return c.json({ ok: true });
});

export default compose;
