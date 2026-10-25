-- Migration 126: sliding sessions (owner decision of 2026-10-25, review item 2).
-- A session of an ACTIVE, APPROVED profile ends session_idle_seconds (default 30 days) after its last refresh and never later than
-- session_max_seconds (default 90 days) after sign-in; any other active profile keeps the fixed 7 days of a new session; disabling a
-- user still deletes the sessions. The clock is real: a session is aged by moving its created_at and expires_at back, which is what
-- time passing does. Values are checked to within two minutes. Fictional data; runs only in migrations.sh's disposable,
-- network-disabled database; every fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ss_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'sliding sessions: %',label; END IF; END $$;
-- True when the moment lies within two minutes of now() plus the interval.
CREATE FUNCTION pg_temp.ss_near(moment timestamptz, ahead interval) RETURNS boolean LANGUAGE sql AS $$
  SELECT abs(extract(epoch FROM (moment - (now() + ahead)))) < 120 $$;
CREATE FUNCTION pg_temp.ss_session(p_refresh text) RETURNS warehouse_security.refresh_sessions LANGUAGE sql AS $$
  SELECT s FROM warehouse_security.refresh_sessions s WHERE s.token_hash=encode(extensions.digest(p_refresh,'sha256'),'hex') $$;
-- A refresh through the public function, as the app role that calls it; returns the new refresh token, or the refusal as text.
CREATE FUNCTION pg_temp.ss_refresh(p_refresh text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN
    answer := public.refresh_jwt_token(p_refresh);
  EXCEPTION WHEN OTHERS THEN RETURN 'raised: '||SQLERRM||' ('||SQLSTATE||')';
  END;
  IF answer->>'success'='true' THEN RETURN answer->>'refresh_token'; END IF;
  RETURN 'refused: '||COALESCE(answer->>'message','');
END $$;
CREATE FUNCTION pg_temp.ss_claims(p_user uuid) RETURNS text LANGUAGE plpgsql AS $$
DECLARE refresh text := warehouse_security.issue_session(p_user)->>'refresh_token';
BEGIN
  RETURN (SELECT jsonb_build_object('role','authenticated','sub',user_id,'session_id',id)::text
    FROM warehouse_security.refresh_sessions WHERE token_hash=encode(extensions.digest(refresh,'sha256'),'hex'));
END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false'),('refresh_grace_seconds','60')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
SELECT warehouse_security.bootstrap_first_admin('9888888901','Sliding Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888902','Sliding Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888903','Sliding Waiting','staff',true,'pending'),
 (gen_random_uuid(),'919888888904','Sliding Switched Off','staff',true,'approved');
SELECT auth_user_id AS staff_user, id AS staff_profile FROM public.user_profiles WHERE mobile='919888888902' \gset
SELECT auth_user_id AS waiting_user FROM public.user_profiles WHERE mobile='919888888903' \gset
SELECT auth_user_id AS off_user FROM public.user_profiles WHERE mobile='919888888904' \gset

-- 0. The defaults are seeded; the optional trusted-source list is not.
SELECT pg_temp.ss_assert((SELECT value FROM warehouse_security.auth_config WHERE key='session_idle_seconds')='2592000'
  AND (SELECT value FROM warehouse_security.auth_config WHERE key='session_max_seconds')='7776000',
  'the idle time is 30 days and the absolute limit 90 days by default');

SELECT pg_temp.ss_assert((SELECT bool_and(NOT has_function_privilege(r,f,'EXECUTE'))
    FROM unnest(ARRAY['anon','authenticated','service_role']) r,
         unnest(ARRAY['warehouse_security.session_idle_seconds()','warehouse_security.session_max_seconds()']) f),
  'the two session helpers are for the database functions only');

-- 1. A new sign-in lasts the idle time (30 days), not the old 7 days.
SELECT warehouse_security.issue_session(:'staff_user'::uuid)->>'refresh_token' AS r1 \gset
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'r1')).expires_at, interval '30 days')
  AND pg_temp.ss_near((pg_temp.ss_session(:'r1')).created_at, interval '0'),
  'a new session of an approved, active profile ends 30 days from now (the old code: 7 days)');

-- 2. A refresh moves the end to 30 days after the refresh. The session's last refresh was 29 days ago (it ends in 1 day).
UPDATE warehouse_security.refresh_sessions SET created_at=now()-interval '10 days', expires_at=now()+interval '1 day'
  WHERE token_hash=encode(extensions.digest(:'r1','sha256'),'hex');
