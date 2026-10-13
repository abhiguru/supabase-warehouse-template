-- A receipt edit changes only the receipt it names, and the pricing mode of an
-- invoiced receipt stays as it was invoiced (backend review 2026-10-13, I1 and I3).
--
-- I1. update_grn read and updated each sent line by its id alone. A line id of
-- another receipt was edited in place (its name, weight, rack and, when nothing
-- was dispatched, its quantity and stock), counted as "provided", and the target
-- receipt's own lines that were not sent were then deleted as omitted. A line id
-- sent twice was applied twice; an id that exists nowhere deleted the receipt's
-- real line. Before anything is written, an edit is now refused when a line id
-- is sent more than once, or when a sent id is not a line of this receipt. The
-- line SELECT takes the row lock and is bound to the receipt, and both line
-- UPDATEs are bound to the receipt and must change exactly one row. A refusal
-- rolls back the whole edit, as every other refusal of update_grn does.
--
-- The image "keep" UPDATE is bound to the receipt as well. Its image id is
-- already looked up with grn_id = p_grn_id (migration 43), so this is a second
-- guard on the write itself, not a change in behaviour.
--
-- I3. An invoice's lines are read with the receipt's live pricing_mode
-- (get_invoice_items_detailed), while its stored total is worked out only when
-- the invoice is saved. Changing the mode of an invoiced receipt made the two
-- disagree (108.00 stored, 40.00 in the lines). The mode of a receipt that has a
-- live invoice (an invoice of the receipt, or an invoice line of one of its
-- dispatched lots) can no longer change: the existing path is to delete the
-- invoices, change the mode and invoice again. Sending the mode the receipt
-- already has (the app always sends it) is not a change; a stored null counts
-- as MONTHLY, as the invoice amounts read it.
--
-- update_grn's text is the migration-47 body; it is patched in place with its
-- owner, grants, SECURITY DEFINER and settings kept, and checked below.
DO $patch$
DECLARE
  fn regprocedure; definition text; step record; occurrences integer;
  before_secdef boolean; before_acl aclitem[]; before_config text[];
  after_secdef boolean; after_acl aclitem[]; after_config text[];
BEGIN
  SELECT p.oid::regprocedure INTO STRICT fn FROM pg_proc p
    WHERE p.pronamespace='public'::regnamespace AND p.proname='update_grn';
  SELECT prosecdef, proacl, proconfig INTO STRICT before_secdef, before_acl, before_config
    FROM pg_proc WHERE oid=fn;
  definition := pg_get_functiondef(fn);
  FOR step IN SELECT * FROM (VALUES
    (1, 1, $m$    v_result jsonb;
BEGIN$m$,
     $r$    v_result jsonb;
    v_line_rows integer;
    v_bad_line text;
BEGIN$r$),
    -- Checks before the first write (the header UPDATE follows the trigger switch).
    (2, 1, $m$        PERFORM safe_disable_grn_trl_triggers();$m$,
     $r$        IF p_pricing_mode IS NOT NULL AND EXISTS (
            SELECT 1 FROM goodsreceived
            WHERE id = p_grn_id AND COALESCE(pricing_mode, 'MONTHLY') IS DISTINCT FROM p_pricing_mode
        ) THEN
            PERFORM 1 FROM goodsreceived WHERE id = p_grn_id FOR UPDATE;

            IF EXISTS (SELECT 1 FROM invoice WHERE gr_id = p_grn_id AND deleted_at IS NULL)
               OR EXISTS (
                   SELECT 1 FROM invoice_trl it
                   JOIN dispatch_trl dt ON dt.id = it.disp_trl_id
                   JOIN invoice inv ON inv.id = it.invoice_id
                   WHERE dt.gr_id = p_grn_id AND inv.deleted_at IS NULL
               ) THEN
                RAISE EXCEPTION 'Cannot change the pricing mode of a GRN that has invoices: delete invoices first, then change the pricing mode and invoice again';
            END IF;
        END IF;

        SELECT (e->>'id')::uuid::text INTO v_bad_line
        FROM jsonb_array_elements(p_items) AS e
        WHERE e->>'id' IS NOT NULL
        GROUP BY (e->>'id')::uuid
        HAVING count(*) > 1
        LIMIT 1;
        IF v_bad_line IS NOT NULL THEN
            RAISE EXCEPTION 'A GRN line is sent more than once in this edit; reload the GRN and edit again';
        END IF;

        SELECT x.e->>'id' INTO v_bad_line
        FROM jsonb_array_elements(p_items) WITH ORDINALITY AS x(e, n)
        WHERE x.e->>'id' IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM goodsreceived_trl t
              WHERE t.id = (x.e->>'id')::uuid AND t.gr_id = p_grn_id
          )
        ORDER BY x.n
        LIMIT 1;
        IF v_bad_line IS NOT NULL THEN
            RAISE EXCEPTION 'GRN line % is not a line of this GRN; reload the GRN and edit again', v_bad_line;
        END IF;

        PERFORM safe_disable_grn_trl_triggers();$r$),
    (3, 1, $m$                FROM goodsreceived_trl
                WHERE id = (v_item->>'id')::uuid;$m$,
     $r$                FROM goodsreceived_trl
                WHERE id = (v_item->>'id')::uuid AND gr_id = p_grn_id
                FOR UPDATE;

                IF NOT FOUND THEN
                    RAISE EXCEPTION 'GRN line % is not a line of this GRN; reload the GRN and edit again', v_item->>'id';
                END IF;$r$),
    -- Both line UPDATEs (undispatched and dispatched lot).
    (4, 2, $m$                    WHERE id = (v_item->>'id')::uuid;

                    v_items_updated := v_items_updated + 1;$m$,
     $r$                    WHERE id = (v_item->>'id')::uuid AND gr_id = p_grn_id;

                    GET DIAGNOSTICS v_line_rows = ROW_COUNT;
                    IF v_line_rows <> 1 THEN
                        RAISE EXCEPTION 'GRN line % is not a line of this GRN; reload the GRN and edit again', v_item->>'id';
                    END IF;

                    v_items_updated := v_items_updated + 1;$r$),
    (5, 1, $m$                    UPDATE grn_images SET
                        grn_item_id = v_resolved_item_id,
                        updated_at = now()
                    WHERE id = v_image_id;$m$,
     $r$                    UPDATE grn_images SET
                        grn_item_id = v_resolved_item_id,
                        updated_at = now()
                    WHERE id = v_image_id AND grn_id = p_grn_id;$r$)
  ) AS s(step_no, expected, marker, replacement) ORDER BY step_no
  LOOP
    occurrences := (length(definition)-length(replace(definition,step.marker,'')))/length(step.marker);
    IF occurrences <> step.expected THEN
      RAISE EXCEPTION 'GRN edit integrity patch %: expected % marker(s) in update_grn, found %',
        step.step_no, step.expected, occurrences;
    END IF;
    definition := replace(definition, step.marker, step.replacement);
  END LOOP;
  EXECUTE definition;

  SELECT prosecdef, proacl, proconfig INTO STRICT after_secdef, after_acl, after_config
    FROM pg_proc WHERE oid=fn;
  IF NOT after_secdef OR after_secdef IS DISTINCT FROM before_secdef THEN
    RAISE EXCEPTION 'update_grn is no longer SECURITY DEFINER';
  END IF;
  IF after_acl IS DISTINCT FROM before_acl THEN
    RAISE EXCEPTION 'update_grn grants changed: % became %', before_acl, after_acl;
  END IF;
  IF after_config IS DISTINCT FROM before_config THEN
    RAISE EXCEPTION 'update_grn settings changed: % became %', before_config, after_config;
  END IF;
  IF position('is not a line of this GRN' IN pg_get_functiondef(fn)) = 0
     OR position('Cannot change the pricing mode of a GRN that has invoices' IN pg_get_functiondef(fn)) = 0 THEN
    RAISE EXCEPTION 'update_grn was not patched';
  END IF;
