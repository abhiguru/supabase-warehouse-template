-- Migration 95: the receipt snapshot is as wide as the catalog (TW-BE-012, TW-BE-013; owner decision D7, widen).
--
-- The catalog accepts an item name of 80 characters and a packaging of 40 (items.name varchar(80),
-- items.packaging varchar(40)), but a receipt line copies both into goodsreceived_trl.item_name varchar(30) and
-- packaging varchar(20). An accepted catalog item therefore failed save_grn with string_column_length and the whole
-- receipt rolled back. The owner chose to widen the snapshot, not to narrow the catalog.
--
-- 1. goodsreceived_trl.item_name becomes varchar(80) and packaging varchar(40). Widening a varchar rewrites nothing.
--    Four views read the columns and block the change: mv_grn_list and mv_dispatch_list (materialized, with their
--    indexes, the unique ones included, which REFRESH ... CONCURRENTLY needs), stock_summary and low_stock_alerts
--    (plain; low_stock_alerts reads stock_summary). The migration finds them from pg_depend, so it does not trust a
--    fixed list, records definition, owner, ACL and indexes, drops them (dependents first), widens, and recreates them
--    in the reverse order. It then checks that each definition, owner, ACL and index list is identical to what was
--    recorded and that the two columns of every recreated view are now 80 and 40 wide.
-- 2. The two materialized views are recreated WITH DATA in the same transaction, so they are correct at commit. The
--    migration does not touch the refresh queue: a list that was dirty stays dirty, and a write to another table that
--    commits during the rebuild marks its lists itself. (Marking from here would lock the queue rows after
--    goodsreceived_trl, the opposite order of save_grn, and could deadlock with a GRN save.) The mark triggers of
--    migration 91 are on the tables and name the views, so they need no change; the migration only checks that each of
--    the seven lists still exists as a materialized view with its queue row.
--    The migration takes advisory lock 71040 first, the document lock every GRN, dispatch and invoice writer takes at
--    its start, so such writers wait for the rebuild instead of queueing on table locks.
-- 3. save_grn and update_grn check the lengths first, before anything is written, and answer
--    { success: false, error_code: 'item_name_too_long' | 'packaging_too_long', message, error, data: { limit, index } }
--    (limit 80 / 40, index = position in p_items, from 0) instead of a database error. This follows migration 90's
--    patch of both functions; the markers occur exactly once.

-- Replaces one marker in a function body, failing unless it occurs exactly `expected` times.
CREATE FUNCTION pg_temp.patch_rpc(fn regprocedure, marker text, replacement text, expected integer DEFAULT 1) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE definition text := pg_get_functiondef(fn); occurrences integer;
BEGIN
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker,80);
  END IF;
  EXECUTE replace(definition,marker,replacement);
END $$;

-- The document lock every GRN, dispatch and invoice writer takes first (migration 46): they wait here, not on the
-- table locks below. The list worker never takes it.
SELECT pg_advisory_xact_lock(71040);

-- ---------------------------------------------------------------------------
-- 1. Record, drop, widen, recreate
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE m95_view ON COMMIT DROP AS
WITH RECURSIVE dep(oid, depth) AS (
  SELECT DISTINCT c.oid, 1
  FROM pg_depend d
  JOIN pg_rewrite r ON r.oid = d.objid
  JOIN pg_class c ON c.oid = r.ev_class
  JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
  WHERE d.refobjid = 'public.goodsreceived_trl'::regclass
    AND a.attname IN ('item_name', 'packaging') AND c.oid <> d.refobjid
  UNION
  SELECT c.oid, dep.depth + 1
  FROM dep
  JOIN pg_depend d ON d.refobjid = dep.oid
  JOIN pg_rewrite r ON r.oid = d.objid
  JOIN pg_class c ON c.oid = r.ev_class
  WHERE c.oid <> dep.oid
)
SELECT c.oid AS view_oid, c.relname, c.relkind, c.relowner, c.relacl, c.reloptions,
       pg_get_viewdef(c.oid) AS viewdef, max(dep.depth) AS depth
FROM dep JOIN pg_class c ON c.oid = dep.oid
GROUP BY c.oid, c.relname, c.relkind, c.relowner, c.relacl, c.reloptions;

CREATE TEMP TABLE m95_index ON COMMIT DROP AS
SELECT v.relname AS view_name, c.relname AS index_name, pg_get_indexdef(i.indexrelid) AS indexdef
FROM m95_view v
JOIN pg_index i ON i.indrelid = v.view_oid
JOIN pg_class c ON c.oid = i.indexrelid;

CREATE TEMP TABLE m95_acl ON COMMIT DROP AS
SELECT v.relname AS view_name, a.grantee, a.privilege_type, a.is_grantable
FROM m95_view v, LATERAL aclexplode(v.relacl) a;

