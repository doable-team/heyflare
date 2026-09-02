-- HEY-style Bundles: all mail from a bundled sender shows as one row in the Imbox / Paper Trail.
ALTER TABLE contacts ADD COLUMN bundled INTEGER NOT NULL DEFAULT 0;
