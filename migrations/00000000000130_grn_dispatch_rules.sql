-- Migration 130: GRN and dispatch input rules, and the housekeeping that goes with them.
--
-- The functions that have a definition file (save_grn, update_grn, create_dispatch_with_stock_check_internal, update_dispatch_smart) carry
-- their part of these rules in migrations/definitions/; this file holds the rest.
--
-- Section 1  (D15) delete_grn_image refuses to delete the last confirmed photo of a GRN (reason GRN_PHOTO_REQUIRED). update_grn refuses a
--            photo list that leaves a GRN that had a photo with none (same reason; definition file).
-- Section 2  (D17) dispatch.registration holds 20 characters, like the GRN's (migration 121). No view reads the column, so the type
--            change needs no view to be made again. Both dispatch writers refuse a longer one with registration_too_long (definition files).
-- Section 3  (App 34) check_dispatch_exists refuses a number with whitespace (reason DISPATCH_NUMBER_SPACES), like the dispatch create and
--            update (definition files) and, for a new GRN, save_grn (reason GRN_NUMBER_SPACES). Stored rows are untouched.
-- Section 4  (App 42) search_customer_items_for_order: an all-digit search (type auto, no weight given) finds the lots of that exact weight
--            and also the lots whose item name, package mark or GRN number contains the digits ("4455" finds MK4455, "50" still lists
--            the 50 kg lots). The type "weight" (asked for by name) stays an exact-weight search. The count follows.
-- Section 5  (Backend 20) A dispatch is deleted only by delete_dispatch_with_order_cleanup. The BEFORE DELETE trigger refuses any other
--            DELETE on public.dispatch ("Delete dispatches with delete_dispatch_with_order_cleanup."); the function marks its own DELETE
--            with the transaction-local setting warehouse.dispatch_delete_via_rpc. The trigger's order-reset half stays, as the function
--            runs it (owner decision of 2026-10-21; tests/dispatch_delete_trigger.sql). Nothing else in the repository deletes
--            dispatch rows (checked: functions, scripts, seeds; the tests that did now set the setting around their own DELETE).
-- Section 6  (Backend 19) Unfinished photo uploads (grn_images and dispatch_images rows still 'pending' after 24 hours, from an upload the
--            phone never confirmed) are removed by the daily job (scripts/retention.sh, run by scripts/watch-daily.sh):
--            * warehouse_maintenance.expired_pending_images(bucket, now) names the files (grn-images, dispatch-images) of such rows; the
--              script removes them through the Storage API, as it does for expired PDFs (only the API removes the file from disk).
--            * warehouse_maintenance.delete_expired_pending_images(now) then deletes the rows whose file is gone from storage (or never
--              arrived). A row whose file could not be removed stays, and the next day tries again; a row confirmed meanwhile is not
--              pending any more and is never touched. A file that a confirmed row also names is never listed.
--
-- Patches use the marker-count pattern of migration 111: every marker must be found exactly the expected number of times, or the
-- migration stops.

-- Section 1: the last photo of a GRN stays
DO $patch$
DECLARE
  v_def text;
  v_old text[] := ARRAY[
    $m$    DELETE FROM grn_images WHERE id = p_image_id;$m$
  ];
  v_new text[] := ARRAY[
    $m$    -- Migration 130 (D15): a GRN that has a confirmed photo of the GRN book entry (image_type 'header') keeps one; photos of single
    -- items (image_type 'item') do not stand in for it and can always be deleted. The GRN row is locked, so two deletes of its last two
    -- photos at once cannot both pass. A photo that is not confirmed (an unfinished upload) is never the last one.
    IF EXISTS (SELECT 1 FROM grn_images WHERE id = p_image_id AND status = 'confirmed' AND image_type = 'header') THEN
        PERFORM 1 FROM goodsreceived g WHERE g.id = (SELECT i.grn_id FROM grn_images i WHERE i.id = p_image_id) FOR UPDATE;
        IF NOT EXISTS (SELECT 1 FROM grn_images o
                       WHERE o.grn_id = (SELECT i.grn_id FROM grn_images i WHERE i.id = p_image_id)
                         AND o.status = 'confirmed' AND o.image_type = 'header' AND o.id <> p_image_id) THEN
            RETURN warehouse_security.refuse('GRN_PHOTO_REQUIRED',
                'A GRN needs at least one photo. Add another before deleting this one.',
                jsonb_build_object('image_id', p_image_id,
                                   'grn_id', (SELECT i.grn_id FROM grn_images i WHERE i.id = p_image_id),
                                   'gr_no', (SELECT g.gr_no FROM grn_images i JOIN goodsreceived g ON g.id = i.grn_id WHERE i.id = p_image_id)));
        END IF;
    END IF;

    DELETE FROM grn_images WHERE id = p_image_id;$m$
  ];
  v_expected integer[] := ARRAY[1];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.delete_grn_image(uuid)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> v_expected[i] THEN
      RAISE EXCEPTION 'delete_grn_image: expected marker % % times, found % times', i, v_expected[i], v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- Section 2: the vehicle number of a dispatch holds 20 characters
