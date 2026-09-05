import type { Env } from "./env";
import type { AccountRow } from "./db";
import { now, logSync } from "./db";
import { graphJson, graphRaw, MicrosoftError } from "./microsoft";
import { parseInbound, deliverInbound } from "./inbound";

/** The inbox is the only folder we track: Sent, Drafts and Junk are not mail *arriving* for you. */
const INBOX_DELTA_PATH = `mailFolders/inbox/messages/delta?$select=id`;
/** Bodies are fetched one HTTP request each, so this is the real cost ceiling for a cron tick. */
const MAX_MESSAGES_PER_RUN = 25;
/** Bounds how much of a long delta chain one invocation will walk. */
const MAX_PAGES = 10;

interface DeltaRef {
  id?: string;
  "@removed"?: { reason?: string };
}

export interface DeltaPage {
  value?: DeltaRef[];
  "@odata.nextLink"?: string;
  "@odata.deltaLink"?: string;
}

/**
 * The ids on one delta page that represent a message we might not have yet.
 *
 * Delta tracking is collection-level, so a page also carries `@removed` tombstones and entries for
 * messages that merely changed read state. Both are dropped here: ingest is idempotent, but fetching
 * a full MIME body for a message we already stored is pure waste.
 */
export function newMessageIdsFromPage(page: DeltaPage): string[] {
  const out: string[] = [];
  for (const item of page.value ?? []) {
    if (item["@removed"]) continue;
    if (typeof item.id === "string" && item.id) out.push(item.id);
  }
  return out;
}

/** A delta cursor Graph will no longer accept: we must start the chain again. */
export function isExpiredCursor(e: unknown): boolean {
  return e instanceof MicrosoftError && (e.status === 410 || /resyncRequired|syncStateNotFound/i.test(e.body));
}

export interface DeltaWalk {
  ids: string[];
  /**
   * Where to resume. Graph hands back either an `@odata.nextLink` (more pages this round) or an
   * `@odata.deltaLink` (caught up), never both, and *either* can be stored and replayed later — so
   * one field covers both and the cursor always advances, even mid-chain.
   */
  cursor: string;
  /** True once the chain reached its `@odata.deltaLink`, i.e. we are level with the mailbox. */
  done: boolean;
}

export async function walkDelta(
  env: Env,
  account: AccountRow,
  startUrl: string,
  opts: { collect: boolean; maxIds?: number } = { collect: true }
): Promise<DeltaWalk> {
  const maxIds = opts.maxIds ?? MAX_MESSAGES_PER_RUN;
  const ids: string[] = [];
  let url = startUrl;
  let cursor = "";
  let done = false;
  for (let page = 0; page < MAX_PAGES; page++) {
    const res: DeltaPage = await graphJson(env, account, url, { headers: { prefer: "odata.maxpagesize=50" } });
    if (opts.collect) {
      for (const id of newMessageIdsFromPage(res)) {
        if (!ids.includes(id)) ids.push(id);
      }
    }
    const delta = res["@odata.deltaLink"];
    if (delta) {
      cursor = delta;
      done = true;
      break;
    }
    const next = res["@odata.nextLink"];
    if (!next) {
      done = true;
      break;
    }
    cursor = next;
    // Every id already collected gets ingested before the cursor is stored, so stopping here loses
    // nothing: the next tick resumes from this very nextLink.
    if (opts.collect && ids.length >= maxIds) break;
  }
  return { ids, cursor, done };
}

/**
 * One pass over an Outlook mailbox.
 *
 * The first passes only walk the chain to find out where the inbox is *now*, ingesting nothing —
 * the same "connecting imports no history" behaviour Gmail has. A large inbox takes several ticks to
 * walk, which is why `initial_sync_done` gates it rather than a single priming call: Graph has no
 * "give me a token for now" shortcut for mail the way it does for directory objects.
 *
 * Once level, each new id is fetched as raw MIME (`/$value`) and handed to the same
 * `parseInbound` → `deliverInbound` pair that Cloudflare Email Routing uses, so threading, the
 * Screener and bucket classification behave identically to every other kind of mailbox.
 */
export async function syncOutlookAccount(env: Env, account: AccountRow): Promise<{ added: number }> {
  const db = env.DB;
  const priming = !account.initial_sync_done;
  const start = account.delta_link || INBOX_DELTA_PATH;

  let walked: DeltaWalk;
  try {
    walked = await walkDelta(env, account, start, { collect: !priming });
  } catch (e) {
    if (!isExpiredCursor(e)) throw e;
    // Graph forgot this cursor. Re-walk from scratch in priming mode rather than ingesting the whole
    // mailbox as if it were new: anything that arrived during the gap is missed, which is the lesser
    // evil against importing years of history into the Screener.
    await logSync(db, account.id, "warn", "Outlook delta cursor expired; re-syncing from now");
    await db.prepare(`UPDATE accounts SET delta_link = NULL, initial_sync_done = 0 WHERE id = ?`).bind(account.id).run();
    account.delta_link = null;
    account.initial_sync_done = 0;
    return { added: 0 };
  }

  let added = 0;
  if (!priming) {
    for (const id of walked.ids) {
      const mime = await graphRaw(env, account, `messages/${encodeURIComponent(id)}/$value`);
      const parsed = await parseInbound(mime, "", account.email);
      const r = await deliverInbound(env, account, parsed);
      added += r.added;
    }
  }

  // Only now, with every message safely ingested, does the cursor move. A throw above leaves it
  // where it was and the next tick replays — which is safe, because ingest is idempotent.
  if (walked.cursor) {
    const initialDone = priming && walked.done ? 1 : account.initial_sync_done;
    await db
      .prepare(`UPDATE accounts SET delta_link = ?, initial_sync_done = ?, last_synced_at = ? WHERE id = ?`)
      .bind(walked.cursor, initialDone, now(), account.id)
      .run();
    account.delta_link = walked.cursor;
    account.initial_sync_done = initialDone;
  }
  return { added };
}
