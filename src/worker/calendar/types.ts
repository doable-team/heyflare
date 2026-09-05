// Row shapes for the calendar tables (migrations/0011_calendar.sql) and the small vocabulary the
// calendar modules share. Times are epoch milliseconds; dates are "YYYY-MM-DD" in the user's zone.

export interface CalendarRow {
  id: string;
  user_id: string;
  account_id: string | null;
  source: "local" | "google" | "ics";
  remote_id: string | null;
  url: string | null;
  name: string;
  description: string;
  color: string;
  timezone: string;
  visible: number;
  writable: number;
  is_default: number;
  position: number;
  sync_token: string | null;
  etag: string | null;
  last_synced_at: number | null;
  /** When the calendar was last pulled from scratch rather than through its sync token. */
  full_synced_at: number | null;
  sync_status: "idle" | "syncing" | "error";
  sync_error: string | null;
  created_at: number;
  updated_at: number;
}

export interface EventRow {
  id: string;
  user_id: string;
  calendar_id: string;
  remote_id: string | null;
  ical_uid: string | null;
  kind: "event" | "birthday" | "anniversary" | "todo";
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
  exdates: string;
  master_id: string | null;
  occurrence_date: string | null;
  status: "confirmed" | "tentative" | "cancelled";
  busy: number;
  countdown: number;
  circled: number;
  organizer_email: string;
  organizer_name: string;
  attendees_json: string;
  rsvp: string;
  conference_url: string;
  url: string;
  reminders_json: string;
  thread_id: string | null;
  message_id: string | null;
  done_at: number | null;
  etag: string | null;
  created_at: number;
  updated_at: number;
}

export interface HabitRow {
  id: string;
  user_id: string;
  name: string;
  icon: string;
  color: string;
  days: string;
  position: number;
  archived: number;
  created_at: number;
  updated_at: number;
}

export interface CalendarDayRow {
  user_id: string;
  date: string;
  label: string;
  cover_url: string;
  journal_html: string;
  journal_updated_at: number | null;
  cover_id: string | null;
  cover_position: string;
  updated_at: number;
}

export interface DayCoverRow {
  id: string;
  user_id: string;
  mime: string;
  width: number;
  height: number;
  size: number;
  name: string;
  created_at: number;
}

export interface FlexTaskRow {
  id: string;
  user_id: string;
  week_start: string;
  title: string;
  done_at: number | null;
  position: number;
  created_at: number;
  updated_at: number;
}

export interface TimeEntryRow {
  id: string;
  user_id: string;
  title: string;
  event_id: string | null;
  started_at: number;
  ended_at: number | null;
  created_at: number;
  updated_at: number;
}

export interface CalendarSettingsRow {
  user_id: string;
  timezone: string;
  week_start: number;
  night_start: number;
  night_end: number;
  collapse_night: number;
  time_format: string;
  default_view: string;
  show_declined: number;
  cover_art: number;
  updated_at: number;
}

