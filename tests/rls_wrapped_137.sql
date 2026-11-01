-- Migration 137: row policies evaluate their helpers once, and customers no longer see deleted documents.
--
--   (a) No policy on the 12 app-readable tables (nor on storage.objects) calls active_role(), owns_customer(),
--       get_current_user_profile_id() or auth.uid() outside a scalar subquery `(SELECT ...)`, and owns_customer() calls active_role() once.
--   (b) Parity: customer, staff, supervisor, administrator and a token without a session see the rows they saw before the
--       migration (the rows that are not deleted); an unwrapped helper would also be called once per row, a wrapped one does not.
--   (c) A customer cannot read a deleted receipt, dispatch or invoice, nor their lines or photos; staff, supervisor and
--       administrator still can; another customer sees nothing of either.
--
-- Runs ONLY in migrations.sh's fresh, network-disabled database, after scripts/configure-storage.sql. All rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.rw_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'rls wrapped 137: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.rw_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.rw_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;

-- (a) the text of every policy -------------------------------------------------------------------------------------------
CREATE TEMP TABLE rw_pol AS
  SELECT schemaname, tablename, policyname, coalesce(qual, '') || ' ' || coalesce(with_check, '') AS body
    FROM pg_policies
   WHERE (schemaname = 'public' AND tablename IN ('customers','dispatch','dispatch_images','dispatch_trl','feature_flags','goodsreceived',
            'goodsreceived_trl','grn_images','invoice','invoice_trl','items','user_profiles'))
      OR (schemaname = 'storage' AND tablename = 'objects');
SELECT pg_temp.rw_assert((SELECT count(*) FROM rw_pol WHERE schemaname = 'public') = 32, 'the 12 tables hold their 32 policies');
SELECT pg_temp.rw_assert((SELECT count(*) FROM rw_pol WHERE schemaname = 'storage') >= 14, 'the storage policies of configure-storage.sql exist (run this test after it)');
-- Every helper call must sit directly inside "(SELECT ...)": the count of calls equals the count of wrapped calls.
CREATE FUNCTION pg_temp.rw_calls(body text, helper text) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT (length(body) - length(replace(body, helper || '(', ''))) / length(helper || '(') $$;
CREATE FUNCTION pg_temp.rw_wrapped(body text, helper text) RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT count(*)::int FROM regexp_matches(body, '\(\s*SELECT\s+(public\.|auth\.)?' || replace(helper, '.', '\.') || '\(', 'g') $$;
DO $$
DECLARE r record; h text; total integer := 0;
BEGIN
  FOR r IN SELECT * FROM rw_pol LOOP
    -- pg_policies shows public.get_current_user_profile_id and auth.uid() without their schemas (both are on the search path).
    FOREACH h IN ARRAY ARRAY['warehouse_security.active_role', 'warehouse_security.owns_customer', 'get_current_user_profile_id', 'uid'] LOOP
      IF pg_temp.rw_calls(r.body, h) <> pg_temp.rw_wrapped(r.body, h) THEN
        RAISE EXCEPTION 'rls wrapped 137: policy % on %.% calls % outside (SELECT ...): %', r.policyname, r.schemaname, r.tablename, h, r.body;
      END IF;
      total := total + pg_temp.rw_calls(r.body, h);
    END LOOP;
  END LOOP;
  -- not vacuous: the policies do call the helpers
  PERFORM pg_temp.rw_assert(total >= 40, 'the policies call the helpers (found ' || total || ' calls)');
END $$;

-- fixture ----------------------------------------------------------------------------------------------------------------
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888887001', 'Wrap Rule Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888887002', 'Wrap Rule Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888887003', 'Wrap Rule Staff', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888887004', 'Wrap Rule Customer One', 'customer', true, 'approved'),
 (gen_random_uuid(), '919888887005', 'Wrap Rule Customer Two', 'customer', true, 'approved');
