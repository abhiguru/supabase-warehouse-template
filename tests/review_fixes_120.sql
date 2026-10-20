-- Migration 120 (review fixes 2026-10-20): the new behaviour that no older test covers, each case with a refusal or a failure
-- and its allowed twin.
--  1. A saved create answer is replayed only while the dispatch / GRN it made exists (cache guard after delete).
--  2. Request codes (request_key) on dispatch edit and invoice save: a repeat returns the stored answer and writes nothing;
--     get_submission_result answers the calling user's own saved success only, and only while the record exists.
--  3. NUMBER_TAKEN: the named refusal of dispatch create, dispatch edit, invoice save and invoice edit.
--  4. An empty dispatch line list is refused (NULL keeps the lines).
--  5. D20: a cancelled (soft-deleted) invoice keeps its lines and amounts when its dispatch line goes; the link is emptied.
--  6. order_lines_left on a dispatch made from an order.
--  7. A cart line that does not exist is answered "Order item not found"; one that exists is still checked against its customer.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.rf_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'review fixes 120: %',label; END IF; END $$;
-- The answer of a statement as text, or 'raised: <state> <message>'.
CREATE FUNCTION pg_temp.rf_call(statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer text;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN 'raised: ' || SQLSTATE || ' ' || SQLERRM; END;
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.rf_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.rf_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.rf_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888901','Fix Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888902','Fix Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888903','Fix Customer Login','customer',true,'approved');
SELECT pg_temp.rf_login('9888888901') AS admin_claims \gset
SELECT pg_temp.rf_login('9888888902') AS staff_claims \gset
SELECT pg_temp.rf_login('9888888903') AS customer_claims \gset

-- Fixture, as the administrator: customer A and customer B (the customer login owns neither), two items, and receipts
--   FXA  A  Potatoes 100 bags (lot a1), Onions 60 bags (lot a2)   the dispatches and the order
--   FXI  A  Potatoes 10 (lot i1), Onions 10 (lot i2)               fully dispatched on FXDI, invoiced
--   FXK  A  Onions 3 (lot k1)                                      fully dispatched on FXDK, invoiced
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rf_assert(public.create_customer('Fix Customer A','9888888904')->>'success'='true','customer A');
SELECT pg_temp.rf_assert(public.create_customer('Fix Customer B','9888888905')->>'success'='true','customer B');
SELECT pg_temp.rf_assert(public.create_item('Fix Potatoes','Bag')->>'success'='true','item potatoes');
SELECT pg_temp.rf_assert(public.create_item('Fix Onions','Bag')->>'success'='true','item onions');
SELECT id AS customer_a FROM public.customers WHERE name='Fix Customer A' \gset
SELECT id AS customer_b FROM public.customers WHERE name='Fix Customer B' \gset
SELECT id AS potatoes FROM public.items WHERE name='Fix Potatoes' \gset
SELECT id AS onions FROM public.items WHERE name='Fix Onions' \gset
CREATE FUNCTION pg_temp.rf_line(item uuid, name text, qty integer, mark text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('item_id',item,'item_name',name,'packaging','Bag','qty',qty,'weight',10,'rack','R1','package_mark',mark) $$;
SELECT pg_temp.rf_assert(public.save_grn(p_gr_no=>'FXA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_a'::uuid,
 p_customer_name=>'Fix Customer A',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(pg_temp.rf_line(:'potatoes','Fix Potatoes',100,'FXA-P'),pg_temp.rf_line(:'onions','Fix Onions',60,'FXA-O')))->>'success'='true','receipt FXA');
SELECT pg_temp.rf_assert(public.save_grn(p_gr_no=>'FXI',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_a'::uuid,
 p_customer_name=>'Fix Customer A',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(pg_temp.rf_line(:'potatoes','Fix Potatoes',10,'FXI-P'),pg_temp.rf_line(:'onions','Fix Onions',10,'FXI-O')))->>'success'='true','receipt FXI');
SELECT pg_temp.rf_assert(public.save_grn(p_gr_no=>'FXK',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_a'::uuid,
 p_customer_name=>'Fix Customer A',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(pg_temp.rf_line(:'onions','Fix Onions',3,'FXK-O')))->>'success'='true','receipt FXK');
RESET ROLE;
SELECT id AS grn_a FROM public.goodsreceived WHERE gr_no='FXA' \gset
SELECT id AS grn_i FROM public.goodsreceived WHERE gr_no='FXI' \gset
SELECT id AS grn_k FROM public.goodsreceived WHERE gr_no='FXK' \gset
SELECT id AS lot_a1 FROM public.goodsreceived_trl WHERE gr_id=:'grn_a'::uuid AND package_mark='FXA-P' \gset
SELECT id AS lot_a2 FROM public.goodsreceived_trl WHERE gr_id=:'grn_a'::uuid AND package_mark='FXA-O' \gset
SELECT id AS lot_i1 FROM public.goodsreceived_trl WHERE gr_id=:'grn_i'::uuid AND package_mark='FXI-P' \gset
SELECT id AS lot_i2 FROM public.goodsreceived_trl WHERE gr_id=:'grn_i'::uuid AND package_mark='FXI-O' \gset
SELECT id AS lot_k1 FROM public.goodsreceived_trl WHERE gr_id=:'grn_k'::uuid \gset
SELECT jsonb_build_object('disp_date','2026-05-02T12:00:00Z','customer_id',:'customer_a','customer_name','Fix Customer A',
 'supervisor_id',:'admin_profile','supervisor_name','Fix Administrator') AS for_a \gset

-- ---------------------------------------------------------------------------
-- 1. Cache guard: a saved create answer is replayed only while what it made exists
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || '{"disp_no":"FXD1"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a1','disp_qty',5)],0,'fx-cache-key') AS first_create \gset
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || '{"disp_no":"FXD1"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a1','disp_qty',5)],0,'fx-cache-key') AS replay \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'first_create'::jsonb->>'success'='true' AND :'replay'::jsonb->>'from_cache'='true'
 AND :'replay'::jsonb->>'dispatch_id'=:'first_create'::jsonb->>'dispatch_id'
 AND (SELECT count(*)=1 FROM public.dispatch WHERE disp_no='FXD1') AND (SELECT stock=95 FROM public.goodsreceived_trl WHERE id=:'lot_a1'::uuid),
 'twin: while the dispatch exists the same key answers from the saved answer and takes no stock twice: '||:'replay');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup((:'first_create'::jsonb->>'dispatch_id')::uuid,:'admin_profile'::uuid) AS deleted \gset
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || '{"disp_no":"FXD1"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a1','disp_qty',5)],0,'fx-cache-key') AS after_delete \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'deleted'::jsonb->>'success'='true' AND :'after_delete'::jsonb->>'success'='true'
 AND NOT (:'after_delete'::jsonb ? 'from_cache')
 AND :'after_delete'::jsonb->>'dispatch_id' IS DISTINCT FROM :'first_create'::jsonb->>'dispatch_id'
 AND (SELECT count(*)=1 FROM public.dispatch WHERE disp_no='FXD1' AND deleted_at IS NULL AND id=(:'after_delete'::jsonb->>'dispatch_id')::uuid)
 AND (SELECT stock=95 FROM public.goodsreceived_trl WHERE id=:'lot_a1'::uuid),
 'after the dispatch was deleted the same key makes a new dispatch and does not return the dead one: '||:'after_delete');
