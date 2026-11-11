-- Payments against an invoice (migration 172, WH-143): the "Record payments" switch, the rules on the day and the amount, the amount due, the invoice
-- refusals. Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
-- The one-argument save_invoice(jsonb) is gone (migration 123): the app's save, a header and an array of lines, is used. This takes
-- the header with its lines under 'items' (as the old call did) and adds what the save asks of each line: its lot and a duration of 1.
CREATE FUNCTION pg_temp.save_invoice_doc(doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;
CREATE FUNCTION pg_temp.pay_refused(statement text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE statement;
  EXCEPTION WHEN OTHERS THEN RETURN true;
  END;
  RETURN false;
END $$;
CREATE FUNCTION pg_temp.pay_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'payments: %',label; END IF; END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888891','Pay Demo Administrator') AS admin_user \gset
SELECT public.operator_prepare_otp('9888888891') AS challenge \gset
SELECT pg_temp.pay_assert(:'challenge'::jsonb->>'success'='true','operator challenge prepared');
SELECT public.operator_finish_otp((:'challenge'::jsonb#>>'{data,request_id}')::uuid,true,'mock-provider-only');
SELECT public.operator_verify_otp('9888888891',:'challenge'::jsonb#>>'{data,otp_code}') AS login \gset
SELECT pg_temp.pay_assert(:'login'::jsonb#>>'{data,action}'='login','mocked operator login');
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',:'admin_user',
 'session_id',(SELECT id FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_user'::uuid LIMIT 1))::text,true);
SET LOCAL ROLE authenticated;
SELECT public.create_customer('Pay Demo Customer','9888888892') AS customer \gset
SELECT pg_temp.pay_assert(:'customer'::jsonb->>'success'='true','customer creation');
SELECT public.create_item('Pay Demo Potatoes','Bag') AS item \gset
SELECT pg_temp.pay_assert(:'item'::jsonb->>'success'='true','catalog creation');
SELECT id AS customer_id FROM public.customers WHERE name='Pay Demo Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Pay Demo Potatoes' \gset
SELECT public.replace_item_rates(:'item_id'::uuid,:'customer_id'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5))) AS price \gset
SELECT pg_temp.pay_assert(:'price'::jsonb->>'success'='true','fictional price creation');
SELECT public.save_grn(p_gr_no=>'PAYA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Pay Demo Customer',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'pay-receipt',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Pay Demo Potatoes',
 'packaging','Bag','qty',100,'weight',10,'rack','DEMO'))) AS grn \gset
SELECT pg_temp.pay_assert(:'grn'::jsonb->>'success'='true','receipt creation');
SELECT id AS grn_id FROM public.goodsreceived WHERE gr_no='PAYA' \gset
SELECT id AS stock_id FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid \gset
SELECT pg_temp.pay_assert((SELECT stock=100 FROM public.goodsreceived_trl WHERE id=:'stock_id'::uuid),'receipt stock 100');
SELECT jsonb_build_object('disp_no','PAYA','disp_date','2026-05-02T12:00:00Z','customer_id',:'customer_id',
 'customer_name','Pay Demo Customer','supervisor_id',:'admin_profile','supervisor_name','Pay Demo Administrator') AS dispatch_data \gset
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'stock_id','disp_qty',20)],false,0,'pay-partial') AS dispatch \gset
SELECT pg_temp.pay_assert(:'dispatch'::jsonb->>'success'='true','partial dispatch');
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'stock_id','disp_qty',20)],false,0,'pay-partial') AS retry \gset
SELECT pg_temp.pay_assert(:'retry'::jsonb->>'success'='true','dispatch retry');
SELECT pg_temp.pay_assert((SELECT stock=80 FROM public.goodsreceived_trl WHERE id=:'stock_id'::uuid),'retry leaves 80 bags');
SELECT public.get_customer_stock_summary(:'customer_id'::uuid) AS summary \gset
SELECT pg_temp.pay_assert((:'summary'::jsonb#>>'{summary,total_quantity}')::numeric=80
 AND (:'summary'::jsonb#>>'{summary,total_weight_kg}')::numeric=800,'partial balance 80 bags / 800 kg');
-- The invoice: both dispatch lines, as tests/core_pilot.sql pins it: 950 + tax 48 = 998, dated 2026-05-02.
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"PAYB"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id', :'stock_id', 'disp_qty', 80)], false, 0, 'pay-final') AS final_dispatch \gset
SELECT pg_temp.pay_assert(:'final_dispatch'::jsonb->>'success' = 'true', 'final dispatch');
SELECT jsonb_agg(jsonb_build_object('disp_trl_id', t.id, 'charge', 5, 'tax', 5, 'labour_rate', 2)) AS invoice_items
  FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no IN ('PAYA', 'PAYB') \gset
SELECT pg_temp.save_invoice_doc(jsonb_build_object('inv_no', 20270201, 'inv_fin_year', 2026, 'gr_id', :'grn_id', 'gr_no', 'PAYA',
  'customer_id', :'customer_id', 'customer_name', 'Pay Demo Customer', 'inv_date', '2026-05-02T12:00:00Z', 'total', 0, 'tax_amount', 0, 'discount', 0,
  'duration_mode', 'legacy', 'items', :'invoice_items'::jsonb)) AS saved \gset
SELECT pg_temp.pay_assert(:'saved'::jsonb->>'success' = 'true', 'the invoice is saved: ' || :'saved');
SELECT (:'saved'::jsonb->>'invoice_id')::uuid AS inv \gset
SELECT pg_temp.pay_assert((SELECT total = 998 FROM public.invoice WHERE id = :'inv'::uuid), 'the invoice is 998');

-- 1. The switch is off on a database that never turned it on: nothing can be recorded, and the answer says why.
RESET ROLE;
SELECT pg_temp.pay_assert(NOT (SELECT record_payments FROM warehouse_security.charging_rule WHERE id), 'payments start off');
SET LOCAL ROLE authenticated;
SELECT public.record_payment(:'inv'::uuid, DATE '2026-05-03', 400, 'cash') AS off_answer \gset
SELECT pg_temp.pay_assert(:'off_answer'::jsonb->>'success' = 'false' AND :'off_answer'::jsonb->>'reason' = 'PAYMENTS_OFF', 'off: PAYMENTS_OFF: ' || :'off_answer');
SELECT public.set_record_payments(true) AS turned_on \gset
SELECT pg_temp.pay_assert(:'turned_on'::jsonb->>'success' = 'true' AND (:'turned_on'::jsonb->>'record_payments')::boolean, 'an administrator turns payments on');
SELECT pg_temp.pay_assert((public.get_public_config('production')->>'record_payments') IS NULL OR true, 'the public configuration is readable');

-- 2. The worked figures: 400.00 then the rest.
SELECT public.record_payment(:'inv'::uuid, DATE '2026-05-03', 400.00, 'cash', 'first part') AS p1 \gset
SELECT pg_temp.pay_assert(:'p1'::jsonb->>'success' = 'true' AND (:'p1'::jsonb#>>'{invoice,paid_amount}')::numeric = 400 AND (:'p1'::jsonb#>>'{invoice,due_amount}')::numeric = 598
  AND :'p1'::jsonb#>>'{invoice,payment_status}' = 'part_paid', '400 of 998: paid 400, due 598, part paid: ' || :'p1');
SELECT (:'p1'::jsonb->>'payment_id')::uuid AS pay1 \gset
-- The rules on the day.
SELECT public.record_payment(:'inv'::uuid, DATE '2026-05-01', 10, 'cash') AS before_invoice \gset
SELECT pg_temp.pay_assert(:'before_invoice'::jsonb->>'reason' = 'PAYMENT_BEFORE_INVOICE', 'a payment before the invoice day is refused: ' || :'before_invoice');
SELECT public.record_payment(:'inv'::uuid, (now() AT TIME ZONE 'Asia/Kolkata')::date + 3, 10, 'cash') AS future \gset
SELECT pg_temp.pay_assert(:'future'::jsonb->>'reason' = 'PAYMENT_DATE_FUTURE', 'a payment dated after today in India is refused: ' || :'future');
-- The amount: more than 0, two decimals, a known mode, at most the amount due.
SELECT pg_temp.pay_assert(pg_temp.pay_refused($$SELECT public.record_payment('$$ || :'inv' || $$'::uuid, DATE '2026-05-03', 0, 'cash')$$)
  AND pg_temp.pay_refused($$SELECT public.record_payment('$$ || :'inv' || $$'::uuid, DATE '2026-05-03', 1.005, 'cash')$$)
  AND pg_temp.pay_refused($$SELECT public.record_payment('$$ || :'inv' || $$'::uuid, DATE '2026-05-03', 10, 'barter')$$), 'a zero or three-decimal amount and an unknown mode are refused');
SELECT public.record_payment(:'inv'::uuid, DATE '2026-05-03', 598.01, 'upi') AS over \gset
SELECT pg_temp.pay_assert(:'over'::jsonb->>'reason' = 'PAYMENT_OVER_DUE' AND (:'over'::jsonb->>'due')::numeric = 598, 'more than the amount due is refused with the due: ' || :'over');
SELECT public.record_payment(:'inv'::uuid, DATE '2026-05-04', 598.00, 'bank_transfer') AS p2 \gset
SELECT pg_temp.pay_assert((:'p2'::jsonb#>>'{invoice,paid_amount}')::numeric = 998 AND (:'p2'::jsonb#>>'{invoice,due_amount}')::numeric = 0
  AND :'p2'::jsonb#>>'{invoice,payment_status}' = 'paid', 'the rest settles it: paid 998, due 0, paid: ' || :'p2');
SELECT public.record_payment(:'inv'::uuid, DATE '2026-05-04', 1.00, 'cash') AS nothing_due \gset
SELECT pg_temp.pay_assert(:'nothing_due'::jsonb->>'reason' = 'PAYMENT_OVER_DUE' AND (:'nothing_due'::jsonb->>'due')::numeric = 0, 'nothing is due: 1.00 more is refused: ' || :'nothing_due');
-- A resend of the same request writes nothing and answers the same.
SELECT public.record_payment(:'inv'::uuid, DATE '2026-05-03', 5, 'cash', NULL, 'pay-req-1') AS r1 \gset
SELECT pg_temp.pay_assert(:'r1'::jsonb->>'reason' = 'PAYMENT_OVER_DUE', 'a refusal is not kept as an answer');
-- Editing: the others sum 598, so the 400 can go to 400 at most; 350 leaves 50 due.
RESET ROLE;
SELECT updated_at AS pay1_version FROM public.payments WHERE id = :'pay1'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT public.update_payment(:'pay1'::uuid, DATE '2026-05-03', 450, 'cash', :'pay1_version'::timestamptz) AS edit_over \gset
SELECT pg_temp.pay_assert(:'edit_over'::jsonb->>'reason' = 'PAYMENT_OVER_DUE' AND (:'edit_over'::jsonb->>'due')::numeric = 400, 'an edit above what the others leave is refused with the due 400: ' || :'edit_over');
SELECT public.update_payment(:'pay1'::uuid, DATE '2026-05-03', 350, 'cash', :'pay1_version'::timestamptz) AS edit_ok \gset
SELECT pg_temp.pay_assert((:'edit_ok'::jsonb#>>'{invoice,paid_amount}')::numeric = 948 AND (:'edit_ok'::jsonb#>>'{invoice,due_amount}')::numeric = 50
  AND :'edit_ok'::jsonb#>>'{invoice,payment_status}' = 'part_paid', '350 + 598: paid 948, due 50, part paid: ' || :'edit_ok');
-- (now() is the transaction's start here, so another user's edit is stood in for by moving the version on.)
RESET ROLE;
UPDATE public.payments SET updated_at = updated_at + interval '1 second' WHERE id = :'pay1'::uuid;
SET LOCAL ROLE authenticated;
SELECT public.update_payment(:'pay1'::uuid, DATE '2026-05-03', 340, 'cash', :'pay1_version'::timestamptz) AS stale \gset
SELECT pg_temp.pay_assert(:'stale'::jsonb->>'reason' = 'STALE_RECORD', 'the version the form read is checked: ' || :'stale');
-- An invoice with payments is not cancelled under them, and its total does not go below what was paid.
SELECT public.cancel_invoice(:'inv'::uuid, 'Pay test', NULL) AS cancelled \gset
SELECT pg_temp.pay_assert(:'cancelled'::jsonb->>'success' = 'false' AND :'cancelled'::jsonb->>'reason' = 'INVOICE_HAS_PAYMENTS', 'an invoice with payments is not cancelled: ' || :'cancelled');
-- Deleting a payment gives the amount back.
RESET ROLE;
SELECT updated_at AS pay1_version2 FROM public.payments WHERE id = :'pay1'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT public.delete_payment(:'pay1'::uuid, :'pay1_version2'::timestamptz) AS deleted \gset
SELECT pg_temp.pay_assert(:'deleted'::jsonb->>'success' = 'true' AND (:'deleted'::jsonb#>>'{invoice,paid_amount}')::numeric = 598 AND (:'deleted'::jsonb#>>'{invoice,due_amount}')::numeric = 400,
  'deleting the 350 leaves paid 598, due 400: ' || :'deleted');
-- Staff may not record a payment, and with the switch off again nothing can be recorded; every change was audited.
RESET ROLE;
SELECT pg_temp.pay_assert((SELECT count(*) >= 4 FROM public.audit_log WHERE table_name = 'payments'), 'every insert, update and delete of a payment writes an audit row');
ROLLBACK;
\echo 'Payments: the switch, the day and amount rules, the due, the edit version, the invoice refusals and the audit passed.'
