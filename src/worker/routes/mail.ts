import { Hono } from "hono";
import type { AppEnv } from "../env";
import type { AttachmentRow, MessageRow, ThreadRow } from "../db";
import { applyBundleFlag } from "./screener";
import { now, chunk, placeholders, safeJson, runBatch, threadsWithLabels, toThreadSummary, toMessage, getLabelsForThreads, toAttachment, inClause, accountForThread, accountsById, attachAvatars, avatarMap, loadBundles } from "../db";
import type { ContactRow, AccountRow } from "../db";
import { gmailFetch, gmailJson, gmailPost } from "../google";
import { b64urlDecodeBytes } from "../mime";
import type { Address, Bucket, ThreadDetail, ImboxResponse, Counts } from "@shared/types";

const mail = new Hono<AppEnv>();

const VISIBLE = `t.merged_into IS NULL AND (t.bubble_up_at IS NULL OR t.bubble_up_at <= ?)`;
const PAGE = 50;

/** `t.account_id IN (...)` for the accounts in scope (one account, or all of the user's in unified scope). */
function scope(c: any, alias = "t"): { sql: string; params: string[] } {
  const ids: string[] = c.get("accountIds") ?? [];
  const inc = inClause(ids);
  return { sql: `${alias}.account_id IN ${inc.sql}`, params: inc.params };
}

// ---------- Counts ----------
mail.get("/counts", async (c) => {
  const db = c.env.DB;
  const t = now();
  const sc = scope(c);
  const q = (sql: string) => {
    // Bind (scope params + now) once per occurrence of the scope clause in the SQL.
    const times = sql.split(sc.sql).length - 1;
    const params: unknown[] = [];
    for (let i = 0; i < times; i++) params.push(...sc.params, t);
    return db.prepare(sql).bind(...params).first<{ n: number }>();
  };
  const [screener, imbox, feed, paper, rl, sa] = await Promise.all([
    q(`SELECT COUNT(DISTINCT t.account_id || '|' || t.last_from_email) AS n FROM threads t WHERE ${sc.sql} AND t.bucket = 'screener' AND ${VISIBLE}`),
    q(`SELECT (SELECT COUNT(*) FROM threads t WHERE ${sc.sql} AND t.bucket = 'imbox' AND t.bundle_id IS NULL AND t.seen = 0 AND t.reply_later = 0 AND t.set_aside = 0 AND ${VISIBLE})
             + (SELECT COUNT(*) FROM bundles b WHERE b.status = 'open' AND EXISTS (SELECT 1 FROM threads t WHERE t.bundle_id = b.id AND ${sc.sql} AND t.bucket = 'imbox' AND t.reply_later = 0 AND t.set_aside = 0 AND ${VISIBLE})) AS n`),
    q(`SELECT COUNT(*) AS n FROM threads t WHERE ${sc.sql} AND t.bucket = 'feed' AND t.seen = 0 AND ${VISIBLE}`),
    q(`SELECT (SELECT COUNT(*) FROM threads t WHERE ${sc.sql} AND t.bucket = 'paper_trail' AND t.bundle_id IS NULL AND t.seen = 0 AND ${VISIBLE})
             + (SELECT COUNT(*) FROM bundles b WHERE b.status = 'open' AND EXISTS (SELECT 1 FROM threads t WHERE t.bundle_id = b.id AND ${sc.sql} AND t.bucket = 'paper_trail' AND ${VISIBLE})) AS n`),
    q(`SELECT COUNT(*) AS n FROM threads t WHERE ${sc.sql} AND t.reply_later = 1 AND ${VISIBLE}`),
    q(`SELECT COUNT(*) AS n FROM threads t WHERE ${sc.sql} AND t.set_aside = 1 AND ${VISIBLE}`),
  ]);
  const out: Counts = {
    screener: screener?.n ?? 0,
    imbox_new: imbox?.n ?? 0,
    feed_new: feed?.n ?? 0,
    paper_trail_new: paper?.n ?? 0,
    reply_later: rl?.n ?? 0,
    set_aside: sa?.n ?? 0,
  };
  return c.json(out);
});

