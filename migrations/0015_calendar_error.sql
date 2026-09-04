-- Why an account's calendars are missing, kept where the UI can show it. Distinct from sync_error,
-- which belongs to mail: an account can be syncing mail perfectly and still have no calendar access.
ALTER TABLE accounts ADD COLUMN calendar_error TEXT;
