import { Hono, type Context } from "hono";
import type { AppEnv } from "../env";
import type { LabelRow, ThreadRow } from "../db";
import { uid, now, toLabel, threadsWithLabels, inClause, ownedRow, ownedAccount } from "../db";

const labels = new Hono<AppEnv>();

/** Account a new object is created under: body.account_id (must be owned) → thread's account → primary. */
export async function creationAccountId(c: Context<AppEnv>, body: { account_id?: unknown; thread_id?: unknown }): Promise<string | null> {
  const db = c.env.DB;
  const user = c.get("user");
  if (typeof body.account_id === "string" && body.account_id) {
    const a = await ownedAccount(db, user.id, body.account_id);
    return a ? a.id : null;
  }
  if (typeof body.thread_id === "string" && body.thread_id) {
    const t = await ownedRow<ThreadRow>(db, "threads", body.thread_id, user.id);
    if (t) return t.account_id;
  }
  return c.get("account")?.id ?? null;
}

// Labels belong to one account for storage but may be applied to any of the user's threads.
labels.get("/", async (c) => {
  const sc = inClause(c.get("accountIds"));
  const rows = await c.env.DB.prepare(`SELECT * FROM labels WHERE account_id IN ${sc.sql} ORDER BY name`).bind(...sc.params).all<LabelRow>();
  return c.json(rows.results.map(toLabel));
});

labels.post("/", async (c) => {
  const body = await c.req.json<{ name?: string; color?: string; account_id?: string }>().catch(() => ({}) as any);
  const name = (body.name ?? "").trim().slice(0, 60);
  if (!name) return c.json({ error: "name_required" }, 400);
  const accountId = await creationAccountId(c, body);
  if (!accountId) return c.json({ error: "invalid_account" }, 400);
  const color = /^#[0-9a-fA-F]{6}$/.test(body.color ?? "") ? body.color! : "#0f766e";
  const id = uid();
  try {
    await c.env.DB.prepare(`INSERT INTO labels (id, account_id, name, color, created_at) VALUES (?, ?, ?, ?, ?)`).bind(id, accountId, name, color, now()).run();
  } catch {
    return c.json({ error: "label_exists" }, 409);
  }
  return c.json({ id, account_id: accountId, name, color });
});

labels.patch("/:id", async (c) => {
  const row = await ownedRow<LabelRow>(c.env.DB, "labels", c.req.param("id"), c.get("user").id);
  if (!row) return c.json({ error: "not_found" }, 404);
  const body = await c.req.json<{ name?: string; color?: string }>().catch(() => ({}) as any);
  const name = typeof body.name === "string" && body.name.trim() ? body.name.trim().slice(0, 60) : row.name;
  const color = /^#[0-9a-fA-F]{6}$/.test(body.color ?? "") ? body.color! : row.color;
  await c.env.DB.prepare(`UPDATE labels SET name = ?, color = ? WHERE id = ?`).bind(name, color, row.id).run();
  return c.json({ id: row.id, account_id: row.account_id, name, color });
});

labels.delete("/:id", async (c) => {
  const row = await ownedRow<LabelRow>(c.env.DB, "labels", c.req.param("id"), c.get("user").id);
  if (!row) return c.json({ error: "not_found" }, 404);
  await c.env.DB.batch([
    c.env.DB.prepare(`DELETE FROM thread_labels WHERE label_id = ?`).bind(row.id),
    c.env.DB.prepare(`DELETE FROM labels WHERE id = ?`).bind(row.id),
  ]);
  return c.json({ ok: true });
});

labels.get("/:id/threads", async (c) => {
  const row = await ownedRow<LabelRow>(c.env.DB, "labels", c.req.param("id"), c.get("user").id);
  if (!row) return c.json({ error: "not_found" }, 404);
  const sc = inClause(c.get("accountIds"));
  const rows = await c.env.DB.prepare(
    `SELECT t.* FROM threads t JOIN thread_labels tl ON tl.thread_id = t.id WHERE t.account_id IN ${sc.sql} AND tl.label_id = ? AND t.merged_into IS NULL ORDER BY t.last_message_at DESC LIMIT 200`
  )
    .bind(...sc.params, row.id)
    .all<ThreadRow>();
  return c.json({ threads: await threadsWithLabels(c.env.DB, rows.results) });
});

export default labels;
