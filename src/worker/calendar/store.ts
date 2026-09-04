// The calendar's data layer: row → API mappers, the windowed range query every view is drawn from,
// and the write path that keeps D1 and Google in step.
//
// Recurrence lives on a master row as an RRULE and is expanded per request window (`rangeFor`).
// A single occurrence that was edited is stored as its own row carrying `master_id` +
// `occurrence_date`; one that was deleted is a date appended to the master's `exdates`.
// Google calendars are asked for pre-expanded instances by the sync layer, so masters here are in
// practice `local` and `ics` — but nothing below assumes that.

import type { Env } from "../env";
import type { AccountRow } from "../db";
import { uid, now, inClause, chunk, safeJson, logSync } from "../db";
import type {
  CalendarRow,
  EventRow,
  HabitRow,
  CalendarDayRow,
  FlexTaskRow,
  TimeEntryRow,
  CalendarSettingsRow,
} from "./types";
import type {
  CalEvent,
  Calendar,
  CalendarDay,
  CalendarRange,
  CalendarSettings,
  CalendarView,
  EventAttendee,
  FlexTask,
  Habit,
  Reminder,
  Rsvp,
  TimeEntry,
} from "@shared/types";
import {
  addDays,
  dateKey,
  dateRange,
  daysBetween,
  endOfDay,
  isValidDate,
  minutesOfDay,
  startOfDay,
  weekStartOf,
  weekdayOf,
  zonedTime,
} from "./dates";
import type { IcsEventInput } from "./ical";
import { buildIcs, expandRRule } from "./ical";
import { createRemoteEvent, deleteRemoteEvent, setRemoteRsvp, updateRemoteEvent } from "./google";

/** Hard ceiling on expanded occurrences per request, so a decade-wide window can't blow up. */
const MAX_OCCURRENCES = 5000;
/** How far back a habit streak is willing to walk. */
const STREAK_LOOKBACK = 400;

const KINDS = ["event", "birthday", "anniversary", "todo"] as const;
const STATUSES = ["confirmed", "tentative", "cancelled"] as const;
const RSVPS = ["", "needsAction", "accepted", "declined", "tentative"] as const;

// ---------- Mappers ----------

export function toCalendar(r: CalendarRow, extra?: { account_email?: string | null; event_count?: number }): Calendar {
  return {
    id: r.id,
    account_id: r.account_id ?? null,
    account_email: extra?.account_email ?? null,
    source: r.source,
    remote_id: r.remote_id ?? null,
    url: r.url ?? null,
    name: r.name,
    description: r.description,
    color: r.color,
    timezone: r.timezone,
    visible: !!r.visible,
    writable: !!r.writable,
    is_default: !!r.is_default,
    position: r.position,
    last_synced_at: r.last_synced_at,
    sync_status: r.sync_status,
    sync_error: r.sync_error,
    ...(extra?.event_count !== undefined ? { event_count: extra.event_count } : {}),
  };
}

/**
 * One drawable event. `occurrence` is supplied only for an instance expanded out of a recurring
 * master: it moves the times, restamps the all-day dates, and gives the composite `<row>@<date>` id
 * the routes address a single instance by.
 */
export function toEvent(
  r: EventRow,
  cal: CalendarRow,
  occurrence?: { date: string; startsAt: number; endsAt: number; done: boolean } | null
): CalEvent {
  // An all-day master spanning N days keeps that span on every occurrence.
  const span = r.all_day && r.start_date && r.end_date ? Math.max(0, daysBetween(r.start_date, r.end_date)) : 0;
  return {
    id: occurrence ? `${r.id}@${occurrence.date}` : r.id,
    event_id: r.id,
    occurrence_date: occurrence ? occurrence.date : r.occurrence_date ?? null,
    calendar_id: r.calendar_id,
    calendar_name: cal.name,
    calendar_color: cal.color,
    source: cal.source,
    writable: cal.source !== "ics" && (cal.source === "local" || !!cal.writable),
    kind: r.kind,
    title: r.title,
    description: r.description,
    location: r.location,
    emoji: r.emoji,
    all_day: !!r.all_day,
    starts_at: occurrence ? occurrence.startsAt : r.starts_at,
    ends_at: occurrence ? occurrence.endsAt : r.ends_at,
    start_date: occurrence ? (r.all_day ? occurrence.date : null) : r.start_date,
    end_date: occurrence ? (r.all_day ? addDays(occurrence.date, span) : null) : r.end_date,
    timezone: r.timezone,
    rrule: r.rrule ?? null,
    recurring: !!r.rrule || !!r.master_id || !!seriesMasterId(r.remote_id),
    // A Google-expanded series: repeating, but with no RRULE here to narrow a save down with.
    series: !r.rrule && !r.master_id && !!seriesMasterId(r.remote_id),
    status: r.status,
    busy: !!r.busy,
    countdown: !!r.countdown,
    circled: !!r.circled,
    organizer: r.organizer_email ? { email: r.organizer_email, name: r.organizer_name } : null,
    attendees: safeJson<EventAttendee[]>(r.attendees_json, []),
    rsvp: (r.rsvp || "") as Rsvp,
    conference_url: r.conference_url,
    url: r.url,
    reminders: safeJson<Reminder[]>(r.reminders_json, []),
    thread_id: r.thread_id ?? null,
    done: occurrence ? occurrence.done : !!r.done_at,
    created_at: r.created_at,
    updated_at: r.updated_at,
  };
}

export function toHabit(r: HabitRow, completions: string[], streak: number): Habit {
  return {
    id: r.id,
    name: r.name,
    icon: r.icon,
    color: r.color,
    days: parseDays(r.days),
    position: r.position,
    archived: !!r.archived,
    completions,
    streak,
  };
}

export function toFlexTask(r: FlexTaskRow): FlexTask {
  return { id: r.id, week_start: r.week_start, title: r.title, done: !!r.done_at, position: r.position };
}

export function toTimeEntry(r: TimeEntryRow): TimeEntry {
  return { id: r.id, title: r.title, event_id: r.event_id ?? null, started_at: r.started_at, ended_at: r.ended_at };
}

export function toCalendarDay(r: CalendarDayRow): CalendarDay {
  return {
    date: r.date,
    label: r.label,
    cover_url: r.cover_url,
    cover_id: r.cover_id ?? null,
    cover_position: r.cover_position || "50% 50%",
    has_journal: !!(r.journal_html && r.journal_html.trim()),
    journal_updated_at: r.journal_updated_at,
  };
}

