-- Migration 174: invoicing goods as they leave is on by default, and GRN details say whether an invoice can be made now (WH-162).
--
--  * The setting (warehouse_security.charging_rule.invoice_as_goods_leave, migration 165) defaults to true.
--  * An installation where the setting was never changed gets it turned on here; one where an administrator changed it keeps its value.
--    "Changed" is read from the audit trail: since migration 165 every change of the setting writes one audit_log row (table
--    charging_rule) whose old and new rows differ in invoice_as_goods_leave; set_charging_rule is the only way it changes. Where an audit
--    write of the charging rule failed (warehouse_security.audit_write_failures, migration 155, when present) the trail can not tell,
--    and the setting keeps its value. Turning it
--    on here is itself one such audit_log row (no user), sets updated_at and clears updated_by (the change was not an administrator's),
--    and resynchronises every GRN's cached invoiced flag exactly as set_charging_rule does when the setting changes. A fresh
--    installation runs migration 165 and then this one, so it reads on as well.
--  * No invoice is read or written: every saved invoice keeps its lines, figures and stored rule. What the setting changes from here
--    on is the rule set out in migration 165 (several invoices per GRN, the D9 stock check not made, the form offering only the
--    dispatch lines on no live invoice). The only rows written besides the setting are goodsreceived.invoiced flags of GRNs whose
--    state differs under the setting: a GRN with a live invoice that still has stock, or a dispatch line on no live invoice, reads
--    partly_invoiced (its flag goes from true to false) and becomes invoiceable for its free lines.
--  * warehouse_security.grn_invoiceable(gr_id, out_of_stock, invoiced): the rule get_invoiceable_grns lists a GRN by (migration 165:
--    with the setting on, a dispatch line on no live invoice; with it off, out of stock and not invoiced). get_invoiceable_grns now
--    calls it, so the list and the boolean below can never disagree.
--  * get_grn_details: the invoice summary gains can_create_invoice (boolean): the GRN is not deleted, get_invoiceable_grns's rule
--    holds, and it has a dispatch line on no live invoice (with the setting off the last part only drops an out-of-stock GRN that has
--    no dispatch line at all, which the invoice form would answer with "no dispatched items"). Every role reads it; the app shows
--    its button only to a role that may create invoices.
--
-- Today's behaviour (pinned; checked below before anything changes):
--   the column default is false, and the setting reads false until an administrator turns it on (migration 165);
--   get_invoiceable_grns: deleted_at IS NULL and, setting on, grn_has_free_dispatch_line; setting off, out_of_stock = true and
--   invoiced = false (migration 165's markers, found once each below); get_grn_details has no can_create_invoice.
-- Money (made-up figures, migration 165's sample): GRN of 10 bags in two lots of 5, rate 10.00 a month, no labour, receipt day 0;
-- lot A leaves on day 20 (1 month), lot B on day 50 (2 months). Before this migration (setting off): no invoice until lot B leaves,
-- then one invoice of 50.00 + 100.00 = 150.00. After it (setting on): after day 20 can_create_invoice is true and an invoice for lot A
-- is 5 x 10.00 x 1 = 50.00; the GRN reads partly_invoiced and can_create_invoice false; after day 50 an invoice for lot B is
-- 5 x 10.00 x 2 = 100.00; together 150.00, the same. Each invoice rounds its own header (migration 165: with tax 5 % on lines of 51.00
-- and 101.00 the two invoices are 54 + 107 = 161 against one invoice's 160). One-time rent: 5 bags x 40.00 = 200.00 per lot whatever
-- the days, the same split or not.

-- Section 0: today's behaviour, before anything changes.
DO $pin$
DECLARE
  v_default text;
BEGIN
  SELECT pg_get_expr(d.adbin, d.adrelid) INTO v_default
    FROM pg_attribute a JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
   WHERE a.attrelid = 'warehouse_security.charging_rule'::regclass AND a.attname = 'invoice_as_goods_leave';
  IF v_default IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'Migration 174: expected invoice_as_goods_leave to default to false (migration 165), found %', v_default;
  END IF;
  IF (SELECT count(*) FROM warehouse_security.charging_rule) <> 1 THEN
    RAISE EXCEPTION 'Migration 174: expected the one charging rule row of migration 164';
  END IF;
END
$pin$;

-- Section 1: the default.
ALTER TABLE warehouse_security.charging_rule ALTER COLUMN invoice_as_goods_leave SET DEFAULT true;
COMMENT ON COLUMN warehouse_security.charging_rule.invoice_as_goods_leave IS 'Migration 165: a GRN may have several invoices, each for dispatch lines on no other live invoice, while stock remains. On by default since migration 174.';

-- Section 2: turned on where nobody changed it.
DO $default$
DECLARE
  v_current boolean;
  v_changed boolean;
  v_flags integer;
BEGIN
  SELECT r.invoice_as_goods_leave INTO v_current FROM warehouse_security.charging_rule r WHERE r.id FOR UPDATE;
  IF v_current THEN
    RAISE NOTICE 'Migration 174: invoicing goods as they leave is already on; nothing changed.';
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.audit_log a
     WHERE a.table_name = 'charging_rule' AND a.action = 'UPDATE'
       AND (a.old_data->'invoice_as_goods_leave') IS DISTINCT FROM (a.new_data->'invoice_as_goods_leave'))
    INTO v_changed;
  IF v_changed THEN
    RAISE NOTICE 'Migration 174: an administrator changed invoicing goods as they leave; it stays off.';
    RETURN;
  END IF;
  -- A charging-rule change whose audit row could not be written (migration 155 records those) may have been this setting: the trail
  -- can not tell, so the setting keeps its value.
  IF to_regclass('warehouse_security.audit_write_failures') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM warehouse_security.audit_write_failures f WHERE f.table_name = ''charging_rule'')'
      INTO v_changed;
    IF v_changed THEN
      RAISE NOTICE 'Migration 174: an audit row of the charging rule is missing; invoicing goods as they leave stays off.';
      RETURN;
    END IF;
  END IF;

  -- The audit trigger writes one audit_log row for this change.
  UPDATE warehouse_security.charging_rule r
     SET invoice_as_goods_leave = true, updated_by = NULL, updated_at = now()
   WHERE r.id;

  -- As set_charging_rule does when the setting changes: every GRN's cached flag follows its state under the setting.
  UPDATE public.goodsreceived g SET invoiced = (warehouse_security.grn_invoice_state(g.id) = 'invoiced')
   WHERE g.invoiced IS DISTINCT FROM (warehouse_security.grn_invoice_state(g.id) = 'invoiced');
  GET DIAGNOSTICS v_flags = ROW_COUNT;
  RAISE NOTICE 'Migration 174: invoicing goods as they leave turned on; % GRN invoiced flags follow the new state.', v_flags;
END
$default$;

-- Section 3: one rule for "an invoice can be made for this GRN now".
CREATE FUNCTION warehouse_security.grn_invoiceable(p_gr_id uuid, p_out_of_stock boolean, p_invoiced boolean) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT CASE WHEN warehouse_security.invoice_as_goods_leave() THEN warehouse_security.grn_has_free_dispatch_line(p_gr_id)
              ELSE p_out_of_stock IS TRUE AND p_invoiced IS FALSE END
$$;
ALTER FUNCTION warehouse_security.grn_invoiceable(uuid, boolean, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_invoiceable(uuid, boolean, boolean) FROM PUBLIC;
COMMENT ON FUNCTION warehouse_security.grn_invoiceable(uuid, boolean, boolean) IS 'Migration 174: the rule get_invoiceable_grns lists a GRN by (deleted GRNs aside); get_grn_details answers it as can_create_invoice.';

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

-- 3.1 The list: migration 165's two CASE expressions (the page and its count) become the one rule. Same answer for every GRN.
SELECT pg_temp.patch_function('public.get_invoiceable_grns(integer, integer, text)'::regprocedure, ARRAY[
$m$          AND CASE WHEN warehouse_security.invoice_as_goods_leave() THEN warehouse_security.grn_has_free_dispatch_line(gr.id)
                   ELSE gr.out_of_stock = true AND gr.invoiced = false END$m$,
$m$      AND CASE WHEN warehouse_security.invoice_as_goods_leave() THEN warehouse_security.grn_has_free_dispatch_line(gr.id)
               ELSE gr.out_of_stock = true AND gr.invoiced = false END$m$
], ARRAY[
$m$          AND warehouse_security.grn_invoiceable(gr.id, gr.out_of_stock, gr.invoiced)  -- Migration 174: the rule get_grn_details answers.$m$,
$m$      AND warehouse_security.grn_invoiceable(gr.id, gr.out_of_stock, gr.invoiced)  -- Migration 174: the rule get_grn_details answers.$m$
]);

-- 3.2 GRN details: can_create_invoice in the invoice summary, next to migration 165's invoice_state.
SELECT pg_temp.patch_function('public.get_grn_details(uuid)'::regprocedure, ARRAY[
$m$'invoice_state', warehouse_security.grn_invoice_state(gr.id),
                            'invoices', COALESCE($m$
], ARRAY[
$m$'invoice_state', warehouse_security.grn_invoice_state(gr.id),
                            -- Migration 174: get_invoiceable_grns's rule, with a dispatch line on no live invoice.
                            'can_create_invoice', (gr.deleted_at IS NULL
                                                   AND warehouse_security.grn_invoiceable(gr.id, gr.out_of_stock, gr.invoiced)
                                                   AND warehouse_security.grn_has_free_dispatch_line(gr.id)),
                            'invoices', COALESCE($m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
