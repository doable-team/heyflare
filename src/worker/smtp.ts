import { connect } from "cloudflare:sockets";

/**
 * A minimal SMTP submission client for Cloudflare Workers.
 *
 * Cloudflare blocks outbound port 25 outright, so this only ever speaks *submission*: 465 with
 * implicit TLS, or 587 upgraded with STARTTLS. Both were verified against a real server before this
 * was written; 465 is preferred because it needs no upgrade step.
 */

const enc = new TextEncoder();
const dec = new TextDecoder();

export type SmtpSecurity = "tls" | "starttls";

export interface SmtpConfig {
  host: string;
  port: number;
  security: SmtpSecurity;
  username: string;
  password: string;
}

export interface SmtpMessage {
  /** Envelope sender (MAIL FROM), bare address, no display name. */
  from: string;
  /** Every envelope recipient (RCPT TO) — To, Cc *and* Bcc. */
  recipients: string[];
  /** The full RFC822 message. Bcc must not appear in its headers. */
  raw: string;
}

export class SmtpError extends Error {
  code: number;
  /** True when the server rejected the credentials, which retrying cannot fix. */
  auth: boolean;
  constructor(code: number, message: string, opts: { auth?: boolean } = {}) {
    super(message);
    this.code = code;
    this.auth = opts.auth ?? false;
  }
}

const READ_TIMEOUT_MS = 15_000;

function timeout<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  return Promise.race([
    p,
    new Promise<T>((_, rej) => setTimeout(() => rej(new SmtpError(0, `smtp_timeout: ${what}`)), ms)),
  ]);
}

/** Reads whole SMTP replies, handling the multi-line `250-foo` / `250 bar` continuation form. */
class ReplyReader {
  private buf = "";
  constructor(private reader: ReadableStreamDefaultReader<Uint8Array>) {}

  async read(what: string): Promise<{ code: number; text: string }> {
    for (;;) {
      const complete = this.buf.split("\r\n").filter(Boolean).some((l) => /^\d{3} /.test(l));
      if (complete) break;
      const { value, done } = await timeout(this.reader.read(), READ_TIMEOUT_MS, what);
      if (done) throw new SmtpError(0, `smtp_closed: ${what}`);
      this.buf += dec.decode(value, { stream: true });
    }
    const text = this.buf;
    this.buf = "";
    const final = text.split("\r\n").filter(Boolean).find((l) => /^\d{3} /.test(l))!;
    return { code: parseInt(final.slice(0, 3), 10), text };
  }
}

/** Lines beginning with a dot must be escaped, or the server ends the message early (RFC 5321 §4.5.2). */
export function dotStuff(raw: string): string {
  return raw.replace(/\r\n\./g, "\r\n..").replace(/^\./, "..");
}

/**
 * Pick an AUTH mechanism the server actually offers. PLAIN is a single round trip and is preferred;
 * LOGIN is the fallback that older servers advertise instead.
 */
export function chooseAuth(ehlo: string): "PLAIN" | "LOGIN" | null {
  const line = ehlo.toUpperCase();
  const m = line.match(/^\d{3}[- ]AUTH[ =](.*)$/m);
  if (!m) return null;
  const mechs = m[1].split(/\s+/);
  if (mechs.includes("PLAIN")) return "PLAIN";
  if (mechs.includes("LOGIN")) return "LOGIN";
  return null;
}

function b64(s: string): string {
  return btoa(String.fromCharCode(...enc.encode(s)));
}

interface Session {
  send(line: string): Promise<void>;
  expect(want: number, what: string): Promise<{ code: number; text: string }>;
  writeRaw(data: string): Promise<void>;
  close(): Promise<void>;
}

/** Open the connection, upgrade it if needed, and log in. Shared by sending and by "Test connection". */
async function connectAndAuth(cfg: SmtpConfig): Promise<Session> {
  if (cfg.port === 25) throw new SmtpError(0, "smtp_port_25_blocked: Cloudflare blocks outbound port 25; use 465 or 587");

  let socket = connect(
    { hostname: cfg.host, port: cfg.port },
    { secureTransport: cfg.security === "tls" ? "on" : "starttls", allowHalfOpen: false }
  );
  let reader = socket.readable.getReader();
  let writer = socket.writable.getWriter();
  let replies = new ReplyReader(reader);

  const send = async (line: string) => {
    await writer.write(enc.encode(line + "\r\n"));
  };
  const expect = async (want: number, what: string) => {
    const r = await replies.read(what);
    if (r.code !== want) throw new SmtpError(r.code, `smtp_${what}_failed: ${r.text.trim().slice(0, 200)}`);
    return r;
  };
  const close = async () => {
    try {
      await socket.close();
    } catch {
      /* the server often closes first after QUIT */
    }
  };

  try {
    await expect(220, "greeting");
    await send(`EHLO heyflare`);
    let ehlo = (await expect(250, "ehlo")).text;

    if (cfg.security === "starttls") {
      if (!/STARTTLS/i.test(ehlo)) throw new SmtpError(0, "smtp_no_starttls: server does not offer STARTTLS");
      await send("STARTTLS");
      await expect(220, "starttls");
      // The pre-upgrade socket is finished once startTls() is called; everything continues on the
      // new one, so the old locks have to be released first.
      reader.releaseLock();
      writer.releaseLock();
      socket = socket.startTls();
      reader = socket.readable.getReader();
      writer = socket.writable.getWriter();
      replies = new ReplyReader(reader);
      await send(`EHLO heyflare`);
      ehlo = (await expect(250, "ehlo_tls")).text;
    }

    const mech = chooseAuth(ehlo);
    if (!mech) throw new SmtpError(0, "smtp_no_auth_method: server offers neither PLAIN nor LOGIN");
    if (mech === "PLAIN") {
      await send(`AUTH PLAIN ${b64(`\0${cfg.username}\0${cfg.password}`)}`);
    } else {
      await send("AUTH LOGIN");
      await expect(334, "auth_login");
      await send(b64(cfg.username));
      await expect(334, "auth_user");
      await send(b64(cfg.password));
    }
    try {
      await expect(235, "auth");
    } catch (e) {
      // 535 and friends mean the credentials are wrong; polling again will not help.
      if (e instanceof SmtpError && e.code >= 500) throw new SmtpError(e.code, e.message, { auth: true });
      throw e;
    }
  } catch (e) {
    await close();
    throw e;
  }

  return {
    send,
    expect,
    writeRaw: async (data: string) => {
      await writer.write(enc.encode(data));
    },
    close,
  };
}

export async function smtpSend(cfg: SmtpConfig, msg: SmtpMessage): Promise<void> {
  if (!msg.recipients.length) throw new SmtpError(0, "smtp_no_recipients");
  const s = await connectAndAuth(cfg);
  try {
    await s.send(`MAIL FROM:<${msg.from}>`);
    await s.expect(250, "mail_from");
    for (const rcpt of msg.recipients) {
      await s.send(`RCPT TO:<${rcpt}>`);
      await s.expect(250, "rcpt_to");
    }
    await s.send("DATA");
    await s.expect(354, "data");
    await s.writeRaw(dotStuff(msg.raw) + "\r\n.\r\n");
    await s.expect(250, "message");
    await s.send("QUIT");
  } finally {
    await s.close();
  }
}

/** Connect, upgrade and log in, then hang up — what the "Test connection" button runs. */
export async function smtpVerify(cfg: SmtpConfig): Promise<void> {
  const s = await connectAndAuth(cfg);
  try {
    await s.send("QUIT");
  } finally {
    await s.close();
  }
}
