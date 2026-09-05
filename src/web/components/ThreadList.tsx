import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useNavigate } from "react-router-dom";
import type { Bundle, ThreadSummary } from "@shared/types";
import { useBulkAction, useBundleMutations, type ThreadAction } from "../api";
import { useKeys } from "../lib/keys";
import { useFocusRegion } from "../lib/focusStore";
import { scrollPageBy } from "../lib/cardKeys";
import { monthKey } from "../lib/format";
import { BulkBar } from "./BulkBar";
import { BundleRow, bundleHref } from "./BundleRow";
import { ThreadRow, type QuickAction } from "./ThreadRow";
import { DateTimePicker } from "./DatePicker";
import { EmptyState, ErrorState, SectionTitle, SkeletonRows } from "./EmptyState";
import { Modal } from "./Modal";
import { useToast } from "./Toast";
import { Button } from "@/components/ui/button";
import { Loader2 } from "lucide-react";

interface Section {
  title?: ReactNode;
  threads: ThreadSummary[];
  /** Bundled senders interleaved with the threads by date (HEY Bundles). */
  bundles?: Bundle[];
  emptyTitle?: string;
  emptyBody?: ReactNode;
  emptyIllustration?: ReactNode;
  /** Custom empty rendering for this section (e.g. the Imbox hero). */
  emptyNode?: ReactNode;
  actions?: ReactNode;
}

const OUT_MS = 240;

type Item = { kind: "thread"; t: ThreadSummary; at: number } | { kind: "bundle"; b: Bundle; at: number };

/** DOM hook shared by thread and bundle rows so the cursor can scroll either into view. */
const rowId = (i: Item) => (i.kind === "thread" ? i.t.id : `b:${i.b.id}`);

/**
 * Selectable, keyboard-navigable list. Accepts one or more sections that share
 * one selection + cursor (so Imbox "New" and "Previously seen" act as one list).
 */
