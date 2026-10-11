-- Fictional core-pilot regression. Runs only in migrations.sh's disposable,
-- network-disabled database. Uses the existing operator test-session lifecycle.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.core_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'core pilot: %',label; END IF; END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888871','Core Demo Administrator') AS admin_user \gset
SELECT public.operator_prepare_otp('9888888871') AS challenge \gset
SELECT pg_temp.core_assert(:'challenge'::jsonb->>'success'='true','operator challenge prepared');
SELECT public.operator_finish_otp((:'challenge'::jsonb#>>'{data,request_id}')::uuid,true,'mock-provider-only');
SELECT public.operator_verify_otp('9888888871',:'challenge'::jsonb#>>'{data,otp_code}') AS login \gset
SELECT pg_temp.core_assert(:'login'::jsonb#>>'{data,action}'='login','mocked operator login');
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',:'admin_user',
 'session_id',(SELECT id FROM warehouse_security.refresh_sessions WHERE user_id=:'admin_user'::uuid LIMIT 1))::text,true);
SET LOCAL ROLE authenticated;
SELECT public.create_customer('Core Demo Customer A','9888888872') AS customer \gset
SELECT pg_temp.core_assert(:'customer'::jsonb->>'success'='true','customer creation');
SELECT public.create_item('Core Demo Potatoes','Bag') AS item \gset
SELECT pg_temp.core_assert(:'item'::jsonb->>'success'='true','catalog creation');
SELECT id AS customer_id FROM public.customers WHERE name='Core Demo Customer A' \gset
SELECT id AS item_id FROM public.items WHERE name='Core Demo Potatoes' \gset
SELECT public.create_item_storage_price(p_item_id=>:'item_id'::uuid,p_price_type=>'monthly',p_unit_price=>5,
 p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_effective_from=>'2026-01-01',
 p_customer_id=>:'customer_id'::uuid,p_tax_percent=>5) AS price \gset
SELECT pg_temp.core_assert(:'price'::jsonb->>'success'='true','fictional price creation');
SELECT public.save_grn(p_gr_no=>'COREA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Core Demo Customer A',p_pricing_mode=>'MONTHLY',p_idempotency_key=>'core-receipt',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Core Demo Potatoes',
 'packaging','Bag','qty',100,'weight',10,'rack','DEMO'))) AS grn \gset
SELECT pg_temp.core_assert(:'grn'::jsonb->>'success'='true','receipt creation');
SELECT id AS grn_id FROM public.goodsreceived WHERE gr_no='COREA' \gset
SELECT id AS stock_id FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid \gset
SELECT pg_temp.core_assert((SELECT stock=100 FROM public.goodsreceived_trl WHERE id=:'stock_id'::uuid),'receipt stock 100');
SELECT jsonb_build_object('disp_no','COREA','disp_date','2026-05-02T12:00:00Z','customer_id',:'customer_id',
 'customer_name','Core Demo Customer A','supervisor_id',:'admin_profile','supervisor_name','Core Demo Administrator') AS dispatch_data \gset
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'stock_id','disp_qty',20)],false,0,'core-partial') AS dispatch \gset
SELECT pg_temp.core_assert(:'dispatch'::jsonb->>'success'='true','partial dispatch');
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'stock_id','disp_qty',20)],false,0,'core-partial') AS retry \gset
SELECT pg_temp.core_assert(:'retry'::jsonb->>'success'='true','dispatch retry');
SELECT pg_temp.core_assert((SELECT stock=80 FROM public.goodsreceived_trl WHERE id=:'stock_id'::uuid),'retry leaves 80 bags');
SELECT public.get_customer_stock_summary(:'customer_id'::uuid) AS summary \gset
SELECT pg_temp.core_assert((:'summary'::jsonb#>>'{summary,total_quantity}')::numeric=80
 AND (:'summary'::jsonb#>>'{summary,total_weight_kg}')::numeric=800,'partial balance 80 bags / 800 kg');
SELECT pg_temp.core_assert(public.generate_invoice_data_for_grn_with_pricing(:'grn_id'::uuid)->>'success'='false','partial receipt cannot invoice');
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"COREB"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'stock_id','disp_qty',80)],false,0,'core-final') AS final_dispatch \gset
SELECT pg_temp.core_assert(:'final_dispatch'::jsonb->>'success'='true','final dispatch');
SELECT pg_temp.core_assert((SELECT stock=0 FROM public.goodsreceived_trl WHERE id=:'stock_id'::uuid),'final stock zero');
SELECT public.generate_invoice_data_for_grn_with_pricing(p_gr_id=>:'grn_id'::uuid,p_duration_mode=>'legacy') AS preview \gset
SELECT pg_temp.core_assert(:'preview'::jsonb->>'success'='true','invoice preview');
SELECT pg_temp.core_assert(:'preview'::jsonb->'totals'='{"subtotal":950,"tax":48,"total_tax":48,"grand_total":998,"total":998,"total_rows":2}'::jsonb,'fictional totals reconcile');
SELECT pg_temp.core_assert((SELECT jsonb_agg(jsonb_build_object('qty',r->'dispatch_qty','storage',r->'storage_amount',
 'labour',r->'labour_amount','tax',r->'tax_amount','total',r->'total_amount') ORDER BY (r->>'dispatch_qty')::numeric)
 FROM jsonb_array_elements(:'preview'::jsonb->'rows') r)='[{"qty":20,"storage":150,"labour":40,"tax":9.5,"total":199.5},{"qty":80,"storage":600,"labour":160,"tax":38,"total":798}]'::jsonb,'independent line amounts');
