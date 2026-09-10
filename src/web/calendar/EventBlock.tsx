import { Repeat } from "lucide-react";
import type { CalEvent } from "@shared/types";
import { cn } from "@/lib/utils";
import { eventBar, eventFill, eventInk, useDark } from "./colors";
import { handlePx, type DragMode } from "./dragEvent";
import { shortRange, shortTime } from "../lib/caldate";

/**
 * The three shapes an event takes, Apple Calendar style: a timed block in the day columns, an
 * all-day pill in the banner row (and the month grid), and a one-line row in a month cell.
 *
 * Every one of them is a wash of the calendar's colour with the title in the colour itself; the
 * chrome around them stays monochrome.
 */

/** True when the event is only provisionally on the calendar — the organiser's or the user's doubt. */
function isTentative(e: CalEvent): boolean {
  return e.status === "tentative" || e.rsvp === "tentative";
}

/** Under this a block has room for its title only. */
const TIME_LINE_PX = 34;
/** Under this width the repeat icon has nowhere to sit. */
const ICON_WIDTH_PX = 90;

/**
 * One timed event, absolutely positioned inside a day column. `column`/`columns` come from
 * `layoutColumns` so overlapping events sit side by side; `top`/`height` from `placeBlocks`.
 */
export function TimedBlock({
  e,
  top,
  height,
  column,
  columns,
  widthPx,
  format,
  onClick,
  onDragStart,
  dragging,
  z,
}: {
  e: CalEvent;
  top: number;
  height: number;
  column: number;
  columns: number;
  /** The block's rendered width, for deciding whether the repeat icon fits. */
  widthPx: number;
  format: "12" | "24";
  onClick?: () => void;
  /** Press to move, or press within the top/bottom 6px to take that end with you. */
  onDragStart?: (ev: React.PointerEvent, mode: DragMode) => void;
  /** Under the pointer, or dropped and waiting for the server. */
  dragging?: boolean;
  /** Stacking order: later-starting events go on top. */
  z?: number;
}) {
  const dark = useDark();
  const h = Math.max(height, 16);
  const declined = e.rsvp === "declined";
  const tentative = isTentative(e);
  const struck = declined || e.done;
  const ink = eventInk(e.calendar_color, dark);
  const bar = eventBar(e.calendar_color);

  // Two pixels of air either side of the column, and a hairline between neighbours.
  const width = `calc((100% - 4px) / ${columns} - ${columns > 1 ? 1 : 0}px)`;
  const left = `calc((100% - 4px) / ${columns} * ${column} + 2px)`;
  const title = e.title || "(no title)";
  const draggable = !!onDragStart && e.writable !== false;
  const grab = handlePx(h);

  return (
    <div className="absolute" style={{ top, height: Math.max(h - 2, 14), width, left, zIndex: dragging ? 90 : (z ?? 20) }} data-event={e.id}>
      <button
        type="button"
        onClick={onClick}
        onPointerDown={draggable ? (ev) => onDragStart!(ev, "move") : undefined}
        title={`${title} · ${shortRange(e.starts_at, e.ends_at, format)}`}
        style={{
          ["--fill" as string]: eventFill(e.calendar_color, tentative ? 0.22 * 0.6 : 0.22),
          ["--fill-hover" as string]: eventFill(e.calendar_color, 0.3),
          color: ink,
          borderColor: tentative ? bar : undefined,
        }}
        className={cn(
          "relative flex h-full w-full flex-col overflow-hidden rounded-[5px] bg-(--fill) px-1.5 text-left hover:bg-(--fill-hover)",
          // Room for the time line: pad it. Title only: centre the one line, so a quarter hour keeps its name.
          h >= TIME_LINE_PX ? "py-[3px]" : "justify-center py-0",
          tentative && "border border-dashed",
          declined && "opacity-45",
          dragging && "cursor-grabbing shadow-lg",
        )}
      >
        <span className="pointer-events-none absolute inset-y-0 left-0 w-[3px] rounded-l-[5px]" style={{ background: bar }} />
        <span className={cn("block truncate text-[12px] font-semibold leading-[14px]", struck && "line-through")}>
          {e.emoji ? `${e.emoji} ` : ""}
          {title}
        </span>
        {h >= TIME_LINE_PX && <span className="block truncate text-[11px] leading-[13px] opacity-80 tnum">{shortRange(e.starts_at, e.ends_at, format)}</span>}
        {e.recurring && widthPx >= ICON_WIDTH_PX && <Repeat size={10} className="pointer-events-none absolute right-1 top-1 opacity-70" />}
      </button>

      {/* The two grab zones sit over the block's own edges, so a neighbour is never harder to hit. */}
      {draggable && (
        <>
          <span onPointerDown={(ev) => onDragStart!(ev, "start")} onClick={onClick} className="absolute inset-x-0 top-0 z-10 cursor-ns-resize" style={{ height: grab }} />
          <span onPointerDown={(ev) => onDragStart!(ev, "end")} onClick={onClick} className="absolute inset-x-0 bottom-0 z-10 cursor-ns-resize" style={{ height: grab }} />
        </>
      )}
    </div>
  );
}

