-- An image row is confirmed only for a file in its own document's folder
-- (review, 2026-10-10).
--
-- The customer read policies on storage.objects (scripts/configure-storage.sql)
-- let a customer download every object whose name equals the storage_path of a
-- confirmed grn_images / dispatch_images row of a document that customer owns.
-- Three entry points wrote such a row with a path the caller chose, as
-- 'confirmed' (the column default), without looking at the path or the bucket:
-- upload_grn_image, the p_images list of save_grn and the p_images list of
-- update_grn. One staff call for customer B's receipt naming customer A's
-- object therefore made A's photo downloadable by B; a path that was never
-- uploaded left a confirmed row with no file. update_grn also accepted the id
-- of an image of another receipt and re-linked it, and an item image could be
-- tied to a line of another receipt. upload_dispatch_image had the same body
-- (it is not part of the granted API, but is tightened alike).
--
-- Rule from here on, enforced in the database for every entry point:
--   * the path lies in the folder the register RPCs issue for that document:
--     grn-images       headers/<grn id>/...  or  items/<grn id>/...
--     dispatch-images  <dispatch id>/...
--   * an object with that name exists in the bucket;
--   * no other image row carries the path;
--   * an item image's line belongs to the receipt.
-- A row that was not checked is 'pending' (new column default), which no
-- customer policy matches. The app's flow (register, upload, confirm; update_grn
-- sending back the images already on the receipt by id) is unchanged.

CREATE FUNCTION warehouse_security.image_path_prefix(p_kind text, p_document_id uuid, p_image_type text)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog
AS $$
  SELECT CASE
    WHEN p_document_id IS NULL THEN NULL
    WHEN p_kind = 'dispatch' THEN p_document_id::text || '/'
    WHEN p_kind = 'grn' AND p_image_type = 'header' THEN 'headers/' || p_document_id::text || '/'
    WHEN p_kind = 'grn' AND p_image_type = 'item' THEN 'items/' || p_document_id::text || '/'
  END
$$;

-- NULL when the path may be attached to the document, otherwise the reason.
-- p_except_image_id is the row being confirmed, which already carries the path.
CREATE FUNCTION warehouse_security.image_path_refusal(
  p_kind text, p_document_id uuid, p_image_type text, p_storage_path text, p_except_image_id uuid DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  prefix text := warehouse_security.image_path_prefix(p_kind, p_document_id, p_image_type);
  bucket text := CASE p_kind WHEN 'grn' THEN 'grn-images' WHEN 'dispatch' THEN 'dispatch-images' END;
  document_word text := CASE p_kind WHEN 'grn' THEN 'GRN' ELSE 'dispatch' END;
  taken boolean;
BEGIN
  IF bucket IS NULL THEN RAISE EXCEPTION 'Unknown image kind %', p_kind; END IF;
  IF p_storage_path IS NULL OR btrim(p_storage_path) = '' THEN RETURN 'Image path is required'; END IF;
  IF prefix IS NULL OR NOT starts_with(p_storage_path, prefix) OR length(p_storage_path) = length(prefix)
     OR p_storage_path ~ '(^|/)\.{1,2}(/|$)' OR p_storage_path LIKE '%//%' THEN
    RETURN format('Image path does not belong to this %s', document_word);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = bucket AND o.name = p_storage_path) THEN
    RETURN 'Image file is not in storage';
  END IF;
  IF p_kind = 'grn' THEN
    SELECT EXISTS (SELECT 1 FROM public.grn_images i
      WHERE i.storage_path = p_storage_path AND i.id IS DISTINCT FROM p_except_image_id) INTO taken;
  ELSE
    SELECT EXISTS (SELECT 1 FROM public.dispatch_images i
      WHERE i.storage_path = p_storage_path AND i.id IS DISTINCT FROM p_except_image_id) INTO taken;
  END IF;
  IF taken THEN RETURN 'Image path is attached to a different image record'; END IF;
  RETURN NULL;
END $$;

CREATE FUNCTION warehouse_security.require_image_path(
  p_kind text, p_document_id uuid, p_image_type text, p_storage_path text
) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE refusal text := warehouse_security.image_path_refusal(p_kind, p_document_id, p_image_type, p_storage_path);
BEGIN
  IF refusal IS NOT NULL THEN RAISE EXCEPTION '%', refusal USING ERRCODE = '22023'; END IF;
END $$;

REVOKE ALL ON FUNCTION warehouse_security.image_path_prefix(text, uuid, text),
  warehouse_security.image_path_refusal(text, uuid, text, text, uuid),
  warehouse_security.require_image_path(text, uuid, text, text) FROM PUBLIC, anon, authenticated;

