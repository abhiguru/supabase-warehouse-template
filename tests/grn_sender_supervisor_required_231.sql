-- WH-231: save_grn refuses a NEW GRN with no sender name or no supervisor (SENDER_REQUIRED / SUPERVISOR_REQUIRED, WH409), and writes nothing.
--   An edit of an existing GRN that has neither (update_grn, WH-230) is not held to the rule; the history import (WH-180) never calls save_grn.
--   Exempt: a GRN that fas-sync creates may have no sender (not the supervisor): save_grn recognises it by session_user = supabase_admin AND a
--   non-blank fas.session setting; the API's login (authenticator) and a connection without the mark are refused (tested at the end).
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.s_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'grn sender supervisor required: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.s_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.s_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- One save_grn call; sender and supervisor name are passed as given (NULL stays NULL), the supervisor id only when p_sup is true.
CREATE FUNCTION pg_temp.s_save(p_no text, p_cust uuid, p_item uuid, p_sender text, p_sup boolean, p_supname text, p_key text) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT public.save_grn(p_gr_no=>p_no, p_date=>'2026-04-01T12:00:00Z', p_customer_id=>p_cust, p_customer_name=>'Sender Rule Customer',
    p_sender_name=>p_sender, p_supervisor_id=>CASE WHEN p_sup THEN (SELECT id FROM public.user_profiles WHERE NOT is_service_account ORDER BY created_at LIMIT 1) END, p_supervisor_name=>p_supname,
    p_pricing_mode=>'MONTHLY', p_idempotency_key=>p_key,
    p_items=>jsonb_build_array(jsonb_build_object('item_id', p_item, 'item_name', 'Sender Rule Cumin', 'packaging', 'Bag', 'qty', 2, 'weight', 10))) $$;

