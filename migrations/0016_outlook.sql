-- Outlook mailboxes (accounts.provider = 'outlook'), synced over Microsoft Graph.
-- delta_link stores the whole @odata.deltaLink URL: Graph's equivalent of Gmail's history_id cursor.
ALTER TABLE accounts ADD COLUMN delta_link TEXT;
