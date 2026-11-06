-- Migration 149 (WH-96): an invoice whose GRN number or dispatch number is longer than 8 characters can be cancelled.
-- The numbering rule allows up to 20 characters (migration 127; the "year" scheme gives "26-27/0001"), and cancel_invoice copies both numbers
-- to the kept_* columns of each line, which migration 143 had made 8 wide: the copy raised 22001 and the cancel answered a failure.
--   * a 9-character pair and a 20-character pair of numbers: the cancel succeeds and the invoice is cancelled;
--   * the kept copy holds both numbers in full, and get_invoice_detail and get_invoice_data show them.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.l_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'kept long numbers 149: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.l_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.l_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.l_assert(l#>>'{data,action}'='login','login for '||phone);
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
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='KLTEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9877777761','Long Number Test Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT pg_temp.l_login('9877777761') AS admin_claims \gset

-- Fixture: one customer and item; two receipts of 20 bags, each dispatched in full and invoiced. The first pair of numbers is
-- 9 characters long (one past the old width), the second 20 (the most the numbering rule allows, in the form of the year scheme).
\set grn9 'KLG000001'
\set disp9 'KLD000001'
\set grn20 '26-27/00000000001234'
\set disp20 'D26-27/0000000005678'
SELECT pg_temp.l_assert(length(:'grn9')=9 AND length(:'disp9')=9 AND length(:'grn20')=20 AND length(:'disp20')=20,'the fixture numbers are 9 and 20 characters long');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.l_assert(public.create_customer('Long Number Test North','9877777763')->>'success'='true','customer');
SELECT pg_temp.l_assert(public.create_item('Long Number Test Garlic','Bag')->>'success'='true','item');
SELECT id AS north FROM public.customers WHERE name='Long Number Test North' \gset
SELECT id AS item_id FROM public.items WHERE name='Long Number Test Garlic' \gset
SELECT pg_temp.l_assert(public.replace_item_rates(:'item_id'::uuid,:'north'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5)))->>'success'='true','price');
SELECT pg_temp.l_assert(public.save_grn(p_gr_no=>n.no::varchar,p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'north'::uuid,
 p_customer_name=>'Long Number Test North',p_pricing_mode=>'ONE_TIME',p_idempotency_key=>'long-grn-'||n.no,
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Long Number Test Garlic','packaging','Bag','qty',20,'weight',10,
   'rack','L-'||n.k,'package_mark','M-'||n.k)))->>'success'='true','receipt '||n.no)
FROM (VALUES ('9',:'grn9'),('20',:'grn20')) n(k,no);
SELECT id AS g9 FROM public.goodsreceived WHERE gr_no=:'grn9' \gset
SELECT id AS g20 FROM public.goodsreceived WHERE gr_no=:'grn20' \gset
SELECT pg_temp.l_assert(public.create_dispatch_with_stock_check(jsonb_build_object('customer_id',:'north','customer_name','Long Number Test North',
 'supervisor_id',:'admin_profile','supervisor_name','Long Number Test Administrator','disp_date','2026-05-02','disp_no',n.no),
 ARRAY[jsonb_build_object('gr_trl_id',(SELECT t.id FROM public.goodsreceived_trl t WHERE t.gr_id=n.g::uuid),'disp_qty',20)],0,'long-dispatch-'||n.no)->>'success'='true','dispatch '||n.no)
FROM (VALUES (:'disp9',:'g9'),(:'disp20',:'g20')) n(no,g);
SELECT pg_temp.l_assert(public.save_invoice(NULL::uuid,
 jsonb_build_object('inv_fin_year',2026,'inv_no',n.no,'customer_id',:'north','customer_name','Long Number Test North',
  'inv_date','2026-05-02T12:00:00Z','total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy','gr_id',n.g,'gr_no',n.gno),
 ARRAY(SELECT jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2)
       FROM public.dispatch_trl t WHERE t.gr_id=n.g::uuid))->>'success'='true','save invoice '||n.no)
