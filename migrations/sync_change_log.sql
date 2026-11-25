-- Sync change log (WH-297, offline work step 1): the server keeps a log of every change a phone's copy needs and answers, per caller,
-- what changed since the phone's last position. Named by topic; its number is taken when the work is assembled for main.
-- The contract the app and the tests follow is the "Sync" section of docs/API_CONTRACT.md.
--
--  1. Schema warehouse_sync (no app role reads it): change_log (one row per changed row, setting, lock fact or money mark per
--     transaction, keyed by the transaction's 64-bit id) and state (log id, reason of its last change, floor, payload format).
--  2. Trigger zz_change_feed, AFTER INSERT OR UPDATE OR DELETE FOR EACH ROW, ENABLE ALWAYS (it also fires with
--     session_replication_role = replica, as the import writes), on every table a phone's copy depends on; a TRUNCATE of any of
--     them, and a new import batch, make every phone reload everything (rotate_log).
--  3. Four RPCs, any active role, read-only, jsonb: get_sync_start, get_sync_page, get_sync_changes, get_sync_checksums. Like
--     every granted function they run as the owner, so they apply the row rules of migration 137 (and the readable columns) in
--     warehouse_sync.entity_rows; a customer account receives no soft-deleted row and no internal staff or import id.
--  4. get_grn_edit_state and the feed's grn_lock entity are built by one function, warehouse_sync.grn_lock_build.
--  5. Retention key sync_change_log, 120 days, applied by run_database_retention (marker-count patch); the floor rises with it.
--  6. safe_disable_grn_trl_triggers() and safe_enable_grn_trl_triggers() are dropped: their trigger no longer exists, and "Edit GRN"
--     (definitions/update_grn.sql) no longer calls them.
--
-- No role is created, altered or dropped. authorize_rpc admits the four RPCs in definitions/00_authorize_rpc.sql.

-- ===== 1. the log =====
CREATE SCHEMA warehouse_sync AUTHORIZATION supabase_admin;
REVOKE ALL ON SCHEMA warehouse_sync FROM PUBLIC;

CREATE TABLE warehouse_sync.change_log (
  xid          xid8 NOT NULL DEFAULT pg_current_xact_id(),
  at           timestamptz NOT NULL DEFAULT now(),
  tbl          text NOT NULL,       -- the entity (table entities, settings), grn_lock (lock facts only) or money (marks only)
  row_key      text NOT NULL,       -- the row id, the setting key, the GRN id of a lock fact or the customer id of a money mark
  op           "char" NOT NULL,     -- I, U or D: the last operation of the transaction on that row
  old_customer uuid,                -- the customer of the row before the transaction (for a line, its document's customer)
  new_customer uuid,                -- and after it
  grn_id       uuid,                -- the GRN whose edit locks the row touches
  disp_id      uuid,
  CONSTRAINT change_log_entry UNIQUE (xid, tbl, row_key)
);
ALTER TABLE warehouse_sync.change_log OWNER TO supabase_admin;
ALTER TABLE warehouse_sync.change_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_sync.change_log FROM PUBLIC, anon, authenticated, service_role;
CREATE INDEX change_log_tbl_xid ON warehouse_sync.change_log (tbl, xid);
CREATE INDEX change_log_old_customer_xid ON warehouse_sync.change_log (old_customer, xid) WHERE old_customer IS NOT NULL;
CREATE INDEX change_log_new_customer_xid ON warehouse_sync.change_log (new_customer, xid) WHERE new_customer IS NOT NULL;
CREATE INDEX change_log_at ON warehouse_sync.change_log (at);
COMMENT ON TABLE warehouse_sync.change_log IS
  'WH-297: what changed, per transaction (xid), for the phones'' copies. Written only by the zz_change_feed triggers; read only by the get_sync_* RPCs. Kept 120 days (retention key sync_change_log).';

CREATE TABLE warehouse_sync.state (
  singleton     boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  log_id        uuid NOT NULL DEFAULT gen_random_uuid(),
  log_id_reason text NOT NULL DEFAULT 'RESET',
  rotated_at    timestamptz NOT NULL DEFAULT now(),
  floor         xid8 NOT NULL DEFAULT '0',
  format        integer NOT NULL DEFAULT 1
);
ALTER TABLE warehouse_sync.state OWNER TO supabase_admin;
ALTER TABLE warehouse_sync.state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_sync.state FROM PUBLIC, anon, authenticated, service_role;
INSERT INTO warehouse_sync.state DEFAULT VALUES;
COMMENT ON TABLE warehouse_sync.state IS
  'WH-297: log_id changes whenever every phone must reload (reason in log_id_reason); floor is the lowest position still answerable; format is the payload format (a migration that changes an entity''s payload raises it).';

-- A new log id: every phone's next call answers reload_all with this reason. Also for an operator (RESET) and after a restore (RESTORED).
CREATE FUNCTION warehouse_sync.rotate_log(p_reason text) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF p_reason IS NULL OR p_reason !~ '^[A-Z_]{1,40}$' THEN
    RAISE EXCEPTION 'rotate_log: the reason is a short upper-case word, for example RESET' USING ERRCODE = '22023';
  END IF;
  UPDATE warehouse_sync.state SET log_id = gen_random_uuid(), log_id_reason = p_reason, rotated_at = now();
END $$;
ALTER FUNCTION warehouse_sync.rotate_log(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.rotate_log(text) FROM PUBLIC, anon, authenticated, service_role;

-- x + 1 for a transaction id.
CREATE FUNCTION warehouse_sync.next_xid(x xid8) RETURNS xid8
 LANGUAGE sql IMMUTABLE SET search_path = pg_catalog
AS $$ SELECT (x::text::numeric + 1)::text::xid8 $$;
ALTER FUNCTION warehouse_sync.next_xid(xid8) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.next_xid(xid8) FROM PUBLIC, anon, authenticated, service_role;

-- ===== 2. the triggers =====
CREATE FUNCTION warehouse_sync.log_entry(p_tbl text, p_key text, p_op "char", p_old uuid, p_new uuid, p_grn uuid, p_disp uuid)
 RETURNS void
 LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
  INSERT INTO warehouse_sync.change_log AS c (tbl, row_key, op, old_customer, new_customer, grn_id, disp_id)
  VALUES (p_tbl, p_key, p_op, p_old, p_new, p_grn, p_disp)
  ON CONFLICT ON CONSTRAINT change_log_entry DO UPDATE SET
    op = excluded.op,
    old_customer = COALESCE(c.old_customer, excluded.old_customer),
    new_customer = excluded.new_customer,
    grn_id = COALESCE(excluded.grn_id, c.grn_id),
    disp_id = COALESCE(excluded.disp_id, c.disp_id)
$$;
ALTER FUNCTION warehouse_sync.log_entry(text, text, "char", uuid, uuid, uuid, uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.log_entry(text, text, "char", uuid, uuid, uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION warehouse_sync.log_change() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  o jsonb; n jsonb; r jsonb; op "char" := left(TG_OP, 1)::"char";
  t text := TG_TABLE_NAME; oc uuid; nc uuid; og uuid; ng uuid; c uuid; g uuid;
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
    PERFORM warehouse_sync.log_entry(t, r->>'id', op, (o->>'customer_id')::uuid, (n->>'customer_id')::uuid, NULL, (r->>'id')::uuid);
  WHEN 'dispatch_trl', 'dispatch_images' THEN
    og := (o->>CASE t WHEN 'dispatch_images' THEN 'dispatch_id' ELSE 'disp_id' END)::uuid;
    ng := (n->>CASE t WHEN 'dispatch_images' THEN 'dispatch_id' ELSE 'disp_id' END)::uuid;
    IF og IS NOT NULL THEN SELECT customer_id INTO oc FROM public.dispatch WHERE id = og; END IF;
    IF ng IS NOT NULL THEN SELECT customer_id INTO nc FROM public.dispatch WHERE id = ng; END IF;
    PERFORM warehouse_sync.log_entry(t, r->>'id', op, oc, nc,
      CASE WHEN t = 'dispatch_trl' THEN COALESCE((n->>'gr_id')::uuid, (o->>'gr_id')::uuid) END, COALESCE(ng, og));
    IF t = 'dispatch_trl' AND (o->>'gr_id') IS DISTINCT FROM (n->>'gr_id') AND o->>'gr_id' IS NOT NULL AND n->>'gr_id' IS NOT NULL THEN
      PERFORM warehouse_sync.log_entry('grn_lock', o->>'gr_id', 'U', NULL, NULL, (o->>'gr_id')::uuid, NULL);
    END IF;
  WHEN 'invoice' THEN
    oc := (o->>'customer_id')::uuid; nc := (n->>'customer_id')::uuid;
    PERFORM warehouse_sync.log_entry(t, r->>'id', op, oc, nc, COALESCE((n->>'gr_id')::uuid, (o->>'gr_id')::uuid), NULL);
    IF (o->>'gr_id') IS DISTINCT FROM (n->>'gr_id') AND o->>'gr_id' IS NOT NULL AND n->>'gr_id' IS NOT NULL THEN
      PERFORM warehouse_sync.log_entry('grn_lock', o->>'gr_id', 'U', NULL, NULL, (o->>'gr_id')::uuid, NULL);
    END IF;
    FOREACH c IN ARRAY ARRAY(SELECT DISTINCT x FROM unnest(ARRAY[oc, nc]) x WHERE x IS NOT NULL) LOOP
      PERFORM warehouse_sync.log_entry('money', c::text, 'U', c, c, NULL, NULL);
    END LOOP;
  WHEN 'invoice_trl' THEN
    IF o IS NOT NULL THEN SELECT customer_id INTO oc FROM public.invoice WHERE id = (o->>'invoice_id')::uuid; END IF;
    IF n IS NOT NULL THEN SELECT customer_id INTO nc FROM public.invoice WHERE id = (n->>'invoice_id')::uuid; END IF;
    SELECT dt.gr_id INTO g FROM public.dispatch_trl dt WHERE dt.id = COALESCE((n->>'disp_trl_id')::uuid, (o->>'disp_trl_id')::uuid);
    PERFORM warehouse_sync.log_entry(t, r->>'id', op, oc, nc, g, NULL);
    FOREACH c IN ARRAY ARRAY(SELECT DISTINCT x FROM unnest(ARRAY[oc, nc]) x WHERE x IS NOT NULL) LOOP
      PERFORM warehouse_sync.log_entry('money', c::text, 'U', c, c, NULL, NULL);
    END LOOP;
  WHEN 'payments' THEN
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
    FOR g IN SELECT DISTINCT COALESCE(oi.grns_id, l.gr_id) FROM public.order_items oi
        LEFT JOIN public.goodsreceived_trl l ON l.id = oi.grn_items_id
        WHERE oi.order_id = (r->>'id')::uuid AND COALESCE(oi.grns_id, l.gr_id) IS NOT NULL LOOP
      PERFORM warehouse_sync.log_entry('grn_lock', g::text, 'U', NULL, NULL, g, NULL);
    END LOOP;
  WHEN 'rack_presets', 'rack_preset_state' THEN
    PERFORM warehouse_sync.log_entry('settings', 'rack_presets', 'U', NULL, NULL, NULL, NULL);
  WHEN 'document_numbering' THEN
    PERFORM warehouse_sync.log_entry('settings', 'numbering', 'U', NULL, NULL, NULL, NULL);
  WHEN 'charging_rule' THEN
    PERFORM warehouse_sync.log_entry('settings', 'charging_rule', 'U', NULL, NULL, NULL, NULL);
  ELSE
    RAISE EXCEPTION 'warehouse_sync.log_change: table % is not a logged table', TG_TABLE_NAME;
  END CASE;
  RETURN NULL;
END $$;
ALTER FUNCTION warehouse_sync.log_change() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.log_change() FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION warehouse_sync.log_truncate() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$ BEGIN PERFORM warehouse_sync.rotate_log('TRUNCATED'); RETURN NULL; END $$;
ALTER FUNCTION warehouse_sync.log_truncate() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.log_truncate() FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION warehouse_sync.log_import() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$ BEGIN PERFORM warehouse_sync.rotate_log('BULK_IMPORT'); RETURN NULL; END $$;
ALTER FUNCTION warehouse_sync.log_import() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.log_import() FROM PUBLIC, anon, authenticated, service_role;

-- Trigger names sort last among AFTER triggers (zz_); ENABLE ALWAYS so that session_replication_role = replica does not silence
-- them. Nothing may switch the user triggers of these tables off or on wholesale: switching them on again wholesale turns ALWAYS back into ORIGIN.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['public.goodsreceived', 'public.goodsreceived_trl', 'public.grn_images', 'public.dispatch', 'public.dispatch_trl',
      'public.dispatch_images', 'public.invoice', 'public.invoice_trl', 'public.payments', 'public.customers', 'public.items',
      'public.user_profiles', 'public.users_customers_new', 'public.order_items', 'public.orders', 'public.grn_rates',
      'warehouse_security.imported_documents', 'warehouse_security.rack_presets', 'warehouse_security.rack_preset_state',
      'warehouse_security.document_numbering', 'warehouse_security.charging_rule'] LOOP
    EXECUTE format('CREATE TRIGGER zz_change_feed AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION warehouse_sync.log_change()', t);
    EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER zz_change_feed', t);
    EXECUTE format('CREATE TRIGGER zz_change_feed_truncate AFTER TRUNCATE ON %s FOR EACH STATEMENT EXECUTE FUNCTION warehouse_sync.log_truncate()', t);
    EXECUTE format('ALTER TABLE %s ENABLE ALWAYS TRIGGER zz_change_feed_truncate', t);
  END LOOP;
END $$;
CREATE TRIGGER zz_change_feed_import AFTER INSERT ON warehouse_security.import_batches
  FOR EACH STATEMENT EXECUTE FUNCTION warehouse_sync.log_import();
ALTER TABLE warehouse_security.import_batches ENABLE ALWAYS TRIGGER zz_change_feed_import;

-- ===== 3. reading for a caller =====
-- The caller: role, profile and (customer accounts) the customers it is assigned to; access is the key part that changes when any of
-- them does. Service-role calls have no role and are refused by the RPCs.
CREATE FUNCTION warehouse_sync.caller(OUT role text, OUT profile uuid, OUT customers uuid[], OUT access text)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  role := warehouse_security.active_role();
  IF role IS NULL THEN RAISE EXCEPTION 'Active account required' USING ERRCODE = '42501'; END IF;
  SELECT p.id INTO profile FROM public.user_profiles p WHERE p.auth_user_id = auth.uid() AND p.active;
  customers := CASE WHEN role = 'customer' THEN ARRAY(
    SELECT DISTINCT a.customer_id FROM public.users_customers_new a
    WHERE a.user_profile_id = profile AND a.active AND a.customer_id IS NOT NULL ORDER BY a.customer_id) ELSE '{}'::uuid[] END;
  access := md5(concat_ws('|', profile, role, array_to_string(customers, ',')));
END $$;
ALTER FUNCTION warehouse_sync.caller() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.caller() FROM PUBLIC, anon, authenticated, service_role;

-- The entities a role loads, in load order.
CREATE FUNCTION warehouse_sync.entities(p_role text) RETURNS text[]
 LANGUAGE sql IMMUTABLE SET search_path = pg_catalog
AS $$
  SELECT ARRAY(SELECT e FROM unnest(ARRAY['customers', 'items', 'settings', 'people', 'goodsreceived', 'goodsreceived_trl', 'grn_images',
      'dispatch', 'dispatch_trl', 'dispatch_images', 'invoice', 'invoice_trl', 'grn_lock', 'user_profiles', 'users_customers_new'])
      WITH ORDINALITY u(e, ord)
    WHERE CASE p_role
      WHEN 'admin' THEN e <> 'people'
      WHEN 'supervisor' THEN e <> 'people'
      WHEN 'staff' THEN e NOT IN ('user_profiles', 'users_customers_new')
      WHEN 'customer' THEN e NOT IN ('settings', 'people', 'grn_lock', 'user_profiles', 'users_customers_new')
      ELSE false END
    ORDER BY ord)
$$;
ALTER FUNCTION warehouse_sync.entities(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.entities(text) FROM PUBLIC, anon, authenticated, service_role;

-- The entities whose rows a log row of one kind can change (the row itself, the rows the server adds to it, and the locks).
CREATE FUNCTION warehouse_sync.affected(p_tbl text) RETURNS text[]
 LANGUAGE sql IMMUTABLE SET search_path = pg_catalog
AS $$
  SELECT CASE p_tbl
    WHEN 'goodsreceived' THEN ARRAY['goodsreceived', 'goodsreceived_trl', 'grn_images', 'grn_lock']
    WHEN 'goodsreceived_trl' THEN ARRAY['goodsreceived_trl', 'grn_lock']
    WHEN 'dispatch' THEN ARRAY['dispatch', 'dispatch_trl', 'dispatch_images', 'grn_lock']
    WHEN 'dispatch_trl' THEN ARRAY['dispatch_trl', 'grn_lock']
    WHEN 'invoice' THEN ARRAY['invoice', 'invoice_trl', 'grn_lock']
    WHEN 'invoice_trl' THEN ARRAY['invoice_trl', 'grn_lock']
    WHEN 'user_profiles' THEN ARRAY['user_profiles', 'people']
    WHEN 'money' THEN '{}'::text[]
    ELSE ARRAY[p_tbl] END
$$;
ALTER FUNCTION warehouse_sync.affected(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.affected(text) FROM PUBLIC, anon, authenticated, service_role;

-- Columns a customer account never receives (Product, WH-297 Q1: internal ids of staff members and imports).
CREATE FUNCTION warehouse_sync.customer_hidden_columns() RETURNS text[]
 LANGUAGE sql IMMUTABLE SET search_path = pg_catalog
AS $$ SELECT ARRAY['created_by', 'updated_by', 'deleted_by', 'supervisor_id', 'sender_id', 'import_batch_id', 'uploaded_by'] $$;
ALTER FUNCTION warehouse_sync.customer_hidden_columns() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.customer_hidden_columns() FROM PUBLIC, anon, authenticated, service_role;

-- The "Edit GRN" facts of live GRNs, set-based: get_grn_edit_state's data plus imported and rated_item_ids.
CREATE FUNCTION warehouse_sync.grn_lock_build(p_ids uuid[]) RETURNS TABLE(id uuid, body jsonb)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  WITH want AS (
    SELECT g.id, g.gr_no, g.date, g.updated_at, g.customer_name, COALESCE(g.invoiced, false) AS invoiced
    FROM unnest(p_ids) AS w(id) JOIN public.goodsreceived g ON g.id = w.id
    WHERE g.deleted_at IS NULL),
  lots AS (SELECT t.id, t.gr_id FROM public.goodsreceived_trl t JOIN want ON t.gr_id = want.id),
  disp AS (SELECT dt.gr_trl_id, SUM(dt.disp_qty) AS qty FROM public.dispatch_trl dt JOIN lots ON lots.id = dt.gr_trl_id GROUP BY dt.gr_trl_id),
  moved AS (SELECT DISTINCT m.gr_trl_id FROM public.stock_movements m JOIN lots ON lots.id = m.gr_trl_id),
  line_inv AS (
    SELECT DISTINCT ON (dt.gr_trl_id) dt.gr_trl_id, i.inv_no, i.inv_fin_year, i.inv_prefix
    FROM lots
    JOIN public.dispatch_trl dt ON dt.gr_trl_id = lots.id
    JOIN public.invoice_trl it ON it.disp_trl_id = dt.id
    JOIN public.invoice i ON i.id = it.invoice_id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL
    ORDER BY dt.gr_trl_id, i.inv_fin_year, i.inv_no, i.id),
  ordered AS (
    SELECT DISTINCT oi.grn_items_id FROM lots
    JOIN public.order_items oi ON oi.grn_items_id = lots.id
    JOIN public.orders o ON o.id = oi.order_id AND o.deleted_at IS NULL),
  lines AS (
    SELECT t.gr_id, jsonb_agg(jsonb_build_object(
               'id', t.id,
               'dispatched_qty', COALESCE(disp.qty, 0),
               'has_history', disp.gr_trl_id IS NOT NULL OR moved.gr_trl_id IS NOT NULL,
               'on_invoice', li.inv_no IS NOT NULL,
               'invoice_no', li.inv_no,
               'invoice_label', warehouse_security.invoice_label(li.inv_prefix, li.inv_no),
               'inv_fin_year', li.inv_fin_year,
               'on_order', od.grn_items_id IS NOT NULL,
               'order_customer_name', g.customer_name
           ) ORDER BY uuid_extract_timestamp(t.id), t.id) AS j
    FROM lots t
    JOIN want g ON g.id = t.gr_id
    LEFT JOIN disp ON disp.gr_trl_id = t.id
    LEFT JOIN moved ON moved.gr_trl_id = t.id
    LEFT JOIN line_inv li ON li.gr_trl_id = t.id
    LEFT JOIN ordered od ON od.grn_items_id = t.id
    GROUP BY t.gr_id),
  head_inv AS (
    SELECT DISTINCT ON (i.gr_id) i.gr_id,
           jsonb_build_object('id', i.id, 'inv_no', i.inv_no, 'inv_fin_year', i.inv_fin_year,
                              'inv_prefix', i.inv_prefix, 'invoice_label', warehouse_security.invoice_label(i.inv_prefix, i.inv_no)) AS j
    FROM public.invoice i JOIN want ON i.gr_id = want.id
    WHERE i.deleted_at IS NULL AND i.cancelled_at IS NULL
    ORDER BY i.gr_id, i.inv_fin_year, i.inv_no, i.id),
  first_day AS (
    SELECT DISTINCT ON (dt.gr_id) dt.gr_id, to_char(warehouse_security.business_date(d.disp_date), 'YYYY-MM-DD') AS day
    FROM public.dispatch_trl dt
    JOIN want ON dt.gr_id = want.id
    JOIN public.dispatch d ON d.id = dt.disp_id AND d.deleted_at IS NULL
    WHERE d.disp_date IS NOT NULL
    ORDER BY dt.gr_id, warehouse_security.business_date(d.disp_date), d.disp_date),
  imported AS (SELECT DISTINCT d.doc_id FROM warehouse_security.imported_documents d JOIN want ON d.doc_id = want.id WHERE d.kind = 'grn'),
  rated AS (SELECT r.gr_id, jsonb_agg(DISTINCT r.item_id ORDER BY r.item_id) AS j FROM public.grn_rates r JOIN want ON r.gr_id = want.id GROUP BY r.gr_id)
  SELECT g.id, jsonb_build_object(
      'grn_id', g.id,
      'gr_no', g.gr_no,
      'date', g.date,
      'updated_at', g.updated_at,
      'invoice', COALESCE(hi.j, CASE WHEN g.invoiced THEN
        jsonb_build_object('id', NULL, 'inv_no', NULL, 'inv_fin_year', NULL, 'inv_prefix', NULL, 'invoice_label', NULL) END),
      'first_dispatch_date', fd.day,
      'lines', COALESCE(ln.j, '[]'::jsonb),
      'imported', im.doc_id IS NOT NULL,
      'rated_item_ids', COALESCE(ra.j, '[]'::jsonb))
  FROM want g
  LEFT JOIN head_inv hi ON hi.gr_id = g.id
  LEFT JOIN first_day fd ON fd.gr_id = g.id
  LEFT JOIN lines ln ON ln.gr_id = g.id
  LEFT JOIN imported im ON im.doc_id = g.id
  LEFT JOIN rated ra ON ra.gr_id = g.id
$$;
ALTER FUNCTION warehouse_sync.grn_lock_build(uuid[]) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.grn_lock_build(uuid[]) FROM PUBLIC, anon, authenticated, service_role;

-- The settings a role receives, by key (as get_rack_presets, get_document_numbering and get_charging_rule allow them). Staff
-- receive of the numbering only whether the server issues each document's number (Product, Q2).
CREATE FUNCTION warehouse_sync.settings_rows(p_role text) RETURNS TABLE(id text, body jsonb)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT 'charging_rule', warehouse_security.charging_rule_json(r)
           || jsonb_build_object('invoice_as_goods_leave', r.invoice_as_goods_leave, 'updated_at', r.updated_at, 'updated_by', r.updated_by)
    FROM warehouse_security.charging_rule r WHERE r.id AND p_role = 'admin'
  UNION ALL
  SELECT 'numbering', jsonb_object_agg(n.document_type, CASE WHEN p_role IN ('admin', 'supervisor')
           THEN warehouse_security.document_rule_json(n) || jsonb_build_object('fy_reset', n.fy_reset, 'server_issues', n.scheme <> 'free',
                  'updated_at', n.updated_at, 'updated_by', n.updated_by)
           ELSE jsonb_build_object('server_issues', n.scheme <> 'free') END)
    FROM warehouse_security.document_numbering n WHERE p_role IN ('admin', 'supervisor', 'staff') HAVING count(*) > 0
  UNION ALL
  SELECT 'rack_presets', warehouse_security.rack_presets_json() WHERE p_role IN ('admin', 'supervisor', 'staff')
$$;
ALTER FUNCTION warehouse_sync.settings_rows(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.settings_rows(text) FROM PUBLIC, anon, authenticated, service_role;

-- The rows of one entity as the caller may read them: by ids (p_ids), or a keyset page after p_after (p_limit rows; NULL = all).
-- Table entities follow the row rules of migration 137 and the columns the authenticated role may read (invoice: its granted
-- columns); a customer account gets only live rows (deleted_at IS NULL) of its customers and no column of customer_hidden_columns.
-- Administrators, supervisors and staff get soft-deleted rows with deleted_at set, as they read them today (Product, Q4).
CREATE FUNCTION warehouse_sync.entity_rows(p_role text, p_profile uuid, p_customers uuid[], p_entity text, p_ids text[], p_after text, p_limit integer)
 RETURNS TABLE(id text, body jsonb)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
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
  ELSIF p_entity = 'users_customers_new' THEN
    RETURN QUERY SELECT u.id::text, to_jsonb(u) FROM public.users_customers_new u
      WHERE (p_ids IS NULL OR u.id = ANY (p_ids::uuid[])) AND (p_after IS NULL OR u.id > p_after::uuid)
      ORDER BY u.id LIMIT CASE WHEN p_limit IS NULL THEN NULL ELSE p_limit END;
    RETURN;
  END IF;

  v_tbl := format('public.%I', p_entity)::regclass;
  SELECT string_agg(format('t.%I', a.attname), ', ' ORDER BY a.attnum) INTO v_cols
    FROM pg_attribute a
    WHERE a.attrelid = v_tbl AND a.attnum > 0 AND NOT a.attisdropped
      AND has_column_privilege('authenticated', v_tbl, a.attname::text, 'SELECT')
      AND NOT (v_cust AND a.attname::text = ANY (warehouse_sync.customer_hidden_columns()));
  v_where := CASE
    WHEN p_entity = 'items' THEN 'true'
    WHEN p_role IN ('admin', 'supervisor') THEN 'true'
    WHEN p_role = 'staff' THEN CASE WHEN p_entity IN ('grn_images', 'dispatch_images')
      THEN '(t.status = ''confirmed'' OR t.uploaded_by = $1)' ELSE 'true' END
    WHEN p_entity = 'customers' THEN 't.deleted_at IS NULL AND t.id = ANY ($2)'
    WHEN p_entity IN ('goodsreceived', 'dispatch', 'invoice') THEN 't.deleted_at IS NULL AND t.customer_id = ANY ($2)'
    WHEN p_entity = 'goodsreceived_trl' THEN
      'EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = t.gr_id AND g.deleted_at IS NULL AND g.customer_id = ANY ($2))'
    WHEN p_entity = 'grn_images' THEN
      't.status = ''confirmed'' AND EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = t.grn_id AND g.deleted_at IS NULL AND g.customer_id = ANY ($2))'
    WHEN p_entity = 'dispatch_trl' THEN
      'EXISTS (SELECT 1 FROM public.dispatch d WHERE d.id = t.disp_id AND d.deleted_at IS NULL AND d.customer_id = ANY ($2))'
    WHEN p_entity = 'dispatch_images' THEN
      't.status = ''confirmed'' AND EXISTS (SELECT 1 FROM public.dispatch d WHERE d.id = t.dispatch_id AND d.deleted_at IS NULL AND d.customer_id = ANY ($2))'
    WHEN p_entity = 'invoice_trl' THEN
      'EXISTS (SELECT 1 FROM public.invoice i WHERE i.id = t.invoice_id AND i.deleted_at IS NULL AND i.customer_id = ANY ($2))'
    ELSE 'false' END;
  RETURN QUERY EXECUTE format(
    'SELECT t.id::text, to_jsonb(x) FROM %s t CROSS JOIN LATERAL (SELECT %s) x WHERE (%s)%s%s ORDER BY t.id LIMIT %s',
    v_tbl, v_cols, v_where,
    CASE WHEN p_ids IS NOT NULL THEN ' AND t.id = ANY ($3::uuid[])' ELSE '' END,
    CASE WHEN p_after IS NOT NULL THEN ' AND t.id > $4::uuid' ELSE '' END,
    v_limit)
    USING p_profile, p_customers, p_ids, p_after;
END $$;
ALTER FUNCTION warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer) FROM PUBLIC, anon, authenticated, service_role;

-- The ids of one table entity that exist at all (whoever may read them).
CREATE FUNCTION warehouse_sync.existing_ids(p_entity text, p_ids text[]) RETURNS text[]
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE r text[];
BEGIN
  IF p_entity NOT IN ('customers', 'items', 'goodsreceived', 'goodsreceived_trl', 'grn_images', 'dispatch', 'dispatch_trl',
                      'dispatch_images', 'invoice', 'invoice_trl', 'user_profiles') THEN RETURN '{}'; END IF;
  EXECUTE format('SELECT COALESCE(array_agg(t.id::text), ''{}'') FROM public.%I t WHERE t.id = ANY ($1::uuid[])', p_entity) INTO r USING p_ids;
  RETURN r;
END $$;
ALTER FUNCTION warehouse_sync.existing_ids(text, text[]) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.existing_ids(text, text[]) FROM PUBLIC, anon, authenticated, service_role;

-- The log rows of [p_from, p_to) a caller receives, in transaction order (at most p_limit; NULL = all). A customer account gets the
-- catalogue and the rows whose old or new customer is one of its own; staff get no money mark and no assignment.
CREATE FUNCTION warehouse_sync.caller_log(p_role text, p_customers uuid[], p_from xid8, p_to xid8, p_limit integer)
 RETURNS SETOF warehouse_sync.change_log
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF p_role IN ('admin', 'supervisor', 'staff') THEN
    RETURN QUERY SELECT * FROM warehouse_sync.change_log l
      WHERE l.xid >= p_from AND l.xid < p_to AND (p_role <> 'staff' OR l.tbl NOT IN ('money', 'users_customers_new'))
      ORDER BY l.xid LIMIT p_limit;
  ELSIF p_role = 'customer' THEN
    RETURN QUERY SELECT u.* FROM (
      (SELECT * FROM warehouse_sync.change_log l WHERE l.tbl = 'items' AND l.xid >= p_from AND l.xid < p_to ORDER BY l.xid LIMIT p_limit)
      UNION
      (SELECT * FROM warehouse_sync.change_log l WHERE l.old_customer = ANY (p_customers) AND l.xid >= p_from AND l.xid < p_to
         AND l.tbl IN ('customers', 'goodsreceived', 'goodsreceived_trl', 'grn_images', 'dispatch', 'dispatch_trl', 'dispatch_images',
                       'invoice', 'invoice_trl', 'money')
       ORDER BY l.xid LIMIT p_limit)
      UNION
      (SELECT * FROM warehouse_sync.change_log l WHERE l.new_customer = ANY (p_customers) AND l.xid >= p_from AND l.xid < p_to
         AND l.tbl IN ('customers', 'goodsreceived', 'goodsreceived_trl', 'grn_images', 'dispatch', 'dispatch_trl', 'dispatch_images',
                       'invoice', 'invoice_trl', 'money')
       ORDER BY l.xid LIMIT p_limit)) u
      ORDER BY u.xid LIMIT p_limit;
  END IF;
END $$;
ALTER FUNCTION warehouse_sync.caller_log(text, uuid[], xid8, xid8, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.caller_log(text, uuid[], xid8, xid8, integer) FROM PUBLIC, anon, authenticated, service_role;

-- The (transaction, entity, id) keys log rows give a caller: the row's own entity, the rows the server adds to a document
-- (a GRN with its lots and photos, a dispatch with its lines and photos, an invoice with its lines) and the GRN locks they touch.
CREATE FUNCTION warehouse_sync.expand(p_role text, p_rows warehouse_sync.change_log[])
 RETURNS TABLE(xid xid8, e text, id text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  WITH l AS (SELECT * FROM unnest(p_rows)),
  k AS (
    SELECT l.xid, CASE WHEN l.tbl = 'user_profiles' AND p_role = 'staff' THEN 'people' ELSE l.tbl END AS e, l.row_key AS id FROM l
    UNION ALL SELECT l.xid, 'grn_lock', l.grn_id::text FROM l WHERE l.grn_id IS NOT NULL
    UNION ALL SELECT l.xid, 'goodsreceived_trl', t.id::text FROM l JOIN public.goodsreceived_trl t ON t.gr_id = l.row_key::uuid WHERE l.tbl = 'goodsreceived'
    UNION ALL SELECT l.xid, 'grn_images', i.id::text FROM l JOIN public.grn_images i ON i.grn_id = l.row_key::uuid WHERE l.tbl = 'goodsreceived'
    UNION ALL SELECT l.xid, 'dispatch_trl', t.id::text FROM l JOIN public.dispatch_trl t ON t.disp_id = l.row_key::uuid WHERE l.tbl = 'dispatch'
    UNION ALL SELECT l.xid, 'grn_lock', t.gr_id::text FROM l JOIN public.dispatch_trl t ON t.disp_id = l.row_key::uuid
      WHERE l.tbl = 'dispatch' AND t.gr_id IS NOT NULL
    UNION ALL SELECT l.xid, 'dispatch_images', i.id::text FROM l JOIN public.dispatch_images i ON i.dispatch_id = l.row_key::uuid WHERE l.tbl = 'dispatch'
    UNION ALL SELECT l.xid, 'invoice_trl', t.id::text FROM l JOIN public.invoice_trl t ON t.invoice_id = l.row_key::uuid WHERE l.tbl = 'invoice'
    UNION ALL SELECT l.xid, 'grn_lock', dt.gr_id::text FROM l JOIN public.invoice_trl t ON t.invoice_id = l.row_key::uuid
      JOIN public.dispatch_trl dt ON dt.id = t.disp_trl_id WHERE l.tbl = 'invoice' AND dt.gr_id IS NOT NULL)
  SELECT DISTINCT k.xid, k.e, k.id FROM k
  WHERE (k.e = ANY (warehouse_sync.entities(p_role)) OR (k.e = 'money' AND p_role IN ('admin', 'supervisor', 'customer')))
    AND NOT (k.e = 'settings' AND k.id = 'charging_rule' AND p_role <> 'admin')
$$;
ALTER FUNCTION warehouse_sync.expand(text, warehouse_sync.change_log[]) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.expand(text, warehouse_sync.change_log[]) FROM PUBLIC, anon, authenticated, service_role;

-- The current entries for a set of keys: upsert with the row as the caller reads it now; delete when the row is gone, when a
-- customer account may no longer read it (it left the account's customers or was soft-deleted), or for a derived entity; a row
-- that exists but that a staff role never could read (another person's pending photo) is left out.
-- p_keys: '<entity>' || chr(31) || '<id>'.
CREATE FUNCTION warehouse_sync.entries(p_role text, p_profile uuid, p_customers uuid[], p_keys text[]) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_e text; v_ids text[]; v_out jsonb := '[]'; v_rows jsonb; v_exist text[];
BEGIN
  FOR v_e, v_ids IN
    SELECT k.e, array_agg(k.id ORDER BY k.id) FROM (SELECT split_part(x, chr(31), 1) AS e, split_part(x, chr(31), 2) AS id FROM unnest(p_keys) x) k
    GROUP BY k.e ORDER BY array_position(warehouse_sync.entities('admin') || ARRAY['people', 'money'], k.e)
  LOOP
    IF v_e = 'money' THEN
      v_out := v_out || COALESCE((SELECT jsonb_agg(jsonb_build_object('e', 'money', 'id', x, 'op', 'stale') ORDER BY x) FROM unnest(v_ids) x), '[]');
      CONTINUE;
    END IF;
    SELECT COALESCE(jsonb_object_agg(r.id, r.body), '{}') INTO v_rows FROM warehouse_sync.entity_rows(p_role, p_profile, p_customers, v_e, v_ids, NULL, NULL) r;
    IF v_e IN ('settings', 'people', 'grn_lock', 'users_customers_new') OR p_role = 'customer' THEN
      v_exist := '{}';
    ELSE
      v_exist := warehouse_sync.existing_ids(v_e, v_ids);
    END IF;
    v_out := v_out || COALESCE((SELECT jsonb_agg(CASE WHEN v_rows ? x
          THEN jsonb_build_object('e', v_e, 'id', x, 'op', 'upsert', 'v', left(md5((v_rows->x)::text), 16), 'row', v_rows->x)
          ELSE jsonb_build_object('e', v_e, 'id', x, 'op', 'delete') END ORDER BY x)
        FROM unnest(v_ids) x WHERE v_rows ? x OR NOT x = ANY (v_exist)), '[]');
  END LOOP;
  RETURN v_out;
END $$;
ALTER FUNCTION warehouse_sync.entries(text, uuid, uuid[], text[]) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.entries(text, uuid, uuid[], text[]) FROM PUBLIC, anon, authenticated, service_role;

-- The time up to which data below the safe position is complete: the start of the transaction that holds it back, or now.
CREATE FUNCTION warehouse_sync.as_of(p_safe xid8) RETURNS timestamptz
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
  SELECT COALESCE(
    (SELECT min(a.xact_start) FROM pg_stat_activity a WHERE a.backend_xid = xid(p_safe) AND a.pid <> pg_backend_pid()),
    (SELECT min(p.prepared) FROM pg_prepared_xacts p WHERE p.transaction = xid(p_safe)),
    now())
$$;
ALTER FUNCTION warehouse_sync.as_of(xid8) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.as_of(xid8) FROM PUBLIC, anon, authenticated, service_role;

-- The copy key of a caller: <format>.<log id>.<access>.
CREATE FUNCTION warehouse_sync.copy_key(p_access text) RETURNS text
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$ SELECT s.format::text || '.' || s.log_id::text || '.' || p_access FROM warehouse_sync.state s $$;
ALTER FUNCTION warehouse_sync.copy_key(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.copy_key(text) FROM PUBLIC, anon, authenticated, service_role;

-- Checks a phone's position and copy key: NULL when they can be answered, else the refusal or the reload_all answer.
CREATE FUNCTION warehouse_sync.check_copy(p_access text, p_position text, p_copy text) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE s record; m text[]; v_pos xid8; v_reason text;
BEGIN
  IF p_position IS NULL OR p_position !~ '^[0-9]{1,20}$' OR p_position::numeric > 18446744073709551615 THEN
    RETURN warehouse_security.refuse('SYNC_BAD_POSITION', 'The sync position is not valid. Load the data again.', jsonb_build_object('position', p_position));
  END IF;
  m := regexp_match(COALESCE(p_copy, ''), '^([0-9]{1,9})\.([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.([0-9a-f]{32})$');
  IF m IS NULL THEN
    RETURN warehouse_security.refuse('SYNC_BAD_COPY', 'The sync key is not valid. Load the data again.', '{}'::jsonb);
  END IF;
  v_pos := p_position::xid8;
  SELECT * INTO s FROM warehouse_sync.state;
  v_reason := CASE
    WHEN m[1]::integer <> s.format THEN 'FORMAT_CHANGED'
    WHEN m[2]::uuid <> s.log_id THEN s.log_id_reason
    WHEN m[3] <> p_access THEN 'ACCESS_CHANGED'
    WHEN v_pos > pg_snapshot_xmax(pg_current_snapshot()) THEN 'POSITION_AHEAD'
    WHEN v_pos < s.floor THEN 'LOG_PURGED' END;
  IF v_reason IS NULL THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('reload_all', jsonb_build_object('reason', v_reason));
END $$;
ALTER FUNCTION warehouse_sync.check_copy(text, text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.check_copy(text, text, text) FROM PUBLIC, anon, authenticated, service_role;

-- ===== 4. the RPCs =====
CREATE FUNCTION public.get_sync_start() RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
 SET "TimeZone" = 'UTC'
AS $$
DECLARE c record; v_safe xid8 := pg_snapshot_xmin(pg_current_snapshot());
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_sync_start', '{}'::jsonb);
  c := warehouse_sync.caller();
  RETURN jsonb_build_object('success', true, 'format', (SELECT s.format FROM warehouse_sync.state s), 'copy', warehouse_sync.copy_key(c.access),
    'position', v_safe::text, 'as_of', warehouse_sync.as_of(v_safe), 'page_limit', 2000, 'entities', to_jsonb(warehouse_sync.entities(c.role)));
END $$;

CREATE FUNCTION public.get_sync_page(p_entity text, p_after text DEFAULT NULL, p_limit integer DEFAULT 2000) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
 SET "TimeZone" = 'UTC'
AS $$
DECLARE c record; v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 2000), 1), 2000); v_rows jsonb; v_next text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_sync_page', jsonb_build_object('p_entity', p_entity, 'p_after', p_after, 'p_limit', p_limit));
  c := warehouse_sync.caller();
  IF p_entity IS NULL OR NOT p_entity = ANY (warehouse_sync.entities(c.role)) THEN
    RETURN warehouse_security.refuse('SYNC_UNKNOWN_ENTITY', 'Unknown sync table.', jsonb_build_object('entity', p_entity));
  END IF;
  IF p_after IS NOT NULL AND p_entity <> 'settings' AND p_after !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RETURN warehouse_security.refuse('SYNC_BAD_POSITION', 'The sync position is not valid. Load the data again.', jsonb_build_object('position', p_after));
  END IF;
  -- One row more than the page tells whether another page follows.
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', x.id, 'v', left(md5(x.body::text), 16), 'row', x.body) ORDER BY x.n)
                    FILTER (WHERE x.n <= v_limit), '[]'::jsonb),
         max(x.id) FILTER (WHERE x.n = v_limit AND x.total > v_limit)
    INTO v_rows, v_next
    FROM (SELECT r.id, r.body, r.n, count(*) OVER () AS total
          FROM warehouse_sync.entity_rows(c.role, c.profile, c.customers, p_entity, NULL, p_after, v_limit + 1) WITH ORDINALITY r(id, body, n)) x;
  RETURN jsonb_build_object('success', true, 'entity', p_entity, 'copy', warehouse_sync.copy_key(c.access), 'rows', v_rows, 'next_after', v_next);
END $$;

CREATE FUNCTION public.get_sync_changes(p_position text, p_copy text, p_limit integer DEFAULT 2000) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
 SET "TimeZone" = 'UTC'
AS $$
DECLARE
  c record; v_check jsonb; v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 2000), 1), 2000);
  v_pos xid8; v_safe xid8 := pg_snapshot_xmin(pg_current_snapshot());
  v_rows warehouse_sync.change_log[]; v_cand warehouse_sync.change_log[]; v_last xid8; v_trunc boolean;
  v_take xid8[]; v_with_keys integer; v_first xid8; v_keys text[]; v_reload text[] := '{}'; v_end xid8; v_more boolean;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_sync_changes', jsonb_build_object('p_position', p_position, 'p_copy', p_copy, 'p_limit', p_limit));
  c := warehouse_sync.caller();
  v_check := warehouse_sync.check_copy(c.access, p_position, p_copy);
  IF v_check ? 'success' THEN RETURN v_check; END IF;
  IF v_check IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'format', (SELECT s.format FROM warehouse_sync.state s), 'position', p_position,
      'as_of', warehouse_sync.as_of(v_safe), 'more', false, 'reload_all', v_check->'reload_all', 'reload', '[]'::jsonb, 'changes', '[]'::jsonb);
  END IF;
  v_pos := p_position::xid8;

  -- The caller's log rows from the position, below the safe id (every transaction under it has ended), one more than a page:
  -- whole transactions are taken and the last one read may be cut, so it waits for the next call.
  v_rows := ARRAY(SELECT l FROM warehouse_sync.caller_log(c.role, c.customers, v_pos, v_safe, v_limit + 1) l);
  v_trunc := cardinality(v_rows) > v_limit;
  IF v_trunc THEN
    v_last := (SELECT max(r.xid) FROM unnest(v_rows) r);
    v_cand := ARRAY(SELECT r FROM unnest(v_rows) r WHERE r.xid < v_last);
  ELSE
    v_cand := v_rows;
  END IF;

  IF v_trunc AND cardinality(v_cand) = 0 THEN
    -- One transaction alone holds more rows than a page: the caller reloads the entities it touched (never a split page).
    v_reload := ARRAY(SELECT DISTINCT a FROM (SELECT DISTINCT r.tbl FROM warehouse_sync.caller_log(c.role, c.customers, v_last,
                        warehouse_sync.next_xid(v_last), NULL) r) t, unnest(warehouse_sync.affected(t.tbl)) a
                      WHERE a = ANY (warehouse_sync.entities(c.role)) ORDER BY a);
    v_end := warehouse_sync.next_xid(v_last);
    v_more := true;
  ELSE
    -- Entries per transaction after the server's additions; whole transactions in id order while the page stays within the limit.
    WITH per AS (SELECT k.xid, count(*) AS n FROM warehouse_sync.expand(c.role, v_cand) k GROUP BY k.xid),
         cum AS (SELECT per.xid, sum(per.n) OVER (ORDER BY per.xid) AS s FROM per)
    SELECT (SELECT count(*) FROM per), (SELECT min(per.xid) FROM per),
           ARRAY(SELECT cum.xid FROM cum WHERE cum.s <= v_limit ORDER BY cum.xid)
      INTO v_with_keys, v_first, v_take;
    IF v_with_keys > 0 AND cardinality(v_take) = 0 THEN
      -- The first transaction alone gives more entries than a page.
      v_reload := ARRAY(SELECT DISTINCT k.e FROM warehouse_sync.expand(c.role, ARRAY(SELECT r FROM unnest(v_cand) r WHERE r.xid = v_first)) k
                        WHERE k.e <> 'money' ORDER BY k.e);
      v_end := warehouse_sync.next_xid(v_first);
      v_more := true;
    ELSE
      SELECT array_agg(k.e || chr(31) || k.id) INTO v_keys
        FROM (SELECT DISTINCT x.e, x.id FROM warehouse_sync.expand(c.role, ARRAY(SELECT r FROM unnest(v_cand) r WHERE r.xid = ANY (v_take))) x) k;
      IF cardinality(v_take) = v_with_keys THEN
        IF v_trunc THEN v_end := v_last; v_more := true; ELSE v_end := GREATEST(v_pos, v_safe); v_more := false; END IF;
      ELSE
        v_end := warehouse_sync.next_xid((SELECT max(x) FROM unnest(v_take) x));
        v_more := true;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object('success', true, 'format', (SELECT s.format FROM warehouse_sync.state s), 'position', v_end::text,
    'as_of', warehouse_sync.as_of(v_safe), 'more', v_more, 'reload_all', NULL, 'reload', to_jsonb(v_reload),
    'changes', CASE WHEN v_keys IS NULL THEN '[]'::jsonb ELSE warehouse_sync.entries(c.role, c.profile, c.customers, v_keys) END);
END $$;

CREATE FUNCTION public.get_sync_checksums(p_position text, p_copy text, p_entities text[] DEFAULT NULL) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path = pg_catalog, public, pg_temp
 SET "TimeZone" = 'UTC'
AS $$
DECLARE c record; v_check jsonb; v_ents text[]; v_unsettled text[]; v_out jsonb := '[]'; e text; v_count bigint; v_sum numeric;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_sync_checksums', jsonb_build_object('p_position', p_position, 'p_copy', p_copy, 'p_entities', p_entities));
  c := warehouse_sync.caller();
  v_check := warehouse_sync.check_copy(c.access, p_position, p_copy);
  IF v_check ? 'success' THEN RETURN v_check; END IF;
  IF v_check IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'position', p_position, 'reload_all', v_check->'reload_all', 'entities', '[]'::jsonb);
  END IF;
  e := (SELECT x FROM unnest(p_entities) x WHERE x IS NULL OR NOT x = ANY (warehouse_sync.entities(c.role)) LIMIT 1);
  IF e IS NOT NULL OR (p_entities IS NOT NULL AND array_position(p_entities, NULL) IS NOT NULL) THEN
    RETURN warehouse_security.refuse('SYNC_UNKNOWN_ENTITY', 'Unknown sync table.', jsonb_build_object('entity', e));
  END IF;
  v_ents := ARRAY(SELECT x FROM unnest(warehouse_sync.entities(c.role)) x WHERE p_entities IS NULL OR x = ANY (p_entities));
  -- Entities with a committed change at or after the position are not at the same point on both sides: compared later.
  v_unsettled := ARRAY(SELECT DISTINCT a FROM (SELECT DISTINCT r.tbl FROM warehouse_sync.caller_log(c.role, c.customers, p_position::xid8,
                         pg_snapshot_xmax(pg_current_snapshot()), NULL) r) t, unnest(warehouse_sync.affected(t.tbl)) a);
  FOREACH e IN ARRAY v_ents LOOP
    SELECT count(*), COALESCE(sum(('x' || left(md5(r.body::text), 15))::bit(60)::bigint::numeric), 0) % 1152921504606846976
      INTO v_count, v_sum
      FROM warehouse_sync.entity_rows(c.role, c.profile, c.customers, e, NULL, NULL, NULL) r;
    v_out := v_out || jsonb_build_object('e', e, 'count', v_count, 'sum', v_sum::text, 'settled', NOT e = ANY (v_unsettled));
  END LOOP;
  RETURN jsonb_build_object('success', true, 'position', p_position, 'entities', v_out);
END $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.get_sync_start()', 'public.get_sync_page(text, text, integer)',
      'public.get_sync_changes(text, text, integer)', 'public.get_sync_checksums(text, text, text[])'] LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO supabase_admin', f);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f);
  END LOOP;
END $$;
COMMENT ON FUNCTION public.get_sync_start() IS 'WH-297: first load, step 1: format, copy key, starting position, as_of, page limit and the entities of the caller.';
COMMENT ON FUNCTION public.get_sync_page(text, text, integer) IS 'WH-297: first load, step 2: one keyset page (at most 2,000 rows) of one entity, as the caller may read it.';
COMMENT ON FUNCTION public.get_sync_changes(text, text, integer) IS 'WH-297: what changed since a position, whole transactions per page, or reload / reload_all.';
COMMENT ON FUNCTION public.get_sync_checksums(text, text, text[]) IS 'WH-297: count and checksum per entity of what the caller may read, for the daily comparison.';

-- ===== 5. get_grn_edit_state from the shared lock builder =====
CREATE OR REPLACE FUNCTION public.get_grn_edit_state(p_grn_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_row jsonb;
BEGIN
    PERFORM warehouse_security.authorize_rpc('get_grn_edit_state', jsonb_build_object('p_grn_id', p_grn_id));

    -- One statement reads the token (updated_at) and the lines; warehouse_sync.grn_lock_build is also the feed's grn_lock entity.
    SELECT b.body INTO v_row FROM warehouse_sync.grn_lock_build(ARRAY[p_grn_id]) b;

    IF v_row IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'GRN not found', 'message', 'GRN not found');
    END IF;

    RETURN jsonb_build_object('success', true, 'data', v_row - 'imported' - 'rated_item_ids');
END;
$$;

-- ===== 6. retention =====
INSERT INTO warehouse_maintenance.retention_policy(key, days, description)
VALUES ('sync_change_log', 120, 'Change log of the phones'' offline copies (which rows changed, no row data); a phone away longer reloads everything')
ON CONFLICT (key) DO NOTHING;

-- Deletes (p_apply) or counts the log rows older than the policy; the floor rises just above the highest id deleted, never down.
CREATE FUNCTION warehouse_sync.purge_log(p_now timestamptz, p_apply boolean) RETURNS bigint
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_cutoff timestamptz; v_n bigint; v_top xid8;
BEGIN
  SELECT p_now - make_interval(days => p.days) INTO v_cutoff FROM warehouse_maintenance.retention_policy p WHERE p.key = 'sync_change_log';
  IF v_cutoff IS NULL THEN RETURN 0; END IF;
  IF NOT p_apply THEN
    RETURN (SELECT count(*) FROM warehouse_sync.change_log l WHERE l.at < v_cutoff);
  END IF;
  WITH gone AS (DELETE FROM warehouse_sync.change_log l WHERE l.at < v_cutoff RETURNING l.xid)
  SELECT count(*), max(gone.xid) INTO v_n, v_top FROM gone;
  IF v_top IS NOT NULL THEN
    UPDATE warehouse_sync.state s SET floor = GREATEST(s.floor, warehouse_sync.next_xid(v_top));
  END IF;
  RETURN v_n;
END $$;
ALTER FUNCTION warehouse_sync.purge_log(timestamptz, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.purge_log(timestamptz, boolean) FROM PUBLIC, anon, authenticated, service_role;

-- Written against run_database_retention as migration 188 left it. Marker-count patch.
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
    IF position(p_old[i] IN p_new[i]) = 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % does not keep the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

SELECT pg_temp.patch_function('warehouse_maintenance.run_database_retention(timestamptz, boolean)'::regprocedure, ARRAY[
$m$    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('connection_gap_notes', affected);$m$,
$m$      'connection_gap_notes', (SELECT count(*) FROM warehouse_security.connection_gap_notes c$m$
], ARRAY[
$m$    GET DIAGNOSTICS affected = ROW_COUNT; result := result || jsonb_build_object('connection_gap_notes', affected);
    -- WH-297: the phones' change log past its retention; the floor rises with it.
    result := result || jsonb_build_object('sync_change_log', warehouse_sync.purge_log(p_now, true));$m$,
$m$      'sync_change_log', warehouse_sync.purge_log(p_now, false),
      'connection_gap_notes', (SELECT count(*) FROM warehouse_security.connection_gap_notes c$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

-- ===== 7. the dead trigger switch of "Edit GRN" =====
-- Their only target, trg_mark_stock_mvs_dirty_grn, no longer exists; definitions/update_grn.sql no longer calls them.
DROP FUNCTION public.safe_disable_grn_trl_triggers();
DROP FUNCTION public.safe_enable_grn_trl_triggers();
