-- Sync feed scope cut (WH-381, feed format 8): topic "sync_scope_grn_and_stock_only". Named by topic; its number is taken when the work is
-- assembled for main. Contract: product/tech/app-offline-scope-cut.md Section 1.
--
-- Drops the 8 retired entities ('dispatch', 'dispatch_trl', 'dispatch_images', 'invoice', 'invoice_trl', 'payments', 'orders', 'order_items')
-- from the sync feed for every role while preserving all kept GRN/stock/rate/lock/meta entities and all side-effect logging:
--  1. warehouse_sync.entities(p_role): removes the 8 dropped entities for all roles; preserves the 16 kept entities and their role guards.
--  2. public.dispatch_images: drops zz_change_feed and zz_change_feed_truncate triggers (no side effects depend on dispatch_images).
--  3. warehouse_sync.log_change(): stops emitting entity rows for the 8 dropped tables while preserving:
--       - 'grn_lock' facts (dispatch, dispatch_trl, invoice, invoice_trl, orders, order_items, grn_rates, imported_documents,
--         imported_billed_dispatches, and goodsreceived/goodsreceived_trl),
--       - 'money' stale marks (goodsreceived, goodsreceived_trl, dispatch, dispatch_trl, invoice, invoice_trl, payments, grn_rates,
--         customers, item_storage_prices, charging_rule, system_settings),
--       - 'lot_rate' facts for goodsreceived_trl.item_rate,
--       - goodsreceived / goodsreceived_trl (stock, emptied_at) and all other kept entities unchanged.
--  4. warehouse_sync.caller_log(), customer_log_tables(), staff_hidden_log_tables(): filters out pre-migration change_log rows of the 8
--     dropped tables so older log pages never waste or stall get_sync_changes.
--  5. warehouse_sync.expand(), affected(), existing_ids(), entity_rows(): narrowed to the kept entities (dead dropped-entity fan-out and
--     builders removed; all kept features from migrations 212-242 preserved).
--  6. warehouse_sync.state.format bumped 7 -> 8 (column default and current row); format-7 clients receive reload_all FORMAT_CHANGED.
--
-- Idempotent (CREATE OR REPLACE preserves owner supabase_admin and REVOKE ALL grants). No role is created, altered or dropped; no pg_temp
-- helper is created.

-- ===== 1. entities =====
CREATE OR REPLACE FUNCTION warehouse_sync.entities(p_role text) RETURNS text[]
 LANGUAGE sql IMMUTABLE SET search_path = pg_catalog
AS $$
  SELECT ARRAY(SELECT e FROM unnest(ARRAY[
      'customers', 'items', 'settings', 'people', 'goodsreceived', 'goodsreceived_trl', 'grn_images',
      'grn_rates', 'item_storage_prices', 'standard_rate_tiers', 'item_price_history',
      'grn_lock', 'grn_replacements', 'held_items', 'user_profiles', 'users_customers_new'])
      WITH ORDINALITY u(e, ord)
    WHERE CASE p_role
      WHEN 'admin' THEN e <> 'people'
      WHEN 'supervisor' THEN e <> 'people'
      WHEN 'staff' THEN e NOT IN ('grn_rates', 'item_storage_prices', 'standard_rate_tiers', 'item_price_history',
                                  'user_profiles', 'users_customers_new')
      WHEN 'customer' THEN e NOT IN ('settings', 'people', 'item_storage_prices', 'standard_rate_tiers', 'item_price_history',
                                     'grn_lock', 'grn_replacements', 'held_items', 'user_profiles', 'users_customers_new')
      ELSE false END
    ORDER BY ord)
$$;

-- ===== 2. dispatch_images triggers (no side effects) =====
DROP TRIGGER IF EXISTS zz_change_feed ON public.dispatch_images;
DROP TRIGGER IF EXISTS zz_change_feed_truncate ON public.dispatch_images;

-- ===== 3. log_change =====
CREATE OR REPLACE FUNCTION warehouse_sync.log_change() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  o jsonb; n jsonb; r jsonb; op "char" := left(TG_OP, 1)::"char";
  t text := TG_TABLE_NAME; oc uuid; nc uuid; og uuid; ng uuid; c uuid; g uuid; lk text; mk uuid[]; mall boolean := false;
