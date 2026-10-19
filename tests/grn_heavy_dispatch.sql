-- Five receipts (HVD1 to HVD5) of ten lots each, every lot fully dispatched by many small dispatches over many
-- dates (100 to 300+ per lot, 7,885 dispatches in all). Fictional data; runs only in migrations.sh's disposable,
-- network-disabled database; everything rolls back.
--
--   receipt  lots  dispatches per lot                          permutation
--   HVD1     10    101..110                                    10 items, Bag, 50 kg
--   HVD2     10    100,103,...,127 (+3 per lot)                5 items x (Bag, Box), kg 5/12/25/50/1
--   HVD3     10    100                                         2 lots per item (marks differ), kg 7/33/19/41/26
--   HVD4     10    301..310, 1 unit each, over 401 days        year boundary 2023/24 and leap day 2024-02-29
--   HVD5     10    301,302,303 / 104,106,108,110 / 101,102,103 same-day dispatches (97-day span), mixed
--
-- Plan: pg_temp.hv_lot() (one row per lot) and pg_temp.hv_plan() (one row per dispatch: lot, number, quantity,
-- day) are pure functions of generate_series and modulo arithmetic; no random(). Every expected number below is
-- computed from them, plus literal totals written by hand.
-- Dates: every GRN and dispatch is on or before 2025-12-07 (HVD4 runs 2023-06 to 2024-07, across the 2023/24 year
-- boundary and the leap day 2024-02-29). Each item has its own packaging (Bag, Box, Crate, Carton, Sack). Each receipt
-- is saved the way the GRN review step saves it: p_rates carries one {scope:'everyone', 0-50 kg} entry per item that has
-- no rate yet, applied from the GRN day by apply_grn_rates (no import path, no replace_item_rates), with sender,
-- supervisor and registration filled; dispatches carry a registration. Customer mobiles are 91 + 10 digits.
-- Deviations from the brief: goodsreceived_trl.weight is an integer and save_grn casts it with ::int, so the
-- fractional weights (0.5, 12.5, 7.25, 33.333) are replaced by whole kilograms (1, 12, 7, 33). A dispatch for a
-- customer other than the lot's customer is refused by migration 39, so no lot is dispatched by two customers.
-- The dispatch date is set ONLY by the 'disp_date' key of the header passed to
-- public.create_dispatch_with_stock_check in pg_temp.hv_build (marked DATE SET HERE); it is stored as the start of
-- that date in the session zone (UTC, asserted), the same India day. No update is made to any table.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.hv_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'grn heavy dispatch: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.hv_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.hv_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;

-- ===========================================================================
-- PLAN (pure functions)
-- ===========================================================================
CREATE FUNCTION pg_temp.hv_lot() RETURNS TABLE(rcpt int, k int, n int, item_no int, packaging text, weight int,
  mark text, rdate date, dstart date, span int, ma int, mb int) LANGUAGE sql IMMUTABLE AS $$
 SELECT gr, gk,
  CASE gr WHEN 1 THEN 100+gk WHEN 2 THEN 100+3*(gk-1) WHEN 3 THEN 100 WHEN 4 THEN 300+gk
          ELSE (ARRAY[301,302,303,104,106,108,110,101,102,103])[gk] END,
  CASE WHEN gr IN (2,3) THEN (gk+1)/2 ELSE gk END,
  CASE gr WHEN 2 THEN CASE WHEN gk%2=1 THEN 'Bag' ELSE 'Box' END
          WHEN 3 THEN CASE WHEN ((gk+1)/2)%2=1 THEN 'Bag' ELSE 'Crate' END
          WHEN 4 THEN CASE WHEN gk%2=1 THEN 'Bag' ELSE 'Carton' END
          WHEN 5 THEN (ARRAY['Bag','Box','Sack'])[1+gk%3] ELSE 'Bag' END,
  CASE gr WHEN 1 THEN 50 WHEN 2 THEN (ARRAY[5,12,25,50,1])[1+(gk-1)%5]
          WHEN 3 THEN (ARRAY[7,33,19,41,26])[1+(gk-1)%5]
          WHEN 4 THEN (ARRAY[10,20,25,50,30])[1+(gk-1)%5] ELSE (ARRAY[50,25,40,10,5])[1+(gk-1)%5] END,
  'H'||gr||chr(64+gk),
  x.d-3, x.d, (ARRAY[127,131,113,401,97])[gr], (ARRAY[3,5,7,13,11])[gr], (ARRAY[7,11,5,29,3])[gr]
 FROM generate_series(1,5) gr CROSS JOIN generate_series(1,10) gk
 CROSS JOIN LATERAL (SELECT (ARRAY['2025-03-01','2025-05-01','2025-07-01','2023-06-01','2025-09-01'])[gr]::date AS d) x
