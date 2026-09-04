// Google Calendar v3: list the account's calendars, pull a calendar's events into `events`
// (incrementally, by syncToken), and push our own creates/updates/deletes/RSVPs back.
//
// Google is asked for pre-expanded instances (`singleEvents=true`), so every row we store here is a
// single occurrence with `rrule` NULL — heyflare only expands recurrence itself for `local` and
// `ics` calendars.

import type { Env } from "../env";
import type { AccountRow } from "../db";
import { uid, now, chunk, safeJson, runBatch, logSync } from "../db";
import { googleFetch, GmailError, hasCalendarScope } from "../google";
import type { CalendarRow, EventRow } from "./types";
import { dateKey } from "./dates";
import type { EventAttendee, Reminder, Rsvp } from "@shared/types";

const API = "https://www.googleapis.com/calendar/v3";
const DAY = 86_400_000;
/** How far back and forward a first sync reaches. Later syncs follow the syncToken instead. */
const WINDOW_BACK_DAYS = 120;
const WINDOW_FWD_DAYS = 540;
const PAGE_LIMIT = 40;
/** 27 bound parameters per upsert; 50 statements a batch keeps D1 comfortable. */
const BATCH_SIZE = 50;

const RSVP_VALUES = new Set(["needsAction", "accepted", "declined", "tentative"]);

// ---------- Google's shapes ----------
interface GTime {
  date?: string;
  dateTime?: string;
  timeZone?: string;
}
interface GAttendee {
  email?: string;
  displayName?: string;
  responseStatus?: string;
  optional?: boolean;
  organizer?: boolean;
  self?: boolean;
  resource?: boolean;
}
interface GEvent {
  id?: string;
  etag?: string;
  status?: string;
  summary?: string;
  description?: string;
  location?: string;
  htmlLink?: string;
  hangoutLink?: string;
  iCalUID?: string;
  transparency?: string;
  start?: GTime;
  end?: GTime;
  organizer?: { email?: string; displayName?: string; self?: boolean };
  attendees?: GAttendee[];
  conferenceData?: { entryPoints?: { entryPointType?: string; uri?: string }[] };
  reminders?: { useDefault?: boolean; overrides?: { method?: string; minutes?: number }[] };
}
interface GEventList {
  items?: GEvent[];
  nextPageToken?: string;
  nextSyncToken?: string;
}
interface GCalendarListEntry {
  id?: string;
  summary?: string;
  summaryOverride?: string;
  description?: string;
  backgroundColor?: string;
  foregroundColor?: string;
  timeZone?: string;
  accessRole?: string;
  primary?: boolean;
  deleted?: boolean;
}
interface GCalendarList {
  items?: GCalendarListEntry[];
  nextPageToken?: string;
}

export interface RemoteCalendar {
  remote_id: string;
  name: string;
  description: string;
  color: string;
  timezone: string;
  writable: boolean;
  primary: boolean;
}

// ---------- Plumbing ----------

/** Fail before making a doomed request when the refresh token never carried the Calendar scope. */
function requireScope(account: AccountRow): void {
  if (!hasCalendarScope(account.scopes)) {
    throw new GmailError(
      403,
      "calendar_scope_missing",
      `${account.email} is not connected to Google Calendar. Reconnect the account to grant calendar access.`
    );
  }
}

/** The Google calendarId this row points at. */
function remoteCalendarId(cal: CalendarRow): string {
  if (cal.source !== "google" || !cal.remote_id) {
    throw new GmailError(400, "not_a_google_calendar", `Calendar ${cal.id} is not a Google calendar`);
  }
  return cal.remote_id;
}

function eventsUrl(cal: CalendarRow, suffix = ""): string {
  return `${API}/calendars/${encodeURIComponent(remoteCalendarId(cal))}/events${suffix}`;
}

/** An authed Calendar request that turns any non-2xx into a GmailError, naming a missing scope. */
async function calJson<T = any>(env: Env, account: AccountRow, url: string, init: RequestInit = {}): Promise<T> {
  const res = await googleFetch(env, account, url, init);
  const text = await res.text();
  if (!res.ok) {
    if (res.status === 403 && /insufficient|scope|ACCESS_TOKEN_SCOPE|forbidden/i.test(text)) {
      throw new GmailError(
        403,
        "calendar_scope_missing",
        `Google refused calendar access for ${account.email}: the account is missing the Calendar scope. Reconnect it to grant access.`
      );
    }
    throw new GmailError(res.status, text);
  }
  return (text ? JSON.parse(text) : {}) as T;
}

// ---------- Dates ----------

