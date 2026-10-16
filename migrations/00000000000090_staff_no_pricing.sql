-- Migration 90: staff accounts lose item pricing (owner decision of 2026-10-16).
--
-- The owner: item pricing is for administrators and supervisors. A staff account may no longer read
-- or write item rates, customer rates, the standard rate or the rates of a GRN, nor type rates on
-- the GRN sheet. This supersedes the staff access of 11 October 2026 (migrations 45, 76, 85, 86).
--
-- 1. warehouse_security.authorize_rpc: the staff list no longer names get_item_storage_prices,
--    create_item_storage_price, update_item_storage_price, delete_item_storage_price,
--    replace_item_rates, undo_rate_change, get_standard_rate, set_standard_rate or
--    get_item_grn_rates. A staff call to one of them is refused as any call outside the list:
--    'Staff access required', SQLSTATE 42501. Administrators and supervisors return earlier and are
--    untouched. The list keeps get_grn_item_rates (migration 88: the rate each line of a GRN is
--    invoiced at, the staff answer unchanged) and generate_invoice_data_for_grn_with_pricing (the
--    invoice preview), so staff still invoice.
-- 2. save_grn and update_grn: a staff call that carries p_rates (any non-NULL list, `[]` included)
--    is answered { success: false, error_code: 'RATES_MANAGER_ONLY' } before anything is written.
--    A call without p_rates is untouched.
-- 3. get_grn_details: grn.rates is [] for staff, as for customers (administrators, supervisors and
--    the service role get the rates as before).
-- Not changed: the bodies' own staff branches that are now unreachable (migration 76 and 85); the
-- row policies (the rate tables are already readable by administrators and supervisors only).
-- The app release that hides these screens from staff must go first or together with this one.

-- Replaces one marker in a function body, failing unless it occurs exactly
-- `expected` times. Dropped at the end of this migration.
CREATE FUNCTION pg_temp.patch_rpc(fn regprocedure, marker text, replacement text, expected integer DEFAULT 1) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE definition text := pg_get_functiondef(fn); occurrences integer;
BEGIN
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker,80);
  END IF;
  EXECUTE replace(definition,marker,replacement);
END $$;

DO $patch$
DECLARE
  save_grn_fn regprocedure;
  update_grn_fn regprocedure;
BEGIN
  -- 1. The staff list of the guard.
  PERFORM pg_temp.patch_rpc('warehouse_security.authorize_rpc(text,jsonb)',
  $m$    -- Item pricing, read and write (owner decision, 2026-10-11; supersedes
    -- the refusal of migration 23).
    'get_item_storage_prices',
    'create_item_storage_price','update_item_storage_price','delete_item_storage_price',
    -- A change "from a date" (migration 76).
    'replace_item_rates',
    'undo_rate_change',
$m$, $r$    -- Item pricing is for administrators and supervisors (migration 90); staff keep
    -- only the rates a GRN is invoiced at (migration 88, below).
$r$);
  PERFORM pg_temp.patch_rpc('warehouse_security.authorize_rpc(text,jsonb)',
  $m$    -- The facility's standard rate (migration 85); set_standard_rate refuses staff in its body.
    'get_standard_rate','set_standard_rate',
    -- The GRN-only rates of an item (migration 86).
    'get_item_grn_rates',
$m$, $r$$r$);

  -- 2. p_rates is a manager's input.
  SELECT p.oid::regprocedure INTO STRICT save_grn_fn FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'save_grn';
  SELECT p.oid::regprocedure INTO STRICT update_grn_fn FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'update_grn';
  PERFORM pg_temp.patch_rpc(save_grn_fn,
  $m$  PERFORM warehouse_security.authorize_rpc('save_grn',jsonb_build_object('p_customer_id',p_customer_id));
$m$, $r$  PERFORM warehouse_security.authorize_rpc('save_grn',jsonb_build_object('p_customer_id',p_customer_id));
  -- Migration 90: rates typed on the GRN sheet are an administrator's or a supervisor's.
  IF p_rates IS NOT NULL AND warehouse_security.active_role() = 'staff' THEN
    RETURN warehouse_security.rate_failure('RATES_MANAGER_ONLY', 'Only administrators and supervisors can set rates on a GRN');
  END IF;
$r$);
  PERFORM pg_temp.patch_rpc(update_grn_fn,
  $m$  PERFORM warehouse_security.authorize_rpc('update_grn',jsonb_build_object('p_grn_id',p_grn_id,'p_customer_id',p_customer_id));
$m$, $r$  PERFORM warehouse_security.authorize_rpc('update_grn',jsonb_build_object('p_grn_id',p_grn_id,'p_customer_id',p_customer_id));
  -- Migration 90: rates typed on the GRN sheet are an administrator's or a supervisor's.
  IF p_rates IS NOT NULL AND warehouse_security.active_role() = 'staff' THEN
    RETURN warehouse_security.rate_failure('RATES_MANAGER_ONLY', 'Only administrators and supervisors can set rates on a GRN');
  END IF;
$r$);

  -- 3. get_grn_details: grn.rates is [] for staff.
  PERFORM pg_temp.patch_rpc('public.get_grn_details(uuid)',
  $m$'rates', CASE WHEN v_role IN ('admin', 'supervisor', 'staff') OR auth.jwt() ->> 'role' = 'service_role'$m$,
  $r$'rates', CASE WHEN v_role IN ('admin', 'supervisor') OR auth.jwt() ->> 'role' = 'service_role'$r$);
END $patch$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
NOTIFY pgrst, 'reload schema';
