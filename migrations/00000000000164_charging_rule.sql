-- Migration 164: how storage time is counted and how invoice totals are rounded, one rule per facility (WH-137).
--
--  * warehouse_security.charging_rule: one row, the facility's rule. It starts as the rule every invoice has used so far, so a facility
--    bills exactly as before until an administrator changes it:
--      step_days     15      storage is charged in steps of 15 days (half a month); 30 = a month, 1 = a day
--      minimum_days  30      at least 30 days (1 month) are charged; 0 = one step, 15, 30, 60 or 90 (never shorter than one step)
--      days_counted  legacy  billable days = dispatch date - receipt date; standard adds the day of receipt (the existing duration_mode)
--      rounding      up      header tax and grand total rounded up to the next rupee; nearest (50 paise up) or none (paise)
--    No app role has a grant on the table: get_charging_rule() reads it and set_charging_rule(p_rule) changes it, both administrators
--    only. Every change writes one audit_log row (old and new row, who) through the audit trigger; the same rule again writes nothing.
--  * public.invoice keeps the rule each invoice was made with: charge_step_days, charge_minimum_days, total_rounding (and duration_mode,
--    which it already had). The columns are added with today's values as their defaults, so every invoice saved before this migration
--    is stored as today's rule without rewriting a row (no updated_at, no audit row, no stale edit form).
--  * The months charged: duration = max(minimum, ceil(billable days / step) x step) / 30, billable days never below 1. With today's rule
--    warehouse_security.charge_duration uses the expression of calculate_invoice_duration itself, so every figure stays as it was;
--    calculate_invoice_duration is unchanged. invoice_trl.duration stays numeric(10,2): with steps of a day it holds the months to two
--    decimals (40 days: 1.33), and the storage of such a line is worked out from the days (quantity x rate x days / 30, rounded to paise),
--    never from the rounded months (warehouse_security.storage_amount, invoice_storage_amount).
--  * Which rule: a new invoice takes the facility's rule when it is saved (save_invoice through save_invoice_internal) and stores it; an
--    edit (update_invoice), the header recalculation and every reader use the invoice's stored rule. Days counted: a duration_mode the
--    request carries still wins, as before; without one the facility's rule decides (the app sends none). The invoice form's preview
--    (generate_invoice_data_for_grn_with_pricing, generate_invoice_data_for_grn, build_invoice_form_lines) uses the facility's rule
--    and answers it as `charging`; its p_duration_mode defaults change from 'legacy' to NULL (= the facility's days counted).
--  * CHARGING_CHANGED: the invoice form sends the rule it showed as `charging` in the invoice data; a save whose rule is no longer the
--    facility's is refused as RATES_CHANGED is (WH409, nothing saved). No `charging` key (an older app): no check.
--  * Readers: get_invoice_detail and get_invoice_data (definition files) answer `charging` on the header and `storage_amount` on each
--    line; the line amounts of get_invoice_items_detailed, get_customer_invoice_summary, get_dispatch_details and
--    get_invoice_range_for_print use the stored rule. Printed and PDF layouts are unchanged.
--
-- Today's figures, worked out from the code before this migration (calculate_invoice_duration, recalculate_invoice_header), with the
-- default rule they stay exactly these:
--   duration by billable days:  1 -> 1, 15 -> 1, 16 -> 1, 30 -> 1, 31 -> 1.5, 45 -> 1.5, 46 -> 2, 61 -> 2.5 (months)
--   days counted: receipt 2026-04-01, dispatch 2026-05-01: legacy 30 days -> 1; standard 31 days -> 1.5; same-day dispatch -> 1 day -> 1
--   sample line (made-up figures): 10 bags, rate 12.50 a month, labour 3.00, tax 5 %, receipt 2026-04-01, dispatch 2026-05-11 (40 days):
--     duration 1.5, storage 187.50, labour 30.00, base 217.50, tax basis 10.875 -> header tax 11, grand total ceil(228.50) = 229
--   ONE_TIME line: 10 bags x 40.00 = 400.00 storage whatever the days, no labour; header total 400
--   rounding up: a total of 1234.40 -> 1235, 1234.50 -> 1235
-- The same sample under other rules (for the tests):
--   steps of a day, minimum one step: 40 days -> 1.33 months, storage 10 x 12.50 x 40 / 30 = 166.67, base 196.67, tax basis 9.8335:
--     up: tax 10, total 207; nearest: tax 10, total 207; none: tax 9.83, total 206.50
--   steps of a month, minimum 1 month: 40 days -> 2 months, storage 250.00, base 280.00, tax 14, total 294
--   half-month steps, minimum 2 months: 40 days -> 2 months (as above); minimum one step: 10 days -> 0.5 months, storage 62.50
--   rounding nearest: 1234.40 -> 1234, 1234.50 -> 1235; none: 1234.40 -> 1234.40
--
-- The function changes are marker-count patches (migration 134's pattern): each before-text is found exactly once and no after-text
-- contains its before-text, so a second run fails on its count check. The changes to get_invoice_detail, get_invoice_data and
-- authorize_rpc are in their definition files.

-- Section 1: the facility's rule
CREATE TABLE warehouse_security.charging_rule (
    id boolean DEFAULT true NOT NULL,
    step_days smallint DEFAULT 15 NOT NULL,
    minimum_days smallint DEFAULT 30 NOT NULL,
    days_counted text DEFAULT 'legacy' NOT NULL,
    rounding text DEFAULT 'up' NOT NULL,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT charging_rule_pkey PRIMARY KEY (id),
    CONSTRAINT charging_rule_one_row CHECK (id),
    CONSTRAINT charging_rule_step_check CHECK (step_days IN (1, 15, 30)),
    CONSTRAINT charging_rule_minimum_check CHECK (minimum_days IN (0, 15, 30, 60, 90) AND (minimum_days = 0 OR minimum_days >= step_days)),
    CONSTRAINT charging_rule_days_check CHECK (days_counted IN ('legacy', 'standard')),
    CONSTRAINT charging_rule_rounding_check CHECK (rounding IN ('up', 'nearest', 'none'))
);
ALTER TABLE warehouse_security.charging_rule OWNER TO supabase_admin;
ALTER TABLE warehouse_security.charging_rule ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.charging_rule FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE warehouse_security.charging_rule IS 'Migration 164: the facility''s charging rule (one row); read and written only through get_charging_rule and set_charging_rule. minimum_days 0 means one step.';

INSERT INTO warehouse_security.charging_rule DEFAULT VALUES;

-- The row is never deleted (keep_document_numbering refuses with the table's name); a change writes one audit_log row.
CREATE TRIGGER keep_charging_rule BEFORE DELETE ON warehouse_security.charging_rule FOR EACH ROW
  EXECUTE FUNCTION warehouse_security.keep_document_numbering();
CREATE TRIGGER keep_charging_rule_truncate BEFORE TRUNCATE ON warehouse_security.charging_rule FOR EACH STATEMENT
  EXECUTE FUNCTION warehouse_security.keep_document_numbering();
CREATE TRIGGER audit_charging_rule_update AFTER UPDATE ON warehouse_security.charging_rule FOR EACH ROW
  WHEN (ROW(OLD.step_days, OLD.minimum_days, OLD.days_counted, OLD.rounding)
        IS DISTINCT FROM ROW(NEW.step_days, NEW.minimum_days, NEW.days_counted, NEW.rounding))
  EXECUTE FUNCTION public.audit_trigger_func();

-- Section 2: the rule of each invoice. Constant defaults: no table rewrite; every existing invoice reads as today's rule.
ALTER TABLE public.invoice
  ADD COLUMN charge_step_days smallint DEFAULT 15 NOT NULL,
  ADD COLUMN charge_minimum_days smallint DEFAULT 30 NOT NULL,
  ADD COLUMN total_rounding text DEFAULT 'up' NOT NULL,
  ADD CONSTRAINT invoice_charge_rule_check CHECK (charge_step_days IN (1, 15, 30)
    AND charge_minimum_days IN (0, 15, 30, 60, 90) AND (charge_minimum_days = 0 OR charge_minimum_days >= charge_step_days)
    AND total_rounding IN ('up', 'nearest', 'none'));
COMMENT ON COLUMN public.invoice.charge_step_days IS 'Migration 164: the step (days) storage was charged in when the invoice was made: 15, 30 or 1.';
COMMENT ON COLUMN public.invoice.charge_minimum_days IS 'Migration 164: the minimum charged (days) when the invoice was made; 0 = one step.';
COMMENT ON COLUMN public.invoice.total_rounding IS 'Migration 164: how header tax and grand total are rounded: up (to the next rupee), nearest, none (paise).';

-- Section 3: helpers
CREATE FUNCTION warehouse_security.current_charging_rule() RETURNS warehouse_security.charging_rule
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT r.* FROM warehouse_security.charging_rule r WHERE r.id
$$;
ALTER FUNCTION warehouse_security.current_charging_rule() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.current_charging_rule() FROM PUBLIC;

CREATE FUNCTION warehouse_security.charging_rule_json(r warehouse_security.charging_rule) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT jsonb_build_object('step_days', r.step_days, 'minimum_days', r.minimum_days, 'days_counted', r.days_counted, 'rounding', r.rounding)
$$;
ALTER FUNCTION warehouse_security.charging_rule_json(warehouse_security.charging_rule) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.charging_rule_json(warehouse_security.charging_rule) FROM PUBLIC;

-- The days and months charged for one dispatch line. Columns as calculate_invoice_duration (no_of_days, billable_days, duration) plus
-- charged_days. Today's rule (15, 30) keeps calculate_invoice_duration's own expression; every other rule gives the months to two decimals.
CREATE FUNCTION warehouse_security.charge_duration(p_grn_date date, p_dispatch_date date, p_duration_mode text, p_step_days integer, p_minimum_days integer)
    RETURNS TABLE(no_of_days integer, billable_days integer, charged_days integer, duration numeric)
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
    v_duration_mode text := public.validate_invoice_duration_mode(p_duration_mode);
BEGIN
    IF p_step_days IS NULL OR p_step_days NOT IN (1, 15, 30) OR p_minimum_days IS NULL OR p_minimum_days NOT IN (0, 15, 30, 60, 90) THEN
        RAISE EXCEPTION 'Invalid charging rule: step % days, minimum % days', p_step_days, p_minimum_days USING ERRCODE = '22023';
    END IF;
    no_of_days := (p_dispatch_date - p_grn_date)::integer
        + CASE WHEN v_duration_mode = 'standard' THEN 1 ELSE 0 END;
    billable_days := GREATEST(1, no_of_days);
    charged_days := GREATEST(p_minimum_days, CEIL(billable_days::numeric / p_step_days)::integer * p_step_days);
    IF p_step_days = 15 AND p_minimum_days = 30 THEN
        duration := GREATEST(1, CEIL(billable_days::numeric / 15.0) / 2.0);
    ELSE
        duration := round(charged_days / 30.0, 2);
    END IF;
    RETURN NEXT;
END;
$$;
ALTER FUNCTION warehouse_security.charge_duration(date, date, text, integer, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.charge_duration(date, date, text, integer, integer) FROM PUBLIC;

-- The storage of a monthly line. With steps of a day the line is charged for its days (minimum included) / 30, worked out before the
-- rounding to paise; with steps of 15 or 30 days the months are whole halves, so rate x quantity x duration is the same figure as before.
CREATE FUNCTION warehouse_security.storage_amount(p_charge numeric, p_qty numeric, p_duration numeric, p_no_of_days integer,
                                                   p_step_days integer, p_minimum_days integer) RETURNS numeric
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT CASE WHEN p_step_days = 1 AND p_no_of_days IS NOT NULL
              THEN round(p_charge * p_qty * GREATEST(p_minimum_days, GREATEST(1, p_no_of_days)) / 30.0, 2)
              ELSE round(p_charge * p_qty * p_duration, 2) END
$$;
ALTER FUNCTION warehouse_security.storage_amount(numeric, numeric, numeric, integer, integer, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.storage_amount(numeric, numeric, numeric, integer, integer, integer) FROM PUBLIC;

-- The same for a saved line, under its invoice's stored rule (an unknown invoice: today's rule).
CREATE FUNCTION warehouse_security.invoice_storage_amount(p_invoice_id uuid, p_charge numeric, p_qty numeric, p_duration numeric,
                                                           p_no_of_days integer) RETURNS numeric
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT warehouse_security.storage_amount(p_charge, p_qty, p_duration, p_no_of_days,
                                           COALESCE(i.charge_step_days, 15), COALESCE(i.charge_minimum_days, 30))
    FROM (SELECT p_invoice_id AS id) k
    LEFT JOIN public.invoice i ON i.id = k.id
$$;
ALTER FUNCTION warehouse_security.invoice_storage_amount(uuid, numeric, numeric, numeric, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.invoice_storage_amount(uuid, numeric, numeric, numeric, integer) FROM PUBLIC;

-- Header tax and grand total: up (ceiling, today's rule and the rule of a missing value), nearest (50 paise up) or none (to paise).
CREATE FUNCTION warehouse_security.round_invoice_total(p_amount numeric, p_rounding text) RETURNS numeric
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT CASE p_rounding WHEN 'nearest' THEN round(p_amount) WHEN 'none' THEN round(p_amount, 2) ELSE ceil(p_amount) END
$$;
ALTER FUNCTION warehouse_security.round_invoice_total(numeric, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.round_invoice_total(numeric, text) FROM PUBLIC;

-- CHARGING_CHANGED: the rule the form showed (`charging` in the invoice data) is no longer the facility's. Raised as 'rate_fail' like
-- RATES_CHANGED, so the save is rolled back and answered {success:false, error_code:'WH409', reason:'CHARGING_CHANGED', charging, sent}.
CREATE FUNCTION warehouse_security.check_charging_rule(p_invoice_data jsonb, p_rule warehouse_security.charging_rule) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
    v_sent jsonb := p_invoice_data->'charging';
    v_now jsonb := warehouse_security.charging_rule_json(p_rule);
BEGIN
    IF jsonb_typeof(v_sent) IS DISTINCT FROM 'object' THEN
        RETURN;
    END IF;
    IF jsonb_build_object('step_days', v_sent->'step_days', 'minimum_days', v_sent->'minimum_days',
                          'days_counted', v_sent->'days_counted', 'rounding', v_sent->'rounding') IS DISTINCT FROM v_now THEN
        RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('CHARGING_CHANGED',
            'How storage is charged changed since you opened this invoice. Check the new figures.',
            jsonb_build_object('charging', v_now, 'sent', v_sent))::text;
    END IF;
END;
$$;
ALTER FUNCTION warehouse_security.check_charging_rule(jsonb, warehouse_security.charging_rule) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.check_charging_rule(jsonb, warehouse_security.charging_rule) FROM PUBLIC;

-- Section 4: the RPCs. Administrators only; authorize_rpc's entry is in its definition file, and the bodies do not depend on it.
CREATE FUNCTION public.get_charging_rule() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_rule warehouse_security.charging_rule := warehouse_security.current_charging_rule();
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_charging_rule', jsonb_build_object());
  IF warehouse_security.active_role() IS DISTINCT FROM 'admin' AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object('success', true,
    'rule', warehouse_security.charging_rule_json(v_rule)
            || jsonb_build_object('updated_at', v_rule.updated_at, 'updated_by', v_rule.updated_by,
                                  'updated_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = v_rule.updated_by)));
END $$;
ALTER FUNCTION public.get_charging_rule() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_charging_rule() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_charging_rule() TO authenticated, service_role;

-- p_rule carries all four: {step_days: 15|30|1, minimum_days: 0|15|30|60|90, days_counted: legacy|standard, rounding: up|nearest|none}.
-- A wrong or missing value is refused with SQLSTATE 22023. The same rule again changes and records nothing (changed false).
CREATE FUNCTION public.set_charging_rule(p_rule jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_old warehouse_security.charging_rule;
    v_new warehouse_security.charging_rule;
    v_step integer;
    v_minimum integer;
    v_changed boolean;
BEGIN
  PERFORM warehouse_security.authorize_rpc('set_charging_rule', jsonb_build_object());
  IF warehouse_security.active_role() IS DISTINCT FROM 'admin' AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_rule) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Send the rule as {step_days, minimum_days, days_counted, rounding}' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_rule->'step_days') IS DISTINCT FROM 'number' OR (p_rule->>'step_days')::numeric NOT IN (1, 15, 30) THEN
    RAISE EXCEPTION 'step_days must be 15 (half a month), 30 (a month) or 1 (a day)' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_rule->'minimum_days') IS DISTINCT FROM 'number' OR (p_rule->>'minimum_days')::numeric NOT IN (0, 15, 30, 60, 90) THEN
    RAISE EXCEPTION 'minimum_days must be 0 (one step), 15, 30, 60 or 90' USING ERRCODE = '22023';
  END IF;
  v_step := (p_rule->>'step_days')::numeric::integer;
  v_minimum := (p_rule->>'minimum_days')::numeric::integer;
  IF v_minimum <> 0 AND v_minimum < v_step THEN
    RAISE EXCEPTION 'The minimum charge is shorter than one step' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_rule->'days_counted') IS DISTINCT FROM 'string' OR p_rule->>'days_counted' NOT IN ('legacy', 'standard') THEN
    RAISE EXCEPTION 'days_counted must be legacy (from the day after receipt) or standard (including the day of receipt)' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_rule->'rounding') IS DISTINCT FROM 'string' OR p_rule->>'rounding' NOT IN ('up', 'nearest', 'none') THEN
    RAISE EXCEPTION 'rounding must be up, nearest or none' USING ERRCODE = '22023';
  END IF;

  SELECT r.* INTO v_old FROM warehouse_security.charging_rule r WHERE r.id FOR UPDATE;
  UPDATE warehouse_security.charging_rule r
     SET step_days = v_step, minimum_days = v_minimum, days_counted = p_rule->>'days_counted', rounding = p_rule->>'rounding',
         updated_by = public.get_current_user_profile_id(), updated_at = now()
   WHERE r.id
     AND ROW(r.step_days::integer, r.minimum_days::integer, r.days_counted, r.rounding)
         IS DISTINCT FROM ROW(v_step, v_minimum, p_rule->>'days_counted', p_rule->>'rounding')
  RETURNING r.* INTO v_new;
  v_changed := FOUND;
  IF NOT v_changed THEN
    v_new := v_old;
  END IF;
  RETURN jsonb_build_object('success', true, 'changed', v_changed,
    'rule', warehouse_security.charging_rule_json(v_new)
            || jsonb_build_object('updated_at', v_new.updated_at, 'updated_by', v_new.updated_by,
                                  'updated_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = v_new.updated_by)),
    'previous_rule', warehouse_security.charging_rule_json(v_old));
END $$;
ALTER FUNCTION public.set_charging_rule(jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.set_charging_rule(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_charging_rule(jsonb) TO authenticated, service_role;

-- Section 5: the invoice functions
CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text[], p_new text[]) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_def text := pg_get_functiondef(p_function);
  v_count integer;
  i integer;
BEGIN
  IF array_length(p_old, 1) IS DISTINCT FROM array_length(p_new, 1) THEN
    RAISE EXCEPTION '%: the marker list and the replacement list differ in length', p_function;
  END IF;
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    IF position(p_old[i] IN p_new[i]) > 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % contains the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- 5.1 The header: the stored line storage under the invoice's rule, and its rounding.
SELECT pg_temp.patch_function('warehouse_security.recalculate_invoice_header(uuid)'::regprocedure, ARRAY[
$m$ELSE round(COALESCE(it.charge,0)*dt.disp_qty*COALESCE(it.duration,1),2)$m$,
$m$  tax_total := ceil(tax_basis);
  grand := ceil(subtotal + tax_total - discount_value);$m$
], ARRAY[
$m$ELSE warehouse_security.invoice_storage_amount(p_invoice_id, COALESCE(it.charge,0), dt.disp_qty, COALESCE(it.duration,1), it.no_of_days)$m$,
$m$  -- Migration 164: the invoice's own rounding ('up', the ceilings of before, for every invoice made before 164).
  tax_total := warehouse_security.round_invoice_total(tax_basis, (SELECT r.total_rounding FROM public.invoice r WHERE r.id=p_invoice_id));
  grand := warehouse_security.round_invoice_total(subtotal + tax_total - discount_value, (SELECT r.total_rounding FROM public.invoice r WHERE r.id=p_invoice_id));$m$
]);

-- 5.2 A new invoice: the facility's rule, checked against the one the form showed, stored with the invoice.
SELECT pg_temp.patch_function('public.save_invoice_internal(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$    v_duration_mode text;
    v_discount NUMERIC(12,2)$m$,
$m$v_duration_mode := public.validate_invoice_duration_mode(p_invoice_data->>'duration_mode');$m$,
$m$compared with the lookup now.
    PERFORM warehouse_security.check_invoice_rates(v_new_gr_id, v_duration_mode, p_invoice_items);$m$,
$m$            one_time_charge, notes, created_by, is_auto_generated, duration_mode
        ) VALUES (
            p_invoice_id,$m$,
$m$            v_duration_mode
        );
        v_final_invoice_id := p_invoice_id;$m$,
$m$            one_time_charge, notes, created_by, is_auto_generated, duration_mode
        ) VALUES (
            (p_invoice_data->>'inv_fin_year')::integer,$m$,
$m$            v_duration_mode
        ) RETURNING id INTO v_final_invoice_id;$m$,
$m$public.calculate_invoice_duration(warehouse_security.business_date(gr.date), warehouse_security.business_date(disp.disp_date), v_duration_mode) d$m$
], ARRAY[
$m$    v_duration_mode text;
    -- Migration 164: the facility's charging rule, read once for the whole save.
    v_charging warehouse_security.charging_rule := warehouse_security.current_charging_rule();
    v_discount NUMERIC(12,2)$m$,
$m$-- Migration 164: a duration_mode the request carries wins, as before; without one the facility's rule decides.
    v_duration_mode := public.validate_invoice_duration_mode(COALESCE(NULLIF(btrim(p_invoice_data->>'duration_mode'), ''), v_charging.days_counted));$m$,
$m$compared with the lookup now. Migration 164: the
    -- charging rule the form showed (`charging`) is compared with the facility's rule now.
    PERFORM warehouse_security.check_invoice_rates(v_new_gr_id, v_duration_mode, p_invoice_items);
    PERFORM warehouse_security.check_charging_rule(p_invoice_data, v_charging);$m$,
$m$            one_time_charge, notes, created_by, is_auto_generated, duration_mode,
            charge_step_days, charge_minimum_days, total_rounding
        ) VALUES (
            p_invoice_id,$m$,
$m$            v_duration_mode,
            v_charging.step_days, v_charging.minimum_days, v_charging.rounding
        );
        v_final_invoice_id := p_invoice_id;$m$,
$m$            one_time_charge, notes, created_by, is_auto_generated, duration_mode,
            charge_step_days, charge_minimum_days, total_rounding
        ) VALUES (
            (p_invoice_data->>'inv_fin_year')::integer,$m$,
$m$            v_duration_mode,
            v_charging.step_days, v_charging.minimum_days, v_charging.rounding
        ) RETURNING id INTO v_final_invoice_id;$m$,
$m$warehouse_security.charge_duration(warehouse_security.business_date(gr.date), warehouse_security.business_date(disp.disp_date), v_duration_mode, v_charging.step_days, v_charging.minimum_days) d$m$
]);

-- 5.3 An edit: the invoice's stored rule, whatever the facility's rule is now.
SELECT pg_temp.patch_function('public.update_invoice(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$    v_stored_duration_mode text;
    v_stored_inv_date timestamptz;$m$,
$m$    SELECT gr_id, duration_mode, inv_date, inv_fin_year, updated_at
    INTO v_old_gr_id, v_stored_duration_mode, v_stored_inv_date, v_stored_fin_year, v_stored_updated_at
$m$,
$m$public.calculate_invoice_duration(warehouse_security.business_date(gr.date), warehouse_security.business_date(disp.disp_date), v_duration_mode) d$m$
], ARRAY[
$m$    v_stored_duration_mode text;
    v_stored_step_days smallint;
    v_stored_minimum_days smallint;
    v_stored_inv_date timestamptz;$m$,
$m$    SELECT gr_id, duration_mode, inv_date, inv_fin_year, updated_at, charge_step_days, charge_minimum_days
    INTO v_old_gr_id, v_stored_duration_mode, v_stored_inv_date, v_stored_fin_year, v_stored_updated_at, v_stored_step_days, v_stored_minimum_days
$m$,
$m$warehouse_security.charge_duration(warehouse_security.business_date(gr.date), warehouse_security.business_date(disp.disp_date), v_duration_mode, v_stored_step_days, v_stored_minimum_days) d$m$
]);

-- 5.4 The invoice form's lines and totals: the facility's rule, answered as `charging`; each line also answers its storage_amount.
SELECT pg_temp.patch_function('public.build_invoice_form_lines(uuid, text)'::regprocedure, ARRAY[
$m$p_duration_mode text DEFAULT 'legacy'::text)$m$,
$m$    v_duration_mode text;
    v_grn_date date;$m$,
$m$    v_duration_mode := public.validate_invoice_duration_mode(p_duration_mode);$m$,
$m$public.calculate_invoice_duration(v_grn_date, dy.disp_bd, v_duration_mode) c$m$,
$m$ROUND(COALESCE(u.unit_price, 0) * r.disp_qty * dur.duration, 2)::numeric(12,2) END AS storage_amount$m$,
$m$'duration', l.duration,
                   'unit_price', l.unit_price,$m$,
$m$'items', s.items,
        'totals', jsonb_build_object($m$,
$m$'tax', CASE WHEN s.has_null THEN NULL ELSE CEIL(s.tax_basis)::numeric(12,2) END,
            'total_tax', CASE WHEN s.has_null THEN NULL ELSE CEIL(s.tax_basis)::numeric(12,2) END,
            'grand_total', CASE WHEN s.has_null THEN NULL ELSE CEIL(s.subtotal + CEIL(s.tax_basis)::numeric(12,2))::numeric(12,2) END,
            'total', CASE WHEN s.has_null THEN NULL ELSE CEIL(s.subtotal + CEIL(s.tax_basis)::numeric(12,2))::numeric(12,2) END,$m$
], ARRAY[
$m$p_duration_mode text DEFAULT NULL::text)$m$,
$m$    v_duration_mode text;
    v_charging warehouse_security.charging_rule;
    v_grn_date date;$m$,
$m$    -- Migration 164: the facility's charging rule; days counted as sent, else the rule's.
    v_charging := warehouse_security.current_charging_rule();
    v_duration_mode := public.validate_invoice_duration_mode(COALESCE(NULLIF(btrim(p_duration_mode), ''), v_charging.days_counted));$m$,
$m$warehouse_security.charge_duration(v_grn_date, dy.disp_bd, v_duration_mode, v_charging.step_days, v_charging.minimum_days) c$m$,
$m$warehouse_security.storage_amount(COALESCE(u.unit_price, 0), r.disp_qty, dur.duration, dur.no_of_days, v_charging.step_days, v_charging.minimum_days)::numeric(12,2) END AS storage_amount$m$,
$m$'duration', l.duration,
                   'storage_amount', l.storage_amount,
                   'unit_price', l.unit_price,$m$,
$m$'items', s.items,
        'charging', warehouse_security.charging_rule_json(v_charging),
        'totals', jsonb_build_object($m$,
$m$'tax', CASE WHEN s.has_null THEN NULL ELSE warehouse_security.round_invoice_total(s.tax_basis, v_charging.rounding)::numeric(12,2) END,
            'total_tax', CASE WHEN s.has_null THEN NULL ELSE warehouse_security.round_invoice_total(s.tax_basis, v_charging.rounding)::numeric(12,2) END,
            'grand_total', CASE WHEN s.has_null THEN NULL ELSE warehouse_security.round_invoice_total(s.subtotal + warehouse_security.round_invoice_total(s.tax_basis, v_charging.rounding)::numeric(12,2), v_charging.rounding)::numeric(12,2) END,
            'total', CASE WHEN s.has_null THEN NULL ELSE warehouse_security.round_invoice_total(s.subtotal + warehouse_security.round_invoice_total(s.tax_basis, v_charging.rounding)::numeric(12,2), v_charging.rounding)::numeric(12,2) END,$m$
]);

SELECT pg_temp.patch_function('public.generate_invoice_data_for_grn(uuid, text)'::regprocedure, ARRAY[
$m$p_duration_mode text DEFAULT 'legacy'::text)$m$,
$m$    v_duration_mode := public.validate_invoice_duration_mode(p_duration_mode);$m$,
$m$'totals', v_recalculation->'totals',
        'message'$m$
], ARRAY[
$m$p_duration_mode text DEFAULT NULL::text)$m$,
$m$    -- Migration 164: days counted as sent, else the facility's charging rule.
    v_duration_mode := public.validate_invoice_duration_mode(COALESCE(NULLIF(btrim(p_duration_mode), ''),
        (warehouse_security.current_charging_rule()).days_counted));$m$,
$m$'totals', v_recalculation->'totals',
        'charging', v_recalculation->'charging',
        'message'$m$
]);