const dayMs = (date: string) => Date.parse(`${date}T00:00:00Z`);
/** Shift a "YYYY-MM-DD" by whole days, staying in UTC. */
const shiftDate = (date: string, days: number) => dateKey(dayMs(date) + days * DAY, "UTC");

// ---------- Reading ----------

/** GET users/me/calendarList. Throws GmailError; a 403 for a missing scope surfaces clearly. */
export async function listRemoteCalendars(env: Env, account: AccountRow): Promise<RemoteCalendar[]> {
  requireScope(account);
  const out: RemoteCalendar[] = [];
  let pageToken: string | undefined;
  let pages = 0;
  do {
    const u = new URL(`${API}/users/me/calendarList`);
    u.searchParams.set("maxResults", "250");
    u.searchParams.set("showHidden", "true");
    if (pageToken) u.searchParams.set("pageToken", pageToken);
    const j = await calJson<GCalendarList>(env, account, u.toString());
    for (const c of j.items ?? []) {
      if (!c.id || c.deleted) continue;
      out.push({
        remote_id: c.id,
        name: c.summaryOverride || c.summary || c.id,
        description: c.description ?? "",
        color: c.backgroundColor ?? "",
        timezone: c.timeZone ?? "",
        writable: c.accessRole === "owner" || c.accessRole === "writer",
        primary: !!c.primary,
      });
    }
    pageToken = j.nextPageToken;
    pages++;
  } while (pageToken && pages < PAGE_LIMIT);
  return out;
}

/** Map one instance Google handed us onto our column values. */
function mapEvent(cal: CalendarRow, g: GEvent): Omit<EventRow, "id" | "created_at"> & { created_at: number } {
  const t = now();
  const attendees: EventAttendee[] = (g.attendees ?? [])
    .filter((a) => !!a.email)
    .map((a) => ({
      email: (a.email ?? "").toLowerCase(),
      name: a.displayName ?? "",
      rsvp: (a.responseStatus ?? "") as Rsvp,
      optional: !!a.optional,
      organizer: !!a.organizer,
    }));

  const entries = g.conferenceData?.entryPoints ?? [];
  const video = entries.find((e) => e.entryPointType === "video" && e.uri);
  const conference = g.hangoutLink || video?.uri || entries.find((e) => !!e.uri)?.uri || "";

  const reminders: Reminder[] =
    g.reminders && g.reminders.useDefault === false
      ? (g.reminders.overrides ?? []).filter((o) => typeof o.minutes === "number").map((o) => ({ minutes: o.minutes as number }))
      : [];

  const allDay = !!g.start?.date;
  let startsAt: number;
  let endsAt: number;
  let startDate: string | null = null;
  let endDate: string | null = null;
  let timezone = "";

  if (allDay) {
    const s = g.start!.date!;
    // Google's end.date is exclusive; we store the inclusive last day but keep the exclusive
    // midnight in ends_at so half-open window queries still work.
    const exclusiveEnd = g.end?.date && dayMs(g.end.date) > dayMs(s) ? g.end.date : shiftDate(s, 1);
    startDate = s;
    endDate = shiftDate(exclusiveEnd, -1);
    startsAt = dayMs(s);
    endsAt = dayMs(exclusiveEnd);
  } else {
    startsAt = Date.parse(g.start?.dateTime ?? "");
    endsAt = Date.parse(g.end?.dateTime ?? g.start?.dateTime ?? "");
    if (!Number.isFinite(startsAt)) startsAt = t;
    if (!Number.isFinite(endsAt)) endsAt = startsAt;
    timezone = g.start?.timeZone ?? "";
  }

  const self = (g.attendees ?? []).find((a) => a.self);

  return {
    user_id: cal.user_id,
    calendar_id: cal.id,
    remote_id: g.id ?? null,
    ical_uid: g.iCalUID ?? null,
    kind: "event",
    title: g.summary ?? "",
    description: g.description ?? "",
    location: g.location ?? "",
    emoji: "",
    all_day: allDay ? 1 : 0,
    starts_at: startsAt,
    ends_at: endsAt,
    start_date: startDate,
    end_date: endDate,
    timezone,
    rrule: null,
    exdates: "",
    master_id: null,
    occurrence_date: null,
    status: g.status === "tentative" ? "tentative" : g.status === "cancelled" ? "cancelled" : "confirmed",
    busy: g.transparency === "transparent" ? 0 : 1,
    countdown: 0,
    circled: 0,
    organizer_email: (g.organizer?.email ?? "").toLowerCase(),
    organizer_name: g.organizer?.displayName ?? "",
    attendees_json: JSON.stringify(attendees),
    rsvp: self?.responseStatus ?? "",
    conference_url: conference,
    url: g.htmlLink ?? "",
    reminders_json: JSON.stringify(reminders),
    thread_id: null,
    message_id: null,
    done_at: null,
    etag: g.etag ?? null,
    created_at: t,
    updated_at: t,
  };
}

