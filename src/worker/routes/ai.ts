import { Hono } from "hono";
import type { AppEnv } from "../env";
import type { AccountRow, ThreadRow } from "../db";
import { uid, now, accountForThread } from "../db";
import { encryptSecret } from "../ai/crypto";
import { PRESETS, presetById, loadAiSettings, loadAiConfig, makeProvider, describeApiError, AiNotConfigured } from "../ai/provider";
import { listMemory, addMemory, updateMemory, deleteMemory, clearMemory, learnFromMail, type MemoryKind } from "../ai/memory";
import { runChatTurn, generateReply, summarizeThread, threadToText, type ChatDeps, type ReplyTone, type SseEvent } from "../ai/chat";
import { loadThreadDetail } from "./mail";

const ai = new Hono<AppEnv>();

async function userAccounts(c: any): Promise<AccountRow[]> {
  const r = await c.env.DB.prepare(`SELECT * FROM accounts WHERE user_id = ? ORDER BY created_at ASC`).bind(c.get("user").id).all();
  return r.results as AccountRow[];
}

async function deps(c: any): Promise<ChatDeps> {
  const user = c.get("user");
  const cfg = await loadAiConfig(c.env, user.id);
  if (!cfg) throw new AiNotConfigured();
  return { env: c.env, user, accounts: await userAccounts(c), cfg };
}

function shimFor(c: any, accounts: AccountRow[], acc: AccountRow | null) {
  const ids = accounts.map((a) => a.id);
  const vars: Record<string, unknown> = { user: c.get("user"), accountIds: ids, allAccountIds: ids, account: acc ?? accounts[0] ?? null };
  return { env: c.env, get: (k: string) => vars[k], req: { param: () => undefined, query: (k: string) => (k === "peek" ? "1" : undefined), json: async () => ({}) }, executionCtx: { waitUntil() {} } } as any;
}

/* ---------- settings ---------- */

ai.get("/settings", async (c) => {
  const user = c.get("user");
  const row = await loadAiSettings(c.env, user.id);
  const state = await c.env.DB.prepare(`SELECT last_learned_at FROM ai_learning_state WHERE user_id = ?`).bind(user.id).first<{ last_learned_at: number | null }>();
  const preset = presetById(row?.preset ?? "anthropic");
  const configured = !!row && (preset.kind === "anthropic" ? !!row.api_key_enc : preset.id === "custom" ? !!row.base_url : true);
  return c.json({
    configured,
    provider: preset.kind,
    preset: preset.id,
    base_url: preset.id === "custom" ? row?.base_url ?? "" : preset.base_url,
    key_hint: row?.key_hint ?? "",
    model: row?.model || preset.default_model,
    learn: row ? !!row.learn : true,
    auto_send: row ? !!row.auto_send : false,
    presets: PRESETS,
    last_learned_at: state?.last_learned_at ?? null,
    server_ready: !!c.env.SESSION_SECRET,
  });
});

