import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import DOMPurify from "dompurify";
import { Bold, CalendarDays, ChevronLeft, ChevronRight, Heading2, Italic, Link2, List, NotebookPen, RemoveFormatting } from "lucide-react";
import { toast } from "sonner";
import type { CalendarDay } from "@shared/types";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useJournal, useJournalIndex, useJournalMutation } from "../api";
import { EmptyState, ErrorState, SkeletonRows } from "../components/EmptyState";
import { useItemCursor } from "../lib/cardKeys";
import { longDayLabel, relativeDay, todayKey } from "../lib/caldate";


const SAVE_DEBOUNCE_MS = 900;
/** A pasted image rides in the entry as a data: URI, and the whole entry is capped at 500k chars. */
const MAX_IMAGE_BYTES = 250_000;

const ALLOWED_TAGS = ["p", "div", "br", "hr", "h1", "h2", "h3", "strong", "b", "em", "i", "u", "s", "strike", "ul", "ol", "li", "a", "blockquote", "code", "pre", "img", "span"];
const ALLOWED_ATTR = ["href", "target", "rel", "src", "alt", "title"];

/**
 * The entry round-trips through the server as HTML, so it is sanitized on the way in *and* on the
 * way out: what we read out of the contentEditable can contain anything that was ever pasted into
 * it, and what comes back down could have been written by an older, laxer client.
 */
export function sanitizeJournalHtml(html: string): string {
  return DOMPurify.sanitize(html, { ALLOWED_TAGS, ALLOWED_ATTR, ALLOW_DATA_ATTR: false, ALLOW_UNKNOWN_PROTOCOLS: false });
}

/* ---------------------------------- index ---------------------------------- */

function JournalIndex() {
  const q = useJournalIndex();
  const nav = useNavigate();
  const list = q.data ?? [];
  const { cursor } = useItemCursor({ count: list.length, onOpen: (i) => list[i] && nav(`/journal/${list[i].date}`) });
  const today = todayKey();

  return (
    <div className="max-w-2xl mx-auto px-1">
      <header className="flex items-end justify-between gap-4 pb-3 mb-1 border-b border-border">
        <div className="min-w-0">
          <h1 className="text-[15px] font-semibold tracking-[-0.01em] text-foreground">Journal</h1>
          <p className="text-[12px] text-muted-foreground mt-0.5">One entry a day. Nobody reads it but you.</p>
        </div>
        <Button asChild variant="ghost" size="sm" className="text-muted-foreground shrink-0">
          <Link to={`/journal/${today}`}>
            <NotebookPen /> Today
          </Link>
        </Button>
      </header>

      {q.error && <ErrorState error={q.error} onRetry={() => q.refetch()} />}
      {q.isLoading && <SkeletonRows rows={5} compact />}
      {!q.isLoading && !q.error && list.length === 0 && (
        <EmptyState
          icon={<NotebookPen />}
          title="Nothing written down yet."
          body="A line about the day is enough. It'll sit beside that day in the calendar forever."
          action={
            <Button asChild variant="outline" size="sm">
              <Link to={`/journal/${today}`}>Write today's</Link>
            </Button>
          }
        />
      )}

      <div>
        {list.map((e, i) => (
          <div key={e.date} data-item-index={i} data-focused={cursor === i || undefined}>
            <Link
              to={`/journal/${e.date}`}
              className={cn(
                "block px-2 py-3 border-b border-border scroll-mt-20 hover:bg-muted/60 transition-colors duration-100",
                cursor === i && "bg-muted",
              )}
            >
              <div className="flex items-baseline gap-2 min-w-0">
                <span className="text-[13px] font-medium text-foreground">{longDayLabel(e.date)}</span>
                {e.label && <span className="text-[12px] text-muted-foreground truncate">{e.label}</span>}
                <span className="flex-1" />
                {relativeDay(e.date) && <span className="text-[11px] text-tertiary shrink-0">{relativeDay(e.date)}</span>}
              </div>
              {e.excerpt && <p className="mt-1 text-[12.5px] leading-[1.55] text-muted-foreground line-clamp-2">{e.excerpt}</p>}
            </Link>
          </div>
        ))}
      </div>
    </div>
  );
}

/* ---------------------------------- entry ---------------------------------- */

type Status = { text: string; on: boolean };

interface Marks {
  bold: boolean;
  italic: boolean;
  ul: boolean;
  h2: boolean;
}

