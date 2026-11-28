-- WH-303 "sync replaced entries" and "replaced entries in GRN details" (contract ~/ws/fresh/product/tech/app-offline-edit-grn.md 5.5,
-- case B12; PQ7, PQ8). Written before the build. tests/migrations.sh pipes tests/fixtures/gst_details.sql and
-- tests/sync_feed_contract.sql in front of this file, in the sync feed database of its own; this file commits. Fictional data only.
--
-- The feed gains the entity "grn_replacements": the UNCHECKED entries in get_grn_replacements' row shape (names resolved,
-- recorded_at included) for administrators, supervisors and staff, never for a customer account. Checking an entry is a delete for
-- the phones; the server keeps the row. get_grn_details answers `replacements` (unchecked, same row shape) for the three staff
-- roles and none for a customer account. A new entity is a feed format step: an older app must not meet it (the step itself is
-- Dev's to number; tests/sync_feed_contract.sql's 'bump_format' covers what a step does).
--
-- AGREE WITH DEVELOPMENT (WH-303): the entity name below; entries are made through public.apply_grn_changes (covered by
-- tests/grn_edit_field_changes.sql); the contract's wording "touches its GRN in the change log" is read as: the GRN's own row
-- (entity goodsreceived) reaches the phones as an upsert in the pull after an entry is checked.
\set ON_ERROR_STOP on

CREATE TEMP TABLE sr_keys(k text);
INSERT INTO sr_keys(k) VALUES ('id'), ('grn_id'), ('gr_no'), ('customer_name'), ('kind'), ('field'), ('newer_value'), ('newer_by_name'), ('newer_at'),
  ('sent_value'), ('sent_by_name'), ('sent_at'), ('recorded_at'), ('checked_by_name'), ('checked_at');
CREATE FUNCTION pg_temp.sr_apply(claims jsonb, grn uuid, loaded timestamptz, note_from text, note_to text, key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.sf_as(claims, format('SELECT public.apply_grn_changes(%L::uuid, %L::jsonb, %L)', grn,
    jsonb_build_object('v', 1, 'grnId', grn, 'loadedAt', loaded, 'recordedAt', now(),
      'header', jsonb_build_object('note', jsonb_build_object('from', note_from, 'to', note_to))), key)) $$;
-- The unchecked entries a phone holds, as ids.
CREATE FUNCTION pg_temp.sr_held(p text) RETURNS text[] LANGUAGE sql STABLE AS $$ SELECT ARRAY(SELECT x FROM unnest(pg_temp.sf_held(p, 'grn_replacements')) x ORDER BY x) $$;
-- The details' `replacements` of a GRN as a caller: the array, wherever the answer carries it.
CREATE FUNCTION pg_temp.sr_details(claims jsonb, grn uuid) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE a jsonb;
BEGIN
  a := pg_temp.sf_as(claims, format('SELECT public.get_grn_details(%L::uuid)', grn));
  RETURN COALESCE(a->'replacements', a#>'{data,replacements}', 'null'::jsonb);
END $$;

INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888897851', 'Replacement Feed Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888897852', 'Replacement Feed Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888897853', 'Replacement Feed Reader', 'customer', true, 'approved');
SELECT pg_temp.sf_login('9888897851') AS staff_claims \gset
SELECT pg_temp.sf_login('9888897852') AS sup_claims \gset
SELECT pg_temp.sf_login('9888897853') AS reader_claims \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Replacement Feed West'', ''9888897861'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Replacement Feed Ginger'', ''Bag'')')->>'success' = 'true', 'customer and item');
SELECT id AS west FROM public.customers WHERE name = 'Replacement Feed West' \gset
SELECT id AS ginger FROM public.items WHERE name = 'Replacement Feed Ginger' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897853', :'west', 'Replacement feed fixture'))::text = 'true',
  'the customer account is assigned');

SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'FSR1', :'west'::uuid, pg_temp.sf_lines(:'ginger'::uuid, 1, 'SR', 20)) AS grn \gset
SELECT updated_at AS load1 FROM public.goodsreceived WHERE id = :'grn' \gset
SELECT pg_temp.sr_apply(:'sf_admin_claims'::jsonb, :'grn', :'load1', NULL, 'Admin note', 'sr-1') AS s1 \gset
SELECT pg_temp.sr_apply(:'staff_claims'::jsonb, :'grn', :'load1', NULL, 'Staff note', 'sr-2') AS s2 \gset
SELECT pg_temp.sf_assert(:'s2'::jsonb->>'success' = 'true' AND (SELECT count(*) = 1 FROM warehouse_security.grn_replacements WHERE grn_id = :'grn'), 'premise: one entry: ' || :'s2');
SELECT id AS e1 FROM warehouse_security.grn_replacements WHERE grn_id = :'grn' \gset

SELECT pg_temp.sf_phone('admin', :'sf_admin_claims'::jsonb);
SELECT pg_temp.sf_phone('staff', :'staff_claims'::jsonb);
SELECT pg_temp.sf_phone('sup', :'sup_claims'::jsonb);
SELECT pg_temp.sf_phone('reader', :'reader_claims'::jsonb);
SELECT pg_temp.sf_first_load(p) FROM unnest(ARRAY['admin', 'staff', 'sup', 'reader']) p;

-- B12: the three staff roles hold the unchecked entry, in the row shape of get_grn_replacements; a customer account holds none.
SELECT pg_temp.sf_assert(pg_temp.sr_held(p) = ARRAY[:'e1'], 'B12: ' || p || ' holds the unchecked entry after the first load: ' || pg_temp.sr_held(p)::text)
  FROM unnest(ARRAY['admin', 'staff', 'sup']) p;
SELECT pg_temp.sf_assert(pg_temp.sr_held('reader') = ARRAY[]::text[], 'B12: a customer account holds no entry');
SELECT pg_temp.sf_assert((SELECT c.row ?& (SELECT array_agg(k) FROM sr_keys) AND c.row->>'gr_no' = 'FSR1' AND c.row->>'grn_id' = :'grn' AND c.row->>'field' = 'note'
    AND c.row->>'newer_by_name' = 'Sync Feed Administrator' AND c.row->>'sent_by_name' = 'Replacement Feed Staff' AND c.row->>'customer_name' = 'Replacement Feed West'
    AND c.row->'checked_at' = 'null'::jsonb AND strpos((c.row->'newer_value')::text, 'Admin note') > 0 AND strpos((c.row->'sent_value')::text, 'Staff note') > 0
    FROM pg_temp.sf_copy c WHERE c.slot = p AND c.e = 'grn_replacements' AND c.id = :'e1'),
  'B12: the row on ' || p || ' has every key of get_grn_replacements, resolved names, no checking') FROM unnest(ARRAY['admin', 'staff', 'sup']) p;
