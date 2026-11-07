-- Migration 165: a facility setting to invoice lots that have left while other lots of the same GRN are still in store (WH-138).
--
--  * warehouse_security.charging_rule (migration 164) gains invoice_as_goods_leave boolean, default false. get_charging_rule and
--    set_charging_rule carry it (administrators only; a change is one audit_log row, as for the other fields). set_charging_rule
--    takes it as an optional key (left out: unchanged), and refuses true -> false while a GRN with stock has a live invoice:
--    {success:false, error_code:'WH409', reason:'PARTIAL_INVOICES_OPEN', count, gr_nos (up to five)}; nothing changes.
--  * With the setting OFF (every facility until an administrator turns it on) every rule below answers exactly as before: the new
--    branches test the setting first, and the cache triggers return at once.
--  * With the setting ON:
--      - save_invoice (save_invoice_internal) and update_invoice skip the D9 stock check (GRN_HAS_STOCK); claim_invoice_lines no longer
--        refuses a second invoice on a GRN ("GRN is already invoiced"). A dispatch line still sits on one live invoice only ("A dispatch
--        line is already on another invoice", WH409). T10, T8, T12, W18, W1 and CHARGING_CHANGED are unchanged.
--      - The invoice form (generate_invoice_data_for_grn_with_pricing) is answered for a GRN with stock, and offers only the dispatch
--        lines that are on no live invoice (build_invoice_form_lines); none left: an empty items list. In update_invoice the
--        invoice's own lines count as free for the rate check (T12). get_invoiceable_grns lists the GRNs with a free dispatch line.
--      - GRN state (warehouse_security.grn_invoice_state): not_invoiced (no live invoice); invoiced (no stock and every dispatch line
--        on a live invoice); partly_invoiced (otherwise). With the setting off it is WH-112's rule: a live invoice = invoiced.
--        goodsreceived.invoiced stays a cache equal to state = invoiced: triggers on invoice, invoice_trl, goodsreceived_trl, dispatch_trl
--        and dispatch keep it while the setting is on, a BEFORE trigger corrects any other write of it, and set_charging_rule
--        resynchronises every GRN when the setting changes.
--      - update_grn refuses a new lot (GRN_INVOICED) only for an invoiced GRN, not a partly invoiced one; the GRN date stays locked
--        once any live invoice exists; the per-lot locks are unchanged. apply_grn_rates treats a GRN as invoiced (GRN_INVOICED,
--        GRN-only rates archived) only when its state is invoiced. (Both in their definition files.)
--  * Readers: get_grn_list answers invoice_state on each GRN and takes the filter invoiced = 'partly_invoiced' (true and false keep
--    their meaning; with the setting on they mean the states invoiced and not_invoiced); get_grn_details answers invoice_state and
--    invoices [{id, inv_no, inv_fin_year, inv_date, total}] (live ones) in its invoice summary; get_customer_grn_activity answers
--    invoiced_amount (the sum of the GRN's live invoices) and invoice_state. Reports that list invoices already add every live invoice.
--
-- Today's behaviour (pinned, unchanged with the setting off):
--   save on a GRN with stock: {success:false, error_code:'WH409', reason:'GRN_HAS_STOCK', gr_no, stock, lots}
--   a second invoice on a GRN with a live invoice: 'GRN is already invoiced' (WH409)
--   the form for a GRN with stock or an invoice: 'GRN is not ready for invoicing (must be completely dispatched and not already invoiced)'
--   get_invoiceable_grns: out_of_stock and invoiced false; get_grn_list invoiced filter: a live invoice exists (migration 160)
--   update_grn: a new lot on a GRN with a live invoice (or the flag): GRN_INVOICED; a date change: GRN_DATE_LOCKED
-- Money (made-up figures): GRN of 10 bags in two lots of 5, rate 10.00 a month, no labour, receipt day 0; lot A leaves on day 20
-- (1 month), lot B on day 50 (2 months). One invoice after both left (today): 50.00 + 100.00 = 150.00, total 150. With the setting on,
-- invoice 1 (lot A) 50 and invoice 2 (lot B) 100: the GRN's invoiced amount is 150, the same. Each invoice rounds its own header (WH-137
-- rule), so split invoices can differ by the rounding: with tax 5 % on lines of 51.00 and 101.00, one invoice is 152.00 + ceil(7.60) =
-- 160; two invoices are 51.00 + ceil(2.55) = 54 and 101.00 + ceil(5.05) = 107, together 161.
--
-- Marker-count patches as in migration 164; the update_grn and apply_grn_rates changes are in their definition files.

-- Section 1: the setting
ALTER TABLE warehouse_security.charging_rule ADD COLUMN invoice_as_goods_leave boolean DEFAULT false NOT NULL;
COMMENT ON COLUMN warehouse_security.charging_rule.invoice_as_goods_leave IS 'Migration 165: a GRN may have several invoices, each for dispatch lines on no other live invoice, while stock remains.';

DROP TRIGGER audit_charging_rule_update ON warehouse_security.charging_rule;
CREATE TRIGGER audit_charging_rule_update AFTER UPDATE ON warehouse_security.charging_rule FOR EACH ROW
  WHEN (ROW(OLD.step_days, OLD.minimum_days, OLD.days_counted, OLD.rounding, OLD.invoice_as_goods_leave)
        IS DISTINCT FROM ROW(NEW.step_days, NEW.minimum_days, NEW.days_counted, NEW.rounding, NEW.invoice_as_goods_leave))
  EXECUTE FUNCTION public.audit_trigger_func();

-- Section 2: the GRN's state
CREATE FUNCTION warehouse_security.invoice_as_goods_leave() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT COALESCE((SELECT r.invoice_as_goods_leave FROM warehouse_security.charging_rule r WHERE r.id), false)
$$;
ALTER FUNCTION warehouse_security.invoice_as_goods_leave() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.invoice_as_goods_leave() FROM PUBLIC;

-- A dispatch line of the GRN (its dispatch not deleted) that is on no live invoice.
CREATE FUNCTION warehouse_security.grn_has_free_dispatch_line(p_gr_id uuid) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.dispatch_trl dt
    JOIN public.dispatch d ON d.id = dt.disp_id AND d.deleted_at IS NULL
    WHERE dt.gr_id = p_gr_id
      AND NOT EXISTS (SELECT 1 FROM public.invoice_trl it JOIN public.invoice iv ON iv.id = it.invoice_id
                      WHERE it.disp_trl_id = dt.id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL))
