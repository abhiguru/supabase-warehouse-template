-- Sync feed, invoice amounts (WH-348, offline work step 6): topic "sync invoice amounts". Named by topic; its number is taken when the work
-- is assembled for main. Follows "sync payments"; one feed format 3 with the rest of the set, set by the last of them ("sync GST details").
-- Contract: product/tech/app-offline-read-more.md sections 0, 4 (topic 3), 7 and 14.1.
--
-- The two figures the server works out and a phone must not (decision 4: the phone never computes money):
--  1. An invoice_trl feed row gains storage_amount: the line's storage as get_invoice_detail reports it (the issued figure of an imported
--     line, else the rule of the invoice: ONE_TIME mode = charge x quantity, otherwise warehouse_security.invoice_storage_amount; null when
--     the line has no quantity left to read). Built by warehouse_sync.invoice_line_storage, which reads exactly what get_invoice_detail reads.
--     Every role that receives the line receives it.
--  2. An invoice feed row gains payment_state ({paid_amount, due_amount, payment_status}, as warehouse_security.invoice_payment_state builds
--     it) for administrators, supervisors and customer accounts; staff read no payment figure online and receive no such key.
--  3. A payment change logs its invoice (the invoice row, with its lines, is re-sent: its payment_state changed).
--  4. A change of any input of the storage figure logs the lines it reaches: the lines of the invoice (the invoice row itself logs them), of
--     the invoices of a GRN whose pricing_mode changed (a goodsreceived entry), and of the dispatch line whose quantity changed (a
--     dispatch_trl entry). The invoice's own charging rule columns change with the invoice row.
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

-- ===== 1. the line's storage figure =====
-- The expression of get_invoice_detail's items (migration 164, 178, 191 and the definition file), for one stored line.
CREATE FUNCTION warehouse_sync.invoice_line_storage(p_line public.invoice_trl) RETURNS numeric
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT CASE
           WHEN p_line.issued_storage_amount IS NOT NULL THEN p_line.issued_storage_amount
           WHEN q.qty IS NULL THEN NULL
           WHEN COALESCE(p_line.kept_pricing_mode, m.mode) = 'ONE_TIME' THEN round(COALESCE(p_line.charge, 0) * q.qty, 2)
           ELSE warehouse_security.invoice_storage_amount(p_line.invoice_id, COALESCE(p_line.charge, 0), q.qty,
                                                          COALESCE(p_line.duration, 1), p_line.no_of_days) END
    FROM (SELECT CASE WHEN p_line.details_kept_at IS NOT NULL THEN p_line.kept_disp_qty
                      ELSE (SELECT dt.disp_qty FROM public.dispatch_trl dt WHERE dt.id = p_line.disp_trl_id) END AS qty) q,
         (SELECT COALESCE((SELECT k.kept_pricing_mode FROM public.invoice_trl k
                            WHERE k.invoice_id = p_line.invoice_id AND k.kept_pricing_mode IS NOT NULL LIMIT 1),
                          (SELECT gr.pricing_mode FROM public.invoice i JOIN public.goodsreceived gr ON gr.id = i.gr_id
                            WHERE i.id = p_line.invoice_id)) AS mode) m
$$;
ALTER FUNCTION warehouse_sync.invoice_line_storage(public.invoice_trl) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.invoice_line_storage(public.invoice_trl) FROM PUBLIC, anon, authenticated, service_role;

-- ===== 2. the feed's functions =====
SELECT pg_temp.patch_function('warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer)'::regprocedure, ARRAY[
$m$-- The one column of a lot that is not the table's: when it was last emptied (get_customer_stock_summary's time).$m$
], ARRAY[
$m$-- The figures of an invoice the server works out (decision 4: a phone never does): each line's storage, and the invoice's payment state
  -- (not for staff: they read no payment figure).
  IF p_entity = 'invoice_trl' THEN
    v_cols := v_cols || ', warehouse_sync.invoice_line_storage(t) AS storage_amount';
  ELSIF p_entity = 'invoice' AND p_role <> 'staff' THEN
    v_cols := v_cols || ', warehouse_security.invoice_payment_state(t.id) AS payment_state';
  END IF;
  -- The one column of a lot that is not the table's: when it was last emptied (get_customer_stock_summary's time).$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.expand(text, warehouse_sync.change_log[])'::regprocedure, ARRAY[
$m$ELSE l.tbl END AS e, l.row_key AS id FROM l$m$
], ARRAY[
$m$ELSE l.tbl END AS e, l.row_key AS id FROM l
    UNION ALL SELECT l.xid, 'invoice_trl', it.id::text FROM l JOIN public.invoice v ON v.gr_id = l.row_key::uuid
      JOIN public.invoice_trl it ON it.invoice_id = v.id WHERE l.tbl = 'goodsreceived'
    UNION ALL SELECT l.xid, 'invoice_trl', it.id::text FROM l JOIN public.invoice_trl it ON it.disp_trl_id = l.row_key::uuid
      WHERE l.tbl = 'dispatch_trl'$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.affected(text)'::regprocedure, ARRAY[
$m$ARRAY['goodsreceived', 'goodsreceived_trl', 'grn_images', 'grn_lock', 'grn_rates']$m$,
$m$WHEN 'dispatch_trl' THEN ARRAY['dispatch_trl', 'grn_lock']$m$
], ARRAY[
$m$ARRAY['goodsreceived', 'goodsreceived_trl', 'grn_images', 'grn_lock', 'grn_rates', 'invoice_trl']$m$,
$m$WHEN 'dispatch_trl' THEN ARRAY['dispatch_trl', 'grn_lock', 'invoice_trl']$m$
]);

-- A payment change logs its invoice (payment_state), for the invoice's customer.
SELECT pg_temp.patch_function('warehouse_sync.log_change()'::regprocedure, ARRAY[
$m$og uuid; ng uuid; c uuid; g uuid;$m$,
$m$  END CASE;$m$
], ARRAY[
$m$og uuid; ng uuid; c uuid; g uuid; ic uuid;$m$,
$m$  END CASE;
  -- Feed format 3: the invoice of a payment is re-sent, its payment_state changed with it.
  IF t = 'payments' THEN
    FOREACH ic IN ARRAY ARRAY(SELECT DISTINCT x FROM unnest(ARRAY[(o->>'invoice_id')::uuid, (n->>'invoice_id')::uuid]) x WHERE x IS NOT NULL) LOOP
      oc := (SELECT x.customer_id FROM public.invoice x WHERE x.id = ic);
      PERFORM warehouse_sync.log_entry('invoice', ic::text, 'U', oc, oc, NULL, NULL);
    END LOOP;
  END IF;$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
