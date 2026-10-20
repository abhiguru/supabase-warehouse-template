-- Migration 95 (TW-BE-012, TW-BE-013): the receipt snapshot is as wide as the catalog. An item of 80 characters with a
-- packaging of 40 can be received, listed, dispatched and invoiced; 81 / 41 characters are refused up front by
-- save_grn and update_grn with item_name_too_long / packaging_too_long, writing nothing; the four views that block the
-- column change were recreated with the same owner, privileges and indexes, and the list refresher still sees them.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; every fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.cw_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'catalog receipt width: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.cw_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.cw_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.cw_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The jsonb answer of a statement run as the signed-in caller, or what it raised.
CREATE FUNCTION pg_temp.cw_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
-- One GRN line as save_grn / update_grn take it.
CREATE FUNCTION pg_temp.cw_line(p_item uuid, p_name text, p_pack text, p_qty integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('item_id',p_item,'item_name',p_name,'packaging',p_pack,'qty',p_qty,'weight',40,'rack','R1') $$;
CREATE FUNCTION pg_temp.cw_save(claims jsonb, p_no text, p_customer uuid, p_items jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.cw_as(claims, format($q$SELECT public.save_grn(p_gr_no=>%L,p_date=>now(),p_customer_id=>%L::uuid,
    p_customer_name=>'x',p_items=>%L::jsonb)$q$, p_no, p_customer, p_items)) $$;
CREATE FUNCTION pg_temp.cw_upd(claims jsonb, p_grn uuid, p_items jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.cw_as(claims, format($q$SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb)$q$, p_grn, p_items)) $$;
-- Dispatches the whole lot of a GRN and saves an invoice for it.
CREATE FUNCTION pg_temp.cw_invoice(claims jsonb, p_gr_no text, p_disp_no text, p_inv_no integer, p_customer uuid, p_sup uuid) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE lot record; disp jsonb; rws jsonb; its jsonb; v_gr uuid;
BEGIN
  SELECT id INTO v_gr FROM public.goodsreceived WHERE gr_no=p_gr_no;
  SELECT t.id, t.qty INTO lot FROM public.goodsreceived_trl t WHERE t.gr_id=v_gr ORDER BY t.id LIMIT 1;
  disp := pg_temp.cw_as(claims, format($q$SELECT public.create_dispatch_with_stock_check(%L::jsonb||%L::jsonb,ARRAY[%L::jsonb],0,%L)$q$,
    jsonb_build_object('customer_id',p_customer,'customer_name','CW Orchard','supervisor_id',p_sup,'supervisor_name','CW Administrator'),
    jsonb_build_object('disp_no',p_disp_no,'disp_date',warehouse_security.business_date(now())), jsonb_build_object('gr_trl_id',lot.id,'disp_qty',lot.qty), 'cw-key-'||p_disp_no));
  IF disp->>'success' IS DISTINCT FROM 'true' THEN RETURN disp; END IF;
  rws := public.build_invoice_recalculation_rows(v_gr);
  SELECT jsonb_agg(jsonb_build_object('disp_trl_id',r->>'disp_trl_id','grn_item_id',r->>'grn_item_id','duration',(r->>'duration')::numeric,
           'charge',5,'tax',5,'labour_rate',1)) INTO its FROM jsonb_array_elements(rws->'rows') r;
  RETURN pg_temp.cw_as(claims, format($q$SELECT public.save_invoice(%L::jsonb||jsonb_build_object('items',%L::jsonb))$q$,
    jsonb_build_object('inv_no',p_inv_no,'inv_fin_year',2026,'customer_id',p_customer,'customer_name','CW Orchard',
      'inv_date',now(),'total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy',
      'gr_id',v_gr,'gr_no',p_gr_no), its));
END $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888889601','CW Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888889602','CW Staff','staff',true,'approved');
SELECT pg_temp.cw_login('9888889601') AS admin_claims \gset
SELECT pg_temp.cw_login('9888889602') AS staff_claims \gset

-- ---------------------------------------------------------------------------
-- 1. Columns, views, owners, privileges and indexes
-- ---------------------------------------------------------------------------
SELECT pg_temp.cw_assert((SELECT count(*)=2 FROM pg_attribute WHERE attrelid='public.goodsreceived_trl'::regclass AND NOT attisdropped
   AND ((attname='item_name' AND atttypmod=84) OR (attname='packaging' AND atttypmod=44))),
 'goodsreceived_trl.item_name is varchar(80) and packaging varchar(40)');
SELECT pg_temp.cw_assert((SELECT count(*)=4 FROM information_schema.columns WHERE table_schema='public'
   AND table_name IN ('stock_summary','low_stock_alerts')
   AND ((column_name='item_name' AND character_maximum_length=80) OR (column_name='packaging' AND character_maximum_length=40))),
 'stock_summary and low_stock_alerts show item_name 80 and packaging 40');
-- The two views that stay keep the owner and privileges they had.
SELECT pg_temp.cw_assert((SELECT count(*)=2 AND bool_and(pg_get_userbyid(c.relowner)='supabase_admin'
     AND c.relacl::text ~ '^\{supabase_admin=arwdDxtm?/supabase_admin,service_role=arwdDxtm?/supabase_admin\}$')  -- m (MAINTAIN) exists from PostgreSQL 17; the role postgres is not in this database
   FROM pg_class c WHERE c.oid IN ('public.stock_summary'::regclass,'public.low_stock_alerts'::regclass)),
 'the two recreated views keep the owner and privileges they had');
-- Migration 106 removed the materialized lists: the list screens read the tables, so there is nothing to refresh.
SELECT pg_temp.cw_assert(NOT EXISTS (SELECT 1 FROM pg_matviews) AND to_regclass('public.mv_refresh_queue') IS NULL,
 'no materialized list and no refresh queue remain (migration 106)');

-- ---------------------------------------------------------------------------
-- 2. Fixtures: a business, a supervisor and an 80 / 40 character catalog item
-- ---------------------------------------------------------------------------
SELECT pg_temp.cw_assert(pg_temp.cw_as(:'admin_claims'::jsonb,$q$SELECT public.create_customer('CW Orchard','9888889611')$q$)->>'success'='true','customer');
SELECT id AS orchard FROM public.customers WHERE name='CW Orchard' \gset
SELECT repeat('N',79)||'Z' AS name80, repeat('P',39)||'Q' AS pack40, repeat('N',80)||'Z' AS name81, repeat('P',40)||'Q' AS pack41 \gset
SELECT pg_temp.cw_assert(length(:'name80')=80 AND length(:'pack40')=40 AND length(:'name81')=81 AND length(:'pack41')=41,'fixture lengths');
SELECT pg_temp.cw_assert(pg_temp.cw_as(:'admin_claims'::jsonb,format($q$SELECT public.create_item(%L,%L)$q$,:'name80',:'pack40'))->>'success'='true',
 'the catalog accepts an item of 80 characters with a packaging of 40');
SELECT id AS wide_item FROM public.items WHERE name=:'name80' \gset
SELECT pg_temp.cw_assert(:'wide_item' <> '' AND (SELECT packaging=:'pack40' FROM public.items WHERE id=:'wide_item'::uuid),'the catalog item keeps its packaging');

-- ---------------------------------------------------------------------------
-- 3. Receive, list, dispatch, invoice
-- ---------------------------------------------------------------------------
SELECT pg_temp.cw_save(:'staff_claims'::jsonb,'CWW1',:'orchard'::uuid,
  jsonb_build_array(pg_temp.cw_line(:'wide_item'::uuid,:'name80',:'pack40',10))) AS wide_save \gset
SELECT pg_temp.cw_assert(:'wide_save'::jsonb->>'success'='true','staff save_grn takes the 80 / 40 character line: '||:'wide_save');
SELECT pg_temp.cw_assert((SELECT t.item_name=:'name80' AND t.packaging=:'pack40' AND char_length(t.item_name)=80 AND char_length(t.packaging)=40
     FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='CWW1'),
 'the receipt line holds the full name and packaging');
-- The GRN list reads the tables, so the receipt is listed with the full strings at once.
SELECT pg_temp.cw_assert(pg_temp.cw_as(:'admin_claims'::jsonb,$q$SELECT public.get_all_grn_items(p_filters=>'{"search":"CWW1"}'::jsonb)$q$)::text LIKE '%'||:'name80'||'%'
 AND pg_temp.cw_as(:'admin_claims'::jsonb,$q$SELECT public.get_all_grn_items(p_filters=>'{"search":"CWW1"}'::jsonb)$q$)::text LIKE '%'||:'pack40'||'%',
 'the GRN list shows the full name and packaging');
SELECT pg_temp.cw_assert((SELECT count(*)=1 AND bool_and(item_name=:'name80' AND packaging=:'pack40') FROM public.stock_summary WHERE gr_no='CWW1')
 AND (SELECT count(*)=0 FROM public.low_stock_alerts WHERE gr_no='CWW1'),
 'stock_summary shows the full strings (a full lot is not a low-stock alert)');

SELECT pg_temp.cw_invoice(:'admin_claims'::jsonb,'CWW1','CWD1',20269601,:'orchard'::uuid,:'admin_profile'::uuid) AS wide_invoice \gset
SELECT pg_temp.cw_assert(:'wide_invoice'::jsonb->>'success'='true','the 80 / 40 character line is dispatched and invoiced: '||:'wide_invoice');
SELECT pg_temp.cw_assert(pg_temp.cw_as(:'admin_claims'::jsonb,$q$SELECT public.get_dispatch_list_with_items(p_filters=>'{"disp_no":"CWD1"}'::jsonb,p_include_items=>true)$q$)::text LIKE '%'||:'name80'||'%',
 'the Dispatches list names the full item of the dispatch');
SELECT pg_temp.cw_assert((SELECT count(*)=0 FROM public.stock_summary WHERE gr_no='CWW1' AND current_stock>0),
 'the dispatched lot leaves stock_summary');

-- ---------------------------------------------------------------------------
-- 4. One character more is refused up front, with the code and the limit, and writes nothing
-- ---------------------------------------------------------------------------
SELECT count(*) AS grns_before FROM public.goodsreceived \gset
SELECT count(*) AS lines_before FROM public.goodsreceived_trl \gset
SELECT pg_temp.cw_save(:'staff_claims'::jsonb,'CWLN',:'orchard'::uuid,
  jsonb_build_array(pg_temp.cw_line(:'wide_item'::uuid,:'name80',:'pack40',1), pg_temp.cw_line(:'wide_item'::uuid,:'name81',:'pack40',1))) AS long_name \gset
SELECT pg_temp.cw_assert(:'long_name'::jsonb->>'success'='false' AND :'long_name'::jsonb->>'error_code'='item_name_too_long'
  AND (:'long_name'::jsonb#>>'{data,limit}')::int=80 AND (:'long_name'::jsonb#>>'{data,index}')::int=1
  AND :'long_name'::jsonb->>'message' LIKE '%80%' AND :'long_name'::jsonb->>'error' = :'long_name'::jsonb->>'message',
 'save_grn: an 81 character item name answers item_name_too_long with limit 80 and the line index: '||:'long_name');
SELECT pg_temp.cw_save(:'staff_claims'::jsonb,'CWLP',:'orchard'::uuid,
  jsonb_build_array(pg_temp.cw_line(:'wide_item'::uuid,:'name80',:'pack41',1))) AS long_pack \gset
SELECT pg_temp.cw_assert(:'long_pack'::jsonb->>'success'='false' AND :'long_pack'::jsonb->>'error_code'='packaging_too_long'
  AND (:'long_pack'::jsonb#>>'{data,limit}')::int=40 AND (:'long_pack'::jsonb#>>'{data,index}')::int=0,
 'save_grn: a 41 character packaging answers packaging_too_long with limit 40: '||:'long_pack');
SELECT pg_temp.cw_assert((SELECT count(*) FROM public.goodsreceived)=:grns_before AND (SELECT count(*) FROM public.goodsreceived_trl)=:lines_before
  AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no IN ('CWLN','CWLP')),
 'a refused save_grn wrote no GRN and no line');
-- A line with a packaging of NULL or a short name is unaffected by the check.
SELECT pg_temp.cw_save(:'staff_claims'::jsonb,'CWS1',:'orchard'::uuid,
  jsonb_build_array(jsonb_build_object('item_id',:'wide_item'::uuid,'item_name','Short','qty',2,'weight',40,'rack','R1'))) AS short_save \gset
SELECT pg_temp.cw_assert(:'short_save'::jsonb->>'success'='true','a short name without packaging is still saved: '||:'short_save');

-- update_grn: the same two codes, and the GRN stays as it was.
SELECT id AS wide_grn FROM public.goodsreceived WHERE gr_no='CWS1' \gset
SELECT t.id AS short_line FROM public.goodsreceived_trl t WHERE t.gr_id=:'wide_grn'::uuid \gset
SELECT pg_temp.cw_upd(:'staff_claims'::jsonb,:'wide_grn'::uuid, jsonb_build_array(jsonb_build_object('id',:'short_line'::uuid,'item_id',:'wide_item'::uuid,
  'item_name',:'name81','packaging','Bag','qty',2,'weight',40,'rack','R1'))) AS upd_name \gset
SELECT pg_temp.cw_assert(:'upd_name'::jsonb->>'error_code'='item_name_too_long' AND (:'upd_name'::jsonb#>>'{data,limit}')::int=80
  AND (:'upd_name'::jsonb#>>'{data,index}')::int=0,'update_grn: an 81 character item name answers item_name_too_long: '||:'upd_name');
SELECT pg_temp.cw_upd(:'staff_claims'::jsonb,:'wide_grn'::uuid, jsonb_build_array(jsonb_build_object('id',:'short_line'::uuid,'item_id',:'wide_item'::uuid,
  'item_name','Short','packaging',:'pack41','qty',2,'weight',40,'rack','R1'))) AS upd_pack \gset
SELECT pg_temp.cw_assert(:'upd_pack'::jsonb->>'error_code'='packaging_too_long' AND (:'upd_pack'::jsonb#>>'{data,limit}')::int=40,
 'update_grn: a 41 character packaging answers packaging_too_long: '||:'upd_pack');
SELECT pg_temp.cw_assert((SELECT item_name='Short' AND packaging IS NULL FROM public.goodsreceived_trl WHERE id=:'short_line'::uuid),
 'a refused update_grn left the line as it was');
-- update_grn accepts the wide strings.
SELECT pg_temp.cw_upd(:'staff_claims'::jsonb,:'wide_grn'::uuid, jsonb_build_array(jsonb_build_object('id',:'short_line'::uuid,'item_id',:'wide_item'::uuid,
  'item_name',:'name80','packaging',:'pack40','qty',2,'weight',40,'rack','R1'))) AS upd_ok \gset
SELECT pg_temp.cw_assert(:'upd_ok'::jsonb->>'success'='true' AND (SELECT item_name=:'name80' AND packaging=:'pack40' FROM public.goodsreceived_trl WHERE id=:'short_line'::uuid),
 'update_grn stores an 80 / 40 character line: '||:'upd_ok');
SELECT pg_temp.cw_assert(pg_temp.cw_as(:'admin_claims'::jsonb,$q$SELECT public.get_all_grn_items(p_filters=>'{"search":"CWS1"}'::jsonb)$q$)::text LIKE '%'||:'name80'||'%',
 'the list shows the edited full strings');

-- The functions kept their owner and options.
SELECT pg_temp.cw_assert((SELECT bool_and(p.prosecdef AND pg_get_userbyid(p.proowner)=(SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE proname='replace_item_rates' AND pronamespace='public'::regnamespace)
      AND p.proconfig::text LIKE '%search_path=pg_catalog, public, extensions, utils, pg_temp%' AND p.proconfig::text LIKE '%jit=off%'
      AND has_function_privilege('authenticated',p.oid,'EXECUTE') AND NOT has_function_privilege('anon',p.oid,'EXECUTE'))
   FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('save_grn','update_grn')),
 'save_grn and update_grn keep owner, SECURITY DEFINER, search_path and grants');
ROLLBACK;
