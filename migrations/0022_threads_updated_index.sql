-- GET /api/changes answers "did any thread of yours change since?" with one MAX(updated_at) per
-- account. Every client polls it while it is on screen, so the read has to be an index seek,
-- not a scan of the mailbox.
CREATE INDEX IF NOT EXISTS idx_threads_account_updated ON threads(account_id, updated_at);