END $patch$;

-- Report only: saved invoices whose stored total differs from a recomputation of
-- their lines under the receipt's current pricing mode (the formula of
-- warehouse_security.recalculate_invoice_header, migration 48). The cause can be
-- a pricing-mode change before this migration, an invoice saved before migration
-- 48, or another difference; nothing is altered here. To correct one, open and
-- save it again (or delete it and invoice again).
DO $report$
DECLARE mismatched integer;
BEGIN
  SELECT count(*) INTO mismatched FROM (
    SELECT i.id, i.total, COALESCE(i.discount,0) AS discount,
           sum(CASE WHEN gr.pricing_mode='ONE_TIME'
                 THEN round(COALESCE(it.charge,0)*dt.disp_qty,2)
                 ELSE round(COALESCE(it.charge,0)*dt.disp_qty*COALESCE(it.duration,1),2)
                      + round(COALESCE(it.labour_rate,0)*dt.disp_qty,2) END) AS subtotal,
           sum(CASE WHEN gr.pricing_mode='ONE_TIME'
                 THEN round(COALESCE(it.charge,0)*dt.disp_qty,2)
                 ELSE round(COALESCE(it.charge,0)*dt.disp_qty*COALESCE(it.duration,1),2)
                      + round(COALESCE(it.labour_rate,0)*dt.disp_qty,2) END * COALESCE(it.tax,0)/100.0) AS tax_basis
    FROM public.invoice i
    JOIN public.invoice_trl it ON it.invoice_id=i.id
    JOIN public.dispatch_trl dt ON dt.id=it.disp_trl_id
    JOIN public.goodsreceived gr ON gr.id=dt.gr_id
    WHERE i.deleted_at IS NULL
    GROUP BY i.id, i.total, i.discount
  ) s
  WHERE s.total IS DISTINCT FROM ceil(s.subtotal + ceil(s.tax_basis) - s.discount);
  IF mismatched > 0 THEN
    RAISE WARNING 'Migration 65: % saved invoice(s) have a stored total that differs from a recomputation of its lines under the receipt''s current pricing mode (any cause: a pricing-mode change before this migration, an invoice saved before migration 48, or another difference); nothing is changed. Review them (open and save again, or delete and invoice again).', mismatched;
  ELSE
    RAISE NOTICE 'Migration 65: no saved invoice has a stored total that differs from a recomputation of its lines under the receipt''s current pricing mode';
  END IF;
END $report$;
NOTIFY pgrst, 'reload schema';
