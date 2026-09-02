// Inbound mail for custom-domain mailboxes: Cloudflare Email Routing (catch-all → this Worker) → parse → ingest.
import PostalMime from "postal-mime";
import type { Env } from "./env";
import type { AccountRow, DomainRow } from "./db";
import { uid, now, logSync } from "./db";
import { ingestParsed, type IngestOptions } from "./sync";
import { parseAddressList, type ParsedMessage, type ParsedAttachment } from "./mime";
import { htmlToText } from "./sanitize";
import type { Address } from "@shared/types";

const MAX_RAW = 25 * 1024 * 1024;
const MAX_BLOB = 900 * 1024;

interface ForwardableEmailMessage {
  readonly from: string;
  readonly to: string;
  readonly headers: Headers;
  readonly raw: ReadableStream<Uint8Array>;
  readonly rawSize: number;
  setReject(reason: string): void;
}

function addr(a: { name?: string; address?: string } | undefined | null): Address {
  return { email: (a?.address ?? "").toLowerCase().trim(), name: (a?.name ?? "").trim() };
}
function addrs(list: { name?: string; address?: string }[] | undefined): Address[] {
  return (list ?? []).map(addr).filter((a) => a.email);
}

function toArrayBuffer(content: unknown): ArrayBuffer | null {
  if (!content) return null;
  if (content instanceof ArrayBuffer) return content;
  if (ArrayBuffer.isView(content)) {
    const v = content as ArrayBufferView;
    return v.buffer.slice(v.byteOffset, v.byteOffset + v.byteLength) as ArrayBuffer;
  }
  if (typeof content === "string") return new TextEncoder().encode(content).buffer as ArrayBuffer;
  return null;
}

/** Resolve which mailbox should receive mail addressed to `rcpt`. */
export async function resolveMailbox(db: D1Database, rcpt: string): Promise<AccountRow | null> {
  const email = rcpt.toLowerCase().trim();
  const direct = await db.prepare(`SELECT * FROM accounts WHERE provider = 'domain' AND email = ? LIMIT 1`).bind(email).first<AccountRow>();
  if (direct) return direct;
  const domain = email.split("@")[1] ?? "";
  if (!domain) return null;
  const d = await db.prepare(`SELECT * FROM domains WHERE name = ?`).bind(domain).first<DomainRow>();
  if (!d?.catch_all_account_id) return null;
  return (await db.prepare(`SELECT * FROM accounts WHERE id = ? AND provider = 'domain'`).bind(d.catch_all_account_id).first<AccountRow>()) ?? null;
}

/** Find the local thread key (threads.gmail_thread_id) for a reply, via In-Reply-To / References. */
async function threadKeyFor(db: D1Database, accountId: string, inReplyTo: string, references: string): Promise<string | null> {
  const ids = [...new Set([inReplyTo, ...references.split(/\s+/)].map((s) => s.trim()).filter(Boolean))].slice(0, 20);
  if (!ids.length) return null;
  const row = await db
    .prepare(`SELECT t.gmail_thread_id FROM messages m JOIN threads t ON t.id = m.thread_id WHERE m.account_id = ? AND m.message_id_header IN (${ids.map(() => "?").join(",")}) ORDER BY m.date DESC LIMIT 1`)
    .bind(accountId, ...ids)
    .first<{ gmail_thread_id: string }>();
  return row?.gmail_thread_id ?? null;
}

