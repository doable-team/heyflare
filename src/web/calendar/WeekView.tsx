import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { CalendarDay, Habit } from "@shared/types";
import { cn } from "@/lib/utils";
import { useCalendar } from "./CalendarContext";
import { AllDayPill, EventBlock } from "./EventBlock";
import { WeekTasks } from "./WeekTasks";
import { eventColors } from "./colors";
import { DayPhotoBackdrop, DayPhotoButton, hasPhoto } from "./DayPhoto";
import { heyTime, snap } from "./scale";
import { addDays, daysBetween, isToday, layoutColumns, startOfDayMs, weekStartOf } from "../lib/caldate";
import { useEventMutations, useHabitMutations } from "../api";

/**
 * The week — HEY Calendar's desktop home, rebuilt from the real thing.
 *
 * It is not one week. It is a **vertical stack of week rows** that runs on forever in both
 * directions: you scroll through the year the way you scroll through a document, and the week you
 * are currently pointed at is the one wearing a thin rounded frame.
 *
 * Each row is a self-contained week. Top to bottom:
 *
 *   · a habit rail — a hairline per day column with that day's habit buttons straddling it;
 *   · the day headers, right-aligned, small, today reversed out of a filled blob;
 *   · the timed body: seven columns, the **whole 24 hours, dead linear**, about 19px to the hour;
 *   · "SOMETIME THIS WEEK:", this week's flexible tasks, always present even when empty.
 *
 * Two things this view deliberately does *not* do, both of which belong to the day view:
 *
 *  1. **No night compression.** 1AM sits near the top of the column and 10:30PM near the bottom,
 *     on one unbroken ruler. A week is for seeing shape across days, and a kinked axis would make
 *     Tuesday's evening a different size from Wednesday's.
 *
 *  2. **No free-time bands and no duration stamps.** The ground is plain. There is also no hour
 *     gutter and there are no hour rules — nothing in a column but events.
 */

const WEEKDAYS = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];
const MONTHS_LONG = [
  "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE",
  "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER",
];

const DAY_MS = 24 * 60 * 60 * 1000;

/** The habit rail, and the header above the track. */
const HABITS_PX = 22;
const HEADER_PX = 34;
/**
 * The timed body. All 24 hours live in here at one scale — 460/24 ≈ 19.2px per hour, measured off
 * HEY's own week view — so no row ever scrolls inside itself and every row is exactly as tall as
 * every other, which is what makes the stack cheap to scroll and to anchor.
 */
const BODY_PX = 460;
const PX_PER_MS = BODY_PX / DAY_MS;
/** The "sometime this week" strip along the floor of the row. */
const TASKS_PX = 28;
/** Air between one week and the next. */
const ROW_GAP_PX = 12;

const ROW_PX = HABITS_PX + HEADER_PX + BODY_PX + TASKS_PX;
const ROW_STRIDE_PX = ROW_PX + ROW_GAP_PX;

/** How many all-day pills a column shows before it starts counting them instead. */
const ALLDAY_MAX = 3;