SET LOCAL ROLE anon;
SELECT pg_temp.ss_refresh(:'r1') AS r2 \gset
RESET ROLE;
SELECT pg_temp.ss_assert(:'r2' ~ '^[0-9a-f]{64}$' AND :'r2'<>:'r1', 'the refresh succeeds and rotates the token: '||:'r2');
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'r2')).expires_at, interval '30 days'),
  'the refresh moved the end from 1 day ahead to 30 days ahead (the old code left it at 1 day)');
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'r2')).created_at, interval '-10 days'),
  'the sign-in time of the session is kept by a refresh');

-- 3. The absolute limit: signed in 80 days ago, so the session may end 10 days from now at the latest, not 30.
UPDATE warehouse_security.refresh_sessions SET created_at=now()-interval '80 days', expires_at=now()+interval '1 day'
  WHERE token_hash=encode(extensions.digest(:'r2','sha256'),'hex');
SELECT pg_temp.ss_refresh(:'r2') AS r3 \gset
SELECT pg_temp.ss_assert(:'r3' ~ '^[0-9a-f]{64}$', 'a session 80 days old still refreshes: '||:'r3');
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'r3')).expires_at, interval '10 days'),
  'the end is capped at 90 days after sign-in, 10 days from now (not 30)');

-- 4. Past the absolute limit (the operator lowered it under a live session, or the clock moved): no renewal, the session is not extended.
UPDATE warehouse_security.refresh_sessions SET created_at=now()-interval '91 days', expires_at=now()+interval '1 day'
  WHERE token_hash=encode(extensions.digest(:'r3','sha256'),'hex');
SELECT count(*) AS consumed_before FROM warehouse_security.consumed_refresh_tokens WHERE session_id=(pg_temp.ss_session(:'r3')).id \gset
SELECT pg_temp.ss_refresh(:'r3') AS r4 \gset
SELECT pg_temp.ss_assert(:'r4' = 'raised: Session expired (P0001)', 'a session past 90 days is not renewed; the app''s definitive answer is raised: '||:'r4');
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'r3')).expires_at, interval '1 day'),
  'the refused refresh leaves the end where it was (token not rotated, nothing consumed)');
SELECT pg_temp.ss_assert((SELECT count(*)=:consumed_before FROM warehouse_security.consumed_refresh_tokens WHERE session_id=(pg_temp.ss_session(:'r3')).id)
  AND :consumed_before=2, 'the refused refresh consumed no token (the two earlier rotations of the session are the only consumed ones)');

-- 5. A session made before this migration (7 days from sign-in, signed in 6 days ago) is extended by its first refresh.
SELECT warehouse_security.issue_session(:'staff_user'::uuid)->>'refresh_token' AS old1 \gset
UPDATE warehouse_security.refresh_sessions SET created_at=now()-interval '6 days', expires_at=now()+interval '1 day'
  WHERE token_hash=encode(extensions.digest(:'old1','sha256'),'hex');
SELECT pg_temp.ss_refresh(:'old1') AS old2 \gset
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'old2')).expires_at, interval '30 days'),
  'a session of the 7-day kind is extended to 30 days from now by a refresh');

-- 6. The two values come from auth_config and are clamped.
UPDATE warehouse_security.auth_config SET value='86400' WHERE key='session_idle_seconds';
SELECT warehouse_security.issue_session(:'staff_user'::uuid)->>'refresh_token' AS c1 \gset
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'c1')).expires_at, interval '1 day'), 'idle time 86400: a new session ends in 1 day');
UPDATE warehouse_security.auth_config SET value='60' WHERE key='session_idle_seconds';
SELECT warehouse_security.issue_session(:'staff_user'::uuid)->>'refresh_token' AS c2 \gset
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'c2')).expires_at, interval '1 hour'), 'idle time 60 is raised to the minimum of 1 hour');
UPDATE warehouse_security.auth_config SET value='999999999' WHERE key='session_idle_seconds';
SELECT warehouse_security.issue_session(:'staff_user'::uuid)->>'refresh_token' AS c3 \gset
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'c3')).expires_at, interval '365 days'), 'idle time 999999999 is cut to 365 days');
UPDATE warehouse_security.auth_config SET value='abc' WHERE key='session_idle_seconds';
SELECT warehouse_security.issue_session(:'staff_user'::uuid)->>'refresh_token' AS c4 \gset
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'c4')).expires_at, interval '30 days'), 'idle time "abc" means the default of 30 days');
DELETE FROM warehouse_security.auth_config WHERE key='session_idle_seconds';
SELECT warehouse_security.issue_session(:'staff_user'::uuid)->>'refresh_token' AS c5 \gset
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'c5')).expires_at, interval '30 days'), 'no idle key means the default of 30 days');
-- The absolute limit is never below the idle time: idle 30 days, limit set to 1 day, signed in 20 days ago: the end is 30 days after
-- sign-in, which is 10 days from now.
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('session_idle_seconds','2592000');
UPDATE warehouse_security.auth_config SET value='86400' WHERE key='session_max_seconds';
SELECT warehouse_security.issue_session(:'staff_user'::uuid)->>'refresh_token' AS m1 \gset
UPDATE warehouse_security.refresh_sessions SET created_at=now()-interval '20 days', expires_at=now()+interval '1 day'
  WHERE token_hash=encode(extensions.digest(:'m1','sha256'),'hex');
