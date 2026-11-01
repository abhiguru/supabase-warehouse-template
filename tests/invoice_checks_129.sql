-- Migration 129, invoices (save_invoice and update_invoice):
--   A. an invoice is not dated before the latest dispatch of its lines (INVOICE_BEFORE_DISPATCH); an edit is checked only when the
--      date or the set of lines changes
--   B. an invoice is not dated in the future (India day): INVOICE_DATE_FUTURE with today's date; stored future dates are not touched
--   C. a discount may not take a charged invoice to exactly 0 (DISCOUNT_TOTAL_ZERO), on save and on update
--   D. lines that carry the figures the form looked up are refused when the lookup changed since (RATES_CHANGED), except the
--      figures typed by hand; no looked_up (an older app) is not checked
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.i9_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'invoice checks 129: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.i9_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.i9_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.i9_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The answer of a statement, or what it raised.
CREATE FUNCTION pg_temp.i9_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN answer;
END $$;
-- What a check helper raises as 'rate_fail': the refusal in its DETAIL; {"ok":true} when it raises nothing.
CREATE FUNCTION pg_temp.i9_helper(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE detail text;
BEGIN
  BEGIN EXECUTE statement;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS detail = PG_EXCEPTION_DETAIL;
    RETURN COALESCE(detail::jsonb, jsonb_build_object('raised', SQLERRM));
  END;
  RETURN '{"ok":true}'::jsonb;
END $$;
-- One value read as the owner (the app role has no direct read of the tables), for the fixture helpers that run as the signed-in administrator.
CREATE FUNCTION pg_temp.i9_scalar(p_query text) RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v text;
BEGIN EXECUTE p_query INTO v; RETURN v; END $$;
-- A GRN of p_qty bags of the item (no rate check, as before this migration), fully dispatched on one dispatch. Run as a signed-in administrator.
-- Answers the GRN id, its number, the invoice line of the one dispatch line and the dispatch id.
CREATE FUNCTION pg_temp.i9_make(p_no text, p_qty integer, p_grn_day date, p_disp_no text, p_disp_day date, p_customer uuid, p_item uuid, p_admin uuid) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_grn jsonb; v_grn_id uuid; v_lot uuid; v_disp jsonb; v_line jsonb;
BEGIN
  v_grn := public.save_grn(p_gr_no=>p_no, p_date=>(p_grn_day::text||'T12:00:00Z')::timestamptz, p_customer_id=>p_customer, p_customer_name=>'Inv129 Customer A',
    p_pricing_mode=>'MONTHLY', p_items=>jsonb_build_array(jsonb_build_object('item_id',p_item,'item_name','Inv129 Potatoes','packaging','Bag','qty',p_qty,'weight',10,'rack','R1','package_mark',p_no||'-P')));
  IF v_grn->>'success' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'fixture GRN % failed: %', p_no, v_grn; END IF;
  SELECT pg_temp.i9_scalar(format('SELECT g.id FROM public.goodsreceived g WHERE g.gr_no = %L', p_no))::uuid INTO v_grn_id;
  SELECT pg_temp.i9_scalar(format('SELECT t.id FROM public.goodsreceived_trl t WHERE t.gr_id = %L', v_grn_id))::uuid INTO v_lot;
  v_disp := public.create_dispatch_with_stock_check(jsonb_build_object('disp_no',p_disp_no,'disp_date',p_disp_day,'customer_id',p_customer,
    'customer_name','Inv129 Customer A','supervisor_id',p_admin,'supervisor_name','Inv129 Administrator'),
    ARRAY[jsonb_build_object('gr_trl_id',v_lot,'disp_qty',p_qty)], 0, 'i9-'||p_disp_no);
  IF v_disp->>'success' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'fixture dispatch % failed: %', p_disp_no, v_disp; END IF;
  SELECT pg_temp.i9_scalar(format('SELECT jsonb_build_object(''disp_trl_id'',dt.id,''grn_item_id'',dt.gr_trl_id,''duration'',1,''charge'',10,''tax'',0,''labour_rate'',2)::text FROM public.dispatch_trl dt WHERE dt.disp_id = %L', v_disp->>'dispatch_id'))::jsonb INTO v_line;
  RETURN jsonb_build_object('grn_id',v_grn_id,'gr_no',p_no,'line',v_line,'dispatch_id',v_disp->>'dispatch_id');
END $$;
-- (SECURITY DEFINER, like i9_stored: business_date and financial_year are not granted to the app role, which runs most of this file.)
-- The financial year of a day, for the same reason.
CREATE FUNCTION pg_temp.i9_fy(p_day date) RETURNS integer LANGUAGE sql SECURITY DEFINER AS $$ SELECT warehouse_security.financial_year(p_day) $$;
-- The header of an invoice of a made GRN, dated p_day (a date or a timestamp as text), with extra keys.
CREATE FUNCTION pg_temp.i9_head(p_made jsonb, p_cust uuid, p_no integer, p_day text, p_extra jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY DEFINER AS $$
  SELECT jsonb_build_object('inv_no',p_no,'inv_fin_year',warehouse_security.financial_year(warehouse_security.business_date(p_day::timestamptz)),
    'customer_id',p_cust,'customer_name','Inv129 Customer A','inv_date',p_day,'total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy',
    'gr_id',COALESCE(p_made->>'grn_id',p_made->>'gr_id'),'gr_no',p_made->>'gr_no') || p_extra $$;
CREATE FUNCTION pg_temp.i9_save(p_head jsonb, p_lines jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.i9_call(format('SELECT public.save_invoice(NULL::uuid,%L::jsonb,ARRAY(SELECT jsonb_array_elements(%L::jsonb)))',p_head,p_lines)) $$;
CREATE FUNCTION pg_temp.i9_update(p_id uuid, p_head jsonb, p_lines jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.i9_call(format('SELECT public.update_invoice(%L::uuid,%L::jsonb,ARRAY(SELECT jsonb_array_elements(%L::jsonb)))',p_id,p_head,p_lines)) $$;
-- The stored invoice as text, to see that a refusal wrote nothing.
CREATE FUNCTION pg_temp.i9_stored(p_id uuid) RETURNS text LANGUAGE sql SECURITY DEFINER AS $$
  SELECT COALESCE((SELECT concat_ws('|', business_date_text, inv_no, discount, total, notes, line_count) FROM (
    SELECT to_char(warehouse_security.business_date(i.inv_date),'YYYY-MM-DD') AS business_date_text, i.inv_no, i.discount, i.total, i.notes,
           (SELECT count(*) FROM public.invoice_trl t WHERE t.invoice_id=i.id) AS line_count FROM public.invoice i WHERE i.id=p_id) s),'(none)') $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9555555501','Inv129 Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT pg_temp.i9_login('9555555501') AS admin_claims \gset
SELECT warehouse_security.business_date(now()) AS today, warehouse_security.business_date(now())+1 AS tomorrow, warehouse_security.business_date(now())-1 AS yesterday \gset

SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_assert(public.create_customer('Inv129 Customer A','9555555511')->>'success'='true' AND public.create_item('Inv129 Potatoes','Bag')->>'success'='true','customer and item');
RESET ROLE;
SELECT id AS ca FROM public.customers WHERE name='Inv129 Customer A' \gset
SELECT id AS potatoes FROM public.items WHERE name='Inv129 Potatoes' \gset

-- ===========================================================================
-- A. An invoice is not dated before the latest dispatch of its lines
-- ===========================================================================
-- I1: 100 bags received 2026-04-01, 20 dispatched on DA1 (2026-05-02) and 80 on DA2 (2026-06-10).
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_assert(public.save_grn(p_gr_no=>'IV1',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'ca'::uuid,p_customer_name=>'Inv129 Customer A',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'potatoes','item_name','Inv129 Potatoes','packaging','Bag','qty',100,'weight',10,'rack','R1','package_mark','IV1-P')))->>'success'='true','GRN IV1');
RESET ROLE;
SELECT id AS grn_1 FROM public.goodsreceived WHERE gr_no='IV1' \gset
SELECT id AS lot_1 FROM public.goodsreceived_trl WHERE gr_id=:'grn_1'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','DA1','disp_date','2026-05-02','customer_id',:'ca','customer_name','Inv129 Customer A','supervisor_id',:'admin_profile','supervisor_name','Inv129 Administrator'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_1','disp_qty',20)],0,'i9-da1') AS da1 \gset
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','DA2','disp_date','2026-06-10','customer_id',:'ca','customer_name','Inv129 Customer A','supervisor_id',:'admin_profile','supervisor_name','Inv129 Administrator'),
 ARRAY[jsonb_build_object('gr_trl_id',:'lot_1','disp_qty',80)],0,'i9-da2') AS da2 \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'da1'::jsonb->>'success'='true' AND :'da2'::jsonb->>'success'='true','fixture dispatches: '||:'da1'||:'da2');
