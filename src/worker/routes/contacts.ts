import { Hono } from "hono";
import type { AppEnv } from "../env";
import type { ContactRow, ThreadRow } from "../db";
import { toContact, threadsWithLabels, inClause, ownedRow } from "../db";
import { applyScreenDecision, applyBundleFlag, type DecisionScope } from "./screener";
import type { MergedContact, ScreenStatus } from "@shared/types";

const contacts = new Hono<AppEnv>();

/**
 * One entry per person, not per account. A contact row exists for every (account, email) pair, so someone who writes
 * to three of your addresses would otherwise appear three times; merge them and report where the accounts disagree.
 */
export function mergeContacts(rows: ContactRow[]): MergedContact[] {
  const byEmail = new Map<string, ContactRow[]>();
  for (const r of rows) {
    const arr = byEmail.get(r.email) ?? [];
    arr.push(r);
    byEmail.set(r.email, arr);
  }
  const out: MergedContact[] = [];
  for (const [email, group] of byEmail) {
    // The row we link to and PATCH: the one that has heard from them most recently.
    const sorted = [...group].sort((a, b) => b.last_seen_at - a.last_seen_at);
    const primary = sorted[0];
    const statuses = group.map((r) => r.screen_status);
    const mixed = new Set(statuses).size > 1;
    const tally = (vals: string[]) => {
      const counts = new Map<string, number>();
      for (const v of vals) counts.set(v, (counts.get(v) ?? 0) + 1);
      return [...counts.entries()].sort((a, b) => b[1] - a[1])[0][0];
    };
    out.push({
      ...toContact(primary),
      email,
      name: group.find((r) => r.name.trim())?.name ?? "",
      avatar_url: group.find((r) => r.avatar_url)?.avatar_url ?? "",
      notes: group.find((r) => r.notes.trim())?.notes ?? "",
      screen_status: (mixed ? tally(statuses) : statuses[0]) as ScreenStatus,
      bundled: tally(group.map((r) => (r.bundled ? "1" : "0"))) === "1",
      message_count: group.reduce((n, r) => n + r.message_count, 0),
      first_seen_at: Math.min(...group.map((r) => r.first_seen_at)),
      last_seen_at: Math.max(...group.map((r) => r.last_seen_at)),
      screened_at: group.reduce<number | null>((acc, r) => (r.screened_at && (!acc || r.screened_at > acc) ? r.screened_at : acc), null),
      mixed,
      accounts: sorted.map((r) => ({ account_id: r.account_id, contact_id: r.id, screen_status: r.screen_status, bundled: !!r.bundled })),
    });
  }
  const rank = (s: ScreenStatus) => (s === "pending" ? 1 : 0);
  return out.sort((a, b) => rank(a.screen_status) - rank(b.screen_status) || b.last_seen_at - a.last_seen_at);
}

contacts.get("/", async (c) => {
  const ids = c.get("accountIds");
  const sc = inClause(ids);
  const q = (c.req.query("q") ?? "").trim();
  const like = `%${q}%`;
  // Fetch enough rows that the merged list still fills a page when several accounts hold the same people.
  const limit = Math.min(2000, (q ? 300 : 500) * Math.max(1, ids.length));
  const rows = q
    ? await c.env.DB.prepare(`SELECT * FROM contacts WHERE account_id IN ${sc.sql} AND (email LIKE ? OR name LIKE ?) ORDER BY CASE screen_status WHEN 'pending' THEN 1 ELSE 0 END, last_seen_at DESC LIMIT ?`).bind(...sc.params, like, like, limit).all<ContactRow>()
    : await c.env.DB.prepare(`SELECT * FROM contacts WHERE account_id IN ${sc.sql} ORDER BY CASE screen_status WHEN 'pending' THEN 1 ELSE 0 END, last_seen_at DESC LIMIT ?`).bind(...sc.params, limit).all<ContactRow>();
  return c.json(mergeContacts(rows.results));
});

// Compose autocomplete: local contacts (any screen status) + the Google address book, deduped by email.
contacts.get("/suggest", async (c) => {
  const sc = inClause(c.get("accountIds"));
  const q = (c.req.query("q") ?? "").trim().toLowerCase();
  if (!q) return c.json([]);
  const like = `%${q}%`;
  const [local, book] = await Promise.all([
    c.env.DB.prepare(`SELECT email, name, avatar_url, last_seen_at FROM contacts WHERE account_id IN ${sc.sql} AND (email LIKE ? OR name LIKE ?) ORDER BY last_seen_at DESC LIMIT 20`).bind(...sc.params, like, like).all<{ email: string; name: string; avatar_url: string; last_seen_at: number }>(),
    c.env.DB.prepare(`SELECT email, name, avatar_url FROM address_book WHERE account_id IN ${sc.sql} AND (email LIKE ? OR name LIKE ?) ORDER BY CASE WHEN email LIKE ? OR name LIKE ? THEN 0 ELSE 1 END, name LIMIT 20`).bind(...sc.params, like, like, `${q}%`, `${q}%`).all<{ email: string; name: string; avatar_url: string }>(),
  ]);
  const seen = new Map<string, { email: string; name: string; avatar_url: string }>();
  for (const r of local.results) seen.set(r.email, { email: r.email, name: r.name, avatar_url: r.avatar_url });
  for (const r of book.results) {
    const prev = seen.get(r.email);
    if (!prev) seen.set(r.email, { email: r.email, name: r.name, avatar_url: r.avatar_url });
    else seen.set(r.email, { email: r.email, name: prev.name || r.name, avatar_url: prev.avatar_url || r.avatar_url });
  }
  return c.json([...seen.values()].slice(0, 10));
});

