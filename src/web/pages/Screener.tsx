import { useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { Check, FileText, Inbox, Paperclip, Receipt, Rss, ShieldOff, UserRound, X } from "lucide-react";
import type { ScreenStatus } from "@shared/types";
import { cn } from "@/lib/utils";
import { useScreener, useScreenerDecide, type ScreenerSender } from "../api";
import { useAccount } from "../context/AccountContext";
import { useKeys } from "../lib/keys";
import { overlayOpen, useFocusRegion } from "../lib/focusStore";
import { scrollPageBy } from "../lib/cardKeys";
import { fmtTime } from "../lib/format";
import { ConnectGmailCard } from "./Imbox";
import { Avatar, AccountGlyph } from "../components/Avatar";
import { EmptyState, ErrorState, PageHeader } from "../components/EmptyState";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Kbd } from "@/components/ui/kbd";
import { Skeleton } from "@/components/ui/skeleton";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";

type Target = "imbox" | "feed" | "paper_trail";
const OUT_MS = 120;

const TARGETS: { value: Target; label: string; icon: React.ReactNode }[] = [
  { value: "imbox", label: "Imbox", icon: <Inbox /> },
  { value: "feed", label: "The Feed", icon: <Rss /> },
  { value: "paper_trail", label: "Paper Trail", icon: <FileText /> },
];

function reason(s: ScreenerSender): { text: string; icon: React.ReactNode } {
  if (s.suggestion === "feed") {
    const unsub = s.threads.some((t) => /unsubscribe/i.test(t.snippet));
    return { text: unsub ? "Has an unsubscribe link" : "Looks like a newsletter", icon: <Rss /> };
  }
  if (s.suggestion === "paper_trail") return { text: "Looks like a receipt", icon: <Receipt /> };
  return { text: "Probably a person", icon: <UserRound /> };
}

