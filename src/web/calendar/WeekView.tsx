import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { CalEvent, CalendarDay, Habit } from "@shared/types";
import { cn } from "@/lib/utils";
import { useCalendar } from "./CalendarContext";
import { AllDayPill, EventBlock } from "./EventBlock";
import { WeekTasks } from "./WeekTasks";
import { eventColors } from "./colors";
import { freeGaps, makeRibbon, snap, spanLabel, type Ribbon, type RibbonRun } from "./scale";
import { isToday, layoutColumns, startOfDayMs, weekDays } from "../lib/caldate";
import { useCalendarDayMutation, useEventMutations, useHabitMutations } from "../api";

/**
 * The week — HEY Calendar's desktop home, rebuilt column for column.
 *
 * Seven columns, one week, and no more: "the calendar grid in the Week view caps at 7 columns."
 * The ‹ › in the toolbar move the cursor a week at a time; nothing here scrolls to another week,
 * because a week you can see all of is the point.
 *
 * Two things follow from that, and they are what make this not a spreadsheet:
 *
 *  1. **There is no hour gutter and there are no hour rules.** A column's interior holds event
 *     boxes and free-time bands and nothing else. You read the shape of a day, not its coordinates.
 *
 *  2. **Free time is drawn.** Jason Fried: "Your day begins with 24 hours of free time, and you
 *     have to carve time out of your free time to add an event… your day is actually full." So the
 *     gaps between meetings are rendered at exactly the same scale as the meetings and stamped
 *     with their length — 2hrs, 45min — rather than left as background.
 *
 * The night hours are the single break in the scale: `makeRibbon` squeezes them into a fixed block,
 * drawn here as a torn-edged patch of dark sky. Click it to open the night out at full scale.
 */

const WEEKDAYS = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];
const MONTHS_LONG = [
  "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE",
  "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER",
];

const DAY_MS = 24 * 60 * 60 * 1000;

/** How far the fitted scale may be squeezed or stretched. Outside this a week stops reading. */
const MIN_PPH = 18;
const MAX_PPH = 46;

/** Fixed furniture above the track, so all seven tracks start on the same line. */
const HABITS_PX = 18;
const HEADER_PX = 30;
const LABEL_PX = 16;
/** One all-day pill plus the gap under it. */
const ALLDAY_PX = 20;

/** A free-time band shorter than this has no room for its stamp. */
const STAMP_MIN_PX = 26;

export function WeekView() {
  const { settings, cursor, range } = useCalendar();
  const days = useMemo(() => weekDays(cursor, settings.week_start), [cursor, settings.week_start]);

  const dayMeta = useMemo(() => {
    const m = new Map<string, CalendarDay>();
    for (const d of range?.days ?? []) m.set(d.date, d);
    return m;
  }, [range]);
  const habits = useMemo(() => (range?.habits ?? []).filter((h) => !h.archived), [range]);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <WeekGrid days={days} dayMeta={dayMeta} habits={habits} />
      <WeekTasks />
    </div>
  );
}

/**
 * The grid proper: the month rail, then seven equal columns divided by hairlines.
 *
 * Every column reserves the same height for its furniture — habits, header, label, the all-day
 * shelf at the floor — so the timed tracks are one band across the whole week and a single
 * `pxPerHour` makes 3pm on Monday sit level with 3pm on Friday.
 */
