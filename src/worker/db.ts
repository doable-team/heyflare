import type { Bundle,
  Account,
  Address,
  Attachment,
  Contact,
  Label,
  Message,
  ThreadSummary,
  User,
  Bucket,
  ScreenStatus,
} from "@shared/types";

// ---------- Row types ----------
export interface UserRow {
  id: string;
  email: string;
  name: string;
  password_hash: string;
  role: string;
  disabled: number;
  settings_json: string;
  created_at: number;
  last_login_at: number | null;
  totp_secret?: string | null;
  totp_enabled?: number;
  recovery_codes_json?: string;
}

export interface AccountRow {
  id: string;
  user_id: string;
  provider: "gmail" | "domain" | "outlook" | "imap";
  domain_id: string | null;
  email: string;
  display_name: string;
  access_token: string | null;
  refresh_token: string | null;
  token_expires_at: number | null;
  history_id: string | null;
  /** Outlook only: the Graph @odata.deltaLink cursor. Optional — predates 0015 on older rows. */
  delta_link?: string | null;
  initial_sync_done: number;
  initial_sync_page_token: string | null;
  initial_sync_count: number;
  sync_status: "idle" | "syncing" | "error" | "disconnected";
  sync_error: string | null;
  last_synced_at: number | null;
  signature: string;
  cover_art: string;
  avatar_url: string;
  photos_synced_at: number | null;
  contacts_changed_at?: number | null;
  /** OAuth scopes this account's refresh token carries (space separated). */
  scopes?: string;
  /** Why this account has no calendars, when it has the scope but the list call fails. */
  calendar_error?: string | null;
  created_at: number;
}

export interface DomainRow {
  id: string;
  user_id: string;
  name: string;
  zone_id: string | null;
  status: "pending" | "active" | "error";
  routing: "unconfigured" | "enabled" | "manual";
  sending: "cloudflare" | "resend" | "none";
  catch_all_account_id: string | null;
  error: string | null;
  dns_json: string;
  created_at: number;
  updated_at: number;
}

export interface ContactRow {
  id: string;
  account_id: string;
  email: string;
  name: string;
  screen_status: ScreenStatus;
  screened_at: number | null;
  first_seen_at: number;
  last_seen_at: number;
  message_count: number;
  notes: string;
  avatar_url: string;
  bundled: number;
}

export interface ThreadRow {
  id: string;
  account_id: string;
  gmail_thread_id: string;
  subject: string;
  custom_subject: string | null;
  snippet: string;
  bucket: Bucket;
  seen: number;
  unread: number;
  reply_later: number;
  reply_later_at: number | null;
  set_aside: number;
  set_aside_at: number | null;
  bubble_up_at: number | null;
  bubbled: number;
  merged_into: string | null;
  note: string;
  has_attachments: number;
  trackers_blocked: number;
  participants_json: string;
  last_from_email: string;
  last_from_name: string;
  message_count: number;
  first_message_at: number;
  last_message_at: number;
  is_sent_only: number;
  bundle_id: string | null;
  created_at: number;
  updated_at: number;
}

export interface MessageRow {
  id: string;
  account_id: string;
  thread_id: string;
  gmail_message_id: string;
  from_email: string;
  from_name: string;
  to_json: string;
  cc_json: string;
  bcc_json: string;
  reply_to: string;
  subject: string;
  date: number;
  snippet: string;
  text_body: string;
  html_body: string;
  is_from_me: number;
  unread: number;
  message_id_header: string;
  in_reply_to: string;
  references_header: string;
  list_unsubscribe: string;
  gmail_labels_json: string;
  has_attachments: number;
  trackers_json: string;
  size_estimate: number;
  created_at: number;
}

export interface AttachmentRow {
  id: string;
  account_id: string;
  message_id: string;
  thread_id: string;
  gmail_attachment_id: string;
  filename: string;
  mime_type: string;
  size: number;
  content_id: string;
  is_inline: number;
  created_at: number;
}

export interface LabelRow {
  id: string;
  account_id: string;
  name: string;
  color: string;
  created_at: number;
}

// ---------- Helpers ----------
export const uid = () => crypto.randomUUID();
export const now = () => Date.now();

