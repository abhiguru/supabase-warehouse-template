-- Migration 121 (owner decisions D1 to D25, "wave B"): one section per decision, each with a refusal and an allowed twin.
--   D1  stale edits (dispatch, GRN, invoice, order line): STALE_RECORD; no token = no check; a resend of the user's own lost
--       save (request code / idempotency key) is answered before the version check
--   D2  locks after invoicing and dispatch (LOT_INVOICED, LOT_DISPATCHED, DISPATCH_INVOICED); D23 GRN_DATE_LOCKED
--   D3  date rules (DISPATCH_DATE_FUTURE, DISPATCH_BEFORE_GRN, GRN_DATE_AFTER_DISPATCH); D25 an unchanged legacy date is edited
--   D4  dispatch edit and delete keep the order in step (lower, remove, raise, delete; the log rows)
--   D5  dispatch from an order: ORDER_CHANGED only when the order's lines changed
--   D6  GRN number locked; D8 the next GRN number follows the highest letter
--   D9  GRN_HAS_STOCK on invoice save and edit; GRN_INVOICED for a new line on an invoiced GRN
--   D10 staff drop of a GRN-only rate (RATES_NEED_MANAGER) and D24 manager's (RATES_WOULD_DROP)
--   D11 removing a GRN line: LINE_DISPATCHED_BEFORE, LINE_ON_ORDER
--   D12 audit rows of GRN edits and deletes; D13 registration length; D15 digits stored as 0-9
--   D16 a deactivated business is still dispatched and may still order; a new GRN is refused
--   D18 TOTAL_CHANGED and its rollback; get_grn_edit_state (the edit form's version token and locks)
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.rd_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'review decisions 121: %',label; END IF; END $$;
-- True when the statement raises an error whose text matches the pattern.
CREATE FUNCTION pg_temp.rd_raises(statement text, pattern text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM LIKE pattern; END;
  RETURN false;
END $$;
CREATE FUNCTION pg_temp.rd_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.rd_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.rd_assert(l#>>'{data,action}'='login','login for '||phone);
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
SELECT warehouse_security.bootstrap_first_admin('9888888911','Decision Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888912','Decision Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888913','Decision Supervisor','supervisor',true,'approved');
SELECT pg_temp.rd_login('9888888911') AS admin_claims \gset
SELECT pg_temp.rd_login('9888888912') AS staff_claims \gset
SELECT pg_temp.rd_login('9888888913') AS supervisor_claims \gset
SELECT auth_user_id AS admin_sub FROM public.user_profiles WHERE id=:'admin_profile'::uuid \gset

-- The GRN numbers of the pattern letter + digits are what D8 reads: this file starts with none of them.
SELECT pg_temp.rd_assert((SELECT count(*)=0 FROM public.goodsreceived WHERE gr_no ~ '^[A-Z][0-9]{1,7}$'),'no GRN of the series pattern before this file');
-- Lines of a GRN as update_grn wants them back (ids included), with an optional patch for the lines of one package mark.
CREATE FUNCTION pg_temp.rd_lines(p_grn uuid, p_patch jsonb DEFAULT '{}', p_mark text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id',t.id,'item_id',t.item_id,'item_name',t.item_name,'packaging',t.packaging,'qty',t.qty,
      'weight',t.weight,'rack',t.rack,'package_mark',t.package_mark)
    || CASE WHEN p_mark IS NULL OR t.package_mark=p_mark THEN p_patch ELSE '{}'::jsonb END ORDER BY uuid_extract_timestamp(t.id), t.id),'[]'::jsonb)
  FROM public.goodsreceived_trl t WHERE t.gr_id=p_grn $$;
CREATE FUNCTION pg_temp.rd_new_line(p_item uuid, p_name text, p_qty integer, p_mark text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('item_id',p_item,'item_name',p_name,'packaging','Bag','qty',p_qty,'weight',10,'rack','R1','package_mark',p_mark) $$;
CREATE FUNCTION pg_temp.rd_ts(p timestamptz) RETURNS text LANGUAGE sql AS $$ SELECT to_char(p AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') $$;
-- The version tokens are updated_at = now(), and now() is fixed inside this test's transaction, so a change made here does not move
-- a token. A stale token is therefore what the user read earlier: the current one five seconds back.
CREATE FUNCTION pg_temp.rd_old(p timestamptz) RETURNS timestamptz LANGUAGE sql AS $$ SELECT p - interval '5 seconds' $$;

-- Fixture, as the administrator. Customers A (documents), B (order sync), C (GRN lines), D (deactivated); items.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rd_assert(public.create_customer('Decision Customer A','9888888921')->>'success'='true','customer A');
SELECT pg_temp.rd_assert(public.create_customer('Decision Customer B','9888888922')->>'success'='true','customer B');
SELECT pg_temp.rd_assert(public.create_customer('Decision Customer C','9888888923')->>'success'='true','customer C');
SELECT pg_temp.rd_assert(public.create_customer('Decision Customer D','9888888924')->>'success'='true','customer D');
SELECT pg_temp.rd_assert(public.create_item('Decision Potatoes','Bag')->>'success'='true','item potatoes');
SELECT pg_temp.rd_assert(public.create_item('Decision Onions','Bag')->>'success'='true','item onions');
SELECT id AS ca FROM public.customers WHERE name='Decision Customer A' \gset
SELECT id AS cb FROM public.customers WHERE name='Decision Customer B' \gset
SELECT id AS cc FROM public.customers WHERE name='Decision Customer C' \gset
SELECT id AS cd FROM public.customers WHERE name='Decision Customer D' \gset
SELECT id AS potatoes FROM public.items WHERE name='Decision Potatoes' \gset
SELECT id AS onions FROM public.items WHERE name='Decision Onions' \gset
-- DG1  A  dispatched-not-invoiced lot (potatoes 100, 5 dispatched on DDX1 dated 2026-05-02), a second lot nothing touches
-- DGI  A  potatoes 10, fully dispatched on DDI (2026-05-02) and invoiced 92001: the invoiced GRN, lot and dispatch
SELECT pg_temp.rd_assert(public.save_grn(p_gr_no=>'DG1',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'ca'::uuid,p_customer_name=>'Decision Customer A',
 p_pricing_mode=>'MONTHLY',p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',100,'DG1-P'),
  pg_temp.rd_new_line(:'onions','Decision Onions',20,'DG1-O')))->>'success'='true','receipt DG1');
SELECT pg_temp.rd_assert(public.save_grn(p_gr_no=>'DGI',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'ca'::uuid,p_customer_name=>'Decision Customer A',
 p_pricing_mode=>'MONTHLY',p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',10,'DGI-P')))->>'success'='true','receipt DGI');
RESET ROLE;
SELECT id AS grn_1 FROM public.goodsreceived WHERE gr_no='DG1' \gset
SELECT id AS grn_i FROM public.goodsreceived WHERE gr_no='DGI' \gset
SELECT id AS lot_1p FROM public.goodsreceived_trl WHERE gr_id=:'grn_1'::uuid AND package_mark='DG1-P' \gset
SELECT id AS lot_1o FROM public.goodsreceived_trl WHERE gr_id=:'grn_1'::uuid AND package_mark='DG1-O' \gset
SELECT id AS lot_i FROM public.goodsreceived_trl WHERE gr_id=:'grn_i'::uuid \gset
SELECT jsonb_build_object('disp_date','2026-05-02','customer_id',:'ca','customer_name','Decision Customer A',
 'supervisor_id',:'admin_profile','supervisor_name','Decision Administrator') AS for_a \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb||'{"disp_no":"DDX1"}'::jsonb,ARRAY[jsonb_build_object('gr_trl_id',:'lot_1p','disp_qty',5)],0,'rd-ddx1') AS d_x1 \gset
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb||'{"disp_no":"DDI"}'::jsonb,ARRAY[jsonb_build_object('gr_trl_id',:'lot_i','disp_qty',10)],0,'rd-ddi') AS d_i \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'d_x1'::jsonb->>'success'='true' AND :'d_i'::jsonb->>'success'='true','fixture dispatches: '||:'d_x1'||:'d_i');
SELECT (:'d_x1'::jsonb->>'dispatch_id')::uuid AS disp_x1, (:'d_i'::jsonb->>'dispatch_id')::uuid AS disp_i \gset
SELECT jsonb_build_object('inv_fin_year',2026,'customer_id',:'ca','customer_name','Decision Customer A','inv_date','2026-06-20',
 'total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy') AS inv_base \gset
SELECT jsonb_build_object('disp_trl_id',dt.id,'grn_item_id',dt.gr_trl_id,'duration',1,'charge',10,'tax',0,'labour_rate',2) AS line_i
 FROM public.dispatch_trl dt WHERE dt.disp_id=:'disp_i'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_invoice(NULL::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',92001,'gr_id',:'grn_i','gr_no','DGI'),ARRAY[:'line_i'::jsonb]) AS inv_i_saved \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'inv_i_saved'::jsonb->>'success'='true','fixture invoice 92001 on DGI: '||:'inv_i_saved');
SELECT (:'inv_i_saved'::jsonb->>'invoice_id')::uuid AS invoice_i \gset

-- ===========================================================================
-- D1. Stale edits: dispatch
-- ===========================================================================
SELECT updated_at AS tok_d0 FROM public.dispatch WHERE id=:'disp_x1'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_x1'::uuid,jsonb_build_object('note','edit one','expected_updated_at',pg_temp.rd_ts(:'tok_d0'::timestamptz)),NULL) AS d1_ok \gset
RESET ROLE;
SELECT updated_at AS tok_d1 FROM public.dispatch WHERE id=:'disp_x1'::uuid \gset
SELECT pg_temp.rd_assert(:'d1_ok'::jsonb->>'success'='true' AND (:'d1_ok'::jsonb->>'updated_at')::timestamptz=:'tok_d1'::timestamptz,'dispatch edit with the current token is saved and answers the new token: '||:'d1_ok');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_x1'::uuid,jsonb_build_object('note','stale edit','expected_updated_at',pg_temp.rd_ts(pg_temp.rd_old(:'tok_d0'::timestamptz))),NULL) AS d1_stale \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'d1_stale'::jsonb->>'success'='false' AND :'d1_stale'::jsonb->>'reason'='STALE_RECORD' AND :'d1_stale'::jsonb->>'error_code'='WH409'
 AND :'d1_stale'::jsonb->>'what'='dispatch' AND :'d1_stale'::jsonb->>'id'=:'disp_x1'
 AND (:'d1_stale'::jsonb->>'current_updated_at')::timestamptz=:'tok_d1'::timestamptz
 AND :'d1_stale'::jsonb->>'message'='Someone else changed this dispatch. Open it again.'
 AND (SELECT note='edit one' AND updated_at=:'tok_d1'::timestamptz FROM public.dispatch WHERE id=:'disp_x1'::uuid),
 'dispatch edit with an old token: STALE_RECORD, nothing written: '||:'d1_stale');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_x1'::uuid,jsonb_build_object('note','no token'),NULL) AS d1_none \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'d1_none'::jsonb->>'success'='true' AND (SELECT note='no token' FROM public.dispatch WHERE id=:'disp_x1'::uuid),
 'twin: an edit with no token is not checked (an older app, fas-sync): '||:'d1_none');
-- Replay before the check: a resend of the user's own lost save carries the old token and the same request code.
SELECT updated_at AS tok_d2 FROM public.dispatch WHERE id=:'disp_x1'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_x1'::uuid,jsonb_build_object('note','coded save','request_key','rd-d1-code','expected_updated_at',pg_temp.rd_ts(:'tok_d2'::timestamptz)),NULL) AS d1_coded \gset
SELECT public.update_dispatch_smart(:'disp_x1'::uuid,jsonb_build_object('note','coded save','request_key','rd-d1-code','expected_updated_at',pg_temp.rd_ts(pg_temp.rd_old(:'tok_d2'::timestamptz))),NULL) AS d1_resend \gset
SELECT public.update_dispatch_smart(:'disp_x1'::uuid,jsonb_build_object('note','other code','request_key','rd-d1-other','expected_updated_at',pg_temp.rd_ts(pg_temp.rd_old(:'tok_d2'::timestamptz))),NULL) AS d1_other_code \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'d1_coded'::jsonb->>'success'='true' AND :'d1_resend'::jsonb=:'d1_coded'::jsonb,
 'a resend with the same request code and an old token is answered with the stored success, not STALE_RECORD: '||:'d1_resend');