SELECT pg_temp.ss_refresh(:'m1') AS m2 \gset
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'m2')).expires_at, interval '10 days'),
  'a limit below the idle time is raised to the idle time: 30 days after sign-in, 10 days from now');
-- The absolute limit is cut to 1095 days: idle 365 days, limit 999999999, signed in 1000 days ago: the end is 95 days from now, not 365.
UPDATE warehouse_security.auth_config SET value='31536000' WHERE key='session_idle_seconds';
UPDATE warehouse_security.auth_config SET value='999999999' WHERE key='session_max_seconds';
SELECT warehouse_security.issue_session(:'staff_user'::uuid)->>'refresh_token' AS m3 \gset
UPDATE warehouse_security.refresh_sessions SET created_at=now()-interval '1000 days', expires_at=now()+interval '1 day'
  WHERE token_hash=encode(extensions.digest(:'m3','sha256'),'hex');
SELECT pg_temp.ss_refresh(:'m3') AS m4 \gset
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'m4')).expires_at, interval '95 days'),
  'a limit of 999999999 is cut to 1095 days after sign-in');
UPDATE warehouse_security.auth_config SET value='2592000' WHERE key='session_idle_seconds';
UPDATE warehouse_security.auth_config SET value='7776000' WHERE key='session_max_seconds';

-- 7. A profile that is active but not approved is not extended: a new session keeps the fixed 7 days, a refresh leaves the end alone.
SELECT warehouse_security.issue_session(:'waiting_user'::uuid)->>'refresh_token' AS w1 \gset
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'w1')).expires_at, interval '7 days'),
  'a new session of an active, not approved profile ends 7 days from now');
UPDATE warehouse_security.refresh_sessions SET expires_at=now()+interval '1 day' WHERE token_hash=encode(extensions.digest(:'w1','sha256'),'hex');
SELECT pg_temp.ss_refresh(:'w1') AS w2 \gset
SELECT pg_temp.ss_assert(:'w2' ~ '^[0-9a-f]{64}$' AND :'w2'<>:'w1', 'the token of such a session still rotates: '||:'w2');
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'w2')).expires_at, interval '1 day'),
  'a refresh does not extend the session of a profile that is not approved (the end stays 1 day ahead)');

-- 8. A profile that is switched off gets no renewal and no extension.
SELECT warehouse_security.issue_session(:'off_user'::uuid)->>'refresh_token' AS o1 \gset
UPDATE warehouse_security.refresh_sessions SET expires_at=now()+interval '1 day' WHERE token_hash=encode(extensions.digest(:'o1','sha256'),'hex');
UPDATE public.user_profiles SET active=false WHERE auth_user_id=:'off_user'::uuid;
SELECT pg_temp.ss_assert(pg_temp.ss_refresh(:'o1') = 'refused: Invalid refresh token', 'an inactive profile cannot refresh: '||pg_temp.ss_refresh(:'o1'));
SELECT pg_temp.ss_assert(pg_temp.ss_near((pg_temp.ss_session(:'o1')).expires_at, interval '1 day'), 'the refused refresh did not extend the session');
UPDATE public.user_profiles SET active=true WHERE auth_user_id=:'off_user'::uuid;
SELECT pg_temp.ss_assert((SELECT count(*)=1 FROM public.user_profiles WHERE auth_user_id=:'off_user'::uuid AND enrollment_status='approved'),
  'fixture: the switched-off profile is approved again');

