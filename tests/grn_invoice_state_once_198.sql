-- WH-198 (migration "GRN invoice state once"): warehouse_security.invoiced_grn_states() (every GRN with a live invoice, worked out once per read, used by the
-- invoiced filter of get_grn_list and get_all_grn_items) and warehouse_security.grn_invoice_state(id) (one GRN; the invoice_state of each row) are one rule in two
-- forms. This suite pins them together: for EVERY GRN, COALESCE(state from invoiced_grn_states(), 'not_invoiced') = grn_invoice_state(id), with "Invoice goods as
-- they leave" on and off, on a fully invoiced GRN, a partly invoiced one (stock left), one with a free dispatch line, one whose invoice is cancelled, a deleted
-- one, two live invoices, a GRN whose dispatch line a live imported invoice takes as billed (and the same with that invoice cancelled), a live invoice with no
-- dispatch at all, and a GRN with no invoice. It also pins: the set has one row per GRN and never says not_invoiced; no client role may read it; the filter values
-- null and "abc" with the setting off (and on) answer as before the migration (JSON null: no GRN with the setting off, the not-invoiced GRNs with it on; "abc":
-- 22P02), in both lists; and the filtered lists equal the GRNs the per-GRN state names.
-- Fictional data; runs after all migrations in migrations.sh's disposable, network-disabled database; every fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.st_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'grn invoice state once: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.st_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.st_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.st_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The answer of a statement run as the signed-in account, or {"raised": message, "state": sqlstate}.
CREATE FUNCTION pg_temp.st_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
-- A receipt of one line (qty bags), saved as the account; returns the receipt id.
CREATE FUNCTION pg_temp.st_grn(claims jsonb, no text, qty integer, customer uuid, item uuid) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE a jsonb;
BEGIN
  a := pg_temp.st_as(claims, format($f$SELECT public.save_grn(p_sender_name=>'Fixture Sender',p_supervisor_id=>(SELECT id FROM public.user_profiles WHERE NOT is_service_account ORDER BY created_at LIMIT 1),p_supervisor_name=>'Fixture Supervisor',p_gr_no=>%L,p_date=>'2026-04-01T12:00:00Z',p_customer_id=>%L::uuid,p_customer_name=>'State Demo Customer',
    p_pricing_mode=>'MONTHLY',p_idempotency_key=>%L,p_items=>jsonb_build_array(jsonb_build_object('item_id',%L,'item_name','State Demo Potatoes','packaging','Bag','qty',%s,'weight',10,'rack','S1')))$f$,
    no, customer, 'st-'||no, item, qty));
  PERFORM pg_temp.st_assert(a->>'success'='true','receipt '||no||' saved: '||a);
  RETURN (SELECT id FROM public.goodsreceived WHERE gr_no=no);
END $$;
-- A dispatch of qty bags from the receipt's one line, saved as the account; returns the dispatch line id.
CREATE FUNCTION pg_temp.st_disp(claims jsonb, no text, grn uuid, qty integer, customer uuid, profile uuid) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE a jsonb;
BEGIN
  a := pg_temp.st_as(claims, format($f$SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no',%L,'disp_date','2026-05-02T12:00:00Z','customer_id',%L,
    'customer_name','State Demo Customer','supervisor_id',%L,'supervisor_name','State Administrator'),
    ARRAY[jsonb_build_object('gr_trl_id',%L,'disp_qty',%s)],false,0,%L)$f$,
    no, customer, profile, (SELECT id FROM public.goodsreceived_trl WHERE gr_id=grn ORDER BY id LIMIT 1), qty, 'st-'||no));
  PERFORM pg_temp.st_assert(a->>'success'='true','dispatch '||no||' saved: '||a);
  RETURN (SELECT t.id FROM public.dispatch_trl t JOIN public.dispatch d ON d.id=t.disp_id WHERE d.disp_no=no);
