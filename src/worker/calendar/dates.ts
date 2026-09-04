// Timezone-aware date maths for the calendar. The worker ships no date library (date-fns exists but
// is web-only), so everything here is built on Intl.DateTimeFormat — Workers run full ICU, so every
// IANA zone name resolves.
//
// Two vocabularies live side by side and never blur together:
//   - an *instant* is epoch milliseconds, a point on the timeline
//   - a *date* is "YYYY-MM-DD", a square on a wall calendar with no zone attached
// Every function that crosses between them takes a `tz`; the ones that stay on one side do not.
// An unknown or empty `tz` silently means UTC — a bad zone in a subscribed feed must not 500.

const DAY = 86400000;
const MAX_RANGE_DAYS = 10000;

// ---------- Intl plumbing ----------

// Constructing an Intl.DateTimeFormat dominates the cost of everything below, and the range
// endpoints call these in a loop over a window of days, so keep one formatter per zone forever.
const fmtCache = new Map<string, Intl.DateTimeFormat>();
const zoneOk = new Map<string, boolean>();

function makeFormat(tz: string): Intl.DateTimeFormat {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function formatterFor(tz: string): Intl.DateTimeFormat {
  const key = tz || "UTC";
  const hit = fmtCache.get(key);
  if (hit) return hit;
  let f: Intl.DateTimeFormat;
  try {
    f = makeFormat(key);
  } catch {
    f = makeFormat("UTC"); // cached under the bad name too, so we only ever throw once per zone
  }
  fmtCache.set(key, f);
  return f;
}

/** True when Intl accepts `tz` as a zone name (IANA id, or "UTC"). Cheap after the first call. */
export function isValidZone(tz: string): boolean {
  if (!tz) return false;
  const hit = zoneOk.get(tz);
  if (hit !== undefined) return hit;
  let ok = true;
  try {
    makeFormat(tz);
  } catch {
    ok = false;
  }
  zoneOk.set(tz, ok);
  return ok;
}

interface Wall {
  y: number;
  mo: number; // 1-12
  d: number;
  h: number;
  mi: number;
  s: number;
}

/** The wall-clock reading an observer in `tz` gets for an instant. */
function wallOf(ms: number, tz: string): Wall {
  const parts = formatterFor(tz).formatToParts(new Date(ms));
  const w: Wall = { y: 1970, mo: 1, d: 1, h: 0, mi: 0, s: 0 };
  for (const p of parts) {
    switch (p.type) {
      case "year":
        w.y = parseInt(p.value, 10);
        break;
      case "month":
        w.mo = parseInt(p.value, 10);
        break;
      case "day":
        w.d = parseInt(p.value, 10);
        break;
      case "hour":
        w.h = parseInt(p.value, 10);
        break;
      case "minute":
        w.mi = parseInt(p.value, 10);
        break;
      case "second":
        w.s = parseInt(p.value, 10);
        break;
    }
  }
  if (w.h === 24) w.h = 0; // some ICU builds render midnight as "24" under hour12:false
  return w;
}

/** Date.UTC, but years 0-99 stay themselves instead of sliding into the 1900s. */
function utcOf(y: number, mo: number, d: number, h = 0, mi = 0, s = 0): number {
  const t = Date.UTC(y, mo - 1, d, h, mi, s);
  if (y >= 0 && y < 100) {
    const dt = new Date(t);
    dt.setUTCFullYear(y);
    return dt.getTime();
  }
  return t;
}

// The DST-correct offset trick: render the instant in the target zone, then read those parts back
// as if they were UTC. The gap between that and the instant itself is the zone's offset *at that
// instant*, transitions and historical offsets included.
function offsetAt(ms: number, tz: string): number {
  const w = wallOf(ms, tz);
  return utcOf(w.y, w.mo, w.d, w.h, w.mi, w.s) - Math.floor(ms / 1000) * 1000;
}

// ---------- date strings ----------

function pad2(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}

function pad4(n: number): string {
  return n < 0 ? `-${String(-n).padStart(4, "0")}` : String(n).padStart(4, "0");
}

function stamp(y: number, mo: number, d: number): string {
  return `${pad4(y)}-${pad2(mo)}-${pad2(d)}`;
}

/** Strict "YYYY-MM-DD" → [y, m, d], or null. Rejects 2026-02-30 and friends. */
function ymd(date: string): [number, number, number] | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date);
  if (!m) return null;
  const y = +m[1];
  const mo = +m[2];
  const d = +m[3];
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  const dt = new Date(utcOf(y, mo, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() + 1 !== mo || dt.getUTCDate() !== d) return null;
  return [y, mo, d];
}

