-- WH-250, WH-251: what counts as a save "that changes only the rates" for an ordinary (not imported) GRN with an empty sender or supervisor
-- (warehouse_security.grn_save_keeps_stored, p_strict true, asked by update_grn; tests/grn_edit_requires_sender_supervisor_248.sql holds the
-- rule itself). A save with p_rates is held to the rule only if nothing update_grn would write differs from what is stored, where two values are
-- the same if the server stores or reads them alike.
--   SAME (accepted, rates stored): another time on the same India day; '' for a stored NULL note, packaging, rack or package mark; false for a
--     stored empty leon; a stored sender or supervisor name of only tabs, non-breaking or zero-width spaces sent back trimmed; a stored NULL
--     pricing mode against the sent MONTHLY.
--   CHANGE (refused SENDER_REQUIRED / SUPERVISOR_REQUIRED; the row, the lines and the rates unchanged): a package mark that would be cleared
--     (only packageMark sent), another India day, spaces at an end of an item name, packaging or rack, 0 (or nothing) for a stored empty line
--     weight, true for an empty leon, ONE_TIME against a stored NULL pricing mode.
--   An imported GRN keeps migration 190's comparison (warehouse_security.update_imported_grn_rates): its rates save still passes with values
--     the strict comparison refuses, and any other change is still IMPORTED_READ_ONLY.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.r_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'grn rates-only strict: %', label; END IF; END $$;
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
-- Put R250 in a stored state: the header (sender, supervisor id and name, date, note, leon, pricing mode) and its one line (packaging, rack, mark, weight).
CREATE FUNCTION pg_temp.r_state(p_sender text, p_sid uuid, p_sname text, p_date timestamptz DEFAULT '2026-04-01T12:00:00Z', p_note text DEFAULT NULL,
    p_leon boolean DEFAULT NULL, p_pricing text DEFAULT 'MONTHLY', p_packaging text DEFAULT 'Bag', p_rack text DEFAULT NULL, p_mark text DEFAULT NULL,
    p_weight integer DEFAULT 10) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE public.goodsreceived SET sender_name = p_sender, supervisor_id = p_sid, supervisor_name = p_sname, date = p_date, note = p_note,
    leon = p_leon, pricing_mode = p_pricing WHERE gr_no = 'R250';
  UPDATE public.goodsreceived_trl SET packaging = p_packaging, rack = p_rack, package_mark = p_mark, weight = p_weight
    WHERE gr_id = (SELECT id FROM public.goodsreceived WHERE gr_no = 'R250');
END $$;
-- One rates-only save of R250 (an argument NULL = not sent). The stored line is sent back as stored (snake_case keys, as the app sends it), then
-- p_patch is merged over it and the keys in p_drop are removed. Expect 'ok' (success, and the rates stored) or a refusal reason (WH409, and the
-- row, the lines and the rates identical after it).
CREATE FUNCTION pg_temp.r_try(p_label text, p_expect text, p_date timestamptz DEFAULT NULL, p_note text DEFAULT NULL, p_leon boolean DEFAULT NULL,
    p_pricing text DEFAULT NULL, p_sender text DEFAULT NULL, p_supname text DEFAULT NULL, p_patch jsonb DEFAULT '{}', p_drop text[] DEFAULT '{}')
    RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_line jsonb; v_row jsonb; v_lines jsonb; v_rates jsonb; v_price numeric; v_res jsonb; v_row2 jsonb; v_lines2 jsonb; v_rates2 jsonb;
