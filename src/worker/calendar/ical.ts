// A self-contained iCalendar (RFC 5545) reader, writer and recurrence expander. No dependencies:
// this runs on the worker, where the only date maths available is ./dates.
//
// Scope on purpose: VEVENT only. VTODO/VJOURNAL/VFREEBUSY are skipped, and VTIMEZONE bodies are
// ignored rather than interpreted — real feeds always carry an IANA name in TZID, and ICU knows
// those far better than a hand-rolled RRULE-of-offsets reader ever would.

import { addDays, dateKey, daysBetween, isValidDate, isValidZone, minutesOfDay, weekStartOf, weekdayOf, zonedTime } from "./dates";

const MAX_EVENTS = 20000;
const MAX_LINES = 400000;

export interface IcsEvent {
  uid: string;
  recurrenceId: string | null; // RECURRENCE-ID as YYYY-MM-DD when present
  sequence: number;
  summary: string;
  description: string;
  location: string;
  url: string;
  allDay: boolean;
  startsAt: number; // epoch ms
  endsAt: number;
  startDate: string | null; // all-day only, YYYY-MM-DD
  endDate: string | null; // all-day only, INCLUSIVE last day (DTEND in ICS is exclusive)
  tzid: string;
  rrule: string | null; // the raw "FREQ=...;..." value
  exdates: string[]; // YYYY-MM-DD
  status: "confirmed" | "tentative" | "cancelled";
  busy: boolean; // false when TRANSP:TRANSPARENT
  organizer: { email: string; name: string } | null;
  attendees: { email: string; name: string; rsvp: string; optional: boolean }[];
  conferenceUrl: string; // from X-GOOGLE-CONFERENCE, or a meet/zoom/teams link found in DESCRIPTION/LOCATION
  reminders: number[]; // minutes before start, from VALARM TRIGGER
  lastModified: number | null;
}

/** The writable subset of {@link IcsEvent} — what buildIcs needs and nothing more. */
export interface IcsEventInput {
  uid?: string;
  summary?: string;
  description?: string;
  location?: string;
  url?: string;
  allDay?: boolean;
  startsAt?: number;
  endsAt?: number;
  startDate?: string | null;
  endDate?: string | null; // inclusive; written out as an exclusive DTEND
  tzid?: string;
  rrule?: string | null;
  organizer?: { email: string; name?: string } | null;
  attendees?: { email: string; name?: string; rsvp?: string; optional?: boolean }[];
  reminders?: number[];
  status?: "confirmed" | "tentative" | "cancelled";
}

// ---------- line plumbing ----------

interface Prop {
  name: string;
  params: Record<string, string>;
  value: string;
}

/**
 * Unfold per RFC 5545 §3.1: a CRLF (or bare LF, which plenty of feeds emit) followed by a space or
 * tab continues the previous line, and the whitespace itself is not content.
 */
function unfold(text: string): string[] {
  const src = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  const out: string[] = [];
  let buf = "";
  let i = 0;
  const n = src.length;
  while (i < n) {
    let j = src.indexOf("\n", i);
    if (j < 0) j = n;
    let end = j;
    if (end > i && src.charCodeAt(end - 1) === 13) end--; // trailing CR
    const chunk = src.slice(i, end);
    if (chunk.length && (chunk[0] === " " || chunk[0] === "\t")) {
      buf += chunk.slice(1);
    } else {
      if (buf) out.push(buf);
      buf = chunk;
    }
    if (out.length > MAX_LINES) break;
    i = j + 1;
  }
  if (buf) out.push(buf);
  return out;
}

/** NAME;PARAM=VAL;PARAM="quoted,val":VALUE — quoted parameter values may hold ':' and ';'. */
function splitLine(line: string): Prop | null {
  let quoted = false;
  let colon = -1;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === '"') quoted = !quoted;
    else if (c === ":" && !quoted) {
      colon = i;
      break;
    }
  }
  if (colon < 0) return null;
  const head = line.slice(0, colon);
  const value = line.slice(colon + 1);

  const segs: string[] = [];
  let buf = "";
  quoted = false;
  for (const c of head) {
    if (c === '"') {
      quoted = !quoted;
      buf += c;
    } else if (c === ";" && !quoted) {
      segs.push(buf);
      buf = "";
    } else buf += c;
  }
  segs.push(buf);

  let name = (segs.shift() ?? "").trim().toUpperCase();
  const dot = name.lastIndexOf("."); // strip an RFC 5545 property group ("cal.SUMMARY")
  if (dot >= 0) name = name.slice(dot + 1);
  if (!name) return null;

  const params: Record<string, string> = {};
  for (const seg of segs) {
    const eq = seg.indexOf("=");
    if (eq < 0) {
      const bare = seg.trim();
      if (bare) params[bare.toUpperCase()] = "";
      continue;
    }
    const k = seg.slice(0, eq).trim().toUpperCase();
    let v = seg.slice(eq + 1).trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) v = v.slice(1, -1);
    if (k) params[k] = v;
  }
  return { name, params, value };
}

