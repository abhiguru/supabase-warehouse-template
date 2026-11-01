-- Migration 139: integrity for invoices, dispatches and payments (review finding M7), and the base for the `payments` capability.
--
--  * Six foreign keys that the baseline never declared, so that a row can no longer point at a customer, receipt, invoice or user that
--    does not exist: invoice.gr_id -> goodsreceived, invoice.customer_id -> customers, invoice_trl.invoice_id -> invoice,
--    dispatch.customer_id -> customers, payments.customer_id -> customers (all ON DELETE RESTRICT) and payments.supervisor_id ->
--    user_profiles (ON DELETE SET NULL: the payment stays when the person who entered it is removed; supervisor_name keeps the name).
--  * payments.amount must be greater than zero (NULL stays allowed, as before).
--  * The child-side columns of all six keys already have an index in the baseline (idx_invoice_grn, idx_invoice_customer_id,
--    idx_invoice_trl_invoice_id, idx_dispatch_customer_id, idx_payments_customer_id, idx_payments_supervisor_id), so none is built here.
--
-- The delete paths were checked: customers are soft-deleted; delete_invoice and the invoice cancel function delete the lines first;
-- delete_grn_safe (migrations/definitions) now refuses, with a clear answer, a GRN that an invoice refers to.
--
-- Each constraint is added NOT VALID (a short lock) and validated afterwards (no blocking lock). The guard refuses, changing nothing,
-- while a row breaks one of them: the operator decides what to do with those rows.

-- 0. Guard. (GUARD-BEGIN: tests/migrations.sh runs this block.)
-- GUARD-BEGIN
DO $guard$
DECLARE
  c record;
  v_n bigint;
  v_found text[] := '{}';
BEGIN
  FOR c IN SELECT * FROM (VALUES
    ('invoice.gr_id without a goods receipt', 'FROM public.invoice t WHERE t.gr_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.goodsreceived p WHERE p.id = t.gr_id)'),
    ('invoice.customer_id without a customer', 'FROM public.invoice t WHERE t.customer_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.customers p WHERE p.id = t.customer_id)'),
    ('invoice_trl.invoice_id without an invoice', 'FROM public.invoice_trl t WHERE NOT EXISTS (SELECT 1 FROM public.invoice p WHERE p.id = t.invoice_id)'),
    ('dispatch.customer_id without a customer', 'FROM public.dispatch t WHERE t.customer_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.customers p WHERE p.id = t.customer_id)'),
    ('payments.customer_id without a customer', 'FROM public.payments t WHERE t.customer_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.customers p WHERE p.id = t.customer_id)'),
    ('payments.supervisor_id without a user profile', 'FROM public.payments t WHERE t.supervisor_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = t.supervisor_id)'),
    ('payments with an amount of zero or less', 'FROM public.payments t WHERE t.amount <= 0')
  ) AS x(label, from_where) LOOP
    EXECUTE 'SELECT count(*) ' || c.from_where INTO v_n;
    IF v_n > 0 THEN v_found := v_found || format('%s: %s rows (find them: SELECT t.* %s)', c.label, v_n, c.from_where); END IF;
  END LOOP;
  IF cardinality(v_found) > 0 THEN
    RAISE EXCEPTION 'Migration 139 found rows that break the new integrity rules: %. Nothing was changed. Correct or remove these rows (export them first if they matter), then run the migration again.',
      array_to_string(v_found, '; ');
  END IF;
END
$guard$;
-- GUARD-END

-- 1. Foreign keys, added without a long lock and then validated.
ALTER TABLE public.invoice ADD CONSTRAINT invoice_gr_id_fkey FOREIGN KEY (gr_id) REFERENCES public.goodsreceived(id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE public.invoice ADD CONSTRAINT invoice_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE public.invoice_trl ADD CONSTRAINT invoice_trl_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES public.invoice(id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE public.dispatch ADD CONSTRAINT dispatch_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE public.payments ADD CONSTRAINT payments_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE RESTRICT NOT VALID;
ALTER TABLE public.payments ADD CONSTRAINT payments_supervisor_id_fkey FOREIGN KEY (supervisor_id) REFERENCES public.user_profiles(id) ON DELETE SET NULL NOT VALID;
ALTER TABLE public.payments ADD CONSTRAINT payments_amount_positive CHECK (amount > 0) NOT VALID;

ALTER TABLE public.invoice VALIDATE CONSTRAINT invoice_gr_id_fkey;
ALTER TABLE public.invoice VALIDATE CONSTRAINT invoice_customer_id_fkey;
ALTER TABLE public.invoice_trl VALIDATE CONSTRAINT invoice_trl_invoice_id_fkey;
ALTER TABLE public.dispatch VALIDATE CONSTRAINT dispatch_customer_id_fkey;
ALTER TABLE public.payments VALIDATE CONSTRAINT payments_customer_id_fkey;
ALTER TABLE public.payments VALIDATE CONSTRAINT payments_supervisor_id_fkey;
ALTER TABLE public.payments VALIDATE CONSTRAINT payments_amount_positive;

NOTIFY pgrst, 'reload schema';
