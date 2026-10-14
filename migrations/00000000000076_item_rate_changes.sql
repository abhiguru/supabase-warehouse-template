-- Migration 76: item rate changes (Settings UX batch, 2026-10-14).
--
-- 1. public.replace_item_rates: one call changes an item's default or customer rate "from a
--    date". It ends the rows in force the day before, drops rows that start on that day (this
--    is how "correct" and "edit the new rate" work), refuses to drop a later planned rate
--    unless told to, and adds the new weight bands, all in one transaction.
-- 2. A one-day rate is valid (dates_valid becomes effective_from <= effective_to).
-- 3. create_item_storage_price and update_item_storage_price refuse overlapping rows of the
--    same item, customer, price type, weight and dates (BANDS_OVERLAP), store labour 0 for a
--    one-time rate, and refuse staff a rate that is already in force. delete_item_storage_price
--    and the old nine-argument update overload refuse staff the same way
--    (RATE_IN_FORCE_MANAGER_ONLY).
-- 4. search_customers matches every typed word anywhere in the name.
-- 5. get_item_storage_prices orders by id last, so paging never skips or repeats a row.
-- 6. The guard admits replace_item_rates and undo_rate_change for staff.
-- 7. public.undo_rate_change: undoes a change that starts on a given day in one step (the
--    rows starting that day go, the rows it had ended are opened again).
-- 8. replace_item_rates has a mode: 'change' keeps a scheduled stop and can move a planned rate
--    (p_move_from); 'correct' replaces only the rows that start on the day and never touches
--    later rows. Staff cannot replace a rate that began today.
-- 9. get_item_storage_prices' include_expired=false test uses the India day.
-- 10. find_or_create_item_storage_price is administrators and supervisors only (staff are
--    refused in the body and the guard), refuses overlapping rows, stores labour 0 for a
--    one-time rate and uses the India day.
--
-- Errors of the new function follow migration 74: {success:false, error, error_code, data}.

-- Replaces one marker in a function body, failing unless it occurs exactly
-- `expected` times. Dropped at the end of this migration. Every before-text below
-- is absent from its after-text, so a second direct run fails on the count.
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
-- 1. A one-day rate is valid
-- ---------------------------------------------------------------------------
ALTER TABLE public.item_storage_prices DROP CONSTRAINT dates_valid;
ALTER TABLE public.item_storage_prices ADD CONSTRAINT dates_valid
  CHECK (effective_to IS NULL OR effective_from <= effective_to);

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
-- True when another row of the same item, customer (NULL = default) and price type shares a
-- weight and a day with the given range. Both ends of weight and dates are inclusive.
CREATE FUNCTION warehouse_security.price_rows_overlap(
  p_item_id uuid, p_customer_id uuid, p_price_type text,
  p_weight_min integer, p_weight_max integer, p_from date, p_to date, p_exclude_id uuid DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE SET search_path = pg_catalog, public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.item_storage_prices r
    WHERE r.item_id = p_item_id
      AND r.customer_id IS NOT DISTINCT FROM p_customer_id
      AND r.price_type = p_price_type
      AND r.id IS DISTINCT FROM p_exclude_id
      AND r.weight_min <= p_weight_max AND p_weight_min <= r.weight_max
      AND r.effective_from <= COALESCE(p_to, 'infinity'::date)
      AND p_from <= COALESCE(r.effective_to, 'infinity'::date));
