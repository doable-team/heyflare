import type { Env } from "./env";
import type { AccountRow } from "./db";
import { now, logSync } from "./db";
import { encryptSecret, decryptSecret } from "./ai/crypto";
import { getSessionSecret } from "./secrets";
import { imapFetchNew, imapVerify, type ImapConfig, type ImapSecurity } from "./imap";
import { smtpSend, smtpVerify, type SmtpConfig, type SmtpSecurity } from "./smtp";
import { parseInbound, deliverInbound } from "./inbound";

/** Bodies are fetched one at a time, so this is the real cost ceiling for a cron tick. */
const MAX_MESSAGES_PER_RUN = 25;

export interface ImapAccountRow {
  account_id: string;
  imap_host: string;
  imap_port: number;
  imap_security: ImapSecurity;
  smtp_host: string;
  smtp_port: number;
  smtp_security: SmtpSecurity;
  username: string;
  password_enc: string;
  password_hint: string;
  folder: string;
  uid_validity: number;
  last_uid: number;
  updated_at: number;
}

export async function loadImapRow(env: Env, accountId: string): Promise<ImapAccountRow | null> {
  return (
    (await env.DB.prepare(`SELECT * FROM imap_accounts WHERE account_id = ?`).bind(accountId).first<ImapAccountRow>()) ?? null
  );
}

/** Mask a password for display. The plaintext never leaves the worker. */
export function passwordHint(password: string): string {
  return password.length > 4 ? `${"•".repeat(Math.min(8, password.length - 2))}${password.slice(-2)}` : "••••";
}

export async function encryptPassword(env: Env, password: string): Promise<string> {
  return encryptSecret(await getSessionSecret(env), password);
}

async function credentials(env: Env, row: ImapAccountRow): Promise<{ imap: ImapConfig; smtp: SmtpConfig }> {
  const password = row.password_enc ? await decryptSecret(await getSessionSecret(env), row.password_enc) : "";
  return {
    imap: {
      host: row.imap_host,
      port: row.imap_port,
      security: row.imap_security,
      username: row.username,
      password,
    },
    smtp: {
      host: row.smtp_host,
      port: row.smtp_port,
      security: row.smtp_security,
      username: row.username,
      password,
    },
  };
}

export async function configFor(env: Env, accountId: string): Promise<{ imap: ImapConfig; smtp: SmtpConfig } | null> {
  const row = await loadImapRow(env, accountId);
  return row ? credentials(env, row) : null;
}

/** Connect and log in to both servers — what "Test connection" runs before anything is saved. */
export async function verifyBoth(cfg: { imap: ImapConfig; smtp: SmtpConfig }): Promise<void> {
  await imapVerify(cfg.imap);
  await smtpVerify(cfg.smtp);
}

/**
 * One incremental pass over an IMAP mailbox.
 *
 * The cursor is (UIDVALIDITY, last UID). A server that renumbers the folder changes UIDVALIDITY,
 * which invalidates every stored UID — that case re-baselines to the current end of the folder
 * rather than re-importing the whole history, the same choice the Gmail and Outlook paths make.
 */
export async function syncImapAccount(env: Env, account: AccountRow): Promise<{ added: number }> {
  const db = env.DB;
  const row = await loadImapRow(env, account.id);
  if (!row) return { added: 0 };
  const cfg = await credentials(env, row);

  const result = await imapFetchNew(
    cfg.imap,
    row.folder,
    { uidValidity: row.uid_validity, lastUid: row.last_uid },
    MAX_MESSAGES_PER_RUN
  );

  if (result.reset) {
    await logSync(db, account.id, "warn", `IMAP folder was renumbered (UIDVALIDITY changed); re-syncing from now`);
  }

  let added = 0;
  for (const msg of result.messages) {
    const parsed = await parseInbound(msg.raw.buffer as ArrayBuffer, "", account.email);
    const r = await deliverInbound(env, account, parsed);
    added += r.added;
  }

  // Only now, with every message safely ingested, does the cursor move. A throw above leaves it
  // where it was and the next tick replays — which is safe, because ingest is idempotent.
  await db
    .prepare(`UPDATE imap_accounts SET uid_validity = ?, last_uid = ?, updated_at = ? WHERE account_id = ?`)
    .bind(result.uidValidity, result.lastUid, now(), account.id)
    .run();
  await db.prepare(`UPDATE accounts SET initial_sync_done = 1, last_synced_at = ? WHERE id = ?`).bind(now(), account.id).run();
  return { added };
}

/** Hand a finished RFC822 message to the mailbox's own SMTP server. */
export async function sendViaImapAccount(
  env: Env,
  account: AccountRow,
  msg: { from: string; recipients: string[]; raw: string }
): Promise<void> {
  const cfg = await configFor(env, account.id);
  if (!cfg) throw new Error("smtp_not_configured");
  await smtpSend(cfg.smtp, msg);
}
