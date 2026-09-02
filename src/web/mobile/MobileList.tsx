import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowUpCircle, Bookmark, Clock, FileText, Inbox, Rss, Trash2, FolderInput, Mail } from "lucide-react";
import { toast } from "sonner";
import type { Bundle, ThreadSummary } from "@shared/types";
import { cn } from "@/lib/utils";
import { useBulkAction, type ThreadAction } from "../api";
import { monthKey } from "../lib/format";
import { DateTimePicker } from "../components/DatePicker";
import { ErrorState } from "../components/EmptyState";
import { Skeleton } from "@/components/ui/skeleton";
import { Drawer, DrawerContent, DrawerDescription, DrawerHeader, DrawerTitle } from "@/components/ui/drawer";
import { ActionSheet } from "./ActionSheet";
import { MobileThreadRow, type RowAction } from "./MobileThreadRow";
import { MobileBundleRow } from "./MobileBundleRow";
import { usePullToRefresh } from "./usePullToRefresh";
import { TAB_BAR_H } from "./TabBar";

export interface MobileSection {
  title?: ReactNode;
  threads: ThreadSummary[];
  bundles?: Bundle[];
  emptyTitle?: string;
  emptyBody?: string;
  emptyNode?: ReactNode;
}

const OUT_MS = 220;

export function MobileEmpty({ icon, title, body, action }: { icon?: ReactNode; title: string; body?: string; action?: ReactNode }) {
  return (
    <div className="px-6 py-10 text-center">
      {icon && <div className="mx-auto mb-3 size-10 rounded-full bg-muted flex items-center justify-center text-muted-foreground [&>svg]:size-5">{icon}</div>}
      <div className="text-[15px] font-medium">{title}</div>
      {body && <div className="text-[14px] text-muted-foreground mt-1">{body}</div>}
      {action && <div className="mt-4">{action}</div>}
    </div>
  );
}

export function RowSkeleton({ rows = 6, dense }: { rows?: number; dense?: boolean }) {
  return (
    <div aria-busy>
      {Array.from({ length: rows }).map((_, i) => (
        <div key={i} className="flex items-center gap-3 px-4" style={{ height: dense ? 64 : 80 }}>
          <Skeleton className="size-9 rounded-[4px]" />
          <div className="flex-1 space-y-2">
            <Skeleton className="h-3.5 w-[45%]" />
            <Skeleton className="h-3.5 w-[80%]" />
          </div>
        </div>
      ))}
    </div>
  );
}

/**
 * Mobile thread list: swipe actions, long-press selection with a bottom action bar,
 * pull-to-refresh, optional month groups, animated removal.
 */
