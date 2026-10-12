-- The invoice amounts in the reports are the invoice's real amount, not a double count.
--
-- An invoice's payable amount is invoice.total. warehouse_security.recalculate_invoice_header
-- (migration 48) stores total = ceil(sum of the line bases + tax_amount - discount), where a line
-- base already holds the labour of the line, tax_amount = ceil(the tax of the lines) and labour is
-- the sum of the lines' labour. Payments, Tally, the invoice PDF and the invoice screens all use
-- total. Three report functions built a "net" figure as
--
--   total + labour + tax_amount - discount
--
-- which adds the labour and the tax a second time and takes the discount off a second time.
-- Worked example: 1 bag, charge 10, labour rate 2.50, tax 5%. Line base 10 + 2.50 = 12.50, tax
-- ceil(12.50 x 5 / 100 = 0.625) = 1, total = ceil(12.50 + 1) = 14. The reports said
-- 14 + 2.50 + 1 = 17.50: 3.50 too much, and the invoice history PDF printed that 17.50 as "Net"
-- next to the right "Amount" of 14. A discount made it worse the other way: it is already inside
-- total, and the sum took it off once more.
--
-- This migration replaces the sum by the invoice's total in every place it was used. Every key
-- keeps its name and its JSON type, so no client breaks; the values go DOWN to the real amounts.
--
--   get_customer_invoice_summary(p_customer_uuid, p_from_date, p_to_date, p_financial_year)
--     one customer:
--       invoices[].net_total       was total + labour + tax_amount - discount, now = total
--       summary.net_amount         was the sum of that, now = summary.total_amount
--       summary.paid_amount        was the sum of that over the invoices with a payment row,
--                                  now the sum of their total
--       summary.pending_amount     the same over the invoices without one; paid + pending now
--                                  equals total_amount
--       by_month[].paid_amount and by_month[].pending_amount: the same, per month
--     all customers:
--       by_customer[].net_amount   was the sum of that per customer, now = total_amount
--       summary.net_amount         now = summary.total_amount
--     unchanged: total_amount (always the sum of total), total_labour, total_tax, total_discount,
--     the counts, invoices[].total, labour, discount and tax_amount, by_month[].total_amount.
--
--   get_customer_activity_detail(p_customer_uuid, p_from_date, p_to_date)
--       summary.total_invoice_amount   was the sum of total + labour + tax_amount - discount of
--                                      the invoices of the period, now the sum of their total
--       monthly_trends[].invoice_amount  the same, per month
--       summary.total_pending_amount   = total_invoice_amount - total_paid_amount, so it follows
--       recent_invoices[].net_total    was the sum for that invoice, now = its total
--     unchanged: summary.total_paid_amount (the sum of the payments of the period's invoices),
--     every other key.
--
--   get_all_customer_activity_summary(p_from_date, p_to_date)
--       summary.total_invoice_amount and customers[].total_invoice_amount: the same change, over
--       all customers and per customer.
--
-- The same function, get_customer_invoice_summary, listed an invoice twice and summed it twice
-- when it had two rows in payments (a part payment and the balance, as Tally writes them): its
-- payment_status set held one row per payment and was joined to the invoices as it was. The set
-- is now one row per invoice, and payment_status keeps its keys (status, paid_date, payment_ref,
-- amount, payment_mode):
--       status        'paid' when the invoice has any payment row, as before (that rule is the
--                     owner's to change, and this migration does not); 'pending' otherwise
--       amount        the sum of the invoice's payment rows (was: the one row's amount)
--       paid_date     the date of the latest payment row (payment_date, then payment_no, latest)
--       payment_ref, payment_mode   of that latest row
-- An invoice with one payment row, or none, is answered as before.
--
-- Nothing else changes: the authorize_rpc guard, SECURITY DEFINER, the search_path, the grants,
-- the India day cuts of migrations 54 and 56, the key sets, and the order of the rows.
-- authorize_rpc is not redefined.
--
-- Method: the current definitions are patched, not rewritten. pg_get_functiondef keeps the guard,
-- SECURITY DEFINER, the search_path, the grants and every other line (including migrations 54
-- and 56); each replaced text must occur exactly as often as stated, or the migration fails and
-- nothing is applied. In get_customer_activity_detail the unprefixed sum (the period and its
-- months, twice) is told from the `i.` one (the recent invoices, once) by the `i.`.

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
  current_fn text := '';
  definition text;
BEGIN
  FOR change IN SELECT * FROM (VALUES
    -- get_customer_invoice_summary: the net figure of the invoice list (one customer) and of
    -- the all-customers invoice set, one each.
    (1, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$(COALESCE(i.total, 0) + COALESCE(i.labour, 0) + COALESCE(i.tax_amount, 0) - COALESCE(i.discount, 0)) as net_total$b$,
     $a$COALESCE(i.total, 0) as net_total$a$, 2),
    -- ... and the payment status, one row per invoice: DISTINCT ON picks the latest payment row
    -- of each invoice (the ORDER BY, last in the query), the window sum is the sum of all the
    -- invoice's rows (windows are evaluated before DISTINCT ON picks the row).
    (2, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$SELECT
                p.invoice_id,$b$,
     $a$SELECT DISTINCT ON (p.invoice_id)
                p.invoice_id,$a$, 1),
    (3, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$'amount', p.amount,$b$,
     $a$'amount', SUM(p.amount) OVER (PARTITION BY p.invoice_id),$a$, 1),
    (4, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$WHERE p.invoice_id IS NOT NULL$b$,
     $a$WHERE p.invoice_id IS NOT NULL
            ORDER BY p.invoice_id, p.payment_date DESC, p.payment_no DESC$a$, 1),

    -- get_customer_activity_detail: the period's invoice amount and its months (no alias, told
    -- apart from the next by the missing `i.`), and the recent invoices' net_total (alias i).
    (5, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$COALESCE(total, 0) + COALESCE(labour, 0) + COALESCE(tax_amount, 0) - COALESCE(discount, 0)$b$,
     $a$COALESCE(total, 0)$a$, 2),
    (6, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$COALESCE(i.total, 0) + COALESCE(i.labour, 0) + COALESCE(i.tax_amount, 0) - COALESCE(i.discount, 0) as net_total$b$,
     $a$COALESCE(i.total, 0) as net_total$a$, 1),

    -- get_all_customer_activity_summary: the invoice total per customer, once.
    (7, 'public.get_all_customer_activity_summary(date,date)',
     $b$COALESCE(total, 0) + COALESCE(labour, 0) + COALESCE(tax_amount, 0) - COALESCE(discount, 0)$b$,
     $a$COALESCE(total, 0)$a$, 1)
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
