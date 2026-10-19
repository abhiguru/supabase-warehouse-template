-- Migration 99: get_customer_dispatch_items chooses the rows of a page after sorting, with the dispatch
-- line id as the unique tie-breaker. Fictional data; runs only in migrations.sh's disposable,
-- network-disabled database.
--
-- Fixture: two receipts (DIO2 dated before DIO1, 6 lots each; two items, varied quantities) and 8 dispatches of 3 lines each (24
-- lines), created in the date order 5,1,8,3,7,2,6,4 of May 2026 (so the insertion order differs from the
-- date order) and with the dispatch number order different from the date order. Lines of one dispatch
-- share its date, so every date sort has ties.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.di_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'dispatch items order: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.di_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.di_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.di_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888889901','Dispatch Order Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT pg_temp.di_login('9888889901') AS admin_claims \gset

SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.di_assert(public.create_customer('Dispatch Order Customer','9888889902')->>'success'='true','customer');
SELECT pg_temp.di_assert(public.create_item('Dispatch Order Millet','Bag')->>'success'='true','item one');
SELECT pg_temp.di_assert(public.create_item('Dispatch Order Barley','Bag')->>'success'='true','item two');
SELECT id AS customer_id FROM public.customers WHERE name='Dispatch Order Customer' \gset
SELECT id AS item_a FROM public.items WHERE name='Dispatch Order Millet' \gset
SELECT id AS item_b FROM public.items WHERE name='Dispatch Order Barley' \gset
SELECT pg_temp.di_assert(public.save_grn(p_gr_no=>'DIO1',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Dispatch Order Customer',p_pricing_mode=>'MONTHLY',
 p_items=>(SELECT jsonb_agg(jsonb_build_object('item_id',CASE WHEN n % 2 = 0 THEN :'item_a' ELSE :'item_b' END,
   'item_name',CASE WHEN n % 2 = 0 THEN 'Dispatch Order Millet' ELSE 'Dispatch Order Barley' END,
   'packaging','Bag','qty',20 + (n * 7) % 5,'weight',5,'rack','R1','package_mark','L' || n))
   FROM generate_series(1,6) AS n))->>'success'='true','receipt DIO1');
SELECT pg_temp.di_assert(public.save_grn(p_gr_no=>'DIO2',p_date=>'2026-03-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Dispatch Order Customer',p_pricing_mode=>'MONTHLY',
 p_items=>(SELECT jsonb_agg(jsonb_build_object('item_id',CASE WHEN n % 2 = 0 THEN :'item_a' ELSE :'item_b' END,
   'item_name',CASE WHEN n % 2 = 0 THEN 'Dispatch Order Millet' ELSE 'Dispatch Order Barley' END,
   'packaging','Bag','qty',20 + (n * 7) % 5,'weight',5,'rack','R1','package_mark','L' || n))
   FROM generate_series(7,12) AS n))->>'success'='true','receipt DIO2');
RESET ROLE;

-- Dispatch k takes units of the lots k, k+1 and k+2 (cyclic): three distinct lots, 24 lines. The
-- dispatch number runs against the date (day 5 is DIO-D, day 1 is DIO-H ...) and disp_qty varies by line.
SELECT jsonb_build_object('customer_id',:'customer_id','customer_name','Dispatch Order Customer',
 'supervisor_id',:'admin_profile','supervisor_name','Dispatch Order Administrator') AS header \gset
CREATE FUNCTION pg_temp.di_make(header jsonb) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  days integer[] := ARRAY[5,1,8,3,7,2,6,4];
  k integer; lots jsonb; made jsonb;