END $$;
-- An invoice of the given dispatch lines, saved as the account; returns the invoice id.
CREATE FUNCTION pg_temp.st_inv(claims jsonb, inv_no integer, grn uuid, customer uuid, lines uuid[]) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE a jsonb;
BEGIN
  a := pg_temp.st_as(claims, format($f$SELECT public.save_invoice(NULL::uuid, %L::jsonb, ARRAY(SELECT jsonb_build_object('grn_item_id', d.gr_trl_id, 'duration', 1, 'disp_trl_id', d.id,
    'charge', 5, 'tax', 5, 'labour_rate', 2) FROM public.dispatch_trl d WHERE d.id = ANY(%L::uuid[])))$f$,
    jsonb_build_object('inv_no', inv_no, 'inv_fin_year', 2026, 'gr_id', grn, 'gr_no', (SELECT gr_no FROM public.goodsreceived WHERE id=grn), 'customer_id', customer,
      'customer_name', 'State Demo Customer', 'inv_date', '2026-05-02T12:00:00Z', 'total', 0, 'tax_amount', 0, 'discount', 0, 'duration_mode', 'legacy'), lines));
  PERFORM pg_temp.st_assert(a->>'success'='true','invoice '||inv_no||' saved: '||a);
  RETURN (a->>'invoice_id')::uuid;
END $$;
CREATE FUNCTION pg_temp.st_list_grns(answer jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(e->>'gr_no', ',' ORDER BY e->>'gr_no'), '') FROM jsonb_array_elements(COALESCE(answer#>'{data,grns}', answer->'grns', '[]'::jsonb)) e WHERE e->>'gr_no' LIKE 'ST%' $$;
CREATE FUNCTION pg_temp.st_item_grns(answer jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(DISTINCT e->>'gr_no', ',' ORDER BY e->>'gr_no'), '') FROM jsonb_array_elements(COALESCE(answer->'data', '[]'::jsonb)) e WHERE e->>'gr_no' LIKE 'ST%' $$;
CREATE FUNCTION pg_temp.st_list(claims jsonb, filters jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.st_as(claims, format('SELECT public.get_grn_list(p_filters => %L::jsonb, p_limit => 100)', filters::text)) $$;
CREATE FUNCTION pg_temp.st_items(claims jsonb, filters jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.st_as(claims, format('SELECT public.get_all_grn_items(p_filters => %L::jsonb, p_limit => 100)', filters::text)) $$;
-- The fixture receipts the per-GRN state names as the given state (the reference the filters are held to).
CREATE FUNCTION pg_temp.st_named(state text) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(gr_no, ',' ORDER BY gr_no), '') FROM public.goodsreceived WHERE gr_no LIKE 'ST%' AND warehouse_security.grn_invoice_state(id) = state $$;
-- Every GRN of the database: the two forms must agree. Returns the receipts that differ, "" when none; also counts the GRNs compared.
CREATE FUNCTION pg_temp.st_disagree() RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(g.gr_no || ':' || COALESCE(s.invoice_state, 'not_invoiced') || '<>' || warehouse_security.grn_invoice_state(g.id), ',' ORDER BY g.gr_no), '')
    FROM public.goodsreceived g LEFT JOIN warehouse_security.invoiced_grn_states() s ON s.gr_id = g.id
   WHERE COALESCE(s.invoice_state, 'not_invoiced') IS DISTINCT FROM warehouse_security.grn_invoice_state(g.id) $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888841','State Administrator') AS admin_user \gset
SELECT pg_temp.st_login('9888888841') AS admin_claims \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_customer('State Demo Customer','9888888845') AS customer \gset
SELECT public.create_item('State Demo Potatoes','Bag') AS item1 \gset
SELECT id AS customer_id FROM public.customers WHERE name='State Demo Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='State Demo Potatoes' \gset
SELECT public.replace_item_rates(:'item_id'::uuid,:'customer_id'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5))) AS price \gset
RESET ROLE;
SELECT pg_temp.st_assert(:'price'::jsonb->>'success'='true','price creation');
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = true WHERE id;