BEGIN
  IF TG_OP <> 'INSERT' THEN o := to_jsonb(OLD); END IF;
  IF TG_OP <> 'DELETE' THEN n := to_jsonb(NEW); END IF;
  r := COALESCE(n, o);
  CASE t
  WHEN 'goodsreceived' THEN
    PERFORM warehouse_sync.log_entry(t, r->>'id', op, (o->>'customer_id')::uuid, (n->>'customer_id')::uuid, (r->>'id')::uuid, NULL);
  WHEN 'goodsreceived_trl', 'grn_images' THEN
    og := (o->>CASE t WHEN 'grn_images' THEN 'grn_id' ELSE 'gr_id' END)::uuid;
    ng := (n->>CASE t WHEN 'grn_images' THEN 'grn_id' ELSE 'gr_id' END)::uuid;
    IF og IS NOT NULL THEN SELECT customer_id INTO oc FROM public.goodsreceived WHERE id = og; END IF;
    IF ng IS NOT NULL THEN SELECT customer_id INTO nc FROM public.goodsreceived WHERE id = ng; END IF;
    PERFORM warehouse_sync.log_entry(t, r->>'id', op, oc, nc, CASE WHEN t = 'goodsreceived_trl' THEN COALESCE(ng, og) END, NULL);
    IF t = 'goodsreceived_trl' AND og IS DISTINCT FROM ng AND og IS NOT NULL AND ng IS NOT NULL THEN
      PERFORM warehouse_sync.log_entry('grn_lock', og::text, 'U', NULL, NULL, og, NULL);
    END IF;
  WHEN 'dispatch' THEN
    -- Lock facts only: every GRN touched by this dispatch's lines (first_dispatch_date, deleted_at, invoice_state).
    FOR g IN SELECT DISTINCT dt.gr_id FROM public.dispatch_trl dt
        WHERE dt.disp_id = (r->>'id')::uuid AND dt.gr_id IS NOT NULL LOOP
      PERFORM warehouse_sync.log_entry('grn_lock', g::text, 'U', NULL, NULL, g, NULL);
    END LOOP;
  WHEN 'dispatch_trl' THEN
    -- Lock facts only: old and new GRN of this dispatch line.
    FOREACH g IN ARRAY ARRAY(SELECT DISTINCT x FROM unnest(ARRAY[(o->>'gr_id')::uuid, (n->>'gr_id')::uuid]) x WHERE x IS NOT NULL) LOOP
      PERFORM warehouse_sync.log_entry('grn_lock', g::text, 'U', NULL, NULL, g, NULL);
    END LOOP;
  WHEN 'invoice' THEN
    -- Lock facts (header GRN and every GRN of its lines) and money marks only.
    FOR g IN
      SELECT DISTINCT x FROM (
        SELECT (o->>'gr_id')::uuid AS x
        UNION ALL SELECT (n->>'gr_id')::uuid
        UNION ALL SELECT dt.gr_id FROM public.invoice_trl it
          JOIN public.dispatch_trl dt ON dt.id = it.disp_trl_id
          WHERE it.invoice_id = (r->>'id')::uuid
      ) q WHERE x IS NOT NULL LOOP
      PERFORM warehouse_sync.log_entry('grn_lock', g::text, 'U', NULL, NULL, g, NULL);
    END LOOP;
    FOREACH c IN ARRAY ARRAY(SELECT DISTINCT x FROM unnest(ARRAY[(o->>'customer_id')::uuid, (n->>'customer_id')::uuid]) x WHERE x IS NOT NULL) LOOP
      PERFORM warehouse_sync.log_entry('money', c::text, 'U', c, c, NULL, NULL);
    END LOOP;
  WHEN 'invoice_trl' THEN
    -- Lock facts and money marks only.
    IF o IS NOT NULL THEN SELECT customer_id INTO oc FROM public.invoice WHERE id = (o->>'invoice_id')::uuid; END IF;
    IF n IS NOT NULL THEN SELECT customer_id INTO nc FROM public.invoice WHERE id = (n->>'invoice_id')::uuid; END IF;
    FOR g IN SELECT DISTINCT dt.gr_id FROM public.dispatch_trl dt
        WHERE dt.id IN ((o->>'disp_trl_id')::uuid, (n->>'disp_trl_id')::uuid) AND dt.gr_id IS NOT NULL LOOP
      PERFORM warehouse_sync.log_entry('grn_lock', g::text, 'U', NULL, NULL, g, NULL);
    END LOOP;
    FOREACH c IN ARRAY ARRAY(SELECT DISTINCT x FROM unnest(ARRAY[oc, nc]) x WHERE x IS NOT NULL) LOOP
      PERFORM warehouse_sync.log_entry('money', c::text, 'U', c, c, NULL, NULL);
    END LOOP;
  WHEN 'payments' THEN
    -- Money marks only.
    FOREACH c IN ARRAY ARRAY(SELECT DISTINCT x FROM unnest(ARRAY[(o->>'customer_id')::uuid, (n->>'customer_id')::uuid]) x WHERE x IS NOT NULL) LOOP
      PERFORM warehouse_sync.log_entry('money', c::text, 'U', c, c, NULL, NULL);
    END LOOP;
  WHEN 'customers' THEN
    PERFORM warehouse_sync.log_entry(t, r->>'id', op, (r->>'id')::uuid, (r->>'id')::uuid, NULL, NULL);
  WHEN 'items', 'user_profiles' THEN
    PERFORM warehouse_sync.log_entry(t, r->>'id', op, NULL, NULL, NULL, NULL);
  WHEN 'users_customers_new' THEN
    PERFORM warehouse_sync.log_entry(t, r->>'id', op, (o->>'customer_id')::uuid, (n->>'customer_id')::uuid, NULL, NULL);
  WHEN 'order_items', 'grn_rates', 'imported_documents' THEN
    -- Lock facts only: the GRN whose "Edit GRN" locks change.
    FOREACH g IN ARRAY ARRAY(SELECT DISTINCT x FROM unnest(CASE t
        WHEN 'order_items' THEN ARRAY[
          COALESCE((o->>'grns_id')::uuid, (SELECT l.gr_id FROM public.goodsreceived_trl l WHERE l.id = (o->>'grn_items_id')::uuid)),
          COALESCE((n->>'grns_id')::uuid, (SELECT l.gr_id FROM public.goodsreceived_trl l WHERE l.id = (n->>'grn_items_id')::uuid))]
        WHEN 'grn_rates' THEN ARRAY[(o->>'gr_id')::uuid, (n->>'gr_id')::uuid]
        ELSE ARRAY[CASE WHEN o->>'kind' = 'grn' THEN (o->>'doc_id')::uuid END, CASE WHEN n->>'kind' = 'grn' THEN (n->>'doc_id')::uuid END]
        END) x WHERE x IS NOT NULL) LOOP
      PERFORM warehouse_sync.log_entry('grn_lock', g::text, 'U', NULL, NULL, g, NULL);
    END LOOP;
  WHEN 'orders' THEN
    -- Lock facts only: every GRN referenced by this order's lines.
    FOR g IN SELECT DISTINCT COALESCE(oi.grns_id, l.gr_id) FROM public.order_items oi
        LEFT JOIN public.goodsreceived_trl l ON l.id = oi.grn_items_id
        WHERE oi.order_id = (r->>'id')::uuid AND COALESCE(oi.grns_id, l.gr_id) IS NOT NULL LOOP
      PERFORM warehouse_sync.log_entry('grn_lock', g::text, 'U', NULL, NULL, g, NULL);
    END LOOP;
  WHEN 'item_storage_prices', 'standard_rate_tiers', 'item_price_history' THEN
    PERFORM warehouse_sync.log_entry(t, r->>'id', op, NULL, NULL, NULL, NULL);
  WHEN 'system_settings' THEN
    -- The keys behind get_gst_details and can_make_bills; every other setting is nobody's copy.
    IF COALESCE(o->>'key', n->>'key') IN ('facility_legal', 'app_name') THEN
      PERFORM warehouse_sync.log_entry('settings', 'gst_details', 'U', NULL, NULL, NULL, NULL);
      PERFORM warehouse_sync.log_entry('settings', 'bills_allowed', 'U', NULL, NULL, NULL, NULL);
    END IF;
  WHEN 'rack_presets', 'rack_preset_state' THEN
    PERFORM warehouse_sync.log_entry('settings', 'rack_presets', 'U', NULL, NULL, NULL, NULL);
  WHEN 'document_numbering' THEN
    PERFORM warehouse_sync.log_entry('settings', 'numbering', 'U', NULL, NULL, NULL, NULL);
  WHEN 'charging_rule' THEN
    PERFORM warehouse_sync.log_entry('settings', 'charging_rule', 'U', NULL, NULL, NULL, NULL);
    IF (o->>'invoice_as_goods_leave') IS DISTINCT FROM (n->>'invoice_as_goods_leave') THEN
      PERFORM warehouse_sync.log_entry('reload', 'grn_lock', 'U', NULL, NULL, NULL, NULL);
    END IF;
  WHEN 'imported_billed_dispatches' THEN
    -- Lock facts only: the GRN of a dispatch line taken as billed, or no longer.
    FOR g IN SELECT DISTINCT dt.gr_id FROM public.dispatch_trl dt
        WHERE dt.id IN ((o->>'disp_trl_id')::uuid, (n->>'disp_trl_id')::uuid) AND dt.gr_id IS NOT NULL LOOP
      PERFORM warehouse_sync.log_entry('grn_lock', g::text, 'U', NULL, NULL, g, NULL);
    END LOOP;
  WHEN 'held_items' THEN
    PERFORM warehouse_sync.log_entry(t, r->>'id', op, (o->>'customer_id')::uuid, (n->>'customer_id')::uuid, NULL, NULL);
  WHEN 'grn_replacements' THEN
    PERFORM warehouse_sync.log_entry(t, r->>'id', op, NULL, NULL, NULL, NULL);
    g := (r->>'grn_id')::uuid;
    SELECT x.customer_id INTO c FROM public.goodsreceived x WHERE x.id = g;
    IF FOUND THEN
      PERFORM warehouse_sync.log_entry('goodsreceived', g::text, 'U', c, c, g, NULL);
    END IF;
  ELSE
    RAISE EXCEPTION 'warehouse_sync.log_change: table % is not a logged table', TG_TABLE_NAME;
  END CASE;

  -- A GRN rate as a row of its own, placed by the customer of its GRN (the branch above keeps the lock fact).
  IF t = 'grn_rates' THEN
    oc := (SELECT x.customer_id FROM public.goodsreceived x WHERE x.id = (o->>'gr_id')::uuid);
    nc := (SELECT x.customer_id FROM public.goodsreceived x WHERE x.id = (n->>'gr_id')::uuid);
    PERFORM warehouse_sync.log_entry('grn_rates', r->>'id', op, oc, nc, NULL, NULL);
  END IF;

  -- A rate change re-sends its item's row (rate_cover).
  IF t = 'item_storage_prices' THEN
    FOREACH g IN ARRAY ARRAY(SELECT DISTINCT x FROM unnest(ARRAY[(o->>'item_id')::uuid, (n->>'item_id')::uuid]) x WHERE x IS NOT NULL) LOOP
      PERFORM warehouse_sync.log_entry('items', g::text, 'U', NULL, NULL, NULL, NULL);
    END LOOP;
  END IF;

  -- The lots whose item_rate this change can move (WH-348 section 16.2).
  FOR lk IN
    SELECT DISTINCT x FROM unnest(CASE t
      WHEN 'grn_rates' THEN ARRAY['grn:' || (o->>'gr_id') || ':' || (o->>'item_id'), 'grn:' || (n->>'gr_id') || ':' || (n->>'item_id')]
      WHEN 'item_storage_prices' THEN ARRAY['item:' || (o->>'item_id') || COALESCE(':' || (o->>'customer_id'), ''),
                                            'item:' || (n->>'item_id') || COALESCE(':' || (n->>'customer_id'), '')]
      -- A dispatch line added, deleted or moved to another lot.
      WHEN 'dispatch_trl' THEN CASE WHEN op IN ('I', 'D') OR (o->>'gr_trl_id') IS DISTINCT FROM (n->>'gr_trl_id')
          THEN ARRAY['lot:' || (o->>'gr_trl_id'), 'lot:' || (n->>'gr_trl_id')] ELSE '{}'::text[] END
      -- An invoice line added, deleted, or given other rates or another dispatch line.
      WHEN 'invoice_trl' THEN CASE WHEN op IN ('I', 'D')
            OR (o->>'charge', o->>'labour_rate', o->>'tax', o->>'disp_trl_id') IS DISTINCT FROM (n->>'charge', n->>'labour_rate', n->>'tax', n->>'disp_trl_id')
          THEN ARRAY(SELECT 'lot:' || dt.gr_trl_id FROM public.dispatch_trl dt
                      WHERE dt.id IN ((o->>'disp_trl_id')::uuid, (n->>'disp_trl_id')::uuid) AND dt.gr_trl_id IS NOT NULL) ELSE '{}'::text[] END
      -- An invoice cancelled, taken back or deleted: the lots of its lines.
      WHEN 'invoice' THEN CASE WHEN op = 'U' AND (o->>'cancelled_at', o->>'deleted_at', o->>'notes') IS DISTINCT FROM (n->>'cancelled_at', n->>'deleted_at', n->>'notes')
          THEN ARRAY(SELECT 'lot:' || dt.gr_trl_id FROM public.invoice_trl it JOIN public.dispatch_trl dt ON dt.id = it.disp_trl_id
                      WHERE it.invoice_id = (r->>'id')::uuid AND dt.gr_trl_id IS NOT NULL) ELSE '{}'::text[] END
      -- A dispatch date change: the lots of the dispatch.
      WHEN 'dispatch' THEN CASE WHEN op = 'U' AND (o->>'disp_date') IS DISTINCT FROM (n->>'disp_date')
          THEN ARRAY(SELECT 'lot:' || dt.gr_trl_id FROM public.dispatch_trl dt WHERE dt.disp_id = (r->>'id')::uuid AND dt.gr_trl_id IS NOT NULL)
          ELSE '{}'::text[] END
      ELSE '{}'::text[] END) x WHERE x IS NOT NULL LOOP
    PERFORM warehouse_sync.log_entry('lot_rate', lk, 'U', NULL, NULL, NULL, NULL);
  END LOOP;

  -- Money marks: which customers' kept answers this change makes out of date (nothing is worked out here).
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

  RETURN NULL;
