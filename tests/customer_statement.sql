-- The customer statement and the dues list (migration 176, WH-155): what a customer owes, worked out by the server from the same pricing path as the
-- invoice form. Fictional data; runs only in migrations.sh's disposable, network-disabled database.
-- Money (the migration header's example B, with dates relative to today so the days are fixed): 10 bags at 12.50 a month, labour 3.00, tax 5 %, received
-- 40 days ago. 4 bags leave 20 days after receipt (1 month, the minimum): storage 50.00 + labour 12.00 = 62.00, tax ceil(3.10) = 4, 66.00. The 6 bags in
-- store, 40 days: 1.5 months, storage 112.50 + labour 18.00 = 130.50, tax ceil(6.525) = 7, ceil(137.50) = 138.00. All 10 in store would be 229.00.
\set ON_ERROR_STOP on
BEGIN;
-- The one-argument save_invoice(jsonb) is gone (migration 123): the app's save, a header and an array of lines, is used. This takes
-- the header with its lines under 'items' (as the old call did) and adds what the save asks of each line: its lot and a duration of 1.
CREATE FUNCTION pg_temp.save_invoice_doc(doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;
CREATE FUNCTION pg_temp.st_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'customer statement: %',label; END IF; END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888851','Statement Demo Administrator') AS admin_user \gset
SELECT public.operator_prepare_otp('9888888851') AS challenge \gset
SELECT pg_temp.st_assert(:'challenge'::jsonb->>'success'='true','operator challenge prepared');
SELECT public.operator_finish_otp((:'challenge'::jsonb#>>'{data,request_id}')::uuid,true,'mock-provider-only');
SELECT public.operator_verify_otp('9888888851',:'challenge'::jsonb#>>'{data,otp_code}') AS login \gset
SELECT pg_temp.st_assert(:'login'::jsonb#>>'{data,action}'='login','mocked operator login');
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',:'admin_user',
 'session_id',(SELECT id FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_user'::uuid LIMIT 1))::text,true);
SET LOCAL ROLE authenticated;
SELECT public.create_customer('Statement Demo Customer','9888888852') AS customer \gset
SELECT pg_temp.st_assert(:'customer'::jsonb->>'success'='true','customer creation');
SELECT public.create_item('Statement Demo Potatoes','Bag') AS item \gset
SELECT pg_temp.st_assert(:'item'::jsonb->>'success'='true','catalog creation');
SELECT id AS customer_id FROM public.customers WHERE name='Statement Demo Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Statement Demo Potatoes' \gset
SELECT public.replace_item_rates(:'item_id'::uuid,:'customer_id'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5))) AS price \gset
SELECT public.replace_item_rates(:'item_id'::uuid, :'customer_id'::uuid, 'monthly', '2026-01-01'::date,
  jsonb_build_array(jsonb_build_object('weight_min', 0, 'weight_max', 100, 'unit_price', 12.50, 'labour_rate', 3, 'tax_percent', 5))) AS price \gset
SELECT pg_temp.st_assert(:'price'::jsonb->>'success' = 'true', 'fictional price creation');
SELECT to_char((now() AT TIME ZONE 'Asia/Kolkata')::date - 40, 'YYYY-MM-DD') || 'T12:00:00Z' AS received_on,
       to_char((now() AT TIME ZONE 'Asia/Kolkata')::date - 20, 'YYYY-MM-DD') || 'T12:00:00Z' AS left_on \gset
SELECT public.save_grn(p_gr_no => 'STMT1', p_date => :'received_on', p_customer_id => :'customer_id'::uuid, p_customer_name => 'Statement Demo Customer',
  p_pricing_mode => 'MONTHLY', p_idempotency_key => 'stmt-receipt',
  p_items => jsonb_build_array(jsonb_build_object('item_id', :'item_id', 'item_name', 'Statement Demo Potatoes', 'packaging', 'Bag', 'qty', 10, 'weight', 10, 'rack', 'DEMO'))) AS grn \gset
SELECT pg_temp.st_assert(:'grn'::jsonb->>'success' = 'true', 'receipt creation: ' || :'grn');
SELECT id AS grn_id FROM public.goodsreceived WHERE gr_no = 'STMT1' \gset
SELECT id AS stock_id FROM public.goodsreceived_trl WHERE gr_id = :'grn_id'::uuid \gset

-- 1. Everything in store: the estimate of the migration header, 229.00, for the 10 bags; nothing has left, nothing is invoiced.
SELECT public.get_customer_statement(:'customer_id'::uuid) AS s0 \gset
SELECT pg_temp.st_assert(:'s0'::jsonb->>'success' = 'true' AND :'s0'::jsonb#>>'{customer,name}' = 'Statement Demo Customer', 'the statement is answered: ' || :'s0');
SELECT pg_temp.st_assert((:'s0'::jsonb#>>'{figures,not_invoiced_in_store}')::numeric = 229.00 AND (:'s0'::jsonb#>>'{figures,not_invoiced_left}')::numeric = 0
  AND (:'s0'::jsonb#>>'{figures,invoices_amount}')::numeric = 0 AND jsonb_array_length(:'s0'::jsonb->'in_store') = 1
  AND (:'s0'::jsonb#>>'{in_store,0,days_in_store}')::int = 40 AND (:'s0'::jsonb#>>'{in_store,0,bags}')::numeric = 10, 'in store: 10 bags, 40 days, 229.00: ' || :'s0');
SELECT pg_temp.st_assert(:'s0'::jsonb->>'invoices_basis' = 'invoiced' AND NOT (:'s0'::jsonb->>'record_payments')::boolean AND (:'s0'::jsonb->>'lots_without_rate')::int = 0, 'payments off: the invoices figure is "invoiced"');

-- 2. 4 bags leave 20 days after receipt: 66.00 has left and is not invoiced; 6 bags (138.00) are in store; the three figures are never added.
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no', 'STMTD1', 'disp_date', :'left_on', 'customer_id', :'customer_id',
   'customer_name', 'Statement Demo Customer', 'supervisor_id', :'admin_profile', 'supervisor_name', 'Statement Demo Administrator'),
 ARRAY[jsonb_build_object('gr_trl_id', :'stock_id', 'disp_qty', 4)], false, 0, 'stmt-left') AS dispatch \gset
SELECT pg_temp.st_assert(:'dispatch'::jsonb->>'success' = 'true', 'dispatch of 4 bags: ' || :'dispatch');
SELECT public.get_customer_statement(:'customer_id'::uuid) AS s1 \gset
SELECT pg_temp.st_assert((:'s1'::jsonb#>>'{figures,not_invoiced_left}')::numeric = 66.00 AND (:'s1'::jsonb#>>'{figures,not_invoiced_in_store}')::numeric = 138.00
  AND (:'s1'::jsonb#>>'{left,0,amount}')::numeric = 66.00 AND (:'s1'::jsonb#>>'{left,0,bags}')::numeric = 4 AND :'s1'::jsonb#>>'{left,0,gr_no}' = 'STMT1'
  AND (:'s1'::jsonb#>>'{in_store,0,bags}')::numeric = 6 AND (:'s1'::jsonb#>>'{in_store,0,amount}')::numeric = 138.00,
  'left 66.00 (4 bags), in store 138.00 (6 bags): ' || :'s1');
-- The dues list carries the same two figures for this customer (administrators and supervisors).
SELECT public.get_customer_dues() AS d1 \gset
SELECT pg_temp.st_assert(:'d1'::jsonb->>'success' = 'true' AND EXISTS (SELECT 1 FROM jsonb_array_elements(:'d1'::jsonb->'customers') c
   WHERE c->>'customer_id' = :'customer_id' AND (c->>'not_invoiced_left')::numeric = 66.00 AND (c->>'not_invoiced_in_store')::numeric = 138.00 AND (c->>'invoices_amount')::numeric = 0),
  'the dues list has the customer with 66.00 left and 138.00 in store: ' || :'d1');

-- 3. Invoiced (invoicing goods as they leave on): the 66.00 moves from "not invoiced" to "invoiced"; with payments off the figure is the invoice's total.
RESET ROLE;
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = true WHERE id;
SET LOCAL ROLE authenticated;
SELECT jsonb_agg(jsonb_build_object('disp_trl_id', t.id, 'charge', 12.5, 'tax', 5, 'labour_rate', 3)) AS items
  FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'STMTD1' \gset
SELECT pg_temp.save_invoice_doc(jsonb_build_object('inv_no', 20270401, 'inv_fin_year', 2026, 'gr_id', :'grn_id', 'gr_no', 'STMT1', 'customer_id', :'customer_id',
  'customer_name', 'Statement Demo Customer', 'inv_date', :'left_on', 'total', 0, 'tax_amount', 0, 'discount', 0, 'duration_mode', 'legacy', 'items', :'items'::jsonb)) AS saved \gset
SELECT pg_temp.st_assert(:'saved'::jsonb->>'success' = 'true', 'the invoice is saved: ' || :'saved');
SELECT public.get_customer_statement(:'customer_id'::uuid) AS s2 \gset
SELECT pg_temp.st_assert((:'s2'::jsonb#>>'{figures,invoices_amount}')::numeric = 66.00 AND (:'s2'::jsonb#>>'{figures,not_invoiced_left}')::numeric = 0
  AND (:'s2'::jsonb#>>'{figures,not_invoiced_in_store}')::numeric = 138.00 AND jsonb_array_length(:'s2'::jsonb->'left') = 0 AND jsonb_array_length(:'s2'::jsonb->'invoices') = 1
  AND (:'s2'::jsonb#>>'{invoices,0,total}')::numeric = 66.00, 'invoiced 66.00, nothing left, 138.00 in store: ' || :'s2');

-- 4. Payments on: the figure is what is due. 16.00 recorded against the invoice of 66.00 leaves 50.00 due.
SELECT public.set_record_payments(true) AS on_answer \gset
SELECT pg_temp.st_assert(:'on_answer'::jsonb->>'success' = 'true', 'payments on');
SELECT public.record_payment((:'saved'::jsonb->>'invoice_id')::uuid, (now() AT TIME ZONE 'Asia/Kolkata')::date - 10, 16.00, 'cash') AS paid \gset
SELECT pg_temp.st_assert(:'paid'::jsonb->>'success' = 'true', 'a payment of 16.00: ' || :'paid');
SELECT public.get_customer_statement(:'customer_id'::uuid) AS s3 \gset
SELECT pg_temp.st_assert(:'s3'::jsonb->>'invoices_basis' = 'due' AND (:'s3'::jsonb#>>'{figures,invoices_amount}')::numeric = 50.00
  AND (:'s3'::jsonb#>>'{invoices,0,paid_amount}')::numeric = 16.00 AND (:'s3'::jsonb#>>'{invoices,0,due_amount}')::numeric = 50.00 AND :'s3'::jsonb#>>'{invoices,0,payment_status}' = 'part_paid'
  AND (:'s3'::jsonb->>'unlinked_paid_amount')::numeric = 0, 'payments on: due 50.00 (part paid 16.00 of 66.00): ' || :'s3');
-- An unknown customer is answered, not raised.
SELECT public.get_customer_statement(gen_random_uuid()) AS unknown \gset
SELECT pg_temp.st_assert(:'unknown'::jsonb->>'success' = 'false' AND :'unknown'::jsonb->>'error' = 'Customer not found', 'an unknown customer: Customer not found');
RESET ROLE;
ROLLBACK;
\echo 'Customer statement: the three figures, the dues list, invoiced and due bases passed.'
