-- Migration 124: the "possible duplicate" WARNING on GRN create (save_grn) and on direct dispatch create. It is OPT-IN: it runs only
-- when the caller sends p_warn_duplicate = true (save_grn) or warn_duplicate = true (the dispatch data). Each case has a result a
-- broken function would not give. The helpers below send the flag true unless a case says otherwise (as the app does on a normal
-- create); dw_save_plain / dw_disp_plain send none (an older app, fas-sync).
--   G1  a flagged GRN with the same customer, day and SET of (item, packaging) as a live GRN of the last 30 minutes, by another
--       person, is answered POSSIBLE_DUPLICATE with every field; quantity, weight, line order and a repeated line are ignored; nothing is written
--   G2  packaging is compared trimmed and in one case
--   G3  the day is the business day (Asia/Kolkata): another time of the same day warns, 00:30 of the next day does not
--   G4  a subset, a superset and another customer do not warn
--   G5  opt-in: no flag, NULL and false save the same set, true warns; one save_grn overload with the same argument names and grants
--   G6  the GRN number refusal and a resend of a saved request come before the warning; the warning is not stored under the key
--   G7  the 30 minute window (29 warns, 31 does not), the newest of several matches is reported, a deleted GRN does not warn
--   G8  a creator without a name gives existing_created_by null; a malformed line is not turned into a warning or an exception
--   D1  a direct dispatch with the same customer, SET of lots and vehicle (other spacing and case) is answered POSSIBLE_DUPLICATE
--   D2  another vehicle, a subset of lots and a superset of lots do not warn; opt-in: no flag and warn_duplicate false save, true warns
--   D3  NUMBER_TAKEN and insufficient stock come before the warning; both signatures; a resend of a saved request is not warned
--   D4  a dispatch from an order never warns, and is itself the match of a later direct dispatch (the newest is reported)
--   D5  the 30 minute window and a deleted dispatch
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database. Everything rolls back at the end.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.dw_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'duplicate warning 124: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.dw_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.dw_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.dw_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- One GRN line.
CREATE FUNCTION pg_temp.dw_line(item uuid, name text, pack text, qty integer, weight integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('item_id',item,'item_name',name,'packaging',pack,'qty',qty,'weight',weight) $$;
-- save_grn as the person of the claims, asking for the warning (p_warn_duplicate = true), as the app does on a normal create.
CREATE FUNCTION pg_temp.dw_save(claims jsonb, no text, cust uuid, cname text, day text, items jsonb, key text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb;
 BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  SET LOCAL ROLE authenticated;
  r:=public.save_grn(p_gr_no=>no,p_date=>day::timestamptz,p_customer_id=>cust,p_customer_name=>cname,p_pricing_mode=>'MONTHLY',p_items=>items,p_idempotency_key=>key,p_warn_duplicate=>true);
  RESET ROLE;
  RETURN r;
 END $$;
-- The same call without the parameter, the way an older app or fas-sync calls it.
CREATE FUNCTION pg_temp.dw_save_plain(claims jsonb, no text, cust uuid, cname text, day text, items jsonb, key text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb;
 BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  SET LOCAL ROLE authenticated;
  r:=public.save_grn(p_gr_no=>no,p_date=>day::timestamptz,p_customer_id=>cust,p_customer_name=>cname,p_pricing_mode=>'MONTHLY',p_items=>items,p_idempotency_key=>key);
  RESET ROLE;
  RETURN r;
 END $$;
-- The same with p_warn_duplicate sent as given (true, false or NULL).
CREATE FUNCTION pg_temp.dw_save_warn(claims jsonb, no text, cust uuid, cname text, day text, items jsonb, warn boolean, key text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb;
 BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  SET LOCAL ROLE authenticated;
  r:=public.save_grn(p_gr_no=>no,p_date=>day::timestamptz,p_customer_id=>cust,p_customer_name=>cname,p_pricing_mode=>'MONTHLY',p_items=>items,p_idempotency_key=>key,p_warn_duplicate=>warn);
  RESET ROLE;
  RETURN r;
 END $$;
-- Dispatch data for a customer; the supervisor is the administrator.
CREATE FUNCTION pg_temp.dw_ddata(cust uuid, cname text, no text, reg text, extra jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('disp_no',no,'disp_date','2026-05-02','customer_id',cust,'customer_name',cname,
    'supervisor_id',(SELECT id FROM public.user_profiles WHERE name='Dup Administrator'),'supervisor_name','Dup Administrator','registration',reg) || extra $$;
CREATE FUNCTION pg_temp.dw_dline(lot uuid, qty integer) RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('gr_trl_id',lot,'disp_qty',qty) $$;
-- create_dispatch_with_stock_check (4 arguments) as the person of the claims, asking for the warning (warn_duplicate = true in the data,
-- unless the data already carries the key).
CREATE FUNCTION pg_temp.dw_disp(claims jsonb, data jsonb, items jsonb[], key text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb;
 BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  SET LOCAL ROLE authenticated;
  r:=public.create_dispatch_with_stock_check(CASE WHEN data ? 'warn_duplicate' THEN data ELSE data||'{"warn_duplicate":true}'::jsonb END,items,0,key);
  RESET ROLE;
  RETURN r;
 END $$;
-- The same with the data exactly as given (no flag added): an older app, fas-sync.
CREATE FUNCTION pg_temp.dw_disp_plain(claims jsonb, data jsonb, items jsonb[], key text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb;
 BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  SET LOCAL ROLE authenticated;
  r:=public.create_dispatch_with_stock_check(data,items,0,key);
  RESET ROLE;
  RETURN r;
 END $$;
-- The signature with p_generate_invoice (5 arguments), asking for the warning.
CREATE FUNCTION pg_temp.dw_disp5(claims jsonb, data jsonb, items jsonb[], key text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE r jsonb;
 BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  SET LOCAL ROLE authenticated;
  r:=public.create_dispatch_with_stock_check(data||'{"warn_duplicate":true}'::jsonb,items,false,0,key);
  RESET ROLE;
  RETURN r;
 END $$;
-- Writes of a refused call: the number of GRNs, dispatches, stock movements and saved answers.
CREATE FUNCTION pg_temp.dw_counts() RETURNS text LANGUAGE sql AS $$
  SELECT (SELECT count(*) FROM public.goodsreceived)||'/'||(SELECT count(*) FROM public.goodsreceived_trl)||'/'||(SELECT count(*) FROM public.dispatch)
    ||'/'||(SELECT count(*) FROM public.dispatch_trl)||'/'||(SELECT count(*) FROM public.stock_movements)||'/'||(SELECT count(*) FROM public.idempotency_keys) $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888941','Dup Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888942','Dup Staff','staff',true,'approved');
SELECT pg_temp.dw_login('9888888941') AS admin_claims \gset
SELECT pg_temp.dw_login('9888888942') AS staff_claims \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT id AS staff_profile FROM public.user_profiles WHERE name='Dup Staff' \gset
INSERT INTO public.customers(name,mobile) VALUES
 ('Dup Customer A','9888888951'),('Dup Customer B','9888888952'),('Dup Customer C','9888888953'),('Dup Customer D','9888888954'),
 ('Dup Customer E','9888888955'),('Dup Customer F','9888888956'),('Dup Customer G','9888888957'),
 ('Dup Customer P','9888888961'),('Dup Customer Q','9888888962'),('Dup Customer R','9888888963'),('Dup Customer S','9888888964');
SELECT id AS ca FROM public.customers WHERE name='Dup Customer A' \gset
SELECT id AS cb FROM public.customers WHERE name='Dup Customer B' \gset
SELECT id AS cc FROM public.customers WHERE name='Dup Customer C' \gset
SELECT id AS cd FROM public.customers WHERE name='Dup Customer D' \gset
SELECT id AS ce FROM public.customers WHERE name='Dup Customer E' \gset
SELECT id AS cf FROM public.customers WHERE name='Dup Customer F' \gset
SELECT id AS cg FROM public.customers WHERE name='Dup Customer G' \gset
SELECT id AS cp FROM public.customers WHERE name='Dup Customer P' \gset
SELECT id AS cq FROM public.customers WHERE name='Dup Customer Q' \gset
SELECT id AS cr FROM public.customers WHERE name='Dup Customer R' \gset
SELECT id AS cs FROM public.customers WHERE name='Dup Customer S' \gset
INSERT INTO public.items(name,packaging) VALUES ('Dup Potatoes','Bag'),('Dup Onions','Bag'),('Dup Garlic','Bag');
SELECT id AS potatoes FROM public.items WHERE name='Dup Potatoes' \gset
SELECT id AS onions FROM public.items WHERE name='Dup Onions' \gset
SELECT id AS garlic FROM public.items WHERE name='Dup Garlic' \gset

-- ===========================================================================
-- G1. Customer A, day 2026-04-01: the administrator saves DUPA1 (potatoes 10 bags of 50 kg, onions 5 bags of 30 kg).
-- ===========================================================================
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPA1',:'ca'::uuid,'Dup Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',10,50),pg_temp.dw_line(:'onions','Dup Onions','Bag',5,30)),'dw-a1') AS a1 \gset
SELECT pg_temp.dw_assert(:'a1'::jsonb->>'success'='true','fixture: the first GRN of A is saved (nothing to warn about): '||:'a1');
SELECT id AS grn_a1, created_at AS a1_created FROM public.goodsreceived WHERE gr_no='DUPA1' \gset
-- Staff saves the same set again: other quantities and weights, the lines in the other order, potatoes twice, a name the person did not take from the list.
SELECT pg_temp.dw_counts() AS counts0 \gset
SELECT pg_temp.dw_save(:'staff_claims'::jsonb,'DUPA2',:'ca'::uuid,'Dup Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'onions','Dup Onions','Bag',99,1),pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',1,999),pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',3,7)),'dw-a2') AS a2 \gset
SELECT pg_temp.dw_assert(:'a2'::jsonb->>'success'='false' AND :'a2'::jsonb->>'reason'='POSSIBLE_DUPLICATE' AND :'a2'::jsonb->>'error_code'='WH409',
  'G1 shape: success false, error_code WH409, reason POSSIBLE_DUPLICATE: '||:'a2');
SELECT pg_temp.dw_assert(:'a2'::jsonb->>'kind'='grn' AND (:'a2'::jsonb->>'existing_id')::uuid=:'grn_a1'::uuid AND :'a2'::jsonb->>'existing_number'='DUPA1'
  AND (:'a2'::jsonb->>'existing_created_at')::timestamptz=:'a1_created'::timestamptz AND :'a2'::jsonb->>'existing_created_by'='Dup Administrator'
  AND :'a2'::jsonb->>'customer_name'='Dup Customer A' AND (:'a2'::jsonb->>'window_minutes')::int=30,
  'G1 fields: kind, existing id, number, created_at, created_by (the administrator, not the caller), customer name, window: '||:'a2');
SELECT pg_temp.dw_assert(:'a2'::jsonb->'items'='[{"item_name":"Dup Onions","packaging":"Bag"},{"item_name":"Dup Potatoes","packaging":"Bag"}]'::jsonb
  AND NOT :'a2'::jsonb ? 'vehicle','G1 items: the set of the existing GRN, by name, no vehicle: '||:'a2');
SELECT pg_temp.dw_assert(:'a2'::jsonb->>'message'='GRN DUPA1 for Dup Customer A was created just now with the same items.' AND :'a2'::jsonb->>'error'=:'a2'::jsonb->>'message',
  'G1 sentence: '||:'a2');
SELECT pg_temp.dw_assert(pg_temp.dw_counts()=:'counts0' AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='DUPA2')
  AND NOT EXISTS (SELECT 1 FROM public.idempotency_keys WHERE idempotency_key='dw-a2'),
  'G1 the refused call wrote nothing: no GRN, no line, no saved answer ('||:'counts0'||' then '||pg_temp.dw_counts()||')');

-- G2. Packaging: " bag " and "BAG" are the same packaging as "Bag".
SELECT pg_temp.dw_save(:'staff_claims'::jsonb,'DUPA2',:'ca'::uuid,'Dup Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','  BAG ',1,1),pg_temp.dw_line(:'onions','Dup Onions','bag',1,1))) AS g2 \gset
SELECT pg_temp.dw_assert(:'g2'::jsonb->>'reason'='POSSIBLE_DUPLICATE' AND :'g2'::jsonb->>'existing_number'='DUPA1','G2 packaging in another case and with spaces still matches: '||:'g2');
-- ... but another packaging is another line.
SELECT pg_temp.dw_save(:'staff_claims'::jsonb,'DUPA2X',:'ca'::uuid,'Dup Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Sack',1,1),pg_temp.dw_line(:'onions','Dup Onions','Bag',1,1))) AS g2b \gset
SELECT pg_temp.dw_assert(:'g2b'::jsonb->>'success'='true','G2 another packaging for one item is another set and saves: '||:'g2b');

-- G3. The day. DUPA1 was dated 2026-04-01T12:00Z (17:30 IST). 02:00Z is 07:30 IST the same day: warns. 19:00Z is 00:30 IST on 04-02: saves.
SELECT pg_temp.dw_save(:'staff_claims'::jsonb,'DUPA2',:'ca'::uuid,'Dup Customer A','2026-04-01T02:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',1,1),pg_temp.dw_line(:'onions','Dup Onions','Bag',1,1))) AS g3a \gset
SELECT pg_temp.dw_assert(:'g3a'::jsonb->>'reason'='POSSIBLE_DUPLICATE','G3 another time of the same business day warns: '||:'g3a');
SELECT pg_temp.dw_save(:'staff_claims'::jsonb,'DUPA3',:'ca'::uuid,'Dup Customer A','2026-04-01T19:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',1,1),pg_temp.dw_line(:'onions','Dup Onions','Bag',1,1))) AS g3b \gset
SELECT pg_temp.dw_assert(:'g3b'::jsonb->>'success'='true','G3 00:30 IST of the next day is another GRN day and saves: '||:'g3b');