SELECT pg_temp.rd_assert(:'d1_other_code'::jsonb->>'reason'='STALE_RECORD' AND (SELECT note='coded save' FROM public.dispatch WHERE id=:'disp_x1'::uuid),
 'twin: another request code with the old token is stale: '||:'d1_other_code');

-- D1: GRN (update_grn with p_expected_updated_at; the idempotency key is answered first)
SELECT updated_at AS tok_g0 FROM public.goodsreceived WHERE id=:'grn_1'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_grn_edit_state(:'grn_1'::uuid) AS edit_state_1 \gset
SELECT public.update_grn(p_grn_id=>:'grn_1'::uuid,p_note=>'grn edit one',p_items=>pg_temp.rd_lines(:'grn_1'::uuid),p_expected_updated_at=>:'tok_g0'::timestamptz) AS g1_ok \gset
RESET ROLE;
SELECT updated_at AS tok_g1 FROM public.goodsreceived WHERE id=:'grn_1'::uuid \gset
SELECT pg_temp.rd_assert((:'edit_state_1'::jsonb#>>'{data,updated_at}')::timestamptz=:'tok_g0'::timestamptz AND :'g1_ok'::jsonb->>'success'='true'
 AND (:'g1_ok'::jsonb#>>'{grn,updated_at}')::timestamptz=:'tok_g1'::timestamptz,
 'GRN edit with the token get_grn_edit_state gave is saved and answers the new token: '||:'g1_ok');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_1'::uuid,p_note=>'grn stale',p_items=>pg_temp.rd_lines(:'grn_1'::uuid),p_expected_updated_at=>pg_temp.rd_old(:'tok_g0'::timestamptz)) AS g1_stale \gset
SELECT public.update_grn(p_grn_id=>:'grn_1'::uuid,p_note=>'grn no token',p_items=>pg_temp.rd_lines(:'grn_1'::uuid)) AS g1_none \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'g1_stale'::jsonb->>'success'='false' AND :'g1_stale'::jsonb->>'reason'='STALE_RECORD' AND :'g1_stale'::jsonb->>'what'='grn'
 AND :'g1_stale'::jsonb->>'id'=:'grn_1' AND (:'g1_stale'::jsonb->>'current_updated_at')::timestamptz=:'tok_g1'::timestamptz
 AND :'g1_stale'::jsonb->>'message'='Someone else changed this GRN. Open it again.','GRN edit with an old token: STALE_RECORD: '||:'g1_stale');
SELECT pg_temp.rd_assert(:'g1_none'::jsonb->>'success'='true' AND (SELECT note='grn no token' FROM public.goodsreceived WHERE id=:'grn_1'::uuid),'twin: a GRN edit with no token is not checked: '||:'g1_none');
SELECT updated_at AS tok_g2 FROM public.goodsreceived WHERE id=:'grn_1'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_1'::uuid,p_note=>'grn coded',p_items=>pg_temp.rd_lines(:'grn_1'::uuid),p_expected_updated_at=>:'tok_g2'::timestamptz,p_idempotency_key=>'rd-g1-key') AS g1_coded \gset
SELECT public.update_grn(p_grn_id=>:'grn_1'::uuid,p_note=>'grn coded',p_items=>pg_temp.rd_lines(:'grn_1'::uuid),p_expected_updated_at=>pg_temp.rd_old(:'tok_g2'::timestamptz),p_idempotency_key=>'rd-g1-key') AS g1_resend \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'g1_coded'::jsonb->>'success'='true' AND :'g1_resend'::jsonb->>'success'='true' AND :'g1_resend'::jsonb->>'idempotent'='true',
 'a resend of a GRN save with its idempotency key and an old token is replayed, not stale: '||:'g1_resend');

-- D1: invoice (update_invoice with expected_updated_at in the data)
SELECT updated_at AS tok_i0 FROM public.invoice WHERE id=:'invoice_i'::uuid \gset
SELECT jsonb_build_object('disp_trl_id',dt.id,'grn_item_id',dt.gr_trl_id,'duration',1,'charge',10,'tax',0,'labour_rate',2) AS line_i2
 FROM public.dispatch_trl dt WHERE dt.disp_id=:'disp_i'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_detail(:'invoice_i'::uuid) AS detail_i \gset
SELECT public.update_invoice(:'invoice_i'::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',92001,'gr_id',:'grn_i','gr_no','DGI','notes','one','expected_updated_at',pg_temp.rd_ts(:'tok_i0'::timestamptz)),
 ARRAY[:'line_i2'::jsonb]) AS i1_ok \gset
RESET ROLE;
SELECT updated_at AS tok_i1 FROM public.invoice WHERE id=:'invoice_i'::uuid \gset
SELECT pg_temp.rd_assert((:'detail_i'::jsonb#>>'{invoice,updated_at}')::timestamptz=:'tok_i0'::timestamptz AND :'i1_ok'::jsonb->>'success'='true'
 AND (:'i1_ok'::jsonb->>'updated_at')::timestamptz=:'tok_i1'::timestamptz,
 'invoice edit with the token get_invoice_detail gave is saved and answers the new token: '||:'i1_ok'||left(:'detail_i',200));
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_invoice(:'invoice_i'::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',92001,'gr_id',:'grn_i','gr_no','DGI','notes','stale','expected_updated_at',pg_temp.rd_ts(pg_temp.rd_old(:'tok_i0'::timestamptz))),
 ARRAY[:'line_i2'::jsonb]) AS i1_stale \gset
SELECT public.update_invoice(:'invoice_i'::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',92001,'gr_id',:'grn_i','gr_no','DGI','notes','no token'),
 ARRAY[:'line_i2'::jsonb]) AS i1_none \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'i1_stale'::jsonb->>'success'='false' AND :'i1_stale'::jsonb->>'reason'='STALE_RECORD' AND :'i1_stale'::jsonb->>'what'='invoice'
 AND :'i1_stale'::jsonb->>'id'=:'invoice_i' AND :'i1_stale'::jsonb->>'message'='Someone else changed this invoice. Open it again.',
 'invoice edit with an old token: STALE_RECORD: '||:'i1_stale');
SELECT pg_temp.rd_assert(:'i1_none'::jsonb->>'success'='true','twin: an invoice edit with no token is not checked: '||:'i1_none');
SELECT updated_at AS tok_i2 FROM public.invoice WHERE id=:'invoice_i'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_invoice(:'invoice_i'::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',92001,'gr_id',:'grn_i','gr_no','DGI','notes','coded','request_key','rd-i1-code','expected_updated_at',pg_temp.rd_ts(:'tok_i2'::timestamptz)),
 ARRAY[:'line_i2'::jsonb]) AS i1_coded \gset
SELECT public.update_invoice(:'invoice_i'::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',92001,'gr_id',:'grn_i','gr_no','DGI','notes','coded','request_key','rd-i1-code','expected_updated_at',pg_temp.rd_ts(pg_temp.rd_old(:'tok_i2'::timestamptz))),
 ARRAY[:'line_i2'::jsonb]) AS i1_resend \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'i1_coded'::jsonb->>'success'='true' AND :'i1_resend'::jsonb=:'i1_coded'::jsonb,
 'a resend of an invoice save with its request code and an old token is replayed, not stale: '||:'i1_resend');

