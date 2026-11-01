-- Migration 139: foreign keys on invoice, invoice_trl, dispatch and payments, and payments.amount > 0.
--   A. each key exists with the right delete rule and is validated; the amount rule exists and is validated
--   B. a row that points at nothing is refused; amounts of 0 and -1 are refused, a positive amount and NULL are accepted
--   C. deleting a user profile that a payment names sets payments.supervisor_id to NULL (the payment stays)
--   D. delete_grn_safe refuses, with its own answer, a GRN that an invoice refers to (cancelled or not); delete_invoice refuses (INVOICE_CANCEL_ONLY)
--   E. a customer, a GRN or an invoice that is still referenced cannot be hard-deleted
-- (The guard of the migration is run against a database with bad rows by tests/migrations.sh.)
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.p9_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'payments integrity 139: %',label; END IF; END $$;
-- The SQLSTATE a statement raises ('none' when it raises nothing), run in a subtransaction so that a refusal does not end the test.
CREATE FUNCTION pg_temp.p9_state(statement text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement; RETURN 'none';
  EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE; END;
END $$;
CREATE FUNCTION pg_temp.p9_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.p9_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.p9_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;

-- ===========================================================================
-- A. The constraints exist, are validated, and have the right delete rule
-- ===========================================================================
SELECT pg_temp.p9_assert((SELECT count(*) FROM pg_constraint c WHERE c.contype='f' AND c.convalidated AND (c.conrelid::regclass::text, c.conname, c.confrelid::regclass::text, c.confdeltype) IN (
  ('invoice','invoice_gr_id_fkey','goodsreceived','r'),
  ('invoice','invoice_customer_id_fkey','customers','r'),
  ('invoice_trl','invoice_trl_invoice_id_fkey','invoice','r'),
  ('dispatch','dispatch_customer_id_fkey','customers','r'),
  ('payments','payments_customer_id_fkey','customers','r'),
  ('payments','payments_supervisor_id_fkey','user_profiles','n'))) = 6, 'six validated foreign keys with RESTRICT (SET NULL for the supervisor)');
SELECT pg_temp.p9_assert((SELECT count(*) FROM pg_constraint c WHERE c.contype='c' AND c.convalidated AND c.conrelid='public.payments'::regclass AND c.conname='payments_amount_positive'
  AND pg_get_constraintdef(c.oid) LIKE 'CHECK ((amount > (0)%') = 1, 'payments_amount_positive is a validated CHECK (amount > 0)');

-- ===========================================================================
-- Fixtures (inserted as the owner)
-- ===========================================================================
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9555555901','Pay139 Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT pg_temp.p9_login('9555555901') AS admin_claims \gset
INSERT INTO public.customers(name) VALUES ('Pay139 Customer') RETURNING id AS cust \gset
INSERT INTO public.goodsreceived(gr_no, customer_id, date) VALUES ('P139', :'cust'::uuid, now()) RETURNING id AS grn \gset
INSERT INTO public.goodsreceived(gr_no, customer_id, date) VALUES ('P139B', :'cust'::uuid, now()) RETURNING id AS grn_b \gset
INSERT INTO public.invoice(inv_fin_year, inv_no, gr_id, gr_no, customer_id, inv_date) VALUES (2026, 139001, :'grn'::uuid, 'P139', :'cust'::uuid, now()) RETURNING id AS inv \gset

-- ===========================================================================
-- B. Rows that point at nothing, and amounts that are not positive, are refused
-- ===========================================================================
SELECT pg_temp.p9_assert(pg_temp.p9_state(format($q$INSERT INTO public.invoice(inv_fin_year, inv_no, gr_id, gr_no, customer_id, inv_date) VALUES (2026, 139002, gen_random_uuid(), 'X', %L, now())$q$, :'cust')) = '23503', 'invoice with a missing GRN is refused');
SELECT pg_temp.p9_assert(pg_temp.p9_state(format($q$INSERT INTO public.invoice(inv_fin_year, inv_no, gr_id, gr_no, customer_id, inv_date) VALUES (2026, 139003, %L, 'P139', gen_random_uuid(), now())$q$, :'grn')) = '23503', 'invoice with a missing customer is refused');
SELECT pg_temp.p9_assert(pg_temp.p9_state($q$INSERT INTO public.invoice_trl(invoice_id, disp_trl_id) VALUES (gen_random_uuid(), gen_random_uuid())$q$) IN ('23503'), 'invoice line with a missing invoice is refused');
SELECT pg_temp.p9_assert(pg_temp.p9_state(format($q$INSERT INTO public.dispatch(disp_no, customer_id) VALUES ('D139', gen_random_uuid())$q$)) = '23503', 'dispatch with a missing customer is refused');
SELECT pg_temp.p9_assert(pg_temp.p9_state($q$INSERT INTO public.payments(payment_no, payment_date, customer_id, amount) VALUES ('PY1', now(), gen_random_uuid(), 10)$q$) = '23503', 'payment with a missing customer is refused');
SELECT pg_temp.p9_assert(pg_temp.p9_state($q$INSERT INTO public.payments(payment_no, payment_date, supervisor_id, amount) VALUES ('PY2', now(), gen_random_uuid(), 10)$q$) = '23503', 'payment with a missing supervisor is refused');
SELECT pg_temp.p9_assert(pg_temp.p9_state(format($q$INSERT INTO public.payments(payment_no, payment_date, customer_id, amount) VALUES ('PY3', now(), %L, 0)$q$, :'cust')) = '23514', 'payment of 0 is refused');
SELECT pg_temp.p9_assert(pg_temp.p9_state(format($q$INSERT INTO public.payments(payment_no, payment_date, customer_id, amount) VALUES ('PY4', now(), %L, -1)$q$, :'cust')) = '23514', 'payment of -1 is refused');
SELECT pg_temp.p9_assert(pg_temp.p9_state(format($q$INSERT INTO public.payments(payment_no, payment_date, customer_id, amount) VALUES ('PY5', now(), %L, 0.01)$q$, :'cust')) = 'none', 'payment of 0.01 is accepted');
SELECT pg_temp.p9_assert(pg_temp.p9_state(format($q$INSERT INTO public.payments(payment_no, payment_date, customer_id) VALUES ('PY6', now(), %L)$q$, :'cust')) = 'none', 'a payment without an amount (NULL) is still accepted');
SELECT pg_temp.p9_assert(pg_temp.p9_state(format($q$UPDATE public.payments SET amount = 0 WHERE payment_no = 'PY5'$q$)) = '23514', 'an update to 0 is refused');

-- ===========================================================================
-- C. Deleting a user profile that a payment names keeps the payment and clears supervisor_id
-- ===========================================================================
INSERT INTO public.user_profiles(auth_user_id, name, mobile, role, active) VALUES (gen_random_uuid(), 'Pay139 Supervisor', warehouse_security.normalize_phone('9555555902'), 'supervisor', true) RETURNING id AS sup \gset
INSERT INTO public.payments(payment_no, payment_date, customer_id, supervisor_id, supervisor_name, amount, invoice_id) VALUES ('PY7', now(), :'cust'::uuid, :'sup'::uuid, 'Pay139 Supervisor', 5, :'inv'::uuid);
DELETE FROM public.user_profiles WHERE id = :'sup'::uuid;
SELECT pg_temp.p9_assert((SELECT count(*) FROM public.payments WHERE payment_no='PY7' AND supervisor_id IS NULL AND supervisor_name='Pay139 Supervisor') = 1, 'the payment stays with supervisor_id NULL');

-- ===========================================================================
-- D. Delete paths
-- ===========================================================================
-- delete_grn_safe: an invoice refers to the GRN (no dispatch line): refused with its own answer, nothing deleted.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_grn_safe(:'grn'::uuid) AS r_blocked \gset
RESET ROLE;
SELECT pg_temp.p9_assert(:'r_blocked'::jsonb->>'success'='false' AND :'r_blocked'::jsonb->>'error' LIKE '%it has an invoice (cancelled invoices included); an invoiced GRN is kept.', 'delete_grn_safe names the invoice: '||:'r_blocked');
SELECT pg_temp.p9_assert(EXISTS (SELECT 1 FROM public.goodsreceived WHERE id=:'grn'::uuid), 'the GRN is still there');
-- A GRN without an invoice is still deleted.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_grn_safe(:'grn_b'::uuid) AS r_ok \gset
RESET ROLE;
SELECT pg_temp.p9_assert(:'r_ok'::jsonb->>'success'='true' AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE id=:'grn_b'::uuid), 'a GRN with no invoice is deleted: '||:'r_ok');

