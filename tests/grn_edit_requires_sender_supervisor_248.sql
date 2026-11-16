-- WH-248: what tests/grn_sender_supervisor_required_231.sql, _edit_keeps_..._233.sql and grn_names_trimmed_237.sql do not hold.
--   1. A save that changes only the rates (update_grn with p_rates, every other field and photo as stored) may leave an empty sender or an
--      empty or half-filled supervisor as stored; rates plus any other change is refused (SENDER_REQUIRED / SUPERVISOR_REQUIRED), the GRN
--      unchanged. A save that changes nothing but sends p_rates (what the app sends on every administrator's or supervisor's save) is accepted
--      (Product, 2026-11-16: accept as built); the same call without p_rates is an ordinary edit and is refused.
--   2. The history import (public.import_history) stores the customer's name as the sender of a row whose sender is blank in the file,
--      and no supervisor; a sender that is given is kept; running the same file again adds nothing.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.r_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'grn edit requires sender supervisor: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.r_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.r_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- The stored lines of the GRN, as an edit sends them back.
CREATE FUNCTION pg_temp.r_lines(p_no text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_agg(jsonb_build_object('id', t.id, 'item_id', t.item_id, 'item_name', t.item_name, 'packaging', t.packaging, 'qty', t.qty, 'weight', t.weight) ORDER BY t.id)
  FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = p_no $$;
-- Put the stored sender and supervisor of R248 in a given state (a direct write, as the superuser).
CREATE FUNCTION pg_temp.r_put(p_sender text, p_sid uuid, p_sname text) RETURNS void LANGUAGE sql AS $$
  UPDATE public.goodsreceived SET sender_name = p_sender, supervisor_id = p_sid, supervisor_name = p_sname WHERE gr_no = 'R248' $$;
-- One edit of R248: p_note and p_rates are optional (NULL = not sent); the lines are always sent as stored. Expect 'ok' or a refusal reason;
-- after a refusal the GRN row and its lines are identical, after 'ok' the sender and supervisor are as stored before the call.
CREATE FUNCTION pg_temp.r_edit(p_label text, p_note text, p_rates jsonb, p_expect text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_row_before jsonb; v_lines_before jsonb; v_res jsonb; v_row_after jsonb; v_lines_after jsonb; b public.goodsreceived; a public.goodsreceived;
BEGIN
  SELECT * INTO b FROM public.goodsreceived WHERE gr_no = 'R248';
  v_id := b.id;
  SELECT to_jsonb(x) INTO v_row_before FROM public.goodsreceived x WHERE x.id = v_id;
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.id), '[]') INTO v_lines_before FROM public.goodsreceived_trl t WHERE t.gr_id = v_id;
  SET LOCAL ROLE authenticated;
  v_res := public.update_grn(p_grn_id => v_id, p_note => p_note, p_rates => p_rates, p_items => pg_temp.r_lines('R248'));
  RESET ROLE;
  SELECT to_jsonb(x) INTO v_row_after FROM public.goodsreceived x WHERE x.id = v_id;
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.id), '[]') INTO v_lines_after FROM public.goodsreceived_trl t WHERE t.gr_id = v_id;
  SELECT * INTO a FROM public.goodsreceived WHERE id = v_id;
  IF p_expect = 'ok' THEN
    PERFORM pg_temp.r_assert(v_res->>'success' = 'true', p_label || ': saves: ' || v_res);
    PERFORM pg_temp.r_assert(a.sender_name IS NOT DISTINCT FROM b.sender_name AND a.supervisor_id IS NOT DISTINCT FROM b.supervisor_id
      AND a.supervisor_name IS NOT DISTINCT FROM b.supervisor_name, p_label || ': sender and supervisor stay as stored');
  ELSE
    PERFORM pg_temp.r_assert(v_res->>'success' = 'false' AND v_res->>'reason' = p_expect AND v_res->>'error_code' = 'WH409', p_label || ': refused with ' || p_expect || ': ' || v_res);
    PERFORM pg_temp.r_assert(v_row_after = v_row_before AND v_lines_after = v_lines_before, p_label || ': the GRN and its lines are identical after the refusal');
  END IF;
  RETURN v_res;