$$;
CREATE FUNCTION pg_temp.hv_plan() RETURNS TABLE(rcpt int, k int, j int, q int, day date) LANGUAGE sql IMMUTABLE AS $$
 SELECT l.rcpt, l.k, gj,
  CASE WHEN l.rcpt=4 THEN 1 ELSE 1+((gj+l.k)%3) END,
  CASE WHEN l.rcpt=4 AND gj=1 THEN DATE '2024-02-29'
       WHEN l.rcpt=4 AND gj=2 THEN DATE '2023-12-31'
       WHEN l.rcpt=4 AND gj=3 THEN DATE '2024-01-01'
       ELSE l.dstart + ((gj*l.ma + l.k*l.mb) % l.span) END
 FROM pg_temp.hv_lot() l CROSS JOIN LATERAL generate_series(1,l.n) gj
$$;

-- ===========================================================================
-- FIXTURE BEGIN: only public functions (create_customer, create_item, save_grn, create_dispatch_with_stock_check).
-- Called as the administrator in the authenticated role. Reusable as seed data: only the names and the plan matter.
-- ===========================================================================
CREATE FUNCTION pg_temp.hv_build(admin_profile uuid, admin_name text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE rec record; res jsonb; cust uuid; items jsonb; rates jsonb; t0 timestamptz := clock_timestamp(); made int := 0;
BEGIN
  FOR rec IN SELECT g AS rcpt FROM generate_series(1,5) g LOOP
    res := public.create_customer('Heavy Dispatch Customer '||rec.rcpt, '91988888950'||rec.rcpt);
    PERFORM pg_temp.hv_assert(res->>'success'='true','customer '||rec.rcpt||': '||res);
  END LOOP;
  -- Each item has its own packaging (a line's packaging is its item's, fixed in the app): an item is one number
  -- and one packaging, e.g. "Heavy Dispatch Item 03 Box".
  FOR rec IN SELECT DISTINCT l.item_no, l.packaging FROM pg_temp.hv_lot() l ORDER BY 1,2 LOOP
    res := public.create_item('Heavy Dispatch Item '||lpad(rec.item_no::text,2,'0')||' '||rec.packaging, rec.packaging);
    PERFORM pg_temp.hv_assert(res->>'success'='true','item '||rec.item_no||' '||rec.packaging||': '||res);
  END LOOP;
  FOR rec IN SELECT g AS rcpt FROM unnest(ARRAY[4,1,2,3,5]) g LOOP
    SELECT id INTO cust FROM public.customers WHERE name='Heavy Dispatch Customer '||rec.rcpt;
    SELECT jsonb_agg(jsonb_build_object('item_id',i.id,'item_name',i.name,'packaging',i.packaging,'qty',s.qty,
        'weight',l.weight,'rack','R'||l.k,'package_mark',l.mark) ORDER BY l.k) INTO items
      FROM pg_temp.hv_lot() l
      JOIN public.items i ON i.name='Heavy Dispatch Item '||lpad(l.item_no::text,2,'0')||' '||l.packaging
      JOIN (SELECT p.rcpt, p.k, sum(p.q)::int AS qty FROM pg_temp.hv_plan() p GROUP BY 1,2) s ON s.rcpt=l.rcpt AND s.k=l.k
      WHERE l.rcpt=rec.rcpt;
    -- Rates as the GRN review step sends them: an item with no rate on the GRN day (find_storage_price) gets one entry {scope:'everyone', 0-50 kg},
    -- applied from the GRN day by apply_grn_rates; items that already have one need none (p_rates = []). The receipts go
    -- in date order (HVD4 2023, then HVD1, 2, 3, 5), so every item is priced from the day of the first receipt that uses it.
    -- find_storage_price is not granted to authenticated (the app reads the rates through get_item_storage_prices), so
    -- the decision is taken as the owner, then the role goes back.
    RESET ROLE;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('scope','everyone','item_id',x.id,'weight_min',0,'weight_max',50,
        'unit_price',2+x.item_no*0.5,'labour_rate',1,'tax_percent',5) ORDER BY x.id),'[]'::jsonb) INTO rates
      FROM (SELECT DISTINCT i.id, l.item_no FROM pg_temp.hv_lot() l
            JOIN public.items i ON i.name='Heavy Dispatch Item '||lpad(l.item_no::text,2,'0')||' '||l.packaging
            WHERE l.rcpt=rec.rcpt
              AND (public.find_storage_price(i.id, cust, l.weight, l.rdate, 'monthly')).id IS NULL) x;  -- no rate on the GRN day
    SET LOCAL ROLE authenticated;
    PERFORM pg_temp.hv_assert(jsonb_array_length(items)=10,'ten lots planned for HVD'||rec.rcpt);
    res := public.save_grn(p_gr_no=>'HVD'||rec.rcpt,
      p_date=>((SELECT min(rdate) FROM pg_temp.hv_lot() WHERE rcpt=rec.rcpt)+time '12:00')::timestamptz,
      p_customer_id=>cust, p_customer_name=>'Heavy Dispatch Customer '||rec.rcpt, p_pricing_mode=>'MONTHLY',
      p_idempotency_key=>'hvd-grn-'||rec.rcpt, p_items=>items,
      p_sender_id=>admin_profile, p_sender_name=>admin_name, p_supervisor_id=>admin_profile, p_supervisor_name=>admin_name,
      p_registration=>'GJ05HV'||lpad(rec.rcpt::text,4,'0'),
      p_rates=>rates);
    PERFORM pg_temp.hv_assert(res->>'success'='true','receipt HVD'||rec.rcpt||': '||res);
  END LOOP;
  RAISE NOTICE 'heavy dispatch fixture: receipts saved in %', clock_timestamp()-t0;
