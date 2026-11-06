-- Migration 148: staff can order and dispatch for a deactivated customer (WH-26).
--
-- W16: a deactivated customer's stock still goes out on orders and dispatches; only a new GRN is refused. Migration 147 lets staff pick such a
-- customer in search_customers, but two reads behind the order and dispatch screens limited staff to user_accessible_customers(), which lists
-- ACTIVE customers only:
--   * search_customer_items_for_order  answered "Access denied to customer" (the item list of an order / dispatch for that customer);
--   * get_orders_list                 left the orders of that customer out of a staff member's Orders list.
-- Administrators and supervisors never used that list in these two reads, so they already worked; a customer account keeps user_accessible_customers().
-- For the role 'staff' the set is now: what user_accessible_customers() returned before, plus every customer that is not soft-deleted
-- (so a deactivated one is included, a soft-deleted one stays out as before). user_accessible_customers() itself is NOT changed.
-- Traced and left alone: get_customer_grns_with_stock_dispatch_sorted already lets staff through (role list admin/supervisor/staff), and
-- get_customer_items_for_order_selection has no customer access check beyond authorize_rpc.
-- Only the one access line of each function is patched (DO $patch$ with a marker count, the migration 130 pattern), so signature, owner,
-- grants, SECURITY and search_path stay exactly as they are.

DO $patch$
DECLARE
  v_def text;
  v_old text[] := ARRAY[
    $m$SELECT user_accessible_customers() INTO v_accessible_customers;$m$
  ];
  v_new text[] := ARRAY[
    $m$-- Migration 148: staff also reach deactivated customers (W16); soft-deleted ones only if they were reachable before.
        IF warehouse_security.active_role() = 'staff' THEN
            SELECT ARRAY(SELECT id FROM customers WHERE active = true OR deleted_at IS NULL) INTO v_accessible_customers;
        ELSE
            SELECT user_accessible_customers() INTO v_accessible_customers;
        END IF;$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef(to_regprocedure('public.search_customer_items_for_order(text, uuid, text, integer, integer, integer, uuid, numeric, numeric)'));
  IF v_def IS NULL THEN RAISE EXCEPTION 'search_customer_items_for_order: signature not found'; END IF;
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'search_customer_items_for_order: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

DO $patch$
DECLARE
  v_def text;
  v_old text[] := ARRAY[
    $m$SELECT user_accessible_customers() INTO v_accessible_customers;$m$
  ];
  v_new text[] := ARRAY[
    $m$-- Migration 148: staff also see the orders of deactivated customers (W16); soft-deleted customers are excluded by the join below.
        IF warehouse_security.active_role() = 'staff' THEN
            SELECT ARRAY(SELECT id FROM customers WHERE active = true OR deleted_at IS NULL) INTO v_accessible_customers;
        ELSE
            SELECT user_accessible_customers() INTO v_accessible_customers;
        END IF;$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.get_orders_list(uuid, text, boolean, uuid, integer, integer, text)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'get_orders_list: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