END $$;

INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888887481', 'Rates Rule Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888887482', 'Rates Rule Supervisor One', 'supervisor', true, 'approved');
SELECT id AS p1 FROM public.user_profiles WHERE mobile = '919888887482' \gset
SELECT pg_temp.r_login('9888887481') AS admin_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Rates Rule Customer', '9888887484') RETURNING id AS cust \gset
INSERT INTO public.items(name, packaging) VALUES ('Rates Rule Cumin', 'Bag') RETURNING id AS cumin \gset
SELECT set_config('request.jwt.claims', :'admin_claims', true);

SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'R248', p_date=>'2026-04-01T12:00:00Z', p_customer_id=>:'cust'::uuid, p_customer_name=>'Rates Rule Customer',
  p_sender_name=>'Orig Sender', p_supervisor_id=>:'p1'::uuid, p_supervisor_name=>'Sup One', p_pricing_mode=>'MONTHLY', p_idempotency_key=>'wh248-save',
  p_items=>jsonb_build_array(jsonb_build_object('item_id', :'cumin'::uuid, 'item_name', 'Rates Rule Cumin', 'packaging', 'Bag', 'qty', 2, 'weight', 10))) AS made \gset
RESET ROLE;
SELECT pg_temp.r_assert(:'made'::jsonb->>'success' = 'true', 'the GRN was saved: ' || :'made');
SELECT jsonb_build_array(jsonb_build_object('scope', 'grn', 'item_id', :'cumin', 'weight_min', 0, 'weight_max', 100, 'unit_price', 7, 'labour_rate', 1, 'tax_percent', 0)) AS rates_a \gset
SELECT jsonb_build_array(jsonb_build_object('scope', 'grn', 'item_id', :'cumin', 'weight_min', 0, 'weight_max', 100, 'unit_price', 8, 'labour_rate', 1, 'tax_percent', 0)) AS rates_b \gset

-- ===== 1. a rates-only save leaves an empty sender and supervisor as stored =====
SELECT pg_temp.r_put(NULL, NULL, NULL);
SELECT pg_temp.r_edit('rates only, sender and supervisor empty', NULL, :'rates_a'::jsonb, 'ok') AS rates_empty \gset
SELECT pg_temp.r_assert((SELECT count(*) = 1 AND bool_and(unit_price = 7) FROM public.grn_rates r JOIN public.goodsreceived g ON g.id = r.gr_id WHERE g.gr_no = 'R248'),
  'the rates were stored by the rates-only save');
SELECT pg_temp.r_edit('new rates only, sender and supervisor empty', NULL, :'rates_b'::jsonb, 'ok') AS rates_empty_again \gset
SELECT pg_temp.r_assert((SELECT count(*) = 1 AND bool_and(unit_price = 8) FROM public.grn_rates r JOIN public.goodsreceived g ON g.id = r.gr_id WHERE g.gr_no = 'R248'),
  'the second rates-only save replaced the rates');
SELECT pg_temp.r_put('', :'p1'::uuid, NULL);
SELECT pg_temp.r_edit('rates only, empty-string sender, id without a name', NULL, :'rates_a'::jsonb, 'ok') AS rates_half \gset
SELECT pg_temp.r_put('Orig Sender', NULL, 'Sup One');
SELECT pg_temp.r_edit('rates only, name without an id', NULL, :'rates_b'::jsonb, 'ok') AS rates_name \gset

-- No change at all, p_rates sent as stored (what the app sends on every save): accepted, as built.
SELECT pg_temp.r_put(NULL, NULL, NULL);
SELECT pg_temp.r_edit('no change, rates sent as stored', NULL, :'rates_b'::jsonb, 'ok') AS no_change \gset

