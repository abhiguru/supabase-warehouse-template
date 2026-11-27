-- Customer account copy, hidden invoice and order columns (WH-306, Product rule on WH-348 and WH-306: a phone's copy holds what that role's
-- screens show, no more; what the server withholds from a customer online must not reach a customer's copy). Named by topic; its number is
-- taken when the work is assembled for main. Follows 235 (accepted_by), 221 (items_total_amount) and 239 (customer_answer).
--
--  1. warehouse_sync.customer_hidden_columns() also hides: cancelled_by (invoice, orders) and ignored_by (orders); and on the invoice
--     discount_set_by, discount_reason, discount_set_at, zero_charge_set_by, zero_charge_reason, zero_charge_set_at. Online, get_invoice_data
--     answers cancelled_by and cancelled_by_name to administrators, supervisors and staff only, and get_invoice_detail adds the discount
--     and zero-charge reasons, setters, times and cancelled_by only for those roles. cancel_reason and cancelled_at stay (both are answered
--     to a customer online). The feed (entity_rows, rows_held_items) and the change-log reads take their column list from this function,
--     so no other function changes.
--  3. strip_staff_keys (239) also removes cancelled_by, cancelled_by_name, ignored_by, discount_set_by, zero_charge_set_by, discount_reason, zero_charge_reason at any depth, so a customer answer lacks the keys (get_invoice_data answered cancelled_by as null).
--  2. A customer account's invoice feed row carries items_total_amount, as migration 221 and the contract (app-offline-read-more.md 15.2)
--     say for every role: customers see the invoice amounts online and the server computes the figure. discount_set_by_name and
--     zero_charge_set_by_name stay for administrators, supervisors and staff only.
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
    IF position(p_old[i] IN p_new[i]) = 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % does not keep the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- ===== 1. the columns a customer account's copy never holds =====
SELECT pg_temp.patch_function('warehouse_sync.customer_hidden_columns()'::regprocedure, ARRAY[
$m$, 'accepted_by'$m$
], ARRAY[
$m$, 'accepted_by', 'cancelled_by', 'ignored_by', 'discount_set_by', 'discount_reason', 'discount_set_at',
   'zero_charge_set_by', 'zero_charge_reason', 'zero_charge_set_at'$m$
]);

-- ===== 2. the invoice total reaches customer accounts =====
SELECT pg_temp.patch_function('warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer)'::regprocedure, ARRAY[
$m$ELSIF p_entity = 'invoice' AND p_role <> 'customer' THEN$m$
], ARRAY[
$m$ELSIF p_entity = 'invoice' AND p_role = 'customer' THEN
    v_cols := v_cols || ', warehouse_sync.invoice_items_total(t.id) AS items_total_amount';
  ELSIF p_entity = 'invoice' AND p_role <> 'customer' THEN$m$
]);

-- ===== 3. the same keys are absent, not null, from a customer account's answers =====
-- warehouse_security.customer_answer (migration 239) wraps get_invoice_data, get_invoice_detail, get_order_with_items and get_orders_list;
-- strip_staff_keys removes keys at any depth. get_invoice_data answered cancelled_by as null to a customer: now the key is gone.
SELECT pg_temp.patch_function('warehouse_security.strip_staff_keys(jsonb)'::regprocedure, ARRAY[
$m$'created_by_info', 'created_by_display_name', 'created_by_role'$m$
], ARRAY[
$m$'created_by_info', 'created_by_display_name', 'created_by_role',
                                'cancelled_by', 'cancelled_by_name', 'ignored_by', 'discount_set_by', 'zero_charge_set_by', 'discount_reason', 'zero_charge_reason'$m$
]);

-- ===== 4. the invoice re-sent after a GRN or dispatch line change reaches customer accounts =====
-- 221 re-sends an invoice (its items_total_amount follows its lines) when a goodsreceived or dispatch_trl entry changes, for staff-side roles
-- only. A customer account now receives the figure, so the same two keys are expanded for it. Scope: caller_log passes a customer account
-- only the log rows of its own customers, and entity_rows sends only invoices of its customers that are live (customer_id = ANY, deleted_at
-- IS NULL), so no other customer's invoice reaches it.
SELECT pg_temp.patch_function('warehouse_sync.expand(text, warehouse_sync.change_log[])'::regprocedure, ARRAY[
$m$WHERE l.tbl = 'goodsreceived' AND p_role <> 'customer'$m$,
$m$WHERE l.tbl = 'dispatch_trl' AND p_role <> 'customer'$m$
], ARRAY[
$m$WHERE l.tbl = 'goodsreceived' AND p_role = 'customer'
    UNION ALL SELECT l.xid, 'invoice', v.id::text FROM l JOIN public.invoice v ON v.gr_id = l.row_key::uuid
      WHERE l.tbl = 'goodsreceived' AND p_role <> 'customer'$m$,
$m$WHERE l.tbl = 'dispatch_trl' AND p_role = 'customer'
    UNION ALL SELECT l.xid, 'invoice', it.invoice_id::text FROM l JOIN public.invoice_trl it ON it.disp_trl_id = l.row_key::uuid
      WHERE l.tbl = 'dispatch_trl' AND p_role <> 'customer'$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
