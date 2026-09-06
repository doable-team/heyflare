import { useEffect, useState, type ReactNode } from "react";
import { useParams, useSearchParams } from "react-router-dom";
import { ArrowUpCircle, Bookmark, Clock, Eye, FileText, Mail, Search, Send, Tag, Trash2, X } from "lucide-react";
import { useAccount } from "../context/AccountContext";
import { useLabelThreads, useLabels, useSearch, useThreads } from "../api";
import { LoadMore } from "../components/ThreadList";
import { fmtRelative } from "../lib/format";
import { Screen } from "./Screen";
import { MobileConnectCard } from "./MobileImbox";
import { MobileList } from "./MobileList";

type Cfg = { title: string; subtitle?: string; icon: ReactNode; empty: string; emptyBody?: string; dense?: boolean; groupByMonth?: boolean; showBucket?: boolean; fab?: boolean };

/** Bucket-driven list screens (paper trail, trays, library lists). */
export function MobileBucketScreen({ bucket, back, cfg }: { bucket: string; back?: boolean; cfg: Cfg }) {
  const { accounts } = useAccount();
  const q = useThreads(bucket, { enabled: accounts.length > 0 });
  const threads = q.data?.pages.flatMap((p) => p.threads) ?? [];
  const bundles = bucket === "paper_trail" ? q.data?.pages[0]?.bundles ?? [] : [];
  // Every thread list swipes the same way — right selects, left turns read state over —
  // so no screen overrides them any more. Everything a bucket used to offer on a swipe
  // (Done on a tray, Cancel on Bubble Up) is one swipe-right away in the bar below,
  // which is where the rest of the filing already lives.
  return (
    <Screen title={cfg.title} largeTitle back={back} subtitle={accounts.length ? cfg.subtitle : undefined} fab={cfg.fab} tabs>
      {accounts.length === 0 ? (
        <MobileConnectCard />
      ) : (
        <MobileList
          loading={q.isLoading}
          error={q.error}
          onRetry={() => q.refetch()}
          onRefresh={() => q.refetch()}
          dense={cfg.dense}
          groupByMonth={cfg.groupByMonth}
          showBucket={cfg.showBucket}
          emptyIcon={cfg.icon}
          sections={[{ threads: bucket === "bubble_up" ? threads.map((t) => ({ ...t, snippet: t.bubble_up_at ? `Bubbles up ${fmtRelative(t.bubble_up_at)}` : t.snippet })) : threads, bundles, emptyTitle: cfg.empty, emptyBody: cfg.emptyBody }]}
          footer={<LoadMore hasMore={!!q.hasNextPage} loading={q.isFetchingNextPage} onMore={() => q.fetchNextPage()} />}
        />
      )}
    </Screen>
  );
}

export const BUCKETS: Record<string, Cfg> = {
  paper_trail: { title: "Paper Trail", subtitle: "Receipts, confirmations, and the rest of the paperwork.", icon: <FileText />, empty: "No paperwork yet.", emptyBody: "Receipts land here once you screen those senders into the Paper Trail.", dense: true, groupByMonth: true, fab: true },
  reply_later: { title: "Reply Later", subtitle: "Threads you meant to answer.", icon: <Clock />, empty: "Nothing to reply to.", emptyBody: "Long-press a thread in the Imbox and choose Reply later to park it here." },
  set_aside: { title: "Set Aside", subtitle: "Things you want close at hand.", icon: <Bookmark />, empty: "Nothing set aside.", emptyBody: "Long-press a thread in the Imbox and choose Set aside to keep it handy." },
  bubble_up: { title: "Bubble Up", subtitle: "Out of sight until the moment you picked.", icon: <ArrowUpCircle />, empty: "Nothing scheduled.", emptyBody: "Long-press a thread and choose Bubble up." },
  previously_seen: { title: "Previously seen", icon: <Eye />, empty: "Nothing here yet.", emptyBody: "Once you open something, it settles down here." },
  sent: { title: "Sent", icon: <Send />, empty: "Nothing sent yet.", showBucket: true },
  trash: { title: "Trash", icon: <Trash2 />, empty: "Trash is empty." },
  everything: { title: "Everything", icon: <Mail />, empty: "Nothing here.", showBucket: true },
};

export function MobileLabelThreads() {
  const { id } = useParams();
  const { accounts } = useAccount();
  const labels = useLabels(accounts.length > 0);
  const q = useLabelThreads(id);
  const label = labels.data?.find((l) => l.id === id);
  return (
    <Screen title={label?.name ?? "Label"} largeTitle back>
      <MobileList loading={q.isLoading} error={q.error} onRetry={() => q.refetch()} onRefresh={() => q.refetch()} emptyIcon={<Tag />} sections={[{ threads: q.data?.threads ?? [], emptyTitle: "No threads with this label." }]} showBucket />
    </Screen>
  );
}

export function MobileSearch() {
  const [sp, setSp] = useSearchParams();
  const initial = sp.get("q") ?? "";
  const [text, setText] = useState(initial);
  const [q, setQ] = useState(initial);
  const res = useSearch(q);
  const threads = res.data?.pages.flatMap((p) => p.threads) ?? [];
  useEffect(() => {
    const t = window.setTimeout(() => {
      setQ(text.trim());
      setSp(text.trim() ? { q: text.trim() } : {}, { replace: true });
    }, 250);
    return () => window.clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [text]);
  return (
    <Screen
      title="Search"
      back
      below={
        <div className="px-3 pb-2">
          <label className="flex items-center gap-2 h-10 rounded-lg bg-muted px-3">
            <Search size={16} className="text-muted-foreground shrink-0" />
            <input autoFocus value={text} onChange={(e) => setText(e.target.value)} placeholder="Search mail" className="flex-1 min-w-0 bg-transparent outline-none text-[16px] placeholder:text-tertiary" type="search" enterKeyHint="search" />
            {text && (
              <button type="button" onClick={() => setText("")} aria-label="Clear" className="text-muted-foreground">
                <X size={16} />
              </button>
            )}
          </label>
        </div>
      }
    >
      <div className="pt-12">
        {q ? (
          <MobileList loading={res.isLoading} error={res.error} onRetry={() => res.refetch()} emptyIcon={<Search />} showBucket sections={[{ threads, emptyTitle: "No matches.", emptyBody: "Try fewer words, or a name." }]} footer={<LoadMore hasMore={!!res.hasNextPage} loading={res.isFetchingNextPage} onMore={() => res.fetchNextPage()} />} />
        ) : (
          <div className="px-6 py-10 text-center text-[14px] text-muted-foreground">Search subjects, people and message text.</div>
        )}
      </div>
    </Screen>
  );
}