-- One save_grn call with the connection and the mark chosen: plain = the superuser's connection with no mark; fas = the same with fas-sync's mark
-- (fas.session, local to the transaction, cleared again after the call); api = the mark AND the API's login (authenticator); a mode starting
-- with 'mark:' sets the rest as the mark text (blank, white space ...). The role is authenticated, as in the calls above.
CREATE FUNCTION pg_temp.s_save_as(p_mode text, p_no text, p_cust uuid, p_item uuid, p_sender text, p_sup boolean, p_supname text, p_key text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_res jsonb;
BEGIN
  PERFORM set_config('fas.session', CASE WHEN p_mode = 'plain' THEN '' WHEN p_mode LIKE 'mark:%' THEN substr(p_mode, 6) ELSE gen_random_uuid()::text END, true);
  IF p_mode = 'api' THEN SET SESSION AUTHORIZATION authenticator; END IF;
  SET LOCAL ROLE authenticated;
  v_res := pg_temp.s_save(p_no, p_cust, p_item, p_sender, p_sup, p_supname, p_key);
  RESET ROLE;
  IF p_mode = 'api' THEN RESET SESSION AUTHORIZATION; END IF;
  PERFORM set_config('fas.session', '', true);
  RETURN v_res;
END $$;

INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888887231', 'Sender Rule Administrator');
SELECT pg_temp.s_login('9888887231') AS admin_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Sender Rule Customer', '9888887232') RETURNING id AS cust \gset
INSERT INTO public.items(name, packaging) VALUES ('Sender Rule Cumin', 'Bag') RETURNING id AS cumin \gset
SELECT set_config('request.jwt.claims', :'admin_claims', true);

SELECT count(*) AS grn_before FROM public.goodsreceived \gset
SELECT count(*) AS line_before FROM public.goodsreceived_trl \gset
SELECT count(*) AS key_before FROM public.idempotency_keys \gset

SET LOCAL ROLE authenticated;
SELECT pg_temp.s_save('S231A', :'cust'::uuid, :'cumin'::uuid, NULL, true, 'Fixture Supervisor', 'wh231-a') AS no_sender \gset
SELECT pg_temp.s_save('S231B', :'cust'::uuid, :'cumin'::uuid, E'  \t  ', true, 'Fixture Supervisor', 'wh231-b') AS blank_sender \gset
SELECT pg_temp.s_save('S231C', :'cust'::uuid, :'cumin'::uuid, 'Fixture Sender', false, 'Fixture Supervisor', 'wh231-c') AS no_sup_id \gset
SELECT pg_temp.s_save('S231D', :'cust'::uuid, :'cumin'::uuid, 'Fixture Sender', true, '   ', 'wh231-d') AS blank_sup_name \gset
SELECT pg_temp.s_save('S231E', :'cust'::uuid, :'cumin'::uuid, NULL, false, NULL, 'wh231-e') AS neither \gset
RESET ROLE;
SELECT pg_temp.s_assert(:'no_sender'::jsonb->>'success' = 'false' AND :'no_sender'::jsonb->>'reason' = 'SENDER_REQUIRED'
  AND :'no_sender'::jsonb->>'error_code' = 'WH409' AND :'no_sender'::jsonb->>'message' = 'Sender name is required', 'no sender: ' || :'no_sender');
SELECT pg_temp.s_assert(:'blank_sender'::jsonb->>'reason' = 'SENDER_REQUIRED' AND :'blank_sender'::jsonb->>'success' = 'false', 'blank sender (spaces, tab, non-breaking space): ' || :'blank_sender');
SELECT pg_temp.s_assert(:'no_sup_id'::jsonb->>'success' = 'false' AND :'no_sup_id'::jsonb->>'reason' = 'SUPERVISOR_REQUIRED'
  AND :'no_sup_id'::jsonb->>'error_code' = 'WH409' AND :'no_sup_id'::jsonb->>'message' = 'Supervisor is required', 'no supervisor id: ' || :'no_sup_id');
SELECT pg_temp.s_assert(:'blank_sup_name'::jsonb->>'reason' = 'SUPERVISOR_REQUIRED' AND :'blank_sup_name'::jsonb->>'success' = 'false', 'blank supervisor name: ' || :'blank_sup_name');
SELECT pg_temp.s_assert(:'neither'::jsonb->>'success' = 'false' AND :'neither'::jsonb->>'reason' = 'SENDER_REQUIRED', 'neither: the sender is named first: ' || :'neither');
-- Nothing was written: no GRN, no line, no stored idempotency key.
SELECT pg_temp.s_assert((SELECT count(*) FROM public.goodsreceived) = :grn_before AND (SELECT count(*) FROM public.goodsreceived_trl) = :line_before
  AND (SELECT count(*) FROM public.idempotency_keys) = :key_before
  AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no LIKE 'S231%'), 'a refused save wrote no row and no key');

-- With both, the same numbers save (the numbers were not used up), including a retry under a refused call's key.
SET LOCAL ROLE authenticated;
SELECT pg_temp.s_save('S231A', :'cust'::uuid, :'cumin'::uuid, 'Fixture Sender', true, 'Fixture Supervisor', 'wh231-a') AS ok_a \gset
SELECT pg_temp.s_save('S231E', :'cust'::uuid, :'cumin'::uuid, 'Fixture Sender', true, 'Fixture Supervisor', 'wh231-e') AS ok_e \gset
RESET ROLE;
SELECT pg_temp.s_assert(:'ok_a'::jsonb->>'success' = 'true' AND :'ok_e'::jsonb->>'success' = 'true', 'both present saves: ' || :'ok_a' || :'ok_e');
SELECT pg_temp.s_assert((SELECT sender_name = 'Fixture Sender' AND supervisor_name = 'Fixture Supervisor' FROM public.goodsreceived WHERE gr_no = 'S231A'), 'sender and supervisor stored');

