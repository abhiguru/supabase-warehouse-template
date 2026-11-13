-- WH-189 (migration 191): the dispatch range print (get_dispatch_range_for_print, behind print-dispatch-preprinted) leaves out a dispatch with
-- deleted_at set, and, since migration 191, an imported one. Live I0001 and I0005, deleted I0002 and I0004, imported I0003. A range of only
-- deleted dispatches, and one of only an imported dispatch, give no row; a live dispatch is returned. Fictional data; runs only in
-- migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.dp_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'dispatch range print: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.dp_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.dp_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.dp_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
CREATE FUNCTION pg_temp.dp_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
-- The dispatch numbers the range returns, in order, comma separated ('' for none).
CREATE FUNCTION pg_temp.dp_range(p_from text, p_to text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer jsonb; v_numbers text;
BEGIN
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  EXECUTE 'SET LOCAL ROLE service_role';
  answer := public.get_dispatch_range_for_print(p_from, p_to, 100);
  EXECUTE 'RESET ROLE';
  SELECT COALESCE(string_agg(DISTINCT v #>> '{}', ',' ORDER BY v #>> '{}'), '') INTO v_numbers
    FROM jsonb_path_query(answer, 'strict $.**.disp_no') AS t(v) WHERE jsonb_typeof(v) = 'string';
  RETURN v_numbers;
END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888951','Dispatch Range Administrator') AS boot \gset
SELECT pg_temp.dp_login('9888888951') AS admin_claims \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888888951' \gset
SELECT warehouse_security.business_date(now()) AS today \gset
INSERT INTO public.customers(name,mobile) VALUES ('Dispatch Range Customer','9888888952') RETURNING id AS customer \gset
INSERT INTO public.items(name,packaging) VALUES ('Dispatch Range Potato','Bag') RETURNING id AS item_id \gset
SELECT pg_temp.dp_as(:'admin_claims'::jsonb, format($q$SELECT public.save_grn(p_gr_no=>'A0001',p_date=>now(),p_customer_id=>%L::uuid,p_customer_name=>'x',p_pricing_mode=>'MONTHLY',
  p_idempotency_key=>'dp-g1',p_items=>jsonb_build_array(jsonb_build_object('item_id',%L,'item_name','Dispatch Range Potato','packaging','Bag','qty',100,'weight',50,'rack','R1')))$q$,
  :'customer', :'item_id')) AS g1 \gset
SELECT pg_temp.dp_assert(:'g1'::jsonb->>'success' = 'true', 'the GRN: ' || :'g1');
SELECT t.id AS lot FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = 'A0001' \gset
SELECT string_agg(n || ':' || (pg_temp.dp_as(:'admin_claims'::jsonb, format($q$SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no',%L,'disp_date',now(),
  'customer_id',%L,'customer_name','x','supervisor_id',%L,'supervisor_name','x'),ARRAY[jsonb_build_object('gr_trl_id',%L,'disp_qty',2)],false,0,%L)$q$,
  n, :'customer', :'admin_profile', :'lot', 'dp-' || n))->>'success'), ',') AS saved
  FROM unnest(ARRAY['I0001','I0002','I0004','I0005']) n \gset
SELECT pg_temp.dp_assert((SELECT count(*) FROM public.dispatch WHERE disp_no IN ('I0001','I0002','I0004','I0005')) = 4, 'four app dispatches: ' || :'saved');
-- No RPC sets dispatch.deleted_at the way the range print reads it, so the state is made directly (as the GRN range test does).
UPDATE public.dispatch SET deleted_at = now() WHERE disp_no IN ('I0002', 'I0004');
-- One imported dispatch, I0003, through the import itself.
INSERT INTO warehouse_import.stage_grns(line,gr_no,gr_date,customer,pricing) VALUES (2,'A0003',:'today'::date - 300,'Dispatch Range Customer','MONTHLY');
INSERT INTO warehouse_import.stage_grn_lines(line,gr_no,gr_date,line_no,item,packaging,qty,weight,stock_now) VALUES (2,'A0003',:'today'::date - 300,1,'Dispatch Range Potato','Bag',10,50,5);
INSERT INTO warehouse_import.stage_dispatches(line,disp_no,disp_date,customer) VALUES (2,'I0003',:'today'::date - 250,'Dispatch Range Customer');
INSERT INTO warehouse_import.stage_dispatch_lines(line,disp_no,disp_date,gr_no,gr_date,grn_line,qty) VALUES (2,'I0003',:'today'::date - 250,'A0003',:'today'::date - 300,1,5);
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true) AS c \gset
SET LOCAL ROLE service_role;
SELECT public.import_history('{}'::jsonb, true) AS imported \gset
RESET ROLE;
SELECT pg_temp.dp_assert(:'imported'::jsonb->>'success' = 'true', 'the import of I0003: ' || :'imported');
SELECT pg_temp.dp_assert((SELECT import_batch_id IS NOT NULL AND deleted_at IS NULL FROM public.dispatch WHERE disp_no = 'I0003'), 'I0003 is imported and live');

SELECT pg_temp.dp_assert(pg_temp.dp_range('I0001', 'I0005') = 'I0001,I0005', 'range I0001-I0005 gives the live app dispatches only: ' || pg_temp.dp_range('I0001', 'I0005'));
SELECT pg_temp.dp_assert(pg_temp.dp_range('I0002', 'I0002') = '' AND pg_temp.dp_range('I0004', 'I0004') = '', 'each deleted dispatch alone gives no row');
SELECT pg_temp.dp_assert(pg_temp.dp_range('I0002', 'I0004') = '', 'a range of deleted and imported dispatches gives no row');
SELECT pg_temp.dp_assert(pg_temp.dp_range('I0003', 'I0003') = '', 'an imported dispatch alone gives no row');
SELECT pg_temp.dp_assert(pg_temp.dp_range('I0001', 'I0001') = 'I0001' AND pg_temp.dp_range('I0005', 'I0005') = 'I0005', 'a live dispatch alone is printed');
SELECT pg_temp.dp_assert(pg_temp.dp_range('I0001', 'I0002') = 'I0001', 'a live and a deleted dispatch give the live one');
SELECT pg_temp.dp_assert(NOT has_function_privilege('anon', 'public.get_dispatch_range_for_print(text,text,integer)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.get_dispatch_range_for_print(text,text,integer)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.get_dispatch_range_for_print(text,text,integer)', 'EXECUTE'), 'the range read stays with the service role');
ROLLBACK;
\echo 'Dispatch range print: deleted and imported dispatches are left out, a range with nothing to print gives no row.'
