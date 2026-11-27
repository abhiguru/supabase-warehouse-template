-- Topics "holding list reads", "decide a held item" and "held outcome seen" (WH-304; contract tech/app-offline-holding-list.md sections 2.3,
-- 2.4, 2.8 and 11.1, 11.4 to 11.6). Named by topic; its number is taken when the work is assembled for main. It needs the topics "held items
-- store and hand-over" and "save on behalf of the recorder" applied before it, and WH-303's apply_grn_changes (a held grnEdit is accepted
-- through it).
--  1. Helpers in warehouse_security (no app role runs them): held_row (the list row shape), held_can_accept (every item an item follows,
--     all the way up, is decided), held_record (the GRN or dispatch a photos item belongs to), held_change_part and held_rebase (the
--     "from" of a field change taken past rejected items, Product PQ6), held_current (the server's present value of each changed field),
--     held_store_reason, held_attach_photos, held_run (the kind's own save, run for the recorder inside a block that is rolled back for a
--     trial and for a refusal), held_decision_answer.
--  2. public.get_held_items(p_limit, p_offset): administrators and supervisors; open items only, oldest first, an item that follows
--     another directly under it; at most 2,000 rows a page.
--  3. public.get_held_item(p_id): the row, its body, photos, followers, the server's present values and the trial (accept_possible).
--  4. public.decide_held_item(p_id, p_action, p_decision_key, p_reason, p_body): accept (the kind's own save under the item's request key,
--     as the recorder, checked as the accepting person) or reject (a reason). One decision per item; a repeated decision key answers the first.
--  5. public.mark_held_item_seen(p_id): the recorder marks a decided item seen.
-- No role is created, altered or dropped. No pg_temp helper is left behind.

-- ===== 1. helpers =====
-- The list row: the same keys for every reader of the list; names are resolved here. A moved item's reason_data names who moved it.
CREATE FUNCTION warehouse_security.held_row(h public.held_items) RETURNS jsonb
  LANGUAGE sql STABLE
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
  SELECT jsonb_build_object(
    'id', h.id,
    'kind', h.kind,
    'what', h.what,
    'customer_name', (SELECT c.name FROM public.customers c WHERE c.id = h.customer_id),
    'recorded_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = h.recorded_by),
    'recorded_at', h.recorded_at,
    'phone', h.phone,
    'reason', h.reason,
    'reason_data', CASE WHEN h.reason = 'moved' THEN jsonb_build_object(
        'admin_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = h.handed_by),
        'recorder_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = h.recorded_by),
        'moved_at', h.handed_at) ELSE h.reason_data END,
    'state', h.state,
    'follows', h.follows,
    'needs_decision', h.needs_decision,
    'decided_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = h.decided_by),
    'decided_at', h.decided_at,
    'reject_reason', h.reject_reason,
    'result', h.result)
$$;
ALTER FUNCTION warehouse_security.held_row(public.held_items) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_row(public.held_items) FROM PUBLIC, anon, authenticated, service_role;

-- True when the item is held, has a decision of its own and nothing it follows (directly or further up) is still held.
CREATE FUNCTION warehouse_security.held_can_accept(p_id uuid) RETURNS boolean
  LANGUAGE sql STABLE
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
  SELECT h.state = 'held' AND h.needs_decision AND NOT EXISTS (
    WITH RECURSIVE up(id, follows, state) AS (
      SELECT p.id, p.follows, p.state FROM public.held_items p WHERE p.id = h.follows
      UNION
      SELECT p.id, p.follows, p.state FROM public.held_items p JOIN up ON p.id = up.follows)
    SELECT 1 FROM up WHERE up.state = 'held')
  FROM public.held_items h WHERE h.id = p_id
$$;
ALTER FUNCTION warehouse_security.held_can_accept(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_can_accept(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- The GRN or dispatch a photos item belongs to: its own record, else the nearest item it follows that has one (or has made one).
CREATE FUNCTION warehouse_security.held_record(h public.held_items, OUT grn uuid, OUT disp uuid) RETURNS record
  LANGUAGE plpgsql STABLE
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
DECLARE
  v_a public.held_items;
  v_uuid constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  v_text text;
BEGIN
  grn := h.grn_id;
  disp := h.dispatch_id;
  v_a := h;
  WHILE grn IS NULL AND disp IS NULL AND v_a.follows IS NOT NULL LOOP
    SELECT * INTO v_a FROM public.held_items x WHERE x.id = v_a.follows;
    EXIT WHEN NOT FOUND;
    grn := v_a.grn_id;
    disp := v_a.dispatch_id;
    IF grn IS NULL AND disp IS NULL THEN
      v_text := v_a.result ->> 'grn_id';
      IF v_text ~* v_uuid THEN grn := v_text::uuid; END IF;
      v_text := v_a.result ->> 'dispatch_id';
      IF v_text ~* v_uuid THEN disp := v_text::uuid; END IF;
    END IF;
  END LOOP;
END $$;
ALTER FUNCTION warehouse_security.held_record(public.held_items) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_record(public.held_items) FROM PUBLIC, anon, authenticated, service_role;

-- The {from, to} object a held lotChange or grnEdit holds for one field, or NULL. p_lot NULL is a header field of an edit.
CREATE FUNCTION warehouse_security.held_change_part(a public.held_items, p_lot text, p_field text) RETURNS jsonb
  LANGUAGE sql IMMUTABLE
  SET search_path TO 'pg_catalog'
AS $$
  SELECT CASE
    WHEN p_lot IS NULL THEN CASE WHEN a.kind = 'grnEdit' THEN a.body #> ARRAY['header', p_field] END
    WHEN a.kind = 'lotChange' THEN CASE WHEN lower(a.body ->> 'lotId') = lower(p_lot) THEN a.body #> ARRAY['changes', p_field] END
    WHEN a.kind = 'grnEdit' THEN a.body #> ARRAY['lots', lower(p_lot), p_field]
    END
$$;
ALTER FUNCTION warehouse_security.held_change_part(public.held_items, text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_change_part(public.held_items, text, text) FROM PUBLIC, anon, authenticated, service_role;

-- The body with each field's "from" taken past the rejected items before it (Product PQ6): a rejected value was never on the server, so it is
-- never "the value replaced". For each changed field the nearest item up the chain that changes the same field is looked at: when it was
-- rejected, its own "from" becomes this one's, and the walk goes on above it; an accepted item (or none) stops the walk, so a value that an
-- accepted item set (the recorder is its setter) keeps its "from". Only lotChange and grnEdit have a "from"; the stored body is never changed.
CREATE FUNCTION warehouse_security.held_rebase(h public.held_items, p_body jsonb) RETURNS jsonb
  LANGUAGE plpgsql STABLE
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
DECLARE
  v_body jsonb := p_body;
  v_lot text;
  v_field text;
  v_fields jsonb;
  v_path text[];
  v_part jsonb;
  v_from jsonb;
  v_cur uuid;
  v_a public.held_items;
  v_found boolean;
  v_apart jsonb;
BEGIN
  IF h.follows IS NULL OR h.kind NOT IN ('lotChange', 'grnEdit') OR jsonb_typeof(p_body) IS DISTINCT FROM 'object' THEN
    RETURN p_body;
  END IF;
  -- The changed fields of the body: (lot or NULL, field, path of its {from, to} object).
  FOR v_lot, v_field, v_path IN
    SELECT s.lot, s.field, s.path FROM (
      SELECT lower(p_body ->> 'lotId') AS lot, f.key AS field, ARRAY['changes', f.key] AS path
        FROM jsonb_each(CASE WHEN h.kind = 'lotChange' AND jsonb_typeof(p_body -> 'changes') = 'object' THEN p_body -> 'changes' ELSE '{}'::jsonb END) f
      UNION ALL
      SELECT NULL, f.key, ARRAY['header', f.key]
        FROM jsonb_each(CASE WHEN h.kind = 'grnEdit' AND jsonb_typeof(p_body -> 'header') = 'object' THEN p_body -> 'header' ELSE '{}'::jsonb END) f
      UNION ALL
      SELECT l.key, f.key, ARRAY['lots', l.key, f.key]
        FROM jsonb_each(CASE WHEN h.kind = 'grnEdit' AND jsonb_typeof(p_body -> 'lots') = 'object' THEN p_body -> 'lots' ELSE '{}'::jsonb END) l,
             jsonb_each(CASE WHEN jsonb_typeof(l.value) = 'object' THEN l.value ELSE '{}'::jsonb END) f) s
  LOOP
    v_part := v_body #> v_path;
    CONTINUE WHEN jsonb_typeof(v_part) IS DISTINCT FROM 'object' OR NOT v_part ? 'from';
    v_from := v_part -> 'from';
    v_cur := h.follows;
    LOOP
      -- The nearest item at or above v_cur that changes this field.
      v_found := false;
      WHILE v_cur IS NOT NULL LOOP
        SELECT * INTO v_a FROM public.held_items x WHERE x.id = v_cur;
        EXIT WHEN NOT FOUND;
        IF warehouse_security.held_change_part(v_a, v_lot, v_field) IS NOT NULL THEN v_found := true; EXIT; END IF;
        v_cur := v_a.follows;
      END LOOP;
      EXIT WHEN NOT v_found OR v_a.state <> 'rejected';
      v_apart := warehouse_security.held_change_part(v_a, v_lot, v_field);
      EXIT WHEN jsonb_typeof(v_apart) IS DISTINCT FROM 'object' OR NOT v_apart ? 'from';
      v_from := v_apart -> 'from';
      v_cur := v_a.follows;
    END LOOP;
    v_body := jsonb_set(v_body, v_path || 'from', v_from);
  END LOOP;
  RETURN v_body;
END $$;
ALTER FUNCTION warehouse_security.held_rebase(public.held_items, jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_rebase(public.held_items, jsonb) FROM PUBLIC, anon, authenticated, service_role;

-- The server's present value beside the held one, per changed field of a lotChange or grnEdit: [{ field, line_ref?, current, held }].
CREATE FUNCTION warehouse_security.held_current(h public.held_items) RETURNS jsonb
  LANGUAGE plpgsql STABLE
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
DECLARE
  v_uuid constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  v_out jsonb := '[]'::jsonb;
  v_g jsonb;
  v_t jsonb;
  v_lot text;
  v_field text;
  v_part jsonb;
  v_grn text;
  v_fv jsonb;
BEGIN
  IF h.kind NOT IN ('lotChange', 'grnEdit') THEN RETURN v_out; END IF;
  IF h.kind = 'lotChange' THEN
    v_lot := lower(h.body ->> 'lotId');
    IF v_lot ~ v_uuid THEN SELECT to_jsonb(t) INTO v_t FROM public.goodsreceived_trl t WHERE t.id = v_lot::uuid; END IF;
    FOREACH v_field IN ARRAY ARRAY['rack', 'package_mark'] LOOP
      v_part := h.body #> ARRAY['changes', v_field];
      CONTINUE WHEN jsonb_typeof(v_part) IS DISTINCT FROM 'object' OR NOT v_part ? 'to';
      v_out := v_out || jsonb_build_array(jsonb_build_object('field', v_field, 'line_ref', v_lot, 'current', v_t -> v_field, 'held', v_part -> 'to'));
    END LOOP;
    RETURN v_out;
  END IF;
  -- grnEdit: the header fields, then the lot fields.
  v_grn := h.body ->> 'grnId';
  IF v_grn ~* v_uuid THEN SELECT to_jsonb(g) INTO v_g FROM public.goodsreceived g WHERE g.id = v_grn::uuid; END IF;
  IF jsonb_typeof(h.body -> 'header') = 'object' THEN
    FOR v_field, v_part IN SELECT f.key, f.value FROM jsonb_each(h.body -> 'header') f ORDER BY f.key LOOP
      CONTINUE WHEN jsonb_typeof(v_part) IS DISTINCT FROM 'object' OR NOT v_part ? 'to';
      v_out := v_out || jsonb_build_array(jsonb_build_object('field', v_field, 'current', CASE v_field
        WHEN 'customer_id' THEN jsonb_build_object('id', v_g -> 'customer_id', 'name', v_g -> 'customer_name')
        WHEN 'sender' THEN jsonb_build_object('id', v_g -> 'sender_id', 'name', v_g -> 'sender_name')
        WHEN 'supervisor' THEN jsonb_build_object('id', v_g -> 'supervisor_id', 'name', v_g -> 'supervisor_name')
        ELSE v_g -> v_field END, 'held', v_part -> 'to'));
    END LOOP;
  END IF;
  IF jsonb_typeof(h.body -> 'lots') = 'object' THEN
    FOR v_lot, v_part IN SELECT l.key, l.value FROM jsonb_each(h.body -> 'lots') l ORDER BY l.key LOOP
      CONTINUE WHEN jsonb_typeof(v_part) IS DISTINCT FROM 'object';
      v_t := NULL;
      IF v_lot ~* v_uuid THEN SELECT to_jsonb(t) INTO v_t FROM public.goodsreceived_trl t WHERE t.id = lower(v_lot)::uuid; END IF;
      FOR v_field, v_fv IN SELECT f.key, f.value FROM jsonb_each(v_part) f ORDER BY f.key LOOP
        CONTINUE WHEN jsonb_typeof(v_fv) IS DISTINCT FROM 'object' OR NOT v_fv ? 'to';
        v_out := v_out || jsonb_build_array(jsonb_build_object('field', v_field, 'line_ref', lower(v_lot), 'current', CASE v_field
          WHEN 'item' THEN jsonb_build_object('id', v_t -> 'item_id', 'name', v_t -> 'item_name')
          ELSE v_t -> v_field END, 'held', v_fv -> 'to'));
      END LOOP;
    END LOOP;
  END IF;
  RETURN v_out;
END $$;
ALTER FUNCTION warehouse_security.held_current(public.held_items) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_current(public.held_items) FROM PUBLIC, anon, authenticated, service_role;

-- The items that follow an item (directly or further down) and that can be accepted now: [id].
CREATE FUNCTION warehouse_security.held_now_acceptable(p_id uuid) RETURNS jsonb
  LANGUAGE sql STABLE
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
  SELECT COALESCE(jsonb_agg(d.id ORDER BY d.phone_seq, d.id), '[]'::jsonb)
    FROM (WITH RECURSIVE down(id, phone_seq) AS (
            SELECT c.id, c.phone_seq FROM public.held_items c WHERE c.follows = p_id
            UNION
            SELECT c.id, c.phone_seq FROM public.held_items c JOIN down ON c.follows = down.id)
          SELECT down.id, down.phone_seq FROM down) d
   WHERE warehouse_security.held_can_accept(d.id)
$$;
ALTER FUNCTION warehouse_security.held_now_acceptable(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_now_acceptable(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- The answer of a decision, rebuilt from the row (also the first answer again for a repeated decision key).
CREATE FUNCTION warehouse_security.held_decision_answer(h public.held_items) RETURNS jsonb
  LANGUAGE sql STABLE
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
  SELECT jsonb_build_object('success', true, 'id', h.id, 'state', h.state, 'result', h.result,
    'decided_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = h.decided_by), 'decided_at', h.decided_at,
    'now_acceptable', warehouse_security.held_now_acceptable(h.id))
$$;
ALTER FUNCTION warehouse_security.held_decision_answer(public.held_items) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_decision_answer(public.held_items) FROM PUBLIC, anon, authenticated, service_role;

-- Stores the reason a save's refusal gives (family, code, figures) on the held row when it differs from what the row holds.
-- The code of a refusal answer is its reason, else its error_code unless that is WH409; its figures are the answer without the keys of the
-- refusal itself, or (a rate failure) its data member.
CREATE FUNCTION warehouse_security.held_store_reason(p_id uuid, p_answer jsonb) RETURNS void
  LANGUAGE plpgsql
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
DECLARE
  v_code text;
  v_data jsonb;
  v_family text;
BEGIN
  v_code := COALESCE(NULLIF(p_answer ->> 'reason', ''), CASE WHEN p_answer ->> 'error_code' IS DISTINCT FROM 'WH409' THEN NULLIF(p_answer ->> 'error_code', '') END);
  v_data := CASE WHEN jsonb_typeof(p_answer -> 'data') = 'object' AND p_answer ->> 'reason' IS NULL THEN p_answer -> 'data'
                 ELSE COALESCE(p_answer, '{}'::jsonb) - 'success' - 'error_code' - 'reason' - 'error' - 'message' - 'idempotent' END;
  v_family := warehouse_security.held_reason(v_code);
  UPDATE public.held_items h SET reason = v_family, reason_code = v_code, reason_data = v_data
   WHERE h.id = p_id AND (h.reason, h.reason_code, h.reason_data) IS DISTINCT FROM (v_family, v_code, v_data);
END $$;
ALTER FUNCTION warehouse_security.held_store_reason(uuid, jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_store_reason(uuid, jsonb) FROM PUBLIC, anon, authenticated, service_role;

-- Attaches the confirmed photos of a held item to the document that was made (or that its photos belong to). The files are not moved. A photo of a
-- line is attached when its line_ref resolves ("index:<n>" through the save's item mapping, or a lot id of the GRN); one that does not is left
-- with the held item. A photo already on the document (same path) is not attached twice.
CREATE FUNCTION warehouse_security.held_attach_photos(p_held uuid, p_by uuid, p_grn uuid, p_disp uuid, p_mapping jsonb) RETURNS void
  LANGUAGE plpgsql
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
DECLARE
  v_uuid constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  p public.held_item_photos;
  v_line uuid;
BEGIN
  FOR p IN SELECT x.* FROM public.held_item_photos x WHERE x.held_id = p_held AND x.state = 'confirmed' ORDER BY x.created_at, x.client_photo_id LOOP
    IF p.role = 'dispatch' THEN
      IF p_disp IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.dispatch_images i WHERE i.dispatch_id = p_disp AND i.storage_path = p.path) THEN
        INSERT INTO public.dispatch_images (dispatch_id, storage_path, original_filename, file_size, mime_type, uploaded_by, status)
        VALUES (p_disp, p.path, p.file_name, p.file_size, p.mime_type, p_by, 'confirmed');
      END IF;
    ELSIF p_grn IS NOT NULL THEN
      v_line := NULL;
      IF p.role = 'item' THEN
        IF p.line_ref ~ '^index:[0-9]{1,6}$' THEN
          SELECT (e ->> 'item_id')::uuid INTO v_line FROM jsonb_array_elements(COALESCE(p_mapping, '[]'::jsonb)) e
           WHERE e ->> 'index' = substr(p.line_ref, 7) LIMIT 1;
        ELSIF p.line_ref ~* v_uuid THEN
          SELECT t.id INTO v_line FROM public.goodsreceived_trl t WHERE t.id = p.line_ref::uuid AND t.gr_id = p_grn;
        END IF;
        CONTINUE WHEN v_line IS NULL;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM public.grn_images i WHERE i.grn_id = p_grn AND i.storage_path = p.path) THEN
        INSERT INTO public.grn_images (grn_id, grn_item_id, image_type, storage_path, original_filename, file_size, mime_type, uploaded_by, status)
        VALUES (p_grn, v_line, p.role, p.path, p.file_name, p.file_size, p.mime_type, p_by, 'confirmed');
      END IF;
    END IF;
  END LOOP;
END $$;
ALTER FUNCTION warehouse_security.held_attach_photos(uuid, uuid, uuid, uuid, jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_attach_photos(uuid, uuid, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated, service_role;

-- Runs the kind's own save for a held item, as the recorder (warehouse.held_acting), with the accepting caller's role checks, inside a block that
-- is rolled back for a trial (p_trial) and for a refusal, so nothing is half-saved and a trial leaves no document, number, key or log entry.
-- p_body is the body of an accept with changes (NULL: the held body); the "from" of a field change is rebased past rejected items (held_rebase).
-- Answers { ok, answer (the save's own answer, unchanged), result ({ grn_id, gr_no } or { dispatch_id, disp_no }), body (what was run) }.
CREATE FUNCTION warehouse_security.held_run(p_id uuid, p_body jsonb, p_trial boolean) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
DECLARE
  h public.held_items;
  v_body jsonb;
  v_args jsonb;
  v_data jsonb;
  v_answer jsonb;
  v_result jsonb;
  v_ok boolean := false;
  v_items jsonb[];
  v_rec record;
  v_grn uuid;
  v_disp uuid;
  v_f record;
  v_image uuid;
  v_text text;
BEGIN
  SELECT * INTO h FROM public.held_items x WHERE x.id = p_id;
  v_body := warehouse_security.held_rebase(h, COALESCE(p_body, h.body));
  BEGIN
    PERFORM set_config('warehouse.held_acting', h.recorded_by::text, true);
    CASE h.kind
    WHEN 'newGrn' THEN
      v_args := v_body -> 'args';
      v_answer := public.save_grn(
        p_gr_no => v_args ->> 'p_gr_no', p_date => (v_args ->> 'p_date')::timestamptz, p_customer_id => (v_args ->> 'p_customer_id')::uuid,
        p_customer_name => v_args ->> 'p_customer_name', p_sender_id => (v_args ->> 'p_sender_id')::uuid, p_sender_name => v_args ->> 'p_sender_name',
        p_supervisor_id => (v_args ->> 'p_supervisor_id')::uuid, p_supervisor_name => v_args ->> 'p_supervisor_name',
        p_registration => v_args ->> 'p_registration', p_note => v_args ->> 'p_note',
        p_leon => COALESCE((v_args ->> 'p_leon')::boolean, false), p_pricing_mode => v_args ->> 'p_pricing_mode',
        p_items => COALESCE(NULLIF(v_args -> 'p_items', 'null'::jsonb), '[]'::jsonb), p_images => COALESCE(NULLIF(v_args -> 'p_images', 'null'::jsonb), '[]'::jsonb),
        p_idempotency_key => h.request_key, p_duration_mode => COALESCE(v_args ->> 'p_duration_mode', 'legacy'),
        p_rates => NULLIF(v_args -> 'p_rates', 'null'::jsonb), p_warn_duplicate => false,
        p_issue_number => COALESCE((v_args ->> 'p_issue_number')::boolean, false), p_recorded_at => h.recorded_at);
    WHEN 'newDispatch' THEN
      v_args := v_body -> 'args';
      v_data := (v_args -> 'p_dispatch_data') - 'source_order_id' - 'warn_duplicate' || jsonb_build_object('recorded_at', h.recorded_at);
      v_items := ARRAY(SELECT e FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_args -> 'p_dispatch_items') = 'array'
                                                            THEN v_args -> 'p_dispatch_items' ELSE '[]'::jsonb END) e);
      v_answer := public.create_dispatch_with_stock_check(v_data, v_items, COALESCE((v_args ->> 'p_generate_invoice')::boolean, false), 0, h.request_key);
    WHEN 'lotChange' THEN
      v_answer := public.set_lot_rack_and_mark((v_body ->> 'lotId')::uuid, (v_body -> 'changes') || jsonb_build_object('recorded_at', h.recorded_at), h.request_key);
    WHEN 'grnEdit' THEN
      v_answer := public.apply_grn_changes((v_body ->> 'grnId')::uuid, v_body || jsonb_build_object('recordedAt', h.recorded_at), h.request_key);
    WHEN 'photos' THEN
      SELECT r.grn, r.disp INTO v_grn, v_disp FROM warehouse_security.held_record(h) r;
      IF (v_grn IS NOT NULL AND EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = v_grn AND g.deleted_at IS NULL))
         OR (v_disp IS NOT NULL AND EXISTS (SELECT 1 FROM public.dispatch d WHERE d.id = v_disp AND d.deleted_at IS NULL)) THEN
        v_answer := jsonb_build_object('success', true);
      ELSE
        v_answer := warehouse_security.refuse('RECORD_DELETED', 'The record these photos belong to is no longer there.');
      END IF;
    END CASE;
    v_ok := COALESCE(v_answer ->> 'success', 'false') = 'true';

    IF v_ok THEN
      -- The result, flat: the GRN's or the dispatch's id and number (of the GRN a change or photos belong to).
      IF h.kind = 'newGrn' THEN
        v_grn := (v_answer #>> '{data,grn_id}')::uuid;
      ELSIF h.kind = 'newDispatch' THEN
        v_disp := (v_answer ->> 'dispatch_id')::uuid;
      ELSIF h.kind IN ('lotChange', 'grnEdit') THEN
        v_grn := (v_body ->> 'grnId')::uuid;
      END IF;
      v_result := CASE
        WHEN v_grn IS NOT NULL THEN (SELECT jsonb_build_object('grn_id', g.id, 'gr_no', g.gr_no) FROM public.goodsreceived g WHERE g.id = v_grn)
        WHEN v_disp IS NOT NULL THEN (SELECT jsonb_build_object('dispatch_id', d.id, 'disp_no', d.disp_no) FROM public.dispatch d WHERE d.id = v_disp) END;

      IF NOT p_trial THEN
        IF h.kind IN ('newGrn', 'newDispatch') THEN
          PERFORM warehouse_security.held_attach_photos(h.id, h.recorded_by, v_grn, v_disp, v_answer #> '{data,item_mapping}');
          FOR v_f IN SELECT x.id FROM public.held_items x WHERE x.follows = h.id AND x.kind = 'photos' AND NOT x.needs_decision AND x.state = 'held'
                     ORDER BY x.phone_seq, x.id LOOP
            PERFORM warehouse_security.held_attach_photos(v_f.id, h.recorded_by, v_grn, v_disp, v_answer #> '{data,item_mapping}');
          END LOOP;
        ELSIF h.kind = 'photos' THEN
          PERFORM warehouse_security.held_attach_photos(h.id, h.recorded_by, v_grn, v_disp, NULL);
          -- The photos the edit removed: only ones of this record; one already gone is not an error, one that may not go (the last photo)
          -- stays (the edit's own rule, as the online delete answers it).
          IF jsonb_typeof(h.body -> 'remove') = 'array' THEN
            FOR v_text IN SELECT x FROM jsonb_array_elements_text(h.body -> 'remove') x LOOP
              CONTINUE WHEN v_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
              v_image := v_text::uuid;
              IF v_grn IS NOT NULL AND EXISTS (SELECT 1 FROM public.grn_images i WHERE i.id = v_image AND i.grn_id = v_grn) THEN
                PERFORM public.delete_grn_image(v_image);
              ELSIF v_disp IS NOT NULL AND EXISTS (SELECT 1 FROM public.dispatch_images i WHERE i.id = v_image AND i.dispatch_id = v_disp) THEN
                PERFORM public.delete_dispatch_image(v_image);
              END IF;
            END LOOP;
          END IF;
        END IF;
      END IF;
    END IF;
    IF p_trial OR NOT v_ok THEN
      RAISE EXCEPTION 'held run rolled back' USING ERRCODE = 'WH304';
    END IF;
  EXCEPTION
    WHEN SQLSTATE 'WH304' THEN NULL;
    WHEN OTHERS THEN
      v_ok := false;
      v_result := NULL;
      v_answer := warehouse_security.refuse('HELD_SAVE_FAILED', SQLERRM);
  END;
  PERFORM set_config('warehouse.held_acting', '', true);
  RETURN jsonb_build_object('ok', v_ok, 'answer', v_answer, 'result', v_result, 'body', v_body);
END $$;
ALTER FUNCTION warehouse_security.held_run(uuid, jsonb, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_run(uuid, jsonb, boolean) FROM PUBLIC, anon, authenticated, service_role;

-- ===== 2. the list =====
CREATE FUNCTION public.get_held_items(p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 2000);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
  v_rows jsonb;
  v_total bigint;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_held_items', jsonb_build_object('p_limit', p_limit, 'p_offset', p_offset));
  IF COALESCE(warehouse_security.active_role(), '') NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Administrator or supervisor required' USING ERRCODE = '42501';
  END IF;
  -- Open items only. The oldest chain first (by when it was handed over); an item that follows another comes directly under it.
  WITH RECURSIVE tree(id, path) AS (
      SELECT h.id, ARRAY[lpad((extract(epoch FROM h.handed_at) * 1000000)::bigint::text, 20, '0') || h.id::text]
        FROM public.held_items h
       WHERE h.state = 'held'
         AND (h.follows IS NULL OR NOT EXISTS (SELECT 1 FROM public.held_items p WHERE p.id = h.follows AND p.state = 'held'))
      UNION ALL
      SELECT c.id, t.path || (lpad((extract(epoch FROM c.handed_at) * 1000000)::bigint::text, 20, '0') || c.id::text)
        FROM public.held_items c JOIN tree t ON c.follows = t.id WHERE c.state = 'held'),
    page AS (SELECT t.id, t.path FROM tree t ORDER BY t.path LIMIT v_limit OFFSET v_offset)
  SELECT (SELECT count(*) FROM tree),
         COALESCE(jsonb_agg(warehouse_security.held_row(h) || jsonb_build_object('can_accept', warehouse_security.held_can_accept(h.id)) ORDER BY pg.path), '[]'::jsonb)
    INTO v_total, v_rows
    FROM page pg JOIN public.held_items h ON h.id = pg.id;
  RETURN jsonb_build_object('success', true, 'rows', v_rows, 'total', v_total);
END $$;
ALTER FUNCTION public.get_held_items(integer, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_held_items(integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_held_items(integer, integer) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_held_items(integer, integer) IS
  'WH-304: the holding list (administrators and supervisors): open items only, oldest first, an item that follows another directly under it; {success, rows, total}.';

-- ===== 3. one item with its trial =====
CREATE FUNCTION public.get_held_item(p_id uuid)
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
                                                              'path', f.path, 'state', f.state, 'url', NULL)
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

-- ===== 4. the decision =====
CREATE FUNCTION public.decide_held_item(p_id uuid, p_action text, p_decision_key text, p_reason text DEFAULT NULL, p_body jsonb DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  h public.held_items;
  v_caller uuid;
  v_key text := NULLIF(btrim(p_decision_key), '');
  v_reason text;
  v_body jsonb := CASE WHEN jsonb_typeof(p_body) = 'object' THEN p_body END;
  v_run jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('decide_held_item', jsonb_build_object('p_id', p_id, 'p_action', p_action));
  SELECT p.id INTO v_caller FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();
  IF v_caller IS NULL OR COALESCE(warehouse_security.active_role(), '') NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Administrator or supervisor required' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO h FROM public.held_items x WHERE x.id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN warehouse_security.refuse('HELD_NOT_FOUND', 'This held item is not there.');
  END IF;
  IF p_action IS NULL OR p_action NOT IN ('accept', 'reject') THEN
    RETURN warehouse_security.refuse('HELD_ACTION_INVALID', 'The decision is not understood.');
  END IF;
  IF h.state <> 'held' THEN
    IF v_key IS NOT NULL AND h.decision_key IS NOT DISTINCT FROM v_key THEN
      RETURN warehouse_security.held_decision_answer(h) || jsonb_build_object('idempotent', true);
    END IF;
    RETURN warehouse_security.refuse('HELD_ALREADY_DECIDED', 'This item was already decided.', jsonb_build_object(
      'state', h.state, 'decided_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = h.decided_by), 'decided_at', h.decided_at));
  END IF;
  IF NOT h.needs_decision THEN
    RETURN warehouse_security.refuse('HELD_NO_DECISION', 'This item is decided with the item it goes with.');
  END IF;

  IF p_action = 'reject' THEN
    v_reason := btrim(p_reason, E' \t\r\n');
    IF v_reason IS NULL OR v_reason = '' OR char_length(v_reason) > 500 THEN
      RETURN warehouse_security.refuse('HELD_REASON_REQUIRED', 'A reason is needed to reject an item (at most 500 characters).');
    END IF;
    -- Nothing else is written: the items that follow it are not rejected, except photos that go with it (no decision of their own).
    UPDATE public.held_items x SET state = 'rejected', decided_by = v_caller, decided_at = now(), decision_key = v_key, reject_reason = v_reason
     WHERE x.id = h.id;
    UPDATE public.held_items x SET state = 'rejected', decided_by = v_caller, decided_at = now(), reject_reason = v_reason
     WHERE x.follows = h.id AND x.kind = 'photos' AND NOT x.needs_decision AND x.state = 'held';
  ELSE
    IF NOT warehouse_security.held_can_accept(h.id) THEN
      RETURN warehouse_security.refuse('HELD_FOLLOWS_UNDECIDED', 'An item before this one is not decided yet.');
    END IF;
    IF h.kind = 'photos' THEN v_body := NULL; END IF;
    v_run := warehouse_security.held_run(h.id, v_body, false);
    IF NOT (v_run ->> 'ok')::boolean THEN
      -- The save's own refusal, unchanged; the item stays held with today's reason.
      PERFORM warehouse_security.held_store_reason(h.id, v_run -> 'answer');
      RETURN v_run -> 'answer';
    END IF;
    UPDATE public.held_items x SET state = 'accepted', decided_by = v_caller, decided_at = now(), decision_key = v_key, result = v_run -> 'result',
           accepted_body = CASE WHEN v_body IS NOT NULL THEN v_run -> 'body' END
     WHERE x.id = h.id;
    UPDATE public.held_items x SET state = 'accepted', decided_by = v_caller, decided_at = now(), result = v_run -> 'result'
     WHERE x.follows = h.id AND x.kind = 'photos' AND NOT x.needs_decision AND x.state = 'held';
  END IF;

  SELECT * INTO h FROM public.held_items x WHERE x.id = p_id;
  RETURN warehouse_security.held_decision_answer(h);
END $$;
ALTER FUNCTION public.decide_held_item(uuid, text, text, text, jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.decide_held_item(uuid, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.decide_held_item(uuid, text, text, text, jsonb) TO authenticated, service_role;
COMMENT ON FUNCTION public.decide_held_item(uuid, text, text, text, jsonb) IS
  'WH-304: accept (the kind''s own save under the item''s request key, as the recorder, checked as the caller) or reject (a reason, at most 500 characters) a held item. One decision per item; a repeated decision key answers the first.';

-- ===== 5. the recorder sees the outcome =====
CREATE FUNCTION public.mark_held_item_seen(p_id uuid)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_caller uuid;
  h public.held_items;
BEGIN
  PERFORM warehouse_security.authorize_rpc('mark_held_item_seen', jsonb_build_object('p_id', p_id));
  SELECT p.id INTO v_caller FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'Active account required' USING ERRCODE = '42501';
  END IF;
  -- Only the recorder's own item: whether another person's exists is not told.
  SELECT * INTO h FROM public.held_items x WHERE x.id = p_id AND x.recorded_by = v_caller FOR UPDATE;
  IF NOT FOUND THEN
    RETURN warehouse_security.refuse('HELD_NOT_FOUND', 'This held item is not there.');
  END IF;
  IF h.state = 'held' THEN
    RETURN warehouse_security.refuse('HELD_NOT_DECIDED', 'This item is not decided yet.');
  END IF;
  IF h.seen_at IS NULL THEN
    UPDATE public.held_items x SET seen_at = now() WHERE x.id = h.id;
  END IF;
  RETURN jsonb_build_object('success', true);
END $$;
ALTER FUNCTION public.mark_held_item_seen(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.mark_held_item_seen(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_held_item_seen(uuid) TO authenticated, service_role;
COMMENT ON FUNCTION public.mark_held_item_seen(uuid) IS
  'WH-304: the recorder marks a decided item of their own as seen (once; a repeat writes nothing).';

NOTIFY pgrst, 'reload schema';
