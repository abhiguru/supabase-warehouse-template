-- Migration 110: build_invoice_form_lines looks each rate and each duration up once per distinct value, as migration
-- 102 meant it to.
--
-- Migration 102 wrote the per-distinct-value steps (pairs, rates, days, dur) as CTEs, but PostgreSQL 15 folds a CTE
-- that is used once into the query that uses it. So find_storage_price and calculate_invoice_duration ran once per
-- line again (3,055 times each on Dev, GRN HVD4), and the IS NOT DISTINCT FROM joins to them became nested loops
-- (191 ms). Here:
--   * pairs, rates, days and dur are AS MATERIALIZED, so they run once per distinct (item, weight) / business date;
--   * the joins use plain equality on COALESCEd keys, which PostgreSQL can hash: goodsreceived_trl.item_id is NOT
--     NULL; weight is integer, so a NULL weight is matched through -2147483648 and a NULL business date through
--     '-infinity'. Both COALESCE values can also be stored (direct SQL can store weight -2147483648; '-infinity' can
--     be a dispatch date, though such a GRN already fails in 102 and 110 because calculate_invoice_duration raises
--     "cannot subtract infinite dates"), so each join also has an (x IS NULL) = (y IS NULL) guard, which makes both
--     joins exact; a boolean = is hashable, so the hash joins stay.
-- Measured on Dev, HVD4: find_storage_price 3,055 -> 10 runs, calculate_invoice_duration 3,055 -> 401 runs, 191 -> ~19 ms.
-- The answer is the same: same lines, same order, same figures and number formats. Signature, return type, SECURITY
-- DEFINER, search_path and the body are otherwise those of migration 102. Migrations do not record themselves
-- (the runner does), so there is no ledger statement here.

CREATE OR REPLACE FUNCTION public.build_invoice_form_lines(p_gr_id uuid, p_duration_mode text DEFAULT 'legacy')
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
DECLARE
    v_duration_mode text;
    v_grn_date date;
    v_grn_customer_id uuid;
    v_grn_pricing_mode goodsreceived.pricing_mode%TYPE;
    v_price_type text;
    v_one_time boolean;
    v_result jsonb;
