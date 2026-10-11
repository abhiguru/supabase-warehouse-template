-- Migration 42: the nineteen business tables are written only through the
-- guarded RPCs. For the administrator and the supervisor a direct INSERT, UPDATE
-- or DELETE is refused on every one of them, reads are unchanged, and the RPC
-- paths still apply their rules (server totals, rate limits, stock checks, the
-- dependency-checked deletes, order history). Fictional data; runs only in
-- migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.guard_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'direct write guard: %',label; END IF; END $$;
-- True only when the statement is refused for lack of privilege (42501). A
-- statement that runs, or fails for any other reason, is not a refusal.
CREATE FUNCTION pg_temp.guard_denied(statement text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement; EXCEPTION WHEN insufficient_privilege THEN RETURN true; WHEN OTHERS THEN RETURN false; END;
  RETURN false;
END $$;
CREATE FUNCTION pg_temp.guard_tables() RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT ARRAY['customers','items','item_storage_prices','goodsreceived','goodsreceived_trl',
    'dispatch','dispatch_trl','invoice','invoice_trl','payments','orders','order_items','grn_images','dispatch_images',
    'stock_movements','print_jobs','sensor_devices','sensor_readings','sensor_health_events'] $$;
-- Runs as the caller. Names every business table on which a direct INSERT,
-- UPDATE or DELETE is NOT refused; the result is empty when all 57 are refused.
-- The statements touch no row (DEFAULT VALUES fails on a NOT NULL column when
-- it is allowed to run, WHERE false matches nothing), so a table that lets one
-- through is reported, not changed.
CREATE FUNCTION pg_temp.guard_open_writes() RETURNS text LANGUAGE plpgsql AS $$
DECLARE table_name text; first_column text; open text := '';
BEGIN
  FOREACH table_name IN ARRAY pg_temp.guard_tables() LOOP
    SELECT attname INTO STRICT first_column FROM pg_attribute
      WHERE attrelid=format('public.%I',table_name)::regclass AND attnum=1;
    IF NOT pg_temp.guard_denied(format('INSERT INTO public.%I DEFAULT VALUES',table_name)) THEN open := open || ' insert:' || table_name; END IF;
    IF NOT pg_temp.guard_denied(format('UPDATE public.%I SET %I=%I WHERE false',table_name,first_column,first_column)) THEN open := open || ' update:' || table_name; END IF;
    IF NOT pg_temp.guard_denied(format('DELETE FROM public.%I WHERE false',table_name)) THEN open := open || ' delete:' || table_name; END IF;
  END LOOP;
  RETURN open;
END $$;
-- Runs as the caller: rows visible in each business table.
CREATE FUNCTION pg_temp.guard_visible() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE table_name text; visible bigint; result jsonb := '{}';
BEGIN
  FOREACH table_name IN ARRAY pg_temp.guard_tables() LOOP
    EXECUTE format('SELECT count(*) FROM public.%I',table_name) INTO visible;
    result := result || jsonb_build_object(table_name,visible);
  END LOOP;
  RETURN result;
END $$;
CREATE FUNCTION pg_temp.guard_update(invoice uuid, header jsonb, items jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.update_invoice(invoice, header, ARRAY(SELECT jsonb_array_elements(items))) $$;
CREATE FUNCTION pg_temp.guard_rates(items jsonb, rates jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(item || rates) FROM jsonb_array_elements(items) AS item $$;
CREATE FUNCTION pg_temp.guard_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.guard_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.guard_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;

-- 1. Catalog. The shared role has no direct write on any public table except
-- the two profile columns; reads and service_role are untouched.
SELECT pg_temp.guard_assert((SELECT bool_and(
   has_table_privilege('authenticated',format('public.%I',t)::regclass,'SELECT')
   AND NOT has_any_column_privilege('authenticated',format('public.%I',t)::regclass,'INSERT,UPDATE')
   AND NOT has_table_privilege('authenticated',format('public.%I',t)::regclass,'DELETE,TRUNCATE')
   AND NOT has_any_column_privilege('anon',format('public.%I',t)::regclass,'SELECT,INSERT,UPDATE')
   AND has_table_privilege('service_role',format('public.%I',t)::regclass,'INSERT')
   AND has_table_privilege('service_role',format('public.%I',t)::regclass,'UPDATE')
   AND has_table_privilege('service_role',format('public.%I',t)::regclass,'DELETE'))
  AND count(*)=19 FROM unnest(pg_temp.guard_tables()) AS t),
 'authenticated reads and cannot write the 19 business tables; service_role still writes them');
SELECT pg_temp.guard_assert((SELECT count(*)=0 FROM pg_class c
  WHERE c.relnamespace='public'::regnamespace AND c.relkind IN ('r','p','v','m') AND c.relname<>'user_profiles'
    AND (has_any_column_privilege('authenticated',c.oid,'INSERT,UPDATE') OR has_table_privilege('authenticated',c.oid,'DELETE,TRUNCATE'))),
 'no other public table or view is writable by authenticated');
SELECT pg_temp.guard_assert((SELECT array_agg(column_name::text ORDER BY column_name::text)=ARRAY['display_name','name']
  FROM information_schema.column_privileges
  WHERE table_schema='public' AND table_name='user_profiles' AND grantee='authenticated' AND privilege_type='UPDATE'),
 'the profile column grant UPDATE(name, display_name) is unchanged');
SELECT pg_temp.guard_assert(NOT has_any_column_privilege('authenticated','public.user_profiles','INSERT')
  AND NOT has_table_privilege('authenticated','public.user_profiles','DELETE'),'profiles are not inserted or deleted directly');
SELECT pg_temp.guard_assert((SELECT bool_and(cmd='SELECT') AND count(*)=19 FROM pg_policies
  WHERE schemaname='public' AND policyname='starter_staff' AND tablename=ANY(pg_temp.guard_tables())),
 'the administrator and supervisor policy on each business table is read-only');
SELECT pg_temp.guard_assert((SELECT count(*)=1 AND bool_and(tablename='user_profiles' AND policyname='starter_profile_update' AND cmd='UPDATE')
  FROM pg_policies WHERE schemaname='public' AND cmd<>'SELECT'),'the only write policy left is the own-profile update');
-- The RPCs must not depend on the caller's table privileges: everything the
-- shared role may execute runs with the owner's rights, except the one
-- read-only stock lookup.
SELECT pg_temp.guard_assert((SELECT array_agg(p.oid::regprocedure::text)=ARRAY['get_available_stock(uuid)']
  FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND NOT p.prosecdef
    AND has_function_privilege('authenticated',p.oid,'EXECUTE')),
 'every granted function except get_available_stock is SECURITY DEFINER');
SELECT pg_temp.guard_assert((SELECT bool_and(pg_get_userbyid(p.proowner)=pg_get_userbyid(c.relowner))
  FROM pg_proc p, pg_class c WHERE p.pronamespace='public'::regnamespace AND p.prosecdef
    AND has_function_privilege('authenticated',p.oid,'EXECUTE')
    AND c.relnamespace='public'::regnamespace AND c.relname=ANY(pg_temp.guard_tables())),
 'the granted functions are owned by the owner of the business tables');
SELECT pg_temp.guard_assert(has_function_privilege('authenticated','public.update_order_metadata(uuid,text,text,timestamp without time zone)','EXECUTE')
  AND NOT has_function_privilege('anon','public.update_order_metadata(uuid,text,text,timestamp without time zone)','EXECUTE'),
 'update_order_metadata is granted to signed-in users only');

-- Fixture accounts: administrator, supervisor, staff, and a customer login
-- assigned to the fixture customer.
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888821','Write Guard Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888822','Write Guard Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888823','Write Guard Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888824','Write Guard Customer Reader','customer',true,'approved');
SELECT pg_temp.guard_login('9888888821') AS admin_claims \gset
SELECT pg_temp.guard_login('9888888822') AS supervisor_claims \gset
SELECT pg_temp.guard_login('9888888823') AS staff_claims \gset
SELECT pg_temp.guard_login('9888888824') AS customer_claims \gset

-- Fixture documents, written by the administrator through the RPCs only. Price
-- 5 per bag, labour 2, tax 5%.
--   WGA  monthly, 100 bags received 2026-04-01, dispatched 20 + 80 on
--        2026-05-02 and invoiced: the INVOICE_RULES fixture, total 998
--   WGB  10 bags in stock; 3 of them are in the customer's cart
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.guard_assert(warehouse_security.active_role()='admin','actual administrator role');
SELECT pg_temp.guard_assert(public.create_customer('Write Guard Customer','9888888825')->>'success'='true','customer');
SELECT pg_temp.guard_assert(public.create_item('Write Guard Potatoes','Bag')->>'success'='true','catalog item');
SELECT id AS customer_id FROM public.customers WHERE name='Write Guard Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Write Guard Potatoes' \gset
SELECT pg_temp.guard_assert(public.assign_customer_to_user('919888888824',:'customer_id'::uuid,'Write guard fixture'),'customer login assigned');
SELECT pg_temp.guard_assert(public.create_item_storage_price(p_item_id=>:'item_id'::uuid,p_price_type=>'monthly',p_unit_price=>5,
 p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_effective_from=>'2026-01-01',
 p_customer_id=>:'customer_id'::uuid,p_tax_percent=>5)->>'success'='true','monthly price');
SELECT pg_temp.guard_assert(public.save_grn(p_gr_no=>'WGA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Write Guard Customer',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'write-guard-a',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Write Guard Potatoes',
 'packaging','Bag','qty',100,'weight',10,'rack','R1')))->>'success'='true','receipt WGA');
SELECT pg_temp.guard_assert(public.save_grn(p_gr_no=>'WGB',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Write Guard Customer',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'write-guard-b',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Write Guard Potatoes',
 'packaging','Bag','qty',10,'weight',10,'rack','R2')))->>'success'='true','receipt WGB');