-- The same for a receipt.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'FXG1',p_date=>'2026-04-02T12:00:00Z',p_customer_id=>:'customer_a'::uuid,p_customer_name=>'Fix Customer A',
 p_pricing_mode=>'MONTHLY',p_idempotency_key=>'fx-grn-key',p_items=>jsonb_build_array(pg_temp.rf_line(:'potatoes','Fix Potatoes',7,'FXG1'))) AS grn_first \gset
SELECT public.save_grn(p_gr_no=>'FXG1',p_date=>'2026-04-02T12:00:00Z',p_customer_id=>:'customer_a'::uuid,p_customer_name=>'Fix Customer A',
 p_pricing_mode=>'MONTHLY',p_idempotency_key=>'fx-grn-key',p_items=>jsonb_build_array(pg_temp.rf_line(:'potatoes','Fix Potatoes',7,'FXG1'))) AS grn_replay \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'grn_first'::jsonb->>'success'='true' AND :'grn_replay'::jsonb#>>'{data,grn_id}'=:'grn_first'::jsonb#>>'{data,grn_id}'
 AND (SELECT count(*)=1 FROM public.goodsreceived WHERE gr_no='FXG1'),'twin: while the receipt exists the same key answers with the same receipt: '||:'grn_replay');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_grn_safe((:'grn_first'::jsonb#>>'{data,grn_id}')::uuid) AS grn_deleted \gset
SELECT public.save_grn(p_gr_no=>'FXG1',p_date=>'2026-04-02T12:00:00Z',p_customer_id=>:'customer_a'::uuid,p_customer_name=>'Fix Customer A',
 p_pricing_mode=>'MONTHLY',p_idempotency_key=>'fx-grn-key',p_items=>jsonb_build_array(pg_temp.rf_line(:'potatoes','Fix Potatoes',7,'FXG1'))) AS grn_again \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'grn_deleted'::jsonb->>'success'='true' AND :'grn_again'::jsonb->>'success'='true'
 AND :'grn_again'::jsonb#>>'{data,grn_id}' IS DISTINCT FROM :'grn_first'::jsonb#>>'{data,grn_id}'
 AND (SELECT count(*)=1 FROM public.goodsreceived WHERE gr_no='FXG1' AND id=(:'grn_again'::jsonb#>>'{data,grn_id}')::uuid),
 'after the receipt was deleted the same key makes a new receipt: '||:'grn_again');

-- ---------------------------------------------------------------------------
-- 2. Request codes: a repeat returns the stored answer; get_submission_result is the caller's own, while the record exists
-- ---------------------------------------------------------------------------
SELECT id AS disp_1 FROM public.dispatch WHERE disp_no='FXD1' AND deleted_at IS NULL \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_1'::uuid,jsonb_build_object('note','first try','request_key','fx-edit-key'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a1','disp_qty',8)]) AS edit_first \gset
-- The same request code again, now with other values: the stored answer comes back and nothing is written.
SELECT public.update_dispatch_smart(:'disp_1'::uuid,jsonb_build_object('note','second try','request_key','fx-edit-key'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a1','disp_qty',20)]) AS edit_repeat \gset
-- Another code with the same values is a new edit: it is written.
SELECT public.update_dispatch_smart(:'disp_1'::uuid,jsonb_build_object('note','third try','request_key','fx-edit-key-2'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a1','disp_qty',9)]) AS edit_other \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'edit_first'::jsonb->>'success'='true' AND :'edit_repeat'::jsonb=:'edit_first'::jsonb,
 'the repeat of a request code returns the stored answer as it was: '||:'edit_repeat');
SELECT pg_temp.rf_assert((SELECT disp_qty=9 FROM public.dispatch_trl WHERE disp_id=:'disp_1'::uuid)
 AND (SELECT note='third try' FROM public.dispatch WHERE id=:'disp_1'::uuid)
 AND (SELECT stock=91 FROM public.goodsreceived_trl WHERE id=:'lot_a1'::uuid)
 AND :'edit_other'::jsonb->>'success'='true',
 'a new code is a new edit (9 bags, note third try); the repeat of the first wrote nothing (20 bags and the second note never happened)');
SELECT (SELECT count(*) FROM public.stock_movements WHERE reference_id=:'disp_1'::uuid AND reference_type='dispatch_update') AS edit_moves \gset
SELECT pg_temp.rf_assert(:edit_moves=2,'the two real edits (5 to 8, 8 to 9) wrote two movements, the repeat none: '||:edit_moves);
-- get_submission_result: the caller's own answer
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_submission_result('fx-edit-key') AS own_result \gset
SELECT public.get_submission_result('fx-cache-key') AS own_create \gset
SELECT public.get_submission_result('no-such-code') AS unknown_result \gset
SELECT public.get_submission_result(NULL) AS null_result \gset
SELECT public.get_submission_result('') AS blank_result \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'own_result'::jsonb->>'found'='true' AND :'own_result'::jsonb->'response'=:'edit_first'::jsonb,
 'the saving user finds the answer of a code: '||:'own_result');
SELECT pg_temp.rf_assert(:'own_create'::jsonb->>'found'='true' AND :'own_create'::jsonb#>>'{response,dispatch_id}'=:'after_delete'::jsonb->>'dispatch_id',
 'a dispatch create key is found too, with the live dispatch: '||:'own_create');
SELECT pg_temp.rf_assert(:'unknown_result'::jsonb='{"found": false}'::jsonb AND :'null_result'::jsonb='{"found": false}'::jsonb
 AND :'blank_result'::jsonb='{"found": false}'::jsonb,'an unknown, NULL or blank code is not found');
-- Another user, with the same code, finds nothing.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rf_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT public.get_submission_result('fx-edit-key') AS other_result \gset
SELECT public.get_submission_result('fx-cache-key') AS other_create \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'other_result'::jsonb='{"found": false}'::jsonb AND :'other_create'::jsonb='{"found": false}'::jsonb,
 'another user does not find the first user''s answers: '||:'other_result');
-- An expired answer is not found; the record gone is not found.
UPDATE public.idempotency_keys SET expires_at=now()-interval '1 minute' WHERE idempotency_key='fx-edit-key';
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_submission_result('fx-edit-key') AS expired_result \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'expired_result'::jsonb='{"found": false}'::jsonb,'an expired answer is not found');
UPDATE public.dispatch SET deleted_at=now() WHERE id=:'disp_1'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_submission_result('fx-edit-key-2') AS gone_result \gset
SELECT public.update_dispatch_smart(:'disp_1'::uuid,jsonb_build_object('note','after delete','request_key','fx-edit-key-2'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a1','disp_qty',9)]) AS edit_gone \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'gone_result'::jsonb='{"found": false}'::jsonb
 AND :'edit_gone'::jsonb->>'success'='false' AND :'edit_gone'::jsonb->>'error'='Dispatch not found',
 'once the dispatch is gone its code is not found and a repeat is not replayed: '||:'gone_result'||:'edit_gone');
UPDATE public.dispatch SET deleted_at=NULL WHERE id=:'disp_1'::uuid;

-- ---------------------------------------------------------------------------
-- 3. NUMBER_TAKEN: dispatch create, dispatch edit, invoice save, invoice edit
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || '{"disp_no":"FXD1"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a2','disp_qty',1)],0,'fx-number-taken') AS taken_create \gset
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || '{"disp_no":"FXD2"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a2','disp_qty',1)],0,'fx-number-free') AS free_create \gset
SELECT public.update_dispatch_smart((:'free_create'::jsonb->>'dispatch_id')::uuid,jsonb_build_object('disp_no','FXD1'),NULL) AS taken_edit \gset
SELECT public.update_dispatch_smart((:'free_create'::jsonb->>'dispatch_id')::uuid,jsonb_build_object('disp_no','FXD3'),NULL) AS free_edit \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'taken_create'::jsonb->>'success'='false' AND :'taken_create'::jsonb->>'reason'='NUMBER_TAKEN'
 AND :'taken_create'::jsonb->>'error_code'='WH409' AND :'taken_create'::jsonb->>'number'='FXD1'
 AND :'taken_create'::jsonb->>'error'='Dispatch number FXD1 is already used','dispatch create with a used number: NUMBER_TAKEN: '||:'taken_create');