const UPSERT_SQL = `INSERT INTO events (
  id, user_id, calendar_id, remote_id, ical_uid, kind, title, description, location, all_day,
  starts_at, ends_at, start_date, end_date, timezone, status, busy, organizer_email, organizer_name,
  attendees_json, rsvp, conference_url, url, reminders_json, etag, created_at, updated_at
) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(calendar_id, remote_id) DO UPDATE SET
  ical_uid = excluded.ical_uid,
  title = excluded.title,
  description = excluded.description,
  location = excluded.location,
  all_day = excluded.all_day,
  starts_at = excluded.starts_at,
  ends_at = excluded.ends_at,
  start_date = excluded.start_date,
  end_date = excluded.end_date,
  timezone = excluded.timezone,
  status = excluded.status,
  busy = excluded.busy,
  organizer_email = excluded.organizer_email,
  organizer_name = excluded.organizer_name,
  attendees_json = excluded.attendees_json,
  rsvp = excluded.rsvp,
  conference_url = excluded.conference_url,
  url = excluded.url,
  reminders_json = excluded.reminders_json,
  etag = excluded.etag,
  rrule = NULL,
  master_id = NULL,
  occurrence_date = NULL,
  updated_at = excluded.updated_at`;

/** Write one page of instances: upsert the live ones, delete the cancelled ones. */
async function applyPage(env: Env, cal: CalendarRow, items: GEvent[]): Promise<{ changed: number; deleted: number }> {
  const db = env.DB;
  const stmts: D1PreparedStatement[] = [];
  let changed = 0;
  let deleted = 0;

  for (const g of items) {
    if (!g.id) continue;
    // In an incremental response a cancelled instance means the occurrence is gone.
    if (g.status === "cancelled") {
      stmts.push(db.prepare(`DELETE FROM events WHERE calendar_id = ? AND remote_id = ?`).bind(cal.id, g.id));
      deleted++;
      continue;
    }
    const r = mapEvent(cal, g);
    stmts.push(
      db
        .prepare(UPSERT_SQL)
        .bind(
          uid(),
          r.user_id,
          r.calendar_id,
          r.remote_id,
          r.ical_uid,
          r.kind,
          r.title,
          r.description,
          r.location,
          r.all_day,
          r.starts_at,
          r.ends_at,
          r.start_date,
          r.end_date,
          r.timezone,
          r.status,
          r.busy,
          r.organizer_email,
          r.organizer_name,
          r.attendees_json,
          r.rsvp,
          r.conference_url,
          r.url,
          r.reminders_json,
          r.etag,
          r.created_at,
          r.updated_at
        )
    );
    changed++;
  }

  await runBatch(db, stmts, BATCH_SIZE);
  return { changed, deleted };
}

/**
 * Walk every page of one pull and apply it as we go.
 * `syncToken` may not be combined with timeMin/timeMax/orderBy — Google rejects that outright —
 * so the two request shapes stay strictly separate.
 */
async function pull(
  env: Env,
  cal: CalendarRow,
  account: AccountRow,
  syncToken: string | null
): Promise<{ changed: number; deleted: number; nextSyncToken: string | null }> {
  let changed = 0;
  let deleted = 0;
  let nextSyncToken: string | null = null;
  let pageToken: string | undefined;
  let pages = 0;

  do {
    const u = new URL(eventsUrl(cal));
    u.searchParams.set("singleEvents", "true");
    u.searchParams.set("maxResults", "2500");
    if (syncToken) {
      u.searchParams.set("syncToken", syncToken);
    } else {
      const t = now();
      u.searchParams.set("showDeleted", "false");
      u.searchParams.set("timeMin", new Date(t - WINDOW_BACK_DAYS * DAY).toISOString());
      u.searchParams.set("timeMax", new Date(t + WINDOW_FWD_DAYS * DAY).toISOString());
    }
    if (pageToken) u.searchParams.set("pageToken", pageToken);

    const j = await calJson<GEventList>(env, account, u.toString());
    const applied = await applyPage(env, cal, j.items ?? []);
    changed += applied.changed;
    deleted += applied.deleted;
    if (j.nextSyncToken) nextSyncToken = j.nextSyncToken;
    pageToken = j.nextPageToken;
    pages++;
  } while (pageToken && pages < PAGE_LIMIT);

  return { changed, deleted, nextSyncToken };
}

