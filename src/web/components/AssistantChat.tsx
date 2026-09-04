import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { ArrowUp, Check, Loader2, Paperclip, PenSquare, Plus, Send, Sparkles, Square, TriangleAlert, X } from "lucide-react";
import { toast } from "sonner";
import type { AiDraftCard } from "@shared/types";
import { aiChatStream, api, useAiConversation, useAiSettings, type AiSseEvent } from "../api";
import { useCompose } from "../context/ComposeContext";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import type { ContextChip } from "../lib/assistantStore";
import { focus } from "../lib/focusStore";
import { draftSentThread, markDraftSent, subscribeSentDrafts } from "../lib/sentDrafts";

/* ---------- rendering helpers ---------- */

function textToHtml(text: string): string {
  const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return text.trim().split(/\n{2,}/).map((p) => `<p>${esc(p).replace(/\n/g, "<br>")}</p>`).join("");
}

/** Tiny markdown: paragraphs, "- " bullets, **bold**, `code`. */
export function Prose({ text, className }: { text: string; className?: string }) {
  const blocks = useMemo(() => text.replace(/\r/g, "").split(/\n{2,}/).filter((b) => b.trim()), [text]);
  const inline = (s: string) => {
    const parts = s.split(/(\*\*[^*]+\*\*|`[^`]+`)/g);
    return parts.map((p, i) => (p.startsWith("**") ? <strong key={i} className="font-semibold">{p.slice(2, -2)}</strong> : p.startsWith("`") ? <code key={i} className="font-mono text-[12px] bg-muted rounded px-1">{p.slice(1, -1)}</code> : <span key={i}>{p}</span>));
  };
  return (
    <div className={cn("text-[14px] leading-6 space-y-2", className)}>
      {blocks.map((b, i) => {
        const lines = b.split("\n");
        if (lines.every((l) => /^\s*[-*]\s+/.test(l))) {
          return (
            <ul key={i} className="space-y-1 pl-4 list-disc marker:text-muted-foreground">
              {lines.map((l, j) => <li key={j}>{inline(l.replace(/^\s*[-*]\s+/, ""))}</li>)}
            </ul>
          );
        }
        if (lines.every((l) => /^\s*\d+[.)]\s+/.test(l))) {
          return (
            <ol key={i} className="space-y-1 pl-5 list-decimal marker:text-muted-foreground">
              {lines.map((l, j) => <li key={j}>{inline(l.replace(/^\s*\d+[.)]\s+/, ""))}</li>)}
            </ol>
          );
        }
        return <p key={i}>{lines.map((l, j) => <span key={j}>{j > 0 && <br />}{inline(l)}</span>)}</p>;
      })}
    </div>
  );
}

function ThinkingDots() {
  return (
    <div className="flex items-center gap-1 h-6" aria-label="Thinking">
      {[0, 1, 2].map((i) => (
        <span key={i} className="size-1.5 rounded-full bg-muted-foreground/60 animate-pulse" style={{ animationDelay: `${i * 160}ms` }} />
      ))}
    </div>
  );
}

function ToolLine({ status, summary }: { status: "running" | "done" | "error"; summary: string }) {
  return (
    <div className="flex items-center gap-2 text-[12px] text-muted-foreground py-0.5">
      {status === "running" ? <Loader2 className="size-3 animate-spin" /> : status === "error" ? <TriangleAlert className="size-3" /> : <Check className="size-3" />}
      <span className="truncate">{summary}</span>
    </div>
  );
}

