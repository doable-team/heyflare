-- Photo avatars: Google People photos for contacts, Google profile picture for accounts.
ALTER TABLE contacts ADD COLUMN avatar_url TEXT NOT NULL DEFAULT '';
ALTER TABLE accounts ADD COLUMN avatar_url TEXT NOT NULL DEFAULT '';
ALTER TABLE accounts ADD COLUMN photos_synced_at INTEGER;
