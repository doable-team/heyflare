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