export function DraftCard({ d, sentThreadId }: { d: AiDraftCard; sentThreadId?: string }) {
  const { openCompose } = useCompose();
  const qc = useQueryClient();
  const [state, setState] = useState<"idle" | "sending" | "sent">(sentThreadId ? "sent" : "idle");
  const [threadId, setThreadId] = useState<string | undefined>(sentThreadId);
  // A draft can also be sent from the composer this card opened, or by the assistant itself.
  useEffect(() => {
    const sync = () => {
      const t = draftSentThread(d.draft_id);
      if (t !== null) {
        setState("sent");
        setThreadId((prev) => prev ?? t);
      }
    };
    sync();
    return subscribeSentDrafts(sync);
  }, [d.draft_id]);
  useEffect(() => {
    if (sentThreadId) {
      setState("sent");
      setThreadId(sentThreadId);
    }
  }, [sentThreadId]);
  const send = async () => {
    setState("sending");
    try {
      await api.post("/api/send", { draft_id: d.draft_id, account_id: d.account_id, thread_id: d.thread_id, to: d.to, cc: d.cc, subject: d.subject, body_html: textToHtml(d.body_text) });
      setState("sent");
      toast("Sent");
      markDraftSent(d.draft_id);
      qc.invalidateQueries({ predicate: (q) => q.queryKey[0] !== "me" });
    } catch (e) {
      setState("idle");
      toast.error((e as Error).message);
    }
  };
  if (state === "sent") {
    // Collapsed: the mail is gone, so the card stops offering to send it.
    return (
      <div className="my-2 rounded-lg bg-muted/50 px-3 py-2 text-[13px] flex items-center gap-2 text-muted-foreground">
        <Check className="size-3.5 shrink-0" />
        <span className="truncate">
          Sent to {d.to.map((a) => a.name || a.email).join(", ")} · <span className="text-foreground/80">{d.subject}</span>
        </span>
        {threadId && (
          <Link className="ml-auto shrink-0 underline underline-offset-2 hover:text-foreground" to={`/t/${threadId}`}>
            Open
          </Link>
        )}
      </div>
    );
  }

  return (
    <div className="my-2 rounded-lg bg-muted/50 p-3 text-[13px]">
      <div className="flex items-center gap-2 text-muted-foreground mb-1">
        <PenSquare className="size-3.5" />
        <span className="truncate">Draft · from {d.from} · to {d.to.map((a) => a.name || a.email).join(", ")}{d.cc.length ? ` · cc ${d.cc.map((a) => a.email).join(", ")}` : ""}</span>
      </div>
      <div className="font-medium mb-1">{d.subject}</div>
      <Prose text={d.body_text} className="text-[13px] leading-5 text-foreground/90 max-h-56 overflow-y-auto" />
      <div className="flex items-center gap-2 mt-3">
        <Button size="sm" onClick={send} disabled={state === "sending"}>{state === "sending" ? <Loader2 className="animate-spin" /> : <Send />} Send</Button>
        <Button size="sm" variant="ghost" onClick={() => openCompose({ draft_id: d.draft_id, account_id: d.account_id, thread_id: d.thread_id, to: d.to, cc: d.cc, subject: d.subject, body_html: textToHtml(d.body_text) })}>Open in composer</Button>
      </div>
    </div>
  );
}

/* ---------- message model ---------- */

interface Turn {
  id: string;
  role: "user" | "assistant";
  text: string;
  context?: ContextChip[];
  tools: { id: string; status: "running" | "done" | "error"; summary: string }[];
  drafts: AiDraftCard[];
  sent: Record<string, string>;
  error?: string;
}

function turnsFromStored(messages: { id: string; role: "user" | "assistant"; content: unknown[] }[]): Turn[] {
  const out: Turn[] = [];
  for (const m of messages) {
    const blocks = Array.isArray(m.content) ? (m.content as any[]) : [];
    if (m.role === "user") {
      const ctx: ContextChip[] = [];
      const texts: string[] = [];
      for (const b of blocks) {
        if (b.type !== "text" || typeof b.text !== "string") continue;
        const m2 = /^\[\[context thread=([^\]]+)\]\] Subject: (.*?) · From: (.*?)(?:\n|$)/.exec(b.text);
        if (m2) ctx.push({ id: m2[1], subject: m2[2], from: m2[3] });
        else texts.push(b.text);
      }
      const text = texts.join("\n");
      if (text.trim()) out.push({ id: m.id, role: "user", text, context: ctx, tools: [], drafts: [], sent: {} });
      continue;
    }
    const last = out[out.length - 1];
    const target = last && last.role === "assistant" ? last : (out.push({ id: m.id, role: "assistant", text: "", tools: [], drafts: [], sent: {} }), out[out.length - 1]);
    for (const b of blocks) {
      if (b.type === "text") target.text += (target.text ? "\n\n" : "") + b.text;
      else if (b.type === "tool_use") target.tools.push({ id: b.id, status: "done", summary: toolLabel(b.name, b.input) });
    }
  }
  return out;
}

