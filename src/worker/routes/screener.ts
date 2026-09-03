import { Hono } from "hono";
import type { AppEnv } from "../env";
import type { ContactRow, MessageRow, ThreadRow } from "../db";
import { now, toContact, threadsWithLabels, safeJson, inClause, ownedRow, chunk } from "../db";
import { suggestBucket } from "../sync";
import type { ScreenStatus } from "@shared/types";

const screener = new Hono<AppEnv>();

export type DecisionScope = "all" | "account";

/** Which accounts a decision touches: every account the user has connected, or just this one. */
async function scopeAccountIds(db: D1Database, accountId: string, scope: DecisionScope): Promise<string[]> {
  if (scope === "account") return [accountId];
  const siblings = await db
    .prepare(`SELECT id FROM accounts WHERE user_id = (SELECT user_id FROM accounts WHERE id = ?)`)
    .bind(accountId)
    .all<{ id: string }>();
  const ids = siblings.results.map((r) => r.id);
  if (!ids.includes(accountId)) ids.push(accountId);
  return ids;
}

/**
 * Screening decisions are user-wide by default: deciding for a sender applies to that email across every account the
 * user has connected (contact rows are created where missing), and re-buckets their threads everywhere. Pass
 * scope "account" to touch only the account the contact row belongs to.
 */
export async function applyScreenDecision(db: D1Database, accountId: string, contact: ContactRow, decision: ScreenStatus, scope: DecisionScope = "all") {
  const t = now();
  const bucket = decision === "pending" ? "screener" : decision;
  const ids = await scopeAccountIds(db, accountId, scope);
  const stmts: D1PreparedStatement[] = [];
  for (const id of ids) {
    stmts.push(
      db
        .prepare(
          `INSERT INTO contacts (id, account_id, email, name, screen_status, screened_at, first_seen_at, last_seen_at, message_count, notes, avatar_url)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, '', ?)
           ON CONFLICT(account_id, email) DO UPDATE SET screen_status = excluded.screen_status, screened_at = excluded.screened_at`
        )
        .bind(crypto.randomUUID(), id, contact.email, contact.name, decision, t, t, t, contact.avatar_url ?? "")
    );
  }
  const inSql = `(${ids.map(() => "?").join(",")})`;
  stmts.push(
    decision === "screened_out"
      ? db
          .prepare(
            `UPDATE threads SET bucket = 'screened_out', reply_later = 0, set_aside = 0, updated_at = ? WHERE account_id IN ${inSql} AND bucket IN ('screener','imbox','feed','paper_trail') AND is_sent_only = 0 AND last_from_email = ?`
          )
          .bind(t, ...ids, contact.email)
      : db
          .prepare(
            `UPDATE threads SET bucket = ?, updated_at = ? WHERE account_id IN ${inSql} AND bucket IN ('screener','screened_out') AND EXISTS (SELECT 1 FROM messages m WHERE m.thread_id = threads.id AND m.from_email = ?)`
          )
          .bind(bucket, t, ...ids, contact.email)
  );
  await db.batch(stmts);
}

/** Bundle flag is user-wide too by default; scope "account" limits it to this one account's row. */
export async function applyBundleFlag(db: D1Database, accountId: string, contact: ContactRow, on: boolean, scope: DecisionScope = "all") {
  const t = now();
  const ids = await scopeAccountIds(db, accountId, scope);
  const stmts: D1PreparedStatement[] = ids.map((id) =>
    db
      .prepare(
        `INSERT INTO contacts (id, account_id, email, name, screen_status, screened_at, first_seen_at, last_seen_at, message_count, notes, avatar_url, bundled)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, '', ?, ?)
         ON CONFLICT(account_id, email) DO UPDATE SET bundled = excluded.bundled`
      )
      .bind(crypto.randomUUID(), id, contact.email, contact.name, contact.screen_status, contact.screened_at, t, t, contact.avatar_url ?? "", on ? 1 : 0)
  );
  await db.batch(stmts);
}

