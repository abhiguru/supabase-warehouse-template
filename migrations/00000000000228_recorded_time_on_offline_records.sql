-- Recorded time on offline records (WH-161, offline work step 5): topic "recorded time on offline records". Named by topic; its number is taken
-- when the work is assembled for main, after "number issued at save" (this file changes the signature that file leaves). Contract:
-- product/tech/app-offline-new-records.md section 2.2, cases B9 and B12.
--
-- What it does:
--  1. goodsreceived and dispatch gain recorded_at timestamptz (NULL for every row so far and for every save that does not carry one), beside
--     the server's created_at: the time the phone recorded the document.
--  2. save_grn gains the trailing parameter p_recorded_at timestamptz DEFAULT NULL (the old 19-argument function is dropped); the dispatch
--     reads recorded_at in p_dispatch_data (no signature change). A value more than 5 minutes ahead of the server is refused
--     RECORDED_TIME_FUTURE (definition files); the document date rules are unchanged.
--  3. The possible-duplicate lookups (warehouse_security.possible_duplicate_grn and possible_duplicate_dispatch, migration 124) gain a
--     trailing p_recorded_at timestamptz DEFAULT NULL (the old functions are dropped). With it NULL they are exactly what they were
--     (another live record created in the last 30 minutes). With it set, the 30 minutes run between the recorded times: a stored record
--     matches when COALESCE(recorded_at, created_at) is within 30 minutes of this record's recorded time, before or after it.
-- The function bodies of save_grn and the dispatch are in migrations/definitions.

ALTER TABLE public.goodsreceived ADD COLUMN recorded_at timestamptz;
ALTER TABLE public.dispatch ADD COLUMN recorded_at timestamptz;
COMMENT ON COLUMN public.goodsreceived.recorded_at IS 'WH-161: the time the phone recorded this GRN (an offline send); NULL for a GRN saved online. created_at is when the server saved it.';
COMMENT ON COLUMN public.dispatch.recorded_at IS 'WH-161: the time the phone recorded this dispatch (an offline send); NULL for a dispatch saved online. created_at is when the server saved it.';

-- save_grn: the trailing p_recorded_at.
DROP FUNCTION public.save_grn(character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, text, character varying, jsonb, boolean, boolean);

