import { Hono, type Context } from "hono";
import type { AppEnv } from "../env";
import type { AccountRow, MessageRow, ThreadRow } from "../db";
import type { Address } from "@shared/types";
import { uid, now, safeJson, ownedAccount, accountForThread } from "../db";
import { htmlToText } from "../sanitize";
import { googleConfigured, hasCalendarScope } from "../google";
import { appOrigin, HANDOFF_PREFIX, CAL_PREFIX } from "./auth";
import type { DayCoverRow, CalendarDayRow, CalendarRow, CalendarSettingsRow, FlexTaskRow, HabitRow, TimeEntryRow } from "../calendar/types";
import {
  toCalendar,
  toHabit,
  toFlexTask,
  toTimeEntry,
  toCalendarDay,
  toSettings,
  parseEventId,
  getSettings,
  putSettings,
  listCalendars,
  ownedCalendar,
  ownedEvent,
  rangeFor,
  createEvent,
  updateEvent,
  deleteEvent,
  setRsvp,
  setDone,
  eventIcs,
  type EventInput,
  type SettingsPatch,
} from "../calendar/store";
import { ensureDefaultCalendars, subscribeIcs, importIcs, syncCalendarNow, deleteCalendar } from "../calendar/sources";
import { isValidDate, addDays, daysBetween, weekStartOf, weekdayOf, dateKey, startOfDay, endOfDay } from "../calendar/dates";

const calendar = new Hono<AppEnv>();

/* ---------- small shared helpers ---------- */

const HEX = /^#[0-9a-fA-F]{6}$/;
const MAX_SPAN_DAYS = 400;
const STREAK_LOOKBACK = 400;

const str = (v: unknown, max: number): string => (typeof v === "string" ? v.slice(0, max) : "");
const trimmed = (v: unknown, max: number): string => (typeof v === "string" ? v.trim().slice(0, max) : "");
const int = (v: unknown, lo: number, hi: number, fallback: number): number =>
  typeof v === "number" && Number.isFinite(v) ? Math.min(hi, Math.max(lo, Math.round(v))) : fallback;
const ms = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? Math.round(v) : null);
const bool = (v: unknown): boolean | undefined => (typeof v === "boolean" ? v : undefined);

async function body<T>(c: Context<AppEnv>): Promise<Partial<T>> {
  return (await c.req.json<T>().catch(() => ({}) as T)) as Partial<T>;
}

/** Settings + the timezone/today pair almost every handler needs. */
async function ctx(c: Context<AppEnv>): Promise<{ userId: string; settings: CalendarSettingsRow; tz: string; today: string }> {
  const userId = c.get("user").id;
  const settings = await getSettings(c.env.DB, userId);
  const tz = settings.timezone || "UTC";
  return { userId, settings, tz, today: dateKey(now(), tz) };
}

/**
 * The calendar store signals refusals by message: a read-only (Google-without-scope, or an ICS
 * feed) calendar is a 403, a malformed or unplaceable event is a 400, and anything left is a
 * failure talking to Google.
 */
const BAD_REQUEST = new Set(["no_calendar", "no_account", "bad_time", "bad_range", "bad_rsvp", "bad_date"]);

function fail(c: Context<AppEnv>, e: unknown): Response {
  const msg = (e instanceof Error ? e.message : String(e ?? "")).slice(0, 300);
  if (msg === "read_only") return c.json({ error: "read_only" }, 403);
  if (msg === "not_found") return c.json({ error: "not_found" }, 404);
  if (BAD_REQUEST.has(msg)) return c.json({ error: msg }, 400);
  return c.json({ error: "calendar_failed", message: msg }, 502);
}

/* ---------- range ---------- */

// Everything needed to draw a window of days. `from`/`to` default to the current week.
calendar.get("/events", async (c) => {
  const { userId, settings, today } = await ctx(c);
  const qFrom = c.req.query("from") ?? "";
  const qTo = c.req.query("to") ?? "";
  if ((qFrom && !isValidDate(qFrom)) || (qTo && !isValidDate(qTo))) return c.json({ error: "bad_date" }, 400);
  const week = weekStartOf(today, settings.week_start);
  const from = qFrom || (qTo ? addDays(qTo, -6) : week);
  const to = qTo || addDays(from, 6);
  const span = daysBetween(from, to);
  if (span < 0) return c.json({ error: "bad_range" }, 400);
  if (span > MAX_SPAN_DAYS) return c.json({ error: "range_too_wide" }, 400);
  return c.json(await rangeFor(c.env, userId, from, to, { all: c.req.query("all") === "1" }));
});

/* ---------- events ---------- */

function readEventInput(b: Partial<EventInput>): EventInput {
  const input: EventInput = {};
  if (typeof b.calendar_id === "string") input.calendar_id = b.calendar_id.slice(0, 64);
  if (typeof b.kind === "string" && ["event", "birthday", "anniversary", "todo"].includes(b.kind)) input.kind = b.kind;
  if (typeof b.title === "string") input.title = b.title.trim().slice(0, 500);
  if (typeof b.description === "string") input.description = b.description.slice(0, 50_000);
  if (typeof b.location === "string") input.location = b.location.slice(0, 500);
  if (typeof b.emoji === "string") input.emoji = b.emoji.slice(0, 16);
  if (typeof b.all_day === "boolean") input.all_day = b.all_day;
  if (ms(b.starts_at) !== null) input.starts_at = ms(b.starts_at)!;
  if (ms(b.ends_at) !== null) input.ends_at = ms(b.ends_at)!;
  if (b.start_date === null || (typeof b.start_date === "string" && isValidDate(b.start_date))) input.start_date = b.start_date;
  if (b.end_date === null || (typeof b.end_date === "string" && isValidDate(b.end_date))) input.end_date = b.end_date;
  if (typeof b.timezone === "string") input.timezone = b.timezone.slice(0, 80);
  if (b.rrule === null || typeof b.rrule === "string") input.rrule = b.rrule === null ? null : String(b.rrule).slice(0, 1000);
  if (typeof b.status === "string" && ["confirmed", "tentative", "cancelled"].includes(b.status)) input.status = b.status;
  if (typeof b.busy === "boolean") input.busy = b.busy;
  if (typeof b.countdown === "boolean") input.countdown = b.countdown;
  if (typeof b.circled === "boolean") input.circled = b.circled;
  if (Array.isArray(b.attendees)) {
    input.attendees = b.attendees
      .filter((a): a is { email: string; name?: string; optional?: boolean } => !!a && typeof (a as any).email === "string")
      .slice(0, 200)
      .map((a) => ({ email: a.email.trim().slice(0, 320), name: trimmed(a.name, 200) || undefined, optional: bool(a.optional) }))
      .filter((a) => !!a.email);
  }
  if (typeof b.conference_url === "string") input.conference_url = b.conference_url.trim().slice(0, 2000);
  if (typeof b.url === "string") input.url = b.url.trim().slice(0, 2000);
  if (Array.isArray(b.reminders)) {
    input.reminders = b.reminders
      .filter((r): r is { minutes: number } => !!r && typeof (r as any).minutes === "number" && Number.isFinite((r as any).minutes))
      .slice(0, 10)
      .map((r) => ({ minutes: int(r.minutes, 0, 40320, 0) }));
  }
  if (b.thread_id === null || typeof b.thread_id === "string") input.thread_id = b.thread_id === null ? null : String(b.thread_id).slice(0, 64);
  if (b.message_id === null || typeof b.message_id === "string") input.message_id = b.message_id === null ? null : String(b.message_id).slice(0, 64);
  return input;
}

