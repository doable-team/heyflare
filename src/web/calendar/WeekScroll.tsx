import { useCallback, useEffect, useLayoutEffect, useMemo, useRef } from "react";
import { Plus } from "lucide-react";
import type { CalEvent, CalendarDay } from "@shared/types";
import { cn } from "@/lib/utils";
import { useCalendar } from "./CalendarContext";
import { WeekTasks } from "./WeekTasks";
import { addDays, daysBetween, isPast, isToday, isWeekend, msAt, weekDays, weekStartOf } from "../lib/caldate";

/**
 * The week scroll — HEY Calendar's primary surface.
 *
 * "Week after week, not month after month." Time is a single vertical ribbon of week rows that
 * never page-flips: each row is seven equal day columns, each column a stack of one-line chips in
 * time order. Duration is deliberately not drawn. A fifteen-minute standup and a three-hour
 * workshop are the same chip, because at the scale of a week what matters is *what* is happening
 * and in *what order*, not how much of the afternoon it eats. Rows are therefore as tall as their
 * busiest day and no taller, so a quiet week costs a glance and a heavy one earns its space.
 */

/** A cell is never shorter than this, so an empty week still reads as a week and not as a rule. */
const MIN_CELL_PX = 78;
/** Used only to size the infinite-scroll trigger before a row has been measured. */
const EST_ROW_PX = 112;
/** How many days each end-of-scroll top-up asks for. Four weeks keeps the query count low. */
const EXTEND_DAYS = 28;

const MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];
const MONTHS_LONG = [
  "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE",
  "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER",
];
const WEEKDAYS = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];

/** The near-black a calendar falls back to when it has no colour of its own. */
const DEFAULT_CHIP = "#1f1f1f";

/**
 * The fill and the text colour for one event chip.
 *
 * Chips are solid blocks of the calendar's own colour, so the foreground has to be chosen per
 * colour or a pale yellow calendar becomes unreadable. Relative luminance (WCAG 2.x) gives the
 * perceptual lightness of the fill; we then take whichever of near-black or near-white contrasts
 * better against it. Everything else in this view stays monochrome — colour is the user's data,
 * not our decoration.
 */
export function chipColors(hex: string | null | undefined): { background: string; color: string } {
  const background = normalizeHex(hex) ?? DEFAULT_CHIP;
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(background.slice(i, i + 2), 16) / 255);
  const lin = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  const L = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
  // Contrast ratio against white is (1.05)/(L+0.05); against black it is (L+0.05)/0.05.
  const onWhite = 1.05 / (L + 0.05);
  const onBlack = (L + 0.05) / 0.05;
  return { background, color: onWhite >= onBlack ? "#fbfbfa" : "#131313" };
}

