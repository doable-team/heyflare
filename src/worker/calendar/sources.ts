// Where calendars come from: the Google list mirrored per account, subscribed .ics/webcal feeds,
// uploaded .ics files, and heyflare's own local calendars. Google events are fetched by ./google;
// this module owns the `calendars` rows, the ICS fetch (and its SSRF guard) and the ICS → events write.

import type { Env } from "../env";
import type { AccountRow, UserRow } from "../db";
import { uid, now, chunk, placeholders, runBatch, logSync } from "../db";
import { hasCalendarScope } from "../google";
import { muteHex } from "@shared/color";
import { VERSION } from "@shared/version";
import type { CalendarRow } from "./types";
import { parseIcs, type IcsEvent } from "./ical";
import { listRemoteCalendars, syncGoogleCalendar } from "./google";
import { dateKey } from "./dates";

/** A feed bigger than this is somebody's mistake, not a calendar. */
const MAX_ICS_BYTES = 8 * 1024 * 1024;
/** An uploaded .ics can be a decade of history; past this we stop rather than melt the CPU budget. */
const MAX_IMPORT_EVENTS = 5000;
/** D1 caps bound parameters per batch, and an event row binds ~35 of them. */
const BATCH_SIZE = 50;
const USER_AGENT = `heyflare/${VERSION} (calendar feed sync)`;

// ---------- URL safety ----------

/**
 * Normalise a user-supplied feed URL and refuse anything that would let the Worker fetch something
 * private on our behalf. `webcal://` is just `https://` with a nicer icon.
 */
function safeFeedUrl(input: string): string {
  const raw = (input ?? "").trim();
  if (!raw) throw new Error("A calendar URL is required");
  const swapped = raw.replace(/^webcals?:\/\//i, "https://");
  let u: URL;
  try {
    u = new URL(swapped);
  } catch {
    throw new Error("That does not look like a calendar URL");
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") throw new Error("Only http(s) and webcal calendar URLs can be subscribed to");
  const host = u.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  const isPrivate =
    host === "localhost" ||
    host.endsWith(".localhost") ||
    host.endsWith(".internal") ||
    host === "::1" ||
    host.startsWith("127.") ||
    host.startsWith("10.") ||
    host.startsWith("192.168.") ||
    host.startsWith("169.254.") ||
    host.startsWith("0.") ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(host);
  if (isPrivate) throw new Error("That host is not reachable from heyflare");
  return u.toString();
}

/** Read a response body, giving up as soon as it goes over `max` bytes. */
async function readCapped(res: Response, max: number): Promise<string> {
  const declared = Number(res.headers.get("content-length") ?? 0);
  if (declared > max) throw new Error("That feed is too large (over 8 MB)");
  if (!res.body) return "";
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let out = "";
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value) continue;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel().catch(() => {});
      throw new Error("That feed is too large (over 8 MB)");
    }
    out += decoder.decode(value, { stream: true });
  }
  out += decoder.decode();
  return out;
}

interface FeedResponse {
  /** 304 means the feed is unchanged and `text` is empty. */
  status: number;
  text: string;
  etag: string | null;
}

/**
 * Fetch an ICS feed. Redirects are followed by hand so every hop goes back through the SSRF guard —
 * a public URL that 302s to 169.254.169.254 is the whole point of the attack.
 */
async function fetchFeed(url: string, etag?: string | null): Promise<FeedResponse> {
  let target = safeFeedUrl(url);
  for (let hop = 0; hop < 4; hop++) {
    const headers: Record<string, string> = {
      accept: "text/calendar, text/plain;q=0.8, */*;q=0.5",
      "user-agent": USER_AGENT,
    };
    if (etag) headers["if-none-match"] = etag;
    const res = await fetch(target, { headers, redirect: "manual" });
    if (res.status === 304) return { status: 304, text: "", etag: etag ?? null };
    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get("location");
      if (!loc) throw new Error(`That feed redirected without a Location header (${res.status})`);
      target = safeFeedUrl(new URL(loc, target).toString());
      continue;
    }
    if (!res.ok) throw new Error(`That feed returned ${res.status}`);
    const text = await readCapped(res, MAX_ICS_BYTES);
    if (!/BEGIN:VCALENDAR/i.test(text)) throw new Error("That URL did not return an iCalendar feed");
    return { status: res.status, text, etag: res.headers.get("etag") };
  }
  throw new Error("That feed redirected too many times");
}

