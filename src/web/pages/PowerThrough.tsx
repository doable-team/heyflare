import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { ArrowLeft, Bookmark, Check, ChevronDown, Clock, FileText, FolderOpen, Inbox, MoreHorizontal, Reply, Rss, StickyNote, Tag, Trash2, ArrowUpCircle } from "lucide-react";
import { toast } from "sonner";
import type { Message, ThreadDetail, ThreadSummary } from "@shared/types";
import { cn } from "@/lib/utils";
import { useBulkAction, usePowerThrough, usePowerThroughMutations, useThreadAction } from "../api";
import { useAccount } from "../context/AccountContext";
import { HtmlBody } from "../components/HtmlBody";
import { Composer, type ComposerInitial } from "../components/Composer";
import { DateTimePicker } from "../components/DatePicker";
import { CollectionMenuItems, LabelChip, LabelMenuItems } from "../components/Pickers";
import { Avatar, AccountGlyph } from "../components/Avatar";
import { ErrorState } from "../components/EmptyState";
import { replyInitial } from "./Thread";
import { ConnectGmailCard } from "./Imbox";
import { useItemCursor } from "../lib/cardKeys";
import { useKeys } from "../lib/keys";
import { overlayOpen } from "../lib/focusStore";
import { fmtFull, fmtTime } from "../lib/format";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Kbd } from "@/components/ui/kbd";
import { Skeleton } from "@/components/ui/skeleton";
import { Textarea } from "@/components/ui/textarea";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuSub, DropdownMenuSubContent, DropdownMenuSubTrigger, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";

export type PowerItem = ThreadSummary & { latest_message: Message | null };

const CAP = 560;
const OUT_MS = 160;

/** `replyInitial` only reads the thread's ids and subject, both of which a summary carries. */
function asDetail(t: PowerItem): ThreadDetail {
  return { ...t, messages: [], collections: [], clips: [], merged_threads: [], sender_bundled: false } as unknown as ThreadDetail;
}

