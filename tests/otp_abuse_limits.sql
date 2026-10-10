-- Migrations 44 and 47: OTP limits that a caller without an account cannot
-- turn against a real user, inside a fixed bound on guesses per code and on
-- SMS per phone. Covers the five wrong attempts per issued code and how they
-- are split between the requester and other sources, the per-source failure
-- limit, the open and trusted send lanes with the 24 hour cap per phone and
-- the reserve for trusted sources, the installer's reset, the warehouse cap
-- split, the refund of undelivered sends, and the bounds on new access requests.
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
-- Moves a phone's send history n hours into the past: the counted sends, the
-- hourly window of the open lane and the codes themselves (cooldown).
CREATE FUNCTION pg_temp.age_hours(phone text, n integer) RETURNS void LANGUAGE sql AS $$
  UPDATE warehouse_security.otp_send_log SET created_at=created_at-make_interval(hours=>n)
    WHERE phone_number=warehouse_security.normalize_phone(phone);
  UPDATE public.otp_rate_limits SET last_reset_hour=last_reset_hour-make_interval(hours=>n)
    WHERE phone_number=warehouse_security.normalize_phone(phone);
  UPDATE public.otp_verifications SET created_at=created_at-make_interval(hours=>n)
    WHERE phone_number=warehouse_security.normalize_phone(phone);