export function ThreadList({
  sections,
  loading,
  error,
  onRetry,
  compact,
  groupByMonth,
  showBucket,
  emptyIcon,
  emptyIllustration,
  keysEnabled = true,
  footer,
  quickActions = true,
}: {
  sections: Section[];
  loading?: boolean;
  error?: unknown;
  onRetry?: () => void;
  compact?: boolean;
  groupByMonth?: boolean;
  showBucket?: boolean;
  emptyIcon?: ReactNode;
  emptyIllustration?: ReactNode;
  keysEnabled?: boolean;
  footer?: ReactNode;
  quickActions?: boolean;
}) {
  const all = useMemo(() => sections.flatMap((s) => s.threads), [sections]);
  // Threads + bundles interleaved by date, per section — the exact order rendered below, so the
  // keyboard cursor and the screen never disagree.
  const sectionItems = useMemo(
    () =>
      sections.map((s) => {
        const items: Item[] = [
          ...s.threads.map((t) => ({ kind: "thread" as const, t, at: t.last_message_at })),
          ...(s.bundles ?? []).map((b) => ({ kind: "bundle" as const, b, at: b.last_message_at })),
        ];
        if (s.bundles?.length) items.sort((x, y) => y.at - x.at);
        return items;
      }),
    [sections],
  );
  const items = useMemo(() => sectionItems.flat(), [sectionItems]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [cursor, setCursor] = useState(-1);
  const [bubbleFor, setBubbleFor] = useState<string[] | null>(null);
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  const lastClick = useRef<string | null>(null);
  const nav = useNavigate();
  const region = useFocusRegion();
  const bulk = useBulkAction();
  const { toast } = useToast();
  const bundleM = useBundleMutations();
  const markSeen = (b: Bundle) => bundleM.seen.mutate(b.id, { onSuccess: () => toast(`Marked ${b.name || b.email} as seen`) });

  // Drop selection entries that vanished.
  useEffect(() => {
    setSelected((s) => {
      const next = new Set([...s].filter((id) => all.some((t) => t.id === id)));
      return next.size === s.size ? s : next;
    });
  }, [all]);

  useEffect(() => {
    if (cursor >= items.length) setCursor(items.length - 1);
  }, [items, cursor]);

  // The row callbacks read the latest list and action through refs and are created once. Rows are
  // memoised, and a poll that changes nothing hands back the very same thread objects (the query
  // client shares structure), so with stable callbacks an unchanged row does not render at all —
  // rather than all four hundred of them re-rendering every minute.
  const allRef = useRef(all);
  allRef.current = all;
  const toggle = useCallback((id: string, shift: boolean) => {
    const list = allRef.current;
    setSelected((s) => {
      const n = new Set(s);
      if (shift && lastClick.current) {
        const a = list.findIndex((t) => t.id === lastClick.current);
        const b = list.findIndex((t) => t.id === id);
        if (a >= 0 && b >= 0) {
          for (let i = Math.min(a, b); i <= Math.max(a, b); i++) n.add(list[i].id);
          return n;
        }
      }
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });
    lastClick.current = id;
  }, []);

  const cur = cursor >= 0 ? items[cursor] : undefined;
  const curThread = cur?.kind === "thread" ? cur.t : undefined;
  // Bundles take a cursor slot but no thread actions: with one focused, targets() is empty and act() no-ops.
  const targets = () => (selected.size ? [...selected] : curThread ? [curThread.id] : []);

  /** Animate rows out, then run the mutation. */
  const act = useCallback(
    (ids: string[], a: ThreadAction, msg?: string, removes = true) => {
      if (!ids.length) return;
      const fire = () =>
        bulk.mutate({ thread_ids: ids, ...a }, {
          onSuccess: () => msg && toast(msg, { kind: "success" }),
          onError: (e) => toast((e as Error).message, { kind: "error" }),
          onSettled: () => setLeaving((l) => { const n = new Set(l); ids.forEach((id) => n.delete(id)); return n; }),
        });
      setSelected(new Set());
      if (removes) {
        setLeaving((l) => new Set([...l, ...ids]));
        window.setTimeout(fire, OUT_MS);
      } else fire();
    },
    [bulk, toast],
  );

  const actRef = useRef(act);
  actRef.current = act;
  const onQuick = useCallback((id: string, q: QuickAction) => {
    const t = allRef.current.find((x) => x.id === id);
    const act = actRef.current;
    if (q === "reply_later") act([id], { action: "reply_later", on: !t?.reply_later }, t?.reply_later ? "Removed from Reply Later" : "Added to Reply Later", !t?.reply_later);
    else if (q === "set_aside") act([id], { action: "set_aside", on: !t?.set_aside }, t?.set_aside ? "Back in the Imbox" : "Set aside", !t?.set_aside);
    else if (q === "bubble_up") setBubbleFor([id]);
    else if (q === "trash") act([id], { action: "move", bucket: "trash" }, "Moved to trash");
  }, []);

  const open = () => {
    if (!cur) return;
    nav(cur.kind === "thread" ? `/t/${cur.t.id}` : bundleHref(cur.b));
  };

  // With nothing to walk (an empty list), the arrows scroll the page instead of doing nothing.
  const step = (delta: number) => {
    if (!items.length) {
      scrollPageBy(delta * 0.25);
      return;
    }
    setCursor((c) => Math.min(Math.max(c + delta, 0), items.length - 1));
  };

  useKeys(
    {
      j: () => step(1),
      k: () => step(-1),
      ArrowDown: () => step(1),
      ArrowUp: () => step(-1),
      Enter: () => open(),
      o: () => open(),
      x: () => curThread && toggle(curThread.id, false),
      l: () => act(targets(), { action: "reply_later", on: true }, "Added to Reply Later"),
      a: () => act(targets(), { action: "set_aside", on: true }, "Set aside"),
      z: () => { const ids = targets(); if (ids.length) setBubbleFor(ids); },
      "#": () => act(targets(), { action: "move", bucket: "trash" }, "Moved to trash"),
      u: () => act(targets(), { action: "mark_unread" }, undefined, false),
      Escape: () => setSelected(new Set()),
    },
    // While the sidebar owns the arrows, the list stays put.
    keysEnabled && region === "content",
  );

  useEffect(() => {
    const it = cursor >= 0 ? items[cursor] : undefined;
    if (!it) return;
    document.querySelector(`[data-row-id="${rowId(it)}"]`)?.scrollIntoView({ block: "nearest" });
  }, [cursor, items]);

  if (error) return <ErrorState error={error} onRetry={onRetry} />;
  if (loading && all.length === 0) return <SkeletonRows compact={compact} />;

  let idx = 0;
  return (
    <div>
      {selected.size > 0 && <BulkBar selected={selected} threads={all} onClear={() => setSelected(new Set())} onAct={(a, msg, removes) => act([...selected], a, msg, removes)} />}
      {sections.map((s, si) => {
        const rows: ReactNode[] = [];
        let lastMonth = "";
        for (const item of sectionItems[si]) {
          const i = idx++;
          if (item.kind === "bundle") {
            rows.push(
              <BundleRow
                key={"b" + item.b.id}
                bundle={item.b}
                compact={compact}
                focused={i === cursor && region === "content"}
                onSeen={(b) => markSeen(b)}
              />,
            );
            continue;
          }
          const t = item.t;
          if (groupByMonth) {
            const m = monthKey(t.last_message_at);
            if (m !== lastMonth) {
              lastMonth = m;
              rows.push(
                <div key={"m" + m} className="sticky top-11 z-10 bg-background/95 backdrop-blur text-xs font-medium text-muted-foreground h-8 flex items-center px-2 mt-2">
                  {m}
                </div>,
              );
            }
          }
          rows.push(
            <ThreadRow
              key={t.id}
              thread={t}
              selected={selected.has(t.id)}
              focused={i === cursor && region === "content"}
              onSelect={toggle}
              compact={compact}
              showBucket={showBucket}
              leaving={leaving.has(t.id)}
              onQuickAction={onQuick}
              quickActions={quickActions}
            />,
          );
        }
        return (
          <section key={si} className={si > 0 ? "mt-6" : ""}>
            {s.title && (
              <SectionTitle count={s.threads.length + (s.bundles?.length ?? 0)} actions={s.actions}>
                {s.title}
              </SectionTitle>
            )}
            {s.threads.length === 0 && !(s.bundles?.length) ? (
              s.emptyNode ? (
                s.emptyNode
              ) : s.emptyTitle ? (
                <EmptyState illustration={s.emptyIllustration ?? emptyIllustration} icon={emptyIcon} title={s.emptyTitle} body={s.emptyBody} compact={si > 0 || sections.length > 1} />
              ) : (
                <div className="text-[13px] text-muted-foreground px-2 py-3">Nothing here.</div>
              )
            ) : (
              <div className={cxDivide(compact)}>{rows}</div>
            )}
          </section>
        );
      })}
      {footer}
      <Modal open={!!bubbleFor} onClose={() => setBubbleFor(null)} title="Bubble up" subtitle="Out of sight until the moment you pick." size="sm">
        <DateTimePicker
          embedded
          onPick={(at) => {
            const ids = bubbleFor ?? [];
            setBubbleFor(null);
            act(ids, { action: "bubble_up", at }, "Will bubble up later");
          }}
          onCancel={() => setBubbleFor(null)}
        />
      </Modal>
    </div>
  );
}

function cxDivide(_compact?: boolean) {
  return "";
}

export function LoadMore({ hasMore, loading, onMore }: { hasMore: boolean; loading: boolean; onMore: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!hasMore || loading) return;
    const el = ref.current;
    if (!el) return;
    const io = new IntersectionObserver((es) => es[0]?.isIntersecting && onMore(), { rootMargin: "400px" });
    io.observe(el);
    return () => io.disconnect();
  }, [hasMore, loading, onMore]);
  if (!hasMore && !loading) return null;
  return (
    <div ref={ref} className="py-6 text-center text-[13px] text-muted-foreground">
      {loading ? (
        <span className="inline-flex items-center gap-2"><Loader2 className="size-3.5 animate-spin" /> Loading more…</span>
      ) : (
        <Button variant="ghost" size="sm" onClick={onMore}>Load more</Button>
      )}
    </div>
  );
}
