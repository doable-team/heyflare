import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Check, FileText, Inbox, Paperclip, Receipt, Rss, ShieldOff, UserRound, X } from "lucide-react";
import type { ScreenStatus } from "@shared/types";
import { cn } from "@/lib/utils";
import { useScreener, useScreenerDecide, type ScreenerSender } from "../api";
import { useAccount } from "../context/AccountContext";
import { fmtTime } from "../lib/format";
import { Avatar, AccountGlyph } from "../components/Avatar";
import { ErrorState } from "../components/EmptyState";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { Screen } from "./Screen";
import { MobileConnectCard } from "./MobileImbox";
import { MobileEmpty } from "./MobileList";
import { useSwipe } from "./useSwipe";

type Target = "imbox" | "feed" | "paper_trail";
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

function Card({ s, target, onTarget, onDecide, leaving }: { s: ScreenerSender; target: Target; onTarget: (t: Target) => void; onDecide: (d: ScreenStatus) => void; leaving: "yes" | "no" | null }) {
  const { multi, glyphFor, accountFor } = useAccount();
  const nav = useNavigate();
  const swipe = useSwipe({ threshold: 120, onRight: () => onDecide(target), onLeft: () => onDecide("screened_out") });
  const why = reason(s);
  const domain = s.contact.email.split("@")[1] ?? "";
  const acct = accountFor(s.contact.account_id);
  const previews = s.threads.slice(0, 2);
  return (
    <div className={cn("relative mx-4 overflow-hidden rounded-xl transition-all duration-200", leaving && "opacity-0 max-h-0 my-0")}>
      {swipe.dx > 0 && (
        <div className="absolute inset-0 rounded-xl bg-muted flex items-center pl-6 text-[14px] font-medium">
          <span className={cn("flex items-center gap-2 transition-transform [&>svg]:size-5", swipe.past && "scale-110")}><Check /> Let in · {TARGETS.find((t) => t.value === target)?.label}</span>
        </div>
      )}
      {swipe.dx < 0 && (
        <div className="absolute inset-0 rounded-xl bg-muted flex items-center justify-end pr-6 text-[14px] font-medium">
          <span className={cn("flex items-center gap-2 transition-transform [&>svg]:size-5", swipe.past && "scale-110")}>Screen out <X /></span>
        </div>
      )}
      <article
        {...swipe.handlers}
        className="relative touch-pan-y select-none [-webkit-touch-callout:none] rounded-xl bg-muted/50 px-4 pt-4 pb-3"
        style={{ transform: `translateX(${swipe.dx}px)`, transition: swipe.dragging ? "none" : "transform 220ms cubic-bezier(.2,.8,.2,1)" }}
      >
        <header className="flex items-start gap-3">
          <Avatar email={s.contact.email} name={s.contact.name} src={s.contact.avatar_url} size={48} />
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2 min-w-0">
              <h3 className="text-[17px] font-semibold truncate">{s.contact.name || s.contact.email.split("@")[0]}</h3>
              {multi && acct && <AccountGlyph glyph={glyphFor(acct.id)} label={acct.email} />}
            </div>
            <div className="text-[14px] text-muted-foreground truncate">{s.contact.email}</div>
            <div className="mt-1.5 flex items-center gap-1.5 flex-wrap">
              <Badge variant="outline" className="font-normal text-muted-foreground gap-1 h-6">{why.icon} {why.text}</Badge>
              {domain && <Badge variant="outline" className="font-normal text-muted-foreground h-6">@{domain}</Badge>}
            </div>
          </div>
        </header>
        <ul className="mt-3 divide-y divide-border/60">
          {previews.map((t) => (
            <li key={t.id} className="py-2 min-w-0" onClick={() => !swipe.consumeClick() && nav(`/t/${t.id}?peek=1`)}>
              <div className="flex items-center gap-2 min-w-0">
                <span className="text-[15px] truncate">{t.subject || "(no subject)"}</span>
                {t.has_attachments && <Paperclip className="size-3.5 text-muted-foreground shrink-0" />}
                <span className="ml-auto text-[12px] text-muted-foreground tnum shrink-0">{fmtTime(t.last_message_at)}</span>
              </div>
              {t.snippet && <div className="text-[14px] text-muted-foreground truncate">{t.snippet}</div>}
            </li>
          ))}
          {s.threads.length > 2 && <li className="py-1.5 text-[12px] text-muted-foreground">+{s.threads.length - 2} more</li>}
        </ul>
        <div className="mt-3">
          <ToggleGroup type="single" variant="outline" spacing={0} value={target} onValueChange={(v) => v && onTarget(v as Target)} className="w-full grid grid-cols-3" aria-label="Deliver to">
            {TARGETS.map((t) => (
              <ToggleGroupItem key={t.value} value={t.value} aria-label={t.label} className="h-10 text-[13px] text-muted-foreground aria-checked:bg-background aria-checked:text-foreground aria-checked:shadow-sm aria-checked:font-medium">
                {t.icon} {t.label}
              </ToggleGroupItem>
            ))}
          </ToggleGroup>
        </div>
        <div className="mt-2 grid grid-cols-2 gap-2">
          <Button variant="outline" size="lg" className="h-12 text-[15px]" onClick={() => onDecide("screened_out")}>
            <X /> Screen out
          </Button>
          <Button size="lg" className="h-12 text-[15px]" onClick={() => onDecide(target)}>
            <Check /> Let them in
          </Button>
        </div>
      </article>
    </div>
  );
}

