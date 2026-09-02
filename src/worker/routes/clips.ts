import { Hono } from "hono";
import type { AppEnv } from "../env";
import type { ThreadRow } from "../db";
import { uid, now, inClause, ownedRow } from "../db";
import type { Clip } from "@shared/types";

const clips = new Hono<AppEnv>();

function mapClip(r: any): Clip {
  return { id: r.id, account_id: r.account_id, thread_id: r.thread_id, message_id: r.message_id, text: r.text, created_at: r.created_at, thread_subject: r.thread_subject };
}

clips.get("/", async (c) => {
  const sc = inClause(c.get("accountIds"));
  const rows = await c.env.DB.prepare(
    `SELECT k.*, COALESCE(t.custom_subject, t.subject) AS thread_subject FROM clips k JOIN threads t ON t.id = k.thread_id WHERE k.account_id IN ${sc.sql} ORDER BY k.created_at DESC LIMIT 500`
  )
    .bind(...sc.params)
    .all<any>();
  return c.json(rows.results.map(mapClip));
});

// A clip always lives under its thread's account.
clips.post("/", async (c) => {
  const body = await c.req.json<{ thread_id?: string; message_id?: string; text?: string }>().catch(() => ({}) as any);
  const text = (body.text ?? "").trim().slice(0, 5000);
  if (!text || !body.thread_id) return c.json({ error: "invalid" }, 400);
  const th = await ownedRow<ThreadRow>(c.env.DB, "threads", body.thread_id, c.get("user").id);
  if (!th) return c.json({ error: "not_found" }, 404);
  const id = uid();
  const t = now();
  await c.env.DB.prepare(`INSERT INTO clips (id, account_id, thread_id, message_id, text, created_at) VALUES (?, ?, ?, ?, ?, ?)`)
    .bind(id, th.account_id, th.id, body.message_id ?? null, text, t)
    .run();
  return c.json(mapClip({ id, account_id: th.account_id, thread_id: th.id, message_id: body.message_id ?? null, text, created_at: t, thread_subject: th.custom_subject ?? th.subject }));
});

clips.delete("/:id", async (c) => {
  const row = await ownedRow<any>(c.env.DB, "clips", c.req.param("id"), c.get("user").id);
  if (!row) return c.json({ error: "not_found" }, 404);
  await c.env.DB.prepare(`DELETE FROM clips WHERE id = ?`).bind(row.id).run();
  return c.json({ ok: true });
});

export default clips;