END $$;
-- Dispatches number lo..hi of the plan (numbered by receipt, lot, dispatch).
CREATE FUNCTION pg_temp.hv_dispatch_range(admin_profile uuid, admin_name text, lo int, hi int) RETURNS int LANGUAGE plpgsql AS $$
DECLARE rec record; res jsonb; made int := 0;
BEGIN
  FOR rec IN
    SELECT p.*, row_number() OVER (ORDER BY p.rcpt,p.k,p.j) AS seq, t.id AS lot, g.customer_id, c.name AS cname
    FROM pg_temp.hv_plan() p
    JOIN public.goodsreceived g ON g.gr_no='HVD'||p.rcpt
    JOIN public.goodsreceived_trl t ON t.gr_id=g.id AND t.package_mark='H'||p.rcpt||chr(64+p.k)
    JOIN public.customers c ON c.id=g.customer_id
    ORDER BY p.rcpt,p.k,p.j
  LOOP
    CONTINUE WHEN rec.seq < lo OR rec.seq > hi;
    -- DATE SET HERE: the 'disp_date' key below is the only place a dispatch date is set.
    res := public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','V'||lpad(rec.seq::text,6,'0'),
        'disp_date',rec.day::text,'customer_id',rec.customer_id,'customer_name',rec.cname,
        'supervisor_id',admin_profile,'supervisor_name',admin_name,
        'registration','GJ05HV'||lpad(rec.rcpt::text,4,'0')),
      ARRAY[jsonb_build_object('gr_trl_id',rec.lot,'disp_qty',rec.q)],0,'hvd-disp-'||rec.seq);
    PERFORM pg_temp.hv_assert(res->>'success'='true','dispatch '||rec.seq||': '||res);
    made := made+1;
    IF made % 1000 = 0 THEN RAISE NOTICE 'progress % %', made, clock_timestamp(); END IF;
  END LOOP;
  RETURN made;
END $$;
-- ===========================================================================
-- FIXTURE END
-- ===========================================================================

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888889500','Heavy Dispatch Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT pg_temp.hv_login('9888889500') AS admin_claims \gset
SELECT pg_temp.hv_assert(current_setting('TimeZone')='UTC','session zone is UTC, so a dispatch stored at the start of its date is on that India day');

-- The plan itself, before anything is built (literal totals worked out by hand).
SELECT pg_temp.hv_assert((SELECT count(*) FROM pg_temp.hv_plan())=7885,'plan holds 7885 dispatches');
SELECT pg_temp.hv_assert((SELECT string_agg(c::text,',' ORDER BY r) FROM (SELECT rcpt r, count(*) c FROM pg_temp.hv_plan() GROUP BY 1) x)
  ='1055,1135,1000,3055,1640','plan dispatches per receipt 1055,1135,1000,3055,1640');
SELECT pg_temp.hv_assert((SELECT count(*) FROM pg_temp.hv_lot() WHERE rcpt=5 AND n>=300)=3
  AND (SELECT count(*) FROM pg_temp.hv_lot() WHERE rcpt=5 AND n BETWEEN 104 AND 110)=4
  AND (SELECT string_agg(n::text,',' ORDER BY k) FROM pg_temp.hv_lot() WHERE rcpt=5 AND k>=8)='101,102,103','HVD5 lot counts');
SELECT pg_temp.hv_assert((SELECT bool_and(d>=90) FROM (SELECT rcpt, count(DISTINCT day) d FROM pg_temp.hv_plan() GROUP BY 1) x),'at least 90 distinct days per receipt');
SELECT pg_temp.hv_assert((SELECT count(DISTINCT day) FROM pg_temp.hv_plan() WHERE rcpt=4)>=300,'HVD4 spreads over many days');
SELECT pg_temp.hv_assert((SELECT count(*) FROM (SELECT rcpt, day FROM pg_temp.hv_plan() GROUP BY 1,2 HAVING count(*)>=3) x WHERE rcpt=5)>0,'HVD5 has several dispatches on one day');

SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT set_config('hv.admin',:'admin_profile',true);
SELECT pg_temp.hv_build(:'admin_profile'::uuid,'Heavy Dispatch Administrator');
RESET ROLE;
-- TEST HARNESS ONLY (not part of the fixture): one transaction holds all 7,885 dispatches here, and every write
-- statement marks the list queue rows dirty (warehouse_security.mark_lists_dirty, migration 91) by updating the
-- same few rows again. Inside ONE transaction each update lengthens a row version chain that the next update must
-- walk, so the n-th dispatch costs about n times the first (measured: 250 dispatches in 1.3 s, 5,000 in 6.5 min).
-- A facility commits each dispatch on its own and never sees this. The marker is therefore replaced by a no-op
-- for the loop and the original definition is put back and compared afterwards.
SELECT pg_get_functiondef('warehouse_security.mark_lists_dirty(text[])'::regprocedure) AS mark_original \gset
CREATE OR REPLACE FUNCTION warehouse_security.mark_lists_dirty(p_views text[]) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$ BEGIN NULL; END $$;
DO $$
DECLARE t0 timestamptz := clock_timestamp(); made int; lo int;
BEGIN
  made := 0;
  FOR lo IN 0..7 LOOP
    ANALYZE public.dispatch; ANALYZE public.dispatch_trl; ANALYZE public.stock_movements; ANALYZE public.goodsreceived_trl;
    ANALYZE public.idempotency_keys;
    SET LOCAL ROLE authenticated;
    made := made + pg_temp.hv_dispatch_range(current_setting('hv.admin')::uuid,'Heavy Dispatch Administrator',lo*1000+1,lo*1000+1000);
    RESET ROLE;
  END LOOP;
  PERFORM pg_temp.hv_assert(made=7885,'7885 dispatches built');
  RAISE NOTICE 'heavy dispatch fixture: % dispatches in %', made, clock_timestamp()-t0;
END $$;
SELECT :'mark_original' AS restore_sql \gset
SELECT :'restore_sql' \gexec
SELECT pg_temp.hv_assert(pg_get_functiondef('warehouse_security.mark_lists_dirty(text[])'::regprocedure)=:'mark_original','mark_lists_dirty is back as it was');
-- The list screens read materialized views that a worker refreshes after commit; refresh them now, as that worker does.
SELECT warehouse_security.mark_lists_dirty(warehouse_security.list_refresh_views());
SELECT warehouse_security.refresh_dirty_lists();


-- ===========================================================================
-- ASSERTIONS on the tables (1 to 4, 6)
-- ===========================================================================
-- 1. stock 0, none negative
SELECT pg_temp.hv_assert((SELECT count(*)=50 AND bool_and(t.stock=0) FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no LIKE 'HVD%'),
  'all 50 lots have stock exactly 0');
SELECT pg_temp.hv_assert((SELECT count(*)=0 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no LIKE 'HVD%' AND t.stock<>0),'no lot with stock other than 0');
-- 2. per lot: dispatch count and quantity against the plan and the received quantity
SELECT pg_temp.hv_assert((SELECT count(*)=50 AND bool_and(a.cnt=p.n AND a.qty=p.q AND a.qty=a.received) FROM (
    SELECT substr(g.gr_no,4)::int rcpt, ascii(substr(t.package_mark,3,1))-64 k, t.qty received,
      count(dt.id) cnt, COALESCE(sum(dt.disp_qty),0) qty
    FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id
    LEFT JOIN public.dispatch_trl dt ON dt.gr_trl_id=t.id
    WHERE g.gr_no LIKE 'HVD%' GROUP BY 1,2,3) a
  JOIN (SELECT rcpt,k,count(*) n,sum(q) q FROM pg_temp.hv_plan() GROUP BY 1,2) p ON p.rcpt=a.rcpt AND p.k=a.k),
  'every lot: dispatch count and quantity equal the plan, and the quantity equals the received quantity');
-- 3. weight per receipt = sum of qty x weight over the lots
SELECT pg_temp.hv_assert((SELECT count(*)=5 AND bool_and(a.kg=p.kg) FROM (
    SELECT substr(g.gr_no,4)::int rcpt, sum(dt.disp_qty::numeric*t.weight) kg
    FROM public.dispatch_trl dt JOIN public.goodsreceived_trl t ON t.id=dt.gr_trl_id JOIN public.goodsreceived g ON g.id=t.gr_id
    WHERE g.gr_no LIKE 'HVD%' GROUP BY 1) a
  JOIN (SELECT p.rcpt, sum(p.q::numeric*l.weight) kg FROM pg_temp.hv_plan() p JOIN pg_temp.hv_lot() l ON l.rcpt=p.rcpt AND l.k=p.k GROUP BY 1) p ON p.rcpt=a.rcpt),
  'dispatched weight of each receipt equals the sum of qty x weight');