-- Rates plus any other change is an ordinary edit: refused, nothing written (not even the rates).
SELECT pg_temp.r_edit('rates and a note, sender empty', 'A new note', :'rates_a'::jsonb, 'SENDER_REQUIRED') AS rates_note \gset
SELECT pg_temp.r_assert((SELECT bool_and(unit_price = 8) FROM public.grn_rates r JOIN public.goodsreceived g ON g.id = r.gr_id WHERE g.gr_no = 'R248'),
  'the refused call did not change the rates');
SELECT pg_temp.r_put('Orig Sender', NULL, NULL);
SELECT pg_temp.r_edit('rates and a note, supervisor empty', 'A new note', :'rates_a'::jsonb, 'SUPERVISOR_REQUIRED') AS rates_note_sup \gset
-- The same call without p_rates is an ordinary edit too: refused.
SELECT pg_temp.r_put(NULL, NULL, NULL);
SELECT pg_temp.r_edit('no rates sent, nothing else changed, sender empty', NULL, NULL, 'SENDER_REQUIRED') AS no_rates \gset
SELECT pg_temp.r_put('Orig Sender', :'p1'::uuid, NULL);
SELECT pg_temp.r_edit('no rates sent, nothing else changed, supervisor half-filled', NULL, NULL, 'SUPERVISOR_REQUIRED') AS no_rates_sup \gset
-- A whole GRN is not affected: a note edit and a rates-only save both save.
SELECT pg_temp.r_put('Orig Sender', :'p1'::uuid, 'Sup One');
SELECT pg_temp.r_edit('whole GRN, a note', 'Whole note', NULL, 'ok') AS whole_note \gset
SELECT pg_temp.r_assert((SELECT note = 'Whole note' FROM public.goodsreceived WHERE gr_no = 'R248'), 'the note of the whole GRN was saved');

-- ===== 1b. the photo conditions of the rates-only check (warehouse_security.grn_save_keeps_stored) =====
-- A GRN with two lines and two confirmed photos (a header photo and a photo of line 1), written directly (no Storage object is needed
-- for the rows). A rates-only save must send the photos as stored: one photo removed, or one moved to another line, is a change.
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'R248P', p_date=>'2026-04-01T12:00:00Z', p_customer_id=>:'cust'::uuid, p_customer_name=>'Rates Rule Customer',
  p_sender_name=>'Orig Sender', p_supervisor_id=>:'p1'::uuid, p_supervisor_name=>'Sup One', p_pricing_mode=>'MONTHLY', p_idempotency_key=>'wh248-photos',
  p_items=>jsonb_build_array(jsonb_build_object('item_id', :'cumin'::uuid, 'item_name', 'Rates Rule Cumin', 'packaging', 'Bag', 'qty', 2, 'weight', 10),
                             jsonb_build_object('item_id', :'cumin'::uuid, 'item_name', 'Rates Rule Cumin', 'packaging', 'Bag', 'qty', 3, 'weight', 12))) AS made_p \gset
RESET ROLE;
SELECT pg_temp.r_assert(:'made_p'::jsonb->>'success' = 'true', 'the GRN with photos was saved: ' || :'made_p');
SELECT id AS pg FROM public.goodsreceived WHERE gr_no = 'R248P' \gset
SELECT id AS pl1 FROM public.goodsreceived_trl WHERE gr_id = :'pg'::uuid ORDER BY id LIMIT 1 \gset
SELECT id AS pl2 FROM public.goodsreceived_trl WHERE gr_id = :'pg'::uuid ORDER BY id OFFSET 1 LIMIT 1 \gset
INSERT INTO public.grn_images(grn_id, grn_item_id, image_type, storage_path, original_filename, file_size, mime_type, status)
 VALUES (:'pg'::uuid, NULL, 'header', 'wh248/header.jpg', 'header.jpg', 1000, 'image/jpeg', 'confirmed') RETURNING id AS ph \gset
INSERT INTO public.grn_images(grn_id, grn_item_id, image_type, storage_path, original_filename, file_size, mime_type, status)
 VALUES (:'pg'::uuid, :'pl1'::uuid, 'item', 'wh248/line1.jpg', 'line1.jpg', 1000, 'image/jpeg', 'confirmed') RETURNING id AS pi \gset