-- G4. A subset, a superset and another customer.
SELECT pg_temp.dw_save(:'staff_claims'::jsonb,'DUPA4',:'ca'::uuid,'Dup Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',10,50))) AS g4a \gset
SELECT pg_temp.dw_save(:'staff_claims'::jsonb,'DUPA5',:'ca'::uuid,'Dup Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',10,50),pg_temp.dw_line(:'onions','Dup Onions','Bag',5,30),pg_temp.dw_line(:'garlic','Dup Garlic','Bag',2,20))) AS g4b \gset
SELECT pg_temp.dw_save(:'staff_claims'::jsonb,'DUPB1',:'cb'::uuid,'Dup Customer B','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',10,50),pg_temp.dw_line(:'onions','Dup Onions','Bag',5,30))) AS g4c \gset
SELECT pg_temp.dw_assert(:'g4a'::jsonb->>'success'='true' AND :'g4b'::jsonb->>'success'='true' AND :'g4c'::jsonb->>'success'='true',
  'G4 a subset, a superset and the same set for another customer all save: '||:'g4a'||:'g4b'||:'g4c');

-- G5. Opt-in. Customer A has DUPA1 {potatoes, onions} live and new. A call without the parameter (an older app, fas-sync), with NULL and with
-- false saves the same set; only true warns.
SELECT pg_temp.dw_save_plain(:'staff_claims'::jsonb,'DUPA6',:'ca'::uuid,'Dup Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',1,1),pg_temp.dw_line(:'onions','Dup Onions','Bag',1,1))) AS g5a \gset
SELECT pg_temp.dw_save_warn(:'staff_claims'::jsonb,'DUPA7',:'ca'::uuid,'Dup Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',1,1),pg_temp.dw_line(:'onions','Dup Onions','Bag',1,1)),NULL) AS g5b \gset
SELECT pg_temp.dw_save_warn(:'staff_claims'::jsonb,'DUPA8',:'ca'::uuid,'Dup Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',1,1),pg_temp.dw_line(:'onions','Dup Onions','Bag',1,1)),false) AS g5c \gset
SELECT pg_temp.dw_assert(:'g5a'::jsonb->>'success'='true' AND :'g5b'::jsonb->>'success'='true' AND :'g5c'::jsonb->>'success'='true'
  AND NOT :'g5a'::jsonb ? 'reason' AND NOT :'g5b'::jsonb ? 'reason' AND NOT :'g5c'::jsonb ? 'reason'
  AND (SELECT count(*)=3 FROM public.goodsreceived WHERE gr_no IN ('DUPA6','DUPA7','DUPA8') AND deleted_at IS NULL),
  'G5 without the flag, with NULL and with false the same set saves (no warning is asked for): '||:'g5a'||:'g5b'||:'g5c');
