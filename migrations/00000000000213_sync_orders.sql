-- Sync feed, orders and order lines (WH-328, offline work step 4): topic "sync orders". Named by topic; its number is taken when the work is
-- assembled for main. Part of one feed format 3 with "sync payments", "sync order dispatch names", "stable order reads" (WH-328) and "sync GRN
-- rates", "sync item rates", "sync invoice amounts", "sync GST details" (WH-348); the payload format becomes 3 once, in the last of them
-- ("sync GST details"). Contract: the "Sync" section of docs/API_CONTRACT.md; product/tech/app-offline-orders-payments.md sections 2 and 3.
--
--  1. 'orders' and 'order_items' become feed entities of every role, loaded after invoice_trl. Migration 123 revoked the phones' direct read of
--     both tables, so each has its own row builder (warehouse_sync.rows_orders, rows_order_items); the generic builder would yield no columns.
--       orders       every column but revisions, plus updated_by_name and updated_by_display_name (the profile's name and display name,
--                    computed here: staff hold no profiles, and a customer account may have made the change).
--       order_items  every column but revisions.
--     Administrators, supervisors and staff receive every row, soft-deleted orders with deleted_at set (a staff member opens any order online:
--     is_admin_or_supervisor() is true for staff). A customer account receives the live orders of its own customers, their lines, and no column
--     of customer_hidden_columns.
--  2. log_change() logs an orders or order_items row as itself (old and new customer = the order's customer; a line whose order is gone is
--     placed by its grns_customer_id) and keeps today's grn_lock facts. A change of a line logs its order too, so the order's lines come with it.
--  3. Fan-out (warehouse_sync.expand): an orders entry carries its order_items (as a GRN carries its lots); a user_profiles entry re-sends the
--     orders whose updated_by is that profile (their updated_by_name changes with it).
--  4. The caller's log: warehouse_sync.caller_log reads its two table lists from two small functions (customer_log_tables,
--     staff_hidden_log_tables), so that each topic adds its tables by one marker patch. A customer account's list gains orders and order_items.
--
-- The functions of migration "sync change log" (and of "sync GRN invoice state and lot emptied time") are patched by text with marker counts;
-- caller_log is replaced whole (CREATE OR REPLACE keeps owner and grants). No role, table, column, grant, owner, search_path or volatility changes.

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

-- ===== 1. the row builders =====
CREATE FUNCTION warehouse_sync.rows_orders(p_role text, p_customers uuid[], p_ids text[], p_after text, p_limit integer)
 RETURNS TABLE(id text, body jsonb)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT o.id::text,
         (to_jsonb(o) - 'revisions' - CASE WHEN p_role = 'customer' THEN warehouse_sync.customer_hidden_columns() ELSE '{}'::text[] END)
           || jsonb_build_object('updated_by_name', u.name, 'updated_by_display_name', u.display_name)
    FROM public.orders o
    LEFT JOIN public.user_profiles u ON u.id = o.updated_by
   WHERE (p_role IN ('admin', 'supervisor', 'staff')
          OR (p_role = 'customer' AND o.deleted_at IS NULL AND o.customer_id = ANY (p_customers)))
     AND (p_ids IS NULL OR o.id = ANY (p_ids::uuid[]))
     AND (p_after IS NULL OR o.id > p_after::uuid)
   ORDER BY o.id LIMIT p_limit