export function toSettings(r: CalendarSettingsRow): CalendarSettings {
  return {
    timezone: r.timezone,
    week_start: r.week_start,
    night_start: r.night_start,
    night_end: r.night_end,
    collapse_night: !!r.collapse_night,
    time_format: r.time_format === "24" ? "24" : "12",
    default_view: (["days", "week", "year"].includes(r.default_view) ? r.default_view : "week") as CalendarView,
    show_declined: !!r.show_declined,
    cover_art: !!r.cover_art,
  };
}

function parseDays(s: string): number[] {
  return [...new Set((s ?? "").split(",").map((x) => Number(x.trim())).filter((n) => Number.isInteger(n) && n >= 0 && n <= 6))].sort();
}

// ---------- Ids ----------

/**
 * `<row id>` or `<row id>@<YYYY-MM-DD>`. Splits on the *last* `@` and only treats the tail as an
 * occurrence when it really is a date, so an id that happens to contain `@` stays intact.
 */
export function parseEventId(id: string): { id: string; occurrence: string | null } {
  const at = id.lastIndexOf("@");
  if (at <= 0) return { id, occurrence: null };
  const tail = id.slice(at + 1);
  if (!isValidDate(tail)) return { id, occurrence: null };
  return { id: id.slice(0, at), occurrence: tail };
}

// ---------- Settings, calendars, ownership ----------

export async function getSettings(db: D1Database, userId: string): Promise<CalendarSettingsRow> {
  const row = await db.prepare(`SELECT * FROM calendar_settings WHERE user_id = ?`).bind(userId).first<CalendarSettingsRow>();
  if (row) return row;
  // First touch: materialise the schema defaults so every later read is a plain SELECT. The view
  // is named explicitly because the column's own default still says 'days' — SQLite cannot alter a
  // default in place, and the week is the calendar's home.
  await db.prepare(`INSERT OR IGNORE INTO calendar_settings (user_id, default_view, updated_at) VALUES (?, 'week', ?)`).bind(userId, now()).run();
  const fresh = await db.prepare(`SELECT * FROM calendar_settings WHERE user_id = ?`).bind(userId).first<CalendarSettingsRow>();
  return (
    fresh ?? {
      user_id: userId,
      timezone: "",
      week_start: 1,
      night_start: 22,
      night_end: 6,
      collapse_night: 1,
      time_format: "12",
      default_view: "week",
      show_declined: 0,
      cover_art: 0,
      updated_at: now(),
    }
  );
}

/** Flags take a boolean from the API layer or the raw 0/1 of a row; both coerce the same way. */
export type SettingsPatch = Partial<{
  timezone: string;
  week_start: number;
  night_start: number;
  night_end: number;
  collapse_night: boolean | number;
  time_format: string;
  default_view: string;
  show_declined: boolean | number;
  cover_art: boolean | number;
}>;

export async function putSettings(db: D1Database, userId: string, patch: SettingsPatch): Promise<CalendarSettingsRow> {
  const cur = await getSettings(db, userId);
  const next: CalendarSettingsRow = {
    ...cur,
    timezone: patch.timezone !== undefined ? String(patch.timezone).trim().slice(0, 64) : cur.timezone,
    week_start: patch.week_start !== undefined ? clampInt(patch.week_start, 0, 6, cur.week_start) : cur.week_start,
    night_start: patch.night_start !== undefined ? clampInt(patch.night_start, 0, 23, cur.night_start) : cur.night_start,
    night_end: patch.night_end !== undefined ? clampInt(patch.night_end, 0, 23, cur.night_end) : cur.night_end,
    collapse_night: patch.collapse_night !== undefined ? (patch.collapse_night ? 1 : 0) : cur.collapse_night,
    time_format: patch.time_format !== undefined ? (String(patch.time_format) === "24" ? "24" : "12") : cur.time_format,
    default_view:
      patch.default_view !== undefined && ["days", "week", "year"].includes(String(patch.default_view))
        ? String(patch.default_view)
        : cur.default_view,
    show_declined: patch.show_declined !== undefined ? (patch.show_declined ? 1 : 0) : cur.show_declined,
    cover_art: patch.cover_art !== undefined ? (patch.cover_art ? 1 : 0) : cur.cover_art,
    updated_at: now(),
  };
  await db
    .prepare(
      `UPDATE calendar_settings SET timezone = ?, week_start = ?, night_start = ?, night_end = ?, collapse_night = ?,
         time_format = ?, default_view = ?, show_declined = ?, cover_art = ?, updated_at = ? WHERE user_id = ?`
    )
    .bind(
      next.timezone,
      next.week_start,
      next.night_start,
      next.night_end,
      next.collapse_night,
      next.time_format,
      next.default_view,
      next.show_declined,
      next.cover_art,
      next.updated_at,
      userId
    )
    .run();
  return next;
}

export async function listCalendars(db: D1Database, userId: string): Promise<CalendarRow[]> {
  const r = await db.prepare(`SELECT * FROM calendars WHERE user_id = ? ORDER BY position, created_at, name`).bind(userId).all<CalendarRow>();
  return r.results ?? [];
}

export async function ownedCalendar(db: D1Database, userId: string, id: string): Promise<CalendarRow | null> {
  return (await db.prepare(`SELECT * FROM calendars WHERE id = ? AND user_id = ?`).bind(id, userId).first<CalendarRow>()) ?? null;
}

export async function ownedEvent(db: D1Database, userId: string, id: string): Promise<EventRow | null> {
  return (await db.prepare(`SELECT * FROM events WHERE id = ? AND user_id = ?`).bind(id, userId).first<EventRow>()) ?? null;
}

// ---------- The range query ----------