SELECT pg_temp.dw_save_warn(:'staff_claims'::jsonb,'DUPA9',:'ca'::uuid,'Dup Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',1,1),pg_temp.dw_line(:'onions','Dup Onions','Bag',1,1)),true) AS g5d \gset
SELECT pg_temp.dw_assert(:'g5d'::jsonb->>'reason'='POSSIBLE_DUPLICATE' AND :'g5d'::jsonb->>'kind'='grn' AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='DUPA9'),
  'G5 with p_warn_duplicate true the same set warns and writes nothing: '||:'g5d');
SELECT pg_temp.dw_assert((SELECT count(*)=4 FROM public.goodsreceived g WHERE g.customer_id=:'ca'::uuid AND g.gr_no IN ('DUPA1','DUPA6','DUPA7','DUPA8')),
  'G5 fixture: A holds four GRNs of the set');
-- One save_grn (PostgREST must not see two), with the new trailing parameter, owned and granted as before.
SELECT pg_temp.dw_assert((SELECT count(*)=1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='save_grn'),'G5 exactly one public.save_grn');
SELECT pg_temp.dw_assert((SELECT pg_get_function_arguments(oid) LIKE '%p_rates jsonb DEFAULT NULL::jsonb, p_warn_duplicate boolean DEFAULT false'
  AND pg_get_function_arguments(oid) NOT LIKE '%p_warn_duplicate%p_warn_duplicate%' FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='save_grn'),
  'G5 p_warn_duplicate boolean DEFAULT false is the last parameter, after p_rates');
SELECT pg_temp.dw_assert((SELECT pg_get_function_identity_arguments(oid) LIKE 'p_gr_no character varying, p_date timestamp with time zone, p_customer_id uuid, p_customer_name character varying, p_sender_id uuid, p_sender_name character varying, p_supervisor_id uuid, p_supervisor_name character varying, p_registration character varying, p_note character varying, p_leon boolean, p_pricing_mode character varying, p_items jsonb, p_images jsonb, p_idempotency_key text, p_duration_mode character varying, p_rates jsonb, p_warn_duplicate boolean'
    FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='save_grn'),'G5 every argument of save_grn keeps its name and position (fas-sync calls them by name)');
