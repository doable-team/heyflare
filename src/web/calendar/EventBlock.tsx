import { CheckCircle2, Circle, Lock, MapPin, Repeat, Users, Video } from "lucide-react";
import type { CalEvent } from "@shared/types";
import { cn } from "@/lib/utils";
import { fmtTime } from "../lib/caldate";

/** A calendar's colour is data, not chrome: it shows as a bar on the edge, never as a wash. */
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
        "w-full flex items-center gap-1.5 rounded-[4px] border-l-[3px] bg-secondary px-2 py-1 text-left",
        "text-[12.5px] font-medium leading-[16px] hover:bg-accent transition-colors",
        declined && "opacity-45 line-through",
        e.status === "tentative" && "border-dashed",
        focused && "ring-1 ring-ring",
      )}
      style={{ borderLeftColor: accent(e) }}
    >
      {e.emoji && <span className="shrink-0">{e.emoji}</span>}
      <span className="truncate">{e.title || "(no title)"}</span>
      {e.recurring && <Repeat size={10} className="ml-auto shrink-0 text-tertiary" />}
    </button>
  );
}

/**
 * One timed event, absolutely positioned inside a day column. `column`/`columns` come from
 * `layoutColumns` so overlapping events sit side by side instead of hiding each other.
 *
 * A block is a solid, readable card — not a hairline outline. At a glance you should be able to
 * read what the thing is from across the desk, which is the whole point of looking at a day.
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
  // Below ~44px there is only room for one line, so the time moves onto it.
  const oneLine = height < 44;
  const roomy = height >= 66;
  const width = `calc((100% - 6px) / ${columns})`;
  const left = `calc((100% - 6px) / ${columns} * ${column} + 3px)`;
  return (
    <div className="absolute z-10" style={{ top, height: Math.max(height, 22), width, left }}>
      <button
        type="button"
        onClick={onClick}
        title={`${e.title || "(no title)"}${e.location ? ` · ${e.location}` : ""}`}
        className={cn(
          "group/ev h-full w-full overflow-hidden rounded-[5px] border-l-[3px] bg-secondary px-2 py-1 text-left",
          "hover:bg-accent transition-colors",
          declined && "opacity-45",
          e.status === "tentative" && "border border-l-[3px] border-dashed bg-background",
          !e.busy && "bg-background border border-l-[3px] border-border",
          focused && "ring-1 ring-ring",
        )}
        style={{ borderLeftColor: accent(e) }}
      >
        <div className={cn("flex min-w-0 gap-1.5", oneLine ? "items-baseline" : "items-start")}>
          {e.kind === "todo" && (
            <span
              role="checkbox"
              aria-checked={e.done}
              tabIndex={-1}
              onClick={(ev) => {
                ev.stopPropagation();
                onToggleDone?.();
              }}
              className="mt-[3px] shrink-0 text-muted-foreground hover:text-foreground"
            >
              {e.done ? <CheckCircle2 size={12} /> : <Circle size={12} />}
            </span>
          )}
          {e.emoji && <span className="shrink-0 text-[13px] leading-[17px]">{e.emoji}</span>}
          <span
            className={cn(
              "min-w-0 text-[13px] font-medium leading-[17px]",
              oneLine ? "truncate" : "line-clamp-2",
              e.done && "line-through text-muted-foreground",
            )}
          >
            {e.title || "(no title)"}
          </span>
          {oneLine && <span className="ml-auto shrink-0 text-[11px] tnum text-muted-foreground">{fmtTime(e.starts_at, format)}</span>}
        </div>
        {!oneLine && (
          <div className="mt-0.5 flex items-center gap-1 text-[11.5px] leading-[15px] text-muted-foreground">
            <span className="shrink-0 tnum">{fmtTime(e.starts_at, format)}</span>
            {e.location && roomy && (
              <>
                <MapPin size={10} className="shrink-0 text-tertiary" />
                <span className="truncate">{e.location}</span>
              </>
            )}
            <span className="ml-auto flex shrink-0 items-center gap-0.5 text-tertiary">
              {e.conference_url && <Video size={10} />}
              {e.attendees.length > 0 && <Users size={10} />}
              {e.recurring && <Repeat size={10} />}
              {!e.writable && <Lock size={10} />}
            </span>
          </div>
        )}
      </button>
    </div>
  );
}