-- D1: order line (p_expected_updated_at of update_order_item_quantity and remove_item_from_order)
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'ca'::uuid) AS cart_a \gset
SELECT public.add_item_to_order(:'cart_a'::uuid,:'lot_1p'::uuid,5) AS line_added \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'line_added'::jsonb->>'success'='true','order line added: '||:'line_added');
SELECT (:'line_added'::jsonb#>>'{data,order_item_id}')::uuid AS ol, (:'line_added'::jsonb#>>'{data,updated_at}')::timestamptz AS tok_o0 \gset
SELECT pg_temp.rd_assert((SELECT updated_at=:'tok_o0'::timestamptz FROM public.order_items WHERE id=:'ol'::uuid),'add_item_to_order answers the line''s token');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_order_item_quantity(:'ol'::uuid,6,:'tok_o0'::timestamptz) AS o_ok \gset
SELECT public.update_order_item_quantity(:'ol'::uuid,7,pg_temp.rd_old(:'tok_o0'::timestamptz)) AS o_stale \gset
SELECT public.remove_item_from_order(:'ol'::uuid,pg_temp.rd_old(:'tok_o0'::timestamptz)) AS o_stale_remove \gset
SELECT public.update_order_item_quantity(:'ol'::uuid,8) AS o_none \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'o_ok'::jsonb->>'success'='true' AND (:'o_ok'::jsonb#>>'{data,updated_at}')::timestamptz=(SELECT updated_at FROM public.order_items WHERE id=:'ol'::uuid),'order line change with the current token: '||:'o_ok');
SELECT pg_temp.rd_assert(:'o_stale'::jsonb->>'success'='false' AND :'o_stale'::jsonb->>'reason'='STALE_RECORD' AND :'o_stale'::jsonb->>'what'='order_line'
 AND :'o_stale'::jsonb->>'id'=:'ol' AND :'o_stale'::jsonb->>'message'='Someone else changed this order line. Open it again.',
 'order line change with an old token: STALE_RECORD: '||:'o_stale');
SELECT pg_temp.rd_assert(:'o_stale_remove'::jsonb->>'reason'='STALE_RECORD' AND :'o_stale_remove'::jsonb->>'what'='order_line'
 AND EXISTS (SELECT 1 FROM public.order_items WHERE id=:'ol'::uuid),'removal with an old token: STALE_RECORD, the line stays: '||:'o_stale_remove');
SELECT pg_temp.rd_assert(:'o_none'::jsonb->>'success'='true' AND (SELECT requested_quantity=8 FROM public.order_items WHERE id=:'ol'::uuid),'twin: a change with no token is not checked: '||:'o_none');
SELECT updated_at AS tok_o2 FROM public.order_items WHERE id=:'ol'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.remove_item_from_order(:'ol'::uuid,:'tok_o2'::timestamptz) AS o_remove_ok \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'o_remove_ok'::jsonb->>'success'='true' AND NOT EXISTS (SELECT 1 FROM public.order_items WHERE id=:'ol'::uuid),'twin: a removal with the current token removes the line: '||:'o_remove_ok');

-- ===========================================================================
-- get_grn_edit_state (D1, D2, D3, D9, D11): the shape, read for the invoiced GRN DGI and the plain GRN DG1
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_grn_edit_state(:'grn_i'::uuid) AS state_i \gset
SELECT public.get_grn_edit_state(:'grn_1'::uuid) AS state_1 \gset
SELECT public.get_grn_edit_state(gen_random_uuid()) AS state_none \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'state_i'::jsonb->>'success'='true' AND :'state_i'::jsonb#>>'{data,gr_no}'='DGI'
 AND (:'state_i'::jsonb#>>'{data,invoice,inv_no}')::int=92001 AND (:'state_i'::jsonb#>>'{data,invoice,inv_fin_year}')::int=2026
 AND :'state_i'::jsonb#>>'{data,invoice,id}'=:'invoice_i' AND :'state_i'::jsonb#>>'{data,first_dispatch_date}'='2026-05-02'
 AND jsonb_array_length(:'state_i'::jsonb#>'{data,lines}')=1
 AND (:'state_i'::jsonb#>>'{data,lines,0,dispatched_qty}')::int=10 AND (:'state_i'::jsonb#>>'{data,lines,0,has_history}')::boolean
 AND (:'state_i'::jsonb#>>'{data,lines,0,on_invoice}')::boolean AND (:'state_i'::jsonb#>>'{data,lines,0,invoice_no}')::int=92001
 AND NOT (:'state_i'::jsonb#>>'{data,lines,0,on_order}')::boolean AND :'state_i'::jsonb#>>'{data,lines,0,id}'=:'lot_i'
 AND :'state_i'::jsonb#>>'{data,lines,0,order_customer_name}'='Decision Customer A',
 'edit state of the invoiced GRN (staff may read it): '||:'state_i');
SELECT pg_temp.rd_assert(:'state_1'::jsonb#>'{data,invoice}'='null'::jsonb AND :'state_1'::jsonb#>>'{data,first_dispatch_date}'='2026-05-02'
 AND jsonb_array_length(:'state_1'::jsonb#>'{data,lines}')=2
 AND (SELECT bool_and(l->>'id'<>'') FROM jsonb_array_elements(:'state_1'::jsonb#>'{data,lines}') l)
 AND (SELECT (l->>'dispatched_qty')::int=5 AND (l->>'has_history')::boolean AND NOT (l->>'on_invoice')::boolean AND l->>'invoice_no' IS NULL
      FROM jsonb_array_elements(:'state_1'::jsonb#>'{data,lines}') l WHERE l->>'id'=:'lot_1p')
 AND (SELECT (l->>'dispatched_qty')::int=0 AND NOT (l->>'has_history')::boolean AND NOT (l->>'on_order')::boolean
      FROM jsonb_array_elements(:'state_1'::jsonb#>'{data,lines}') l WHERE l->>'id'=:'lot_1o'),
 'edit state of the plain GRN: no invoice, per-line flags differ between the dispatched and the untouched lot: '||:'state_1');
SELECT pg_temp.rd_assert(:'state_none'::jsonb->>'success'='false' AND :'state_none'::jsonb->>'error'='GRN not found','edit state of an unknown GRN: GRN not found');

-- ===========================================================================
-- D2 and D23: locks after invoicing and dispatch
-- ===========================================================================
-- LOT_INVOICED: item, packing or weight of the invoiced lot
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_i'::uuid,p_items=>pg_temp.rd_lines(:'grn_i'::uuid,'{"weight":12,"packaging":"Sack"}')) AS lot_inv_both \gset
SELECT public.update_grn(p_grn_id=>:'grn_i'::uuid,p_items=>pg_temp.rd_lines(:'grn_i'::uuid,jsonb_build_object('item_id',:'onions','item_name','Decision Onions'))) AS lot_inv_item \gset
SELECT public.update_grn(p_grn_id=>:'grn_i'::uuid,p_note=>'note on invoiced',p_items=>pg_temp.rd_lines(:'grn_i'::uuid,'{"rack":"R9"}')) AS lot_inv_ok \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'lot_inv_both'::jsonb->>'success'='false' AND :'lot_inv_both'::jsonb->>'reason'='LOT_INVOICED'
 AND :'lot_inv_both'::jsonb->'fields'='["packaging", "weight"]'::jsonb AND (:'lot_inv_both'::jsonb->>'invoice_no')::int=92001
 AND :'lot_inv_both'::jsonb->>'line_id'=:'lot_i' AND :'lot_inv_both'::jsonb->>'item_name'='Decision Potatoes'
 AND (SELECT weight=10 AND packaging='Bag' FROM public.goodsreceived_trl WHERE id=:'lot_i'::uuid),
 'weight and packing of an invoiced lot: LOT_INVOICED naming both fields, nothing changed: '||:'lot_inv_both');
SELECT pg_temp.rd_assert(:'lot_inv_item'::jsonb->>'reason'='LOT_INVOICED' AND :'lot_inv_item'::jsonb->'fields'='["item"]'::jsonb,'the item of an invoiced lot: LOT_INVOICED: '||:'lot_inv_item');
SELECT pg_temp.rd_assert(:'lot_inv_ok'::jsonb->>'success'='true' AND (SELECT rack='R9' FROM public.goodsreceived_trl WHERE id=:'lot_i'::uuid),
 'twin: the rack and the note of an invoiced GRN stay editable, unchanged item/packing/weight pass: '||:'lot_inv_ok');
-- LOT_DISPATCHED: item and packing of a dispatched, not invoiced lot (DG1-P, 5 dispatched); weight stays editable
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_1'::uuid,p_items=>pg_temp.rd_lines(:'grn_1'::uuid,'{"packaging":"Sack"}','DG1-P')) AS lot_disp_pack \gset
SELECT public.update_grn(p_grn_id=>:'grn_1'::uuid,p_items=>pg_temp.rd_lines(:'grn_1'::uuid,jsonb_build_object('item_id',:'onions','item_name','Decision Onions'),'DG1-P')) AS lot_disp_item \gset
SELECT public.update_grn(p_grn_id=>:'grn_1'::uuid,p_items=>pg_temp.rd_lines(:'grn_1'::uuid,'{"packaging":"Sack"}','DG1-O')) AS lot_free_pack \gset
SELECT public.update_grn(p_grn_id=>:'grn_1'::uuid,p_items=>pg_temp.rd_lines(:'grn_1'::uuid,'{"weight":11}','DG1-P')) AS lot_disp_weight \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'lot_disp_pack'::jsonb->>'success'='false' AND :'lot_disp_pack'::jsonb->>'reason'='LOT_DISPATCHED'
 AND :'lot_disp_pack'::jsonb->'fields'='["packaging"]'::jsonb AND :'lot_disp_pack'::jsonb->>'line_id'=:'lot_1p'
 AND :'lot_disp_pack'::jsonb->>'message'='Decision Potatoes has been dispatched. Its item and packing can''t be changed.'
 AND (SELECT packaging='Bag' FROM public.goodsreceived_trl WHERE id=:'lot_1p'::uuid),'packing of a dispatched lot: LOT_DISPATCHED: '||:'lot_disp_pack');
SELECT pg_temp.rd_assert(:'lot_disp_item'::jsonb->>'reason'='LOT_DISPATCHED' AND :'lot_disp_item'::jsonb->'fields'='["item"]'::jsonb,'the item of a dispatched lot: LOT_DISPATCHED: '||:'lot_disp_item');
SELECT pg_temp.rd_assert(:'lot_free_pack'::jsonb->>'success'='true' AND (SELECT packaging='Sack' FROM public.goodsreceived_trl WHERE id=:'lot_1o'::uuid),
 'twin: the packing of a lot nothing was dispatched from changes: '||:'lot_free_pack');
SELECT pg_temp.rd_assert(:'lot_disp_weight'::jsonb->>'success'='true' AND (SELECT weight=11 FROM public.goodsreceived_trl WHERE id=:'lot_1p'::uuid),
 'twin: the weight of a dispatched, not invoiced lot stays editable: '||:'lot_disp_weight');
-- DISPATCH_INVOICED: date and number of the invoiced dispatch DDI
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_i'::uuid,jsonb_build_object('disp_no','DDI-NEW'),NULL) AS di_number \gset
SELECT public.update_dispatch_smart(:'disp_i'::uuid,jsonb_build_object('disp_date','2026-05-03'),NULL) AS di_date \gset
SELECT public.update_dispatch_smart(:'disp_i'::uuid,jsonb_build_object('disp_no','DDI-NEW','disp_date','2026-05-03'),NULL) AS di_both \gset
SELECT public.update_dispatch_smart(:'disp_i'::uuid,jsonb_build_object('disp_no','DDI','disp_date','2026-05-02','note','on an invoiced dispatch'),NULL) AS di_same \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'di_number'::jsonb->>'success'='false' AND :'di_number'::jsonb->>'reason'='DISPATCH_INVOICED' AND :'di_number'::jsonb->'fields'='["disp_no"]'::jsonb
 AND :'di_number'::jsonb->>'dispatch_no'='DDI' AND (:'di_number'::jsonb->>'invoice_no')::int=92001 AND (:'di_number'::jsonb->>'inv_fin_year')::int=2026
 AND (SELECT disp_no='DDI' FROM public.dispatch WHERE id=:'disp_i'::uuid),'the number of an invoiced dispatch: DISPATCH_INVOICED: '||:'di_number');
SELECT pg_temp.rd_assert(:'di_date'::jsonb->>'reason'='DISPATCH_INVOICED' AND :'di_date'::jsonb->'fields'='["disp_date"]'::jsonb
 AND :'di_both'::jsonb->'fields'='["disp_date", "disp_no"]'::jsonb,'the date (and both) of an invoiced dispatch: DISPATCH_INVOICED: '||:'di_date'||:'di_both');
SELECT pg_temp.rd_assert(:'di_same'::jsonb->>'success'='true' AND (SELECT note='on an invoiced dispatch' AND disp_no='DDI' FROM public.dispatch WHERE id=:'disp_i'::uuid),
 'twin (D25): the same number and day sent back with a note are saved on an invoiced dispatch: '||:'di_same');
-- D23: the date of the invoiced GRN is locked; the same day at another time is not a change
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_i'::uuid,p_date=>'2026-04-02T12:00:00Z',p_items=>pg_temp.rd_lines(:'grn_i'::uuid)) AS grn_date_locked \gset
SELECT public.update_grn(p_grn_id=>:'grn_i'::uuid,p_date=>'2026-04-01T03:00:00Z',p_items=>pg_temp.rd_lines(:'grn_i'::uuid)) AS grn_date_same \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'grn_date_locked'::jsonb->>'success'='false' AND :'grn_date_locked'::jsonb->>'reason'='GRN_DATE_LOCKED'
 AND :'grn_date_locked'::jsonb->>'message'='This GRN is invoiced. Delete or edit the invoice first.' AND (:'grn_date_locked'::jsonb->>'invoice_no')::int=92001
 AND :'grn_date_locked'::jsonb->>'date'='2026-04-02' AND (SELECT warehouse_security.business_date(date)='2026-04-01' FROM public.goodsreceived WHERE id=:'grn_i'::uuid),
 'the date of an invoiced GRN: GRN_DATE_LOCKED: '||:'grn_date_locked');
SELECT pg_temp.rd_assert(:'grn_date_same'::jsonb->>'success'='true','twin: the same India day at another time of day is not a change: '||:'grn_date_same');

-- ===========================================================================
-- D3 and D25: date rules (IST days). DG3: customer A, onions 30 bags, dated 2026-04-01.
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rd_assert(public.save_grn(p_gr_no=>'DG3',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'ca'::uuid,p_customer_name=>'Decision Customer A',
 p_pricing_mode=>'MONTHLY',p_items=>jsonb_build_array(pg_temp.rd_new_line(:'onions','Decision Onions',30,'DG3-O')))->>'success'='true','receipt DG3');
RESET ROLE;
SELECT id AS grn_3 FROM public.goodsreceived WHERE gr_no='DG3' \gset
SELECT id AS lot_3o FROM public.goodsreceived_trl WHERE gr_id=:'grn_3'::uuid \gset
SELECT warehouse_security.business_date(now())::text AS today_ist, (warehouse_security.business_date(now())+3)::text AS future_ist \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check((:'for_a'::jsonb||'{"disp_no":"DDF1"}'::jsonb)||jsonb_build_object('disp_date',:'future_ist'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_3o','disp_qty',1)],0,'rd-ddf1') AS create_future \gset
SELECT public.create_dispatch_with_stock_check((:'for_a'::jsonb||'{"disp_no":"DDF2"}'::jsonb)||'{"disp_date":"2026-03-31"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_3o','disp_qty',1)],0,'rd-ddf2') AS create_early \gset
SELECT public.create_dispatch_with_stock_check((:'for_a'::jsonb||'{"disp_no":"DDF3"}'::jsonb)||jsonb_build_object('disp_date',:'today_ist'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_3o','disp_qty',1)],0,'rd-ddf3') AS create_today \gset
SELECT public.create_dispatch_with_stock_check((:'for_a'::jsonb||'{"disp_no":"DDF4"}'::jsonb)||'{"disp_date":"2026-04-01"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_3o','disp_qty',1)],0,'rd-ddf4') AS create_grn_day \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'create_future'::jsonb->>'success'='false' AND :'create_future'::jsonb->>'reason'='DISPATCH_DATE_FUTURE' AND :'create_future'::jsonb->>'error_code'='WH409'
 AND :'create_future'::jsonb->>'date'=:'future_ist' AND :'create_future'::jsonb->>'today'=:'today_ist'
 AND :'create_future'::jsonb->>'message'=format('A dispatch can''t be dated in the future. Today is %s.',:'today_ist')
 AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no='DDF1'),'create dated in the future: DISPATCH_DATE_FUTURE, nothing saved: '||:'create_future');
SELECT pg_temp.rd_assert(:'create_early'::jsonb->>'reason'='DISPATCH_BEFORE_GRN' AND :'create_early'::jsonb->>'gr_no'='DG3' AND :'create_early'::jsonb->>'grn_date'='2026-04-01'
 AND :'create_early'::jsonb->>'date'='2026-03-31' AND :'create_early'::jsonb->>'message'='The dispatch date 2026-03-31 is before GRN DG3 (2026-04-01).'
 AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no='DDF2') AND (SELECT stock=28 FROM public.goodsreceived_trl WHERE id=:'lot_3o'::uuid),
 'create dated before the GRN: DISPATCH_BEFORE_GRN, saved nothing (30 less the 2 valid creates below = 28 is checked here, so the refused ones took none): '||:'create_early');
SELECT pg_temp.rd_assert(:'create_today'::jsonb->>'success'='true' AND :'create_grn_day'::jsonb->>'success'='true',
 'twin: a dispatch dated today, and one dated on the GRN day, are saved: '||:'create_today'||:'create_grn_day');
SELECT (:'create_grn_day'::jsonb->>'dispatch_id')::uuid AS disp_f4 \gset
-- Edit: a changed day is checked against every line
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_f4'::uuid,jsonb_build_object('disp_date',:'future_ist'),NULL) AS edit_future \gset
SELECT public.update_dispatch_smart(:'disp_f4'::uuid,jsonb_build_object('disp_date','2026-03-30'),NULL) AS edit_early \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'edit_future'::jsonb->>'reason'='DISPATCH_DATE_FUTURE' AND :'edit_future'::jsonb->>'today'=:'today_ist','edit to a future day: DISPATCH_DATE_FUTURE: '||:'edit_future');
SELECT pg_temp.rd_assert(:'edit_early'::jsonb->>'reason'='DISPATCH_BEFORE_GRN' AND :'edit_early'::jsonb->>'gr_no'='DG3'
 AND (SELECT warehouse_security.business_date(disp_date)='2026-04-01' FROM public.dispatch WHERE id=:'disp_f4'::uuid),'edit to a day before the GRN: DISPATCH_BEFORE_GRN, the date stays: '||:'edit_early');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_f4'::uuid,jsonb_build_object('disp_date','2026-04-10'),NULL) AS edit_ok \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'edit_ok'::jsonb->>'success'='true' AND (SELECT warehouse_security.business_date(disp_date)='2026-04-10' FROM public.dispatch WHERE id=:'disp_f4'::uuid),'twin: a valid new day is saved: '||:'edit_ok');
-- D25: a legacy dispatch saved before the rule (dated before its GRN) stays editable while its own day is sent back
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check((:'for_a'::jsonb||'{"disp_no":"DDL1"}'::jsonb)||'{"disp_date":"2026-04-05"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_3o','disp_qty',2)],0,'rd-ddl1') AS legacy_made \gset
RESET ROLE;
SELECT (:'legacy_made'::jsonb->>'dispatch_id')::uuid AS disp_l1 \gset
UPDATE public.dispatch SET disp_date='2026-03-15T03:00:00Z' WHERE id=:'disp_l1'::uuid;
SELECT warehouse_security.business_date(disp_date)::text AS legacy_day FROM public.dispatch WHERE id=:'disp_l1'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_l1'::uuid,jsonb_build_object('disp_date',:'legacy_day','note','legacy note'),NULL) AS legacy_same \gset
SELECT public.update_dispatch_smart(:'disp_l1'::uuid,jsonb_build_object('disp_date',:'legacy_day','note','legacy qty'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_3o','disp_qty',3)]) AS legacy_qty \gset
SELECT public.update_dispatch_smart(:'disp_l1'::uuid,jsonb_build_object('disp_date','2026-03-20'),NULL) AS legacy_moved \gset
SELECT public.update_dispatch_smart(:'disp_l1'::uuid,jsonb_build_object('disp_date',:'legacy_day'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_3o','disp_qty',3),jsonb_build_object('gr_trl_id',:'lot_1o','disp_qty',1)]) AS legacy_added \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'legacy_day'='2026-03-15' AND :'legacy_same'::jsonb->>'success'='true'
 AND (SELECT disp_date='2026-03-15T03:00:00Z' FROM public.dispatch WHERE id=:'disp_l1'::uuid),
 'D25: an old dispatch saved before the date rule is edited when its own day is sent back, the stored date is not rewritten: '||:'legacy_same');
SELECT pg_temp.rd_assert(:'legacy_qty'::jsonb->>'success'='true' AND (SELECT disp_qty=3 FROM public.dispatch_trl WHERE disp_id=:'disp_l1'::uuid),
 'D25: its quantity can be raised on an unchanged day: '||:'legacy_qty');
SELECT pg_temp.rd_assert(:'legacy_moved'::jsonb->>'reason'='DISPATCH_BEFORE_GRN' AND :'legacy_moved'::jsonb->>'date'='2026-03-20',
 'D25 twin: moving the old dispatch to another day before the GRN is refused: '||:'legacy_moved');
SELECT pg_temp.rd_assert(:'legacy_added'::jsonb->>'reason'='DISPATCH_BEFORE_GRN' AND :'legacy_added'::jsonb->>'gr_no'='DG1'
 AND NOT EXISTS (SELECT 1 FROM public.dispatch_trl WHERE disp_id=:'disp_l1'::uuid AND gr_trl_id=:'lot_1o'::uuid),
 'D25 twin: a line the edit adds is checked even on an unchanged day: '||:'legacy_added');
-- D3: the GRN date may not move after its first dispatch (DG1: first dispatch DDX1 on 2026-05-02)
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_1'::uuid,p_date=>'2026-06-01T12:00:00Z',p_items=>pg_temp.rd_lines(:'grn_1'::uuid)) AS grn_late \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'grn_late'::jsonb->>'success'='false' AND :'grn_late'::jsonb->>'reason'='GRN_DATE_AFTER_DISPATCH' AND :'grn_late'::jsonb->>'gr_no'='DG1'
 AND :'grn_late'::jsonb->>'first_dispatch_date'='2026-05-02' AND :'grn_late'::jsonb->>'dispatch_no'='DDX1' AND :'grn_late'::jsonb->>'date'='2026-06-01'
 AND :'grn_late'::jsonb->>'message'='GRN DG1 can''t be dated 2026-06-01: dispatch DDX1 took goods from it on 2026-05-02.'
 AND (SELECT warehouse_security.business_date(date)='2026-04-01' FROM public.goodsreceived WHERE id=:'grn_1'::uuid),
 'GRN dated after its first dispatch: GRN_DATE_AFTER_DISPATCH, the date stays: '||:'grn_late');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_1'::uuid,p_date=>'2026-05-02T12:00:00Z',p_items=>pg_temp.rd_lines(:'grn_1'::uuid)) AS grn_on_day \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'grn_on_day'::jsonb->>'success'='true' AND (SELECT warehouse_security.business_date(date)='2026-05-02' FROM public.goodsreceived WHERE id=:'grn_1'::uuid),
 'twin: a GRN dated on the day of its first dispatch is saved: '||:'grn_on_day');

-- ===========================================================================
-- D4: dispatch edits and deletes keep the order in step. Customer B: GRN DG4 (potatoes 100 = lot 4p, onions 50 = lot 4o).
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rd_assert(public.save_grn(p_gr_no=>'DG4',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'cb'::uuid,p_customer_name=>'Decision Customer B',
 p_pricing_mode=>'MONTHLY',p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',100,'DG4-P'),
  pg_temp.rd_new_line(:'onions','Decision Onions',50,'DG4-O')))->>'success'='true','receipt DG4');
RESET ROLE;
SELECT id AS lot_4p FROM public.goodsreceived_trl WHERE package_mark='DG4-P' \gset
SELECT id AS lot_4o FROM public.goodsreceived_trl WHERE package_mark='DG4-O' \gset
SELECT jsonb_build_object('disp_date','2026-05-02','customer_id',:'cb','customer_name','Decision Customer B',
 'supervisor_id',:'admin_profile','supervisor_name','Decision Administrator') AS for_b \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'cb'::uuid) AS cart_b \gset
SELECT pg_temp.rd_assert(public.add_item_to_order(:'cart_b'::uuid,:'lot_4p'::uuid,10)->>'success'='true' AND public.add_item_to_order(:'cart_b'::uuid,:'lot_4o'::uuid,6)->>'success'='true','order lines for B');
SELECT public.create_dispatch_with_stock_check(:'for_b'::jsonb||jsonb_build_object('disp_no','DDB','source_order_id',:'cart_b'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_4p','disp_qty',10),jsonb_build_object('gr_trl_id',:'lot_4o','disp_qty',6)],0,'rd-ddb') AS ddb \gset
RESET ROLE;
SELECT (:'ddb'::jsonb->>'dispatch_id')::uuid AS disp_b \gset
SELECT pg_temp.rd_assert(:'ddb'::jsonb->>'success'='true' AND :'ddb'::jsonb->>'order_lines_left'='0'
 AND (SELECT count(*)=0 FROM public.order_items WHERE order_id=:'cart_b'::uuid)
 AND (SELECT cart_quantity_consumed=10 FROM public.dispatch_trl WHERE disp_id=:'disp_b'::uuid AND gr_trl_id=:'lot_4p'::uuid)
 AND (SELECT cart_quantity_consumed=6 FROM public.dispatch_trl WHERE disp_id=:'disp_b'::uuid AND gr_trl_id=:'lot_4o'::uuid),'fixture: DDB took both order lines: '||:'ddb');
-- What a create takes is logged as a dispatch reduction (one row per line).
SELECT pg_temp.rd_assert((SELECT count(*)=2 FROM public.order_revisions WHERE order_id=:'cart_b'::uuid AND action='auto_quantity_reduction')
 AND (SELECT entry->>'dispatch_no'='DDB' AND (entry->>'previous_quantity')::int=10 AND (entry->>'new_quantity')::int=0 AND entry->>'grn_item_id'=:'lot_4p' AND entry->>'dispatch_id'=:'disp_b'
      FROM public.order_revisions WHERE order_id=:'cart_b'::uuid AND action='auto_quantity_reduction' AND entry->>'grn_item_id'=:'lot_4p'),
 'create from an order logs two dispatch reductions (10 to 0 for the potatoes)');
-- E1: lowered 10 to 7 gives 3 back to the order
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_b'::uuid,jsonb_build_object('note','lower'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_4p','disp_qty',7),jsonb_build_object('gr_trl_id',:'lot_4o','disp_qty',6)]) AS e1 \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'e1'::jsonb->>'success'='true' AND :'e1'::jsonb->'order_sync'='{"taken": 0, "given_back": 3}'::jsonb
 AND (SELECT requested_quantity=3 AND item_status='pending' FROM public.order_items WHERE order_id=:'cart_b'::uuid AND grn_items_id=:'lot_4p'::uuid)
 AND (SELECT cart_quantity_consumed=7 FROM public.dispatch_trl WHERE disp_id=:'disp_b'::uuid AND gr_trl_id=:'lot_4p'::uuid)
 AND (SELECT stock=93 FROM public.goodsreceived_trl WHERE id=:'lot_4p'::uuid),
 'lowering a line by 3 gives 3 back: the order line is made again with 3, the dispatch line holds 7: '||:'e1');
