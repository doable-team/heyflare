import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useNavigate } from "react-router-dom";
import type { Bundle, ThreadSummary } from "@shared/types";
import { useBulkAction, useBundleMutations, type ThreadAction } from "../api";
import { useKeys } from "../lib/keys";
import { monthKey } from "../lib/format";
import { BulkBar } from "./BulkBar";
import { BundleRow } from "./BundleRow";
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
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [cursor, setCursor] = useState(-1);
  const [bubbleFor, setBubbleFor] = useState<string[] | null>(null);
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  const lastClick = useRef<string | null>(null);
  const nav = useNavigate();
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
    if (cursor >= all.length) setCursor(all.length - 1);
  }, [all, cursor]);

  const toggle = (id: string, shift: boolean) => {
    setSelected((s) => {
      const n = new Set(s);
      if (shift && lastClick.current) {
        const a = all.findIndex((t) => t.id === lastClick.current);
        const b = all.findIndex((t) => t.id === id);
        if (a >= 0 && b >= 0) {
          for (let i = Math.min(a, b); i <= Math.max(a, b); i++) n.add(all[i].id);
          return n;
        }
      }
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });
    lastClick.current = id;
  };

  const targets = () => (selected.size ? [...selected] : cursor >= 0 && all[cursor] ? [all[cursor].id] : []);

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

  const onQuick = (id: string, q: QuickAction) => {
    const t = all.find((x) => x.id === id);
    if (q === "reply_later") act([id], { action: "reply_later", on: !t?.reply_later }, t?.reply_later ? "Removed from Reply Later" : "Added to Reply Later", !t?.reply_later);
    else if (q === "set_aside") act([id], { action: "set_aside", on: !t?.set_aside }, t?.set_aside ? "Back in the Imbox" : "Set aside", !t?.set_aside);
    else if (q === "bubble_up") setBubbleFor([id]);
    else if (q === "trash") act([id], { action: "move", bucket: "trash" }, "Moved to trash");
  };

  useKeys(
    {
      j: () => setCursor((c) => Math.min(c + 1, all.length - 1)),
      k: () => setCursor((c) => Math.max(c - 1, 0)),
      ArrowDown: () => setCursor((c) => Math.min(c + 1, all.length - 1)),
      ArrowUp: () => setCursor((c) => Math.max(c - 1, 0)),
      Enter: () => cursor >= 0 && all[cursor] && nav(`/t/${all[cursor].id}`),
      o: () => cursor >= 0 && all[cursor] && nav(`/t/${all[cursor].id}`),
      x: () => cursor >= 0 && all[cursor] && toggle(all[cursor].id, false),
      l: () => act(targets(), { action: "reply_later", on: true }, "Added to Reply Later"),
      a: () => act(targets(), { action: "set_aside", on: true }, "Set aside"),
      z: () => { const ids = targets(); if (ids.length) setBubbleFor(ids); },
      "#": () => act(targets(), { action: "move", bucket: "trash" }, "Moved to trash"),
      u: () => act(targets(), { action: "mark_unread" }, undefined, false),
      Escape: () => setSelected(new Set()),
    },
    keysEnabled,
  );

  useEffect(() => {
    if (cursor < 0) return;
    const el = document.querySelector(`[data-thread-id="${all[cursor]?.id}"]`);
    el?.scrollIntoView({ block: "nearest" });
  }, [cursor, all]);

  if (error) return <ErrorState error={error} onRetry={onRetry} />;
  if (loading && all.length === 0) return <SkeletonRows compact={compact} />;

  let idx = 0;
  return (
    <div>
      {selected.size > 0 && <BulkBar selected={selected} threads={all} onClear={() => setSelected(new Set())} onAct={(a, msg, removes) => act([...selected], a, msg, removes)} />}
      {sections.map((s, si) => {
        const rows: ReactNode[] = [];
        let lastMonth = "";
        // Interleave bundles with threads by date; bundles are not selectable and don't take a cursor slot.
        const items: ({ kind: "thread"; t: ThreadSummary; at: number } | { kind: "bundle"; b: Bundle; at: number })[] = [
          ...s.threads.map((t) => ({ kind: "thread" as const, t, at: t.last_message_at })),
          ...(s.bundles ?? []).map((b) => ({ kind: "bundle" as const, b, at: b.last_message_at })),
        ];
        if (s.bundles?.length) items.sort((a, b) => b.at - a.at);
        for (const item of items) {
          if (item.kind === "bundle") {
            rows.push(<BundleRow key={"b" + item.b.id} bundle={item.b} compact={compact} onSeen={(b) => markSeen(b)} />);
            continue;
          }
          const t = item.t;
          const i = idx++;
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
              focused={i === cursor}
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
