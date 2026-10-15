-- Migration 84 (2026-10-15): update_grn refuses to MOVE a GRN onto a deactivated business (admin and staff),
-- keeps 'Business is not active' for a deleted one, still allows editing a GRN of a deactivated business
-- without changing it, still allows a move onto an active business, and works again after reactivation.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.g84_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'grn move deactivated 84: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.g84_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.g84_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.g84_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.g84_assert(l#>>'{data,action}'='login','login for '||phone||': '||l::text);
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
SELECT warehouse_security.bootstrap_first_admin('9555560401','GRN84 Admin') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919555560404','GRN84 Staff','staff',true,'approved'),
 (gen_random_uuid(),'919555560405','GRN84 Supervisor','supervisor',true,'approved');
SELECT pg_temp.g84_login('9555560401') AS admin_claims \gset
SELECT pg_temp.g84_login('9555560404') AS staff_claims \gset
SELECT pg_temp.g84_login('9555560405') AS supervisor_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('GRN84 Active','9555560411') RETURNING id AS cust_a \gset
INSERT INTO public.customers(name,mobile) VALUES ('GRN84 Second active','9555560412') RETURNING id AS cust_b \gset
INSERT INTO public.customers(name,mobile) VALUES ('GRN84 Later deactivated','9555560413') RETURNING id AS cust_d \gset
INSERT INTO public.customers(name,mobile,active,deleted_at,deleted_by) SELECT 'GRN84 Soft deleted','9555560414',false,now(),id FROM public.user_profiles WHERE mobile='919555560401' RETURNING id AS cust_x \gset
INSERT INTO public.items(name,packaging) VALUES ('GRN84 Ginger','Bag') RETURNING id AS item_id \gset

-- GRN1 and GRN2 belong to active A; GRN3 belongs to D (deactivated afterwards)
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'G84A1',p_date=>now(),p_customer_id=>:'cust_a'::uuid,p_customer_name=>'GRN84 Active',
  p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','GRN84 Ginger','packaging','Bag','qty',1,'weight',10,'rack','A1')),
  p_idempotency_key=>'g84-a1') AS save_1 \gset
SELECT public.save_grn(p_gr_no=>'G84A2',p_date=>now(),p_customer_id=>:'cust_a'::uuid,p_customer_name=>'GRN84 Active',
  p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','GRN84 Ginger','packaging','Bag','qty',1,'weight',10,'rack','A2')),
  p_idempotency_key=>'g84-a2') AS save_2 \gset
SELECT public.save_grn(p_gr_no=>'G84D1',p_date=>now(),p_customer_id=>:'cust_d'::uuid,p_customer_name=>'GRN84 Later deactivated',
  p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','GRN84 Ginger','packaging','Bag','qty',2,'weight',10,'rack','A3')),
  p_idempotency_key=>'g84-d1') AS save_3 \gset
RESET ROLE;
SELECT pg_temp.g84_assert((:'save_1'::jsonb->>'success')='true' AND (:'save_2'::jsonb->>'success')='true' AND (:'save_3'::jsonb->>'success')='true',
 'GRNs saved: '||:'save_1'||:'save_2'||:'save_3');
SELECT id AS grn_1 FROM public.goodsreceived WHERE gr_no='G84A1' \gset
SELECT id AS grn_2 FROM public.goodsreceived WHERE gr_no='G84A2' \gset
SELECT id AS grn_3 FROM public.goodsreceived WHERE gr_no='G84D1' \gset
UPDATE public.customers SET active=false WHERE id=:'cust_d'::uuid;

-- 1. admin and staff: moving a GRN of active A onto deactivated D is refused with the exact text; customer unchanged
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.g84_call(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_customer_id=>%L::uuid)',:'grn_1',:'cust_d')) AS refuse_admin \gset
RESET ROLE;
SELECT customer_id=:'cust_a'::uuid AS kept_admin FROM public.goodsreceived WHERE id=:'grn_1'::uuid \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.g84_call(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_customer_id=>%L::uuid)',:'grn_1',:'cust_d')) AS refuse_staff \gset
RESET ROLE;
SELECT customer_id=:'cust_a'::uuid AS kept_staff FROM public.goodsreceived WHERE id=:'grn_1'::uuid \gset
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.g84_call(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_customer_id=>%L::uuid)',:'grn_1',:'cust_d')) AS refuse_supervisor \gset
RESET ROLE;
SELECT customer_id=:'cust_a'::uuid AS kept_supervisor FROM public.goodsreceived WHERE id=:'grn_1'::uuid \gset
SELECT pg_temp.g84_assert(
 :'refuse_supervisor'::jsonb->>'raised'='This business is deactivated. Activate it in Customers to receive new goods.' AND :'refuse_supervisor'::jsonb->>'state'='P0001'
 AND :'kept_supervisor'::boolean,
 'a move onto a deactivated business is refused, GRN unchanged (supervisor): '||:'refuse_supervisor');