SELECT pg_temp.rd_assert((SELECT count(*)=1 FROM public.order_revisions WHERE order_id=:'cart_b'::uuid AND action='UPDATE' AND entry->'changes'->>'source'='dispatch_edit'
   AND entry->'changes'->>'dispatch_no'='DDB' AND entry->'changes'->>'dispatch_id'=:'disp_b'),'the give-back is one "Quantity changed" entry naming the dispatch');
-- E2: raised 7 to 9 takes 2 from the order line (3 to 1)
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_b'::uuid,NULL,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_4p','disp_qty',9),jsonb_build_object('gr_trl_id',:'lot_4o','disp_qty',6)]) AS e2 \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'e2'::jsonb->'order_sync'='{"taken": 2, "given_back": 0}'::jsonb
 AND (SELECT requested_quantity=1 FROM public.order_items WHERE order_id=:'cart_b'::uuid AND grn_items_id=:'lot_4p'::uuid)
 AND (SELECT cart_quantity_consumed=9 FROM public.dispatch_trl WHERE disp_id=:'disp_b'::uuid AND gr_trl_id=:'lot_4p'::uuid)
 AND (SELECT count(*)=1 FROM public.order_revisions WHERE order_id=:'cart_b'::uuid AND action='auto_quantity_reduction' AND entry->>'dispatch_no'='DDB'
        AND (entry->>'previous_quantity')::int=3 AND (entry->>'new_quantity')::int=1),'raising a line by 2 takes 2 from the order line (3 to 1) and logs it: '||:'e2');