SELECT pg_temp.rw_login('9888887001') AS admin_claims \gset
SELECT pg_temp.rw_login('9888887002') AS supervisor_claims \gset
SELECT pg_temp.rw_login('9888887003') AS staff_claims \gset
SELECT pg_temp.rw_login('9888887004') AS c1_claims \gset
SELECT pg_temp.rw_login('9888887005') AS c2_claims \gset
-- a token that is signed in as nobody: a real user id without a session
SELECT jsonb_build_object('role', 'authenticated', 'sub', gen_random_uuid(), 'session_id', gen_random_uuid()) AS ghost_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Wrap Rule Alpha Cold', '9888887011') RETURNING id AS cust1 \gset
INSERT INTO public.customers(name, mobile) VALUES ('Wrap Rule Beta Cold', '9888887012') RETURNING id AS cust2 \gset
INSERT INTO public.items(name, packaging) VALUES ('Wrap Rule Garlic', 'Bag') RETURNING id AS garlic \gset
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'cust1'::uuid, true FROM public.user_profiles WHERE mobile = '919888887004'
 UNION ALL SELECT id, :'cust2'::uuid, true FROM public.user_profiles WHERE mobile = '919888887005';

-- Customer one: receipts WRL (live) and WRD (deleted), dispatches WLV and WDL, invoices 7001 and 7002; customer two: one of each, live.
INSERT INTO public.goodsreceived(gr_no, customer_id, customer_name, date) VALUES
 ('WRL', :'cust1', 'Wrap Rule Alpha Cold', now()), ('WRD', :'cust1', 'Wrap Rule Alpha Cold', now()), ('WRB', :'cust2', 'Wrap Rule Beta Cold', now());
INSERT INTO public.goodsreceived_trl(gr_id, item_id, item_name, qty, stock, package_mark)
 SELECT g.id, :'garlic', 'Wrap Rule Garlic', 10, 10, g.gr_no FROM public.goodsreceived g WHERE g.gr_no IN ('WRL', 'WRD', 'WRB');
-- 60 more lines on WRL, for the one-call-per-statement check below
INSERT INTO public.goodsreceived_trl(gr_id, item_id, item_name, qty, stock, package_mark)
 SELECT g.id, :'garlic', 'Wrap Rule Garlic', 10, 10, 'WRL' || i FROM public.goodsreceived g, generate_series(1, 60) i WHERE g.gr_no = 'WRL';
INSERT INTO public.grn_images(grn_id, image_type, storage_path, original_filename, file_size, mime_type, status)
 SELECT g.id, 'header', 'wrap-rule/' || g.gr_no || '.jpg', g.gr_no || '.jpg', 10, 'image/jpeg', 'confirmed' FROM public.goodsreceived g WHERE g.gr_no IN ('WRL', 'WRD', 'WRB');
INSERT INTO public.dispatch(disp_no, disp_date, customer_id, customer_name) VALUES
 ('WLV', now(), :'cust1', 'Wrap Rule Alpha Cold'), ('WDL', now(), :'cust1', 'Wrap Rule Alpha Cold'), ('WBT', now(), :'cust2', 'Wrap Rule Beta Cold');
-- WLV takes every line of WRL (61); WDL and WBT take one line each.
INSERT INTO public.dispatch_trl(gr_id, gr_trl_id, disp_id, disp_qty)
 SELECT t.gr_id, t.id, (SELECT id FROM public.dispatch WHERE disp_no = 'WLV'), 1 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = 'WRL';
INSERT INTO public.dispatch_trl(gr_id, gr_trl_id, disp_id, disp_qty)
 SELECT t.gr_id, t.id, (SELECT id FROM public.dispatch WHERE disp_no = 'WDL'), 1 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = 'WRD';
INSERT INTO public.dispatch_trl(gr_id, gr_trl_id, disp_id, disp_qty)
 SELECT t.gr_id, t.id, (SELECT id FROM public.dispatch WHERE disp_no = 'WBT'), 1 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = 'WRB';
INSERT INTO public.dispatch_images(dispatch_id, storage_path, original_filename, file_size, mime_type, status)
 SELECT d.id, 'wrap-rule/' || d.disp_no || '.jpg', d.disp_no || '.jpg', 10, 'image/jpeg', 'confirmed' FROM public.dispatch d WHERE d.disp_no IN ('WLV', 'WDL', 'WBT');
