import { Link, useParams } from "react-router-dom";
import { Tag } from "lucide-react";
import { useLabelThreads, useLabels } from "../api";
import { ThreadList } from "../components/ThreadList";
import { PageHeader } from "../components/EmptyState";
import { Button } from "@/components/ui/button";

export default function LabelThreads() {
  const { id } = useParams();
  const labels = useLabels();
  const label = labels.data?.find((l) => l.id === id);
  const q = useLabelThreads(id);
  const n = q.data?.threads.length ?? 0;
  return (
    <div className="max-w-3xl mx-auto">
      <PageHeader
        className="px-2"
        title={
          <span className="inline-flex items-center gap-2.5">
            <Tag className="size-5 text-muted-foreground" />
            {label?.name ?? "Label"}
          </span>
        }
        subtitle={n ? `${n} ${n === 1 ? "thread" : "threads"} with this label.` : "A label."}
        actions={
          <Button variant="ghost" size="sm" className="text-muted-foreground" asChild>
            <Link to="/labels">All labels</Link>
          </Button>
        }
      />
      <ThreadList showBucket loading={q.isLoading} error={q.error} onRetry={() => q.refetch()} emptyIcon={<Tag />} sections={[{ threads: q.data?.threads ?? [], emptyTitle: "Nothing wears this label yet.", emptyBody: "Select a thread and press b to tag it." }]} />
    </div>
  );
}
