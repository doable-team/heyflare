import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowRight, Bookmark, Check, ChevronDown, ChevronRight, Clock, Mail, Shield, Search, Zap } from "lucide-react";
import type { ThreadSummary } from "@shared/types";
import { useAccount } from "../context/AccountContext";
import { useBulkAction, useImbox } from "../api";
import { startGoogleConnect } from "../lib/connect";
import { Avatar } from "../components/Avatar";
import { SyncPill } from "../pages/Imbox";
import { fmtTime } from "../lib/format";
import { Button } from "@/components/ui/button";
import { Drawer, DrawerContent, DrawerDescription, DrawerHeader, DrawerTitle } from "@/components/ui/drawer";
import { Screen } from "./Screen";
import { MobileList, MobileEmpty } from "./MobileList";
import { ScopeSheet, useScopeLabel } from "./MobileShell";
import { TAB_BAR_H } from "./TabBar";

export function MobileConnectCard() {
  const { user } = useAccount();
  return (
    <MobileEmpty
      icon={<Mail />}
      title={`Connect your Gmail${user?.name ? `, ${user.name.split(" ")[0]}` : ""}`}
      body="Nobody reaches your Imbox until you say so. First-time senders wait in the Screener. Nothing from the past is imported — heyflare starts from the moment you connect."
      action={
        <Button size="lg" onClick={() => startGoogleConnect()}>
          Connect Gmail <ArrowRight />
        </Button>
      }
    />
  );
}

function PileChip({ threads, label, icon, link, linkLabel, onDone }: { threads: ThreadSummary[]; label: string; icon: React.ReactNode; link: string; linkLabel: string; onDone: (id: string) => void }) {
  const [open, setOpen] = useState(false);
  const nav = useNavigate();
  if (threads.length === 0) return null;
  const stack = threads.slice(0, 3);
  return (
    <>
      <button type="button" onClick={() => setOpen(true)} className="flex items-center gap-2 h-11 pl-2 pr-3 rounded-lg bg-background border border-border shadow-sm active:bg-muted" aria-label={`${label}, ${threads.length}`}>
        <span className="relative w-8 h-6 shrink-0 hidden min-[390px]:block">
          {stack.map((t, i) => {
            const depth = stack.length - 1 - i;
            return (
              <span key={t.id} className="absolute left-0 bottom-0 w-7 h-5 rounded-[3px] border border-border bg-background flex items-center justify-center" style={{ transform: `translate(${depth * 3}px, ${-depth * 3}px) rotate(${depth === 0 ? 0 : depth === 1 ? -4 : 3}deg)`, zIndex: 10 - depth, opacity: 1 - depth * 0.25 }}>
                {depth === 0 && <Avatar email={t.last_from.email} name={t.last_from.name} src={t.last_from.avatar_url} size={16} />}
              </span>
            );
          })}
        </span>
        <span className="text-[13px] font-medium text-foreground flex items-center gap-1 whitespace-nowrap">
          {icon} {label}
        </span>
        <span className="text-[13px] tnum text-muted-foreground">{threads.length}</span>
      </button>
      <Drawer open={open} onOpenChange={setOpen}>
        <DrawerContent className="pb-safe">
          <DrawerHeader className="pb-1 flex-row items-center justify-between text-left">
            <div>
              <DrawerTitle className="text-[15px]">{label}</DrawerTitle>
              <DrawerDescription className="sr-only">Threads in {label}</DrawerDescription>
            </div>
            <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={() => { setOpen(false); nav(link); }}>
              {linkLabel} <ArrowRight />
            </Button>
          </DrawerHeader>
          <div className="max-h-[60vh] overflow-y-auto pb-2">
            {threads.map((t) => (
              <div key={t.id} className="flex items-center gap-3 px-4 h-14">
                <Avatar email={t.last_from.email} name={t.last_from.name} src={t.last_from.avatar_url} size={32} />
                <button type="button" className="flex-1 min-w-0 text-left" onClick={() => { setOpen(false); nav(`/t/${t.id}`); }}>
                  <div className="text-[15px] truncate">{t.subject || "(no subject)"}</div>
                  <div className="text-[13px] text-muted-foreground truncate">{t.last_from.name || t.last_from.email} · {fmtTime(t.last_message_at)}</div>
                </button>
                <Button variant="ghost" size="sm" className="text-muted-foreground" onClick={() => onDone(t.id)}>
                  <Check /> Done
                </Button>
              </div>
            ))}
          </div>
        </DrawerContent>
      </Drawer>
    </>
  );
}