BEGIN
    v_duration_mode := public.validate_invoice_duration_mode(p_duration_mode);

    SELECT warehouse_security.business_date(date), customer_id, pricing_mode
    INTO v_grn_date, v_grn_customer_id, v_grn_pricing_mode
    FROM goodsreceived
    WHERE id = p_gr_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'GRN not found');
    END IF;

    v_price_type := CASE WHEN upper(COALESCE(v_grn_pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END;
    v_one_time := v_grn_pricing_mode = 'ONE_TIME';

    WITH raw AS (
        SELECT grt.id AS grn_items_id, grt.item_id, grt.item_name, grt.qty, grt.package_mark, grt.rack, grt.weight,
               dt.id AS dt_id, dt.disp_qty, d.id AS d_id, d.disp_no, d.disp_date,
               warehouse_security.business_date(d.disp_date) AS disp_bd, i.name AS catalog_name
        FROM goodsreceived_trl grt
        JOIN dispatch_trl dt ON dt.gr_trl_id = grt.id
        JOIN dispatch d ON d.id = dt.disp_id
        LEFT JOIN items i ON i.id = grt.item_id
        WHERE grt.gr_id = p_gr_id
    ),
    pairs AS MATERIALIZED (
        SELECT DISTINCT item_id, weight FROM raw
    ),
    rates AS MATERIALIZED (
        -- One source for the three figures: the GRN's own rate, else the item's (as in migration 86).
        -- This rule is also in build_invoice_recalculation_rows and get_grn_item_rates: change all three together.
        SELECT p.item_id, p.weight,
               CASE WHEN g.id IS NOT NULL THEN g.unit_price ELSE fp.unit_price END AS src_unit,
               CASE WHEN g.id IS NOT NULL THEN g.labour_rate ELSE fp.labour_rate END AS src_labour,
               CASE WHEN g.id IS NOT NULL THEN g.tax_percent ELSE fp.tax_percent END AS src_tax
        FROM pairs p
        LEFT JOIN LATERAL (
            SELECT g2.id, g2.unit_price, g2.labour_rate, g2.tax_percent
            FROM public.grn_rates g2
            WHERE g2.gr_id = p_gr_id AND g2.item_id = p.item_id
              AND g2.price_type = v_price_type
              AND COALESCE(p.weight, 0) BETWEEN g2.weight_min AND g2.weight_max
            ORDER BY (g2.weight_max - g2.weight_min), g2.weight_min
            LIMIT 1
        ) g ON true
        LEFT JOIN LATERAL (
            SELECT f.unit_price, f.labour_rate, f.tax_percent
            FROM find_storage_price(p.item_id, v_grn_customer_id, p.weight, v_grn_date, LOWER(v_grn_pricing_mode)) f
            WHERE g.id IS NULL
        ) fp ON true
    ),
    days AS MATERIALIZED (
        SELECT DISTINCT disp_bd FROM raw
    ),
    dur AS MATERIALIZED (
        -- The duration rule lives in calculate_invoice_duration only: once per distinct business date.
        SELECT dy.disp_bd, c.no_of_days, c.billable_days, c.duration
        FROM days dy
        CROSS JOIN LATERAL public.calculate_invoice_duration(v_grn_date, dy.disp_bd, v_duration_mode) c
    ),
    lines AS (
        SELECT r.*, dur.no_of_days, dur.billable_days, dur.duration,
               u.unit_price, u.labour_rate, u.tax_percent,
               CASE WHEN v_one_time THEN ROUND(COALESCE(u.unit_price, 0) * r.disp_qty, 2)::numeric(12,2)
                    ELSE ROUND(COALESCE(u.unit_price, 0) * r.disp_qty * dur.duration, 2)::numeric(12,2) END AS storage_amount,
               CASE WHEN v_one_time THEN 0::numeric(12,2)
                    ELSE ROUND(COALESCE(u.labour_rate, 0) * r.disp_qty, 2)::numeric(12,2) END AS labour_amount
        FROM raw r
        JOIN rates rt ON rt.item_id = r.item_id
                     AND COALESCE(rt.weight, -2147483648) = COALESCE(r.weight, -2147483648)
                     AND (rt.weight IS NULL) = (r.weight IS NULL)
        JOIN dur ON COALESCE(dur.disp_bd, '-infinity'::date) = COALESCE(r.disp_bd, '-infinity'::date)
                AND (dur.disp_bd IS NULL) = (r.disp_bd IS NULL)
        CROSS JOIN LATERAL (
            SELECT rt.src_unit::numeric(12,2) AS unit_price,
                   COALESCE(rt.src_labour, 0)::numeric(12,2) AS labour_rate,
                   COALESCE(rt.src_tax, 0)::numeric(5,2) AS tax_percent
        ) u
    ),
    sums AS (
        SELECT COALESCE(sum(l.storage_amount + l.labour_amount), 0)::numeric(12,2) AS subtotal,
               COALESCE(sum((l.storage_amount + l.labour_amount) * COALESCE(l.tax_percent, 0) / 100.0), 0) AS tax_basis,
               count(*)::integer AS total_rows,
               -- A NULL amount (NULL dispatched quantity) makes the old loop's running totals NULL for good.
               COALESCE(bool_or(l.storage_amount IS NULL OR l.labour_amount IS NULL), false) AS has_null,
               COALESCE(jsonb_agg(jsonb_build_object(
                   'grn_items_id', l.grn_items_id,
                   'grn_items_item_id', l.item_id,
                   'grn_items_item_name', l.item_name,
                   'grn_items_original_qty', l.qty,
                   'grn_items_package_mark', l.package_mark,
                   'grn_items_rack', l.rack,
                   'grn_items_weight', l.weight,
                   'grn_items_pricing_mode', v_grn_pricing_mode,
                   'dispatches_items_id', l.dt_id,
                   'dispatches_items_disp_qty', l.disp_qty,
                   'dispatches_id', l.d_id,
                   'dispatches_no', l.disp_no,
                   'dispatches_date', l.disp_date,
                   'items_catalog_name', l.catalog_name,
                   'grn_date', v_grn_date,
                   'no_of_days', l.no_of_days,
                   'billable_days', l.billable_days,
                   'duration', l.duration,
                   'unit_price', l.unit_price,
                   'labour_rate', l.labour_rate,
                   'tax_percent', l.tax_percent
               ) ORDER BY l.item_name, l.disp_date, l.dt_id), '[]'::jsonb) AS items
        FROM lines l
    )
    SELECT jsonb_build_object(
        'success', true,
        'items', s.items,
        'totals', jsonb_build_object(
            'subtotal', CASE WHEN s.has_null THEN NULL ELSE s.subtotal END,
            'tax', CASE WHEN s.has_null THEN NULL ELSE CEIL(s.tax_basis)::numeric(12,2) END,
            'total_tax', CASE WHEN s.has_null THEN NULL ELSE CEIL(s.tax_basis)::numeric(12,2) END,
            'grand_total', CASE WHEN s.has_null THEN NULL ELSE CEIL(s.subtotal + CEIL(s.tax_basis)::numeric(12,2))::numeric(12,2) END,
            'total', CASE WHEN s.has_null THEN NULL ELSE CEIL(s.subtotal + CEIL(s.tax_basis)::numeric(12,2))::numeric(12,2) END,
            'total_rows', s.total_rows
        )
    ) INTO v_result
    FROM sums s;

    RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.build_invoice_form_lines(uuid, text) FROM PUBLIC, anon, authenticated, service_role;
