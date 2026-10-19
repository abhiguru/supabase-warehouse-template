-- Migration 101: the invoice form's GRN answer names each value once.
--
-- Migration 100 cut the answer of generate_invoice_data_for_grn_with_pricing to the lines once, 34 keys per line,
-- keeping every key the app reads, fallbacks included. Many of those are a second name for the same value: the app
-- reads `grn_items_id || grn_item_id` and so on, and the first name is always present. A GRN of 3,055 lines still
-- came to 3,467,795 bytes. This migration removes the second names that are built from the very same expression as
-- their first name in build_invoice_recalculation_rows, so they can never differ:
--
--   removed key      first-choice key (kept)         both built from
--   grn_item_id      grn_items_id                    grt.id
--   item_id          grn_items_item_id               grt.item_id
--   item_name        grn_items_item_name             grt.item_name
--   qty              dispatches_items_disp_qty       dt.disp_qty
--   package_mark     grn_items_package_mark          grt.package_mark
--   rack             grn_items_rack                  grt.rack
--   weight           grn_items_weight                grt.weight
--   dispatch_id      dispatches_id                   d.id
--   dispatch_no      dispatches_no                   d.disp_no
--   dispatch_date    dispatches_date                 d.disp_date
--   charge           unit_price                      v_unit_price
--   tax              tax_percent                     v_tax_percent
--   disp_trl_id      dispatches_items_id             dt.id
--
-- Kept although the app reads them second, because they are NOT the same expression as the key before them:
--   items_catalog_name  (items.name, a LEFT JOIN; grn_items_item_name is goodsreceived_trl.item_name, a copy kept on
--                        the receipt, which can differ after an item is renamed; the app falls back to it when the
--                        receipt's name is empty)
--   billable_days       (v_duration_record.billable_days; no_of_days is v_duration_record.no_of_days, a different
--                        column of calculate_invoice_duration; the app reads no_of_days first and billable_days second)
--
-- After this the line has 21 keys. save_invoice(jsonb), the only reader in the database of the lines of this answer
-- (create_dispatch_with_stock_check_internal returns it as 'invoice_data' and the app only passes it on), reads
-- COALESCE(disp_trl_id, dispatches_items_id, dispatch_item_id), COALESCE(charge, unit_price) and
-- COALESCE(tax, tax_percent); the first-choice name of each stays, so it reads the same values.
-- Only the key list of the one expression is extended; each marker must occur exactly once.

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
  PERFORM pg_temp.patch_rpc('public.generate_invoice_data_for_grn(uuid,text)',
  $m$'storage_amount','tax_amount','total_amount','total_dispatched'$m$,
  $r$'storage_amount','tax_amount','total_amount','total_dispatched',
                'grn_item_id','item_id','item_name','qty','package_mark','rack','weight','dispatch_id','dispatch_no',
                'dispatch_date','charge','tax','disp_trl_id'$r$);
END $patch$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
