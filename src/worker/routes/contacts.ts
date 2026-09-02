import { Hono } from "hono";
import type { AppEnv } from "../env";
import type { ContactRow, ThreadRow } from "../db";
import { toContact, threadsWithLabels, inClause, ownedRow } from "../db";
import { applyScreenDecision, applyBundleFlag } from "./screener";
import type { ScreenStatus } from "@shared/types";

const contacts = new Hono<AppEnv>();

// Unified scope may return the same email once per account (separate contact rows with separate screener decisions).
contacts.get("/", async (c) => {
  const sc = inClause(c.get("accountIds"));
  const q = (c.req.query("q") ?? "").trim();
  const like = `%${q}%`;
  const rows = q
    ? await c.env.DB.prepare(`SELECT * FROM contacts WHERE account_id IN ${sc.sql} AND (email LIKE ? OR name LIKE ?) ORDER BY CASE screen_status WHEN 'pending' THEN 1 ELSE 0 END, last_seen_at DESC LIMIT 300`).bind(...sc.params, like, like).all<ContactRow>()
    : await c.env.DB.prepare(`SELECT * FROM contacts WHERE account_id IN ${sc.sql} ORDER BY CASE screen_status WHEN 'pending' THEN 1 ELSE 0 END, last_seen_at DESC LIMIT 500`).bind(...sc.params).all<ContactRow>();
  return c.json(rows.results.map(toContact));
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
  const bucket = c.req.query("bucket");
  const bucketSql = bucket && ["imbox", "feed", "paper_trail", "screener", "screened_out", "trash"].includes(bucket) ? `AND t.bucket = ?` : "";
  const threads = await db
    .prepare(
      `SELECT t.* FROM threads t WHERE t.account_id = ? AND t.merged_into IS NULL ${bucketSql} AND (t.participants_json LIKE ? OR EXISTS (SELECT 1 FROM messages m WHERE m.thread_id = t.id AND m.from_email = ?)) ORDER BY t.seen ASC, t.last_message_at DESC LIMIT 100`
    )
    .bind(row.account_id, ...(bucketSql ? [bucket] : []), `%"${row.email}"%`, row.email)
    .all<ThreadRow>();
  return c.json({ contact: toContact(row), threads: await threadsWithLabels(db, threads.results) });
});

contacts.patch("/:id", async (c) => {
  const db = c.env.DB;
  const row = await ownedRow<ContactRow>(db, "contacts", c.req.param("id"), c.get("user").id);
  if (!row) return c.json({ error: "not_found" }, 404);
  const body = await c.req.json<{ name?: string; notes?: string; screen_status?: ScreenStatus; bundled?: boolean }>().catch(() => ({}) as any);
  const name = typeof body.name === "string" ? body.name.trim().slice(0, 200) : row.name;
  const notes = typeof body.notes === "string" ? body.notes.slice(0, 10_000) : row.notes;
  await db.prepare(`UPDATE contacts SET name = ?, notes = ? WHERE id = ?`).bind(name, notes, row.id).run();
  if (body.screen_status && ["imbox", "feed", "paper_trail", "screened_out", "pending"].includes(body.screen_status) && body.screen_status !== row.screen_status) {
    await applyScreenDecision(db, row.account_id, row, body.screen_status);
  }
  if (typeof body.bundled === "boolean" && body.bundled !== !!row.bundled) {
    await applyBundleFlag(db, row.account_id, row, body.bundled);
  }
  const fresh = await db.prepare(`SELECT * FROM contacts WHERE id = ?`).bind(row.id).first<ContactRow>();
  return c.json(toContact(fresh!));
});

export default contacts;