SELECT pg_temp.rf_assert(:'free_create'::jsonb->>'success'='true' AND (SELECT stock=59 FROM public.goodsreceived_trl WHERE id=:'lot_a2'::uuid),
 'twin: a free number is saved, and the refused create took no stock (only the free one took 1 of 60)');
SELECT pg_temp.rf_assert(:'taken_edit'::jsonb->>'success'='false' AND :'taken_edit'::jsonb->>'reason'='NUMBER_TAKEN'
 AND :'taken_edit'::jsonb->>'error_code'='WH409' AND :'taken_edit'::jsonb->>'number'='FXD1','dispatch edit to a used number: NUMBER_TAKEN: '||:'taken_edit');
SELECT pg_temp.rf_assert(:'free_edit'::jsonb->>'success'='true' AND (SELECT disp_no='FXD3' FROM public.dispatch WHERE id=(:'free_create'::jsonb->>'dispatch_id')::uuid),
 'twin: an edit to a free number is saved');
-- Invoices. FXI (two lots) and FXK (one lot) are dispatched in full first: an invoice needs a GRN with no stock (migration 121).
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || '{"disp_no":"FXDI"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_i1','disp_qty',10),jsonb_build_object('gr_trl_id',:'lot_i2','disp_qty',10)],0,'fx-di') AS disp_i \gset
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || '{"disp_no":"FXDK"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_k1','disp_qty',3)],0,'fx-dk') AS disp_k \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'disp_i'::jsonb->>'success'='true' AND :'disp_k'::jsonb->>'success'='true','FXI and FXK dispatched in full');
SELECT jsonb_build_object('inv_fin_year',2026,'customer_id',:'customer_a','customer_name','Fix Customer A','inv_date','2026-06-20',
 'total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy') AS inv_base \gset