BEGIN
  SELECT x.id, to_jsonb(x) INTO v_id, v_row FROM public.goodsreceived x WHERE x.gr_no = 'R250';
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.id), '[]') INTO v_lines FROM public.goodsreceived_trl t WHERE t.gr_id = v_id;
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.id), '[]') INTO v_rates FROM public.grn_rates r WHERE r.gr_id = v_id;
  SELECT COALESCE(max(unit_price), 6) + 1 INTO v_price FROM public.grn_rates WHERE gr_id = v_id;
  SELECT jsonb_build_object('id', t.id, 'item_id', t.item_id, 'item_name', t.item_name, 'packaging', t.packaging, 'qty', t.qty, 'weight', t.weight,
                            'rack', t.rack, 'package_mark', t.package_mark) INTO v_line
    FROM public.goodsreceived_trl t WHERE t.gr_id = v_id;
  v_line := (v_line || p_patch) - p_drop;
  SET LOCAL ROLE authenticated;
  v_res := public.update_grn(p_grn_id => v_id, p_date => p_date, p_note => p_note, p_leon => p_leon, p_pricing_mode => p_pricing,
    p_sender_name => p_sender, p_supervisor_name => p_supname, p_items => jsonb_build_array(v_line),
    p_rates => jsonb_build_array(jsonb_build_object('scope', 'grn', 'item_id', v_line->>'item_id', 'weight_min', 0, 'weight_max', 100,
                                                    'unit_price', v_price, 'labour_rate', 1, 'tax_percent', 0)));
  RESET ROLE;
  SELECT to_jsonb(x) INTO v_row2 FROM public.goodsreceived x WHERE x.id = v_id;
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.id), '[]') INTO v_lines2 FROM public.goodsreceived_trl t WHERE t.gr_id = v_id;
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.id), '[]') INTO v_rates2 FROM public.grn_rates r WHERE r.gr_id = v_id;
  IF p_expect = 'ok' THEN
    PERFORM pg_temp.r_assert(v_res->>'success' = 'true', p_label || ': saves: ' || v_res);
    PERFORM pg_temp.r_assert((SELECT count(*) = 1 AND bool_and(unit_price = v_price) FROM public.grn_rates WHERE gr_id = v_id), p_label || ': the new rates are stored');
  ELSE
    PERFORM pg_temp.r_assert(v_res->>'success' = 'false' AND v_res->>'reason' = p_expect AND v_res->>'error_code' = 'WH409', p_label || ': refused with ' || p_expect || ': ' || v_res);
    PERFORM pg_temp.r_assert(v_row2 = v_row AND v_lines2 = v_lines AND v_rates2 = v_rates, p_label || ': the GRN, its lines and its rates are identical after the refusal');
  END IF;
END $$;

INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888887501', 'Strict Rates Administrator');
INSERT INTO public.user_profiles(auth_user_id, mobile, name, role, active, enrollment_status) VALUES
 (gen_random_uuid(), '919888887502', 'Strict Rates Supervisor', 'supervisor', true, 'approved');
SELECT id AS p1 FROM public.user_profiles WHERE mobile = '919888887502' \gset
SELECT pg_temp.r_login('9888887501') AS admin_claims \gset
INSERT INTO public.customers(name, mobile) VALUES ('Strict Rates Customer', '9888887504') RETURNING id AS cust \gset
INSERT INTO public.items(name, packaging) VALUES ('Strict Rates Cumin', 'Bag') RETURNING id AS cumin \gset
SELECT set_config('request.jwt.claims', :'admin_claims', true);

SET LOCAL ROLE authenticated;
SELECT public.save_grn(p_gr_no=>'R250', p_date=>'2026-04-01T12:00:00Z', p_customer_id=>:'cust'::uuid, p_customer_name=>'Strict Rates Customer',
  p_sender_name=>'Orig Sender', p_supervisor_id=>:'p1'::uuid, p_supervisor_name=>'Sup One', p_pricing_mode=>'MONTHLY', p_idempotency_key=>'wh250-save',
  p_items=>jsonb_build_array(jsonb_build_object('item_id', :'cumin'::uuid, 'item_name', 'Strict Rates Cumin', 'packaging', 'Bag', 'qty', 2, 'weight', 10))) AS made \gset
RESET ROLE;
SELECT pg_temp.r_assert(:'made'::jsonb->>'success' = 'true', 'the GRN was saved: ' || :'made');

