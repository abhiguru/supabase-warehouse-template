-- Sync feed, lot item rate (WH-348, offline work step 6): topic "sync lot item rate". Named by topic; its number is taken when the work is
-- assembled for main. Follows "sync invoice amounts" (second part, sync_invoice_line_amounts.sql); no format step: format 3 is set by "sync GST
-- details" and is not on main yet. Contract: product/tech/app-offline-read-more.md section 16 (16.2).
--
--  1. One helper, warehouse_security.grn_lot_rate(lot id, customer view), holds the rule get_grn_item_rates applied lot by lot: the first live
--     invoice line of the lot ('invoice', with 'varies'), else the GRN's own rate ('grn'), else find_storage_price (the customer's rate
--     'customer' or the item's default 'item'). It answers {source, unit_price, labour_rate, tax_percent, weight_min, weight_max, varies}.
--     get_grn_item_rates now calls it for every lot (the same answers as before: the same statements, moved).
--  2. A goodsreceived_trl feed row gains item_rate = that answer (customer view off) for administrators, supervisors and staff. Customer
--     accounts get none here (their view of the same helper is WH-306's).
--  3. Staff no longer receive grn_rates rows: online they read none (get_grn_details.rates is [] for them); the GRN's rate reaches them inside
--     item_rate. The entity leaves staff's list, its log rows are hidden from staff, and its row builder serves administrators, supervisors
--     and customer accounts only.
--  4. Fan-out: every input of a lot's rate re-sends the lots it reaches (staff-side roles only; a customer account gets no extra row):
--       - a grn_rates change: that GRN's lots of that item;
--       - an item_storage_prices change (the item's default rate or a customer's rate, a standard rate being the item's default rows): every
--         lot of that item, or for a customer's rate only the lots of that customer's GRNs;
--       - an invoice line added, changed (rates or dispatch line) or deleted, and an invoice cancelled, un-cancelled or deleted: the lot of
--         each line; a dispatch line added, deleted or moved to another lot: that lot; a dispatch date change: the lots of the dispatch;
--       - a goodsreceived change (date, customer, pricing mode): already re-sends every lot of the GRN.
--     The scope rides on one logged fact per change, table 'lot_rate' with a key 'lot:<lot>', 'item:<item>[:<customer>]' or
--     'grn:<GRN>:<item>', which expand() turns into the lots (so a rate change writes one log row per item, not one per lot).
--     standard_rate_tiers is not an input: find_storage_price and get_grn_item_rates never read it (it only seeds a new item's rows).
--
-- Patched by text with marker counts; no role, table, column, grant, owner, search_path or volatility changes of an existing function.

DROP FUNCTION IF EXISTS pg_temp.patch_function(regprocedure, text[], text[]);
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
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- ===== 1. the helper =====
-- The loop body of get_grn_item_rates (migrations 88, 89, 129, 134) for one lot. The rule is also in build_invoice_recalculation_rows and
-- apply_grn_rates: change all of them together.
CREATE FUNCTION warehouse_security.grn_lot_rate(p_lot_id uuid, p_customer_view boolean) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, extensions, utils, pg_temp
AS $$
DECLARE
  v_lot record; v_grn_date date; v_customer_id uuid; v_pricing_mode text; v_price_type text;
  v_source text; v_unit numeric(12,2); v_labour numeric(12,2); v_tax numeric(5,2);
  v_min integer; v_max integer; v_varies boolean := false;
  v_price item_storage_prices;
BEGIN
  SELECT grt.id, grt.gr_id, grt.item_id, grt.weight INTO v_lot FROM public.goodsreceived_trl grt WHERE grt.id = p_lot_id;
  IF v_lot.id IS NULL THEN RETURN NULL; END IF;
  SELECT warehouse_security.business_date(g.date), g.customer_id, g.pricing_mode INTO v_grn_date, v_customer_id, v_pricing_mode
    FROM public.goodsreceived g WHERE g.id = v_lot.gr_id;
  v_price_type := CASE WHEN upper(COALESCE(v_pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END;

  -- 1. The stored invoice figure: first line of the lot by dispatch date, then id.
  SELECT it.charge, it.labour_rate, it.tax INTO v_unit, v_labour, v_tax
    FROM public.invoice_trl it
    JOIN public.invoice inv ON inv.id = it.invoice_id
    JOIN public.dispatch_trl dt ON dt.id = it.disp_trl_id
    JOIN public.dispatch d ON d.id = dt.disp_id
   WHERE dt.gr_trl_id = v_lot.id
     AND inv.deleted_at IS NULL AND inv.cancelled_at IS NULL AND COALESCE(inv.notes, '') NOT LIKE '%[CANCELLED:%'
   ORDER BY d.disp_date, it.id
   LIMIT 1;
  IF FOUND THEN
    v_source := 'invoice';
    SELECT count(DISTINCT (it.charge, it.labour_rate, it.tax)) > 1 INTO v_varies
      FROM public.invoice_trl it
      JOIN public.invoice inv ON inv.id = it.invoice_id
      JOIN public.dispatch_trl dt ON dt.id = it.disp_trl_id
     WHERE dt.gr_trl_id = v_lot.id
       AND inv.deleted_at IS NULL AND inv.cancelled_at IS NULL AND COALESCE(inv.notes, '') NOT LIKE '%[CANCELLED:%';
  ELSE
    -- 2. The GRN's own rate (same query as build_invoice_recalculation_rows).
    SELECT g.unit_price, g.labour_rate, g.tax_percent, g.weight_min, g.weight_max
      INTO v_unit, v_labour, v_tax, v_min, v_max
      FROM public.grn_rates g
     WHERE g.gr_id = v_lot.gr_id AND g.item_id = v_lot.item_id
       AND g.price_type = v_price_type
       AND COALESCE(v_lot.weight, 0) BETWEEN g.weight_min AND g.weight_max
     ORDER BY (g.weight_max - g.weight_min), g.weight_min
     LIMIT 1;
    IF FOUND THEN
      v_source := 'grn';
    ELSE
      -- 3. The customer's rate, else the item's default rate.
      v_price := find_storage_price(v_lot.item_id, v_customer_id, v_lot.weight, v_grn_date, lower(v_pricing_mode));
      IF v_price.id IS NOT NULL THEN
        v_source := CASE WHEN v_price.customer_id IS NOT NULL THEN 'customer' ELSE 'item' END;
        v_unit := v_price.unit_price; v_labour := v_price.labour_rate; v_tax := v_price.tax_percent;
        v_min := v_price.weight_min; v_max := v_price.weight_max;
      ELSE
        v_unit := NULL; v_labour := NULL; v_tax := NULL; v_min := NULL; v_max := NULL;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'source', CASE WHEN p_customer_view AND v_source IN ('grn','customer','item') THEN 'customer' ELSE v_source END,
    'unit_price', v_unit, 'labour_rate', v_labour, 'tax_percent', v_tax,
    'weight_min', CASE WHEN p_customer_view THEN NULL ELSE v_min END,
    'weight_max', CASE WHEN p_customer_view THEN NULL ELSE v_max END,
    'varies', COALESCE(v_varies, false));
END $$;
ALTER FUNCTION warehouse_security.grn_lot_rate(uuid, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_lot_rate(uuid, boolean) FROM PUBLIC, anon, authenticated, service_role;

-- get_grn_item_rates: the same answer, one lot at a time through the helper.
CREATE OR REPLACE FUNCTION public.get_grn_item_rates(p_grn_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
AS $function$
DECLARE
  v_grn_date date; v_pricing_mode text; v_invoiced boolean; v_gr_id uuid;
  v_price_type text;
  v_lot record; v_rates jsonb := '[]'::jsonb;
  v_customer_view boolean;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_grn_item_rates', jsonb_build_object('p_grn_id', p_grn_id));
  -- Migration 89: a customer account sees every rate as its own (no source, no band edges).
  -- A caller with no app role (service role, database owner) is answered as staff.
  v_customer_view := COALESCE(warehouse_security.active_role() NOT IN ('admin','supervisor','staff'), false);

  SELECT g.id, warehouse_security.business_date(g.date), g.pricing_mode, COALESCE(g.invoiced, false)
    INTO v_gr_id, v_grn_date, v_pricing_mode, v_invoiced
    FROM public.goodsreceived g
   WHERE g.id = p_grn_id AND g.deleted_at IS NULL;
  IF v_gr_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'GRN not found', 'error_code', 'GRN_NOT_FOUND', 'data', NULL);
  END IF;
  v_price_type := CASE WHEN upper(COALESCE(v_pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END;

  FOR v_lot IN
    SELECT grt.id, grt.item_id, grt.item_name, grt.weight
      FROM public.goodsreceived_trl grt
     WHERE grt.gr_id = p_grn_id
     ORDER BY grt.id
  LOOP
    -- WH-348: the rule for one lot lives in warehouse_security.grn_lot_rate (also the phone copy's item_rate).
    v_rates := v_rates || jsonb_build_array(
      jsonb_build_object('grn_item_id', v_lot.id, 'item_id', v_lot.item_id, 'item_name', v_lot.item_name, 'weight', v_lot.weight)
      || warehouse_security.grn_lot_rate(v_lot.id, v_customer_view));
  END LOOP;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'gr_id', p_grn_id, 'grn_date', v_grn_date, 'price_type', v_price_type, 'invoiced', v_invoiced, 'rates', v_rates));
END;
$function$;

-- ===== 2. the feed's functions =====
-- Staff read no grn_rates row online: the entity, its log rows and its rows leave staff.
SELECT pg_temp.patch_function('warehouse_sync.entities(text)'::regprocedure, ARRAY[
$m$WHEN 'staff' THEN e NOT IN ('item_storage_prices', $m$
], ARRAY[
$m$WHEN 'staff' THEN e NOT IN ('grn_rates', 'item_storage_prices', $m$
]);

SELECT pg_temp.patch_function('warehouse_sync.staff_hidden_log_tables()'::regprocedure, ARRAY[
$m$ARRAY['item_storage_prices', $m$
], ARRAY[
$m$ARRAY['grn_rates', 'item_storage_prices', $m$
]);

SELECT pg_temp.patch_function('warehouse_sync.rows_grn_rates(text, uuid[], text[], text, integer)'::regprocedure, ARRAY[
$m$p_role IN ('admin', 'supervisor', 'staff')$m$
], ARRAY[
$m$p_role IN ('admin', 'supervisor')$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer)'::regprocedure, ARRAY[
$m$-- The one column of a lot that is not the table's: when it was last emptied (get_customer_stock_summary's time).$m$
], ARRAY[
$m$-- The rate each lot is charged at, as get_grn_item_rates answers it (WH-348 section 16): the server's answer, never worked out on a phone.
  IF p_entity = 'goodsreceived_trl' AND p_role IN ('admin', 'supervisor', 'staff') THEN
    v_cols := v_cols || ', warehouse_security.grn_lot_rate(t.id, false) AS item_rate';
  END IF;
  -- The one column of a lot that is not the table's: when it was last emptied (get_customer_stock_summary's time).$m$
]);

-- The lots a logged 'lot_rate' fact reaches (staff-side roles only: a customer account's lots carry no item_rate). The CTE casts the key
-- parts only for the rows of that table.
SELECT pg_temp.patch_function('warehouse_sync.expand(text, warehouse_sync.change_log[])'::regprocedure, ARRAY[
$m$  k AS ($m$,
$m$UNION ALL SELECT l.xid, 'invoice', v.id::text FROM l JOIN public.invoice v ON v.gr_id = l.row_key::uuid$m$
], ARRAY[
$m$  lr AS MATERIALIZED (SELECT l.xid, split_part(l.row_key, ':', 1) AS kind, split_part(l.row_key, ':', 2)::uuid AS a,
                       NULLIF(split_part(l.row_key, ':', 3), '')::uuid AS b FROM l WHERE l.tbl = 'lot_rate'),
  k AS ($m$,
$m$UNION ALL SELECT lr.xid, 'goodsreceived_trl', t.id::text FROM lr JOIN public.goodsreceived_trl t ON t.id = lr.a
      WHERE lr.kind = 'lot' AND p_role <> 'customer'
    UNION ALL SELECT lr.xid, 'goodsreceived_trl', t.id::text FROM lr JOIN public.goodsreceived_trl t ON t.item_id = lr.a
      WHERE lr.kind = 'item' AND p_role <> 'customer'
        AND (lr.b IS NULL OR EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = t.gr_id AND g.customer_id = lr.b))
    UNION ALL SELECT lr.xid, 'goodsreceived_trl', t.id::text FROM lr JOIN public.goodsreceived_trl t ON t.gr_id = lr.a AND t.item_id = lr.b
      WHERE lr.kind = 'grn' AND p_role <> 'customer'
    UNION ALL SELECT l.xid, 'invoice', v.id::text FROM l JOIN public.invoice v ON v.gr_id = l.row_key::uuid$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.affected(text)'::regprocedure, ARRAY[
$m$WHEN 'money' THEN '{}'::text[]$m$
], ARRAY[
$m$WHEN 'lot_rate' THEN ARRAY['goodsreceived_trl']
    WHEN 'grn_rates' THEN ARRAY['grn_rates', 'goodsreceived_trl']
    WHEN 'item_storage_prices' THEN ARRAY['item_storage_prices', 'goodsreceived_trl']
    WHEN 'money' THEN '{}'::text[]$m$
]);

-- Every input of a lot's rate logs one 'lot_rate' fact for the lots it reaches (see the header). The facts of one transaction are one row each.
SELECT pg_temp.patch_function('warehouse_sync.log_change()'::regprocedure, ARRAY[
$m$g uuid; ic uuid;$m$,
$m$RETURN NULL;$m$
], ARRAY[
$m$g uuid; ic uuid; lk text;$m$,
$m$-- Feed format 3: the lots whose item_rate this change can move (WH-348 section 16.2).
  FOR lk IN
    SELECT DISTINCT x FROM unnest(CASE t
      WHEN 'grn_rates' THEN ARRAY['grn:' || (o->>'gr_id') || ':' || (o->>'item_id'), 'grn:' || (n->>'gr_id') || ':' || (n->>'item_id')]
      WHEN 'item_storage_prices' THEN ARRAY['item:' || (o->>'item_id') || COALESCE(':' || (o->>'customer_id'), ''),
                                            'item:' || (n->>'item_id') || COALESCE(':' || (n->>'customer_id'), '')]
      -- A dispatch line added, deleted or moved to another lot.
      WHEN 'dispatch_trl' THEN CASE WHEN op IN ('I', 'D') OR (o->>'gr_trl_id') IS DISTINCT FROM (n->>'gr_trl_id')
          THEN ARRAY['lot:' || (o->>'gr_trl_id'), 'lot:' || (n->>'gr_trl_id')] ELSE '{}'::text[] END
      -- An invoice line added, deleted, or given other rates or another dispatch line.
      WHEN 'invoice_trl' THEN CASE WHEN op IN ('I', 'D')
            OR (o->>'charge', o->>'labour_rate', o->>'tax', o->>'disp_trl_id') IS DISTINCT FROM (n->>'charge', n->>'labour_rate', n->>'tax', n->>'disp_trl_id')
          THEN ARRAY(SELECT 'lot:' || dt.gr_trl_id FROM public.dispatch_trl dt
                      WHERE dt.id IN ((o->>'disp_trl_id')::uuid, (n->>'disp_trl_id')::uuid) AND dt.gr_trl_id IS NOT NULL) ELSE '{}'::text[] END
      -- An invoice cancelled, taken back or deleted: the lots of its lines.
      WHEN 'invoice' THEN CASE WHEN op = 'U' AND (o->>'cancelled_at', o->>'deleted_at', o->>'notes') IS DISTINCT FROM (n->>'cancelled_at', n->>'deleted_at', n->>'notes')
          THEN ARRAY(SELECT 'lot:' || dt.gr_trl_id FROM public.invoice_trl it JOIN public.dispatch_trl dt ON dt.id = it.disp_trl_id
                      WHERE it.invoice_id = (r->>'id')::uuid AND dt.gr_trl_id IS NOT NULL) ELSE '{}'::text[] END
      -- A dispatch date change: the lots of the dispatch.
      WHEN 'dispatch' THEN CASE WHEN op = 'U' AND (o->>'disp_date') IS DISTINCT FROM (n->>'disp_date')
          THEN ARRAY(SELECT 'lot:' || dt.gr_trl_id FROM public.dispatch_trl dt WHERE dt.disp_id = (r->>'id')::uuid AND dt.gr_trl_id IS NOT NULL)
          ELSE '{}'::text[] END
      ELSE '{}'::text[] END) x WHERE x IS NOT NULL LOOP
    PERFORM warehouse_sync.log_entry('lot_rate', lk, 'U', NULL, NULL, NULL, NULL);
  END LOOP;
  RETURN NULL;$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
