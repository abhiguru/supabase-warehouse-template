-- Topic "lot rack and mark change" (WH-302; contract tech/app-offline-quick-change.md section 2.1): public.set_lot_rack_and_mark(p_lot_id,
-- p_changes, p_request_key), the one narrow write of a lot's rack and package mark, so a phone can send "this lot's rack is now C-2" without
-- the whole GRN. It needs the topics "GRN field marks" and "replaced entries" (applied before it).
--  1. The function. Order: gate (the role list of migrations/definitions/00_authorize_rpc.sql) -> shape of p_changes and the request key ->
--     request-key replay -> the lot's GRN and then the lot locked FOR UPDATE -> checks -> write -> the answer is kept under the key.
--     p_changes = { rack?: {to, from}, package_mark?: {to, from}, recorded_at?: ISO time }. recorded_at is not a field: it is the phone time
--     of the change, passed to the writer of replaced entries; alone, or with an unknown key or a value that is not a time, it is
--     LOT_CHANGE_INVALID. Values are trimmed, given the digits 0-9 and a blank becomes NULL (to and from alike); then rack is limited to 30
--     and mark to 60 characters (RACK_TOO_LONG, MARK_TOO_LONG with `limit`). Only the lot's rack and package_mark and its GRN's
--     updated_at/updated_by are written, and the GRN's change mark moves only when a value was written (an Edit GRN opened before is then
--     refused STALE_RECORD). Last sent wins per field: a stored value that differs from both `from` and `to` is replaced and
--     warehouse_security.record_grn_replacement names it in `replaced` (no entry when the caller set it themselves). A deactivated
--     customer's lot, a dispatched, billed or on-order lot, and a GRN with no sender or supervisor are all accepted.
--     The answer of a success is kept in idempotency_keys with no expiry (expires_at infinity, so the purge never takes it); a repeat of
--     the key gets that first answer plus idempotent true after any delay and writes nothing; the same key for another lot is refused
--     REQUEST_KEY_REUSED. A refusal keeps nothing, so the key can be used again.
--  2. The imported guard (warehouse_security.refuse_imported_change, migration 190) lets an imported GRN's line change rack and package_mark
--     only while the transaction-local setting warehouse.lot_place is 'on', and only when nothing else of the line differs. Only this
--     function sets it, around its one UPDATE; it is put back at once, so the rest of the transaction is refused as before.
--  3. get_submission_result finds this function's answers while the lot exists (the key's 7-day rule does not apply: expires_at is infinity).
-- Patched by marker count (a second run fails on the count). No role is created, altered or dropped; no pg_temp helper is left behind.