type Scope = "this" | "following" | "all";

/** `?scope=` if it names one, else "all" for a master and "this" for one addressed occurrence. */
function scopeFor(c: Context<AppEnv>, occurrence: string | null): Scope {
  const q = c.req.query("scope") ?? "";
  if (q === "this" || q === "following" || q === "all") return q;
  return occurrence ? "this" : "all";
}

calendar.post("/events", async (c) => {
  const userId = c.get("user").id;
  const input = readEventInput(await body<EventInput>(c));
  if (input.calendar_id) {
    const cal = await ownedCalendar(c.env.DB, userId, input.calendar_id);
    if (!cal) return c.json({ error: "not_found" }, 404);
  }
  try {
    return c.json(await createEvent(c.env, userId, input));
  } catch (e) {
    return fail(c, e);
  }
});

/**
 * Prefill for "make a meeting out of this email" — deliberately *not* saved. The client opens its
 * composer with this and the user picks a calendar and a real time.
 */
calendar.post("/events/from-thread", async (c) => {
  const db = c.env.DB;
  const user = c.get("user");
  const b = await body<{ thread_id: string }>(c);
  const threadId = trimmed(b.thread_id, 64);
  if (!threadId) return c.json({ error: "thread_id_required" }, 400);
  // Ownership rides on the account: accountForThread only resolves threads under this user.
  const acc = await accountForThread(db, user.id, threadId);
  if (!acc) return c.json({ error: "not_found" }, 404);
  const thread = await db.prepare(`SELECT * FROM threads WHERE id = ? AND account_id = ?`).bind(threadId, acc.id).first<ThreadRow>();
  if (!thread) return c.json({ error: "not_found" }, 404);
  const msg = await db.prepare(`SELECT * FROM messages WHERE thread_id = ? ORDER BY date DESC LIMIT 1`).bind(threadId).first<MessageRow>();

  const mine = new Set<string>();
  const accounts = await db.prepare(`SELECT * FROM accounts WHERE user_id = ?`).bind(user.id).all<AccountRow>();
  for (const a of accounts.results) if (a.email) mine.add(a.email.toLowerCase());

  const seen = new Set<string>();
  const attendees: { email: string; name?: string }[] = [];
  const add = (p: Address | null | undefined) => {
    const email = (p?.email ?? "").trim().toLowerCase();
    if (!email || mine.has(email) || seen.has(email)) return;
    seen.add(email);
    attendees.push({ email, name: (p?.name ?? "").trim().slice(0, 200) || undefined });
  };
  if (msg) {
    add({ email: msg.from_email, name: msg.from_name });
    for (const p of safeJson<Address[]>(msg.to_json, [])) add(p);
    for (const p of safeJson<Address[]>(msg.cc_json, [])) add(p);
  }
  for (const p of safeJson<Address[]>(thread.participants_json, [])) add(p);

  // Next half-hour boundary, for an hour.
  const half = 30 * 60_000;
  const starts_at = Math.ceil(now() / half) * half;
  return c.json({
    title: (thread.custom_subject ?? thread.subject ?? "").trim().slice(0, 500),
    description: (msg?.snippet ?? thread.snippet ?? "").trim().slice(0, 2000),
    attendees: attendees.slice(0, 100),
    thread_id: thread.id,
    starts_at,
    ends_at: starts_at + 60 * 60_000,
  });
});

// One event as a downloadable .ics.
calendar.get("/events/:file{.+\\.ics}", async (c) => {
  const userId = c.get("user").id;
  const id = c.req.param("file").replace(/\.ics$/i, "");
  const row = await ownedEvent(c.env.DB, userId, parseEventId(id).id);
  if (!row) return c.json({ error: "not_found" }, 404);
  let ics: string;
  try {
    ics = await eventIcs(c.env, userId, id);
  } catch (e) {
    return fail(c, e);
  }
  const name = (row.title || "event").replace(/[^A-Za-z0-9 _-]+/g, " ").trim().replace(/\s+/g, "-").slice(0, 60) || "event";
  return new Response(ics, {
    headers: {
      "content-type": "text/calendar; charset=utf-8",
      "content-disposition": `attachment; filename="${name}.ics"`,
      "cache-control": "no-store",
    },
  });
});

calendar.patch("/events/:id", async (c) => {
  const userId = c.get("user").id;
  const id = c.req.param("id");
  const parsed = parseEventId(id);
  if (!(await ownedEvent(c.env.DB, userId, parsed.id))) return c.json({ error: "not_found" }, 404);
  const patch = readEventInput(await body<EventInput>(c));
  if (patch.calendar_id && !(await ownedCalendar(c.env.DB, userId, patch.calendar_id))) return c.json({ error: "not_found" }, 404);
  try {
    return c.json(await updateEvent(c.env, userId, id, patch, scopeFor(c, parsed.occurrence)));
  } catch (e) {
    return fail(c, e);
  }
});

calendar.delete("/events/:id", async (c) => {
  const userId = c.get("user").id;
  const id = c.req.param("id");
  const parsed = parseEventId(id);
  if (!(await ownedEvent(c.env.DB, userId, parsed.id))) return c.json({ error: "not_found" }, 404);
  try {
    await deleteEvent(c.env, userId, id, scopeFor(c, parsed.occurrence));
    return c.json({ ok: true });
  } catch (e) {
    return fail(c, e);
  }
});

calendar.post("/events/:id/rsvp", async (c) => {
  const userId = c.get("user").id;
  const id = c.req.param("id");
  if (!(await ownedEvent(c.env.DB, userId, parseEventId(id).id))) return c.json({ error: "not_found" }, 404);
  const b = await body<{ rsvp: string }>(c);
  const rsvp = trimmed(b.rsvp, 20);
  if (!["needsAction", "accepted", "declined", "tentative"].includes(rsvp)) return c.json({ error: "bad_rsvp" }, 400);
  try {
    return c.json(await setRsvp(c.env, userId, id, rsvp));
  } catch (e) {
    return fail(c, e);
  }
});

calendar.post("/events/:id/done", async (c) => {
  const userId = c.get("user").id;
  const id = c.req.param("id");
  if (!(await ownedEvent(c.env.DB, userId, parseEventId(id).id))) return c.json({ error: "not_found" }, 404);
  const b = await body<{ done: boolean; date: string }>(c);
  const done = b.done !== false;
  const date = typeof b.date === "string" ? b.date : "";
  if (date && !isValidDate(date)) return c.json({ error: "bad_date" }, 400);
  try {
    return c.json(await setDone(c.env, userId, id, done, date || undefined));
  } catch (e) {
    return fail(c, e);
  }
});

/* ---------- sources ---------- */