INSERT INTO public.invoice(inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, total)
 SELECT 2099, v.n, g.id, g.gr_no, g.customer_id, g.customer_name, now(), 100
   FROM (VALUES (7001, 'WRL'), (7002, 'WRD'), (7003, 'WRB')) v(n, gr_no) JOIN public.goodsreceived g ON g.gr_no = v.gr_no;
INSERT INTO public.invoice_trl(invoice_id) SELECT id FROM public.invoice WHERE inv_fin_year = 2099;
-- The deletions (a soft delete only sets deleted_at).
UPDATE public.goodsreceived SET deleted_at = now() WHERE gr_no = 'WRD';
UPDATE public.dispatch SET deleted_at = now() WHERE disp_no = 'WDL';
UPDATE public.invoice SET deleted_at = now() WHERE inv_fin_year = 2099 AND inv_no = 7002;
SELECT array_agg(id) AS gr_ids FROM public.goodsreceived WHERE gr_no IN ('WRL', 'WRD', 'WRB') \gset
SELECT id AS grl FROM public.goodsreceived WHERE gr_no = 'WRL' \gset
SELECT id AS grd FROM public.goodsreceived WHERE gr_no = 'WRD' \gset
SELECT id AS dwl FROM public.dispatch WHERE disp_no = 'WLV' \gset
SELECT id AS dwd FROM public.dispatch WHERE disp_no = 'WDL' \gset
SELECT id AS invl FROM public.invoice WHERE inv_fin_year = 2099 AND inv_no = 7001 \gset
SELECT id AS invd FROM public.invoice WHERE inv_fin_year = 2099 AND inv_no = 7002 \gset
-- Which document each fixture row belongs to: kind (grn, dispatch, invoice) and state (live, deleted, other = customer two's).
CREATE TEMP TABLE rw_doc(kind text, state text, id uuid);
INSERT INTO rw_doc SELECT 'grn', CASE gr_no WHEN 'WRL' THEN 'live' WHEN 'WRD' THEN 'deleted' ELSE 'other' END, id FROM public.goodsreceived WHERE gr_no IN ('WRL', 'WRD', 'WRB');
INSERT INTO rw_doc SELECT 'dispatch', CASE disp_no WHEN 'WLV' THEN 'live' WHEN 'WDL' THEN 'deleted' ELSE 'other' END, id FROM public.dispatch WHERE disp_no IN ('WLV', 'WDL', 'WBT');
INSERT INTO rw_doc SELECT 'invoice', CASE inv_no WHEN 7001 THEN 'live' WHEN 7002 THEN 'deleted' ELSE 'other' END, id FROM public.invoice WHERE inv_fin_year = 2099;
GRANT SELECT ON rw_doc TO PUBLIC;
-- Fixture rows a role reads: table, then the key column that names the document, grouped by the document's state.
CREATE FUNCTION pg_temp.rw_read(who text) RETURNS TABLE(tbl text, live bigint, deleted bigint, other bigint) LANGUAGE plpgsql AS $$
DECLARE t record;
BEGIN
  FOR t IN SELECT * FROM (VALUES ('goodsreceived', 'id', 'grn'), ('goodsreceived_trl', 'gr_id', 'grn'), ('grn_images', 'grn_id', 'grn'),
      ('dispatch', 'id', 'dispatch'), ('dispatch_trl', 'disp_id', 'dispatch'), ('dispatch_images', 'dispatch_id', 'dispatch'),
      ('invoice', 'id', 'invoice'), ('invoice_trl', 'invoice_id', 'invoice')) v(name, key, kind) LOOP
    tbl := t.name;
    EXECUTE format('SELECT count(*) FILTER (WHERE d.state = ''live''), count(*) FILTER (WHERE d.state = ''deleted''), count(*) FILTER (WHERE d.state = ''other'')
      FROM public.%I x JOIN rw_doc d ON d.kind = %L AND d.id = x.%I', t.name, t.kind, t.key) INTO live, deleted, other;
    RETURN NEXT;
  END LOOP;
END $$;
CREATE TEMP TABLE rw_seen(who text, tbl text, live bigint, deleted bigint, other bigint, customers bigint);
GRANT ALL ON rw_seen TO PUBLIC;
-- What each role should read: the live document of customer one is on every list that may read it; the deleted one only for
-- staff, supervisor and administrator; customer two's only for them and for customer two.
CREATE TEMP TABLE rw_expect(who text, tbl text, live bigint, deleted bigint, other bigint);
INSERT INTO rw_expect
 SELECT w.who, t.tbl, t.live * (w.who IN ('customer1', 'staff', 'supervisor', 'admin'))::int,
        t.deleted * (w.who IN ('staff', 'supervisor', 'admin'))::int, t.other * (w.who IN ('customer2', 'staff', 'supervisor', 'admin'))::int
   FROM (VALUES ('customer1'), ('customer2'), ('staff'), ('supervisor'), ('admin'), ('ghost')) w(who),
        (VALUES ('goodsreceived', 1, 1, 1), ('goodsreceived_trl', 61, 1, 1), ('grn_images', 1, 1, 1),
                ('dispatch', 1, 1, 1), ('dispatch_trl', 61, 1, 1), ('dispatch_images', 1, 1, 1),
                ('invoice', 1, 1, 1), ('invoice_trl', 1, 1, 1)) t(tbl, live, deleted, other);
GRANT SELECT ON rw_expect TO PUBLIC;

SELECT set_config('request.jwt.claims', :'c1_claims', true);
SET LOCAL ROLE authenticated;
INSERT INTO rw_seen SELECT 'customer1', r.*, (SELECT count(*) FROM public.customers WHERE id IN (:'cust1', :'cust2')) FROM pg_temp.rw_read('customer1') r;
RESET ROLE;
SELECT set_config('request.jwt.claims', :'c2_claims', true);
SET LOCAL ROLE authenticated;
INSERT INTO rw_seen SELECT 'customer2', r.*, (SELECT count(*) FROM public.customers WHERE id IN (:'cust1', :'cust2')) FROM pg_temp.rw_read('customer2') r;
RESET ROLE;
SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
INSERT INTO rw_seen SELECT 'staff', r.*, (SELECT count(*) FROM public.customers WHERE id IN (:'cust1', :'cust2')) FROM pg_temp.rw_read('staff') r;
RESET ROLE;
SELECT set_config('request.jwt.claims', :'supervisor_claims', true);
SET LOCAL ROLE authenticated;
INSERT INTO rw_seen SELECT 'supervisor', r.*, (SELECT count(*) FROM public.customers WHERE id IN (:'cust1', :'cust2')) FROM pg_temp.rw_read('supervisor') r;
RESET ROLE;
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
INSERT INTO rw_seen SELECT 'admin', r.*, (SELECT count(*) FROM public.customers WHERE id IN (:'cust1', :'cust2')) FROM pg_temp.rw_read('admin') r;
RESET ROLE;
SELECT set_config('request.jwt.claims', :'ghost_claims', true);
SET LOCAL ROLE authenticated;
INSERT INTO rw_seen SELECT 'ghost', r.*, (SELECT count(*) FROM public.customers WHERE id IN (:'cust1', :'cust2')) FROM pg_temp.rw_read('ghost') r;
RESET ROLE;

-- (b) and (c): every role reads exactly what it should, table by table.
DO $$
DECLARE r record; bad text := '';
BEGIN
  FOR r IN SELECT s.who, s.tbl, s.live, s.deleted, s.other, e.live AS e_live, e.deleted AS e_deleted, e.other AS e_other
             FROM rw_seen s JOIN rw_expect e ON e.who = s.who AND e.tbl = s.tbl
            WHERE (s.live, s.deleted, s.other) IS DISTINCT FROM (e.live, e.deleted, e.other) LOOP
    bad := bad || format(E'\n  %s reads %s: live/deleted/other = %s/%s/%s, expected %s/%s/%s', r.who, r.tbl, r.live, r.deleted, r.other, r.e_live, r.e_deleted, r.e_other);
  END LOOP;
  PERFORM pg_temp.rw_assert(bad = '', 'rows visible per role differ:' || bad);
  PERFORM pg_temp.rw_assert((SELECT count(*) FROM rw_seen) = 6 * 8, 'every role was read on every table');
  -- customers: a customer sees its own customer row, the three internal roles both, a session-less token none
  PERFORM pg_temp.rw_assert((SELECT string_agg(DISTINCT who || '=' || customers, ',' ORDER BY who || '=' || customers) FROM rw_seen)
    = 'admin=2,customer1=1,customer2=1,ghost=0,staff=2,supervisor=2', 'customers visible per role');
END $$;

-- (c) again, for the line and photo tables on their own. Their customer policies read the document through the document's own
-- policy, which already hides a deleted one, so the check above cannot tell whether the line policy itself asks for a live
-- document. Here the three document policies are put back to the old rule (assigned customer only, deleted or not): the customer
-- then reads the deleted headers, and must still not read their lines, photos or invoice lines.
DROP POLICY starter_customer ON public.goodsreceived;
CREATE POLICY starter_customer ON public.goodsreceived FOR SELECT TO authenticated USING ((SELECT warehouse_security.owns_customer(customer_id)));
DROP POLICY starter_customer ON public.dispatch;
CREATE POLICY starter_customer ON public.dispatch FOR SELECT TO authenticated USING ((SELECT warehouse_security.owns_customer(customer_id)));
DROP POLICY starter_customer ON public.invoice;
CREATE POLICY starter_customer ON public.invoice FOR SELECT TO authenticated USING ((SELECT warehouse_security.owns_customer(customer_id)));
SELECT set_config('request.jwt.claims', :'c1_claims', true);
SET LOCAL ROLE authenticated;
INSERT INTO rw_seen SELECT 'customer1_open_headers', r.*, 0 FROM pg_temp.rw_read('customer1_open_headers') r;
RESET ROLE;
DO $$
DECLARE got text; want text;
BEGIN
  SELECT string_agg(tbl || '=' || live || '/' || deleted || '/' || other, ',' ORDER BY tbl) INTO got FROM rw_seen WHERE who = 'customer1_open_headers';
  want := 'dispatch=1/1/0,dispatch_images=1/0/0,dispatch_trl=61/0/0,goodsreceived=1/1/0,goodsreceived_trl=61/0/0,grn_images=1/0/0,invoice=1/1/0,invoice_trl=1/0/0';
  PERFORM pg_temp.rw_assert(got = want, 'with the document policies open, a customer still reads no line, photo or invoice line of a deleted document (live/deleted/other per table): ' || got);
END $$;

-- The same for the files: a customer's storage policies ask for a live document themselves. The policies they read through (the
-- documents and the photo rows) are put back to the old rule too, so that only the storage policy can hide a deleted document's file.
DROP POLICY starter_customer ON public.grn_images;
CREATE POLICY starter_customer ON public.grn_images FOR SELECT TO authenticated USING (((status)::text = 'confirmed'::text) AND (EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = grn_images.grn_id AND (SELECT warehouse_security.owns_customer(g.customer_id)))));
DROP POLICY starter_customer ON public.dispatch_images;
CREATE POLICY starter_customer ON public.dispatch_images FOR SELECT TO authenticated USING (((status)::text = 'confirmed'::text) AND (EXISTS (SELECT 1 FROM public.dispatch d WHERE d.id = dispatch_images.dispatch_id AND (SELECT warehouse_security.owns_customer(d.customer_id)))));
INSERT INTO storage.objects(bucket_id, name) VALUES
 ('grn-images', 'wrap-rule/WRL.jpg'), ('grn-images', 'wrap-rule/WRD.jpg'), ('grn-images', 'wrap-rule/WRB.jpg'),
 ('dispatch-images', 'wrap-rule/WLV.jpg'), ('dispatch-images', 'wrap-rule/WDL.jpg'), ('dispatch-images', 'wrap-rule/WBT.jpg');