SELECT jsonb_agg(jsonb_build_object('disp_trl_id',dt.id,'grn_item_id',dt.gr_trl_id,'duration',1,'charge',10,'tax',0,'labour_rate',2) ORDER BY d.disp_no) AS lines_1,
       (array_agg(dt.id ORDER BY d.disp_no))[1] AS line_da1, (array_agg(dt.id ORDER BY d.disp_no))[2] AS line_da2
  FROM public.dispatch_trl dt JOIN public.dispatch d ON d.id=dt.disp_id WHERE dt.gr_id=:'grn_1'::uuid \gset
SELECT jsonb_build_object('gr_id',:'grn_1','gr_no','IV1') AS made_1 \gset
-- Dated the day before DA2: refused, naming the latest dispatch, and nothing is written.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_save(pg_temp.i9_head(:'made_1'::jsonb,:'ca'::uuid,129001,'2026-06-09'),:'lines_1'::jsonb) AS a_early,
       pg_temp.i9_save(pg_temp.i9_head(:'made_1'::jsonb,:'ca'::uuid,129001,'2026-05-02'),:'lines_1'::jsonb) AS a_much_earlier \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'a_early'::jsonb->>'success'='false' AND :'a_early'::jsonb->>'reason'='INVOICE_BEFORE_DISPATCH' AND :'a_early'::jsonb->>'error_code'='WH409'
 AND :'a_early'::jsonb->>'invoice_date'='2026-06-09' AND :'a_early'::jsonb->>'dispatch_no'='DA2' AND :'a_early'::jsonb->>'dispatch_date'='2026-06-10'
 AND :'a_early'::jsonb->>'message'='The invoice date 2026-06-09 is before dispatch DA2 (2026-06-10).'
 AND :'a_much_earlier'::jsonb->>'reason'='INVOICE_BEFORE_DISPATCH' AND :'a_much_earlier'::jsonb->>'dispatch_no'='DA2'
 AND (SELECT count(*)=0 FROM public.invoice WHERE gr_id=:'grn_1'::uuid) AND (SELECT NOT invoiced FROM public.goodsreceived WHERE id=:'grn_1'::uuid),
 'save: dated before the latest dispatch is refused with the dispatch named, and nothing is written: '||:'a_early');
