import { Link, useNavigate } from "react-router-dom";
import { Check, Layers } from "lucide-react";
import type { Bundle } from "@shared/types";
import { cn } from "@/lib/utils";
import { useAccount } from "../context/AccountContext";
import { fmtTime } from "../lib/format";
import { BundleAvatar, AccountGlyph } from "./Avatar";
import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";

export function bundleHref(b: Bundle): string {
  return `/bundle/${b.id}`;
}

/** One batch of mail from a bundled sender (same row grammar as ThreadRow). */
export function BundleRow({ bundle: b, compact, onSeen, leaving }: { bundle: Bundle; compact?: boolean; onSeen?: (b: Bundle) => void; leaving?: boolean }) {
  const { multi, glyphFor, accountFor } = useAccount();
  const nav = useNavigate();
  const open = b.status === "open";
  const glyph = multi ? glyphFor(b.account_id) : "";
  const countText = `${b.message_count} ${b.message_count === 1 ? "message" : "messages"}`;
  return (
    <div
      className={cn(
        "group relative grid items-center gap-2.5 rounded-md px-2 transition-colors duration-100 hover:bg-muted",
        compact ? "grid-cols-[24px_1fr_auto] h-11" : "grid-cols-[24px_1fr_auto] h-14",
        leaving && "row-out",
      )}
    >
      <BundleAvatar email={b.email} name={b.name} src={b.avatar_url} size={20} />
      <Link to={bundleHref(b)} className="min-w-0 block outline-none">
        <div className="flex items-center gap-1.5 min-w-0 leading-tight">
          {open && <span className="size-1.5 rounded-full bg-foreground shrink-0" aria-label="New" />}
          <span className={cn("truncate text-[13px]", open ? "font-semibold text-foreground" : "font-medium text-foreground/90")}>{b.name || b.email}</span>
          <Layers size={12} className="text-muted-foreground shrink-0" aria-label="Bundle" />
          <span className="text-xs text-tertiary tnum shrink-0">{countText}</span>
          {glyph && <AccountGlyph glyph={glyph} label={accountFor(b.account_id)?.email} />}
          {compact && (
            <span className="truncate text-[13px] min-w-0 text-foreground/80">
              {b.latest.subject || "(no subject)"}
              {b.latest.snippet && <span className="text-muted-foreground"> — {b.latest.snippet}</span>}
            </span>
          )}
        </div>
        {!compact && (
          <div className="flex items-center gap-1.5 min-w-0 leading-tight mt-0.5">
            <span className={cn("truncate text-[13px] shrink-0 max-w-full sm:max-w-[60%]", open ? "text-foreground" : "text-foreground/80")}>{b.latest.subject || "(no subject)"}</span>
            {b.latest.snippet && <span className="hidden sm:inline truncate text-xs text-muted-foreground min-w-0">— {b.latest.snippet}</span>}
          </div>
        )}
      </Link>
      <div className="relative flex items-center justify-end gap-2 text-muted-foreground shrink-0 min-w-[56px] group-hover:min-w-[116px]">
        <span className={cn("text-xs tnum transition-opacity duration-100 group-hover:opacity-0", open && "text-foreground")}>{fmtTime(b.last_message_at)}</span>
        <div className="absolute right-0 inset-y-0 flex items-center gap-1 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity duration-100 pointer-events-none group-hover:pointer-events-auto group-focus-within:pointer-events-auto">
          {open && onSeen && (
            <Tooltip>
              <TooltipTrigger asChild>
                <Button variant="ghost" size="icon-xs" aria-label="Mark as seen" onClick={() => onSeen(b)}>
                  <Check />
                </Button>
              </TooltipTrigger>
              <TooltipContent side="top">Mark as seen</TooltipContent>
            </Tooltip>
          )}
          <Button variant="ghost" size="xs" className="text-muted-foreground" onClick={() => nav(`/contacts/${b.contact_id}`)}>
            Contact
          </Button>
        </div>
      </div>
    </div>
  );
}
