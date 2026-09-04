import { useEffect, useMemo, useRef, useState } from "react";
import type { CalEvent, CalendarDay } from "@shared/types";
import { cn } from "@/lib/utils";
import { useCalendar } from "./CalendarContext";
import { eventColors } from "./colors";
import { DayPhotoBackdrop, hasPhoto } from "./DayPhoto";
import { addDays, dateKey, daysBetween, isPast, isToday, keyToDate } from "../lib/caldate";

/**
 * The year — HEY's, rebuilt from the real thing.
 *
 * It is **not** twelve little month grids. It is one continuous ribbon of every day in the year,
 * wrapped into rows of exactly **four weeks**, and the wrapping is weekday-aligned: the column a
 * day lands in is `dayOfWeek + 7 * weekWithinRow`, so column 0, 7, 14 and 21 are all Sundays and
 * every column in the grid holds the same weekday for its position. That is what makes the
 * weekend stripes run straight down the page, and it is why you can read the shape of a year at a
 * glance — the eye follows a column, not a box.
 *
 * The ribbon starts on the Sunday on or before January 1 and runs past December 31, with the
 * cells outside the year left blank. Months are not sections; a month announces itself on the day
 * it starts, with a small badge and a hairline tick dropping through the row. That tick is how you
 * read where a month changes.
 *
 * Only **all-day and multi-day** events are drawn, which is HEY's rule for the year and a
 * deliberate one: a year of timed meetings is unreadable, and what genuinely belongs to a *date* —
 * a birthday, a trip, a holiday — is what you want a year to show you. Each is a horizontal pill
 * spanning the columns it covers, cut into one segment per row when it crosses a wrap.
 */

/** Four weeks to a row. The whole idiom hangs off this number. */
/**
 * Four weeks to a row is HEY's shape, but it only works when a cell is wide enough for "SAT 10".
 * Below that the grid clips two-digit dates, so the row falls back to two weeks, then one — always
 * a whole number of weeks, which is what keeps the weekend stripes aligned down the page.
 */
const WEEK_OPTIONS = [4, 2, 1] as const;
const MIN_CELL_PX = 52;
/** Enough for the date line plus a couple of pills or a glimpse of a photo. */
const ROW_PX = 84;
/** Where the pill overlay starts — clear of the date line. */
const DATE_PX = 19;
const PILL_PX = 14;
const PILL_GAP = 2;
/** As many lanes as the row height actually has room for. */
const MAX_LANES = Math.max(1, Math.floor((ROW_PX - DATE_PX - 2) / (PILL_PX + PILL_GAP)));

const MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];
const WEEKDAYS = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];

/** One drawn pill: an all-day event clipped to a single row of the ribbon. */
interface Segment {
  e: CalEvent;
  /** Inclusive column indices within the row, 0-27. */
  start: number;
  end: number;
  lane: number;
}

