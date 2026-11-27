-- WH-304, topic "held photo missing" (follows "held item photos", migration 240 at assembly; PQ11).
--  1. held_item_photos.state also takes 'missing': the phone gave up on a photo (refused as invalid, or "not yours" after its retry limit).
--     A reason column holds the phone's short note. A missing photo is never attached on accept (held_attach_photos takes 'confirmed' only).
--  2. public.mark_held_photo_missing(p_held_id, p_client_photo_id, p_role, p_line_ref, p_reason): same caller rule as
--     register_held_photo_upload. Idempotent; creates the row (placeholder file values) if none exists; never turns a confirmed photo
--     into missing.
--  3. public.get_held_item (migration 236) is replaced: each photo also carries 'reason' (its 'state' now may be 'missing').
-- The authorize_rpc line is in definitions/00_authorize_rpc.sql. No pg_temp helper is left behind. No role is created, altered or dropped.

-- ===== 1. the state and the reason =====
ALTER TABLE public.held_item_photos DROP CONSTRAINT held_item_photos_state_check;
ALTER TABLE public.held_item_photos ADD CONSTRAINT held_item_photos_state_check CHECK (state IN ('pending', 'confirmed', 'missing'));
ALTER TABLE public.held_item_photos ADD COLUMN reason text CHECK (reason IS NULL OR length(reason) <= 500);

-- ===== 2. mark missing =====
CREATE FUNCTION public.mark_held_photo_missing(p_held_id uuid, p_client_photo_id text, p_role text, p_line_ref text DEFAULT NULL,
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
  INSERT INTO public.held_item_photos (held_id, client_photo_id, path, role, line_ref, file_name, file_size, mime_type, state, reason, uploaded_by)
  VALUES (p_held_id, v_id, 'held/' || p_held_id::text || '/missing/' || regexp_replace(v_id, '[^a-zA-Z0-9._-]', '_', 'g'), p_role,
          CASE WHEN p_role = 'item' THEN btrim(p_line_ref) END, 'missing', 1, 'image/jpeg', 'missing', v_reason, v_caller)
  ON CONFLICT (held_id, client_photo_id) DO NOTHING;
  SELECT x.* INTO p FROM public.held_item_photos x WHERE x.held_id = p_held_id AND x.client_photo_id = v_id FOR UPDATE;
  -- A confirmed photo stays confirmed; a missing one keeps its first reason.
  IF p.state = 'pending' THEN
    UPDATE public.held_item_photos x SET state = 'missing', reason = v_reason WHERE x.held_id = p.held_id AND x.client_photo_id = p.client_photo_id;
    p.state := 'missing';
  END IF;
  RETURN jsonb_build_object('success', true, 'held_id', p.held_id, 'client_photo_id', p.client_photo_id, 'status', p.state);
END $$;
ALTER FUNCTION public.mark_held_photo_missing(uuid, text, text, text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.mark_held_photo_missing(uuid, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_held_photo_missing(uuid, text, text, text, text) TO authenticated, service_role;
COMMENT ON FUNCTION public.mark_held_photo_missing(uuid, text, text, text, text) IS
  'WH-304: the recorder of a held item (or the administrator who moved it) says the phone gave up on a photo; the decider sees it as missing. Idempotent; never turns a confirmed photo into missing.';

-- ===== 3. get_held_item: photos carry their reason =====
CREATE OR REPLACE FUNCTION public.get_held_item(p_id uuid)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  h public.held_items;
  v_can boolean;
  v_possible boolean := false;
  v_run jsonb;
  v_rec record;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_held_item', jsonb_build_object('p_id', p_id));
  IF COALESCE(warehouse_security.active_role(), '') NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Administrator or supervisor required' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO h FROM public.held_items x WHERE x.id = p_id;
  IF NOT FOUND THEN
    RETURN warehouse_security.refuse('HELD_NOT_FOUND', 'This held item is not there.');
  END IF;
  v_can := warehouse_security.held_can_accept(h.id);
  -- No trial for a decided item, while something it follows is still held, or for photos that go with their record (no decision of their own).
  IF v_can THEN
    IF h.kind = 'photos' THEN
      SELECT r.grn, r.disp INTO v_rec FROM warehouse_security.held_record(h) r;
      v_possible := (v_rec.grn IS NOT NULL AND EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = v_rec.grn AND g.deleted_at IS NULL))
                 OR (v_rec.disp IS NOT NULL AND EXISTS (SELECT 1 FROM public.dispatch d WHERE d.id = v_rec.disp AND d.deleted_at IS NULL));
    ELSE
      -- The trial runs the document writers: the refresh lock first, before held_store_reason's row lock.
      PERFORM pg_advisory_xact_lock(71040);
      v_run := warehouse_security.held_run(h.id, NULL, true);
      v_possible := (v_run ->> 'ok')::boolean;
      -- The reason follows today's refusal, so the list and the recorder see it.
      IF NOT v_possible THEN
        PERFORM warehouse_security.held_store_reason(h.id, v_run -> 'answer');
        SELECT * INTO h FROM public.held_items x WHERE x.id = p_id;
      END IF;
    END IF;
  END IF;
  RETURN jsonb_build_object('success', true)
    || warehouse_security.held_row(h)
    || jsonb_build_object(
      'can_accept', v_can,
      'reason_code', h.reason_code,
      'body', h.body,
      'accepted_body', h.accepted_body,
      'photos', COALESCE((SELECT jsonb_agg(jsonb_build_object('client_photo_id', f.client_photo_id, 'role', f.role, 'line_ref', f.line_ref,
                                                              'path', CASE WHEN f.state = 'missing' THEN NULL ELSE f.path END,
                                                              'state', f.state, 'reason', f.reason, 'url', NULL)
                                           ORDER BY f.created_at, f.client_photo_id)
                            FROM public.held_item_photos f WHERE f.held_id = h.id), '[]'::jsonb),
      'followers', COALESCE((SELECT jsonb_agg(warehouse_security.held_row(c) || jsonb_build_object('can_accept', warehouse_security.held_can_accept(c.id))
                                              ORDER BY c.phone_seq, c.id)
                               FROM public.held_items c WHERE c.follows = h.id), '[]'::jsonb),
      'accept_possible', v_possible,
      'current', warehouse_security.held_current(h));
END $$;
ALTER FUNCTION public.get_held_item(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_held_item(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_held_item(uuid) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_held_item(uuid) IS
  'WH-304: one held item (administrators and supervisors): its row, body, photos, followers, the server''s present values and accept_possible (the item''s save run inside a block that is always rolled back).';

