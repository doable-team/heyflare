import { connect } from "cloudflare:sockets";

/**
 * A minimal IMAP4rev1 client for Cloudflare Workers — enough to poll a folder for new mail.
 *
 * It reads bytes rather than text throughout: IMAP literals (`{1234}`) are counted in *octets*, and
 * a message body is arbitrary binary, so decoding early would corrupt both the framing and the mail.
 * Raw messages come back as bytes and go straight to postal-mime.
 */

const enc = new TextEncoder();
const dec = new TextDecoder();

export type ImapSecurity = "tls" | "starttls";

export interface ImapConfig {
  host: string;
  port: number;
  security: ImapSecurity;
  username: string;
  password: string;
}

export class ImapError extends Error {
  /** True when the server rejected the credentials, which retrying cannot fix. */
  auth: boolean;
  constructor(message: string, opts: { auth?: boolean } = {}) {
    super(message);
    this.auth = opts.auth ?? false;
  }
}

const READ_TIMEOUT_MS = 20_000;

function timeout<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  return Promise.race([p, new Promise<T>((_, rej) => setTimeout(() => rej(new ImapError(`imap_timeout: ${what}`)), ms))]);
}

/** A byte buffer over the socket that can hand back either a CRLF line or an exact octet count. */
class ByteReader {
  private buf = new Uint8Array(0);
  constructor(private reader: ReadableStreamDefaultReader<Uint8Array>) {}

  private append(chunk: Uint8Array) {
    const next = new Uint8Array(this.buf.length + chunk.length);
    next.set(this.buf, 0);
    next.set(chunk, this.buf.length);
    this.buf = next;
  }

  private async pull(what: string) {
    const { value, done } = await timeout(this.reader.read(), READ_TIMEOUT_MS, what);
    if (done || !value) throw new ImapError(`imap_closed: ${what}`);
    this.append(value);
  }

  /** One CRLF-terminated line, decoded as text, without the CRLF. */
  async line(what = "line"): Promise<string> {
    for (;;) {
      for (let i = 0; i + 1 < this.buf.length; i++) {
        if (this.buf[i] === 0x0d && this.buf[i + 1] === 0x0a) {
          const line = dec.decode(this.buf.subarray(0, i));
          this.buf = this.buf.subarray(i + 2);
          return line;
        }
      }
      await this.pull(what);
    }
  }

  /** Exactly `n` octets — the payload of an IMAP literal. */
  async bytes(n: number, what = "literal"): Promise<Uint8Array> {
    while (this.buf.length < n) await this.pull(what);
    const out = this.buf.slice(0, n);
    this.buf = this.buf.subarray(n);
    return out;
  }
}

/** A server line, with the literal that followed it (if any) already read. */
export interface ImapLine {
  text: string;
  literal?: Uint8Array;
}

/** `* 1 FETCH (UID 5 BODY[] {1234}` -> 1234. Only a trailing literal counts. */
export function literalSize(line: string): number | null {
  const m = line.match(/\{(\d+)\}$/);
  return m ? parseInt(m[1], 10) : null;
}

