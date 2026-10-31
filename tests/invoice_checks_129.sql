-- Migration 129, invoices (save_invoice and update_invoice):
--   A. an invoice is not dated before the latest dispatch of its lines (INVOICE_BEFORE_DISPATCH); an edit is checked only when the
--      date or the set of lines changes
--   B. an invoice is not dated in the future (India day): INVOICE_DATE_FUTURE with today's date; stored future dates are not touched
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
-- A GRN of p_qty bags of the item (no rate check, as before this migration), fully dispatched on one dispatch. Run as a signed-in administrator.
-- Answers the GRN id, its number, the invoice line of the one dispatch line and the dispatch id.
CREATE FUNCTION pg_temp.i9_make(p_no text, p_qty integer, p_grn_day date, p_disp_no text, p_disp_day date, p_customer uuid, p_item uuid, p_admin uuid) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_grn jsonb; v_grn_id uuid; v_lot uuid; v_disp jsonb; v_line jsonb;
BEGIN
  v_grn := public.save_grn(p_gr_no=>p_no, p_date=>(p_grn_day::text||'T12:00:00Z')::timestamptz, p_customer_id=>p_customer, p_customer_name=>'Inv129 Customer A',
    p_pricing_mode=>'MONTHLY', p_items=>jsonb_build_array(jsonb_build_object('item_id',p_item,'item_name','Inv129 Potatoes','packaging','Bag','qty',p_qty,'weight',10,'rack','R1','package_mark',p_no||'-P')));
  IF v_grn->>'success' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'fixture GRN % failed: %', p_no, v_grn; END IF;
  SELECT g.id INTO v_grn_id FROM public.goodsreceived g WHERE g.gr_no = p_no;
  SELECT t.id INTO v_lot FROM public.goodsreceived_trl t WHERE t.gr_id = v_grn_id;
  v_disp := public.create_dispatch_with_stock_check(jsonb_build_object('disp_no',p_disp_no,'disp_date',p_disp_day,'customer_id',p_customer,
    'customer_name','Inv129 Customer A','supervisor_id',p_admin,'supervisor_name','Inv129 Administrator'),
    ARRAY[jsonb_build_object('gr_trl_id',v_lot,'disp_qty',p_qty)], 0, 'i9-'||p_disp_no);
  IF v_disp->>'success' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'fixture dispatch % failed: %', p_disp_no, v_disp; END IF;
  SELECT jsonb_build_object('disp_trl_id',dt.id,'grn_item_id',dt.gr_trl_id,'duration',1,'charge',10,'tax',0,'labour_rate',2) INTO v_line
    FROM public.dispatch_trl dt WHERE dt.disp_id = (v_disp->>'dispatch_id')::uuid;
  RETURN jsonb_build_object('grn_id',v_grn_id,'gr_no',p_no,'line',v_line,'dispatch_id',v_disp->>'dispatch_id');
END $$;
-- The header of an invoice of a made GRN, dated p_day (a date or a timestamp as text), with extra keys.
CREATE FUNCTION pg_temp.i9_head(p_made jsonb, p_cust uuid, p_no integer, p_day text, p_extra jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('inv_no',p_no,'inv_fin_year',warehouse_security.financial_year(warehouse_security.business_date(p_day::timestamptz)),
    'customer_id',p_cust,'customer_name','Inv129 Customer A','inv_date',p_day,'total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy',
    'gr_id',p_made->>'grn_id','gr_no',p_made->>'gr_no') || p_extra $$;
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
SELECT pg_temp.i9_update(:'inv_2'::uuid,pg_temp.i9_head(:'made_2'::jsonb,:'ca'::uuid,129002,:'tomorrow'||'T12:00:00Z',jsonb_build_object('notes','kept','inv_fin_year',warehouse_security.financial_year(:'yesterday'::date))),:'lines_2'::jsonb) AS b_upd_keep,
       pg_temp.i9_update(:'inv_2'::uuid,pg_temp.i9_head(:'made_2'::jsonb,:'ca'::uuid,129002,(:'tomorrow'::date+1)::text,jsonb_build_object('inv_fin_year',warehouse_security.financial_year(:'tomorrow'::date+1))),:'lines_2'::jsonb) AS b_upd_move \gset
RESET ROLE;
SELECT pg_temp.i9_assert(:'b_upd_keep'::jsonb->>'success'='true' AND pg_temp.i9_stored(:'inv_2'::uuid) LIKE :'tomorrow'||'|129002|%|kept|1'
 AND :'b_upd_move'::jsonb->>'reason'='INVOICE_DATE_FUTURE' AND :'b_upd_move'::jsonb->>'date'=(:'tomorrow'::date+1)::text,
 'update: a stored future date stays as it is when the edit leaves the date alone, and moving it is checked: '||:'b_upd_keep'||:'b_upd_move');
ROLLBACK;
