// The assistant: system prompt, SSE streaming chat with a manual tool loop.
import type Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import type { Env } from "../env";
import type { AccountRow, UserRow } from "../db";
import { uid, now } from "../db";
import { listMemory, memoryText } from "./memory";
import { TOOLS, runTool, type ToolContext } from "./tools";
import { type AiConfig, makeProvider, describeApiError } from "./provider";
import { htmlToText } from "../sanitize";

const MAX_ITERATIONS = 12;

export interface ChatDeps {
  env: Env;
  user: UserRow;
  accounts: AccountRow[];
  cfg: AiConfig;
}

export async function buildSystemPrompt(d: ChatDeps): Promise<string> {
  const memory = memoryText(await listMemory(d.env, d.user.id));
  const accounts = d.accounts.map((a) => `- ${a.email} (${a.provider === "gmail" ? "Gmail" : a.provider === "outlook" ? "Outlook" : "domain mailbox"}, id ${a.id})`).join("\n") || "- none connected yet";
  return [
    `You are the assistant inside heyflare, a HEY-style email client. You help ${d.user.name || d.user.email} read, triage, organise, and write email.`,
    ``,
    `Connected accounts:`,
    accounts,
    ``,
    `What you remember about the user:`,
    memory,
    ``,
    `House rules:`,
    `- Use tools to look things up instead of guessing. Read a thread before summarising or replying to it.`,
    `- Draft mail with create_draft, written in the user's own voice (see memory: tone). ${d.cfg.autoSend ? "You may send with send_draft when the user clearly asked you to send." : "Never send: the user reviews every draft and presses Send themselves. Say that the draft is ready."}`,
    `- Screener decisions are reversible; act when asked, otherwise recommend.`,
    `- Be brief and concrete. Plain prose, short lists when listing mail. Refer to threads by subject and sender, never by id.`,
    `- When you learn something durable about the user (a preference, a fact, how they like to write), store it with remember. Don't store secrets or one-off details.`,
    `- Today is ${new Date().toISOString().slice(0, 10)} (UTC).`,
  ].join("\n");
}

export type SseEvent = { type: "start"; conversation_id: string } | { type: "text"; text: string } | { type: "tool"; name: string; status: "running" | "done" | "error"; summary: string; id: string } | { type: "draft"; draft: unknown } | { type: "sent"; draft_id: string; thread_id: string } | { type: "done"; conversation_id: string } | { type: "error"; message: string };

/** Runs one user turn; streams SSE events through `send`, persists messages, returns when finished. */
export async function runChatTurn(d: ChatDeps, conversationId: string, userText: string, send: (e: SseEvent) => Promise<void>, signal?: AbortSignal, contextBlocks: string[] = []): Promise<void> {
  const db = d.env.DB;
  const system = await buildSystemPrompt(d);
  // History from the DB (full content blocks so tool_use / tool_result pairs round-trip).
  const hist = await db.prepare(`SELECT role, content_json FROM ai_messages WHERE conversation_id = ? ORDER BY created_at ASC LIMIT 200`).bind(conversationId).all<{ role: "user" | "assistant"; content_json: string }>();
  const messages: Anthropic.MessageParam[] = hist.results.map((r) => ({ role: r.role, content: JSON.parse(r.content_json) }));
  // Context blocks (threads the user attached) go first, clearly labelled, then the user's own words.
  const userBlock: Anthropic.MessageParam = { role: "user", content: [...contextBlocks.map((text) => ({ type: "text" as const, text })), { type: "text", text: userText }] };
  messages.push(userBlock);
  await db.prepare(`INSERT INTO ai_messages (id, conversation_id, role, content_json, created_at) VALUES (?, ?, 'user', ?, ?)`).bind(uid(), conversationId, JSON.stringify(userBlock.content), now()).run();

  const ctx: ToolContext = {
    env: d.env,
    user: { id: d.user.id, email: d.user.email, name: d.user.name },
    accounts: d.accounts,
    autoSend: d.cfg.autoSend,
    emit: (e) => void send(e as SseEvent),
  };

  const provider = makeProvider(d.cfg);
  try {
    for (let i = 0; i < MAX_ITERATIONS; i++) {
      if (signal?.aborted) break;
      let final: { stop: "end" | "tool_use" | "refusal" | "max_tokens"; content: Anthropic.ContentBlock[] } | null = null;
      let failed = false;
      for await (const ev of provider.stream({ system, messages, tools: TOOLS, maxTokens: 8000, effort: "medium", signal })) {
        if (ev.type === "text") await send({ type: "text", text: ev.text });
        else if (ev.type === "error") {
          await send({ type: "error", message: ev.message });
          failed = true;
          break;
        } else final = { stop: ev.stop, content: ev.content };
      }
      if (failed || !final) break;
      if (final.content.length) {
        messages.push({ role: "assistant", content: final.content });
        await db.prepare(`INSERT INTO ai_messages (id, conversation_id, role, content_json, created_at) VALUES (?, ?, 'assistant', ?, ?)`).bind(uid(), conversationId, JSON.stringify(final.content), now()).run();
      }
      if (final.stop === "refusal") {
        await send({ type: "error", message: "The model declined this request." });
        break;
      }
      if (final.stop !== "tool_use") break;

      const uses = final.content.filter((b): b is Anthropic.ToolUseBlock => b.type === "tool_use");
      const results: Anthropic.ToolResultBlockParam[] = [];
      for (const u of uses) {
        await send({ type: "tool", id: u.id, name: u.name, status: "running", summary: labelFor(u.name) });
        let r: { result: string; summary: string; isError?: boolean };
        try {
          r = await runTool(ctx, u.name, u.input);
        } catch (e) {
          r = { result: JSON.stringify({ error: (e as Error).message }), summary: `${labelFor(u.name)} failed`, isError: true };
        }
        await send({ type: "tool", id: u.id, name: u.name, status: r.isError ? "error" : "done", summary: r.summary });
        results.push({ type: "tool_result", tool_use_id: u.id, content: r.result, is_error: r.isError || undefined });
      }
      const resultMsg: Anthropic.MessageParam = { role: "user", content: results };
      messages.push(resultMsg);
      await db.prepare(`INSERT INTO ai_messages (id, conversation_id, role, content_json, created_at) VALUES (?, ?, 'user', ?, ?)`).bind(uid(), conversationId, JSON.stringify(results), now()).run();
    }
  } catch (e) {
    if (!(signal?.aborted)) await send({ type: "error", message: describeApiError(e) });
  }
  await db.prepare(`UPDATE ai_conversations SET updated_at = ? WHERE id = ?`).bind(now(), conversationId).run();
  await send({ type: "done", conversation_id: conversationId });
}

