import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { ArrowUpRight, ChevronDown, FileText, Inbox, Rss, Check } from "lucide-react";
import { cn } from "@/lib/utils";
import { useFeed, useBulkAction, type FeedThread } from "../api";
import { useAccount } from "../context/AccountContext";
import { ConnectGmailCard } from "./Imbox";
import { HtmlBody } from "../components/HtmlBody";
import { LoadMore } from "../components/ThreadList";
import { Avatar, AccountGlyph } from "../components/Avatar";
import { EmptyState, ErrorState, PageHeader } from "../components/EmptyState";
import { useToast } from "../components/Toast";
import { fmtTime, fmtFull, unsubscribeTarget } from "../lib/format";
import { Button } from "@/components/ui/button";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { Skeleton } from "@/components/ui/skeleton";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";

const CAP = 480;
const OUT_MS = 120;

export function FeedCard({ t, onLeave }: { t: FeedThread; onLeave: (id: string, cb: () => void) => void }) {
  const bulk = useBulkAction();
  const { toast } = useToast();
  const { multi, glyphFor, accountFor } = useAccount();
  const acct = accountFor(t.account_id);
  const m = t.latest_message;
  const unsub = unsubscribeTarget(m?.list_unsubscribe ?? "");
  const [expanded, setExpanded] = useState(false);
  const [overflows, setOverflows] = useState(false);
  const bodyRef = useRef<HTMLDivElement>(null);

  // Detect whether the (iframe-sized) body exceeds the cap; re-check as the iframe resizes.
  useEffect(() => {
    const el = bodyRef.current;
    if (!el) return;
    const check = () => setOverflows(el.scrollHeight > CAP + 24);
    check();
    const ro = new ResizeObserver(check);
    ro.observe(el);
    const t1 = window.setTimeout(check, 600);
    return () => {
      ro.disconnect();
      clearTimeout(t1);
    };
  }, [m?.id]);

  const move = (bucket: "paper_trail" | "imbox", label: string) =>
    onLeave(t.id, () => bulk.mutate({ thread_ids: [t.id], action: "move", bucket }, { onSuccess: () => toast(`Moved to ${label}`, { kind: "success" }) }));

  return (
    <article className="rounded-md bg-muted/40">
      <header className="flex items-center gap-2.5 px-5 pt-5">
        <Avatar email={t.last_from.email} name={t.last_from.name} src={t.last_from.avatar_url} size={20} />
        <span className="text-sm font-medium truncate">{t.last_from.name || t.last_from.email}</span>
        {multi && acct && <AccountGlyph glyph={glyphFor(acct.id)} label={acct.email} />}
        <span className="text-xs text-muted-foreground truncate hidden sm:inline">{t.last_from.email}</span>
        <span className="flex-1" />
        <Tooltip>
          <TooltipTrigger asChild>
            <time className="text-xs text-muted-foreground tnum shrink-0">{fmtTime(t.last_message_at)}</time>
          </TooltipTrigger>
          <TooltipContent>{fmtFull(t.last_message_at)}</TooltipContent>
        </Tooltip>
      </header>

      <div className="px-5 pt-3">
        <Link to={`/t/${t.id}`} className="text-xl font-semibold tracking-[-0.01em] leading-snug hover:underline underline-offset-2 block">
          {t.subject || "(no subject)"}
        </Link>
      </div>

      <div className="relative px-5 pt-3 pb-1">
        <div ref={bodyRef} className={cn(!expanded && "overflow-hidden")} style={!expanded ? { maxHeight: CAP } : undefined}>
          {m ? <HtmlBody html={m.html_body} text={m.text_body} trackers={m.trackers} /> : <p className="text-sm">{t.snippet}</p>}
        </div>
        {!expanded && overflows && (
          <div className="absolute inset-x-0 bottom-0 h-24 flex items-end justify-center pb-2 bg-gradient-to-t from-background via-background/80 to-transparent">
            <Button variant="outline" size="sm" onClick={() => setExpanded(true)}>
              Read more <ChevronDown />
            </Button>
          </div>
        )}
      </div>

      <footer className="flex items-center gap-1 px-3 py-2 flex-wrap">
        <Button variant="ghost" size="sm" className="text-muted-foreground" asChild>
          <Link to={`/t/${t.id}`}>Open thread</Link>
        </Button>
        {unsub.url ? (
          <Button variant="ghost" size="sm" className="text-muted-foreground" asChild>
            <a href={unsub.url} target="_blank" rel="noopener noreferrer">
              Unsubscribe <ArrowUpRight />
            </a>
          </Button>
        ) : unsub.mailto ? (
          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="sm" className="text-muted-foreground" asChild>
                <a href={`mailto:${unsub.mailto}`}>
                  Unsubscribe <ArrowUpRight />
                </a>
              </Button>
            </TooltipTrigger>
            <TooltipContent>Email {unsub.mailto} to unsubscribe</TooltipContent>
          </Tooltip>
        ) : null}
        <span className="flex-1" />
        <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={() => onLeave(t.id, () => bulk.mutate({ thread_ids: [t.id], action: "seen" }, { onSuccess: () => toast("Done", { kind: "success" }) }))}>
          <Check /> <span className="hidden sm:inline">Done</span>
        </Button>
        <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={() => move("paper_trail", "Paper Trail")}>
          <FileText /> <span className="hidden sm:inline">Paper Trail</span>
        </Button>
        <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={() => move("imbox", "Imbox")}>
          <Inbox /> <span className="hidden sm:inline">Imbox</span>
        </Button>
      </footer>
    </article>
  );
}