SELECT jsonb_agg(jsonb_build_object('disp_trl_id',dt.id,'grn_item_id',dt.gr_trl_id,'duration',1,'charge',10,'tax',0,'labour_rate',2) ORDER BY dt.gr_trl_id) AS lines_i
 FROM public.dispatch_trl dt WHERE dt.disp_id=(:'disp_i'::jsonb->>'dispatch_id')::uuid \gset
SELECT jsonb_agg(jsonb_build_object('disp_trl_id',dt.id,'grn_item_id',dt.gr_trl_id,'duration',1,'charge',10,'tax',0,'labour_rate',2)) AS lines_k
 FROM public.dispatch_trl dt WHERE dt.disp_id=(:'disp_k'::jsonb->>'dispatch_id')::uuid \gset
CREATE FUNCTION pg_temp.rf_items(lines jsonb) RETURNS jsonb[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(e),ARRAY[]::jsonb[]) FROM jsonb_array_elements(lines) e $$;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_invoice(NULL::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',91001,'gr_id',:'grn_i','gr_no','FXI','request_key','fx-inv-key'),
 pg_temp.rf_items(:'lines_i'::jsonb)) AS inv_first \gset
SELECT public.save_invoice(NULL::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',91001,'gr_id',:'grn_i','gr_no','FXI','request_key','fx-inv-key'),
 pg_temp.rf_items(:'lines_i'::jsonb)) AS inv_repeat \gset
