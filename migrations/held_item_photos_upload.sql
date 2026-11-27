-- WH-304, topic "held item photos" (slice B-5, contract product/tech/app-offline-holding-list.md §2.5 and §11.6).
--
--  1. public.register_held_photo_upload(p_held_id, p_client_photo_id, p_role, p_file_name, p_file_size, p_mime_type, p_line_ref): registers a
--     pending held_item_photos row and answers the path to upload to. Shaped as register_grn_image_upload; the phone's own photo id
--     (p_client_photo_id) makes a resend answer the same row.
--  2. public.confirm_held_photo_upload(p_held_id, p_client_photo_id): checks the file is in storage and marks the row confirmed (as
--     confirm_grn_image_upload; the pair has no upload token: the client photo id under the held id names the row, and only the recorder
--     or the administrator who moved the item may use it).
--  3. warehouse_security.held_photo_refusal, held_photo_file_access, held_photo_file_named: the caller check and the two helpers the storage
--     policies of scripts/configure-storage.sql call (a policy cannot read held_item_photos, which no app role may read).
-- Accept already attaches the confirmed rows to the new document (migration 236, held_attach_photos, uploaded_by = the recorder); nothing
-- changes there. The files live under held/<held id>/ of grn-images (header and item photos) or dispatch-images (dispatch photos) and are
-- not moved on accept. The authorize_rpc lines are in definitions/00_authorize_rpc.sql.
-- confirm_held_photo_upload reads storage.objects, which the storage service creates after the migrations run: its body is not checked at
-- creation (migration 130's pattern). No pg_temp helper is left behind. No role is created, altered or dropped.

-- ===== 1. the caller check =====
-- NULL when the caller may upload to this held item, else the refusal. Only the item's recorder, or the administrator who moved it
-- (handed_by), and only while the item is still held.
CREATE FUNCTION warehouse_security.held_photo_refusal(p_held_id uuid) RETURNS jsonb
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
  IF h.state <> 'held' THEN
    RETURN warehouse_security.refuse('HELD_ALREADY_DECIDED', 'This item is already decided.');
  END IF;
  RETURN NULL;
END $$;
ALTER FUNCTION warehouse_security.held_photo_refusal(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_photo_refusal(uuid) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION warehouse_security.held_photo_refusal(uuid) IS
  'WH-304: NULL when the caller is the recorder of this held item (or the administrator who moved it) and it is still held, else the refusal.';

-- ===== 2. register =====
CREATE FUNCTION public.register_held_photo_upload(p_held_id uuid, p_client_photo_id text, p_role text, p_file_name text, p_file_size integer,
                                                  p_mime_type text, p_line_ref text DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_refusal jsonb;
  v_caller uuid;
  v_id text;
  v_name text;
  v_path text;
  v_bucket text;
  p public.held_item_photos%ROWTYPE;
BEGIN
  PERFORM warehouse_security.authorize_rpc('register_held_photo_upload', jsonb_build_object('p_held_id', p_held_id));
  v_refusal := warehouse_security.held_photo_refusal(p_held_id);
  IF v_refusal IS NOT NULL THEN RETURN v_refusal; END IF;
  SELECT pr.id INTO v_caller FROM public.user_profiles pr WHERE pr.auth_user_id = auth.uid();

  v_id := btrim(p_client_photo_id);
  IF v_id IS NULL OR v_id = '' OR length(v_id) > 100 THEN
    RETURN warehouse_security.refuse('HELD_PHOTO_INVALID', 'The photo has no id.');
  END IF;
  IF p_role IS NULL OR p_role NOT IN ('header', 'item', 'dispatch') THEN
    RETURN warehouse_security.refuse('HELD_PHOTO_INVALID', 'The photo role must be header, item or dispatch.');
  END IF;
  IF p_role = 'item' AND (p_line_ref IS NULL OR btrim(p_line_ref) = '') THEN
    RETURN warehouse_security.refuse('HELD_PHOTO_INVALID', 'An item photo needs its line.');
  END IF;
  IF p_file_name IS NULL OR btrim(p_file_name) = '' THEN
    RETURN warehouse_security.refuse('HELD_PHOTO_INVALID', 'The photo has no file name.');
  END IF;
  IF p_mime_type IS NULL OR p_mime_type NOT IN ('image/jpeg', 'image/png', 'image/webp') THEN
    RETURN warehouse_security.refuse('HELD_PHOTO_INVALID', 'Only image/jpeg, image/png, image/webp allowed.');
  END IF;
  IF p_file_size IS NULL OR p_file_size < 1 OR p_file_size > 10485760 THEN
    RETURN warehouse_security.refuse('HELD_PHOTO_INVALID', 'File size must be between 1 byte and 10MB.');
  END IF;

  -- A resend (same held id and client photo id) answers the same row.
  SELECT x.* INTO p FROM public.held_item_photos x WHERE x.held_id = p_held_id AND x.client_photo_id = v_id;
  IF NOT FOUND THEN
    v_name := regexp_replace(p_file_name, '[^a-zA-Z0-9._-]', '_', 'g');
    v_path := 'held/' || p_held_id::text || '/' || gen_random_uuid()::text || '_' || v_name;
    INSERT INTO public.held_item_photos (held_id, client_photo_id, path, role, line_ref, file_name, file_size, mime_type, state, uploaded_by)
    VALUES (p_held_id, v_id, v_path, p_role, CASE WHEN p_role = 'item' THEN btrim(p_line_ref) END, p_file_name, p_file_size, p_mime_type,
            'pending', v_caller)
    ON CONFLICT (held_id, client_photo_id) DO NOTHING;
    SELECT x.* INTO p FROM public.held_item_photos x WHERE x.held_id = p_held_id AND x.client_photo_id = v_id;
  END IF;
  v_bucket := CASE p.role WHEN 'dispatch' THEN 'dispatch-images' ELSE 'grn-images' END;
  RETURN jsonb_build_object('success', true, 'held_id', p.held_id, 'client_photo_id', p.client_photo_id, 'storage_path', p.path,
                            'bucket', v_bucket, 'status', p.state);
END $$;
ALTER FUNCTION public.register_held_photo_upload(uuid, text, text, text, integer, text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.register_held_photo_upload(uuid, text, text, text, integer, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_held_photo_upload(uuid, text, text, text, integer, text, text) TO authenticated, service_role;
COMMENT ON FUNCTION public.register_held_photo_upload(uuid, text, text, text, integer, text, text) IS
  'WH-304: the recorder of a held item (or the administrator who moved it) registers one photo under its held id; a resend of the same client photo id answers the same row.';

-- ===== 3. confirm =====
SET LOCAL check_function_bodies = false;
CREATE FUNCTION public.confirm_held_photo_upload(p_held_id uuid, p_client_photo_id text)
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

  -- The row is locked while it is confirmed.
  SELECT x.* INTO p FROM public.held_item_photos x WHERE x.held_id = p_held_id AND x.client_photo_id = v_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN warehouse_security.refuse('HELD_PHOTO_NOT_FOUND', 'That photo was not registered.');
  END IF;
  IF p.state = 'confirmed' THEN
    RETURN jsonb_build_object('success', true, 'held_id', p.held_id, 'client_photo_id', p.client_photo_id, 'storage_path', p.path,
                              'status', 'confirmed');
  END IF;
  v_bucket := CASE p.role WHEN 'dispatch' THEN 'dispatch-images' ELSE 'grn-images' END;
  IF NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = v_bucket AND o.name = p.path) THEN
    RETURN warehouse_security.refuse('IMAGE_NOT_VERIFIED', 'Image file is not in storage.');
  END IF;
  UPDATE public.held_item_photos x SET state = 'confirmed' WHERE x.held_id = p.held_id AND x.client_photo_id = p.client_photo_id;
  RETURN jsonb_build_object('success', true, 'held_id', p.held_id, 'client_photo_id', p.client_photo_id, 'storage_path', p.path,
                            'status', 'confirmed');
END $$;
RESET check_function_bodies;
ALTER FUNCTION public.confirm_held_photo_upload(uuid, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.confirm_held_photo_upload(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_held_photo_upload(uuid, text) TO authenticated, service_role;
COMMENT ON FUNCTION public.confirm_held_photo_upload(uuid, text) IS
  'WH-304: the recorder confirms a registered held photo once its file is in storage (a repeat answers the same).';

-- ===== 4. helpers for the storage policies (scripts/configure-storage.sql) =====
-- A staff person may upload (write) a pending file registered by themselves, and read the files of the held items they recorded. Administrators
-- and supervisors already read and write both photo buckets through the manager policies.
CREATE FUNCTION warehouse_security.held_photo_file_access(p_bucket text, p_name text, p_write boolean) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path TO 'pg_catalog'
AS $$
  SELECT warehouse_security.active_role() = 'staff' AND EXISTS (
    SELECT 1 FROM public.held_item_photos x JOIN public.held_items h ON h.id = x.held_id
    JOIN public.user_profiles pr ON pr.auth_user_id = auth.uid()
    WHERE x.path = p_name
      AND p_bucket = CASE x.role WHEN 'dispatch' THEN 'dispatch-images' ELSE 'grn-images' END
      AND CASE WHEN p_write THEN x.state = 'pending' AND h.state = 'held' AND x.uploaded_by = pr.id
               ELSE h.recorded_by = pr.id OR x.uploaded_by = pr.id END);
$$;
ALTER FUNCTION warehouse_security.held_photo_file_access(text, text, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_photo_file_access(text, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION warehouse_security.held_photo_file_access(text, text, boolean) TO authenticated;

-- True while a held photo names the file: a manager may not delete it.
CREATE FUNCTION warehouse_security.held_photo_file_named(p_name text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path TO 'pg_catalog'
AS $$
  SELECT EXISTS (SELECT 1 FROM public.held_item_photos x WHERE x.path = p_name);
$$;
ALTER FUNCTION warehouse_security.held_photo_file_named(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_photo_file_named(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION warehouse_security.held_photo_file_named(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
