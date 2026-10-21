-- Migration 48, owner decision 3 of 2026-10-11: an invoice line may have a
-- storage charge of 0, with a reason. Staff must give one on every write while
-- a line has a zero charge; administrators and supervisors may leave it empty;
-- with no zero-charge line the reason is stored as NULL whatever was sent. The
-- invoice records the reason, the profile and the time whenever the reason or
-- the set of zero-charge lines changes, each change is appended to
-- invoice_zero_charge_history, and get_invoice_detail returns the record to
-- the warehouse roles. Checked on save_invoice(uuid,jsonb,jsonb[]) and update_invoice. Fictional data; runs
-- only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.zc_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'zero charge reason: %',label; END IF; END $$;
-- True when the statement raises an error whose text matches the pattern.
CREATE FUNCTION pg_temp.zc_raises(statement text, pattern text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM LIKE pattern; END;
  RETURN false;
END $$;
-- Every line with other rates; one line (0 = the first) with other rates.
CREATE FUNCTION pg_temp.zc_rates(items jsonb, rates jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(item || rates) FROM jsonb_array_elements(items) AS item $$;
CREATE FUNCTION pg_temp.zc_line(items jsonb, line integer, rates jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_set(items, ARRAY[line::text], (items->line) || rates) $$;
-- Since migration 123 there is one save path: zc_save1 is the call the one-argument save_invoice(jsonb) used to take, now made the app's way.
CREATE FUNCTION pg_temp.zc_save1(header jsonb, items jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, header, ARRAY(SELECT jsonb_array_elements(items))) $$;
CREATE FUNCTION pg_temp.zc_save3(header jsonb, items jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, header, ARRAY(SELECT jsonb_array_elements(items))) $$;
CREATE FUNCTION pg_temp.zc_update(invoice uuid, header jsonb, items jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.update_invoice(invoice, header, ARRAY(SELECT jsonb_array_elements(items))) $$;
-- What the invoice records, and its history as [old reason, new reason, zero
-- lines before, zero lines after, profile, role] per change, oldest first.
CREATE FUNCTION pg_temp.zc_record(invoice uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('reason',i.zero_charge_reason,'by',i.zero_charge_set_by,'at',i.zero_charge_set_at)
  FROM public.invoice i WHERE i.id=invoice $$;
CREATE FUNCTION pg_temp.zc_history(invoice uuid) RETURNS jsonb LANGUAGE sql AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_array(h.old_reason,h.new_reason,cardinality(h.old_lines),cardinality(h.new_lines),h.changed_by,h.changed_by_role) ORDER BY h.id),'[]'::jsonb)
  FROM public.invoice_zero_charge_history h WHERE h.invoice_id=invoice $$;
CREATE FUNCTION pg_temp.zc_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.zc_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.zc_assert(l#>>'{data,action}'='login','login for '||phone);
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
SELECT warehouse_security.bootstrap_first_admin('9888888881','Zero Charge Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888882','Zero Charge Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888883','Zero Charge Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888884','Zero Charge Second Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888885','Zero Charge Customer Reader','customer',true,'approved');
SELECT id AS supervisor_profile FROM public.user_profiles WHERE mobile='919888888882' \gset
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile='919888888883' \gset
SELECT id AS staff2_profile FROM public.user_profiles WHERE mobile='919888888884' \gset
SELECT pg_temp.zc_login('9888888881') AS admin_claims \gset
SELECT pg_temp.zc_login('9888888882') AS supervisor_claims \gset
SELECT pg_temp.zc_login('9888888883') AS staff_claims \gset
SELECT pg_temp.zc_login('9888888884') AS staff2_claims \gset
SELECT pg_temp.zc_login('9888888885') AS customer_claims \gset

-- Fixture, as the administrator. Price 5 per bag, labour 2, tax 5%. Receipts
-- of 1 April 2026, dispatched in full on 2 May (31 days, 1.5 periods):
--   ZCA  monthly, 100 bags, dispatched as 20 + 80: two invoice lines
--   ZCB  one-time, 20 bags
--   ZCC to ZCG  monthly, 10 bags each, one line each
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(public.create_customer('Zero Charge Customer','9888888886')->>'success'='true','customer');
SELECT pg_temp.zc_assert(public.create_item('Zero Charge Onions','Bag')->>'success'='true','catalog item');
SELECT id AS customer_id FROM public.customers WHERE name='Zero Charge Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Zero Charge Onions' \gset
SELECT pg_temp.zc_assert(public.replace_item_rates(:'item_id'::uuid,:'customer_id'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5)))->>'success'='true','monthly price');
SELECT pg_temp.zc_assert(public.save_grn(p_gr_no=>'ZC'||r.code,p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Zero Charge Customer',p_pricing_mode=>r.mode,p_idempotency_key=>'zero-charge-'||r.code,
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Zero Charge Onions',
 'packaging','Bag','qty',r.qty,'weight',10,'rack','R'||r.code)))->>'success'='true','receipt ZC'||r.code)
FROM (VALUES ('A','MONTHLY',100),('B','ONE_TIME',20),('C','MONTHLY',10),('D','MONTHLY',10),('E','MONTHLY',10),
  ('F','MONTHLY',10),('G','MONTHLY',10)) AS r(code,mode,qty);
SELECT jsonb_build_object('customer_id',:'customer_id','customer_name','Zero Charge Customer',
 'supervisor_id',:'admin_profile','supervisor_name','Zero Charge Administrator','disp_date','2026-05-02') AS dispatch_for \gset
SELECT pg_temp.zc_assert(public.create_dispatch_with_stock_check(:'dispatch_for'::jsonb || jsonb_build_object('disp_no','ZC'||d.code||d.part),
 ARRAY[jsonb_build_object('gr_trl_id',(SELECT t.id FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE g.gr_no='ZC'||d.code),
   'disp_qty',d.qty)],0,'zero-charge-'||d.code||d.part)->>'success'='true','dispatch ZC'||d.code||d.part)