-- 4. movement chain per lot: n movements, each quantity = after - before (negative), first before = received,
-- last after = 0, and every after is the next before (balances strictly fall, so the before values order the chain).
SELECT pg_temp.hv_assert((SELECT count(*)=50 AND bool_and(c.cnt=p.n AND c.start_ok AND c.end_ok AND c.links=c.cnt-1 AND c.signs_ok AND c.distinct_before=c.cnt) FROM (
    SELECT m.rcpt, m.k, count(*) cnt, count(DISTINCT m.balance_before) distinct_before,
      max(m.balance_before)=max(m.received) AS start_ok, min(m.balance_after)=0 AS end_ok,
      count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.stock_movements n WHERE n.gr_trl_id=m.gr_trl_id AND n.balance_before=m.balance_after)) AS links,
      bool_and(m.quantity=m.balance_after-m.balance_before AND m.quantity<0 AND m.movement_type='dispatch') AS signs_ok
    FROM (SELECT substr(g.gr_no,4)::int rcpt, ascii(substr(t.package_mark,3,1))-64 k, t.qty received, sm.*
          FROM public.stock_movements sm JOIN public.goodsreceived_trl t ON t.id=sm.gr_trl_id JOIN public.goodsreceived g ON g.id=t.gr_id
          WHERE g.gr_no LIKE 'HVD%') m GROUP BY m.rcpt, m.k) c
  JOIN (SELECT rcpt,k,count(*) n FROM pg_temp.hv_plan() GROUP BY 1,2) p ON p.rcpt=c.rcpt AND p.k=c.k),
  'each lot: movement chain complete, from the received quantity to 0, one movement per dispatch');
-- the last link of the chain ends at 0 and the first starts at the received quantity (links = count-1 above
-- leaves exactly the last movement without a successor)
SELECT pg_temp.hv_assert((SELECT count(*)=50 FROM (SELECT sm.gr_trl_id FROM public.stock_movements sm JOIN public.goodsreceived_trl t ON t.id=sm.gr_trl_id
    JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no LIKE 'HVD%' AND sm.balance_before=t.qty GROUP BY 1 HAVING count(*)=1) x),'exactly one movement per lot starts at the received quantity');
-- IST days of the dispatches: leap day and year boundary of HVD4
SELECT pg_temp.hv_assert((SELECT count(*) FROM public.dispatch d WHERE d.disp_no LIKE 'V%' AND (d.disp_date AT TIME ZONE 'Asia/Kolkata')::date=DATE '2024-02-29')
  =(SELECT count(*) FROM pg_temp.hv_plan() WHERE day=DATE '2024-02-29') AND (SELECT count(*) FROM pg_temp.hv_plan() WHERE day=DATE '2024-02-29')>=10,
  'dispatches on the IST leap day 2024-02-29 equal the plan');
SELECT pg_temp.hv_assert((SELECT string_agg(to_char(d.disp_date AT TIME ZONE 'Asia/Kolkata','YYYY-MM-DD')||'='||c,',' ORDER BY d.disp_date) FROM (
      SELECT disp_date, count(*) c FROM public.dispatch WHERE disp_no LIKE 'V%' AND disp_date >= '2023-12-31' AND disp_date < '2024-01-02' GROUP BY 1) d)
  =(SELECT string_agg(day::text||'='||c,',' ORDER BY day) FROM (SELECT day, count(*) c FROM pg_temp.hv_plan() WHERE day IN (DATE '2023-12-31',DATE '2024-01-01') GROUP BY 1) y),
  'year boundary: dispatches on 2023-12-31 and 2024-01-01 equal the plan');
-- 6. grand totals from the tables
SELECT pg_temp.hv_assert((SELECT count(*) FROM public.dispatch_trl dt JOIN public.dispatch d ON d.id=dt.disp_id WHERE d.disp_no LIKE 'V%' AND d.deleted_at IS NULL)=7885
  AND (SELECT count(*) FROM public.dispatch WHERE disp_no LIKE 'V%')=7885
  AND (SELECT sum(dt.disp_qty) FROM public.dispatch_trl dt JOIN public.dispatch d ON d.id=dt.disp_id WHERE d.disp_no LIKE 'V%')=(SELECT sum(q) FROM pg_temp.hv_plan())
  AND (SELECT sum(t.qty) FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no LIKE 'HVD%')=(SELECT sum(q) FROM pg_temp.hv_plan()),
  'grand total: 7885 dispatches and the planned units, equal to everything received');