-- E3: a raise by more than the order line holds empties it (1 left, raised by 6): takes 1, the line is deleted, the rest comes from stock
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_b'::uuid,NULL,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_4p','disp_qty',15),jsonb_build_object('gr_trl_id',:'lot_4o','disp_qty',6)]) AS e3 \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'e3'::jsonb->'order_sync'='{"taken": 1, "given_back": 0}'::jsonb
 AND NOT EXISTS (SELECT 1 FROM public.order_items WHERE order_id=:'cart_b'::uuid AND grn_items_id=:'lot_4p'::uuid)
 AND (SELECT cart_quantity_consumed=10 AND disp_qty=15 FROM public.dispatch_trl WHERE disp_id=:'disp_b'::uuid AND gr_trl_id=:'lot_4p'::uuid)
 AND (SELECT stock=85 FROM public.goodsreceived_trl WHERE id=:'lot_4p'::uuid),
 'a raise that empties the order line: it takes the 1 left and is deleted, the dispatch holds 10 of 15, stock 85: '||:'e3');
-- E4: a line removed from the dispatch gives its 6 back, as a new order line
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_b'::uuid,NULL,ARRAY[jsonb_build_object('gr_trl_id',:'lot_4p','disp_qty',15)]) AS e4 \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'e4'::jsonb->'order_sync'='{"taken": 0, "given_back": 6}'::jsonb
 AND (SELECT requested_quantity=6 AND item_status='pending' FROM public.order_items WHERE order_id=:'cart_b'::uuid AND grn_items_id=:'lot_4o'::uuid)
 AND NOT EXISTS (SELECT 1 FROM public.dispatch_trl WHERE disp_id=:'disp_b'::uuid AND gr_trl_id=:'lot_4o'::uuid)
 AND (SELECT stock=50 FROM public.goodsreceived_trl WHERE id=:'lot_4o'::uuid),'removing a line gives its 6 back to the order and its stock back: '||:'e4');
-- E5: a lot added back with more than its order line holds (line 6, added 10): takes 6, the line is deleted
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_b'::uuid,NULL,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_4p','disp_qty',15),jsonb_build_object('gr_trl_id',:'lot_4o','disp_qty',10)]) AS e5 \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'e5'::jsonb->'order_sync'='{"taken": 6, "given_back": 0}'::jsonb
 AND NOT EXISTS (SELECT 1 FROM public.order_items WHERE order_id=:'cart_b'::uuid AND grn_items_id=:'lot_4o'::uuid)
 AND (SELECT cart_quantity_consumed=6 AND disp_qty=10 FROM public.dispatch_trl WHERE disp_id=:'disp_b'::uuid AND gr_trl_id=:'lot_4o'::uuid)
 AND (SELECT stock=40 FROM public.goodsreceived_trl WHERE id=:'lot_4o'::uuid),
 'an added lot whose order line (6) is at most the added quantity (10): takes 6, deletes the line, the dispatch holds 6 of 10: '||:'e5');
SELECT pg_temp.rd_assert((SELECT count(*)=5 FROM public.order_revisions WHERE order_id=:'cart_b'::uuid AND action='auto_quantity_reduction'),
 'every take is logged: 2 at the create, then one each for the raises of E2, E3 and E5');
-- D4: deleting the dispatch gives back only what its lines still hold. DDB holds p: consumed 10 of 15, o: consumed 6 of 10.
-- The o line is made a legacy line with a recorded give-back of 99, more than the 10 it holds: the old rule would give back 99.
UPDATE public.dispatch_trl SET cart_quantity_consumed=99 WHERE disp_id=:'disp_b'::uuid AND gr_trl_id=:'lot_4o'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_dispatch_with_order_cleanup(:'disp_b'::uuid,:'admin_profile'::uuid) AS delete_b \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'delete_b'::jsonb->>'success'='true'
 AND (SELECT requested_quantity=10 AND item_status='pending' FROM public.order_items WHERE order_id=:'cart_b'::uuid AND grn_items_id=:'lot_4p'::uuid)
 AND (SELECT requested_quantity=10 AND item_status='pending' FROM public.order_items WHERE order_id=:'cart_b'::uuid AND grn_items_id=:'lot_4o'::uuid)
 AND (SELECT stock=100 FROM public.goodsreceived_trl WHERE id=:'lot_4p'::uuid) AND (SELECT stock=50 FROM public.goodsreceived_trl WHERE id=:'lot_4o'::uuid),
 'delete gives back only what the line still holds: p 10 (not all 15), o 10 (not the recorded 99); stock back to 100 and 50: '||:'delete_b');
SELECT pg_temp.rd_assert((SELECT count(*)=1 FROM public.order_revisions WHERE order_id=:'cart_b'::uuid AND action='dispatch_deleted')
 AND (SELECT (entry->>'total_quantity_restored')::int=20 AND entry->>'cart_restoration_status'='success' AND jsonb_array_length(entry->'restored_items')=2
      AND entry->>'dispatch_no'='DDB' AND (entry->'restored_items'->0->>'quantity_restored')::int=10 AND (entry->'restored_items'->1->>'quantity_restored')::int=10
      FROM public.order_revisions WHERE order_id=:'cart_b'::uuid AND action='dispatch_deleted'),
 'the order log has one dispatch_deleted entry listing the two lines given back with 10 each: '||(SELECT entry::text FROM public.order_revisions WHERE order_id=:'cart_b'::uuid AND action='dispatch_deleted'));

