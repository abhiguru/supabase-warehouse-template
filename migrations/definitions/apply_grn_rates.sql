-- warehouse_security.apply_grn_rates: the definition setup applies after the numbered migrations whenever this file's checksum changes
-- (scripts/migration-plan.mjs, table warehouse_migrations.definitions). Edit the function here, never in a new migration.
-- Starts as the function migrations 000 to 126 leave (the numbered files that patched it stay as they are, never edited).
CREATE OR REPLACE FUNCTION warehouse_security.apply_grn_rates(p_gr_id uuid, p_rates jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_profile uuid; v_customer uuid; v_mode text; v_day date; v_invoiced boolean; v_type text;
  v_e jsonb; v_ord integer; v_field text; v_n numeric; v_limit numeric; v_scope text; v_item uuid;
  v_min integer; v_max integer; v_to date; v_cust uuid; v_unit numeric; v_lab numeric; v_tax numeric;
  v_starts date; v_row public.item_storage_prices; v_old_to date; v_new_id uuid; v_key text; v_missing jsonb;
  v_amount constant text := 'Rent and labour must be 0 to 999999 with two decimals at most; tax 0 to 100';
  v_band constant text := 'Each band needs whole kilograms with the start at most the end';
  v_unseen jsonb;
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
    -- seen_ids (migration 120), when an entry carries it: the ids of the rate rows of the entry's scope that the
    -- sheet showed in force on the GRN day. A list of uuids, or absent (an older app).
    IF v_scope <> 'grn' AND jsonb_typeof(v_e->'seen_ids') IS NOT NULL AND jsonb_typeof(v_e->'seen_ids') <> 'null' THEN
      IF (CASE WHEN jsonb_typeof(v_e->'seen_ids') <> 'array' THEN true
               ELSE EXISTS (SELECT 1 FROM jsonb_array_elements(v_e->'seen_ids') s
                             WHERE jsonb_typeof(s) <> 'string'
                                OR (s #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') END) THEN
        RETURN warehouse_security.grn_rate_failure('INVALID_BANDS', 'seen_ids must be a list of rate ids',
          jsonb_build_object('index', v_ord, 'field', 'seen_ids'));
      END IF;
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
  -- A sheet that is out of date (migration 120). An entry that lists seen_ids names the rows of its scope that the
  -- sheet showed in force on the GRN day. A row of the entry's scope and band that is in force on that day and is not
  -- listed was added or changed by someone else since, so nothing is written (STALE_RATES; data.ids is the unlisted
  -- ids, sorted). An entry without seen_ids is not checked. Every entry is read before the first write, because the
  -- writes below end and copy the rows of the other bands of the scope.
  FOR v_e, v_ord IN SELECT e.value, (e.ord - 1)::integer FROM jsonb_array_elements(p_rates) WITH ORDINALITY e(value, ord)
      WHERE e.value->>'scope' IN ('customer','everyone') AND jsonb_typeof(e.value->'seen_ids') = 'array' ORDER BY e.ord LOOP
    SELECT COALESCE(jsonb_agg(r.id ORDER BY r.id), '[]'::jsonb) INTO v_unseen
      FROM public.item_storage_prices r
     WHERE r.item_id = (v_e->>'item_id')::uuid
       AND r.customer_id IS NOT DISTINCT FROM CASE WHEN v_e->>'scope' = 'customer' THEN v_customer END
       AND r.price_type = v_type
       AND r.weight_min = (v_e->>'weight_min')::numeric::integer AND r.weight_max = (v_e->>'weight_max')::numeric::integer
       AND r.effective_from <= v_day AND COALESCE(r.effective_to, 'infinity'::date) >= v_day
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_e->'seen_ids') s WHERE lower(s) = r.id::text);
    IF v_unseen <> '[]'::jsonb THEN
      RETURN warehouse_security.grn_rate_failure('STALE_RATES', 'The rates were changed by someone else; reload and try again',
        jsonb_build_object('index', v_ord, 'ids', v_unseen)) || jsonb_build_object('reason', 'STALE_RATES');
    END IF;
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
END $function$;

REVOKE ALL ON FUNCTION warehouse_security.apply_grn_rates(uuid,jsonb) FROM PUBLIC, anon, authenticated, service_role;