$$;
ALTER FUNCTION warehouse_sync.rows_orders(text, uuid[], text[], text, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.rows_orders(text, uuid[], text[], text, integer) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION warehouse_sync.rows_order_items(p_role text, p_customers uuid[], p_ids text[], p_after text, p_limit integer)
 RETURNS TABLE(id text, body jsonb)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT i.id::text,
         to_jsonb(i) - 'revisions' - CASE WHEN p_role = 'customer' THEN warehouse_sync.customer_hidden_columns() ELSE '{}'::text[] END
    FROM public.order_items i
   WHERE (p_role IN ('admin', 'supervisor', 'staff')
          OR (p_role = 'customer' AND EXISTS (SELECT 1 FROM public.orders o
                WHERE o.id = i.order_id AND o.deleted_at IS NULL AND o.customer_id = ANY (p_customers))))
     AND (p_ids IS NULL OR i.id = ANY (p_ids::uuid[]))
     AND (p_after IS NULL OR i.id > p_after::uuid)
   ORDER BY i.id LIMIT p_limit
$$;
ALTER FUNCTION warehouse_sync.rows_order_items(text, uuid[], text[], text, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.rows_order_items(text, uuid[], text[], text, integer) FROM PUBLIC, anon, authenticated, service_role;

-- ===== 2. the caller's log: the two table lists as functions =====
-- The tables whose log rows a customer account receives (rows whose old or new customer is one of its own), besides the catalogue.
CREATE FUNCTION warehouse_sync.customer_log_tables() RETURNS text[]
 LANGUAGE sql IMMUTABLE SET search_path = pg_catalog
AS $$ SELECT ARRAY['customers', 'goodsreceived', 'goodsreceived_trl', 'grn_images', 'dispatch', 'dispatch_trl', 'dispatch_images',
                   'invoice', 'invoice_trl', 'money', 'orders', 'order_items'] $$;
ALTER FUNCTION warehouse_sync.customer_log_tables() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.customer_log_tables() FROM PUBLIC, anon, authenticated, service_role;

-- The tables whose log rows staff never receive.
CREATE FUNCTION warehouse_sync.staff_hidden_log_tables() RETURNS text[]
 LANGUAGE sql IMMUTABLE SET search_path = pg_catalog
AS $$ SELECT ARRAY['money', 'users_customers_new'] $$;
ALTER FUNCTION warehouse_sync.staff_hidden_log_tables() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.staff_hidden_log_tables() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION warehouse_sync.caller_log(p_role text, p_customers uuid[], p_from xid8, p_to xid8, p_limit integer)
 RETURNS SETOF warehouse_sync.change_log
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF p_role IN ('admin', 'supervisor', 'staff') THEN
    RETURN QUERY SELECT * FROM warehouse_sync.change_log l
      WHERE l.xid >= p_from AND l.xid < p_to AND (p_role <> 'staff' OR NOT l.tbl = ANY (warehouse_sync.staff_hidden_log_tables()))
      ORDER BY l.xid LIMIT p_limit;
  ELSIF p_role = 'customer' THEN
    RETURN QUERY SELECT u.* FROM (
      (SELECT * FROM warehouse_sync.change_log l WHERE l.tbl = 'items' AND l.xid >= p_from AND l.xid < p_to ORDER BY l.xid LIMIT p_limit)
      UNION
      (SELECT * FROM warehouse_sync.change_log l WHERE l.old_customer = ANY (p_customers) AND l.xid >= p_from AND l.xid < p_to
         AND l.tbl = ANY (warehouse_sync.customer_log_tables())
       ORDER BY l.xid LIMIT p_limit)
      UNION
      (SELECT * FROM warehouse_sync.change_log l WHERE l.new_customer = ANY (p_customers) AND l.xid >= p_from AND l.xid < p_to
         AND l.tbl = ANY (warehouse_sync.customer_log_tables())
       ORDER BY l.xid LIMIT p_limit)) u
      ORDER BY u.xid LIMIT p_limit;
  END IF;
END $$;

-- ===== 3. the feed's functions =====
-- entities(): orders and order_items after invoice_trl; affected(): an orders change reaches its lines, a profile change the orders it
-- last updated.
SELECT pg_temp.patch_function('warehouse_sync.entities(text)'::regprocedure, ARRAY[
$m$'invoice_trl', 'grn_lock'$m$
], ARRAY[
$m$'invoice_trl', 'orders', 'order_items', 'grn_lock'$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.affected(text)'::regprocedure, ARRAY[
$m$WHEN 'money' THEN '{}'::text[]$m$,
$m$ARRAY['user_profiles', 'people']$m$
], ARRAY[
$m$WHEN 'orders' THEN ARRAY['orders', 'order_items']
    WHEN 'money' THEN '{}'::text[]$m$,
$m$ARRAY['user_profiles', 'people', 'orders']$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer)'::regprocedure, ARRAY[
$m$ELSIF p_entity = 'users_customers_new' THEN$m$
], ARRAY[
$m$ELSIF p_entity = 'orders' THEN
    RETURN QUERY SELECT r.id, r.body FROM warehouse_sync.rows_orders(p_role, p_customers, p_ids, p_after, p_limit) r;
    RETURN;
  ELSIF p_entity = 'order_items' THEN
    RETURN QUERY SELECT r.id, r.body FROM warehouse_sync.rows_order_items(p_role, p_customers, p_ids, p_after, p_limit) r;
    RETURN;
  ELSIF p_entity = 'users_customers_new' THEN$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.expand(text, warehouse_sync.change_log[])'::regprocedure, ARRAY[
$m$ELSE l.tbl END AS e, l.row_key AS id FROM l$m$
], ARRAY[
$m$ELSE l.tbl END AS e, l.row_key AS id FROM l
    UNION ALL SELECT l.xid, 'order_items', i.id::text FROM l JOIN public.order_items i ON i.order_id = l.row_key::uuid WHERE l.tbl = 'orders'
    UNION ALL SELECT l.xid, 'orders', o.id::text FROM l JOIN public.orders o ON o.updated_by = l.row_key::uuid WHERE l.tbl = 'user_profiles'$m$
]);

-- log_change(): the entity rows of orders and order_items, after the table's own branch (which keeps logging the grn_lock facts).
SELECT pg_temp.patch_function('warehouse_sync.log_change()'::regprocedure, ARRAY[
$m$  END CASE;$m$
], ARRAY[
$m$  END CASE;
  -- Feed format 3: orders and their lines as rows of their own (the branch above keeps the lock facts).
  IF t = 'orders' THEN
    PERFORM warehouse_sync.log_entry('orders', r->>'id', op, (o->>'customer_id')::uuid, (n->>'customer_id')::uuid, NULL, NULL);
  ELSIF t = 'order_items' THEN
    -- The customer of a line is its order's; a line whose order is already gone (deleted with it) takes the GRN's, which is the same customer.
    oc := COALESCE((SELECT x.customer_id FROM public.orders x WHERE x.id = (o->>'order_id')::uuid), (o->>'grns_customer_id')::uuid);
    nc := COALESCE((SELECT x.customer_id FROM public.orders x WHERE x.id = (n->>'order_id')::uuid), (n->>'grns_customer_id')::uuid);
    PERFORM warehouse_sync.log_entry('order_items', r->>'id', op, oc, nc, NULL, NULL);
    -- The order comes with its lines (its updated_at, status and totals follow them).
    FOREACH g IN ARRAY ARRAY(SELECT DISTINCT x FROM unnest(ARRAY[(o->>'order_id')::uuid, (n->>'order_id')::uuid]) x WHERE x IS NOT NULL) LOOP
      oc := (SELECT x.customer_id FROM public.orders x WHERE x.id = g);
      PERFORM warehouse_sync.log_entry('orders', g::text, 'U', oc, oc, NULL, NULL);
    END LOOP;
  END IF;$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