-- The twin: dated the day of the latest dispatch.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_save(pg_temp.i9_head(:'made_1'::jsonb,:'ca'::uuid,129001,'2026-06-10'),:'lines_1'::jsonb) AS a_ok \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'a_ok'::jsonb->>'success'='true','save: dated the day of the latest dispatch is saved: '||:'a_ok');
SELECT (:'a_ok'::jsonb->>'invoice_id')::uuid AS inv_1 \gset
-- update_invoice: moving the date before the dispatch is refused; the invoice stays as it was.
SELECT pg_temp.i9_stored(:'inv_1'::uuid) AS stored_1 \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_update(:'inv_1'::uuid,pg_temp.i9_head(:'made_1'::jsonb,:'ca'::uuid,129001,'2026-06-09'),:'lines_1'::jsonb) AS a_upd_early,
       pg_temp.i9_update(:'inv_1'::uuid,pg_temp.i9_head(:'made_1'::jsonb,:'ca'::uuid,129001,'2026-06-11'),:'lines_1'::jsonb) AS a_upd_later \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'a_upd_early'::jsonb->>'reason'='INVOICE_BEFORE_DISPATCH' AND :'a_upd_early'::jsonb->>'dispatch_no'='DA2' AND :'a_upd_early'::jsonb->>'invoice_date'='2026-06-09'
 AND :'a_upd_later'::jsonb->>'success'='true' AND pg_temp.i9_stored(:'inv_1'::uuid) LIKE '2026-06-11|129001|%',
 'update: a date before the dispatch is refused, a later date is saved: '||:'a_upd_early'||:'a_upd_later');
-- An old invoice dated before its dispatch (stored that way) can still be edited for other reasons: the rule looks at what changes.
UPDATE public.invoice SET inv_date='2026-05-15T12:00:00Z' WHERE id=:'inv_1'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_update(:'inv_1'::uuid,pg_temp.i9_head(:'made_1'::jsonb,:'ca'::uuid,129001,'2026-05-15T12:00:00Z',jsonb_build_object('notes','a note')),:'lines_1'::jsonb) AS a_upd_same \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'a_upd_same'::jsonb->>'success'='true' AND pg_temp.i9_stored(:'inv_1'::uuid) LIKE '2026-05-15|129001|%|a note|2',
 'update: the same date and the same lines are not checked, so an old invoice can take a note: '||:'a_upd_same'||pg_temp.i9_stored(:'inv_1'::uuid));
-- The helper's other branch: a changed set of lines with the unchanged date is checked (the stored lines are DA1 and DA2, the edit sends DA2 only).
SELECT pg_temp.i9_helper(format('SELECT warehouse_security.check_invoice_dates(%L::uuid,%L::timestamptz,ARRAY[%L::uuid,%L::uuid])',:'inv_1','2026-05-15T12:00:00Z',:'line_da1',:'line_da2')) AS h_same,
       pg_temp.i9_helper(format('SELECT warehouse_security.check_invoice_dates(%L::uuid,%L::timestamptz,ARRAY[%L::uuid])',:'inv_1','2026-05-15T12:00:00Z',:'line_da2')) AS h_changed,
       pg_temp.i9_helper(format('SELECT warehouse_security.check_invoice_dates(%L::uuid,%L::timestamptz,ARRAY[%L::uuid])',:'inv_1','2026-05-15T12:00:00Z',:'line_da1')) AS h_changed_ok \gset