const NO_MARKS: Marks = { bold: false, italic: false, ul: false, h2: false };

function readMarks(): Marks {
  const state = (c: string) => {
    try {
      return document.queryCommandState(c);
    } catch {
      return false;
    }
  };
  let block = "";
  try {
    block = (document.queryCommandValue("formatBlock") || "").toLowerCase();
  } catch {
    block = "";
  }
  return { bold: state("bold"), italic: state("italic"), ul: state("insertUnorderedList"), h2: block === "h2" };
}

function readDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result ?? ""));
    r.onerror = () => reject(r.error ?? new Error("Couldn't read that image"));
    r.readAsDataURL(file);
  });
}

function ToolButton({ label, onClick, active, children }: { label: string; onClick: () => void; active?: boolean; children: React.ReactNode }) {
  return (
    <button
      type="button"
      aria-label={label}
      aria-pressed={active}
      // Mousedown must not steal the selection the command is about to act on.
      onMouseDown={(e) => e.preventDefault()}
      onClick={onClick}
      className={cn(
        "size-6 rounded-[4px] inline-flex items-center justify-center text-muted-foreground hover:text-foreground hover:bg-muted transition-colors",
        active && "bg-muted text-foreground",
      )}
    >
      {children}
    </button>
  );
}

function JournalEntry({ date }: { date: string }) {
  const q = useJournal(date);
  const indexQ = useJournalIndex();
  const mutation = useJournalMutation();
  const mutRef = useRef(mutation);
  mutRef.current = mutation;

  const editorRef = useRef<HTMLDivElement>(null);
  const wrapRef = useRef<HTMLDivElement>(null);
  const loadedFor = useRef<string | null>(null);
  const dirty = useRef(false);
  const savedRange = useRef<Range | null>(null);

  const [beat, setBeat] = useState(0);
  const [status, setStatus] = useState<Status>({ text: "", on: false });
  const [bar, setBar] = useState<{ top: number; left: number } | null>(null);
  const [marks, setMarks] = useState<Marks>(NO_MARKS);
  const [linkOpen, setLinkOpen] = useState(false);
  const [linkUrl, setLinkUrl] = useState("");

  /* --- neighbours, for the ‹ › arrows --- */
  const dates = useMemo(() => (indexQ.data ?? []).map((d) => d.date).sort((a, b) => (a < b ? 1 : -1)), [indexQ.data]);
  const older = dates.find((d) => d < date);
  const newer = [...dates].reverse().find((d) => d > date);

  /* --- load --- */
  useEffect(() => {
    const el = editorRef.current;
    if (!el || !q.data || q.data.date !== date || loadedFor.current === date) return;
    el.innerHTML = sanitizeJournalHtml(q.data.journal_html || "");
    loadedFor.current = date;
    dirty.current = false;
    setStatus({ text: "", on: false });
  }, [q.data, date]);

  /* --- save --- */
  const flush = useCallback(async () => {
    const el = editorRef.current;
    if (!el || !dirty.current || loadedFor.current !== date) return;
    const html = sanitizeJournalHtml(el.innerHTML);
    dirty.current = false;
    setStatus({ text: "Saving…", on: true });
    try {
      await mutRef.current.mutateAsync({ date, journal_html: html });
      setStatus({ text: "Saved", on: true });
    } catch (e) {
      dirty.current = true;
      setStatus({ text: (e as Error).message || "Couldn't save", on: true });
    }
  }, [date]);

  // Debounced autosave. `beat` ticks on every keystroke; the cleanup cancels the pending save.
  useEffect(() => {
    if (!dirty.current) return;
    const t = window.setTimeout(() => void flush(), SAVE_DEBOUNCE_MS);
    return () => window.clearTimeout(t);
  }, [beat, flush]);

  // `flush` is keyed to one date, so this cleanup fires both on unmount and when you walk to
  // another day — either way the text that's on screen is written before it leaves.
  useEffect(() => {
    const pending = flush;
    return () => void pending();
  }, [flush]);

  // "Saved" says its piece and gets out of the way.
  useEffect(() => {
    if (status.text !== "Saved" || !status.on) return;
    const t = window.setTimeout(() => setStatus((s) => ({ ...s, on: false })), 2400);
    return () => window.clearTimeout(t);
  }, [status]);

  const markDirty = () => {
    dirty.current = true;
    setBeat((b) => b + 1);
  };

  /**
   * Formatting runs through `document.execCommand`. It is deprecated, but it is also the only
   * rich-text primitive every browser still implements the same way, and it is what the app's
   * composer already uses — a journal box does not justify shipping a whole editor framework
   * (ProseMirror, Lexical, Tiptap) to do bold, a heading and a bullet list.
   */
  const exec = (cmd: string, val?: string) => {
    editorRef.current?.focus();
    document.execCommand(cmd, false, val);
    setMarks(readMarks());
    markDirty();
  };

  /* --- floating toolbar --- */
  useEffect(() => {
    const onSelect = () => {
      if (linkOpen) return;
      const el = editorRef.current;
      const wrap = wrapRef.current;
      const sel = window.getSelection();
      if (!el || !wrap || !sel || sel.rangeCount === 0 || sel.isCollapsed || !el.contains(sel.anchorNode)) {
        setBar(null);
        return;
      }
      const r = sel.getRangeAt(0).getBoundingClientRect();
      if (!r.width && !r.height) {
        setBar(null);
        return;
      }
      const box = wrap.getBoundingClientRect();
      setBar({ top: r.top - box.top - 38, left: Math.min(Math.max(r.left - box.left + r.width / 2, 90), Math.max(box.width - 90, 90)) });
      setMarks(readMarks());
    };
    document.addEventListener("selectionchange", onSelect);
    return () => document.removeEventListener("selectionchange", onSelect);
  }, [linkOpen]);

  const openLink = () => {
    const sel = window.getSelection();
    savedRange.current = sel && sel.rangeCount ? sel.getRangeAt(0).cloneRange() : null;
    setLinkUrl("");
    setLinkOpen(true);
  };
  const applyLink = () => {
    const url = linkUrl.trim();
    setLinkOpen(false);
    if (!url) return;
    const href = /^[a-z][a-z0-9+.-]*:/i.test(url) ? url : `https://${url}`;
    editorRef.current?.focus();
    if (savedRange.current) {
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(savedRange.current);
    }
    document.execCommand("createLink", false, href);
    markDirty();
  };

  /* --- paste --- */
  const insertImages = async (files: File[]) => {
    const sel = window.getSelection();
    let range = sel && sel.rangeCount ? sel.getRangeAt(0).cloneRange() : null;
    for (const f of files) {
      if (f.size > MAX_IMAGE_BYTES) {
        toast.error("That image is too big to keep in an entry — under 250 KB, please.");
        continue;
      }
      const url = await readDataUrl(f);
      editorRef.current?.focus();
      if (range) {
        const s = window.getSelection();
        s?.removeAllRanges();
        s?.addRange(range);
        range = null;
      }
      document.execCommand("insertHTML", false, `<img src="${url}" alt="">`);
    }
    markDirty();
  };

  const onPaste = (e: React.ClipboardEvent<HTMLDivElement>) => {
    const files = Array.from(e.clipboardData.files ?? []).filter((f) => f.type.startsWith("image/"));
    if (files.length) {
      e.preventDefault();
      void insertImages(files);
      return;
    }
    const html = e.clipboardData.getData("text/html");
    if (html) {
      // Never let a page's markup land in the editor as-is; it is about to become our stored HTML.
      e.preventDefault();
      document.execCommand("insertHTML", false, sanitizeJournalHtml(html));
      markDirty();
    }
  };

  const rel = relativeDay(date);

  return (
    <div className="max-w-2xl mx-auto px-1 pb-24">
      <header className="pb-3 mb-4 border-b border-border">
        <div className="flex items-center gap-1 flex-wrap">
          <Button asChild variant="ghost" size="icon-xs" className={cn("text-muted-foreground", !older && "invisible")} aria-label="Previous entry">
            <Link to={`/journal/${older ?? date}`}>
              <ChevronLeft />
            </Link>
          </Button>
          <Button asChild variant="ghost" size="icon-xs" className={cn("text-muted-foreground", !newer && "invisible")} aria-label="Next entry">
            <Link to={`/journal/${newer ?? date}`}>
              <ChevronRight />
            </Link>
          </Button>
          <div className="min-w-0 ml-1">
            <h1 className="text-[15px] font-semibold tracking-[-0.01em] text-foreground truncate">
              {longDayLabel(date)}
              {rel && <span className="ml-2 text-[12px] font-normal text-muted-foreground">{rel}</span>}
            </h1>
            <p className="text-[12px] text-muted-foreground mt-0.5 truncate">{q.data?.label || "Whatever's worth remembering."}</p>
          </div>
          <span className="flex-1" />
          <span
            aria-live="polite"
            className={cn("text-[11px] text-tertiary tnum transition-opacity duration-700 mr-1", status.on ? "opacity-100" : "opacity-0")}
          >
            {status.text || "Saved"}
          </span>
          <Button asChild variant="ghost" size="sm" className="text-muted-foreground shrink-0">
            <Link to={`/calendar?d=${date}`}>
              <CalendarDays /> <span className="hidden sm:inline">In the calendar</span>
            </Link>
          </Button>
        </div>
      </header>

      {q.error && <ErrorState error={q.error} onRetry={() => q.refetch()} />}
      {q.isLoading && <SkeletonRows rows={4} compact />}

      <div ref={wrapRef} className={cn("relative", q.isLoading && "hidden")}>
        {bar && (
          <div
            style={{ top: bar.top, left: bar.left }}
            className="absolute z-30 -translate-x-1/2 flex items-center gap-0.5 rounded-md border border-border bg-background p-1 shadow-sm"
          >
            {linkOpen ? (
              <form
                className="flex items-center gap-1"
                onSubmit={(e) => {
                  e.preventDefault();
                  applyLink();
                }}
              >
                <Input
                  autoFocus
                  value={linkUrl}
                  onChange={(e) => setLinkUrl(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Escape") setLinkOpen(false);
                  }}
                  placeholder="https://"
                  className="h-6 w-48 text-[12px]"
                />
                <Button type="submit" size="xs" disabled={!linkUrl.trim()}>
                  Link
                </Button>
              </form>
            ) : (
              <>
                <ToolButton label="Bold" active={marks.bold} onClick={() => exec("bold")}>
                  <Bold size={13} />
                </ToolButton>
                <ToolButton label="Italic" active={marks.italic} onClick={() => exec("italic")}>
                  <Italic size={13} />
                </ToolButton>
                <ToolButton label="Heading" active={marks.h2} onClick={() => exec("formatBlock", marks.h2 ? "p" : "h2")}>
                  <Heading2 size={13} />
                </ToolButton>
                <ToolButton label="Bulleted list" active={marks.ul} onClick={() => exec("insertUnorderedList")}>
                  <List size={13} />
                </ToolButton>
                <ToolButton label="Link" onClick={openLink}>
                  <Link2 size={13} />
                </ToolButton>
                <ToolButton label="Clear formatting" onClick={() => exec("removeFormat")}>
                  <RemoveFormatting size={13} />
                </ToolButton>
              </>
            )}
          </div>
        )}

        <div
          ref={editorRef}
          contentEditable
          suppressContentEditableWarning
          role="textbox"
          aria-multiline="true"
          aria-label={`Journal entry for ${date}`}
          data-placeholder="How did it go?"
          onInput={markDirty}
          onBlur={() => void flush()}
          onPaste={onPaste}
          onKeyUp={() => setMarks(readMarks())}
          className={cn(
            "min-h-[55vh] outline-none text-[13px] leading-[1.7] text-foreground",
            "empty:before:content-[attr(data-placeholder)] empty:before:text-tertiary",
            "[&_h1]:text-[16px] [&_h1]:font-semibold [&_h1]:mt-4 [&_h1]:mb-1",
            "[&_h2]:text-[14px] [&_h2]:font-semibold [&_h2]:mt-4 [&_h2]:mb-1",
            "[&_h3]:text-[13px] [&_h3]:font-semibold [&_h3]:mt-3 [&_h3]:mb-1",
            "[&_p]:my-2 [&_a]:underline [&_a]:underline-offset-2",
            "[&_ul]:list-disc [&_ul]:pl-5 [&_ol]:list-decimal [&_ol]:pl-5 [&_li]:my-0.5",
            "[&_blockquote]:border-l-2 [&_blockquote]:border-border [&_blockquote]:pl-3 [&_blockquote]:text-muted-foreground",
            "[&_img]:max-w-full [&_img]:rounded-[4px] [&_img]:my-2",
          )}
        />
      </div>
    </div>
  );
}

export default function Journal() {
  const { date } = useParams<{ date?: string }>();
  const valid = !!date && /^\d{4}-\d{2}-\d{2}$/.test(date);
  if (date && !valid) return <JournalIndex />;
  // Keyed so walking to another day rebuilds the editor rather than reusing its DOM.
  return date ? <JournalEntry key={date} date={date} /> : <JournalIndex />;
}
