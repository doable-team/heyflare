import { CheckCircle2, Circle, Lock, MapPin, Repeat, Users, Video } from "lucide-react";
import type { CalEvent } from "@shared/types";
import { cn } from "@/lib/utils";
import { fmtTime } from "../lib/caldate";

/** A calendar's colour is data, not chrome: it shows as a hairline, never as a wash of colour. */
function accent(e: CalEvent): string {
  return e.calendar_color && /^#[0-9a-fA-F]{6}$/.test(e.calendar_color) ? e.calendar_color : "currentColor";
}

export function AllDayChip({ e, onClick, focused }: { e: CalEvent; onClick?: () => void; focused?: boolean }) {
  const declined = e.rsvp === "declined";
  return (
    <button
      type="button"
      onClick={onClick}
      title={e.title || "(no title)"}
      className={cn(
        "w-full h-[19px] px-1.5 flex items-center gap-1 rounded-[3px] text-left text-[11px] leading-none",
        "border-l-2 bg-muted/70 hover:bg-muted transition-colors",
        declined && "opacity-45 line-through",
        e.status === "tentative" && "border-dashed",
        focused && "ring-1 ring-ring",
      )}
      style={{ borderLeftColor: accent(e) }}
    >
      {e.emoji && <span className="shrink-0">{e.emoji}</span>}
      <span className="truncate font-medium">{e.title || "(no title)"}</span>
      {e.recurring && <Repeat size={9} className="shrink-0 text-tertiary" />}
    </button>
  );
}

/**
 * One timed event, absolutely positioned inside a day column. `column`/`columns` come from
 * `layoutColumns` so overlapping events sit side by side instead of hiding each other.
 */
export function EventBlock({
  e,
  top,
  height,
  column,
  columns,
  format,
  onClick,
  onToggleDone,
  focused,
}: {
  e: CalEvent;
  top: number;
  height: number;
  column: number;
  columns: number;
  format: "12" | "24";
  onClick?: () => void;
  onToggleDone?: () => void;
  focused?: boolean;
}) {
  const declined = e.rsvp === "declined";
  const tight = height < 34;
  const width = `calc((100% - 4px) / ${columns})`;
  const left = `calc((100% - 4px) / ${columns} * ${column} + 2px)`;
  return (
    <div className="absolute z-10" style={{ top, height: Math.max(height, 16), width, left }}>
      <button
        type="button"
        onClick={onClick}
        title={`${e.title || "(no title)"}${e.location ? ` · ${e.location}` : ""}`}
        className={cn(
          "group/ev h-full w-full overflow-hidden rounded-[4px] border border-border border-l-2 bg-card px-1.5 py-0.5 text-left",
          "shadow-[0_1px_2px_rgba(0,0,0,0.04)] hover:bg-muted transition-colors",
          declined && "opacity-45",
          e.status === "tentative" && "border-dashed bg-background",
          !e.busy && "bg-background",
          focused && "ring-1 ring-ring",
        )}
        style={{ borderLeftColor: accent(e) }}
      >
        <div className={cn("flex items-start gap-1 min-w-0", tight && "items-center")}>
          {e.kind === "todo" && (
            <span
              role="checkbox"
              aria-checked={e.done}
              tabIndex={-1}
              onClick={(ev) => {
                ev.stopPropagation();
                onToggleDone?.();
              }}
              className="shrink-0 mt-[1px] text-muted-foreground hover:text-foreground"
            >
              {e.done ? <CheckCircle2 size={11} /> : <Circle size={11} />}
            </span>
          )}
          {e.emoji && <span className="shrink-0 text-[11px] leading-[15px]">{e.emoji}</span>}
          <span className={cn("min-w-0 truncate text-[11.5px] font-medium leading-[15px]", e.done && "line-through text-muted-foreground")}>
            {e.title || "(no title)"}
          </span>
          {tight && <span className="ml-auto shrink-0 text-[10px] text-tertiary tnum">{fmtTime(e.starts_at, format)}</span>}
        </div>
        {!tight && (
          <div className="mt-px flex items-center gap-1 text-[10px] leading-[13px] text-muted-foreground">
            <span className="tnum shrink-0">{fmtTime(e.starts_at, format)}</span>
            {e.location && height > 48 && (
              <>
                <MapPin size={9} className="shrink-0 text-tertiary" />
                <span className="truncate">{e.location}</span>
              </>
            )}
            <span className="ml-auto flex items-center gap-0.5 shrink-0 text-tertiary">
              {e.conference_url && <Video size={9} />}
              {e.attendees.length > 0 && <Users size={9} />}
              {e.recurring && <Repeat size={9} />}
              {!e.writable && <Lock size={9} />}
            </span>
          </div>
        )}
      </button>
    </div>
  );
}