ALTER TABLE public.dispatch ALTER COLUMN registration TYPE character varying(20);

-- Section 3: the dispatch number lookup refuses whitespace
DO $patch$
DECLARE
  v_def text;
  v_old text[] := ARRAY[
    $m$    SELECT id, disp_no, customer_name, disp_date INTO v_dispatch FROM dispatch WHERE disp_no = p_disp_no AND deleted_at IS NULL LIMIT 1;$m$
  ];
  v_new text[] := ARRAY[
    $m$    -- Migration 130: a dispatch number has no whitespace (a blank one is looked up as before).
    IF p_disp_no ~ '[[:space:]]|\u00a0' AND NOT warehouse_security.is_blank_text(p_disp_no) THEN
        RETURN warehouse_security.refuse('DISPATCH_NUMBER_SPACES', 'A dispatch number can''t contain spaces.',
            jsonb_build_object('number', p_disp_no));
    END IF;
    SELECT id, disp_no, customer_name, disp_date INTO v_dispatch FROM dispatch WHERE disp_no = p_disp_no AND deleted_at IS NULL LIMIT 1;$m$
  ];
  v_expected integer[] := ARRAY[1];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.check_dispatch_exists(text)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> v_expected[i] THEN
      RAISE EXCEPTION 'check_dispatch_exists: expected marker % % times, found % times', i, v_expected[i], v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- Section 4: an all-digit search is a weight or a text
DO $patch$
DECLARE
  v_def text;
  v_old text[] := ARRAY[
    $m$    v_is_admin BOOLEAN;$m$,
    $m$        v_weight_max_final := v_weight_min_final;$m$,
    $m$OR (v_search_type_final = 'weight_exact' AND grt.weight = v_weight_min_final)$m$
  ];
  v_new text[] := ARRAY[
    $m$    v_is_admin BOOLEAN;
    v_digits_are_text_too BOOLEAN := false;$m$,
    $m$        v_weight_max_final := v_weight_min_final;
        -- Migration 130: digits typed in the search box are also looked for in the text columns.
        v_digits_are_text_too := p_search_type = 'auto' AND p_weight_min IS NULL;$m$,
    $m$OR (v_search_type_final = 'weight_exact' AND (
                    grt.weight = v_weight_min_final
                    OR (v_digits_are_text_too AND (
                        grt.item_name ILIKE '%' || p_search_query || '%'
                        OR grt.package_mark ILIKE '%' || p_search_query || '%'
                        OR gr.gr_no ILIKE '%' || p_search_query || '%'
                    ))
                ))$m$
  ];
  v_expected integer[] := ARRAY[1, 1, 2];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef(to_regprocedure('public.search_customer_items_for_order(text, uuid, text, integer, integer, integer, uuid, numeric, numeric)'));
  IF v_def IS NULL THEN RAISE EXCEPTION 'search_customer_items_for_order: signature not found'; END IF;
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> v_expected[i] THEN
      RAISE EXCEPTION 'search_customer_items_for_order: expected marker % % times, found % times', i, v_expected[i], v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- Section 5: no direct DELETE of a dispatch