function labelFor(tool: string): string {
  const map: Record<string, string> = {
    search_mail: "Searching mail", list_threads: "Listing threads", read_thread: "Reading thread", list_screener: "Checking the Screener", screen_sender: "Screening sender",
    thread_action: "Organising", list_labels: "Listing labels", list_collections: "Listing collections", create_collection: "Creating collection", add_to_collection: "Adding to collection",
    save_clip: "Saving clip", find_contact: "Looking up contact", create_draft: "Writing draft", send_draft: "Sending", list_memory: "Recalling memory", remember: "Remembering", forget: "Forgetting",
  };
  return map[tool] ?? tool;
}

/* ---------- Reply with AI ---------- */

const ReplySchema = z.object({
  subject: z.string().nullable().describe("Only if the subject should change; null otherwise"),
  body_text: z.string().describe("The reply text: greeting, body paragraphs separated by blank lines, sign-off. No subject line, no quoted history."),
});

export type ReplyTone = "match" | "formal" | "friendly" | "brief";

export async function generateReply(d: ChatDeps, threadText: string, brief: string, tone: ReplyTone, extra: { subject: string; to: string; myEmail: string }): Promise<{ subject: string | null; body_text: string; body_html: string }> {
  const provider = makeProvider(d.cfg);
  const memory = memoryText(await listMemory(d.env, d.user.id));
  const toneLine = tone === "formal" ? "Write formally and precisely." : tone === "friendly" ? "Write warmly and casually." : tone === "brief" ? "Keep it to a few sentences." : "Match the user's own voice from the memory notes (greeting, sign-off, length, phrasing).";
  const res = await provider.complete({
    maxTokens: 4000,
    effort: "medium",
    schema: { name: "email_reply", zod: ReplySchema },
    system: `You write email replies on behalf of ${d.user.name || d.user.email} (${extra.myEmail}). ${toneLine}\n\nWhat you know about them:\n${memory}\n\nRules: reply to the latest message, answer what was asked, don't invent facts or commitments the user didn't state, no placeholders like [name], no quoted history, sign off the way they usually do.`,
    messages: [{ role: "user", content: `Thread (oldest first):\n${threadText}\n\nReplying to: ${extra.to}\nSubject: ${extra.subject}\n\nWhat the user wants to say: ${brief}` }],
  });
  if (res.refused) throw new Error("The model declined to write this reply.");
  const p = res.json ?? (res.text ? { subject: null, body_text: res.text } : null);
  if (!p) throw new Error("The model returned nothing usable.");
  return { subject: p.subject ?? null, body_text: p.body_text, body_html: textToHtml(p.body_text) };
}

export async function summarizeThread(d: ChatDeps, threadText: string, subject: string): Promise<string> {
  const provider = makeProvider(d.cfg);
  const res = await provider.complete({
    maxTokens: 1200,
    effort: "low",
    messages: [{ role: "user", content: `Summarise this email thread for ${d.user.name || d.user.email}. Use 3–6 short bullet points: what it's about, decisions, open questions, and anything they need to do (with dates). Plain text bullets starting with "- ".\n\nSubject: ${subject}\n\n${threadText}` }],
  });
  if (res.refused) throw new Error("The model declined to summarise this thread.");
  return res.text.trim();
}

export function textToHtml(text: string): string {
  const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return text.trim().split(/\n{2,}/).map((p) => `<p>${esc(p).replace(/\n/g, "<br>")}</p>`).join("");
}

/** Render a thread as plain text for the model, newest last, bodies trimmed. */
export function threadToText(messages: { from: { name: string; email: string }; date: number; text_body: string; html_body: string; is_from_me: boolean }[], maxPer = 6000, maxMessages = 20): string {
  const slice = messages.slice(Math.max(0, messages.length - maxMessages));
  return slice
    .map((m) => {
      let text = (m.text_body || htmlToText(m.html_body || "")).trim();
      if (text.length > maxPer) text = text.slice(0, maxPer) + " …[truncated]";
      return `From: ${m.from.name ? `${m.from.name} <${m.from.email}>` : m.from.email}${m.is_from_me ? " (the user)" : ""}\nDate: ${new Date(m.date).toISOString()}\n\n${text}`;
    })
    .join("\n\n-----\n\n");
}
