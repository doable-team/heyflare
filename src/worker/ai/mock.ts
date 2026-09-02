// Hidden mock provider for local end-to-end testing of streaming + tool calls (env.AI_MOCK === "1" only).
import type Anthropic from "@anthropic-ai/sdk";
import type { LlmProvider, StreamParams, StreamEvent, CompleteParams } from "./provider";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class MockProvider implements LlmProvider {
  constructor(readonly model: string) {}

  async *stream(p: StreamParams): AsyncIterable<StreamEvent> {
    const last = p.messages[p.messages.length - 1];
    const afterTool = !!last && Array.isArray(last.content) && (last.content as Anthropic.ContentBlockParam[]).some((b) => b.type === "tool_result");
    const words = afterTool
      ? "Here is what I found: two threads mention an invoice. The latest is from Jane Cooper about the design review; the other is an Amazon receipt. Want me to draft a reply to Jane?".split(" ")
      : "Let me look through your mail for that.".split(" ");
    let text = "";
    for (const w of words) {
      if (p.signal?.aborted) return;
      const chunk = (text ? " " : "") + w;
      text += chunk;
      yield { type: "text", text: chunk };
      await sleep(40);
    }
    if (afterTool) {
      yield { type: "done", stop: "end", content: [{ type: "text", text, citations: null }] as Anthropic.ContentBlock[] };
      return;
    }
    yield {
      type: "done",
      stop: "tool_use",
      content: [
        { type: "text", text, citations: null },
        { type: "tool_use", id: `toolu_mock_${Date.now()}`, name: "search_mail", input: { query: "invoice" } },
      ] as Anthropic.ContentBlock[],
    };
  }

  async complete<T>(p: CompleteParams<T>): Promise<{ text: string; json?: T; refused?: boolean }> {
    await sleep(60);
    if (p.schema) {
      const guess = { subject: null, body_text: "Thanks — sounds good to me. Farhan", entries: [], summary: "Mock summary." };
      const r = p.schema.zod.safeParse(guess);
      return { text: JSON.stringify(guess), json: r.success ? r.data : undefined };
    }
    return { text: "ready" };
  }
}
