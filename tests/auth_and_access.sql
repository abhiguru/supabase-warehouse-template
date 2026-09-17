\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.assert_true(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAILED: %',label; END IF; END $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
  ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),('demo_auth_enabled','false');
SELECT pg_temp.assert_true(NOT (public.send_otp('0000000001')->>'success')::boolean,'demo auth is disabled by default');
UPDATE warehouse_security.auth_config SET value='true' WHERE key='demo_auth_enabled';
INSERT INTO public.user_profiles(id,auth_user_id,name,display_name,mobile,role,active) VALUES
  ('11111111-0000-4000-8000-000000000001','11111111-0000-4000-8000-000000000011','Test Admin','Test Admin','910000000001','admin',true),
  ('11111111-0000-4000-8000-000000000002','11111111-0000-4000-8000-000000000012','Test Customer','Test Customer','910000000002','customer',true),
  ('11111111-0000-4000-8000-000000000003','11111111-0000-4000-8000-000000000013','Inactive','Inactive','910000000003','customer',false);
INSERT INTO public.customers(id,name) VALUES
  ('22222222-0000-4000-8000-000000000001','Example Customer A'),
  ('22222222-0000-4000-8000-000000000002','Example Customer B');
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active) VALUES
  ('11111111-0000-4000-8000-000000000002','22222222-0000-4000-8000-000000000001',true);

