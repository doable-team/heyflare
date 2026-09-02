import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { ArrowUpRight, Check, ChevronLeft, ChevronRight, Clock, Reply, SkipForward } from "lucide-react";
import type { ThreadSummary } from "@shared/types";
import { cn } from "@/lib/utils";
import { useBulkAction, useImbox, useThread } from "../api";
import { useAccount } from "../context/AccountContext";
import { useKeys } from "../lib/keys";
import { fmtFull, fmtTime } from "../lib/format";
import { ConnectGmailCard } from "./Imbox";
import { HtmlBody } from "../components/HtmlBody";
import { Composer } from "../components/Composer";
import { replyInitial } from "./Thread";
import { Avatar, AvatarStack, AccountGlyph } from "../components/Avatar";
import { EmptyState, ErrorState, PageHeader, SectionTitle } from "../components/EmptyState";
import { useToast } from "../components/Toast";
import { Button } from "@/components/ui/button";
import { Kbd } from "@/components/ui/kbd";
import { Progress } from "@/components/ui/progress";
import { Skeleton } from "@/components/ui/skeleton";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";

function Focus({ t, index, total, onPrev, onNext, onDone }: { t: ThreadSummary; index: number; total: number; onPrev: () => void; onNext: () => void; onDone: () => void }) {
  const { multi, glyphFor, accountFor } = useAccount();
  const acct = accountFor(t.account_id);
  const detail = useThread(t.id, true);
  const [replying, setReplying] = useState(false);
  useEffect(() => setReplying(false), [t.id]);
  const msgs = detail.data?.messages ?? [];
  const last = msgs[msgs.length - 1];
  const lastIncoming = [...msgs].reverse().find((m) => !m.is_from_me) ?? last;
  const earlier = msgs.length - 1;
  return (
    <section key={t.id} className="rounded-md bg-muted/40">
      <header className="px-5 pt-4">
        <div className="flex items-center gap-3 mb-3">
          <span className="text-xs text-muted-foreground tnum">
            {index + 1} of {total}
          </span>
          <Progress value={((index + 1) / total) * 100} className="h-1 w-24" />
          <span className="text-xs text-muted-foreground tnum hidden sm:inline">Last message {fmtTime(t.last_message_at)}</span>
          <span className="flex-1" />
          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="icon-sm" aria-label="Previous" onClick={onPrev} disabled={index === 0}>
                <ChevronLeft />
              </Button>
            </TooltipTrigger>
            <TooltipContent>
              Previous <Kbd className="ml-1">k</Kbd>
            </TooltipContent>
          </Tooltip>
          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="icon-sm" aria-label="Next" onClick={onNext} disabled={index >= total - 1}>
                <ChevronRight />
              </Button>
            </TooltipTrigger>
            <TooltipContent>
              Next <Kbd className="ml-1">j</Kbd>
            </TooltipContent>
          </Tooltip>
        </div>
        <h2 className="text-2xl font-semibold tracking-[-0.02em] leading-tight">{t.subject || "(no subject)"}</h2>
        <div className="mt-2 flex items-center gap-2 min-w-0">
          <AvatarStack people={t.participants.length ? t.participants : [t.last_from]} size={18} />
          <span className="text-[13px] text-muted-foreground truncate">
            {t.last_from.name || t.last_from.email}
            {t.participants.length > 1 ? ` and ${t.participants.length - 1} other${t.participants.length > 2 ? "s" : ""}` : ""}
          </span>
          {multi && acct && <AccountGlyph glyph={glyphFor(acct.id)} label={acct.email} />}
        </div>
      </header>

      <div className="px-5 pt-5 pb-2 min-h-[140px]">
        {detail.isLoading && (
          <div className="space-y-3" aria-busy>
            <Skeleton className="h-3 w-[40%]" />
            <Skeleton className="h-3 w-full" />
            <Skeleton className="h-3 w-[90%]" />
            <Skeleton className="h-3 w-[70%]" />
          </div>
        )}
        {detail.error && <ErrorState error={detail.error} onRetry={() => detail.refetch()} />}
        {last && (
          <div>
            {earlier > 0 && (
              <Link to={`/t/${t.id}`} className="inline-flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground mb-3">
                {earlier} earlier message{earlier === 1 ? "" : "s"} in this thread <ArrowUpRight className="size-3" />
              </Link>
            )}
            <div className="flex items-center gap-2.5 mb-3">
              <Avatar email={last.from.email} name={last.from.name} src={last.from.avatar_url} size={24} />
              <div className="min-w-0 flex items-baseline gap-2">
                <span className="text-sm font-medium truncate">{last.from.name || last.from.email}</span>
                <span className="text-xs text-muted-foreground truncate">{fmtFull(last.date)}</span>
              </div>
            </div>
            <HtmlBody html={last.html_body} text={last.text_body} trackers={last.trackers} />
          </div>
        )}
      </div>

      {replying && detail.data && lastIncoming ? (
        <div className="p-3">
          <div className="rounded-md bg-background">
            <Composer
              inline
              initial={replyInitial(detail.data, lastIncoming, "reply", acct?.email)}
              onDone={() => {
                setReplying(false);
                onDone();
              }}
              onCancel={() => setReplying(false)}
            />
          </div>
        </div>
      ) : (
        <footer className="flex items-center gap-1 px-3 py-3 flex-wrap">
          <Button size="sm" onClick={() => setReplying(true)} disabled={!lastIncoming}>
            <Reply /> Reply
          </Button>
          <Button variant="ghost" size="sm" className="text-muted-foreground" asChild>
            <Link to={`/t/${t.id}`}>
              <ArrowUpRight /> <span className="hidden sm:inline">Open thread</span>
            </Link>
          </Button>
          <span className="flex-1" />
          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={onNext} disabled={index >= total - 1}>
                <SkipForward /> Skip
              </Button>
            </TooltipTrigger>
            <TooltipContent>
              Leave it in the pile, look at the next one <Kbd className="ml-1">j</Kbd>
            </TooltipContent>
          </Tooltip>
          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="outline" size="sm" onClick={onDone}>
                <Check /> Done
              </Button>
            </TooltipTrigger>
            <TooltipContent>
              Remove from Reply Later <Kbd className="ml-1">d</Kbd>
            </TooltipContent>
          </Tooltip>
        </footer>
      )}
    </section>
  );
}

