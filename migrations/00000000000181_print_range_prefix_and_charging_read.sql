-- Migration 181 (WH-173 items 1 and 2): the print range reads a number after the facility's own prefix, and save_invoice_internal reads
-- the charging rule under lock 71040.
--  1. get_invoice_range_for_print. Before: a number that was not all digits was read as its trailing digits (migration 175), so with a
--     prefix ending in a digit the prefix's digits were read as part of the number: prefix GJ24, input GJ245 printed invoice 245, not 5.
--     Now, in this order:
--       a. an input of digits only is the number (245 is invoice 245, as before, also when the prefix is itself all digits);
--       b. an input that starts with the facility's prefix (compared in capitals, as the prefix is stored) followed by digits only is the
--          number after the prefix (GJ245 with prefix GJ24 is invoice 5; gj24005 is invoice 5);
--       c. anything else is read as before (its trailing digits, else every digit of it; INV012 is invoice 12).
--     The facility's prefix: with inv_fin_year sent, the prefix that year's invoices carry (warehouse_security.invoice_prefix_for_year,
--     migration 175: the year's own, else the rule's); without it, the numbering rule's current prefix. No prefix: a. and c. as before.
--     The allowed prefix characters do not change (WH-139).
--  2. save_invoice_internal. Before: the charging rule was read in DECLARE. Its one caller, save_invoice, takes lock 71040 before calling
--     it, and set_charging_rule takes the same lock (migration 165), so through save_invoice the read already followed the lock; a direct
--     call (service_role) took no lock at all. Now the function takes lock 71040 itself (an advisory transaction lock this transaction
--     already holds is granted at once) and reads the rule after it, so a rule change committed just before is always seen and the
--     CHARGING_CHANGED and invoice-as-goods-leave rules apply to the rule as it now is.
-- Written against the functions as migrations 119, 134, 164, 173, 175 (print range) and 123, 129, 134, 164, 165, 173, 175 (save) left
-- them. Marker-count patches: each before-text is found once.

-- Migration 180 drops its helper; this guards against an earlier file that left one behind.
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
    IF position(p_old[i] IN p_new[i]) > 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % contains the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- 1. The print range.
SELECT pg_temp.patch_function('public.get_invoice_range_for_print(text, text, integer, integer)'::regprocedure, ARRAY[
$m$    target_fin_year integer;
BEGIN$m$,
$m$THEN start_inv_no_str::integer
        ELSE COALESCE(substring(start_inv_no_str from$m$,
$m$THEN end_inv_no_str::integer
        ELSE COALESCE(substring(end_inv_no_str from$m$
], ARRAY[
$m$    target_fin_year integer;
    v_prefix text;
BEGIN
    -- Migration 181 (WH-173): the facility's own prefix, stripped before the number is read.
    v_prefix := CASE WHEN get_invoice_range_for_print.inv_fin_year IS NOT NULL
                     THEN warehouse_security.invoice_prefix_for_year(get_invoice_range_for_print.inv_fin_year)
                     ELSE COALESCE((SELECT n.prefix FROM warehouse_security.document_numbering n WHERE n.document_type = 'invoice'), '') END;$m$,
$m$THEN start_inv_no_str::integer
        WHEN v_prefix <> '' AND left(upper(start_inv_no_str), length(v_prefix)) = v_prefix
             AND substr(start_inv_no_str, length(v_prefix) + 1) ~ '^[0-9]+$'
          THEN substr(start_inv_no_str, length(v_prefix) + 1)::integer  -- Migration 181: the number after the prefix.
        ELSE COALESCE(substring(start_inv_no_str from$m$,
$m$THEN end_inv_no_str::integer
        WHEN v_prefix <> '' AND left(upper(end_inv_no_str), length(v_prefix)) = v_prefix
             AND substr(end_inv_no_str, length(v_prefix) + 1) ~ '^[0-9]+$'
          THEN substr(end_inv_no_str, length(v_prefix) + 1)::integer  -- Migration 181: the number after the prefix.
        ELSE COALESCE(substring(end_inv_no_str from$m$
]);

-- 2. The save reads the charging rule under lock 71040.
SELECT pg_temp.patch_function('public.save_invoice_internal(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$    -- Migration 164: the facility's charging rule, read once for the whole save.
    v_charging warehouse_security.charging_rule := warehouse_security.current_charging_rule();
$m$,
$m$BEGIN
    -- Migration 134: saving over the id of a cancelled invoice$m$
], ARRAY[
$m$    -- Migration 164: the facility's charging rule, read once for the whole save (since migration 181 after lock 71040, below).
    v_charging warehouse_security.charging_rule;
$m$,
$m$BEGIN
    -- Migration 181 (WH-173): the list-refresh lock that set_charging_rule takes (save_invoice already holds it; held again at once),
    -- then the rule, so a rule change committed before this save is the rule it uses.
    PERFORM pg_advisory_xact_lock(71040);
    v_charging := warehouse_security.current_charging_rule();
    -- Migration 134: saving over the id of a cancelled invoice$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
