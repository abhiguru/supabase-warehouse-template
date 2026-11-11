-- Re-dating an invoice (migration 182, WH-174; migration 184, WH-178): the two documents of a GST pair keep one date inside one financial year,
-- and an invoice date may not move after a payment's day. A pair is made here by linking two invoices of one receipt both ways, as
-- migration 173 stores one. Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.save_invoice_doc(doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;
CREATE FUNCTION pg_temp.update_invoice_doc(p_id uuid, doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.update_invoice(p_id, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;
-- The answer of an edit, or {"raised": message} when the edit raises (an unpaired invoice moved before its dispatch is refused its own way).
CREATE FUNCTION pg_temp.idr_try(p_id uuid, doc jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN RETURN pg_temp.update_invoice_doc(p_id, doc);
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM); END $$;
CREATE FUNCTION pg_temp.idr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'invoice date rules: %',label; END IF; END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888871','Date Rules Administrator') AS admin_user \gset
SELECT public.operator_prepare_otp('9888888871') AS challenge \gset
SELECT pg_temp.idr_assert(:'challenge'::jsonb->>'success'='true','operator challenge prepared');
SELECT public.operator_finish_otp((:'challenge'::jsonb#>>'{data,request_id}')::uuid,true,'mock-provider-only');
SELECT public.operator_verify_otp('9888888871',:'challenge'::jsonb#>>'{data,otp_code}') AS login \gset
SELECT pg_temp.idr_assert(:'login'::jsonb#>>'{data,action}'='login','mocked operator login');
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',:'admin_user',
 'session_id',(SELECT id FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_user'::uuid LIMIT 1))::text,true);
SET LOCAL ROLE authenticated;
SELECT public.create_customer('Date Rules Customer','9888888872') AS customer \gset
SELECT pg_temp.idr_assert(:'customer'::jsonb->>'success'='true','customer creation');
SELECT public.create_item('Date Rules Potatoes','Bag') AS item \gset
SELECT pg_temp.idr_assert(:'item'::jsonb->>'success'='true','catalog creation');
SELECT id AS customer_id FROM public.customers WHERE name='Date Rules Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Date Rules Potatoes' \gset
SELECT public.replace_item_rates(:'item_id'::uuid,:'customer_id'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5))) AS price \gset
SELECT pg_temp.idr_assert(:'price'::jsonb->>'success'='true','fictional price creation');
SELECT public.save_grn(p_gr_no=>'DRA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Date Rules Customer',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'dr-receipt',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Date Rules Potatoes',
 'packaging','Bag','qty',100,'weight',10,'rack','DEMO'))) AS grn \gset
SELECT pg_temp.idr_assert(:'grn'::jsonb->>'success'='true','receipt creation');
SELECT id AS grn_id FROM public.goodsreceived WHERE gr_no='DRA' \gset
SELECT id AS stock_id FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid \gset
SELECT jsonb_build_object('disp_no','DRA','disp_date','2026-05-02T12:00:00Z','customer_id',:'customer_id',
 'customer_name','Date Rules Customer','supervisor_id',:'admin_profile','supervisor_name','Date Rules Administrator') AS dispatch_data \gset
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'stock_id','disp_qty',20)],false,0,'dr-first') AS dispatch \gset
SELECT pg_temp.idr_assert(:'dispatch'::jsonb->>'success'='true','first dispatch');
RESET ROLE;
-- Two invoices of the same GRN, one per dispatch line (invoicing goods as they leave on).
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = true WHERE id;
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"DRB"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id', :'stock_id', 'disp_qty', 80)], false, 0, 'dr-final') AS final_dispatch \gset
SELECT pg_temp.idr_assert(:'final_dispatch'::jsonb->>'success' = 'true', 'final dispatch');
SELECT jsonb_agg(jsonb_build_object('disp_trl_id', t.id, 'charge', 5, 'tax', 5, 'labour_rate', 2)) AS items_a
  FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'DRA' \gset
SELECT jsonb_agg(jsonb_build_object('disp_trl_id', t.id, 'charge', 5, 'tax', 5, 'labour_rate', 2)) AS items_b
  FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'DRB' \gset
SELECT jsonb_build_object('inv_fin_year', 2026, 'gr_id', :'grn_id', 'gr_no', 'DRA', 'customer_id', :'customer_id', 'customer_name', 'Date Rules Customer',
  'inv_date', '2026-05-02T12:00:00Z', 'total', 0, 'tax_amount', 0, 'discount', 0, 'duration_mode', 'legacy') AS base_header \gset
SELECT :'base_header'::jsonb || jsonb_build_object('inv_no', 20270401, 'items', :'items_a'::jsonb) AS header_a \gset
SELECT :'base_header'::jsonb || jsonb_build_object('inv_no', 20270402, 'items', :'items_b'::jsonb) AS header_b \gset
SELECT pg_temp.save_invoice_doc(:'header_a'::jsonb) AS saved_a \gset
SELECT pg_temp.save_invoice_doc(:'header_b'::jsonb) AS saved_b \gset
SELECT pg_temp.idr_assert(:'saved_a'::jsonb->>'success' = 'true' AND :'saved_b'::jsonb->>'success' = 'true', 'both invoices save: ' || :'saved_a' || :'saved_b');
SELECT (:'saved_a'::jsonb->>'invoice_id')::uuid AS inv_a \gset
SELECT (:'saved_b'::jsonb->>'invoice_id')::uuid AS inv_b \gset
RESET ROLE;
-- The pair of migration 173: linked both ways.
UPDATE public.invoice SET linked_invoice_id = :'inv_b'::uuid WHERE id = :'inv_a'::uuid;
UPDATE public.invoice SET linked_invoice_id = :'inv_a'::uuid WHERE id = :'inv_b'::uuid;
SET LOCAL ROLE authenticated;
SELECT public.set_record_payments(true) AS turned_on \gset
SELECT pg_temp.idr_assert(:'turned_on'::jsonb->>'success' = 'true', 'payments on: ' || :'turned_on');
SELECT public.record_payment(:'inv_a'::uuid, DATE '2026-05-05', 10, 'cash') AS pay \gset
SELECT pg_temp.idr_assert(:'pay'::jsonb->>'success' = 'true', 'a payment on the first document: ' || :'pay');
RESET ROLE;

-- WH-178 (on the pair, payment dated 2026-05-05 on the first document).
-- A date before or on the payment's day is accepted, and the other document follows.
SET LOCAL ROLE authenticated;
SELECT pg_temp.update_invoice_doc(:'inv_a'::uuid, :'header_a'::jsonb || '{"inv_date":"2026-05-04T12:00:00Z"}') AS before_pay \gset
RESET ROLE;
SELECT pg_temp.idr_assert(:'before_pay'::jsonb->>'success' = 'true', 'a date before the payment is accepted: ' || :'before_pay');
SELECT pg_temp.idr_assert((SELECT a.inv_date = b.inv_date AND a.inv_date = '2026-05-04T12:00:00Z'::timestamptz
  FROM public.invoice a, public.invoice b WHERE a.id = :'inv_a'::uuid AND b.id = :'inv_b'::uuid), 'WH-174: the other document took the date');
-- After the payment's day: refused, nothing written.
SET LOCAL ROLE authenticated;
SELECT pg_temp.update_invoice_doc(:'inv_a'::uuid, :'header_a'::jsonb || '{"inv_date":"2026-05-06T12:00:00Z"}') AS after_pay \gset
RESET ROLE;
SELECT pg_temp.idr_assert(:'after_pay'::jsonb->>'success' = 'false' AND :'after_pay'::jsonb->>'reason' = 'INVOICE_AFTER_PAYMENT'
  AND :'after_pay'::jsonb->>'date' = '2026-05-05' AND :'after_pay'::jsonb->>'invoice_date' = '2026-05-06'
  AND :'after_pay'::jsonb->>'payment_invoice_id' = :'inv_a' AND :'after_pay'::jsonb->>'error_code' = 'WH409', 'after the payment: INVOICE_AFTER_PAYMENT: ' || :'after_pay');
SELECT pg_temp.idr_assert((SELECT count(*) = 2 FROM public.invoice WHERE id IN (:'inv_a'::uuid, :'inv_b'::uuid) AND inv_date = '2026-05-04T12:00:00Z'::timestamptz),
  'the refusal wrote nothing: both documents keep 2026-05-04');
-- The other document of the pair is refused too, and the answer names the document that holds the payment.
SET LOCAL ROLE authenticated;
SELECT pg_temp.update_invoice_doc(:'inv_b'::uuid, :'header_b'::jsonb || '{"inv_date":"2026-05-07T12:00:00Z"}') AS partner_after \gset
RESET ROLE;
SELECT pg_temp.idr_assert(:'partner_after'::jsonb->>'reason' = 'INVOICE_AFTER_PAYMENT' AND :'partner_after'::jsonb->>'payment_invoice_id' = :'inv_a',
  'the partner is refused, naming the document with the payment: ' || :'partner_after');
-- On the payment's own day is accepted.
SET LOCAL ROLE authenticated;
SELECT pg_temp.update_invoice_doc(:'inv_a'::uuid, :'header_a'::jsonb || '{"inv_date":"2026-05-05T12:00:00Z"}') AS same_day \gset
RESET ROLE;
SELECT pg_temp.idr_assert(:'same_day'::jsonb->>'success' = 'true', 'a date on the payment day is accepted: ' || :'same_day');
-- An invoice already stored after a payment stays editable while its day does not change.
UPDATE public.invoice SET inv_date = '2026-05-08T12:00:00Z' WHERE id IN (:'inv_a'::uuid, :'inv_b'::uuid);
SET LOCAL ROLE authenticated;
SELECT pg_temp.update_invoice_doc(:'inv_a'::uuid, :'header_a'::jsonb || '{"inv_date":"2026-05-08T12:00:00Z","notes":"same day"}') AS kept_day \gset
RESET ROLE;
SELECT pg_temp.idr_assert(:'kept_day'::jsonb->>'success' = 'true', 'the same day with an older payment is not refused: ' || :'kept_day');
-- A payment without a paid_on day (old accounting link rows) never blocks.
UPDATE public.payments SET paid_on = NULL WHERE invoice_id IN (:'inv_a'::uuid, :'inv_b'::uuid);
SET LOCAL ROLE authenticated;
SELECT pg_temp.update_invoice_doc(:'inv_a'::uuid, :'header_a'::jsonb || '{"inv_date":"2026-05-09T12:00:00Z"}') AS null_paid_on \gset
RESET ROLE;
SELECT pg_temp.idr_assert(:'null_paid_on'::jsonb->>'success' = 'true', 'a payment with paid_on NULL does not block: ' || :'null_paid_on');
-- The payment is gone from the picture for the rest: WH-174 on the pair.
DELETE FROM public.payments WHERE invoice_id IN (:'inv_a'::uuid, :'inv_b'::uuid);

-- WH-174: a move within the financial year moves both, numbers stay.
SET LOCAL ROLE authenticated;
SELECT pg_temp.update_invoice_doc(:'inv_b'::uuid, :'header_b'::jsonb || '{"inv_date":"2026-05-12T12:00:00Z"}') AS from_second \gset
RESET ROLE;
SELECT pg_temp.idr_assert(:'from_second'::jsonb->>'success' = 'true', 'editing the second document within the year saves: ' || :'from_second');
SELECT pg_temp.idr_assert((SELECT bool_and(inv_date = '2026-05-12T12:00:00Z'::timestamptz) FROM public.invoice WHERE id IN (:'inv_a'::uuid, :'inv_b'::uuid))
  AND (SELECT inv_no = 20270401 FROM public.invoice WHERE id = :'inv_a'::uuid) AND (SELECT inv_no = 20270402 FROM public.invoice WHERE id = :'inv_b'::uuid),
  'either document moves both, and the numbers stay');
-- Across the financial year: either document is refused, both stay as they were.
SET LOCAL ROLE authenticated;
SELECT pg_temp.update_invoice_doc(:'inv_a'::uuid, :'header_a'::jsonb || '{"inv_date":"2026-03-30T12:00:00Z"}') AS cross_a \gset
SELECT pg_temp.update_invoice_doc(:'inv_b'::uuid, :'header_b'::jsonb || '{"inv_date":"2026-03-30T12:00:00Z"}') AS cross_b \gset
SELECT pg_temp.update_invoice_doc(:'inv_a'::uuid, :'header_a'::jsonb || '{"inv_fin_year":2025}') AS cross_year \gset
RESET ROLE;
SELECT pg_temp.idr_assert(:'cross_a'::jsonb->>'success' = 'false' AND :'cross_a'::jsonb->>'reason' = 'INVOICE_PAIR_OTHER_YEAR' AND :'cross_a'::jsonb->>'error_code' = 'WH409'
  AND :'cross_a'::jsonb->>'first' = '20270401' AND :'cross_a'::jsonb->>'second' = '20270402' AND (:'cross_a'::jsonb->>'fin_year')::int = 2026,
  'a date in the previous financial year is refused for the first document: ' || :'cross_a');
SELECT pg_temp.idr_assert(:'cross_b'::jsonb->>'reason' = 'INVOICE_PAIR_OTHER_YEAR', 'and for the second document: ' || :'cross_b');
SELECT pg_temp.idr_assert(:'cross_year'::jsonb->>'reason' = 'INVOICE_PAIR_OTHER_YEAR' AND (:'cross_year'::jsonb->>'new_fin_year')::int = 2025,
  'a different inv_fin_year is refused too: ' || :'cross_year');
SELECT pg_temp.idr_assert((SELECT bool_and(inv_date = '2026-05-12T12:00:00Z'::timestamptz AND inv_fin_year = 2026) FROM public.invoice WHERE id IN (:'inv_a'::uuid, :'inv_b'::uuid)),
  'the refusals wrote nothing');

-- A cancelled partner is not part of the pair: the live document is edited as an unpaired invoice and the cancelled one keeps its date.
SET LOCAL ROLE authenticated;
SELECT public.cancel_invoice(:'inv_b'::uuid, 'Date rules test', NULL) AS cancelled \gset
SELECT pg_temp.idr_assert(:'cancelled'::jsonb->>'success' = 'true', 'the partner is cancelled: ' || :'cancelled');
SELECT pg_temp.update_invoice_doc(:'inv_a'::uuid, :'header_a'::jsonb || '{"inv_date":"2026-05-14T12:00:00Z"}') AS alone \gset
SELECT pg_temp.idr_try(:'inv_a'::uuid, :'header_a'::jsonb || '{"inv_date":"2026-03-30T12:00:00Z"}') AS alone_cross \gset
RESET ROLE;
SELECT pg_temp.idr_assert(:'alone'::jsonb->>'success' = 'true', 'a document whose partner is cancelled can be re-dated: ' || :'alone');
SELECT pg_temp.idr_assert((SELECT inv_date = '2026-05-12T12:00:00Z'::timestamptz FROM public.invoice WHERE id = :'inv_b'::uuid), 'the cancelled partner keeps its date');
SELECT pg_temp.idr_assert(COALESCE(:'alone_cross'::jsonb->>'reason', '') <> 'INVOICE_PAIR_OTHER_YEAR', 'no pair refusal with a cancelled partner: ' || :'alone_cross');
ROLLBACK;
\echo 'Invoice date rules: the pair keeps one date inside one financial year, and no date after a payment passed.'
