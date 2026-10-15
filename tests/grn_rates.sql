-- Migration 86 (2026-10-15): rates typed on the GRN sheet and the rate start floor. save_grn and
-- update_grn with p_rates (NULL = as before, [] = check only, RATE_MISSING, the "grn", "customer"
-- and "everyone" scopes, the failures that leave the GRN unsaved), grn_rates in the invoice
-- rows and in get_grn_details, get_item_grn_rates, rate_start_floor with replace_item_rates,
-- undo_rate_change and get_item_storage_prices.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.gr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'grn rates: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.gr_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.gr_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.gr_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The jsonb answer of a statement run as the signed-in caller, or what it raised.
CREATE FUNCTION pg_temp.gr_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
-- "0-50@6.00/2.00/5 2026-03-02..open | ..." per scope, oldest start first.
CREATE FUNCTION pg_temp.gr_rows(p_item uuid, p_customer uuid, p_type text DEFAULT 'monthly') RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(r.weight_min||'-'||r.weight_max||'@'||r.unit_price||'/'||r.labour_rate||'/'||trim_scale(r.tax_percent)
           ||' '||r.effective_from||'..'||COALESCE(r.effective_to::text,'open'), ' | ' ORDER BY r.effective_from, r.weight_min),'(none)')
  FROM public.item_storage_prices r
  WHERE r.item_id=p_item AND r.customer_id IS NOT DISTINCT FROM p_customer AND r.price_type=p_type $$;
-- The GRN's own rates: "0-50@7.00/2.00/5 monthly | ..." by item name and weight.
CREATE FUNCTION pg_temp.gr_own(p_gr_no text) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(i.name||' '||r.weight_min||'-'||r.weight_max||'@'||r.unit_price||'/'||r.labour_rate||'/'||trim_scale(r.tax_percent)
           ||' '||r.price_type, ' | ' ORDER BY i.name, r.weight_min),'(none)')
  FROM public.grn_rates r JOIN public.items i ON i.id=r.item_id JOIN public.goodsreceived g ON g.id=r.gr_id WHERE g.gr_no=p_gr_no $$;
