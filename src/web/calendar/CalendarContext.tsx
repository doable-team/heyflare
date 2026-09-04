import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { useSearchParams } from "react-router-dom";
import type { CalEvent, Calendar, CalendarRange, CalendarSettings, CalendarView } from "@shared/types";
import { useCalendarRange, useCalendarSettings, useCalendarSources } from "../api";
import { addDays, daysBetween, minutesOfDay, todayKey, weekStartOf } from "../lib/caldate";
import { fitWindow, makeScale, type TimeScale } from "./scale";

/** What the event editor is currently holding: an existing occurrence, or a blank to fill in. */
export type EditorTarget =
  | { mode: "edit"; event: CalEvent }
  | { mode: "create"; prefill: Partial<CalEvent> & { starts_at: number; ends_at: number; all_day?: boolean } };

interface CalendarCtx {
  settings: CalendarSettings;
  calendars: Calendar[];
  view: CalendarView;
  setView: (v: CalendarView) => void;
  /** The day everything is anchored to. Changing it scrolls the strip. */
  cursor: string;
  setCursor: (d: string) => void;
  today: string;
  /** The loaded window, wider than what's on screen so scrolling stays quiet. */
  from: string;
  to: string;
  extend: (side: "start" | "end", days: number) => void;
  range: CalendarRange | undefined;
  loading: boolean;
  /** Timeline geometry, shared by every day column so the hour rules line up. */
  scale: TimeScale;
  nightOpen: boolean;
  setNightOpen: (b: boolean) => void;
  editor: EditorTarget | null;
  openEvent: (e: CalEvent) => void;
  createEvent: (prefill: Partial<CalEvent> & { starts_at: number; ends_at: number; all_day?: boolean }) => void;
  closeEditor: () => void;
  /** Events for one day, already filtered and split into all-day and timed. */
  eventsOn: (date: string) => { allDay: CalEvent[]; timed: CalEvent[] };
}

const Ctx = createContext<CalendarCtx | null>(null);

export const DEFAULT_SETTINGS: CalendarSettings = {
  timezone: "",
  week_start: 1,
  night_start: 22,
  night_end: 6,
  collapse_night: true,
  time_format: "12",
  default_view: "week",
  show_declined: false,
  cover_art: false,
};

const VIEWS: CalendarView[] = ["days", "week", "month", "year", "agenda"];

/** The window a view needs loaded around a date. Days and week grow as you scroll; the rest snap. */
function windowFor(view: CalendarView, date: string, weekStart: number): [string, string] {
  switch (view) {
    case "month": {
      const first = `${date.slice(0, 7)}-01`;
      return [addDays(weekStartOf(first, weekStart), -7), addDays(first, 48)];
    }
    case "year":
      return [`${date.slice(0, 4)}-01-01`, `${date.slice(0, 4)}-12-31`];
    case "agenda":
      return [addDays(date, -1), addDays(date, 120)];
    case "week":
      // The week scroll runs continuously, so it wants a deep window in both directions.
      return [addDays(weekStartOf(date, weekStart), -35), addDays(weekStartOf(date, weekStart), 70)];
    default:
      return [addDays(date, -7), addDays(date, 21)];
  }
}