BEGIN
  FOR k IN 1..8 LOOP
    SELECT jsonb_agg(jsonb_build_object('gr_trl_id', t.id, 'disp_qty', 1 + (k + g.off) % 3) ORDER BY g.off) INTO lots
    FROM generate_series(0,2) AS g(off)
    JOIN public.goodsreceived_trl t ON t.package_mark = 'L' || (((k - 1 + g.off) % 12) + 1)
    JOIN public.goodsreceived gr ON gr.id = t.gr_id AND gr.gr_no IN ('DIO1','DIO2');
    PERFORM set_config('request.jwt.claims', current_setting('di.claims'), true);
    SET LOCAL ROLE authenticated;
    made := public.create_dispatch_with_stock_check(
      header || jsonb_build_object('disp_no', 'DIO-' || chr(64 + 9 - k), 'disp_date', format('2026-05-%s', lpad(days[k]::text, 2, '0'))),
      ARRAY(SELECT jsonb_array_elements(lots)), 0, 'dio-' || k);
    RESET ROLE;
    PERFORM pg_temp.di_assert(made->>'success'='true', 'dispatch ' || k || ': ' || made);
  END LOOP;
END $$;
SELECT set_config('di.claims',:'admin_claims',false);
SELECT pg_temp.di_make(:'header'::jsonb);
SELECT pg_temp.di_assert((SELECT count(*)=24 FROM public.dispatch_trl dt JOIN public.goodsreceived_trl t ON t.id=dt.gr_trl_id
 JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no IN ('DIO1','DIO2')), '24 dispatch lines');
SELECT pg_temp.di_assert((SELECT count(DISTINCT d.disp_date)=8 FROM public.dispatch d WHERE d.disp_no LIKE 'DIO-%'), '8 distinct dates');