function toolLabel(name: string, input: any): string {
  switch (name) {
    case "search_mail": return `Searched mail for “${input?.query ?? ""}”`;
    case "list_threads": return `Listed ${String(input?.bucket ?? "").replace("_", " ")}`;
    case "read_thread": return "Read a thread";
    case "list_screener": return "Checked the Screener";
    case "screen_sender": return `Screened a sender → ${String(input?.decision ?? "").replace("_", " ")}`;
    case "thread_action": return `Organised · ${String(input?.action ?? "").replace("_", " ")}`;
    case "create_draft": return `Drafted “${input?.subject ?? "a message"}”`;
    case "send_draft": return "Sent a draft";
    case "remember": return `Remembered: ${input?.content ?? ""}`;
    case "forget": return "Forgot a memory entry";
    case "find_contact": return `Looked up “${input?.query ?? ""}”`;
    case "save_clip": return "Saved a clip";
    case "create_collection": return `Created collection “${input?.name ?? ""}”`;
    case "add_to_collection": return "Added to a collection";
    default: return name.replace(/_/g, " ");
  }
}

/* ---------- the chat ---------- */

export const SUGGESTIONS = ["What's new for me today?", "Anything waiting in the Screener?", "Summarise my unread mail", "Draft a reply to the latest email from …"];

/** Past this the box stops growing and scrolls instead, so the conversation never leaves the screen. */
const INPUT_MAX_PX = 160;

