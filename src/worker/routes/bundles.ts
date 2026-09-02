import { Hono, type Context } from "hono";
import type { AppEnv } from "../env";
import type { BundleRow, ThreadRow, MessageRow } from "../db";
import { now, chunk, placeholders, threadsWithLabels, toMessage, loadBundles, refreshBundle } from "../db";
import type { BundleDetail } from "@shared/types";

const bundles = new Hono<AppEnv>();

async function ownedBundle(c: Context<AppEnv>, id: string): Promise<BundleRow | null> {
  const all: string[] = c.get("allAccountIds") ?? [];
  if (!all.length) return null;
  const row = await c.env.DB.prepare(`SELECT * FROM bundles WHERE id = ? AND account_id IN (${placeholders(all.length)})`).bind(id, ...all).first<BundleRow>();
  return row ?? null;
}

/** A bundle read like The Feed: every thread in the batch, newest first, each with its latest message body. */
bundles.get("/:id", async (c) => {
  const db = c.env.DB;
  const b = await ownedBundle(c, c.req.param("id"));
  if (!b) return c.json({ error: "not_found" }, 404);
  const t = now();
  const bucketRow = await db.prepare(`SELECT bucket FROM threads WHERE bundle_id = ? ORDER BY last_message_at DESC LIMIT 1`).bind(b.id).first<{ bucket: "imbox" | "paper_trail" }>();
  const bucket = bucketRow?.bucket === "paper_trail" ? "paper_trail" : "imbox";
  const [summary] = (await loadBundles(db, [b.account_id], bucket, t)).filter((x) => x.id === b.id);
  const rows = await db.prepare(`SELECT t.* FROM threads t WHERE t.bundle_id = ? AND t.merged_into IS NULL ORDER BY t.last_message_at DESC LIMIT 300`).bind(b.id).all<ThreadRow>();
  const summaries = await threadsWithLabels(db, rows.results);
  const latest = new Map<string, MessageRow>();
  for (const ids of chunk(rows.results.map((r) => r.id), 90)) {
    const ms = await db
      .prepare(`SELECT m.* FROM messages m WHERE m.thread_id IN (${placeholders(ids.length)}) AND m.date = (SELECT MAX(date) FROM messages x WHERE x.thread_id = m.thread_id)`)
      .bind(...ids)
      .all<MessageRow>();
    for (const m of ms.results) latest.set(m.thread_id, m);
  }
  const threads = summaries.map((s) => {
    const m = latest.has(s.id) ? toMessage(latest.get(s.id)!) : null;
    if (m && m.from.email.toLowerCase() === s.last_from.email.toLowerCase() && s.last_from.avatar_url) m.from.avatar_url = s.last_from.avatar_url;
    return { ...s, latest_message: m };
  });
  const contact = await db.prepare(`SELECT name, avatar_url FROM contacts WHERE id = ?`).bind(b.contact_id).first<{ name: string; avatar_url: string }>();
  const out: BundleDetail = {
    bundle: summary ?? {
      id: b.id,
      contact_id: b.contact_id,
      account_id: b.account_id,
      email: b.email,
      name: contact?.name || threads[0]?.last_from.name || b.email,
      avatar_url: contact?.avatar_url || threads[0]?.last_from.avatar_url || "",
      status: b.status,
      thread_count: threads.length,
      message_count: threads.reduce((n, x) => n + x.message_count, 0),
      latest: threads[0],
      first_message_at: b.first_message_at,
      last_message_at: b.last_message_at,
    },
    threads,
  };
  return c.json(out);
});

/** Mark seen = close the batch. The next mail from this sender starts a new bundle. */
bundles.post("/:id/seen", async (c) => {
  const db = c.env.DB;
  const b = await ownedBundle(c, c.req.param("id"));
  if (!b) return c.json({ error: "not_found" }, 404);
  const t = now();
  await db.batch([
    db.prepare(`UPDATE bundles SET status = 'seen', seen_at = ? WHERE id = ?`).bind(t, b.id),
    db.prepare(`UPDATE threads SET seen = 1, unread = 0, bubbled = 0, updated_at = ? WHERE bundle_id = ?`).bind(t, b.id),
    db.prepare(`UPDATE messages SET unread = 0 WHERE thread_id IN (SELECT id FROM threads WHERE bundle_id = ?)`).bind(b.id),
  ]);
  // Best-effort: clear Gmail's UNREAD label for the bundle's messages.
  c.executionCtx.waitUntil(
    (async () => {
      try {
        const acc = await db.prepare(`SELECT * FROM accounts WHERE id = ?`).bind(b.account_id).first<any>();
        if (!acc || acc.provider !== "gmail") return;
        const ids = await db.prepare(`SELECT gmail_message_id FROM messages WHERE thread_id IN (SELECT id FROM threads WHERE bundle_id = ?) AND is_from_me = 0`).bind(b.id).all<{ gmail_message_id: string }>();
        if (!ids.results.length) return;
        const { gmailPost } = await import("../google");
        await gmailPost(c.env, acc, "messages/batchModify", { ids: ids.results.map((r) => r.gmail_message_id), removeLabelIds: ["UNREAD"] });
      } catch {
        /* ignore */
      }
    })()
  );
  return c.json({ ok: true, status: "seen" });
});

/** Reopen a seen bundle ("mark unread"). */
bundles.post("/:id/unseen", async (c) => {
  const db = c.env.DB;
  const b = await ownedBundle(c, c.req.param("id"));
  if (!b) return c.json({ error: "not_found" }, 404);
  const t = now();
  // Only one open bundle per sender+account: fold any currently open one into this bundle first.
  const open = await db.prepare(`SELECT id FROM bundles WHERE account_id = ? AND email = ? AND status = 'open' AND id <> ?`).bind(b.account_id, b.email, b.id).first<{ id: string }>();
  const stmts = [
    db.prepare(`UPDATE bundles SET status = 'open', seen_at = NULL WHERE id = ?`).bind(b.id),
    db.prepare(`UPDATE threads SET seen = 0, updated_at = ? WHERE bundle_id = ?`).bind(t, b.id),
  ];
  if (open) {
    stmts.push(db.prepare(`UPDATE threads SET bundle_id = ?, updated_at = ? WHERE bundle_id = ?`).bind(b.id, t, open.id));
    stmts.push(db.prepare(`DELETE FROM bundles WHERE id = ?`).bind(open.id));
  }
  await db.batch(stmts);
  await refreshBundle(db, b.id);
  return c.json({ ok: true, status: "open" });
});

/** Dissolve: the threads go back to being separate rows. */
bundles.delete("/:id", async (c) => {
  const db = c.env.DB;
  const b = await ownedBundle(c, c.req.param("id"));
  if (!b) return c.json({ error: "not_found" }, 404);
  const t = now();
  await db.batch([
    db.prepare(`UPDATE threads SET bundle_id = NULL, updated_at = ? WHERE bundle_id = ?`).bind(t, b.id),
    db.prepare(`DELETE FROM bundles WHERE id = ?`).bind(b.id),
  ]);
  return c.json({ ok: true });
});

export default bundles;