FROM (VALUES ('A','1',20),('A','2',80),('B','1',20),('C','1',10),('D','1',10),('E','1',10),('F','1',10),('G','1',10)) AS d(code,part,qty);
RESET ROLE;
-- Per receipt: its id, a header, and its lines at the price-list rates (ZCA's
-- ordered 20 bags, then 80), in the shape every path accepts.
CREATE TEMP TABLE zc_receipt AS
SELECT right(g.gr_no,1) AS code, g.id AS grn_id,
  jsonb_build_object('inv_fin_year',2026,'customer_id',:'customer_id','customer_name','Zero Charge Customer',
   'inv_date','2026-05-02T12:00:00Z','total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy',
   'gr_id',g.id,'gr_no',g.gr_no) AS header,
  (SELECT jsonb_agg(jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',5,'tax',5,'labour_rate',2) ORDER BY t.disp_qty)
   FROM public.dispatch_trl t WHERE t.gr_id=g.id) AS items
FROM public.goodsreceived g WHERE g.gr_no LIKE 'ZC_';
GRANT SELECT ON zc_receipt TO authenticated;
SELECT header AS a_header, items AS a_items, grn_id AS grn_a FROM zc_receipt WHERE code='A' \gset
SELECT header AS b_header, items AS b_items FROM zc_receipt WHERE code='B' \gset
SELECT header AS c_header, items AS c_items FROM zc_receipt WHERE code='C' \gset
SELECT header AS d_header, items AS d_items FROM zc_receipt WHERE code='D' \gset
SELECT header AS e_header, items AS e_items FROM zc_receipt WHERE code='E' \gset
SELECT header AS f_header, items AS f_items, grn_id AS grn_f FROM zc_receipt WHERE code='F' \gset
SELECT header AS g_header, items AS g_items, grn_id AS grn_g FROM zc_receipt WHERE code='G' \gset
SELECT pg_temp.zc_assert(jsonb_array_length(:'a_items'::jsonb)=2 AND jsonb_array_length(:'b_items'::jsonb)=1,'fixture lines');

-- The record: three columns on the invoice, and a history only the database
-- writes.
SELECT pg_temp.zc_assert((SELECT count(*)=3 FROM information_schema.columns WHERE table_schema='public' AND table_name='invoice'
  AND (column_name,data_type) IN (('zero_charge_reason','text'),('zero_charge_set_by','uuid'),('zero_charge_set_at','timestamp with time zone'))),
 'invoice has zero_charge_reason, zero_charge_set_by and zero_charge_set_at');
SELECT pg_temp.zc_assert((SELECT relrowsecurity FROM pg_class WHERE oid='public.invoice_zero_charge_history'::regclass)
 AND NOT has_table_privilege('authenticated','public.invoice_zero_charge_history','INSERT,UPDATE,DELETE,TRUNCATE')
 AND NOT has_table_privilege('service_role','public.invoice_zero_charge_history','INSERT,UPDATE,DELETE,TRUNCATE')
 AND NOT has_table_privilege('anon','public.invoice_zero_charge_history','SELECT')
 AND (SELECT count(*)=0 FROM pg_constraint WHERE conrelid='public.invoice_zero_charge_history'::regclass AND contype='f'),
 'the history has row level security, no write grant and no foreign key');

-- "Blank" means for this reason what it means for the discount reason: every
-- character of the Basic Multilingual Plane is trimmed by one rule exactly when
-- the other trims it (the class is read from migration 41's trigger function).
SELECT pg_temp.zc_assert(discount.blank IS NOT NULL
 AND (SELECT count(*)=0 FROM generate_series(1,65535) AS code
      WHERE code NOT BETWEEN 55296 AND 57343
        AND (warehouse_security.trimmed_reason(chr(code)) IS NULL) IS DISTINCT FROM (chr(code) ~ ('^' || discount.blank || '$')))
 AND (SELECT count(*)>=25 FROM generate_series(1,65535) AS code
      WHERE code NOT BETWEEN 55296 AND 57343 AND warehouse_security.trimmed_reason(chr(code)) IS NULL)
 AND warehouse_security.trimmed_reason(U&' \00A0Kept \200B text\3000 ')=U&'Kept \200B text'
 AND warehouse_security.trimmed_reason(NULL) IS NULL,
 'the zero-charge reason is trimmed of the same characters as the discount reason')
FROM (SELECT substring(pg_get_functiondef('warehouse_security.invoice_discount_audit()'::regprocedure) from $re$blank constant text := '([^']+)'$re$) AS blank) discount;

-- ---------------------------------------------------------------------------
-- 1. Staff, new invoices: a zero charge needs a reason on both save paths
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(warehouse_security.active_role()='staff','actual staff role');
-- The first call: zc_save1 (the call the one-argument save used to take) and zc_save3 now both use the app's save.
SELECT pg_temp.zc_save1(:'a_header'::jsonb || '{"inv_no":20261101}'::jsonb, pg_temp.zc_rates(:'a_items'::jsonb,'{"charge":0}'::jsonb)) AS refused1 \gset
SELECT pg_temp.zc_assert(:'refused1'::jsonb->>'success'='false'
 AND :'refused1'::jsonb->>'error'='Enter a reason for the zero charge',
 'one-argument save: zero charge without a reason refused: '||:'refused1');
-- Three-argument path (the one the app uses): the text and the code as they are.
SELECT pg_temp.zc_save3(:'a_header'::jsonb || '{"inv_no":20261101}'::jsonb, pg_temp.zc_rates(:'a_items'::jsonb,'{"charge":0}'::jsonb)) AS refused3 \gset
SELECT pg_temp.zc_assert(:'refused3'::jsonb->>'success'='false' AND :'refused3'::jsonb->>'error'='Enter a reason for the zero charge'
 AND :'refused3'::jsonb->>'error_code'='22023','three-argument save: zero charge without a reason refused: '||:'refused3');
-- One zero-charge line among two is enough.
SELECT pg_temp.zc_assert(pg_temp.zc_save3(:'a_header'::jsonb || '{"inv_no":20261101}'::jsonb,
 pg_temp.zc_line(:'a_items'::jsonb,1,'{"charge":0}'::jsonb))->>'error'='Enter a reason for the zero charge',
 'three-argument save: one zero-charge line of two needs a reason');
-- A reason made only of white space or invisible characters is no reason
-- (the same characters as for the discount reason, migration 41).
SELECT pg_temp.zc_assert(pg_temp.zc_save3(:'a_header'::jsonb || jsonb_build_object('inv_no',20261101,'zero_charge_reason',blank.reason),
 pg_temp.zc_rates(:'a_items'::jsonb,'{"charge":0}'::jsonb))->>'error'='Enter a reason for the zero charge','blank reason refused for staff: '||blank.label)
 FROM (VALUES ('empty',''),('spaces','   '),('tab and newline',E'\t\n\r'),('no-break space',U&'\00A0'),('zero-width space',U&'\200B'),
  ('ideographic space',U&'\3000'),('a mix',U&' \00A0\2003\200B\FEFF\2060 ')) AS blank(label,reason);
-- A charge outside the range is still refused, with or without a reason.
SELECT pg_temp.zc_assert(pg_temp.zc_save3(:'a_header'::jsonb || '{"inv_no":20261101,"zero_charge_reason":"Goodwill"}'::jsonb,
  pg_temp.zc_line(pg_temp.zc_rates(:'a_items'::jsonb,'{"charge":0}'::jsonb),1,rate.bad))->>'success'='false',
 'a charge out of range is still refused beside a zero charge with a reason: '||rate.bad::text)
 FROM (VALUES ('{"charge":-0.01}'::jsonb),('{"charge":-5}'::jsonb),('{"charge":1000000}'::jsonb)) AS rate(bad);
-- A zero duration is still refused where it was (the three-argument save
-- validates the line it is sent; the other paths compute the duration).
SELECT pg_temp.zc_save3(:'a_header'::jsonb || '{"inv_no":20261101,"zero_charge_reason":"Goodwill"}'::jsonb,
 pg_temp.zc_rates(:'a_items'::jsonb,'{"charge":0,"duration":0}'::jsonb)) AS zero_duration \gset
SELECT pg_temp.zc_assert(:'zero_duration'::jsonb->>'success'='false' AND :'zero_duration'::jsonb->>'error'='Invalid invoice items'
 AND :'zero_duration'::jsonb->'validation_errors'->0->>'field'='invoice_items[1].duration','a zero duration is still refused: '||:'zero_duration');
RESET ROLE;
SELECT pg_temp.zc_assert((SELECT count(*)=0 FROM public.invoice WHERE customer_id=:'customer_id'::uuid)
 AND (SELECT count(*)=0 FROM public.invoice_zero_charge_history)
 AND (SELECT invoiced IS NOT TRUE FROM public.goodsreceived WHERE id=:'grn_a'::uuid),'refused saves leave no invoice, no history row and the receipt uninvoiced');

-- With a reason the saves go through and the record is written. ZCA through
-- the three-argument path, both lines at zero: 100 x 2 labour = 200, tax 10.
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_save3(:'a_header'::jsonb || jsonb_build_object('inv_no',20261101,'zero_charge_reason',U&' \00A0Trial consignment\200B '),
 pg_temp.zc_rates(:'a_items'::jsonb,'{"charge":0}'::jsonb)) AS saved_a \gset
SELECT pg_temp.zc_assert(:'saved_a'::jsonb->>'success'='true','three-argument save: zero charge with a reason: '||:'saved_a');
SELECT (:'saved_a'::jsonb->>'invoice_id') AS invoice_a \gset
-- ZCB through the one-argument path, reason beside the other header fields.
SELECT pg_temp.zc_save1(:'b_header'::jsonb || '{"inv_no":20261102,"zero_charge_reason":"Sample lot"}'::jsonb,
 pg_temp.zc_rates(:'b_items'::jsonb,'{"charge":0}'::jsonb)) AS saved_b \gset
SELECT pg_temp.zc_assert(:'saved_b'::jsonb->>'success'='true','one-argument save: zero charge with a reason: '||:'saved_b');
SELECT (:'saved_b'::jsonb->>'invoice_id') AS invoice_b \gset
-- ZCC through the one-argument path, reason inside a "header" object.
SELECT pg_temp.zc_save1(:'c_header'::jsonb || '{"inv_no":20261103,"header":{"zero_charge_reason":"Owner said so"}}'::jsonb,
 pg_temp.zc_rates(:'c_items'::jsonb,'{"charge":0}'::jsonb)) AS saved_c \gset
SELECT pg_temp.zc_assert(:'saved_c'::jsonb->>'success'='true','one-argument save: the reason in the header object: '||:'saved_c');
SELECT (:'saved_c'::jsonb->>'invoice_id') AS invoice_c \gset
-- ZCD has no zero-charge line: the reason that was sent is not stored.
SELECT pg_temp.zc_save3(:'d_header'::jsonb || '{"inv_no":20261104,"zero_charge_reason":"Not needed"}'::jsonb,:'d_items'::jsonb) AS saved_d \gset
SELECT pg_temp.zc_assert(:'saved_d'::jsonb->>'success'='true','three-argument save without a zero charge: '||:'saved_d');
SELECT (:'saved_d'::jsonb->>'invoice_id') AS invoice_d \gset
RESET ROLE;
SELECT pg_temp.zc_assert((SELECT total=210 AND labour=200 AND tax_amount=10 FROM public.invoice WHERE id=:'invoice_a'::uuid),'a zero charge bills the labour only: 200 + 10');
SELECT pg_temp.zc_assert(pg_temp.zc_record(:'invoice_a'::uuid)-'at'=jsonb_build_object('reason','Trial consignment','by',:'staff_profile')
 AND pg_temp.zc_record(:'invoice_a'::uuid)->>'at' IS NOT NULL,'the reason is stored trimmed, with the profile and the time: '||pg_temp.zc_record(:'invoice_a'::uuid)::text);
SELECT pg_temp.zc_assert(pg_temp.zc_history(:'invoice_a'::uuid)=jsonb_build_array(jsonb_build_array(NULL,'Trial consignment',0,2,:'staff_profile','staff')),
 'one history row for the new invoice: '||pg_temp.zc_history(:'invoice_a'::uuid)::text);
SELECT pg_temp.zc_assert((SELECT h.inv_no=20261101 AND h.inv_fin_year=2026 AND h.customer_id=:'customer_id'::uuid AND h.changed_at IS NOT NULL
   AND h.old_lines='{}' AND h.new_lines=ARRAY(SELECT t.disp_trl_id FROM public.invoice_trl t WHERE t.invoice_id=h.invoice_id ORDER BY t.disp_trl_id)
  FROM public.invoice_zero_charge_history h WHERE h.invoice_id=:'invoice_a'::uuid),'the history row names the invoice, the customer and the dispatch lines');
SELECT pg_temp.zc_assert(pg_temp.zc_record(:'invoice_b'::uuid)-'at'=jsonb_build_object('reason','Sample lot','by',:'staff_profile')
 AND pg_temp.zc_history(:'invoice_b'::uuid)=jsonb_build_array(jsonb_build_array(NULL,'Sample lot',0,1,:'staff_profile','staff')),
 'one-argument save: record and history: '||pg_temp.zc_record(:'invoice_b'::uuid)::text);
SELECT pg_temp.zc_assert(pg_temp.zc_record(:'invoice_c'::uuid)-'at'=jsonb_build_object('reason','Owner said so','by',:'staff_profile'),
 'one-argument save: the header object''s reason is recorded: '||pg_temp.zc_record(:'invoice_c'::uuid)::text);
SELECT pg_temp.zc_assert(pg_temp.zc_record(:'invoice_d'::uuid)=jsonb_build_object('reason',NULL,'by',NULL,'at',NULL)
 AND pg_temp.zc_history(:'invoice_d'::uuid)='[]'::jsonb,'no zero-charge line: reason NULL, nobody recorded, no history: '||pg_temp.zc_record(:'invoice_d'::uuid)::text);
-- None of this touches the discount record.
SELECT pg_temp.zc_assert((SELECT count(*)=0 FROM public.invoice_discount_history)
 AND (SELECT bool_and(discount_reason IS NULL AND discount_set_by IS NULL) FROM public.invoice WHERE customer_id=:'customer_id'::uuid),
 'the discount history is untouched');

-- ---------------------------------------------------------------------------
-- 2. Administrator and supervisor: the reason is optional
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_save3(:'e_header'::jsonb || '{"inv_no":20261105}'::jsonb, pg_temp.zc_rates(:'e_items'::jsonb,'{"charge":0}'::jsonb)) AS saved_e \gset
SELECT pg_temp.zc_assert(:'saved_e'::jsonb->>'success'='true','administrator: zero charge without a reason: '||:'saved_e');
SELECT (:'saved_e'::jsonb->>'invoice_id') AS invoice_e \gset
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SELECT pg_temp.zc_assert(warehouse_security.active_role()='supervisor','actual supervisor role');
SELECT pg_temp.zc_save1(:'f_header'::jsonb || '{"inv_no":20261106,"zero_charge_reason":"   "}'::jsonb, pg_temp.zc_rates(:'f_items'::jsonb,'{"charge":0}'::jsonb)) AS saved_f \gset
SELECT pg_temp.zc_assert(:'saved_f'::jsonb->>'success'='true','supervisor: zero charge with a blank reason: '||:'saved_f');
SELECT (:'saved_f'::jsonb->>'invoice_id') AS invoice_f \gset
RESET ROLE;
SELECT pg_temp.zc_assert(pg_temp.zc_record(:'invoice_e'::uuid)-'at'=jsonb_build_object('reason',NULL,'by',:'admin_profile')
 AND pg_temp.zc_record(:'invoice_e'::uuid)->>'at' IS NOT NULL
 AND pg_temp.zc_history(:'invoice_e'::uuid)=jsonb_build_array(jsonb_build_array(NULL,NULL,0,1,:'admin_profile','admin')),
 'the administrator''s zero charge is recorded without a reason: '||pg_temp.zc_history(:'invoice_e'::uuid)::text);
SELECT pg_temp.zc_assert(pg_temp.zc_record(:'invoice_f'::uuid)-'at'=jsonb_build_object('reason',NULL,'by',:'supervisor_profile')
 AND pg_temp.zc_history(:'invoice_f'::uuid)=jsonb_build_array(jsonb_build_array(NULL,NULL,0,1,:'supervisor_profile','supervisor')),
 'the supervisor''s zero charge is recorded without a reason: '||pg_temp.zc_history(:'invoice_f'::uuid)::text);

-- ---------------------------------------------------------------------------
-- 3. Edits. The time is moved back by hand to see whether an edit sets it.
-- ---------------------------------------------------------------------------
UPDATE public.invoice SET zero_charge_set_at='2026-01-01T00:00:00Z' WHERE customer_id=:'customer_id'::uuid AND zero_charge_set_at IS NOT NULL;
-- The second staff member edits ZCA.
SELECT set_config('request.jwt.claims',:'staff2_claims',true);
SET LOCAL ROLE authenticated;
-- Without the reason: refused, and nothing of the edit is kept.
SELECT pg_temp.zc_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261101,"notes":"must roll back"}'::jsonb,
 pg_temp.zc_rates(:'a_items'::jsonb,'{"charge":0}'::jsonb)) AS edit_refused \gset
