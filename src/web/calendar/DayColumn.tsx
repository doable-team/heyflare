import { useEffect, useRef, useState } from "react";
import { BookOpen, ImagePlus, Plus } from "lucide-react";
import type { CalEvent, CalendarDay, Habit } from "@shared/types";
import { cn } from "@/lib/utils";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { useCalendar } from "./CalendarContext";
import { AllDayChip, EventBlock } from "./EventBlock";
import { MIN_EVENT_PX, snap } from "./scale";
import { countdownLabel, isPast, isToday, isWeekend, layoutColumns, minutesOfDay, msAt } from "../lib/caldate";
import { useCalendarDayMutation, useEventMutations, useHabitMutations } from "../api";

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

/** Header block: cover art, the date, an editable label, habits and the day's all-day items. */
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
      className={cn(
        "flex flex-col gap-1 px-1.5 pt-1.5 pb-1 border-l border-border",
        isWeekend(date) && "bg-muted/30",
        cursor === date && "bg-muted/60",
      )}
      onClick={() => setCursor(date)}
    >
      {day?.cover_url && (
        <div className="h-9 -mx-1.5 -mt-1.5 mb-0.5 overflow-hidden bg-muted">
          <img src={day.cover_url} alt="" className="h-full w-full object-cover grayscale" loading="lazy" />
        </div>
      )}
      <div className="flex items-baseline gap-1.5 min-w-0">
        <span className={cn("text-[10px] uppercase tracking-wide", today ? "text-foreground" : "text-tertiary")}>{WEEKDAYS[d.getDay()]}</span>
        <span
          className={cn(
            "text-[13px] tnum leading-none",
            today ? "font-semibold text-background bg-foreground rounded-full px-1.5 py-1 -my-1" : isPast(date) ? "text-muted-foreground" : "font-medium",
          )}
        >
          {d.getDate()}
        </span>
        {d.getDate() === 1 && <span className="text-[10px] text-tertiary">{d.toLocaleString(undefined, { month: "short" })}</span>}
        <span className="flex-1" />
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            createEvent({ starts_at: msAt(date, 9 * 60), ends_at: msAt(date, 10 * 60) });
          }}
          className="opacity-0 group-hover/col:opacity-100 text-tertiary hover:text-foreground transition-opacity"
          aria-label={`New event on ${date}`}
        >
          <Plus size={12} />
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
          className="h-4 w-full bg-transparent text-[10.5px] outline-none placeholder:text-tertiary"
        />
      ) : (
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation();
            setEditing(true);
          }}
          className={cn("h-4 text-left text-[10.5px] truncate", day?.label ? "text-muted-foreground" : "text-transparent group-hover/col:text-tertiary")}
        >
          {day?.label || "Name this day"}
        </button>
      )}

      {habits.length > 0 && (
        <div className="flex flex-wrap gap-0.5">
          {habits.map((h) => {
            const done = h.completions?.includes(date);
            return (
              <Tooltip key={h.id}>
                <TooltipTrigger asChild>
                  <button
                    type="button"
                    onClick={(e) => {
                      e.stopPropagation();
                      habitMut.toggle.mutate({ id: h.id, date });
                    }}
                    aria-pressed={done}
                    aria-label={h.name}
                    className={cn(
                      "size-4 rounded-[3px] border text-[9px] leading-none flex items-center justify-center transition-colors",
                      done ? "border-transparent text-background" : "border-border text-tertiary hover:border-foreground/40",
                    )}
                    style={done ? { background: h.color || "currentColor" } : undefined}
                  >
                    {h.icon || h.name.slice(0, 1).toUpperCase()}
                  </button>
                </TooltipTrigger>
                <TooltipContent side="bottom">
                  {h.name}
                  {done ? " · done" : ""}
                </TooltipContent>
              </Tooltip>
            );
          })}
        </div>
      )}

      <div className="flex flex-col gap-0.5 min-h-[19px]">
        {allDay.map((e) => (
          <div key={e.id}>
            <AllDayChip e={e} onClick={() => openEvent(e)} />
            {e.countdown && <div className="px-1.5 text-[9.5px] text-tertiary">{countdownLabel(e.start_date ?? date)}</div>}
          </div>
        ))}
      </div>
    </div>
  );
}

/** The timeline body for one day: hour rules, the events, the now line, and drag-to-create. */
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
        "relative border-l border-border select-none",
        isWeekend(date) && "bg-muted/30",
        isPast(date) && !today && "opacity-[0.82]",
        cursor === date && "bg-muted/50",
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
        s.night ? (
          <button
            key={s.from}
            type="button"
            onClick={() => setNightOpen(!nightOpen)}
            style={{ top: s.y, height: s.height }}
            className="absolute inset-x-0 z-0 bg-muted/60 hover:bg-muted text-[9px] text-tertiary"
            aria-label={nightOpen ? "Collapse nighttime" : "Expand nighttime"}
          />
        ) : null,
      )}
      {scale.hours.map((h) => (
        <div key={h.hour} style={{ top: h.y }} className="pointer-events-none absolute inset-x-0 border-t border-border/60" />
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
          className="pointer-events-none absolute inset-x-0.5 z-20 rounded-[4px] border border-dashed border-foreground/50 bg-foreground/5"
          style={{ top: scale.y(Math.min(drag.from, drag.to)), height: Math.max(scale.y(Math.max(drag.from, drag.to)) - scale.y(Math.min(drag.from, drag.to)), 8) }}
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
