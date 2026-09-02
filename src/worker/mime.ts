import { Buffer } from "node:buffer";
import type { Address } from "@shared/types";

// ---------- Gmail API payload types (minimal) ----------
export interface GmailHeader {
  name: string;
  value: string;
}
export interface GmailPart {
  partId?: string;
  mimeType?: string;
  filename?: string;
  headers?: GmailHeader[];
  body?: { size?: number; data?: string; attachmentId?: string };
  parts?: GmailPart[];
}
export interface GmailMessage {
  id: string;
  threadId: string;
  labelIds?: string[];
  snippet?: string;
  historyId?: string;
  internalDate?: string;
  sizeEstimate?: number;
  payload?: GmailPart;
}

export interface ParsedAttachment {
  attachmentId: string;
  filename: string;
  mimeType: string;
  size: number;
  contentId: string;
  isInline: boolean;
  /** Raw bytes, when the message arrived through the inbound email handler (stored in attachment_blobs). */
  blob?: ArrayBuffer;
}

export interface ParsedMessage {
  gmailId: string;
  threadId: string;
  labelIds: string[];
  snippet: string;
  internalDate: number;
  sizeEstimate: number;
  headers: Record<string, string>;
  from: Address;
  to: Address[];
  cc: Address[];
  bcc: Address[];
  replyTo: string;
  subject: string;
  date: number;
  messageId: string;
  inReplyTo: string;
  references: string;
  listUnsubscribe: string;
  listId: string;
  precedence: string;
  autoSubmitted: string;
  text: string;
  html: string;
  attachments: ParsedAttachment[];
}

// ---------- base64 helpers ----------
export function b64urlDecodeBytes(data: string): Uint8Array {
  return new Uint8Array(Buffer.from(data, "base64url"));
}
export function b64urlEncodeBytes(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}
export function b64Encode(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64");
}

function decodeText(data: string | undefined, charset?: string): string {
  if (!data) return "";
  const bytes = b64urlDecodeBytes(data);
  const cs = (charset ?? "utf-8").toLowerCase().replace(/["']/g, "");
  try {
    return new TextDecoder(cs).decode(bytes);
  } catch {
    try {
      return new TextDecoder("utf-8").decode(bytes);
    } catch {
      return Buffer.from(bytes).toString("latin1");
    }
  }
}

function headerOf(part: GmailPart | undefined, name: string): string {
  if (!part?.headers) return "";
  const lower = name.toLowerCase();
  const h = part.headers.find((x) => x.name.toLowerCase() === lower);
  return h?.value ?? "";
}

function charsetOf(part: GmailPart): string | undefined {
  const ct = headerOf(part, "Content-Type");
  const m = ct.match(/charset\s*=\s*"?([^";\s]+)"?/i);
  return m?.[1];
}

// ---------- RFC 2047 decode (for names/subjects that Gmail didn't decode; usually already decoded) ----------
export function decodeRfc2047(s: string): string {
  if (!s || !/=\?[^?]+\?[BbQq]\?[^?]*\?=/.test(s)) return s;
  return s.replace(/=\?([^?]+)\?([BbQq])\?([^?]*)\?=/g, (_m, cs: string, enc: string, txt: string) => {
    try {
      if (enc.toUpperCase() === "B") {
        return new TextDecoder(cs.toLowerCase()).decode(Buffer.from(txt, "base64"));
      }
      const bytes: number[] = [];
      for (let i = 0; i < txt.length; i++) {
        const ch = txt[i];
        if (ch === "_") bytes.push(32);
        else if (ch === "=" && i + 2 < txt.length + 1) {
          bytes.push(parseInt(txt.substr(i + 1, 2), 16));
          i += 2;
        } else bytes.push(ch.charCodeAt(0));
      }
      return new TextDecoder(cs.toLowerCase()).decode(new Uint8Array(bytes));
    } catch {
      return txt;
    }
  });
}

// ---------- Address parsing ----------
export function parseAddressList(input: string): Address[] {
  const out: Address[] = [];
  if (!input) return out;
  const s = decodeRfc2047(input);
  // Split on commas that are outside quotes and angle brackets.
  const items: string[] = [];
  let cur = "";
  let inQuote = false;
  let depth = 0;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === '"' && s[i - 1] !== "\\") inQuote = !inQuote;
    else if (!inQuote && ch === "<") depth++;
    else if (!inQuote && ch === ">") depth = Math.max(0, depth - 1);
    if (ch === "," && !inQuote && depth === 0) {
      items.push(cur);
      cur = "";
    } else cur += ch;
  }
  if (cur.trim()) items.push(cur);
  for (const raw of items) {
    const item = raw.trim();
    if (!item) continue;
    const m = item.match(/^(.*?)<([^>]+)>\s*$/);
    let name = "";
    let email = "";
    if (m) {
      name = m[1].trim();
      email = m[2].trim();
    } else {
      email = item.replace(/^mailto:/i, "").trim();
    }
    name = name.replace(/^"(.*)"$/, "$1").replace(/\\"/g, '"').trim();
    email = email.toLowerCase().replace(/^<|>$/g, "");
    if (!email) continue;
    out.push({ email, name });
  }
  return out;
}