SELECT pg_temp.i9_assert(:'h_same'::jsonb='{"ok":true}'::jsonb AND :'h_changed'::jsonb->>'reason'='INVOICE_BEFORE_DISPATCH' AND :'h_changed'::jsonb->>'dispatch_no'='DA2'
 AND :'h_changed_ok'::jsonb='{"ok":true}'::jsonb,
 'a changed set of lines is checked against the dispatches of the new set, the same set is not: '||:'h_same'||:'h_changed'||:'h_changed_ok');
-- An edit that sends no date uses the stored one (2026-05-15) for the lines it changes, and checks nothing when the lines are the same.
SELECT pg_temp.i9_helper(format('SELECT warehouse_security.check_invoice_dates(%L::uuid,NULL::timestamptz,ARRAY[%L::uuid,%L::uuid])',:'inv_1',:'line_da1',:'line_da2')) AS n_same,
       pg_temp.i9_helper(format('SELECT warehouse_security.check_invoice_dates(%L::uuid,NULL::timestamptz,ARRAY[%L::uuid])',:'inv_1',:'line_da2')) AS n_changed,
       pg_temp.i9_helper(format('SELECT warehouse_security.check_invoice_dates(%L::uuid,NULL::timestamptz,ARRAY[%L::uuid])',:'inv_1',:'line_da1')) AS n_changed_ok,
       pg_temp.i9_helper(format('SELECT warehouse_security.check_invoice_dates(NULL::uuid,NULL::timestamptz,ARRAY[%L::uuid])',:'line_da2')) AS n_new \gset
SELECT pg_temp.i9_assert(:'n_same'::jsonb='{"ok":true}'::jsonb AND :'n_changed'::jsonb->>'reason'='INVOICE_BEFORE_DISPATCH' AND :'n_changed'::jsonb->>'dispatch_no'='DA2'
 AND :'n_changed'::jsonb->>'invoice_date'='2026-05-15' AND :'n_changed_ok'::jsonb='{"ok":true}'::jsonb AND :'n_new'::jsonb='{"ok":true}'::jsonb,
 'no date sent: the stored date is used for changed lines, same lines pass, and a new invoice without a date is left to the save: '||:'n_same'||:'n_changed'||:'n_changed_ok'||:'n_new');
-- ===========================================================================
-- B. An invoice is not dated in the future
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_make('IV2',10,'2026-04-01','DB1','2026-05-02',:'ca'::uuid,:'potatoes'::uuid,:'admin_profile'::uuid) AS made_2 \gset
RESET ROLE;
SELECT jsonb_build_array(:'made_2'::jsonb->'line') AS lines_2 \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_save(pg_temp.i9_head(:'made_2'::jsonb,:'ca'::uuid,129002,:'tomorrow'),:'lines_2'::jsonb) AS b_future \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'b_future'::jsonb->>'success'='false' AND :'b_future'::jsonb->>'reason'='INVOICE_DATE_FUTURE' AND :'b_future'::jsonb->>'error_code'='WH409'
 AND :'b_future'::jsonb->>'date'=:'tomorrow' AND :'b_future'::jsonb->>'today'=:'today'
 AND :'b_future'::jsonb->>'message'=format('An invoice can''t be dated in the future. Today is %s.',:'today')
 AND (SELECT count(*)=0 FROM public.invoice WHERE gr_id=(:'made_2'::jsonb->>'grn_id')::uuid) AND (SELECT NOT invoiced FROM public.goodsreceived WHERE id=(:'made_2'::jsonb->>'grn_id')::uuid),
 'save: tomorrow (India) is refused with today''s date, and nothing is written: '||:'b_future');
