-- Migration 123, section 9: an app role cannot read the 18 tables the app never reads directly (no SELECT grant, no policy, row security
-- still on), while the direct reads the app, the PDF edge functions and the Storage policies make still work for an administrator, a
-- customer and anon. Fictional data; runs only in migrations.sh's disposable, network-disabled database; everything rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.tr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'table reads removed: %',label; END IF; END $$;
-- The 18 tables whose app-role read was removed.
CREATE FUNCTION pg_temp.tr_removed() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['grn_rates','invoice_discount_history','invoice_zero_charge_history','item_price_history','item_storage_prices',
    'order_items','order_revisions','orders','payments','print_jobs','printer_status','sensor_devices','sensor_hubs','sensor_latest',
    'sensor_readings','standard_rate_tiers','stock_movements','users_customers_new'] $$;
-- Names every removed table the CURRENT role can still read: refused only counts when the error is 42501 (insufficient privilege).
CREATE FUNCTION pg_temp.tr_open_reads() RETURNS text LANGUAGE plpgsql AS $$
DECLARE t text; open text := '';
BEGIN
  FOREACH t IN ARRAY pg_temp.tr_removed() LOOP
    BEGIN
      EXECUTE format('SELECT count(*) FROM public.%I',t);
      open := open || ' ' || t;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;
  RETURN open;
END $$;
-- True when the statement fails with 42501.
CREATE FUNCTION pg_temp.tr_denied(statement text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement; EXCEPTION WHEN insufficient_privilege THEN RETURN true; WHEN OTHERS THEN RETURN false; END;
  RETURN false;
END $$;
CREATE FUNCTION pg_temp.tr_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.tr_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.tr_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;

-- 1. Catalog: no grant and no policy for an app role, row security on, service_role untouched.
SELECT pg_temp.tr_assert((SELECT count(*)=18 AND bool_and(c.relrowsecurity)
    AND bool_and(NOT has_any_column_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,REFERENCES'))
    AND bool_and(NOT has_table_privilege('authenticated',c.oid,'DELETE,TRUNCATE,TRIGGER'))
    AND bool_and(NOT has_any_column_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,REFERENCES'))
    AND bool_and(has_table_privilege('service_role',c.oid,'SELECT'))
  FROM pg_class c WHERE c.relnamespace='public'::regnamespace AND c.relname=ANY(pg_temp.tr_removed())),
 '18 tables: row security on, no privilege for authenticated or anon, SELECT kept for service_role');
SELECT pg_temp.tr_assert((SELECT count(*)=0 FROM pg_policies WHERE schemaname='public' AND tablename=ANY(pg_temp.tr_removed())),
 'the removed tables have no policy');
-- The tables the app still reads keep their grants and policies.
SELECT pg_temp.tr_assert((SELECT bool_and(has_any_column_privilege('authenticated',format('public.%I',t)::regclass,'SELECT'))
  FROM unnest(ARRAY['user_profiles','customers','goodsreceived','goodsreceived_trl','grn_images','items','feature_flags','dispatch','dispatch_trl',
    'dispatch_images','invoice','invoice_trl']) t),'the twelve readable tables keep the authenticated read');
-- invoice: the column grant of migration 48 (six internal columns stay unreadable).
SELECT pg_temp.tr_assert(has_column_privilege('authenticated','public.invoice','inv_no','SELECT')
  AND NOT has_column_privilege('authenticated','public.invoice','discount_reason','SELECT')
  AND NOT has_column_privilege('authenticated','public.invoice','zero_charge_reason','SELECT')
  AND NOT has_table_privilege('authenticated','public.invoice','SELECT'),'invoice: column grant, internal columns not readable');
SELECT pg_temp.tr_assert(has_table_privilege('anon','public.feature_flags','SELECT') AND NOT has_table_privilege('anon','public.items','SELECT'),
 'feature_flags is the one table anon reads');

-- 2. Fixture: an administrator, a customer login assigned to one customer with one receipt.
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888931','Table Reads Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888932','Table Reads Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888933','Table Reads Customer','customer',true,'approved');
SELECT pg_temp.tr_login('9888888931') AS admin_claims \gset
SELECT pg_temp.tr_login('9888888932') AS staff_claims \gset
SELECT pg_temp.tr_login('9888888933') AS customer_claims \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.tr_assert(public.create_customer('Table Reads Customer','9888888934')->>'success'='true','customer');
SELECT pg_temp.tr_assert(public.create_item('Table Reads Potatoes','Bag')->>'success'='true','catalog item');
SELECT id AS customer_id FROM public.customers WHERE name='Table Reads Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Table Reads Potatoes' \gset
SELECT pg_temp.tr_assert(public.assign_customer_to_user('919888888933',:'customer_id'::uuid,'Table reads fixture'),'customer login assigned');
SELECT pg_temp.tr_assert(public.replace_item_rates(:'item_id'::uuid,:'customer_id'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5)))->>'success'='true','rates');
SELECT pg_temp.tr_assert(public.save_grn(p_gr_no=>'TRA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Table Reads Customer',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'table-reads-a',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Table Reads Potatoes',
 'packaging','Bag','qty',10,'weight',10,'rack','R1')))->>'success'='true','receipt TRA');
SELECT public.get_or_create_cart(:'customer_id'::uuid) AS cart \gset
RESET ROLE;
SELECT id AS lot FROM public.goodsreceived_trl WHERE gr_id=(SELECT id FROM public.goodsreceived WHERE gr_no='TRA') \gset
SELECT pg_temp.tr_assert((SELECT count(*)>0 FROM public.orders) AND (SELECT count(*)>0 FROM public.item_storage_prices),
 'fixture: orders and item_storage_prices hold rows, so a refusal is not an empty table');