SELECT id AS grn_a FROM public.goodsreceived WHERE gr_no='WGA' \gset
SELECT id AS grn_b FROM public.goodsreceived WHERE gr_no='WGB' \gset
SELECT id AS lot_a FROM public.goodsreceived_trl WHERE gr_id=:'grn_a'::uuid \gset
SELECT id AS lot_b FROM public.goodsreceived_trl WHERE gr_id=:'grn_b'::uuid \gset
SELECT jsonb_build_object('customer_id',:'customer_id','customer_name','Write Guard Customer',
 'supervisor_id',:'admin_profile','supervisor_name','Write Guard Administrator') AS dispatch_for \gset
SELECT pg_temp.guard_assert(public.create_dispatch_with_stock_check(:'dispatch_for'::jsonb || '{"disp_no":"WGA1","disp_date":"2026-05-02"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a','disp_qty',20)],0,'write-guard-a1')->>'success'='true','WGA first dispatch');
SELECT pg_temp.guard_assert(public.create_dispatch_with_stock_check(:'dispatch_for'::jsonb || '{"disp_no":"WGA2","disp_date":"2026-05-02"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a','disp_qty',80)],0,'write-guard-a2')->>'success'='true','WGA final dispatch');
SELECT jsonb_agg(jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2) ORDER BY t.disp_qty) AS a_items
 FROM public.dispatch_trl t WHERE t.gr_id=:'grn_a'::uuid \gset