// ---------- Imbox ----------
mail.get("/imbox", async (c) => {
  const db = c.env.DB;
  const t = now();
  const sc = scope(c);
  const base = `SELECT t.* FROM threads t WHERE ${sc.sql} AND ${VISIBLE}`;
  const [fresh, seen, rl, sa, scr, senders] = await Promise.all([
    db.prepare(`${base} AND t.bucket = 'imbox' AND t.bundle_id IS NULL AND t.seen = 0 AND t.reply_later = 0 AND t.set_aside = 0 ORDER BY t.last_message_at DESC LIMIT 200`).bind(...sc.params, t).all<ThreadRow>(),
    db.prepare(`${base} AND t.bucket = 'imbox' AND t.bundle_id IS NULL AND t.seen = 1 AND t.reply_later = 0 AND t.set_aside = 0 ORDER BY t.last_message_at DESC LIMIT 200`).bind(...sc.params, t).all<ThreadRow>(),
    db.prepare(`${base} AND t.reply_later = 1 AND t.bucket <> 'trash' ORDER BY t.reply_later_at DESC LIMIT 100`).bind(...sc.params, t).all<ThreadRow>(),
    db.prepare(`${base} AND t.set_aside = 1 AND t.bucket <> 'trash' ORDER BY t.set_aside_at DESC LIMIT 100`).bind(...sc.params, t).all<ThreadRow>(),
    db.prepare(`SELECT COUNT(DISTINCT t.account_id || '|' || t.last_from_email) AS n FROM threads t WHERE ${sc.sql} AND t.bucket = 'screener' AND ${VISIBLE}`).bind(...sc.params, t).first<{ n: number }>(),
    db
      .prepare(
        `SELECT t.account_id, t.last_from_email AS email, MAX(t.last_from_name) AS name, COUNT(*) AS thread_count, MAX(t.last_message_at) AS latest
         FROM threads t WHERE ${sc.sql} AND t.bucket = 'screener' AND ${VISIBLE}
         GROUP BY t.account_id, t.last_from_email ORDER BY latest DESC LIMIT 8`
      )
      .bind(...sc.params, t)
      .all<{ account_id: string; email: string; name: string; thread_count: number }>(),
  ]);
  const all = [...fresh.results, ...seen.results, ...rl.results, ...sa.results];
  const labels = await getLabelsForThreads(
    db,
    all.map((r) => r.id)
  );
  const map = (rows: ThreadRow[]) => rows.map((r) => toThreadSummary(r, labels.get(r.id) ?? []));
  const senderPairs = senders.results.map((r) => ({ account_id: r.account_id, email: r.email }));
  const [newT, seenT, rlT, saT, senderAvatars] = await Promise.all([
    attachAvatars(db, map(fresh.results)),
    attachAvatars(db, map(seen.results)),
    attachAvatars(db, map(rl.results)),
    attachAvatars(db, map(sa.results)),
    avatarMap(db, senderPairs),
  ]);
  const bundles = await loadBundles(db, c.get("accountIds"), "imbox", t);
  const out: ImboxResponse = {
    new_threads: newT,
    seen_threads: seenT,
    bundles,
    reply_later: rlT,
    set_aside: saT,
    screener_count: scr?.n ?? 0,
    screener_senders: senders.results.map((r) => ({
      account_id: r.account_id,
      email: r.email,
      name: r.name ?? "",
      thread_count: r.thread_count,
      avatar_url: senderAvatars.get(`${r.account_id}|${(r.email ?? "").toLowerCase()}`) ?? "",
    })),
  };
  return c.json(out);
});

// ---------- Thread lists ----------
mail.get("/threads", async (c) => {
  const db = c.env.DB;
  const t = now();
  const sc = scope(c);
  const bucket = c.req.query("bucket") ?? "everything";
  const page = Math.max(0, parseInt(c.req.query("page") ?? "0", 10) || 0);
  const label = c.req.query("label");
  const q = (c.req.query("q") ?? "").trim();
  const where: string[] = [sc.sql, bucket === "bubble_up" ? `t.merged_into IS NULL AND t.bubble_up_at IS NOT NULL AND t.bubble_up_at > ?` : VISIBLE];
  const params: unknown[] = [...sc.params, t];
  switch (bucket) {
    case "bubble_up":
      where.push(`t.bucket <> 'trash'`);
      break;
    case "imbox":
    case "feed":
    case "paper_trail":
    case "screened_out":
    case "trash":
    case "screener":
      where.push(`t.bucket = ?`);
      params.push(bucket);
      break;
    case "sent":
      where.push(`t.bucket <> 'trash' AND EXISTS (SELECT 1 FROM messages m WHERE m.thread_id = t.id AND m.is_from_me = 1)`);
      break;
    case "reply_later":
      where.push(`t.reply_later = 1 AND t.bucket <> 'trash'`);
      break;
    case "set_aside":
      where.push(`t.set_aside = 1 AND t.bucket <> 'trash'`);
      break;
    case "bubbled":
      where.push(`t.bubbled = 1 AND t.bucket <> 'trash'`);
      break;
    case "everything":
    default:
      where.push(`t.bucket <> 'trash' AND t.bucket <> 'screened_out'`);
  }
  if (label) {
    where.push(`EXISTS (SELECT 1 FROM thread_labels tl WHERE tl.thread_id = t.id AND tl.label_id = ?)`);
    params.push(label);
  }
  if (q) {
    const like = `%${q}%`;
    where.push(`(t.subject LIKE ? OR t.custom_subject LIKE ? OR t.snippet LIKE ? OR t.participants_json LIKE ?)`);
    params.push(like, like, like, like);
  }
  const order = bucket === "reply_later" ? "t.reply_later_at DESC" : bucket === "set_aside" ? "t.set_aside_at DESC" : bucket === "bubble_up" ? "t.bubble_up_at ASC" : "t.last_message_at DESC";
  const bundlesApply = bucket === "paper_trail" && !q && !label;
  if (bundlesApply) where.push(`t.bundle_id IS NULL`);
  const rows = await db
    .prepare(`SELECT t.* FROM threads t WHERE ${where.join(" AND ")} ORDER BY ${order} LIMIT ? OFFSET ?`)
    .bind(...params, PAGE + 1, page * PAGE)
    .all<ThreadRow>();
  const hasMore = rows.results.length > PAGE;
  const threads = await threadsWithLabels(db, rows.results.slice(0, PAGE));
  if (bundlesApply && page === 0) {
    const bundles = await loadBundles(db, c.get("accountIds"), "paper_trail", t);
    return c.json({ threads, bundles, next_page: hasMore ? page + 1 : null });
  }
  return c.json({ threads, next_page: hasMore ? page + 1 : null });
});

