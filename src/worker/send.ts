import type { Env } from "./env";
import type { AccountRow, MessageRow, ThreadRow } from "./db";
import { now, safeJson } from "./db";
import { gmailJson, gmailPost } from "./google";
import { buildRawMime, buildMimeBase64, type GmailMessage, type OutgoingAttachment } from "./mime";
import { graphFetch, MicrosoftError } from "./microsoft";
import { htmlToText } from "./sanitize";
import { ingestMessages, ingestParsed } from "./sync";
import { uid } from "./db";
import type { Address } from "@shared/types";
import type { ParsedMessage } from "./mime";

export interface SendParams {
  thread_id?: string | null;
  reply_to_message_id?: string | null;
  to: Address[];
  cc?: Address[];
  bcc?: Address[];
  subject: string;
  body_html: string;
  attachments?: OutgoingAttachment[];
}

export async function sendMail(env: Env, account: AccountRow, p: SendParams): Promise<{ thread_id: string; message_id: string }> {
  const db = env.DB;
  let thread: ThreadRow | null = null;
  let replyTo: MessageRow | null = null;
  if (p.thread_id) {
    thread = await db.prepare(`SELECT * FROM threads WHERE id = ? AND account_id = ?`).bind(p.thread_id, account.id).first<ThreadRow>();
    if (!thread) throw new Error("thread_not_found");
    if (p.reply_to_message_id) {
      replyTo = await db.prepare(`SELECT * FROM messages WHERE id = ? AND account_id = ?`).bind(p.reply_to_message_id, account.id).first<MessageRow>();
    }
    if (!replyTo) {
      replyTo = await db
        .prepare(`SELECT * FROM messages WHERE thread_id = ? AND account_id = ? ORDER BY date DESC LIMIT 1`)
        .bind(thread.id, account.id)
        .first<MessageRow>();
    }
  }
  let subject = (p.subject ?? "").trim();
  if (!subject && thread) subject = `Re: ${thread.subject}`;
  let inReplyTo = "";
  let references = "";
  if (replyTo) {
    inReplyTo = replyTo.message_id_header;
    references = [replyTo.references_header, replyTo.message_id_header].filter(Boolean).join(" ");
  }
  const from: Address = { email: account.email, name: account.display_name };
  const ctx: DomainSendCtx = { thread, replyTo, subject, inReplyTo, references, from };
  if (account.provider === "domain") return sendFromDomainMailbox(env, account, p, ctx);
  if (account.provider === "outlook") return sendFromOutlook(env, account, p, ctx);
  const raw = buildRawMime({
    from,
    to: p.to,
    cc: p.cc ?? [],
    bcc: p.bcc ?? [],
    subject,
    html: p.body_html,
    text: htmlToText(p.body_html),
    inReplyTo,
    references,
    attachments: p.attachments ?? [],
  });
  const body: Record<string, string> = { raw };
  if (thread) body.threadId = thread.gmail_thread_id;
  const sent = await gmailPost<{ id: string; threadId: string }>(env, account, `messages/send`, body);

  // Pull the sent message back so it appears locally right away.
  let localThreadId = thread?.id ?? "";
  let localMessageId = "";
  try {
    const full = await gmailJson<GmailMessage>(env, account, `messages/${sent.id}?format=full`);
    await ingestMessages(env, account, [full]);
    const row = await db
      .prepare(`SELECT id, thread_id FROM messages WHERE account_id = ? AND gmail_message_id = ?`)
      .bind(account.id, sent.id)
      .first<{ id: string; thread_id: string }>();
    if (row) {
      localMessageId = row.id;
      localThreadId = row.thread_id;
    }
  } catch {
    // The cron sync will pick it up.
  }
  if (localThreadId) {
    await db
      .prepare(`UPDATE threads SET reply_later = 0, reply_later_at = NULL, seen = 1, unread = 0, updated_at = ? WHERE id = ? AND account_id = ?`)
      .bind(now(), localThreadId, account.id)
      .run();
  }
  return { thread_id: localThreadId, message_id: localMessageId };
}

// ---------- Custom-domain mailboxes: Cloudflare Email Sending or Resend ----------
interface DomainSendCtx {
  thread: ThreadRow | null;
  replyTo: MessageRow | null;
  subject: string;
  inReplyTo: string;
  references: string;
  from: Address;
}

const fmt = (a: Address) => (a.name ? `${a.name.replace(/[<>"]/g, "")} <${a.email}>` : a.email);

/**
 * Cloudflare's Email Service takes an address as a plain string or as `{email, name}`. It does not
 * document the `Name <addr>` form, so say it the way the API asks rather than hoping its parser is
 * forgiving.
 */