-- Packaging: a line's packaging is its item's, and equals the plan.
SELECT pg_temp.hv_assert((SELECT count(*)=50 AND bool_and(t.packaging=i.packaging AND t.packaging=l.packaging) FROM public.goodsreceived_trl t
    JOIN public.goodsreceived g ON g.id=t.gr_id JOIN public.items i ON i.id=t.item_id
    JOIN pg_temp.hv_lot() l ON l.rcpt=substr(g.gr_no,4)::int AND l.mark=t.package_mark WHERE g.gr_no LIKE 'HVD%')
  AND (SELECT count(DISTINCT packaging) FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no LIKE 'HVD%')=5,
  'every line has its item''s packaging, as planned, with five package names in all');
-- Rates and required fields: every lot has a storage rate on its GRN day and on its last dispatch day; the receipts
-- carry sender and supervisor, the dispatches a registration; no date is in the future.
SELECT pg_temp.hv_assert((SELECT count(*)=50 AND bool_and((f).id IS NOT NULL) FROM (
    SELECT public.find_storage_price(t.item_id, g.customer_id, t.weight, g.date::date, 'monthly') AS f
    FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no LIKE 'HVD%') x),
  'find_storage_price returns a rate for every lot on its GRN day');
SELECT pg_temp.hv_assert((SELECT count(*)=50 AND bool_and((f).id IS NOT NULL) FROM (
    SELECT public.find_storage_price(t.item_id, g.customer_id, t.weight, (SELECT max(d.disp_date)::date FROM public.dispatch_trl dt JOIN public.dispatch d ON d.id=dt.disp_id WHERE dt.gr_trl_id=t.id), 'monthly') AS f
    FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no LIKE 'HVD%') x),
  'find_storage_price returns a rate for every lot on its last dispatch day');
SELECT pg_temp.hv_assert((SELECT count(*)=5 AND bool_and(sender_id IS NOT NULL AND supervisor_id IS NOT NULL AND registration IS NOT NULL
    AND sender_name IS NOT NULL AND supervisor_name IS NOT NULL) FROM public.goodsreceived WHERE gr_no LIKE 'HVD%'),'receipts carry sender, supervisor and registration');
SELECT pg_temp.hv_assert((SELECT count(*)=7885 AND bool_and(registration IS NOT NULL AND supervisor_id IS NOT NULL) FROM public.dispatch WHERE disp_no LIKE 'V%'),'dispatches carry a registration and a supervisor');
SELECT pg_temp.hv_assert((SELECT max(disp_date) FROM public.dispatch WHERE disp_no LIKE 'V%') < DATE '2026-10-01'
  AND (SELECT max(date) FROM public.goodsreceived WHERE gr_no LIKE 'HVD%') < DATE '2026-10-01'
  AND (SELECT max(day) FROM pg_temp.hv_plan()) < DATE '2026-10-01','no GRN or dispatch date after 2026-09-30');

-- ===========================================================================
-- ASSERTIONS on the reads (5), as the administrator
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE r int; l record; cust uuid; a jsonb; off int; pg jsonb; seen int; total int; qsum bigint; ids text[]; plan_n int; plan_q bigint; plan_kg numeric;
  d date; exp_n int; exp_q bigint; exp_kg numeric; first_day date; last_day date;