SELECT pg_temp.patch_function('public.generate_invoice_data_for_grn_with_pricing(uuid, text)'::regprocedure, ARRAY[
$m$p_duration_mode text DEFAULT 'legacy'::text)$m$
], ARRAY[
$m$p_duration_mode text DEFAULT NULL::text)$m$
]);

-- 5.5 The recalculation rows (tests and the lot-rate reader): the stored rule of the invoice named, else the facility's.
SELECT pg_temp.patch_function('public.build_invoice_recalculation_rows(uuid, text, uuid)'::regprocedure, ARRAY[
$m$p_duration_mode text DEFAULT 'legacy'::text, p_invoice_id uuid DEFAULT NULL::uuid)$m$,
$m$    v_duration_record record;
    v_price_record item_storage_prices;$m$,
$m$    v_duration_mode := public.validate_invoice_duration_mode(p_duration_mode);$m$,
$m$FROM public.calculate_invoice_duration(v_grn_date, warehouse_security.business_date(v_dispatch_record.dispatches_date), v_duration_mode);$m$,
$m$v_storage_amount := ROUND(COALESCE(v_unit_price, 0) * v_dispatch_record.dispatches_items_disp_qty * v_duration_record.duration, 2);$m$,
$m$    v_total_tax := CEIL(v_tax_total_basis);
    v_grand_total := CEIL(v_subtotal + v_total_tax);$m$
], ARRAY[
$m$p_duration_mode text DEFAULT NULL::text, p_invoice_id uuid DEFAULT NULL::uuid)$m$,
$m$    v_duration_record record;
    v_step_days integer;
    v_minimum_days integer;
    v_rounding text;
    v_price_record item_storage_prices;$m$,
