-- WH-161, backend topic "recorded time on offline records" (contract 2.2, B9): save_grn p_recorded_at and the dispatch data recorded_at are stored in
-- recorded_at beside created_at; more than 5 minutes ahead of the server is refused RECORDED_TIME_FUTURE; the possible-duplicate window of an
-- offline send runs between recorded times, not arrivals (everything here arrives in one transaction, so only the recorded time can tell).
-- Written before the build: it fails until the topic exists. Fictional data; rolls back at the end.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.rt_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'offline recorded time 161: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.rt_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.rt_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.rt_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- One GRN line, and the rule of a document type as the owner sets it.
CREATE FUNCTION pg_temp.rt_line(item uuid, name text, pack text, qty integer, weight integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('item_id',item,'item_name',name,'packaging',pack,'qty',qty,'weight',weight) $$;
CREATE FUNCTION pg_temp.rt_rule(p_type text, p_rule jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT warehouse_security.apply_document_numbering(p_type, p_rule, NULL) $$;
-- save_grn as the person of the claims. With neither issue nor rec it is the call of an app released before the topics ("online": no
-- p_issue_number, no p_recorded_at); with either it is an offline send. A key of 'auto' is a new one each time; NULL is no key. A call
-- that raises is answered {success:false, raised, state}, and what it wrote is undone, as the API would.
CREATE FUNCTION pg_temp.rt_grn(claims jsonb, no text, cust uuid, cname text, day text, items jsonb, key text DEFAULT 'auto',
    issue boolean DEFAULT NULL, rec timestamptz DEFAULT NULL, warn boolean DEFAULT false, rates jsonb DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb; k text := CASE WHEN key = 'auto' THEN 'rt-auto-' || gen_random_uuid()::text ELSE key END;
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
CREATE FUNCTION pg_temp.rt_ddata(cust uuid, cname text, no text, reg text, extra jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('disp_no',no,'disp_date','2026-05-02','customer_id',cust,'customer_name',cname,
    'supervisor_id',(SELECT id FROM public.user_profiles WHERE name='Offline Administrator'),'supervisor_name','Offline Administrator','registration',reg) || extra $$;
CREATE FUNCTION pg_temp.rt_dline(lot uuid, qty integer) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('gr_trl_id',lot,'disp_qty',qty) $$;
-- create_dispatch_with_stock_check (5 arguments, no invoice) as the person of the claims; same key and error rules as rt_grn.
CREATE FUNCTION pg_temp.rt_disp(claims jsonb, data jsonb, items jsonb[], key text DEFAULT 'auto') RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb; k text := CASE WHEN key = 'auto' THEN 'rt-auto-' || gen_random_uuid()::text ELSE key END;
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
CREATE FUNCTION pg_temp.rt_off(issue boolean, rec timestamptz) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('issue_number',issue,'recorded_at',rec) $$;
-- What a refused call may have written: GRNs, lots, dispatches, dispatch lines, stock movements, saved answers.
CREATE FUNCTION pg_temp.rt_counts() RETURNS text LANGUAGE sql AS $$
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
SELECT pg_temp.rt_login('9888888971') AS admin_claims \gset
SELECT pg_temp.rt_login('9888888972') AS supervisor_claims \gset
SELECT pg_temp.rt_login('9888888973') AS staff_claims \gset
SELECT pg_temp.rt_login('9888888974') AS customer_claims \gset
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
SELECT pg_temp.rt_assert((SELECT count(*) FROM public.goodsreceived) = 0 AND (SELECT count(*) FROM public.dispatch) = 0,
  'the numbers below count from empty document tables');

-- Numbers are typed here (rule free) so each case names its own documents.
SELECT pg_temp.rt_rule('grn', '{"scheme":"free"}') AS _ \gset
SELECT pg_temp.rt_rule('dispatch', '{"scheme":"free"}') AS _ \gset

-- ===========================================================================
-- T1. The recorded time is stored beside the server's time, on both documents, exactly as sent.
-- ===========================================================================
SELECT now()-interval '2 hours' AS rec1 \gset
SELECT pg_temp.rt_grn(:'admin_claims'::jsonb,'RT-G1',:'ca'::uuid,'Offline Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rt_line(:'potatoes','Offline Potatoes','Bag',100,50)),'rt-g1',false,:'rec1'::timestamptz) AS g1 \gset
SELECT pg_temp.rt_assert(:'g1'::jsonb->>'success'='true' AND (SELECT recorded_at = :'rec1'::timestamptz AND created_at = now() AND recorded_at <> created_at
    FROM public.goodsreceived WHERE gr_no='RT-G1'),
  'T1 a GRN keeps the time it was recorded on the phone beside the time the server saved it: '||:'g1');
SELECT t.id AS lot_a FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='RT-G1' \gset
SELECT pg_temp.rt_disp(:'admin_claims'::jsonb,pg_temp.rt_ddata(:'ca'::uuid,'Offline Customer A','RT-D1','GJ 01 AB 1111',pg_temp.rt_off(false,:'rec1'::timestamptz)),
  ARRAY[pg_temp.rt_dline(:'lot_a'::uuid,5)],'rt-d1') AS d1 \gset
SELECT pg_temp.rt_assert(:'d1'::jsonb->>'success'='true' AND (SELECT recorded_at = :'rec1'::timestamptz AND created_at = now() AND recorded_at <> created_at
    FROM public.dispatch WHERE disp_no='RT-D1'),
  'T1 a dispatch keeps its recorded time beside the server time: '||:'d1');

-- ===========================================================================
-- T2. A time more than 5 minutes ahead of the server is refused and writes nothing; 4 minutes ahead is accepted (clock drift).
-- ===========================================================================
SELECT pg_temp.rt_counts() AS counts_a \gset
SELECT pg_temp.rt_grn(:'admin_claims'::jsonb,'RT-G2',:'cb'::uuid,'Offline Customer B','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rt_line(:'onions','Offline Onions','Bag',10,30)),'rt-g2x',false,now()+interval '6 minutes') AS g2_future \gset
SELECT pg_temp.rt_assert(:'g2_future'::jsonb->>'success'='false' AND :'g2_future'::jsonb->>'reason'='RECORDED_TIME_FUTURE' AND pg_temp.rt_counts()=:'counts_a',
  'T2 a GRN recorded 6 minutes ahead of the server is refused RECORDED_TIME_FUTURE, nothing written: '||:'g2_future');
SELECT pg_temp.rt_disp(:'admin_claims'::jsonb,pg_temp.rt_ddata(:'ca'::uuid,'Offline Customer A','RT-D2','GJ 01 AB 1111',pg_temp.rt_off(false,now()+interval '6 minutes')),
  ARRAY[pg_temp.rt_dline(:'lot_a'::uuid,5)],'rt-d2x') AS d2_future \gset
SELECT pg_temp.rt_assert(:'d2_future'::jsonb->>'success'='false' AND :'d2_future'::jsonb->>'reason'='RECORDED_TIME_FUTURE' AND pg_temp.rt_counts()=:'counts_a',
  'T2 a dispatch recorded 6 minutes ahead is refused RECORDED_TIME_FUTURE, nothing written: '||:'d2_future');
SELECT pg_temp.rt_grn(:'admin_claims'::jsonb,'RT-G2',:'cb'::uuid,'Offline Customer B','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rt_line(:'onions','Offline Onions','Bag',10,30)),'rt-g2',false,now()+interval '4 minutes') AS g2_near \gset
SELECT pg_temp.rt_assert(:'g2_near'::jsonb->>'success'='true','T2 a GRN recorded 4 minutes ahead is saved: '||:'g2_near');
SELECT pg_temp.rt_disp(:'admin_claims'::jsonb,pg_temp.rt_ddata(:'ca'::uuid,'Offline Customer A','RT-D2','GJ 01 AB 1111',pg_temp.rt_off(false,now()+interval '4 minutes')),
  ARRAY[pg_temp.rt_dline(:'lot_a'::uuid,5)],'rt-d2') AS d2_near \gset
SELECT pg_temp.rt_assert(:'d2_near'::jsonb->>'success'='true','T2 a dispatch recorded 4 minutes ahead is saved: '||:'d2_near');
-- The document date rules stay: a GRN dated tomorrow is still refused although its recorded time is fine.
SELECT pg_temp.rt_grn(:'admin_claims'::jsonb,'RT-G3',:'cb'::uuid,'Offline Customer B',to_char(now()+interval '2 days','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  jsonb_build_array(pg_temp.rt_line(:'onions','Offline Onions','Bag',10,30)),'rt-g3',false,now()-interval '1 minute') AS g3_date \gset
SELECT pg_temp.rt_assert(:'g3_date'::jsonb->>'success'='false' AND :'g3_date'::jsonb->>'reason'='GRN_DATE_FUTURE' AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='RT-G3'),
  'T2 a GRN dated in the future is still refused GRN_DATE_FUTURE: '||:'g3_date');

-- ===========================================================================
-- T3. A save without a recorded time stores none.
-- ===========================================================================
SELECT pg_temp.rt_grn(:'admin_claims'::jsonb,'RT-G4',:'cb'::uuid,'Offline Customer B','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rt_line(:'potatoes','Offline Potatoes','Bag',10,50))) AS g4 \gset
SELECT pg_temp.rt_assert(:'g4'::jsonb->>'success'='true' AND (SELECT recorded_at IS NULL FROM public.goodsreceived WHERE gr_no='RT-G4'),
  'T3 an ordinary GRN save has no recorded time: '||:'g4');

-- ===========================================================================
-- T4. Possible duplicate, GRN: the 30 minutes run between the recorded times, not between the arrivals. Every record below arrives in this
--     one transaction (the same server time), so only the recorded time can tell them apart.
-- ===========================================================================
-- Customer C: recorded 3 hours apart, sent together: not a duplicate.
SELECT pg_temp.rt_grn(:'admin_claims'::jsonb,'RT-C1',:'cc'::uuid,'Offline Customer C','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rt_line(:'potatoes','Offline Potatoes','Bag',10,50)),'rt-c1',false,now()-interval '5 hours',true) AS c1 \gset
SELECT pg_temp.rt_grn(:'staff_claims'::jsonb,'RT-C2',:'cc'::uuid,'Offline Customer C','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rt_line(:'potatoes','Offline Potatoes','Bag',10,50)),'rt-c2',false,now()-interval '2 hours',true) AS c2 \gset
SELECT pg_temp.rt_assert(:'c1'::jsonb->>'success'='true' AND :'c2'::jsonb->>'success'='true' AND NOT :'c2'::jsonb ? 'reason',
  'T4 two GRNs recorded 3 hours apart and sent together are not a possible duplicate: '||:'c2');
-- Customer D: recorded 10 minutes apart, the first one saved by the server 3 hours ago: a possible duplicate.
SELECT pg_temp.rt_grn(:'admin_claims'::jsonb,'RT-D1',:'cd'::uuid,'Offline Customer D','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rt_line(:'potatoes','Offline Potatoes','Bag',10,50)),'rt-dd1',false,now()-interval '4 hours',true) AS dd1 \gset
UPDATE public.goodsreceived SET created_at = now()-interval '3 hours' WHERE gr_no='RT-D1';
SELECT pg_temp.rt_counts() AS counts_b \gset
SELECT pg_temp.rt_grn(:'staff_claims'::jsonb,'RT-D2',:'cd'::uuid,'Offline Customer D','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rt_line(:'potatoes','Offline Potatoes','Bag',10,50)),'rt-dd2',false,now()-interval '3 hours 50 minutes',true) AS dd2 \gset
SELECT pg_temp.rt_assert(:'dd2'::jsonb->>'success'='false' AND :'dd2'::jsonb->>'reason'='POSSIBLE_DUPLICATE' AND :'dd2'::jsonb->>'existing_number'='RT-D1'
  AND pg_temp.rt_counts()=:'counts_b',
  'T4 a GRN recorded 10 minutes after another one is a possible duplicate even when the server saved the other 3 hours ago: '||:'dd2');
-- Customer E: the edges of the window, measured on the recorded times (29 minutes warns, 31 does not).
SELECT pg_temp.rt_grn(:'admin_claims'::jsonb,'RT-E1',:'ce'::uuid,'Offline Customer E','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rt_line(:'potatoes','Offline Potatoes','Bag',10,50)),'rt-e1',false,now()-interval '6 hours',true) AS e1 \gset
SELECT pg_temp.rt_grn(:'staff_claims'::jsonb,'RT-E2',:'ce'::uuid,'Offline Customer E','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rt_line(:'potatoes','Offline Potatoes','Bag',10,50)),'rt-e2',false,now()-interval '6 hours'+interval '29 minutes',true) AS e2 \gset
SELECT pg_temp.rt_grn(:'staff_claims'::jsonb,'RT-E3',:'ce'::uuid,'Offline Customer E','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rt_line(:'potatoes','Offline Potatoes','Bag',10,50)),'rt-e3',false,now()-interval '6 hours'+interval '31 minutes',true) AS e3 \gset
SELECT pg_temp.rt_assert(:'e2'::jsonb->>'reason'='POSSIBLE_DUPLICATE' AND :'e2'::jsonb->>'existing_number'='RT-E1' AND :'e3'::jsonb->>'success'='true',
  'T4 29 minutes between recorded times warns, 31 does not: '||:'e2'||:'e3');
-- A save with no recorded time is judged by its arrival, as before: RT-E3 arrived a moment ago, so an ordinary save of the same set warns.
SELECT pg_temp.rt_grn(:'staff_claims'::jsonb,'RT-E4',:'ce'::uuid,'Offline Customer E','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rt_line(:'potatoes','Offline Potatoes','Bag',10,50)),'rt-e4',NULL,NULL,true) AS e4 \gset
SELECT pg_temp.rt_assert(:'e4'::jsonb->>'reason'='POSSIBLE_DUPLICATE',
  'T4 an ordinary save is still measured from the arrival: it meets RT-E3, which arrived a moment ago: '||:'e4');

-- ===========================================================================
-- T5. Possible duplicate, dispatch: the same, on the recorded times.
-- ===========================================================================
SELECT pg_temp.rt_grn(:'admin_claims'::jsonb,'RT-P1',:'cf'::uuid,'Offline Customer F','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rt_line(:'potatoes','Offline Potatoes','Bag',100,50)),'rt-p1',false,now()-interval '9 hours') AS p1 \gset
SELECT t.id AS lot_f FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='RT-P1' \gset
-- Recorded 3 hours apart, sent together: not a duplicate.
SELECT pg_temp.rt_disp(:'admin_claims'::jsonb,pg_temp.rt_ddata(:'cf'::uuid,'Offline Customer F','RT-F1','GJ 01 AB 1111',pg_temp.rt_off(false,now()-interval '5 hours')||'{"warn_duplicate":true}'),
  ARRAY[pg_temp.rt_dline(:'lot_f'::uuid,5)],'rt-f1') AS f1 \gset
SELECT pg_temp.rt_disp(:'staff_claims'::jsonb,pg_temp.rt_ddata(:'cf'::uuid,'Offline Customer F','RT-F2','gj-01-ab 1111',pg_temp.rt_off(false,now()-interval '2 hours')||'{"warn_duplicate":true}'),
  ARRAY[pg_temp.rt_dline(:'lot_f'::uuid,5)],'rt-f2') AS f2 \gset
SELECT pg_temp.rt_assert(:'f1'::jsonb->>'success'='true' AND :'f2'::jsonb->>'success'='true',
  'T5 two dispatches of the same lots and vehicle recorded 3 hours apart and sent together are not a possible duplicate: '||:'f1'||:'f2');
-- Recorded 10 minutes apart, the first saved by the server 3 hours ago: a possible duplicate.
SELECT pg_temp.rt_grn(:'admin_claims'::jsonb,'RT-P2',:'cg'::uuid,'Offline Customer G','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.rt_line(:'potatoes','Offline Potatoes','Bag',100,50)),'rt-p2',false,now()-interval '9 hours') AS p2 \gset
SELECT t.id AS lot_g FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='RT-P2' \gset
SELECT pg_temp.rt_disp(:'admin_claims'::jsonb,pg_temp.rt_ddata(:'cg'::uuid,'Offline Customer G','RT-G1D','GJ 02 CD 2222',pg_temp.rt_off(false,now()-interval '4 hours')||'{"warn_duplicate":true}'),
  ARRAY[pg_temp.rt_dline(:'lot_g'::uuid,5)],'rt-g1d') AS g1d \gset
UPDATE public.dispatch SET created_at = now()-interval '3 hours' WHERE disp_no='RT-G1D';
SELECT pg_temp.rt_counts() AS counts_c \gset
SELECT pg_temp.rt_disp(:'staff_claims'::jsonb,pg_temp.rt_ddata(:'cg'::uuid,'Offline Customer G','RT-G2D','GJ 02 CD 2222',pg_temp.rt_off(false,now()-interval '3 hours 50 minutes')||'{"warn_duplicate":true}'),
  ARRAY[pg_temp.rt_dline(:'lot_g'::uuid,5)],'rt-g2d') AS g2d \gset
SELECT pg_temp.rt_assert(:'g1d'::jsonb->>'success'='true' AND :'g2d'::jsonb->>'success'='false' AND :'g2d'::jsonb->>'reason'='POSSIBLE_DUPLICATE'
  AND :'g2d'::jsonb->>'existing_number'='RT-G1D' AND pg_temp.rt_counts()=:'counts_c',
  'T5 a dispatch recorded 10 minutes after another one is a possible duplicate even when the server saved the other 3 hours ago: '||:'g2d');

ROLLBACK;
