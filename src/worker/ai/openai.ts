// OpenAI-compatible Chat Completions client (OpenAI, xAI, OpenRouter, Gemini's compat endpoint, Ollama, LM Studio, Groq…).
// Pure fetch, no SDK. Converts the canonical Anthropic-style history to the Chat Completions wire format on the fly.
import type Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import type { AiConfig, CompleteParams, LlmProvider, StreamEvent, StreamParams } from "./provider";

interface OaMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string | null;
  tool_calls?: { id: string; type: "function"; function: { name: string; arguments: string } }[];
  tool_call_id?: string;
}

export class OpenAiApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export function toOpenAiMessages(system: string | undefined, messages: Anthropic.MessageParam[]): OaMessage[] {
  const out: OaMessage[] = [];
  if (system) out.push({ role: "system", content: system });
  for (const m of messages) {
    if (typeof m.content === "string") {
      out.push({ role: m.role, content: m.content });
      continue;
    }
    if (m.role === "user") {
      const texts: string[] = [];
      for (const b of m.content as any[]) {
        if (b.type === "text") texts.push(b.text);
        else if (b.type === "tool_result") {
          const content = typeof b.content === "string" ? b.content : Array.isArray(b.content) ? b.content.map((x: any) => (x.type === "text" ? x.text : "")).join("") : "";
          out.push({ role: "tool", tool_call_id: b.tool_use_id, content });
        }
      }
      if (texts.length) out.push({ role: "user", content: texts.join("\n") });
    } else {
      const texts: string[] = [];
      const calls: OaMessage["tool_calls"] = [];
      for (const b of m.content as any[]) {
        if (b.type === "text") texts.push(b.text);
        else if (b.type === "tool_use") calls.push({ id: b.id, type: "function", function: { name: b.name, arguments: JSON.stringify(b.input ?? {}) } });
      }
      out.push({ role: "assistant", content: texts.join("\n") || null, ...(calls.length ? { tool_calls: calls } : {}) });
    }
  }
  return out;
}

function toOpenAiTools(tools: Anthropic.Tool[]) {
  return tools.map((t) => ({ type: "function" as const, function: { name: t.name, description: t.description ?? "", parameters: t.input_schema as Record<string, unknown>, strict: true } }));
}

/** Parses an SSE body of Chat Completions chunks. Accumulates tool calls by index. */
export async function* parseChatCompletionsStream(body: ReadableStream<Uint8Array>, signal?: AbortSignal): AsyncIterable<{ type: "text"; text: string } | { type: "finish"; reason: string; toolCalls: { id: string; name: string; args: string }[]; refusal?: string }> {
  const reader = body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  const calls = new Map<number, { id: string; name: string; args: string }>();
  let finish = "";
  let refusal = "";
  const flush = (): { type: "finish"; reason: string; toolCalls: { id: string; name: string; args: string }[]; refusal?: string } => ({ type: "finish", reason: finish || (calls.size ? "tool_calls" : "stop"), toolCalls: [...calls.entries()].sort((a, b) => a[0] - b[0]).map(([, v]) => v), refusal: refusal || undefined });
  while (true) {
    if (signal?.aborted) break;
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let idx: number;
    while ((idx = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, idx).replace(/\r$/, "");
      buf = buf.slice(idx + 1);
      if (!line.startsWith("data:")) continue;
      const data = line.slice(5).trim();
      if (data === "[DONE]") {
        yield flush();
        return;
      }
      let j: any;
      try {
        j = JSON.parse(data);
      } catch {
        continue;
      }
      if (j.error) throw new OpenAiApiError(500, String(j.error.message ?? j.error));
      const choice = j.choices?.[0];
      if (!choice) continue;
      const delta = choice.delta ?? {};
      if (typeof delta.content === "string" && delta.content) yield { type: "text", text: delta.content };
      if (typeof delta.refusal === "string" && delta.refusal) refusal += delta.refusal;
      if (Array.isArray(delta.tool_calls)) {
        for (const tc of delta.tool_calls) {
          const i = typeof tc.index === "number" ? tc.index : calls.size;
          const cur = calls.get(i) ?? { id: "", name: "", args: "" };
          if (tc.id) cur.id = tc.id;
          if (tc.function?.name) cur.name += tc.function.name;
          if (tc.function?.arguments) cur.args += tc.function.arguments;
          calls.set(i, cur);
        }
      }
      if (choice.finish_reason) finish = choice.finish_reason;
    }
  }
  yield flush();
}

export class OpenAiCompatibleProvider implements LlmProvider {
  readonly model: string;
  private cfg: AiConfig;
  constructor(cfg: AiConfig) {
    this.cfg = cfg;
    this.model = cfg.model;
  }

  private headers(): Record<string, string> {
    const h: Record<string, string> = { "content-type": "application/json" };
    if (this.cfg.apiKey) h.authorization = `Bearer ${this.cfg.apiKey}`;
    if (this.cfg.preset === "openrouter") {
      h["HTTP-Referer"] = "https://github.com/doable-team/heyflare";
      h["X-Title"] = "heyflare";
    }
    return h;
  }

