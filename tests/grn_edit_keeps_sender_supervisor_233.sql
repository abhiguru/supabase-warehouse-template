-- WH-233, as changed by WH-248: an edit must leave the GRN with a sender name and a whole supervisor (id and name), whatever it held before
--   (SENDER_REQUIRED, SUPERVISOR_REQUIRED, sender judged first). Two callers may leave an empty or half-filled value as stored: fas-sync's
--   updates (session_user supabase_admin and a fas.session mark; the API's login with the mark is NOT exempt) and a rates-only save (tests/
--   grn_edit_requires_sender_supervisor_248.sql). WH-233's rules still hold for those two: a filled sender cannot be blanked, and a changed
--   supervisor (id or name) must end with both. A refusal changes nothing.
-- Half-filled and empty stored values cannot be made through save_grn any more, so they are set with a direct UPDATE here, as the import test does.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.e_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'grn edit keeps sender supervisor: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.e_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.e_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- Since WH-237 a sent blank name is stored as NULL, so the stored values are compared exactly (tests/grn_names_trimmed_237.sql covers the trimming).
-- Put the stored sender and supervisor of a GRN in a given state (a direct write, as the superuser: save_grn cannot make these any more).
CREATE FUNCTION pg_temp.e_put(p_no text, p_sender text, p_sid uuid, p_sname text) RETURNS void LANGUAGE sql AS $$
  UPDATE public.goodsreceived SET sender_name = p_sender, supervisor_id = p_sid, supervisor_name = p_sname WHERE gr_no = p_no $$;
-- One edit through update_grn. NULL means "not sent". Modes:
--   plain: the superuser's own connection, no fas-sync mark;   fas: the same connection with fas-sync's mark (fas.session) set;
--   api:   the mark set AND the API's login (authenticator), the worst case for an exemption;   all as the signed-in admin (role authenticated).
-- p_shape = 'fas' sends what fas-sync's update sends (date, registration, leon, lines) and ignores the sender and supervisor arguments.
-- Expect 'ok' (success, and the stored values are as p_e_*), or a reason (refused, and the GRN row and its lines are identical, updated_at included).
CREATE FUNCTION pg_temp.e_try(p_label text, p_mode text, p_no text, p_sender text, p_sid uuid, p_sname text, p_expect text,
                              p_e_sender text DEFAULT NULL, p_e_sid uuid DEFAULT NULL, p_e_sname text DEFAULT NULL, p_shape text DEFAULT 'edit') RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_row_before jsonb; v_lines_before jsonb; v_lines jsonb; v_res jsonb; v_row_after jsonb; v_lines_after jsonb; g public.goodsreceived;