// ---------- Google calendar list ----------

async function nextPosition(db: D1Database, userId: string): Promise<number> {
  const r = await db.prepare(`SELECT COALESCE(MAX(position), -1) AS p FROM calendars WHERE user_id = ?`).bind(userId).first<{ p: number }>();
  return (r?.p ?? -1) + 1;
}

async function mirrorGoogleCalendars(env: Env, userId: string, account: AccountRow): Promise<void> {
  const db = env.DB;
  const remote = await listRemoteCalendars(env, account);
  const existing = await db
    .prepare(`SELECT id, remote_id, color FROM calendars WHERE user_id = ? AND account_id = ? AND source = 'google'`)
    .bind(userId, account.id)
    .all<{ id: string; remote_id: string | null; color: string }>();
  const seen = new Set(remote.map((r) => r.remote_id));
  const t = now();
  let position = await nextPosition(db, userId);
  const stmts: D1PreparedStatement[] = [];
  for (const rc of remote) {
    if (!rc.remote_id) continue;
    stmts.push(
      db
        .prepare(
          // Only the columns Google owns are refreshed: name, colour and visibility are the user's
          // once heyflare has them, so they are filled in on insert and never overwritten after.
          `INSERT INTO calendars (id, user_id, account_id, source, remote_id, url, name, description, color, timezone, visible, writable, is_default, position, created_at, updated_at)
           VALUES (?, ?, ?, 'google', ?, NULL, ?, ?, ?, ?, 1, ?, 0, ?, ?, ?)
           ON CONFLICT(account_id, remote_id) DO UPDATE SET
             description = excluded.description,
             timezone = excluded.timezone,
             writable = excluded.writable,
             updated_at = excluded.updated_at`
        )
        .bind(
          uid(),
          userId,
          account.id,
          rc.remote_id,
          rc.name || account.email,
          rc.description ?? "",
          muteHex(rc.color) ?? "#3d3d3d",
          rc.timezone ?? "",
          rc.writable ? 1 : 0,
          position++,
          t,
          t
        )
    );
  }
  await runBatch(db, stmts, BATCH_SIZE);

  // Google's palette is built for pale chips with dark text; heyflare fills the whole block. Any
  // calendar still carrying the raw colour Google sent is one the owner has not chosen for
  // themselves, so quiet it down. A colour they picked never matches the remote one and is left be.
  for (const row of existing.results) {
    const rc = remote.find((r) => r.remote_id === row.remote_id);
    const muted = muteHex(rc?.color);
    if (!rc || !muted || row.color === muted) continue;
    if (row.color.toLowerCase() !== (rc.color ?? "").toLowerCase()) continue;
    await db.prepare(`UPDATE calendars SET color = ?, updated_at = ? WHERE id = ?`).bind(muted, t, row.id).run();
  }

  // Unsubscribed or deleted on Google's side: drop it here too, events and all.
  for (const row of existing.results) {
    if (row.remote_id && seen.has(row.remote_id)) continue;
    await deleteCalendar(db, row.id);
  }
}

/**
 * Called after a Google account connects (or reconnects with the Calendar scope): mirror its
 * calendar list into `calendars`, and make sure the user has at least one writable local calendar.
 * Safe to call as often as you like.
 */