-- Fixture (setting on while it is built). One line per receipt, so a dispatch of the whole quantity leaves no stock.
--   STFULL  5 bags, 5 leave, invoiced                                  -> invoiced
--   STPART  10 bags, 4 leave, that line invoiced (6 stay in store)     -> partly_invoiced
--   STFREE  5 bags, 2 and 3 leave, only the first line invoiced        -> partly_invoiced (a free dispatch line)
--   STCANC  5 bags, 5 leave, invoiced, the invoice cancelled           -> not_invoiced
--   STDEL   5 bags, 5 leave, invoiced, the receipt then deleted        -> invoiced (a receipt with deleted_at set keeps its state; the lists do not leave it out)
--   STTWO   5 bags, 2 and 3 leave, one live invoice each               -> invoiced
--   STMIX   5 bags, 2 and 3 leave, two invoices, the second cancelled  -> partly_invoiced
--   STIMP   5 bags, 5 leave, a live imported invoice takes the line as billed (imported_billed_dispatches), no invoice line names it -> invoiced
--   STIMPX  as STIMP with the imported invoice cancelled               -> not_invoiced
--   STNODSP 5 bags, never dispatched, a live invoice with no line      -> partly_invoiced (stock left)
--   STNONE  5 bags, nothing happens                                    -> not_invoiced
--   STDEL2  5 bags, never invoiced, deleted                            -> not_invoiced
SELECT pg_temp.st_grn(:'admin_claims'::jsonb,'STFULL',5,:'customer_id'::uuid,:'item_id'::uuid) AS g_full \gset
SELECT pg_temp.st_grn(:'admin_claims'::jsonb,'STPART',10,:'customer_id'::uuid,:'item_id'::uuid) AS g_part \gset
SELECT pg_temp.st_grn(:'admin_claims'::jsonb,'STFREE',5,:'customer_id'::uuid,:'item_id'::uuid) AS g_free \gset
SELECT pg_temp.st_grn(:'admin_claims'::jsonb,'STCANC',5,:'customer_id'::uuid,:'item_id'::uuid) AS g_canc \gset
SELECT pg_temp.st_grn(:'admin_claims'::jsonb,'STDEL',5,:'customer_id'::uuid,:'item_id'::uuid) AS g_del \gset
SELECT pg_temp.st_grn(:'admin_claims'::jsonb,'STTWO',5,:'customer_id'::uuid,:'item_id'::uuid) AS g_two \gset
SELECT pg_temp.st_grn(:'admin_claims'::jsonb,'STMIX',5,:'customer_id'::uuid,:'item_id'::uuid) AS g_mix \gset
SELECT pg_temp.st_grn(:'admin_claims'::jsonb,'STIMP',5,:'customer_id'::uuid,:'item_id'::uuid) AS g_imp \gset
SELECT pg_temp.st_grn(:'admin_claims'::jsonb,'STIMPX',5,:'customer_id'::uuid,:'item_id'::uuid) AS g_impx \gset
SELECT pg_temp.st_grn(:'admin_claims'::jsonb,'STNODSP',5,:'customer_id'::uuid,:'item_id'::uuid) AS g_nodsp \gset
SELECT pg_temp.st_grn(:'admin_claims'::jsonb,'STNONE',5,:'customer_id'::uuid,:'item_id'::uuid) AS g_none \gset
SELECT pg_temp.st_grn(:'admin_claims'::jsonb,'STDEL2',5,:'customer_id'::uuid,:'item_id'::uuid) AS g_del2 \gset