function WeekGrid({ days, dayMeta, habits }: { days: string[]; dayMeta: Map<string, CalendarDay>; habits: Habit[] }) {
  const { settings, nightOpen, eventsOn } = useCalendar();

  // The all-day shelf is as deep as the busiest day's, in every column, or the tracks fall out of step.
  const allDayPx = useMemo(() => {
    const most = days.reduce((n, d) => Math.max(n, eventsOn(d).allDay.length), 0);
    return most === 0 ? 0 : most * ALLDAY_PX + 4;
  }, [days, eventsOn]);

  // The track measures itself and the scale is solved from the height it turns out to have. The ref
  // is a callback rather than an object because the first column is remounted whenever the week
  // turns, and the observer has to follow the live node rather than sit on a detached one.
  const [trackEl, setTrackEl] = useState<HTMLDivElement | null>(null);
  const measure = useCallback((el: HTMLDivElement | null) => setTrackEl(el), []);
  const [trackPx, setTrackPx] = useState(0);
  useLayoutEffect(() => {
    if (!trackEl) return;
    setTrackPx(trackEl.clientHeight);
    if (typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(() => setTrackPx(trackEl.clientHeight));
    ro.observe(trackEl);
    return () => ro.disconnect();
  }, [trackEl]);

  const collapseNight = settings.collapse_night && !nightOpen;

  /**
   * Fit the scale to the height we were given.
   *
   * The ribbon's length is (collapsed night px) + (waking hours × pxPerHour), and the night part is
   * a constant. Two probe ribbons recover both terms without hard-coding the night geometry: at
   * 0 px/hour the length *is* the night block, and at 1 px/hour the extra is the waking hours.
   */
  const pxPerHour = useMemo(() => {
    const from = startOfDayMs(days[0] ?? "");
    const base = { from, to: from + DAY_MS, nightStart: settings.night_start, nightEnd: settings.night_end, collapseNight };
    const nightPx = makeRibbon({ ...base, pxPerHour: 0 }).length;
    const wakingHours = Math.max(1, makeRibbon({ ...base, pxPerHour: 1 }).length - nightPx);
    if (!trackPx) return 30;
    return Math.max(MIN_PPH, Math.min(MAX_PPH, (trackPx - nightPx) / wakingHours));
  }, [days, settings.night_start, settings.night_end, collapseNight, trackPx]);

  return (
    <div className="flex min-h-0 flex-1 overflow-hidden rounded-md border border-border bg-background">
      <MonthRail days={days} />
      {/* The 8px of air is where the top halves of the habit badges live. */}
      <div className="grid min-w-0 flex-1 grid-cols-[repeat(7,minmax(0,1fr))] pt-2">
        {days.map((d, i) => (
          <DayColumn
            key={d}
            date={d}
            day={dayMeta.get(d)}
            habits={habits}
            pxPerHour={pxPerHour}
            allDayPx={allDayPx}
            measure={i === 0 ? measure : undefined}
          />
        ))}
      </div>
    </div>
  );
}

/**
 * The left rail. Its only content is the month, set on its side in light grey — the week's place in
 * the year, stated once, taking no width from the days. A week that straddles two months prints
 * both, the rail split in proportion to how many days each month owns.
 */
function MonthRail({ days }: { days: string[] }) {
  const groups = useMemo(() => {
    const out: { month: number; days: number }[] = [];
    for (const d of days) {
      const month = Number(d.slice(5, 7)) - 1;
      const last = out[out.length - 1];
      if (last && last.month === month) last.days++;
      else out.push({ month, days: 1 });
    }
    return out;
  }, [days]);

  return (
    <div className="flex w-7 shrink-0 flex-col border-r border-border">
      {groups.map((g) => (
        <div key={g.month} className="flex min-h-0 items-center justify-center overflow-hidden" style={{ flexGrow: g.days, flexBasis: 0 }}>
          <span
            className="whitespace-nowrap text-[11px] uppercase tracking-[0.2em] text-tertiary"
            style={{ writingMode: "vertical-rl" }}
          >
            {MONTHS_LONG[g.month]}
          </span>
        </div>
      ))}
    </div>
  );
}

/**
 * One day. Top to bottom: habit badges straddling the rail, the header, the day's name, the timed
 * track, and the all-day pills sitting on the floor.
 *
 * All-day events at the *bottom* is the opposite of Google and Apple, and it is deliberate: they
 * are the ground the day stands on rather than a banner hung above it.
 */
function DayColumn({
  date,
  day,
  habits,
  pxPerHour,
  allDayPx,
  measure,
}: {
  date: string;
  day: CalendarDay | undefined;
  habits: Habit[];
  pxPerHour: number;
  allDayPx: number;
  /** Only one column reports its height: the scale it yields is shared by all seven. */
  measure?: (el: HTMLDivElement | null) => void;
}) {
  const { cursor, setCursor, openEvent, eventsOn } = useCalendar();
  const { allDay } = eventsOn(date);
  const today = isToday(date);

  return (
    <div
      onMouseDown={() => setCursor(date)}
      className={cn(
        "group/col relative flex min-w-0 flex-col border-l border-t border-border first:border-l-0",
        cursor === date && "bg-muted/25",
      )}
    >
      {/* Not a thumbnail: the cover runs floor to ceiling, behind everything, barely there. */}
      {day?.cover_url && (
        <img
          src={day.cover_url}
          alt=""
          loading="lazy"
          className="pointer-events-none absolute inset-0 z-0 h-full w-full object-cover opacity-[0.16] grayscale"
        />
      )}

      <div className="relative z-10 flex min-h-0 flex-1 flex-col">
        <HabitBadges date={date} habits={habits} />
        <DayHeader date={date} today={today} />
        <DayLabel date={date} label={day?.label ?? ""} />
        <Track date={date} pxPerHour={pxPerHour} today={today} measure={measure} />
        {allDayPx > 0 && (
          <div className="flex shrink-0 flex-col justify-end gap-[2px] px-1 pb-1" style={{ height: allDayPx }}>
            {allDay.map((e) => (
              <AllDayPill key={e.id} e={e} onClick={() => openEvent(e)} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

/**
 * The habits, as small circles straddling the top rail — half above the column's border, so they
 * read as buttons pinned to the calendar rather than another row of content inside it.
 */
function HabitBadges({ date, habits }: { date: string; habits: Habit[] }) {
  const { toggle } = useHabitMutations();
  const dow = new Date(`${date}T00:00:00`).getDay();
  const mine = habits.filter((h) => h.days.length === 0 || h.days.includes(dow));

  return (
    <div className="relative z-10 -mt-2 flex shrink-0 items-center justify-center gap-1" style={{ height: HABITS_PX }}>
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
              "inline-flex size-[18px] shrink-0 items-center justify-center rounded-full border text-[9px] leading-none transition-colors",
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
 * `MON 18`, right-aligned and deliberately small — on HEY the header is barely bigger than the
 * event text, because the header is not the point of the view. Today is reversed out of a solid
 * blob; HEY uses its orange, and this app being monochrome, the foreground colour stands in.
 */
function DayHeader({ date, today }: { date: string; today: boolean }) {
  const d = new Date(`${date}T00:00:00`);
  return (
    <div className="flex shrink-0 items-center justify-end px-1.5" style={{ height: HEADER_PX }}>
      <span className={cn("inline-flex items-baseline gap-1", today && "rounded-full bg-foreground px-1.5 py-0.5 text-background")}>
        <span className={cn("text-[10.5px] uppercase leading-none tracking-[0.09em]", !today && "text-tertiary")}>{WEEKDAYS[d.getDay()]}</span>
        <span className="text-[15px] font-bold leading-none tnum">{d.getDate()}</span>
      </span>
    </div>
  );
}

/** A day is allowed a name of its own — "Ada's birthday", "Ship day". One line, click to write it. */
function DayLabel({ date, label }: { date: string; label: string }) {
  const mut = useCalendarDayMutation();
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(label);
  useEffect(() => setDraft(label), [label]);

  const save = () => {
    setEditing(false);
    if (draft !== label) mut.mutate({ date, label: draft });
  };

  if (editing) {
    return (
      <input
        autoFocus
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={save}
        onKeyDown={(e) => {
          if (e.key === "Enter") save();
          if (e.key === "Escape") {
            setDraft(label);
            setEditing(false);
          }
        }}
        placeholder="Name this day"
        style={{ height: LABEL_PX }}
        className="w-full shrink-0 bg-transparent px-1 text-center text-[10.5px] outline-none placeholder:text-tertiary"
      />
    );
  }
  return (
    <button
      type="button"
      onClick={(e) => {
        e.stopPropagation();
        setEditing(true);
      }}
      title={label || "Name this day"}
      style={{ height: LABEL_PX }}
      className={cn(
        "w-full shrink-0 truncate px-1 text-center text-[10.5px] leading-[16px]",
        label ? "text-muted-foreground" : "text-transparent group-hover/col:text-tertiary",
      )}
    >
      {label || "Name this day"}
    </button>
  );
}

/**
 * The body of a column: free time, night, events, now — drawn on one ribbon, to one scale.
 *
 * There is nothing else in here. No hour labels, no rules. The bands *are* the hours.
 */
function Track({
  date,
  pxPerHour,
  today,
  measure,
}: {
  date: string;
  pxPerHour: number;
  today: boolean;
  measure?: (el: HTMLDivElement | null) => void;
}) {
  const { settings, nightOpen, setNightOpen, eventsOn, openEvent, createEvent } = useCalendar();
  const { setDone } = useEventMutations();
  const { timed } = eventsOn(date);

  const box = useRef<HTMLDivElement>(null);
  const setBox = useCallback(
    (el: HTMLDivElement | null) => {
      box.current = el;
      measure?.(el);
    },
    [measure],
  );

  const dayStart = useMemo(() => startOfDayMs(date), [date]);
  const ribbon = useMemo(
    () =>
      makeRibbon({
        from: dayStart,
        to: dayStart + DAY_MS,
        pxPerHour,
        nightStart: settings.night_start,
        nightEnd: settings.night_end,
        collapseNight: settings.collapse_night && !nightOpen,
      }),
    [dayStart, pxPerHour, settings.night_start, settings.night_end, settings.collapse_night, nightOpen],
  );

  const layout = useMemo(() => layoutColumns(timed), [timed]);
  const gaps = useMemo(() => wakingGaps(ribbon, timed), [ribbon, timed]);

  // The now marker ticks itself; only today's column has one.
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!today) return;
    const t = window.setInterval(() => setNow(Date.now()), 60_000);
    return () => window.clearInterval(t);
  }, [today]);

  const [drag, setDrag] = useState<{ from: number; to: number } | null>(null);
  const msAtY = useCallback(
    (clientY: number) => {
      const r = box.current?.getBoundingClientRect();
      if (!r) return dayStart;
      return dayStart + snap(Math.round((ribbon.at(clientY - r.top) - dayStart) / 60_000)) * 60_000;
    },
    [ribbon, dayStart],
  );

  return (
    <div
      ref={setBox}
      className="relative min-h-0 flex-1 select-none overflow-hidden"
      onMouseDown={(e) => {
        if (e.button !== 0 || (e.target as HTMLElement).closest("button")) return;
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
      {/* Free time, at the same scale as everything else, stamped with what it is worth. */}
      {gaps.map((g) => {
        const top = ribbon.pos(g.from);
        const height = ribbon.pos(g.to) - top;
        if (height < 2) return null;
        return (
          <div key={g.from} className="pointer-events-none absolute inset-x-0 bg-muted/60" style={{ top, height }}>
            {height >= STAMP_MIN_PX && (
              <span className="absolute inset-x-0 bottom-[2px] text-center text-[9.5px] leading-none text-tertiary">
                {spanLabel(g.to - g.from)}
              </span>
            )}
          </div>
        );
      })}

      {ribbon.runs.filter((r) => r.night).map((r) => (
        <Night key={r.from} run={r} onToggle={() => setNightOpen(!nightOpen)} open={nightOpen} />
      ))}

      {timed.map((e, i) => {
        const top = ribbon.pos(Math.max(e.starts_at, dayStart));
        const bottom = ribbon.pos(Math.min(e.ends_at, dayStart + DAY_MS));
        return (
          <EventBlock
            key={e.id}
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
            top: ribbon.pos(Math.min(drag.from, drag.to)),
            height: Math.max(ribbon.pos(Math.max(drag.from, drag.to)) - ribbon.pos(Math.min(drag.from, drag.to)), 8),
          }}
        />
      )}

      {today && now >= dayStart && now < dayStart + DAY_MS && (
        <div className="pointer-events-none absolute inset-x-0 z-30" style={{ top: ribbon.pos(now) }}>
          <div className="h-px bg-red-500" />
          <div className="absolute -top-[3px] left-0 size-[7px] rounded-full bg-red-500" />
        </div>
      )}
    </div>
  );
}

/** The gaps between busy events, inside the waking runs only — night is never "free time". */
function wakingGaps(ribbon: Ribbon, events: CalEvent[]): { from: number; to: number }[] {
  const out: { from: number; to: number }[] = [];
  for (const r of ribbon.runs) {
    if (r.night) continue;
    for (const g of freeGaps(events, r.from, r.to)) out.push(g);
  }
  return out;
}

/** Zigzag torn-paper edges, top and bottom, with the body of the block left solid between them. */
const SAW = "repeating-linear-gradient(135deg, #000 0 4px, rgba(0,0,0,0) 4px 8px)";
const TORN: React.CSSProperties = {
  maskImage: `${SAW}, ${SAW}, linear-gradient(#000, #000)`,
  WebkitMaskImage: `${SAW}, ${SAW}, linear-gradient(#000, #000)`,
  maskSize: "100% 5px, 100% 5px, 100% calc(100% - 10px)",
  WebkitMaskSize: "100% 5px, 100% 5px, 100% calc(100% - 10px)",
  maskPosition: "top left, bottom left, left 5px",
  WebkitMaskPosition: "top left, bottom left, left 5px",
  maskRepeat: "repeat-x, repeat-x, no-repeat",
  WebkitMaskRepeat: "repeat-x, repeat-x, no-repeat",
};

/**
 * Night: the one place the scale is allowed to lie. Eight hours become eighty pixels, torn off at
 * both edges so the break in the ruler is visible rather than pretended away. Click to open it out.
 */
function Night({ run, onToggle, open }: { run: RibbonRun; onToggle: () => void; open: boolean }) {
  const sky = useMemo(() => stars(run.from, Math.max(3, Math.min(10, Math.round(run.size / 12)))), [run.from, run.size]);
  return (
    <button
      type="button"
      onClick={onToggle}
      aria-label={open ? "Collapse the night" : "Open the night out"}
      title={open ? "Collapse the night" : "Open the night out"}
      className="absolute inset-x-0 z-10 overflow-hidden bg-[#1c1c24]"
      style={{ top: run.pos, height: run.size, ...TORN }}
    >
      {sky.map((s, i) => (
        <span
          key={i}
          className="absolute rounded-full bg-white"
          style={{ left: `${s.x}%`, top: `${s.y}%`, width: s.r, height: s.r, opacity: s.o }}
        />
      ))}
      {/* The midnight fold, drawn down the middle of the block the way HEY scores its night. */}
      <span className="absolute inset-y-0 left-1/2 w-px bg-black" />
      {run.size >= 26 && (
        <span className="absolute inset-x-0 bottom-[3px] text-center text-[9px] leading-none text-white/60">Nighttime</span>
      )}
    </button>
  );
}

/**
 * Stars, placed from the run's own start instant so a re-render never reshuffles the sky.
 * A plain LCG: cheap, deterministic, and nobody is checking its spectral properties.
 */
function stars(seed: number, count: number): { x: number; y: number; r: number; o: number }[] {
  let s = (seed >>> 0) || 1;
  const rnd = () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 4294967296;
  };
  return Array.from({ length: count }, () => ({
    x: 6 + rnd() * 88,
    y: 12 + rnd() * 74,
    r: rnd() < 0.25 ? 2 : 1,
    o: 0.35 + rnd() * 0.5,
  }));
}
