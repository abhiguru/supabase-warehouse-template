-- WH-304, topic "held photos after accept" (follows "held photo missing", migration 241 at assembly; from Test's release review of the batch).
--  1. A photo that is still uploading when its item is accepted is not lost. A pending photo of an ACCEPTED item can still be registered,
--     confirmed and marked missing by its recorder (the same caller rule as before); on confirm it is attached at once to the document the
--     accept created (the same attach code as accept: held_attach_photos, uploaded_by = the recorder; a repeat of confirm attaches once).
--     A REJECTED item keeps the refusal HELD_ALREADY_DECIDED. Accept itself is unchanged (no refusal, no new message).
--       - held_items.item_mapping keeps the save's item mapping of an accepted item, so a late line photo ("index:<n>") resolves its line
--         as accept does (decide_held_item is patched to store it).
--       - held_item_photos.document_id is the GRN (header and item photos) or dispatch (dispatch photos) the item's accept created; set when
--         a photo is confirmed or marked missing after the accept. A missing photo of an accepted item keeps state 'missing', its reason
--         and this link, so a later screen can show it on the saved document.
--       - warehouse_security.held_photo_refusal lets an accepted item through; held_photo_file_access lets staff write the pending file of an
--         accepted item (the policies of scripts/configure-storage.sql call it; their text is unchanged).
--       - confirm_held_photo_upload locks the item (its parent first) so it cannot run beside the accept's attach and be missed by it.
--  2. WH-382: hold_items looks up the item a held item follows by request key AND the recorder.
--  3. WH-383: hold_items derives the held row's customer from the saved body (newGrn: args.p_customer_id; newDispatch:
--     args.p_dispatch_data.customer_id; any other kind: the customer of the GRN or dispatch it belongs to), never from the phone's item field.
--  4. WH-384: in an administrator's move (p_recorder) the recorder must have a warehouse role (admin, supervisor, staff); a deactivated
--     profile is allowed. Another role, or a deleted profile (deleted_at set): HELD_RECORDER_INVALID. An unknown profile keeps HELD_RECORDER_UNKNOWN.
-- confirm_held_photo_upload reads storage.objects (migration 130's pattern: its body is not checked at creation). The pg_temp helper is
-- dropped at the end. No role is created, altered or dropped. No new public function (so no authorize_rpc line).

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
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- ===== 1a. columns =====
ALTER TABLE public.held_items ADD COLUMN item_mapping jsonb;
ALTER TABLE public.held_item_photos ADD COLUMN document_id uuid;

-- ===== 1b. accept keeps the item mapping (of the item and of the photos that go with it) =====
SELECT pg_temp.patch_function('public.decide_held_item(uuid, text, text, text, jsonb)'::regprocedure, ARRAY[
$m$decision_key = v_key, result = v_run -> 'result',$m$,
$m$decided_at = now(), result = v_run -> 'result'$m$
], ARRAY[
$m$decision_key = v_key, result = v_run -> 'result', item_mapping = v_run #> '{answer,data,item_mapping}',$m$,
$m$decided_at = now(), result = v_run -> 'result', item_mapping = v_run #> '{answer,data,item_mapping}'$m$
]);

-- ===== 1c. who may add photos: an accepted item too =====
CREATE OR REPLACE FUNCTION warehouse_security.held_photo_refusal(p_held_id uuid) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
DECLARE
  v_role text := warehouse_security.active_role();
  v_caller uuid;
  h public.held_items%ROWTYPE;
BEGIN
  SELECT p.id INTO v_caller FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();
  IF v_role IS NULL OR v_role NOT IN ('admin', 'supervisor', 'staff') OR v_caller IS NULL THEN
    RAISE EXCEPTION 'Staff access required' USING ERRCODE = '42501';
  END IF;
  SELECT x.* INTO h FROM public.held_items x WHERE x.id = p_held_id;
  IF NOT FOUND THEN
    RETURN warehouse_security.refuse('HELD_NOT_FOUND', 'That held item is not there.');
  END IF;
  IF NOT (h.recorded_by = v_caller OR (h.handed_by = v_caller AND v_role = 'admin')) THEN
    RETURN warehouse_security.refuse('HELD_PHOTO_NOT_YOURS', 'Only the person who recorded this item can add photos to it.');
  END IF;
  -- Still held, or accepted (a photo still on its way is taken afterwards); a rejected item is settled.
  IF h.state NOT IN ('held', 'accepted') THEN
    RETURN warehouse_security.refuse('HELD_ALREADY_DECIDED', 'This item is already decided.');
  END IF;
  RETURN NULL;
END $$;
COMMENT ON FUNCTION warehouse_security.held_photo_refusal(uuid) IS
  'WH-304: NULL when the caller is the recorder of this held item (or the administrator who moved it) and it is still held or accepted, else the refusal.';

CREATE OR REPLACE FUNCTION warehouse_security.held_photo_file_access(p_bucket text, p_name text, p_write boolean) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path TO 'pg_catalog'
AS $$
  SELECT warehouse_security.active_role() = 'staff' AND EXISTS (
    SELECT 1 FROM public.held_item_photos x JOIN public.held_items h ON h.id = x.held_id
    JOIN public.user_profiles pr ON pr.auth_user_id = auth.uid()
    WHERE x.path = p_name
      AND p_bucket = CASE x.role WHEN 'dispatch' THEN 'dispatch-images' ELSE 'grn-images' END
      AND CASE WHEN p_write THEN x.state = 'pending' AND h.state IN ('held', 'accepted') AND x.uploaded_by = pr.id
               ELSE h.recorded_by = pr.id OR x.uploaded_by = pr.id END);
$$;

-- ===== 1d. helpers: the document an accepted item made, and the late attach =====
-- The GRN (header and item photos) or the dispatch (dispatch photos) the accept of this held item created or its photos belong to; NULL while
-- the item is not accepted.
CREATE FUNCTION warehouse_security.held_document(p_held uuid, p_role text) RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
  SELECT CASE WHEN (CASE WHEN p_role = 'dispatch' THEN h.result ->> 'dispatch_id' ELSE h.result ->> 'grn_id' END)
                   ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              THEN (CASE WHEN p_role = 'dispatch' THEN h.result ->> 'dispatch_id' ELSE h.result ->> 'grn_id' END)::uuid END
    FROM public.held_items h WHERE h.id = p_held AND h.state = 'accepted';
$$;
ALTER FUNCTION warehouse_security.held_document(uuid, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_document(uuid, text) FROM PUBLIC, anon, authenticated, service_role;

-- Attaches the confirmed photos of an ACCEPTED held item to the document its accept created, as accept does (held_attach_photos: uploaded_by = the
-- recorder, the line resolved through the stored item mapping or a lot id, a photo already on the document by path is not attached twice), and
-- links every confirmed or missing photo of the item that has none yet to that document. A deleted document is not attached to.
CREATE FUNCTION warehouse_security.held_attach_late(p_held uuid) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
DECLARE
  h public.held_items;
  v_grn uuid := warehouse_security.held_document(p_held, 'header');
  v_disp uuid := warehouse_security.held_document(p_held, 'dispatch');
BEGIN
  SELECT * INTO h FROM public.held_items x WHERE x.id = p_held AND x.state = 'accepted';
  IF NOT FOUND THEN RETURN; END IF;
  IF v_grn IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = v_grn AND g.deleted_at IS NULL) THEN v_grn := NULL; END IF;
  IF v_disp IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.dispatch d WHERE d.id = v_disp AND d.deleted_at IS NULL) THEN v_disp := NULL; END IF;
  IF v_grn IS NOT NULL OR v_disp IS NOT NULL THEN
    PERFORM warehouse_security.held_attach_photos(h.id, h.recorded_by, v_grn, v_disp, h.item_mapping);
  END IF;
  UPDATE public.held_item_photos x SET document_id = warehouse_security.held_document(x.held_id, x.role)
   WHERE x.held_id = p_held AND x.document_id IS NULL AND x.state IN ('confirmed', 'missing');