export async function rangeFor(env: Env, userId: string, from: string, to: string, opts?: { all?: boolean }): Promise<CalendarRange> {
  const db = env.DB;
  if (!isValidDate(from) || !isValidDate(to) || to < from) throw new Error("bad_range");
  const settings = await getSettings(db, userId);
  const tz = settings.timezone || "UTC";

  // Widen by a day on each side: an event that starts late on the day before, or an all-day item
  // whose UTC midnight lands outside a far-from-UTC local day, still has to be drawn.
  const wFrom = addDays(from, -1);
  const wTo = addDays(to, 1);
  const windowStart = startOfDay(wFrom, tz);
  const windowEnd = endOfDay(wTo, tz);

  const allCals = await listCalendars(db, userId);
  const cals = opts?.all ? allCals : allCals.filter((c) => !!c.visible);
  const calById = new Map(cals.map((c) => [c.id, c]));
  const events: CalEvent[] = [];

  if (cals.length) {
    const ic = inClause(cals.map((c) => c.id));
    // Cancelled never draws; declined only when the user asked to see it.
    const hide = `AND status <> 'cancelled'${settings.show_declined ? "" : " AND rsvp <> 'declined'"}`;

    // 1. Plain rows overlapping the window. Per-occurrence override rows (master_id set, rrule null)
    //    come through here too, which is exactly where they belong.
    const plain = await db
      .prepare(
        `SELECT * FROM events WHERE user_id = ? AND calendar_id IN ${ic.sql} AND rrule IS NULL
           AND starts_at <= ? AND ends_at >= ? ${hide}`
      )
      .bind(userId, ...ic.params, windowEnd, windowStart)
      .all<EventRow>();

    // 2. Recurring masters that could reach into the window. There is no upper bound on a series,
    //    so anything that started by the end of the window is a candidate.
    const masters = await db
      .prepare(`SELECT * FROM events WHERE user_id = ? AND calendar_id IN ${ic.sql} AND rrule IS NOT NULL AND starts_at <= ? ${hide}`)
      .bind(userId, ...ic.params, windowEnd)
      .all<EventRow>();

    const masterRows = masters.results ?? [];
    const masterIds = masterRows.map((m) => m.id);

    // Occurrences replaced by an override row, and completions for repeating todos. Overrides are
    // loaded regardless of the window: one that was *moved* out of it still suppresses its slot.
    const overridden = new Set<string>();
    const completed = new Set<string>();
    for (const part of chunk(masterIds, 90)) {
      const oc = inClause(part);
      const ov = await db
        .prepare(`SELECT master_id, occurrence_date FROM events WHERE user_id = ? AND master_id IN ${oc.sql} AND occurrence_date IS NOT NULL`)
        .bind(userId, ...oc.params)
        .all<{ master_id: string; occurrence_date: string }>();
      for (const o of ov.results ?? []) overridden.add(`${o.master_id}|${o.occurrence_date}`);
      const cp = await db
        .prepare(`SELECT event_id, date FROM event_completions WHERE event_id IN ${oc.sql} AND date >= ? AND date <= ?`)
        .bind(...oc.params, wFrom, wTo)
        .all<{ event_id: string; date: string }>();
      for (const c of cp.results ?? []) completed.add(`${c.event_id}|${c.date}`);
    }

    for (const r of plain.results ?? []) {
      const cal = calById.get(r.calendar_id);
      if (cal) events.push(toEvent(r, cal));
    }

    let budget = MAX_OCCURRENCES;
    for (const m of masterRows) {
      if (budget <= 0) break;
      const cal = calById.get(m.calendar_id);
      if (!cal || !m.rrule) continue;
      const dur = Math.max(0, m.ends_at - m.starts_at);
      const ex = (m.exdates ?? "").split(",").map((s) => s.trim()).filter(Boolean);
      // All-day series are anchored to UTC midnights, so their instance dates key off UTC.
      const keyTz = m.all_day ? "UTC" : tz;
      let starts: number[] = [];
      try {
        // Start the scan a duration early so a long occurrence that began before the window still lands.
        starts = expandRRule(m.rrule, m.starts_at, { tz: m.timezone || tz, allDay: !!m.all_day, from: windowStart - dur, to: windowEnd, exdates: ex, limit: budget });
      } catch {
        continue; // A malformed RRULE drops that series, never the whole request.
      }
      for (const s of starts) {
        if (budget <= 0) break;
        const date = dateKey(s, keyTz);
        if (ex.includes(date)) continue;
        if (overridden.has(`${m.id}|${date}`)) continue;
        budget--;
        events.push(toEvent(m, cal, { date, startsAt: s, endsAt: s + dur, done: completed.has(`${m.id}|${date}`) }));
      }
    }
  }

  // All-day items head their day; everything else is chronological.
  const dayOf = (e: CalEvent) => dateKey(e.starts_at, e.all_day ? "UTC" : tz);
  events.sort((a, b) => {
    const da = dayOf(a);
    const dbk = dayOf(b);
    if (da !== dbk) return da < dbk ? -1 : 1;
    if (a.all_day !== b.all_day) return a.all_day ? -1 : 1;
    if (a.starts_at !== b.starts_at) return a.starts_at - b.starts_at;
    return a.title.localeCompare(b.title);
  });

  const [habits, days, flex_tasks, time_entries] = await Promise.all([
    loadHabits(db, userId, from, to, tz),
    loadDays(db, userId, from, to),
    loadFlexTasks(db, userId, from, to, settings.week_start),
    loadTimeEntries(db, userId, windowStart, windowEnd),
  ]);

  return { from, to, events, habits, days, flex_tasks, time_entries };
}

async function loadHabits(db: D1Database, userId: string, from: string, to: string, tz: string): Promise<Habit[]> {
  const rows = (await db.prepare(`SELECT * FROM habits WHERE user_id = ? AND archived = 0 ORDER BY position, created_at`).bind(userId).all<HabitRow>()).results ?? [];
  if (!rows.length) return [];
  const today = dateKey(now(), tz);
  const since = addDays(today, -STREAK_LOOKBACK);
  const inWindow = new Map<string, string[]>();
  const recent = new Map<string, Set<string>>();
  for (const part of chunk(rows.map((h) => h.id), 90)) {
    const ic = inClause(part);
    // One query covers both jobs: the window the client draws, and the streak's walk back from today.
    const lo = since < from ? since : from;
    const hi = today > to ? today : to;
    const cs = await db
      .prepare(`SELECT habit_id, date FROM habit_completions WHERE habit_id IN ${ic.sql} AND date >= ? AND date <= ? ORDER BY date`)
      .bind(...ic.params, lo, hi)
      .all<{ habit_id: string; date: string }>();
    for (const c of cs.results ?? []) {
      const set = recent.get(c.habit_id) ?? new Set<string>();
      set.add(c.date);
      recent.set(c.habit_id, set);
      if (c.date >= from && c.date <= to) {
        const arr = inWindow.get(c.habit_id) ?? [];
        arr.push(c.date);
        inWindow.set(c.habit_id, arr);
      }
    }
  }
  return rows.map((h) => toHabit(h, inWindow.get(h.id) ?? [], streakFor(parseDays(h.days), recent.get(h.id) ?? new Set(), today)));
}

/** Consecutive scheduled days completed, walking back from today. Today itself gets a pass: the day isn't over. */
function streakFor(days: number[], done: Set<string>, today: string): number {
  if (!days.length) return 0;
  let n = 0;
  let d = today;
  for (let i = 0; i < STREAK_LOOKBACK; i++, d = addDays(d, -1)) {
    if (!days.includes(weekdayOf(d))) continue;
    if (done.has(d)) n++;
    else if (d !== today) break;
  }
  return n;
}

