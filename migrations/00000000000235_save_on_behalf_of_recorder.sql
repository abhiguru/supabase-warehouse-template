-- Topic "save on behalf of the recorder" (WH-304; contract tech/app-offline-holding-list.md sections 2.6 and 11.4). Named by topic; its number
-- is taken when the work is assembled for main. It needs WH-303's topics ("edit GRN by field changes": apply_grn_changes and the field marks)
-- and WH-302's ("lot rack and mark change": set_lot_rack_and_mark) applied before it. save_grn and the dispatch save are changed in their
-- definition files (migrations/definitions/save_grn.sql, create_dispatch_with_stock_check_internal.sql), not here.
--  1. goodsreceived.accepted_by and dispatch.accepted_by (uuid, NULL on every ordinary save): the supervisor or administrator who accepted
--     the held item that made the document.
--  2. warehouse_security.acting_profile(): the profile of the person a held item is saved for. It answers only while decide_held_item or the
--     trial of get_held_item has set the transaction-local setting warehouse.held_acting AND the caller is an administrator or a
--     supervisor; every other call answers NULL, so a save behaves exactly as before. The role gate and every "needs a manager" check keep
--     reading the caller (the accepting person).
--  3. The five saves read the acting person through it: set_lot_rack_and_mark and apply_grn_changes (the person of the request key, of the
--     replaced entries and of updated_by) and the two field-mark triggers (who set a field, which decides whether a later change is a
--     "replaced entry"). The photo attach of a held item is in decide_held_item.
-- Patched by text with marker counts. No role is created, altered or dropped; the pg_temp helper is dropped at the end.

-- ===== 1. who accepted =====
ALTER TABLE public.goodsreceived ADD COLUMN accepted_by uuid REFERENCES public.user_profiles(id);
ALTER TABLE public.dispatch ADD COLUMN accepted_by uuid REFERENCES public.user_profiles(id);
COMMENT ON COLUMN public.goodsreceived.accepted_by IS 'WH-304: the supervisor or administrator who accepted the held item that made this GRN; NULL for a GRN saved in the ordinary way.';
COMMENT ON COLUMN public.dispatch.accepted_by IS 'WH-304: the supervisor or administrator who accepted the held item that made this dispatch; NULL for a dispatch saved in the ordinary way.';

-- ===== 2. the acting person =====
CREATE FUNCTION warehouse_security.acting_profile() RETURNS uuid
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
DECLARE
  v_setting text := current_setting('warehouse.held_acting', true);
BEGIN
  IF v_setting IS NULL OR v_setting = '' OR v_setting !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RETURN NULL;
  END IF;
  -- Only the accepting administrator or supervisor can act for the recorder; any other caller is itself.
  IF COALESCE(warehouse_security.active_role(), '') NOT IN ('admin', 'supervisor') THEN
    RETURN NULL;
  END IF;
  RETURN v_setting::uuid;
END $$;
ALTER FUNCTION warehouse_security.acting_profile() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.acting_profile() FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION warehouse_security.acting_profile() IS
  'WH-304: the profile a held item is saved for while decide_held_item (or its trial) runs for an administrator or supervisor; NULL at every other time.';

-- ===== 3. the saves =====
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

SELECT pg_temp.patch_function('public.set_lot_rack_and_mark(uuid, jsonb, text)'::regprocedure, ARRAY[
$m$SELECT p.id INTO v_profile FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();$m$
], ARRAY[
$m$SELECT p.id INTO v_profile FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();
  -- WH-304: a held change accepted by a supervisor or administrator is the recorder's (request key owner, replaced entry, updated_by).
  v_profile := COALESCE(warehouse_security.acting_profile(), v_profile);$m$
]);

SELECT pg_temp.patch_function('public.apply_grn_changes(uuid, jsonb, text)'::regprocedure, ARRAY[
$m$SELECT p.id INTO v_profile FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();$m$
], ARRAY[
$m$SELECT p.id INTO v_profile FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();
  -- WH-304: a held edit accepted by a supervisor or administrator is the recorder's (request key owner, replaced entries).
  v_profile := COALESCE(warehouse_security.acting_profile(), v_profile);$m$
]);

SELECT pg_temp.patch_function('warehouse_security.record_lot_field_marks()'::regprocedure, ARRAY[
$m$SELECT p.id INTO v_by FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();$m$
], ARRAY[
$m$SELECT p.id INTO v_by FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();
    -- WH-304: a field written by an accepted held item was set by the recorder.
    v_by := COALESCE(warehouse_security.acting_profile(), v_by);$m$
]);

SELECT pg_temp.patch_function('warehouse_security.record_grn_field_marks()'::regprocedure, ARRAY[
$m$SELECT p.id INTO v_by FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();$m$
], ARRAY[
$m$SELECT p.id INTO v_by FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();
    -- WH-304: a field written by an accepted held item was set by the recorder.
    v_by := COALESCE(warehouse_security.acting_profile(), v_by);$m$
]);

-- A customer account's copy never holds who accepted a document (an internal staff id, as created_by).
SELECT pg_temp.patch_function('warehouse_sync.customer_hidden_columns()'::regprocedure, ARRAY[
$m$, 'uploaded_by'$m$
], ARRAY[
$m$, 'uploaded_by', 'accepted_by'$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