async function calendarPayload(c: Context<AppEnv>, userId: string): Promise<{ rows: CalendarRow[]; accounts: AccountRow[]; counts: Map<string, number> }> {
  const db = c.env.DB;
  const [rows, accounts, counts] = await Promise.all([
    listCalendars(db, userId),
    db.prepare(`SELECT * FROM accounts WHERE user_id = ? ORDER BY created_at ASC`).bind(userId).all<AccountRow>(),
    db.prepare(`SELECT calendar_id, COUNT(*) AS n FROM events WHERE user_id = ? GROUP BY calendar_id`).bind(userId).all<{ calendar_id: string; n: number }>(),
  ]);
  return { rows, accounts: accounts.results, counts: new Map(counts.results.map((r) => [r.calendar_id, r.n])) };
}

function asCalendars(rows: CalendarRow[], accounts: AccountRow[], counts: Map<string, number>) {
  const emails = new Map(accounts.map((a) => [a.id, a.email]));
  return rows.map((r) => toCalendar(r, { account_email: r.account_id ? emails.get(r.account_id) ?? null : null, event_count: counts.get(r.id) ?? 0 }));
}

calendar.get("/sources", async (c) => {
  const { userId, settings } = await ctx(c);
  await ensureDefaultCalendars(c.env, userId).catch(() => {});
  const { rows, accounts, counts } = await calendarPayload(c, userId);
  return c.json({
    calendars: asCalendars(rows, accounts, counts),
    settings: toSettings(settings),
    // Gmail accounts whose refresh token predates (or declined) the Calendar scope.
    connectable: accounts.filter((a) => a.provider === "gmail" && !hasCalendarScope(a.scopes)).map((a) => ({ id: a.id, email: a.email })),
  });
});

calendar.post("/sources", async (c) => {
  const db = c.env.DB;
  const userId = c.get("user").id;
  const b = await body<{ name: string; color: string; description: string }>(c);
  const name = trimmed(b.name, 120);
  if (!name) return c.json({ error: "name_required" }, 400);
  const color = trimmed(b.color, 7) || "#111111";
  if (!HEX.test(color)) return c.json({ error: "bad_color" }, 400);
  const pos = await db.prepare(`SELECT COALESCE(MAX(position), -1) + 1 AS p FROM calendars WHERE user_id = ?`).bind(userId).first<{ p: number }>();
  const id = uid();
  const t = now();
  await db
    .prepare(
      `INSERT INTO calendars (id, user_id, account_id, source, remote_id, url, name, description, color, timezone, visible, writable, is_default, position, sync_status, created_at, updated_at)
       VALUES (?, ?, NULL, 'local', NULL, NULL, ?, ?, ?, '', 1, 1, 0, ?, 'idle', ?, ?)`
    )
    .bind(id, userId, name, str(b.description, 2000), color, pos?.p ?? 0, t, t)
    .run();
  const row = await ownedCalendar(db, userId, id);
  return c.json(toCalendar(row!, { event_count: 0 }));
});