// ---------- Feed (with latest message) ----------
mail.get("/feed", async (c) => {
  const db = c.env.DB;
  const t = now();
  const sc = scope(c);
  const page = Math.max(0, parseInt(c.req.query("page") ?? "0", 10) || 0);
  const FEED_PAGE = 30;
  // The Feed shows what you haven't marked done yet (seen = 0) by default; ?show=all includes everything.
  const showAll = c.req.query("show") === "all";
  const rows = await db
    .prepare(`SELECT t.* FROM threads t WHERE ${sc.sql} AND t.bucket = 'feed' AND ${VISIBLE}${showAll ? "" : " AND t.seen = 0"} ORDER BY t.last_message_at DESC LIMIT ? OFFSET ?`)
    .bind(...sc.params, t, FEED_PAGE + 1, page * FEED_PAGE)
    .all<ThreadRow>();
  const hasMore = rows.results.length > FEED_PAGE;
  const list = rows.results.slice(0, FEED_PAGE);
  const summaries = await threadsWithLabels(db, list);
  const latest = new Map<string, MessageRow>();
  for (const ids of chunk(list.map((r) => r.id), 90)) {
    const ms = await db
      .prepare(
        `SELECT m.* FROM messages m WHERE m.thread_id IN (${placeholders(ids.length)}) AND m.date = (SELECT MAX(date) FROM messages x WHERE x.thread_id = m.thread_id)`
      )
      .bind(...ids)
      .all<MessageRow>();
    for (const m of ms.results) latest.set(m.thread_id, m);
  }
  const threads = summaries.map((s) => {
    const m = latest.has(s.id) ? toMessage(latest.get(s.id)!) : null;
    if (m && m.from.email.toLowerCase() === s.last_from.email.toLowerCase() && s.last_from.avatar_url) m.from.avatar_url = s.last_from.avatar_url;
    return { ...s, latest_message: m };
  });
  return c.json({ threads, next_page: hasMore ? page + 1 : null });
});

// ---------- Power through new ----------
/**
 * Everything sitting in the Imbox's "New for you", each with its latest message body, so the whole
 * queue can be triaged on one page (HEY's "Power Through New"). Threads inside an open bundle are
 * stacked inline — powering through is about the mail, not the grouping.
 */
mail.get("/power-through", async (c) => {
  const db = c.env.DB;
  const t = now();
  const sc = scope(c);
  const CAP = 50;
  const rows = await db
    .prepare(
      `SELECT t.* FROM threads t
       LEFT JOIN bundles b ON b.id = t.bundle_id
       WHERE ${sc.sql} AND t.bucket = 'imbox' AND t.reply_later = 0 AND t.set_aside = 0 AND ${VISIBLE}
         AND (t.bundle_id IS NULL AND t.seen = 0 OR b.status = 'open')
       ORDER BY t.last_message_at DESC LIMIT ?`
    )
    .bind(...sc.params, t, CAP)
    .all<ThreadRow>();
  const list = rows.results;
  const summaries = await threadsWithLabels(db, list);
  const latest = new Map<string, MessageRow>();
  for (const ids of chunk(list.map((r) => r.id), 90)) {
    const ms = await db
      .prepare(
        `SELECT m.* FROM messages m WHERE m.thread_id IN (${placeholders(ids.length)}) AND m.date = (SELECT MAX(date) FROM messages x WHERE x.thread_id = m.thread_id)`
      )
      .bind(...ids)
      .all<MessageRow>();
    for (const m of ms.results) latest.set(m.thread_id, m);
  }
  const items = summaries.map((s) => {
    const m = latest.has(s.id) ? toMessage(latest.get(s.id)!) : null;
    if (m && m.from.email.toLowerCase() === s.last_from.email.toLowerCase() && s.last_from.avatar_url) m.from.avatar_url = s.last_from.avatar_url;
    return { ...s, latest_message: m };
  });
  return c.json({ items });
});

