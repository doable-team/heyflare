-- BIMI brand logos (what Gmail shows for companies) + a marker for "new contacts appeared" so photo sync can run sooner.
CREATE TABLE IF NOT EXISTS brand_logos (
  domain TEXT PRIMARY KEY,
  logo_url TEXT NOT NULL DEFAULT '',
  checked_at INTEGER NOT NULL
);
ALTER TABLE accounts ADD COLUMN contacts_changed_at INTEGER;
