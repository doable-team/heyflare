/**
 * Calendar date helpers.
 *
 * Two value shapes travel through the calendar UI:
 *   - a "key": a `YYYY-MM-DD` string, the identity of a day in the user's own timezone.
 *   - an "instant": epoch milliseconds, as the API sends every timed value.
 *
 * Everything here works in local wall time — a key is turned into a Date at local midnight,
 * never UTC midnight, so a birthday lands on the same square wherever you open the app.
 */
import {
  addDays as dfAddDays,
  differenceInCalendarDays,
  format,
  isWeekend as dfIsWeekend,
  parseISO,
  startOfMonth,
  startOfWeek,
} from "date-fns";

/** date-fns' weekStartsOn is a 0-6 union; our settings carry a plain number. */
type WeekDay = 0 | 1 | 2 | 3 | 4 | 5 | 6;
function wk(weekStart: number): WeekDay {
  return (((weekStart % 7) + 7) % 7) as WeekDay;
}

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;

// ---------- Keys ----------

/** Today, as a `YYYY-MM-DD` key in local time. */
export function todayKey(): string {
  return dateKey(Date.now());
}

/** The local day an instant falls on. */
export function dateKey(ms: number): string {
  return format(new Date(ms), "yyyy-MM-dd");
}

/** Local midnight at the start of `key`. (parseISO reads a date-only string as local time.) */
export function keyToDate(key: string): Date {
  return parseISO(key);
}

/** `key` shifted by `n` calendar days (DST-safe: it moves days, not milliseconds). */
export function addDays(key: string, n: number): string {
  return dateKey(dfAddDays(keyToDate(key), n).getTime());
}

/** Calendar days from `a` to `b`. Positive when `b` is later. */
export function daysBetween(a: string, b: string): number {
  return differenceInCalendarDays(keyToDate(b), keyToDate(a));
}

/** The first day of the week containing `key`. `weekStart` 0 = Sunday, 1 = Monday. */
export function weekStartOf(key: string, weekStart: number): string {
  return dateKey(startOfWeek(keyToDate(key), { weekStartsOn: wk(weekStart) }).getTime());
}

/** The 7 keys of the week containing `key`. */
export function weekDays(key: string, weekStart: number): string[] {
  const start = weekStartOf(key, weekStart);
  return Array.from({ length: 7 }, (_, i) => addDays(start, i));
}

/**
 * 6x7 = 42 keys covering the month containing `key`, starting on `weekStart`.
 * Always six rows so the grid never changes height as you page through months.
 */
export function monthGrid(key: string, weekStart: number): string[] {
  const first = dateKey(startOfMonth(keyToDate(key)).getTime());
  const start = weekStartOf(first, weekStart);
  return Array.from({ length: 42 }, (_, i) => addDays(start, i));
}

/** The month `key` belongs to, as its own key (the 1st). */
/** Every date key from `from` to `to`, inclusive. Capped so a bad range can't allocate forever. */
export function dateRange(from: string, to: string): string[] {
  const span = daysBetween(from, to);
  if (!Number.isFinite(span) || span < 0) return [];
  const out: string[] = [];
  for (let i = 0; i <= Math.min(span, 3660); i++) out.push(addDays(from, i));
  return out;
}

export function monthStartOf(key: string): string {
  return dateKey(startOfMonth(keyToDate(key)).getTime());
}

// ---------- Predicates ----------

export function isToday(key: string): boolean {
  return key === todayKey();
}

/** Strictly before today. Today itself is not past. */
export function isPast(key: string): boolean {
  return key < todayKey();
}

/** Strictly after today. */
export function isFuture(key: string): boolean {
  return key > todayKey();
}

export function isWeekend(key: string): boolean {
  return dfIsWeekend(keyToDate(key));
}

export function isSameMonth(a: string, b: string): boolean {
  return a.slice(0, 7) === b.slice(0, 7);
}

// ---------- Labels ----------

