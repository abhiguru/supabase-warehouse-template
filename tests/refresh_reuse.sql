-- Migration 44: refresh-token rotation, the idempotent retry window, reuse
-- detection that ends the session, and logout with a pre-rotation token.
-- Runs only in migrations.sh's disposable, network-disabled database; every
-- fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.refresh_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'refresh reuse: %',label; END IF; END $$;
-- True when PostgREST's pre-request hook would refuse a request of this session.
CREATE FUNCTION pg_temp.session_refused(p_user uuid, p_session uuid) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',p_user,'session_id',p_session)::text,true);
  BEGIN
    PERFORM public.check_session();
    RETURN false;
  EXCEPTION WHEN insufficient_privilege THEN RETURN true;
  END;
END $$;
CREATE FUNCTION pg_temp.session_of(p_refresh text) RETURNS uuid LANGUAGE sql AS $$
  SELECT id FROM warehouse_security.refresh_sessions WHERE token_hash=encode(extensions.digest(p_refresh,'sha256'),'hex');
$$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false'),('refresh_grace_seconds','60')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
SELECT warehouse_security.bootstrap_first_admin('9888888601','Refresh Administrator') AS user_id \gset

-- Normal rotation.
SELECT warehouse_security.issue_session(:'user_id'::uuid)->>'refresh_token' AS r1 \gset
SELECT pg_temp.session_of(:'r1') AS session_a \gset
SET LOCAL ROLE anon;
SELECT public.refresh_jwt_token(:'r1') AS rotated \gset
RESET ROLE;
SELECT :'rotated'::jsonb->>'refresh_token' AS r2 \gset
SELECT pg_temp.refresh_assert(:'rotated'::jsonb->>'success'='true' AND :'r2'<>:'r1' AND :'r2' ~ '^[0-9a-f]{64}$'
  AND :'rotated'::jsonb ? 'access_token' AND :'rotated'::jsonb ? 'expires_at' AND :'rotated'::jsonb->>'token_type'='bearer',
  'rotation issues a new refresh token in the same response shape');
SELECT pg_temp.refresh_assert(pg_temp.session_of(:'r2')=:'session_a'::uuid AND pg_temp.session_of(:'r1') IS NULL,
  'the session row now holds the successor only');
SELECT pg_temp.refresh_assert((SELECT successor_wrap ~ '^[0-9a-f]+$' AND position(:'r2' in successor_wrap)=0
  AND token_hash<>:'r1' AND consumed_at IS NOT NULL FROM warehouse_security.consumed_refresh_tokens WHERE session_id=:'session_a'::uuid),
  'the consumed row stores neither token in clear');

-- Retry within the grace period: same successor, a usable access token, one session.
SELECT public.refresh_jwt_token(:'r1') AS retried \gset
SELECT pg_temp.refresh_assert(:'retried'::jsonb->>'success'='true' AND :'retried'::jsonb->>'refresh_token'=:'r2',
  'a retry within the grace period returns the same successor');
SELECT pg_temp.refresh_assert(:'retried'::jsonb->>'access_token' ~ '^[^.]+\.[^.]+\.[^.]+$'
  AND (:'retried'::jsonb->>'expires_in')::integer>=60,'the retry carries a signed access token');
SELECT pg_temp.refresh_assert((SELECT count(*)=1 FROM warehouse_security.refresh_sessions WHERE user_id=:'user_id'::uuid)
  AND NOT pg_temp.session_refused(:'user_id'::uuid,:'session_a'::uuid),'the retry leaves one live session');
-- Both views of the client (first answer, retried answer) hold r2, and r2 works.
SELECT public.refresh_jwt_token(:'r2') AS third \gset
SELECT :'third'::jsonb->>'refresh_token' AS r3 \gset
SELECT pg_temp.refresh_assert(:'third'::jsonb->>'success'='true' AND :'r3' NOT IN (:'r1',:'r2'),'the converged successor rotates normally');

-- A token two generations old is reuse even inside the grace period.
SELECT pg_temp.refresh_assert(public.refresh_jwt_token(:'r1')->>'success'='false'
  AND public.refresh_jwt_token(:'r1')->>'message'='Invalid refresh token','a token two generations old is refused');
SELECT pg_temp.refresh_assert((SELECT count(*)=0 FROM warehouse_security.refresh_sessions WHERE user_id=:'user_id'::uuid),
  'reuse of an old generation revokes the session');
SELECT pg_temp.refresh_assert(public.refresh_jwt_token(:'r3')->>'success'='false','the current token stops working after reuse');
SELECT pg_temp.refresh_assert(pg_temp.session_refused(:'user_id'::uuid,:'session_a'::uuid),'access tokens of the revoked session are refused');