SELECT jsonb_build_object('inv_no',20261091,'inv_fin_year',2026,'customer_id',:'customer_id','customer_name','Write Guard Customer',
 'inv_date','2026-05-02T12:00:00Z','total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy',
 'gr_id',:'grn_a','gr_no','WGA') AS a_header \gset
SELECT public.save_invoice(:'a_header'::jsonb || jsonb_build_object('items',:'a_items'::jsonb)) AS saved \gset
SELECT pg_temp.guard_assert(:'saved'::jsonb->>'success'='true','invoice saved through the RPC: ' || :'saved');
SELECT (:'saved'::jsonb->>'invoice_id') AS invoice_a \gset
SELECT public.get_or_create_cart(:'customer_id'::uuid) AS cart \gset
SELECT pg_temp.guard_assert(public.add_item_to_order(:'cart'::uuid,:'lot_b'::uuid,3)->>'success'='true','cart line');
RESET ROLE;
SELECT pg_temp.guard_assert((SELECT total=998 AND tax_amount=48 AND labour=200 FROM public.invoice WHERE id=:'invoice_a'::uuid),'fixture invoice total 998');
SELECT id AS dispatch_line FROM public.dispatch_trl WHERE gr_id=:'grn_a'::uuid AND disp_qty=20 \gset
SELECT id AS dispatch_a1 FROM public.dispatch WHERE disp_no='WGA1' \gset
-- Row counts as the database owner, to compare with what each role reads.
SELECT pg_temp.guard_visible() AS actual \gset
SELECT pg_temp.guard_assert((SELECT bool_and((:'actual'::jsonb->>t)::int >= 1)
  FROM unnest(ARRAY['customers','items','item_storage_prices','goodsreceived','goodsreceived_trl','dispatch','dispatch_trl',
    'invoice','invoice_trl','orders','order_items']) AS t),'the fixture put rows in eleven of the tables: ' || :'actual');

