import { Link } from "react-router-dom";
import { ArrowUpCircle, Bookmark, Clock, Paperclip, ShieldCheck, StickyNote, Trash2 } from "lucide-react";
import type { ThreadSummary } from "@shared/types";
import { cn } from "@/lib/utils";
import { fmtTime, fmtFull } from "../lib/format";
import { useAccount } from "../context/AccountContext";
import { Avatar, AvatarStack, AccountGlyph } from "./Avatar";
import { bucketName } from "./BulkBar";
import { Checkbox } from "@/components/ui/checkbox";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { Kbd } from "@/components/ui/kbd";

export type QuickAction = "reply_later" | "set_aside" | "bubble_up" | "trash";

export function senderLine(t: ThreadSummary): string {
  const others = t.participants.filter((p) => p.email !== t.last_from.email);
  const first = t.last_from.name?.trim() || t.last_from.email;
  if (others.length === 0) return first;
  const names = [first, ...others.map((p) => p.name?.trim().split(" ")[0] || p.email.split("@")[0])];
  return names.slice(0, 3).join(", ") + (names.length > 3 ? ` +${names.length - 3}` : "");
}

function Quick({ label, kbd, icon, onClick, active }: { label: string; kbd: string; icon: React.ReactNode; onClick: () => void; active?: boolean }) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button variant="ghost" size="icon-xs" aria-label={label} onClick={(e) => { e.preventDefault(); e.stopPropagation(); onClick(); }} className={cn("text-muted-foreground hover:text-foreground", active && "bg-accent text-foreground")}>
          {icon}
        </Button>
      </TooltipTrigger>
      <TooltipContent>
        {label} <Kbd className="ml-1">{kbd}</Kbd>
      </TooltipContent>
    </Tooltip>
  );
}