  private async post(body: Record<string, unknown>, signal?: AbortSignal): Promise<Response> {
    let res: Response;
    try {
      res = await fetch(`${this.cfg.baseUrl}/chat/completions`, { method: "POST", headers: this.headers(), body: JSON.stringify(body), signal });
    } catch (e) {
      if (signal?.aborted) throw e;
      throw new OpenAiApiError(0, `Couldn't reach ${this.cfg.baseUrl}. Check the base URL.`);
    }
    if (!res.ok) {
      let msg = `${res.status} ${res.statusText}`;
      try {
        const j: any = await res.json();
        msg = j.error?.message ?? j.message ?? JSON.stringify(j).slice(0, 200);
      } catch {}
      throw new OpenAiApiError(res.status, msg);
    }
    return res;
  }

  async *stream(p: StreamParams): AsyncIterable<StreamEvent> {
    let res: Response;
    try {
      res = await this.post({ model: this.model, stream: true, messages: toOpenAiMessages(p.system, p.messages), tools: p.tools.length ? toOpenAiTools(p.tools) : undefined, tool_choice: p.tools.length ? "auto" : undefined, max_tokens: p.maxTokens }, p.signal);
    } catch (e) {
      yield { type: "error", message: describeOpenAiError(e) };
      return;
    }
    if (!res.body) {
      yield { type: "error", message: "Empty response from the provider." };
      return;
    }
    let text = "";
    try {
      for await (const ev of parseChatCompletionsStream(res.body, p.signal)) {
        if (ev.type === "text") {
          text += ev.text;
          yield { type: "text", text: ev.text };
        } else {
          const content: Anthropic.ContentBlock[] = [];
          if (text) content.push({ type: "text", text, citations: null } as Anthropic.TextBlock);
          for (const tc of ev.toolCalls) {
            let input: unknown = {};
            try {
              input = tc.args ? JSON.parse(tc.args) : {};
            } catch {
              input = { _raw: tc.args };
            }
            content.push({ type: "tool_use", id: tc.id || `call_${crypto.randomUUID()}`, name: tc.name, input } as Anthropic.ToolUseBlock);
          }
          if (ev.refusal) {
            content.push({ type: "text", text: ev.refusal, citations: null } as Anthropic.TextBlock);
            yield { type: "done", stop: "refusal", content };
            return;
          }
          const stop = ev.toolCalls.length ? "tool_use" : ev.reason === "length" ? "max_tokens" : "end";
          yield { type: "done", stop, content };
          return;
        }
      }
      yield { type: "done", stop: "end", content: text ? [{ type: "text", text, citations: null } as Anthropic.TextBlock] : [] };
    } catch (e) {
      yield { type: "error", message: describeOpenAiError(e) };
    }
  }

  async complete<T>(p: CompleteParams<T>): Promise<{ text: string; json?: T; refused?: boolean }> {
    const messages = toOpenAiMessages(p.system, p.messages);
    const read = async (body: Record<string, unknown>) => {
      const res = await this.post(body);
      const j: any = await res.json();
      const choice = j.choices?.[0];
      const msg = choice?.message ?? {};
      if (msg.refusal) return { text: "", refused: true as const };
      return { text: typeof msg.content === "string" ? msg.content : Array.isArray(msg.content) ? msg.content.map((x: any) => x.text ?? "").join("") : "" };
    };
    if (!p.schema) return read({ model: this.model, messages, max_tokens: p.maxTokens });
    const jsonSchema = z.toJSONSchema(p.schema.zod, { target: "draft-7" }) as Record<string, unknown>;
    let r: { text: string; refused?: true };
    try {
      r = await read({ model: this.model, messages, max_tokens: p.maxTokens, response_format: { type: "json_schema", json_schema: { name: p.schema.name, schema: jsonSchema, strict: true } } });
    } catch (e) {
      if (!(e instanceof OpenAiApiError) || e.status !== 400) throw e;
      // Provider doesn't support response_format: ask for JSON in-band.
      const fallback = [...messages];
      fallback.push({ role: "system", content: `Reply with a single JSON object only (no prose, no code fences) matching this JSON schema:\n${JSON.stringify(jsonSchema)}` });
      r = await read({ model: this.model, messages: fallback, max_tokens: p.maxTokens });
    }
    if (r.refused) return { text: "", refused: true };
    const parsed = parseJsonLoose(r.text);
    if (parsed === undefined) return { text: r.text };
    const v = p.schema.zod.safeParse(parsed);
    return { text: r.text, json: v.success ? v.data : undefined };
  }
}

function parseJsonLoose(text: string): unknown {
  const t = text.trim().replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/, "");
  try {
    return JSON.parse(t);
  } catch {}
  const a = t.indexOf("{");
  const b = t.lastIndexOf("}");
  if (a >= 0 && b > a) {
    try {
      return JSON.parse(t.slice(a, b + 1));
    } catch {}
  }
  return undefined;
}

export function describeOpenAiError(e: unknown): string {
  if (e instanceof OpenAiApiError) {
    if (e.status === 0) return e.message;
    if (e.status === 401 || e.status === 403) return "The API key was rejected. Check it in Settings → AI.";
    if (e.status === 404) return `Model or endpoint not found: ${e.message.slice(0, 160)}`;
    if (e.status === 429) return "Rate limited by the provider. Try again in a moment.";
    return `Provider error ${e.status}: ${e.message.slice(0, 200)}`;
  }
  const msg = (e as Error)?.message ?? String(e);
  if (/fetch failed|ECONNREFUSED|network|connection lost|connect/i.test(msg)) return "Couldn't reach the provider. Check the base URL.";
  return msg.slice(0, 300);
}