SELECT pg_temp.st_disp(:'admin_claims'::jsonb,'STDFULL',:'g_full'::uuid,5,:'customer_id'::uuid,:'admin_profile'::uuid) AS d_full \gset
SELECT pg_temp.st_disp(:'admin_claims'::jsonb,'STDPART',:'g_part'::uuid,4,:'customer_id'::uuid,:'admin_profile'::uuid) AS d_part \gset
SELECT pg_temp.st_disp(:'admin_claims'::jsonb,'STDFREE1',:'g_free'::uuid,2,:'customer_id'::uuid,:'admin_profile'::uuid) AS d_free1 \gset
SELECT pg_temp.st_disp(:'admin_claims'::jsonb,'STDFREE2',:'g_free'::uuid,3,:'customer_id'::uuid,:'admin_profile'::uuid) AS d_free2 \gset
SELECT pg_temp.st_disp(:'admin_claims'::jsonb,'STDCANC',:'g_canc'::uuid,5,:'customer_id'::uuid,:'admin_profile'::uuid) AS d_canc \gset
SELECT pg_temp.st_disp(:'admin_claims'::jsonb,'STDDEL',:'g_del'::uuid,5,:'customer_id'::uuid,:'admin_profile'::uuid) AS d_del \gset
SELECT pg_temp.st_disp(:'admin_claims'::jsonb,'STDTWO1',:'g_two'::uuid,2,:'customer_id'::uuid,:'admin_profile'::uuid) AS d_two1 \gset
SELECT pg_temp.st_disp(:'admin_claims'::jsonb,'STDTWO2',:'g_two'::uuid,3,:'customer_id'::uuid,:'admin_profile'::uuid) AS d_two2 \gset
SELECT pg_temp.st_disp(:'admin_claims'::jsonb,'STDMIX1',:'g_mix'::uuid,2,:'customer_id'::uuid,:'admin_profile'::uuid) AS d_mix1 \gset
SELECT pg_temp.st_disp(:'admin_claims'::jsonb,'STDMIX2',:'g_mix'::uuid,3,:'customer_id'::uuid,:'admin_profile'::uuid) AS d_mix2 \gset
SELECT pg_temp.st_disp(:'admin_claims'::jsonb,'STDIMP',:'g_imp'::uuid,5,:'customer_id'::uuid,:'admin_profile'::uuid) AS d_imp \gset
SELECT pg_temp.st_disp(:'admin_claims'::jsonb,'STDIMPX',:'g_impx'::uuid,5,:'customer_id'::uuid,:'admin_profile'::uuid) AS d_impx \gset

SELECT pg_temp.st_inv(:'admin_claims'::jsonb,20280101,:'g_full'::uuid,:'customer_id'::uuid,ARRAY[:'d_full'::uuid]) AS i_full \gset
SELECT pg_temp.st_inv(:'admin_claims'::jsonb,20280102,:'g_part'::uuid,:'customer_id'::uuid,ARRAY[:'d_part'::uuid]) AS i_part \gset
SELECT pg_temp.st_inv(:'admin_claims'::jsonb,20280103,:'g_free'::uuid,:'customer_id'::uuid,ARRAY[:'d_free1'::uuid]) AS i_free \gset
SELECT pg_temp.st_inv(:'admin_claims'::jsonb,20280104,:'g_canc'::uuid,:'customer_id'::uuid,ARRAY[:'d_canc'::uuid]) AS i_canc \gset
SELECT pg_temp.st_inv(:'admin_claims'::jsonb,20280105,:'g_del'::uuid,:'customer_id'::uuid,ARRAY[:'d_del'::uuid]) AS i_del \gset
SELECT pg_temp.st_inv(:'admin_claims'::jsonb,20280106,:'g_two'::uuid,:'customer_id'::uuid,ARRAY[:'d_two1'::uuid]) AS i_two1 \gset
SELECT pg_temp.st_inv(:'admin_claims'::jsonb,20280107,:'g_two'::uuid,:'customer_id'::uuid,ARRAY[:'d_two2'::uuid]) AS i_two2 \gset
SELECT pg_temp.st_inv(:'admin_claims'::jsonb,20280108,:'g_mix'::uuid,:'customer_id'::uuid,ARRAY[:'d_mix1'::uuid]) AS i_mix1 \gset
SELECT pg_temp.st_inv(:'admin_claims'::jsonb,20280109,:'g_mix'::uuid,:'customer_id'::uuid,ARRAY[:'d_mix2'::uuid]) AS i_mix2 \gset
SELECT pg_temp.st_as(:'admin_claims'::jsonb, format('SELECT public.cancel_invoice(%L::uuid, %L, NULL)', :'i_canc', 'State test')) AS c1 \gset
SELECT pg_temp.st_as(:'admin_claims'::jsonb, format('SELECT public.cancel_invoice(%L::uuid, %L, NULL)', :'i_mix2', 'State test')) AS c2 \gset
SELECT pg_temp.st_assert(:'c1'::jsonb->>'success'='true' AND :'c2'::jsonb->>'success'='true','two invoices cancelled: '||:'c1'||:'c2');