END $$;

-- ===== 4. caller_log and log table lists =====
CREATE OR REPLACE FUNCTION warehouse_sync.customer_log_tables() RETURNS text[]
 LANGUAGE sql IMMUTABLE SET search_path = pg_catalog
AS $$ SELECT ARRAY['customers', 'goodsreceived', 'goodsreceived_trl', 'grn_images', 'grn_rates', 'money'] $$;

CREATE OR REPLACE FUNCTION warehouse_sync.staff_hidden_log_tables() RETURNS text[]
 LANGUAGE sql IMMUTABLE SET search_path = pg_catalog
AS $$ SELECT ARRAY['grn_rates', 'item_storage_prices', 'standard_rate_tiers', 'item_price_history', 'money', 'users_customers_new'] $$;

CREATE OR REPLACE FUNCTION warehouse_sync.caller_log(p_role text, p_customers uuid[], p_from xid8, p_to xid8, p_limit integer)
 RETURNS SETOF warehouse_sync.change_log
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF p_role IN ('admin', 'supervisor', 'staff') THEN
    RETURN QUERY SELECT * FROM warehouse_sync.change_log l
      WHERE l.xid >= p_from AND l.xid < p_to
        AND l.tbl <> ALL (ARRAY['dispatch', 'dispatch_trl', 'dispatch_images', 'invoice', 'invoice_trl', 'payments', 'orders', 'order_items'])
        AND (p_role <> 'staff' OR NOT l.tbl = ANY (warehouse_sync.staff_hidden_log_tables()))
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
      -- The mark for every customer has no customer of its own, so the two filters above never find it.
      (SELECT * FROM warehouse_sync.change_log l WHERE l.tbl = 'money' AND l.row_key = 'all' AND l.xid >= p_from AND l.xid < p_to
       ORDER BY l.xid LIMIT p_limit)) u
      ORDER BY u.xid LIMIT p_limit;
  END IF;
