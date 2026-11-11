-- Invoicing goods as they leave (migrations 165 and 174, WH-138, WH-162): a GRN may have several invoices, each for dispatch lines that are on no other
-- live invoice, while stock remains. Fictional data; runs only in migrations.sh's disposable, network-disabled database.
-- (The suites that predate the setting run with it off: tests/migrations.sh. This one turns it on, as it is by default on a database that never
-- changed it.)
\set ON_ERROR_STOP on
BEGIN;
-- The one-argument save_invoice(jsonb) is gone (migration 123): the app's save, a header and an array of lines, is used. This takes
-- the header with its lines under 'items' (as the old call did) and adds what the save asks of each line: its lot and a duration of 1.
CREATE FUNCTION pg_temp.save_invoice_doc(doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;
CREATE FUNCTION pg_temp.lv_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'invoice as goods leave: %',label; END IF; END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888881','Leave Demo Administrator') AS admin_user \gset
SELECT public.operator_prepare_otp('9888888881') AS challenge \gset
SELECT pg_temp.lv_assert(:'challenge'::jsonb->>'success'='true','operator challenge prepared');
SELECT public.operator_finish_otp((:'challenge'::jsonb#>>'{data,request_id}')::uuid,true,'mock-provider-only');
SELECT public.operator_verify_otp('9888888881',:'challenge'::jsonb#>>'{data,otp_code}') AS login \gset
SELECT pg_temp.lv_assert(:'login'::jsonb#>>'{data,action}'='login','mocked operator login');
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',:'admin_user',
 'session_id',(SELECT id FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_user'::uuid LIMIT 1))::text,true);
SET LOCAL ROLE authenticated;
SELECT public.create_customer('Leave Demo Customer','9888888882') AS customer \gset
SELECT pg_temp.lv_assert(:'customer'::jsonb->>'success'='true','customer creation');
SELECT public.create_item('Leave Demo Potatoes','Bag') AS item \gset
SELECT pg_temp.lv_assert(:'item'::jsonb->>'success'='true','catalog creation');
SELECT id AS customer_id FROM public.customers WHERE name='Leave Demo Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Leave Demo Potatoes' \gset
SELECT public.replace_item_rates(:'item_id'::uuid,:'customer_id'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5))) AS price \gset
SELECT pg_temp.lv_assert(:'price'::jsonb->>'success'='true','fictional price creation');
SELECT public.save_grn(p_gr_no=>'LEAVA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Leave Demo Customer',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'leave-receipt',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Leave Demo Potatoes',
 'packaging','Bag','qty',100,'weight',10,'rack','DEMO'))) AS grn \gset
SELECT pg_temp.lv_assert(:'grn'::jsonb->>'success'='true','receipt creation');
SELECT id AS grn_id FROM public.goodsreceived WHERE gr_no='LEAVA' \gset
SELECT id AS stock_id FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid \gset
SELECT pg_temp.lv_assert((SELECT stock=100 FROM public.goodsreceived_trl WHERE id=:'stock_id'::uuid),'receipt stock 100');
SELECT jsonb_build_object('disp_no','LEAVA','disp_date','2026-05-02T12:00:00Z','customer_id',:'customer_id',
 'customer_name','Leave Demo Customer','supervisor_id',:'admin_profile','supervisor_name','Leave Demo Administrator') AS dispatch_data \gset
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'stock_id','disp_qty',20)],false,0,'leave-partial') AS dispatch \gset
SELECT pg_temp.lv_assert(:'dispatch'::jsonb->>'success'='true','partial dispatch');
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'stock_id','disp_qty',20)],false,0,'leave-partial') AS retry \gset
SELECT pg_temp.lv_assert(:'retry'::jsonb->>'success'='true','dispatch retry');
SELECT pg_temp.lv_assert((SELECT stock=80 FROM public.goodsreceived_trl WHERE id=:'stock_id'::uuid),'retry leaves 80 bags');
SELECT public.get_customer_stock_summary(:'customer_id'::uuid) AS summary \gset
SELECT pg_temp.lv_assert((:'summary'::jsonb#>>'{summary,total_quantity}')::numeric=80
 AND (:'summary'::jsonb#>>'{summary,total_weight_kg}')::numeric=800,'partial balance 80 bags / 800 kg');
-- The same fixture as tests/core_pilot.sql: 100 bags received on 2026-04-01, 20 dispatched on 2026-05-02, 80 still in store. Rate 5.00 a month, labour 2.00,
-- tax 5 %. Line A (20 bags, 31 days -> 1.5 months): storage 150, labour 40, tax 9.5. Line B (80 bags): storage 600, labour 160, tax 38. One invoice for
-- both is 950 + 48 = 998 (core_pilot pins it).
RESET ROLE;
-- 1. Migration 174 makes on the default of the setting, and turns it on where it was never changed.
SELECT pg_temp.lv_assert((SELECT column_default = 'true' FROM information_schema.columns
  WHERE table_schema = 'warehouse_security' AND table_name = 'charging_rule' AND column_name = 'invoice_as_goods_leave'), 'the column defaults to on (migration 174, WH-162)');
SELECT pg_temp.lv_assert(warehouse_security.invoice_as_goods_leave() IS NOT NULL, 'the setting is readable');
-- Off: the rule of before. A GRN with stock cannot be invoiced.
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = false WHERE id;
SET LOCAL ROLE authenticated;
SELECT pg_temp.lv_assert(public.generate_invoice_data_for_grn_with_pricing(:'grn_id'::uuid)->>'success' = 'false', 'off: a receipt with stock offers no invoice form');
RESET ROLE;
-- On.
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = true WHERE id;
SELECT pg_temp.lv_assert(warehouse_security.grn_invoice_state(:'grn_id'::uuid) = 'not_invoiced', 'on: no live invoice, not invoiced');
SET LOCAL ROLE authenticated;
SELECT public.generate_invoice_data_for_grn_with_pricing(:'grn_id'::uuid) AS form_a \gset
SELECT pg_temp.lv_assert(:'form_a'::jsonb->>'success' = 'true' AND jsonb_array_length(:'form_a'::jsonb->'items') = 1,
  'on: the form of a receipt with stock offers the one dispatch line that has left: ' || :'form_a');
SELECT jsonb_agg(jsonb_build_object('disp_trl_id', t.id, 'charge', 5, 'tax', 5, 'labour_rate', 2)) AS items_a
  FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'LEAVA' \gset
SELECT pg_temp.save_invoice_doc(jsonb_build_object('inv_no', 20270101, 'inv_fin_year', 2026, 'gr_id', :'grn_id', 'gr_no', 'LEAVA',
  'customer_id', :'customer_id', 'customer_name', 'Leave Demo Customer', 'inv_date', '2026-05-02T12:00:00Z', 'total', 0, 'tax_amount', 0, 'discount', 0,
  'duration_mode', 'legacy', 'items', :'items_a'::jsonb)) AS saved_a \gset
SELECT pg_temp.lv_assert(:'saved_a'::jsonb->>'success' = 'true', 'on: the line that has left is invoiced while the rest is in store: ' || :'saved_a');
RESET ROLE;
-- Invoice 1: 190.00 + tax ceil(9.5) = 10 -> 200. The GRN is partly invoiced, and its cached flag is not "invoiced".
SELECT pg_temp.lv_assert((SELECT subtotal_ok FROM (SELECT total = 200 AND tax_amount = 10 AND labour = 40 AS subtotal_ok FROM public.invoice WHERE id = (:'saved_a'::jsonb->>'invoice_id')::uuid) x),
  'invoice 1 is 190.00 + 10 = 200');
SELECT pg_temp.lv_assert(warehouse_security.grn_invoice_state(:'grn_id'::uuid) = 'partly_invoiced'
  AND NOT (SELECT invoiced FROM public.goodsreceived WHERE id = :'grn_id'::uuid), 'on: with stock left the GRN is partly invoiced, the cache is false');
-- A dispatch line sits on one live invoice only.
SET LOCAL ROLE authenticated;
SELECT pg_temp.save_invoice_doc(jsonb_build_object('inv_no', 20270102, 'inv_fin_year', 2026, 'gr_id', :'grn_id', 'gr_no', 'LEAVA',
  'customer_id', :'customer_id', 'customer_name', 'Leave Demo Customer', 'inv_date', '2026-05-02T12:00:00Z', 'total', 0, 'tax_amount', 0, 'discount', 0,
  'duration_mode', 'legacy', 'items', :'items_a'::jsonb)) AS again_a \gset
SELECT pg_temp.lv_assert(:'again_a'::jsonb->>'success' = 'false' AND :'again_a'::jsonb->>'reason' = 'DISPATCH_LINE_INVOICED',
  'on: the same dispatch line cannot be on a second invoice: ' || :'again_a');
-- With nothing free the form is empty.
SELECT public.generate_invoice_data_for_grn_with_pricing(:'grn_id'::uuid) AS form_none \gset
SELECT pg_temp.lv_assert(jsonb_array_length(COALESCE(:'form_none'::jsonb->'items', '[]'::jsonb)) = 0, 'on: nothing free, the form offers no line: ' || :'form_none');
RESET ROLE;
-- The setting cannot go off while a GRN with stock has a live invoice (the owner is not the administrator RPC: set_charging_rule is asked as the service key).
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SET LOCAL ROLE service_role;
SELECT public.set_charging_rule('{"step_days":15,"minimum_days":30,"days_counted":"legacy","rounding":"up","invoice_as_goods_leave":false}') AS off_refused \gset
RESET ROLE;
SELECT pg_temp.lv_assert(:'off_refused'::jsonb->>'success' = 'false' AND :'off_refused'::jsonb->>'reason' = 'PARTIAL_INVOICES_OPEN'
  AND warehouse_security.invoice_as_goods_leave(), 'turning it off is refused while a GRN with stock has a live invoice: ' || :'off_refused');
-- The rest leaves; its dispatch line is the only free one, and the second invoice settles the GRN: 760.00 + 38 = 798; together 998, as one invoice.
SELECT set_config('request.jwt.claims', jsonb_build_object('role', 'authenticated', 'sub', :'admin_user',
 'session_id', (SELECT id FROM warehouse_security.refresh_sessions WHERE user_id = :'admin_user'::uuid LIMIT 1))::text, true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"LEAVB"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id', :'stock_id', 'disp_qty', 80)], false, 0, 'leave-final') AS final_dispatch \gset
SELECT pg_temp.lv_assert(:'final_dispatch'::jsonb->>'success' = 'true', 'final dispatch');
SELECT public.generate_invoice_data_for_grn_with_pricing(:'grn_id'::uuid) AS form_b \gset
SELECT pg_temp.lv_assert(jsonb_array_length(:'form_b'::jsonb->'items') = 1 AND :'form_b'::jsonb#>>'{items,0,dispatches_no}' = 'LEAVB',
  'on: the form offers only the line that is on no invoice: ' || :'form_b');
SELECT jsonb_agg(jsonb_build_object('disp_trl_id', t.id, 'charge', 5, 'tax', 5, 'labour_rate', 2)) AS items_b
  FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'LEAVB' \gset
SELECT pg_temp.save_invoice_doc(jsonb_build_object('inv_no', 20270103, 'inv_fin_year', 2026, 'gr_id', :'grn_id', 'gr_no', 'LEAVA',
  'customer_id', :'customer_id', 'customer_name', 'Leave Demo Customer', 'inv_date', '2026-05-02T12:00:00Z', 'total', 0, 'tax_amount', 0, 'discount', 0,
  'duration_mode', 'legacy', 'items', :'items_b'::jsonb)) AS saved_b \gset
SELECT pg_temp.lv_assert(:'saved_b'::jsonb->>'success' = 'true', 'on: the second invoice for the rest: ' || :'saved_b');
RESET ROLE;
SELECT pg_temp.lv_assert((SELECT total = 798 AND tax_amount = 38 AND labour = 160 FROM public.invoice WHERE id = (:'saved_b'::jsonb->>'invoice_id')::uuid), 'invoice 2 is 760.00 + 38 = 798');
SELECT pg_temp.lv_assert((SELECT sum(total) = 998 FROM public.invoice WHERE gr_id = :'grn_id'::uuid AND deleted_at IS NULL AND cancelled_at IS NULL),
  'the two invoices together are 998, as one invoice is (tests/core_pilot.sql)');
SELECT pg_temp.lv_assert(warehouse_security.grn_invoice_state(:'grn_id'::uuid) = 'invoiced' AND (SELECT invoiced FROM public.goodsreceived WHERE id = :'grn_id'::uuid),
  'on: no stock and every dispatch line on a live invoice, the GRN is invoiced and the cache says so');
-- Cancelling one invoice frees its line: the GRN is partly invoiced again.
SELECT set_config('request.jwt.claims', jsonb_build_object('role', 'authenticated', 'sub', :'admin_user',
 'session_id', (SELECT id FROM warehouse_security.refresh_sessions WHERE user_id = :'admin_user'::uuid LIMIT 1))::text, true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.lv_assert(public.cancel_invoice((:'saved_a'::jsonb->>'invoice_id')::uuid, 'Leave test cleanup', NULL)->>'success' = 'true', 'invoice 1 cancelled');
RESET ROLE;
SELECT pg_temp.lv_assert(warehouse_security.grn_invoice_state(:'grn_id'::uuid) = 'partly_invoiced' AND NOT (SELECT invoiced FROM public.goodsreceived WHERE id = :'grn_id'::uuid),
  'a cancelled invoice frees its dispatch line: the GRN is partly invoiced again');
ROLLBACK;
\echo 'Invoice as goods leave: form, split invoices, one-invoice-per-line, the off refusal and the GRN states passed.'
