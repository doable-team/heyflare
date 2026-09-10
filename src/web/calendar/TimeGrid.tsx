import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type MutableRefObject } from "react";
import type { CalEvent } from "@shared/types";
import { cn } from "@/lib/utils";
import { useToast } from "../components/Toast";
import { useCalendar } from "./CalendarContext";
import { AllDayPill, TimedBlock } from "./EventBlock";
import { useDark } from "./colors";
import {
  DRAG_SLOP_PX,
  MIN_EVENT_MS,
  SNAP_MS,
  allDaySpan,
  dragSpan,
  previewed,
  shiftDays,
  spanMoved,
  spanPatch,
  swallowNextClick,
  type DragMode,
  type DragSpan,
  type EventPreview,
} from "./dragEvent";
import { useEventMutations } from "../api";
import { clockTime, dateKey, daysBetween, hourLabel, isWeekend, layoutColumns, placeBlocks, startOfDayMs, weekdayLabel, weekdayShort } from "../lib/caldate";

/**
 * The time grid Apple Calendar draws for a day or a week: a header row, an all-day banner row,
 * and a 24-hour column per day that scrolls inside itself. The week passes seven days, the day
 * passes one; nothing else differs.
 */

const DAY_MS = 24 * 60 * 60 * 1000;
/** The hour gutter. */
const GUTTER_PX = 56;
/** The day header row. */
const HEADER_PX = 44;
/** The all-day row never shrinks below this. */
const ALLDAY_MIN_PX = 28;
/** An all-day pill, and the air between two of them. */
const PILL_PX = 20;
const PILL_GAP_PX = 2;
/** The all-day row's padding above the first pill and below the last thing in it. */
const ALLDAY_PAD_PX = 4;
/** How many all-day lanes a column shows before it starts counting them instead. */
const ALLDAY_MAX_LANES = 3;
/** The `+N more` line under the pills. */
const MORE_PX = 14;
/** Twelve hours fill the viewport; an hour is never squeezed under this. */
const MIN_PX_PER_HOUR = 44;
/** The shortest a block is drawn: one line of type. */
const MIN_BLOCK_PX = 16;
const BLOCK_GAP_PX = 2;
/** The one accent in the calendar: the now line. */
const RED_LIGHT = "#ff3b30";
const RED_DARK = "#ff453a";

/** The page hands the grid a slot for PageUp/PageDown, which scroll it by a viewport. */
export type GridPager = MutableRefObject<((dir: 1 | -1) => void) | null>;

/** An all-day event clipped to the visible days, in lanes. */
interface Segment {
  e: CalEvent;
  /** Inclusive column indices. */
  start: number;
  end: number;
  /** Began before the first visible day: drawn without its bar. */
  continuing: boolean;
  lane: number;
}

/** A press that may become a drag: an event being moved or resized, or a new one being sketched. */
type Gesture =
  | {
      kind: "event";
      pointerId: number;
      event: CalEvent;
      mode: DragMode;
      x0: number;
      y0: number;
      col: number;
      dayStart: number;
      active: boolean;
      captured: boolean;
      span: DragSpan | null;
    }
  | { kind: "sketch"; pointerId: number; x0: number; y0: number; date: string; from: number; to: number; active: boolean; captured: boolean };

