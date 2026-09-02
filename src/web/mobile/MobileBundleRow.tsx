import { useNavigate } from "react-router-dom";
import { Layers } from "lucide-react";
import type { Bundle } from "@shared/types";
import { cn } from "@/lib/utils";
import { useAccount } from "../context/AccountContext";
import { fmtTime } from "../lib/format";
import { BundleAvatar, AccountGlyph } from "../components/Avatar";
import { bundleHref } from "../components/BundleRow";

/** Mobile bundle row: one batch of mail from a bundled sender. */
export function MobileBundleRow({ bundle: b, dense }: { bundle: Bundle; dense?: boolean }) {
  const { multi, glyphFor, accountFor } = useAccount();
  const nav = useNavigate();
  const open = b.status === "open";
  const glyph = multi ? glyphFor(b.account_id) : "";
  const h = dense ? 64 : 80;
  return (
    <button type="button" onClick={() => nav(bundleHref(b))} className="w-full text-left flex items-center gap-3 px-4 bg-background active:bg-muted" style={{ height: h }}>
      <BundleAvatar email={b.email} name={b.name} src={b.avatar_url} size={dense ? 30 : 34} strong={open} />
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-1.5 min-w-0">
          {open && <span className="size-1.5 rounded-full bg-foreground shrink-0" />}
          <span className={cn("truncate text-[15px]", open ? "font-semibold text-foreground" : "font-medium text-foreground/90")}>{b.name || b.email}</span>
          <Layers size={13} className="text-muted-foreground shrink-0" />
          <span className="text-xs text-tertiary tnum shrink-0">{b.message_count} {b.message_count === 1 ? "message" : "messages"}</span>
          {glyph && <AccountGlyph glyph={glyph} label={accountFor(b.account_id)?.email} />}
          <span className="flex-1" />
          <span className={cn("text-[13px] tnum shrink-0", open ? "text-foreground" : "text-muted-foreground")}>{fmtTime(b.last_message_at)}</span>
        </div>
        <div className="flex items-center gap-1.5 min-w-0 mt-0.5">
          <span className={cn("truncate text-[14px] leading-5 shrink-0 max-w-[60%]", open ? "text-foreground" : "text-foreground/80")}>{b.latest.subject || "(no subject)"}</span>
          {b.latest.snippet && <span className="truncate text-[14px] leading-5 text-muted-foreground min-w-0">— {b.latest.snippet}</span>}
        </div>
      </div>
    </button>
  );
}
