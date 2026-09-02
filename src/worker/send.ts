import type { Env } from "./env";
import type { AccountRow, MessageRow, ThreadRow } from "./db";
import { now, safeJson } from "./db";
import { gmailJson, gmailPost } from "./google";
import { buildRawMime, type GmailMessage, type OutgoingAttachment } from "./mime";
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
  if (account.provider === "domain") {
    return sendFromDomainMailbox(env, account, p, { thread, replyTo, subject, inReplyTo, references, from });
  }
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

async function sendFromDomainMailbox(env: Env, account: AccountRow, p: SendParams, ctx: DomainSendCtx): Promise<{ thread_id: string; message_id: string }> {
  const db = env.DB;
  const domain = account.email.split("@")[1] || "localhost";
  const messageId = `<${uid()}@${domain}>`;
  const text = htmlToText(p.body_html);
  const headers: Record<string, string> = { "Message-ID": messageId };
  if (ctx.inReplyTo) headers["In-Reply-To"] = ctx.inReplyTo;
  if (ctx.references) headers["References"] = ctx.references;
  const to = p.to.map(fmt);
  const cc = (p.cc ?? []).map(fmt);
  const bcc = (p.bcc ?? []).map(fmt);

  if (env.EMAIL && typeof env.EMAIL.send === "function") {
    await env.EMAIL.send({
      from: fmt(ctx.from),
      to,
      cc: cc.length ? cc : undefined,
      bcc: bcc.length ? bcc : undefined,
      subject: ctx.subject,
      html: p.body_html,
      text,
      headers,
      attachments: (p.attachments ?? []).map((a) => ({ filename: a.filename, type: a.mime_type, content: a.data_base64, disposition: "attachment" })),
    });
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

  // Store the sent message locally so it shows up immediately.
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