/** Days since epoch for a date string, or NaN. The zone-free spine of all calendar arithmetic. */
function dayNum(date: string): number {
  const p = ymd(date);
  return p ? utcOf(p[0], p[1], p[2]) / DAY : NaN;
}

function fromDayNum(n: number): string {
  const dt = new Date(n * DAY);
  return stamp(dt.getUTCFullYear(), dt.getUTCMonth() + 1, dt.getUTCDate());
}

export function isValidDate(date: string): boolean {
  return ymd(date) !== null;
}

// ---------- instants <-> dates ----------

/** "YYYY-MM-DD" for an instant as seen in `tz` ("" = UTC). */
export function dateKey(ms: number, tz: string): string {
  if (!Number.isFinite(ms)) return "";
  const w = wallOf(ms, tz);
  return stamp(w.y, w.mo, w.d);
}

/**
 * Epoch ms for a wall-clock time on `date` in `tz`. `minutes` is minutes past midnight, and may run
 * past 1440 or below 0 to mean the neighbouring days. NaN for a malformed date.
 *
 * The offset has to be measured at the *answer*, not at the guess, or a time within a day of a DST
 * transition lands an hour out: guess with the offset at the pretend-UTC instant, then re-measure at
 * the guess and correct. One correction settles every real-world zone; times inside a spring-forward
 * gap resolve to the instant just after the jump.
 */
export function zonedTime(date: string, minutes: number, tz: string): number {
  const p = ymd(date);
  if (!p) return NaN;
  const wall = utcOf(p[0], p[1], p[2]) + Math.round(minutes) * 60000;
  const first = wall - offsetAt(wall, tz);
  const off = offsetAt(first, tz);
  const second = wall - off;
  if (second === first) return first;
  // Re-measure once more: if the correction moved us back across the same transition, keep the
  // first answer rather than oscillating.
  return offsetAt(second, tz) === off ? second : first;
}

/** Epoch ms of 00:00:00.000 on `date` in `tz`. */
export function startOfDay(date: string, tz: string): number {
  return zonedTime(date, 0, tz);
}

/**
 * Epoch ms of the last millisecond of `date` in `tz` — 23:59:59.999 on an ordinary day. Derived
 * from the next day's midnight so a day that gains or loses an hour still ends where it should.
 */
export function endOfDay(date: string, tz: string): number {
  const next = startOfDay(addDays(date, 1), tz);
  if (Number.isFinite(next)) return next - 1;
  const start = startOfDay(date, tz);
  return Number.isFinite(start) ? start + DAY - 1 : NaN;
}

/** Local wall-clock minutes past midnight for an instant in `tz`. */
export function minutesOfDay(ms: number, tz: string): number {
  if (!Number.isFinite(ms)) return 0;
  const w = wallOf(ms, tz);
  return w.h * 60 + w.mi;
}

// ---------- calendar arithmetic (no timezone involved) ----------

export function addDays(date: string, n: number): string {
  const base = dayNum(date);
  if (Number.isNaN(base)) return date;
  return fromDayNum(base + Math.round(n));
}

export function daysBetween(a: string, b: string): number {
  const x = dayNum(a);
  const y = dayNum(b);
  if (Number.isNaN(x) || Number.isNaN(y)) return 0;
  return y - x;
}

/** 0 = Sunday … 6 = Saturday. */
export function weekdayOf(date: string): number {
  const n = dayNum(date);
  if (Number.isNaN(n)) return 0;
  return (((n + 4) % 7) + 7) % 7; // 1970-01-01 was a Thursday
}

/** First day of `date`'s week; weekStart is 0 (Sunday) or 1 (Monday). */
export function weekStartOf(date: string, weekStart: number): string {
  const ws = ((Math.round(weekStart) % 7) + 7) % 7;
  const back = (weekdayOf(date) - ws + 7) % 7;
  return addDays(date, -back);
}

/** Every date string from `from` to `to` inclusive; [] when reversed or malformed. */
export function dateRange(from: string, to: string): string[] {
  const start = dayNum(from);
  const end = dayNum(to);
  if (Number.isNaN(start) || Number.isNaN(end) || end < start) return [];
  const span = Math.min(end - start, MAX_RANGE_DAYS);
  const out: string[] = new Array(span + 1);
  for (let i = 0; i <= span; i++) out[i] = fromDayNum(start + i);
  return out;
}
