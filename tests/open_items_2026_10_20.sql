-- Open items 2026-10-20: (1) the GRN picker pages after it sorts, (2) a deleted invoice is not found,
-- (3) lists have a total order and the lines of invoices and dispatches come back in the order they were saved,
-- (4) the dead functions and the dead view are gone. Fictional data; runs only in migrations.sh's disposable,
-- network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.oi_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'open items 2026-10-20: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.oi_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.oi_assert(l#>>'{data,action}'='login','login for '||phone);
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
SELECT warehouse_security.bootstrap_first_admin('9888889801','Open Items Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT pg_temp.oi_login('9888889801') AS admin_claims \gset
SELECT set_config('oi.claims',:'admin_claims',false);

-- The administrator's session: every call below runs as it.
CREATE FUNCTION pg_temp.oi_as_admin() RETURNS void LANGUAGE plpgsql AS $$
BEGIN PERFORM set_config('request.jwt.claims', current_setting('oi.claims'), true); SET LOCAL ROLE authenticated; END $$;

--------------------------------------------------------------------------------------------------
-- 1. get_customer_grns_with_stock_dispatch_sorted: sort first, then page.
-- 25 receipts GP01..GP25 (receipt date = day k of July 2026, one lot of 10 bags each). GP01..GP22 are dispatched once,
-- on day 1 + (k * 7) % 22 of August (a permutation of 1..22, unlike the receipt order); GP23..GP25 never are.
-- The 20 most recently dispatched are therefore the dispatches of days 22 down to 3; the two oldest dispatches (days 1
-- and 2) and the three never-dispatched receipts fall on the second page.
--------------------------------------------------------------------------------------------------
SELECT pg_temp.oi_as_admin();
SELECT pg_temp.oi_assert(public.create_customer('Open Items Picker Customer','9888889802')->>'success'='true','picker customer');
SELECT pg_temp.oi_assert(public.create_item('Open Items Picker Item','Bag')->>'success'='true','picker item');
RESET ROLE;
SELECT id AS picker_customer FROM public.customers WHERE name='Open Items Picker Customer' \gset
SELECT id AS picker_item FROM public.items WHERE name='Open Items Picker Item' \gset
CREATE FUNCTION pg_temp.oi_make_picker() RETURNS void LANGUAGE plpgsql AS $$
DECLARE k integer; lot uuid; made jsonb;
BEGIN
  FOR k IN 1..25 LOOP
    PERFORM pg_temp.oi_as_admin();
    made := public.save_grn(p_gr_no=>'GP'||lpad(k::text,2,'0'), p_date=>format('2026-07-%s T06:00:00Z', lpad(k::text,2,'0'))::timestamptz,
      p_customer_id=>current_setting('oi.picker_customer')::uuid, p_customer_name=>'Open Items Picker Customer', p_pricing_mode=>'MONTHLY',
      p_items=>jsonb_build_array(jsonb_build_object('item_id',current_setting('oi.picker_item'),'item_name','Open Items Picker Item',
        'packaging','Bag','qty',10,'weight',5,'rack','R1','package_mark','P'||k)));
    PERFORM pg_temp.oi_assert(made->>'success'='true','picker receipt '||k||': '||made);
    IF k <= 22 THEN
      SELECT t.id INTO lot FROM public.goodsreceived_trl t WHERE t.package_mark='P'||k;
      made := public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','GPD'||lpad(k::text,2,'0'),
        'disp_date', format('2026-08-%s', lpad((1 + (k * 7) % 22)::text,2,'0')),
        'customer_id',current_setting('oi.picker_customer'),'customer_name','Open Items Picker Customer',
        'supervisor_id',current_setting('oi.admin_profile'),'supervisor_name','Open Items Administrator'),
        ARRAY[jsonb_build_object('gr_trl_id',lot,'disp_qty',1)], 0, 'oi-picker-d'||k);
      PERFORM pg_temp.oi_assert(made->>'success'='true','picker dispatch '||k||': '||made);
    END IF;
    RESET ROLE;
  END LOOP;
END $$;
SELECT set_config('oi.picker_customer',:'picker_customer',false), set_config('oi.picker_item',:'picker_item',false),
       set_config('oi.admin_profile',:'admin_profile',false);
SELECT pg_temp.oi_make_picker();
-- What the picker must return: the plain query on the tables, in the stated order, as a list of receipt numbers.
CREATE FUNCTION pg_temp.oi_picker_expected(p_limit integer, p_offset integer) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(gr_no, ',' ORDER BY n), '') FROM (
    SELECT gs.gr_no, row_number() OVER (ORDER BY (SELECT max(d.disp_date) FROM public.dispatch_trl dt
        JOIN public.dispatch d ON d.id = dt.disp_id AND d.deleted_at IS NULL WHERE dt.gr_id = gs.id) DESC NULLS LAST, gs.date DESC, gs.gr_no, gs.id) AS n
    FROM public.goodsreceived gs WHERE gs.customer_id = current_setting('oi.picker_customer')::uuid) s
  WHERE n > p_offset AND n <= p_offset + p_limit $$;
