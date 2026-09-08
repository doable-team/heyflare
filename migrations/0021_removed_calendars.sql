-- A calendar someone removes from the settings page must stay removed. `mirrorGoogleCalendars`
-- re-lists every calendar Google reports for an account on each sync and re-inserts anything
-- missing (by design, so a calendar created on Google after the last sync shows up here too) —
-- which used to bring back a calendar the user had just deleted, since deleting it only dropped
-- the row, leaving nothing to tell the next sync "not this one."
CREATE TABLE IF NOT EXISTS removed_calendars (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  remote_id TEXT NOT NULL,
  removed_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_removed_calendars ON removed_calendars(account_id, remote_id);
