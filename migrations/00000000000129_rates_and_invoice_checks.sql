-- Migration 129: rate and invoice checks. The header below is completed as the sections are added; each section says what it does.

-- Section 1: replace_item_rates.
--  * Change mode: a rate that starts after the start day is a later rate whether it has begun or is only planned, so it is refused
--    with LATER_RATES_EXIST unless p_replace_later is true. (Before, only a planned one was; a begun later rate was deleted without a
--    word.) A rate that starts ON the start day stays as before: one already in force is the rate being changed, a planned one is a
--    later rate. Each entry of data.later also says whether it has begun.
--  * p_request_key: a save that carries a key stores its first answer for seven days under the user; a resend of the same change with
--    the same key returns that answer and writes nothing. The key is locked first, so two sends of one key take turns, and the replay
--    is answered before any other check. The old signature is dropped first (PostgREST would see two overloads).
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$p_seen_rows uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
$m$,
    $m$  v_new public.item_storage_prices;
BEGIN
  PERFORM warehouse_security.authorize_rpc('replace_item_rates'$m$,
    $m$SELECT up.id, up.role::text INTO v_profile, v_role FROM public.user_profiles up WHERE up.auth_user_id = auth.uid() AND up.active;

  IF p_price_type IS NULL$m$,
    $m$           AND r.effective_from >= p_starts_on AND r.effective_from > v_today
$m$,
    $m$'unit_price', r.unit_price)
                 ORDER BY r.effective_from, r.weight_min) INTO v_planned$m$,
    $m$  RETURN jsonb_build_object('success', true, 'message', 'Rates saved', 'data', jsonb_build_object($m$,
    $m$'reopened', v_reopened, 'added', v_added));
END;$m$
  ];
  v_new constant text[] := ARRAY[
    $m$p_seen_rows uuid[] DEFAULT NULL::uuid[], p_request_key text DEFAULT NULL::text)
 RETURNS jsonb
$m$,
    $m$  v_new public.item_storage_prices;
  v_key text := NULLIF(btrim(p_request_key), '');
  v_cached jsonb; v_result jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('replace_item_rates'$m$,
    $m$SELECT up.id, up.role::text INTO v_profile, v_role FROM public.user_profiles up WHERE up.auth_user_id = auth.uid() AND up.active;

  -- Migration 129: this user's stored first answer for the same change and key is returned as it was, with no write.
  IF v_key IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('rate_key:' || v_key, 0));
    SELECT k.response INTO v_cached FROM public.idempotency_keys k
     WHERE k.idempotency_key = v_key AND k.rpc_function = 'replace_item_rates' AND k.created_by = v_profile AND k.expires_at > now()
       AND k.response #>> '{data,item_id}' = p_item_id::text
       AND k.response #>> '{data,customer_id}' IS NOT DISTINCT FROM p_customer_id::text
       AND k.response #>> '{data,price_type}' = p_price_type
       AND k.response #>> '{data,starts_on}' = to_char(p_starts_on, 'YYYY-MM-DD');
    IF v_cached IS NOT NULL THEN
      RETURN v_cached;
    END IF;
  END IF;

  IF p_price_type IS NULL$m$,
    $m$           AND (r.effective_from > p_starts_on OR (r.effective_from = p_starts_on AND r.effective_from > v_today))
$m$,
    $m$'unit_price', r.unit_price, 'begun', r.effective_from <= v_today)
                 ORDER BY r.effective_from, r.weight_min) INTO v_planned$m$,
    $m$  v_result := jsonb_build_object('success', true, 'message', 'Rates saved', 'data', jsonb_build_object($m$,
    $m$'reopened', v_reopened, 'added', v_added));

  -- Migration 129: the first answer is kept for the 7 days a resend is answered from it. A key that another function or user holds
  -- is left alone unless it has expired.
  IF v_key IS NOT NULL THEN
    INSERT INTO public.idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
    VALUES (v_key, 'replace_item_rates', v_result, v_profile, now() + interval '7 days')
    ON CONFLICT (idempotency_key) DO UPDATE SET
      rpc_function = EXCLUDED.rpc_function, response = EXCLUDED.response, created_by = EXCLUDED.created_by,
      created_at = now(), expires_at = EXCLUDED.expires_at
    WHERE idempotency_keys.expires_at <= now()
       OR (idempotency_keys.rpc_function = EXCLUDED.rpc_function
           AND idempotency_keys.created_by IS NOT DISTINCT FROM EXCLUDED.created_by);
  END IF;
  RETURN v_result;
END;$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.replace_item_rates(uuid, uuid, text, date, jsonb, boolean, text, date, uuid[])'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'replace_item_rates: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  DROP FUNCTION public.replace_item_rates(uuid, uuid, text, date, jsonb, boolean, text, date, uuid[]);
  EXECUTE v_def;
END
$patch$;

ALTER FUNCTION public.replace_item_rates(uuid, uuid, text, date, jsonb, boolean, text, date, uuid[], text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.replace_item_rates(uuid, uuid, text, date, jsonb, boolean, text, date, uuid[], text) FROM PUBLIC, anon, authenticated;
GRANT ALL ON FUNCTION public.replace_item_rates(uuid, uuid, text, date, jsonb, boolean, text, date, uuid[], text) TO service_role;
GRANT ALL ON FUNCTION public.replace_item_rates(uuid, uuid, text, date, jsonb, boolean, text, date, uuid[], text) TO authenticated;

-- Section 2: set_standard_rate takes p_request_key, the same way (not for a dry run, which writes nothing). The replay is answered
-- before the stale check, which the first save itself would fail now.
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$p_dry_run boolean DEFAULT false)
 RETURNS jsonb
