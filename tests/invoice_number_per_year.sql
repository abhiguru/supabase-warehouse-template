-- Migration 48, owner decision 2 of 2026-10-11: the suggested next invoice
-- number is per financial year. get_next_invoice_number(p_fin_year) returns the
-- highest number of that year's invoice rows plus 1, soft-deleted rows
-- included because the unique constraint still reserves their numbers; 1 for a
-- year without invoices; numbers below 1 do not count; the year defaults to the
-- financial year of today in India; and when the year's highest number is the
-- largest an invoice number can be, the answer is a WH409 refusal instead of
-- "integer out of range". Since migration 73 the largest is 999999
-- (INVOICE_NUMBER_MAX) and numbers above it do not count
-- (tests/invoice_number_ceiling.sql). Guard and grants are those of the function it
-- replaces. Fictional data; runs only in migrations.sh's disposable,
-- network-disabled database (session time zone UTC).
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.num_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'invoice number per year: %',label; END IF; END $$;
-- The text answer of a call, or what it raised.
CREATE FUNCTION pg_temp.num_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer text;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN jsonb_build_object('answer', answer);
END $$;
CREATE FUNCTION pg_temp.num_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.num_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.num_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT pg_temp.num_assert(current_setting('TimeZone')='UTC','the session time zone is UTC, so its date can differ from India''s');
SELECT warehouse_security.bootstrap_first_admin('9888888871','Year Number Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888872','Year Number Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888873','Year Number Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888874','Year Number Customer Reader','customer',true,'approved'),
 (gen_random_uuid(),'919888888875','Year Number Former Staff','staff',false,'disabled');
SELECT pg_temp.num_login('9888888871') AS admin_claims \gset
SELECT pg_temp.num_login('9888888872') AS supervisor_claims \gset
SELECT pg_temp.num_login('9888888873') AS staff_claims \gset
SELECT pg_temp.num_login('9888888874') AS customer_claims \gset
SELECT jsonb_build_object('role','authenticated','sub',auth_user_id) AS former_claims
 FROM public.user_profiles WHERE mobile='919888888875' \gset

-- Invoices, written by the database owner: only year, number and deleted_at
-- matter here. Years far from today so that no other row is in them.
--   2090  7 and 54 live, 60 deleted, 0 and -3 below the range   -> 61
--   2091  nothing                                               -> 1
--   2092  9, deleted                                            -> 10
--   2093  0 and -5 only                                         -> 1
--   2094  999999 live                                           -> refused
--   2095  3 live, 999999 deleted                                -> refused
--   2096  8 live, 2 deleted                                     -> 9
-- and 4242 in the financial year of today in India.
SELECT pg_temp.num_assert((SELECT count(*)=0 FROM public.invoice WHERE inv_fin_year BETWEEN 2090 AND 2096),'the fixture years are empty');
SELECT today, EXTRACT(YEAR FROM today)::integer - CASE WHEN EXTRACT(MONTH FROM today) >= 4 THEN 0 ELSE 1 END AS this_year
 FROM (SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date AS today) india \gset
SELECT pg_temp.num_assert((SELECT count(*)=0 FROM public.invoice WHERE inv_fin_year=:this_year AND inv_no>=4242),
 'no invoice of this financial year is numbered 4242 or above');
INSERT INTO public.invoice(inv_fin_year,inv_no,gr_id,gr_no,customer_id,customer_name,inv_date,labour,tax_amount,total,discount,deleted_at)
SELECT f.fin_year,f.number,gen_random_uuid(),'YEARNO',gen_random_uuid(),'Year Number Customer',now(),0,0,0,0,
       CASE WHEN f.deleted THEN now() END
FROM (VALUES (2090,7,false),(2090,54,false),(2090,60,true),(2090,0,false),(2090,-3,false),
             (2092,9,true),(2093,0,false),(2093,-5,false),
             (2094,999999,false),(2095,3,false),(2095,999999,true),
             (2096,8,false),(2096,2,true),
             (:this_year,4242,false)) AS f(fin_year,number,deleted);

-- One function, one optional argument, returning text; the old no-argument
-- signature is gone, so a call without an argument is not ambiguous.
SELECT pg_temp.num_assert((SELECT count(*)=1 AND bool_and(p.pronargs=1 AND p.pronargdefaults=1 AND p.proargnames=ARRAY['p_fin_year']
    AND p.proargtypes[0]='integer'::regtype AND p.prorettype='text'::regtype AND p.prosecdef AND p.provolatile='s')
  FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname='get_next_invoice_number'),
 'get_next_invoice_number(p_fin_year integer DEFAULT NULL) RETURNS text is the only signature');