function SenderCard({
  s,
  index,
  focused,
  leaving,
  target,
  onTarget,
  onDecide,
  onFocus,
}: {
  s: ScreenerSender;
  index: number;
  focused: boolean;
  leaving: "yes" | "no" | null;
  target: Target;
  onTarget: (t: Target) => void;
  onDecide: (d: ScreenStatus) => void;
  onFocus: () => void;
}) {
  const { multi, glyphFor, accountFor } = useAccount();
  const why = reason(s);
  const domain = s.contact.email.split("@")[1] ?? "";
  const previews = s.threads.slice(0, 3);
  const rest = s.threads.length - previews.length;
  const acct = accountFor(s.contact.account_id);
  return (
    <article
      data-screener-index={index}
      onMouseEnter={onFocus}
      onClick={onFocus}
      className={cn(
        "relative flex flex-col min-w-0 rounded-md bg-muted/40 scroll-mt-20 transition-opacity duration-100",
        focused && "ring-1 ring-border",
        leaving && "opacity-0",
      )}
    >
      <header className="flex items-start gap-3 px-4 pt-4">
        <Avatar email={s.contact.email} name={s.contact.name} src={s.contact.avatar_url} size={32} />
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 min-w-0">
            <h3 className="text-sm font-semibold truncate">{s.contact.name || s.contact.email.split("@")[0]}</h3>
            {multi && acct && <AccountGlyph glyph={glyphFor(acct.id)} label={acct.email} />}
          </div>
          <div className="text-[13px] text-muted-foreground truncate">{s.contact.email}</div>
          <div className="mt-2 flex items-center gap-1.5 flex-wrap">
            <Badge variant="outline" className="font-normal text-muted-foreground gap-1">
              {why.icon} {why.text}
            </Badge>
            {domain && (
              <Badge variant="outline" className="font-normal text-muted-foreground">
                @{domain}
              </Badge>
            )}
            <span className="text-xs text-muted-foreground tnum ml-0.5">
              {s.contact.message_count} message{s.contact.message_count === 1 ? "" : "s"} · first wrote {fmtTime(s.contact.first_seen_at)}
            </span>
          </div>
        </div>
      </header>

      <ul className="mx-4 mt-3 mb-3">
        {previews.map((t) => (
          <li key={t.id} className="py-1.5 min-w-0">
            <Link to={`/t/${t.id}?peek=1`} className="flex items-baseline gap-2 min-w-0 group">
              <span className="text-sm truncate group-hover:underline underline-offset-2">{t.subject || "(no subject)"}</span>
              {t.has_attachments && <Paperclip className="size-3 text-muted-foreground shrink-0 self-center" />}
              <span className="ml-auto text-xs text-muted-foreground tnum shrink-0">{fmtTime(t.last_message_at)}</span>
            </Link>
            {t.snippet && <div className="text-[13px] text-muted-foreground truncate">{t.snippet}</div>}
          </li>
        ))}
        {rest > 0 && <li className="py-1 text-xs text-muted-foreground">+{rest} more</li>}
      </ul>

      <footer className="mt-auto px-3 pb-3 space-y-2">
        <ToggleGroup type="single" size="sm" variant="outline" spacing={0} value={target} onValueChange={(v) => v && onTarget(v as Target)} aria-label="Deliver to">
          {TARGETS.map((t, i) => (
            <Tooltip key={t.value}>
              <TooltipTrigger asChild>
                <ToggleGroupItem value={t.value} aria-label={t.label} className="text-muted-foreground aria-checked:bg-background aria-checked:text-foreground aria-checked:shadow-sm aria-checked:font-medium">
                  {t.icon} {t.label}
                </ToggleGroupItem>
              </TooltipTrigger>
              <TooltipContent>
                Deliver to {t.label} <Kbd className="ml-1">{i + 1}</Kbd>
              </TooltipContent>
            </Tooltip>
          ))}
        </ToggleGroup>
        <div className="flex items-center gap-1 justify-end">
          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={() => onDecide("screened_out")}>
                <X /> Screen out
              </Button>
            </TooltipTrigger>
            <TooltipContent>
              Never see them again <Kbd className="ml-1">n</Kbd>
            </TooltipContent>
          </Tooltip>
          <Tooltip>
            <TooltipTrigger asChild>
              <Button size="sm" onClick={() => onDecide(target)}>
                <Check /> Let them in
              </Button>
            </TooltipTrigger>
            <TooltipContent>
              Deliver to {TARGETS.find((t) => t.value === target)?.label} <Kbd className="ml-1">y</Kbd>
            </TooltipContent>
          </Tooltip>
        </div>
      </footer>
    </article>
  );
}