ai.put("/settings", async (c) => {
  const user = c.get("user");
  const b = await c.req.json<{ preset?: string; base_url?: string; api_key?: string | null; model?: string; learn?: boolean; auto_send?: boolean }>().catch(() => ({}) as any);
  const cur = await loadAiSettings(c.env, user.id);
  const preset = presetById(typeof b.preset === "string" ? b.preset : cur?.preset ?? "anthropic");
  let enc = cur?.api_key_enc ?? "";
  let hint = cur?.key_hint ?? "";
  if (typeof b.api_key === "string") {
    const key = b.api_key.trim();
    if (key) {
      if (key.length < 8) return c.json({ error: "invalid_key" }, 400);
      try {
        enc = await encryptSecret(c.env.SESSION_SECRET, key);
      } catch (e) {
        return c.json({ error: (e as Error).message }, 500);
      }
      hint = key.length > 12 ? `${key.slice(0, 6)}…${key.slice(-4)}` : "••••";
    }
  } else if (b.api_key === null) {
    enc = "";
    hint = "";
  }
  let baseUrl = cur?.base_url ?? "";
  if (typeof b.base_url === "string") {
    baseUrl = b.base_url.trim().replace(/\/+$/, "");
    if (baseUrl && !/^https?:\/\//i.test(baseUrl)) return c.json({ error: "base_url_must_be_http" }, 400);
  }
  const model = (typeof b.model === "string" ? b.model.trim().slice(0, 120) : cur?.model) || preset.default_model;
  const learn = typeof b.learn === "boolean" ? (b.learn ? 1 : 0) : cur?.learn ?? 1;
  const autoSend = typeof b.auto_send === "boolean" ? (b.auto_send ? 1 : 0) : cur?.auto_send ?? 0;
  await c.env.DB.prepare(
    `INSERT INTO ai_settings (user_id, provider, preset, base_url, api_key_enc, key_hint, model, learn, auto_send, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(user_id) DO UPDATE SET provider = excluded.provider, preset = excluded.preset, base_url = excluded.base_url, api_key_enc = excluded.api_key_enc, key_hint = excluded.key_hint, model = excluded.model, learn = excluded.learn, auto_send = excluded.auto_send, updated_at = excluded.updated_at`
  )
    .bind(user.id, preset.kind, preset.id, baseUrl, enc, hint, model, learn, autoSend, now())
    .run();
  return c.json({ ok: true, provider: preset.kind, preset: preset.id, key_hint: hint, model, learn: !!learn, auto_send: !!autoSend });
});

ai.post("/settings/test", async (c) => {
  try {
    const d = await deps(c);
    const provider = makeProvider(d.cfg);
    const r = await provider.complete({ maxTokens: 20, effort: "low", messages: [{ role: "user", content: "Reply with the single word: ready" }] });
    return c.json({ ok: true, model: d.cfg.model, reply: r.text.trim().slice(0, 40) });
  } catch (e) {
    return c.json({ ok: false, error: describeApiError(e) }, 400);
  }
});

/* ---------- memory ---------- */

ai.get("/memory", async (c) => c.json(await listMemory(c.env, c.get("user").id)));
ai.post("/memory", async (c) => {
  const b = await c.req.json<{ kind?: MemoryKind; content?: string }>().catch(() => ({}) as any);
  if (!b.content?.trim()) return c.json({ error: "content_required" }, 400);
  return c.json(await addMemory(c.env, c.get("user").id, b.kind ?? "fact", b.content, "user"));
});
ai.patch("/memory/:id", async (c) => {
  const b = await c.req.json<{ kind?: MemoryKind; content?: string }>().catch(() => ({}) as any);
  const row = await updateMemory(c.env, c.get("user").id, c.req.param("id"), b);
  return row ? c.json(row) : c.json({ error: "not_found" }, 404);
});
ai.delete("/memory/:id", async (c) => c.json({ ok: await deleteMemory(c.env, c.get("user").id, c.req.param("id")) }));
ai.delete("/memory", async (c) => {
  await clearMemory(c.env, c.get("user").id);
  return c.json({ ok: true });
});
ai.post("/learn", async (c) => {
  try {
    const r = await learnFromMail(c.env, c.get("user"), { force: true });
    return c.json(r);
  } catch (e) {
    return c.json({ error: describeApiError(e) }, 400);
  }
});

/* ---------- conversations ---------- */

ai.get("/conversations", async (c) => {
  const r = await c.env.DB.prepare(`SELECT id, title, created_at, updated_at FROM ai_conversations WHERE user_id = ? ORDER BY updated_at DESC LIMIT 100`).bind(c.get("user").id).all();
  return c.json(r.results);
});
ai.post("/conversations", async (c) => {
  const id = uid();
  const t = now();
  await c.env.DB.prepare(`INSERT INTO ai_conversations (id, user_id, title, created_at, updated_at) VALUES (?, ?, '', ?, ?)`).bind(id, c.get("user").id, t, t).run();
  return c.json({ id, title: "", created_at: t, updated_at: t });
});
ai.get("/conversations/:id", async (c) => {
  const conv = await c.env.DB.prepare(`SELECT id, title, created_at, updated_at FROM ai_conversations WHERE id = ? AND user_id = ?`).bind(c.req.param("id"), c.get("user").id).first();
  if (!conv) return c.json({ error: "not_found" }, 404);
  const msgs = await c.env.DB.prepare(`SELECT id, role, content_json, created_at FROM ai_messages WHERE conversation_id = ? ORDER BY created_at ASC`).bind(c.req.param("id")).all<{ id: string; role: string; content_json: string; created_at: number }>();
  return c.json({ conversation: conv, messages: msgs.results.map((m) => ({ id: m.id, role: m.role, content: JSON.parse(m.content_json), created_at: m.created_at })) });
});
ai.patch("/conversations/:id", async (c) => {
  const b = await c.req.json<{ title?: string }>().catch(() => ({}) as any);
  await c.env.DB.prepare(`UPDATE ai_conversations SET title = ?, updated_at = ? WHERE id = ? AND user_id = ?`).bind(String(b.title ?? "").slice(0, 120), now(), c.req.param("id"), c.get("user").id).run();
  return c.json({ ok: true });
});
ai.delete("/conversations/:id", async (c) => {
  await c.env.DB.prepare(`DELETE FROM ai_conversations WHERE id = ? AND user_id = ?`).bind(c.req.param("id"), c.get("user").id).run();
  return c.json({ ok: true });
});

/* ---------- chat (SSE) ---------- */

ai.post("/chat", async (c) => {
  const b = await c.req.json<{ conversation_id?: string; message?: string; context_thread_ids?: string[] }>().catch(() => ({}) as any);
  const text = String(b.message ?? "").trim().slice(0, 20_000);
  if (!text) return c.json({ error: "message_required" }, 400);
  let d: ChatDeps;
  try {
    d = await deps(c);
  } catch (e) {
    return c.json({ error: describeApiError(e), code: "ai_not_configured" }, 400);
  }
  // Attached threads → compact context blocks (subject, participants, last 3 messages), max 3 threads.
  const contextBlocks: string[] = [];
  const ctxIds: string[] = Array.isArray(b.context_thread_ids) ? (b.context_thread_ids as unknown[]).filter((x): x is string => typeof x === "string").slice(0, 3) : [];
  for (const tid of ctxIds) {
    const t = await threadForAi(c, d, tid).catch(() => null);
    if (!t) continue;
    const people = t.detail.participants.map((p) => (p.name ? `${p.name} <${p.email}>` : p.email)).join(", ");
    const lastFrom = t.detail.last_from.name || t.detail.last_from.email;
    const body = threadToText(t.detail.messages.slice(-3), 2000, 3);
    contextBlocks.push(`[[context thread=${tid}]] Subject: ${t.detail.subject || "(no subject)"} · From: ${lastFrom}\nParticipants: ${people}\nAccount: ${t.acc.email}\n\n${body}`);
  }
  let convId = typeof b.conversation_id === "string" ? b.conversation_id : "";
  if (convId) {
    const own = await c.env.DB.prepare(`SELECT id FROM ai_conversations WHERE id = ? AND user_id = ?`).bind(convId, d.user.id).first();
    if (!own) convId = "";
  }
  if (!convId) {
    convId = uid();
    await c.env.DB.prepare(`INSERT INTO ai_conversations (id, user_id, title, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`).bind(convId, d.user.id, text.slice(0, 60), now(), now()).run();
  } else {
    await c.env.DB.prepare(`UPDATE ai_conversations SET title = CASE WHEN title = '' THEN ? ELSE title END WHERE id = ?`).bind(text.slice(0, 60), convId).run();
  }

  const { readable, writable } = new TransformStream<Uint8Array>();
  const writer = writable.getWriter();
  const encoder = new TextEncoder();
  let closed = false;
  const send = async (e: SseEvent) => {
    if (closed) return;
    try {
      await writer.write(encoder.encode(`data: ${JSON.stringify(e)}\n\n`));
    } catch {
      closed = true;
    }
  };
  const abort = new AbortController();
  c.req.raw.signal?.addEventListener("abort", () => abort.abort());
  const run = (async () => {
    await send({ type: "start", conversation_id: convId });
    await runChatTurn(d, convId, text, send, abort.signal, contextBlocks);
    closed = true;
    try {
      await writer.close();
    } catch {}
  })();
  c.executionCtx.waitUntil(run);
  return new Response(readable, { headers: { "content-type": "text/event-stream; charset=utf-8", "cache-control": "no-cache, no-transform", "x-accel-buffering": "no", "x-conversation-id": convId } });
});

/* ---------- reply / summarize ---------- */

async function threadForAi(c: any, d: ChatDeps, threadId: string) {
  const acc = await accountForThread(c.env.DB, d.user.id, threadId);
  if (!acc) return null;
  const detail = await loadThreadDetail(shimFor(c, d.accounts, acc), threadId);
  if (!detail) return null;
  return { acc, detail };
}

ai.post("/reply", async (c) => {
  const b = await c.req.json<{ thread_id?: string; brief?: string; tone?: ReplyTone }>().catch(() => ({}) as any);
  const brief = String(b.brief ?? "").trim().slice(0, 2000);
  if (!b.thread_id || !brief) return c.json({ error: "thread_id and brief are required" }, 400);
  try {
    const d = await deps(c);
    const t = await threadForAi(c, d, b.thread_id);
    if (!t) return c.json({ error: "not_found" }, 404);
    const last = [...t.detail.messages].reverse().find((m) => !m.is_from_me) ?? t.detail.messages[t.detail.messages.length - 1];
    const tone: ReplyTone = ["match", "formal", "friendly", "brief"].includes(String(b.tone)) ? (b.tone as ReplyTone) : "match";
    const r = await generateReply(d, threadToText(t.detail.messages), brief, tone, { subject: t.detail.subject, to: last ? `${last.from.name} <${last.from.email}>` : "", myEmail: t.acc.email });
    return c.json({ ...r, reply_to_message_id: last?.id ?? null });
  } catch (e) {
    return c.json({ error: describeApiError(e) }, e instanceof AiNotConfigured ? 400 : 502);
  }
});

ai.post("/summarize", async (c) => {
  const b = await c.req.json<{ thread_id?: string }>().catch(() => ({}) as any);
  if (!b.thread_id) return c.json({ error: "thread_id required" }, 400);
  try {
    const d = await deps(c);
    const t = await threadForAi(c, d, b.thread_id);
    if (!t) return c.json({ error: "not_found" }, 404);
    const summary = await summarizeThread(d, threadToText(t.detail.messages), t.detail.subject);
    return c.json({ summary });
  } catch (e) {
    return c.json({ error: describeApiError(e) }, e instanceof AiNotConfigured ? 400 : 502);
  }
});

export default ai;
export type { ThreadRow };