export function TimeGrid({ days, single, pager }: { days: string[]; single?: boolean; pager: GridPager }) {
  const { settings, cursor, today, range, revealAt, eventsOn, openEvent, createEvent } = useCalendar();
  const { update } = useEventMutations();
  const { toast } = useToast();
  const dark = useDark();
  const red = dark ? RED_DARK : RED_LIGHT;
  const n = days.length;
  const holdsToday = days.includes(today);

  // ---------- geometry ----------

  const root = useRef<HTMLDivElement>(null);
  const scroller = useRef<HTMLDivElement>(null);
  const cols = useRef<HTMLDivElement>(null);
  const [viewport, setViewport] = useState(0);
  const [colPx, setColPx] = useState(0);
  useLayoutEffect(() => {
    const el = scroller.current;
    const c = cols.current;
    if (!el || !c) return;
    const measure = () => {
      setViewport(el.clientHeight);
      setColPx(c.getBoundingClientRect().width / n);
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    ro.observe(c);
    return () => ro.disconnect();
  }, [n]);
  const pph = Math.max(MIN_PX_PER_HOUR, Math.floor(viewport / 12));
  const pxPerMs = pph / 3_600_000;
  const dayPx = pph * 24;

  // ---------- the clock ----------

  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = window.setInterval(() => setNow(Date.now()), 30_000);
    return () => window.clearInterval(t);
  }, []);
  const nowPx = (now - startOfDayMs(dateKey(now))) * pxPerMs;

  // ---------- initial scroll ----------

  // The week holding today opens with the current time in the middle; any other at 8 AM. "Today"
  // and ‹ › ask for the rule again; walking with the keys leaves the scroll where it is.
  const applied = useRef(0);
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el || !viewport) return;
    if (applied.current === revealAt.nonce && applied.current !== 0) return;
    applied.current = revealAt.nonce || -1;
    el.scrollTop = holdsToday ? Math.max(0, nowPx - viewport / 2) : 8 * pph;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [viewport, revealAt.nonce]);

  useEffect(() => {
    pager.current = (dir) => scroller.current?.scrollBy({ top: dir * (scroller.current.clientHeight || 0), behavior: "smooth" });
    return () => {
      pager.current = null;
    };
  }, [pager]);

  // ---------- drag ----------

  const gesture = useRef<Gesture | null>(null);
  /** Under the pointer now. */
  const [live, setLive] = useState<EventPreview | null>(null);
  /** Dropped, and held there until the server's answer comes back through the range query. */
  const [pending, setPending] = useState<EventPreview | null>(null);
  const [sketch, setSketch] = useState<{ date: string; from: number; to: number } | null>(null);
  const unswallow = useRef<() => void>(() => {});
  useEffect(() => () => unswallow.current(), []);

  const beginEvent = useCallback(
    (ev: React.PointerEvent, e: CalEvent, mode: DragMode, date: string) => {
      if (ev.button !== 0 || e.writable === false || gesture.current) return;
      // The column underneath sketches a new event; this press is not for it.
      ev.stopPropagation();
      gesture.current = {
        kind: "event",
        pointerId: ev.pointerId,
        event: e,
        // An all-day pill has no time to change, only a day, so it only ever moves.
        mode: e.all_day ? "move" : mode,
        x0: ev.clientX,
        y0: ev.clientY,
        col: Math.max(0, Math.min(n - 1, daysBetween(days[0], date))),
        dayStart: startOfDayMs(date),
        active: false,
        captured: false,
        span: null,
      };
    },
    [days, n],
  );

  /** The instant under a pointer in a column, snapped to the quarter hour (down for a press, nearest for a drag). */
  const msAtY = useCallback(
    (clientY: number, date: string, round: boolean) => {
      const r = cols.current?.getBoundingClientRect();
      const y = r ? Math.max(0, Math.min(dayPx, clientY - r.top)) : 0;
      const raw = y / pxPerMs;
      const snapped = round ? Math.round(raw / SNAP_MS) * SNAP_MS : Math.floor(raw / SNAP_MS) * SNAP_MS;
      return startOfDayMs(date) + Math.min(snapped, DAY_MS);
    },
    [dayPx, pxPerMs],
  );

  const beginSketch = (ev: React.PointerEvent, date: string) => {
    if (ev.button !== 0 || gesture.current) return;
    if ((ev.target as HTMLElement).closest("[data-event]")) return;
    const from = msAtY(ev.clientY, date, false);
    gesture.current = { kind: "sketch", pointerId: ev.pointerId, x0: ev.clientX, y0: ev.clientY, date, from, to: from + SNAP_MS, active: false, captured: false };
  };

  const capture = (g: Gesture, ev: React.PointerEvent) => {
    g.active = true;
    try {
      root.current?.setPointerCapture(ev.pointerId);
      g.captured = true;
    } catch {
      /* Capture is a nicety; the handlers on the root still see the move without it. */
    }
  };

  const onPointerMove = (ev: React.PointerEvent) => {
    const g = gesture.current;
    if (!g || ev.pointerId !== g.pointerId) return;
    const dx = ev.clientX - g.x0;
    const dy = ev.clientY - g.y0;
    if (!g.active && Math.abs(dx) < DRAG_SLOP_PX && Math.abs(dy) < DRAG_SLOP_PX) return;
    if (!g.active) capture(g, ev);

    if (g.kind === "sketch") {
      const to = msAtY(ev.clientY, g.date, true);
      g.to = to;
      setSketch({ date: g.date, from: g.from, to });
      return;
    }
    // Horizontally the grid is equal columns; a move may cross into any of them.
    const shift = g.mode === "move" && colPx > 0 ? Math.max(-g.col, Math.min(n - 1 - g.col, Math.round(dx / colPx))) : 0;
    const span = g.event.all_day
      ? allDaySpan(g.event, shift)
      : dragSpan(g.event, g.mode, dy / pxPerMs, shift, { min: shiftDays(g.dayStart, shift), max: shiftDays(g.dayStart, shift + 1) });
    g.span = span;
    setLive({ id: g.event.id, event: g.event, ...span });
  };

  const finish = (ev: React.PointerEvent, commit: boolean) => {
    const g = gesture.current;
    if (!g || ev.pointerId !== g.pointerId) return;
    gesture.current = null;
    if (g.captured) {
      try {
        root.current?.releasePointerCapture(ev.pointerId);
      } catch {
        /* Already released with the pointer. */
      }
    }
    setLive(null);
    setSketch(null);

    if (g.kind === "sketch") {
      if (!commit) return;
      // A press that never became a drag is a click: half an hour at the snapped time.
      if (!g.active) {
        createEvent({ starts_at: g.from, ends_at: g.from + 30 * 60_000 });
        return;
      }
      const a = Math.min(g.from, g.to);
      const b = Math.max(g.from, g.to);
      createEvent({ starts_at: a, ends_at: Math.max(b, a + MIN_EVENT_MS) });
      return;
    }

    // A press that never became a drag is a click, and the block opens as it always did.
    if (!g.active) return;
    unswallow.current();
    unswallow.current = swallowNextClick(root.current);
    const span = g.span;
    if (!commit || !span || !spanMoved(g.event, span)) return;
    const next: EventPreview = { id: g.event.id, event: g.event, ...span };
    setPending(next);
    update.mutate(
      { id: g.event.id, ...spanPatch(g.event, span) },
      {
        onError: (err) => {
          setPending((p) => (p === next ? null : p));
          toast((err as Error)?.message || "Couldn't move this event.", { kind: "error" });
        },
      },
    );
  };

  // Let go of the dropped position once the refetched range agrees with it — or, if the server
  // answered with something else entirely, after long enough that the block can't be stuck.
  useEffect(() => {
    if (!pending) return;
    const cur = (range?.events ?? []).find((e) => e.id === pending.id);
    if (cur && cur.starts_at === pending.starts_at && cur.ends_at === pending.ends_at) {
      setPending(null);
      return;
    }
    const t = window.setTimeout(() => setPending(null), 6000);
    return () => window.clearTimeout(t);
  }, [pending, range]);

  const preview = live ?? pending;

  // ---------- all-day lanes ----------

  const { segments, lanes, more } = useMemo(() => {
    const first = days[0];
    const last = days[n - 1];
    const raw: Omit<Segment, "lane">[] = [];
    const source = (range?.events ?? []).filter((e) => e.all_day && e.id !== preview?.id);
    if (preview?.event.all_day) source.push(previewed(preview));
    for (const e of source) {
      const from = e.start_date ?? dateKey(e.starts_at);
      const to = e.end_date ?? from;
      if (to < first || from > last) continue;
      raw.push({ e, start: Math.max(0, daysBetween(first, from)), end: Math.min(n - 1, daysBetween(first, to)), continuing: from < first });
    }
    // Longest first inside a start column, so a trip claims the top lane and the one-day things
    // fill in underneath it.
    raw.sort((a, b) => a.start - b.start || b.end - a.end || a.e.starts_at - b.e.starts_at || a.e.id.localeCompare(b.e.id));
    const laneEnds: number[] = [];
    const out: Segment[] = [];
    const hidden = Array.from({ length: n }, () => 0);
    for (const s of raw) {
      let lane = laneEnds.findIndex((end) => end < s.start);
      if (lane === -1) {
        lane = laneEnds.length;
        laneEnds.push(s.end);
      } else laneEnds[lane] = s.end;
      if (lane >= ALLDAY_MAX_LANES) {
        for (let c = s.start; c <= s.end; c++) hidden[c]++;
        continue;
      }
      out.push({ ...s, lane });
    }
    return { segments: out, lanes: Math.min(laneEnds.length, ALLDAY_MAX_LANES), more: hidden };
  }, [range?.events, days, n, preview]);
  const hasMore = more.some((m) => m > 0);
  const allDayPx = Math.max(ALLDAY_MIN_PX, ALLDAY_PAD_PX * 2 + lanes * (PILL_PX + PILL_GAP_PX) - (lanes ? PILL_GAP_PX : 0) + (hasMore ? MORE_PX : 0));

  const nowLabel = clockTime(now, settings.time_format);

  return (
    <div
      ref={root}
      className="flex min-h-0 flex-1 select-none flex-col"
      onPointerMove={onPointerMove}
      onPointerUp={(ev) => finish(ev, true)}
      onPointerCancel={(ev) => finish(ev, false)}
    >
      {/* Day headers */}
      <div className="flex shrink-0 border-b border-border" style={{ height: HEADER_PX }}>
        <div className="shrink-0" style={{ width: GUTTER_PX }} />
        {days.map((d) => (
          <DayHead key={d} date={d} today={d === today} cursor={d === cursor} single={!!single} />
        ))}
      </div>

      {/* All-day row */}
      <div className="flex shrink-0 border-b border-border" style={{ height: allDayPx }}>
        <div className="shrink-0 pr-2 text-right text-[11px] leading-[20px] text-muted-foreground" style={{ width: GUTTER_PX, paddingTop: ALLDAY_PAD_PX }}>
          all-day
        </div>
        <div className="relative min-w-0 flex-1">
          {segments.map((s) => (
            <AllDayPill
              key={`${s.e.id}:${s.start}`}
              e={s.e}
              continuing={s.continuing}
              dragging={preview?.id === s.e.id}
              onClick={() => openEvent(s.e)}
              onDragStart={(ev) => beginEvent(ev, s.e, "move", days[Math.max(s.start, 0)])}
              className="absolute"
              style={{
                left: `calc(${(s.start / n) * 100}% + 2px)`,
                width: `calc(${((s.end - s.start + 1) / n) * 100}% - 4px)`,
                top: ALLDAY_PAD_PX + s.lane * (PILL_PX + PILL_GAP_PX),
                zIndex: preview?.id === s.e.id ? 90 : undefined,
              }}
            />
          ))}
          {hasMore &&
            more.map((m, i) =>
              m > 0 ? (
                <span
                  key={days[i]}
                  className="absolute text-[11px] leading-[14px] text-muted-foreground"
                  style={{ left: `calc(${(i / n) * 100}% + 2px)`, top: ALLDAY_PAD_PX + lanes * (PILL_PX + PILL_GAP_PX) }}
                >
                  +{m} more
                </span>
              ) : null,
            )}
        </div>
      </div>

      {/* The hours */}
      <div ref={scroller} className="min-h-0 flex-1 overflow-y-auto overflow-x-hidden overscroll-contain [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        <div className="relative flex" style={{ height: dayPx }}>
          {/* Gutter */}
          <div className="relative shrink-0" style={{ width: GUTTER_PX }}>
            {Array.from({ length: 23 }, (_, i) => i + 1).map((h) =>
              holdsToday && Math.abs(h * pph - nowPx) < 10 ? null : (
                <span key={h} className="absolute right-2 -translate-y-1/2 whitespace-nowrap text-[11px] leading-none text-muted-foreground tnum" style={{ top: h * pph }}>
                  {hourLabel(h, settings.time_format)}
                </span>
              ),
            )}
            {holdsToday && (
              <span
                className="absolute right-2 z-[100] flex h-4 -translate-y-1/2 items-center rounded-full px-1.5 text-[10px] font-semibold leading-none text-white tnum"
                style={{ top: nowPx, background: red }}
              >
                {nowLabel}
              </span>
            )}
          </div>

          {/* Columns */}
          <div ref={cols} data-grid-cols className="relative flex min-w-0 flex-1">
            <div className="pointer-events-none absolute inset-0 z-0">
              {Array.from({ length: 23 }, (_, i) => i + 1).map((h) => (
                <div key={h} className="absolute inset-x-0 border-t border-border" style={{ top: h * pph }} />
              ))}
              {Array.from({ length: 24 }, (_, i) => i).map((h) => (
                <div key={`h${h}`} className="absolute inset-x-0 border-t border-dotted border-border/50" style={{ top: (h + 0.5) * pph }} />
              ))}
            </div>
            {days.map((d, i) => (
              <Column
                key={d}
                date={d}
                first={i === 0}
                today={d === today}
                cursor={d === cursor}
                pxPerMs={pxPerMs}
                dayPx={dayPx}
                colPx={colPx}
                format={settings.time_format}
                timed={eventsOn(d).timed}
                preview={preview}
                sketch={sketch?.date === d ? sketch : null}
                nowPx={d === today ? nowPx : null}
                red={red}
                onOpen={openEvent}
                onDragStart={beginEvent}
                onPointerDown={(ev) => beginSketch(ev, d)}
              />
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

/** `Mon 9` — or `Wednesday 9` in the day view. Today's number sits in a filled circle; the cursor's in a ring. */
function DayHead({ date, today, cursor, single }: { date: string; today: boolean; cursor: boolean; single: boolean }) {
  return (
    <div className="flex min-w-0 flex-1 items-center justify-center gap-1 text-[13px]">
      <span className="truncate text-muted-foreground">{single ? weekdayLabel(date) : weekdayShort(date)}</span>
      <span
        className={cn(
          "inline-flex size-6 shrink-0 items-center justify-center rounded-full font-semibold text-foreground tnum",
          today && "bg-foreground text-background",
          !today && cursor && "border border-foreground",
        )}
      >
        {Number(date.slice(8))}
      </span>
    </div>
  );
}

/** One day's column: its blocks, the ghost of a drag passing through, the sketch of a new event, the now line. */
function Column({
  date,
  first,
  today,
  cursor,
  pxPerMs,
  dayPx,
  colPx,
  format,
  timed,
  preview,
  sketch,
  nowPx,
  red,
  onOpen,
  onDragStart,
  onPointerDown,
}: {
  date: string;
  first: boolean;
  today: boolean;
  cursor: boolean;
  pxPerMs: number;
  dayPx: number;
  colPx: number;
  format: "12" | "24";
  timed: CalEvent[];
  preview: EventPreview | null;
  sketch: { from: number; to: number } | null;
  nowPx: number | null;
  red: string;
  onOpen: (e: CalEvent) => void;
  onDragStart: (ev: React.PointerEvent, e: CalEvent, mode: DragMode, date: string) => void;
  onPointerDown: (ev: React.PointerEvent) => void;
}) {
  const dayStart = useMemo(() => startOfDayMs(date), [date]);
  const posOf = useCallback((ms: number) => Math.max(0, Math.min(dayPx, (ms - dayStart) * pxPerMs)), [dayPx, dayStart, pxPerMs]);

  // A dragged event is drawn where it is *going*, which may well be another column. Every column
  // drops it from its own list, and the column its prospective span lands in draws it on top.
  const { rest, ghost } = useMemo(() => {
    if (!preview) return { rest: timed, ghost: null as CalEvent | null };
    const kept = timed.filter((e) => e.id !== preview.id);
    const here = !preview.event.all_day && preview.ends_at > dayStart && preview.starts_at < dayStart + DAY_MS;
    return { rest: kept, ghost: here ? previewed(preview) : null };
  }, [timed, preview, dayStart]);

  const layout = useMemo(() => layoutColumns(rest, 0), [rest]);
  const placed = useMemo(
    () => placeBlocks(rest.map((e) => ({ top: posOf(Math.max(e.starts_at, dayStart)), bottom: posOf(Math.min(e.ends_at, dayStart + DAY_MS)) })), layout, MIN_BLOCK_PX, BLOCK_GAP_PX),
    [rest, layout, posOf, dayStart],
  );

  return (
    <div
      data-col={date}
      className={cn("relative min-w-0 flex-1 border-border", !first && "border-l", isWeekend(date) && "bg-muted/30", (today || cursor) && "bg-muted/50")}
      onPointerDown={onPointerDown}
    >
      {rest.map((e, i) => (
        <TimedBlock
          key={e.id}
          e={e}
          top={placed[i].top}
          height={placed[i].height}
          column={layout[i].column}
          columns={layout[i].columns}
          widthPx={(colPx - 4) / layout[i].columns - (layout[i].columns > 1 ? 1 : 0)}
          format={format}
          z={20 + i}
          onClick={() => onOpen(e)}
          onDragStart={(ev, mode) => onDragStart(ev, e, mode, date)}
        />
      ))}

      {ghost && (
        <TimedBlock
          e={ghost}
          top={posOf(Math.max(ghost.starts_at, dayStart))}
          height={posOf(Math.min(ghost.ends_at, dayStart + DAY_MS)) - posOf(Math.max(ghost.starts_at, dayStart))}
          column={0}
          columns={1}
          widthPx={colPx - 4}
          format={format}
          dragging
          onClick={() => onOpen(ghost)}
        />
      )}

      {sketch && (
        <div
          className="pointer-events-none absolute inset-x-0.5 z-[95] rounded-[4px] border border-dashed border-foreground/50 bg-foreground/5"
          style={{
            top: posOf(Math.min(sketch.from, sketch.to)),
            height: Math.max(posOf(Math.max(sketch.from, sketch.to)) - posOf(Math.min(sketch.from, sketch.to)), MIN_EVENT_MS * pxPerMs),
          }}
        />
      )}

      {nowPx !== null && (
        <div className="pointer-events-none absolute inset-x-0 z-[100] h-px" style={{ top: nowPx, background: red }}>
          <span className="absolute -left-[3.5px] -top-[3px] size-[7px] rounded-full" style={{ background: red }} />
        </div>
      )}
    </div>
  );
}
