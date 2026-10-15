-- Migration 86: rates typed on the GRN sheet, and the rate start floor (owner decisions of 2026-10-15).
--
-- 1. public.grn_rates: a rate that belongs to one GRN only (item, weight band, rent, labour, tax).
--    Row level security is on; administrators and supervisors read it (customer accounts never),
--    no app role writes it: save_grn and update_grn do.
-- 2. public.save_grn and public.update_grn get a last parameter p_rates jsonb DEFAULT NULL (DROP +
--    CREATE; owner, options, grants unchanged, checked below). NULL = as before. A list (also
--    []) is checked and applied in the GRN's transaction: entries with scope "grn" replace the
--    GRN's own rates; entries with scope "customer" or "everyone" change the item's customer or
--    default rate from the GRN's India day (to an optional last day), for administrators,
--    supervisors and staff alike; then every line of the GRN must have a rate (RATE_MISSING
--    otherwise; not for an invoiced GRN, which keeps its archived rates and needs none). Any failure undoes the
--    whole call. update_grn also removes the GRN's own rates whose pricing kind or band no longer fits its lines. Helpers: warehouse_security.apply_grn_rates.
-- 3. build_invoice_recalculation_rows: rent, labour and tax of a line come from one source, in
--    this order: the stored invoice figure, the GRN's own rate, the item's rate.
-- 4. get_grn_details: grn.rates (always [] for a customer account). 5. public.get_item_grn_rates(p_item_id): the GRN-only rates of
--    an item (admin, supervisor, staff).
-- 6. warehouse_security.rate_start_floor(): the earliest day a rate may start = the earlier of the
--    India day of the first GRN that is not deleted and today - 1095 days (the old window, which
--    a facility with older GRNs extends further back; never later than before). replace_item_rates
--    and undo_rate_change use it instead of "today - 1095 days"; get_item_storage_prices answers
--    it as earliest_start.
-- 7. The guard admits get_item_grn_rates for staff.
--
-- Errors follow migration 74: {success:false, error, error_code, data}; those of save_grn and
-- update_grn also carry message (the app reads it there).

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
CREATE TABLE public.grn_rates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  gr_id uuid NOT NULL REFERENCES public.goodsreceived(id) ON DELETE CASCADE,
  item_id uuid NOT NULL REFERENCES public.items(id),
  price_type text NOT NULL,
  weight_min integer NOT NULL,
  weight_max integer NOT NULL,
  unit_price numeric(12,2) NOT NULL,
  labour_rate numeric(12,2) NOT NULL,
  tax_percent numeric(5,2) NOT NULL,
  created_by uuid REFERENCES public.user_profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES public.user_profiles(id),
  updated_at timestamptz,
  CONSTRAINT grn_rates_price_type_valid CHECK (price_type IN ('monthly','one_time')),
  CONSTRAINT grn_rates_weight_valid CHECK (weight_min >= 0 AND weight_min <= weight_max AND weight_max <= 100000),
  CONSTRAINT grn_rates_unit_price_valid CHECK (unit_price >= 0 AND unit_price <= 999999),
  CONSTRAINT grn_rates_labour_rate_valid CHECK (labour_rate >= 0 AND labour_rate <= 999999),
  CONSTRAINT grn_rates_tax_percent_valid CHECK (tax_percent >= 0 AND tax_percent <= 100),
  CONSTRAINT grn_rates_band_key UNIQUE (gr_id, item_id, weight_min, weight_max)
);
COMMENT ON TABLE public.grn_rates IS
  'A rate that applies to one GRN only (migration 86): its item, weight band (whole kg, inclusive), rent, labour and tax. Written by save_grn and update_grn only; an invoice uses it between its own stored figure and the item''s rate.';
CREATE INDEX grn_rates_gr_id_idx ON public.grn_rates (gr_id);
ALTER TABLE public.grn_rates ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.grn_rates FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.grn_rates TO authenticated;
-- Read like item_storage_prices: administrators and supervisors (staff through the RPCs); a
-- customer account never reads a rate. No write policy and no write grant.
CREATE POLICY starter_staff ON public.grn_rates FOR SELECT TO authenticated
  USING (warehouse_security.active_role() IN ('admin','supervisor'));

-- ---------------------------------------------------------------------------
-- 2. The rate start floor
-- ---------------------------------------------------------------------------
-- The earliest day a rate may start: never later than the old window (today - 1095 days), and
-- earlier when the facility has older GRNs (the India day of the first one that is not deleted).
-- LEAST ignores the NULL of a facility with no GRN.
CREATE FUNCTION warehouse_security.rate_start_floor() RETURNS date
LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT LEAST(warehouse_security.business_date((SELECT min(g.date) FROM public.goodsreceived g WHERE g.deleted_at IS NULL)),
               warehouse_security.business_date(now()) - 1095)
$$;
REVOKE ALL ON FUNCTION warehouse_security.rate_start_floor() FROM PUBLIC, anon, authenticated;

