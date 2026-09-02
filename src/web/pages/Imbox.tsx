import { Link } from "react-router-dom";
import { ArrowRight, ChevronRight, Loader2, Mail, RefreshCw, Shield } from "lucide-react";
import { cn } from "@/lib/utils";
import { ALL, useAccount } from "../context/AccountContext";
import { useAccountMutations, useImbox } from "../api";
import { ThreadList } from "../components/ThreadList";
import { Piles } from "../components/Trays";
import { Avatar } from "../components/Avatar";
import { fmtRelative } from "../lib/format";
import { Button } from "@/components/ui/button";
import { Empty, EmptyContent, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty";

export function ConnectGmailCard() {
  const { user } = useAccount();
  return (
    <div className="max-w-2xl mx-auto pt-10">
      <Empty className="border-0 py-10">
        <EmptyHeader>
          <EmptyMedia variant="icon" className="bg-muted text-muted-foreground"><Mail /></EmptyMedia>
          <EmptyTitle className="text-lg font-semibold">Connect your Gmail{user?.name ? `, ${user.name.split(" ")[0]}` : ""}</EmptyTitle>
          <EmptyDescription className="max-w-md">
            Nobody reaches your Imbox until you say so. First-time senders wait in the Screener; newsletters go to The Feed; receipts to the Paper Trail. Nothing from the past is imported — heyflare starts from the moment you connect and checks Gmail every couple of minutes.
          </EmptyDescription>
        </EmptyHeader>
        <EmptyContent>
          <Button asChild>
            <a href="/auth/google/start">Connect Gmail <ArrowRight /></a>
          </Button>
          <div className="text-xs text-muted-foreground mt-1">Tokens stay in your own Cloudflare account.</div>
        </EmptyContent>
      </Empty>
    </div>
  );
}

export function SyncPill({ className }: { className?: string }) {
  const { account, accounts, scope } = useAccount();
  const { sync } = useAccountMutations();
  const targets = scope === ALL ? accounts : account ? [account] : [];
  const busy = targets.filter((a) => !a.initial_sync_done || a.sync_status === "syncing");
  const broken = targets.filter((a) => a.sync_status === "error" || a.sync_status === "disconnected");
  if (busy.length === 0 && broken.length === 0) return null;
  const a = broken[0] ?? busy[0];
  const error = broken.length > 0;
  return (
    <div className={cn("inline-flex items-center gap-2 text-xs text-muted-foreground", className)}>
      {error ? <RefreshCw size={13} /> : <Loader2 size={13} className="animate-spin" />}
      {error ? (
        <span>
          Sync problem{targets.length > 1 ? ` (${a.email})` : ""}: {a.sync_error || "unknown"}.{" "}
          {a.sync_status === "disconnected" && <a href="/auth/google/start" className="underline underline-offset-2 hover:text-foreground">Reconnect</a>}
        </span>
      ) : (
        <span>
          Syncing{targets.length > 1 ? ` ${a.email}` : ""} <span className="tnum">· {a.initial_sync_count} messages</span>
          {a.last_synced_at ? <span> · {fmtRelative(a.last_synced_at)}</span> : null}
        </span>
      )}
      <Button size="xs" variant="ghost" onClick={() => sync.mutate(a.id)} disabled={sync.isPending} className="text-muted-foreground">
        Sync now
      </Button>
    </div>
  );
}

function senderLine(people: { name: string; email: string }[], total: number): string {
  const names = people.slice(0, 3).map((p) => p.name || p.email);
  const rest = total - names.length;
  if (names.length === 0) return "";
  if (rest <= 0) return names.length === 1 ? names[0] : `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
  return `${names.join(", ")} and ${rest} more`;
}

export default function Imbox() {
  const { accounts, account, scope } = useAccount();
  const imbox = useImbox(accounts.length > 0);
  if (accounts.length === 0) return <ConnectGmailCard />;
  const d = imbox.data;
  const scopeLabel = accounts.length > 1 ? (scope === ALL ? "All accounts" : account?.email) : account?.email ?? accounts[0]?.email;
  return (
    <div className="max-w-3xl mx-auto flex flex-col min-h-[calc(100vh-44px-48px)]">
      <header className="mb-4 px-2">
        <h1 className="text-[28px] leading-[34px] font-bold tracking-[-0.02em]">Imbox</h1>
        <div className="flex items-center gap-3 mt-1 min-h-5">
          {scopeLabel && <span className="text-xs text-muted-foreground">{scopeLabel}</span>}
          <SyncPill />
        </div>
      </header>

      {!!d?.screener_count && (
        <Link to="/screener" className="group flex items-center gap-3 rounded-md bg-muted/40 hover:bg-muted px-3 py-2.5 mb-5 transition-colors">
          <div className="flex -space-x-1.5 shrink-0">
            {(d.screener_senders ?? []).slice(0, 5).map((p) => (
              <span key={p.account_id + p.email} className="ring-2 ring-background rounded-[4px]">
                <Avatar email={p.email} name={p.name} src={p.avatar_url} size={24} />
              </span>
            ))}
          </div>
          <div className="min-w-0 flex-1">
            <div className="text-[13px] font-medium">
              <Shield size={13} className="inline -mt-0.5 mr-1 text-muted-foreground" />
              <span className="tnum">{d.screener_count}</span> new {d.screener_count === 1 ? "sender is" : "senders are"} waiting in the Screener
            </div>
            <div className="text-xs text-muted-foreground truncate">{senderLine(d.screener_senders ?? [], d.screener_count)}</div>
          </div>
          <span className="inline-flex items-center gap-1 text-[13px] text-muted-foreground group-hover:text-foreground shrink-0">
            <span className="hidden sm:inline">Screen them</span> <ChevronRight size={14} />
          </span>
        </Link>
      )}

      <ThreadList
        loading={imbox.isLoading}
        error={imbox.error}
        onRetry={() => imbox.refetch()}
        sections={[
          {
            title: "New for you",
            threads: d?.new_threads ?? [],
            bundles: (d?.bundles ?? []).filter((b) => b.status === "open"),
            emptyNode: (
              <div className="min-h-[20vh] px-2 pt-2">
                <div className="text-[14px] text-foreground">Nothing new. Go enjoy your day.</div>
                <div className="text-[13px] text-muted-foreground mt-1">Mail from people you've screened in shows up here.</div>
              </div>
            ),
          },
          { title: "Previously seen", threads: d?.seen_threads ?? [], bundles: (d?.bundles ?? []).filter((b) => b.status === "seen"), emptyTitle: "Nothing here yet.", emptyBody: "Once you open something, it settles down here." },
        ]}
      />
      <Piles replyLater={d?.reply_later ?? []} setAside={d?.set_aside ?? []} />
    </div>
  );
}