SELECT public.get_submission_result('fx-inv-key') AS inv_result \gset
-- NUMBER_TAKEN: FXK under the number FXI holds; then under a free one.
SELECT public.save_invoice(NULL::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',91001,'gr_id',:'grn_k','gr_no','FXK'),
 pg_temp.rf_items(:'lines_k'::jsonb)) AS inv_taken \gset
SELECT public.save_invoice(NULL::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',91002,'gr_id',:'grn_k','gr_no','FXK'),
 pg_temp.rf_items(:'lines_k'::jsonb)) AS inv_free \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'inv_first'::jsonb->>'success'='true' AND :'inv_repeat'::jsonb=:'inv_first'::jsonb
 AND (SELECT count(*)=1 FROM public.invoice WHERE gr_id=:'grn_i'::uuid) AND (SELECT count(*)=2 FROM public.invoice_trl it JOIN public.invoice i ON i.id=it.invoice_id WHERE i.gr_id=:'grn_i'::uuid),
 'invoice save: the repeat of a request code returns the stored answer, one invoice with two lines: '||:'inv_repeat');
SELECT pg_temp.rf_assert(:'inv_result'::jsonb->>'found'='true' AND :'inv_result'::jsonb->'response'=:'inv_first'::jsonb,
 'get_submission_result finds the invoice answer: '||:'inv_result');