export default function MobileScreener() {
  const { accounts, user } = useAccount();
  const nav = useNavigate();
  const s = useScreener(accounts.length > 0);
  const decide = useScreenerDecide();
  const senders = useMemo(() => s.data?.senders ?? [], [s.data]);
  const [targets, setTargets] = useState<Record<string, Target>>({});
  const [leaving, setLeaving] = useState<Record<string, "yes" | "no">>({});
  const timers = useRef<number[]>([]);
  useEffect(() => () => timers.current.forEach(clearTimeout), []);
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
      }, 200),
    );
  };
  const waiting = senders.length;
  return (
    <Screen
      title="Screener"
      largeTitle
      subtitle={accounts.length ? (waiting ? `${waiting} ${waiting === 1 ? "sender" : "senders"} waiting. Swipe right to let in, left to screen out.` : "First-time senders wait here.") : undefined}
      right={
        <Button variant="ghost" size="icon-sm" aria-label="Screened out" className="text-muted-foreground" onClick={() => nav("/screened-out")}>
          <ShieldOff />
        </Button>
      }
    >
      {accounts.length === 0 ? (
        <MobileConnectCard />
      ) : (
        <>
          {s.error && <ErrorState error={s.error} onRetry={() => s.refetch()} />}
          {s.isLoading && (
            <div className="space-y-3 px-4" aria-busy>
              {[0, 1].map((i) => (
                <div key={i} className="rounded-xl bg-muted/50 p-4 space-y-3">
                  <div className="flex gap-3">
                    <Skeleton className="size-12 rounded-[4px]" />
                    <div className="flex-1 space-y-2 pt-1">
                      <Skeleton className="h-4 w-[45%]" />
                      <Skeleton className="h-3.5 w-[65%]" />
                    </div>
                  </div>
                  <Skeleton className="h-12" />
                  <Skeleton className="h-10" />
                </div>
              ))}
            </div>
          )}
          {!s.isLoading && waiting === 0 && !s.error && <MobileEmpty icon={<ShieldOff />} title="Nobody at the door." body="Every new sender has been dealt with." />}
          <div className="space-y-3">
            {senders.map((x) => (
              <Card key={x.contact.id} s={x} target={targetFor(x)} leaving={leaving[x.contact.id] ?? null} onTarget={(t) => setTargets((m) => ({ ...m, [x.contact.id]: t }))} onDecide={(d) => act(x, d)} />
            ))}
          </div>
        </>
      )}
    </Screen>
  );
}
