-- Migration 140: signed-in devices. A session records where it was made (source address, user agent) and when it was last refreshed;
-- a person keeps at most the newest 10 sessions; list_user_sessions shows a person's sessions (masked address, current one marked) and
-- revoke_session signs one device out. Covered: the cap (12 sign-ins leave the newest 10, another person's sessions stay, an evicted
-- session's tokens cannot be replayed), the fields written at sign-in and by the sign-in RPCs (new signatures and the old ones as wrappers),
-- last_refreshed_at moving on a refresh while created_at, the address and the user agent stay, who may list and who may revoke, that a
-- revoked session fails check_session, that exactly one session is marked current, the address masking, and the grants.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; every fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.sd_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'session devices: %',label; END IF; END $$;
-- Calls a statement as the signed-in account with these claims; the answer, or {"raised": message, "state": sqlstate}.
CREATE FUNCTION pg_temp.sd_as(claims text, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', claims, true);
  SET LOCAL ROLE authenticated;
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RESET ROLE; RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RESET ROLE;
  RETURN answer;
END $$;
-- Signs the account in (issue_session) and returns its refresh token; the session's age is set so that the order is plain:
-- all sessions of one transaction share now(), so each new one is made `age` minutes old after it is created.
CREATE FUNCTION pg_temp.sd_in(p_user uuid, age_minutes integer DEFAULT 0, p_ip inet DEFAULT NULL, p_ua text DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $$
DECLARE refresh text := warehouse_security.issue_session(p_user, NULL, p_ip, p_ua)->>'refresh_token';
BEGIN
  UPDATE warehouse_security.refresh_sessions SET created_at = now() - make_interval(mins => age_minutes)
    WHERE token_hash = encode(extensions.digest(refresh,'sha256'),'hex');
  RETURN refresh;
END $$;
CREATE FUNCTION pg_temp.sd_row(p_refresh text) RETURNS warehouse_security.refresh_sessions LANGUAGE sql AS $$
  SELECT s FROM warehouse_security.refresh_sessions s WHERE s.token_hash = encode(extensions.digest(p_refresh,'sha256'),'hex') $$;
CREATE FUNCTION pg_temp.sd_has(p_refresh text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM warehouse_security.refresh_sessions s WHERE s.token_hash = encode(extensions.digest(p_refresh,'sha256'),'hex')) $$;
CREATE FUNCTION pg_temp.sd_claims(p_refresh text) RETURNS text LANGUAGE sql AS $$
  SELECT jsonb_build_object('role','authenticated','sub',user_id,'session_id',id)::text FROM warehouse_security.refresh_sessions
  WHERE token_hash = encode(extensions.digest(p_refresh,'sha256'),'hex') $$;
CREATE FUNCTION pg_temp.sd_count(p_user uuid) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM warehouse_security.refresh_sessions WHERE user_id = p_user $$;
CREATE FUNCTION pg_temp.sd_rotates(p_refresh text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN RETURN public.refresh_jwt_token(p_refresh)->>'success' = 'true'; EXCEPTION WHEN OTHERS THEN RETURN false; END $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false'),('refresh_grace_seconds','60'),('central_issuer','https://login.association.example.test')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='SDTEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888961','Devices Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888962','Devices Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888963','Devices Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888964','Devices Other Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888965','Devices Customer','customer',true,'approved');
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id = :'admin_user' \gset
SELECT auth_user_id AS sup_user, id AS sup_profile FROM public.user_profiles WHERE mobile='919888888962' \gset
SELECT auth_user_id AS staff_user, id AS staff_profile FROM public.user_profiles WHERE mobile='919888888963' \gset
SELECT auth_user_id AS other_user, id AS other_profile FROM public.user_profiles WHERE mobile='919888888964' \gset
SELECT auth_user_id AS cust_user, id AS cust_profile FROM public.user_profiles WHERE mobile='919888888965' \gset
DELETE FROM warehouse_security.refresh_sessions;

-- ---------------------------------------------------------------------------
-- 1. The cap: 12 sign-ins leave the newest 10; another person's sessions stay
-- ---------------------------------------------------------------------------
SELECT pg_temp.sd_in(:'other_user'::uuid, 5) AS other1 \gset
SELECT pg_temp.sd_in(:'other_user'::uuid, 4) AS other2 \gset
SELECT pg_temp.sd_in(:'staff_user'::uuid, 12) AS s1 \gset
-- The first token is rotated once, so the session has a recorded (consumed) token.
SELECT public.refresh_jwt_token(:'s1')->>'refresh_token' AS s1b \gset
SELECT pg_temp.sd_in(:'staff_user'::uuid, 11) AS s2 \gset
SELECT pg_temp.sd_in(:'staff_user'::uuid, 10) AS s3 \gset
SELECT pg_temp.sd_in(:'staff_user'::uuid, 9) AS s4 \gset
SELECT pg_temp.sd_in(:'staff_user'::uuid, 8) AS s5 \gset
SELECT pg_temp.sd_in(:'staff_user'::uuid, 7) AS s6 \gset
SELECT pg_temp.sd_in(:'staff_user'::uuid, 6) AS s7 \gset
SELECT pg_temp.sd_in(:'staff_user'::uuid, 5) AS s8 \gset
SELECT pg_temp.sd_in(:'staff_user'::uuid, 4) AS s9 \gset
SELECT pg_temp.sd_in(:'staff_user'::uuid, 3) AS s10 \gset
SELECT pg_temp.sd_in(:'staff_user'::uuid, 2) AS s11 \gset
SELECT pg_temp.sd_in(:'staff_user'::uuid, 1) AS s12 \gset
SELECT pg_temp.sd_assert(pg_temp.sd_count(:'staff_user')=10, 'twelve sign-ins leave ten sessions');
SELECT pg_temp.sd_assert(NOT pg_temp.sd_has(:'s1b') AND NOT pg_temp.sd_has(:'s2'),
 'the two oldest sessions are the ones that went');
SELECT pg_temp.sd_assert(pg_temp.sd_has(:'s3') AND pg_temp.sd_has(:'s4') AND pg_temp.sd_has(:'s5')
  AND pg_temp.sd_has(:'s6') AND pg_temp.sd_has(:'s7') AND pg_temp.sd_has(:'s8')
  AND pg_temp.sd_has(:'s9') AND pg_temp.sd_has(:'s10') AND pg_temp.sd_has(:'s11')
  AND pg_temp.sd_has(:'s12'), 'the newest ten stay, the newest of all included');
SELECT pg_temp.sd_assert(pg_temp.sd_count(:'other_user')=2 AND pg_temp.sd_has(:'other1') AND pg_temp.sd_has(:'other2'),
 'another person''s sessions are untouched');
SELECT pg_temp.sd_assert(NOT EXISTS (SELECT 1 FROM warehouse_security.consumed_refresh_tokens c
  WHERE c.token_hash = encode(extensions.digest(:'s1','sha256'),'hex')), 'the recorded token of an evicted session went with it');
SELECT pg_temp.sd_assert(NOT pg_temp.sd_rotates(:'s1') AND NOT pg_temp.sd_rotates(:'s1b') AND NOT pg_temp.sd_rotates(:'s2'),
 'neither the replaced nor the current token of an evicted session can be used again');
SELECT pg_temp.sd_assert(pg_temp.sd_rotates(:'s9') AND pg_temp.sd_rotates(:'other2'), 'a kept session still refreshes');

-- ---------------------------------------------------------------------------
-- 2. What a sign-in writes, and what a refresh changes
-- ---------------------------------------------------------------------------
SELECT pg_temp.sd_in(:'cust_user'::uuid, 120, '203.0.113.77', repeat('x', 400)) AS c1 \gset
SELECT pg_temp.sd_assert((pg_temp.sd_row(:'c1')).created_ip = '203.0.113.77'::inet
  AND char_length((pg_temp.sd_row(:'c1')).user_agent) = 300 AND (pg_temp.sd_row(:'c1')).label IS NULL
  AND (pg_temp.sd_row(:'c1')).last_refreshed_at = now(), 'a sign-in records the address, the user agent cut to 300 characters and the time');
SELECT pg_temp.sd_assert((SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='refresh_sessions_user_agent_len') LIKE '%300%'
  AND (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='refresh_sessions_label_len') LIKE '%60%', 'the length limits are checked by the table');
UPDATE warehouse_security.refresh_sessions SET last_refreshed_at = now() - interval '1 hour' WHERE token_hash = encode(extensions.digest(:'c1','sha256'),'hex');
SELECT public.refresh_jwt_token(:'c1')->>'refresh_token' AS c1b \gset
SELECT pg_temp.sd_assert((pg_temp.sd_row(:'c1b')).last_refreshed_at = now(), 'a refresh moves last_refreshed_at');
SELECT pg_temp.sd_assert((pg_temp.sd_row(:'c1b')).created_at = now() - interval '120 minutes'
  AND (pg_temp.sd_row(:'c1b')).created_ip = '203.0.113.77'::inet AND char_length((pg_temp.sd_row(:'c1b')).user_agent) = 300,
 'a refresh leaves created_at, the address and the user agent as they were');

-- ---------------------------------------------------------------------------
-- 3. The sign-in RPCs: the new signatures record both, the old ones still work
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.sd_code(phone text, source inet DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $$
DECLARE challenge jsonb;
BEGIN
  UPDATE public.otp_verifications SET created_at = created_at - interval '61 seconds' WHERE phone_number = phone;
  challenge := public.operator_prepare_otp(phone, source);
  PERFORM pg_temp.sd_assert(challenge->>'success'='true', 'a code is prepared: '||challenge::text);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  RETURN challenge#>>'{data,otp_code}';
END $$;
CREATE FUNCTION pg_temp.sd_newest(p_user uuid) RETURNS warehouse_security.refresh_sessions LANGUAGE sql AS $$
  SELECT s FROM warehouse_security.refresh_sessions s WHERE s.user_id = p_user ORDER BY s.created_at DESC, s.id LIMIT 1 $$;
-- Sessions made in one transaction share now(): before each sign-in the person's earlier sessions are made a minute older, so the newest is plain.
CREATE FUNCTION pg_temp.sd_age(p_user uuid) RETURNS void LANGUAGE sql AS $$
  UPDATE warehouse_security.refresh_sessions SET created_at = created_at - interval '1 minute' WHERE user_id = p_user $$;
-- SMS code, six arguments.
SELECT pg_temp.sd_code('919888888965', '203.0.113.20') AS code1 \gset
SELECT pg_temp.sd_age(:'cust_user'::uuid) AS _a \gset
SELECT public.operator_verify_otp('919888888965', :'code1', NULL, NULL, '203.0.113.20', 'WarehouseApp/1 (test)') AS v1 \gset
SELECT pg_temp.sd_assert(:'v1'::jsonb #>> '{data,action}' = 'login', 'the six-argument code sign-in signs in: '||:'v1');
SELECT pg_temp.sd_assert((pg_temp.sd_newest(:'cust_user')).created_ip = '203.0.113.20'::inet
  AND (pg_temp.sd_newest(:'cust_user')).user_agent = 'WarehouseApp/1 (test)', 'the code sign-in records the address and the user agent');
-- SMS code, the old five-argument form.
SELECT pg_temp.sd_code('919888888965', '203.0.113.21') AS code2 \gset
SELECT pg_temp.sd_age(:'cust_user'::uuid) AS _a \gset
SELECT public.operator_verify_otp('919888888965', :'code2', NULL, NULL, '203.0.113.21') AS v2 \gset
SELECT pg_temp.sd_assert(:'v2'::jsonb #>> '{data,action}' = 'login', 'the five-argument code sign-in still signs in');
SELECT pg_temp.sd_assert((pg_temp.sd_newest(:'cust_user')).created_ip = '203.0.113.21'::inet AND (pg_temp.sd_newest(:'cust_user')).user_agent IS NULL,
 'the old form records the address and no user agent');
-- The shortest old form (two arguments) binds to the wrapper too.
SELECT pg_temp.sd_code('919888888965') AS code3 \gset
SELECT pg_temp.sd_assert(public.operator_verify_otp('919888888965', :'code3') #>> '{data,action}' = 'login', 'the two-argument call still signs in');
-- Central exchange: ten arguments, then the old nine.
SELECT pg_temp.sd_age(:'cust_user'::uuid) AS _a \gset
SELECT public.operator_central_exchange('https://login.association.example.test', 'central-user-0140a', '919888888965', 'token-id-0000000000140001',
  now() + interval '5 minutes', NULL, NULL, '203.0.113.30', NULL, 'WarehouseApp/2 (central)') AS e1 \gset
SELECT pg_temp.sd_assert(:'e1'::jsonb #>> '{data,action}' = 'login', 'the ten-argument exchange signs in: '||:'e1');
SELECT pg_temp.sd_assert((pg_temp.sd_newest(:'cust_user')).created_ip = '203.0.113.30'::inet
  AND (pg_temp.sd_newest(:'cust_user')).user_agent = 'WarehouseApp/2 (central)', 'the exchange records the address and the user agent');
SELECT pg_temp.sd_age(:'cust_user'::uuid) AS _a \gset
SELECT public.operator_central_exchange('https://login.association.example.test', 'central-user-0140a', '919888888965', 'token-id-0000000000140002',
  now() + interval '5 minutes', NULL, NULL, '203.0.113.31', NULL) AS e2 \gset
SELECT pg_temp.sd_assert(:'e2'::jsonb #>> '{data,action}' = 'login', 'the nine-argument exchange still signs in: '||:'e2');
SELECT pg_temp.sd_assert((pg_temp.sd_newest(:'cust_user')).created_ip = '203.0.113.31'::inet AND (pg_temp.sd_newest(:'cust_user')).user_agent IS NULL,
 'the old exchange form records the address and no user agent');
-- Break-glass: four arguments, then the old three.
SELECT (warehouse_security.break_glass_code('9888888962'))->>'code' AS bg1 \gset
SELECT pg_temp.sd_age(:'sup_user'::uuid) AS _a \gset
SELECT public.operator_break_glass_sign_in('9888888962', :'bg1', '203.0.113.40', 'WarehouseApp/3 (glass)') AS g1 \gset
SELECT pg_temp.sd_assert(:'g1'::jsonb #>> '{data,action}' = 'login', 'the four-argument break-glass sign-in signs in: '||:'g1');
SELECT pg_temp.sd_assert((pg_temp.sd_newest(:'sup_user')).created_ip = '203.0.113.40'::inet
  AND (pg_temp.sd_newest(:'sup_user')).user_agent = 'WarehouseApp/3 (glass)' AND (pg_temp.sd_newest(:'sup_user')).hard_expires_at IS NOT NULL,
 'the break-glass sign-in records the address and the user agent and keeps its 24 hour end');
SELECT (warehouse_security.break_glass_code('9888888962'))->>'code' AS bg2 \gset
SELECT pg_temp.sd_age(:'sup_user'::uuid) AS _a \gset
SELECT public.operator_break_glass_sign_in('9888888962', :'bg2', '203.0.113.41') AS g2 \gset
SELECT pg_temp.sd_assert(:'g2'::jsonb #>> '{data,action}' = 'login', 'the three-argument break-glass sign-in still signs in');
SELECT pg_temp.sd_assert((pg_temp.sd_newest(:'sup_user')).created_ip = '203.0.113.41'::inet AND (pg_temp.sd_newest(:'sup_user')).user_agent IS NULL,
 'the old break-glass form records the address and no user agent');
-- The sign-ins kept the cap.
SELECT pg_temp.sd_assert(pg_temp.sd_count(:'cust_user') <= 10, 'sign-in RPCs keep at most ten sessions');

-- ---------------------------------------------------------------------------
-- 4. Listing: who may, the shape, the masking, the current mark
-- ---------------------------------------------------------------------------
SELECT pg_temp.sd_in(:'admin_user'::uuid, 30, '2001:db8:abcd:12::1', 'AdminPhone') AS a1 \gset
SELECT pg_temp.sd_claims(:'a1') AS admin_claims \gset
SELECT pg_temp.sd_claims(:'s12') AS staff_claims \gset
SELECT pg_temp.sd_claims(:'s11') AS staff_claims_other_device \gset
SELECT pg_temp.sd_in(:'sup_user'::uuid, 0, '198.51.100.99', 'SupPhone') AS sp1 \gset
SELECT pg_temp.sd_claims(:'sp1') AS sup_claims \gset
SELECT pg_temp.sd_in(:'cust_user'::uuid, 0) AS cu1 \gset
SELECT pg_temp.sd_claims(:'cu1') AS cust_claims \gset
UPDATE warehouse_security.refresh_sessions SET created_ip = '203.0.113.77', user_agent = 'StaffPhone/1' WHERE token_hash = encode(extensions.digest(:'s12','sha256'),'hex');
UPDATE warehouse_security.refresh_sessions SET created_ip = '2001:db8:abcd:1234::9' WHERE token_hash = encode(extensions.digest(:'s11','sha256'),'hex');

SELECT pg_temp.sd_as(:'admin_claims', format('SELECT public.list_user_sessions(%L)', :'staff_profile')) AS listed \gset
SELECT pg_temp.sd_assert(:'listed'::jsonb->>'success' = 'true' AND jsonb_array_length(:'listed'::jsonb #> '{data,sessions}') = 10,
 'an administrator lists the ten sessions of a staff member: '||:'listed');
SELECT pg_temp.sd_assert((SELECT bool_and(s ?& ARRAY['id','label','user_agent','created_ip','created_at','last_refreshed_at','expires_at','is_current'])
  FROM jsonb_array_elements(:'listed'::jsonb #> '{data,sessions}') s), 'every session carries the agreed fields');
SELECT pg_temp.sd_assert((SELECT bool_and((a->>'created_at')::timestamptz >= (b->>'created_at')::timestamptz) FROM
  (SELECT s AS a, lead(s) OVER (ORDER BY ord) AS b FROM jsonb_array_elements(:'listed'::jsonb #> '{data,sessions}') WITH ORDINALITY t(s,ord)) q WHERE b IS NOT NULL),
 'newest first');
SELECT pg_temp.sd_assert((SELECT count(*) FROM jsonb_array_elements(:'listed'::jsonb #> '{data,sessions}') s WHERE s->>'is_current' = 'true') = 0,
 'an administrator looking at another person has no current session in the list');
SELECT pg_temp.sd_assert(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(:'listed'::jsonb #> '{data,sessions}') s WHERE (s->>'id')::uuid IN
  (SELECT id FROM warehouse_security.refresh_sessions WHERE user_id <> :'staff_user')), 'only that person''s sessions are listed');
SELECT pg_temp.sd_assert(EXISTS (SELECT 1 FROM jsonb_array_elements(:'listed'::jsonb #> '{data,sessions}') s WHERE s->>'created_ip' = '203.0.113.0/24' AND s->>'user_agent' = 'StaffPhone/1')
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(:'listed'::jsonb #> '{data,sessions}') s WHERE s->>'created_ip' = '2001:db8:abcd::/48')
  AND NOT :'listed'::jsonb::text LIKE '%203.0.113.77%' AND NOT :'listed'::jsonb::text LIKE '%1234::9%',
 'an IPv4 address is masked to its /24 and an IPv6 address to its /48; the full address is not in the answer');
SELECT pg_temp.sd_as(:'staff_claims', format('SELECT public.list_user_sessions(%L)', :'staff_profile')) AS own_listed \gset
SELECT pg_temp.sd_assert(:'own_listed'::jsonb->>'raised' IS NOT NULL AND :'own_listed'::jsonb->>'state' = '42501',
 'staff are refused the list, also their own: '||:'own_listed');
SELECT pg_temp.sd_as(:'cust_claims', format('SELECT public.list_user_sessions(%L)', :'staff_profile')) AS cust_listed \gset
SELECT pg_temp.sd_assert(:'cust_listed'::jsonb->>'state' = '42501', 'a customer is refused the list');
SELECT pg_temp.sd_as(:'sup_claims', format('SELECT public.list_user_sessions(%L)', :'staff_profile')) AS sup_listed \gset
SELECT pg_temp.sd_assert(:'sup_listed'::jsonb->>'success' = 'true' AND jsonb_array_length(:'sup_listed'::jsonb #> '{data,sessions}') = 10,
 'a supervisor lists a staff member''s sessions');
SELECT pg_temp.sd_as(:'sup_claims', format('SELECT public.list_user_sessions(%L)', :'admin_profile')) AS sup_admin \gset
SELECT pg_temp.sd_assert(:'sup_admin'::jsonb->>'success' = 'false' AND :'sup_admin'::jsonb->>'error' = 'PERMISSION_DENIED' AND NOT :'sup_admin'::jsonb::text LIKE '%AdminPhone%',
 'a supervisor is refused an administrator''s sessions: '||:'sup_admin');
SELECT pg_temp.sd_as(:'admin_claims', format('SELECT public.list_user_sessions(%L)', :'admin_profile')) AS admin_own \gset
SELECT pg_temp.sd_assert(jsonb_array_length(:'admin_own'::jsonb #> '{data,sessions}') = 1
  AND (:'admin_own'::jsonb #> '{data,sessions,0,is_current}') = 'true'::jsonb AND :'admin_own'::jsonb #>> '{data,sessions,0,created_ip}' = '2001:db8:abcd::/48',
 'an administrator''s own list marks the session in use as current: '||:'admin_own');
SELECT pg_temp.sd_as(:'admin_claims', format('SELECT public.list_user_sessions(%L)', :'cust_profile')) AS cust_all \gset
SELECT pg_temp.sd_assert((SELECT count(*) FROM jsonb_array_elements(:'cust_all'::jsonb #> '{data,sessions}') s WHERE s->>'is_current' = 'true') = 0,
 'is_current is false everywhere when the listed person''s sessions are not the caller''s');
SELECT pg_temp.sd_as(:'admin_claims', format('SELECT public.list_user_sessions(%L)', gen_random_uuid())) AS unknown_person \gset
SELECT pg_temp.sd_assert(:'unknown_person'::jsonb->>'error' = 'NOT_FOUND', 'an unknown person is NOT_FOUND');
-- Exactly one current mark when the caller lists a person whose session it holds (a supervisor listing staff while holding a staff session
-- is not possible; the service role carries the session id of a staff device here).
SELECT pg_temp.sd_as(:'sup_claims', format('SELECT public.list_user_sessions(%L)', :'sup_profile')) AS sup_own \gset
SELECT pg_temp.sd_assert((SELECT count(*) FROM jsonb_array_elements(:'sup_own'::jsonb #> '{data,sessions}') s WHERE s->>'is_current' = 'true') = 1
  AND jsonb_array_length(:'sup_own'::jsonb #> '{data,sessions}') >= 2, 'exactly one of a person''s own sessions is current');
-- An expired session is not listed.
UPDATE warehouse_security.refresh_sessions SET expires_at = now() - interval '1 minute' WHERE token_hash = encode(extensions.digest(:'s3','sha256'),'hex');
SELECT pg_temp.sd_as(:'admin_claims', format('SELECT public.list_user_sessions(%L)', :'staff_profile')) AS listed2 \gset
SELECT pg_temp.sd_assert(jsonb_array_length(:'listed2'::jsonb #> '{data,sessions}') = 9, 'an expired session is not listed');

-- ---------------------------------------------------------------------------
-- 5. Revoking
-- ---------------------------------------------------------------------------
SELECT id AS s4_id FROM warehouse_security.refresh_sessions WHERE token_hash = encode(extensions.digest(:'s4','sha256'),'hex') \gset
SELECT id AS s5_id FROM warehouse_security.refresh_sessions WHERE token_hash = encode(extensions.digest(:'s5','sha256'),'hex') \gset
SELECT id AS s6_id FROM warehouse_security.refresh_sessions WHERE token_hash = encode(extensions.digest(:'s6','sha256'),'hex') \gset
SELECT id AS s7_id FROM warehouse_security.refresh_sessions WHERE token_hash = encode(extensions.digest(:'s7','sha256'),'hex') \gset
SELECT id AS s8_id FROM warehouse_security.refresh_sessions WHERE token_hash = encode(extensions.digest(:'s8','sha256'),'hex') \gset
SELECT id AS s12_id FROM warehouse_security.refresh_sessions WHERE token_hash = encode(extensions.digest(:'s12','sha256'),'hex') \gset
SELECT id AS a1_id FROM warehouse_security.refresh_sessions WHERE token_hash = encode(extensions.digest(:'a1','sha256'),'hex') \gset
SELECT id AS o1_id FROM warehouse_security.refresh_sessions WHERE token_hash = encode(extensions.digest(:'other1','sha256'),'hex') \gset
-- A record of a replaced token for s8, to see it go with the session.
SELECT public.refresh_jwt_token(:'s8')->>'refresh_token' AS s8b \gset
SELECT pg_temp.sd_assert(EXISTS (SELECT 1 FROM warehouse_security.consumed_refresh_tokens WHERE session_id = :'s8_id'), 'fixture: s8 has a recorded token');

-- Staff: not another person's session (answered like an unknown id, nothing deleted), not an administrator's.
SELECT pg_temp.sd_as(:'staff_claims', format('SELECT public.revoke_session(%L)', :'o1_id')) AS st_other \gset
SELECT pg_temp.sd_assert(:'st_other'::jsonb = '{"success":true,"revoked_current":false}'::jsonb AND pg_temp.sd_has(:'other1'),
 'staff cannot revoke another person''s session: '||:'st_other');
SELECT pg_temp.sd_as(:'staff_claims', format('SELECT public.revoke_session(%L)', gen_random_uuid())) AS st_unknown \gset
SELECT pg_temp.sd_assert(:'st_unknown'::jsonb = :'st_other'::jsonb, 'an unknown id gets the same answer as a session that is not the caller''s');
SELECT pg_temp.sd_as(:'staff_claims', format('SELECT public.revoke_session(%L)', :'a1_id')) AS st_admin \gset
SELECT pg_temp.sd_assert(pg_temp.sd_has(:'a1'), 'staff cannot revoke an administrator''s session');
-- A customer: only the own.
SELECT pg_temp.sd_as(:'cust_claims', format('SELECT public.revoke_session(%L)', :'s4_id')) AS cu_other \gset
SELECT pg_temp.sd_assert(pg_temp.sd_has(:'s4'), 'a customer cannot revoke another person''s session');
-- A supervisor: not an administrator's, a staff member's yes.
SELECT pg_temp.sd_as(:'sup_claims', format('SELECT public.revoke_session(%L)', :'a1_id')) AS sup_a \gset
SELECT pg_temp.sd_assert(pg_temp.sd_has(:'a1') AND :'sup_a'::jsonb->>'success' = 'true', 'a supervisor cannot revoke an administrator''s session');
SELECT pg_temp.sd_as(:'sup_claims', format('SELECT public.revoke_session(%L)', :'s8_id')) AS sup_s \gset
SELECT pg_temp.sd_assert(:'sup_s'::jsonb = '{"success":true,"revoked_current":false}'::jsonb AND NOT pg_temp.sd_has(:'s8b'),
 'a supervisor revokes a staff member''s session: '||:'sup_s');
SELECT pg_temp.sd_assert(NOT EXISTS (SELECT 1 FROM warehouse_security.consumed_refresh_tokens WHERE session_id = :'s8_id'),
 'the recorded tokens of a revoked session go with it');
SELECT pg_temp.sd_assert(NOT pg_temp.sd_rotates(:'s8b') AND NOT pg_temp.sd_rotates(:'s8'), 'a revoked session''s tokens cannot be used again');
-- An administrator: any session; an unknown id is NOT_FOUND.
SELECT pg_temp.sd_as(:'admin_claims', format('SELECT public.revoke_session(%L)', :'s7_id')) AS ad_s \gset
SELECT pg_temp.sd_assert(:'ad_s'::jsonb = '{"success":true,"revoked_current":false}'::jsonb AND NOT pg_temp.sd_has(:'s7'), 'an administrator revokes a session');
SELECT pg_temp.sd_as(:'admin_claims', format('SELECT public.revoke_session(%L)', gen_random_uuid())) AS ad_unknown \gset
SELECT pg_temp.sd_assert(:'ad_unknown'::jsonb->>'error' = 'NOT_FOUND' AND :'ad_unknown'::jsonb->>'success' = 'false', 'an administrator gets NOT_FOUND for an unknown id');
SELECT pg_temp.sd_as(:'admin_claims', 'SELECT public.revoke_session(NULL)') AS ad_null \gset
SELECT pg_temp.sd_assert(:'ad_null'::jsonb->>'error' = 'INVALID_INPUT', 'a missing id is INVALID_INPUT');
-- The owner: the own session; the one in use is reported.
SELECT pg_temp.sd_as(:'staff_claims', format('SELECT public.revoke_session(%L)', :'s6_id')) AS own_other \gset
SELECT pg_temp.sd_assert(:'own_other'::jsonb = '{"success":true,"revoked_current":false}'::jsonb AND NOT pg_temp.sd_has(:'s6'),
 'the owner signs out another of their own devices');
SELECT pg_temp.sd_as(:'staff_claims', format('SELECT public.revoke_session(%L)', :'s12_id')) AS own_current \gset
SELECT pg_temp.sd_assert(:'own_current'::jsonb = '{"success":true,"revoked_current":true}'::jsonb AND NOT pg_temp.sd_has(:'s12'),
 'the owner signs out the device in use: revoked_current is true: '||:'own_current');
SELECT pg_temp.sd_as(:'staff_claims', 'SELECT public.check_session()') AS after_revoke \gset
SELECT pg_temp.sd_assert(:'after_revoke'::jsonb->>'state' = '42501' AND :'after_revoke'::jsonb->>'raised' = 'Session expired or revoked',
 'the revoked session fails check_session: '||:'after_revoke');
SELECT pg_temp.sd_assert(pg_temp.sd_count(:'staff_user') = 6, 'only the four revoked sessions went (ten before; the expired one is not listed but still stored)');
-- Audit rows for the revokes that happened (one per deleted session).
SELECT pg_temp.sd_assert((SELECT count(*) FROM public.audit_log WHERE table_name='refresh_sessions' AND action='REVOKE') = 4,
 'each revoke is audited, a refused or unknown one is not');
-- Another person's list is unchanged by all this.
SELECT pg_temp.sd_assert(pg_temp.sd_count(:'other_user') = 2, 'the other person''s sessions are untouched by the refused calls');

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------
SELECT pg_temp.sd_assert(NOT has_function_privilege('anon','public.list_user_sessions(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','public.revoke_session(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.list_user_sessions(uuid)','EXECUTE')
  AND has_function_privilege('authenticated','public.revoke_session(uuid)','EXECUTE')
  AND has_function_privilege('service_role','public.list_user_sessions(uuid)','EXECUTE')
  AND has_function_privilege('service_role','public.revoke_session(uuid)','EXECUTE'), 'the two RPCs are for signed-in accounts and the service role');
SELECT pg_temp.sd_assert(NOT has_function_privilege('authenticated','warehouse_security.issue_session(uuid,uuid,inet,text)','EXECUTE')
  AND NOT has_function_privilege('anon','warehouse_security.issue_session(uuid,uuid,inet,text)','EXECUTE'), 'issue_session stays internal');
SELECT pg_temp.sd_assert(NOT EXISTS (SELECT 1 FROM unnest(ARRAY['anon','authenticated']) r, unnest(ARRAY[
   'public.operator_verify_otp(text,text,text,text,inet)','public.operator_verify_otp(text,text,text,text,inet,text)',
   'public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text)',
   'public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text,text)',
   'public.operator_break_glass_sign_in(text,text,inet)','public.operator_break_glass_sign_in(text,text,inet,text)']) f
   WHERE has_function_privilege(r, f, 'EXECUTE'))
  AND (SELECT bool_and(has_function_privilege('service_role', f, 'EXECUTE')) FROM unnest(ARRAY[
   'public.operator_verify_otp(text,text,text,text,inet)','public.operator_verify_otp(text,text,text,text,inet,text)',
   'public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text)',
   'public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text,text)',
   'public.operator_break_glass_sign_in(text,text,inet)','public.operator_break_glass_sign_in(text,text,inet,text)']) f),
 'both signatures of the three sign-in RPCs are for the service role alone');
\echo Signed-in devices: the newest ten sessions, address and user agent recorded, list and sign-out by owner, administrator and supervisor, masked addresses, old sign-in signatures passed.
ROLLBACK;