SELECT pg_temp.zc_assert(:'edit_refused'::jsonb->>'success'='false' AND :'edit_refused'::jsonb->>'error'='Enter a reason for the zero charge'
 AND :'edit_refused'::jsonb->>'error_code'='22023','edit: staff must send the reason again: '||:'edit_refused');
-- The same reason and the same zero-charge lines: the edit is saved, the
-- record keeps its author and time, the history gets no row.
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261101,"notes":"same zero charge","zero_charge_reason":"Trial consignment"}'::jsonb,
 pg_temp.zc_rates(:'a_items'::jsonb,'{"charge":0,"labour_rate":3}'::jsonb))->>'success'='true','edit keeping the reason and the zero-charge lines');
RESET ROLE;
SELECT pg_temp.zc_assert((SELECT notes='same zero charge' AND labour=300 FROM public.invoice WHERE id=:'invoice_a'::uuid)
 AND pg_temp.zc_record(:'invoice_a'::uuid)=jsonb_build_object('reason','Trial consignment','by',:'staff_profile','at','2026-01-01T00:00:00+00:00'::timestamptz)
 AND jsonb_array_length(pg_temp.zc_history(:'invoice_a'::uuid))=1,
 'an unchanged zero charge keeps its author and time: '||pg_temp.zc_record(:'invoice_a'::uuid)::text);