export async function parseInbound(raw: ReadableStream<Uint8Array> | ArrayBuffer | string, envelopeFrom: string, envelopeTo: string): Promise<Omit<ParsedMessage, "threadId">> {
  const email: any = await PostalMime.parse(raw as any);
  const headers: Record<string, string> = {};
  for (const h of email.headers ?? []) headers[String(h.key).toLowerCase()] = String(h.value ?? "");
  const from = email.from?.address ? addr(email.from) : { email: envelopeFrom.toLowerCase(), name: "" };
  let to = addrs(email.to);
  if (!to.length) to = parseAddressList(envelopeTo);
  const date = email.date ? Date.parse(email.date) : NaN;
  const html: string = email.html ?? "";
  const text: string = email.text ?? (html ? htmlToText(html) : "");
  const attachments: ParsedAttachment[] = [];
  for (const a of email.attachments ?? []) {
    const buf = toArrayBuffer(a.content);
    const size = buf?.byteLength ?? 0;
    const contentId = String(a.contentId ?? "").replace(/^<|>$/g, "");
    attachments.push({
      attachmentId: uid(),
      filename: a.filename || (contentId ? `inline-${contentId}` : `attachment-${attachments.length + 1}`),
      mimeType: a.mimeType || "application/octet-stream",
      size,
      contentId,
      isInline: a.disposition === "inline" || (!!contentId && a.disposition !== "attachment"),
      blob: buf && size <= MAX_BLOB ? buf : undefined,
    });
  }
  const messageId = String(email.messageId ?? headers["message-id"] ?? "").trim();
  const snippetSrc = (text || htmlToText(html)).replace(/\s+/g, " ").trim();
  return {
    gmailId: messageId || `inbound-${uid()}`,
    labelIds: ["UNREAD"],
    snippet: snippetSrc.slice(0, 200),
    internalDate: Number.isNaN(date) ? now() : date,
    sizeEstimate: 0,
    headers,
    from,
    to,
    cc: addrs(email.cc),
    bcc: addrs(email.bcc),
    replyTo: addrs(email.replyTo)[0]?.email ?? "",
    subject: String(email.subject ?? ""),
    date: Number.isNaN(date) ? now() : date,
    messageId,
    inReplyTo: String(email.inReplyTo ?? headers["in-reply-to"] ?? "").trim(),
    references: String(email.references ?? headers["references"] ?? "").trim(),
    listUnsubscribe: headers["list-unsubscribe"] ?? "",
    listId: headers["list-id"] ?? "",
    precedence: headers["precedence"] ?? "",
    autoSubmitted: headers["auto-submitted"] ?? "",
    text,
    html,
    attachments,
  };
}

/** Store an already-parsed inbound message into a mailbox (dedupes on Message-ID). */
export async function deliverInbound(env: Env, account: AccountRow, parsed: Omit<ParsedMessage, "threadId">, opts: IngestOptions = {}): Promise<{ added: number; threadIds: string[] }> {
  const db = env.DB;
  if (parsed.messageId) {
    const dup = await db.prepare(`SELECT id FROM messages WHERE account_id = ? AND (message_id_header = ? OR gmail_message_id = ?) LIMIT 1`).bind(account.id, parsed.messageId, parsed.gmailId).first();
    if (dup) return { added: 0, threadIds: [] };
  }
  const threadId = (await threadKeyFor(db, account.id, parsed.inReplyTo, parsed.references)) ?? uid();
  const full: ParsedMessage = { ...parsed, threadId };
  const r = await ingestParsed(env, account, [full], opts);
  await db.prepare(`UPDATE accounts SET last_synced_at = ? WHERE id = ?`).bind(now(), account.id).run();
  return r;
}

export async function handleInboundEmail(message: ForwardableEmailMessage, env: Env): Promise<void> {
  const db = env.DB;
  if (message.rawSize > MAX_RAW) {
    message.setReject("552 5.3.4 Message too large");
    return;
  }
  const mailbox = await resolveMailbox(db, message.to);
  if (!mailbox) {
    message.setReject("550 5.1.1 No such mailbox");
    return;
  }
  try {
    const parsed = await parseInbound(message.raw, message.from, message.to);
    const r = await deliverInbound(env, mailbox, parsed);
    await logSync(db, mailbox.id, "info", `Inbound from ${parsed.from.email}: ${r.added ? "stored" : "duplicate"} (${parsed.subject.slice(0, 80)})`);
  } catch (e) {
    await logSync(db, mailbox.id, "error", `Inbound failed from ${message.from}: ${(e as Error).message}`);
    message.setReject("451 4.3.0 Temporary failure, try again later");
  }
}
