import type { Env } from "./env";
import type { AccountRow, ContactRow, ThreadRow } from "./db";
import { uid, now, chunk, placeholders, safeJson, runBatch, logSync } from "./db";
import { gmailJson, gmailBatchGet, GmailError, hasMailScope } from "./google";
import { MicrosoftError, hasMsMailScope } from "./microsoft";
import { parseGmailMessage, stripSubjectPrefixes, parseAddressList, type GmailMessage, type ParsedMessage } from "./mime";
import { stripTrackers, htmlToText } from "./sanitize";
import { syncContactPhotos } from "./people";
import { resolveBrandLogos } from "./bimi";
import { assignBundles } from "./db";
import type { Address, Bucket, ScreenStatus } from "@shared/types";

// ---------- Suggestion heuristics ----------
export interface SuggestInput {
  subject: string;
  from_email: string;
  list_unsubscribe?: string;
  list_id?: string;
  precedence?: string;
  labels: string[];
}

const PAPER_TRAIL_RE =
  /\b(receipt|invoice|order|payment|confirmation|confirmed|shipped|shipping|delivery|delivered|statement|booking|reservation|ticket|itinerary|your (order|purchase)|purchase|transaction|subscription renew|renewal|refund|billing)\b/i;
const PAPER_SENDER_RE = /^(noreply|no-reply|no_reply|donotreply|do-not-reply|billing|receipts?|invoices?|orders?|payments?|notifications?)@/i;

export function suggestBucket(i: SuggestInput): "imbox" | "feed" | "paper_trail" {
  const labels = i.labels ?? [];
  const subj = i.subject ?? "";
  if (labels.includes("CATEGORY_PURCHASES") || PAPER_TRAIL_RE.test(subj)) return "paper_trail";
  if (PAPER_SENDER_RE.test(i.from_email) && !i.list_unsubscribe) return "paper_trail";
  if (i.list_unsubscribe || i.list_id || /bulk|list/i.test(i.precedence ?? "")) return "feed";
  if (labels.includes("CATEGORY_PROMOTIONS") || labels.includes("CATEGORY_FORUMS")) return "feed";
  if (labels.includes("CATEGORY_UPDATES") && PAPER_SENDER_RE.test(i.from_email)) return "paper_trail";
  return "imbox";
}

// ---------- Ingest ----------
function bucketForContact(status: ScreenStatus): Bucket {
  switch (status) {
    case "imbox":
    case "feed":
    case "paper_trail":
      return status;
    case "screened_out":
      return "screened_out";
    default:
      return "screener";
  }
}

function unionParticipants(existing: Address[], extra: Address[]): Address[] {
  const map = new Map<string, Address>();
  for (const a of existing) if (a.email) map.set(a.email, a);
  for (const a of extra) {
    if (!a.email) continue;
    const cur = map.get(a.email);
    if (!cur) map.set(a.email, a);
    else if (!cur.name && a.name) map.set(a.email, a);
  }
  return [...map.values()];
}

interface ContactState extends ContactRow {
  _dirty: boolean;
  _new: boolean;
}
interface ThreadState extends ThreadRow {
  /** Received a not-from-me message in this ingest → eligible to join the sender's open bundle. */
  _bundleCandidate?: boolean;
  _dirty: boolean;
  _new: boolean;
}

async function loadExistingMessageIds(db: D1Database, accountId: string, gmailIds: string[]): Promise<Set<string>> {
  const set = new Set<string>();
  for (const ids of chunk(gmailIds, 90)) {
    const r = await db
      .prepare(`SELECT gmail_message_id FROM messages WHERE account_id = ? AND gmail_message_id IN (${placeholders(ids.length)})`)
      .bind(accountId, ...ids)
      .all<{ gmail_message_id: string }>();
    for (const row of r.results) set.add(row.gmail_message_id);
  }
  return set;
}

async function loadThreads(db: D1Database, accountId: string, gmailThreadIds: string[]): Promise<Map<string, ThreadState>> {
  const map = new Map<string, ThreadState>();
  for (const ids of chunk(gmailThreadIds, 90)) {
    const r = await db
      .prepare(`SELECT * FROM threads WHERE account_id = ? AND gmail_thread_id IN (${placeholders(ids.length)})`)
      .bind(accountId, ...ids)
      .all<ThreadRow>();
    for (const row of r.results) map.set(row.gmail_thread_id, { ...row, _dirty: false, _new: false });
  }
  return map;
}