-- Another reason: recorded for the person who changed it.
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261101,"zero_charge_reason":"Trial consignment, agreed by phone"}'::jsonb,
 pg_temp.zc_rates(:'a_items'::jsonb,'{"charge":0}'::jsonb))->>'success'='true','edit changing the reason');
-- (The same person rewords ZCC's reason; section 6 removes that profile.)
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_c'::uuid,:'c_header'::jsonb || '{"inv_no":20261103,"zero_charge_reason":"Owner agreed"}'::jsonb,
 pg_temp.zc_rates(:'c_items'::jsonb,'{"charge":0}'::jsonb))->>'success'='true','edit changing the reason of ZCC');
RESET ROLE;
SELECT pg_temp.zc_assert(pg_temp.zc_record(:'invoice_a'::uuid)-'at'=jsonb_build_object('reason','Trial consignment, agreed by phone','by',:'staff2_profile')
 AND (SELECT zero_charge_set_at=now() FROM public.invoice WHERE id=:'invoice_a'::uuid)
 AND pg_temp.zc_history(:'invoice_a'::uuid)->1=jsonb_build_array('Trial consignment','Trial consignment, agreed by phone',2,2,:'staff2_profile','staff'),
 'a changed reason is recorded with its author and time: '||pg_temp.zc_history(:'invoice_a'::uuid)::text);
-- The supervisor gives the 80-bag line its price: the set of zero-charge lines
-- changes while the reason stays.
UPDATE public.invoice SET zero_charge_set_at='2026-01-01T00:00:00Z' WHERE id=:'invoice_a'::uuid;
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261101,"zero_charge_reason":"Trial consignment, agreed by phone"}'::jsonb,
 pg_temp.zc_line(:'a_items'::jsonb,0,'{"charge":0}'::jsonb))->>'success'='true','edit changing which lines have a zero charge');
RESET ROLE;
SELECT pg_temp.zc_assert(pg_temp.zc_record(:'invoice_a'::uuid)-'at'=jsonb_build_object('reason','Trial consignment, agreed by phone','by',:'supervisor_profile')
 AND (SELECT zero_charge_set_at=now() FROM public.invoice WHERE id=:'invoice_a'::uuid)
 AND pg_temp.zc_history(:'invoice_a'::uuid)->2=jsonb_build_array('Trial consignment, agreed by phone','Trial consignment, agreed by phone',2,1,:'supervisor_profile','supervisor'),
 'a changed set of zero-charge lines is recorded: '||pg_temp.zc_history(:'invoice_a'::uuid)::text);
SELECT pg_temp.zc_assert((SELECT h.new_lines=ARRAY[(:'a_items'::jsonb#>>'{0,disp_trl_id}')::uuid] FROM public.invoice_zero_charge_history h
  WHERE h.invoice_id=:'invoice_a'::uuid ORDER BY h.id DESC LIMIT 1),'the history names the line that still has a zero charge');
-- The administrator saves a request that has no zero_charge_reason key at all
-- (an older app build, or a client that does not know the field): the stored
-- reason is kept, and as the zero-charge lines are the same nothing is
-- recorded. Staff are different: they must send the reason on every save (the
-- refused edit above), also when one is stored.
UPDATE public.invoice SET zero_charge_set_at='2026-01-01T00:00:00Z' WHERE id=:'invoice_a'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(NOT (:'a_header'::jsonb ? 'zero_charge_reason')
 AND pg_temp.zc_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261101,"notes":"edit without the key"}'::jsonb,
 pg_temp.zc_line(:'a_items'::jsonb,0,'{"charge":0}'::jsonb))->>'success'='true','administrator edit without the reason key');
RESET ROLE;
SELECT pg_temp.zc_assert((SELECT notes='edit without the key' FROM public.invoice WHERE id=:'invoice_a'::uuid)
 AND pg_temp.zc_record(:'invoice_a'::uuid)=jsonb_build_object('reason','Trial consignment, agreed by phone','by',:'supervisor_profile','at','2026-01-01T00:00:00+00:00'::timestamptz)
 AND jsonb_array_length(pg_temp.zc_history(:'invoice_a'::uuid))=3,
 'a request without the reason key keeps the stored reason, its author and time: '||pg_temp.zc_record(:'invoice_a'::uuid)::text);
-- The key sent as null (what the app sends for an empty field) clears the
-- reason, and that is recorded.
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261101,"zero_charge_reason":null}'::jsonb,
 pg_temp.zc_line(:'a_items'::jsonb,0,'{"charge":0}'::jsonb))->>'success'='true','administrator edit with the reason sent as null');
