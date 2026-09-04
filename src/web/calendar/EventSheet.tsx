import { useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import {
  Bell,
  CalendarDays,
  Check,
  Download,
  Link2,
  Lock,
  Mail,
  MapPin,
  Plus,
  Repeat,
  Smile,
  Trash2,
  Video,
  X,
  CopyPlus,
} from "lucide-react";
import type { CalEvent, Calendar, EventAttendee, Reminder, Rsvp } from "@shared/types";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Calendar as CalendarGrid } from "@/components/ui/calendar";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet";
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { eventIcsUrl, useEventMutations, type EventInput, type EventScope } from "../api";
import { useAccount } from "../context/AccountContext";
import { AddressInput } from "../components/AddressInput";
import { addDays, dateKey, daysBetween, fmtTime, keyToDate, longDayLabel, minutesOfDay, msAt, todayKey, weekdayLabel } from "../lib/caldate";
import { openExternalUrl } from "../lib/native";
import { useCalendar, type EditorTarget } from "./CalendarContext";

/* ------------------------------------------------------------------ time */

const STEP = 15;
const DAY_MIN = 24 * 60;
/** Every 15-minute slot of a day, as minutes past local midnight. */
const SLOTS: number[] = Array.from({ length: DAY_MIN / STEP }, (_, i) => i * STEP);

/* ---------------------------------------------------------------- repeat */

type RepeatKind = "never" | "daily" | "weekdays" | "weekly" | "biweekly" | "monthly" | "yearly" | "custom";
type RepeatEnd = "never" | "until" | "count";

const REPEAT_KINDS: Exclude<RepeatKind, "never" | "custom">[] = ["daily", "weekdays", "weekly", "biweekly", "monthly", "yearly"];
const BYDAY = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];

function ordinal(n: number): string {
  const rest = n % 100;
  if (rest >= 11 && rest <= 13) return `${n}th`;
  return `${n}${["th", "st", "nd", "rd"][n % 10] ?? "th"}`;
}

/** The rule body for one of the cases HEY offers, anchored on the event's start day. */
function baseRule(kind: Exclude<RepeatKind, "never" | "custom">, startKey: string): string {
  const d = keyToDate(startKey);
  switch (kind) {
    case "daily":
      return "FREQ=DAILY";
    case "weekdays":
      return "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR";
    case "weekly":
      return `FREQ=WEEKLY;BYDAY=${BYDAY[d.getDay()]}`;
    case "biweekly":
      return `FREQ=WEEKLY;INTERVAL=2;BYDAY=${BYDAY[d.getDay()]}`;
    case "monthly":
      return `FREQ=MONTHLY;BYMONTHDAY=${d.getDate()}`;
    default:
      return "FREQ=YEARLY";
  }
}

function repeatLabel(kind: RepeatKind, startKey: string): string {
  switch (kind) {
    case "never":
      return "Does not repeat";
    case "daily":
      return "Every day";
    case "weekdays":
      return "Every weekday";
    case "weekly":
      return `Weekly on ${weekdayLabel(startKey)}`;
    case "biweekly":
      return "Every two weeks";
    case "monthly":
      return `Monthly on the ${ordinal(keyToDate(startKey).getDate())}`;
    case "yearly":
      return "Every year";
    default:
      return "Custom…";
  }
}

/** `FREQ=DAILY;COUNT=5` → `{ FREQ: "DAILY", COUNT: "5" }`, upper-cased, `RRULE:` prefix tolerated. */
function ruleParts(rrule: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const part of rrule.replace(/^RRULE:/i, "").split(";")) {
    const i = part.indexOf("=");
    if (i < 0) continue;
    out.set(part.slice(0, i).trim().toUpperCase(), part.slice(i + 1).trim().toUpperCase());
  }
  return out;
}

/** The rule without its ending clause — the ending lives in its own controls. */
function stripEnd(rrule: string): string {
  return rrule
    .replace(/^RRULE:/i, "")
    .split(";")
    .filter((p) => p.trim() && !/^(UNTIL|COUNT)\s*=/i.test(p))
    .join(";");
}

/**
 * A comparable form of a rule body, so two rules that mean the same thing compare equal:
 * parts sorted, `INTERVAL=1` (the default) dropped, `BYDAY` order ignored, `WKST` ignored.
 * Without this, `FREQ=WEEKLY;BYDAY=MO;WKST=SU` from Google would never match our `FREQ=WEEKLY;BYDAY=MO`
 * and every synced weekly event would show as "Custom".
 */
function canon(rrule: string): string {
  const m = ruleParts(stripEnd(rrule));
  m.delete("WKST");
  if (m.get("INTERVAL") === "1") m.delete("INTERVAL");
  const byday = m.get("BYDAY");
  if (byday) m.set("BYDAY", byday.split(",").map((s) => s.trim()).sort().join(","));
  return [...m.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]) => `${k}=${v}`)
    .join(";");
}

