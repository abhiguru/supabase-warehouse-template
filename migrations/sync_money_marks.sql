-- Sync feed, money marks for goods, rates and settings (WH-305, offline work): topic "sync money marks". Named by topic; its number is taken when
-- the work is assembled for main. THE LAST MIGRATION OF FEED FORMAT 6: it sets the payload format to 6. Formats 4 (grn replacements, WH-303) and
-- 5 (held items, WH-304) are built on other branches; assembly stacks them first. Contract: product/tech/app-offline-dues-statement.md sections 7 and 12.
--
-- The server only says WHICH customers' kept answers are out of date; it works out no amount. The mark's shape is unchanged
-- ({e: 'money', id, op: 'stale'}), so an older app applies a newer feed unharmed.
--
--  1. log_change() writes a money mark (change_log tbl 'money', row_key = the customer id, old = new = that customer) for the old and the new
--     customer of every INSERT, UPDATE and DELETE on goodsreceived, goodsreceived_trl, dispatch, dispatch_trl and grn_rates (the customer of
--     the row, or of its GRN or dispatch), and on customers when it is created, deleted, or its name or active flag changes.
--  2. It writes one mark with row_key 'all' (both customers NULL; one per transaction) for any change of item_storage_prices, of the charging
--     rule table (which also holds the record-payments setting) and of the system_settings row 'facility_legal' (the GST settings).
--  3. caller_log(): a customer account also receives every 'all' money mark (its customer filter alone would drop a row with no customer).
--     Staff receive none: 'money' stays in staff_hidden_log_tables(). Administrator and supervisor receive every mark.
--  4. The payload format becomes 6: a copy key of format 5 answers reload_all FORMAT_CHANGED.
--
-- log_change() is patched by text with marker counts; caller_log is replaced whole (CREATE OR REPLACE keeps owner and grants). No role, table,
-- column, grant, owner, search_path or volatility changes. The triggers on all nine tables exist already.

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

-- ===== 1 and 2. what logs the marks =====
SELECT pg_temp.patch_function('warehouse_sync.log_change()'::regprocedure, ARRAY[
$m$g uuid; ic uuid; lk text;$m$,
$m$RETURN NULL;$m$
], ARRAY[
$m$g uuid; ic uuid; lk text; mk uuid[]; mall boolean := false;$m$,
$m$-- Feed format 6: money marks. Which customers' kept answers this change makes out of date (nothing is worked out here).
  mk := '{}';
  CASE t
    WHEN 'goodsreceived', 'dispatch' THEN
      mk := ARRAY[(o->>'customer_id')::uuid, (n->>'customer_id')::uuid];
    WHEN 'goodsreceived_trl', 'grn_rates' THEN
      mk := ARRAY[(SELECT x.customer_id FROM public.goodsreceived x WHERE x.id = (o->>'gr_id')::uuid),
                  (SELECT x.customer_id FROM public.goodsreceived x WHERE x.id = (n->>'gr_id')::uuid)];
    WHEN 'dispatch_trl' THEN
      mk := ARRAY[(SELECT x.customer_id FROM public.dispatch x WHERE x.id = (o->>'disp_id')::uuid),
                  (SELECT x.customer_id FROM public.dispatch x WHERE x.id = (n->>'disp_id')::uuid)];
    WHEN 'customers' THEN
      -- Created, deleted, or a change of the name or the active flag; any other column marks nothing.
      IF op IN ('I', 'D') OR (o->>'name', o->>'active') IS DISTINCT FROM (n->>'name', n->>'active') THEN
        mk := ARRAY[(o->>'id')::uuid, (n->>'id')::uuid];
      END IF;
    WHEN 'item_storage_prices', 'charging_rule' THEN
      mall := true;
    WHEN 'system_settings' THEN
      -- The GST settings only; no other setting is behind a figure.
      mall := (o->>'key') = 'facility_legal' OR (n->>'key') = 'facility_legal';
    ELSE
      NULL;
  END CASE;
  FOREACH c IN ARRAY ARRAY(SELECT DISTINCT x FROM unnest(mk) x WHERE x IS NOT NULL) LOOP
    PERFORM warehouse_sync.log_entry('money', c::text, 'U', c, c, NULL, NULL);
  END LOOP;
  IF mall THEN
    PERFORM warehouse_sync.log_entry('money', 'all', 'U', NULL, NULL, NULL, NULL);
  END IF;
  RETURN NULL;$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

-- ===== 3. who receives them =====
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
       ORDER BY l.xid LIMIT p_limit)
      UNION
      -- Feed format 6: the mark for every customer has no customer of its own, so the two filters above never find it.
      (SELECT * FROM warehouse_sync.change_log l WHERE l.tbl = 'money' AND l.row_key = 'all' AND l.xid >= p_from AND l.xid < p_to
       ORDER BY l.xid LIMIT p_limit)) u
      ORDER BY u.xid LIMIT p_limit;
  END IF;
END $$;

-- ===== 4. format 6 =====
ALTER TABLE warehouse_sync.state ALTER COLUMN format SET DEFAULT 6;
UPDATE warehouse_sync.state SET format = 6;
