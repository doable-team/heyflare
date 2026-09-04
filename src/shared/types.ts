// Shared API types between worker and web.

export type Bucket = "screener" | "imbox" | "feed" | "paper_trail" | "screened_out" | "trash";
export type ScreenStatus = "pending" | "imbox" | "feed" | "paper_trail" | "screened_out";

export interface User {
  id: string;
  email: string;
  name: string;
  disabled: boolean;
  settings: UserSettings;
  created_at: number;
  two_factor_enabled?: boolean;
}

export interface UserSettings {
  theme?: "light" | "dark" | "system";
  // Default place for new screened-in senders. Not a rule, just the default selection.
  defaultScreenTarget?: Exclude<ScreenStatus, "pending" | "screened_out">;
  undoSendSeconds?: number; // 0 disables
  showPreviews?: boolean;
}

export interface Account {
  id: string;
  email: string;
  display_name: string;
  provider: "gmail" | "domain";
  domain_id: string | null;
  initial_sync_done: boolean;
  initial_sync_count: number;
  sync_status: "idle" | "syncing" | "error" | "disconnected";
  sync_error: string | null;
  last_synced_at: number | null;
  signature: string;
  cover_art: string;
  avatar_url: string;
  photos_synced_at: number | null;
  created_at: number;
}

export interface Address {
  email: string;
  name: string;
  avatar_url?: string;
}

export interface Label {
  account_id: string;
  id: string;
  name: string;
  color: string;
}

export interface ThreadSummary {
  account_id: string;
  id: string;
  subject: string; // custom_subject ?? subject
  original_subject: string;
  snippet: string;
  bucket: Bucket;
  seen: boolean;
  unread: boolean;
  reply_later: boolean;
  set_aside: boolean;
  bubble_up_at: number | null;
  bubbled: boolean;
  note: string;
  has_attachments: boolean;
  trackers_blocked: number;
  participants: Address[];
  last_from: Address;
  message_count: number;
  first_message_at: number;
  last_message_at: number;
  labels: Label[];
  // Screener-only: status of the sender's contact
  sender_status?: ScreenStatus;
}

export interface Attachment {
  account_id: string;
  id: string;
  message_id: string;
  thread_id: string;
  filename: string;
  mime_type: string;
  size: number;
  is_inline: boolean;
  created_at: number;
  // Optional context (Files page)
  thread_subject?: string;
  from?: Address;
}

export interface Message {
  account_id: string;
  id: string;
  thread_id: string;
  from: Address;
  to: Address[];
  cc: Address[];
  bcc: Address[];
  reply_to: string;
  subject: string;
  date: number;
  snippet: string;
  text_body: string;
  html_body: string; // sanitized-ish (tracker pixels removed). Client must still DOMPurify + sandbox.
  is_from_me: boolean;
  unread: boolean;
  has_attachments: boolean;
  trackers: string[]; // blocked tracker hostnames
  list_unsubscribe: string;
  attachments: Attachment[];
}

export interface ThreadDetail extends ThreadSummary {
  messages: Message[];
  collections: { id: string; name: string }[];
  clips: Clip[];
  merged_threads: { id: string; subject: string }[];
  /** Whether the latest sender is bundled (for the Bundle / Unbundle toggle). */
  sender_bundled: boolean;
}

export interface Contact {
  account_id: string;
  id: string;
  email: string;
  name: string;
  screen_status: ScreenStatus;
  screened_at: number | null;
  first_seen_at: number;
  last_seen_at: number;
  message_count: number;
  notes: string;
  avatar_url: string;
  /** All their mail collapses into one row in the Imbox / Paper Trail. */
  bundled: boolean;
}

/**
 * One person, merged across every account that has heard from them. Contact rows are per (account, email);
 * the list and detail views collapse them so someone who writes to three of your addresses is one entry.
 */
export interface MergedContact extends Contact {
  /** True when the accounts disagree about where this person's mail goes. */
  mixed: boolean;
  accounts: { account_id: string; contact_id: string; screen_status: ScreenStatus; bundled: boolean }[];
}

/** Whether a screening / bundling change applies to every connected account, or only the one it came from. */
export type DecisionScope = "all" | "account";