SELECT jsonb_build_array(jsonb_build_object('id', :'ph', 'image_type', 'header', 'storage_path', 'wh248/header.jpg'),
                         jsonb_build_object('id', :'pi', 'image_type', 'item', 'grn_item_id', :'pl1', 'storage_path', 'wh248/line1.jpg')) AS imgs_stored \gset
SELECT jsonb_build_array(jsonb_build_object('id', :'ph', 'image_type', 'header', 'storage_path', 'wh248/header.jpg')) AS imgs_removed \gset
SELECT jsonb_build_array(jsonb_build_object('id', :'ph', 'image_type', 'header', 'storage_path', 'wh248/header.jpg'),
                         jsonb_build_object('id', :'pi', 'image_type', 'item', 'grn_item_id', :'pl2', 'storage_path', 'wh248/line1.jpg')) AS imgs_moved \gset
-- One rates-only call with the given photo list; expect 'ok' or a reason. A refusal leaves the row, the lines and the photos identical.
CREATE FUNCTION pg_temp.r_photo(p_label text, p_images jsonb, p_expect text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_row jsonb; v_imgs jsonb; v_res jsonb; v_row2 jsonb; v_imgs2 jsonb;
BEGIN
  SELECT x.id, to_jsonb(x) INTO v_id, v_row FROM public.goodsreceived x WHERE x.gr_no = 'R248P';
  SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY i.id), '[]') INTO v_imgs FROM public.grn_images i WHERE i.grn_id = v_id;
  SET LOCAL ROLE authenticated;
  v_res := public.update_grn(p_grn_id => v_id, p_items => pg_temp.r_lines('R248P'), p_images => p_images,
    p_rates => (SELECT jsonb_build_array(jsonb_build_object('scope', 'grn', 'item_id', t.item_id, 'weight_min', 0, 'weight_max', 100, 'unit_price', 9, 'labour_rate', 1, 'tax_percent', 0))
                FROM public.goodsreceived_trl t WHERE t.gr_id = v_id ORDER BY t.id LIMIT 1));
  RESET ROLE;
  SELECT to_jsonb(x) INTO v_row2 FROM public.goodsreceived x WHERE x.id = v_id;
  SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY i.id), '[]') INTO v_imgs2 FROM public.grn_images i WHERE i.grn_id = v_id;
  IF p_expect = 'ok' THEN
    PERFORM pg_temp.r_assert(v_res->>'success' = 'true', p_label || ': saves: ' || v_res);
    PERFORM pg_temp.r_assert((SELECT sender_name IS NULL AND supervisor_id IS NULL AND supervisor_name IS NULL FROM public.goodsreceived WHERE id = v_id)
      AND (SELECT count(*) = 2 FROM public.grn_images WHERE grn_id = v_id AND status = 'confirmed'), p_label || ': sender and supervisor stay empty, both photos stay');
  ELSE
    PERFORM pg_temp.r_assert(v_res->>'success' = 'false' AND v_res->>'reason' = p_expect AND v_res->>'error_code' = 'WH409', p_label || ': refused with ' || p_expect || ': ' || v_res);
    PERFORM pg_temp.r_assert(v_row2 = v_row AND v_imgs2 = v_imgs, p_label || ': the GRN row and its photos are identical after the refusal');
  END IF;