-- E. Hard deletes of referenced rows are refused.
SELECT pg_temp.p9_assert(pg_temp.p9_state(format('DELETE FROM public.goodsreceived WHERE id = %L', :'grn')) = '23001', 'a GRN with an invoice cannot be hard-deleted');
-- A customer that only a payment (or only a dispatch) refers to: no other key stands in the way, so the new RESTRICT key is the one that refuses.
INSERT INTO public.customers(name) VALUES ('Pay139 Customer P') RETURNING id AS cust_p \gset
INSERT INTO public.customers(name) VALUES ('Pay139 Customer D') RETURNING id AS cust_d \gset
INSERT INTO public.payments(payment_no, payment_date, customer_id, amount) VALUES ('PY8', now(), :'cust_p'::uuid, 7);
INSERT INTO public.dispatch(disp_no, customer_id) VALUES ('D139B', :'cust_d'::uuid);
SELECT pg_temp.p9_assert(pg_temp.p9_state(format('DELETE FROM public.customers WHERE id = %L', :'cust_p')) = '23001', 'a customer with a payment cannot be hard-deleted');
SELECT pg_temp.p9_assert(pg_temp.p9_state(format('DELETE FROM public.customers WHERE id = %L', :'cust_d')) = '23001', 'a customer with a dispatch cannot be hard-deleted');