RESET ROLE;
SELECT pg_temp.zc_assert(pg_temp.zc_record(:'invoice_a'::uuid)-'at'=jsonb_build_object('reason',NULL,'by',:'admin_profile')
 AND (SELECT zero_charge_set_at=now() FROM public.invoice WHERE id=:'invoice_a'::uuid)
 AND pg_temp.zc_history(:'invoice_a'::uuid)->3=jsonb_build_array('Trial consignment, agreed by phone',NULL,1,1,:'admin_profile','admin')
 AND jsonb_array_length(pg_temp.zc_history(:'invoice_a'::uuid))=4,
 'an administrator who sends the reason as null clears it, and that is recorded: '||pg_temp.zc_history(:'invoice_a'::uuid)::text);
-- The same on ZCF, whose zero charge the supervisor entered without a reason.
-- The supervisor adds one; the administrator's edit without the key keeps it
-- although the request is otherwise complete; a reason sent blank clears it.
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_f'::uuid,:'f_header'::jsonb || '{"inv_no":20261106,"zero_charge_reason":"Promotional lot"}'::jsonb,
 pg_temp.zc_rates(:'f_items'::jsonb,'{"charge":0}'::jsonb))->>'success'='true','the supervisor adds a reason to ZCF');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_f'::uuid,:'f_header'::jsonb || '{"inv_no":20261106,"notes":"no key","discount":0}'::jsonb,
 pg_temp.zc_rates(:'f_items'::jsonb,'{"charge":0,"labour_rate":3}'::jsonb))->>'success'='true','administrator edit of ZCF without the reason key');
RESET ROLE;
SELECT pg_temp.zc_assert(pg_temp.zc_record(:'invoice_f'::uuid)-'at'=jsonb_build_object('reason','Promotional lot','by',:'supervisor_profile')
 AND (SELECT notes='no key' FROM public.invoice WHERE id=:'invoice_f'::uuid)
 AND pg_temp.zc_history(:'invoice_f'::uuid)=jsonb_build_array(jsonb_build_array(NULL,NULL,0,1,:'supervisor_profile','supervisor'),
   jsonb_build_array(NULL,'Promotional lot',1,1,:'supervisor_profile','supervisor')),
 'ZCF keeps the supervisor''s reason through an edit without the key: '||pg_temp.zc_history(:'invoice_f'::uuid)::text);
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_f'::uuid,:'f_header'::jsonb || jsonb_build_object('inv_no',20261106,'zero_charge_reason',U&' \00A0\200B '),
 pg_temp.zc_rates(:'f_items'::jsonb,'{"charge":0}'::jsonb))->>'success'='true','administrator edit of ZCF with a blank reason');
RESET ROLE;
SELECT pg_temp.zc_assert(pg_temp.zc_record(:'invoice_f'::uuid)-'at'=jsonb_build_object('reason',NULL,'by',:'admin_profile')
 AND pg_temp.zc_history(:'invoice_f'::uuid)->2=jsonb_build_array('Promotional lot',NULL,1,1,:'admin_profile','admin')
 AND jsonb_array_length(pg_temp.zc_history(:'invoice_f'::uuid))=3,
 'a reason sent blank clears it, and that is recorded: '||pg_temp.zc_history(:'invoice_f'::uuid)::text);
-- Staff gives every line its price and still sends a reason: no zero-charge
-- line is left, so the reason is stored as NULL; the removal is a change.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261101,"zero_charge_reason":"No longer free"}'::jsonb,
 :'a_items'::jsonb)->>'success'='true','edit removing every zero charge');
RESET ROLE;
SELECT pg_temp.zc_assert((SELECT total=998 FROM public.invoice WHERE id=:'invoice_a'::uuid)
 AND pg_temp.zc_record(:'invoice_a'::uuid)-'at'=jsonb_build_object('reason',NULL,'by',:'staff_profile')
 AND pg_temp.zc_history(:'invoice_a'::uuid)->4=jsonb_build_array(NULL,NULL,1,0,:'staff_profile','staff')
 AND jsonb_array_length(pg_temp.zc_history(:'invoice_a'::uuid))=5,
 'with no zero-charge line left the reason is NULL and the removal is recorded: '||pg_temp.zc_history(:'invoice_a'::uuid)::text);
-- From then on a reason is neither needed nor stored, and nothing is recorded.
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261101,"notes":"priced","zero_charge_reason":"ignored"}'::jsonb,
 :'a_items'::jsonb)->>'success'='true' AND pg_temp.zc_update(:'invoice_a'::uuid,:'a_header'::jsonb || '{"inv_no":20261101,"notes":"priced"}'::jsonb,
 :'a_items'::jsonb)->>'success'='true','edits of an invoice without a zero charge');
-- Giving a line a zero charge in an edit needs the reason again.
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_d'::uuid,:'d_header'::jsonb || '{"inv_no":20261104}'::jsonb,
 pg_temp.zc_rates(:'d_items'::jsonb,'{"charge":0}'::jsonb))->>'error'='Enter a reason for the zero charge','edit: a new zero charge without a reason refused');
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_d'::uuid,:'d_header'::jsonb || jsonb_build_object('inv_no',20261104,'zero_charge_reason',repeat('Long reason ',50)),
 pg_temp.zc_rates(:'d_items'::jsonb,'{"charge":0}'::jsonb))->>'success'='true','edit: a new zero charge with a 600-character reason');
-- A charge out of range is refused on the edit path as before.
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_d'::uuid,:'d_header'::jsonb || '{"inv_no":20261104,"zero_charge_reason":"Goodwill"}'::jsonb,
 pg_temp.zc_rates(:'d_items'::jsonb,rate.bad))->>'error'='Invoice line charge must be between 0 and 999999','edit: a charge out of range is still refused: '||rate.bad::text)
 FROM (VALUES ('{"charge":-1}'::jsonb),('{"charge":1000000}'::jsonb)) AS rate(bad);
RESET ROLE;
SELECT pg_temp.zc_assert(jsonb_array_length(pg_temp.zc_history(:'invoice_a'::uuid))=5
 AND pg_temp.zc_record(:'invoice_a'::uuid)-'at'=jsonb_build_object('reason',NULL,'by',:'staff_profile'),'no zero charge, no further record');
-- Each history row holds its author's name as it was at the change.
SELECT pg_temp.zc_assert((SELECT array_agg(h.changed_by_name ORDER BY h.id) FROM public.invoice_zero_charge_history h WHERE h.invoice_id=:'invoice_a'::uuid)
 = ARRAY['Zero Charge Staff','Zero Charge Second Staff','Zero Charge Supervisor','Zero Charge Administrator','Zero Charge Staff'],
 'each history row holds its author''s name: '||(SELECT jsonb_agg(h.changed_by_name ORDER BY h.id)::text FROM public.invoice_zero_charge_history h WHERE h.invoice_id=:'invoice_a'::uuid));
SELECT pg_temp.zc_assert((SELECT length(zero_charge_reason)=500 AND zero_charge_reason=left(repeat('Long reason ',50),500) AND zero_charge_set_by=:'staff_profile'::uuid
  FROM public.invoice WHERE id=:'invoice_d'::uuid)
 AND (SELECT count(*)=1 AND bool_and(length(new_reason)=500 AND old_reason IS NULL AND cardinality(old_lines)=0 AND cardinality(new_lines)=1)
  FROM public.invoice_zero_charge_history WHERE invoice_id=:'invoice_d'::uuid),'a long reason is stored cut to 500 characters');