SELECT pg_temp.num_assert(has_function_privilege('authenticated','public.get_next_invoice_number(integer)','EXECUTE')
 AND has_function_privilege('service_role','public.get_next_invoice_number(integer)','EXECUTE')
 AND NOT has_function_privilege('anon','public.get_next_invoice_number(integer)','EXECUTE'),
 'granted to signed-in sessions and the service role, not to anonymous callers');
SELECT pg_temp.num_assert(pg_get_functiondef('public.get_next_invoice_number(integer)'::regprocedure)
  ~ 'BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''get_next_invoice_number''',
 'the guard is the first statement');
-- get_next_invoice_number_with_year is left as it is: no app role can call it.
SELECT pg_temp.num_assert(NOT has_function_privilege('authenticated','public.get_next_invoice_number_with_year()','EXECUTE')
 AND NOT has_function_privilege('anon','public.get_next_invoice_number_with_year()','EXECUTE'),
 'the older with-year variant is not part of the API');

-- The answers, as staff (the role that creates most invoices).
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.num_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT pg_temp.num_assert(pg_temp.num_call(statement)->>'answer'=expected,
  label||': '||statement||' -> '||pg_temp.num_call(statement)::text||', expected '||expected)
FROM (VALUES
 ('highest number of the year plus 1, a soft-deleted invoice''s number included; zero and negative numbers ignored','SELECT public.get_next_invoice_number(2090)','61'),
 ('the argument by name, as the app sends it','SELECT public.get_next_invoice_number(p_fin_year => 2090)','61'),
 ('a year without invoices starts at 1','SELECT public.get_next_invoice_number(2091)','1'),
 ('a year whose only invoice is soft-deleted continues after its number','SELECT public.get_next_invoice_number(2092)','10'),
 ('a year with only numbers below 1 starts at 1','SELECT public.get_next_invoice_number(2093)','1'),
 ('a soft-deleted invoice below the highest number changes nothing','SELECT public.get_next_invoice_number(2096)','9'),
 ('no argument: the financial year of today in India','SELECT public.get_next_invoice_number()','4243'),
 ('NULL: the financial year of today in India','SELECT public.get_next_invoice_number(NULL)','4243'),
 ('this financial year by number','SELECT public.get_next_invoice_number('||:this_year||')','4243')
) AS c(label,statement,expected);
SELECT pg_temp.num_assert(public.get_next_invoice_number(2090) ~ '^[1-9][0-9]*$','the answer is plain digits');
-- The largest number: a refusal the app can show, not "integer out of range".
SELECT pg_temp.num_call('SELECT public.get_next_invoice_number(2094)') AS full_year \gset
SELECT pg_temp.num_assert(:'full_year'::jsonb->>'raised'='No invoice number is left in financial year 2094'
 AND :'full_year'::jsonb->>'state'='WH409','a full year is refused with WH409: '||:'full_year');
-- One full year does not affect another (before, the maximum was taken over
-- every invoice, so one such number broke the suggestion for all years).
SELECT pg_temp.num_assert(public.get_next_invoice_number(2090)='61' AND public.get_next_invoice_number()='4243',
 'other years still answer while 2094 is full');
-- A soft-deleted invoice holds the largest number: that year is full too,
-- because the number after it does not exist and its own cannot be reused.
SELECT pg_temp.num_assert(pg_temp.num_call('SELECT public.get_next_invoice_number(2095)')
 =jsonb_build_object('raised','No invoice number is left in financial year 2095','state','WH409'),
 'a year whose largest number belongs to a soft-deleted invoice is refused: '||pg_temp.num_call('SELECT public.get_next_invoice_number(2095)')::text);
RESET ROLE;

-- Why soft-deleted rows count: the unique constraint covers every row of the
-- year, deleted or not, so their numbers cannot be given again. The number the
-- function suggests can always be saved; the number of a soft-deleted invoice
-- cannot. (If the constraint ever becomes partial, the function's rule has to
-- follow it, and this assertion says so.)
SELECT pg_temp.num_assert((SELECT pg_get_constraintdef(oid)='UNIQUE (inv_fin_year, inv_no)' FROM pg_constraint
  WHERE conrelid='public.invoice'::regclass AND conname='unique_inv_no_per_year'),
 'unique_inv_no_per_year covers every invoice row of a year, soft-deleted ones included');