-- ===== 1. the same: accepted, rates stored (empty sender and supervisor) =====
-- 2026-04-01 12:00 UTC is 17:30 on 1 April in India; 05:00 UTC is 10:30 the same day, 2026-04-02 12:00 UTC is another day.
SELECT pg_temp.r_state(NULL, NULL, NULL);
SELECT pg_temp.r_try('stored as sent, rates only', 'ok');
SELECT pg_temp.r_try('another time on the same India day', 'ok', p_date => '2026-04-01T05:00:00Z');
SELECT pg_temp.r_state(NULL, NULL, NULL, p_date => '2026-03-31T18:30:00Z');                        -- 00:00 on 1 April in India (the older app's midnight)
SELECT pg_temp.r_try('the older app''s stored time, saved as a calendar day (00:00 UTC, same India day)', 'ok', p_date => '2026-04-01T00:00:00Z');
SELECT pg_temp.r_state(NULL, NULL, NULL, p_packaging => NULL);
SELECT pg_temp.r_try('empty note sent for a stored NULL note', 'ok', p_note => '');
SELECT pg_temp.r_try('empty packaging sent for a stored NULL packaging', 'ok', p_patch => '{"packaging": ""}');
SELECT pg_temp.r_try('empty rack sent for a stored NULL rack', 'ok', p_patch => '{"rack": ""}');
SELECT pg_temp.r_try('empty package mark sent for a stored NULL mark', 'ok', p_patch => '{"package_mark": ""}');
SELECT pg_temp.r_state(NULL, NULL, NULL, p_note => '', p_packaging => '', p_rack => '', p_mark => '');
SELECT pg_temp.r_try('nothing sent for a stored empty note, packaging, rack and mark', 'ok', p_patch => '{"packaging": null, "rack": null, "package_mark": null}');
SELECT pg_temp.r_state(NULL, NULL, NULL);
SELECT pg_temp.r_try('false for a stored empty leon', 'ok', p_leon => false);
-- Digits: a mark typed with Gujarati digits is the stored mark with 0-9 (the server stores digits as 0-9).
SELECT pg_temp.r_state(NULL, NULL, NULL, p_rack => 'A12', p_mark => 'M7');
SELECT pg_temp.r_try('a rack with Gujarati digits for the stored 0-9 rack', 'ok', p_patch => jsonb_build_object('rack', 'A' || chr(2791) || chr(2792)));
-- WH-251: a stored name of only tabs, non-breaking or zero-width spaces, sent back trimmed (WH-237's trimming turns it into '').
SELECT pg_temp.r_state(E'\t\t', NULL, NULL);
SELECT pg_temp.r_try('sender of only tabs, sent back trimmed', 'ok', p_sender => '');
SELECT pg_temp.r_state(chr(160) || chr(160), NULL, NULL);
SELECT pg_temp.r_try('sender of only non-breaking spaces, sent back trimmed', 'ok', p_sender => '');
SELECT pg_temp.r_state(chr(8203) || chr(8203), NULL, NULL);
SELECT pg_temp.r_try('sender of only zero-width spaces, sent back trimmed', 'ok', p_sender => '');
SELECT pg_temp.r_state(E'\t\t', NULL, NULL);
SELECT pg_temp.r_try('sender of only tabs, sent back as stored', 'ok', p_sender => E'\t\t');
SELECT pg_temp.r_state('Orig Sender', NULL, E'\t ' || chr(160));
SELECT pg_temp.r_try('supervisor name of tabs and a non-breaking space, sent back trimmed', 'ok', p_supname => '');
SELECT pg_temp.r_state('Orig Sender', NULL, chr(8203));
SELECT pg_temp.r_try('supervisor name of only a zero-width space, sent back trimmed', 'ok', p_supname => '');
-- WH-251: a stored NULL pricing mode against the sent default (the server charges it as MONTHLY); ONE_TIME is another mode.
SELECT pg_temp.r_state(NULL, NULL, NULL, p_pricing => NULL);
SELECT pg_temp.r_try('MONTHLY sent for a stored NULL pricing mode', 'ok', p_pricing => 'MONTHLY');
SELECT pg_temp.r_try('ONE_TIME sent for a stored NULL pricing mode', 'SENDER_REQUIRED', p_pricing => 'ONE_TIME');

-- ===== 2. a change: refused, nothing written (empty sender) =====
SELECT pg_temp.r_state(NULL, NULL, NULL, p_mark => 'M7');
SELECT pg_temp.r_try('only packageMark sent for a stored mark (it would be cleared)', 'SENDER_REQUIRED', p_patch => '{"packageMark": "M7"}', p_drop => '{package_mark}');
SELECT pg_temp.r_try('another India day', 'SENDER_REQUIRED', p_date => '2026-04-02T12:00:00Z');
SELECT pg_temp.r_try('the day before in India (UTC date the same, India day not)', 'SENDER_REQUIRED', p_date => '2026-03-31T18:00:00Z');
SELECT pg_temp.r_try('a space at the end of the item name', 'SENDER_REQUIRED', p_patch => '{"item_name": "Strict Rates Cumin "}');
SELECT pg_temp.r_try('a space at the start of the item name', 'SENDER_REQUIRED', p_patch => '{"item_name": " Strict Rates Cumin"}');
SELECT pg_temp.r_try('a space at the end of the packaging', 'SENDER_REQUIRED', p_patch => '{"packaging": "Bag "}');
SELECT pg_temp.r_state(NULL, NULL, NULL, p_rack => 'A12');
SELECT pg_temp.r_try('a space at the end of the rack', 'SENDER_REQUIRED', p_patch => '{"rack": "A12 "}');
SELECT pg_temp.r_try('true for a stored empty leon', 'SENDER_REQUIRED', p_leon => true);
SELECT pg_temp.r_state(NULL, NULL, NULL, p_weight => NULL);
SELECT pg_temp.r_try('0 for a stored empty line weight', 'SENDER_REQUIRED', p_patch => '{"weight": 0}');
SELECT pg_temp.r_try('nothing for a stored empty line weight', 'SENDER_REQUIRED', p_drop => '{weight}');
SELECT pg_temp.r_try('a note for a stored NULL note', 'SENDER_REQUIRED', p_note => 'A new note');

-- ===== 3. the same rule on the supervisor side (sender filled, supervisor empty) =====
SELECT pg_temp.r_state('Orig Sender', NULL, NULL, p_mark => 'M7');
SELECT pg_temp.r_try('supervisor empty: only packageMark sent', 'SUPERVISOR_REQUIRED', p_patch => '{"packageMark": "M7"}', p_drop => '{package_mark}');
SELECT pg_temp.r_try('supervisor empty: another India day', 'SUPERVISOR_REQUIRED', p_date => '2026-04-02T12:00:00Z');
SELECT pg_temp.r_try('supervisor empty: a space at the end of the item name', 'SUPERVISOR_REQUIRED', p_patch => '{"item_name": "Strict Rates Cumin "}');
SELECT pg_temp.r_try('supervisor empty: another time on the same India day', 'ok', p_date => '2026-04-01T05:00:00Z');
SELECT pg_temp.r_state('Orig Sender', NULL, NULL, p_leon => NULL);
SELECT pg_temp.r_try('supervisor empty: false for a stored empty leon', 'ok', p_leon => false);

-- ===== 4. an imported GRN's rates save behaves as before (migration 190's comparison, not the strict one) =====
SELECT pg_temp.r_assert((SELECT count(*) FROM warehouse_import.stage_grns) = 0, 'no staged rows before this part');
INSERT INTO warehouse_import.stage_grns(line, gr_no, gr_date, customer, pricing, sender) VALUES (2, 'A0901', '2023-05-05', 'Strict Rates Customer', 'MONTHLY', 'Given Sender');
INSERT INTO warehouse_import.stage_grn_lines(line, gr_no, gr_date, line_no, item, packaging, qty, weight, stock_now) VALUES
 (2, 'A0901', '2023-05-05', 1, 'Strict Rates Cumin', 'Bag', 10, 50, 10);
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SET LOCAL ROLE service_role;
SELECT public.import_history('{}'::jsonb, true) AS imported \gset
RESET ROLE;
SELECT pg_temp.r_assert(:'imported'::jsonb->>'success' = 'true' AND :'imported'::jsonb->>'applied' = 'true', 'the import applies: ' || :'imported');
SELECT id AS ig FROM public.goodsreceived WHERE gr_no = 'A0901' AND import_batch_id IS NOT NULL \gset
SELECT set_config('request.jwt.claims', :'admin_claims', true);
-- p_rates, p_items as stored but item name with a space at an end and the packageMark fallback key: migration 190's comparison accepts both.
CREATE FUNCTION pg_temp.r_imp(p_label text, p_note text, p_patch jsonb, p_drop text[], p_price numeric) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_line jsonb; v_res jsonb;
BEGIN
  SELECT jsonb_build_object('id', t.id, 'item_id', t.item_id, 'item_name', t.item_name, 'packaging', t.packaging, 'qty', t.qty, 'weight', t.weight,
                            'rack', t.rack, 'package_mark', t.package_mark) INTO v_line
    FROM public.goodsreceived_trl t WHERE t.gr_id = (SELECT id FROM public.goodsreceived WHERE gr_no = 'A0901');
  v_line := (v_line || p_patch) - p_drop;
  SET LOCAL ROLE authenticated;
  v_res := public.update_grn(p_grn_id => (SELECT id FROM public.goodsreceived WHERE gr_no = 'A0901'), p_note => p_note, p_items => jsonb_build_array(v_line),
    p_rates => jsonb_build_array(jsonb_build_object('scope', 'grn', 'item_id', v_line->>'item_id', 'weight_min', 0, 'weight_max', 100,
                                                    'unit_price', p_price, 'labour_rate', 1, 'tax_percent', 0)));
  RESET ROLE;
  RETURN v_res;
END $$;
SELECT pg_temp.r_imp('imported: as stored', NULL, '{}', '{}', 11) AS imp1 \gset
SELECT pg_temp.r_assert(:'imp1'::jsonb->>'success' = 'true', 'imported GRN, rates only as stored: saves: ' || :'imp1');
SELECT pg_temp.r_assert((SELECT count(*) = 1 AND bool_and(unit_price = 11) FROM public.grn_rates WHERE gr_id = :'ig'::uuid), 'imported GRN: the rates were stored');
SELECT pg_temp.r_imp('imported: space at the end of the item name', NULL, '{"item_name": "Strict Rates Cumin "}', '{}', 12) AS imp2 \gset
SELECT pg_temp.r_assert(:'imp2'::jsonb->>'success' = 'true', 'imported GRN, a space at the end of the item name is still accepted (migration 190): ' || :'imp2');
SELECT pg_temp.r_imp('imported: packageMark fallback', NULL, '{"packageMark": ""}', '{package_mark}', 13) AS imp3 \gset
SELECT pg_temp.r_assert(:'imp3'::jsonb->>'success' = 'true', 'imported GRN, the packageMark fallback is still accepted (migration 190): ' || :'imp3');
SELECT pg_temp.r_assert((SELECT count(*) = 1 AND bool_and(unit_price = 13) FROM public.grn_rates WHERE gr_id = :'ig'::uuid), 'imported GRN: the last rates were stored');
SELECT pg_temp.r_imp('imported: a note', 'A new note', '{}', '{}', 14) AS imp4 \gset
SELECT pg_temp.r_assert(:'imp4'::jsonb->>'success' = 'false' AND :'imp4'::jsonb->>'reason' = 'IMPORTED_READ_ONLY', 'imported GRN, a note change is still IMPORTED_READ_ONLY: ' || :'imp4');
SELECT pg_temp.r_assert((SELECT note IS NULL FROM public.goodsreceived WHERE id = :'ig'::uuid)
  AND (SELECT count(*) = 1 AND bool_and(unit_price = 13) FROM public.grn_rates WHERE gr_id = :'ig'::uuid), 'imported GRN: the refused note change wrote nothing');
ROLLBACK;
\echo 'GRN rates-only save compares what update_grn would write (WH-250, WH-251) checks passed.'
