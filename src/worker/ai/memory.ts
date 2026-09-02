// Assistant memory: small, transparent facts about the user, their tone, preferences and contacts.
import { z } from "zod";
import type { Env } from "../env";
import type { UserRow } from "../db";
import { uid, now } from "../db";
import { loadAiConfig, makeProvider } from "./provider";

export type MemoryKind = "profile" | "tone" | "fact" | "preference" | "contact";
export const MEMORY_KINDS: MemoryKind[] = ["profile", "tone", "fact", "preference", "contact"];

export interface MemoryRow {
  id: string;
  user_id: string;
  kind: MemoryKind;
  content: string;
  source: "user" | "assistant" | "learned";
  created_at: number;
  updated_at: number;
}

const MAX_ENTRIES = 80;

export async function listMemory(env: Env, userId: string): Promise<MemoryRow[]> {
  const r = await env.DB.prepare(`SELECT * FROM ai_memory WHERE user_id = ? ORDER BY kind, updated_at DESC`).bind(userId).all<MemoryRow>();
  return r.results;
}

export async function addMemory(env: Env, userId: string, kind: MemoryKind, content: string, source: MemoryRow["source"]): Promise<MemoryRow> {
  const t = now();
  const row: MemoryRow = { id: uid(), user_id: userId, kind: MEMORY_KINDS.includes(kind) ? kind : "fact", content: content.trim().slice(0, 600), source, created_at: t, updated_at: t };
  await env.DB.prepare(`INSERT INTO ai_memory (id, user_id, kind, content, source, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)`)
    .bind(row.id, row.user_id, row.kind, row.content, row.source, t, t)
    .run();
  await trimMemory(env, userId);
  return row;
}

export async function updateMemory(env: Env, userId: string, id: string, patch: { kind?: MemoryKind; content?: string }): Promise<MemoryRow | null> {
  const cur = await env.DB.prepare(`SELECT * FROM ai_memory WHERE id = ? AND user_id = ?`).bind(id, userId).first<MemoryRow>();
  if (!cur) return null;
  const kind = patch.kind && MEMORY_KINDS.includes(patch.kind) ? patch.kind : cur.kind;
  const content = typeof patch.content === "string" ? patch.content.trim().slice(0, 600) : cur.content;
  await env.DB.prepare(`UPDATE ai_memory SET kind = ?, content = ?, updated_at = ? WHERE id = ?`).bind(kind, content, now(), id).run();
  return { ...cur, kind, content, updated_at: now() };
}

export async function deleteMemory(env: Env, userId: string, id: string): Promise<boolean> {
  const r = await env.DB.prepare(`DELETE FROM ai_memory WHERE id = ? AND user_id = ?`).bind(id, userId).run();
  return (r.meta.changes ?? 0) > 0;
}

export async function clearMemory(env: Env, userId: string): Promise<void> {
  await env.DB.prepare(`DELETE FROM ai_memory WHERE user_id = ?`).bind(userId).run();
  await env.DB.prepare(`DELETE FROM ai_learning_state WHERE user_id = ?`).bind(userId).run();
}

async function trimMemory(env: Env, userId: string) {
  // Keep the newest MAX_ENTRIES; drop the oldest learned ones first.
  await env.DB.prepare(
    `DELETE FROM ai_memory WHERE user_id = ? AND id IN (
       SELECT id FROM ai_memory WHERE user_id = ? ORDER BY CASE source WHEN 'learned' THEN 0 ELSE 1 END, updated_at ASC
       LIMIT MAX(0, (SELECT COUNT(*) FROM ai_memory WHERE user_id = ?) - ?)
     )`
  )
    .bind(userId, userId, userId, MAX_ENTRIES)
    .run();
}

/** Render memory for a system prompt. */
export function memoryText(rows: MemoryRow[]): string {
  if (!rows.length) return "(nothing yet)";
  const byKind = new Map<string, MemoryRow[]>();
  for (const r of rows) byKind.set(r.kind, [...(byKind.get(r.kind) ?? []), r]);
  const label: Record<string, string> = { profile: "About the user", tone: "How the user writes", fact: "Facts", preference: "Preferences", contact: "People" };
  return MEMORY_KINDS.filter((k) => byKind.has(k))
    .map((k) => `${label[k]}:\n` + byKind.get(k)!.map((r) => `- [${r.id}] ${r.content}`).join("\n"))
    .join("\n\n");
}

/* ---------- Learning from sent mail ---------- */

const LearnedSchema = z.object({
  entries: z.array(
    z.object({
      id: z.string().nullable().describe("Existing memory id to update, or null for a new entry"),
      kind: z.enum(["profile", "tone", "fact", "preference", "contact"]),
      content: z.string().describe("One concise sentence. Concrete, reusable, no fluff."),
    })
  ),
  remove_ids: z.array(z.string()).describe("Ids of existing entries that are now wrong or redundant"),
});

interface SentSample {
  date: number;
  to: string;
  subject: string;
  text: string;
  in_reply_to_text: string;
}