END $$;

-- ===== 5. expand =====
CREATE OR REPLACE FUNCTION warehouse_sync.expand(p_role text, p_rows warehouse_sync.change_log[])
 RETURNS TABLE(xid xid8, e text, id text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
  WITH l AS (SELECT * FROM unnest(p_rows)),
  lr AS MATERIALIZED (
    SELECT l.xid, split_part(l.row_key, ':', 1) AS kind, split_part(l.row_key, ':', 2)::uuid AS a,
           NULLIF(split_part(l.row_key, ':', 3), '')::uuid AS b
      FROM l WHERE l.tbl = 'lot_rate'),
  k AS (
    SELECT l.xid, CASE WHEN l.tbl = 'user_profiles' AND p_role = 'staff' THEN 'people' ELSE l.tbl END AS e, l.row_key AS id FROM l
    UNION ALL SELECT l.xid, 'settings', 'gst_details' FROM l WHERE l.tbl = 'user_profiles'
    UNION ALL SELECT lr.xid, 'goodsreceived_trl', t.id::text FROM lr JOIN public.goodsreceived_trl t ON t.id = lr.a
      WHERE lr.kind = 'lot' AND p_role <> 'customer'
    UNION ALL SELECT lr.xid, 'goodsreceived_trl', t.id::text FROM lr JOIN public.goodsreceived_trl t ON t.item_id = lr.a
      WHERE lr.kind = 'item' AND p_role <> 'customer'
        AND (lr.b IS NULL OR EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = t.gr_id AND g.customer_id = lr.b))
    UNION ALL SELECT lr.xid, 'goodsreceived_trl', t.id::text FROM lr JOIN public.goodsreceived_trl t ON t.gr_id = lr.a AND t.item_id = lr.b
      WHERE lr.kind = 'grn' AND p_role <> 'customer'
    UNION ALL SELECT l.xid, 'grn_rates', r.id::text FROM l JOIN public.grn_rates r ON r.gr_id = l.row_key::uuid
      WHERE l.tbl = 'goodsreceived' AND p_role = 'customer'
    UNION ALL SELECT l.xid, 'grn_lock', l.grn_id::text FROM l WHERE l.grn_id IS NOT NULL
    UNION ALL SELECT l.xid, 'goodsreceived_trl', t.id::text FROM l JOIN public.goodsreceived_trl t ON t.gr_id = l.row_key::uuid
      WHERE l.tbl = 'goodsreceived'
    UNION ALL SELECT l.xid, 'grn_images', i.id::text FROM l JOIN public.grn_images i ON i.grn_id = l.row_key::uuid
      WHERE l.tbl = 'goodsreceived')
  SELECT DISTINCT k.xid, k.e, k.id FROM k
  WHERE (k.e = ANY (warehouse_sync.entities(p_role)) OR (k.e = 'money' AND p_role IN ('admin', 'supervisor', 'customer')))
    AND NOT (k.e = 'settings' AND k.id IN ('charging_rule', 'gst_details') AND p_role <> 'admin')
