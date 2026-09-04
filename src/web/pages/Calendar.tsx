import { useEffect } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { CalendarProvider, useCalendar } from "../calendar/CalendarContext";
import { CalendarToolbar, step } from "../calendar/CalendarToolbar";
import { WeekView } from "../calendar/WeekView";
import { DayRibbon } from "../calendar/DayRibbon";
import { YearView } from "../calendar/YearView";
import { EventSheet } from "../calendar/EventSheet";
import { useKeys } from "../lib/keys";
import { overlayOpen, useFocusRegion } from "../lib/focusStore";
import { addDays, msAt } from "../lib/caldate";

export default function CalendarPage() {
  return (
    <CalendarProvider>
      <CalendarInner />
    </CalendarProvider>
  );
}

function CalendarInner() {
  const { view, setView, cursor, setCursor, today, settings, createEvent, editor, reveal } = useCalendar();
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

  // ↑ ↓ walk the calendar; ← → keep their meaning everywhere else in the app — out to the sidebar
  // and over to the assistant — so the calendar deliberately does not claim them.
  //
  // The region check matters: while focus is in the sidebar its own ↑ ↓ walk the nav, and both
  // listeners sit on the window, so without this the calendar moved a week for every nav step.
  const region = useFocusRegion();
  const ok = () => !overlayOpen() && !editor;
  // The arrows are the only keys the sidebar also wants, so they alone check where focus is.
  const arrowOk = () => ok() && region === "content";
  useKeys({
    ArrowUp: () => arrowOk() && setCursor(step(view, cursor, -1, settings.week_start)),
    ArrowDown: () => arrowOk() && setCursor(step(view, cursor, 1, settings.week_start)),
    t: () => ok() && reveal(today),
    d: () => ok() && setView("days"),
    w: () => ok() && setView("week"),
    y: () => ok() && setView("year"),
    n: () => ok() && createEvent({ starts_at: msAt(cursor, 9 * 60), ends_at: msAt(cursor, 10 * 60) }),
    j: () => ok() && nav(`/journal/${cursor}`),
    b: () => ok() && nav("/habits"),
    PageUp: () => arrowOk() && setCursor(addDays(cursor, -7)),
    PageDown: () => arrowOk() && setCursor(addDays(cursor, 7)),
  });

  return (
    <div className="flex h-full min-h-0 flex-col">
      <CalendarToolbar />
      {view === "year" ? (
        <YearView />
      ) : view === "days" ? (
        <div className="flex min-h-0 flex-1"><DayRibbon full /></div>
      ) : (
        <div className="flex min-h-0 flex-1"><WeekView /></div>
      )}
      <EventSheet />
    </div>
  );
}