SELECT pg_temp.rf_assert(:'inv_taken'::jsonb->>'success'='false' AND :'inv_taken'::jsonb->>'reason'='NUMBER_TAKEN' AND :'inv_taken'::jsonb->>'error_code'='WH409'
 AND :'inv_taken'::jsonb->>'number'='91001' AND (SELECT count(*)=0 FROM public.invoice WHERE gr_id=:'grn_k'::uuid AND inv_no=91001),
 'invoice save with a used number: NUMBER_TAKEN, nothing saved: '||:'inv_taken');
SELECT pg_temp.rf_assert(:'inv_free'::jsonb->>'success'='true' AND (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn_k'::uuid),'twin: a free number saves the invoice: '||:'inv_free');
SELECT id AS invoice_k FROM public.invoice WHERE gr_id=:'grn_k'::uuid AND inv_no=91002 \gset
SELECT id AS invoice_i FROM public.invoice WHERE gr_id=:'grn_i'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_invoice(:'invoice_k'::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',91001,'gr_id',:'grn_k','gr_no','FXK'),
 pg_temp.rf_items(:'lines_k'::jsonb)) AS upd_taken \gset
SELECT inv_no AS number_after_refusal FROM public.invoice WHERE id=:'invoice_k'::uuid \gset
SELECT public.update_invoice(:'invoice_k'::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',91003,'gr_id',:'grn_k','gr_no','FXK'),
 pg_temp.rf_items(:'lines_k'::jsonb)) AS upd_free \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'upd_taken'::jsonb->>'success'='false' AND :'upd_taken'::jsonb->>'reason'='NUMBER_TAKEN' AND :'upd_taken'::jsonb->>'error_code'='WH409'
 AND :'upd_taken'::jsonb->>'number'='91001' AND :number_after_refusal=91002,
 'invoice edit to a used number: NUMBER_TAKEN, the number stays: '||:'upd_taken');
SELECT pg_temp.rf_assert(:'upd_free'::jsonb->>'success'='true' AND (SELECT inv_no=91003 FROM public.invoice WHERE id=:'invoice_k'::uuid),'twin: an edit to a free number is saved: '||:'upd_free');

-- ---------------------------------------------------------------------------
-- 4. An empty line list is refused; no list keeps the lines
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_1'::uuid,jsonb_build_object('note','empty list'),ARRAY[]::jsonb[]) AS empty_list \gset
SELECT public.update_dispatch_smart(:'disp_1'::uuid,jsonb_build_object('note','no list'),NULL) AS no_list \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'empty_list'::jsonb->>'success'='false' AND :'empty_list'::jsonb->>'error'='A dispatch needs at least one line'
 AND (SELECT count(*)=1 AND bool_and(disp_qty=9) FROM public.dispatch_trl WHERE disp_id=:'disp_1'::uuid)
 AND (SELECT note IS DISTINCT FROM 'empty list' FROM public.dispatch WHERE id=:'disp_1'::uuid),
 'an empty line list is refused and changes nothing (not even the note): '||:'empty_list');
