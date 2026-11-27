-- WH-304, feed side (test-first, nothing built): the entity "held_items" in the change log and the copy, topic "sync held items"
-- (contract ~/ws/fresh/product/tech/app-offline-holding-list.md section 2.7 and 8: B-F1 to B-F5).
-- tests/migrations.sh pipes tests/fixtures/gst_details.sql and tests/sync_feed_contract.sql in front of this file, in the sync feed
-- database of its own; this file commits. Fictional data only. Backend topics by name; no migration number is used here.
--
-- AGREE WITH DEVELOPMENT (WH-304): the entity is named 'held_items'; its rows carry the keys id, kind, state, lines for a staff reader
-- of another person's item, and for a manager everything of the list row except body and accepted_body (this file looks for the keys
-- body, accepted_body, what, customer_name, recorded_by_name); the recorder's row carries body and seen_at; the payload format after the
-- topics is :held_format below (this card's own step is 5; a later step is accepted, see B-F4).
-- Every other name is in tests/sync_feed_contract.sql. The hand-over and decisions are made through hold_items and decide_held_item.
--
-- Cases: B-F1 rows by role, B-F2 hand-over, decision and seen each reach the phones, B-F3 a decided row leaves a manager's and a staff
-- phone as a delete, a seen row leaves the recorder's, B-F4 the format step, B-F5 5,000 held rows stay inside 8 s and 2,000 rows.
\set ON_ERROR_STOP on
\set held_format 5

CREATE FUNCTION pg_temp.hf_hold(claims jsonb, items jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.sf_as(claims, format('SELECT public.hold_items(%L::jsonb, NULL)', items));
  PERFORM pg_temp.sf_assert(r->>'success' = 'true', 'fixture: hold_items: ' || left(COALESCE(r::text, 'NULL'), 300));
  RETURN r;
END $$;
CREATE FUNCTION pg_temp.hf_item(key text, kind text, seq int, cust uuid, extra jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('request_key', key, 'kind', kind, 'body', jsonb_build_object('note', 'frozen ' || key), 'seq', seq,
    'recorded_at', now() - interval '2 hours', 'what', jsonb_build_object('document', kind, 'number', key), 'customer_id', cust,
    'refusal', jsonb_build_object('code', 'STOCK_SHORT')) || extra $$;
CREATE FUNCTION pg_temp.hf_id(key text) RETURNS text LANGUAGE sql AS $$ SELECT id::text FROM public.held_items WHERE request_key = key $$;
-- One step: every phone pulls and holds what a fresh load of it holds.
CREATE FUNCTION pg_temp.hf_step(step text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE p text; bad text;
BEGIN
  FOREACH p IN ARRAY ARRAY['admin', 'supervisor', 'staff', 'staff2', 'c1'] LOOP
    PERFORM pg_temp.sf_pull(p);
    bad := pg_temp.sf_diff(p);
    PERFORM pg_temp.sf_assert(bad = '', format('%s: the copy of %s differs from a fresh load: %s', step, p, bad));
  END LOOP;
END $$;
-- The keys of the row a phone holds, sorted, comma separated.
CREATE FUNCTION pg_temp.hf_keys(p text, rid text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT array_to_string(ARRAY(SELECT k FROM jsonb_object_keys(c.row) k ORDER BY k), ',') FROM pg_temp.sf_copy c WHERE c.slot = p AND c.e = 'held_items' AND c.id = rid $$;

INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888897652', 'Held Feed Staff Person', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888897653', 'Held Feed Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888897604', 'Held Feed Second Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888897661', 'Held Feed North Reader', 'customer', true, 'approved');
SELECT pg_temp.sf_login('9888897652') AS staff_claims \gset
SELECT pg_temp.sf_login('9888897653') AS supervisor_claims \gset
SELECT pg_temp.sf_login('9888897604') AS staff2_claims \gset
SELECT pg_temp.sf_login('9888897661') AS c1_claims \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, 'SELECT public.create_customer(''Held Feed North'', ''9888897621'')')->>'success' = 'true', 'customer');
SELECT id AS north FROM public.customers WHERE name = 'Held Feed North' \gset
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT to_jsonb(public.assign_customer_to_user(%L, %L::uuid, %L))', '919888897661', :'north', 'Held feed fixture'))::text = 'true',
  'customer account assigned');
SELECT pg_temp.sf_phone('admin', :'sf_admin_claims'::jsonb);
SELECT pg_temp.sf_phone('supervisor', :'supervisor_claims'::jsonb);
SELECT pg_temp.sf_phone('staff', :'staff_claims'::jsonb);
SELECT pg_temp.sf_phone('staff2', :'staff2_claims'::jsonb);
SELECT pg_temp.sf_phone('c1', :'c1_claims'::jsonb);

-- ===== B-F4. The format step: every start answers the new format and a copy key of the one before is told to reload everything =====
SELECT pg_temp.sf_first_load(p) FROM unnest(ARRAY['admin', 'supervisor', 'staff', 'staff2', 'c1']) p;
SELECT pg_temp.sf_assert((SELECT count(*) = 5 AND bool_and((answer->>pg_temp.sf('f_format'))::int >= :'held_format'::int AND split_part(answer->>pg_temp.sf('f_copy'), '.', 1) = answer->>pg_temp.sf('f_format')
      AND (answer->pg_temp.sf('f_entities') ? 'held_items') = (phone <> 'c1')) FROM pg_temp.sf_answer WHERE kind = 'start'),
  'B-F4: get_sync_start answers format 5 or later and a copy key of it to every role, and the entity held_items to admin, supervisor and staff only, never to a customer account: '
  || (SELECT string_agg(phone || ' ' || COALESCE(answer->>pg_temp.sf('f_format'), '(none)'), ', ') FROM pg_temp.sf_answer WHERE kind = 'start'));
SELECT (answer->>pg_temp.sf('f_format'))::int - 1 AS older_format FROM pg_temp.sf_answer WHERE kind = 'start' AND phone = 'admin' \gset
SELECT pg_temp.sf_changes_once('admin', NULL, regexp_replace(copy, '^[0-9]+\.', :'older_format' || '.')) AS old_copy FROM pg_temp.sf_device WHERE phone = 'admin' \gset
SELECT pg_temp.sf_assert(:'old_copy'::jsonb#>>ARRAY[pg_temp.sf('f_reload_all'), pg_temp.sf('f_reason')] = pg_temp.sf('r_format'),
  'B-F4: a copy key of the format before answers reload_all FORMAT_CHANGED: ' || left(:'old_copy', 300));
SELECT pg_temp.hf_step('empty');
SELECT pg_temp.sf_assert(cardinality(pg_temp.sf_held(p, 'held_items')) = 0, 'premise: ' || p || ' holds no held item yet') FROM unnest(ARRAY['admin', 'supervisor', 'staff', 'staff2', 'c1']) p;

-- ===== B-F1 / B-F2. Hand-over: the recorder holds the full row, managers the row without body, other staff only the lines of a dispatch =====
-- staff hands over a dispatch D1, a new GRN G1 and the photos item P1 that follows G1; the second staff person hands over a dispatch D2.
SELECT pg_temp.hf_hold(:'staff_claims'::jsonb, jsonb_build_array(
  pg_temp.hf_item('hf-d1', 'newDispatch', 1, :'north'::uuid),
  pg_temp.hf_item('hf-g1', 'newGrn', 2, :'north'::uuid),
  pg_temp.hf_item('hf-p1', 'photos', 3, :'north'::uuid, jsonb_build_object('follows_key', 'hf-g1', 'refusal', NULL)))) AS hand1 \gset
SELECT pg_temp.hf_hold(:'staff2_claims'::jsonb, jsonb_build_array(pg_temp.hf_item('hf-d2', 'newDispatch', 1, :'north'::uuid))) AS hand2 \gset
SELECT pg_temp.hf_id('hf-d1') AS d1, pg_temp.hf_id('hf-g1') AS g1, pg_temp.hf_id('hf-p1') AS p1, pg_temp.hf_id('hf-d2') AS d2 \gset
SELECT pg_temp.hf_step('hand-over');
SELECT pg_temp.sf_assert(pg_temp.sf_held('staff', 'held_items') = ARRAY(SELECT x FROM unnest(ARRAY[:'d1', :'g1', :'p1', :'d2']) x ORDER BY x),
  'B-F1: the recorder holds its three items and, of another person''s, the dispatch: ' || array_to_string(pg_temp.sf_held('staff', 'held_items'), ','));
SELECT pg_temp.sf_assert(pg_temp.sf_held('staff2', 'held_items') = ARRAY(SELECT x FROM unnest(ARRAY[:'d2', :'d1']) x ORDER BY x),
  'B-F1: the other staff person holds its own dispatch and, of another person''s, the dispatch only (no GRN, no photos): ' || array_to_string(pg_temp.sf_held('staff2', 'held_items'), ','));
SELECT pg_temp.sf_assert(pg_temp.sf_held(p, 'held_items') = ARRAY(SELECT x FROM unnest(ARRAY[:'d1', :'g1', :'p1', :'d2']) x ORDER BY x),
  'B-F1: ' || p || ' holds every held item') FROM unnest(ARRAY['admin', 'supervisor']) p;
SELECT pg_temp.sf_assert(cardinality(pg_temp.sf_held('c1', 'held_items')) = 0, 'B-F1: a customer account holds none');
-- The columns by role.
SELECT pg_temp.sf_assert(c.row ? 'body' AND c.row ? 'accepted_body' AND c.row ? 'lines' AND c.row ? 'seen_at' AND c.row ? 'what' AND c.row ? 'reason',
  'B-F1: the recorder''s row carries body, accepted_body, lines, seen_at and the list row: ' || pg_temp.hf_keys('staff', :'d1'))
  FROM pg_temp.sf_copy c WHERE c.slot = 'staff' AND c.e = 'held_items' AND c.id = :'d1';
SELECT pg_temp.sf_assert(NOT c.row ? 'body' AND NOT c.row ? 'accepted_body' AND c.row ? 'lines' AND NOT c.row ? 'what' AND NOT c.row ? 'reason' AND NOT c.row ? 'recorded_by_name' AND pg_temp.hf_keys(p, :'d1') = 'id,kind,lines,needs_decision,state',
  'B-F1: a manager''s row is exactly id, kind, lines, needs_decision and state: ' || pg_temp.hf_keys(p, :'d1'))
  FROM pg_temp.sf_copy c, unnest(ARRAY['admin', 'supervisor']) p WHERE c.slot = p AND c.e = 'held_items' AND c.id = :'d1';
SELECT pg_temp.sf_assert(pg_temp.hf_keys('staff2', :'d1') = 'id,kind,lines,state', 'B-F1: another staff person''s dispatch row is exactly id, kind, state and lines: ' || pg_temp.hf_keys('staff2', :'d1'));
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'held_items', :'d1', pg_temp.sf_last_pull(p)) = 'upsert', 'B-F2: ' || p || ' received the hand-over as an upsert')
  FROM unnest(ARRAY['admin', 'supervisor', 'staff', 'staff2']) p;