-- The twin: today (India) is saved.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_save(pg_temp.i9_head(:'made_2'::jsonb,:'ca'::uuid,129002,:'today'),:'lines_2'::jsonb) AS b_today \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'b_today'::jsonb->>'success'='true','save: today is saved: '||:'b_today');
SELECT (:'b_today'::jsonb->>'invoice_id')::uuid AS inv_2 \gset
-- update_invoice: moving the date to tomorrow is refused, to yesterday is saved.
SELECT pg_temp.i9_stored(:'inv_2'::uuid) AS stored_2 \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_update(:'inv_2'::uuid,pg_temp.i9_head(:'made_2'::jsonb,:'ca'::uuid,129002,:'tomorrow'),:'lines_2'::jsonb) AS b_upd_future \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'b_upd_future'::jsonb->>'reason'='INVOICE_DATE_FUTURE' AND :'b_upd_future'::jsonb->>'date'=:'tomorrow' AND :'b_upd_future'::jsonb->>'today'=:'today'
 AND pg_temp.i9_stored(:'inv_2'::uuid)=:'stored_2','update: a date in the future is refused and the invoice is unchanged: '||:'b_upd_future');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_update(:'inv_2'::uuid,pg_temp.i9_head(:'made_2'::jsonb,:'ca'::uuid,129002,:'yesterday'),:'lines_2'::jsonb) AS b_upd_past \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'b_upd_past'::jsonb->>'success'='true' AND pg_temp.i9_stored(:'inv_2'::uuid) LIKE :'yesterday'||'|129002|%','update: yesterday is saved: '||:'b_upd_past');
-- A stored invoice that is dated in the future (made before this rule) is not touched by an edit that leaves its date alone; moving its date is checked.
UPDATE public.invoice SET inv_date=(:'tomorrow'||'T12:00:00Z')::timestamptz WHERE id=:'inv_2'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_update(:'inv_2'::uuid,pg_temp.i9_head(:'made_2'::jsonb,:'ca'::uuid,129002,:'tomorrow'||'T12:00:00Z',jsonb_build_object('notes','kept','inv_fin_year',pg_temp.i9_fy(:'yesterday'::date))),:'lines_2'::jsonb) AS b_upd_keep,
       pg_temp.i9_update(:'inv_2'::uuid,pg_temp.i9_head(:'made_2'::jsonb,:'ca'::uuid,129002,(:'tomorrow'::date+1)::text,jsonb_build_object('inv_fin_year',pg_temp.i9_fy(:'tomorrow'::date+1))),:'lines_2'::jsonb) AS b_upd_move \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'b_upd_keep'::jsonb->>'success'='true' AND pg_temp.i9_stored(:'inv_2'::uuid) LIKE :'tomorrow'||'|129002|%|kept|1'
 AND :'b_upd_move'::jsonb->>'reason'='INVOICE_DATE_FUTURE' AND :'b_upd_move'::jsonb->>'date'=(:'tomorrow'::date+1)::text,
 'update: a stored future date stays as it is when the edit leaves the date alone, and moving it is checked: '||:'b_upd_keep'||:'b_upd_move');
-- ===========================================================================
-- C. A discount may not take a charged invoice to exactly 0
-- ===========================================================================
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_make('IV3',10,'2026-04-01','DC1','2026-05-02',:'ca'::uuid,:'potatoes'::uuid,:'admin_profile'::uuid) AS made_3 \gset
SELECT pg_temp.i9_make('IV4',10,'2026-04-01','DC2','2026-05-02',:'ca'::uuid,:'potatoes'::uuid,:'admin_profile'::uuid) AS made_4 \gset
RESET ROLE;
SELECT jsonb_build_array(:'made_3'::jsonb->'line') AS lines_3, jsonb_build_array(:'made_4'::jsonb->'line') AS lines_4 \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_save(pg_temp.i9_head(:'made_3'::jsonb,:'ca'::uuid,129003,'2026-06-20'),:'lines_3'::jsonb) AS c_base \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'c_base'::jsonb->>'success'='true','set-up: an invoice without a discount: '||:'c_base');
SELECT (:'c_base'::jsonb->>'invoice_id')::uuid AS inv_3 \gset
SELECT total AS total_3 FROM public.invoice WHERE id=:'inv_3'::uuid \gset
SELECT pg_temp.i9_assert(:'total_3'::numeric>1,'set-up: the invoice has a total to discount: '||:'total_3');
SELECT pg_temp.i9_stored(:'inv_3'::uuid) AS stored_3 \gset
-- Update: a discount equal to the total is refused, with the figures; the invoice is unchanged.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_update(:'inv_3'::uuid,pg_temp.i9_head(:'made_3'::jsonb,:'ca'::uuid,129003,'2026-06-20',jsonb_build_object('discount',:'total_3'::numeric,'discount_reason','Test discount')),:'lines_3'::jsonb) AS c_upd_zero,
       pg_temp.i9_update(:'inv_3'::uuid,pg_temp.i9_head(:'made_3'::jsonb,:'ca'::uuid,129003,'2026-06-20',jsonb_build_object('discount',:'total_3'::numeric+5,'discount_reason','Test discount')),:'lines_3'::jsonb) AS c_upd_over \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'c_upd_zero'::jsonb->>'success'='false' AND :'c_upd_zero'::jsonb->>'reason'='DISCOUNT_TOTAL_ZERO' AND :'c_upd_zero'::jsonb->>'error_code'='WH409'
 AND (:'c_upd_zero'::jsonb->>'discount')::numeric=:'total_3'::numeric AND (:'c_upd_zero'::jsonb->>'total_before_discount')::numeric=:'total_3'::numeric
 AND pg_temp.i9_stored(:'inv_3'::uuid)=:'stored_3',
 'update: a discount that takes the total to 0 is refused with the figures, and the invoice is unchanged: '||:'c_upd_zero'||pg_temp.i9_stored(:'inv_3'::uuid));