DO $check$
DECLARE names text;
BEGIN
  SELECT string_agg(relname, ',' ORDER BY relname) INTO names FROM m95_view;
  IF names IS DISTINCT FROM 'low_stock_alerts,mv_dispatch_list,mv_grn_list,stock_summary' THEN
    RAISE EXCEPTION 'The views that read goodsreceived_trl.item_name or packaging are %, not the four this migration was written for', names;
  END IF;
  IF EXISTS (SELECT 1 FROM m95_view WHERE reloptions IS NOT NULL) THEN
    RAISE EXCEPTION 'A view to recreate has storage options; this migration does not carry them';
  END IF;
  IF EXISTS (SELECT 1 FROM m95_view WHERE relkind = 'm' AND NOT EXISTS (
        SELECT 1 FROM m95_index i JOIN pg_index x ON x.indexrelid = (SELECT oid FROM pg_class WHERE relname = i.index_name AND relnamespace = 'public'::regnamespace)
        WHERE i.view_name = m95_view.relname AND x.indisunique)) THEN
    RAISE EXCEPTION 'A materialized view has no unique index; REFRESH CONCURRENTLY would fail';
  END IF;
  -- Nothing else depends on the views (a function return type, a policy, a comment ...): a plain DROP would fail anyway,
  -- and CASCADE is never used.
END $check$;

-- Dependents first.
DO $drop$
DECLARE v record;
BEGIN
  FOR v IN SELECT * FROM m95_view ORDER BY depth DESC, relname LOOP
    EXECUTE format('DROP %s public.%I', CASE v.relkind WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'VIEW' END, v.relname);
  END LOOP;
END $drop$;

ALTER TABLE public.goodsreceived_trl
  ALTER COLUMN item_name TYPE varchar(80),
  ALTER COLUMN packaging TYPE varchar(40);

DO $create$
DECLARE v record; i record; a record; cur_acl aclitem[]; g record;
BEGIN
  FOR v IN SELECT * FROM m95_view ORDER BY depth, relname LOOP
    IF v.relkind = 'm' THEN
      EXECUTE format('CREATE MATERIALIZED VIEW public.%I AS %s WITH DATA', v.relname, rtrim(v.viewdef, E';\n '));
    ELSE
      EXECUTE format('CREATE VIEW public.%I AS %s', v.relname, rtrim(v.viewdef, E';\n '));
    END IF;
    IF (SELECT relowner FROM pg_class WHERE oid = format('public.%I', v.relname)::regclass) <> v.relowner THEN
      EXECUTE format('ALTER %s public.%I OWNER TO %I', CASE v.relkind WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END,
                     v.relname, (SELECT rolname FROM pg_roles WHERE oid = v.relowner));
    END IF;
    -- ACL: remove whatever the default privileges gave, then grant exactly what was recorded.
    FOR g IN SELECT DISTINCT a2.grantee FROM pg_class c, LATERAL aclexplode(c.relacl) a2
              WHERE c.oid = format('public.%I', v.relname)::regclass AND a2.grantee <> v.relowner LOOP
      EXECUTE format('REVOKE ALL ON public.%I FROM %s', v.relname,
                     CASE g.grantee WHEN 0 THEN 'PUBLIC' ELSE quote_ident((SELECT rolname FROM pg_roles WHERE oid = g.grantee)) END);
    END LOOP;
    FOR a IN SELECT * FROM m95_acl WHERE view_name = v.relname AND grantee <> v.relowner LOOP
      EXECUTE format('GRANT %s ON public.%I TO %s%s', a.privilege_type, v.relname,
                     CASE a.grantee WHEN 0 THEN 'PUBLIC' ELSE quote_ident((SELECT rolname FROM pg_roles WHERE oid = a.grantee)) END,
                     CASE WHEN a.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END);
    END LOOP;
    FOR i IN SELECT * FROM m95_index WHERE view_name = v.relname ORDER BY index_name LOOP
      EXECUTE i.indexdef;
    END LOOP;
  END LOOP;
END $create$;