const addr = (a: Address) => (a.name ? { email: a.email, name: a.name.replace(/[<>"]/g, "") } : { email: a.email });

/**
 * The headers Cloudflare will accept from us. Its allowlist is narrow and unforgiving: a header
 * that is not on it — or that it considers its own — fails the *whole* send rather than being
 * dropped. `Message-ID` is the one that matters here, because Cloudflare generates its own and
 * rejects ours with E_HEADER_NOT_ALLOWED; every message this app sent through the binding carried
 * one, so every one of them was refused. Threading headers are allowlisted and stay.
 */
const CF_ALLOWED_HEADERS = new Set(["in-reply-to", "references"]);
const cfHeaders = (h: Record<string, string>): Record<string, string> =>
  Object.fromEntries(Object.entries(h).filter(([k]) => CF_ALLOWED_HEADERS.has(k.toLowerCase()) || k.toLowerCase().startsWith("x-")));

/**
 * Cloudflare reports why it would not send as an `E_`-prefixed code. The codes worth translating
 * are the ones a person can act on — the domain is not set up, or the recipient is not allowed —
 * because otherwise the failure reads as though the app is broken when the account is not finished.
 */
function cloudflareSendReason(e: unknown): string {
  const raw = (e as Error)?.message ?? String(e);
  const code = /E_[A-Z_]+/.exec(raw)?.[0] ?? "";
  const said: Record<string, string> = {
    E_SENDER_DOMAIN_NOT_AVAILABLE: "that domain isn't onboarded to Cloudflare Email Sending yet",
    E_SENDER_NOT_VERIFIED: "that sending domain isn't verified with Cloudflare yet",
    E_RECIPIENT_NOT_ALLOWED: "Cloudflare won't deliver to that recipient from this domain yet",
    E_RECIPIENT_SUPPRESSED: "that recipient is on Cloudflare's suppression list",
    E_HEADER_NOT_ALLOWED: "Cloudflare rejected one of the message headers",
    E_DAILY_LIMIT_EXCEEDED: "the daily send limit for this domain has been reached",
    E_RATE_LIMIT_EXCEEDED: "Cloudflare is rate limiting sends from this domain",
    E_CONTENT_TOO_LARGE: "the message is larger than Cloudflare will accept",
  };
  return said[code] ? `${said[code]} (${code})` : raw.slice(0, 300);
}

async function sendFromDomainMailbox(env: Env, account: AccountRow, p: SendParams, ctx: DomainSendCtx): Promise<{ thread_id: string; message_id: string }> {
  const db = env.DB;
  const domain = account.email.split("@")[1] || "localhost";
  // Ours until a provider tells us otherwise. Cloudflare stamps its own Message-ID and will not
  // accept one from us, so the copy we keep has to adopt whatever it used — the reply that comes
  // back will quote that, and threading matches on it.
  let messageId = `<${uid()}@${domain}>`;
  const text = htmlToText(p.body_html);
  const headers: Record<string, string> = { "Message-ID": messageId };
  if (ctx.inReplyTo) headers["In-Reply-To"] = ctx.inReplyTo;
  if (ctx.references) headers["References"] = ctx.references;
  const to = p.to.map(fmt);
  const cc = (p.cc ?? []).map(fmt);
  const bcc = (p.bcc ?? []).map(fmt);

  if (env.EMAIL && typeof env.EMAIL.send === "function") {
    try {
      const sent = await env.EMAIL.send({
        from: addr(ctx.from),
        to: p.to.map(addr),
        cc: cc.length ? (p.cc ?? []).map(addr) : undefined,
        bcc: bcc.length ? (p.bcc ?? []).map(addr) : undefined,
        subject: ctx.subject,
        html: p.body_html,
        text,
        headers: cfHeaders(headers),
        attachments: (p.attachments ?? []).map((a) => ({ filename: a.filename, type: a.mime_type, content: a.data_base64, disposition: "attachment" })),
      });
      // Only if it really looks like a Message-ID; the field is documented only as a "unique email
      // ID", so anything that is not an addr-spec is a tracking handle and no use for threading.
      const given = (sent as { messageId?: string } | undefined)?.messageId?.trim();
      if (given && given.includes("@")) messageId = given.startsWith("<") ? given : `<${given}>`;
    } catch (e) {
      throw new Error(`cloudflare_send_failed: ${cloudflareSendReason(e)}`);
    }
  } else if (env.RESEND_API_KEY) {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { authorization: `Bearer ${env.RESEND_API_KEY}`, "content-type": "application/json" },
      body: JSON.stringify({
        from: fmt(ctx.from),
        to,
        cc: cc.length ? cc : undefined,
        bcc: bcc.length ? bcc : undefined,
        subject: ctx.subject,
        html: p.body_html,
        text,
        headers,
        attachments: (p.attachments ?? []).map((a) => ({ filename: a.filename, content: a.data_base64 })),
      }),
    });
    if (!res.ok) throw new Error(`resend_failed: ${(await res.text()).slice(0, 300)}`);
  } else {
    throw new Error("sending_not_configured");
  }

  return recordSentMessage(env, account, p, ctx, messageId, text);
}

/**
 * Store a message we just handed to a transport that gives us nothing to read back (Cloudflare Email
 * Sending, Resend, Graph `sendMail`), so it appears in the thread immediately. The Gmail path instead
 * re-fetches the real message by id.
 */
async function recordSentMessage(
  env: Env,
  account: AccountRow,
  p: SendParams,
  ctx: DomainSendCtx,
  messageId: string,
  text: string
): Promise<{ thread_id: string; message_id: string }> {
  const db = env.DB;
  const t = now();
  const parsed: ParsedMessage = {
    gmailId: messageId,
    threadId: ctx.thread?.gmail_thread_id ?? uid(),
    labelIds: ["SENT"],
    snippet: text.replace(/\s+/g, " ").trim().slice(0, 200),
    internalDate: t,
    sizeEstimate: p.body_html.length,
    headers: {},
    from: ctx.from,
    to: p.to,
    cc: p.cc ?? [],
    bcc: p.bcc ?? [],
    replyTo: "",
    subject: ctx.subject,
    date: t,
    messageId,
    inReplyTo: ctx.inReplyTo,
    references: ctx.references,
    listUnsubscribe: "",
    listId: "",
    precedence: "",
    autoSubmitted: "",
    text,
    html: p.body_html,
    attachments: [],
  };
  await ingestParsed(env, account, [parsed]);
  const row = await db.prepare(`SELECT id, thread_id FROM messages WHERE account_id = ? AND gmail_message_id = ?`).bind(account.id, messageId).first<{ id: string; thread_id: string }>();
  const localThreadId = row?.thread_id ?? ctx.thread?.id ?? "";
  if (localThreadId) {
    await db
      .prepare(`UPDATE threads SET reply_later = 0, reply_later_at = NULL, seen = 1, unread = 0, updated_at = ? WHERE id = ? AND account_id = ?`)
      .bind(now(), localThreadId, account.id)
      .run();
  }
  return { thread_id: localThreadId, message_id: row?.id ?? "" };
}

// ---------- Outlook: Microsoft Graph ----------

/**
 * Graph accepts a whole RFC822 message as base64 with `Content-Type: text/plain`, derives the
 * envelope from the headers (Bcc included, which it strips before delivery) and files the result in
 * Sent Items itself — the same end state Gmail sending reaches. It answers 202 with an empty body,
 * so there is nothing to read back and we record the message locally instead.
 */
async function sendFromOutlook(env: Env, account: AccountRow, p: SendParams, ctx: DomainSendCtx): Promise<{ thread_id: string; message_id: string }> {
  const domain = account.email.split("@")[1] || "outlook.com";
  const messageId = `<${uid()}@${domain}>`;
  const text = htmlToText(p.body_html);
  const mime = buildMimeBase64({
    from: ctx.from,
    to: p.to,
    cc: p.cc ?? [],
    bcc: p.bcc ?? [],
    subject: ctx.subject,
    html: p.body_html,
    text,
    inReplyTo: ctx.inReplyTo,
    references: ctx.references,
    attachments: p.attachments ?? [],
    messageId,
  });
  const res = await graphFetch(env, account, "sendMail", {
    method: "POST",
    headers: { "content-type": "text/plain" },
    body: mime,
  });
  if (!res.ok) {
    const body = await res.text();
    throw new MicrosoftError(res.status, body, `outlook_send_failed: ${body.slice(0, 300)}`);
  }
  return recordSentMessage(env, account, p, ctx, messageId, text);
}

export async function processScheduledSends(env: Env): Promise<number> {
  const db = env.DB;
  const t = now();
  const due = await db
    .prepare(`SELECT d.*, a.id AS acc_id FROM drafts d JOIN accounts a ON a.id = d.account_id WHERE d.status = 'scheduled' AND d.send_at IS NOT NULL AND d.send_at <= ? LIMIT 10`)
    .bind(t)
    .all<any>();
  let sent = 0;
  for (const d of due.results) {
    const claimed = await db.prepare(`UPDATE drafts SET status = 'sending', updated_at = ? WHERE id = ? AND status = 'scheduled'`).bind(t, d.id).run();
    if (!claimed.meta.changes) continue;
    const account = await db.prepare(`SELECT * FROM accounts WHERE id = ?`).bind(d.account_id).first<AccountRow>();
    if (!account) continue;
    try {
      await sendMail(env, account, {
        thread_id: d.thread_id,
        reply_to_message_id: d.reply_to_message_id,
        to: safeJson<Address[]>(d.to_json, []),
        cc: safeJson<Address[]>(d.cc_json, []),
        bcc: safeJson<Address[]>(d.bcc_json, []),
        subject: d.subject,
        body_html: d.body_html,
      });
      await db.prepare(`DELETE FROM drafts WHERE id = ?`).bind(d.id).run();
      sent++;
    } catch (e) {
      await db
        .prepare(`UPDATE drafts SET status = 'failed', error = ?, updated_at = ? WHERE id = ?`)
        .bind(((e as Error).message ?? "send failed").slice(0, 1000), now(), d.id)
        .run();
    }
  }
  return sent;
}
