-- The stock reports cut their days on India's calendar.
--
-- The facilities keep their books in India (Asia/Kolkata, UTC+05:30). Migration 41 pins the
-- billable day to it (warehouse_security.business_date) and migration 56 moved every day cut
-- of the nine period reports to it. The stock reports were not among the nine: every day they
-- take from a receipt, a dispatch or a stock movement, and every age in days, still went
-- through a plain ::date or CURRENT_DATE, which is a day in the database session's time zone
-- (UTC on this image). A receipt made at 02:30 India time on 1 October was reported as 30
-- September by the stock summary and as 1 October by the GRN activity report, and a lot's age
-- in days, and the bucket it falls in, was one day more or less than the dates shown for 5.5
-- hours of every India day. This migration makes each of those an India day:
--
--   get_customer_stock_summary (6 expressions, 8 places)
--     summary.oldest_stock_date      MIN(g.date)::date            (1)
--     summary.last_grn_date          MAX(g3.date)::date           (1)
--     summary.last_dispatch_date     MAX(d.disp_date)::date       (1)
--     items[].grns[].date            g2.date::date                (2: in stock, out of stock)
--     out_of_stock_items[].grns[].emptied_date
--                                    MAX(sm.created_at)::date     (1)
--     out_of_stock_items: the window "emptied within the last 360 days"
--                                    sm.created_at >= NOW() - INTERVAL '360 days'   (2: the
--                                    lots listed under each item, and the items listed)
--   get_all_stock_summary (3 expressions)
--     summary.oldest_stock_date      MIN(g.date)::date            (1)
--     customers[].oldest_date        MIN(g.date)::date            (1)
--     customers[].latest_date        MAX(g.date)::date            (1)
--   get_stock_aging_report (3 expressions, 10 places; one customer and all customers)
--     aging_days, aging_bucket, and so the bucket totals, items_over_365_days and the averages
--                                    CURRENT_DATE - gr.date::date (8: aging_days and the three
--                                    bucket bounds, in each of the two branches)
--     dispatch_info.days_since_last_dispatch
--                                    CURRENT_DATE - di.last_dispatch_date::date          (1)
--     dispatch_info.avg_days_between_dispatches
--                                    di.last_dispatch_date::date - si.grn_date::date     (1)
--   get_customer_stock_analysis_v2 (1 expression)
--     the answer's message, "... as of <day> retrieved successfully"
--                                    to_char(p_date_filter, 'YYYY-MM-DD')                (1)
--
-- The forms, one for each kind of day:
--   the day of a moment     warehouse_security.business_date(col)       (migration 41)
--   today                   warehouse_security.business_date(now())     (as migrations 48 and 56)
--   an age in days          business_date(now()) - business_date(col): India's today minus
--                           India's day of the moment, a whole number of days, so the age, the
--                           bucket it falls in and the dates shown always agree
--   a window of N days      col >= (SELECT warehouse_security.business_day_start(
--                                     warehouse_security.business_date(now()) - N))
--                           (migration 56's helper): the lots emptied on India's day N days
--                           ago or later, the same rule as an age of at most N days
-- The window is the only one of these in a WHERE clause. It stays a comparison of the column
-- with one value per query, the shape it had. The value is written as an uncorrelated scalar
-- subquery so that it is evaluated once per query (an InitPlan) and not for every movement the
-- EXISTS looks at: business_date is STABLE and has a SET clause, so the planner neither folds
-- nor inlines it. stock_movements has an index on gr_trl_id only (the EXISTS joins through it),
-- none on created_at, before or after, so nothing here could use or lose an index. Every other
-- change is in a SELECT list or a CASE, which needs no such care. An aging query evaluates
-- business_date a few times per lot with stock; that is a few thousand cheap calls at most.
--
-- Not changed, because they are moments or not days at all:
--   aging items[].grn_date and dispatch_info.last_dispatch_date (moments, as migration 56
--   left grn_date, invoice_date and last_activity_date), metadata.retrieved_at and
--   as_of_date (moments), every comparison of a moment with a moment (get_customer_grn_items
--   compares gr.date with its two timestamptz parameters and shows gr.date as a moment;
--   get_customer_stock_analysis_v2 compares gr.date and disp_date with its date filter), and
--   the row orders (receipts and lots are ordered by the moment, newest first). Nothing in
--   get_item_wise_stock_list takes a day from a moment, so it needs nothing.
-- Also not changed: the weight expressions, the sort and summary additions of migration 52, the
-- authorize_rpc guard, SECURITY DEFINER, the search_path (and jit setting), the grants, and
-- every key's name and type (a date stays a date, an integer an integer, a message a string).
-- Figures change only for activity between 00:00 and 05:30 India time (18:30 to 24:00 UTC),
-- and for the edge of the 360-day window.
--
-- Method: the current definitions are patched, not rewritten. pg_get_functiondef keeps the
-- authorize_rpc guard, SECURITY DEFINER, the search_path, the grants and every other line
-- (including migrations 3, 45, 52, 58 and 59); each replaced text must occur exactly as often
-- as stated, or the migration fails and nothing is applied.

-- The definition with one marker replaced; fails unless the marker occurs
-- exactly `expected` times. Dropped at the end of this migration.
CREATE FUNCTION pg_temp.replace_marker(fn text, definition text, marker text, replacement text, expected integer) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE occurrences integer := (length(definition) - length(replace(definition, marker, ''))) / length(marker);
BEGIN
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker, 80);
  END IF;
  RETURN replace(definition, marker, replacement);