CREATE FUNCTION pg_temp.oi_picker_actual(p_limit integer, p_offset integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE res jsonb;
BEGIN
  PERFORM pg_temp.oi_as_admin();
  res := public.get_customer_grns_with_stock_dispatch_sorted(current_setting('oi.picker_customer')::uuid, p_limit, p_offset);
  RESET ROLE;
  PERFORM pg_temp.oi_assert(res->>'success'='true','picker call: '||res::text);
  RETURN COALESCE((SELECT string_agg(e->>'gr_no', ',' ORDER BY n) FROM jsonb_array_elements(res->'data') WITH ORDINALITY AS t(e,n)), '');
END $$;
-- Day 22 is k with (k*7)%22 = 21, which is k = 3: so GP03 is first. The first page ends with the dispatch of day 3.
SELECT pg_temp.oi_assert(pg_temp.oi_picker_actual(20,0) = pg_temp.oi_picker_expected(20,0) AND split_part(pg_temp.oi_picker_actual(20,0),',',1) = 'GP03',
  'first page: the 20 most recently dispatched, newest first: ' || pg_temp.oi_picker_actual(20,0));
SELECT pg_temp.oi_assert(pg_temp.oi_picker_actual(20,0) !~ 'GP2[345]', 'no never-dispatched receipt on the first page');
-- The second page: the two oldest dispatches (day 2, day 1), then the never-dispatched by receipt date, newest first.
SELECT pg_temp.oi_assert(pg_temp.oi_picker_actual(20,20) = pg_temp.oi_picker_expected(20,20) AND pg_temp.oi_picker_actual(20,20) ~ ',GP25,GP24,GP23$',
  'second page: the oldest dispatches, then GP25, GP24, GP23: ' || pg_temp.oi_picker_actual(20,20));
SELECT pg_temp.oi_assert(pg_temp.oi_picker_actual(7,0) || ',' || pg_temp.oi_picker_actual(7,7) || ',' || pg_temp.oi_picker_actual(7,14) || ',' || pg_temp.oi_picker_actual(7,21)
  = pg_temp.oi_picker_expected(25,0), 'pages of 7 walk the whole order once');
-- The answer's shape is unchanged.
SELECT pg_temp.oi_as_admin();
SELECT public.get_customer_grns_with_stock_dispatch_sorted(:'picker_customer'::uuid, 1, 0) AS picker_one \gset
RESET ROLE;
SELECT pg_temp.oi_assert((SELECT array_agg(k ORDER BY k COLLATE "C") = ARRAY['customer_name','gr_no','grn_date','grn_id','item_count','last_dispatch_date','total_stock']
    FROM jsonb_object_keys((:'picker_one'::jsonb)#>'{data,0}') k)
  AND jsonb_typeof((:'picker_one'::jsonb)#>'{data,0,last_dispatch_date}') = 'string', 'picker row keys unchanged: ' || :'picker_one');

--------------------------------------------------------------------------------------------------
-- 3. The lines of a dispatch and of an invoice come back in the order they were saved.
-- Receipt LO1 holds 4 lots (L1..L4). A dispatch takes them in the order L3, L1, L4, L2 (not their lot order, not their id order).
-- Nested loops and merge joins are switched off for this section (until the end of it): the inserts join the given lines to
-- the dispatch tables by a hash join, which does not keep the order of its input. Without the ORDER BY in the functions the
-- checks below fail on the baseline.
--------------------------------------------------------------------------------------------------
SET LOCAL enable_nestloop = off;
SET LOCAL enable_mergejoin = off;
SELECT pg_temp.oi_as_admin();
SELECT pg_temp.oi_assert(public.create_customer('Open Items Lines Customer','9888889803')->>'success'='true','lines customer');
RESET ROLE;
SELECT id AS lines_customer FROM public.customers WHERE name='Open Items Lines Customer' \gset
SELECT pg_temp.oi_as_admin();
SELECT pg_temp.oi_assert(public.save_grn(p_gr_no=>'LO1',p_date=>'2026-06-01T06:00:00Z',p_customer_id=>:'lines_customer'::uuid,
 p_customer_name=>'Open Items Lines Customer',p_pricing_mode=>'MONTHLY',
 p_items=>(SELECT jsonb_agg(jsonb_build_object('item_id',:'picker_item','item_name','Open Items Picker Item',
   'packaging','Bag','qty',10,'weight',5,'rack','R1','package_mark','L'||n) ORDER BY n) FROM generate_series(1,4) n))->>'success'='true','receipt LO1');
RESET ROLE;
SELECT id AS lo1 FROM public.goodsreceived WHERE gr_no='LO1' \gset
SELECT t.id AS l1 FROM public.goodsreceived_trl t WHERE t.gr_id=:'lo1'::uuid AND t.package_mark='L1' \gset
SELECT t.id AS l2 FROM public.goodsreceived_trl t WHERE t.gr_id=:'lo1'::uuid AND t.package_mark='L2' \gset
SELECT t.id AS l3 FROM public.goodsreceived_trl t WHERE t.gr_id=:'lo1'::uuid AND t.package_mark='L3' \gset
SELECT t.id AS l4 FROM public.goodsreceived_trl t WHERE t.gr_id=:'lo1'::uuid AND t.package_mark='L4' \gset
SELECT pg_temp.oi_as_admin();
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','LOD1','disp_date','2026-06-10',
  'customer_id',:'lines_customer','customer_name','Open Items Lines Customer','supervisor_id',:'admin_profile','supervisor_name','Open Items Administrator'),
  ARRAY[jsonb_build_object('gr_trl_id',:'l3','disp_qty',1), jsonb_build_object('gr_trl_id',:'l1','disp_qty',2),
        jsonb_build_object('gr_trl_id',:'l4','disp_qty',3), jsonb_build_object('gr_trl_id',:'l2','disp_qty',4)], 0, 'oi-lines-d1') AS made_dispatch \gset
RESET ROLE;
SELECT pg_temp.oi_assert((:'made_dispatch'::jsonb)->>'success'='true','dispatch LOD1: '||:'made_dispatch');
SELECT id AS lod1 FROM public.dispatch WHERE disp_no='LOD1' \gset
-- The lot of each line, in the order the lines were saved (the timestamp inside the line id), against the order given.
SELECT pg_temp.oi_assert((SELECT string_agg(t.package_mark, ',' ORDER BY uuid_extract_timestamp(dt.id), dt.id)
    FROM public.dispatch_trl dt JOIN public.goodsreceived_trl t ON t.id=dt.gr_trl_id WHERE dt.disp_id=:'lod1'::uuid) = 'L3,L1,L4,L2',
  'dispatch lines are stored in the order given');
CREATE FUNCTION pg_temp.oi_dispatch_lots(p_dispatch uuid) RETURNS text LANGUAGE plpgsql AS $$
DECLARE res jsonb;
BEGIN
  PERFORM pg_temp.oi_as_admin();
  res := public.get_dispatch_details(p_dispatch);
  RESET ROLE;
  PERFORM pg_temp.oi_assert(res->>'success'='true','get_dispatch_details: '||left(res::text,300));
  RETURN (SELECT string_agg(i#>>'{grn_item_details,package_mark}', ',' ORDER BY n) FROM jsonb_array_elements(res#>'{data,dispatch,items}') WITH ORDINALITY AS t(i,n));
END $$;
SELECT pg_temp.oi_assert(pg_temp.oi_dispatch_lots(:'lod1'::uuid) = 'L3,L1,L4,L2', 'get_dispatch_details: lines in the order given: ' || pg_temp.oi_dispatch_lots(:'lod1'::uuid));
-- A dispatch edit that adds two lots in one statement keeps the existing lines and appends them in the order given.
SELECT pg_temp.oi_as_admin();
SELECT pg_temp.oi_assert(public.save_grn(p_gr_no=>'LO2',p_date=>'2026-06-02T06:00:00Z',p_customer_id=>:'lines_customer'::uuid,
 p_customer_name=>'Open Items Lines Customer',p_pricing_mode=>'MONTHLY',
 p_items=>(SELECT jsonb_agg(jsonb_build_object('item_id',:'picker_item','item_name','Open Items Picker Item',
   'packaging','Bag','qty',10,'weight',5,'rack','R1','package_mark','M'||n) ORDER BY n) FROM generate_series(1,2) n))->>'success'='true','receipt LO2');
RESET ROLE;
SELECT t.id AS m1 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='LO2' AND t.package_mark='M1' \gset
SELECT t.id AS m2 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='LO2' AND t.package_mark='M2' \gset
SELECT pg_temp.oi_as_admin();
SELECT public.update_dispatch_smart(:'lod1'::uuid, jsonb_build_object('disp_no','LOD1','disp_date','2026-06-10',
  'customer_id',:'lines_customer','customer_name','Open Items Lines Customer','supervisor_id',:'admin_profile','supervisor_name','Open Items Administrator'),
  ARRAY[jsonb_build_object('gr_trl_id',:'l3','disp_qty',1), jsonb_build_object('gr_trl_id',:'l1','disp_qty',2),
        jsonb_build_object('gr_trl_id',:'l4','disp_qty',3), jsonb_build_object('gr_trl_id',:'l2','disp_qty',4),
        jsonb_build_object('gr_trl_id',:'m2','disp_qty',1), jsonb_build_object('gr_trl_id',:'m1','disp_qty',1)]) AS edited \gset
RESET ROLE;
SELECT pg_temp.oi_assert((:'edited'::jsonb)->>'success'='true','dispatch edit: '||:'edited');
SELECT pg_temp.oi_assert(pg_temp.oi_dispatch_lots(:'lod1'::uuid) = 'L3,L1,L4,L2,M2,M1', 'after the edit: old lines, then M2, M1 as given: ' || pg_temp.oi_dispatch_lots(:'lod1'::uuid));

-- An invoice for the six lines, listed in the order L2, M1, L3, M2, L1, L4 (given, not saved, order).
CREATE FUNCTION pg_temp.oi_line_of(p_mark text) RETURNS uuid LANGUAGE sql AS $$
  SELECT dt.id FROM public.dispatch_trl dt JOIN public.goodsreceived_trl t ON t.id=dt.gr_trl_id WHERE dt.disp_id=current_setting('oi.lod1')::uuid AND t.package_mark=p_mark $$;
SELECT set_config('oi.lod1',:'lod1',false);
CREATE FUNCTION pg_temp.oi_items(VARIADIC marks text[]) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(jsonb_build_object('disp_trl_id', pg_temp.oi_line_of(m), 'charge', 10, 'tax', 0, 'labour_rate', 1) ORDER BY n) FROM unnest(marks) WITH ORDINALITY AS t(m,n) $$;
CREATE FUNCTION pg_temp.oi_invoice_lots(p_invoice uuid) RETURNS text LANGUAGE plpgsql AS $$
DECLARE res jsonb;
BEGIN
  PERFORM pg_temp.oi_as_admin();
  res := public.get_invoice_data(p_invoice);
  RESET ROLE;
  PERFORM pg_temp.oi_assert(res->>'success'='true','get_invoice_data: '||left(res::text,300));
  RETURN (SELECT string_agg(t.package_mark, ',' ORDER BY n)
          FROM jsonb_array_elements(res#>'{data,items}') WITH ORDINALITY AS e(i,n)
          JOIN public.dispatch_trl dt ON dt.id=(e.i->>'disp_trl_id')::uuid JOIN public.goodsreceived_trl t ON t.id=dt.gr_trl_id);
END $$;
-- This one call joins by a merge join instead (on the baseline a hash join happens to keep the input order here, a merge join
-- hands the lines back in dispatch line id order): either way the saved order has to be the given order.
SET LOCAL enable_hashjoin = off;
SET LOCAL enable_mergejoin = on;
SELECT pg_temp.oi_as_admin();
SELECT public.save_invoice(jsonb_build_object('inv_no', 9801, 'inv_fin_year', 2026, 'gr_id', :'lo1', 'gr_no', 'LO1',
  'customer_id', :'lines_customer', 'customer_name', 'Open Items Lines Customer', 'inv_date', '2026-06-20T06:00:00Z',
  'discount', 0, 'duration_mode', 'legacy',
  'items', jsonb_build_array(
    jsonb_build_object('disp_trl_id', pg_temp.oi_line_of('L2'), 'charge', 10, 'tax', 0, 'labour_rate', 1),
    jsonb_build_object('disp_trl_id', pg_temp.oi_line_of('L3'), 'charge', 10, 'tax', 0, 'labour_rate', 1),
    jsonb_build_object('disp_trl_id', pg_temp.oi_line_of('L1'), 'charge', 10, 'tax', 0, 'labour_rate', 1),
    jsonb_build_object('disp_trl_id', pg_temp.oi_line_of('L4'), 'charge', 10, 'tax', 0, 'labour_rate', 1)))) AS saved_invoice \gset
RESET ROLE;
SET LOCAL enable_hashjoin = on;
SET LOCAL enable_mergejoin = off;
SELECT pg_temp.oi_assert((:'saved_invoice'::jsonb)->>'success'='true','save_invoice: '||:'saved_invoice');
SELECT id AS inv1 FROM public.invoice WHERE inv_no=9801 AND inv_fin_year=2026 \gset
SELECT pg_temp.oi_assert(pg_temp.oi_invoice_lots(:'inv1'::uuid) = 'L2,L3,L1,L4', 'save_invoice: lines in the order given: ' || pg_temp.oi_invoice_lots(:'inv1'::uuid));
-- update_invoice with a different order (the lines are deleted and inserted again).
SELECT pg_temp.oi_as_admin();
SELECT public.update_invoice(:'inv1'::uuid, jsonb_build_object('inv_no', 9801, 'inv_fin_year', 2026, 'gr_id', :'lo1', 'gr_no', 'LO1',
  'customer_id', :'lines_customer', 'customer_name', 'Open Items Lines Customer', 'inv_date', '2026-06-20T06:00:00Z',
  'discount', 0, 'duration_mode', 'legacy'),
  ARRAY(SELECT jsonb_array_elements(pg_temp.oi_items('L4','L1','L3','L2')))) AS updated_invoice \gset
RESET ROLE;
SELECT pg_temp.oi_assert((:'updated_invoice'::jsonb)->>'success'='true','update_invoice: '||:'updated_invoice');
SELECT pg_temp.oi_assert(pg_temp.oi_invoice_lots(:'inv1'::uuid) = 'L4,L1,L3,L2', 'update_invoice: lines in the order given: ' || pg_temp.oi_invoice_lots(:'inv1'::uuid));
-- save_invoice with an invoice id (save_invoice_internal), on a new invoice of the second receipt.
SELECT pg_temp.oi_as_admin();
SELECT public.save_invoice(NULL::uuid, jsonb_build_object('inv_no', 9802, 'inv_fin_year', 2026, 'gr_id', (SELECT id FROM public.goodsreceived WHERE gr_no='LO2'), 'gr_no', 'LO2',
  'customer_id', :'lines_customer', 'customer_name', 'Open Items Lines Customer', 'inv_date', '2026-06-20T06:00:00Z',
  'discount', 0, 'labour', 0, 'tax_amount', 0, 'total', 0, 'duration_mode', 'legacy'),
  ARRAY(SELECT i || jsonb_build_object('grn_item_id', (SELECT gr_trl_id FROM public.dispatch_trl WHERE id = (i->>'disp_trl_id')::uuid), 'duration', 1)
        FROM jsonb_array_elements(pg_temp.oi_items('M2','M1')) WITH ORDINALITY AS t(i,n) ORDER BY n)) AS saved_internal \gset
RESET ROLE;
SELECT pg_temp.oi_assert((:'saved_internal'::jsonb)->>'success'='true','save_invoice with an id: '||:'saved_internal');
SELECT id AS inv2 FROM public.invoice WHERE inv_no=9802 AND inv_fin_year=2026 \gset
SELECT pg_temp.oi_assert(pg_temp.oi_invoice_lots(:'inv2'::uuid) = 'M2,M1', 'save_invoice (with an id): lines in the order given: ' || pg_temp.oi_invoice_lots(:'inv2'::uuid));
-- The print answer lists the same lines in the same order.
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SET LOCAL ROLE service_role;
SELECT public.get_invoice_range_for_print('9801', '9802', 2026) AS printed \gset
RESET ROLE;
SELECT pg_temp.oi_assert((SELECT string_agg(l->>'grn_items_package_mark', ',' ORDER BY n)
    FROM jsonb_array_elements((:'printed'::jsonb)->'data') AS x, jsonb_array_elements(x->'trl') WITH ORDINALITY AS t(l,n)
    WHERE (x->>'inv_no')::integer = 9801) = 'L4,L1,L3,L2', 'the print answer keeps the line order: ' || left(:'printed', 300));

-- Ids across a time_low wrap. A version-1 id starts with the low 32 bits of its timestamp, so two lines saved a few minutes
-- apart can have the newer id sort BEFORE the older one when ids are compared as plain uuids. Receipt LO3 holds W1 and W2;
-- a dispatch and an invoice take W1 then W2, and the line ids are then set by hand: W1 (older) fffffff0-1234-..., W2 (newer)
-- 00000010-1235-.... Plain id order puts W2 first; timestamp order puts W1 first, which is the saved order.
SELECT pg_temp.oi_as_admin();
SELECT pg_temp.oi_assert(public.save_grn(p_gr_no=>'LO3',p_date=>'2026-06-03T06:00:00Z',p_customer_id=>:'lines_customer'::uuid,
 p_customer_name=>'Open Items Lines Customer',p_pricing_mode=>'MONTHLY',
 p_items=>(SELECT jsonb_agg(jsonb_build_object('item_id',:'picker_item','item_name','Open Items Picker Item',
   'packaging','Bag','qty',10,'weight',5,'rack','R1','package_mark','W'||n) ORDER BY n) FROM generate_series(1,2) n))->>'success'='true','receipt LO3');
RESET ROLE;
SELECT id AS lo3 FROM public.goodsreceived WHERE gr_no='LO3' \gset
SELECT t.id AS w1 FROM public.goodsreceived_trl t WHERE t.gr_id=:'lo3'::uuid AND t.package_mark='W1' \gset
SELECT t.id AS w2 FROM public.goodsreceived_trl t WHERE t.gr_id=:'lo3'::uuid AND t.package_mark='W2' \gset
SELECT pg_temp.oi_as_admin();
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','LOD3','disp_date','2026-06-11',
  'customer_id',:'lines_customer','customer_name','Open Items Lines Customer','supervisor_id',:'admin_profile','supervisor_name','Open Items Administrator'),
  ARRAY[jsonb_build_object('gr_trl_id',:'w1','disp_qty',1), jsonb_build_object('gr_trl_id',:'w2','disp_qty',1)], 0, 'oi-lines-d3') AS made_wrap \gset
RESET ROLE;
SELECT pg_temp.oi_assert((:'made_wrap'::jsonb)->>'success'='true','dispatch LOD3: '||:'made_wrap');
SELECT id AS lod3 FROM public.dispatch WHERE disp_no='LOD3' \gset
UPDATE public.dispatch_trl SET id = 'fffffff0-1234-11f1-8000-000000000001' WHERE disp_id=:'lod3'::uuid AND gr_trl_id=:'w1'::uuid;
UPDATE public.dispatch_trl SET id = '00000010-1235-11f1-8000-000000000002' WHERE disp_id=:'lod3'::uuid AND gr_trl_id=:'w2'::uuid;
SELECT pg_temp.oi_assert((SELECT string_agg(t.package_mark, ',' ORDER BY dt.id) FROM public.dispatch_trl dt JOIN public.goodsreceived_trl t ON t.id=dt.gr_trl_id
    WHERE dt.disp_id=:'lod3'::uuid) = 'W2,W1'
  AND (SELECT string_agg(t.package_mark, ',' ORDER BY uuid_extract_timestamp(dt.id), dt.id) FROM public.dispatch_trl dt JOIN public.goodsreceived_trl t ON t.id=dt.gr_trl_id
    WHERE dt.disp_id=:'lod3'::uuid) = 'W1,W2', 'wrapped dispatch ids: plain id order is W2,W1, timestamp order is W1,W2');
SELECT pg_temp.oi_assert(pg_temp.oi_dispatch_lots(:'lod3'::uuid) = 'W1,W2', 'get_dispatch_details: older line first across a time_low wrap: ' || pg_temp.oi_dispatch_lots(:'lod3'::uuid));
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SET LOCAL ROLE service_role;
SELECT public.get_dispatch_range_for_print('LOD3', 'LOD3') AS printed_dispatch \gset
RESET ROLE;
SELECT pg_temp.oi_assert((SELECT string_agg(i->>'grn_items_package_mark', ',' ORDER BY n)
    FROM jsonb_array_elements((:'printed_dispatch'::jsonb)->'data') AS x, jsonb_array_elements(x->'items') WITH ORDINALITY AS t(i,n)
    WHERE x->>'disp_no' = 'LOD3') = 'W1,W2', 'the dispatch print keeps the older line first across a wrap: ' || left(:'printed_dispatch', 300));
-- The invoice: its lines are saved W1 then W2, then given the same wrapped ids.
SELECT pg_temp.oi_as_admin();
SELECT public.save_invoice(jsonb_build_object('inv_no', 9803, 'inv_fin_year', 2026, 'gr_id', :'lo3', 'gr_no', 'LO3',
  'customer_id', :'lines_customer', 'customer_name', 'Open Items Lines Customer', 'inv_date', '2026-06-21T06:00:00Z',
  'discount', 0, 'duration_mode', 'legacy',
  'items', jsonb_build_array(
    jsonb_build_object('disp_trl_id', (SELECT id FROM public.dispatch_trl WHERE disp_id=:'lod3'::uuid AND gr_trl_id=:'w1'::uuid), 'charge', 10, 'tax', 0, 'labour_rate', 1),
    jsonb_build_object('disp_trl_id', (SELECT id FROM public.dispatch_trl WHERE disp_id=:'lod3'::uuid AND gr_trl_id=:'w2'::uuid), 'charge', 10, 'tax', 0, 'labour_rate', 1)))) AS saved_wrap \gset
RESET ROLE;
SELECT pg_temp.oi_assert((:'saved_wrap'::jsonb)->>'success'='true','save_invoice 9803: '||:'saved_wrap');
SELECT id AS inv3 FROM public.invoice WHERE inv_no=9803 AND inv_fin_year=2026 \gset
UPDATE public.invoice_trl SET id = 'fffffff0-1234-11f1-8000-000000000001' WHERE invoice_id=:'inv3'::uuid AND disp_trl_id=(SELECT id FROM public.dispatch_trl WHERE disp_id=:'lod3'::uuid AND gr_trl_id=:'w1'::uuid);
UPDATE public.invoice_trl SET id = '00000010-1235-11f1-8000-000000000002' WHERE invoice_id=:'inv3'::uuid AND disp_trl_id=(SELECT id FROM public.dispatch_trl WHERE disp_id=:'lod3'::uuid AND gr_trl_id=:'w2'::uuid);
SELECT pg_temp.oi_assert((SELECT string_agg(t.package_mark, ',' ORDER BY it.id) FROM public.invoice_trl it JOIN public.dispatch_trl dt ON dt.id=it.disp_trl_id
    JOIN public.goodsreceived_trl t ON t.id=dt.gr_trl_id WHERE it.invoice_id=:'inv3'::uuid) = 'W2,W1', 'wrapped invoice ids: plain id order is W2,W1');
SELECT pg_temp.oi_assert(pg_temp.oi_invoice_lots(:'inv3'::uuid) = 'W1,W2', 'get_invoice_data: older line first across a time_low wrap: ' || pg_temp.oi_invoice_lots(:'inv3'::uuid));
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SET LOCAL ROLE service_role;
SELECT public.get_invoice_range_for_print('9803', '9803', 2026) AS printed_wrap_inv \gset
RESET ROLE;
SELECT pg_temp.oi_assert((SELECT string_agg(l->>'grn_items_package_mark', ',' ORDER BY n)
    FROM jsonb_array_elements((:'printed_wrap_inv'::jsonb)->'data') AS x, jsonb_array_elements(x->'trl') WITH ORDINALITY AS t(l,n)
    WHERE (x->>'inv_no')::integer = 9803) = 'W1,W2', 'the invoice print keeps the older line first across a wrap: ' || left(:'printed_wrap_inv', 300));
RESET enable_nestloop;
RESET enable_mergejoin;
RESET enable_hashjoin;

--------------------------------------------------------------------------------------------------
-- 2. A deleted invoice is not found.
--------------------------------------------------------------------------------------------------
CREATE FUNCTION pg_temp.oi_detail(p_invoice uuid) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE a jsonb; b jsonb;
BEGIN
  PERFORM pg_temp.oi_as_admin();
  a := public.get_invoice_data(p_invoice); b := public.get_invoice_detail(p_invoice);
  RESET ROLE;
  RETURN jsonb_build_object('data', a, 'detail', b);
END $$;
SELECT pg_temp.oi_assert(pg_temp.oi_detail(:'inv2'::uuid)#>>'{data,success}' = 'true' AND pg_temp.oi_detail(:'inv2'::uuid)#>>'{detail,success}' = 'true',
  'before deletion both readers find the invoice');
CREATE FUNCTION pg_temp.oi_dispatch_invoices(p_dispatch uuid) RETURNS text LANGUAGE plpgsql AS $$
DECLARE res jsonb;
BEGIN
  PERFORM pg_temp.oi_as_admin();
  res := public.get_dispatch_details(p_dispatch);
  RESET ROLE;
  PERFORM pg_temp.oi_assert(res->>'success'='true','get_dispatch_details: '||left(res::text,300));
  RETURN (SELECT string_agg(i#>>'{grn_item_details,package_mark}' || ':' || COALESCE(i#>>'{invoice_details,invoice_no}', '-'), ',' ORDER BY n)
          FROM jsonb_array_elements(res#>'{data,dispatch,items}') WITH ORDINALITY AS t(i,n))
    || ' | ' || (res#>>'{data,dispatch,statistics,total_invoiced_items}') || ' | ' || (res#>>'{data,dispatch,invoices_summary,total_invoices}')
    || ' | ' || (res#>>'{data,dispatch,invoices_summary,invoice_numbers}');
END $$;
SELECT pg_temp.oi_assert(pg_temp.oi_dispatch_invoices(:'lod1'::uuid) = 'L3:9801,L1:9801,L4:9801,L2:9801,M2:9802,M1:9802 | 6 | 2 | [9801, 9802]',
  'before deletion the dispatch shows both invoices: ' || pg_temp.oi_dispatch_invoices(:'lod1'::uuid));
UPDATE public.invoice SET deleted_at = now() WHERE id = :'inv2'::uuid;
-- A deleted invoice is shown in the dispatch as if the lines had none.
SELECT pg_temp.oi_assert(pg_temp.oi_dispatch_invoices(:'lod1'::uuid) = 'L3:9801,L1:9801,L4:9801,L2:9801,M2:-,M1:- | 4 | 1 | [9801]',
  'get_dispatch_details hides the deleted invoice (lines, count, summary): ' || pg_temp.oi_dispatch_invoices(:'lod1'::uuid));
-- update_invoice refuses it and leaves its lines alone.
SELECT pg_temp.oi_as_admin();
SELECT public.update_invoice(:'inv2'::uuid, jsonb_build_object('inv_no', 9802, 'inv_fin_year', 2026, 'gr_id', (SELECT id FROM public.goodsreceived WHERE gr_no='LO2'), 'gr_no', 'LO2',
  'customer_id', :'lines_customer', 'customer_name', 'Open Items Lines Customer', 'inv_date', '2026-06-20T06:00:00Z',
  'discount', 0, 'duration_mode', 'legacy'),
  ARRAY(SELECT jsonb_array_elements(pg_temp.oi_items('M1')))) AS refused_update \gset
RESET ROLE;
SELECT pg_temp.oi_assert((:'refused_update'::jsonb) = '{"success": false, "error": "Invoice not found"}'::jsonb, 'update_invoice refuses a deleted invoice: ' || :'refused_update');
SELECT pg_temp.oi_assert((SELECT count(*) FROM public.invoice_trl WHERE invoice_id = :'inv2'::uuid) = 2, 'the refused update left the deleted invoice''s two lines');
SELECT pg_temp.oi_assert(pg_temp.oi_detail(:'inv2'::uuid)#>'{data}' = '{"success": false, "error": "Invoice not found"}'::jsonb
    AND pg_temp.oi_detail(:'inv2'::uuid)#>'{detail}' = '{"success": false, "error": "Invoice not found"}'::jsonb,
  'a deleted invoice is not found by get_invoice_data and get_invoice_detail: ' || pg_temp.oi_detail(:'inv2'::uuid)::text);
SELECT pg_temp.oi_assert(pg_temp.oi_detail(:'inv1'::uuid)#>>'{detail,success}' = 'true', 'the other invoice is still found');
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SET LOCAL ROLE service_role;
SELECT public.get_invoice_range_for_print('9801', '9802', 2026) AS printed_after \gset
RESET ROLE;
SELECT pg_temp.oi_assert((SELECT array_agg((x->>'inv_no')::integer) FROM jsonb_array_elements((:'printed_after'::jsonb)->'data') x) = ARRAY[9801],
  'the print range skips the deleted invoice');

--------------------------------------------------------------------------------------------------
-- 3. Tied rows have one order. Receipts SA-B and SA-A (inserted in that order) of one date, one lot weight and item name.
--------------------------------------------------------------------------------------------------
SELECT pg_temp.oi_as_admin();
SELECT pg_temp.oi_assert(public.create_customer('Open Items Tie Zulu','9888889804')->>'success'='true','tie customer zulu');
RESET ROLE;
SELECT pg_temp.oi_as_admin();
SELECT pg_temp.oi_assert(public.create_customer('Open Items Tie Mike','9888889806')->>'success'='true','tie customer mike');
SELECT pg_temp.oi_assert(public.create_customer('Open Items Tie Kilo','9888889807')->>'success'='true','tie customer kilo');
SELECT pg_temp.oi_assert(public.create_customer('Open Items Tie Charlie','9888889808')->>'success'='true','tie customer charlie');
SELECT pg_temp.oi_assert(public.create_customer('Open Items Tie Alpha','9888889805')->>'success'='true','tie customer alpha');
RESET ROLE;
SELECT id AS tie_zulu FROM public.customers WHERE name='Open Items Tie Zulu' \gset
SELECT id AS tie_alpha FROM public.customers WHERE name='Open Items Tie Alpha' \gset
SELECT pg_temp.oi_as_admin();
SELECT pg_temp.oi_assert(public.save_grn(p_gr_no=>'SAB',p_date=>'2026-05-01T06:00:00Z',p_customer_id=>:'tie_zulu'::uuid,p_customer_name=>'Open Items Tie Zulu',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'picker_item','item_name','Open Items Tie Item','packaging','Bag','qty',5,'weight',7,'rack','R1','package_mark','T1'),
                            jsonb_build_object('item_id',:'picker_item','item_name','Open Items Tie Item','packaging','Bag','qty',5,'weight',7,'rack','R1','package_mark','T2')))->>'success'='true','receipt SAB');
SELECT pg_temp.oi_assert(public.save_grn(p_gr_no=>'SAA',p_date=>'2026-05-01T06:00:00Z',p_customer_id=>:'tie_zulu'::uuid,p_customer_name=>'Open Items Tie Zulu',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'picker_item','item_name','Open Items Tie Item','packaging','Bag','qty',5,'weight',7,'rack','R1','package_mark','T3'),
                            jsonb_build_object('item_id',:'picker_item','item_name','Open Items Tie Item','packaging','Bag','qty',5,'weight',7,'rack','R1','package_mark','T4')))->>'success'='true','receipt SAA');
RESET ROLE;
SELECT id AS tie_mike FROM public.customers WHERE name='Open Items Tie Mike' \gset
SELECT id AS tie_kilo FROM public.customers WHERE name='Open Items Tie Kilo' \gset
SELECT id AS tie_charlie FROM public.customers WHERE name='Open Items Tie Charlie' \gset
SELECT pg_temp.oi_as_admin();
SELECT pg_temp.oi_assert(public.save_grn(p_gr_no=>'SAD',p_date=>'2026-05-01T06:00:00Z',p_customer_id=>:'tie_mike'::uuid,p_customer_name=>'Open Items Tie Mike',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'picker_item','item_name','Open Items Tie Item','packaging','Bag','qty',5,'weight',7,'rack','R1','package_mark','T6')))->>'success'='true','receipt SAD');
SELECT pg_temp.oi_assert(public.save_grn(p_gr_no=>'SAE',p_date=>'2026-05-01T06:00:00Z',p_customer_id=>:'tie_kilo'::uuid,p_customer_name=>'Open Items Tie Kilo',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'picker_item','item_name','Open Items Tie Item','packaging','Bag','qty',5,'weight',7,'rack','R1','package_mark','T7')))->>'success'='true','receipt SAE');
SELECT pg_temp.oi_assert(public.save_grn(p_gr_no=>'SAF',p_date=>'2026-05-01T06:00:00Z',p_customer_id=>:'tie_charlie'::uuid,p_customer_name=>'Open Items Tie Charlie',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'picker_item','item_name','Open Items Tie Item','packaging','Bag','qty',5,'weight',7,'rack','R1','package_mark','T8')))->>'success'='true','receipt SAF');
SELECT pg_temp.oi_assert(public.save_grn(p_gr_no=>'SAC',p_date=>'2026-05-01T06:00:00Z',p_customer_id=>:'tie_alpha'::uuid,p_customer_name=>'Open Items Tie Alpha',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'picker_item','item_name','Open Items Tie Item','packaging','Bag','qty',5,'weight',7,'rack','R1','package_mark','T5')))->>'success'='true','receipt SAC');
RESET ROLE;
-- search_customer_items_for_order (paged by 1): receipt number, then lot id, behind the weight and name.
CREATE FUNCTION pg_temp.oi_search_page(p_customer uuid, p_size integer, p_offset integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE res jsonb;
BEGIN
  PERFORM pg_temp.oi_as_admin();
  res := public.search_customer_items_for_order('', p_customer, 'auto', 1, p_size, p_offset);
  RESET ROLE;
  RETURN COALESCE((SELECT string_agg(i->>'gr_no' || '/' || (i->>'id'), ',' ORDER BY n) FROM jsonb_array_elements(res->'items') WITH ORDINALITY AS t(i,n)), '');
END $$;
SELECT pg_temp.oi_assert(pg_temp.oi_search_page(:'tie_zulu'::uuid, 10, 0) = (SELECT string_agg(g.gr_no || '/' || t.id, ',' ORDER BY g.gr_no, t.id)
      FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.customer_id=:'tie_zulu'::uuid),
  'tied lots come back by receipt number, then lot id (SAA before SAB): ' || pg_temp.oi_search_page(:'tie_zulu'::uuid, 10, 0));
SELECT pg_temp.oi_assert(pg_temp.oi_search_page(:'tie_zulu'::uuid, 1, 0) || ',' || pg_temp.oi_search_page(:'tie_zulu'::uuid, 1, 1) || ',' ||
   pg_temp.oi_search_page(:'tie_zulu'::uuid, 1, 2) || ',' || pg_temp.oi_search_page(:'tie_zulu'::uuid, 1, 3) = pg_temp.oi_search_page(:'tie_zulu'::uuid, 10, 0),
  'four pages of one row repeat and skip nothing');
-- get_stock_aging_report: items by age, then receipt number, then lot id; customers by average age, then name, then id.
CREATE FUNCTION pg_temp.oi_aging(p_customer uuid) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE res jsonb;
BEGIN
  PERFORM pg_temp.oi_as_admin();
  res := public.get_stock_aging_report(p_customer);
  RESET ROLE;
  PERFORM pg_temp.oi_assert(res->>'success'='true','aging report: '||left(res::text,300));
  RETURN res;
END $$;
SELECT pg_temp.oi_assert((SELECT string_agg(i->>'gr_no', ',' ORDER BY n) FROM jsonb_array_elements(pg_temp.oi_aging(:'tie_zulu'::uuid)#>'{data,items}') WITH ORDINALITY AS t(i,n)) = 'SAA,SAA,SAB,SAB',
  'aging items: SAA before SAB: ' || (pg_temp.oi_aging(:'tie_zulu'::uuid)#>'{data,items}')::text);
SELECT pg_temp.oi_assert((SELECT array_agg(i->>'grn_item_id' ORDER BY n) FROM jsonb_array_elements(pg_temp.oi_aging(:'tie_zulu'::uuid)#>'{data,items}') WITH ORDINALITY AS t(i,n)) IS NOT NULL, 'aging items present');
-- The all-customers view: the five Tie customers have the same average age. They were created in the order Zulu, Mike, Kilo,
-- Charlie, Alpha (reverse name order), so an unordered tie shows them in that order; the answer lists them by name.
SELECT pg_temp.oi_assert((SELECT array_agg(c->>'customer_name' ORDER BY n) FILTER (WHERE c->>'customer_name' LIKE 'Open Items Tie%')
    FROM jsonb_array_elements(pg_temp.oi_aging(NULL)#>'{data,by_customer}') WITH ORDINALITY AS t(c,n)) = ARRAY['Open Items Tie Alpha','Open Items Tie Charlie','Open Items Tie Kilo','Open Items Tie Mike','Open Items Tie Zulu'],
  'aging customers with equal average age: by name: ' || (pg_temp.oi_aging(NULL)#>'{data,by_customer}')::text);
-- user_accessible_customers: the staff branch is ordered by id (search_customers calls the function once per row, so a name sort
-- is expensive); the customer branch by customer name, then id.
CREATE FUNCTION pg_temp.oi_accessible() RETURNS uuid[] LANGUAGE plpgsql AS $$
DECLARE r uuid[];
BEGIN PERFORM pg_temp.oi_as_admin(); r := public.user_accessible_customers(); RESET ROLE; RETURN r; END $$;
SELECT pg_temp.oi_assert(pg_temp.oi_accessible() = ARRAY(SELECT id FROM public.customers WHERE active = true ORDER BY id)
    AND array_length(pg_temp.oi_accessible(), 1) = (SELECT count(*) FROM public.customers WHERE active = true),
  'staff branch: active customers by id');
-- The customer branch: a customer-role profile assigned to Tie Zulu, Lines and Tie Alpha (in that order).
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active)
 VALUES (gen_random_uuid(), '919888889899', 'Open Items Customer User', 'customer', true) RETURNING id AS cust_profile, auth_user_id AS cust_auth \gset
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT :'cust_profile'::uuid, c, true FROM unnest(ARRAY[:'tie_zulu'::uuid, :'lines_customer'::uuid, :'tie_alpha'::uuid]) c;
SELECT set_config('request.jwt.claims', jsonb_build_object('role','authenticated','sub',:'cust_auth')::text, true);
SET LOCAL ROLE authenticated;
SELECT public.user_accessible_customers() AS cust_list \gset
RESET ROLE;
SELECT pg_temp.oi_assert(:'cust_list'::uuid[] = ARRAY(SELECT id FROM public.customers WHERE id IN (:'tie_zulu',:'lines_customer',:'tie_alpha') ORDER BY name, id)
    AND array_length(:'cust_list'::uuid[], 1) = 3 AND (:'cust_list'::uuid[])[1] = :'lines_customer'::uuid,
  'customer branch: assigned customers by name (Lines, Tie Alpha, Tie Zulu), assigned as Zulu, Lines, Alpha: ' || :'cust_list');

--------------------------------------------------------------------------------------------------
-- 4. The dead objects are gone; what stays stays.
--------------------------------------------------------------------------------------------------
SELECT pg_temp.oi_assert(NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public', 'warehouse_security') AND p.proname IN ('verify_otp', 'verify_otp_secure', 'phone_auth_login', 'track_user_activity',
      'update_customer_contact_with_auth_phone', 'get_priority_contact_for_customer', 'bulk_update_customers_priority_contact', 'get_grn_autocomplete')),
  'the dead functions are dropped');
SELECT pg_temp.oi_assert(to_regclass('public.customers_with_priority_contact') IS NULL, 'the dead view is dropped');
SELECT pg_temp.oi_assert((SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'create_item_storage_price') = 1
    AND to_regprocedure('public.create_item_storage_price(uuid,text,numeric,numeric,numeric,numeric,date,uuid,numeric,date)') IS NOT NULL
    AND to_regprocedure('public.create_item_storage_price(uuid,numeric,numeric,numeric,date,uuid,numeric,numeric,numeric,date)') IS NULL,
  'only the p_price_type overload of create_item_storage_price is left');
SELECT pg_temp.oi_assert(pg_get_functiondef('warehouse_security.authorize_rpc(text,jsonb)'::regprocedure) NOT LIKE '%get_grn_autocomplete%'
    AND pg_get_functiondef('warehouse_security.authorize_rpc(text,jsonb)'::regprocedure) LIKE '%get_grn_prefixes_with_stock%', 'the staff allowlist no longer names get_grn_autocomplete');
-- No function body still calls a dropped name (a word match: operator_verify_otp is not verify_otp).
SELECT pg_temp.oi_assert(NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public', 'warehouse_security', 'utils') AND p.prosrc ~ '\m(verify_otp|verify_otp_secure|phone_auth_login|track_user_activity|update_customer_contact_with_auth_phone|get_priority_contact_for_customer|bulk_update_customers_priority_contact|customers_with_priority_contact|get_grn_autocomplete)\M'),
  'no function body names a dropped object');
ROLLBACK;
