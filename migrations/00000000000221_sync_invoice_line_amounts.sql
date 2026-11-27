-- Sync feed, invoice line amounts (WH-348, offline work step 6): topic "sync invoice amounts", the second part (the first is the file
-- sync_invoice_amounts.sql). Named by topic; its number is taken when the work is assembled for main. Follows "sync GST details" (the eight
-- files of feed format 3); no format step: format 3 is set by that last file and is not on main yet.
-- Contract: product/tech/app-offline-read-more.md section 15 (15.1, 15.2).
--
-- The figures of get_invoice_items_detailed and get_invoice_detail that a phone must not work out (decision 4: the phone never computes money):
--  1. An invoice_trl feed row gains line_amounts {tax_amount, total_amount}: get_invoice_items_detailed's expressions for one line (the
--     issued tax of an imported line, else the tax rounded per line; base = storage under that function's rule + labour x quantity, or the
--     issued taxable value). Both are null when the line has no quantity to read. Built by warehouse_sync.invoice_line_figures, which
--     reads exactly what get_invoice_items_detailed reads, and says whether that function lists the line. Every role receives it.
--  2. An invoice feed row gains items_total_amount (that function's summary.total_amount: ROUND(SUM(total_amount), 2) over the listed
--     lines, built by warehouse_sync.invoice_items_total) and, for administrators, supervisors and staff, discount_set_by_name and
--     zero_charge_set_by_name (built as get_invoice_detail builds them, by warehouse_sync.invoice_set_by_names). Customer accounts
--     receive none of the three (they read no such name, and the contract keeps the total off their copy).
--  3. Fan-out: every entry that re-sends an invoice's lines also re-sends that invoice, so items_total_amount follows its lines: a
--     goodsreceived entry (the invoices of that GRN) and a dispatch_trl entry (the invoices of the dispatch line) through expand(), an
--     invoice_trl change through log_change() (a deleted line has no row to join). Customer accounts are not sent the extra invoice rows.
--
-- Patched by text with marker counts; no role, table, column, grant, owner, search_path or volatility changes.

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

-- ===== 1. one line's figures, and the invoice's =====
-- get_invoice_items_detailed (migrations 143, 164, 178, 191, 210) for one stored line: listed = the function lists the line; the amounts
-- are null when the line has no quantity to read.
CREATE FUNCTION warehouse_sync.invoice_line_figures(p_line public.invoice_trl)
 RETURNS TABLE(listed boolean, tax_amount numeric, total_amount numeric)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT (inv.cancelled_at IS NOT NULL OR p_line.details_kept_at IS NOT NULL
          OR (dt.id IS NOT NULL AND d.id IS NOT NULL AND gr.id IS NOT NULL AND grt.id IS NOT NULL AND catalog.id IS NOT NULL)),
         COALESCE(amount.issued_tax, ROUND(amount.base * COALESCE(p_line.tax, 0)::numeric / 100, 2)),
         amount.base + COALESCE(amount.issued_tax, ROUND(amount.base * COALESCE(p_line.tax, 0)::numeric / 100, 2))
    FROM public.invoice inv
    LEFT JOIN public.dispatch_trl dt ON dt.id = p_line.disp_trl_id
    LEFT JOIN public.dispatch d ON d.id = dt.disp_id
    LEFT JOIN public.goodsreceived gr ON gr.id = dt.gr_id
    LEFT JOIN public.goodsreceived_trl grt ON grt.id = dt.gr_trl_id
    LEFT JOIN public.items catalog ON catalog.id = grt.item_id
    LEFT JOIN public.goodsreceived igr ON igr.id = inv.gr_id
    CROSS JOIN LATERAL (
      SELECT (p_line.details_kept_at IS NOT NULL OR dt.id IS NOT NULL) AS ok,
             CASE WHEN p_line.details_kept_at IS NOT NULL THEN p_line.kept_disp_qty ELSE dt.disp_qty END AS qty,
             CASE WHEN p_line.details_kept_at IS NOT NULL THEN COALESCE(p_line.kept_pricing_mode, igr.pricing_mode) ELSE gr.pricing_mode END AS mode
    ) AS avail
    CROSS JOIN LATERAL (
      SELECT CASE WHEN NOT avail.ok THEN NULL
        WHEN p_line.issued_storage_amount IS NOT NULL THEN COALESCE(p_line.taxable_value, p_line.issued_storage_amount)
        WHEN avail.mode = 'ONE_TIME'
        THEN ROUND(COALESCE(p_line.charge, 0)::numeric * COALESCE(avail.qty, 0)::numeric, 2)
        ELSE warehouse_security.invoice_storage_amount(p_line.invoice_id, COALESCE(p_line.charge, 0)::numeric, COALESCE(avail.qty, 0)::numeric,
                                                       COALESCE(p_line.duration, 1)::numeric, p_line.no_of_days)
             + ROUND(COALESCE(p_line.labour_rate, 0)::numeric * COALESCE(avail.qty, 0)::numeric, 2)
        END AS base,
        CASE WHEN p_line.issued_storage_amount IS NOT NULL THEN p_line.line_tax END AS issued_tax
    ) AS amount
   WHERE inv.id = p_line.invoice_id
$$;
ALTER FUNCTION warehouse_sync.invoice_line_figures(public.invoice_trl) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.invoice_line_figures(public.invoice_trl) FROM PUBLIC, anon, authenticated, service_role;

-- get_invoice_items_detailed's summary.total_amount: ROUND(SUM(total_amount), 2) over the lines it lists, 0 when none.
CREATE FUNCTION warehouse_sync.invoice_items_total(p_invoice_id uuid) RETURNS numeric
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT COALESCE(ROUND(SUM(f.total_amount), 2), 0)
    FROM public.invoice_trl it CROSS JOIN LATERAL warehouse_sync.invoice_line_figures(it) f
   WHERE it.invoice_id = p_invoice_id AND f.listed
