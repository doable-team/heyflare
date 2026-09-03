import { useState } from "react";
import { Link } from "react-router-dom";
import { ArrowUpCircle, X } from "lucide-react";
import type { ThreadSummary } from "@shared/types";
import { cn } from "@/lib/utils";
import { useBulkAction, useThreads } from "../api";
import { useAccount } from "../context/AccountContext";
import { fmtFull, fmtRelative } from "../lib/format";
import { ConnectGmailCard } from "./Imbox";
import { Avatar, AccountGlyph } from "../components/Avatar";
import { EmptyState, ErrorState, PageHeader, SkeletonRows } from "../components/EmptyState";
import { useToast } from "../components/Toast";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { useCardScroll } from "../lib/cardKeys";

const OUT_MS = 120;

export default function BubbleUp() {
  useCardScroll();
  const { accounts, multi, glyphFor, accountFor } = useAccount();
  const q = useThreads("bubble_up", { enabled: accounts.length > 0 });
  const bulk = useBulkAction();
  const { toast } = useToast();
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  if (accounts.length === 0) return <ConnectGmailCard />;
  const list = (q.data?.pages.flatMap((p) => p.threads) ?? []).filter((t) => t.bubble_up_at).sort((a, b) => (a.bubble_up_at ?? 0) - (b.bubble_up_at ?? 0));
  const cancel = (t: ThreadSummary) => {
    setLeaving((l) => new Set([...l, t.id]));
    window.setTimeout(() => {
      bulk.mutate({ thread_ids: [t.id], action: "bubble_up", at: null }, { onSuccess: () => toast("Back in the Imbox now", { kind: "success" }) });
      setLeaving((l) => {
        const n = new Set(l);
        n.delete(t.id);
        return n;
      });
    }, OUT_MS);
  };
  return (
    <div className="max-w-3xl mx-auto">
      <PageHeader className="px-2" title="Bubble Up" subtitle={list.length ? `${list.length} scheduled. Out of sight until the moment you picked.` : "Out of sight until the moment you picked. Then it pops back to the top of New for you."} />
      {q.error && <ErrorState error={q.error} onRetry={() => q.refetch()} />}
      {q.isLoading && <SkeletonRows />}
      {!q.isLoading && list.length === 0 && !q.error && <EmptyState icon={<ArrowUpCircle />} title="Nothing scheduled to bubble up." body="Pick a thread, press z, choose a time." />}
      {list.length > 0 && (
        <ul>
          {list.map((t) => {
            const acct = accountFor(t.account_id);
            return (
              <li key={t.id} className={cn("group flex items-center gap-3 px-2 h-11 rounded-md hover:bg-accent transition-opacity duration-100", leaving.has(t.id) && "opacity-0")}>
                <Avatar email={t.last_from.email} name={t.last_from.name} src={t.last_from.avatar_url} size={20} />
                <Link to={`/t/${t.id}?peek=1`} className="flex-1 min-w-0 flex items-center gap-2">
                  <span className="text-sm truncate">{t.subject || "(no subject)"}</span>
                  {multi && acct && <AccountGlyph glyph={glyphFor(acct.id)} label={acct.email} />}
                  <span className="text-[13px] text-muted-foreground truncate hidden sm:inline">
                    {t.last_from.name || t.last_from.email}
                    {t.snippet ? ` — ${t.snippet}` : ""}
                  </span>
                </Link>
                <Tooltip>
                  <TooltipTrigger asChild>
                    <Badge variant="secondary" className="font-normal tnum shrink-0">
                      <ArrowUpCircle /> {fmtRelative(t.bubble_up_at!)}
                    </Badge>
                  </TooltipTrigger>
                  <TooltipContent>{fmtFull(t.bubble_up_at!)}</TooltipContent>
                </Tooltip>
                <Tooltip>
                  <TooltipTrigger asChild>
                    <Button variant="ghost" size="icon-sm" aria-label="Cancel" className="text-muted-foreground opacity-0 group-hover:opacity-100 focus-visible:opacity-100" onClick={() => cancel(t)}>
                      <X />
                    </Button>
                  </TooltipTrigger>
                  <TooltipContent>Cancel · back to the Imbox now</TooltipContent>
                </Tooltip>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