DO $patch$
DECLARE
  v_def text;
  v_old text[] := ARRAY[
    $m$    -- Restore stock for all items in this dispatch (capped at qty), and log$m$
  ];
  v_new text[] := ARRAY[
    $m$    -- Migration 130: only delete_dispatch_with_order_cleanup deletes a dispatch (it sets this transaction-local flag).
    IF current_setting('warehouse.dispatch_delete_via_rpc', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'Delete dispatches with delete_dispatch_with_order_cleanup.' USING ERRCODE = 'WH409';
    END IF;

    -- Restore stock for all items in this dispatch (capped at qty), and log$m$
  ];
  v_expected integer[] := ARRAY[1];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.restore_stock_on_dispatch_delete()'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> v_expected[i] THEN
      RAISE EXCEPTION 'restore_stock_on_dispatch_delete: expected marker % % times, found % times', i, v_expected[i], v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

DO $patch$
DECLARE
  v_def text;
  v_old text[] := ARRAY[
    $m$    DELETE FROM dispatch WHERE id = p_dispatch_id;$m$
  ];
  v_new text[] := ARRAY[
    $m$    PERFORM set_config('warehouse.dispatch_delete_via_rpc', 'on', true);
    DELETE FROM dispatch WHERE id = p_dispatch_id;
    PERFORM set_config('warehouse.dispatch_delete_via_rpc', 'off', true);$m$
  ];
  v_expected integer[] := ARRAY[1];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.delete_dispatch_with_order_cleanup(uuid, uuid)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> v_expected[i] THEN
      RAISE EXCEPTION 'delete_dispatch_with_order_cleanup: expected marker % % times, found % times', i, v_expected[i], v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- Section 6: unfinished photo uploads older than 24 hours
-- These two functions read storage.objects, which the storage service creates after the migrations run (as in the baseline,
-- bodies are not checked at creation; they run only in maintenance, when the storage schema exists).
SET LOCAL check_function_bodies = false;
CREATE FUNCTION warehouse_maintenance.expired_pending_images(p_bucket text, p_now timestamp with time zone DEFAULT now()) RETURNS SETOF text
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public', 'warehouse_maintenance'
    AS $$
  SELECT o.name FROM storage.objects o
  WHERE o.bucket_id = p_bucket
    AND (
      (p_bucket = 'grn-images'
        AND EXISTS (SELECT 1 FROM public.grn_images i
                    WHERE i.storage_path = o.name AND i.status = 'pending' AND i.created_at < p_now - interval '24 hours')
        AND NOT EXISTS (SELECT 1 FROM public.grn_images c WHERE c.storage_path = o.name AND c.status IS DISTINCT FROM 'pending'))
      OR
      (p_bucket = 'dispatch-images'
        AND EXISTS (SELECT 1 FROM public.dispatch_images i
                    WHERE i.storage_path = o.name AND i.status = 'pending' AND i.created_at < p_now - interval '24 hours')
        AND NOT EXISTS (SELECT 1 FROM public.dispatch_images c WHERE c.storage_path = o.name AND c.status IS DISTINCT FROM 'pending'))
    )
  ORDER BY o.name
$$;
ALTER FUNCTION warehouse_maintenance.expired_pending_images(p_bucket text, p_now timestamp with time zone) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_maintenance.expired_pending_images(p_bucket text, p_now timestamp with time zone) FROM PUBLIC;

CREATE FUNCTION warehouse_maintenance.delete_expired_pending_images(p_now timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE sql
    SET search_path TO 'pg_catalog', 'public', 'warehouse_maintenance'
    AS $$
  WITH g AS (
    DELETE FROM public.grn_images i
    WHERE i.status = 'pending' AND i.created_at < p_now - interval '24 hours'
      AND NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'grn-images' AND o.name = i.storage_path)
    RETURNING 1
  ), d AS (
    DELETE FROM public.dispatch_images i
    WHERE i.status = 'pending' AND i.created_at < p_now - interval '24 hours'
      AND NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'dispatch-images' AND o.name = i.storage_path)
    RETURNING 1
  )
  SELECT jsonb_build_object('grn_images', (SELECT count(*) FROM g), 'dispatch_images', (SELECT count(*) FROM d))
$$;
ALTER FUNCTION warehouse_maintenance.delete_expired_pending_images(p_now timestamp with time zone) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_maintenance.delete_expired_pending_images(p_now timestamp with time zone) FROM PUBLIC;
RESET check_function_bodies;