SELECT pg_temp.dw_assert((SELECT prosecdef AND pg_get_userbyid(proowner)='supabase_admin'
    AND proconfig @> ARRAY['search_path=pg_catalog, public, extensions, utils, pg_temp','jit=off'] FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='save_grn'),
  'G5 save_grn is SECURITY DEFINER, owned by supabase_admin, with its search_path and jit setting');
SELECT pg_temp.dw_assert((SELECT has_function_privilege('authenticated',oid,'EXECUTE') AND has_function_privilege('service_role',oid,'EXECUTE')
    AND NOT has_function_privilege('anon',oid,'EXECUTE') AND NOT has_function_privilege('public',oid,'EXECUTE') FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='save_grn'),
  'G5 save_grn is executable by authenticated and service_role only');
SELECT pg_temp.dw_assert((SELECT NOT has_function_privilege('authenticated',oid,'EXECUTE') AND NOT has_function_privilege('anon',oid,'EXECUTE') FROM pg_proc WHERE proname='possible_duplicate_grn'
    AND pronamespace='warehouse_security'::regnamespace)
  AND (SELECT NOT has_function_privilege('authenticated',oid,'EXECUTE') AND NOT has_function_privilege('anon',oid,'EXECUTE') FROM pg_proc WHERE proname='possible_duplicate_dispatch'
    AND pronamespace='warehouse_security'::regnamespace),'G5 the two lookups are not granted to any API role');

-- G6. The number refusal and the saved answer come before the warning.
SELECT pg_temp.dw_save(:'staff_claims'::jsonb,'DUPA1',:'ca'::uuid,'Dup Customer A','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',1,1),pg_temp.dw_line(:'onions','Dup Onions','Bag',1,1))) AS g6a \gset
SELECT pg_temp.dw_assert(:'g6a'::jsonb->>'success'='false' AND :'g6a'::jsonb->>'message'='GRN number already exists: DUPA1' AND NOT :'g6a'::jsonb ? 'reason',
  'G6 a taken number is refused as before, not warned about: '||:'g6a');
-- Customer C: potatoes only. The first save is stored under the key; the identical resend returns the stored answer although the GRN it made is
-- itself a match; another key with the same body warns, and the warning is not stored; the override with that key saves.
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPC1',:'cc'::uuid,'Dup Customer C','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',10,50)),'dw-c1') AS c1 \gset
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPC1',:'cc'::uuid,'Dup Customer C','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',10,50)),'dw-c1') AS c1_again \gset
SELECT pg_temp.dw_assert(:'c1'::jsonb->>'success'='true' AND :'c1_again'::jsonb->>'success'='true' AND (:'c1_again'::jsonb->>'idempotent')::boolean
  AND :'c1_again'::jsonb#>>'{data,grn_id}'=:'c1'::jsonb#>>'{data,grn_id}' AND NOT :'c1_again'::jsonb ? 'reason',
  'G6 a resend of a saved request returns the stored answer, not the warning: '||:'c1_again');
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPC2',:'cc'::uuid,'Dup Customer C','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',10,50)),'dw-c2') AS c2 \gset
SELECT pg_temp.dw_assert(:'c2'::jsonb->>'reason'='POSSIBLE_DUPLICATE' AND :'c2'::jsonb->>'existing_number'='DUPC1'
  AND NOT EXISTS (SELECT 1 FROM public.idempotency_keys WHERE idempotency_key='dw-c2'),'G6 the same body under another key warns, and the warning is not stored under the key: '||:'c2');
SELECT pg_temp.dw_save_warn(:'admin_claims'::jsonb,'DUPC2',:'cc'::uuid,'Dup Customer C','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',10,50)),false,'dw-c2') AS c2_ok \gset
SELECT pg_temp.dw_assert(:'c2_ok'::jsonb->>'success'='true' AND EXISTS (SELECT 1 FROM public.idempotency_keys WHERE idempotency_key='dw-c2' AND rpc_function='save_grn'),
  'G6 confirmed (flag false) the same key saves and stores its answer: '||:'c2_ok');

-- G7. The 30 minutes. Customer D: DUPD1 {potatoes}. Backdated 29 minutes it warns ("29 minutes ago"); backdated 31 it does not.
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPD1',:'cd'::uuid,'Dup Customer D','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',10,50))) AS gd1 \gset
SET LOCAL session_replication_role = replica;
UPDATE public.goodsreceived SET created_at=now()-interval '29 minutes' WHERE gr_no='DUPD1';
SET LOCAL session_replication_role = origin;
SELECT pg_temp.dw_save(:'staff_claims'::jsonb,'DUPD2',:'cd'::uuid,'Dup Customer D','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',1,1))) AS d_29 \gset
SELECT pg_temp.dw_assert(:'d_29'::jsonb->>'reason'='POSSIBLE_DUPLICATE' AND :'d_29'::jsonb->>'message'='GRN DUPD1 for Dup Customer D was created 29 minutes ago with the same items.',
  'G7 a GRN made 29 minutes ago still warns, in minutes: '||:'d_29');
SET LOCAL session_replication_role = replica;
UPDATE public.goodsreceived SET created_at=now()-interval '31 minutes' WHERE gr_no='DUPD1';
SET LOCAL session_replication_role = origin;
SELECT pg_temp.dw_save(:'staff_claims'::jsonb,'DUPD2',:'cd'::uuid,'Dup Customer D','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',1,1))) AS d_31 \gset
SELECT pg_temp.dw_assert(:'d_31'::jsonb->>'success'='true','G7 a GRN made 31 minutes ago does not warn: '||:'d_31');
-- Two matches: DUPD1 (31 minutes, outside the window) and DUPD2 (new). Make DUPD1 20 minutes old and DUPD2 10: the newest, DUPD2, is reported.
SET LOCAL session_replication_role = replica;
UPDATE public.goodsreceived SET created_at=now()-interval '20 minutes' WHERE gr_no='DUPD1';
UPDATE public.goodsreceived SET created_at=now()-interval '10 minutes' WHERE gr_no='DUPD2';
SET LOCAL session_replication_role = origin;
SELECT pg_temp.dw_save(:'staff_claims'::jsonb,'DUPD3',:'cd'::uuid,'Dup Customer D','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',1,1))) AS d_new \gset
SELECT pg_temp.dw_assert(:'d_new'::jsonb->>'existing_number'='DUPD2' AND :'d_new'::jsonb->>'message'='GRN DUPD2 for Dup Customer D was created 10 minutes ago with the same items.'
  AND :'d_new'::jsonb->>'existing_created_by'='Dup Staff','G7 with two matches the newest is reported: '||:'d_new');
