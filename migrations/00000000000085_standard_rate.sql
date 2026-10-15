-- Migration 85: the facility's standard rate (owner decisions of 2026-10-15).
--
-- 1. public.standard_rate_tiers: the facility's standard monthly rate, weight tiers with rent,
--    labour and tax (whole kilograms, from 0, no gaps). Row level security is on; administrators
--    and supervisors read it, no app role writes it; it is written by set_standard_rate only.
-- 2. public.get_standard_rate(): the tiers, when they were saved and by whom (admin, supervisor,
--    staff).
-- 3. public.set_standard_rate(p_tiers): administrators and supervisors replace the tiers (the
--    same rules and texts as replace_item_rates). Every active item that has no default rate row
--    at all then gets the tiers as monthly default rows, from the India day of its first GRN
--    that is not deleted, else from today. Items that have any default row (also one that ended
--    or was stopped) and inactive items are left alone; an item with customer rates only has no
--    default row and gets the tiers.
-- 4. public.create_item gets p_rate_from_item (DROP + CREATE; the old four-argument call still
--    works through the default): the new item gets a copy of that item's default rows in force
--    today, else the standard tiers from today, else no rate. The answer names rate_source.
-- 5. public.update_item: an item that turns active and has no default row gets the standard
--    tiers from today.
-- 6. The guard admits get_standard_rate (staff too) and set_standard_rate (staff reach its body,
--    which refuses them with STANDARD_RATE_MANAGER_ONLY).
--
-- A later change of the standard rate does not change an item that already has a rate. Errors of
-- the new functions follow migration 74: {success:false, error, error_code, data}.

-- Replaces one marker in a function body, failing unless it occurs exactly
-- `expected` times. Dropped at the end of this migration. A second direct run of the
-- file fails at CREATE TABLE; the ledger skips an applied file, so it never runs twice.
CREATE FUNCTION pg_temp.patch_rpc(fn regprocedure, marker text, replacement text, expected integer DEFAULT 1) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE definition text := pg_get_functiondef(fn); occurrences integer;
BEGIN
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker,80);
  END IF;
  EXECUTE replace(definition,marker,replacement);
END $$;

-- ---------------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------------
CREATE TABLE public.standard_rate_tiers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  weight_min integer NOT NULL,
  weight_max integer NOT NULL,
  unit_price numeric(12,2) NOT NULL,
  labour_rate numeric(12,2) NOT NULL,
  tax_percent numeric(5,2) NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  CONSTRAINT standard_rate_tiers_weight_valid CHECK (weight_min >= 0 AND weight_min <= weight_max AND weight_max <= 100000),
  CONSTRAINT standard_rate_tiers_unit_price_valid CHECK (unit_price >= 0 AND unit_price <= 999999),
  CONSTRAINT standard_rate_tiers_labour_rate_valid CHECK (labour_rate >= 0 AND labour_rate <= 999999),
  CONSTRAINT standard_rate_tiers_tax_percent_valid CHECK (tax_percent >= 0 AND tax_percent <= 100),
  CONSTRAINT standard_rate_tiers_weight_min_key UNIQUE (weight_min)
);
COMMENT ON TABLE public.standard_rate_tiers IS
  'The facility''s standard monthly rate (migration 85): weight tiers, whole kilograms, from 0 without gaps. Written by set_standard_rate only; new items get it.';
ALTER TABLE public.standard_rate_tiers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.standard_rate_tiers FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.standard_rate_tiers TO authenticated;
-- Read like the business tables since migration 42: administrators and supervisors; staff read it
-- through get_standard_rate. No write policy and no write grant.
CREATE POLICY starter_staff ON public.standard_rate_tiers FOR SELECT TO authenticated
  USING (warehouse_security.active_role() IN ('admin','supervisor'));

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
-- The tier list of set_standard_rate: NULL when it is valid, else the failure answer. The limits
-- and texts are those of replace_item_rates (migration 76) for a monthly default rate.
CREATE FUNCTION warehouse_security.standard_rate_failure(p_tiers jsonb) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, public AS $$
DECLARE
  v_band jsonb; v_ord integer; v_field text; v_n numeric; v_limit numeric;
  v_prev_max integer; v_expected integer; v_min integer; v_max integer;