$m$    -- Migration 164: the stored rule of a live invoice named by p_invoice_id, else the facility's; days counted as sent, else as stored,
    -- else the facility's.
    SELECT COALESCE(i.charge_step_days, r.step_days), COALESCE(i.charge_minimum_days, r.minimum_days), COALESCE(i.total_rounding, r.rounding),
           public.validate_invoice_duration_mode(COALESCE(NULLIF(btrim(p_duration_mode), ''), i.duration_mode, r.days_counted))
      INTO v_step_days, v_minimum_days, v_rounding, v_duration_mode
      FROM warehouse_security.charging_rule r
      LEFT JOIN public.invoice i ON i.id = p_invoice_id AND i.cancelled_at IS NULL
     WHERE r.id;$m$,
$m$FROM warehouse_security.charge_duration(v_grn_date, warehouse_security.business_date(v_dispatch_record.dispatches_date), v_duration_mode, v_step_days, v_minimum_days);$m$,
$m$v_storage_amount := warehouse_security.storage_amount(COALESCE(v_unit_price, 0), v_dispatch_record.dispatches_items_disp_qty, v_duration_record.duration, v_duration_record.no_of_days, v_step_days, v_minimum_days);$m$,
$m$    v_total_tax := warehouse_security.round_invoice_total(v_tax_total_basis, v_rounding);
    v_grand_total := warehouse_security.round_invoice_total(v_subtotal + v_total_tax, v_rounding);$m$
]);

