import { useEffect, useRef, useState } from "react";
import { Plus } from "lucide-react";
import type { CalEvent, CalendarDay, Habit } from "@shared/types";
import { cn } from "@/lib/utils";
import { useCalendar } from "./CalendarContext";
import { AllDayChip, EventBlock } from "./EventBlock";
import { MIN_EVENT_PX, snap } from "./scale";
import { countdownLabel, isPast, isToday, isWeekend, layoutColumns, minutesOfDay, msAt } from "../lib/caldate";
import { useCalendarDayMutation, useEventMutations, useHabitMutations } from "../api";

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/**
 * The head of a day: its cover, its name, the things you meant to do today, then the all-day
 * banners. The personal half of a day sits above the scheduled half on purpose — a day is more
 * than the meetings someone else put in it.
 */
function DayHead({ date, day, habits, allDay }: { date: string; day: CalendarDay | undefined; habits: Habit[]; allDay: CalEvent[] }) {
  const { openEvent, createEvent, cursor, setCursor } = useCalendar();
  const today = isToday(date);
  const d = new Date(`${date}T00:00:00`);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(day?.label ?? "");
  const dayMut = useCalendarDayMutation();
  const habitMut = useHabitMutations();
  useEffect(() => setDraft(day?.label ?? ""), [day?.label]);

  const saveLabel = () => {
    setEditing(false);
    if ((day?.label ?? "") !== draft) dayMut.mutate({ date, label: draft });
  };

  return (
    <div
      className={cn("flex flex-col border-l border-border px-2.5 pb-1.5 pt-2", isWeekend(date) && "bg-muted/40", cursor === date && "bg-muted/70")}
      onClick={() => setCursor(date)}
    >
      {day?.cover_url && (
        <div className="-mx-2.5 -mt-2 mb-2 h-14 overflow-hidden bg-muted">
          <img src={day.cover_url} alt="" className="h-full w-full object-cover grayscale" loading="lazy" />
        </div>
      )}

      <div className="flex items-start gap-2">
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-1.5">
            {today ? (
              <span className="rounded-full bg-foreground px-1.5 py-[3px] text-[9.5px] font-semibold uppercase tracking-[0.08em] leading-none text-background">Today</span>
            ) : (
              <span className={cn("text-[10.5px] uppercase tracking-[0.08em]", isPast(date) ? "text-tertiary" : "text-muted-foreground")}>{WEEKDAYS[d.getDay()]}</span>
            )}
            {d.getDate() === 1 && <span className="text-[10.5px] uppercase tracking-[0.08em] text-tertiary">{d.toLocaleString(undefined, { month: "short" })}</span>}
          </div>
          <div className={cn("mt-0.5 text-[30px] font-semibold leading-[32px] tnum tracking-[-0.02em]", isPast(date) && !today && "text-muted-foreground")}>
            {d.getDate()}
          </div>
        </div>
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            createEvent({ starts_at: msAt(date, 9 * 60), ends_at: msAt(date, 10 * 60) });
          }}
          className="mt-1 shrink-0 text-tertiary opacity-0 transition-opacity hover:text-foreground group-hover/col:opacity-100"
          aria-label={`New event on ${date}`}
        >
          <Plus size={14} />
        </button>
      </div>

      {editing ? (
        <input
          autoFocus
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onBlur={saveLabel}
          onKeyDown={(e) => {
            if (e.key === "Enter") saveLabel();
            if (e.key === "Escape") {
              setDraft(day?.label ?? "");
              setEditing(false);
            }
          }}
          placeholder="Name this day"
          className="mt-0.5 h-5 w-full bg-transparent text-[12px] outline-none placeholder:text-tertiary"
        />
      ) : (
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            setEditing(true);
          }}
          className={cn("mt-0.5 h-5 truncate text-left text-[12px]", day?.label ? "text-muted-foreground" : "text-transparent group-hover/col:text-tertiary")}
        >
          {day?.label || "Name this day"}
        </button>
      )}

      {habits.length > 0 && (
        <div className="mt-1.5 flex flex-wrap gap-1">
          {habits.map((h) => {
            const done = h.completions?.includes(date);
            return (
              <button
                key={h.id}
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  habitMut.toggle.mutate({ id: h.id, date });
                }}
                aria-pressed={done}
                title={h.name}
                className={cn(
                  "inline-flex h-5 max-w-full items-center gap-1 rounded-full border px-1.5 text-[11px] leading-none transition-colors",
                  done ? "border-transparent text-background" : "border-border text-muted-foreground hover:border-foreground/40 hover:text-foreground",
                )}
                style={done ? { background: h.color || "currentColor" } : undefined}
              >
                {h.icon && <span className="shrink-0 text-[10px]">{h.icon}</span>}
                <span className="truncate">{h.name}</span>
              </button>
            );
          })}
        </div>
      )}

      <div className={cn("flex flex-col gap-1", allDay.length > 0 && "mt-1.5")}>
        {allDay.map((e) => (
          <div key={e.id}>
            <AllDayChip e={e} onClick={() => openEvent(e)} />
            {e.countdown && <div className="px-2 pt-0.5 text-[10.5px] text-tertiary">{countdownLabel(e.start_date ?? date)}</div>}
          </div>
        ))}
      </div>
    </div>
  );
}

