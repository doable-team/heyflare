import { CheckCircle2, Circle, Lock, Repeat, Users, Video } from "lucide-react";
import type { CalEvent } from "@shared/types";
import { cn } from "@/lib/utils";
import { eventColors } from "./colors";
import { InkCircle } from "./InkCircle";
import { handlePx, type DragMode } from "./dragEvent";
import { heyRange, heyTime } from "./scale";

/**
 * The two shapes an event takes on HEY's week grid.
 *
 * A timed event is a *proportional box*: it is exactly as tall as it is long, filled solid in its
 * calendar's colour, because the whole argument of the view is that an hour looks like an hour.
 * An all-day event is a stadium pill pinned to the floor of the column — the opposite of every
 * other calendar, and deliberately so: all-day things are the ground the day stands on, not a
 * banner hung from the ceiling.
 *
 * The one thing that is *not* signalled with colour is uncertainty. A tentative or "maybe" event
 * has its colour taken away — white ground, grey hatching, a dashed edge and a handwritten italic
 * — so a provisional afternoon reads as provisional from across the room.
 */

/** Grey diagonal hatching for a provisional event. */
const HATCH = "repeating-linear-gradient(45deg, rgba(0,0,0,0.09) 0 3px, rgba(0,0,0,0) 3px 7px)";
/** Nothing definitive about a hand-drawn hand: fall back through whatever the platform scribbles with. */
const HAND = '"Bradley Hand", "Brush Script MT", "Segoe Script", "Comic Sans MS", cursive, ui-sans-serif';

/** True when the event is only provisionally on the calendar — the organiser's or the user's doubt. */
function isMaybe(e: CalEvent): boolean {
  return e.status === "tentative" || e.rsvp === "tentative";
}

/** Solid fill and its contrast colour — unless the event is a maybe, which is drawn without colour. */
function surface(e: CalEvent): React.CSSProperties {
  if (isMaybe(e)) return { background: "#ffffff", backgroundImage: HATCH, color: "#131313" };
  const { background, color } = eventColors(e.calendar_color);
  return { background, color };
}

/**
 * An all-day event: a fully rounded stadium pill, solid in the calendar's colour.
 * Exported as `AllDayChip` too, which is what the month grid and the day panes still call it.
 */
export function AllDayPill({
  e,
  onClick,
  focused,
  onDragStart,
  dragging,
}: {
  e: CalEvent;
  onClick?: () => void;
  focused?: boolean;
  /** Press-and-drag to move the pill to another day. All-day things move by whole days only. */
  onDragStart?: (ev: React.PointerEvent) => void;
  dragging?: boolean;
}) {
  const declined = e.rsvp === "declined";
  const maybe = isMaybe(e);
  const draggable = !!onDragStart && e.writable !== false;
  return (
    <button
      type="button"
      data-event={e.id}
      onClick={onClick}
      onPointerDown={draggable ? onDragStart : undefined}
      title={e.title || "(no title)"}
      style={surface(e)}
      className={cn(
        "flex h-[18px] w-full items-center gap-1 overflow-hidden rounded-full px-2 text-left",
        "text-[11px] font-medium leading-[18px] transition-opacity hover:opacity-85",
        maybe && "border border-dashed border-foreground/35 italic",
        e.done && "line-through",
        declined && "opacity-45 line-through",
        focused && "ring-1 ring-ring",
        dragging && "cursor-grabbing opacity-100 shadow-lg ring-1 ring-foreground/40",
      )}
    >
      {e.emoji && <span className="shrink-0">{e.emoji}</span>}
      <span className="truncate" style={maybe ? { fontFamily: HAND } : undefined}>
        {e.title || "(no title)"}
      </span>
      {e.recurring && <Repeat size={9} className="ml-auto shrink-0 opacity-60" />}
    </button>
  );
}

/** The old name, kept so the month grid and the day panes don't have to change. */
export const AllDayChip = AllDayPill;