export async function ensureDefaultCalendars(env: Env, userId: string, account?: AccountRow): Promise<void> {
  const db = env.DB;
  if (account && hasCalendarScope(account.scopes)) {
    try {
      await mirrorGoogleCalendars(env, userId, account);
      await db.prepare(`UPDATE accounts SET calendar_error = NULL WHERE id = ?`).bind(account.id).run();
    } catch (e) {
      // A failed calendar list must not break connecting the account; the cron will try again.
      // It is recorded on the account as well as the log, because with no calendar rows there is
      // nowhere else for the UI to read it from — and "no calendars" with no reason is a dead end.
      const message = ((e as Error).message ?? String(e)).slice(0, 500);
      await logSync(db, account.id, "warn", `Calendar list failed: ${message}`);
      await db.prepare(`UPDATE accounts SET calendar_error = ? WHERE id = ?`).bind(message, account.id).run();
    }
  }

  const local = await db.prepare(`SELECT id FROM calendars WHERE user_id = ? AND source = 'local' LIMIT 1`).bind(userId).first<{ id: string }>();
  if (local) return;
  const user = await db.prepare(`SELECT * FROM users WHERE id = ?`).bind(userId).first<UserRow>();
  const name = (user?.name ?? "").trim() || "Personal";
  const t = now();
  await db
    .prepare(
      `INSERT INTO calendars (id, user_id, account_id, source, remote_id, url, name, description, color, timezone, visible, writable, is_default, position, created_at, updated_at)
       VALUES (?, ?, NULL, 'local', NULL, NULL, ?, '', '#111111', '', 1, 1, 1, ?, ?, ?)`
    )
    .bind(uid(), userId, name, await nextPosition(db, userId), t, t)
    .run();
}

// ---------- ICS → events ----------

/** The stable per-calendar key for an ICS event: its UID, plus RECURRENCE-ID for a single overridden occurrence. */
function icsRemoteId(ev: IcsEvent): string {
  return ev.recurrenceId ? `${ev.uid}::${ev.recurrenceId}` : ev.uid;
}

/** ICS dates arrive as `20260104`, `2026-01-04` or `20260104T090000Z`; we store YYYY-MM-DD in the calendar's zone. */
function icsDateKey(value: string, tz: string): string {
  const v = (value ?? "").trim();
  if (!v) return "";
  if (/Z$/i.test(v)) {
    const ms = Date.parse(v.replace(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/i, "$1-$2-$3T$4:$5:$6Z"));
    if (Number.isFinite(ms)) return dateKey(ms, tz || "UTC");
  }
  const m = /^(\d{4})-?(\d{2})-?(\d{2})/.exec(v);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : "";
}

function remindersJson(minutes: number[]): string {
  return JSON.stringify((minutes ?? []).map((m) => ({ minutes: m })));
}

interface PreparedEvent {
  ev: IcsEvent;
  remoteId: string | null;
  id: string;
  masterId: string | null;
  occurrenceDate: string | null;
}

/**
 * Give every parsed event a row id and, for a RECURRENCE-ID override, wire it to the master row it
 * replaces. Recurrence itself is left alone: the master keeps its RRULE and EXDATEs and heyflare
 * expands it per request window.
 */
function prepareEvents(events: IcsEvent[], cal: { timezone: string }, existing: Map<string, string>, keyed: boolean): PreparedEvent[] {
  const out: PreparedEvent[] = [];
  const masters = new Map<string, string>();
  // (calendar_id, remote_id) is unique, so a feed that repeats a UID gets its last copy, not a failed batch.
  const taken = new Set<string>();
  for (const ev of events) {
    if (ev.recurrenceId) continue;
    const remoteId = keyed ? icsRemoteId(ev) : null;
    if (remoteId && taken.has(remoteId)) continue;
    if (remoteId) taken.add(remoteId);
    const id = (remoteId && existing.get(remoteId)) || uid();
    masters.set(ev.uid, id);
    out.push({ ev, remoteId, id, masterId: null, occurrenceDate: null });
  }
  for (const ev of events) {
    if (!ev.recurrenceId) continue;
    const remoteId = keyed ? icsRemoteId(ev) : null;
    if (remoteId && taken.has(remoteId)) continue;
    if (remoteId) taken.add(remoteId);
    const id = (remoteId && existing.get(remoteId)) || uid();
    const tz = ev.tzid || cal.timezone || "UTC";
    out.push({
      ev,
      remoteId,
      id,
      masterId: masters.get(ev.uid) ?? null,
      occurrenceDate: icsDateKey(ev.recurrenceId, tz) || null,
    });
  }
  return out;
}

