-- Migration 129: rate saves that cannot be lost or doubled, rates that never drop a begun rate silently, an item's first rate for
-- earlier days, and the invoice date, discount and rate checks.
--
--  * replace_item_rates and set_standard_rate take p_request_key (text, default NULL). A save that carries a key stores its first answer
--    for seven days under the user; a resend of the same key returns that answer and writes nothing, and get_submission_result finds it.
--    The signatures grow by one defaulted parameter, so the old ones are dropped first (PostgREST would see two overloads).
--  * replace_item_rates, change mode: a rate that starts after p_starts_on is refused with LATER_RATES_EXIST whether it has begun or is
--    only planned, unless p_replace_later is true (before, a begun later rate was deleted without a word). data.later[].begun says which.
--  * find_storage_price, the single source of "which default rate applies to this item on this day" (invoice form, recalculation,
--    get_grn_item_rates, the missing-rates check of the GRN rate sheet): an item's first default rate also covers every earlier day.
--  * save_invoice (through save_invoice_internal) and update_invoice, no signature change; the new inputs are keys of the invoice data
--    and of the lines, so an older app that sends none of them keeps working:
--      - INVOICE_DATE_FUTURE: an invoice day after today (India); update_invoice checks it only when the invoice day changes;
--      - INVOICE_BEFORE_DISPATCH: an invoice dated before the latest dispatch of its lines; update_invoice checks it only when the
--        invoice day or the set of lines changes;
--      - DISCOUNT_TOTAL_ZERO: a discount that takes a charged invoice to exactly 0;
--      - RATES_CHANGED: lines that carry `looked_up` (and `typed` for figures typed by hand) whose lookup changed since.
--    They are raised as 'rate_fail' like TOTAL_CHANGED: the handler rolls the block back and answers them (success false, error_code
--    WH409, reason = the code). Helpers: warehouse_security.check_invoice_dates, check_discount_total, check_invoice_rates.
-- The refusal of customer and everyone rate entries for an invoiced GRN (GRN_INVOICED) is in migrations/definitions/apply_grn_rates.sql.

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

-- Section 5: invoice checks. They are raised as 'rate_fail' (like TOTAL_CHANGED): the handler of the function rolls the block back and
-- answers the refusal, which is built by warehouse_security.refuse (success false, error_code WH409, reason = the code, the fields).
-- The new inputs are keys of the invoice data and of the lines, so no signature changes and an older app keeps working: it sends none
-- of them, and what it does send is judged by the same rules as every other client.

-- The date rules. p_invoice_id is the invoice being edited (NULL or an id that does not exist yet: a new invoice, everything is
-- checked). For an existing invoice the rules look at what the edit changes, so that an old invoice can still be edited for other
-- reasons: the future-date rule only when the invoice day changes, the dispatch rule when the day or the set of lines changes.
-- Days are India days (business_date), as the dispatch rules are.
CREATE FUNCTION warehouse_security.check_invoice_dates(p_invoice_id uuid, p_invoice_date timestamptz, p_lines uuid[]) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_day date; v_today date := warehouse_security.business_date(now()); v_stored_day date;
  v_date_changed boolean := true; v_lines_changed boolean := true;
  v_disp_no text; v_disp_day date;
BEGIN
  IF p_invoice_id IS NOT NULL THEN
    SELECT warehouse_security.business_date(i.inv_date) INTO v_stored_day FROM public.invoice i WHERE i.id = p_invoice_id;
    IF FOUND THEN
      -- An edit that does not send the date keeps the stored one: the date is not changed, and the dispatch rule still looks at the
      -- lines against the stored day.
      v_day := CASE WHEN p_invoice_date IS NULL THEN v_stored_day ELSE warehouse_security.business_date(p_invoice_date) END;
      v_date_changed := v_day IS DISTINCT FROM v_stored_day;
      v_lines_changed := ARRAY(SELECT it.disp_trl_id FROM public.invoice_trl it WHERE it.invoice_id = p_invoice_id ORDER BY it.disp_trl_id)
                         IS DISTINCT FROM ARRAY(SELECT DISTINCT l FROM unnest(p_lines) l ORDER BY l);
    END IF;
  END IF;
  IF v_day IS NULL THEN
    IF p_invoice_date IS NULL THEN RETURN; END IF;
    v_day := warehouse_security.business_date(p_invoice_date);
  END IF;

  -- D10: an invoice is not dated in the future (today in India). Stored invoices that already are stay as they are.
  IF v_date_changed AND v_day > v_today THEN
    RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('INVOICE_DATE_FUTURE',
      format('An invoice can''t be dated in the future. Today is %s.', to_char(v_today, 'YYYY-MM-DD')),
      jsonb_build_object('date', to_char(v_day, 'YYYY-MM-DD'), 'today', to_char(v_today, 'YYYY-MM-DD')))::text;
  END IF;

  -- An invoice is not dated before the latest dispatch of its lines. The dispatch named is the latest one (by day, then number).
  IF v_date_changed OR v_lines_changed THEN
    SELECT d.disp_no, warehouse_security.business_date(d.disp_date) INTO v_disp_no, v_disp_day
      FROM public.dispatch_trl dt JOIN public.dispatch d ON d.id = dt.disp_id
     WHERE dt.id = ANY (p_lines)
     ORDER BY warehouse_security.business_date(d.disp_date) DESC, d.disp_no DESC LIMIT 1;
    IF v_disp_day > v_day THEN
      RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('INVOICE_BEFORE_DISPATCH',
        format('The invoice date %s is before dispatch %s (%s).', to_char(v_day, 'YYYY-MM-DD'), v_disp_no, to_char(v_disp_day, 'YYYY-MM-DD')),
        jsonb_build_object('invoice_date', to_char(v_day, 'YYYY-MM-DD'), 'dispatch_no', v_disp_no,
                           'dispatch_date', to_char(v_disp_day, 'YYYY-MM-DD')))::text;
    END IF;
  END IF;