/** "Mark all as seen" at the bottom of the power-through page. */
mail.post("/power-through/seen", async (c) => {
  const db = c.env.DB;
  const t = now();
  const body = await c.req.json<{ thread_ids?: string[] }>().catch(() => ({}) as { thread_ids?: string[] });
  const ids = (body.thread_ids ?? []).slice(0, 200);
  if (!ids.length) return c.json({ error: "no_threads" }, 400);
  const owned = inClause(c.get("allAccountIds") ?? []);
  const mine = await db
    .prepare(`SELECT id, account_id FROM threads WHERE id IN (${placeholders(ids.length)}) AND account_id IN ${owned.sql}`)
    .bind(...ids, ...owned.params)
    .all<{ id: string; account_id: string }>();
  if (!mine.results.length) return c.json({ ok: true, count: 0 });
  const mineIds = mine.results.map((r) => r.id);

  // Gmail's own read state, per account, before we clear ours.
  const unread = await db
    .prepare(`SELECT account_id, gmail_message_id FROM messages WHERE thread_id IN (${placeholders(mineIds.length)}) AND unread = 1 AND gmail_message_id <> ''`)
    .bind(...mineIds)
    .all<{ account_id: string; gmail_message_id: string }>();

  await runBatch(db, [
    ...mineIds.map((id) => db.prepare(`UPDATE threads SET seen = 1, unread = 0, bubbled = 0, updated_at = ? WHERE id = ?`).bind(t, id)),
    ...mineIds.map((id) => db.prepare(`UPDATE messages SET unread = 0 WHERE thread_id = ?`).bind(id)),
  ]);

  // A bundle whose whole batch is now seen is finished: close it, so the queue really does empty.
  await db
    .prepare(
      `UPDATE bundles SET status = 'seen', seen_at = ?
       WHERE status = 'open'
         AND EXISTS (SELECT 1 FROM threads t WHERE t.bundle_id = bundles.id AND t.id IN (${placeholders(mineIds.length)}))
         AND NOT EXISTS (SELECT 1 FROM threads t WHERE t.bundle_id = bundles.id AND t.seen = 0)`
    )
    .bind(t, ...mineIds)
    .run();

  if (unread.results.length) {
    const byAccount = new Map<string, string[]>();
    for (const r of unread.results) byAccount.set(r.account_id, [...(byAccount.get(r.account_id) ?? []), r.gmail_message_id]);
    const accounts = await accountsById(db, c.get("user").id, [...byAccount.keys()]);
    for (const [accId, gmailIds] of byAccount) {
      const acc = accounts.get(accId);
      if (!acc || acc.provider !== "gmail") continue;
      for (const part of chunk(gmailIds, 900)) {
        c.executionCtx.waitUntil(gmailPost(c.env, acc, `messages/batchModify`, { ids: part, removeLabelIds: ["UNREAD"] }).catch(() => {}));
      }
    }
  }
  return c.json({ ok: true, count: mineIds.length });
});

// ---------- Search ----------
mail.get("/search", async (c) => {
  const db = c.env.DB;
  const sc = scope(c);
  const q = (c.req.query("q") ?? "").trim();
  const page = Math.max(0, parseInt(c.req.query("page") ?? "0", 10) || 0);
  if (!q) return c.json({ threads: [], next_page: null });
  const like = `%${q}%`;
  const rows = await db
    .prepare(
      `SELECT t.* FROM threads t WHERE ${sc.sql} AND t.merged_into IS NULL AND t.bucket <> 'trash' AND (
         t.subject LIKE ? OR t.custom_subject LIKE ? OR t.snippet LIKE ? OR t.participants_json LIKE ? OR t.note LIKE ?
         OR EXISTS (SELECT 1 FROM messages m WHERE m.thread_id = t.id AND (m.text_body LIKE ? OR m.from_email LIKE ? OR m.subject LIKE ?))
       ) ORDER BY t.last_message_at DESC LIMIT ? OFFSET ?`
    )
    .bind(...sc.params, like, like, like, like, like, like, like, like, PAGE + 1, page * PAGE)
    .all<ThreadRow>();
  const hasMore = rows.results.length > PAGE;
  const threads = await threadsWithLabels(db, rows.results.slice(0, PAGE));
  return c.json({ threads, next_page: hasMore ? page + 1 : null, q });
});

// ---------- Thread detail ----------
/** A thread row the user owns (through any of their accounts), regardless of the requested scope. */
async function ownedThread(c: any, id: string): Promise<ThreadRow | null> {
  const db: D1Database = c.env.DB;
  const user = c.get("user");
  return (await db.prepare(`SELECT t.* FROM threads t JOIN accounts a ON a.id = t.account_id WHERE t.id = ? AND a.user_id = ?`).bind(id, user.id).first<ThreadRow>()) ?? null;
}

