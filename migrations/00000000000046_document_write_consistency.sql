-- Document writes: one lock order, and the input rules the app already applies
-- (review, 2026-10-10).
--
--  1. Every granted function that writes customers, goodsreceived,
--     goodsreceived_trl, dispatch or dispatch_trl takes the list-refresh lock
--     (advisory lock 71040) before it locks a row. Migration 26 said the other
--     writers already did; they did not: the lock was taken by the statement
--     trigger AFTER the statement had locked its rows, so a dispatch being
--     saved, edited or deleted (rows first, 71040 second) and a receipt edit
--     (71040 first, rows second) formed a cycle that PostgreSQL ended by
--     aborting one of them. Migration 39 added a second cycle: a dispatch edit
--     key-share locked the receipt before the header update took 71040, while a
--     receipt edit that changes the customer holds 71040 and then locks the
--     receipt FOR UPDATE.
--  2. An idempotency key answers only the function and the user that stored it,
--     and a dispatch key is kept for the 24 hours it is honoured.
--  3. A receipt line needs a quantity above zero and a weight that is not
--     negative; a dispatch edit needs known lots and whole quantities above zero.
--  4. A document number made of tabs, no-break spaces or other invisible
--     characters is blank.
--  5. The receipt's customer name comes from the customer record.
--  6. Deleting a receipt records the cart lines it removes in the order history.
--  7. delete_dispatch_with_order_cleanup checks for administrator or supervisor
--     in its body, as the guard in front of it does.
--  8. The field filters of the receipt lists take '%', '_' and '\' literally,
--     as the quick search does.
--  9. Four internal dispatch functions that nothing calls are removed.

-- Text that shows nothing: empty, or only white space and invisible characters
-- (the same set migration 41 strips from a discount reason).
CREATE FUNCTION warehouse_security.is_blank_text(value text) RETURNS boolean
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT COALESCE(value, '') !~ '[^\s\u0085 ­ ᠎ -‏ -  -⁤　﻿]'
$$;
REVOKE ALL ON FUNCTION warehouse_security.is_blank_text(text) FROM PUBLIC, anon, authenticated;