-- 2. Administrator and supervisor: every direct write is refused, on empty
-- probes and on the real rows of the review scenarios; reads show every row.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.guard_assert(warehouse_security.active_role()='admin','actual administrator role');
SELECT pg_temp.guard_open_writes() AS admin_open \gset
SELECT pg_temp.guard_assert(:'admin_open'='','administrator: direct writes still open on' || :'admin_open');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$UPDATE public.invoice SET total=1, labour=0, tax_amount=0 WHERE id='$s$||:'invoice_a'||$s$'$s$),'administrator cannot patch invoice totals');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$UPDATE public.invoice SET discount=900 WHERE id='$s$||:'invoice_a'||$s$'$s$),'administrator cannot patch a discount');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$UPDATE public.invoice_trl SET charge=1 WHERE invoice_id='$s$||:'invoice_a'||$s$'$s$),'administrator cannot patch a line rate');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$UPDATE public.goodsreceived_trl SET stock=999 WHERE id='$s$||:'lot_b'||$s$'$s$),'administrator cannot patch stock');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$INSERT INTO public.stock_movements(gr_trl_id) VALUES ('$s$||:'lot_b'||$s$')$s$),'administrator cannot insert a stock movement');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$DELETE FROM public.dispatch_trl WHERE disp_id='$s$||:'dispatch_a1'||$s$'$s$),'administrator cannot delete dispatch lines');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$DELETE FROM public.dispatch WHERE id='$s$||:'dispatch_a1'||$s$'$s$),'administrator cannot delete a dispatch');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$UPDATE public.orders SET note='Direct' WHERE id='$s$||:'cart'||$s$'$s$),'administrator cannot patch an order');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$UPDATE public.customers SET active=false WHERE id='$s$||:'customer_id'||$s$'$s$),'administrator cannot patch a customer');
SELECT pg_temp.guard_visible() AS admin_sees \gset
SELECT pg_temp.guard_assert(:'admin_sees'::jsonb=:'actual'::jsonb,'administrator reads every row: ' || :'admin_sees');
-- The own-profile column grant still works; other profile columns do not.
UPDATE public.user_profiles SET name='Write Guard Admin Renamed' WHERE auth_user_id=:'admin_user'::uuid;
SELECT pg_temp.guard_assert((SELECT name='Write Guard Admin Renamed' FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid),'own profile name still editable');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$UPDATE public.user_profiles SET role='staff' WHERE auth_user_id='$s$||:'admin_user'||$s$'$s$),'role column is not directly editable');
RESET ROLE;

SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.guard_assert(warehouse_security.active_role()='supervisor','actual supervisor role');
SELECT pg_temp.guard_open_writes() AS supervisor_open \gset
SELECT pg_temp.guard_assert(:'supervisor_open'='','supervisor: direct writes still open on' || :'supervisor_open');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$UPDATE public.invoice SET total=1, labour=0, tax_amount=0 WHERE id='$s$||:'invoice_a'||$s$'$s$),'supervisor cannot patch invoice totals');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$UPDATE public.invoice SET discount=900 WHERE id='$s$||:'invoice_a'||$s$'$s$),'supervisor cannot patch a discount');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$UPDATE public.invoice_trl SET charge=1 WHERE invoice_id='$s$||:'invoice_a'||$s$'$s$),'supervisor cannot patch a line rate');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$UPDATE public.goodsreceived_trl SET stock=999 WHERE id='$s$||:'lot_b'||$s$'$s$),'supervisor cannot patch stock');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$INSERT INTO public.stock_movements(gr_trl_id) VALUES ('$s$||:'lot_b'||$s$')$s$),'supervisor cannot insert a stock movement');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$DELETE FROM public.dispatch_trl WHERE disp_id='$s$||:'dispatch_a1'||$s$'$s$),'supervisor cannot delete dispatch lines');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$DELETE FROM public.dispatch WHERE id='$s$||:'dispatch_a1'||$s$'$s$),'supervisor cannot delete a dispatch');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$UPDATE public.orders SET note='Direct' WHERE id='$s$||:'cart'||$s$'$s$),'supervisor cannot patch an order');
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$UPDATE public.customers SET active=false WHERE id='$s$||:'customer_id'||$s$'$s$),'supervisor cannot patch a customer');
SELECT pg_temp.guard_visible() AS supervisor_sees \gset
SELECT pg_temp.guard_assert(:'supervisor_sees'::jsonb=:'actual'::jsonb,'supervisor reads every row: ' || :'supervisor_sees');
RESET ROLE;
SELECT pg_temp.guard_assert((SELECT total=998 AND tax_amount=48 AND labour=200 AND discount=0 FROM public.invoice WHERE id=:'invoice_a'::uuid),'refused writes left the invoice header');
SELECT pg_temp.guard_assert((SELECT bool_and(charge=5) AND count(*)=2 FROM public.invoice_trl WHERE invoice_id=:'invoice_a'::uuid),'refused writes left the invoice lines');
SELECT pg_temp.guard_assert((SELECT stock=10 FROM public.goodsreceived_trl WHERE id=:'lot_b'::uuid),'refused writes left the stock');
SELECT pg_temp.guard_assert((SELECT count(*)=1 FROM public.dispatch_trl WHERE disp_id=:'dispatch_a1'::uuid),'refused writes left the dispatch');
SELECT pg_temp.guard_assert((SELECT note IS DISTINCT FROM 'Direct' FROM public.orders WHERE id=:'cart'::uuid),'refused writes left the order');
SELECT pg_temp.guard_assert((SELECT active FROM public.customers WHERE id=:'customer_id'::uuid),'refused writes left the customer');
SELECT pg_temp.guard_assert(pg_temp.guard_visible()=:'actual'::jsonb,'refused writes changed no row count');

-- 3. Staff and customer reads are the ones migrations 3, 18 and 22 gave them,
-- and their direct writes are refused as well.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.guard_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT pg_temp.guard_assert(pg_temp.guard_open_writes()='','staff: direct writes refused');
SELECT pg_temp.guard_visible() AS staff_sees \gset
SELECT pg_temp.guard_assert((SELECT bool_and(:'staff_sees'::jsonb->t = :'actual'::jsonb->t)
  FROM unnest(ARRAY['customers','goodsreceived','goodsreceived_trl','dispatch','dispatch_trl','invoice','invoice_trl','items']) AS t),
 'staff still reads customers, receipts, dispatches, invoices and the catalog: ' || :'staff_sees');
-- Migration 45 gives staff a row read on orders (the live queue); the price
-- and order-line tables stay closed to them.
SELECT pg_temp.guard_assert((:'staff_sees'::jsonb->>'item_storage_prices')::int=0 AND (:'staff_sees'::jsonb->>'order_items')::int=0
  AND :'staff_sees'::jsonb->'orders' = :'actual'::jsonb->'orders' AND (:'actual'::jsonb->>'order_items')::int>0,
 'staff read orders, and still no price or order line directly: ' || :'staff_sees');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.guard_assert(warehouse_security.active_role()='customer','actual customer role');
