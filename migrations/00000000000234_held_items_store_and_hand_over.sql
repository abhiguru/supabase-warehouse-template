-- Topics "held items store" and "hand over held items" (WH-304; contract tech/app-offline-holding-list.md sections 2.1, 2.2, 11.1 to 11.3,
-- 11.6). Named by topic; its number is taken when the work is assembled for main. It needs WH-161's topics (request keys on offline records)
-- and WH-303's (apply_grn_changes, replaced entries) applied before it.
--  1. public.held_items: the items a phone could not save (the server refused them) and a supervisor or administrator decides. Rows are
--     never deleted and never dropped for age. No grant to any app role: read and written only by the functions of this topic and of
--     "holding list reads" and "decide a held item". public.held_item_photos: the photos of a held item, PK (held_id, client_photo_id).
--  2. warehouse_security.held_reason(code): the one map from a refusal code to its family (IMMUTABLE, never raises; an unknown code is 'other').
--  3. public.hold_items(p_items jsonb, p_recorder uuid DEFAULT NULL): a phone hands over its refused items with what follows them (at most 50
--     in one transaction); an administrator hands over another person's unsent items ("move"). A repeated key answers the first row.
-- No role is created, altered or dropped. No pg_temp helper is left behind. The photo upload pair (register and confirm) is a later topic.

-- ===== 1. the tables =====
CREATE TABLE public.held_items (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_key    text NOT NULL UNIQUE,
  kind           text NOT NULL CHECK (kind IN ('newGrn', 'newDispatch', 'grnEdit', 'lotChange', 'photos')),
  body           jsonb NOT NULL CHECK (jsonb_typeof(body) = 'object'),
  source         text NOT NULL CHECK (source IN ('refused', 'follows', 'moved')),
  follows        uuid REFERENCES public.held_items(id),
  phone_seq      integer NOT NULL,
  recorded_by    uuid NOT NULL REFERENCES public.user_profiles(id),
  recorded_at    timestamptz NOT NULL,
  phone          text,
  handed_by      uuid NOT NULL REFERENCES public.user_profiles(id),
  handed_at      timestamptz NOT NULL DEFAULT now(),
  customer_id    uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  grn_id         uuid,
  dispatch_id    uuid,
  what           jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(what) = 'object'),
  lines          jsonb,
  reason         text NOT NULL,
  reason_code    text,
  reason_data    jsonb NOT NULL DEFAULT '{}'::jsonb,
  state          text NOT NULL DEFAULT 'held' CHECK (state IN ('held', 'accepted', 'rejected')),
  needs_decision boolean NOT NULL DEFAULT true,
  decided_by     uuid REFERENCES public.user_profiles(id),
  decided_at     timestamptz,
  decision_key   text,
  reject_reason  text,
  accepted_body  jsonb,
  result         jsonb,
  seen_at        timestamptz
);
ALTER TABLE public.held_items OWNER TO supabase_admin;
ALTER TABLE public.held_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.held_items FROM PUBLIC, anon, authenticated, service_role;
CREATE INDEX held_items_state_handed ON public.held_items (state, handed_at, id);
CREATE INDEX held_items_recorder ON public.held_items (recorded_by, state);
CREATE INDEX held_items_follows ON public.held_items (follows) WHERE follows IS NOT NULL;
COMMENT ON TABLE public.held_items IS
  'WH-304: items a phone could not save because the server refused them, waiting for a supervisor or administrator (accept, correct or reject). Never deleted. No app role reads it; the holding-list functions and the sync feed do.';

CREATE TABLE public.held_item_photos (
  held_id         uuid NOT NULL REFERENCES public.held_items(id),
  client_photo_id text NOT NULL,
  path            text NOT NULL,
  role            text NOT NULL CHECK (role IN ('header', 'item', 'dispatch')),
  line_ref        text,
  file_name       text NOT NULL,
  file_size       integer NOT NULL CHECK (file_size > 0 AND file_size <= 10485760),
  mime_type       text NOT NULL CHECK (mime_type IN ('image/jpeg', 'image/png', 'image/webp')),
  state           text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'confirmed')),
  uploaded_by     uuid REFERENCES public.user_profiles(id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (held_id, client_photo_id)
);
ALTER TABLE public.held_item_photos OWNER TO supabase_admin;
ALTER TABLE public.held_item_photos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.held_item_photos FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE public.held_item_photos IS
  'WH-304: the photos of a held item (files under a held prefix of the photo bucket). Attached to the new document on accept, kept with the item on reject.';

-- ===== 2. the reason families =====
CREATE FUNCTION warehouse_security.held_reason(p_code text) RETURNS text
  LANGUAGE sql IMMUTABLE
  SET search_path TO 'pg_catalog'