-- An invoice that has a line cannot be hard-deleted.
INSERT INTO public.dispatch(disp_no, customer_id) VALUES ('D139', :'cust'::uuid) RETURNING id AS disp \gset
INSERT INTO public.dispatch_trl(gr_id, disp_id) VALUES (:'grn'::uuid, :'disp'::uuid) RETURNING id AS dtrl \gset
INSERT INTO public.invoice_trl(invoice_id, disp_trl_id) VALUES (:'inv'::uuid, :'dtrl'::uuid);
SELECT pg_temp.p9_assert(pg_temp.p9_state(format('DELETE FROM public.invoice WHERE id = %L', :'inv')) = '23001', 'an invoice with a line cannot be hard-deleted');
-- delete_invoice refuses and deletes nothing; a cancelled invoice still blocks the GRN's deletion.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_invoice(:'inv'::uuid) AS r_del \gset
RESET ROLE;
SELECT pg_temp.p9_assert(:'r_del'::jsonb->>'success'='false' AND :'r_del'::jsonb->>'reason'='INVOICE_CANCEL_ONLY'
  AND EXISTS (SELECT 1 FROM public.invoice WHERE id=:'inv'::uuid) AND EXISTS (SELECT 1 FROM public.invoice_trl WHERE invoice_id=:'inv'::uuid), 'delete_invoice refuses and deletes nothing: '||:'r_del');
-- A GRN whose only invoice is cancelled is kept as well.
INSERT INTO public.goodsreceived(gr_no, customer_id, date) VALUES ('P139C', :'cust'::uuid, now()) RETURNING id AS grn_c \gset
INSERT INTO public.invoice(inv_fin_year, inv_no, gr_id, gr_no, customer_id, inv_date, cancelled_at, cancelled_by, cancel_reason)
  VALUES (2026, 139004, :'grn_c'::uuid, 'P139C', :'cust'::uuid, now(), now(), :'admin_profile'::uuid, 'Pay139 test');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_grn_safe(:'grn_c'::uuid) AS r_cancelled \gset
RESET ROLE;
SELECT pg_temp.p9_assert(:'r_cancelled'::jsonb->>'success'='false' AND :'r_cancelled'::jsonb->>'error' LIKE '%cancelled invoices included%' AND EXISTS (SELECT 1 FROM public.goodsreceived WHERE id=:'grn_c'::uuid), 'a GRN with a cancelled invoice is kept: '||:'r_cancelled');
ROLLBACK;
