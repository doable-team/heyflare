import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { useSearchParams } from "react-router-dom";
import type { CalEvent, Calendar, CalendarRange, CalendarSettings, CalendarView } from "@shared/types";
import { useCalendarRange, useCalendarSettings, useCalendarSources } from "../api";
import { addDays, addMonths, daysBetween, minutesOfDay, monthEndOf, monthStartOf, todayKey } from "../lib/caldate";
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
  /** The day everything is anchored to. */
  cursor: string;
  setCursor: (d: string) => void;
  today: string;
  /** The loaded window: the cursor's month and its neighbours, or the whole year in the year view. */
  from: string;
  to: string;
  range: CalendarRange | undefined;
  loading: boolean;
  /** Timeline geometry for the mobile day, which still draws the fitted, night-folded scale. */
  scale: TimeScale;
  nightOpen: boolean;
  setNightOpen: (b: boolean) => void;
  /**
   * Ask the current view to bring a date on screen. Distinct from `setCursor` because "Today" has
   * to work when the cursor is *already* on today and you have simply scrolled away from it —
   * setting the cursor to the value it already holds changes nothing.
   */
  reveal: (date: string) => void;
  revealAt: { date: string; nonce: number };
  /** The month a view is showing, `YYYY-MM`. */
  visibleMonth: string;
  reportVisibleMonth: (month: string) => void;
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

const VIEWS: CalendarView[] = ["days", "week", "month", "year"];

/** The window a view needs loaded around a date: the date's month and one either side, or its year. */
function windowFor(view: CalendarView, date: string): [string, string] {
  if (view === "year") return [`${date.slice(0, 4)}-01-01`, `${date.slice(0, 4)}-12-31`];
  return [monthStartOf(addMonths(date, -1)), monthEndOf(addMonths(date, 1))];
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
  const [view, setViewState] = useState<CalendarView>(urlView && VIEWS.includes(urlView) ? urlView : "week");
  const [nightOpen, setNightOpen] = useState(false);
  const [editor, setEditor] = useState<EditorTarget | null>(null);
  const [revealAt, setRevealAt] = useState<{ date: string; nonce: number }>(() => ({ date: cursor, nonce: 0 }));
  const [visibleMonth, setVisibleMonth] = useState<string>(() => cursor.slice(0, 7));

  // The default view is a preference, not a redirect: it only applies before the user picks one.
  const [viewTouched, setViewTouched] = useState(!!urlView);
  useEffect(() => {
    if (!viewTouched && settingsQ.data && VIEWS.includes(settingsQ.data.default_view)) setViewState(settingsQ.data.default_view);
  }, [settingsQ.data, viewTouched]);

  // The window only changes when the cursor leaves the month (or, in the year, the year), so a
  // walk through a week never re-asks for the same three months.
  const period = view === "year" ? cursor.slice(0, 4) : cursor.slice(0, 7);
  const [from, to] = useMemo(() => windowFor(view, cursor), [view, period]); // eslint-disable-line react-hooks/exhaustive-deps

  const rangeQ = useCalendarRange(from, to);

  const setCursor = useCallback(
    (d: string) => {
      setCursorState(d);
      setVisibleMonth(d.slice(0, 7));
      setParams(withParam("d", d === todayKey() ? null : d), { replace: true });
    },
    [setParams],
  );
  const reveal = useCallback(
    (d: string) => {
      setCursor(d);
      setRevealAt({ date: d, nonce: Date.now() });
    },
    [setCursor],
  );

  const setView = useCallback(
    (v: CalendarView) => {
      setViewState(v);
      setViewTouched(true);
      setParams(withParam("v", v), { replace: true });
    },
    [setParams],
  );

  // The mobile day's timeline: fitted to the hours the loaded events occupy, night folded.
  const fitted = useMemo(() => fitWindow(rangeQ.data?.events ?? [], minutesOfDay), [rangeQ.data]);
  const scale = useMemo(
    () => makeScale({ from: fitted.from, to: fitted.to, collapse: settings.collapse_night && !nightOpen }),
    [fitted, settings.collapse_night, nightOpen],
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
    for (const d of map.values()) d.timed.sort((a, b) => a.starts_at - b.starts_at || b.ends_at - a.ends_at);
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
    range: rangeQ.data,
    loading: rangeQ.isLoading || settingsQ.isLoading,
    scale,
    nightOpen,
    setNightOpen,
    reveal,
    revealAt,
    visibleMonth,
    reportVisibleMonth: setVisibleMonth,
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

/**
 * The URL with one param changed, read from the address bar rather than from the hook: two key
 * presses can land before React re-renders, and the second would otherwise rebuild the query
 * from the first's stale snapshot and undo it.
 */
function withParam(key: string, value: string | null): URLSearchParams {
  const next = new URLSearchParams(window.location.search);
  if (value === null) next.delete(key);
  else next.set(key, value);
  return next;
}

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