/** How stale a quiet calendar's `last_synced_at` may get before it is written for its own sake. */
const HEARTBEAT_MS = 10 * 60_000;

/** Pull this calendar's events into the `events` table. Incremental when `sync_token` is set. */
export async function syncGoogleCalendar(env: Env, cal: CalendarRow, account: AccountRow): Promise<{ changed: number; deleted: number }> {
  requireScope(account);
  const db = env.DB;
  remoteCalendarId(cal);

  // No 'syncing' marker on the way in: a token-based poll answers in well under a second, and the
  // cron is the only caller that runs often enough to care. Marking it would cost a row a minute
  // per calendar to describe a state nobody is ever fast enough to observe.
  try {
    let res: { changed: number; deleted: number; nextSyncToken: string | null };
    try {
      res = await pull(env, cal, account, cal.sync_token);
    } catch (e) {
      // 410 Gone: the sync token expired. Drop it and do one full sync — once, never in a loop.
      if (cal.sync_token && e instanceof GmailError && e.status === 410) {
        await logSync(db, cal.account_id, "warn", `Calendar "${cal.name}": sync token expired, doing a full sync`);
        cal.sync_token = null;
        await db.prepare(`UPDATE calendars SET sync_token = NULL WHERE id = ?`).bind(cal.id).run();
        res = await pull(env, cal, account, null);
      } else {
        throw e;
      }
    }

    const t = now();
    const token = res.nextSyncToken ?? cal.sync_token;
    // Google issues a fresh sync token on every poll, but the previous one stays valid until it
    // expires — so a poll that found nothing has nothing worth persisting. Storing the new token
    // anyway, along with a timestamp, is a write per calendar per minute that changes no answer
    // this app can give. The heartbeat keeps "last synced" honest without paying that every tick.
    const quiet = res.changed === 0 && res.deleted === 0;
    const stale = t - (cal.last_synced_at ?? 0) > HEARTBEAT_MS;
    // Read the row's previous state before overwriting it: a calendar coming back from an error
    // has to be written even on a poll that found nothing, or the UI keeps showing the old failure.
    const recovering = cal.sync_status !== "idle" || !!cal.sync_error;
    cal.sync_status = "idle";
    cal.sync_error = null;
    if (!quiet || stale || recovering) {
      cal.sync_token = token;
      cal.last_synced_at = t;
      await db
        .prepare(`UPDATE calendars SET sync_token = ?, sync_status = 'idle', sync_error = NULL, last_synced_at = ?, updated_at = ? WHERE id = ?`)
        .bind(cal.sync_token, t, t, cal.id)
        .run();
    }
    return { changed: res.changed, deleted: res.deleted };
  } catch (e) {
    const msg = (e as Error).message ?? String(e);
    const t = now();
    cal.sync_status = "error";
    cal.sync_error = msg.slice(0, 1000);
    cal.last_synced_at = t;
    await db
      .prepare(`UPDATE calendars SET sync_status = 'error', sync_error = ?, last_synced_at = ?, updated_at = ? WHERE id = ?`)
      .bind(cal.sync_error, t, t, cal.id)
      .run();
    await logSync(db, cal.account_id, "error", `Calendar sync failed for "${cal.name}": ${msg}`);
    throw e;
  }
}

// ---------- Writing back ----------

/** The Google request body for one of our rows. */
function eventBody(row: EventRow): Record<string, unknown> {
  const attendees = safeJson<EventAttendee[]>(row.attendees_json, []);
  const reminders = safeJson<Reminder[]>(row.reminders_json, []);

  const body: Record<string, unknown> = {
    summary: row.title,
    description: row.description,
    location: row.location,
    status: row.status === "cancelled" ? "confirmed" : row.status,
    transparency: row.busy ? "opaque" : "transparent",
    reminders: {
      useDefault: false,
      overrides: reminders.filter((r) => typeof r.minutes === "number").map((r) => ({ method: "popup", minutes: r.minutes })),
    },
  };

  if (row.all_day) {
    const start = row.start_date ?? dateKey(row.starts_at, "UTC");
    const lastDay = row.end_date ?? start;
    // Google wants an exclusive end date.
    body.start = { date: start };
    body.end = { date: shiftDate(lastDay, 1) };
  } else {
    const tz = row.timezone || undefined;
    body.start = { dateTime: new Date(row.starts_at).toISOString(), ...(tz ? { timeZone: tz } : {}) };
    body.end = { dateTime: new Date(row.ends_at || row.starts_at).toISOString(), ...(tz ? { timeZone: tz } : {}) };
  }

  if (row.rrule) body.recurrence = [`RRULE:${row.rrule.replace(/^RRULE:/i, "")}`];

  if (attendees.length) {
    body.attendees = attendees.map((a) => ({
      email: a.email,
      ...(a.name ? { displayName: a.name } : {}),
      ...(a.optional ? { optional: true } : {}),
      ...(a.rsvp ? { responseStatus: a.rsvp } : {}),
    }));
  }

  return body;
}

