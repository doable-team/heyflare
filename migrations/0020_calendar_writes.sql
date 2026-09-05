-- D1 bills a row write for the row and again for every index on it. An events row carried five
-- indexes, so each Google instance cost seven writes; three of the five only ever matter for rows
-- that carry the column, which almost no Google row does. As partial indexes they cost those rows
-- nothing and still serve every lookup, which all name the column with = or IN.
DROP INDEX IF EXISTS idx_events_calendar;
DROP INDEX IF EXISTS idx_events_master;
DROP INDEX IF EXISTS idx_events_thread;
CREATE INDEX IF NOT EXISTS idx_events_masters ON events(user_id, starts_at) WHERE rrule IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_events_master ON events(master_id) WHERE master_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_events_thread ON events(thread_id) WHERE thread_id IS NOT NULL;

-- When a Google calendar was last pulled from scratch. Bounded pulls need a periodic repeat, because
-- the sync token keeps the original window for life. Existing calendars count their last poll as
-- one, so they do not all come due in the same minute.
ALTER TABLE calendars ADD COLUMN full_synced_at INTEGER;
UPDATE calendars SET full_synced_at = COALESCE(last_synced_at, strftime('%s','now') * 1000) WHERE source = 'google' AND sync_token IS NOT NULL;

-- Instances imported before the sync window existed, years past anything the calendar can show.
-- The refresh above brings them back one window at a time, as they come within reach.
DELETE FROM event_completions WHERE event_id IN (
  SELECT id FROM events WHERE master_id IS NULL AND rrule IS NULL AND starts_at > strftime('%s','now') * 1000 + 540 * 86400000
    AND calendar_id IN (SELECT id FROM calendars WHERE source = 'google'));
DELETE FROM events WHERE master_id IS NULL AND rrule IS NULL AND starts_at > strftime('%s','now') * 1000 + 540 * 86400000
  AND calendar_id IN (SELECT id FROM calendars WHERE source = 'google');

-- The same shared calendar subscribed through several accounts: keep the oldest copy on, hide the rest.
UPDATE calendars SET visible = 0, updated_at = strftime('%s','now') * 1000
WHERE source = 'google' AND visible = 1
  AND id NOT IN (SELECT id FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY user_id, remote_id ORDER BY created_at, id) AS rn FROM calendars WHERE source = 'google') WHERE rn = 1);
