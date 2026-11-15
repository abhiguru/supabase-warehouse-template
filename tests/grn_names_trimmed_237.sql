-- WH-237: a GRN's sender name and supervisor name are stored without white space at either end (spaces, tab, line break, non-breaking and
--   zero-width space; white space inside is kept), and a name that is empty or only white space is stored as NULL, on save_grn and on update_grn.
--   A name that is not sent is not rewritten. update_grn's answer shows the stored values. WH-233's one case that changed: a name that differs
--   from the stored one only by white space at its ends is not a change of the supervisor.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.t_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'grn names trimmed: %', label; END IF; END $$;
CREATE FUNCTION pg_temp.t_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  login := public.operator_verify_otp(phone, challenge#>>'{data,otp_code}');
  PERFORM pg_temp.t_assert(login#>>'{data,action}' = 'login', 'login ' || phone);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- A new GRN through save_grn; mode fas = fas-sync's path (the mark set, so a blank sender is allowed), plain = no mark. Expects the stored values exactly.
CREATE FUNCTION pg_temp.t_save(p_label text, p_mode text, p_no text, p_cust uuid, p_item uuid, p_sid uuid, p_sender text, p_sname text,
                               p_e_sender text, p_e_sname text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_res jsonb; g public.goodsreceived;
BEGIN
  PERFORM set_config('fas.session', CASE WHEN p_mode = 'fas' THEN gen_random_uuid()::text ELSE '' END, true);
  SET LOCAL ROLE authenticated;
  v_res := public.save_grn(p_gr_no => p_no, p_date => '2026-04-01T12:00:00Z', p_customer_id => p_cust, p_customer_name => 'Trim Rule Customer',
    p_sender_name => p_sender, p_supervisor_id => p_sid, p_supervisor_name => p_sname, p_pricing_mode => 'MONTHLY', p_idempotency_key => 'wh237-' || p_no,
    p_items => jsonb_build_array(jsonb_build_object('item_id', p_item, 'item_name', 'Trim Rule Cumin', 'packaging', 'Bag', 'qty', 2, 'weight', 10)));
  RESET ROLE;
  PERFORM set_config('fas.session', '', true);
  PERFORM pg_temp.t_assert(v_res->>'success' = 'true', p_label || ': saves: ' || v_res);
  SELECT * INTO g FROM public.goodsreceived x WHERE x.gr_no = p_no;
  PERFORM pg_temp.t_assert(g.sender_name IS NOT DISTINCT FROM p_e_sender AND g.supervisor_name IS NOT DISTINCT FROM p_e_sname,
    p_label || ': stored sender [' || COALESCE(g.sender_name, '<NULL>') || '] supervisor [' || COALESCE(g.supervisor_name, '<NULL>') || ']');
END $$;
-- One edit through update_grn with only the names (NULL = not sent). Expects success, the stored values exactly, and the answer showing the same.
CREATE FUNCTION pg_temp.t_edit(p_label text, p_state_sender text, p_state_sid uuid, p_state_sname text, p_sender text, p_sid uuid, p_sname text,
                               p_e_sender text, p_e_sid uuid, p_e_sname text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_lines jsonb; v_res jsonb; g public.goodsreceived;
BEGIN
  UPDATE public.goodsreceived SET sender_name = p_state_sender, supervisor_id = p_state_sid, supervisor_name = p_state_sname WHERE gr_no = 'T237';
  SELECT x.id INTO v_id FROM public.goodsreceived x WHERE x.gr_no = 'T237';
  SELECT jsonb_agg(jsonb_build_object('id', t.id, 'item_id', t.item_id, 'item_name', t.item_name, 'packaging', t.packaging, 'qty', t.qty, 'weight', t.weight) ORDER BY t.id)
    INTO v_lines FROM public.goodsreceived_trl t WHERE t.gr_id = v_id;
  SET LOCAL ROLE authenticated;
  v_res := public.update_grn(p_grn_id => v_id, p_sender_name => p_sender, p_supervisor_id => p_sid, p_supervisor_name => p_sname, p_items => v_lines);
  RESET ROLE;
  PERFORM pg_temp.t_assert(v_res->>'success' = 'true', p_label || ': saves: ' || v_res);
  SELECT * INTO g FROM public.goodsreceived x WHERE x.id = v_id;
  PERFORM pg_temp.t_assert(g.sender_name IS NOT DISTINCT FROM p_e_sender AND g.supervisor_id IS NOT DISTINCT FROM p_e_sid
    AND g.supervisor_name IS NOT DISTINCT FROM p_e_sname,
    p_label || ': stored sender [' || COALESCE(g.sender_name, '<NULL>') || '] supervisor [' || COALESCE(g.supervisor_name, '<NULL>') || ']');
  PERFORM pg_temp.t_assert(v_res #>> '{grn,sender_name}' IS NOT DISTINCT FROM p_e_sender AND v_res #>> '{grn,supervisor_name}' IS NOT DISTINCT FROM p_e_sname,
    p_label || ': the answer shows the stored values: ' || (v_res->'grn')::text);
END $$;

INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888887431', 'Trim Rule Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888887432', 'Trim Rule Supervisor One', 'supervisor', true, 'approved');
SELECT id AS p1 FROM public.user_profiles WHERE mobile = '919888887432' \gset
SELECT pg_temp.t_login('9888887431') AS admin_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Trim Rule Customer', '9888887434') RETURNING id AS cust \gset
INSERT INTO public.items(name, packaging) VALUES ('Trim Rule Cumin', 'Bag') RETURNING id AS cumin \gset
SELECT set_config('request.jwt.claims', :'admin_claims', true);

-- ===== save_grn: a new GRN =====
SELECT pg_temp.t_save('new: spaces around both names', 'plain', 'N1', :'cust'::uuid, :'cumin'::uuid, :'p1'::uuid, '  Ramesh  ', '  Suresh  ', 'Ramesh', 'Suresh');
SELECT pg_temp.t_save('new: inner spaces kept', 'plain', 'N2', :'cust'::uuid, :'cumin'::uuid, :'p1'::uuid, 'Ramesh  Patel', 'Suresh   Shah', 'Ramesh  Patel', 'Suresh   Shah');
SELECT pg_temp.t_save('new: tab and line break at the ends', 'plain', 'N3', :'cust'::uuid, :'cumin'::uuid, :'p1'::uuid, E'\tRamesh\n', E'\r\nSuresh\t', 'Ramesh', 'Suresh');
SELECT pg_temp.t_save('new: non-breaking space at the ends', 'plain', 'N4', :'cust'::uuid, :'cumin'::uuid, :'p1'::uuid, E' Ramesh  ', E' Suresh', 'Ramesh', 'Suresh');
SELECT pg_temp.t_save('new: zero-width space at the ends', 'plain', 'N5', :'cust'::uuid, :'cumin'::uuid, :'p1'::uuid, E'​Ramesh​', E'​ Suresh ​', 'Ramesh', 'Suresh');
SELECT pg_temp.t_save('new: mixed white space around, inner kept', 'plain', 'N6', :'cust'::uuid, :'cumin'::uuid, :'p1'::uuid, E' \t Ramesh ​ Patel\n ', 'Suresh', 'Ramesh ​ Patel', 'Suresh');
-- On fas-sync's path a blank sender is stored as NULL, never '' or white space.
SELECT pg_temp.t_save('new on fas-sync''s path: sender empty', 'fas', 'N7', :'cust'::uuid, :'cumin'::uuid, :'p1'::uuid, '', 'Suresh', NULL, 'Suresh');
SELECT pg_temp.t_save('new on fas-sync''s path: sender spaces', 'fas', 'N8', :'cust'::uuid, :'cumin'::uuid, :'p1'::uuid, E'  \t ', '  Suresh ', NULL, 'Suresh');
SELECT pg_temp.t_save('new on fas-sync''s path: sender NULL', 'fas', 'N9', :'cust'::uuid, :'cumin'::uuid, :'p1'::uuid, NULL, 'Suresh', NULL, 'Suresh');
SELECT pg_temp.t_save('new on fas-sync''s path: sender non-breaking and zero-width spaces only', 'fas', 'N10', :'cust'::uuid, :'cumin'::uuid, :'p1'::uuid, E' ​', 'Suresh', NULL, 'Suresh');
-- The WH-231 refusals are as before after the trimming: a blank supervisor name is still refused.
SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'N11', p_date=>'2026-04-01T12:00:00Z', p_customer_id=>:'cust'::uuid, p_customer_name=>'Trim Rule Customer', p_sender_name=>'Ramesh',
  p_supervisor_id=>:'p1'::uuid, p_supervisor_name=>E'​ \t', p_pricing_mode=>'MONTHLY', p_idempotency_key=>'wh237-N11',
  p_items=>jsonb_build_array(jsonb_build_object('item_id', :'cumin'::uuid, 'item_name', 'Trim Rule Cumin', 'packaging', 'Bag', 'qty', 2, 'weight', 10))) AS blank_sup \gset
RESET ROLE;
SELECT pg_temp.t_assert(:'blank_sup'::jsonb->>'reason' = 'SUPERVISOR_REQUIRED' AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no = 'N11'), 'a supervisor name of white space only is refused: ' || :'blank_sup');

-- ===== update_grn =====
-- One GRN to edit (made the normal way); each case sets the stored state first with a direct UPDATE.
SELECT pg_temp.t_save('the GRN to edit', 'plain', 'T237', :'cust'::uuid, :'cumin'::uuid, :'p1'::uuid, 'Orig Sender', 'Orig Sup', 'Orig Sender', 'Orig Sup');
SELECT pg_temp.t_edit('edit: spaces around both names', 'Orig Sender', :'p1'::uuid, 'Orig Sup', '  Ramesh  ', NULL, '  Suresh  ', 'Ramesh', :'p1'::uuid, 'Suresh');
SELECT pg_temp.t_edit('edit: inner spaces kept', 'Orig Sender', :'p1'::uuid, 'Orig Sup', 'Ramesh  Patel', NULL, 'Suresh   Shah', 'Ramesh  Patel', :'p1'::uuid, 'Suresh   Shah');
SELECT pg_temp.t_edit('edit: tab and line break', 'Orig Sender', :'p1'::uuid, 'Orig Sup', E'\tRamesh\n', NULL, E'\r\nSuresh\t', 'Ramesh', :'p1'::uuid, 'Suresh');
SELECT pg_temp.t_edit('edit: non-breaking space', 'Orig Sender', :'p1'::uuid, 'Orig Sup', E' Ramesh ', NULL, E' Suresh  ', 'Ramesh', :'p1'::uuid, 'Suresh');
SELECT pg_temp.t_edit('edit: zero-width space', 'Orig Sender', :'p1'::uuid, 'Orig Sup', E'​Ramesh​', NULL, E'​ Suresh​', 'Ramesh', :'p1'::uuid, 'Suresh');
SELECT pg_temp.t_edit('edit: a new id with a padded name', 'Orig Sender', NULL, 'Orig Sup', NULL, :'p1'::uuid, E'  Suresh Shah\t', 'Orig Sender', :'p1'::uuid, 'Suresh Shah');
-- An empty sender: sending '' or white space saves and the sender is NULL (for a NULL, an '' and a white-space stored value alike).
SELECT pg_temp.t_edit('edit: NULL sender, sent empty', NULL, :'p1'::uuid, 'Orig Sup', '', NULL, NULL, NULL, :'p1'::uuid, 'Orig Sup');
SELECT pg_temp.t_edit('edit: NULL sender, sent white space', NULL, :'p1'::uuid, 'Orig Sup', E'  \t ​ ', NULL, NULL, NULL, :'p1'::uuid, 'Orig Sup');
SELECT pg_temp.t_edit('edit: empty-string sender, sent empty', '', :'p1'::uuid, 'Orig Sup', '', NULL, NULL, NULL, :'p1'::uuid, 'Orig Sup');
SELECT pg_temp.t_edit('edit: white-space sender, sent white space', E'   ', :'p1'::uuid, 'Orig Sup', E' \t ', NULL, NULL, NULL, :'p1'::uuid, 'Orig Sup');
SELECT pg_temp.t_edit('edit: NULL sender filled with a padded name', NULL, :'p1'::uuid, 'Orig Sup', '  Now Filled ', NULL, NULL, 'Now Filled', :'p1'::uuid, 'Orig Sup');
-- An empty supervisor (no id, no name): a blank name sent is NULL.
SELECT pg_temp.t_edit('edit: both empty, empty name sent', 'Orig Sender', NULL, NULL, NULL, NULL, '', 'Orig Sender', NULL, NULL);
SELECT pg_temp.t_edit('edit: both empty, white-space name sent', 'Orig Sender', NULL, NULL, NULL, NULL, E' \t  ', 'Orig Sender', NULL, NULL);
SELECT pg_temp.t_edit('edit: id without a name, empty name sent', 'Orig Sender', :'p1'::uuid, NULL, NULL, :'p1'::uuid, '', 'Orig Sender', :'p1'::uuid, NULL);
-- A name that is not sent is left byte for byte as stored, even with white space at its ends (and the other name is trimmed as sent).
SELECT pg_temp.t_edit('edit: stored padded names, nothing sent', E'  Padded Sender \t', :'p1'::uuid, E'  Padded Sup\n', NULL, NULL, NULL, E'  Padded Sender \t', :'p1'::uuid, E'  Padded Sup\n');
SELECT pg_temp.t_edit('edit: stored padded names, only the sender sent', E'  Padded Sender \t', :'p1'::uuid, E'  Padded Sup\n', ' New ', NULL, NULL, 'New', :'p1'::uuid, E'  Padded Sup\n');
SELECT pg_temp.t_edit('edit: stored padded names, only the supervisor name sent', E'  Padded Sender \t', :'p1'::uuid, E'  Padded Sup\n', NULL, NULL, ' New Sup ', E'  Padded Sender \t', :'p1'::uuid, 'New Sup');
-- The one refusal that now saves (WH-233's rule): a name with no id, sent with only white space added or removed at its ends, is no change.
SELECT pg_temp.t_edit('name only: the same name padded', 'Orig Sender', NULL, 'Suresh', NULL, NULL, '  Suresh  ', 'Orig Sender', NULL, 'Suresh');
SELECT pg_temp.t_edit('name only: the same name padded with tab and non-breaking space', 'Orig Sender', NULL, 'Suresh', NULL, NULL, E'\tSuresh ', 'Orig Sender', NULL, 'Suresh');
SELECT pg_temp.t_edit('name only (stored padded): the same name trimmed', 'Orig Sender', NULL, '  Suresh ', NULL, NULL, 'Suresh', 'Orig Sender', NULL, 'Suresh');
-- ...while a different name, or an empty one, on a name-only supervisor is still refused (WH-233), and the stored values stay.
UPDATE public.goodsreceived SET sender_name = 'Orig Sender', supervisor_id = NULL, supervisor_name = 'Suresh' WHERE gr_no = 'T237';
SELECT id AS t_id FROM public.goodsreceived WHERE gr_no = 'T237' \gset
SELECT jsonb_agg(jsonb_build_object('id', t.id, 'item_id', t.item_id, 'item_name', t.item_name, 'packaging', t.packaging, 'qty', t.qty, 'weight', t.weight) ORDER BY t.id) AS t_lines
  FROM public.goodsreceived_trl t WHERE t.gr_id = :'t_id'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'t_id'::uuid, p_supervisor_name=>'  Other  ', p_items=>:'t_lines'::jsonb) AS other_name \gset
SELECT public.update_grn(p_grn_id=>:'t_id'::uuid, p_supervisor_name=>E'  ​ ', p_items=>:'t_lines'::jsonb) AS empty_name \gset
RESET ROLE;
SELECT pg_temp.t_assert(:'other_name'::jsonb->>'reason' = 'SUPERVISOR_REQUIRED' AND :'empty_name'::jsonb->>'reason' = 'SUPERVISOR_REQUIRED'
  AND (SELECT supervisor_name = 'Suresh' AND supervisor_id IS NULL FROM public.goodsreceived WHERE gr_no = 'T237'), 'another name, or an empty one, on a name-only supervisor is still refused: ' || :'other_name' || :'empty_name');
-- A filled sender sent as white space is still refused (WH-233) and stays as stored.
UPDATE public.goodsreceived SET supervisor_id = :'p1'::uuid WHERE gr_no = 'T237';
SET LOCAL ROLE authenticated;
SELECT public.update_grn(p_grn_id=>:'t_id'::uuid, p_sender_name=>E' ​ ', p_items=>:'t_lines'::jsonb) AS blank_sender \gset
RESET ROLE;
SELECT pg_temp.t_assert(:'blank_sender'::jsonb->>'reason' = 'SENDER_REQUIRED' AND (SELECT sender_name = 'Orig Sender' FROM public.goodsreceived WHERE gr_no = 'T237'),
  'a filled sender sent as white space is refused: ' || :'blank_sender');
ROLLBACK;
\echo 'GRN names trimmed and stored as NULL when blank (WH-237) checks passed.'
