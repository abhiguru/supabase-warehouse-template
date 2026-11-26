-- Sync feed, item rates and price history (WH-348, offline work step 6): topic "sync item rates". Named by topic; its number is taken when the
-- work is assembled for main. Follows "sync GRN rates" (the entity list); one feed format 3 with the rest of the set, set by the last of them
-- ("sync GST details"). Contract: product/tech/app-offline-read-more.md sections 4, 7 and 14.1 (Product PQ3: price history from the copy).
--
--  1. 'item_storage_prices', 'standard_rate_tiers' and 'item_price_history' become feed entities of administrators and supervisors only,
--     loaded after grn_rates. Staff read none of them online (get_item_storage_prices, get_item_price_history and get_standard_rate are for
--     administrators and supervisors, migrations 90 and 48), and neither do customer accounts (authorize_rpc refuses them): they are not
--     in staff's or a customer account's entities, and their log rows reach neither. Migration 123 revoked the phones' direct read of all
--     three, so each has its own row builder (warehouse_sync.rows_item_storage_prices, rows_standard_rate_tiers, rows_item_price_history):
--     every column of the table, id as text. item_price_history.id is a bigint: its page position is a decimal string, which get_sync_page
--     accepts for that entity.
--  2. Each table gets the zz_change_feed row trigger and the TRUNCATE trigger (ENABLE ALWAYS, as the other tables of the feed), and
--     log_change() logs each row as itself.
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

-- ===== 1. the row builders =====
CREATE FUNCTION warehouse_sync.rows_item_storage_prices(p_ids text[], p_after text, p_limit integer)
 RETURNS TABLE(id text, body jsonb)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT r.id::text, to_jsonb(r) FROM public.item_storage_prices r
   WHERE (p_ids IS NULL OR r.id = ANY (p_ids::uuid[])) AND (p_after IS NULL OR r.id > p_after::uuid)
   ORDER BY r.id LIMIT p_limit
$$;
ALTER FUNCTION warehouse_sync.rows_item_storage_prices(text[], text, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.rows_item_storage_prices(text[], text, integer) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION warehouse_sync.rows_standard_rate_tiers(p_ids text[], p_after text, p_limit integer)
 RETURNS TABLE(id text, body jsonb)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT r.id::text, to_jsonb(r) FROM public.standard_rate_tiers r
   WHERE (p_ids IS NULL OR r.id = ANY (p_ids::uuid[])) AND (p_after IS NULL OR r.id > p_after::uuid)
   ORDER BY r.id LIMIT p_limit
$$;
ALTER FUNCTION warehouse_sync.rows_standard_rate_tiers(text[], text, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.rows_standard_rate_tiers(text[], text, integer) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION warehouse_sync.rows_item_price_history(p_ids text[], p_after text, p_limit integer)
 RETURNS TABLE(id text, body jsonb)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT r.id::text, to_jsonb(r) FROM public.item_price_history r
   WHERE (p_ids IS NULL OR r.id = ANY (p_ids::bigint[])) AND (p_after IS NULL OR r.id > p_after::bigint)
   ORDER BY r.id LIMIT p_limit
$$;
ALTER FUNCTION warehouse_sync.rows_item_price_history(text[], text, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.rows_item_price_history(text[], text, integer) FROM PUBLIC, anon, authenticated, service_role;

-- ===== 2. the feed's functions =====
SELECT pg_temp.patch_function('warehouse_sync.entities(text)'::regprocedure, ARRAY[
$m$'grn_rates', 'grn_lock'$m$,
$m$WHEN 'staff' THEN e NOT IN ($m$,
$m$WHEN 'customer' THEN e NOT IN ($m$
], ARRAY[
$m$'grn_rates', 'item_storage_prices', 'standard_rate_tiers', 'item_price_history', 'grn_lock'$m$,
$m$WHEN 'staff' THEN e NOT IN ('item_storage_prices', 'standard_rate_tiers', 'item_price_history', $m$,
$m$WHEN 'customer' THEN e NOT IN ('item_storage_prices', 'standard_rate_tiers', 'item_price_history', $m$
]);

SELECT pg_temp.patch_function('warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer)'::regprocedure, ARRAY[
$m$ELSIF p_entity = 'users_customers_new' THEN$m$
], ARRAY[
$m$ELSIF p_entity = 'item_storage_prices' THEN
    RETURN QUERY SELECT r.id, r.body FROM warehouse_sync.rows_item_storage_prices(p_ids, p_after, p_limit) r;
    RETURN;
  ELSIF p_entity = 'standard_rate_tiers' THEN
    RETURN QUERY SELECT r.id, r.body FROM warehouse_sync.rows_standard_rate_tiers(p_ids, p_after, p_limit) r;
    RETURN;
  ELSIF p_entity = 'item_price_history' THEN
    RETURN QUERY SELECT r.id, r.body FROM warehouse_sync.rows_item_price_history(p_ids, p_after, p_limit) r;
    RETURN;
  ELSIF p_entity = 'users_customers_new' THEN$m$
]);

-- Staff never receive a log row of these tables (a customer account does not either: they are not in customer_log_tables).
SELECT pg_temp.patch_function('warehouse_sync.staff_hidden_log_tables()'::regprocedure, ARRAY[
$m$ARRAY['payments', $m$
], ARRAY[
$m$ARRAY['item_storage_prices', 'standard_rate_tiers', 'item_price_history', 'payments', $m$
]);

SELECT pg_temp.patch_function('warehouse_sync.log_change()'::regprocedure, ARRAY[
$m$WHEN 'rack_presets', 'rack_preset_state' THEN$m$
], ARRAY[
$m$WHEN 'item_storage_prices', 'standard_rate_tiers', 'item_price_history' THEN
    PERFORM warehouse_sync.log_entry(t, r->>'id', op, NULL, NULL, NULL, NULL);
  WHEN 'rack_presets', 'rack_preset_state' THEN$m$
]);

-- A page position of item_price_history is the decimal text of a bigint.
SELECT pg_temp.patch_function('public.get_sync_page(text, text, integer)'::regprocedure, ARRAY[
$m$p_entity <> 'settings' AND p_after !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'$m$
], ARRAY[
$m$CASE p_entity WHEN 'settings' THEN false WHEN 'item_price_history' THEN p_after !~ '^[0-9]{1,18}$'
                                  ELSE p_after !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' END$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

-- ===== 3. the triggers =====
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['public.item_storage_prices', 'public.standard_rate_tiers', 'public.item_price_history'] LOOP
    EXECUTE format('CREATE TRIGGER zz_change_feed AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION warehouse_sync.log_change()', t);
    EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER zz_change_feed', t);
    EXECUTE format('CREATE TRIGGER zz_change_feed_truncate AFTER TRUNCATE ON %s FOR EACH STATEMENT EXECUTE FUNCTION warehouse_sync.log_truncate()', t);
    EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER zz_change_feed_truncate', t);
  END LOOP;
END $$;
