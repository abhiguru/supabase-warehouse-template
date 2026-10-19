-- Prints one line per catalog fact of the current database: "kind|key|detail". Read-only (temp objects only).
-- scripts/baseline/catalog-diff.mjs runs this in two containers and compares the sorted lines.
-- No OIDs and no passwords are printed. Schemas pg_catalog, information_schema and pg_toast*/pg_temp* are skipped,
-- and so are the definitions of extension members (the extensions list carries their name, version, schema and owner);
-- the ACLs of extension members ARE compared (kind ext-member). Names are printed relative to search_path = pg_catalog,
-- so every object outside pg_catalog is schema-qualified on both sides whatever the role's own search_path is.
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
\pset fieldsep '|'
SET search_path = pg_catalog;
SET client_min_messages = warning;

-- One line each: newlines and backslashes escaped.
CREATE FUNCTION pg_temp.e(t text) RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT replace(replace(replace(t, E'\\', E'\\\\'), E'\n', E'\\n'), E'\r', E'\\r') $$;
CREATE FUNCTION pg_temp.rn(o oid) RETURNS text LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN o = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(o) END $$;
-- One line per privilege of an ACL; a NULL ACL means the object-type default for the owner.
CREATE FUNCTION pg_temp.acl(kind text, key text, a aclitem[], deftype text, owner oid) RETURNS SETOF text LANGUAGE sql STABLE AS
$$ SELECT format('acl|%s|%s|%s -> %s %s%s', kind, key, pg_temp.rn(x.grantor), pg_temp.rn(x.grantee), x.privilege_type,
                 CASE WHEN x.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END)
     FROM aclexplode(COALESCE(a, CASE WHEN deftype IS NOT NULL THEN acldefault(deftype::"char", owner) END)) x $$;

CREATE TEMP VIEW t_ns AS
  SELECT n.oid, n.nspname, n.nspowner, n.nspacl FROM pg_namespace n
   WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname !~ '^pg_(toast|temp)';
CREATE TEMP VIEW t_cls AS
  SELECT c.*, n.nspname FROM pg_class c JOIN t_ns n ON n.oid = c.relnamespace
   WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f', 'c')
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e');
CREATE TEMP VIEW t_fn AS
  SELECT p.*, n.nspname FROM pg_proc p JOIN t_ns n ON n.oid = p.pronamespace
   WHERE NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e');
CREATE TEMP VIEW t_ty AS
  SELECT t.*, n.nspname FROM pg_type t JOIN t_ns n ON n.oid = t.typnamespace
   WHERE t.typtype IN ('e', 'd', 'c', 'r', 'm') AND (t.typtype <> 'c' OR EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = t.typrelid AND c.relkind = 'c'))
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e');

