-- Migration 131, rack presets (the Floor and Chamber buttons of the GRN item form):
--   1. the lists start as the buttons the app had built in, version 1, and every staff role reads them; a customer does not;
--   2. administrators and supervisors replace both lists in one call (order kept, spaces cut, the version goes up); staff and
--      customers are refused by the guard and nothing changes;
--   3. a save from an older version is refused with PRESETS_CHANGED and the current lists; the same lists again change nothing;
--   4. every label rule has its own reason and a refused save changes nothing: empty, over 12 characters, "/" or a control
--      character, a duplicate (also across the lists and in another case), more than 20, a missing list or version;
--   5. the tables are not readable or writable by an app role.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.rp_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'rack presets 131: %', label; END IF; END $$;
-- The jsonb answer of a call, or what it raised.
CREATE FUNCTION pg_temp.rp_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.rp_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.rp_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- set_rack_presets with array literals; NULL for a list is written NULL.
CREATE FUNCTION pg_temp.rp_set(p_floor text, p_chamber text, p_version integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.rp_call(format('SELECT public.set_rack_presets(p_floor=>%L::text[], p_chamber=>%L::text[], p_version=>%L::integer)',
    p_floor, p_chamber, p_version)) $$;
-- "BASE,F1|C4" for an answer or a get_rack_presets answer; the version after a "#".
CREATE FUNCTION pg_temp.rp_shape(a jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT (SELECT string_agg(x, ',' ORDER BY n) FROM jsonb_array_elements_text(a->'floor') WITH ORDINALITY t(x, n)) || '|' ||
         (SELECT string_agg(x, ',' ORDER BY n) FROM jsonb_array_elements_text(a->'chamber') WITH ORDINALITY t(x, n)) || '#' || (a->>'version') $$;
-- The stored lists, read as the owner.
CREATE FUNCTION pg_temp.rp_stored() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT pg_temp.rp_shape(warehouse_security.rack_presets_json()) $$;

INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888641', 'Rack Presets Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888888642', 'Rack Presets Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888888643', 'Rack Presets Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888888644', 'Rack Presets Customer', 'customer', true, 'approved');
SELECT pg_temp.rp_login('9888888641') AS admin_claims \gset
SELECT pg_temp.rp_login('9888888642') AS supervisor_claims \gset
SELECT pg_temp.rp_login('9888888643') AS staff_claims \gset
SELECT pg_temp.rp_login('9888888644') AS customer_claims \gset

-- The starting lists are the buttons that were built into the app.
SELECT pg_temp.rp_assert(pg_temp.rp_stored() = 'BASE,F1,F2,F3,F4|C4,C7,C2,Anti-Ch#1', 'the starting lists: ' || pg_temp.rp_stored());

-- 1. Staff read them; a customer does not.
SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rp_assert(warehouse_security.active_role() = 'staff', 'actual staff role');
SELECT pg_temp.rp_assert(r->>'success' = 'true' AND pg_temp.rp_shape(r) = 'BASE,F1,F2,F3,F4|C4,C7,C2,Anti-Ch#1'
  AND (r->>'max_label_length')::int = 12 AND (r->>'max_per_list')::int = 20 AND r->>'updated_at' IS NOT NULL,
  'staff read the starting lists and the limits: ' || r::text)
FROM (SELECT pg_temp.rp_call('SELECT public.get_rack_presets()') AS r) a;
-- 2. Staff are refused a save; nothing changes.
SELECT pg_temp.rp_assert(r->>'state' = '42501' AND r->>'raised' ~ '(Staff access required|Administrator required)',
  'staff are refused set_rack_presets: ' || r::text)
FROM (SELECT pg_temp.rp_set('{X1}', '{Y1}', 1) AS r) a;
RESET ROLE;
SELECT pg_temp.rp_assert(pg_temp.rp_stored() = 'BASE,F1,F2,F3,F4|C4,C7,C2,Anti-Ch#1', 'the refused staff save changed nothing');

SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rp_assert(warehouse_security.active_role() = 'customer', 'actual customer role');
SELECT pg_temp.rp_assert(r->>'state' = '42501', 'a customer is refused get_rack_presets: ' || r::text)
FROM (SELECT pg_temp.rp_call('SELECT public.get_rack_presets()') AS r) a;
SELECT pg_temp.rp_assert(r->>'state' = '42501', 'a customer is refused set_rack_presets: ' || r::text)
FROM (SELECT pg_temp.rp_set('{X1}', '{Y1}', 1) AS r) a;
-- 5. The tables are not reachable by an app role.
SELECT pg_temp.rp_assert(pg_temp.rp_call('SELECT count(*) FROM warehouse_security.rack_presets')->>'state' = '42501', 'no direct read of the presets');
SELECT pg_temp.rp_assert(pg_temp.rp_call('DELETE FROM warehouse_security.rack_presets')->>'state' = '42501', 'no direct delete of the presets');
SELECT pg_temp.rp_assert(pg_temp.rp_call('SELECT count(*) FROM warehouse_security.rack_preset_state')->>'state' = '42501', 'no direct read of the version');
RESET ROLE;
SELECT pg_temp.rp_assert(pg_temp.rp_stored() = 'BASE,F1,F2,F3,F4|C4,C7,C2,Anti-Ch#1', 'nothing changed so far');

-- 2. A supervisor replaces both lists: order kept, spaces cut, version 2. A 12-character label is allowed.
SELECT set_config('request.jwt.claims', :'supervisor_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rp_assert(warehouse_security.active_role() = 'supervisor', 'actual supervisor role');
SELECT pg_temp.rp_assert(r->>'success' = 'true' AND (r->>'changed')::boolean AND pg_temp.rp_shape(r) = 'GROUND,F2,F1|C4,Chamber-Nine#2',
  'a supervisor saves both lists: ' || r::text)
FROM (SELECT pg_temp.rp_set('{"  GROUND ",F2,F1}', '{C4,Chamber-Nine}', 1) AS r) a;
RESET ROLE;
SELECT pg_temp.rp_assert(pg_temp.rp_stored() = 'GROUND,F2,F1|C4,Chamber-Nine#2', 'stored after the supervisor save: ' || pg_temp.rp_stored());
SELECT pg_temp.rp_assert((SELECT updated_by IS NOT NULL FROM warehouse_security.rack_preset_state), 'the save records who made it');

-- Staff now read the new lists.
SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rp_assert(pg_temp.rp_shape(pg_temp.rp_call('SELECT public.get_rack_presets()')) = 'GROUND,F2,F1|C4,Chamber-Nine#2', 'staff read the new lists');
RESET ROLE;

-- 3. An administrator with the old version (1) is refused with the current lists; nothing changes.
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rp_assert(r->>'success' = 'false' AND r->>'reason' = 'PRESETS_CHANGED' AND r->>'error_code' = 'WH409'
  AND r->>'message' = 'Someone else changed the rack presets. Reload to see their changes.'
  AND pg_temp.rp_shape(r) = 'GROUND,F2,F1|C4,Chamber-Nine#2', 'a stale save is refused with the current lists: ' || r::text)
FROM (SELECT pg_temp.rp_set('{BASE}', '{C1}', 1) AS r) a;
RESET ROLE;
SELECT pg_temp.rp_assert(pg_temp.rp_stored() = 'GROUND,F2,F1|C4,Chamber-Nine#2', 'the stale save changed nothing');
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
-- The same lists again with the old version: success, nothing written, the version stays.
SELECT pg_temp.rp_assert(r->>'success' = 'true' AND NOT (r->>'changed')::boolean AND pg_temp.rp_shape(r) = 'GROUND,F2,F1|C4,Chamber-Nine#2',
  'a resend of the saved lists changes nothing: ' || r::text)
FROM (SELECT pg_temp.rp_set('{GROUND,F2,F1}', '{C4,Chamber-Nine}', 1) AS r) a;
-- With the current version the administrator saves; a group may be emptied, and a case change is a change.
SELECT pg_temp.rp_assert(r->>'success' = 'true' AND (r->>'changed')::boolean AND r->>'version' = '3' AND r->'floor' = '["ground","F2","F1"]'::jsonb
  AND r->'chamber' = '[]'::jsonb, 'an administrator saves with the current version and may empty a list: ' || r::text)
FROM (SELECT pg_temp.rp_set('{ground,F2,F1}', '{}', 2) AS r) a;
RESET ROLE;
SELECT pg_temp.rp_assert((SELECT version FROM warehouse_security.rack_preset_state) = 3
  AND (SELECT count(*) FROM warehouse_security.rack_presets WHERE kind = 'chamber') = 0
  AND (SELECT string_agg(label, ',' ORDER BY "position") FROM warehouse_security.rack_presets WHERE kind = 'floor') = 'ground,F2,F1',
  'stored after the administrator save');

-- 4. Every rule has its reason; a refused save changes nothing (version 3 stays).
CREATE TEMP TABLE rp_cases(label text, floor text, chamber text, version integer, reason text, list text, idx text);
GRANT ALL ON rp_cases TO authenticated;
SELECT set_config('request.jwt.claims', :'admin_claims', true);
INSERT INTO rp_cases VALUES
  ('empty text',          '{A,""}',                     '{}',        3, 'LABEL_EMPTY',     'floor',   '2'),
  ('only spaces',         '{"   "}',                    '{}',        3, 'LABEL_EMPTY',     'floor',   '1'),
  ('NULL element',        '{A}',                        '{A2,NULL}', 3, 'LABEL_EMPTY',     'chamber', '2'),
  ('13 characters',       '{A}',                        '{ABCDEFGHIJKLM}', 3, 'LABEL_TOO_LONG', 'chamber', '1'),
  ('slash',               '{A,"B/C"}',                  '{}',        3, 'LABEL_CHARACTER', 'floor',   '2'),
  ('tab',                 E'{A,"B\tC"}',               '{}',        3, 'LABEL_CHARACTER', 'floor',   '2'),
  ('duplicate in a list', '{A,B,A}',                    '{}',        3, 'LABEL_DUPLICATE', 'floor',   '3'),
  ('duplicate across',    '{A,B}',                      '{C,B}',     3, 'LABEL_DUPLICATE', 'chamber', '2'),
  ('duplicate in case',   '{Base}',                     '{bASE}',    3, 'LABEL_DUPLICATE', 'chamber', '1'),
  ('21 labels',           '{' || (SELECT string_agg('L' || g, ',') FROM generate_series(1, 21) g) || '}', '{}', 3, 'TOO_MANY', 'floor', NULL),
  ('missing floor',       NULL,                         '{A}',       3, 'LIST_REQUIRED',   NULL,      NULL),
  ('missing chamber',     '{A}',                        NULL,        3, 'LIST_REQUIRED',   NULL,      NULL),
  ('missing version',     '{A}',                        '{B}',       NULL, 'VERSION_REQUIRED', NULL,  NULL);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rp_assert(r->>'success' = 'false' AND r->>'error_code' = 'WH409' AND r->>'reason' = c.reason
    AND (c.list IS NULL OR r->>'list' = c.list) AND (c.idx IS NULL OR r->>'index' = c.idx) AND r->>'message' IS NOT NULL,
  'refused (' || c.label || '): ' || r::text)
FROM rp_cases c, LATERAL (SELECT pg_temp.rp_set(c.floor, c.chamber, c.version) AS r) a;
-- 20 labels are allowed (the limit is inclusive); 12 characters of Gujarati count as 12.
SELECT pg_temp.rp_assert(r->>'success' = 'true' AND jsonb_array_length(r->'floor') = 20 AND r->>'version' = '4', 'twenty labels are allowed: ' || r::text)
FROM (SELECT pg_temp.rp_set('{' || (SELECT string_agg('L' || g, ',') FROM generate_series(1, 20) g) || '}', '{"ભોંયતળિયું"}', 3) AS r) a;
RESET ROLE;
SELECT pg_temp.rp_assert((SELECT version FROM warehouse_security.rack_preset_state) = 4
  AND (SELECT count(*) FROM warehouse_security.rack_presets) = 21, 'only the accepted saves changed anything');
-- The table itself enforces the label rule too (a direct write by the owner).
SELECT pg_temp.rp_assert(pg_temp.rp_call($q$INSERT INTO warehouse_security.rack_presets VALUES ('floor', 'A/B', 99)$q$)->>'state' = '23514', 'the table refuses a slash');
SELECT pg_temp.rp_assert(pg_temp.rp_call($q$INSERT INTO warehouse_security.rack_presets VALUES ('floor', 'l1', 98)$q$)->>'state' = '23505', 'the table refuses a duplicate in another case');
SELECT pg_temp.rp_assert(pg_temp.rp_call($q$INSERT INTO warehouse_security.rack_preset_state VALUES (false, 1)$q$)->>'state' IN ('23514', '23505'), 'the version row is single');
ROLLBACK;
SELECT 'rack presets 131: lists, roles, version check and label rules hold' AS result;