CREATE TEMP TABLE rw_files(who text, files text);
GRANT ALL ON rw_files TO PUBLIC;
SELECT set_config('request.jwt.claims', :'c1_claims', true);
SET LOCAL ROLE authenticated;
INSERT INTO rw_files SELECT 'customer1', coalesce(string_agg(name, ',' ORDER BY name), '') FROM storage.objects WHERE name LIKE 'wrap-rule/%';
RESET ROLE;
SELECT set_config('request.jwt.claims', :'c2_claims', true);
SET LOCAL ROLE authenticated;
INSERT INTO rw_files SELECT 'customer2', coalesce(string_agg(name, ',' ORDER BY name), '') FROM storage.objects WHERE name LIKE 'wrap-rule/%';
RESET ROLE;
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
INSERT INTO rw_files SELECT 'admin', coalesce(string_agg(name, ',' ORDER BY name), '') FROM storage.objects WHERE name LIKE 'wrap-rule/%';
RESET ROLE;
SELECT set_config('request.jwt.claims', :'ghost_claims', true);
SET LOCAL ROLE authenticated;
INSERT INTO rw_files SELECT 'ghost', coalesce(string_agg(name, ',' ORDER BY name), '') FROM storage.objects WHERE name LIKE 'wrap-rule/%';
RESET ROLE;
SELECT pg_temp.rw_assert((SELECT string_agg(who || '=' || files, ' ' ORDER BY who) FROM rw_files)
  = 'admin=wrap-rule/WBT.jpg,wrap-rule/WDL.jpg,wrap-rule/WLV.jpg,wrap-rule/WRB.jpg,wrap-rule/WRD.jpg,wrap-rule/WRL.jpg customer1=wrap-rule/WLV.jpg,wrap-rule/WRL.jpg customer2=wrap-rule/WBT.jpg,wrap-rule/WRB.jpg ghost=',
  'photo files per role (customer one must not read the files of its deleted receipt and dispatch): ' || (SELECT string_agg(who || '=' || files, ' ' ORDER BY who) FROM rw_files));