export function WeekView() {
  const { settings, cursor, from, to, extend, range, revealAt, reportVisibleMonth } = useCalendar();

  // Every week the loaded window touches, oldest first. The window only ever grows, so this list
  // only ever gains rows — at the head or the tail — which is exactly what the anchor below assumes.
  const weeks = useMemo(() => {
    const first = weekStartOf(from, settings.week_start);
    const last = weekStartOf(to, settings.week_start);
    const n = Math.min(Math.max(Math.floor(daysBetween(first, last) / 7) + 1, 1), 520);
    return Array.from({ length: n }, (_, i) => addDays(first, i * 7));
  }, [from, to, settings.week_start]);

  const dayMeta = useMemo(() => {
    const m = new Map<string, CalendarDay>();
    for (const d of range?.days ?? []) m.set(d.date, d);
    return m;
  }, [range]);
  const habits = useMemo(() => (range?.habits ?? []).filter((h) => !h.archived), [range]);

  const scroller = useRef<HTMLDivElement>(null);
  const rows = useRef(new Map<string, HTMLDivElement>());
  const registerRow = useCallback((week: string, el: HTMLDivElement | null) => {
    if (el) rows.current.set(week, el);
    else rows.current.delete(week);
  }, []);

  /**
   * Growing at the head prepends rows above the viewport, which would yank everything you were
   * looking at downwards. Measure the scroll height either side of the change and put the
   * difference straight back into `scrollTop`, in the same frame, before paint.
   */
  const lastHeight = useRef(0);
  const lastHead = useRef(weeks[0]);
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el) return;
    if (lastHead.current !== weeks[0]) {
      el.scrollTop += el.scrollHeight - lastHeight.current;
      lastHead.current = weeks[0];
    }
    lastHeight.current = el.scrollHeight;
  });

  // Land on the cursor's week, and follow it whenever it leaves the screen.
  const cursorWeek = weekStartOf(cursor, settings.week_start);
  const landed = useRef(false);
  useLayoutEffect(() => {
    const el = scroller.current;
    const row = rows.current.get(cursorWeek);
    if (!el || !row) return;
    const target = Math.max(0, row.offsetTop - (el.clientHeight - row.offsetHeight) / 2);
    if (!landed.current) {
      landed.current = true;
      el.scrollTop = target;
      return;
    }
    // Already fully in view: leave the scroll where the reader put it.
    const top = row.offsetTop - el.scrollTop;
    if (top >= 0 && top + row.offsetHeight <= el.clientHeight) return;
    // A jump of more than a screen and a half is a different place, not a nudge — don't animate it.
    const far = Math.abs(target - el.scrollTop) > el.clientHeight * 1.5;
    el.scrollTo({ top: target, behavior: far ? "auto" : "smooth" });
    // Only the cursor moving may move the scroll. Growing the window must not, or scrolling far
    // enough to trigger a load would snap you straight back to the week you started from.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cursorWeek]);

  // "Today", and the toolbar's arrows, ask to be brought on screen even when the cursor did not
  // change — you can scroll a long way without moving it.
  useLayoutEffect(() => {
    const el = scroller.current;
    const row = rows.current.get(weekStartOf(revealAt.date, settings.week_start));
    if (!el || !row || !landed.current) return;
    const target = Math.max(0, row.offsetTop - (el.clientHeight - row.offsetHeight) / 2);
    el.scrollTo({ top: target, behavior: Math.abs(target - el.scrollTop) > el.clientHeight * 1.5 ? "auto" : "smooth" });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [revealAt.nonce]);

  // Within a row of either end, load another four weeks. The guards are keyed on the window itself,
  // so a burst of scroll events can't fire the same extension twice before React catches up.
  const asked = useRef({ start: "", end: "" });
  const onScroll = useCallback(() => {
    const el = scroller.current;
    if (!el) return;
    if (el.scrollTop < ROW_STRIDE_PX && asked.current.start !== from) {
      asked.current.start = from;
      extend("start", 28);
    }
    if (el.scrollHeight - el.scrollTop - el.clientHeight < ROW_STRIDE_PX && asked.current.end !== to) {
      asked.current.end = to;
      extend("end", 28);
    }
    // Tell the toolbar which month is actually on screen. The row nearest the top of the viewport
    // wins, and its middle day names the month, so a week straddling a boundary reads sensibly.
    let best: { week: string; d: number } | null = null;
    for (const [week, row] of rows.current) {
      const d = Math.abs(row.offsetTop - el.scrollTop);
      if (!best || d < best.d) best = { week, d };
    }
    if (best) reportVisibleMonth(addDays(best.week, 3).slice(0, 7));
  }, [from, to, extend, reportVisibleMonth]);

  return (
    <div ref={scroller} onScroll={onScroll} className="min-h-0 flex-1 overflow-y-auto overflow-x-hidden">
      <div className="relative px-1 py-2">
        {weeks.map((w) => (
          <WeekRow
            key={w}
            weekStart={w}
            current={w === cursorWeek}
            dayMeta={dayMeta}
            habits={habits}
            register={registerRow}
          />
        ))}
      </div>
    </div>
  );
}

/**
 * One week: the month standing on its side at the left edge, seven columns, and the week's loose
 * tasks along the floor. The row the cursor is in gets a rounded outline that lifts it out of the
 * stack; the others carry the same border in nothing, so no row is ever a pixel taller.
 */
function WeekRow({
  weekStart,
  current,
  dayMeta,
  habits,
  register,
}: {
  weekStart: string;
  current: boolean;
  dayMeta: Map<string, CalendarDay>;
  habits: Habit[];
  register: (week: string, el: HTMLDivElement | null) => void;
}) {
  const days = useMemo(() => Array.from({ length: 7 }, (_, i) => addDays(weekStart, i)), [weekStart]);

  // A month that turns inside the row is announced on the divider it turns at, with its year.
  const turns = useMemo(
    () =>
      days
        .map((d, i) => ({ i, month: Number(d.slice(5, 7)) - 1, year: d.slice(0, 4) }))
        .filter((d, i) => i > 0 && d.month !== Number(days[i - 1].slice(5, 7)) - 1),
    [days],
  );

  return (
    <div
      ref={(el) => register(weekStart, el)}
      style={{ height: ROW_PX, marginBottom: ROW_GAP_PX }}
      className={cn("relative flex flex-col rounded-lg border", current ? "border-border" : "border-transparent")}
    >
      <div className="flex min-h-0 flex-1">
        {/* The month, once, on its side — the week's place in the year, taking no width from the days. */}
        <div className="relative flex w-6 shrink-0 items-center justify-center overflow-hidden">
          <span
            className="whitespace-nowrap text-[15px] uppercase tracking-[0.06em] text-foreground/25"
            style={{ writingMode: "vertical-rl" }}
          >
            {MONTHS_LONG[Number(weekStart.slice(5, 7)) - 1]}
          </span>
        </div>

        <div className="relative grid min-w-0 flex-1 grid-cols-[repeat(7,minmax(0,1fr))]">
          {days.map((d, i) => (
            <DayColumn key={d} date={d} first={i === 0} day={dayMeta.get(d)} habits={habits} />
          ))}

          {turns.map((t) => (
            <span
              key={t.i}
              // Behind the events, not over them: it is a watermark telling you where the month
              // turns, and it must never sit on top of something you are trying to read.
              className="pointer-events-none absolute z-0 max-h-[190px] overflow-hidden whitespace-nowrap text-[12px] uppercase tracking-[0.08em] text-foreground/20"
              style={{
                left: `${(t.i / 7) * 100}%`,
                top: HABITS_PX + HEADER_PX + 8,
                writingMode: "vertical-rl",
                transform: "translateX(-50%)",
              }}
            >
              {MONTHS_LONG[t.month]} {t.year}
            </span>
          ))}
        </div>
      </div>

      <div className="shrink-0" style={{ height: TASKS_PX }}>
        <WeekTasks weekStart={weekStart} />
      </div>
    </div>
  );
}

/** One day: habits on their rail, the header, then the track. */
function DayColumn({ date, first, day, habits }: { date: string; first: boolean; day: CalendarDay | undefined; habits: Habit[] }) {
  return (
    <div className="group/day relative flex min-w-0 flex-col">
      <HabitRail date={date} habits={habits} />
      <DayHeader date={date} photo={hasPhoto(day)} />
      <Track date={date} first={first} day={day} />
      {/* HEY's entry point: hover the day's top-left corner and a photo icon appears over it. */}
      <div className="absolute left-1.5 z-30" style={{ top: HABITS_PX + HEADER_PX + 6 }}>
        <DayPhotoButton
          date={date}
          day={day}
          className={cn(
            "opacity-0 transition-opacity focus-visible:opacity-100 group-hover/day:opacity-100",
            hasPhoto(day) && "opacity-80",
          )}
        />
      </div>
    </div>
  );
}

/**
 * The habits, as small circles straddling a hairline that runs the width of the column — the line
 * passes behind them, so they read as buttons pinned to the week rather than another row of
 * content inside it. Outlined when the habit is undone, filled in its own colour when it is done.
 */
function HabitRail({ date, habits }: { date: string; habits: Habit[] }) {
  const { toggle } = useHabitMutations();
  const dow = new Date(`${date}T00:00:00`).getDay();
  const mine = habits.filter((h) => h.days.length === 0 || h.days.includes(dow));

  return (
    <div className="relative flex shrink-0 items-center justify-center gap-1" style={{ height: HABITS_PX }}>
      <span className="pointer-events-none absolute inset-x-1.5 top-1/2 h-px -translate-y-1/2 bg-border" />
      {mine.map((h) => {
        const done = h.completions?.includes(date) ?? false;
        const { background, color } = eventColors(h.color);
        return (
          <button
            key={h.id}
            type="button"
            title={`${h.name}${done ? " · done" : ""}`}
            aria-pressed={done}
            onClick={(ev) => {
              ev.stopPropagation();
              toggle.mutate({ id: h.id, date });
            }}
            style={done ? { background, color, borderColor: background } : undefined}
            className={cn(
              "relative z-10 inline-flex size-[19px] shrink-0 items-center justify-center rounded-full border text-[9.5px] leading-none transition-colors",
              done ? "border-transparent" : "border-border bg-background text-tertiary hover:border-foreground/40 hover:text-foreground",
            )}
          >
            {h.icon || h.name.slice(0, 1).toUpperCase()}
          </button>
        );
      })}
    </div>
  );
}

/**
 * `SUN 30`, right-aligned and deliberately small — on HEY the header is barely bigger than the
 * event text, because the header is not the point of the view. Today is reversed out of a solid
 * blob; HEY uses its orange, and this app being monochrome, the foreground colour stands in.
 */
function DayHeader({ date, photo }: { date: string; photo?: boolean }) {
  const d = new Date(`${date}T00:00:00`);
  const today = isToday(date);
  return (
    <div className="relative z-20 flex shrink-0 items-center justify-end px-1.5" style={{ height: HEADER_PX }}>
      <span
        className={cn(
          "inline-flex items-baseline gap-1",
          today && "rounded-full bg-foreground px-2 py-[3px] text-background",
          // Over a photo the number goes plain white — no shadow, no halo — as HEY does.
          !today && photo && "text-white [text-shadow:0_0_3px_rgba(0,0,0,0.9),0_1px_2px_rgba(0,0,0,0.8)]",
        )}
      >
        <span className={cn("text-[11px] uppercase leading-none tracking-[0.1em]", !today && !photo && "text-tertiary")}>{WEEKDAYS[d.getDay()]}</span>
        <span className="text-[16px] font-bold leading-none tnum">{d.getDate()}</span>
      </span>
    </div>
  );
}

/**
 * The body of a column: the day's photo, its events, its all-day pills on the floor, and — on
 * today only — a dotted line where the hour hand is.
 *
 * The ruler is linear and complete: midnight at the top, midnight at the bottom, 24 hours in
 * between at one rate. No hour rules, no labels, no bands. The boxes *are* the day.
 */
function Track({ date, first, day }: { date: string; first: boolean; day: CalendarDay | undefined }) {
  const { settings, cursor, setCursor, eventsOn, openEvent, createEvent } = useCalendar();
  const { setDone } = useEventMutations();
  const { timed, allDay } = eventsOn(date);
  const today = isToday(date);

  const dayStart = useMemo(() => startOfDayMs(date), [date]);
  const posOf = useCallback((ms: number) => Math.max(0, Math.min(BODY_PX, (ms - dayStart) * PX_PER_MS)), [dayStart]);

  const layout = useMemo(() => layoutColumns(timed), [timed]);

  const box = useRef<HTMLDivElement>(null);
  const [drag, setDrag] = useState<{ from: number; to: number } | null>(null);
  const msAtY = useCallback(
    (clientY: number) => {
      const r = box.current?.getBoundingClientRect();
      if (!r) return dayStart;
      const mins = (Math.max(0, Math.min(BODY_PX, clientY - r.top)) / PX_PER_MS) / 60_000;
      return dayStart + snap(Math.round(mins)) * 60_000;
    },
    [dayStart],
  );

  // The now marker ticks itself; only today's column has one.
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!today) return;
    const t = window.setInterval(() => setNow(Date.now()), 60_000);
    return () => window.clearInterval(t);
  }, [today]);

  const extra = allDay.length - ALLDAY_MAX;

  return (
    <div
      ref={box}
      style={{ height: BODY_PX }}
      className={cn(
        "relative min-w-0 shrink-0 select-none overflow-hidden border-border",
        !first && "border-l",
        cursor === date && "bg-muted/25",
      )}
      onMouseDown={(e) => {
        if (e.button !== 0) return;
        setCursor(date);
        if ((e.target as HTMLElement).closest("button")) return;
        const from = msAtY(e.clientY);
        setDrag({ from, to: from + 30 * 60_000 });
      }}
      onMouseMove={(e) => drag && setDrag({ from: drag.from, to: msAtY(e.clientY) })}
      onMouseLeave={() => setDrag(null)}
      onMouseUp={() => {
        if (!drag) return;
        const a = Math.min(drag.from, drag.to);
        const b = Math.max(drag.from, drag.to);
        setDrag(null);
        createEvent({ starts_at: a, ends_at: b === a ? a + 30 * 60_000 : b });
      }}
    >
      {/* Not a thumbnail, and not dimmed: the photo fills the column at full strength. Legibility
          comes from the events on top of it, which stay opaque and gain a white keyline. */}
      <DayPhotoBackdrop day={day} className="z-0" />

      {timed.map((e, i) => {
        const top = posOf(Math.max(e.starts_at, dayStart));
        const bottom = posOf(Math.min(e.ends_at, dayStart + DAY_MS));
        return (
          <EventBlock
            key={e.id}
            onPhoto={hasPhoto(day)}
            e={e}
            top={top}
            height={bottom - top}
            column={layout[i].column}
            columns={layout[i].columns}
            format={settings.time_format}
            onClick={() => openEvent(e)}
            onToggleDone={() => setDone.mutate({ id: e.id, done: !e.done, date })}
          />
        );
      })}

      {drag && (
        <div
          className="pointer-events-none absolute inset-x-0.5 z-30 rounded-[3px] border border-dashed border-foreground/60 bg-foreground/5"
          style={{
            top: posOf(Math.min(drag.from, drag.to)),
            height: Math.max(posOf(Math.max(drag.from, drag.to)) - posOf(Math.min(drag.from, drag.to)), 8),
          }}
        />
      )}

      {/* All-day things sit on the floor of the day — the ground it stands on, not a banner. */}
      {allDay.length > 0 && (
        <div className="pointer-events-auto absolute inset-x-1 bottom-1 z-30 flex flex-col gap-[2px]">
          {allDay.slice(0, ALLDAY_MAX).map((e) => (
            <AllDayPill key={e.id} e={e} onClick={() => openEvent(e)} />
          ))}
          {extra > 0 && <span className="px-2 text-[10px] leading-none text-tertiary">+{extra} more</span>}
        </div>
      )}

      {today && now >= dayStart && now < dayStart + DAY_MS && (
        <div className="pointer-events-none absolute inset-x-0 z-40" style={{ top: posOf(now) }}>
          <div className="border-t border-dotted border-red-500" />
          <span className="absolute left-0 -top-[7px] bg-background/80 pr-1 text-[9px] leading-none tnum text-red-500">
            {heyTime(now, settings.time_format)}
          </span>
        </div>
      )}
    </div>
  );
}
