-- Prints "seed|schema.table|rows N hash H masked …" for every ordinary table that has rows (outside system schemas,
-- extension members and the migration ledger), so the seed data a fresh chain install leaves can be compared, and
-- "seqstate|schema.sequence|last_value N" for every sequence (NULL = never called). Read-only.
-- The hash covers every row as JSON, in text order. A fresh install stamps some seed rows with the moment it ran and with
-- random ids, so two installs of the same chain cannot agree on those. Only these are left out of the hash (the line says
-- which columns): timestamp columns whose DEFAULT is a clock function, and uuid VALUES of version 1 or 4 in columns whose
-- default generates them. A fixed seeded date or a fixed id is compared. With the setting baseline.unmasked = on (catalog-diff
-- --unmasked, used when both sides come from the same installation) nothing is masked.
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
SET search_path = pg_catalog;
SET client_min_messages = warning;
SELECT line FROM (
SELECT format('seed|%s|rows %s hash %s masked %s', t.rel, t.n, t.h, t.masked) AS line, t.rel AS sortkey
FROM (
  SELECT quote_ident(ns.nspname) || '.' || quote_ident(c.relname) AS rel,
         (xpath('/row/n/text()', x))[1]::text AS n,
         (xpath('/row/h/text()', x))[1]::text AS h,
         m.masked
  FROM pg_class c
  JOIN pg_namespace ns ON ns.oid = c.relnamespace
  CROSS JOIN LATERAL (
    SELECT COALESCE(string_agg(a.attname, ',' ORDER BY a.attname) FILTER (WHERE k.kind IS NOT NULL), '') AS masked,
           COALESCE(string_agg(a.attname, ',' ORDER BY a.attname) FILTER (WHERE k.kind = 'ts'), '') AS ts_cols,
           COALESCE(string_agg(format('%L, CASE WHEN substr(t.%I::text, 15, 1) IN (''1'', ''4'') THEN ''masked''::text ELSE t.%I::text END', a.attname, a.attname, a.attname), ', ')
                    FILTER (WHERE k.kind = 'uuid'), '') AS uuid_pairs
      FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
      CROSS JOIN LATERAL (SELECT CASE
          WHEN COALESCE(current_setting('baseline.unmasked', true), '') = 'on' THEN NULL
          WHEN a.atttypid IN ('timestamptz'::regtype, 'timestamp'::regtype)
               AND pg_get_expr(d.adbin, d.adrelid) ~ 'now\(\)|CURRENT_TIMESTAMP|clock_timestamp|statement_timestamp|transaction_timestamp' THEN 'ts'
          WHEN a.atttypid = 'uuid'::regtype AND pg_get_expr(d.adbin, d.adrelid) ~ 'gen_random_uuid|uuid_generate_v1|uuid_generate_v4' THEN 'uuid'
        END AS kind) k
     WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped ) m
  CROSS JOIN LATERAL query_to_xml(
    format('SELECT count(*) AS n, md5(COALESCE(string_agg(j, E''\n'' ORDER BY j), '''')) AS h FROM (SELECT ((to_jsonb(t) - %L::text[]) || jsonb_build_object(%s))::text AS j FROM %s t) s',
           '{' || m.ts_cols || '}', CASE WHEN m.uuid_pairs = '' THEN '' ELSE m.uuid_pairs END, c.oid::regclass), false, true, '') x
  WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
    AND ns.nspname NOT IN ('pg_catalog', 'information_schema', 'warehouse_migrations') AND ns.nspname !~ '^pg_(toast|temp)'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
) t
WHERE t.n <> '0'
UNION ALL
SELECT format('seqstate|%s.%s|last_value %s', quote_ident(s.schemaname), quote_ident(s.sequencename), COALESCE(s.last_value::text, 'NULL')), s.schemaname || s.sequencename
  FROM pg_sequences s
 WHERE s.schemaname NOT IN ('pg_catalog', 'information_schema', 'warehouse_migrations') AND s.schemaname !~ '^pg_(toast|temp)'
   AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = (quote_ident(s.schemaname) || '.' || quote_ident(s.sequencename))::regclass AND d.deptype = 'e')
) q
ORDER BY sortkey;