-- Replay after the grace period revokes the session.
SELECT warehouse_security.issue_session(:'user_id'::uuid)->>'refresh_token' AS s1 \gset
SELECT pg_temp.session_of(:'s1') AS session_b \gset
SELECT public.refresh_jwt_token(:'s1')->>'refresh_token' AS s2 \gset
UPDATE warehouse_security.consumed_refresh_tokens SET consumed_at=now()-interval '61 seconds' WHERE session_id=:'session_b'::uuid;
SELECT pg_temp.refresh_assert(NOT pg_temp.session_refused(:'user_id'::uuid,:'session_b'::uuid),'session is live before the replay');
SELECT pg_temp.refresh_assert(public.refresh_jwt_token(:'s1')->>'success'='false','replay after the grace period is refused');
SELECT pg_temp.refresh_assert(pg_temp.session_of(:'s2') IS NULL AND public.refresh_jwt_token(:'s2')->>'success'='false'
  AND pg_temp.session_refused(:'user_id'::uuid,:'session_b'::uuid),'replay after the grace period revokes the session and its current token');

-- Grace of zero seconds: every replay is reuse.
UPDATE warehouse_security.auth_config SET value='0' WHERE key='refresh_grace_seconds';
SELECT warehouse_security.issue_session(:'user_id'::uuid)->>'refresh_token' AS z1 \gset
SELECT public.refresh_jwt_token(:'z1')->>'refresh_token' AS z2 \gset
SELECT pg_temp.refresh_assert(public.refresh_jwt_token(:'z1')->>'success'='false'
  AND public.refresh_jwt_token(:'z2')->>'success'='false','a zero grace period disables the retry');
UPDATE warehouse_security.auth_config SET value='60' WHERE key='refresh_grace_seconds';

-- A consumed row written before this migration has no successor: replay is reuse.
SELECT warehouse_security.issue_session(:'user_id'::uuid)->>'refresh_token' AS o1 \gset
SELECT public.refresh_jwt_token(:'o1')->>'refresh_token' AS o2 \gset
UPDATE warehouse_security.consumed_refresh_tokens SET consumed_at=NULL,successor_wrap=NULL
  WHERE token_hash=encode(extensions.digest(:'o1','sha256'),'hex');
SELECT pg_temp.refresh_assert(public.refresh_jwt_token(:'o1')->>'success'='false' AND pg_temp.session_of(:'o2') IS NULL,
  'a consumed token without a stored successor is treated as reuse');

-- Logout with the pre-rotation token (logout raced a refresh and lost).
SELECT warehouse_security.issue_session(:'user_id'::uuid)->>'refresh_token' AS l1 \gset
SELECT pg_temp.session_of(:'l1') AS session_l \gset
SELECT public.refresh_jwt_token(:'l1')->>'refresh_token' AS l2 \gset
SET LOCAL ROLE anon;
SELECT public.logout_session(:'l1') AS logged_out \gset
RESET ROLE;
SELECT pg_temp.refresh_assert(:'logged_out'::boolean,'logout with the pre-rotation token answers true');
SELECT pg_temp.refresh_assert((SELECT count(*)=0 FROM warehouse_security.refresh_sessions WHERE user_id=:'user_id'::uuid),
  'logout with the pre-rotation token removes the rotated session');
SELECT pg_temp.refresh_assert(public.refresh_jwt_token(:'l2')->>'success'='false'
  AND public.refresh_jwt_token(:'l1')->>'success'='false','no token of a logged-out session refreshes');
SELECT pg_temp.refresh_assert(pg_temp.session_refused(:'user_id'::uuid,:'session_l'::uuid),'a logged-out session is refused by the session check');

-- Forged tokens change nothing; an expired session and a disabled user cannot refresh.
SELECT warehouse_security.issue_session(:'user_id'::uuid)->>'refresh_token' AS e1 \gset
SELECT pg_temp.session_of(:'e1') AS session_e \gset
SELECT pg_temp.refresh_assert(public.refresh_jwt_token(repeat('0',64))->>'success'='false'
  AND public.refresh_jwt_token('short')->>'success'='false' AND public.refresh_jwt_token(NULL)->>'success'='false'
  AND public.logout_session(repeat('0',64)) AND public.logout_session(NULL),'forged tokens are refused, forged logout answers true');
SELECT pg_temp.refresh_assert(pg_temp.session_of(:'e1')=:'session_e'::uuid,'forged tokens leave other sessions alone');
SELECT public.refresh_jwt_token(:'e1')->>'refresh_token' AS e2 \gset
UPDATE public.user_profiles SET active=false WHERE auth_user_id=:'user_id'::uuid;
SELECT pg_temp.refresh_assert(public.refresh_jwt_token(:'e1')->>'success'='false'
  AND public.refresh_jwt_token(:'e2')->>'success'='false','a deactivated user gets no token, by retry or by rotation');
UPDATE public.user_profiles SET active=true WHERE auth_user_id=:'user_id'::uuid;
SELECT warehouse_security.issue_session(:'user_id'::uuid)->>'refresh_token' AS x1 \gset
UPDATE warehouse_security.refresh_sessions SET expires_at=now()-interval '1 second' WHERE id=pg_temp.session_of(:'x1');
SELECT pg_temp.refresh_assert(public.refresh_jwt_token(:'x1')->>'success'='false','an expired session cannot refresh');
ROLLBACK;
\echo 'Refresh rotation, retry window, reuse revocation and pre-rotation logout checks passed.'