export function MobilePiles({ replyLater, setAside }: { replyLater: ThreadSummary[]; setAside: ThreadSummary[] }) {
  const bulk = useBulkAction();
  if (replyLater.length === 0 && setAside.length === 0) return null;
  return (
    <div className="fixed left-0 right-0 z-30 flex items-center gap-2 px-4 pointer-events-none" style={{ bottom: `calc(${TAB_BAR_H + 12}px + env(safe-area-inset-bottom))` }}>
      <div className="flex items-center gap-2 pointer-events-auto w-full [&>*]:flex-1 [&>*]:min-w-0">
        <PileChip threads={replyLater} label="Reply later" icon={<Clock size={13} />} link="/reply-later" linkLabel="Focus & Reply" onDone={(id) => bulk.mutate({ thread_ids: [id], action: "reply_later", on: false })} />
        <PileChip threads={setAside} label="Set aside" icon={<Bookmark size={13} />} link="/set-aside" linkLabel="Board" onDone={(id) => bulk.mutate({ thread_ids: [id], action: "set_aside", on: false })} />
      </div>
    </div>
  );
}

function senderLine(people: { name: string; email: string }[], total: number): string {
  const names = people.slice(0, 2).map((p) => p.name?.split(" ")[0] || p.email);
  const rest = total - names.length;
  if (names.length === 0) return "";
  if (rest <= 0) return names.join(" and ");
  return `${names.join(", ")} and ${rest} more`;
}

export default function MobileImbox() {
  const { accounts } = useAccount();
  const nav = useNavigate();
  const imbox = useImbox(accounts.length > 0);
  const [scopeOpen, setScopeOpen] = useState(false);
  const [selecting, setSelecting] = useState(false);
  const scopeLabel = useScopeLabel();
  const d = imbox.data;
  const piles = (d?.reply_later.length ?? 0) + (d?.set_aside.length ?? 0) > 0;
  const newCount = (d?.new_threads.length ?? 0) + (d?.bundles ?? []).filter((b) => b.status === "open").length;
  return (
    <Screen
      title={
        <span className="inline-flex items-center gap-1">
          Imbox {accounts.length > 0 && <ChevronDown size={18} className="text-muted-foreground" />}
        </span>
      }
      largeTitle
      subtitle={
        accounts.length > 0 ? (
          <span className="flex items-center gap-2 flex-wrap">
            <span>{scopeLabel}</span>
            <SyncPill />
          </span>
        ) : undefined
      }
      onTitleTap={accounts.length > 0 ? () => setScopeOpen(true) : undefined}
      titleRight={
        <button type="button" onClick={() => nav("/search")} aria-label="Search" className="size-11 rounded-full flex items-center justify-center text-foreground active:bg-muted">
          <Search size={22} />
        </button>
      }
      fab={accounts.length > 0 && !selecting}
      fabBottom={piles ? TAB_BAR_H + 76 : undefined}
      bottomInset={piles ? 64 : 0}
    >
      {accounts.length === 0 ? (
        <MobileConnectCard />
      ) : (
        <>
          {!!d?.screener_count && (
            <button type="button" onClick={() => nav("/screener")} className="mx-4 mb-3 flex items-center gap-3 rounded-lg bg-muted/50 active:bg-muted px-3 py-3 text-left">
              <div className="flex -space-x-2 shrink-0">
                {(d.screener_senders ?? []).slice(0, 4).map((p) => (
                  <span key={p.account_id + p.email} className="ring-2 ring-background rounded-[5px]">
                    <Avatar email={p.email} name={p.name} src={p.avatar_url} size={28} />
                  </span>
                ))}
              </div>
              <div className="flex-1 min-w-0">
                <div className="text-[15px] font-medium leading-5 flex items-center gap-1.5">
                  <Shield size={14} className="text-muted-foreground shrink-0" />
                  <span className="tnum">{d.screener_count}</span> waiting in the Screener
                </div>
                <div className="text-[13px] text-muted-foreground truncate">{senderLine(d.screener_senders ?? [], d.screener_count)}</div>
              </div>
              <ChevronRight size={18} className="text-tertiary shrink-0" />
            </button>
          )}
          {newCount > 0 && (
            <div className="px-4 mb-2">
              <Button variant="outline" className="w-full h-10 justify-center" onClick={() => nav("/power-through")}>
                <Zap /> Power through {newCount} new
              </Button>
            </div>
          )}
          <MobileList
            loading={imbox.isLoading}
            error={imbox.error}
            onRetry={() => imbox.refetch()}
            onRefresh={() => imbox.refetch()}
            onSelectionModeChange={setSelecting}
            sections={[
              {
                title: "New for you",
                threads: d?.new_threads ?? [],
                bundles: (d?.bundles ?? []).filter((b) => b.status === "open"),
                emptyNode: (
                  <div className="min-h-[16vh] px-4 pt-2">
                    <div className="text-[15px] text-foreground">Nothing new. Go enjoy your day.</div>
                    <div className="text-[13px] text-muted-foreground mt-1">Mail from people you've screened in shows up here.</div>
                  </div>
                ),
              },
              { title: "Previously seen", threads: d?.seen_threads ?? [], bundles: (d?.bundles ?? []).filter((b) => b.status === "seen"), emptyTitle: "Nothing here yet.", emptyBody: "Once you open something, it settles down here." },
            ]}
          />
          {!selecting && <MobilePiles replyLater={d?.reply_later ?? []} setAside={d?.set_aside ?? []} />}
        </>
      )}
      <ScopeSheet open={scopeOpen} onOpenChange={setScopeOpen} />
    </Screen>
  );
}