/** IMAP quoted-string: backslash and double-quote must be escaped. */
export function quote(s: string): string {
  return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

/** Pull UIDs out of an untagged SEARCH response. */
export function parseSearchUids(lines: string[]): number[] {
  const out: number[] = [];
  for (const l of lines) {
    const m = l.match(/^\*\s+SEARCH\b(.*)$/i);
    if (!m) continue;
    for (const tok of m[1].trim().split(/\s+/)) {
      const n = parseInt(tok, 10);
      if (Number.isFinite(n)) out.push(n);
    }
  }
  return out;
}

/** UIDVALIDITY and UIDNEXT out of the untagged responses to SELECT. */
export function parseSelect(lines: string[]): { uidValidity: number; uidNext: number; exists: number } {
  let uidValidity = 0;
  let uidNext = 0;
  let exists = 0;
  for (const l of lines) {
    const v = l.match(/\[UIDVALIDITY\s+(\d+)\]/i);
    if (v) uidValidity = parseInt(v[1], 10);
    const n = l.match(/\[UIDNEXT\s+(\d+)\]/i);
    if (n) uidNext = parseInt(n[1], 10);
    const e = l.match(/^\*\s+(\d+)\s+EXISTS/i);
    if (e) exists = parseInt(e[1], 10);
  }
  return { uidValidity, uidNext, exists };
}

/** The UID from a FETCH response line, which servers may order differently. */
export function parseFetchUid(line: string): number | null {
  const m = line.match(/\bUID\s+(\d+)/i);
  return m ? parseInt(m[1], 10) : null;
}

class ImapSession {
  private tag = 0;
  constructor(
    private reader: ByteReader,
    private writer: WritableStreamDefaultWriter<Uint8Array>
  ) {}

  /** Send a command and collect untagged lines until its tagged completion. */
  async run(command: string, what = command.split(" ")[0]): Promise<ImapLine[]> {
    const tag = `a${(++this.tag).toString().padStart(4, "0")}`;
    await this.writer.write(enc.encode(`${tag} ${command}\r\n`));
    const lines: ImapLine[] = [];
    for (;;) {
      const text = await this.reader.line(what);
      const size = literalSize(text);
      if (size !== null) {
        const literal = await this.reader.bytes(size, what);
        lines.push({ text, literal });
        continue;
      }
      if (text.startsWith(`${tag} `)) {
        const status = text.slice(tag.length + 1).trim();
        if (!/^OK\b/i.test(status)) throw new ImapError(`imap_${what}_failed: ${status.slice(0, 200)}`);
        return lines;
      }
      lines.push({ text });
    }
  }
}

export interface ImapCursor {
  /** Resets to 0 whenever the server renumbers the folder; that invalidates every stored UID. */
  uidValidity: number;
  lastUid: number;
}

export interface ImapFetchResult extends ImapCursor {
  messages: { uid: number; raw: Uint8Array }[];
  /** True when the folder was renumbered and the caller must not treat `messages` as incremental. */
  reset: boolean;
}

async function open(cfg: ImapConfig) {
  let socket = connect(
    { hostname: cfg.host, port: cfg.port },
    { secureTransport: cfg.security === "tls" ? "on" : "starttls", allowHalfOpen: false }
  );
  let reader = new ByteReader(socket.readable.getReader());
  let writer = socket.writable.getWriter();

  const greeting = await reader.line("greeting");
  if (!/^\*\s+(OK|PREAUTH)/i.test(greeting)) throw new ImapError(`imap_greeting_failed: ${greeting.slice(0, 200)}`);

  if (cfg.security === "starttls") {
    const pre = new ImapSession(reader, writer);
    await pre.run("STARTTLS", "starttls");
    // The pre-upgrade socket is finished; everything continues on the one startTls() returns.
    socket.readable.cancel().catch(() => {});
    writer.releaseLock();
    socket = socket.startTls();
    reader = new ByteReader(socket.readable.getReader());
    writer = socket.writable.getWriter();
  }

  const session = new ImapSession(reader, writer);
  try {
    await session.run(`LOGIN ${quote(cfg.username)} ${quote(cfg.password)}`, "login");
  } catch (e) {
    // Leaving the socket open here would leak a connection on every failed poll.
    try {
      await socket.close();
    } catch {
      /* already gone */
    }
    if (e instanceof ImapError && /login/.test(e.message)) throw new ImapError(e.message, { auth: true });
    throw e;
  }
  return { socket, session };
}

/** Connect and log in, then hang up — the "Test connection" button. */
export async function imapVerify(cfg: ImapConfig): Promise<void> {
  const { socket, session } = await open(cfg);
  try {
    await session.run("LOGOUT", "logout");
  } finally {
    try {
      await socket.close();
    } catch {
      /* the server usually closes first after LOGOUT */
    }
  }
}

/**
 * Fetch messages newer than `cursor.lastUid` from `folder`.
 *
 * When the server reports a different UIDVALIDITY every previously stored UID is meaningless, so the
 * result is flagged `reset` and the caller re-baselines rather than treating the batch as new mail.
 */
export async function imapFetchNew(
  cfg: ImapConfig,
  folder: string,
  cursor: ImapCursor,
  max = 25
): Promise<ImapFetchResult> {
  const { socket, session } = await open(cfg);
  try {
    const selected = parseSelect((await session.run(`SELECT ${quote(folder)}`, "select")).map((l) => l.text));
    // RFC 3501 requires UIDVALIDITY on SELECT. Without it every UID we store is meaningless — and
    // since 0 is also the "never baselined" marker, accepting it would re-baseline on every run and
    // the mailbox would stay silent forever instead of reporting a problem.
    if (!selected.uidValidity) {
      throw new ImapError(`imap_select_failed: ${folder} returned no UIDVALIDITY`);
    }
    const reset = cursor.uidValidity !== 0 && selected.uidValidity !== cursor.uidValidity;

    // A fresh mailbox, or one that was renumbered, only records where things stand — importing the
    // entire history into the Screener is never what anyone wants.
    if (cursor.uidValidity === 0 || reset) {
      return { uidValidity: selected.uidValidity, lastUid: Math.max(0, selected.uidNext - 1), messages: [], reset };
    }

    const from = cursor.lastUid + 1;
    const found = parseSearchUids((await session.run(`UID SEARCH UID ${from}:*`, "search")).map((l) => l.text));
    // `UID SEARCH n:*` always returns at least the highest UID even when nothing is that new.
    const uids = found.filter((u) => u >= from).sort((a, b) => a - b).slice(0, max);
    if (!uids.length) return { uidValidity: selected.uidValidity, lastUid: cursor.lastUid, messages: [], reset: false };

    const messages: { uid: number; raw: Uint8Array }[] = [];
    for (const uid of uids) {
      // BODY.PEEK leaves \Seen alone: reading here must not mark the mail read in the real mailbox.
      const lines = await session.run(`UID FETCH ${uid} (UID BODY.PEEK[])`, "fetch");
      const withBody = lines.find((l) => l.literal);
      if (!withBody?.literal) continue;
      messages.push({ uid: parseFetchUid(withBody.text) ?? uid, raw: withBody.literal });
    }

    const lastUid = messages.length ? Math.max(...messages.map((m) => m.uid)) : cursor.lastUid;
    await session.run("LOGOUT", "logout").catch(() => {});
    return { uidValidity: selected.uidValidity, lastUid, messages, reset: false };
  } finally {
    try {
      await socket.close();
    } catch {
      /* ignore */
    }
  }
}