/**
 * `UNTIL` is an instant, not a date: RFC 5545 writes it in UTC. Reading it back through the
 * local clock is what makes "ends on the 5th" still say the 5th after a round trip, because
 * that is exactly how `untilStamp` wrote it.
 */
function untilKey(raw: string): string {
  const m = raw.match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/);
  if (!m) return todayKey();
  if (m[7]) return dateKey(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]));
  return `${m[1]}-${m[2]}-${m[3]}`;
}

/** The last minute of `key` in local time, as a UTC stamp: `20260905T225900Z`. */
function untilStamp(key: string): string {
  return `${new Date(msAt(key, DAY_MIN - 1)).toISOString().replace(/[-:]/g, "").slice(0, 15)}Z`;
}

interface RepeatState {
  repeat: RepeatKind;
  /** Only meaningful for `custom`: the rule body the user typed, ending clause removed. */
  rruleText: string;
  repeatEnd: RepeatEnd;
  until: string;
  count: number;
}

/**
 * Recognise a stored RRULE as one of the offered cases so the select shows a real label.
 * Anything we don't know falls through to "custom" with the rule intact — nothing is ever
 * silently rewritten, which matters because the round trip has to survive an edit that
 * never touches the repeat field.
 */
function parseRepeat(rrule: string | null | undefined, startKey: string): RepeatState {
  const blank: RepeatState = { repeat: "never", rruleText: "", repeatEnd: "never", until: startKey, count: 10 };
  if (!rrule || !rrule.trim()) return blank;
  const parts = ruleParts(rrule);
  const untilRaw = parts.get("UNTIL");
  const countRaw = parts.get("COUNT");
  const ending: Pick<RepeatState, "repeatEnd" | "until" | "count"> = {
    repeatEnd: untilRaw ? "until" : countRaw ? "count" : "never",
    until: untilRaw ? untilKey(untilRaw) : startKey,
    count: countRaw ? Math.max(1, Number(countRaw) || 1) : 10,
  };
  const body = canon(rrule);
  for (const kind of REPEAT_KINDS) {
    if (canon(baseRule(kind, startKey)) === body) return { repeat: kind, rruleText: "", ...ending };
  }
  return { repeat: "custom", rruleText: stripEnd(rrule), ...ending };
}

/* -------------------------------------------------------------- reminders */

const UNITS = { minutes: 1, hours: 60, days: 1440 } as const;
type Unit = keyof typeof UNITS;

/** 120 → "2 hours"; 45 → "45 minutes". The biggest unit that divides evenly wins. */
function splitReminder(minutes: number): { n: number; unit: Unit } {
  if (minutes > 0 && minutes % UNITS.days === 0) return { n: minutes / UNITS.days, unit: "days" };
  if (minutes > 0 && minutes % UNITS.hours === 0) return { n: minutes / UNITS.hours, unit: "hours" };
  return { n: minutes, unit: "minutes" };
}

/* ------------------------------------------------------------------ form */

interface Form {
  calendar_id: string;
  title: string;
  emoji: string;
  all_day: boolean;
  startDate: string;
  /** Minutes past local midnight. Ignored while `all_day`. */
  startMin: number;
  /** While `all_day` this is the *inclusive* last day; otherwise the day the event stops on. */
  endDate: string;
  endMin: number;
  repeat: RepeatKind;
  rruleText: string;
  repeatEnd: RepeatEnd;
  until: string;
  count: number;
  location: string;
  description: string;
  guests: EventAttendee[];
  url: string;
  reminders: Reminder[];
  countdown: boolean;
  circled: boolean;
}

function pickCalendar(calendars: Calendar[]): string {
  const writable = calendars.filter((c) => c.writable);
  return (writable.find((c) => c.is_default) ?? writable[0])?.id ?? "";
}

function makeForm(target: EditorTarget, calendars: Calendar[]): Form {
  const base: Partial<CalEvent> = target.mode === "edit" ? target.event : target.prefill;
  const allDay = !!base.all_day;
  const starts = base.starts_at ?? Date.now();
  const ends = base.ends_at ?? starts + 60 * 60_000;
  // All-day rows carry their own inclusive dates; timed rows only carry instants.
  const startDate = (allDay ? base.start_date : null) ?? dateKey(starts);
  const endDate = allDay ? base.end_date ?? startDate : dateKey(ends);
  const startMin = minutesOfDay(starts);
  return {
    calendar_id: base.calendar_id ?? pickCalendar(calendars),
    title: base.title ?? "",
    emoji: base.emoji ?? "",
    all_day: allDay,
    startDate,
    startMin,
    endDate,
    endMin: allDay ? Math.min(startMin + 60, DAY_MIN - STEP) : minutesOfDay(ends),
    ...parseRepeat(base.rrule, startDate),
    location: base.location ?? "",
    description: base.description ?? "",
    guests: base.attendees ? [...base.attendees] : [],
    url: base.url ?? "",
    reminders: base.reminders ? [...base.reminders] : [],
    countdown: !!base.countdown,
    circled: !!base.circled,
  };
}