async function loadThreadDetail(c: any, id: string): Promise<ThreadDetail | null> {
  const db: D1Database = c.env.DB;
  const row = await ownedThread(c, id);
  if (!row) return null;
  const accId = row.account_id;
  const merged = await db.prepare(`SELECT id, subject, custom_subject FROM threads WHERE merged_into = ? AND account_id = ?`).bind(row.id, accId).all<{ id: string; subject: string; custom_subject: string | null }>();
  const threadIds = [row.id, ...merged.results.map((m) => m.id)];
  const msgs = await db
    .prepare(`SELECT * FROM messages WHERE thread_id IN (${placeholders(threadIds.length)}) AND account_id = ? ORDER BY date ASC`)
    .bind(...threadIds, accId)
    .all<MessageRow>();
  const atts = await db
    .prepare(`SELECT * FROM attachments WHERE thread_id IN (${placeholders(threadIds.length)}) AND account_id = ? ORDER BY created_at ASC`)
    .bind(...threadIds, accId)
    .all<AttachmentRow>();
  const attsByMsg = new Map<string, AttachmentRow[]>();
  for (const a of atts.results) {
    const arr = attsByMsg.get(a.message_id) ?? [];
    arr.push(a);
    attsByMsg.set(a.message_id, arr);
  }
  const labels = await getLabelsForThreads(db, [row.id]);
  const cols = await db
    .prepare(`SELECT c.id, c.name FROM collection_threads ct JOIN collections c ON c.id = ct.collection_id WHERE ct.thread_id = ? ORDER BY c.name`)
    .bind(row.id)
    .all<{ id: string; name: string }>();
  const clips = await db.prepare(`SELECT * FROM clips WHERE thread_id = ? AND account_id = ? ORDER BY created_at DESC`).bind(row.id, accId).all<any>();
  const [summary] = await attachAvatars(db, [toThreadSummary(row, labels.get(row.id) ?? [])]);
  const messages = msgs.results.map((m) => toMessage(m, attsByMsg.get(m.id) ?? []));
  const msgAvatars = await avatarMap(
    db,
    messages.map((m) => ({ account_id: m.account_id, email: m.from.email }))
  );
  for (const m of messages) {
    const u = msgAvatars.get(`${m.account_id}|${m.from.email.toLowerCase()}`);
    if (u) m.from.avatar_url = u;
  }
  const detail: ThreadDetail = {
    ...summary,
    messages,
    collections: cols.results,
    clips: clips.results.map((k) => ({ id: k.id, account_id: k.account_id, thread_id: k.thread_id, message_id: k.message_id, text: k.text, created_at: k.created_at })),
    merged_threads: merged.results.map((m) => ({ id: m.id, subject: m.custom_subject ?? m.subject })),
    sender_bundled: !!(await db.prepare(`SELECT bundled FROM contacts WHERE account_id = ? AND email = ?`).bind(row.account_id, row.last_from_email.toLowerCase()).first<{ bundled: number }>())?.bundled,
  };
  return detail;
}

mail.get("/threads/:id", async (c) => {
  const db = c.env.DB;
  const id = c.req.param("id");
  const peek = c.req.query("peek") === "1";
  const detail = await loadThreadDetail(c, id);
  if (!detail) return c.json({ error: "not_found" }, 404);
  if (!peek && (detail.unread || !detail.seen)) {
    const unreadGmailIds = await db
      .prepare(`SELECT gmail_message_id FROM messages WHERE thread_id = ? AND account_id = ? AND unread = 1`)
      .bind(id, detail.account_id)
      .all<{ gmail_message_id: string }>();
    await db.batch([
      db.prepare(`UPDATE threads SET seen = 1, unread = 0, bubbled = 0, updated_at = ? WHERE id = ?`).bind(now(), id),
      db.prepare(`UPDATE messages SET unread = 0 WHERE thread_id = ?`).bind(id),
    ]);
    detail.seen = true;
    detail.unread = false;
    detail.bubbled = false;
    for (const m of detail.messages) m.unread = false;
    if (unreadGmailIds.results.length) {
      const acc = await accountForThread(db, c.get("user").id, id);
      if (acc) {
        c.executionCtx.waitUntil(
          gmailPost(c.env, acc, `messages/batchModify`, { ids: unreadGmailIds.results.map((r) => r.gmail_message_id), removeLabelIds: ["UNREAD"] }).catch(() => {})
        );
      }
    }
  }
  return c.json(detail);
});

// ---------- Actions ----------
export type ActionBody = {
  action: string;
  on?: boolean;
  at?: number | null;
  bucket?: Bucket;
  subject?: string | null;
  note?: string;
  thread_ids?: string[];
  add?: string[];
  remove?: string[];
};