-- The invoice with no dispatch at all, and the two imported invoices: written directly (an import writes them directly too, migration 192).
INSERT INTO public.invoice (inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, total, tax_amount, discount, duration_mode)
SELECT 2026, v.n, v.gid, g.gr_no, :'customer_id'::uuid, 'State Demo Customer', '2026-05-02T12:00:00Z', 0, 0, 0, 'legacy'
  FROM (VALUES (20280110, :'g_nodsp'::uuid), (20280111, :'g_imp'::uuid), (20280112, :'g_impx'::uuid)) v(n, gid) JOIN public.goodsreceived g ON g.id = v.gid;
INSERT INTO public.imported_billed_dispatches (disp_trl_id, invoice_id)
SELECT :'d_imp'::uuid, (SELECT id FROM public.invoice WHERE inv_no = 20280111);
INSERT INTO public.imported_billed_dispatches (disp_trl_id, invoice_id)
SELECT :'d_impx'::uuid, (SELECT id FROM public.invoice WHERE inv_no = 20280112);
UPDATE public.invoice SET cancelled_at = now(), cancelled_by = :'admin_profile'::uuid, cancel_reason = 'State test' WHERE inv_no = 20280112;
UPDATE public.goodsreceived SET deleted_at = now() WHERE id IN (:'g_del'::uuid, :'g_del2'::uuid);

-- 1. Setting ON. The fixture holds the states it is built for (so the equality below is not vacuous), and the two forms agree on every GRN.
SELECT pg_temp.st_assert((SELECT string_agg(g.gr_no || '=' || warehouse_security.grn_invoice_state(g.id), ',' ORDER BY g.gr_no) FROM public.goodsreceived g WHERE g.gr_no LIKE 'ST%')
  = 'STCANC=not_invoiced,STDEL=invoiced,STDEL2=not_invoiced,STFREE=partly_invoiced,STFULL=invoiced,STIMP=invoiced,STIMPX=not_invoiced,STMIX=partly_invoiced,STNODSP=partly_invoiced,STNONE=not_invoiced,STPART=partly_invoiced,STTWO=invoiced',
  'on: the fixture holds the states it was built for');
SELECT pg_temp.st_assert(pg_temp.st_disagree() = '', 'on: invoiced_grn_states equals grn_invoice_state on every GRN: ' || pg_temp.st_disagree());
SELECT pg_temp.st_assert((SELECT count(*) FROM public.goodsreceived) >= 12 AND (SELECT count(*) FROM warehouse_security.invoiced_grn_states()) = 8, 'on: the set holds the eight GRNs with a live invoice');
-- The set is one row per GRN and never says not_invoiced (a GRN without a live invoice is absent).
SELECT pg_temp.st_assert((SELECT count(*) = count(DISTINCT gr_id) AND bool_and(invoice_state IN ('invoiced', 'partly_invoiced')) FROM warehouse_security.invoiced_grn_states()),
  'on: one row per GRN, only invoiced or partly_invoiced');