/** One bundled sender, standing in for all of their threads in a list. */
export interface Bundle {
  id: string;
  contact_id: string;
  account_id: string;
  email: string;
  name: string;
  avatar_url: string;
  status: "open" | "seen";
  thread_count: number;
  message_count: number;
  latest: ThreadSummary;
  first_message_at: number;
  last_message_at: number;
}

export interface BundleDetail {
  bundle: Bundle;
  threads: (ThreadSummary & { latest_message: Message | null })[];
}

export interface Collection {
  account_id: string;
  id: string;
  name: string;
  description: string;
  thread_count: number;
  file_count: number;
  created_at: number;
  updated_at: number;
}

export interface Clip {
  account_id: string;
  id: string;
  thread_id: string;
  message_id: string | null;
  text: string;
  created_at: number;
  thread_subject?: string;
}

export interface Draft {
  account_id: string;
  id: string;
  thread_id: string | null;
  reply_to_message_id: string | null;
  to: Address[];
  cc: Address[];
  bcc: Address[];
  subject: string;
  body_html: string;
  send_at: number | null;
  status: "draft" | "scheduled" | "sending" | "sent" | "failed";
  error: string | null;
  created_at: number;
  updated_at: number;
}

export interface ImboxResponse {
  new_threads: ThreadSummary[];
  seen_threads: ThreadSummary[];
  reply_later: ThreadSummary[];
  set_aside: ThreadSummary[];
  screener_count: number;
  screener_senders: (Address & { account_id: string; thread_count: number })[];
  bundles: Bundle[];
}

export interface Counts {
  screener: number;
  imbox_new: number;
  feed_new: number;
  paper_trail_new: number;
  reply_later: number;
  set_aside: number;
}

export interface ApiError {
  error: string;
}

export interface DnsRecord {
  type: string;
  name: string;
  content: string;
  priority?: number;
}

export interface Domain {
  id: string;
  name: string;
  zone_id: string | null;
  status: "pending" | "active" | "error";
  routing: "unconfigured" | "enabled" | "manual";
  sending: "cloudflare" | "resend" | "none";
  catch_all_account_id: string | null;
  error: string | null;
  dns: DnsRecord[];
  instructions: string[];
  mailboxes: Account[];
  created_at: number;
}

export interface TwoFactorStatus {
  enabled: boolean;
  recovery_left: number;
}

/* ---------- AI assistant ---------- */
export interface AiPreset {
  id: "anthropic" | "openai" | "xai" | "openrouter" | "gemini" | "custom";
  label: string;
  kind: "anthropic" | "openai_compatible";
  base_url: string;
  default_model: string;
  models: string[];
  key_placeholder: string;
  key_url?: string;
}
export interface AiSettings {
  configured: boolean;
  provider: "anthropic" | "openai_compatible";
  preset: AiPreset["id"];
  base_url: string;
  key_hint: string;
  model: string;
  learn: boolean;
  auto_send: boolean;
  presets: AiPreset[];
  last_learned_at: number | null;
  server_ready: boolean;
}
export type AiMemoryKind = "profile" | "tone" | "fact" | "preference" | "contact";
export interface AiMemoryEntry {
  id: string;
  kind: AiMemoryKind;
  content: string;
  source: "user" | "assistant" | "learned";
  created_at: number;
  updated_at: number;
}
export interface AiConversation {
  id: string;
  title: string;
  created_at: number;
  updated_at: number;
}
export interface AiDraftCard {
  draft_id: string;
  account_id: string;
  from: string;
  thread_id: string | null;
  to: Address[];
  cc: Address[];
  subject: string;
  body_text: string;
}

/* ---------- Calendar ---------- */
export type CalendarSource = "local" | "google" | "ics";
export type EventKind = "event" | "birthday" | "anniversary" | "todo";
export type Rsvp = "" | "needsAction" | "accepted" | "declined" | "tentative";
/** HEY has three: a day, a week, a year. No month grid, no agenda list. */
export type CalendarView = "days" | "week" | "year";

