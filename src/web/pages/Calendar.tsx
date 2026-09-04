import { useEffect } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { CalendarProvider, useCalendar } from "../calendar/CalendarContext";
import { CalendarToolbar, step } from "../calendar/CalendarToolbar";
import { WeekScroll } from "../calendar/WeekScroll";
import { DayPane } from "../calendar/DayPane";
import { MonthView } from "../calendar/MonthView";
import { YearView } from "../calendar/YearView";
import { AgendaView } from "../calendar/AgendaView";
import { EventSheet } from "../calendar/EventSheet";
import { useKeys } from "../lib/keys";
import { arrows, focus, overlayOpen } from "../lib/focusStore";
import { scrollPageBy } from "../lib/cardKeys";
import { addDays, msAt } from "../lib/caldate";

export default function CalendarPage() {
  return (
    <CalendarProvider>
      <CalendarInner />
    </CalendarProvider>
  );
}

function CalendarInner() {
  const { view, setView, cursor, setCursor, today, settings, createEvent, editor } = useCalendar();
  const nav = useNavigate();
  const loc = useLocation();

  // "Create event" on an email lands here with a prefill in router state. Consume it once, then
  // clear it so a refresh or a Back doesn't reopen the composer.
  useEffect(() => {
    const prefill = (loc.state as { newEvent?: { starts_at: number; ends_at: number } } | null)?.newEvent;
    if (!prefill) return;
    createEvent(prefill);
    nav(loc.pathname + loc.search, { replace: true, state: null });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loc.state]);

  // The calendar walks days with ← →, so it takes the arrow keys off the sidebar while it's open.
  useEffect(() => arrows.claim(), []);

  const ok = () => !overlayOpen() && !editor;
  useKeys({
    ArrowLeft: () => ok() && setCursor(step(view, cursor, -1, settings.week_start)),
    ArrowRight: () => ok() && setCursor(step(view, cursor, 1, settings.week_start)),
    ArrowUp: () => ok() && scrollPageBy(-0.25),
    ArrowDown: () => ok() && scrollPageBy(0.25),
    t: () => ok() && setCursor(today),
    d: () => ok() && setView("days"),
    w: () => ok() && setView("week"),
    m: () => ok() && setView("month"),
    y: () => ok() && setView("year"),
    a: () => ok() && setView("agenda"),
    n: () => ok() && createEvent({ starts_at: msAt(cursor, 9 * 60), ends_at: msAt(cursor, 10 * 60) }),
    j: () => ok() && nav(`/journal/${cursor}`),
    b: () => ok() && nav("/habits"),
    Escape: () => !editor && focus.toSidebar(),
    PageUp: () => ok() && setCursor(addDays(cursor, -7)),
    PageDown: () => ok() && setCursor(addDays(cursor, 7)),
  });

  return (
    <div className="flex h-[calc(100dvh-6.5rem)] min-h-96 flex-col">
      <CalendarToolbar />
      {view === "month" ? (
        <MonthView />
      ) : view === "year" ? (
        <YearView />
      ) : view === "agenda" ? (
        <AgendaView />
      ) : view === "days" ? (
        <div className="flex min-h-0 flex-1"><DayPane full /></div>
      ) : (
        // The week scroll is the home view; the day it has selected sits beside it where there's room.
        <div className="flex min-h-0 flex-1 gap-2.5">
          <div className="flex min-h-0 min-w-0 flex-1 flex-col"><WeekScroll /></div>
          <div className="hidden w-[380px] shrink-0 xl:block"><DayPane /></div>
        </div>
      )}
      <EventSheet />
    </div>
  );
}