async function applyAction(c: any, threadId: string, body: ActionBody, accountCache?: Map<string, AccountRow>): Promise<{ ok: true } | { error: string; status: number }> {
  const db: D1Database = c.env.DB;
  const t = now();
  const row = await ownedThread(c, threadId);
  if (!row) return { error: "not_found", status: 404 };
  const accId = row.account_id;
  const allIds: string[] = c.get("allAccountIds") ?? [];
  const ownedIn = inClause(allIds);
  // Gmail calls use the thread's own account tokens, never the header account.
  const gmailAccount = async (): Promise<AccountRow | null> => {
    if (accountCache?.has(accId)) return accountCache.get(accId)!;
    const a = await accountForThread(db, c.get("user").id, threadId);
    if (a && accountCache) accountCache.set(accId, a);
    return a;
  };
  const upd = (sql: string, ...params: unknown[]) => db.prepare(`UPDATE threads SET ${sql}, updated_at = ? WHERE id = ? AND account_id = ?`).bind(...params, t, threadId, accId).run();

  switch (body.action) {
    case "bundle": {
      const email = row.last_from_email.toLowerCase();
      let contact = await db.prepare(`SELECT * FROM contacts WHERE account_id = ? AND email = ?`).bind(accId, email).first<ContactRow>();
      if (!contact) {
        const status = row.bucket === "paper_trail" || row.bucket === "imbox" ? row.bucket : "imbox";
        contact = {
          id: crypto.randomUUID(), account_id: accId, email, name: row.last_from_name ?? "", screen_status: status, screened_at: t,
          first_seen_at: t, last_seen_at: t, message_count: 0, notes: "", avatar_url: "", bundled: 0,
        };
      }
      await applyBundleFlag(db, accId, contact, body.on !== false);
      return { ok: true };
    }
    case "mark_unread":
      await upd(`unread = 1, seen = 0`);
      return { ok: true };
    case "mark_read":
      await upd(`unread = 0, seen = 1`);
      await db.prepare(`UPDATE messages SET unread = 0 WHERE thread_id = ?`).bind(threadId).run();
      return { ok: true };
    case "seen":
      await upd(`seen = 1, unread = 0, bubbled = 0`);
      await db.prepare(`UPDATE messages SET unread = 0 WHERE thread_id = ?`).bind(threadId).run();
      return { ok: true };
    case "reply_later": {
      const on = body.on !== false;
      await upd(`reply_later = ?, reply_later_at = ?, set_aside = CASE WHEN ? THEN 0 ELSE set_aside END`, on ? 1 : 0, on ? t : null, on ? 1 : 0);
      return { ok: true };
    }
    case "set_aside": {
      const on = body.on !== false;
      await upd(`set_aside = ?, set_aside_at = ?, reply_later = CASE WHEN ? THEN 0 ELSE reply_later END`, on ? 1 : 0, on ? t : null, on ? 1 : 0);
      return { ok: true };
    }
    case "bubble_up": {
      const at = body.at == null ? null : Number(body.at);
      if (at != null && (!Number.isFinite(at) || at <= t)) return { error: "invalid_time", status: 400 };
      await upd(`bubble_up_at = ?, bubbled = 0`, at);
      return { ok: true };
    }
    case "move": {
      const b = body.bucket;
      if (!b || !["imbox", "feed", "paper_trail", "trash", "screened_out", "screener"].includes(b)) return { error: "invalid_bucket", status: 400 };
      await upd(`bucket = ?, reply_later = CASE WHEN ? = 'trash' THEN 0 ELSE reply_later END, set_aside = CASE WHEN ? = 'trash' THEN 0 ELSE set_aside END`, b, b, b);
      if (b === "trash" || row.bucket === "trash") {
        const acc = await gmailAccount();
        if (acc) c.executionCtx.waitUntil(gmailPost(c.env, acc, `threads/${row.gmail_thread_id}/${b === "trash" ? "trash" : "untrash"}`, {}).catch(() => {}));
      }
      return { ok: true };
    }
    case "rename": {
      const s = body.subject == null || body.subject.trim() === "" ? null : body.subject.trim().slice(0, 500);
      await upd(`custom_subject = ?`, s);
      return { ok: true };
    }
    case "note":
      await upd(`note = ?`, (body.note ?? "").slice(0, 10_000));
      return { ok: true };
    case "merge": {
      const ids = (body.thread_ids ?? []).filter((x) => x && x !== threadId);
      if (!ids.length) return { error: "no_threads", status: 400 };
      // Merging only within the same Gmail account (messages/attachments are keyed by account).
      const others = await db
        .prepare(`SELECT * FROM threads WHERE account_id = ? AND id IN (${placeholders(ids.length)}) AND merged_into IS NULL`)
        .bind(accId, ...ids)
        .all<ThreadRow>();
      if (!others.results.length) return { error: "not_found", status: 404 };
      let participants = safeJson<Address[]>(row.participants_json, []);
      let count = row.message_count;
      let last = row.last_message_at;
      let first = row.first_message_at;
      const stmts: D1PreparedStatement[] = [];
      for (const o of others.results) {
        count += o.message_count;
        last = Math.max(last, o.last_message_at);
        first = Math.min(first, o.first_message_at);
        const map = new Map(participants.map((p) => [p.email, p]));
        for (const p of safeJson<Address[]>(o.participants_json, [])) if (!map.has(p.email)) map.set(p.email, p);
        participants = [...map.values()];
        stmts.push(db.prepare(`UPDATE threads SET merged_into = ?, reply_later = 0, set_aside = 0, updated_at = ? WHERE id = ?`).bind(threadId, t, o.id));
        // Also re-point threads that were merged into the other thread.
        stmts.push(db.prepare(`UPDATE threads SET merged_into = ? WHERE merged_into = ?`).bind(threadId, o.id));
      }
      stmts.push(
        db
          .prepare(`UPDATE threads SET message_count = ?, last_message_at = ?, first_message_at = ?, participants_json = ?, has_attachments = has_attachments OR ?, updated_at = ? WHERE id = ?`)
          .bind(count, last, first, JSON.stringify(participants), others.results.some((o) => o.has_attachments) ? 1 : 0, t, threadId)
      );
      await runBatch(db, stmts, 40);
      return { ok: true };
    }
    case "labels": {
      const stmts: D1PreparedStatement[] = [];
      for (const l of body.add ?? []) {
        stmts.push(db.prepare(`INSERT OR IGNORE INTO thread_labels (thread_id, label_id) SELECT ?, id FROM labels WHERE id = ? AND account_id IN ${ownedIn.sql}`).bind(threadId, l, ...ownedIn.params));
      }
      for (const l of body.remove ?? []) stmts.push(db.prepare(`DELETE FROM thread_labels WHERE thread_id = ? AND label_id = ?`).bind(threadId, l));
      if (stmts.length) await runBatch(db, stmts, 40);
      return { ok: true };
    }
    case "collections": {
      const stmts: D1PreparedStatement[] = [];
      for (const col of body.add ?? []) {
        stmts.push(
          db.prepare(`INSERT OR IGNORE INTO collection_threads (collection_id, thread_id, added_at) SELECT id, ?, ? FROM collections WHERE id = ? AND account_id IN ${ownedIn.sql}`).bind(threadId, t, col, ...ownedIn.params)
        );
        stmts.push(db.prepare(`UPDATE collections SET updated_at = ? WHERE id = ? AND account_id IN ${ownedIn.sql}`).bind(t, col, ...ownedIn.params));
      }
      for (const col of body.remove ?? []) stmts.push(db.prepare(`DELETE FROM collection_threads WHERE collection_id = ? AND thread_id = ?`).bind(col, threadId));
      if (stmts.length) await runBatch(db, stmts, 40);
      return { ok: true };
    }
    case "delete": {
      const merged = await db.prepare(`SELECT id, gmail_thread_id FROM threads WHERE merged_into = ? AND account_id = ?`).bind(threadId, accId).all<{ id: string; gmail_thread_id: string }>();
      const ids = [threadId, ...merged.results.map((m) => m.id)];
      await db.batch([
        db.prepare(`DELETE FROM thread_labels WHERE thread_id IN (${placeholders(ids.length)})`).bind(...ids),
        db.prepare(`DELETE FROM collection_threads WHERE thread_id IN (${placeholders(ids.length)})`).bind(...ids),
        db.prepare(`DELETE FROM clips WHERE thread_id IN (${placeholders(ids.length)})`).bind(...ids),
        db.prepare(`DELETE FROM attachments WHERE thread_id IN (${placeholders(ids.length)})`).bind(...ids),
        db.prepare(`DELETE FROM messages WHERE thread_id IN (${placeholders(ids.length)})`).bind(...ids),
        db.prepare(`DELETE FROM threads WHERE id IN (${placeholders(ids.length)})`).bind(...ids),
      ]);
      const gmailIds = [row.gmail_thread_id, ...merged.results.map((m) => m.gmail_thread_id)];
      const acc = await gmailAccount();
      if (acc) c.executionCtx.waitUntil(Promise.all(gmailIds.map((g) => gmailPost(c.env, acc, `threads/${g}/trash`, {}).catch(() => {}))));
      return { ok: true };
    }
    default:
      return { error: "unknown_action", status: 400 };
  }
}