END $$;

DO $migration$
DECLARE
  change record;
BEGIN
  FOR change IN SELECT * FROM (VALUES
    -- get_customer_stock_summary: the summary (oldest stock, last receipt, last dispatch), the
    -- receipts of each item in stock and out of stock, the day a lot was emptied, and the
    -- 360-day window of the out-of-stock list (its lots and its item totals).
    (1, 'public.get_customer_stock_summary(uuid)',
     $b$'oldest_stock_date', MIN(g.date)::date$b$,
     $a$'oldest_stock_date', warehouse_security.business_date(MIN(g.date))$a$, 1),
    (2, 'public.get_customer_stock_summary(uuid)',
     $b$SELECT MAX(g3.date)::date$b$,
     $a$SELECT warehouse_security.business_date(MAX(g3.date))$a$, 1),
    (3, 'public.get_customer_stock_summary(uuid)',
     $b$SELECT MAX(d.disp_date)::date$b$,
     $a$SELECT warehouse_security.business_date(MAX(d.disp_date))$a$, 1),
    (4, 'public.get_customer_stock_summary(uuid)',
     $b$'date', g2.date::date,$b$,
     $a$'date', warehouse_security.business_date(g2.date),$a$, 2),
    (5, 'public.get_customer_stock_summary(uuid)',
     $b$SELECT MAX(sm.created_at)::date$b$,
     $a$SELECT warehouse_security.business_date(MAX(sm.created_at))$a$, 1),
    (6, 'public.get_customer_stock_summary(uuid)',
     $b$sm.created_at >= NOW() - INTERVAL '360 days'$b$,
     $a$sm.created_at >= (SELECT warehouse_security.business_day_start(warehouse_security.business_date(now()) - 360))$a$, 2),

    -- get_all_stock_summary: the oldest stock of the whole summary, the oldest and the latest
    -- receipt of each customer. (The leading key tells the two MIN(g.date) apart.)
    (7, 'public.get_all_stock_summary()',
     $b$'oldest_stock_date', MIN(g.date)::date$b$,
     $a$'oldest_stock_date', warehouse_security.business_date(MIN(g.date))$a$, 1),
    (8, 'public.get_all_stock_summary()',
     $b$'oldest_date', MIN(g.date)::date$b$,
     $a$'oldest_date', warehouse_security.business_date(MIN(g.date))$a$, 1),
    (9, 'public.get_all_stock_summary()',
     $b$'latest_date', MAX(g.date)::date$b$,
     $a$'latest_date', warehouse_security.business_date(MAX(g.date))$a$, 1),

    -- get_stock_aging_report: the age of a lot and the bucket bounds (aging_days plus the three
    -- CASE bounds, in the one-customer and the all-customers query), the days since the last
    -- dispatch, and the days between dispatches. The longer markers name di. and si., so they
    -- cannot be part of the first one.
    (10, 'public.get_stock_aging_report(uuid,integer[])',
     $b$CURRENT_DATE - gr.date::date$b$,
     $a$warehouse_security.business_date(now()) - warehouse_security.business_date(gr.date)$a$, 8),
    (11, 'public.get_stock_aging_report(uuid,integer[])',
     $b$CURRENT_DATE - di.last_dispatch_date::date$b$,
     $a$warehouse_security.business_date(now()) - warehouse_security.business_date(di.last_dispatch_date)$a$, 1),
    (12, 'public.get_stock_aging_report(uuid,integer[])',
     $b$di.last_dispatch_date::date - si.grn_date::date$b$,
     $a$warehouse_security.business_date(di.last_dispatch_date) - warehouse_security.business_date(si.grn_date)$a$, 1),

    -- get_customer_stock_analysis_v2: the day named in the message of a historical analysis.
    (13, 'public.get_customer_stock_analysis_v2(uuid,timestamp with time zone,jsonb,boolean)',
     $b$to_char(p_date_filter, 'YYYY-MM-DD')$b$,
     $a$to_char(warehouse_security.business_date(p_date_filter), 'YYYY-MM-DD')$a$, 1)
  ) AS changes(step, signature, before_text, after_text, times)
  ORDER BY step
  LOOP
    EXECUTE pg_temp.replace_marker(change.signature, pg_get_functiondef(change.signature::regprocedure),
      change.before_text, change.after_text, change.times);
  END LOOP;
END;
$migration$;

DROP FUNCTION pg_temp.replace_marker(text, text, text, text, integer);
NOTIFY pgrst, 'reload schema';
