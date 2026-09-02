import { useState } from "react";
import { Link } from "react-router-dom";
import { Check, Copy, MessageSquare, Scissors, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { cn } from "@/lib/utils";
import { useClipMutations, useClips } from "../api";
import { EmptyState, ErrorState, PageHeader, SkeletonRows } from "../components/EmptyState";
import { fmtDate } from "../lib/format";
import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";

function ClipRow({ id, text, thread_id, thread_subject, created_at }: { id: string; text: string; thread_id: string; thread_subject?: string; created_at: number }) {
  const { remove } = useClipMutations();
  const [copied, setCopied] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const codeLike = text.length < 80 && /^[A-Z0-9\-]{4,24}$/.test(text.trim());
  const copy = () =>
    navigator.clipboard.writeText(text).then(() => {
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1400);
    });
  const del = () => {
    setLeaving(true);
    window.setTimeout(() => remove.mutate(id, { onError: (e) => { setLeaving(false); toast.error((e as Error).message); } }), 120);
  };
  return (
    <article className={cn("group rounded-md px-3 py-2.5 hover:bg-muted transition-colors duration-100", leaving && "opacity-0")}>
      {codeLike ? (
        <div className="font-mono text-base tracking-wider tnum select-all break-all py-1">{text.trim()}</div>
      ) : (
        <blockquote className="text-sm leading-relaxed whitespace-pre-wrap break-words line-clamp-6">{text}</blockquote>
      )}
      <footer className="mt-1.5 flex items-center gap-2 text-xs text-muted-foreground">
        <Link to={`/t/${thread_id}`} className="inline-flex items-center gap-1.5 min-w-0 hover:text-foreground">
          <MessageSquare size={12} className="shrink-0" />
          <span className="truncate max-w-[280px]">{thread_subject || "Open thread"}</span>
        </Link>
        <span className="text-tertiary">·</span>
        <span className="tnum">{fmtDate(created_at)}</span>
        <span className="flex-1" />
        <span className="inline-flex items-center opacity-0 group-hover:opacity-100 focus-within:opacity-100 transition-opacity">
          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="icon-xs" aria-label={copied ? "Copied" : "Copy"} onClick={copy} className="text-muted-foreground hover:text-foreground">
                {copied ? <Check /> : <Copy />}
              </Button>
            </TooltipTrigger>
            <TooltipContent>{copied ? "Copied" : "Copy"}</TooltipContent>
          </Tooltip>
          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="icon-xs" aria-label="Delete clip" onClick={del} className="text-muted-foreground hover:text-foreground">
                <Trash2 />
              </Button>
            </TooltipTrigger>
            <TooltipContent>Delete</TooltipContent>
          </Tooltip>
        </span>
      </footer>
    </article>
  );
}

export default function Clips() {
  const q = useClips();
  const list = q.data ?? [];
  return (
    <div className="max-w-3xl mx-auto">
      <PageHeader title="Clips" subtitle="Bits of text you saved. Codes, addresses, the good sentence." />
      {q.error && <ErrorState error={q.error} onRetry={() => q.refetch()} />}
      {q.isLoading && <SkeletonRows rows={5} />}
      {!q.isLoading && list.length === 0 && !q.error && (
        <EmptyState icon={<Scissors />} title="Nothing clipped yet." body="Select any text inside an email and hit Save clip. It'll wait here so you never dig for it again." />
      )}
      <div className="space-y-0.5">
        {list.map((c) => (
          <ClipRow key={c.id} id={c.id} text={c.text} thread_id={c.thread_id} thread_subject={c.thread_subject} created_at={c.created_at} />
        ))}
      </div>
    </div>
  );
}
