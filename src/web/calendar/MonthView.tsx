import { useMemo } from "react";
import { BookOpen, Plus } from "lucide-react";
import type { CalEvent, CalendarDay } from "@shared/types";
import { cn } from "@/lib/utils";
import { useCalendar } from "./CalendarContext";
import { AllDayChip } from "./EventBlock";
import { fmtTime, isPast, isToday, isWeekend, monthGrid, msAt, weekDays, weekdayLabel } from "../lib/caldate";

/**
 * The month grid — six rows of seven, for orientation rather than detail.
 *
 * A cell is deliberately poor at showing a busy day: it lists what fits and then says how much it
 * is hiding, and the "+n more" takes you to the days view where the day is actually readable.
 */

/** How many items a cell shows before it starts counting. Sized to the shortest row height. */
const CAP = 3;

export function MonthView() {
  const { settings, cursor, setCursor, setView, range, eventsOn, openEvent, createEvent } = useCalendar();

  const grid = useMemo(() => monthGrid(cursor, settings.week_start), [cursor, settings.week_start]);
  const heads = useMemo(() => weekDays(cursor, settings.week_start), [cursor, settings.week_start]);
  const days = useMemo(() => {
    const m = new Map<string, CalendarDay>();
    for (const d of range?.days ?? []) m.set(d.date, d);
    return m;
  }, [range]);

  const month = cursor.slice(0, 7);
  const openDay = (date: string) => {
    setCursor(date);
    setView("days");
  };

  return (
    <div className="min-h-0 flex-1 overflow-auto rounded-md border border-border bg-background">
      <div className="flex min-h-full min-w-[42rem] flex-col">
        <div className="sticky top-0 z-10 grid grid-cols-7 border-b border-border bg-background">
          {heads.map((d) => (
            <div key={d} className="px-2 py-1 text-[10px] uppercase tracking-wide text-tertiary">
              {weekdayLabel(d).slice(0, 3)}
            </div>
          ))}
        </div>

        <div className="grid min-h-0 flex-1 grid-cols-7 grid-rows-6">
          {grid.map((date, i) => (
            <Cell
              key={date}
              date={date}
              inMonth={date.slice(0, 7) === month}
              lastRow={i >= 35}
              lastCol={i % 7 === 6}
              day={days.get(date)}
              selected={date === cursor}
              format={settings.time_format}
              events={eventsOn(date)}
              onOpenEvent={openEvent}
              onOpenDay={openDay}
              onCreate={() => createEvent({ starts_at: msAt(date, 9 * 60), ends_at: msAt(date, 10 * 60) })}
            />
          ))}
        </div>
      </div>
    </div>
  );
}

function Cell({
  date,
  inMonth,
  lastRow,
  lastCol,
  day,
  selected,
  format,
  events,
  onOpenEvent,
  onOpenDay,
  onCreate,
}: {
  date: string;
  inMonth: boolean;
  lastRow: boolean;
  lastCol: boolean;
  day: CalendarDay | undefined;
  selected: boolean;
  format: "12" | "24";
  events: { allDay: CalEvent[]; timed: CalEvent[] };
  onOpenEvent: (e: CalEvent) => void;
  onOpenDay: (date: string) => void;
  onCreate: () => void;
}) {
  const today = isToday(date);
  const n = Number(date.slice(8));
  const items: CalEvent[] = [...events.allDay, ...events.timed];
  const shown = items.slice(0, CAP);
  const more = items.length - shown.length;

  return (
    <div
      onClick={onCreate}
      className={cn(
        "group/cell relative flex min-h-[5.5rem] min-w-0 flex-col gap-0.5 border-b border-r border-border p-1",
        isWeekend(date) && "bg-muted/30",
        !inMonth && "opacity-45",
        selected && "bg-muted/60",
        lastRow && "border-b-0",
        lastCol && "border-r-0",
      )}
    >
      <div className="flex items-center gap-1">
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            onOpenDay(date);
          }}
          title={date}
          className={cn(
            "flex size-[18px] shrink-0 items-center justify-center rounded-full text-[11.5px] tnum leading-none transition-colors",
            today ? "bg-foreground font-semibold text-background" : isPast(date) ? "text-muted-foreground hover:bg-muted" : "hover:bg-muted",
          )}
        >
          {n}
        </button>
        {n === 1 && <span className="shrink-0 text-[10px] text-tertiary">{monthShort(date)}</span>}
        {day?.label && <span className="min-w-0 truncate text-[10.5px] text-muted-foreground">{day.label}</span>}
        <span className="flex-1" />
        {day?.has_journal && <BookOpen size={9} className="shrink-0 text-tertiary" aria-label="Journal entry" />}
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            onCreate();
          }}
          aria-label={`New event on ${date}`}
          className="shrink-0 text-tertiary opacity-0 transition-opacity hover:text-foreground group-hover/cell:opacity-100"
        >
          <Plus size={11} />
        </button>
      </div>

      <div className="flex min-h-0 flex-col gap-0.5 overflow-hidden" onClick={(e) => e.stopPropagation()}>
        {shown.map((e) =>
          e.all_day ? (
            <AllDayChip key={e.id} e={e} onClick={() => onOpenEvent(e)} />
          ) : (
            <button
              key={e.id}
              type="button"
              onClick={() => onOpenEvent(e)}
              title={`${fmtTime(e.starts_at, format)} · ${e.title || "(no title)"}`}
              className={cn(
                "flex h-[17px] w-full items-center gap-1 rounded-[3px] px-1 text-left text-[11px] leading-none hover:bg-muted",
                e.rsvp === "declined" && "opacity-45 line-through",
              )}
            >
              <span className="shrink-0 tnum text-tertiary">{fmtTime(e.starts_at, format)}</span>
              {e.emoji && <span className="shrink-0">{e.emoji}</span>}
              <span className={cn("min-w-0 truncate", e.done && "text-muted-foreground line-through")}>{e.title || "(no title)"}</span>
            </button>
          ),
        )}
        {more > 0 && (
          <button
            type="button"
            onClick={() => onOpenDay(date)}
            className="h-[15px] px-1 text-left text-[10.5px] text-tertiary hover:text-foreground"
          >
            +{more} more
          </button>
        )}
      </div>
    </div>
  );
}

/** "Sep" — printed beside a 1st so the grid still reads at its seams. */
function monthShort(date: string): string {
  return new Date(`${date}T00:00:00`).toLocaleString(undefined, { month: "short" });
}