-- ===========================================================================
-- D5: dispatch from an order is refused when the order's LINES changed after the form opened (ORDER_CHANGED); other fields are not a reason.
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rd_assert(public.create_customer('Decision Customer E','9888888925')->>'success'='true' AND public.create_customer('Decision Customer F','9888888926')->>'success'='true','customers E and F');
RESET ROLE;
SELECT id AS ce FROM public.customers WHERE name='Decision Customer E' \gset
SELECT id AS cf FROM public.customers WHERE name='Decision Customer F' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rd_assert(public.save_grn(p_gr_no=>'DG5',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'ce'::uuid,p_customer_name=>'Decision Customer E',
 p_pricing_mode=>'MONTHLY',p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',40,'DG5-P'),pg_temp.rd_new_line(:'onions','Decision Onions',40,'DG5-O')))->>'success'='true','receipt DG5');
SELECT pg_temp.rd_assert(public.save_grn(p_gr_no=>'DG6',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'cf'::uuid,p_customer_name=>'Decision Customer F',
 p_pricing_mode=>'MONTHLY',p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',40,'DG6-P')))->>'success'='true','receipt DG6');
RESET ROLE;
SELECT id AS lot_5p FROM public.goodsreceived_trl WHERE package_mark='DG5-P' \gset
SELECT id AS lot_5o FROM public.goodsreceived_trl WHERE package_mark='DG5-O' \gset
SELECT id AS lot_6p FROM public.goodsreceived_trl WHERE package_mark='DG6-P' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_or_create_cart(:'ce'::uuid) AS cart_e \gset
SELECT public.get_or_create_cart(:'cf'::uuid) AS cart_f \gset
SELECT public.add_item_to_order(:'cart_e'::uuid,:'lot_5p'::uuid,5)#>>'{data,order_item_id}' AS line_5p \gset
SELECT public.add_item_to_order(:'cart_e'::uuid,:'lot_5o'::uuid,4)#>>'{data,order_item_id}' AS line_5o \gset
SELECT public.add_item_to_order(:'cart_f'::uuid,:'lot_6p'::uuid,5)#>>'{data,order_item_id}' AS line_6p \gset
RESET ROLE;
-- The forms were opened an hour ago: the orders and their lines carry that time (the triggers that stamp now() are off for this one statement block).
SET LOCAL session_replication_role = replica;
UPDATE public.order_items SET updated_at=now()-interval '1 hour' WHERE order_id IN (:'cart_e'::uuid,:'cart_f'::uuid);
UPDATE public.orders SET updated_at=now()-interval '1 hour' WHERE id IN (:'cart_e'::uuid,:'cart_f'::uuid);
SET LOCAL session_replication_role = origin;
SELECT updated_at AS tok_e FROM public.orders WHERE id=:'cart_e'::uuid \gset
SELECT updated_at AS tok_f FROM public.orders WHERE id=:'cart_f'::uuid \gset
SELECT jsonb_build_object('disp_date','2026-05-02','customer_id',:'ce','customer_name','Decision Customer E','supervisor_id',:'admin_profile','supervisor_name','Decision Administrator') AS for_e \gset
SELECT jsonb_build_object('disp_date','2026-05-02','customer_id',:'cf','customer_name','Decision Customer F','supervisor_id',:'admin_profile','supervisor_name','Decision Administrator') AS for_f \gset
-- F: a line quantity changed after the form opened: refused, nothing saved
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_order_item_quantity(:'line_6p'::uuid,6) AS f_change \gset
SELECT public.create_dispatch_with_stock_check(:'for_f'::jsonb||jsonb_build_object('disp_no','DDF-F1','source_order_id',:'cart_f','source_order_updated_at',pg_temp.rd_ts(:'tok_f'::timestamptz)),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_6p','disp_qty',5)],0,'rd-ddf-f1') AS f_stale \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'f_change'::jsonb->>'success'='true' AND :'f_stale'::jsonb->>'success'='false' AND :'f_stale'::jsonb->>'reason'='ORDER_CHANGED'
 AND :'f_stale'::jsonb->>'error_code'='WH409' AND :'f_stale'::jsonb->>'source_order_id'=:'cart_f'
 AND (:'f_stale'::jsonb->>'current_updated_at')::timestamptz>(:'f_stale'::jsonb->>'expected_updated_at')::timestamptz
 AND :'f_stale'::jsonb->>'message'='This order changed after you opened it.'
 AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no='DDF-F1') AND (SELECT stock=40 FROM public.goodsreceived_trl WHERE id=:'lot_6p'::uuid)
 AND (SELECT requested_quantity=6 FROM public.order_items WHERE id=:'line_6p'::uuid),
 'a line changed after the form opened: ORDER_CHANGED, no dispatch, no stock taken, the order line stays 6: '||:'f_stale');
-- F twin: the form reopened (the order's current updated_at) is dispatched
SELECT updated_at AS tok_f2 FROM public.orders WHERE id=:'cart_f'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'for_f'::jsonb||jsonb_build_object('disp_no','DDF-F2','source_order_id',:'cart_f','source_order_updated_at',pg_temp.rd_ts(:'tok_f2'::timestamptz)),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_6p','disp_qty',6)],0,'rd-ddf-f2') AS f_ok \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'f_ok'::jsonb->>'success'='true' AND :'f_ok'::jsonb->>'order_lines_left'='0','twin: with the order as it is now the dispatch is created: '||:'f_ok');
-- E: only the order's note changed after the form opened: not a reason
UPDATE public.orders SET note='note changed after opening' WHERE id=:'cart_e'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'for_e'::jsonb||jsonb_build_object('disp_no','DDF-E1','source_order_id',:'cart_e','source_order_updated_at',pg_temp.rd_ts(:'tok_e'::timestamptz)),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_5o','disp_qty',4)],0,'rd-ddf-e1') AS e_note \gset
RESET ROLE;
SELECT pg_temp.rd_assert((SELECT updated_at>:'tok_e'::timestamptz FROM public.orders WHERE id=:'cart_e'::uuid) AND :'e_note'::jsonb->>'success'='true' AND :'e_note'::jsonb->>'order_lines_left'='1',
 'twin: the order''s own fields (note) changed, its lines did not: the dispatch is created: '||:'e_note');
-- E again with the same old token, now that its own dispatch took a line: refused (a line was taken after the form opened)
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'for_e'::jsonb||jsonb_build_object('disp_no','DDF-E2','source_order_id',:'cart_e','source_order_updated_at',pg_temp.rd_ts(:'tok_e'::timestamptz)),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_5p','disp_qty',5)],0,'rd-ddf-e2') AS e_after \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'e_after'::jsonb->>'reason'='ORDER_CHANGED' AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no='DDF-E2'),
 'a line taken by another dispatch after the form opened: ORDER_CHANGED: '||:'e_after');

-- ===========================================================================
-- D9: no invoice while the GRN has stock; no new lot on an invoiced GRN
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rd_assert(public.save_grn(p_gr_no=>'DG7',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'ca'::uuid,p_customer_name=>'Decision Customer A',
 p_pricing_mode=>'MONTHLY',p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',10,'DG7-P')))->>'success'='true','receipt DG7');
RESET ROLE;
SELECT id AS grn_7 FROM public.goodsreceived WHERE gr_no='DG7' \gset
SELECT id AS lot_7 FROM public.goodsreceived_trl WHERE gr_id=:'grn_7'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb||'{"disp_no":"DD7A"}'::jsonb,ARRAY[jsonb_build_object('gr_trl_id',:'lot_7','disp_qty',4)],0,'rd-dd7a') AS d7a \gset
RESET ROLE;
SELECT (:'d7a'::jsonb->>'dispatch_id')::uuid AS disp_7a \gset
SELECT jsonb_build_object('disp_trl_id',dt.id,'grn_item_id',dt.gr_trl_id,'duration',1,'charge',10,'tax',0,'labour_rate',2) AS line_7a FROM public.dispatch_trl dt WHERE dt.disp_id=:'disp_7a'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_invoice(NULL::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',92007,'gr_id',:'grn_7','gr_no','DG7'),ARRAY[:'line_7a'::jsonb]) AS stock_save3 \gset
SELECT public.save_invoice(:'inv_base'::jsonb||jsonb_build_object('inv_no',92007,'gr_id',:'grn_7','gr_no','DG7','items',jsonb_build_array(:'line_7a'::jsonb))) AS stock_save1 \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'stock_save3'::jsonb->>'success'='false' AND :'stock_save3'::jsonb->>'reason'='GRN_HAS_STOCK' AND :'stock_save3'::jsonb->>'gr_no'='DG7'
 AND (:'stock_save3'::jsonb->>'stock')::int=6 AND (:'stock_save3'::jsonb->>'lots')::int=1
 AND :'stock_save3'::jsonb->>'message'='GRN DG7 still has 6 in stock. Dispatch it first, then make the invoice.'
 AND NOT EXISTS (SELECT 1 FROM public.invoice WHERE gr_id=:'grn_7'::uuid) AND NOT (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn_7'::uuid),
 'invoice save (3 arguments) on a GRN with 6 in stock: GRN_HAS_STOCK, nothing saved: '||:'stock_save3');
SELECT pg_temp.rd_assert(:'stock_save1'::jsonb->>'reason'='GRN_HAS_STOCK' AND (:'stock_save1'::jsonb->>'stock')::int=6,'invoice save (1 argument): GRN_HAS_STOCK too: '||:'stock_save1');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb||'{"disp_no":"DD7B"}'::jsonb,ARRAY[jsonb_build_object('gr_trl_id',:'lot_7','disp_qty',6)],0,'rd-dd7b') AS d7b \gset
SELECT public.save_invoice(NULL::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',92007,'gr_id',:'grn_7','gr_no','DG7'),ARRAY[:'line_7a'::jsonb]) AS stock_gone_save \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'d7b'::jsonb->>'success'='true' AND :'stock_gone_save'::jsonb->>'success'='true','twin: once the rest is dispatched the same invoice is saved: '||:'stock_gone_save');
-- update_invoice on a GRN that now holds stock again (a legacy invoice): refused until the stock is gone
UPDATE public.goodsreceived_trl SET stock=2 WHERE id=:'lot_i'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_invoice(:'invoice_i'::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',92001,'gr_id',:'grn_i','gr_no','DGI','notes','with stock'),ARRAY[:'line_i2'::jsonb]) AS stock_update \gset
RESET ROLE;
UPDATE public.goodsreceived_trl SET stock=0 WHERE id=:'lot_i'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_invoice(:'invoice_i'::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',92001,'gr_id',:'grn_i','gr_no','DGI','notes','without stock'),ARRAY[:'line_i2'::jsonb]) AS nostock_update \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'stock_update'::jsonb->>'reason'='GRN_HAS_STOCK' AND (:'stock_update'::jsonb->>'stock')::int=2 AND :'nostock_update'::jsonb->>'success'='true',
 'update_invoice on a GRN that holds stock: GRN_HAS_STOCK; with the stock gone it is saved (twin): '||:'stock_update'||:'nostock_update');
-- GRN_INVOICED: a new lot on an invoiced GRN is refused, on a GRN without an invoice it is added
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_i'::uuid,p_items=>pg_temp.rd_lines(:'grn_i'::uuid)||jsonb_build_array(pg_temp.rd_new_line(:'onions','Decision Onions',3,'DGI-NEW'))) AS new_lot_invoiced \gset
SELECT public.update_grn(p_grn_id=>:'grn_3'::uuid,p_items=>pg_temp.rd_lines(:'grn_3'::uuid)||jsonb_build_array(pg_temp.rd_new_line(:'onions','Decision Onions',3,'DG3-NEW'))) AS new_lot_plain \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'new_lot_invoiced'::jsonb->>'success'='false' AND :'new_lot_invoiced'::jsonb->>'reason'='GRN_INVOICED' AND :'new_lot_invoiced'::jsonb->>'gr_no'='DGI'
 AND (:'new_lot_invoiced'::jsonb->>'invoice_no')::int=92001
 AND :'new_lot_invoiced'::jsonb->>'message'='GRN DGI is on invoice 92001. A line can''t be added. Delete the invoice first.'
 AND (SELECT count(*)=1 FROM public.goodsreceived_trl WHERE gr_id=:'grn_i'::uuid),'a new lot on an invoiced GRN: GRN_INVOICED, no line added: '||:'new_lot_invoiced');
SELECT pg_temp.rd_assert(:'new_lot_plain'::jsonb->>'success'='true' AND (SELECT count(*)=2 FROM public.goodsreceived_trl WHERE gr_id=:'grn_3'::uuid),'twin: a new lot on a GRN without an invoice is added: '||:'new_lot_plain');

-- ===========================================================================
-- D6 and D8: the GRN number is locked in an edit; the next number follows the highest letter
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_1'::uuid,p_gr_no=>'DG1X',p_items=>pg_temp.rd_lines(:'grn_1'::uuid)) AS number_changed \gset
SELECT public.update_grn(p_grn_id=>:'grn_1'::uuid,p_gr_no=>'DG1',p_note=>'number sent back',p_items=>pg_temp.rd_lines(:'grn_1'::uuid)) AS number_same \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'number_changed'::jsonb->>'success'='false' AND :'number_changed'::jsonb->>'reason'='GRN_NUMBER_LOCKED' AND :'number_changed'::jsonb->>'gr_no'='DG1'
 AND :'number_changed'::jsonb->>'requested'='DG1X' AND :'number_changed'::jsonb->>'message'='The GRN number can''t be changed. Delete the GRN and enter it again.'
 AND (SELECT gr_no='DG1' FROM public.goodsreceived WHERE id=:'grn_1'::uuid),'a changed GRN number: GRN_NUMBER_LOCKED, the number stays: '||:'number_changed');
SELECT pg_temp.rd_assert(:'number_same'::jsonb->>'success'='true' AND (SELECT note='number sent back' FROM public.goodsreceived WHERE id=:'grn_1'::uuid),
 'twin: the stored number sent back (or no number, as every other edit here) is saved: '||:'number_same');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rd_assert(public.get_next_grn_number()='A0001','with no series GRN the suggestion is A0001: '||public.get_next_grn_number());
SELECT pg_temp.rd_assert(public.save_grn(p_gr_no=>'M0001',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'ca'::uuid,p_customer_name=>'Decision Customer A',
 p_pricing_mode=>'MONTHLY',p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',1,'SERIES-1')))->>'success'='true','GRN M0001');
SELECT pg_temp.rd_assert(public.save_grn(p_gr_no=>'K0007',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'ca'::uuid,p_customer_name=>'Decision Customer A',
 p_pricing_mode=>'MONTHLY',p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',1,'SERIES-2')))->>'success'='true','GRN K0007, entered last');
SELECT public.get_next_grn_number() AS next_after_older_letter \gset
SELECT pg_temp.rd_assert(public.save_grn(p_gr_no=>'M1000',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'ca'::uuid,p_customer_name=>'Decision Customer A',
 p_pricing_mode=>'MONTHLY',p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',1,'SERIES-3')))->>'success'='true','GRN M1000');
SELECT public.get_next_grn_number() AS next_after_full_series \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'next_after_older_letter'='M0002','K0007 entered after M0001: the suggestion follows the highest letter M (M0002), not the last-entered K (K0008): '||:'next_after_older_letter');
SELECT pg_temp.rd_assert(:'next_after_full_series'='N0001','with M1000 in use the series is full: the next letter N starts at N0001: '||:'next_after_full_series');

-- ===========================================================================
-- D10 and D24: a GRN-only rate dropped by an edit. DG8: customer A, potatoes 10 bags of weight 10 with the GRN-only rate band 0 to 10.
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'DG8',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'ca'::uuid,p_customer_name=>'Decision Customer A',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',10,'DG8-P')),
 p_rates=>jsonb_build_array(jsonb_build_object('scope','grn','item_id',:'potatoes','weight_min',0,'weight_max',10,'unit_price',7,'labour_rate',2,'tax_percent',5))) AS g8 \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'g8'::jsonb->>'success'='true','DG8 with a GRN-only rate: '||:'g8');
SELECT id AS grn_8 FROM public.goodsreceived WHERE gr_no='DG8' \gset
SELECT pg_temp.rd_assert((SELECT count(*)=1 FROM public.grn_rates WHERE gr_id=:'grn_8'::uuid),'DG8 holds one GRN-only rate');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rd_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT public.update_grn(p_grn_id=>:'grn_8'::uuid,p_items=>pg_temp.rd_lines(:'grn_8'::uuid,'{"weight":20}')) AS staff_drop \gset
SELECT public.update_grn(p_grn_id=>:'grn_8'::uuid,p_note=>'staff note only',p_items=>pg_temp.rd_lines(:'grn_8'::uuid)) AS staff_note \gset
SELECT public.update_grn(p_grn_id=>:'grn_8'::uuid,p_items=>pg_temp.rd_lines(:'grn_8'::uuid,'{"weight":9}')) AS staff_inside \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'staff_drop'::jsonb->>'success'='false' AND :'staff_drop'::jsonb->>'reason'='RATES_NEED_MANAGER' AND :'staff_drop'::jsonb->>'gr_no'='DG8'
 AND (:'staff_drop'::jsonb->>'rates')::int=1 AND :'staff_drop'::jsonb->'items'='["Decision Potatoes"]'::jsonb
 AND :'staff_drop'::jsonb->>'message'='Ask a manager to make this change: it would remove a rate that was set for this GRN.',
 'D10: a staff edit that would drop the GRN-only rate: RATES_NEED_MANAGER: '||:'staff_drop');
SELECT pg_temp.rd_assert(:'staff_note'::jsonb->>'success'='true' AND :'staff_inside'::jsonb->>'success'='true'
 AND (SELECT weight=9 FROM public.goodsreceived_trl WHERE gr_id=:'grn_8'::uuid) AND (SELECT count(*)=1 FROM public.grn_rates WHERE gr_id=:'grn_8'::uuid),
 'D10 twin: a staff note edit and a weight change inside the rate band (10 to 9) are saved, the rate stays: '||:'staff_note'||:'staff_inside');
SELECT pg_temp.rd_assert((SELECT weight=9 FROM public.goodsreceived_trl WHERE gr_id=:'grn_8'::uuid),'the refused staff edit changed no weight (9 is from the allowed edit)');
-- Managers: refused unless the same save sends a rate for the new weight
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_8'::uuid,p_items=>pg_temp.rd_lines(:'grn_8'::uuid,'{"weight":20}')) AS admin_drop \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rd_assert(warehouse_security.active_role()='supervisor','actual supervisor role');
SELECT public.update_grn(p_grn_id=>:'grn_8'::uuid,p_items=>pg_temp.rd_lines(:'grn_8'::uuid,'{"weight":20}')) AS supervisor_drop \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'admin_drop'::jsonb->>'success'='false' AND :'admin_drop'::jsonb->>'reason'='RATES_WOULD_DROP' AND :'supervisor_drop'::jsonb->>'reason'='RATES_WOULD_DROP'
 AND :'admin_drop'::jsonb->>'message'='This change removes the rate set for this GRN. Set a new rate in Rates.' AND :'admin_drop'::jsonb->'items'='["Decision Potatoes"]'::jsonb
 AND (SELECT weight=9 FROM public.goodsreceived_trl WHERE gr_id=:'grn_8'::uuid) AND (SELECT count(*)=1 AND bool_and(weight_max=10) FROM public.grn_rates WHERE gr_id=:'grn_8'::uuid),
 'D24: an administrator''s and a supervisor''s weight edit that drops the rate: RATES_WOULD_DROP, weight and rate unchanged: '||:'admin_drop'||:'supervisor_drop');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_8'::uuid,p_items=>pg_temp.rd_lines(:'grn_8'::uuid,'{"weight":20}'),
 p_rates=>jsonb_build_array(jsonb_build_object('scope','grn','item_id',:'potatoes','weight_min',0,'weight_max',50,'unit_price',6,'labour_rate',2,'tax_percent',5))) AS admin_new_rate \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'admin_new_rate'::jsonb->>'success'='true' AND (SELECT weight=20 FROM public.goodsreceived_trl WHERE gr_id=:'grn_8'::uuid)
 AND (SELECT count(*)=1 AND bool_and(weight_max=50 AND unit_price=6) FROM public.grn_rates WHERE gr_id=:'grn_8'::uuid),
 'D24 twin: the same weight edit with a new rate in the same save is accepted and the rate is replaced: '||:'admin_new_rate');

-- ===========================================================================
-- D11: removing a GRN line. DG9, customer C: line 1 dispatched before, line 2 on the order, line 3 untouched.
-- ===========================================================================
CREATE FUNCTION pg_temp.rd_lines_without(p_grn uuid, p_mark text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT COALESCE(jsonb_agg(e),'[]'::jsonb) FROM jsonb_array_elements(pg_temp.rd_lines(p_grn)) e WHERE e->>'package_mark' IS DISTINCT FROM p_mark $$;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rd_assert(public.save_grn(p_gr_no=>'DG9',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'cc'::uuid,p_customer_name=>'Decision Customer C',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',10,'DG9-1'),pg_temp.rd_new_line(:'onions','Decision Onions',10,'DG9-2'),
   pg_temp.rd_new_line(:'potatoes','Decision Potatoes',10,'DG9-3')))->>'success'='true','receipt DG9');
RESET ROLE;
SELECT id AS grn_9 FROM public.goodsreceived WHERE gr_no='DG9' \gset
SELECT id AS lot_91 FROM public.goodsreceived_trl WHERE package_mark='DG9-1' \gset
SELECT id AS lot_92 FROM public.goodsreceived_trl WHERE package_mark='DG9-2' \gset
SELECT id AS lot_93 FROM public.goodsreceived_trl WHERE package_mark='DG9-3' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','DD9A','disp_date','2026-05-02','customer_id',:'cc','customer_name','Decision Customer C',
 'supervisor_id',:'admin_profile','supervisor_name','Decision Administrator'),ARRAY[jsonb_build_object('gr_trl_id',:'lot_91','disp_qty',3)],0,'rd-dd9a') AS d9a \gset
SELECT public.get_or_create_cart(:'cc'::uuid) AS cart_c \gset
SELECT public.add_item_to_order(:'cart_c'::uuid,:'lot_92'::uuid,2)#>>'{data,order_item_id}' AS line_92 \gset
SELECT public.update_grn(p_grn_id=>:'grn_9'::uuid,p_items=>pg_temp.rd_lines_without(:'grn_9'::uuid,'DG9-1')) AS remove_dispatched \gset
SELECT public.update_grn(p_grn_id=>:'grn_9'::uuid,p_items=>pg_temp.rd_lines_without(:'grn_9'::uuid,'DG9-2')) AS remove_ordered \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'d9a'::jsonb->>'success'='true' AND :'remove_dispatched'::jsonb->>'success'='false' AND :'remove_dispatched'::jsonb->>'reason'='LINE_DISPATCHED_BEFORE'
 AND :'remove_dispatched'::jsonb->>'line_id'=:'lot_91' AND :'remove_dispatched'::jsonb->>'item_name'='Decision Potatoes'
 AND :'remove_dispatched'::jsonb->>'message'='Decision Potatoes was dispatched before, so this line can''t be removed.'
 AND (SELECT count(*)=3 FROM public.goodsreceived_trl WHERE gr_id=:'grn_9'::uuid),'removing a line that was dispatched: LINE_DISPATCHED_BEFORE, three lines remain: '||:'remove_dispatched');