async function loadDays(db: D1Database, userId: string, from: string, to: string): Promise<CalendarDay[]> {
  const r = await db
    .prepare(`SELECT * FROM calendar_days WHERE user_id = ? AND date >= ? AND date <= ? ORDER BY date`)
    .bind(userId, from, to)
    .all<CalendarDayRow>();
  return (r.results ?? []).map(toCalendarDay);
}

async function loadFlexTasks(db: D1Database, userId: string, from: string, to: string, weekStart: number): Promise<FlexTask[]> {
  const weeks = [...new Set(dateRange(from, to).map((d) => weekStartOf(d, weekStart)))];
  const out: FlexTask[] = [];
  for (const part of chunk(weeks, 90)) {
    const ic = inClause(part);
    const r = await db
      .prepare(`SELECT * FROM flex_tasks WHERE user_id = ? AND week_start IN ${ic.sql} ORDER BY week_start, position, created_at`)
      .bind(userId, ...ic.params)
      .all<FlexTaskRow>();
    for (const t of r.results ?? []) out.push(toFlexTask(t));
  }
  return out;
}

async function loadTimeEntries(db: D1Database, userId: string, windowStart: number, windowEnd: number): Promise<TimeEntry[]> {
  const r = await db
    .prepare(`SELECT * FROM time_entries WHERE user_id = ? AND started_at <= ? AND (ended_at IS NULL OR ended_at >= ?) ORDER BY started_at`)
    .bind(userId, windowEnd, windowStart)
    .all<TimeEntryRow>();
  return (r.results ?? []).map(toTimeEntry);
}

// ---------- Write path ----------

export interface EventInput {
  calendar_id?: string;
  kind?: string;
  title?: string;
  description?: string;
  location?: string;
  emoji?: string;
  all_day?: boolean;
  starts_at?: number;
  ends_at?: number;
  start_date?: string | null;
  end_date?: string | null;
  timezone?: string;
  rrule?: string | null;
  status?: string;
  busy?: boolean;
  countdown?: boolean;
  circled?: boolean;
  attendees?: { email: string; name?: string; optional?: boolean }[];
  conference_url?: string;
  url?: string;
  reminders?: { minutes: number }[];
  thread_id?: string | null;
  message_id?: string | null;
}

/** The columns an EventInput can write. Ownership, recurrence links and sync state are set separately. */
interface EventFields {
  kind: EventRow["kind"];
  title: string;
  description: string;
  location: string;
  emoji: string;
  all_day: number;
  starts_at: number;
  ends_at: number;
  start_date: string | null;
  end_date: string | null;
  timezone: string;
  rrule: string | null;
  status: EventRow["status"];
  busy: number;
  countdown: number;
  circled: number;
  attendees_json: string;
  conference_url: string;
  url: string;
  reminders_json: string;
  thread_id: string | null;
  message_id: string | null;
}

function clampInt(v: unknown, lo: number, hi: number, fallback: number): number {
  const n = Math.round(Number(v));
  if (!Number.isFinite(n)) return fallback;
  return Math.min(hi, Math.max(lo, n));
}

function str(v: unknown, max: number, fallback: string): string {
  return v === undefined || v === null ? fallback : String(v).slice(0, max);
}

/** UTC midnight of a YYYY-MM-DD, or null when it isn't one. */
function utcMidnight(date: string | null | undefined): number | null {
  if (!date || !isValidDate(date)) return null;
  const ms = Date.parse(`${date}T00:00:00.000Z`);
  return Number.isFinite(ms) ? ms : null;
}

/** ICS basic UTC stamp, `YYYYMMDDTHHMMSSZ`. */
function icsUtc(ms: number): string {
  return new Date(ms).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}

/** Close an open-ended series at `untilMs`, dropping any UNTIL/COUNT it already carried. */
function withUntil(rrule: string, untilMs: number): string {
  const parts = rrule
    .replace(/^RRULE:/i, "")
    .split(";")
    .map((p) => p.trim())
    .filter((p) => p && !/^(UNTIL|COUNT)=/i.test(p));
  parts.push(`UNTIL=${icsUtc(untilMs)}`);
  return parts.join(";");
}

/** Where one occurrence of a master actually starts: same wall-clock minute, that date. */
function occurrenceStart(master: EventRow, date: string, tz: string): number {
  if (master.all_day) return utcMidnight(date) ?? master.starts_at;
  return zonedTime(date, minutesOfDay(master.starts_at, tz), tz);
}

/** A copy of a master with its times moved onto one occurrence — the seed for a split or a new series. */
function shiftToOccurrence(master: EventRow, date: string, tz: string): EventRow {
  const dur = Math.max(0, master.ends_at - master.starts_at);
  const s = occurrenceStart(master, date, tz);
  const span = master.all_day && master.start_date && master.end_date ? Math.max(0, daysBetween(master.start_date, master.end_date)) : 0;
  return {
    ...master,
    starts_at: s,
    ends_at: s + dur,
    start_date: master.all_day ? date : null,
    end_date: master.all_day ? addDays(date, span) : null,
  };
}

/**
 * Merge an input over a previous row (or over blank defaults for a create), clamping strings the way
 * the rest of the codebase does and normalising all-day items onto UTC midnights so the window query
 * in `rangeFor` treats them like everything else.
 */
