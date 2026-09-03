import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowUpCircle, Bookmark, Check, ChevronDown, Clock, FileText, MoreHorizontal, Reply, Rss, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { cn } from "@/lib/utils";
import { useBulkAction, usePowerThrough, usePowerThroughMutations } from "../api";
import { useAccount } from "../context/AccountContext";
import { HtmlBody } from "../components/HtmlBody";
import { Avatar, AccountGlyph } from "../components/Avatar";
import { ErrorState } from "../components/EmptyState";
import { DateTimePicker } from "../components/DatePicker";
import { type PowerItem } from "../pages/PowerThrough";
import { fmtTime } from "../lib/format";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { Drawer, DrawerContent, DrawerHeader, DrawerTitle } from "@/components/ui/drawer";
import { Screen } from "./Screen";
import { MobileConnectCard } from "./MobileImbox";
import { MobileEmpty } from "./MobileList";
import { usePullToRefresh } from "./usePullToRefresh";

const CAP = 340;
const OUT_MS = 160;

function MobilePowerCard({ t, onGone }: { t: PowerItem; onGone: (id: string, run: () => void) => void }) {
  const bulk = useBulkAction();
  const nav = useNavigate();
  const { multi, glyphFor, accountFor } = useAccount();
  const acct = accountFor(t.account_id);
  const m = t.latest_message;
  const [expanded, setExpanded] = useState(false);
  const [overflows, setOverflows] = useState(false);
  const bodyRef = useRef<HTMLDivElement>(null);
  const [bubble, setBubble] = useState(false);
  useEffect(() => {
    const el = bodyRef.current;
    if (!el) return;
    const check = () => setOverflows(el.scrollHeight > CAP + 24);
    check();
    const ro = new ResizeObserver(check);
    ro.observe(el);
    const t1 = window.setTimeout(check, 600);
    return () => {
      ro.disconnect();
      window.clearTimeout(t1);
    };
  }, [m?.id]);
  const [more, setMore] = useState(false);

  const leave = (body: Parameters<typeof bulk.mutate>[0], msg: string) => onGone(t.id, () => bulk.mutate(body, { onSuccess: () => toast(msg) }));

  return (
    <article className="border-b border-border pb-3 mb-3">
      <header className="flex items-center gap-2 px-4 pt-3">
        <Avatar email={t.last_from.email} name={t.last_from.name} src={t.last_from.avatar_url} size={24} />
        <span className="text-[14px] font-medium truncate">{t.last_from.name || t.last_from.email}</span>
        {multi && acct && <AccountGlyph glyph={glyphFor(acct.id)} label={acct.email} />}
        <span className="flex-1" />
        <time className="text-[12px] text-muted-foreground tnum shrink-0">{fmtTime(t.last_message_at)}</time>
      </header>

      <button type="button" onClick={() => nav(`/t/${t.id}`)} className="block w-full text-left px-4 pt-2">
        <span className="text-[17px] font-semibold leading-snug">{t.subject || "(no subject)"}</span>
      </button>

      <div className="relative px-4 pt-2">
        <div ref={bodyRef} className={cn(!expanded && "overflow-hidden")} style={!expanded ? { maxHeight: CAP } : undefined}>
          {m ? <HtmlBody html={m.html_body} text={m.text_body} trackers={m.trackers} /> : <p className="text-[15px]">{t.snippet}</p>}
        </div>
        {!expanded && overflows && (
          <div className="absolute inset-x-0 bottom-0 h-16 flex items-end justify-center bg-gradient-to-t from-background via-background/70 to-transparent pointer-events-none">
            <Button variant="outline" size="sm" className="pointer-events-auto" onClick={() => setExpanded(true)}>
              Read more <ChevronDown />
            </Button>
          </div>
        )}
      </div>

      <div className="flex items-center gap-1 px-2 pt-3">
        <Button size="sm" className="h-10" onClick={() => nav(`/t/${t.id}?reply=1`)}>
          <Reply /> Reply
        </Button>
        <Button variant="ghost" size="icon" className="size-10 text-muted-foreground" aria-label="Reply later" onClick={() => leave({ thread_ids: [t.id], action: "reply_later", on: true }, "Added to Reply Later")}>
          <Clock />
        </Button>
        <Button variant="ghost" size="icon" className="size-10 text-muted-foreground" aria-label="Set aside" onClick={() => leave({ thread_ids: [t.id], action: "set_aside", on: true }, "Set aside")}>
          <Bookmark />
        </Button>
        <Button variant="ghost" size="icon" className="size-10 text-muted-foreground" aria-label="Bubble up" onClick={() => setBubble(true)}>
          <ArrowUpCircle />
        </Button>
        <span className="flex-1" />
        <Button variant="ghost" size="icon" className="size-10 text-muted-foreground" aria-label="Mark seen" onClick={() => leave({ thread_ids: [t.id], action: "seen" }, "Marked seen")}>
          <Check />
        </Button>
        <Button variant="ghost" size="icon" className="size-10 text-muted-foreground" aria-label="More" onClick={() => setMore(true)}>
          <MoreHorizontal />
        </Button>
      </div>

      <Drawer open={bubble} onOpenChange={setBubble}>
        <DrawerContent>
          <DrawerHeader>
            <DrawerTitle>Bubble up</DrawerTitle>
          </DrawerHeader>
          <div className="px-2 pb-4">
            <DateTimePicker
              embedded
              onPick={(at) => {
                setBubble(false);
                leave({ thread_ids: [t.id], action: "bubble_up", at }, "Will bubble up");
              }}
              onCancel={() => setBubble(false)}
            />
          </div>
        </DrawerContent>
      </Drawer>

      <Drawer open={more} onOpenChange={setMore}>
        <DrawerContent>
          <DrawerHeader>
            <DrawerTitle className="truncate">{t.subject || "(no subject)"}</DrawerTitle>
          </DrawerHeader>
          <div className="pb-4">
            {[
              { icon: <Rss />, label: "Move to The Feed", run: () => leave({ thread_ids: [t.id], action: "move", bucket: "feed" }, "Moved to The Feed") },
              { icon: <FileText />, label: "Move to Paper Trail", run: () => leave({ thread_ids: [t.id], action: "move", bucket: "paper_trail" }, "Moved to Paper Trail") },
              { icon: <Trash2 />, label: "Trash", run: () => leave({ thread_ids: [t.id], action: "move", bucket: "trash" }, "Moved to trash") },
            ].map((r) => (
              <button
                key={r.label}
                type="button"
                className="w-full flex items-center gap-3 px-5 h-12 text-[15px] active:bg-muted"
                onClick={() => {
                  setMore(false);
                  r.run();
                }}
              >
                <span className="text-muted-foreground [&>svg]:size-[18px]">{r.icon}</span>
                {r.label}
              </button>
            ))}
          </div>
        </DrawerContent>
      </Drawer>
    </article>
  );
}