export default function ReplyLater() {
  const { accounts } = useAccount();
  const imbox = useImbox(accounts.length > 0);
  const bulk = useBulkAction();
  const { toast } = useToast();
  const list = useMemo(() => imbox.data?.reply_later ?? [], [imbox.data]);
  const [currentId, setCurrentId] = useState<string | null>(null);
  const index = Math.max(0, list.findIndex((t) => t.id === currentId));
  const current = list[index] ?? list[0];
  useEffect(() => {
    if (list.length && !list.some((t) => t.id === currentId)) setCurrentId(list[Math.min(index, list.length - 1)]?.id ?? null);
  }, [list, currentId, index]);

  const go = (d: 1 | -1) => {
    const i = Math.min(Math.max(index + d, 0), list.length - 1);
    setCurrentId(list[i]?.id ?? null);
  };
  const done = (t: ThreadSummary) => {
    const next = list[index + 1] ?? list[index - 1] ?? null;
    setCurrentId(next?.id ?? null);
    bulk.mutate({ thread_ids: [t.id], action: "reply_later", on: false }, { onSuccess: () => toast("Done. Out of the pile.", { kind: "success" }) });
  };

  useKeys(
    {
      j: () => go(1),
      k: () => go(-1),
      ArrowRight: () => go(1),
      ArrowLeft: () => go(-1),
      d: () => current && done(current),
    },
    list.length > 0,
  );

  if (accounts.length === 0) return <ConnectGmailCard />;
  return (
    <div className="max-w-2xl mx-auto">
      <PageHeader className="px-2" title="Focus & Reply" subtitle={list.length ? `${list.length} waiting on you. One at a time, nothing else in view.` : "Just the things you said you'd reply to. One at a time."} />
      {imbox.error && <ErrorState error={imbox.error} onRetry={() => imbox.refetch()} />}
      {imbox.isLoading && (
        <div className="rounded-md bg-muted/40 p-5 space-y-4" aria-busy>
          <Skeleton className="h-3 w-16" />
          <Skeleton className="h-6 w-[60%]" />
          <Skeleton className="h-3 w-[35%]" />
          <Skeleton className="h-32" />
        </div>
      )}
      {!imbox.isLoading && list.length === 0 && !imbox.error && <EmptyState icon={<Clock />} title="Nothing waiting on you." body="Hit Reply Later on any thread and it stacks up here." />}
      {current && (
        <>
          <Focus t={current} index={index} total={list.length} onPrev={() => go(-1)} onNext={() => go(1)} onDone={() => done(current)} />
          {list.length > 1 && (
            <div className="mt-6">
              <SectionTitle>Up next</SectionTitle>
              <ol>
                {list.map((t, i) => (
                  <li key={t.id}>
                    <button
                      type="button"
                      onClick={() => setCurrentId(t.id)}
                      className={cn("w-full flex items-center gap-3 px-2 h-10 rounded-md text-left hover:bg-accent", i === index && "bg-accent")}
                    >
                      <span className="text-xs text-muted-foreground tnum w-4 text-right">{i + 1}</span>
                      <Avatar email={t.last_from.email} name={t.last_from.name} src={t.last_from.avatar_url} size={20} />
                      <span className={cn("text-sm truncate flex-1", i === index && "font-medium")}>{t.subject || "(no subject)"}</span>
                      <span className="text-xs text-muted-foreground truncate hidden sm:inline max-w-[35%]">{t.last_from.name || t.last_from.email}</span>
                      <time className="text-xs text-muted-foreground tnum shrink-0">{fmtTime(t.last_message_at)}</time>
                    </button>
                  </li>
                ))}
              </ol>
            </div>
          )}
          <p className="hidden md:flex items-center gap-1.5 justify-center mt-8 text-xs text-muted-foreground">
            <Kbd>j</Kbd>
            <Kbd>k</Kbd> next / previous <span className="mx-1">·</span> <Kbd>d</Kbd> done
          </p>
        </>
      )}
    </div>
  );
}