const sendUpdates = (row: EventRow) => (safeJson<EventAttendee[]>(row.attendees_json, []).length ? "all" : "none");

export async function createRemoteEvent(
  env: Env,
  cal: CalendarRow,
  account: AccountRow,
  row: EventRow
): Promise<{ remote_id: string; etag: string | null }> {
  requireScope(account);
  const u = new URL(eventsUrl(cal));
  u.searchParams.set("sendUpdates", sendUpdates(row));
  const j = await calJson<GEvent>(env, account, u.toString(), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(eventBody(row)),
  });
  if (!j.id) throw new GmailError(500, JSON.stringify(j).slice(0, 300), "Google created the event but returned no id");
  return { remote_id: j.id, etag: j.etag ?? null };
}

export async function updateRemoteEvent(env: Env, cal: CalendarRow, account: AccountRow, row: EventRow): Promise<{ etag: string | null }> {
  requireScope(account);
  if (!row.remote_id) throw new GmailError(400, "no_remote_id", "Event has no Google id to update");
  const u = new URL(eventsUrl(cal, `/${encodeURIComponent(row.remote_id)}`));
  u.searchParams.set("sendUpdates", sendUpdates(row));
  // PATCH, not PUT. A PUT replaces the whole event with what we send, and we do not model all of
  // it: `eventType` is the one that bites, because a birthday, holiday, out-of-office or
  // Gmail-derived event silently becomes `default` and Google rejects the lot with
  // "Event type cannot be changed" — after which the next sync pulls the unchanged event back and
  // the edit appears to undo itself. Omitting `recurrence` on a master would likewise have dropped
  // the repeat. PATCH touches only the fields named here and leaves the rest of the event alone.
  const j = await calJson<GEvent>(env, account, u.toString(), {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(eventBody(row)),
  });
  return { etag: j.etag ?? null };
}

export async function deleteRemoteEvent(env: Env, cal: CalendarRow, account: AccountRow, remoteId: string): Promise<void> {
  requireScope(account);
  if (!remoteId) return;
  const u = new URL(eventsUrl(cal, `/${encodeURIComponent(remoteId)}`));
  u.searchParams.set("sendUpdates", "all");
  const res = await googleFetch(env, account, u.toString(), { method: "DELETE" });
  // Already gone is the outcome we wanted.
  if (res.ok || res.status === 404 || res.status === 410) return;
  throw new GmailError(res.status, await res.text());
}

/** Patch our own attendee entry's responseStatus, and send the update to the organizer. */
export async function setRemoteRsvp(env: Env, cal: CalendarRow, account: AccountRow, remoteId: string, rsvp: string): Promise<void> {
  requireScope(account);
  if (!remoteId) throw new GmailError(400, "no_remote_id", "Event has no Google id to RSVP to");
  if (!RSVP_VALUES.has(rsvp)) throw new GmailError(400, "bad_rsvp", `Unknown RSVP "${rsvp}"`);

  const base = eventsUrl(cal, `/${encodeURIComponent(remoteId)}`);
  const current = await calJson<GEvent>(env, account, base);
  const attendees = current.attendees ?? [];
  const mine = attendees.find((a) => a.self) ?? attendees.find((a) => (a.email ?? "").toLowerCase() === account.email.toLowerCase());
  if (!mine) throw new GmailError(400, "not_an_attendee", `${account.email} is not an attendee of this event`);

  // A patch replaces the whole attendee list, so send it back intact with just our entry changed.
  const patched = attendees.map((a) => ({
    email: a.email,
    ...(a.displayName ? { displayName: a.displayName } : {}),
    ...(a.optional ? { optional: true } : {}),
    ...(a.organizer ? { organizer: true } : {}),
    ...(a.resource ? { resource: true } : {}),
    ...(a.self ? { self: true } : {}),
    responseStatus: a === mine ? rsvp : a.responseStatus ?? "needsAction",
  }));

  const u = new URL(base);
  u.searchParams.set("sendUpdates", "all");
  await calJson(env, account, u.toString(), {
    method: "PATCH",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ attendees: patched }),
  });
}
