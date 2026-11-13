-- WH-188 (with WH-187, migration 193): the not-invoiced figure Customer dues and the statement show for a GRN
-- (warehouse_security.not_invoiced_grns) is the figure the invoice form gives for the same goods. The reference here is the form itself:
-- build_invoice_form_lines, then form_document_lines and form_documents, the way migration 176's grn_not_invoiced (dropped by 193) put
-- them together for a new invoice. It fails when the two differ, for a seeded set that covers
--   customer rates, a GRN's own rates, lots with no rate, weight bands, an exempt item, an ONE_TIME GRN, partial dispatches,
--   a GRN whose dispatches were imported (WH-180) and are not invoiced yet, a closed GRN, a customer with a GSTIN,
-- and for every combination of GST (not saved, saved and not registered, registered), rounding (up, nearest, none) and charging steps
-- (15/30, 1/0, 30/60). It also checks that the dues list and each customer's statement give one figure, that grn_not_invoiced is gone,
-- and that the figures do not move between two reads. Fictional data; runs only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.wc_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'dues and form: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.wc_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.wc_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.wc_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
CREATE FUNCTION pg_temp.wc_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;

-- The invoice form's own figure for one GRN: the goods that have left on no live invoice, and the goods in store as one dispatch today.
-- (migration 176's grn_not_invoiced, kept here as the reference).
CREATE FUNCTION pg_temp.wc_form(p_gr_id uuid, p_today date) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_customer uuid;
  v_rounding text := (warehouse_security.current_charging_rule()).rounding;
  v_free uuid[]; v_form jsonb; v_lines jsonb; v_docs jsonb; v_left jsonb; v_store jsonb; v_no_rate jsonb := '[]'::jsonb;
BEGIN
  SELECT g.customer_id INTO v_customer FROM public.goodsreceived g WHERE g.id = p_gr_id AND g.deleted_at IS NULL;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM set_config('warehouse.form_invoice_id', '', true);
  PERFORM set_config('warehouse.form_in_store_date', '', true);
  SELECT array_agg(dt.id) INTO v_free
    FROM public.dispatch_trl dt
    JOIN public.goodsreceived_trl grt ON grt.id = dt.gr_trl_id
    JOIN public.dispatch d ON d.id = dt.disp_id AND d.deleted_at IS NULL
   WHERE grt.gr_id = p_gr_id
     AND NOT EXISTS (SELECT 1 FROM public.invoice_trl it JOIN public.invoice iv ON iv.id = it.invoice_id
                     WHERE it.disp_trl_id = dt.id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL);
  IF v_free IS NOT NULL THEN
    v_form := public.build_invoice_form_lines(p_gr_id, NULL);
    IF v_form->>'success' = 'true' THEN
      v_lines := warehouse_security.form_document_lines(v_form, v_free);
      IF jsonb_array_length(v_lines) > 0 THEN
        v_docs := COALESCE(NULLIF(warehouse_security.form_documents(v_lines, v_customer, NULL::public.invoice, v_rounding)->'documents', 'null'::jsonb), '[]'::jsonb);
        v_left := jsonb_build_object('bags', (SELECT sum((l->>'qty')::numeric) FROM jsonb_array_elements(v_lines) l),
          'amount', (SELECT COALESCE(sum((d->>'total')::numeric), 0) FROM jsonb_array_elements(v_docs) d)::numeric(14,2));
        v_no_rate := v_no_rate || (SELECT COALESCE(jsonb_agg(DISTINCT l->'lot_id'), '[]'::jsonb) FROM jsonb_array_elements(v_lines) l WHERE NOT (l->>'has_rate')::boolean);
      END IF;
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.gr_id = p_gr_id AND t.stock > 0) THEN
    PERFORM set_config('warehouse.form_in_store_date', to_char(p_today, 'YYYY-MM-DD'), true);
    v_form := public.build_invoice_form_lines(p_gr_id, NULL);
    PERFORM set_config('warehouse.form_in_store_date', '', true);
    IF v_form->>'success' = 'true' THEN
      v_lines := warehouse_security.form_document_lines(v_form, NULL);
      IF jsonb_array_length(v_lines) > 0 THEN
        v_docs := COALESCE(NULLIF(warehouse_security.form_documents(v_lines, v_customer, NULL::public.invoice, v_rounding)->'documents', 'null'::jsonb), '[]'::jsonb);
        v_store := jsonb_build_object('bags', (SELECT sum((l->>'qty')::numeric) FROM jsonb_array_elements(v_lines) l),
          'amount', (SELECT COALESCE(sum((d->>'total')::numeric), 0) FROM jsonb_array_elements(v_docs) d)::numeric(14,2),
          'lots', (SELECT jsonb_agg(jsonb_build_object('grn_item_id', l->'lot_id', 'has_rate', l->'has_rate',
                     'amount', CASE WHEN (l->>'has_rate')::boolean THEN
                       ((l->>'base')::numeric + floor((l->>'base')::numeric * (l->>'tax_percent')::numeric) / 100.0)::numeric(14,2) END))
                   FROM jsonb_array_elements(v_lines) l));
        v_no_rate := v_no_rate || (SELECT COALESCE(jsonb_agg(DISTINCT l->'lot_id'), '[]'::jsonb) FROM jsonb_array_elements(v_lines) l WHERE NOT (l->>'has_rate')::boolean);
      END IF;
    END IF;
  END IF;
  RETURN jsonb_build_object('gr_id', p_gr_id, 'left', v_left, 'in_store', v_store, 'no_rate', v_no_rate);