export function MobileList({
  sections,
  loading,
  error,
  onRetry,
  onRefresh,
  rightAction,
  leftAction,
  dense,
  showBucket,
  groupByMonth,
  footer,
  emptyIcon,
  selectionEnabled = true,
  onSelectionModeChange,
}: {
  sections: MobileSection[];
  loading?: boolean;
  error?: unknown;
  onRetry?: () => void;
  onRefresh?: () => Promise<unknown> | unknown;
  rightAction?: RowAction | null;
  leftAction?: RowAction | null;
  dense?: boolean;
  showBucket?: boolean;
  groupByMonth?: boolean;
  footer?: ReactNode;
  emptyIcon?: ReactNode;
  selectionEnabled?: boolean;
  onSelectionModeChange?: (on: boolean) => void;
}) {
  const nav = useNavigate();
  const bulk = useBulkAction();
  const all = useMemo(() => sections.flatMap((s) => s.threads), [sections]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [selectionMode, setSelectionMode] = useState(false);
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  const [bubbleFor, setBubbleFor] = useState<string[] | null>(null);
  const [moveFor, setMoveFor] = useState<string[] | null>(null);
  const ptr = usePullToRefresh(async () => onRefresh?.(), !!onRefresh && !selectionMode);

  useEffect(() => {
    onSelectionModeChange?.(selectionMode);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectionMode]);

  useEffect(() => {
    setSelected((s) => {
      const n = new Set([...s].filter((id) => all.some((t) => t.id === id)));
      return n.size === s.size ? s : n;
    });
  }, [all]);

  const act = useCallback(
    (ids: string[], a: ThreadAction, msg?: string, removes = true) => {
      if (!ids.length) return;
      const fire = () =>
        bulk.mutate(
          { thread_ids: ids, ...a },
          {
            onSuccess: () => msg && toast(msg),
            onError: (e) => toast.error((e as Error).message),
            onSettled: () =>
              setLeaving((l) => {
                const n = new Set(l);
                ids.forEach((id) => n.delete(id));
                return n;
              }),
          },
        );
      setSelected(new Set());
      setSelectionMode(false);
      if (removes) {
        setLeaving((l) => new Set([...l, ...ids]));
        window.setTimeout(fire, OUT_MS);
      } else fire();
    },
    [bulk],
  );

  const defaultRight: RowAction = { label: "Reply later", icon: <Clock />, run: (t) => act([t.id], { action: "reply_later", on: !t.reply_later }, t.reply_later ? "Removed from Reply Later" : "Added to Reply Later", !t.reply_later) };
  const defaultLeft: RowAction = { label: "Set aside", icon: <Bookmark />, run: (t) => act([t.id], { action: "set_aside", on: !t.set_aside }, t.set_aside ? "Back in the Imbox" : "Set aside", !t.set_aside) };
  const rA = rightAction === null ? undefined : rightAction ?? defaultRight;
  const lA = leftAction === null ? undefined : leftAction ?? defaultLeft;

  const toggle = (id: string) =>
    setSelected((s) => {
      const n = new Set(s);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });
  const startSelect = (id: string) => {
    setSelectionMode(true);
    setSelected(new Set([id]));
  };
  const cancelSelect = () => {
    setSelectionMode(false);
    setSelected(new Set());
  };
  const ids = [...selected];

  if (error) return <ErrorState error={error} onRetry={onRetry} />;
  if (loading && all.length === 0) return <RowSkeleton dense={dense} />;

  return (
    <div {...ptr.handlers}>
      {ptr.indicator}
      {sections.map((s, si) => {
        const rows: ReactNode[] = [];
        let lastMonth = "";
        const items: ({ kind: "thread"; t: ThreadSummary; at: number } | { kind: "bundle"; b: Bundle; at: number })[] = [
          ...s.threads.map((t) => ({ kind: "thread" as const, t, at: t.last_message_at })),
          ...(s.bundles ?? []).map((b) => ({ kind: "bundle" as const, b, at: b.last_message_at })),
        ];
        if (s.bundles?.length) items.sort((a, b) => b.at - a.at);
        for (const item of items) {
          if (item.kind === "bundle") {
            rows.push(<MobileBundleRow key={"b" + item.b.id} bundle={item.b} dense={dense} />);
            continue;
          }
          const t = item.t;
          if (groupByMonth) {
            const m = monthKey(t.last_message_at);
            if (m !== lastMonth) {
              lastMonth = m;
              rows.push(
                <div key={"m" + m} className="sticky z-10 bg-background/95 backdrop-blur text-[12px] font-medium text-muted-foreground h-8 flex items-center px-4" style={{ top: "calc(44px + env(safe-area-inset-top))" }}>
                  {m}
                </div>,
              );
            }
          }
          rows.push(
            <MobileThreadRow
              key={t.id}
              thread={t}
              dense={dense}
              showBucket={showBucket}
              leaving={leaving.has(t.id)}
              selectionMode={selectionMode}
              selected={selected.has(t.id)}
              onToggleSelect={toggle}
              onLongPress={selectionEnabled ? startSelect : undefined}
              onOpen={(x) => nav(`/t/${x.id}`)}
              rightAction={rA}
              leftAction={lA}
            />,
          );
        }
        return (
          <section key={si} className={cn(si > 0 && "mt-4")}>
            {s.title && (
              <div className="flex items-center gap-1.5 px-4 h-8 text-[12px] font-medium text-muted-foreground">
                {s.title}
                {(s.threads.length > 0 || !!s.bundles?.length) && <span className="tnum text-tertiary">{s.threads.length + (s.bundles?.length ?? 0)}</span>}
              </div>
            )}
            {s.threads.length === 0 && !(s.bundles?.length) ? (
              s.emptyNode ? (
                s.emptyNode
              ) : s.emptyTitle ? (
                <div className="px-4 py-3 text-[14px]">
                  <span className="text-foreground">{s.emptyTitle}</span> {s.emptyBody && <span className="text-muted-foreground">{s.emptyBody}</span>}
                </div>
              ) : (
                <MobileEmpty icon={emptyIcon} title="Nothing here." />
              )
            ) : (
              rows
            )}
          </section>
        );
      })}
      {footer}

      {/* selection mode chrome */}
      {selectionMode && (
        <>
          <div className="fixed top-0 inset-x-0 z-50 bg-background border-b border-border pt-safe">
            <div className="h-11 flex items-center px-2">
              <button type="button" className="h-11 px-2 text-[15px] text-foreground" onClick={cancelSelect}>Cancel</button>
              <div className="flex-1 text-center text-[15px] font-semibold tnum">{selected.size} selected</div>
              <button type="button" className="h-11 px-2 text-[15px] text-foreground" onClick={() => setSelected(new Set(all.map((t) => t.id)))}>All</button>
            </div>
          </div>
          <div className="fixed inset-x-0 bottom-0 z-50 bg-background border-t border-border pb-safe">
            <div className="grid grid-cols-5" style={{ height: TAB_BAR_H }}>
              {[
                { label: "Reply later", icon: <Clock size={20} />, run: () => act(ids, { action: "reply_later", on: true }, "Added to Reply Later") },
                { label: "Set aside", icon: <Bookmark size={20} />, run: () => act(ids, { action: "set_aside", on: true }, "Set aside") },
                { label: "Bubble up", icon: <ArrowUpCircle size={20} />, run: () => setBubbleFor(ids) },
                { label: "Move", icon: <FolderInput size={20} />, run: () => setMoveFor(ids) },
                { label: "Trash", icon: <Trash2 size={20} />, run: () => act(ids, { action: "move", bucket: "trash" }, "Moved to trash") },
              ].map((b) => (
                <button key={b.label} type="button" disabled={!ids.length} onClick={b.run} className="flex flex-col items-center justify-center gap-1 text-muted-foreground active:text-foreground disabled:opacity-40">
                  {b.icon}
                  <span className="text-[10px] font-medium">{b.label}</span>
                </button>
              ))}
            </div>
          </div>
        </>
      )}

      <Drawer open={!!bubbleFor} onOpenChange={(o) => !o && setBubbleFor(null)}>
        <DrawerContent className="pb-safe">
          <DrawerHeader className="pb-0">
            <DrawerTitle>Bubble up</DrawerTitle>
            <DrawerDescription>Out of sight until the moment you pick.</DrawerDescription>
          </DrawerHeader>
          <div className="px-2 pb-2 max-h-[70vh] overflow-y-auto">
            <DateTimePicker
              embedded
              onPick={(at) => {
                const target = bubbleFor ?? [];
                setBubbleFor(null);
                act(target, { action: "bubble_up", at }, "Will bubble up later");
              }}
              onCancel={() => setBubbleFor(null)}
            />
          </div>
        </DrawerContent>
      </Drawer>

      <ActionSheet
        open={!!moveFor}
        onOpenChange={(o) => !o && setMoveFor(null)}
        title="Move to"
        actions={[
          { icon: <Inbox />, label: "Imbox", onSelect: () => act(moveFor ?? [], { action: "move", bucket: "imbox" }, "Moved to Imbox") },
          { icon: <Rss />, label: "The Feed", onSelect: () => act(moveFor ?? [], { action: "move", bucket: "feed" }, "Moved to The Feed") },
          { icon: <FileText />, label: "Paper Trail", onSelect: () => act(moveFor ?? [], { action: "move", bucket: "paper_trail" }, "Moved to Paper Trail") },
          { icon: <Mail />, label: "Mark unread", onSelect: () => act(moveFor ?? [], { action: "mark_unread" }, "Marked unread", false) },
          { icon: <Trash2 />, label: "Trash", onSelect: () => act(moveFor ?? [], { action: "move", bucket: "trash" }, "Moved to trash"), destructive: true },
        ]}
      />
    </div>
  );
}
