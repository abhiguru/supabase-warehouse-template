-- Migration 44: OTP limits that a caller without an account cannot turn
-- against a real user. Covers wrong-attempt budgets per issued code and per
-- source, the send lanes of a known phone, the warehouse cap split, the refund
-- of undelivered sends, and the bounds on new access requests.
-- Runs only in migrations.sh's disposable, network-disabled database; every
-- fixture row rolls back. Addresses are documentation ranges.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.otp_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'otp limits: %',label; END IF; END $$;
-- Moves a phone's codes 61 s into the past so the per-source resend cooldown is over.
CREATE FUNCTION pg_temp.age_codes(phone text) RETURNS void LANGUAGE sql AS $$
  UPDATE public.otp_verifications SET created_at=created_at-interval '61 seconds'
    WHERE phone_number=warehouse_security.normalize_phone(phone);
$$;
-- Requests a code and marks it delivered; returns operator_prepare_otp's answer.
CREATE FUNCTION pg_temp.send(phone text, source inet) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb := public.operator_prepare_otp(phone,source);
BEGIN
  IF challenge->>'success'='true' THEN
    PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  END IF;
  RETURN challenge;
END $$;
-- A six-digit code that is not the given one.
CREATE FUNCTION pg_temp.wrong(code text) RETURNS text LANGUAGE sql AS $$
  SELECT lpad(((code::integer+1)%1000000)::text,6,'0');
$$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false'),
 ('otp_global_hourly_cap','300'),('otp_unknown_hourly_cap','60'),('enrollment_daily_cap','30')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE warehouse_security.operator_otp_global_limit SET hourly_count=0,unknown_count=0,window_started=now() WHERE id;
