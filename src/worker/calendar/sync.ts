// The calendar half of the cron. Google calendars are incremental (a syncToken round trip) so they
// run every invocation; ICS feeds are a whole-file download, so they wait out the hour.

import type { Env } from "../env";
import type { AccountRow } from "../db";
import { now } from "../db";
import { hasCalendarScope } from "../google";
import type { CalendarRow } from "./types";
import { ensureDefaultCalendars, syncCalendarNow } from "./sources";

/** How stale a subscribed feed has to be before it is worth re-downloading. */
const ICS_INTERVAL_MS = 3600_000;
/** One busy account must not starve the others, or eat the invocation's CPU on its own. */
const MAX_PER_RUN = 12;

/** How long an account's calendar list may go unchecked before it is worth pulling again. */
const LIST_INTERVAL_MS = 6 * 3600_000;

/**
 * Re-read a Google account's calendar list.
 *
 * It is pulled at consent, and if that call fails the account is left holding the scope with
 * nothing to show and no way back — everything after it syncs calendars that already exist. So an
 * account with no calendars is retried every run. An account that has some is re-read a few times a
 * day, which is also how a calendar added on Google's side turns up here without being asked.
 */
async function discoverMissing(env: Env): Promise<void> {
  const r = await env.DB.prepare(
    `SELECT a.* FROM accounts a
     WHERE a.provider = 'gmail' AND a.sync_status <> 'disconnected'
       AND (NOT EXISTS (SELECT 1 FROM calendars c WHERE c.account_id = a.id)
            OR COALESCE((SELECT MAX(c2.updated_at) FROM calendars c2 WHERE c2.account_id = a.id), 0) <= ?)
     LIMIT 4`
  )
    .bind(now() - LIST_INTERVAL_MS)
    .all<AccountRow>();
  for (const acc of r.results) {
    if (!hasCalendarScope(acc.scopes)) continue;
    try {
      await ensureDefaultCalendars(env, acc.user_id, acc);
    } catch (e) {
      console.error("calendar discovery failed", acc.email, e);
    }
  }
}

/** Cron entry point: refresh every calendar that is due. Never throws. */
export async function runCalendarSync(env: Env): Promise<void> {
  const db = env.DB;
  try {
    await discoverMissing(env);
  } catch (e) {
    console.error("calendar discovery pass failed", e);
  }
  let due: CalendarRow[] = [];
  try {
    const r = await db
      .prepare(
        `SELECT c.* FROM calendars c
         LEFT JOIN accounts a ON a.id = c.account_id
         WHERE c.source <> 'local'
           AND (c.account_id IS NULL OR (a.id IS NOT NULL AND a.sync_status <> 'disconnected'))
           AND (c.source = 'google' OR COALESCE(c.last_synced_at, 0) <= ?)
         ORDER BY COALESCE(c.last_synced_at, 0) ASC
         LIMIT ?`
      )
      .bind(now() - ICS_INTERVAL_MS, MAX_PER_RUN)
      .all<CalendarRow>();
    due = r.results;
  } catch (e) {
    console.error("calendar sync: could not list calendars", e);
    return;
  }

  for (const cal of due) {
    // One unreachable feed must not take the rest of them down with it; syncCalendarNow has already
    // recorded sync_error and a sync_log row by the time it throws.
    try {
      await syncCalendarNow(env, cal);
    } catch (e) {
      console.error("calendar sync failed", cal.name, e);
    }
  }
}
