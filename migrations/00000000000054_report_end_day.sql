-- Report periods include their last day.
--
-- The report RPCs take a period as two calendar days, p_from_date and
-- p_to_date (type date). Four of them compared the end day directly with a
-- timestamptz column: `col <= p_to_date` or `col BETWEEN v_from_date AND
-- v_to_date`. A date compared with a timestamptz is read as midnight at the
-- START of that day, so every receipt, dispatch or invoice on the last day of
-- the period was left out, except a row stored exactly at midnight (the
-- dispatch RPC the app uses stores a dispatch at the start of its date, so
-- those were counted; receipts and invoices keep their time). The app always
-- asks for a period that ends today, so today's activity was missing from
-- these reports:
--
--   get_all_dispatch_activity      summary, by_customer, by_date
--   get_all_grn_activity           summary, by_customer, by_date
--   get_customer_grn_activity      single customer (grns) and all customers
--   get_customer_invoice_summary   single customer (invoices) and all customers
--
-- The end of the period is now `col < p_to_date + 1`: before the start of the
-- day after the last day, so the whole last day is in. This is the same set of
-- rows as `col::date <= p_to_date`, the form the other four report RPCs that
-- take a period already use (get_all_customer_activity_summary,
-- get_customer_activity_detail, get_customer_dispatch_activity,
-- get_operations_dashboard), but it compares the column itself, so the
-- indexes on goodsreceived.date, dispatch.disp_date and invoice.inv_date stay
-- usable. The start of the period (`col >= p_from_date`) was already right and
-- is not changed.
--
-- Time zone: not changed here. A day in these RPCs, both ends of the period
-- and the by_date grouping, is a day in the database session's time zone,
-- which is UTC on this image, not in India where the facilities keep their
-- books. That is a separate question (warehouse_security.business_date,
-- migration 41, is the place an India day is defined) and is left as it was;
-- this migration only stops the last day from being dropped.
--
-- Method: the current definitions are patched, not rewritten.
-- pg_get_functiondef keeps the authorize_rpc guard, SECURITY DEFINER, the
-- search_path, the grants and every other line of each body (including the
-- migration 52 ordering); each replaced comparison must occur exactly as often
-- as stated, or the migration fails.

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
    -- summary, by_customer and by_date each compare the end day once.
    ('public.get_all_dispatch_activity(date,date)',
     $b$d.disp_date <= p_to_date$b$, $a$d.disp_date < p_to_date + 1$a$, 3),
    ('public.get_all_grn_activity(date,date)',
     $b$g.date <= p_to_date$b$, $a$g.date < p_to_date + 1$a$, 3),
    -- The single-customer and the all-customers branch, once each.
    ('public.get_customer_grn_activity(uuid,date,date)',
     $b$gr.date BETWEEN v_from_date AND v_to_date$b$, $a$gr.date >= v_from_date AND gr.date < v_to_date + 1$a$, 2),
    ('public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$i.inv_date BETWEEN v_from_date AND v_to_date$b$, $a$i.inv_date >= v_from_date AND i.inv_date < v_to_date + 1$a$, 2)
  ) AS changes(signature, before_text, after_text, times)
  LOOP
    EXECUTE pg_temp.replace_marker(change.signature, pg_get_functiondef(change.signature::regprocedure),
      change.before_text, change.after_text, change.times);
  END LOOP;
END;
$migration$;

DROP FUNCTION pg_temp.replace_marker(text, text, text, text, integer);
NOTIFY pgrst, 'reload schema';