BEGIN
  SELECT x.id INTO v_id FROM public.goodsreceived x WHERE x.gr_no = p_no;
  SELECT to_jsonb(x) INTO v_row_before FROM public.goodsreceived x WHERE x.id = v_id;
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.id), '[]') INTO v_lines_before FROM public.goodsreceived_trl t WHERE t.gr_id = v_id;
  SELECT jsonb_agg(jsonb_build_object('id', t.id, 'item_id', t.item_id, 'item_name', t.item_name, 'packaging', t.packaging, 'qty', t.qty, 'weight', t.weight) ORDER BY t.id)
    INTO v_lines FROM public.goodsreceived_trl t WHERE t.gr_id = v_id;
  PERFORM set_config('fas.session', CASE WHEN p_mode = 'plain' THEN '' ELSE gen_random_uuid()::text END, true);
  IF p_mode = 'api' THEN SET SESSION AUTHORIZATION authenticator; END IF;
  SET LOCAL ROLE authenticated;
  IF p_shape = 'fas' THEN
    v_res := public.update_grn(p_grn_id => v_id, p_date => (v_row_before->>'date')::timestamptz, p_registration => 'GJ05ZZ9999', p_leon => false,
      p_items => v_lines, p_images => '[]'::jsonb);
  ELSE
    v_res := public.update_grn(p_grn_id => v_id, p_sender_name => p_sender, p_supervisor_id => p_sid, p_supervisor_name => p_sname, p_items => v_lines);
  END IF;
  RESET ROLE;
  IF p_mode = 'api' THEN RESET SESSION AUTHORIZATION; END IF;
  SELECT to_jsonb(x) INTO v_row_after FROM public.goodsreceived x WHERE x.id = v_id;
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.id), '[]') INTO v_lines_after FROM public.goodsreceived_trl t WHERE t.gr_id = v_id;
  SELECT * INTO g FROM public.goodsreceived x WHERE x.id = v_id;
  IF p_expect = 'ok' THEN
    PERFORM pg_temp.e_assert(v_res->>'success' = 'true', p_label || ': saves: ' || v_res);
    IF p_shape = 'fas' THEN
      PERFORM pg_temp.e_assert(g.registration = 'GJ05ZZ9999', p_label || ': fas-sync shape stored the registration');
      PERFORM pg_temp.e_assert(g.sender_name IS NOT DISTINCT FROM (v_row_before->>'sender_name') AND g.supervisor_id IS NOT DISTINCT FROM (v_row_before->>'supervisor_id')::uuid
        AND g.supervisor_name IS NOT DISTINCT FROM (v_row_before->>'supervisor_name'), p_label || ': sender and supervisor untouched, not even NULL to empty');
    ELSE
      PERFORM pg_temp.e_assert(g.sender_name IS NOT DISTINCT FROM p_e_sender AND g.supervisor_id IS NOT DISTINCT FROM p_e_sid
        AND g.supervisor_name IS NOT DISTINCT FROM p_e_sname,
        p_label || ': stored sender/supervisor are as expected: ' || to_jsonb(g)::text);
    END IF;
  ELSE
    PERFORM pg_temp.e_assert(v_res->>'success' = 'false' AND v_res->>'reason' = p_expect AND v_res->>'error_code' = 'WH409', p_label || ': refused with ' || p_expect || ': ' || v_res);
    PERFORM pg_temp.e_assert(v_row_after = v_row_before AND v_lines_after = v_lines_before, p_label || ': the GRN and its lines are identical after the refusal');
  END IF;
END $$;

INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888887331', 'Edit Rule Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888887332', 'Edit Rule Supervisor One', 'supervisor', true, 'approved'),
 (gen_random_uuid(), '919888887333', 'Edit Rule Supervisor Two', 'supervisor', true, 'approved');
SELECT id AS p1 FROM public.user_profiles WHERE mobile = '919888887332' \gset
SELECT id AS p2 FROM public.user_profiles WHERE mobile = '919888887333' \gset
SELECT pg_temp.e_login('9888887331') AS admin_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Edit Rule Customer', '9888887334') RETURNING id AS cust \gset
INSERT INTO public.items(name, packaging) VALUES ('Edit Rule Cumin', 'Bag') RETURNING id AS cumin \gset
SELECT set_config('request.jwt.claims', :'admin_claims', true);

-- One whole GRN made the normal way, with two lines.
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'E233', p_date=>'2026-04-01T12:00:00Z', p_customer_id=>:'cust'::uuid, p_customer_name=>'Edit Rule Customer',
  p_sender_name=>'Orig Sender', p_supervisor_id=>:'p1'::uuid, p_supervisor_name=>'Sup One', p_pricing_mode=>'MONTHLY', p_idempotency_key=>'wh233-save',
  p_items=>jsonb_build_array(jsonb_build_object('item_id', :'cumin'::uuid, 'item_name', 'Edit Rule Cumin', 'packaging', 'Bag', 'qty', 2, 'weight', 10),
                             jsonb_build_object('item_id', :'cumin'::uuid, 'item_name', 'Edit Rule Cumin', 'packaging', 'Bag', 'qty', 3, 'weight', 12))) AS made \gset
RESET ROLE;
SELECT pg_temp.e_assert(:'made'::jsonb->>'success' = 'true', 'the GRN was saved: ' || :'made');
SELECT pg_temp.e_assert((SELECT count(*) = 2 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = 'E233'), 'two lines');

