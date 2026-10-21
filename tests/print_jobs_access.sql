-- Migration 123, section 8: the print "View jobs" sheet (get_print_jobs, cancel_print_job) is open to administrators, supervisors and
-- staff with their own session; customers and anon are refused. A job that is finished cannot be cancelled and an unknown id is
-- "not found". Fictional data; runs in migrations.sh's disposable, network-disabled database and rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.pj_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'print jobs access: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.pj_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.pj_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.pj_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.pj_assert(l#>>'{data,action}'='login','login for '||phone);
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
SELECT warehouse_security.bootstrap_first_admin('9888888951','Print Jobs Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888952','Print Jobs Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888953','Print Jobs Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888954','Print Jobs Customer','customer',true,'approved');
SELECT auth_user_id AS staff_user FROM public.user_profiles WHERE mobile='919888888953' \gset
SELECT auth_user_id AS customer_user FROM public.user_profiles WHERE mobile='919888888954' \gset
SELECT pg_temp.pj_login('9888888951') AS admin_claims \gset
SELECT pg_temp.pj_login('9888888952') AS supervisor_claims \gset
SELECT pg_temp.pj_login('9888888953') AS staff_claims \gset
SELECT pg_temp.pj_login('9888888954') AS customer_claims \gset

-- Grants: signed-in sessions and the service role, never PUBLIC or anon.
SELECT pg_temp.pj_assert(has_function_privilege('authenticated','public.get_print_jobs(integer,text,text)','EXECUTE')
  AND has_function_privilege('authenticated','public.cancel_print_job(uuid)','EXECUTE')
  AND has_function_privilege('service_role','public.get_print_jobs(integer,text,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.get_print_jobs(integer,text,text)','EXECUTE')
  AND NOT has_function_privilege('anon','public.cancel_print_job(uuid)','EXECUTE'),'grants');
-- Both bodies call the guard first.
SELECT pg_temp.pj_assert((SELECT bool_and(prosrc ~ 'authorize_rpc\(''(get_print_jobs|cancel_print_job)''')
  FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('get_print_jobs','cancel_print_job')),'bodies call authorize_rpc');
-- The stale name left the guard.
SELECT pg_temp.pj_assert((SELECT position('get_cart_dispatches' IN prosrc)=0 AND position('''get_print_jobs''' IN prosrc)>0
  FROM pg_proc WHERE oid='warehouse_security.authorize_rpc(text,jsonb)'::regprocedure),'authorize_rpc names');

-- Five jobs, written as the service would: three queued (admin's, staff's, customer's), one completed, one failed.
INSERT INTO public.print_jobs(id,job_type,document_range_start,document_range_end,user_id,user_name,status) VALUES
 ('00000000-0000-4000-8000-0000000000a1','GRN','PJ0001','PJ0002',:'admin_user','Print Jobs Administrator','queued'),
 ('00000000-0000-4000-8000-0000000000a2','GRN','PJ0003','PJ0004',:'staff_user','Print Jobs Staff','queued'),
 ('00000000-0000-4000-8000-0000000000a3','Invoice','PJ0005','PJ0006',:'customer_user','Print Jobs Customer','queued'),
 ('00000000-0000-4000-8000-0000000000a4','GRN','PJ0007','PJ0008',:'admin_user','Print Jobs Administrator','completed'),
 ('00000000-0000-4000-8000-0000000000a5','GRN','PJ0009','PJ0010',:'admin_user','Print Jobs Administrator','failed');

-- Administrator, supervisor and staff each list all five jobs, newest first by submitted_at, and filters work.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.pj_call('SELECT public.get_print_jobs()') AS answer \gset
SELECT pg_temp.pj_assert(:'answer'::jsonb->>'success'='true' AND jsonb_array_length(:'answer'::jsonb->'data')=5,'admin lists 5 jobs: '||:'answer');
SELECT pg_temp.pj_call('SELECT public.get_print_jobs(50,''Invoice'',NULL)') AS answer \gset
SELECT pg_temp.pj_assert(jsonb_array_length(:'answer'::jsonb->'data')=1 AND :'answer'::jsonb#>>'{data,0,document_range_start}'='PJ0005','job type filter');
SELECT pg_temp.pj_call('SELECT public.get_print_jobs(50,NULL,''queued'')') AS answer \gset
SELECT pg_temp.pj_assert(jsonb_array_length(:'answer'::jsonb->'data')=3,'status filter: 3 queued');
-- p_limit limits the jobs, not the answer: 2 of the 5 come back, the newest by submitted_at; 0 and a negative number give 1; null gives all 5.
RESET ROLE;
UPDATE public.print_jobs SET submitted_at = timestamptz '2026-01-01T00:00:00Z' + (substr(document_range_start,3)::int) * interval '1 hour';
SET LOCAL ROLE authenticated;
SELECT pg_temp.pj_call('SELECT public.get_print_jobs(2)') AS answer \gset
SELECT pg_temp.pj_assert(jsonb_array_length(:'answer'::jsonb->'data')=2 AND :'answer'::jsonb#>>'{data,0,document_range_start}'='PJ0009'
  AND :'answer'::jsonb#>>'{data,1,document_range_start}'='PJ0007','limit 2 returns the two newest (PJ0009, PJ0007): '||:'answer');
SELECT pg_temp.pj_call('SELECT public.get_print_jobs(0)') AS answer \gset
SELECT pg_temp.pj_assert(jsonb_array_length(:'answer'::jsonb->'data')=1,'limit 0 gives 1 job');
SELECT pg_temp.pj_call('SELECT public.get_print_jobs(1000)') AS answer \gset
SELECT pg_temp.pj_assert(jsonb_array_length(:'answer'::jsonb->'data')=5,'a large limit gives all 5 (cap 200)');
SELECT pg_temp.pj_assert(pg_get_functiondef('public.get_print_jobs(integer,text,text)'::regprocedure) ~ 'LEAST\(GREATEST\(COALESCE\(p_limit, 50\), 1\), 200\)','the limit is capped at 200');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.pj_call('SELECT public.get_print_jobs()') AS answer \gset
SELECT pg_temp.pj_assert(:'answer'::jsonb->>'success'='true' AND jsonb_array_length(:'answer'::jsonb->'data')=5,'supervisor lists 5 jobs: '||:'answer');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.pj_call('SELECT public.get_print_jobs()') AS answer \gset
SELECT pg_temp.pj_assert(:'answer'::jsonb->>'success'='true' AND jsonb_array_length(:'answer'::jsonb->'data')=5,'staff lists 5 jobs: '||:'answer');

-- Cancel: staff cancel a queued job of another user; the job becomes cancelled.
SELECT pg_temp.pj_call('SELECT public.cancel_print_job(''00000000-0000-4000-8000-0000000000a1'')') AS answer \gset
SELECT pg_temp.pj_assert(:'answer'::jsonb->>'success'='true','staff cancel a queued job: '||:'answer');
-- A finished job, a cancelled job and an unknown id are answered, not changed.
SELECT pg_temp.pj_call('SELECT public.cancel_print_job(''00000000-0000-4000-8000-0000000000a4'')') AS answer \gset
SELECT pg_temp.pj_assert(:'answer'::jsonb->>'success'='false' AND :'answer'::jsonb#>>'{error,code}'='INVALID_STATUS','completed job refused: '||:'answer');
SELECT pg_temp.pj_call('SELECT public.cancel_print_job(''00000000-0000-4000-8000-0000000000a1'')') AS answer \gset
SELECT pg_temp.pj_assert(:'answer'::jsonb#>>'{error,code}'='INVALID_STATUS','cancelled job cannot be cancelled twice: '||:'answer');
SELECT pg_temp.pj_call('SELECT public.cancel_print_job(gen_random_uuid())') AS answer \gset
SELECT pg_temp.pj_assert(:'answer'::jsonb->>'success'='false' AND :'answer'::jsonb#>>'{error,code}' LIKE '%NOT_FOUND%','unknown job not found: '||:'answer');
RESET ROLE;
SELECT pg_temp.pj_assert((SELECT status FROM public.print_jobs WHERE id='00000000-0000-4000-8000-0000000000a1')='cancelled'
  AND (SELECT status FROM public.print_jobs WHERE id='00000000-0000-4000-8000-0000000000a4')='completed','job states after the staff calls');
-- Supervisor and administrator cancel too.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.pj_assert(public.cancel_print_job('00000000-0000-4000-8000-0000000000a2')->>'success'='true','supervisor cancels');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.pj_assert(public.cancel_print_job('00000000-0000-4000-8000-0000000000a3')->>'success'='true','admin cancels');
RESET ROLE;
SELECT pg_temp.pj_assert((SELECT count(*)=3 FROM public.print_jobs WHERE status='cancelled'),'three jobs cancelled');

-- A customer, also the owner of job a3's user, is refused both calls; nothing changes.
UPDATE public.print_jobs SET status='queued' WHERE id='00000000-0000-4000-8000-0000000000a3';
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.pj_call('SELECT public.get_print_jobs()') AS answer \gset
SELECT pg_temp.pj_assert(:'answer'::jsonb->>'state'='42501' AND :'answer'::jsonb->>'raised' LIKE 'Staff access required%','customer refused get_print_jobs: '||:'answer');
SELECT pg_temp.pj_call('SELECT public.cancel_print_job(''00000000-0000-4000-8000-0000000000a3'')') AS answer \gset
SELECT pg_temp.pj_assert(:'answer'::jsonb->>'state'='42501' AND :'answer'::jsonb->>'raised' LIKE 'Staff access required%','customer refused cancel_print_job: '||:'answer');
RESET ROLE;
SELECT pg_temp.pj_assert((SELECT status FROM public.print_jobs WHERE id='00000000-0000-4000-8000-0000000000a3')='queued','the customer changed nothing');

-- Anon has no EXECUTE.
SELECT set_config('request.jwt.claims','{"role":"anon"}',true);
SET LOCAL ROLE anon;
SELECT pg_temp.pj_call('SELECT public.get_print_jobs()') AS answer \gset
SELECT pg_temp.pj_assert(:'answer'::jsonb->>'state'='42501','anon refused get_print_jobs: '||:'answer');
SELECT pg_temp.pj_call('SELECT public.cancel_print_job(gen_random_uuid())') AS answer \gset
SELECT pg_temp.pj_assert(:'answer'::jsonb->>'state'='42501','anon refused cancel_print_job: '||:'answer');
RESET ROLE;
\echo 'Print jobs access: staff, supervisor and administrator list and cancel; customer and anon refused.'
ROLLBACK;