export function parseAddress(input: string): Address {
  return parseAddressList(input)[0] ?? { email: "", name: "" };
}

// ---------- Parse a Gmail message (format=full) ----------
export function parseGmailMessage(msg: GmailMessage): ParsedMessage {
  const payload = msg.payload ?? {};
  const headers: Record<string, string> = {};
  for (const h of payload.headers ?? []) headers[h.name.toLowerCase()] = h.value;

  let text = "";
  let html = "";
  const attachments: ParsedAttachment[] = [];

  const walk = (part: GmailPart, depth: number) => {
    const mime = (part.mimeType ?? "").toLowerCase();
    const filename = part.filename ?? "";
    const disposition = headerOf(part, "Content-Disposition").toLowerCase();
    const contentId = headerOf(part, "Content-ID").replace(/^<|>$/g, "");
    const isAttachmentLike = !!filename || disposition.startsWith("attachment") || !!part.body?.attachmentId;

    if (part.parts && part.parts.length) {
      // multipart/alternative: prefer html over text, but collect both when present.
      for (const p of part.parts) walk(p, depth + 1);
      return;
    }

    if (isAttachmentLike && (part.body?.attachmentId || filename)) {
      attachments.push({
        attachmentId: part.body?.attachmentId ?? "",
        filename: filename || (contentId ? `inline-${contentId}` : `attachment-${attachments.length + 1}`),
        mimeType: mime || "application/octet-stream",
        size: part.body?.size ?? 0,
        contentId,
        isInline: disposition.startsWith("inline") || (!!contentId && !disposition.startsWith("attachment")),
      });
      return;
    }

    if (mime === "text/plain" && !text) text = decodeText(part.body?.data, charsetOf(part));
    else if (mime === "text/html" && !html) html = decodeText(part.body?.data, charsetOf(part));
    else if (mime.startsWith("text/") && !text && !html) text = decodeText(part.body?.data, charsetOf(part));
  };
  walk(payload, 0);

  const from = parseAddress(headers["from"] ?? "");
  const dateHeader = headers["date"];
  let date = msg.internalDate ? parseInt(msg.internalDate, 10) : NaN;
  if (Number.isNaN(date)) date = dateHeader ? Date.parse(dateHeader) : Date.now();
  if (Number.isNaN(date)) date = Date.now();

  return {
    gmailId: msg.id,
    threadId: msg.threadId,
    labelIds: msg.labelIds ?? [],
    snippet: decodeHtmlEntities(msg.snippet ?? ""),
    internalDate: date,
    sizeEstimate: msg.sizeEstimate ?? 0,
    headers,
    from,
    to: parseAddressList(headers["to"] ?? ""),
    cc: parseAddressList(headers["cc"] ?? ""),
    bcc: parseAddressList(headers["bcc"] ?? ""),
    replyTo: parseAddress(headers["reply-to"] ?? "").email,
    subject: decodeRfc2047(headers["subject"] ?? ""),
    date,
    messageId: headers["message-id"] ?? "",
    inReplyTo: headers["in-reply-to"] ?? "",
    references: headers["references"] ?? "",
    listUnsubscribe: headers["list-unsubscribe"] ?? "",
    listId: headers["list-id"] ?? "",
    precedence: headers["precedence"] ?? "",
    autoSubmitted: headers["auto-submitted"] ?? "",
    text,
    html,
    attachments,
  };
}

function decodeHtmlEntities(s: string): string {
  return s
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#(\d+);/g, (_m, n) => String.fromCodePoint(parseInt(n, 10)));
}

export function stripSubjectPrefixes(subject: string): string {
  let s = (subject ?? "").trim();
  // Strip repeated Re:/Fwd:/FW:/AW:/SV: etc.
  for (;;) {
    const next = s.replace(/^((re|fwd?|fw|aw|sv|vs|tr|wg)\s*(\[\d+\])?\s*:\s*)/i, "").trim();
    if (next === s) break;
    s = next;
  }
  return s;
}

