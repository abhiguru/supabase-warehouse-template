-- A dispatch carries only its own customer's lots, and a receipt that already
-- has dispatches, invoices or cart lines keeps its customer (review, 2026-10-10).
--
-- Neither dispatch write path compared the customer of each lot's receipt with
-- the dispatch header customer, so a dispatch for customer A could take customer
-- B's stock: A then read B's receipt number, item, mark and rack through the
-- dispatch reads, and B's receipt could no longer be invoiced. update_grn could
-- move a receipt to another customer while its dispatches, invoices and cart
-- lines kept the old one, with the same result.
--
-- The rule is enforced when a document is written. No constraint is added and
-- no existing row is validated or changed, so this migration applies to a
-- database that already holds mixed dispatches; the block at the end only
-- reports how many there are.

-- Dispatch creation. create_dispatch_with_stock_check_internal(jsonb,jsonb[],
-- boolean,text) is the body both granted create_dispatch_with_stock_check
-- wrappers reach. create_dispatch_with_stock_check_2arg_internal is reachable
-- only from an internal three-argument dispatcher that no granted function
-- calls; it gets the same check so it cannot become a way around the rule.
DO $patch$
DECLARE fn regprocedure; definition text; marker text; replacement text; occurrences integer;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)',
    'public.create_dispatch_with_stock_check_2arg_internal(jsonb,jsonb[])']::regprocedure[] LOOP
    definition := pg_get_functiondef(fn);
    marker := $m$    v_insufficient_stock text;$m$;
    replacement := $r$    v_insufficient_stock text;
    v_foreign_lots text;$r$;
    occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
    IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one stock-text declaration in %, found %', fn, occurrences; END IF;
    definition := replace(definition,marker,replacement);
    marker := $m$    -- STEP 2: Check stock availability (separate query, no FOR UPDATE)$m$;
    replacement := $r$    -- A dispatch carries only its own customer's lots. The receipts are
    -- key-share locked so update_grn cannot move one to another customer meanwhile.
    PERFORM gr.id
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    FOR KEY SHARE OF gr;

    SELECT string_agg(gt.item_name || ' (' || gr.gr_no || ')', ', ')
    INTO v_foreign_lots
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    WHERE gr.customer_id IS DISTINCT FROM (p_dispatch_data->>'customer_id')::uuid;

    IF v_foreign_lots IS NOT NULL THEN
        RAISE EXCEPTION 'Item belongs to another customer: %', v_foreign_lots USING ERRCODE = 'WH409';
    END IF;

    -- STEP 2: Check stock availability (separate query, no FOR UPDATE)$r$;
    occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
    IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one stock-check step in %, found %', fn, occurrences; END IF;
    EXECUTE replace(definition,marker,replacement);
  END LOOP;
END $patch$;

-- Dispatch edit. A line the edit adds must belong to the dispatch customer, and
-- the header customer may change only when every line the edit leaves belongs
-- to the new customer. Lines saved before this rule are not examined again
-- unless the customer changes, so an older mixed dispatch can still be edited.
-- The check runs before the header update; the raise reaches the function's own
-- handler, which returns the text after rolling everything back.
DO $patch$
DECLARE fn regprocedure := 'public.update_dispatch_smart(uuid,jsonb,jsonb[])'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$    v_insufficient_stock text;$m$;
  replacement := $r$    v_insufficient_stock text;
    v_foreign_lots text;$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one stock-text declaration in update_dispatch_smart, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);
  marker := $m$    -- Update dispatch header if data provided (single statement - OK)$m$;
  replacement := $r$    -- A dispatch carries only its own customer's lots: a line this edit adds
    -- must belong to the dispatch customer, and the customer may change only
    -- when every line the edit leaves belongs to the new one. The receipts are
    -- key-share locked so update_grn cannot move one to another customer meanwhile.
    PERFORM gr.id
    FROM goodsreceived gr
    WHERE gr.id IN (
        SELECT gt.gr_id
        FROM unnest(p_dispatch_items) AS new_item
        JOIN goodsreceived_trl gt ON gt.id = (new_item->>'gr_trl_id')::uuid
        UNION
        SELECT dt.gr_id FROM dispatch_trl dt WHERE dt.disp_id = p_dispatch_id
    )
    FOR KEY SHARE OF gr;

    SELECT string_agg(gt.item_name || ' (' || gr.gr_no || ')', ', ')
    INTO v_foreign_lots
    FROM dispatch d
    JOIN LATERAL (
        -- Lines the edit leaves: the new list, or the present lines when no list is sent
        SELECT (new_item->>'gr_trl_id')::uuid AS gr_trl_id
        FROM unnest(p_dispatch_items) AS new_item
        UNION
        SELECT dt.gr_trl_id FROM dispatch_trl dt
        WHERE dt.disp_id = d.id AND p_dispatch_items IS NULL
    ) AS kept ON true
    JOIN goodsreceived_trl gt ON gt.id = kept.gr_trl_id
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    WHERE d.id = p_dispatch_id
    AND gr.customer_id IS DISTINCT FROM COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id)
    AND (
        -- The header customer is changing
        d.customer_id IS DISTINCT FROM COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id)
        OR
        -- The line is being added
        NOT EXISTS (
            SELECT 1 FROM dispatch_trl dt
            WHERE dt.disp_id = d.id AND dt.gr_trl_id = kept.gr_trl_id
        )
    );

    IF v_foreign_lots IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM dispatch d
            WHERE d.id = p_dispatch_id
            AND d.customer_id IS DISTINCT FROM COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id)
        ) THEN
            RAISE EXCEPTION 'Cannot change the dispatch customer: items belong to another customer: %', v_foreign_lots USING ERRCODE = 'WH409';
        END IF;
        RAISE EXCEPTION 'Item belongs to another customer: %', v_foreign_lots USING ERRCODE = 'WH409';
    END IF;

    -- Update dispatch header if data provided (single statement - OK)$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one header-update step in update_dispatch_smart, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- Receipt edit. Dispatches, invoices and cart lines keep the customer they were