SELECT pg_temp.rd_assert(:'remove_ordered'::jsonb->>'reason'='LINE_ON_ORDER' AND :'remove_ordered'::jsonb->>'line_id'=:'lot_92' AND :'remove_ordered'::jsonb->>'customer_name'='Decision Customer C'
 AND :'remove_ordered'::jsonb->>'message'='Decision Onions is on Decision Customer C''s order. Remove it from the order first.'
 AND (SELECT count(*)=3 FROM public.goodsreceived_trl WHERE gr_id=:'grn_9'::uuid),'removing a line that is on an order: LINE_ON_ORDER naming the customer: '||:'remove_ordered');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_9'::uuid,p_items=>pg_temp.rd_lines_without(:'grn_9'::uuid,'DG9-3')) AS remove_plain \gset
SELECT public.remove_item_from_order(:'line_92'::uuid) AS unorder \gset
SELECT public.update_grn(p_grn_id=>:'grn_9'::uuid,p_items=>pg_temp.rd_lines_without(:'grn_9'::uuid,'DG9-2')) AS remove_after_unorder \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'remove_plain'::jsonb->>'success'='true' AND :'unorder'::jsonb->>'success'='true' AND :'remove_after_unorder'::jsonb->>'success'='true'
 AND (SELECT count(*)=1 AND bool_and(id=:'lot_91'::uuid) FROM public.goodsreceived_trl WHERE gr_id=:'grn_9'::uuid),
 'twins: an untouched line is removed, and the ordered line once it is off the order: only the dispatched line is left: '||:'remove_plain'||:'remove_after_unorder');

-- ===========================================================================
-- D12: audit rows of GRN edits and deletes. DG10: customer A, potatoes 10 and onions 5.
-- ===========================================================================
CREATE FUNCTION pg_temp.rd_audit_grn(p_action text, p_grn uuid) RETURNS integer LANGUAGE sql AS $$
  SELECT count(*)::integer FROM public.audit_log WHERE table_name='goodsreceived' AND action=p_action AND COALESCE(new_data,old_data)->>'id'=p_grn::text $$;
CREATE FUNCTION pg_temp.rd_audit_trl(p_action text, p_grn uuid) RETURNS integer LANGUAGE sql AS $$
  SELECT count(*)::integer FROM public.audit_log WHERE table_name='goodsreceived_trl' AND action=p_action AND COALESCE(new_data,old_data)->>'gr_id'=p_grn::text $$;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'DG10',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'ca'::uuid,p_customer_name=>'Decision Customer A',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',10,'DG10-P'),pg_temp.rd_new_line(:'onions','Decision Onions',5,'DG10-O'))) AS g10 \gset
RESET ROLE;
SELECT id AS grn_10 FROM public.goodsreceived WHERE gr_no='DG10' \gset
SELECT id AS lot_10p FROM public.goodsreceived_trl WHERE package_mark='DG10-P' \gset
SELECT id AS lot_10o FROM public.goodsreceived_trl WHERE package_mark='DG10-O' \gset
SELECT pg_temp.rd_assert(:'g10'::jsonb->>'success'='true' AND pg_temp.rd_audit_grn('INSERT',:'grn_10'::uuid)=1 AND pg_temp.rd_audit_trl('INSERT',:'grn_10'::uuid)=2
 AND (SELECT bool_and(user_id=:'admin_sub'::uuid) FROM public.audit_log WHERE table_name IN ('goodsreceived','goodsreceived_trl') AND action='INSERT' AND COALESCE(new_data,old_data)->>'id' IN (:'grn_10',:'lot_10p',:'lot_10o')),
 'a new GRN writes one INSERT row for it and one for each of its two lines, with the saving user');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_10'::uuid,p_note=>'audit note',p_items=>pg_temp.rd_lines(:'grn_10'::uuid)) AS g10_note \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'g10_note'::jsonb->>'success'='true' AND pg_temp.rd_audit_grn('UPDATE',:'grn_10'::uuid)=1 AND pg_temp.rd_audit_trl('UPDATE',:'grn_10'::uuid)=0
 AND (SELECT old_data->>'note' IS NULL AND new_data->>'note'='audit note' AND user_id=:'admin_sub'::uuid FROM public.audit_log
      WHERE table_name='goodsreceived' AND action='UPDATE' AND new_data->>'id'=:'grn_10'),
 'a note edit writes one UPDATE row of the GRN (old and new note, the editing user) and none of the lines');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_10'::uuid,p_note=>'audit note',p_items=>pg_temp.rd_lines(:'grn_10'::uuid,'{"weight":12}','DG10-P')) AS g10_weight \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'g10_weight'::jsonb->>'success'='true' AND pg_temp.rd_audit_trl('UPDATE',:'grn_10'::uuid)=1 AND pg_temp.rd_audit_grn('UPDATE',:'grn_10'::uuid)=1
 AND (SELECT (old_data->>'weight')::int=10 AND (new_data->>'weight')::int=12 FROM public.audit_log WHERE table_name='goodsreceived_trl' AND action='UPDATE' AND new_data->>'id'=:'lot_10p'),
 'a weight edit writes one UPDATE row of that line (10 to 12); the same note sent again wrote no GRN row: '||:'g10_weight');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_10'::uuid,p_note=>'audit note',p_items=>pg_temp.rd_lines(:'grn_10'::uuid)) AS g10_again \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'g10_again'::jsonb->>'success'='true' AND pg_temp.rd_audit_trl('UPDATE',:'grn_10'::uuid)=1 AND pg_temp.rd_audit_grn('UPDATE',:'grn_10'::uuid)=1,
 'an edit that sends the stored values again writes no row: '||:'g10_again');
-- Every dispatch moves the stock of a line, and the last one flips the GRN's out_of_stock flag: neither is audited.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb||'{"disp_no":"DD10"}'::jsonb,
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_10p','disp_qty',10),jsonb_build_object('gr_trl_id',:'lot_10o','disp_qty',5)],0,'rd-dd10') AS d10 \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'d10'::jsonb->>'success'='true' AND (SELECT out_of_stock FROM public.goodsreceived WHERE id=:'grn_10'::uuid)
 AND (SELECT bool_and(stock=0) FROM public.goodsreceived_trl WHERE gr_id=:'grn_10'::uuid)
 AND pg_temp.rd_audit_trl('UPDATE',:'grn_10'::uuid)=1 AND pg_temp.rd_audit_grn('UPDATE',:'grn_10'::uuid)=1,
 'a dispatch that empties the GRN (stock and out_of_stock change) writes no audit row: '||:'d10');
-- A delete keeps a copy of the GRN and each line.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'DG11',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'ca'::uuid,p_customer_name=>'Decision Customer A',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',4,'DG11-P'),pg_temp.rd_new_line(:'onions','Decision Onions',2,'DG11-O'))) AS g11 \gset
RESET ROLE;
SELECT id AS grn_11 FROM public.goodsreceived WHERE gr_no='DG11' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.delete_grn_safe(:'grn_11'::uuid) AS g11_deleted \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'g11_deleted'::jsonb->>'success'='true' AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE id=:'grn_11'::uuid)
 AND pg_temp.rd_audit_grn('DELETE',:'grn_11'::uuid)=1 AND pg_temp.rd_audit_trl('DELETE',:'grn_11'::uuid)=2
 AND (SELECT old_data->>'gr_no'='DG11' AND user_id=:'admin_sub'::uuid FROM public.audit_log WHERE table_name='goodsreceived' AND action='DELETE' AND old_data->>'id'=:'grn_11'),
 'deleting a GRN (still a hard delete) keeps one DELETE row of the GRN and one per line: '||:'g11_deleted');