async function gatherSentSamples(env: Env, userId: string, sinceDate: number, limit: number): Promise<SentSample[]> {
  const rows = await env.DB.prepare(
    `SELECT m.id, m.thread_id, m.date, m.to_json, m.subject, m.text_body FROM messages m
     WHERE m.account_id IN (SELECT id FROM accounts WHERE user_id = ?) AND m.is_from_me = 1 AND m.date > ?
     ORDER BY m.date DESC LIMIT ?`
  )
    .bind(userId, sinceDate, limit)
    .all<{ id: string; thread_id: string; date: number; to_json: string; subject: string; text_body: string }>();
  const out: SentSample[] = [];
  for (const r of rows.results) {
    const prev = await env.DB.prepare(`SELECT text_body FROM messages WHERE thread_id = ? AND is_from_me = 0 AND date < ? ORDER BY date DESC LIMIT 1`).bind(r.thread_id, r.date).first<{ text_body: string }>();
    let to = "";
    try {
      to = (JSON.parse(r.to_json) as { email: string; name?: string }[]).map((a) => a.name ? `${a.name} <${a.email}>` : a.email).join(", ");
    } catch {}
    out.push({ date: r.date, to, subject: r.subject, text: stripQuoted(r.text_body).slice(0, 2500), in_reply_to_text: (prev?.text_body ?? "").slice(0, 1200) });
  }
  return out;
}

function stripQuoted(text: string): string {
  // Drop quoted history ("On ... wrote:" and "> " lines).
  const lines = text.split("\n");
  const out: string[] = [];
  for (const l of lines) {
    if (/^On .{5,120} wrote:$/.test(l.trim()) || /^-{2,}\s*Original Message/i.test(l.trim())) break;
    if (l.trim().startsWith(">")) continue;
    out.push(l);
  }
  return out.join("\n").trim();
}

/** Update the memory from recent sent mail. Returns how many entries changed. */
export async function learnFromMail(env: Env, user: UserRow, opts: { force?: boolean } = {}): Promise<{ changed: number; skipped?: string }> {
  const cfg = await loadAiConfig(env, user.id);
  if (!cfg) return { changed: 0, skipped: "no_key" };
  if (!cfg.learn && !opts.force) return { changed: 0, skipped: "learning_off" };
  const state = await env.DB.prepare(`SELECT * FROM ai_learning_state WHERE user_id = ?`).bind(user.id).first<{ last_learned_at: number | null; last_sent_date: number }>();
  const since = opts.force ? 0 : state?.last_sent_date ?? 0;
  const samples = await gatherSentSamples(env, user.id, since, 40);
  if (!samples.length) return { changed: 0, skipped: "nothing_new" };
  const existing = await listMemory(env, user.id);
  const provider = makeProvider(cfg);
  const prompt = [
    `You maintain a small memory that helps an email assistant write like this user and act on their behalf.`,
    `User: ${user.name || "(no name)"} <${user.email}>.`,
    ``,
    `Current memory entries (id in brackets):`,
    memoryText(existing),
    ``,
    `Recent messages the user SENT (newest first). Each has the message they were replying to when available.`,
    ...samples.map((s, i) => `--- Sent #${i + 1} (${new Date(s.date).toISOString().slice(0, 10)}) to ${s.to}\nSubject: ${s.subject}\n${s.text}${s.in_reply_to_text ? `\n[Replying to:]\n${s.in_reply_to_text}` : ""}`),
    ``,
    `Produce the updated memory. Guidance:`,
    `- tone: greeting and sign-off habits, formality, typical length, punctuation quirks, phrases they reuse, how they say no, languages used.`,
    `- profile: role, company, projects, responsibilities, time zone if evident.`,
    `- fact: durable facts (accounts, tools they use, recurring commitments).`,
    `- preference: how they like things handled (e.g. "prefers short replies", "always CCs X on invoices").`,
    `- contact: one line per person that matters ("Rithesh — colleague at Acodez, handles design reviews").`,
    `Update existing entries by id when they should change; add new ones; list ids to remove when wrong or redundant. Keep the whole set under ${MAX_ENTRIES} entries. Never store secrets, codes, or one-off details.`,
  ].join("\n");
  const res = await provider.complete({ maxTokens: 6000, effort: "medium", schema: { name: "memory_update", zod: LearnedSchema }, messages: [{ role: "user", content: prompt }] });
  if (res.refused || !res.json) return { changed: 0, skipped: "no_output" };
  const parsed = res.json;
  let changed = 0;
  const known = new Set(existing.map((e) => e.id));
  for (const id of parsed.remove_ids) if (known.has(id)) { await deleteMemory(env, user.id, id); changed++; }
  for (const e of parsed.entries) {
    if (!e.content.trim()) continue;
    if (e.id && known.has(e.id)) {
      await updateMemory(env, user.id, e.id, { kind: e.kind, content: e.content });
    } else {
      await addMemory(env, user.id, e.kind, e.content, "learned");
    }
    changed++;
  }
  const newest = Math.max(...samples.map((s) => s.date));
  await env.DB.prepare(`INSERT INTO ai_learning_state (user_id, last_learned_at, last_sent_date) VALUES (?, ?, ?) ON CONFLICT(user_id) DO UPDATE SET last_learned_at = excluded.last_learned_at, last_sent_date = MAX(ai_learning_state.last_sent_date, excluded.last_sent_date)`)
    .bind(user.id, now(), newest)
    .run();
  return { changed };
}

/** Cron entry: learn for users who opted in, at most every 12h, only when there is new sent mail. */
export async function runLearning(env: Env): Promise<void> {
  const users = await env.DB.prepare(
    `SELECT u.* FROM users u JOIN ai_settings s ON s.user_id = u.id
     WHERE s.learn = 1 AND s.api_key_enc <> '' AND COALESCE((SELECT last_learned_at FROM ai_learning_state l WHERE l.user_id = u.id), 0) < ?`
  )
    .bind(now() - 12 * 3600_000)
    .all<UserRow>();
  for (const u of users.results) {
    try {
      await learnFromMail(env, u);
    } catch (e) {
      console.error("ai learning failed", u.email, (e as Error).message);
    }
  }
}