// Screening decisions are per contact row, i.e. per (account, email). Unified scope lists every account's queue.
screener.get("/", async (c) => {
  const db = c.env.DB;
  const t = now();
  const sc = inClause(c.get("accountIds"));
  const rows = await db
    .prepare(
      `SELECT t.* FROM threads t WHERE t.account_id IN ${sc.sql} AND t.bucket = 'screener' AND t.merged_into IS NULL AND (t.bubble_up_at IS NULL OR t.bubble_up_at <= ?) ORDER BY t.last_message_at DESC LIMIT 400`
    )
    .bind(...sc.params, t)
    .all<ThreadRow>();
  const threads = await threadsWithLabels(db, rows.results);
  const keyOf = (accountId: string, email: string) => `${accountId}|${email}`;
  const byKey = new Map<string, typeof threads>();
  for (const th of threads) {
    const key = keyOf(th.account_id, th.last_from.email);
    const arr = byKey.get(key) ?? [];
    arr.push(th);
    byKey.set(key, arr);
  }
  const emails = [...new Set(threads.map((th) => th.last_from.email))];
  const contacts = new Map<string, ContactRow>();
  for (const part of chunk(emails, 80)) {
    const cr = await db
      .prepare(`SELECT * FROM contacts WHERE account_id IN ${sc.sql} AND email IN (${part.map(() => "?").join(",")})`)
      .bind(...sc.params, ...part)
      .all<ContactRow>();
    for (const r of cr.results) contacts.set(keyOf(r.account_id, r.email), r);
  }
  // Latest message per sender for suggestion heuristics.
  const latest = new Map<string, MessageRow>();
  for (const part of chunk(rows.results.map((r) => r.id), 90)) {
    const ms = await db
      .prepare(`SELECT m.* FROM messages m WHERE m.thread_id IN (${part.map(() => "?").join(",")}) AND m.is_from_me = 0 ORDER BY m.date DESC`)
      .bind(...part)
      .all<MessageRow>();
    for (const m of ms.results) {
      const key = keyOf(m.account_id, m.from_email);
      if (!latest.has(key)) latest.set(key, m);
    }
  }
  const senders = [...byKey.entries()]
    .map(([key, ths]) => {
      const contact = contacts.get(key);
      const email = ths[0].last_from.email;
      const accountId = ths[0].account_id;
      const m = latest.get(key);
      const suggestion = suggestBucket({
        subject: m?.subject ?? ths[0]?.subject ?? "",
        from_email: email,
        list_unsubscribe: m?.list_unsubscribe ?? "",
        labels: safeJson<string[]>(m?.gmail_labels_json ?? "[]", []),
      });
      return {
        account_id: accountId,
        contact: contact
          ? toContact(contact)
          : { id: "", account_id: accountId, email, name: ths[0]?.last_from.name ?? "", screen_status: "pending" as ScreenStatus, screened_at: null, first_seen_at: ths[0]?.first_message_at ?? t, last_seen_at: ths[0]?.last_message_at ?? t, message_count: ths.length, notes: "", avatar_url: "" },
        threads: ths,
        suggestion,
      };
    })
    .filter((s) => s.contact.id)
    .sort((a, b) => b.threads[0].last_message_at - a.threads[0].last_message_at);
  return c.json({ senders });
});

screener.post("/decide", async (c) => {
  const db = c.env.DB;
  const body = await c.req.json<{ contact_id?: string; decision?: ScreenStatus; scope?: DecisionScope }>().catch(() => ({}) as any);
  const decision = body.decision;
  if (!decision || !["imbox", "feed", "paper_trail", "screened_out"].includes(decision)) return c.json({ error: "invalid_decision" }, 400);
  const contact = await ownedRow<ContactRow>(db, "contacts", body.contact_id ?? "", c.get("user").id);
  if (!contact) return c.json({ error: "not_found" }, 404);
  await applyScreenDecision(db, contact.account_id, contact, decision, body.scope === "account" ? "account" : "all");
  return c.json({ ok: true });
});

screener.get("/screened-out", async (c) => {
  const sc = inClause(c.get("accountIds"));
  const rows = await c.env.DB.prepare(`SELECT * FROM contacts WHERE account_id IN ${sc.sql} AND screen_status = 'screened_out' ORDER BY screened_at DESC LIMIT 500`).bind(...sc.params).all<ContactRow>();
  return c.json({ contacts: rows.results.map(toContact) });
});

export default screener;
