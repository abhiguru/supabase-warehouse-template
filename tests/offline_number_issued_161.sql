-- WH-161, backend topic "number issued at save" (tech/app-offline-new-records.md 2.1, B1-B4, B12, B13): an offline GRN or dispatch send with a blank
-- number and the issue flag (save_grn p_issue_number, dispatch data issue_number) gets the next number inside the lock, in arrival order, under the
-- letters, year and sequence schemes; free numbering and a full series are refused; a refused send uses no number; a number sent with the flag
-- is refused; roles; and a save without the new members is today's save. Written before the build: it fails until the topic exists.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database. Everything rolls back at the end.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.nn_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'offline number 161: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.nn_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.nn_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.nn_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- One GRN line, and the rule of a document type as the owner sets it.
CREATE FUNCTION pg_temp.nn_line(item uuid, name text, pack text, qty integer, weight integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('item_id',item,'item_name',name,'packaging',pack,'qty',qty,'weight',weight) $$;
CREATE FUNCTION pg_temp.nn_rule(p_type text, p_rule jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT warehouse_security.apply_document_numbering(p_type, p_rule, NULL) $$;
-- save_grn as the person of the claims. With neither issue nor rec it is the call of an app released before the topics ("online": no
-- p_issue_number, no p_recorded_at); with either it is an offline send. A key of 'auto' is a new one each time; NULL is no key. A call
-- that raises is answered {success:false, raised, state}, and what it wrote is undone, as the API would.
CREATE FUNCTION pg_temp.nn_grn(claims jsonb, no text, cust uuid, cname text, day text, items jsonb, key text DEFAULT 'auto',
    issue boolean DEFAULT NULL, rec timestamptz DEFAULT NULL, warn boolean DEFAULT false, rates jsonb DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb; k text := CASE WHEN key = 'auto' THEN 'nn-auto-' || gen_random_uuid()::text ELSE key END;
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
CREATE FUNCTION pg_temp.nn_ddata(cust uuid, cname text, no text, reg text, extra jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('disp_no',no,'disp_date','2026-05-02','customer_id',cust,'customer_name',cname,
    'supervisor_id',(SELECT id FROM public.user_profiles WHERE name='Offline Administrator'),'supervisor_name','Offline Administrator','registration',reg) || extra $$;
CREATE FUNCTION pg_temp.nn_dline(lot uuid, qty integer) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('gr_trl_id',lot,'disp_qty',qty) $$;
-- create_dispatch_with_stock_check (5 arguments, no invoice) as the person of the claims; same key and error rules as nn_grn.
CREATE FUNCTION pg_temp.nn_disp(claims jsonb, data jsonb, items jsonb[], key text DEFAULT 'auto') RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb; k text := CASE WHEN key = 'auto' THEN 'nn-auto-' || gen_random_uuid()::text ELSE key END;
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
CREATE FUNCTION pg_temp.nn_off(issue boolean, rec timestamptz) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('issue_number',issue,'recorded_at',rec) $$;
-- What a refused call may have written: GRNs, lots, dispatches, dispatch lines, stock movements, saved answers.
CREATE FUNCTION pg_temp.nn_counts() RETURNS text LANGUAGE sql AS $$
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
SELECT pg_temp.nn_login('9888888971') AS admin_claims \gset
SELECT pg_temp.nn_login('9888888972') AS supervisor_claims \gset
SELECT pg_temp.nn_login('9888888973') AS staff_claims \gset
SELECT pg_temp.nn_login('9888888974') AS customer_claims \gset
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
SELECT pg_temp.nn_assert((SELECT count(*) FROM public.goodsreceived) = 0 AND (SELECT count(*) FROM public.dispatch) = 0,
  'the numbers below count from empty document tables');
-- The numbers below follow the new-installation rules (migration 127), not whatever an earlier suite of the run left: GRN letters from A, dispatch I + 4 digits.
SELECT pg_temp.nn_rule('grn', '{"scheme":"letters","first_letter":"A","width":4,"per_letter":1000}') AS _ \gset
SELECT pg_temp.nn_rule('dispatch', '{"scheme":"sequence","prefix":"I","width":4,"start":1}') AS _ \gset

-- ===========================================================================
-- N1-N3. GRN numbers under the default letters rule: the next one, in the order the sends arrive, whoever sends.
-- ===========================================================================
SELECT pg_temp.nn_grn(:'admin_claims'::jsonb,'',:'ca'::uuid,'Offline Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.nn_line(:'potatoes','Offline Potatoes','Bag',100,50)),'nn-g1',true,now()-interval '5 minutes') AS g1 \gset
SELECT pg_temp.nn_assert(:'g1'::jsonb->>'success'='true' AND :'g1'::jsonb#>>'{data,gr_no}'='A0001'
  AND (SELECT count(*) FROM public.goodsreceived WHERE gr_no='A0001' AND id=(:'g1'::jsonb#>>'{data,grn_id}')::uuid)=1 AND (SELECT count(*) FROM public.goodsreceived)=1,
  'N1 a blank number with the issue flag is saved with the next number A0001, in the answer and on the row: '||:'g1');
SELECT pg_temp.nn_grn(:'supervisor_claims'::jsonb,'',:'cb'::uuid,'Offline Customer B','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.nn_line(:'onions','Offline Onions','Bag',10,30)),'nn-g2',true,now()-interval '4 minutes') AS g2 \gset
SELECT pg_temp.nn_grn(:'staff_claims'::jsonb,'',:'cc'::uuid,'Offline Customer C','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.nn_line(:'onions','Offline Onions','Bag',10,30)),'nn-g3',true,now()-interval '3 minutes') AS g3 \gset
SELECT pg_temp.nn_assert(:'g2'::jsonb#>>'{data,gr_no}'='A0002' AND :'g3'::jsonb#>>'{data,gr_no}'='A0003'
  AND (SELECT gr_no FROM public.goodsreceived WHERE id=(:'g2'::jsonb#>>'{data,grn_id}')::uuid)='A0002'
  AND (SELECT gr_no FROM public.goodsreceived WHERE id=(:'g3'::jsonb#>>'{data,grn_id}')::uuid)='A0003',
  'N2 a burst gets consecutive numbers in the order it arrives, for the supervisor and for staff: '||:'g2'||:'g3');
SELECT pg_temp.nn_assert(warehouse_security.document_number_suggestion('grn', NULL)->>'number'='A0004',
  'N2 the suggestion that follows the burst is A0004');

-- ===========================================================================
-- N3. Dispatch numbers under the default sequence rule, from the lot of A0001 (100 bags of customer A).
-- ===========================================================================
SELECT t.id AS lot_a FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='A0001' \gset
SELECT pg_temp.nn_disp(:'admin_claims'::jsonb,pg_temp.nn_ddata(:'ca'::uuid,'Offline Customer A','','GJ 01 AB 1111',pg_temp.nn_off(true,now()-interval '2 minutes')),
  ARRAY[pg_temp.nn_dline(:'lot_a'::uuid,5)],'nn-d1') AS d1 \gset
SELECT pg_temp.nn_disp(:'staff_claims'::jsonb,pg_temp.nn_ddata(:'ca'::uuid,'Offline Customer A','','GJ 02 CD 2222',pg_temp.nn_off(true,now()-interval '1 minute')),
  ARRAY[pg_temp.nn_dline(:'lot_a'::uuid,5)],'nn-d2') AS d2 \gset
SELECT pg_temp.nn_assert(:'d1'::jsonb->>'success'='true' AND :'d1'::jsonb->>'disp_no'='I0001'
  AND (SELECT disp_no FROM public.dispatch WHERE id=(:'d1'::jsonb->>'dispatch_id')::uuid)='I0001',
  'N3 an offline dispatch with a blank number is saved as I0001 and the answer carries it: '||:'d1');
SELECT pg_temp.nn_assert(:'d2'::jsonb->>'success'='true' AND :'d2'::jsonb->>'disp_no'='I0002'
  AND (SELECT disp_no FROM public.dispatch WHERE id=(:'d2'::jsonb->>'dispatch_id')::uuid)='I0002',
  'N3 the next dispatch, sent by staff, is I0002: '||:'d2');

-- ===========================================================================
-- N4. A send that is refused uses no number: the next one gets the number the refused one would have had.
-- ===========================================================================
SELECT pg_temp.nn_counts() AS counts_a \gset
SELECT pg_temp.nn_disp(:'admin_claims'::jsonb,pg_temp.nn_ddata(:'ca'::uuid,'Offline Customer A','','GJ 03 EF 3333',pg_temp.nn_off(true,now()-interval '1 minute')),
  ARRAY[pg_temp.nn_dline(:'lot_a'::uuid,1000)],'nn-d3') AS d3_short \gset
SELECT pg_temp.nn_assert(:'d3_short'::jsonb->>'success'='false' AND pg_temp.nn_counts()=:'counts_a','N4 a dispatch refused for stock writes nothing: '||:'d3_short');
SELECT pg_temp.nn_disp(:'customer_claims'::jsonb,pg_temp.nn_ddata(:'ca'::uuid,'Offline Customer A','','GJ 03 EF 3333',pg_temp.nn_off(true,now()-interval '1 minute')),
  ARRAY[pg_temp.nn_dline(:'lot_a'::uuid,1)],'nn-d3c') AS d3_customer \gset
SELECT pg_temp.nn_assert(:'d3_customer'::jsonb->>'success'='false' AND pg_temp.nn_counts()=:'counts_a',
  'B13 a customer account cannot send a new dispatch, offline either: '||:'d3_customer');
SELECT pg_temp.nn_disp(:'supervisor_claims'::jsonb,pg_temp.nn_ddata(:'ca'::uuid,'Offline Customer A','','GJ 03 EF 3333',pg_temp.nn_off(true,now()-interval '1 minute')),
  ARRAY[pg_temp.nn_dline(:'lot_a'::uuid,5)],'nn-d3ok') AS d3 \gset
SELECT pg_temp.nn_assert(:'d3'::jsonb->>'success'='true' AND :'d3'::jsonb->>'disp_no'='I0003',
  'N4 the dispatch after two refused ones is I0003, and the supervisor may send one: '||:'d3');
-- A number sent together with the issue flag is refused, and uses no number either.
SELECT pg_temp.nn_counts() AS counts_b \gset
SELECT pg_temp.nn_grn(:'admin_claims'::jsonb,'A9999',:'cd'::uuid,'Offline Customer D','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.nn_line(:'onions','Offline Onions','Bag',10,30)),'nn-g4x',true,now()-interval '1 minute') AS g4_numbered \gset
SELECT pg_temp.nn_assert(:'g4_numbered'::jsonb->>'success'='false' AND :'g4_numbered'::jsonb->>'reason'='NUMBER_NOT_EXPECTED' AND pg_temp.nn_counts()=:'counts_b',
  'N4 a GRN that sends a number and asks for one is refused NUMBER_NOT_EXPECTED, nothing written: '||:'g4_numbered');
SELECT pg_temp.nn_disp(:'admin_claims'::jsonb,pg_temp.nn_ddata(:'ca'::uuid,'Offline Customer A','I9999','GJ 01 AB 1111',pg_temp.nn_off(true,now()-interval '1 minute')),
  ARRAY[pg_temp.nn_dline(:'lot_a'::uuid,1)],'nn-d4x') AS d4_numbered \gset
SELECT pg_temp.nn_assert(:'d4_numbered'::jsonb->>'success'='false' AND :'d4_numbered'::jsonb->>'reason'='NUMBER_NOT_EXPECTED' AND pg_temp.nn_counts()=:'counts_b',
  'N4 a dispatch that sends a number and asks for one is refused NUMBER_NOT_EXPECTED, nothing written: '||:'d4_numbered');
SELECT pg_temp.nn_grn(:'customer_claims'::jsonb,'',:'cd'::uuid,'Offline Customer D','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.nn_line(:'onions','Offline Onions','Bag',10,30)),'nn-g4c',true,now()-interval '1 minute') AS g4_customer \gset
SELECT pg_temp.nn_assert(:'g4_customer'::jsonb->>'success'='false' AND pg_temp.nn_counts()=:'counts_b',
  'B13 a customer account cannot send a new GRN, offline either: '||:'g4_customer');
SELECT pg_temp.nn_grn(:'admin_claims'::jsonb,'',:'cd'::uuid,'Offline Customer D','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.nn_line(:'onions','Offline Onions','Bag',10,30)),'nn-g4',true,now()-interval '1 minute') AS g4 \gset
SELECT pg_temp.nn_assert(:'g4'::jsonb->>'success'='true' AND :'g4'::jsonb#>>'{data,gr_no}'='A0004',
  'N4 the GRN after the refused ones is A0004: '||:'g4');

-- ===========================================================================
-- N5. The financial-year scheme: the number is the one the owner's suggestion gives for the day of the document.
-- ===========================================================================
SELECT pg_temp.nn_rule('grn', '{"scheme":"year","prefix":"GRN/"}')->>'hint' AS _ \gset
SELECT warehouse_security.document_number_suggestion('grn', '2026-04-01')->>'number' AS year_expected \gset
SELECT pg_temp.nn_assert(:'year_expected' <> '' AND :'year_expected' LIKE 'GRN/%','fixture: the year rule suggests a GRN/ number: '||:'year_expected');
SELECT pg_temp.nn_grn(:'admin_claims'::jsonb,'',:'ce'::uuid,'Offline Customer E','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.nn_line(:'onions','Offline Onions','Bag',10,30)),'nn-g5',true,now()-interval '1 minute') AS g5 \gset
SELECT pg_temp.nn_assert(:'g5'::jsonb->>'success'='true' AND :'g5'::jsonb#>>'{data,gr_no}'=:'year_expected'
  AND warehouse_security.document_number_suggestion('grn', '2026-04-01')->>'number' <> :'year_expected',
  'N5 under the year scheme the issued number is the suggestion for the document day, and the next suggestion moves on: '||:'g5');

-- ===========================================================================
-- N6. A store that types its numbers (free): the server cannot issue one; a typed number saves; a taken one is refused with the number.
-- ===========================================================================
SELECT pg_temp.nn_rule('grn', '{"scheme":"free"}') AS _ \gset
SELECT pg_temp.nn_rule('dispatch', '{"scheme":"free"}') AS _ \gset
SELECT pg_temp.nn_counts() AS counts_c \gset
SELECT pg_temp.nn_grn(:'admin_claims'::jsonb,'',:'cf'::uuid,'Offline Customer F','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.nn_line(:'onions','Offline Onions','Bag',10,30)),'nn-g6x',true,now()-interval '1 minute') AS g6_blank \gset
SELECT pg_temp.nn_assert(:'g6_blank'::jsonb->>'success'='false' AND :'g6_blank'::jsonb->>'reason'='NUMBER_REQUIRED' AND pg_temp.nn_counts()=:'counts_c',
  'N6 a free-numbering store asking the server for a GRN number is refused NUMBER_REQUIRED, nothing written: '||:'g6_blank');
SELECT pg_temp.nn_disp(:'admin_claims'::jsonb,pg_temp.nn_ddata(:'ca'::uuid,'Offline Customer A','','GJ 01 AB 1111',pg_temp.nn_off(true,now()-interval '1 minute')),
  ARRAY[pg_temp.nn_dline(:'lot_a'::uuid,1)],'nn-d6x') AS d6_blank \gset
SELECT pg_temp.nn_assert(:'d6_blank'::jsonb->>'success'='false' AND :'d6_blank'::jsonb->>'reason'='NUMBER_REQUIRED' AND pg_temp.nn_counts()=:'counts_c',
  'N6 the same for a dispatch number: '||:'d6_blank');
SELECT pg_temp.nn_grn(:'admin_claims'::jsonb,'FREE-1',:'cf'::uuid,'Offline Customer F','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.nn_line(:'onions','Offline Onions','Bag',10,30)),'nn-g6',false,now()-interval '1 minute') AS g6 \gset
SELECT pg_temp.nn_assert(:'g6'::jsonb->>'success'='true' AND :'g6'::jsonb#>>'{data,gr_no}'='FREE-1'
  AND (SELECT count(*) FROM public.goodsreceived WHERE gr_no='FREE-1')=1,'N6 a typed number is saved as typed: '||:'g6');
SELECT pg_temp.nn_grn(:'admin_claims'::jsonb,'FREE-1',:'cg'::uuid,'Offline Customer G','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.nn_line(:'potatoes','Offline Potatoes','Bag',10,50)),'nn-g6t',false,now()-interval '1 minute') AS g6_taken \gset
SELECT pg_temp.nn_assert(:'g6_taken'::jsonb->>'success'='false' AND :'g6_taken'::jsonb->>'reason'='NUMBER_TAKEN' AND :'g6_taken'::jsonb->>'number'='FREE-1'
  AND (SELECT count(*) FROM public.goodsreceived WHERE gr_no='FREE-1')=1,'N6 a taken typed number is refused NUMBER_TAKEN with the number: '||:'g6_taken');

-- ===========================================================================
-- N7. The end of a series: no number left is refused SERIES_FULL and writes nothing.
-- ===========================================================================
SELECT pg_temp.nn_rule('dispatch', '{"scheme":"sequence","prefix":"I"}') AS _ \gset
INSERT INTO public.dispatch(disp_no, customer_id) VALUES ('I9999999', :'ca');
SELECT pg_temp.nn_counts() AS counts_d \gset
SELECT pg_temp.nn_disp(:'admin_claims'::jsonb,pg_temp.nn_ddata(:'ca'::uuid,'Offline Customer A','','GJ 01 AB 1111',pg_temp.nn_off(true,now()-interval '1 minute')),
  ARRAY[pg_temp.nn_dline(:'lot_a'::uuid,1)],'nn-d7') AS d7 \gset
SELECT pg_temp.nn_assert(:'d7'::jsonb->>'success'='false' AND :'d7'::jsonb->>'reason'='SERIES_FULL' AND pg_temp.nn_counts()=:'counts_d',
  'N7 a dispatch sent when I9999999 ends the sequence is refused SERIES_FULL, nothing written: '||:'d7');

-- ===========================================================================
-- N8. A save with neither new member is today's save (every app already released): the number sent is used, a blank one refused as before,
--     the row has no recorded time and no request key, and the dispatch answer only gains its number.
-- ===========================================================================
SELECT pg_temp.nn_rule('grn', '{"scheme":"letters"}') AS _ \gset
SELECT pg_temp.nn_grn(:'admin_claims'::jsonb,'A0040',:'ch'::uuid,'Offline Customer H','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.nn_line(:'potatoes','Offline Potatoes','Bag',50,50))) AS g8 \gset
SELECT pg_temp.nn_assert(:'g8'::jsonb->>'success'='true' AND :'g8'::jsonb#>>'{data,gr_no}'='A0040'
  AND (SELECT recorded_at IS NULL AND request_key IS NULL FROM public.goodsreceived WHERE gr_no='A0040'),
  'N8 an ordinary GRN save keeps its typed number and stores no recorded time and no request key: '||:'g8');
SELECT pg_temp.nn_grn(:'admin_claims'::jsonb,'',:'ch'::uuid,'Offline Customer H','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.nn_line(:'potatoes','Offline Potatoes','Bag',50,50))) AS g8_blank \gset
SELECT pg_temp.nn_assert(:'g8_blank'::jsonb->>'success'='false' AND :'g8_blank'::jsonb->>'message' LIKE 'Missing required parameters%',
  'N8 an ordinary GRN save with a blank number is still refused: '||:'g8_blank');
SELECT t.id AS lot_h FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='A0040' \gset
SELECT pg_temp.nn_disp(:'admin_claims'::jsonb,pg_temp.nn_ddata(:'ch'::uuid,'Offline Customer H','I0040','GJ 01 AB 1111'),ARRAY[pg_temp.nn_dline(:'lot_h'::uuid,5)]) AS d8 \gset
SELECT pg_temp.nn_assert(:'d8'::jsonb->>'success'='true' AND :'d8'::jsonb->>'disp_no'='I0040'
  AND (SELECT recorded_at IS NULL AND request_key IS NULL FROM public.dispatch WHERE disp_no='I0040'),
  'N8 an ordinary dispatch save answers with its number, and stores no recorded time and no request key: '||:'d8');

ROLLBACK;
