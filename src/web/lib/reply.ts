import type { Address, Message, ThreadDetail } from "@shared/types";
import type { ComposerInitial } from "../components/Composer";
import { escapeHtml, fmtFull, textToHtml } from "../lib/format";

/**
 * What a reply, reply-all or forward starts from. Shared by the desktop and mobile thread screens —
 * it lived in the desktop page, which meant a phone downloaded that whole page to compose a reply.
 */
export type ReplyMode = "reply" | "replyAll" | "forward";

export function replyInitial(thread: ThreadDetail, m: Message, mode: ReplyMode, myEmail?: string): ComposerInitial {
  const me = (myEmail ?? "").toLowerCase();
  const quoted = `<div>On ${fmtFull(m.date)}, ${escapeHtml(m.from.name || m.from.email)} &lt;${escapeHtml(m.from.email)}&gt; wrote:</div>${m.html_body || textToHtml(m.text_body)}`;
  const subj = thread.original_subject || thread.subject || m.subject;
  if (mode === "forward") {
    const header = `<div>---------- Forwarded message ----------<br>From: ${escapeHtml(m.from.name)} &lt;${escapeHtml(m.from.email)}&gt;<br>Date: ${fmtFull(m.date)}<br>Subject: ${escapeHtml(m.subject)}<br>To: ${escapeHtml(m.to.map((a) => a.email).join(", "))}</div><br>`;
    return { account_id: thread.account_id, thread_id: null, reply_to_message_id: null, subject: /^fwd?:/i.test(subj) ? subj : `Fwd: ${subj}`, body_html: "", quoted_html: header + (m.html_body || textToHtml(m.text_body)), title: "Forward" };
  }
  const replyTo: Address = m.reply_to ? { email: m.reply_to.toLowerCase(), name: m.from.name } : m.from;
  let to: Address[] = m.is_from_me ? m.to : [replyTo];
  let cc: Address[] = [];
  if (mode === "replyAll") {
    const seen = new Set(to.map((a) => a.email));
    const extra = [...m.to, ...m.cc].filter((a) => a.email.toLowerCase() !== me && !seen.has(a.email));
    cc = extra.filter((a, i) => extra.findIndex((b) => b.email === a.email) === i);
  }
  to = to.filter((a) => a.email.toLowerCase() !== me || m.is_from_me);
  return { account_id: thread.account_id, thread_id: thread.id, reply_to_message_id: m.id, to, cc, subject: /^re:/i.test(subj) ? subj : `Re: ${subj}`, body_html: "", quoted_html: quoted, title: mode === "replyAll" ? "Reply all" : "Reply" };
}