-- The discount reason and the zero-charge reason are two rules: each is asked
-- for on its own.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_b'::uuid,:'b_header'::jsonb || '{"inv_no":20261102,"discount":-10,"zero_charge_reason":"Sample lot"}'::jsonb,
  pg_temp.zc_rates(:'b_items'::jsonb,'{"charge":0}'::jsonb))->>'error'='A reason is required for an invoice discount'
 AND pg_temp.zc_update(:'invoice_b'::uuid,:'b_header'::jsonb || '{"inv_no":20261102,"discount":-10,"discount_reason":"Handling"}'::jsonb,
  pg_temp.zc_rates(:'b_items'::jsonb,'{"charge":0}'::jsonb))->>'error'='Enter a reason for the zero charge'
 AND pg_temp.zc_update(:'invoice_b'::uuid,:'b_header'::jsonb || '{"inv_no":20261102,"discount":-10,"discount_reason":"Handling","zero_charge_reason":"Sample lot"}'::jsonb,
  pg_temp.zc_rates(:'b_items'::jsonb,'{"charge":0}'::jsonb))->>'success'='true','a discount and a zero charge each need their own reason');
RESET ROLE;
SELECT pg_temp.zc_assert((SELECT discount=-10 AND discount_reason='Handling' AND zero_charge_reason='Sample lot' AND total=10 FROM public.invoice WHERE id=:'invoice_b'::uuid)
 AND (SELECT count(*)=1 FROM public.invoice_discount_history WHERE invoice_id=:'invoice_b'::uuid)
 AND jsonb_array_length(pg_temp.zc_history(:'invoice_b'::uuid))=1,'both records are kept, each in its own history');

-- Every spelling of a zero charge, on every path, as staff. What counts is the
-- stored NUMERIC(12,2) value, so a charge that rounds to 0.00, a zero sent as
-- text, a null or missing charge and the `unit_price` alias are zero charges
-- like 0 itself: without a reason staff are refused, with one the save goes
-- through. The three-argument save validates the line first and refuses a
-- missing, null or negative charge and the alias as invalid, with or without a
-- reason, so none of them reaches the table by that path. A charge of 0.005
-- is stored as 0.01 and needs no reason.
-- Each call runs in a subtransaction that is rolled back, so nothing is kept:
-- new invoices are tried on the receipt ZCG, edits on the ZCD invoice.
CREATE FUNCTION pg_temp.zc_try(statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN
    EXECUTE statement INTO answer;
    RAISE EXCEPTION USING ERRCODE='ZC000', MESSAGE=answer::text;
  EXCEPTION WHEN SQLSTATE 'ZC000' THEN answer := SQLERRM::jsonb;
  END;
  RETURN CASE WHEN answer->>'success'='true' THEN 'saved'
    WHEN answer->>'error' IN ('Enter a reason for the zero charge','Database error: Enter a reason for the zero charge (SQLState: 22023)') THEN 'reason'
    WHEN answer->>'error'='Invalid invoice items' THEN 'invalid'
    ELSE answer::text END;
END $$;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT pg_temp.zc_assert(outcome.without_reason=expected.without_reason AND outcome.with_reason=replace(expected.without_reason,'reason','saved'),
  path.name||', charge '||spelling.label||': without a reason '||outcome.without_reason||' (expected '||expected.without_reason
  ||'), with a reason '||outcome.with_reason||' (expected '||replace(expected.without_reason,'reason','saved')||')')
FROM (VALUES
  ('0',                          '{"charge":0}'::jsonb,                  'reason','reason'),
  ('"0"',                        '{"charge":"0"}',                       'reason','reason'),
  ('"0.00"',                     '{"charge":"0.00"}',                    'reason','reason'),
  ('-0',                         '{"charge":-0}',                        'reason','reason'),
  ('0.004',                      '{"charge":0.004}',                     'reason','reason'),
  ('0.0049',                     '{"charge":0.0049}',                    'reason','reason'),
  ('-0.004',                     '{"charge":-0.004}',                    'invalid','reason'),
  ('null',                       '{"charge":null}',                      'invalid','reason'),
  ('absent',                     '{}',                                   'invalid','reason'),
  ('""',                         '{"charge":""}',                        'invalid','reason'),
  ('absent, unit_price 0',       '{"unit_price":0}',                     'invalid','reason'),
  ('absent, unit_price "0.00"',  '{"unit_price":"0.00"}',                'invalid','reason'),
  ('null, unit_price 0',         '{"charge":null,"unit_price":0}',       'invalid','reason'),
  ('"", unit_price 0.004',       '{"charge":"","unit_price":0.004}',     'invalid','reason'),
  ('0.005',                      '{"charge":0.005}',                     'saved','saved'),
  ('0.01',                       '{"charge":0.01}',                      'saved','saved'),
  ('absent, unit_price 0.01',    '{"unit_price":0.01}',                  'invalid','saved'),
  ('absent, unit_price 5',       '{"unit_price":5}',                     'invalid','saved')
 ) AS spelling(label,rates,save3,update)
CROSS JOIN LATERAL (VALUES
  ('three-argument save',spelling.save3, 'SELECT pg_temp.zc_save3(%1$L::jsonb,%2$L::jsonb)'),
  ('edit',               spelling.update,'SELECT pg_temp.zc_update(%5$L::uuid,%3$L::jsonb,%4$L::jsonb)')
 ) AS path(name,expected,call)
CROSS JOIN LATERAL (SELECT path.expected AS without_reason) AS expected
CROSS JOIN LATERAL (SELECT
  pg_temp.zc_try(format(path.call,
    (:'g_header'::jsonb || '{"inv_no":20261108}'::jsonb)::text,
    (SELECT jsonb_agg((item - 'charge') || spelling.rates) FROM jsonb_array_elements(:'g_items'::jsonb) item)::text,
    (:'d_header'::jsonb || '{"inv_no":20261104}'::jsonb)::text,
    (SELECT jsonb_agg((item - 'charge') || spelling.rates) FROM jsonb_array_elements(:'d_items'::jsonb) item)::text, :'invoice_d')) AS without_reason,
  pg_temp.zc_try(format(path.call,
    (:'g_header'::jsonb || '{"inv_no":20261108,"zero_charge_reason":"Goodwill"}'::jsonb)::text,
    (SELECT jsonb_agg((item - 'charge') || spelling.rates) FROM jsonb_array_elements(:'g_items'::jsonb) item)::text,
    (:'d_header'::jsonb || '{"inv_no":20261104,"zero_charge_reason":"Goodwill"}'::jsonb)::text,
    (SELECT jsonb_agg((item - 'charge') || spelling.rates) FROM jsonb_array_elements(:'d_items'::jsonb) item)::text, :'invoice_d')) AS with_reason
 ) AS outcome;
-- A reason sent as null or blank is no reason for staff, whatever the spelling.
SELECT pg_temp.zc_assert(pg_temp.zc_try(format('SELECT pg_temp.zc_update(%L::uuid,%L::jsonb,%L::jsonb)',:'invoice_d',
   (:'d_header'::jsonb || '{"inv_no":20261104}'::jsonb || reason.sent)::text,
   pg_temp.zc_rates(:'d_items'::jsonb,'{"charge":"0.00"}'::jsonb)::text))='reason','staff edit with the reason sent as '||reason.sent::text||' is refused')
FROM (VALUES ('{"zero_charge_reason":null}'::jsonb),('{"zero_charge_reason":""}'),('{"zero_charge_reason":"  "}')) AS reason(sent);
RESET ROLE;
-- None of the trials was kept.
SELECT pg_temp.zc_assert((SELECT count(*)=0 FROM public.invoice WHERE inv_no=20261108)
 AND (SELECT invoiced IS NOT TRUE FROM public.goodsreceived WHERE id=:'grn_g'::uuid)
 AND (SELECT length(zero_charge_reason)=500 FROM public.invoice WHERE id=:'invoice_d'::uuid)
 AND (SELECT count(*)=1 FROM public.invoice_zero_charge_history WHERE invoice_id=:'invoice_d'::uuid),
 'the trials left no invoice for ZCG and the ZCD invoice as it was');

-- ---------------------------------------------------------------------------
-- 4. An invoice from before the rule: a zero-charge line and no reason
-- ---------------------------------------------------------------------------
-- Written as the database owner, the way such a row exists after the upgrade.
INSERT INTO public.invoice(id,inv_fin_year,inv_no,gr_id,gr_no,customer_id,customer_name,inv_date,labour,tax_amount,total,discount)
 VALUES ('00000000-0000-4000-8000-000000000048',2026,20261107,:'grn_g'::uuid,'ZCG',:'customer_id'::uuid,'Zero Charge Customer','2026-05-02T12:00:00Z',20,1,21,0);
INSERT INTO public.invoice_trl(invoice_id,disp_trl_id,duration,no_of_days,charge,tax,labour_rate)
 VALUES ('00000000-0000-4000-8000-000000000048',(:'g_items'::jsonb#>>'{0,disp_trl_id}')::uuid,1.5,31,0,5,2);
UPDATE public.goodsreceived SET invoiced=true WHERE id=:'grn_g'::uuid;
\set invoice_g 00000000-0000-4000-8000-000000000048
-- It stays readable.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_detail(:'invoice_g'::uuid) AS detail_old \gset
SELECT pg_temp.zc_assert(:'detail_old'::jsonb->>'success'='true' AND (:'detail_old'::jsonb#>>'{items,0,charge}')::numeric=0
 AND :'detail_old'::jsonb->'invoice' ?& ARRAY['zero_charge_reason','zero_charge_set_by','zero_charge_set_by_name','zero_charge_set_at']
 AND :'detail_old'::jsonb#>'{invoice,zero_charge_reason}'='null' AND :'detail_old'::jsonb#>'{invoice,zero_charge_set_at}'='null',
 'an older invoice with a zero charge and no reason is readable: '||(:'detail_old'::jsonb->'invoice')::text);
-- An administrator edits it without a reason: nothing about the zero charge
-- changed, so nothing is recorded.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_g'::uuid,:'g_header'::jsonb || '{"inv_no":20261107,"notes":"older invoice"}'::jsonb,
 pg_temp.zc_rates(:'g_items'::jsonb,'{"charge":0}'::jsonb))->>'success'='true','administrator edits the older invoice without a reason');
RESET ROLE;
SELECT pg_temp.zc_assert(pg_temp.zc_record(:'invoice_g'::uuid)=jsonb_build_object('reason',NULL,'by',NULL,'at',NULL)
 AND pg_temp.zc_history(:'invoice_g'::uuid)='[]'::jsonb AND (SELECT notes='older invoice' FROM public.invoice WHERE id=:'invoice_g'::uuid),
 'the unchanged older zero charge gets no author: '||pg_temp.zc_record(:'invoice_g'::uuid)::text);
-- Staff editing it meet the rule at that edit: refused without a reason,
-- recorded with one.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_g'::uuid,:'g_header'::jsonb || '{"inv_no":20261107,"notes":"staff edit"}'::jsonb,
 pg_temp.zc_rates(:'g_items'::jsonb,'{"charge":0}'::jsonb))->>'error'='Enter a reason for the zero charge','staff edit of the older invoice needs a reason');