SELECT pg_temp.rf_assert(:'no_list'::jsonb->>'success'='true' AND (SELECT note='no list' FROM public.dispatch WHERE id=:'disp_1'::uuid)
 AND (SELECT count(*)=1 AND bool_and(disp_qty=9) FROM public.dispatch_trl WHERE disp_id=:'disp_1'::uuid),'twin: no list keeps the lines and saves the header');

-- ---------------------------------------------------------------------------
-- 5. D20: a cancelled invoice keeps its lines and amounts when the dispatch line goes; the link is emptied
-- ---------------------------------------------------------------------------
-- The live invoice of FXI holds both dispatch lines: they cannot be taken away (the refusal), but once the invoice is
-- cancelled (the older soft delete: deleted_at set) the dispatch may be edited and its line is removed.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart((:'disp_i'::jsonb->>'dispatch_id')::uuid,jsonb_build_object('note','drop a line'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_i1','disp_qty',10)]) AS live_refused \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'live_refused'::jsonb->>'success'='false' AND :'live_refused'::jsonb->>'error' LIKE 'Cannot modify invoiced items:%'
 AND (SELECT count(*)=2 FROM public.dispatch_trl WHERE disp_id=(:'disp_i'::jsonb->>'dispatch_id')::uuid),'a line on a live invoice cannot be removed: '||:'live_refused');
SELECT sum(charge) AS charge_before, count(*) AS lines_before FROM public.invoice_trl WHERE invoice_id=:'invoice_i'::uuid \gset
UPDATE public.invoice SET deleted_at=now() WHERE id=:'invoice_i'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart((:'disp_i'::jsonb->>'dispatch_id')::uuid,jsonb_build_object('note','drop a line'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_i1','disp_qty',10)]) AS cancelled_edit \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'cancelled_edit'::jsonb->>'success'='true' AND (SELECT count(*)=1 FROM public.dispatch_trl WHERE disp_id=(:'disp_i'::jsonb->>'dispatch_id')::uuid),
 'with the invoice cancelled the line can be removed: '||:'cancelled_edit');
SELECT pg_temp.rf_assert((SELECT count(*)=:lines_before AND sum(charge)=:charge_before FROM public.invoice_trl WHERE invoice_id=:'invoice_i'::uuid)
 AND (SELECT count(*)=1 FROM public.invoice_trl WHERE invoice_id=:'invoice_i'::uuid AND disp_trl_id IS NULL)
 AND (SELECT count(*)=1 FROM public.invoice_trl WHERE invoice_id=:'invoice_i'::uuid AND disp_trl_id IS NOT NULL),
 'the cancelled invoice keeps both lines and the amounts; the removed line has no link, the other keeps its link');
-- Deleting the whole dispatch empties the other link too, and still removes no line of the cancelled invoice.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup((:'disp_i'::jsonb->>'dispatch_id')::uuid,:'admin_profile'::uuid) AS delete_i \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'delete_i'::jsonb->>'success'='true' AND (SELECT count(*)=:lines_before AND bool_and(disp_trl_id IS NULL) AND sum(charge)=:charge_before
  FROM public.invoice_trl WHERE invoice_id=:'invoice_i'::uuid),
 'deleting the dispatch leaves the cancelled invoice''s lines, all unlinked: '||:'delete_i');

-- ---------------------------------------------------------------------------
-- 6. order_lines_left on a dispatch made from an order
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'customer_a'::uuid) AS cart_a \gset
SELECT pg_temp.rf_assert(public.add_item_to_order(:'cart_a'::uuid,:'lot_a1'::uuid,4)->>'success'='true','order line for potatoes');
SELECT pg_temp.rf_assert(public.add_item_to_order(:'cart_a'::uuid,:'lot_a2'::uuid,3)->>'success'='true','order line for onions');
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || jsonb_build_object('disp_no','FXD4','source_order_id',:'cart_a'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a1','disp_qty',4)],0,'fx-from-order-1') AS from_order_1 \gset
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || jsonb_build_object('disp_no','FXD5','source_order_id',:'cart_a'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a2','disp_qty',3)],0,'fx-from-order-2') AS from_order_2 \gset
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || '{"disp_no":"FXD6"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a1','disp_qty',2)],0,'fx-direct-6') AS direct_6 \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'from_order_1'::jsonb->>'success'='true' AND :'from_order_1'::jsonb->>'order_lines_left'='1',
 'one of two order lines dispatched: 1 line still open: '||:'from_order_1');