BEGIN
  IF p_tiers IS NULL OR jsonb_typeof(p_tiers) <> 'array' OR jsonb_array_length(p_tiers) = 0 OR jsonb_array_length(p_tiers) > 10 THEN
    RETURN warehouse_security.rate_failure('INVALID_BANDS', 'Bands must be a list of 1 to 10 bands');
  END IF;
  FOR v_band, v_ord IN SELECT e.value, (e.ord - 1)::integer FROM jsonb_array_elements(p_tiers) WITH ORDINALITY e(value, ord) ORDER BY e.ord LOOP
    IF jsonb_typeof(v_band) <> 'object' THEN
      RETURN warehouse_security.rate_failure('INVALID_BAND', 'Each band needs whole kilograms with the start at most the end', jsonb_build_object('index', v_ord));
    END IF;
    FOREACH v_field IN ARRAY ARRAY['weight_min','weight_max'] LOOP
      IF jsonb_typeof(v_band->v_field) IS DISTINCT FROM 'number' THEN
        RETURN warehouse_security.rate_failure('INVALID_BAND', 'Each band needs whole kilograms with the start at most the end', jsonb_build_object('index', v_ord, 'field', v_field));
      END IF;
      v_n := (v_band->>v_field)::numeric;
      IF v_n <> trunc(v_n) OR v_n < 0 OR v_n > 100000 THEN
        RETURN warehouse_security.rate_failure('INVALID_BAND', 'Each band needs whole kilograms with the start at most the end', jsonb_build_object('index', v_ord, 'field', v_field));
      END IF;
    END LOOP;
    IF (v_band->>'weight_min')::numeric > (v_band->>'weight_max')::numeric THEN
      RETURN warehouse_security.rate_failure('INVALID_BAND', 'Each band needs whole kilograms with the start at most the end', jsonb_build_object('index', v_ord));
    END IF;
    FOREACH v_field IN ARRAY ARRAY['unit_price','labour_rate','tax_percent'] LOOP
      IF jsonb_typeof(v_band->v_field) IS DISTINCT FROM 'number' THEN
        RETURN warehouse_security.rate_failure('INVALID_AMOUNT', 'Rent and labour must be 0 to 999999 with two decimals at most; tax 0 to 100', jsonb_build_object('index', v_ord, 'field', v_field));
      END IF;
      v_n := (v_band->>v_field)::numeric;
      v_limit := CASE WHEN v_field = 'tax_percent' THEN 100 ELSE 999999 END;
      IF v_n < 0 OR v_n > v_limit OR v_n * 100 <> trunc(v_n * 100) THEN
        RETURN warehouse_security.rate_failure('INVALID_AMOUNT', 'Rent and labour must be 0 to 999999 with two decimals at most; tax 0 to 100', jsonb_build_object('index', v_ord, 'field', v_field));
      END IF;
    END LOOP;
  END LOOP;
  -- Sorted by start: no overlap; the first tier starts at 0 and none leaves a gap.
  v_prev_max := NULL; v_expected := 0;
  FOR v_band, v_ord IN SELECT e.value, (e.ord - 1)::integer FROM jsonb_array_elements(p_tiers) WITH ORDINALITY e(value, ord)
      ORDER BY (e.value->>'weight_min')::numeric, e.ord LOOP
    v_min := (v_band->>'weight_min')::numeric::integer; v_max := (v_band->>'weight_max')::numeric::integer;
    IF v_prev_max IS NOT NULL AND v_min <= v_prev_max THEN
      RETURN warehouse_security.rate_failure('BANDS_OVERLAP', 'Weight bands overlap', jsonb_build_object('index', v_ord));
    END IF;
    IF v_min <> v_expected THEN
      RETURN warehouse_security.rate_failure('BANDS_GAP', 'The default rate''s bands must start at 0 kg and follow on without gaps',
        jsonb_build_object('index', v_ord, 'expected_min', v_expected));
    END IF;
    v_prev_max := v_max; v_expected := v_max + 1;
  END LOOP;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.standard_rate_failure(jsonb) FROM PUBLIC, anon, authenticated;

