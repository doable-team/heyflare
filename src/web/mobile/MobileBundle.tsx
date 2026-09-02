import { useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { Check, MailOpen, MoreHorizontal, Ungroup, User } from "lucide-react";
import { toast } from "sonner";
import { useBundle, useBundleMutations, type FeedThread } from "../api";
import { BundleAvatar } from "../components/Avatar";
import { ErrorState } from "../components/EmptyState";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";
import { Screen } from "./Screen";
import { ActionSheet } from "./ActionSheet";
import { MobileFeedCard } from "./MobileFeed";

/** Mobile bundle page: the batch read like The Feed, newest first. Opening marks it seen. */
export default function MobileBundle() {
  const { id } = useParams();
  const nav = useNavigate();
  const q = useBundle(id);
  const m = useBundleMutations();
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  const [more, setMore] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const marked = useRef<string | null>(null);
  const b = q.data?.bundle;
  useEffect(() => {
    if (!b || b.status !== "open" || marked.current === b.id) return;
    marked.current = b.id;
    m.seen.mutate(b.id);
  }, [b?.id, b?.status]);
  const onLeave = (tid: string, cb: () => void) => {
    setLeaving((l) => new Set([...l, tid]));
    window.setTimeout(() => {
      cb();
      setLeaving((l) => {
        const n = new Set(l);
        n.delete(tid);
        return n;
      });
    }, 160);
  };
  const threads = (q.data?.threads ?? []).filter((t) => t.latest_message) as FeedThread[];
  const bucketPath = b?.latest?.bucket === "paper_trail" ? "/paper-trail" : "/";
  return (
    <Screen
      title={b?.name || b?.email || "Bundle"}
      back
      backLabel={b?.latest?.bucket === "paper_trail" ? "Paper Trail" : "Imbox"}
      titleOnScroll
      right={
        b ? (
          <Button variant="ghost" size="icon" className="size-10" aria-label="More" onClick={() => setMore(true)}>
            <MoreHorizontal />
          </Button>
        ) : undefined
      }
    >
      {q.error && <ErrorState error={q.error} onRetry={() => q.refetch()} />}
      {!q.data && !q.error && (
        <div className="px-4 pt-2 space-y-3" aria-busy>
          <Skeleton className="h-10 w-2/3" />
          <Skeleton className="h-40" />
        </div>
      )}
      {b && (
        <div className="px-4 pt-2 pb-3 flex items-center gap-3">
          <BundleAvatar email={b.email} name={b.name} src={b.avatar_url} size={40} />
          <div className="min-w-0">
            <div className="text-[20px] leading-6 font-semibold truncate">{b.name || b.email}</div>
            <div className="text-[13px] text-muted-foreground truncate tnum">
              {b.message_count} {b.message_count === 1 ? "message" : "messages"} · {b.thread_count} {b.thread_count === 1 ? "thread" : "threads"}
            </div>
          </div>
        </div>
      )}
      <div className="divide-y divide-border">
        {threads.map((t) => (
          <div key={t.id} className={leaving.has(t.id) ? "opacity-0 transition-opacity duration-150" : "transition-opacity duration-150"}>
            <MobileFeedCard t={t} onLeave={onLeave} />
          </div>
        ))}
      </div>
      {b && (
        <ActionSheet
          open={more}
          onOpenChange={setMore}
          title={b.name || b.email}
          actions={[
            b.status === "open"
              ? { label: "Mark as seen", icon: <Check />, onSelect: () => m.seen.mutate(b.id, { onSuccess: () => toast("Marked as seen") }) }
              : { label: "Mark unread", icon: <MailOpen />, onSelect: () => m.unseen.mutate(b.id, { onSuccess: () => toast("Marked unread") }) },
            { label: "Open contact", icon: <User />, onSelect: () => nav(`/contacts/${b.contact_id}`) },
            { label: "Unbundle these messages", icon: <Ungroup />, destructive: true, onSelect: () => setConfirm(true) },
          ]}
        />
      )}
      {b && (
        <AlertDialog open={confirm} onOpenChange={setConfirm}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Unbundle these messages?</AlertDialogTitle>
              <AlertDialogDescription>They go back to being separate rows. The sender stays bundled for future mail.</AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancel</AlertDialogCancel>
              <AlertDialogAction onClick={() => m.dissolve.mutate(b.id, { onSuccess: () => { toast("Unbundled"); nav(bucketPath, { replace: true }); } })}>Unbundle</AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      )}
    </Screen>
  );
}
