-- The invoice print data carries each line's amounts as the database computes them (migration 72).
--
-- get_invoice_range_for_print (service role; read by functions/print-invoice-preprinted) gave a
-- line its charge, quantity and duration but not the GRN's pricing mode, so the printer worked the
-- storage amount out as duration * quantity * rate, also for a ONE_TIME receipt, whose storage is
-- charged once (external review 2026-10-13, PRINT2). Since migration 72 each line also carries
--   pricing_mode    the GRN's, as warehouse_security.recalculate_invoice_header reads it;
--   storage_amount  ONE_TIME: round(charge * qty, 2); else round(charge * qty * COALESCE(duration, 1), 2);
--   labour_amount   ONE_TIME: 0; else round(labour_rate * qty, 2)
-- (the canonical rule of migration 48), and the print code prints those numbers.
-- print_jobs.status also accepts 'unknown' (PRINT3: a job whose outcome CUPS never confirmed).
--
-- Two receipts of 2 bags each, received 2026-06-01, dispatched 2026-08-20 (80 days: 3 periods in
-- the legacy mode), invoiced at 10 a bag a period:
--   7201  ONE_TIME  labour 0    storage 20 (10 * 2, once)          [old print: 3 * 2 * 10 = 60]
--   7202  MONTHLY   labour 2.5  storage 60 (10 * 2 * 3), labour 5
-- Runs ONLY in migrations.sh's fresh, network-disabled database. All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
-- The one-argument save_invoice(jsonb) is gone (migration 123): the app's save, a header and an array of lines, is used. This takes
-- the header with its lines under 'items' (as the old call did) and adds what the save asks of each line: its lot and a duration of 1.
CREATE FUNCTION pg_temp.save_invoice_doc(doc jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_invoice(NULL::uuid, doc - 'items', ARRAY(
    SELECT jsonb_build_object('grn_item_id', (SELECT d.gr_trl_id FROM public.dispatch_trl d WHERE d.id = (i->>'disp_trl_id')::uuid), 'duration', 1) || i
    FROM jsonb_array_elements(doc->'items') i)) $$;
CREATE FUNCTION pg_temp.pir_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'print invoice range: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.pir_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.pir_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- A receipt of one item in a pricing mode, its full dispatch and an invoice for it, as the administrator.
CREATE FUNCTION pg_temp.pir_invoice(p_no integer, p_mode text, p_customer uuid, p_item uuid, p_supervisor text,
  p_bags integer, p_charge numeric, p_labour numeric)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE trl_id uuid; grn_id uuid; line_id uuid; saved jsonb;
BEGIN
  PERFORM pg_temp.pir_assert(public.save_grn(p_gr_no => 'PIRG' || p_no, p_date => '2026-06-01T06:00:00Z'::timestamptz,
      p_customer_id => p_customer, p_customer_name => 'Print Range Laurel Cold', p_pricing_mode => p_mode,
      p_idempotency_key => 'print-invoice-range-g' || p_no,
      p_items => jsonb_build_array(jsonb_build_object('item_id', p_item, 'item_name', 'Print Range Cumin', 'packaging', 'Bag',
        'qty', p_bags, 'weight', 10)))->>'success' = 'true', 'fixture receipt PIRG' || p_no);
  SELECT g.id, t.id INTO grn_id, trl_id FROM public.goodsreceived g JOIN public.goodsreceived_trl t ON t.gr_id = g.id WHERE g.gr_no = 'PIRG' || p_no;
  PERFORM pg_temp.pir_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no', 'PIRD' || p_no,
      'disp_date', '2026-08-20', 'customer_id', p_customer, 'customer_name', 'Print Range Laurel Cold',
      'supervisor_id', p_supervisor, 'supervisor_name', 'Print Range Administrator'),
    ARRAY[jsonb_build_object('gr_trl_id', trl_id, 'disp_qty', p_bags)], 0, 'print-invoice-range-d' || p_no)->>'success' = 'true',
    'fixture dispatch PIRD' || p_no);
  SELECT dt.id INTO line_id FROM public.dispatch_trl dt JOIN public.dispatch d ON d.id = dt.disp_id WHERE d.disp_no = 'PIRD' || p_no;
  saved := pg_temp.save_invoice_doc(jsonb_build_object('inv_no', p_no, 'inv_fin_year', 2026, 'gr_id', grn_id, 'gr_no', 'PIRG' || p_no,
    'customer_id', p_customer, 'customer_name', 'Print Range Laurel Cold', 'inv_date', '2026-08-25T06:00:00Z',
    'discount', 0, 'duration_mode', 'legacy',
    'items', jsonb_build_array(jsonb_build_object('disp_trl_id', line_id, 'charge', p_charge, 'tax', 0, 'labour_rate', p_labour))));
  PERFORM pg_temp.pir_assert(saved->>'success' = 'true', 'fixture invoice ' || p_no || ': ' || saved::text);
END $$;
-- The one line of an invoice in the print answer.
CREATE FUNCTION pg_temp.pir_line(answer jsonb, p_no integer) RETURNS jsonb LANGUAGE sql AS $$
  SELECT x#>'{trl,0}' FROM jsonb_array_elements(answer->'data') AS t(x) WHERE (x->>'inv_no')::integer = p_no $$;

