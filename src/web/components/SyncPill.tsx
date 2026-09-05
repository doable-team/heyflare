import { ArrowRight, Loader2, Mail, RefreshCw } from "lucide-react";
import { cn } from "@/lib/utils";
import { ALL, useAccount } from "../context/AccountContext";
import { useAccountMutations } from "../api";
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