async function loadContacts(db: D1Database, accountId: string, emails: string[]): Promise<Map<string, ContactState>> {
  const map = new Map<string, ContactState>();
  for (const ids of chunk(emails, 90)) {
    const r = await db
      .prepare(`SELECT * FROM contacts WHERE account_id = ? AND email IN (${placeholders(ids.length)})`)
      .bind(accountId, ...ids)
      .all<ContactRow>();
    for (const row of r.results) map.set(row.email, { ...row, _dirty: false, _new: false });
  }
  // Screening decisions are user-wide: a sender already decided on another connected account inherits that decision here.
  const missing = emails.filter((e) => !map.has(e));
  for (const ids of chunk(missing, 90)) {
    const r = await db
      .prepare(
        `SELECT c.email, c.name, c.screen_status, c.screened_at, c.avatar_url, c.bundled FROM contacts c
         WHERE c.account_id IN (SELECT id FROM accounts WHERE user_id = (SELECT user_id FROM accounts WHERE id = ?) AND id <> ?)
           AND c.screen_status <> 'pending' AND c.email IN (${placeholders(ids.length)})
         ORDER BY c.screened_at DESC`
      )
      .bind(accountId, accountId, ...ids)
      .all<{ email: string; name: string; screen_status: ContactRow["screen_status"]; screened_at: number | null; avatar_url: string; bundled: number }>();
    const t = now();
    for (const row of r.results) {
      if (map.has(row.email)) continue;
      map.set(row.email, {
        id: uid(),
        account_id: accountId,
        email: row.email,
        name: row.name ?? "",
        screen_status: row.screen_status,
        screened_at: row.screened_at ?? t,
        first_seen_at: t,
        last_seen_at: t,
        message_count: 0,
        notes: "",
        avatar_url: row.avatar_url ?? "",
        bundled: row.bundled ?? 0,
        _dirty: true,
        _new: true,
      });
    }
  }
  return map;
}

function getOrCreateContact(map: Map<string, ContactState>, accountId: string, a: Address, t: number): ContactState {
  let c = map.get(a.email);
  if (!c) {
    c = {
      id: uid(),
      account_id: accountId,
      email: a.email,
      name: a.name ?? "",
      screen_status: "pending",
      screened_at: null,
      first_seen_at: t,
      last_seen_at: t,
      message_count: 0,
      notes: "",
      avatar_url: "",
      bundled: 0,
      _dirty: true,
      _new: true,
    };
    map.set(a.email, c);
  }
  return c;
}

export interface IngestResult {
  added: number;
  threadIds: string[];
}

/** Kept for call-site compatibility; there is no import mode any more (mail starts from the moment you connect). */
export interface IngestOptions {}

/**
 * Ingest a set of Gmail messages (format=full) for an account. Idempotent.
 */
export async function ingestMessages(env: Env, account: AccountRow, raw: GmailMessage[], opts: IngestOptions = {}): Promise<IngestResult> {
  const db = env.DB;
  if (!raw.length) return { added: 0, threadIds: [] };

  const existing = await loadExistingMessageIds(
    db,
    account.id,
    raw.map((m) => m.id)
  );
  const parsed: ParsedMessage[] = [];
  for (const m of raw) {
    if (!m?.id || existing.has(m.id)) continue;
    if ((m.labelIds ?? []).includes("SPAM")) continue;
    try {
      parsed.push(parseGmailMessage(m));
    } catch (e) {
      await logSync(db, account.id, "warn", `parse failed for ${m.id}: ${(e as Error).message}`);
    }
  }
  return ingestParsed(env, account, parsed, opts);
}

/**
 * Provider-agnostic ingest of already-parsed messages (Gmail sync and the inbound email handler both end up here).
 * `gmailId` must be unique per account (Gmail id, or the Message-ID for domain mailboxes); `threadId` groups messages
 * into threads (Gmail thread id, or a locally generated id). Idempotent via the (account_id, gmail_message_id) unique key.
 */