function fieldsFrom(input: EventInput, prev: EventRow | null, tz: string): EventFields {
  const t = now();
  const f: EventFields = {
    kind: (KINDS as readonly string[]).includes(String(input.kind)) ? (input.kind as EventRow["kind"]) : prev?.kind ?? "event",
    title: str(input.title, 500, prev?.title ?? ""),
    description: str(input.description, 50_000, prev?.description ?? ""),
    location: str(input.location, 500, prev?.location ?? ""),
    emoji: str(input.emoji, 16, prev?.emoji ?? ""),
    all_day: input.all_day !== undefined ? (input.all_day ? 1 : 0) : prev?.all_day ?? 0,
    starts_at: input.starts_at !== undefined ? Math.round(Number(input.starts_at)) : prev?.starts_at ?? t,
    ends_at: input.ends_at !== undefined ? Math.round(Number(input.ends_at)) : prev?.ends_at ?? NaN,
    start_date: input.start_date !== undefined ? (input.start_date || null) : prev?.start_date ?? null,
    end_date: input.end_date !== undefined ? (input.end_date || null) : prev?.end_date ?? null,
    timezone: str(input.timezone, 64, prev?.timezone ?? ""),
    rrule: input.rrule !== undefined ? (input.rrule ? String(input.rrule).replace(/^RRULE:/i, "").slice(0, 1000) : null) : prev?.rrule ?? null,
    status: (STATUSES as readonly string[]).includes(String(input.status)) ? (input.status as EventRow["status"]) : prev?.status ?? "confirmed",
    busy: input.busy !== undefined ? (input.busy ? 1 : 0) : prev?.busy ?? 1,
    countdown: input.countdown !== undefined ? (input.countdown ? 1 : 0) : prev?.countdown ?? 0,
    circled: input.circled !== undefined ? (input.circled ? 1 : 0) : prev?.circled ?? 0,
    attendees_json: prev?.attendees_json ?? "[]",
    conference_url: str(input.conference_url, 2000, prev?.conference_url ?? ""),
    url: str(input.url, 2000, prev?.url ?? ""),
    reminders_json: prev?.reminders_json ?? "[]",
    thread_id: input.thread_id !== undefined ? (input.thread_id || null) : prev?.thread_id ?? null,
    message_id: input.message_id !== undefined ? (input.message_id || null) : prev?.message_id ?? null,
  };

  if (input.attendees !== undefined) {
    const list = (input.attendees ?? [])
      .slice(0, 200)
      .map((a) => {
        const email = String(a?.email ?? "").trim().toLowerCase().slice(0, 320);
        const out: EventAttendee = { email };
        if (a?.name) out.name = String(a.name).slice(0, 200);
        if (a?.optional) out.optional = true;
        return out;
      })
      .filter((a) => a.email.includes("@"));
    f.attendees_json = JSON.stringify(list);
  }
  if (input.reminders !== undefined) {
    const list = (input.reminders ?? [])
      .slice(0, 20)
      .map((r) => ({ minutes: clampInt(r?.minutes, 0, 40_320, 0) }))
      .filter((r) => Number.isFinite(r.minutes));
    f.reminders_json = JSON.stringify(list);
  }

  if (f.all_day) {
    // A birthday must land on the same date everywhere, so all-day rows are pinned to UTC midnight.
    const sd = (f.start_date && isValidDate(f.start_date) ? f.start_date : null) ?? dateKey(f.starts_at, "UTC");
    const ed = (f.end_date && isValidDate(f.end_date) ? f.end_date : null) ?? sd;
    f.start_date = sd;
    f.end_date = ed < sd ? sd : ed;
    if (input.starts_at === undefined) f.starts_at = utcMidnight(f.start_date) ?? f.starts_at;
    if (input.ends_at === undefined) f.ends_at = utcMidnight(f.end_date) ?? f.starts_at;
  } else {
    f.start_date = null;
    f.end_date = null;
    // A timed event with no end gets an hour; long enough to be visible, short enough to be obvious.
    if (!Number.isFinite(f.ends_at)) f.ends_at = f.starts_at + 3_600_000;
  }

  if (!Number.isFinite(f.starts_at) || !Number.isFinite(f.ends_at)) throw new Error("bad_time");
  if (f.ends_at < f.starts_at) throw new Error("bad_time");
  if (!f.timezone) f.timezone = tz;
  return f;
}

/** ICS feeds mirror someone else's calendar; a Google calendar we only have read access to is the same. */
function assertWritable(cal: CalendarRow): void {
  if (cal.source === "ics") throw new Error("read_only");
  if (cal.source === "google" && !cal.writable) throw new Error("read_only");
}

/**
 * Mirror a local write to Google. Best-effort by design: the D1 row is already committed, so a
 * remote failure is logged and swallowed rather than allowed to lose the user's edit.
 */
/**
 * Google is asked for `singleEvents=true`, so a repeating event arrives already expanded: one row
 * per occurrence, each with its own remote id and no RRULE of its own. Nothing in the schema then
 * says those rows belong together — which is why "delete all" used to remove exactly one Wednesday
 * and leave the other eighty-six behind.
 *
 * Two things tie a series back together. Every instance carries the same `iCalUID`
 * (`{masterId}@google.com`), and an instance's own id is `{masterId}_{YYYYMMDD}T{HHMMSS}Z`. The
 * second is what identifies a row as an instance at all; the first is what gathers its siblings.
 */
const GOOGLE_INSTANCE_ID = /_\d{8}T\d{6}Z$/;

/** The id of the repeating event this row is an occurrence of, or null if it is a one-off. */
export function seriesMasterId(remoteId: string | null | undefined): string | null {
  if (!remoteId || !GOOGLE_INSTANCE_ID.test(remoteId)) return null;
  const cut = remoteId.lastIndexOf("_");
  return cut > 0 ? remoteId.slice(0, cut) : null;
}

/** Deleting more instances than this one at a time is a mistake, not an intention. */
const SERIES_DELETE_CAP = 400;

async function mirrorGoogle<T>(env: Env, cal: CalendarRow, what: string, fn: (account: AccountRow) => Promise<T>): Promise<T | null> {
  if (cal.source !== "google") return null;
  try {
    const account = cal.account_id
      ? await env.DB.prepare(`SELECT * FROM accounts WHERE id = ?`).bind(cal.account_id).first<AccountRow>()
      : null;
    if (!account) throw new Error("no_account");
    return await fn(account);
  } catch (e) {
    await logSync(env.DB, cal.account_id, "error", `calendar ${what} (${cal.name || cal.id}): ${(e as Error)?.message ?? String(e)}`);
    return null;
  }
}

const INSERT_COLUMNS =
  `id, user_id, calendar_id, remote_id, ical_uid, kind, title, description, location, emoji, all_day, starts_at, ends_at,
   start_date, end_date, timezone, rrule, exdates, master_id, occurrence_date, status, busy, countdown, circled,
   organizer_email, organizer_name, attendees_json, rsvp, conference_url, url, reminders_json, thread_id, message_id,
   done_at, etag, created_at, updated_at`;