mail.post("/threads/:id/actions", async (c) => {
  const body = await c.req.json<ActionBody>().catch(() => ({}) as ActionBody);
  const id = c.req.param("id");
  const r = await applyAction(c, id, body);
  if ("error" in r) return c.json({ error: r.error }, r.status as any);
  if (body.action === "delete") return c.json({ ok: true, deleted: true });
  const detail = await loadThreadDetail(c, id);
  return c.json(detail);
});

mail.post("/threads/bulk", async (c) => {
  const body = await c.req.json<ActionBody>().catch(() => ({}) as ActionBody);
  const ids = (body.thread_ids ?? []).slice(0, 200);
  if (!ids.length) return c.json({ error: "no_threads" }, 400);
  if (body.action === "merge") return c.json({ error: "use_thread_action" }, 400);
  // Threads may span several accounts; resolve each account once.
  const cache = await accountsById(c.env.DB, c.get("user").id, c.get("allAccountIds") ?? []);
  let ok = 0;
  for (const id of ids) {
    const r = await applyAction(c, id, body, cache);
    if ("ok" in r) ok++;
  }
  return c.json({ ok: true, count: ok });
});

// ---------- Attachment proxy ----------
mail.get("/messages/:id/attachments/:attId", async (c) => {
  const db = c.env.DB;
  const user = c.get("user");
  const att = await db
    .prepare(
      `SELECT a.*, m.gmail_message_id FROM attachments a JOIN messages m ON m.id = a.message_id JOIN accounts ac ON ac.id = a.account_id WHERE a.id = ? AND a.message_id = ? AND ac.user_id = ?`
    )
    .bind(c.req.param("attId"), c.req.param("id"), user.id)
    .first<AttachmentRow & { gmail_message_id: string }>();
  if (!att) return c.json({ error: "not_found" }, 404);
  const acc = await db.prepare(`SELECT * FROM accounts WHERE id = ?`).bind(att.account_id).first<AccountRow>();
  if (!acc) return c.json({ error: "not_found" }, 404);
  const download = c.req.query("download") === "1";
  const safeName = (att.filename || "attachment").replace(/[\r\n"]/g, "_");
  let ctype = att.mime_type || "application/octet-stream";
  if (/^text\/html/i.test(ctype) || /^image\/svg/i.test(ctype)) ctype = "application/octet-stream";
  const headersFor = (len: number) => ({
    "content-type": ctype,
    "content-length": String(len),
    "content-disposition": `${download ? "attachment" : "inline"}; filename="${safeName}"; filename*=UTF-8''${encodeURIComponent(att.filename || "attachment")}`,
    "cache-control": "private, max-age=3600",
    "x-content-type-options": "nosniff",
  });
  if (acc.provider !== "gmail") {
    const blob = await db.prepare(`SELECT data FROM attachment_blobs WHERE attachment_id = ?`).bind(att.id).first<{ data: unknown }>();
    const raw = blob?.data;
    // D1 hands BLOBs back as ArrayBuffer (remote) or number[] (local); normalize.
    const bytes = raw instanceof ArrayBuffer ? new Uint8Array(raw) : Array.isArray(raw) ? Uint8Array.from(raw as number[]) : ArrayBuffer.isView(raw) ? new Uint8Array(raw.buffer, raw.byteOffset, raw.byteLength) : null;
    if (!bytes) return c.json({ error: "attachment_not_stored" }, 404);
    return new Response(bytes, { headers: headersFor(bytes.byteLength) });
  }
  let res: Response;
  try {
    res = await gmailFetch(c.env, acc, `messages/${att.gmail_message_id}/attachments/${att.gmail_attachment_id}`);
  } catch (e) {
    return c.json({ error: "gmail_error", message: ((e as Error).message ?? "").slice(0, 300) }, 502);
  }
  if (!res.ok) return c.json({ error: "gmail_error", status: res.status }, 502);
  const j = (await res.json()) as { data?: string; size?: number };
  const bytes = b64urlDecodeBytes(j.data ?? "");
  return new Response(bytes, { headers: headersFor(bytes.byteLength) });
});

// ---------- Files ----------
mail.get("/files", async (c) => {
  const db = c.env.DB;
  const sc = scope(c, "a");
  const page = Math.max(0, parseInt(c.req.query("page") ?? "0", 10) || 0);
  const q = (c.req.query("q") ?? "").trim();
  const params: unknown[] = [...sc.params];
  let extra = "";
  if (q) {
    extra = ` AND (a.filename LIKE ? OR t.subject LIKE ?)`;
    params.push(`%${q}%`, `%${q}%`);
  }
  const rows = await db
    .prepare(
      `SELECT a.*, t.subject AS t_subject, t.custom_subject AS t_custom_subject, m.from_email, m.from_name FROM attachments a JOIN messages m ON m.id = a.message_id JOIN threads t ON t.id = a.thread_id WHERE ${sc.sql} AND a.is_inline = 0${extra} ORDER BY a.created_at DESC LIMIT ? OFFSET ?`
    )
    .bind(...params, PAGE + 1, page * PAGE)
    .all<AttachmentRow & { t_subject: string; t_custom_subject: string | null; from_email: string; from_name: string }>();
  const hasMore = rows.results.length > PAGE;
  const files = rows.results.slice(0, PAGE).map((r) => toAttachment(r, { thread_subject: r.t_custom_subject ?? r.t_subject, from: { email: r.from_email, name: r.from_name } }));
  return c.json({ files, next_page: hasMore ? page + 1 : null });
});

export { loadThreadDetail, applyAction };
export default mail;
