import { Hono } from "hono";
import type { AppEnv } from "../env";
import type { AttachmentRow, ThreadRow } from "../db";
import { uid, now, threadsWithLabels, toAttachment, inClause, ownedRow } from "../db";
import { creationAccountId } from "./labels";
import type { Collection } from "@shared/types";

const collections = new Hono<AppEnv>();

const SELECT = `SELECT c.*, (SELECT COUNT(*) FROM collection_threads ct WHERE ct.collection_id = c.id) AS thread_count,
  (SELECT COUNT(*) FROM attachments a JOIN collection_threads ct2 ON ct2.thread_id = a.thread_id WHERE ct2.collection_id = c.id AND a.is_inline = 0) AS file_count
  FROM collections c`;

function map(r: any): Collection {
  return { id: r.id, account_id: r.account_id, name: r.name, description: r.description, thread_count: r.thread_count ?? 0, file_count: r.file_count ?? 0, created_at: r.created_at, updated_at: r.updated_at };
}

// Collections are stored under one account but may hold threads from any of the user's accounts.
collections.get("/", async (c) => {
  const sc = inClause(c.get("accountIds"));
  const rows = await c.env.DB.prepare(`${SELECT} WHERE c.account_id IN ${sc.sql} ORDER BY c.updated_at DESC`).bind(...sc.params).all<any>();
  return c.json(rows.results.map(map));
});

collections.post("/", async (c) => {
  const body = await c.req.json<{ name?: string; description?: string; account_id?: string }>().catch(() => ({}) as any);
  const name = (body.name ?? "").trim().slice(0, 120);
  if (!name) return c.json({ error: "name_required" }, 400);
  const accountId = await creationAccountId(c, body);
  if (!accountId) return c.json({ error: "invalid_account" }, 400);
  const id = uid();
  const t = now();
  await c.env.DB.prepare(`INSERT INTO collections (id, account_id, name, description, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)`)
    .bind(id, accountId, name, (body.description ?? "").slice(0, 2000), t, t)
    .run();
  return c.json(map({ id, account_id: accountId, name, description: body.description ?? "", created_at: t, updated_at: t }));
});

collections.get("/:id", async (c) => {
  const db = c.env.DB;
  const user = c.get("user");
  const row = await db.prepare(`${SELECT} JOIN accounts ac ON ac.id = c.account_id WHERE c.id = ? AND ac.user_id = ?`).bind(c.req.param("id"), user.id).first<any>();
  if (!row) return c.json({ error: "not_found" }, 404);
  const own = inClause(c.get("allAccountIds"));
  const threads = await db
    .prepare(`SELECT t.* FROM threads t JOIN collection_threads ct ON ct.thread_id = t.id WHERE ct.collection_id = ? AND t.account_id IN ${own.sql} ORDER BY ct.added_at DESC`)
    .bind(row.id, ...own.params)
    .all<ThreadRow>();
  const files = await db
    .prepare(
      `SELECT a.*, t.subject AS t_subject, t.custom_subject AS t_custom_subject, m.from_email, m.from_name FROM attachments a JOIN collection_threads ct ON ct.thread_id = a.thread_id JOIN threads t ON t.id = a.thread_id JOIN messages m ON m.id = a.message_id WHERE ct.collection_id = ? AND a.account_id IN ${own.sql} AND a.is_inline = 0 ORDER BY a.created_at DESC LIMIT 200`
    )
    .bind(row.id, ...own.params)
    .all<AttachmentRow & { t_subject: string; t_custom_subject: string | null; from_email: string; from_name: string }>();
  return c.json({
    collection: map(row),
    threads: await threadsWithLabels(db, threads.results),
    files: files.results.map((r) => toAttachment(r, { thread_subject: r.t_custom_subject ?? r.t_subject, from: { email: r.from_email, name: r.from_name } })),
  });
});

collections.patch("/:id", async (c) => {
  const db = c.env.DB;
  const row = await ownedRow<any>(db, "collections", c.req.param("id"), c.get("user").id);
  if (!row) return c.json({ error: "not_found" }, 404);
  const body = await c.req.json<{ name?: string; description?: string }>().catch(() => ({}) as any);
  const name = typeof body.name === "string" && body.name.trim() ? body.name.trim().slice(0, 120) : row.name;
  const description = typeof body.description === "string" ? body.description.slice(0, 2000) : row.description;
  await db.prepare(`UPDATE collections SET name = ?, description = ?, updated_at = ? WHERE id = ?`).bind(name, description, now(), row.id).run();
  const fresh = await db.prepare(`${SELECT} WHERE c.id = ?`).bind(row.id).first<any>();
  return c.json(map(fresh));
});

collections.delete("/:id", async (c) => {
  const row = await ownedRow<any>(c.env.DB, "collections", c.req.param("id"), c.get("user").id);
  if (!row) return c.json({ error: "not_found" }, 404);
  await c.env.DB.batch([
    c.env.DB.prepare(`DELETE FROM collection_threads WHERE collection_id = ?`).bind(row.id),
    c.env.DB.prepare(`DELETE FROM collections WHERE id = ?`).bind(row.id),
  ]);
  return c.json({ ok: true });
});

export default collections;
