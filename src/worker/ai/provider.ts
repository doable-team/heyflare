// Provider layer: a common stream/complete interface over Anthropic (official SDK) and OpenAI-compatible APIs.
import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import type { z } from "zod";
import type { Env } from "../env";
import { decryptSecret } from "./crypto";
import { OpenAiCompatibleProvider, OpenAiApiError, describeOpenAiError } from "./openai";
import { MockProvider } from "./mock";

/* ---------- presets ---------- */

export type ProviderKind = "anthropic" | "openai_compatible" | "mock";
export interface Preset {
  id: "anthropic" | "openai" | "xai" | "openrouter" | "gemini" | "custom" | "mock";
  label: string;
  kind: ProviderKind;
  base_url: string;
  default_model: string;
  models: string[];
  key_placeholder: string;
  key_url?: string;
}

export const PRESETS: Preset[] = [
  { id: "anthropic", label: "Anthropic", kind: "anthropic", base_url: "https://api.anthropic.com", default_model: "claude-opus-5", models: ["claude-opus-5", "claude-fable-5-1", "claude-sonnet-5", "claude-haiku-4-5"], key_placeholder: "sk-ant-api03-…", key_url: "https://console.anthropic.com/settings/keys" },
  { id: "openai", label: "OpenAI", kind: "openai_compatible", base_url: "https://api.openai.com/v1", default_model: "gpt-5", models: ["gpt-5", "gpt-5-mini", "gpt-4.1", "o3"], key_placeholder: "sk-…", key_url: "https://platform.openai.com/api-keys" },
  { id: "xai", label: "xAI (Grok)", kind: "openai_compatible", base_url: "https://api.x.ai/v1", default_model: "grok-4", models: ["grok-4", "grok-4-fast", "grok-3"], key_placeholder: "xai-…", key_url: "https://console.x.ai" },
  { id: "openrouter", label: "OpenRouter", kind: "openai_compatible", base_url: "https://openrouter.ai/api/v1", default_model: "anthropic/claude-sonnet-4.5", models: ["anthropic/claude-sonnet-4.5", "openai/gpt-5", "google/gemini-2.5-pro", "x-ai/grok-4", "meta-llama/llama-4-maverick"], key_placeholder: "sk-or-…", key_url: "https://openrouter.ai/keys" },
  { id: "gemini", label: "Google Gemini", kind: "openai_compatible", base_url: "https://generativelanguage.googleapis.com/v1beta/openai", default_model: "gemini-2.5-pro", models: ["gemini-2.5-pro", "gemini-2.5-flash"], key_placeholder: "AIza…", key_url: "https://aistudio.google.com/apikey" },
  { id: "custom", label: "Custom (OpenAI-compatible)", kind: "openai_compatible", base_url: "", default_model: "", models: ["llama3.1", "mistral", "qwen2.5"], key_placeholder: "API key (optional for local servers)" },
];
export const DEFAULT_MODEL = "claude-opus-5";
export const MODELS = PRESETS[0].models.map((id) => ({ id, label: id }));

/** Hidden test provider: streams a canned answer and calls one tool. Only usable when env.AI_MOCK === "1". */
export const MOCK_PRESET: Preset = { id: "mock", label: "Mock (testing)", kind: "mock", base_url: "", default_model: "mock-1", models: ["mock-1"], key_placeholder: "not needed" };

export function presetById(id: string): Preset {
  if (id === "mock") return MOCK_PRESET;
  return PRESETS.find((p) => p.id === id) ?? PRESETS[0];
}

/* ---------- config ---------- */

export interface AiSettingsRow {
  user_id: string;
  provider: ProviderKind;
  preset: string;
  base_url: string;
  api_key_enc: string;
  key_hint: string;
  model: string;
  learn: number;
  auto_send: number;
  updated_at: number;
}

export interface AiConfig {
  provider: ProviderKind;
  preset: Preset["id"];
  baseUrl: string;
  apiKey: string;
  model: string;
  learn: boolean;
  autoSend: boolean;
}

export async function loadAiSettings(env: Env, userId: string): Promise<AiSettingsRow | null> {
  return (await env.DB.prepare(`SELECT * FROM ai_settings WHERE user_id = ?`).bind(userId).first<AiSettingsRow>()) ?? null;
}

/** Decrypted config, or null when nothing usable is configured. */
export async function loadAiConfig(env: Env, userId: string): Promise<AiConfig | null> {
  const row = await loadAiSettings(env, userId);
  if (!row) return null;
  const preset = presetById(row.preset || (row.provider === "anthropic" ? "anthropic" : "custom"));
  if (preset.kind === "mock") {
    if (env.AI_MOCK !== "1") return null;
    return { provider: "mock", preset: "mock", baseUrl: "", apiKey: "", model: row.model || preset.default_model, learn: !!row.learn, autoSend: !!row.auto_send };
  }
  const apiKey = row.api_key_enc ? await decryptSecret(env.SESSION_SECRET, row.api_key_enc) : "";
  const baseUrl = preset.id === "custom" ? row.base_url.replace(/\/+$/, "") : preset.base_url;
  if (preset.kind === "anthropic" && !apiKey) return null;
  if (preset.kind === "openai_compatible" && !baseUrl) return null;
  return { provider: preset.kind, preset: preset.id, baseUrl, apiKey, model: row.model || preset.default_model, learn: !!row.learn, autoSend: !!row.auto_send };
}

export class AiNotConfigured extends Error {
  constructor() {
    super("ai_not_configured");
  }
}

/* ---------- common interface ---------- */

export type StreamEvent =
  | { type: "text"; text: string }
  | { type: "done"; stop: "end" | "tool_use" | "refusal" | "max_tokens"; content: Anthropic.ContentBlock[] }
  | { type: "error"; message: string };