/** `#abc` and `#aabbcc` both come back as a lowercase six-digit hex; anything else is rejected. */
function normalizeHex(hex: string | null | undefined): string | null {
  if (!hex) return null;
  const s = hex.trim().toLowerCase();
  if (/^#[0-9a-f]{6}$/.test(s)) return s;
  if (/^#[0-9a-f]{3}$/.test(s)) return `#${s[1]}${s[1]}${s[2]}${s[2]}${s[3]}${s[3]}`;
  return null;
}

export function WeekScroll() {
  const { settings, cursor, setCursor, today, from, to, extend, range, eventsOn, openEvent, createEvent } = useCalendar();

  // The loaded window, snapped outwards to whole weeks so every row always has seven columns.
  const weekStarts = useMemo(() => {
    const first = weekStartOf(from, settings.week_start);
    const last = weekStartOf(to, settings.week_start);
    const span = daysBetween(first, last);
    if (!Number.isFinite(span) || span < 0) return [] as string[];
    const n = Math.min(Math.floor(span / 7), 520) + 1;
    return Array.from({ length: n }, (_, i) => addDays(first, i * 7));
  }, [from, to, settings.week_start]);

  // Day labels and cover art, keyed by date for a per-cell lookup.
  const dayMeta = useMemo(() => {
    const m = new Map<string, CalendarDay>();
    for (const d of range?.days ?? []) m.set(d.date, d);
    return m;
  }, [range]);

  const scroller = useRef<HTMLDivElement>(null);
  const rows = useRef(new Map<string, HTMLDivElement>());
  const prevFrom = useRef(from);
  const prevTo = useRef(to);
  /** scrollHeight as it stood at the end of the previous paint — the "before" of the anchor maths. */
  const lastHeight = useRef(0);
  /** True between asking for more days and those days arriving, so one scroll can't ask twice. */
  const growing = useRef(false);
  const aligned = useRef(false);

  /**
   * Scroll anchoring.
   *
   * Extending the window at the *head* prepends whole week rows above the viewport. The browser
   * keeps scrollTop where it was, so all that content appearing above the fold yanks the page
   * downwards by exactly the height of what was inserted. There is no cheap way to know that
   * height in advance — rows are content-sized — so we measure it: remember scrollHeight at the
   * end of every paint, and when `from` moves backwards add (new scrollHeight − old scrollHeight)
   * to scrollTop. Doing it in a layout effect means the correction lands in the same frame as the
   * insertion, before the browser paints, so the viewport never visibly moves.
   *
   * Growth at the tail needs no correction: content below the fold does not shift what is above it.
   *
   * This effect runs after *every* render, deliberately — that is what keeps `lastHeight` honest
   * when a row grows for another reason (events arriving from the query, an image decoding).
   */
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const height = el.scrollHeight;
    if (prevFrom.current !== from) {
      const added = height - lastHeight.current;
      if (added > 0) el.scrollTop += added;
      prevFrom.current = from;
      growing.current = false;
    }
    if (prevTo.current !== to) {
      prevTo.current = to;
      growing.current = false;
    }
    lastHeight.current = height;
  });

  /** Distance from a week row's top to the top of the scroll content. */
  const offsetOf = useCallback((weekStart: string): number | null => {
    const el = scroller.current;
    const row = rows.current.get(weekStart);
    if (!el || !row) return null;
    return row.getBoundingClientRect().top - el.getBoundingClientRect().top + el.scrollTop;
  }, []);

  /**
   * Keep the cursor's week in view. On mount (and whenever the loaded rows are rebuilt) the week
   * is parked near the top; afterwards it only moves when the cursor has actually gone off screen,
   * gliding for somewhere nearby and cutting for somewhere far away.
   */
  useEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const ws = weekStartOf(cursor, settings.week_start);
    const top = offsetOf(ws);
    if (top == null) return;
    const first = !aligned.current;
    if (!first) {
      const row = rows.current.get(ws);
      const h = row?.offsetHeight ?? EST_ROW_PX;
      // Already comfortably inside the viewport: leave the scroll position alone.
      if (top >= el.scrollTop + 4 && top + h <= el.scrollTop + el.clientHeight - 4) return;
    }
    const target = Math.max(0, top - 8);
    el.scrollTo({ left: 0, top: target, behavior: first || Math.abs(target - el.scrollTop) > el.clientHeight * 2 ? "auto" : "smooth" });
    // Don't lock the alignment in until the events have actually landed: until then the rows are
    // all at their minimum height, so the offset we just measured is not the one that will hold.
    if (range) aligned.current = true;
  }, [cursor, settings.week_start, weekStarts, range, offsetOf]);

  /** Coming within about two rows of either end pulls in another four weeks. */
  const onScroll = () => {
    const el = scroller.current;
    if (!el || growing.current || weekStarts.length === 0) return;
    const rowPx = rows.current.get(weekStarts[0])?.offsetHeight || EST_ROW_PX;
    const pad = rowPx * 2;
    if (el.scrollTop < pad) {
      growing.current = true;
      extend("start", EXTEND_DAYS);
    } else if (el.scrollTop + el.clientHeight > el.scrollHeight - pad) {
      growing.current = true;
      extend("end", EXTEND_DAYS);
    }
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <WeekTasks />
      <div
        ref={scroller}
        onScroll={onScroll}
        className="min-h-0 flex-1 overflow-y-auto overflow-x-hidden rounded-md border border-border bg-background"
      >
        <div>
          {weekStarts.map((ws) => (
            <WeekRow
              key={ws}
              weekStart={ws}
              weekStartDay={settings.week_start}
              cursor={cursor}
              today={today}
              dayMeta={dayMeta}
              eventsOn={eventsOn}
              onPick={setCursor}
              onOpen={openEvent}
              onCreate={createEvent}
              register={(el) => {
                if (el) rows.current.set(ws, el);
                else rows.current.delete(ws);
              }}
            />
          ))}
        </div>
      </div>
      <p className="pt-1.5 text-[11px] text-tertiary">
        {today === cursor ? "Today" : cursor} · scroll for the weeks either side, ← → to walk the days, n for a new event
      </p>
    </div>
  );
}

