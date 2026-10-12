-- Paid and Pending in the invoice reports follow the money.
--
-- The owner's rule (2026-10-12): "Paid is the money received and Pending is what is still owed. An
-- invoice counts as Paid only when nothing is owed; a part-paid invoice stays Pending with the
-- balance."
--
-- Until now an invoice was "paid" in the reports as soon as ANY row in payments named it, and its
-- whole total was summed as paid, whatever was received (migration 61 kept that rule on purpose:
-- it was the owner's to change). Per invoice, the reports now work out
--
--   received = the sum of the invoice's payments.amount, never below 0 and never above the total
--              (GREATEST(0, LEAST(sum, total)); a missing sum, total or amount counts as 0)
--   balance  = total - received
--   status   = 'paid' when balance <= 0.50, otherwise 'pending'
--
-- 0.50 is the tolerance get_open_invoices_for_customer already uses: an invoice is open when
-- total - paid > 0.50, so a balance of exactly 0.50 is Paid and 0.51 is Pending. An invoice of 0
-- (or less) owes nothing and is Paid with no payment at all.
--
-- Worked example, the invoice of migration 61 (total 14), and four others:
--
--   total  payments        received  balance  status    (it was)
--     14   14.00               14       0      paid      paid
--     14   4.00                 4      10      pending   paid, all 14 counted as paid
--     14   none                 0      14      pending   pending
--     50   60.00 (over-paid)   50       0      paid      paid, 50 counted
--     20   19.50               19.50    0.50   paid      paid
--     20   19.49               19.49    0.51   pending   paid, all 20 counted as paid
--     20   9.00 + 11.00        20       0      paid      paid  (two rows that together pay in full)
--
-- Paid + Pending = the total, for an invoice and for any set of invoices: received + balance =
-- total. A balance of up to 0.50 on an invoice that counts as Paid is still owed, so it is in
-- Pending (20 with 19.50 received: Paid 19.50, Pending 0.50, the invoice listed as 'paid').
--
--   get_customer_invoice_summary(p_customer_uuid, p_from_date, p_to_date, p_financial_year)
--     one customer (the all-customers answer has no paid or pending figure and is not touched):
--       invoices[].payment_status.status   by the rule, 'paid' or 'pending'. Its other keys keep
--                                          their meaning: amount is the sum of the invoice's
--                                          payment rows (not capped), paid_date, payment_ref and
--                                          payment_mode are those of the latest row; a part-paid
--                                          invoice is 'pending' with them, an unpaid one has no
--                                          amount, as before
--       invoices[].paid_amount             NEW, a number: received
--       invoices[].balance_amount          NEW, a number: balance
--       summary.paid_amount                was the total of the invoices with a payment row, now
--                                          the sum of received
--       summary.pending_amount             was the total of the others, now the sum of balances
--       summary.paid_count, pending_count  the invoices whose status is 'paid' / 'pending' by the
--                                          rule (the lines are not edited: they read the status)
--       by_month[].paid_amount and by_month[].pending_amount: the same, per month
--     unchanged: total_invoices, total_amount, total_labour, total_tax, total_discount,
--     net_amount, every other key of an invoice, by_month[].invoice_count and total_amount.
--
--   get_customer_activity_detail(p_customer_uuid, p_from_date, p_to_date)
--       recent_invoices[].status           by the rule (was: 'paid' when any payment row exists)
--       summary.total_pending_amount       was total_invoice_amount - total_paid_amount, now the
--                                          sum of the balances of the period's invoices (never
--                                          below 0: a balance is not negative)
--     unchanged: summary.total_paid_amount (the sum of the payments of the period's invoices, an
--     over-payment included), total_invoice_amount, every other key. So with an over-payment in
--     the period total_paid_amount + total_pending_amount is more than total_invoice_amount; the
--     invoice history above has the capped figures.
--
-- Every key keeps its name and its JSON type; only the two keys of invoices[] are new.
--
-- Nothing else changes: the authorize_rpc guard (not redefined), SECURITY DEFINER, the
-- search_path and jit setting, the grants, the India day cuts of migrations 54, 56 and 61, the
-- key order of the existing keys, the order of the rows and the all-customers branch.
-- get_all_customer_activity_summary has no paid or pending figure and is not touched.
--
-- Method: the current definitions are patched, not rewritten. pg_get_functiondef keeps the guard,
-- SECURITY DEFINER, the search_path, the grants and every other line (including migrations 54, 56
-- and 61); each replaced text must occur exactly as often as stated, or the migration fails and
-- nothing is applied. Steps 1 and 2 add the sum of the payments and, per invoice, two lateral
-- values (received, balance) to the invoice list of one customer; 3 gives the invoice its status
-- by the rule and the two figures; 4 to 6 use them for the months and the summary; 7 and 8 replace
-- nothing: they fail the migration unless the counts of paid and pending invoices still read the
-- status; 9 adds the two keys to the list; 10 to 12 are the activity detail.

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
    -- get_customer_invoice_summary, one customer. The payment_status set has one row per invoice
    -- (migration 61): it also carries the sum of the invoice's payments as a number.
    (1, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$) as status
            FROM payments p$b$,
     $a$) as status,
                SUM(p.amount) OVER (PARTITION BY p.invoice_id) as paid_sum
            FROM payments p$a$, 1),
    -- ... received and balance of each invoice, from that sum and the invoice's total ...
    (2, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$LEFT JOIN payment_status ps ON id.invoice_id = ps.invoice_id$b$,
     $a$LEFT JOIN payment_status ps ON id.invoice_id = ps.invoice_id
            CROSS JOIN LATERAL (SELECT GREATEST(0, LEAST(COALESCE(ps.paid_sum, 0), COALESCE(id.total, 0))) AS received) rcv
            CROSS JOIN LATERAL (SELECT COALESCE(id.total, 0) - rcv.received AS balance) bal$a$, 1),
    -- ... the status of the invoice by the rule (the other keys of the payment status stay), and the
    -- two figures for the months, the summary and the invoice list.
    (3, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$COALESCE(ps.status, jsonb_build_object('status', 'pending', 'paid_date', null, 'payment_ref', null)) as payment_status,$b$,
     $a$jsonb_set(
                    COALESCE(ps.status, jsonb_build_object('status', 'pending', 'paid_date', null, 'payment_ref', null)),
                    '{status}',
                    CASE WHEN bal.balance <= 0.50 THEN to_jsonb('paid'::text) ELSE to_jsonb('pending'::text) END
                ) as payment_status,
                rcv.received as received_amount,
                bal.balance as balance_amount,$a$, 1),
    -- By month: the money received and the balances.
    (4, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$SUM(CASE WHEN (payment_status->>'status') = 'paid' THEN net_total ELSE 0 END) as paid_amount,$b$,
     $a$SUM(received_amount) as paid_amount,$a$, 1),
    (5, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$SUM(CASE WHEN (payment_status->>'status') = 'pending' THEN net_total ELSE 0 END) as pending_amount$b$,
     $a$SUM(balance_amount) as pending_amount$a$, 1),
    -- The summary: the same over all the invoices of the answer.
    (6, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$'paid_amount', COALESCE((SELECT SUM(net_total) FROM invoices_full WHERE (payment_status->>'status') = 'paid'), 0),
                'pending_amount', COALESCE((SELECT SUM(net_total) FROM invoices_full WHERE (payment_status->>'status') = 'pending'), 0)$b$,
     $a$'paid_amount', COALESCE((SELECT SUM(received_amount) FROM invoices_full), 0),
                'pending_amount', COALESCE((SELECT SUM(balance_amount) FROM invoices_full), 0)$a$, 1),
    -- The counts read the status, which is now the rule's. These two entries change nothing; the
    -- migration fails unless each count is still written this way, once.
    (7, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$'paid_count', (SELECT COUNT(*) FROM invoices_full WHERE (payment_status->>'status') = 'paid'),$b$,
     $a$'paid_count', (SELECT COUNT(*) FROM invoices_full WHERE (payment_status->>'status') = 'paid'),$a$, 1),
    (8, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$'pending_count', (SELECT COUNT(*) FROM invoices_full WHERE (payment_status->>'status') = 'pending'),$b$,
     $a$'pending_count', (SELECT COUNT(*) FROM invoices_full WHERE (payment_status->>'status') = 'pending'),$a$, 1),
    -- The two new keys of each invoice of the list.
    (9, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$'payment_status', payment_status,$b$,
     $a$'payment_status', payment_status,
                        'paid_amount', received_amount,
                        'balance_amount', balance_amount,$a$, 1),

    -- get_customer_activity_detail: the pending amount of the period is the sum of the balances of
    -- its invoices (the unprefixed sum of the totals, once: the monthly one is alias invoice_amount) ...
    (10, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$COALESCE(SUM(COALESCE(total, 0)), 0) as total_invoice_amount$b$,
     $a$COALESCE(SUM(COALESCE(total, 0)), 0) as total_invoice_amount,
            COALESCE(SUM(COALESCE(total, 0) - GREATEST(0, LEAST(COALESCE((SELECT SUM(p.amount) FROM payments p WHERE p.invoice_id = invoice.id), 0), COALESCE(total, 0)))), 0) as total_pending_amount$a$, 1),
    (11, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$'total_pending_amount', COALESCE(id.total_invoice_amount, 0) - COALESCE(pd.total_paid_amount, 0),$b$,
     $a$'total_pending_amount', COALESCE(id.total_pending_amount, 0),$a$, 1),
    -- ... and the status of the five recent invoices is the rule's.
    (12, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$CASE WHEN EXISTS (SELECT 1 FROM payments p WHERE p.invoice_id = i.id) THEN 'paid' ELSE 'pending' END as status$b$,
     $a$CASE WHEN COALESCE(i.total, 0) - GREATEST(0, LEAST(COALESCE((SELECT SUM(p.amount) FROM payments p WHERE p.invoice_id = i.id), 0), COALESCE(i.total, 0))) <= 0.50 THEN 'paid' ELSE 'pending' END as status$a$, 1)
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