SELECT pg_temp.zc_assert(pg_temp.zc_update(:'invoice_g'::uuid,:'g_header'::jsonb || '{"inv_no":20261107,"notes":"staff edit","zero_charge_reason":"Free storage agreed in April"}'::jsonb,
 pg_temp.zc_rates(:'g_items'::jsonb,'{"charge":0}'::jsonb))->>'success'='true','staff edit of the older invoice with a reason');
RESET ROLE;
SELECT pg_temp.zc_assert(pg_temp.zc_record(:'invoice_g'::uuid)-'at'=jsonb_build_object('reason','Free storage agreed in April','by',:'staff_profile')
 AND pg_temp.zc_history(:'invoice_g'::uuid)=jsonb_build_array(jsonb_build_array(NULL,'Free storage agreed in April',1,1,:'staff_profile','staff')),
 'the reason given at that edit is recorded: '||pg_temp.zc_history(:'invoice_g'::uuid)::text);

-- ---------------------------------------------------------------------------
-- 5. get_invoice_detail
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'staff2_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_detail(:'invoice_g'::uuid) AS detail_staff \gset
SELECT pg_temp.zc_assert(:'detail_staff'::jsonb->>'success'='true' AND :'detail_staff'::jsonb#>>'{invoice,zero_charge_reason}'='Free storage agreed in April'
 AND :'detail_staff'::jsonb#>>'{invoice,zero_charge_set_by}'=:'staff_profile' AND :'detail_staff'::jsonb#>>'{invoice,zero_charge_set_by_name}'='Zero Charge Staff'
 AND (:'detail_staff'::jsonb#>>'{invoice,zero_charge_set_at}')::timestamptz=now()
 AND :'detail_staff'::jsonb->'invoice' ? 'discount_reason' AND jsonb_array_length(:'detail_staff'::jsonb->'items')=1,
 'staff read the zero-charge record with the invoice: '||(:'detail_staff'::jsonb->'invoice')::text);
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SELECT pg_temp.zc_assert(public.get_invoice_detail(:'invoice_g'::uuid)#>>'{invoice,zero_charge_set_by_name}'='Zero Charge Staff'
 AND public.get_invoice_detail(:'invoice_d'::uuid)#>>'{invoice,zero_charge_reason}'=left(repeat('Long reason ',50),500),'the supervisor reads it too');
RESET ROLE;
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT id,:'customer_id'::uuid,true FROM public.user_profiles WHERE mobile='919888888885';
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_detail(:'invoice_g'::uuid) AS detail_customer \gset
SELECT pg_temp.zc_assert(:'detail_customer'::jsonb->>'success'='true' AND (:'detail_customer'::jsonb#>>'{invoice,total}')::numeric=21
 AND NOT (:'detail_customer'::jsonb->'invoice' ?| ARRAY['zero_charge_reason','zero_charge_set_by','zero_charge_set_by_name','zero_charge_set_at']),
 'the customer reads the invoice without the zero-charge record: '||(:'detail_customer'::jsonb->'invoice')::text);

-- ---------------------------------------------------------------------------
-- 6. Who reads the history; nobody changes it
-- ---------------------------------------------------------------------------
SELECT pg_temp.zc_assert((SELECT count(*)=0 FROM public.invoice_zero_charge_history),'a customer account cannot read the history');
RESET ROLE;
SELECT count(*) AS history_rows FROM public.invoice_zero_charge_history \gset
SELECT pg_temp.zc_assert(:history_rows=14,'fourteen changes were recorded in all, found '||:history_rows);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SELECT pg_temp.zc_assert((SELECT count(*)=0 FROM public.invoice_zero_charge_history),'staff cannot read the history');
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SELECT pg_temp.zc_assert((SELECT count(*)=:history_rows FROM public.invoice_zero_charge_history),'the supervisor reads the history');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SELECT pg_temp.zc_assert((SELECT count(*)=:history_rows FROM public.invoice_zero_charge_history),'the administrator reads the history');
SELECT pg_temp.zc_assert(pg_temp.zc_raises('UPDATE public.invoice_zero_charge_history SET new_reason=''rewritten''','permission denied%'),'the administrator cannot rewrite it');
SELECT pg_temp.zc_assert(pg_temp.zc_raises('DELETE FROM public.invoice_zero_charge_history','permission denied%'),'the administrator cannot delete from it');
SELECT pg_temp.zc_assert(pg_temp.zc_raises(format('INSERT INTO public.invoice_zero_charge_history(invoice_id,old_lines,new_lines) VALUES (%L,''{}'',''{}'')',:'invoice_a'),
 'permission denied%'),'the administrator cannot add to it by hand');
-- Deleting the invoice keeps its history.
SELECT pg_temp.zc_assert(public.delete_invoice(:'invoice_a'::uuid)->>'success'='true','administrator deletes the ZCA invoice');
RESET ROLE;
SELECT pg_temp.zc_assert(jsonb_array_length(pg_temp.zc_history(:'invoice_a'::uuid))=5,'the deleted invoice''s zero-charge history is kept');
SET LOCAL ROLE anon;
SELECT pg_temp.zc_assert(pg_temp.zc_raises('SELECT count(*) FROM public.invoice_zero_charge_history','permission denied%'),'no anonymous access');
RESET ROLE;
SELECT pg_temp.zc_assert(pg_temp.zc_raises('UPDATE public.invoice_zero_charge_history SET new_reason=''rewritten''','History table invoice_zero_charge_history cannot be changed'),
 'rows cannot be changed even by the database owner');
SELECT pg_temp.zc_assert(pg_temp.zc_raises('DELETE FROM public.invoice_zero_charge_history','History table invoice_zero_charge_history cannot be changed'),
 'rows cannot be deleted even by the database owner');
SELECT pg_temp.zc_assert(pg_temp.zc_raises('TRUNCATE public.invoice_zero_charge_history','History table invoice_zero_charge_history cannot be changed'),
 'the table cannot be emptied even by the database owner');
-- No foreign key ties the record to a profile: removing the profile empties
-- the invoice's author column and leaves the reason and the history.
SELECT pg_temp.zc_assert((SELECT zero_charge_set_by=:'staff2_profile'::uuid FROM public.invoice WHERE id=:'invoice_c'::uuid),'ZCC''s zero charge was last set by the second staff member');
DELETE FROM public.user_profiles WHERE id=:'staff2_profile'::uuid;
SELECT pg_temp.zc_assert((SELECT zero_charge_set_by IS NULL AND zero_charge_reason='Owner agreed' AND zero_charge_set_at IS NOT NULL FROM public.invoice WHERE id=:'invoice_c'::uuid)
 AND (SELECT count(*)=2 AND bool_and(changed_by_name='Zero Charge Second Staff') FROM public.invoice_zero_charge_history WHERE changed_by=:'staff2_profile'::uuid),
 'a removed profile leaves the reason on the invoice and its rows, with its name, in the history');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(public.get_invoice_detail(:'invoice_c'::uuid)#>'{invoice,zero_charge_set_by}'='null'
 AND public.get_invoice_detail(:'invoice_c'::uuid)#>>'{invoice,zero_charge_set_by_name}'='Zero Charge Second Staff',
 'the invoice still names who set the zero charge after the profile row is gone: '||(public.get_invoice_detail(:'invoice_c'::uuid)->'invoice')::text);
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 7. The author's name is the one at the time of the change
-- ---------------------------------------------------------------------------
-- delete_user_account, which every signed-in user may call for the own
-- account, renames the profile to "Deleted User". The first staff member set
-- ZCG's zero charge and ZCB's discount, then deletes the account: both records
-- and both histories still name the person.
SELECT pg_temp.zc_assert((SELECT zero_charge_set_by=:'staff_profile'::uuid FROM public.invoice WHERE id=:'invoice_g'::uuid)
 AND (SELECT discount_set_by=:'staff_profile'::uuid FROM public.invoice WHERE id=:'invoice_b'::uuid),'the first staff member is the author of both records');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(public.delete_user_account()->>'success'='true','the staff member deletes the own account');
RESET ROLE;
SELECT pg_temp.zc_assert((SELECT name='Deleted User' AND NOT active FROM public.user_profiles WHERE id=:'staff_profile'::uuid),'the profile is renamed to Deleted User');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_invoice_detail(:'invoice_g'::uuid)->'invoice' AS g_after, public.get_invoice_detail(:'invoice_b'::uuid)->'invoice' AS b_after \gset
SELECT pg_temp.zc_assert(:'g_after'::jsonb->>'zero_charge_set_by'=:'staff_profile' AND :'g_after'::jsonb->>'zero_charge_set_by_name'='Zero Charge Staff',
 'the zero-charge record keeps the name of a deleted account: '||:'g_after');
SELECT pg_temp.zc_assert(:'b_after'::jsonb->>'discount_set_by'=:'staff_profile' AND :'b_after'::jsonb->>'discount_set_by_name'='Zero Charge Staff',
 'the discount record keeps the name of a deleted account: '||:'b_after');
SELECT pg_temp.zc_assert((SELECT count(*)>=4 AND bool_and(h.changed_by_name='Zero Charge Staff' AND h.changed_by_role='staff')
   FROM public.invoice_zero_charge_history h WHERE h.changed_by=:'staff_profile'::uuid)
 AND (SELECT count(*)=1 AND bool_and(h.changed_by_name='Zero Charge Staff' AND h.changed_by_role='staff')
   FROM public.invoice_discount_history h WHERE h.changed_by=:'staff_profile'::uuid),
 'both histories keep the name and the role the author had');
RESET ROLE;
-- A record without a stored name (a history row from before migration 48 that
-- the upgrade could not name, or an invoice row written in the database)
-- shows the profile's present name.
INSERT INTO public.invoice_zero_charge_history(invoice_id,old_lines,new_lines,changed_by,changed_by_role,changed_at)
 VALUES (:'invoice_e'::uuid,'{}','{}',:'supervisor_profile'::uuid,'supervisor','2025-06-01T00:00:00Z');
UPDATE public.invoice SET zero_charge_set_by=:'supervisor_profile'::uuid, zero_charge_set_at='2025-06-01T00:00:00Z' WHERE id=:'invoice_e'::uuid;
UPDATE public.invoice SET zero_charge_set_by=:'supervisor_profile'::uuid, zero_charge_set_at='2025-07-01T00:00:00Z' WHERE id=:'invoice_f'::uuid;
SET LOCAL ROLE authenticated;
SELECT pg_temp.zc_assert(public.get_invoice_detail(:'invoice_e'::uuid)#>>'{invoice,zero_charge_set_by_name}'='Zero Charge Supervisor'
 AND public.get_invoice_detail(:'invoice_f'::uuid)#>>'{invoice,zero_charge_set_by_name}'='Zero Charge Supervisor',
 'without a stored name the profile''s present name is shown');
RESET ROLE;
ROLLBACK;
\echo 'Zero-charge reason on all three invoice save paths, per role, its record, history, detail and author-name checks passed.'