/** "January 2026" */
export function monthLabel(key: string): string {
  return format(keyToDate(key), "MMMM yyyy");
}

/** "Thu 15" */
export function dayLabel(key: string): string {
  return format(keyToDate(key), "EEE d");
}

/** "Thursday" */
export function weekdayLabel(key: string): string {
  return format(keyToDate(key), "EEEE");
}

/** "Thu" */
export function weekdayShort(key: string): string {
  return format(keyToDate(key), "EEE");
}

/** "15" */
export function dayNumber(key: string): string {
  return format(keyToDate(key), "d");
}

/** "Thursday, 15 January 2026" — for headers and tooltips. */
export function longDayLabel(key: string): string {
  return format(keyToDate(key), "EEEE, d MMMM yyyy");
}

// ---------- Times ----------

/** "9:30 AM" (12h) or "09:30" (24h). */
export function fmtTime(ms: number, format12: "12" | "24"): string {
  return format(new Date(ms), format12 === "24" ? "HH:mm" : "h:mm a");
}

/**
 * "9:30 – 10:30 AM", "09:30 – 10:30", "All day".
 * In 12-hour form a shared meridiem is printed once, the way a calendar chip reads best.
 */
export function fmtTimeRange(startMs: number, endMs: number, allDay: boolean, format12: "12" | "24"): string {
  if (allDay) return "All day";
  const start = fmtTime(startMs, format12);
  if (endMs <= startMs) return start;
  const end = fmtTime(endMs, format12);
  if (format12 === "12") {
    const sm = start.slice(-2);
    // Same meridiem and same day: "9:30 – 10:30 AM".
    if (sm === end.slice(-2) && dateKey(startMs) === dateKey(endMs)) return `${start.slice(0, -3)} – ${end}`;
  }
  return `${start} – ${end}`;
}

/** "1h 30m", "45m", "2h", "1d 4h". */
export function fmtDuration(ms: number): string {
  const total = Math.max(0, Math.round(ms / MINUTE));
  if (total < 1) return "0m";
  const days = Math.floor(total / (24 * 60));
  const hours = Math.floor((total % (24 * 60)) / 60);
  const mins = total % 60;
  const parts: string[] = [];
  if (days) parts.push(`${days}d`);
  if (hours) parts.push(`${hours}h`);
  if (mins && !days) parts.push(`${mins}m`);
  return parts.join(" ") || "0m";
}

/** Minutes since local midnight — the y coordinate of an instant in a day column. */
export function minutesOfDay(ms: number): number {
  const d = new Date(ms);
  return d.getHours() * 60 + d.getMinutes();
}

/** The instant at `minutes` past local midnight on `key`. DST-safe (built from wall-clock parts). */
export function msAt(key: string, minutes: number): number {
  const d = keyToDate(key);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate(), 0, minutes, 0, 0).getTime();
}

/** Local midnight at the start of `key`, in ms. */
export function startOfDayMs(key: string): number {
  return msAt(key, 0);
}

/** The first instant of the next day (exclusive end of `key`). */
export function endOfDayMs(key: string): number {
  return msAt(addDays(key, 1), 0);
}

// ---------- Relative ----------

/** "Today", "Tomorrow", "Yesterday" — otherwise "" so callers can fall back to a date label. */
export function relativeDay(key: string): string {
  const d = daysBetween(todayKey(), key);
  if (d === 0) return "Today";
  if (d === 1) return "Tomorrow";
  if (d === -1) return "Yesterday";
  return "";
}

/** "in 12 days", "tomorrow", "today", "yesterday", "8 days ago" — for countdown events. */
export function countdownLabel(key: string): string {
  const d = daysBetween(todayKey(), key);
  if (d === 0) return "today";
  if (d === 1) return "tomorrow";
  if (d === -1) return "yesterday";
  if (d > 0) return `in ${d} days`;
  return `${-d} days ago`;
}

// ---------- Overlap layout ----------

