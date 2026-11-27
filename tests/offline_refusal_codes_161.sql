-- WH-161, backend topic "refusal codes for offline sends" (contract 2.4, B3, B10, B11): NUMBER_TAKEN (GRN, with the number), STOCK_SHORT (with
-- the short lots and figures), CUSTOMER_INACTIVE, LOT_NOT_FOUND, beside today's text; the other codes (dates, number format, rates) unchanged;
-- every refusal writes nothing. Written before the build: it fails until the topic exists. Fictional data; rolls back at the end.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.rc_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'offline refusal codes 161: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.rc_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.rc_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.rc_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- One GRN line, and the rule of a document type as the owner sets it.
CREATE FUNCTION pg_temp.rc_line(item uuid, name text, pack text, qty integer, weight integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('item_id',item,'item_name',name,'packaging',pack,'qty',qty,'weight',weight) $$;
CREATE FUNCTION pg_temp.rc_rule(p_type text, p_rule jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT warehouse_security.apply_document_numbering(p_type, p_rule, NULL) $$;
-- save_grn as the person of the claims. With neither issue nor rec it is the call of an app released before the topics ("online": no
-- p_issue_number, no p_recorded_at); with either it is an offline send. A key of 'auto' is a new one each time; NULL is no key. A call
-- that raises is answered {success:false, raised, state}, and what it wrote is undone, as the API would.
CREATE FUNCTION pg_temp.rc_grn(claims jsonb, no text, cust uuid, cname text, day text, items jsonb, key text DEFAULT 'auto',
    issue boolean DEFAULT NULL, rec timestamptz DEFAULT NULL, warn boolean DEFAULT false, rates jsonb DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb; k text := CASE WHEN key = 'auto' THEN 'rc-auto-' || gen_random_uuid()::text ELSE key END;
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
CREATE FUNCTION pg_temp.rc_ddata(cust uuid, cname text, no text, reg text, extra jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('disp_no',no,'disp_date','2026-05-02','customer_id',cust,'customer_name',cname,
    'supervisor_id',(SELECT id FROM public.user_profiles WHERE name='Offline Administrator'),'supervisor_name','Offline Administrator','registration',reg) || extra $$;
CREATE FUNCTION pg_temp.rc_dline(lot uuid, qty integer) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('gr_trl_id',lot,'disp_qty',qty) $$;
-- create_dispatch_with_stock_check (5 arguments, no invoice) as the person of the claims; same key and error rules as rc_grn.
CREATE FUNCTION pg_temp.rc_disp(claims jsonb, data jsonb, items jsonb[], key text DEFAULT 'auto') RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb; k text := CASE WHEN key = 'auto' THEN 'rc-auto-' || gen_random_uuid()::text ELSE key END;
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
CREATE FUNCTION pg_temp.rc_off(issue boolean, rec timestamptz) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('issue_number',issue,'recorded_at',rec) $$;
-- What a refused call may have written: GRNs, lots, dispatches, dispatch lines, stock movements, saved answers.
CREATE FUNCTION pg_temp.rc_counts() RETURNS text LANGUAGE sql AS $$
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
SELECT pg_temp.rc_login('9888888971') AS admin_claims \gset
SELECT pg_temp.rc_login('9888888972') AS supervisor_claims \gset
SELECT pg_temp.rc_login('9888888973') AS staff_claims \gset
SELECT pg_temp.rc_login('9888888974') AS customer_claims \gset
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
SELECT pg_temp.rc_assert((SELECT count(*) FROM public.goodsreceived) = 0 AND (SELECT count(*) FROM public.dispatch) = 0,
  'the numbers below count from empty document tables');

SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
-- Typed numbers throughout: the cases name their own documents.
SELECT pg_temp.rc_rule('grn', '{"scheme":"free"}') AS _ \gset
SELECT pg_temp.rc_rule('dispatch', '{"scheme":"free"}') AS _ \gset
CREATE FUNCTION pg_temp.rc_delete_grn(claims jsonb, id uuid) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb;
 BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  SET LOCAL ROLE authenticated;
  r:=public.delete_grn_safe(id);
  RESET ROLE;
  RETURN r;
 END $$;
-- Two receipts of customer A: potatoes 10 bags, onions 5 bags (the lots of the stock cases), recorded an hour ago.
SELECT pg_temp.rc_grn(:'admin_claims'::jsonb,'RC-G1',:'ca'::uuid,'Offline Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rc_line(:'potatoes','Offline Potatoes','Bag',10,50),pg_temp.rc_line(:'onions','Offline Onions','Bag',5,30)),'rc-g1',false,now()-interval '1 hour') AS g1 \gset
SELECT pg_temp.rc_assert(:'g1'::jsonb->>'success'='true','fixture: receipt RC-G1 saved: '||:'g1');
SELECT t.id AS lot_p FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='RC-G1' AND t.item_id=:'potatoes'::uuid \gset
SELECT t.id AS lot_o FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='RC-G1' AND t.item_id=:'onions'::uuid \gset

-- ===========================================================================
-- C1. Number taken: a GRN answers NUMBER_TAKEN with the number, offline and online; the old text stays beside the code. The dispatch has it already.
-- ===========================================================================
SELECT pg_temp.rc_counts() AS counts_a \gset
SELECT pg_temp.rc_grn(:'admin_claims'::jsonb,'RC-G1',:'cb'::uuid,'Offline Customer B','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rc_line(:'onions','Offline Onions','Bag',5,30)),'rc-g1t',false,now()-interval '1 minute') AS g_taken_off \gset
SELECT pg_temp.rc_grn(:'admin_claims'::jsonb,'RC-G1',:'cb'::uuid,'Offline Customer B','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rc_line(:'onions','Offline Onions','Bag',5,30))) AS g_taken_on \gset
SELECT pg_temp.rc_assert(:'g_taken_off'::jsonb->>'success'='false' AND :'g_taken_off'::jsonb->>'reason'='NUMBER_TAKEN' AND :'g_taken_off'::jsonb->>'number'='RC-G1'
  AND :'g_taken_on'::jsonb->>'success'='false' AND :'g_taken_on'::jsonb->>'reason'='NUMBER_TAKEN' AND :'g_taken_on'::jsonb->>'number'='RC-G1'
  AND :'g_taken_on'::jsonb->>'message'='GRN number already exists: RC-G1' AND pg_temp.rc_counts()=:'counts_a',
  'C1 a GRN number already used is answered NUMBER_TAKEN with the number and today''s message, writes nothing: '||:'g_taken_off'||:'g_taken_on');
SELECT pg_temp.rc_disp(:'admin_claims'::jsonb,pg_temp.rc_ddata(:'ca'::uuid,'Offline Customer A','RC-D1','GJ 01 AB 1111',pg_temp.rc_off(false,now()-interval '30 minutes')),
  ARRAY[pg_temp.rc_dline(:'lot_p'::uuid,2)],'rc-d1') AS d1 \gset
SELECT pg_temp.rc_assert(:'d1'::jsonb->>'success'='true','fixture: dispatch RC-D1 takes 2 bags of potatoes: '||:'d1');
SELECT pg_temp.rc_counts() AS counts_b \gset
SELECT pg_temp.rc_disp(:'admin_claims'::jsonb,pg_temp.rc_ddata(:'ca'::uuid,'Offline Customer A','RC-D1','GJ 02 CD 2222',pg_temp.rc_off(false,now()-interval '20 minutes')),
  ARRAY[pg_temp.rc_dline(:'lot_p'::uuid,1)],'rc-d1t') AS d_taken \gset
SELECT pg_temp.rc_assert(:'d_taken'::jsonb->>'success'='false' AND :'d_taken'::jsonb->>'reason'='NUMBER_TAKEN' AND :'d_taken'::jsonb->>'number'='RC-D1' AND pg_temp.rc_counts()=:'counts_b',
  'C1 an offline dispatch with a used number is answered NUMBER_TAKEN with the number: '||:'d_taken');

-- ===========================================================================
-- C2. Stock short: STOCK_SHORT with the lots and figures; the old text stays; nothing is written (on and off line).
-- ===========================================================================
-- Potatoes: 10 - 2 = 8 left. 9 of potatoes is short; 3 of onions (5 left) is fine and is not named.
SELECT pg_temp.rc_disp(:'admin_claims'::jsonb,pg_temp.rc_ddata(:'ca'::uuid,'Offline Customer A','RC-D2','GJ 03 EF 3333',pg_temp.rc_off(false,now()-interval '10 minutes')),
  ARRAY[pg_temp.rc_dline(:'lot_p'::uuid,9),pg_temp.rc_dline(:'lot_o'::uuid,3)],'rc-d2') AS d_short_off \gset
SELECT pg_temp.rc_disp(:'admin_claims'::jsonb,pg_temp.rc_ddata(:'ca'::uuid,'Offline Customer A','RC-D2','GJ 03 EF 3333'),
  ARRAY[pg_temp.rc_dline(:'lot_p'::uuid,9),pg_temp.rc_dline(:'lot_o'::uuid,3)]) AS d_short_on \gset
SELECT pg_temp.rc_assert(:'d_short_off'::jsonb->>'success'='false' AND :'d_short_off'::jsonb->>'reason'='STOCK_SHORT'
  AND :'d_short_off'::jsonb->>'error' LIKE 'Insufficient stock:%' AND pg_temp.rc_counts()=:'counts_b',
  'C2 an offline dispatch for more than a lot holds is answered STOCK_SHORT beside today''s text, nothing written: '||:'d_short_off');
SELECT pg_temp.rc_assert(jsonb_typeof(:'d_short_off'::jsonb->'lines')='array' AND jsonb_array_length(:'d_short_off'::jsonb->'lines')=1
  AND (:'d_short_off'::jsonb#>>'{lines,0,lot_id}')::uuid=:'lot_p'::uuid AND :'d_short_off'::jsonb#>>'{lines,0,item_name}'='Offline Potatoes'
  AND (:'d_short_off'::jsonb#>>'{lines,0,available}')::numeric=8 AND (:'d_short_off'::jsonb#>>'{lines,0,requested}')::numeric=9,
  'C2 the answer names the short lot with what it holds and what was asked: '||:'d_short_off');
SELECT pg_temp.rc_assert(:'d_short_on'::jsonb->>'success'='false' AND :'d_short_on'::jsonb->>'reason'='STOCK_SHORT' AND :'d_short_on'::jsonb->>'error' LIKE 'Insufficient stock:%'
  AND (:'d_short_on'::jsonb#>>'{lines,0,available}')::numeric=8 AND pg_temp.rc_counts()=:'counts_b',
  'C2 an ordinary dispatch carries the same code and figures beside its text: '||:'d_short_on');
-- Two sends for one lot never take more than it holds: 8 left, 6 taken, then 6 more is short with 2 left.
SELECT pg_temp.rc_disp(:'admin_claims'::jsonb,pg_temp.rc_ddata(:'ca'::uuid,'Offline Customer A','RC-D3','GJ 04 GH 4444',pg_temp.rc_off(false,now()-interval '9 minutes')),
  ARRAY[pg_temp.rc_dline(:'lot_p'::uuid,6)],'rc-d3') AS d3 \gset
SELECT pg_temp.rc_disp(:'staff_claims'::jsonb,pg_temp.rc_ddata(:'ca'::uuid,'Offline Customer A','RC-D4','GJ 05 IJ 5555',pg_temp.rc_off(false,now()-interval '8 minutes')),
  ARRAY[pg_temp.rc_dline(:'lot_p'::uuid,6)],'rc-d4') AS d4 \gset
SELECT pg_temp.rc_assert(:'d3'::jsonb->>'success'='true' AND :'d4'::jsonb->>'success'='false' AND :'d4'::jsonb->>'reason'='STOCK_SHORT'
  AND (:'d4'::jsonb#>>'{lines,0,available}')::numeric=2 AND (:'d4'::jsonb#>>'{lines,0,requested}')::numeric=6
  AND (SELECT stock FROM public.goodsreceived_trl WHERE id=:'lot_p'::uuid)=2 AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no='RC-D4'),
  'C2 the second send for the same lot is refused with the 2 bags that are left, and the lot is never oversold: '||:'d3'||:'d4');

-- ===========================================================================
-- C3. A customer deactivated or deleted: CUSTOMER_INACTIVE, for a GRN, on and off line.
-- ===========================================================================
UPDATE public.customers SET active=false WHERE id=:'cc'::uuid;
UPDATE public.customers SET deleted_at=now() WHERE id=:'cd'::uuid;
SELECT pg_temp.rc_counts() AS counts_c \gset
SELECT pg_temp.rc_grn(:'admin_claims'::jsonb,'RC-C1',:'cc'::uuid,'Offline Customer C','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rc_line(:'onions','Offline Onions','Bag',5,30)),'rc-c1',false,now()-interval '1 minute') AS c_off \gset
SELECT pg_temp.rc_grn(:'admin_claims'::jsonb,'RC-C2',:'cc'::uuid,'Offline Customer C','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rc_line(:'onions','Offline Onions','Bag',5,30))) AS c_on \gset
SELECT pg_temp.rc_grn(:'admin_claims'::jsonb,'RC-C3',:'cd'::uuid,'Offline Customer D','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rc_line(:'onions','Offline Onions','Bag',5,30)),'rc-c3',false,now()-interval '1 minute') AS c_del \gset
SELECT pg_temp.rc_assert(:'c_off'::jsonb->>'success'='false' AND :'c_off'::jsonb->>'reason'='CUSTOMER_INACTIVE'
  AND :'c_on'::jsonb->>'success'='false' AND :'c_on'::jsonb->>'reason'='CUSTOMER_INACTIVE' AND pg_temp.rc_counts()=:'counts_c',
  'C3 a GRN for a deactivated customer is answered CUSTOMER_INACTIVE on and off line, nothing written: '||:'c_off'||:'c_on');
SELECT pg_temp.rc_assert(:'c_del'::jsonb->>'success'='false' AND :'c_del'::jsonb->>'reason'='CUSTOMER_INACTIVE' AND pg_temp.rc_counts()=:'counts_c',
  'C3 a GRN for a deleted customer is answered CUSTOMER_INACTIVE: '||:'c_del');

-- ===========================================================================
-- C4. A lot removed meanwhile: LOT_NOT_FOUND, for a lot that never was and for one whose receipt was deleted; nothing is written.
-- ===========================================================================
SELECT pg_temp.rc_grn(:'admin_claims'::jsonb,'RC-G2',:'ce'::uuid,'Offline Customer E','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rc_line(:'onions','Offline Onions','Bag',5,30)),'rc-g2',false,now()-interval '1 hour') AS g2 \gset
SELECT t.id AS lot_e FROM public.goodsreceived_trl t WHERE t.gr_id=(:'g2'::jsonb#>>'{data,grn_id}')::uuid \gset
SELECT pg_temp.rc_delete_grn(:'admin_claims'::jsonb,(:'g2'::jsonb#>>'{data,grn_id}')::uuid) AS g2_deleted \gset
SELECT pg_temp.rc_assert(:'g2_deleted'::jsonb->>'success'='true','fixture: receipt RC-G2 deleted: '||:'g2_deleted');
SELECT pg_temp.rc_counts() AS counts_d \gset
SELECT pg_temp.rc_disp(:'admin_claims'::jsonb,pg_temp.rc_ddata(:'ce'::uuid,'Offline Customer E','RC-D5','GJ 06 KL 6666',pg_temp.rc_off(false,now()-interval '5 minutes')),
  ARRAY[pg_temp.rc_dline(:'lot_e'::uuid,1)],'rc-d5') AS d_gone \gset
SELECT pg_temp.rc_disp(:'admin_claims'::jsonb,pg_temp.rc_ddata(:'ce'::uuid,'Offline Customer E','RC-D6','GJ 06 KL 6666',pg_temp.rc_off(false,now()-interval '5 minutes')),
  ARRAY[pg_temp.rc_dline(gen_random_uuid(),1)],'rc-d6') AS d_never \gset
SELECT pg_temp.rc_assert(:'d_gone'::jsonb->>'success'='false' AND :'d_gone'::jsonb->>'reason'='LOT_NOT_FOUND'
  AND :'d_never'::jsonb->>'success'='false' AND :'d_never'::jsonb->>'reason'='LOT_NOT_FOUND' AND pg_temp.rc_counts()=:'counts_d',
  'C4 a lot that was removed, and a lot that never was, are answered LOT_NOT_FOUND, nothing written: '||:'d_gone'||:'d_never');

-- ===========================================================================
-- C5. The rest keep the codes they have, for an offline send as well.
-- ===========================================================================
SELECT pg_temp.rc_counts() AS counts_e \gset
SELECT pg_temp.rc_disp(:'admin_claims'::jsonb,pg_temp.rc_ddata(:'ca'::uuid,'Offline Customer A','RC-D7','GJ 07 MN 7777',pg_temp.rc_off(false,now()-interval '5 minutes')||'{"disp_date":"2026-03-01"}'),
  ARRAY[pg_temp.rc_dline(:'lot_o'::uuid,1)],'rc-d7') AS d_before \gset
SELECT pg_temp.rc_disp(:'admin_claims'::jsonb,pg_temp.rc_ddata(:'ca'::uuid,'Offline Customer A','RC-D8','GJ 08 OP 8888',pg_temp.rc_off(false,now()-interval '5 minutes')
  ||jsonb_build_object('disp_date',to_char(now()+interval '3 days','YYYY-MM-DD"T"HH24:MI:SS"Z"'))),ARRAY[pg_temp.rc_dline(:'lot_o'::uuid,1)],'rc-d8') AS d_future \gset
SELECT pg_temp.rc_assert(:'d_before'::jsonb->>'reason'='DISPATCH_BEFORE_GRN' AND :'d_future'::jsonb->>'reason'='DISPATCH_DATE_FUTURE' AND pg_temp.rc_counts()=:'counts_e',
  'C5 the dispatch date codes are unchanged for an offline send, nothing written: '||:'d_before'||:'d_future');
-- Rates are checked at send by today's rules: check-only rates with no rate set up are refused RATE_MISSING.
SELECT pg_temp.rc_rule('grn', '{"scheme":"letters"}') AS _ \gset
SELECT warehouse_security.document_number_suggestion('grn', NULL)->>'number' AS next_grn \gset
SELECT pg_temp.rc_grn(:'admin_claims'::jsonb,'',:'cf'::uuid,'Offline Customer F','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rc_line(:'potatoes','Offline Potatoes','Bag',10,50)),'rc-r1',true,now()-interval '1 minute',false,'[]'::jsonb) AS r_off \gset
SELECT pg_temp.rc_grn(:'admin_claims'::jsonb,'A0099',:'cf'::uuid,'Offline Customer F','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rc_line(:'potatoes','Offline Potatoes','Bag',10,50)),'auto',NULL,NULL,false,'[]'::jsonb) AS r_on \gset
SELECT pg_temp.rc_assert(:'r_off'::jsonb->>'success'='false' AND :'r_off'::jsonb->>'error_code'='RATE_MISSING'
  AND :'r_on'::jsonb->>'success'='false' AND :'r_on'::jsonb->>'error_code'='RATE_MISSING' AND pg_temp.rc_counts()=:'counts_e',
  'C5 a GRN whose rates fail is refused RATE_MISSING on and off line, and the number it would have had is not used: '||:'r_off'||:'r_on');
SELECT pg_temp.rc_grn(:'admin_claims'::jsonb,'',:'cf'::uuid,'Offline Customer F','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rc_line(:'potatoes','Offline Potatoes','Bag',10,50)),'rc-r2',true,now()-interval '1 minute') AS r_ok \gset
SELECT pg_temp.rc_assert(:'r_ok'::jsonb->>'success'='true' AND :'r_ok'::jsonb#>>'{data,gr_no}'=:'next_grn','C5 without the rates check the same GRN saves with the number the refused one would have had: '||:'r_ok');
SELECT pg_temp.rc_grn(:'admin_claims'::jsonb,'ZZ 1',:'cf'::uuid,'Offline Customer F','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rc_line(:'potatoes','Offline Potatoes','Bag',10,50)),'rc-f1',false,now()-interval '1 minute') AS f_spaces \gset
SELECT pg_temp.rc_grn(:'admin_claims'::jsonb,'AB',:'cf'::uuid,'Offline Customer F','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rc_line(:'potatoes','Offline Potatoes','Bag',10,50)),'rc-f2',false,now()-interval '1 minute') AS f_format \gset
SELECT pg_temp.rc_assert(:'f_spaces'::jsonb->>'reason'='GRN_NUMBER_SPACES' AND :'f_format'::jsonb->>'reason'='NUMBER_FORMAT',
  'C5 a typed number with a space, and one outside the rule, keep GRN_NUMBER_SPACES and NUMBER_FORMAT: '||:'f_spaces'||:'f_format');

ROLLBACK;