// Resolve (or create) the contact row for an email address so links from messages land on a contact page.
contacts.get("/by-email", async (c) => {
  const db = c.env.DB;
  const user = c.get("user");
  const email = (c.req.query("email") ?? "").trim().toLowerCase();
  if (!email || !email.includes("@")) return c.json({ error: "invalid_email" }, 400);
  const wanted = c.req.query("account_id") ?? "";
  const all = c.get("allAccountIds");
  const preferred = wanted && all.includes(wanted) ? wanted : all[0];
  if (!preferred) return c.json({ error: "no_account" }, 400);
  const ph = all.map(() => "?").join(",");
  const existing = await db
    .prepare(`SELECT id, account_id FROM contacts WHERE email = ? AND account_id IN (${ph}) ORDER BY CASE WHEN account_id = ? THEN 0 ELSE 1 END, last_seen_at DESC LIMIT 1`)
    .bind(email, ...all, preferred)
    .first<{ id: string; account_id: string }>();
  if (existing) return c.json({ id: existing.id, account_id: existing.account_id });
  const name = (c.req.query("name") ?? "").trim().slice(0, 200);
  const id = crypto.randomUUID();
  const t = Date.now();
  await db
    .prepare(`INSERT INTO contacts (id, account_id, email, name, screen_status, first_seen_at, last_seen_at, message_count, notes, avatar_url) VALUES (?, ?, ?, ?, 'pending', ?, ?, 0, '', '')`)
    .bind(id, preferred, email, name, t, t)
    .run();
  void user;
  return c.json({ id, account_id: preferred });
});

contacts.get("/:id", async (c) => {
  const db = c.env.DB;
  const row = await ownedRow<ContactRow>(db, "contacts", c.req.param("id"), c.get("user").id);
  if (!row) return c.json({ error: "not_found" }, 404);
  const scoped = inClause(c.get("accountIds"));
  // The same person across every account in scope, so the page can show (and change) all of it at once.
  const siblings = await db
    .prepare(`SELECT * FROM contacts WHERE email = ? AND account_id IN ${scoped.sql}`)
    .bind(row.email, ...scoped.params)
    .all<ContactRow>();
  const group = siblings.results.length ? siblings.results : [row];
  const merged = mergeContacts(group).find((m) => m.email === row.email)!;
  const bucket = c.req.query("bucket");
  const bucketSql = bucket && ["imbox", "feed", "paper_trail", "screener", "screened_out", "trash"].includes(bucket) ? `AND t.bucket = ?` : "";
  const threads = await db
    .prepare(
      `SELECT t.* FROM threads t WHERE t.account_id IN ${scoped.sql} AND t.merged_into IS NULL ${bucketSql} AND (t.participants_json LIKE ? OR EXISTS (SELECT 1 FROM messages m WHERE m.thread_id = t.id AND m.from_email = ?)) ORDER BY t.seen ASC, t.last_message_at DESC LIMIT 100`
    )
    .bind(...scoped.params, ...(bucketSql ? [bucket] : []), `%"${row.email}"%`, row.email)
    .all<ThreadRow>();
  // `id`/`account_id` stay the row you asked for, so "only this account" knows which one it means.
  return c.json({ contact: { ...merged, id: row.id, account_id: row.account_id }, threads: await threadsWithLabels(db, threads.results) });
});

contacts.patch("/:id", async (c) => {
  const db = c.env.DB;
  const row = await ownedRow<ContactRow>(db, "contacts", c.req.param("id"), c.get("user").id);
  if (!row) return c.json({ error: "not_found" }, 404);
  const body = await c.req.json<{ name?: string; notes?: string; screen_status?: ScreenStatus; bundled?: boolean; scope?: DecisionScope }>().catch(() => ({}) as any);
  const scope: DecisionScope = body.scope === "account" ? "account" : "all";
  const name = typeof body.name === "string" ? body.name.trim().slice(0, 200) : row.name;
  const notes = typeof body.notes === "string" ? body.notes.slice(0, 10_000) : row.notes;
  await db.prepare(`UPDATE contacts SET name = ?, notes = ? WHERE id = ?`).bind(name, notes, row.id).run();
  // Apply even when this row already matches: the other accounts may not, and "all" is how you square them up.
  const changed = (want: unknown, have: unknown) => scope === "all" || want !== have;
  if (body.screen_status && ["imbox", "feed", "paper_trail", "screened_out", "pending"].includes(body.screen_status) && changed(body.screen_status, row.screen_status)) {
    await applyScreenDecision(db, row.account_id, row, body.screen_status, scope);
  }
  if (typeof body.bundled === "boolean" && changed(body.bundled, !!row.bundled)) {
    await applyBundleFlag(db, row.account_id, row, body.bundled, scope);
  }
  const scoped = inClause(c.get("accountIds"));
  const after = await db.prepare(`SELECT * FROM contacts WHERE email = ? AND account_id IN ${scoped.sql}`).bind(row.email, ...scoped.params).all<ContactRow>();
  const fresh = await db.prepare(`SELECT * FROM contacts WHERE id = ?`).bind(row.id).first<ContactRow>();
  const merged = mergeContacts(after.results.length ? after.results : [fresh!]).find((m) => m.email === row.email)!;
  return c.json({ ...merged, id: row.id, account_id: row.account_id });
});

export default contacts;
