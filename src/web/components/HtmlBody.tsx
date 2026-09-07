import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import DOMPurify from "dompurify";
import { ChevronDown, Scissors, ShieldCheck } from "lucide-react";
import { cn } from "@/lib/utils";
import { textToHtml } from "../lib/format";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { openExternalUrl } from "../lib/native";

DOMPurify.addHook("afterSanitizeAttributes", (node) => {
  if (node.tagName === "A") {
    node.setAttribute("target", "_blank");
    node.setAttribute("rel", "noopener noreferrer nofollow");
  }
});

// Elements that mail clients use to wrap the quoted history of a thread.
const QUOTE_SELECTOR = [".gmail_quote", "blockquote[type=cite]", ".yahoo_quoted", "#divRplyFwdMsg", "#appendonsend", ".moz-cite-prefix", ".protonmail_quote", "div[id^='yiv'] blockquote", ".hey-quote"].join(",");

/** Reads the app's current grayscale palette so the iframe can follow the theme. */
function readTheme() {
  const cs = getComputedStyle(document.documentElement);
  const get = (n: string, fb: string) => cs.getPropertyValue(n).trim() || fb;
  return {
    dark: document.documentElement.classList.contains("dark"),
    fg: get("--foreground", "#37352f"),
    bg: get("--background", "#ffffff"),
    muted: get("--muted-foreground", "rgba(55,53,47,.65)"),
    border: get("--border", "rgba(55,53,47,.09)"),
  };
}

function useTheme() {
  const [t, setT] = useState(readTheme);
  useEffect(() => {
    const mo = new MutationObserver(() => setT(readTheme()));
    mo.observe(document.documentElement, { attributes: true, attributeFilter: ["class", "data-theme"] });
    return () => mo.disconnect();
  }, []);
  return t;
}