-- The expected order of a (sort, direction): a direct query on the tables, sorted by the key and then the
-- line id, as "dispatch id/lot id" pairs.
CREATE FUNCTION pg_temp.di_expected(p_sort text, p_dir text, p_limit integer, p_offset integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  EXECUTE format($q$SELECT string_agg(pair, ',' ORDER BY n) FROM (
      SELECT d.id || '/' || grt.id AS pair, row_number() OVER (ORDER BY %s %s, dt.id) AS n
      FROM public.dispatch_trl dt JOIN public.dispatch d ON d.id = dt.disp_id
      JOIN public.goodsreceived_trl grt ON grt.id = dt.gr_trl_id JOIN public.goodsreceived gr ON gr.id = grt.gr_id
      WHERE gr.customer_id = %L) s WHERE n > %s AND n <= %s$q$,
    CASE p_sort WHEN 'grn_gr_no' THEN 'gr.gr_no' WHEN 'grn_date' THEN 'gr.date' WHEN 'item_name' THEN 'grt.item_name'
      WHEN 'disp_no' THEN 'd.disp_no' WHEN 'disp_date' THEN 'd.disp_date' WHEN 'qty' THEN 'grt.qty'
      WHEN 'disp_qty' THEN 'dt.disp_qty' END,
    p_dir, current_setting('di.customer'), p_offset, p_offset + p_limit) INTO r;
  RETURN COALESCE(r, '');
END $$;
-- What the function returns for it, in the same form (run as the administrator).
CREATE FUNCTION pg_temp.di_actual(p_sort text, p_dir text, p_limit integer, p_offset integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE res jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', current_setting('di.claims'), true);
  SET LOCAL ROLE authenticated;
  res := public.get_customer_dispatch_items(current_setting('di.customer')::uuid, NULL, NULL, '{}'::jsonb, p_sort, p_dir, p_limit, p_offset);
  RESET ROLE;
  PERFORM pg_temp.di_assert(res->>'success'='true', 'call succeeded: ' || res::text);
  RETURN COALESCE((SELECT string_agg(i->>'dispatch_id' || '/' || (i->>'grn_item_id'), ',' ORDER BY n)
                   FROM jsonb_array_elements(res#>'{data,items}') WITH ORDINALITY AS e(i, n)), '');
END $$;
SELECT set_config('di.customer',:'customer_id',false);

-- 1. Every sort key, both directions: the first page of 10 is exactly the first 10 of the sorted whole.
DO $$
DECLARE s text; d text;
BEGIN
  FOREACH s IN ARRAY ARRAY['grn_gr_no','grn_date','item_name','disp_no','disp_date','qty','disp_qty'] LOOP
    FOREACH d IN ARRAY ARRAY['asc','desc'] LOOP
      PERFORM pg_temp.di_assert(pg_temp.di_actual(s, d, 10, 0) = pg_temp.di_expected(s, d, 10, 0),
        'first page of 10, sort ' || s || ' ' || d);
      PERFORM pg_temp.di_assert(pg_temp.di_actual(s, d, 10, 10) = pg_temp.di_expected(s, d, 10, 10),
        'second page of 10, sort ' || s || ' ' || d);
      PERFORM pg_temp.di_assert(pg_temp.di_actual(s, d, 10, 0) = pg_temp.di_actual(s, d, 10, 0),
        'the same call returns the same page, sort ' || s || ' ' || d);
    END LOOP;
  END LOOP;
END $$;

-- 2. The newest lines: sort disp_date desc, limit 10, are the 10 newest lines (days 8, 7 and 6 whole, then
-- one line of day 5); asc gives days 1, 2 and 3 whole, then one line of day 4.
CREATE FUNCTION pg_temp.di_days(pairs text) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(to_char(d.disp_date AT TIME ZONE 'UTC', 'DD'), ',' ORDER BY p.n)
  FROM unnest(string_to_array(pairs, ',')) WITH ORDINALITY AS p(pair, n)
  JOIN public.dispatch d ON d.id = split_part(p.pair, '/', 1)::uuid $$;
SELECT pg_temp.di_assert(pg_temp.di_days(pg_temp.di_actual('disp_date','desc',10,0)) = '08,08,08,07,07,07,06,06,06,05',
  'newest 10 lines: ' || pg_temp.di_days(pg_temp.di_actual('disp_date','desc',10,0)));
SELECT pg_temp.di_assert(pg_temp.di_days(pg_temp.di_actual('disp_date','asc',10,0)) = '01,01,01,02,02,02,03,03,03,04',
  'oldest 10 lines: ' || pg_temp.di_days(pg_temp.di_actual('disp_date','asc',10,0)));

-- 3. Walking all pages (page sizes 5 and 7) returns every line exactly once, in the global order.
DO $$
DECLARE s text; d text; size integer; off integer; walked text; page text;
BEGIN
  FOREACH s IN ARRAY ARRAY['grn_gr_no','grn_date','item_name','disp_no','disp_date','qty','disp_qty'] LOOP
    FOREACH d IN ARRAY ARRAY['asc','desc'] LOOP
      FOREACH size IN ARRAY ARRAY[5,7] LOOP
        walked := '';
        FOR off IN SELECT generate_series(0, 23, size) LOOP
          page := pg_temp.di_actual(s, d, size, off);
          walked := walked || CASE WHEN walked = '' THEN '' ELSE ',' END || page;
        END LOOP;
        PERFORM pg_temp.di_assert(walked = pg_temp.di_expected(s, d, 24, 0),
          'pages of ' || size || ' follow the global order, sort ' || s || ' ' || d);
        PERFORM pg_temp.di_assert((SELECT count(DISTINCT x) = 24 AND count(*) = 24 FROM unnest(string_to_array(walked, ',')) x),
          '24 distinct lines once each, sort ' || s || ' ' || d);
      END LOOP;
    END LOOP;
  END LOOP;
END $$;

-- 4. An unknown sort key still pages without repeats or gaps (line id order).
DO $$
DECLARE walked text := ''; off integer;
BEGIN
  FOR off IN SELECT generate_series(0, 23, 5) LOOP
    walked := walked || CASE WHEN walked = '' THEN '' ELSE ',' END || pg_temp.di_actual('no_such_key', 'asc', 5, off);
  END LOOP;
  PERFORM pg_temp.di_assert((SELECT count(DISTINCT x) = 24 AND count(*) = 24 FROM unnest(string_to_array(walked, ',')) x),
    'an unknown sort key pages every line once');
END $$;
ROLLBACK;