END $$;
ALTER FUNCTION warehouse_security.held_attach_late(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_attach_late(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- ===== 1e. confirm: attaches at once when the item is already accepted =====
SET LOCAL check_function_bodies = false;
CREATE OR REPLACE FUNCTION public.confirm_held_photo_upload(p_held_id uuid, p_client_photo_id text)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_refusal jsonb;
  v_id text := btrim(p_client_photo_id);
  p public.held_item_photos%ROWTYPE;
  v_bucket text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('confirm_held_photo_upload', jsonb_build_object('p_held_id', p_held_id));
  v_refusal := warehouse_security.held_photo_refusal(p_held_id);
  IF v_refusal IS NOT NULL THEN RETURN v_refusal; END IF;

  -- The item (its parent first, the order accept locks in) is locked, so an accept either sees this photo confirmed or is seen by it.
  PERFORM 1 FROM public.held_items x
   WHERE x.id = COALESCE((SELECT f.follows FROM public.held_items f WHERE f.id = p_held_id), p_held_id) FOR UPDATE;
  PERFORM 1 FROM public.held_items x WHERE x.id = p_held_id FOR UPDATE;
  v_refusal := warehouse_security.held_photo_refusal(p_held_id);
  IF v_refusal IS NOT NULL THEN RETURN v_refusal; END IF;

  -- The row is locked while it is confirmed.
  SELECT x.* INTO p FROM public.held_item_photos x WHERE x.held_id = p_held_id AND x.client_photo_id = v_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN warehouse_security.refuse('HELD_PHOTO_NOT_FOUND', 'That photo was not registered.');
  END IF;
  IF p.state <> 'confirmed' THEN
    v_bucket := CASE p.role WHEN 'dispatch' THEN 'dispatch-images' ELSE 'grn-images' END;
    IF NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = v_bucket AND o.name = p.path) THEN
      RETURN warehouse_security.refuse('IMAGE_NOT_VERIFIED', 'Image file is not in storage.');
    END IF;
    UPDATE public.held_item_photos x SET state = 'confirmed' WHERE x.held_id = p.held_id AND x.client_photo_id = p.client_photo_id;
  END IF;
  -- An accepted item's photo goes onto the saved document now (idempotent: a repeat attaches nothing twice).
  PERFORM warehouse_security.held_attach_late(p_held_id);
  RETURN jsonb_build_object('success', true, 'held_id', p.held_id, 'client_photo_id', p.client_photo_id, 'storage_path', p.path,
                            'status', 'confirmed');
END $$;
RESET check_function_bodies;

-- ===== 1f. mark missing: after the accept it keeps its record, linked to the saved document =====
CREATE OR REPLACE FUNCTION public.mark_held_photo_missing(p_held_id uuid, p_client_photo_id text, p_role text, p_line_ref text DEFAULT NULL,
                                                         p_reason text DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_refusal jsonb;
  v_caller uuid;
  v_id text := btrim(p_client_photo_id);
  v_reason text := left(NULLIF(btrim(p_reason), ''), 500);
  p public.held_item_photos%ROWTYPE;
BEGIN
  PERFORM warehouse_security.authorize_rpc('mark_held_photo_missing', jsonb_build_object('p_held_id', p_held_id));
  v_refusal := warehouse_security.held_photo_refusal(p_held_id);
  IF v_refusal IS NOT NULL THEN RETURN v_refusal; END IF;
  SELECT pr.id INTO v_caller FROM public.user_profiles pr WHERE pr.auth_user_id = auth.uid();

  IF v_id IS NULL OR v_id = '' OR length(v_id) > 100 THEN
    RETURN warehouse_security.refuse('HELD_PHOTO_INVALID', 'The photo has no id.');
  END IF;
  IF p_role IS NULL OR p_role NOT IN ('header', 'item', 'dispatch') THEN
    RETURN warehouse_security.refuse('HELD_PHOTO_INVALID', 'The photo role must be header, item or dispatch.');
  END IF;
  IF p_role = 'item' AND (p_line_ref IS NULL OR btrim(p_line_ref) = '') THEN
    RETURN warehouse_security.refuse('HELD_PHOTO_INVALID', 'An item photo needs its line.');
  END IF;

  -- The row may not exist (the photo was refused at registration). Placeholder file values satisfy the table's checks; no file exists.
  -- document_id: the document the item's accept created, when the item is already accepted (NULL while it is held).
  INSERT INTO public.held_item_photos (held_id, client_photo_id, path, role, line_ref, file_name, file_size, mime_type, state, reason, uploaded_by,
                                       document_id)
  VALUES (p_held_id, v_id, 'held/' || p_held_id::text || '/missing/' || regexp_replace(v_id, '[^a-zA-Z0-9._-]', '_', 'g'), p_role,
          CASE WHEN p_role = 'item' THEN btrim(p_line_ref) END, 'missing', 1, 'image/jpeg', 'missing', v_reason, v_caller,
          warehouse_security.held_document(p_held_id, p_role))
  ON CONFLICT (held_id, client_photo_id) DO NOTHING;
  SELECT x.* INTO p FROM public.held_item_photos x WHERE x.held_id = p_held_id AND x.client_photo_id = v_id FOR UPDATE;
  -- A confirmed photo stays confirmed; a missing one keeps its first reason.
  IF p.state = 'pending' THEN
    UPDATE public.held_item_photos x SET state = 'missing', reason = v_reason, document_id = warehouse_security.held_document(x.held_id, x.role)
     WHERE x.held_id = p.held_id AND x.client_photo_id = p.client_photo_id;
    p.state := 'missing';
  END IF;
  RETURN jsonb_build_object('success', true, 'held_id', p.held_id, 'client_photo_id', p.client_photo_id, 'status', p.state);
END $$;

-- ===== 2, 3, 4. hold_items =====
SELECT pg_temp.patch_function('public.hold_items(jsonb, uuid)'::regprocedure, ARRAY[
-- WH-384
$m$v_moved := true;$m$,
-- WH-382
$m$SELECT * INTO v_parent FROM public.held_items h WHERE h.request_key = v_fk;$m$,
-- WH-383: the customer of the saved body
$m$IF jsonb_typeof(v_e -> 'customer_id') = 'string' AND (v_e ->> 'customer_id') ~* v_uuid THEN$m$,
$m$SELECT c.id INTO v_customer FROM public.customers c WHERE c.id = (v_e ->> 'customer_id')::uuid;$m$,
$m$INSERT INTO public.held_items (request_key, kind, body,$m$
], ARRAY[
$m$IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = v_recorder AND p.role IN ('admin', 'supervisor', 'staff') AND p.deleted_at IS NULL) THEN
      RETURN warehouse_security.refuse('HELD_RECORDER_INVALID', 'That person cannot have items moved from their phone.');
    END IF;
    v_moved := true;$m$,
$m$SELECT * INTO v_parent FROM public.held_items h WHERE h.request_key = v_fk AND h.recorded_by = v_recorder;$m$,
$m$v_text := CASE v_kind WHEN 'newGrn' THEN v_body #>> '{args,p_customer_id}' WHEN 'newDispatch' THEN v_body #>> '{args,p_dispatch_data,customer_id}' END;
    IF v_text ~* v_uuid THEN$m$,
$m$SELECT c.id INTO v_customer FROM public.customers c WHERE c.id = v_text::uuid;$m$,
$m$IF v_customer IS NULL AND v_kind NOT IN ('newGrn', 'newDispatch') THEN
      -- A change or photos of a saved record: the customer of that record.
      IF v_grn IS NOT NULL THEN
        SELECT g.customer_id INTO v_customer FROM public.goodsreceived g WHERE g.id = v_grn;
      ELSIF v_disp IS NOT NULL THEN
        SELECT d.customer_id INTO v_customer FROM public.dispatch d WHERE d.id = v_disp;
      END IF;
    END IF;
    INSERT INTO public.held_items (request_key, kind, body,$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
NOTIFY pgrst, 'reload schema';