CREATE FUNCTION pg_temp.gr_item(p_name text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.items WHERE name=p_name $$;
CREATE FUNCTION pg_temp.gr_grn(p_gr_no text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.goodsreceived WHERE gr_no=p_gr_no $$;
-- One GRN line as save_grn takes it; a NULL weight leaves the key out.
CREATE FUNCTION pg_temp.gr_line(p_item text, p_qty integer, p_weight integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('item_id',pg_temp.gr_item(p_item),'item_name',p_item,'packaging','Bag','qty',p_qty,'weight',p_weight,'rack','R1')) $$;
-- The lines a GRN has now, as update_grn takes them (so an update keeps them).
CREATE FUNCTION pg_temp.gr_items(p_gr_no text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(jsonb_build_object('id',t.id,'item_id',t.item_id,'item_name',t.item_name,'packaging',t.packaging,'qty',t.qty,
           'weight',t.weight,'rack',t.rack,'package_mark',t.package_mark) ORDER BY t.id)
  FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no=p_gr_no $$;
CREATE FUNCTION pg_temp.gr_save(claims jsonb, p_no text, p_day date, p_customer uuid, p_mode text, p_items jsonb, p_rates jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.gr_as(claims, format($q$SELECT public.save_grn(p_gr_no=>%L,p_date=>%L::timestamptz,p_customer_id=>%L::uuid,
    p_customer_name=>'x',p_pricing_mode=>%L,p_items=>%L::jsonb,p_rates=>%L::jsonb)$q$, p_no, p_day::text||'T12:00:00Z', p_customer, p_mode, p_items, p_rates)) $$;
CREATE FUNCTION pg_temp.gr_upd(claims jsonb, p_no text, p_rates jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.gr_as(claims, format($q$SELECT public.update_grn(p_grn_id=>%L::uuid,p_items=>%L::jsonb,p_rates=>%L::jsonb)$q$,
    pg_temp.gr_grn(p_no), pg_temp.gr_items(p_no), p_rates)) $$;
-- Entries of p_rates.
CREATE FUNCTION pg_temp.gr_rate(p_scope text, p_item text, p_min integer, p_max integer, p_rent numeric, p_labour numeric, p_tax numeric, p_to date DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('scope',p_scope,'item_id',pg_temp.gr_item(p_item),'weight_min',p_min,'weight_max',p_max,
    'unit_price',p_rent,'labour_rate',p_labour,'tax_percent',p_tax) || CASE WHEN p_scope='grn' THEN '{}'::jsonb ELSE jsonb_build_object('to',p_to) END $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9666666601','GR Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919666666602','GR Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919666666603','GR Staff','staff',true,'approved'),
 (gen_random_uuid(),'919666666604','GR Customer','customer',true,'approved');
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile='919666666603' \gset
SELECT pg_temp.gr_login('9666666601') AS admin_claims \gset
SELECT pg_temp.gr_login('9666666602') AS supervisor_claims \gset
SELECT pg_temp.gr_login('9666666603') AS staff_claims \gset
SELECT pg_temp.gr_login('9666666604') AS customer_claims \gset
SELECT warehouse_security.business_date(now()) AS today \gset
-- Days are written as today plus or minus a number; psql variables hold the dates used below.
SELECT (:'today'::date-100) AS d100, (:'today'::date-13) AS dm13, (:'today'::date-12) AS dm12, (:'today'::date-11) AS dm11,
       (:'today'::date-10) AS dm10, (:'today'::date-9) AS dm9, (:'today'::date-8) AS dm8, (:'today'::date-5) AS dm5,
       (:'today'::date-4) AS dm4, (:'today'::date-3) AS dm3, (:'today'::date+4) AS dp4, (:'today'::date+5) AS dp5,
       (:'today'::date+10) AS dp10 \gset

-- ---------------------------------------------------------------------------
-- 1. The surface
-- ---------------------------------------------------------------------------
SELECT pg_temp.gr_assert((SELECT count(*)=1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='save_grn')
 AND (SELECT count(*)=1 FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='update_grn')
 AND (SELECT pg_get_function_identity_arguments(oid) LIKE '%, p_duration_mode character varying, p_rates jsonb' FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='save_grn')
 AND (SELECT pg_get_function_identity_arguments(oid) LIKE '%, p_idempotency_key text, p_rates jsonb' FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='update_grn'),
 'save_grn and update_grn have one overload each, p_rates last');
-- Owner, options and grants as before the re-create (the migration compares them with what it dropped);
-- here: the same as a sibling that was never re-created, and the options the two had.
SELECT pg_temp.gr_assert((SELECT bool_and(p.prosecdef AND p.proacl::text=(SELECT proacl::text FROM pg_proc WHERE proname='replace_item_rates' AND pronamespace='public'::regnamespace)
      AND pg_get_userbyid(p.proowner)=(SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE proname='replace_item_rates' AND pronamespace='public'::regnamespace)
      AND p.proconfig::text LIKE '%search_path=pg_catalog, public, extensions, utils, pg_temp%' AND p.proconfig::text LIKE '%jit=off%')
   FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('save_grn','update_grn'))
 AND bool_and(has_function_privilege('authenticated',f,'EXECUTE') AND has_function_privilege('service_role',f,'EXECUTE') AND NOT has_function_privilege('anon',f,'EXECUTE'))
 AND has_function_privilege('authenticated','public.get_item_grn_rates(uuid)','EXECUTE')
 AND NOT has_function_privilege('anon','public.get_item_grn_rates(uuid)','EXECUTE')
 AND NOT has_function_privilege('authenticated','warehouse_security.rate_start_floor()','EXECUTE')
 AND NOT has_function_privilege('authenticated','warehouse_security.apply_grn_rates(uuid,jsonb)','EXECUTE'),
 'grants, owner and options of the re-created functions; the new ones are granted and the helpers are not')
 FROM (SELECT p.oid::regprocedure AS f FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('save_grn','update_grn')) q;
SELECT pg_temp.gr_assert((SELECT relrowsecurity FROM pg_class WHERE oid='public.grn_rates'::regclass)
 AND NOT has_table_privilege('authenticated','public.grn_rates','INSERT') AND NOT has_table_privilege('authenticated','public.grn_rates','UPDATE')
 AND NOT has_table_privilege('authenticated','public.grn_rates','DELETE') AND NOT has_table_privilege('authenticated','public.grn_rates','TRUNCATE')
 AND NOT has_table_privilege('anon','public.grn_rates','SELECT') AND has_table_privilege('authenticated','public.grn_rates','SELECT')
 AND (SELECT count(*)=2 AND bool_and(cmd='SELECT') FROM pg_policies WHERE schemaname='public' AND tablename='grn_rates'),
 'grn_rates has row level security, two read policies and no write privilege');

-- ---------------------------------------------------------------------------
-- 2. The floor without any GRN is today
-- ---------------------------------------------------------------------------
UPDATE public.goodsreceived SET deleted_at=now() WHERE deleted_at IS NULL;   -- earlier tests leave nothing, but be sure
SELECT pg_temp.gr_assert(warehouse_security.rate_start_floor()=:'today'::date,'no GRN: the floor is today: '||warehouse_security.rate_start_floor());

-- ---------------------------------------------------------------------------
-- 3. Fixtures: businesses, items and the item rates each scope needs
-- ---------------------------------------------------------------------------
SELECT pg_temp.gr_assert(pg_temp.gr_as(:'admin_claims'::jsonb,$q$SELECT public.create_customer('GR Orchard','9666666611')$q$)->>'success'='true','customer GR Orchard');
SELECT pg_temp.gr_assert(pg_temp.gr_as(:'admin_claims'::jsonb,$q$SELECT public.create_customer('GR Other','9666666612')$q$)->>'success'='true','customer GR Other');
SELECT id AS orchard FROM public.customers WHERE name='GR Orchard' \gset
SELECT id AS other FROM public.customers WHERE name='GR Other' \gset
SELECT pg_temp.gr_assert((SELECT public.assign_customer_to_user('919666666604',:'orchard'::uuid,'grn rates fixture')),'customer login assigned');
SELECT pg_temp.gr_assert(bool_and(pg_temp.gr_as(:'admin_claims'::jsonb,format($q$SELECT public.create_item(%L,'Bag')$q$,n))->>'success'='true'),'items')
 FROM unnest(ARRAY['GR Apple','GR Fig','GR Pear','GR Date','GR Lime','GR Kiwi','GR Mango','GR Plum','GR Quince']) n;
-- Apple: a default and an Orchard rate. Fig: default. Pear: default. Date: a default that stops on
-- today+4 and a planned one from today+5. Lime: two bands. Kiwi: one band. Mango: one-time.
-- Plum and Quince: no rate at all.
INSERT INTO public.item_storage_prices(item_id,customer_id,price_type,unit_price,weight_min,weight_max,labour_rate,tax_percent,effective_from,effective_to,unit_price_one_time,unit_price_monthly) VALUES
 (pg_temp.gr_item('GR Apple'),NULL,'monthly',4,0,50,1.5,5,:'d100',NULL,0,4),
 (pg_temp.gr_item('GR Apple'),:'orchard'::uuid,'monthly',9,0,50,1,5,:'d100',NULL,0,9),
 (pg_temp.gr_item('GR Fig'),NULL,'monthly',4,0,50,1.5,5,:'d100',NULL,0,4),
 (pg_temp.gr_item('GR Pear'),NULL,'monthly',3,0,50,1,5,:'d100',NULL,0,3),
 (pg_temp.gr_item('GR Date'),NULL,'monthly',3,0,50,1,5,:'d100',:'dp4',0,3),
 (pg_temp.gr_item('GR Date'),NULL,'monthly',5,0,50,1,5,:'dp5',NULL,0,5),
 (pg_temp.gr_item('GR Lime'),NULL,'monthly',3,0,10,1,5,:'d100',NULL,0,3),
 (pg_temp.gr_item('GR Lime'),NULL,'monthly',4,11,50,1,5,:'d100',NULL,0,4),
 (pg_temp.gr_item('GR Kiwi'),NULL,'monthly',5,0,100,1,5,:'d100',NULL,0,5),
 (pg_temp.gr_item('GR Mango'),NULL,'one_time',30,0,50,0,18,:'d100',NULL,30,0);

-- ---------------------------------------------------------------------------
-- 4. p_rates NULL: as before (a GRN with an unpriced line still saves; old calls still work)
-- ---------------------------------------------------------------------------
SELECT pg_temp.gr_as(:'staff_claims'::jsonb,format($q$SELECT public.save_grn(p_gr_no=>'GRN-OLD',p_date=>%L::timestamptz,p_customer_id=>%L::uuid,
  p_customer_name=>'x',p_pricing_mode=>'MONTHLY',p_items=>%L::jsonb)$q$,:'dm12'||'T12:00:00Z',:'orchard',jsonb_build_array(pg_temp.gr_line('GR Plum',3,10)))) AS old_call \gset
SELECT pg_temp.gr_assert(:'old_call'::jsonb->>'success'='true' AND pg_temp.gr_own('GRN-OLD')='(none)','the call without p_rates saves a GRN with an unpriced line: '||:'old_call');
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-NULL',:'dm12'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Plum',3,10)),NULL) AS null_call \gset
SELECT pg_temp.gr_assert(:'null_call'::jsonb->>'success'='true' AND pg_temp.gr_own('GRN-NULL')='(none)','p_rates NULL saves a GRN with an unpriced line: '||:'null_call');
SELECT pg_temp.gr_as(:'staff_claims'::jsonb,format($q$SELECT public.update_grn(p_grn_id=>%L::uuid,p_note=>'noted',p_items=>%L::jsonb)$q$,
  pg_temp.gr_grn('GRN-NULL'),pg_temp.gr_items('GRN-NULL'))) AS old_update \gset
SELECT pg_temp.gr_assert(:'old_update'::jsonb->>'success'='true' AND (SELECT note='noted' FROM public.goodsreceived WHERE gr_no='GRN-NULL'),
 'update_grn without p_rates still works: '||:'old_update');

-- ---------------------------------------------------------------------------
-- 5. [] means "check only": every line priced is fine, an unpriced line is RATE_MISSING and
-- nothing is saved
-- ---------------------------------------------------------------------------
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-EMP',:'dm12'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Kiwi',3,10),pg_temp.gr_line('GR Apple',2,20)),'[]') AS empty_ok \gset
SELECT pg_temp.gr_assert(:'empty_ok'::jsonb->>'success'='true' AND pg_temp.gr_own('GRN-EMP')='(none)','[] with every line priced saves: '||:'empty_ok');
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-MISS',:'dm12'::date,:'orchard'::uuid,'MONTHLY',
  jsonb_build_array(pg_temp.gr_line('GR Plum',3,10),pg_temp.gr_line('GR Plum',1,10),pg_temp.gr_line('GR Plum',2,20),pg_temp.gr_line('GR Quince',1,NULL),pg_temp.gr_line('GR Kiwi',1,10)),'[]') AS miss \gset
