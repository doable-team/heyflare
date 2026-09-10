import { useEffect, useRef } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { CalendarProvider, useCalendar } from "../calendar/CalendarContext";
import { CalendarToolbar } from "../calendar/CalendarToolbar";
import { WeekView } from "../calendar/WeekView";
import { DayView } from "../calendar/DayView";
import { MonthView } from "../calendar/MonthView";
import { YearView } from "../calendar/YearView";
import { EventSheet } from "../calendar/EventSheet";
import type { GridPager } from "../calendar/TimeGrid";
import { useKeys } from "../lib/keys";
import { arrows, overlayOpen, useFocusRegion } from "../lib/focusStore";
import { addDays, addMonths, msAt } from "../lib/caldate";

export default function CalendarPage() {
  return (
    <CalendarProvider>
      <CalendarInner />
    </CalendarProvider>
  );
}

function CalendarInner() {
  const { view, setView, cursor, setCursor, today, createEvent, editor, reveal } = useCalendar();
  const nav = useNavigate();
  const loc = useLocation();
  const pager: GridPager = useRef(null);

  // "Create event" on an email lands here with a prefill in router state. Consume it once, then
  // clear it so a refresh or a Back doesn't reopen the composer.
  useEffect(() => {
    const prefill = (loc.state as { newEvent?: { starts_at: number; ends_at: number } } | null)?.newEvent;
    if (!prefill) return;
    createEvent(prefill);
    nav(loc.pathname + loc.search, { replace: true, state: null });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loc.state]);

  // Opening the calendar lands on today. A URL that names a date is left alone.
  useEffect(() => {
    if (!new URLSearchParams(loc.search).get("d")) reveal(today);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // The calendar walks days with ← →, which would otherwise step out to the sidebar and over to
  // the assistant; claiming them keeps the shell's hands off while focus is in the content.
  useEffect(() => arrows.claim(), []);

  // While focus is in the sidebar its own ↑ ↓ walk the nav, and both listeners sit on the window,
  // so the movement keys check where focus is.
  const region = useFocusRegion();
  const ok = () => !overlayOpen() && !editor;
  const moveOk = () => ok() && region === "content";
  const grid = view === "week" || view === "days";
  useKeys({
    ArrowLeft: () => moveOk() && setCursor(addDays(cursor, -1)),
    ArrowRight: () => moveOk() && setCursor(addDays(cursor, 1)),
    ArrowUp: () => moveOk() && setCursor(addDays(cursor, -7)),
    ArrowDown: () => moveOk() && setCursor(addDays(cursor, 7)),
    PageUp: () => moveOk() && (grid ? pager.current?.(-1) : setCursor(addMonths(cursor, view === "year" ? -12 : -1))),
    PageDown: () => moveOk() && (grid ? pager.current?.(1) : setCursor(addMonths(cursor, view === "year" ? 12 : 1))),
    Enter: () => moveOk() && !grid && setView("days"),
    t: () => ok() && reveal(today),
    d: () => ok() && setView("days"),
    w: () => ok() && setView("week"),
    m: () => ok() && setView("month"),
    y: () => ok() && setView("year"),
    n: () => ok() && createEvent({ starts_at: msAt(cursor, 9 * 60), ends_at: msAt(cursor, 10 * 60) }),
    j: () => ok() && nav(`/journal/${cursor}`),
    b: () => ok() && nav("/habits"),
  });

  return (
    <div className="flex h-full min-h-0 flex-col">
      <CalendarToolbar />
      <div className="mt-3 flex min-h-0 flex-1 flex-col overflow-hidden rounded-lg border border-border bg-background">
        {view === "year" ? <YearView /> : view === "month" ? <MonthView /> : view === "days" ? <DayView pager={pager} /> : <WeekView pager={pager} />}
      </div>
      <EventSheet />
    </div>
  );
}