-- An edit of a GRN that has neither is not refused (WH-230): the empty fields stay empty.
UPDATE public.goodsreceived SET sender_name = NULL, supervisor_id = NULL, supervisor_name = NULL WHERE gr_no = 'S231E';
SELECT id AS e_id FROM public.goodsreceived WHERE gr_no = 'S231E' \gset
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'e_id'::uuid, p_note=>'Edited without sender or supervisor',
  p_items=>(SELECT jsonb_agg(jsonb_build_object('id', t.id, 'item_id', t.item_id, 'item_name', t.item_name, 'packaging', t.packaging, 'qty', t.qty, 'weight', t.weight))
            FROM public.goodsreceived_trl t WHERE t.gr_id = :'e_id'::uuid)) AS edited \gset
RESET ROLE;
SELECT pg_temp.s_assert(:'edited'::jsonb->>'success' = 'true' AND COALESCE(:'edited'::jsonb->>'reason', '') NOT IN ('SENDER_REQUIRED', 'SUPERVISOR_REQUIRED'),
  'an edit of a GRN with no sender or supervisor is accepted: ' || :'edited');
SELECT pg_temp.s_assert((SELECT sender_name IS NULL AND supervisor_id IS NULL AND note = 'Edited without sender or supervisor' FROM public.goodsreceived WHERE gr_no = 'S231E'),
  'the edit saved and the empty fields stayed empty');

-- ===== fas-sync's exemption (rework 1): only the sender check, only on fas-sync's own path =====
SELECT pg_temp.s_assert(coalesce(current_setting('fas.session', true), '') = '' AND session_user = 'supabase_admin', 'no mark is set before this part; the login is supabase_admin');
SELECT count(*) AS grn_x FROM public.goodsreceived \gset
SELECT count(*) AS line_x FROM public.goodsreceived_trl \gset
SELECT count(*) AS key_x FROM public.idempotency_keys \gset
-- Refused: no mark on the superuser's connection (sender '' or NULL), the mark with the API's login, a blank or white-space mark.
SELECT pg_temp.s_save_as('plain', 'S231F', :'cust'::uuid, :'cumin'::uuid, '', true, 'Fixture Supervisor', 'wh231-f') AS plain_empty \gset
SELECT pg_temp.s_save_as('plain', 'S231F', :'cust'::uuid, :'cumin'::uuid, NULL, true, 'Fixture Supervisor', 'wh231-f') AS plain_null \gset
SELECT pg_temp.s_save_as('api', 'S231F', :'cust'::uuid, :'cumin'::uuid, '', true, 'Fixture Supervisor', 'wh231-f') AS api_empty \gset
SELECT pg_temp.s_save_as('api', 'S231F', :'cust'::uuid, :'cumin'::uuid, NULL, true, 'Fixture Supervisor', 'wh231-f') AS api_null \gset
SELECT pg_temp.s_save_as('mark:', 'S231F', :'cust'::uuid, :'cumin'::uuid, '', true, 'Fixture Supervisor', 'wh231-f') AS mark_empty \gset
SELECT pg_temp.s_save_as(E'mark:  ', 'S231F', :'cust'::uuid, :'cumin'::uuid, '', true, 'Fixture Supervisor', 'wh231-f') AS mark_spaces \gset
SELECT pg_temp.s_save_as(E'mark:\t  ', 'S231F', :'cust'::uuid, :'cumin'::uuid, '', true, 'Fixture Supervisor', 'wh231-f') AS mark_tab_nbsp \gset
SELECT pg_temp.s_assert(:'plain_empty'::jsonb->>'reason' = 'SENDER_REQUIRED' AND :'plain_empty'::jsonb->>'success' = 'false', 'no mark, sender empty: refused: ' || :'plain_empty');
SELECT pg_temp.s_assert(:'plain_null'::jsonb->>'reason' = 'SENDER_REQUIRED' AND :'plain_null'::jsonb->>'success' = 'false', 'no mark, sender NULL: refused: ' || :'plain_null');
SELECT pg_temp.s_assert(:'api_empty'::jsonb->>'reason' = 'SENDER_REQUIRED' AND :'api_empty'::jsonb->>'success' = 'false'
  AND :'api_empty'::jsonb->>'error_code' = 'WH409', 'the mark with the API login, sender empty: refused: ' || :'api_empty');
