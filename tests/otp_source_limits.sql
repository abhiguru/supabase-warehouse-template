-- Migration 126: the per-source OTP limits are auth_config keys (owner decision of 2026-10-25, review item 20).
-- otp_source_hourly_sends (default 30) is how many SMS requests one address may make in an hour over all phones,
-- otp_source_hourly_failures (default 20) how many failed verifications, and an address in the optional otp_trusted_sources list
-- (addresses and CIDR ranges, for the facility's Wi-Fi) gets otp_trusted_source_hourly_sends (default 120) instead. Before, 30 and 20
-- were literals in operator_prepare_otp and operator_verify_otp. Fictional data; addresses are documentation ranges; runs only in
-- migrations.sh's disposable, network-disabled database; every fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.sl_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'source limits: %',label; END IF; END $$;
CREATE TEMP SEQUENCE sl_phone;
-- n requests from one address, each for the next known phone (so no per-phone limit or cooldown is involved); returns how many were accepted.
CREATE FUNCTION pg_temp.sl_burst(source inet, n integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE accepted integer := 0; i integer; challenge jsonb;
BEGIN
  FOR i IN 1..n LOOP
    challenge := public.operator_prepare_otp('98887'||lpad(nextval('sl_phone')::text,5,'0'),source);
    IF challenge->>'success'='true' THEN
      accepted := accepted+1;
      PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
    ELSIF challenge->>'code' <> 'rate_limited' THEN
      RAISE EXCEPTION 'source limits: a request was refused for another reason: %',challenge;
    END IF;
  END LOOP;
  RETURN accepted;
END $$;
-- The outcome of n wrong verifications from one address, as the string of their codes.
CREATE FUNCTION pg_temp.sl_wrong(source inet, n integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE codes text[] := '{}'; i integer;
BEGIN
  FOR i IN 1..n LOOP
    codes := codes || (public.operator_verify_otp('9888600001','123456',NULL,NULL,source)->>'code');
  END LOOP;
  RETURN array_to_string(codes,',');
END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false'),
 ('otp_global_hourly_cap','1000'),('otp_unknown_hourly_cap','60'),('enrollment_daily_cap','30'),
 ('otp_phone_daily_cap','30'),('otp_trusted_daily_reserve','10')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE warehouse_security.operator_otp_global_limit SET hourly_count=0,unknown_count=0,window_started=now() WHERE id;
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status)
 SELECT gen_random_uuid(),'9198887'||lpad(n::text,5,'0'),'Source Known '||n,'customer',true,'approved' FROM generate_series(1,300) AS n;
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status)
 VALUES (gen_random_uuid(),'919888600001','Source Failures','customer',true,'approved');

-- 0. The defaults are seeded; the trusted list is not.
SELECT pg_temp.sl_assert((SELECT value FROM warehouse_security.auth_config WHERE key='otp_source_hourly_sends')='30'
  AND (SELECT value FROM warehouse_security.auth_config WHERE key='otp_source_hourly_failures')='20'
  AND (SELECT value FROM warehouse_security.auth_config WHERE key='otp_trusted_source_hourly_sends')='120'
  AND NOT EXISTS (SELECT 1 FROM warehouse_security.auth_config WHERE key='otp_trusted_sources'),
  'the keys hold 30, 20 and 120 and there is no trusted list until the operator makes one');
SELECT pg_temp.sl_assert(NOT has_function_privilege('anon','warehouse_security.otp_source_send_cap(inet)','EXECUTE')
  AND NOT has_function_privilege('authenticated','warehouse_security.otp_source_send_cap(inet)','EXECUTE')
  AND NOT has_function_privilege('service_role','warehouse_security.otp_source_send_cap(inet)','EXECUTE')
  AND NOT has_function_privilege('authenticated','warehouse_security.otp_source_failure_cap()','EXECUTE')
  AND NOT has_function_privilege('authenticated','warehouse_security.address_in_list(inet,text)','EXECUTE'),
  'the three helpers are for the database functions only');

-- 1. The helper functions, with the values the operator might type.
SELECT pg_temp.sl_assert(warehouse_security.otp_source_send_cap(NULL)=30 AND warehouse_security.otp_source_send_cap('203.0.113.1')=30
  AND warehouse_security.otp_source_failure_cap()=20,'the defaults are 30 and 20');
UPDATE warehouse_security.auth_config SET value='45' WHERE key='otp_source_hourly_sends';
UPDATE warehouse_security.auth_config SET value='7' WHERE key='otp_source_hourly_failures';
SELECT pg_temp.sl_assert(warehouse_security.otp_source_send_cap('203.0.113.1')=45 AND warehouse_security.otp_source_failure_cap()=7,'the keys are read');
UPDATE warehouse_security.auth_config SET value='abc' WHERE key='otp_source_hourly_sends';
UPDATE warehouse_security.auth_config SET value='-5' WHERE key='otp_source_hourly_failures';
SELECT pg_temp.sl_assert(warehouse_security.otp_source_send_cap('203.0.113.1')=30 AND warehouse_security.otp_source_failure_cap()=20,
  'a value that is not a whole number means the default');
UPDATE warehouse_security.auth_config SET value='0' WHERE key='otp_source_hourly_sends';
UPDATE warehouse_security.auth_config SET value='0' WHERE key='otp_source_hourly_failures';
SELECT pg_temp.sl_assert(warehouse_security.otp_source_send_cap('203.0.113.1')=1 AND warehouse_security.otp_source_failure_cap()=1,
  '0 is raised to 1 (the no-send switch is otp_global_hourly_cap)');
DELETE FROM warehouse_security.auth_config WHERE key IN ('otp_source_hourly_sends','otp_source_hourly_failures');
SELECT pg_temp.sl_assert(warehouse_security.otp_source_send_cap('203.0.113.1')=30 AND warehouse_security.otp_source_failure_cap()=20,
  'with the keys removed the defaults apply');
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('otp_source_hourly_sends','30'),('otp_source_hourly_failures','20');
SELECT pg_temp.sl_assert(warehouse_security.address_in_list('203.0.113.5','203.0.113.0/28, 198.51.100.7')
  AND warehouse_security.address_in_list('198.51.100.7','203.0.113.0/28, 198.51.100.7')
  AND NOT warehouse_security.address_in_list('203.0.113.17','203.0.113.0/28, 198.51.100.7')
  AND NOT warehouse_security.address_in_list('198.51.100.8','203.0.113.0/28, 198.51.100.7')
  AND warehouse_security.address_in_list('2001:db8::1','203.0.113.0/28,2001:db8::/32')
  AND NOT warehouse_security.address_in_list('203.0.113.5','2001:db8::/32')
  AND warehouse_security.address_in_list('203.0.113.5',E' not-an-address ,, 999.1.1.1 ,\n203.0.113.5')
  AND NOT warehouse_security.address_in_list(NULL,'203.0.113.5') AND NOT warehouse_security.address_in_list('203.0.113.5',NULL)
  AND NOT warehouse_security.address_in_list('203.0.113.5','') AND NOT warehouse_security.address_in_list('203.0.113.5','not-an-address'),
  'addresses and ranges match, IPv4 and IPv6 stay apart, blanks and entries that are no address are ignored');

-- 2. The default: 30 requests an hour from one address, the 31st is refused.
SELECT pg_temp.sl_assert(pg_temp.sl_burst('198.51.100.200',30)=30,'30 requests from one address are accepted');
SELECT pg_temp.sl_assert(pg_temp.sl_burst('198.51.100.200',1)=0,'the 31st request from that address is refused');
SELECT pg_temp.sl_assert(pg_temp.sl_burst('198.51.100.201',1)=1,'another address is not affected');

-- 3. The key decides: a limit of 3.
UPDATE warehouse_security.auth_config SET value='3' WHERE key='otp_source_hourly_sends';
SELECT pg_temp.sl_assert(pg_temp.sl_burst('198.51.100.202',5)=3,'with otp_source_hourly_sends 3 an address gets 3 requests of 5 (the old literal 30 would accept all 5)');
UPDATE warehouse_security.auth_config SET value='6' WHERE key='otp_source_hourly_sends';
SELECT pg_temp.sl_assert(pg_temp.sl_burst('198.51.100.202',5)=3,'raising the key to 6 lets the same address make 3 more (the hour has not passed: 3 + 3 = 6)');

-- 4. Trusted addresses: a list of addresses and ranges, a higher limit; the larger of the two limits is used.
UPDATE warehouse_security.auth_config SET value='3' WHERE key='otp_source_hourly_sends';
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('otp_trusted_sources','203.0.113.0/28, 198.51.100.250 ,not-an-address, 2001:db8::/32');
UPDATE warehouse_security.auth_config SET value='5' WHERE key='otp_trusted_source_hourly_sends';
SELECT pg_temp.sl_assert(warehouse_security.otp_source_send_cap('203.0.113.5')=5 AND warehouse_security.otp_source_send_cap('198.51.100.250')=5
  AND warehouse_security.otp_source_send_cap('2001:db8::1')=5 AND warehouse_security.otp_source_send_cap('203.0.113.17')=3
  AND warehouse_security.otp_source_send_cap(NULL)=3,'listed addresses get 5, others 3');
SELECT pg_temp.sl_assert(pg_temp.sl_burst('203.0.113.5',8)=5,'an address inside a listed range makes 5 requests (not 3)');
SELECT pg_temp.sl_assert(pg_temp.sl_burst('198.51.100.250',8)=5,'a listed single address makes 5 requests');
SELECT pg_temp.sl_assert(pg_temp.sl_burst('2001:db8::1',8)=5,'a listed IPv6 range works too');
SELECT pg_temp.sl_assert(pg_temp.sl_burst('203.0.113.17',8)=3,'an address next to the range is limited to 3');
UPDATE warehouse_security.auth_config SET value='2' WHERE key='otp_trusted_source_hourly_sends';
SELECT pg_temp.sl_assert(warehouse_security.otp_source_send_cap('203.0.113.5')=3,'a trusted limit below the ordinary one does not lower it');
DELETE FROM warehouse_security.auth_config WHERE key='otp_trusted_source_hourly_sends';
SELECT pg_temp.sl_assert(warehouse_security.otp_source_send_cap('203.0.113.5')=120 AND warehouse_security.otp_source_send_cap('203.0.113.17')=3,
  'without the key a listed address gets 120');
SELECT pg_temp.sl_assert(pg_temp.sl_burst('203.0.113.6',20)=20,'a listed address makes far more than 30 requests when the ordinary limit is lower');
DELETE FROM warehouse_security.auth_config WHERE key='otp_trusted_sources';
SELECT pg_temp.sl_assert(warehouse_security.otp_source_send_cap('203.0.113.5')=3,'without the list nobody is trusted');
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('otp_trusted_sources','');
SELECT pg_temp.sl_assert(warehouse_security.otp_source_send_cap('203.0.113.5')=3,'an empty list trusts nobody');
UPDATE warehouse_security.auth_config SET value='30' WHERE key='otp_source_hourly_sends';

-- 5. Failed verifications: the key decides how many an address may make an hour.
UPDATE warehouse_security.auth_config SET value='3' WHERE key='otp_source_hourly_failures';
SELECT pg_temp.sl_assert(pg_temp.sl_wrong('198.51.100.210',5)='invalid_otp,invalid_otp,invalid_otp,rate_limited,rate_limited',
  'with otp_source_hourly_failures 3 the fourth wrong verification from an address is refused as rate_limited (the old literal 20 would still answer invalid_otp)');
SELECT pg_temp.sl_assert(pg_temp.sl_wrong('198.51.100.211',2)='invalid_otp,invalid_otp','another address has its own count');
UPDATE warehouse_security.auth_config SET value='20' WHERE key='otp_source_hourly_failures';
SELECT pg_temp.sl_assert(pg_temp.sl_wrong('198.51.100.210',1)='invalid_otp','raising the limit lets the address try again at once (3 counted of 20)');
-- The default of 20.
DELETE FROM warehouse_security.auth_config WHERE key='otp_source_hourly_failures';
SELECT pg_temp.sl_assert(pg_temp.sl_wrong('198.51.100.212',21)=repeat('invalid_otp,',20)||'rate_limited','without the key the default of 20 applies');
ROLLBACK;
\echo 'Per-source OTP limits: auth_config keys and defaults, clamps, the trusted address list and its higher limit, and the failure limit passed.'
