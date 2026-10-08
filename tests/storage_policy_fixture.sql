-- Used only in migrations.sh's fresh network-none disposable database.
-- The pinned PostgreSQL image supplies the base Storage tables.
-- Model the later Storage API bucket-migration columns used by the actual
-- setup policy script; this fixture is never used by warehouse installation.
-- Grant the API test role table privileges so RLS, rather than a missing table
-- grant, is the layer under test. No live Storage HTTP acceptance is claimed.
\set ON_ERROR_STOP on
DO $$ BEGIN
 IF to_regclass('storage.objects') IS NULL OR to_regclass('storage.buckets') IS NULL THEN
  RAISE EXCEPTION 'Pinned database image Storage schema is required';
 END IF;
END $$;
ALTER TABLE storage.buckets ADD COLUMN IF NOT EXISTS public boolean DEFAULT false;
ALTER TABLE storage.buckets ADD COLUMN IF NOT EXISTS file_size_limit bigint;
ALTER TABLE storage.buckets ADD COLUMN IF NOT EXISTS allowed_mime_types text[];
GRANT USAGE ON SCHEMA storage TO authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON storage.objects TO authenticated;
