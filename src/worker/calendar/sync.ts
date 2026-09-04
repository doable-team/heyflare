// The calendar half of the cron. Google calendars are incremental (a syncToken round trip) so they
// run every invocation; ICS feeds are a whole-file download, so they wait out the hour.

import type { Env } from "../env";
import { now } from "../db";
import type { CalendarRow } from "./types";
import { syncCalendarNow } from "./sources";

/** How stale a subscribed feed has to be before it is worth re-downloading. */
const ICS_INTERVAL_MS = 3600_000;
/** One busy account must not starve the others, or eat the invocation's CPU on its own. */
const MAX_PER_RUN = 12;

/** Cron entry point: refresh every calendar that is due. Never throws. */
export async function runCalendarSync(env: Env): Promise<void> {
  const db = env.DB;
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