SELECT pg_temp.guard_assert(pg_temp.guard_open_writes()='','customer: direct writes refused');
SELECT pg_temp.guard_assert((SELECT count(*)=1 FROM public.invoice WHERE id=:'invoice_a'::uuid)
  AND (SELECT count(*)=2 FROM public.goodsreceived WHERE customer_id=:'customer_id'::uuid)
  AND (SELECT count(*)=1 FROM public.orders WHERE id=:'cart'::uuid)
  AND (SELECT count(*)=1 FROM public.order_items WHERE order_id=:'cart'::uuid)
  AND (SELECT count(*)=0 FROM public.item_storage_prices),'the assigned customer still reads its own documents and no prices');
RESET ROLE;

-- 4. The RPC paths work for the supervisor without table privileges and apply
-- their rules. A changed line rate recomputes the header: charge 6 gives
-- storage 6 x 100 x 1.5 = 900, labour 200, tax 5% of 1100 = 55, total 1155.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.guard_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"total":1,"tax_amount":0,"labour":0}'::jsonb,
 pg_temp.guard_rates(:'a_items'::jsonb,'{"charge":6}'::jsonb)) AS rate_change \gset
SELECT pg_temp.guard_assert(:'rate_change'::jsonb->>'success'='true','supervisor changes a line rate through update_invoice: ' || :'rate_change');
RESET ROLE;
SELECT pg_temp.guard_assert((SELECT total=1155 AND tax_amount=55 AND labour=200 FROM public.invoice WHERE id=:'invoice_a'::uuid),
 'the header is recomputed from the new rate, not taken from the client: '
 || (SELECT format('total %s tax %s labour %s',total,tax_amount,labour) FROM public.invoice WHERE id=:'invoice_a'::uuid));
SET LOCAL ROLE authenticated;
-- An out-of-range rate is refused and changes nothing.
SELECT pg_temp.guard_update(:'invoice_a'::uuid,:'a_header'::jsonb,pg_temp.guard_rates(:'a_items'::jsonb,'{"charge":-5}'::jsonb)) AS bad_rate \gset
SELECT pg_temp.guard_assert(:'bad_rate'::jsonb->>'success'='false' AND :'bad_rate'::jsonb->>'error' LIKE '%Invoice line charge must be between 0 and 999999%',
 'an out-of-range rate is refused: ' || :'bad_rate');
-- A dispatch larger than the stock is refused; one within it reduces the stock.
SELECT public.create_dispatch_with_stock_check(:'dispatch_for'::jsonb || '{"disp_no":"WGB9","disp_date":"2026-05-03"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',11)],0,'write-guard-b-over') AS over \gset
SELECT pg_temp.guard_assert(:'over'::jsonb->>'success'='false','a dispatch above the stock is refused: ' || :'over');
RESET ROLE;
SELECT pg_temp.guard_assert((SELECT total=1155 AND tax_amount=55 FROM public.invoice WHERE id=:'invoice_a'::uuid)
  AND (SELECT bool_and(charge=6) FROM public.invoice_trl WHERE invoice_id=:'invoice_a'::uuid),'the refused rate left the invoice');
SELECT pg_temp.guard_assert((SELECT stock=10 FROM public.goodsreceived_trl WHERE id=:'lot_b'::uuid)
  AND (SELECT count(*)=0 FROM public.dispatch WHERE disp_no='WGB9'),'the refused dispatch left the stock at 10 and no dispatch');
SET LOCAL ROLE authenticated;
SELECT pg_temp.guard_assert(public.create_dispatch_with_stock_check(:'dispatch_for'::jsonb || '{"disp_no":"WGB1","disp_date":"2026-05-03"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_b','disp_qty',4)],0,'write-guard-b1')->>'success'='true','supervisor dispatches within the stock');
RESET ROLE;
SELECT pg_temp.guard_assert((SELECT stock=6 FROM public.goodsreceived_trl WHERE id=:'lot_b'::uuid),'the dispatch of 4 leaves 6 in stock');
SELECT id AS dispatch_b1 FROM public.dispatch WHERE disp_no='WGB1' \gset