-- 5.6 Line amounts of saved invoices: the invoice's stored rule.
SELECT pg_temp.patch_function('public.get_invoice_items_detailed(uuid)'::regprocedure, ARRAY[
$m$ELSE ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(avail.qty, 0)::numeric * COALESCE(it.duration, 1)::numeric, 2)$m$
], ARRAY[
$m$ELSE warehouse_security.invoice_storage_amount(it.invoice_id, COALESCE(it.charge, 0)::numeric, COALESCE(avail.qty, 0)::numeric, COALESCE(it.duration, 1)::numeric, it.no_of_days)$m$
]);

SELECT pg_temp.patch_function('public.get_customer_invoice_summary(uuid, date, date, integer)'::regprocedure, ARRAY[
$m$ELSE ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric * COALESCE(it.duration, 1)::numeric, 2)$m$
], ARRAY[
$m$ELSE warehouse_security.invoice_storage_amount(it.invoice_id, COALESCE(it.charge, 0)::numeric, COALESCE(dt.disp_qty, 0)::numeric, COALESCE(it.duration, 1)::numeric, it.no_of_days)$m$
]);

SELECT pg_temp.patch_function('public.get_dispatch_details(uuid)'::regprocedure, ARRAY[
$m$ELSE ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric * COALESCE(it.duration, 1)::numeric, 2)$m$
], ARRAY[
$m$ELSE warehouse_security.invoice_storage_amount(it.invoice_id, COALESCE(it.charge, 0)::numeric, COALESCE(dt.disp_qty, 0)::numeric, COALESCE(it.duration, 1)::numeric, it.no_of_days)$m$
]);

SELECT pg_temp.patch_function('public.get_invoice_range_for_print(text, text, integer, integer)'::regprocedure, ARRAY[
$m$ELSE round(COALESCE(it.charge, 0) * dt.disp_qty * COALESCE(it.duration, 1), 2) END,$m$
], ARRAY[
$m$ELSE warehouse_security.invoice_storage_amount(it.invoice_id, COALESCE(it.charge, 0), dt.disp_qty, COALESCE(it.duration, 1), it.no_of_days) END,$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
