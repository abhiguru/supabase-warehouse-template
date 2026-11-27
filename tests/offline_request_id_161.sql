-- WH-161, backend topic "permanent request ID on offline records" (contract 2.3, B5-B8): request_key and request_digest on goodsreceived and
-- dispatch; a repeated offline send returns the first answer (idempotent true) at once, with the saved answer gone and 8 days on, with one
-- document, one number and the stock taken once; the same key for other contents or by another person is REQUEST_KEY_REUSED; a deleted
-- document is RECORD_DELETED; an offline send needs a key; get_submission_result answers the key after 8 days.
-- Written before the build: it fails until the topic exists. Fictional data; rolls back at the end.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ri_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'offline request id 161: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.ri_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.ri_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.ri_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- One GRN line, and the rule of a document type as the owner sets it.
CREATE FUNCTION pg_temp.ri_line(item uuid, name text, pack text, qty integer, weight integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('item_id',item,'item_name',name,'packaging',pack,'qty',qty,'weight',weight) $$;
CREATE FUNCTION pg_temp.ri_rule(p_type text, p_rule jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT warehouse_security.apply_document_numbering(p_type, p_rule, NULL) $$;
-- save_grn as the person of the claims. With neither issue nor rec it is the call of an app released before the topics ("online": no
-- p_issue_number, no p_recorded_at); with either it is an offline send. A key of 'auto' is a new one each time; NULL is no key. A call
-- that raises is answered {success:false, raised, state}, and what it wrote is undone, as the API would.
CREATE FUNCTION pg_temp.ri_grn(claims jsonb, no text, cust uuid, cname text, day text, items jsonb, key text DEFAULT 'auto',
    issue boolean DEFAULT NULL, rec timestamptz DEFAULT NULL, warn boolean DEFAULT false, rates jsonb DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb; k text := CASE WHEN key = 'auto' THEN 'ri-auto-' || gen_random_uuid()::text ELSE key END;
 BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  SET LOCAL ROLE authenticated;
  BEGIN
   IF issue IS NULL AND rec IS NULL THEN
    r:=public.save_grn(p_sender_name=>'Fixture Sender',p_supervisor_id=>(SELECT id FROM public.user_profiles WHERE NOT is_service_account ORDER BY created_at LIMIT 1),p_supervisor_name=>'Fixture Supervisor',p_gr_no=>no,p_date=>day::timestamptz,p_customer_id=>cust,p_customer_name=>cname,p_pricing_mode=>'MONTHLY',p_items=>items,p_rates=>rates,p_idempotency_key=>k,p_warn_duplicate=>warn);
   ELSE
    r:=public.save_grn(p_sender_name=>'Fixture Sender',p_supervisor_id=>(SELECT id FROM public.user_profiles WHERE NOT is_service_account ORDER BY created_at LIMIT 1),p_supervisor_name=>'Fixture Supervisor',p_gr_no=>no,p_date=>day::timestamptz,p_customer_id=>cust,p_customer_name=>cname,p_pricing_mode=>'MONTHLY',p_items=>items,p_rates=>rates,p_idempotency_key=>k,p_warn_duplicate=>warn,p_issue_number=>COALESCE(issue,false),p_recorded_at=>rec);
   END IF;
  EXCEPTION WHEN OTHERS THEN r:=jsonb_build_object('success',false,'raised',SQLERRM,'state',SQLSTATE);
  END;
  RESET ROLE;
  RETURN r;
 END $$;
-- Dispatch data for a customer; the supervisor is the administrator. extra carries issue_number, recorded_at, warn_duplicate.
CREATE FUNCTION pg_temp.ri_ddata(cust uuid, cname text, no text, reg text, extra jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('disp_no',no,'disp_date','2026-05-02','customer_id',cust,'customer_name',cname,
    'supervisor_id',(SELECT id FROM public.user_profiles WHERE name='Offline Administrator'),'supervisor_name','Offline Administrator','registration',reg) || extra $$;
CREATE FUNCTION pg_temp.ri_dline(lot uuid, qty integer) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('gr_trl_id',lot,'disp_qty',qty) $$;
-- create_dispatch_with_stock_check (5 arguments, no invoice) as the person of the claims; same key and error rules as ri_grn.
CREATE FUNCTION pg_temp.ri_disp(claims jsonb, data jsonb, items jsonb[], key text DEFAULT 'auto') RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb; k text := CASE WHEN key = 'auto' THEN 'ri-auto-' || gen_random_uuid()::text ELSE key END;
 BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  SET LOCAL ROLE authenticated;
  BEGIN
   r:=public.create_dispatch_with_stock_check(data,items,false,0,k);
  EXCEPTION WHEN OTHERS THEN r:=jsonb_build_object('success',false,'raised',SQLERRM,'state',SQLSTATE);
  END;
  RESET ROLE;
  RETURN r;
 END $$;
-- The offline members of the dispatch data.
CREATE FUNCTION pg_temp.ri_off(issue boolean, rec timestamptz) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('issue_number',issue,'recorded_at',rec) $$;
-- What a refused call may have written: GRNs, lots, dispatches, dispatch lines, stock movements, saved answers.
CREATE FUNCTION pg_temp.ri_counts() RETURNS text LANGUAGE sql AS $$
  SELECT (SELECT count(*) FROM public.goodsreceived)||'/'||(SELECT count(*) FROM public.goodsreceived_trl)||'/'||(SELECT count(*) FROM public.dispatch)
    ||'/'||(SELECT count(*) FROM public.dispatch_trl)||'/'||(SELECT count(*) FROM public.stock_movements)||'/'||(SELECT count(*) FROM public.idempotency_keys) $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888971','Offline Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888972','Offline Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888973','Offline Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888974','Offline Customer Reader','customer',true,'approved');
SELECT pg_temp.ri_login('9888888971') AS admin_claims \gset
SELECT pg_temp.ri_login('9888888972') AS supervisor_claims \gset
SELECT pg_temp.ri_login('9888888973') AS staff_claims \gset
SELECT pg_temp.ri_login('9888888974') AS customer_claims \gset
INSERT INTO public.customers(name,mobile) VALUES
 ('Offline Customer A','9888888981'),('Offline Customer B','9888888982'),('Offline Customer C','9888888983'),('Offline Customer D','9888888984'),
 ('Offline Customer E','9888888985'),('Offline Customer F','9888888986'),('Offline Customer G','9888888987'),('Offline Customer H','9888888988');
SELECT id AS ca FROM public.customers WHERE name='Offline Customer A' \gset
SELECT id AS cb FROM public.customers WHERE name='Offline Customer B' \gset
SELECT id AS cc FROM public.customers WHERE name='Offline Customer C' \gset
SELECT id AS cd FROM public.customers WHERE name='Offline Customer D' \gset
SELECT id AS ce FROM public.customers WHERE name='Offline Customer E' \gset
SELECT id AS cf FROM public.customers WHERE name='Offline Customer F' \gset
SELECT id AS cg FROM public.customers WHERE name='Offline Customer G' \gset
SELECT id AS ch FROM public.customers WHERE name='Offline Customer H' \gset
INSERT INTO public.items(name,packaging) VALUES ('Offline Potatoes','Bag'),('Offline Onions','Bag');
SELECT id AS potatoes FROM public.items WHERE name='Offline Potatoes' \gset
SELECT id AS onions FROM public.items WHERE name='Offline Onions' \gset
SELECT pg_temp.ri_assert((SELECT count(*) FROM public.goodsreceived) = 0 AND (SELECT count(*) FROM public.dispatch) = 0,
  'the numbers below count from empty document tables');

SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
-- A bare row in goodsreceived or dispatch with a request key (as the database owner): 'ok' or the SQLSTATE it ended in.
CREATE FUNCTION pg_temp.ri_ins(tbl text, no text, key text, cust uuid) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE format('INSERT INTO public.%I(%s, customer_id, request_key) VALUES ($1, $2, $3)', tbl, CASE WHEN tbl = 'dispatch' THEN 'disp_no' ELSE 'gr_no' END) USING no, cust, key;
  EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE; END;
  RETURN 'ok';
END $$;
-- What the documents hold, without the saved answers (a replay may or may not store one again).
CREATE FUNCTION pg_temp.ri_docs() RETURNS text LANGUAGE sql AS $$
  SELECT (SELECT count(*) FROM public.goodsreceived)||'/'||(SELECT count(*) FROM public.goodsreceived_trl)||'/'||(SELECT count(*) FROM public.dispatch)
    ||'/'||(SELECT count(*) FROM public.dispatch_trl)||'/'||(SELECT count(*) FROM public.stock_movements) $$;
-- get_submission_result as the person of the claims.
CREATE FUNCTION pg_temp.ri_result(claims jsonb, key text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb;
 BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  SET LOCAL ROLE authenticated;
  r:=public.get_submission_result(key);
  RESET ROLE;
  RETURN r;
 END $$;
-- The administrator deletes a GRN or a dispatch through the ordinary functions.
CREATE FUNCTION pg_temp.ri_delete_grn(claims jsonb, id uuid) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb;
 BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  SET LOCAL ROLE authenticated;
  r:=public.delete_grn_safe(id);
  RESET ROLE;
  RETURN r;
 END $$;
CREATE FUNCTION pg_temp.ri_delete_dispatch(claims jsonb, id uuid, profile uuid) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb;
 BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  SET LOCAL ROLE authenticated;
  r:=public.delete_dispatch_with_order_cleanup(id,profile);
  RESET ROLE;
  RETURN r;
 END $$;

-- ===========================================================================
-- Q1. The columns: a request key and its digest on both documents, the key unique where it is set.
-- ===========================================================================
SELECT pg_temp.ri_assert((SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name IN ('goodsreceived','dispatch')
    AND column_name IN ('request_key','request_digest'))=4,'Q1 goodsreceived and dispatch each have request_key and request_digest');
SELECT pg_temp.ri_ins('goodsreceived','RI-X1','ri-same',:'ca'::uuid) AS x1 \gset
SELECT pg_temp.ri_ins('goodsreceived','RI-X2','ri-same',:'ca'::uuid) AS x2 \gset
SELECT pg_temp.ri_ins('goodsreceived','RI-X3',NULL,:'ca'::uuid) AS x3 \gset
SELECT pg_temp.ri_ins('goodsreceived','RI-X4',NULL,:'ca'::uuid) AS x4 \gset
SELECT pg_temp.ri_assert(:'x1'='ok' AND :'x2'='23505' AND :'x3'='ok' AND :'x4'='ok',
  'Q1 a request key is unique on goodsreceived, and rows without one do not clash: '||:'x1'||' '||:'x2'||' '||:'x3'||' '||:'x4');
SELECT pg_temp.ri_ins('dispatch','RI-X1','ri-same',:'ca'::uuid) AS y1 \gset
SELECT pg_temp.ri_ins('dispatch','RI-X2','ri-same',:'ca'::uuid) AS y2 \gset
SELECT pg_temp.ri_ins('dispatch','RI-X3',NULL,:'ca'::uuid) AS y3 \gset
SELECT pg_temp.ri_ins('dispatch','RI-X4',NULL,:'ca'::uuid) AS y4 \gset
SELECT pg_temp.ri_assert(:'y1'='ok' AND :'y2'='23505' AND :'y3'='ok' AND :'y4'='ok',
  'Q1 a request key is unique on dispatch, and rows without one do not clash: '||:'y1'||' '||:'y2'||' '||:'y3'||' '||:'y4');
DELETE FROM public.goodsreceived WHERE gr_no LIKE 'RI-X%';
SELECT set_config('warehouse.dispatch_delete_via_rpc', 'on', true) AS _ \gset
DELETE FROM public.dispatch WHERE disp_no LIKE 'RI-X%';
SELECT set_config('warehouse.dispatch_delete_via_rpc', 'off', true) AS _ \gset

-- ===========================================================================
-- Q2. A repeated GRN send returns the first answer: at once, with the saved answer gone, and with the clock 8 days on.
-- ===========================================================================
SELECT now()-interval '1 hour' AS rec_g1 \gset
SELECT pg_temp.ri_grn(:'admin_claims'::jsonb,'',:'ca'::uuid,'Offline Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.ri_line(:'potatoes','Offline Potatoes','Bag',100,50),pg_temp.ri_line(:'onions','Offline Onions','Bag',20,30)),'ri-g1',true,:'rec_g1'::timestamptz) AS g1 \gset
SELECT pg_temp.ri_assert(:'g1'::jsonb->>'success'='true' AND :'g1'::jsonb#>>'{data,gr_no}'='A0001','fixture: the first send is saved as A0001: '||:'g1');
SELECT pg_temp.ri_assert((SELECT request_key='ri-g1' AND request_digest IS NOT NULL AND request_digest <> '' FROM public.goodsreceived WHERE id=(:'g1'::jsonb#>>'{data,grn_id}')::uuid),
  'Q2 the document holds its request key and a digest of the request');
SELECT pg_temp.ri_docs() AS counts_g \gset
SELECT t.id AS lot_p FROM public.goodsreceived_trl t WHERE t.gr_id=(:'g1'::jsonb#>>'{data,grn_id}')::uuid AND t.item_id=:'potatoes'::uuid \gset
-- (a) at once
SELECT pg_temp.ri_grn(:'admin_claims'::jsonb,'',:'ca'::uuid,'Offline Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.ri_line(:'potatoes','Offline Potatoes','Bag',100,50),pg_temp.ri_line(:'onions','Offline Onions','Bag',20,30)),'ri-g1',true,:'rec_g1'::timestamptz) AS g1a \gset
SELECT pg_temp.ri_assert(:'g1a'::jsonb->>'success'='true' AND :'g1a'::jsonb->>'idempotent'='true' AND :'g1a'::jsonb#>>'{data,grn_id}'=:'g1'::jsonb#>>'{data,grn_id}'
  AND :'g1a'::jsonb#>>'{data,gr_no}'='A0001' AND :'g1a'::jsonb#>'{data,item_mapping}'=:'g1'::jsonb#>'{data,item_mapping}' AND pg_temp.ri_docs()=:'counts_g',
  'Q2 a resend at once returns the same GRN, number and line mapping, marked idempotent, and writes nothing: '||:'g1a');
-- (b) the saved answer removed
DELETE FROM public.idempotency_keys WHERE idempotency_key='ri-g1';
SELECT pg_temp.ri_grn(:'admin_claims'::jsonb,'',:'ca'::uuid,'Offline Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.ri_line(:'potatoes','Offline Potatoes','Bag',100,50),pg_temp.ri_line(:'onions','Offline Onions','Bag',20,30)),'ri-g1',true,:'rec_g1'::timestamptz) AS g1b \gset
SELECT pg_temp.ri_assert(:'g1b'::jsonb->>'success'='true' AND :'g1b'::jsonb->>'idempotent'='true' AND :'g1b'::jsonb#>>'{data,grn_id}'=:'g1'::jsonb#>>'{data,grn_id}'
  AND :'g1b'::jsonb#>>'{data,gr_no}'='A0001' AND :'g1b'::jsonb#>'{data,item_mapping}'=:'g1'::jsonb#>'{data,item_mapping}' AND pg_temp.ri_docs()=:'counts_g',
  'Q2 a resend after the saved answer is gone finds the document and returns the first answer: '||:'g1b');
SELECT pg_temp.ri_assert((SELECT count(*) FROM public.goodsreceived)=1 AND (SELECT count(*) FROM public.goodsreceived_trl)=2
  AND warehouse_security.document_number_suggestion('grn', NULL)->>'number'='A0002',
  'Q2 one document, two lots, and no second number was used');
-- (c) with the clock 8 days on: the saved answer, if any, is past its 7 days
UPDATE public.idempotency_keys SET expires_at=now()-interval '1 day', created_at=now()-interval '8 days' WHERE idempotency_key='ri-g1';
SELECT pg_temp.ri_grn(:'admin_claims'::jsonb,'',:'ca'::uuid,'Offline Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.ri_line(:'potatoes','Offline Potatoes','Bag',100,50),pg_temp.ri_line(:'onions','Offline Onions','Bag',20,30)),'ri-g1',true,:'rec_g1'::timestamptz) AS g1c \gset
SELECT pg_temp.ri_assert(:'g1c'::jsonb->>'success'='true' AND :'g1c'::jsonb#>>'{data,grn_id}'=:'g1'::jsonb#>>'{data,grn_id}' AND :'g1c'::jsonb#>>'{data,gr_no}'='A0001'
  AND (SELECT count(*) FROM public.goodsreceived)=1,
  'Q2 a resend 8 days later still returns the first GRN and makes no second: '||:'g1c');
SELECT pg_temp.ri_assert((SELECT stock FROM public.goodsreceived_trl WHERE id=:'lot_p'::uuid)=100,'Q2 the lot holds the one receipt of 100 bags');

-- ===========================================================================
-- Q3. The same for a dispatch: one dispatch, its number, and the stock taken once.
-- ===========================================================================
SELECT now()-interval '30 minutes' AS rec_d1 \gset
SELECT pg_temp.ri_disp(:'admin_claims'::jsonb,pg_temp.ri_ddata(:'ca'::uuid,'Offline Customer A','','GJ 01 AB 1111',pg_temp.ri_off(true,:'rec_d1'::timestamptz)),
  ARRAY[pg_temp.ri_dline(:'lot_p'::uuid,5)],'ri-d1') AS d1 \gset
SELECT pg_temp.ri_assert(:'d1'::jsonb->>'success'='true' AND :'d1'::jsonb->>'disp_no'='I0001' AND (SELECT stock FROM public.goodsreceived_trl WHERE id=:'lot_p'::uuid)=95
  AND (SELECT request_key='ri-d1' AND request_digest IS NOT NULL FROM public.dispatch WHERE id=(:'d1'::jsonb->>'dispatch_id')::uuid),
  'fixture: the first dispatch is I0001, takes 5 bags and holds its request key and digest: '||:'d1');
SELECT pg_temp.ri_docs() AS counts_d \gset
SELECT pg_temp.ri_disp(:'admin_claims'::jsonb,pg_temp.ri_ddata(:'ca'::uuid,'Offline Customer A','','GJ 01 AB 1111',pg_temp.ri_off(true,:'rec_d1'::timestamptz)),
  ARRAY[pg_temp.ri_dline(:'lot_p'::uuid,5)],'ri-d1') AS d1a \gset
DELETE FROM public.idempotency_keys WHERE idempotency_key='ri-d1';
SELECT pg_temp.ri_disp(:'admin_claims'::jsonb,pg_temp.ri_ddata(:'ca'::uuid,'Offline Customer A','','GJ 01 AB 1111',pg_temp.ri_off(true,:'rec_d1'::timestamptz)),
  ARRAY[pg_temp.ri_dline(:'lot_p'::uuid,5)],'ri-d1') AS d1b \gset
SELECT pg_temp.ri_assert(:'d1a'::jsonb->>'idempotent'='true' AND :'d1b'::jsonb->>'idempotent'='true'
  AND :'d1a'::jsonb->>'dispatch_id'=:'d1'::jsonb->>'dispatch_id' AND :'d1b'::jsonb->>'dispatch_id'=:'d1'::jsonb->>'dispatch_id'
  AND :'d1a'::jsonb->>'disp_no'='I0001' AND :'d1b'::jsonb->>'disp_no'='I0001',
  'Q3 a resend at once and a resend after the saved answer is gone return the same dispatch and number: '||:'d1a'||:'d1b');
SELECT pg_temp.ri_assert((SELECT count(*) FROM public.dispatch)=1 AND (SELECT count(*) FROM public.dispatch_trl)=1
  AND (SELECT stock FROM public.goodsreceived_trl WHERE id=:'lot_p'::uuid)=95 AND warehouse_security.document_number_suggestion('dispatch', NULL)->>'number'='I0002'
  AND pg_temp.ri_docs()=:'counts_d',
  'Q3 one dispatch, one line, the stock taken once, no second number');
UPDATE public.idempotency_keys SET expires_at=now()-interval '1 day', created_at=now()-interval '8 days' WHERE idempotency_key='ri-d1';
SELECT pg_temp.ri_disp(:'admin_claims'::jsonb,pg_temp.ri_ddata(:'ca'::uuid,'Offline Customer A','','GJ 01 AB 1111',pg_temp.ri_off(true,:'rec_d1'::timestamptz)),
  ARRAY[pg_temp.ri_dline(:'lot_p'::uuid,5)],'ri-d1') AS d1c \gset
SELECT pg_temp.ri_assert(:'d1c'::jsonb->>'dispatch_id'=:'d1'::jsonb->>'dispatch_id' AND :'d1c'::jsonb->>'disp_no'='I0001' AND (SELECT count(*) FROM public.dispatch)=1
  AND (SELECT stock FROM public.goodsreceived_trl WHERE id=:'lot_p'::uuid)=95,
  'Q3 a resend 8 days later returns the first dispatch, makes no second and takes no more stock: '||:'d1c');

-- ===========================================================================
-- Q4. A key used again for other contents, or by another person, is refused and changes nothing.
-- ===========================================================================
SELECT pg_temp.ri_counts() AS counts_e \gset
SELECT pg_temp.ri_grn(:'admin_claims'::jsonb,'',:'ca'::uuid,'Offline Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.ri_line(:'potatoes','Offline Potatoes','Bag',99,50),pg_temp.ri_line(:'onions','Offline Onions','Bag',20,30)),'ri-g1',true,:'rec_g1'::timestamptz) AS g1_other \gset
SELECT pg_temp.ri_assert(:'g1_other'::jsonb->>'success'='false' AND :'g1_other'::jsonb->>'reason'='REQUEST_KEY_REUSED' AND pg_temp.ri_counts()=:'counts_e',
  'Q4 the same key with another quantity is refused REQUEST_KEY_REUSED, nothing written: '||:'g1_other');
SELECT pg_temp.ri_grn(:'staff_claims'::jsonb,'',:'ca'::uuid,'Offline Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.ri_line(:'potatoes','Offline Potatoes','Bag',100,50),pg_temp.ri_line(:'onions','Offline Onions','Bag',20,30)),'ri-g1',true,:'rec_g1'::timestamptz) AS g1_person \gset
SELECT pg_temp.ri_assert(:'g1_person'::jsonb->>'success'='false' AND :'g1_person'::jsonb->>'reason'='REQUEST_KEY_REUSED' AND pg_temp.ri_counts()=:'counts_e',
  'Q4 the same key and contents from another person is refused REQUEST_KEY_REUSED, nothing written: '||:'g1_person');
SELECT pg_temp.ri_disp(:'admin_claims'::jsonb,pg_temp.ri_ddata(:'ca'::uuid,'Offline Customer A','','GJ 01 AB 1111',pg_temp.ri_off(true,:'rec_d1'::timestamptz)),
  ARRAY[pg_temp.ri_dline(:'lot_p'::uuid,4)],'ri-d1') AS d1_other \gset
SELECT pg_temp.ri_disp(:'staff_claims'::jsonb,pg_temp.ri_ddata(:'ca'::uuid,'Offline Customer A','','GJ 01 AB 1111',pg_temp.ri_off(true,:'rec_d1'::timestamptz)),
  ARRAY[pg_temp.ri_dline(:'lot_p'::uuid,5)],'ri-d1') AS d1_person \gset
SELECT pg_temp.ri_assert(:'d1_other'::jsonb->>'reason'='REQUEST_KEY_REUSED' AND :'d1_person'::jsonb->>'reason'='REQUEST_KEY_REUSED' AND pg_temp.ri_counts()=:'counts_e'
  AND (SELECT stock FROM public.goodsreceived_trl WHERE id=:'lot_p'::uuid)=95,
  'Q4 a dispatch key used for other lines, or by another person, is refused REQUEST_KEY_REUSED, nothing written: '||:'d1_other'||:'d1_person');
-- With no key at all an offline send is refused.
SELECT pg_temp.ri_grn(:'admin_claims'::jsonb,'',:'cb'::uuid,'Offline Customer B','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.ri_line(:'onions','Offline Onions','Bag',10,30)),NULL,true,now()-interval '1 minute') AS g_nokey \gset
SELECT pg_temp.ri_assert(:'g_nokey'::jsonb->>'success'='false' AND pg_temp.ri_counts()=:'counts_e','Q4 an offline GRN send without a request key is refused: '||:'g_nokey');

-- ===========================================================================
-- Q5. The document was deleted meanwhile: the key finds it, and nothing is made again.
-- ===========================================================================
SELECT pg_temp.ri_grn(:'admin_claims'::jsonb,'',:'cb'::uuid,'Offline Customer B','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.ri_line(:'onions','Offline Onions','Bag',10,30)),'ri-g5',true,now()-interval '20 minutes') AS g5 \gset
SELECT pg_temp.ri_assert(:'g5'::jsonb->>'success'='true','fixture: GRN of customer B saved: '||:'g5');
SELECT pg_temp.ri_delete_grn(:'admin_claims'::jsonb,(:'g5'::jsonb#>>'{data,grn_id}')::uuid) AS g5_deleted \gset
SELECT pg_temp.ri_assert(:'g5_deleted'::jsonb->>'success'='true','fixture: the GRN is deleted: '||:'g5_deleted');
DELETE FROM public.idempotency_keys WHERE idempotency_key='ri-g5';
SELECT pg_temp.ri_counts() AS counts_f \gset
SELECT pg_temp.ri_grn(:'admin_claims'::jsonb,'',:'cb'::uuid,'Offline Customer B','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.ri_line(:'onions','Offline Onions','Bag',10,30)),'ri-g5',true,now()-interval '20 minutes') AS g5_again \gset
SELECT pg_temp.ri_assert(:'g5_again'::jsonb->>'success'='false' AND :'g5_again'::jsonb->>'reason'='RECORD_DELETED' AND pg_temp.ri_counts()=:'counts_f',
  'Q5 a resend for a GRN deleted meanwhile is refused RECORD_DELETED and makes no new GRN: '||:'g5_again');
-- The tombstone (contract 2.3): the delete itself wrote the key of the deleted GRN to warehouse_security.deleted_request_keys (a BEFORE DELETE
-- trigger of goodsreceived and dispatch, so every delete path is covered), with its creator and digest; the table is closed to the app roles.
SELECT pg_temp.ri_assert((SELECT count(*)=1 FROM warehouse_security.deleted_request_keys k WHERE k.request_key='ri-g5' AND k.rpc_function='save_grn'
    AND k.record_id=(:'g5'::jsonb#>>'{data,grn_id}')::uuid AND k.created_by=:'admin_profile'::uuid AND k.request_digest IS NOT NULL AND k.deleted_at IS NOT NULL),
  'Q5 the tombstone of the deleted GRN holds its key, kind, id, creator, digest and time');
SELECT pg_temp.ri_assert((SELECT relrowsecurity FROM pg_class WHERE oid='warehouse_security.deleted_request_keys'::regclass)
  AND NOT has_table_privilege('authenticated','warehouse_security.deleted_request_keys','SELECT') AND NOT has_table_privilege('anon','warehouse_security.deleted_request_keys','SELECT')
  AND NOT has_table_privilege('service_role','warehouse_security.deleted_request_keys','SELECT')
  AND (SELECT count(*)=2 FROM pg_trigger t WHERE NOT t.tgisinternal AND t.tgname='keep_deleted_request_key' AND t.tgrelid IN ('public.goodsreceived'::regclass,'public.dispatch'::regclass)
    AND (t.tgtype & 2)=2 AND (t.tgtype & 8)=8 AND (t.tgtype & 1)=1),
  'Q5 the tombstone table has RLS on and no read for the app roles; a BEFORE DELETE row trigger sits on goodsreceived and on dispatch');
-- Another person, or the same person with other contents, meeting the tombstone is REQUEST_KEY_REUSED, not RECORD_DELETED, and nothing is made.
SELECT pg_temp.ri_grn(:'staff_claims'::jsonb,'',:'cb'::uuid,'Offline Customer B','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.ri_line(:'onions','Offline Onions','Bag',10,30)),'ri-g5',true,now()-interval '20 minutes') AS g5_person \gset
SELECT pg_temp.ri_grn(:'admin_claims'::jsonb,'',:'cb'::uuid,'Offline Customer B','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.ri_line(:'onions','Offline Onions','Bag',11,30)),'ri-g5',true,now()-interval '20 minutes') AS g5_digest \gset
SELECT pg_temp.ri_assert(:'g5_person'::jsonb->>'success'='false' AND :'g5_person'::jsonb->>'reason'='REQUEST_KEY_REUSED'
  AND :'g5_digest'::jsonb->>'success'='false' AND :'g5_digest'::jsonb->>'reason'='REQUEST_KEY_REUSED' AND pg_temp.ri_counts()=:'counts_f',
  'Q5 the key of a deleted GRN sent by another person, or with other contents, is REQUEST_KEY_REUSED and makes no GRN: '||:'g5_person'||:'g5_digest');
SELECT pg_temp.ri_disp(:'admin_claims'::jsonb,pg_temp.ri_ddata(:'ca'::uuid,'Offline Customer A','','GJ 05 GH 5555',pg_temp.ri_off(true,now()-interval '10 minutes')),
  ARRAY[pg_temp.ri_dline(:'lot_p'::uuid,3)],'ri-d5') AS d5 \gset
SELECT pg_temp.ri_assert(:'d5'::jsonb->>'success'='true','fixture: a second dispatch is saved: '||:'d5');
SELECT pg_temp.ri_delete_dispatch(:'admin_claims'::jsonb,(:'d5'::jsonb->>'dispatch_id')::uuid,:'admin_profile'::uuid) AS d5_deleted \gset
SELECT pg_temp.ri_assert(:'d5_deleted'::jsonb->>'success'='true','fixture: the dispatch is deleted: '||:'d5_deleted');
DELETE FROM public.idempotency_keys WHERE idempotency_key='ri-d5';
SELECT pg_temp.ri_counts() AS counts_h \gset
SELECT pg_temp.ri_disp(:'admin_claims'::jsonb,pg_temp.ri_ddata(:'ca'::uuid,'Offline Customer A','','GJ 05 GH 5555',pg_temp.ri_off(true,now()-interval '10 minutes')),
  ARRAY[pg_temp.ri_dline(:'lot_p'::uuid,3)],'ri-d5') AS d5_again \gset
SELECT pg_temp.ri_assert(:'d5_again'::jsonb->>'success'='false' AND :'d5_again'::jsonb->>'reason'='RECORD_DELETED' AND pg_temp.ri_counts()=:'counts_h'
  AND (SELECT stock FROM public.goodsreceived_trl WHERE id=:'lot_p'::uuid)=95,
  'Q5 a resend for a dispatch deleted meanwhile is refused RECORD_DELETED, makes no new dispatch and takes no stock: '||:'d5_again');
SELECT pg_temp.ri_assert((SELECT count(*)=1 FROM warehouse_security.deleted_request_keys k WHERE k.request_key='ri-d5' AND k.rpc_function='create_dispatch_with_stock_check'
    AND k.record_id=(:'d5'::jsonb->>'dispatch_id')::uuid AND k.created_by=:'admin_profile'::uuid AND k.request_digest IS NOT NULL),
  'Q5 the tombstone of the deleted dispatch holds its key, kind, id, creator and digest');
SELECT pg_temp.ri_disp(:'staff_claims'::jsonb,pg_temp.ri_ddata(:'ca'::uuid,'Offline Customer A','','GJ 05 GH 5555',pg_temp.ri_off(true,now()-interval '10 minutes')),
  ARRAY[pg_temp.ri_dline(:'lot_p'::uuid,3)],'ri-d5') AS d5_person \gset
SELECT pg_temp.ri_disp(:'admin_claims'::jsonb,pg_temp.ri_ddata(:'ca'::uuid,'Offline Customer A','','GJ 05 GH 5555',pg_temp.ri_off(true,now()-interval '10 minutes')),
  ARRAY[pg_temp.ri_dline(:'lot_p'::uuid,4)],'ri-d5') AS d5_digest \gset
SELECT pg_temp.ri_assert(:'d5_person'::jsonb->>'reason'='REQUEST_KEY_REUSED' AND :'d5_digest'::jsonb->>'reason'='REQUEST_KEY_REUSED' AND pg_temp.ri_counts()=:'counts_h'
  AND (SELECT stock FROM public.goodsreceived_trl WHERE id=:'lot_p'::uuid)=95,
  'Q5 the key of a deleted dispatch sent by another person, or for other lines, is REQUEST_KEY_REUSED, makes no dispatch and takes no stock: '||:'d5_person'||:'d5_digest');

-- ===========================================================================
-- Q6. get_submission_result answers the key after 8 days and without the saved answer; only to the person who sent it.
-- ===========================================================================
UPDATE public.idempotency_keys SET expires_at=now()-interval '1 day', created_at=now()-interval '8 days' WHERE idempotency_key IN ('ri-g1','ri-d1');
DELETE FROM public.idempotency_keys WHERE idempotency_key='ri-g1';
SELECT pg_temp.ri_result(:'admin_claims'::jsonb,'ri-g1') AS s_grn \gset
SELECT pg_temp.ri_result(:'admin_claims'::jsonb,'ri-d1') AS s_disp \gset
SELECT pg_temp.ri_assert(:'s_grn'::jsonb->>'found'='true' AND :'s_grn'::jsonb#>>'{response,data,grn_id}'=:'g1'::jsonb#>>'{data,grn_id}'
  AND :'s_grn'::jsonb#>>'{response,data,gr_no}'='A0001','Q6 the GRN key is answered without its saved answer: '||:'s_grn');
SELECT pg_temp.ri_assert(:'s_disp'::jsonb->>'found'='true' AND :'s_disp'::jsonb#>>'{response,dispatch_id}'=:'d1'::jsonb->>'dispatch_id'
  AND :'s_disp'::jsonb#>>'{response,disp_no}'='I0001','Q6 the dispatch key is answered 8 days on: '||:'s_disp');
SELECT pg_temp.ri_result(:'staff_claims'::jsonb,'ri-g1') AS s_other \gset
SELECT pg_temp.ri_result(:'admin_claims'::jsonb,'ri-never-sent') AS s_none \gset
SELECT pg_temp.ri_assert(:'s_other'::jsonb->>'found'='false' AND :'s_none'::jsonb->>'found'='false','Q6 another person, and a key never sent, are answered found false: '||:'s_other'||:'s_none');
SELECT pg_temp.ri_result(:'admin_claims'::jsonb,'ri-g5') AS s_deleted \gset
SELECT pg_temp.ri_assert(:'s_deleted'::jsonb->>'found'='false','Q6 the key of a deleted GRN is answered found false: '||:'s_deleted');

ROLLBACK;
