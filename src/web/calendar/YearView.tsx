import { useEffect, useMemo, useRef, useState } from "react";
import type { CalEvent, CalendarDay } from "@shared/types";
import { cn } from "@/lib/utils";
import { useCalendar } from "./CalendarContext";
import { DayPhotoBackdrop, hasPhoto } from "./DayPhoto";
import { addDays, isPast, isToday, isWeekend, monthLabel, msAt, weekdayLabel } from "../lib/caldate";

/**
 * The whole year, one row per day.
 *
 * HEY's rule applies here: only all-day and multi-day items are drawn. A year of timed meetings is
 * noise, and it is better to show everything a day holds than to hide it behind "+2 more" — so the
 * things that are genuinely about the *date* (birthdays, trips, holidays, countdowns) get the year,
 * and the meetings stay in the days view where their time means something.
 *
 * The month columns follow the container, not a breakpoint: `auto-fill` with a 15rem minimum, so
 * the same component reads as one column in a split pane and six across a wide window.
 */

/** How long a just-picked date stays lit before it fades back. */
const FLASH_MS = 550;

export function YearView() {
  const { cursor, setCursor, setView, eventsOn, openEvent, createEvent, range } = useCalendar();
  // Day photos show through here too, read-only — the year is where you notice you had a life.
  const dayByKey = useMemo(() => new Map((range?.days ?? []).map((d) => [d.date, d])), [range?.days]);
  const year = cursor.slice(0, 4);

  const months = useMemo(
    () => Array.from({ length: 12 }, (_, m) => `${year}-${String(m + 1).padStart(2, "0")}-01`),
    [year],
  );

  // A picked date lights up and fades, so the eye keeps its place when the view changes under it.
  const [flash, setFlash] = useState<string | null>(null);
  const timer = useRef<number>(0);
  useEffect(() => () => window.clearTimeout(timer.current), []);
  const lightUp = (date: string) => {
    setFlash(date);
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setFlash(null), FLASH_MS);
  };

  const pick = (date: string) => {
    lightUp(date);
    setCursor(date);
    setView("days");
  };

  return (
    <div className="min-h-0 flex-1 overflow-auto rounded-md border border-border bg-background p-2">
      <div className="grid gap-x-4 gap-y-5" style={{ gridTemplateColumns: "repeat(auto-fill, minmax(15rem, 1fr))" }}>
        {months.map((m) => (
          <Month
            key={m}
            month={m}
            cursor={cursor}
            flash={flash}
            eventsOn={eventsOn}
            dayByKey={dayByKey}
            onPick={pick}
            onOpenEvent={openEvent}
            onCreate={(date) => {
              lightUp(date);
              createEvent({ starts_at: msAt(date, 0), ends_at: msAt(addDays(date, 1), 0), all_day: true, start_date: date, end_date: date });
            }}
          />
        ))}
      </div>
    </div>
  );
}

function Month({
  month,
  cursor,
  flash,
  eventsOn,
  dayByKey,
  onPick,
  onOpenEvent,
  onCreate,
}: {
  month: string;
  cursor: string;
  flash: string | null;
  eventsOn: (date: string) => { allDay: CalEvent[]; timed: CalEvent[] };
  dayByKey: Map<string, CalendarDay>;
  onPick: (date: string) => void;
  onOpenEvent: (e: CalEvent) => void;
  onCreate: (date: string) => void;
}) {
  const days = useMemo(() => {
    const out: string[] = [];
    for (let d = month; d.slice(0, 7) === month.slice(0, 7); d = addDays(d, 1)) out.push(d);
    return out;
  }, [month]);

  return (
    <section className="min-w-0">
      <h2 className="sticky top-0 z-10 mb-0.5 border-b border-border bg-background pb-1 text-[11px] font-medium">
        {monthLabel(month).replace(/\s\d{4}$/, "")}
      </h2>
      <div className="flex flex-col">
        {days.map((d) => (
          <Row
            key={d}
            date={d}
            allDay={eventsOn(d).allDay}
            day={dayByKey.get(d)}
            selected={d === cursor}
            lit={d === flash}
            onPick={onPick}
            onOpenEvent={onOpenEvent}
            onCreate={onCreate}
          />
        ))}
      </div>
    </section>
  );
}

function Row({
  date,
  allDay,
  day,
  selected,
  lit,
  onPick,
  onOpenEvent,
  onCreate,
}: {
  date: string;
  allDay: CalEvent[];
  day: CalendarDay | undefined;
  selected: boolean;
  lit: boolean;
  onPick: (date: string) => void;
  onOpenEvent: (e: CalEvent) => void;
  onCreate: (date: string) => void;
}) {
  const today = isToday(date);
  const n = Number(date.slice(8));
  const photo = hasPhoto(day);

  return (
    <div
      className={cn(
        // The highlight goes on instantly and fades out over the transition — no library needed.
        "relative flex h-[19px] items-center gap-1 overflow-hidden rounded-[3px] transition-colors duration-500",
        isWeekend(date) && "bg-muted/40",
        selected && "bg-muted/70",
        lit && "bg-foreground/15 duration-0",
      )}
    >
      <DayPhotoBackdrop day={day} className="z-0" />
      <button
        type="button"
        onClick={() => onPick(date)}
        title={date}
        className="relative z-10 flex h-full shrink-0 items-center gap-1 pl-1 pr-0.5"
      >
        <span
          className={cn(
            "w-[15px] text-[9.5px] uppercase tracking-wide",
            photo ? "text-white [text-shadow:0_1px_2px_rgba(0,0,0,0.5)]" : today ? "text-foreground" : "text-tertiary",
          )}
        >
          {weekdayLabel(date).slice(0, 2)}
        </span>
        <span
          className={cn(
            "flex size-[16px] items-center justify-center rounded-full text-[11px] tnum leading-none",
            today
              ? "bg-foreground font-semibold text-background"
              : photo
                ? "font-semibold text-white [text-shadow:0_1px_2px_rgba(0,0,0,0.5)]"
                : isPast(date)
                  ? "text-muted-foreground"
                  : n === 1
                    ? "font-medium"
                    : "",
          )}
        >
          {n}
        </span>
      </button>

      {allDay.map((e) => (
        <button
          key={e.id}
          type="button"
          onClick={() => onOpenEvent(e)}
          title={e.title || "(no title)"}
          className={cn(
            "relative z-10 min-w-0 shrink border-l-2 pl-1 text-left text-[11px] leading-none hover:bg-muted",
            photo && "bg-background/85 pr-1 rounded-[2px]",
            e.rsvp === "declined" && "opacity-45 line-through",
          )}
          style={{ borderLeftColor: accent(e) }}
        >
          <span className="block truncate">
            {e.emoji ? `${e.emoji} ` : ""}
            {e.title || "(no title)"}
          </span>
        </button>
      ))}

      <button
        type="button"
        onClick={() => onCreate(date)}
        aria-label={`New all-day event on ${date}`}
        className="h-full min-w-[1rem] flex-1"
      />
    </div>
  );
}

/** A calendar's colour is data, not chrome: a hairline, never a wash. */
function accent(e: CalEvent): string {
  return e.calendar_color && /^#[0-9a-fA-F]{6}$/.test(e.calendar_color) ? e.calendar_color : "currentColor";
}