-- owns_customer() asks active_role() once per call (it asked three times before migration 137).
SET LOCAL track_functions = 'all';
CREATE TEMP TABLE rw_calls0 AS SELECT coalesce(sum(calls), 0) AS n FROM pg_stat_xact_user_functions WHERE funcid = 'warehouse_security.active_role'::regproc;
SELECT set_config('request.jwt.claims', :'c1_claims', true);
SET LOCAL ROLE authenticated;
SELECT warehouse_security.owns_customer(:'cust1') AS owns \gset
RESET ROLE;
SELECT pg_temp.rw_assert(:'owns' = 't', 'customer one owns its customer');
SELECT pg_temp.rw_assert((SELECT coalesce(sum(calls), 0) FROM pg_stat_xact_user_functions WHERE funcid = 'warehouse_security.active_role'::regproc) - (SELECT n FROM rw_calls0) = 1,
  'owns_customer() calls active_role() once, not ' || ((SELECT coalesce(sum(calls), 0) FROM pg_stat_xact_user_functions WHERE funcid = 'warehouse_security.active_role'::regproc) - (SELECT n FROM rw_calls0)));

-- A policy that calls active_role() unwrapped asks it again for every row; wrapped, a statement asks it a few times, however many
-- rows the table holds. Staff read all 63+ lines of dispatch_trl; before migration 137 that took a lookup per row and policy.
SELECT coalesce(sum(calls), 0) AS role_calls0 FROM pg_stat_xact_user_functions WHERE funcid = 'warehouse_security.active_role'::regproc \gset
SELECT set_config('request.jwt.claims', :'staff_claims', true);
SET LOCAL ROLE authenticated;
SELECT count(*) AS staff_lines FROM public.dispatch_trl \gset
RESET ROLE;
SELECT coalesce(sum(calls), 0) - :role_calls0 AS role_calls FROM pg_stat_xact_user_functions WHERE funcid = 'warehouse_security.active_role'::regproc \gset
SELECT pg_temp.rw_assert(:'staff_lines'::int >= 63, 'staff read the lines of dispatch_trl (' || :'staff_lines' || ')');
SELECT pg_temp.rw_assert(:'role_calls'::int <= 10, 'a staff read of ' || :'staff_lines' || ' dispatch lines called active_role() ' || :'role_calls' || ' times: the policies evaluate it per row');
ROLLBACK;