type CreateFn = (prefill: Partial<CalEvent> & { starts_at: number; ends_at: number; all_day?: boolean }) => void;

/**
 * One week: an optional strip of day names above, then seven equal columns.
 *
 * The row has no fixed height. Each cell asks for `MIN_CELL_PX` and then grows with its chips;
 * CSS grid stretches every cell in the row to the tallest of them, which is exactly the behaviour
 * we want — the week is as tall as its busiest day.
 */
function WeekRow({
  weekStart,
  weekStartDay,
  cursor,
  today,
  dayMeta,
  eventsOn,
  onPick,
  onOpen,
  onCreate,
  register,
}: {
  weekStart: string;
  weekStartDay: number;
  cursor: string;
  today: string;
  dayMeta: Map<string, CalendarDay>;
  eventsOn: (date: string) => { allDay: CalEvent[]; timed: CalEvent[] };
  onPick: (d: string) => void;
  onOpen: (e: CalEvent) => void;
  onCreate: CreateFn;
  register: (el: HTMLDivElement | null) => void;
}) {
  const days = useMemo(() => weekDays(weekStart, weekStartDay), [weekStart, weekStartDay]);
  const labels = days.map((d) => dayMeta.get(d)?.label ?? "");
  // The label strip only exists when something is named — an empty week gets no dead band.
  const hasLabels = labels.some(Boolean);
  // A month begins inside this week: reserve the marker line in *every* cell of the row so the
  // "MON 19" header lines stay on one baseline across all seven columns.
  const hasMonthMark = days.some((d) => d.endsWith("-01"));

  return (
    <div ref={register} className="border-b border-border last:border-b-0">
      {hasLabels && (
        <div className="grid grid-cols-7 pt-1">
          {days.map((d, i) => (
            <div key={d} className="min-w-0 px-1.5">
              <div className="truncate text-[10px] leading-[13px] text-tertiary" title={labels[i] || undefined}>
                {labels[i]}
              </div>
            </div>
          ))}
        </div>
      )}
      <div className="grid grid-cols-7">
        {days.map((d) => (
          <DayCell
            key={d}
            date={d}
            cursor={cursor}
            today={today}
            day={dayMeta.get(d)}
            events={eventsOn(d)}
            showMonthMark={hasMonthMark}
            onPick={onPick}
            onOpen={onOpen}
            onCreate={onCreate}
          />
        ))}
      </div>
    </div>
  );
}

