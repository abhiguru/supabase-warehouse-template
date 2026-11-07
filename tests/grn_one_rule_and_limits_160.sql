-- Migration 160 and the update_grn / save_grn definitions of WH-111, WH-112 and WH-56.
--   WH-112: "invoiced" means one thing: the GRN has a live invoice (neither deleted nor cancelled). The goodsreceived.invoiced flag is only
--     a cache. get_grn_list's invoiced filter, update_grn's date lock and apply_grn_rates ask the invoices. Fixture: GRN 1 has a live
--     invoice (flag true), GRN 2 only a cancelled invoice and a stale flag (true), GRN 3 a live invoice and a stale flag (false).
--   WH-111: update_grn without a line list (missing, NULL, empty, not a list) is refused by name and writes nothing.
--   WH-56: a new or changed weight over 9999 is refused by save_grn and update_grn; a saved line over 9999 keeps its weight when the
--     weight is not edited.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.g_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'grn one rule and limits: %', label; END IF; END $$;
-- The answer of a statement, or 'raised: <message>'.
CREATE FUNCTION pg_temp.g_try(statement text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN 'raised: ' || SQLERRM; END;
  RETURN answer::text;
END $$;
CREATE FUNCTION pg_temp.save_invoice_doc(doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;
CREATE FUNCTION pg_temp.g_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.g_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- A receipt of one item in a pricing mode, its full dispatch and an invoice for it, as the administrator.
CREATE FUNCTION pg_temp.g_invoice(p_no integer, p_mode text, p_customer uuid, p_item uuid, p_supervisor text,
  p_bags integer, p_charge numeric, p_labour numeric)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE trl_id uuid; grn_id uuid; line_id uuid; saved jsonb;
BEGIN
  PERFORM pg_temp.g_assert(public.save_grn(p_gr_no => 'GOR' || p_no, p_date => '2026-06-01T06:00:00Z'::timestamptz,
      p_customer_id => p_customer, p_customer_name => 'Print Range Laurel Cold', p_pricing_mode => p_mode,
      p_idempotency_key => 'grn-one-rule-g' || p_no,
      p_items => jsonb_build_array(jsonb_build_object('item_id', p_item, 'item_name', 'Print Range Cumin', 'packaging', 'Bag',
        'qty', p_bags, 'weight', 10)))->>'success' = 'true', 'fixture receipt GOR' || p_no);
  SELECT g.id, t.id INTO grn_id, trl_id FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id WHERE g.gr_no = 'GOR' || p_no;
  PERFORM pg_temp.g_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no', 'GORD' || p_no,
      'disp_date', '2026-08-20', 'customer_id', p_customer, 'customer_name', 'Print Range Laurel Cold',
      'supervisor_id', p_supervisor, 'supervisor_name', 'Print Range Administrator'),
    ARRAY[jsonb_build_object('gr_trl_id', trl_id, 'disp_qty', p_bags)], 0, 'grn-one-rule-d' || p_no)->>'success' = 'true',
    'fixture dispatch GORD' || p_no);
  SELECT dt.id INTO line_id FROM public.dispatch_trl dt JOIN public.dispatch d ON d.id = dt.disp_id WHERE d.disp_no = 'GORD' || p_no;
  saved := pg_temp.save_invoice_doc(jsonb_build_object('inv_no', p_no, 'inv_fin_year', 2026, 'gr_id', grn_id, 'gr_no', 'GOR' || p_no,
    'customer_id', p_customer, 'customer_name', 'Print Range Laurel Cold', 'inv_date', '2026-08-25T06:00:00Z',
    'discount', 0, 'duration_mode', 'legacy',
    'items', jsonb_build_array(jsonb_build_object('disp_trl_id', line_id, 'charge', p_charge, 'tax', 0, 'labour_rate', p_labour))));
  PERFORM pg_temp.g_assert(saved->>'success' = 'true', 'fixture invoice ' || p_no || ': ' || saved::text);
END $$;

-- Fixture
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888887301', 'Grn Rule Administrator');
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888887301' \gset
SELECT pg_temp.g_login('9888887301') AS admin_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Grn Rule Laurel Cold', '9888887311') RETURNING id AS laurel \gset
INSERT INTO public.items(name, packaging) VALUES ('Grn Rule Cumin', 'Bag') RETURNING id AS cumin \gset
SELECT set_config('request.jwt.claims', :'admin_claims', true);
-- The lines of a receipt as an edit sends them back.
CREATE FUNCTION pg_temp.g_lines(p_gr_no text, p_weight integer DEFAULT NULL, p_extra jsonb DEFAULT '[]') RETURNS jsonb LANGUAGE sql AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', t.id, 'item_id', t.item_id, 'item_name', t.item_name, 'packaging', t.packaging,
    'qty', t.qty, 'weight', COALESCE(p_weight, t.weight))), '[]'::jsonb) || p_extra
  FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = p_gr_no $$;