function PowerCard({
  t,
  focused,
  index,
  onGone,
  onReply,
  replying,
  onCloseReply,
}: {
  t: PowerItem;
  focused: boolean;
  index: number;
  onGone: (id: string, run: () => void) => void;
  onReply: (id: string) => void;
  replying: boolean;
  onCloseReply: () => void;
}) {
  const bulk = useBulkAction();
  const act = useThreadAction(t.id);
  const { multi, glyphFor, accountFor, account, accounts } = useAccount();
  const acct = accountFor(t.account_id);
  const m = t.latest_message;
  const [expanded, setExpanded] = useState(false);
  const [overflows, setOverflows] = useState(false);
  const bodyRef = useRef<HTMLDivElement>(null);
  const [bubbleOpen, setBubbleOpen] = useState(false);
  const [noteOpen, setNoteOpen] = useState(false);
  const [note, setNote] = useState(t.note ?? "");
  const labelIds = useMemo(() => new Set(t.labels.map((l) => l.id)), [t.labels]);
  const myEmail = (account ?? accounts.find((a) => a.id === t.account_id))?.email;

  const leave = (body: Parameters<typeof bulk.mutate>[0], msg: string) => onGone(t.id, () => bulk.mutate(body, { onSuccess: () => toast(msg) }));

  const initial: ComposerInitial | null = m ? replyInitial(asDetail(t), m, "reply", myEmail) : null;

  // Only offer "Read more" when the body is actually taller than the cap — the iframe sizes itself late.
  useEffect(() => {
    const el = bodyRef.current;
    if (!el) return;
    const check = () => setOverflows(el.scrollHeight > CAP + 24);
    check();
    const ro = new ResizeObserver(check);
    ro.observe(el);
    const t1 = window.setTimeout(check, 600);
    const t2 = window.setTimeout(check, 1600);
    return () => {
      ro.disconnect();
      window.clearTimeout(t1);
      window.clearTimeout(t2);
    };
  }, [m?.id]);

  return (
    <article
      data-item-index={index}
      data-power-id={t.id}
      className={cn("rounded-md bg-muted/40 scroll-mt-20 transition-opacity duration-150", focused && "ring-1 ring-ring")}
    >
      <header className="flex items-center gap-2.5 px-5 pt-5">
        <Avatar email={t.last_from.email} name={t.last_from.name} src={t.last_from.avatar_url} size={20} />
        <span className="text-sm font-medium truncate">{t.last_from.name || t.last_from.email}</span>
        {multi && acct && <AccountGlyph glyph={glyphFor(acct.id)} label={acct.email} />}
        <span className="text-xs text-muted-foreground truncate hidden sm:inline">{t.last_from.email}</span>
        {t.labels.slice(0, 2).map((l) => (
          <LabelChip key={l.id} label={l} small />
        ))}
        <span className="flex-1" />
        <Tooltip>
          <TooltipTrigger asChild>
            <time className="text-xs text-muted-foreground tnum shrink-0">{fmtTime(t.last_message_at)}</time>
          </TooltipTrigger>
          <TooltipContent>{fmtFull(t.last_message_at)}</TooltipContent>
        </Tooltip>
      </header>

      <div className="px-5 pt-3">
        <Link to={`/t/${t.id}`} className="text-lg font-semibold tracking-[-0.01em] leading-snug hover:underline underline-offset-2 block">
          {t.subject || "(no subject)"}
        </Link>
        {t.message_count > 1 && <span className="text-xs text-muted-foreground">{t.message_count} messages</span>}
      </div>

      {t.note && (
        <div className="mx-5 mt-3 rounded-md bg-background px-3 py-2 text-[13px] flex items-start gap-2">
          <StickyNote className="size-3.5 mt-0.5 shrink-0 text-muted-foreground" />
          <span className="whitespace-pre-wrap">{t.note}</span>
        </div>
      )}

      <div className="relative px-5 pt-3 pb-1">
        <div ref={bodyRef} className={cn(!expanded && "overflow-hidden")} style={!expanded ? { maxHeight: CAP } : undefined}>
          {m ? <HtmlBody html={m.html_body} text={m.text_body} trackers={m.trackers} /> : <p className="text-sm">{t.snippet}</p>}
        </div>
        {!expanded && overflows && (
          <div className="absolute inset-x-0 bottom-0 h-20 flex items-end justify-center pb-2 bg-gradient-to-t from-background via-background/70 to-transparent pointer-events-none">
            <Button variant="outline" size="sm" className="pointer-events-auto" onClick={() => setExpanded(true)}>
              Read more <ChevronDown />
            </Button>
          </div>
        )}
      </div>

      {replying && initial ? (
        <div className="px-3 pb-3">
          <div className="rounded-md ring-1 ring-border bg-background p-2">
            <Composer inline initial={initial} autoFocusBody onCancel={onCloseReply} onDone={() => onGone(t.id, () => bulk.mutate({ thread_ids: [t.id], action: "seen" }))} />
          </div>
        </div>
      ) : (
        <footer className="flex items-center gap-1 px-3 py-2 flex-wrap">
          <Button size="sm" onClick={() => onReply(t.id)}>
            <Reply /> Reply
          </Button>
          <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={() => leave({ thread_ids: [t.id], action: "reply_later", on: true }, "Added to Reply Later")}>
            <Clock /> <span className="hidden sm:inline">Reply later</span>
          </Button>
          <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={() => leave({ thread_ids: [t.id], action: "set_aside", on: true }, "Set aside")}>
            <Bookmark /> <span className="hidden sm:inline">Set aside</span>
          </Button>
          <Popover open={bubbleOpen} onOpenChange={setBubbleOpen}>
            <PopoverTrigger asChild>
              <Button variant="ghost" size="sm" className="text-muted-foreground">
                <ArrowUpCircle /> <span className="hidden sm:inline">Bubble up</span>
              </Button>
            </PopoverTrigger>
            <PopoverContent align="start" className="w-auto p-0">
              <DateTimePicker
                onPick={(at) => {
                  setBubbleOpen(false);
                  leave({ thread_ids: [t.id], action: "bubble_up", at }, "Will bubble up");
                }}
                onCancel={() => setBubbleOpen(false)}
              />
            </PopoverContent>
          </Popover>
          <span className="flex-1" />
          <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={() => leave({ thread_ids: [t.id], action: "seen" }, "Marked seen")}>
            <Check /> <span className="hidden sm:inline">Mark seen</span>
          </Button>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="ghost" size="sm" className="text-muted-foreground">
                <MoreHorizontal />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-52">
              <DropdownMenuLabel>Move to</DropdownMenuLabel>
              <DropdownMenuItem onClick={() => leave({ thread_ids: [t.id], action: "move", bucket: "feed" }, "Moved to The Feed")}>
                <Rss /> The Feed
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => leave({ thread_ids: [t.id], action: "move", bucket: "paper_trail" }, "Moved to Paper Trail")}>
                <FileText /> Paper Trail
              </DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuSub>
                <DropdownMenuSubTrigger>
                  <Tag /> Labels
                </DropdownMenuSubTrigger>
                <DropdownMenuSubContent>
                  <LabelMenuItems current={labelIds} onToggle={(id, on) => act.mutate({ action: "labels", ...(on ? { add: [id] } : { remove: [id] }) })} />
                </DropdownMenuSubContent>
              </DropdownMenuSub>
              <DropdownMenuSub>
                <DropdownMenuSubTrigger>
                  <FolderOpen /> Add to collection
                </DropdownMenuSubTrigger>
                <DropdownMenuSubContent>
                  <CollectionMenuItems current={new Set()} onToggle={(id, on) => act.mutate({ action: "collections", ...(on ? { add: [id] } : { remove: [id] }) })} />
                </DropdownMenuSubContent>
              </DropdownMenuSub>
              <DropdownMenuItem onClick={() => setNoteOpen((v) => !v)}>
                <StickyNote /> {t.note ? "Edit note" : "Add note"}
              </DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem onClick={() => leave({ thread_ids: [t.id], action: "move", bucket: "imbox" }, "Kept in the Imbox")}>
                <Inbox /> Keep in Imbox
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => leave({ thread_ids: [t.id], action: "move", bucket: "trash" }, "Moved to trash")}>
                <Trash2 /> Trash
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </footer>
      )}

      {noteOpen && (
        <div className="px-5 pb-4">
          <Textarea
            autoFocus
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="A private note on this thread…"
            className="min-h-16 text-[13px]"
            onKeyDown={(e) => {
              if (e.key === "Escape") {
                setNoteOpen(false);
                setNote(t.note ?? "");
              }
              if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                act.mutate({ action: "note", note }, { onSuccess: () => toast("Note saved") });
                setNoteOpen(false);
              }
            }}
          />
          <div className="flex items-center gap-2 mt-2">
            <Button
              size="sm"
              onClick={() => {
                act.mutate({ action: "note", note }, { onSuccess: () => toast("Note saved") });
                setNoteOpen(false);
              }}
            >
              Save note
            </Button>
            <Button size="sm" variant="ghost" onClick={() => setNoteOpen(false)}>
              Cancel
            </Button>
            <span className="text-xs text-muted-foreground">
              <Kbd>⌘</Kbd> <Kbd>↵</Kbd> to save
            </span>
          </div>
        </div>
      )}
    </article>
  );
}

