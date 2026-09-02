// Mock OpenAI-compatible server + assertions for src/worker/ai/openai.ts
import { createServer } from "node:http";
import { z } from "zod";
import { OpenAiCompatibleProvider, toOpenAiMessages } from "../src/worker/ai/openai.ts";

const seen: any[] = [];
const server = createServer(async (req, res) => {
  let body = "";
  for await (const c of req) body += c;
  const j = JSON.parse(body);
  seen.push(j);
  if (j.stream) {
    res.writeHead(200, { "content-type": "text/event-stream" });
    const chunks = [
      { choices: [{ delta: { role: "assistant", content: "Let me " } }] },
      { choices: [{ delta: { content: "check." } }] },
      { choices: [{ delta: { tool_calls: [{ index: 0, id: "call_1", type: "function", function: { name: "search_", arguments: "{\"que" } }] } }] },
      { choices: [{ delta: { tool_calls: [{ index: 0, function: { name: "mail", arguments: "ry\":\"invoice\",\"limit\":null}" } }] } }] },
      { choices: [{ delta: { tool_calls: [{ index: 1, id: "call_2", type: "function", function: { name: "list_labels", arguments: "{}" } }] } }] },
      { choices: [{ delta: {}, finish_reason: "tool_calls" }] },
    ];
    for (const c of chunks) res.write(`data: ${JSON.stringify(c)}\n\n`);
    res.write("data: [DONE]\n\n");
    res.end();
    return;
  }
  if (j.response_format) {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: "response_format not supported" } }));
    return;
  }
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify({ choices: [{ message: { role: "assistant", content: "```json\n{\"subject\":null,\"body_text\":\"Hi there\"}\n```" } }] }));
});
await new Promise<void>((r) => server.listen(0, r));
const port = (server.address() as any).port;
const p = new OpenAiCompatibleProvider({ provider: "openai_compatible", preset: "custom", baseUrl: `http://127.0.0.1:${port}/v1`, apiKey: "test", model: "mock-1", learn: true, autoSend: false });

// 1. streaming + tool call accumulation
const events: any[] = [];
for await (const ev of p.stream({ system: "sys", messages: [{ role: "user", content: [{ type: "text", text: "find invoices" }] }], tools: [{ name: "search_mail", description: "d", input_schema: { type: "object", properties: {}, additionalProperties: false, required: [] } } as any], maxTokens: 100 })) events.push(ev);
const text = events.filter((e) => e.type === "text").map((e) => e.text).join("");
const done = events.find((e) => e.type === "done");
const assert = (c: boolean, m: string) => { if (!c) { console.error("FAIL", m, JSON.stringify(events)); process.exit(1); } };
assert(text === "Let me check.", "text accumulated");
assert(done.stop === "tool_use", "stop is tool_use");
const uses = done.content.filter((b: any) => b.type === "tool_use");
assert(uses.length === 2 && uses[0].id === "call_1" && uses[0].name === "search_mail" && uses[0].input.query === "invoice" && uses[1].name === "list_labels", "tool calls accumulated by index");
assert(seen[0].tools[0].type === "function" && seen[0].tools[0].function.name === "search_mail" && seen[0].tool_choice === "auto", "tools sent in OpenAI shape");

// 2. history conversion (Anthropic blocks -> OpenAI messages)
const hist = toOpenAiMessages("sys", [
  { role: "user", content: [{ type: "text", text: "hi" }] },
  { role: "assistant", content: done.content },
  { role: "user", content: [{ type: "tool_result", tool_use_id: "call_1", content: "{\"results\":[]}" }, { type: "tool_result", tool_use_id: "call_2", content: "{}" }] },
]);
assert(hist[0].role === "system" && hist[1].role === "user" && hist[2].role === "assistant" && hist[2].tool_calls?.length === 2 && hist[3].role === "tool" && hist[3].tool_call_id === "call_1" && hist[4].role === "tool", "history converted: " + JSON.stringify(hist));

// 3. structured output with response_format rejected -> JSON-in-band fallback + fenced parse
const schema = z.object({ subject: z.string().nullable(), body_text: z.string() });
const r = await p.complete({ maxTokens: 100, schema: { name: "reply", zod: schema }, messages: [{ role: "user", content: "write" }] });
assert(r.json?.body_text === "Hi there", "fallback structured output parsed: " + JSON.stringify(r));
assert(seen[1].response_format?.type === "json_schema" && seen[2].response_format === undefined && seen[2].messages.at(-1).role === "system", "fallback path used");
console.log("openai-compatible mock: all assertions passed");
server.close();