/** `MON 19`, then everything that happens — chips in time order, with the cover art among them. */
function DayCell({
  date,
  cursor,
  today,
  day,
  events,
  showMonthMark,
  onPick,
  onOpen,
  onCreate,
}: {
  date: string;
  cursor: string;
  today: string;
  day: CalendarDay | undefined;
  events: { allDay: CalEvent[]; timed: CalEvent[] };
  showMonthMark: boolean;
  onPick: (d: string) => void;
  onOpen: (e: CalEvent) => void;
  onCreate: CreateFn;
}) {
  const d = new Date(`${date}T00:00:00`);
  const isFirst = d.getDate() === 1;
  const now = isToday(date);
  const past = isPast(date) && !now;

  // All-day banners lead — they frame the day — then the timed events in start order.
  const chips = useMemo(
    () => [...events.allDay, ...[...events.timed].sort((a, b) => a.starts_at - b.starts_at || a.title.localeCompare(b.title))],
    [events],
  );

  const create = () => onCreate({ starts_at: msAt(date, 9 * 60), ends_at: msAt(date, 10 * 60) });

  return (
    <div
      onClick={() => onPick(date)}
      onDoubleClick={create}
      className={cn(
        "group/cell relative min-w-0 border-l border-border px-1.5 pb-1.5 pt-1 first:border-l-0",
        isFirst && "border-l-foreground/25",
        isWeekend(date) && "bg-muted/30",
        past && "opacity-60",
        cursor === date && "outline outline-1 -outline-offset-1 outline-foreground/35",
      )}
      style={{ minHeight: MIN_CELL_PX }}
      title={date}
    >
      {showMonthMark && (
        <div className="h-[13px] text-[9px] font-semibold uppercase leading-[13px] tracking-[0.1em] text-foreground/70">
          {isFirst ? MONTHS_LONG[d.getMonth()] : ""}
        </div>
      )}

      <div className="flex items-center gap-1">
        <span className="text-[9.5px] uppercase leading-none tracking-[0.09em] text-tertiary">{WEEKDAYS[d.getDay()]}</span>
        {now ? (
          <span className="rounded-full bg-foreground px-[5px] py-[2px] text-[11px] font-semibold leading-none tnum text-background">
            {d.getDate()}
          </span>
        ) : (
          <span className={cn("text-[11px] leading-none tnum", past ? "text-tertiary" : "text-muted-foreground")}>{d.getDate()}</span>
        )}
        {isFirst && !showMonthMark && (
          <span className="text-[9px] uppercase leading-none tracking-[0.09em] text-tertiary">{MONTHS[d.getMonth()]}</span>
        )}
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            create();
          }}
          className="ml-auto shrink-0 text-tertiary opacity-0 transition-opacity hover:text-foreground group-hover/cell:opacity-100"
          aria-label={`New event on ${date}`}
        >
          <Plus size={11} />
        </button>
      </div>

      <div className="mt-1 flex flex-col gap-[2px]">
        {day?.cover_url && (
          <img
            src={day.cover_url}
            alt=""
            loading="lazy"
            className="h-[34px] w-full rounded-[3px] bg-muted object-cover"
          />
        )}
        {chips.map((e) => (
          <Chip key={e.id} e={e} onClick={() => onOpen(e)} />
        ))}
      </div>
    </div>
  );
}

/**
 * One event, one line, full width, filled in its calendar's colour. Long titles are cut with an
 * ellipsis and not apologised for: at a week's scale the chip is a reminder, not the record.
 */
function Chip({ e, onClick }: { e: CalEvent; onClick: () => void }) {
  const { background, color } = chipColors(e.calendar_color);
  const declined = e.rsvp === "declined";
  return (
    <button
      type="button"
      onClick={(ev) => {
        ev.stopPropagation();
        onClick();
      }}
      title={e.title || "(no title)"}
      style={{ background, color }}
      className={cn(
        "block h-[16px] w-full overflow-hidden text-ellipsis whitespace-nowrap rounded-[3px] px-1 text-left",
        "text-[10.5px] font-medium leading-[16px] transition-opacity hover:opacity-85",
        e.all_day && "italic",
        e.done && "line-through",
        declined && "opacity-45 line-through",
      )}
    >
      {e.emoji ? `${e.emoji} ` : ""}
      {e.title || "(no title)"}
    </button>
  );
}