SELECT pg_temp.i9_assert(:'c_upd_over'::jsonb->>'success'='false' AND :'c_upd_over'::jsonb->>'error'='Discount exceeds the invoice amount' AND :'c_upd_over'::jsonb->>'reason' IS NULL,
 'twin: a discount above the total keeps its own refusal: '||:'c_upd_over');
-- The twin: one rupee less leaves a total of 1.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_update(:'inv_3'::uuid,pg_temp.i9_head(:'made_3'::jsonb,:'ca'::uuid,129003,'2026-06-20',jsonb_build_object('discount',:'total_3'::numeric-1,'discount_reason','Test discount')),:'lines_3'::jsonb) AS c_upd_one \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'c_upd_one'::jsonb->>'success'='true' AND (SELECT total=1 AND discount=:'total_3'::numeric-1 FROM public.invoice WHERE id=:'inv_3'::uuid),
 'update: a discount of the total less 1 is saved and leaves a total of 1: '||:'c_upd_one');
-- An invoice already stored at 0 by a discount (allowed before the rule) still takes a note: the rule is for an edit that changes the discount or the lines.
UPDATE public.invoice SET discount=:'total_3'::numeric, total=0 WHERE id=:'inv_3'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_update(:'inv_3'::uuid,pg_temp.i9_head(:'made_3'::jsonb,:'ca'::uuid,129003,'2026-06-20',jsonb_build_object('discount',:'total_3'::numeric,'discount_reason','Test discount','notes','note only')),:'lines_3'::jsonb) AS c_note_only \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'c_note_only'::jsonb->>'success'='true' AND (SELECT total=0 AND discount=:'total_3'::numeric AND notes='note only' FROM public.invoice WHERE id=:'inv_3'::uuid),
 'update: a stored invoice at 0 by a discount takes a note-only edit: '||:'c_note_only');
-- But when the edit moves the total (here the stored total is made stale, as a charge or tax change under the discount would move it) and the new total is 0, it is refused.
UPDATE public.invoice SET total=7 WHERE id=:'inv_3'::uuid;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_update(:'inv_3'::uuid,pg_temp.i9_head(:'made_3'::jsonb,:'ca'::uuid,129003,'2026-06-20',jsonb_build_object('discount',:'total_3'::numeric,'discount_reason','Test discount','notes','note only')),:'lines_3'::jsonb) AS c_moved_zero \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'c_moved_zero'::jsonb->>'reason'='DISCOUNT_TOTAL_ZERO' AND (SELECT total=7 FROM public.invoice WHERE id=:'inv_3'::uuid),
 'update: an edit that moves the total to 0 under an unchanged discount is refused and nothing is written: '||:'c_moved_zero');
UPDATE public.invoice SET total=0 WHERE id=:'inv_3'::uuid;
-- Save: the same refusal for a new invoice (same GRN set-up, so the same total), and nothing is written.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_save(pg_temp.i9_head(:'made_4'::jsonb,:'ca'::uuid,129004,'2026-06-20',jsonb_build_object('discount',:'total_3'::numeric,'discount_reason','Test discount')),:'lines_4'::jsonb) AS c_save_zero \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'c_save_zero'::jsonb->>'reason'='DISCOUNT_TOTAL_ZERO' AND (:'c_save_zero'::jsonb->>'discount')::numeric=:'total_3'::numeric
 AND (:'c_save_zero'::jsonb->>'total_before_discount')::numeric=:'total_3'::numeric
 AND (SELECT count(*)=0 FROM public.invoice WHERE gr_id=(:'made_4'::jsonb->>'grn_id')::uuid) AND (SELECT NOT invoiced FROM public.goodsreceived WHERE id=(:'made_4'::jsonb->>'grn_id')::uuid),
 'save: a discount that takes the total to 0 is refused and nothing is written: '||:'c_save_zero');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_save(pg_temp.i9_head(:'made_4'::jsonb,:'ca'::uuid,129004,'2026-06-20',jsonb_build_object('discount',:'total_3'::numeric-1,'discount_reason','Test discount')),:'lines_4'::jsonb) AS c_save_one \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'c_save_one'::jsonb->>'success'='true' AND (SELECT total=1 FROM public.invoice WHERE gr_id=(:'made_4'::jsonb->>'grn_id')::uuid),
 'save: a discount of the total less 1 is saved: '||:'c_save_one');