$$;
ALTER FUNCTION warehouse_sync.invoice_items_total(uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.invoice_items_total(uuid) FROM PUBLIC, anon, authenticated, service_role;

-- get_invoice_detail's two names: the history row written when the discount (zero charge) was set, else the profile's name.
CREATE FUNCTION warehouse_sync.invoice_set_by_names(p_invoice public.invoice) RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'discount_set_by_name', COALESCE(
      (SELECT h.changed_by_name FROM public.invoice_discount_history h
        WHERE h.invoice_id = p_invoice.id AND h.changed_at = p_invoice.discount_set_at ORDER BY h.id DESC LIMIT 1),
      (SELECT p.name FROM public.user_profiles p WHERE p.id = p_invoice.discount_set_by)),
    'zero_charge_set_by_name', COALESCE(
      (SELECT h.changed_by_name FROM public.invoice_zero_charge_history h
        WHERE h.invoice_id = p_invoice.id AND h.changed_at = p_invoice.zero_charge_set_at ORDER BY h.id DESC LIMIT 1),
      (SELECT p.name FROM public.user_profiles p WHERE p.id = p_invoice.zero_charge_set_by)))
$$;
ALTER FUNCTION warehouse_sync.invoice_set_by_names(public.invoice) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.invoice_set_by_names(public.invoice) FROM PUBLIC, anon, authenticated, service_role;

-- ===== 2. the feed's functions =====
SELECT pg_temp.patch_function('warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer)'::regprocedure, ARRAY[
$m$-- The one column of a lot that is not the table's: when it was last emptied (get_customer_stock_summary's time).$m$,
$m$v_cols := v_cols || ', warehouse_sync.invoice_line_storage(t) AS storage_amount';$m$
], ARRAY[
$m$-- The server's figures of an invoice line and of the invoice (WH-348 section 15): the line's tax and total, the invoice's total of its
  -- listed lines, and the names behind the discount and the zero charge (not for customer accounts).
  IF p_entity = 'invoice_trl' THEN
    v_cols := v_cols || ', (SELECT jsonb_build_object(''tax_amount'', f.tax_amount, ''total_amount'', f.total_amount)'
                     || ' FROM warehouse_sync.invoice_line_figures(t) f) AS line_amounts';
  ELSIF p_entity = 'invoice' AND p_role <> 'customer' THEN
    v_cols := v_cols || ', warehouse_sync.invoice_items_total(t.id) AS items_total_amount';
    v_extra := ' || warehouse_sync.invoice_set_by_names(t)';
  END IF;
  -- The one column of a lot that is not the table's: when it was last emptied (get_customer_stock_summary's time).$m$,
$m$v_cols := v_cols || ', warehouse_sync.invoice_line_storage(t) AS storage_amount';$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.expand(text, warehouse_sync.change_log[])'::regprocedure, ARRAY[
$m$UNION ALL SELECT l.xid, 'grn_rates', r.id::text FROM l$m$
], ARRAY[
$m$UNION ALL SELECT l.xid, 'invoice', v.id::text FROM l JOIN public.invoice v ON v.gr_id = l.row_key::uuid
      WHERE l.tbl = 'goodsreceived' AND p_role <> 'customer'
    UNION ALL SELECT l.xid, 'invoice', it.invoice_id::text FROM l JOIN public.invoice_trl it ON it.disp_trl_id = l.row_key::uuid
      WHERE l.tbl = 'dispatch_trl' AND p_role <> 'customer'
    UNION ALL SELECT l.xid, 'grn_rates', r.id::text FROM l$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.affected(text)'::regprocedure, ARRAY[
$m$ARRAY['goodsreceived', 'goodsreceived_trl', 'grn_images', 'grn_lock', 'grn_rates', 'invoice_trl']$m$,
$m$WHEN 'dispatch_trl' THEN ARRAY['dispatch_trl', 'grn_lock', 'invoice_trl']$m$,
$m$WHEN 'invoice_trl' THEN ARRAY['invoice_trl', 'grn_lock']$m$
], ARRAY[
$m$ARRAY['goodsreceived', 'goodsreceived_trl', 'grn_images', 'grn_lock', 'grn_rates', 'invoice_trl', 'invoice']$m$,
$m$WHEN 'dispatch_trl' THEN ARRAY['dispatch_trl', 'grn_lock', 'invoice_trl', 'invoice']$m$,
$m$WHEN 'invoice_trl' THEN ARRAY['invoice_trl', 'grn_lock', 'invoice']$m$
]);

-- A change of a line re-sends its invoice (items_total_amount follows the lines); a deleted line has no row to join, so it is logged here.
SELECT pg_temp.patch_function('warehouse_sync.log_change()'::regprocedure, ARRAY[
$m$-- Feed format 3: the invoice of a payment is re-sent, its payment_state changed with it.$m$
], ARRAY[
$m$-- Feed format 3: the invoice of a line is re-sent, its items_total_amount changed with it.
  IF t = 'invoice_trl' THEN
    FOREACH ic IN ARRAY ARRAY(SELECT DISTINCT x FROM unnest(ARRAY[(o->>'invoice_id')::uuid, (n->>'invoice_id')::uuid]) x WHERE x IS NOT NULL) LOOP
      oc := (SELECT x.customer_id FROM public.invoice x WHERE x.id = ic);
      PERFORM warehouse_sync.log_entry('invoice', ic::text, 'U', oc, oc, NULL, NULL);
    END LOOP;
  END IF;
  -- Feed format 3: the invoice of a payment is re-sent, its payment_state changed with it.$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