-- The new signature. The body is the definition file's (migrations/definitions/save_grn.sql, applied after the numbered files, as for every
-- function that has one, with its grants); this one only exists so that the signature does.
CREATE FUNCTION public.save_grn(p_gr_no character varying, p_date timestamp with time zone, p_customer_id uuid, p_customer_name character varying, p_sender_id uuid DEFAULT NULL::uuid, p_sender_name character varying DEFAULT NULL::character varying, p_supervisor_id uuid DEFAULT NULL::uuid, p_supervisor_name character varying DEFAULT NULL::character varying, p_registration character varying DEFAULT NULL::character varying, p_note character varying DEFAULT NULL::character varying, p_leon boolean DEFAULT false, p_pricing_mode character varying DEFAULT NULL::character varying, p_items jsonb DEFAULT '[]'::jsonb, p_images jsonb DEFAULT '[]'::jsonb, p_idempotency_key text DEFAULT NULL::text, p_duration_mode character varying DEFAULT 'legacy'::character varying, p_rates jsonb DEFAULT NULL::jsonb, p_warn_duplicate boolean DEFAULT false, p_issue_number boolean DEFAULT false, p_recorded_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
 SET jit TO 'off'
AS $function$
BEGIN
  RAISE EXCEPTION 'save_grn: the definition of migrations/definitions/save_grn.sql has not been applied';
END
$function$;

REVOKE ALL ON FUNCTION public.save_grn(character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, text, character varying, jsonb, boolean, boolean, timestamp with time zone) FROM PUBLIC, anon, authenticated, service_role;

-- The GRN lookup: the window between the recorded times when the request carries one.
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$p_exclude_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb$m$,
    $m$    SELECT g.id, g.gr_no, g.created_at,$m$,
    $m$      AND g.created_at >= now() - interval '30 minutes'$m$,
    $m$    v_minutes := GREATEST(0, floor(extract(epoch FROM (now() - v_found.created_at)) / 60))::integer;$m$
  ];
  v_new constant text[] := ARRAY[
    $m$p_exclude_id uuid DEFAULT NULL::uuid, p_recorded_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb$m$,
    $m$    SELECT g.id, g.gr_no, g.created_at, COALESCE(g.recorded_at, g.created_at) AS effective_at,$m$,
    $m$      -- WH-161: an offline send is measured between the recorded times (the stored record's own recorded time, else its arrival), not from now.
      AND (CASE WHEN p_recorded_at IS NULL THEN g.created_at >= now() - interval '30 minutes'
                ELSE abs(extract(epoch FROM (COALESCE(g.recorded_at, g.created_at) - p_recorded_at))) <= 1800 END)$m$,
    $m$    v_minutes := GREATEST(0, floor(abs(extract(epoch FROM (CASE WHEN p_recorded_at IS NULL THEN now() - v_found.created_at
                                                                     ELSE p_recorded_at - v_found.effective_at END))) / 60))::integer;$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('warehouse_security.possible_duplicate_grn(uuid, timestamp with time zone, jsonb, uuid)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'possible_duplicate_grn: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  DROP FUNCTION warehouse_security.possible_duplicate_grn(uuid, timestamp with time zone, jsonb, uuid);
  EXECUTE v_def;
END
$patch$;
ALTER FUNCTION warehouse_security.possible_duplicate_grn(p_customer_id uuid, p_date timestamp with time zone, p_items jsonb, p_exclude_id uuid, p_recorded_at timestamp with time zone) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.possible_duplicate_grn(p_customer_id uuid, p_date timestamp with time zone, p_items jsonb, p_exclude_id uuid, p_recorded_at timestamp with time zone) FROM PUBLIC;

-- The dispatch lookup: the same.
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$p_exclude_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb$m$,
    $m$    SELECT d.id, d.disp_no, d.created_at, d.registration,$m$,
    $m$      AND d.created_at >= now() - interval '30 minutes'$m$,
    $m$    v_minutes := GREATEST(0, floor(extract(epoch FROM (now() - v_found.created_at)) / 60))::integer;$m$
  ];
  v_new constant text[] := ARRAY[
    $m$p_exclude_id uuid DEFAULT NULL::uuid, p_recorded_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb$m$,
    $m$    SELECT d.id, d.disp_no, d.created_at, COALESCE(d.recorded_at, d.created_at) AS effective_at, d.registration,$m$,
    $m$      -- WH-161: an offline send is measured between the recorded times (the stored record's own recorded time, else its arrival), not from now.
      AND (CASE WHEN p_recorded_at IS NULL THEN d.created_at >= now() - interval '30 minutes'
                ELSE abs(extract(epoch FROM (COALESCE(d.recorded_at, d.created_at) - p_recorded_at))) <= 1800 END)$m$,
    $m$    v_minutes := GREATEST(0, floor(abs(extract(epoch FROM (CASE WHEN p_recorded_at IS NULL THEN now() - v_found.created_at
                                                                     ELSE p_recorded_at - v_found.effective_at END))) / 60))::integer;$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('warehouse_security.possible_duplicate_dispatch(uuid, text, uuid[], uuid)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'possible_duplicate_dispatch: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  DROP FUNCTION warehouse_security.possible_duplicate_dispatch(uuid, text, uuid[], uuid);
  EXECUTE v_def;
END
$patch$;
ALTER FUNCTION warehouse_security.possible_duplicate_dispatch(p_customer_id uuid, p_registration text, p_lot_ids uuid[], p_exclude_id uuid, p_recorded_at timestamp with time zone) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.possible_duplicate_dispatch(p_customer_id uuid, p_registration text, p_lot_ids uuid[], p_exclude_id uuid, p_recorded_at timestamp with time zone) FROM PUBLIC;

NOTIFY pgrst, 'reload schema';
