-- Migration 83 (2026-10-15): save_grn refuses a NEW GRN for a deactivated business (admin and staff), an
-- active business still works, update_grn of an existing GRN of a deactivated business still works, and
-- update_customer(p_active=>true) clears deleted_at / deleted_by while p_active=>false leaves them alone.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.g83_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'grn deactivated 83: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.g83_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.g83_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.g83_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.g83_assert(l#>>'{data,action}'='login','login for '||phone||': '||l::text);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE true;
SELECT warehouse_security.bootstrap_first_admin('9555560301','GRN83 Admin') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919555560304','GRN83 Staff','staff',true,'approved');
SELECT pg_temp.g83_login('9555560301') AS admin_claims \gset
SELECT pg_temp.g83_login('9555560304') AS staff_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('GRN83 Active','9555560311') RETURNING id AS cust_a \gset
INSERT INTO public.customers(name,mobile) VALUES ('GRN83 Later deactivated','9555560312') RETURNING id AS cust_b \gset
INSERT INTO public.customers(name,mobile,active,deleted_at,deleted_by) SELECT 'GRN83 Soft deleted','9555560313',false,now(),id FROM public.user_profiles WHERE mobile='919555560301' RETURNING id AS cust_c \gset
INSERT INTO public.items(name,packaging) VALUES ('GRN83 Ginger','Bag') RETURNING id AS item_id \gset

-- an active business gets a GRN; B gets one while still active (the existing GRN to edit later)
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'G83A',p_date=>now(),p_customer_id=>:'cust_a'::uuid,p_customer_name=>'GRN83 Active',
  p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','GRN83 Ginger','packaging','Bag','qty',1,'weight',10,'rack','A1')),
  p_idempotency_key=>'g83-a') AS save_a \gset
SELECT public.save_grn(p_gr_no=>'G83B',p_date=>now(),p_customer_id=>:'cust_b'::uuid,p_customer_name=>'GRN83 Later deactivated',
  p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','GRN83 Ginger','packaging','Bag','qty',2,'weight',10,'rack','A2')),
  p_idempotency_key=>'g83-b') AS save_b \gset
RESET ROLE;
SELECT pg_temp.g83_assert((:'save_a'::jsonb->>'success')='true' AND (:'save_b'::jsonb->>'success')='true',
 'active businesses get a GRN: '||:'save_a'||:'save_b');
SELECT id AS grn_b FROM public.goodsreceived WHERE gr_no='G83B' \gset
UPDATE public.customers SET active=false WHERE id=:'cust_b'::uuid;

-- admin and staff: a new GRN for deactivated B is refused with the exact text, nothing is inserted
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.g83_call(format($q$SELECT public.save_grn(p_gr_no=>'G83X1',p_date=>now(),p_customer_id=>%L::uuid,p_customer_name=>'GRN83 Later deactivated',
  p_idempotency_key=>'g83-x1')$q$,:'cust_b')) AS refuse_admin \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.g83_call(format($q$SELECT public.save_grn(p_gr_no=>'G83X2',p_date=>now(),p_customer_id=>%L::uuid,p_customer_name=>'GRN83 Later deactivated',
  p_idempotency_key=>'g83-x2')$q$,:'cust_b')) AS refuse_staff \gset
RESET ROLE;
SELECT pg_temp.g83_assert(
 :'refuse_admin'::jsonb->>'raised'='This business is deactivated. Activate it in Customers to receive new goods.' AND :'refuse_admin'::jsonb->>'state'='P0001'
 AND :'refuse_staff'::jsonb->>'raised'='This business is deactivated. Activate it in Customers to receive new goods.' AND :'refuse_staff'::jsonb->>'state'='P0001'
 AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no IN ('G83X1','G83X2'))
 AND (SELECT count(*)=1 FROM public.goodsreceived WHERE customer_id=:'cust_b'::uuid),
 'a deactivated business gets no new GRN (admin, staff): '||:'refuse_admin'||:'refuse_staff');

-- update_grn of the existing GRN of the deactivated business (same customer) still works
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.g83_call(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_customer_id=>%L::uuid,p_note=>%L)',:'grn_b',:'cust_b','edited 83')) AS edit_b \gset
RESET ROLE;
SELECT pg_temp.g83_assert(:'edit_b'::jsonb->>'raised' IS NULL AND (:'edit_b'::jsonb->>'success')='true'
 AND (SELECT note='edited 83' AND customer_id=:'cust_b'::uuid FROM public.goodsreceived WHERE id=:'grn_b'::uuid),
 'editing an existing GRN of a deactivated business still works: '||:'edit_b');

-- update_customer(p_active=>true) on a soft-deleted business clears deleted_at / deleted_by
SELECT pg_temp.g83_assert((SELECT NOT active AND deleted_at IS NOT NULL AND deleted_by IS NOT NULL FROM public.customers WHERE id=:'cust_c'::uuid),'C starts inactive and deleted');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_customer(p_customer_id=>:'cust_c'::uuid,p_active=>true) AS act_c \gset
RESET ROLE;
SELECT pg_temp.g83_assert((:'act_c'::jsonb->>'success')='true'
 AND (SELECT active AND deleted_at IS NULL AND deleted_by IS NULL FROM public.customers WHERE id=:'cust_c'::uuid),
 'update_customer(p_active=>true) leaves active and not deleted: '||:'act_c');

-- update_customer(p_active=>false) leaves deleted_at alone: a deleted-but-active row keeps its mark; NULL changes neither
UPDATE public.customers SET active=true, deleted_at='2026-01-02 03:04:05+00' WHERE id=:'cust_a'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_customer(p_customer_id=>:'cust_a'::uuid,p_active=>false) AS deact_a \gset
SELECT public.update_customer(p_customer_id=>:'cust_a'::uuid,p_city=>'Surat') AS null_a \gset
RESET ROLE;
SELECT pg_temp.g83_assert((:'deact_a'::jsonb->>'success')='true' AND (:'null_a'::jsonb->>'success')='true'
 AND (SELECT NOT active AND deleted_at='2026-01-02 03:04:05+00' AND city='Surat' FROM public.customers WHERE id=:'cust_a'::uuid),
 'update_customer(p_active=>false) and NULL leave deleted_at untouched: '||:'deact_a'||:'null_a');
ROLLBACK;