-- Gives an item the standard tiers as monthly default rows from p_from, when it has no default
-- row at all (any dates) and a standard rate is saved. Returns the rows added (0 = nothing done).
-- The author is the session's profile. The same lock as replace_item_rates: one change of this
-- scope at a time.
CREATE FUNCTION warehouse_security.give_standard_rate(p_item_id uuid, p_from date) RETURNS integer
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE v_profile uuid; v_added integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('item_rates:' || p_item_id || ':default:monthly', 0));
  IF EXISTS (SELECT 1 FROM public.item_storage_prices r WHERE r.item_id = p_item_id AND r.customer_id IS NULL) THEN
    RETURN 0;
  END IF;
  SELECT up.id INTO v_profile FROM public.user_profiles up WHERE up.auth_user_id = auth.uid() AND up.active;
  INSERT INTO public.item_storage_prices (
    item_id, customer_id, price_type, unit_price, weight_min, weight_max, labour_rate, tax_percent,
    effective_from, effective_to, created_by, unit_price_one_time, unit_price_monthly)
  SELECT p_item_id, NULL, 'monthly', t.unit_price, t.weight_min, t.weight_max, t.labour_rate, t.tax_percent,
         p_from, NULL, v_profile, 0, t.unit_price
    FROM public.standard_rate_tiers t ORDER BY t.weight_min;
  GET DIAGNOSTICS v_added = ROW_COUNT;
  RETURN v_added;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.give_standard_rate(uuid, date) FROM PUBLIC, anon, authenticated;

-- Copies the default rows of p_from_item that are in force on p_day (both price types, no
-- customer rate) to p_to_item as rows from p_day without an end. Labour of a one-time rate is 0.
-- One row per band, the one find_storage_price would use (the latest start). When the rows
-- picked still overlap (data written before migration 76's overlap check), nothing is copied.
-- Returns the rows added (0 = the source has nothing usable in force).
CREATE FUNCTION warehouse_security.copy_default_rates(p_from_item uuid, p_to_item uuid, p_day date) RETURNS integer
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE v_profile uuid; v_added integer;
BEGIN
  SELECT up.id INTO v_profile FROM public.user_profiles up WHERE up.auth_user_id = auth.uid() AND up.active;
  WITH picked AS (
    SELECT DISTINCT ON (r.price_type, r.weight_min, r.weight_max) r.*
      FROM public.item_storage_prices r
     WHERE r.item_id = p_from_item AND r.customer_id IS NULL
       AND r.effective_from <= p_day AND (r.effective_to IS NULL OR r.effective_to >= p_day)
     ORDER BY r.price_type, r.weight_min, r.weight_max, r.effective_from DESC, r.id)
  INSERT INTO public.item_storage_prices (
    item_id, customer_id, price_type, unit_price, weight_min, weight_max, labour_rate, tax_percent,
    effective_from, effective_to, created_by, unit_price_one_time, unit_price_monthly)
  SELECT p_to_item, NULL, r.price_type, r.unit_price, r.weight_min, r.weight_max,
         CASE WHEN r.price_type = 'one_time' THEN 0 ELSE r.labour_rate END, r.tax_percent,
         p_day, NULL, v_profile,
         CASE WHEN r.price_type = 'one_time' THEN r.unit_price ELSE 0 END,
         CASE WHEN r.price_type = 'monthly' THEN r.unit_price ELSE 0 END
    FROM picked r
   WHERE NOT EXISTS (SELECT 1 FROM picked a JOIN picked b ON a.price_type = b.price_type AND a.id <> b.id
                      AND a.weight_min <= b.weight_max AND b.weight_min <= a.weight_max)
   ORDER BY r.price_type, r.weight_min;
  GET DIAGNOSTICS v_added = ROW_COUNT;
  RETURN v_added;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.copy_default_rates(uuid, uuid, date) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. get_standard_rate
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.get_standard_rate() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, utils, pg_temp
AS $function$
DECLARE v_tiers jsonb; v_at timestamptz; v_by text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_standard_rate', jsonb_build_object());
  SELECT COALESCE(jsonb_agg(jsonb_build_object('weight_min', t.weight_min, 'weight_max', t.weight_max,
           'unit_price', t.unit_price, 'labour_rate', t.labour_rate, 'tax_percent', t.tax_percent) ORDER BY t.weight_min), '[]'::jsonb),
         max(t.updated_at)
    INTO v_tiers, v_at FROM public.standard_rate_tiers t;
  SELECT up.name INTO v_by FROM public.standard_rate_tiers t JOIN public.user_profiles up ON up.id = t.updated_by
   ORDER BY t.updated_at DESC, t.weight_min LIMIT 1;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'tiers', v_tiers, 'updated_at', v_at, 'updated_by_name', v_by));
