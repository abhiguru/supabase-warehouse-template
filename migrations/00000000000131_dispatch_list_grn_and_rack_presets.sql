-- Migration 131: the GRN of each dispatch line in the dispatch lists, and the rack presets of the GRN item form.
--
--  * get_dispatch_list_with_items (with items) adds `grn_id` (goodsreceived.id) to each item object; it already carries `grn_qty`.
--    get_recent_dispatched_orders adds `grn_qty` (the quantity received on the lot) and `grn_id` to each item object. Fields are only
--    added, signatures, grants and the authorize_rpc calls stay, so an older app keeps working. The app opens the GRN from `grn_id`.
--  * Rack presets: the Floor and Chamber buttons of the GRN item form, one list per facility, the same on every phone.
--    warehouse_security.rack_presets holds the labels (kind floor or chamber, position), warehouse_security.rack_preset_state the
--    version of the two lists together. Neither table has a grant for an app role: the RPCs below are the only readers and writers.
--    The rows start as the buttons the app had built in (BASE, F1 to F4; C4, C7, C2, Anti-Ch), version 1; racks already saved never change.
--    get_rack_presets() answers both lists and the version (administrators, supervisors and staff); set_rack_presets(p_floor, p_chamber,
--    p_version) replaces both lists in one transaction (administrators and supervisors; staff and customers are refused by the guard).
--    A save made from an older version is refused with PRESETS_CHANGED (and the current lists), so two managers do not overwrite each
--    other; there is no history table. A label is not empty, has at most 12 characters, has no "/" (the rack separator) and no control
--    character, and is unique across both lists whatever its case (spaces around it are cut). At most 20 labels per list; a list may be
--    empty. The same lists as stored again change nothing and answer success with changed false (a resend after a lost answer).
--    authorize_rpc's staff entry for get_rack_presets is in migrations/definitions/00_authorize_rpc.sql.

-- Section 1: grn_id in the two dispatch list functions.
DO $patch$
DECLARE
  v_def text;
  v_count integer;
BEGIN
  v_def := pg_get_functiondef('public.get_dispatch_list_with_items(uuid, jsonb, text, text, integer, integer, boolean)'::regprocedure);
  v_count := (length(v_def) - length(replace(v_def, $m$''grn_item_id'', grt.id, $m$, ''))) / length($m$''grn_item_id'', grt.id, $m$);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_dispatch_list_with_items: expected the item marker once, found % times', v_count; END IF;
  v_def := replace(v_def, $m$''grn_item_id'', grt.id, $m$, $m$''grn_item_id'', grt.id, ''grn_id'', gr.id, $m$);
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.get_recent_dispatched_orders(integer, integer)'::regprocedure);
  v_count := (length(v_def) - length(replace(v_def, $m$                    'weight', grt.weight
$m$, ''))) / length($m$                    'weight', grt.weight
$m$);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_recent_dispatched_orders: expected the item marker once, found % times', v_count; END IF;
  v_def := replace(v_def, $m$                    'weight', grt.weight
$m$, $m$                    'weight', grt.weight,
                    'grn_qty', grt.qty,
                    'grn_id', gr.id
$m$);
  EXECUTE v_def;
END
$patch$;

-- Section 2: the rack presets.
CREATE TABLE warehouse_security.rack_presets (
    kind text NOT NULL,
    label text NOT NULL,
    "position" integer NOT NULL,
    CONSTRAINT rack_presets_pkey PRIMARY KEY (kind, label),
    CONSTRAINT rack_presets_position_key UNIQUE (kind, "position"),
    CONSTRAINT rack_presets_kind_check CHECK (kind IN ('floor', 'chamber')),
    CONSTRAINT rack_presets_label_check CHECK (label = btrim(label) AND label <> '' AND char_length(label) <= 12
        AND position('/' IN label) = 0 AND label !~ '[[:cntrl:]]'),
    CONSTRAINT rack_presets_position_check CHECK ("position" >= 1)
);
-- One label is one button: not in both lists either, and "f1" is "F1".
CREATE UNIQUE INDEX rack_presets_label_key ON warehouse_security.rack_presets (lower(label));
ALTER TABLE warehouse_security.rack_presets OWNER TO supabase_admin;
ALTER TABLE warehouse_security.rack_presets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.rack_presets FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE warehouse_security.rack_presets IS 'Migration 131: the Floor and Chamber buttons of the GRN item form; read and written only through get_rack_presets and set_rack_presets.';

