-- Pricing review migration (2026-10-20), backend half.
--  * set_standard_rate(p_tiers, p_expected_updated_at, p_dry_run): a stale check for two managers editing the
--    standard rate (STALE_STANDARD_RATE), and a dry run that returns how many items would receive the rate.
--  * undo_rate_change(..., p_seen_rows): the stale protection replace_item_rates has (STALE_RATES).
-- Both new parameters are defaulted, so an older app that sends the old arguments keeps working. The old
-- signatures are dropped first: PostgREST would otherwise see two overloads it cannot tell apart.
-- Grants and owner are exactly the baseline's (authenticated and service_role; not anon, not PUBLIC).

DROP FUNCTION public.set_standard_rate(jsonb);

CREATE FUNCTION public.set_standard_rate(p_tiers jsonb, p_expected_updated_at timestamptz DEFAULT NULL, p_dry_run boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_role text; v_profile uuid; v_failure jsonb; v_today date := warehouse_security.business_date(now());
  v_item record; v_priced integer := 0; v_tiers jsonb; v_current timestamptz; v_updated timestamptz;
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

  -- A stale editor: p_expected_updated_at is the updated_at get_standard_rate returned when the editor
  -- loaded the rate (every tier of a save carries the same time, so max(updated_at) is its version). A
  -- different current version means someone saved since, so nothing is written. NULL skips the check
  -- (an old app). '-infinity' means "I loaded no tiers": it matches only an empty table, so the very first
  -- save is protected too.
  SELECT max(t.updated_at) INTO v_current FROM public.standard_rate_tiers t;
  IF p_expected_updated_at IS NOT NULL AND v_current IS DISTINCT FROM NULLIF(p_expected_updated_at, '-infinity'::timestamptz) THEN
    RETURN warehouse_security.rate_failure('STALE_STANDARD_RATE', 'The standard rate was changed by someone else; reload and try again',
      jsonb_build_object('updated_at', v_current));
  END IF;

  -- Active items with no default row at all start on the India day of their first GRN that is
  -- not deleted, else today. A dry run only counts them (every tier list that passed the checks is
  -- not empty, so each such item receives rows).
  IF p_dry_run THEN
    SELECT count(*) INTO v_priced FROM public.items i
     WHERE i.active
       AND NOT EXISTS (SELECT 1 FROM public.item_storage_prices r WHERE r.item_id = i.id AND r.customer_id IS NULL);
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
      'dry_run', true, 'items_priced', v_priced, 'tiers', p_tiers, 'updated_at', v_current));
  END IF;

  DELETE FROM public.standard_rate_tiers WHERE true;
  INSERT INTO public.standard_rate_tiers (weight_min, weight_max, unit_price, labour_rate, tax_percent, updated_at, updated_by)
  SELECT (e.value->>'weight_min')::numeric::integer, (e.value->>'weight_max')::numeric::integer, (e.value->>'unit_price')::numeric,
         (e.value->>'labour_rate')::numeric, (e.value->>'tax_percent')::numeric, now(), v_profile
    FROM jsonb_array_elements(p_tiers) e;

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
           'unit_price', t.unit_price, 'labour_rate', t.labour_rate, 'tax_percent', t.tax_percent) ORDER BY t.weight_min), '[]'::jsonb),
         max(t.updated_at)
    INTO v_tiers, v_updated FROM public.standard_rate_tiers t;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'tiers', v_tiers, 'items_priced', v_priced, 'dry_run', false, 'updated_at', v_updated));
END;
$$;