END;
$$;

ALTER FUNCTION warehouse_security.check_invoice_dates(uuid, timestamp with time zone, uuid[]) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.check_invoice_dates(uuid, timestamp with time zone, uuid[]) FROM PUBLIC;

-- D8: a discount may not take a charged invoice to exactly 0. p_totals is what recalculate_invoice_header just answered. The way to
-- bill nothing is a charge of 0 with its reason. An invoice with nothing to charge is not "charged": a discount larger than that
-- already fails in recalculate_invoice_header.
CREATE FUNCTION warehouse_security.check_discount_total(p_totals jsonb) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE v_discount numeric := COALESCE((p_totals->>'discount')::numeric, 0);
        v_before numeric := ceil(COALESCE((p_totals->>'subtotal')::numeric, 0) + COALESCE((p_totals->>'tax')::numeric, 0));
BEGIN
  IF v_discount > 0 AND COALESCE((p_totals->>'grand_total')::numeric, 0) = 0 AND v_before > 0 THEN
    RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('DISCOUNT_TOTAL_ZERO',
      'A discount can''t take the total to zero. To charge nothing, set the charge to 0 and give a reason.',
      jsonb_build_object('discount', v_discount, 'total_before_discount', v_before))::text;
  END IF;
END;
$$;

ALTER FUNCTION warehouse_security.check_discount_total(jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.check_discount_total(jsonb) FROM PUBLIC;

-- D12: the figures the form looked up. A line may carry `looked_up` = {charge, labour_rate, tax} (what the form showed when it
-- opened) and, for figures the person typed by hand, `typed` = true (all three) or a list of the field names. Every other figure of
-- such a line is compared with what the invoice form would look up now (build_invoice_form_lines, the one lookup the form uses); the
-- lines that differ are refused together, with the old and the new figures. No `looked_up` on any line: no check (an older app).
CREATE FUNCTION warehouse_security.check_invoice_rates(p_gr_id uuid, p_duration_mode text, p_items jsonb[]) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE v_form jsonb; v_changed jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM unnest(p_items) i WHERE jsonb_typeof(i->'looked_up') = 'object') THEN
    RETURN;
  END IF;
  v_form := public.build_invoice_form_lines(p_gr_id, p_duration_mode);
  IF v_form->>'success' IS DISTINCT FROM 'true' THEN
    RETURN;
  END IF;
  SELECT jsonb_agg(jsonb_build_object('disp_trl_id', x.id, 'fields', to_jsonb(x.fields), 'looked_up', x.sent,
                                      'current', jsonb_build_object('charge', x.cur_charge, 'labour_rate', x.cur_labour, 'tax', x.cur_tax))
                   ORDER BY x.ord)
    INTO v_changed
    FROM (
      SELECT y.*, array_remove(ARRAY[
               CASE WHEN NOT y.t_charge AND round(NULLIF(y.sent->>'charge', '')::numeric, 2) IS DISTINCT FROM round(y.cur_charge, 2) THEN 'charge' END,
               CASE WHEN NOT y.t_labour AND round(NULLIF(y.sent->>'labour_rate', '')::numeric, 2) IS DISTINCT FROM round(y.cur_labour, 2) THEN 'labour_rate' END,
               CASE WHEN NOT y.t_tax AND round(NULLIF(y.sent->>'tax', '')::numeric, 2) IS DISTINCT FROM round(y.cur_tax, 2) THEN 'tax' END
             ], NULL) AS fields
        FROM (
          SELECT t.ord, (t.item->>'disp_trl_id')::uuid AS id, t.item->'looked_up' AS sent,
                 COALESCE(t.item->'typed' = 'true'::jsonb OR (jsonb_typeof(t.item->'typed') = 'array' AND t.item->'typed' ? 'charge'), false) AS t_charge,
                 COALESCE(t.item->'typed' = 'true'::jsonb OR (jsonb_typeof(t.item->'typed') = 'array' AND t.item->'typed' ? 'labour_rate'), false) AS t_labour,
                 COALESCE(t.item->'typed' = 'true'::jsonb OR (jsonb_typeof(t.item->'typed') = 'array' AND t.item->'typed' ? 'tax'), false) AS t_tax,
                 f.cur_charge, f.cur_labour, f.cur_tax
            FROM unnest(p_items) WITH ORDINALITY t(item, ord)
            JOIN LATERAL (
              SELECT (e->>'unit_price')::numeric AS cur_charge, (e->>'labour_rate')::numeric AS cur_labour, (e->>'tax_percent')::numeric AS cur_tax
                FROM jsonb_array_elements(v_form->'items') e
               WHERE e->>'dispatches_items_id' = t.item->>'disp_trl_id' LIMIT 1) f ON true
           WHERE jsonb_typeof(t.item->'looked_up') = 'object') y
    ) x
   WHERE cardinality(x.fields) > 0;
  IF v_changed IS NOT NULL THEN
    RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('RATES_CHANGED',
      'The rates changed since you opened this invoice. Check the new figures.', jsonb_build_object('lines', v_changed))::text;
  END IF;
