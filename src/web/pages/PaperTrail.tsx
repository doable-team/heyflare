import { FileText } from "lucide-react";
import { useThreads } from "../api";
import { useAccount } from "../context/AccountContext";
import { ConnectGmailCard } from "./Imbox";
import { LoadMore, ThreadList } from "../components/ThreadList";
import { PageHeader } from "../components/EmptyState";

export default function PaperTrail() {
  const { accounts } = useAccount();
  const q = useThreads("paper_trail", { enabled: accounts.length > 0 });
  if (accounts.length === 0) return <ConnectGmailCard />;
  const threads = q.data?.pages.flatMap((p) => p.threads) ?? [];
  const bundles = q.data?.pages[0]?.bundles ?? [];
  const count = threads.length ? `${threads.length}${q.hasNextPage ? "+" : ""} ${threads.length === 1 && !q.hasNextPage ? "item" : "items"}. ` : "";
  return (
    <div className="max-w-3xl mx-auto">
      <PageHeader className="px-2" title="Paper Trail" subtitle={`${count}Receipts, confirmations, and the rest of the paperwork.`} />
      <ThreadList
        compact
        groupByMonth
        loading={q.isLoading}
        error={q.error}
        onRetry={() => q.refetch()}
        emptyIcon={<FileText />}
        sections={[{ threads, bundles, emptyTitle: "No paperwork yet.", emptyBody: "Receipts and confirmations land here once you screen those senders into the Paper Trail." }]}
        footer={<LoadMore hasMore={!!q.hasNextPage} loading={q.isFetchingNextPage} onMore={() => q.fetchNextPage()} />}
      />
    </div>
  );
}
