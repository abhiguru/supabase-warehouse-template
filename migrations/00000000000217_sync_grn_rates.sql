-- Sync feed, GRN rates (WH-348, offline work step 6): topic "sync GRN rates". Named by topic; its number is taken when the work is assembled
-- for main. Follows "sync payments" (the entity list); one feed format 3 with the rest of the set, set by the last of them
-- ("sync GST details"). Contract: product/tech/app-offline-read-more.md sections 4, 7 and 14.1.
--
--  1. 'grn_rates' becomes a feed entity of administrators, supervisors, staff (they read a GRN's rates online through get_grn_item_rates,
--     migration 88) and customer accounts, loaded after payments. Migration 123 revoked the phones' direct read of the table, so it has its
--     own row builder (warehouse_sync.rows_grn_rates): every column, id as text. A customer account receives only the rows of the live GRNs
--     of its own customers, without the columns of customer_hidden_columns (created_by, updated_by).
--  2. log_change() logs a grn_rates row as itself (old and new customer = the GRN's) next to the grn_lock fact its branch keeps writing.
--  3. Fan-out: a goodsreceived entry brings the rates of that GRN to a customer account (a GRN deleted or moved takes its rates with it as
--     deletes). Staff-side roles receive a rate row on its own change.
--
-- Patched by text with marker counts; no role, table, column, grant, owner, search_path or volatility changes.

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
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- ===== 1. the row builder =====
CREATE FUNCTION warehouse_sync.rows_grn_rates(p_role text, p_customers uuid[], p_ids text[], p_after text, p_limit integer)
 RETURNS TABLE(id text, body jsonb)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT r.id::text,
         to_jsonb(r) - CASE WHEN p_role = 'customer' THEN warehouse_sync.customer_hidden_columns() ELSE '{}'::text[] END
    FROM public.grn_rates r
   WHERE (p_role IN ('admin', 'supervisor', 'staff')
          OR (p_role = 'customer' AND EXISTS (SELECT 1 FROM public.goodsreceived g
                WHERE g.id = r.gr_id AND g.deleted_at IS NULL AND g.customer_id = ANY (p_customers))))
     AND (p_ids IS NULL OR r.id = ANY (p_ids::uuid[]))
     AND (p_after IS NULL OR r.id > p_after::uuid)
   ORDER BY r.id LIMIT p_limit
$$;
ALTER FUNCTION warehouse_sync.rows_grn_rates(text, uuid[], text[], text, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.rows_grn_rates(text, uuid[], text[], text, integer) FROM PUBLIC, anon, authenticated, service_role;

-- ===== 2. the feed's functions =====
SELECT pg_temp.patch_function('warehouse_sync.entities(text)'::regprocedure, ARRAY[
$m$'payments', 'grn_lock'$m$
], ARRAY[
$m$'payments', 'grn_rates', 'grn_lock'$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer)'::regprocedure, ARRAY[
$m$ELSIF p_entity = 'users_customers_new' THEN$m$
], ARRAY[
$m$ELSIF p_entity = 'grn_rates' THEN
    RETURN QUERY SELECT r.id, r.body FROM warehouse_sync.rows_grn_rates(p_role, p_customers, p_ids, p_after, p_limit) r;
    RETURN;
  ELSIF p_entity = 'users_customers_new' THEN$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.expand(text, warehouse_sync.change_log[])'::regprocedure, ARRAY[
$m$ELSE l.tbl END AS e, l.row_key AS id FROM l$m$
], ARRAY[
$m$ELSE l.tbl END AS e, l.row_key AS id FROM l
    UNION ALL SELECT l.xid, 'grn_rates', r.id::text FROM l JOIN public.grn_rates r ON r.gr_id = l.row_key::uuid
      WHERE l.tbl = 'goodsreceived' AND p_role = 'customer'$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.affected(text)'::regprocedure, ARRAY[
$m$ARRAY['goodsreceived', 'goodsreceived_trl', 'grn_images', 'grn_lock']$m$
], ARRAY[
$m$ARRAY['goodsreceived', 'goodsreceived_trl', 'grn_images', 'grn_lock', 'grn_rates']$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.customer_log_tables()'::regprocedure, ARRAY[
$m$ARRAY['payments', $m$
], ARRAY[
$m$ARRAY['grn_rates', 'payments', $m$
]);

SELECT pg_temp.patch_function('warehouse_sync.log_change()'::regprocedure, ARRAY[
$m$  END CASE;$m$
], ARRAY[
$m$  END CASE;
  -- Feed format 3: a GRN rate as a row of its own, placed by the customer of its GRN (the branch above keeps the lock fact).
  IF t = 'grn_rates' THEN
    oc := (SELECT x.customer_id FROM public.goodsreceived x WHERE x.id = (o->>'gr_id')::uuid);
    nc := (SELECT x.customer_id FROM public.goodsreceived x WHERE x.id = (n->>'gr_id')::uuid);
    PERFORM warehouse_sync.log_entry('grn_rates', r->>'id', op, oc, nc, NULL, NULL);
  END IF;$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