/** Notion-dense thread row: 44px two-line (default) or 40px one-line (compact). */
export function ThreadRow({
  thread: t,
  selected,
  focused,
  onSelect,
  compact,
  showBucket,
  leaving,
  onQuickAction,
  quickActions = true,
}: {
  thread: ThreadSummary;
  selected: boolean;
  focused?: boolean;
  onSelect: (id: string, shift: boolean) => void;
  compact?: boolean;
  showBucket?: boolean;
  leaving?: boolean;
  onQuickAction?: (id: string, action: QuickAction) => void;
  quickActions?: boolean;
}) {
  const { multi, glyphFor, accountFor } = useAccount();
  const unread = t.unread;
  const showQuick = quickActions && !!onQuickAction;
  const glyph = multi ? glyphFor(t.account_id) : "";
  const me = (accountFor(t.account_id)?.email ?? "").toLowerCase();
  const others = t.participants.filter((p) => p.email.toLowerCase() !== me);
  // Everyone else on the thread (HEY-style small stack next to the subject).
  const stack = others.length >= 2 ? [t.last_from, ...others.filter((p) => p.email.toLowerCase() !== t.last_from.email.toLowerCase())] : null;
  return (
    <div
      data-thread-id={t.id}
      className={cn(
        "group relative grid items-center gap-2.5 rounded-md px-2 transition-colors duration-100",
        compact ? "grid-cols-[20px_1fr_auto] h-11" : "grid-cols-[20px_1fr_auto] h-14",
        selected ? "bg-accent" : focused ? "bg-muted" : "hover:bg-muted",
        leaving && "row-out",
      )}
    >
      {focused && <span className="absolute left-0 top-2 bottom-2 w-0.5 rounded-full bg-foreground" />}

      {/* avatar ↔ checkbox */}
      <div className="relative size-5">
        {!compact && (
          <div className={cn("transition-opacity duration-100", (selected || showQuick) && "group-hover:opacity-0", selected && "opacity-0")}>
            <Avatar email={t.last_from.email} name={t.last_from.name} src={t.last_from.avatar_url} size={20} />
          </div>
        )}
        <div className={cn("absolute inset-0 flex items-center justify-center transition-opacity duration-100", selected ? "opacity-100" : "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100")}>
          <Checkbox checked={selected} onClick={(e) => onSelect(t.id, (e as React.MouseEvent).shiftKey)} aria-label="Select" className="size-4 rounded-[3px]" />
        </div>
      </div>

      <Link to={`/t/${t.id}`} className="min-w-0 block outline-none">
        {compact ? (
          <div className="flex items-center gap-1.5 min-w-0 leading-tight">
            {unread && <span className="size-1.5 rounded-full bg-foreground shrink-0" aria-label="Unread" />}
            <span className={cn("truncate text-[13px] shrink-0 max-w-[38%]", unread ? "font-semibold text-foreground" : "font-medium text-foreground/90")}>{senderLine(t)}</span>
            {t.message_count > 1 && <span className="text-xs text-tertiary tnum shrink-0">{t.message_count}</span>}
            {glyph && <AccountGlyph glyph={glyph} label={accountFor(t.account_id)?.email} />}
            {t.bubbled && <Badge variant="outline" className="h-4 px-1 text-[10px] font-normal text-muted-foreground">Bubbled up</Badge>}
            {showBucket && t.bucket !== "imbox" && <Badge variant="outline" className="h-4 px-1 text-[10px] font-normal text-muted-foreground">{bucketName(t.bucket)}</Badge>}
            <span className={cn("truncate text-[13px] min-w-0", unread ? "text-foreground" : "text-foreground/80")}>
              {t.subject || "(no subject)"}
              {t.snippet && <span className="text-muted-foreground"> — {t.snippet}</span>}
            </span>
          </div>
        ) : (
          <>
            {/* line 1: subject (+ participants) */}
            <div className="flex items-center gap-1.5 min-w-0 leading-tight">
              {unread && <span className="size-1.5 rounded-full bg-foreground shrink-0" aria-label="Unread" />}
              <span className={cn("truncate text-[13px]", unread ? "font-semibold text-foreground" : "font-medium text-foreground/90")}>{t.subject || "(no subject)"}</span>
              {stack && <AvatarStack people={stack} size={14} max={6} className="shrink-0" />}
              {t.message_count > 1 && <span className="text-xs text-tertiary tnum shrink-0">{t.message_count}</span>}
              {glyph && <AccountGlyph glyph={glyph} label={accountFor(t.account_id)?.email} />}
              {t.bubbled && <Badge variant="outline" className="h-4 px-1 text-[10px] font-normal text-muted-foreground">Bubbled up</Badge>}
              {showBucket && t.bucket !== "imbox" && <Badge variant="outline" className="h-4 px-1 text-[10px] font-normal text-muted-foreground">{bucketName(t.bucket)}</Badge>}
            </div>
            {/* line 2: who — snippet */}
            <div className="flex items-center gap-1.5 min-w-0 leading-tight mt-0.5">
              <span className={cn("truncate text-[13px] shrink-0 max-w-full sm:max-w-[45%]", unread ? "text-foreground" : "text-foreground/80")}>{senderLine(t)}</span>
              {t.snippet && <span className="hidden sm:inline truncate text-xs text-muted-foreground min-w-0">— {t.snippet}</span>}
            </div>
          </>
        )}
      </Link>

      {/* meta / quick actions */}
      <div className={cn("relative flex items-center justify-end gap-2 text-muted-foreground shrink-0 min-w-[56px]", showQuick && "group-hover:min-w-[116px] group-focus-within:min-w-[116px]")}>
        <div className={cn("flex items-center gap-2 transition-opacity duration-100", showQuick && "group-hover:opacity-0 group-focus-within:opacity-0")}>
          {!compact && t.labels.slice(0, 2).map((l) => (
            <Badge key={l.id} variant="outline" className="hidden sm:inline-flex h-4 px-1.5 text-[10px] font-normal text-muted-foreground">{l.name}</Badge>
          ))}
          {t.note && (
            <Tooltip>
              <TooltipTrigger asChild><span className="flex"><StickyNote size={13} /></span></TooltipTrigger>
              <TooltipContent>Has a note</TooltipContent>
            </Tooltip>
          )}
          {t.trackers_blocked > 0 && (
            <Tooltip>
              <TooltipTrigger asChild><span className="flex"><ShieldCheck size={13} /></span></TooltipTrigger>
              <TooltipContent>Blocked {t.trackers_blocked} spy tracker{t.trackers_blocked === 1 ? "" : "s"}</TooltipContent>
            </Tooltip>
          )}
          {t.has_attachments && <Paperclip size={13} />}
          <Tooltip>
            <TooltipTrigger asChild>
              <span className={cn("text-xs tnum whitespace-nowrap", unread ? "text-foreground" : "")}>{fmtTime(t.last_message_at)}</span>
            </TooltipTrigger>
            <TooltipContent>{fmtFull(t.last_message_at)}</TooltipContent>
          </Tooltip>
        </div>
        {showQuick && (
          <div className="absolute right-0 inset-y-0 flex items-center gap-0.5 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity duration-100 pointer-events-none group-hover:pointer-events-auto group-focus-within:pointer-events-auto">
            {t.bucket !== "trash" && (
              <>
                <Quick label="Reply later" kbd="l" icon={<Clock />} active={t.reply_later} onClick={() => onQuickAction!(t.id, "reply_later")} />
                <Quick label="Set aside" kbd="a" icon={<Bookmark />} active={t.set_aside} onClick={() => onQuickAction!(t.id, "set_aside")} />
                <Quick label="Bubble up" kbd="z" icon={<ArrowUpCircle />} onClick={() => onQuickAction!(t.id, "bubble_up")} />
              </>
            )}
            <Quick label="Trash" kbd="#" icon={<Trash2 />} onClick={() => onQuickAction!(t.id, "trash")} />
          </div>
        )}
      </div>
    </div>
  );
}