AS $$
  SELECT CASE p_code
    WHEN 'STOCK_SHORT' THEN 'stockShort'
    WHEN 'RATE_MISSING' THEN 'noRate'
    WHEN 'NUMBER_TAKEN' THEN 'numberUsed'
    WHEN 'NUMBER_FORMAT' THEN 'numberFormat'
    WHEN 'GRN_NUMBER_SPACES' THEN 'numberFormat'
    WHEN 'DISPATCH_NUMBER_SPACES' THEN 'numberFormat'
    WHEN 'GRN_DATE_FUTURE' THEN 'dateRefused'
    WHEN 'DISPATCH_DATE_FUTURE' THEN 'dateRefused'
    WHEN 'DISPATCH_BEFORE_GRN' THEN 'dateRefused'
    WHEN 'GRN_DATE_AFTER_DISPATCH' THEN 'dateRefused'
    WHEN 'RECORDED_TIME_FUTURE' THEN 'dateRefused'
    WHEN 'POSSIBLE_DUPLICATE' THEN 'duplicate'
    WHEN 'LOT_NOT_FOUND' THEN 'deleted'
    WHEN 'GRN_NOT_FOUND' THEN 'deleted'
    WHEN 'RECORD_DELETED' THEN 'deleted'
    WHEN 'GRN_DATE_LOCKED' THEN 'locked'
    WHEN 'GRN_INVOICED' THEN 'locked'
    WHEN 'LOT_INVOICED' THEN 'locked'
    WHEN 'LOT_DISPATCHED' THEN 'locked'
    WHEN 'LINE_DISPATCHED_BEFORE' THEN 'locked'
    WHEN 'LINE_ON_ORDER' THEN 'locked'
    WHEN 'GRN_CUSTOMER_LOCKED' THEN 'locked'
    WHEN 'GRN_PRICING_MODE_LOCKED' THEN 'locked'
    WHEN 'QTY_BELOW_DISPATCHED' THEN 'belowDispatched'
    ELSE 'other' END