-- A deleted GRN does not warn. Customer E: DUPE1 is deleted for good (delete_grn_safe) and the same set saves as DUPE2; DUPE2 is then
-- soft-deleted (deleted_at set) and the same set saves as DUPE3; DUPE3 is live, so DUPE4 warns, naming DUPE3 and not DUPE2.
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPE1',:'ce'::uuid,'Dup Customer E','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',10,50))) AS e1 \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_grn_safe((:'e1'::jsonb#>>'{data,grn_id}')::uuid) AS e1_deleted \gset
RESET ROLE;
SELECT pg_temp.dw_assert(:'e1_deleted'::jsonb->>'success'='true' AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='DUPE1'),'fixture: DUPE1 is deleted: '||:'e1_deleted');
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPE2',:'ce'::uuid,'Dup Customer E','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',10,50))) AS e2 \gset
SELECT pg_temp.dw_assert(:'e2'::jsonb->>'success'='true','G7 a deleted GRN does not warn: '||:'e2');
UPDATE public.goodsreceived SET deleted_at=now(), deleted_by=:'admin_profile'::uuid WHERE gr_no='DUPE2';
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPE3',:'ce'::uuid,'Dup Customer E','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',10,50))) AS e3 \gset
SELECT pg_temp.dw_assert(:'e3'::jsonb->>'success'='true','G7 a soft-deleted GRN does not warn: '||:'e3');
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPE4',:'ce'::uuid,'Dup Customer E','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',10,50))) AS e4 \gset
SELECT pg_temp.dw_assert(:'e4'::jsonb->>'existing_number'='DUPE3','G7 the live GRN warns, not the soft-deleted one: '||:'e4');

-- G8. A creator without a name gives null. Customer G: staff saves DUPG1, then the staff profile loses both names.
SELECT pg_temp.dw_save(:'staff_claims'::jsonb,'DUPG1',:'cg'::uuid,'Dup Customer G','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',10,50))) AS g1 \gset
UPDATE public.user_profiles SET name=NULL, display_name=NULL WHERE id=:'staff_profile'::uuid;
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPG2',:'cg'::uuid,'Dup Customer G','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',10,50))) AS g2n \gset
SELECT pg_temp.dw_assert(:'g2n'::jsonb->>'reason'='POSSIBLE_DUPLICATE' AND :'g2n'::jsonb ? 'existing_created_by' AND jsonb_typeof(:'g2n'::jsonb->'existing_created_by')='null',
  'G8 a creator without a name gives existing_created_by null: '||:'g2n');
UPDATE public.user_profiles SET name='Dup Staff' WHERE id=:'staff_profile'::uuid;
-- A malformed line (an item id that is no uuid) is no warning and no raw error: the save answers as it did before this migration.
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPF1',:'cf'::uuid,'Dup Customer F','2026-04-01T12:00:00Z',
  jsonb_build_array(jsonb_build_object('item_id','not-a-uuid','item_name','Dup Potatoes','packaging','Bag','qty',1,'weight',1))) AS f_bad \gset
SELECT pg_temp.dw_assert(:'f_bad'::jsonb->>'success'='false' AND :'f_bad'::jsonb->>'message' LIKE 'Error creating GRN:%' AND NOT :'f_bad'::jsonb ? 'reason',
  'G8 a malformed line is answered by the save as before, not as a warning: '||:'f_bad');
SELECT pg_temp.dw_assert(NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='DUPF1'),'G8 and writes no GRN');

-- ===========================================================================
-- Dispatch. Customer P holds DUPP1 (potatoes 100 bags, onions 100) and DUPP2 (garlic 100).
-- ===========================================================================
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPP1',:'cp'::uuid,'Dup Customer P','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',100,50),pg_temp.dw_line(:'onions','Dup Onions','Bag',100,30))) AS p1 \gset
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPP2',:'cp'::uuid,'Dup Customer P','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'garlic','Dup Garlic','Bag',100,20))) AS p2 \gset
SELECT pg_temp.dw_assert(:'p1'::jsonb->>'success'='true' AND :'p2'::jsonb->>'success'='true','fixture: P has two receipts');
SELECT t.id AS lot_p FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DUPP1' AND t.item_id=:'potatoes'::uuid \gset
SELECT t.id AS lot_o FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DUPP1' AND t.item_id=:'onions'::uuid \gset
SELECT t.id AS lot_g FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DUPP2' \gset

-- D1. The administrator dispatches 10 bags of each lot of DUPP1 with vehicle "GJ 01 AB 1234".
SELECT pg_temp.dw_disp(:'admin_claims'::jsonb,pg_temp.dw_ddata(:'cp'::uuid,'Dup Customer P','DD1','GJ 01 AB 1234'),
  ARRAY[pg_temp.dw_dline(:'lot_p'::uuid,10),pg_temp.dw_dline(:'lot_o'::uuid,10)],'dw-d1') AS d1 \gset
SELECT pg_temp.dw_assert(:'d1'::jsonb->>'success'='true','fixture: DD1 is saved (nothing to warn about): '||:'d1');
SELECT id AS disp_1, created_at AS dd1_created FROM public.dispatch WHERE disp_no='DD1' \gset
-- Staff dispatches the same lots (other order, 5 bags each) with the vehicle written "gj-01-ab 1234".
SELECT pg_temp.dw_counts() AS dcounts0 \gset
SELECT pg_temp.dw_disp(:'staff_claims'::jsonb,pg_temp.dw_ddata(:'cp'::uuid,'Dup Customer P','DD2','gj-01-ab 1234'),
  ARRAY[pg_temp.dw_dline(:'lot_o'::uuid,5),pg_temp.dw_dline(:'lot_p'::uuid,5)],'dw-d2') AS d2 \gset