SELECT pg_temp.g84_assert(
 :'refuse_admin'::jsonb->>'raised'='This business is deactivated. Activate it in Customers to receive new goods.' AND :'refuse_admin'::jsonb->>'state'='P0001'
 AND :'refuse_staff'::jsonb->>'raised'='This business is deactivated. Activate it in Customers to receive new goods.' AND :'refuse_staff'::jsonb->>'state'='P0001'
 AND :'kept_admin'::boolean AND :'kept_staff'::boolean,
 'a move onto a deactivated business is refused, GRN unchanged (admin, staff): '||:'refuse_admin'||:'refuse_staff');

-- 2. editing the GRN that already belongs to deactivated D still works
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.g84_call(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_customer_id=>%L::uuid,p_note=>%L,p_registration=>%L)',:'grn_3',:'cust_d','edited 84','GJ84REG')) AS edit_d \gset
RESET ROLE;
SELECT pg_temp.g84_assert(:'edit_d'::jsonb->>'raised' IS NULL AND (:'edit_d'::jsonb->>'success')='true'
 AND (SELECT note='edited 84' AND registration='GJ84REG' AND customer_id=:'cust_d'::uuid FROM public.goodsreceived WHERE id=:'grn_3'::uuid),
 'editing a GRN of a deactivated business still works: '||:'edit_d');

-- 2b. the call shape FAS sync uses (it never passes a customer): editing a GRN of a deactivated business is allowed
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.g84_call(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_customer_id=>NULL,p_note=>%L)',:'grn_3','edited by sync 84')) AS edit_null \gset
RESET ROLE;
SELECT pg_temp.g84_assert(:'edit_null'::jsonb->>'raised' IS NULL AND (:'edit_null'::jsonb->>'success')='true'
 AND (SELECT note='edited by sync 84' AND customer_id=:'cust_d'::uuid FROM public.goodsreceived WHERE id=:'grn_3'::uuid),
 'an edit with no customer on a GRN of a deactivated business works: '||:'edit_null');

-- 3. a move onto an active business still works
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.g84_call(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_customer_id=>%L::uuid)',:'grn_2',:'cust_b')) AS move_b \gset
RESET ROLE;
SELECT pg_temp.g84_assert(:'move_b'::jsonb->>'raised' IS NULL AND (:'move_b'::jsonb->>'success')='true'
 AND (SELECT customer_id=:'cust_b'::uuid FROM public.goodsreceived WHERE id=:'grn_2'::uuid),
 'a move onto an active business still works: '||:'move_b');

-- 4. a move onto a deleted business keeps 'Business is not active'
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.g84_call(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_customer_id=>%L::uuid)',:'grn_1',:'cust_x')) AS move_x \gset
RESET ROLE;
SELECT pg_temp.g84_assert(:'move_x'::jsonb->>'raised'='Business is not active' AND :'move_x'::jsonb->>'state'='P0001'
 AND (SELECT customer_id=:'cust_a'::uuid FROM public.goodsreceived WHERE id=:'grn_1'::uuid),
 'a move onto a deleted business says Business is not active: '||:'move_x');

-- 5. after the business is activated again, the move of case 1 succeeds
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.set_customer_active(:'cust_d'::uuid,true) AS reactivate \gset
SELECT pg_temp.g84_call(format('SELECT public.update_grn(p_grn_id=>%L::uuid,p_customer_id=>%L::uuid)',:'grn_1',:'cust_d')) AS move_d \gset
RESET ROLE;
SELECT pg_temp.g84_assert((:'reactivate'::jsonb->>'success')='true' AND :'move_d'::jsonb->>'raised' IS NULL AND (:'move_d'::jsonb->>'success')='true'
 AND (SELECT customer_id=:'cust_d'::uuid FROM public.goodsreceived WHERE id=:'grn_1'::uuid),
 'after activation the move succeeds: '||:'reactivate'||:'move_d');
ROLLBACK;
