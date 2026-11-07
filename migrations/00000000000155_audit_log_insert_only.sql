-- Migration 155 (WH-115): the audit log is insert-only, and a failed audit write is recorded and reported.
--
--  1. A save still goes through when its audit row cannot be written (owner decision, 2026-11-07: availability first). audit_trigger_func
--     now also writes one row to warehouse_security.audit_write_failures (table, row id, action, error state and message) and raises a
--     WARNING with the same facts. If even that row cannot be written, the save still goes through and only the WARNING is left.
--     The monitor (scripts/watch.mjs, check audit_write_failed) reads the table and tells the operator once a day while there are
--     failures in the last 24 hours.
--  2. No role can change or delete an audit row. The service role, anon, authenticated and PUBLIC keep at most SELECT (the service role
--     also INSERT) on audit_log and every partition; UPDATE, DELETE, TRUNCATE, REFERENCES and TRIGGER are taken away. The retention
--     job (warehouse_maintenance.run_database_retention, SECURITY DEFINER, runs as the table owner) is the only thing that removes
--     rows: it drops whole partitions past the retention period and deletes audit_log_default rows past it. Partitions it creates from
--     now on are granted SELECT and INSERT to the service role, not ALL.
--  Nothing else reads audit rows with a change right: no function, script or fas-sync statement updates or deletes audit_log.

-- ===== 1. the failures table =====
CREATE TABLE warehouse_security.audit_write_failures (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  table_name    text NOT NULL,
  row_id        text,
  action        text NOT NULL,
  error_state   text,
  error_message text,
  created_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE warehouse_security.audit_write_failures OWNER TO supabase_admin;
ALTER TABLE warehouse_security.audit_write_failures ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.audit_write_failures FROM PUBLIC, anon, authenticated, service_role;
CREATE INDEX audit_write_failures_created_idx ON warehouse_security.audit_write_failures (created_at DESC);
COMMENT ON TABLE warehouse_security.audit_write_failures IS
  'One row for each audit_log write that failed while its save went through (WH-115). Read by the monitor (audit_write_failed); no API role has a grant.';

-- ===== 2. audit_trigger_func records the failure =====
CREATE OR REPLACE FUNCTION public.audit_trigger_func() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_state text;
    v_message text;
    v_row_id text;
BEGIN
    INSERT INTO public.audit_log (table_name, action, user_id, old_data, new_data)
    VALUES (
        TG_TABLE_NAME,
        TG_OP,
        NULLIF(current_setting('request.jwt.claims', true)::json->>'sub', '')::UUID,
        CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END,
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END
    );
    RETURN COALESCE(NEW, OLD);
EXCEPTION
    WHEN OTHERS THEN
        -- The save goes through (an audit failure does not stop business operations), but it is never silent: the failure is
        -- recorded for the monitor and raised as a warning with the table and the row id (WH-115).
        v_state := SQLSTATE;
        v_message := SQLERRM;
        BEGIN
            v_row_id := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD)->>'id' ELSE to_jsonb(NEW)->>'id' END;
        EXCEPTION WHEN OTHERS THEN
            v_row_id := NULL;
        END;
        RAISE WARNING 'audit_trigger_func failed for table % row % operation %: % - %', TG_TABLE_NAME, v_row_id, TG_OP, v_state, v_message;
        BEGIN
            INSERT INTO warehouse_security.audit_write_failures (table_name, row_id, action, error_state, error_message)
            VALUES (TG_TABLE_NAME, v_row_id, TG_OP, v_state, left(v_message, 500));
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'audit_trigger_func could not record its failure for table % row %: % - %', TG_TABLE_NAME, v_row_id, SQLSTATE, SQLERRM;
        END;
        RETURN COALESCE(NEW, OLD);
END;
$$;

-- ===== 3. insert-only: audit_log and every partition =====
DO $grants$
DECLARE
  v_table regclass;
BEGIN
  FOR v_table IN
    SELECT 'public.audit_log'::regclass
    UNION ALL
    SELECT i.inhrelid::regclass FROM pg_inherits i WHERE i.inhparent = 'public.audit_log'::regclass
  LOOP
    EXECUTE format('REVOKE ALL ON TABLE %s FROM PUBLIC, anon, authenticated, service_role', v_table);
    EXECUTE format('GRANT SELECT, INSERT ON TABLE %s TO service_role', v_table);
  END LOOP;
END $grants$;

-- ===== 4. partitions made by the retention job are insert-only too =====
-- Patched in place (text of migration 123, section 10, as migration 136 left it): the marker must be found exactly once.
DO $patch$
DECLARE
  def text := pg_get_functiondef('warehouse_maintenance.run_database_retention(timestamptz,boolean)'::regprocedure);
  before_text text := $m$'GRANT ALL ON public.%I TO service_role'$m$;
  -- The default privileges give a new table ALL to service_role, so the grant is preceded by the same REVOKE as section 3.
  after_text text := $m$'REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated, service_role', v_name);
        EXECUTE format('GRANT SELECT, INSERT ON public.%I TO service_role'$m$;
  found int;
BEGIN
  found := (length(def) - length(replace(def, before_text, ''))) / length(before_text);
  IF found <> 1 THEN
    RAISE EXCEPTION 'migration 155: run_database_retention patch found its marker % times (expected 1)', found;
  END IF;
  EXECUTE replace(def, before_text, after_text);
END $patch$;