-- The recreated views equal what was recorded, and carry the wider columns.
DO $verify$
DECLARE v record; now_def text; n integer;
BEGIN
  FOR v IN SELECT * FROM m95_view LOOP
    now_def := pg_get_viewdef(format('public.%I', v.relname)::regclass);
    IF now_def IS DISTINCT FROM v.viewdef THEN
      RAISE EXCEPTION 'The definition of % changed on recreation', v.relname;
    END IF;
    IF (SELECT c.relowner FROM pg_class c WHERE c.oid = format('public.%I', v.relname)::regclass) <> v.relowner THEN
      RAISE EXCEPTION 'The owner of % changed', v.relname;
    END IF;
    IF EXISTS (
        (SELECT grantee, privilege_type, is_grantable FROM m95_acl WHERE view_name = v.relname
         EXCEPT SELECT a.grantee, a.privilege_type, a.is_grantable FROM pg_class c, LATERAL aclexplode(c.relacl) a
                WHERE c.oid = format('public.%I', v.relname)::regclass)
        UNION ALL
        (SELECT a.grantee, a.privilege_type, a.is_grantable FROM pg_class c, LATERAL aclexplode(c.relacl) a
                WHERE c.oid = format('public.%I', v.relname)::regclass
         EXCEPT SELECT grantee, privilege_type, is_grantable FROM m95_acl WHERE view_name = v.relname)) THEN
      RAISE EXCEPTION 'The privileges of % changed', v.relname;
    END IF;
    IF EXISTS (
        (SELECT index_name, indexdef FROM m95_index WHERE view_name = v.relname
         EXCEPT SELECT c.relname, pg_get_indexdef(i.indexrelid) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
                WHERE i.indrelid = format('public.%I', v.relname)::regclass)
        UNION ALL
        (SELECT c.relname, pg_get_indexdef(i.indexrelid) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
                WHERE i.indrelid = format('public.%I', v.relname)::regclass
         EXCEPT SELECT index_name, indexdef FROM m95_index WHERE view_name = v.relname)) THEN
      RAISE EXCEPTION 'The indexes of % changed', v.relname;
    END IF;
  END LOOP;
  SELECT count(*) INTO n FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name IN ('stock_summary', 'low_stock_alerts')
     AND ((column_name = 'item_name' AND character_maximum_length = 80) OR (column_name = 'packaging' AND character_maximum_length = 40));
  IF n <> 4 THEN
    RAISE EXCEPTION 'stock_summary and low_stock_alerts must show item_name 80 and packaging 40, found % matching columns', n;
  END IF;
  IF (SELECT count(*) FROM pg_attribute WHERE attrelid = 'public.goodsreceived_trl'::regclass AND NOT attisdropped
        AND ((attname = 'item_name' AND atttypmod = 84) OR (attname = 'packaging' AND atttypmod = 44))) <> 2 THEN
    RAISE EXCEPTION 'goodsreceived_trl.item_name / packaging are not varchar(80) / varchar(40)';
  END IF;
END $verify$;

-- ---------------------------------------------------------------------------
-- 2. The list refresher sees the recreated views (migration 91)
-- ---------------------------------------------------------------------------
-- Read-only: the mark triggers are on tables and name the lists, so they stay valid. The queue is not written here.
DO $queue$
DECLARE missing text;
BEGIN
  SELECT string_agg(n, ',') INTO missing FROM unnest(warehouse_security.list_refresh_views()) AS n
   WHERE NOT EXISTS (SELECT 1 FROM public.mv_refresh_queue q WHERE q.mv_name = n)
      OR NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.relname = n AND c.relkind = 'm' AND c.relnamespace = 'public'::regnamespace);
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'A list lost its view or its queue row: %', missing;
  END IF;
END $queue$;

-- ---------------------------------------------------------------------------
-- 3. Length checks before any write
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE
  save_grn_fn regprocedure;
  update_grn_fn regprocedure;
  marker constant text := $m$    RETURN warehouse_security.rate_failure('RATES_MANAGER_ONLY', 'Only administrators and supervisors can set rates on a GRN');
  END IF;
$m$;
  replacement constant text := marker || $r$  -- Migration 95: a line's name and packaging fit the receipt columns (80 and 40 characters, as the catalog).
  IF jsonb_typeof(p_items) = 'array' THEN
    v_item_index := 0;
    FOR v_item IN SELECT e FROM jsonb_array_elements(p_items) AS e LOOP
      IF jsonb_typeof(v_item->'item_name') = 'string' AND char_length(v_item->>'item_name') > 80 THEN
        RETURN warehouse_security.grn_rate_failure('item_name_too_long',
          'An item name can have at most 80 characters', jsonb_build_object('limit', 80, 'index', v_item_index));
      END IF;
      IF jsonb_typeof(v_item->'packaging') = 'string' AND char_length(v_item->>'packaging') > 40 THEN
        RETURN warehouse_security.grn_rate_failure('packaging_too_long',
          'Packaging can have at most 40 characters', jsonb_build_object('limit', 40, 'index', v_item_index));
      END IF;
      v_item_index := v_item_index + 1;
    END LOOP;
  END IF;
$r$;
BEGIN
  SELECT p.oid::regprocedure INTO STRICT save_grn_fn FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'save_grn';
  SELECT p.oid::regprocedure INTO STRICT update_grn_fn FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'update_grn';
  CREATE TEMP TABLE m95_fn ON COMMIT DROP AS
    SELECT p.oid AS fn, p.proowner, p.prosecdef, p.proconfig, p.proacl FROM pg_proc p WHERE p.oid IN (save_grn_fn, update_grn_fn);
  PERFORM pg_temp.patch_rpc(save_grn_fn, marker, replacement);
  PERFORM pg_temp.patch_rpc(update_grn_fn, marker, replacement);
  IF (SELECT count(*) FROM m95_fn b JOIN pg_proc p ON p.oid = b.fn
       WHERE p.proowner = b.proowner AND p.prosecdef = b.prosecdef
         AND p.proconfig IS NOT DISTINCT FROM b.proconfig AND p.proacl IS NOT DISTINCT FROM b.proacl) <> 2 THEN
    RAISE EXCEPTION 'save_grn / update_grn lost their owner, SECURITY DEFINER, search_path or grants';
  END IF;
END $patch$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