export function CalendarProvider({ children }: { children: ReactNode }) {
  const [params, setParams] = useSearchParams();
  const settingsQ = useCalendarSettings();
  const sourcesQ = useCalendarSources();
  const settings = settingsQ.data ?? DEFAULT_SETTINGS;

  const today = todayKey();
  const urlDate = params.get("d");
  const [cursor, setCursorState] = useState<string>(urlDate && /^\d{4}-\d{2}-\d{2}$/.test(urlDate) ? urlDate : today);
  const urlView = params.get("v") as CalendarView | null;
  const [view, setViewState] = useState<CalendarView>(urlView && VIEWS.includes(urlView) ? urlView : "days");
  const [nightOpen, setNightOpen] = useState(false);
  const [editor, setEditor] = useState<EditorTarget | null>(null);

  // The default view is a preference, not a redirect: it only applies before the user picks one.
  const [viewTouched, setViewTouched] = useState(!!urlView);
  useEffect(() => {
    if (!viewTouched && settingsQ.data && VIEWS.includes(settingsQ.data.default_view)) setViewState(settingsQ.data.default_view);
  }, [settingsQ.data, viewTouched]);

  // The loaded window is kept in state rather than derived from the cursor: walking one day at a
  // time must not re-slice the strip under the scroll position. It only moves when you near an edge.
  const [win, setWin] = useState<[string, string]>(() => windowFor(view, cursor, settings.week_start));
  useEffect(() => {
    setWin(windowFor(view, cursor, settings.week_start));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [view, settings.week_start, view === "year" ? cursor.slice(0, 4) : view === "month" ? cursor.slice(0, 7) : ""]);
  const [from, to] = win;

  const rangeQ = useCalendarRange(from, to);

  const setCursor = useCallback(
    (d: string) => {
      setCursorState(d);
      setWin(([a, b]) => {
        if (daysBetween(a, d) < 7) return [addDays(d, -21), b];
        if (daysBetween(d, b) < 7) return [a, addDays(d, 45)];
        return [a, b];
      });
      setParams((p) => {
        const next = new URLSearchParams(p);
        if (d === todayKey()) next.delete("d");
        else next.set("d", d);
        return next;
      }, { replace: true });
    },
    [setParams],
  );
  const setView = useCallback(
    (v: CalendarView) => {
      setViewState(v);
      setViewTouched(true);
      setParams((p) => {
        const next = new URLSearchParams(p);
        if (v === "days") next.delete("v");
        else next.set("v", v);
        return next;
      }, { replace: true });
    },
    [setParams],
  );
  const extend = useCallback((side: "start" | "end", days: number) => {
    setWin(([a, b]) => (side === "start" ? [addDays(a, -days), b] : [a, addDays(b, days)]));
  }, []);

  // The timeline is fitted to the hours the loaded events actually occupy and stretched to fill the
  // space on screen, so a day reads as a full day rather than a few boxes adrift in a 24-hour chart.
  const [timelineHeight, setTimelineHeight] = useState(0);
  const fitted = useMemo(() => fitWindow(rangeQ.data?.events ?? [], minutesOfDay), [rangeQ.data]);
  const scale = useMemo(
    () => makeScale({ from: fitted.from, to: fitted.to, collapse: settings.collapse_night && !nightOpen, fit: timelineHeight || undefined }),
    [fitted, settings.collapse_night, nightOpen, timelineHeight],
  );

  // One pass over the window's events, bucketed by day, so a column render is a lookup.
  const byDay = useMemo(() => {
    const map = new Map<string, { allDay: CalEvent[]; timed: CalEvent[] }>();
    for (const e of rangeQ.data?.events ?? []) {
      if (e.all_day) {
        // A multi-day banner appears on every day it covers.
        const start = e.start_date ?? dateOf(e.starts_at);
        const end = e.end_date ?? start;
        const span = Math.min(daysBetween(start, end), 400);
        for (let i = 0; i <= span; i++) bucket(map, addDays(start, i)).allDay.push(e);
      } else {
        // A timed event that crosses midnight is drawn on every day it touches, clipped per column.
        const startKey = dateOf(e.starts_at);
        const endKey = dateOf(Math.max(e.ends_at - 1, e.starts_at));
        const span = Math.min(Math.max(daysBetween(startKey, endKey), 0), 14);
        for (let i = 0; i <= span; i++) bucket(map, addDays(startKey, i)).timed.push(e);
      }
    }
    return map;
  }, [rangeQ.data]);

  const eventsOn = useCallback((date: string) => byDay.get(date) ?? EMPTY_DAY, [byDay]);

  const value: CalendarCtx = {
    settings,
    calendars: sourcesQ.data?.calendars ?? [],
    view,
    setView,
    cursor,
    setCursor,
    today,
    from,
    to,
    extend,
    range: rangeQ.data,
    loading: rangeQ.isLoading || settingsQ.isLoading,
    scale,
    nightOpen,
    setNightOpen,
    editor,
    openEvent: (e) => setEditor({ mode: "edit", event: e }),
    createEvent: (prefill) => setEditor({ mode: "create", prefill }),
    closeEditor: () => setEditor(null),
    eventsOn,
  };
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useCalendar(): CalendarCtx {
  const v = useContext(Ctx);
  if (!v) throw new Error("useCalendar outside CalendarProvider");
  return v;
}

const EMPTY_DAY = { allDay: [] as CalEvent[], timed: [] as CalEvent[] };

function bucket(map: Map<string, { allDay: CalEvent[]; timed: CalEvent[] }>, date: string) {
  let d = map.get(date);
  if (!d) {
    d = { allDay: [], timed: [] };
    map.set(date, d);
  }
  return d;
}

function dateOf(ms: number): string {
  const d = new Date(ms);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