-- ===== 2. the imported guard =====
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$            AND (to_jsonb(NEW) - 'stock') = (to_jsonb(OLD) - 'stock')) THEN$m$
  ];
  v_new constant text[] := ARRAY[
    $m$            AND (to_jsonb(NEW) - 'stock') = (to_jsonb(OLD) - 'stock'))
       -- Topic "lot rack and mark change": set_lot_rack_and_mark alone may change rack and package_mark of the line (nothing else).
       AND NOT (TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'goodsreceived_trl'
            AND current_setting('warehouse.lot_place', true) = 'on'
            AND (to_jsonb(NEW) - ARRAY['rack', 'package_mark']) = (to_jsonb(OLD) - ARRAY['rack', 'package_mark'])) THEN$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('warehouse_security.refuse_imported_change()'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'refuse_imported_change: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- ===== 1. the function =====
CREATE FUNCTION public.set_lot_rack_and_mark(p_lot_id uuid, p_changes jsonb, p_request_key text)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_profile uuid;
  v_key text := btrim(p_request_key);
  v_has_rack boolean;
  v_has_mark boolean;
  v_field text;
  v_part jsonb;
  v_recorded timestamptz;
  v_to_rack text;
  v_from_rack text;
  v_to_mark text;
  v_from_mark text;
  v_kept record;
  v_gr_id uuid;
  v_gr_no text;
  v_cur_rack text;
  v_cur_mark text;
  v_set_rack boolean := false;
  v_set_mark boolean := false;
  v_changed text[] := ARRAY[]::text[];
  v_replaced jsonb := '[]'::jsonb;
  v_entry jsonb;
  v_prev_place text;
  v_answer jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('set_lot_rack_and_mark', jsonb_build_object('p_lot_id', p_lot_id));
  SELECT p.id INTO v_profile FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();
  IF v_profile IS NULL THEN
    RAISE EXCEPTION 'Active account required' USING ERRCODE = '42501';
  END IF;

  -- The shape of the change.
  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' OR v_key IS NULL OR v_key = ''
     OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_changes) AS k WHERE k NOT IN ('rack', 'package_mark', 'recorded_at')) THEN
    RETURN warehouse_security.refuse('LOT_CHANGE_INVALID', 'The change is not understood.');
  END IF;
  v_has_rack := p_changes ? 'rack';
  v_has_mark := p_changes ? 'package_mark';
  IF NOT (v_has_rack OR v_has_mark) THEN
    RETURN warehouse_security.refuse('LOT_CHANGE_INVALID', 'There is nothing to change.');
  END IF;
  FOREACH v_field IN ARRAY ARRAY['rack', 'package_mark'] LOOP
    CONTINUE WHEN NOT (p_changes ? v_field);
    v_part := p_changes -> v_field;
    IF jsonb_typeof(v_part) <> 'object' OR NOT (v_part ? 'to')
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(v_part) AS k WHERE k NOT IN ('to', 'from'))
       OR jsonb_typeof(v_part -> 'to') NOT IN ('string', 'null')
       OR (v_part ? 'from' AND jsonb_typeof(v_part -> 'from') NOT IN ('string', 'null')) THEN
      RETURN warehouse_security.refuse('LOT_CHANGE_INVALID', 'The change is not understood.');
    END IF;
  END LOOP;
  IF p_changes ? 'recorded_at' AND jsonb_typeof(p_changes -> 'recorded_at') <> 'null' THEN
    IF jsonb_typeof(p_changes -> 'recorded_at') <> 'string' THEN
      RETURN warehouse_security.refuse('LOT_CHANGE_INVALID', 'The time of the change is not understood.');
    END IF;
    BEGIN
      v_recorded := (p_changes ->> 'recorded_at')::timestamptz;
    EXCEPTION WHEN others THEN
      RETURN warehouse_security.refuse('LOT_CHANGE_INVALID', 'The time of the change is not understood.');
    END;
  END IF;

  -- Normalised: trimmed, the digits 0-9, blank is NULL; then the limits.
  IF v_has_rack THEN
    v_to_rack := NULLIF(btrim(warehouse_security.ascii_digits(p_changes #>> '{rack,to}')), '');
    v_from_rack := NULLIF(btrim(warehouse_security.ascii_digits(p_changes #>> '{rack,from}')), '');
    IF char_length(v_to_rack) > 30 THEN
      RETURN warehouse_security.refuse('RACK_TOO_LONG', 'The rack can be at most 30 characters.', jsonb_build_object('limit', 30));
    END IF;
  END IF;
  IF v_has_mark THEN
    v_to_mark := NULLIF(btrim(warehouse_security.ascii_digits(p_changes #>> '{package_mark,to}')), '');
    v_from_mark := NULLIF(btrim(warehouse_security.ascii_digits(p_changes #>> '{package_mark,from}')), '');
    IF char_length(v_to_mark) > 60 THEN
      RETURN warehouse_security.refuse('MARK_TOO_LONG', 'The package mark can be at most 60 characters.', jsonb_build_object('limit', 60));
    END IF;
  END IF;

  -- A repeated send gets the first answer. Two sends of one key at once are taken one after the other.
  PERFORM pg_advisory_xact_lock(hashtextextended('set_lot_rack_and_mark:' || v_key, 0));
  SELECT k.rpc_function, k.created_by, k.expires_at, k.response INTO v_kept
    FROM public.idempotency_keys k WHERE k.idempotency_key = v_key;
  IF FOUND THEN
    IF v_kept.rpc_function = 'set_lot_rack_and_mark' AND v_kept.created_by IS NOT DISTINCT FROM v_profile
       AND v_kept.response #>> '{lot,id}' = p_lot_id::text THEN
      RETURN v_kept.response || jsonb_build_object('idempotent', true);
    ELSIF v_kept.expires_at IS NULL OR v_kept.expires_at > now() THEN
      RETURN warehouse_security.refuse('REQUEST_KEY_REUSED', 'This request key was already used for another change.');
    END IF;
  END IF;

  -- The refresh lock before any row lock (migration 46), as update_grn and apply_grn_changes take it.
  PERFORM pg_advisory_xact_lock(71040);

  -- The GRN first, then its lot.
  SELECT t.gr_id INTO v_gr_id FROM public.goodsreceived_trl t WHERE t.id = p_lot_id;
  IF v_gr_id IS NOT NULL THEN
    SELECT g.gr_no INTO v_gr_no FROM public.goodsreceived g WHERE g.id = v_gr_id AND g.deleted_at IS NULL FOR UPDATE;
  END IF;
  IF v_gr_no IS NULL THEN
    RETURN warehouse_security.refuse('LOT_NOT_FOUND', 'This lot is no longer there.');
  END IF;
  SELECT NULLIF(btrim(warehouse_security.ascii_digits(t.rack)), ''), NULLIF(btrim(warehouse_security.ascii_digits(t.package_mark)), '')
    INTO v_cur_rack, v_cur_mark
    FROM public.goodsreceived_trl t WHERE t.id = p_lot_id AND t.gr_id = v_gr_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN warehouse_security.refuse('LOT_NOT_FOUND', 'This lot is no longer there.');
  END IF;

  -- Last sent wins per field. The replaced entry is recorded before the write: the write moves the field mark it reads.
  IF v_has_rack AND v_to_rack IS DISTINCT FROM v_cur_rack THEN
    v_set_rack := true;
    v_changed := array_append(v_changed, 'rack');
    IF v_from_rack IS DISTINCT FROM v_cur_rack THEN
      v_entry := warehouse_security.record_grn_replacement(v_gr_id, p_lot_id, 'rack', v_cur_rack, v_to_rack, v_profile, v_key, v_recorded);
      IF v_entry IS NOT NULL THEN v_replaced := v_replaced || jsonb_build_array(v_entry); END IF;
    END IF;
  END IF;
  IF v_has_mark AND v_to_mark IS DISTINCT FROM v_cur_mark THEN
    v_set_mark := true;
    v_changed := array_append(v_changed, 'package_mark');
    IF v_from_mark IS DISTINCT FROM v_cur_mark THEN
      v_entry := warehouse_security.record_grn_replacement(v_gr_id, p_lot_id, 'package_mark', v_cur_mark, v_to_mark, v_profile, v_key, v_recorded);
      IF v_entry IS NOT NULL THEN v_replaced := v_replaced || jsonb_build_array(v_entry); END IF;
    END IF;
  END IF;

  IF v_set_rack OR v_set_mark THEN
    -- The imported guard is opened for this one statement and put back at once.
    v_prev_place := current_setting('warehouse.lot_place', true);
    PERFORM set_config('warehouse.lot_place', 'on', true);
    UPDATE public.goodsreceived_trl t
       SET rack = CASE WHEN v_set_rack THEN v_to_rack ELSE t.rack END,
           package_mark = CASE WHEN v_set_mark THEN v_to_mark ELSE t.package_mark END
     WHERE t.id = p_lot_id;
    PERFORM set_config('warehouse.lot_place', COALESCE(v_prev_place, ''), true);
    -- The GRN's change mark: an Edit GRN loaded before this is refused as out of date.
    UPDATE public.goodsreceived g SET updated_at = now(), updated_by = v_profile WHERE g.id = v_gr_id;
  END IF;

  SELECT jsonb_build_object(
      'success', true,
      'lot', jsonb_build_object('id', t.id, 'gr_id', t.gr_id, 'rack', t.rack, 'package_mark', t.package_mark),
      'grn', jsonb_build_object('id', g.id, 'gr_no', g.gr_no, 'updated_at', g.updated_at),
      'changed', to_jsonb(v_changed),
      'replaced', v_replaced)
    INTO v_answer
    FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE t.id = p_lot_id;

  -- Kept with no expiry (infinity), so the repeat of an old key is still answered. Only an expired key of another function is taken over.
  INSERT INTO public.idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
  VALUES (v_key, 'set_lot_rack_and_mark', v_answer, v_profile, 'infinity')
  ON CONFLICT (idempotency_key) DO UPDATE SET
    rpc_function = EXCLUDED.rpc_function, response = EXCLUDED.response, created_by = EXCLUDED.created_by,
    created_at = now(), expires_at = EXCLUDED.expires_at
  WHERE idempotency_keys.expires_at <= now();
  RETURN v_answer;
END $$;
ALTER FUNCTION public.set_lot_rack_and_mark(uuid, jsonb, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.set_lot_rack_and_mark(uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_lot_rack_and_mark(uuid, jsonb, text) TO authenticated, service_role;

-- ===== 3. get_submission_result finds the answer while the lot exists =====
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$            WHEN 'delete_payment' THEN true
$m$
  ];
  v_new constant text[] := ARRAY[
    $m$            WHEN 'delete_payment' THEN true
            WHEN 'set_lot_rack_and_mark' THEN EXISTS (SELECT 1 FROM goodsreceived_trl t WHERE t.id::text = k.response #>> '{lot,id}')
$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.get_submission_result(text)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'get_submission_result: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

NOTIFY pgrst, 'reload schema';