-- Expressions printed by pg_get_expr and friends may span lines: any newline left is escaped here.
SELECT replace(replace(line, E'\n', '\n'), E'\r', '\r') FROM (

-- schemas
SELECT format('schema|%s|owner %s', nspname, pg_get_userbyid(nspowner)) FROM t_ns
UNION ALL SELECT pg_temp.acl('schema', nspname, nspacl, 'n', nspowner) FROM t_ns

-- relations (tables, partitioned tables, views, materialized views, sequences, foreign tables, composite types)
UNION ALL SELECT format('relation|%s.%s|kind %s owner %s persistence %s rls %s forced %s partition %s bound %s options %s replident %s am %s',
    nspname, relname, relkind, pg_get_userbyid(relowner), relpersistence, relrowsecurity, relforcerowsecurity, relispartition,
    COALESCE(pg_get_expr(relpartbound, oid), ''), COALESCE(reloptions::text, ''), relreplident, COALESCE((SELECT amname FROM pg_am WHERE pg_am.oid = relam), ''))
  FROM t_cls
UNION ALL SELECT pg_temp.acl('relation', nspname || '.' || relname, relacl, CASE WHEN relkind = 'S' THEN 's' ELSE 'r' END, relowner) FROM t_cls WHERE relkind <> 'c'
UNION ALL SELECT format('partkey|%s.%s|%s', c.nspname, c.relname, pg_get_partkeydef(c.oid)) FROM t_cls c WHERE c.relkind = 'p'
UNION ALL SELECT format('inherits|%s.%s|%s', c.nspname, c.relname, string_agg(parent.oid::regclass::text, ',' ORDER BY i.inhseqno))
  FROM t_cls c JOIN pg_inherits i ON i.inhrelid = c.oid JOIN pg_class parent ON parent.oid = i.inhparent WHERE NOT c.relispartition GROUP BY c.nspname, c.relname
UNION ALL SELECT format('partof|%s.%s|%s', c.nspname, c.relname, i.inhparent::regclass::text)
  FROM t_cls c JOIN pg_inherits i ON i.inhrelid = c.oid WHERE c.relispartition
UNION ALL SELECT format('indexattach|%s|%s', i.inhrelid::regclass::text, i.inhparent::regclass::text)
  FROM pg_inherits i JOIN pg_class ic ON ic.oid = i.inhrelid JOIN t_ns n ON n.oid = ic.relnamespace WHERE ic.relkind IN ('i', 'I')
UNION ALL SELECT format('viewdef|%s.%s|%s', nspname, relname, pg_temp.e(pg_get_viewdef(oid))) FROM t_cls WHERE relkind IN ('v', 'm')
UNION ALL SELECT format('matview|%s.%s|populated %s', nspname, relname, relispopulated) FROM t_cls WHERE relkind = 'm'

-- columns in order, with their own ACLs
UNION ALL SELECT format('column|%s.%s|%s %s type %s notnull %s default %s identity %s generated %s collation %s storage %s compression %s statistics %s options %s',
    c.nspname, c.relname, row_number() OVER (PARTITION BY c.oid ORDER BY a.attnum), a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull,
    COALESCE(pg_get_expr(d.adbin, d.adrelid), ''), a.attidentity, a.attgenerated,
    COALESCE((SELECT collname FROM pg_collation WHERE pg_collation.oid = a.attcollation AND a.attcollation <> 100), ''), a.attstorage,
    a.attcompression, CASE WHEN a.attstattarget IS NULL OR a.attstattarget = -1 THEN 'default' ELSE a.attstattarget::text END, COALESCE(a.attoptions::text, ''))
  FROM t_cls c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
UNION ALL SELECT pg_temp.acl('column', c.nspname || '.' || c.relname || '.' || a.attname, a.attacl, NULL, c.relowner)
  FROM t_cls c JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped WHERE a.attacl IS NOT NULL

-- constraints and indexes
UNION ALL SELECT format('constraint|%s.%s|%s %s validated %s deferrable %s initially %s',
    c.nspname, c.relname, k.conname, pg_get_constraintdef(k.oid), k.convalidated, k.condeferrable, k.condeferred)
  FROM t_cls c JOIN pg_constraint k ON k.conrelid = c.oid
UNION ALL SELECT format('constraint|domain %s.%s|%s %s', t.nspname, t.typname, k.conname, pg_get_constraintdef(k.oid))
  FROM t_ty t JOIN pg_constraint k ON k.contypid = t.oid
UNION ALL SELECT format('index|%s.%s|%s valid %s replident %s clustered %s', c.nspname, c.relname, pg_get_indexdef(i.indexrelid), i.indisvalid, i.indisreplident, i.indisclustered)
  FROM t_cls c JOIN pg_index i ON i.indrelid = c.oid
UNION ALL SELECT format('statistics|%s.%s|%s', n.nspname, s.stxname, pg_get_statisticsobjdef(s.oid))
  FROM pg_statistic_ext s JOIN t_ns n ON n.oid = s.stxnamespace

-- sequences
UNION ALL SELECT format('sequence|%s.%s|type %s start %s inc %s min %s max %s cache %s cycle %s owned by %s',
    c.nspname, c.relname, format_type(s.seqtypid, NULL), s.seqstart, s.seqincrement, s.seqmin, s.seqmax, s.seqcache, s.seqcycle,
    COALESCE((SELECT d.refobjid::regclass::text || '.' || d.refobjsubid FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype IN ('a', 'i') AND d.refclassid = 'pg_class'::regclass LIMIT 1), ''))
  FROM t_cls c JOIN pg_sequence s ON s.seqrelid = c.oid

-- functions, procedures, aggregates
UNION ALL SELECT format('function|%s.%s(%s)|kind %s owner %s secdef %s volatility %s strict %s parallel %s leakproof %s cost %s rows %s config %s language %s def %s',
    nspname, proname, pg_get_function_identity_arguments(oid), prokind, pg_get_userbyid(proowner), prosecdef, provolatile, proisstrict, proparallel, proleakproof,
    procost, prorows, COALESCE(proconfig::text, ''), (SELECT lanname FROM pg_language WHERE pg_language.oid = prolang),
    CASE WHEN prokind IN ('f', 'p', 'w') THEN pg_temp.e(pg_get_functiondef(oid)) ELSE '' END)
  FROM t_fn
UNION ALL SELECT pg_temp.acl('function', nspname || '.' || proname || '(' || pg_get_function_identity_arguments(oid) || ')', proacl, 'f', proowner) FROM t_fn
UNION ALL SELECT format('aggregate|%s.%s(%s)|kind %s direct %s trans %s final %s combine %s serial %s deserial %s mtrans %s minv %s mfinal %s finalextra %s mfinalextra %s finalmodify %s mfinalmodify %s sortop %s transtype %s transspace %s mtranstype %s mtransspace %s init %s minit %s',
    f.nspname, f.proname, pg_get_function_identity_arguments(f.oid), a.aggkind, a.aggnumdirectargs, a.aggtransfn, a.aggfinalfn, a.aggcombinefn, a.aggserialfn, a.aggdeserialfn,
    a.aggmtransfn, a.aggminvtransfn, a.aggmfinalfn, a.aggfinalextra, a.aggmfinalextra, a.aggfinalmodify, a.aggmfinalmodify, a.aggsortop::regoperator,
    a.aggtranstype::regtype, a.aggtransspace, COALESCE(a.aggmtranstype::regtype::text, ''), a.aggmtransspace, COALESCE(a.agginitval, ''), COALESCE(a.aggminitval, ''))
  FROM t_fn f JOIN pg_aggregate a ON a.aggfnoid = f.oid

-- types
UNION ALL SELECT format('type|%s.%s|kind %s owner %s base %s notnull %s default %s labels %s', nspname, typname, typtype, pg_get_userbyid(typowner),
    CASE WHEN typtype = 'd' THEN format_type(typbasetype, typtypmod) ELSE '' END, typnotnull, COALESCE(typdefault, ''),
    COALESCE((SELECT string_agg(enumlabel, ',' ORDER BY enumsortorder) FROM pg_enum WHERE enumtypid = t_ty.oid), ''))
  FROM t_ty
UNION ALL SELECT pg_temp.acl('type', nspname || '.' || typname, typacl, 'T', typowner) FROM t_ty

-- triggers (not the internal constraint triggers) with their enabled state
UNION ALL SELECT format('trigger|%s.%s|%s enabled %s', c.nspname, c.relname, pg_get_triggerdef(g.oid), g.tgenabled)
  FROM t_cls c JOIN pg_trigger g ON g.tgrelid = c.oid WHERE NOT g.tgisinternal
UNION ALL SELECT format('rule|%s.%s|%s', c.nspname, c.relname, pg_temp.e(pg_get_ruledef(r.oid)))
  FROM t_cls c JOIN pg_rewrite r ON r.ev_class = c.oid WHERE r.rulename <> '_RETURN'
UNION ALL SELECT format('eventtrigger|%s|event %s owner %s enabled %s tags %s function %s', evtname, evtevent, pg_get_userbyid(evtowner), evtenabled,
    COALESCE(evttags::text, ''), evtfoid::regprocedure)
  FROM pg_event_trigger

-- row level security policies
UNION ALL SELECT format('policy|%s.%s|%s cmd %s permissive %s roles %s using %s check %s', c.nspname, c.relname, p.polname, p.polcmd, p.polpermissive,
    COALESCE((SELECT string_agg(pg_temp.rn(r), ',' ORDER BY pg_temp.rn(r)) FROM unnest(p.polroles) r), ''),
    COALESCE(pg_get_expr(p.polqual, p.polrelid), ''), COALESCE(pg_get_expr(p.polwithcheck, p.polrelid), ''))
  FROM t_cls c JOIN pg_policy p ON p.polrelid = c.oid

-- default privileges
UNION ALL SELECT format('defacl|role %s schema %s type %s|%s', pg_get_userbyid(d.defaclrole), COALESCE((SELECT nspname FROM pg_namespace WHERE oid = d.defaclnamespace), '*'), d.defaclobjtype, x)
  FROM pg_default_acl d, LATERAL (SELECT format('%s -> %s %s%s', pg_temp.rn(a.grantor), pg_temp.rn(a.grantee), a.privilege_type, CASE WHEN a.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END) AS x
    FROM aclexplode(d.defaclacl) a) q

-- comments (on objects outside system schemas and extensions)
UNION ALL SELECT format('comment|%s|%s', pg_describe_object(d.classoid, d.objoid, d.objsubid), pg_temp.e(d.description))
  FROM pg_description d
 WHERE d.classoid IN ('pg_class'::regclass, 'pg_proc'::regclass, 'pg_namespace'::regclass, 'pg_type'::regclass, 'pg_constraint'::regclass, 'pg_trigger'::regclass,
                      'pg_event_trigger'::regclass, 'pg_policy'::regclass, 'pg_extension'::regclass, 'pg_rewrite'::regclass)
   AND COALESCE((pg_identify_object(d.classoid, d.objoid, d.objsubid)).schema, '') !~ '^(pg_catalog|information_schema|pg_toast)'
   AND NOT (d.classoid = 'pg_namespace'::regclass AND (pg_identify_object(d.classoid, d.objoid, d.objsubid)).name ~ '^(pg_catalog|information_schema|pg_toast)')
   AND NOT EXISTS (SELECT 1 FROM pg_depend e WHERE e.classid = d.classoid AND e.objid = d.objoid AND e.objsubid = 0 AND e.deptype = 'e')
   AND pg_describe_object(d.classoid, d.objoid, d.objsubid) !~ '^toast table '
UNION ALL SELECT format('comment|%s|%s', pg_describe_object(d.classoid, d.objoid, 0), pg_temp.e(d.description))
  FROM pg_shdescription d WHERE d.classoid = 'pg_authid'::regclass

-- publications, subscriptions, extensions
UNION ALL SELECT format('publication|%s|owner %s all %s ins %s upd %s del %s trunc %s', pubname, pg_get_userbyid(pubowner), puballtables, pubinsert, pubupdate, pubdelete, pubtruncate) FROM pg_publication
UNION ALL SELECT format('publication-table|%s|%s.%s', pubname, schemaname, tablename) FROM pg_publication_tables
UNION ALL SELECT format('subscription|%s|owner %s', subname, pg_get_userbyid(subowner)) FROM pg_subscription
UNION ALL SELECT format('extension|%s|version %s schema %s relocatable %s owner %s', e.extname, e.extversion, n.nspname, e.extrelocatable, pg_get_userbyid(e.extowner)) FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
UNION ALL SELECT pg_temp.acl('ext-member', pg_describe_object('pg_proc'::regclass, p.oid, 0), p.proacl, 'f', p.proowner)
  FROM pg_proc p JOIN pg_depend d ON d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e' AND d.refclassid = 'pg_extension'::regclass
UNION ALL SELECT pg_temp.acl('ext-member', pg_describe_object('pg_class'::regclass, c.oid, 0), c.relacl, CASE WHEN c.relkind = 'S' THEN 's' ELSE 'r' END, c.relowner)
  FROM pg_class c JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.objsubid = 0 AND d.deptype = 'e' AND d.refclassid = 'pg_extension'::regclass
 WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S')
UNION ALL SELECT pg_temp.acl('parameter', parname, paracl, NULL, 0) FROM pg_parameter_acl
UNION ALL SELECT format('language|%s|trusted %s owner %s', lanname, lanpltrusted, pg_get_userbyid(lanowner)) FROM pg_language WHERE lanname NOT IN ('internal', 'c', 'sql')
UNION ALL SELECT pg_temp.acl('language', lanname, lanacl, 'l', lanowner) FROM pg_language WHERE lanname NOT IN ('internal', 'c', 'sql')

-- operators, casts, collations, foreign servers outside system schemas and extensions
UNION ALL SELECT format('operator|%s', pg_describe_object('pg_operator'::regclass, o.oid, 0)) FROM pg_operator o JOIN t_ns n ON n.oid = o.oprnamespace
  WHERE NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_operator'::regclass AND d.objid = o.oid AND d.deptype = 'e')
UNION ALL SELECT format('cast|%s', pg_describe_object('pg_cast'::regclass, c.oid, 0)) FROM pg_cast c WHERE c.oid >= 16384
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_cast'::regclass AND d.objid = c.oid AND d.deptype = 'e')
UNION ALL SELECT format('collation|%s.%s', n.nspname, c.collname) FROM pg_collation c JOIN t_ns n ON n.oid = c.collnamespace
  WHERE NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_collation'::regclass AND d.objid = c.oid AND d.deptype = 'e')
UNION ALL SELECT format('foreign-server|%s|%s', s.srvname, pg_get_userbyid(s.srvowner)) FROM pg_foreign_server s

-- roles (attributes without the OID and the password), memberships (the INHERIT/SET options of PG16+ are not printed:
-- PG15 has none, and the role's own INHERIT attribute is in the role line), role/database settings
UNION ALL SELECT format('role|%s|%s', r.rolname, to_jsonb(r) - 'oid' - 'rolpassword') FROM pg_roles r WHERE r.rolname !~ '^pg_'
UNION ALL SELECT format('member|%s in %s|admin %s grantor %s', pg_get_userbyid(m.member), pg_get_userbyid(m.roleid), m.admin_option, pg_get_userbyid(m.grantor))
  FROM pg_auth_members m
UNION ALL SELECT format('setting|role %s db %s|%s', COALESCE(pg_get_userbyid(NULLIF(s.setrole, 0)), '*'), COALESCE((SELECT datname FROM pg_database WHERE oid = s.setdatabase), '*'), x)
  FROM pg_db_role_setting s, unnest(s.setconfig) x
UNION ALL SELECT format('database|%s|owner %s encoding %s collate %s ctype %s', datname, pg_get_userbyid(datdba), pg_encoding_to_char(encoding), datcollate, datctype)
  FROM pg_database WHERE datname = current_database()
UNION ALL SELECT pg_temp.acl('database', datname, datacl, 'd', datdba) FROM pg_database WHERE datname = current_database()

) q(line) ORDER BY line;