$$;

-- ===== 6. affected =====
CREATE OR REPLACE FUNCTION warehouse_sync.affected(p_tbl text) RETURNS text[]
 LANGUAGE sql IMMUTABLE SET search_path = pg_catalog
AS $$
  SELECT CASE p_tbl
    WHEN 'goodsreceived' THEN ARRAY['goodsreceived', 'goodsreceived_trl', 'grn_images', 'grn_lock', 'grn_rates']
    WHEN 'goodsreceived_trl' THEN ARRAY['goodsreceived_trl', 'grn_lock']
    WHEN 'user_profiles' THEN ARRAY['user_profiles', 'people', 'settings']
    WHEN 'lot_rate' THEN ARRAY['goodsreceived_trl']
    WHEN 'grn_rates' THEN ARRAY['grn_rates', 'goodsreceived_trl']
    WHEN 'item_storage_prices' THEN ARRAY['item_storage_prices', 'goodsreceived_trl', 'items']
    WHEN 'reload' THEN ARRAY['grn_lock']
    WHEN 'money', 'dispatch', 'dispatch_trl', 'dispatch_images', 'invoice', 'invoice_trl', 'payments', 'orders', 'order_items' THEN '{}'::text[]
    ELSE ARRAY[p_tbl] END
$$;

-- ===== 7. existing_ids =====
CREATE OR REPLACE FUNCTION warehouse_sync.existing_ids(p_entity text, p_ids text[]) RETURNS text[]
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE r text[];
BEGIN
  IF p_entity NOT IN ('customers', 'items', 'goodsreceived', 'goodsreceived_trl', 'grn_images', 'user_profiles') THEN
    RETURN '{}';
  END IF;
  EXECUTE format('SELECT COALESCE(array_agg(t.id::text), ''{}'') FROM public.%I t WHERE t.id = ANY ($1::uuid[])', p_entity) INTO r USING p_ids;
  RETURN r;
