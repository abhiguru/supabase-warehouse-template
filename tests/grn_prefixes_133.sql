-- Migration 133: get_grn_prefixes_with_stock returns the trimmed, upper-cased leading run of non-digits (DV, X, T-), not the first letter; a number that starts with a digit gets its first character, so no GRN is left without a button.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database. Every row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.gpx_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'grn prefixes: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.gpx_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM pg_temp.gpx_assert(challenge->>'success'='true','ordinary challenge');
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  login := public.operator_verify_otp(phone,challenge#>>'{data,otp_code}');
  PERFORM pg_temp.gpx_assert(login#>>'{data,action}'='login','ordinary login');
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id
    WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888831','Prefix Administrator');
SELECT pg_temp.gpx_login('9888888831') AS admin_claims \gset
-- Numbers are free text here (the facility's numbering is not what this test is about).
SELECT warehouse_security.apply_document_numbering('grn', '{"scheme":"free"}', NULL) AS _ \gset
SELECT warehouse_security.apply_document_numbering('dispatch', '{"scheme":"free"}', NULL) AS _ \gset
INSERT INTO public.customers(name,mobile) VALUES ('Prefix Customer','9888888881') RETURNING id AS customer_id \gset
INSERT INTO public.customers(name,mobile) VALUES ('Digit Customer','9888888882') RETURNING id AS digit_id \gset
INSERT INTO public.items(name,packaging) VALUES ('Prefix Onions','Bag') RETURNING id AS onion_id \gset



SELECT set_config('request.jwt.claims',:'admin_claims',true);
SELECT set_config('gpx.cust',:'customer_id',true), set_config('gpx.digit',:'digit_id',true), set_config('gpx.item',:'onion_id',true);
SET LOCAL ROLE authenticated;
CREATE FUNCTION pg_temp.gpx_save(n text, cust uuid, cname text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  r := public.save_grn(p_gr_no=>n,p_date=>now(),p_customer_id=>cust,p_customer_name=>cname,
    p_items=>jsonb_build_array(jsonb_build_object('item_id',current_setting('gpx.item')::uuid,'item_name','Prefix Onions','packaging','Bag','qty',10,'weight',40,'rack','A1','package_mark','P'||n)),
    p_idempotency_key=>'gpx-'||cname||n);
  PERFORM pg_temp.gpx_assert(r->>'success'='true','save '||n||': '||r);
END $$;
-- Letter series and odd numbers (customer 1).
DO $$
DECLARE n text;
BEGIN
  FOREACH n IN ARRAY ARRAY['DV0102','DV0103','dv01','X0001','E0008','T-12','T31-G5','G14','A77','GRN/26-27/0001','99001'] LOOP
    PERFORM pg_temp.gpx_save(n, current_setting('gpx.cust')::uuid, 'Prefix Customer');
  END LOOP;
  -- A facility whose numbers all start with a digit (customer 2): 0001 and 26-27/0001.
  FOREACH n IN ARRAY ARRAY['0001','26-27/0001','26-27/0002'] LOOP
    PERFORM pg_temp.gpx_save(n, current_setting('gpx.digit')::uuid, 'Digit Customer');
  END LOOP;
END $$;
RESET ROLE;
-- save_grn refuses spaces in a number; older data may still have them (set directly).
UPDATE public.goodsreceived SET gr_no = 'G 14' WHERE gr_no = 'G14' AND customer_id = :'customer_id'::uuid;
UPDATE public.goodsreceived SET gr_no = ' A77' WHERE gr_no = 'A77' AND customer_id = :'customer_id'::uuid;
SELECT pg_temp.gpx_assert((SELECT count(*) FROM public.goodsreceived WHERE customer_id IN (:'customer_id'::uuid,:'digit_id'::uuid))=14,'fourteen receipts saved');
SET LOCAL ROLE authenticated;
SELECT public.get_grn_prefixes_with_stock(:'customer_id'::uuid) AS pf \gset
SELECT public.get_grn_prefixes_with_stock(:'digit_id'::uuid) AS pd \gset
SELECT public.get_grn_prefixes_with_stock(NULL) AS pa \gset
RESET ROLE;
SELECT pg_temp.gpx_assert(:'pf'::jsonb->>'success'='true','answers: '||:'pf');
SELECT pg_temp.gpx_assert((SELECT string_agg(e->>'prefix'||':'||(e->>'grn_count'),',' ORDER BY e->>'prefix' COLLATE "C") FROM jsonb_array_elements(:'pf'::jsonb->'data') e)
 ='9:1,A:1,DV:3,E:1,G:1,GRN/:1,T:1,T-:1,X:1',
 'trimmed upper-cased run; dv01 joins DV; T31-G5 -> T; GRN/ kept; 99001 -> 9: '||:'pf');
-- Only digit-first numbers in stock: still a button for each (the app shows the digit keys only when there is a button).
SELECT pg_temp.gpx_assert((SELECT string_agg(e->>'prefix'||':'||(e->>'grn_count'),',' ORDER BY e->>'prefix' COLLATE "C") FROM jsonb_array_elements(:'pd'::jsonb->'data') e)
 ='0:1,2:2', 'digit-first numbers keep their first character: '||:'pd');
-- No GRN with stock is dropped: the counts add up to every receipt.
SELECT pg_temp.gpx_assert((SELECT sum((e->>'grn_count')::int) FROM jsonb_array_elements(:'pa'::jsonb->'data') e)
 =(SELECT count(DISTINCT gr.id) FROM public.goodsreceived gr JOIN public.goodsreceived_trl gt ON gt.gr_id=gr.id WHERE gr.deleted_at IS NULL AND gt.stock>0),
 'every GRN with stock is counted: '||:'pa');
-- A button finds its GRNs under the app's search (case-insensitive contains): every prefix is contained in its numbers.
SELECT pg_temp.gpx_assert(NOT EXISTS (
  SELECT 1 FROM jsonb_array_elements(:'pf'::jsonb->'data') e
  WHERE NOT EXISTS (SELECT 1 FROM public.goodsreceived gr WHERE gr.customer_id=:'customer_id'::uuid AND gr.gr_no ILIKE '%'||replace(replace(e->>'prefix','\','\\'),'%','\%')||'%')),
 'each prefix is found by a contains search');
ROLLBACK;
