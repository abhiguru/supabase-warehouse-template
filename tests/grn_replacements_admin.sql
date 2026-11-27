-- WH-303 "replaced entries": the administrators' list and "mark checked" (contract ~/ws/fresh/product/tech/app-offline-edit-grn.md 5.4,
-- cases B11 and B11b; Product PQ7 and PQ8). Written before the build. tests/migrations.sh pipes tests/fixtures/gst_details.sql and
-- tests/sync_feed_contract.sql in front of this file, in the sync feed database of its own (committed statements: an entry needs a
-- value set after the person's load, and now() does not move inside one transaction). Fictional data.
--
-- AGREE WITH DEVELOPMENT (WH-303):
--   public.get_grn_replacements(p_from date, p_to date, p_state text, p_limit int, p_offset int) -> { success: true, rows: [row], total } (5.8; fr_rows below also reads a bare array, or an object
--     whose "data" is the array); row keys as the contract lists them (ROW_KEYS below); newest first by sent_at; p_state 'unchecked' or 'checked', NULL both, else STATE_INVALID
--   public.mark_grn_replacements_checked(p_grn_id uuid, p_ids uuid[]) -> { success: true, checked: n } (n = newly checked)
--   p_state values (the card's tags "To check" and "Checked"): the two names below. NULL = both.
--   entries are made through public.apply_grn_changes (tests/grn_edit_field_changes.sql covers that function).
\set ON_ERROR_STOP on
\set state_open 'unchecked'
\set state_checked 'checked'

CREATE TEMP TABLE fr_keys(k text);
INSERT INTO fr_keys(k) VALUES ('id'), ('grn_id'), ('gr_no'), ('customer_name'), ('kind'), ('field'), ('newer_value'), ('newer_by_name'), ('newer_at'),
  ('sent_value'), ('sent_by_name'), ('sent_at'), ('recorded_at'), ('checked_by_name'), ('checked_at');   -- ROW_KEYS
CREATE FUNCTION pg_temp.fr_rows(a jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN jsonb_typeof(a) = 'array' THEN a WHEN a ? 'data' THEN a->'data' WHEN a ? 'rows' THEN a->'rows' ELSE '[]'::jsonb END $$;
CREATE FUNCTION pg_temp.fr_list(claims jsonb, args text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.fr_rows(pg_temp.sf_as(claims, 'SELECT public.get_grn_replacements(' || args || ')')) $$;
CREATE FUNCTION pg_temp.fr_apply(claims jsonb, grn uuid, loaded timestamptz, changes jsonb, key text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.sf_as(claims, format('SELECT public.apply_grn_changes(%L::uuid, %L::jsonb, %L)', grn,
    jsonb_build_object('v', 1, 'grnId', grn, 'loadedAt', loaded, 'recordedAt', now()) || changes, key)) $$;
CREATE FUNCTION pg_temp.fr_note(to_value text, from_value text) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('header', jsonb_build_object('note', jsonb_build_object('from', from_value, 'to', to_value))) $$;

INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888897831', 'Replacement Staff A', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888897832', 'Replacement Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888897833', 'Replacement Reader', 'customer', true, 'approved');
SELECT pg_temp.sf_login('9888897831') AS a_claims \gset
SELECT pg_temp.sf_login('9888897832') AS sup_claims \gset
SELECT pg_temp.sf_login('9888897833') AS reader_claims \gset
SELECT id AS a_profile FROM public.user_profiles WHERE mobile = '919888897831' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Replacement West'', ''9888897841'')')->>'success' = 'true'
  AND pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_item(''Replacement Mustard'', ''Bag'')')->>'success' = 'true', 'customer and item');
SELECT id AS west FROM public.customers WHERE name = 'Replacement West' \gset
SELECT id AS mustard FROM public.items WHERE name = 'Replacement Mustard' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897833', :'west', 'Replacement fixture'))::text = 'true',
  'the customer account is assigned');

-- Fixtures: two GRNs; on each the administrator sets the note after the staff member's load, then the staff member's send replaces it.
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'FRA1', :'west'::uuid, pg_temp.sf_lines(:'mustard'::uuid, 1, 'RA', 20)) AS grn1 \gset
SELECT pg_temp.sf_save_grn(:'sf_admin_claims'::jsonb, 'FRA2', :'west'::uuid, pg_temp.sf_lines(:'mustard'::uuid, 1, 'RB', 20)) AS grn2 \gset
SELECT updated_at AS load1 FROM public.goodsreceived WHERE id = :'grn1' \gset
SELECT pg_temp.fr_apply(:'sf_admin_claims'::jsonb, :'grn1', :'load1', pg_temp.fr_note('Admin note 1', NULL), 'fr-1') AS s1 \gset
SELECT pg_temp.fr_apply(:'a_claims'::jsonb, :'grn1', :'load1', pg_temp.fr_note('Staff note 1', NULL), 'fr-2') AS s2 \gset
SELECT updated_at AS load2 FROM public.goodsreceived WHERE id = :'grn2' \gset
SELECT pg_temp.fr_apply(:'sf_admin_claims'::jsonb, :'grn2', :'load2', pg_temp.fr_note('Admin note 2', NULL), 'fr-3') AS s3 \gset
SELECT pg_temp.fr_apply(:'a_claims'::jsonb, :'grn2', :'load2', pg_temp.fr_note('Staff note 2', NULL), 'fr-4') AS s4 \gset
SELECT pg_temp.sf_assert(:'s2'::jsonb->>'success' = 'true' AND :'s4'::jsonb->>'success' = 'true'
  AND (SELECT count(*) = 2 FROM warehouse_security.grn_replacements WHERE request_key IN ('fr-2', 'fr-4')), 'premise: two entries, one on each GRN: ' || :'s2' || :'s4');
SELECT id AS e1 FROM warehouse_security.grn_replacements WHERE request_key = 'fr-2' \gset
SELECT id AS e2 FROM warehouse_security.grn_replacements WHERE request_key = 'fr-4' \gset

-- B11: the list, as an administrator: every row has every key, names are resolved, newest first.
SELECT pg_temp.fr_list(:'sf_admin_claims'::jsonb, 'current_date - 120, current_date, NULL, 100, 0') AS listed \gset
SELECT pg_temp.sf_assert(jsonb_array_length(:'listed'::jsonb) = 2 AND (SELECT bool_and(r ?& (SELECT array_agg(k) FROM fr_keys)) FROM jsonb_array_elements(:'listed'::jsonb) r),
  'B11: two rows, each with every key of the contract: ' || :'listed');
SELECT pg_temp.sf_assert(:'listed'::jsonb#>>'{0,id}' = :'e2' AND :'listed'::jsonb#>>'{1,id}' = :'e1', 'B11: newest first: ' || :'listed');
SELECT pg_temp.sf_assert(:'listed'::jsonb#>>'{1,gr_no}' = 'FRA1' AND :'listed'::jsonb#>>'{1,customer_name}' = 'Replacement West' AND :'listed'::jsonb#>>'{1,field}' = 'note'
  AND :'listed'::jsonb#>>'{1,kind}' = 'field' AND :'listed'::jsonb#>>'{1,newer_by_name}' = 'Sync Feed Administrator' AND :'listed'::jsonb#>>'{1,sent_by_name}' = 'Replacement Staff A'
  AND strpos((:'listed'::jsonb#>'{1,newer_value}')::text, 'Admin note 1') > 0 AND strpos((:'listed'::jsonb#>'{1,sent_value}')::text, 'Staff note 1') > 0
  AND :'listed'::jsonb#>'{1,checked_by_name}' = 'null'::jsonb AND :'listed'::jsonb#>'{1,checked_at}' = 'null'::jsonb AND :'listed'::jsonb#>>'{1,grn_id}' = :'grn1',
  'B11: the row names the GRN, the customer, the field, both values and both people, and is not checked: ' || :'listed');
-- The answer's shape (5.8): { success: true, rows: [...], total } with total the count the filter matches, before p_limit and p_offset.
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.get_grn_replacements(current_date - 120, current_date, NULL, 1, 0)') AS listed_raw \gset
SELECT pg_temp.sf_assert(:'listed_raw'::jsonb->>'success' = 'true' AND jsonb_typeof(:'listed_raw'::jsonb->'rows') = 'array' AND jsonb_array_length(:'listed_raw'::jsonb->'rows') = 1
  AND (:'listed_raw'::jsonb->>'total')::int = 2, 'B11: the answer is { success, rows, total } and total counts both entries although one row is asked for: ' || :'listed_raw');
-- p_state takes 'unchecked', 'checked' or NULL (both); anything else is STATE_INVALID.
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.get_grn_replacements(current_date - 120, current_date, ''to check'', 100, 0)') AS bad_state \gset
SELECT pg_temp.sf_assert(:'bad_state'::jsonb->>'success' = 'false' AND :'bad_state'::jsonb->>'reason' = 'STATE_INVALID', 'B11: another p_state is STATE_INVALID: ' || :'bad_state');
-- paging
SELECT pg_temp.sf_assert(jsonb_array_length(pg_temp.fr_list(:'sf_admin_claims'::jsonb, 'current_date - 120, current_date, NULL, 1, 0')) = 1
  AND pg_temp.fr_list(:'sf_admin_claims'::jsonb, 'current_date - 120, current_date, NULL, 1, 1')#>>'{0,id}' = :'e1', 'B11: p_limit and p_offset page the list');
-- who may read and check: administrators only
SELECT pg_temp.sf_assert(NOT EXISTS (SELECT 1 FROM (VALUES ('a', :'a_claims'::jsonb), ('sup', :'sup_claims'::jsonb), ('reader', :'reader_claims'::jsonb), ('none', NULL::jsonb)) w(who, c),
    LATERAL (SELECT pg_temp.sf_try('authenticated', w.c, 'SELECT public.get_grn_replacements(current_date - 120, current_date, NULL, 100, 0)') AS t) x
    WHERE jsonb_array_length(pg_temp.fr_rows(x.t->'answer')) > 0),
  'B11: staff, a supervisor, a customer account and a caller with no role are shown no entry by get_grn_replacements');
SELECT pg_temp.sf_try('authenticated', :'sup_claims'::jsonb, format('SELECT public.mark_grn_replacements_checked(%L::uuid, ARRAY[%L]::uuid[])', :'grn1', :'e1')) AS sup_mark \gset
SELECT pg_temp.sf_try('authenticated', :'a_claims'::jsonb, format('SELECT public.mark_grn_replacements_checked(%L::uuid, ARRAY[%L]::uuid[])', :'grn1', :'e1')) AS staff_mark \gset
SELECT pg_temp.sf_try('authenticated', :'reader_claims'::jsonb, format('SELECT public.mark_grn_replacements_checked(%L::uuid, ARRAY[%L]::uuid[])', :'grn1', :'e1')) AS reader_mark \gset
SELECT pg_temp.sf_assert(COALESCE(:'sup_mark'::jsonb#>>'{answer,success}', 'raised') <> 'true' AND COALESCE(:'staff_mark'::jsonb#>>'{answer,success}', 'raised') <> 'true'
  AND COALESCE(:'reader_mark'::jsonb#>>'{answer,success}', 'raised') <> 'true' AND (SELECT checked_at IS NULL AND checked_by IS NULL FROM warehouse_security.grn_replacements WHERE id = :'e1'),
  'B11: a supervisor, staff and a customer account cannot mark checked, and nothing changed');
SELECT pg_temp.sf_assert(pg_temp.sf_try('authenticated', :'sup_claims'::jsonb, 'SELECT public.get_grn_replacements(current_date - 120, current_date, NULL, 100, 0)')->>'sqlstate' IS NOT NULL
  OR jsonb_array_length(pg_temp.fr_rows(pg_temp.sf_try('authenticated', :'sup_claims'::jsonb, 'SELECT public.get_grn_replacements(current_date - 120, current_date, NULL, 100, 0)')->'answer')) = 0,
  'B11: a supervisor is refused or shown nothing');

-- B11: mark checked: exactly the entries the screen showed; one that arrived meanwhile stays "To check"; repeating is a success.
SELECT updated_at AS load1b FROM public.goodsreceived WHERE id = :'grn1' \gset
SELECT pg_temp.fr_apply(:'sf_admin_claims'::jsonb, :'grn1', :'load1b', pg_temp.fr_note('Admin note 3', 'Staff note 1'), 'fr-5') AS s5 \gset
SELECT pg_temp.fr_apply(:'a_claims'::jsonb, :'grn1', :'load1b', pg_temp.fr_note('Staff note 3', 'Staff note 1'), 'fr-6') AS s6 \gset
SELECT id AS e3 FROM warehouse_security.grn_replacements WHERE request_key = 'fr-6' \gset
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.mark_grn_replacements_checked(%L::uuid, ARRAY[%L]::uuid[])', :'grn1', :'e1')) AS marked \gset
SELECT pg_temp.sf_assert(:'marked'::jsonb->>'success' = 'true' AND (SELECT checked_by = :'sf_admin_profile'::uuid AND checked_at IS NOT NULL FROM warehouse_security.grn_replacements WHERE id = :'e1')
  AND (SELECT checked_by IS NULL AND checked_at IS NULL FROM warehouse_security.grn_replacements WHERE id = :'e3')
  AND (SELECT checked_by IS NULL FROM warehouse_security.grn_replacements WHERE id = :'e2'), 'B11: only the entry named is checked: ' || :'marked');
SELECT checked_at AS first_checked FROM warehouse_security.grn_replacements WHERE id = :'e1' \gset
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.mark_grn_replacements_checked(%L::uuid, ARRAY[%L]::uuid[])', :'grn1', :'e1')) AS marked_again \gset
SELECT pg_temp.sf_assert(:'marked_again'::jsonb->>'success' = 'true' AND (SELECT checked_at = :'first_checked'::timestamptz FROM warehouse_security.grn_replacements WHERE id = :'e1'),
  'B11: checking again is a success and keeps the first checking: ' || :'marked_again');
-- 5.8: the answer counts the entries newly checked; the ids of another GRN and ids already checked are skipped, not refused.
SELECT pg_temp.sf_assert((:'marked'::jsonb->>'checked')::int = 1 AND (:'marked_again'::jsonb->>'checked')::int = 0,
  'B11: checked is the number of entries newly checked (1, then 0 on the repeat): ' || :'marked' || :'marked_again');
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.mark_grn_replacements_checked(%L::uuid, ARRAY[%L]::uuid[])', :'grn1', :'e2')) AS marked_foreign \gset
SELECT pg_temp.sf_assert(:'marked_foreign'::jsonb->>'success' = 'true' AND (:'marked_foreign'::jsonb->>'checked')::int = 0
  AND (SELECT checked_by IS NULL AND checked_at IS NULL FROM warehouse_security.grn_replacements WHERE id = :'e2'),
  'B11: an id that belongs to another GRN is skipped, not refused, and stays "To check": ' || :'marked_foreign');
-- the state filter and the checker's name
SELECT pg_temp.fr_list(:'sf_admin_claims'::jsonb, format('current_date - 120, current_date, %L, 100, 0', :'state_checked')) AS only_checked \gset
SELECT pg_temp.fr_list(:'sf_admin_claims'::jsonb, format('current_date - 120, current_date, %L, 100, 0', :'state_open')) AS only_open \gset
SELECT pg_temp.sf_assert(jsonb_array_length(:'only_checked'::jsonb) = 1 AND :'only_checked'::jsonb#>>'{0,id}' = :'e1' AND :'only_checked'::jsonb#>>'{0,checked_by_name}' = 'Sync Feed Administrator'
  AND jsonb_array_length(:'only_open'::jsonb) = 2 AND NOT (:'only_open'::jsonb @> jsonb_build_array(jsonb_build_object('id', :'e1'))),
  'B11: the state filter separates "To check" from "Checked"; a checked row names who checked: ' || :'only_checked' || ' / ' || :'only_open');

-- B11 (PQ7): any p_from: an entry older than 120 days is returned when p_from reaches back to it, and not otherwise.
UPDATE warehouse_security.grn_replacements SET sent_at = now() - interval '200 days', newer_at = now() - interval '201 days', recorded_at = NULL WHERE id = :'e2';
SELECT pg_temp.sf_assert(NOT (pg_temp.fr_list(:'sf_admin_claims'::jsonb, 'current_date - 120, current_date, NULL, 100, 0') @> jsonb_build_array(jsonb_build_object('id', :'e2')))
  AND pg_temp.fr_list(:'sf_admin_claims'::jsonb, 'current_date - 300, current_date, NULL, 100, 0') @> jsonb_build_array(jsonb_build_object('id', :'e2')),
  'B11 / PQ7: the last 120 days leave out a 200-day-old entry, p_from 300 days back shows it');

-- B11b (PQ7): the server never deletes an entry: checked ones stay, a deleted GRN keeps its entries.
SELECT count(*) AS entries_all FROM warehouse_security.grn_replacements WHERE grn_id IN (:'grn1', :'grn2') \gset
SELECT pg_temp.sf_assert(:entries_all = 3 AND (SELECT count(*) = 1 FROM warehouse_security.grn_replacements WHERE id = :'e1' AND checked_at IS NOT NULL), 'B11b: the checked entry is still in the table');
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.delete_grn_safe(%L::uuid)', :'grn2')) AS deleted \gset
SELECT pg_temp.sf_assert(:'deleted'::jsonb->>'success' = 'true' AND (SELECT deleted_at IS NOT NULL FROM public.goodsreceived WHERE id = :'grn2'),
  'premise: the GRN is deleted: ' || :'deleted');
SELECT pg_temp.sf_assert((SELECT count(*) = 1 FROM warehouse_security.grn_replacements WHERE grn_id = :'grn2'), 'B11b: a deleted GRN keeps its entries');
SELECT pg_temp.sf_assert((SELECT count(*) FROM warehouse_security.grn_replacements WHERE grn_id IN (:'grn1', :'grn2')) = :entries_all
  AND (SELECT count(*) = 1 FROM warehouse_security.grn_replacements WHERE id = :'e1' AND checked_by = :'sf_admin_profile'::uuid), 'B11b: nothing removed after the delete, the checking intact');

\echo 'WH-303 replaced entries list and mark-checked (B11, B11b) checks passed.'