$$;
-- n requests for a phone, each from the next address after `first`; returns how many were accepted.
CREATE FUNCTION pg_temp.send_many(phone text, first inet, n integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE accepted integer := 0; i integer;
BEGIN
  FOR i IN 0..n-1 LOOP
    IF pg_temp.send(phone,first+i)->>'success'='true' THEN accepted := accepted+1; END IF;
  END LOOP;
  RETURN accepted;
END $$;
-- n requests for a phone from one address, 61 s apart; returns how many were accepted.
CREATE FUNCTION pg_temp.send_repeat(phone text, source inet, n integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE accepted integer := 0; i integer;
BEGIN
  FOR i IN 1..n LOOP
    PERFORM pg_temp.age_codes(phone);
    IF pg_temp.send(phone,source)->>'success'='true' THEN accepted := accepted+1; END IF;
  END LOOP;
  RETURN accepted;
END $$;
-- A six-digit code that is not the given one.
CREATE FUNCTION pg_temp.wrong(code text) RETURNS text LANGUAGE sql AS $$
  SELECT lpad(((code::integer+1)%1000000)::text,6,'0');
$$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false'),
 ('otp_global_hourly_cap','300'),('otp_unknown_hourly_cap','60'),('enrollment_daily_cap','30'),
 ('otp_phone_daily_cap','30'),('otp_trusted_daily_reserve','10')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE warehouse_security.operator_otp_global_limit SET hourly_count=0,unknown_count=0,window_started=now() WHERE id;
SELECT warehouse_security.bootstrap_first_admin('9888888701','Limits Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status)
 SELECT gen_random_uuid(),'9198888887'||n,'Limits Known '||n,'customer',true,'approved'
 FROM unnest(ARRAY['02','11','12','13','14','15','16','17','18','21','22','23']) AS n;
SELECT pg_temp.otp_assert(NOT has_function_privilege('anon','public.operator_verify_otp(text,text,text,text,inet)','EXECUTE')
  AND NOT has_function_privilege('authenticated','public.operator_verify_otp(text,text,text,text,inet)','EXECUTE')
  AND has_function_privilege('service_role','public.operator_verify_otp(text,text,text,text,inet)','EXECUTE')
  AND to_regprocedure('public.operator_verify_otp(text,text,text,text)') IS NULL,
  'only the edge worker can verify, and only through the source-aware function');

-- A. A code can be tried wrongly five times in all. Other addresses share two
-- of the five, so they cannot use up the attempts of the person who asked.
DO $$ DECLARE challenge jsonb; code text; n integer; outcome jsonb; BEGIN
  challenge := pg_temp.send('9888888701','198.51.100.10');
  code := challenge#>>'{data,otp_code}';
  PERFORM pg_temp.otp_assert(challenge->>'success'='true','administrator requests a code');
  FOR n IN 1..2 LOOP
    outcome := public.operator_verify_otp('9888888701',pg_temp.wrong(code),NULL,NULL,'203.0.113.50');
    PERFORM pg_temp.otp_assert(outcome->>'code'='invalid_otp','wrong guess '||n||' from another address is refused');
  END LOOP;
  PERFORM pg_temp.otp_assert((SELECT attempts=2 AND source_attempts=0 FROM public.otp_verifications
    WHERE id=(challenge#>>'{data,request_id}')::uuid),'foreign guesses are counted apart from the requester');
  PERFORM pg_temp.otp_assert(public.operator_verify_otp('9888888701',code,NULL,NULL,'203.0.113.50')->>'code'='invalid_otp'
    AND public.operator_verify_otp('9888888701',code,NULL,NULL,'203.0.113.51')->>'code'='invalid_otp'
    AND public.operator_verify_otp('9888888701',code)->>'code'='invalid_otp',
    'other addresses have two guesses per code between them, even for the right code');
  PERFORM pg_temp.otp_assert((SELECT attempts=2 AND source_attempts=0 FROM public.otp_verifications
    WHERE id=(challenge#>>'{data,request_id}')::uuid),'a guess that is not admitted is not counted on the code');
  FOR n IN 1..2 LOOP
    outcome := public.operator_verify_otp('9888888701',pg_temp.wrong(code),NULL,NULL,'198.51.100.10');
    PERFORM pg_temp.otp_assert(outcome->>'code'='invalid_otp','the requester''s own wrong guess '||n);
  END LOOP;
  outcome := public.operator_verify_otp('9888888701',code,NULL,NULL,'198.51.100.10');
  PERFORM pg_temp.otp_assert(outcome#>>'{data,action}'='login',
    'the requester signs in on the fifth try after two foreign and two own wrong guesses: '||COALESCE(outcome->>'code',''));
END $$;

-- B. No code can be tried wrongly more than five times in all, whoever guesses.
DO $$ DECLARE challenge jsonb; code text; n integer; BEGIN
  challenge := pg_temp.send('9888888702','198.51.100.10');
  code := challenge#>>'{data,otp_code}';
  FOR n IN 1..3 LOOP
    PERFORM public.operator_verify_otp('9888888702',pg_temp.wrong(code),NULL,NULL,'203.0.113.50');
    PERFORM public.operator_verify_otp('9888888702',pg_temp.wrong(code),NULL,NULL,'198.51.100.10');
  END LOOP;
  PERFORM pg_temp.otp_assert((SELECT attempts=2 AND source_attempts=3 FROM public.otp_verifications
    WHERE id=(challenge#>>'{data,request_id}')::uuid),'two foreign and three own wrong guesses are the whole budget');
  PERFORM pg_temp.otp_assert(public.operator_verify_otp('9888888702',code,NULL,NULL,'198.51.100.10')->>'code'='invalid_otp'
    AND public.operator_verify_otp('9888888702',code,NULL,NULL,'203.0.113.51')->>'code'='invalid_otp'
    AND public.operator_verify_otp('9888888702',code)->>'code'='invalid_otp',
    'a code is dead after five wrong guesses, from any address');
  PERFORM pg_temp.otp_assert((SELECT attempts+source_attempts=5 FROM public.otp_verifications
    WHERE id=(challenge#>>'{data,request_id}')::uuid),'no code is tried more than five times');
  -- The requester alone has all five.
  PERFORM pg_temp.age_codes('9888888702');
  challenge := pg_temp.send('9888888702','198.51.100.10');
  code := challenge#>>'{data,otp_code}';
  FOR n IN 1..5 LOOP
    PERFORM public.operator_verify_otp('9888888702',pg_temp.wrong(code),NULL,NULL,'198.51.100.10');
  END LOOP;
  PERFORM pg_temp.otp_assert((SELECT attempts=0 AND source_attempts=5 FROM public.otp_verifications
    WHERE id=(challenge#>>'{data,request_id}')::uuid)
    AND public.operator_verify_otp('9888888702',code,NULL,NULL,'198.51.100.10')->>'code'='invalid_otp',
    'the requester''s own five wrong guesses end the code');
  -- A request and a verification without a source address are the same source.
  PERFORM pg_temp.age_codes('9888888702');
  challenge := pg_temp.send('9888888702',NULL);
  code := challenge#>>'{data,otp_code}';
  FOR n IN 1..4 LOOP
    PERFORM public.operator_verify_otp('9888888702',pg_temp.wrong(code));
  END LOOP;
  PERFORM pg_temp.otp_assert(public.operator_verify_otp('9888888702',code)#>>'{data,action}'='login',
    'without a source address the requester still has five tries');
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

-- D. Send lanes. Strangers use up the hour of the administrator's open lane;
-- every address that has not signed in for the phone is then refused, and the
-- address the administrator signed in from (section A) keeps its own allowance.
DO $$ DECLARE n integer; outcome jsonb; BEGIN
  PERFORM pg_temp.otp_assert(pg_temp.send_many('9888888701','203.0.113.1',4)=4,'four open-lane requests from new addresses');
  PERFORM pg_temp.otp_assert((SELECT hourly_count=5 FROM public.otp_rate_limits WHERE phone_number='919888888701'),
    'the open lane is used up for this hour');
  outcome := pg_temp.send('9888888701','203.0.113.5');
  PERFORM pg_temp.otp_assert(outcome->>'code'='rate_limited' AND NOT outcome ? 'retry_at',
    'a known phone past its open lane gets no code from a new address (no slow lane): '||outcome::text);
  PERFORM pg_temp.otp_assert((SELECT count(*)=0 FROM public.otp_verifications WHERE phone_number='919888888701' AND quota_lane='slow'),
    'no slow-lane code is issued');
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
    'trusted sends do not touch the open counter');
  PERFORM pg_temp.otp_assert((SELECT count(*) FILTER (WHERE lane='open')=5 AND count(*) FILTER (WHERE lane='trusted')=5
    FROM warehouse_security.otp_send_log WHERE phone_number='919888888701'),'every counted send is in the send log with its lane');
  -- A number without an approved profile has the open lane only.
  PERFORM pg_temp.otp_assert(pg_temp.send_many('9888888750','203.0.113.11',5)=5,'five requests for an unknown number');
  PERFORM pg_temp.otp_assert(pg_temp.send('9888888750','203.0.113.16')->>'code'='rate_limited',
    'an unknown number is refused after five an hour');
  -- The cooldown is per source: the same address must wait, another need not.
  PERFORM pg_temp.otp_assert(pg_temp.send('9888888752','203.0.113.20')->>'success'='true','first request of the cooldown pair');
  outcome := pg_temp.send('9888888752','203.0.113.20');
  PERFORM pg_temp.otp_assert(outcome->>'code'='resend_cooldown'
    AND (outcome->>'retry_at')::timestamptz BETWEEN now()+interval '59 seconds' AND now()+interval '60 seconds',
    'the same address must wait 60 s and is told until when: '||outcome::text);
  PERFORM pg_temp.otp_assert(pg_temp.send('9888888752','203.0.113.21')->>'success'='true','resend cooldown is per phone and source');
END $$;

-- D2. One phone in 24 hours: 30 codes in all; addresses that have not signed
-- in share 20 of them, so 10 stay for addresses that have.
INSERT INTO warehouse_security.otp_trusted_sources(phone_number,ip_address) VALUES
 ('919888888721','198.51.100.21'),('919888888722','198.51.100.22');
DO $$ DECLARE round integer; outcome jsonb; BEGIN
  -- Phone 21: a stranger with fresh addresses asks five times an hour.
  FOR round IN 1..4 LOOP
    PERFORM pg_temp.otp_assert(pg_temp.send_many('9888888721',('203.0.114.'||round*10)::inet,5)=5,'stranger hour '||round||': five codes');
    PERFORM pg_temp.age_hours('9888888721',2);
  END LOOP;
  PERFORM pg_temp.otp_assert((SELECT hourly_count=5 AND last_reset_hour<now()-interval '1 hour' FROM public.otp_rate_limits WHERE phone_number='919888888721'),
    'the open lane''s hour is over, so only the day count can refuse the next request');
  outcome := pg_temp.send('9888888721','203.0.114.90');
  PERFORM pg_temp.otp_assert(outcome->>'code'='rate_limited' AND NOT outcome ? 'retry_at',
    'the 21st code in 24 hours for addresses that have not signed in is refused: '||outcome::text);
  -- The owner's usual address still gets the reserved ten, and no more.
  PERFORM pg_temp.otp_assert(pg_temp.send_repeat('9888888721','198.51.100.21',5)=5,'trusted address: five codes after the open share is used up');
  PERFORM pg_temp.age_hours('9888888721',2);
  PERFORM pg_temp.otp_assert(pg_temp.send_repeat('9888888721','198.51.100.21',5)=5,'trusted address: five more an hour later');
  PERFORM pg_temp.age_hours('9888888721',2);
  PERFORM pg_temp.otp_assert((SELECT count(*)=30 FROM warehouse_security.otp_send_log WHERE phone_number='919888888721'
    AND created_at>now()-interval '24 hours'),'thirty codes were counted in under 24 hours');
  PERFORM pg_temp.age_codes('9888888721');
  PERFORM pg_temp.otp_assert(pg_temp.send('9888888721','198.51.100.21')->>'code'='rate_limited'
    AND pg_temp.send('9888888721','203.0.114.91')->>'code'='rate_limited',
    'the 31st code in 24 hours is refused for every source');
  -- The installer clears the phone; the limits start again.
  PERFORM pg_temp.otp_assert(warehouse_security.reset_otp_limits('9888888721')=30,'the installer''s reset reports the thirty counted sends');
  PERFORM pg_temp.otp_assert((SELECT count(*)=0 FROM warehouse_security.otp_send_log WHERE phone_number='919888888721')
    AND (SELECT hourly_count=0 AND daily_count=0 FROM public.otp_rate_limits WHERE phone_number='919888888721'),
    'the installer''s reset clears the phone''s counted sends');
  PERFORM pg_temp.otp_assert(pg_temp.send('9888888721','203.0.114.92')->>'success'='true'
    AND (SELECT count(*)=1 FROM warehouse_security.otp_trusted_sources WHERE phone_number='919888888721'),
    'after the reset a new address gets a code, and the trusted address is kept');
  -- Phone 22: trusted sends may use more than the reserve while the open share is unused; the total stays 30.
  FOR round IN 1..4 LOOP
    PERFORM pg_temp.otp_assert(pg_temp.send_repeat('9888888722','198.51.100.22',5)=5,'trusted hour '||round||': five codes');
    PERFORM pg_temp.age_hours('9888888722',2);
  END LOOP;
  PERFORM pg_temp.otp_assert(pg_temp.send_many('9888888722','203.0.115.10',5)=5,'new addresses: five codes');
  PERFORM pg_temp.age_hours('9888888722',2);
  PERFORM pg_temp.otp_assert(pg_temp.send_many('9888888722','203.0.115.20',5)=5,'new addresses: five more');
  PERFORM pg_temp.age_hours('9888888722',2);
  PERFORM pg_temp.age_codes('9888888722');
  PERFORM pg_temp.otp_assert(pg_temp.send('9888888722','203.0.115.30')->>'code'='rate_limited'
    AND pg_temp.send('9888888722','198.51.100.22')->>'code'='rate_limited',
    'twenty trusted and ten other codes are the daily cap of 30');
  -- 24 hours after the first sends the phone is served again.
  PERFORM pg_temp.age_hours('9888888722',24);
  PERFORM pg_temp.otp_assert(pg_temp.send('9888888722','203.0.115.31')->>'success'='true','the cap is a rolling 24 hours');
  -- Both values come from auth_config.
  UPDATE warehouse_security.auth_config SET value='6' WHERE key='otp_phone_daily_cap';
  UPDATE warehouse_security.auth_config SET value='2' WHERE key='otp_trusted_daily_reserve';
  PERFORM pg_temp.otp_assert(pg_temp.send_many('9888888723','203.0.116.10',5)=4,
    'with a cap of 6 and a reserve of 2, new addresses get four codes');
  UPDATE warehouse_security.auth_config SET value='30' WHERE key='otp_phone_daily_cap';
  UPDATE warehouse_security.auth_config SET value='10' WHERE key='otp_trusted_daily_reserve';
END $$;
SELECT pg_temp.otp_assert(NOT has_function_privilege('anon','warehouse_security.reset_otp_limits(text)','EXECUTE')
  AND NOT has_function_privilege('authenticated','warehouse_security.reset_otp_limits(text)','EXECUTE')
  AND NOT has_function_privilege('service_role','warehouse_security.reset_otp_limits(text)','EXECUTE')
  AND NOT has_table_privilege('authenticated','warehouse_security.otp_send_log','SELECT')
  AND NOT has_table_privilege('service_role','warehouse_security.otp_send_log','SELECT')
  AND (SELECT relrowsecurity FROM pg_class WHERE oid='warehouse_security.otp_send_log'::regclass),
  'only the installer resets a phone, and no API role reads the send log');

-- E. A send the provider did not accept is given back; the source charge stays.
DO $$ DECLARE n integer; outcome jsonb; before_global record; after_global record; BEGIN
  SELECT hourly_count,unknown_count INTO before_global FROM warehouse_security.operator_otp_global_limit WHERE id;
  FOR n IN 1..6 LOOP
    outcome := public.operator_prepare_otp('9888888751','203.0.113.70');
    PERFORM pg_temp.otp_assert(outcome->>'success'='true','request '||n||' during a provider outage');
    PERFORM public.operator_finish_otp((outcome#>>'{data,request_id}')::uuid,false,'provider_unavailable');
  END LOOP;
  SELECT hourly_count,unknown_count INTO after_global FROM warehouse_security.operator_otp_global_limit WHERE id;
  PERFORM pg_temp.otp_assert((SELECT hourly_count=0 AND daily_count=0 FROM public.otp_rate_limits WHERE phone_number='919888888751')
    AND (SELECT count(*)=0 FROM warehouse_security.otp_send_log WHERE phone_number='919888888751'),
    'undelivered sends leave the phone allowance untouched');
  PERFORM pg_temp.otp_assert(before_global.hourly_count=after_global.hourly_count AND before_global.unknown_count=after_global.unknown_count,'undelivered sends leave the warehouse allowance untouched');
  PERFORM pg_temp.otp_assert((SELECT hourly_count=6 FROM public.ip_rate_limits WHERE ip_address='203.0.113.70'),
    'the source is still charged for each request');
  outcome := public.operator_prepare_otp('9888888751','203.0.113.70');
  PERFORM public.operator_finish_otp((outcome#>>'{data,request_id}')::uuid,false,'provider_validation');
  PERFORM pg_temp.otp_assert((SELECT hourly_count=1 AND daily_count=1 FROM public.otp_rate_limits WHERE phone_number='919888888751')
    AND (SELECT NOT quota_refunded FROM public.otp_verifications WHERE id=(outcome#>>'{data,request_id}')::uuid)
    AND (SELECT count(*)=1 FROM warehouse_security.otp_send_log WHERE phone_number='919888888751'),
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
\echo 'OTP attempt budget, send lanes, daily cap and reserve, installer reset, warehouse cap split, refunds and access-request bounds passed.'