DO $patch$ BEGIN
  -- replace_item_rates: the lower bound of the start and of the moved start.
  PERFORM pg_temp.patch_rpc('public.replace_item_rates(uuid,uuid,text,date,jsonb,boolean,text,date,uuid[])',
  $m$  IF p_starts_on IS NULL OR p_starts_on NOT BETWEEN v_today - 1095 AND v_today + 730 THEN
    RETURN warehouse_security.rate_failure('INVALID_DATE', 'The start date must be within three years before today and two years after');
  END IF;
  IF p_move_from IS NOT NULL AND p_move_from NOT BETWEEN v_today - 1095 AND v_today + 730 THEN
    RETURN warehouse_security.rate_failure('INVALID_DATE', 'The start date must be within three years before today and two years after');
  END IF;
$m$, $r$  IF p_starts_on IS NULL OR p_starts_on NOT BETWEEN warehouse_security.rate_start_floor() AND v_today + 730 THEN
    RETURN warehouse_security.rate_failure('INVALID_DATE',
      'The start date must be on or after ' || warehouse_security.rate_start_floor()::text || ' and within two years after today',
      jsonb_build_object('earliest', warehouse_security.rate_start_floor()));
  END IF;
  IF p_move_from IS NOT NULL AND p_move_from NOT BETWEEN warehouse_security.rate_start_floor() AND v_today + 730 THEN
    RETURN warehouse_security.rate_failure('INVALID_DATE',
      'The start date must be on or after ' || warehouse_security.rate_start_floor()::text || ' and within two years after today',
      jsonb_build_object('earliest', warehouse_security.rate_start_floor()));
  END IF;
$r$);
  -- undo_rate_change: the lower bound of the start.
  PERFORM pg_temp.patch_rpc('public.undo_rate_change(uuid,uuid,text,date)',
  $m$  IF p_starts_on IS NULL OR p_starts_on NOT BETWEEN warehouse_security.business_date(now()) - 1095 AND warehouse_security.business_date(now()) + 730 THEN
    RETURN warehouse_security.rate_failure('INVALID_DATE', 'The start date must be within three years before today and two years after');
  END IF;
$m$, $r$  IF p_starts_on IS NULL OR p_starts_on NOT BETWEEN warehouse_security.rate_start_floor() AND warehouse_security.business_date(now()) + 730 THEN
    RETURN warehouse_security.rate_failure('INVALID_DATE',
      'The start date must be on or after ' || warehouse_security.rate_start_floor()::text || ' and within two years after today',
      jsonb_build_object('earliest', warehouse_security.rate_start_floor()));
  END IF;
$r$);
  -- replace_item_rates: whole kilograms may be written 50.0 (as set_standard_rate and apply_grn_rates accept).
  PERFORM pg_temp.patch_rpc('public.replace_item_rates(uuid,uuid,text,date,jsonb,boolean,text,date,uuid[])',
  $m$v_min := (v_band->>'weight_min')::integer; v_max := (v_band->>'weight_max')::integer;$m$,
  $r$v_min := (v_band->>'weight_min')::numeric::integer; v_max := (v_band->>'weight_max')::numeric::integer;$r$);
  PERFORM pg_temp.patch_rpc('public.replace_item_rates(uuid,uuid,text,date,jsonb,boolean,text,date,uuid[])',
  $m$(v_band->>'weight_min')::integer, (v_band->>'weight_max')::integer,$m$,
  $r$(v_band->>'weight_min')::numeric::integer, (v_band->>'weight_max')::numeric::integer,$r$);
  -- get_item_storage_prices: the floor beside the rows. data is the list of rows, so the floor is
  -- a key of the answer next to data and pagination.
  PERFORM pg_temp.patch_rpc('public.get_item_storage_prices(jsonb,text,text,integer,integer)',
  $m$        'data', v_data,
        'pagination', jsonb_build_object($m$, $r$        'data', v_data,
        'earliest_start', warehouse_security.rate_start_floor(),
        'pagination', jsonb_build_object($r$);
END $patch$;

-- ---------------------------------------------------------------------------
-- 3. The helpers of save_grn and update_grn
-- ---------------------------------------------------------------------------
-- A failure answer that also carries message, as save_grn and update_grn answer.
CREATE FUNCTION warehouse_security.grn_rate_failure(p_code text, p_error text, p_data jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT warehouse_security.rate_failure(p_code, p_error, p_data) || jsonb_build_object('message', p_error)
$$;
REVOKE ALL ON FUNCTION warehouse_security.grn_rate_failure(text, text, jsonb) FROM PUBLIC, anon, authenticated;

-- Checks and applies the p_rates list of save_grn / update_grn for a GRN whose header and lines
-- are already written. NULL when all is well, else the failure answer; the caller undoes its
-- writes. Runs with the caller's session (auth.uid()), so the price history names the author.
CREATE FUNCTION warehouse_security.apply_grn_rates(p_gr_id uuid, p_rates jsonb) RETURNS jsonb
LANGUAGE plpgsql SET search_path = pg_catalog, public AS $$
DECLARE
  v_profile uuid; v_customer uuid; v_mode text; v_day date; v_invoiced boolean; v_type text;
  v_e jsonb; v_ord integer; v_field text; v_n numeric; v_limit numeric; v_scope text; v_item uuid;
  v_min integer; v_max integer; v_to date; v_cust uuid; v_unit numeric; v_lab numeric; v_tax numeric;
  v_starts date; v_row public.item_storage_prices; v_old_to date; v_new_id uuid; v_key text; v_missing jsonb;
  v_amount constant text := 'Rent and labour must be 0 to 999999 with two decimals at most; tax 0 to 100';
  v_band constant text := 'Each band needs whole kilograms with the start at most the end';
BEGIN
  SELECT up.id INTO v_profile FROM public.user_profiles up WHERE up.auth_user_id = auth.uid() AND up.active;
  SELECT g.customer_id, g.pricing_mode, warehouse_security.business_date(g.date), COALESCE(g.invoiced, false)
    INTO v_customer, v_mode, v_day, v_invoiced FROM public.goodsreceived g WHERE g.id = p_gr_id;
  v_type := CASE WHEN upper(COALESCE(v_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END;

  IF jsonb_typeof(p_rates) <> 'array' THEN
    RETURN warehouse_security.grn_rate_failure('INVALID_BANDS', 'Rates must be a list');
  END IF;

  -- 1. Every entry.
  FOR v_e, v_ord IN SELECT e.value, (e.ord - 1)::integer FROM jsonb_array_elements(p_rates) WITH ORDINALITY e(value, ord) ORDER BY e.ord LOOP
    IF jsonb_typeof(v_e) <> 'object' THEN
      RETURN warehouse_security.grn_rate_failure('INVALID_BANDS', 'Each rate must be an object', jsonb_build_object('index', v_ord));
    END IF;
    v_scope := v_e->>'scope';
    IF jsonb_typeof(v_e->'scope') IS DISTINCT FROM 'string' OR v_scope NOT IN ('grn','customer','everyone') THEN
      RETURN warehouse_security.grn_rate_failure('INVALID_SCOPE', 'The scope must be grn, customer or everyone', jsonb_build_object('index', v_ord));
    END IF;
    FOREACH v_field IN ARRAY ARRAY['weight_min','weight_max'] LOOP
      IF jsonb_typeof(v_e->v_field) IS DISTINCT FROM 'number' THEN
        RETURN warehouse_security.grn_rate_failure('INVALID_BAND', v_band, jsonb_build_object('index', v_ord, 'field', v_field));
      END IF;
      v_n := (v_e->>v_field)::numeric;
      IF v_n <> trunc(v_n) OR v_n < 0 OR v_n > 100000 THEN
        RETURN warehouse_security.grn_rate_failure('INVALID_BAND', v_band, jsonb_build_object('index', v_ord, 'field', v_field));
      END IF;
    END LOOP;
    IF (v_e->>'weight_min')::numeric > (v_e->>'weight_max')::numeric THEN
      RETURN warehouse_security.grn_rate_failure('INVALID_BAND', v_band, jsonb_build_object('index', v_ord));
    END IF;
    v_min := (v_e->>'weight_min')::numeric::integer; v_max := (v_e->>'weight_max')::numeric::integer;
    -- Labour of a one-time rate is not used (invoices never charge it): not checked, stored as 0.
    FOREACH v_field IN ARRAY CASE WHEN v_type = 'one_time' THEN ARRAY['unit_price','tax_percent'] ELSE ARRAY['unit_price','labour_rate','tax_percent'] END LOOP
      IF jsonb_typeof(v_e->v_field) IS DISTINCT FROM 'number' THEN
        RETURN warehouse_security.grn_rate_failure('INVALID_AMOUNT', v_amount, jsonb_build_object('index', v_ord, 'field', v_field));
      END IF;
      v_n := (v_e->>v_field)::numeric;
      v_limit := CASE WHEN v_field = 'tax_percent' THEN 100 ELSE 999999 END;
      IF v_n < 0 OR v_n > v_limit OR v_n * 100 <> trunc(v_n * 100) THEN
        RETURN warehouse_security.grn_rate_failure('INVALID_AMOUNT', v_amount, jsonb_build_object('index', v_ord, 'field', v_field));
      END IF;
    END LOOP;
    IF v_scope <> 'grn' AND jsonb_typeof(v_e->'to') IS NOT NULL AND jsonb_typeof(v_e->'to') <> 'null' THEN
      IF jsonb_typeof(v_e->'to') <> 'string' OR (v_e->>'to') !~ '^\d{4}-\d{2}-\d{2}$' THEN
        RETURN warehouse_security.grn_rate_failure('INVALID_DATE', 'The last day must be a date, not before the GRN day', jsonb_build_object('index', v_ord));
      END IF;
      BEGIN v_to := (v_e->>'to')::date;
      EXCEPTION WHEN OTHERS THEN
        RETURN warehouse_security.grn_rate_failure('INVALID_DATE', 'The last day must be a date, not before the GRN day', jsonb_build_object('index', v_ord));
      END;
      IF v_to < v_day THEN
        RETURN warehouse_security.grn_rate_failure('INVALID_DATE', 'The last day must be a date, not before the GRN day', jsonb_build_object('index', v_ord));
      END IF;
    END IF;
    -- The item must be on the GRN, with a line whose weight the band holds.
    v_item := CASE WHEN jsonb_typeof(v_e->'item_id') = 'string' AND (v_e->>'item_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                   THEN (v_e->>'item_id')::uuid END;
    -- (An invoiced GRN's own rates are archived: the stored set may no longer fit a line that
    -- changed after the invoice, and re-sending it must still save.)
    IF v_item IS NULL OR (NOT (v_invoiced AND v_scope = 'grn') AND NOT EXISTS (SELECT 1 FROM public.goodsreceived_trl t
         WHERE t.gr_id = p_gr_id AND t.item_id = v_item AND COALESCE(t.weight, 0) BETWEEN v_min AND v_max)) THEN
      RETURN warehouse_security.grn_rate_failure('RATE_NOT_FOR_GRN', 'The rate is not for any line of this GRN',
        jsonb_build_object('index', v_ord, 'item_id', v_e->'item_id'));
    END IF;
    -- The GRN's own bands of one item do not overlap.
    IF v_scope = 'grn' AND EXISTS (
         SELECT 1 FROM jsonb_array_elements(p_rates) WITH ORDINALITY q(value, ord)
          WHERE CASE WHEN q.ord < v_ord + 1 AND q.value->>'scope' = 'grn' AND lower(q.value->>'item_id') = lower(v_e->>'item_id')
                     THEN (q.value->>'weight_min')::numeric <= v_max AND v_min <= (q.value->>'weight_max')::numeric
                     ELSE false END) THEN
      RETURN warehouse_security.grn_rate_failure('BANDS_OVERLAP', 'Weight bands overlap', jsonb_build_object('index', v_ord));
    END IF;
    v_to := NULL;
  END LOOP;

  -- 2. customer / everyone: the item's rate changes from the GRN day. The locks of replace_item_rates,
  -- taken in a fixed order.
  FOR v_key IN
    SELECT DISTINCT 'item_rates:' || ((e->>'item_id')::uuid)::text || ':'
           || CASE WHEN e->>'scope' = 'customer' THEN v_customer::text ELSE 'default' END || ':' || v_type
      FROM jsonb_array_elements(p_rates) e WHERE e->>'scope' IN ('customer','everyone') ORDER BY 1 LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(v_key, 0));
  END LOOP;
  FOR v_e, v_ord IN SELECT e.value, (e.ord - 1)::integer FROM jsonb_array_elements(p_rates) WITH ORDINALITY e(value, ord)
      WHERE e.value->>'scope' IN ('customer','everyone') ORDER BY e.ord LOOP
    v_scope := v_e->>'scope'; v_item := (v_e->>'item_id')::uuid;
    v_min := (v_e->>'weight_min')::numeric::integer; v_max := (v_e->>'weight_max')::numeric::integer;
    v_to := CASE WHEN jsonb_typeof(v_e->'to') = 'string' THEN (v_e->>'to')::date END;
    v_cust := CASE WHEN v_scope = 'customer' THEN v_customer END;
    v_unit := (v_e->>'unit_price')::numeric; v_tax := (v_e->>'tax_percent')::numeric;
    v_lab := CASE WHEN v_type = 'one_time' THEN 0 ELSE (v_e->>'labour_rate')::numeric END;
    -- Another band that shares a weight and a day with the new row.
    SELECT min(r.effective_from) INTO v_starts FROM public.item_storage_prices r
     WHERE r.item_id = v_item AND r.customer_id IS NOT DISTINCT FROM v_cust AND r.price_type = v_type
       AND r.weight_min <= v_max AND v_min <= r.weight_max AND (r.weight_min <> v_min OR r.weight_max <> v_max)
       AND r.effective_from <= COALESCE(v_to, 'infinity'::date) AND COALESCE(r.effective_to, 'infinity'::date) >= v_day;
    IF v_starts IS NOT NULL THEN
      RETURN warehouse_security.grn_rate_failure('BANDS_OVERLAP', 'Weight bands overlap',
        jsonb_build_object('index', v_ord, 'starts_on', v_starts));
    END IF;
    -- The same band planned after the GRN day, inside the new row's days.
    SELECT min(r.effective_from) INTO v_starts FROM public.item_storage_prices r
     WHERE r.item_id = v_item AND r.customer_id IS NOT DISTINCT FROM v_cust AND r.price_type = v_type
       AND r.weight_min = v_min AND r.weight_max = v_max
       AND r.effective_from > v_day AND r.effective_from <= COALESCE(v_to, 'infinity'::date);
    IF v_starts IS NOT NULL THEN
      RETURN warehouse_security.grn_rate_failure('RATE_PLANNED', 'A later rate is already planned for this band',
        jsonb_build_object('index', v_ord, 'starts_on', v_starts));
    END IF;
    -- The same band in force on the GRN day: replaced when it starts that day, else ended the day
    -- before; its old figures resume the day after the last day.
    FOR v_row IN SELECT * FROM public.item_storage_prices r
        WHERE r.item_id = v_item AND r.customer_id IS NOT DISTINCT FROM v_cust AND r.price_type = v_type
          AND r.weight_min = v_min AND r.weight_max = v_max
          AND r.effective_from <= v_day AND COALESCE(r.effective_to, 'infinity'::date) >= v_day
        ORDER BY r.effective_from, r.id FOR UPDATE LOOP
      v_old_to := v_row.effective_to;
      IF v_row.effective_from = v_day THEN
        DELETE FROM public.item_storage_prices WHERE id = v_row.id;
      ELSE
        UPDATE public.item_storage_prices SET effective_to = v_day - 1 WHERE id = v_row.id;
      END IF;
      IF v_to IS NOT NULL AND (v_old_to IS NULL OR v_old_to > v_to) THEN
        INSERT INTO public.item_storage_prices (
          item_id, customer_id, price_type, unit_price, weight_min, weight_max, labour_rate, tax_percent,
          effective_from, effective_to, created_by, unit_price_one_time, unit_price_monthly)
        VALUES (v_row.item_id, v_row.customer_id, v_row.price_type, v_row.unit_price, v_row.weight_min, v_row.weight_max,
          v_row.labour_rate, v_row.tax_percent, v_to + 1, v_old_to, v_profile, v_row.unit_price_one_time, v_row.unit_price_monthly);
      END IF;
    END LOOP;
    -- The other bands of the scope in force on the GRN day follow on the same days, so every band of
    -- the scope still starts and ends together and Item pricing's Correct and Undo keep working: ended
    -- the day before, copied unchanged from the GRN day (to the last day), and resumed after it.
    FOR v_row IN SELECT * FROM public.item_storage_prices r
        WHERE r.item_id = v_item AND r.customer_id IS NOT DISTINCT FROM v_cust AND r.price_type = v_type
          AND (r.weight_min <> v_min OR r.weight_max <> v_max)
          AND r.effective_from <= v_day AND COALESCE(r.effective_to, 'infinity'::date) >= v_day
        ORDER BY r.weight_min, r.effective_from, r.id FOR UPDATE LOOP
      v_old_to := v_row.effective_to;
      IF v_row.effective_from < v_day THEN
        UPDATE public.item_storage_prices SET effective_to = v_day - 1 WHERE id = v_row.id;
        INSERT INTO public.item_storage_prices (
          item_id, customer_id, price_type, unit_price, weight_min, weight_max, labour_rate, tax_percent,
          effective_from, effective_to, created_by, unit_price_one_time, unit_price_monthly)
        VALUES (v_row.item_id, v_row.customer_id, v_row.price_type, v_row.unit_price, v_row.weight_min, v_row.weight_max,
          v_row.labour_rate, v_row.tax_percent, v_day,
          CASE WHEN v_to IS NOT NULL AND (v_old_to IS NULL OR v_old_to > v_to) THEN v_to ELSE v_old_to END,
          v_profile, v_row.unit_price_one_time, v_row.unit_price_monthly);
      ELSIF v_to IS NOT NULL AND (v_old_to IS NULL OR v_old_to > v_to) THEN
        UPDATE public.item_storage_prices SET effective_to = v_to WHERE id = v_row.id;
      END IF;
      IF v_to IS NOT NULL AND (v_old_to IS NULL OR v_old_to > v_to) THEN
        INSERT INTO public.item_storage_prices (
          item_id, customer_id, price_type, unit_price, weight_min, weight_max, labour_rate, tax_percent,
          effective_from, effective_to, created_by, unit_price_one_time, unit_price_monthly)
        VALUES (v_row.item_id, v_row.customer_id, v_row.price_type, v_row.unit_price, v_row.weight_min, v_row.weight_max,
          v_row.labour_rate, v_row.tax_percent, v_to + 1, v_old_to, v_profile, v_row.unit_price_one_time, v_row.unit_price_monthly);
      END IF;
    END LOOP;
    INSERT INTO public.item_storage_prices (
      item_id, customer_id, price_type, unit_price, weight_min, weight_max, labour_rate, tax_percent,
      effective_from, effective_to, created_by, unit_price_one_time, unit_price_monthly)
    VALUES (v_item, v_cust, v_type, v_unit, v_min, v_max, v_lab, v_tax, v_day, v_to, v_profile,
      CASE WHEN v_type = 'one_time' THEN v_unit ELSE 0 END, CASE WHEN v_type = 'monthly' THEN v_unit ELSE 0 END)
    RETURNING id INTO v_new_id;
    IF warehouse_security.price_rows_overlap(v_item, v_cust, v_type, v_min, v_max, v_day, v_to, v_new_id) THEN
      RETURN warehouse_security.grn_rate_failure('BANDS_OVERLAP', 'Weight bands overlap', jsonb_build_object('index', v_ord));
    END IF;
  END LOOP;

  -- 3. The GRN's own rates are replaced; an invoiced GRN keeps them (an equal list is accepted).
  IF v_invoiced THEN
    IF EXISTS (
         (SELECT g.item_id, g.weight_min, g.weight_max, g.unit_price, g.labour_rate, g.tax_percent FROM public.grn_rates g WHERE g.gr_id = p_gr_id
          EXCEPT
          SELECT (e->>'item_id')::uuid, (e->>'weight_min')::numeric::integer, (e->>'weight_max')::numeric::integer,
                 (e->>'unit_price')::numeric(12,2), CASE WHEN v_type = 'one_time' THEN 0 ELSE (e->>'labour_rate')::numeric(12,2) END,
                 (e->>'tax_percent')::numeric(5,2)
            FROM jsonb_array_elements(p_rates) e WHERE e->>'scope' = 'grn')
         UNION ALL
         (SELECT (e->>'item_id')::uuid, (e->>'weight_min')::numeric::integer, (e->>'weight_max')::numeric::integer,
                 (e->>'unit_price')::numeric(12,2), CASE WHEN v_type = 'one_time' THEN 0 ELSE (e->>'labour_rate')::numeric(12,2) END,
                 (e->>'tax_percent')::numeric(5,2)
            FROM jsonb_array_elements(p_rates) e WHERE e->>'scope' = 'grn'
          EXCEPT
          SELECT g.item_id, g.weight_min, g.weight_max, g.unit_price, g.labour_rate, g.tax_percent FROM public.grn_rates g WHERE g.gr_id = p_gr_id)) THEN
      RETURN warehouse_security.grn_rate_failure('GRN_INVOICED', 'The rates of an invoiced GRN cannot change');
    END IF;
  ELSE
    -- By (item, band): a row that is no longer in the list goes; a new one is inserted; an unchanged
    -- one is left alone (id, author and time stay); a changed one is updated and names who changed it.
    DELETE FROM public.grn_rates g WHERE g.gr_id = p_gr_id AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_rates) e WHERE e->>'scope' = 'grn' AND (e->>'item_id')::uuid = g.item_id
         AND (e->>'weight_min')::numeric::integer = g.weight_min AND (e->>'weight_max')::numeric::integer = g.weight_max);
    INSERT INTO public.grn_rates (gr_id, item_id, price_type, weight_min, weight_max, unit_price, labour_rate, tax_percent, created_by)
    SELECT p_gr_id, (e->>'item_id')::uuid, v_type, (e->>'weight_min')::numeric::integer, (e->>'weight_max')::numeric::integer,
           (e->>'unit_price')::numeric, CASE WHEN v_type = 'one_time' THEN 0 ELSE (e->>'labour_rate')::numeric END,
           (e->>'tax_percent')::numeric, v_profile
      FROM jsonb_array_elements(p_rates) e WHERE e->>'scope' = 'grn'
    ON CONFLICT (gr_id, item_id, weight_min, weight_max) DO UPDATE
      SET price_type = EXCLUDED.price_type, unit_price = EXCLUDED.unit_price, labour_rate = EXCLUDED.labour_rate,
          tax_percent = EXCLUDED.tax_percent, updated_by = v_profile, updated_at = now()
      WHERE (public.grn_rates.price_type, public.grn_rates.unit_price, public.grn_rates.labour_rate, public.grn_rates.tax_percent)
            IS DISTINCT FROM (EXCLUDED.price_type, EXCLUDED.unit_price, EXCLUDED.labour_rate, EXCLUDED.tax_percent);
  END IF;

  -- 4. Every line has a rate: the GRN's own, else the item's. (Not for an invoiced GRN: its invoice
  -- carries its own figures, and no rate is read again.)
  IF NOT v_invoiced THEN
  SELECT jsonb_agg(jsonb_build_object('item_id', x.item_id, 'item_name', x.item_name, 'weight', x.weight) ORDER BY x.item_name, x.weight, x.item_id)
    INTO v_missing
    FROM (SELECT DISTINCT t.item_id, t.item_name, COALESCE(t.weight, 0) AS weight
            FROM public.goodsreceived_trl t
           WHERE t.gr_id = p_gr_id AND t.item_id IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM public.grn_rates g WHERE g.gr_id = p_gr_id AND g.item_id = t.item_id
                               AND g.price_type = v_type AND COALESCE(t.weight, 0) BETWEEN g.weight_min AND g.weight_max)
             AND (public.find_storage_price(t.item_id, v_customer, COALESCE(t.weight, 0), v_day, v_type)).id IS NULL) x;
  IF v_missing IS NOT NULL THEN
    RETURN warehouse_security.grn_rate_failure('RATE_MISSING', 'Some lines of this GRN have no rate', jsonb_build_object('lines', v_missing));
  END IF;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.apply_grn_rates(uuid, jsonb) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. save_grn and update_grn with p_rates (DROP + CREATE: a parameter cannot be added by a patch)
-- ---------------------------------------------------------------------------
-- What the two functions have now, to compare after the re-create: owner, options, grants.
CREATE TEMP TABLE grn_fn_before ON COMMIT DROP AS
  SELECT p.proname, pg_get_userbyid(p.proowner) AS owner, p.proacl::text AS acl, p.proconfig::text AS config,
         p.prosecdef, p.provolatile, p.proisstrict, p.prorettype::regtype::text AS returns
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('save_grn','update_grn');
DO $check$ BEGIN
  IF (SELECT count(*) FROM grn_fn_before) <> 2 THEN RAISE EXCEPTION 'Expected exactly one save_grn and one update_grn'; END IF;
END $check$;

DROP FUNCTION public.save_grn(character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, text, character varying);
DROP FUNCTION public.update_grn(uuid, character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, character varying, text);

CREATE FUNCTION public.save_grn(p_gr_no character varying, p_date timestamp with time zone, p_customer_id uuid, p_customer_name character varying, p_sender_id uuid DEFAULT NULL::uuid, p_sender_name character varying DEFAULT NULL::character varying, p_supervisor_id uuid DEFAULT NULL::uuid, p_supervisor_name character varying DEFAULT NULL::character varying, p_registration character varying DEFAULT NULL::character varying, p_note character varying DEFAULT NULL::character varying, p_leon boolean DEFAULT false, p_pricing_mode character varying DEFAULT NULL::character varying, p_items jsonb DEFAULT '[]'::jsonb, p_images jsonb DEFAULT '[]'::jsonb, p_idempotency_key text DEFAULT NULL::text, p_duration_mode character varying DEFAULT 'legacy'::character varying, p_rates jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
 SET jit TO 'off'
AS $function$
  DECLARE
      v_user_id uuid;
      v_user_profile_id uuid;
      v_user_role text;
      v_grn_id uuid;
      v_item_id uuid;
      v_item jsonb;
      v_image jsonb;
      v_image_id uuid;
      v_item_ids uuid[] := '{}';
      v_image_ids uuid[] := '{}';
      v_items_created int := 0;
      v_images_saved int := 0;
      v_item_index int;
      v_item_mapping jsonb := '[]'::jsonb;
      v_cached_response jsonb;
      v_result jsonb;
      v_rate_failure jsonb;
      v_detail text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('save_grn',jsonb_build_object('p_customer_id',p_customer_id));
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
      -- IDEMPOTENCY CHECK: Return cached response if key exists
      IF p_idempotency_key IS NOT NULL THEN
          SELECT response INTO v_cached_response
          FROM idempotency_keys
          WHERE idempotency_key = p_idempotency_key
            AND rpc_function = 'save_grn'
            AND created_by = (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid())
            AND expires_at > now();

          IF v_cached_response IS NOT NULL THEN
              RETURN v_cached_response || jsonb_build_object('idempotent', true);
          END IF;
      END IF;

      v_user_id := auth.uid();

      IF v_user_id IS NULL THEN
          RETURN jsonb_build_object(
              'success', false,
              'message', 'Authentication required'
          );
      END IF;

      SELECT id, role INTO v_user_profile_id, v_user_role
      FROM user_profiles
      WHERE auth_user_id = v_user_id;

      IF v_user_profile_id IS NULL THEN
          RETURN jsonb_build_object(
              'success', false,
              'message', 'User profile not found'
          );
      END IF;

      IF v_user_role NOT IN ('admin', 'supervisor', 'staff') THEN
          RETURN jsonb_build_object(
              'success', false,
              'message', 'Insufficient permissions. Only admin and supervisor can create GRNs'
          );
      END IF;

      PERFORM warehouse_security.require_person_supervisor(p_supervisor_id::text);

      IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND deleted_at IS NOT NULL) THEN
          RAISE EXCEPTION 'Business is not active' USING ERRCODE = 'P0001';
      END IF;

      IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND active = false) THEN
          RAISE EXCEPTION 'This business is deactivated. Activate it in Customers to receive new goods.' USING ERRCODE = 'P0001';
      END IF;

      IF warehouse_security.is_blank_text(p_gr_no) OR p_date IS NULL OR p_customer_id IS NULL THEN
          RETURN jsonb_build_object(
              'success', false,
              'message', 'Missing required parameters: gr_no, date, and customer_id are required'
          );
      END IF;

      IF EXISTS (SELECT 1 FROM goodsreceived WHERE gr_no = p_gr_no) THEN
          RETURN jsonb_build_object(
              'success', false,
              'message', 'GRN number already exists: ' || p_gr_no
          );
      END IF;

      IF jsonb_array_length(p_items) = 0 THEN
          RETURN jsonb_build_object(
              'success', false,
              'message', 'At least one item is required'
          );
      END IF;

      BEGIN
          INSERT INTO goodsreceived (
              gr_no,
              date,
              customer_id,
              customer_name,
              sender_id,
              sender_name,
              supervisor_id,
              supervisor_name,
              registration,
              note,
              leon,
              pricing_mode,
              duration_mode,
              out_of_stock,
              invoiced,
              created_by,
              updated_by
          ) VALUES (
              p_gr_no,
              p_date,
              p_customer_id,
              COALESCE((SELECT name FROM customers WHERE id = p_customer_id), p_customer_name),
              p_sender_id,
              p_sender_name,
              p_supervisor_id,
              p_supervisor_name,
              p_registration,
              p_note,
              COALESCE(p_leon, false),
              p_pricing_mode,
              COALESCE(p_duration_mode, 'legacy'),
              false,
              false,
              v_user_profile_id,
              v_user_profile_id
          ) RETURNING id INTO v_grn_id;

          v_item_index := 0;
          FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
          LOOP
              IF v_item->>'item_name' IS NULL OR (v_item->>'qty')::int IS NULL THEN
                  RAISE EXCEPTION 'Invalid item data: item_name and qty are required for item at index %', v_item_index;
              END IF;
              IF (v_item->>'qty')::int <= 0 THEN
                  RAISE EXCEPTION 'Quantity must be greater than 0 for item at index %', v_item_index;
              END IF;
              IF (v_item->>'weight')::int < 0 THEN
                  RAISE EXCEPTION 'Weight cannot be negative for item at index %', v_item_index;
              END IF;

              INSERT INTO goodsreceived_trl (
                  gr_id,
                  item_id,
                  item_name,
                  packaging,
                  qty,
                  stock,
                  weight,
                  rack,
                  package_mark
              ) VALUES (
                  v_grn_id,
                  (v_item->>'item_id')::uuid,
                  v_item->>'item_name',
                  v_item->>'packaging',
                  (v_item->>'qty')::int,
                  (v_item->>'qty')::int,
                  COALESCE((v_item->>'weight')::int, 0),
                  v_item->>'rack',
                  v_item->>'package_mark'
              ) RETURNING id INTO v_item_id;

              v_item_ids := array_append(v_item_ids, v_item_id);
              v_items_created := v_items_created + 1;

              v_item_mapping := v_item_mapping || jsonb_build_object(
                  'index', v_item_index,
                  'item_id', v_item_id,
                  'item_name', v_item->>'item_name'
              );

              v_item_index := v_item_index + 1;
          END LOOP;

          IF jsonb_array_length(p_images) > 0 THEN
              FOR v_image IN SELECT * FROM jsonb_array_elements(p_images)
              LOOP
                  IF v_image->>'storage_path' IS NULL OR v_image->>'image_type' IS NULL THEN
                      RAISE EXCEPTION 'Invalid image data: storage_path and image_type are required';
                  END IF;

                  v_image_id := gen_random_uuid();

                  PERFORM warehouse_security.require_image_path('grn', v_grn_id, v_image->>'image_type', v_image->>'storage_path');

                  IF v_image->>'image_type' = 'item' THEN
                      IF v_image->>'item_index' IS NOT NULL THEN
                          IF (v_image->>'item_index')::int < 0 OR
                             (v_image->>'item_index')::int >= jsonb_array_length(p_items) THEN
                              RAISE EXCEPTION 'Invalid item_index % for image. Must be between 0 and %',
                                  v_image->>'item_index', jsonb_array_length(p_items) - 1;
                          END IF;

                          v_item_id := v_item_ids[(v_image->>'item_index')::int + 1];

                          INSERT INTO grn_images (
                              id, grn_id, grn_item_id, image_type, storage_path,
                              original_filename, file_size, mime_type, uploaded_by, status
                          ) VALUES (
                              v_image_id, v_grn_id, v_item_id, v_image->>'image_type',
                              v_image->>'storage_path',
                              COALESCE(v_image->>'original_filename', 'unknown'),
                              COALESCE((v_image->>'file_size')::int, 0),
                              COALESCE(v_image->>'mime_type', 'image/jpeg'),
                              v_user_profile_id, 'confirmed'
                          );
                      ELSIF v_image->>'grn_item_id' IS NOT NULL THEN
                          IF NOT EXISTS (SELECT 1 FROM goodsreceived_trl
                              WHERE id = (v_image->>'grn_item_id')::uuid AND gr_id = v_grn_id) THEN
                              RAISE EXCEPTION 'Image line does not belong to this GRN';
                          END IF;
                          INSERT INTO grn_images (
                              id, grn_id, grn_item_id, image_type, storage_path,
                              original_filename, file_size, mime_type, uploaded_by, status
                          ) VALUES (
                              v_image_id, v_grn_id, (v_image->>'grn_item_id')::uuid,
                              v_image->>'image_type', v_image->>'storage_path',
                              COALESCE(v_image->>'original_filename', 'unknown'),
                              COALESCE((v_image->>'file_size')::int, 0),
                              COALESCE(v_image->>'mime_type', 'image/jpeg'),
                              v_user_profile_id, 'confirmed'
                          );
                      ELSE
                          RAISE EXCEPTION 'Item images must have either item_index or grn_item_id';
                      END IF;
                  ELSE
                      INSERT INTO grn_images (
                          id, grn_id, grn_item_id, image_type, storage_path,
                          original_filename, file_size, mime_type, uploaded_by, status
                      ) VALUES (
                          v_image_id, v_grn_id, NULL, v_image->>'image_type',
                          v_image->>'storage_path',
                          COALESCE(v_image->>'original_filename', 'unknown'),
                          COALESCE((v_image->>'file_size')::int, 0),
                          COALESCE(v_image->>'mime_type', 'image/jpeg'),
                          v_user_profile_id, 'confirmed'
                      );
                  END IF;

                  v_image_ids := array_append(v_image_ids, v_image_id);
                  v_images_saved := v_images_saved + 1;
              END LOOP;
          END IF;

          -- Rates typed on the GRN sheet (migration 86). A failure undoes the GRN with it: the
          -- raise leaves this block, whose writes are rolled back, and the handler answers it.
          IF p_rates IS NOT NULL THEN
              v_rate_failure := warehouse_security.apply_grn_rates(v_grn_id, p_rates);
              IF v_rate_failure IS NOT NULL THEN
                  RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = v_rate_failure::text;
              END IF;
          END IF;

          v_result := jsonb_build_object(
              'success', true,
              'message', 'GRN created successfully',
              'data', jsonb_build_object(
                  'grn_id', v_grn_id,
                  'gr_no', p_gr_no,
                  'items_created', v_items_created,
                  'images_saved', v_images_saved,
                  'item_ids', v_item_ids,
                  'image_ids', v_image_ids,
                  'item_mapping', v_item_mapping
              )
          );

          IF p_idempotency_key IS NOT NULL THEN
              INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by)
              VALUES (p_idempotency_key, 'save_grn', v_result, v_user_profile_id)
              ON CONFLICT (idempotency_key) DO NOTHING;
          END IF;

          RETURN v_result;

      EXCEPTION
          WHEN foreign_key_violation THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'message', 'Invalid reference: ' || SQLERRM
              );
          WHEN unique_violation THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'message', 'Duplicate value: ' || SQLERRM
              );
          WHEN OTHERS THEN
              IF SQLERRM = 'rate_fail' THEN
                  GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
                  RETURN v_detail::jsonb;
              END IF;
              RETURN jsonb_build_object(
                  'success', false,
                  'message', 'Error creating GRN: ' || SQLERRM
              );
      END;
  END;
  $function$;