-- saved with, so a receipt that has any of them keeps its customer. Sending the
-- receipt's present customer again stays an ordinary edit. The receipt row is
-- locked first: a dispatch being saved against it holds a key-share lock, so
-- its lines are visible to the check once the lock is granted. Cart lines of a
-- deleted order do not count; nothing reads them against the receipt's customer.
DO $patch$
DECLARE fn regprocedure; definition text; marker text; replacement text; occurrences integer;
BEGIN
  SELECT p.oid::regprocedure INTO STRICT fn FROM pg_proc p
    WHERE p.pronamespace='public'::regnamespace AND p.proname='update_grn';
  definition := pg_get_functiondef(fn);
  marker := $m$    BEGIN
        PERFORM pg_advisory_xact_lock(71040);$m$;
  replacement := $r$    BEGIN
        PERFORM pg_advisory_xact_lock(71040);

        IF p_customer_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM goodsreceived
            WHERE id = p_grn_id AND customer_id IS DISTINCT FROM p_customer_id
        ) THEN
            PERFORM 1 FROM goodsreceived WHERE id = p_grn_id FOR UPDATE;

            IF EXISTS (SELECT 1 FROM dispatch_trl WHERE gr_id = p_grn_id)
               OR EXISTS (SELECT 1 FROM invoice WHERE gr_id = p_grn_id)
               OR EXISTS (
                   SELECT 1 FROM order_items oi
                   JOIN orders o ON o.id = oi.order_id
                   JOIN goodsreceived_trl gt ON gt.id = oi.grn_items_id
                   WHERE gt.gr_id = p_grn_id AND o.deleted_at IS NULL
               ) THEN
                RAISE EXCEPTION 'Cannot change the customer of a GRN that has dispatches, invoices or order items';
            END IF;
        END IF;$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one refresh-lock marker in update_grn, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- Report, do not repair: dispatch lines saved before this rule whose receipt
-- belongs to another customer than the dispatch header need an operator's
-- decision (which customer the goods really left for).
DO $report$
DECLARE mixed_lines integer; mixed_dispatches integer;
BEGIN
  SELECT count(*), count(DISTINCT d.id) INTO mixed_lines, mixed_dispatches
  FROM public.dispatch_trl dt
  JOIN public.dispatch d ON d.id = dt.disp_id
  JOIN public.goodsreceived g ON g.id = dt.gr_id
  WHERE g.customer_id IS DISTINCT FROM d.customer_id;
  IF mixed_lines > 0 THEN
    RAISE WARNING 'Migration 39: % existing dispatch line(s) on % dispatch(es) carry a receipt of another customer than the dispatch header. They are left as they are; review them.', mixed_lines, mixed_dispatches;
  END IF;
END $report$;
NOTIFY pgrst, 'reload schema';