END $$;

-- Every difference between the form's figures and not_invoiced_grns for the whole facility on a day, as text ('' for none).
CREATE FUNCTION pg_temp.wc_diff(p_today date) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r record; f jsonb; out text := ''; v_ids uuid[]; v_seen integer := 0;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
  -- The GRNs the old loop looked at: live, of a live customer, with stock or a dispatch line on no live invoice.
  SELECT array_agg(g.id) INTO v_ids FROM public.goodsreceived g JOIN public.customers c ON c.id = g.customer_id AND c.deleted_at IS NULL
   WHERE g.deleted_at IS NULL AND (EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.gr_id = g.id AND t.stock > 0)
          OR warehouse_security.grn_has_free_dispatch_line(g.id));
  FOR r IN SELECT x.* FROM warehouse_security.not_invoiced_grns(NULL, p_today) x LOOP
    v_seen := v_seen + 1;
    IF NOT (r.gr_id = ANY (COALESCE(v_ids, ARRAY[]::uuid[]))) THEN out := out || format('[%s: a row for a GRN the form would not look at] ', r.gr_no); CONTINUE; END IF;
    f := pg_temp.wc_form(r.gr_id, p_today);
    IF COALESCE((f#>>'{left,amount}')::numeric, -1) IS DISTINCT FROM COALESCE(r.left_amount, -1) THEN
      out := out || format('[%s left amount: form %s, dues %s] ', r.gr_no, f#>>'{left,amount}', r.left_amount); END IF;
    IF COALESCE((f#>>'{left,bags}')::numeric, -1) IS DISTINCT FROM COALESCE(r.left_bags, -1) THEN
      out := out || format('[%s left bags: form %s, dues %s] ', r.gr_no, f#>>'{left,bags}', r.left_bags); END IF;
    IF COALESCE((f#>>'{in_store,amount}')::numeric, -1) IS DISTINCT FROM COALESCE(r.store_amount, -1) THEN
      out := out || format('[%s in-store amount: form %s, dues %s] ', r.gr_no, f#>>'{in_store,amount}', r.store_amount); END IF;
    IF COALESCE((f#>>'{in_store,bags}')::numeric, -1) IS DISTINCT FROM COALESCE(r.store_bags, -1) THEN
      out := out || format('[%s in-store bags: form %s, dues %s] ', r.gr_no, f#>>'{in_store,bags}', r.store_bags); END IF;
    IF (SELECT COALESCE(jsonb_agg(DISTINCT x ORDER BY x), '[]') FROM jsonb_array_elements_text(f->'no_rate') x)
       IS DISTINCT FROM (SELECT COALESCE(jsonb_agg(DISTINCT x ORDER BY x), '[]') FROM unnest(COALESCE(r.no_rate_lot_ids, ARRAY[]::text[])) x) THEN
      out := out || format('[%s lots without a rate: form %s, dues %s] ', r.gr_no, f->'no_rate', r.no_rate_lot_ids); END IF;
    IF (SELECT COALESCE(jsonb_agg(jsonb_build_object('l', l->>'grn_item_id', 'a', l->>'amount') ORDER BY l->>'grn_item_id'), '[]') FROM jsonb_array_elements(COALESCE(f#>'{in_store,lots}', '[]')) l)
       IS DISTINCT FROM (SELECT COALESCE(jsonb_agg(jsonb_build_object('l', l->>'grn_item_id', 'a', l->>'amount') ORDER BY l->>'grn_item_id'), '[]') FROM jsonb_array_elements(COALESCE(r.store_lots, '[]')) l) THEN
      out := out || format('[%s lot amounts: form %s, dues %s] ', r.gr_no, f#>'{in_store,lots}', r.store_lots); END IF;
  END LOOP;
  -- A GRN the form has a figure for that dues has no row for.
  FOR r IN SELECT g.id, g.gr_no FROM public.goodsreceived g WHERE g.id = ANY (COALESCE(v_ids, ARRAY[]::uuid[]))
              AND NOT EXISTS (SELECT 1 FROM warehouse_security.not_invoiced_grns(NULL, p_today) n WHERE n.gr_id = g.id) LOOP
    f := pg_temp.wc_form(r.id, p_today);
    IF f->'left' IS NOT NULL AND jsonb_typeof(f->'left') = 'object' OR f->'in_store' IS NOT NULL AND jsonb_typeof(f->'in_store') = 'object' THEN
      out := out || format('[%s: the form has a figure, dues has no row] ', r.gr_no); END IF;
  END LOOP;
  IF v_seen = 0 THEN out := out || '[no GRN has a figure at all: the set is empty] '; END IF;
  RETURN out;
END $$;

-- ===== the set =====
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888931','Dues Form Administrator') AS boot \gset
SELECT pg_temp.wc_login('9888888931') AS admin_claims \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888888931' \gset
SELECT warehouse_security.business_date(now()) AS today \gset
UPDATE warehouse_security.charging_rule SET days_counted = 'legacy', invoice_as_goods_leave = true WHERE id;
INSERT INTO public.customers(name,mobile) VALUES ('Dues Form Alpha','9888888932') RETURNING id AS c1 \gset
INSERT INTO public.customers(name,mobile,gst) VALUES ('Dues Form Beta','9888888933','24AAACC1206D1ZM') RETURNING id AS c2 \gset
INSERT INTO public.customers(name,mobile) VALUES ('Dues Form Gamma','9888888934') RETURNING id AS c3 \gset
INSERT INTO public.items(name,packaging) VALUES ('Dues Form Potato','Bag') RETURNING id AS ix \gset
INSERT INTO public.items(name,packaging) VALUES ('Dues Form Mustard','Bag') RETURNING id AS iy \gset
INSERT INTO public.items(name,packaging,gst_treatment) VALUES ('Dues Form Grain','Bag','exempt_agri') RETURNING id AS iz \gset
SELECT pg_temp.wc_assert((SELECT gst_treatment FROM public.items WHERE id = :'iz'::uuid) = 'exempt_agri', 'the exempt item is set');
SELECT (:'today'::date - 600) AS rate_from \gset
-- General rates: Potato 5.00 + labour 2.00, tax 5 %; Grain by weight band (0-30 at 4.00, 31-100 at 6.50), tax 0; Mustard has none.
SELECT pg_temp.wc_as(:'admin_claims'::jsonb, format($q$SELECT public.replace_item_rates(%L::uuid,NULL,'monthly',%L::date,
  '[{"weight_min":0,"weight_max":100,"unit_price":5,"labour_rate":2,"tax_percent":5}]'::jsonb)$q$, :'ix', :'rate_from')) AS r1 \gset
SELECT pg_temp.wc_as(:'admin_claims'::jsonb, format($q$SELECT public.replace_item_rates(%L::uuid,NULL,'monthly',%L::date,
  '[{"weight_min":0,"weight_max":30,"unit_price":4,"labour_rate":1,"tax_percent":0},{"weight_min":31,"weight_max":100,"unit_price":6.5,"labour_rate":1.5,"tax_percent":0}]'::jsonb)$q$, :'iz', :'rate_from')) AS r2 \gset
-- One-time rate for Potato, and a customer rate for Alpha (8.00 + labour 3.00, tax 12 %).
SELECT pg_temp.wc_as(:'admin_claims'::jsonb, format($q$SELECT public.replace_item_rates(%L::uuid,NULL,'one_time',%L::date,
  '[{"weight_min":0,"weight_max":100,"unit_price":20,"labour_rate":2,"tax_percent":5}]'::jsonb)$q$, :'ix', :'rate_from')) AS r3 \gset
SELECT pg_temp.wc_as(:'admin_claims'::jsonb, format($q$SELECT public.replace_item_rates(%L::uuid,%L::uuid,'monthly',%L::date,
  '[{"weight_min":0,"weight_max":100,"unit_price":8,"labour_rate":3,"tax_percent":12}]'::jsonb)$q$, :'ix', :'c1', :'rate_from')) AS r4 \gset
SELECT pg_temp.wc_assert(:'r1'::jsonb->>'success' = 'true' AND :'r2'::jsonb->>'success' = 'true' AND :'r3'::jsonb->>'success' = 'true' AND :'r4'::jsonb->>'success' = 'true',
  'rates saved: ' || :'r1' || :'r2' || :'r3' || :'r4');
-- A GRN save and a dispatch, as the app makes them. Dates are days before today.
CREATE FUNCTION pg_temp.wc_grn(p_claims jsonb, p_no text, p_days integer, p_customer uuid, p_mode text, p_lines jsonb, p_rates jsonb DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.wc_as(p_claims, format($q$SELECT public.save_grn(p_gr_no=>%L,p_date=>%L::timestamptz,p_customer_id=>%L::uuid,p_customer_name=>'x',p_pricing_mode=>%L,
    p_idempotency_key=>%L,p_items=>%L::jsonb,p_rates=>%L::jsonb)$q$, p_no, (warehouse_security.business_date(now()) - p_days)::text || 'T12:00:00Z', p_customer, p_mode, 'wc-' || p_no, p_lines, p_rates)) $$;
CREATE FUNCTION pg_temp.wc_line(p_item uuid, p_name text, p_qty integer, p_weight integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('item_id',p_item,'item_name',p_name,'packaging','Bag','qty',p_qty,'weight',p_weight,'rack','R1') $$;
CREATE FUNCTION pg_temp.wc_disp(p_claims jsonb, p_no text, p_days integer, p_customer uuid, p_profile uuid, p_gr_no text, p_item uuid, p_qty integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.wc_as(p_claims, format($q$SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no',%L,'disp_date',%L,'customer_id',%L,'customer_name','x',
    'supervisor_id',%L,'supervisor_name','x'),ARRAY[jsonb_build_object('gr_trl_id',(SELECT t.id FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id
      WHERE g.gr_no=%L AND t.item_id=%L LIMIT 1),'disp_qty',%s)],false,0,%L)$q$,
    p_no, (warehouse_security.business_date(now()) - p_days)::text || 'T12:00:00Z', p_customer, p_profile, p_gr_no, p_item, p_qty, 'wc-' || p_no)) $$;

-- G1 (Alpha, customer rate; a Grain line in the weight bands): two lines, both partly dispatched.
SELECT pg_temp.wc_grn(:'admin_claims'::jsonb, 'A0001', 120, :'c1'::uuid, 'MONTHLY', jsonb_build_array(pg_temp.wc_line(:'ix'::uuid,'Dues Form Potato',40,50), pg_temp.wc_line(:'iz'::uuid,'Dues Form Grain',30,20))) AS g1 \gset
SELECT pg_temp.wc_disp(:'admin_claims'::jsonb, 'I0001', 60, :'c1'::uuid, :'admin_profile'::uuid, 'A0001', :'ix'::uuid, 15) AS d1 \gset
SELECT pg_temp.wc_disp(:'admin_claims'::jsonb, 'I0002', 30, :'c1'::uuid, :'admin_profile'::uuid, 'A0001', :'iz'::uuid, 10) AS d2 \gset
-- G2 (Beta, a GSTIN; the GRN's own rate 9.00 + 1.00, tax 18 %): part dispatched.
SELECT pg_temp.wc_grn(:'admin_claims'::jsonb, 'A0002', 90, :'c2'::uuid, 'MONTHLY', jsonb_build_array(pg_temp.wc_line(:'ix'::uuid,'Dues Form Potato',20,50)),
  jsonb_build_array(jsonb_build_object('scope','grn','item_id',:'ix','weight_min',0,'weight_max',100,'unit_price',9,'labour_rate',1,'tax_percent',18))) AS g2 \gset
SELECT pg_temp.wc_disp(:'admin_claims'::jsonb, 'I0003', 10, :'c2'::uuid, :'admin_profile'::uuid, 'A0002', :'ix'::uuid, 5) AS d3 \gset
-- G3 (Beta, Mustard has no rate anywhere): a lot with no rate, left and in store.
SELECT pg_temp.wc_grn(:'admin_claims'::jsonb, 'A0003', 50, :'c2'::uuid, 'MONTHLY', jsonb_build_array(pg_temp.wc_line(:'iy'::uuid,'Dues Form Mustard',10,50))) AS g3 \gset
SELECT pg_temp.wc_disp(:'admin_claims'::jsonb, 'I0004', 5, :'c2'::uuid, :'admin_profile'::uuid, 'A0003', :'iy'::uuid, 4) AS d4 \gset
-- G4 (Gamma, one time): everything in store.
SELECT pg_temp.wc_grn(:'admin_claims'::jsonb, 'A0004', 200, :'c3'::uuid, 'ONE_TIME', jsonb_build_array(pg_temp.wc_line(:'ix'::uuid,'Dues Form Potato',12,50))) AS g4 \gset
-- G6 (Alpha, closed): all dispatched and invoiced (so it has no figure).
SELECT pg_temp.wc_grn(:'admin_claims'::jsonb, 'A0006', 100, :'c1'::uuid, 'MONTHLY', jsonb_build_array(pg_temp.wc_line(:'ix'::uuid,'Dues Form Potato',10,50))) AS g6 \gset
SELECT pg_temp.wc_disp(:'admin_claims'::jsonb, 'I0006', 40, :'c1'::uuid, :'admin_profile'::uuid, 'A0006', :'ix'::uuid, 10) AS d6 \gset
SELECT pg_temp.wc_assert(:'g1'::jsonb->>'success' = 'true' AND :'g2'::jsonb->>'success' = 'true' AND :'g3'::jsonb->>'success' = 'true' AND :'g4'::jsonb->>'success' = 'true'
  AND :'g6'::jsonb->>'success' = 'true', 'GRNs saved: ' || :'g1' || :'g2' || :'g3' || :'g4' || :'g6');
SELECT pg_temp.wc_assert(:'d1'::jsonb->>'success' = 'true' AND :'d2'::jsonb->>'success' = 'true' AND :'d3'::jsonb->>'success' = 'true' AND :'d4'::jsonb->>'success' = 'true'
  AND :'d6'::jsonb->>'success' = 'true', 'dispatches saved: ' || :'d1' || :'d2' || :'d3' || :'d4' || :'d6');
SELECT d.id AS d6_line FROM public.dispatch_trl d JOIN public.dispatch x ON x.id = d.disp_id WHERE x.disp_no = 'I0006' \gset
SELECT id AS g6_id FROM public.goodsreceived WHERE gr_no = 'A0006' \gset
SELECT warehouse_security.financial_year(:'today'::date) AS cur_fy \gset
CREATE FUNCTION pg_temp.wc_save_invoice(doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;
SELECT pg_temp.wc_as(:'admin_claims'::jsonb, format($q$SELECT pg_temp.wc_save_invoice(jsonb_build_object('inv_fin_year', %s, 'gr_id', %L, 'gr_no', 'A0006', 'customer_id', %L,
  'customer_name', 'Dues Form Alpha', 'inv_date', now(), 'total', 0, 'tax_amount', 0, 'discount', 0, 'duration_mode', 'legacy', 'inv_no', 1,
  'items', jsonb_build_array(jsonb_build_object('disp_trl_id', %L, 'charge', 8, 'tax', 12, 'labour_rate', 3))))$q$, :'cur_fy', :'g6_id', :'c1', :'d6_line')) AS inv6 \gset
SELECT pg_temp.wc_assert(:'inv6'::jsonb->>'success' = 'true', 'the closed GRN is invoiced: ' || :'inv6');

-- G5 (Gamma): imported with dispatches that are on no invoice yet (WH-180), then the app's rates apply to them.
INSERT INTO warehouse_import.stage_grns(line,gr_no,gr_date,customer,pricing) VALUES (2,'A0005', :'today'::date - 300, 'Dues Form Gamma', 'MONTHLY');
INSERT INTO warehouse_import.stage_grn_lines(line,gr_no,gr_date,line_no,item,packaging,qty,weight,stock_now) VALUES
 (2,'A0005', :'today'::date - 300, 1, 'Dues Form Potato', 'Bag', 30, 50, 10),
 (3,'A0005', :'today'::date - 300, 2, 'Dues Form Grain', 'Bag', 8, 20, 8);
INSERT INTO warehouse_import.stage_dispatches(line,disp_no,disp_date,customer) VALUES
 (2,'I0007', :'today'::date - 250, 'Dues Form Gamma'), (3,'I0008', :'today'::date - 100, 'Dues Form Gamma');
INSERT INTO warehouse_import.stage_dispatch_lines(line,disp_no,disp_date,gr_no,gr_date,grn_line,qty) VALUES
 (2,'I0007', :'today'::date - 250, 'A0005', :'today'::date - 300, 1, 12),
 (3,'I0008', :'today'::date - 100, 'A0005', :'today'::date - 300, 1, 8);
-- G7 (Gamma): imported dispatches I0009 (before) and I0010 (after) an imported invoice GC/9 whose line names no dispatch: I0009 is taken as billed
-- by GC/9 (WH-180, spec answer 4), I0010 is not. The form and dues must agree with a taken-as-billed dispatch present.
INSERT INTO warehouse_import.stage_grns(line,gr_no,gr_date,customer,pricing) VALUES (3,'A0007', :'today'::date - 300, 'Dues Form Gamma', 'MONTHLY');
INSERT INTO warehouse_import.stage_grn_lines(line,gr_no,gr_date,line_no,item,packaging,qty,weight,stock_now) VALUES
 (4,'A0007', :'today'::date - 300, 1, 'Dues Form Potato', 'Bag', 20, 50, 10);
INSERT INTO warehouse_import.stage_dispatches(line,disp_no,disp_date,customer) VALUES
 (4,'I0009', :'today'::date - 250, 'Dues Form Gamma'), (5,'I0010', :'today'::date - 200, 'Dues Form Gamma');
INSERT INTO warehouse_import.stage_dispatch_lines(line,disp_no,disp_date,gr_no,gr_date,grn_line,qty) VALUES
 (4,'I0009', :'today'::date - 250, 'A0007', :'today'::date - 300, 1, 5),
 (5,'I0010', :'today'::date - 200, 'A0007', :'today'::date - 300, 1, 5);
INSERT INTO warehouse_import.stage_invoices(line,inv_label,inv_no,inv_prefix,inv_date,customer,gr_no,gr_date,labour,tax,total) VALUES
 (2,'GC/9', 9, 'GC/', :'today'::date - 250, 'Dues Form Gamma', 'A0007', :'today'::date - 300, 10.00, 0.00, 110.00);
INSERT INTO warehouse_import.stage_invoice_lines(line,inv_label,inv_no,inv_date,item,packaging,qty,disp_no,disp_date,grn_line,rate,labour_rate,tax_pct,storage,labour,tax_amount) VALUES
 (2,'GC/9', 9, :'today'::date - 250, 'Dues Form Potato', 'Bag', 5, NULL, NULL, NULL, 20.00, 2.00, 0, 100.00, 10.00, 0.00);
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true) AS c \gset
SET LOCAL ROLE service_role;
SELECT public.import_history('{}'::jsonb, true) AS imported \gset
RESET ROLE;
SELECT pg_temp.wc_assert(:'imported'::jsonb->>'success' = 'true', 'the import: ' || :'imported');
SELECT pg_temp.wc_assert((SELECT count(*) FROM public.dispatch WHERE import_batch_id IS NOT NULL) = 4
  AND NOT EXISTS (SELECT 1 FROM public.invoice_trl it JOIN public.dispatch_trl dt ON dt.id = it.disp_trl_id JOIN public.dispatch d ON d.id = dt.disp_id WHERE d.import_batch_id IS NOT NULL),
  'four imported dispatches, on no invoice line');
SELECT pg_temp.wc_assert((SELECT count(*) FROM public.imported_billed_dispatches) = 1
  AND (SELECT d.disp_no || '>' || i.inv_no FROM public.imported_billed_dispatches b JOIN public.dispatch_trl dt ON dt.id = b.disp_trl_id JOIN public.dispatch d ON d.id = dt.disp_id JOIN public.invoice i ON i.id = b.invoice_id) = 'I0009>9',
  'I0009 is taken as billed by GC/9, and only that one');

-- ===== WH-187: the old per-GRN function is gone, the new one is the only caller path =====
SELECT pg_temp.wc_assert(to_regprocedure('warehouse_security.grn_not_invoiced(uuid,date)') IS NULL, 'grn_not_invoiced is dropped');
SELECT pg_temp.wc_assert(to_regprocedure('warehouse_security.not_invoiced_grns(uuid,date)') IS NOT NULL, 'not_invoiced_grns exists');
SELECT pg_temp.wc_assert(NOT has_function_privilege('anon', 'warehouse_security.not_invoiced_grns(uuid,date)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'warehouse_security.not_invoiced_grns(uuid,date)', 'EXECUTE'), 'not_invoiced_grns is not callable by the app roles');

-- ===== WH-188: the figures agree, in every setting =====
CREATE TEMP TABLE wc_log(variant text, diff text, total numeric) ON COMMIT DROP;
CREATE FUNCTION pg_temp.wc_variant(p_gst text, p_rounding text, p_step integer, p_min integer, p_today date) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM public.system_settings WHERE key = 'facility_legal';
  IF p_gst = 'unregistered' THEN
    INSERT INTO public.system_settings(key, value) VALUES ('facility_legal', '{"gstSavedAt":"2026-01-01T00:00:00Z","gstRegistered":false}');
  ELSIF p_gst = 'registered' THEN
    INSERT INTO public.system_settings(key, value) VALUES ('facility_legal',
      '{"gstSavedAt":"2026-01-01T00:00:00Z","gstRegistered":true,"gstin":"27AAPFU0939F1ZV","legalName":"Dues Form Facility","address":"Test Road, Pune"}');
  END IF;
  UPDATE warehouse_security.charging_rule SET step_days = p_step, minimum_days = p_min, rounding = p_rounding WHERE id;
  INSERT INTO wc_log VALUES (format('gst=%s rounding=%s step=%s/%s', p_gst, p_rounding, p_step, p_min), pg_temp.wc_diff(p_today),
    (SELECT COALESCE(sum(COALESCE(left_amount, 0) + COALESCE(store_amount, 0)), 0) FROM warehouse_security.not_invoiced_grns(NULL, p_today)));
END $$;
DO $$
DECLARE g text; r text; s integer[]; v_today date := warehouse_security.business_date(now());
BEGIN
  FOREACH g IN ARRAY ARRAY['none', 'unregistered', 'registered'] LOOP
    FOREACH r IN ARRAY ARRAY['up', 'nearest', 'none'] LOOP
      FOREACH s SLICE 1 IN ARRAY ARRAY[[15, 30], [1, 0], [30, 60]] LOOP
        BEGIN
          PERFORM pg_temp.wc_variant(g, r, s[1], s[2], v_today);
        EXCEPTION WHEN check_violation OR invalid_parameter_value THEN
          INSERT INTO wc_log VALUES (format('gst=%s rounding=%s step=%s/%s', g, r, s[1], s[2]), 'the rule was refused: ' || SQLERRM, NULL);
        END;
      END LOOP;
    END LOOP;
  END LOOP;
END $$;
SELECT pg_temp.wc_assert((SELECT count(*) FROM wc_log) = 27, 'every combination ran: ' || (SELECT count(*) FROM wc_log));
SELECT pg_temp.wc_assert(NOT EXISTS (SELECT 1 FROM wc_log WHERE diff <> ''),
  'the invoice form and dues disagree: ' || COALESCE((SELECT string_agg(variant || ' => ' || diff, E'\n') FROM (SELECT * FROM wc_log WHERE diff <> '' LIMIT 6) x), ''));
-- The set is sensitive to every setting: the totals differ between the variants (a test that always said "equal" would not).
SELECT pg_temp.wc_assert((SELECT count(DISTINCT total) FROM wc_log) >= 8, 'the settings change the figures: ' || (SELECT count(DISTINCT total) FROM wc_log) || ' different totals in 27 variants');
SELECT pg_temp.wc_assert((SELECT count(DISTINCT total) FROM wc_log WHERE variant LIKE 'gst=none rounding=up%') >= 2, 'the charging steps change the figures: ' || (SELECT string_agg(variant || '=' || total, '; ') FROM wc_log));
SELECT pg_temp.wc_assert((SELECT count(DISTINCT total) FROM wc_log WHERE variant LIKE '%rounding=nearest step=15/30') >= 2, 'GST changes the figures');
SELECT pg_temp.wc_assert((SELECT count(DISTINCT total) FROM wc_log WHERE variant LIKE 'gst=registered %step=15/30') >= 2, 'the rounding changes the figures');

-- The set covers what it says (default rule, GST registered, so the exempt line, the GSTIN customer and the inter-state document all count).
UPDATE warehouse_security.charging_rule SET step_days = 15, minimum_days = 30, rounding = 'up' WHERE id;
SELECT pg_temp.wc_assert(pg_temp.wc_diff(:'today'::date) = '', 'the default rule agrees');
SELECT n.* INTO TEMP wc_rows FROM warehouse_security.not_invoiced_grns(NULL, :'today'::date) n;
SELECT pg_temp.wc_assert((SELECT left_amount > 0 AND store_amount > 0 AND left_bags = 15 + 10 AND store_bags = 25 + 20 FROM wc_rows WHERE gr_no = 'A0001'), 'A0001 (customer rate, two lines): left and in store');
SELECT pg_temp.wc_assert((SELECT left_amount > 0 AND store_amount > 0 AND left_bags = 5 AND store_bags = 15 FROM wc_rows WHERE gr_no = 'A0002'), 'A0002 (own rate): left and in store');
SELECT pg_temp.wc_assert((SELECT cardinality(no_rate_lot_ids) = 1 AND left_amount IS NOT NULL AND store_amount IS NOT NULL FROM wc_rows WHERE gr_no = 'A0003'), 'A0003 (no rate): one lot without a rate');
SELECT pg_temp.wc_assert((SELECT left_amount IS NULL AND store_amount > 0 AND store_bags = 12 FROM wc_rows WHERE gr_no = 'A0004'), 'A0004 (one time): all in store');
SELECT pg_temp.wc_assert((SELECT left_bags = 20 AND left_amount > 0 AND store_bags = 18 FROM wc_rows WHERE gr_no = 'A0005'), 'A0005 (imported dispatches on no invoice): 20 bags to bill at the app''s rates, 18 in store');
SELECT pg_temp.wc_assert(NOT EXISTS (SELECT 1 FROM wc_rows WHERE gr_no = 'A0006'), 'A0006 (closed and invoiced) has no row');
SELECT pg_temp.wc_assert((SELECT left_bags = 5 AND left_amount > 0 AND store_bags = 10 FROM wc_rows WHERE gr_no = 'A0007'), 'A0007: I0010 only is to bill (5 bags), I0009 is taken as billed, 10 bags in store');
-- The GRN's own rate is used by both: raising it moves A0002's figure, and the two still agree.
UPDATE public.grn_rates SET unit_price = 19 WHERE gr_id = (SELECT id FROM public.goodsreceived WHERE gr_no = 'A0002');
SELECT pg_temp.wc_assert((SELECT store_amount FROM warehouse_security.not_invoiced_grns(NULL, :'today'::date) WHERE gr_no = 'A0002') > (SELECT store_amount FROM wc_rows WHERE gr_no = 'A0002')
  AND pg_temp.wc_diff(:'today'::date) = '', 'the own rate of A0002 is used by the form and by dues');
UPDATE public.grn_rates SET unit_price = 9 WHERE gr_id = (SELECT id FROM public.goodsreceived WHERE gr_no = 'A0002');

-- The dues list and each customer's statement give one figure, and a second read gives the same figures.
SELECT pg_temp.wc_as(:'admin_claims'::jsonb, $q$SELECT public.get_customer_dues()$q$) AS dues1 \gset
SELECT pg_temp.wc_as(:'admin_claims'::jsonb, $q$SELECT public.get_customer_dues()$q$) AS dues2 \gset
SELECT pg_temp.wc_assert(:'dues1'::jsonb->>'success' = 'true', 'dues is answered: ' || :'dues1');
SELECT pg_temp.wc_assert((:'dues1'::jsonb - 'as_of') = (:'dues2'::jsonb - 'as_of'), 'two reads of dues give the same figures');
SELECT pg_temp.wc_assert((SELECT bool_and(
    (st.s->'figures'->>'not_invoiced_left')::numeric = (c->>'not_invoiced_left')::numeric
    AND (st.s->'figures'->>'not_invoiced_in_store')::numeric = (c->>'not_invoiced_in_store')::numeric
    AND (st.s->'figures'->>'invoices_amount')::numeric = (c->>'invoices_amount')::numeric
    AND (st.s->>'lots_without_rate')::int = (c->>'lots_without_rate')::int)
  FROM jsonb_array_elements(:'dues1'::jsonb->'customers') c
  CROSS JOIN LATERAL (SELECT pg_temp.wc_as(:'admin_claims'::jsonb, format($q$SELECT public.get_customer_statement(%L::uuid)$q$, c->>'customer_id')) AS s) st), 'each customer''s statement gives the dues figures');
SELECT pg_temp.wc_assert(jsonb_array_length(:'dues1'::jsonb->'customers') = 3, 'three customers owe: ' || (:'dues1'::jsonb->>'totals'));
-- Dues totals are the sum of the statements' figures and of the per-GRN rows.
SELECT pg_temp.wc_assert((:'dues1'::jsonb#>>'{totals,not_invoiced_left}')::numeric = (SELECT sum(left_amount) FROM wc_rows)
  AND (:'dues1'::jsonb#>>'{totals,not_invoiced_in_store}')::numeric = (SELECT sum(store_amount) FROM wc_rows), 'the dues totals are the sums of the GRN figures');
-- The statement's own GRN rows are the not_invoiced_grns rows.
SELECT pg_temp.wc_as(:'admin_claims'::jsonb, format($q$SELECT public.get_customer_statement(%L::uuid)$q$, :'c1')) AS st1 \gset
SELECT pg_temp.wc_assert((SELECT sum((e->>'amount')::numeric) FROM jsonb_array_elements(:'st1'::jsonb->'left') e) = (SELECT sum(left_amount) FROM wc_rows WHERE customer_id = :'c1'::uuid)
  AND (SELECT sum((e->>'amount')::numeric) FROM jsonb_array_elements(:'st1'::jsonb->'in_store') e) = (SELECT sum(store_amount) FROM wc_rows WHERE customer_id = :'c1'::uuid),
  'the statement rows are the GRN figures');
ROLLBACK;
\echo 'Dues and the invoice form agree for every setting of GST, rounding and charging steps.'