-- ===========================================================================
-- D. The rates changed since the form opened
-- ===========================================================================
-- Potatoes: 6.00 rent, 2.50 labour, 5 tax from 2026-01-01. Four GRNs of 10 bags dated 2026-04-01, dispatched on 2026-05-02.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_call(format('SELECT public.replace_item_rates(p_item_id=>%L,p_customer_id=>NULL,p_price_type=>%L,p_starts_on=>%L,p_bands=>%L::jsonb)',
  :'potatoes','monthly','2026-01-01',jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',6,'labour_rate',2.5,'tax_percent',5)))) AS d_rate1 \gset
SELECT pg_temp.i9_make('IV5',10,'2026-04-01','DE1','2026-05-02',:'ca'::uuid,:'potatoes'::uuid,:'admin_profile'::uuid) AS made_5 \gset
SELECT pg_temp.i9_make('IV6',10,'2026-04-01','DE2','2026-05-02',:'ca'::uuid,:'potatoes'::uuid,:'admin_profile'::uuid) AS made_6 \gset
SELECT pg_temp.i9_make('IV7',10,'2026-04-01','DE3','2026-05-02',:'ca'::uuid,:'potatoes'::uuid,:'admin_profile'::uuid) AS made_7 \gset
SELECT pg_temp.i9_make('IV8',10,'2026-04-01','DE4','2026-05-02',:'ca'::uuid,:'potatoes'::uuid,:'admin_profile'::uuid) AS made_8 \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'d_rate1'::jsonb->>'success'='true','set-up: the potato rate: '||:'d_rate1');
-- What the form looks up for IV5 now: the figures the app would send as looked_up.
SELECT (e->>'unit_price')::numeric AS lu_charge, (e->>'labour_rate')::numeric AS lu_labour, (e->>'tax_percent')::numeric AS lu_tax
  FROM jsonb_array_elements(public.build_invoice_form_lines((:'made_5'::jsonb->>'grn_id')::uuid,'legacy')->'items') e \gset
SELECT pg_temp.i9_assert(:'lu_charge'::numeric=6 AND :'lu_labour'::numeric=2.5 AND :'lu_tax'::numeric=5,'the form looks up 6.00 / 2.50 / 5: '||:'lu_charge'||'/'||:'lu_labour'||'/'||:'lu_tax');
-- The rate changes to 7.00 / 3.00 / 5 from 2026-03-01, after the form was opened.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_call(format('SELECT public.replace_item_rates(p_item_id=>%L,p_customer_id=>NULL,p_price_type=>%L,p_starts_on=>%L,p_bands=>%L::jsonb)',
  :'potatoes','monthly','2026-03-01',jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',7,'labour_rate',3,'tax_percent',5)))) AS d_rate2 \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'d_rate2'::jsonb->>'success'='true','set-up: the rate changed: '||:'d_rate2');
-- A line as the app sends it: the figure it saves, what it looked up, and which figures were typed by hand (omitted when none).
CREATE FUNCTION pg_temp.i9_ln(p_made jsonb, p_charge numeric, p_looked jsonb, p_typed jsonb DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_array((p_made->'line') || jsonb_build_object('charge',p_charge)
    || CASE WHEN p_looked IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('looked_up',p_looked) END
    || CASE WHEN p_typed IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('typed',p_typed) END) $$;
SELECT '{"charge":6,"labour_rate":2.5,"tax":5}'::jsonb AS stale, '{"charge":7,"labour_rate":3,"tax":5}'::jsonb AS fresh \gset
-- Stale figures, nothing typed: refused with the changed figures of the line; nothing written.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_save(pg_temp.i9_head(:'made_5'::jsonb,:'ca'::uuid,129005,'2026-06-20'),pg_temp.i9_ln(:'made_5'::jsonb,6,:'stale'::jsonb)) AS d_stale \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'d_stale'::jsonb->>'success'='false' AND :'d_stale'::jsonb->>'reason'='RATES_CHANGED' AND :'d_stale'::jsonb->>'error_code'='WH409'
 AND jsonb_array_length(:'d_stale'::jsonb->'lines')=1 AND :'d_stale'::jsonb#>>'{lines,0,disp_trl_id}'=(:'made_5'::jsonb#>>'{line,disp_trl_id}')
 AND :'d_stale'::jsonb#>'{lines,0,fields}'='["charge","labour_rate"]'::jsonb
 AND (:'d_stale'::jsonb#>>'{lines,0,looked_up,charge}')::numeric=6 AND (:'d_stale'::jsonb#>>'{lines,0,current,charge}')::numeric=7
 AND (:'d_stale'::jsonb#>>'{lines,0,current,labour_rate}')::numeric=3 AND (:'d_stale'::jsonb#>>'{lines,0,current,tax}')::numeric=5
 AND (SELECT count(*)=0 FROM public.invoice WHERE gr_id=(:'made_5'::jsonb->>'grn_id')::uuid) AND (SELECT NOT invoiced FROM public.goodsreceived WHERE id=(:'made_5'::jsonb->>'grn_id')::uuid),
 'save: a figure that changed since the form looked it up is refused with the old and the new figures, and nothing is written: '||:'d_stale');
-- The twin: the same GRN with the current figures looked up is saved.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_save(pg_temp.i9_head(:'made_5'::jsonb,:'ca'::uuid,129005,'2026-06-20'),pg_temp.i9_ln(:'made_5'::jsonb,7,:'fresh'::jsonb)) AS d_fresh \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'d_fresh'::jsonb->>'success'='true','save: the looked-up figures still match, so the invoice is saved: '||:'d_fresh');
-- Typed by hand: all three (true), or only some of them (a list).
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_save(pg_temp.i9_head(:'made_6'::jsonb,:'ca'::uuid,129006,'2026-06-20'),pg_temp.i9_ln(:'made_6'::jsonb,6,:'stale'::jsonb,'true'::jsonb)) AS d_typed_all,
       pg_temp.i9_save(pg_temp.i9_head(:'made_7'::jsonb,:'ca'::uuid,129007,'2026-06-20'),pg_temp.i9_ln(:'made_7'::jsonb,6,:'stale'::jsonb,'["charge"]'::jsonb)) AS d_typed_part \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'d_typed_all'::jsonb->>'success'='true' AND (SELECT sum(t.charge)=6 FROM public.invoice_trl t JOIN public.invoice i ON i.id=t.invoice_id WHERE i.gr_id=(:'made_6'::jsonb->>'grn_id')::uuid),
 'save: figures typed by hand are not compared, whatever the lookup says: '||:'d_typed_all');
SELECT pg_temp.i9_assert(:'d_typed_part'::jsonb->>'reason'='RATES_CHANGED' AND :'d_typed_part'::jsonb#>'{lines,0,fields}'='["labour_rate"]'::jsonb,
 'save: a typed charge is not compared but a looked-up labour rate still is: '||:'d_typed_part');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_save(pg_temp.i9_head(:'made_7'::jsonb,:'ca'::uuid,129007,'2026-06-20'),pg_temp.i9_ln(:'made_7'::jsonb,6,:'stale'::jsonb,'["charge","labour_rate"]'::jsonb)) AS d_typed_two \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'d_typed_two'::jsonb->>'success'='true','save: charge and labour rate typed, tax unchanged: saved: '||:'d_typed_two');
-- An older app sends no looked_up: not checked.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_save(pg_temp.i9_head(:'made_8'::jsonb,:'ca'::uuid,129008,'2026-06-20'),pg_temp.i9_ln(:'made_8'::jsonb,6,NULL)) AS d_old_app \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'d_old_app'::jsonb->>'success'='true','save: a line without looked_up is not checked: '||:'d_old_app');
SELECT (:'d_old_app'::jsonb->>'invoice_id')::uuid AS inv_8 \gset
-- update_invoice compares the same way, and writes nothing on a refusal.
SELECT pg_temp.i9_stored(:'inv_8'::uuid) AS stored_8 \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.i9_update(:'inv_8'::uuid,pg_temp.i9_head(:'made_8'::jsonb,:'ca'::uuid,129008,'2026-06-20',jsonb_build_object('notes','edited')),pg_temp.i9_ln(:'made_8'::jsonb,6,:'stale'::jsonb)) AS d_upd_stale,
       pg_temp.i9_update(:'inv_8'::uuid,pg_temp.i9_head(:'made_8'::jsonb,:'ca'::uuid,129008,'2026-06-20',jsonb_build_object('notes','edited')),pg_temp.i9_ln(:'made_8'::jsonb,7,:'fresh'::jsonb)) AS d_upd_fresh \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'d_upd_stale'::jsonb->>'reason'='RATES_CHANGED' AND :'d_upd_stale'::jsonb#>'{lines,0,fields}'='["charge","labour_rate"]'::jsonb
 AND :'d_upd_fresh'::jsonb->>'success'='true' AND pg_temp.i9_stored(:'inv_8'::uuid) LIKE '%|edited|1',
 'update: stale looked-up figures are refused, current ones are saved: '||:'d_upd_stale'||:'d_upd_fresh');
ROLLBACK;