-- 2. Setting OFF (migration 160's rule): a live invoice is invoiced, whatever stock is left. Rebuilt by hand and compared to both forms.
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = false WHERE id;
SELECT pg_temp.st_assert(pg_temp.st_disagree() = '', 'off: invoiced_grn_states equals grn_invoice_state on every GRN: ' || pg_temp.st_disagree());
SELECT pg_temp.st_assert((SELECT string_agg(g.gr_no, ',' ORDER BY g.gr_no) FROM public.goodsreceived g WHERE g.gr_no LIKE 'ST%' AND warehouse_security.grn_invoice_state(g.id) = 'invoiced')
  = 'STDEL,STFREE,STFULL,STIMP,STMIX,STNODSP,STPART,STTWO', 'off: every GRN with a live invoice is invoiced, the others are not');
SELECT pg_temp.st_assert((SELECT bool_and(invoice_state = 'invoiced') AND count(*) = 8 FROM warehouse_security.invoiced_grn_states()), 'off: the set holds the eight GRNs with a live invoice, all invoiced');
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = true WHERE id;

-- 3. No client may read the set (no grant): the roles of the app, the table-less anon and the signed-in account all refuse it.
SELECT pg_temp.st_assert(NOT EXISTS (SELECT 1 FROM unnest(ARRAY['anon','authenticated','service_role','authenticator']) r
  WHERE has_function_privilege(r, 'warehouse_security.invoiced_grn_states()', 'EXECUTE')), 'no client role holds EXECUTE on invoiced_grn_states');
SELECT pg_temp.st_as(:'admin_claims'::jsonb, 'SELECT count(*)::text::jsonb FROM warehouse_security.invoiced_grn_states()') AS direct \gset
SELECT pg_temp.st_assert(:'direct'::jsonb->>'state' IN ('42501', '3F000'), 'a signed-in account cannot call invoiced_grn_states: ' || :'direct');

-- 4. The filtered lists name the GRNs the per-GRN state names, setting on. (Neither list leaves out a receipt with deleted_at set; the filter does not change that.)
SELECT pg_temp.st_list_grns(pg_temp.st_list(:'admin_claims'::jsonb, '{"invoiced":true}')) AS l_t, pg_temp.st_list_grns(pg_temp.st_list(:'admin_claims'::jsonb, '{"invoiced":false}')) AS l_f,
       pg_temp.st_list_grns(pg_temp.st_list(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}')) AS l_p,
       pg_temp.st_item_grns(pg_temp.st_items(:'admin_claims'::jsonb, '{"invoiced":true}')) AS i_t, pg_temp.st_item_grns(pg_temp.st_items(:'admin_claims'::jsonb, '{"invoiced":false}')) AS i_f,
       pg_temp.st_item_grns(pg_temp.st_items(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}')) AS i_p \gset
SELECT pg_temp.st_assert(:'l_t' = pg_temp.st_named('invoiced') AND :'l_f' = pg_temp.st_named('not_invoiced') AND :'l_p' = pg_temp.st_named('partly_invoiced'),
  'on: get_grn_list true / false / partly name the GRNs of grn_invoice_state: ' || :'l_t' || ' | ' || :'l_f' || ' | ' || :'l_p');
SELECT pg_temp.st_assert(:'i_t' = :'l_t' AND :'i_f' = :'l_f' AND :'i_p' = :'l_p', 'on: get_all_grn_items names the same GRNs as get_grn_list');
SELECT pg_temp.st_assert(:'l_t' = 'STDEL,STFULL,STIMP,STTWO' AND :'l_p' = 'STFREE,STMIX,STNODSP,STPART' AND :'l_f' = 'STCANC,STDEL2,STIMPX,STNONE', 'on: the lists hold the states the fixture was built for');
-- JSON null with the setting on reads as not_invoiced (as before the migration); "abc" raises 22P02.
SELECT pg_temp.st_list_grns(pg_temp.st_list(:'admin_claims'::jsonb, '{"invoiced":null}')) AS l_n, pg_temp.st_item_grns(pg_temp.st_items(:'admin_claims'::jsonb, '{"invoiced":null}')) AS i_n,
       pg_temp.st_list(:'admin_claims'::jsonb, '{"invoiced":"abc"}') AS l_abc, pg_temp.st_items(:'admin_claims'::jsonb, '{"invoiced":"abc"}') AS i_abc \gset
SELECT pg_temp.st_assert(:'l_n' = :'l_f' AND :'i_n' = :'l_f', 'on: a JSON null filter lists the not invoiced GRNs: ' || :'l_n' || ' | ' || :'i_n');
SELECT pg_temp.st_assert(:'l_abc'::jsonb->>'success' = 'false' AND :'l_abc'::jsonb#>>'{error,details}' LIKE 'invalid input syntax for type boolean%' AND :'i_abc'::jsonb->>'state' = '22P02', 'on: "abc" raises 22P02 in both lists: ' || :'l_abc' || ' | ' || :'i_abc');

-- 5. Setting OFF: true = a live invoice exists, false = none, partly_invoiced = nothing, JSON null = no GRN, "abc" = 22P02, in both lists.
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = false WHERE id;
SELECT pg_temp.st_list(:'admin_claims'::jsonb, '{"invoiced":null}') AS o_ln, pg_temp.st_items(:'admin_claims'::jsonb, '{"invoiced":null}') AS o_in,
       pg_temp.st_list(:'admin_claims'::jsonb, '{"invoiced":"abc"}') AS o_labc, pg_temp.st_items(:'admin_claims'::jsonb, '{"invoiced":"abc"}') AS o_iabc,
       pg_temp.st_list_grns(pg_temp.st_list(:'admin_claims'::jsonb, '{"invoiced":true}')) AS o_lt, pg_temp.st_list_grns(pg_temp.st_list(:'admin_claims'::jsonb, '{"invoiced":false}')) AS o_lf,
       pg_temp.st_list_grns(pg_temp.st_list(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}')) AS o_lp,
       pg_temp.st_item_grns(pg_temp.st_items(:'admin_claims'::jsonb, '{"invoiced":true}')) AS o_it, pg_temp.st_item_grns(pg_temp.st_items(:'admin_claims'::jsonb, '{"invoiced":false}')) AS o_if,
       pg_temp.st_item_grns(pg_temp.st_items(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}')) AS o_ip \gset
SELECT pg_temp.st_assert(pg_temp.st_list_grns(:'o_ln'::jsonb) = '' AND pg_temp.st_item_grns(:'o_in'::jsonb) = ''
  AND COALESCE((:'o_ln'::jsonb#>>'{data,pagination,total_count}')::int, 0) = 0 AND COALESCE((:'o_in'::jsonb#>>'{pagination,total_count}')::int, 0) = 0
  AND (:'o_ln'::jsonb->>'success' = 'true') AND (:'o_in'::jsonb->>'success' = 'true'), 'off: a JSON null filter lists no GRN, in both lists: ' || :'o_ln' || ' | ' || :'o_in');
SELECT pg_temp.st_assert(:'o_labc'::jsonb->>'success' = 'false' AND :'o_labc'::jsonb#>>'{error,details}' LIKE 'invalid input syntax for type boolean%' AND :'o_iabc'::jsonb->>'state' = '22P02', 'off: "abc" raises 22P02 in both lists: ' || :'o_labc' || ' | ' || :'o_iabc');
SELECT pg_temp.st_assert(:'o_lt' = 'STDEL,STFREE,STFULL,STIMP,STMIX,STNODSP,STPART,STTWO' AND :'o_lf' = 'STCANC,STDEL2,STIMPX,STNONE' AND :'o_lp' = ''
  AND :'o_it' = :'o_lt' AND :'o_if' = :'o_lf' AND :'o_ip' = '', 'off: true lists the GRNs with a live invoice, false the others, partly_invoiced none: ' || :'o_lt' || ' | ' || :'o_lf');
ROLLBACK;
