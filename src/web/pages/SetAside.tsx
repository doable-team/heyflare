import { useState } from "react";
import { Link } from "react-router-dom";
import { Bookmark, Check, Paperclip, ShieldCheck, StickyNote } from "lucide-react";
import type { ThreadSummary } from "@shared/types";
import { cn } from "@/lib/utils";
import { useBulkAction, useImbox } from "../api";
import { useAccount } from "../context/AccountContext";
import { fmtTime, fmtFull } from "../lib/format";
import { ConnectGmailCard } from "./Imbox";
import { Avatar, AccountGlyph } from "../components/Avatar";
import { EmptyState, ErrorState, PageHeader } from "../components/EmptyState";
import { useToast } from "../components/Toast";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";

const OUT_MS = 120;

function Card({ t, leaving, onDone }: { t: ThreadSummary; leaving: boolean; onDone: () => void }) {
  const { multi, glyphFor, accountFor } = useAccount();
  const acct = accountFor(t.account_id);
  return (
    <article className={cn("group flex flex-col rounded-md bg-muted/40 transition-opacity duration-100", leaving && "opacity-0")}>
      <div className="flex items-center gap-2 px-4 pt-4">
        <Avatar email={t.last_from.email} name={t.last_from.name} src={t.last_from.avatar_url} size={20} />
        <span className="text-[13px] text-muted-foreground truncate flex-1">{t.last_from.name || t.last_from.email}</span>
        {multi && acct && <AccountGlyph glyph={glyphFor(acct.id)} label={acct.email} />}
        <Tooltip>
          <TooltipTrigger asChild>
            <time className="text-xs text-muted-foreground tnum shrink-0">{fmtTime(t.last_message_at)}</time>
          </TooltipTrigger>
          <TooltipContent>{fmtFull(t.last_message_at)}</TooltipContent>
        </Tooltip>
      </div>
      <Link to={`/t/${t.id}`} className="px-4 pt-2 block">
        <h3 className="text-sm font-semibold leading-snug line-clamp-2 hover:underline underline-offset-2">{t.subject || "(no subject)"}</h3>
      </Link>
      <p className="px-4 pt-1 text-[13px] text-muted-foreground leading-relaxed line-clamp-3 flex-1">{t.snippet}</p>
      {t.note && (
        <div className="mx-4 mt-3 rounded-md bg-background px-3 py-2 text-[13px] flex gap-2">
          <StickyNote className="size-3.5 shrink-0 mt-0.5 text-muted-foreground" />
          <span className="line-clamp-2">{t.note}</span>
        </div>
      )}
      <footer className="flex items-center gap-1.5 px-3 py-2 mt-3">
        {t.has_attachments && (
          <Tooltip>
            <TooltipTrigger asChild>
              <Paperclip className="size-3.5 text-muted-foreground" />
            </TooltipTrigger>
            <TooltipContent>Has attachments</TooltipContent>
          </Tooltip>
        )}
        {t.trackers_blocked > 0 && (
          <Tooltip>
            <TooltipTrigger asChild>
              <ShieldCheck className="size-3.5 text-muted-foreground" />
            </TooltipTrigger>
            <TooltipContent>Blocked {t.trackers_blocked} spy tracker{t.trackers_blocked === 1 ? "" : "s"}</TooltipContent>
          </Tooltip>
        )}
        {t.labels.slice(0, 2).map((l) => (
          <Badge key={l.id} variant="outline" className="font-normal text-muted-foreground">
            {l.name}
          </Badge>
        ))}
        <span className="flex-1" />
        <Tooltip>
          <TooltipTrigger asChild>
            <Button size="sm" variant="ghost" className="text-muted-foreground" onClick={onDone}>
              <Check /> Done
            </Button>
          </TooltipTrigger>
          <TooltipContent>Back to the Imbox</TooltipContent>
        </Tooltip>
      </footer>
    </article>
  );
}

export default function SetAside() {
  const { accounts } = useAccount();
  const imbox = useImbox(accounts.length > 0);
  const bulk = useBulkAction();
  const { toast } = useToast();
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  if (accounts.length === 0) return <ConnectGmailCard />;
  const list = imbox.data?.set_aside ?? [];
  const done = (t: ThreadSummary) => {
    setLeaving((l) => new Set([...l, t.id]));
    window.setTimeout(() => {
      bulk.mutate({ thread_ids: [t.id], action: "set_aside", on: false }, { onSuccess: () => toast("Back in the Imbox", { kind: "success" }) });
      setLeaving((l) => {
        const n = new Set(l);
        n.delete(t.id);
        return n;
      });
    }, OUT_MS);
  };
  return (
    <div className="max-w-[1100px] mx-auto">
      <PageHeader className="px-2" title="Set Aside" subtitle={list.length ? `${list.length} set aside. Things you want close at hand.` : "Things you want close at hand. Confirmations, links, reference numbers."} />
      {imbox.error && <ErrorState error={imbox.error} onRetry={() => imbox.refetch()} />}
      {imbox.isLoading && (
        <div className="grid sm:grid-cols-2 lg:grid-cols-3 gap-3" aria-busy>
          {[0, 1, 2].map((i) => (
            <div key={i} className="rounded-md bg-muted/40 p-4 space-y-3">
              <Skeleton className="h-3 w-[50%]" />
              <Skeleton className="h-4 w-[80%]" />
              <Skeleton className="h-3 w-full" />
              <Skeleton className="h-3 w-[70%]" />
            </div>
          ))}
        </div>
      )}
      {!imbox.isLoading && list.length === 0 && !imbox.error && <EmptyState icon={<Bookmark />} title="Nothing set aside." body="Press a on any thread to keep it handy here." />}
      <div className="grid sm:grid-cols-2 lg:grid-cols-3 gap-3 items-start">
        {list.map((t) => (
          <Card key={t.id} t={t} leaving={leaving.has(t.id)} onDone={() => done(t)} />
        ))}
      </div>
    </div>
  );
}