$m$,
    $m$  v_item record; v_priced integer := 0; v_tiers jsonb; v_current timestamptz; v_updated timestamptz;
BEGIN
$m$,
    $m$  v_failure := warehouse_security.standard_rate_failure(p_tiers);
$m$,
    $m$  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'tiers', v_tiers, 'items_priced', v_priced, 'dry_run', false, 'updated_at', v_updated));
END;$m$
  ];
  v_new constant text[] := ARRAY[
    $m$p_dry_run boolean DEFAULT false, p_request_key text DEFAULT NULL::text)
 RETURNS jsonb
$m$,
    $m$  v_item record; v_priced integer := 0; v_tiers jsonb; v_current timestamptz; v_updated timestamptz;
  v_key text := NULLIF(btrim(p_request_key), '');
  v_cached jsonb; v_result jsonb;
BEGIN
$m$,
    $m$  -- Migration 129: this user's stored first answer for the key is returned as it was, with no write.
  IF v_key IS NOT NULL AND NOT COALESCE(p_dry_run, false) THEN
    PERFORM pg_advisory_xact_lock(hashtextextended('rate_key:' || v_key, 0));
    SELECT k.response INTO v_cached FROM public.idempotency_keys k
     WHERE k.idempotency_key = v_key AND k.rpc_function = 'set_standard_rate' AND k.created_by = v_profile AND k.expires_at > now();
    IF v_cached IS NOT NULL THEN
      RETURN v_cached;
    END IF;
  END IF;
  v_failure := warehouse_security.standard_rate_failure(p_tiers);
$m$,
    $m$  v_result := jsonb_build_object('success', true, 'data', jsonb_build_object(
    'tiers', v_tiers, 'items_priced', v_priced, 'dry_run', false, 'updated_at', v_updated));
  IF v_key IS NOT NULL THEN
    INSERT INTO public.idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
    VALUES (v_key, 'set_standard_rate', v_result, v_profile, now() + interval '7 days')
    ON CONFLICT (idempotency_key) DO UPDATE SET
      rpc_function = EXCLUDED.rpc_function, response = EXCLUDED.response, created_by = EXCLUDED.created_by,
      created_at = now(), expires_at = EXCLUDED.expires_at
    WHERE idempotency_keys.expires_at <= now()
       OR (idempotency_keys.rpc_function = EXCLUDED.rpc_function
           AND idempotency_keys.created_by IS NOT DISTINCT FROM EXCLUDED.created_by);
  END IF;
  RETURN v_result;
END;$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.set_standard_rate(jsonb, timestamp with time zone, boolean)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'set_standard_rate: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  DROP FUNCTION public.set_standard_rate(jsonb, timestamp with time zone, boolean);
  EXECUTE v_def;
END
$patch$;

ALTER FUNCTION public.set_standard_rate(jsonb, timestamp with time zone, boolean, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.set_standard_rate(jsonb, timestamp with time zone, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT ALL ON FUNCTION public.set_standard_rate(jsonb, timestamp with time zone, boolean, text) TO service_role;
GRANT ALL ON FUNCTION public.set_standard_rate(jsonb, timestamp with time zone, boolean, text) TO authenticated;

-- Section 3: get_submission_result finds the two rate saves (the answer a lost reply would have carried).
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$            ELSE false
          END;$m$
  ];
  v_new constant text[] := ARRAY[
    $m$            WHEN 'replace_item_rates' THEN true
            WHEN 'set_standard_rate' THEN true
            ELSE false
          END;$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.get_submission_result(text)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'get_submission_result: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- Section 4: find_storage_price, the one function that answers "which default rate applies to this item on this day" for the invoice
-- form, the invoice recalculation, get_grn_item_rates and the "every line has a rate" check of the GRN rate sheet (apply_grn_rates):
-- an item's first default rate also covers every earlier day, so a GRN dated before the item was priced is not "missing a rate" and
-- nothing has to be back-filled. Only the default rate (no customer) of the item's first start day is extended, and only to days
-- before it; a customer's own rate never reaches back, a later change starts on its own day. No signature change.
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$      AND isp.effective_from <= p_dispatch_date
      AND (isp.effective_to IS NULL OR p_dispatch_date <= isp.effective_to)
$m$
  ];
  v_new constant text[] := ARRAY[
    $m$      AND (
          (isp.effective_from <= p_dispatch_date
           AND (isp.effective_to IS NULL OR p_dispatch_date <= isp.effective_to))
          -- Migration 129: the item's first default rate (its earliest start day, all its bands) also covers the days before it.
          OR (isp.customer_id IS NULL AND p_dispatch_date < isp.effective_from
              AND isp.effective_from = (SELECT min(f.effective_from) FROM item_storage_prices f
                                         WHERE f.item_id = isp.item_id AND f.price_type = isp.price_type AND f.customer_id IS NULL))
      )
$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.find_storage_price(uuid, uuid, integer, date, text)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'find_storage_price: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