export function AssistantChat({
  conversationId,
  onConversationId,
  compact,
  context = [],
  onRemoveContext,
  onAddContext,
  autoFocus, onClose }: {
  conversationId?: string;
  onConversationId: (id: string) => void;
  compact?: boolean;
  /** Threads attached as context for the next message (panel mode). */
  context?: ContextChip[];
  onRemoveContext?: (id: string) => void;
  /** Opens the thread picker ("+" button and typing "@"). */
  onAddContext?: () => void;
  autoFocus?: boolean; onClose?: () => void }) {
  const settings = useAiSettings();
  const conv = useAiConversation(conversationId);
  const qc = useQueryClient();
  const [turns, setTurns] = useState<Turn[]>([]);
  const [live, setLiveState] = useState<Turn | null>(null);
  const liveRef = useRef<Turn | null>(null);
  /** Keep the streaming turn in a ref too, so events (which arrive outside React's batching) never race a stale closure. */
  const setLive = (next: Turn | null | ((l: Turn | null) => Turn | null)) => {
    liveRef.current = typeof next === "function" ? next(liveRef.current) : next;
    setLiveState(liveRef.current);
  };
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const abortRef = useRef<AbortController | null>(null);
  const bottomRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  /**
   * Grow the box to fit what is in it.
   *
   * Counting newlines — which is what this did — only sees the lines someone typed deliberately.
   * A long sentence with no break in it wraps onto four visual lines while still being one string,
   * so the field stayed a single row and the message scrolled out of sight as it was written.
   * Only the browser knows how the text actually wrapped, and `scrollHeight` is where it says so:
   * collapse the height first, or a box that has grown can never measure itself smaller again.
   */
  useLayoutEffect(() => {
    const el = inputRef.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, INPUT_MAX_PX)}px`;
  }, [input]);
  /** Conversation whose turns are held locally (streamed here); server data must not overwrite them mid-flight or drop transient errors. */
  const streamedConv = useRef<string | null>(null);
  const busyRef = useRef(false);

  useEffect(() => {
    if (busyRef.current) return;
    if (conv.data) {
      if (conv.data.conversation.id === streamedConv.current) return;
      setTurns(turnsFromStored(conv.data.messages as any));
    } else if (!conversationId) {
      streamedConv.current = null;
      setTurns([]);
    }
  }, [conv.data, conversationId]);
  useEffect(() => {
    bottomRef.current?.scrollIntoView({ block: "end" });
  }, [turns, live?.text, live?.tools.length]);

  const send = async (text: string) => {
    const msg = text.trim();
    if (!msg || busy) return;
    setInput("");
    setBusy(true);
    busyRef.current = true;
    if (conversationId) streamedConv.current = conversationId;
    const ctx = context.slice(0, 3);
    const userTurn: Turn = { id: `u-${Date.now()}`, role: "user", text: msg, context: ctx, tools: [], drafts: [], sent: {} };
    const assistant: Turn = { id: `a-${Date.now()}`, role: "assistant", text: "", tools: [], drafts: [], sent: {} };
    setTurns((t) => [...t, userTurn]);
    setLive(assistant);
    const ac = new AbortController();
    abortRef.current = ac;
    let convId = conversationId;
    try {
      await aiChatStream(
        { conversation_id: conversationId, message: msg, context_thread_ids: ctx.length ? ctx.map((c) => c.id) : undefined },
        (e: AiSseEvent) => {
          if (e.type === "start") {
            convId = e.conversation_id;
            streamedConv.current = e.conversation_id;
            if (!conversationId) onConversationId(e.conversation_id);
          } else if (e.type === "text") setLive((l) => (l ? { ...l, text: l.text + e.text } : l));
          else if (e.type === "tool") setLive((l) => (l ? { ...l, tools: l.tools.some((x) => x.id === e.id) ? l.tools.map((x) => (x.id === e.id ? { ...x, status: e.status, summary: e.summary } : x)) : [...l.tools, { id: e.id, status: e.status, summary: e.summary }] } : l));
          else if (e.type === "draft") setLive((l) => (l ? { ...l, drafts: [...l.drafts, e.draft] } : l));
          else if (e.type === "sent") setLive((l) => (l ? { ...l, sent: { ...l.sent, [e.draft_id]: e.thread_id } } : l));
          else if (e.type === "error") setLive((l) => (l ? { ...l, error: e.message } : l));
        },
        ac.signal
      );
    } catch (e) {
      if (!ac.signal.aborted) setLive((l) => (l ? { ...l, error: (e as Error).message } : { ...assistant, error: (e as Error).message }));
    }
    const finished = liveRef.current;
    if (finished) setTurns((t) => [...t, finished]);
    setLive(null);
    busyRef.current = false;
    setBusy(false);
    abortRef.current = null;
    if (onRemoveContext) for (const c of ctx) onRemoveContext(c.id);
    qc.invalidateQueries({ queryKey: ["ai", "conversations"] });
    if (convId) qc.invalidateQueries({ queryKey: ["ai", "conversation", convId] });
    qc.invalidateQueries({ predicate: (q) => ["imbox", "threads", "counts", "screener", "thread", "feed"].includes(String(q.queryKey[0])) });
  };

  const stop = () => abortRef.current?.abort();
  const notConfigured = settings.data && !settings.data.configured;
  const all = live ? [...turns, live] : turns;

  return (
    <div className="flex flex-col h-full min-h-0">
      <div className={cn("flex-1 min-h-0 overflow-y-auto", compact ? "px-4" : "px-2")}>
        {all.length === 0 && (
          <div className={cn("pb-6 text-center", compact ? "pt-6" : "pt-10")}>
            <Sparkles className="size-6 mx-auto text-muted-foreground" />
            <div className="mt-3 text-[15px] font-medium">What can I do for you?</div>
            <div className="text-[13px] text-muted-foreground mt-1">I can read, search and organise your mail, screen senders, and write drafts for you to send.</div>
            {notConfigured && (
              <div className="mt-4 text-[13px]">
                <Link to="/settings#ai" className="underline underline-offset-2">Add your Anthropic API key</Link> to get started.
              </div>
            )}
            {!notConfigured && (
              <div className="mt-5 flex flex-wrap justify-center gap-2">
                {SUGGESTIONS.map((s) => (
                  <button key={s} type="button" onClick={() => { setInput(s); inputRef.current?.focus(); }} className="rounded-full bg-muted/60 hover:bg-muted px-3 h-8 text-[13px] text-foreground/80">{s}</button>
                ))}
              </div>
            )}
          </div>
        )}
        <div className="py-4 space-y-5">
          {all.map((t) => (
            <div key={t.id} className={cn("flex", t.role === "user" ? "justify-end" : "justify-start")}>
              {t.role === "user" ? (
                <div className="max-w-[85%]">
                  {!!t.context?.length && (
                    <div className="flex flex-wrap justify-end gap-1 mb-1">
                      {t.context.map((c) => (
                        <Link key={c.id} to={`/t/${c.id}`} className="inline-flex items-center gap-1 rounded-md bg-muted/60 px-2 h-6 text-[12px] text-muted-foreground max-w-[220px]">
                          <Paperclip className="size-3 shrink-0" />
                          <span className="truncate">{c.subject || "(no subject)"}</span>
                        </Link>
                      ))}
                    </div>
                  )}
                  <div className="rounded-2xl rounded-br-md bg-muted px-3.5 py-2 text-[14px] leading-6 whitespace-pre-wrap">{t.text}</div>
                </div>
              ) : (
                <div className="max-w-[92%] min-w-0">
                  {t.tools.length > 0 && <div className="mb-1">{t.tools.map((x) => <ToolLine key={x.id} status={x.status} summary={x.summary} />)}</div>}
                  {t.text ? <Prose text={t.text} /> : t === live && !t.error ? <ThinkingDots /> : null}
                  {t.drafts.map((d) => <DraftCard key={d.draft_id} d={d} sentThreadId={t.sent[d.draft_id]} />)}
                  {t.error && <div className="mt-2 flex items-start gap-2 rounded-md bg-muted/60 px-3 py-2 text-[13px]"><TriangleAlert className="size-4 shrink-0 mt-0.5 text-muted-foreground" /><span>{t.error}{/API key/i.test(t.error) && <> · <Link to="/settings#ai" className="underline underline-offset-2">Settings → AI</Link></>}</span></div>}
                </div>
              )}
            </div>
          ))}
          <div ref={bottomRef} />
        </div>
      </div>
      <form
        className={cn("shrink-0 pt-2", compact ? "px-4 pb-3" : "px-2 pb-2")}
        onSubmit={(e) => {
          e.preventDefault();
          send(input);
        }}
      >
        <div className="rounded-xl bg-muted/60 focus-within:bg-muted px-3 py-2">
          {context.length > 0 && (
            <div className="flex flex-wrap gap-1 mb-1.5">
              {context.map((c) => (
                <span key={c.id} className="inline-flex items-center gap-1 rounded-md bg-background border border-border pl-2 pr-1 h-6 text-[12px] max-w-[240px]">
                  <Paperclip className="size-3 shrink-0 text-muted-foreground" />
                  <span className="truncate">{c.subject || "(no subject)"}</span>
                  <span className="truncate text-muted-foreground hidden sm:inline">· {c.from}</span>
                  {onRemoveContext && (
                    <button type="button" aria-label="Remove context" onClick={() => onRemoveContext(c.id)} className="size-4 rounded-sm flex items-center justify-center text-muted-foreground hover:text-foreground hover:bg-muted">
                      <X className="size-3" />
                    </button>
                  )}
                </span>
              ))}
            </div>
          )}
        <div className="flex items-end gap-2">
          {onAddContext && (
            <Button type="button" size="icon-sm" variant="ghost" className="text-muted-foreground shrink-0" onClick={onAddContext} aria-label="Add a thread as context" disabled={!!notConfigured}>
              <Plus />
            </Button>
          )}
          <textarea
            ref={inputRef}
            data-assistant-input
            autoFocus={autoFocus}
            value={input}
            onChange={(e) => {
              const v = e.target.value;
              // "@" opens the thread picker only when it starts a word — otherwise you could never
              // type an email address (issue #2). The character is always kept.
              const startsWord = v.length === 1 || /\s$/.test(v.slice(0, -1));
              if (onAddContext && v.endsWith("@") && !input.endsWith("@") && startsWord) {
                setInput(v);
                onAddContext();
                return;
              }
              setInput(v);
            }}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
                e.preventDefault();
                send(input);
                return;
              }
              // Left from an empty box leaves the assistant: close it and hand focus back to the list.
              if (e.key === "ArrowLeft" && !input) {
                e.preventDefault();
                (e.target as HTMLTextAreaElement).blur();
                focus.toContent();
                if (onClose) onClose();
              }
            }}
            rows={1}
            placeholder={notConfigured ? "Add an API key in Settings → AI first" : onAddContext ? "Ask about your mail, @ for context" : "Ask about your mail, or tell me what to write…"}
            disabled={!!notConfigured}
            className="flex-1 resize-none overflow-y-auto bg-transparent outline-none text-[14px] leading-6 placeholder:text-muted-foreground"
          />
          {busy ? (
            <Button type="button" size="icon-sm" variant="ghost" onClick={stop} aria-label="Stop"><Square className="size-3.5" /></Button>
          ) : (
            <Button type="submit" size="icon-sm" disabled={!input.trim() || !!notConfigured} aria-label="Send"><ArrowUp /></Button>
          )}
        </div>
        </div>
        <div className="text-[11px] text-muted-foreground mt-1.5 px-1">Drafts are never sent without you{settings.data?.auto_send ? ", unless you allowed it in Settings → AI" : ""}. Enter to send, Shift+Enter for a new line.</div>
      </form>
    </div>
  );
}
