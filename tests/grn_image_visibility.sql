-- Migration 69: a receipt's unfinished photos follow the image row rules in the RPCs too
-- (external review 2026-10-13, SEC-1 and SEC-2).
--
-- One receipt with two lines (L1, L2) and four photos, registered and confirmed through the app's RPCs:
--   a  header, confirmed, by the administrator
--   b  header, pending,   by staff S1
--   c  item of L1, pending,   by staff S2
--   d  item of L1, confirmed, by staff S2
-- The row rules (migrations 18, 43, 45): administrators and supervisors see every row; staff see confirmed
-- rows and their own pending ones; a customer sees confirmed rows of its own receipts.
--
--   SEC-1 get_grn_details lists header_images / item_images by that rule:
--         admin and supervisor a,b | c,d;  S1 a,b | d;  S2 a | c,d;  the customer a | d.
--         Before: every role got all four.
--   SEC-2 update_grn with a non-empty p_images removes only the omitted rows the caller can see:
--         S1 sending [a] removes b (own pending) and d (confirmed) and keeps c (S2's pending; before, c
--         was removed and S2 could not confirm it). S1 naming c (by its path, with line L2) keeps c as
--         it is: not moved to L2, not inserted again, not counted. The answer's grn.images lists what S1
--         can see. S2 can then confirm c. An administrator omitting S2's pending photo removes it.
--
--   Also get_customer_items_for_order_selection (image_url), get_invoiceable_grns (gr_image_url) and
--         get_customer_grn_activity (image_count, total_images) read only those rows: with S1's pending
--         header photo alone on a receipt, S1 and the administrator get it, S2 and the customer do not
--         (before, the customer got its storage path and every role counted it).
--
-- Runs ONLY in migrations.sh's fresh, network-disabled database (storage.objects rows stand in for
-- uploaded files, as in image_path_rules.sql). All fixture rows roll back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.giv_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'grn image visibility: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.giv_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.giv_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- The fixture letters of the photo ids in an array of image objects, sorted ('a,b').
CREATE TABLE pg_temp.giv_photo(letter text PRIMARY KEY, id uuid);
CREATE FUNCTION pg_temp.giv_letters(arr jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(string_agg(COALESCE(p.letter, '?'), ',' ORDER BY COALESCE(p.letter, '?')), '')
  FROM jsonb_array_elements(COALESCE(arr, '[]'::jsonb)) AS t(x) LEFT JOIN pg_temp.giv_photo p ON p.id = (x->>'id')::uuid $$;
-- header | item photos of the receipt as get_grn_details answers them.
CREATE FUNCTION pg_temp.giv_seen(answer jsonb) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.giv_letters(answer#>'{data,grn,header_images}') || ' | '
    || pg_temp.giv_letters((SELECT jsonb_agg(e) FROM jsonb_array_elements(answer#>'{data,grn,items}') AS l(line),
                             jsonb_array_elements(line->'item_images') AS i(e))) $$;

INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888886901', 'Photo Rule Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888886902', 'Photo Rule Supervisor', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888886903', 'Photo Rule Staff One', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888886904', 'Photo Rule Staff Two', 'staff', true, 'approved'),
 (gen_random_uuid(), '919888886905', 'Photo Rule Reader', 'customer', true, 'approved');
SELECT pg_temp.giv_login('9888886901') AS admin_claims \gset
SELECT pg_temp.giv_login('9888886902') AS supervisor_claims \gset
SELECT pg_temp.giv_login('9888886903') AS s1_claims \gset
SELECT pg_temp.giv_login('9888886904') AS s2_claims \gset
SELECT pg_temp.giv_login('9888886905') AS reader_claims \gset
SELECT id AS s1_profile FROM public.user_profiles WHERE mobile = '919888886903' \gset
SELECT id AS s2_profile FROM public.user_profiles WHERE mobile = '919888886904' \gset
INSERT INTO public.customers(name, mobile) VALUES ('Photo Rule Hazel Cold', '9888886911') RETURNING id AS hazel \gset
INSERT INTO public.items(name, packaging) VALUES ('Photo Rule Garlic', 'Bag') RETURNING id AS garlic \gset
INSERT INTO public.users_customers_new(user_profile_id, customer_id, active)
 SELECT id, :'hazel'::uuid, true FROM public.user_profiles WHERE mobile = '919888886905';

-- The receipt and photo a, as the administrator.
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.giv_assert(public.save_grn(p_gr_no => 'W2PH', p_date => '2026-04-01T12:00:00Z', p_customer_id => :'hazel'::uuid,
  p_customer_name => 'Photo Rule Hazel Cold', p_pricing_mode => 'MONTHLY', p_idempotency_key => 'photo-rule-grn',
  p_items => jsonb_build_array(
    jsonb_build_object('item_id', :'garlic', 'item_name', 'Photo Rule Garlic', 'packaging', 'Bag', 'qty', 10, 'weight', 5, 'package_mark', 'L1'),
    jsonb_build_object('item_id', :'garlic', 'item_name', 'Photo Rule Garlic', 'packaging', 'Bag', 'qty', 10, 'weight', 5, 'package_mark', 'L2')))->>'success' = 'true',
  'fixture receipt W2PH');
SELECT id AS grn FROM public.goodsreceived WHERE gr_no = 'W2PH' \gset
SELECT id AS l1 FROM public.goodsreceived_trl WHERE gr_id = :'grn' AND package_mark = 'L1' \gset
SELECT id AS l2 FROM public.goodsreceived_trl WHERE gr_id = :'grn' AND package_mark = 'L2' \gset
SELECT public.register_grn_image_upload(:'grn'::uuid, 'header', 'a.webp', 32, 'image/webp') AS reg_a \gset
RESET ROLE;
INSERT INTO storage.objects(bucket_id, name) VALUES ('grn-images', :'reg_a'::jsonb->>'storage_path');
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.giv_assert(public.confirm_grn_image_upload((:'reg_a'::jsonb->>'image_id')::uuid, (:'reg_a'::jsonb->>'upload_token')::uuid)->>'success' = 'true',
  'fixture: a confirmed');
RESET ROLE;
-- b, as S1 (left pending).
SELECT set_config('request.jwt.claims', :'s1_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.register_grn_image_upload(:'grn'::uuid, 'header', 'b.webp', 32, 'image/webp') AS reg_b \gset
RESET ROLE;
-- c (left pending) and d (confirmed), as S2.
SELECT set_config('request.jwt.claims', :'s2_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.register_grn_image_upload(:'grn'::uuid, 'item', 'c.webp', 32, 'image/webp', :'l1'::uuid) AS reg_c \gset
SELECT public.register_grn_image_upload(:'grn'::uuid, 'item', 'd.webp', 32, 'image/webp', :'l1'::uuid) AS reg_d \gset
RESET ROLE;
INSERT INTO storage.objects(bucket_id, name) VALUES ('grn-images', :'reg_d'::jsonb->>'storage_path'), ('grn-images', :'reg_c'::jsonb->>'storage_path');
SELECT set_config('request.jwt.claims', :'s2_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.giv_assert(public.confirm_grn_image_upload((:'reg_d'::jsonb->>'image_id')::uuid, (:'reg_d'::jsonb->>'upload_token')::uuid)->>'success' = 'true',
  'fixture: d confirmed');
RESET ROLE;
INSERT INTO pg_temp.giv_photo VALUES ('a', (:'reg_a'::jsonb->>'image_id')::uuid), ('b', (:'reg_b'::jsonb->>'image_id')::uuid),
  ('c', (:'reg_c'::jsonb->>'image_id')::uuid), ('d', (:'reg_d'::jsonb->>'image_id')::uuid);
SELECT pg_temp.giv_assert((SELECT string_agg(p.letter || ':' || i.status || ':' || COALESCE(i.image_type, '') || ':'
      || CASE i.uploaded_by WHEN :'s1_profile'::uuid THEN 'S1' WHEN :'s2_profile'::uuid THEN 'S2' ELSE 'admin' END, ' ' ORDER BY p.letter)
    FROM pg_temp.giv_photo p JOIN public.grn_images i ON i.id = p.id)
  = 'a:confirmed:header:admin b:pending:header:S1 c:pending:item:S2 d:confirmed:item:S2',
  'fixture: the four photos');

-- ---------------------------------------------------------------------------
-- SEC-1 get_grn_details, per role
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_grn_details(:'grn'::uuid)::text AS admin_details \gset
RESET ROLE;
SELECT set_config('request.jwt.claims', :'supervisor_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_grn_details(:'grn'::uuid)::text AS supervisor_details \gset
RESET ROLE;
SELECT set_config('request.jwt.claims', :'s1_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_grn_details(:'grn'::uuid)::text AS s1_details \gset
RESET ROLE;
SELECT set_config('request.jwt.claims', :'s2_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.get_grn_details(:'grn'::uuid)::text AS s2_details \gset
RESET ROLE;
SELECT set_config('request.jwt.claims', :'reader_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.giv_assert(warehouse_security.active_role() = 'customer', 'actual customer role');
SELECT public.get_grn_details(:'grn'::uuid)::text AS reader_details \gset
RESET ROLE;
SELECT pg_temp.giv_assert(:'admin_details'::jsonb->>'success' = 'true' AND pg_temp.giv_seen(:'admin_details'::jsonb) = 'a,b | c,d',
  'SEC-1: the administrator sees all four: ' || pg_temp.giv_seen(:'admin_details'::jsonb));
SELECT pg_temp.giv_assert(pg_temp.giv_seen(:'supervisor_details'::jsonb) = 'a,b | c,d',
  'SEC-1: the supervisor sees all four: ' || pg_temp.giv_seen(:'supervisor_details'::jsonb));
SELECT pg_temp.giv_assert(pg_temp.giv_seen(:'s1_details'::jsonb) = 'a,b | d',
  'SEC-1: S1 sees the confirmed photos and its own pending one: ' || pg_temp.giv_seen(:'s1_details'::jsonb));
SELECT pg_temp.giv_assert(pg_temp.giv_seen(:'s2_details'::jsonb) = 'a | c,d',
  'SEC-1: S2 sees the confirmed photos and its own pending one: ' || pg_temp.giv_seen(:'s2_details'::jsonb));
SELECT pg_temp.giv_assert(:'reader_details'::jsonb->>'success' = 'true' AND pg_temp.giv_seen(:'reader_details'::jsonb) = 'a | d',
  'SEC-1: the customer sees the confirmed photos only: ' || pg_temp.giv_seen(:'reader_details'::jsonb));
-- The answer's shape is unchanged: the two lines are still listed, each with its item_images key.
SELECT pg_temp.giv_assert(jsonb_array_length(:'reader_details'::jsonb#>'{data,grn,items}') = 2
  AND (SELECT bool_and(line ? 'item_images') FROM jsonb_array_elements(:'reader_details'::jsonb#>'{data,grn,items}') AS t(line)),
  'SEC-1: both lines are listed with their item_images');

-- ---------------------------------------------------------------------------
-- The three other RPCs that read grn_images (found while fixing SEC-1)
-- ---------------------------------------------------------------------------
-- Two more receipts of the same customer, each with one photo only: a header photo that S1 registered
-- and left pending. W2PQ keeps its stock (order selection, GRN activity); W2PR is fully dispatched and
-- not invoiced (the invoice picker).
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile = '919888886901' \gset
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.giv_assert(public.save_grn(p_gr_no => 'W2P' || x, p_date => '2026-04-02T12:00:00Z', p_customer_id => :'hazel'::uuid,
  p_customer_name => 'Photo Rule Hazel Cold', p_pricing_mode => 'MONTHLY', p_idempotency_key => 'photo-rule-grn-' || x,
  p_items => jsonb_build_array(
    jsonb_build_object('item_id', :'garlic', 'item_name', 'Photo Rule Garlic', 'packaging', 'Bag', 'qty', 4, 'weight', 5, 'package_mark', x)))->>'success' = 'true',
  'fixture receipt W2P' || x)
FROM unnest(ARRAY['Q', 'R']) AS x;
SELECT id AS grn_q FROM public.goodsreceived WHERE gr_no = 'W2PQ' \gset
SELECT id AS grn_r FROM public.goodsreceived WHERE gr_no = 'W2PR' \gset
SELECT pg_temp.giv_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no', 'W2PRD', 'disp_date', '2026-05-02',
    'customer_id', :'hazel', 'customer_name', 'Photo Rule Hazel Cold',
    'supervisor_id', :'admin_profile', 'supervisor_name', 'Photo Rule Administrator'),
  ARRAY(SELECT jsonb_build_object('gr_trl_id', t.id, 'disp_qty', 4) FROM public.goodsreceived_trl t WHERE t.gr_id = :'grn_r'::uuid),
  0, 'photo-rule-dispatch-r')->>'success' = 'true', 'fixture dispatch of W2PR');
RESET ROLE;
SELECT set_config('request.jwt.claims', :'s1_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.register_grn_image_upload(:'grn_q'::uuid, 'header', 'q.webp', 32, 'image/webp')->>'storage_path' AS path_q \gset
SELECT public.register_grn_image_upload(:'grn_r'::uuid, 'header', 'r.webp', 32, 'image/webp')->>'storage_path' AS path_r \gset
RESET ROLE;
SELECT pg_temp.giv_assert((SELECT bool_and(out_of_stock AND NOT invoiced) FROM public.goodsreceived WHERE id = :'grn_r'::uuid)
  AND (SELECT count(*) FROM public.grn_images WHERE grn_id IN (:'grn_q'::uuid, :'grn_r'::uuid) AND status = 'pending' AND uploaded_by = :'s1_profile'::uuid) = 2,
  'fixture: W2PR is out of stock and not invoiced; W2PQ and W2PR each have S1''s pending header photo');
-- Each role's answers. A customer is refused get_invoiceable_grns (a warehouse function), as before.
CREATE TABLE pg_temp.giv_answer(who text PRIMARY KEY, selection jsonb, invoiceable jsonb, activity jsonb);
GRANT INSERT ON pg_temp.giv_answer TO authenticated;
CREATE FUNCTION pg_temp.giv_read(who text, grn_q uuid, customer uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE invoiceable jsonb;
BEGIN
  BEGIN invoiceable := public.get_invoiceable_grns(100, 0, 'W2PR');
  EXCEPTION WHEN insufficient_privilege THEN invoiceable := jsonb_build_object('refused', SQLERRM); END;
  INSERT INTO pg_temp.giv_answer VALUES (who,
    public.get_customer_items_for_order_selection(p_customer_id => customer, p_grn_no_filter => 'W2PQ'),
    invoiceable,
    public.get_customer_grn_activity(customer, '2026-03-01', '2026-12-31'));
END $$;
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.giv_read('admin', :'grn_q'::uuid, :'hazel'::uuid);
RESET ROLE;
SELECT set_config('request.jwt.claims', :'s1_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.giv_read('S1', :'grn_q'::uuid, :'hazel'::uuid);
RESET ROLE;
SELECT set_config('request.jwt.claims', :'s2_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.giv_read('S2', :'grn_q'::uuid, :'hazel'::uuid);
RESET ROLE;
SELECT set_config('request.jwt.claims', :'reader_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.giv_read('customer', :'grn_q'::uuid, :'hazel'::uuid);
RESET ROLE;
-- get_customer_items_for_order_selection: the photo of a W2PQ line is S1's pending header photo, or none.
SELECT pg_temp.giv_assert((SELECT string_agg(a.who || ':' || COALESCE(
      (SELECT string_agg(CASE x->>'image_url' WHEN :'path_q' THEN 'q' ELSE COALESCE(x->>'image_url', 'none') END, ',')
       FROM jsonb_array_elements(a.selection->'data') AS t(x)), 'no rows'), ' ' ORDER BY a.who COLLATE "C") FROM pg_temp.giv_answer a)
  = 'S1:q S2:none admin:q customer:none',
  'order selection: the pending photo goes to its uploader and the administrator only: '
    || (SELECT string_agg(a.who || ':' || left(a.selection::text, 200), ' | ' ORDER BY a.who) FROM pg_temp.giv_answer a));
-- get_invoiceable_grns: W2PR's header photo likewise; the customer stays refused (the function answers
-- the guard's refusal as an error object).
SELECT pg_temp.giv_assert((SELECT string_agg(a.who || ':' || COALESCE(
      CASE WHEN a.invoiceable ? 'refused' OR a.invoiceable->>'success' IS DISTINCT FROM 'true' THEN 'refused'
           ELSE (SELECT string_agg(CASE x->>'gr_image_url' WHEN :'path_r' THEN 'r' ELSE COALESCE(x->>'gr_image_url', 'none') END, ',')
                 FROM jsonb_array_elements(a.invoiceable->'data') AS t(x)) END, 'no rows'), ' ' ORDER BY a.who COLLATE "C") FROM pg_temp.giv_answer a)
  = 'S1:r S2:none admin:r customer:refused',
  'invoice picker: the pending photo goes to its uploader and the administrator only: '
    || (SELECT string_agg(a.who || ':' || left(a.invoiceable::text, 200), ' | ' ORDER BY a.who) FROM pg_temp.giv_answer a));
-- get_customer_grn_activity: image_count per receipt (W2PH, W2PQ, W2PR) and total_images; the receipts
-- listed are the same three for everyone.
SELECT pg_temp.giv_assert((SELECT string_agg(a.who || ':' || (SELECT string_agg(x->>'gr_no' || '=' || (x->>'image_count'), ',' ORDER BY x->>'gr_no')
      FROM jsonb_array_elements(a.activity#>'{data,grns}') AS t(x)) || '/' || (a.activity#>>'{data,summary,total_images}'), ' ' ORDER BY a.who COLLATE "C")
    FROM pg_temp.giv_answer a)
  = 'S1:W2PH=3,W2PQ=1,W2PR=1/5 S2:W2PH=3,W2PQ=0,W2PR=0/3 admin:W2PH=4,W2PQ=1,W2PR=1/6 customer:W2PH=2,W2PQ=0,W2PR=0/2',
  'GRN activity counts the photos the caller may read: '
    || (SELECT string_agg(a.who || ':' || left(a.activity::text, 150), ' | ' ORDER BY a.who) FROM pg_temp.giv_answer a));

-- ---------------------------------------------------------------------------
-- SEC-2 update_grn as S1
-- ---------------------------------------------------------------------------
SELECT jsonb_build_array(
  jsonb_build_object('id', :'l1', 'item_id', :'garlic', 'item_name', 'Photo Rule Garlic', 'packaging', 'Bag', 'qty', 10, 'weight', 5, 'package_mark', 'L1'),
  jsonb_build_object('id', :'l2', 'item_id', :'garlic', 'item_name', 'Photo Rule Garlic', 'packaging', 'Bag', 'qty', 10, 'weight', 5, 'package_mark', 'L2')) AS lines \gset
SELECT jsonb_build_object('id', :'reg_a'::jsonb->>'image_id', 'image_type', 'header', 'storage_path', :'reg_a'::jsonb->>'storage_path') AS keep_a \gset
SELECT set_config('request.jwt.claims', :'s1_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id => :'grn'::uuid, p_items => :'lines'::jsonb, p_images => jsonb_build_array(:'keep_a'::jsonb)) AS s1_edit \gset
RESET ROLE;
SELECT pg_temp.giv_assert(:'s1_edit'::jsonb->>'success' = 'true', 'SEC-2: S1''s edit is saved: ' || left(:'s1_edit', 300));
SELECT pg_temp.giv_assert((SELECT string_agg(p.letter, ',' ORDER BY p.letter) FROM pg_temp.giv_photo p JOIN public.grn_images i ON i.id = p.id) = 'a,c',
  'SEC-2: S1 omitting b, c, d removes b and d and keeps S2''s pending c: '
    || COALESCE((SELECT string_agg(p.letter, ',' ORDER BY p.letter) FROM pg_temp.giv_photo p JOIN public.grn_images i ON i.id = p.id), 'none'));
SELECT pg_temp.giv_assert(:'s1_edit'::jsonb#>>'{stats,images_deleted}' = '2' AND :'s1_edit'::jsonb#>>'{stats,images_updated}' = '1',
  'SEC-2: two photos removed, one kept: ' || (:'s1_edit'::jsonb->'stats')::text);
SELECT pg_temp.giv_assert((SELECT status = 'pending' AND uploaded_by = :'s2_profile'::uuid AND grn_item_id = :'l1'::uuid
    FROM public.grn_images WHERE id = (:'reg_c'::jsonb->>'image_id')::uuid),
  'SEC-2: c is still S2''s pending photo of L1');
SELECT pg_temp.giv_assert(pg_temp.giv_letters(:'s1_edit'::jsonb#>'{grn,images}') = 'a',
  'SEC-2: the answer lists the photos S1 can see: ' || pg_temp.giv_letters(:'s1_edit'::jsonb#>'{grn,images}'));
-- S1 names c (by its path only, now on line L2): c is kept as it is and not inserted a second time.
SELECT set_config('request.jwt.claims', :'s1_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id => :'grn'::uuid, p_items => :'lines'::jsonb, p_images => jsonb_build_array(:'keep_a'::jsonb,
  jsonb_build_object('image_type', 'item', 'grn_item_id', :'l2', 'storage_path', :'reg_c'::jsonb->>'storage_path',
    'original_filename', 'c.webp', 'file_size', 32, 'mime_type', 'image/webp'))) AS s1_names_c \gset
RESET ROLE;
SELECT pg_temp.giv_assert(:'s1_names_c'::jsonb->>'success' = 'true', 'SEC-2: naming c is not an error: ' || left(:'s1_names_c', 300));
SELECT pg_temp.giv_assert((SELECT count(*) = 1 AND bool_and(id = (:'reg_c'::jsonb->>'image_id')::uuid AND status = 'pending'
      AND uploaded_by = :'s2_profile'::uuid AND grn_item_id = :'l1'::uuid)
    FROM public.grn_images WHERE storage_path = :'reg_c'::jsonb->>'storage_path'),
  'SEC-2: c stays S2''s pending photo of L1, one row');
SELECT pg_temp.giv_assert(:'s1_names_c'::jsonb#>>'{stats,images_updated}' = '1' AND :'s1_names_c'::jsonb#>>'{stats,images_added}' = '0'
  AND :'s1_names_c'::jsonb#>>'{stats,images_deleted}' = '0' AND pg_temp.giv_letters(:'s1_names_c'::jsonb#>'{grn,images}') = 'a',
  'SEC-2: only a is counted and listed: ' || (:'s1_names_c'::jsonb->'stats')::text || ' ' || pg_temp.giv_letters(:'s1_names_c'::jsonb#>'{grn,images}'));

-- S2 can still finish its upload.
SELECT set_config('request.jwt.claims', :'s2_claims', true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.giv_assert(public.confirm_grn_image_upload((:'reg_c'::jsonb->>'image_id')::uuid, (:'reg_c'::jsonb->>'upload_token')::uuid)->>'success' = 'true',
  'SEC-2: S2 confirms c after S1''s edits');
-- e: another pending photo of S2's.
SELECT public.register_grn_image_upload(:'grn'::uuid, 'header', 'e.webp', 32, 'image/webp') AS reg_e \gset
RESET ROLE;
INSERT INTO pg_temp.giv_photo VALUES ('e', (:'reg_e'::jsonb->>'image_id')::uuid);
-- An administrator sees every row, so omitting S2's pending e removes it.
SELECT set_config('request.jwt.claims', :'admin_claims', true);
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id => :'grn'::uuid, p_items => :'lines'::jsonb, p_images => jsonb_build_array(:'keep_a'::jsonb,
  jsonb_build_object('id', :'reg_c'::jsonb->>'image_id', 'image_type', 'item', 'grn_item_id', :'l1', 'storage_path', :'reg_c'::jsonb->>'storage_path'))) AS admin_edit \gset
RESET ROLE;
SELECT pg_temp.giv_assert(:'admin_edit'::jsonb#>>'{stats,images_deleted}' = '1' AND :'admin_edit'::jsonb#>>'{stats,images_updated}' = '2'
  AND (SELECT string_agg(p.letter, ',' ORDER BY p.letter) FROM pg_temp.giv_photo p JOIN public.grn_images i ON i.id = p.id) = 'a,c'
  AND pg_temp.giv_letters(:'admin_edit'::jsonb#>'{grn,images}') = 'a,c',
  'SEC-2: the administrator omitting S2''s pending e removes it: ' || (:'admin_edit'::jsonb->'stats')::text);

-- update_grn and get_grn_details keep SECURITY DEFINER, their settings and grants.
SELECT pg_temp.giv_assert(p.prosecdef AND p.proconfig IS NOT NULL AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
    AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
    AND pg_get_functiondef(p.oid) ~ ('BEGIN\s+PERFORM warehouse_security\.authorize_rpc\(''' || p.proname || ''','),
  'SECURITY DEFINER, settings, grants and the guard first in ' || p.proname)
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('update_grn', 'get_grn_details');

-- The helper: not callable by the app roles, used inside the definer functions only.
SELECT pg_temp.giv_assert(CASE WHEN to_regprocedure('warehouse_security.grn_image_visible(text,uuid)') IS NULL THEN false
    ELSE NOT has_function_privilege('authenticated', to_regprocedure('warehouse_security.grn_image_visible(text,uuid)'), 'EXECUTE')
     AND NOT has_function_privilege('anon', to_regprocedure('warehouse_security.grn_image_visible(text,uuid)'), 'EXECUTE') END,
  'grn_image_visible exists and is not granted to the app roles');

ROLLBACK;