SELECT pg_temp.s_assert(:'api_null'::jsonb->>'reason' = 'SENDER_REQUIRED' AND :'api_null'::jsonb->>'success' = 'false', 'the mark with the API login, sender NULL: refused: ' || :'api_null');
SELECT pg_temp.s_assert(:'mark_empty'::jsonb->>'reason' = 'SENDER_REQUIRED', 'an empty mark does not exempt: ' || :'mark_empty');
SELECT pg_temp.s_assert(:'mark_spaces'::jsonb->>'reason' = 'SENDER_REQUIRED', 'a white-space mark does not exempt: ' || :'mark_spaces');
SELECT pg_temp.s_assert(:'mark_tab_nbsp'::jsonb->>'reason' = 'SENDER_REQUIRED', 'a tab and non-breaking-space mark does not exempt: ' || :'mark_tab_nbsp');
SELECT pg_temp.s_assert((SELECT count(*) FROM public.goodsreceived) = :grn_x AND (SELECT count(*) FROM public.goodsreceived_trl) = :line_x
  AND (SELECT count(*) FROM public.idempotency_keys) = :key_x AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no = 'S231F'),
  'the refused calls wrote no GRN, no line and no request key');
-- fas-sync's path: the same number and key save now (neither was used up), with the sender empty.
SELECT pg_temp.s_save_as('fas', 'S231F', :'cust'::uuid, :'cumin'::uuid, '', true, 'Fixture Supervisor', 'wh231-f') AS fas_empty \gset
SELECT pg_temp.s_save_as('fas', 'S231G', :'cust'::uuid, :'cumin'::uuid, NULL, true, 'Fixture Supervisor', 'wh231-g') AS fas_null \gset
SELECT pg_temp.s_save_as('fas', 'S231H', :'cust'::uuid, :'cumin'::uuid, E'  \t ', true, 'Fixture Supervisor', 'wh231-h') AS fas_spaces \gset
SELECT pg_temp.s_assert(:'fas_empty'::jsonb->>'success' = 'true' AND :'fas_null'::jsonb->>'success' = 'true' AND :'fas_spaces'::jsonb->>'success' = 'true',
  'fas-sync''s path saves a new GRN with a blank sender: ' || :'fas_empty' || :'fas_null' || :'fas_spaces');
SELECT pg_temp.s_assert((SELECT sender_name IS NULL OR btrim(sender_name, E' \t\r\n ') = '' FROM public.goodsreceived WHERE gr_no = 'S231F')
  AND (SELECT sender_name IS NULL FROM public.goodsreceived WHERE gr_no = 'S231G')
  AND (SELECT sender_name IS NULL OR btrim(sender_name, E' \t\r\n ') = '' FROM public.goodsreceived WHERE gr_no = 'S231H')
  AND (SELECT count(*) FROM public.goodsreceived WHERE gr_no IN ('S231F', 'S231G', 'S231H')) = 3
  AND (SELECT count(*) FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no IN ('S231F', 'S231G', 'S231H')) = 3
  AND (SELECT bool_and(supervisor_name = 'Fixture Supervisor' AND supervisor_id IS NOT NULL) FROM public.goodsreceived WHERE gr_no IN ('S231F', 'S231G', 'S231H')),
  'the fas-sync GRNs are stored with the sender empty, each with its line and its supervisor');