-- A row inserted without a status has not been checked.
ALTER TABLE public.grn_images ALTER COLUMN status SET DEFAULT 'pending';
ALTER TABLE public.dispatch_images ALTER COLUMN status SET DEFAULT 'pending';

-- One-shot attach of a file that is already in the bucket. Only administrators
-- and supervisors can have put a file there without a registered row, so for
-- staff this path has nothing to attach; the app uses register and confirm.
CREATE OR REPLACE FUNCTION public.upload_grn_image(p_grn_id uuid, p_image_type character varying, p_storage_path text, p_original_filename text, p_file_size integer, p_mime_type character varying, p_grn_item_id uuid DEFAULT NULL::uuid, p_image_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_image_id UUID;
    v_user_id UUID;
    v_user_profile_id UUID;
    v_refusal text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('upload_grn_image',jsonb_build_object('p_grn_id',p_grn_id,'p_grn_item_id',p_grn_item_id));
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN utils.not_authenticated_response();
    END IF;

    SELECT id INTO v_user_profile_id FROM user_profiles WHERE auth_user_id = v_user_id;

    IF v_user_profile_id IS NULL THEN
        RETURN utils.error_response('USER_PROFILE_NOT_FOUND', 'User profile not found. Please contact support.');
    END IF;

    IF p_grn_id IS NULL OR p_image_type IS NULL OR p_storage_path IS NULL THEN
        RETURN utils.validation_error_response('parameters', 'Missing required parameters');
    END IF;

    IF p_grn_item_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM goodsreceived_trl WHERE id = p_grn_item_id AND gr_id = p_grn_id) THEN
        RETURN utils.validation_error_response('p_grn_item_id', 'Image line does not belong to this GRN');
    END IF;

    v_refusal := warehouse_security.image_path_refusal('grn', p_grn_id, p_image_type, p_storage_path);
    IF v_refusal IS NOT NULL THEN
        RETURN utils.validation_error_response('p_storage_path', v_refusal);
    END IF;

    v_image_id := COALESCE(p_image_id, gen_random_uuid());

    INSERT INTO grn_images (id, grn_id, grn_item_id, image_type, storage_path, original_filename, file_size, mime_type, uploaded_by, status)
    VALUES (v_image_id, p_grn_id, p_grn_item_id, p_image_type, p_storage_path, p_original_filename, p_file_size, p_mime_type, v_user_profile_id, 'confirmed');

    RETURN utils.success_response(
        jsonb_build_object('image_id', v_image_id, 'grn_id', p_grn_id, 'storage_path', p_storage_path, 'uploaded_by', v_user_profile_id),
        'Image uploaded successfully'
    );
EXCEPTION
    WHEN foreign_key_violation THEN
        RETURN utils.error_response('FOREIGN_KEY_ERROR', 'Database constraint error. Please check your data.');
    WHEN unique_violation THEN
        RETURN utils.error_response('DUPLICATE_IMAGE_ID', 'Image ID already exists. Please try again.');
    WHEN OTHERS THEN
        RETURN utils.database_error_response('Failed to upload image', SQLERRM, SQLSTATE);
END;
$$;