END $$;
UPDATE public.goodsreceived SET sender_name = NULL, supervisor_id = NULL, supervisor_name = NULL WHERE gr_no = 'R248P';
SELECT pg_temp.r_photo('rates only, empty sender, photos as stored', :'imgs_stored'::jsonb, 'ok');
UPDATE public.goodsreceived SET sender_name = NULL, supervisor_id = NULL, supervisor_name = NULL WHERE gr_no = 'R248P';
SELECT pg_temp.r_photo('rates only, empty sender, a photo removed', :'imgs_removed'::jsonb, 'SENDER_REQUIRED');
SELECT pg_temp.r_photo('rates only, empty sender, a photo moved to another line', :'imgs_moved'::jsonb, 'SENDER_REQUIRED');
UPDATE public.goodsreceived SET sender_name = 'Orig Sender', supervisor_id = NULL, supervisor_name = NULL WHERE gr_no = 'R248P';
SELECT pg_temp.r_photo('rates only, empty supervisor, a photo removed', :'imgs_removed'::jsonb, 'SUPERVISOR_REQUIRED');
SELECT pg_temp.r_photo('rates only, empty supervisor, a photo moved to another line', :'imgs_moved'::jsonb, 'SUPERVISOR_REQUIRED');

-- ===== 2. the history import =====
SELECT pg_temp.r_assert((SELECT count(*) FROM warehouse_import.stage_grns) = 0, 'no staged rows before this part');
INSERT INTO warehouse_import.stage_grns(line, gr_no, gr_date, customer, pricing, sender) VALUES
 (2, 'A0801', '2023-05-05', 'Rates Rule Customer', 'MONTHLY', NULL),
 (3, 'A0802', '2023-05-06', 'Rates Rule Customer', 'MONTHLY', ''),
 (4, 'A0803', '2023-05-07', 'Rates Rule Customer', 'MONTHLY', E'  \t '),
 (5, 'A0804', '2023-05-08', 'Rates Rule Customer', 'MONTHLY', 'Given Sender');
INSERT INTO warehouse_import.stage_grn_lines(line, gr_no, gr_date, line_no, item, packaging, qty, weight, stock_now) VALUES
 (2, 'A0801', '2023-05-05', 1, 'Rates Rule Cumin', 'Bag', 10, 50, 10), (3, 'A0802', '2023-05-06', 1, 'Rates Rule Cumin', 'Bag', 10, 50, 10),
 (4, 'A0803', '2023-05-07', 1, 'Rates Rule Cumin', 'Bag', 10, 50, 10), (5, 'A0804', '2023-05-08', 1, 'Rates Rule Cumin', 'Bag', 10, 50, 10);
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SET LOCAL ROLE service_role;
SELECT public.import_history('{}'::jsonb, true) AS imported \gset
RESET ROLE;
SELECT pg_temp.r_assert(:'imported'::jsonb->>'success' = 'true' AND :'imported'::jsonb->>'applied' = 'true', 'the import applies: ' || :'imported');
SELECT pg_temp.r_assert((SELECT count(*) = 4 FROM public.goodsreceived WHERE gr_no LIKE 'A080_' AND import_batch_id IS NOT NULL), 'the four GRNs were imported');
SELECT pg_temp.r_assert((SELECT bool_and(sender_name = 'Rates Rule Customer' AND supervisor_id IS NULL AND supervisor_name IS NULL)
  FROM public.goodsreceived WHERE gr_no IN ('A0801', 'A0802', 'A0803')),
  'a blank sender (NULL, empty, white space) is imported as the customer''s name, with no supervisor');
SELECT pg_temp.r_assert((SELECT sender_name = 'Given Sender' AND supervisor_id IS NULL AND supervisor_name IS NULL FROM public.goodsreceived WHERE gr_no = 'A0804'),
  'a sender that is given is kept');
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SET LOCAL ROLE service_role;
SELECT public.import_history('{}'::jsonb, true) AS imported_again \gset
RESET ROLE;
SELECT pg_temp.r_assert(:'imported_again'::jsonb->>'success' = 'true' AND (SELECT count(*) = 4 FROM public.goodsreceived WHERE gr_no LIKE 'A080_'),
  'the same file again adds no GRN: ' || :'imported_again');
SELECT pg_temp.r_assert((:'imported_again'::jsonb#>>'{files,grns,add}')::int = 0, 'the same file again finds the GRNs already there: ' || :'imported_again');
ROLLBACK;
\echo 'GRN edit requires sender and supervisor, rates-only save, import default (WH-248) checks passed.'