END;
$$;

ALTER FUNCTION warehouse_security.check_invoice_rates(uuid, text, jsonb[]) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.check_invoice_rates(uuid, text, jsonb[]) FROM PUBLIC;

DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$PERFORM warehouse_security.claim_invoice_lines(NULL, v_new_gr_id,$m$,
    $m$PERFORM warehouse_security.recalculate_invoice_header(v_final_invoice_id);$m$
  ];
  v_new constant text[] := ARRAY[
    $m$-- Migration 129: the date rules, before anything is written.
    PERFORM warehouse_security.check_invoice_dates(p_invoice_id, v_invoice_date, ARRAY(SELECT (item->>'disp_trl_id')::uuid FROM unnest(p_invoice_items) AS item));
    -- Migration 129: lines that carry the figures the form looked up are compared with the lookup now.
    PERFORM warehouse_security.check_invoice_rates(v_new_gr_id, v_duration_mode, p_invoice_items);

    PERFORM warehouse_security.claim_invoice_lines(NULL, v_new_gr_id,$m$,
    $m$PERFORM warehouse_security.check_discount_total(warehouse_security.recalculate_invoice_header(v_final_invoice_id));$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.save_invoice_internal(uuid, jsonb, jsonb[])'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'save_invoice_internal: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$    v_new_updated_at timestamptz;
BEGIN$m$,
    $m$PERFORM warehouse_security.claim_invoice_lines(p_invoice_id, v_new_gr_id,$m$,
    $m$PERFORM warehouse_security.recalculate_invoice_header(p_invoice_id);$m$
  ];
  v_new constant text[] := ARRAY[
    $m$    v_new_updated_at timestamptz;
    v_money_changed boolean;
    v_old_total numeric;
    v_new_totals jsonb;
BEGIN$m$,
    $m$-- Migration 129: the date rules, only for what the edit changes, before anything is written.
    PERFORM warehouse_security.check_invoice_dates(p_invoice_id, (p_invoice_data->>'inv_date')::timestamptz, ARRAY(SELECT (item->>'disp_trl_id')::uuid FROM unnest(p_invoice_items) AS item));
    -- Migration 129: lines that carry the figures the form looked up are compared with the lookup now.
    PERFORM warehouse_security.check_invoice_rates(v_new_gr_id, v_duration_mode, p_invoice_items);
    -- Migration 129: the "discount may not make the total 0" rule below is for an edit that changes the discount, the set of lines or the
    -- total (a charge or tax edit under an existing discount can also reach 0), so that an invoice already stored at 0 by a discount
    -- can still take a note or a date fix.
    SELECT i.total INTO v_old_total FROM invoice i WHERE i.id = p_invoice_id;
    v_money_changed := v_discount IS DISTINCT FROM (SELECT COALESCE(i.discount, 0) FROM invoice i WHERE i.id = p_invoice_id)
      OR ARRAY(SELECT t.disp_trl_id FROM invoice_trl t WHERE t.invoice_id = p_invoice_id ORDER BY t.disp_trl_id)
         IS DISTINCT FROM ARRAY(SELECT DISTINCT (item->>'disp_trl_id')::uuid AS l FROM unnest(p_invoice_items) AS item ORDER BY l);

    PERFORM warehouse_security.claim_invoice_lines(p_invoice_id, v_new_gr_id,$m$,
    $m$v_new_totals := warehouse_security.recalculate_invoice_header(p_invoice_id);
    IF v_money_changed OR COALESCE((v_new_totals->>'grand_total')::numeric, 0) IS DISTINCT FROM COALESCE(v_old_total, 0) THEN
        PERFORM warehouse_security.check_discount_total(v_new_totals);
    END IF;$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.update_invoice(uuid, jsonb, jsonb[])'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'update_invoice: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
