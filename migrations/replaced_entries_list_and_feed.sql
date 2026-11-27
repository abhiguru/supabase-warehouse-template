-- Topics "replaced entries" (WH-303's part: the administrators' list and "mark checked"), "replaced entries in GRN details" and "sync
-- replaced entries" (contract tech/app-offline-edit-grn.md sections 5.4, 5.5 and 5.8). Named by topic; its number is taken when the work
-- is assembled for main. It needs the topics "replaced entries" (the table) and "sync change log" with the feed migrations up to
-- "sync feed without request columns" applied before it.
--  1. warehouse_security.grn_replacement_rows: one row shape for every reader (names resolved; a person not known is NULL):
--     {id, grn_id, gr_no, customer_name, kind, field, newer_value, newer_by_name, newer_at, sent_value, sent_by_name, sent_at,
--     recorded_at, checked_by_name, checked_at}. No app role reads it.
--  2. public.get_grn_replacements(p_from, p_to, p_state, p_limit, p_offset): administrators only; {success, rows, total}, newest first by
--     sent_at; p_from and p_to are India days of sent_at (NULL = open; any p_from, Product PQ7); p_state 'unchecked' ("To check"),
--     'checked' ("Checked") or NULL (both), anything else STATE_INVALID; at most 2,000 rows a page.
--  3. public.mark_grn_replacements_checked(p_grn_id, p_ids): administrators only; checks exactly the named entries of that GRN that are
--     not checked yet ({success, checked: n}); ids of another GRN or already checked are skipped. Entries are never deleted (PQ7).
--  4. get_grn_details answers `replacements` (the GRN's unchecked entries, newest first) to administrators, supervisors and staff only.
--  5. Feed entity grn_replacements: the unchecked entries for administrators, supervisors and staff, never a customer account; an entry
--     checked is a delete for the phones (the server keeps it). Every change of an entry also logs its GRN, so the GRN reaches the phones
--     as an upsert in the next pull (the GRN row itself is not written). Feed format 4 (a copy of format 3 answers reload_all
--     FORMAT_CHANGED).
-- The feed functions are patched by text with marker counts. No role is created, altered or dropped; the pg_temp helper is dropped at the end.

-- ===== 1. the row shape =====
CREATE VIEW warehouse_security.grn_replacement_rows AS
  SELECT r.id, r.grn_id, r.sent_at, r.checked_at,
         jsonb_build_object(
           'id', r.id, 'grn_id', r.grn_id, 'gr_no', g.gr_no, 'customer_name', COALESCE(g.customer_name, c.name),
           'kind', r.kind, 'field', r.field,
           'newer_value', r.newer_value, 'newer_by_name', nb.name, 'newer_at', r.newer_at,
           'sent_value', r.sent_value, 'sent_by_name', sb.name, 'sent_at', r.sent_at, 'recorded_at', r.recorded_at,
           'checked_by_name', cb.name, 'checked_at', r.checked_at) AS body
    FROM warehouse_security.grn_replacements r
    LEFT JOIN public.goodsreceived g ON g.id = r.grn_id
    LEFT JOIN public.customers c ON c.id = r.customer_id
    LEFT JOIN public.user_profiles nb ON nb.id = r.newer_by
    LEFT JOIN public.user_profiles sb ON sb.id = r.sent_by
    LEFT JOIN public.user_profiles cb ON cb.id = r.checked_by;
ALTER VIEW warehouse_security.grn_replacement_rows OWNER TO supabase_admin;
REVOKE ALL ON TABLE warehouse_security.grn_replacement_rows FROM PUBLIC, anon, authenticated, service_role;

-- ===== 2. the administrators' list =====
CREATE FUNCTION public.get_grn_replacements(p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_state text DEFAULT NULL,
    p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 2000);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
  v_rows jsonb;
  v_total bigint;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_grn_replacements', jsonb_build_object('p_from', p_from, 'p_to', p_to, 'p_state', p_state,
    'p_limit', p_limit, 'p_offset', p_offset));
  -- The gate admits supervisors with every management RPC; this list is the administrators'.
  IF warehouse_security.active_role() IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  IF p_state IS NOT NULL AND p_state NOT IN ('unchecked', 'checked') THEN
    RETURN warehouse_security.refuse('STATE_INVALID', 'The list state is not understood.', jsonb_build_object('state', p_state));
  END IF;

  WITH matched AS (
    SELECT v.id, v.sent_at, v.body
    FROM warehouse_security.grn_replacement_rows v
    WHERE (p_from IS NULL OR warehouse_security.business_date(v.sent_at) >= p_from)
      AND (p_to IS NULL OR warehouse_security.business_date(v.sent_at) <= p_to)
      AND (p_state IS NULL OR (p_state = 'checked') = (v.checked_at IS NOT NULL)))
  SELECT (SELECT count(*) FROM matched),
         COALESCE((SELECT jsonb_agg(p.body ORDER BY p.sent_at DESC, p.id DESC)
                   FROM (SELECT m.id, m.sent_at, m.body FROM matched m ORDER BY m.sent_at DESC, m.id DESC LIMIT v_limit OFFSET v_offset) p),
                  '[]'::jsonb)
    INTO v_total, v_rows;
  RETURN jsonb_build_object('success', true, 'rows', v_rows, 'total', v_total);