export function chunk<T>(arr: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

export const placeholders = (n: number) => Array(n).fill("?").join(",");

/** `IN (?,?,?)` fragment + params for a list of ids (never empty: an empty list yields `IN (NULL)`, which matches nothing). */
export function inClause(ids: string[]): { sql: string; params: string[] } {
  if (!ids.length) return { sql: "(NULL)", params: [] };
  return { sql: `(${placeholders(ids.length)})`, params: ids };
}

/** An account the user owns, or null. */
export async function ownedAccount(db: D1Database, userId: string, accountId: string): Promise<AccountRow | null> {
  return (await db.prepare(`SELECT * FROM accounts WHERE id = ? AND user_id = ?`).bind(accountId, userId).first<AccountRow>()) ?? null;
}

/** A row from an account-owned table, only if the account belongs to the user. */
export async function ownedRow<T>(db: D1Database, table: string, id: string, userId: string): Promise<T | null> {
  return (await db.prepare(`SELECT x.* FROM ${table} x JOIN accounts a ON a.id = x.account_id WHERE x.id = ? AND a.user_id = ?`).bind(id, userId).first<T>()) ?? null;
}

/** The account that owns a thread, if the user owns that account. */
export async function accountForThread(db: D1Database, userId: string, threadId: string): Promise<AccountRow | null> {
  return (
    (await db.prepare(`SELECT a.* FROM accounts a JOIN threads t ON t.account_id = a.id WHERE t.id = ? AND a.user_id = ?`).bind(threadId, userId).first<AccountRow>()) ?? null
  );
}

/** Account rows by id (for grouping Gmail calls across accounts). */
export async function accountsById(db: D1Database, userId: string, ids: string[]): Promise<Map<string, AccountRow>> {
  const map = new Map<string, AccountRow>();
  const uniq = [...new Set(ids)];
  for (const part of chunk(uniq, 90)) {
    const rows = await db.prepare(`SELECT * FROM accounts WHERE user_id = ? AND id IN (${placeholders(part.length)})`).bind(userId, ...part).all<AccountRow>();
    for (const r of rows.results) map.set(r.id, r);
  }
  return map;
}

export function safeJson<T>(s: string | null | undefined, fallback: T): T {
  if (!s) return fallback;
  try {
    return JSON.parse(s) as T;
  } catch {
    return fallback;
  }
}

/** Run a possibly-large batch of statements, chunked to keep D1 happy. */
export async function runBatch(db: D1Database, stmts: D1PreparedStatement[], size = 40) {
  for (const part of chunk(stmts, size)) {
    if (part.length) await db.batch(part);
  }
}

// ---------- Mappers ----------
export function toUser(r: UserRow): User {
  return {
    id: r.id,
    email: r.email,
    name: r.name,
    disabled: !!r.disabled,
    settings: safeJson(r.settings_json, {}),
    created_at: r.created_at,
    two_factor_enabled: !!r.totp_enabled,
  };
}

export function toAccount(r: AccountRow): Account {
  return {
    id: r.id,
    email: r.email,
    display_name: r.display_name,
    provider: r.provider === "domain" || r.provider === "outlook" || r.provider === "imap" ? r.provider : "gmail",
    domain_id: r.domain_id ?? null,
    initial_sync_done: !!r.initial_sync_done,
    initial_sync_count: r.initial_sync_count,
    sync_status: r.sync_status,
    sync_error: r.sync_error,
    last_synced_at: r.last_synced_at,
    signature: r.signature,
    cover_art: r.cover_art,
    avatar_url: r.avatar_url ?? "",
    photos_synced_at: r.photos_synced_at ?? null,
    created_at: r.created_at,
  };
}

export function toContact(r: ContactRow): Contact {
  return {
    id: r.id,
    account_id: r.account_id,
    email: r.email,
    name: r.name,
    screen_status: r.screen_status,
    screened_at: r.screened_at,
    first_seen_at: r.first_seen_at,
    last_seen_at: r.last_seen_at,
    message_count: r.message_count,
    notes: r.notes,
    avatar_url: r.avatar_url ?? "",
    bundled: !!r.bundled,
  };
}

export function toLabel(r: LabelRow): Label {
  return { id: r.id, account_id: r.account_id, name: r.name, color: r.color };
}

export function toThreadSummary(r: ThreadRow, labels: Label[] = []): ThreadSummary {
  return {
    id: r.id,
    account_id: r.account_id,
    subject: r.custom_subject ?? r.subject,
    original_subject: r.subject,
    snippet: r.snippet,
    bucket: r.bucket,
    seen: !!r.seen,
    unread: !!r.unread,
    reply_later: !!r.reply_later,
    set_aside: !!r.set_aside,
    bubble_up_at: r.bubble_up_at,
    bubbled: !!r.bubbled,
    note: r.note,
    has_attachments: !!r.has_attachments,
    trackers_blocked: r.trackers_blocked,
    participants: safeJson<Address[]>(r.participants_json, []),
    last_from: { email: r.last_from_email, name: r.last_from_name },
    message_count: r.message_count,
    first_message_at: r.first_message_at,
    last_message_at: r.last_message_at,
    labels,
  };
}

export function toAttachment(r: AttachmentRow, extra?: { thread_subject?: string; from?: Address }): Attachment {
  return {
    id: r.id,
    account_id: r.account_id,
    message_id: r.message_id,
    thread_id: r.thread_id,
    filename: r.filename,
    mime_type: r.mime_type,
    size: r.size,
    is_inline: !!r.is_inline,
    created_at: r.created_at,
    ...(extra ?? {}),
  };
}

/**
 * Inline images arrive as `<img src="cid:...">` pointing at an attachment part. Rewrite them to the
 * attachment proxy so signatures, logos and embedded photos actually render.
 */
export function rewriteCidImages(html: string, messageId: string, attachments: AttachmentRow[]): string {
  if (!html || !html.includes("cid:")) return html;
  const byCid = new Map<string, string>();
  for (const a of attachments) {
    const cid = (a.content_id ?? "").replace(/^<|>$/g, "").trim().toLowerCase();
    if (cid) byCid.set(cid, a.id);
    // Some senders reference the filename instead of the Content-ID.
    const name = (a.filename ?? "").trim().toLowerCase();
    if (name && !byCid.has(name)) byCid.set(name, a.id);
  }
  if (byCid.size === 0) return html;
  return html.replace(/(["'(])cid:([^"')\s>]+)/gi, (whole, open: string, ref: string) => {
    const id = byCid.get(decodeURIComponent(ref).trim().toLowerCase());
    return id ? `${open}/api/messages/${messageId}/attachments/${id}` : whole;
  });
}

export function toMessage(r: MessageRow, attachments: AttachmentRow[] = []): Message {
  return {
    id: r.id,
    account_id: r.account_id,
    thread_id: r.thread_id,
    from: { email: r.from_email, name: r.from_name },
    to: safeJson<Address[]>(r.to_json, []),
    cc: safeJson<Address[]>(r.cc_json, []),
    bcc: safeJson<Address[]>(r.bcc_json, []),
    reply_to: r.reply_to,
    subject: r.subject,
    date: r.date,
    snippet: r.snippet,
    text_body: r.text_body,
    html_body: rewriteCidImages(r.html_body, r.id, attachments),
    is_from_me: !!r.is_from_me,
    unread: !!r.unread,
    has_attachments: !!r.has_attachments,
    trackers: safeJson<string[]>(r.trackers_json, []),
    list_unsubscribe: r.list_unsubscribe,
    attachments: attachments.map((a) => toAttachment(a)),
  };
}

/** Labels for many threads in as few queries as possible. */
export async function getLabelsForThreads(db: D1Database, threadIds: string[]): Promise<Map<string, Label[]>> {
  const map = new Map<string, Label[]>();
  if (!threadIds.length) return map;
  for (const ids of chunk(threadIds, 90)) {
    const rows = await db
      .prepare(
        `SELECT tl.thread_id, l.id, l.account_id, l.name, l.color FROM thread_labels tl JOIN labels l ON l.id = tl.label_id WHERE tl.thread_id IN (${placeholders(ids.length)}) ORDER BY l.name`
      )
      .bind(...ids)
      .all<{ thread_id: string; id: string; account_id: string; name: string; color: string }>();
    for (const r of rows.results) {
      const arr = map.get(r.thread_id) ?? [];
      arr.push({ id: r.id, account_id: r.account_id, name: r.name, color: r.color });
      map.set(r.thread_id, arr);
    }
  }
  return map;
}

export async function threadsWithLabels(db: D1Database, rows: ThreadRow[]): Promise<ThreadSummary[]> {
  const labels = await getLabelsForThreads(
    db,
    rows.map((r) => r.id)
  );
  return attachAvatars(db, rows.map((r) => toThreadSummary(r, labels.get(r.id) ?? [])));
}

/** contacts.avatar_url for (account_id, email) pairs, keyed `${account_id}|${email}`. Only non-empty urls are returned. */
export async function avatarMap(db: D1Database, pairs: { account_id: string; email: string }[]): Promise<Map<string, string>> {
  const map = new Map<string, string>();
  const byAccount = new Map<string, Set<string>>();
  for (const p of pairs) {
    if (!p.email || !p.account_id) continue;
    const s = byAccount.get(p.account_id) ?? new Set<string>();
    s.add(p.email.toLowerCase());
    byAccount.set(p.account_id, s);
  }
  for (const [accountId, emails] of byAccount) {
    for (const part of chunk([...emails], 90)) {
      const rows = await db
        .prepare(`SELECT email, avatar_url FROM contacts WHERE account_id = ? AND avatar_url <> '' AND email IN (${placeholders(part.length)})`)
        .bind(accountId, ...part)
        .all<{ email: string; avatar_url: string }>();
      for (const r of rows.results) map.set(`${accountId}|${r.email}`, r.avatar_url);
    }
    // Fall back to the Google address book (any of this user's accounts) for people who aren't contacts yet.
    const missing = [...emails].filter((e) => !map.has(`${accountId}|${e}`));
    for (const part of chunk(missing, 90)) {
      const rows = await db
        .prepare(
          `SELECT b.email, b.avatar_url FROM address_book b
           WHERE b.avatar_url <> '' AND b.email IN (${placeholders(part.length)})
             AND b.account_id IN (SELECT id FROM accounts WHERE user_id = (SELECT user_id FROM accounts WHERE id = ?))`
        )
        .bind(...part, accountId)
        .all<{ email: string; avatar_url: string }>();
      for (const r of rows.results) if (!map.has(`${accountId}|${r.email}`)) map.set(`${accountId}|${r.email}`, r.avatar_url);
    }
  }
  return map;
}

/** Fill `last_from.avatar_url` (and participants) on thread summaries from the contacts table. */
export async function attachAvatars(db: D1Database, summaries: ThreadSummary[]): Promise<ThreadSummary[]> {
  if (!summaries.length) return summaries;
  const pairs: { account_id: string; email: string }[] = [];
  for (const s of summaries) {
    pairs.push({ account_id: s.account_id, email: s.last_from.email });
    for (const p of s.participants) pairs.push({ account_id: s.account_id, email: p.email });
  }
  const map = await avatarMap(db, pairs);
  if (!map.size) return summaries;
  for (const s of summaries) {
    const u = map.get(`${s.account_id}|${s.last_from.email.toLowerCase()}`);
    if (u) s.last_from.avatar_url = u;
    for (const p of s.participants) {
      const pu = map.get(`${s.account_id}|${p.email.toLowerCase()}`);
      if (pu) p.avatar_url = pu;
    }
  }
  return summaries;
}

export async function logSync(db: D1Database, accountId: string | null, level: "info" | "warn" | "error", message: string) {
  try {
    await db
      .prepare(`INSERT INTO sync_log (account_id, level, message, created_at) VALUES (?, ?, ?, ?)`)
      .bind(accountId, level, message.slice(0, 2000), now())
      .run();
  } catch {
    // ignore
  }
}

/**
 * Bundles: collapse threads from bundled senders into one entry per (account, sender).
 * Returns the remaining threads plus the bundles (each with its latest thread and counts).
 */
export interface BundleRow {
  id: string;
  account_id: string;
  contact_id: string;
  email: string;
  status: "open" | "seen";
  thread_count: number;
  message_count: number;
  first_message_at: number;
  last_message_at: number;
  seen_at: number | null;
  created_at: number;
}

/** Bundle batches for the accounts in scope, with the latest (non-parked) thread as the row preview. */
export async function loadBundles(db: D1Database, accountIds: string[], bucket: "imbox" | "paper_trail", now_: number): Promise<Bundle[]> {
  if (!accountIds.length) return [];
  const sc = inClause(accountIds);
  const rows = await db
    .prepare(
      `SELECT b.*, c.name AS contact_name, c.avatar_url AS contact_avatar FROM bundles b
       LEFT JOIN contacts c ON c.id = b.contact_id
       WHERE b.account_id IN ${sc.sql}
         AND EXISTS (SELECT 1 FROM threads t WHERE t.bundle_id = b.id AND t.bucket = ? AND t.merged_into IS NULL AND t.reply_later = 0 AND t.set_aside = 0 AND (t.bubble_up_at IS NULL OR t.bubble_up_at <= ?))
       ORDER BY b.last_message_at DESC LIMIT 200`
    )
    .bind(...sc.params, bucket, now_)
    .all<BundleRow & { contact_name: string | null; contact_avatar: string | null }>();
  if (!rows.results.length) return [];
  const out: Bundle[] = [];
  for (const b of rows.results) {
    const latestRow = await db
      .prepare(
        `SELECT t.* FROM threads t WHERE t.bundle_id = ? AND t.bucket = ? AND t.merged_into IS NULL AND t.reply_later = 0 AND t.set_aside = 0 AND (t.bubble_up_at IS NULL OR t.bubble_up_at <= ?) ORDER BY t.last_message_at DESC LIMIT 1`
      )
      .bind(b.id, bucket, now_)
      .first<ThreadRow>();
    if (!latestRow) continue;
    const counts = await db
      .prepare(`SELECT COUNT(*) AS threads, COALESCE(SUM(message_count), 0) AS messages FROM threads t WHERE t.bundle_id = ? AND t.merged_into IS NULL AND t.reply_later = 0 AND t.set_aside = 0`)
      .bind(b.id)
      .first<{ threads: number; messages: number }>();
    const [latest] = await attachAvatars(db, [toThreadSummary(latestRow, [])]);
    out.push({
      id: b.id,
      contact_id: b.contact_id,
      account_id: b.account_id,
      email: b.email,
      name: b.contact_name || latest.last_from.name || b.email,
      avatar_url: b.contact_avatar || latest.last_from.avatar_url || "",
      status: b.status,
      thread_count: counts?.threads ?? b.thread_count,
      message_count: counts?.messages ?? b.message_count,
      latest,
      first_message_at: b.first_message_at,
      last_message_at: b.last_message_at,
    });
  }
  return out;
}

/** Recompute a bundle's counts and timestamps from its threads. */
export async function refreshBundle(db: D1Database, bundleId: string): Promise<void> {
  await db
    .prepare(
      `UPDATE bundles SET
         thread_count = (SELECT COUNT(*) FROM threads t WHERE t.bundle_id = bundles.id AND t.merged_into IS NULL),
         message_count = (SELECT COALESCE(SUM(t.message_count), 0) FROM threads t WHERE t.bundle_id = bundles.id AND t.merged_into IS NULL),
         first_message_at = COALESCE((SELECT MIN(t.first_message_at) FROM threads t WHERE t.bundle_id = bundles.id), first_message_at),
         last_message_at = COALESCE((SELECT MAX(t.last_message_at) FROM threads t WHERE t.bundle_id = bundles.id), last_message_at)
       WHERE id = ?`
    )
    .bind(bundleId)
    .run();
}

/**
 * Batch assignment after ingest: threads that just received a not-from-me message from a bundled sender join that
 * sender's open bundle for the account (creating one when none is open). Threads sitting in a seen bundle move to the
 * open one. Bundling is not retroactive: only threads touched by new mail are considered.
 */
export async function assignBundles(db: D1Database, accountId: string, threadIds: string[]): Promise<void> {
  if (!threadIds.length) return;
  const t = Date.now();
  for (const ids of chunk(threadIds, 90)) {
    const rows = await db
      .prepare(
        `SELECT t.id, t.bundle_id, t.last_from_email, t.last_message_at, t.first_message_at, t.message_count, c.id AS contact_id
         FROM threads t JOIN contacts c ON c.account_id = t.account_id AND c.email = t.last_from_email
         WHERE t.account_id = ? AND t.id IN (${placeholders(ids.length)}) AND c.bundled = 1 AND t.bucket IN ('imbox','paper_trail') AND t.merged_into IS NULL AND t.is_sent_only = 0`
      )
      .bind(accountId, ...ids)
      .all<{ id: string; bundle_id: string | null; last_from_email: string; last_message_at: number; first_message_at: number; message_count: number; contact_id: string }>();
    const touched = new Set<string>();
    for (const r of rows.results) {
      let open = await db
        .prepare(`SELECT id FROM bundles WHERE account_id = ? AND email = ? AND status = 'open' LIMIT 1`)
        .bind(accountId, r.last_from_email)
        .first<{ id: string }>();
      if (!open) {
        const id = crypto.randomUUID();
        await db
          .prepare(`INSERT INTO bundles (id, account_id, contact_id, email, status, thread_count, message_count, first_message_at, last_message_at, seen_at, created_at) VALUES (?, ?, ?, ?, 'open', 0, 0, ?, ?, NULL, ?)`)
          .bind(id, accountId, r.contact_id, r.last_from_email, r.last_message_at, r.last_message_at, t)
          .run();
        open = { id };
      }
      if (r.bundle_id !== open.id) {
        if (r.bundle_id) touched.add(r.bundle_id);
        await db.prepare(`UPDATE threads SET bundle_id = ?, updated_at = ? WHERE id = ?`).bind(open.id, t, r.id).run();
      }
      touched.add(open.id);
    }
    for (const id of touched) await refreshBundle(db, id);
  }
}
