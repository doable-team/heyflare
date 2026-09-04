import { useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { BookOpen, ChevronLeft, ChevronRight, Plus } from "lucide-react";
import type { CalEvent } from "@shared/types";
import { cn } from "@/lib/utils";
import { useCalendar } from "./CalendarContext";
import { AllDayChip, EventBlock } from "./EventBlock";
import { fitWindow, makeScale, MIN_EVENT_PX, snap } from "./scale";
import { useCalendarDayMutation, useEventMutations, useHabitMutations } from "../api";
import { addDays, countdownLabel, isToday, layoutColumns, longDayLabel, minutesOfDay, msAt, relativeDay, todayKey } from "../lib/caldate";

/**
 * One day, in detail. This is the only place time is drawn to scale: the week scroll next to it
 * orders events without sizing them, and everything that needs an actual hour — where a meeting
 * sits, dragging out a new one, the line marking now — happens here.
 */
export function DayPane({ full = false }: { full?: boolean }) {
  const { cursor, setCursor, settings, eventsOn, range, openEvent, createEvent, nightOpen, setNightOpen } = useCalendar();
  const { allDay, timed } = eventsOn(cursor);
  const { setDone } = useEventMutations();
  const habitMut = useHabitMutations();
  const dayMut = useCalendarDayMutation();
  const day = range?.days.find((d) => d.date === cursor);
  const habits = (range?.habits ?? []).filter((h) => !h.archived && h.days.includes(new Date(`${cursor}T00:00:00`).getDay()));

  const bodyRef = useRef<HTMLDivElement>(null);
  const [height, setHeight] = useState(520);
  useEffect(() => {
    const el = bodyRef.current;
    if (!el) return;
    const measure = () => setHeight(Math.max(320, el.clientHeight - 4));
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Fitted to this day alone, so a day that runs 09:00–18:00 fills the pane instead of floating in
  // the middle of a 24-hour chart. What falls outside becomes the nighttime band.
  const scale = useMemo(() => {
    const w = fitWindow(timed, minutesOfDay);
    return makeScale({ from: w.from, to: w.to, collapse: settings.collapse_night && !nightOpen, fit: height });
  }, [timed, settings.collapse_night, nightOpen, height]);

  const [drag, setDrag] = useState<{ from: number; to: number } | null>(null);
  const [nowMin, setNowMin] = useState(() => minutesOfDay(Date.now()));
  const today = isToday(cursor);
  useEffect(() => {
    if (!today) return;
    const t = window.setInterval(() => setNowMin(minutesOfDay(Date.now())), 60_000);
    return () => window.clearInterval(t);
  }, [today]);

  const layout = layoutColumns(timed);
  const minutesAt = (clientY: number) => {
    const box = bodyRef.current?.querySelector("[data-timeline]")?.getBoundingClientRect();
    if (!box) return 0;
    return snap(scale.minutes(clientY - box.top));
  };

  // Everything with a countdown still ahead of us, nearest first — HEY's strip along the bottom.
  const countdowns = (range?.events ?? [])
    .filter((e) => e.countdown && (e.start_date ?? "") >= todayKey())
    .sort((a, b) => (a.start_date ?? "").localeCompare(b.start_date ?? ""))
    .slice(0, 6);

  const [labelDraft, setLabelDraft] = useState(day?.label ?? "");
  const [editingLabel, setEditingLabel] = useState(false);
  useEffect(() => setLabelDraft(day?.label ?? ""), [day?.label, cursor]);

  return (
    <div className={cn("flex min-h-0 flex-col overflow-hidden rounded-md border border-border bg-background", full ? "flex-1" : "h-full")}>
      <header className="shrink-0 border-b border-border px-3 py-2">
        <div className="flex items-center gap-1">
          <button type="button" onClick={() => setCursor(addDays(cursor, -1))} className="rounded p-0.5 text-muted-foreground hover:bg-accent hover:text-foreground" aria-label="Previous day">
            <ChevronLeft size={16} />
          </button>
          <button type="button" onClick={() => setCursor(addDays(cursor, 1))} className="rounded p-0.5 text-muted-foreground hover:bg-accent hover:text-foreground" aria-label="Next day">
            <ChevronRight size={16} />
          </button>
          <div className="min-w-0 flex-1 text-center">
            <div className="truncate text-[14px] font-semibold">{longDayLabel(cursor)}</div>
            {relativeDay(cursor) && <div className="text-[11px] text-muted-foreground">{relativeDay(cursor)}</div>}
          </div>
          <Link to={`/journal/${cursor}`} className="rounded p-1 text-muted-foreground hover:bg-accent hover:text-foreground" title="Journal">
            <BookOpen size={15} />
          </Link>
          <button
            type="button"
            onClick={() => createEvent({ starts_at: msAt(cursor, 9 * 60), ends_at: msAt(cursor, 10 * 60) })}
            className="rounded p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
            aria-label="New event"
          >
            <Plus size={15} />
          </button>
        </div>

        {editingLabel ? (
          <input
            autoFocus
            value={labelDraft}
            onChange={(e) => setLabelDraft(e.target.value)}
            onBlur={() => {
              setEditingLabel(false);
              if ((day?.label ?? "") !== labelDraft) dayMut.mutate({ date: cursor, label: labelDraft });
            }}
            onKeyDown={(e) => {
              if (e.key === "Enter") (e.target as HTMLInputElement).blur();
              if (e.key === "Escape") {
                setLabelDraft(day?.label ?? "");
                setEditingLabel(false);
              }
            }}
            placeholder="Name this day"
            className="mt-1 h-5 w-full bg-transparent text-center text-[12px] outline-none placeholder:text-tertiary"
          />
        ) : (
          <button
            type="button"
            onClick={() => setEditingLabel(true)}
            className={cn("mt-0.5 h-5 w-full truncate text-center text-[12px]", day?.label ? "text-muted-foreground" : "text-tertiary/70 hover:text-tertiary")}
          >
            {day?.label || "Name this day"}
          </button>
        )}

        {habits.length > 0 && (
          <div className="mt-1.5 flex flex-wrap justify-center gap-1.5">
            {habits.map((h) => {
              const done = h.completions?.includes(cursor);
              return (
                <button
                  key={h.id}
                  type="button"
                  onClick={() => habitMut.toggle.mutate({ id: h.id, date: cursor })}
                  aria-pressed={done}
                  title={`${h.name}${done ? " · done" : ""}`}
                  className={cn(
                    "inline-flex size-7 items-center justify-center rounded-full border text-[13px] transition-colors",
                    done ? "border-transparent" : "border-border text-muted-foreground hover:border-foreground/40",
                  )}
                  style={done ? { background: h.color || "currentColor", color: "#fff" } : undefined}
                >
                  {h.icon || h.name.slice(0, 1).toUpperCase()}
                </button>
              );
            })}
          </div>
        )}
      </header>

      {day?.cover_url && (
        <div className="h-24 shrink-0 overflow-hidden bg-muted">
          <img src={day.cover_url} alt="" className="h-full w-full object-cover grayscale" loading="lazy" />
        </div>
      )}

      {allDay.length > 0 && (
        <div className="shrink-0 space-y-1 border-b border-border px-2.5 py-1.5">
          {allDay.map((e) => (
            <AllDayChip key={e.id} e={e} onClick={() => openEvent(e)} />
          ))}
        </div>
      )}

      <div ref={bodyRef} className="min-h-0 flex-1 overflow-auto">
        <div
          data-timeline
          className="relative select-none pr-10"
          style={{ height: scale.height }}
          onMouseDown={(e) => {
            if (e.button !== 0 || (e.target as HTMLElement).closest("button")) return;
            const from = minutesAt(e.clientY);
            setDrag({ from, to: from + 30 });
          }}
          onMouseMove={(e) => drag && setDrag({ ...drag, to: minutesAt(e.clientY) })}
          onMouseUp={() => {
            if (!drag) return;
            const a = Math.min(drag.from, drag.to);
            const b = Math.max(drag.from, drag.to);
            setDrag(null);
            createEvent({ starts_at: msAt(cursor, a), ends_at: msAt(cursor, b === a ? a + 30 : b) });
          }}
          onMouseLeave={() => setDrag(null)}
        >
          {/* Hour marks sit quietly down the right edge rather than ruling the whole pane. */}
          {scale.hours.map((h) =>
            h.hour === 0 || h.hour === 24 ? null : (
              <div key={h.hour} className="pointer-events-none absolute right-1.5 text-[10px] tnum text-tertiary" style={{ top: scale.y(h.hour * 60) - 6 }}>
                {fmtHour(h.hour, settings.time_format)}
              </div>
            ),
          )}

          {scale.segments
            .filter((s) => s.band)
            .map((s) => (
              <button
                key={s.from}
                type="button"
                onClick={() => setNightOpen(!nightOpen)}
                style={{ top: s.y, height: s.height }}
                className="absolute inset-x-0 z-0 flex items-center justify-center bg-foreground/85 text-[10.5px] tracking-wide text-background hover:bg-foreground"
              >
                {nightOpen ? "Hide the quiet hours" : "Nighttime"}
              </button>
            ))}

          <div className="absolute inset-y-0 left-2 right-10">
            {timed.map((e, i) => {
              const top = scale.y(minutesOfDay(Math.max(e.starts_at, msAt(cursor, 0))));
              const bottom = scale.y(minutesOfDay(Math.min(e.ends_at, msAt(cursor, 1439))));
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
                  onToggleDone={() => setDone.mutate({ id: e.id, done: !e.done, date: cursor })}
                />
              );
            })}
          </div>

          {drag && (
            <div
              className="pointer-events-none absolute left-2 right-10 z-20 rounded-[5px] border border-dashed border-foreground/50 bg-foreground/5"
              style={{ top: scale.y(Math.min(drag.from, drag.to)), height: Math.max(scale.y(Math.max(drag.from, drag.to)) - scale.y(Math.min(drag.from, drag.to)), 10) }}
            />
          )}

          {today && (
            <div className="pointer-events-none absolute inset-x-0 z-20" style={{ top: scale.y(nowMin) }}>
              <div className="h-px bg-red-500" />
              <div className="absolute left-0 -top-[3px] size-[7px] rounded-full bg-red-500" />
            </div>
          )}

          {timed.length === 0 && (
            <p className="absolute inset-x-0 top-1/2 -translate-y-1/2 text-center text-[12px] text-tertiary">Nothing scheduled. Drag to make something.</p>
          )}
        </div>
      </div>

      {countdowns.length > 0 && (
        <div className="shrink-0 overflow-x-auto border-t border-border px-3 py-1.5">
          <div className="flex items-center gap-3 whitespace-nowrap text-[11px] text-muted-foreground">
            {countdowns.map((e: CalEvent) => (
              <button key={e.id} type="button" onClick={() => openEvent(e)} className="shrink-0 hover:text-foreground">
                <span className="tnum">{countdownLabel(e.start_date ?? "")}</span> until {e.emoji} {e.title}
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

function fmtHour(hour: number, format: "12" | "24"): string {
  if (format === "24") return `${String(hour).padStart(2, "0")}:00`;
  const h = hour % 12 === 0 ? 12 : hour % 12;
  return `${h}${hour < 12 || hour === 24 ? "am" : "pm"}`;
}