ALTER FUNCTION public.set_standard_rate(p_tiers jsonb, p_expected_updated_at timestamptz, p_dry_run boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.set_standard_rate(p_tiers jsonb, p_expected_updated_at timestamptz, p_dry_run boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_standard_rate(p_tiers jsonb, p_expected_updated_at timestamptz, p_dry_run boolean) FROM anon;
GRANT ALL ON FUNCTION public.set_standard_rate(p_tiers jsonb, p_expected_updated_at timestamptz, p_dry_run boolean) TO service_role;
GRANT ALL ON FUNCTION public.set_standard_rate(p_tiers jsonb, p_expected_updated_at timestamptz, p_dry_run boolean) TO authenticated;

DROP FUNCTION public.undo_rate_change(uuid, uuid, text, date);

CREATE FUNCTION public.undo_rate_change(p_item_id uuid, p_customer_id uuid, p_price_type text, p_starts_on date, p_seen_rows uuid[] DEFAULT NULL::uuid[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_role text; v_next date; v_stop date; v_unseen uuid[];
  v_removed jsonb := '[]'::jsonb; v_reopened jsonb := '[]'::jsonb; v_row record;
BEGIN
  PERFORM warehouse_security.authorize_rpc('undo_rate_change', jsonb_build_object('p_customer_id', p_customer_id));
  SELECT up.role::text INTO v_role FROM public.user_profiles up WHERE up.auth_user_id = auth.uid() AND up.active;

  IF p_price_type IS NULL OR p_price_type NOT IN ('monthly','one_time') THEN
    RETURN warehouse_security.rate_failure('INVALID_PRICE_TYPE', 'Price type must be monthly or one_time');
  END IF;
  IF p_starts_on IS NULL OR p_starts_on NOT BETWEEN warehouse_security.rate_start_floor() AND warehouse_security.business_date(now()) + 730 THEN
    RETURN warehouse_security.rate_failure('INVALID_DATE',
      'The start date must be on or after ' || warehouse_security.rate_start_floor()::text || ' and within two years after today',
      jsonb_build_object('earliest', warehouse_security.rate_start_floor()));
  END IF;
  IF p_starts_on <= warehouse_security.business_date(now()) AND v_role = 'staff' THEN
    RETURN warehouse_security.rate_failure('PAST_DATE_NOT_ALLOWED', 'Only administrators and supervisors can undo a change that has already begun');
  END IF;
  IF p_item_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.items WHERE id = p_item_id AND active) THEN
    RETURN warehouse_security.rate_failure('ITEM_NOT_FOUND', 'Item not found or inactive');
  END IF;
  IF p_customer_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.customers WHERE id = p_customer_id AND active AND deleted_at IS NULL) THEN
    RETURN warehouse_security.rate_failure('CUSTOMER_NOT_FOUND', 'Customer not found or inactive');
  END IF;

  -- The same lock as replace_item_rates: one change of this scope at a time.
  PERFORM pg_advisory_xact_lock(hashtextextended('item_rates:' || p_item_id || ':' || COALESCE(p_customer_id::text, 'default') || ':' || p_price_type, 0));
  PERFORM 1 FROM public.item_storage_prices r
   WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type FOR UPDATE;

  -- A stale editor, as in replace_item_rates: p_seen_rows lists the row ids the editor loaded for this
  -- scope. A row this call would delete or open again (it starts on p_starts_on, or ended the day before),
  -- or one that decides where the reopened rate ends (a later start), that is not in the list was added or
  -- changed by someone else since, so nothing is written (STALE_RATES; data.ids is the unlisted ids, sorted).
  -- NULL skips the check.
  IF p_seen_rows IS NOT NULL THEN
    SELECT array_agg(r.id ORDER BY r.id) INTO v_unseen FROM public.item_storage_prices r
     WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type
       AND r.id <> ALL (p_seen_rows)
       AND (r.effective_from >= p_starts_on OR r.effective_to IS NULL OR r.effective_to >= p_starts_on - 1);
    IF v_unseen IS NOT NULL THEN
      RETURN warehouse_security.rate_failure('STALE_RATES', 'The rates were changed by someone else; reload and try again',
        jsonb_build_object('ids', to_jsonb(v_unseen)));
    END IF;
  END IF;

  -- The writes sit in a block of their own, so an overlap undoes them all.
  BEGIN
    WITH gone AS (
      DELETE FROM public.item_storage_prices r
       WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type
         AND r.effective_from = p_starts_on
      RETURNING r.id, r.effective_from, r.effective_to)
    -- v_stop: the scheduled stop the removed rate carried (all its rows end on one day), if any.
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', gone.id, 'effective_from', gone.effective_from) ORDER BY gone.id), '[]'::jsonb),
           CASE WHEN count(*) > 0 AND count(*) FILTER (WHERE gone.effective_to IS NULL) = 0 AND count(DISTINCT gone.effective_to) = 1
                THEN max(gone.effective_to) END
      INTO v_removed, v_stop FROM gone;

    SELECT min(r.effective_from) INTO v_next FROM public.item_storage_prices r
     WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type
       AND r.effective_from >= p_starts_on;

    WITH opened AS (
      UPDATE public.item_storage_prices r SET effective_to = COALESCE(v_next - 1, v_stop)
       WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type
         AND r.effective_to = p_starts_on - 1
      RETURNING r.id, r.effective_from, r.effective_to)
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', opened.id, 'effective_from', opened.effective_from, 'effective_to', opened.effective_to)
             ORDER BY opened.effective_from, opened.id), '[]'::jsonb) INTO v_reopened FROM opened;

    IF jsonb_array_length(v_removed) = 0 AND jsonb_array_length(v_reopened) = 0 THEN
      RETURN warehouse_security.rate_failure('NOTHING_TO_UNDO', 'There is no change starting on that day to undo');
    END IF;

    FOR v_row IN SELECT r.id, r.weight_min, r.weight_max, r.effective_from, r.effective_to FROM public.item_storage_prices r
        WHERE r.id IN (SELECT (e->>'id')::uuid FROM jsonb_array_elements(v_reopened) e) LOOP
      IF warehouse_security.price_rows_overlap(p_item_id, p_customer_id, p_price_type,
           v_row.weight_min, v_row.weight_max, v_row.effective_from, v_row.effective_to, v_row.id) THEN
        RAISE EXCEPTION 'rate rows overlap' USING ERRCODE = 'P0001', DETAIL = 'undo_rate_change';
      END IF;
    END LOOP;
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM = 'rate rows overlap' THEN
      RETURN warehouse_security.rate_failure('BANDS_OVERLAP', 'Undoing would make rates overlap');
    END IF;
    RAISE;
  END;

  RETURN jsonb_build_object('success', true, 'message', 'Change undone', 'data', jsonb_build_object(
    'item_id', p_item_id, 'customer_id', p_customer_id, 'price_type', p_price_type, 'starts_on', p_starts_on,
    'removed', v_removed, 'reopened', v_reopened));
END;
$$;

ALTER FUNCTION public.undo_rate_change(p_item_id uuid, p_customer_id uuid, p_price_type text, p_starts_on date, p_seen_rows uuid[]) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.undo_rate_change(p_item_id uuid, p_customer_id uuid, p_price_type text, p_starts_on date, p_seen_rows uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.undo_rate_change(p_item_id uuid, p_customer_id uuid, p_price_type text, p_starts_on date, p_seen_rows uuid[]) FROM anon;
GRANT ALL ON FUNCTION public.undo_rate_change(p_item_id uuid, p_customer_id uuid, p_price_type text, p_starts_on date, p_seen_rows uuid[]) TO service_role;
GRANT ALL ON FUNCTION public.undo_rate_change(p_item_id uuid, p_customer_id uuid, p_price_type text, p_starts_on date, p_seen_rows uuid[]) TO authenticated;