/** TEXT unescaping: \n \N → newline, \, \; \\ → the literal character. */
function unesc(s: string): string {
  if (s.indexOf("\\") < 0) return s;
  let out = "";
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c !== "\\") {
      out += c;
      continue;
    }
    const next = s[++i];
    if (next === undefined) out += "\\";
    else if (next === "n" || next === "N") out += "\n";
    else out += next;
  }
  return out;
}

/** The inverse of {@link unesc}; backslashes first or we'd escape our own escapes. */
function esc(s: string): string {
  return s
    .replace(/\r\n?/g, "\n")
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\n/g, "\\n");
}

/** ISO 8601 duration → ms. Handles P1DT2H30M, PT15M, P2W and a leading sign. */
function parseDuration(raw: string): number | null {
  const m = /^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec(raw.trim().toUpperCase());
  if (!m) return null;
  const [, sign, w, d, h, mi, s] = m;
  if (!w && !d && !h && !mi && !s) return 0;
  const ms = (+(w ?? 0) * 604800 + +(d ?? 0) * 86400 + +(h ?? 0) * 3600 + +(mi ?? 0) * 60 + +(s ?? 0)) * 1000;
  return sign === "-" ? -ms : ms;
}

interface DtValue {
  ms: number;
  date: string; // YYYY-MM-DD in `zone`
  allDay: boolean;
  zone: string;
}

/**
 * A DATE or DATE-TIME property value.
 *   20260115                  → all-day
 *   20260115T090000Z          → UTC
 *   TZID=America/New_York:... → a wall time in that zone, resolved through zonedTime
 *   20260115T090000           → floating. Treated as UTC: the worker has no user zone at parse time
 *                               and guessing one would silently move events between accounts.
 * An unrecognised TZID (a Windows name, a VTIMEZONE-local id) also falls back to UTC.
 */
function parseDt(raw: string, params: Record<string, string>): DtValue | null {
  const value = raw.trim();
  const dateOnly = /^(\d{4})(\d{2})(\d{2})$/.exec(value);
  if (dateOnly || (params["VALUE"] ?? "").toUpperCase() === "DATE") {
    const m = dateOnly ?? /^(\d{4})(\d{2})(\d{2})/.exec(value);
    if (!m) return null;
    const date = `${m[1]}-${m[2]}-${m[3]}`;
    if (!isValidDate(date)) return null;
    // All-day instants are anchored to UTC midnight so the date survives any viewer's zone.
    return { ms: zonedTime(date, 0, "UTC"), date, allDay: true, zone: "UTC" };
  }
  const dt = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z)?$/.exec(value);
  if (!dt) return null;
  const date = `${dt[1]}-${dt[2]}-${dt[3]}`;
  if (!isValidDate(date)) return null;
  const tzid = (params["TZID"] ?? "").trim().replace(/^\//, "");
  const zone = dt[7] ? "UTC" : tzid && isValidZone(tzid) ? tzid : "UTC";
  const minutes = +dt[4] * 60 + +dt[5];
  const ms = zonedTime(date, minutes, zone) + +dt[6] * 1000;
  if (!Number.isFinite(ms)) return null;
  return { ms, date, allDay: false, zone };
}

