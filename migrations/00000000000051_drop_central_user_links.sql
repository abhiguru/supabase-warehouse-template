-- Drops public.central_user_links (2026-10-12).
--
-- Migration 0 created this table for an earlier central-login design: one row
-- per central account (central_user_id, phone_number, central_status) pointing
-- at a local profile (local_user_id). That design was not built. Migration 49
-- implemented central login with the link on the profile itself
-- (public.user_profiles.central_issuer and central_subject, one identity per
-- profile; docs/CENTRAL_LOGIN.md, "What is stored") and the single-use record
-- in warehouse_security.central_token_use.
--
-- Nothing reads or writes this table: no function body in any migration, no
-- edge function, script or test names it, the app does not query it, the
-- write guard of migration 42 and run_database_retention do not list it, and
-- its only grant is the blanket service_role grant of migration 3. Its two
-- policies (service_role manages, a user reads the own row) go with it. The
-- table is empty on every installation, because nothing ever inserted into it.
DO $check$ BEGIN
  IF (SELECT count(*) FROM public.central_user_links) <> 0 THEN
    RAISE EXCEPTION 'central_user_links holds rows; nothing was expected to write it. Inspect before dropping.';
  END IF;
END $check$;
DROP TABLE public.central_user_links;
NOTIFY pgrst, 'reload schema';
