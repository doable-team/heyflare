import { useEffect, useMemo } from "react";
import { useNavigate } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { ChevronLeft, ChevronRight, Plus } from "lucide-react";
import type { CalEvent } from "@shared/types";
import { cn } from "@/lib/utils";
import { invalidateCalendar, useCalendarSourceMutations } from "../api";
import { CalendarProvider, useCalendar } from "../calendar/CalendarContext";
import { EventSheet } from "../calendar/EventSheet";
import { dateKey, dayNumber, fmtTime, isPast, isSameMonth, isToday, isWeekend, keyToDate, monthGrid, monthLabel, msAt, relativeDay, weekdayLabel, weekdayShort } from "../lib/caldate";
import { Screen } from "./Screen";
import { TAB_BAR_H } from "./TabBar";
import { usePullToRefresh } from "./usePullToRefresh";
import { useSwipe } from "./useSwipe";

/**
 * The phone's calendar home: one month at a time, with the selected day's agenda underneath.
 *
 * The desktop filmstrip of day columns is deliberately *not* what this is. A horizontal strip of
 * 120px columns is unusable under a thumb, so the phone reads the month as a grid — each day a
 * tappable square with at most three dots standing in for its events — and puts the detail in a
 * list below, where a finger can actually hit it. One tap selects a day, a second opens it.
 */
export default function MobileCalendar() {
  return (
    <CalendarProvider>
      <MonthScreen />
    </CalendarProvider>
  );
}

/** Same month, same day-of-month where it exists (Jan 31 → Feb 28), so a step keeps the agenda. */
function stepMonth(key: string, delta: number): string {
  const [y, m, d] = key.split("-").map(Number);
  const last = new Date(y, m + delta, 0).getDate();
  return dateKey(new Date(y, m - 1 + delta, Math.min(d, last)).getTime());
}