/**
 * An all-day event: a soft pill with a 3px bar of the colour at its left. A pill that continues
 * from before the visible range has no bar — the bar marks where the event begins.
 */
export function AllDayPill({
  e,
  continuing,
  height = 20,
  onClick,
  onDragStart,
  dragging,
  className,
  style,
}: {
  e: CalEvent;
  continuing?: boolean;
  height?: number;
  onClick?: () => void;
  /** Press-and-drag to move the pill to another day. All-day things move by whole days only. */
  onDragStart?: (ev: React.PointerEvent) => void;
  dragging?: boolean;
  className?: string;
  style?: React.CSSProperties;
}) {
  const dark = useDark();
  const declined = e.rsvp === "declined";
  const tentative = isTentative(e);
  const draggable = !!onDragStart && e.writable !== false;
  const bar = eventBar(e.calendar_color);
  return (
    <button
      type="button"
      data-event={e.id}
      onClick={onClick}
      onPointerDown={draggable ? onDragStart : undefined}
      title={e.title || "(no title)"}
      style={{
        ...style,
        height,
        lineHeight: `${height}px`,
        ["--fill" as string]: eventFill(e.calendar_color, tentative ? 0.22 * 0.6 : 0.22),
        ["--fill-hover" as string]: eventFill(e.calendar_color, 0.3),
        color: eventInk(e.calendar_color, dark),
        borderColor: tentative ? bar : undefined,
      }}
      className={cn(
        "relative block overflow-hidden rounded-[4px] bg-(--fill) pl-2 pr-1.5 text-left text-[11px] font-medium hover:bg-(--fill-hover)",
        tentative && "border border-dashed",
        declined && "opacity-45",
        dragging && "cursor-grabbing shadow-lg",
        className,
      )}
    >
      {!continuing && <span className="pointer-events-none absolute inset-y-0 left-0 w-[3px] rounded-[2px]" style={{ background: bar }} />}
      <span className={cn("block truncate", (declined || e.done) && "line-through")}>
        {e.emoji ? `${e.emoji} ` : ""}
        {e.title || "(no title)"}
      </span>
    </button>
  );
}

/** A timed event as one line of a month cell: a dot of the colour, the start time, the title. */
export function TimedRow({ e, format, onClick }: { e: CalEvent; format: "12" | "24"; onClick?: () => void }) {
  const declined = e.rsvp === "declined";
  return (
    <button
      type="button"
      data-event={e.id}
      onClick={onClick}
      title={`${e.title || "(no title)"} · ${shortRange(e.starts_at, e.ends_at, format)}`}
      className={cn("flex h-[18px] w-full min-w-0 items-center gap-1 rounded-[4px] px-1 text-left hover:bg-muted", declined && "opacity-45")}
    >
      <span className="size-1.5 shrink-0 rounded-full" style={{ background: eventBar(e.calendar_color) }} />
      <span className="shrink-0 text-[11px] leading-[18px] text-muted-foreground tnum">{shortTime(e.starts_at, format)}</span>
      <span className={cn("min-w-0 truncate text-[11px] leading-[18px] text-foreground", (declined || e.done) && "line-through")}>
        {e.emoji ? `${e.emoji} ` : ""}
        {e.title || "(no title)"}
      </span>
    </button>
  );
}

/** The old name and prop shape, still what the mobile day draws with. */
export function EventBlock(props: { e: CalEvent; top: number; height: number; column: number; columns: number; format: "12" | "24"; onClick?: () => void; onToggleDone?: () => void }) {
  return <TimedBlock e={props.e} top={props.top} height={props.height} column={props.column} columns={props.columns} widthPx={0} format={props.format} onClick={props.onClick} />;
}