-- 8b. Reuse detection lasts as long as the session can. The record of a replaced token ends at the latest end the session can have
--     (sign-in + the absolute limit), not at the end the session had when the token was replaced: a session that slides would outlive
--     the second, and a stolen token the real holder presents weeks later would be refused without ending the session.
--     The session was signed in 1 day ago and last used 29 days ago (it ends in 1 day); a thief replaces the real holder's token.
SELECT warehouse_security.issue_session(:'staff_user'::uuid)->>'refresh_token' AS u1 \gset
UPDATE warehouse_security.refresh_sessions SET created_at=now()-interval '1 day', expires_at=now()+interval '1 day'
  WHERE token_hash=encode(extensions.digest(:'u1','sha256'),'hex');
SELECT pg_temp.ss_refresh(:'u1') AS u2 \gset
SELECT pg_temp.ss_assert(:'u2' ~ '^[0-9a-f]{64}$', 'the thief''s refresh succeeds: '||:'u2');
SELECT (pg_temp.ss_session(:'u2')).id AS u_session \gset
SELECT pg_temp.ss_assert(pg_temp.ss_near((SELECT expires_at FROM warehouse_security.consumed_refresh_tokens
    WHERE token_hash=encode(extensions.digest(:'u1','sha256'),'hex')), interval '89 days'),
  'the record of the replaced token lasts to 90 days after sign-in, 89 days from now (the end the session had when it was replaced, 1 day, would lose it)');
-- Forty days pass while the thief keeps the session sliding (it now ends in 29 days); the records age with it.
UPDATE warehouse_security.refresh_sessions SET created_at=created_at-interval '40 days', expires_at=now()+interval '29 days' WHERE id=:'u_session'::uuid;
UPDATE warehouse_security.consumed_refresh_tokens SET consumed_at=consumed_at-interval '40 days', expires_at=expires_at-interval '40 days' WHERE session_id=:'u_session'::uuid;
SELECT pg_temp.ss_assert(pg_temp.ss_refresh(:'u1') = 'refused: Invalid refresh token', 'the real holder presents the replaced token 40 days later: refused');
SELECT pg_temp.ss_assert((SELECT count(*)=0 FROM warehouse_security.refresh_sessions WHERE id=:'u_session'::uuid),
  'and the session is ended for both holders (reuse is found; the old code kept the thief''s session)');
-- A record that is older than the longest possible session is gone: the replaced token is only refused.
SELECT warehouse_security.issue_session(:'staff_user'::uuid)->>'refresh_token' AS v1 \gset
SELECT pg_temp.ss_refresh(:'v1') AS v2 \gset
SELECT (pg_temp.ss_session(:'v2')).id AS v_session \gset
UPDATE warehouse_security.consumed_refresh_tokens SET consumed_at=now()-interval '100 days', expires_at=now()-interval '10 days' WHERE session_id=:'v_session'::uuid;
SELECT pg_temp.ss_assert(pg_temp.ss_refresh(:'v1') = 'refused: Invalid refresh token'
  AND (SELECT count(*)=1 FROM warehouse_security.refresh_sessions WHERE id=:'v_session'::uuid),
  'a record past its end is gone: the token is refused and the session, which no record points at, is left alone');

-- 9. Disabling a user from the administrator's screen still deletes every session of the user.
SELECT pg_temp.ss_claims(:'admin_user'::uuid) AS admin_claims \gset
SELECT warehouse_security.issue_session(:'staff_user'::uuid)->>'refresh_token' AS d1 \gset
SELECT pg_temp.ss_assert((SELECT count(*)>=2 FROM warehouse_security.refresh_sessions WHERE user_id=:'staff_user'::uuid),
  'the staff user has several live sessions before the switch-off');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_user_status(:'staff_profile'::uuid,false) AS disabled \gset
RESET ROLE;
SELECT pg_temp.ss_assert(:'disabled'::jsonb->>'success'='true', 'the administrator switches the staff user off: '||:'disabled');
SELECT pg_temp.ss_assert((SELECT count(*)=0 FROM warehouse_security.refresh_sessions WHERE user_id=:'staff_user'::uuid),
  'switching a user off deletes all of the sessions, long as they are');
SELECT pg_temp.ss_assert(pg_temp.ss_refresh(:'d1') = 'refused: Invalid refresh token', 'the token of a deleted session no longer refreshes');
ROLLBACK;
\echo 'Sliding sessions: idle extension, absolute limit, configuration and clamps, profiles that are not approved or not active, and revocation passed.'