REVOKE ALL ON FUNCTION public.save_grn(character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, text, character varying, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_grn(character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, text, character varying, jsonb) TO authenticated, service_role;

CREATE FUNCTION public.update_grn(p_grn_id uuid, p_gr_no character varying DEFAULT NULL::character varying, p_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_customer_id uuid DEFAULT NULL::uuid, p_customer_name character varying DEFAULT NULL::character varying, p_sender_id uuid DEFAULT NULL::uuid, p_sender_name character varying DEFAULT NULL::character varying, p_supervisor_id uuid DEFAULT NULL::uuid, p_supervisor_name character varying DEFAULT NULL::character varying, p_registration character varying DEFAULT NULL::character varying, p_note character varying DEFAULT NULL::character varying, p_leon boolean DEFAULT NULL::boolean, p_pricing_mode character varying DEFAULT NULL::character varying, p_items jsonb DEFAULT '[]'::jsonb, p_images jsonb DEFAULT '[]'::jsonb, p_duration_mode character varying DEFAULT NULL::character varying, p_idempotency_key text DEFAULT NULL::text, p_rates jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
 SET jit TO 'off'
AS $function$
DECLARE
    v_user_id uuid;
    v_user_profile_id uuid;
    v_user_role text;
    v_item jsonb;
    v_image jsonb;
    v_grn_trl_item_id uuid;
    v_image_id uuid;
    v_current_qty int;
    v_current_stock int;
    v_item_name_from_db varchar;
    v_dispatched_qty int;
    v_items_updated int := 0;
    v_items_added int := 0;
    v_items_deleted int := 0;
    v_images_updated int := 0;
    v_images_added int := 0;
    v_images_deleted int := 0;
    v_items_skipped_stock jsonb := '[]'::jsonb;
    v_existing_grn_item_ids uuid[];
    v_provided_grn_item_ids uuid[];
    v_items_to_delete uuid[];
    v_item_index int;
    v_item_mapping jsonb := '[]'::jsonb;
    v_resolved_item_id uuid;
    v_existing_image_ids uuid[];
    v_kept_image_ids uuid[];
    v_final_grn_data jsonb;
    v_grn_items jsonb := '[]'::jsonb;
    v_grn_images jsonb;
    v_temp_item jsonb;
    v_grn_header jsonb;
    v_item_master_id uuid;
    v_item_name varchar;
    v_cached_response jsonb;
    v_result jsonb;
    v_line_rows integer;
    v_bad_line text;
    v_rate_failure jsonb;
    v_detail text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_grn',jsonb_build_object('p_grn_id',p_grn_id,'p_customer_id',p_customer_id));
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Authentication required'
        );
    END IF;

    SELECT id, role INTO v_user_profile_id, v_user_role
    FROM user_profiles
    WHERE auth_user_id = v_user_id;

    IF v_user_profile_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'User profile not found'
        );
    END IF;

    IF v_user_role NOT IN ('admin', 'supervisor', 'staff') THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Insufficient permissions. Only admin and supervisor can update GRNs'
        );
    END IF;

    -- IDEMPOTENCY CHECK: a repeated save answers with the stored result (migration 47)
    IF p_idempotency_key IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(71040);

        SELECT response INTO v_cached_response
        FROM idempotency_keys
        WHERE idempotency_key = p_idempotency_key
          AND rpc_function = 'update_grn'
          AND created_by = v_user_profile_id
          AND response #>> '{grn,id}' = p_grn_id::text
          AND expires_at > now();

        IF v_cached_response IS NOT NULL THEN
            RETURN v_cached_response || jsonb_build_object('idempotent', true);
        END IF;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM goodsreceived WHERE id = p_grn_id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'GRN not found'
        );
    END IF;

    PERFORM warehouse_security.require_person_supervisor(p_supervisor_id::text,
      (SELECT supervisor_id FROM goodsreceived WHERE id = p_grn_id));

    IF p_gr_no IS NOT NULL AND warehouse_security.is_blank_text(p_gr_no) THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'GRN number is required'
        );
    END IF;

    IF p_gr_no IS NOT NULL AND EXISTS (
        SELECT 1 FROM goodsreceived
        WHERE gr_no = p_gr_no AND id != p_grn_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'GRN number already exists: ' || p_gr_no
        );
    END IF;

    BEGIN
        PERFORM pg_advisory_xact_lock(71040);

        IF p_customer_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM goodsreceived
            WHERE id = p_grn_id AND customer_id IS DISTINCT FROM p_customer_id
        ) THEN
            IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND deleted_at IS NOT NULL) THEN
                RAISE EXCEPTION 'Business is not active' USING ERRCODE = 'P0001';
            END IF;
            IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND active = false) THEN
                RAISE EXCEPTION 'This business is deactivated. Activate it in Customers to receive new goods.' USING ERRCODE = 'P0001';
            END IF;
            PERFORM 1 FROM goodsreceived WHERE id = p_grn_id FOR UPDATE;

            IF EXISTS (SELECT 1 FROM dispatch_trl WHERE gr_id = p_grn_id)
               OR EXISTS (SELECT 1 FROM invoice WHERE gr_id = p_grn_id)
               OR EXISTS (
                   SELECT 1 FROM order_items oi
                   JOIN orders o ON o.id = oi.order_id
                   JOIN goodsreceived_trl gt ON gt.id = oi.grn_items_id
                   WHERE gt.gr_id = p_grn_id AND o.deleted_at IS NULL
               ) THEN
                RAISE EXCEPTION 'Cannot change the customer of a GRN that has dispatches, invoices or order items';
            END IF;
        END IF;
        IF p_pricing_mode IS NOT NULL AND EXISTS (
            SELECT 1 FROM goodsreceived
            WHERE id = p_grn_id AND COALESCE(pricing_mode, 'MONTHLY') IS DISTINCT FROM p_pricing_mode
        ) THEN
            PERFORM 1 FROM goodsreceived WHERE id = p_grn_id FOR UPDATE;

            IF EXISTS (SELECT 1 FROM invoice WHERE gr_id = p_grn_id AND deleted_at IS NULL)
               OR EXISTS (
                   SELECT 1 FROM invoice_trl it
                   JOIN dispatch_trl dt ON dt.id = it.disp_trl_id
                   JOIN invoice inv ON inv.id = it.invoice_id
                   WHERE dt.gr_id = p_grn_id AND inv.deleted_at IS NULL
               ) THEN
                RAISE EXCEPTION 'Cannot change the pricing mode of a GRN that has invoices: delete invoices first, then change the pricing mode and invoice again';
            END IF;
        END IF;

        SELECT (e->>'id')::uuid::text INTO v_bad_line
        FROM jsonb_array_elements(p_items) AS e
        WHERE e->>'id' IS NOT NULL
        GROUP BY (e->>'id')::uuid
        HAVING count(*) > 1
        LIMIT 1;
        IF v_bad_line IS NOT NULL THEN
            RAISE EXCEPTION 'A GRN line is sent more than once in this edit; reload the GRN and edit again';
        END IF;

        SELECT x.e->>'id' INTO v_bad_line
        FROM jsonb_array_elements(p_items) WITH ORDINALITY AS x(e, n)
        WHERE x.e->>'id' IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM goodsreceived_trl t
              WHERE t.id = (x.e->>'id')::uuid AND t.gr_id = p_grn_id
          )
        ORDER BY x.n
        LIMIT 1;
        IF v_bad_line IS NOT NULL THEN
            RAISE EXCEPTION 'GRN line % is not a line of this GRN; reload the GRN and edit again', v_bad_line;
        END IF;

        PERFORM safe_disable_grn_trl_triggers();

        UPDATE goodsreceived SET
            gr_no = COALESCE(p_gr_no, gr_no),
            date = COALESCE(p_date, date),
            customer_id = COALESCE(p_customer_id, customer_id),
            customer_name = CASE
                WHEN p_customer_id IS NOT NULL AND p_customer_id IS DISTINCT FROM customer_id
                THEN COALESCE((SELECT c.name FROM customers c WHERE c.id = p_customer_id), customer_name)
                ELSE customer_name END,
            sender_id = COALESCE(p_sender_id, sender_id),
            sender_name = COALESCE(p_sender_name, sender_name),
            supervisor_id = COALESCE(p_supervisor_id, supervisor_id),
            supervisor_name = COALESCE(p_supervisor_name, supervisor_name),
            registration = COALESCE(p_registration, registration),
            note = COALESCE(p_note, note),
            leon = COALESCE(p_leon, leon),
            pricing_mode = COALESCE(p_pricing_mode, pricing_mode),
            duration_mode = COALESCE(p_duration_mode, duration_mode),
            updated_by = v_user_profile_id,
            updated_at = now()
        WHERE id = p_grn_id;

        SELECT array_agg(id) INTO v_existing_grn_item_ids
        FROM goodsreceived_trl
        WHERE gr_id = p_grn_id;

        v_provided_grn_item_ids := ARRAY[]::uuid[];

        v_item_index := 0;
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
        LOOP
            v_item_master_id := (v_item->>'item_id')::uuid;
            v_item_name := v_item->>'item_name';

            IF v_item_master_id IS NULL THEN
                RAISE EXCEPTION 'itemId is required for all items';
            END IF;
            IF v_item_name IS NULL OR v_item_name = '' THEN
                RAISE EXCEPTION 'itemName is required for all items';
            END IF;
            IF (v_item->>'qty')::int <= 0 THEN
                RAISE EXCEPTION 'Quantity must be greater than 0 for item "%"', v_item_name;
            END IF;
            IF (v_item->>'weight')::int < 0 THEN
                RAISE EXCEPTION 'Weight cannot be negative for item "%"', v_item_name;
            END IF;

            IF v_item->>'id' IS NOT NULL THEN
                SELECT qty, stock, item_name
                INTO v_current_qty, v_current_stock, v_item_name_from_db
                FROM goodsreceived_trl
                WHERE id = (v_item->>'id')::uuid AND gr_id = p_grn_id
                FOR UPDATE;

                IF NOT FOUND THEN
                    RAISE EXCEPTION 'GRN line % is not a line of this GRN; reload the GRN and edit again', v_item->>'id';
                END IF;

                SELECT COALESCE(SUM(disp_qty), 0)
                INTO v_dispatched_qty
                FROM dispatch_trl
                WHERE gr_trl_id = (v_item->>'id')::uuid;

                IF v_dispatched_qty = 0 THEN
                    UPDATE goodsreceived_trl SET
                        item_id = v_item_master_id,
                        item_name = v_item_name,
                        packaging = v_item->>'packaging',
                        qty = (v_item->>'qty')::int,
                        stock = (v_item->>'qty')::int,
                        weight = COALESCE((v_item->>'weight')::int, 0),
                        rack = v_item->>'rack',
                        package_mark = v_item->>'package_mark'
                    WHERE id = (v_item->>'id')::uuid AND gr_id = p_grn_id;

                    GET DIAGNOSTICS v_line_rows = ROW_COUNT;
                    IF v_line_rows <> 1 THEN
                        RAISE EXCEPTION 'GRN line % is not a line of this GRN; reload the GRN and edit again', v_item->>'id';
                    END IF;

                    v_items_updated := v_items_updated + 1;
                ELSE
                    UPDATE goodsreceived_trl SET
                        item_id = v_item_master_id,
                        item_name = v_item_name,
                        packaging = v_item->>'packaging',
                        weight = COALESCE((v_item->>'weight')::int, 0),
                        rack = v_item->>'rack',
                        package_mark = v_item->>'package_mark'
                    WHERE id = (v_item->>'id')::uuid AND gr_id = p_grn_id;

                    GET DIAGNOSTICS v_line_rows = ROW_COUNT;
                    IF v_line_rows <> 1 THEN
                        RAISE EXCEPTION 'GRN line % is not a line of this GRN; reload the GRN and edit again', v_item->>'id';
                    END IF;

                    v_items_updated := v_items_updated + 1;

                    v_items_skipped_stock := v_items_skipped_stock || jsonb_build_object(
                        'grn_trl_item_id', v_item->>'id',
                        'item_name', v_item_name_from_db,
                        'reason', format('Cannot update qty/stock - item has %s units dispatched', v_dispatched_qty),
                        'current_qty', v_current_qty,
                        'current_stock', v_current_stock,
                        'dispatched_qty', v_dispatched_qty
                    );
                END IF;

                v_provided_grn_item_ids := array_append(v_provided_grn_item_ids, (v_item->>'id')::uuid);
            ELSE
                INSERT INTO goodsreceived_trl (
                    gr_id, item_id, item_name, packaging, qty, stock, weight, rack, package_mark
                ) VALUES (
                    p_grn_id, v_item_master_id, v_item_name, v_item->>'packaging',
                    (v_item->>'qty')::int, (v_item->>'qty')::int,
                    COALESCE((v_item->>'weight')::int, 0), v_item->>'rack', v_item->>'package_mark'
                ) RETURNING id INTO v_grn_trl_item_id;

                v_items_added := v_items_added + 1;

                v_item_mapping := v_item_mapping || jsonb_build_object(
                    'index', v_item_index,
                    'grn_trl_item_id', v_grn_trl_item_id,
                    'item_name', v_item_name
                );
            END IF;

            v_item_index := v_item_index + 1;
        END LOOP;

        IF v_existing_grn_item_ids IS NOT NULL THEN
            v_items_to_delete := ARRAY(
                SELECT unnest(v_existing_grn_item_ids)
                EXCEPT
                SELECT unnest(v_provided_grn_item_ids)
            );

            IF v_items_to_delete IS NOT NULL THEN
                FOR v_grn_trl_item_id IN SELECT unnest(v_items_to_delete)
                LOOP
                    SELECT COUNT(*) INTO v_dispatched_qty
                    FROM dispatch_trl
                    WHERE gr_trl_id = v_grn_trl_item_id;

                    IF v_dispatched_qty > 0 THEN
                        SELECT item_name INTO v_item_name_from_db
                        FROM goodsreceived_trl
                        WHERE id = v_grn_trl_item_id;

                        RAISE EXCEPTION 'Cannot delete item "%" - has % existing dispatches',
                            v_item_name_from_db, v_dispatched_qty;
                    END IF;

                    DELETE FROM goodsreceived_trl WHERE id = v_grn_trl_item_id;
                    v_items_deleted := v_items_deleted + 1;
                END LOOP;
            END IF;
        END IF;

        IF jsonb_array_length(p_images) > 0 THEN
            v_kept_image_ids := ARRAY[]::uuid[];

            FOR v_image IN SELECT * FROM jsonb_array_elements(p_images)
            LOOP
                IF v_image->>'storage_path' IS NULL OR v_image->>'image_type' IS NULL THEN
                    RAISE EXCEPTION 'Invalid image data: storage_path and image_type are required';
                END IF;

                v_resolved_item_id := NULL;
                IF v_image->>'image_type' = 'item' THEN
                    IF v_image->>'grn_item_id' IS NOT NULL THEN
                        v_resolved_item_id := (v_image->>'grn_item_id')::uuid;
                    ELSIF v_image->>'item_index' IS NOT NULL THEN
                        SELECT (mapping->>'grn_trl_item_id')::uuid INTO v_resolved_item_id
                        FROM jsonb_array_elements(v_item_mapping) mapping
                        WHERE (mapping->>'index')::int = (v_image->>'item_index')::int;

                        IF v_resolved_item_id IS NULL THEN
                            RAISE EXCEPTION 'Invalid item_index % for image', v_image->>'item_index';
                        END IF;
                    ELSE
                        RAISE EXCEPTION 'Item images must have either grn_item_id or item_index';
                    END IF;
                END IF;

                IF v_resolved_item_id IS NOT NULL AND NOT EXISTS (
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

                IF v_image_id IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM grn_images seen
                    WHERE seen.id = v_image_id
                    AND warehouse_security.grn_image_visible(seen.status, seen.uploaded_by)) THEN
                    -- Migration 69: another person's pending photo, named in the list, stays as it is.
                    v_kept_image_ids := array_append(v_kept_image_ids, v_image_id);
                ELSIF v_image_id IS NOT NULL THEN
                    UPDATE grn_images SET
                        grn_item_id = v_resolved_item_id,
                        updated_at = now()
                    WHERE id = v_image_id AND grn_id = p_grn_id;

                    v_images_updated := v_images_updated + 1;
                    v_kept_image_ids := array_append(v_kept_image_ids, v_image_id);
                ELSE
                    PERFORM warehouse_security.require_image_path('grn', p_grn_id, v_image->>'image_type', v_image->>'storage_path');

                    v_image_id := gen_random_uuid();

                    INSERT INTO grn_images (
                        id, grn_id, grn_item_id, image_type, storage_path,
                        original_filename, file_size, mime_type, uploaded_by, status
                    ) VALUES (
                        v_image_id, p_grn_id, v_resolved_item_id, v_image->>'image_type',
                        v_image->>'storage_path', COALESCE(v_image->>'original_filename', 'unknown'),
                        COALESCE((v_image->>'file_size')::int, 0),
                        COALESCE(v_image->>'mime_type', 'image/jpeg'), v_user_profile_id, 'confirmed'
                    );

                    v_images_added := v_images_added + 1;
                    v_kept_image_ids := array_append(v_kept_image_ids, v_image_id);
                END IF;
            END LOOP;

            DELETE FROM grn_images
            WHERE grn_id = p_grn_id
            AND id NOT IN (SELECT unnest(v_kept_image_ids))
            AND warehouse_security.grn_image_visible(grn_images.status, grn_images.uploaded_by);

            GET DIAGNOSTICS v_images_deleted = ROW_COUNT;
        ELSE
            v_images_deleted := 0;
        END IF;

        -- The GRN's own rates follow its lines, whether or not p_rates came: a rate of another pricing
        -- kind, or one whose band holds no weight of its item's lines any more, goes. An invoiced
        -- GRN keeps its (archived) rates.
        DELETE FROM public.grn_rates gr WHERE gr.gr_id = p_grn_id
          AND NOT EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = p_grn_id AND g.invoiced IS TRUE)
          AND (gr.price_type <> (SELECT CASE WHEN upper(COALESCE(g.pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END
                                   FROM public.goodsreceived g WHERE g.id = p_grn_id)
               OR NOT EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.gr_id = p_grn_id AND t.item_id = gr.item_id
                                AND COALESCE(t.weight, 0) BETWEEN gr.weight_min AND gr.weight_max));

        -- Rates typed on the GRN sheet (migration 86), after the lines are written. A failure
        -- raises out of this block, which undoes the update, and the handler answers it.
        IF p_rates IS NOT NULL THEN
            v_rate_failure := warehouse_security.apply_grn_rates(p_grn_id, p_rates);
            IF v_rate_failure IS NOT NULL THEN
                RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = v_rate_failure::text;
            END IF;
        END IF;

        PERFORM safe_enable_grn_trl_triggers();

        INSERT INTO mv_refresh_status (mv_name, is_dirty, last_marked_dirty_at)
        VALUES
            ('mv_grn_list', true, now()),
            ('mv_dispatch_list', true, now()),
            ('mv_customer_stock_summary', true, now())
        ON CONFLICT (mv_name) DO UPDATE SET
            is_dirty = true,
            last_marked_dirty_at = now();

        PERFORM pg_advisory_xact_lock(71040);
        UPDATE public.mv_refresh_queue SET needs_refresh=true,last_marked_dirty=now()
          WHERE mv_name IN ('mv_customer_stock_summary','mv_grn_daily_summary',
            'mv_dispatch_daily_summary','mv_grn_list','mv_dispatch_list','mv_orders_list','mv_invoice_list');
        PERFORM warehouse_security.refresh_dirty_lists();

        SELECT jsonb_agg(
            jsonb_build_object(
                'id', t.id,
                'item_id', t.item_id,
                'item_name', t.item_name,
                'packaging', t.packaging,
                'qty', t.qty,
                'stock', t.stock,
                'weight', t.weight,
                'rack', t.rack,
                'package_mark', t.package_mark
            )
        ) INTO v_grn_items
        FROM goodsreceived_trl t
        WHERE t.gr_id = p_grn_id;

        SELECT jsonb_agg(
            jsonb_build_object(
                'id', i.id,
                'image_type', i.image_type,
                'storage_path', i.storage_path,
                'grn_item_id', i.grn_item_id,
                'original_filename', i.original_filename
            )
        ) INTO v_grn_images
        FROM grn_images i
        WHERE i.grn_id = p_grn_id
        AND warehouse_security.grn_image_visible(i.status, i.uploaded_by);

        SELECT jsonb_build_object(
            'id', g.id,
            'gr_no', g.gr_no,
            'date', g.date,
            'customer_id', g.customer_id,
            'customer_name', g.customer_name,
            'sender_id', g.sender_id,
            'sender_name', g.sender_name,
            'supervisor_id', g.supervisor_id,
            'supervisor_name', g.supervisor_name,
            'registration', g.registration,
            'note', g.note,
            'leon', g.leon,
            'pricing_mode', g.pricing_mode,
            'duration_mode', g.duration_mode
        ) INTO v_grn_header
        FROM goodsreceived g
        WHERE g.id = p_grn_id;

        v_final_grn_data := v_grn_header || jsonb_build_object(
            'items', COALESCE(v_grn_items, '[]'::jsonb),
            'images', COALESCE(v_grn_images, '[]'::jsonb)
        );

        v_result := jsonb_build_object(
            'success', true,
            'message', 'GRN updated successfully',
            'grn', v_final_grn_data,
            'stats', jsonb_build_object(
                'items_updated', v_items_updated,
                'items_added', v_items_added,
                'items_deleted', v_items_deleted,
                'images_updated', v_images_updated,
                'images_added', v_images_added,
                'images_deleted', v_images_deleted,
                'items_skipped_stock', v_items_skipped_stock
            ),
            'item_mapping', v_item_mapping
        );

        -- Kept for the 24 hours a retry is answered from it. A key another
        -- function or user holds is left alone unless it has expired.
        IF p_idempotency_key IS NOT NULL THEN
            INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
            VALUES (p_idempotency_key, 'update_grn', v_result, v_user_profile_id, now() + interval '24 hours')
            ON CONFLICT (idempotency_key) DO UPDATE SET
                rpc_function = EXCLUDED.rpc_function,
                response = EXCLUDED.response,
                created_by = EXCLUDED.created_by,
                created_at = now(),
                expires_at = EXCLUDED.expires_at
            WHERE idempotency_keys.expires_at <= now()
               OR (idempotency_keys.rpc_function = EXCLUDED.rpc_function
                   AND idempotency_keys.created_by IS NOT DISTINCT FROM EXCLUDED.created_by);
        END IF;

        RETURN v_result;

    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'rate_fail' THEN
            GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
            PERFORM safe_enable_grn_trl_triggers();
            RETURN v_detail::jsonb;
        END IF;
        PERFORM safe_enable_grn_trl_triggers();
        RAISE;
    END;
END;
$function$;
REVOKE ALL ON FUNCTION public.update_grn(uuid, character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, character varying, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_grn(uuid, character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, character varying, text, jsonb) TO authenticated, service_role;

DO $check$ BEGIN
  IF (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('save_grn','update_grn')) <> 2 THEN
    RAISE EXCEPTION 'save_grn and update_grn must each have exactly one overload';
  END IF;
  IF EXISTS (
    SELECT 1 FROM grn_fn_before b JOIN pg_proc p ON p.pronamespace = 'public'::regnamespace AND p.proname = b.proname
     WHERE (pg_get_userbyid(p.proowner), p.proacl::text, p.proconfig::text, p.prosecdef, p.provolatile, p.proisstrict, p.prorettype::regtype::text)
           IS DISTINCT FROM (b.owner, b.acl, b.config, b.prosecdef, b.provolatile, b.proisstrict, b.returns)
  ) THEN
    RAISE EXCEPTION 'save_grn / update_grn: owner, options or grants changed by the re-create';
  END IF;
END $check$;
DROP TABLE grn_fn_before;

-- ---------------------------------------------------------------------------
-- 5. Where the GRN's own rate is used, shown, listed; the guard
-- ---------------------------------------------------------------------------
DO $patch$ BEGIN
  PERFORM pg_temp.patch_rpc('public.build_invoice_recalculation_rows(uuid,text,uuid)',
  $m$    v_price_record item_storage_prices;
$m$, $r$    v_price_record item_storage_prices;
    v_src_unit numeric(12,2);
    v_src_labour numeric(12,2);
    v_src_tax numeric(5,2);
$r$);
  PERFORM pg_temp.patch_rpc('public.build_invoice_recalculation_rows(uuid,text,uuid)',
  $m$        v_price_record := find_storage_price(
            v_dispatch_record.grn_items_item_id,
            v_grn_customer_id,
            v_dispatch_record.grn_items_weight,
            v_grn_date,
            LOWER(v_grn_pricing_mode)
        );

        v_unit_price := COALESCE(v_dispatch_record.existing_charge, v_price_record.unit_price);
        v_labour_rate := COALESCE(v_dispatch_record.existing_labour_rate, v_price_record.labour_rate, 0);
        v_tax_percent := COALESCE(v_dispatch_record.existing_tax, v_price_record.tax_percent, 0);
$m$, $r$        -- One source for all three figures (migration 86): the GRN's own rate, else the item's.
        v_src_unit := NULL; v_src_labour := NULL; v_src_tax := NULL;
        SELECT g.unit_price, g.labour_rate, g.tax_percent INTO v_src_unit, v_src_labour, v_src_tax
          FROM public.grn_rates g
         WHERE g.gr_id = p_gr_id AND g.item_id = v_dispatch_record.grn_items_item_id
           AND g.price_type = CASE WHEN upper(COALESCE(v_grn_pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END
           AND COALESCE(v_dispatch_record.grn_items_weight, 0) BETWEEN g.weight_min AND g.weight_max
         ORDER BY (g.weight_max - g.weight_min), g.weight_min
         LIMIT 1;
        IF NOT FOUND THEN
            v_price_record := find_storage_price(
                v_dispatch_record.grn_items_item_id,
                v_grn_customer_id,
                v_dispatch_record.grn_items_weight,
                v_grn_date,
                LOWER(v_grn_pricing_mode)
            );
            v_src_unit := v_price_record.unit_price;
            v_src_labour := v_price_record.labour_rate;
            v_src_tax := v_price_record.tax_percent;
        END IF;

        -- A saved invoice's own figures win over both.
        v_unit_price := COALESCE(v_dispatch_record.existing_charge, v_src_unit);
        v_labour_rate := COALESCE(v_dispatch_record.existing_labour_rate, v_src_labour, 0);
        v_tax_percent := COALESCE(v_dispatch_record.existing_tax, v_src_tax, 0);
$r$);
  -- get_grn_details: grn.rates.
  PERFORM pg_temp.patch_rpc('public.get_grn_details(uuid)',
  $m$                    'duration_mode', gr.duration_mode,
                    'created_at', gr.created_at,
$m$, $r$                    'duration_mode', gr.duration_mode,
                    'rates', CASE WHEN v_role IN ('admin', 'supervisor', 'staff') OR auth.jwt() ->> 'role' = 'service_role'
                      THEN COALESCE(
                        (
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'id', rt.id,
                                    'item_id', rt.item_id,
                                    'item_name', ri.name,
                                    'price_type', rt.price_type,
                                    'weight_min', rt.weight_min,
                                    'weight_max', rt.weight_max,
                                    'unit_price', rt.unit_price,
                                    'labour_rate', rt.labour_rate,
                                    'tax_percent', rt.tax_percent,
                                    'archived', COALESCE(gr.invoiced, false)
                                )
                                ORDER BY ri.name, rt.weight_min, rt.id
                            )
                            FROM grn_rates rt
                            LEFT JOIN items ri ON ri.id = rt.item_id
                            WHERE rt.gr_id = gr.id
                        ),
                        '[]'::jsonb
                    ) ELSE '[]'::jsonb END,
                    'created_at', gr.created_at,
$r$);
  -- delete_item_safe: a GRN-only rate is data, like a line (never cascaded).
  PERFORM pg_temp.patch_rpc('public.delete_item_safe(uuid)',
  $m$IF v_grn_count > 0 OR v_order_count > 0 THEN$m$,
  $r$IF v_grn_count > 0 OR v_order_count > 0 OR EXISTS (SELECT 1 FROM public.grn_rates WHERE item_id = p_item_id) THEN$r$);
  PERFORM pg_temp.patch_rpc('public.delete_item_safe(uuid)',
  $m$'order_items_count', v_order_count,$m$,
  $r$'order_items_count', v_order_count,
                'grn_rates_count', (SELECT count(*) FROM public.grn_rates WHERE item_id = p_item_id),$r$);
  -- The guard: staff reach get_item_grn_rates.
  PERFORM pg_temp.patch_rpc('warehouse_security.authorize_rpc(text,jsonb)',
  $m$    'get_standard_rate','set_standard_rate',
$m$, $r$    'get_standard_rate','set_standard_rate',
    -- The GRN-only rates of an item (migration 86).
    'get_item_grn_rates',
$r$);
END $patch$;

-- The GRN-only rates of one item, newest GRN first; the rates of an invoiced GRN ("archived")
-- come after the rest.
CREATE FUNCTION public.get_item_grn_rates(p_item_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, utils, pg_temp
AS $function$
DECLARE v_rates jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_item_grn_rates', jsonb_build_object());
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', r.id, 'gr_id', g.id, 'gr_no', g.gr_no, 'grn_date', warehouse_security.business_date(g.date),
           'customer_id', g.customer_id, 'customer_name', g.customer_name, 'price_type', r.price_type,
           'weight_min', r.weight_min, 'weight_max', r.weight_max, 'unit_price', r.unit_price,
           'labour_rate', r.labour_rate, 'tax_percent', r.tax_percent,
           'archived', COALESCE(g.invoiced, false), 'created_at', r.created_at)
         ORDER BY COALESCE(g.invoiced, false), warehouse_security.business_date(g.date) DESC, g.gr_no, r.weight_min, r.id), '[]'::jsonb)
    INTO v_rates
    FROM public.grn_rates r JOIN public.goodsreceived g ON g.id = r.gr_id
   WHERE r.item_id = p_item_id AND g.deleted_at IS NULL;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('rates', v_rates));
END;
$function$;
REVOKE ALL ON FUNCTION public.get_item_grn_rates(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_item_grn_rates(uuid) TO authenticated, service_role;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
NOTIFY pgrst, 'reload schema';