CREATE FUNCTION pg_temp.g_numbers(answer jsonb) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x->>'gr_no' ORDER BY x->>'gr_no'), '{}') FROM jsonb_array_elements(answer#>'{data,grns}') AS t(x) WHERE x->>'gr_no' LIKE 'GOR%' $$;
CREATE FUNCTION pg_temp.g_grn(p_gr_no text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM public.goodsreceived WHERE gr_no = p_gr_no $$;

-- Fixture: 7301 live invoice; 7302 invoice cancelled, flag then made stale (true); 7303 live invoice, flag made stale (false).
SET LOCAL ROLE authenticated;
SELECT pg_temp.g_invoice(7301, 'MONTHLY', :'laurel'::uuid, :'cumin'::uuid, :'admin_profile', 2, 10, 1);
SELECT pg_temp.g_invoice(7302, 'MONTHLY', :'laurel'::uuid, :'cumin'::uuid, :'admin_profile', 2, 10, 1);
SELECT pg_temp.g_invoice(7303, 'MONTHLY', :'laurel'::uuid, :'cumin'::uuid, :'admin_profile', 2, 10, 1);
SELECT id AS inv_2 FROM public.invoice WHERE inv_no = 7302 AND inv_fin_year = 2026 \gset
SELECT pg_temp.g_assert(public.cancel_invoice(:'inv_2'::uuid, 'Entered twice', NULL)->>'success' = 'true', 'invoice 7302 is cancelled');
RESET ROLE;
UPDATE public.goodsreceived SET invoiced = true WHERE gr_no = 'GOR7302';
UPDATE public.goodsreceived SET invoiced = false WHERE gr_no = 'GOR7303';
SELECT pg_temp.g_assert((SELECT array_agg(gr_no || ':' || invoiced ORDER BY gr_no) FROM public.goodsreceived WHERE gr_no IN ('GOR7301', 'GOR7302', 'GOR7303'))
  = ARRAY['GOR7301:true', 'GOR7302:true', 'GOR7303:false'], 'fixture: flags true, stale true, stale false');

-- ===== WH-112: the invoiced filter asks the invoices =====
SET LOCAL ROLE authenticated;
SELECT public.get_grn_list(NULL, NULL, 'gr_no', 'asc', 50, 0, jsonb_build_object('customer_ids', jsonb_build_array(:'laurel'), 'invoiced', true)) AS list_invoiced \gset
SELECT public.get_grn_list(NULL, NULL, 'gr_no', 'asc', 50, 0, jsonb_build_object('customer_ids', jsonb_build_array(:'laurel'), 'invoiced', false)) AS list_open \gset
RESET ROLE;
SELECT pg_temp.g_assert(pg_temp.g_numbers(:'list_invoiced'::jsonb) = ARRAY['GOR7301', 'GOR7303'],
  'invoiced = true lists the GRNs with a live invoice, not the one with only a cancelled invoice and a stale flag: ' || pg_temp.g_numbers(:'list_invoiced'::jsonb)::text);
SELECT pg_temp.g_assert(pg_temp.g_numbers(:'list_open'::jsonb) = ARRAY['GOR7302'],
  'invoiced = false lists the GRN without a live invoice: ' || pg_temp.g_numbers(:'list_open'::jsonb)::text);

-- update_grn: the date lock follows the live invoice, not the flag.
SET LOCAL ROLE authenticated;
SELECT pg_temp.g_try(format('SELECT public.update_grn(p_grn_id=>%L::uuid, p_date=>%L::timestamptz, p_items=>%L::jsonb)',
  pg_temp.g_grn('GOR7303'), '2026-06-02T06:00:00Z', pg_temp.g_lines('GOR7303'))) AS date_locked \gset
SELECT pg_temp.g_try(format('SELECT public.update_grn(p_grn_id=>%L::uuid, p_date=>%L::timestamptz, p_items=>%L::jsonb)',
  pg_temp.g_grn('GOR7302'), '2026-06-02T06:00:00Z', pg_temp.g_lines('GOR7302'))) AS date_free \gset
RESET ROLE;
SELECT pg_temp.g_assert(:'date_locked' LIKE '%GRN_DATE_LOCKED%', 'a GRN with a live invoice (stale flag false) keeps its date locked: ' || :'date_locked');
SELECT pg_temp.g_assert(:'date_free' NOT LIKE '%GRN_DATE_LOCKED%' AND :'date_free' NOT LIKE 'raised:%' AND :'date_free'::jsonb->>'success' = 'true',
  'a GRN with only a cancelled invoice (stale flag true) is not locked: ' || :'date_free');
SELECT pg_temp.g_assert((SELECT business_date_ok FROM (SELECT date::date = '2026-06-02' AS business_date_ok FROM public.goodsreceived WHERE gr_no = 'GOR7302') x), 'its date changed');

-- the other places that read the rule are patched in the stored functions
SELECT pg_temp.g_assert(position('i.cancelled_at IS NULL AND i.id <> p_invoice_id' IN pg_get_functiondef('public.update_invoice(uuid, jsonb, jsonb[])'::regprocedure)) > 0,
  'update_invoice clears the old GRN''s flag counting live invoices only');
SELECT pg_temp.g_assert(position('li.cancelled_at IS NULL' IN pg_get_functiondef('warehouse_security.apply_grn_rates(uuid, jsonb)'::regprocedure)) > 0,
  'apply_grn_rates reads the live-invoice rule');

-- ===== WH-111: update_grn needs a line list =====
SELECT pg_temp.g_assert(public.save_grn(p_gr_no => 'GOR7304', p_date => '2026-06-01T06:00:00Z'::timestamptz, p_customer_id => :'laurel'::uuid,
    p_customer_name => 'Grn Rule Laurel Cold', p_pricing_mode => 'MONTHLY', p_idempotency_key => 'grn-one-rule-g7304',
    p_items => jsonb_build_array(jsonb_build_object('item_id', :'cumin', 'item_name', 'Grn Rule Cumin', 'packaging', 'Bag', 'qty', 3, 'weight', 9999),
      jsonb_build_object('item_id', :'cumin', 'item_name', 'Grn Rule Cumin', 'packaging', 'Bag', 'qty', 4, 'weight', 20)))->>'success' = 'true',
  'a receipt with a line at the limit (9999) is saved');
SET LOCAL ROLE authenticated;
SELECT pg_temp.g_try(format('SELECT public.update_grn(p_grn_id=>%L::uuid, p_note=>%L)', pg_temp.g_grn('GOR7304'), 'no lines sent')) AS no_list \gset
SELECT pg_temp.g_try(format('SELECT public.update_grn(p_grn_id=>%L::uuid, p_note=>%L, p_items=>NULL)', pg_temp.g_grn('GOR7304'), 'null list')) AS null_list \gset
SELECT pg_temp.g_try(format('SELECT public.update_grn(p_grn_id=>%L::uuid, p_note=>%L, p_items=>%L::jsonb)', pg_temp.g_grn('GOR7304'), 'empty list', '[]')) AS empty_list \gset
SELECT pg_temp.g_try(format('SELECT public.update_grn(p_grn_id=>%L::uuid, p_note=>%L, p_items=>%L::jsonb)', pg_temp.g_grn('GOR7304'), 'object', '{"a":1}')) AS object_list \gset
RESET ROLE;
SELECT pg_temp.g_assert(bool_and(a::jsonb->>'success' = 'false' AND a::jsonb->>'reason' = 'GRN_LINES_REQUIRED' AND a::jsonb->>'error_code' = 'WH409'
    AND a::jsonb->>'error' = 'A GRN needs at least one line. Delete the GRN instead.'),
  'a missing, NULL, empty or non-list line list is refused by name: ' || :'no_list' || ' | ' || :'null_list' || ' | ' || :'empty_list' || ' | ' || :'object_list')
FROM unnest(ARRAY[:'no_list', :'null_list', :'empty_list', :'object_list']) AS a;
SELECT pg_temp.g_assert((SELECT count(*) = 2 AND bool_and(deleted_at IS NULL) FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = 'GOR7304')
  AND (SELECT note IS DISTINCT FROM 'no lines sent' AND note IS DISTINCT FROM 'null list' AND note IS DISTINCT FROM 'empty list' FROM public.goodsreceived WHERE gr_no = 'GOR7304'),
  'the refused edits changed nothing: both lines remain, the note is untouched');
-- A full line list still edits.
SET LOCAL ROLE authenticated;
SELECT pg_temp.g_try(format('SELECT public.update_grn(p_grn_id=>%L::uuid, p_note=>%L, p_items=>%L::jsonb)', pg_temp.g_grn('GOR7304'), 'edited', pg_temp.g_lines('GOR7304'))) AS full_list \gset
RESET ROLE;
SELECT pg_temp.g_assert(:'full_list'::jsonb->>'success' = 'true' AND (SELECT note = 'edited' FROM public.goodsreceived WHERE gr_no = 'GOR7304'), 'an edit with the whole line list works: ' || :'full_list');

-- ===== WH-56: a weight over 9999 =====
-- new GRN
SET LOCAL ROLE authenticated;
SELECT pg_temp.g_try(format('SELECT public.save_grn(p_gr_no=>%L, p_date=>%L::timestamptz, p_customer_id=>%L::uuid, p_customer_name=>%L, p_pricing_mode=>%L, p_idempotency_key=>%L, p_items=>%L::jsonb)',
  'GOR7305', '2026-06-01T06:00:00Z', :'laurel', 'Grn Rule Laurel Cold', 'MONTHLY', 'grn-one-rule-g7305',
  jsonb_build_array(jsonb_build_object('item_id', :'cumin', 'item_name', 'Grn Rule Cumin', 'packaging', 'Bag', 'qty', 3, 'weight', 10000))::text)) AS save_over \gset
RESET ROLE;
SELECT pg_temp.g_assert((:'save_over' LIKE '%9999%') AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no = 'GOR7305'),
  'a new GRN line over 9999 is refused and the GRN is not saved: ' || :'save_over');
-- a changed weight and a new line in an edit
SET LOCAL ROLE authenticated;
SELECT pg_temp.g_try(format('SELECT public.update_grn(p_grn_id=>%L::uuid, p_items=>%L::jsonb)', pg_temp.g_grn('GOR7304'),
  (SELECT jsonb_agg(CASE WHEN (l->>'weight')::int = 20 THEN l || '{"weight": 10000}' ELSE l END) FROM jsonb_array_elements(pg_temp.g_lines('GOR7304')) l)::text)) AS edit_over \gset
SELECT pg_temp.g_try(format('SELECT public.update_grn(p_grn_id=>%L::uuid, p_items=>%L::jsonb)', pg_temp.g_grn('GOR7304'),
  (pg_temp.g_lines('GOR7304', NULL, jsonb_build_array(jsonb_build_object('item_id', :'cumin', 'item_name', 'Grn Rule Cumin', 'packaging', 'Bag', 'qty', 1, 'weight', 10000))))::text)) AS new_line_over \gset
SELECT pg_temp.g_try(format('SELECT public.update_grn(p_grn_id=>%L::uuid, p_items=>%L::jsonb)', pg_temp.g_grn('GOR7304'),
  (SELECT jsonb_agg(CASE WHEN (l->>'weight')::int = 20 THEN l || '{"weight": 9999}' ELSE l END) FROM jsonb_array_elements(pg_temp.g_lines('GOR7304')) l)::text)) AS edit_at_limit \gset
RESET ROLE;
SELECT pg_temp.g_assert(:'edit_over' LIKE '%9999%' AND :'new_line_over' LIKE '%9999%', 'a changed weight and a new line over 9999 are refused: ' || :'edit_over' || ' | ' || :'new_line_over');
SELECT pg_temp.g_assert(:'edit_at_limit'::jsonb->>'success' = 'true' AND (SELECT count(*) = 2 AND max(weight) = 9999 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = 'GOR7304'),
  'a weight of exactly 9999 is accepted: ' || :'edit_at_limit');
-- a saved weight over 9999 (older data) is kept while nobody edits it, and refused once changed to another value over 9999
UPDATE public.goodsreceived_trl SET weight = 12000 WHERE gr_id = pg_temp.g_grn('GOR7304') AND qty = 3;
SET LOCAL ROLE authenticated;
SELECT pg_temp.g_try(format('SELECT public.update_grn(p_grn_id=>%L::uuid, p_note=>%L, p_items=>%L::jsonb)', pg_temp.g_grn('GOR7304'), 'kept', pg_temp.g_lines('GOR7304'))) AS keep_old \gset
SELECT pg_temp.g_try(format('SELECT public.update_grn(p_grn_id=>%L::uuid, p_items=>%L::jsonb)', pg_temp.g_grn('GOR7304'),
  (SELECT jsonb_agg(CASE WHEN (l->>'weight')::int = 12000 THEN l || '{"weight": 12001}' ELSE l END) FROM jsonb_array_elements(pg_temp.g_lines('GOR7304')) l)::text)) AS change_old \gset
RESET ROLE;
SELECT pg_temp.g_assert(:'keep_old'::jsonb->>'success' = 'true' AND (SELECT max(weight) = 12000 FROM public.goodsreceived_trl WHERE gr_id = pg_temp.g_grn('GOR7304')),
  'an unchanged saved weight over 9999 is accepted and kept: ' || :'keep_old');
SELECT pg_temp.g_assert(:'change_old' LIKE '%9999%' AND (SELECT max(weight) = 12000 FROM public.goodsreceived_trl WHERE gr_id = pg_temp.g_grn('GOR7304')),
  'changing it to another value over 9999 is refused and the saved weight stays: ' || :'change_old');
ROLLBACK;
\echo 'GRN invoiced rule, line list and weight limit (migration 160, WH-111, WH-56) checks passed.'