function buildRrule(f: Form): string | null {
  if (f.repeat === "never") return null;
  // Custom rules are taken as typed, minus any ending the user wrote — the ending controls own
  // that half, and they were seeded from the same rule, so nothing is lost on the round trip.
  let rule = f.repeat === "custom" ? stripEnd(f.rruleText) : baseRule(f.repeat, f.startDate);
  if (!rule) return null;
  if (f.repeatEnd === "until" && f.until) rule += `;UNTIL=${untilStamp(f.until)}`;
  else if (f.repeatEnd === "count") rule += `;COUNT=${Math.max(1, Math.min(f.count || 1, 999))}`;
  return rule;
}

function toInput(f: Form, timezone: string): EventInput {
  const common: EventInput = {
    calendar_id: f.calendar_id,
    title: f.title.trim(),
    description: f.description,
    location: f.location.trim(),
    emoji: f.emoji,
    rrule: buildRrule(f),
    attendees: f.guests,
    url: f.url.trim(),
    reminders: f.reminders,
    countdown: f.countdown,
    circled: f.circled,
    timezone,
  };
  if (f.all_day) {
    // `end_date` is inclusive, so the instant the day *stops* is midnight of the day after it.
    return { ...common, all_day: true, start_date: f.startDate, end_date: f.endDate, starts_at: msAt(f.startDate, 0), ends_at: msAt(addDays(f.endDate, 1), 0) };
  }
  return { ...common, all_day: false, start_date: null, end_date: null, starts_at: msAt(f.startDate, f.startMin), ends_at: msAt(f.endDate, f.endMin) };
}

/* ------------------------------------------------------------ small parts */

const EMOJI = ["📅", "🎉", "🎂", "✈️", "🍽️", "☕️", "🏃", "💼", "📞", "🎬", "🩺", "🏖️", "💪", "📚", "🎓", "🎵", "🛠️", "❤️", "⭐️", "🔥", "🧘", "🚗", "🏡", "💡"];

function EmojiButton({ value, onChange, disabled }: { value: string; onChange: (v: string) => void; disabled?: boolean }) {
  const [open, setOpen] = useState(false);
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button type="button" variant="ghost" size="icon-sm" disabled={disabled} aria-label="Emoji" className="shrink-0 text-muted-foreground">
          {value ? <span className="text-[15px] leading-none">{value}</span> : <Smile />}
        </Button>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-64 p-1.5">
        <div className="grid grid-cols-8 gap-0.5">
          {EMOJI.map((e) => (
            <button key={e} type="button" className="size-7 rounded-md text-[15px] hover:bg-muted" onClick={() => { onChange(e); setOpen(false); }}>
              {e}
            </button>
          ))}
        </div>
        {value && (
          <Button variant="ghost" size="xs" className="mt-1 w-full text-muted-foreground" onClick={() => { onChange(""); setOpen(false); }}>
            Remove
          </Button>
        )}
      </PopoverContent>
    </Popover>
  );
}

/** The date half of a start/end row — the same calendar the rest of the app picks dates with. */
function DateField({ value, onChange, disabled }: { value: string; onChange: (key: string) => void; disabled?: boolean }) {
  const [open, setOpen] = useState(false);
  const short = keyToDate(value).toLocaleDateString([], { weekday: "short", day: "numeric", month: "short", year: "numeric" });
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button type="button" variant="outline" size="sm" disabled={disabled} title={longDayLabel(value)} className="justify-start font-normal tnum">
          <CalendarDays className="text-muted-foreground" />
          {short}
        </Button>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-auto p-1">
        <CalendarGrid
          mode="single"
          selected={keyToDate(value)}
          defaultMonth={keyToDate(value)}
          onSelect={(d) => {
            if (!d) return;
            onChange(dateKey(d.getTime()));
            setOpen(false);
          }}
          className="p-1"
        />
      </PopoverContent>
    </Popover>
  );
}