$$;
REVOKE ALL ON FUNCTION warehouse_security.price_rows_overlap(uuid,uuid,text,integer,integer,date,date,uuid) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION warehouse_security.rate_failure(p_code text, p_error text, p_data jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT jsonb_build_object('success', false, 'error', p_error, 'error_code', p_code, 'data', COALESCE(p_data, '{}'::jsonb));
$$;
REVOKE ALL ON FUNCTION warehouse_security.rate_failure(text,text,jsonb) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The existing writers
-- ---------------------------------------------------------------------------
DO $patch$ BEGIN
  -- create_item_storage_price (price type overload)
  PERFORM pg_temp.patch_rpc('public.create_item_storage_price(uuid,text,numeric,numeric,numeric,numeric,date,uuid,numeric,date)',
  $m$p_effective_to <= p_effective_from$m$, $r$p_effective_to < p_effective_from$r$);
  PERFORM pg_temp.patch_rpc('public.create_item_storage_price(uuid,text,numeric,numeric,numeric,numeric,date,uuid,numeric,date)',
  $m$'effective_to must be > effective_from'$m$, $r$'effective_to must not be before effective_from'$r$);
  PERFORM pg_temp.patch_rpc('public.create_item_storage_price(uuid,text,numeric,numeric,numeric,numeric,date,uuid,numeric,date)',
  $m$    -- Validate price_type
$m$, $r$    -- A rate that is already in force is changed by administrators and supervisors (migration 76).
    IF v_user_role = 'staff' AND p_effective_from < warehouse_security.business_date(now()) THEN
        RETURN warehouse_security.rate_failure('RATE_IN_FORCE_MANAGER_ONLY',
          'Only administrators and supervisors can change a rate that is already in force');
    END IF;

    -- Validate price_type
$r$);
  PERFORM pg_temp.patch_rpc('public.create_item_storage_price(uuid,text,numeric,numeric,numeric,numeric,date,uuid,numeric,date)',
  $m$    -- Insert the new price record
$m$, $r$    -- No other row of this item, customer and price type may share a weight and a day (migration 76).
    IF warehouse_security.price_rows_overlap(p_item_id, p_customer_id, p_price_type,
         p_weight_min::integer, p_weight_max::integer, p_effective_from, p_effective_to) THEN
        RETURN warehouse_security.rate_failure('BANDS_OVERLAP', 'Weight bands overlap');
    END IF;

    -- Insert the new price record
$r$);
  -- A one-time rate carries no labour: invoices never charge it.
  PERFORM pg_temp.patch_rpc('public.create_item_storage_price(uuid,text,numeric,numeric,numeric,numeric,date,uuid,numeric,date)',
  $m$        p_weight_min, p_weight_max, p_labour_rate, p_tax_percent,
$m$, $r$        p_weight_min, p_weight_max, CASE WHEN p_price_type = 'one_time' THEN 0 ELSE p_labour_rate END, p_tax_percent,
$r$);

  -- update_item_storage_price (price type overload)
  PERFORM pg_temp.patch_rpc('public.update_item_storage_price(uuid,numeric,numeric,numeric,numeric,numeric,date,date)',
  $m$p_effective_to <= p_effective_from$m$, $r$p_effective_to < p_effective_from$r$);
  PERFORM pg_temp.patch_rpc('public.update_item_storage_price(uuid,numeric,numeric,numeric,numeric,numeric,date,date)',
  $m$'effective_to must be > effective_from'$m$, $r$'effective_to must not be before effective_from'$r$);
  PERFORM pg_temp.patch_rpc('public.update_item_storage_price(uuid,numeric,numeric,numeric,numeric,numeric,date,date)',
  $m$SELECT id, price_type INTO v_existing FROM item_storage_prices WHERE id = p_id;$m$,
  $r$SELECT id, price_type, item_id, customer_id, effective_from INTO v_existing FROM item_storage_prices WHERE id = p_id;$r$);
  PERFORM pg_temp.patch_rpc('public.update_item_storage_price(uuid,numeric,numeric,numeric,numeric,numeric,date,date)',
  $m$    -- Validate weight range
$m$, $r$    -- A rate that is already in force is changed by administrators and supervisors (migration 76).
    IF v_user_role = 'staff' AND (v_existing.effective_from <= warehouse_security.business_date(now()) OR p_effective_from < warehouse_security.business_date(now())) THEN
        RETURN warehouse_security.rate_failure('RATE_IN_FORCE_MANAGER_ONLY',
          'Only administrators and supervisors can change a rate that is already in force');
    END IF;

    -- Validate weight range
$r$);
  PERFORM pg_temp.patch_rpc('public.update_item_storage_price(uuid,numeric,numeric,numeric,numeric,numeric,date,date)',
  $m$    -- Update the record (price_type, item_id, customer_id cannot be changed)
$m$, $r$    -- No other row of this item, customer and price type may share a weight and a day (migration 76).
    IF warehouse_security.price_rows_overlap(v_existing.item_id, v_existing.customer_id, v_existing.price_type,
         p_weight_min::integer, p_weight_max::integer, p_effective_from, p_effective_to, p_id) THEN
        RETURN warehouse_security.rate_failure('BANDS_OVERLAP', 'Weight bands overlap');
    END IF;

    -- Update the record (price_type, item_id, customer_id cannot be changed)
$r$);
  PERFORM pg_temp.patch_rpc('public.update_item_storage_price(uuid,numeric,numeric,numeric,numeric,numeric,date,date)',
  $m$        labour_rate = p_labour_rate,
$m$, $r$        labour_rate = CASE WHEN v_existing.price_type = 'one_time' THEN 0 ELSE p_labour_rate END,
$r$);

  -- The old nine-argument update overload is still granted: same rule for staff.
  PERFORM pg_temp.patch_rpc('public.update_item_storage_price(uuid,numeric,numeric,numeric,numeric,numeric,numeric,date,date)',
  $m$    -- Validation 1: weight_max >= weight_min
$m$, $r$    -- A rate that is already in force is changed by administrators and supervisors (migration 76).
    IF v_user_role = 'staff' AND (v_existing.effective_from <= warehouse_security.business_date(now()) OR p_effective_from < warehouse_security.business_date(now())) THEN
        RETURN warehouse_security.rate_failure('RATE_IN_FORCE_MANAGER_ONLY',
          'Only administrators and supervisors can change a rate that is already in force');
    END IF;

    -- Validation 1: weight_max >= weight_min
$r$);

  -- delete_item_storage_price
  PERFORM pg_temp.patch_rpc('public.delete_item_storage_price(uuid)',
  $m$SELECT isp.id, i.name as item_name, c.name as customer_name$m$,
  $r$SELECT isp.id, isp.effective_from, i.name as item_name, c.name as customer_name$r$);
  PERFORM pg_temp.patch_rpc('public.delete_item_storage_price(uuid)',
  $m$    -- Delete the record
$m$, $r$    -- A rate that is already in force is removed by administrators and supervisors (migration 76).
    IF v_user_role = 'staff' AND v_existing.effective_from <= warehouse_security.business_date(now()) THEN
        RETURN warehouse_security.rate_failure('RATE_IN_FORCE_MANAGER_ONLY',
          'Only administrators and supervisors can change a rate that is already in force');
    END IF;

    -- Delete the record
$r$);

  -- The list: a final tie-breaker so paging is stable.
  PERFORM pg_temp.patch_rpc('public.get_item_storage_prices(jsonb,text,text,integer,integer)',
  $m$    -- Get total count
$m$, $r$    -- Last tie-breaker, so paging never skips or repeats a row (migration 76).
    v_order_by := v_order_by || ', isp.id ASC';

    -- Get total count
$r$);
  -- Rows that ended before the India day are expired (the filter used the server's UTC day).
  PERFORM pg_temp.patch_rpc('public.get_item_storage_prices(jsonb,text,text,integer,integer)',
  $m$(isp.effective_to IS NULL OR isp.effective_to >= CURRENT_DATE)$m$,
  $r$(isp.effective_to IS NULL OR isp.effective_to >= warehouse_security.business_date(now()))$r$);

  -- find_or_create_item_storage_price: the app no longer calls it. It is for administrators and
  -- supervisors only now (staff are refused here and in the guard), it uses the India day, stores
  -- labour 0 for a one-time rate, and refuses a row that would overlap another of the scope.
  PERFORM pg_temp.patch_rpc('public.find_or_create_item_storage_price(uuid,uuid,numeric,text,numeric,numeric,numeric,numeric,numeric)',
  $m$v_user_role NOT IN ('admin', 'supervisor', 'staff')$m$, $r$v_user_role NOT IN ('admin', 'supervisor')$r$);
  PERFORM pg_temp.patch_rpc('public.find_or_create_item_storage_price(uuid,uuid,numeric,text,numeric,numeric,numeric,numeric,numeric)',
  $m$        COALESCE(p_default_labour_rate, 0),
        COALESCE(p_default_tax_percent, 18),
        CURRENT_DATE,$m$,
  $r$        CASE WHEN lower(p_price_type) = 'one_time' THEN 0 ELSE COALESCE(p_default_labour_rate, 0) END,
        COALESCE(p_default_tax_percent, 18),
        CURRENT_DATE,$r$);
  PERFORM pg_temp.patch_rpc('public.find_or_create_item_storage_price(uuid,uuid,numeric,text,numeric,numeric,numeric,numeric,numeric)',
  $m$            'labour_rate', COALESCE(p_default_labour_rate, 0),$m$,
  $r$            'labour_rate', CASE WHEN lower(p_price_type) = 'one_time' THEN 0 ELSE COALESCE(p_default_labour_rate, 0) END,$r$);
  PERFORM pg_temp.patch_rpc('public.find_or_create_item_storage_price(uuid,uuid,numeric,text,numeric,numeric,numeric,numeric,numeric)',
  $m$    INSERT INTO item_storage_prices ($m$,
  $r$    IF warehouse_security.price_rows_overlap(p_item_id, p_customer_id, lower(p_price_type),
         COALESCE(p_default_weight_min, 0)::integer, v_weight_max_value, warehouse_security.business_date(now()), NULL) THEN
        RETURN jsonb_build_object('success', false, 'data', NULL, 'message', 'Weight bands overlap', 'error_code', 'BANDS_OVERLAP');
    END IF;

    INSERT INTO item_storage_prices ($r$);
  PERFORM pg_temp.patch_rpc('public.find_or_create_item_storage_price(uuid,uuid,numeric,text,numeric,numeric,numeric,numeric,numeric)',
  $m$CURRENT_DATE$m$, $r$warehouse_security.business_date(now())$r$, 4);
END $patch$;

-- ---------------------------------------------------------------------------
-- 4. search_customers: every typed word anywhere in the name
-- ---------------------------------------------------------------------------
-- Same arguments and answer as before. A customer matches when every word of the typed text
-- occurs somewhere in the name, or when the mobile number starts with the typed text. Names
-- that start with the typed text (and mobile matches) come first, then the rest by name.
CREATE OR REPLACE FUNCTION public.search_customers(p_search_query text, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
DECLARE
    v_result jsonb;
    v_query text := btrim(COALESCE(p_search_query, ''));
    v_prefix text := replace(replace(replace(btrim(COALESCE(p_search_query, '')), '\', '\\'), '%', '\%'), '_', '\_');
BEGIN
  PERFORM warehouse_security.authorize_rpc('search_customers',jsonb_build_object());
    SELECT COALESCE(
        jsonb_agg(sub.customer_row ORDER BY sub.rank, sub.name, sub.id),
        '[]'::jsonb
    ) INTO v_result
    FROM (
        SELECT jsonb_build_object(
            'id', c.id,
            'name', c.name,
            'mobile', c.mobile,
            'city', c.city,
            'email', c.email,
            'address', c.address
        ) as customer_row,
        c.name, c.id,
        CASE WHEN v_query = '' OR c.name ILIKE v_prefix || '%' OR c.mobile ILIKE v_prefix || '%' THEN 0 ELSE 1 END AS rank
        FROM customers c
        WHERE c.active = true
          AND c.deleted_at IS NULL
          AND c.id = ANY(user_accessible_customers())
          AND (
              v_query = ''
              OR c.mobile ILIKE v_prefix || '%'
              OR NOT EXISTS (
                  SELECT 1 FROM regexp_split_to_table(v_query, '\s+') AS w(word)
                  WHERE c.name NOT ILIKE '%' || replace(replace(replace(w.word, '\', '\\'), '%', '\%'), '_', '\_') || '%'
              )
          )
        ORDER BY rank, c.name, c.id
        LIMIT p_limit
    ) sub;

    RETURN utils.success_response(v_result);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5. replace_item_rates
-- ---------------------------------------------------------------------------
-- p_mode 'change' (default): the new bands start on p_starts_on; rows in force that day end the
--   day before, rows that start on it (and, with p_replace_later, later rows) go. A scheduled
--   stop (every row in force on that day ends on the same day E, nothing starts later) is
--   kept: the new rows end on E and data.kept_end says so.
-- p_mode 'correct': p_starts_on must be the start of the rows in force that day
--   (NOT_A_RATE_START otherwise). Exactly those rows are replaced; they keep their last day;
--   later rows are never touched and p_replace_later is ignored.
-- p_move_from (only with 'change'): first undoes the change that starts on that day (as
--   undo_rate_change does), then applies the change from p_starts_on, in one transaction.
-- p_seen_rows (optional): the ids of the rows the editor loaded; a row this call touches that is
--   not listed makes the call answer STALE_RATES and write nothing.
-- All writes run in a sub-transaction: a refusal after the first write undoes them all.
CREATE FUNCTION public.replace_item_rates(
  p_item_id       uuid,
  p_customer_id   uuid,
  p_price_type    text,
  p_starts_on     date,
  p_bands         jsonb,
  p_replace_later boolean DEFAULT false,
  p_mode          text DEFAULT 'change',
  p_move_from     date DEFAULT NULL,
  p_seen_rows     uuid[] DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, utils, pg_temp
AS $function$
DECLARE
  v_role text; v_profile uuid; v_today date := warehouse_security.business_date(now());
  v_band jsonb; v_ord integer; v_field text; v_n numeric; v_limit numeric;
  v_prev_max integer; v_expected integer; v_min integer; v_max integer;
  v_later jsonb; v_removed jsonb := '[]'::jsonb; v_ended jsonb := '[]'::jsonb; v_added jsonb := '[]'::jsonb;
  v_reopened jsonb := '[]'::jsonb; v_moved integer; v_next date; v_row record;
  v_n_force integer; v_n_notstart integer; v_n_ends integer; v_n_open integer; v_end date;
  v_kept date; v_detail text; v_stop date; v_planned jsonb; v_unseen uuid[]; v_from date;
  v_new public.item_storage_prices;
BEGIN
  PERFORM warehouse_security.authorize_rpc('replace_item_rates', jsonb_build_object('p_customer_id', p_customer_id));
  SELECT up.id, up.role::text INTO v_profile, v_role FROM public.user_profiles up WHERE up.auth_user_id = auth.uid() AND up.active;

  IF p_price_type IS NULL OR p_price_type NOT IN ('monthly','one_time') THEN
    RETURN warehouse_security.rate_failure('INVALID_PRICE_TYPE', 'Price type must be monthly or one_time');
  END IF;
  IF p_mode IS NULL OR p_mode NOT IN ('change','correct') THEN
    RETURN warehouse_security.rate_failure('INVALID_MODE', 'The mode must be change or correct');
  END IF;
  IF p_move_from IS NOT NULL AND p_mode <> 'change' THEN
    RETURN warehouse_security.rate_failure('INVALID_MODE', 'A rate can be moved only in change mode');
  END IF;
  IF p_starts_on IS NULL OR p_starts_on NOT BETWEEN v_today - 1095 AND v_today + 730 THEN
    RETURN warehouse_security.rate_failure('INVALID_DATE', 'The start date must be within three years before today and two years after');
  END IF;
  IF p_move_from IS NOT NULL AND p_move_from NOT BETWEEN v_today - 1095 AND v_today + 730 THEN
    RETURN warehouse_security.rate_failure('INVALID_DATE', 'The start date must be within three years before today and two years after');
  END IF;
  IF p_starts_on < v_today AND v_role = 'staff' THEN
    RETURN warehouse_security.rate_failure('PAST_DATE_NOT_ALLOWED', 'Only administrators and supervisors can start a rate in the past');
  END IF;
  IF p_move_from IS NOT NULL AND v_role = 'staff' AND (p_move_from <= v_today OR p_starts_on <= v_today) THEN
    RETURN warehouse_security.rate_failure('PAST_DATE_NOT_ALLOWED', 'Only administrators and supervisors can move a rate that has begun or move it to today');
  END IF;
  IF p_item_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.items WHERE id = p_item_id AND active) THEN
    RETURN warehouse_security.rate_failure('ITEM_NOT_FOUND', 'Item not found or inactive');
  END IF;
  IF p_customer_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.customers WHERE id = p_customer_id AND active AND deleted_at IS NULL) THEN
    RETURN warehouse_security.rate_failure('CUSTOMER_NOT_FOUND', 'Customer not found or inactive');
  END IF;

  -- The bands.
  IF p_bands IS NULL OR jsonb_typeof(p_bands) <> 'array' OR jsonb_array_length(p_bands) > 10 THEN
    RETURN warehouse_security.rate_failure('INVALID_BANDS', 'Bands must be a list of at most 10 bands');
  END IF;
  IF p_mode = 'correct' AND jsonb_array_length(p_bands) = 0 THEN
    RETURN warehouse_security.rate_failure('INVALID_BANDS', 'A correction needs at least one band');
  END IF;
  FOR v_band, v_ord IN SELECT e.value, (e.ord - 1)::integer FROM jsonb_array_elements(p_bands) WITH ORDINALITY e(value, ord) ORDER BY e.ord LOOP
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
    -- Labour of a one-time rate is not used (invoices never charge it): not checked.
    FOREACH v_field IN ARRAY CASE WHEN p_price_type = 'one_time' THEN ARRAY['unit_price','tax_percent'] ELSE ARRAY['unit_price','labour_rate','tax_percent'] END LOOP
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
  -- Sorted by start: no overlap; the default rate also starts at 0 and has no gap.
  v_prev_max := NULL; v_expected := 0;
  FOR v_band, v_ord IN SELECT e.value, (e.ord - 1)::integer FROM jsonb_array_elements(p_bands) WITH ORDINALITY e(value, ord)
      ORDER BY (e.value->>'weight_min')::numeric, e.ord LOOP
    v_min := (v_band->>'weight_min')::integer; v_max := (v_band->>'weight_max')::integer;
    IF v_prev_max IS NOT NULL AND v_min <= v_prev_max THEN
      RETURN warehouse_security.rate_failure('BANDS_OVERLAP', 'Weight bands overlap', jsonb_build_object('index', v_ord));
    END IF;
    IF p_customer_id IS NULL AND v_min <> v_expected THEN
      RETURN warehouse_security.rate_failure('BANDS_GAP', 'The default rate''s bands must start at 0 kg and follow on without gaps',
        jsonb_build_object('index', v_ord, 'expected_min', v_expected));
    END IF;
    v_prev_max := v_max; v_expected := v_max + 1;
  END LOOP;

  -- One change of this scope at a time.
  PERFORM pg_advisory_xact_lock(hashtextextended('item_rates:' || p_item_id || ':' || COALESCE(p_customer_id::text, 'default') || ':' || p_price_type, 0));
  PERFORM 1 FROM public.item_storage_prices r
   WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type FOR UPDATE;

  -- A rate that began today (or earlier) is changed by administrators and supervisors only,
  -- as delete_ and update_item_storage_price already require.
  IF v_role = 'staff' AND p_starts_on <= v_today AND EXISTS (
       SELECT 1 FROM public.item_storage_prices r
        WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type
          AND r.effective_from = p_starts_on) THEN
    RETURN warehouse_security.rate_failure('RATE_IN_FORCE_MANAGER_ONLY', 'Only administrators and supervisors can change a rate that is already in force');
  END IF;

  -- A stale editor: p_seen_rows lists the row ids the editor loaded for this scope. A row this
  -- call would end, move or delete that is not in the list was added or changed by someone else
  -- since, so nothing is written (STALE_RATES; data.ids is the current set). NULL skips the check.
  IF p_seen_rows IS NOT NULL THEN
    v_from := LEAST(p_starts_on, COALESCE(p_move_from, p_starts_on));
    SELECT array_agg(r.id ORDER BY r.id) INTO v_unseen FROM public.item_storage_prices r
     WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type
       AND r.id <> ALL (p_seen_rows)
       AND CASE WHEN p_mode = 'correct' THEN r.effective_from = p_starts_on
                ELSE r.effective_from >= v_from OR r.effective_to IS NULL OR r.effective_to >= v_from END;
    IF v_unseen IS NOT NULL THEN
      RETURN warehouse_security.rate_failure('STALE_RATES', 'The rates were changed by someone else; reload and try again',
        jsonb_build_object('ids', to_jsonb(v_unseen)));
    END IF;
  END IF;

  -- The writes sit in a block of their own, so a refusal after the first write undoes them all.
  BEGIN
    -- Move: undo the change that starts on p_move_from (as undo_rate_change does).
    IF p_move_from IS NOT NULL THEN
      WITH gone AS (
        DELETE FROM public.item_storage_prices r
         WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type
           AND r.effective_from = p_move_from
        RETURNING r.id, r.effective_to)
      -- v_stop: the scheduled stop the planned rate carried (all its rows end on one day), if any.
      SELECT count(*),
             CASE WHEN count(*) FILTER (WHERE gone.effective_to IS NULL) = 0 AND count(DISTINCT gone.effective_to) = 1
                  THEN max(gone.effective_to) END
        INTO v_moved, v_stop FROM gone;
      IF v_moved = 0 THEN
        RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001',
          DETAIL = warehouse_security.rate_failure('NOTHING_TO_MOVE', 'There is no rate starting on that day to move')::text;
      END IF;
      SELECT min(r.effective_from) INTO v_next FROM public.item_storage_prices r
       WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type
         AND r.effective_from >= p_move_from;
      WITH opened AS (
        UPDATE public.item_storage_prices r SET effective_to = COALESCE(v_next - 1, v_stop)
         WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type
           AND r.effective_to = p_move_from - 1
        RETURNING r.id, r.effective_from, r.effective_to)
      SELECT COALESCE(jsonb_agg(jsonb_build_object('id', opened.id, 'effective_from', opened.effective_from, 'effective_to', opened.effective_to)
               ORDER BY opened.effective_from, opened.id), '[]'::jsonb) INTO v_reopened FROM opened;
    END IF;

    -- The rows in force on the start day: how many, how many start elsewhere, their last days.
    SELECT count(*), count(*) FILTER (WHERE r.effective_from <> p_starts_on),
           count(DISTINCT COALESCE(r.effective_to, 'infinity'::date)), max(r.effective_to), count(*) FILTER (WHERE r.effective_to IS NULL)
      INTO v_n_force, v_n_notstart, v_n_ends, v_end, v_n_open
      FROM public.item_storage_prices r
     WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type
       AND r.effective_from <= p_starts_on AND (r.effective_to IS NULL OR r.effective_to >= p_starts_on);

    IF p_mode = 'correct' THEN
      IF v_n_force = 0 OR v_n_notstart > 0 THEN
        RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001',
          DETAIL = warehouse_security.rate_failure('NOT_A_RATE_START', 'A correction must use the day the rate in force began')::text;
      END IF;
      v_kept := CASE WHEN v_n_ends = 1 AND v_n_open = 0 THEN v_end ELSE NULL END;
      WITH gone AS (
        DELETE FROM public.item_storage_prices r
         WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type
           AND r.effective_from = p_starts_on
        RETURNING r.id, r.effective_from)
      SELECT COALESCE(jsonb_agg(jsonb_build_object('id', gone.id, 'effective_from', gone.effective_from) ORDER BY gone.effective_from, gone.id), '[]'::jsonb)
        INTO v_removed FROM gone;
    ELSE
      -- Rates planned after the start day.
      SELECT jsonb_agg(jsonb_build_object('effective_from', r.effective_from, 'weight_min', r.weight_min, 'weight_max', r.weight_max, 'unit_price', r.unit_price)
               ORDER BY r.effective_from, r.weight_min) INTO v_later
        FROM public.item_storage_prices r
       WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type AND r.effective_from > p_starts_on;
      -- A rate planned (not begun) to start ON the start day is a later rate too: without
      -- p_replace_later it is refused, not silently deleted, unless new bands replace a planned
      -- rate that the editor listed in p_seen_rows. A rate in force from today or
      -- earlier on that day is the one being changed. (p_move_from has already removed the
      -- planned rate being moved.)
      IF NOT COALESCE(p_replace_later, false) THEN
        SELECT jsonb_agg(jsonb_build_object('effective_from', r.effective_from, 'weight_min', r.weight_min, 'weight_max', r.weight_max, 'unit_price', r.unit_price)
                 ORDER BY r.effective_from, r.weight_min) INTO v_planned
          FROM public.item_storage_prices r
         WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type
           AND r.effective_from >= p_starts_on AND r.effective_from > v_today
           -- Replacing the planned rate that starts on the day is allowed with new bands when the
           -- editor listed that rate in p_seen_rows; a stop never replaces it silently.
           AND NOT (r.effective_from = p_starts_on AND jsonb_array_length(p_bands) > 0
                    AND p_seen_rows IS NOT NULL AND r.id = ANY (p_seen_rows));
        IF v_planned IS NOT NULL THEN
          RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001',
            DETAIL = warehouse_security.rate_failure('LATER_RATES_EXIST', 'A later rate is already planned', jsonb_build_object('later', v_planned))::text;
        END IF;
      END IF;
      -- A scheduled stop is kept when nothing starts later.
      v_kept := CASE WHEN v_later IS NULL AND v_n_force > 0 AND v_n_ends = 1 AND v_n_open = 0 THEN v_end ELSE NULL END;
      -- Later rows and rows that start on the start day go.
      WITH gone AS (
        DELETE FROM public.item_storage_prices r
         WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type
           AND r.effective_from >= p_starts_on
        RETURNING r.id, r.effective_from)
      SELECT COALESCE(jsonb_agg(jsonb_build_object('id', gone.id, 'effective_from', gone.effective_from) ORDER BY gone.effective_from, gone.id), '[]'::jsonb)
        INTO v_removed FROM gone;
      -- Rows in force on the start day end the day before.
      WITH ended AS (
        UPDATE public.item_storage_prices r SET effective_to = p_starts_on - 1
         WHERE r.item_id = p_item_id AND r.customer_id IS NOT DISTINCT FROM p_customer_id AND r.price_type = p_price_type
           AND r.effective_from < p_starts_on AND (r.effective_to IS NULL OR r.effective_to >= p_starts_on)
        RETURNING r.id, r.effective_from, r.effective_to)
      SELECT COALESCE(jsonb_agg(jsonb_build_object('id', ended.id, 'effective_from', ended.effective_from, 'effective_to', ended.effective_to)
               ORDER BY ended.effective_from, ended.id), '[]'::jsonb) INTO v_ended FROM ended;

      IF jsonb_array_length(p_bands) = 0 AND jsonb_array_length(v_removed) = 0 AND jsonb_array_length(v_ended) = 0 THEN
        RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001',
          DETAIL = warehouse_security.rate_failure('NOTHING_TO_STOP', 'There is no rate in force on that day to stop')::text;
      END IF;
    END IF;

    FOR v_band IN SELECT e.value FROM jsonb_array_elements(p_bands) WITH ORDINALITY e(value, ord)
        ORDER BY (e.value->>'weight_min')::numeric, e.ord LOOP
      INSERT INTO public.item_storage_prices (
        item_id, customer_id, price_type, unit_price, weight_min, weight_max, labour_rate, tax_percent,
        effective_from, effective_to, created_by, unit_price_one_time, unit_price_monthly)
      VALUES (
        p_item_id, p_customer_id, p_price_type, (v_band->>'unit_price')::numeric,
        (v_band->>'weight_min')::integer, (v_band->>'weight_max')::integer,
        CASE WHEN p_price_type = 'one_time' THEN 0 ELSE (v_band->>'labour_rate')::numeric END,
        (v_band->>'tax_percent')::numeric, p_starts_on, v_kept, v_profile,
        CASE WHEN p_price_type = 'one_time' THEN (v_band->>'unit_price')::numeric ELSE 0 END,
        CASE WHEN p_price_type = 'monthly' THEN (v_band->>'unit_price')::numeric ELSE 0 END)
      RETURNING * INTO v_new;
      v_added := v_added || jsonb_build_array(jsonb_build_object('id', v_new.id, 'weight_min', v_new.weight_min,
        'weight_max', v_new.weight_max, 'unit_price', v_new.unit_price, 'labour_rate', v_new.labour_rate, 'tax_percent', v_new.tax_percent));
    END LOOP;

    -- Nothing the call added may overlap another row of the scope.
    FOR v_row IN SELECT r.id, r.weight_min, r.weight_max, r.effective_from, r.effective_to FROM public.item_storage_prices r
        WHERE r.id IN (SELECT (e->>'id')::uuid FROM jsonb_array_elements(v_added) e) LOOP
      IF warehouse_security.price_rows_overlap(p_item_id, p_customer_id, p_price_type,
           v_row.weight_min, v_row.weight_max, v_row.effective_from, v_row.effective_to, v_row.id) THEN
        RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001',
          DETAIL = warehouse_security.rate_failure('BANDS_OVERLAP', 'Weight bands overlap')::text;
      END IF;
    END LOOP;
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM = 'rate_fail' THEN
      GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
      RETURN v_detail::jsonb;
    END IF;
    RAISE;
  END;

  RETURN jsonb_build_object('success', true, 'message', 'Rates saved', 'data', jsonb_build_object(
    'item_id', p_item_id, 'customer_id', p_customer_id, 'price_type', p_price_type, 'starts_on', p_starts_on,
    'mode', p_mode, 'move_from', p_move_from, 'kept_end', v_kept,
    'ended', v_ended, 'removed', v_removed, 'reopened', v_reopened, 'added', v_added));
END;
$function$;
REVOKE ALL ON FUNCTION public.replace_item_rates(uuid,uuid,text,date,jsonb,boolean,text,date,uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.replace_item_rates(uuid,uuid,text,date,jsonb,boolean,text,date,uuid[]) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5b. undo_rate_change
-- ---------------------------------------------------------------------------
-- Undoes the change of one scope (item, customer or NULL, price type) that starts on
-- p_starts_on: the rows starting that day are deleted, the rows that ended the day before are
-- opened again (up to the day before the next planned rate, or without an end). Staff only for
-- a change that has not begun; managers also for one that has.
CREATE FUNCTION public.undo_rate_change(
  p_item_id     uuid,
  p_customer_id uuid,
  p_price_type  text,
  p_starts_on   date
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, utils, pg_temp
AS $function$
DECLARE
  v_role text; v_next date; v_stop date;
  v_removed jsonb := '[]'::jsonb; v_reopened jsonb := '[]'::jsonb; v_row record;
BEGIN
  PERFORM warehouse_security.authorize_rpc('undo_rate_change', jsonb_build_object('p_customer_id', p_customer_id));
  SELECT up.role::text INTO v_role FROM public.user_profiles up WHERE up.auth_user_id = auth.uid() AND up.active;

  IF p_price_type IS NULL OR p_price_type NOT IN ('monthly','one_time') THEN
    RETURN warehouse_security.rate_failure('INVALID_PRICE_TYPE', 'Price type must be monthly or one_time');
  END IF;
  IF p_starts_on IS NULL OR p_starts_on NOT BETWEEN warehouse_security.business_date(now()) - 1095 AND warehouse_security.business_date(now()) + 730 THEN
    RETURN warehouse_security.rate_failure('INVALID_DATE', 'The start date must be within three years before today and two years after');
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
$function$;
REVOKE ALL ON FUNCTION public.undo_rate_change(uuid,uuid,text,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.undo_rate_change(uuid,uuid,text,date) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. The guard: staff may call replace_item_rates and undo_rate_change (as the other price writers)
-- ---------------------------------------------------------------------------
DO $patch$ BEGIN
  -- find_or_create_item_storage_price is no longer a staff call (no app code uses it).
  PERFORM pg_temp.patch_rpc('warehouse_security.authorize_rpc(text,jsonb)',
  $m$    'get_item_storage_prices','find_or_create_item_storage_price',
$m$, $r$    'get_item_storage_prices',
$r$);
  PERFORM pg_temp.patch_rpc('warehouse_security.authorize_rpc(text,jsonb)',
  $m$    'create_item_storage_price','update_item_storage_price','delete_item_storage_price',
$m$, $r$    'create_item_storage_price','update_item_storage_price','delete_item_storage_price',
    -- A change "from a date" (migration 76).
    'replace_item_rates',
    'undo_rate_change',
$r$);
END $patch$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
NOTIFY pgrst, 'reload schema';