$$;
ALTER FUNCTION warehouse_security.grn_has_free_dispatch_line(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_has_free_dispatch_line(uuid) FROM PUBLIC;

CREATE FUNCTION warehouse_security.grn_invoice_state(p_gr_id uuid) RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM public.invoice i WHERE i.gr_id = p_gr_id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL)
      THEN 'not_invoiced'
    WHEN NOT warehouse_security.invoice_as_goods_leave() THEN 'invoiced'
    WHEN NOT EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.gr_id = p_gr_id AND t.stock > 0)
         AND NOT warehouse_security.grn_has_free_dispatch_line(p_gr_id) THEN 'invoiced'
    ELSE 'partly_invoiced' END
$$;
ALTER FUNCTION warehouse_security.grn_invoice_state(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_invoice_state(uuid) FROM PUBLIC;

-- The cache, while the setting is on. A GRN whose flag already agrees is not written.
CREATE FUNCTION warehouse_security.sync_grn_invoiced(p_gr_id uuid) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog'
    AS $$
BEGIN
  IF p_gr_id IS NULL OR NOT warehouse_security.invoice_as_goods_leave() THEN
    RETURN;
  END IF;
  UPDATE public.goodsreceived g SET invoiced = (warehouse_security.grn_invoice_state(g.id) = 'invoiced')
   WHERE g.id = p_gr_id AND g.invoiced IS DISTINCT FROM (warehouse_security.grn_invoice_state(g.id) = 'invoiced');
END $$;
ALTER FUNCTION warehouse_security.sync_grn_invoiced(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.sync_grn_invoiced(uuid) FROM PUBLIC;

CREATE FUNCTION warehouse_security.sync_grn_invoiced_trigger() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE r record;
BEGIN
  IF NOT warehouse_security.invoice_as_goods_leave() THEN
    RETURN NULL;
  END IF;
  IF TG_TABLE_NAME = 'invoice' THEN
    IF TG_OP <> 'INSERT' THEN PERFORM warehouse_security.sync_grn_invoiced(OLD.gr_id); END IF;
    IF TG_OP <> 'DELETE' THEN PERFORM warehouse_security.sync_grn_invoiced(NEW.gr_id); END IF;
  ELSIF TG_TABLE_NAME = 'invoice_trl' THEN
    IF TG_OP <> 'INSERT' THEN
      PERFORM warehouse_security.sync_grn_invoiced((SELECT i.gr_id FROM public.invoice i WHERE i.id = OLD.invoice_id));
    END IF;
    IF TG_OP <> 'DELETE' THEN
      PERFORM warehouse_security.sync_grn_invoiced((SELECT i.gr_id FROM public.invoice i WHERE i.id = NEW.invoice_id));
    END IF;
  ELSIF TG_TABLE_NAME IN ('goodsreceived_trl', 'dispatch_trl') THEN
    IF TG_OP <> 'INSERT' THEN PERFORM warehouse_security.sync_grn_invoiced(OLD.gr_id); END IF;
    IF TG_OP <> 'DELETE' THEN PERFORM warehouse_security.sync_grn_invoiced(NEW.gr_id); END IF;
  ELSIF TG_TABLE_NAME = 'dispatch' THEN
    FOR r IN SELECT DISTINCT dt.gr_id FROM public.dispatch_trl dt WHERE dt.disp_id = NEW.id LOOP
      PERFORM warehouse_security.sync_grn_invoiced(r.gr_id);
    END LOOP;
  END IF;
  RETURN NULL;
END $$;
ALTER FUNCTION warehouse_security.sync_grn_invoiced_trigger() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.sync_grn_invoiced_trigger() FROM PUBLIC;

CREATE TRIGGER sync_grn_invoiced AFTER INSERT OR DELETE OR UPDATE OF gr_id, deleted_at, cancelled_at ON public.invoice
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.sync_grn_invoiced_trigger();
CREATE TRIGGER sync_grn_invoiced AFTER INSERT OR DELETE OR UPDATE OF invoice_id, disp_trl_id ON public.invoice_trl
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.sync_grn_invoiced_trigger();
CREATE TRIGGER sync_grn_invoiced AFTER INSERT OR DELETE OR UPDATE OF gr_id, stock ON public.goodsreceived_trl
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.sync_grn_invoiced_trigger();
CREATE TRIGGER sync_grn_invoiced AFTER INSERT OR DELETE OR UPDATE OF gr_id ON public.dispatch_trl
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.sync_grn_invoiced_trigger();
CREATE TRIGGER sync_grn_invoiced AFTER UPDATE OF deleted_at ON public.dispatch
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.sync_grn_invoiced_trigger();

-- Any other write of the flag (the invoice RPCs set it to true when they save) is corrected to the state while the setting is on.
CREATE FUNCTION warehouse_security.keep_grn_invoiced_cache() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
BEGIN
  IF warehouse_security.invoice_as_goods_leave() THEN
    NEW.invoiced := (warehouse_security.grn_invoice_state(NEW.id) = 'invoiced');
  END IF;
  RETURN NEW;
END $$;
ALTER FUNCTION warehouse_security.keep_grn_invoiced_cache() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.keep_grn_invoiced_cache() FROM PUBLIC;

CREATE TRIGGER keep_grn_invoiced_cache BEFORE UPDATE OF invoiced ON public.goodsreceived FOR EACH ROW
  WHEN (OLD.invoiced IS DISTINCT FROM NEW.invoiced)
  EXECUTE FUNCTION warehouse_security.keep_grn_invoiced_cache();

-- Section 3: the RPCs of migration 164 with the setting
CREATE OR REPLACE FUNCTION public.get_charging_rule() RETURNS jsonb
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
            || jsonb_build_object('invoice_as_goods_leave', v_rule.invoice_as_goods_leave,
                                  'updated_at', v_rule.updated_at, 'updated_by', v_rule.updated_by,
                                  'updated_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = v_rule.updated_by)));
END $$;

-- p_rule carries step_days, minimum_days, days_counted and rounding (required, as in migration 164) and, optionally,
-- invoice_as_goods_leave (true or false; left out: unchanged).
CREATE OR REPLACE FUNCTION public.set_charging_rule(p_rule jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_old warehouse_security.charging_rule;
    v_new warehouse_security.charging_rule;
    v_step integer;
    v_minimum integer;
    v_leave boolean;
    v_changed boolean;
    v_open_count bigint;
    v_open_nos jsonb;
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
  IF p_rule ? 'invoice_as_goods_leave' AND jsonb_typeof(p_rule->'invoice_as_goods_leave') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION 'invoice_as_goods_leave must be true or false' USING ERRCODE = '22023';
  END IF;

  SELECT r.* INTO v_old FROM warehouse_security.charging_rule r WHERE r.id FOR UPDATE;
  v_leave := COALESCE((p_rule->>'invoice_as_goods_leave')::boolean, v_old.invoice_as_goods_leave);

  -- Turning the setting off while a GRN with stock has a live invoice would leave that invoice uneditable (D9): refused, nothing changes.
  IF v_old.invoice_as_goods_leave AND NOT v_leave THEN
    WITH open_grns AS (
      SELECT g.gr_no FROM public.goodsreceived g
       WHERE g.deleted_at IS NULL
         AND EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.gr_id = g.id AND t.stock > 0)
         AND EXISTS (SELECT 1 FROM public.invoice i WHERE i.gr_id = g.id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL))
    SELECT (SELECT count(*) FROM open_grns),
           COALESCE((SELECT jsonb_agg(x.gr_no ORDER BY x.gr_no) FROM (SELECT o.gr_no FROM open_grns o ORDER BY o.gr_no LIMIT 5) x), '[]'::jsonb)
      INTO v_open_count, v_open_nos;
    IF v_open_count > 0 THEN
      RETURN warehouse_security.refuse('PARTIAL_INVOICES_OPEN',
        format('%s GRNs with goods still in store already have an invoice. Invoice or cancel those first, then turn this off.', v_open_count),
        jsonb_build_object('count', v_open_count, 'gr_nos', v_open_nos));
    END IF;
  END IF;

  UPDATE warehouse_security.charging_rule r
     SET step_days = v_step, minimum_days = v_minimum, days_counted = p_rule->>'days_counted', rounding = p_rule->>'rounding',
         invoice_as_goods_leave = v_leave,
         updated_by = public.get_current_user_profile_id(), updated_at = now()
   WHERE r.id
     AND ROW(r.step_days::integer, r.minimum_days::integer, r.days_counted, r.rounding, r.invoice_as_goods_leave)
         IS DISTINCT FROM ROW(v_step, v_minimum, p_rule->>'days_counted', p_rule->>'rounding', v_leave)
  RETURNING r.* INTO v_new;
  v_changed := FOUND;
  IF NOT v_changed THEN
    v_new := v_old;
  END IF;

  -- The setting changed: every GRN's cached flag follows the state under the new setting.
  IF v_new.invoice_as_goods_leave IS DISTINCT FROM v_old.invoice_as_goods_leave THEN
    UPDATE public.goodsreceived g SET invoiced = (warehouse_security.grn_invoice_state(g.id) = 'invoiced')
     WHERE g.invoiced IS DISTINCT FROM (warehouse_security.grn_invoice_state(g.id) = 'invoiced');
  END IF;

  RETURN jsonb_build_object('success', true, 'changed', v_changed,
    'rule', warehouse_security.charging_rule_json(v_new)
            || jsonb_build_object('invoice_as_goods_leave', v_new.invoice_as_goods_leave,
                                  'updated_at', v_new.updated_at, 'updated_by', v_new.updated_by,
                                  'updated_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = v_new.updated_by)),
    'previous_rule', warehouse_security.charging_rule_json(v_old)
            || jsonb_build_object('invoice_as_goods_leave', v_old.invoice_as_goods_leave));
END $$;

-- Section 4: the invoice functions
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

-- 4.1 The second invoice on a GRN.
SELECT pg_temp.patch_function('warehouse_security.claim_invoice_lines(uuid, uuid, uuid[])'::regprocedure, ARRAY[
$m$IF receipt_invoiced IS TRUE AND own_receipt IS DISTINCT FROM p_gr_id THEN$m$
], ARRAY[
$m$IF receipt_invoiced IS TRUE AND own_receipt IS DISTINCT FROM p_gr_id
     AND NOT warehouse_security.invoice_as_goods_leave() THEN  -- Migration 165: with the setting on, only the line rule below holds.$m$
]);

-- 4.2 The D9 stock check, on save and edit.
SELECT pg_temp.patch_function('public.save_invoice_internal(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$IF v_stock_left > 0 THEN$m$
], ARRAY[
$m$IF v_stock_left > 0 AND NOT v_charging.invoice_as_goods_leave THEN  -- Migration 165: not made with the setting on.$m$
]);

SELECT pg_temp.patch_function('public.update_invoice(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$IF v_stock_left > 0 THEN$m$,
$m$compared with the lookup now.
    PERFORM warehouse_security.check_invoice_rates(v_new_gr_id, v_duration_mode, p_invoice_items);$m$
], ARRAY[
$m$IF v_stock_left > 0 AND NOT warehouse_security.invoice_as_goods_leave() THEN  -- Migration 165: not made with the setting on.$m$,
$m$compared with the lookup now. Migration 165: this
    -- invoice's own lines count as free lines of the form while it is checked.
    PERFORM set_config('warehouse.form_invoice_id', p_invoice_id::text, true);
    PERFORM warehouse_security.check_invoice_rates(v_new_gr_id, v_duration_mode, p_invoice_items);
    PERFORM set_config('warehouse.form_invoice_id', '', true);$m$
]);

-- 4.3 The invoice form: with the setting on, only free dispatch lines, and a GRN with stock or another invoice is answered.
SELECT pg_temp.patch_function('public.build_invoice_form_lines(uuid, text)'::regprocedure, ARRAY[
$m$WHERE grt.gr_id = p_gr_id
    ),
    pairs AS MATERIALIZED ($m$
], ARRAY[
$m$WHERE grt.gr_id = p_gr_id
          -- Migration 165: with the setting on, a line on a live invoice (other than the one being edited) is not offered.
          AND (NOT v_charging.invoice_as_goods_leave OR NOT EXISTS (
                SELECT 1 FROM invoice_trl lit JOIN invoice liv ON liv.id = lit.invoice_id
                WHERE lit.disp_trl_id = dt.id AND liv.deleted_at IS NULL AND liv.cancelled_at IS NULL
                  AND liv.id::text IS DISTINCT FROM NULLIF(current_setting('warehouse.form_invoice_id', true), '')))
    ),
    pairs AS MATERIALIZED ($m$
]);

SELECT pg_temp.patch_function('public.generate_invoice_data_for_grn(uuid, text)'::regprocedure, ARRAY[
$m$AND invoiced = false
            AND NOT EXISTS(SELECT 1 FROM goodsreceived_trl WHERE gr_id = p_gr_id AND stock > 0)$m$
], ARRAY[
$m$AND (warehouse_security.invoice_as_goods_leave() OR (invoiced = false
            AND NOT EXISTS(SELECT 1 FROM goodsreceived_trl WHERE gr_id = p_gr_id AND stock > 0)))$m$
]);

SELECT pg_temp.patch_function('public.get_invoiceable_grns(integer, integer, text)'::regprocedure, ARRAY[
$m$          AND gr.out_of_stock = true
          AND gr.invoiced = false$m$,
$m$      AND gr.out_of_stock = true
      AND gr.invoiced = false$m$
], ARRAY[
$m$          AND CASE WHEN warehouse_security.invoice_as_goods_leave() THEN warehouse_security.grn_has_free_dispatch_line(gr.id)
                   ELSE gr.out_of_stock = true AND gr.invoiced = false END$m$,
$m$      AND CASE WHEN warehouse_security.invoice_as_goods_leave() THEN warehouse_security.grn_has_free_dispatch_line(gr.id)
               ELSE gr.out_of_stock = true AND gr.invoiced = false END$m$
]);

-- 4.4 GRN readers.
SELECT pg_temp.patch_function('public.get_grn_list(date, date, text, text, integer, integer, jsonb)'::regprocedure, ARRAY[
$m$    IF p_filters ? 'invoiced' THEN
        v_where_clauses := array_append(v_where_clauses,
            format('(EXISTS (SELECT 1 FROM invoice li WHERE li.gr_id = gr.id AND li.deleted_at IS NULL AND li.cancelled_at IS NULL)) = %L', (p_filters->>'invoiced')::boolean)
        );$m$,
$m$''invoiced'', ga.invoiced,
                                ''items_count''$m$
], ARRAY[
$m$    IF p_filters ? 'invoiced' THEN
        -- Migration 165: 'partly_invoiced' is the third state; with the setting on, true and false are the states invoiced and not_invoiced.
        v_where_clauses := array_append(v_where_clauses, CASE
            WHEN p_filters->>'invoiced' = 'partly_invoiced'
              THEN 'warehouse_security.grn_invoice_state(gr.id) = ''partly_invoiced'''
            WHEN warehouse_security.invoice_as_goods_leave()
              THEN format('warehouse_security.grn_invoice_state(gr.id) = %L',
                          CASE WHEN (p_filters->>'invoiced')::boolean THEN 'invoiced' ELSE 'not_invoiced' END)
            ELSE format('(EXISTS (SELECT 1 FROM invoice li WHERE li.gr_id = gr.id AND li.deleted_at IS NULL AND li.cancelled_at IS NULL)) = %L', (p_filters->>'invoiced')::boolean)
            END
        );$m$,
$m$''invoiced'', ga.invoiced,
                                ''invoice_state'', warehouse_security.grn_invoice_state(ga.id),
                                ''items_count''$m$
]);

SELECT pg_temp.patch_function('public.get_grn_details(uuid)'::regprocedure, ARRAY[
$m$'total_invoices', COUNT(DISTINCT inv.id) FILTER (WHERE inv.cancelled_at IS NULL),
                            'cancelled_count'$m$
], ARRAY[
$m$'total_invoices', COUNT(DISTINCT inv.id) FILTER (WHERE inv.cancelled_at IS NULL),
                            'invoice_state', warehouse_security.grn_invoice_state(gr.id),
                            'invoices', COALESCE(jsonb_agg(jsonb_build_object('id', inv.id, 'inv_no', inv.inv_no, 'inv_fin_year', inv.inv_fin_year,
                                                                              'inv_date', inv.inv_date, 'total', inv.total)
                                                           ORDER BY inv.inv_fin_year, inv.inv_no, inv.id)
                                                 FILTER (WHERE inv.cancelled_at IS NULL), '[]'::jsonb),
                            'cancelled_count'$m$
]);

SELECT pg_temp.patch_function('public.get_customer_grn_activity(uuid, date, date)'::regprocedure, ARRAY[
$m$'invoice_count', COUNT(*) OVER (PARTITION BY i.gr_id)
                ) as status$m$
], ARRAY[
$m$'invoice_count', COUNT(*) OVER (PARTITION BY i.gr_id),
                    'invoiced_amount', SUM(i.total) OVER (PARTITION BY i.gr_id),
                    'invoice_state', warehouse_security.grn_invoice_state(i.gr_id)
                ) as status$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