async function insertEvent(
  db: D1Database,
  userId: string,
  calendarId: string,
  f: EventFields,
  extra?: Partial<Pick<EventRow, "master_id" | "occurrence_date" | "exdates" | "ical_uid" | "organizer_email" | "organizer_name" | "rsvp" | "done_at">>
): Promise<EventRow> {
  const t = now();
  const row: EventRow = {
    id: uid(),
    user_id: userId,
    calendar_id: calendarId,
    remote_id: null,
    ical_uid: extra?.ical_uid ?? null,
    exdates: extra?.exdates ?? "",
    master_id: extra?.master_id ?? null,
    occurrence_date: extra?.occurrence_date ?? null,
    organizer_email: extra?.organizer_email ?? "",
    organizer_name: extra?.organizer_name ?? "",
    rsvp: extra?.rsvp ?? "",
    done_at: extra?.done_at ?? null,
    etag: null,
    created_at: t,
    updated_at: t,
    ...f,
  };
  await db
    .prepare(`INSERT INTO events (${INSERT_COLUMNS}) VALUES (${Array(37).fill("?").join(", ")})`)
    .bind(
      row.id, row.user_id, row.calendar_id, row.remote_id, row.ical_uid, row.kind, row.title, row.description, row.location,
      row.emoji, row.all_day, row.starts_at, row.ends_at, row.start_date, row.end_date, row.timezone, row.rrule, row.exdates,
      row.master_id, row.occurrence_date, row.status, row.busy, row.countdown, row.circled, row.organizer_email,
      row.organizer_name, row.attendees_json, row.rsvp, row.conference_url, row.url, row.reminders_json, row.thread_id,
      row.message_id, row.done_at, row.etag, row.created_at, row.updated_at
    )
    .run();
  return row;
}

async function updateEventRow(db: D1Database, row: EventRow, f: EventFields): Promise<EventRow> {
  const next: EventRow = { ...row, ...f, updated_at: now() };
  await db
    .prepare(
      `UPDATE events SET kind = ?, title = ?, description = ?, location = ?, emoji = ?, all_day = ?, starts_at = ?, ends_at = ?,
         start_date = ?, end_date = ?, timezone = ?, rrule = ?, status = ?, busy = ?, countdown = ?, circled = ?,
         attendees_json = ?, conference_url = ?, url = ?, reminders_json = ?, thread_id = ?, message_id = ?, updated_at = ?
       WHERE id = ?`
    )
    .bind(
      next.kind, next.title, next.description, next.location, next.emoji, next.all_day, next.starts_at, next.ends_at,
      next.start_date, next.end_date, next.timezone, next.rrule, next.status, next.busy, next.countdown, next.circled,
      next.attendees_json, next.conference_url, next.url, next.reminders_json, next.thread_id, next.message_id,
      next.updated_at, next.id
    )
    .run();
  return next;
}

/** The calendar a create lands on: the one asked for, else the default, else the first writable one. */
async function defaultCalendar(db: D1Database, userId: string, calendarId?: string): Promise<CalendarRow> {
  if (calendarId) {
    const cal = await ownedCalendar(db, userId, calendarId);
    if (!cal) throw new Error("no_calendar");
    return cal;
  }
  const def = await db
    .prepare(`SELECT * FROM calendars WHERE user_id = ? AND is_default = 1 AND source <> 'ics' ORDER BY position, created_at LIMIT 1`)
    .bind(userId)
    .first<CalendarRow>();
  if (def) return def;
  const first = await db
    .prepare(`SELECT * FROM calendars WHERE user_id = ? AND source <> 'ics' AND (writable = 1 OR source = 'local') ORDER BY position, created_at LIMIT 1`)
    .bind(userId)
    .first<CalendarRow>();
  if (!first) throw new Error("no_calendar");
  return first;
}

export async function createEvent(env: Env, userId: string, input: EventInput): Promise<CalEvent> {
  const db = env.DB;
  const settings = await getSettings(db, userId);
  const cal = await defaultCalendar(db, userId, input.calendar_id);
  assertWritable(cal);
  const f = fieldsFrom(input, null, cal.timezone || settings.timezone || "UTC");
  let row = await insertEvent(db, userId, cal.id, f);

  const remote = await mirrorGoogle(env, cal, "create", (account) => createRemoteEvent(env, cal, account, row));
  if (remote?.remote_id) {
    row = { ...row, remote_id: remote.remote_id, etag: remote.etag ?? null };
    await db.prepare(`UPDATE events SET remote_id = ?, etag = ? WHERE id = ?`).bind(row.remote_id, row.etag, row.id).run();
  }
  return toEvent(row, cal);
}

/**
 * Copy an event, or one occurrence of a repeating one, into a standalone event on the same
 * calendar. The copy is deliberately plain: no recurrence, no attendees, and no link back to the
 * mail it may have come from — duplicating is for "the same thing again", not for re-inviting a
 * room full of people or forking a series. It keeps its times, so the caller can move it.
 */
export async function duplicateEvent(env: Env, userId: string, id: string): Promise<CalEvent> {
  const db = env.DB;
  const parsed = parseEventId(id);
  const row = await ownedEvent(db, userId, parsed.id);
  if (!row) throw new Error("not_found");
  const cal = await ownedCalendar(db, userId, row.calendar_id);
  if (!cal) throw new Error("not_found");
  assertWritable(cal);

  // For one occurrence of a series, copy that occurrence's own times rather than the master's.
  let starts = row.starts_at;
  let ends = row.ends_at;
  let startDate = row.start_date;
  let endDate = row.end_date;
  if (row.rrule && parsed.occurrence && isValidDate(parsed.occurrence)) {
    const tz = row.timezone || cal.timezone || (await getSettings(db, userId)).timezone || "UTC";
    const span = row.ends_at - row.starts_at;
    const shifted = row.all_day
      ? Date.parse(`${parsed.occurrence}T00:00:00Z`)
      : zonedTime(parsed.occurrence, minutesOfDay(row.starts_at, tz), tz);
    starts = shifted;
    ends = shifted + span;
    if (row.all_day) {
      const days = row.start_date && row.end_date ? daysBetween(row.start_date, row.end_date) : 0;
      startDate = parsed.occurrence;
      endDate = addDays(parsed.occurrence, Math.max(0, days));
    }
  }

  return createEvent(env, userId, {
    calendar_id: cal.id,
    kind: row.kind,
    title: row.title,
    description: row.description,
    location: row.location,
    emoji: row.emoji,
    all_day: !!row.all_day,
    starts_at: starts,
    ends_at: ends,
    start_date: startDate,
    end_date: endDate,
    timezone: row.timezone,
    status: row.status,
    busy: !!row.busy,
    countdown: !!row.countdown,
    circled: !!row.circled,
    conference_url: row.conference_url,
    url: row.url,
    reminders: JSON.parse(row.reminders_json || "[]") as { minutes: number }[],
  });
}

/**
 * `scope: "this"` splits one occurrence into an override row; `"following"` closes the master with
 * UNTIL and starts a new series at the occurrence; `"all"` (the default) edits the master itself.
 * Scope only means anything for a row we expand ourselves — a plain row always takes the `"all"` path.
 */