$$;
ALTER FUNCTION warehouse_security.held_reason(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.held_reason(text) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION warehouse_security.held_reason(text) IS
  'WH-304: the reason family of a refusal code (stockShort, noRate, numberUsed, numberFormat, dateRefused, duplicate, deleted, locked, belowDispatched or other). An unknown, empty or NULL code is other.';

-- ===== 3. the hand-over =====
CREATE FUNCTION public.hold_items(p_items jsonb, p_recorder uuid DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_uuid constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
  v_role text;
  v_caller uuid;
  v_recorder uuid;
  v_moved boolean := false;
  v_ord integer;
  v_e jsonb;
  v_key text;
  v_kind text;
  v_body jsonb;
  v_what jsonb;
  v_seq integer;
  v_at timestamptz;
  v_fk text;
  v_ref jsonb;
  v_code text;
  v_data jsonb;
  v_sid text;
  v_phone text;
  v_existing public.held_items%ROWTYPE;
  v_parent public.held_items%ROWTYPE;
  v_source text;
  v_reason text;
  v_needs boolean;
  v_customer uuid;
  v_lines jsonb;
  v_text text;
  v_grn uuid;
  v_disp uuid;
  v_id uuid;
  v_answers jsonb[];
BEGIN
  PERFORM warehouse_security.authorize_rpc('hold_items', jsonb_build_object());
  v_role := warehouse_security.active_role();
  SELECT p.id INTO v_caller FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();
  IF v_role IS NULL OR v_role NOT IN ('admin', 'supervisor', 'staff') OR v_caller IS NULL THEN
    RAISE EXCEPTION 'Staff access required' USING ERRCODE = '42501';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RETURN warehouse_security.refuse('HELD_ITEM_INVALID', 'The items are not understood.');
  END IF;
  IF jsonb_array_length(p_items) > 50 THEN
    RETURN warehouse_security.refuse('HELD_TOO_MANY_ITEMS', 'At most 50 items can be handed over at once.', jsonb_build_object('limit', 50));
  END IF;

  -- Who the items are for: the caller, or (administrators only, a move) another person of this facility, whatever their role or state now.
  IF p_recorder IS NULL OR p_recorder = auth.uid() THEN
    v_recorder := v_caller;
  ELSE
    IF v_role <> 'admin' THEN
      RETURN warehouse_security.refuse('HELD_MOVE_ADMIN_ONLY', 'Only an administrator can move another person''s items.');
    END IF;
    SELECT p.id INTO v_recorder FROM public.user_profiles p WHERE p.auth_user_id = p_recorder;
    IF v_recorder IS NULL THEN
      RETURN warehouse_security.refuse('HELD_RECORDER_UNKNOWN', 'That person is not known here.');
    END IF;
    v_moved := true;
  END IF;

  -- ---- Every item is checked before anything is written (one transaction, all or nothing). ----
  FOR v_ord, v_e IN SELECT t.ord::integer, t.e FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, ord) LOOP
    v_key := CASE WHEN jsonb_typeof(v_e) = 'object' AND jsonb_typeof(v_e -> 'request_key') = 'string' THEN btrim(v_e ->> 'request_key') END;
    IF v_key IS NULL OR v_key = '' THEN
      RETURN warehouse_security.refuse('HELD_ITEM_INVALID', 'An item has no request key.', jsonb_build_object('index', v_ord - 1));
    END IF;
    IF jsonb_typeof(v_e -> 'kind') IS DISTINCT FROM 'string'
       OR NOT (v_e ->> 'kind') IN ('newGrn', 'newDispatch', 'grnEdit', 'lotChange', 'photos')
       OR jsonb_typeof(v_e -> 'body') IS DISTINCT FROM 'object'
       OR COALESCE(jsonb_typeof(v_e -> 'what'), 'object') NOT IN ('object', 'null')
       OR jsonb_typeof(v_e -> 'seq') IS DISTINCT FROM 'number' OR (v_e ->> 'seq') !~ '^-?[0-9]{1,9}$'
       OR jsonb_typeof(v_e -> 'recorded_at') IS DISTINCT FROM 'string'
       OR COALESCE(jsonb_typeof(v_e -> 'follows_key'), 'string') NOT IN ('string', 'null')
       OR COALESCE(jsonb_typeof(v_e -> 'refusal'), 'object') NOT IN ('object', 'null') THEN
      RETURN warehouse_security.refuse('HELD_ITEM_INVALID', 'An item is not understood.', jsonb_build_object('request_key', v_key));
    END IF;
    BEGIN
      v_at := (v_e ->> 'recorded_at')::timestamptz;
    EXCEPTION WHEN others THEN
      RETURN warehouse_security.refuse('HELD_ITEM_INVALID', 'The time of an item is not understood.', jsonb_build_object('request_key', v_key));
    END;
    IF octet_length((v_e -> 'body')::text) + octet_length(COALESCE(NULLIF(v_e -> 'what', 'null'::jsonb), '{}'::jsonb)::text) > 65536 THEN
      RETURN warehouse_security.refuse('HELD_BODY_TOO_LARGE', 'This item is too large to hold.', jsonb_build_object('request_key', v_key, 'limit', 65536));
    END IF;
  END LOOP;
  -- A follower names an item that comes before it in this call, or one already held for the same person.
  FOR v_ord, v_e IN SELECT t.ord::integer, t.e FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, ord) LOOP
    v_fk := NULLIF(btrim(v_e ->> 'follows_key'), '');
    CONTINUE WHEN v_fk IS NULL;
    v_seq := (v_e ->> 'seq')::integer;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, ord)
                    WHERE btrim(t.e ->> 'request_key') = v_fk AND ((t.e ->> 'seq')::integer, t.ord) < (v_seq, v_ord))
       AND NOT EXISTS (SELECT 1 FROM public.held_items h WHERE h.request_key = v_fk AND h.recorded_by = v_recorder) THEN
      RETURN warehouse_security.refuse('HELD_ITEM_INVALID', 'An item follows an item that is not held.',
        jsonb_build_object('request_key', btrim(v_e ->> 'request_key')));
    END IF;
  END LOOP;

  -- The handing session's phone (its user agent), when the session is known.
  v_sid := auth.jwt() ->> 'session_id';
  IF v_sid ~* v_uuid THEN
    SELECT s.user_agent INTO v_phone FROM warehouse_security.refresh_sessions s WHERE s.id = v_sid::uuid;
  END IF;

  v_answers := array_fill('null'::jsonb, ARRAY[jsonb_array_length(p_items)]);

  -- ---- Written in phone order (seq); the answer keeps the order of p_items. ----
  FOR v_ord, v_e IN SELECT t.ord::integer, t.e FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, ord)
                    ORDER BY (t.e ->> 'seq')::integer, t.ord LOOP
    v_key := btrim(v_e ->> 'request_key');
    v_kind := v_e ->> 'kind';
    v_body := v_e -> 'body';
    v_what := COALESCE(NULLIF(v_e -> 'what', 'null'::jsonb), '{}'::jsonb);
    v_seq := (v_e ->> 'seq')::integer;
    v_at := LEAST((v_e ->> 'recorded_at')::timestamptz, now());
    v_fk := NULLIF(btrim(v_e ->> 'follows_key'), '');
    v_ref := NULLIF(v_e -> 'refusal', 'null'::jsonb);

    -- A repeated key gets the first answer; the same key for another kind or another person is refused for that item only.
    PERFORM pg_advisory_xact_lock(hashtextextended('hold_items:' || v_key, 0));
    SELECT * INTO v_existing FROM public.held_items h WHERE h.request_key = v_key;
    IF FOUND THEN
      IF v_existing.kind = v_kind AND v_existing.recorded_by = v_recorder THEN
        v_answers[v_ord] := jsonb_build_object('request_key', v_key, 'id', v_existing.id, 'state', v_existing.state, 'idempotent', true);
      ELSE
        v_answers[v_ord] := jsonb_build_object('request_key', v_key, 'reason', 'REQUEST_KEY_REUSED');
      END IF;
      CONTINUE;
    END IF;

    v_parent := NULL;
    IF v_fk IS NOT NULL THEN
      SELECT * INTO v_parent FROM public.held_items h WHERE h.request_key = v_fk;
    END IF;
    v_needs := NOT (v_kind = 'photos' AND COALESCE(v_parent.kind IN ('newGrn', 'newDispatch'), false));
    v_source := CASE WHEN v_fk IS NOT NULL THEN 'follows' WHEN v_moved THEN 'moved' ELSE 'refused' END;

    v_code := CASE WHEN jsonb_typeof(v_ref -> 'code') = 'string' THEN NULLIF(btrim(v_ref ->> 'code'), '') END;
    v_data := CASE WHEN jsonb_typeof(v_ref -> 'data') = 'object' THEN v_ref -> 'data' ELSE '{}'::jsonb END;
    v_reason := CASE
      WHEN v_fk IS NOT NULL THEN 'followsHeld'
      WHEN v_ref IS NOT NULL THEN warehouse_security.held_reason(v_code)
      WHEN v_moved THEN 'moved'
      ELSE 'other' END;

    -- Derived by the server from the body, never taken from the phone.
    v_customer := NULL;
    IF jsonb_typeof(v_e -> 'customer_id') = 'string' AND (v_e ->> 'customer_id') ~* v_uuid THEN
      SELECT c.id INTO v_customer FROM public.customers c WHERE c.id = (v_e ->> 'customer_id')::uuid;
    END IF;
    v_lines := NULL;
    IF v_kind = 'newDispatch' THEN
      SELECT COALESCE(jsonb_agg(jsonb_build_object('lot_id', x.lot, 'qty', x.qty) ORDER BY x.n), '[]'::jsonb) INTO v_lines
        FROM (SELECT t.n, t.e ->> 'gr_trl_id' AS lot,
                     CASE WHEN jsonb_typeof(t.e -> 'disp_qty') = 'number' AND (t.e ->> 'disp_qty') ~ '^[0-9]{1,9}$' THEN (t.e ->> 'disp_qty')::integer END AS qty
                FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_body #> '{args,p_dispatch_items}') = 'array'
                                               THEN v_body #> '{args,p_dispatch_items}' ELSE '[]'::jsonb END) WITH ORDINALITY AS t(e, n)
               WHERE jsonb_typeof(t.e) = 'object') x
       WHERE x.lot ~* v_uuid AND x.qty > 0;
    END IF;
    v_text := CASE WHEN v_kind IN ('lotChange', 'grnEdit') THEN v_body ->> 'grnId'
                   WHEN v_kind = 'photos' AND v_body ->> 'doc' = 'grn' THEN v_body ->> 'recordId' END;
    v_grn := NULL;
    IF v_text ~* v_uuid THEN SELECT g.id INTO v_grn FROM public.goodsreceived g WHERE g.id = v_text::uuid; END IF;
    v_text := CASE WHEN v_kind = 'photos' AND v_body ->> 'doc' = 'dispatch' THEN v_body ->> 'recordId' END;
    v_disp := NULL;
    IF v_text ~* v_uuid THEN SELECT d.id INTO v_disp FROM public.dispatch d WHERE d.id = v_text::uuid; END IF;

    INSERT INTO public.held_items (request_key, kind, body, source, follows, phone_seq, recorded_by, recorded_at, phone, handed_by,
                                   customer_id, grn_id, dispatch_id, what, lines, reason, reason_code, reason_data, state, needs_decision)
    VALUES (v_key, v_kind, v_body, v_source, v_parent.id, v_seq, v_recorder, v_at, v_phone, v_caller,
            v_customer, v_grn, v_disp, v_what, v_lines, v_reason, v_code, v_data, 'held', v_needs)
    RETURNING id INTO v_id;
    v_answers[v_ord] := jsonb_build_object('request_key', v_key, 'id', v_id, 'state', 'held');
  END LOOP;

  RETURN jsonb_build_object('success', true, 'held', to_jsonb(v_answers));
END $$;
ALTER FUNCTION public.hold_items(jsonb, uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.hold_items(jsonb, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.hold_items(jsonb, uuid) TO authenticated, service_role;
COMMENT ON FUNCTION public.hold_items(jsonb, uuid) IS
  'WH-304: a phone hands over its refused items and what follows them (at most 50, one transaction); an administrator hands over another person''s unsent items (p_recorder). A repeated request key answers its first row.';

NOTIFY pgrst, 'reload schema';