// ---------- Build raw MIME for sending ----------
export interface OutgoingAttachment {
  filename: string;
  mime_type: string;
  data_base64: string;
}

export interface BuildMimeParams {
  from: Address;
  to: Address[];
  cc?: Address[];
  bcc?: Address[];
  subject: string;
  html: string;
  text?: string;
  inReplyTo?: string;
  references?: string;
  attachments?: OutgoingAttachment[];
}

function isAscii(s: string): boolean {
  // eslint-disable-next-line no-control-regex
  return /^[\x00-\x7F]*$/.test(s);
}

function encodeHeaderWord(s: string): string {
  if (isAscii(s)) return s;
  return `=?UTF-8?B?${Buffer.from(s, "utf8").toString("base64")}?=`;
}

function formatAddress(a: Address): string {
  if (!a.name) return a.email;
  const name = isAscii(a.name) ? `"${a.name.replace(/"/g, '\\"')}"` : encodeHeaderWord(a.name);
  return `${name} <${a.email}>`;
}

function foldBase64(b64: string): string {
  return b64.replace(/(.{76})/g, "$1\r\n");
}

function randomBoundary(prefix: string): string {
  const arr = crypto.getRandomValues(new Uint8Array(12));
  return `${prefix}_${Array.from(arr, (b) => b.toString(16).padStart(2, "0")).join("")}`;
}

export function buildRawMime(p: BuildMimeParams): string {
  const CRLF = "\r\n";
  const lines: string[] = [];
  const msgId = `<${crypto.randomUUID()}@${p.from.email.split("@")[1] || "hey.local"}>`;
  lines.push(`From: ${formatAddress(p.from)}`);
  if (p.to.length) lines.push(`To: ${p.to.map(formatAddress).join(", ")}`);
  if (p.cc?.length) lines.push(`Cc: ${p.cc.map(formatAddress).join(", ")}`);
  if (p.bcc?.length) lines.push(`Bcc: ${p.bcc.map(formatAddress).join(", ")}`);
  lines.push(`Subject: ${encodeHeaderWord(p.subject ?? "")}`);
  lines.push(`Date: ${new Date().toUTCString()}`);
  lines.push(`Message-ID: ${msgId}`);
  if (p.inReplyTo) lines.push(`In-Reply-To: ${p.inReplyTo}`);
  if (p.references) lines.push(`References: ${p.references}`);
  lines.push(`MIME-Version: 1.0`);

  const text = p.text ?? "";
  const textPart = [
    `Content-Type: text/plain; charset="UTF-8"`,
    `Content-Transfer-Encoding: base64`,
    ``,
    foldBase64(Buffer.from(text, "utf8").toString("base64")),
  ].join(CRLF);
  const htmlPart = [
    `Content-Type: text/html; charset="UTF-8"`,
    `Content-Transfer-Encoding: base64`,
    ``,
    foldBase64(Buffer.from(p.html ?? "", "utf8").toString("base64")),
  ].join(CRLF);

  const altBoundary = randomBoundary("alt");
  const altBody = [
    `--${altBoundary}`,
    textPart,
    `--${altBoundary}`,
    htmlPart,
    `--${altBoundary}--`,
  ].join(CRLF);

  let body: string;
  if (p.attachments && p.attachments.length) {
    const mixBoundary = randomBoundary("mixed");
    lines.push(`Content-Type: multipart/mixed; boundary="${mixBoundary}"`);
    const parts: string[] = [];
    parts.push(`--${mixBoundary}`);
    parts.push(`Content-Type: multipart/alternative; boundary="${altBoundary}"`);
    parts.push(``);
    parts.push(altBody);
    for (const a of p.attachments) {
      const fname = encodeHeaderWord(a.filename || "attachment");
      parts.push(`--${mixBoundary}`);
      parts.push(`Content-Type: ${a.mime_type || "application/octet-stream"}; name="${fname}"`);
      parts.push(`Content-Disposition: attachment; filename="${fname}"`);
      parts.push(`Content-Transfer-Encoding: base64`);
      parts.push(``);
      parts.push(foldBase64(a.data_base64.replace(/\s+/g, "")));
    }
    parts.push(`--${mixBoundary}--`);
    body = parts.join(CRLF);
  } else {
    lines.push(`Content-Type: multipart/alternative; boundary="${altBoundary}"`);
    body = altBody;
  }

  const raw = lines.join(CRLF) + CRLF + CRLF + body + CRLF;
  return Buffer.from(raw, "utf8").toString("base64url");
}