function CardSkeleton() {
  return (
    <div className="rounded-md bg-muted/40 p-5 space-y-4" aria-busy>
      <div className="flex items-center gap-2.5">
        <Skeleton className="size-5 rounded-[4px]" />
        <Skeleton className="h-3 w-[30%]" />
      </div>
      <Skeleton className="h-5 w-[70%]" />
      <div className="space-y-2">
        <Skeleton className="h-3 w-full" />
        <Skeleton className="h-3 w-[92%]" />
        <Skeleton className="h-3 w-[80%]" />
        <Skeleton className="h-32 w-full" />
      </div>
    </div>
  );
}

export default function Feed() {
  const { accounts } = useAccount();
  const [show, setShow] = useState<"new" | "all">("new");
  const feed = useFeed(accounts.length > 0, show);
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  if (accounts.length === 0) return <ConnectGmailCard />;
  const threads = feed.data?.pages.flatMap((p) => p.threads) ?? [];
  const onLeave = (id: string, cb: () => void) => {
    setLeaving((l) => new Set([...l, id]));
    window.setTimeout(() => {
      cb();
      setLeaving((l) => {
        const n = new Set(l);
        n.delete(id);
        return n;
      });
    }, OUT_MS);
  };
  return (
    <div className="max-w-2xl mx-auto">
      <PageHeader
        className="px-2"
        title="The Feed"
        subtitle={threads.length ? `${threads.length}${feed.hasNextPage ? "+" : ""} ${threads.length === 1 && !feed.hasNextPage ? "item" : "items"}. Newsletters and long reads. Scroll, don't sort.` : "Newsletters and long reads. Scroll, don't sort."}
        actions={
          <ToggleGroup type="single" value={show} onValueChange={(v) => v && setShow(v as "new" | "all")} variant="outline" size="sm">
            <ToggleGroupItem value="new" aria-label="Show new">New</ToggleGroupItem>
            <ToggleGroupItem value="all" aria-label="Show everything">All</ToggleGroupItem>
          </ToggleGroup>
        }
      />
      {feed.error && <ErrorState error={feed.error} onRetry={() => feed.refetch()} />}
      {feed.isLoading && (
        <div className="space-y-4">
          <CardSkeleton />
          <CardSkeleton />
        </div>
      )}
      {!feed.isLoading && threads.length === 0 && !feed.error && <EmptyState icon={<Rss />} title="Your Feed is quiet." body="Screen a newsletter into The Feed and it shows up here, fully opened." />}
      <div className="space-y-4">
        {threads.map((t) => (
          <div key={t.id} className={cn("transition-opacity duration-100", leaving.has(t.id) && "opacity-0")}>
            <FeedCard t={t} onLeave={onLeave} />
          </div>
        ))}
      </div>
      <LoadMore hasMore={!!feed.hasNextPage} loading={feed.isFetchingNextPage} onMore={() => feed.fetchNextPage()} />
    </div>
  );
}
