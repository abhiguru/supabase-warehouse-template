-- Report days follow India's calendar.
--
-- The facilities keep their books in India (Asia/Kolkata, UTC+05:30), and migration 41 pins
-- the billable day to it (warehouse_security.business_date). The report functions did not:
-- every day they cut from a receipt, dispatch or invoice time was a day in the database
-- session's time zone, which is UTC on this image. So activity between 00:00 and 05:30 in
-- India counted against the previous day, a period also took in the first five and a half
-- hours after its last day, and a by-day or by-month list put such rows under the day or
-- month before. This migration makes every one of those day cuts an India day:
--
--   get_all_dispatch_activity          period (3 places), by_date, latest_dispatch, defaults
--   get_all_grn_activity               period (3 places), by_date, latest_grn, defaults
--   get_all_customer_activity_summary  period (receipts, dispatches, invoices, last activity)
--   get_customer_dispatch_activity     period (2 places), the disp_date of each dispatch
--   get_customer_grn_activity          period (both branches), today when no day is given
--   get_customer_activity_detail       period (summary and monthly), months, month-end
--                                      stock, stock age (days since receipt)
--   get_customer_invoice_summary       period (both branches), by_month, today when no
--                                      day is given
--   get_operations_dashboard           period (KPIs and trends), the daily trend keys
--   get_grn_list                       date filter (both ends)
--
-- The forms, one for each kind of day cut:
--   a period p_from..p_to (calendar days, type date)
--     col >= warehouse_security.business_day_start(p_from)
--     AND col < warehouse_security.business_day_start(p_to + 1)
--   the day of a moment       warehouse_security.business_date(col)        (migration 41)
--   the month of a moment     date_trunc('month', warehouse_security.business_date(col)::timestamp)
--                             or to_char(warehouse_security.business_date(col), 'YYYY-MM')
--   today                     warehouse_security.business_date(now())      (as migration 48)
-- The period keeps migrations 54 and 55's whole last day (before the start of the day after)
-- and compares the column itself with two constants, so the indexes on goodsreceived.date,
-- dispatch.disp_date and invoice.inv_date stay usable.
--
-- warehouse_security.business_day_start (new) is the first moment of a calendar day in India,
-- the other half of business_date: business_date(business_day_start(d)) = d, and the moment
-- before it is the day before (tests/report_ist_day.sql checks both). It is plain SQL with
-- schema-qualified names and no SET clause, so the planner inlines it and folds it to a
-- constant: a SET clause would stop that and cost a function call per row in a sequential
-- scan. When a facility time-zone setting is added, this function changes with business_date.
-- business_date itself is not changed (billing keeps exactly its behaviour).
--
-- The two parameter defaults of get_all_dispatch_activity and get_all_grn_activity are
-- evaluated with the caller's rights, which do not include the private helpers, so they spell
-- the same India day out: (pg_catalog.timezone('Asia/Kolkata', pg_catalog.now()))::date.
-- The app always passes both days; the defaults only serve a call without them.
--
-- Not changed: the parameters stay calendar days; times in the answers (grn_date,
-- invoice_date, last_activity_date, ...) stay moments; nothing outside these day cuts.
--
-- Method: the current definitions are patched, not rewritten. pg_get_functiondef keeps the
-- authorize_rpc guard, SECURITY DEFINER, the search_path, the grants and every other line
-- (including migrations 52, 54 and 55); each replaced text must occur exactly as often as
-- stated, or the migration fails.

-- The first moment of a calendar day in India. See above for why it has no SET clause.
CREATE FUNCTION warehouse_security.business_day_start(day date) RETURNS timestamptz
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT pg_catalog.timezone('Asia/Kolkata', CAST(day AS pg_catalog.timestamp))
$$;
REVOKE ALL ON FUNCTION warehouse_security.business_day_start(date) FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON FUNCTION warehouse_security.business_day_start(date) IS
  'First moment of a calendar day in India (migration 56); the inverse of business_date. Report periods run from business_day_start(first day) to before business_day_start(last day + 1).';

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
  definition text;
  current_fn text := '';