export function YearView() {
  const { cursor, setCursor, setView, openEvent, range, revealAt } = useCalendar();

  const year = cursor.slice(0, 4);
  const jan1 = `${year}-01-01`;
  const dec31 = `${year}-12-31`;

  // The ribbon's own window: back to the Sunday on or before Jan 1, forward to fill the last row.
  // It spills outside the loaded range at both ends; those cells simply render empty.
  // How many weeks fit a row at this width. Measured, not guessed at a breakpoint, because the
  // sidebar and the assistant panel both change how much room this actually has.
  const boxRef = useRef<HTMLDivElement>(null);
  const [cols, setCols] = useState(28);
  useEffect(() => {
    const el = boxRef.current;
    if (!el) return;
    const measure = () => {
      const w = el.clientWidth;
      const weeks = WEEK_OPTIONS.find((n) => w / (n * 7) >= MIN_CELL_PX) ?? 1;
      setCols(weeks * 7);
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const { gridStart, rowCount, totalDays } = useMemo(() => {
    const start = addDays(jan1, -keyToDate(jan1).getDay());
    const days = daysBetween(start, dec31) + 1;
    const rows = Math.ceil(days / cols);
    return { gridStart: start, rowCount: rows, totalDays: rows * cols };
  }, [jan1, dec31, cols]);

  // Day photos show through here too, read-only — the year is where you notice you had a life.
  const dayByKey = useMemo(() => new Map((range?.days ?? []).map((d) => [d.date, d] as const)), [range?.days]);

  /**
   * Every all-day event, cut into per-row segments and packed into lanes.
   *
   * Taken from the raw range rather than `eventsOn`, because a pill needs the event's whole span —
   * per-day membership would only tell us a day is covered, not where the trip begins and ends.
   */
  const segmentsByRow = useMemo(() => {
    const rows: Segment[][] = Array.from({ length: rowCount }, () => []);
    const raw: { row: number; start: number; end: number; e: CalEvent }[] = [];

    for (const e of range?.events ?? []) {
      if (!e.all_day) continue;
      const from = e.start_date ?? dateKey(e.starts_at);
      const to = e.end_date ?? from;
      let a = daysBetween(gridStart, from);
      let b = daysBetween(gridStart, to);
      if (!Number.isFinite(a) || !Number.isFinite(b)) continue;
      if (b < a) b = a;
      // Clamp to the ribbon before splitting, so an open-ended import can't fan out forever.
      a = Math.max(a, 0);
      b = Math.min(b, totalDays - 1);
      if (b < a) continue;

      for (let i = a; i <= b; ) {
        const row = Math.floor(i / cols);
        const rowStart = row * cols;
        const last = Math.min(b, rowStart + cols - 1);
        raw.push({ row, start: i - rowStart, end: last - rowStart, e });
        i = last + 1;
      }
    }

    // Longest first inside a start column, so a trip claims the top lane and the one-day things
    // fill in underneath it — the same greedy packing `layoutColumns` does for a busy hour.
    raw.sort((x, y) => x.start - y.start || y.end - x.end || x.e.id.localeCompare(y.e.id));
    const laneEnds = Array.from({ length: rowCount }, () => [] as number[]);
    for (const s of raw) {
      const ends = laneEnds[s.row];
      let lane = ends.findIndex((end) => end < s.start);
      if (lane === -1) {
        lane = ends.length;
        ends.push(s.end);
      } else {
        ends[lane] = s.end;
      }
      if (lane >= MAX_LANES) continue;
      rows[s.row].push({ e: s.e, start: s.start, end: s.end, lane });
    }
    return rows;
  }, [range?.events, gridStart, rowCount, totalDays, cols]);

  const pick = (date: string) => {
    setCursor(date);
    setView("days");
  };

  /**
   * Open on the row you are actually on. A year is thirteen screens of grid, and landing at January
   * every time means hunting for today before you can read anything.
   */
  const rowOf = (date: string) => Math.floor(daysBetween(gridStart, date) / cols);
  const rowRefs = useRef(new Map<number, HTMLDivElement>());
  const landed = useRef(false);
  useEffect(() => {
    const box = boxRef.current;
    const row = rowRefs.current.get(rowOf(cursor));
    if (!box || !row) return;
    const top = row.offsetTop - (box.clientHeight - row.offsetHeight) / 2;
    const first = !landed.current;
    if (!first) {
      // Already comfortably on screen: leave the scroll where the reader put it.
      const rel = row.offsetTop - box.scrollTop;
      if (rel >= 0 && rel + row.offsetHeight <= box.clientHeight) return;
    }
    box.scrollTo({ top: Math.max(0, top), behavior: first ? "auto" : "smooth" });
    if (range) landed.current = true;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cursor, cols, rowCount, range, revealAt.nonce]);

  return (
    <div ref={boxRef} className="overscroll-contain min-h-0 flex-1 overflow-y-auto overflow-x-hidden rounded-md border border-border bg-background">
      {Array.from({ length: rowCount }, (_, r) => (
        <Row
          key={r}
          innerRef={(el) => {
            if (el) rowRefs.current.set(r, el);
            else rowRefs.current.delete(r);
          }}
          rowStart={addDays(gridStart, r * cols)}
          cols={cols}
          jan1={jan1}
          dec31={dec31}
          cursor={cursor}
          dayByKey={dayByKey}
          segments={segmentsByRow[r]}
          onPick={pick}
          onOpenEvent={openEvent}
        />
      ))}
    </div>
  );
}

/**
 * Four weeks. Twenty-eight cells of equal fractional width — no horizontal scrollbar, ever; at a
 * narrow window the cells simply get small, which the date type is already sized for.
 */
function Row({
  rowStart,
  jan1,
  dec31,
  cursor,
  dayByKey,
  cols,
  segments,
  onPick,
  onOpenEvent,
  innerRef,
}: {
  innerRef: (el: HTMLDivElement | null) => void;
  rowStart: string;
  jan1: string;
  dec31: string;
  cursor: string;
  dayByKey: Map<string, CalendarDay>;
  cols: number;
  segments: Segment[];
  onPick: (date: string) => void;
  onOpenEvent: (e: CalEvent) => void;
}) {
  const days = useMemo(() => Array.from({ length: cols }, (_, i) => addDays(rowStart, i)), [rowStart, cols]);

  return (
    <div ref={innerRef} className="relative grid" style={{ height: ROW_PX, gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))` }}>
      {days.map((d, c) => (
        <Cell
          key={d}
          date={d}
          col={c}
          inYear={d >= jan1 && d <= dec31}
          selected={d === cursor}
          day={dayByKey.get(d)}
          onPick={onPick}
        />
      ))}

      {/* The pills float over the cells rather than living inside one of them: a week-long trip is
          a single bar, and a bar cannot be a child of seven buttons. */}
      <div className="pointer-events-none absolute inset-x-0 bottom-0 z-20" style={{ top: DATE_PX }}>
        {segments.map((s) => (
          <div
            key={`${s.e.id}:${s.start}`}
            className="absolute px-[1px]"
            style={{
              left: `${(s.start / cols) * 100}%`,
              width: `${((s.end - s.start + 1) / cols) * 100}%`,
              top: s.lane * (PILL_PX + PILL_GAP),
            }}
          >
            <Pill e={s.e} onClick={() => onOpenEvent(s.e)} />
          </div>
        ))}
      </div>
    </div>
  );
}

/**
 * One day. The date line reads `SUN 12`, with the month's three letters badged in front of it on
 * the day a month turns, and a hairline dropping down the cell's left edge on the same day.
 */
function Cell({
  date,
  col,
  inYear,
  selected,
  day,
  onPick,
}: {
  date: string;
  col: number;
  inYear: boolean;
  selected: boolean;
  day: CalendarDay | undefined;
  onPick: (date: string) => void;
}) {
  // Column 0 is a Sunday by construction, so the weekend is the same pair of columns in every week.
  const dow = col % 7;
  const weekend = dow === 0 || dow === 6;

  if (!inYear) {
    // Before January and after December: the stripe carries on, the day does not.
    return <div className={cn(weekend && "bg-muted/25")} />;
  }

  const today = isToday(date);
  const photo = hasPhoto(day);
  const first = date.slice(8) === "01";
  const month = Number(date.slice(5, 7)) - 1;

  return (
    <button
      type="button"
      onClick={() => onPick(date)}
      title={date}
      className={cn(
        "relative min-w-0 text-left align-top",
        weekend && "bg-muted/25",
        selected && "ring-1 ring-inset ring-foreground/25",
      )}
    >
      <span className="pointer-events-none absolute inset-0 z-0 overflow-hidden">
        <DayPhotoBackdrop day={day} />
      </span>

      {/* Where a month begins: a tick down the cell's left edge, through the whole row. */}
      {first && (
        <>
          <span className="pointer-events-none absolute inset-y-0 left-0 z-10 w-px bg-foreground/30" />
          {/* On the boundary, not inside the cell — in flow it squeezed the weekday out. */}
          <span className="pointer-events-none absolute -left-[9px] top-[2px] z-20 rounded-[3px] bg-background px-[3px] py-[2px] text-[8px] font-semibold uppercase leading-none tracking-[0.06em] text-muted-foreground ring-1 ring-border">
            {MONTHS[month]}
          </span>
        </>
      )}

      <span
        className={cn(
          "relative z-10 flex items-center gap-[3px] overflow-hidden whitespace-nowrap pl-[4px] pr-[7px] pt-[4px] leading-none",
          photo && "text-white [text-shadow:0_0_3px_rgba(0,0,0,0.9),0_1px_2px_rgba(0,0,0,0.8)]",
          !photo && !today && isPast(date) && "opacity-70",
        )}
      >
        <span
          className={cn(
            "inline-flex shrink-0 items-baseline gap-[3px] leading-none",
            today && "rounded-full bg-foreground px-[4px] py-[2px] text-background",
          )}
        >
          <span
            className={cn(
              "shrink-0 text-[8px] uppercase leading-none tracking-[0.04em]",
              !today && !photo && "text-tertiary",
            )}
          >
            {WEEKDAYS[dow]}
          </span>
          <span className="shrink-0 text-[11px] font-semibold leading-none tnum">{Number(date.slice(8))}</span>
        </span>
      </span>
    </button>
  );
}

/** A date-shaped thing, drawn the way an all-day event is drawn everywhere else: a solid stadium. */
function Pill({ e, onClick }: { e: CalEvent; onClick: () => void }) {
  const { background, color } = eventColors(e.calendar_color);
  return (
    <button
      type="button"
      onClick={onClick}
      title={e.title || "(no title)"}
      style={{ background, color, height: PILL_PX }}
      className={cn(
        "pointer-events-auto flex w-full items-center gap-1 overflow-hidden rounded-full px-[5px] text-left",
        "text-[9.5px] font-medium leading-none transition-opacity hover:opacity-85",
        e.done && "line-through",
        e.rsvp === "declined" && "opacity-45 line-through",
      )}
    >
      {e.emoji && <span className="shrink-0">{e.emoji}</span>}
      <span className="truncate">{e.title || "(no title)"}</span>
    </button>
  );
}