-- ===========================================================================
-- D13 and D15: lengths and digits
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'DG12',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'ca'::uuid,p_customer_name=>'Decision Customer A',p_pricing_mode=>'MONTHLY',
 p_registration=>repeat('R',21),p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',4,'DG12-P'))) AS reg_long \gset
SELECT public.save_grn(p_gr_no=>'DG12',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'ca'::uuid,p_customer_name=>'Decision Customer A',p_pricing_mode=>'MONTHLY',
 p_registration=>repeat('R',20),p_items=>jsonb_build_array(
   pg_temp.rd_new_line(:'potatoes','Decision Potatoes',4,U&'\0AE7\0AE8')||jsonb_build_object('rack',U&'R\0AE7','package_mark',U&'\0AE7\0AE8'))) AS reg_ok \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'reg_long'::jsonb->>'success'='false' AND :'reg_long'::jsonb->>'error_code'='registration_too_long' AND (:'reg_long'::jsonb#>>'{data,limit}')::int=20
 AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='DG12' AND registration=repeat('R',21)),'save_grn with a 21-character registration: registration_too_long, limit 20: '||:'reg_long');
SELECT pg_temp.rd_assert(:'reg_ok'::jsonb->>'success'='true' AND (SELECT registration=repeat('R',20) FROM public.goodsreceived WHERE gr_no='DG12'),'twin: 20 characters are saved: '||:'reg_ok');
SELECT id AS grn_12 FROM public.goodsreceived WHERE gr_no='DG12' \gset
SELECT pg_temp.rd_assert((SELECT rack='R1' AND package_mark='12' FROM public.goodsreceived_trl WHERE gr_id=:'grn_12'::uuid),
 'D15: Gujarati digits in the rack and the package mark are stored as 0-9 by save_grn: '||(SELECT rack||'/'||package_mark FROM public.goodsreceived_trl WHERE gr_id=:'grn_12'::uuid));
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'grn_12'::uuid,p_registration=>repeat('R',21),p_items=>pg_temp.rd_lines(:'grn_12'::uuid)) AS upd_reg_long \gset
SELECT public.update_grn(p_grn_id=>:'grn_12'::uuid,p_registration=>repeat('Q',20),
 p_items=>pg_temp.rd_lines(:'grn_12'::uuid,jsonb_build_object('rack',U&'\0967\0968','package_mark',U&'\0663\06F4'))) AS upd_reg_ok \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'upd_reg_long'::jsonb->>'error_code'='registration_too_long' AND (:'upd_reg_long'::jsonb#>>'{data,limit}')::int=20
 AND (SELECT registration=repeat('Q',20) FROM public.goodsreceived WHERE id=:'grn_12'::uuid),'update_grn with 21 characters: registration_too_long; 20 are saved (twin): '||:'upd_reg_long'||:'upd_reg_ok');
SELECT pg_temp.rd_assert(:'upd_reg_ok'::jsonb->>'success'='true' AND (SELECT rack='12' AND package_mark='34' FROM public.goodsreceived_trl WHERE gr_id=:'grn_12'::uuid),
 'D15: Devanagari and Arabic-Indic digits are stored as 0-9 by update_grn: '||(SELECT rack||'/'||package_mark FROM public.goodsreceived_trl WHERE gr_id=:'grn_12'::uuid));

-- ===========================================================================
-- D16: a deactivated business is still dispatched and may still order; a new GRN is refused. DG13: customer D, potatoes 20.
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rd_assert(public.save_grn(p_gr_no=>'DG13',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'cd'::uuid,p_customer_name=>'Decision Customer D',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',20,'DG13-P'),pg_temp.rd_new_line(:'onions','Decision Onions',20,'DG13-O')))->>'success'='true','receipt DG13');
RESET ROLE;
SELECT id AS lot_13p FROM public.goodsreceived_trl WHERE package_mark='DG13-P' \gset
SELECT id AS lot_13o FROM public.goodsreceived_trl WHERE package_mark='DG13-O' \gset
UPDATE public.customers SET active=false WHERE id=:'cd'::uuid;
SELECT jsonb_build_object('disp_date','2026-05-02','customer_id',:'cd','customer_name','Decision Customer D','supervisor_id',:'admin_profile','supervisor_name','Decision Administrator') AS for_d \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'for_d'::jsonb||'{"disp_no":"DD13"}'::jsonb,ARRAY[jsonb_build_object('gr_trl_id',:'lot_13p','disp_qty',5)],0,'rd-dd13') AS d13 \gset
SELECT public.update_dispatch_smart((:'d13'::jsonb->>'dispatch_id')::uuid,jsonb_build_object('note','for a deactivated business'),ARRAY[jsonb_build_object('gr_trl_id',:'lot_13p','disp_qty',6)]) AS d13_edit \gset
SELECT public.get_or_create_cart(:'cd'::uuid) AS cart_d \gset
SELECT public.add_item_to_order(:'cart_d'::uuid,:'lot_13o'::uuid,3) AS d_add \gset
SELECT public.update_order_item_quantity((:'d_add'::jsonb#>>'{data,order_item_id}')::uuid,4) AS d_change \gset
SELECT public.delete_dispatch_with_order_cleanup((:'d13'::jsonb->>'dispatch_id')::uuid,:'admin_profile'::uuid) AS d13_delete \gset
SELECT pg_temp.rd_raises(format($q$SELECT public.save_grn(p_gr_no=>'DG13B',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>%L::uuid,p_customer_name=>'Decision Customer D',p_pricing_mode=>'MONTHLY',
 p_items=>%L::jsonb)$q$,:'cd',jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',1,'DG13-N'))::text),'%deactivated%') AS d_new_grn_refused \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'d13'::jsonb->>'success'='true' AND :'d13_edit'::jsonb->>'success'='true' AND :'d13_delete'::jsonb->>'success'='true',
 'D16: a dispatch of a deactivated business is created, edited and deleted: '||:'d13'||:'d13_edit'||:'d13_delete');
SELECT pg_temp.rd_assert(:'d_add'::jsonb->>'success'='true' AND :'d_change'::jsonb->>'success'='true' AND (SELECT requested_quantity=4 FROM public.order_items WHERE order_id=:'cart_d'::uuid AND grn_items_id=:'lot_13o'::uuid),
 'D16: a deactivated business may still add to its order and change a line: '||:'d_add'||:'d_change');
SELECT pg_temp.rd_assert(:'d_new_grn_refused'::boolean AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no='DG13B'),
 'D16 twin: a new GRN for the deactivated business is refused with the deactivated text and saves nothing');

-- ===========================================================================
-- D18: the confirmed total is checked by the server; a refusal rolls the save back
-- ===========================================================================
SELECT total AS total_i, discount AS discount_i, updated_at AS tok_total FROM public.invoice WHERE id=:'invoice_i'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_invoice(:'invoice_i'::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',92001,'gr_id',:'grn_i','gr_no','DGI','notes','total check','discount',3,'expected_total',:total_i+50),
 ARRAY[:'line_i2'::jsonb]) AS total_refused \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'total_refused'::jsonb->>'success'='false' AND :'total_refused'::jsonb->>'reason'='TOTAL_CHANGED' AND :'total_refused'::jsonb->>'error_code'='WH409'
 AND (:'total_refused'::jsonb->>'expected_total')::numeric=:total_i+50 AND (:'total_refused'::jsonb->>'current_total')::numeric=:total_i-3
 AND jsonb_array_length(:'total_refused'::jsonb->'lines')=1 AND (:'total_refused'::jsonb#>>'{lines,0,duration}')::numeric=(SELECT it.duration FROM public.invoice_trl it WHERE it.invoice_id=:'invoice_i'::uuid)
 AND :'total_refused'::jsonb#>>'{lines,0,disp_trl_id}' IS NOT NULL AND :'total_refused'::jsonb#>'{lines,0}' ? 'no_of_days'
 AND (SELECT discount=:discount_i AND total=:total_i AND notes IS DISTINCT FROM 'total check' FROM public.invoice WHERE id=:'invoice_i'::uuid),
 'D18: an invoice edit whose total (with the new discount of 3) is not the confirmed one: TOTAL_CHANGED with the recomputed lines, and the discount, total and notes are rolled back: '||:'total_refused');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_invoice(:'invoice_i'::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',92001,'gr_id',:'grn_i','gr_no','DGI','notes','total ok','discount',3,'expected_total',:total_i-3+0.5),
 ARRAY[:'line_i2'::jsonb]) AS total_ok \gset
SELECT public.update_invoice(:'invoice_i'::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',92001,'gr_id',:'grn_i','gr_no','DGI','notes','no expected total','discount',0),
 ARRAY[:'line_i2'::jsonb]) AS total_none \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'total_ok'::jsonb->>'success'='true' AND :'total_none'::jsonb->>'success'='true' AND (SELECT notes='no expected total' AND discount=0 AND total=:total_i FROM public.invoice WHERE id=:'invoice_i'::uuid),
 'D18 twins: a total within 1.00 of the confirmed one is saved; no expected_total is not checked (an older app): '||:'total_ok'||:'total_none');
-- The 3-argument save: refused, nothing saved; then saved with the total the refusal named
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.rd_assert(public.save_grn(p_gr_no=>'DG14',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'ca'::uuid,p_customer_name=>'Decision Customer A',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(pg_temp.rd_new_line(:'potatoes','Decision Potatoes',6,'DG14-P')))->>'success'='true','receipt DG14');
RESET ROLE;
SELECT id AS grn_14 FROM public.goodsreceived WHERE gr_no='DG14' \gset
SELECT id AS lot_14 FROM public.goodsreceived_trl WHERE gr_id=:'grn_14'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'for_a'::jsonb||'{"disp_no":"DD14"}'::jsonb,ARRAY[jsonb_build_object('gr_trl_id',:'lot_14','disp_qty',6)],0,'rd-dd14') AS d14 \gset
RESET ROLE;
SELECT jsonb_build_object('disp_trl_id',dt.id,'grn_item_id',dt.gr_trl_id,'duration',1,'charge',10,'tax',0,'labour_rate',2) AS line_14 FROM public.dispatch_trl dt WHERE dt.disp_id=(:'d14'::jsonb->>'dispatch_id')::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_invoice(NULL::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',92014,'gr_id',:'grn_14','gr_no','DG14','expected_total',1),ARRAY[:'line_14'::jsonb]) AS save_total_refused \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'save_total_refused'::jsonb->>'reason'='TOTAL_CHANGED' AND (:'save_total_refused'::jsonb->>'expected_total')::numeric=1 AND (:'save_total_refused'::jsonb->>'current_total')::numeric>1
 AND NOT EXISTS (SELECT 1 FROM public.invoice WHERE gr_id=:'grn_14'::uuid) AND NOT (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn_14'::uuid),
 'D18: the 3-argument save with a wrong confirmed total: TOTAL_CHANGED, no invoice, the GRN not invoiced: '||:'save_total_refused');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_invoice(NULL::uuid,:'inv_base'::jsonb||jsonb_build_object('inv_no',92014,'gr_id',:'grn_14','gr_no','DG14','expected_total',(:'save_total_refused'::jsonb->>'current_total')::numeric),ARRAY[:'line_14'::jsonb]) AS save_total_ok \gset
RESET ROLE;
SELECT pg_temp.rd_assert(:'save_total_ok'::jsonb->>'success'='true' AND (SELECT invoiced FROM public.goodsreceived WHERE id=:'grn_14'::uuid)
 AND (SELECT total=(:'save_total_refused'::jsonb->>'current_total')::numeric FROM public.invoice WHERE gr_id=:'grn_14'::uuid),
 'D18 twin: with the total the refusal named, the save goes through: '||:'save_total_ok');