-- The supervisor check has no exemption: on fas-sync's path a missing id or a blank name is refused, and nothing is saved.
SELECT pg_temp.s_save_as('fas', 'S231I', :'cust'::uuid, :'cumin'::uuid, '', false, 'Fixture Supervisor', 'wh231-i') AS fas_nosup \gset
SELECT pg_temp.s_save_as('fas', 'S231I', :'cust'::uuid, :'cumin'::uuid, '', true, '  ', 'wh231-i') AS fas_blanksup \gset
SELECT pg_temp.s_save_as('fas', 'S231I', :'cust'::uuid, :'cumin'::uuid, '', false, NULL, 'wh231-i') AS fas_neither \gset
SELECT pg_temp.s_save_as('fas', 'S231I', :'cust'::uuid, :'cumin'::uuid, 'Fixture Sender', false, 'Fixture Supervisor', 'wh231-i') AS fas_nosup_sender \gset
SELECT pg_temp.s_save_as('plain', 'S231I', :'cust'::uuid, :'cumin'::uuid, '', false, 'Fixture Supervisor', 'wh231-i') AS plain_nosup \gset
SELECT pg_temp.s_assert(:'fas_nosup'::jsonb->>'reason' = 'SUPERVISOR_REQUIRED' AND :'fas_nosup'::jsonb->>'success' = 'false'
  AND :'fas_nosup'::jsonb->>'message' = 'Supervisor is required', 'fas-sync''s path, blank sender, no supervisor id: SUPERVISOR_REQUIRED: ' || :'fas_nosup');
SELECT pg_temp.s_assert(:'fas_blanksup'::jsonb->>'reason' = 'SUPERVISOR_REQUIRED' AND :'fas_blanksup'::jsonb->>'success' = 'false', 'fas-sync''s path, blank supervisor name: ' || :'fas_blanksup');
SELECT pg_temp.s_assert(:'fas_neither'::jsonb->>'reason' = 'SUPERVISOR_REQUIRED', 'fas-sync''s path, no sender and no supervisor: the supervisor is refused: ' || :'fas_neither');
SELECT pg_temp.s_assert(:'fas_nosup_sender'::jsonb->>'reason' = 'SUPERVISOR_REQUIRED', 'fas-sync''s path, sender given, no supervisor id: ' || :'fas_nosup_sender');
SELECT pg_temp.s_assert(:'plain_nosup'::jsonb->>'reason' = 'SENDER_REQUIRED', 'no mark: the sender is still named first: ' || :'plain_nosup');
SELECT pg_temp.s_assert(NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no = 'S231I')
  AND (SELECT count(*) FROM public.goodsreceived) = :grn_x + 3 AND (SELECT count(*) FROM public.goodsreceived_trl) = :line_x + 3
  AND (SELECT count(*) FROM public.idempotency_keys) = :key_x + 3, 'the supervisor refusals wrote nothing');
-- A filled sender on fas-sync's path and with the API login saves as before.
SELECT pg_temp.s_save_as('fas', 'S231J', :'cust'::uuid, :'cumin'::uuid, 'Fixture Sender', true, 'Fixture Supervisor', 'wh231-j') AS fas_full \gset
SELECT pg_temp.s_save_as('api', 'S231K', :'cust'::uuid, :'cumin'::uuid, 'Fixture Sender', true, 'Fixture Supervisor', 'wh231-k') AS api_full \gset
SELECT pg_temp.s_assert(:'fas_full'::jsonb->>'success' = 'true' AND :'api_full'::jsonb->>'success' = 'true', 'a full GRN still saves on both paths: ' || :'fas_full' || :'api_full');
-- The marks did not outlive their calls: a blank sender is refused again.
SELECT pg_temp.s_assert(coalesce(current_setting('fas.session', true), '') = '', 'no mark is left set after this part');
SET LOCAL ROLE authenticated;
SELECT pg_temp.s_save('S231L', :'cust'::uuid, :'cumin'::uuid, NULL, true, 'Fixture Supervisor', 'wh231-l') AS after_marks \gset
RESET ROLE;
SELECT pg_temp.s_assert(:'after_marks'::jsonb->>'reason' = 'SENDER_REQUIRED', 'after the marked calls a blank sender is refused again: ' || :'after_marks');

-- The history import writes the tables itself and never goes through save_grn (its loading is run by import_past_years_180.sql).
SELECT pg_temp.s_assert(position('save_grn' IN pg_get_functiondef('public.import_history(jsonb, boolean)'::regprocedure)) = 0, 'import_history does not call save_grn');
ROLLBACK;
\echo 'GRN sender and supervisor required (WH-231, with the fas-sync exemption) checks passed.'