-- 5. An order's note goes through update_order_metadata, which records order
-- history; only the administrator and the supervisor may call it.
SELECT count(*) AS revisions_before FROM public.order_revisions WHERE order_id=:'cart'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT pg_temp.guard_assert(public.update_order_metadata(:'cart'::uuid,'Collect before noon')->>'success'='true','supervisor sets the order note');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SELECT pg_temp.guard_assert(public.update_order_metadata(:'cart'::uuid,'Collect after noon')->>'success'='true','administrator sets the order note');
SELECT public.update_order_metadata(:'cart'::uuid,'Not saved','urgent') AS bad_priority \gset
SELECT pg_temp.guard_assert(:'bad_priority'::jsonb->>'success'='false','a priority outside low/normal is refused: ' || :'bad_priority');
SELECT pg_temp.guard_assert(public.update_order_metadata(gen_random_uuid(),'No such order')->>'success'='false','an unknown order is reported');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$SELECT public.update_order_metadata('$s$||:'cart'||$s$','Staff note')$s$),'staff cannot set the order note');
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SELECT pg_temp.guard_assert(pg_temp.guard_denied($s$SELECT public.update_order_metadata('$s$||:'cart'||$s$','Customer note')$s$),'the customer cannot set the order note');
RESET ROLE;
SELECT pg_temp.guard_assert((SELECT note='Collect after noon' AND priority IN ('low','normal') FROM public.orders WHERE id=:'cart'::uuid),'the note is the administrator''s; refused calls changed nothing');
SELECT pg_temp.guard_assert((SELECT count(*)=:revisions_before+2 FROM public.order_revisions WHERE order_id=:'cart'::uuid),'each accepted note change wrote one history row');

-- 6. The dependency-checked deletes still work for the supervisor: the invoice
-- first, then a dispatch (stock restored), then a receipt with its lines.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(:'dispatch_a1'::uuid,NULL) AS invoiced_dispatch \gset
SELECT pg_temp.guard_assert(:'invoiced_dispatch'::jsonb->>'success'='false','an invoiced dispatch is not deleted: ' || :'invoiced_dispatch');
SELECT pg_temp.guard_assert(public.delete_invoice(:'invoice_a'::uuid)->>'success'='true','supervisor deletes the invoice');
SELECT public.delete_dispatch_with_order_cleanup(:'dispatch_b1'::uuid,NULL) AS deleted_dispatch \gset
SELECT pg_temp.guard_assert(:'deleted_dispatch'::jsonb->>'success'='true','supervisor deletes the dispatch: ' || :'deleted_dispatch');
SELECT pg_temp.guard_assert((SELECT stock=10 FROM public.goodsreceived_trl WHERE id=:'lot_b'::uuid),'deleting the dispatch restores its 4 bags');
SELECT public.delete_grn_safe(:'grn_b'::uuid) AS deleted_grn \gset
SELECT pg_temp.guard_assert(:'deleted_grn'::jsonb->>'success'='true','supervisor deletes the receipt: ' || :'deleted_grn');
RESET ROLE;
SELECT pg_temp.guard_assert((SELECT count(*)=0 FROM public.invoice WHERE id=:'invoice_a'::uuid)
  AND (SELECT invoiced IS NOT TRUE FROM public.goodsreceived WHERE id=:'grn_a'::uuid),'the invoice is gone and its receipt is uninvoiced');
SELECT pg_temp.guard_assert((SELECT count(*)=1 FROM public.dispatch WHERE id=:'dispatch_a1'::uuid),'the invoiced dispatch was kept');
SELECT pg_temp.guard_assert((SELECT count(*)=0 FROM public.dispatch WHERE id=:'dispatch_b1'::uuid)
  AND (SELECT count(*)=0 FROM public.goodsreceived_trl WHERE id=:'lot_b'::uuid)
  AND (SELECT count(*)=0 FROM public.goodsreceived WHERE id=:'grn_b'::uuid),'the dispatch and the receipt are gone');
ROLLBACK;
\echo 'Direct write refusal for administrator and supervisor, unchanged reads and guarded RPC paths passed.'
