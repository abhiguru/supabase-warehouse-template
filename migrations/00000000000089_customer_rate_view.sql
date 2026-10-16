-- Migration 89: a customer account sees its GRN rates as its own rates (owner decision of 2026-10-16).
--
-- The owner: a customer must see only the rate that applies to it; the facility's default rate, when
-- that is what applies, is presented as the customer's rate, and nothing else about the default rates
-- is shown. An audit of what a customer account can read (2026-10-16) found that only
-- get_grn_item_rates (migration 88) said more: its `source` named the default rate ('item'), so a
-- customer could also tell which items have a rate of its own, and its `weight_min` / `weight_max`
-- gave the band edges of the default (or customer) rate row, not just the figures of the lot.
--
-- 1. get_grn_item_rates answers a customer account (any active role other than admin, supervisor or
--    staff) with:
--    - `source` 'customer' for every rate that is not an invoice figure ('grn', 'customer', 'item'),
--      and 'invoice' and null (no rate) unchanged;
--    - `weight_min` and `weight_max` null on every entry (the lot's own `weight` stays);
--    - the same figures, order, `varies` and header as staff get.
--    Staff, and a caller with no app role (the service role, the database owner), get the answer of
--    migration 88 unchanged.
-- Nothing else changes: the rate tables stay readable by administrators and supervisors only, and
-- every other function a customer may call returns only its own invoiced figures.

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

DO $patch$ BEGIN
  PERFORM pg_temp.patch_rpc('public.get_grn_item_rates(uuid)',
  $m$  v_price item_storage_prices;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_grn_item_rates', jsonb_build_object('p_grn_id', p_grn_id));
$m$, $r$  v_price item_storage_prices;
  v_customer_view boolean;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_grn_item_rates', jsonb_build_object('p_grn_id', p_grn_id));
  -- Migration 89: a customer account sees every rate as its own (no source, no band edges).
  -- A caller with no app role (service role, database owner) is answered as staff.
  v_customer_view := COALESCE(warehouse_security.active_role() NOT IN ('admin','supervisor','staff'), false);
$r$);
  PERFORM pg_temp.patch_rpc('public.get_grn_item_rates(uuid)',
  $m$      'source', v_source, 'unit_price', v_unit, 'labour_rate', v_labour, 'tax_percent', v_tax,
      'weight_min', v_min, 'weight_max', v_max, 'varies', COALESCE(v_varies, false)));$m$,
  $r$      'source', CASE WHEN v_customer_view AND v_source IN ('grn','customer','item') THEN 'customer' ELSE v_source END,
      'unit_price', v_unit, 'labour_rate', v_labour, 'tax_percent', v_tax,
      'weight_min', CASE WHEN v_customer_view THEN NULL ELSE v_min END,
      'weight_max', CASE WHEN v_customer_view THEN NULL ELSE v_max END,
      'varies', COALESCE(v_varies, false)));$r$);
END $patch$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
NOTIFY pgrst, 'reload schema';
