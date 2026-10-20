-- The stock reports cut their days on India's calendar (migration 60).
--
-- get_customer_stock_summary, get_all_stock_summary, get_stock_aging_report and the message of
-- get_customer_stock_analysis_v2 took the day of a receipt, a dispatch or a stock movement with a
-- plain ::date, and the age of a lot from CURRENT_DATE, both in the session time zone (UTC on this
-- image). So activity between 00:00 and 05:30 in India (18:30 to 24:00 UTC) was reported one day
-- early, and a lot's age, and so its aging bucket, was one day off against the dates shown.
--
-- The reports read the clock (the age is India's today minus India's day of the receipt), so the
-- fixture is built from "today in India" read once at the start: every moment below is a number of
-- India days before it, at a minute of the India day, and every expected figure is computed from the
-- same today. The test therefore gives the same answers on any day. Only a run that straddles
-- midnight in India can fail it (the fixture and the reports would read different todays).
-- An India day is cut here with `day::timestamp AT TIME ZONE 'Asia/Kolkata'`, not with the helpers
-- under test. Dates "m1" is the first day of the previous month.
--
-- Customer Saffron, stock in storage (a night receipt is between 00:00 and 05:30 India time, so its
-- UTC day is the day before):
--   STA1  Cardamom 100   m1 00:30 (night; the last day of a month in UTC)   10 dispatched: 90 left
--   STA2  Cardamom  50   today-20 01:00 (night)
--   STA3  Pepper    20   today-15 11:30 (day: the same day in UTC and India)
--   STA4  Pepper     8   today-5 01:45 (night)
--   dispatches STD1 (5 bags of STA1, today-12 14:30, a day moment) and STD2 (5 bags of STA1,
--   today-8 02:30, night)
-- Customer Saffron, emptied lots (stock 0; the movement that emptied each is at the time shown):
--   STE1  Turmeric  7  received today-371 00:30; emptied today-360 00:01 (night): the FIRST India
--                       minute of the 360-day window. Its UTC day is today-361, so a UTC cut drops it.
--   STE2  Mustard   7  received today-372 00:30; emptied today-361 23:59: the last minute before the
--                       window, out in India and in UTC.
--   STE3  Cumin     6  received today-30 00:30; emptied today-3 00:30 (night)
-- Customer Jaggery, stock at ages that straddle the bucket bounds (120, 240, 364) and 365 days. "night"
-- is 00:30 India time and falls on the day before in UTC, "day" is 12:00 India time (06:30 UTC):
--   STJ1  stock   1  age 364  night      bucket 241-364      [UTC cut: 365, bucket 364+, until 18:30 UTC]
--   STJ2  stock   2  age 365  night      bucket 364+, not over 365 days  [UTC: 366, over 365]
--   STJ3  stock   4  age 365  day        bucket 364+, not over 365 days  [UTC: 364 after 18:30 UTC]
--         (14 received, 10 dispatched by STD3 at today-10 02:30, a night moment)
--   STJ4  stock   8  age 366  day        bucket 364+, over 365 days      [UTC: 365 after 18:30 UTC]
--   STJ5  stock  16  age 120  night      bucket 0-120       [UTC: 121, bucket 121-240]
--   STJ6  stock  32  age 241  day        bucket 241-364     [UTC: 240 after 18:30 UTC]
--   STJ7  stock  64  age 400  night      the oldest: the all-customers oldest stock date and days
-- A night receipt is one UTC day earlier than its India day, and the UTC today is one day earlier
-- than India's today only after 18:30 UTC; so the old UTC cut gets a night row wrong before 18:30 UTC
-- and a day row wrong after it. The test does not depend on that: it repeats the administrator's
-- checks with the session in UTC-12 (its date is a day behind India's before 17:30 India time) and
-- in UTC+14 (a day ahead of India's from 15:30 India time), so CURRENT_DATE and ::date, put back
-- anywhere, are wrong in at least one of the runs at every time of day.
-- The dispatch STD3 is a night moment taken from a day receipt (STJ3), so the days between its
-- dispatches differ by one between the cuts at every time of day (355 against 354).
-- Customer Tamarind has nothing; it is "another customer" for the customer account.
--
-- Every answer is read as the role under test and compared in the same session. The session time
-- zone is UTC (asserted) and the administrator's answers are repeated with the session in Los
-- Angeles, in UTC-12 and in UTC+14, where they must not move.
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.sd_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'report stock ist day: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.sd_eq(actual anyelement, expected anyelement, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF actual IS DISTINCT FROM expected THEN
    RAISE EXCEPTION 'report stock ist day: % (expected %, got %)', label, expected, actual;
  END IF;
END $$;
CREATE FUNCTION pg_temp.sd_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.sd_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- A moment of the India calendar: the given India day at the given minute of that day. Written with
-- AT TIME ZONE, not with the helpers under test.
CREATE FUNCTION pg_temp.sd_at(day date, minute_of_day integer) RETURNS timestamptz LANGUAGE sql AS $$
  SELECT (day::timestamp AT TIME ZONE 'Asia/Kolkata') + minute_of_day * interval '1 minute' $$;
-- The India day of a moment, written the same way.
CREATE FUNCTION pg_temp.sd_day(moment timestamptz) RETURNS date LANGUAGE sql AS $$
  SELECT (moment AT TIME ZONE 'Asia/Kolkata')::date $$;
-- The keys of an object, sorted bytewise.
CREATE FUNCTION pg_temp.sd_keys(o jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(k ORDER BY k COLLATE "C"), '{}') FROM jsonb_object_keys(o) AS k $$;
-- One field of every element of a list, in the returned order.
CREATE FUNCTION pg_temp.sd_column(list jsonb, value_key text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x->>value_key ORDER BY ord), '{}') FROM jsonb_array_elements(list) WITH ORDINALITY AS t(x, ord) $$;
-- The element of a list whose key_name starts with the prefix (exactly one expected).
CREATE FUNCTION pg_temp.sd_element(list jsonb, key_name text, prefix text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT CASE WHEN count(*) = 1 THEN min(x::text)::jsonb END
  FROM jsonb_array_elements(list) AS t(x) WHERE x->>key_name LIKE prefix || '%' $$;
-- A day as the reports return it: a JSON string "YYYY-MM-DD".
CREATE FUNCTION pg_temp.sd_is_day(j jsonb) RETURNS boolean LANGUAGE sql AS $$
  SELECT jsonb_typeof(j) = 'string' AND (j #>> '{}') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' $$;
-- A whole number as the reports return it: a JSON number without a fraction.
CREATE FUNCTION pg_temp.sd_is_whole(j jsonb) RETURNS boolean LANGUAGE sql AS $$
  SELECT jsonb_typeof(j) = 'number' AND (j #>> '{}') ~ '^-?[0-9]+$' $$;
-- A lot of an aging answer as "gr_no:days:bucket", sorted by receipt number.
CREATE FUNCTION pg_temp.sd_aged(items jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg((x->>'gr_no') || ':' || (x->>'aging_days') || ':' || (x->>'aging_bucket'), ' ' ORDER BY x->>'gr_no')
  FROM jsonb_array_elements(items) AS t(x) $$;
-- True when the guard refuses the statement: a raw 42501, or, from the bodies whose catch-all handler
-- turns it into an answer, success = false with one of its messages (in error, or in message).
CREATE FUNCTION pg_temp.sd_refused(statement text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  EXECUTE statement INTO answer;
  RETURN answer->>'success' = 'false'
    AND COALESCE(answer->>'error', answer->>'message', '') ~ '(Staff access required|Customer access denied|Active account required|Access denied)';
EXCEPTION WHEN insufficient_privilege THEN RETURN true;
  WHEN OTHERS THEN RETURN false;
END $$;
-- The plan of a statement, as one text.
CREATE FUNCTION pg_temp.sd_plan(statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE line text; plan text := '';
BEGIN
  FOR line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || statement LOOP plan := plan || line || E'\n'; END LOOP;
  RETURN plan;
END $$;

-- ---------------------------------------------------------------------------
-- Everything the four changed reports answer, read as the current role. today is India's today.
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.sd_check(who text, p_saffron uuid, p_jaggery uuid, p_today date, p_analysis boolean) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  m1 date := (date_trunc('month', p_today::timestamp) - interval '1 month')::date;
  a1 integer := p_today - m1;
  r jsonb; e jsonb;
  sum_ages integer := 364 + 365 + 365 + 366 + 120 + 241 + 400;
BEGIN
  -- ---- get_customer_stock_summary
  r := public.get_customer_stock_summary(p_saffron);
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r), ARRAY['items', 'out_of_stock_items', 'summary'], who || ' stock summary keys');
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r->'summary'),
    ARRAY['grn_count', 'grn_count_empty', 'last_dispatch_date', 'last_dispatch_no', 'last_grn_date', 'last_grn_no', 'oldest_stock_date',
          'total_items', 'total_quantity', 'total_weight_kg'], who || ' stock summary summary keys');
  PERFORM pg_temp.sd_eq(r#>>'{summary,oldest_stock_date}', m1::text, who || ' stock summary oldest_stock_date (STA1, the first of the month at 00:30)');
  PERFORM pg_temp.sd_eq(r#>>'{summary,last_grn_date}', (p_today - 5)::text, who || ' stock summary last_grn_date (STA4, 01:45)');
  PERFORM pg_temp.sd_eq(r#>>'{summary,last_dispatch_date}', (p_today - 8)::text, who || ' stock summary last_dispatch_date (STD2, 02:30)');
  PERFORM pg_temp.sd_assert(pg_temp.sd_is_day(r#>'{summary,oldest_stock_date}') AND pg_temp.sd_is_day(r#>'{summary,last_grn_date}')
    AND pg_temp.sd_is_day(r#>'{summary,last_dispatch_date}'), who || ' the summary days are still JSON date strings: ' || (r->'summary')::text);
  PERFORM pg_temp.sd_eq(r#>>'{summary,last_grn_no}' || '/' || (r#>>'{summary,last_dispatch_no}'), 'STA4/STD2', who || ' stock summary last numbers');
  PERFORM pg_temp.sd_eq((r#>>'{summary,total_items}') || '/' || (r#>>'{summary,total_quantity}') || '/' || (r#>>'{summary,total_weight_kg}')
      || '/' || (r#>>'{summary,grn_count}') || '/' || (r#>>'{summary,grn_count_empty}'),
    '2/168/840/4/3', who || ' stock summary counts and weight (unchanged)');
  -- The lots of each item in storage, newest receipt first: each on its India day.
  PERFORM pg_temp.sd_eq(pg_temp.sd_column(r->'items', 'item_name'), ARRAY['IST Stock Cardamom', 'IST Stock Pepper'], who || ' stock summary items');
  e := r#>'{items,0}';
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(e), ARRAY['grn_count', 'grns', 'item_id', 'item_name', 'packaging', 'total_stock', 'total_weight'], who || ' stock summary item keys');
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(e#>'{grns,0}'),
    ARRAY['date', 'gr_no', 'grn_id', 'item_weight', 'orig_qty', 'package_mark', 'packaging', 'rack', 'stock'], who || ' stock summary lot keys');
  PERFORM pg_temp.sd_eq(pg_temp.sd_column(e->'grns', 'gr_no') || pg_temp.sd_column(e->'grns', 'date'),
    ARRAY['STA2', 'STA1', (p_today - 20)::text, m1::text], who || ' Cardamom lots, newest receipt first, on their India days');
  PERFORM pg_temp.sd_eq(pg_temp.sd_column(e->'grns', 'stock'), ARRAY['50', '90'], who || ' Cardamom lot stock');
  e := r#>'{items,1}';
  PERFORM pg_temp.sd_eq(pg_temp.sd_column(e->'grns', 'gr_no') || pg_temp.sd_column(e->'grns', 'date'),
    ARRAY['STA4', 'STA3', (p_today - 5)::text, (p_today - 15)::text], who || ' Pepper lots, newest receipt first, on their India days');
  PERFORM pg_temp.sd_assert(pg_temp.sd_is_day(e#>'{grns,0,date}') AND pg_temp.sd_is_day(e#>'{grns,1,date}'), who || ' the lot days are JSON date strings');
  -- The lots emptied within the last 360 India days: STE1 (the first minute of the window) and STE3
  -- are in, STE2 (the minute before) is out; each on its India days.
  PERFORM pg_temp.sd_eq(pg_temp.sd_column(r->'out_of_stock_items', 'item_name'), ARRAY['IST Stock Cumin', 'IST Stock Turmeric'],
    who || ' emptied items: Mustard (emptied the minute before the window) is out, Turmeric (the first minute of it) is in: ' || (r->'out_of_stock_items')::text);
  e := r#>'{out_of_stock_items,0}';
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(e), ARRAY['grn_count', 'grns', 'item_id', 'item_name', 'packaging'], who || ' emptied item keys');
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(e#>'{grns,0}'),
    ARRAY['date', 'emptied_date', 'gr_no', 'grn_id', 'item_weight', 'orig_qty', 'package_mark', 'packaging', 'rack', 'stock'], who || ' emptied lot keys');
  PERFORM pg_temp.sd_eq((e#>>'{grns,0,gr_no}') || ' ' || (e#>>'{grns,0,date}') || ' ' || (e#>>'{grns,0,emptied_date}'),
    'STE3 ' || (p_today - 30)::text || ' ' || (p_today - 3)::text, who || ' Cumin lot: received 00:30, emptied 00:30');
  e := r#>'{out_of_stock_items,1}';
  PERFORM pg_temp.sd_eq((e#>>'{grns,0,gr_no}') || ' ' || (e#>>'{grns,0,date}') || ' ' || (e#>>'{grns,0,emptied_date}'),
    'STE1 ' || (p_today - 371)::text || ' ' || (p_today - 360)::text, who || ' Turmeric lot: emptied in the first India minute of the window');
  PERFORM pg_temp.sd_assert(pg_temp.sd_is_day(e#>'{grns,0,date}') AND pg_temp.sd_is_day(e#>'{grns,0,emptied_date}'), who || ' the emptied days are JSON date strings');
  PERFORM pg_temp.sd_eq(r#>>'{out_of_stock_items,0,grn_count}' || '/' || (r#>>'{out_of_stock_items,1,grn_count}'), '1/1', who || ' emptied lot counts');

  -- ---- get_all_stock_summary
  r := public.get_all_stock_summary();
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r), ARRAY['customers', 'success', 'summary'], who || ' all stock summary keys');
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r->'summary'),
    ARRAY['grn_count', 'oldest_stock_date', 'total_customers_with_stock', 'total_items', 'total_quantity', 'total_weight_kg'], who || ' all stock summary summary keys');
  PERFORM pg_temp.sd_eq(r#>>'{summary,oldest_stock_date}', (p_today - 400)::text, who || ' all stock summary oldest_stock_date (STJ7, 00:30)');
  PERFORM pg_temp.sd_assert(pg_temp.sd_is_day(r#>'{summary,oldest_stock_date}'), who || ' the oldest stock date is a JSON date string');
  PERFORM pg_temp.sd_eq((r#>>'{summary,total_customers_with_stock}') || '/' || (r#>>'{summary,total_items}') || '/' || (r#>>'{summary,total_quantity}')
      || '/' || (r#>>'{summary,grn_count}'), '2/3/295/11', who || ' all stock summary counts (unchanged)');
  e := pg_temp.sd_element(r->'customers', 'customer_name', 'IST Stock Saffron');
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(e), ARRAY['customer_id', 'customer_name', 'grn_count', 'item_count', 'latest_date', 'oldest_date', 'total_stock', 'total_weight'],
    who || ' all stock summary customer keys');
  PERFORM pg_temp.sd_eq((e->>'oldest_date') || ' ' || (e->>'latest_date'), m1::text || ' ' || (p_today - 5)::text,
    who || ' Saffron oldest and latest receipt with stock: ' || e::text);
  PERFORM pg_temp.sd_assert(pg_temp.sd_is_day(e->'oldest_date') AND pg_temp.sd_is_day(e->'latest_date'), who || ' the customer days are JSON date strings');
  PERFORM pg_temp.sd_eq((e->>'total_stock') || '/' || (e->>'grn_count') || '/' || (e->>'item_count'), '168/4/2', who || ' Saffron counts');
  e := pg_temp.sd_element(r->'customers', 'customer_name', 'IST Stock Jaggery');
  PERFORM pg_temp.sd_eq((e->>'oldest_date') || ' ' || (e->>'latest_date'), (p_today - 400)::text || ' ' || (p_today - 120)::text,
    who || ' Jaggery oldest (STJ7, 00:30) and latest (STJ5, 00:30) receipt: ' || e::text);
  PERFORM pg_temp.sd_eq((e->>'total_stock') || '/' || (e->>'grn_count') || '/' || (e->>'item_count'), '127/7/1', who || ' Jaggery counts');

  -- ---- get_stock_aging_report, one customer
  r := public.get_stock_aging_report(p_jaggery);
  PERFORM pg_temp.sd_eq(r->>'success', 'true', who || ' aging report (Jaggery): ' || left(r::text, 300));
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r), ARRAY['data', 'metadata', 'success'], who || ' aging keys');
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r->'data'), ARRAY['by_bucket', 'items', 'summary'], who || ' aging data keys');
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r#>'{data,summary}'),
    ARRAY['average_age_days', 'avg_dispatch_velocity_days', 'items_no_recent_dispatch', 'items_over_365_days', 'oldest_stock_days',
          'qty_over_365_days', 'total_items', 'total_quantity', 'total_weight_kg'], who || ' aging summary keys');
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r#>'{data,by_bucket}'), ARRAY['0-120', '121-240', '241-364', '364+'], who || ' aging bucket names');
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r#>'{data,by_bucket,0-120}'), ARRAY['item_count', 'percentage', 'total_quantity', 'total_weight'], who || ' aging bucket keys');
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r#>'{data,items,0}'),
    ARRAY['aging_bucket', 'aging_days', 'current_stock', 'dispatch_info', 'gr_no', 'grn_date', 'grn_id', 'item_name', 'original_qty', 'package_mark',
          'packaging', 'rack', 'weight'], who || ' aging item keys');
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r#>'{data,items,0,dispatch_info}'),
    ARRAY['avg_days_between_dispatches', 'days_since_last_dispatch', 'dispatch_count', 'last_dispatch_date', 'total_dispatched'], who || ' aging dispatch keys');
  -- The age of each lot and its bucket: India's today minus India's day of the receipt.
  PERFORM pg_temp.sd_eq(pg_temp.sd_aged(r#>'{data,items}'),
    'STJ1:364:241-364 STJ2:365:364+ STJ3:365:364+ STJ4:366:364+ STJ5:120:0-120 STJ6:241:241-364 STJ7:400:364+',
    who || ' ages and buckets of the Jaggery lots');
  PERFORM pg_temp.sd_assert((SELECT bool_and(pg_temp.sd_is_whole(x->'aging_days')) FROM jsonb_array_elements(r#>'{data,items}') AS t(x)),
    who || ' aging_days is still a whole number');
  -- Bucket totals (item count / quantity).
  PERFORM pg_temp.sd_eq((r#>>'{data,by_bucket,0-120,item_count}') || '/' || (r#>>'{data,by_bucket,0-120,total_quantity}') || ' '
      || (r#>>'{data,by_bucket,121-240,item_count}') || '/' || (r#>>'{data,by_bucket,121-240,total_quantity}') || ' '
      || (r#>>'{data,by_bucket,241-364,item_count}') || '/' || (r#>>'{data,by_bucket,241-364,total_quantity}') || ' '
      || (r#>>'{data,by_bucket,364+,item_count}') || '/' || (r#>>'{data,by_bucket,364+,total_quantity}'),
    '1/16 0/0 2/33 4/78', who || ' Jaggery bucket totals');
  e := r#>'{data,summary}';
  PERFORM pg_temp.sd_eq((e->>'total_items') || '/' || (e->>'total_quantity') || '/' || (e->>'oldest_stock_days') || '/' || (e->>'average_age_days')
      || '/' || (e->>'items_over_365_days') || '/' || (e->>'qty_over_365_days'),
    '7/127/400/317/2/72', who || ' Jaggery aging summary: ' || e::text);
  PERFORM pg_temp.sd_eq((e->>'avg_dispatch_velocity_days') || '/' || (e->>'items_no_recent_dispatch'), '355/6', who || ' Jaggery dispatch figures: ' || e::text);
  -- The dispatch of STJ3 (a day receipt, dispatched at 02:30 ten days ago).
  e := (SELECT x FROM jsonb_array_elements(r#>'{data,items}') AS t(x) WHERE x->>'gr_no' = 'STJ3');
  PERFORM pg_temp.sd_eq((e#>>'{dispatch_info,total_dispatched}') || '/' || (e#>>'{dispatch_info,dispatch_count}') || '/'
      || (e#>>'{dispatch_info,days_since_last_dispatch}') || '/' || (e#>>'{dispatch_info,avg_days_between_dispatches}'),
    '10/1/10/355', who || ' STJ3 dispatch info: ' || (e->'dispatch_info')::text);
  PERFORM pg_temp.sd_assert(pg_temp.sd_is_whole(e#>'{dispatch_info,days_since_last_dispatch}') AND pg_temp.sd_is_whole(e#>'{dispatch_info,avg_days_between_dispatches}'),
    who || ' the dispatch days are still whole numbers');
  PERFORM pg_temp.sd_assert((e#>>'{dispatch_info,last_dispatch_date}')::timestamptz = pg_temp.sd_at(p_today - 10, 150)
    AND (e->>'grn_date')::timestamptz = pg_temp.sd_at(p_today - 365, 720),
    who || ' the moments grn_date and last_dispatch_date are unchanged moments: ' || e::text);
  e := (SELECT x FROM jsonb_array_elements(r#>'{data,items}') AS t(x) WHERE x->>'gr_no' = 'STJ1');
  PERFORM pg_temp.sd_assert(e#>'{dispatch_info,days_since_last_dispatch}' = 'null'::jsonb AND e#>'{dispatch_info,avg_days_between_dispatches}' = 'null'::jsonb
    AND e#>>'{dispatch_info,dispatch_count}' = '0', who || ' a lot without a dispatch has no days: ' || (e->'dispatch_info')::text);

  -- ---- get_stock_aging_report, Saffron (a lot's age against the day shown, whatever today is)
  r := public.get_stock_aging_report(p_saffron);
  PERFORM pg_temp.sd_eq(pg_temp.sd_aged(r#>'{data,items}'),
    'STA1:' || a1 || ':0-120 STA2:20:0-120 STA3:15:0-120 STA4:5:0-120', who || ' ages of the Saffron lots');
  PERFORM pg_temp.sd_eq((r#>>'{data,summary,total_items}') || '/' || (r#>>'{data,summary,total_quantity}') || '/' || (r#>>'{data,summary,oldest_stock_days}')
      || '/' || (r#>>'{data,summary,average_age_days}') || '/' || (r#>>'{data,summary,items_over_365_days}'),
    '4/168/' || a1 || '/' || round((a1 + 40)::numeric / 4) || '/0', who || ' Saffron aging summary: ' || (r#>'{data,summary}')::text);
  e := (SELECT x FROM jsonb_array_elements(r#>'{data,items}') AS t(x) WHERE x->>'gr_no' = 'STA1');
  PERFORM pg_temp.sd_eq((e#>>'{dispatch_info,dispatch_count}') || '/' || (e#>>'{dispatch_info,days_since_last_dispatch}') || '/' || (e#>>'{dispatch_info,avg_days_between_dispatches}'),
    '2/8/' || ((a1 - 8) / 2), who || ' STA1 dispatch info (two dispatches, the last at 02:30 eight days ago): ' || (e->'dispatch_info')::text);
  PERFORM pg_temp.sd_assert((SELECT bool_and((x->>'aging_days')::integer = p_today - pg_temp.sd_day((x->>'grn_date')::timestamptz)) FROM jsonb_array_elements(r#>'{data,items}') AS t(x)),
    who || ' every age is India today minus the India day of its grn_date');

  -- ---- get_stock_aging_report, all customers
  r := public.get_stock_aging_report();
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r->'data'), ARRAY['by_bucket', 'by_customer', 'summary'], who || ' all aging data keys');
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r#>'{data,summary}'),
    ARRAY['average_age_days', 'items_over_365_days', 'oldest_stock_days', 'qty_over_365_days', 'total_customers', 'total_items', 'total_quantity'], who || ' all aging summary keys');
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r#>'{data,by_bucket,0-120}'), ARRAY['item_count', 'percentage', 'total_quantity'], who || ' all aging bucket keys');
  PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r#>'{data,by_customer,0}'),
    ARRAY['aging_distribution', 'average_age_days', 'customer_id', 'customer_name', 'items_over_365_days', 'oldest_stock_days', 'total_stock'], who || ' all aging customer keys');
  e := r#>'{data,summary}';
  PERFORM pg_temp.sd_eq((e->>'total_customers') || '/' || (e->>'total_items') || '/' || (e->>'total_quantity') || '/' || (e->>'oldest_stock_days')
      || '/' || (e->>'items_over_365_days') || '/' || (e->>'qty_over_365_days') || '/' || (e->>'average_age_days'),
    '2/11/295/400/2/72/' || round((sum_ages + a1 + 40)::numeric / 11), who || ' all-customers aging summary: ' || e::text);
  PERFORM pg_temp.sd_eq((r#>>'{data,by_bucket,0-120,item_count}') || '/' || (r#>>'{data,by_bucket,0-120,total_quantity}') || ' '
      || (r#>>'{data,by_bucket,121-240,item_count}') || '/' || (r#>>'{data,by_bucket,121-240,total_quantity}') || ' '
      || (r#>>'{data,by_bucket,241-364,item_count}') || '/' || (r#>>'{data,by_bucket,241-364,total_quantity}') || ' '
      || (r#>>'{data,by_bucket,364+,item_count}') || '/' || (r#>>'{data,by_bucket,364+,total_quantity}'),
    '5/184 0/0 2/33 4/78', who || ' all-customers bucket totals: ' || (r#>'{data,by_bucket}')::text);
  PERFORM pg_temp.sd_eq(pg_temp.sd_column(r#>'{data,by_customer}', 'customer_name'), ARRAY['IST Stock Jaggery Mart', 'IST Stock Saffron Cold'],
    who || ' customers, oldest average age first');
  e := r#>'{data,by_customer,0}';
  PERFORM pg_temp.sd_eq((e->>'average_age_days') || '/' || (e->>'oldest_stock_days') || '/' || (e->>'items_over_365_days') || '/' || (e->>'total_stock'),
    '317/400/2/127', who || ' Jaggery in the all-customers report: ' || e::text);
  PERFORM pg_temp.sd_eq((e#>>'{aging_distribution,0-120}') || '/' || (e#>>'{aging_distribution,121-240}') || '/' || (e#>>'{aging_distribution,241-364}')
      || '/' || (e#>>'{aging_distribution,364+}'), '16/0/33/78', who || ' Jaggery aging distribution: ' || (e->'aging_distribution')::text);

  -- ---- get_customer_stock_analysis_v2: the day named in the message
  IF p_analysis THEN
    r := public.get_customer_stock_analysis_v2(p_saffron, pg_temp.sd_at(p_today - 3, 30));
    PERFORM pg_temp.sd_eq(r->>'message', 'Historical stock analysis (v2 - GRN-level) as of ' || (p_today - 3)::text || ' retrieved successfully',
      who || ' analysis message names the India day of its date filter (00:30)');
    PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r), ARRAY['data', 'message', 'success'], who || ' analysis keys');
    PERFORM pg_temp.sd_eq(pg_temp.sd_keys(r#>'{data,aggregations}'),
      ARRAY['as_of_date', 'calculated_stock', 'has_data_integrity_issues', 'item_count', 'items_with_negative_stock', 'total_dispatch_qty', 'total_grn_qty', 'version'],
      who || ' analysis aggregation keys');
    PERFORM pg_temp.sd_assert((r#>>'{data,aggregations,as_of_date}')::timestamptz = pg_temp.sd_at(p_today - 3, 30), who || ' as_of_date stays the moment given');
    PERFORM pg_temp.sd_eq(public.get_customer_stock_analysis_v2(p_saffron)->>'message', 'Current stock analysis (v2 - GRN-level) retrieved successfully',
      who || ' analysis message without a date');
    r := public.get_customer_stock_analysis_v2(p_saffron);
    PERFORM pg_temp.sd_eq((r#>>'{data,aggregations,item_count}') || '/' || (r#>>'{data,aggregations,calculated_stock}'), '2/168', who || ' analysis figures (unchanged)');
  END IF;

  -- ---- Untouched functions: moments stay moments, and the item list is what it was
  r := public.get_customer_grn_items(p_saffron, pg_temp.sd_at(p_today - 20, 60), pg_temp.sd_at(p_today - 5, 105));
  PERFORM pg_temp.sd_eq(pg_temp.sd_column(r#>'{data,items}', 'gr_no'), ARRAY['STA4', 'STA3', 'STA2'], who || ' receipt lines between two moments, bounds included');
  PERFORM pg_temp.sd_assert((r#>>'{data,items,0,date}')::timestamptz = pg_temp.sd_at(p_today - 5, 105), who || ' a receipt line date is still the moment');
  r := public.get_item_wise_stock_list(p_saffron);
  PERFORM pg_temp.sd_eq(pg_temp.sd_column(r#>'{data,items}', 'item_name') || pg_temp.sd_column(r#>'{data,items}', 'total_stock'),
    ARRAY['IST Stock Cardamom', 'IST Stock Pepper', '140', '28'], who || ' item-wise stock list (unchanged)');
END $$;

-- ---------------------------------------------------------------------------
-- The functions: still single, guarded first, with the same grants and search_path
-- ---------------------------------------------------------------------------
SELECT pg_temp.sd_assert(current_setting('TimeZone') = 'UTC', 'the session time zone is UTC, so an unconverted day below would be a UTC day');
SELECT pg_temp.sd_assert(count(*) = 4
    AND bool_and(p.prosecdef)
    AND bool_and(pg_get_functiondef(p.oid) ~ ('BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''' || p.proname || ''','))
    AND bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE') AND has_function_privilege('service_role', p.oid, 'EXECUTE')
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
      AND NOT EXISTS (SELECT 1 FROM aclexplode(p.proacl) AS a WHERE a.grantee = 0))
    AND bool_and(pg_get_functiondef(p.oid) LIKE '%warehouse_security.business_date(%')
    AND NOT bool_or(pg_get_functiondef(p.oid) ~* '(CURRENT_DATE|::date|interval ''360 days''|to_char\(p_date_filter)'),
  'the four changed functions are single, SECURITY DEFINER, guarded first, granted as before, cut India days, and keep no session-zone day, CURRENT_DATE or NOW() - 360 days')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
  AND p.proname IN ('get_customer_stock_summary', 'get_all_stock_summary', 'get_stock_aging_report', 'get_customer_stock_analysis_v2');
SELECT pg_temp.sd_assert((SELECT p.proconfig FROM pg_proc p WHERE p.proname = 'get_customer_stock_summary')
      = ARRAY['search_path=pg_catalog, public, extensions, utils, pg_temp']
  AND (SELECT p.proconfig FROM pg_proc p WHERE p.proname = 'get_all_stock_summary') = ARRAY['search_path=pg_catalog, public, extensions, utils, pg_temp']
  AND (SELECT p.proconfig FROM pg_proc p WHERE p.proname = 'get_customer_stock_analysis_v2') = ARRAY['search_path=pg_catalog, public, extensions, utils, pg_temp']
  AND (SELECT p.proconfig FROM pg_proc p WHERE p.proname = 'get_stock_aging_report') = ARRAY['search_path=pg_catalog, public, extensions, utils, pg_temp', 'jit=off'],
  'the search_path (and the aging report''s jit setting) are as before');
-- The 360-day window: the two places, one value per query for the EXISTS, no clock call per row.
SELECT pg_temp.sd_assert((length(def) - length(replace(def, m, ''))) / length(m) = 2 AND def NOT LIKE '%NOW()%',
  'the 360-day window is written twice as an uncorrelated scalar subquery on India days')
FROM (SELECT pg_get_functiondef('public.get_customer_stock_summary(uuid)'::regprocedure) AS def,
  $m$sm.created_at >= (SELECT warehouse_security.business_day_start(warehouse_security.business_date(now()) - 360))$m$ AS m) w;
SELECT pg_temp.sd_assert(plan ~ 'InitPlan' AND plan ~ 'created_at >= (\$[0-9]|\(InitPlan [0-9]+\)\.col[0-9]+)',
  'the 360-day value is evaluated once (an InitPlan), not for every movement: ' || plan)
FROM (SELECT pg_temp.sd_plan($q$SELECT 1 FROM public.goodsreceived_trl gt WHERE gt.stock = 0 AND EXISTS (SELECT 1 FROM public.stock_movements sm
  WHERE sm.gr_trl_id = gt.id AND sm.balance_after = 0
  AND sm.created_at >= (SELECT warehouse_security.business_day_start(warehouse_security.business_date(now()) - 360)))$q$) AS plan) p;
-- The two functions with nothing to change are not touched (no day is taken from a moment in them).
SELECT pg_temp.sd_assert(count(*) = 2 AND bool_and(pg_get_functiondef(p.oid) !~* '(::date|CURRENT_DATE|business_date|date_trunc)'),
  'get_item_wise_stock_list and get_customer_grn_items take no day from a moment')
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('get_item_wise_stock_list', 'get_customer_grn_items');

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888889401', 'IST Stock Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888889402', 'IST Stock Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888889403', 'IST Stock Customer', 'customer', true, 'approved');
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888889401' \gset
SELECT pg_temp.sd_login('9888889401') AS admin_claims \gset
SELECT pg_temp.sd_login('9888889402') AS staff_claims \gset
SELECT pg_temp.sd_login('9888889403') AS customer_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('IST Stock Saffron Cold', '9888889411') RETURNING id AS saffron \gset
INSERT INTO public.customers(name, mobile) VALUES ('IST Stock Jaggery Mart', '9888889412') RETURNING id AS jaggery \gset
INSERT INTO public.customers(name, mobile) VALUES ('IST Stock Tamarind Agro', '9888889413') RETURNING id AS tamarind \gset
INSERT INTO public.items(name, packaging) VALUES
 ('IST Stock Cardamom', 'Bag'), ('IST Stock Pepper', 'Bag'), ('IST Stock Turmeric', 'Bag'), ('IST Stock Mustard', 'Bag'),
 ('IST Stock Cumin', 'Bag'), ('IST Stock Jaggery', 'Bag');
-- The customer login is assigned to Saffron only.
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'saffron'::uuid, true FROM public.user_profiles WHERE mobile = '919888889403';
-- India's today, read once; every moment below is relative to it.
SELECT warehouse_security.business_date(now()) AS today \gset
SELECT (date_trunc('month', :'today'::date::timestamp) - interval '1 month')::date AS m1 \gset
CREATE TEMP TABLE report_stock_ist_day_rows (gr_no text, at timestamptz, qty integer, item text, customer_id uuid, customer_name text);
INSERT INTO report_stock_ist_day_rows VALUES
  ('STA1', pg_temp.sd_at(:'m1'::date, 30), 100, 'IST Stock Cardamom', :'saffron', 'IST Stock Saffron Cold'),
  ('STA2', pg_temp.sd_at(:'today'::date - 20, 60), 50, 'IST Stock Cardamom', :'saffron', 'IST Stock Saffron Cold'),
  ('STA3', pg_temp.sd_at(:'today'::date - 15, 690), 20, 'IST Stock Pepper', :'saffron', 'IST Stock Saffron Cold'),
  ('STA4', pg_temp.sd_at(:'today'::date - 5, 105), 8, 'IST Stock Pepper', :'saffron', 'IST Stock Saffron Cold'),
  ('STE1', pg_temp.sd_at(:'today'::date - 371, 30), 7, 'IST Stock Turmeric', :'saffron', 'IST Stock Saffron Cold'),
  ('STE2', pg_temp.sd_at(:'today'::date - 372, 30), 7, 'IST Stock Mustard', :'saffron', 'IST Stock Saffron Cold'),
  ('STE3', pg_temp.sd_at(:'today'::date - 30, 30), 6, 'IST Stock Cumin', :'saffron', 'IST Stock Saffron Cold'),
  ('STJ1', pg_temp.sd_at(:'today'::date - 364, 30), 1, 'IST Stock Jaggery', :'jaggery', 'IST Stock Jaggery Mart'),
  ('STJ2', pg_temp.sd_at(:'today'::date - 365, 30), 2, 'IST Stock Jaggery', :'jaggery', 'IST Stock Jaggery Mart'),
  ('STJ3', pg_temp.sd_at(:'today'::date - 365, 720), 14, 'IST Stock Jaggery', :'jaggery', 'IST Stock Jaggery Mart'),
  ('STJ4', pg_temp.sd_at(:'today'::date - 366, 720), 8, 'IST Stock Jaggery', :'jaggery', 'IST Stock Jaggery Mart'),
  ('STJ5', pg_temp.sd_at(:'today'::date - 120, 30), 16, 'IST Stock Jaggery', :'jaggery', 'IST Stock Jaggery Mart'),
  ('STJ6', pg_temp.sd_at(:'today'::date - 241, 720), 32, 'IST Stock Jaggery', :'jaggery', 'IST Stock Jaggery Mart'),
  ('STJ7', pg_temp.sd_at(:'today'::date - 400, 30), 64, 'IST Stock Jaggery', :'jaggery', 'IST Stock Jaggery Mart');
GRANT SELECT ON report_stock_ist_day_rows TO authenticated;
-- A dispatch of the fixture: qty bags taken from the (only) received line of a receipt. As the administrator.
CREATE FUNCTION pg_temp.sd_dispatch(p_no text, p_day date, p_customer uuid, p_customer_name text, p_supervisor text, p_gr_no text, p_qty integer) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_temp.sd_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no', p_no,
      'disp_date', p_day::text, 'customer_id', p_customer, 'customer_name', p_customer_name,
      'supervisor_id', p_supervisor, 'supervisor_name', 'IST Stock Administrator'),
    ARRAY[(SELECT jsonb_build_object('gr_trl_id', t.id, 'disp_qty', p_qty)
           FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id WHERE g.gr_no = p_gr_no)],
    0, 'report-stock-ist-day-' || p_no)->>'success' = 'true', 'fixture dispatch ' || p_no);
END $$;

SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
-- Nothing from another test lies in storage: every stock figure below is this fixture's.
SELECT pg_temp.sd_assert(public.get_all_stock_summary()#>>'{summary,grn_count}' = '0' AND public.get_stock_aging_report()#>>'{data,summary,total_items}' = '0',
  'no stock in storage before the fixture');
SELECT pg_temp.sd_assert(public.save_grn(p_gr_no => r.gr_no, p_date => r.at,
  p_customer_id => r.customer_id, p_customer_name => r.customer_name, p_idempotency_key => 'report-stock-ist-day-' || r.gr_no,
  p_items => jsonb_build_array(jsonb_build_object('item_id', (SELECT i.id FROM public.items i WHERE i.name = r.item), 'item_name', r.item,
    'packaging', 'Bag', 'qty', r.qty, 'weight', 5)))->>'success' = 'true', 'fixture receipt ' || r.gr_no)
FROM report_stock_ist_day_rows r ORDER BY r.gr_no;
SELECT pg_temp.sd_dispatch('STD1', :'today'::date - 12, :'saffron'::uuid, 'IST Stock Saffron Cold', :'admin_profile', 'STA1', 5);
SELECT pg_temp.sd_dispatch('STD2', :'today'::date - 8, :'saffron'::uuid, 'IST Stock Saffron Cold', :'admin_profile', 'STA1', 5);
SELECT pg_temp.sd_dispatch('STD3', :'today'::date - 10, :'jaggery'::uuid, 'IST Stock Jaggery Mart', :'admin_profile', 'STJ3', 10);
RESET ROLE;
-- The dispatch RPC stores the start of its date; move each to its moment. Empty the three lots and
-- record the movement that emptied each (as the owner of the tables).
UPDATE public.dispatch SET disp_date = CASE disp_no
    WHEN 'STD1' THEN pg_temp.sd_at(:'today'::date - 12, 870)
    WHEN 'STD2' THEN pg_temp.sd_at(:'today'::date - 8, 150)
    WHEN 'STD3' THEN pg_temp.sd_at(:'today'::date - 10, 150) END
  WHERE disp_no IN ('STD1', 'STD2', 'STD3');
UPDATE public.goodsreceived_trl t SET stock = 0 FROM public.goodsreceived g WHERE g.id = t.gr_id AND g.gr_no IN ('STE1', 'STE2', 'STE3');
INSERT INTO public.stock_movements(gr_trl_id, movement_type, quantity, balance_before, balance_after, created_at)
 SELECT t.id, 'dispatch', t.qty, t.qty, 0, CASE g.gr_no
     WHEN 'STE1' THEN pg_temp.sd_at(:'today'::date - 360, 1)
     WHEN 'STE2' THEN pg_temp.sd_at(:'today'::date - 361, 1439)
     WHEN 'STE3' THEN pg_temp.sd_at(:'today'::date - 3, 30) END
 FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id WHERE g.gr_no IN ('STE1', 'STE2', 'STE3');
-- The fixture is where the header says it is.
SELECT pg_temp.sd_eq(
  (SELECT string_agg(g.gr_no || '@' || to_char(g.date AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI') || '/' || t.qty || '/' || t.stock, ' ' ORDER BY g.gr_no)
   FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id WHERE g.gr_no LIKE 'ST%'),
  (SELECT string_agg(r.gr_no || '@' || to_char(r.at AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI') || '/' || r.qty || '/'
      || CASE r.gr_no WHEN 'STA1' THEN 90 WHEN 'STJ3' THEN 4 WHEN 'STE1' THEN 0 WHEN 'STE2' THEN 0 WHEN 'STE3' THEN 0 ELSE r.qty END, ' ' ORDER BY r.gr_no)
   FROM report_stock_ist_day_rows r),
  'receipts at their moments, with the stock the dispatches and emptying leave');
SELECT pg_temp.sd_eq(
  (SELECT string_agg(d.disp_no || '@' || to_char(d.disp_date AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'), ' ' ORDER BY d.disp_no) FROM public.dispatch d WHERE d.disp_no LIKE 'STD%'),
  'STD1@' || (:'today'::date - 12) || ' 14:30 STD2@' || (:'today'::date - 8) || ' 02:30 STD3@' || (:'today'::date - 10) || ' 02:30',
  'dispatches at their moments');
-- The night moments are on the day before in UTC, which is what the old cut reported.
SELECT pg_temp.sd_eq((SELECT g.date::date FROM public.goodsreceived g WHERE g.gr_no = 'STA4'), :'today'::date - 6,
  'the session-zone day of a night receipt is the day before its India day (the cut the old code made)');

-- ---------------------------------------------------------------------------
-- The administrator, then the same session with the time zone elsewhere
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sd_check('administrator', :'saffron'::uuid, :'jaggery'::uuid, :'today'::date, true);
SET LOCAL TimeZone = 'America/Los_Angeles';
SELECT pg_temp.sd_check('administrator, session in Los Angeles', :'saffron'::uuid, :'jaggery'::uuid, :'today'::date, true);
SET LOCAL TimeZone = 'Etc/GMT+12';
SELECT pg_temp.sd_check('administrator, session in UTC-12', :'saffron'::uuid, :'jaggery'::uuid, :'today'::date, true);
SET LOCAL TimeZone = 'Pacific/Kiritimati';
SELECT pg_temp.sd_check('administrator, session in UTC+14', :'saffron'::uuid, :'jaggery'::uuid, :'today'::date, true);
SET LOCAL TimeZone = 'UTC';
RESET ROLE;

-- ---------------------------------------------------------------------------
-- Staff see the same days (and not the analysis, which the allowlist keeps for the others)
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sd_assert(warehouse_security.active_role() = 'staff', 'actual staff role');
SELECT pg_temp.sd_check('staff', :'saffron'::uuid, :'jaggery'::uuid, :'today'::date, false);
SELECT pg_temp.sd_assert(pg_temp.sd_refused(format('SELECT public.get_customer_stock_analysis_v2(%L::uuid)', :'saffron')),
  'staff do not run get_customer_stock_analysis_v2 (as before)');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- A customer account: its own customer on India days, nothing of another customer or of all
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'customer_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.sd_assert(warehouse_security.active_role() = 'customer', 'actual customer role');
SELECT pg_temp.sd_eq(r#>>'{summary,oldest_stock_date}' || ' ' || (r#>>'{summary,last_grn_date}') || ' ' || (r#>>'{summary,last_dispatch_date}'),
  :'m1' || ' ' || (:'today'::date - 5) || ' ' || (:'today'::date - 8), 'customer account, own stock summary days')
FROM (SELECT public.get_customer_stock_summary(:'saffron'::uuid) AS r) answer;
SELECT pg_temp.sd_eq(r#>>'{data,summary,oldest_stock_days}' || ' ' || pg_temp.sd_aged(r#>'{data,items}'),
  (:'today'::date - :'m1'::date) || ' STA1:' || (:'today'::date - :'m1'::date) || ':0-120 STA2:20:0-120 STA3:15:0-120 STA4:5:0-120',
  'customer account, own aging report')
FROM (SELECT public.get_stock_aging_report(:'saffron'::uuid) AS r) answer;
SELECT pg_temp.sd_eq(r->>'message', 'Historical stock analysis (v2 - GRN-level) as of ' || (:'today'::date - 3) || ' retrieved successfully',
  'customer account, own analysis message')
FROM (SELECT public.get_customer_stock_analysis_v2(:'saffron'::uuid, pg_temp.sd_at(:'today'::date - 3, 30)) AS r) answer;
SELECT pg_temp.sd_assert(pg_temp.sd_refused(s.statement), 'a customer account was answered: ' || s.statement)
FROM (VALUES
  (format('SELECT public.get_customer_stock_summary(%L::uuid)', :'tamarind')),
  (format('SELECT public.get_customer_stock_summary(%L::uuid)', :'jaggery')),
  (format('SELECT public.get_stock_aging_report(%L::uuid)', :'tamarind')),
  (format('SELECT public.get_stock_aging_report(%L::uuid)', :'jaggery')),
  (format('SELECT public.get_customer_stock_analysis_v2(%L::uuid, %L::timestamptz)', :'tamarind', '2026-10-01T19:00:00Z')),
  ('SELECT public.get_stock_aging_report()'),
  ('SELECT public.get_all_stock_summary()')
) AS s(statement);
-- The refusal helper can tell an answer from a refusal.
SELECT pg_temp.sd_assert(NOT pg_temp.sd_refused(format('SELECT public.get_customer_stock_summary(%L::uuid)', :'saffron')),
  'the refusal check itself answers false for an allowed call');
RESET ROLE;
ROLLBACK;
SELECT 'report stock ist day: the stock reports cut India days and ages, the session zone does not move them, and authorization is unchanged' AS result;