const CONF_RE =
  /https?:\/\/(?:[\w-]+\.)*(?:meet\.google\.com|zoom\.us|teams\.microsoft\.com|teams\.live\.com|webex\.com|meet\.jit\.si|whereby\.com|chime\.aws)\/[^\s<>"']+/i;

const PARTSTAT: Record<string, string> = {
  "NEEDS-ACTION": "needs-action",
  ACCEPTED: "accepted",
  DECLINED: "declined",
  TENTATIVE: "tentative",
  DELEGATED: "delegated",
};

function mailboxOf(value: string): string {
  return value.trim().replace(/^mailto:/i, "").replace(/^<|>$/g, "").trim().toLowerCase();
}

// ---------- parse ----------

export function parseIcs(text: string): { name: string; timezone: string; color: string; events: IcsEvent[] } {
  const out = { name: "", timezone: "", color: "", events: [] as IcsEvent[] };
  if (!text || typeof text !== "string") return out;

  let props: Prop[] | null = null; // the VEVENT being collected
  let alarms: Prop[][] = [];
  let alarm: Prop[] | null = null;
  let skip = 0; // depth inside a component we do not care about

  for (const line of unfold(text)) {
    const p = splitLine(line);
    if (!p) continue;

    if (p.name === "BEGIN") {
      const comp = p.value.trim().toUpperCase();
      if (skip > 0) {
        skip++;
      } else if (comp === "VEVENT" && !props) {
        props = [];
        alarms = [];
        alarm = null;
      } else if (props && comp === "VALARM" && !alarm) {
        alarm = [];
      } else if (comp === "VTODO" || comp === "VJOURNAL" || comp === "VFREEBUSY" || comp === "VTIMEZONE") {
        skip = 1;
      }
      continue;
    }

    if (p.name === "END") {
      const comp = p.value.trim().toUpperCase();
      if (skip > 0) {
        skip--;
      } else if (props && comp === "VALARM" && alarm) {
        alarms.push(alarm);
        alarm = null;
      } else if (props && comp === "VEVENT") {
        if (out.events.length < MAX_EVENTS) {
          const ev = toEvent(props, alarms);
          if (ev) out.events.push(ev);
        }
        props = null;
        alarms = [];
        alarm = null;
      }
      continue;
    }

    if (skip > 0) continue;
    if (alarm) {
      alarm.push(p);
      continue;
    }
    if (props) {
      props.push(p);
      continue;
    }
    if (p.name === "X-WR-CALNAME") out.name = unesc(p.value).trim();
    else if (p.name === "X-WR-TIMEZONE") out.timezone = p.value.trim();
    else if (p.name === "X-APPLE-CALENDAR-COLOR") out.color = p.value.trim();
  }

  return out;
}

/** One VEVENT → IcsEvent. Returns null for anything malformed; never throws. */
function toEvent(props: Prop[], alarms: Prop[][]): IcsEvent | null {
  try {
    const first = (name: string): Prop | undefined => props.find((p) => p.name === name);
    const textOf = (name: string): string => {
      const p = first(name);
      return p ? unesc(p.value).trim() : "";
    };

    const dtstartProp = first("DTSTART");
    if (!dtstartProp) return null;
    const start = parseDt(dtstartProp.value, dtstartProp.params);
    if (!start) return null;

    const allDay = start.allDay;
    const tzid = start.zone;

    // DTEND, or DURATION, or a sane default (1 hour timed / 1 day all-day).
    let endMs: number;
    let endExclusiveDate: string;
    const dtendProp = first("DTEND");
    const durProp = first("DURATION");
    if (dtendProp) {
      const end = parseDt(dtendProp.value, dtendProp.params);
      if (end) {
        endMs = end.ms;
        endExclusiveDate = end.date;
      } else {
        endMs = allDay ? zonedTime(addDays(start.date, 1), 0, "UTC") : start.ms + 3600000;
        endExclusiveDate = addDays(start.date, 1);
      }
    } else if (durProp && parseDuration(durProp.value) !== null) {
      const ms = parseDuration(durProp.value) as number;
      endMs = start.ms + Math.max(0, ms);
      endExclusiveDate = allDay ? addDays(start.date, Math.max(1, Math.round(ms / 86400000))) : dateKey(endMs, tzid);
    } else {
      endMs = allDay ? zonedTime(addDays(start.date, 1), 0, "UTC") : start.ms + 3600000;
      endExclusiveDate = addDays(start.date, 1);
    }
    if (!Number.isFinite(endMs) || endMs < start.ms) {
      endMs = allDay ? zonedTime(addDays(start.date, 1), 0, "UTC") : start.ms + 3600000;
      endExclusiveDate = addDays(start.date, 1);
    }

    // An all-day DTEND is exclusive: 15th→17th is the 15th and 16th, so the inclusive last day is
    // the day before. Guard against a same-day DTEND, which some writers emit.
    let endDate: string | null = null;
    if (allDay) {
      const inclusive = addDays(endExclusiveDate, -1);
      endDate = daysBetween(start.date, inclusive) < 0 ? start.date : inclusive;
    }

    const status = ((): IcsEvent["status"] => {
      const s = textOf("STATUS").toUpperCase();
      if (s === "TENTATIVE") return "tentative";
      if (s === "CANCELLED") return "cancelled";
      return "confirmed";
    })();

    const recProp = first("RECURRENCE-ID");
    let recurrenceId: string | null = null;
    if (recProp) {
      const rec = parseDt(recProp.value, recProp.params);
      if (rec) recurrenceId = rec.allDay ? rec.date : dateKey(rec.ms, rec.zone);
    }

    const exdates: string[] = [];
    for (const p of props) {
      if (p.name !== "EXDATE") continue;
      for (const piece of p.value.split(",")) {
        const dv = parseDt(piece, p.params);
        if (!dv) continue;
        const key = dv.allDay ? dv.date : dateKey(dv.ms, dv.zone);
        if (key && !exdates.includes(key)) exdates.push(key);
      }
    }

    const orgProp = first("ORGANIZER");
    const orgEmail = orgProp ? mailboxOf(orgProp.value) : "";
    const organizer = orgEmail ? { email: orgEmail, name: unesc(orgProp?.params["CN"] ?? "").trim() } : null;

    const attendees: IcsEvent["attendees"] = [];
    for (const p of props) {
      if (p.name !== "ATTENDEE") continue;
      const email = mailboxOf(p.value);
      if (!email || attendees.some((a) => a.email === email)) continue;
      attendees.push({
        email,
        name: unesc(p.params["CN"] ?? "").trim(),
        rsvp: PARTSTAT[(p.params["PARTSTAT"] ?? "").toUpperCase()] ?? "needs-action",
        optional: (p.params["ROLE"] ?? "").toUpperCase() === "OPT-PARTICIPANT",
      });
    }

    const summary = textOf("SUMMARY");
    const description = textOf("DESCRIPTION");
    const location = textOf("LOCATION");
    const conferenceUrl =
      textOf("X-GOOGLE-CONFERENCE") ||
      CONF_RE.exec(description)?.[0] ||
      CONF_RE.exec(location)?.[0] ||
      (/^https?:\/\//i.test(location) && CONF_RE.test(location) ? location : "") ||
      "";

    const reminders: number[] = [];
    for (const a of alarms) {
      const trig = a.find((p) => p.name === "TRIGGER");
      if (!trig) continue;
      let minutes: number | null = null;
      const dur = parseDuration(trig.value);
      if (dur !== null && (trig.params["VALUE"] ?? "").toUpperCase() !== "DATE-TIME") {
        minutes = Math.round(-dur / 60000); // TRIGGER:-PT15M is 15 minutes *before*
      } else {
        const at = parseDt(trig.value, trig.params);
        if (at) minutes = Math.round((start.ms - at.ms) / 60000);
      }
      if (minutes === null || !Number.isFinite(minutes)) continue;
      if (minutes < -1440 || minutes > 40320) continue; // ignore nonsense (> 4 weeks out)
      if (!reminders.includes(minutes)) reminders.push(minutes);
    }
    reminders.sort((a, b) => a - b);

    const lastModProp = first("LAST-MODIFIED") ?? first("DTSTAMP");
    const lastMod = lastModProp ? parseDt(lastModProp.value, lastModProp.params) : null;

    const seq = parseInt(textOf("SEQUENCE"), 10);
    const rruleProp = first("RRULE");
    const rrule = rruleProp && rruleProp.value.trim() ? rruleProp.value.trim() : null;

    return {
      uid: textOf("UID") || `${start.ms}-${summary}`.slice(0, 200),
      recurrenceId,
      sequence: Number.isFinite(seq) ? seq : 0,
      summary,
      description,
      location,
      url: textOf("URL"),
      allDay,
      startsAt: start.ms,
      endsAt: endMs,
      startDate: allDay ? start.date : null,
      endDate,
      tzid,
      rrule,
      exdates,
      status,
      busy: textOf("TRANSP").toUpperCase() !== "TRANSPARENT",
      organizer,
      attendees,
      conferenceUrl,
      reminders,
      lastModified: lastMod ? lastMod.ms : null,
    };
  } catch {
    return null; // a single bad VEVENT must never take down a whole feed
  }
}

// ---------- recurrence ----------

const WEEKDAYS: Record<string, number> = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };
const MAX_PERIODS = 200000;
const MAX_STEPS = 400000;

interface Rule {
  freq: "DAILY" | "WEEKLY" | "MONTHLY" | "YEARLY";
  interval: number;
  count: number; // 0 = unbounded
  until: number; // Infinity = unbounded
  byDay: { nth: number; wd: number }[];
  byMonthDay: number[];
  byMonth: number[];
  bySetPos: number[];
  wkst: number;
}

function parseRule(raw: string, zone: string): Rule | null {
  const body = raw.trim().replace(/^RRULE:/i, "");
  if (!body) return null;
  const parts: Record<string, string> = {};
  for (const piece of body.split(";")) {
    const eq = piece.indexOf("=");
    if (eq < 0) continue;
    parts[piece.slice(0, eq).trim().toUpperCase()] = piece.slice(eq + 1).trim();
  }
  const freq = (parts["FREQ"] ?? "").toUpperCase();
  if (freq !== "DAILY" && freq !== "WEEKLY" && freq !== "MONTHLY" && freq !== "YEARLY") return null;

  const ints = (key: string, lo: number, hi: number): number[] => {
    const v = parts[key];
    if (!v) return [];
    const out: number[] = [];
    for (const piece of v.split(",")) {
      const n = parseInt(piece, 10);
      if (Number.isFinite(n) && n !== 0 && Math.abs(n) >= lo && Math.abs(n) <= hi && !out.includes(n)) out.push(n);
    }
    return out;
  };

  const byDay: Rule["byDay"] = [];
  for (const piece of (parts["BYDAY"] ?? "").split(",")) {
    const m = /^([+-]?\d{1,2})?(SU|MO|TU|WE|TH|FR|SA)$/.exec(piece.trim().toUpperCase());
    if (!m) continue;
    const nth = m[1] ? parseInt(m[1], 10) : 0;
    byDay.push({ nth, wd: WEEKDAYS[m[2]] });
  }

  let until = Infinity;
  if (parts["UNTIL"]) {
    const dv = parseDt(parts["UNTIL"], {});
    // A date-only UNTIL is inclusive of the whole day.
    if (dv) until = dv.allDay ? zonedTime(dv.date, 0, zone) + 86400000 - 1 : dv.ms;
  }

  const count = Math.max(0, parseInt(parts["COUNT"] ?? "0", 10) || 0);
  const interval = Math.max(1, Math.min(parseInt(parts["INTERVAL"] ?? "1", 10) || 1, 1000));
  const wkst = WEEKDAYS[(parts["WKST"] ?? "MO").toUpperCase()] ?? 1;

  return {
    freq,
    interval,
    count,
    until,
    byDay,
    byMonthDay: ints("BYMONTHDAY", 1, 31),
    byMonth: ints("BYMONTH", 1, 12),
    bySetPos: ints("BYSETPOS", 1, 366),
    wkst,
  };
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}

function dstr(y: number, m: number, d: number): string {
  return `${String(y).padStart(4, "0")}-${pad2(m)}-${pad2(d)}`;
}

function partsOfDate(date: string): [number, number, number] {
  return [+date.slice(0, 4), +date.slice(5, 7), +date.slice(8, 10)];
}

function daysInMonth(y: number, m: number): number {
  return new Date(Date.UTC(y, m, 0)).getUTCDate();
}

/** All dates in [y-m-1 .. end of month] whose weekday is `wd`, honouring an ordinal (2TU, -1FR). */
function weekdaysInMonth(y: number, m: number, wd: number, nth: number): string[] {
  const len = daysInMonth(y, m);
  const firstWd = weekdayOf(dstr(y, m, 1));
  const firstMatch = 1 + ((wd - firstWd + 7) % 7);
  const all: string[] = [];
  for (let d = firstMatch; d <= len; d += 7) all.push(dstr(y, m, d));
  if (!nth) return all;
  const idx = nth > 0 ? nth - 1 : all.length + nth;
  return idx >= 0 && idx < all.length ? [all[idx]] : [];
}

/** The same, scoped to a whole year — YEARLY;BYDAY=20MO and friends. */
function weekdaysInYear(y: number, wd: number, nth: number): string[] {
  const all: string[] = [];
  for (let m = 1; m <= 12; m++) all.push(...weekdaysInMonth(y, m, wd, 0));
  if (!nth) return all;
  const idx = nth > 0 ? nth - 1 : all.length + nth;
  return idx >= 0 && idx < all.length ? [all[idx]] : [];
}

/** BYMONTHDAY entries resolved against a month's real length; negatives count from the end. */
function monthDays(y: number, m: number, list: number[]): string[] {
  const len = daysInMonth(y, m);
  const out: string[] = [];
  for (const n of list) {
    const d = n > 0 ? n : len + n + 1;
    if (d >= 1 && d <= len) out.push(dstr(y, m, d));
  }
  return out;
}

/** Every candidate date a MONTHLY-style month contributes, before BYSETPOS. */
function monthCandidates(r: Rule, y: number, m: number, seedDay: number): string[] {
  if (r.byMonth.length && !r.byMonth.includes(m)) return [];
  let days: string[];
  if (r.byMonthDay.length) {
    days = monthDays(y, m, r.byMonthDay);
    if (r.byDay.length) {
      const wds = new Set(r.byDay.map((b) => b.wd));
      days = days.filter((d) => wds.has(weekdayOf(d)));
    }
  } else if (r.byDay.length) {
    days = [];
    for (const b of r.byDay) days.push(...weekdaysInMonth(y, m, b.wd, b.nth));
  } else {
    days = seedDay <= daysInMonth(y, m) ? [dstr(y, m, seedDay)] : [];
  }
  return days;
}

function sortUnique(list: string[]): string[] {
  return [...new Set(list)].sort();
}

function applySetPos(list: string[], positions: number[]): string[] {
  if (!positions.length) return list;
  const out: string[] = [];
  for (const p of positions) {
    const idx = p > 0 ? p - 1 : list.length + p;
    if (idx >= 0 && idx < list.length) out.push(list[idx]);
  }
  return sortUnique(out);
}

/**
 * Expand an RRULE into occurrence start instants intersecting [from, to].
 *
 * The wall-clock time of the seed is preserved across DST: we generate the occurrence *date* with
 * pure calendar arithmetic and only then re-resolve the seed's local time-of-day on that date, so a
 * 09:00 daily meeting stays at 09:00 the morning the clocks move.
 *
 * All-day rules are anchored in UTC (matching how parseIcs stores all-day instants) so a birthday
 * never drifts a day. An unparseable rule degrades to the single seed occurrence.
 */
export function expandRRule(
  rrule: string,
  startsAt: number,
  opts: { tz: string; allDay: boolean; from: number; to: number; exdates?: string[]; limit?: number },
): number[] {
  const { from, to } = opts;
  const limit = Math.max(1, Math.min(opts.limit ?? 1000, 10000));
  const zone = opts.allDay ? "UTC" : opts.tz && isValidZone(opts.tz) ? opts.tz : "UTC";
  const bare = Number.isFinite(startsAt) && startsAt >= from && startsAt <= to ? [startsAt] : [];
  if (!Number.isFinite(startsAt) || !Number.isFinite(from) || !Number.isFinite(to) || to < from) return bare;

  const r = parseRule(rrule ?? "", zone);
  if (!r) return bare;

  const seedDate = dateKey(startsAt, zone);
  if (!seedDate) return bare;
  const minutes = opts.allDay ? 0 : minutesOfDay(startsAt, zone);
  const [seedY, seedM, seedD] = partsOfDate(seedDate);
  const seedWeek = weekStartOf(seedDate, r.wkst);
  const ex = new Set(opts.exdates ?? []);

  // Without COUNT nothing before the window can matter, so skip whole periods rather than walking
  // them one at a time — a 2015 daily rule asked about 2026 would otherwise cost 4000 iterations.
  let idx = 0;
  if (!r.count && from > startsAt) {
    const fromDate = dateKey(from, zone);
    if (fromDate) {
      const [fy, fm] = partsOfDate(fromDate);
      let skip = 0;
      if (r.freq === "DAILY") skip = Math.floor(daysBetween(seedDate, fromDate) / r.interval);
      else if (r.freq === "WEEKLY") skip = Math.floor(daysBetween(seedWeek, weekStartOf(fromDate, r.wkst)) / (7 * r.interval));
      else if (r.freq === "MONTHLY") skip = Math.floor(((fy - seedY) * 12 + (fm - seedM)) / r.interval);
      else skip = Math.floor((fy - seedY) / r.interval);
      idx = Math.max(0, skip - 1); // one period of slack; cheaper than reasoning about edges
    }
  }

  // Dates a whole day clear of the window (and of UNTIL) still consume a COUNT slot but never need
  // their exact instant — and resolving an instant is where all the Intl cost lives. A day of slack
  // keeps the shortcut safe in the zones that shift at midnight.
  const fromDate = dateKey(from, zone);
  const cheapBefore = fromDate ? addDays(fromDate, -1) : "";
  const untilDate = Number.isFinite(r.until) ? dateKey(r.until, zone) : "";
  const cheapUntil = untilDate ? addDays(untilDate, -1) : "";

  const results: number[] = [];
  let counted = 0;
  let steps = 0;
  let done = false;

  for (; idx < MAX_PERIODS && !done; idx++) {
    if (++steps > MAX_STEPS) break;

    // The dates this period contributes, before BYSETPOS.
    let list: string[];
    if (r.freq === "DAILY") {
      const d = addDays(seedDate, idx * r.interval);
      const [y, m] = partsOfDate(d);
      const okMonth = !r.byMonth.length || r.byMonth.includes(m);
      const okDay = !r.byDay.length || r.byDay.some((b) => b.wd === weekdayOf(d));
      const okMd = !r.byMonthDay.length || monthDays(y, m, r.byMonthDay).includes(d);
      list = okMonth && okDay && okMd ? [d] : [];
    } else if (r.freq === "WEEKLY") {
      const anchor = addDays(seedWeek, idx * r.interval * 7);
      const wds = r.byDay.length ? r.byDay.map((b) => b.wd) : [weekdayOf(seedDate)];
      list = [];
      for (let i = 0; i < 7; i++) {
        const d = addDays(anchor, i);
        if (!wds.includes(weekdayOf(d))) continue;
        const [y, m] = partsOfDate(d);
        if (r.byMonth.length && !r.byMonth.includes(m)) continue;
        if (r.byMonthDay.length && !monthDays(y, m, r.byMonthDay).includes(d)) continue;
        list.push(d);
      }
    } else if (r.freq === "MONTHLY") {
      const total = (seedY * 12 + (seedM - 1)) + idx * r.interval;
      list = monthCandidates(r, Math.floor(total / 12), (total % 12) + 1, seedD);
    } else {
      const y = seedY + idx * r.interval;
      if (!r.byMonth.length && r.byDay.length) {
        // YEARLY;BYDAY without BYMONTH is scoped to the whole year (RFC 5545 §3.3.10).
        list = [];
        for (const b of r.byDay) list.push(...weekdaysInYear(y, b.wd, b.nth));
        if (r.byMonthDay.length) {
          list = list.filter((d) => {
            const [dy, dm] = partsOfDate(d);
            return monthDays(dy, dm, r.byMonthDay).includes(d);
          });
        }
      } else {
        const months = r.byMonth.length ? r.byMonth : [seedM];
        list = [];
        for (const m of months) list.push(...monthCandidates(r, y, m, seedD));
      }
    }

    list = applySetPos(sortUnique(list), r.bySetPos);
    // RFC 5545: DTSTART is always the first instance, even when the rule alone wouldn't emit it.
    if (idx === 0 && !list.includes(seedDate)) list = sortUnique([seedDate, ...list]);

    for (const d of list) {
      if (d < seedDate) continue;
      if (d < cheapBefore && (!cheapUntil || d < cheapUntil)) {
        counted++;
        if (r.count && counted >= r.count) {
          done = true;
          break;
        }
        continue;
      }
      const t = opts.allDay ? zonedTime(d, 0, "UTC") : zonedTime(d, minutes, zone);
      if (!Number.isFinite(t) || t < startsAt) continue;
      if (t > r.until) {
        done = true;
        break;
      }
      counted++;
      if (r.count && counted > r.count) {
        done = true;
        break;
      }
      if (t > to) {
        done = true;
        break;
      }
      if (t >= from && !ex.has(d)) results.push(t);
      if (results.length >= limit) {
        done = true;
        break;
      }
    }
    if (r.count && counted >= r.count) done = true;
  }

  results.sort((a, b) => a - b);
  return results;
}

// ---------- write ----------

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** RFC 5545 §3.1 content line folding: 75 octets, continuations prefixed with a space. */
function fold(line: string): string {
  const bytes = encoder.encode(line);
  if (bytes.length <= 75) return line;
  const chunks: string[] = [];
  let start = 0;
  let limit = 75;
  while (start < bytes.length) {
    let end = Math.min(start + limit, bytes.length);
    // never cut a UTF-8 sequence in half
    if (end < bytes.length) while (end > start + 1 && (bytes[end] & 0xc0) === 0x80) end--;
    chunks.push(decoder.decode(bytes.subarray(start, end)));
    start = end;
    limit = 74; // continuation lines spend an octet on the leading space
  }
  return chunks.join("\r\n ");
}

function utcStamp(ms: number): string {
  const d = new Date(ms);
  return (
    `${String(d.getUTCFullYear()).padStart(4, "0")}${pad2(d.getUTCMonth() + 1)}${pad2(d.getUTCDate())}` +
    `T${pad2(d.getUTCHours())}${pad2(d.getUTCMinutes())}${pad2(d.getUTCSeconds())}Z`
  );
}

function dateStamp(date: string): string {
  return date.replace(/-/g, "");
}

/**
 * Serialise events as a VCALENDAR. Timed values are written in UTC rather than TZID form: a TZID
 * reference is only legal alongside a matching VTIMEZONE body, and emitting a correct one would
 * mean shipping the whole tzdata. UTC is unambiguous and every client accepts it.
 */
export function buildIcs(
  events: IcsEventInput[],
  opts?: { name?: string; method?: "PUBLISH" | "REQUEST" | "CANCEL"; prodId?: string },
): string {
  const lines: string[] = [];
  const push = (s: string) => lines.push(fold(s));

  push("BEGIN:VCALENDAR");
  push("VERSION:2.0");
  push(`PRODID:${opts?.prodId ?? "-//heyflare//Calendar//EN"}`);
  push("CALSCALE:GREGORIAN");
  if (opts?.method) push(`METHOD:${opts.method}`);
  if (opts?.name) push(`X-WR-CALNAME:${esc(opts.name)}`);

  const stamp = utcStamp(Date.now());
  for (const ev of events ?? []) {
    const allDay = !!ev.allDay;
    const startDate = ev.startDate && isValidDate(ev.startDate) ? ev.startDate : dateKey(ev.startsAt ?? Date.now(), "UTC");
    if (allDay && !isValidDate(startDate)) continue;
    if (!allDay && !Number.isFinite(ev.startsAt)) continue;

    push("BEGIN:VEVENT");
    push(`UID:${(ev.uid ?? `${stamp}-${lines.length}@heyflare`).replace(/[\r\n]/g, "")}`);
    push(`DTSTAMP:${stamp}`);

    if (allDay) {
      const endInclusive = ev.endDate && isValidDate(ev.endDate) ? ev.endDate : startDate;
      const exclusive = addDays(daysBetween(startDate, endInclusive) < 0 ? startDate : endInclusive, 1);
      push(`DTSTART;VALUE=DATE:${dateStamp(startDate)}`);
      push(`DTEND;VALUE=DATE:${dateStamp(exclusive)}`); // DTEND is exclusive: the day after the last
    } else {
      const s = ev.startsAt as number;
      const e = Number.isFinite(ev.endsAt) && (ev.endsAt as number) > s ? (ev.endsAt as number) : s + 3600000;
      push(`DTSTART:${utcStamp(s)}`);
      push(`DTEND:${utcStamp(e)}`);
    }

    if (ev.summary) push(`SUMMARY:${esc(ev.summary)}`);
    if (ev.description) push(`DESCRIPTION:${esc(ev.description)}`);
    if (ev.location) push(`LOCATION:${esc(ev.location)}`);
    if (ev.url) push(`URL:${esc(ev.url)}`);
    if (ev.rrule) push(`RRULE:${ev.rrule.trim().replace(/^RRULE:/i, "").replace(/[\r\n]/g, "")}`);
    if (ev.tzid && isValidZone(ev.tzid)) push(`X-WR-TIMEZONE:${ev.tzid}`);
    push(`STATUS:${(ev.status ?? "confirmed").toUpperCase()}`);
    push("SEQUENCE:0");

    if (ev.organizer?.email) {
      const cn = ev.organizer.name ? `;CN="${ev.organizer.name.replace(/"/g, "")}"` : "";
      push(`ORGANIZER${cn}:mailto:${ev.organizer.email}`);
    }
    for (const a of ev.attendees ?? []) {
      if (!a?.email) continue;
      const cn = a.name ? `;CN="${a.name.replace(/"/g, "")}"` : "";
      const role = a.optional ? "OPT-PARTICIPANT" : "REQ-PARTICIPANT";
      const partstat = (a.rsvp ?? "needs-action").toUpperCase();
      push(`ATTENDEE${cn};ROLE=${role};PARTSTAT=${partstat};RSVP=TRUE:mailto:${a.email}`);
    }
    for (const m of ev.reminders ?? []) {
      if (!Number.isFinite(m)) continue;
      const mins = Math.round(m);
      push("BEGIN:VALARM");
      push("ACTION:DISPLAY");
      push(`DESCRIPTION:${esc(ev.summary || "Reminder")}`);
      push(`TRIGGER:${mins >= 0 ? `-PT${mins}M` : `PT${-mins}M`}`);
      push("END:VALARM");
    }
    push("END:VEVENT");
  }

  push("END:VCALENDAR");
  return `${lines.join("\r\n")}\r\n`;
}