CREATE OR REPLACE FUNCTION public.upload_dispatch_image(p_dispatch_id uuid, p_storage_path text, p_original_filename text, p_file_size integer, p_mime_type character varying, p_image_id uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_image_id UUID;
    v_user_id UUID;
    v_user_profile_id UUID;
    v_refusal text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('upload_dispatch_image',jsonb_build_object('p_dispatch_id',p_dispatch_id));
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN RETURN utils.not_authenticated_response(); END IF;

    SELECT id INTO v_user_profile_id FROM user_profiles WHERE auth_user_id = v_user_id;
    IF v_user_profile_id IS NULL THEN RETURN utils.error_response('USER_PROFILE_NOT_FOUND', 'User profile not found.'); END IF;

    IF p_dispatch_id IS NULL OR p_storage_path IS NULL THEN
        RETURN utils.validation_error_response('parameters', 'Missing required parameters');
    END IF;

    v_refusal := warehouse_security.image_path_refusal('dispatch', p_dispatch_id, NULL, p_storage_path);
    IF v_refusal IS NOT NULL THEN
        RETURN utils.validation_error_response('p_storage_path', v_refusal);
    END IF;

    v_image_id := COALESCE(p_image_id, gen_random_uuid());

    INSERT INTO dispatch_images (id, dispatch_id, storage_path, original_filename, file_size, mime_type, uploaded_by, status)
    VALUES (v_image_id, p_dispatch_id, p_storage_path, p_original_filename, p_file_size, p_mime_type, v_user_profile_id, 'confirmed');

    RETURN utils.success_response(
        jsonb_build_object('image_id', v_image_id, 'dispatch_id', p_dispatch_id, 'storage_path', p_storage_path, 'uploaded_by', v_user_profile_id),
        'Image uploaded successfully'
    );
EXCEPTION
    WHEN foreign_key_violation THEN RETURN utils.error_response('FOREIGN_KEY_ERROR', 'Database constraint error.');
    WHEN unique_violation THEN RETURN utils.error_response('DUPLICATE_IMAGE_ID', 'Image ID already exists.');
    WHEN OTHERS THEN RETURN utils.database_error_response('Failed to upload image', SQLERRM, SQLSTATE);
END;
$$;

-- Patches to the large functions: every marker must be found exactly as often
-- as stated, or the migration stops.
DO $patch$
DECLARE
  fn regprocedure; definition text; step record;
  occurrences integer;
BEGIN
  FOR step IN SELECT * FROM (VALUES
    -- save_grn: check each listed image before its row is written.
    (1, 'save_grn', 1, $m$                  v_image_id := gen_random_uuid();

                  IF v_image->>'image_type' = 'item' THEN$m$,
     $r$                  v_image_id := gen_random_uuid();

                  PERFORM warehouse_security.require_image_path('grn', v_grn_id, v_image->>'image_type', v_image->>'storage_path');

                  IF v_image->>'image_type' = 'item' THEN$r$),
    (2, 'save_grn', 1, $m$                      ELSIF v_image->>'grn_item_id' IS NOT NULL THEN
$m$,
     $r$                      ELSIF v_image->>'grn_item_id' IS NOT NULL THEN
                          IF NOT EXISTS (SELECT 1 FROM goodsreceived_trl
                              WHERE id = (v_image->>'grn_item_id')::uuid AND gr_id = v_grn_id) THEN
                              RAISE EXCEPTION 'Image line does not belong to this GRN';
                          END IF;
$r$),
    (3, 'save_grn', 3, $m$original_filename, file_size, mime_type, uploaded_by
$m$,
     $r$original_filename, file_size, mime_type, uploaded_by, status
$r$),
    (4, 'save_grn', 2, $m$                              v_user_profile_id
                          );$m$,
     $r$                              v_user_profile_id, 'confirmed'
                          );$r$),
    (5, 'save_grn', 1, $m$                          v_user_profile_id
                      );$m$,
     $r$                          v_user_profile_id, 'confirmed'
                      );$r$),
    -- update_grn: an image is kept only if it is on this receipt (by id, else by
    -- path); anything else is a new attachment and is checked.
    (6, 'update_grn', 1, $m$                IF v_image->>'id' IS NOT NULL
                    AND NOT (v_image->>'id' LIKE 'temp_%')
                    AND EXISTS (SELECT 1 FROM grn_images WHERE id = (v_image->>'id')::uuid) THEN
                    UPDATE grn_images SET
                        grn_item_id = v_resolved_item_id,
                        updated_at = now()
                    WHERE id = (v_image->>'id')::uuid;

                    v_images_updated := v_images_updated + 1;
                    v_kept_image_ids := array_append(v_kept_image_ids, (v_image->>'id')::uuid);
                ELSE
                    v_image_id := gen_random_uuid();
$m$,
     $r$                IF v_resolved_item_id IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM goodsreceived_trl WHERE id = v_resolved_item_id AND gr_id = p_grn_id) THEN
                    RAISE EXCEPTION 'Image line does not belong to this GRN';
                END IF;

                v_image_id := NULL;
                IF v_image->>'id' IS NOT NULL AND NOT (v_image->>'id' LIKE 'temp_%') THEN
                    SELECT id INTO v_image_id FROM grn_images
                    WHERE id = (v_image->>'id')::uuid AND grn_id = p_grn_id;
                END IF;
                IF v_image_id IS NULL THEN
                    SELECT id INTO v_image_id FROM grn_images
                    WHERE grn_id = p_grn_id AND storage_path = v_image->>'storage_path'
                    ORDER BY created_at, id LIMIT 1;
                END IF;

                IF v_image_id IS NOT NULL THEN
                    UPDATE grn_images SET
                        grn_item_id = v_resolved_item_id,
                        updated_at = now()
                    WHERE id = v_image_id;

                    v_images_updated := v_images_updated + 1;
                    v_kept_image_ids := array_append(v_kept_image_ids, v_image_id);
                ELSE
                    PERFORM warehouse_security.require_image_path('grn', p_grn_id, v_image->>'image_type', v_image->>'storage_path');

                    v_image_id := gen_random_uuid();
