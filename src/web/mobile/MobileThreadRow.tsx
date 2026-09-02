import type { ReactNode } from "react";
import { Check, Paperclip, StickyNote } from "lucide-react";
import type { ThreadSummary } from "@shared/types";
import { cn } from "@/lib/utils";
import { fmtTime } from "../lib/format";
import { useAccount } from "../context/AccountContext";
import { Avatar, AvatarStack, AccountGlyph } from "../components/Avatar";
import { senderLine } from "../components/ThreadRow";
import { bucketName } from "../components/BulkBar";
import { useSwipe } from "./useSwipe";

export interface RowAction {
  label: string;
  icon: ReactNode;
  run: (t: ThreadSummary) => void;
}

/** 64px (56px dense) mobile row with swipe-to-act, tap-to-open and long-press-to-select. */
export function MobileThreadRow({
  thread: t,
  onOpen,
  selectionMode,
  selected,
  onToggleSelect,
  onLongPress,
  rightAction,
  leftAction,
  dense,
  showBucket,
  leaving,
}: {
  thread: ThreadSummary;
  onOpen: (t: ThreadSummary) => void;
  selectionMode?: boolean;
  selected?: boolean;
  onToggleSelect?: (id: string) => void;
  onLongPress?: (id: string) => void;
  rightAction?: RowAction;
  leftAction?: RowAction;
  dense?: boolean;
  showBucket?: boolean;
  leaving?: boolean;
}) {
  const { multi, glyphFor, accountFor } = useAccount();
  const others = t.participants.filter((p) => p.email.toLowerCase() !== (accountFor(t.account_id)?.email ?? "").toLowerCase());
  const swipe = useSwipe({
    disabled: selectionMode,
    onRight: rightAction ? () => rightAction.run(t) : undefined,
    onLeft: leftAction ? () => leftAction.run(t) : undefined,
    onLongPress: onLongPress ? () => onLongPress(t.id) : undefined,
  });
  const h = dense ? 64 : 80;
  const unread = t.unread;
  const glyph = multi ? glyphFor(t.account_id) : "";
  const click = () => {
    if (swipe.consumeClick()) return;
    if (selectionMode) onToggleSelect?.(t.id);
    else onOpen(t);
  };
  return (
    <div
      data-thread-id={t.id}
      className={cn("relative overflow-hidden select-none [-webkit-touch-callout:none] transition-[height,opacity] duration-200", leaving && "opacity-0")}
      style={{ height: leaving ? 0 : h }}
    >
      {/* reveal panels */}
      {rightAction && swipe.dx > 0 && (
        <div className="absolute inset-0 bg-muted text-foreground">
          <div className="absolute inset-y-0 left-0 flex items-center justify-end overflow-hidden pr-4" style={{ width: swipe.dx }}>
            <span className={cn("flex items-center gap-2 whitespace-nowrap text-[13px] font-medium transition-transform duration-100 [&>svg]:size-5", swipe.past && "scale-110")}>
              {rightAction.icon} {rightAction.label}
            </span>
          </div>
        </div>
      )}
      {leftAction && swipe.dx < 0 && (
        <div className="absolute inset-0 bg-muted text-foreground">
          <div className="absolute inset-y-0 right-0 flex items-center justify-start overflow-hidden pl-4" style={{ width: -swipe.dx }}>
            <span className={cn("flex items-center gap-2 whitespace-nowrap text-[13px] font-medium transition-transform duration-100 [&>svg]:size-5", swipe.past && "scale-110")}>
              {leftAction.label} {leftAction.icon}
            </span>
          </div>
        </div>
      )}

      <div
        {...swipe.handlers}
        onClick={click}
        role="button"
        tabIndex={0}
        onKeyDown={(e) => e.key === "Enter" && click()}
        className={cn("relative touch-pan-y flex items-center gap-3 px-4 bg-background active:bg-muted", selected && "bg-accent")}
        style={{ height: h, transform: `translateX(${swipe.dx}px)`, transition: swipe.dragging ? "none" : "transform 220ms cubic-bezier(.2,.8,.2,1)" }}
      >
        <div className="relative shrink-0">
          {selectionMode ? (
            <span className={cn("size-9 rounded-[6px] flex items-center justify-center border", selected ? "bg-foreground text-background border-foreground" : "border-border text-transparent")}>
              <Check size={18} strokeWidth={2.5} />
            </span>
          ) : (
            <Avatar email={t.last_from.email} name={t.last_from.name} src={t.last_from.avatar_url} size={dense ? 32 : 36} strong={unread} />
          )}
        </div>
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-1.5 min-w-0">
            {unread && <span className="size-1.5 rounded-full bg-foreground shrink-0" />}
            <span className={cn("truncate text-[15px]", unread ? "font-semibold text-foreground" : "font-medium text-foreground/90")}>{t.subject || "(no subject)"}</span>
            {others.length >= 2 && <AvatarStack people={[t.last_from, ...others.filter((p) => p.email.toLowerCase() !== t.last_from.email.toLowerCase())]} size={14} max={5} className="shrink-0" />}
            {t.message_count > 1 && <span className="text-xs text-tertiary tnum shrink-0">{t.message_count}</span>}
            {glyph && <AccountGlyph glyph={glyph} label={accountFor(t.account_id)?.email} />}
            <span className="flex-1" />
            <span className={cn("text-[13px] tnum shrink-0", unread ? "text-foreground" : "text-muted-foreground")}>{fmtTime(t.last_message_at)}</span>
          </div>
          <div className="flex items-center gap-1.5 min-w-0 mt-0.5">
            <span className={cn("truncate text-[14px] leading-5 shrink-0 max-w-[55%]", unread ? "text-foreground" : "text-foreground/80")}>{senderLine(t)}</span>
            {showBucket && t.bucket !== "imbox" && <span className="text-[11px] text-muted-foreground shrink-0">· {bucketName(t.bucket)}</span>}
            {t.snippet && <span className="truncate text-[14px] leading-5 text-muted-foreground min-w-0">— {t.snippet}</span>}
            <span className="flex-1" />
            {t.note && <StickyNote size={13} className="text-muted-foreground shrink-0" />}
            {t.has_attachments && <Paperclip size={13} className="text-muted-foreground shrink-0" />}
          </div>
        </div>
      </div>
    </div>
  );
}