SELECT pg_temp.dw_assert(:'d2'::jsonb->>'success'='false' AND :'d2'::jsonb->>'reason'='POSSIBLE_DUPLICATE' AND :'d2'::jsonb->>'error_code'='WH409',
  'D1 shape: success false, error_code WH409, reason POSSIBLE_DUPLICATE: '||:'d2');
SELECT pg_temp.dw_assert(:'d2'::jsonb->>'kind'='dispatch' AND (:'d2'::jsonb->>'existing_id')::uuid=:'disp_1'::uuid AND :'d2'::jsonb->>'existing_number'='DD1'
  AND (:'d2'::jsonb->>'existing_created_at')::timestamptz=:'dd1_created'::timestamptz AND :'d2'::jsonb->>'existing_created_by'='Dup Administrator'
  AND :'d2'::jsonb->>'customer_name'='Dup Customer P' AND :'d2'::jsonb->>'vehicle'='GJ 01 AB 1234' AND (:'d2'::jsonb->>'window_minutes')::int=30,
  'D1 fields: kind, existing id, number, created_at, created_by, customer, the vehicle as stored, window: '||:'d2');
SELECT pg_temp.dw_assert(:'d2'::jsonb->'items'='[{"gr_no":"DUPP1","item_name":"Dup Onions","packaging":"Bag"},{"gr_no":"DUPP1","item_name":"Dup Potatoes","packaging":"Bag"}]'::jsonb,
  'D1 items: the lots of the existing dispatch, by receipt number and name: '||:'d2');
SELECT pg_temp.dw_assert(:'d2'::jsonb->>'message'='Dispatch DD1 for Dup Customer P was created just now with the same lots and vehicle.' AND :'d2'::jsonb->>'error'=:'d2'::jsonb->>'message',
  'D1 sentence: '||:'d2');
SELECT pg_temp.dw_assert(pg_temp.dw_counts()=:'dcounts0' AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no='DD2')
  AND (SELECT stock FROM public.goodsreceived_trl WHERE id=:'lot_p'::uuid)=90 AND (SELECT stock FROM public.goodsreceived_trl WHERE id=:'lot_o'::uuid)=90
  AND NOT EXISTS (SELECT 1 FROM public.idempotency_keys WHERE idempotency_key='dw-d2'),
  'D1 the refused call wrote nothing: no dispatch, no line, no stock movement, stock still 90 and 90, no saved answer ('||:'dcounts0'||' then '||pg_temp.dw_counts()||')');
-- The signature with p_generate_invoice goes through the same function.
SELECT pg_temp.dw_disp5(:'staff_claims'::jsonb,pg_temp.dw_ddata(:'cp'::uuid,'Dup Customer P','DD2','GJ01AB1234'),
  ARRAY[pg_temp.dw_dline(:'lot_p'::uuid,5),pg_temp.dw_dline(:'lot_o'::uuid,5)]) AS d2_5 \gset
SELECT pg_temp.dw_assert(:'d2_5'::jsonb->>'reason'='POSSIBLE_DUPLICATE' AND :'d2_5'::jsonb->>'existing_number'='DD1','D3 the 5-argument signature warns too: '||:'d2_5');

-- D2. Another vehicle, a subset of the lots and a superset do not warn.
SELECT pg_temp.dw_disp(:'staff_claims'::jsonb,pg_temp.dw_ddata(:'cp'::uuid,'Dup Customer P','DD3','GJ 02 ZZ 9999'),
  ARRAY[pg_temp.dw_dline(:'lot_p'::uuid,5),pg_temp.dw_dline(:'lot_o'::uuid,5)]) AS d3 \gset
SELECT pg_temp.dw_disp(:'staff_claims'::jsonb,pg_temp.dw_ddata(:'cp'::uuid,'Dup Customer P','DD4','GJ 01 AB 1234'),
  ARRAY[pg_temp.dw_dline(:'lot_p'::uuid,5)]) AS d4 \gset
SELECT pg_temp.dw_disp(:'staff_claims'::jsonb,pg_temp.dw_ddata(:'cp'::uuid,'Dup Customer P','DD5','GJ 01 AB 1234'),
  ARRAY[pg_temp.dw_dline(:'lot_p'::uuid,5),pg_temp.dw_dline(:'lot_o'::uuid,5),pg_temp.dw_dline(:'lot_g'::uuid,5)]) AS d5 \gset
SELECT pg_temp.dw_assert(:'d3'::jsonb->>'success'='true' AND :'d4'::jsonb->>'success'='true' AND :'d5'::jsonb->>'success'='true',
  'D2 another vehicle, a subset of the lots and a superset of the lots all save: '||:'d3'||:'d4'||:'d5');
-- Opt-in: the lots and vehicle of DD1 again (1 bag each) with no flag (an older app, fas-sync), with warn_duplicate false and with the text
-- "false" all save; with true it warns.
SELECT pg_temp.dw_disp_plain(:'staff_claims'::jsonb,pg_temp.dw_ddata(:'cp'::uuid,'Dup Customer P','DD6','GJ 01 AB 1234'),
  ARRAY[pg_temp.dw_dline(:'lot_p'::uuid,1),pg_temp.dw_dline(:'lot_o'::uuid,1)]) AS d6a \gset
SELECT pg_temp.dw_disp(:'staff_claims'::jsonb,pg_temp.dw_ddata(:'cp'::uuid,'Dup Customer P','DD8','GJ 01 AB 1234','{"warn_duplicate":false}'::jsonb),
  ARRAY[pg_temp.dw_dline(:'lot_p'::uuid,1),pg_temp.dw_dline(:'lot_o'::uuid,1)]) AS d6b \gset
SELECT pg_temp.dw_disp(:'staff_claims'::jsonb,pg_temp.dw_ddata(:'cp'::uuid,'Dup Customer P','DD9','GJ 01 AB 1234','{"warn_duplicate":"false"}'::jsonb),
  ARRAY[pg_temp.dw_dline(:'lot_p'::uuid,1),pg_temp.dw_dline(:'lot_o'::uuid,1)]) AS d6c \gset
SELECT pg_temp.dw_assert(:'d6a'::jsonb->>'success'='true' AND :'d6b'::jsonb->>'success'='true' AND :'d6c'::jsonb->>'success'='true'
  AND (SELECT count(*)=3 FROM public.dispatch WHERE disp_no IN ('DD6','DD8','DD9') AND deleted_at IS NULL),
  'D2 without the flag, with warn_duplicate false and with the text false the same lots and vehicle save: '||:'d6a'||:'d6b'||:'d6c');