/**
 * HEY's "Power Through New": the whole "New for you" queue stacked on one page so you can act on
 * each message in turn. Nothing is marked seen just by scrolling past it — untouched mail stays new.
 */
export default function PowerThrough() {
  const { accounts } = useAccount();
  const nav = useNavigate();
  const q = usePowerThrough(accounts.length > 0);
  const { markAllSeen } = usePowerThroughMutations();
  const bulk = useBulkAction();
  const [gone, setGone] = useState<Set<string>>(new Set());
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  const [replyFor, setReplyFor] = useState<string | null>(null);

  const items = useMemo(() => (q.data?.items ?? []).filter((t) => !gone.has(t.id)), [q.data, gone]);

  /** Fade the card out, run the action, then drop it from the stack. */
  const onGone = useCallback((id: string, run: () => void) => {
    setLeaving((l) => new Set([...l, id]));
    window.setTimeout(() => {
      run();
      setGone((g) => new Set([...g, id]));
      setLeaving((l) => {
        const n = new Set(l);
        n.delete(id);
        return n;
      });
      setReplyFor((r) => (r === id ? null : r));
    }, OUT_MS);
  }, []);

  const { cursor } = useItemCursor({
    count: items.length,
    onOpen: (i) => items[i] && nav(`/t/${items[i].id}`),
    enabled: !replyFor,
  });
  const cur = cursor >= 0 ? items[cursor] : undefined;

  useKeys(
    {
      r: () => cur && setReplyFor(cur.id),
      l: () => cur && onGone(cur.id, () => bulk.mutate({ thread_ids: [cur.id], action: "reply_later", on: true }, { onSuccess: () => toast("Added to Reply Later") })),
      a: () => cur && onGone(cur.id, () => bulk.mutate({ thread_ids: [cur.id], action: "set_aside", on: true }, { onSuccess: () => toast("Set aside") })),
      e: () => cur && onGone(cur.id, () => bulk.mutate({ thread_ids: [cur.id], action: "seen" }, { onSuccess: () => toast("Marked seen") })),
      "#": () => cur && onGone(cur.id, () => bulk.mutate({ thread_ids: [cur.id], action: "move", bucket: "trash" }, { onSuccess: () => toast("Moved to trash") })),
      Escape: () => {
        if (overlayOpen()) return;
        nav("/");
      },
    },
    !replyFor,
  );

  if (accounts.length === 0) return <ConnectGmailCard />;
  if (q.error) return <ErrorState error={q.error} onRetry={() => q.refetch()} />;

  return (
    <div className="max-w-2xl mx-auto">
      <header className="px-2 mb-4">
        <Button variant="ghost" size="sm" className="-ml-2 text-muted-foreground" onClick={() => nav("/")}>
          <ArrowLeft /> Back to Imbox <Kbd>esc</Kbd>
        </Button>
        <div className="flex items-baseline gap-2 mt-1">
          <h1 className="text-[28px] leading-8 font-bold tracking-[-0.02em]">Power through new</h1>
          {items.length > 0 && <Badge variant="secondary" className="font-normal">{items.length} to go</Badge>}
        </div>
        <p className="text-[13px] text-muted-foreground mt-1">
          Act on each one and it leaves the stack. Anything you skip stays new.
        </p>
        <p className="text-xs text-tertiary mt-2 flex items-center gap-1.5 flex-wrap">
          <Kbd>j</Kbd>
          <Kbd>k</Kbd> move · <Kbd>r</Kbd> reply · <Kbd>l</Kbd> later · <Kbd>a</Kbd> set aside · <Kbd>e</Kbd> seen · <Kbd>#</Kbd> trash · <Kbd>↵</Kbd> open
        </p>
      </header>

      {q.isLoading && (
        <div className="space-y-4">
          <Skeleton className="h-64" />
          <Skeleton className="h-64" />
        </div>
      )}

      {!q.isLoading && items.length === 0 && (
        <div className="px-2 py-10">
          <div className="text-[15px] text-foreground">Nothing new. Go enjoy your day.</div>
          <Link to="/" className="text-[13px] text-muted-foreground hover:text-foreground underline underline-offset-2 mt-1 inline-block">
            Back to the Imbox
          </Link>
        </div>
      )}

      <div className="space-y-4">
        {items.map((t, i) => (
          <div key={t.id} className={cn("transition-opacity duration-150", leaving.has(t.id) && "opacity-0")}>
            <PowerCard
              t={t}
              index={i}
              focused={cursor === i}
              onGone={onGone}
              onReply={setReplyFor}
              replying={replyFor === t.id}
              onCloseReply={() => setReplyFor(null)}
            />
          </div>
        ))}
      </div>

      {items.length > 0 && (
        <div className="flex items-center justify-center gap-3 py-8">
          <Button
            variant="outline"
            disabled={markAllSeen.isPending}
            onClick={() =>
              markAllSeen.mutate(
                items.map((t) => t.id),
                {
                  onSuccess: (r) => {
                    toast(`Marked ${r.count} as seen`);
                    nav("/");
                  },
                },
              )
            }
          >
            <Check /> Mark all as seen
          </Button>
          <Button variant="ghost" onClick={() => nav("/")}>
            Leave the rest
          </Button>
        </div>
      )}
    </div>
  );
}