export async function ingestParsed(env: Env, account: AccountRow, parsed: ParsedMessage[], opts: IngestOptions = {}): Promise<IngestResult> {
  const db = env.DB;
  const t0 = now();
  if (!parsed.length) return { added: 0, threadIds: [] };
  parsed.sort((a, b) => a.date - b.date);

  const myEmail = account.email.toLowerCase();
  const threadMap = await loadThreads(db, account.id, [...new Set(parsed.map((p) => p.threadId))]);
  const emails = new Set<string>();
  for (const p of parsed) {
    if (p.from.email) emails.add(p.from.email);
    for (const a of [...p.to, ...p.cc]) if (a.email) emails.add(a.email);
  }
  emails.delete(myEmail);
  const contactMap = await loadContacts(db, account.id, [...emails]);

  const stmts: D1PreparedStatement[] = [];
  const touchedThreads = new Set<string>();
  let added = 0;

  for (const p of parsed) {
    const labels = p.labelIds;
    const fromMe = labels.includes("SENT") || (p.from.email !== "" && p.from.email === myEmail);
    const isTrash = labels.includes("TRASH");
    const isUnread = labels.includes("UNREAD");
    const { html, trackers } = stripTrackers(p.html);
    const text = p.text || (html ? htmlToText(html) : "");
    const subjectClean = stripSubjectPrefixes(p.subject);

    // Contacts
    let sender: ContactState | null = null;
    if (!fromMe && p.from.email) {
      sender = getOrCreateContact(contactMap, account.id, p.from, p.date);
      sender.message_count += 1;
      sender.last_seen_at = Math.max(sender.last_seen_at, p.date);
      sender.first_seen_at = Math.min(sender.first_seen_at, p.date);
      if (!sender.name && p.from.name) sender.name = p.from.name;
      sender._dirty = true;
    }
    if (fromMe) {
      for (const a of [...p.to, ...p.cc]) {
        if (!a.email || a.email === myEmail) continue;
        const c = getOrCreateContact(contactMap, account.id, a, p.date);
        c.last_seen_at = Math.max(c.last_seen_at, p.date);
        if (!c.name && a.name) c.name = a.name;
        if (c.screen_status === "pending") {
          c.screen_status = "imbox";
          c.screened_at = p.date;
        }
        c._dirty = true;
      }
    }

    // Thread
    let th = threadMap.get(p.threadId);
    const participants: Address[] = [p.from, ...p.to, ...p.cc].filter((a) => a.email);
    if (!th) {
      let bucket: Bucket;
      const st = sender?.screen_status ?? "pending";
      if (isTrash) bucket = "trash";
      else if (fromMe) bucket = "imbox";
      else bucket = bucketForContact(st);
      th = {
        id: uid(),
        account_id: account.id,
        gmail_thread_id: p.threadId,
        subject: subjectClean,
        custom_subject: null,
        snippet: p.snippet,
        bucket,
        seen: fromMe ? 1 : 0,
        unread: fromMe ? 0 : isUnread ? 1 : 0,
        reply_later: 0,
        reply_later_at: null,
        set_aside: 0,
        set_aside_at: null,
        bubble_up_at: null,
        bubbled: 0,
        merged_into: null,
        note: "",
        has_attachments: p.attachments.some((a) => !a.isInline) ? 1 : 0,
        trackers_blocked: trackers.length,
        participants_json: JSON.stringify(unionParticipants([], participants)),
        last_from_email: p.from.email,
        last_from_name: p.from.name,
        message_count: 1,
        first_message_at: p.date,
        last_message_at: p.date,
        is_sent_only: fromMe ? 1 : 0,
        bundle_id: null,
        created_at: t0,
        updated_at: t0,
        _dirty: true,
        _new: true,
        _bundleCandidate: !fromMe && !isTrash,
      };
      threadMap.set(p.threadId, th);
    } else {
      th._dirty = true;
      th.message_count += 1;
      th.updated_at = t0;
      if (!th.subject && subjectClean) th.subject = subjectClean;
      th.has_attachments = th.has_attachments || (p.attachments.some((a) => !a.isInline) ? 1 : 0);
      th.trackers_blocked += trackers.length;
      th.participants_json = JSON.stringify(unionParticipants(safeJson<Address[]>(th.participants_json, []), participants));
      th.first_message_at = Math.min(th.first_message_at, p.date);
      const isNewest = p.date >= th.last_message_at;
      if (isNewest) {
        th.last_message_at = p.date;
        th.snippet = p.snippet;
        th.last_from_email = p.from.email;
        th.last_from_name = p.from.name;
      }
      if (!fromMe) {
        th.is_sent_only = 0;
        if (isNewest && !isTrash) th._bundleCandidate = true;
        const st = sender?.screen_status ?? "pending";
        if (isNewest) {
          th.seen = 0; // new mail shows up in "New" again
          if (isUnread) th.unread = 1;
        } else if (isUnread) th.unread = 1;
        // Bucket rules
        if (!isTrash) {
          if (th.bucket === "screener" || th.bucket === "screened_out") {
            th.bucket = bucketForContact(st);
          } else if (st === "screened_out" && th.bucket !== "trash") {
            th.bucket = "screened_out";
          } else if (st === "pending" && isNewest && th.bucket !== "trash") {
            // First mail from someone you never screened: ask now.
            th.bucket = "screener";
            th.seen = 0;
          } else if (th.bucket === "trash" && isNewest) {
            // A new incoming message on a trashed thread brings it back.
            th.bucket = bucketForContact(st);
          }
        }
      } else {
        if (th.bucket === "screener" && !isTrash) th.bucket = "imbox";
        if (th.bucket === "screened_out" && !isTrash) th.bucket = "imbox";
      }
    }
    touchedThreads.add(th.id);

    // Message row
    const msgId = uid();
    stmts.push(
      db
        .prepare(
          `INSERT OR IGNORE INTO messages (id, account_id, thread_id, gmail_message_id, from_email, from_name, to_json, cc_json, bcc_json, reply_to, subject, date, snippet, text_body, html_body, is_from_me, unread, message_id_header, in_reply_to, references_header, list_unsubscribe, gmail_labels_json, has_attachments, trackers_json, size_estimate, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
        )
        .bind(
          msgId,
          account.id,
          th.id,
          p.gmailId,
          p.from.email,
          p.from.name,
          JSON.stringify(p.to),
          JSON.stringify(p.cc),
          JSON.stringify(p.bcc),
          p.replyTo,
          p.subject,
          p.date,
          p.snippet,
          text.slice(0, 200_000),
          html,
          fromMe ? 1 : 0,
          !fromMe && isUnread ? 1 : 0,
          p.messageId,
          p.inReplyTo,
          p.references.slice(0, 8000),
          p.listUnsubscribe.slice(0, 2000),
          JSON.stringify(labels),
          p.attachments.length ? 1 : 0,
          JSON.stringify(trackers),
          p.sizeEstimate,
          t0
        )
    );
    for (const a of p.attachments) {
      if (!a.attachmentId) continue;
      const attId = uid();
      stmts.push(
        db
          .prepare(
            `INSERT INTO attachments (id, account_id, message_id, thread_id, gmail_attachment_id, filename, mime_type, size, content_id, is_inline, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
          )
          .bind(attId, account.id, msgId, th.id, a.attachmentId, a.filename, a.mimeType, a.size, a.contentId, a.isInline ? 1 : 0, p.date)
      );
      if (a.blob) {
        stmts.push(db.prepare(`INSERT INTO attachment_blobs (attachment_id, data, created_at) VALUES (?, ?, ?)`).bind(attId, a.blob, t0));
      }
    }
    added++;
  }

  // Contacts upsert
  const contactStmts: D1PreparedStatement[] = [];
  for (const c of contactMap.values()) {
    if (!c._dirty) continue;
    contactStmts.push(
      db
        .prepare(
          `INSERT INTO contacts (id, account_id, email, name, screen_status, screened_at, first_seen_at, last_seen_at, message_count, notes, bundled)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(account_id, email) DO UPDATE SET
             name = CASE WHEN contacts.name = '' THEN excluded.name ELSE contacts.name END,
             screen_status = CASE WHEN contacts.screen_status = 'pending' THEN excluded.screen_status ELSE contacts.screen_status END,
             screened_at = COALESCE(contacts.screened_at, excluded.screened_at),
             first_seen_at = MIN(contacts.first_seen_at, excluded.first_seen_at),
             last_seen_at = MAX(contacts.last_seen_at, excluded.last_seen_at),
             message_count = excluded.message_count`
        )
        .bind(c.id, c.account_id, c.email, c.name, c.screen_status, c.screened_at, c.first_seen_at, c.last_seen_at, c.message_count, c.notes, c.bundled ?? 0)
    );
  }
  // Threads upsert
  const threadStmts: D1PreparedStatement[] = [];
  for (const th of threadMap.values()) {
    if (!th._dirty) continue;
    if (th._new) {
      threadStmts.push(
        db
          .prepare(
            `INSERT INTO threads (id, account_id, gmail_thread_id, subject, custom_subject, snippet, bucket, seen, unread, reply_later, reply_later_at, set_aside, set_aside_at, bubble_up_at, bubbled, merged_into, note, has_attachments, trackers_blocked, participants_json, last_from_email, last_from_name, message_count, first_message_at, last_message_at, is_sent_only, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
          )
          .bind(
            th.id, th.account_id, th.gmail_thread_id, th.subject, th.custom_subject, th.snippet, th.bucket, th.seen, th.unread,
            th.reply_later, th.reply_later_at, th.set_aside, th.set_aside_at, th.bubble_up_at, th.bubbled, th.merged_into, th.note,
            th.has_attachments, th.trackers_blocked, th.participants_json, th.last_from_email, th.last_from_name, th.message_count,
            th.first_message_at, th.last_message_at, th.is_sent_only, th.created_at, th.updated_at
          )
      );
    } else {
      threadStmts.push(
        db
          .prepare(
            `UPDATE threads SET subject = ?, snippet = ?, bucket = ?, seen = ?, unread = ?, has_attachments = ?, trackers_blocked = ?, participants_json = ?, last_from_email = ?, last_from_name = ?, message_count = ?, first_message_at = ?, last_message_at = ?, is_sent_only = ?, updated_at = ? WHERE id = ?`
          )
          .bind(
            th.subject, th.snippet, th.bucket, th.seen, th.unread, th.has_attachments, th.trackers_blocked, th.participants_json,
            th.last_from_email, th.last_from_name, th.message_count, th.first_message_at, th.last_message_at, th.is_sent_only, th.updated_at, th.id
          )
      );
    }
  }

  // Order matters: contacts + threads before messages (FK).
  await runBatch(db, [...contactStmts, ...threadStmts, ...stmts], 40);

  // Bundles are batches: only mail that arrives after a sender was bundled joins their open bundle.
  const bundleCandidates = [...threadMap.values()].filter((th) => th._bundleCandidate).map((th) => th.id);
  if (bundleCandidates.length) {
    try {
      await assignBundles(db, account.id, bundleCandidates);
    } catch (e) {
      await logSync(db, account.id, "warn", `Bundle assignment failed: ${(e as Error).message}`);
    }
  }

  // New senders: brand logos (BIMI, what Gmail shows for companies) right away; Google People photos on the next photo sync.
  const newSenders = [...contactMap.values()].filter((c) => c._new).map((c) => c.email);
  if (newSenders.length) {
    await db.prepare(`UPDATE accounts SET contacts_changed_at = ? WHERE id = ?`).bind(now(), account.id).run();
    try {
      await resolveBrandLogos(env, account.id, newSenders);
    } catch (e) {
      await logSync(db, account.id, "warn", `Brand logos failed: ${(e as Error).message}`);
    }
  }
  return { added, threadIds: [...touchedThreads] };
}

// ---------- Sync drivers ----------
interface ListResponse {
  messages?: { id: string; threadId: string }[];
  nextPageToken?: string;
  resultSizeEstimate?: number;
}

/**
 * First sync of a freshly connected Gmail account. HEY behavior: nothing from the past is imported —
 * we just record Gmail's current historyId and watch for new mail from this moment on. Every sender
 * is screened when their first new message arrives.
 */
export async function startFromNow(env: Env, account: AccountRow): Promise<void> {
  const db = env.DB;
  const profile = await gmailJson<{ historyId: string }>(env, account, `profile`);
  account.history_id = profile.historyId;
  account.initial_sync_done = 1;
  account.initial_sync_count = 0;
  account.initial_sync_page_token = null;
  await db
    .prepare(`UPDATE accounts SET initial_sync_count = 0, initial_sync_page_token = NULL, initial_sync_done = 1, history_id = ? WHERE id = ?`)
    .bind(account.history_id, account.id)
    .run();
  await logSync(db, account.id, "info", "Connected — watching for new mail from now on");
  try {
    await syncContactPhotos(env, account);
  } catch (e) {
    await logSync(db, account.id, "warn", `Contact photos failed: ${(e as Error).message}`);
  }
}

interface HistoryResponse {
  history?: {
    id: string;
    messagesAdded?: { message: { id: string; threadId: string; labelIds?: string[] } }[];
    messagesDeleted?: { message: { id: string; threadId: string } }[];
    labelsAdded?: { message: { id: string; threadId: string }; labelIds: string[] }[];
    labelsRemoved?: { message: { id: string; threadId: string }; labelIds: string[] }[];
  }[];
  nextPageToken?: string;
  historyId: string;
}

async function recomputeThreadFlags(db: D1Database, threadIds: string[]) {
  const stmts: D1PreparedStatement[] = [];
  for (const id of threadIds) {
    stmts.push(
      db
        .prepare(
          `UPDATE threads SET
             seen = CASE WHEN threads.unread = 1 AND (SELECT COUNT(*) FROM messages m WHERE m.thread_id = threads.id AND m.unread = 1) = 0 THEN 1 ELSE seen END,
             unread = (SELECT COUNT(*) > 0 FROM messages m WHERE m.thread_id = threads.id AND m.unread = 1),
             message_count = (SELECT COUNT(*) FROM messages m WHERE m.thread_id = threads.id),
             updated_at = ? WHERE id = ?`
        )
        .bind(now(), id)
    );
    stmts.push(db.prepare(`DELETE FROM threads WHERE id = ? AND merged_into IS NULL AND (SELECT COUNT(*) FROM messages m WHERE m.thread_id = ?) = 0`).bind(id, id));
  }
  await runBatch(db, stmts, 40);
}

export async function incrementalSync(env: Env, account: AccountRow): Promise<{ added: number }> {
  const db = env.DB;
  if (!account.history_id) {
    const profile = await gmailJson<{ historyId: string }>(env, account, `profile`);
    account.history_id = profile.historyId;
    await db.prepare(`UPDATE accounts SET history_id = ? WHERE id = ?`).bind(account.history_id, account.id).run();
    return { added: 0 };
  }

  const addedIds = new Map<string, string>(); // gmail message id -> thread id
  const deletedIds = new Set<string>();
  const labelAdds = new Map<string, Set<string>>();
  const labelRemoves = new Map<string, Set<string>>();
  let latestHistoryId = account.history_id;
  let pageToken: string | undefined;
  let pages = 0;

  try {
    do {
      let path = `history?startHistoryId=${encodeURIComponent(account.history_id)}&maxResults=500&historyTypes=messageAdded&historyTypes=messageDeleted&historyTypes=labelAdded&historyTypes=labelRemoved`;
      if (pageToken) path += `&pageToken=${encodeURIComponent(pageToken)}`;
      const h = await gmailJson<HistoryResponse>(env, account, path);
      for (const rec of h.history ?? []) {
        for (const a of rec.messagesAdded ?? []) {
          if ((a.message.labelIds ?? []).includes("SPAM")) continue;
          addedIds.set(a.message.id, a.message.threadId);
        }
        for (const d of rec.messagesDeleted ?? []) {
          deletedIds.add(d.message.id);
          addedIds.delete(d.message.id);
        }
        for (const l of rec.labelsAdded ?? []) {
          const s = labelAdds.get(l.message.id) ?? new Set<string>();
          for (const x of l.labelIds) {
            s.add(x);
            labelRemoves.get(l.message.id)?.delete(x);
          }
          labelAdds.set(l.message.id, s);
        }
        for (const l of rec.labelsRemoved ?? []) {
          const s = labelRemoves.get(l.message.id) ?? new Set<string>();
          for (const x of l.labelIds) {
            s.add(x);
            labelAdds.get(l.message.id)?.delete(x);
          }
          labelRemoves.set(l.message.id, s);
        }
      }
      if (h.historyId) latestHistoryId = h.historyId;
      pageToken = h.nextPageToken;
      pages++;
    } while (pageToken && pages < 5);
  } catch (e) {
    if (e instanceof GmailError && e.status === 404) {
      // History expired: re-list recent messages and reset history id.
      await logSync(db, account.id, "warn", "History expired; re-listing last 7 days");
      const list = await gmailJson<ListResponse>(env, account, `messages?maxResults=100&q=${encodeURIComponent("-in:spam -in:trash newer_than:7d")}`);
      const ids = (list.messages ?? []).map((m) => m.id);
      let added = 0;
      if (ids.length) {
        const full = await gmailBatchGet<GmailMessage>(env, account, ids, "full");
        added = (await ingestMessages(env, account, full)).added;
      }
      const profile = await gmailJson<{ historyId: string }>(env, account, `profile`);
      account.history_id = profile.historyId;
      await db.prepare(`UPDATE accounts SET history_id = ? WHERE id = ?`).bind(account.history_id, account.id).run();
      return { added };
    }
    throw e;
  }

  let added = 0;
  if (addedIds.size) {
    const ids = [...addedIds.keys()].slice(0, 300);
    const full = await gmailBatchGet<GmailMessage>(env, account, ids, "full");
    added = (await ingestMessages(env, account, full)).added;
  }

  // Deletions
  const affectedThreads = new Set<string>();
  if (deletedIds.size) {
    for (const ids of chunk([...deletedIds], 90)) {
      const rows = await db
        .prepare(`SELECT id, thread_id FROM messages WHERE account_id = ? AND gmail_message_id IN (${placeholders(ids.length)})`)
        .bind(account.id, ...ids)
        .all<{ id: string; thread_id: string }>();
      if (!rows.results.length) continue;
      for (const r of rows.results) affectedThreads.add(r.thread_id);
      const localIds = rows.results.map((r) => r.id);
      await db.prepare(`DELETE FROM messages WHERE id IN (${placeholders(localIds.length)})`).bind(...localIds).run();
    }
  }

  // Label changes (UNREAD / TRASH)
  const labelStmts: D1PreparedStatement[] = [];
  const t = now();
  const applyLabel = (gmailMsgId: string, label: string, added: boolean) => {
    if (label === "UNREAD") {
      labelStmts.push(
        db.prepare(`UPDATE messages SET unread = ? WHERE account_id = ? AND gmail_message_id = ? AND is_from_me = 0`).bind(added ? 1 : 0, account.id, gmailMsgId)
      );
    } else if (label === "TRASH") {
      if (added) {
        labelStmts.push(
          db
            .prepare(`UPDATE threads SET bucket = 'trash', updated_at = ? WHERE account_id = ? AND id = (SELECT thread_id FROM messages WHERE account_id = ? AND gmail_message_id = ?)`)
            .bind(t, account.id, account.id, gmailMsgId)
        );
      } else {
        labelStmts.push(
          db
            .prepare(
              `UPDATE threads SET bucket = COALESCE((SELECT CASE c.screen_status WHEN 'pending' THEN (CASE WHEN threads.seen = 0 THEN 'screener' ELSE 'imbox' END) WHEN 'screened_out' THEN 'screened_out' ELSE c.screen_status END FROM contacts c WHERE c.account_id = threads.account_id AND c.email = threads.last_from_email), 'imbox'), updated_at = ?
               WHERE account_id = ? AND bucket = 'trash' AND id = (SELECT thread_id FROM messages WHERE account_id = ? AND gmail_message_id = ?)`
            )
            .bind(t, account.id, account.id, gmailMsgId)
        );
      }
    }
  };
  for (const [id, labels] of labelAdds) for (const l of labels) applyLabel(id, l, true);
  for (const [id, labels] of labelRemoves) for (const l of labels) applyLabel(id, l, false);
  if (labelStmts.length) {
    await runBatch(db, labelStmts, 40);
    // Threads whose unread might have changed
    const ids = [...new Set([...labelAdds.keys(), ...labelRemoves.keys()])];
    for (const part of chunk(ids, 90)) {
      const rows = await db
        .prepare(`SELECT DISTINCT thread_id FROM messages WHERE account_id = ? AND gmail_message_id IN (${placeholders(part.length)})`)
        .bind(account.id, ...part)
        .all<{ thread_id: string }>();
      for (const r of rows.results) affectedThreads.add(r.thread_id);
    }
  }
  if (affectedThreads.size) await recomputeThreadFlags(db, [...affectedThreads]);

  // Gmail hands back a historyId on every poll, but it only moves when something happened. Writing
  // it unchanged once a minute per account costs a row a minute and tells us nothing.
  if (latestHistoryId !== account.history_id) {
    account.history_id = latestHistoryId;
    await db.prepare(`UPDATE accounts SET history_id = ? WHERE id = ?`).bind(account.history_id, account.id).run();
  }
  if (added || deletedIds.size || labelStmts.length) {
    await logSync(db, account.id, "info", `Incremental sync: +${added} msgs, -${deletedIds.size} deleted, ${labelStmts.length} label changes`);
  }
  return { added };
}

/**
 * How stale `last_synced_at` may get on an account that keeps polling and finding nothing. The cron
 * runs every minute; without this every account would write a row a minute forever just to say so.
 */
const HEARTBEAT_MS = 10 * 60_000;

/** Sync one account: continues initial sync (up to N chunks) or does an incremental sync. Safe for cron and manual calls. */
export async function syncAccount(env: Env, account: AccountRow): Promise<{ added: number; status: string }> {
  const db = env.DB;
  if (account.sync_status === "disconnected") return { added: 0, status: "disconnected" };
  if (!account.refresh_token) return { added: 0, status: "disconnected" };
  // An account connected for calendar only has no mail scope: every Gmail call would 403. Leave it
  // alone rather than writing a sync error every minute. (An empty `scopes` predates the column and
  // does have mail — see hasMailScope.)
  if (account.provider === "outlook") {
    if (!hasMsMailScope(account.scopes)) return { added: 0, status: "no_mail_scope" };
  } else if (!hasMailScope(account.scopes)) {
    return { added: 0, status: "no_mail_scope" };
  }
  // The 'syncing' marker exists so a long run isn't started twice by overlapping cron ticks, and so
  // the UI can show a spinner. An incremental poll finishes in well under a second and needs
  // neither, so only the initial backfill pays for the marker. An Outlook mailbox is still walking
  // its delta chain while `initial_sync_done` is 0, so it pays for the marker on the same terms.
  const slow = !account.initial_sync_done;
  if (slow) await db.prepare(`UPDATE accounts SET sync_status = 'syncing' WHERE id = ?`).bind(account.id).run();
  let added = 0;
  try {
    if (account.provider === "outlook") {
      const { syncOutlookAccount } = await import("./outlook");
      added += (await syncOutlookAccount(env, account)).added;
    } else if (!account.initial_sync_done) {
      await startFromNow(env, account);
    } else {
      added += (await incrementalSync(env, account)).added;
      // Photos: daily, or 15 minutes after new senders showed up (so new people get their Gmail-style photo quickly).
      const marker = await db.prepare(`SELECT contacts_changed_at FROM accounts WHERE id = ?`).bind(account.id).first<{ contacts_changed_at: number | null }>();
      const last = account.photos_synced_at ?? 0;
      const sinceLast = now() - last;
      const newContacts = (marker?.contacts_changed_at ?? 0) > last;
      if (!account.photos_synced_at || sinceLast > 24 * 3600_000 || (newContacts && sinceLast > 15 * 60_000)) {
        try {
          await syncContactPhotos(env, account);
        } catch (e) {
          await logSync(db, account.id, "warn", `Contact photos failed: ${(e as Error).message}`);
        }
      }
    }
    // A quiet tick has nothing to record. Stamping `last_synced_at` anyway would be a write a
    // minute per account purely so a label can say "just now"; the heartbeat keeps that label
    // honest to within HEARTBEAT_MS at a fraction of the cost.
    const stale = now() - (account.last_synced_at ?? 0) > HEARTBEAT_MS;
    if (added || slow || stale || account.sync_status !== "idle" || account.sync_error) {
      const t = now();
      account.last_synced_at = t;
      account.sync_status = "idle";
      account.sync_error = null;
      await db
        .prepare(`UPDATE accounts SET sync_status = 'idle', sync_error = NULL, last_synced_at = ? WHERE id = ? AND sync_status <> 'disconnected'`)
        .bind(t, account.id)
        .run();
    }
    return { added, status: "ok" };
  } catch (e) {
    const msg = (e as Error).message ?? String(e);
    const disconnected =
      (e instanceof GmailError || e instanceof MicrosoftError) && (e.status === 401 || /invalid_grant|no_refresh_token/i.test(e.body));
    await db
      .prepare(`UPDATE accounts SET sync_status = ?, sync_error = ?, last_synced_at = ? WHERE id = ?`)
      .bind(disconnected ? "disconnected" : "error", msg.slice(0, 1000), now(), account.id)
      .run();
    await logSync(db, account.id, "error", `Sync failed: ${msg}`);
    return { added, status: disconnected ? "disconnected" : "error" };
  }
}

export async function processBubbleUps(db: D1Database): Promise<number> {
  const t = now();
  const r = await db
    .prepare(`UPDATE threads SET bubbled = 1, bubble_up_at = NULL, seen = 0, unread = 1, updated_at = ? WHERE bubble_up_at IS NOT NULL AND bubble_up_at <= ?`)
    .bind(t, t)
    .run();
  return r.meta.changes ?? 0;
}
