\set ON_ERROR_STOP on
-- The list refresher of migration 91: the pg_cron jobs warehouse-list-refresh (every 5 seconds) and
-- warehouse-list-refresh-history, and the LOGIN role warehouse_list_refresher they run as.
-- setup.sh and restore.sh run this after migrate.sh. Role attributes and settings are not part of a
-- database dump, and restore.sh re-creates a missing role without LOGIN, so a restored database
-- needs this before its lists refresh again. Running it twice changes nothing.
DO $$ BEGIN PERFORM warehouse_security.ensure_list_refresher(); END $$;