SELECT pg_temp.rf_assert(:'from_order_2'::jsonb->>'success'='true' AND :'from_order_2'::jsonb->>'order_lines_left'='0',
 'the second line dispatched: 0 lines open: '||:'from_order_2');
SELECT pg_temp.rf_assert(:'direct_6'::jsonb->>'success'='true' AND :'direct_6'::jsonb ? 'order_lines_left' AND jsonb_typeof(:'direct_6'::jsonb->'order_lines_left')='null',
 'a dispatch with no source order answers order_lines_left null: '||:'direct_6');
-- A partial dispatch leaves the line open.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rf_assert(public.add_item_to_order(:'cart_a'::uuid,:'lot_a1'::uuid,6)->>'success'='true','order line for potatoes again (6)');
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb || jsonb_build_object('disp_no','FXD7','source_order_id',:'cart_a'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_a1','disp_qty',2)],0,'fx-from-order-3') AS from_order_3 \gset
RESET ROLE;
SELECT pg_temp.rf_assert(:'from_order_3'::jsonb->>'success'='true' AND :'from_order_3'::jsonb->>'order_lines_left'='1'
 AND (SELECT requested_quantity=4 FROM public.order_items WHERE order_id=:'cart_a'::uuid AND grn_items_id=:'lot_a1'::uuid),
 '2 of 6 dispatched: the line stays open with 4: '||:'from_order_3');

-- ---------------------------------------------------------------------------
-- 7. A cart line that does not exist is "Order item not found"; one that exists is checked against its customer
-- ---------------------------------------------------------------------------
SELECT id AS open_line FROM public.order_items WHERE order_id=:'cart_a'::uuid AND grn_items_id=:'lot_a1'::uuid \gset
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rf_assert(warehouse_security.active_role()='customer','actual customer role');
SELECT pg_temp.rf_call(format('SELECT public.update_order_item_quantity(%L::uuid,3)',gen_random_uuid())) AS cust_missing_update \gset
SELECT pg_temp.rf_call(format('SELECT public.remove_item_from_order(%L::uuid)',gen_random_uuid())) AS cust_missing_remove \gset
SELECT pg_temp.rf_call(format('SELECT public.update_order_item_quantity(%L::uuid,3)',:'open_line')) AS cust_foreign_update \gset
SELECT pg_temp.rf_call(format('SELECT public.remove_item_from_order(%L::uuid)',:'open_line')) AS cust_foreign_remove \gset
RESET ROLE;
SELECT pg_temp.rf_assert((:'cust_missing_update'::jsonb)->>'message'='Order item not found' AND (:'cust_missing_remove'::jsonb)->>'message'='Order item not found',
 'a customer asking about a line that does not exist is told it was not found: '||:'cust_missing_update'||:'cust_missing_remove');
SELECT pg_temp.rf_assert(:'cust_foreign_update' LIKE 'raised: 42501%Customer access denied%' AND :'cust_foreign_remove' LIKE 'raised: 42501%Customer access denied%'
 AND (SELECT requested_quantity=4 FROM public.order_items WHERE id=:'open_line'::uuid),
 'twin: a line that exists, of a customer the login does not own, is still refused and unchanged: '||:'cust_foreign_update'||:'cust_foreign_remove');