/** Plain 15-minute select. An off-grid time (a synced 09:07 meeting) keeps its own slot. */
function TimeField({ day, minutes, onChange, format, disabled }: { day: string; minutes: number; onChange: (m: number) => void; format: "12" | "24"; disabled?: boolean }) {
  const options = useMemo(() => {
    const list = SLOTS.includes(minutes) ? SLOTS : [...SLOTS, minutes].sort((a, b) => a - b);
    return list.map((m) => ({ value: String(m), label: fmtTime(msAt(day, m), format) }));
  }, [day, minutes, format]);
  return (
    <Select value={String(minutes)} onValueChange={(v) => onChange(Number(v))} disabled={disabled}>
      <SelectTrigger size="sm" className="w-28 tnum">
        <SelectValue />
      </SelectTrigger>
      <SelectContent className="max-h-72">
        {options.map((o) => (
          <SelectItem key={o.value} value={o.value} className="tnum">
            {o.label}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}

function Row({ label, icon, children, className }: { label: string; icon?: React.ReactNode; children: React.ReactNode; className?: string }) {
  return (
    <div className={cn("flex items-start gap-3 border-b border-border py-2", className)}>
      <span className="flex w-24 shrink-0 items-center gap-1.5 pt-1.5 text-[13px] text-muted-foreground select-none [&>svg]:size-3.5 [&>svg]:text-tertiary">
        {icon}
        {label}
      </span>
      <div className="min-w-0 flex-1">{children}</div>
    </div>
  );
}

const RSVP_LABEL: Record<string, string> = { accepted: "Yes", declined: "No", tentative: "Maybe", needsAction: "No reply" };

/* ----------------------------------------------------------------- sheet */

type Ask = null | "discard" | "delete" | "delete-scope" | "save-scope";

/**
 * The calendar's one editor. Renders nothing until `openEvent`/`createEvent` puts something in
 * `editor`; the inner form is keyed on the target so switching events starts from clean state.
 */
export function EventSheet() {
  const { editor } = useCalendar();
  if (!editor) return null;
  const key = editor.mode === "edit" ? editor.event.id : `new:${editor.prefill.starts_at}:${editor.prefill.all_day ? 1 : 0}`;
  return <EventForm key={key} target={editor} />;
}

function EventForm({ target }: { target: EditorTarget }) {
  const { closeEditor, calendars, settings, openEvent } = useCalendar();
  const { user, accounts } = useAccount();
  const m = useEventMutations();
  const ev = target.mode === "edit" ? target.event : null;

  const [form, setForm] = useState<Form>(() => makeForm(target, calendars));
  // The form as it was opened. Anything different from this is an unsaved change.
  const [baseline, setBaseline] = useState<string>(() => JSON.stringify(form));
  const [ask, setAsk] = useState<Ask>(null);
  const [error, setError] = useState<string | null>(null);
  const titleRef = useRef<HTMLInputElement>(null);

  // The calendar list can arrive after mount; filling the blank must not make the form dirty.
  useEffect(() => {
    if (form.calendar_id || calendars.length === 0) return;
    const id = pickCalendar(calendars);
    if (!id) return;
    const next = { ...form, calendar_id: id };
    setForm(next);
    setBaseline(JSON.stringify(next));
  }, [calendars, form]);

  useEffect(() => {
    if (target.mode === "create") {
      const t = setTimeout(() => titleRef.current?.focus(), 60);
      return () => clearTimeout(t);
    }
  }, [target.mode]);

  const cal = calendars.find((c) => c.id === form.calendar_id);
  /** An ICS subscription is a mirror of somebody else's calendar: readable, never writable. */
  const readOnly = (ev ? ev.writable === false : false) || cal?.writable === false;
  const busy = m.create.isPending || m.update.isPending || m.remove.isPending;
  const dirty = JSON.stringify(form) !== baseline;
  const set = <K extends keyof Form>(k: K, v: Form[K]) => setForm((f) => ({ ...f, [k]: v }));

  /* --- times ------------------------------------------------------------ */

  /** Moving the start drags the end along, keeping the duration, the way every calendar does. */
  const moveStart = (patch: { date?: string; min?: number }) =>
    setForm((f) => {
      const startDate = patch.date ?? f.startDate;
      if (f.all_day) {
        const span = Math.max(0, daysBetween(f.startDate, f.endDate));
        return { ...f, startDate, endDate: addDays(startDate, span) };
      }
      const startMin = patch.min ?? f.startMin;
      const keep = Math.max(0, msAt(f.endDate, f.endMin) - msAt(f.startDate, f.startMin));
      const end = msAt(startDate, startMin) + keep;
      return { ...f, startDate, startMin, endDate: dateKey(end), endMin: minutesOfDay(end) };
    });

  /** An end before the start is corrected, not rejected: it snaps to the first legal slot. */
  const moveEnd = (patch: { date?: string; min?: number }) =>
    setForm((f) => {
      if (f.all_day) {
        const endDate = patch.date ?? f.endDate;
        return { ...f, endDate: endDate < f.startDate ? f.startDate : endDate };
      }
      const start = msAt(f.startDate, f.startMin);
      let end = msAt(patch.date ?? f.endDate, patch.min ?? f.endMin);
      if (end <= start) end = start + STEP * 60_000;
      return { ...f, endDate: dateKey(end), endMin: minutesOfDay(end) };
    });

  /**
   * All-day and timed are two different shapes, not a flag on one shape, so the toggle converts.
   *
   * Timed → all-day: `end_date` is *inclusive*, so an event that stops at midnight belongs to the
   * day before the instant it ends on — otherwise a 9pm–midnight meeting would grow a second day.
   * All-day → timed: the inclusive end day becomes the day the event stops on, at a sane hour.
   */
  const setAllDay = (on: boolean) =>
    setForm((f) => {
      if (on === f.all_day) return f;
      if (on) {
        let endDate = f.endDate;
        if (f.endMin === 0 && endDate > f.startDate) endDate = addDays(endDate, -1);
        if (endDate < f.startDate) endDate = f.startDate;
        return { ...f, all_day: true, endDate };
      }
      const startMin = f.startMin || 9 * 60;
      return { ...f, all_day: false, startMin, endMin: Math.min(startMin + 60, DAY_MIN - STEP) };
    });

  /* --- guests ----------------------------------------------------------- */

  // AddressInput speaks Address; attendees also carry an RSVP we must not throw away on edit.
  const guestAddresses = useMemo(() => form.guests.map((g) => ({ email: g.email, name: g.name ?? "" })), [form.guests]);
  const setGuests = (next: { email: string; name: string }[]) =>
    setForm((f) => ({
      ...f,
      guests: next.map((a) => {
        const had = f.guests.find((g) => g.email.toLowerCase() === a.email.toLowerCase());
        return had ? { ...had, name: a.name || had.name } : { email: a.email, name: a.name };
      }),
    }));

  /* --- mutations -------------------------------------------------------- */

  const doSave = async (scope?: EventScope) => {
    setError(null);
    if (!form.title.trim()) {
      setError("Give the event a title.");
      titleRef.current?.focus();
      return;
    }
    if (!form.calendar_id) {
      setError("Pick a calendar to put this on.");
      return;
    }
    const body = toInput(form, settings.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone);
    try {
      if (ev) await m.update.mutateAsync({ id: ev.id, scope, ...body });
      else await m.create.mutateAsync(body);
      closeEditor();
    } catch (e) {
      // A failed save stays on screen next to the button — a toast would take the reason with it.
      setError((e as Error).message || "Couldn't save this event.");
    }
  };

  const doDelete = async (scope?: EventScope) => {
    if (!ev) return;
    setError(null);
    try {
      await m.remove.mutateAsync({ id: ev.id, scope });
      closeEditor();
    } catch (e) {
      setError((e as Error).message || "Couldn't delete this event.");
    }
  };

  // Recurring writes always ask which occurrences they mean, and the answer rides as `scope`.
  const requestSave = () => {
    if (readOnly || busy) return;
    if (ev?.recurring) setAsk("save-scope");
    else void doSave();
  };
  const requestDelete = () => {
    if (!ev || readOnly || busy) return;
    setAsk(ev.recurring ? "delete-scope" : "delete");
  };
  const requestClose = () => {
    if (dirty && !readOnly) setAsk("discard");
    else closeEditor();
  };

  /* --- extras ----------------------------------------------------------- */

  const mine = useMemo(() => {
    const emails = new Set<string>();
    if (user?.email) emails.add(user.email.toLowerCase());
    for (const a of accounts) emails.add(a.email.toLowerCase());
    return emails;
  }, [user?.email, accounts]);
  const myInvite = ev?.attendees.find((a) => mine.has(a.email.toLowerCase()));

  const writableCalendars = calendars.filter((c) => c.writable || c.id === form.calendar_id);

  return (
    <Sheet open onOpenChange={(o) => !o && requestClose()}>
      <SheetContent
        side="right"
        className="flex w-full flex-col gap-0 p-0 sm:max-w-none"
        style={{ width: "100%", maxWidth: 540 }}
        onEscapeKeyDown={(e) => {
          if (ask !== null || (dirty && !readOnly)) {
            e.preventDefault();
            if (ask === null) setAsk("discard");
          }
        }}
        onInteractOutside={(e) => {
          if (ask !== null || (dirty && !readOnly)) e.preventDefault();
        }}
        onKeyDown={(e) => {
          // ⌘/Ctrl + Enter saves from anywhere in the sheet.
          if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            e.stopPropagation();
            requestSave();
          }
        }}
      >
        {/* The sheet is full-screen on a phone, so the header clears the notch and the action row
            clears the home indicator. On a desktop both insets are zero and nothing changes. */}
        <SheetHeader className="border-b border-border pb-3 pt-[calc(1rem+env(safe-area-inset-top))]">
          <SheetTitle>{ev ? "Event" : "New event"}</SheetTitle>
          <SheetDescription className="sr-only">Edit the details of a calendar event.</SheetDescription>
        </SheetHeader>

        <div className="min-h-0 flex-1 overflow-y-auto px-4 pb-4">
          {/* Emoji + title */}
          <div className="flex items-center gap-2 border-b border-border py-2">
            <EmojiButton value={form.emoji} onChange={(v) => set("emoji", v)} disabled={readOnly} />
            <input
              ref={titleRef}
              value={form.title}
              disabled={readOnly}
              onChange={(e) => set("title", e.target.value)}
              placeholder="Untitled event"
              aria-label="Title"
              className="min-w-0 flex-1 bg-transparent text-[16px] font-semibold tracking-[-0.01em] text-foreground outline-none placeholder:text-tertiary disabled:opacity-70"
            />
          </div>

          <Row label="All day">
            <label className="inline-flex h-7 items-center gap-2 text-[13px] text-muted-foreground select-none">
              <Switch checked={form.all_day} disabled={readOnly} onCheckedChange={setAllDay} aria-label="All day" />
              {form.all_day ? "Takes the whole day" : "Has a start and an end"}
            </label>
          </Row>

          <Row label="Starts" icon={<CalendarDays />}>
            <div className="flex flex-wrap items-center gap-1.5">
              <DateField value={form.startDate} disabled={readOnly} onChange={(d) => moveStart({ date: d })} />
              {!form.all_day && (
                <TimeField day={form.startDate} minutes={form.startMin} format={settings.time_format} disabled={readOnly} onChange={(min) => moveStart({ min })} />
              )}
            </div>
          </Row>

          <Row label="Ends">
            <div className="flex flex-wrap items-center gap-1.5">
              <DateField value={form.endDate} disabled={readOnly} onChange={(d) => moveEnd({ date: d })} />
              {!form.all_day && (
                <TimeField day={form.endDate} minutes={form.endMin} format={settings.time_format} disabled={readOnly} onChange={(min) => moveEnd({ min })} />
              )}
            </div>
          </Row>

          <Row label="Repeat" icon={<Repeat />}>
            <div className="flex flex-col gap-1.5">
              <Select value={form.repeat} disabled={readOnly} onValueChange={(v) => set("repeat", v as RepeatKind)}>
                <SelectTrigger size="sm" className="w-full max-w-64">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="never">{repeatLabel("never", form.startDate)}</SelectItem>
                  {REPEAT_KINDS.map((k) => (
                    <SelectItem key={k} value={k}>
                      {repeatLabel(k, form.startDate)}
                    </SelectItem>
                  ))}
                  <SelectItem value="custom">Custom…</SelectItem>
                </SelectContent>
              </Select>
              {form.repeat === "custom" && (
                <>
                  <Input
                    value={form.rruleText}
                    disabled={readOnly}
                    onChange={(e) => set("rruleText", e.target.value)}
                    placeholder="FREQ=WEEKLY;INTERVAL=3;BYDAY=TU,TH"
                    aria-label="Recurrence rule"
                    className="h-7 font-mono text-[12px]"
                  />
                  <p className="text-xs text-tertiary">An iCalendar RRULE, without the ending — that's set below.</p>
                </>
              )}
              {form.repeat !== "never" && (
                <div className="flex flex-wrap items-center gap-1.5">
                  <Select value={form.repeatEnd} disabled={readOnly} onValueChange={(v) => set("repeatEnd", v as RepeatEnd)}>
                    <SelectTrigger size="sm" className="w-36">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="never">Ends never</SelectItem>
                      <SelectItem value="until">Ends on…</SelectItem>
                      <SelectItem value="count">Ends after…</SelectItem>
                    </SelectContent>
                  </Select>
                  {form.repeatEnd === "until" && <DateField value={form.until} disabled={readOnly} onChange={(d) => set("until", d)} />}
                  {form.repeatEnd === "count" && (
                    <span className="flex items-center gap-1.5">
                      <Input
                        type="number"
                        min={1}
                        max={999}
                        value={form.count}
                        disabled={readOnly}
                        onChange={(e) => set("count", Math.max(1, Math.min(999, Number(e.target.value) || 1)))}
                        aria-label="Number of times"
                        className="h-7 w-16 tnum"
                      />
                      <span className="text-[13px] text-muted-foreground">times</span>
                    </span>
                  )}
                </div>
              )}
            </div>
          </Row>

          <Row label="Location" icon={<MapPin />}>
            <Input
              value={form.location}
              disabled={readOnly}
              onChange={(e) => set("location", e.target.value)}
              placeholder="Somewhere, or a room"
              aria-label="Location"
              className="h-7"
            />
          </Row>

          <Row label="Calendar">
            <Select value={form.calendar_id} disabled={readOnly} onValueChange={(v) => set("calendar_id", v)}>
              <SelectTrigger size="sm" className="w-full max-w-64">
                <SelectValue placeholder="Pick a calendar" />
              </SelectTrigger>
              <SelectContent>
                {writableCalendars.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    <span className="inline-flex min-w-0 items-center gap-2">
                      <span className="size-2 shrink-0 rounded-full" style={{ background: c.color || "currentColor" }} />
                      <span className="truncate">{c.name}</span>
                    </span>
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Row>

          <Row label="Notes">
            <Textarea
              value={form.description}
              disabled={readOnly}
              onChange={(e) => set("description", e.target.value)}
              placeholder="Anything worth remembering"
              aria-label="Notes"
              className="min-h-16 text-[13px]"
            />
          </Row>

          <div className="border-b border-border py-1">
            <AddressInput label="Guests" value={guestAddresses} onChange={setGuests} placeholder={readOnly ? "" : "Invite people…"} />
            {form.guests.some((g) => g.rsvp && g.rsvp !== "needsAction") && (
              <ul className="flex flex-col gap-0.5 py-1 pl-[68px] text-xs text-muted-foreground">
                {form.guests
                  .filter((g) => g.rsvp && g.rsvp !== "needsAction")
                  .map((g) => (
                    <li key={g.email} className="flex items-center gap-1.5">
                      <span className="truncate">{g.name || g.email}</span>
                      <span className="text-tertiary">· {RSVP_LABEL[g.rsvp as string] ?? g.rsvp}</span>
                    </li>
                  ))}
              </ul>
            )}
          </div>

          <Row label="Link" icon={<Link2 />}>
            <Input value={form.url} disabled={readOnly} onChange={(e) => set("url", e.target.value)} placeholder="https://" aria-label="Link" className="h-7" />
          </Row>

          <Row label="Reminders" icon={<Bell />}>
            <div className="flex flex-col gap-1.5">
              {form.reminders.map((r, i) => {
                const { n, unit } = splitReminder(r.minutes);
                const write = (nn: number, uu: Unit) =>
                  setForm((f) => ({ ...f, reminders: f.reminders.map((x, j) => (j === i ? { minutes: Math.max(0, nn) * UNITS[uu] } : x)) }));
                return (
                  <div key={i} className="flex items-center gap-1.5">
                    <Input
                      type="number"
                      min={0}
                      value={n}
                      disabled={readOnly}
                      onChange={(e) => write(Number(e.target.value) || 0, unit)}
                      aria-label="Reminder amount"
                      className="h-7 w-16 tnum"
                    />
                    <Select value={unit} disabled={readOnly} onValueChange={(v) => write(n, v as Unit)}>
                      <SelectTrigger size="sm" className="w-28">
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value="minutes">minutes</SelectItem>
                        <SelectItem value="hours">hours</SelectItem>
                        <SelectItem value="days">days</SelectItem>
                      </SelectContent>
                    </Select>
                    <span className="text-[13px] text-muted-foreground">before</span>
                    {!readOnly && (
                      <Button
                        variant="ghost"
                        size="icon-xs"
                        aria-label="Remove reminder"
                        className="text-muted-foreground"
                        onClick={() => setForm((f) => ({ ...f, reminders: f.reminders.filter((_, j) => j !== i) }))}
                      >
                        <X />
                      </Button>
                    )}
                  </div>
                );
              })}
              {!readOnly && (
                <Button
                  variant="ghost"
                  size="xs"
                  className="w-fit text-muted-foreground"
                  onClick={() => setForm((f) => ({ ...f, reminders: [...f.reminders, { minutes: 10 }] }))}
                >
                  <Plus /> Add a reminder
                </Button>
              )}
              {form.reminders.length === 0 && readOnly && <span className="text-[13px] text-tertiary">None</span>}
            </div>
          </Row>

          <Row label="Extras">
            <div className="flex flex-col gap-2 pt-0.5">
              <label className="inline-flex items-center gap-2 text-[13px] text-muted-foreground select-none">
                <Switch checked={form.countdown} disabled={readOnly} onCheckedChange={(v) => set("countdown", v)} aria-label="Show a countdown" />
                Show a countdown
              </label>
              <label className="inline-flex items-center gap-2 text-[13px] text-muted-foreground select-none">
                <Switch checked={form.circled} disabled={readOnly} onCheckedChange={(v) => set("circled", v)} aria-label="Circle this day" />
                Circle this day
              </label>
            </div>
          </Row>

          {readOnly && (
            <p className="flex items-start gap-2 pt-3 text-[13px] text-muted-foreground">
              <Lock className="mt-0.5 size-3.5 shrink-0 text-tertiary" />
              This comes from a subscribed calendar{cal ? ` (${cal.name})` : ""} and can't be edited here.
            </p>
          )}

          {ev && (
            <div className="flex flex-col gap-3 pt-4">
              {myInvite && (
                <div className="flex flex-wrap items-center gap-1.5">
                  <span className="text-[13px] text-muted-foreground">Going?</span>
                  {(["accepted", "tentative", "declined"] as Rsvp[]).map((r) => (
                    <Button
                      key={r}
                      variant={ev.rsvp === r ? "secondary" : "outline"}
                      size="sm"
                      disabled={m.rsvp.isPending}
                      onClick={() => m.rsvp.mutate({ id: ev.id, rsvp: r })}
                    >
                      {ev.rsvp === r && <Check />}
                      {RSVP_LABEL[r as string]}
                    </Button>
                  ))}
                </div>
              )}

              <div className="flex flex-wrap items-center gap-1.5">
                {ev.conference_url && (
                  // Native shells never navigate away from the server: hand the link to the OS.
                  <Button size="sm" variant="outline" onClick={() => openExternalUrl(ev.conference_url)}>
                    <Video /> Join
                  </Button>
                )}
                {ev.kind === "todo" && !readOnly && (
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={m.setDone.isPending}
                    onClick={() => m.setDone.mutate({ id: ev.id, done: !ev.done, date: ev.occurrence_date ?? undefined })}
                  >
                    <Check /> {ev.done ? "Mark not done" : "Mark done"}
                  </Button>
                )}
                {ev.thread_id && (
                  <Button size="sm" variant="outline" asChild>
                    <Link to={`/t/${ev.thread_id}`} onClick={() => closeEditor()}>
                      <Mail /> The email this came from
                    </Link>
                  </Button>
                )}
                <Button size="sm" variant="ghost" className="text-muted-foreground" asChild>
                  <a href={eventIcsUrl(ev.id)} download>
                    <Download /> Download .ics
                  </a>
                </Button>
              </div>

              <p className="text-xs text-tertiary">
                {ev.calendar_name}
                {ev.created_at ? ` · added ${new Date(ev.created_at).toLocaleDateString([], { day: "numeric", month: "short", year: "numeric" })}` : ""}
                {ev.updated_at && ev.updated_at !== ev.created_at
                  ? ` · edited ${new Date(ev.updated_at).toLocaleDateString([], { day: "numeric", month: "short", year: "numeric" })}`
                  : ""}
              </p>
            </div>
          )}
        </div>

        <div className="flex items-center gap-2 border-t border-border p-3 pb-[calc(0.75rem+env(safe-area-inset-bottom))]">
          {ev && !readOnly && (
            <>
              <Button variant="ghost" size="icon-sm" aria-label="Delete event" className="text-muted-foreground hover:text-destructive" onClick={requestDelete} disabled={busy}>
                <Trash2 />
              </Button>
              <Button
                variant="ghost"
                size="icon-sm"
                aria-label="Duplicate event"
                title="Duplicate"
                className="text-muted-foreground"
                disabled={busy}
                onClick={async () => {
                  setError(null);
                  try {
                    // Open the copy straight away: you duplicate something in order to change it.
                    const copy = await m.duplicate.mutateAsync(ev.id);
                    openEvent(copy);
                  } catch (e) {
                    setError((e as Error).message || "Couldn't duplicate that.");
                  }
                }}
              >
                <CopyPlus />
              </Button>
            </>
          )}
          {error && (
            <span className="min-w-0 flex-1 truncate text-[13px] text-destructive" role="alert" title={error}>
              {error}
            </span>
          )}
          <span className={cn("flex-1", error && "hidden")} />
          <Button variant="ghost" onClick={requestClose} disabled={busy}>
            {readOnly ? "Close" : "Cancel"}
          </Button>
          {!readOnly && (
            <Button onClick={requestSave} disabled={busy} title="Save (⌘↵)">
              {ev ? "Save" : "Create"}
            </Button>
          )}
        </div>

        {/* window.confirm is blocked in the Mac and iOS webviews, so every question is a dialog. */}
        <AlertDialog open={ask === "discard" || ask === "delete"} onOpenChange={(o) => !o && setAsk(null)}>
          <AlertDialogContent size="sm">
            <AlertDialogHeader>
              <AlertDialogTitle>{ask === "delete" ? "Delete this event?" : "Discard your changes?"}</AlertDialogTitle>
              <AlertDialogDescription>
                {ask === "delete" ? "It disappears from the calendar for everyone it was shared with." : "The edits you made to this event are lost."}
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>{ask === "delete" ? "Keep it" : "Keep editing"}</AlertDialogCancel>
              <AlertDialogAction
                onClick={() => {
                  const which = ask;
                  setAsk(null);
                  if (which === "delete") void doDelete();
                  else closeEditor();
                }}
              >
                {ask === "delete" ? "Delete" : "Discard"}
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>

        <AlertDialog open={ask === "save-scope" || ask === "delete-scope"} onOpenChange={(o) => !o && setAsk(null)}>
          <AlertDialogContent size="sm">
            <AlertDialogHeader>
              <AlertDialogTitle>{ask === "delete-scope" ? "Delete which events?" : "Save to which events?"}</AlertDialogTitle>
              <AlertDialogDescription>“{form.title.trim() || "This event"}” repeats. Choose how far the change reaches.</AlertDialogDescription>
            </AlertDialogHeader>
            <div className="flex flex-col gap-1.5">
              {([
                ["this", "This event"],
                ["following", "This and following events"],
                ["all", "All events"],
              ] as [EventScope, string][]).map(([scope, label]) => (
                <Button
                  key={scope}
                  variant="outline"
                  className="justify-start"
                  onClick={() => {
                    const which = ask;
                    setAsk(null);
                    if (which === "delete-scope") void doDelete(scope);
                    else void doSave(scope);
                  }}
                >
                  {label}
                </Button>
              ))}
            </div>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancel</AlertDialogCancel>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </SheetContent>
    </Sheet>
  );
}