END $$;
ALTER FUNCTION public.get_grn_replacements(date, date, text, integer, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_grn_replacements(date, date, text, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_grn_replacements(date, date, text, integer, integer) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_grn_replacements(date, date, text, integer, integer) IS
  'WH-303: the replaced entries ("Replaced entries" report), administrators only, newest first, by India day and state.';

-- ===== 3. mark checked =====
CREATE FUNCTION public.mark_grn_replacements_checked(p_grn_id uuid, p_ids uuid[])
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_profile uuid;
  v_checked integer;
BEGIN
  PERFORM warehouse_security.authorize_rpc('mark_grn_replacements_checked', jsonb_build_object('p_grn_id', p_grn_id, 'p_ids', p_ids));
  IF warehouse_security.active_role() IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  SELECT p.id INTO v_profile FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();
  IF v_profile IS NULL THEN
    RAISE EXCEPTION 'Active account required' USING ERRCODE = '42501';
  END IF;
  -- Exactly the entries the screen showed; one that arrived meanwhile stays "To check". Checking again keeps the first checking.
  UPDATE warehouse_security.grn_replacements r
     SET checked_by = v_profile, checked_at = now()
   WHERE r.grn_id = p_grn_id AND r.id = ANY (COALESCE(p_ids, ARRAY[]::uuid[])) AND r.checked_at IS NULL;
  GET DIAGNOSTICS v_checked = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'checked', v_checked);
END $$;
ALTER FUNCTION public.mark_grn_replacements_checked(uuid, uuid[]) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.mark_grn_replacements_checked(uuid, uuid[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_grn_replacements_checked(uuid, uuid[]) TO authenticated, service_role;
COMMENT ON FUNCTION public.mark_grn_replacements_checked(uuid, uuid[]) IS
  'WH-303: "Mark as checked": administrators only; the named entries of the GRN that are not checked yet.';

-- ===== 4 and 5: patches by marker count =====
DROP FUNCTION IF EXISTS pg_temp.patch_function(regprocedure, text[], text[]);
CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text[], p_new text[]) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_def text := pg_get_functiondef(p_function);
  v_count integer;
  i integer;
BEGIN
  IF array_length(p_old, 1) IS DISTINCT FROM array_length(p_new, 1) THEN
    RAISE EXCEPTION '%: the marker list and the replacement list differ in length', p_function;
  END IF;
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    IF position(p_old[i] IN p_new[i]) = 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % does not keep the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- ===== 4. get_grn_details: the GRN's unchecked entries, for the three staff roles =====
SELECT pg_temp.patch_function('public.get_grn_details(uuid)'::regprocedure, ARRAY[
$m$        RETURN v_result;

    EXCEPTION$m$
], ARRAY[
$m$        -- WH-303: the GRN's unchecked replaced entries, for administrators, supervisors and staff (never a customer account).
        IF v_role IN ('admin', 'supervisor', 'staff') THEN
            v_result := v_result || jsonb_build_object('replacements', COALESCE((
                SELECT jsonb_agg(v.body ORDER BY v.sent_at DESC, v.id DESC)
                FROM warehouse_security.grn_replacement_rows v
                WHERE v.grn_id = p_grn_id AND v.checked_at IS NULL), '[]'::jsonb));
        END IF;

        RETURN v_result;

    EXCEPTION$m$
]);

-- ===== 5. the feed entity =====
-- The rows: the unchecked entries, administrators, supervisors and staff only.
CREATE FUNCTION warehouse_sync.rows_grn_replacements(p_role text, p_ids text[], p_after text, p_limit integer)
 RETURNS TABLE(id text, body jsonb)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT v.id::text, v.body
    FROM warehouse_security.grn_replacement_rows v
   WHERE p_role IN ('admin', 'supervisor', 'staff')
     AND v.checked_at IS NULL
     AND (p_ids IS NULL OR v.id = ANY (p_ids::uuid[]))
     AND (p_after IS NULL OR v.id > p_after::uuid)
   ORDER BY v.id LIMIT p_limit
$$;
ALTER FUNCTION warehouse_sync.rows_grn_replacements(text, text[], text, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.rows_grn_replacements(text, text[], text, integer) FROM PUBLIC, anon, authenticated, service_role;

SELECT pg_temp.patch_function('warehouse_sync.entities(text)'::regprocedure, ARRAY[
$m$'item_price_history', 'grn_lock'$m$,
$m$WHEN 'customer' THEN e NOT IN ($m$
], ARRAY[
$m$'item_price_history', 'grn_lock', 'grn_replacements'$m$,
$m$WHEN 'customer' THEN e NOT IN ('grn_replacements', $m$
]);

SELECT pg_temp.patch_function('warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer)'::regprocedure, ARRAY[
$m$ELSIF p_entity = 'users_customers_new' THEN$m$
], ARRAY[
$m$ELSIF p_entity = 'grn_replacements' THEN
    RETURN QUERY SELECT r.id, r.body FROM warehouse_sync.rows_grn_replacements(p_role, p_ids, p_after, p_limit) r;
    RETURN;
  ELSIF p_entity = 'users_customers_new' THEN$m$
]);

-- An entry is logged as itself (a checked one is gone for the phones) and touches its GRN, so details are read again.
SELECT pg_temp.patch_function('warehouse_sync.log_change()'::regprocedure, ARRAY[
$m$  ELSE
    RAISE EXCEPTION 'warehouse_sync.log_change: table % is not a logged table', TG_TABLE_NAME;$m$
], ARRAY[
$m$  WHEN 'grn_replacements' THEN
    PERFORM warehouse_sync.log_entry(t, r->>'id', op, NULL, NULL, NULL, NULL);
    g := (r->>'grn_id')::uuid;
    SELECT x.customer_id INTO c FROM public.goodsreceived x WHERE x.id = g;
    IF FOUND THEN
      PERFORM warehouse_sync.log_entry('goodsreceived', g::text, 'U', c, c, g, NULL);
    END IF;
  ELSE
    RAISE EXCEPTION 'warehouse_sync.log_change: table % is not a logged table', TG_TABLE_NAME;$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

CREATE TRIGGER zz_change_feed AFTER INSERT OR UPDATE OR DELETE ON warehouse_security.grn_replacements
  FOR EACH ROW EXECUTE FUNCTION warehouse_sync.log_change();
ALTER TABLE warehouse_security.grn_replacements ENABLE ALWAYS TRIGGER zz_change_feed;
CREATE TRIGGER zz_change_feed_truncate AFTER TRUNCATE ON warehouse_security.grn_replacements
  FOR EACH STATEMENT EXECUTE FUNCTION warehouse_sync.log_truncate();
ALTER TABLE warehouse_security.grn_replacements ENABLE ALWAYS TRIGGER zz_change_feed_truncate;

-- Format 4: a phone's copy of format 3 has no grn_replacements and reloads everything.
ALTER TABLE warehouse_sync.state ALTER COLUMN format SET DEFAULT 4;
UPDATE warehouse_sync.state SET format = 4;

NOTIFY pgrst, 'reload schema';
