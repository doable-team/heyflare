import { env } from "cloudflare:test";
import { ensureMigrations } from "../src/worker/migrations";
import type { Env } from "../src/worker/env";
import type { AccountRow } from "../src/worker/db";

export const testEnv = env as unknown as Env;

/** Apply every migration once per worker, exactly as the Worker itself does on first request. */
export async function migrate(): Promise<void> {
  await ensureMigrations(testEnv);
}

/** Wipe the tables a mail test touches, so each test starts from a known-empty mailbox. */
export async function resetData(): Promise<void> {
  const db = testEnv.DB;
  for (const t of ["messages", "threads", "contacts", "attachments", "attachment_blobs", "sync_log", "accounts", "users"]) {
    await db.prepare(`DELETE FROM ${t}`).run();
  }
}

export async function seedUser(id = "u1"): Promise<void> {
  await testEnv.DB.prepare(`INSERT INTO users (id, email, name, password_hash, created_at) VALUES (?, ?, '', 'x', ?)`)
    .bind(id, `${id}@test.local`, Date.now())
    .run();
}

export async function seedOutlookAccount(overrides: Partial<AccountRow> = {}): Promise<AccountRow> {
  const id = (overrides.id as string) ?? "acc1";
  await testEnv.DB.prepare(
    `INSERT INTO accounts (id, user_id, provider, email, display_name, access_token, refresh_token, token_expires_at,
       scopes, history_id, delta_link, initial_sync_done, initial_sync_page_token, initial_sync_count,
       sync_status, sync_error, last_synced_at, signature, cover_art, avatar_url, created_at)
     VALUES (?, 'u1', 'outlook', ?, 'Me', 'tok', 'rtok', ?, 'Mail.ReadWrite Mail.Send', NULL, ?, ?, NULL, 0, 'idle', NULL, NULL, '', '', '', ?)`
  )
    .bind(
      id,
      (overrides.email as string) ?? "me@outlook.com",
      Date.now() + 3600_000,
      (overrides.delta_link as string | null) ?? null,
      overrides.initial_sync_done ?? 1,
      Date.now()
    )
    .run();
  return (await testEnv.DB.prepare(`SELECT * FROM accounts WHERE id = ?`).bind(id).first<AccountRow>())!;
}

/** A minimal but realistic inbound message, as Graph's `/$value` would return it. */
export function rawMime(opts: { from?: string; subject?: string; messageId?: string; inReplyTo?: string } = {}): string {
  const { from = "Someone <someone@example.com>", subject = "Hello there", messageId = "<m1@example.com>", inReplyTo } = opts;
  return [
    `From: ${from}`,
    `To: Me <me@outlook.com>`,
    `Subject: ${subject}`,
    `Message-ID: ${messageId}`,
    ...(inReplyTo ? [`In-Reply-To: ${inReplyTo}`, `References: ${inReplyTo}`] : []),
    `Date: ${new Date().toUTCString()}`,
    `MIME-Version: 1.0`,
    `Content-Type: text/plain; charset="UTF-8"`,
    ``,
    `Body of the message.`,
    ``,
  ].join("\r\n");
}