SELECT pg_temp.dw_disp(:'staff_claims'::jsonb,pg_temp.dw_ddata(:'cp'::uuid,'Dup Customer P','DD10','GJ 01 AB 1234','{"warn_duplicate":true}'::jsonb),
  ARRAY[pg_temp.dw_dline(:'lot_p'::uuid,1),pg_temp.dw_dline(:'lot_o'::uuid,1)]) AS d6d \gset
SELECT pg_temp.dw_assert(:'d6d'::jsonb->>'reason'='POSSIBLE_DUPLICATE' AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no='DD10'),
  'D2 with warn_duplicate true it warns and writes nothing: '||:'d6d');

-- D3. The number refusal and the stock refusal come before the warning (same lots and vehicle as DD1 in both).
SELECT pg_temp.dw_disp(:'staff_claims'::jsonb,pg_temp.dw_ddata(:'cp'::uuid,'Dup Customer P','DD1','GJ 01 AB 1234'),
  ARRAY[pg_temp.dw_dline(:'lot_p'::uuid,1),pg_temp.dw_dline(:'lot_o'::uuid,1)]) AS d_taken \gset
SELECT pg_temp.dw_assert(:'d_taken'::jsonb->>'reason'='NUMBER_TAKEN' AND :'d_taken'::jsonb->>'number'='DD1','D3 a taken number is refused as NUMBER_TAKEN, not warned about: '||:'d_taken');
SELECT pg_temp.dw_disp(:'staff_claims'::jsonb,pg_temp.dw_ddata(:'cp'::uuid,'Dup Customer P','DD7','GJ 01 AB 1234'),
  ARRAY[pg_temp.dw_dline(:'lot_p'::uuid,9999),pg_temp.dw_dline(:'lot_o'::uuid,1)]) AS d_stock \gset
SELECT pg_temp.dw_assert(:'d_stock'::jsonb->>'success'='false' AND :'d_stock'::jsonb->>'error' LIKE 'Insufficient stock:%' AND NOT :'d_stock'::jsonb ? 'reason',
  'D3 not enough stock is refused as before, not warned about: '||:'d_stock');
-- Customer Q: a first direct dispatch under a key; the identical resend returns the saved answer (it is itself a match); a new key warns.
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPQ1',:'cq'::uuid,'Dup Customer Q','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',100,50))) AS q1 \gset
SELECT t.id AS lot_q FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DUPQ1' \gset
SELECT pg_temp.dw_disp(:'admin_claims'::jsonb,pg_temp.dw_ddata(:'cq'::uuid,'Dup Customer Q','DQ1','GJ 04 QQ 0004'),ARRAY[pg_temp.dw_dline(:'lot_q'::uuid,10)],'dw-q1') AS dq1 \gset
SELECT pg_temp.dw_disp(:'admin_claims'::jsonb,pg_temp.dw_ddata(:'cq'::uuid,'Dup Customer Q','DQ1','GJ 04 QQ 0004'),ARRAY[pg_temp.dw_dline(:'lot_q'::uuid,10)],'dw-q1') AS dq1_again \gset
SELECT pg_temp.dw_assert(:'dq1'::jsonb->>'success'='true' AND :'dq1_again'::jsonb->>'success'='true' AND (:'dq1_again'::jsonb->>'from_cache')::boolean
  AND :'dq1_again'::jsonb->>'dispatch_id'=:'dq1'::jsonb->>'dispatch_id' AND NOT :'dq1_again'::jsonb ? 'reason','D3 a resend of a saved request returns the stored answer, not the warning: '||:'dq1_again');
SELECT pg_temp.dw_disp(:'admin_claims'::jsonb,pg_temp.dw_ddata(:'cq'::uuid,'Dup Customer Q','DQ2','GJ 04 QQ 0004'),ARRAY[pg_temp.dw_dline(:'lot_q'::uuid,10)],'dw-q2') AS dq2 \gset
SELECT pg_temp.dw_assert(:'dq2'::jsonb->>'reason'='POSSIBLE_DUPLICATE' AND :'dq2'::jsonb->>'existing_number'='DQ1' AND NOT EXISTS (SELECT 1 FROM public.idempotency_keys WHERE idempotency_key='dw-q2'),
  'D3 the same body under another key warns, and the warning is not stored under the key: '||:'dq2');

-- D4. From an order. Customer R: DR1 direct (10 bags of each lot, vehicle V), then an order for both lots (20 each) and a dispatch from it, same lots and vehicle.
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPR1',:'cr'::uuid,'Dup Customer R','2026-04-01T12:00:00Z',
  jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',100,50),pg_temp.dw_line(:'onions','Dup Onions','Bag',100,30))) AS r1 \gset
SELECT t.id AS lot_rp FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DUPR1' AND t.item_id=:'potatoes'::uuid \gset
SELECT t.id AS lot_ro FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DUPR1' AND t.item_id=:'onions'::uuid \gset
SELECT pg_temp.dw_disp(:'admin_claims'::jsonb,pg_temp.dw_ddata(:'cr'::uuid,'Dup Customer R','DR1','GJ 03 RR 0003'),ARRAY[pg_temp.dw_dline(:'lot_rp'::uuid,10),pg_temp.dw_dline(:'lot_ro'::uuid,10)]) AS dr1 \gset
SELECT pg_temp.dw_assert(:'dr1'::jsonb->>'success'='true','fixture: DR1 saved: '||:'dr1');
SET LOCAL session_replication_role = replica;
UPDATE public.dispatch SET created_at=now()-interval '5 minutes' WHERE disp_no='DR1';
SET LOCAL session_replication_role = origin;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'cr'::uuid) AS cart_r \gset
SELECT pg_temp.dw_assert(public.add_item_to_order(:'cart_r'::uuid,:'lot_rp'::uuid,20)->>'success'='true' AND public.add_item_to_order(:'cart_r'::uuid,:'lot_ro'::uuid,20)->>'success'='true','fixture: the order lines of R');
RESET ROLE;
SELECT pg_temp.dw_disp(:'admin_claims'::jsonb,pg_temp.dw_ddata(:'cr'::uuid,'Dup Customer R','DR2','GJ 03 RR 0003',jsonb_build_object('source_order_id',:'cart_r')),
  ARRAY[pg_temp.dw_dline(:'lot_rp'::uuid,10),pg_temp.dw_dline(:'lot_ro'::uuid,10)]) AS dr2 \gset
