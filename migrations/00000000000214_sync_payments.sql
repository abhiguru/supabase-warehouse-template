-- Sync feed, payments (WH-328, offline work step 4): topic "sync payments". Named by topic; its number is taken when the work is assembled
-- for main. Follows "sync orders" (it uses the lists that migration makes); one feed format 3 with the rest of the set, set by the last of
-- them ("sync GST details"). Contract: product/tech/app-offline-orders-payments.md sections 2 and 3.
--
--  1. 'payments' becomes a feed entity of administrators, supervisors and customer accounts, loaded after order_items; staff never receive
--     it (they read no payment online). Migration 123 revoked the phones' direct read of the table, so it has its own row builder
--     (warehouse_sync.rows_payments): warehouse_security.payment_json(p), the only list of individual payments the app reads, plus
--     payment_date (the order of the list) and customer_id (the invoice's). A payment with no invoice (the old accounting link) is never
--     sent; one that loses its invoice arrives as a delete, by the rule "not returned: delete" every entity outside existing_ids follows.
--     Administrators and supervisors receive the rows of every invoice, soft-deleted ones too; a customer account the rows of its own
--     customers' live invoices, without the two staff ids of payment_json (entered_by, updated_by: the rule of customer_hidden_columns).
--  2. log_change() logs a payment as itself: old and new customer are those of the old and new invoice. Today's money marks stay.
--  3. Fan-out: an invoice entry brings the payments of that invoice to a customer account (an invoice soft-deleted or moved takes its
--     payments with it as deletes). Staff's log never carries a payments row.
--
-- The payment_state of the invoice re-sent on a payment change is "sync invoice amounts" (WH-348). Patched by text with marker counts;
-- no role, table, column, grant, owner, search_path or volatility changes.

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

-- ===== 1. the row builder =====
CREATE FUNCTION warehouse_sync.rows_payments(p_role text, p_customers uuid[], p_ids text[], p_after text, p_limit integer)
 RETURNS TABLE(id text, body jsonb)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT p.id::text,
         (warehouse_security.payment_json(p) - CASE WHEN p_role = 'customer' THEN ARRAY['entered_by', 'updated_by'] ELSE '{}'::text[] END)
           || jsonb_build_object('payment_date', p.payment_date, 'customer_id', v.customer_id)
    FROM public.payments p
    JOIN public.invoice v ON v.id = p.invoice_id
   WHERE (p_role IN ('admin', 'supervisor')
          OR (p_role = 'customer' AND v.deleted_at IS NULL AND v.customer_id = ANY (p_customers)))
     AND (p_ids IS NULL OR p.id = ANY (p_ids::uuid[]))
     AND (p_after IS NULL OR p.id > p_after::uuid)
   ORDER BY p.id LIMIT p_limit
$$;
ALTER FUNCTION warehouse_sync.rows_payments(text, uuid[], text[], text, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.rows_payments(text, uuid[], text[], text, integer) FROM PUBLIC, anon, authenticated, service_role;

-- ===== 2. the feed's functions =====
SELECT pg_temp.patch_function('warehouse_sync.entities(text)'::regprocedure, ARRAY[
$m$'order_items', 'grn_lock'$m$,
$m$WHEN 'staff' THEN e NOT IN ($m$
], ARRAY[
$m$'order_items', 'payments', 'grn_lock'$m$,
$m$WHEN 'staff' THEN e NOT IN ('payments', $m$
]);

SELECT pg_temp.patch_function('warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer)'::regprocedure, ARRAY[
$m$ELSIF p_entity = 'users_customers_new' THEN$m$
], ARRAY[
$m$ELSIF p_entity = 'payments' THEN
    RETURN QUERY SELECT r.id, r.body FROM warehouse_sync.rows_payments(p_role, p_customers, p_ids, p_after, p_limit) r;
    RETURN;
  ELSIF p_entity = 'users_customers_new' THEN$m$
]);

-- A change of an invoice brings its payments to a customer account (they leave with an invoice it may no longer read).
SELECT pg_temp.patch_function('warehouse_sync.expand(text, warehouse_sync.change_log[])'::regprocedure, ARRAY[
$m$ELSE l.tbl END AS e, l.row_key AS id FROM l$m$
], ARRAY[
$m$ELSE l.tbl END AS e, l.row_key AS id FROM l
    UNION ALL SELECT l.xid, 'payments', p.id::text FROM l JOIN public.payments p ON p.invoice_id = l.row_key::uuid
      WHERE l.tbl = 'invoice' AND p_role = 'customer'$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.affected(text)'::regprocedure, ARRAY[
$m$WHEN 'invoice' THEN ARRAY['invoice', 'invoice_trl', 'grn_lock']$m$
], ARRAY[
$m$WHEN 'invoice' THEN ARRAY['invoice', 'invoice_trl', 'grn_lock', 'payments']$m$
]);

-- Who receives the log rows: a customer account those of its customers, staff none of payments.
SELECT pg_temp.patch_function('warehouse_sync.customer_log_tables()'::regprocedure, ARRAY[
$m$ARRAY['customers', $m$
], ARRAY[
$m$ARRAY['payments', 'customers', $m$
]);

SELECT pg_temp.patch_function('warehouse_sync.staff_hidden_log_tables()'::regprocedure, ARRAY[
$m$ARRAY['money', $m$
], ARRAY[
$m$ARRAY['payments', 'money', $m$
]);

-- log_change(): the payment as a row of its own, next to the money marks its branch keeps writing.
SELECT pg_temp.patch_function('warehouse_sync.log_change()'::regprocedure, ARRAY[
$m$  END CASE;$m$
], ARRAY[
$m$  END CASE;
  -- Feed format 3: a payment as a row of its own, placed by the customers of its old and new invoice.
  IF t = 'payments' THEN
    oc := (SELECT x.customer_id FROM public.invoice x WHERE x.id = (o->>'invoice_id')::uuid);
    nc := (SELECT x.customer_id FROM public.invoice x WHERE x.id = (n->>'invoice_id')::uuid);
    PERFORM warehouse_sync.log_entry('payments', r->>'id', op, oc, nc, NULL, NULL);
  END IF;$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