-- ===== B-F2 / B-F3. A decision: the recorder holds the decided row, managers and other staff get a delete =====
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'sf_admin_claims'::jsonb, format('SELECT public.decide_held_item(%L::uuid, %L, %L, %L)', :'d1', 'reject', 'hf-dk-1', 'Duplicate entry'))->>'success' = 'true', 'fixture: reject D1');
SELECT pg_temp.hf_step('decision');
SELECT pg_temp.sf_assert(:'d1' = ANY (pg_temp.sf_held('staff', 'held_items')) AND (SELECT c.row->>'state' = 'rejected' AND c.row->>'seen_at' IS NULL
    FROM pg_temp.sf_copy c WHERE c.slot = 'staff' AND c.e = 'held_items' AND c.id = :'d1')
  AND pg_temp.sf_ops('staff', 'held_items', :'d1', pg_temp.sf_last_pull('staff')) = 'upsert', 'B-F2: the decision reaches the recorder as an upsert with state rejected, not yet seen');
SELECT pg_temp.sf_assert(pg_temp.sf_ops(p, 'held_items', :'d1', pg_temp.sf_last_pull(p)) = 'delete' AND NOT (:'d1' = ANY (pg_temp.sf_held(p, 'held_items'))),
  'B-F3: a decided row leaves ' || p || '''s phone as a delete') FROM unnest(ARRAY['admin', 'supervisor', 'staff2']) p;
SELECT pg_temp.sf_assert(:'d2' = ANY (pg_temp.sf_held('admin', 'held_items')) AND :'g1' = ANY (pg_temp.sf_held('admin', 'held_items')), 'B-F3: the other held rows stay with the managers');

-- ===== B-F2 / B-F3. Seen: the row leaves the recorder's phone =====
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'staff_claims'::jsonb, format('SELECT public.mark_held_item_seen(%L::uuid)', :'d1'))->>'success' = 'true', 'fixture: D1 seen');
SELECT pg_temp.hf_step('seen');
SELECT pg_temp.sf_assert(pg_temp.sf_ops('staff', 'held_items', :'d1', pg_temp.sf_last_pull('staff')) = 'delete' AND NOT (:'d1' = ANY (pg_temp.sf_held('staff', 'held_items'))),
  'B-F3: a seen row leaves the recorder''s phone as a delete');
-- A second decision, accept-free: a reject of D2 by a supervisor reaches the recorder of D2 (the other staff person) and the first staff person loses the dispatch row.
SELECT pg_temp.sf_assert(pg_temp.sf_as(:'supervisor_claims'::jsonb, format('SELECT public.decide_held_item(%L::uuid, %L, %L, %L)', :'d2', 'reject', 'hf-dk-2', 'Wrong customer'))->>'success' = 'true', 'fixture: reject D2');
SELECT pg_temp.hf_step('second decision');
SELECT pg_temp.sf_assert(pg_temp.sf_ops('staff', 'held_items', :'d2', pg_temp.sf_last_pull('staff')) = 'delete' AND NOT (:'d2' = ANY (pg_temp.sf_held('staff', 'held_items')))
  AND (SELECT c.row->>'state' = 'rejected' FROM pg_temp.sf_copy c WHERE c.slot = 'staff2' AND c.e = 'held_items' AND c.id = :'d2'),
  'B-F2: the decision of another person''s dispatch is a delete for the other staff phone and an upsert (rejected) for its recorder');

-- ===== B-F5. 5,000 held rows: every answer stays inside 2,000 rows and 8 seconds =====
SELECT pg_temp.sf_phone('admin_old', :'sf_admin_claims'::jsonb);
SELECT pg_temp.sf_first_load('admin_old');
SELECT set_config('hf.staff_claims', :'staff_claims', false);
DO $$
DECLARE n int; claims jsonb := current_setting('hf.staff_claims')::jsonb;
BEGIN
  FOR n IN 0..99 LOOP
    PERFORM pg_temp.hf_hold(claims, (SELECT jsonb_agg(pg_temp.hf_item('hf-bulk-' || (n * 50 + g), 'newDispatch', 1000 + n * 50 + g, (SELECT id FROM public.customers WHERE name = 'Held Feed North')))
      FROM generate_series(1, 50) g));
  END LOOP;
END $$;
SELECT pg_temp.sf_assert((SELECT count(*) FROM public.held_items WHERE state = 'held') >= 5000, 'premise: 5,000 or more held rows');
SELECT clock_timestamp() AS t0 \gset
SELECT pg_temp.sf_as(:'sf_admin_claims'::jsonb, format(pg_temp.sf('call_page'), 'held_items', NULL, pg_temp.sf('page_limit'))) AS big_page \gset
SELECT clock_timestamp() AS t1 \gset
SELECT pg_temp.sf_assert(:'big_page'::jsonb->>pg_temp.sf('f_success') = 'true' AND jsonb_array_length(:'big_page'::jsonb->pg_temp.sf('f_rows')) = pg_temp.sf('page_limit')::int
  AND :'big_page'::jsonb->>pg_temp.sf('f_more') = 'true' AND (:'t1'::timestamptz - :'t0'::timestamptz) < interval '8 seconds',
  'B-F5: one page of held_items is the page limit with more to come and takes under 8 seconds: ' || (:'t1'::timestamptz - :'t0'::timestamptz));
SELECT pg_temp.sf_changes_once('admin_old') AS big_changes \gset
SELECT pg_temp.sf_assert(:'big_changes'::jsonb->>pg_temp.sf('f_success') = 'true' AND jsonb_array_length(COALESCE(:'big_changes'::jsonb->pg_temp.sf('f_changes'), '[]'::jsonb)) <= pg_temp.sf('page_limit')::int,
  'B-F5: a changes answer after 5,000 new held rows holds at most the page limit: ' || left(:'big_changes', 200));
SELECT pg_temp.sf_pull('admin_old');
SELECT pg_temp.sf_assert(cardinality(pg_temp.sf_held('admin_old', 'held_items')) = (SELECT count(*) FROM public.held_items WHERE state = 'held'),
  'B-F5: pulling to the end gives the phone every held row');
\echo 'WH-304 sync feed held items (B-F1 to B-F5) checks passed.'
