-- A receipt's unfinished photos follow the image row rules inside the RPCs as well (external review
-- 2026-10-13, SEC-1 and SEC-2).
--
-- The row rules for grn_images (migrations 18, 42, 43): administrators and supervisors read every
-- row; staff read confirmed rows and the pending rows they registered; a customer reads confirmed
-- rows of its own receipts. cancel_grn_image_upload (23) and delete_grn_image (45) allow the same
-- rows to be removed. Two SECURITY DEFINER functions did not apply them:
--
--   SEC-1 get_grn_details listed every image row of the receipt in header_images and in each line's
--         item_images, so a customer or another staff member got a pending upload's path, file name,
--         size, type and uploader. Both lists now hold only the rows the caller may read.
--   SEC-2 update_grn, given a non-empty p_images, deleted every image row of the receipt that the list
--         did not name, so a staff edit removed another person's pending upload, which that person
--         could then not confirm. Only the omitted rows the caller may read are removed now: an
--         administrator or supervisor still removes any omitted row; staff remove confirmed rows and
--         their own pending ones. A row the caller may not read that the list names (by id or path)
--         is kept as it is: not moved to another line, not counted, and not attached a second time.
--         The answer's grn.images lists the rows the caller may read.
--   Three more readers found while fixing SEC-1 apply the rule to their image subqueries (filter only;
--   keys, types and rows unchanged): get_customer_items_for_order_selection gave a customer the
--   storage path of a pending upload as image_url; get_invoiceable_grns' gr_image_url likewise for
--   staff; get_customer_grn_activity counted every image row in image_count and total_images (its text
--   as migration 63 leaves it).
--
-- The rule is one helper, warehouse_security.grn_image_visible(status, uploaded_by), called by the five
-- definer functions; it is not granted to the app roles. Customer ownership of the receipt stays where
-- it was: each function's own customer check (get_invoiceable_grns and update_grn are not open to
-- customers).
--
-- Method: the current definitions are patched (each replaced text must occur exactly as often as
-- stated); SECURITY DEFINER, settings, grants and owner are checked unchanged. Migration 65 patches
-- other text of update_grn (the line checks and the image "keep" UPDATE's WHERE); the markers here do
-- not overlap it, so this migration applies with or without 65.

CREATE FUNCTION warehouse_security.grn_image_visible(p_status text, p_uploaded_by uuid) RETURNS boolean
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT CASE
    WHEN auth.jwt()->>'role' = 'service_role' THEN true
    WHEN warehouse_security.active_role() IN ('admin', 'supervisor') THEN true
    WHEN warehouse_security.active_role() = 'staff'
      THEN COALESCE(p_status = 'confirmed' OR p_uploaded_by = public.get_current_user_profile_id(), false)
    ELSE COALESCE(p_status = 'confirmed', false)
  END
$$;
REVOKE ALL ON FUNCTION warehouse_security.grn_image_visible(text, uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION warehouse_security.grn_image_visible(text, uuid) IS
  'True when the caller may read a grn_images row with this status and uploader (admin/supervisor: all; staff: confirmed or own; others: confirmed). Receipt ownership is checked by the caller.';

CREATE FUNCTION pg_temp.replace_marker(fn text, definition text, marker text, replacement text, expected integer) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE occurrences integer := (length(definition) - length(replace(definition, marker, ''))) / length(marker);
BEGIN
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker, 80);
  END IF;
  RETURN replace(definition, marker, replacement);
END $$;

DO $migration$
DECLARE
  change record;
  current_fn text := '';
  definition text;
  update_grn_fn text;
  before_state jsonb;
  after_state jsonb;
BEGIN
  -- update_grn has one signature (migration 47 dropped the older one).
  SELECT p.oid::regprocedure::text INTO STRICT update_grn_fn FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'update_grn';
  SELECT jsonb_object_agg(p.oid::regprocedure::text, jsonb_build_array(p.prosecdef, p.proconfig, p.proacl::text[], p.proowner))
    INTO before_state
  FROM pg_proc p WHERE p.oid IN ('public.get_grn_details(uuid)'::regprocedure, update_grn_fn::regprocedure,
    'public.get_customer_items_for_order_selection(uuid,integer,integer,text,integer,varchar)'::regprocedure,
    'public.get_invoiceable_grns(integer,integer,text)'::regprocedure,
    'public.get_customer_grn_activity(uuid,date,date)'::regprocedure);

  FOR change IN SELECT * FROM (VALUES
    -- SEC-1: the header photos and each line's photos.
    (1, 'public.get_grn_details(uuid)',
     $b$AND gi.image_type = 'header'$b$,
     $a$AND gi.image_type = 'header'
                            AND warehouse_security.grn_image_visible(gi.status, gi.uploaded_by)$a$, 1),
    (2, 'public.get_grn_details(uuid)',
     $b$AND gi2.image_type = 'item'$b$,
     $a$AND gi2.image_type = 'item'
                                            AND warehouse_security.grn_image_visible(gi2.status, gi2.uploaded_by)$a$, 1),

    -- SEC-2: a named row the caller may not read is kept as it is (the branch before the "keep"
    -- UPDATE, whose text migration 65 changes, and before the INSERT of a new attachment) ...
    (10, update_grn_fn,
     $b$                IF v_image_id IS NOT NULL THEN$b$,
     $a$                IF v_image_id IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM grn_images seen
                    WHERE seen.id = v_image_id
                    AND warehouse_security.grn_image_visible(seen.status, seen.uploaded_by)) THEN
                    -- Migration 69: another person's pending photo, named in the list, stays as it is.
                    v_kept_image_ids := array_append(v_kept_image_ids, v_image_id);
                ELSIF v_image_id IS NOT NULL THEN$a$, 1),
    -- ... the omitted rows removed are those the caller may read ...
    (11, update_grn_fn,
     $b$            DELETE FROM grn_images
            WHERE grn_id = p_grn_id
            AND id NOT IN (SELECT unnest(v_kept_image_ids));$b$,
     $a$            DELETE FROM grn_images
            WHERE grn_id = p_grn_id
            AND id NOT IN (SELECT unnest(v_kept_image_ids))
            AND warehouse_security.grn_image_visible(grn_images.status, grn_images.uploaded_by);$a$, 1),
    -- ... and the answer lists the rows the caller may read.
    (12, update_grn_fn,
     $b$        FROM grn_images i
        WHERE i.grn_id = p_grn_id;$b$,
     $a$        FROM grn_images i
        WHERE i.grn_id = p_grn_id
        AND warehouse_security.grn_image_visible(i.status, i.uploaded_by);$a$, 1),

    -- The three other readers: the first photo of a receipt shown in the order picker ...
    (20, 'public.get_customer_items_for_order_selection(uuid,integer,integer,text,integer,varchar)',
     $b$(SELECT storage_path FROM grn_images gi WHERE gi.grn_id = gr.id LIMIT 1)$b$,
     $a$(SELECT storage_path FROM grn_images gi WHERE gi.grn_id = gr.id AND warehouse_security.grn_image_visible(gi.status, gi.uploaded_by) LIMIT 1)$a$, 1),
    -- ... the header photo in the invoice picker (the two-argument overload reads no image) ...
    (30, 'public.get_invoiceable_grns(integer,integer,text)',
     $b$(SELECT storage_path FROM grn_images WHERE grn_id = gr.id AND image_type = 'header' LIMIT 1)$b$,
     $a$(SELECT storage_path FROM grn_images WHERE grn_id = gr.id AND image_type = 'header' AND warehouse_security.grn_image_visible(grn_images.status, grn_images.uploaded_by) LIMIT 1)$a$, 1),
    -- ... and the photo count of the GRN activity report.
    (40, 'public.get_customer_grn_activity(uuid,date,date)',
     $b$            FROM grn_images
            GROUP BY grn_id$b$,
     $a$            FROM grn_images
            WHERE warehouse_security.grn_image_visible(grn_images.status, grn_images.uploaded_by)
            GROUP BY grn_id$a$, 1)
  ) AS changes(step, signature, before_text, after_text, times)
  ORDER BY step
  LOOP
    IF change.signature <> current_fn THEN
      IF current_fn <> '' THEN EXECUTE definition; END IF;
      current_fn := change.signature;
      definition := pg_get_functiondef(current_fn::regprocedure);
    END IF;
    definition := pg_temp.replace_marker(current_fn, definition, change.before_text, change.after_text, change.times);
  END LOOP;
  EXECUTE definition;

  SELECT jsonb_object_agg(p.oid::regprocedure::text, jsonb_build_array(p.prosecdef, p.proconfig, p.proacl::text[], p.proowner))
    INTO after_state
  FROM pg_proc p WHERE p.oid IN ('public.get_grn_details(uuid)'::regprocedure, update_grn_fn::regprocedure,
    'public.get_customer_items_for_order_selection(uuid,integer,integer,text,integer,varchar)'::regprocedure,
    'public.get_invoiceable_grns(integer,integer,text)'::regprocedure,
    'public.get_customer_grn_activity(uuid,date,date)'::regprocedure);
  IF after_state IS DISTINCT FROM before_state OR (SELECT count(*) FROM jsonb_object_keys(before_state)) <> 5 THEN
    RAISE EXCEPTION 'A patched function changed its SECURITY DEFINER, settings, grants or owner: % became %', before_state, after_state;
  END IF;
END;
$migration$;

DROP FUNCTION pg_temp.replace_marker(text, text, text, text, integer);
NOTIFY pgrst, 'reload schema';