CREATE FUNCTION pg_temp.num_insert(fin_year integer, number integer) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    INSERT INTO public.invoice(inv_fin_year,inv_no,gr_id,gr_no,customer_id,customer_name,inv_date,labour,tax_amount,total,discount)
    VALUES (fin_year,number,gen_random_uuid(),'YEARNO',gen_random_uuid(),'Year Number Customer',now(),0,0,0,0);
  EXCEPTION WHEN unique_violation THEN RETURN 'taken: '||SQLERRM; END;
  RETURN 'saved';
END $$;
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
SELECT pg_temp.num_assert(pg_temp.num_insert(2090,60)='taken: duplicate key value violates unique constraint "unique_inv_no_per_year"'
 AND pg_temp.num_insert(2092,9)='taken: duplicate key value violates unique constraint "unique_inv_no_per_year"',
 'the number of a soft-deleted invoice cannot be used again: '||pg_temp.num_insert(2090,60));
SELECT pg_temp.num_assert(pg_temp.num_insert(f.fin_year,public.get_next_invoice_number(f.fin_year)::integer)='saved',
 'the suggested number of '||f.fin_year||' can be saved')
FROM (VALUES (2090),(2091),(2092),(2093),(2096)) AS f(fin_year);
SELECT pg_temp.num_assert(public.get_next_invoice_number(f.fin_year)::integer=f.then_next,
 'after that save the suggestion for '||f.fin_year||' is '||f.then_next||', found '||public.get_next_invoice_number(f.fin_year))
FROM (VALUES (2090,62),(2091,2),(2092,11),(2093,2),(2096,10)) AS f(fin_year,then_next);

-- Which year "today" is in. April to March, named by the year it starts in;
-- the day is the calendar date in India, so the year turns at 18:30 UTC on
-- 31 March (a date taken in UTC would turn it five and a half hours late).
SELECT pg_temp.num_assert(warehouse_security.financial_year('2026-03-31')=2025 AND warehouse_security.financial_year('2026-04-01')=2026
 AND warehouse_security.financial_year('2026-12-31')=2026 AND warehouse_security.financial_year('2027-01-15')=2026
 AND warehouse_security.financial_year('2027-03-31')=2026 AND warehouse_security.financial_year('2027-04-01')=2027,
 'the financial year runs from 1 April to 31 March');
SELECT pg_temp.num_assert(warehouse_security.financial_year(warehouse_security.business_date('2026-03-31T18:29:59Z'))=2025
 AND warehouse_security.financial_year(warehouse_security.business_date('2026-03-31T18:30:00Z'))=2026,
 'the year turns at midnight in India');
SELECT pg_temp.num_assert(pg_get_functiondef('public.get_next_invoice_number(integer)'::regprocedure)
  LIKE '%COALESCE(p_fin_year, warehouse_security.financial_year(warehouse_security.business_date(now())))%',
 'without a year the function uses that date');
SELECT pg_temp.num_assert(warehouse_security.financial_year(:'today'::date)=:this_year,'and it is the year this test worked out on its own');

-- Roles: unchanged. Administrators, supervisors and staff are answered; a
-- customer account and a deactivated profile are refused by the guard.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.num_assert(warehouse_security.active_role()='admin' AND public.get_next_invoice_number(2090)='62','the administrator is answered');
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SELECT pg_temp.num_assert(warehouse_security.active_role()='supervisor' AND public.get_next_invoice_number(2090)='62','the supervisor is answered');
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SELECT pg_temp.num_assert(warehouse_security.active_role()='customer','actual customer role');
SELECT pg_temp.num_assert(pg_temp.num_call(statement)=jsonb_build_object('raised','Staff access required','state','42501'),
 'a customer account is refused: '||statement||' -> '||pg_temp.num_call(statement)::text)
FROM (VALUES ('SELECT public.get_next_invoice_number()'),('SELECT public.get_next_invoice_number(2090)'),
  ('SELECT public.get_next_invoice_number(2094)')) AS s(statement);
SELECT set_config('request.jwt.claims',:'former_claims',true);
SELECT pg_temp.num_assert(pg_temp.num_call('SELECT public.get_next_invoice_number(2090)')=jsonb_build_object('raised','Active account required','state','42501'),
 'a deactivated profile is refused: '||pg_temp.num_call('SELECT public.get_next_invoice_number(2090)')::text);
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.num_assert(pg_temp.num_call('SELECT public.get_next_invoice_number(2090)')->>'state'='42501','no anonymous call');
RESET ROLE;
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
SET LOCAL ROLE service_role;
SELECT pg_temp.num_assert(public.get_next_invoice_number(2090)='62','the service role is answered');
RESET ROLE;
ROLLBACK;
\echo 'Next invoice number per financial year, India date, full-year refusal and role checks passed.'