CREATE TABLE warehouse_security.rack_preset_state (
    singleton boolean DEFAULT true NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT rack_preset_state_pkey PRIMARY KEY (singleton),
    CONSTRAINT rack_preset_state_singleton_check CHECK (singleton)
);
ALTER TABLE warehouse_security.rack_preset_state OWNER TO supabase_admin;
ALTER TABLE warehouse_security.rack_preset_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.rack_preset_state FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE warehouse_security.rack_preset_state IS 'Migration 131: one row, the version of the two rack preset lists together (a save from an older version is refused).';

INSERT INTO warehouse_security.rack_presets(kind, label, "position") VALUES
  ('floor', 'BASE', 1), ('floor', 'F1', 2), ('floor', 'F2', 3), ('floor', 'F3', 4), ('floor', 'F4', 5),
  ('chamber', 'C4', 1), ('chamber', 'C7', 2), ('chamber', 'C2', 3), ('chamber', 'Anti-Ch', 4);
INSERT INTO warehouse_security.rack_preset_state(singleton, version) VALUES (true, 1);

-- The answer of both RPCs (and the data of a refusal): the two lists in order, the version and the limits.
CREATE FUNCTION warehouse_security.rack_presets_json() RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT jsonb_build_object(
    'floor', COALESCE((SELECT jsonb_agg(p.label ORDER BY p."position") FROM warehouse_security.rack_presets p WHERE p.kind = 'floor'), '[]'::jsonb),
    'chamber', COALESCE((SELECT jsonb_agg(p.label ORDER BY p."position") FROM warehouse_security.rack_presets p WHERE p.kind = 'chamber'), '[]'::jsonb),
    'version', s.version, 'updated_at', s.updated_at, 'max_label_length', 12, 'max_per_list', 20)
  FROM warehouse_security.rack_preset_state s
$$;
ALTER FUNCTION warehouse_security.rack_presets_json() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.rack_presets_json() FROM PUBLIC;

CREATE FUNCTION public.get_rack_presets() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_rack_presets', jsonb_build_object());
  RETURN jsonb_build_object('success', true) || warehouse_security.rack_presets_json();
END $$;
ALTER FUNCTION public.get_rack_presets() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_rack_presets() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_rack_presets() TO authenticated, service_role;