function insertEventStmt(db: D1Database, cal: CalendarRow, p: PreparedEvent, t: number): D1PreparedStatement {
  const ev = p.ev;
  return db
    .prepare(
      `INSERT INTO events (id, user_id, calendar_id, remote_id, ical_uid, kind, title, description, location, emoji, all_day, starts_at, ends_at, start_date, end_date, timezone, rrule, exdates, master_id, occurrence_date, status, busy, countdown, circled, organizer_email, organizer_name, attendees_json, rsvp, conference_url, url, reminders_json, etag, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, 'event', ?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?, '', ?, ?, ?, ?, ?, ?)`
    )
    .bind(
      p.id,
      cal.user_id,
      cal.id,
      p.remoteId,
      ev.uid,
      ev.summary ?? "",
      ev.description ?? "",
      ev.location ?? "",
      ev.allDay ? 1 : 0,
      ev.startsAt,
      ev.endsAt,
      ev.startDate,
      ev.endDate,
      ev.tzid || cal.timezone || "",
      ev.rrule,
      (ev.exdates ?? []).map((d: string) => icsDateKey(d, ev.tzid || cal.timezone || "UTC")).filter(Boolean).join(","),
      p.masterId,
      p.occurrenceDate,
      ev.status ?? "confirmed",
      ev.busy ? 1 : 0,
      ev.organizer?.email ?? "",
      ev.organizer?.name ?? "",
      JSON.stringify(ev.attendees ?? []),
      ev.conferenceUrl ?? "",
      ev.url ?? "",
      remindersJson(ev.reminders),
      ev.lastModified ? String(ev.lastModified) : null,
      t,
      t
    );
}

function updateEventStmt(db: D1Database, cal: CalendarRow, p: PreparedEvent, t: number): D1PreparedStatement {
  const ev = p.ev;
  // `circled`, `countdown`, `emoji` and `done_at` are heyflare's, not the feed's — left untouched.
  return db
    .prepare(
      `UPDATE events SET ical_uid = ?, title = ?, description = ?, location = ?, all_day = ?, starts_at = ?, ends_at = ?, start_date = ?, end_date = ?, timezone = ?, rrule = ?, exdates = ?, master_id = ?, occurrence_date = ?, status = ?, busy = ?, organizer_email = ?, organizer_name = ?, attendees_json = ?, conference_url = ?, url = ?, reminders_json = ?, etag = ?, updated_at = ? WHERE id = ?`
    )
    .bind(
      ev.uid,
      ev.summary ?? "",
      ev.description ?? "",
      ev.location ?? "",
      ev.allDay ? 1 : 0,
      ev.startsAt,
      ev.endsAt,
      ev.startDate,
      ev.endDate,
      ev.tzid || cal.timezone || "",
      ev.rrule,
      (ev.exdates ?? []).map((d: string) => icsDateKey(d, ev.tzid || cal.timezone || "UTC")).filter(Boolean).join(","),
      p.masterId,
      p.occurrenceDate,
      ev.status ?? "confirmed",
      ev.busy ? 1 : 0,
      ev.organizer?.email ?? "",
      ev.organizer?.name ?? "",
      JSON.stringify(ev.attendees ?? []),
      ev.conferenceUrl ?? "",
      ev.url ?? "",
      remindersJson(ev.reminders),
      ev.lastModified ? String(ev.lastModified) : null,
      t,
      p.id
    );
}