SELECT pg_temp.sf_assert(strpos(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.get_sync_start()')::text, 'grn_replacements') > 0
  AND strpos(pg_temp.sf_as(:'reader_claims'::jsonb, 'SELECT public.get_sync_start()')::text, 'grn_replacements') = 0,
  'B12: the start lists the entity for an administrator and not for a customer account');
SELECT pg_temp.sf_try('authenticated', :'reader_claims'::jsonb, 'SELECT public.get_sync_page(p_entity => ''grn_replacements'', p_after => NULL, p_limit => 100)') AS reader_page \gset
SELECT pg_temp.sf_assert(COALESCE(jsonb_array_length(:'reader_page'::jsonb#>'{answer,rows}'), 0) = 0, 'B12: a page asked for by name gives a customer account no entry: ' || :'reader_page');

-- details: unchecked entries for the staff roles, none for a customer account
SELECT pg_temp.sf_assert(jsonb_array_length(pg_temp.sr_details(c, :'grn'::uuid)) = 1 AND pg_temp.sr_details(c, :'grn'::uuid)#>>'{0,id}' = :'e1'
    AND pg_temp.sr_details(c, :'grn'::uuid)#>>'{0,gr_no}' = 'FSR1', 'B12: get_grn_details carries the entry for ' || who)
  FROM (VALUES ('admin', :'sf_admin_claims'::jsonb), ('staff', :'staff_claims'::jsonb), ('supervisor', :'sup_claims'::jsonb)) w(who, c);
SELECT pg_temp.sf_assert(COALESCE(jsonb_array_length(NULLIF(pg_temp.sr_details(:'reader_claims'::jsonb, :'grn'::uuid), 'null'::jsonb)), 0) = 0,
  'B12: get_grn_details carries no entry for a customer account: ' || pg_temp.sr_details(:'reader_claims'::jsonb, :'grn'::uuid)::text);

-- A new entry reaches the phones as an upsert and the copy equals a fresh load.
SELECT updated_at AS load2 FROM public.goodsreceived WHERE id = :'grn' \gset
SELECT pg_temp.sr_apply(:'sf_admin_claims'::jsonb, :'grn', :'load2', 'Staff note', 'Admin note 2', 'sr-3') AS s3 \gset
SELECT pg_temp.sr_apply(:'staff_claims'::jsonb, :'grn', :'load2', 'Staff note', 'Staff note 2', 'sr-4') AS s4 \gset
SELECT id AS e2 FROM warehouse_security.grn_replacements WHERE request_key = 'sr-4' \gset
SELECT pg_temp.sf_pull(p) FROM unnest(ARRAY['admin', 'staff', 'sup', 'reader']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_diff(p) = '' AND pg_temp.sr_held(p) = ARRAY(SELECT x FROM unnest(ARRAY[:'e1', :'e2']) x ORDER BY x)
    AND pg_temp.sf_ops(p, 'grn_replacements', :'e2', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_upsert'),
  'B12: a new entry reaches ' || p || ' as an upsert and its copy equals a fresh load: ' || pg_temp.sf_diff(p)) FROM unnest(ARRAY['admin', 'staff', 'sup']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_diff('reader') = '' AND pg_temp.sr_held('reader') = ARRAY[]::text[]
  AND pg_temp.sf_ops('reader', 'grn_replacements', :'e2') = '', 'B12: a customer account never meets the entry, in a first load or a pull');

-- Checking an entry is a delete for the phones; the server keeps the row.
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.mark_grn_replacements_checked(%L::uuid, ARRAY[%L]::uuid[])', :'grn', :'e1')) AS marked \gset
SELECT pg_temp.sf_assert(:'marked'::jsonb->>'success' = 'true' AND (SELECT checked_at IS NOT NULL FROM warehouse_security.grn_replacements WHERE id = :'e1'), 'premise: checked: ' || :'marked');
SELECT pg_temp.sf_pull(p) FROM unnest(ARRAY['admin', 'staff', 'sup', 'reader']) p;
SELECT pg_temp.sf_assert(pg_temp.sf_diff(p) = '' AND pg_temp.sr_held(p) = ARRAY[:'e2']
    AND pg_temp.sf_ops(p, 'grn_replacements', :'e1', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_delete'),
  'B12: checking removes the entry from ' || p || ' as a delete, and the copy equals a fresh load: ' || pg_temp.sf_diff(p)) FROM unnest(ARRAY['admin', 'staff', 'sup']) p;
SELECT pg_temp.sf_assert((SELECT count(*) = 1 FROM warehouse_security.grn_replacements WHERE id = :'e1'), 'B12 / PQ7: the server keeps the checked entry');
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'goodsreceived', :'grn', pg_temp.sf_last_pull(p)) = pg_temp.sf('op_upsert'),
  'B12: checking touches the GRN itself so details are read again on ' || p) FROM unnest(ARRAY['admin', 'staff', 'sup']) p;
SELECT pg_temp.sf_assert(pg_temp.sr_details(:'sf_admin_claims'::jsonb, :'grn'::uuid)#>>'{0,id}' = :'e2' AND jsonb_array_length(pg_temp.sr_details(:'sf_admin_claims'::jsonb, :'grn'::uuid)) = 1,
  'B12: get_grn_details no longer carries a checked entry');
-- ... and the phones' copy of the table entities is still what a direct read gives (an entry changes no other entity).
SELECT pg_temp.sf_assert(pg_temp.sf_check_direct('admin') = '', 'B12: the administrator''s table entities still equal a direct read: ' || pg_temp.sf_check_direct('admin'));

\echo 'WH-303 sync replaced entries (B12) checks passed.'