SELECT pg_temp.gr_assert(:'miss'::jsonb->>'success'='false' AND :'miss'::jsonb->>'error_code'='RATE_MISSING' AND :'miss'::jsonb->>'message'=:'miss'::jsonb->>'error'
 AND (SELECT jsonb_agg(l->>'item_name'||' '||(l->>'weight')) FROM jsonb_array_elements(:'miss'::jsonb#>'{data,lines}') l)='["GR Plum 10", "GR Plum 20", "GR Quince 0"]'::jsonb
 AND (SELECT bool_and((l->>'item_id')::uuid=pg_temp.gr_item(l->>'item_name')) FROM jsonb_array_elements(:'miss'::jsonb#>'{data,lines}') l),
 'RATE_MISSING lists the distinct unpriced lines (a missing weight counts as 0): '||:'miss');
SELECT pg_temp.gr_assert(NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='GRN-MISS')
 AND NOT EXISTS (SELECT 1 FROM public.goodsreceived_trl WHERE gr_id NOT IN (SELECT id FROM public.goodsreceived)),'the refused GRN is not saved');
-- The same on update: refused and rolled back (the note and the lines stay).
SELECT pg_temp.gr_as(:'staff_claims'::jsonb,format($q$SELECT public.update_grn(p_grn_id=>%L::uuid,p_note=>'must not stay',p_items=>%L::jsonb,p_rates=>'[]')$q$,
  pg_temp.gr_grn('GRN-NULL'),pg_temp.gr_items('GRN-NULL'))) AS miss_update \gset
SELECT pg_temp.gr_assert(:'miss_update'::jsonb->>'error_code'='RATE_MISSING' AND :'miss_update'::jsonb->>'message' IS NOT NULL
 AND (SELECT note='noted' FROM public.goodsreceived WHERE gr_no='GRN-NULL'),'update_grn: RATE_MISSING undoes the update: '||:'miss_update');

-- ---------------------------------------------------------------------------
-- 6. Scope "grn": stored, replaced on update, shown by get_grn_details, listed per item
-- ---------------------------------------------------------------------------
-- G2 (older) and G3 (newer) also carry a Plum rate, for the order of get_item_grn_rates.
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-G2',:'dm12'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Plum',1,10)),
  jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',0,50,2,1,5))) AS g2 \gset
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-G3',:'dm9'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Plum',1,10)),
  jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',0,50,3,1,5))) AS g3 \gset
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-G4',:'dm9'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Plum',1,10)),
  jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',0,50,4,1,5))) AS g4 \gset
SELECT pg_temp.gr_assert(:'g2'::jsonb->>'success'='true' AND :'g3'::jsonb->>'success'='true' AND :'g4'::jsonb->>'success'='true','GRNs G2, G3, G4: '||:'g2'||:'g3'||:'g4');
UPDATE public.goodsreceived SET deleted_at=now() WHERE gr_no='GRN-G4';
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-G1',:'dm10'::date,:'orchard'::uuid,'MONTHLY',
  jsonb_build_array(pg_temp.gr_line('GR Plum',5,10),pg_temp.gr_line('GR Kiwi',1,10)),
  jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',0,50,7,2,5),pg_temp.gr_rate('grn','GR Kiwi',0,100,3,1,5))) AS g1 \gset
SELECT pg_temp.gr_assert(:'g1'::jsonb->>'success'='true' AND pg_temp.gr_own('GRN-G1')='GR Kiwi 0-100@3.00/1.00/5 monthly | GR Plum 0-50@7.00/2.00/5 monthly'
 AND (SELECT bool_and(r.created_by=:'staff_profile'::uuid) FROM public.grn_rates r WHERE r.gr_id=pg_temp.gr_grn('GRN-G1')),'GRN rates stored by staff: '||:'g1'||pg_temp.gr_own('GRN-G1'));