CREATE FUNCTION public.set_rack_presets(p_floor text[], p_chamber text[], p_version integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_group text;
  v_list text[];
  v_clean text[];
  v_floor text[] := '{}';
  v_chamber text[] := '{}';
  v_seen text[] := '{}';
  v_label text;
  v_index bigint;
  v_state warehouse_security.rack_preset_state;
  v_by uuid;
BEGIN
  PERFORM warehouse_security.authorize_rpc('set_rack_presets', jsonb_build_object('p_version', p_version));
  -- Administrators and supervisors (authorize_rpc lets them through and refuses staff and customers); the body does not depend on it.
  IF COALESCE(warehouse_security.active_role(), '') NOT IN ('admin', 'supervisor') AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  IF p_floor IS NULL OR p_chamber IS NULL THEN
    RETURN warehouse_security.refuse('LIST_REQUIRED', 'Both lists are required.');
  END IF;
  IF p_version IS NULL THEN
    RETURN warehouse_security.refuse('VERSION_REQUIRED', 'The version of the lists you changed is required.');
  END IF;
  FOREACH v_group IN ARRAY ARRAY['floor', 'chamber'] LOOP
    v_list := CASE v_group WHEN 'floor' THEN p_floor ELSE p_chamber END;
    v_clean := '{}';
    IF COALESCE(cardinality(v_list), 0) > 20 THEN
      RETURN warehouse_security.refuse('TOO_MANY', 'A list can have at most 20 presets.', jsonb_build_object('list', v_group, 'limit', 20));
    END IF;
    FOR v_label, v_index IN SELECT t.x, t.n FROM unnest(v_list) WITH ORDINALITY AS t(x, n) ORDER BY t.n LOOP
      v_label := btrim(v_label);
      IF v_label IS NULL OR v_label = '' THEN
        RETURN warehouse_security.refuse('LABEL_EMPTY', 'A preset can not be empty.', jsonb_build_object('list', v_group, 'index', v_index));
      ELSIF char_length(v_label) > 12 THEN
        RETURN warehouse_security.refuse('LABEL_TOO_LONG', 'A preset can have at most 12 characters.',
          jsonb_build_object('list', v_group, 'index', v_index, 'label', v_label, 'limit', 12));
      ELSIF position('/' IN v_label) > 0 OR v_label ~ '[[:cntrl:]]' THEN
        RETURN warehouse_security.refuse('LABEL_CHARACTER', 'A preset can not have a "/" or a control character.',
          jsonb_build_object('list', v_group, 'index', v_index, 'label', v_label));
      ELSIF lower(v_label) = ANY (v_seen) THEN
        RETURN warehouse_security.refuse('LABEL_DUPLICATE', 'A preset can be in the lists only once.',
          jsonb_build_object('list', v_group, 'index', v_index, 'label', v_label));
      END IF;
      v_seen := v_seen || lower(v_label);
      v_clean := v_clean || v_label;
    END LOOP;
    IF v_group = 'floor' THEN v_floor := v_clean; ELSE v_chamber := v_clean; END IF;
  END LOOP;

  -- Two managers saving at once take turns on the state row.
  SELECT * INTO v_state FROM warehouse_security.rack_preset_state WHERE singleton FOR UPDATE;
  -- The lists asked for are the lists stored: nothing to write, whatever the version (a resend after a lost answer).
  IF COALESCE((SELECT array_agg(p.label ORDER BY p."position") FROM warehouse_security.rack_presets p WHERE p.kind = 'floor'), '{}'::text[]) = v_floor
     AND COALESCE((SELECT array_agg(p.label ORDER BY p."position") FROM warehouse_security.rack_presets p WHERE p.kind = 'chamber'), '{}'::text[]) = v_chamber THEN
    RETURN jsonb_build_object('success', true, 'changed', false) || warehouse_security.rack_presets_json();
  END IF;
  IF v_state.version IS DISTINCT FROM p_version THEN
    RETURN warehouse_security.refuse('PRESETS_CHANGED', 'Someone else changed the rack presets. Reload to see their changes.',
      warehouse_security.rack_presets_json());
  END IF;
  v_by := public.get_current_user_profile_id();
  DELETE FROM warehouse_security.rack_presets WHERE true;
  INSERT INTO warehouse_security.rack_presets(kind, label, "position") SELECT 'floor', t.x, t.n FROM unnest(v_floor) WITH ORDINALITY AS t(x, n);
  INSERT INTO warehouse_security.rack_presets(kind, label, "position") SELECT 'chamber', t.x, t.n FROM unnest(v_chamber) WITH ORDINALITY AS t(x, n);
  UPDATE warehouse_security.rack_preset_state SET version = version + 1, updated_at = now(), updated_by = v_by WHERE singleton;
  RETURN jsonb_build_object('success', true, 'changed', true) || warehouse_security.rack_presets_json();
END $$;
ALTER FUNCTION public.set_rack_presets(text[], text[], integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.set_rack_presets(text[], text[], integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_rack_presets(text[], text[], integer) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