function MonthScreen() {
  const { cursor, setCursor, setView, view, today, settings, range, eventsOn, createEvent, openEvent } = useCalendar();
  const nav = useNavigate();
  const qc = useQueryClient();
  const { syncAll } = useCalendarSourceMutations();

  // The provider sizes its loaded window from the view; a month screen wants the month's window.
  useEffect(() => {
    // The phone draws its own month grid; "week" is only here to pull a wide enough window.
    if (view !== "week") setView("week");
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const ptr = usePullToRefresh(async () => {
    try {
      await syncAll.mutateAsync();
    } catch {
      /* a source that won't sync shouldn't swallow the refresh */
    }
    invalidateCalendar(qc);
  });

  const swipe = useSwipe({
    threshold: 64,
    onLeft: () => setCursor(stepMonth(cursor, 1)),
    onRight: () => setCursor(stepMonth(cursor, -1)),
  });

  const grid = useMemo(() => monthGrid(cursor, settings.week_start), [cursor, settings.week_start]);
  const journalDays = useMemo(() => new Set((range?.days ?? []).filter((d) => d.has_journal).map((d) => d.date)), [range]);

  const selected = eventsOn(cursor);
  // A committed swipe throws dx to ±innerWidth; the month has already changed under it, so snap
  // back to 0 without a transition rather than sliding the new month in from the wrong edge.
  const committing = Math.abs(swipe.dx) >= (typeof window === "undefined" ? 9e9 : window.innerWidth * 0.9);

  return (
    <Screen
      title={<span className="tnum">{monthLabel(cursor)}</span>}
      left={
        <button
          type="button"
          onClick={() => setCursor(today)}
          className={cn("h-11 px-2 text-[15px] active:opacity-60", isSameMonth(cursor, today) ? "text-muted-foreground" : "text-foreground")}
        >
          Today
        </button>
      }
      right={
        <div className="flex items-center">
          <button type="button" onClick={() => setCursor(stepMonth(cursor, -1))} aria-label="Previous month" className="size-11 flex items-center justify-center text-foreground active:opacity-60">
            <ChevronLeft size={22} />
          </button>
          <button type="button" onClick={() => setCursor(stepMonth(cursor, 1))} aria-label="Next month" className="size-11 flex items-center justify-center text-foreground active:opacity-60">
            <ChevronRight size={22} />
          </button>
        </div>
      }
    >
      <div {...ptr.handlers}>
        {ptr.indicator}

        <div className="grid grid-cols-7 px-1">
          {grid.slice(0, 7).map((k) => (
            <div key={k} className="h-6 flex items-center justify-center text-[10px] uppercase tracking-wide text-tertiary">
              {weekdayShort(k)}
            </div>
          ))}
        </div>

        <div
          {...swipe.handlers}
          className="px-1 touch-pan-y select-none [-webkit-touch-callout:none]"
          style={{
            transform: `translateX(${committing ? 0 : swipe.dx}px)`,
            transition: swipe.dragging || committing ? "none" : "transform 200ms cubic-bezier(.2,.8,.2,1)",
          }}
        >
          <div key={cursor.slice(0, 7)} className="grid grid-cols-7 animate-in fade-in duration-150" style={{ gridTemplateRows: "repeat(6, minmax(0, 1fr))", height: "clamp(228px, 42dvh, 396px)" }}>
            {grid.map((k) => (
              <DayCell
                key={k}
                date={k}
                month={cursor}
                selected={k === cursor}
                journal={journalDays.has(k)}
                onTap={() => {
                  // A month swipe must not also land as a tap on whichever square it started on.
                  if (swipe.consumeClick()) return;
                  if (k === cursor) nav(`/calendar/${k}`);
                  else setCursor(k);
                }}
              />
            ))}
          </div>
        </div>

        <section className="mt-3 px-4">
          <button type="button" onClick={() => nav(`/calendar/${cursor}`)} className="w-full flex items-baseline gap-2 pb-1 text-left active:opacity-60">
            <span className="text-[13px] font-semibold">
              {weekdayLabel(cursor)} {dayNumber(cursor)}
            </span>
            {relativeDay(cursor) && <span className="text-[11px] text-muted-foreground">{relativeDay(cursor)}</span>}
            <span className="flex-1" />
            <ChevronRight size={14} className="text-tertiary shrink-0" />
          </button>

          {selected.allDay.length === 0 && selected.timed.length === 0 ? (
            <div className="border-t border-border/60 py-6 text-[13px] text-muted-foreground">Nothing scheduled.</div>
          ) : (
            <div>
              {selected.allDay.map((e) => (
                <AgendaRow key={e.id} e={e} when="All day" onTap={() => openEvent(e)} />
              ))}
              {selected.timed.map((e) => (
                <AgendaRow key={e.id} e={e} when={fmtTime(e.starts_at, settings.time_format)} onTap={() => openEvent(e)} />
              ))}
            </div>
          )}
        </section>
      </div>

      <button
        type="button"
        onClick={() => createEvent({ starts_at: msAt(cursor, 9 * 60), ends_at: msAt(cursor, 10 * 60) })}
        aria-label={`New event on ${cursor}`}
        className="fixed right-4 z-40 size-12 rounded-full bg-foreground text-background shadow-md flex items-center justify-center active:scale-95 transition-transform"
        style={{ bottom: `calc(${TAB_BAR_H + 16}px + env(safe-area-inset-bottom))` }}
      >
        <Plus size={22} />
      </button>

      <EventSheet />
    </Screen>
  );
}

/** One square of the month grid: the date, up to three event dots, and the day's marks. */
function DayCell({ date, month, selected, journal, onTap }: { date: string; month: string; selected: boolean; journal: boolean; onTap: () => void }) {
  const { eventsOn } = useCalendar();
  const { allDay, timed } = eventsOn(date);
  // All-day items read as filled dots, timed ones as hollow — three at most, whatever the day holds.
  const dots = [...allDay.map(() => true), ...timed.map(() => false)].slice(0, 3);
  const today = isToday(date);
  const inMonth = isSameMonth(date, month);

  return (
    <button
      type="button"
      onClick={onTap}
      aria-current={today ? "date" : undefined}
      aria-label={`${keyToDate(date).toDateString()}, ${allDay.length + timed.length} events`}
      className={cn(
        "relative flex flex-col items-center gap-1 pt-1.5 border-t border-border/50 active:bg-muted",
        isWeekend(date) && "bg-muted/40",
        selected && "bg-muted",
        !inMonth && "opacity-40",
      )}
    >
      <span
        className={cn(
          "size-6 flex items-center justify-center rounded-full text-[12px] tnum leading-none",
          today ? "bg-foreground text-background font-semibold" : isPast(date) ? "text-muted-foreground" : "text-foreground",
          selected && !today && "ring-1 ring-foreground/40",
        )}
      >
        {dayNumber(date)}
      </span>
      {/* A day with a journal entry: a small square in the corner, so it never reads as an event dot. */}
      {journal && <span className="absolute top-1 right-1 size-[3px] rounded-[1px] bg-foreground/50" />}
      <span className="flex items-center gap-[3px] h-[5px]">
        {dots.map((solid, i) => (
          <span key={i} className={cn("size-[5px] rounded-full", solid ? "bg-foreground/75" : "border border-foreground/55")} />
        ))}
      </span>
    </button>
  );
}

function AgendaRow({ e, when, onTap }: { e: CalEvent; when: string; onTap: () => void }) {
  return (
    <button type="button" onClick={onTap} className={cn("w-full flex items-start gap-3 border-t border-border/60 py-2.5 text-left active:bg-muted", e.rsvp === "declined" && "opacity-50")}>
      <span className="w-[58px] shrink-0 pt-px text-[11px] tnum text-muted-foreground">{when}</span>
      <span className="min-w-0 flex-1">
        <span className={cn("block text-[13px] truncate", e.done && "line-through text-muted-foreground")}>
          {e.emoji ? `${e.emoji} ` : ""}
          {e.title || "(no title)"}
        </span>
        {e.location && <span className="block text-[11px] text-muted-foreground truncate">{e.location}</span>}
      </span>
    </button>
  );
}