export async function updateEvent(
  env: Env,
  userId: string,
  id: string,
  patch: EventInput,
  scope: "this" | "following" | "all" = "all"
): Promise<CalEvent> {
  const db = env.DB;
  const parsed = parseEventId(id);
  const row = await ownedEvent(db, userId, parsed.id);
  if (!row) throw new Error("not_found");
  const cal = await ownedCalendar(db, userId, row.calendar_id);
  if (!cal) throw new Error("not_found");
  assertWritable(cal);
  const settings = await getSettings(db, userId);
  const tz = row.timezone || cal.timezone || settings.timezone || "UTC";
  const occ = parsed.occurrence;

  if (row.rrule && occ && scope === "this") {
    // An override may already exist (this occurrence was edited before); patch it rather than fork again.
    const existing = await db
      .prepare(`SELECT * FROM events WHERE user_id = ? AND master_id = ? AND occurrence_date = ?`)
      .bind(userId, row.id, occ)
      .first<EventRow>();
    const seed = shiftToOccurrence(row, occ, tz);
    const f = fieldsFrom(patch, existing ?? seed, tz);
    f.rrule = null; // an override is a single instance, never a series
    if (existing) {
      const next = await updateEventRow(db, existing, f);
      await mirrorGoogle(env, cal, "update", (account) => updateRemoteEvent(env, cal, account, next));
      return toEvent(next, cal);
    }
    let fresh = await insertEvent(db, userId, cal.id, f, {
      master_id: row.id,
      occurrence_date: occ,
      ical_uid: row.ical_uid,
      organizer_email: row.organizer_email,
      organizer_name: row.organizer_name,
      rsvp: row.rsvp,
    });
    const remote = await mirrorGoogle(env, cal, "create", (account) => createRemoteEvent(env, cal, account, fresh));
    if (remote?.remote_id) {
      fresh = { ...fresh, remote_id: remote.remote_id, etag: remote.etag ?? null };
      await db.prepare(`UPDATE events SET remote_id = ?, etag = ? WHERE id = ?`).bind(fresh.remote_id, fresh.etag, fresh.id).run();
    }
    return toEvent(fresh, cal);
  }

  if (row.rrule && occ && scope === "following") {
    const occStart = occurrenceStart(row, occ, tz);
    // Close the old series just before this occurrence …
    const closed: EventRow = { ...row, rrule: withUntil(row.rrule, occStart - 1), updated_at: now() };
    await db.prepare(`UPDATE events SET rrule = ?, updated_at = ? WHERE id = ?`).bind(closed.rrule, closed.updated_at, closed.id).run();
    await mirrorGoogle(env, cal, "update", (account) => updateRemoteEvent(env, cal, account, closed));
    // … and start a fresh one here, carrying the patch and the original recurrence.
    const seed = shiftToOccurrence(row, occ, tz);
    const f = fieldsFrom(patch, seed, tz);
    if (patch.rrule === undefined) f.rrule = row.rrule;
    let fresh = await insertEvent(db, userId, cal.id, f, {
      ical_uid: row.ical_uid,
      organizer_email: row.organizer_email,
      organizer_name: row.organizer_name,
      rsvp: row.rsvp,
    });
    const remote = await mirrorGoogle(env, cal, "create", (account) => createRemoteEvent(env, cal, account, fresh));
    if (remote?.remote_id) {
      fresh = { ...fresh, remote_id: remote.remote_id, etag: remote.etag ?? null };
      await db.prepare(`UPDATE events SET remote_id = ?, etag = ? WHERE id = ?`).bind(fresh.remote_id, fresh.etag, fresh.id).run();
    }
    return toEvent(fresh, cal);
  }

  const next = await updateEventRow(db, row, fieldsFrom(patch, row, tz));
  const remote = await mirrorGoogle(env, cal, "update", (account) => updateRemoteEvent(env, cal, account, next));
  if (remote && "etag" in remote) {
    await db.prepare(`UPDATE events SET etag = ? WHERE id = ?`).bind(remote.etag ?? null, next.id).run();
    next.etag = remote.etag ?? null;
  }
  return toEvent(next, cal);
}

export async function deleteEvent(env: Env, userId: string, id: string, scope: "this" | "following" | "all" = "all"): Promise<void> {
  const db = env.DB;
  const parsed = parseEventId(id);
  const row = await ownedEvent(db, userId, parsed.id);
  if (!row) return; // deleting what isn't there is a success
  const cal = await ownedCalendar(db, userId, row.calendar_id);
  if (!cal) throw new Error("not_found");
  assertWritable(cal);
  const settings = await getSettings(db, userId);
  const tz = row.timezone || cal.timezone || settings.timezone || "UTC";
  const occ = parsed.occurrence;

  if (row.rrule && occ && scope === "this") {
    // Punch a hole in the series rather than dropping it, and clear any override for that slot.
    const ex = new Set((row.exdates ?? "").split(",").map((s) => s.trim()).filter(Boolean));
    ex.add(occ);
    const exdates = [...ex].sort().join(",");
    const next: EventRow = { ...row, exdates, updated_at: now() };
    await db.prepare(`UPDATE events SET exdates = ?, updated_at = ? WHERE id = ?`).bind(exdates, next.updated_at, row.id).run();
    await db.prepare(`DELETE FROM events WHERE user_id = ? AND master_id = ? AND occurrence_date = ?`).bind(userId, row.id, occ).run();
    await db.prepare(`DELETE FROM event_completions WHERE event_id = ? AND date = ?`).bind(row.id, occ).run();
    await mirrorGoogle(env, cal, "update", (account) => updateRemoteEvent(env, cal, account, next));
    return;
  }

  if (row.rrule && occ && scope === "following") {
    const next: EventRow = { ...row, rrule: withUntil(row.rrule, occurrenceStart(row, occ, tz) - 1), updated_at: now() };
    await db.prepare(`UPDATE events SET rrule = ?, updated_at = ? WHERE id = ?`).bind(next.rrule, next.updated_at, row.id).run();
    await mirrorGoogle(env, cal, "update", (account) => updateRemoteEvent(env, cal, account, next));
    return;
  }

  // A Google-expanded series has no RRULE to narrow, so the reach of the delete is expressed as a
  // set of sibling rows instead: all of them, or every one from this occurrence onward.
  const master = seriesMasterId(row.remote_id);
  if (!row.rrule && master && scope !== "this") {
    const from = scope === "following" ? row.starts_at : 0;
    // iCalUID is the reliable link; the id prefix is the fallback for a row that arrived without one.
    const doomed = row.ical_uid
      ? await db
          .prepare(`SELECT id, remote_id FROM events WHERE user_id = ? AND calendar_id = ? AND ical_uid = ? AND starts_at >= ? LIMIT ?`)
          .bind(userId, row.calendar_id, row.ical_uid, from, SERIES_DELETE_CAP)
          .all<{ id: string; remote_id: string | null }>()
      : await db
          .prepare(`SELECT id, remote_id FROM events WHERE user_id = ? AND calendar_id = ? AND remote_id LIKE ? AND starts_at >= ? LIMIT ?`)
          .bind(userId, row.calendar_id, `${master}\_%`, from, SERIES_DELETE_CAP)
          .all<{ id: string; remote_id: string | null }>();
    const ids = (doomed.results ?? []).map((r) => r.id);
    for (const part of chunk(ids, 90)) {
      const ic = inClause(part);
      await db.batch([
        db.prepare(`DELETE FROM event_completions WHERE event_id IN ${ic.sql}`).bind(...ic.params),
        db.prepare(`DELETE FROM events WHERE user_id = ? AND id IN ${ic.sql}`).bind(userId, ...ic.params),
      ]);
    }
    await mirrorGoogle(env, cal, "delete", async (account) => {
      // Dropping the master removes the whole series in one call. "Following" has no such shortcut,
      // so each occurrence from here on is cancelled in turn — the same thing done by hand.
      if (scope === "all") return deleteRemoteEvent(env, cal, account, master);
      for (const r of doomed.results ?? []) {
        if (r.remote_id) await deleteRemoteEvent(env, cal, account, r.remote_id);
      }
    });
    return;
  }

  // Overrides and completions have no ON DELETE for master_id, so clear them by hand.
  await db.prepare(`DELETE FROM events WHERE user_id = ? AND master_id = ?`).bind(userId, row.id).run();
  await db.prepare(`DELETE FROM event_completions WHERE event_id = ?`).bind(row.id).run();
  await db.prepare(`DELETE FROM events WHERE id = ? AND user_id = ?`).bind(row.id, userId).run();
  if (row.remote_id) await mirrorGoogle(env, cal, "delete", (account) => deleteRemoteEvent(env, cal, account, row.remote_id!));
}