SET LOCAL ROLE anon;
DO $$ DECLARE login jsonb; refreshed jsonb; BEGIN
  PERFORM pg_temp.assert_true((public.send_otp('0000000002')->>'success')::boolean,'anonymous send OTP');
  PERFORM pg_temp.assert_true(NOT (public.verify_otp_or_register('0000000002','654321')->>'success')::boolean,'wrong OTP denied');
  login := public.verify_otp_or_register('0000000002','123456');
  PERFORM pg_temp.assert_true((login->>'success')::boolean,'correct OTP signs in');
  PERFORM pg_temp.assert_true(login#>>'{data,user,role}'='customer','customer role retained');
  PERFORM pg_temp.assert_true(NOT (public.verify_otp_or_register('0000000002','123456')->>'success')::boolean,'OTP replay denied');
  refreshed := public.refresh_jwt_token(login#>>'{data,session,refresh_token}');
  PERFORM pg_temp.assert_true((refreshed->>'success')::boolean,'opaque refresh accepted');
  PERFORM pg_temp.assert_true(refreshed->>'refresh_token'<>login#>>'{data,session,refresh_token}','refresh rotates its own session token');
  PERFORM pg_temp.assert_true(NOT (public.refresh_jwt_token(login#>>'{data,session,refresh_token}')->>'success')::boolean,'old refresh replay denied');
  -- Logout may have captured the old token immediately before refresh won the race.
  PERFORM set_config('test.refresh',login#>>'{data,session,refresh_token}',true);
  PERFORM pg_temp.assert_true(NOT (public.refresh_jwt_token(repeat('0',64))->>'success')::boolean,'forged refresh denied');
  PERFORM public.send_otp('0000000003');
  PERFORM pg_temp.assert_true(NOT (public.verify_otp_or_register('0000000003','123456')->>'success')::boolean,'inactive account denied');
  BEGIN PERFORM * FROM public.customers; RAISE EXCEPTION 'anonymous customer read allowed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM * FROM public.jwt_config; RAISE EXCEPTION 'anonymous secret read allowed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM public.get_users_list(); RAISE EXCEPTION 'anonymous staff RPC allowed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;

DO $$ DECLARE claims jsonb; BEGIN
  SELECT jsonb_build_object('role','authenticated','sub',user_id,'session_id',id) INTO claims
    FROM warehouse_security.refresh_sessions WHERE user_id='11111111-0000-4000-8000-000000000012';
  PERFORM set_config('request.jwt.claims',claims::text,true);
END $$;
SET LOCAL ROLE authenticated;
SELECT public.check_session();
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.customers),'customer sees only assigned customer');
SELECT pg_temp.assert_true((SELECT count(*)=1 FROM public.user_profiles),'customer sees only own active profile');
SELECT pg_temp.assert_true((SELECT count(*)=0 FROM public.customers WHERE id='22222222-0000-4000-8000-000000000002'),'cross-customer direct read denied');
DO $$ DECLARE result jsonb; BEGIN
  BEGIN UPDATE public.user_profiles SET role='admin'; RAISE EXCEPTION 'customer self-promotion allowed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM * FROM warehouse_security.auth_config; RAISE EXCEPTION 'customer signing-secret read allowed'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    result := public.get_customer_stock_summary('22222222-0000-4000-8000-000000000002');
    PERFORM pg_temp.assert_true(result->>'success'='false','cross-customer RPC returns no data');
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    result := public.get_users_list();
    PERFORM pg_temp.assert_true(result->>'success'='false','customer staff RPC denied');
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  PERFORM public.logout_session(current_setting('test.refresh'));
  BEGIN PERFORM public.check_session(); RAISE EXCEPTION 'revoked access session accepted'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  PERFORM pg_temp.assert_true((SELECT count(*)=0 FROM public.customers),'revoked session loses RLS access');
END $$;
RESET ROLE;

-- Number suggestions must tolerate custom IDs and compare numeric suffixes
-- numerically. These explicit rows exist only inside this rolled-back test.
DO $$ DECLARE login jsonb; claims jsonb; BEGIN
  PERFORM public.send_otp('0000000001');
  login := public.verify_otp_or_register('0000000001','123456');
  PERFORM pg_temp.assert_true(login->>'success'='true','number fixture admin login');
  SELECT jsonb_build_object('role','authenticated','sub',user_id,'session_id',id) INTO claims
    FROM warehouse_security.refresh_sessions WHERE user_id='11111111-0000-4000-8000-000000000011';
  PERFORM set_config('request.jwt.claims',claims::text,true);
END $$;
INSERT INTO public.goodsreceived(gr_no,customer_id,created_at) VALUES
  ('AZCUSTOM','22222222-0000-4000-8000-000000000001',now());
SELECT pg_temp.assert_true(public.get_next_grn_number()='A0001','custom-only GRNs keep initial numeric suggestion');
INSERT INTO public.goodsreceived(gr_no,customer_id,created_at) VALUES
  ('A0009','22222222-0000-4000-8000-000000000001',now()-interval '2 days'),
  ('A0010','22222222-0000-4000-8000-000000000001',now()-interval '1 day');
SELECT pg_temp.assert_true(public.get_next_grn_number()='A0011','GRN suggestion ignores newer custom suffix and retains numeric sequence');
-- Each dispatch scenario starts from an empty business table. Savepoints keep
-- the fixtures isolated while the enclosing test transaction still rolls back.
SAVEPOINT dispatch_custom_only;
INSERT INTO public.dispatch(disp_no,customer_id) VALUES
  ('ZCUSTOM','22222222-0000-4000-8000-000000000001');
SELECT pg_temp.assert_true(public.get_next_dispatch_number()='I0001','custom-only dispatch keeps padded initial suggestion');
ROLLBACK TO SAVEPOINT dispatch_custom_only;

SAVEPOINT dispatch_numeric_max;
INSERT INTO public.dispatch(disp_no,customer_id) VALUES
  ('I9','22222222-0000-4000-8000-000000000001'),
  ('I10','22222222-0000-4000-8000-000000000001'),
  ('ZCUSTOM','22222222-0000-4000-8000-000000000001');
SELECT pg_temp.assert_true(public.get_next_dispatch_number()='I0011','dispatch suggestion uses numeric maximum and ignores custom IDs');
SELECT pg_temp.assert_true((SELECT array_agg(disp_no ORDER BY disp_no) FROM public.dispatch)=ARRAY['I10','I9','ZCUSTOM']::varchar[],'dispatch suggestions do not rewrite existing identifiers');
ROLLBACK TO SAVEPOINT dispatch_numeric_max;

SAVEPOINT dispatch_rollover;
INSERT INTO public.dispatch(disp_no,customer_id) VALUES
  ('I9999','22222222-0000-4000-8000-000000000001');
SELECT pg_temp.assert_true(public.get_next_dispatch_number()='I10000','dispatch suggestion rolls over from the four-digit boundary');
ROLLBACK TO SAVEPOINT dispatch_rollover;

SAVEPOINT dispatch_maximum;
INSERT INTO public.dispatch(disp_no,customer_id) VALUES
  ('I9999999','22222222-0000-4000-8000-000000000001');
DO $$
BEGIN
  PERFORM public.get_next_dispatch_number();
  RAISE EXCEPTION 'dispatch number exhaustion did not fail';
EXCEPTION
  WHEN numeric_value_out_of_range THEN
    PERFORM pg_temp.assert_true(SQLERRM='Dispatch number sequence exhausted at I9999999','dispatch exhaustion error is explicit');
END $$;
ROLLBACK TO SAVEPOINT dispatch_maximum;

-- Detailed invoice items must return real joined fields, calculate monetary
-- tax from the stored percentage, and retain per-customer authorization.
DO $$ DECLARE claims jsonb; BEGIN
  SELECT jsonb_build_object('role','authenticated','sub',user_id,'session_id',id) INTO claims
    FROM warehouse_security.refresh_sessions
    WHERE user_id='11111111-0000-4000-8000-000000000011'
    ORDER BY created_at DESC LIMIT 1;
  PERFORM set_config('request.jwt.claims',claims::text,true);
END $$;
SAVEPOINT invoice_items_detail;
INSERT INTO public.items(id,name,packaging) VALUES
  ('33333333-0000-4000-8000-000000000010','Invoice detail item','Bag');
INSERT INTO public.goodsreceived(id,gr_no,date,customer_id,customer_name) VALUES
  ('44444444-0000-4000-8000-000000000010','A-DETAIL',current_date,'22222222-0000-4000-8000-000000000001','Example Customer A'),
  ('44444444-0000-4000-8000-000000000020','B-DETAIL',current_date,'22222222-0000-4000-8000-000000000002','Example Customer B');
INSERT INTO public.goodsreceived_trl(id,gr_id,item_id,item_name,packaging,qty,stock,weight,rack,package_mark) VALUES
  ('55555555-0000-4000-8000-000000000010','44444444-0000-4000-8000-000000000010','33333333-0000-4000-8000-000000000010','Invoice detail item','Bag',100,0,10,'R1','DETAIL');
INSERT INTO public.dispatch(id,disp_no,disp_date,customer_id,customer_name) VALUES
  ('66666666-0000-4000-8000-000000000010','I0001',current_date,'22222222-0000-4000-8000-000000000001','Example Customer A'),
  ('66666666-0000-4000-8000-000000000020','I0002',current_date,'22222222-0000-4000-8000-000000000001','Example Customer A'),
  ('66666666-0000-4000-8000-000000000030','I0003',current_date,'22222222-0000-4000-8000-000000000001','Example Customer A');
INSERT INTO public.dispatch_trl(id,gr_id,gr_trl_id,disp_id,disp_qty) VALUES
  ('77777777-0000-4000-8000-000000000010','44444444-0000-4000-8000-000000000010','55555555-0000-4000-8000-000000000010','66666666-0000-4000-8000-000000000010',20),
  ('77777777-0000-4000-8000-000000000020','44444444-0000-4000-8000-000000000010','55555555-0000-4000-8000-000000000010','66666666-0000-4000-8000-000000000020',10),
  ('77777777-0000-4000-8000-000000000030','44444444-0000-4000-8000-000000000010','55555555-0000-4000-8000-000000000010','66666666-0000-4000-8000-000000000030',70);
INSERT INTO public.invoice(id,inv_fin_year,inv_no,gr_id,gr_no,customer_id,customer_name,inv_date,labour,tax_amount,total) VALUES
  ('88888888-0000-4000-8000-000000000010',2026,1001,'44444444-0000-4000-8000-000000000010','A-DETAIL','22222222-0000-4000-8000-000000000001','Example Customer A',current_date,200,35,735),
  ('88888888-0000-4000-8000-000000000020',2026,1002,'44444444-0000-4000-8000-000000000020','B-DETAIL','22222222-0000-4000-8000-000000000002','Example Customer B',current_date,0,0,0);
INSERT INTO public.invoice_trl(invoice_id,disp_trl_id,duration,no_of_days,charge,labour_rate,tax) VALUES
  ('88888888-0000-4000-8000-000000000010','77777777-0000-4000-8000-000000000010',1,0,5,2,5),
  ('88888888-0000-4000-8000-000000000010','77777777-0000-4000-8000-000000000020',1,0,5,2,5),
  ('88888888-0000-4000-8000-000000000010','77777777-0000-4000-8000-000000000030',1,0,5,2,5);
DO $$ DECLARE result jsonb; BEGIN
  result := public.get_invoice_items_detailed('88888888-0000-4000-8000-000000000010');
  PERFORM pg_temp.assert_true(result->>'success'='true','admin reads detailed invoice items');
  PERFORM pg_temp.assert_true(jsonb_array_length(result#>'{data,items}')=3,'detailed invoice returns three lines');
  PERFORM pg_temp.assert_true((result#>>'{data,summary,total_items}')::int=3,'detailed invoice summary counts lines');
  PERFORM pg_temp.assert_true((result#>>'{data,summary,total_quantity}')::numeric=100,'detailed invoice summary totals quantity');
  PERFORM pg_temp.assert_true((result#>>'{data,summary,total_amount}')::numeric=735,'detailed invoice summary calculates total');
  PERFORM pg_temp.assert_true((SELECT SUM((entry->>'tax_amount')::numeric)=35 FROM jsonb_array_elements(result#>'{data,items}') entry),'detailed invoice calculates monetary tax from percent');
  PERFORM pg_temp.assert_true(result#>>'{data,items,0,item_name}'='Invoice detail item','detailed invoice joins item name');
END $$;
DO $$ DECLARE login jsonb; claims jsonb; BEGIN
  PERFORM public.send_otp('0000000002');
  login := public.verify_otp_or_register('0000000002','123456');
  PERFORM pg_temp.assert_true(login->>'success'='true','customer obtains a fresh session for invoice authorization');
  SELECT jsonb_build_object('role','authenticated','sub',user_id,'session_id',id) INTO claims
    FROM warehouse_security.refresh_sessions
    WHERE user_id='11111111-0000-4000-8000-000000000012'
    ORDER BY created_at DESC LIMIT 1;
  PERFORM set_config('request.jwt.claims',claims::text,true);
END $$;
SET LOCAL ROLE authenticated;
SELECT pg_temp.assert_true(public.get_invoice_items_detailed('88888888-0000-4000-8000-000000000010')->>'success'='true','assigned customer reads own detailed invoice');
DO $$ BEGIN
  BEGIN
    PERFORM public.get_invoice_items_detailed('88888888-0000-4000-8000-000000000020');
    RAISE EXCEPTION 'customer read cross-customer detailed invoice';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
ROLLBACK TO SAVEPOINT invoice_items_detail;

DO $$ BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub','11111111-0000-4000-8000-000000000011')::text,true);
END $$;

SELECT pg_temp.assert_true((SELECT r.rolname='supabase_admin' AND p.prosecdef AND p.provolatile='s'
  AND p.proconfig=ARRAY['search_path=pg_catalog, public, extensions, utils, pg_temp']
  FROM pg_proc p JOIN pg_roles r ON r.oid=p.proowner
  WHERE p.oid='public.get_next_dispatch_number()'::regprocedure),'dispatch generator preserves owner, security, volatility, and search path');
SELECT pg_temp.assert_true(NOT has_function_privilege('anon','public.get_next_dispatch_number()','EXECUTE')
  AND has_function_privilege('authenticated','public.get_next_dispatch_number()','EXECUTE')
  AND has_function_privilege('service_role','public.get_next_dispatch_number()','EXECUTE'),'dispatch generator preserves execution grants');

-- Effective grants include PUBLIC inheritance, not merely explicit role grants.
SELECT pg_temp.assert_true(NOT EXISTS (
  SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND has_function_privilege('anon',p.oid,'EXECUTE')
    AND p.proname NOT IN ('send_otp','verify_otp_or_register','refresh_jwt_token','logout_session','check_session')
),'anonymous function allowlist');
SELECT pg_temp.assert_true(NOT EXISTS (
  SELECT 1 FROM pg_matviews WHERE schemaname='public' AND NOT ispopulated
),'all materialized views are queryable');
ROLLBACK;
SELECT 'auth, refresh, revocation and cross-customer access tests passed' AS result;