/** A subscribed feed is the truth: whatever it no longer lists is gone from that calendar. */
async function replaceIcsEvents(env: Env, cal: CalendarRow, events: IcsEvent[]): Promise<number> {
  const db = env.DB;
  const rows = await db
    .prepare(`SELECT id, remote_id FROM events WHERE calendar_id = ?`)
    .bind(cal.id)
    .all<{ id: string; remote_id: string | null }>();
  const existing = new Map<string, string>();
  for (const r of rows.results) if (r.remote_id) existing.set(r.remote_id, r.id);

  const prepared = prepareEvents(events, cal, existing, true);
  const t = now();
  const stmts: D1PreparedStatement[] = [];
  const kept = new Set<string>();
  for (const p of prepared) {
    if (!p.remoteId) continue;
    kept.add(p.remoteId);
    if (existing.has(p.remoteId)) stmts.push(updateEventStmt(db, cal, p, t));
    else stmts.push(insertEventStmt(db, cal, p, t));
  }
  await runBatch(db, stmts, BATCH_SIZE);

  const stale = [...existing.entries()].filter(([remoteId]) => !kept.has(remoteId)).map(([, id]) => id);
  for (const part of chunk(stale, 90)) {
    await db.prepare(`DELETE FROM event_completions WHERE event_id IN (${placeholders(part.length)})`).bind(...part).run();
    await db.prepare(`DELETE FROM events WHERE id IN (${placeholders(part.length)})`).bind(...part).run();
  }
  return prepared.length + stale.length;
}

// ---------- Public API ----------

/** Subscribe to an .ics / webcal:// feed. Fetches once so a bad URL fails loudly at subscribe time. */
export async function subscribeIcs(env: Env, userId: string, url: string, opts?: { name?: string; color?: string }): Promise<CalendarRow> {
  const db = env.DB;
  const feedUrl = safeFeedUrl(url);
  const res = await fetchFeed(feedUrl);
  const parsed = parseIcs(res.text);

  const t = now();
  const id = uid();
  const name = (opts?.name ?? "").trim() || parsed.name.trim() || new URL(feedUrl).hostname;
  const color = (opts?.color ?? "").trim() || parsed.color || "#111111";
  await db
    .prepare(
      `INSERT INTO calendars (id, user_id, account_id, source, remote_id, url, name, description, color, timezone, visible, writable, is_default, position, etag, last_synced_at, sync_status, created_at, updated_at)
       VALUES (?, ?, NULL, 'ics', NULL, ?, ?, '', ?, ?, 1, 0, 0, ?, ?, ?, 'idle', ?, ?)`
    )
    .bind(id, userId, feedUrl, name.slice(0, 200), color, parsed.timezone ?? "", await nextPosition(db, userId), res.etag, t, t, t)
    .run();

  const cal = (await db.prepare(`SELECT * FROM calendars WHERE id = ?`).bind(id).first<CalendarRow>())!;
  try {
    await replaceIcsEvents(env, cal, parsed.events);
  } catch (e) {
    // Subscribing is all or nothing: leave no half-written calendar behind.
    await logSync(db, null, "error", `ICS subscribe "${name}" failed: ${(e as Error).message ?? String(e)}`);
    await deleteCalendar(db, id);
    throw e;
  }
  return { ...cal, sync_status: "idle" };
}

/** Re-fetch a subscribed feed and replace its events. A 304 costs us nothing. */
export async function refreshIcsCalendar(env: Env, cal: CalendarRow): Promise<{ changed: number }> {
  const db = env.DB;
  if (!cal.url) throw new Error("That calendar has no feed URL");
  await db.prepare(`UPDATE calendars SET sync_status = 'syncing', updated_at = ? WHERE id = ?`).bind(now(), cal.id).run();
  try {
    const res = await fetchFeed(cal.url, cal.etag);
    if (res.status === 304) {
      await db.prepare(`UPDATE calendars SET sync_status = 'idle', sync_error = NULL, last_synced_at = ?, updated_at = ? WHERE id = ?`).bind(now(), now(), cal.id).run();
      return { changed: 0 };
    }
    const parsed = parseIcs(res.text);
    const changed = await replaceIcsEvents(env, cal, parsed.events);
    const t = now();
    await db
      .prepare(`UPDATE calendars SET sync_status = 'idle', sync_error = NULL, etag = ?, timezone = ?, last_synced_at = ?, updated_at = ? WHERE id = ?`)
      .bind(res.etag, parsed.timezone || cal.timezone, t, t, cal.id)
      .run();
    return { changed };
  } catch (e) {
    const msg = (e as Error).message ?? String(e);
    const t = now();
    // The last good events stay put; the calendar just wears its error until the next run.
    await db.prepare(`UPDATE calendars SET sync_status = 'error', sync_error = ?, last_synced_at = ?, updated_at = ? WHERE id = ?`).bind(msg.slice(0, 1000), t, t, cal.id).run();
    await logSync(db, cal.account_id, "error", `ICS sync failed for "${cal.name}": ${msg}`);
    throw e;
  }
}