export interface Calendar {
  id: string;
  account_id: string | null;
  account_email?: string | null;
  source: CalendarSource;
  remote_id: string | null;
  url: string | null;
  name: string;
  description: string;
  color: string;
  timezone: string;
  visible: boolean;
  writable: boolean;
  is_default: boolean;
  position: number;
  last_synced_at: number | null;
  sync_status: "idle" | "syncing" | "error";
  sync_error: string | null;
  event_count?: number;
}

export interface EventAttendee {
  email: string;
  name?: string;
  rsvp?: Rsvp;
  optional?: boolean;
  organizer?: boolean;
}

export interface Reminder {
  minutes: number;
}

/** One occurrence, ready to draw. Recurring masters are expanded server-side into these. */
export interface CalEvent {
  id: string;            // "<row id>" or "<row id>@<YYYY-MM-DD>" for an expanded occurrence
  event_id: string;      // the stored row
  occurrence_date: string | null;
  calendar_id: string;
  calendar_name: string;
  calendar_color: string;
  source: CalendarSource;
  writable: boolean;
  kind: EventKind;
  title: string;
  description: string;
  location: string;
  emoji: string;
  all_day: boolean;
  starts_at: number;
  ends_at: number;
  start_date: string | null;
  end_date: string | null;
  timezone: string;
  rrule: string | null;
  recurring: boolean;
  status: "confirmed" | "tentative" | "cancelled";
  busy: boolean;
  countdown: boolean;
  circled: boolean;
  organizer: Address | null;
  attendees: EventAttendee[];
  rsvp: Rsvp;
  conference_url: string;
  url: string;
  reminders: Reminder[];
  thread_id: string | null;
  done: boolean;
  created_at: number;
  updated_at: number;
}

export interface Habit {
  id: string;
  name: string;
  icon: string;
  color: string;
  days: number[];
  position: number;
  archived: boolean;
  /** YYYY-MM-DD values inside the requested window. */
  completions?: string[];
  streak?: number;
}

export interface FlexTask {
  id: string;
  week_start: string;
  title: string;
  done: boolean;
  position: number;
}

export interface TimeEntry {
  id: string;
  title: string;
  event_id: string | null;
  started_at: number;
  ended_at: number | null;
}

export interface DayCover {
  id: string;
  url: string;
  width: number;
  height: number;
  size: number;
  name: string;
  created_at: number;
}

export interface CalendarDay {
  date: string;
  label: string;
  cover_url: string;
  cover_id: string | null;
  /** CSS object-position for the crop, e.g. "50% 30%". */
  cover_position: string;
  has_journal: boolean;
  journal_updated_at: number | null;
}

export interface JournalEntry extends CalendarDay {
  journal_html: string;
}

/** A row of the journal index: the day, plus the first plain-text line of its entry. */
export interface JournalIndexEntry extends CalendarDay {
  excerpt: string;
}

export interface CalendarSettings {
  timezone: string;
  week_start: number;
  night_start: number;
  night_end: number;
  collapse_night: boolean;
  time_format: "12" | "24";
  default_view: CalendarView;
  show_declined: boolean;
  cover_art: boolean;
}

/** GET /api/calendar/events?from=&to= — everything needed to draw a range of days. */
export interface CalendarRange {
  from: string;
  to: string;
  events: CalEvent[];
  habits: Habit[];
  days: CalendarDay[];
  flex_tasks: FlexTask[];
  time_entries: TimeEntry[];
}

/** One connected Google account, and what its refresh token actually carries. */
export interface GoogleCalendarAccount {
  id: string;
  email: string;
  /** Its token carries the Google Calendar scope. */
  calendar: boolean;
  /** Its token carries the Gmail scope — or predates the `scopes` column, which means it does. */
  mail: boolean;
  /** How many of its calendars heyflare holds. */
  calendar_count: number;
  sync_error: string | null;
  /** Why the calendar list failed, when the scope is granted but Google refused the call. */
  calendar_error: string | null;
}

export interface CalendarSourcesResponse {
  calendars: Calendar[];
  settings: CalendarSettings;
  /** Gmail accounts that have not yet granted the Calendar scope. */
  connectable: { id: string; email: string }[];
  /** Every Google account, connected for mail, calendar or both. */
  google_accounts: GoogleCalendarAccount[];
}
