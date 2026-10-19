-- Migration 109: get_invoice_detail returns each line's catalog item, dispatch and rack, in a fixed order.
--
-- Invoices -> an invoice -> Edit -> Next, "Step 2 of 3 · Items": when a GRN holds two different items with the
-- same package mark (or none), the edit form showed one card where Create shows two. The app groups lines by
-- dispatch id, item id and mark, but get_invoice_detail returned lines without item_id, dispatch_id or rack, so
-- every edited line had the group key ":::<mark>". The line aggregate also had no ORDER BY.
--
-- get_invoice_detail: each line object also returns
--   'item_id'     goodsreceived_trl.item_id (the catalog item; the create preview's grn_items_item_id),
--   'dispatch_id' dispatch.id (the create preview's dispatches_id / dispatch_id),
--   'rack'        goodsreceived_trl.rack (the create preview's grn_items_rack).
-- The line jsonb_agg is ordered as the invoice form's GRN preview orders them (item name, dispatch date, dispatch
-- line id; build_invoice_form_lines, migration 102), so Edit shows the cards and lines in the order Create showed.
-- No join is added (all three values come from the joined dispatch and goodsreceived_trl rows already read),
-- so no line is duplicated or dropped. Every existing key and value, the header, the signature, SECURITY
-- DEFINER, search_path, authorize_rpc, the grants and the customer-account CASE are unchanged.
-- Each marker must occur exactly once.

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
BEGIN
  PERFORM pg_temp.patch_rpc('public.get_invoice_detail(uuid)',
  $m$            'package_mark', gt.package_mark
        )
    ) INTO v_invoice_items$m$,
  $r$            'package_mark', gt.package_mark,
            'item_id', gt.item_id,
            'dispatch_id', d.id,
            'rack', gt.rack
        ) ORDER BY gt.item_name, d.disp_date, dt.id
    ) INTO v_invoice_items$r$);
END $patch$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
