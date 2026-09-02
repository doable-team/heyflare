import { useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowUpRight, ChevronDown, FileText, Inbox, Rss, Check } from "lucide-react";
import { toast } from "sonner";
import { cn } from "@/lib/utils";
import { useFeed, useBulkAction, type FeedThread } from "../api";
import { useAccount } from "../context/AccountContext";
import { HtmlBody } from "../components/HtmlBody";
import { LoadMore } from "../components/ThreadList";
import { Avatar, AccountGlyph } from "../components/Avatar";
import { ErrorState } from "../components/EmptyState";
import { fmtTime, unsubscribeTarget } from "../lib/format";
import { Button } from "@/components/ui/button";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { Skeleton } from "@/components/ui/skeleton";
import { Screen } from "./Screen";
import { MobileConnectCard } from "./MobileImbox";
import { MobileEmpty } from "./MobileList";
import { usePullToRefresh } from "./usePullToRefresh";

const CAP = 360;

export function MobileFeedCard({ t, onLeave }: { t: FeedThread; onLeave: (id: string, cb: () => void) => void }) {
  const bulk = useBulkAction();
  const nav = useNavigate();
  const { multi, glyphFor, accountFor } = useAccount();
  const acct = accountFor(t.account_id);
  const m = t.latest_message;
  const unsub = unsubscribeTarget(m?.list_unsubscribe ?? "");
  const [expanded, setExpanded] = useState(false);
  const [overflows, setOverflows] = useState(false);
  const bodyRef = useRef<HTMLDivElement>(null);
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
  const move = (bucket: "paper_trail" | "imbox", label: string) => onLeave(t.id, () => bulk.mutate({ thread_ids: [t.id], action: "move", bucket }, { onSuccess: () => toast(`Moved to ${label}`) }));
  return (
    <article className="bg-background">
      <header className="flex items-center gap-2.5 px-4 pt-4">
        <Avatar email={t.last_from.email} name={t.last_from.name} src={t.last_from.avatar_url} size={28} />
        <div className="min-w-0 flex-1">
          <div className="text-[14px] font-medium truncate flex items-center gap-1.5">
            {t.last_from.name || t.last_from.email}
            {multi && acct && <AccountGlyph glyph={glyphFor(acct.id)} label={acct.email} />}
          </div>
          <div className="text-[12px] text-muted-foreground truncate">{t.last_from.email}</div>
        </div>
        <time className="text-[12px] text-muted-foreground tnum shrink-0">{fmtTime(t.last_message_at)}</time>
      </header>
      <button type="button" onClick={() => nav(`/t/${t.id}`)} className="block w-full text-left px-4 pt-2 text-[18px] font-semibold tracking-[-0.01em] leading-snug">
        {t.subject || "(no subject)"}
      </button>
      <div className="relative px-4 pt-2">
        <div ref={bodyRef} className={cn(!expanded && "overflow-hidden")} style={!expanded ? { maxHeight: CAP } : undefined}>
          {m ? <HtmlBody html={m.html_body} text={m.text_body} trackers={m.trackers} /> : <p className="text-[15px]">{t.snippet}</p>}
        </div>
        {!expanded && overflows && (
          <div className="absolute inset-x-0 bottom-0 h-24 flex items-end justify-center pb-1 bg-gradient-to-t from-background via-background/85 to-transparent">
            <Button variant="outline" size="sm" className="h-9" onClick={() => setExpanded(true)}>
              Read more <ChevronDown />
            </Button>
          </div>
        )}
      </div>
      <footer className="flex items-center gap-1 px-2 py-2">
        <Button variant="ghost" size="sm" className="text-muted-foreground h-10" onClick={() => nav(`/t/${t.id}`)}>Open</Button>
        {unsub.url ? (
          <Button variant="ghost" size="sm" className="text-muted-foreground h-10" asChild>
            <a href={unsub.url} target="_blank" rel="noopener noreferrer">Unsubscribe <ArrowUpRight /></a>
          </Button>
        ) : unsub.mailto ? (
          <Button variant="ghost" size="sm" className="text-muted-foreground h-10" asChild>
            <a href={`mailto:${unsub.mailto}`}>Unsubscribe <ArrowUpRight /></a>
          </Button>
        ) : null}
        <span className="flex-1" />
        <Button variant="ghost" size="icon" className="text-muted-foreground size-10" aria-label="Done" onClick={() => onLeave(t.id, () => bulk.mutate({ thread_ids: [t.id], action: "seen" }, { onSuccess: () => toast("Done") }))}><Check /></Button>
        <Button variant="ghost" size="icon" className="text-muted-foreground size-10" aria-label="Move to Paper Trail" onClick={() => move("paper_trail", "Paper Trail")}><FileText /></Button>
        <Button variant="ghost" size="icon" className="text-muted-foreground size-10" aria-label="Move to Imbox" onClick={() => move("imbox", "Imbox")}><Inbox /></Button>
      </footer>
    </article>
  );
}

export default function MobileFeed() {
  const { accounts } = useAccount();
  const [show, setShow] = useState<"new" | "all">("new");
  const feed = useFeed(accounts.length > 0, show);
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  const ptr = usePullToRefresh(() => feed.refetch(), accounts.length > 0);
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
    }, 160);
  };
  return (
    <Screen
      title="The Feed"
      largeTitle
      subtitle={accounts.length ? "Newsletters and long reads. Scroll, don't sort." : undefined}
      fab={accounts.length > 0}
      titleRight={
        accounts.length > 0 ? (
          <ToggleGroup type="single" value={show} onValueChange={(v) => v && setShow(v as "new" | "all")} variant="outline" size="sm" className="mr-2">
            <ToggleGroupItem value="new">New</ToggleGroupItem>
            <ToggleGroupItem value="all">All</ToggleGroupItem>
          </ToggleGroup>
        ) : undefined
      }
    >
      {accounts.length === 0 ? (
        <MobileConnectCard />
      ) : (
        <div {...ptr.handlers}>
          {ptr.indicator}
          {feed.error && <ErrorState error={feed.error} onRetry={() => feed.refetch()} />}
          {feed.isLoading && (
            <div className="px-4 space-y-4" aria-busy>
              <Skeleton className="h-5 w-[40%]" />
              <Skeleton className="h-6 w-[80%]" />
              <Skeleton className="h-48" />
            </div>
          )}
          {!feed.isLoading && threads.length === 0 && !feed.error && <MobileEmpty icon={<Rss />} title="Your Feed is quiet." body="Screen a newsletter into The Feed and it shows up here, fully opened." />}
          <div className="divide-y divide-border">
            {threads.map((t) => (
              <div key={t.id} className={cn("transition-opacity duration-150", leaving.has(t.id) && "opacity-0")}>
                <MobileFeedCard t={t} onLeave={onLeave} />
              </div>
            ))}
          </div>
          <LoadMore hasMore={!!feed.hasNextPage} loading={feed.isFetchingNextPage} onMore={() => feed.fetchNextPage()} />
        </div>
      )}
    </Screen>
  );
}