/** True when the email paints its own backgrounds; then dark mode must not recolor it. */
function paintsOwnBackground(html: string): boolean {
  return /background(?:-color)?\s*:\s*(?!transparent|inherit|none)[^;"']+/i.test(html) || /\bbgcolor\s*=/i.test(html);
}

/** `#rrggbb`, `#rgb`, `rgb()` and `rgba()` to channels, compositing any alpha over `over`. */
function parseColor(c: string, over?: [number, number, number]): [number, number, number] | null {
  const hex = c.trim().match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
  if (hex) {
    const h = hex[1].length === 3 ? hex[1].replace(/./g, (d) => d + d) : hex[1];
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
  }
  const n = c.match(/-?\d*\.?\d+/g);
  if (!n || n.length < 3) return null;
  const [r, g, b] = n.slice(0, 3).map(Number);
  const a = n.length > 3 ? Number(n[3]) : 1;
  if (a >= 1 || !over) return [r, g, b];
  return [r, g, b].map((v, i) => v * a + over[i] * (1 - a)) as [number, number, number];
}

function luminance([r, g, b]: [number, number, number]): number {
  const f = (v: number) => {
    const x = v / 255;
    return x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
}

/** WCAG contrast ratio: 1 is invisible, 21 is black on white. */
export function contrastRatio(a: string, b: string): number {
  const back = parseColor(b);
  const front = parseColor(a, back ?? undefined);
  if (!front || !back) return 21;
  const [x, y] = [luminance(front), luminance(back)];
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}

/**
 * The line between "dim" and "gone". Deliberately below AA's 4.5: a sender's blue at 3.9 is
 * still readable and still theirs, while the black that prompted this sits at 1.2. Repainting
 * everything that merely falls short of AA would throw away colour the sender chose.
 */
const READABLE = 3;

/**
 * Senders write for a white page. A message that paints its own background gets a light slab,
 * but one that only sets text colours — `color:#000` on a paragraph, a `<font color>` — lands
 * on our dark page still wearing black, and disappears.
 *
 * Every element that names its own colour (it differs from the one it inherits, whatever the
 * source: inline, a `<style>` block, an attribute) is checked against the page it is being
 * read on. Anything that cannot be read there gives up its colour and takes ours. Colours that
 * are legible — a brand blue, a link, our own muted quote grey — are left alone.
 */
export function relightForDarkPage(doc: Document, pageBackground: string, foreground: string): number {
  let changed = 0;
  const colorOf = (el: Element) => doc.defaultView?.getComputedStyle(el).color ?? "";
  for (const el of Array.from(doc.body.querySelectorAll<HTMLElement>("*"))) {
    const own = colorOf(el);
    if (!own) continue;
    const parent = el.parentElement;
    // Inherited text is already ours; only a colour the sender chose is worth second-guessing.
    if (parent && colorOf(parent) === own) continue;
    if (contrastRatio(own, pageBackground) >= READABLE) continue;
    el.style.setProperty("color", foreground, "important");
    changed += 1;
  }
  return changed;
}

export function sanitizeEmailHtml(html: string): string {
  return DOMPurify.sanitize(html, {
    WHOLE_DOCUMENT: false,
    FORBID_TAGS: ["script", "iframe", "object", "embed", "form", "input", "button", "meta", "link", "base"],
    FORBID_ATTR: ["onerror", "onload", "onclick", "formaction"],
    ALLOW_UNKNOWN_PROTOCOLS: false,
  });
}

function baseStyle(t: ReturnType<typeof readTheme>, ownBg: boolean) {
  // Plain messages follow the app theme. Designed (painted) messages keep their light canvas.
  // The iframe's color-scheme must match the page, otherwise browsers paint an opaque white canvas in dark mode.
  const scheme = ownBg ? "light" : t.dark ? "dark" : "light";
  const fg = ownBg ? "#37352f" : t.fg;
  const muted = ownBg ? "rgba(55,53,47,.65)" : t.muted;
  const border = ownBg ? "rgba(55,53,47,.12)" : t.border;
  return `
  html{color-scheme:${scheme};}
  html,body{margin:0;padding:0;background:transparent;}
  body{display:flow-root;font-family:"Geist Variable",Geist,system-ui,-apple-system,sans-serif;font-size:14px;line-height:1.6;color:${fg};word-wrap:break-word;overflow-wrap:anywhere;}
  img{max-width:100% !important;height:auto;}
  table{max-width:100% !important;}
  a{color:${fg};text-decoration:underline;text-underline-offset:2px;}
  blockquote{border-left:2px solid ${border};margin:.5em 0;padding-left:1em;color:${muted};}
  pre{white-space:pre-wrap;font-family:"Geist Mono Variable","Geist Mono",ui-monospace,Menlo,monospace;font-size:12.5px;}
  ::selection{background:${fg};color:${ownBg ? "#ffffff" : t.bg};}
  .hey-quoted-hidden{display:none !important;}
`;
}

/** Renders email HTML in a sandboxed iframe that auto-sizes to its content. */
export function HtmlBody({
  html,
  text,
  trackers = [],
  onClip,
  plain,
  collapseQuotes = true,
  className,
}: {
  html: string;
  text?: string;
  trackers?: string[];
  onClip?: (text: string) => void;
  plain?: boolean;
  /** Hide the quoted history of the thread behind a "Show quoted text" toggle. */
  collapseQuotes?: boolean;
  className?: string;
}) {
  const ref = useRef<HTMLIFrameElement>(null);
  const [height, setHeight] = useState(48);
  const [ready, setReady] = useState(false);
  const [sel, setSel] = useState<{ text: string; x: number; y: number } | null>(null);
  const [quoted, setQuoted] = useState<{ count: number; shown: boolean }>({ count: 0, shown: false });
  const theme = useTheme();

  const usePlain = plain || !html;
  const ownBg = !usePlain && paintsOwnBackground(html);
  // Painted emails get a light slab only in dark mode; everything else sits directly on the page.
  const slab = ownBg && theme.dark;

  const srcdoc = useMemo(() => {
    const body = usePlain ? `<div style="white-space:pre-wrap">${sanitizeEmailHtml(textToHtml(text || ""))}</div>` : sanitizeEmailHtml(html);
    return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><style>${baseStyle(theme, ownBg)}</style></head><body>${body}</body></html>`;
  }, [html, text, usePlain, ownBg, theme]);

  const resize = useCallback(() => {
    const doc = ref.current?.contentDocument;
    if (!doc?.body) return;
    const h = Math.max(doc.body.getBoundingClientRect().height, doc.body.offsetHeight, doc.body.scrollHeight);
    if (h > 0) setHeight(Math.min(Math.ceil(h) + 2, 20000));
  }, []);

  const applyQuotes = useCallback((show: boolean) => {
    const doc = ref.current?.contentDocument;
    if (!doc) return 0;
    const nodes = Array.from(doc.querySelectorAll<HTMLElement>(QUOTE_SELECTOR));
    const top = nodes.filter((n) => !nodes.some((o) => o !== n && o.contains(n)));
    for (const n of top) n.classList.toggle("hey-quoted-hidden", !show);
    return top.length;
  }, []);

  const onLoad = useCallback(() => {
    const doc = ref.current?.contentDocument;
    if (!doc) return;
    if (collapseQuotes && !usePlain) {
      // Start collapsed: pass the *current* state, not its inverse (that left the quotes visible
      // while the button still said "Show quoted text", so the first click appeared to do nothing).
      const count = applyQuotes(quoted.shown);
      setQuoted((q) => ({ count, shown: q.shown }));
    }
    // Only for messages sitting on our dark page; painted ones already have their light slab.
    if (theme.dark && !ownBg && !usePlain) relightForDarkPage(doc, theme.bg, theme.fg);
    resize();
    setReady(true);
    try {
      const ro = new ResizeObserver(() => resize());
      if (doc.body) ro.observe(doc.body);
    } catch {
      /* ignore */
    }
    doc.querySelectorAll("img").forEach((img) => img.addEventListener("load", resize));
    setTimeout(resize, 300);
    setTimeout(resize, 1500);
    if (onClip) {
      const handler = () => {
        const s = doc.getSelection();
        const t = s?.toString().trim() ?? "";
        if (!t || !s || s.rangeCount === 0) {
          setSel(null);
          return;
        }
        const rect = s.getRangeAt(0).getBoundingClientRect();
        setSel({ text: t, x: rect.left + rect.width / 2, y: rect.top });
      };
      doc.addEventListener("selectionchange", handler);
      doc.addEventListener("mouseup", handler);
    }

    // Links inside the sandbox can't navigate the top frame, and the Mac webview swallows
    // window.open — so intercept the click and hand the URL to the system browser.
    doc.querySelectorAll<HTMLAnchorElement>("a[href]").forEach((a) => {
      a.setAttribute("target", "_blank");
      a.setAttribute("rel", "noopener noreferrer");
    });
    doc.addEventListener("click", (ev) => {
      const target = ev.target as HTMLElement | null;
      const a = target?.closest?.("a[href]") as HTMLAnchorElement | null;
      if (!a) return;
      const raw = (a.getAttribute("href") ?? "").trim();
      if (!raw || raw.startsWith("#") || /^(javascript|data|cid|blob):/i.test(raw)) {
        ev.preventDefault();
        return;
      }
      let href: string;
      if (/^(mailto|tel):/i.test(raw)) {
        href = raw;
      } else {
        try {
          href = new URL(raw, location.href).toString();
        } catch {
          ev.preventDefault();
          return;
        }
      }
      ev.preventDefault();
      openExternalUrl(href);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [resize, onClip, collapseQuotes, usePlain, applyQuotes, theme, ownBg]);

  useEffect(() => {
    const onWin = () => resize();
    window.addEventListener("resize", onWin);
    return () => window.removeEventListener("resize", onWin);
  }, [resize]);

  const toggleQuotes = () => {
    const show = !quoted.shown;
    applyQuotes(show);
    setQuoted((q) => ({ ...q, shown: show }));
    setTimeout(resize, 30);
  };

  return (
    <div className={cn("relative", className)}>
      {trackers.length > 0 && (
        <div className="mb-2">
          <Badge variant="secondary" className="max-w-full font-normal text-muted-foreground" title={trackers.join(", ")}>
            <ShieldCheck />
            <span className="truncate">
              Blocked {trackers.length} tracker{trackers.length === 1 ? "" : "s"} · {trackers.slice(0, 2).join(", ")}
              {trackers.length > 2 ? ` +${trackers.length - 2}` : ""}
            </span>
          </Badge>
        </div>
      )}
      <div className={cn("relative overflow-hidden", slab && "rounded-md bg-white px-3 py-2", !ready && "opacity-0")} style={{ minHeight: ready ? undefined : 48 }}>
        <iframe
          ref={ref}
          title="message"
          className="email-body"
          sandbox="allow-same-origin allow-popups allow-popups-to-escape-sandbox"
          srcDoc={srcdoc}
          onLoad={onLoad}
          style={{ height, colorScheme: slab ? "light" : "normal" }}
        />
      </div>
      {!ready && (
        <div className="absolute inset-x-0 top-0 space-y-2 pt-1">
          <Skeleton className="h-3 w-4/5" />
          <Skeleton className="h-3 w-3/5" />
        </div>
      )}
      {quoted.count > 0 && (
        <Button variant="ghost" size="xs" className="mt-2 text-muted-foreground" onClick={toggleQuotes}>
          <ChevronDown className={cn("transition-transform", quoted.shown && "rotate-180")} />
          {quoted.shown ? "Hide quoted text" : "Show quoted text"}
        </Button>
      )}
      {sel && onClip && (
        <Button
          size="xs"
          className="absolute z-10 -translate-x-1/2 -translate-y-full shadow-md"
          style={{ left: sel.x, top: Math.max(sel.y - 6, 0) + (trackers.length ? 28 : 0) }}
          onMouseDown={(e) => e.preventDefault()}
          onClick={() => {
            onClip(sel.text);
            setSel(null);
            ref.current?.contentDocument?.getSelection()?.removeAllRanges();
          }}
        >
          <Scissors /> Save clip
        </Button>
      )}
    </div>
  );
}