export interface StreamParams {
  system: string;
  /** Canonical history: Anthropic-style content blocks. */
  messages: Anthropic.MessageParam[];
  tools: Anthropic.Tool[];
  maxTokens: number;
  effort?: "low" | "medium" | "high";
  signal?: AbortSignal;
}

export interface CompleteParams<T> {
  system?: string;
  messages: Anthropic.MessageParam[];
  schema?: { name: string; zod: z.ZodType<T> };
  maxTokens: number;
  effort?: "low" | "medium" | "high";
}

export interface LlmProvider {
  readonly model: string;
  stream(p: StreamParams): AsyncIterable<StreamEvent>;
  complete<T = unknown>(p: CompleteParams<T>): Promise<{ text: string; json?: T; refused?: boolean }>;
}

export function makeProvider(cfg: AiConfig): LlmProvider {
  if (cfg.provider === "mock") return new MockProvider(cfg.model);
  if (cfg.provider === "anthropic") return new AnthropicProvider(cfg);
  return new OpenAiCompatibleProvider(cfg);
}

/* ---------- Anthropic (official SDK) ---------- */

export function makeClient(cfg: AiConfig): Anthropic {
  const base = { maxRetries: 1, timeout: 120_000 };
  // OAuth tokens (e.g. from `ant auth`) go on Authorization: Bearer with the oauth beta; API keys use x-api-key.
  if (cfg.apiKey.startsWith("sk-ant-oat") || !cfg.apiKey.startsWith("sk-ant-")) {
    return new Anthropic({ ...base, apiKey: null, authToken: cfg.apiKey, defaultHeaders: { "anthropic-beta": "oauth-2025-04-20" } });
  }
  return new Anthropic({ ...base, apiKey: cfg.apiKey });
}

class AnthropicProvider implements LlmProvider {
  readonly model: string;
  private client: Anthropic;
  constructor(private cfg: AiConfig) {
    this.model = cfg.model;
    this.client = makeClient(cfg);
  }
  async *stream(p: StreamParams): AsyncIterable<StreamEvent> {
    const chunks: string[] = [];
    let resolveTick: (() => void) | null = null;
    const stream = this.client.messages.stream(
      {
        model: this.model,
        max_tokens: p.maxTokens,
        system: [{ type: "text", text: p.system, cache_control: { type: "ephemeral" } }],
        tools: p.tools,
        messages: p.messages,
        output_config: { effort: p.effort ?? "medium" },
      },
      { signal: p.signal }
    );
    stream.on("text", (d) => {
      chunks.push(d);
      resolveTick?.();
    });
    const final = stream.finalMessage().then((m) => ({ m }), (e: unknown) => ({ e }));
    let done: { m: Anthropic.Message } | { e: unknown } | null = null;
    final.then((r) => {
      done = r;
      resolveTick?.();
    });
    while (!done) {
      if (chunks.length) yield { type: "text", text: chunks.splice(0).join("") };
      else await new Promise<void>((r) => (resolveTick = r));
      resolveTick = null;
    }
    if (chunks.length) yield { type: "text", text: chunks.splice(0).join("") };
    const r = done as { m: Anthropic.Message } | { e: unknown };
    if ("e" in r) {
      yield { type: "error", message: describeApiError(r.e) };
      return;
    }
    const m = r.m;
    const stop = m.stop_reason === "refusal" ? "refusal" : m.stop_reason === "tool_use" ? "tool_use" : m.stop_reason === "max_tokens" ? "max_tokens" : "end";
    yield { type: "done", stop, content: m.content };
  }
  async complete<T>(p: CompleteParams<T>) {
    const common = { model: this.model, max_tokens: p.maxTokens, output_config: { effort: p.effort ?? "medium" } as Anthropic.MessageCreateParams["output_config"], messages: p.messages, ...(p.system ? { system: [{ type: "text" as const, text: p.system }] } : {}) };
    if (p.schema) {
      const res = await this.client.messages.parse({ ...common, output_config: { ...common.output_config, format: zodOutputFormat(p.schema.zod) } });
      if (res.stop_reason === "refusal") return { text: "", refused: true };
      return { text: res.content.filter((b): b is Anthropic.TextBlock => b.type === "text").map((b) => b.text).join(""), json: (res.parsed_output ?? undefined) as T | undefined };
    }
    const res = await this.client.messages.create(common);
    if (res.stop_reason === "refusal") return { text: "", refused: true };
    return { text: res.content.filter((b): b is Anthropic.TextBlock => b.type === "text").map((b) => b.text).join("") };
  }
}

/** Friendly message for API failures shown in the UI. */
export function describeApiError(e: unknown): string {
  if (e instanceof AiNotConfigured) return "Set up an AI provider in Settings → AI first.";
  if (e instanceof OpenAiApiError) return describeOpenAiError(e);
  if (e instanceof Anthropic.AuthenticationError) return "The API key was rejected. Check it in Settings → AI.";
  if (e instanceof Anthropic.PermissionDeniedError) return "This key isn't allowed to use that model.";
  if (e instanceof Anthropic.RateLimitError) return "Rate limited by the provider. Try again in a moment.";
  if (e instanceof Anthropic.BadRequestError) return `The provider rejected the request: ${e.message.slice(0, 200)}`;
  if (e instanceof Anthropic.APIError) return `Provider error ${e.status ?? ""}: ${e.message.slice(0, 200)}`;
  const msg = (e as Error)?.message ?? String(e);
  if (msg === "session_secret_missing") return "SESSION_SECRET is not set on the server, so keys can't be decrypted.";
  return msg.slice(0, 300);
}