BEGIN
  -- The changes of one function are applied to its text in the listed order, then the
  -- function is replaced once. A marker that is part of another one is listed after it
  -- has been replaced, or carries enough context (a leading space) to tell them apart.
  FOR change IN SELECT * FROM (VALUES
    -- get_all_dispatch_activity: summary, by_customer and by_date each filter the period once.
    (1, 'public.get_all_dispatch_activity(date,date)',
     $b$p_from_date date DEFAULT ((CURRENT_DATE - '7 days'::interval))::date, p_to_date date DEFAULT CURRENT_DATE$b$,
     $a$p_from_date date DEFAULT ((pg_catalog.timezone('Asia/Kolkata', pg_catalog.now()))::date - 7), p_to_date date DEFAULT (pg_catalog.timezone('Asia/Kolkata', pg_catalog.now()))::date$a$, 1),
    (2, 'public.get_all_dispatch_activity(date,date)',
     $b$d.disp_date >= p_from_date$b$, $a$d.disp_date >= warehouse_security.business_day_start(p_from_date)$a$, 3),
    (3, 'public.get_all_dispatch_activity(date,date)',
     $b$d.disp_date < p_to_date + 1$b$, $a$d.disp_date < warehouse_security.business_day_start(p_to_date + 1)$a$, 3),
    -- by_date: the key and the grouping.
    (4, 'public.get_all_dispatch_activity(date,date)',
     $b$d.disp_date::date$b$, $a$warehouse_security.business_date(d.disp_date)$a$, 2),
    (5, 'public.get_all_dispatch_activity(date,date)',
     $b$MAX(d.disp_date)::date$b$, $a$warehouse_security.business_date(MAX(d.disp_date))$a$, 1),

    -- get_all_grn_activity: the same shape.
    (6, 'public.get_all_grn_activity(date,date)',
     $b$p_from_date date DEFAULT ((CURRENT_DATE - '7 days'::interval))::date, p_to_date date DEFAULT CURRENT_DATE$b$,
     $a$p_from_date date DEFAULT ((pg_catalog.timezone('Asia/Kolkata', pg_catalog.now()))::date - 7), p_to_date date DEFAULT (pg_catalog.timezone('Asia/Kolkata', pg_catalog.now()))::date$a$, 1),
    (7, 'public.get_all_grn_activity(date,date)',
     $b$g.date >= p_from_date$b$, $a$g.date >= warehouse_security.business_day_start(p_from_date)$a$, 3),
    (8, 'public.get_all_grn_activity(date,date)',
     $b$g.date < p_to_date + 1$b$, $a$g.date < warehouse_security.business_day_start(p_to_date + 1)$a$, 3),
    (9, 'public.get_all_grn_activity(date,date)',
     $b$g.date::date$b$, $a$warehouse_security.business_date(g.date)$a$, 2),
    (10, 'public.get_all_grn_activity(date,date)',
     $b$MAX(g.date)::date$b$, $a$warehouse_security.business_date(MAX(g.date))$a$, 1),

    -- get_all_customer_activity_summary: receipts twice (counts, last activity), dispatches
    -- twice, invoices once. The leading space keeps `date::date` apart from `disp_date::date`.
    (11, 'public.get_all_customer_activity_summary(date,date)',
     $b$ date::date BETWEEN p_from_date AND p_to_date$b$,
     $a$ date >= warehouse_security.business_day_start(p_from_date) AND date < warehouse_security.business_day_start(p_to_date + 1)$a$, 2),
    (12, 'public.get_all_customer_activity_summary(date,date)',
     $b$disp_date::date BETWEEN p_from_date AND p_to_date$b$,
     $a$disp_date >= warehouse_security.business_day_start(p_from_date) AND disp_date < warehouse_security.business_day_start(p_to_date + 1)$a$, 2),
    (13, 'public.get_all_customer_activity_summary(date,date)',
     $b$inv_date::date BETWEEN p_from_date AND p_to_date$b$,
     $a$inv_date >= warehouse_security.business_day_start(p_from_date) AND inv_date < warehouse_security.business_day_start(p_to_date + 1)$a$, 1),

    -- get_customer_dispatch_activity: summary and list filter the period; the list shows the day.
    (14, 'public.get_customer_dispatch_activity(uuid,date,date)',
     $b$d.disp_date::date >= p_from_date$b$, $a$d.disp_date >= warehouse_security.business_day_start(p_from_date)$a$, 2),
    (15, 'public.get_customer_dispatch_activity(uuid,date,date)',
     $b$d.disp_date::date <= p_to_date$b$, $a$d.disp_date < warehouse_security.business_day_start(p_to_date + 1)$a$, 2),
    (16, 'public.get_customer_dispatch_activity(uuid,date,date)',
     $b$'disp_date', d.disp_date::date,$b$, $a$'disp_date', warehouse_security.business_date(d.disp_date),$a$, 1),

    -- get_customer_grn_activity: the single-customer and the all-customers branch; the two
    -- defaults for a missing day.
    (17, 'public.get_customer_grn_activity(uuid,date,date)',
     $b$gr.date >= v_from_date AND gr.date < v_to_date + 1$b$,
     $a$gr.date >= warehouse_security.business_day_start(v_from_date) AND gr.date < warehouse_security.business_day_start(v_to_date + 1)$a$, 2),
    (18, 'public.get_customer_grn_activity(uuid,date,date)',
     $b$CURRENT_DATE$b$, $a$warehouse_security.business_date(now())$a$, 2),

    -- get_customer_activity_detail.
    -- Stock age: the weighted average and the three bucket bounds plus the reported age.
    (19, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$CURRENT_DATE - gr.date::date$b$, $a$warehouse_security.business_date(now()) - warehouse_security.business_date(gr.date)$a$, 5),
    -- The period: summary and monthly trends, receipts and dispatches twice each.
    (20, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$gr.date::date BETWEEN p_from_date AND p_to_date$b$,
     $a$gr.date >= warehouse_security.business_day_start(p_from_date) AND gr.date < warehouse_security.business_day_start(p_to_date + 1)$a$, 2),
    (21, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$d.disp_date::date BETWEEN p_from_date AND p_to_date$b$,
     $a$d.disp_date >= warehouse_security.business_day_start(p_from_date) AND d.disp_date < warehouse_security.business_day_start(p_to_date + 1)$a$, 2),
    -- Invoices: the paid amount (alias i) once; the invoice amount and its months (no alias),
    -- told apart by the leading space.
    (22, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$i.inv_date::date BETWEEN p_from_date AND p_to_date$b$,
     $a$i.inv_date >= warehouse_security.business_day_start(p_from_date) AND i.inv_date < warehouse_security.business_day_start(p_to_date + 1)$a$, 1),
    (23, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$ inv_date::date BETWEEN p_from_date AND p_to_date$b$,
     $a$ inv_date >= warehouse_security.business_day_start(p_from_date) AND inv_date < warehouse_security.business_day_start(p_to_date + 1)$a$, 2),
    -- Months: the key and the grouping of each monthly list.
    (24, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$DATE_TRUNC('month', gr.date)$b$, $a$DATE_TRUNC('month', warehouse_security.business_date(gr.date)::timestamp)$a$, 2),
    (25, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$DATE_TRUNC('month', d.disp_date)$b$, $a$DATE_TRUNC('month', warehouse_security.business_date(d.disp_date)::timestamp)$a$, 2),
    (26, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$DATE_TRUNC('month', inv_date)$b$, $a$DATE_TRUNC('month', warehouse_security.business_date(inv_date)::timestamp)$a$, 2),
    -- Stock at the end of each month: everything up to the end of the month's last day.
    (27, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$gr.date::date <= (m.month_start + INTERVAL '1 month - 1 day')::date$b$,
     $a$gr.date < warehouse_security.business_day_start((m.month_start + INTERVAL '1 month - 1 day')::date + 1)$a$, 1),
    (28, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$d.disp_date::date <= (m.month_start + INTERVAL '1 month - 1 day')::date$b$,
     $a$d.disp_date < warehouse_security.business_day_start((m.month_start + INTERVAL '1 month - 1 day')::date + 1)$a$, 1),

    -- get_customer_invoice_summary: both branches, the two defaults, by_month in each branch.
    (29, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$i.inv_date >= v_from_date AND i.inv_date < v_to_date + 1$b$,
     $a$i.inv_date >= warehouse_security.business_day_start(v_from_date) AND i.inv_date < warehouse_security.business_day_start(v_to_date + 1)$a$, 2),
    (30, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$CURRENT_DATE$b$, $a$warehouse_security.business_date(now())$a$, 2),
    (31, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$TO_CHAR(invoice_date, 'YYYY-MM')$b$, $a$TO_CHAR(warehouse_security.business_date(invoice_date), 'YYYY-MM')$a$, 2),
    (32, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$TO_CHAR(inv_date, 'YYYY-MM')$b$, $a$TO_CHAR(warehouse_security.business_date(inv_date), 'YYYY-MM')$a$, 2),

    -- get_operations_dashboard: KPIs and trends filter the period for receipts and dispatches
    -- twice each; the leading space keeps `date::date` apart from `disp_date::date`.
    (33, 'public.get_operations_dashboard(date,date)',
     $b$ date::date >= p_from_date$b$, $a$ date >= warehouse_security.business_day_start(p_from_date)$a$, 2),
    (34, 'public.get_operations_dashboard(date,date)',
     $b$ date::date <= p_to_date$b$, $a$ date < warehouse_security.business_day_start(p_to_date + 1)$a$, 2),
    (35, 'public.get_operations_dashboard(date,date)',
     $b$disp_date::date >= p_from_date$b$, $a$disp_date >= warehouse_security.business_day_start(p_from_date)$a$, 2),
    (36, 'public.get_operations_dashboard(date,date)',
     $b$disp_date::date <= p_to_date$b$, $a$disp_date < warehouse_security.business_day_start(p_to_date + 1)$a$, 2),
    -- The daily trend keys and their grouping.
    (37, 'public.get_operations_dashboard(date,date)',
     $b$SELECT date::date AS grn_date$b$, $a$SELECT warehouse_security.business_date(date) AS grn_date$a$, 1),
    (38, 'public.get_operations_dashboard(date,date)',
     $b$GROUP BY date::date$b$, $a$GROUP BY warehouse_security.business_date(date)$a$, 1),
    (39, 'public.get_operations_dashboard(date,date)',
     $b$SELECT disp_date::date AS disp_date$b$, $a$SELECT warehouse_security.business_date(disp_date) AS disp_date$a$, 1),
    (40, 'public.get_operations_dashboard(date,date)',
     $b$GROUP BY disp_date::date$b$, $a$GROUP BY warehouse_security.business_date(disp_date)$a$, 1),

    -- get_grn_list: both ends of the date filter, written into its query text as literals
    -- (a timestamptz literal carries its offset, so it names the same moment in any zone).
    (41, 'public.get_grn_list(date,date,text,text,integer,integer,jsonb)',
     $b$format('gr.date >= %L', p_date_from)$b$, $a$format('gr.date >= %L', warehouse_security.business_day_start(p_date_from))$a$, 1),
    (42, 'public.get_grn_list(date,date,text,text,integer,integer,jsonb)',
     $b$format('gr.date < %L', p_date_to + 1)$b$, $a$format('gr.date < %L', warehouse_security.business_day_start(p_date_to + 1))$a$, 1)
  ) AS changes(step, signature, before_text, after_text, times)
  ORDER BY step
  LOOP
    IF change.signature <> current_fn THEN
      IF current_fn <> '' THEN EXECUTE definition; END IF;
      current_fn := change.signature;
      definition := pg_get_functiondef(current_fn::regprocedure);
    END IF;
    definition := pg_temp.replace_marker(current_fn, definition, change.before_text, change.after_text, change.times);
  END LOOP;
  EXECUTE definition;
END;
$migration$;

DROP FUNCTION pg_temp.replace_marker(text, text, text, text, integer);
NOTIFY pgrst, 'reload schema';