-- ===== Sender: a filled sender may not end blank, on every path =====
SELECT pg_temp.e_put('E233', 'Orig Sender', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('sender blanked plain: empty string', 'plain', 'E233', '', NULL, NULL, 'SENDER_REQUIRED');
SELECT pg_temp.e_try('sender blanked plain: white space', 'plain', 'E233', E'  \t  ', NULL, NULL, 'SENDER_REQUIRED');
SELECT pg_temp.e_try('sender blanked plain: non-breaking space', 'plain', 'E233', E' ', NULL, NULL, 'SENDER_REQUIRED');
SELECT pg_temp.e_try('sender blanked on fas-sync''s path: empty string', 'fas', 'E233', '', NULL, NULL, 'SENDER_REQUIRED');
SELECT pg_temp.e_try('sender blanked on fas-sync''s path: white space', 'fas', 'E233', E'   ', NULL, NULL, 'SENDER_REQUIRED');
SELECT pg_temp.e_try('sender blanked with the API login: empty string', 'api', 'E233', '', NULL, NULL, 'SENDER_REQUIRED');
SELECT pg_temp.e_try('sender blanked with the API login: white space', 'api', 'E233', E' \t ', NULL, NULL, 'SENDER_REQUIRED');
-- Sender blank together with a good supervisor change is still refused (the sender is judged on its own).
SELECT pg_temp.e_try('sender blanked with a valid new supervisor', 'plain', 'E233', '', :'p2'::uuid, 'Sup Two', 'SENDER_REQUIRED');
-- Not sending it, or re-sending it, or changing it to another name saves, on every path.
SELECT pg_temp.e_try('sender not sent plain', 'plain', 'E233', NULL, NULL, NULL, 'ok', 'Orig Sender', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('sender not sent on fas-sync''s path', 'fas', 'E233', NULL, NULL, NULL, 'ok', 'Orig Sender', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('sender not sent with the API login', 'api', 'E233', NULL, NULL, NULL, 'ok', 'Orig Sender', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('sender re-sent as stored', 'plain', 'E233', 'Orig Sender', NULL, NULL, 'ok', 'Orig Sender', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('sender changed to another name', 'plain', 'E233', 'Another Sender', NULL, NULL, 'ok', 'Another Sender', :'p1'::uuid, 'Sup One');

-- ===== A blank stored sender may not stay blank (WH-248; WH-233 let it stay), except on fas-sync's path; it may be filled =====
SELECT pg_temp.e_put('E233', NULL, :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('NULL sender, not sent', 'plain', 'E233', NULL, NULL, NULL, 'SENDER_REQUIRED');
SELECT pg_temp.e_try('NULL sender, sent empty', 'plain', 'E233', '', NULL, NULL, 'SENDER_REQUIRED');
SELECT pg_temp.e_try('NULL sender, sent white space', 'plain', 'E233', E'  \t ', NULL, NULL, 'SENDER_REQUIRED');
SELECT pg_temp.e_try('NULL sender, sent empty with the API login', 'api', 'E233', '', NULL, NULL, 'SENDER_REQUIRED');
SELECT pg_temp.e_put('E233', '', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('empty-string sender, not sent', 'plain', 'E233', NULL, NULL, NULL, 'SENDER_REQUIRED');
-- WH-237: a sent blank is stored as NULL, not as ''.
SELECT pg_temp.e_try('empty-string sender, sent empty', 'fas', 'E233', '', NULL, NULL, 'ok', NULL, :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_put('E233', E'   ', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('white-space sender, sent empty', 'plain', 'E233', '', NULL, NULL, 'SENDER_REQUIRED');
SELECT pg_temp.e_put('E233', NULL, :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('NULL sender filled', 'plain', 'E233', 'Now Filled', NULL, NULL, 'ok', 'Now Filled', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_put('E233', '', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('empty-string sender filled with the API login', 'api', 'E233', 'Now Filled', NULL, NULL, 'ok', 'Now Filled', :'p1'::uuid, 'Sup One');

-- ===== Whole supervisor (id and name) =====
SELECT pg_temp.e_put('E233', 'Orig Sender', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('whole supervisor: name blanked plain', 'plain', 'E233', NULL, NULL, '', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('whole supervisor: name white space', 'plain', 'E233', NULL, NULL, E'  \t ', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('whole supervisor: name blanked on fas-sync''s path', 'fas', 'E233', NULL, NULL, '', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('whole supervisor: name blanked with the API login', 'api', 'E233', NULL, NULL, '', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('whole supervisor: another id with a blank name', 'plain', 'E233', NULL, :'p2'::uuid, '', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('whole supervisor: another id with a blank name on fas-sync''s path', 'fas', 'E233', NULL, :'p2'::uuid, E'  ', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('whole supervisor: nothing sent', 'plain', 'E233', NULL, NULL, NULL, 'ok', 'Orig Sender', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('whole supervisor: stored id and name re-sent', 'plain', 'E233', NULL, :'p1'::uuid, 'Sup One', 'ok', 'Orig Sender', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('whole supervisor: another id, name not sent, keeps the name', 'plain', 'E233', NULL, :'p2'::uuid, NULL, 'ok', 'Orig Sender', :'p2'::uuid, 'Sup One');
SELECT pg_temp.e_put('E233', 'Orig Sender', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('whole supervisor: another id with a new name', 'plain', 'E233', NULL, :'p2'::uuid, 'Sup Two', 'ok', 'Orig Sender', :'p2'::uuid, 'Sup Two');
SELECT pg_temp.e_put('E233', 'Orig Sender', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('whole supervisor: only the name changed', 'plain', 'E233', NULL, NULL, 'Sup One Renamed', 'ok', 'Orig Sender', :'p1'::uuid, 'Sup One Renamed');

-- ===== Id without a name: an edit must complete it (WH-248), except on fas-sync's path =====
SELECT pg_temp.e_put('E233', 'Orig Sender', :'p1'::uuid, NULL);
SELECT pg_temp.e_try('id only: nothing sent', 'plain', 'E233', NULL, NULL, NULL, 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('id only: stored id sent', 'plain', 'E233', NULL, :'p1'::uuid, NULL, 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('id only: stored id with an empty name', 'plain', 'E233', NULL, :'p1'::uuid, '', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('id only: nothing sent with the API login', 'api', 'E233', NULL, NULL, NULL, 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('id only: a new id with no name', 'plain', 'E233', NULL, :'p2'::uuid, NULL, 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('id only: a new id with an empty name', 'fas', 'E233', NULL, :'p2'::uuid, '', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('id only: completing it with a name', 'plain', 'E233', NULL, NULL, 'Sup One', 'ok', 'Orig Sender', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_put('E233', 'Orig Sender', :'p1'::uuid, NULL);
SELECT pg_temp.e_try('id only: a new id completed with a name', 'plain', 'E233', NULL, :'p2'::uuid, 'Sup Two', 'ok', 'Orig Sender', :'p2'::uuid, 'Sup Two');

-- ===== Name without an id: an edit must complete it (WH-248), except on fas-sync's path =====
SELECT pg_temp.e_put('E233', 'Orig Sender', NULL, 'Sup One');
SELECT pg_temp.e_try('name only: nothing sent', 'plain', 'E233', NULL, NULL, NULL, 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('name only: the stored name sent', 'plain', 'E233', NULL, NULL, 'Sup One', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('name only: nothing sent on fas-sync''s path', 'fas', 'E233', NULL, NULL, NULL, 'ok', 'Orig Sender', NULL, 'Sup One');
SELECT pg_temp.e_try('name only: cleared with an empty name', 'plain', 'E233', NULL, NULL, '', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('name only: cleared with white space, API login', 'api', 'E233', NULL, NULL, E'  ', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('name only: another name', 'plain', 'E233', NULL, NULL, 'Other Name', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('name only: adding an id', 'plain', 'E233', NULL, :'p1'::uuid, NULL, 'ok', 'Orig Sender', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_put('E233', 'Orig Sender', NULL, 'Sup One');
SELECT pg_temp.e_try('name only: adding an id with another name', 'plain', 'E233', NULL, :'p1'::uuid, 'Sup Two', 'ok', 'Orig Sender', :'p1'::uuid, 'Sup Two');

-- ===== Both empty: an edit must fill both (WH-248), except on fas-sync's path =====
SELECT pg_temp.e_put('E233', 'Orig Sender', NULL, NULL);
SELECT pg_temp.e_try('both empty: nothing sent', 'plain', 'E233', NULL, NULL, NULL, 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('both empty: an empty name sent', 'plain', 'E233', NULL, NULL, '', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('both empty: a white-space name sent', 'fas', 'E233', NULL, NULL, E' \t ', 'ok', 'Orig Sender', NULL, NULL);
SELECT pg_temp.e_try('both empty: nothing sent with the API login', 'api', 'E233', NULL, NULL, NULL, 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('both empty: only a name', 'plain', 'E233', NULL, NULL, 'Only Name', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('both empty: only an id', 'plain', 'E233', NULL, :'p1'::uuid, NULL, 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('both empty: an id with an empty name', 'plain', 'E233', NULL, :'p1'::uuid, '', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('both empty: only a name, API login', 'api', 'E233', NULL, NULL, 'Only Name', 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_try('both empty: both together', 'plain', 'E233', NULL, :'p1'::uuid, 'Sup One', 'ok', 'Orig Sender', :'p1'::uuid, 'Sup One');

-- ===== fas-sync's own update (date, registration, leon, lines) saves whatever is stored, and leaves sender and supervisor untouched =====
SELECT pg_temp.e_put('E233', NULL, NULL, NULL);
SELECT pg_temp.e_try('fas-sync update: empty sender, empty supervisor', 'fas', 'E233', NULL, NULL, NULL, 'ok', p_shape => 'fas');
SELECT pg_temp.e_put('E233', NULL, :'p1'::uuid, NULL);
SELECT pg_temp.e_try('fas-sync update: empty sender, id without a name', 'fas', 'E233', NULL, NULL, NULL, 'ok', p_shape => 'fas');
SELECT pg_temp.e_put('E233', NULL, NULL, 'Sup One');
SELECT pg_temp.e_try('fas-sync update: empty sender, name without an id', 'fas', 'E233', NULL, NULL, NULL, 'ok', p_shape => 'fas');
SELECT pg_temp.e_put('E233', 'Orig Sender', :'p1'::uuid, 'Sup One');
SELECT pg_temp.e_try('fas-sync update: whole sender and supervisor', 'fas', 'E233', NULL, NULL, NULL, 'ok', p_shape => 'fas');
SELECT pg_temp.e_put('E233', '', NULL, NULL);
SELECT pg_temp.e_try('fas-sync update: empty-string sender, empty supervisor', 'fas', 'E233', NULL, NULL, NULL, 'ok', p_shape => 'fas');
SELECT pg_temp.e_put('E233', 'Orig Sender', NULL, 'Sup One');
SELECT pg_temp.e_try('fas-sync update: name without an id', 'fas', 'E233', NULL, NULL, NULL, 'ok', p_shape => 'fas');

-- ===== WH-248: fas-sync's path leaves an empty or half-filled value as stored (an edit that sends neither field, or sends it unchanged) =====
SELECT pg_temp.e_put('E233', NULL, NULL, NULL);
SELECT pg_temp.e_try('fas path edit shape: both empty, nothing sent', 'fas', 'E233', NULL, NULL, NULL, 'ok', NULL, NULL, NULL);
SELECT pg_temp.e_put('E233', NULL, :'p1'::uuid, NULL);
SELECT pg_temp.e_try('fas path edit shape: sender empty, id without a name, nothing sent', 'fas', 'E233', NULL, NULL, NULL, 'ok', NULL, :'p1'::uuid, NULL);
SELECT pg_temp.e_put('E233', 'Orig Sender', NULL, 'Sup One');
SELECT pg_temp.e_try('fas path edit shape: name without an id, nothing sent', 'fas', 'E233', NULL, NULL, NULL, 'ok', 'Orig Sender', NULL, 'Sup One');
-- ...and the same edit on the plain path and with the API login (the mark alone does not exempt it) is refused, the GRN unchanged.
SELECT pg_temp.e_try('API login with the mark: name without an id, nothing sent', 'api', 'E233', NULL, NULL, NULL, 'SUPERVISOR_REQUIRED');
SELECT pg_temp.e_put('E233', NULL, NULL, NULL);
SELECT pg_temp.e_try('API login with the mark: both empty, an empty sender sent', 'api', 'E233', '', NULL, NULL, 'SENDER_REQUIRED');
-- Even on fas-sync's path, completing is judged as before: a changed supervisor must end whole.
SELECT pg_temp.e_try('fas path edit shape: only an id sent for an empty supervisor', 'fas', 'E233', NULL, :'p1'::uuid, NULL, 'SUPERVISOR_REQUIRED');
ROLLBACK;
\echo 'GRN edit keeps sender and supervisor (WH-233) checks passed.'