END $$;

-- ===== 8. entity_rows =====
CREATE OR REPLACE FUNCTION warehouse_sync.entity_rows(p_role text, p_profile uuid, p_customers uuid[], p_entity text, p_ids text[], p_after text, p_limit integer)
 RETURNS TABLE(id text, body jsonb)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_cols text; v_where text; v_tbl regclass; v_cust boolean := p_role = 'customer';
  v_limit text := COALESCE(p_limit::text, 'ALL');
BEGIN
  IF NOT p_entity = ANY (warehouse_sync.entities(p_role)) THEN RETURN; END IF;
  IF p_entity = 'settings' THEN
    RETURN QUERY SELECT s.id, s.body FROM warehouse_sync.settings_rows(p_role) s
      WHERE (p_ids IS NULL OR s.id = ANY (p_ids)) AND (p_after IS NULL OR s.id > p_after) ORDER BY s.id
      LIMIT CASE WHEN p_limit IS NULL THEN NULL ELSE p_limit END;
    RETURN;
  ELSIF p_entity = 'people' THEN
    -- What get_supervisors('') answers to staff.
    RETURN QUERY SELECT u.id::text, jsonb_build_object('id', u.id, 'name', u.name, 'display_name', u.display_name, 'role', u.role)
      FROM public.user_profiles u
      WHERE u.role IN ('admin', 'supervisor', 'staff') AND NOT u.is_service_account AND u.active
        AND (p_ids IS NULL OR u.id = ANY (p_ids::uuid[])) AND (p_after IS NULL OR u.id > p_after::uuid)
      ORDER BY u.id LIMIT CASE WHEN p_limit IS NULL THEN NULL ELSE p_limit END;
    RETURN;
  ELSIF p_entity = 'grn_lock' THEN
    RETURN QUERY SELECT b.id::text, b.body FROM warehouse_sync.grn_lock_build(ARRAY(
        SELECT g.id FROM public.goodsreceived g
        WHERE g.deleted_at IS NULL AND (p_ids IS NULL OR g.id = ANY (p_ids::uuid[])) AND (p_after IS NULL OR g.id > p_after::uuid)
        ORDER BY g.id LIMIT CASE WHEN p_limit IS NULL THEN NULL ELSE p_limit END)) b
      ORDER BY CASE WHEN p_limit IS NULL THEN NULL ELSE b.id END;
    RETURN;
  ELSIF p_entity = 'held_items' THEN
    RETURN QUERY SELECT r.id, r.body FROM warehouse_sync.rows_held_items(p_role, p_profile, p_ids, p_after, p_limit) r;
    RETURN;
  ELSIF p_entity = 'grn_replacements' THEN
    RETURN QUERY SELECT r.id, r.body FROM warehouse_sync.rows_grn_replacements(p_role, p_ids, p_after, p_limit) r;
    RETURN;
  ELSIF p_entity = 'grn_rates' THEN
    RETURN QUERY SELECT r.id, r.body FROM warehouse_sync.rows_grn_rates(p_role, p_customers, p_ids, p_after, p_limit) r;
    RETURN;
  ELSIF p_entity = 'item_storage_prices' THEN
    RETURN QUERY SELECT r.id, r.body FROM warehouse_sync.rows_item_storage_prices(p_ids, p_after, p_limit) r;
    RETURN;
  ELSIF p_entity = 'standard_rate_tiers' THEN
    RETURN QUERY SELECT r.id, r.body FROM warehouse_sync.rows_standard_rate_tiers(p_ids, p_after, p_limit) r;
    RETURN;
  ELSIF p_entity = 'item_price_history' THEN
    RETURN QUERY SELECT r.id, r.body FROM warehouse_sync.rows_item_price_history(p_ids, p_after, p_limit) r;
    RETURN;
  ELSIF p_entity = 'users_customers_new' THEN
    RETURN QUERY SELECT u.id::text, to_jsonb(u) FROM public.users_customers_new u
      WHERE (p_ids IS NULL OR u.id = ANY (p_ids::uuid[])) AND (p_after IS NULL OR u.id > p_after::uuid)
      ORDER BY u.id LIMIT CASE WHEN p_limit IS NULL THEN NULL ELSE p_limit END;
    RETURN;
  END IF;

  v_tbl := format('public.%I', p_entity)::regclass;
  SELECT string_agg(format('t.%I', a.attname), ', ' ORDER BY a.attnum) INTO v_cols
    FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = v_tbl AND a.attnum > 0 AND NOT a.attisdropped
      AND pg_catalog.has_column_privilege('authenticated', v_tbl, a.attname::text, 'SELECT')
      AND NOT (v_cust AND a.attname::text = ANY (warehouse_sync.customer_hidden_columns()))
      AND NOT (p_entity = 'goodsreceived'
               AND a.attname::text IN ('request_key', 'request_digest', 'request_item_mapping'));
  -- Which price types an item has no rate for (WH-348 section 17): the server's proof, never a rule a phone copies.
  IF p_entity = 'items' AND p_role IN ('admin', 'supervisor', 'staff') THEN
    v_cols := v_cols || ', warehouse_security.item_rate_cover(t.id) AS rate_cover';
  END IF;
  -- The rate each lot is charged at, as get_grn_item_rates answers it (WH-348 section 16): the server's answer, never worked out on a phone.
  IF p_entity = 'goodsreceived_trl' AND p_role IN ('admin', 'supervisor', 'staff') THEN
    v_cols := v_cols || ', warehouse_security.grn_lot_rate(t.id, false) AS item_rate';
  END IF;
  -- When a lot was last emptied (get_customer_stock_summary's time).
  IF p_entity = 'goodsreceived_trl' THEN
    v_cols := v_cols || ', (SELECT max(m.created_at) FROM public.stock_movements m'
                     || ' WHERE m.gr_trl_id = t.id AND m.balance_after = 0) AS emptied_at';
  END IF;
  v_where := CASE
    WHEN p_entity = 'items' THEN 'true'
    WHEN p_role IN ('admin', 'supervisor') THEN 'true'
    WHEN p_role = 'staff' THEN CASE WHEN p_entity = 'grn_images'
      THEN '(t.status = ''confirmed'' OR t.uploaded_by = $1)' ELSE 'true' END
    WHEN p_entity = 'customers' THEN 't.deleted_at IS NULL AND t.id = ANY ($2)'
    WHEN p_entity = 'goodsreceived' THEN 't.deleted_at IS NULL AND t.customer_id = ANY ($2)'
    WHEN p_entity = 'goodsreceived_trl' THEN
      'EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = t.gr_id AND g.deleted_at IS NULL AND g.customer_id = ANY ($2))'
    WHEN p_entity = 'grn_images' THEN
      't.status = ''confirmed'' AND EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = t.grn_id AND g.deleted_at IS NULL AND g.customer_id = ANY ($2))'
    ELSE 'false' END;
  RETURN QUERY EXECUTE format(
    'SELECT t.id::text, to_jsonb(x) FROM %s t CROSS JOIN LATERAL (SELECT %s) x WHERE (%s)%s%s ORDER BY t.id LIMIT %s',
    v_tbl, v_cols, v_where,
    CASE WHEN p_ids IS NOT NULL THEN ' AND t.id = ANY ($3::uuid[])' ELSE '' END,
    CASE WHEN p_after IS NOT NULL THEN ' AND t.id > $4::uuid' ELSE '' END,
    v_limit)
    USING p_profile, p_customers, p_ids, p_after;
END $$;

-- ===== 9. format 8 =====
ALTER TABLE warehouse_sync.state ALTER COLUMN format SET DEFAULT 8;
UPDATE warehouse_sync.state SET format = 8;

NOTIFY pgrst, 'reload schema';