/** Under this a box has room for one line only, and the time moves onto it beside the title. */
const ONE_LINE_PX = 34;
/** Under this there is no room for the icon row along the bottom. */
const ICONS_PX = 64;
/**
 * However short the meeting, it still has to be clickable. Exported because a block drawn taller
 * than its duration overlaps whatever comes next, so the column layout has to know this number too.
 *
 * This is the *day* floor. A compressed view has to pass its own — see the `floor` prop — because
 * 22px of a 460px week column is over an hour, and a floor that lies about the duration by that
 * much drags the column layout along with it: a 1:30-1:45 lunch ends up shouldering a 2:15 meeting
 * into a second column even though the two never touch.
 */
export const FLOOR_PX = 22;
/** Under this there is no room for type at all, and the block is just its bar of colour. */
const BARE_PX = 13;

/**
 * One timed event, absolutely positioned inside a day column, sized by its own duration.
 * `column`/`columns` come from `layoutColumns` so overlapping events sit side by side.
 *
 * The text treatment is driven by the box's own height rather than by a prop, because the height
 * *is* the duration: a 20-minute call and a 3-hour workshop should not be typeset the same way.
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
  onPhoto,
  onDragStart,
  dragging,
  floor = FLOOR_PX,
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
  /** Sitting over a day's photo: keep the fill opaque and ring it in white, the way HEY does. */
  onPhoto?: boolean;
  /**
   * Press to move the block, or press within `EDGE_PX` of the top or bottom edge to take that end
   * with you. The view owns the gesture — it is the only thing that knows what a pixel is worth —
   * so all the block does is say which of the three was asked for.
   */
  onDragStart?: (ev: React.PointerEvent, mode: DragMode) => void;
  /** Under the pointer, or dropped and waiting for the server: draw it lifted, with live times. */
  dragging?: boolean;
  /**
   * The shortest this view ever draws a block. Whatever you pass here you must also hand to
   * `layoutColumns` as milliseconds, or the columns will not match what is on screen.
   */
  floor?: number;
}) {
  const h = Math.max(height, floor);
  const bare = h < BARE_PX;
  const oneLine = h < ONE_LINE_PX;
  const roomy = h >= ICONS_PX;
  // 6px of padding and a 12px time line come off the top; each title line costs 14px. Clamping to
  // what actually fits stops a 2.5-hour block from slicing its second line in half.
  const titleLines = Math.max(1, Math.min(3, Math.floor((h - 6 - 12) / 14)));
  const declined = e.rsvp === "declined";
  const maybe = isMaybe(e);

  // Two pixels of air either side of the track, and a hairline of it between neighbours.
  const width = `calc((100% - 4px) / ${columns} - ${columns > 1 ? 1 : 0}px)`;
  const left = `calc((100% - 4px) / ${columns} * ${column} + 2px)`;

  const title = e.title || "(no title)";
  const icons = roomy && (e.conference_url || e.attendees.length > 0 || e.recurring || !e.writable);
  // A read-only calendar's events are looked at, not rearranged.
  const draggable = !!onDragStart && e.writable !== false;
  const grab = handlePx(h);

  return (
    <div className="absolute" style={{ top, height: h, width, left, zIndex: dragging ? 35 : 20 }} data-event={e.id}>
      {e.circled && <InkCircle />}
      <button
        type="button"
        onClick={onClick}
        onPointerDown={draggable ? (ev) => onDragStart!(ev, "move") : undefined}
        title={`${title}${e.location ? ` · ${e.location}` : ""} · ${heyRange(e.starts_at, e.ends_at, format)}`}
        style={surface(e)}
        className={cn(
          "flex h-full w-full flex-col overflow-hidden rounded-[3px] px-1.5 text-left transition-opacity hover:opacity-90",
          oneLine ? "justify-center py-0" : "py-[3px]",
          maybe && "border border-dashed border-foreground/40",
          declined && "opacity-45",
          // Over a photo the block keeps its solid fill and takes a white keyline; that ring is the
          // whole separation device in HEY — no scrim on the picture, no shadow on the text.
          onPhoto && "shadow-[0_0_0_2px_#fff]",
          focused && "ring-1 ring-ring ring-offset-0",
          dragging && "cursor-grabbing opacity-100 shadow-lg ring-1 ring-foreground/40",
        )}
      >
        {bare ? null : oneLine ? (
          // One line: the time and the title share a baseline — "5:30PM- 6PM  Weekly Call…"
          <span className="flex min-w-0 items-baseline gap-1">
            {e.kind === "todo" && <DoneBox e={e} onToggleDone={onToggleDone} />}
            {/* Mid-drag the whole range shows, however short the block: you are choosing both ends. */}
            <span className="shrink-0 text-[9.5px] leading-none tnum opacity-70">
              {dragging ? heyRange(e.starts_at, e.ends_at, format) : heyTime(e.starts_at, format)}
            </span>
            <span
              className={cn("min-w-0 truncate text-[11px] font-semibold leading-[13px]", (e.done || declined) && "line-through")}
              style={maybe ? { fontFamily: HAND, fontStyle: "italic" } : undefined}
            >
              {e.emoji ? `${e.emoji} ` : ""}
              {title}
            </span>
          </span>
        ) : (
          <>
            <span className="block shrink-0 truncate whitespace-nowrap text-[9.5px] leading-[12px] tnum opacity-70">{heyRange(e.starts_at, e.ends_at, format)}</span>
            <span className="flex min-w-0 items-start gap-1">
              {e.kind === "todo" && <DoneBox e={e} onToggleDone={onToggleDone} />}
              <span
                style={{ WebkitLineClamp: titleLines, ...(maybe ? { fontFamily: HAND, fontStyle: "italic" } : {}) }}
                className={cn(
                  "min-w-0 overflow-hidden text-ellipsis text-[12px] font-semibold leading-[14px] [display:-webkit-box] [-webkit-box-orient:vertical]",
                  (e.done || declined) && "line-through",
                )}
              >
                {e.emoji ? `${e.emoji} ` : ""}
                {title}
              </span>
            </span>
          </>
        )}

        {icons && (
          <span className="mt-auto flex shrink-0 items-center gap-1 pt-0.5 opacity-65">
            {e.conference_url && <Video size={10} />}
            {e.attendees.length > 0 && <Users size={10} />}
            {e.recurring && <Repeat size={10} />}
            {!e.writable && <Lock size={10} />}
          </span>
        )}
      </button>

      {/* The two grab zones. They sit over the block's own edges rather than outside it, so a
          neighbouring event is never harder to hit, and they still open the event on a click. */}
      {draggable && (
        <>
          <span
            onPointerDown={(ev) => onDragStart!(ev, "start")}
            onClick={onClick}
            className="absolute inset-x-0 top-0 z-10 cursor-ns-resize"
            style={{ height: grab }}
          />
          <span
            onPointerDown={(ev) => onDragStart!(ev, "end")}
            onClick={onClick}
            className="absolute inset-x-0 bottom-0 z-10 cursor-ns-resize"
            style={{ height: grab }}
          />
        </>
      )}
    </div>
  );
}

/** A repeating todo carries its own tick, and ticking it must not open the editor. */
function DoneBox({ e, onToggleDone }: { e: CalEvent; onToggleDone?: () => void }) {
  return (
    <span
      role="checkbox"
      aria-checked={e.done}
      tabIndex={-1}
      onClick={(ev) => {
        ev.stopPropagation();
        onToggleDone?.();
      }}
      className="mt-[1px] shrink-0 opacity-80 hover:opacity-100"
    >
      {e.done ? <CheckCircle2 size={11} /> : <Circle size={11} />}
    </span>
  );
}