$r$),
    (7, 'update_grn', 1, $m$                        id, grn_id, grn_item_id, image_type, storage_path,
                        original_filename, file_size, mime_type, uploaded_by
                    ) VALUES ($m$,
     $r$                        id, grn_id, grn_item_id, image_type, storage_path,
                        original_filename, file_size, mime_type, uploaded_by, status
                    ) VALUES ($r$),
    (8, 'update_grn', 1, $m$                        COALESCE(v_image->>'mime_type', 'image/jpeg'), v_user_profile_id
                    );$m$,
     $r$                        COALESCE(v_image->>'mime_type', 'image/jpeg'), v_user_profile_id, 'confirmed'
                    );$r$),
    -- register: an item photo is registered for a line of that receipt.
    (9, 'register_grn_image_upload', 1, $m$    -- 4. Validate GRN exists
$m$,
     $r$    IF p_grn_item_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM goodsreceived_trl WHERE id = p_grn_item_id AND gr_id = p_grn_id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Image line does not belong to this GRN',
            'code', 'ITEM_NOT_IN_GRN'
        );
    END IF;

    -- 4. Validate GRN exists
$r$),
    -- Two photos of one dispatch registered in the same millisecond with the
    -- same file name were given the same path; a random part makes it unique.
    (10, 'register_dispatch_image_upload', 1,
     $m$    v_storage_path := p_dispatch_id::text || '/' || v_timestamp || '_' || v_safe_filename;$m$,
     $r$    v_storage_path := p_dispatch_id::text || '/' || gen_random_uuid()::text || '_' || v_safe_filename;$r$),
    -- confirm: only for a file that was uploaded to the registered path.
    (11, 'confirm_grn_image_upload', 1, $m$    -- 3. Update status to confirmed
$m$,
     $r$    IF warehouse_security.image_path_refusal('grn', v_record.grn_id, v_record.image_type, v_record.storage_path, v_record.id) IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', warehouse_security.image_path_refusal('grn', v_record.grn_id, v_record.image_type, v_record.storage_path, v_record.id),
            'code', 'IMAGE_NOT_VERIFIED'
        );
    END IF;

    -- 3. Update status to confirmed
$r$),
    (12, 'confirm_dispatch_image_upload', 1, $m$    -- 3. Update status to confirmed
$m$,
     $r$    IF warehouse_security.image_path_refusal('dispatch', v_record.dispatch_id, NULL, v_record.storage_path, v_record.id) IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', warehouse_security.image_path_refusal('dispatch', v_record.dispatch_id, NULL, v_record.storage_path, v_record.id),
            'code', 'IMAGE_NOT_VERIFIED'
        );
    END IF;

    -- 3. Update status to confirmed
$r$)
  ) AS s(step_no, function_name, expected, marker, replacement) ORDER BY step_no
  LOOP
    SELECT p.oid::regprocedure INTO STRICT fn FROM pg_proc p
      WHERE p.pronamespace='public'::regnamespace AND p.proname=step.function_name;
    definition := pg_get_functiondef(fn);
    occurrences := (length(definition)-length(replace(definition,step.marker,'')))/length(step.marker);
    IF occurrences <> step.expected THEN
      RAISE EXCEPTION 'Image path patch %: expected % marker(s) in %, found %',
        step.step_no, step.expected, step.function_name, occurrences;
    END IF;
    EXECUTE replace(definition,step.marker,step.replacement);
  END LOOP;
END $patch$;

-- A customer reads the metadata of confirmed images only, as the storage
-- policies already require for the files. Before, the row of a pending upload,
-- its upload_token included, was readable by the document's customer.
DROP POLICY starter_customer ON public.grn_images;
CREATE POLICY starter_customer ON public.grn_images FOR SELECT TO authenticated USING (
  status = 'confirmed' AND EXISTS (SELECT 1 FROM public.goodsreceived g
    WHERE g.id = grn_id AND warehouse_security.owns_customer(g.customer_id)));
DROP POLICY starter_customer ON public.dispatch_images;
CREATE POLICY starter_customer ON public.dispatch_images FOR SELECT TO authenticated USING (
  status = 'confirmed' AND EXISTS (SELECT 1 FROM public.dispatch d
    WHERE d.id = dispatch_id AND warehouse_security.owns_customer(d.customer_id)));