SELECT pg_temp.gr_as(:'staff_claims'::jsonb,format($q$SELECT public.get_grn_details(%L::uuid)$q$,pg_temp.gr_grn('GRN-G1'))) AS det1 \gset
SELECT pg_temp.gr_assert(:'det1'::jsonb#>>'{success}'='true' AND jsonb_array_length(:'det1'::jsonb#>'{data,grn,rates}')=2
 AND :'det1'::jsonb#>>'{data,grn,rates,0,item_name}'='GR Kiwi' AND :'det1'::jsonb#>>'{data,grn,rates,1,item_name}'='GR Plum'
 AND (:'det1'::jsonb#>>'{data,grn,rates,1,unit_price}')::numeric=7 AND (:'det1'::jsonb#>>'{data,grn,rates,1,labour_rate}')::numeric=2
 AND (:'det1'::jsonb#>>'{data,grn,rates,1,tax_percent}')::numeric=5 AND :'det1'::jsonb#>>'{data,grn,rates,1,price_type}'='monthly'
 AND (:'det1'::jsonb#>>'{data,grn,rates,1,weight_max}')::int=50 AND :'det1'::jsonb#>>'{data,grn,rates,1,archived}'='false',
 'get_grn_details: rates by item name, not archived: '||(:'det1'::jsonb#>>'{data,grn,rates}'));
SELECT pg_temp.gr_as(:'staff_claims'::jsonb,format($q$SELECT public.get_grn_details(%L::uuid)$q$,pg_temp.gr_grn('GRN-OLD'))) AS det_none \gset
SELECT pg_temp.gr_assert(:'det_none'::jsonb#>'{data,grn,rates}'='[]'::jsonb,'a GRN without own rates answers rates []');
-- Replaced on update: Plum 7 -> 8, Kiwi dropped.
SELECT pg_temp.gr_upd(:'staff_claims'::jsonb,'GRN-G1',jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',0,50,8,2,5))) AS g1u \gset
SELECT pg_temp.gr_assert(:'g1u'::jsonb->>'success'='true' AND pg_temp.gr_own('GRN-G1')='GR Plum 0-50@8.00/2.00/5 monthly','update_grn replaces the GRN rates: '||:'g1u'||pg_temp.gr_own('GRN-G1'));
-- p_rates NULL leaves them; a refused update leaves them too.
SELECT pg_temp.gr_upd(:'staff_claims'::jsonb,'GRN-G1',NULL) AS g1n \gset
SELECT pg_temp.gr_assert(:'g1n'::jsonb->>'success'='true' AND pg_temp.gr_own('GRN-G1')='GR Plum 0-50@8.00/2.00/5 monthly','update_grn with p_rates NULL keeps them');
SELECT pg_temp.gr_upd(:'staff_claims'::jsonb,'GRN-G1','[]') AS g1x \gset
SELECT pg_temp.gr_assert(:'g1x'::jsonb->>'error_code'='RATE_MISSING' AND (:'g1x'::jsonb#>>'{data,lines,0,item_name}')='GR Plum'
 AND pg_temp.gr_own('GRN-G1')='GR Plum 0-50@8.00/2.00/5 monthly','[] on a GRN whose line needs its own rate: refused, the stored rate stays: '||:'g1x');
-- Kiwi has the item rate, Plum the GRN rate, so [] with the GRN rate still in place is not enough: p_rates replaces the set.
-- The listing per item: not archived first, newest GRN first, a deleted GRN left out.
SELECT pg_temp.gr_as(:'staff_claims'::jsonb,format($q$SELECT public.get_item_grn_rates(%L::uuid)$q$,pg_temp.gr_item('GR Plum'))) AS list_a \gset
SELECT pg_temp.gr_assert(:'list_a'::jsonb->>'success'='true' AND (SELECT jsonb_agg(r->>'gr_no') FROM jsonb_array_elements(:'list_a'::jsonb#>'{data,rates}') r)='["GRN-G3", "GRN-G1", "GRN-G2"]'::jsonb
 AND (SELECT bool_and(r->>'archived'='false') FROM jsonb_array_elements(:'list_a'::jsonb#>'{data,rates}') r)
 AND :'list_a'::jsonb#>>'{data,rates,0,grn_date}'=:'dm9' AND :'list_a'::jsonb#>>'{data,rates,0,customer_name}'='GR Orchard'
 AND (:'list_a'::jsonb#>>'{data,rates,0,unit_price}')::numeric=3 AND :'list_a'::jsonb#>>'{data,rates,0,price_type}'='monthly',
 'get_item_grn_rates: newest first, the deleted GRN left out: '||(SELECT jsonb_agg(r->>'gr_no') FROM jsonb_array_elements(:'list_a'::jsonb#>'{data,rates}') r)::text);
SELECT pg_temp.gr_assert(pg_temp.gr_as(:'customer_claims'::jsonb,format($q$SELECT public.get_item_grn_rates(%L::uuid)$q$,pg_temp.gr_item('GR Plum')))->>'state'='42501',
 'a customer account is refused get_item_grn_rates');
SELECT pg_temp.gr_assert(pg_temp.gr_as(:'supervisor_claims'::jsonb,format($q$SELECT public.get_item_grn_rates(%L::uuid)$q$,pg_temp.gr_item('GR Plum')))->>'success'='true'
 AND pg_temp.gr_as(:'admin_claims'::jsonb,format($q$SELECT public.get_item_grn_rates(%L::uuid)$q$,pg_temp.gr_item('GR Plum')))->>'success'='true','supervisors and administrators may read it');

-- The invoice uses the GRN rate: dispatch 5 Plum on dm8, then the recalculation rows.
SELECT jsonb_build_object('customer_id',:'orchard','customer_name','GR Orchard','supervisor_id',:'admin_profile','supervisor_name','GR Administrator') AS dispatch_for \gset
SELECT id AS plum_lot FROM public.goodsreceived_trl WHERE gr_id=pg_temp.gr_grn('GRN-G1') AND item_name='GR Plum' \gset
SELECT pg_temp.gr_as(:'admin_claims'::jsonb,format($q$SELECT public.create_dispatch_with_stock_check(%L::jsonb||%L::jsonb,ARRAY[%L::jsonb],0,'grn-rates-d1')$q$,
  :'dispatch_for',jsonb_build_object('disp_no','GRD1','disp_date',:'dm8'),jsonb_build_object('gr_trl_id',:'plum_lot','disp_qty',5))) AS disp1 \gset
SELECT pg_temp.gr_assert(:'disp1'::jsonb->>'success'='true','dispatch of the Plum lot: '||:'disp1');
SELECT public.build_invoice_recalculation_rows(pg_temp.gr_grn('GRN-G1')) AS rows1 \gset
SELECT pg_temp.gr_assert(:'rows1'::jsonb->>'success'='true' AND jsonb_array_length(:'rows1'::jsonb->'rows')=1
 AND (:'rows1'::jsonb#>>'{rows,0,charge}')::numeric=8 AND (:'rows1'::jsonb#>>'{rows,0,labour_rate}')::numeric=2 AND (:'rows1'::jsonb#>>'{rows,0,tax_percent}')::numeric=5
 AND (:'rows1'::jsonb#>>'{rows,0,labour_amount}')::numeric=10
 AND (:'rows1'::jsonb#>>'{rows,0,tax_amount}')::numeric=round(((:'rows1'::jsonb#>>'{rows,0,storage_amount}')::numeric+10)*5/100.0,2)
 AND (:'rows1'::jsonb#>>'{rows,0,storage_amount}')::numeric=round(8*5*(:'rows1'::jsonb#>>'{rows,0,duration}')::numeric,2)
 AND (:'rows1'::jsonb#>>'{rows,0,missing_price}')='false','the invoice rows take rent 8, labour 2 and tax 5 from the GRN rate: '||(:'rows1'::jsonb#>'{rows,0}')::text);
-- Save the invoice (charge 8), then change the GRN rate behind it: the stored charge wins.
SELECT jsonb_build_object('inv_no',20269901,'inv_fin_year',2026,'customer_id',:'orchard','customer_name','GR Orchard',
 'inv_date',:'dm8'||'T12:00:00Z','total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy',
 'gr_id',pg_temp.gr_grn('GRN-G1'),'gr_no','GRN-G1') AS inv_header \gset
SELECT jsonb_agg(jsonb_build_object('disp_trl_id',r->>'disp_trl_id','grn_item_id',r->>'grn_item_id','duration',(r->>'duration')::numeric,
   'charge',(r->>'charge')::numeric,'tax',(r->>'tax_percent')::numeric,'labour_rate',(r->>'labour_rate')::numeric)) AS inv_items
 FROM jsonb_array_elements(:'rows1'::jsonb->'rows') r \gset
SELECT pg_temp.gr_as(:'admin_claims'::jsonb,format($q$SELECT public.save_invoice(%L::jsonb||jsonb_build_object('items',%L::jsonb))$q$,:'inv_header',:'inv_items')) AS inv1 \gset
SELECT pg_temp.gr_assert(:'inv1'::jsonb->>'success'='true' AND (SELECT invoiced FROM public.goodsreceived WHERE gr_no='GRN-G1'),'invoice saved, GRN invoiced: '||:'inv1');
SELECT (:'inv1'::jsonb->>'invoice_id') AS invoice_g1 \gset
UPDATE public.grn_rates SET unit_price=9 WHERE gr_id=pg_temp.gr_grn('GRN-G1');
SELECT public.build_invoice_recalculation_rows(pg_temp.gr_grn('GRN-G1'),'legacy',:'invoice_g1'::uuid) AS rows_saved \gset
SELECT public.build_invoice_recalculation_rows(pg_temp.gr_grn('GRN-G1')) AS rows_fresh \gset
SELECT pg_temp.gr_assert((:'rows_saved'::jsonb#>>'{rows,0,charge}')::numeric=8,'the stored invoice charge (8) wins over the GRN rate (now 9): '||(:'rows_saved'::jsonb#>>'{rows,0,charge}'));
SELECT pg_temp.gr_assert((:'rows_fresh'::jsonb#>>'{rows,0,charge}')::numeric=9,'with no invoice, the GRN rate (9) is used: '||(:'rows_fresh'::jsonb#>>'{rows,0,charge}'));
-- An invoiced GRN: a differing set is GRN_INVOICED, the equal set is accepted silently; the details say archived.
SELECT pg_temp.gr_upd(:'staff_claims'::jsonb,'GRN-G1',jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',0,50,5,2,5))) AS inv_diff \gset
SELECT pg_temp.gr_assert(:'inv_diff'::jsonb->>'error_code'='GRN_INVOICED' AND :'inv_diff'::jsonb->>'message'='The rates of an invoiced GRN cannot change'
 AND pg_temp.gr_own('GRN-G1')='GR Plum 0-50@9.00/2.00/5 monthly','a differing set on an invoiced GRN: GRN_INVOICED, unchanged: '||:'inv_diff');
SELECT pg_temp.gr_upd(:'staff_claims'::jsonb,'GRN-G1','[]') AS inv_none \gset
SELECT pg_temp.gr_assert(:'inv_none'::jsonb->>'error_code'='GRN_INVOICED','dropping the GRN rate of an invoiced GRN is a change too');
SELECT pg_temp.gr_upd(:'staff_claims'::jsonb,'GRN-G1',jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',0,50,9,2,5))) AS inv_same \gset
SELECT pg_temp.gr_assert(:'inv_same'::jsonb->>'success'='true' AND pg_temp.gr_own('GRN-G1')='GR Plum 0-50@9.00/2.00/5 monthly','the equal set on an invoiced GRN is accepted: '||:'inv_same');
SELECT pg_temp.gr_as(:'staff_claims'::jsonb,format($q$SELECT public.get_grn_details(%L::uuid)$q$,pg_temp.gr_grn('GRN-G1'))) AS det2 \gset
SELECT pg_temp.gr_assert(:'det2'::jsonb#>>'{data,grn,rates,0,archived}'='true','the rate of an invoiced GRN is archived');
SELECT pg_temp.gr_as(:'staff_claims'::jsonb,format($q$SELECT public.get_item_grn_rates(%L::uuid)$q$,pg_temp.gr_item('GR Plum'))) AS list_b \gset
SELECT pg_temp.gr_assert((SELECT jsonb_agg(r->>'gr_no') FROM jsonb_array_elements(:'list_b'::jsonb#>'{data,rates}') r)='["GRN-G3", "GRN-G2", "GRN-G1"]'::jsonb
 AND :'list_b'::jsonb#>>'{data,rates,2,archived}'='true','the archived rate (invoiced GRN G1) moves to the end: '||(SELECT jsonb_agg(r->>'gr_no') FROM jsonb_array_elements(:'list_b'::jsonb#>'{data,rates}') r)::text);
-- Delete the invoice: the GRN rate (9) applies again, also through the old invoice id.
SELECT pg_temp.gr_as(:'admin_claims'::jsonb,format($q$SELECT public.delete_invoice(%L::uuid)$q$,:'invoice_g1')) AS del1 \gset
SELECT pg_temp.gr_assert(:'del1'::jsonb->>'success'='true' AND NOT (SELECT invoiced FROM public.goodsreceived WHERE gr_no='GRN-G1'),'invoice deleted: '||:'del1');
SELECT public.build_invoice_recalculation_rows(pg_temp.gr_grn('GRN-G1'),'legacy',:'invoice_g1'::uuid) AS rows_after \gset
SELECT pg_temp.gr_assert((:'rows_after'::jsonb#>>'{rows,0,charge}')::numeric=9,'after delete_invoice the GRN rate applies again: '||(:'rows_after'::jsonb#>>'{rows,0,charge}'));

-- ---------------------------------------------------------------------------
-- 7. Scope "customer", as staff, on a GRN dated in the past
-- ---------------------------------------------------------------------------
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-C1',:'dm10'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Apple',2,10)),
  jsonb_build_array(pg_temp.gr_rate('customer','GR Apple',0,50,6,2,5,:'dm5'::date))) AS c1 \gset
SELECT pg_temp.gr_assert(:'c1'::jsonb->>'success'='true','customer scope as staff, GRN day in the past: '||:'c1');
SELECT pg_temp.gr_assert(pg_temp.gr_rows(pg_temp.gr_item('GR Apple'),:'orchard'::uuid)
   ='0-50@9.00/1.00/5 '||:'d100'||'..'||:'dm11'||' | 0-50@6.00/2.00/5 '||:'dm10'||'..'||:'dm5'||' | 0-50@9.00/1.00/5 '||:'dm4'||'..open',
 'the Orchard row ended the day before the GRN, the new row runs to the last day, the old figures resume after it: '||pg_temp.gr_rows(pg_temp.gr_item('GR Apple'),:'orchard'::uuid));
SELECT pg_temp.gr_assert(pg_temp.gr_rows(pg_temp.gr_item('GR Apple'),NULL)='0-50@4.00/1.50/5 '||:'d100'||'..open','the default rate of the item is untouched');
SELECT pg_temp.gr_assert((SELECT count(*)=3 AND count(*) FILTER (WHERE action='update')=1 AND count(*) FILTER (WHERE action='insert')=2
    AND bool_and(changed_by_role='staff' AND changed_by_name='GR Staff')
  FROM public.item_price_history h WHERE h.item_id=pg_temp.gr_item('GR Apple') AND h.changed_by=:'staff_profile'::uuid),
 'the history rows (one update, two inserts) carry the staff author');
-- A second GRN on the day the new row starts replaces that row (no copy: it ended on the last day).
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-C2',:'dm10'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Apple',2,10)),
  jsonb_build_array(pg_temp.gr_rate('customer','GR Apple',0,50,8,1,5,:'dm5'::date))) AS c2 \gset
SELECT pg_temp.gr_assert(:'c2'::jsonb->>'success'='true'
 AND pg_temp.gr_rows(pg_temp.gr_item('GR Apple'),:'orchard'::uuid)
   ='0-50@9.00/1.00/5 '||:'d100'||'..'||:'dm11'||' | 0-50@8.00/1.00/5 '||:'dm10'||'..'||:'dm5'||' | 0-50@9.00/1.00/5 '||:'dm4'||'..open',
 'a row that starts on the GRN day is replaced: '||pg_temp.gr_rows(pg_temp.gr_item('GR Apple'),:'orchard'::uuid));

-- ---------------------------------------------------------------------------
-- 8. Scope "everyone": with a last day (old figures resume) and without (the old row ends for good)
-- ---------------------------------------------------------------------------
SELECT pg_temp.gr_save(:'supervisor_claims'::jsonb,'GRN-E1',:'dm10'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Fig',2,10)),
  jsonb_build_array(pg_temp.gr_rate('everyone','GR Fig',0,50,6,2,5,:'dm5'::date))) AS e1 \gset
SELECT pg_temp.gr_assert(:'e1'::jsonb->>'success'='true'
 AND pg_temp.gr_rows(pg_temp.gr_item('GR Fig'),NULL)
   ='0-50@4.00/1.50/5 '||:'d100'||'..'||:'dm11'||' | 0-50@6.00/2.00/5 '||:'dm10'||'..'||:'dm5'||' | 0-50@4.00/1.50/5 '||:'dm4'||'..open',
 'everyone with a last day: '||pg_temp.gr_rows(pg_temp.gr_item('GR Fig'),NULL));
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-E2',:'dm12'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Pear',2,10)),
  jsonb_build_array(pg_temp.gr_rate('everyone','GR Pear',0,50,6,2,5))) AS e2 \gset
SELECT pg_temp.gr_assert(:'e2'::jsonb->>'success'='true'
 AND pg_temp.gr_rows(pg_temp.gr_item('GR Pear'),NULL)='0-50@3.00/1.00/5 '||:'d100'||'..'||:'dm13'||' | 0-50@6.00/2.00/5 '||:'dm12'||'..open',
 'everyone without a last day ends the old row for good: '||pg_temp.gr_rows(pg_temp.gr_item('GR Pear'),NULL));
-- A last day just before a planned rate works and leaves it alone (no stray copy).
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-E3',:'dm3'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Date',2,10)),
  jsonb_build_array(pg_temp.gr_rate('everyone','GR Date',0,50,6,2,5,:'dp4'::date))) AS e3 \gset
SELECT pg_temp.gr_assert(:'e3'::jsonb->>'success'='true'
 AND pg_temp.gr_rows(pg_temp.gr_item('GR Date'),NULL)
   ='0-50@3.00/1.00/5 '||:'d100'||'..'||:'dm4'||' | 0-50@6.00/2.00/5 '||:'dm3'||'..'||:'dp4'||' | 0-50@5.00/1.00/5 '||:'dp5'||'..open',
 'a last day the day before a planned rate: '||pg_temp.gr_rows(pg_temp.gr_item('GR Date'),NULL));
-- RATE_PLANNED: the typed last day reaches the planned rate. Nothing is saved.
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-E4',:'dm3'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Date',2,10)),
  jsonb_build_array(pg_temp.gr_rate('everyone','GR Date',0,50,7,2,5,:'dp10'::date))) AS planned \gset
SELECT pg_temp.gr_assert(:'planned'::jsonb->>'error_code'='RATE_PLANNED' AND :'planned'::jsonb->>'message' IS NOT NULL
 AND (:'planned'::jsonb#>>'{data,index}')::int=0 AND :'planned'::jsonb#>>'{data,starts_on}'=:'dp5'
 AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='GRN-E4')
 AND pg_temp.gr_rows(pg_temp.gr_item('GR Date'),NULL)
   ='0-50@3.00/1.00/5 '||:'d100'||'..'||:'dm4'||' | 0-50@6.00/2.00/5 '||:'dm3'||'..'||:'dp4'||' | 0-50@5.00/1.00/5 '||:'dp5'||'..open',
 'RATE_PLANNED names the planned start and saves nothing: '||:'planned');
-- BANDS_OVERLAP: a band that cuts across the two bands of Lime; and two overlapping GRN-only bands.
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-L1',:'dm3'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Lime',2,8)),
  jsonb_build_array(pg_temp.gr_rate('everyone','GR Lime',5,20,6,2,5))) AS overlap \gset
SELECT pg_temp.gr_assert(:'overlap'::jsonb->>'error_code'='BANDS_OVERLAP' AND (:'overlap'::jsonb#>>'{data,index}')::int=0
 AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='GRN-L1')
 AND pg_temp.gr_rows(pg_temp.gr_item('GR Lime'),NULL)='0-10@3.00/1.00/5 '||:'d100'||'..open | 11-50@4.00/1.00/5 '||:'d100'||'..open',
 'a partial band overlap is refused, nothing changes: '||:'overlap');
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-L2',:'dm3'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Plum',2,8)),
  jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',0,10,6,2,5),pg_temp.gr_rate('grn','GR Plum',8,20,7,2,5))) AS overlap2 \gset
SELECT pg_temp.gr_assert(:'overlap2'::jsonb->>'error_code'='BANDS_OVERLAP' AND (:'overlap2'::jsonb#>>'{data,index}')::int=1
 AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='GRN-L2'),'overlapping GRN-only bands of one item: '||:'overlap2');
-- RATE_NOT_FOR_GRN: an item that is not on the GRN (second entry), and a band that holds no line weight.
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-N1',:'dm3'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Plum',2,10)),
  jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',0,50,6,2,5),pg_temp.gr_rate('grn','GR Kiwi',0,50,6,2,5))) AS not_item \gset
SELECT pg_temp.gr_assert(:'not_item'::jsonb->>'error_code'='RATE_NOT_FOR_GRN' AND (:'not_item'::jsonb#>>'{data,index}')::int=1
 AND (:'not_item'::jsonb#>>'{data,item_id}')::uuid=pg_temp.gr_item('GR Kiwi') AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='GRN-N1'),
 'an item that is not on the GRN: '||:'not_item');
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-N2',:'dm3'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Plum',2,10)),
  jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',20,30,6,2,5))) AS not_band \gset
SELECT pg_temp.gr_assert(:'not_band'::jsonb->>'error_code'='RATE_NOT_FOR_GRN' AND (:'not_band'::jsonb#>>'{data,index}')::int=0
 AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='GRN-N2'),'a band that holds no line weight: '||:'not_band');

-- ---------------------------------------------------------------------------
-- 9. Weight NULL is priced as 0; a ONE_TIME GRN stores labour 0
-- ---------------------------------------------------------------------------
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-W0',:'dm3'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Quince',2,NULL)),
  jsonb_build_array(pg_temp.gr_rate('grn','GR Quince',0,0,3,1,5))) AS w0 \gset
SELECT pg_temp.gr_assert(:'w0'::jsonb->>'success'='true' AND pg_temp.gr_own('GRN-W0')='GR Quince 0-0@3.00/1.00/5 monthly','a line without weight is priced as 0 kg: '||:'w0');
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-W1',:'dm3'::date,:'orchard'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Quince',2,NULL)),
  jsonb_build_array(pg_temp.gr_rate('grn','GR Quince',1,5,3,1,5))) AS w1 \gset
SELECT pg_temp.gr_assert(:'w1'::jsonb->>'error_code'='RATE_NOT_FOR_GRN','a band from 1 kg holds no 0 kg line: '||:'w1');
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-OT',:'dm3'::date,:'orchard'::uuid,'ONE_TIME',jsonb_build_array(pg_temp.gr_line('GR Mango',2,10),pg_temp.gr_line('GR Plum',1,10)),
  jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',0,50,11,99,18),pg_temp.gr_rate('customer','GR Mango',0,50,12,77,18))) AS ot \gset
SELECT pg_temp.gr_assert(:'ot'::jsonb->>'success'='true' AND pg_temp.gr_own('GRN-OT')='GR Plum 0-50@11.00/0.00/18 one_time'
 AND pg_temp.gr_rows(pg_temp.gr_item('GR Mango'),:'orchard'::uuid,'one_time')='0-50@12.00/0.00/18 '||:'dm3'||'..open'
 AND (SELECT unit_price_one_time=12 AND unit_price_monthly=0 FROM public.item_storage_prices WHERE item_id=pg_temp.gr_item('GR Mango') AND customer_id=:'orchard'::uuid),
 'a ONE_TIME GRN stores labour 0 in both kinds of row: '||:'ot'||pg_temp.gr_own('GRN-OT'));
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-OT2',:'dm3'::date,:'orchard'::uuid,'ONE_TIME',jsonb_build_array(pg_temp.gr_line('GR Plum',1,10)),
  jsonb_build_array(jsonb_build_object('scope','grn','item_id',pg_temp.gr_item('GR Plum'),'weight_min',0,'weight_max',50,'unit_price',4,'tax_percent',18))) AS ot2 \gset
SELECT pg_temp.gr_assert(:'ot2'::jsonb->>'success'='true' AND pg_temp.gr_own('GRN-OT2')='GR Plum 0-50@4.00/0.00/18 one_time','a ONE_TIME entry needs no labour');

-- ---------------------------------------------------------------------------
-- 10. Validation, one case per code; none of them saves a GRN
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE gr_bad(label text, rates jsonb, code text, idx integer, field text) ON COMMIT DROP;
INSERT INTO gr_bad VALUES
 ('not a list', '{"scope":"grn"}', 'INVALID_BANDS', NULL, NULL),
 ('an entry that is not an object', '[1]', 'INVALID_BANDS', 0, NULL),
 ('unknown scope', jsonb_build_array(jsonb_set(pg_temp.gr_rate('grn','GR Plum',0,50,6,2,5),'{scope}','"planet"')), 'INVALID_SCOPE', 0, NULL),
 ('a weight that is not whole', jsonb_build_array(jsonb_set(pg_temp.gr_rate('grn','GR Plum',0,50,6,2,5),'{weight_min}','0.5')), 'INVALID_BAND', 0, 'weight_min'),
 ('a weight missing', jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',0,50,6,2,5) - 'weight_max'), 'INVALID_BAND', 0, 'weight_max'),
 ('start after end', jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',20,10,6,2,5)), 'INVALID_BAND', 0, NULL),
 ('three decimals', jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',0,50,6.001,2,5)), 'INVALID_AMOUNT', 0, 'unit_price'),
 ('labour missing on a monthly GRN', jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',0,50,6,2,5) - 'labour_rate'), 'INVALID_AMOUNT', 0, 'labour_rate'),
 ('tax over 100', jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',0,50,6,2,101)), 'INVALID_AMOUNT', 0, 'tax_percent'),
 ('a last day before the GRN day', jsonb_build_array(pg_temp.gr_rate('everyone','GR Plum',0,50,6,2,5,(:'dm3'::date)-1)), 'INVALID_DATE', 0, NULL),
 ('a last day that is no date', jsonb_build_array(jsonb_set(pg_temp.gr_rate('everyone','GR Plum',0,50,6,2,5),'{to}','"2026-02-30"')), 'INVALID_DATE', 0, NULL);
CREATE FUNCTION pg_temp.gr_bad_failures(claims jsonb, p_customer uuid, p_day date) RETURNS text LANGUAGE plpgsql AS $$
DECLARE b record; a jsonb; bad text := '';
BEGIN
  FOR b IN SELECT * FROM gr_bad LOOP
    a := pg_temp.gr_save(claims,'GRN-BAD',p_day,p_customer,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Plum',1,10)),b.rates);
    IF NOT (a->>'success'='false' AND a->>'error_code'=b.code AND a->>'message'=a->>'error'
            AND (b.idx IS NULL OR (a#>>'{data,index}')::int=b.idx) AND (b.field IS NULL OR a#>>'{data,field}'=b.field)) THEN
      bad := bad || b.label || ' -> ' || a::text || E'\n';
    END IF;
  END LOOP;
  RETURN bad;
END $$;
SELECT pg_temp.gr_assert((SELECT count(*)=11 FROM gr_bad),'eleven validation cases');
SELECT pg_temp.gr_bad_failures(:'staff_claims'::jsonb,:'orchard'::uuid,:'dm3'::date) AS bad_failures \gset
SELECT pg_temp.gr_assert(:'bad_failures'='','every validation failure has its code, index, field and message: '||:'bad_failures');
SELECT pg_temp.gr_assert(NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='GRN-BAD'),'no refused call saved a GRN');

-- ---------------------------------------------------------------------------
-- 11. Who sees grn_rates directly
-- ---------------------------------------------------------------------------
SELECT pg_temp.gr_save(:'staff_claims'::jsonb,'GRN-OTH',:'dm3'::date,:'other'::uuid,'MONTHLY',jsonb_build_array(pg_temp.gr_line('GR Plum',1,10)),
  jsonb_build_array(pg_temp.gr_rate('grn','GR Plum',0,50,13,2,5))) AS oth \gset
SELECT pg_temp.gr_assert(:'oth'::jsonb->>'success'='true','a GRN of another business: '||:'oth');
SELECT count(*) AS all_rates FROM public.grn_rates \gset
SELECT count(*) AS orchard_rates FROM public.grn_rates r JOIN public.goodsreceived g ON g.id=r.gr_id WHERE g.customer_id=:'orchard'::uuid \gset
SELECT pg_temp.gr_assert(:'orchard_rates'::int>0 AND :'all_rates'::int>:'orchard_rates'::int,'fixture: rates of two businesses');
SELECT pg_temp.gr_as(:'admin_claims'::jsonb,'SELECT jsonb_build_object(''n'',count(*)) FROM public.grn_rates')->>'n' AS n_admin \gset
SELECT pg_temp.gr_as(:'staff_claims'::jsonb,'SELECT jsonb_build_object(''n'',count(*)) FROM public.grn_rates')->>'n' AS n_staff \gset
SELECT pg_temp.gr_as(:'customer_claims'::jsonb,'SELECT jsonb_build_object(''n'',count(*)) FROM public.grn_rates')->>'n' AS n_customer \gset
SELECT pg_temp.gr_assert(:'n_admin'::int=:'all_rates'::int AND :'n_customer'::int=:'orchard_rates'::int AND :'n_staff'::int=0,
 'direct reads: administrator all ('||:'n_admin'||'), customer its own business only ('||:'n_customer'||' of '||:'all_rates'||'), staff only through the RPCs ('||:'n_staff'||')');
SELECT pg_temp.gr_assert(pg_temp.gr_as(:'admin_claims'::jsonb,$q$WITH d AS (DELETE FROM public.grn_rates RETURNING 1) SELECT jsonb_build_object('n',count(*)) FROM d$q$)->>'state'='42501',
 'a direct delete is refused even for an administrator');

-- ---------------------------------------------------------------------------
-- 12. The rate start floor: the first GRN's India day, never after today
-- ---------------------------------------------------------------------------
SELECT pg_temp.gr_assert(warehouse_security.rate_start_floor()=:'dm12'::date,'with GRNs: the day of the first live GRN: '||warehouse_security.rate_start_floor());
-- A deleted GRN older than everything does not count; a GRN at 1999-12-31 20:00 UTC is 2000-01-01 in India.
INSERT INTO public.goodsreceived(id,gr_no,date,customer_id,customer_name,deleted_at) VALUES
 ('66660000-0000-4000-8000-000000000001','GRN-OD','1990-05-05 10:00+00',:'orchard'::uuid,'GR Orchard',now()),
 ('66660000-0000-4000-8000-000000000002','GRN-OL','1999-12-31 20:00+00',:'orchard'::uuid,'GR Orchard',NULL);
SELECT pg_temp.gr_assert(warehouse_security.rate_start_floor()='2000-01-01'::date,'the floor is the India day (2000-01-01, not 1999-12-31): '||warehouse_security.rate_start_floor());
SELECT pg_temp.gr_as(:'admin_claims'::jsonb,'SELECT public.get_item_storage_prices(''{}''::jsonb,''item_name'',''asc'',5,0)') AS prices \gset
SELECT pg_temp.gr_assert(:'prices'::jsonb->>'success'='true' AND :'prices'::jsonb->>'earliest_start'='2000-01-01' AND jsonb_typeof(:'prices'::jsonb->'data')='array',
 'get_item_storage_prices answers earliest_start beside data: '||(:'prices'::jsonb->>'earliest_start'));
-- replace_item_rates: the floor day itself is accepted, the day before is refused with data.earliest.
SELECT pg_temp.gr_as(:'admin_claims'::jsonb,format($q$SELECT public.replace_item_rates(%L::uuid,NULL,'monthly',%L::date,%L::jsonb,false,'change')$q$,
  pg_temp.gr_item('GR Plum'),'1999-12-31',jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',50,'unit_price',2,'labour_rate',1,'tax_percent',5)))) AS rep_before \gset
SELECT pg_temp.gr_assert(:'rep_before'::jsonb->>'error_code'='INVALID_DATE' AND :'rep_before'::jsonb#>>'{data,earliest}'='2000-01-01'
 AND :'rep_before'::jsonb->>'error'='The start date must be on or after 2000-01-01 and within two years after today','replace_item_rates refuses the day before the floor: '||:'rep_before');
SELECT pg_temp.gr_as(:'admin_claims'::jsonb,format($q$SELECT public.replace_item_rates(%L::uuid,NULL,'monthly',%L::date,%L::jsonb,false,'change')$q$,
  pg_temp.gr_item('GR Plum'),'2000-01-01',jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',50,'unit_price',2,'labour_rate',1,'tax_percent',5)))) AS rep_on \gset
SELECT pg_temp.gr_assert(:'rep_on'::jsonb->>'success'='true' AND pg_temp.gr_rows(pg_temp.gr_item('GR Plum'),NULL)='0-50@2.00/1.00/5 2000-01-01..open','replace_item_rates accepts the floor day: '||:'rep_on');
SELECT pg_temp.gr_as(:'admin_claims'::jsonb,format($q$SELECT public.replace_item_rates(%L::uuid,NULL,'monthly',%L::date,%L::jsonb,false,'change',%L::date)$q$,
  pg_temp.gr_item('GR Plum'),:'dm5',jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',50,'unit_price',2,'labour_rate',1,'tax_percent',5)),'1999-12-31')) AS rep_move \gset
SELECT pg_temp.gr_assert(:'rep_move'::jsonb->>'error_code'='INVALID_DATE' AND :'rep_move'::jsonb#>>'{data,earliest}'='2000-01-01','p_move_from before the floor is refused too: '||:'rep_move');
-- undo_rate_change: likewise.
SELECT pg_temp.gr_as(:'admin_claims'::jsonb,format($q$SELECT public.undo_rate_change(%L::uuid,NULL,'monthly',%L::date)$q$,pg_temp.gr_item('GR Plum'),'1999-12-31')) AS undo_before \gset
SELECT pg_temp.gr_assert(:'undo_before'::jsonb->>'error_code'='INVALID_DATE' AND :'undo_before'::jsonb#>>'{data,earliest}'='2000-01-01','undo_rate_change refuses the day before the floor: '||:'undo_before');
SELECT pg_temp.gr_as(:'admin_claims'::jsonb,format($q$SELECT public.undo_rate_change(%L::uuid,NULL,'monthly',%L::date)$q$,pg_temp.gr_item('GR Plum'),'2000-01-01')) AS undo_on \gset
SELECT pg_temp.gr_assert(:'undo_on'::jsonb->>'success'='true' AND pg_temp.gr_rows(pg_temp.gr_item('GR Plum'),NULL)='(none)','undo_rate_change accepts the floor day: '||:'undo_on');
-- The upper bound is as before.
SELECT pg_temp.gr_as(:'admin_claims'::jsonb,format($q$SELECT public.undo_rate_change(%L::uuid,NULL,'monthly',%L::date)$q$,pg_temp.gr_item('GR Plum'),(:'today'::date+731)::text)) AS undo_far \gset
SELECT pg_temp.gr_assert(:'undo_far'::jsonb->>'error_code'='INVALID_DATE','two years after today is still the upper bound');

-- direct_write_guard.sql and role_allowlist.sql cover the table and the new function.
ROLLBACK;