END;
$function$;
REVOKE ALL ON FUNCTION public.get_standard_rate() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_standard_rate() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. set_standard_rate
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.set_standard_rate(p_tiers jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, utils, pg_temp
AS $function$
DECLARE
  v_role text; v_profile uuid; v_failure jsonb; v_today date := warehouse_security.business_date(now());
  v_item record; v_priced integer := 0; v_tiers jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('set_standard_rate', jsonb_build_object());
  SELECT up.id, up.role::text INTO v_profile, v_role FROM public.user_profiles up WHERE up.auth_user_id = auth.uid() AND up.active;
  IF v_role IS NULL OR v_role NOT IN ('admin','supervisor') THEN
    RETURN warehouse_security.rate_failure('STANDARD_RATE_MANAGER_ONLY', 'Only administrators and supervisors can change the standard rate');
  END IF;
  v_failure := warehouse_security.standard_rate_failure(p_tiers);
  IF v_failure IS NOT NULL THEN RETURN v_failure; END IF;

  -- One save at a time.
  PERFORM pg_advisory_xact_lock(hashtextextended('standard_rate', 0));
  DELETE FROM public.standard_rate_tiers WHERE true;
  INSERT INTO public.standard_rate_tiers (weight_min, weight_max, unit_price, labour_rate, tax_percent, updated_at, updated_by)
  SELECT (e.value->>'weight_min')::numeric::integer, (e.value->>'weight_max')::numeric::integer, (e.value->>'unit_price')::numeric,
         (e.value->>'labour_rate')::numeric, (e.value->>'tax_percent')::numeric, now(), v_profile
    FROM jsonb_array_elements(p_tiers) e;

  -- Active items with no default row at all start on the India day of their first GRN that is
  -- not deleted, else today.
  FOR v_item IN
    SELECT i.id,
           COALESCE(warehouse_security.business_date((SELECT min(g.date) FROM public.goodsreceived g
              JOIN public.goodsreceived_trl l ON l.gr_id = g.id WHERE l.item_id = i.id AND g.deleted_at IS NULL)), v_today) AS starts_on
      FROM public.items i
     WHERE i.active
       AND NOT EXISTS (SELECT 1 FROM public.item_storage_prices r WHERE r.item_id = i.id AND r.customer_id IS NULL)
     ORDER BY i.id LOOP
    IF warehouse_security.give_standard_rate(v_item.id, v_item.starts_on) > 0 THEN v_priced := v_priced + 1; END IF;
  END LOOP;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('weight_min', t.weight_min, 'weight_max', t.weight_max,
           'unit_price', t.unit_price, 'labour_rate', t.labour_rate, 'tax_percent', t.tax_percent) ORDER BY t.weight_min), '[]'::jsonb)
    INTO v_tiers FROM public.standard_rate_tiers t;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('tiers', v_tiers, 'items_priced', v_priced));