-- What a user typed, as a literal inside an ILIKE pattern (see search_terms, migration 35).
CREATE FUNCTION warehouse_security.like_literal(value text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT replace(replace(replace(value, '\', '\\'), '%', '\%'), '_', '\_')
$$;
REVOKE ALL ON FUNCTION warehouse_security.like_literal(text) FROM PUBLIC, anon, authenticated;

-- 1. The refresh lock first. Each of these functions starts with its
-- authorize_rpc call; the lock follows it. update_grn has taken the lock before
-- its first write since migration 26. Later acquisitions in the same
-- transaction (the statement triggers) are reentrant.
DO $patch$
DECLARE fn regprocedure; definition text; pattern text; occurrences integer;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'public.save_grn(varchar,timestamptz,uuid,varchar,uuid,varchar,uuid,varchar,varchar,varchar,boolean,varchar,jsonb,jsonb,text,varchar)',
    'public.delete_grn_safe(uuid)',
    'public.update_dispatch_smart(uuid,jsonb,jsonb[])',
    'public.delete_dispatch_with_order_cleanup(uuid,uuid)',
    'public.save_invoice(jsonb)',
    'public.save_invoice(uuid,jsonb,jsonb[])',
    'public.update_invoice(uuid,jsonb,jsonb[])',
    'public.delete_invoice(uuid)',
    'public.create_customer(varchar,varchar,varchar,text,varchar,varchar,varchar,varchar,varchar,varchar,varchar,varchar,text[],text[])',
    'public.update_customer(uuid,varchar,varchar,varchar,text,varchar,varchar,varchar,varchar,varchar,boolean,varchar,varchar,varchar,text[])',
    'public.restore_customer(uuid)',
    'public.safe_delete_customer(uuid,boolean)']::regprocedure[] LOOP
    definition := pg_get_functiondef(fn);
    pattern := '(\n\s*PERFORM warehouse_security\.authorize_rpc\(''' ||
      (SELECT proname FROM pg_proc WHERE oid = fn) || ''',[^\n]*\n)';
    occurrences := regexp_count(definition, pattern);
    IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one authorize_rpc call in %, found %', fn, occurrences; END IF;
    IF position('pg_advisory_xact_lock(71040)' IN definition) > 0 THEN
      RAISE EXCEPTION '% already takes the refresh lock', fn;
    END IF;
    EXECUTE regexp_replace(definition, pattern,
      E'\\1    -- The list-refresh lock comes before any row lock (migration 46).\n    PERFORM pg_advisory_xact_lock(71040);\n');
  END LOOP;
END $patch$;

-- 1 and 2. Dispatch creation. create_dispatch_with_stock_check_internal(jsonb,
-- jsonb[],boolean,text) is the body both granted wrappers reach. It took the
-- lot row locks first and the refresh lock only when the dispatch header was
-- inserted. Its idempotency lookup matched the key alone for 24 hours by
-- created_at, while the stored row expired (and was removed by retention) after
-- the default hour, and it answered with whatever any function or user had
-- stored under the key.
DO $patch$
DECLARE fn regprocedure := 'public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean,text)'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$        WHERE idempotency_key = p_idempotency_key AND created_at > NOW() - INTERVAL '24 hours';$m$;
  replacement := $r$        WHERE idempotency_key = p_idempotency_key
          AND rpc_function = 'create_dispatch_with_stock_check'
          AND created_by = (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid())
          AND expires_at > NOW();$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one idempotency lookup in %, found %', fn, occurrences; END IF;
  definition := replace(definition,marker,replacement);
  marker := $m$    -- STEP 1: Lock all relevant GRN items first (no aggregation)$m$;
  replacement := $r$    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);

    -- STEP 1: Lock all relevant GRN items first (no aggregation)$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one lot-lock step in %, found %', fn, occurrences; END IF;
  definition := replace(definition,marker,replacement);
  marker := $m$        INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by)
        VALUES (p_idempotency_key, 'create_dispatch_with_stock_check', v_cached_response, v_user_id)
        ON CONFLICT (idempotency_key) DO UPDATE SET response = v_cached_response, created_at = NOW();$m$;
  replacement := $r$        -- Kept for the 24 hours a retry is answered from it. A key another
        -- function or user holds is left alone unless it has expired.
        INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
        VALUES (p_idempotency_key, 'create_dispatch_with_stock_check', v_cached_response, v_user_id, NOW() + INTERVAL '24 hours')
        ON CONFLICT (idempotency_key) DO UPDATE SET
            rpc_function = EXCLUDED.rpc_function,
            response = EXCLUDED.response,
            created_by = EXCLUDED.created_by,
            created_at = NOW(),
            expires_at = EXCLUDED.expires_at
        WHERE idempotency_keys.expires_at <= NOW()
           OR (idempotency_keys.rpc_function = EXCLUDED.rpc_function
               AND idempotency_keys.created_by IS NOT DISTINCT FROM EXCLUDED.created_by);$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one idempotency store in %, found %', fn, occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;
-- Dispatch keys stored before this migration keep the window they were given.
UPDATE public.idempotency_keys SET expires_at = created_at + INTERVAL '24 hours'
WHERE rpc_function = 'create_dispatch_with_stock_check' AND expires_at < created_at + INTERVAL '24 hours';

-- 2 to 5. Receipt creation.
DO $patch$
DECLARE fn regprocedure := 'public.save_grn(varchar,timestamptz,uuid,varchar,uuid,varchar,uuid,varchar,varchar,varchar,boolean,varchar,jsonb,jsonb,text,varchar)'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$            AND rpc_function = 'save_grn'
            AND expires_at > now();$m$;
  replacement := $r$            AND rpc_function = 'save_grn'
            AND created_by = (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid())
            AND expires_at > now();$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one idempotency lookup in save_grn, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);
  marker := $m$IF NULLIF(btrim(p_gr_no), '') IS NULL OR p_date IS NULL OR p_customer_id IS NULL THEN$m$;
  replacement := $r$IF warehouse_security.is_blank_text(p_gr_no) OR p_date IS NULL OR p_customer_id IS NULL THEN$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one required-parameter check in save_grn, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);
  marker := $m$              p_customer_id,
              p_customer_name,$m$;
  replacement := $r$              p_customer_id,
              COALESCE((SELECT name FROM customers WHERE id = p_customer_id), p_customer_name),$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one customer name value in save_grn, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);
  marker := $m$                  RAISE EXCEPTION 'Invalid item data: item_name and qty are required for item at index %', v_item_index;
              END IF;$m$;
  replacement := $r$                  RAISE EXCEPTION 'Invalid item data: item_name and qty are required for item at index %', v_item_index;
              END IF;
              IF (v_item->>'qty')::int <= 0 THEN
                  RAISE EXCEPTION 'Quantity must be greater than 0 for item at index %', v_item_index;
              END IF;
              IF (v_item->>'weight')::int < 0 THEN
                  RAISE EXCEPTION 'Weight cannot be negative for item at index %', v_item_index;
              END IF;$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one item check in save_grn, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- 3 to 5. Receipt edit. The customer name is a record of the customer at the
-- time: it follows the customer record when the receipt moves to another
-- customer and otherwise stays as it is; the name the client sends is not used.
DO $patch$
DECLARE fn regprocedure; definition text; marker text; replacement text; occurrences integer;
BEGIN
  SELECT p.oid::regprocedure INTO STRICT fn FROM pg_proc p
    WHERE p.pronamespace='public'::regnamespace AND p.proname='update_grn';
  definition := pg_get_functiondef(fn);
  marker := $m$    IF p_gr_no IS NOT NULL AND EXISTS (
        SELECT 1 FROM goodsreceived
        WHERE gr_no = p_gr_no AND id != p_grn_id
    ) THEN$m$;
  replacement := $r$    IF p_gr_no IS NOT NULL AND warehouse_security.is_blank_text(p_gr_no) THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'GRN number is required'
        );
    END IF;

    IF p_gr_no IS NOT NULL AND EXISTS (
        SELECT 1 FROM goodsreceived
        WHERE gr_no = p_gr_no AND id != p_grn_id
    ) THEN$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one duplicate-number check in update_grn, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);
  marker := $m$            customer_name = COALESCE(p_customer_name, customer_name),$m$;
  replacement := $r$            customer_name = CASE
                WHEN p_customer_id IS NOT NULL AND p_customer_id IS DISTINCT FROM customer_id
                THEN COALESCE((SELECT c.name FROM customers c WHERE c.id = p_customer_id), customer_name)
                ELSE customer_name END,$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one customer name assignment in update_grn, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);
  marker := $m$                RAISE EXCEPTION 'itemName is required for all items';
            END IF;$m$;
  replacement := $r$                RAISE EXCEPTION 'itemName is required for all items';
            END IF;
            IF (v_item->>'qty')::int <= 0 THEN
                RAISE EXCEPTION 'Quantity must be greater than 0 for item "%"', v_item_name;
            END IF;
            IF (v_item->>'weight')::int < 0 THEN
                RAISE EXCEPTION 'Weight cannot be negative for item "%"', v_item_name;
            END IF;$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one item-name check in update_grn, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- 3 and 4. Dispatch edit. Unlike creation it had no input validation: a line
-- with quantity 0 was stored, and a line whose lot does not exist was dropped
-- without a word. An empty list still removes every line. The raises reach the
-- function's own handler, which returns the text after rolling everything back.
DO $patch$
DECLARE fn regprocedure := 'public.update_dispatch_smart(uuid,jsonb,jsonb[])'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$    -- A dispatch carries only its own customer's lots: a line this edit adds$m$;
  replacement := $r$    IF p_dispatch_data->>'disp_no' IS NOT NULL AND warehouse_security.is_blank_text(p_dispatch_data->>'disp_no') THEN
        RAISE EXCEPTION 'disp_no is required' USING ERRCODE = 'WH409';
    END IF;

    -- Every line names a lot that exists and a whole quantity above zero.
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS new_item
        WHERE NOT EXISTS (
            SELECT 1 FROM goodsreceived_trl gt WHERE gt.id = (new_item->>'gr_trl_id')::uuid
        )
    ) THEN
        RAISE EXCEPTION 'Dispatch item does not exist in inventory' USING ERRCODE = 'WH409';
    END IF;
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS new_item
        WHERE new_item->>'disp_qty' IS NULL
           OR (new_item->>'disp_qty')::numeric <= 0
           OR (new_item->>'disp_qty')::numeric <> floor((new_item->>'disp_qty')::numeric)
    ) THEN
        RAISE EXCEPTION 'Dispatch quantity must be a whole number greater than 0' USING ERRCODE = 'WH409';
    END IF;

    -- A dispatch carries only its own customer's lots: a line this edit adds$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one ownership step in update_dispatch_smart, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- 4. Dispatch creation answers a blank number with its validation message; it
-- used to reach the table constraint and come back as a database error.
DO $patch$
DECLARE fn regprocedure := 'public.validate_dispatch_input(jsonb)'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$    IF v_disp_no IS NULL OR v_disp_no = '' THEN$m$;
  replacement := $r$    IF warehouse_security.is_blank_text(v_disp_no) THEN$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one disp_no check in validate_dispatch_input, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- 4. The table checks of migration 34 stripped U+0020 only. They stay NOT VALID
-- for the same reason: an installation that holds such a number still migrates.
ALTER TABLE public.goodsreceived DROP CONSTRAINT goodsreceived_gr_no_not_blank;
ALTER TABLE public.goodsreceived ADD CONSTRAINT goodsreceived_gr_no_not_blank
  CHECK (gr_no ~ '[^\s\u0085 ­ ᠎ -‏ -  -⁤　﻿]') NOT VALID;
ALTER TABLE public.dispatch DROP CONSTRAINT dispatch_disp_no_not_blank;
ALTER TABLE public.dispatch ADD CONSTRAINT dispatch_disp_no_not_blank
  CHECK (disp_no ~ '[^\s\u0085 ­ ᠎ -‏ -  -⁤　﻿]') NOT VALID;

-- 6. Deleting a receipt removes the cart lines of its lots. Each order that
-- loses a line gets an order_revisions entry with those lines at quantity 0, so
-- the order history shows where they went.
DO $patch$
DECLARE fn regprocedure := 'public.delete_grn_safe(uuid)'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$          v_order_items_deleted int := 0;$m$;
  replacement := $r$          v_order_items_deleted int := 0;
          v_removed_order_lines jsonb;$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one order-item counter in delete_grn_safe, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);
  marker := $m$          DELETE FROM order_items
          WHERE grns_id = p_grn_id
          OR grn_items_id IN (
              SELECT id FROM goodsreceived_trl WHERE gr_id = p_grn_id
          );
          GET DIAGNOSTICS v_order_items_deleted = ROW_COUNT;$m$;
  replacement := $r$          SELECT jsonb_object_agg(removed.order_id::text, removed.lines)
          INTO v_removed_order_lines
          FROM (
              SELECT oi.order_id, jsonb_agg(jsonb_build_object(
                         'item_id', oi.grn_items_item_id,
                         'item_name', oi.grn_items_item_name,
                         'quantity', 0,
                         'grn_no', oi.grns_gr_no,
                         'package_mark', oi.grn_items_package_mark
                     ) ORDER BY oi.sort_order, oi.created_at) AS lines
              FROM order_items oi
              WHERE oi.grns_id = p_grn_id
              OR oi.grn_items_id IN (
                  SELECT id FROM goodsreceived_trl WHERE gr_id = p_grn_id
              )
              GROUP BY oi.order_id
          ) AS removed;

          DELETE FROM order_items
          WHERE grns_id = p_grn_id
          OR grn_items_id IN (
              SELECT id FROM goodsreceived_trl WHERE gr_id = p_grn_id
          );
          GET DIAGNOSTICS v_order_items_deleted = ROW_COUNT;

          PERFORM warehouse_security.record_order_revision(
              removed.key::uuid,
              (SELECT id FROM user_profiles WHERE auth_user_id = v_user_id),
              'grn_deleted', '{}'::jsonb, removed.value)
          FROM jsonb_each(COALESCE(v_removed_order_lines, '{}'::jsonb)) AS removed;$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one order-item removal in delete_grn_safe, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- 7. Deleting a dispatch. The body let through anyone is_admin_or_supervisor()
-- accepts (which includes staff) and, failing that, anyone assigned to the
-- dispatch's customer; only the authorize_rpc guard in front refused them.
DO $patch$
DECLARE fn regprocedure := 'public.delete_dispatch_with_order_cleanup(uuid,uuid)'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$    IF NOT is_admin_or_supervisor() THEN
        v_accessible_customers := user_accessible_customers();
        IF NOT (v_dispatch_record.customer_id = ANY(v_accessible_customers)) THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'Access denied to this dispatch',
                'message', 'Access denied to this dispatch'
            );
        END IF;
    END IF;$m$;
  replacement := $r$    IF NOT is_admin_or_supervisor_strict() THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only administrators and supervisors can delete dispatches',
            'message', 'Only administrators and supervisors can delete dispatches'
        );
    END IF;$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one access check in delete_dispatch_with_order_cleanup, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- 8. Field filters of the receipt lists. '%' || value || '%' made '%' and '_'
-- wildcards and let a trailing '\' escape the closing '%'.
DO $patch$
DECLARE fn regprocedure; definition text; marker text; replacement text; occurrences integer; field text;
BEGIN
  fn := 'public.get_customer_grn_items(uuid,timestamptz,timestamptz,jsonb,text,text,integer,integer)'::regprocedure;
  definition := pg_get_functiondef(fn);
  FOREACH field IN ARRAY ARRAY['item_name','customer_name','gr_no','package_mark','rack'] LOOP
    marker := format($m$ILIKE '%%' || (v_filters->>'%s') || '%%')$m$, field);
    replacement := format($r$ILIKE '%%' || warehouse_security.like_literal(v_filters->>'%s') || '%%')$r$, field);
    occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
    IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one % filter in get_customer_grn_items, found %', field, occurrences; END IF;
    definition := replace(definition,marker,replacement);
  END LOOP;
  EXECUTE definition;

  fn := 'public.get_all_grn_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)'::regprocedure;
  definition := pg_get_functiondef(fn);
  marker := $m$LIKE LOWER(%L)', '%' || v_package_mark || '%'));$m$;
  replacement := $r$LIKE LOWER(%L)', '%' || warehouse_security.like_literal(v_package_mark) || '%'));$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one package filter in get_all_grn_items, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- 9. Internal dispatch functions that no function, test, script or app calls:
-- the granted wrappers pass four and five arguments and so reach
-- create_dispatch_with_stock_check_internal_3param(jsonb,jsonb[],integer,text)
-- and ..._internal_4param(jsonb,jsonb[],boolean,integer,text), which both call
-- ..._internal(jsonb,jsonb[],boolean,text). The four below were never granted.
-- The two-argument body was the only code that set orders.deleted_at, which
-- the unconditional one-cart-per-customer index cannot recover from.
DO $drop$
DECLARE dead regprocedure; caller regprocedure;
BEGIN
  FOREACH dead IN ARRAY ARRAY[
    'public.create_dispatch_with_stock_check_internal_3param(jsonb,jsonb[],integer)',
    'public.create_dispatch_with_stock_check_internal_4param(jsonb,jsonb[],boolean,integer)',
    'public.create_dispatch_with_stock_check_internal(jsonb,jsonb[],boolean)',
    'public.create_dispatch_with_stock_check_2arg_internal(jsonb,jsonb[])']::regprocedure[] LOOP
    IF has_function_privilege('authenticated', dead, 'EXECUTE') OR has_function_privilege('anon', dead, 'EXECUTE') THEN
      RAISE EXCEPTION '% is granted to an API role; it is not dead code', dead;
    END IF;
    EXECUTE format('DROP FUNCTION %s', dead);
  END LOOP;
END $drop$;
NOTIFY pgrst, 'reload schema';