/** Import an uploaded .ics body into a writable calendar; the events become ordinary editable rows. */
export async function importIcs(env: Env, userId: string, calendarId: string, text: string): Promise<{ added: number }> {
  const db = env.DB;
  const cal = await db.prepare(`SELECT * FROM calendars WHERE id = ? AND user_id = ?`).bind(calendarId, userId).first<CalendarRow>();
  if (!cal) throw new Error("Calendar not found");
  if (!cal.writable) throw new Error("That calendar is read-only");
  if (!/BEGIN:VCALENDAR/i.test(text ?? "")) throw new Error("That file is not an iCalendar (.ics) file");

  const parsed = parseIcs(text);
  const events = parsed.events.slice(0, MAX_IMPORT_EVENTS);
  if (!events.length) return { added: 0 };
  // Fresh ids and no remote_id: imported events belong to the user now, not to the file.
  const prepared = prepareEvents(events, cal, new Map(), false);
  const t = now();
  await runBatch(
    db,
    prepared.map((p) => insertEventStmt(db, cal, p, t)),
    BATCH_SIZE
  );
  await logSync(db, cal.account_id, "info", `Imported ${prepared.length} events into "${cal.name}"`);
  return { added: prepared.length };
}

/** Sync one calendar of any source. A `local` calendar is a no-op. */
export async function syncCalendarNow(env: Env, cal: CalendarRow): Promise<{ changed: number }> {
  const db = env.DB;
  if (cal.source === "local") return { changed: 0 };
  if (cal.source === "ics") return refreshIcsCalendar(env, cal);

  const account = cal.account_id ? await db.prepare(`SELECT * FROM accounts WHERE id = ?`).bind(cal.account_id).first<AccountRow>() : null;
  if (!account) throw new Error("That calendar's account is gone");
  // Nothing to do until the account is reconnected — not an error worth showing.
  if (account.sync_status === "disconnected" || !account.refresh_token || !hasCalendarScope(account.scopes)) return { changed: 0 };

  await db.prepare(`UPDATE calendars SET sync_status = 'syncing', updated_at = ? WHERE id = ?`).bind(now(), cal.id).run();
  try {
    const r = await syncGoogleCalendar(env, cal, account);
    const t = now();
    await db.prepare(`UPDATE calendars SET sync_status = 'idle', sync_error = NULL, last_synced_at = ?, updated_at = ? WHERE id = ?`).bind(t, t, cal.id).run();
    return { changed: r.changed + r.deleted };
  } catch (e) {
    const msg = (e as Error).message ?? String(e);
    const t = now();
    await db.prepare(`UPDATE calendars SET sync_status = 'error', sync_error = ?, last_synced_at = ?, updated_at = ? WHERE id = ?`).bind(msg.slice(0, 1000), t, t, cal.id).run();
    await logSync(db, cal.account_id, "error", `Calendar sync failed for "${cal.name}": ${msg}`);
    throw e;
  }
}

export async function deleteCalendar(db: D1Database, id: string): Promise<void> {
  await db.batch([
    db.prepare(`DELETE FROM event_completions WHERE event_id IN (SELECT id FROM events WHERE calendar_id = ?)`).bind(id),
    db.prepare(`DELETE FROM events WHERE calendar_id = ?`).bind(id),
    db.prepare(`DELETE FROM calendars WHERE id = ?`).bind(id),
  ]);
}