-- 3. Administrator and customer: every removed table is refused; the direct reads of the app work.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.tr_assert(warehouse_security.active_role()='admin','actual administrator role');
SELECT pg_temp.tr_assert(pg_temp.tr_open_reads()='','administrator: direct reads still open on' || pg_temp.tr_open_reads());
SELECT pg_temp.tr_assert((SELECT count(*)>=3 FROM public.user_profiles WHERE mobile IN ('919888888931','919888888932','919888888933')),'administrator reads every profile');
SELECT pg_temp.tr_assert((SELECT count(*)=1 FROM public.customers WHERE name='Table Reads Customer'),'administrator reads customers');
SELECT pg_temp.tr_assert((SELECT count(*)=1 FROM public.goodsreceived WHERE gr_no='TRA'),'administrator reads goodsreceived');
SELECT pg_temp.tr_assert((SELECT count(*)=1 FROM public.goodsreceived_trl WHERE id=:'lot'::uuid),'administrator reads goodsreceived_trl');
SELECT pg_temp.tr_assert((SELECT count(*)>=0 FROM public.grn_images) AND (SELECT count(*)>=0 FROM public.dispatch) AND (SELECT count(*)>=0 FROM public.dispatch_trl)
  AND (SELECT count(*)>=0 FROM public.dispatch_images) AND (SELECT count(inv_no)>=0 FROM public.invoice) AND (SELECT count(id)>=0 FROM public.invoice_trl),
 'administrator reads grn_images, dispatch, dispatch_trl, dispatch_images, invoice (columns) and invoice_trl');
SELECT pg_temp.tr_assert((SELECT count(*)=1 FROM public.items WHERE name='Table Reads Potatoes'),'administrator reads items');
SELECT pg_temp.tr_assert((SELECT count(*)>=0 FROM public.feature_flags),'administrator reads feature_flags');
SELECT pg_temp.tr_assert(pg_temp.tr_denied('SELECT discount_reason FROM public.invoice'),'administrator: an internal invoice column is refused');
-- What the screens use instead keeps working.
SELECT pg_temp.tr_assert(public.get_available_stock(:'lot'::uuid)=10,'get_available_stock (security invoker) still reads goodsreceived_trl');
SELECT pg_temp.tr_assert(public.get_print_jobs()->>'success'='true','get_print_jobs reads print_jobs with the owner''s rights');
SELECT pg_temp.tr_assert(jsonb_array_length(public.get_orders_list()#>'{data,orders}')=1,'get_orders_list reads orders with the owner''s rights');
SELECT pg_temp.tr_assert(public.get_standard_rate() IS NOT NULL,'get_standard_rate reads standard_rate_tiers with the owner''s rights');
SELECT pg_temp.tr_assert(jsonb_typeof(public.get_item_storage_prices()->'data')='array' OR public.get_item_storage_prices()->>'success'='true','get_item_storage_prices reads the prices');
RESET ROLE;

SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.tr_assert(warehouse_security.active_role()='customer','actual customer role');
SELECT pg_temp.tr_assert(pg_temp.tr_open_reads()='','customer: direct reads still open on' || pg_temp.tr_open_reads());
SELECT pg_temp.tr_assert((SELECT count(*)=1 FROM public.user_profiles),'the customer reads its own profile only');
SELECT pg_temp.tr_assert((SELECT count(*)=1 FROM public.customers WHERE name='Table Reads Customer'),'the customer reads its assigned customer');
SELECT pg_temp.tr_assert((SELECT count(*)=1 FROM public.goodsreceived WHERE gr_no='TRA') AND (SELECT count(*)=1 FROM public.goodsreceived_trl WHERE id=:'lot'::uuid),
 'the customer reads its receipt and lot');
SELECT pg_temp.tr_assert((SELECT count(*)>=1 FROM public.items WHERE name='Table Reads Potatoes'),'the customer reads the catalog');
SELECT pg_temp.tr_assert((SELECT count(inv_no)>=0 FROM public.invoice) AND (SELECT count(*)>=0 FROM public.grn_images),'the customer reads invoice columns and confirmed images');
SELECT pg_temp.tr_assert(pg_temp.tr_denied('SELECT zero_charge_reason FROM public.invoice'),'the customer: an internal invoice column is refused');
SELECT pg_temp.tr_assert(public.get_available_stock(:'lot'::uuid)=10,'the customer still reads the stock of its own lot');
SELECT pg_temp.tr_assert(jsonb_array_length(public.get_orders_list()#>'{data,orders}')=1,'the customer still lists its cart through get_orders_list');
RESET ROLE;

-- The staff role is refused the same tables, and anon reads only feature_flags.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.tr_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT pg_temp.tr_assert(pg_temp.tr_open_reads()='','staff: direct reads still open on' || pg_temp.tr_open_reads());
RESET ROLE;
SELECT set_config('request.jwt.claims','{"role":"anon"}',true);
SET LOCAL ROLE anon;
SELECT pg_temp.tr_assert(pg_temp.tr_open_reads()='','anon: direct reads still open on' || pg_temp.tr_open_reads());
SELECT pg_temp.tr_assert((SELECT count(*)>=0 FROM public.feature_flags),'anon reads feature_flags');
SELECT pg_temp.tr_assert(pg_temp.tr_denied('SELECT count(*) FROM public.items') AND pg_temp.tr_denied('SELECT count(*) FROM public.user_profiles'),'anon reads no other table');
RESET ROLE;
ROLLBACK;