SELECT jsonb_agg(jsonb_build_object('disp_trl_id',t.id,'charge',5,'tax',5,'labour_rate',2)) AS invoice_items
 FROM public.dispatch_trl t JOIN public.dispatch d ON d.id=t.disp_id WHERE d.disp_no IN ('COREA','COREB') \gset
SELECT jsonb_build_object('inv_no',20260929,'inv_fin_year',2026,'gr_id',:'grn_id','gr_no','COREA',
 'customer_id',:'customer_id','customer_name','Core Demo Customer A','inv_date','2026-05-02T12:00:00Z',
 'total',998,'tax_amount',48,'discount',0,'duration_mode','legacy','items',:'invoice_items'::jsonb) AS invoice_data \gset
SELECT public.save_invoice(:'invoice_data'::jsonb) AS saved \gset
SELECT pg_temp.core_assert(:'saved'::jsonb->>'success'='true','save invoice');
SELECT pg_temp.core_assert((SELECT total=998 AND tax_amount=48 AND discount=0 AND labour=200 FROM public.invoice WHERE id=(:'saved'::jsonb->>'invoice_id')::uuid),'saved header matches preview');
-- Migration 24: header money is computed from the saved lines for every path;
-- client totals are ignored, the discount is subtracted, tax ceilings once.
-- Migration 41: a receipt is invoiced once, so each further save follows the
-- deletion of the invoice before it.
SELECT pg_temp.core_assert(public.delete_invoice((:'saved'::jsonb->>'invoice_id')::uuid)->>'success'='true','first invoice deleted before the next save');
SELECT public.save_invoice(:'invoice_data'::jsonb || '{"inv_no":20260931,"total":1,"tax_amount":0,"labour":999}'::jsonb) AS tampered \gset
SELECT pg_temp.core_assert(:'tampered'::jsonb->>'success'='true','tampered totals still save: '||COALESCE(:'tampered'::jsonb->>'error',''));
SELECT pg_temp.core_assert((SELECT total=998 AND tax_amount=48 AND labour=200 FROM public.invoice WHERE id=(:'tampered'::jsonb->>'invoice_id')::uuid),'server recomputes tampered header totals');
SELECT pg_temp.core_assert((:'tampered'::jsonb#>>'{totals,total}')::numeric=998 AND (:'tampered'::jsonb#>>'{totals,tax}')::numeric=48,'save returns the computed totals');
SELECT pg_temp.core_assert(public.delete_invoice((:'tampered'::jsonb->>'invoice_id')::uuid)->>'success'='true','second invoice deleted');
SELECT public.save_invoice(:'invoice_data'::jsonb || '{"inv_no":20260932,"discount":10,"total":1}'::jsonb) AS discounted \gset
SELECT pg_temp.core_assert((SELECT total=988 AND discount=10 AND tax_amount=48 FROM public.invoice WHERE id=(:'discounted'::jsonb->>'invoice_id')::uuid),'stored discount reduces the computed total');
SELECT jsonb_agg(jsonb_build_object('disp_trl_id',t.id,'charge',5,'tax',4.5,'labour_rate',2)) AS fractional_items
 FROM public.dispatch_trl t JOIN public.dispatch d ON d.id=t.disp_id WHERE d.disp_no IN ('COREA','COREB') \gset
SELECT pg_temp.core_assert(public.delete_invoice((:'discounted'::jsonb->>'invoice_id')::uuid)->>'success'='true','third invoice deleted');
SELECT public.save_invoice(:'invoice_data'::jsonb || jsonb_build_object('inv_no',20260933,'items',:'fractional_items'::jsonb)) AS fractional \gset
SELECT pg_temp.core_assert((SELECT total=993 AND tax_amount=43 FROM public.invoice WHERE id=(:'fractional'::jsonb->>'invoice_id')::uuid),'fractional tax ceilings once at the header');
SELECT jsonb_agg(jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1.5,'charge',5,'tax',5,'labour_rate',2)) AS typed_items
 FROM public.dispatch_trl t JOIN public.dispatch d ON d.id=t.disp_id WHERE d.disp_no IN ('COREA','COREB') \gset
SELECT jsonb_build_object('inv_no',20260934,'inv_fin_year',2026,'gr_id',:'grn_id','gr_no','COREA','customer_id',:'customer_id',
 'customer_name','Core Demo Customer A','inv_date','2026-05-02T12:00:00Z','total',1,'tax_amount',0,'labour',0,'discount',0,
 'duration_mode','legacy','notes','typed') AS typed_header \gset
SELECT pg_temp.core_assert(public.delete_invoice((:'fractional'::jsonb->>'invoice_id')::uuid)->>'success'='true','fourth invoice deleted');
SELECT public.save_invoice(NULL::uuid,:'typed_header'::jsonb,ARRAY(SELECT jsonb_array_elements(:'typed_items'::jsonb))) AS three_arg \gset
SELECT pg_temp.core_assert(:'three_arg'::jsonb->>'success'='true','three-argument save: '||COALESCE(:'three_arg'::jsonb->>'error','')||' '||COALESCE(:'three_arg'::jsonb->>'validation_errors',''));
SELECT pg_temp.core_assert((SELECT total=998 AND tax_amount=48 AND labour=200 FROM public.invoice WHERE id=(:'three_arg'::jsonb->>'invoice_id')::uuid),'three-argument save recomputes totals');
SELECT public.update_invoice((:'three_arg'::jsonb->>'invoice_id')::uuid,:'typed_header'::jsonb || '{"total":5,"notes":"edited"}'::jsonb,
 ARRAY(SELECT jsonb_array_elements(:'typed_items'::jsonb))) AS edited \gset
SELECT pg_temp.core_assert(:'edited'::jsonb->>'success'='true','invoice edit: '||COALESCE(:'edited'::jsonb->>'error','')||' '||COALESCE(:'edited'::jsonb->>'validation_errors',''));
SELECT pg_temp.core_assert((SELECT total=998 AND tax_amount=48 AND labour=200 AND notes='edited' FROM public.invoice WHERE id=(:'three_arg'::jsonb->>'invoice_id')::uuid),'invoice edit recomputes totals');
SELECT public.update_invoice((:'three_arg'::jsonb->>'invoice_id')::uuid,:'typed_header'::jsonb || '{"notes":"bogus"}'::jsonb,
 ARRAY['{"disp_trl_id":"00000000-0000-4000-8000-000000000000","grn_item_id":"00000000-0000-4000-8000-000000000000","duration":1,"charge":1}'::jsonb]) AS bogus_edit \gset
SELECT pg_temp.core_assert(:'bogus_edit'::jsonb->>'success'='false','bogus edit line denied');
SELECT pg_temp.core_assert((SELECT count(*)=2 FROM public.invoice_trl WHERE invoice_id=(:'three_arg'::jsonb->>'invoice_id')::uuid),'failed edit keeps the lines');
SELECT pg_temp.core_assert((SELECT total=998 AND notes='edited' FROM public.invoice WHERE id=(:'three_arg'::jsonb->>'invoice_id')::uuid),'failed edit keeps the header');
SELECT public.save_invoice(:'invoice_data'::jsonb || '{"inv_no":20260930,"items":[{"disp_trl_id":"00000000-0000-4000-8000-000000000000","charge":1}]}'::jsonb) AS invalid \gset
SELECT pg_temp.core_assert(:'invalid'::jsonb->>'success'='false','invalid dispatch invoice denied');
SELECT pg_temp.core_assert(NOT EXISTS(SELECT 1 FROM public.invoice WHERE inv_no=20260930),'invalid invoice rolls back header');
RESET ROLE;
ROLLBACK;
\echo 'Fictional core pilot receipt, partial/final dispatch, retry, stock and invoice checks passed.'