/** The "New for you" queue stacked on one screen, one tap per decision. */
export default function MobilePowerThrough() {
  const { accounts } = useAccount();
  const nav = useNavigate();
  const q = usePowerThrough(accounts.length > 0);
  const { markAllSeen } = usePowerThroughMutations();
  const [gone, setGone] = useState<Set<string>>(new Set());
  const [leaving, setLeaving] = useState<Set<string>>(new Set());
  const ptr = usePullToRefresh(() => q.refetch(), accounts.length > 0);

  const items = useMemo(() => (q.data?.items ?? []).filter((t) => !gone.has(t.id)), [q.data, gone]);

  const onGone = useCallback((id: string, run: () => void) => {
    setLeaving((l) => new Set([...l, id]));
    window.setTimeout(() => {
      run();
      setGone((g) => new Set([...g, id]));
      setLeaving((l) => {
        const n = new Set(l);
        n.delete(id);
        return n;
      });
    }, OUT_MS);
  }, []);

  return (
    <Screen title="Power through" back="/" backLabel="Imbox" subtitle={items.length ? `${items.length} to go` : undefined}>
      {accounts.length === 0 ? (
        <MobileConnectCard />
      ) : (
        <div {...ptr.handlers}>
          {ptr.indicator}
          {q.error && <ErrorState error={q.error} onRetry={() => q.refetch()} />}
          {q.isLoading && (
            <div className="px-4 space-y-4" aria-busy>
              <Skeleton className="h-6 w-[70%]" />
              <Skeleton className="h-40" />
              <Skeleton className="h-40" />
            </div>
          )}
          {!q.isLoading && items.length === 0 && <MobileEmpty icon={<Check />} title="Nothing new. Go enjoy your day." body="Anything you skipped is still in the Imbox." />}
          {items.map((t) => (
            <div key={t.id} className={cn("transition-opacity duration-150", leaving.has(t.id) && "opacity-0")}>
              <MobilePowerCard t={t} onGone={onGone} />
            </div>
          ))}
          {items.length > 0 && (
            <div className="px-4 py-6 flex flex-col gap-2">
              <Button
                variant="outline"
                className="h-11"
                disabled={markAllSeen.isPending}
                onClick={() =>
                  markAllSeen.mutate(
                    items.map((t) => t.id),
                    {
                      onSuccess: (r) => {
                        toast(`Marked ${r.count} as seen`);
                        nav("/");
                      },
                    },
                  )
                }
              >
                <Check /> Mark all as seen
              </Button>
              <Button variant="ghost" className="h-11" onClick={() => nav("/")}>
                Leave the rest
              </Button>
            </div>
          )}
        </div>
      )}
    </Screen>
  );
}