SELECT warehouse_security.bootstrap_first_admin('9888888701','Limits Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status)
 SELECT gen_random_uuid(),'9198888887'||n,'Limits Known '||n,'customer',true,'approved'
 FROM unnest(ARRAY['02','11','12','13','14','15','16','17','18']) AS n;
SELECT pg_temp.otp_assert(NOT has_function_privilege('anon','public.operator_verify_otp(text,text,text,text,inet)','EXECUTE')
  AND NOT has_function_privilege('authenticated','public.operator_verify_otp(text,text,text,text,inet)','EXECUTE')
  AND has_function_privilege('service_role','public.operator_verify_otp(text,text,text,text,inet)','EXECUTE')
  AND to_regprocedure('public.operator_verify_otp(text,text,text,text)') IS NULL,
  'only the edge worker can verify, and only through the source-aware function');

-- A. Wrong guesses from another address cannot use up the requester's attempts.
DO $$ DECLARE challenge jsonb; code text; n integer; outcome jsonb; BEGIN
  challenge := pg_temp.send('9888888701','198.51.100.10');
  code := challenge#>>'{data,otp_code}';
  PERFORM pg_temp.otp_assert(challenge->>'success'='true','administrator requests a code');
  FOR n IN 1..5 LOOP
    outcome := public.operator_verify_otp('9888888701',pg_temp.wrong(code),NULL,NULL,'203.0.113.50');
    PERFORM pg_temp.otp_assert(outcome->>'code'='invalid_otp','wrong guess '||n||' from another address is refused');
  END LOOP;
  PERFORM pg_temp.otp_assert((SELECT attempts=5 AND source_attempts=0 FROM public.otp_verifications
    WHERE id=(challenge#>>'{data,request_id}')::uuid),'foreign guesses are counted apart from the requester');
  PERFORM pg_temp.otp_assert(public.operator_verify_otp('9888888701',code,NULL,NULL,'203.0.113.50')->>'code'='invalid_otp',
    'the other-address budget is five guesses, even for the right code');
  outcome := public.operator_verify_otp('9888888701',code,NULL,NULL,'198.51.100.10');
  PERFORM pg_temp.otp_assert(outcome#>>'{data,action}'='login','the requester still signs in after five foreign wrong guesses');
END $$;

-- B. No code can be tried more than ten times in all.
DO $$ DECLARE challenge jsonb; code text; n integer; BEGIN
  challenge := pg_temp.send('9888888702','198.51.100.10');
  code := challenge#>>'{data,otp_code}';
  FOR n IN 1..5 LOOP
    PERFORM public.operator_verify_otp('9888888702',pg_temp.wrong(code),NULL,NULL,'198.51.100.10');
    PERFORM public.operator_verify_otp('9888888702',pg_temp.wrong(code),NULL,NULL,'203.0.113.50');
  END LOOP;
  PERFORM pg_temp.otp_assert((SELECT attempts=5 AND source_attempts=5 FROM public.otp_verifications
    WHERE id=(challenge#>>'{data,request_id}')::uuid),'each budget holds five guesses');
  PERFORM pg_temp.otp_assert(public.operator_verify_otp('9888888702',code,NULL,NULL,'198.51.100.10')->>'code'='invalid_otp'
    AND public.operator_verify_otp('9888888702',code,NULL,NULL,'203.0.113.51')->>'code'='invalid_otp'
    AND public.operator_verify_otp('9888888702',code)->>'code'='invalid_otp',
    'a code is dead after ten wrong guesses, from any address');
END $$;

-- C. One address gets 20 failed verifications an hour over all phones.
DO $$ DECLARE challenge jsonb; code text; n integer; outcome jsonb; BEGIN
  FOR n IN 1..20 LOOP
    outcome := public.operator_verify_otp('9888888790','123456',NULL,NULL,'203.0.113.60');
    PERFORM pg_temp.otp_assert(outcome->>'code'='invalid_otp','failed verification '||n||' is an ordinary refusal');
  END LOOP;
  PERFORM pg_temp.otp_assert((SELECT verify_failures=20 FROM public.ip_rate_limits WHERE ip_address='203.0.113.60'),
    'failed verifications are counted per source');
  PERFORM pg_temp.age_codes('9888888702');
  challenge := pg_temp.send('9888888702','198.51.100.10');
  code := challenge#>>'{data,otp_code}';
  PERFORM pg_temp.otp_assert(public.operator_verify_otp('9888888702',code,NULL,NULL,'203.0.113.60')->>'code'='rate_limited',
    'a source over its failure limit is refused before the code is looked at');
  PERFORM pg_temp.otp_assert((SELECT attempts=0 AND source_attempts=0 FROM public.otp_verifications
    WHERE id=(challenge#>>'{data,request_id}')::uuid),'a refused source uses up no attempt');
  PERFORM pg_temp.otp_assert(public.operator_verify_otp('9888888702',code,NULL,NULL,'198.51.100.10')#>>'{data,action}'='login',
    'the limited source does not affect the requester');
END $$;

-- D. Send lanes. Strangers use up the administrator's open lane; the phone is
-- slowed down, not locked out, and the administrator's usual address keeps its own allowance.
DO $$ DECLARE n integer; outcome jsonb; BEGIN
  FOR n IN 1..4 LOOP
    outcome := pg_temp.send('9888888701',('203.0.113.'||n)::inet);
    PERFORM pg_temp.otp_assert(outcome->>'success'='true','open-lane request '||n||' from a new address');
  END LOOP;
  PERFORM pg_temp.otp_assert((SELECT hourly_count=5 FROM public.otp_rate_limits WHERE phone_number='919888888701'),
    'the open lane is used up');
  outcome := pg_temp.send('9888888701','203.0.113.5');
  PERFORM pg_temp.otp_assert(outcome->>'success'='true' AND (SELECT quota_lane='slow' FROM public.otp_verifications
    WHERE id=(outcome#>>'{data,request_id}')::uuid),'a known phone past its open lane still gets a code (slow lane)');
  outcome := pg_temp.send('9888888701','203.0.113.6');
  PERFORM pg_temp.otp_assert(outcome->>'code'='resend_cooldown'
    AND (outcome->>'retry_at')::timestamptz BETWEEN now()+interval '14 minutes' AND now()+interval '15 minutes',
    'the slow lane gives one code every 15 minutes and says when');
  FOR n IN 1..5 LOOP
    PERFORM pg_temp.age_codes('9888888701');
    outcome := pg_temp.send('9888888701','198.51.100.10');
    PERFORM pg_temp.otp_assert(outcome->>'success'='true' AND (SELECT quota_lane='trusted' FROM public.otp_verifications
      WHERE id=(outcome#>>'{data,request_id}')::uuid),'request '||n||' from the address the administrator signed in from');
  END LOOP;
  PERFORM pg_temp.age_codes('9888888701');
  PERFORM pg_temp.otp_assert(pg_temp.send('9888888701','198.51.100.10')->>'code'='rate_limited',
    'the trusted lane is five an hour for one address');
  PERFORM pg_temp.otp_assert((SELECT hourly_count=5 FROM public.otp_rate_limits WHERE phone_number='919888888701'),
    'slow and trusted sends do not touch the open counter');
  -- A number without an approved profile keeps the hard limit.
  FOR n IN 11..15 LOOP
    PERFORM pg_temp.otp_assert(pg_temp.send('9888888750',('203.0.113.'||n)::inet)->>'success'='true','unknown number request '||n);
  END LOOP;
  PERFORM pg_temp.otp_assert(pg_temp.send('9888888750','203.0.113.16')->>'code'='rate_limited',
    'an unknown number is refused after five an hour');
  -- The cooldown is per source: the same address must wait, another need not.
  PERFORM pg_temp.otp_assert(pg_temp.send('9888888752','203.0.113.20')->>'success'='true'
    AND pg_temp.send('9888888752','203.0.113.20')->>'code'='resend_cooldown'
    AND pg_temp.send('9888888752','203.0.113.21')->>'success'='true','resend cooldown is per phone and source');
END $$;

-- E. A send the provider did not accept is given back; the source charge stays.
DO $$ DECLARE n integer; outcome jsonb; before_global record; after_global record; BEGIN
  SELECT hourly_count,unknown_count INTO before_global FROM warehouse_security.operator_otp_global_limit WHERE id;
  FOR n IN 1..6 LOOP
    outcome := public.operator_prepare_otp('9888888751','203.0.113.70');
    PERFORM pg_temp.otp_assert(outcome->>'success'='true','request '||n||' during a provider outage');
    PERFORM public.operator_finish_otp((outcome#>>'{data,request_id}')::uuid,false,'provider_unavailable');
  END LOOP;
  SELECT hourly_count,unknown_count INTO after_global FROM warehouse_security.operator_otp_global_limit WHERE id;
  PERFORM pg_temp.otp_assert((SELECT hourly_count=0 AND daily_count=0 FROM public.otp_rate_limits WHERE phone_number='919888888751'),
    'undelivered sends leave the phone allowance untouched');
  PERFORM pg_temp.otp_assert(before_global.hourly_count=after_global.hourly_count AND before_global.unknown_count=after_global.unknown_count,'undelivered sends leave the warehouse allowance untouched');
  PERFORM pg_temp.otp_assert((SELECT hourly_count=6 FROM public.ip_rate_limits WHERE ip_address='203.0.113.70'),
    'the source is still charged for each request');
  outcome := public.operator_prepare_otp('9888888751','203.0.113.70');
  PERFORM public.operator_finish_otp((outcome#>>'{data,request_id}')::uuid,false,'provider_validation');
  PERFORM pg_temp.otp_assert((SELECT hourly_count=1 AND daily_count=1 FROM public.otp_rate_limits WHERE phone_number='919888888751')
    AND (SELECT NOT quota_refunded FROM public.otp_verifications WHERE id=(outcome#>>'{data,request_id}')::uuid),
    'a number the provider calls invalid is not given back');
END $$;

-- F. Warehouse cap: unknown numbers may use only their share; known phones keep the rest.
UPDATE warehouse_security.auth_config SET value='10' WHERE key='otp_global_hourly_cap';
UPDATE warehouse_security.auth_config SET value='3' WHERE key='otp_unknown_hourly_cap';
UPDATE warehouse_security.operator_otp_global_limit SET hourly_count=0,unknown_count=0,window_started=now() WHERE id;
DO $$ DECLARE n integer; BEGIN
  FOR n IN 60..62 LOOP
    PERFORM pg_temp.otp_assert(pg_temp.send('98888887'||n,('203.0.113.'||n+40)::inet)->>'success'='true','unknown number '||n||' inside its share');
  END LOOP;
  PERFORM pg_temp.otp_assert(pg_temp.send('9888888763','203.0.113.103')->>'code'='rate_limited',
    'unknown numbers stop at their share of the warehouse cap');
  FOR n IN 11..17 LOOP
    PERFORM pg_temp.otp_assert(pg_temp.send('98888887'||n,('203.0.113.'||n+100)::inet)->>'success'='true',
      'known phone '||n||' is served after the unknown share is used up');
  END LOOP;
  PERFORM pg_temp.otp_assert((SELECT hourly_count=10 AND unknown_count=3 FROM warehouse_security.operator_otp_global_limit WHERE id),
    'both counters follow the sends');
  PERFORM pg_temp.otp_assert(pg_temp.send('9888888718','203.0.113.118')->>'code'='rate_limited','the warehouse cap still holds for everyone');
END $$;
UPDATE warehouse_security.auth_config SET value='300' WHERE key='otp_global_hourly_cap';
UPDATE warehouse_security.auth_config SET value='60' WHERE key='otp_unknown_hourly_cap';
UPDATE warehouse_security.operator_otp_global_limit SET hourly_count=0,unknown_count=0,window_started=now() WHERE id;

-- G. New access requests: three per source and a daily warehouse cap; names are checked.
DO $$ DECLARE challenge jsonb; outcome jsonb; names text[] := ARRAY['<b>Free</b> http://x.example','  રમેશ   પટેલ  ','Asha & Sons (Unjha) Cold Storage Traders'];
  n integer; BEGIN
  FOR n IN 1..3 LOOP
    challenge := pg_temp.send('988888877'||n,'203.0.113.80');
    outcome := public.operator_verify_otp('988888877'||n,challenge#>>'{data,otp_code}',names[n],NULL,'203.0.113.80');
    PERFORM pg_temp.otp_assert(outcome#>>'{data,action}'='pending','access request '||n||' from one source');
  END LOOP;
  PERFORM pg_temp.otp_assert((SELECT name='New customer' AND display_name='New customer' FROM public.user_profiles WHERE mobile='919888888771'),
    'a name with markup or a link is replaced by the default');
  PERFORM pg_temp.otp_assert((SELECT name='રમેશ પટેલ' AND display_name='રમેશ પટેલ' FROM public.user_profiles WHERE mobile='919888888772'),
    'a Gujarati name is kept, with spaces tidied');
  PERFORM pg_temp.otp_assert((SELECT name='Asha & Sons (Unjha) Cold Stora' FROM public.user_profiles WHERE mobile='919888888773'),
    'a long name is cut to 30 characters');
  PERFORM pg_temp.otp_assert(public.operator_prepare_otp('9888888774','203.0.113.80')->>'code'='rate_limited',
    'a fourth new number from the same source gets no SMS');
  challenge := pg_temp.send('9888888774','203.0.113.81');
  outcome := public.operator_verify_otp('9888888774',challenge#>>'{data,otp_code}','Fourth Request',NULL,'203.0.113.80');
  PERFORM pg_temp.otp_assert(outcome->>'code'='enrollment_limited'
    AND NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE mobile='919888888774'),
    'a fourth access request from the same source creates no profile');
  UPDATE warehouse_security.auth_config SET value='4' WHERE key='enrollment_daily_cap';
  challenge := pg_temp.send('9888888775','203.0.113.81');
  outcome := public.operator_verify_otp('9888888775',challenge#>>'{data,otp_code}','Fifth Request',NULL,'203.0.113.81');
  PERFORM pg_temp.otp_assert(outcome#>>'{data,action}'='pending','another source is served until the daily cap');
  PERFORM pg_temp.otp_assert(public.operator_prepare_otp('9888888776','203.0.113.82')->>'code'='rate_limited',
    'the daily cap on access requests holds for every source');
  PERFORM pg_temp.otp_assert((SELECT count(*)=4 FROM public.user_profiles WHERE enrollment_status='pending' AND mobile LIKE '91988888877_'),
    'four access requests were created in all');
END $$;
SELECT pg_temp.otp_assert(warehouse_security.clean_person_name('Mehul D''Souza-Patel, Jr.')='Mehul D''Souza-Patel, Jr.'
  AND warehouse_security.clean_person_name(E' tab\tand\nnewline ')='tab and newline'
  AND warehouse_security.clean_person_name('12345') IS NULL
  AND warehouse_security.clean_person_name('') IS NULL AND warehouse_security.clean_person_name(NULL) IS NULL
  AND warehouse_security.clean_person_name('x@y.example') IS NULL
  AND warehouse_security.clean_person_name('a'||U&'\202E'||'b') IS NULL
  AND warehouse_security.clean_person_name('<script>') IS NULL,'name rules');
ROLLBACK;
\echo 'OTP attempt budgets, send lanes, warehouse cap split, refunds and access-request bounds passed.'
