-- Migration 202 (WH-138): get_all_grn_items (the app's GRN list, one row per GRN line) takes p_filters.invoiced with the meaning get_grn_list has:
-- 'partly_invoiced'; true / false = the states invoiced / not_invoiced with "Invoice goods as they leave" on, a live invoice exists / does not exist with it off;
-- any other value raises 22P02. The filter is on the GRN (every line of a matching GRN is listed) and the rows, pagination.total_count and the aggregates follow it,
-- also with limit / offset and page_by = receipt. No filter, or a filter that does not name the key, gives the same answer as before. A customer is refused
-- (42501), an administrator, a supervisor and staff read the same answer. A cancelled invoice moves a GRN back to partly invoiced and then not invoiced.
-- Fictional data; runs after all migrations in migrations.sh's disposable, network-disabled database; every fixture row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.gi_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'grn items invoice filter: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.gi_save_invoice(doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;
CREATE FUNCTION pg_temp.gi_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.gi_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.gi_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The answer of a statement run as the signed-in account, or {"raised": message, "state": sqlstate}.
CREATE FUNCTION pg_temp.gi_as(claims jsonb, statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims',claims::text,true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN answer := jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  EXECUTE 'RESET ROLE';
  RETURN answer;
END $$;
CREATE FUNCTION pg_temp.gi_items(claims jsonb, filters jsonb, lim integer DEFAULT 100, off integer DEFAULT 0) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.gi_as(claims, format('SELECT public.get_all_grn_items(p_filters => %L::jsonb, p_limit => %s, p_offset => %s)', filters::text, lim, off)) $$;
CREATE FUNCTION pg_temp.gi_list(claims jsonb, filters jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT pg_temp.gi_as(claims, format('SELECT public.get_grn_list(p_filters => %L::jsonb, p_limit => 100)', filters::text)) $$;
-- The fixture receipts of the answer of get_all_grn_items, sorted and joined: "FLTA,FLTB,FLTB" is one row of FLTA and two of FLTB.
CREATE FUNCTION pg_temp.gi_rows(answer jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(e->>'gr_no', ',' ORDER BY e->>'gr_no', e->>'item_name'), '') FROM jsonb_array_elements(COALESCE(answer->'data', '[]'::jsonb)) e WHERE e->>'gr_no' LIKE 'FLT%' $$;
-- The distinct fixture receipts of either list.
CREATE FUNCTION pg_temp.gi_grns(answer jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(DISTINCT e->>'gr_no', ',' ORDER BY e->>'gr_no'), '') FROM jsonb_array_elements(
    COALESCE(answer->'data', '[]'::jsonb) || COALESCE(answer#>'{data,grns}', '[]'::jsonb)) e WHERE jsonb_typeof(e) = 'object' AND e->>'gr_no' LIKE 'FLT%' $$;
CREATE FUNCTION pg_temp.gi_list_grns(answer jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(e->>'gr_no', ',' ORDER BY e->>'gr_no'), '') FROM jsonb_array_elements(COALESCE(answer#>'{data,grns}', answer->'grns', '[]'::jsonb)) e WHERE e->>'gr_no' LIKE 'FLT%' $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888831','Filter Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888832','Filter Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888833','Filter Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888834','Filter Customer Reader','customer',true,'approved');
SELECT pg_temp.gi_login('9888888831') AS admin_claims \gset
SELECT pg_temp.gi_login('9888888832') AS supervisor_claims \gset
SELECT pg_temp.gi_login('9888888833') AS staff_claims \gset
SELECT pg_temp.gi_login('9888888834') AS customer_claims \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset

-- Fixture: one customer, two items. FLTA 10 bags (4 leave, that line is invoiced: partly invoiced); FLTB two lines of 6 and 7 bags, nothing leaves
-- (not invoiced); FLTC 5 bags, 2 and 3 leave in two dispatches, each invoiced (invoiced).
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_customer('Filter Demo Customer','9888888835') AS customer \gset
SELECT public.create_item('Filter Demo Potatoes','Bag') AS item1 \gset
SELECT public.create_item('Filter Demo Onions','Bag') AS item2 \gset
SELECT id AS customer_id FROM public.customers WHERE name='Filter Demo Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Filter Demo Potatoes' \gset
SELECT id AS item2_id FROM public.items WHERE name='Filter Demo Onions' \gset
SELECT public.replace_item_rates(:'item_id'::uuid,:'customer_id'::uuid,'monthly','2026-01-01'::date,jsonb_build_array(jsonb_build_object('weight_min',0,'weight_max',100,'unit_price',5,'labour_rate',2,'tax_percent',5))) AS price \gset
SELECT pg_temp.gi_assert(:'price'::jsonb->>'success'='true','price creation');
SELECT public.save_grn(p_gr_no=>'FLTA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,p_customer_name=>'Filter Demo Customer',
 p_pricing_mode=>'MONTHLY',p_idempotency_key=>'flt-a',p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Filter Demo Potatoes',
 'packaging','Bag','qty',10,'weight',10,'rack','F1'))) AS grn_a \gset
SELECT public.save_grn(p_gr_no=>'FLTB',p_date=>'2026-04-02T12:00:00Z',p_customer_id=>:'customer_id'::uuid,p_customer_name=>'Filter Demo Customer',
 p_pricing_mode=>'MONTHLY',p_idempotency_key=>'flt-b',p_items=>jsonb_build_array(
 jsonb_build_object('item_id',:'item_id','item_name','Filter Demo Potatoes','packaging','Bag','qty',6,'weight',10,'rack','F2'),
 jsonb_build_object('item_id',:'item2_id','item_name','Filter Demo Onions','packaging','Bag','qty',7,'weight',20,'rack','F3'))) AS grn_b \gset
SELECT public.save_grn(p_gr_no=>'FLTC',p_date=>'2026-04-03T12:00:00Z',p_customer_id=>:'customer_id'::uuid,p_customer_name=>'Filter Demo Customer',
 p_pricing_mode=>'MONTHLY',p_idempotency_key=>'flt-c',p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Filter Demo Potatoes',
 'packaging','Bag','qty',5,'weight',10,'rack','F4'))) AS grn_c \gset
SELECT pg_temp.gi_assert(:'grn_a'::jsonb->>'success'='true' AND :'grn_b'::jsonb->>'success'='true' AND :'grn_c'::jsonb->>'success'='true','three receipts saved');
RESET ROLE;
SELECT id AS grn_a_id FROM public.goodsreceived WHERE gr_no='FLTA' \gset
SELECT id AS grn_c_id FROM public.goodsreceived WHERE gr_no='FLTC' \gset
SELECT id AS stock_a FROM public.goodsreceived_trl WHERE gr_id=:'grn_a_id'::uuid \gset
SELECT id AS stock_c FROM public.goodsreceived_trl WHERE gr_id=:'grn_c_id'::uuid \gset
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = true WHERE id;
SELECT jsonb_build_object('disp_no','FLTDA','disp_date','2026-05-02T12:00:00Z','customer_id',:'customer_id','customer_name','Filter Demo Customer',
 'supervisor_id',:'admin_profile','supervisor_name','Filter Administrator') AS dispatch_data \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb, ARRAY[jsonb_build_object('gr_trl_id',:'stock_a','disp_qty',4)],false,0,'flt-da') AS d_a \gset
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"FLTDC1"}'::jsonb, ARRAY[jsonb_build_object('gr_trl_id',:'stock_c','disp_qty',2)],false,0,'flt-dc1') AS d_c1 \gset
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"FLTDC2"}'::jsonb, ARRAY[jsonb_build_object('gr_trl_id',:'stock_c','disp_qty',3)],false,0,'flt-dc2') AS d_c2 \gset
SELECT pg_temp.gi_assert(:'d_a'::jsonb->>'success'='true' AND :'d_c1'::jsonb->>'success'='true' AND :'d_c2'::jsonb->>'success'='true','three dispatches');
SELECT jsonb_agg(jsonb_build_object('disp_trl_id', t.id, 'charge', 5, 'tax', 5, 'labour_rate', 2)) AS items_a FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'FLTDA' \gset
SELECT jsonb_agg(jsonb_build_object('disp_trl_id', t.id, 'charge', 5, 'tax', 5, 'labour_rate', 2)) AS items_c1 FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'FLTDC1' \gset
SELECT jsonb_agg(jsonb_build_object('disp_trl_id', t.id, 'charge', 5, 'tax', 5, 'labour_rate', 2)) AS items_c2 FROM public.dispatch_trl t JOIN public.dispatch d ON d.id = t.disp_id WHERE d.disp_no = 'FLTDC2' \gset
SELECT pg_temp.gi_save_invoice(jsonb_build_object('inv_no', 20270201, 'inv_fin_year', 2026, 'gr_id', :'grn_a_id', 'gr_no', 'FLTA', 'customer_id', :'customer_id',
  'customer_name', 'Filter Demo Customer', 'inv_date', '2026-05-02T12:00:00Z', 'total', 0, 'tax_amount', 0, 'discount', 0, 'duration_mode', 'legacy', 'items', :'items_a'::jsonb)) AS inv_a \gset
SELECT pg_temp.gi_save_invoice(jsonb_build_object('inv_no', 20270202, 'inv_fin_year', 2026, 'gr_id', :'grn_c_id', 'gr_no', 'FLTC', 'customer_id', :'customer_id',
  'customer_name', 'Filter Demo Customer', 'inv_date', '2026-05-02T12:00:00Z', 'total', 0, 'tax_amount', 0, 'discount', 0, 'duration_mode', 'legacy', 'items', :'items_c1'::jsonb)) AS inv_c1 \gset
SELECT pg_temp.gi_save_invoice(jsonb_build_object('inv_no', 20270203, 'inv_fin_year', 2026, 'gr_id', :'grn_c_id', 'gr_no', 'FLTC', 'customer_id', :'customer_id',
  'customer_name', 'Filter Demo Customer', 'inv_date', '2026-05-02T12:00:00Z', 'total', 0, 'tax_amount', 0, 'discount', 0, 'duration_mode', 'legacy', 'items', :'items_c2'::jsonb)) AS inv_c2 \gset
RESET ROLE;
SELECT pg_temp.gi_assert(:'inv_a'::jsonb->>'success'='true' AND :'inv_c1'::jsonb->>'success'='true' AND :'inv_c2'::jsonb->>'success'='true','three invoices saved: '||:'inv_a'||:'inv_c1'||:'inv_c2');
SELECT pg_temp.gi_assert(warehouse_security.grn_invoice_state(:'grn_a_id'::uuid)='partly_invoiced' AND warehouse_security.grn_invoice_state(:'grn_c_id'::uuid)='invoiced'
  AND warehouse_security.grn_invoice_state((SELECT id FROM public.goodsreceived WHERE gr_no='FLTB'))='not_invoiced', 'the fixture holds the three states with the setting on');

-- 1. Setting ON. true = invoiced (FLTC), false = not invoiced (FLTB, both lines), partly_invoiced = FLTA. The filter is on the GRN: every line of FLTB is listed.
SELECT pg_temp.gi_rows(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":true}')) AS r_true,
       pg_temp.gi_rows(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":false}')) AS r_false,
       pg_temp.gi_rows(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}')) AS r_partly,
       pg_temp.gi_rows(pg_temp.gi_items(:'admin_claims'::jsonb, '{}')) AS r_all \gset
SELECT pg_temp.gi_assert(:'r_true' = 'FLTC' AND :'r_false' = 'FLTB,FLTB' AND :'r_partly' = 'FLTA', 'on: true / false / partly_invoiced list the GRNs in that state: '||:'r_true'||' | '||:'r_false'||' | '||:'r_partly');
SELECT pg_temp.gi_assert(:'r_all' = 'FLTA,FLTB,FLTB,FLTC', 'on: with no filter every line of the three GRNs is listed: '||:'r_all');
-- The string 'true' / 'false' (as get_grn_list reads them) means the booleans.
SELECT pg_temp.gi_assert(pg_temp.gi_rows(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":"true"}')) = 'FLTC' AND pg_temp.gi_rows(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":"false"}')) = 'FLTB,FLTB',
  'on: the strings true and false read as the booleans');

-- 2. Setting ON: total_count and the aggregates follow the filter, and limit / offset move the rows only.
SELECT pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":false}') AS f_all, pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":false}', 1, 0) AS f_p1,
       pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":false}', 1, 1) AS f_p2, pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":false}', 1, 2) AS f_p3 \gset
SELECT pg_temp.gi_assert((:'f_all'::jsonb#>>'{pagination,total_count}')::int = 2 AND (:'f_p1'::jsonb#>>'{pagination,total_count}')::int = 2 AND (:'f_p3'::jsonb#>>'{pagination,total_count}')::int = 2,
  'on: total_count counts the lines of the filtered GRNs, whatever the page: '||:'f_all');
SELECT pg_temp.gi_assert((:'f_all'::jsonb#>>'{aggregates,total_qty}')::numeric = 13 AND (:'f_all'::jsonb#>>'{aggregates,total_stock}')::numeric = 13
  AND :'f_all'::jsonb->'aggregates' = :'f_p1'::jsonb->'aggregates' AND :'f_all'::jsonb->'aggregates' = :'f_p2'::jsonb->'aggregates' AND :'f_all'::jsonb->'aggregates' = :'f_p3'::jsonb->'aggregates',
  'on: the aggregates sum the filtered GRN (6 + 7 bags) and do not change with the page: '||:'f_all');
SELECT pg_temp.gi_assert(jsonb_array_length(:'f_p1'::jsonb->'data') = 1 AND jsonb_array_length(:'f_p2'::jsonb->'data') = 1 AND jsonb_array_length(:'f_p3'::jsonb->'data') = 0
  AND :'f_p1'::jsonb#>>'{data,0,grn_item_id}' IS DISTINCT FROM :'f_p2'::jsonb#>>'{data,0,grn_item_id}', 'on: limit 1 gives one line a page and the third page is empty');
-- The three filters partition the lines: the aggregates add up to the unfiltered ones.
SELECT pg_temp.gi_items(:'admin_claims'::jsonb, '{}') AS u_all, pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":true}') AS u_t, pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}') AS u_p \gset
SELECT pg_temp.gi_assert((:'u_all'::jsonb#>>'{pagination,total_count}')::int = 4
  AND (:'u_t'::jsonb#>>'{pagination,total_count}')::int + (:'f_all'::jsonb#>>'{pagination,total_count}')::int + (:'u_p'::jsonb#>>'{pagination,total_count}')::int = 4
  AND (:'u_all'::jsonb#>>'{aggregates,total_qty}')::numeric = 28
  AND (:'u_t'::jsonb#>>'{aggregates,total_qty}')::numeric + (:'f_all'::jsonb#>>'{aggregates,total_qty}')::numeric + (:'u_p'::jsonb#>>'{aggregates,total_qty}')::numeric = 28
  AND (:'u_t'::jsonb#>>'{aggregates,total_stock}')::numeric + (:'f_all'::jsonb#>>'{aggregates,total_stock}')::numeric + (:'u_p'::jsonb#>>'{aggregates,total_stock}')::numeric = (:'u_all'::jsonb#>>'{aggregates,total_stock}')::numeric
  AND (:'u_t'::jsonb#>>'{aggregates,total_weight}')::numeric + (:'f_all'::jsonb#>>'{aggregates,total_weight}')::numeric + (:'u_p'::jsonb#>>'{aggregates,total_weight}')::numeric = (:'u_all'::jsonb#>>'{aggregates,total_weight}')::numeric,
  'on: counts and aggregates of the three states add up to the unfiltered ones: '||:'u_all');

-- 3. page_by = receipt: the page and total_count count GRNs, every line of a GRN on the page is listed.
SELECT pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":false,"page_by":"receipt"}', 1, 0) AS rc_f0, pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":false,"page_by":"receipt"}', 1, 1) AS rc_f1,
       pg_temp.gi_items(:'admin_claims'::jsonb, '{"page_by":"receipt"}', 2, 0) AS rc_u0, pg_temp.gi_items(:'admin_claims'::jsonb, '{"page_by":"receipt"}', 2, 2) AS rc_u2,
       pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced","page_by":"receipt"}', 5, 0) AS rc_p \gset
SELECT pg_temp.gi_assert((:'rc_f0'::jsonb#>>'{pagination,total_count}')::int = 1 AND pg_temp.gi_rows(:'rc_f0'::jsonb) = 'FLTB,FLTB' AND jsonb_array_length(:'rc_f1'::jsonb->'data') = 0
  AND (:'rc_f1'::jsonb#>>'{pagination,total_count}')::int = 1, 'on, by receipt: the not invoiced GRN is one receipt of two lines and the second page is empty: '||:'rc_f0');
SELECT pg_temp.gi_assert((:'rc_f0'::jsonb#>>'{aggregates,total_qty}')::numeric = 13 AND :'rc_f0'::jsonb->'aggregates' = :'rc_f1'::jsonb->'aggregates', 'on, by receipt: the aggregates follow the filter, not the page');
SELECT pg_temp.gi_assert((:'rc_u0'::jsonb#>>'{pagination,total_count}')::int = 3 AND (:'rc_u2'::jsonb#>>'{pagination,total_count}')::int = 3
  AND (SELECT count(DISTINCT e->>'gr_no') FROM jsonb_array_elements(:'rc_u0'::jsonb->'data') e) = 2 AND (SELECT count(DISTINCT e->>'gr_no') FROM jsonb_array_elements(:'rc_u2'::jsonb->'data') e) = 1,
  'on, by receipt, no filter: three receipts, two on the first page of 2 and one on the next: '||:'rc_u0');
SELECT pg_temp.gi_assert((:'rc_p'::jsonb#>>'{pagination,total_count}')::int = 1 AND pg_temp.gi_rows(:'rc_p'::jsonb) = 'FLTA', 'on, by receipt: partly_invoiced lists the one GRN');

-- 4. No filter, or a filter that leaves the key out, answers what it did before: the same answer as an unrelated filter, and the same as the partition.
SELECT pg_temp.gi_assert(:'u_all'::jsonb = pg_temp.gi_items(:'admin_claims'::jsonb, jsonb_build_object('customer_ids', jsonb_build_array(:'customer_id'))), 'no filter equals a filter on the customer alone: the same data, pagination and aggregates');
-- Each answer still carries the row fields the app reads (invoice_state of migration 165 among them).
SELECT pg_temp.gi_assert((SELECT bool_and(e ? 'invoice_state' AND e ? 'grn_item_id' AND e ? 'imported' AND e ? 'qty' AND e ? 'stock') FROM jsonb_array_elements(:'u_all'::jsonb->'data') e), 'rows carry invoice_state, imported, qty and stock');
SELECT pg_temp.gi_assert((SELECT string_agg(e->>'gr_no' || '=' || (e->>'invoice_state'), ',' ORDER BY e->>'gr_no') FROM (SELECT DISTINCT ON (e->>'gr_no') e FROM jsonb_array_elements(:'u_all'::jsonb->'data') e) x(e))
  = 'FLTA=partly_invoiced,FLTB=not_invoiced,FLTC=invoiced', 'the rows say the state the filter used');

-- 5. The sets equal get_grn_list's for the same filter (setting on).
SELECT pg_temp.gi_assert(pg_temp.gi_list_grns(pg_temp.gi_list(:'admin_claims'::jsonb, '{"invoiced":true}')) = 'FLTC'
  AND pg_temp.gi_list_grns(pg_temp.gi_list(:'admin_claims'::jsonb, '{"invoiced":false}')) = 'FLTB'
  AND pg_temp.gi_list_grns(pg_temp.gi_list(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}')) = 'FLTA'
  AND pg_temp.gi_list_grns(pg_temp.gi_list(:'admin_claims'::jsonb, '{}')) = 'FLTA,FLTB,FLTC'
  AND pg_temp.gi_grns(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":true}')) = pg_temp.gi_list_grns(pg_temp.gi_list(:'admin_claims'::jsonb, '{"invoiced":true}'))
  AND pg_temp.gi_grns(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":false}')) = pg_temp.gi_list_grns(pg_temp.gi_list(:'admin_claims'::jsonb, '{"invoiced":false}'))
  AND pg_temp.gi_grns(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}')) = pg_temp.gi_list_grns(pg_temp.gi_list(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}')),
  'on: the GRNs of get_all_grn_items equal the GRNs of get_grn_list for true, false and partly_invoiced');

-- 6. Setting OFF (migration 160's rule): true = a live invoice exists (FLTA and FLTC), false = none (FLTB), partly_invoiced matches nothing.
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = false WHERE id;
SELECT pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}') AS off_p, pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":true}') AS off_t,
       pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":false}') AS off_f, pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":false,"page_by":"receipt"}', 1, 0) AS off_rc \gset
SELECT pg_temp.gi_assert(pg_temp.gi_rows(:'off_t'::jsonb) = 'FLTA,FLTA,FLTC' OR pg_temp.gi_rows(:'off_t'::jsonb) = 'FLTA,FLTC', 'off: true lists the GRNs with a live invoice: '||:'off_t');
SELECT pg_temp.gi_assert(pg_temp.gi_rows(:'off_f'::jsonb) = 'FLTB,FLTB' AND (:'off_f'::jsonb#>>'{pagination,total_count}')::int = 2, 'off: false lists the GRN without one: '||:'off_f');
SELECT pg_temp.gi_assert(:'off_p'::jsonb->>'success' = 'true' AND jsonb_array_length(:'off_p'::jsonb->'data') = 0 AND (:'off_p'::jsonb#>>'{pagination,total_count}')::int = 0,
  'off: partly_invoiced is empty, with a total of 0: '||:'off_p');
SELECT pg_temp.gi_assert(pg_temp.gi_rows(:'off_rc'::jsonb) = 'FLTB,FLTB' AND (:'off_rc'::jsonb#>>'{pagination,total_count}')::int = 1, 'off, by receipt: false is one receipt');
SELECT pg_temp.gi_assert((:'off_t'::jsonb#>>'{pagination,total_count}')::int + (:'off_f'::jsonb#>>'{pagination,total_count}')::int = 4, 'off: true and false partition the four lines');
SELECT pg_temp.gi_assert(pg_temp.gi_grns(:'off_t'::jsonb) = pg_temp.gi_list_grns(pg_temp.gi_list(:'admin_claims'::jsonb, '{"invoiced":true}'))
  AND pg_temp.gi_grns(:'off_f'::jsonb) = pg_temp.gi_list_grns(pg_temp.gi_list(:'admin_claims'::jsonb, '{"invoiced":false}'))
  AND pg_temp.gi_grns(:'off_p'::jsonb) = pg_temp.gi_list_grns(pg_temp.gi_list(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}')),
  'off: the sets equal get_grn_list for true, false and partly_invoiced');
SELECT pg_temp.gi_assert(pg_temp.gi_items(:'admin_claims'::jsonb, '{}')->'aggregates' = :'u_all'::jsonb->'aggregates', 'off: the unfiltered aggregates are the same as with the setting on');

-- 7. A value that is neither a boolean nor partly_invoiced raises 22P02 under both settings (get_grn_list's expression); the other roles read the answers of the administrator.
SELECT pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":"maybe"}') AS bad_off \gset
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = true WHERE id;
SELECT pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":"maybe"}') AS bad_on, pg_temp.gi_list(:'admin_claims'::jsonb, '{"invoiced":"maybe"}') AS bad_list \gset
SELECT pg_temp.gi_assert(:'bad_off'::jsonb->>'state' = '22P02' AND :'bad_on'::jsonb->>'state' = '22P02', 'a bad value raises 22P02 with the setting off and on: '||:'bad_off'||' | '||:'bad_on');
SELECT pg_temp.gi_assert(:'bad_list'::jsonb->>'state' = '22P02' OR :'bad_list'::jsonb->>'success' = 'false', 'get_grn_list refuses the same value too: '||:'bad_list');

-- 8. Roles. A customer account is refused by the guard (42501); an administrator, a supervisor and staff read the same answer for every filter.
SELECT pg_temp.gi_items(:'customer_claims'::jsonb, '{"invoiced":false}') AS c_ans, pg_temp.gi_items(:'customer_claims'::jsonb, '{}') AS c_none \gset
SELECT pg_temp.gi_assert(:'c_ans'::jsonb->>'state' = '42501' AND :'c_none'::jsonb->>'state' = '42501', 'a customer is refused with and without the filter: '||:'c_ans'||' | '||:'c_none');
SELECT pg_temp.gi_assert(pg_temp.gi_items(:'supervisor_claims'::jsonb, '{"invoiced":false}') = pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":false}')
  AND pg_temp.gi_items(:'supervisor_claims'::jsonb, '{"invoiced":"partly_invoiced"}') = pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}')
  AND pg_temp.gi_items(:'supervisor_claims'::jsonb, '{"invoiced":true,"page_by":"receipt"}', 1, 0) = pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":true,"page_by":"receipt"}', 1, 0),
  'a supervisor reads what the administrator reads');
SELECT pg_temp.gi_assert(pg_temp.gi_items(:'staff_claims'::jsonb, '{"invoiced":false}') = pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":false}')
  AND pg_temp.gi_items(:'staff_claims'::jsonb, '{"invoiced":"partly_invoiced"}') = pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}')
  AND pg_temp.gi_items(:'staff_claims'::jsonb, '{"invoiced":true,"page_by":"receipt"}', 1, 0) = pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":true,"page_by":"receipt"}', 1, 0),
  'staff read what the administrator reads');

-- 9. Cancelling invoices moves a GRN back (setting on). FLTC has two live invoices (invoiced); cancelling one frees its line: partly invoiced; cancelling the other: not invoiced.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.gi_assert(public.cancel_invoice((:'inv_c2'::jsonb->>'invoice_id')::uuid, 'Filter test cleanup', NULL)->>'success' = 'true', 'invoice 2 of FLTC cancelled');
RESET ROLE;
SELECT pg_temp.gi_rows(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":true}')) AS c_t1, pg_temp.gi_rows(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}')) AS c_p1,
       pg_temp.gi_rows(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":false}')) AS c_f1 \gset
SELECT pg_temp.gi_assert(:'c_t1' = '' AND :'c_p1' = 'FLTA,FLTC' AND :'c_f1' = 'FLTB,FLTB', 'on: after one cancel FLTC is partly invoiced: '||:'c_t1'||' | '||:'c_p1'||' | '||:'c_f1');
SELECT pg_temp.gi_assert(pg_temp.gi_grns(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}')) = pg_temp.gi_list_grns(pg_temp.gi_list(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}')),
  'on: the same set as get_grn_list after the cancel');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.gi_assert(public.cancel_invoice((:'inv_c1'::jsonb->>'invoice_id')::uuid, 'Filter test cleanup', NULL)->>'success' = 'true', 'invoice 1 of FLTC cancelled');
RESET ROLE;
SELECT pg_temp.gi_rows(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":false}')) AS c_f2, pg_temp.gi_rows(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":"partly_invoiced"}')) AS c_p2 \gset
SELECT pg_temp.gi_assert(:'c_f2' = 'FLTB,FLTB,FLTC' AND :'c_p2' = 'FLTA', 'on: with no live invoice FLTC is not invoiced: '||:'c_f2'||' | '||:'c_p2');
-- Off: a cancelled invoice leaves the "live invoice exists" side too.
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = false WHERE id;
SELECT pg_temp.gi_assert(pg_temp.gi_rows(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":true}')) = 'FLTA'
  AND pg_temp.gi_rows(pg_temp.gi_items(:'admin_claims'::jsonb, '{"invoiced":false}')) = 'FLTB,FLTB,FLTC', 'off: with both invoices of FLTC cancelled only FLTA has a live invoice');
ROLLBACK;