/** Zero-length (and sub-15-minute) events still need room to be clicked. */
const MIN_SLOT = 15 * MINUTE;

export interface ColumnSlot {
  /** 0-based column within the cluster. */
  column: number;
  /** How many columns the cluster ended up needing; width is 1 / columns. */
  columns: number;
}

/**
 * Lay overlapping timed events into side-by-side columns — HEY's rule that events sit
 * beside each other rather than stacking on top of one another.
 *
 * The algorithm, in three moves:
 *
 *  1. Sort by start time, then by longest first. Long events therefore claim the leftmost
 *     column of a cluster, and the short ones that begin inside them fan out to the right,
 *     which is what reads naturally.
 *
 *  2. Walk the sorted list and cut it into *clusters*: a maximal run of events where each
 *     one starts before everything seen so far has ended. `clusterEnd` tracks the furthest
 *     end reached; the moment an event starts at or after it, nothing in the run can
 *     overlap anything that follows, so the cluster is closed and widths are frozen.
 *     Width is decided per cluster, not globally, so one busy hour does not squeeze the
 *     rest of the day.
 *
 *  3. Inside a cluster, place each event in the first column whose previous occupant has
 *     already ended (`colEnds[c] <= start`); if every column is still busy, open a new one.
 *     This is the classic interval-partitioning greedy, and it uses the minimum possible
 *     number of columns for the cluster.
 *
 * Ends are clamped up to `minMs` for overlap purposes only, so a zero-length event does
 * not silently vanish underneath its neighbour.
 *
 * `minMs` is how long the shortest drawable event *looks*, which is not how long it is: a view
 * that floors a block at some pixel height is drawing a 15-minute meeting as though it ran for an
 * hour, and two events that do not overlap in time then overlap on screen. Pass the floor the view
 * actually renders with — converted to milliseconds — and the columns will match what is drawn.
 *
 * @returns one `{ column, columns }` per input event, in the *input* order.
 */
export function layoutColumns<T extends { starts_at: number; ends_at: number }>(events: T[], minMs = MIN_SLOT): ColumnSlot[] {
  const out: ColumnSlot[] = events.map(() => ({ column: 0, columns: 1 }));
  if (events.length === 0) return out;

  const floor = Math.max(minMs, 0);
  // Index-carrying view so results can be written back in input order.
  const items = events.map((e, i) => {
    const start = e.starts_at;
    const end = Math.max(e.ends_at, start + floor);
    return { i, start, end };
  });

  items.sort((a, b) => a.start - b.start || b.end - a.end || a.i - b.i);

  // Members of the cluster currently being built, and when each column last freed up.
  let cluster: number[] = [];
  let colEnds: number[] = [];
  let clusterEnd = -Infinity;

  const flush = () => {
    const n = colEnds.length || 1;
    for (const idx of cluster) out[idx].columns = n;
    cluster = [];
    colEnds = [];
    clusterEnd = -Infinity;
  };

  for (const it of items) {
    // Nothing in the open cluster is still running: start a fresh one.
    if (it.start >= clusterEnd) flush();

    let col = colEnds.findIndex((end) => end <= it.start);
    if (col === -1) {
      col = colEnds.length;
      colEnds.push(it.end);
    } else {
      colEnds[col] = it.end;
    }

    out[it.i].column = col;
    cluster.push(it.i);
    if (it.end > clusterEnd) clusterEnd = it.end;
  }
  flush();

  return out;
}

/** Does this event touch `key` at all? Useful for slicing a range response into day columns. */
export function overlapsDay(e: { starts_at: number; ends_at: number }, key: string): boolean {
  return e.starts_at < endOfDayMs(key) && Math.max(e.ends_at, e.starts_at + MIN_SLOT) > startOfDayMs(key);
}

/** Fraction of the day (0-1) an instant sits at — the raw offset for a timeline column. */
export function dayFraction(ms: number): number {
  return minutesOfDay(ms) / (24 * 60);
}

export { MINUTE, HOUR, MIN_SLOT };