FROM (VALUES (31,:'g9',:'grn9'),(32,:'g20',:'grn20')) n(no,g,gno);
RESET ROLE;
SELECT id AS inv9 FROM public.invoice WHERE inv_no=31 AND inv_fin_year=2026 \gset
SELECT id AS inv20 FROM public.invoice WHERE inv_no=32 AND inv_fin_year=2026 \gset
SELECT pg_temp.l_assert((SELECT count(*)=2 AND bool_and(details_kept_at IS NULL AND kept_grn_no IS NULL AND kept_disp_no IS NULL)
  FROM public.invoice_trl WHERE invoice_id IN (:'inv9'::uuid,:'inv20'::uuid)),'fixture: one line on each invoice, no copy while live');
SELECT updated_at AS token9 FROM public.invoice WHERE id=:'inv9'::uuid \gset
SELECT updated_at AS token20 FROM public.invoice WHERE id=:'inv20'::uuid \gset

-- Cancel both. Before migration 149 each answered success false with error_code 22001.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.cancel_invoice(:'inv9'::uuid,'Entered twice',:'token9'::timestamptz) AS r9 \gset
SELECT public.cancel_invoice(:'inv20'::uuid,'Entered twice',:'token20'::timestamptz) AS r20 \gset
RESET ROLE;
SELECT pg_temp.l_assert(:'r9'::jsonb->>'success'='true','cancel succeeds with 9-character GRN and dispatch numbers: '||:'r9');
SELECT pg_temp.l_assert(:'r20'::jsonb->>'success'='true','cancel succeeds with 20-character GRN and dispatch numbers: '||:'r20');
SELECT pg_temp.l_assert((SELECT count(*)=2 AND bool_and(cancelled_at IS NOT NULL) FROM public.invoice WHERE id IN (:'inv9'::uuid,:'inv20'::uuid)),'both invoices are cancelled');
SELECT pg_temp.l_assert((SELECT count(*)=1 AND bool_and(details_kept_at IS NOT NULL AND kept_grn_no=:'grn9' AND kept_disp_no=:'disp9')
  FROM public.invoice_trl WHERE invoice_id=:'inv9'::uuid),'the kept copy holds both 9-character numbers in full');
SELECT pg_temp.l_assert((SELECT count(*)=1 AND bool_and(details_kept_at IS NOT NULL AND kept_grn_no=:'grn20' AND kept_disp_no=:'disp20')
  FROM public.invoice_trl WHERE invoice_id=:'inv20'::uuid),'the kept copy holds both 20-character numbers in full');

-- The readers show the full numbers of the cancelled invoice.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_detail(:'inv20'::uuid) AS d20 \gset
SELECT public.get_invoice_data(:'inv20'::uuid) AS dd20 \gset
RESET ROLE;
SELECT pg_temp.l_assert(jsonb_array_length(:'d20'::jsonb->'items')=1 AND :'d20'::jsonb#>>'{items,0,dispatch_no}'=:'disp20'
  AND :'d20'::jsonb#>>'{items,0,grn_no}'=:'grn20' AND (:'d20'::jsonb#>>'{items,0,details_available}')='true',
  'get_invoice_detail shows the 20-character numbers: '||:'d20');
SELECT pg_temp.l_assert(jsonb_array_length(:'dd20'::jsonb#>'{data,items}')=1 AND :'dd20'::jsonb#>>'{data,items,0,dispatch,disp_no}'=:'disp20'
  AND :'dd20'::jsonb#>>'{data,items,0,grn_item,gr_no}'=:'grn20',
  'get_invoice_data shows the 20-character numbers: '||:'dd20');

-- The widths behind it: the numbers and their kept copies are all 20 wide, so a later change to one side shows here.
SELECT pg_temp.l_assert((SELECT count(*)=4 AND bool_and(character_maximum_length=20) FROM information_schema.columns
  WHERE table_schema='public' AND ((table_name='goodsreceived' AND column_name='gr_no') OR (table_name='dispatch' AND column_name='disp_no')
    OR (table_name='invoice_trl' AND column_name IN ('kept_grn_no','kept_disp_no')))),
  'gr_no, disp_no and both kept columns are 20 characters wide');
ROLLBACK;
