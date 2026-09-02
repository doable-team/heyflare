import type { ReactNode } from "react";
import { Eye, Inbox, Send, Trash2 } from "lucide-react";
import { useImbox, useThreads } from "../api";
import { useAccount } from "../context/AccountContext";
import { ConnectGmailCard } from "./Imbox";
import { LoadMore, ThreadList } from "../components/ThreadList";
import { PageHeader } from "../components/EmptyState";

const ART: Record<string, { icon: ReactNode; title: string; body: string }> = {
  previously_seen: { icon: <Eye />, title: "Nothing seen yet.", body: "Once you open something in the Imbox, it settles down here." },
  trash: { icon: <Trash2 />, title: "Trash is empty.", body: "Nothing to take out." },
  sent: { icon: <Send />, title: "Nothing sent yet.", body: "Press c to write something." },
  everything: { icon: <Inbox />, title: "Nothing here.", body: "Empty lists are underrated." },
};

export default function ListPage({ bucket, title, subtitle, showBucket }: { bucket: string; title: string; subtitle?: string; showBucket?: boolean }) {
  const { accounts } = useAccount();
  const isSeen = bucket === "previously_seen";
  const enabled = accounts.length > 0;
  const q = useThreads(bucket, { enabled: enabled && !isSeen });
  const imbox = useImbox(enabled && isSeen);
  if (!enabled) return <ConnectGmailCard />;
  const threads = isSeen ? imbox.data?.seen_threads ?? [] : q.data?.pages.flatMap((p) => p.threads) ?? [];
  const loading = isSeen ? imbox.isLoading : q.isLoading;
  const error = isSeen ? imbox.error : q.error;
  const art = ART[bucket] ?? ART.everything;
  const count = threads.length ? `${threads.length}${!isSeen && q.hasNextPage ? "+" : ""} ${threads.length === 1 && !q.hasNextPage ? "thread" : "threads"}. ` : "";
  return (
    <div className="max-w-3xl mx-auto">
      <PageHeader className="px-2" title={title} subtitle={`${count}${subtitle ?? ""}`.trim() || undefined} />
      <ThreadList
        loading={loading}
        error={error}
        onRetry={() => (isSeen ? imbox.refetch() : q.refetch())}
        showBucket={showBucket}
        emptyIcon={art.icon}
        sections={[{ threads, emptyTitle: art.title, emptyBody: art.body }]}
        footer={!isSeen && <LoadMore hasMore={!!q.hasNextPage} loading={q.isFetchingNextPage} onMore={() => q.fetchNextPage()} />}
      />
    </div>
  );
}