END;
$function$;
REVOKE ALL ON FUNCTION public.set_standard_rate(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_standard_rate(jsonb) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. create_item with p_rate_from_item
-- ---------------------------------------------------------------------------
DROP FUNCTION public.create_item(character varying, character varying, character varying, boolean);
CREATE FUNCTION public.create_item(p_name character varying, p_packaging character varying DEFAULT NULL::character varying, p_description character varying DEFAULT NULL::character varying, p_active boolean DEFAULT true, p_rate_from_item uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
DECLARE
    v_new_id uuid;
    v_result jsonb;
    v_source text := 'none';
    v_today date := warehouse_security.business_date(now());
BEGIN
  PERFORM warehouse_security.authorize_rpc('create_item',jsonb_build_object());
    -- Security check
    IF NOT is_admin_or_supervisor() THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Access denied: Admin or supervisor role required'
        );
    END IF;

    -- Validate name
    IF p_name IS NULL OR TRIM(p_name) = '' THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Item name is required'
        );
    END IF;

    -- Check for duplicate name
    IF EXISTS (SELECT 1 FROM items WHERE LOWER(name) = LOWER(TRIM(p_name))) THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'An item with this name already exists'
        );
    END IF;

    -- Insert new item
    INSERT INTO items (name, packaging, description, active)
    VALUES (TRIM(p_name), NULLIF(TRIM(p_packaging), ''), NULLIF(TRIM(p_description), ''), p_active)
    RETURNING id INTO v_new_id;

    -- The item's rate (migration 85): a copy of another item's default rows in force today, else
    -- the standard tiers from today, else none. A save of the standard rate in progress is waited
    -- for (it holds the same lock exclusively), so the tiers read below are the committed ones.
    PERFORM pg_advisory_xact_lock_shared(hashtextextended('standard_rate', 0));
    IF p_rate_from_item IS NOT NULL
       AND warehouse_security.copy_default_rates(p_rate_from_item, v_new_id, v_today) > 0 THEN
        v_source := 'copied';
    ELSIF warehouse_security.give_standard_rate(v_new_id, v_today) > 0 THEN
        v_source := 'standard';
    END IF;

    -- Return created item
    SELECT jsonb_build_object(
        'id', id,
        'name', name,
        'packaging', packaging,
        'description', description,
        'active', active,
        'rate_source', v_source
    ) INTO v_result
    FROM items
    WHERE id = v_new_id;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Item created successfully',
        'data', v_result
    );
END;
$function$;
REVOKE ALL ON FUNCTION public.create_item(character varying, character varying, character varying, boolean, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_item(character varying, character varying, character varying, boolean, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. update_item: an item that turns active gets the standard tiers when it has no default row
-- ---------------------------------------------------------------------------
DO $patch$ BEGIN
  PERFORM pg_temp.patch_rpc('public.update_item(uuid,character varying,character varying,character varying,boolean)',
  $m$    v_result jsonb;
BEGIN$m$, $r$    v_result jsonb;
    v_was_active boolean;
BEGIN$r$);
  PERFORM pg_temp.patch_rpc('public.update_item(uuid,character varying,character varying,character varying,boolean)',
  $m$    -- Update item
$m$, $r$    SELECT active INTO v_was_active FROM items WHERE id = p_item_id;

    -- Update item
$r$);
  PERFORM pg_temp.patch_rpc('public.update_item(uuid,character varying,character varying,character varying,boolean)',
  $m$    -- Return updated item
$m$, $r$    -- An item that turns active and has no default rate gets the standard tiers from today (migration 85).
    IF COALESCE(v_was_active, false) = false AND p_active IS TRUE THEN
        PERFORM pg_advisory_xact_lock_shared(hashtextextended('standard_rate', 0));
        PERFORM warehouse_security.give_standard_rate(p_item_id, warehouse_security.business_date(now()));
    END IF;

    -- Return updated item
$r$);
END $patch$;

-- ---------------------------------------------------------------------------
-- 7. The guard: staff reach get_standard_rate; set_standard_rate refuses them in its body
-- ---------------------------------------------------------------------------
DO $patch$ BEGIN
  PERFORM pg_temp.patch_rpc('warehouse_security.authorize_rpc(text,jsonb)',
  $m$    'replace_item_rates',
    'undo_rate_change',
$m$, $r$    'replace_item_rates',
    'undo_rate_change',
    -- The facility's standard rate (migration 85); set_standard_rate refuses staff in its body.
    'get_standard_rate','set_standard_rate',
$r$);
END $patch$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
NOTIFY pgrst, 'reload schema';