calendar.post("/sources/subscribe", async (c) => {
  const userId = c.get("user").id;
  const b = await body<{ url: string; name: string; color: string }>(c);
  const url = trimmed(b.url, 2000);
  if (!/^(https?|webcal):\/\//i.test(url)) return c.json({ error: "bad_url" }, 400);
  const name = trimmed(b.name, 120);
  const color = trimmed(b.color, 7);
  if (color && !HEX.test(color)) return c.json({ error: "bad_color" }, 400);
  try {
    const row = await subscribeIcs(c.env, userId, url, { name: name || undefined, color: color || undefined });
    return c.json(toCalendar(row));
  } catch (e) {
    // A feed that 404s or isn't iCalendar is the caller's problem, not a server fault.
    return c.json({ error: "bad_feed", message: (e instanceof Error ? e.message : String(e ?? "")).slice(0, 300) }, 400);
  }
});

// Sync every syncable source. Individual failures are reported, not thrown.
calendar.post("/sources/sync", async (c) => {
  const userId = c.get("user").id;
  const rows = await listCalendars(c.env.DB, userId);
  const results: { id: string; changed: number; error?: string }[] = [];
  for (const cal of rows) {
    if (cal.source === "local") continue;
    try {
      const r = await syncCalendarNow(c.env, cal);
      results.push({ id: cal.id, changed: r.changed });
    } catch (e) {
      results.push({ id: cal.id, changed: 0, error: (e instanceof Error ? e.message : String(e ?? "")).slice(0, 300) });
    }
  }
  const { rows: fresh, accounts, counts } = await calendarPayload(c, userId);
  return c.json({ ok: true, results, calendars: asCalendars(fresh, accounts, counts) });
});

// An uploaded .ics body becomes editable local events on one of the owner's calendars.
calendar.post("/sources/import", async (c) => {
  const db = c.env.DB;
  const userId = c.get("user").id;
  const LIMIT = 8 * 1024 * 1024;
  if (Number(c.req.header("content-length") ?? 0) > LIMIT) return c.json({ error: "too_large" }, 413);
  // Accept either a raw `text/calendar` body or the JSON envelope the web client sends.
  const raw = await c.req.text().catch(() => "");
  if (raw.length > LIMIT) return c.json({ error: "too_large" }, 413);
  let text = raw;
  let bodyCalendarId = "";
  if (raw.trimStart().startsWith("{")) {
    try {
      const j = JSON.parse(raw) as { ics?: string; calendar_id?: string };
      if (typeof j.ics === "string") text = j.ics;
      if (typeof j.calendar_id === "string") bodyCalendarId = j.calendar_id;
    } catch {
      /* not JSON after all — treat the body as iCalendar text */
    }
  }
  if (!text.trim()) return c.json({ error: "empty_body" }, 400);

  const wanted = c.req.query("calendar_id") || bodyCalendarId;
  let target: CalendarRow | null = null;
  if (wanted) {
    target = await ownedCalendar(db, userId, wanted);
    if (!target) return c.json({ error: "not_found" }, 404);
  } else {
    const rows = await listCalendars(db, userId);
    target = rows.find((r) => r.source === "local" && r.is_default) ?? rows.find((r) => r.source === "local") ?? null;
  }
  if (!target) return c.json({ error: "no_calendar" }, 400);
  if (!target.writable) return c.json({ error: "read_only" }, 403);
  try {
    const r = await importIcs(c.env, userId, target.id, text);
    return c.json({ ok: true, imported: r.added, added: r.added, calendar: toCalendar(target) });
  } catch (e) {
    return c.json({ error: "bad_ics", message: (e instanceof Error ? e.message : String(e ?? "")).slice(0, 300) }, 400);
  }
});

calendar.patch("/sources/:id", async (c) => {
  const db = c.env.DB;
  const userId = c.get("user").id;
  const cal = await ownedCalendar(db, userId, c.req.param("id"));
  if (!cal) return c.json({ error: "not_found" }, 404);
  const b = await body<{ name: string; color: string; visible: boolean; is_default: boolean }>(c);
  const name = typeof b.name === "string" && b.name.trim() ? b.name.trim().slice(0, 120) : cal.name;
  let color = cal.color;
  if (typeof b.color === "string") {
    color = b.color.trim().slice(0, 7);
    if (!HEX.test(color)) return c.json({ error: "bad_color" }, 400);
  }
  const visible = typeof b.visible === "boolean" ? (b.visible ? 1 : 0) : cal.visible;
  const isDefault = typeof b.is_default === "boolean" ? (b.is_default ? 1 : 0) : cal.is_default;
  if (isDefault && !cal.writable) return c.json({ error: "read_only" }, 403);
  const stmts = [
    db.prepare(`UPDATE calendars SET name = ?, color = ?, visible = ?, is_default = ?, updated_at = ? WHERE id = ? AND user_id = ?`).bind(name, color, visible, isDefault, now(), cal.id, userId),
  ];
  // Exactly one default per owner.
  if (isDefault) stmts.unshift(db.prepare(`UPDATE calendars SET is_default = 0 WHERE user_id = ? AND id != ?`).bind(userId, cal.id));
  await db.batch(stmts);
  const fresh = await ownedCalendar(db, userId, cal.id);
  return c.json(toCalendar(fresh!));
});

calendar.delete("/sources/:id", async (c) => {
  const userId = c.get("user").id;
  const cal = await ownedCalendar(c.env.DB, userId, c.req.param("id"));
  if (!cal) return c.json({ error: "not_found" }, 404);
  await deleteCalendar(c.env.DB, cal.id);
  return c.json({ ok: true });
});

calendar.post("/sources/:id/sync", async (c) => {
  const userId = c.get("user").id;
  const cal = await ownedCalendar(c.env.DB, userId, c.req.param("id"));
  if (!cal) return c.json({ error: "not_found" }, 404);
  if (cal.source === "local") return c.json({ ok: true, changed: 0, calendar: toCalendar(cal) });
  let changed = 0;
  let error: string | null = null;
  try {
    changed = (await syncCalendarNow(c.env, cal)).changed;
  } catch (e) {
    error = (e instanceof Error ? e.message : String(e ?? "")).slice(0, 300);
  }
  const fresh = await ownedCalendar(c.env.DB, userId, cal.id);
  return c.json({ ok: !error, changed, error, calendar: toCalendar(fresh ?? cal) });
});

/* ---------- google ---------- */

/**
 * Same handoff as `POST /api/accounts/connect-link`, but the state also asks for the Calendar
 * scope. The app opens the URL in the system browser, which carries the user's Google session.
 */
calendar.post("/google/connect-link", async (c) => {
  const user = c.get("user");
  if (!googleConfigured(c.env)) return c.json({ error: "google_not_configured", message: "Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET secrets." }, 500);
  const b = await body<{ account_id: string }>(c);
  let hint = "";
  if (typeof b.account_id === "string" && b.account_id) {
    const acc = await ownedAccount(c.env.DB, user.id, b.account_id);
    if (!acc) return c.json({ error: "not_found" }, 404);
    hint = acc.email;
  }
  const state = `${HANDOFF_PREFIX}${CAL_PREFIX}${uid()}`;
  await c.env.DB.prepare(`INSERT INTO oauth_states (state, user_id, created_at) VALUES (?, ?, ?)`).bind(state, user.id, now()).run();
  c.executionCtx.waitUntil(c.env.DB.prepare(`DELETE FROM oauth_states WHERE created_at < ?`).bind(now() - 3600_000).run());
  const url = `${appOrigin(c)}/auth/google/handoff?state=${encodeURIComponent(state)}${hint ? `&login_hint=${encodeURIComponent(hint)}` : ""}`;
  return c.json({ url });
});

/* ---------- habits ---------- */

/** `[1,3,5]` → "1,3,5". An absent or unusable list keeps whatever was there before. */
function parseDays(v: unknown, fallback: string): string {
  if (!Array.isArray(v)) return fallback;
  const set = new Set<number>();
  for (const d of v) if (typeof d === "number" && Number.isInteger(d) && d >= 0 && d <= 6) set.add(d);
  return set.size ? [...set].sort((a, b) => a - b).join(",") : fallback;
}

const minDate = (a: string, b: string): string => (daysBetween(a, b) < 0 ? b : a);
const maxDate = (a: string, b: string): string => (daysBetween(a, b) < 0 ? a : b);

const daysOf = (row: HabitRow): number[] =>
  row.days
    .split(",")
    .map((s) => parseInt(s, 10))
    .filter((n) => Number.isInteger(n) && n >= 0 && n <= 6);

/**
 * Consecutive expected days, walking back from today. Today is forgiving: an unticked habit on the
 * day you're looking at hasn't broken anything yet, it just hasn't happened.
 */
function streakOf(row: HabitRow, done: Set<string>, today: string): number {
  const days = daysOf(row);
  if (!days.length) return 0;
  let streak = 0;
  let d = today;
  for (let i = 0; i <= STREAK_LOOKBACK; i++) {
    if (days.includes(weekdayOf(d))) {
      if (done.has(d)) streak++;
      else if (d !== today) break;
    }
    d = addDays(d, -1);
  }
  return streak;
}

/** Completions for a set of habits over one date window, as a habit_id → dates map. */
async function completionsFor(db: D1Database, ids: string[], from: string, to: string): Promise<Map<string, string[]>> {
  const out = new Map<string, string[]>();
  if (!ids.length) return out;
  const rows = await db
    .prepare(`SELECT habit_id, date FROM habit_completions WHERE habit_id IN (${ids.map(() => "?").join(",")}) AND date >= ? AND date <= ? ORDER BY date ASC`)
    .bind(...ids, from, to)
    .all<{ habit_id: string; date: string }>();
  for (const r of rows.results) {
    const list = out.get(r.habit_id);
    if (list) list.push(r.date);
    else out.set(r.habit_id, [r.date]);
  }
  return out;
}

/** Habits with the window's completions and a streak, in one pass over both date ranges. */
async function habitsWith(db: D1Database, userId: string, today: string, from: string, to: string) {
  const rows = await db.prepare(`SELECT * FROM habits WHERE user_id = ? ORDER BY position ASC, created_at ASC`).bind(userId).all<HabitRow>();
  const ids = rows.results.map((r) => r.id);
  const all = await completionsFor(db, ids, minDate(addDays(today, -STREAK_LOOKBACK), from), maxDate(today, to));
  return rows.results.map((r) => {
    const dates = all.get(r.id) ?? [];
    const inWindow = dates.filter((d) => daysBetween(from, d) >= 0 && daysBetween(d, to) >= 0);
    return toHabit(r, inWindow, streakOf(r, new Set(dates), today));
  });
}

calendar.get("/habits", async (c) => {
  const { userId, settings, today } = await ctx(c);
  const qFrom = c.req.query("from") ?? "";
  const qTo = c.req.query("to") ?? "";
  if ((qFrom && !isValidDate(qFrom)) || (qTo && !isValidDate(qTo))) return c.json({ error: "bad_date" }, 400);
  const week = weekStartOf(today, settings.week_start);
  const from = qFrom || week;
  const to = qTo || addDays(from, 6);
  if (daysBetween(from, to) < 0) return c.json({ error: "bad_range" }, 400);
  if (daysBetween(from, to) > MAX_SPAN_DAYS) return c.json({ error: "range_too_wide" }, 400);
  return c.json(await habitsWith(c.env.DB, userId, today, from, to));
});

calendar.post("/habits", async (c) => {
  const db = c.env.DB;
  const userId = c.get("user").id;
  const b = await body<{ name: string; icon: string; color: string; days: number[]; position: number }>(c);
  const name = trimmed(b.name, 120);
  if (!name) return c.json({ error: "name_required" }, 400);
  const color = trimmed(b.color, 7) || "#111111";
  if (!HEX.test(color)) return c.json({ error: "bad_color" }, 400);
  const pos = await db.prepare(`SELECT COALESCE(MAX(position), -1) + 1 AS p FROM habits WHERE user_id = ?`).bind(userId).first<{ p: number }>();
  const id = uid();
  const t = now();
  await db
    .prepare(`INSERT INTO habits (id, user_id, name, icon, color, days, position, archived, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`)
    .bind(id, userId, name, trimmed(b.icon, 16), color, parseDays(b.days, "0,1,2,3,4,5,6"), int(b.position, 0, 9999, pos?.p ?? 0), t, t)
    .run();
  const row = await db.prepare(`SELECT * FROM habits WHERE id = ?`).bind(id).first<HabitRow>();
  return c.json(toHabit(row!, [], 0));
});

calendar.patch("/habits/:id", async (c) => {
  const db = c.env.DB;
  const { userId, today } = await ctx(c);
  const row = await db.prepare(`SELECT * FROM habits WHERE id = ? AND user_id = ?`).bind(c.req.param("id"), userId).first<HabitRow>();
  if (!row) return c.json({ error: "not_found" }, 404);
  const b = await body<{ name: string; icon: string; color: string; days: number[]; position: number; archived: boolean }>(c);
  const name = typeof b.name === "string" && b.name.trim() ? b.name.trim().slice(0, 120) : row.name;
  let color = row.color;
  if (typeof b.color === "string") {
    color = b.color.trim().slice(0, 7);
    if (!HEX.test(color)) return c.json({ error: "bad_color" }, 400);
  }
  const icon = typeof b.icon === "string" ? b.icon.trim().slice(0, 16) : row.icon;
  const days = parseDays(b.days, row.days);
  const position = int(b.position, 0, 9999, row.position);
  const archived = typeof b.archived === "boolean" ? (b.archived ? 1 : 0) : row.archived;
  await db
    .prepare(`UPDATE habits SET name = ?, icon = ?, color = ?, days = ?, position = ?, archived = ?, updated_at = ? WHERE id = ? AND user_id = ?`)
    .bind(name, icon, color, days, position, archived, now(), row.id, userId)
    .run();
  const fresh = await db.prepare(`SELECT * FROM habits WHERE id = ?`).bind(row.id).first<HabitRow>();
  const dates = (await completionsFor(db, [row.id], addDays(today, -STREAK_LOOKBACK), today)).get(row.id) ?? [];
  return c.json(toHabit(fresh!, dates, streakOf(fresh!, new Set(dates), today)));
});

calendar.delete("/habits/:id", async (c) => {
  const db = c.env.DB;
  const userId = c.get("user").id;
  const row = await db.prepare(`SELECT id FROM habits WHERE id = ? AND user_id = ?`).bind(c.req.param("id"), userId).first<{ id: string }>();
  if (!row) return c.json({ error: "not_found" }, 404);
  await db.batch([db.prepare(`DELETE FROM habit_completions WHERE habit_id = ?`).bind(row.id), db.prepare(`DELETE FROM habits WHERE id = ? AND user_id = ?`).bind(row.id, userId)]);
  return c.json({ ok: true });
});

// Tick or untick one day. Returns the habit with a recomputed streak so the UI can just swap it in.
calendar.post("/habits/:id/toggle", async (c) => {
  const db = c.env.DB;
  const { userId, today } = await ctx(c);
  const row = await db.prepare(`SELECT * FROM habits WHERE id = ? AND user_id = ?`).bind(c.req.param("id"), userId).first<HabitRow>();
  if (!row) return c.json({ error: "not_found" }, 404);
  const b = await body<{ date: string; done: boolean }>(c);
  const date = typeof b.date === "string" && b.date ? b.date : today;
  if (!isValidDate(date)) return c.json({ error: "bad_date" }, 400);
  const existing = await db.prepare(`SELECT date FROM habit_completions WHERE habit_id = ? AND date = ?`).bind(row.id, date).first<{ date: string }>();
  const wantDone = typeof b.done === "boolean" ? b.done : !existing;
  if (wantDone && !existing) {
    await db.prepare(`INSERT OR IGNORE INTO habit_completions (habit_id, date, done_at) VALUES (?, ?, ?)`).bind(row.id, date, now()).run();
  } else if (!wantDone && existing) {
    await db.prepare(`DELETE FROM habit_completions WHERE habit_id = ? AND date = ?`).bind(row.id, date).run();
  }
  // Report completions over the window the client is drawing (default: everything the streak looks
  // at), but always compute the streak from the full lookback.
  const qFrom = c.req.query("from") ?? "";
  const qTo = c.req.query("to") ?? "";
  const lookback = addDays(today, -STREAK_LOOKBACK);
  const from = isValidDate(qFrom) ? qFrom : lookback;
  const to = maxDate(isValidDate(qTo) ? qTo : today, date);
  const all = (await completionsFor(db, [row.id], minDate(lookback, from), to)).get(row.id) ?? [];
  const inWindow = all.filter((d) => daysBetween(from, d) >= 0 && daysBetween(d, to) >= 0);
  return c.json(toHabit(row, inWindow, streakOf(row, new Set(all), today)));
});

/* ---------- days ---------- */

function emptyDay(userId: string, date: string): CalendarDayRow {
  return { user_id: userId, date, label: "", cover_url: "", journal_html: "", journal_updated_at: null, cover_id: null, cover_position: "50% 50%", updated_at: 0 };
}

async function dayRow(db: D1Database, userId: string, date: string): Promise<CalendarDayRow> {
  const row = await db.prepare(`SELECT * FROM calendar_days WHERE user_id = ? AND date = ?`).bind(userId, date).first<CalendarDayRow>();
  return row ?? emptyDay(userId, date);
}

calendar.get("/days/:date", async (c) => {
  const userId = c.get("user").id;
  const date = c.req.param("date");
  if (!isValidDate(date)) return c.json({ error: "bad_date" }, 400);
  return c.json(toCalendarDay(await dayRow(c.env.DB, userId, date)));
});

// Label and photo. Absent fields are left alone, so this doubles as a PATCH. Passing an empty
// string for `cover_url` (or null for `cover_id`) is how you take a day's photo back off.
calendar.put("/days/:date", async (c) => {
  const db = c.env.DB;
  const userId = c.get("user").id;
  const date = c.req.param("date");
  if (!isValidDate(date)) return c.json({ error: "bad_date" }, 400);
  const b = await body<{ label: string; cover_url: string; cover_id: string | null; cover_position: string }>(c);
  const label = typeof b.label === "string" ? b.label.trim().slice(0, 200) : null;
  let cover = typeof b.cover_url === "string" ? b.cover_url.trim().slice(0, 2000) : null;
  let coverId = b.cover_id === null ? "" : typeof b.cover_id === "string" ? b.cover_id.trim().slice(0, 64) : null;
  const position = typeof b.cover_position === "string" && /^[\d.]+% [\d.]+%$/.test(b.cover_position) ? b.cover_position : null;

  const previous = (await dayRow(db, userId, date)).cover_id;

  if (coverId) {
    const own = await db.prepare(`SELECT id FROM day_covers WHERE id = ? AND user_id = ?`).bind(coverId, userId).first<{ id: string }>();
    if (!own) return c.json({ error: "not_found" }, 404);
    cover = `/api/calendar/covers/${coverId}`;
  } else if (coverId === "") {
    // Clearing the stored photo clears the URL with it, unless one was supplied in the same call.
    if (cover === null) cover = "";
  }
  // An external URL replaces any stored photo, so the two can't disagree.
  if (cover !== null && coverId === null && !cover.startsWith("/api/calendar/covers/")) coverId = "";

  await db
    .prepare(
      `INSERT INTO calendar_days (user_id, date, label, cover_url, cover_id, cover_position, journal_html, journal_updated_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, '', NULL, ?)
       ON CONFLICT(user_id, date) DO UPDATE SET
         label = COALESCE(?, calendar_days.label),
         cover_url = COALESCE(?, calendar_days.cover_url),
         cover_id = COALESCE(?, calendar_days.cover_id),
         cover_position = COALESCE(?, calendar_days.cover_position),
         updated_at = excluded.updated_at`
    )
    .bind(userId, date, label ?? "", cover ?? "", coverId || null, position ?? "50% 50%", now(), label, cover, coverId === "" ? null : coverId, position)
    .run();

  // HEY keeps no photo library, so a picture that no day points at any more is just dead weight.
  if (previous && previous !== coverId) {
    const still = await db.prepare(`SELECT 1 AS n FROM calendar_days WHERE user_id = ? AND cover_id = ? LIMIT 1`).bind(userId, previous).first<{ n: number }>();
    if (!still) c.executionCtx.waitUntil(db.prepare(`DELETE FROM day_covers WHERE id = ? AND user_id = ?`).bind(previous, userId).run().then(() => {}));
  }
  return c.json(toCalendarDay(await dayRow(db, userId, date)));
});

/* ---------- day photos ---------- */

const COVER_LIMIT = 1_500_000;
const COVER_TYPES = /^image\/(jpeg|png|webp|gif|avif)$/i;

/** D1 hands BLOBs back as ArrayBuffer (remote) or number[] (local); normalise both. */
function blobBytes(raw: unknown): Uint8Array | null {
  if (raw instanceof ArrayBuffer) return new Uint8Array(raw);
  if (Array.isArray(raw)) return Uint8Array.from(raw as number[]);
  if (ArrayBuffer.isView(raw)) return new Uint8Array(raw.buffer as ArrayBuffer, raw.byteOffset, raw.byteLength);
  return null;
}

// The photo library: every picture the owner has stuck on a day, newest first, so one can be reused.
calendar.get("/covers", async (c) => {
  const userId = c.get("user").id;
  const rows = await c.env.DB.prepare(
    `SELECT id, mime, width, height, size, name, created_at FROM day_covers WHERE user_id = ? ORDER BY created_at DESC LIMIT 120`
  )
    .bind(userId)
    .all<DayCoverRow>();
  return c.json(
    rows.results.map((r) => ({ id: r.id, url: `/api/calendar/covers/${r.id}`, width: r.width, height: r.height, size: r.size, name: r.name, created_at: r.created_at }))
  );
});

// Raw image bytes in the body; the client downscales first, so this only has to guard the ceiling.
calendar.post("/covers", async (c) => {
  const userId = c.get("user").id;
  const mime = (c.req.header("content-type") ?? "").split(";")[0].trim().toLowerCase();
  if (!COVER_TYPES.test(mime)) return c.json({ error: "bad_image_type", message: "Upload a JPEG, PNG, WebP, GIF or AVIF." }, 400);
  const declared = Number(c.req.header("content-length") ?? 0);
  if (declared > COVER_LIMIT) return c.json({ error: "image_too_large" }, 413);
  const buf = new Uint8Array(await c.req.arrayBuffer());
  if (buf.byteLength === 0) return c.json({ error: "empty_body" }, 400);
  if (buf.byteLength > COVER_LIMIT) return c.json({ error: "image_too_large" }, 413);
  const id = uid();
  const width = Number(c.req.header("x-image-width") ?? 0) || 0;
  const height = Number(c.req.header("x-image-height") ?? 0) || 0;
  const name = (c.req.header("x-image-name") ?? "").slice(0, 120);
  await c.env.DB.prepare(`INSERT INTO day_covers (id, user_id, mime, width, height, size, name, data, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`)
    .bind(id, userId, mime, width, height, buf.byteLength, name, buf, now())
    .run();
  return c.json({ id, url: `/api/calendar/covers/${id}`, width, height, size: buf.byteLength, name, created_at: now() });
});

calendar.get("/covers/:id", async (c) => {
  const userId = c.get("user").id;
  const row = await c.env.DB.prepare(`SELECT mime, data FROM day_covers WHERE id = ? AND user_id = ?`).bind(c.req.param("id"), userId).first<{ mime: string; data: unknown }>();
  if (!row) return c.json({ error: "not_found" }, 404);
  const bytes = blobBytes(row.data);
  if (!bytes) return c.json({ error: "not_found" }, 404);
  return new Response(bytes, {
    headers: {
      "content-type": COVER_TYPES.test(row.mime) ? row.mime : "application/octet-stream",
      "content-length": String(bytes.byteLength),
      // The id is content-addressed by creation, so a stored photo never changes under its URL.
      "cache-control": "private, max-age=31536000, immutable",
      "x-content-type-options": "nosniff",
    },
  });
});

calendar.delete("/covers/:id", async (c) => {
  const db = c.env.DB;
  const userId = c.get("user").id;
  const id = c.req.param("id");
  const row = await db.prepare(`SELECT id FROM day_covers WHERE id = ? AND user_id = ?`).bind(id, userId).first<{ id: string }>();
  if (!row) return c.json({ error: "not_found" }, 404);
  await db.batch([
    db.prepare(`UPDATE calendar_days SET cover_id = NULL, cover_url = '' WHERE user_id = ? AND cover_id = ?`).bind(userId, id),
    db.prepare(`DELETE FROM day_covers WHERE id = ? AND user_id = ?`).bind(id, userId),
  ]);
  return c.json({ ok: true });
});

/* ---------- journal ---------- */

const excerptOf = (html: string): string => htmlToText(html).replace(/\s+/g, " ").trim().slice(0, 240);

// The index: every day that has an entry, newest first. `?before=` is the previous page's oldest
// `journal_updated_at`.
calendar.get("/journal", async (c) => {
  const userId = c.get("user").id;
  const before = Number(c.req.query("before") ?? "");
  const limit = int(Number(c.req.query("limit") ?? ""), 1, 100, 50);
  const where = Number.isFinite(before) && before > 0 ? ` AND journal_updated_at < ?` : "";
  const binds: unknown[] = [userId];
  if (where) binds.push(Math.round(before));
  const rows = await c.env.DB.prepare(
    `SELECT * FROM calendar_days WHERE user_id = ? AND journal_html != ''${where} ORDER BY journal_updated_at DESC, date DESC LIMIT ?`
  )
    .bind(...binds, limit)
    .all<CalendarDayRow>();
  // Shaped as `CalendarDay` plus an excerpt, so the index and the day view share one type.
  return c.json(
    rows.results.map((r) => ({
      date: r.date,
      label: r.label,
      cover_url: r.cover_url,
      cover_id: r.cover_id ?? null,
      cover_position: r.cover_position || "50% 50%",
      has_journal: true,
      excerpt: excerptOf(r.journal_html),
      journal_updated_at: r.journal_updated_at,
    })),
  );
});

calendar.get("/journal/:date", async (c) => {
  const userId = c.get("user").id;
  const date = c.req.param("date");
  if (!isValidDate(date)) return c.json({ error: "bad_date" }, 400);
  const row = await dayRow(c.env.DB, userId, date);
  return c.json({ ...toCalendarDay(row), journal_html: row.journal_html });
});

calendar.put("/journal/:date", async (c) => {
  const db = c.env.DB;
  const userId = c.get("user").id;
  const date = c.req.param("date");
  if (!isValidDate(date)) return c.json({ error: "bad_date" }, 400);
  const b = await body<{ journal_html: string }>(c);
  if (typeof b.journal_html !== "string") return c.json({ error: "journal_html_required" }, 400);
  const html = b.journal_html.slice(0, 500_000);
  const t = now();
  await db
    .prepare(
      `INSERT INTO calendar_days (user_id, date, label, cover_url, journal_html, journal_updated_at, updated_at) VALUES (?, ?, '', '', ?, ?, ?)
       ON CONFLICT(user_id, date) DO UPDATE SET journal_html = excluded.journal_html, journal_updated_at = excluded.journal_updated_at, updated_at = excluded.updated_at`
    )
    .bind(userId, date, html, html.trim() ? t : null, t)
    .run();
  const row = await dayRow(db, userId, date);
  return c.json({ ...toCalendarDay(row), journal_html: row.journal_html });
});

/* ---------- flex tasks ---------- */

async function weekParam(c: Context<AppEnv>): Promise<{ userId: string; week: string; today: string } | null> {
  const { userId, settings, today } = await ctx(c);
  const q = c.req.query("week") ?? "";
  if (q && !isValidDate(q)) return null;
  return { userId, week: weekStartOf(q || today, settings.week_start), today };
}

calendar.get("/flex-tasks", async (c) => {
  const p = await weekParam(c);
  if (!p) return c.json({ error: "bad_date" }, 400);
  const rows = await c.env.DB.prepare(`SELECT * FROM flex_tasks WHERE user_id = ? AND week_start = ? ORDER BY position ASC, created_at ASC`).bind(p.userId, p.week).all<FlexTaskRow>();
  return c.json(rows.results.map(toFlexTask));
});

calendar.post("/flex-tasks", async (c) => {
  const db = c.env.DB;
  const { userId, settings, today } = await ctx(c);
  const b = await body<{ title: string; week_start: string; position: number }>(c);
  const title = trimmed(b.title, 500);
  if (!title) return c.json({ error: "title_required" }, 400);
  if (typeof b.week_start === "string" && b.week_start && !isValidDate(b.week_start)) return c.json({ error: "bad_date" }, 400);
  const week = weekStartOf(typeof b.week_start === "string" && b.week_start ? b.week_start : today, settings.week_start);
  const pos = await db.prepare(`SELECT COALESCE(MAX(position), -1) + 1 AS p FROM flex_tasks WHERE user_id = ? AND week_start = ?`).bind(userId, week).first<{ p: number }>();
  const id = uid();
  const t = now();
  await db
    .prepare(`INSERT INTO flex_tasks (id, user_id, week_start, title, done_at, position, created_at, updated_at) VALUES (?, ?, ?, ?, NULL, ?, ?, ?)`)
    .bind(id, userId, week, title, int(b.position, 0, 9999, pos?.p ?? 0), t, t)
    .run();
  const row = await db.prepare(`SELECT * FROM flex_tasks WHERE id = ?`).bind(id).first<FlexTaskRow>();
  return c.json(toFlexTask(row!));
});

// "Sometime this week" that never happened: pull it into this week rather than losing it.
calendar.post("/flex-tasks/roll", async (c) => {
  const db = c.env.DB;
  const { userId, settings, today } = await ctx(c);
  // The client may name the target week; otherwise everything unfinished lands in the current one.
  const b = await body<{ week: string }>(c);
  const target = typeof b.week === "string" && isValidDate(b.week) ? b.week : today;
  const week = weekStartOf(target, settings.week_start);
  const t = now();
  const moved = await db.prepare(`UPDATE flex_tasks SET week_start = ?, updated_at = ? WHERE user_id = ? AND done_at IS NULL AND week_start < ?`).bind(week, t, userId, week).run();
  const rows = await db.prepare(`SELECT * FROM flex_tasks WHERE user_id = ? AND week_start = ? ORDER BY position ASC, created_at ASC`).bind(userId, week).all<FlexTaskRow>();
  const rolled = moved.meta?.changes ?? 0;
  return c.json({ ok: true, week_start: week, moved: rolled, rolled, tasks: rows.results.map(toFlexTask) });
});

calendar.patch("/flex-tasks/:id", async (c) => {
  const db = c.env.DB;
  const { userId, settings } = await ctx(c);
  const row = await db.prepare(`SELECT * FROM flex_tasks WHERE id = ? AND user_id = ?`).bind(c.req.param("id"), userId).first<FlexTaskRow>();
  if (!row) return c.json({ error: "not_found" }, 404);
  const b = await body<{ title: string; done: boolean; position: number; week_start: string }>(c);
  const title = typeof b.title === "string" && b.title.trim() ? b.title.trim().slice(0, 500) : row.title;
  const doneAt = typeof b.done === "boolean" ? (b.done ? row.done_at ?? now() : null) : row.done_at;
  const position = int(b.position, 0, 9999, row.position);
  let week = row.week_start;
  if (typeof b.week_start === "string" && b.week_start) {
    if (!isValidDate(b.week_start)) return c.json({ error: "bad_date" }, 400);
    week = weekStartOf(b.week_start, settings.week_start);
  }
  await db
    .prepare(`UPDATE flex_tasks SET title = ?, done_at = ?, position = ?, week_start = ?, updated_at = ? WHERE id = ? AND user_id = ?`)
    .bind(title, doneAt, position, week, now(), row.id, userId)
    .run();
  const fresh = await db.prepare(`SELECT * FROM flex_tasks WHERE id = ?`).bind(row.id).first<FlexTaskRow>();
  return c.json(toFlexTask(fresh!));
});

calendar.delete("/flex-tasks/:id", async (c) => {
  const db = c.env.DB;
  const userId = c.get("user").id;
  const row = await db.prepare(`SELECT id FROM flex_tasks WHERE id = ? AND user_id = ?`).bind(c.req.param("id"), userId).first<{ id: string }>();
  if (!row) return c.json({ error: "not_found" }, 404);
  await db.prepare(`DELETE FROM flex_tasks WHERE id = ? AND user_id = ?`).bind(row.id, userId).run();
  return c.json({ ok: true });
});

/* ---------- time tracking ---------- */

calendar.get("/time", async (c) => {
  const { userId, settings, tz, today } = await ctx(c);
  const qFrom = c.req.query("from") ?? "";
  const qTo = c.req.query("to") ?? "";
  if ((qFrom && !isValidDate(qFrom)) || (qTo && !isValidDate(qTo))) return c.json({ error: "bad_date" }, 400);
  const from = qFrom || weekStartOf(today, settings.week_start);
  const to = qTo || addDays(from, 6);
  const span = daysBetween(from, to);
  if (span < 0) return c.json({ error: "bad_range" }, 400);
  if (span > MAX_SPAN_DAYS) return c.json({ error: "range_too_wide" }, 400);
  // Anything overlapping the window, running entries included.
  const rows = await c.env.DB.prepare(
    `SELECT * FROM time_entries WHERE user_id = ? AND started_at <= ? AND (ended_at IS NULL OR ended_at >= ?) ORDER BY started_at DESC LIMIT 1000`
  )
    .bind(userId, endOfDay(to, tz), startOfDay(from, tz))
    .all<TimeEntryRow>();
  return c.json(rows.results.map(toTimeEntry));
});

// Starting a stopwatch stops whatever was already running — only one at a time.
calendar.post("/time", async (c) => {
  const db = c.env.DB;
  const userId = c.get("user").id;
  const b = await body<{ title: string; started_at: number; event_id: string }>(c);
  const title = trimmed(b.title, 500);
  let eventId: string | null = null;
  if (typeof b.event_id === "string" && b.event_id) {
    const ev = await ownedEvent(db, userId, parseEventId(b.event_id).id);
    if (!ev) return c.json({ error: "not_found" }, 404);
    eventId = ev.id;
  }
  const t = now();
  const started = ms(b.started_at) ?? t;
  await db.prepare(`UPDATE time_entries SET ended_at = ?, updated_at = ? WHERE user_id = ? AND ended_at IS NULL`).bind(started, t, userId).run();
  const id = uid();
  await db
    .prepare(`INSERT INTO time_entries (id, user_id, title, event_id, started_at, ended_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, NULL, ?, ?)`)
    .bind(id, userId, title, eventId, started, t, t)
    .run();
  const row = await db.prepare(`SELECT * FROM time_entries WHERE id = ?`).bind(id).first<TimeEntryRow>();
  return c.json(toTimeEntry(row!));
});

calendar.post("/time/:id/stop", async (c) => {
  const db = c.env.DB;
  const userId = c.get("user").id;
  const row = await db.prepare(`SELECT * FROM time_entries WHERE id = ? AND user_id = ?`).bind(c.req.param("id"), userId).first<TimeEntryRow>();
  if (!row) return c.json({ error: "not_found" }, 404);
  if (row.ended_at === null) {
    const t = now();
    await db.prepare(`UPDATE time_entries SET ended_at = ?, updated_at = ? WHERE id = ? AND user_id = ?`).bind(Math.max(t, row.started_at), t, row.id, userId).run();
  }
  const fresh = await db.prepare(`SELECT * FROM time_entries WHERE id = ?`).bind(row.id).first<TimeEntryRow>();
  return c.json(toTimeEntry(fresh!));
});

calendar.patch("/time/:id", async (c) => {
  const db = c.env.DB;
  const userId = c.get("user").id;
  const row = await db.prepare(`SELECT * FROM time_entries WHERE id = ? AND user_id = ?`).bind(c.req.param("id"), userId).first<TimeEntryRow>();
  if (!row) return c.json({ error: "not_found" }, 404);
  const b = await body<{ title: string; started_at: number; ended_at: number | null; event_id: string | null }>(c);
  const title = typeof b.title === "string" ? b.title.trim().slice(0, 500) : row.title;
  const started = ms(b.started_at) ?? row.started_at;
  const ended = b.ended_at === null ? null : ms(b.ended_at) ?? row.ended_at;
  if (ended !== null && ended < started) return c.json({ error: "bad_range" }, 400);
  let eventId = row.event_id;
  if (b.event_id === null) eventId = null;
  else if (typeof b.event_id === "string" && b.event_id) {
    const ev = await ownedEvent(db, userId, parseEventId(b.event_id).id);
    if (!ev) return c.json({ error: "not_found" }, 404);
    eventId = ev.id;
  }
  await db
    .prepare(`UPDATE time_entries SET title = ?, started_at = ?, ended_at = ?, event_id = ?, updated_at = ? WHERE id = ? AND user_id = ?`)
    .bind(title, started, ended, eventId, now(), row.id, userId)
    .run();
  const fresh = await db.prepare(`SELECT * FROM time_entries WHERE id = ?`).bind(row.id).first<TimeEntryRow>();
  return c.json(toTimeEntry(fresh!));
});

calendar.delete("/time/:id", async (c) => {
  const db = c.env.DB;
  const userId = c.get("user").id;
  const row = await db.prepare(`SELECT id FROM time_entries WHERE id = ? AND user_id = ?`).bind(c.req.param("id"), userId).first<{ id: string }>();
  if (!row) return c.json({ error: "not_found" }, 404);
  await db.prepare(`DELETE FROM time_entries WHERE id = ? AND user_id = ?`).bind(row.id, userId).run();
  return c.json({ ok: true });
});

/* ---------- settings ---------- */

calendar.get("/settings", async (c) => c.json(toSettings(await getSettings(c.env.DB, c.get("user").id))));

calendar.put("/settings", async (c) => {
  const userId = c.get("user").id;
  const b = await body<{
    timezone: string;
    week_start: number;
    night_start: number;
    night_end: number;
    collapse_night: boolean;
    time_format: string;
    default_view: string;
    show_declined: boolean;
    cover_art: boolean;
  }>(c);
  const patch: SettingsPatch = {};
  if (typeof b.timezone === "string") patch.timezone = b.timezone.trim().slice(0, 80);
  if (b.week_start !== undefined) patch.week_start = int(b.week_start, 0, 6, 1);
  if (b.night_start !== undefined) patch.night_start = int(b.night_start, 0, 23, 22);
  if (b.night_end !== undefined) patch.night_end = int(b.night_end, 0, 23, 6);
  if (typeof b.collapse_night === "boolean") patch.collapse_night = b.collapse_night;
  if (typeof b.time_format === "string") {
    if (b.time_format !== "12" && b.time_format !== "24") return c.json({ error: "bad_time_format" }, 400);
    patch.time_format = b.time_format;
  }
  if (typeof b.default_view === "string") {
    if (!["days", "week", "month", "year", "agenda"].includes(b.default_view)) return c.json({ error: "bad_view" }, 400);
    patch.default_view = b.default_view;
  }
  if (typeof b.show_declined === "boolean") patch.show_declined = b.show_declined;
  if (typeof b.cover_art === "boolean") patch.cover_art = b.cover_art;
  return c.json(toSettings(await putSettings(c.env.DB, userId, patch)));
});

export default calendar;