BEGIN
  FOR r IN 1..5 LOOP
    SELECT id INTO cust FROM public.customers WHERE name='Heavy Dispatch Customer '||r;
    SELECT count(*), sum(q), sum(q::numeric*lt.weight) INTO plan_n, plan_q, plan_kg
      FROM pg_temp.hv_plan() p JOIN pg_temp.hv_lot() lt ON lt.rcpt=p.rcpt AND lt.k=p.k WHERE p.rcpt=r;
    -- get_grn_item_dispatches for every lot
    FOR l IN SELECT t.id, ascii(substr(t.package_mark,3,1))-64 AS k FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='HVD'||r ORDER BY 2 LOOP
      a := public.get_grn_item_dispatches(l.id);
      SELECT count(*), sum(q), min(day), max(day) INTO exp_n, exp_q, first_day, last_day FROM pg_temp.hv_plan() WHERE rcpt=r AND k=l.k;
      PERFORM pg_temp.hv_assert(a->>'success'='true' AND (a#>>'{data,summary,total_dispatches}')::int=exp_n
        AND (a#>>'{data,summary,total_dispatched_qty}')::bigint=exp_q AND (a#>>'{data,summary,remaining_stock}')::int=0
        AND jsonb_array_length(a#>'{data,dispatches}')=exp_n,'lot history HVD'||r||' lot '||l.k||' summary');
      PERFORM pg_temp.hv_assert((a#>>'{data,dispatches,0,disp_date}')::timestamptz AT TIME ZONE 'Asia/Kolkata' = last_day::timestamp + time '05:30'
        AND (a#>>(('{data,dispatches,'||(exp_n-1)||',disp_date}')::text[]))::timestamptz AT TIME ZONE 'Asia/Kolkata' = first_day::timestamp + time '05:30',
        'lot history HVD'||r||' lot '||l.k||' newest and oldest day');
    END LOOP;
    -- paging: pages of 100 (smaller than the lot count)
    total := NULL; seen := 0; qsum := 0; ids := '{}'; off := 0;
    LOOP
      pg := public.get_customer_dispatch_items(cust, NULL, NULL, '{}'::jsonb, 'disp_no', 'asc', 100, off);
      PERFORM pg_temp.hv_assert(pg->>'success'='true','items page HVD'||r||' offset '||off);
      total := (pg#>>'{data,pagination,total_count}')::int;
      EXIT WHEN jsonb_array_length(pg#>'{data,items}')=0;
      SELECT seen + count(*), qsum + sum((x->>'disp_qty')::int), ids || array_agg((x->>'dispatch_id')||'/'||(x->>'grn_item_id'))
        INTO seen, qsum, ids FROM jsonb_array_elements(pg#>'{data,items}') x;
      off := off + 100;
      EXIT WHEN off > 5000;
    END LOOP;
    PERFORM pg_temp.hv_assert(total=plan_n AND seen=plan_n AND cardinality(ids)=plan_n AND (SELECT count(DISTINCT i) FROM unnest(ids) i)=plan_n AND qsum=plan_q,
      'paging HVD'||r||': every dispatch exactly once over the pages (rows '||seen||', distinct '||(SELECT count(DISTINCT i) FROM unnest(ids) i)||', expected '||plan_n||')');
    pg := public.get_customer_dispatch_items(cust, NULL, NULL, '{}'::jsonb, 'disp_no', 'asc', 20, 0);
    PERFORM pg_temp.hv_assert((pg#>>'{data,aggregations,total_dispatch_qty}')::bigint=plan_q AND (pg#>>'{data,aggregations,total_weight}')::numeric=plan_kg
      AND (pg#>>'{data,aggregations,record_count}')::int=plan_n
      /* total_initial_qty is not asserted: the function sums the lot's received quantity once per dispatch line */,
      'aggregations HVD'||r||' quantity, weight, count');
    -- activity report: whole range, first day, last day
    SELECT min(day), max(day) INTO first_day, last_day FROM pg_temp.hv_plan() WHERE rcpt=r;
    FOREACH d IN ARRAY ARRAY[first_day, last_day] LOOP
      SELECT count(*), sum(q), sum(q::numeric*lt.weight) INTO exp_n, exp_q, exp_kg
        FROM pg_temp.hv_plan() p JOIN pg_temp.hv_lot() lt ON lt.rcpt=p.rcpt AND lt.k=p.k WHERE p.rcpt=r AND p.day=d;
      a := public.get_customer_dispatch_activity(cust, d, d);
      PERFORM pg_temp.hv_assert((a#>>'{summary,total_dispatches}')::int=exp_n AND (a#>>'{summary,total_quantity}')::bigint=exp_q
        AND (a#>>'{summary,total_weight}')::numeric=exp_kg AND jsonb_array_length(a->'dispatches')=exp_n,
        'activity HVD'||r||' on the single day '||d||' (expected '||exp_n||' dispatches, got '||(a#>>'{summary,total_dispatches}')||')');
      pg := public.get_customer_dispatch_items(cust, d::timestamptz, (d+1)::timestamptz - interval '1 second', '{}'::jsonb, 'disp_no', 'asc', 20, 0);
      PERFORM pg_temp.hv_assert((pg#>>'{data,aggregations,record_count}')::int=exp_n AND (pg#>>'{data,aggregations,total_dispatch_qty}')::bigint=exp_q,
        'items filter HVD'||r||' on the single day '||d);
    END LOOP;
    -- one page: the packaging of every row is the planned one (by package mark)
    pg := public.get_customer_dispatch_items(cust, NULL, NULL, '{}'::jsonb, 'disp_no', 'asc', 100, 0);
    PERFORM pg_temp.hv_assert(jsonb_array_length(pg#>'{data,items}')=100 AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(pg#>'{data,items}') x LEFT JOIN pg_temp.hv_lot() hl ON hl.rcpt=r AND hl.mark=x->>'package_mark'
        WHERE hl.packaging IS DISTINCT FROM x->>'packaging'),'page of HVD'||r||': packaging of every row equals the plan');
    -- list screens (after the refresh): dispatch list pages of 1000, then the stock summary
    total := NULL; seen := 0; qsum := 0; ids := '{}'; off := 0;
    LOOP
      pg := public.get_dispatch_list(NULL, NULL, jsonb_build_object('customer_name','Heavy Dispatch Customer '||r), 'disp_no', 'asc', 1000, off);
      PERFORM pg_temp.hv_assert(pg->>'success'='true','dispatch list HVD'||r||' offset '||off||': '||left(pg::text,200));
      total := (pg#>>'{pagination,total_count}')::int;
      EXIT WHEN jsonb_array_length(pg->'data')=0;
      SELECT seen + count(*), qsum + sum((x->>'total_qty')::int), ids || array_agg(x->>'disp_no')
        INTO seen, qsum, ids FROM jsonb_array_elements(pg->'data') x;
      off := off + 1000;
      EXIT WHEN off > 5000;
    END LOOP;
    PERFORM pg_temp.hv_assert(total=plan_n AND seen=plan_n AND (SELECT count(DISTINCT i) FROM unnest(ids) i)=plan_n AND qsum=plan_q,
      'dispatch list HVD'||r||': count '||seen||' of '||plan_n||', quantity '||qsum||' of '||plan_q);
    a := public.get_customer_stock_summary(cust);
    PERFORM pg_temp.hv_assert((a#>>'{summary,total_quantity}')::bigint=0 AND jsonb_array_length(a->'items')=0
      AND (a#>>'{summary,grn_count_empty}')::int=1,'stock summary HVD'||r||' shows nothing in stock: '||left(a::text,300));
    -- GRN list screen: get_all_grn_items for this customer, paged by receipt as the app does (migration 98)
    pg := public.get_all_grn_items(p_filters => jsonb_build_object('customer_ids', jsonb_build_array(cust), 'page_by', 'receipt'),
      p_sort_by => 'date', p_sort_order => 'desc', p_limit => 50, p_offset => 0);
    PERFORM pg_temp.hv_assert(pg->>'success'='true' AND pg#>>'{pagination,unit}'='receipt' AND (pg#>>'{pagination,total_count}')::int=1
      AND jsonb_array_length(pg->'data')=10
      AND (SELECT bool_and(x->>'gr_no'='HVD'||r) AND sum((x->>'qty')::bigint)=plan_q AND sum((x->>'stock')::bigint)=0 FROM jsonb_array_elements(pg->'data') x)
      AND (pg#>>'{aggregates,total_qty}')::bigint=plan_q AND (pg#>>'{aggregates,total_stock}')::bigint=0,
      'GRN list screen HVD'||r||': 1 receipt, 10 lines, received '||plan_q||', stock 0: '||left(pg::text,300));
    -- GRN number search (the only use of get_grn_list in the app)
    pg := public.get_grn_list(NULL, NULL, 'date', 'desc', 50, 0, jsonb_build_object('gr_no','HVD'));
    PERFORM pg_temp.hv_assert(pg->>'success'='true' AND (
        SELECT count(*)=1 AND bool_and((x->>'total_qty')::bigint=plan_q AND (x->>'total_stock')::bigint=0 AND (x->>'total_weight')::numeric=0
          AND (x->>'items_count')::int=10) FROM jsonb_array_elements(pg#>'{data,grns}') x WHERE x->>'gr_no'='HVD'||r),
      'GRN number search HVD'||r||' shows all '||plan_q||' received and stock 0 in 10 lines: '||left(pg::text,300));
    a := public.get_customer_dispatch_activity(cust, first_day, last_day);
    PERFORM pg_temp.hv_assert((a#>>'{summary,total_dispatches}')::int=plan_n AND (a#>>'{summary,total_quantity}')::bigint=plan_q
      AND (a#>>'{summary,total_weight}')::numeric=plan_kg AND jsonb_array_length(a->'dispatches')=plan_n,'activity HVD'||r||' over the whole range');
    -- one day short at each end loses exactly the dispatches of that day
    SELECT count(*) INTO exp_n FROM pg_temp.hv_plan() WHERE rcpt=r AND day>first_day;
    a := public.get_customer_dispatch_activity(cust, first_day+1, last_day);
    PERFORM pg_temp.hv_assert((a#>>'{summary,total_dispatches}')::int=exp_n,'activity HVD'||r||' without the first day');
  END LOOP;
  -- HVD4 single days: leap day and the year boundary
  SELECT id INTO cust FROM public.customers WHERE name='Heavy Dispatch Customer 4';
  FOREACH d IN ARRAY ARRAY[DATE '2024-02-29', DATE '2023-12-31', DATE '2024-01-01'] LOOP
    SELECT count(*), sum(q) INTO exp_n, exp_q FROM pg_temp.hv_plan() WHERE rcpt=4 AND day=d;
    a := public.get_customer_dispatch_activity(cust, d, d);
    PERFORM pg_temp.hv_assert(exp_n>=10 AND (a#>>'{summary,total_dispatches}')::int=exp_n AND (a#>>'{summary,total_quantity}')::bigint=exp_q,
      'HVD4 day '||d||' lists '||exp_n||' dispatches');
    FOR l IN SELECT x->>'disp_date' dd FROM jsonb_array_elements(a->'dispatches') x LOOP
      PERFORM pg_temp.hv_assert(l.dd=d::text,'HVD4 dispatch on '||d||' shows the day '||l.dd);
    END LOOP;
  END LOOP;
END $$;
RESET ROLE;
ROLLBACK;