-- Rows written before this migration are not changed. The operator can list
-- the ones the rule would refuse today.
CREATE FUNCTION warehouse_maintenance.misplaced_image_paths()
RETURNS TABLE(kind text, image_id uuid, document_id uuid, status text, storage_path text, reason text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT 'grn', i.id, i.grn_id, i.status::text, i.storage_path, 'outside the folder of its GRN'
  FROM public.grn_images i
  WHERE NOT COALESCE(starts_with(i.storage_path, warehouse_security.image_path_prefix('grn', i.grn_id, i.image_type::text)), false)
  UNION ALL
  SELECT 'dispatch', i.id, i.dispatch_id, i.status::text, i.storage_path, 'outside the folder of its dispatch'
  FROM public.dispatch_images i
  WHERE NOT COALESCE(starts_with(i.storage_path, warehouse_security.image_path_prefix('dispatch', i.dispatch_id, NULL)), false)
  UNION ALL
  SELECT 'grn', i.id, i.grn_id, i.status::text, i.storage_path, 'path also on another image row'
  FROM public.grn_images i
  WHERE EXISTS (SELECT 1 FROM public.grn_images o WHERE o.storage_path = i.storage_path AND o.id <> i.id)
  UNION ALL
  SELECT 'dispatch', i.id, i.dispatch_id, i.status::text, i.storage_path, 'path also on another image row'
  FROM public.dispatch_images i
  WHERE EXISTS (SELECT 1 FROM public.dispatch_images o WHERE o.storage_path = i.storage_path AND o.id <> i.id)
$$;
REVOKE ALL ON FUNCTION warehouse_maintenance.misplaced_image_paths() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION warehouse_maintenance.misplaced_image_paths() TO service_role;

DO $legacy$
DECLARE outside bigint; repeated bigint;
BEGIN
  SELECT count(*) FILTER (WHERE reason LIKE 'outside%'), count(*) FILTER (WHERE reason LIKE 'path also%')
    INTO outside, repeated FROM warehouse_maintenance.misplaced_image_paths();
  IF outside > 0 THEN
    RAISE WARNING '% existing image row(s) have a storage path outside their own document''s folder. They were left as they are; list them with SELECT * FROM warehouse_maintenance.misplaced_image_paths() and remove the ones that should not be there.', outside;
  END IF;
  -- With no repeated path today, the database keeps it that way.
  IF repeated = 0 THEN
    CREATE UNIQUE INDEX grn_images_storage_path_key ON public.grn_images (storage_path);
    CREATE UNIQUE INDEX dispatch_images_storage_path_key ON public.dispatch_images (storage_path);
  ELSE
    RAISE WARNING '% existing image row(s) share a storage path with another row, so the unique index on storage_path was not created. The RPCs still refuse a path that is already attached; list the rows with SELECT * FROM warehouse_maintenance.misplaced_image_paths().', repeated;
  END IF;
END $legacy$;

-- Generated PDFs expire (review, 2026-10-10).
--
-- Every generate-*-pdf call stores a new object <kind>/<document id>/<uuid>.pdf
-- in the private documents bucket and hands out a link that is valid for one
-- hour (functions/_shared/document-pdf.ts). Nothing removed the object. The
-- retention command now removes the ones older than this policy. A file is
-- freed only through the Storage API, so the database only names the expired
-- objects and scripts/retention.sh deletes them with the service key.
INSERT INTO warehouse_maintenance.retention_policy(key, days, description) VALUES
  ('generated_documents', 7, 'Generated PDF files in the documents bucket (their links expire after one hour)');

-- Only names the PDF functions produce; a file an operator put in the bucket
-- under another name is never listed.
CREATE FUNCTION warehouse_maintenance.expired_generated_documents(p_now timestamptz DEFAULT now())
RETURNS SETOF text
LANGUAGE sql STABLE
SET search_path = pg_catalog, public, warehouse_maintenance
AS $$
  SELECT o.name FROM storage.objects o
  WHERE o.bucket_id = 'documents'
    AND o.created_at < p_now - make_interval(days => (SELECT days FROM warehouse_maintenance.retention_policy WHERE key = 'generated_documents'))
    AND o.name ~ '^(grn|dispatch|invoice|stock)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.pdf$'
  ORDER BY o.created_at, o.name
$$;
REVOKE ALL ON FUNCTION warehouse_maintenance.expired_generated_documents(timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION warehouse_maintenance.expired_generated_documents(timestamptz) TO service_role;

NOTIFY pgrst, 'reload schema';
