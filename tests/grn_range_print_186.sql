-- WH-186 (migration 194): the GRN range print (get_grn_range_for_print, behind print-grn-preprinted) leaves out deleted GRNs, and, since
-- migration 191, imported ones. Live A0001 and A0005, deleted A0002 and A0004, imported A0003. A range of only deleted GRNs, and one of
-- only an imported GRN, give no row; a live GRN comes with its line. Fictional data; runs only in migrations.sh's disposable,
-- network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.rp_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'GRN range print: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.rp_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.rp_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.rp_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
CREATE FUNCTION pg_temp.rp_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
-- The range as the print function reads it (the service role): the GRN numbers it returns, in order, comma separated ('' for none).
CREATE FUNCTION pg_temp.rp_range(p_from text, p_to text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer jsonb; v_numbers text;
BEGIN
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  EXECUTE 'SET LOCAL ROLE service_role';
  answer := public.get_grn_range_for_print(p_from, p_to, 100);
  EXECUTE 'RESET ROLE';
  SELECT COALESCE(string_agg(e->>'gr_no', ',' ORDER BY e->>'gr_no'), '') INTO v_numbers
    FROM jsonb_array_elements(COALESCE(answer->'grns', answer->'data', '[]'::jsonb)) e;
  RETURN v_numbers;
END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888921','Range Print Administrator') AS boot \gset
SELECT pg_temp.rp_login('9888888921') AS admin_claims \gset
INSERT INTO public.customers(name,mobile) VALUES ('Range Print Customer','9888888922') RETURNING id AS customer \gset
INSERT INTO public.items(name,packaging) VALUES ('Range Print Potato','Bag') RETURNING id AS item_id \gset
-- Four app GRNs, A0002 and A0004 then deleted.
SELECT string_agg(n || ':' || (pg_temp.rp_as(:'admin_claims'::jsonb, format($q$SELECT public.save_grn(p_gr_no=>%L,p_date=>now(),p_customer_id=>%L::uuid,p_customer_name=>'Range Print Customer',
  p_pricing_mode=>'MONTHLY',p_idempotency_key=>%L,p_items=>jsonb_build_array(jsonb_build_object('item_id',%L,'item_name','Range Print Potato','packaging','Bag','qty',10,'weight',50,'rack','R1')))$q$,
  n, :'customer', 'rp-' || n, :'item_id'))->>'success'), ',') AS saved
  FROM unnest(ARRAY['A0001','A0002','A0004','A0005','A0006']) n \gset
SELECT pg_temp.rp_assert((SELECT count(*) FROM public.goodsreceived WHERE gr_no IN ('A0001','A0002','A0004','A0005','A0006')) = 5, 'five app GRNs saved');
SELECT id AS g2 FROM public.goodsreceived WHERE gr_no = 'A0002' \gset
SELECT id AS g4 FROM public.goodsreceived WHERE gr_no = 'A0004' \gset
-- No RPC sets goodsreceived.deleted_at today (delete_grn_safe removes the row), so the state migration 194 guards is made directly. A GRN
-- removed by delete_grn_safe (A0006) is simply not there to print.
UPDATE public.goodsreceived SET deleted_at = now() WHERE id IN (:'g2'::uuid, :'g4'::uuid);
SELECT id AS g6 FROM public.goodsreceived WHERE gr_no = 'A0006' \gset
SELECT pg_temp.rp_as(:'admin_claims'::jsonb, format($q$SELECT public.delete_grn_safe(%L::uuid)$q$, :'g6')) AS del6 \gset
SELECT pg_temp.rp_assert(:'del6'::jsonb->>'success' = 'true' AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no = 'A0006'), 'A0006 removed by delete_grn_safe: ' || :'del6');
SELECT pg_temp.rp_assert((SELECT count(*) FROM public.goodsreceived WHERE gr_no IN ('A0002','A0004') AND deleted_at IS NOT NULL) = 2, 'both are soft-deleted');
-- One imported GRN, A0003, through the import itself.
INSERT INTO warehouse_import.stage_grns(line,gr_no,gr_date,customer,pricing) VALUES (2,'A0003','2023-05-05','Range Print Customer','MONTHLY');
INSERT INTO warehouse_import.stage_grn_lines(line,gr_no,gr_date,line_no,item,packaging,qty,weight,stock_now) VALUES (2,'A0003','2023-05-05',1,'Range Print Potato','Bag',10,50,10);
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true) AS c \gset
SET LOCAL ROLE service_role;
SELECT public.import_history('{}'::jsonb, true) AS imported \gset
RESET ROLE;
SELECT pg_temp.rp_assert(:'imported'::jsonb->>'success' = 'true', 'the import of A0003: ' || :'imported');
SELECT pg_temp.rp_assert((SELECT import_batch_id IS NOT NULL AND deleted_at IS NULL FROM public.goodsreceived WHERE gr_no = 'A0003'), 'A0003 is imported and live');

-- The range A0001 to A0006 prints the two live app GRNs only.
SELECT pg_temp.rp_assert(pg_temp.rp_range('A0001', 'A0006') = 'A0001,A0005', 'range A0001-A0006 gives the live app GRNs only: ' || pg_temp.rp_range('A0001', 'A0006'));
-- A range of only deleted GRNs gives no row; so does one of only an imported GRN; a live one comes with its line.
SELECT pg_temp.rp_assert(pg_temp.rp_range('A0002', 'A0002') = '', 'a deleted GRN alone gives no row');
SELECT pg_temp.rp_assert(pg_temp.rp_range('A0002', 'A0002') = '' AND pg_temp.rp_range('A0004', 'A0004') = '', 'each deleted GRN alone gives no row');
SELECT pg_temp.rp_assert(pg_temp.rp_range('A0002', 'A0004') = '', 'a range of deleted and imported GRNs gives no row');
SELECT pg_temp.rp_assert(pg_temp.rp_range('A0003', 'A0003') = '', 'an imported GRN alone gives no row');
SELECT pg_temp.rp_assert(pg_temp.rp_range('A0001', 'A0001') = 'A0001', 'a live GRN alone is printed');
SELECT pg_temp.rp_assert(pg_temp.rp_range('A0001', 'A0002') = 'A0001', 'a live and a deleted GRN give the live one');
-- The live GRN comes with its line.
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true) AS c \gset
SET LOCAL ROLE service_role;
SELECT public.get_grn_range_for_print('A0001', 'A0001', 100) AS one \gset
RESET ROLE;
SELECT pg_temp.rp_assert(:'one'::jsonb::text LIKE '%Range Print Potato%', 'the live GRN is printed with its line: ' || :'one');
-- The access is as before: not for anon or signed-in users.
SELECT pg_temp.rp_assert(NOT has_function_privilege('anon', 'public.get_grn_range_for_print(text,text,integer)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.get_grn_range_for_print(text,text,integer)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public.get_grn_range_for_print(text,text,integer)', 'EXECUTE'), 'the range read stays with the service role');
ROLLBACK;
\echo 'GRN range print: deleted and imported GRNs are left out, a range with nothing to print gives no row.'