SELECT pg_temp.dw_assert(:'dr2'::jsonb->>'success'='true' AND (:'dr2'::jsonb->>'source_order_cleared')::boolean AND NOT :'dr2'::jsonb ? 'reason',
  'D4 a dispatch from an order never warns (same customer, lots and vehicle as DR1): '||:'dr2');
-- A direct dispatch afterwards matches the newest of DR1 (5 minutes) and DR2 (just now): DR2, which came from an order.
SELECT pg_temp.dw_disp(:'admin_claims'::jsonb,pg_temp.dw_ddata(:'cr'::uuid,'Dup Customer R','DR3','gj 03 rr 0003'),
  ARRAY[pg_temp.dw_dline(:'lot_rp'::uuid,1),pg_temp.dw_dline(:'lot_ro'::uuid,1)]) AS dr3 \gset
SELECT pg_temp.dw_assert(:'dr3'::jsonb->>'reason'='POSSIBLE_DUPLICATE' AND :'dr3'::jsonb->>'existing_number'='DR2','D4 a later direct dispatch matches the newest, which came from an order: '||:'dr3');
SET LOCAL session_replication_role = replica;
UPDATE public.dispatch SET created_at=now()-interval '3 minutes' WHERE disp_no='DR2';
SET LOCAL session_replication_role = origin;
SELECT pg_temp.dw_disp(:'admin_claims'::jsonb,pg_temp.dw_ddata(:'cr'::uuid,'Dup Customer R','DR3','gj 03 rr 0003'),
  ARRAY[pg_temp.dw_dline(:'lot_rp'::uuid,1),pg_temp.dw_dline(:'lot_ro'::uuid,1)]) AS dr3b \gset
SELECT pg_temp.dw_assert(:'dr3b'::jsonb->>'existing_number'='DR2' AND :'dr3b'::jsonb->>'message'='Dispatch DR2 for Dup Customer R was created 3 minutes ago with the same lots and vehicle.',
  'D4 the minutes in the sentence: '||:'dr3b');

-- D5. The window and a deleted dispatch. Customer S: DS1 direct. 29 minutes old it warns; 31 minutes old it does not; a deleted one does not.
SELECT pg_temp.dw_save(:'admin_claims'::jsonb,'DUPS1',:'cs'::uuid,'Dup Customer S','2026-04-01T12:00:00Z',jsonb_build_array(pg_temp.dw_line(:'potatoes','Dup Potatoes','Bag',100,50))) AS s1 \gset
SELECT t.id AS lot_s FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='DUPS1' \gset
SELECT pg_temp.dw_disp(:'admin_claims'::jsonb,pg_temp.dw_ddata(:'cs'::uuid,'Dup Customer S','DS1','GJ 05 SS 0005'),ARRAY[pg_temp.dw_dline(:'lot_s'::uuid,10)]) AS ds1 \gset
SET LOCAL session_replication_role = replica;
UPDATE public.dispatch SET created_at=now()-interval '29 minutes' WHERE disp_no='DS1';
SET LOCAL session_replication_role = origin;
SELECT pg_temp.dw_disp(:'admin_claims'::jsonb,pg_temp.dw_ddata(:'cs'::uuid,'Dup Customer S','DS2','GJ 05 SS 0005'),ARRAY[pg_temp.dw_dline(:'lot_s'::uuid,10)]) AS ds_29 \gset
SELECT pg_temp.dw_assert(:'ds_29'::jsonb->>'reason'='POSSIBLE_DUPLICATE' AND :'ds_29'::jsonb->>'message'='Dispatch DS1 for Dup Customer S was created 29 minutes ago with the same lots and vehicle.',
  'D5 a dispatch made 29 minutes ago still warns: '||:'ds_29');
SET LOCAL session_replication_role = replica;
UPDATE public.dispatch SET created_at=now()-interval '31 minutes' WHERE disp_no='DS1';
SET LOCAL session_replication_role = origin;
SELECT pg_temp.dw_disp(:'admin_claims'::jsonb,pg_temp.dw_ddata(:'cs'::uuid,'Dup Customer S','DS2','GJ 05 SS 0005'),ARRAY[pg_temp.dw_dline(:'lot_s'::uuid,10)]) AS ds_31 \gset
SELECT pg_temp.dw_assert(:'ds_31'::jsonb->>'success'='true','D5 a dispatch made 31 minutes ago does not warn: '||:'ds_31');
-- DS2 (new) is deleted for good: the same dispatch again saves as DS3, because DS1 is 31 minutes old and DS2 is gone. DS3 is then soft-deleted
-- (deleted_at set): DS4 saves again.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(id,:'admin_profile'::uuid) AS ds2_deleted FROM public.dispatch WHERE disp_no='DS2' \gset
RESET ROLE;
SELECT pg_temp.dw_assert(:'ds2_deleted'::jsonb->>'success'='true' AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no='DS2'),'fixture: DS2 is deleted: '||:'ds2_deleted');
SELECT pg_temp.dw_disp(:'admin_claims'::jsonb,pg_temp.dw_ddata(:'cs'::uuid,'Dup Customer S','DS3','GJ 05 SS 0005'),ARRAY[pg_temp.dw_dline(:'lot_s'::uuid,10)]) AS ds3 \gset
SELECT pg_temp.dw_assert(:'ds3'::jsonb->>'success'='true','D5 a deleted dispatch does not warn: '||:'ds3');
UPDATE public.dispatch SET deleted_at=now(), deleted_by=:'admin_profile'::uuid WHERE disp_no='DS3';
SELECT pg_temp.dw_disp(:'admin_claims'::jsonb,pg_temp.dw_ddata(:'cs'::uuid,'Dup Customer S','DS4','GJ 05 SS 0005'),ARRAY[pg_temp.dw_dline(:'lot_s'::uuid,10)]) AS ds4 \gset
SELECT pg_temp.dw_assert(:'ds4'::jsonb->>'success'='true','D5 a soft-deleted dispatch does not warn: '||:'ds4');