/** The timeline body for one day: the events, the now line, and drag-to-create. */
function DayBody({ date }: { date: string }) {
  const { scale, settings, eventsOn, openEvent, createEvent, setNightOpen, nightOpen, cursor, setCursor } = useCalendar();
  const { timed } = eventsOn(date);
  const { setDone } = useEventMutations();
  const ref = useRef<HTMLDivElement>(null);
  const [drag, setDrag] = useState<{ from: number; to: number } | null>(null);
  const layout = layoutColumns(timed);
  const today = isToday(date);
  const [nowMin, setNowMin] = useState(() => minutesOfDay(Date.now()));
  useEffect(() => {
    if (!today) return;
    const t = window.setInterval(() => setNowMin(minutesOfDay(Date.now())), 60_000);
    return () => window.clearInterval(t);
  }, [today]);

  const minutesAt = (clientY: number) => {
    const box = ref.current?.getBoundingClientRect();
    if (!box) return 0;
    return snap(scale.minutes(clientY - box.top));
  };

  return (
    <div
      ref={ref}
      className={cn(
        "relative select-none border-l border-border",
        isWeekend(date) && "bg-muted/40",
        isPast(date) && !today && "opacity-[0.75]",
        cursor === date && "bg-muted/60",
      )}
      style={{ height: scale.height }}
      onMouseDown={(e) => {
        if (e.button !== 0 || (e.target as HTMLElement).closest("button")) return;
        setCursor(date);
        const from = minutesAt(e.clientY);
        setDrag({ from, to: from + 30 });
      }}
      onMouseMove={(e) => drag && setDrag({ ...drag, to: minutesAt(e.clientY) })}
      onMouseUp={() => {
        if (!drag) return;
        const a = Math.min(drag.from, drag.to);
        const b = Math.max(drag.from, drag.to);
        setDrag(null);
        createEvent({ starts_at: msAt(date, a), ends_at: msAt(date, b === a ? a + 30 : b) });
      }}
      onMouseLeave={() => setDrag(null)}
    >
      {scale.segments.map((s) =>
        s.band ? (
          <button
            key={s.from}
            type="button"
            onClick={() => setNightOpen(!nightOpen)}
            style={{ top: s.y, height: s.height }}
            className="absolute inset-x-0 z-0 bg-muted/70 hover:bg-muted"
            aria-label={nightOpen ? "Collapse the rest of the day" : "Show the rest of the day"}
          />
        ) : null,
      )}
      {scale.hours.map((h) => (
        <div key={h.hour} style={{ top: h.y }} className="pointer-events-none absolute inset-x-0 border-t border-border/45" />
      ))}

      {timed.map((e, i) => {
        const top = scale.y(minutesOfDay(Math.max(e.starts_at, msAt(date, 0))));
        const bottom = scale.y(minutesOfDay(Math.min(e.ends_at, msAt(date, 1439))));
        return (
          <EventBlock
            key={e.id}
            e={e}
            top={top}
            height={Math.max(bottom - top, MIN_EVENT_PX)}
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
          className="pointer-events-none absolute inset-x-1 z-20 rounded-[5px] border border-dashed border-foreground/50 bg-foreground/5"
          style={{ top: scale.y(Math.min(drag.from, drag.to)), height: Math.max(scale.y(Math.max(drag.from, drag.to)) - scale.y(Math.min(drag.from, drag.to)), 10) }}
        />
      )}

      {today && (
        <div className="pointer-events-none absolute inset-x-0 z-20" style={{ top: scale.y(nowMin) }}>
          <div className="h-px bg-red-500" />
          <div className="absolute -left-[3px] -top-[3px] size-[7px] rounded-full bg-red-500" />
        </div>
      )}
    </div>
  );
}

export function DayHeader({ date }: { date: string }) {
  const { eventsOn, range } = useCalendar();
  const { allDay } = eventsOn(date);
  const day = range?.days.find((d) => d.date === date);
  const habits = (range?.habits ?? []).filter((h) => !h.archived && h.days.includes(new Date(`${date}T00:00:00`).getDay()));
  return <DayHead date={date} day={day} habits={habits} allDay={allDay} />;
}

export { DayBody };