export async function setRsvp(env: Env, userId: string, id: string, rsvp: string): Promise<CalEvent> {
  const db = env.DB;
  if (!(RSVPS as readonly string[]).includes(rsvp)) throw new Error("bad_rsvp");
  const parsed = parseEventId(id);
  const row = await ownedEvent(db, userId, parsed.id);
  if (!row) throw new Error("not_found");
  const cal = await ownedCalendar(db, userId, row.calendar_id);
  if (!cal) throw new Error("not_found");
  assertWritable(cal);
  // An occurrence answers for itself when it already has an override row; otherwise the series answers.
  const target =
    parsed.occurrence && row.rrule
      ? (await db
          .prepare(`SELECT * FROM events WHERE user_id = ? AND master_id = ? AND occurrence_date = ?`)
          .bind(userId, row.id, parsed.occurrence)
          .first<EventRow>()) ?? row
      : row;
  const t = now();
  await db.prepare(`UPDATE events SET rsvp = ?, updated_at = ? WHERE id = ?`).bind(rsvp, t, target.id).run();
  const next: EventRow = { ...target, rsvp, updated_at: t };
  if (next.remote_id) await mirrorGoogle(env, cal, "rsvp", (account) => setRemoteRsvp(env, cal, account, next.remote_id!, rsvp));
  return toEvent(next, cal);
}

/** Tick a todo off. Repeating todos record one row per occurrence; a plain one just stamps `done_at`. */
export async function setDone(env: Env, userId: string, id: string, done: boolean, date?: string): Promise<CalEvent> {
  const db = env.DB;
  const parsed = parseEventId(id);
  const row = await ownedEvent(db, userId, parsed.id);
  if (!row) throw new Error("not_found");
  const cal = await ownedCalendar(db, userId, row.calendar_id);
  if (!cal) throw new Error("not_found");
  assertWritable(cal);
  const settings = await getSettings(db, userId);
  const tz = row.timezone || cal.timezone || settings.timezone || "UTC";
  const occ = date && isValidDate(date) ? date : parsed.occurrence;
  const t = now();

  if (row.rrule && occ) {
    if (done) {
      await db
        .prepare(`INSERT OR REPLACE INTO event_completions (event_id, date, done_at) VALUES (?, ?, ?)`)
        .bind(row.id, occ, t)
        .run();
    } else {
      await db.prepare(`DELETE FROM event_completions WHERE event_id = ? AND date = ?`).bind(row.id, occ).run();
    }
    const dur = Math.max(0, row.ends_at - row.starts_at);
    const s = occurrenceStart(row, occ, tz);
    return toEvent(row, cal, { date: occ, startsAt: s, endsAt: s + dur, done });
  }

  await db.prepare(`UPDATE events SET done_at = ?, updated_at = ? WHERE id = ?`).bind(done ? t : null, t, row.id).run();
  return toEvent({ ...row, done_at: done ? t : null, updated_at: t }, cal);
}

/** One event as a downloadable `.ics`, occurrence-aware so `<row>@<date>` exports that instance. */
export async function eventIcs(env: Env, userId: string, id: string): Promise<string> {
  const db = env.DB;
  const parsed = parseEventId(id);
  const row = await ownedEvent(db, userId, parsed.id);
  if (!row) throw new Error("not_found");
  const cal = await ownedCalendar(db, userId, row.calendar_id);
  if (!cal) throw new Error("not_found");
  const settings = await getSettings(db, userId);
  const tz = row.timezone || cal.timezone || settings.timezone || "UTC";
  // A `<row>@<date>` id exports that one instance, so its times move and the RRULE is dropped.
  const occ = parsed.occurrence && row.rrule ? parsed.occurrence : null;
  const e = occ ? { ...shiftToOccurrence(row, occ, tz), rrule: null } : row;
  const ics: IcsEventInput = {
    uid: occ ? `${row.id}-${occ}@heyflare` : row.ical_uid || `${row.id}@heyflare`,
    summary: e.title,
    description: e.description,
    location: e.location,
    url: e.url,
    allDay: !!e.all_day,
    startsAt: e.starts_at,
    endsAt: e.ends_at,
    startDate: e.start_date,
    endDate: e.end_date,
    tzid: e.timezone || tz,
    rrule: e.rrule,
    organizer: e.organizer_email ? { email: e.organizer_email, name: e.organizer_name } : null,
    attendees: safeJson<EventAttendee[]>(e.attendees_json, []),
    reminders: safeJson<Reminder[]>(e.reminders_json, []).map((r) => r.minutes),
    status: e.status,
  };
  return buildIcs([ics], { name: cal.name || "Calendar" });
}