-- The function is patched in place: one function by the name, still the service role's only.
SELECT pg_temp.pir_assert((SELECT count(*) FROM pg_proc WHERE proname = 'get_invoice_range_for_print') = 1, 'one get_invoice_range_for_print');
SELECT pg_temp.pir_assert(has_function_privilege('service_role', 'public.get_invoice_range_for_print(text,text,integer,integer)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.get_invoice_range_for_print(text,text,integer,integer)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.get_invoice_range_for_print(text,text,integer,integer)', 'EXECUTE'),
  'get_invoice_range_for_print stays the service role''s only');

-- Fixture
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888887201', 'Print Range Administrator');
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888887201' \gset
SELECT pg_temp.pir_login('9888887201') AS admin_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Print Range Laurel Cold', '9888887211') RETURNING id AS laurel \gset
INSERT INTO public.items(name, packaging) VALUES ('Print Range Cumin', 'Bag') RETURNING id AS cumin \gset
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.pir_invoice(7201, 'ONE_TIME', :'laurel'::uuid, :'cumin'::uuid, :'admin_profile', 2, 10, 0);
SELECT pg_temp.pir_invoice(7202, 'MONTHLY', :'laurel'::uuid, :'cumin'::uuid, :'admin_profile', 2, 10, 2.5);
RESET ROLE;
SELECT pg_temp.pir_assert((SELECT bool_and(it.duration = 3 AND it.charge = 10) AND count(*) = 2 FROM public.invoice_trl it
    JOIN public.invoice i ON i.id = it.invoice_id WHERE i.inv_fin_year = 2026 AND i.inv_no IN (7201, 7202)),
  'fixture: both lines are 3 periods at 10');

SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SET LOCAL ROLE service_role;
SELECT public.get_invoice_range_for_print('7201', '7202', 2026) AS printed \gset
RESET ROLE;
SELECT pg_temp.pir_assert((:'printed'::jsonb)->>'success' = 'true' AND jsonb_array_length((:'printed'::jsonb)->'data') = 2,
  'two invoices printed: ' || left(:'printed', 200));

-- The ONE_TIME line: its storage is charged once, whatever the duration.
SELECT pg_temp.pir_assert(pg_temp.pir_line(:'printed'::jsonb, 7201) ? 'storage_amount',
  'the line carries storage_amount: keys ' || (SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(pg_temp.pir_line(:'printed'::jsonb, 7201)) k));
SELECT pg_temp.pir_assert(l->>'pricing_mode' = 'ONE_TIME' AND (l->>'storage_amount')::numeric = 20 AND (l->>'labour_amount')::numeric = 0
    AND (l->>'duration')::numeric = 3,
  'ONE_TIME line: storage 20, labour 0 (not 3 * 2 * 10 = 60): ' || l::text)
FROM pg_temp.pir_line(:'printed'::jsonb, 7201) AS l;
-- The MONTHLY line: charge * qty * duration, and the labour per bag.
SELECT pg_temp.pir_assert(l->>'pricing_mode' = 'MONTHLY' AND (l->>'storage_amount')::numeric = 60 AND (l->>'labour_amount')::numeric = 5,
  'MONTHLY line: storage 60, labour 5: ' || l::text)
FROM pg_temp.pir_line(:'printed'::jsonb, 7202) AS l;
-- The line amounts add up to the invoice's own subtotal (the header the save code computed: no tax, no discount).
SELECT pg_temp.pir_assert((SELECT bool_and((x->>'total')::numeric = (x#>>'{trl,0,storage_amount}')::numeric + (x#>>'{trl,0,labour_amount}')::numeric)
    FROM jsonb_array_elements((:'printed'::jsonb)->'data') AS t(x)),
  'each invoice total is its storage plus labour amount');
-- Only the three keys are added; the 47 keys of a line before are all still there.
SELECT pg_temp.pir_assert((SELECT count(*) FROM jsonb_object_keys(pg_temp.pir_line(:'printed'::jsonb, 7202))) = 50,
  'a line has 50 keys: ' || (SELECT count(*) FROM jsonb_object_keys(pg_temp.pir_line(:'printed'::jsonb, 7202)))::text);

-- print_jobs.status accepts 'unknown' and still refuses anything else.
INSERT INTO public.print_jobs(job_type, document_range_start, document_range_end, user_id, status)
VALUES ('Invoice', '7201', '7202', gen_random_uuid(), 'unknown');
DO $$
BEGIN
  INSERT INTO public.print_jobs(job_type, document_range_start, document_range_end, user_id, status)
  VALUES ('Invoice', '7201', '7202', gen_random_uuid(), 'lost');
  RAISE EXCEPTION 'print invoice range: print_jobs accepted the status lost';
EXCEPTION WHEN check_violation THEN NULL;
END $$;
SELECT pg_temp.pir_assert(pg_get_constraintdef(c.oid) LIKE '%unknown%' AND pg_get_constraintdef(c.oid) LIKE '%queued%'
    AND pg_get_constraintdef(c.oid) LIKE '%printing%' AND pg_get_constraintdef(c.oid) LIKE '%completed%'
    AND pg_get_constraintdef(c.oid) LIKE '%cancelled%' AND pg_get_constraintdef(c.oid) LIKE '%failed%',
  'print_jobs_status_check: queued, printing, completed, cancelled, failed and unknown')
FROM pg_constraint c WHERE c.conrelid = 'public.print_jobs'::regclass AND c.conname = 'print_jobs_status_check';

ROLLBACK;