export default function Screener() {
  const { accounts, user } = useAccount();
  const s = useScreener(accounts.length > 0);
  const decide = useScreenerDecide();
  const senders = useMemo(() => s.data?.senders ?? [], [s.data]);
  const [cursor, setCursor] = useState(0);
  const [targets, setTargets] = useState<Record<string, Target>>({});
  const [leaving, setLeaving] = useState<Record<string, "yes" | "no">>({});
  const timers = useRef<number[]>([]);
  useEffect(() => () => timers.current.forEach(clearTimeout), []);
  useEffect(() => {
    if (cursor >= senders.length) setCursor(Math.max(0, senders.length - 1));
  }, [senders.length, cursor]);

  const targetFor = (x: ScreenerSender): Target => targets[x.contact.id] ?? (x.suggestion === "imbox" ? user?.settings?.defaultScreenTarget ?? "imbox" : x.suggestion);

  const act = (x: ScreenerSender, d: ScreenStatus) => {
    if (leaving[x.contact.id]) return;
    setLeaving((l) => ({ ...l, [x.contact.id]: d === "screened_out" ? "no" : "yes" }));
    timers.current.push(
      window.setTimeout(() => {
        decide.mutate({ contact_id: x.contact.id, decision: d });
        setLeaving((l) => {
          const n = { ...l };
          delete n[x.contact.id];
          return n;
        });
      }, OUT_MS),
    );
  };

  const current = senders[cursor];
  const region = useFocusRegion();
  const move = (delta: number) => {
    if (overlayOpen()) return;
    setCursor((c) => {
      const next = Math.min(Math.max(c + delta, 0), senders.length - 1);
      // Nowhere left to go: let the arrows scroll the page instead of doing nothing.
      if (next === c) scrollPageBy(delta * 0.25);
      else requestAnimationFrame(() => document.querySelector(`[data-screener-index="${next}"]`)?.scrollIntoView({ block: "nearest" }));
      return next;
    });
  };
  useKeys(
    {
      j: () => move(1),
      k: () => move(-1),
      ArrowDown: () => move(1),
      ArrowUp: () => move(-1),
      y: () => current && act(current, targetFor(current)),
      n: () => current && act(current, "screened_out"),
      "1": () => current && setTargets((t) => ({ ...t, [current.contact.id]: "imbox" })),
      "2": () => current && setTargets((t) => ({ ...t, [current.contact.id]: "feed" })),
      "3": () => current && setTargets((t) => ({ ...t, [current.contact.id]: "paper_trail" })),
    },
    senders.length > 0 && region === "content",
  );

  if (accounts.length === 0) return <ConnectGmailCard />;
  const waiting = senders.length;
  return (
    <div className="max-w-[1100px] mx-auto">
      <PageHeader
        className="px-2"
        title="The Screener"
        subtitle={waiting ? `${waiting} ${waiting === 1 ? "sender" : "senders"} waiting. Say yes and pick where their mail goes, or say no and never hear from them again.` : "First-time senders wait here. Nobody waiting right now."}
        actions={
          <Button variant="ghost" size="sm" className="text-muted-foreground" asChild>
            <Link to="/screened-out">
              <ShieldOff /> Screened out
            </Link>
          </Button>
        }
      />
      {s.error && <ErrorState error={s.error} onRetry={() => s.refetch()} />}
      {s.isLoading && (
        <div className="grid grid-cols-1 gap-3 min-[1100px]:grid-cols-2" aria-busy>
          {[0, 1, 2, 3].map((i) => (
            <div key={i} className="rounded-md bg-muted/40 p-4 space-y-3">
              <div className="flex gap-3">
                <Skeleton className="size-8 rounded-[4px]" />
                <div className="flex-1 space-y-2 pt-1">
                  <Skeleton className="h-3 w-[40%]" />
                  <Skeleton className="h-3 w-[60%]" />
                </div>
              </div>
              <Skeleton className="h-14" />
              <Skeleton className="h-7 w-[60%]" />
            </div>
          ))}
        </div>
      )}
      {!s.isLoading && waiting === 0 && !s.error && (
        <EmptyState
          icon={<ShieldOff />}
          title="Nobody at the door."
          body="Every new sender has been dealt with."
          action={
            <Button variant="ghost" size="sm" asChild>
              <Link to="/">Back to the Imbox</Link>
            </Button>
          }
        />
      )}
      {waiting > 0 && (
        <>
          <div className="grid grid-cols-1 gap-3 min-[1100px]:grid-cols-2 items-start">
            {senders.map((x, i) => (
              <SenderCard
                key={x.contact.id}
                s={x}
                index={i}
                focused={i === cursor}
                leaving={leaving[x.contact.id] ?? null}
                target={targetFor(x)}
                onTarget={(t) => setTargets((m) => ({ ...m, [x.contact.id]: t }))}
                onDecide={(d) => act(x, d)}
                onFocus={() => setCursor(i)}
              />
            ))}
          </div>
          <p className="hidden md:flex items-center gap-1.5 justify-center mt-8 text-xs text-muted-foreground">
            <Kbd>j</Kbd>
            <Kbd>k</Kbd> move <span className="mx-1">·</span> <Kbd>y</Kbd> let in <span className="mx-1">·</span> <Kbd>n</Kbd> screen out <span className="mx-1">·</span> <Kbd>1</Kbd>
            <Kbd>2</Kbd>
            <Kbd>3</Kbd> pick a place
          </p>
        </>
      )}
    </div>
  );
}
