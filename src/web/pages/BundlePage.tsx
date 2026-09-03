import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { ArrowLeft, Check, Layers, MailOpen, Ungroup } from "lucide-react";
import { toast } from "sonner";
import { useBundle, useBundleMutations, type FeedThread } from "../api";
import { useKeys } from "../lib/keys";
import { BundleAvatar } from "../components/Avatar";
import { ErrorState } from "../components/EmptyState";
import { FeedCard } from "./Feed";
import { Button } from "@/components/ui/button";
import { Kbd } from "@/components/ui/kbd";
import { Skeleton } from "@/components/ui/skeleton";
import { AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle } from "@/components/ui/alert-dialog";

/** A bundle read like The Feed: every message of the batch, newest first. Opening it marks the batch seen. */
export default function BundlePage() {
  const { id } = useParams();
  const nav = useNavigate();
  const q = useBundle(id);
  const m = useBundleMutations();
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  const [confirm, setConfirm] = useState(false);
  const marked = useRef<string | null>(null);
  const b = q.data?.bundle;

  // Like opening a thread: viewing the batch marks it seen (closes it) once.
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
    }, 120);
  };

  // Escape goes back, like the thread view (open menus/dialogs consume it first).
  useKeys(
    {
      Escape: () => {
        if (document.querySelector('[role="menu"],[role="dialog"],[role="alertdialog"],[role="listbox"],[data-slot="popover-content"]')) return;
        nav(-1);
      },
    },
    !confirm,
  );

  if (q.error) return <ErrorState error={q.error} onRetry={() => q.refetch()} />;
  if (!q.data || !b) return <div className="max-w-2xl mx-auto px-2 space-y-3"><Skeleton className="h-8 w-48" /><Skeleton className="h-40" /><Skeleton className="h-40" /></div>;
  const threads = q.data.threads.filter((t) => t.latest_message) as FeedThread[];
  const bucketPath = b.latest?.bucket === "paper_trail" ? "/paper-trail" : "/";
  return (
    <div className="max-w-2xl mx-auto">
      <div className="px-2 mb-3">
        <Button variant="ghost" size="sm" className="-ml-2 text-muted-foreground" onClick={() => nav(-1)}>
          <ArrowLeft /> Back <Kbd>esc</Kbd>
        </Button>
      </div>
      <header className="px-2 flex items-center gap-3 mb-6">
        <BundleAvatar email={b.email} name={b.name} src={b.avatar_url} size={40} />
        <div className="min-w-0 flex-1">
          <h1 className="text-[22px] leading-7 font-semibold tracking-[-0.01em] truncate flex items-center gap-2">
            {b.name || b.email}
            <Layers size={16} className="text-muted-foreground" aria-label="Bundle" />
          </h1>
          <div className="text-[13px] text-muted-foreground truncate tnum">
            {b.message_count} {b.message_count === 1 ? "message" : "messages"} · {b.thread_count} {b.thread_count === 1 ? "thread" : "threads"} ·{" "}
            <Link to={`/contacts/${b.contact_id}`} className="hover:text-foreground underline-offset-2 hover:underline">Open contact</Link>
          </div>
        </div>
        <div className="flex items-center gap-1 shrink-0">
          {b.status === "open" ? (
            <Button variant="outline" size="sm" disabled={m.seen.isPending} onClick={() => m.seen.mutate(b.id, { onSuccess: () => toast("Marked as seen") })}>
              <Check /> Mark as seen
            </Button>
          ) : (
            <Button variant="outline" size="sm" disabled={m.unseen.isPending} onClick={() => m.unseen.mutate(b.id, { onSuccess: () => toast("Marked unread") })}>
              <MailOpen /> Mark unread
            </Button>
          )}
          <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={() => setConfirm(true)}>
            <Ungroup /> Unbundle
          </Button>
        </div>
      </header>
      <div className="space-y-4">
        {threads.map((t) => (
          <div key={t.id} className={leaving.has(t.id) ? "opacity-0 transition-opacity duration-100" : "transition-opacity duration-100"}>
            <FeedCard t={t} onLeave={onLeave} />
          </div>
        ))}
        {threads.length === 0 && <div className="px-2 text-sm text-muted-foreground">Nothing in this bundle yet.</div>}
      </div>
      <AlertDialog open={confirm} onOpenChange={setConfirm}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Unbundle these messages?</AlertDialogTitle>
            <AlertDialogDescription>The {b.thread_count} {b.thread_count === 1 ? "thread" : "threads"} in this bundle go back to being separate rows. The sender stays bundled for future mail; turn that off on their contact page.</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={() => m.dissolve.mutate(b.id, { onSuccess: () => { toast("Unbundled"); nav(bucketPath); } })}>Unbundle</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
