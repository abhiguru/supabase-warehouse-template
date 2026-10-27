-- Migration 127: the numbering rule of each document type (warehouse_security.document_numbering). The tables and their grants, the
-- columns of 20 characters, each scheme's suggestion (letters from A and from X, financial year, sequence, free), the invoice
-- options, the refusal of a number outside the rule by the GRN save, the dispatch save and the dispatch edit, FAS-style numbers, who may
-- read and change a rule, the history, and a race between two suggestions. Fictional data; runs only in migrations.sh's disposable,
-- network-disabled database (session time zone UTC). Every fixture row, and every rule change, rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.nd_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'document numbering: %',label; END IF; END $$;
-- The text answer of a statement, or what it raised.
CREATE FUNCTION pg_temp.nd_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer text;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN jsonb_build_object('answer', answer);
END $$;
CREATE FUNCTION pg_temp.nd_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.nd_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.nd_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
-- The next number (or its reason) of the rule in force, for a type and a day, as the owner reads it.
CREATE FUNCTION pg_temp.nd_next(p_type text, p_day date DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE(s->>'number', s->>'reason') FROM (SELECT warehouse_security.document_number_suggestion(p_type, p_day) AS s) x $$;
CREATE FUNCTION pg_temp.nd_rule(p_type text, p_rule jsonb) RETURNS jsonb LANGUAGE sql AS $$
  SELECT warehouse_security.apply_document_numbering(p_type, p_rule, NULL) $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888811','Numbering Administrator') AS admin_user \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888812','Numbering Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888813','Numbering Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888814','Numbering Customer Reader','customer',true,'approved');
SELECT pg_temp.nd_login('9888888811') AS admin_claims \gset
SELECT pg_temp.nd_login('9888888812') AS supervisor_claims \gset
SELECT pg_temp.nd_login('9888888813') AS staff_claims \gset
SELECT pg_temp.nd_login('9888888814') AS customer_claims \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE mobile='919888888811' \gset
INSERT INTO public.customers(name,mobile) VALUES ('Numbering Customer','9888888801') RETURNING id AS customer_id \gset
INSERT INTO public.items(name,packaging) VALUES ('Numbering Potatoes','Bag') RETURNING id AS item_id \gset

SELECT pg_temp.nd_assert((SELECT count(*) FROM public.goodsreceived) = 0 AND (SELECT count(*) FROM public.dispatch) = 0 AND (SELECT count(*) FROM public.invoice) = 0,
  'the suggestions below count from empty document tables');
-- 1. The tables: row security on, no API role can read or write them, one row per type, the history only grows.
SELECT pg_temp.nd_assert((SELECT bool_and(c.relrowsecurity AND c.relowner = 'supabase_admin'::regrole) FROM pg_class c
    WHERE c.oid IN ('warehouse_security.document_numbering'::regclass, 'warehouse_security.document_numbering_history'::regclass)),
  'both tables have row security on and belong to the database owner');
SELECT pg_temp.nd_assert(NOT EXISTS (SELECT 1 FROM unnest(ARRAY['anon','authenticated','service_role']) r,
    unnest(ARRAY['warehouse_security.document_numbering','warehouse_security.document_numbering_history']) t
    WHERE has_table_privilege(r, t, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')),
  'no app role has a privilege on the rule or its history');
SELECT pg_temp.nd_assert((SELECT string_agg(document_type, ',' ORDER BY document_type) FROM warehouse_security.document_numbering) = 'dispatch,grn,invoice',
  'one rule per document type');
SELECT pg_temp.nd_assert(pg_temp.nd_call('DELETE FROM warehouse_security.document_numbering')->>'state' = '42501'
  AND pg_temp.nd_call('TRUNCATE warehouse_security.document_numbering')->>'state' = '42501',
  'a rule cannot be deleted or truncated');
SELECT pg_temp.nd_rule('grn', '{"scheme":"free"}') AS _ \gset
SELECT pg_temp.nd_assert(pg_temp.nd_call('UPDATE warehouse_security.document_numbering_history SET changed_by = NULL')->>'state' = '42501'
  AND pg_temp.nd_call('DELETE FROM warehouse_security.document_numbering_history')->>'state' = '42501'
  AND pg_temp.nd_call('TRUNCATE warehouse_security.document_numbering_history')->>'state' = '42501',
  'the history cannot be changed, deleted or truncated');
-- The table refuses a row the RPC would never write.
SELECT pg_temp.nd_assert(NOT EXISTS (SELECT 1 FROM (VALUES
  ('scheme', $$UPDATE warehouse_security.document_numbering SET scheme = 'words' WHERE document_type = 'grn'$$),
  ('letters without a first letter', $$UPDATE warehouse_security.document_numbering SET scheme = 'letters', first_letter = NULL, per_letter = NULL, fy_reset = false WHERE document_type = 'dispatch'$$),
  ('a prefix on letters', $$UPDATE warehouse_security.document_numbering SET scheme = 'letters', prefix = 'G', first_letter = 'A', per_letter = 10, fy_reset = false WHERE document_type = 'dispatch'$$),
  ('a lower case prefix', $$UPDATE warehouse_security.document_numbering SET prefix = 'i' WHERE document_type = 'dispatch'$$),
  ('an eleven character prefix', $$UPDATE warehouse_security.document_numbering SET prefix = 'ABCDEFGHIJK' WHERE document_type = 'dispatch'$$),
  ('eight digits', $$UPDATE warehouse_security.document_numbering SET width = 8 WHERE document_type = 'dispatch'$$),
  ('a first number of 0', $$UPDATE warehouse_security.document_numbering SET start = 0 WHERE document_type = 'dispatch'$$),
  ('fy_reset that disagrees with the scheme', $$UPDATE warehouse_security.document_numbering SET fy_reset = true WHERE document_type = 'dispatch'$$),
  ('a free invoice', $$UPDATE warehouse_security.document_numbering SET scheme = 'free', fy_reset = false WHERE document_type = 'invoice'$$),
  ('letters for an invoice', $$UPDATE warehouse_security.document_numbering SET scheme = 'letters', first_letter = 'A', per_letter = 10, fy_reset = false WHERE document_type = 'invoice'$$),
  ('a prefix on an invoice', $$UPDATE warehouse_security.document_numbering SET scheme = 'sequence', prefix = 'I', fy_reset = false WHERE document_type = 'invoice'$$),
  ('an invoice with the check off', $$UPDATE warehouse_security.document_numbering SET "check" = false WHERE document_type = 'invoice'$$),
  ('a year number that does not fit the column', $$UPDATE warehouse_security.document_numbering SET scheme = 'year', prefix = 'ABCDEFGHIJ', width = 5, fy_reset = true WHERE document_type = 'dispatch'$$)
  ) AS c(label, statement) WHERE pg_temp.nd_call(c.statement)->>'state' IS DISTINCT FROM '23514'),
  'the table checks refuse every row outside the rules');

-- 2. Numbers of 20 characters: the columns, the view that reads one, and the checks that were not validated.
SELECT pg_temp.nd_assert((SELECT bool_and(character_maximum_length = 20) AND count(*) = 4 FROM information_schema.columns
    WHERE table_schema = 'public' AND ((table_name = 'goodsreceived' AND column_name = 'gr_no') OR (table_name = 'invoice' AND column_name = 'gr_no')
      OR (table_name = 'dispatch' AND column_name = 'disp_no') OR (table_name = 'v_orders_list' AND column_name = 'dispatch_no'))),
  'GRN, dispatch and invoice GRN numbers (and the order list view) hold 20 characters');
SELECT pg_temp.nd_assert((SELECT c.relowner = 'supabase_admin'::regrole AND c.relkind = 'v'
      AND NOT has_table_privilege('authenticated', c.oid, 'SELECT') AND NOT has_table_privilege('anon', c.oid, 'SELECT')
      AND has_table_privilege('service_role', c.oid, 'SELECT,INSERT,UPDATE,DELETE')
      AND obj_description(c.oid, 'pg_class') = 'Live replacement for mv_orders_list, read only through get_orders_list.'
    FROM pg_class c WHERE c.oid = 'public.v_orders_list'::regclass),
  'the order list view is as it was: owner, comment, service role only');
SELECT pg_temp.nd_assert((SELECT count(*) = 2 AND bool_and(NOT convalidated) FROM pg_constraint
    WHERE conname IN ('goodsreceived_gr_no_not_blank', 'dispatch_disp_no_not_blank')),
  'the two blank-number checks are still there, not validated, as before');
SELECT pg_temp.nd_assert(pg_temp.nd_call($$INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('  ', '$$ || :'customer_id' || $$') RETURNING 1$$)->>'state' = '23514'
  AND pg_temp.nd_call($$INSERT INTO public.dispatch(disp_no, customer_id) VALUES ('  ', '$$ || :'customer_id' || $$') RETURNING 1$$)->>'state' = '23514',
  'a blank number is still refused by those checks');
SELECT pg_temp.nd_assert(pg_temp.nd_call($$INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('ABCDEFGHIJ0123456789', '$$ || :'customer_id' || $$') RETURNING 1$$)->>'raised' IS NULL
  AND pg_temp.nd_call($$INSERT INTO public.dispatch(disp_no, customer_id) VALUES ('ABCDEFGHIJ0123456789', '$$ || :'customer_id' || $$') RETURNING 1$$)->>'raised' IS NULL
  AND pg_temp.nd_call($$INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('ABCDEFGHIJ01234567890', '$$ || :'customer_id' || $$') RETURNING 1$$)->>'state' = '22001'
  AND pg_temp.nd_call($$INSERT INTO public.dispatch(disp_no, customer_id) VALUES ('ABCDEFGHIJ01234567890', '$$ || :'customer_id' || $$') RETURNING 1$$)->>'state' = '22001',
  'a number column takes 20 characters and not 21');
DELETE FROM public.goodsreceived WHERE gr_no = 'ABCDEFGHIJ0123456789';
DELETE FROM public.dispatch WHERE disp_no = 'ABCDEFGHIJ0123456789';

-- 3. Letters, from A (the default). Suggestions with data, as the owner reads them.
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters"}')->>'changed' AS _ \gset
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'A0001' AND warehouse_security.document_number_suggestion('grn', NULL)->>'hint' = 'A####',
  'no GRN: A0001, the pattern A####');
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('A0999', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'A1000', 'A0999 is followed by A1000');
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('A1000', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'B0001', 'at 1000 the next letter starts');
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('C0003', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'C0004', 'the highest letter in use is followed, not the first one with room');
-- A full series has every letter in use (a letter range that is unused would start a new order, section 4a), so the other letters are filled.
INSERT INTO public.goodsreceived(gr_no, customer_id) SELECT chr(i) || '1000', :'customer_id' FROM generate_series(66, 89) AS i WHERE chr(i) <> 'C';
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('Z1000', :'customer_id');
SELECT pg_temp.nd_assert(warehouse_security.document_number_suggestion('grn', NULL) = jsonb_build_object('number', NULL, 'hint', 'A####', 'scheme', 'letters', 'reason', 'SERIES_FULL',
    'message', 'All GRN numbers A0001–Z1000 are used', 'sqlstate', 'WH409'),
  'after Z1000 the series is full, with the range in the message and no number: '||warehouse_security.document_number_suggestion('grn', NULL)::text);
DELETE FROM public.goodsreceived WHERE gr_no IN ('A0999', 'A1000', 'C0003', 'Z1000') OR gr_no ~ '^[B-Y]1000$';
-- Another size: first letter B, 3 digits, 50 to a letter; the order is B, C, ... Z, A.
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters","first_letter":"B","width":3,"per_letter":50}')->>'next_number' AS first_b \gset
SELECT pg_temp.nd_assert(:'first_b' = 'B001', 'a rule that starts at B: B001');
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('B049', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'B050', 'B049 is followed by B050');
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('B050', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'C001', 'at the 50 of this rule the next letter starts');
-- C to Z are in use before A is: with a letter range unused, A would not be the last letter (section 4a).
INSERT INTO public.goodsreceived(gr_no, customer_id) SELECT chr(i) || '050', :'customer_id' FROM generate_series(67, 90) AS i;
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('A010', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'A011', 'A comes last in a series that starts at B');
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('A050', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'SERIES_FULL' AND warehouse_security.document_number_suggestion('grn', NULL)->>'message' = 'All GRN numbers B001–A50 are used',
  'A50 closes a series that starts at B: '||warehouse_security.document_number_suggestion('grn', NULL)::text);
DELETE FROM public.goodsreceived WHERE gr_no IN ('B049', 'B050', 'A010', 'A050') OR gr_no ~ '^[C-Z]050$';
-- Numbers grow past the width instead of being cut.
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters","width":2,"per_letter":9999999}') AS _ \gset
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('A99', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'A100', 'A99 with 2 digits is followed by A100, not A10');
DELETE FROM public.goodsreceived WHERE gr_no = 'A99';

-- 4. FAS's series: X, Y, Z, then A, B ... The rule that starts at X follows it, past A1000, the case the earlier generator got wrong.
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters","first_letter":"X"}')->>'next_number' AS first_x \gset
SELECT pg_temp.nd_assert(:'first_x' = 'X0001', 'a rule that starts at X: X0001');
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('X1000', :'customer_id'), ('Y1000', :'customer_id'), ('Z1000', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'A0001', 'Z1000 is followed by A0001 in the X series');
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('A0007', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'A0008', 'A0007 in the X series is followed by A0008');
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('A1000', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'B0001', 'A1000 in the X series is followed by B0001, not by the taken A0001');
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('Z1001', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'B0001', 'Z1001, an overflow number of the Z series, changes nothing');
DELETE FROM public.goodsreceived WHERE gr_no IN ('X1000', 'Y1000', 'Z1000', 'Z1001', 'A0007', 'A1000');

-- 4a. FAS's real shape: the 2019 book holds W0818-W1000 and the series goes on X, Y, Z, A. A rule that says X is not full at W1000: the
-- order starts after the longest run of unused letters (B to V), which is W. A rule that says W, and the default A, give the same answer.
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('W0818', :'customer_id'), ('W0999', :'customer_id'), ('W1000', :'customer_id'), ('X0001', :'customer_id'), ('X1000', :'customer_id'),
  ('Y0500', :'customer_id'), ('Y1000', :'customer_id'), ('Z1000', :'customer_id'), ('A0257', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'A0258', 'first=X with W0818-W1000, X, Y, Z and A0257 in use: A0258, not SERIES_FULL: '||warehouse_security.document_number_suggestion('grn', NULL)::text);
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters","first_letter":"W"}')->>'next_number' AS fas_w_next \gset
SELECT pg_temp.nd_assert(:'fas_w_next' = 'A0258', 'first=W gives A0258 too');
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters"}') AS _ \gset
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'A0258' AND warehouse_security.document_number_suggestion('grn', NULL)->>'hint' = 'A####', 'and the default rule (A), where Z and A are in use: A0258');
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters","first_letter":"X"}') AS _ \gset
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('A1000', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'B0001', 'A1000 closes A: B0001');
DELETE FROM public.goodsreceived WHERE gr_no IN ('X0001', 'X1000', 'Y0500', 'Y1000', 'Z1000', 'A0257', 'A1000');
-- The 2019 book alone: W1000 is a full letter of a series that goes on at X; with part of the book and X in use, X goes on.
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'X0001', 'W0818-W1000 alone, first=X: X0001: '||warehouse_security.document_number_suggestion('grn', NULL)::text);
DELETE FROM public.goodsreceived WHERE gr_no = 'W1000';
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('X0500', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'X0501', 'W0999 and X0500 in use, first=X: X0501, not W1000');
DELETE FROM public.goodsreceived WHERE gr_no IN ('W0818', 'W0999', 'X0500');
-- Two unused runs as long as each other (A-L and N-Y): the order starts after the one nearer the first letter, M.
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('M0005', :'customer_id'), ('Z0005', :'customer_id');
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters"}') AS _ \gset
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'Z0006', 'M and Z in use, equal runs: the order starts at M, so Z is the highest: Z0006');
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('B0001', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'M0006', 'and with B in use the longest run is N-Y: the order starts at Z, so M is the highest letter: M0006');
DELETE FROM public.goodsreceived WHERE gr_no IN ('M0005', 'Z0005', 'B0001');

-- 4b. GCS's books (W1000, X1000, Y1000, Z1001, A0257) with one mistyped letter: Q0001 for A0001. The order starts after the longest
-- run of unused letters whatever the rule's first letter says, so the stray does not take the suggestion over under W, X or A.
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('W1000', :'customer_id'), ('X1000', :'customer_id'), ('Y1000', :'customer_id'), ('Z1001', :'customer_id'),
  ('A0257', :'customer_id'), ('Q0001', :'customer_id');
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters","first_letter":"W"}')->>'next_number' AS stray_w \gset
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters","first_letter":"X"}')->>'next_number' AS stray_x \gset
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters","first_letter":"A"}')->>'next_number' AS stray_a \gset
SELECT pg_temp.nd_assert(:'stray_w' = 'A0258' AND :'stray_x' = 'A0258' AND :'stray_a' = 'A0258', 'Q0001 beside W-A: A0258 under W, X and A: '||:'stray_w'||' '||:'stray_x'||' '||:'stray_a');
-- The stray is named for the administrator (doctor prints it): the main run is the letters that follow one another up to the highest.
SELECT pg_temp.nd_assert(warehouse_security.grn_stray_letters() = '{"series":"W–A","strays":[{"letter":"Q","numbers":1,"example":"Q0001"}]}'::jsonb,
  'the stray letter is listed with the main run: '||warehouse_security.grn_stray_letters()::text);
DELETE FROM public.goodsreceived WHERE gr_no = 'Q0001';
SELECT pg_temp.nd_assert(warehouse_security.grn_stray_letters() = '{"series":"W–A","strays":[]}'::jsonb AND pg_temp.nd_next('grn') = 'A0258', 'without a stray none is listed: '||warehouse_security.grn_stray_letters()::text);
-- A stray in B to K still takes the order (C0002); it is the one doctor names, so that it gets corrected.
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('C0001', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'C0002' AND warehouse_security.grn_stray_letters()->'strays' = '[{"letter":"C","numbers":1,"example":"C0001"}]'::jsonb,
  'a stray beside the series is named: '||warehouse_security.grn_stray_letters()::text);
DELETE FROM public.goodsreceived WHERE gr_no IN ('W1000', 'X1000', 'Y1000', 'Z1001', 'A0257', 'C0001');
SELECT pg_temp.nd_assert(warehouse_security.grn_stray_letters() = '{}'::jsonb, 'no GRN, no letters to list');
-- The main series is the run that holds the most numbers, not the one with the highest numbers: a young facility (A0001-A0050) with one
-- mistyped Q0900 has Q as the stray, and the suggestion is A0051.
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters","first_letter":"A"}') AS _ \gset
INSERT INTO public.goodsreceived(gr_no, customer_id) SELECT 'A' || lpad(g::text, 4, '0'), :'customer_id' FROM generate_series(1, 50) g;
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('Q0900', :'customer_id');
SELECT pg_temp.nd_assert(warehouse_security.grn_stray_letters() = '{"series":"A–A","strays":[{"letter":"Q","numbers":1,"example":"Q0900"}]}'::jsonb AND pg_temp.nd_next('grn') = 'A0051',
  'the series with 50 numbers is the main one, the stray Q0900 is named: '||warehouse_security.grn_stray_letters()::text||' '||pg_temp.nd_next('grn'));
DELETE FROM public.goodsreceived WHERE gr_no = 'Q0900' OR gr_no ~ '^A00[0-5][0-9]$';
-- A letter that follows one that is not full takes the suggestion on (A0500 with B0001 gives B0002) and joins the run, so it is not a stray; doctor says
-- so through previous_not_full. A full letter before it (A1000) is the normal change of letter: nothing to say.
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('A0500', :'customer_id'), ('B0001', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn') = 'B0002'
  AND warehouse_security.grn_stray_letters() = '{"series":"A–B","strays":[],"previous_not_full":{"letter":"B","previous":"A","highest":"A0500"}}'::jsonb,
  'B0001 after A0500 is named: '||warehouse_security.grn_stray_letters()::text||' '||pg_temp.nd_next('grn'));
DELETE FROM public.goodsreceived WHERE gr_no = 'A0500';
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('A1000', :'customer_id');
SELECT pg_temp.nd_assert(warehouse_security.grn_stray_letters() = '{"series":"A–B","strays":[]}'::jsonb, 'B0001 after a full A1000 is nothing to say: '||warehouse_security.grn_stray_letters()::text);
DELETE FROM public.goodsreceived WHERE gr_no IN ('A1000', 'B0001');
-- A tie between two runs of unused letters (a stray at L beside W-A: B-K and M-V are as long as each other): the run nearer the first letter wins, so the
-- answer depends on the first letter here and only here (L0002 under W, A0258 under X and A).
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('W1000', :'customer_id'), ('X1000', :'customer_id'), ('Y1000', :'customer_id'), ('Z1001', :'customer_id'),
  ('A0257', :'customer_id'), ('L0001', :'customer_id');
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters","first_letter":"W"}')->>'next_number' AS tie_w \gset
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters","first_letter":"X"}')->>'next_number' AS tie_x \gset
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters","first_letter":"A"}')->>'next_number' AS tie_a \gset
SELECT pg_temp.nd_assert(:'tie_w' = 'L0002' AND :'tie_x' = 'A0258' AND :'tie_a' = 'A0258', 'L0001 beside W-A is a tie: L0002 under W, A0258 under X and A: '||:'tie_w'||' '||:'tie_x'||' '||:'tie_a');
DELETE FROM public.goodsreceived WHERE gr_no IN ('W1000', 'X1000', 'Y1000', 'Z1001', 'A0257', 'L0001');
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters","first_letter":"X"}') AS _ \gset

-- 5. Financial year: GRN/26-27/0001, the year of the day, restarting on 1 April.
SELECT pg_temp.nd_rule('grn', '{"scheme":"year","prefix":"GRN/"}')->>'hint' AS _ \gset
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('GRN/26-27/0418', :'customer_id'), ('A0001', :'customer_id'), ('GRN/25-26/0900', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn', '2027-03-31') = 'GRN/26-27/0419', '31 March: still 26-27, after 0418 (A0001 and 25-26 numbers do not count)');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn', '2027-04-01') = 'GRN/27-28/0001', '1 April: 27-28 starts at 0001');
SELECT pg_temp.nd_assert(warehouse_security.document_number_suggestion('grn', '2027-04-01')->>'hint' = 'GRN/27-28/####', 'the pattern names the year of the day');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn', '2099-04-01') = 'GRN/99-00/0001', 'the year after 99 is 00');
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('GRN/99-00/9999', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn', '2099-04-01') = 'GRN/99-00/10000', 'the digits grow past the width');
DELETE FROM public.goodsreceived WHERE gr_no IN ('GRN/26-27/0418', 'A0001', 'GRN/25-26/0900', 'GRN/99-00/9999');
-- A prefix of 10 characters leaves room for 4 digits only.
SELECT pg_temp.nd_rule('grn', '{"scheme":"year","prefix":"ABCDEFGHIJ"}') AS _ \gset
INSERT INTO public.goodsreceived(gr_no, customer_id) VALUES ('ABCDEFGHIJ26-27/9999', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('grn', '2026-05-01') = 'SERIES_FULL' AND warehouse_security.document_number_suggestion('grn', '2026-05-01')->>'sqlstate' = '22003',
  'a number that would not fit the 20 characters is never suggested');
DELETE FROM public.goodsreceived WHERE gr_no = 'ABCDEFGHIJ26-27/9999';

-- 6. Sequence: the dispatch default I0001, a first number, no prefix; the end at 9999999 as before.
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"sequence","prefix":"I"}')->>'hint' AS _ \gset
SELECT pg_temp.nd_assert(pg_temp.nd_next('dispatch') = 'I0001' AND warehouse_security.document_number_suggestion('dispatch', NULL)->>'hint' = 'I####', 'no dispatch: I0001');
INSERT INTO public.dispatch(disp_no, customer_id) VALUES ('I4817', :'customer_id'), ('I9', :'customer_id'), ('I4568   ', :'customer_id'), ('ZCUSTOM', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('dispatch') = 'I4818', 'the highest I number plus 1; a number with spaces or another prefix is ignored');
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"sequence","prefix":"I","start":5000}') AS _ \gset
SELECT pg_temp.nd_assert(pg_temp.nd_next('dispatch') = 'I5000', 'not below the first number of the rule');
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"sequence","prefix":"I","start":4000}') AS _ \gset
SELECT pg_temp.nd_assert(pg_temp.nd_next('dispatch') = 'I4818', 'a first number below the highest does not matter');
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"sequence","start":1001,"width":1}') AS _ \gset
SELECT pg_temp.nd_assert(pg_temp.nd_next('dispatch') = '1001' AND warehouse_security.document_number_suggestion('dispatch', NULL)->>'hint' = '#', 'no prefix, from 1001, a paper book kept going');
INSERT INTO public.dispatch(disp_no, customer_id) VALUES ('1001', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('dispatch') = '1002', 'and then 1002');
DELETE FROM public.dispatch WHERE disp_no IN ('1001');
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"sequence","prefix":"I"}') AS _ \gset
INSERT INTO public.dispatch(disp_no, customer_id) VALUES ('I9999', :'customer_id');
SELECT pg_temp.nd_assert(pg_temp.nd_next('dispatch') = 'I10000', 'I9999 is followed by I10000, not cut to I1000');
INSERT INTO public.dispatch(disp_no, customer_id) VALUES ('I9999999', :'customer_id');
SELECT pg_temp.nd_assert(warehouse_security.document_number_suggestion('dispatch', NULL) = jsonb_build_object('number', NULL, 'hint', 'I####', 'scheme', 'sequence', 'reason', 'SERIES_FULL',
    'message', 'Dispatch number sequence exhausted at I9999999', 'sqlstate', '22003'), 'I9999999 ends the sequence');
DELETE FROM public.dispatch WHERE disp_no IN ('I4817', 'I9', 'I4568   ', 'ZCUSTOM', 'I9999', 'I9999999');

-- The longest sequence rule (a prefix of 10 characters and 7 digits, 17 characters) fits the column: there is no length check to reach.
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"sequence","prefix":"ABCDEFGHIJ","width":7}')->>'next_number' AS longest_sequence \gset
SELECT pg_temp.nd_assert(:'longest_sequence' = 'ABCDEFGHIJ0000001' AND char_length(:'longest_sequence') = 17, 'a 10-character prefix with 7 digits is a rule and suggests its first number');
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"sequence","prefix":"I"}') AS _ \gset

-- 7. Free text: no suggestion, only the reason; the old calls raise it.
SELECT pg_temp.nd_rule('grn', '{"scheme":"free"}')->>'reason' AS free_reason \gset
SELECT pg_temp.nd_assert(:'free_reason' = 'TYPE_IT' AND warehouse_security.document_number_suggestion('grn', NULL)->'hint' = 'null'::jsonb, 'free text: the reason TYPE_IT and no pattern');
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"free"}') AS _ \gset
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.nd_assert(pg_temp.nd_call('SELECT public.get_next_grn_number()') = jsonb_build_object('raised', 'Type the GRN number.', 'state', 'WH409'), 'get_next_grn_number raises the reason, never an empty answer: '||pg_temp.nd_call('SELECT public.get_next_grn_number()')::text);
SELECT pg_temp.nd_assert(pg_temp.nd_call('SELECT public.get_next_dispatch_number()') = jsonb_build_object('raised', 'Type the dispatch number.', 'state', 'WH409'), 'and get_next_dispatch_number');
SELECT pg_temp.nd_assert(public.suggest_document_number('grn') = '{"success":true,"number":null,"hint":null,"scheme":"free","reason":"TYPE_IT"}'::jsonb,
  'suggest_document_number answers TYPE_IT without a message: '||public.suggest_document_number('grn')::text);
RESET ROLE;

-- 8. Invoice numbers: whole numbers, per financial year (today) or counting on across years.
SELECT pg_temp.nd_rule('invoice', '{"scheme":"year"}')->>'changed' AS _ \gset
INSERT INTO public.invoice(inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, labour, tax_amount, total, discount)
SELECT f.y, f.n, gen_random_uuid(), 'NUMGRN', :'customer_id', 'Numbering Customer', now(), 0, 0, 0, 0 FROM (VALUES (2090, 40), (2090, 7), (2091, 12)) AS f(y, n);
SELECT pg_temp.nd_assert(warehouse_security.document_number_suggestion('invoice', NULL, 2090)->>'number' = '41'
  AND warehouse_security.document_number_suggestion('invoice', NULL, 2091)->>'number' = '13'
  AND warehouse_security.document_number_suggestion('invoice', NULL, 2092)->>'number' = '1', 'year: each financial year counts for itself');
SELECT pg_temp.nd_rule('invoice', '{"scheme":"sequence"}')->>'changed' AS _ \gset
SELECT pg_temp.nd_assert(warehouse_security.document_number_suggestion('invoice', NULL, 2090)->>'number' = '41'
  AND warehouse_security.document_number_suggestion('invoice', NULL, 2092)->>'number' = '41'
  AND warehouse_security.document_number_suggestion('invoice', NULL, 2091)->>'number' = '41'
  AND warehouse_security.document_number_suggestion('invoice', NULL, 2092)->'hint' = '"#"'::jsonb, 'sequence: the highest of every year plus 1, in any year');
-- An invoice number that has reached the ceiling: the words name a financial year only when the rule counts per year.
INSERT INTO public.invoice(inv_fin_year, inv_no, gr_id, gr_no, customer_id, customer_name, inv_date, labour, tax_amount, total, discount)
VALUES (2093, 99999999, gen_random_uuid(), 'NUMGRN', :'customer_id', 'Numbering Customer', now(), 0, 0, 0, 0);
SELECT pg_temp.nd_assert(warehouse_security.document_number_suggestion('invoice', NULL, 2090) = jsonb_build_object('number', NULL, 'hint', '#', 'scheme', 'sequence', 'reason', 'SERIES_FULL',
    'message', 'No invoice number is left', 'sqlstate', 'WH409'), 'sequence: the ceiling is no financial year'||warehouse_security.document_number_suggestion('invoice', NULL, 2090)::text);
SELECT pg_temp.nd_rule('invoice', '{"scheme":"year"}') AS _ \gset
SELECT pg_temp.nd_assert(warehouse_security.document_number_suggestion('invoice', NULL, 2093)->>'message' = 'No invoice number is left in financial year 2093'
  AND warehouse_security.document_number_suggestion('invoice', NULL, 2090)->>'number' = '41', 'year: the ceiling of one year names it and leaves the others');
DELETE FROM public.invoice WHERE inv_no = 99999999 AND gr_no = 'NUMGRN';
SELECT pg_temp.nd_rule('invoice', '{"scheme":"sequence"}') AS _ \gset
SELECT pg_temp.nd_rule('invoice', '{"scheme":"sequence","start":500}') AS _ \gset
SELECT pg_temp.nd_assert(pg_temp.nd_next('invoice') = '500', 'a first number applies to invoices too');
SELECT pg_temp.nd_rule('invoice', '{"scheme":"year","start":500}') AS _ \gset
SELECT pg_temp.nd_assert(warehouse_security.document_number_suggestion('invoice', NULL, 2092)->>'number' = '500' AND warehouse_security.document_number_suggestion('invoice', NULL, 2090)->>'number' = '500', 'and to every year of a year rule');
SELECT pg_temp.nd_rule('invoice', '{"scheme":"year"}') AS _ \gset
DELETE FROM public.invoice WHERE gr_no = 'NUMGRN';

-- 9. A rule is checked before it is stored: what is refused, with the message that says what to do.
SELECT pg_temp.nd_assert(NOT EXISTS (SELECT 1 FROM (VALUES
  ('grn', '{"scheme":"words"}', 'Unknown scheme words. Use letters, year, sequence or free.'),
  ('grn', '[]', 'The rule must be an object with a scheme.'),
  ('grn', '{"prefix":"G"}', 'The rule must be an object with a scheme.'),
  ('boxes', '{"scheme":"free"}', 'Unknown document type boxes. Use grn, dispatch or invoice.'),
  ('grn', '{"scheme":"free","prefix":"G"}', 'prefix does not belong to a free rule for grn.'),
  ('grn', '{"scheme":"letters","prefix":"G"}', 'prefix does not belong to a letters rule for grn.'),
  ('grn', '{"scheme":"year","first_letter":"A"}', 'first_letter does not belong to a year rule for grn.'),
  ('grn', '{"scheme":"sequence","per_letter":10}', 'per_letter does not belong to a sequence rule for grn.'),
  ('grn', '{"scheme":"letters","start":5}', 'start does not belong to a letters rule for grn.'),
  ('grn', '{"scheme":"sequence","prefix":"i"}', 'The prefix can have up to 10 characters: capital letters, digits, / and -.'),
  ('grn', '{"scheme":"sequence","prefix":"ABCDEFGHIJK"}', 'The prefix can have up to 10 characters: capital letters, digits, / and -.'),
  ('grn', '{"scheme":"sequence","prefix":5}', 'The prefix can have up to 10 characters: capital letters, digits, / and -.'),
  ('grn', '{"scheme":"letters","first_letter":"a"}', 'The first letter must be one capital letter.'),
  ('grn', '{"scheme":"sequence","width":0}', 'The number of digits must be a whole number from 1 to 7.'),
  ('grn', '{"scheme":"sequence","width":8}', 'The number of digits must be a whole number from 1 to 7.'),
  ('grn', '{"scheme":"sequence","width":"4"}', 'The number of digits must be a whole number from 1 to 7.'),
  ('grn', '{"scheme":"sequence","width":4.5}', 'The number of digits must be a whole number from 1 to 7.'),
  ('grn', '{"scheme":"sequence","start":0}', 'The first number must be a whole number from 1 to 9999999.'),
  ('grn', '{"scheme":"sequence","start":10000000}', 'The first number must be a whole number from 1 to 9999999.'),
  ('grn', '{"scheme":"letters","per_letter":0}', 'The numbers per letter must be a whole number from 1 to 9999999.'),
  ('grn', '{"scheme":"year","prefix":"ABCDEFGHIJ","width":5}', 'A number with this prefix, the year (26-27/) and 5 digits is longer than 20 characters.'),
  ('invoice', '{"scheme":"letters"}', 'An invoice number is a whole number: use year (starts again at 1 every financial year) or sequence (keeps counting).'),
  ('invoice', '{"scheme":"free"}', 'An invoice number is a whole number: use year (starts again at 1 every financial year) or sequence (keeps counting).'),
  ('invoice', '{"scheme":"year","prefix":"INV"}', 'prefix does not belong to a year rule for invoice.'),
  ('invoice', '{"scheme":"sequence","width":4}', 'width does not belong to a sequence rule for invoice.')
  ) AS c(t, rule, expected)
  WHERE pg_temp.nd_call(format('SELECT warehouse_security.apply_document_numbering(%L, %L::jsonb, NULL)', c.t, c.rule))
        IS DISTINCT FROM jsonb_build_object('raised', c.expected, 'state', '22023')),
  'every wrong rule is refused with its own message');
SELECT pg_temp.nd_assert(NOT EXISTS (SELECT 1 FROM warehouse_security.document_numbering_history WHERE document_type = 'invoice' AND new_rule->>'scheme' IN ('letters', 'free')),
  'a refused rule leaves nothing in the history');

-- 10. The history: one row per change with the old and the new rule and the live documents; none for the same rule again.
SELECT count(*) AS history_before FROM warehouse_security.document_numbering_history WHERE document_type = 'dispatch' \gset
INSERT INTO public.dispatch(disp_no, customer_id) VALUES ('H1', :'customer_id'), ('H2', :'customer_id');
INSERT INTO public.dispatch(disp_no, customer_id, deleted_at) VALUES ('H3', :'customer_id', now());
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"sequence","prefix":"H","width":3}')->>'changed' AS changed_once \gset
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"sequence","prefix":"H","width":3}')->>'changed' AS changed_twice \gset
SELECT pg_temp.nd_assert(:'changed_once' = 'true' AND :'changed_twice' = 'false', 'a changed rule is reported as changed, the same rule again is not');
SELECT pg_temp.nd_assert((SELECT count(*) FROM warehouse_security.document_numbering_history WHERE document_type = 'dispatch') = :history_before + 1, 'one history row, not two');
SELECT pg_temp.nd_assert((SELECT old_rule->>'scheme' = 'free' AND new_rule->>'prefix' = 'H' AND new_rule->>'width' = '3' AND changed_by IS NULL AND existing_documents = 2
      AND changed_at > now() - interval '1 minute' FROM warehouse_security.document_numbering_history WHERE document_type = 'dispatch' ORDER BY id DESC LIMIT 1),
  'the row holds the old rule, the new rule, no person (the operator) and the two live dispatches');
SELECT pg_temp.nd_assert((SELECT updated_by IS NULL FROM warehouse_security.document_numbering WHERE document_type = 'dispatch')
  AND pg_temp.nd_next('dispatch') = 'H004', 'the new rule suggests H004: H1 and H2 are live, the deleted H3 keeps its number');
DELETE FROM public.dispatch WHERE disp_no IN ('H1', 'H2', 'H3');

-- 11. Who may read and change a rule, and what the old calls and the new one answer.
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters"}') AS _ \gset
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"sequence","prefix":"I"}') AS _ \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_document_numbering() AS rules \gset
SELECT public.set_document_numbering('grn', '{"scheme":"year","prefix":"GRN/"}') AS set_by_admin \gset
SELECT public.get_next_grn_number() AS old_call_year \gset
SELECT public.set_document_numbering('grn', '{"scheme":"letters"}') AS set_back \gset
SELECT public.suggest_document_number('grn') AS suggested \gset
SELECT public.suggest_document_number('invoice', '2027-04-01') AS suggested_invoice \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'rules'::jsonb->>'success' = 'true' AND (SELECT string_agg(r->>'document_type', ',') FROM jsonb_array_elements(:'rules'::jsonb->'rules') r) = 'grn,dispatch,invoice'
  AND (:'rules'::jsonb#>'{rules,0}') ? 'existing_documents' AND (:'rules'::jsonb#>>'{rules,0,hint}') = 'A####' AND (:'rules'::jsonb#>>'{rules,1,hint}') = 'I####'
  AND (:'rules'::jsonb#>>'{rules,2,scheme}') = 'year' AND (:'rules'::jsonb#>>'{rules,2,fy_reset}') = 'true', 'the administrator reads the three rules in order: '||:'rules');
SELECT pg_temp.nd_assert(:'set_by_admin'::jsonb->>'success' = 'true' AND :'set_by_admin'::jsonb->>'changed' = 'true' AND :'set_by_admin'::jsonb#>>'{rule,prefix}' = 'GRN/'
  AND :'set_by_admin'::jsonb#>>'{previous_rule,scheme}' = 'letters' AND :'set_by_admin'::jsonb->>'next_number' ~ '^GRN/[0-9]{2}-[0-9]{2}/0001$' AND :'set_by_admin'::jsonb->>'hint' ~ '^GRN/[0-9]{2}-[0-9]{2}/####$',
  'the administrator changes a rule and is told the new rule, the old one and the next number: '||:'set_by_admin');
SELECT pg_temp.nd_assert(:'old_call_year' ~ '^GRN/[0-9]{2}-[0-9]{2}/0001$', 'get_next_grn_number returns the new suggestion: '||:'old_call_year');
SELECT pg_temp.nd_assert((SELECT changed_by = :'admin_profile'::uuid AND old_rule->>'scheme' = 'letters' FROM warehouse_security.document_numbering_history
    WHERE document_type = 'grn' AND new_rule->>'prefix' = 'GRN/' ORDER BY id DESC LIMIT 1)
  AND (SELECT updated_by = :'admin_profile'::uuid FROM warehouse_security.document_numbering WHERE document_type = 'grn'), 'the change is recorded with the administrator');
SELECT pg_temp.nd_assert(:'suggested'::jsonb = '{"success":true,"number":"A0001","hint":"A####","scheme":"letters","reason":null}'::jsonb, 'suggest_document_number: '||:'suggested');
SELECT pg_temp.nd_assert(:'suggested_invoice'::jsonb->>'number' = '1' AND :'suggested_invoice'::jsonb->>'scheme' = 'year', 'invoices too: '||:'suggested_invoice');
-- supervisor: reads and suggests, does not change
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.nd_assert(public.get_document_numbering()->>'success' = 'true' AND public.suggest_document_number('dispatch')->>'number' = 'I0001', 'the supervisor reads the rules and is suggested a number');
SELECT pg_temp.nd_assert(pg_temp.nd_call($$SELECT public.set_document_numbering('grn', '{"scheme":"free"}')$$) = jsonb_build_object('raised', 'Administrator required', 'state', '42501'),
  'the supervisor cannot change a rule: '||pg_temp.nd_call($$SELECT public.set_document_numbering('grn', '{"scheme":"free"}')$$)::text);
RESET ROLE;
-- staff: suggests, does not read the rules, does not change
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.nd_assert(public.suggest_document_number('grn')->>'number' = 'A0001' AND public.get_next_grn_number() = 'A0001' AND public.get_next_dispatch_number() = 'I0001', 'staff are suggested numbers by both calls');
SELECT pg_temp.nd_assert(pg_temp.nd_call('SELECT public.get_document_numbering()') = jsonb_build_object('raised', 'Staff access required', 'state', '42501')
  AND pg_temp.nd_call($$SELECT public.set_document_numbering('grn', '{"scheme":"free"}')$$) = jsonb_build_object('raised', 'Administrator required', 'state', '42501'), 'staff do not read or change the rules');
RESET ROLE;
-- customer: nothing
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.nd_assert(NOT EXISTS (SELECT 1 FROM (VALUES ($$SELECT public.suggest_document_number('grn')$$, 'Staff access required'), ('SELECT public.get_document_numbering()', 'Staff access required'),
    ($$SELECT public.set_document_numbering('grn', '{"scheme":"free"}')$$, 'Administrator required')) AS c(statement, expected)
    WHERE pg_temp.nd_call(c.statement) IS DISTINCT FROM jsonb_build_object('raised', c.expected, 'state', '42501')), 'a customer account is refused by all three calls');
RESET ROLE;
SET LOCAL ROLE anon;
SELECT pg_temp.nd_assert(pg_temp.nd_call($$SELECT public.suggest_document_number('grn')$$)->>'state' = '42501' AND pg_temp.nd_call('SELECT public.get_document_numbering()')->>'state' = '42501'
  AND pg_temp.nd_call($$SELECT public.set_document_numbering('grn', '{"scheme":"free"}')$$)->>'state' = '42501', 'anonymous callers cannot run them');
RESET ROLE;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.nd_assert(pg_temp.nd_call($$SELECT public.suggest_document_number('boxes')$$) = jsonb_build_object('raised', 'Unknown document type boxes. Use grn, dispatch or invoice.', 'state', '22023')
  AND pg_temp.nd_call($$SELECT public.set_document_numbering('boxes', '{"scheme":"free"}')$$)->>'state' = '22023', 'an unknown type is refused');
RESET ROLE;
SELECT pg_temp.nd_assert(NOT EXISTS (SELECT 1 FROM unnest(ARRAY['authenticated', 'anon', 'service_role']) r,
    unnest(ARRAY['warehouse_security.document_number_suggestion(text,date,integer)', 'warehouse_security.apply_document_numbering(text,jsonb,uuid)',
                 'warehouse_security.document_number_failure(text,text,date)']) f WHERE has_function_privilege(r, f, 'EXECUTE')), 'the internal functions are for no API role');

-- 12. The GRN save refuses a number outside the rule, with the pattern; what it accepts.
CREATE FUNCTION pg_temp.nd_grn(p_number text, p_date timestamptz DEFAULT '2026-06-01T12:00:00Z') RETURNS jsonb LANGUAGE sql AS $$
  SELECT public.save_grn(p_gr_no => p_number, p_date => p_date, p_customer_id => current_setting('test.nd_customer')::uuid, p_customer_name => 'Numbering Customer',
    p_items => jsonb_build_array(jsonb_build_object('item_id', current_setting('test.nd_item'), 'item_name', 'Numbering Potatoes', 'packaging', 'Bag', 'qty', 10, 'weight', 5))) $$;
SELECT set_config('test.nd_customer', :'customer_id', true), set_config('test.nd_item', :'item_id', true) \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.nd_grn('A0500') AS ok_default, pg_temp.nd_grn('GRN1') AS bad_word, pg_temp.nd_grn('a0501') AS bad_case, pg_temp.nd_grn('A501') AS bad_short,
       pg_temp.nd_grn('A0500') AS again, pg_temp.nd_grn('  ') AS blank \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'ok_default'::jsonb->>'success' = 'true' AND EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no = 'A0500'), 'A0500 follows the default rule and is saved');
SELECT pg_temp.nd_assert(NOT EXISTS (SELECT 1 FROM (VALUES (:'bad_word', 'GRN1'), (:'bad_case', 'a0501'), (:'bad_short', 'A501')) AS c(answer, typed)
    WHERE NOT (c.answer::jsonb->>'success' = 'false' AND c.answer::jsonb->>'reason' = 'NUMBER_FORMAT' AND c.answer::jsonb->>'error_code' = 'WH409' AND c.answer::jsonb->>'number' = c.typed
      AND c.answer::jsonb->>'pattern' = 'A####' AND c.answer::jsonb->>'message' = 'This number does not follow this facility''s numbering (A####)' AND c.answer::jsonb->>'error' = c.answer::jsonb->>'message'
      AND NOT EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no = c.typed))),
  'GRN1, a0501 and A501 are refused with NUMBER_FORMAT, the typed number and the pattern, and nothing is written: '||:'bad_word');
SELECT pg_temp.nd_assert(:'again'::jsonb->>'message' = 'GRN number already exists: A0500' AND :'again'::jsonb->>'success' = 'false', 'a taken number in the right format is still refused by name: '||:'again');
SELECT pg_temp.nd_assert(:'blank'::jsonb->>'reason' IS NULL AND :'blank'::jsonb->>'message' LIKE 'Missing required parameters%', 'an empty number keeps its own answer: '||:'blank');
-- The rule of FAS's series accepts the legacy numbers, whatever their letter, and nothing else.
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters","first_letter":"X"}') AS _ \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.nd_grn('X0001') AS fas_x, pg_temp.nd_grn('Z1001') AS fas_overflow, pg_temp.nd_grn('A0130') AS fas_a, pg_temp.nd_grn('B2021') AS fas_b, pg_temp.nd_grn('W1000') AS fas_w,
       pg_temp.nd_grn('Z10') AS fas_short, pg_temp.nd_grn('G-14') AS fas_book \gset
RESET ROLE;
SELECT pg_temp.nd_assert(NOT EXISTS (SELECT 1 FROM (VALUES (:'fas_x'), (:'fas_overflow'), (:'fas_a'), (:'fas_b'), (:'fas_w')) AS c(answer) WHERE c.answer::jsonb->>'success' IS DISTINCT FROM 'true'),
  'X0001, Z1001, A0130, B2021 and W1000 are saved under the rule that starts at X: '||:'fas_overflow');
SELECT pg_temp.nd_assert(:'fas_short'::jsonb->>'reason' = 'NUMBER_FORMAT' AND :'fas_short'::jsonb->>'pattern' = 'X####' AND :'fas_book'::jsonb->>'reason' = 'NUMBER_FORMAT', 'Z10 (too few digits) and G-14 are refused: pattern X####');
-- Financial year: the pattern names the year of the date typed; two consecutive years.
SELECT pg_temp.nd_rule('grn', '{"scheme":"year","prefix":"GRN/"}') AS _ \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.nd_grn('GRN/26-27/0001') AS year_ok, pg_temp.nd_grn('GRN/26-28/0001', '2027-04-01T12:00:00Z') AS year_bad, pg_temp.nd_grn('A0001') AS year_old, pg_temp.nd_grn('GRN/26-27/001') AS year_short \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'year_ok'::jsonb->>'success' = 'true' AND :'year_bad'::jsonb->>'pattern' = 'GRN/27-28/####' AND :'year_bad'::jsonb->>'reason' = 'NUMBER_FORMAT'
  AND :'year_old'::jsonb->>'reason' = 'NUMBER_FORMAT' AND :'year_short'::jsonb->>'reason' = 'NUMBER_FORMAT', 'the year rule saves GRN/26-27/0001 and refuses the others, naming the year of the date: '||:'year_bad');
-- An empty or missing number is not this check's to judge: each save has its own answer for it.
SELECT pg_temp.nd_assert(warehouse_security.document_number_failure('grn', NULL, NULL) IS NULL AND warehouse_security.document_number_failure('grn', '  ', NULL) IS NULL
  AND warehouse_security.document_number_failure('dispatch', '', NULL) IS NULL, 'an empty number is left to the save RPC');
-- Free text: any number up to 20 characters, 21 refused; a 20-character number is stored whole.
SELECT pg_temp.nd_rule('grn', '{"scheme":"free"}') AS _ \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.nd_grn('14/B/2027') AS free_ok, pg_temp.nd_grn('ABCDEFGHIJ0123456789') AS free_20, pg_temp.nd_grn('ABCDEFGHIJ01234567890') AS free_21 \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'free_ok'::jsonb->>'success' = 'true' AND :'free_20'::jsonb->>'success' = 'true' AND EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no = 'ABCDEFGHIJ0123456789'), 'free text takes 14/B/2027 and 20 characters');
SELECT pg_temp.nd_assert(:'free_21'::jsonb->>'reason' = 'NUMBER_FORMAT' AND :'free_21'::jsonb->>'message' = 'This number can have at most 20 characters' AND :'free_21'::jsonb->'pattern' = 'null'::jsonb, 'but not 21: '||:'free_21');

-- 13. Dispatch: the create and the edit refuse a number outside the rule; the stored number may be sent back.
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"sequence","prefix":"I"}') AS _ \gset
SELECT id AS lot_id FROM public.goodsreceived_trl WHERE gr_id = (SELECT id FROM public.goodsreceived WHERE gr_no = 'A0500') \gset
SELECT jsonb_build_object('disp_no', 'D0001', 'disp_date', '2026-06-02T12:00:00Z', 'customer_id', :'customer_id', 'customer_name', 'Numbering Customer',
  'supervisor_id', :'admin_profile', 'supervisor_name', 'Numbering Administrator') AS dispatch_data \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb, ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'nd-bad') AS disp_bad,
       public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"I0500"}', ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'nd-ok') AS disp_ok,
       public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"  "}', ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'nd-blank') AS disp_blank \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'disp_blank'::jsonb->>'success' = 'false' AND :'disp_blank'::jsonb->>'reason' IS DISTINCT FROM 'NUMBER_FORMAT' AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE btrim(disp_no) = ''),
  'a blank dispatch number is not a NUMBER_FORMAT case, it keeps the refusal it had: '||:'disp_blank');
SELECT pg_temp.nd_assert(:'disp_bad'::jsonb->>'success' = 'false' AND :'disp_bad'::jsonb->>'reason' = 'NUMBER_FORMAT' AND :'disp_bad'::jsonb->>'pattern' = 'I####'
  AND :'disp_bad'::jsonb->>'message' = 'This number does not follow this facility''s numbering (I####)' AND :'disp_bad'::jsonb->>'number' = 'D0001'
  AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no = 'D0001') AND (SELECT stock = 9 FROM public.goodsreceived_trl WHERE id = :'lot_id'::uuid),
  'D0001 is refused by the dispatch create under the I rule, nothing written: '||:'disp_bad');
SELECT pg_temp.nd_assert(:'disp_ok'::jsonb->>'success' = 'true' AND EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no = 'I0500'), 'I0500 is saved: '||:'disp_ok');
SELECT id AS disp_id FROM public.dispatch WHERE disp_no = 'I0500' \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_id'::uuid, '{"disp_no":"D0009"}'::jsonb, NULL) AS edit_bad,
       public.update_dispatch_smart(:'disp_id'::uuid, '{"disp_no":"I0500","note":"same number sent back"}'::jsonb, NULL) AS edit_same,
       public.update_dispatch_smart(:'disp_id'::uuid, '{"disp_no":"I0501"}'::jsonb, NULL) AS edit_ok \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'edit_bad'::jsonb->>'reason' = 'NUMBER_FORMAT' AND :'edit_bad'::jsonb->>'pattern' = 'I####' AND :'edit_bad'::jsonb->>'success' = 'false', 'an edit to D0009 is refused: '||:'edit_bad');
SELECT pg_temp.nd_assert(:'edit_same'::jsonb->>'success' = 'true' AND :'edit_ok'::jsonb->>'success' = 'true' AND (SELECT disp_no = 'I0501' AND note = 'same number sent back' FROM public.dispatch WHERE id = :'disp_id'::uuid),
  'the stored number sent back is not checked, and an edit to I0501 is saved: '||:'edit_same'||' '||:'edit_ok');
-- A number that was stored under an earlier rule can still be sent back after the rule changed.
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"sequence","prefix":"J","width":5}') AS _ \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.update_dispatch_smart(:'disp_id'::uuid, '{"disp_no":"I0501","note":"old number, new rule"}'::jsonb, NULL) AS edit_legacy \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'edit_legacy'::jsonb->>'success' = 'true', 'a number from an earlier rule is kept on edit: '||:'edit_legacy');

-- The year in the refusal is the Kolkata day of the date sent (an edit that sends no date: of the stored one).
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"year","prefix":"D/"}') AS _ \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"BAD","disp_date":"2027-03-31T20:00:00Z"}', ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'nd-late') AS year_late,
       public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"BAD","disp_date":"2027-03-31T10:00:00Z"}', ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'nd-early') AS year_early,
       public.update_dispatch_smart(:'disp_id'::uuid, '{"disp_no":"BAD","disp_date":"2027-04-01"}'::jsonb, NULL) AS edit_sent_day,
       public.update_dispatch_smart(:'disp_id'::uuid, '{"disp_no":"BAD"}'::jsonb, NULL) AS edit_stored_day,
       public.update_dispatch_smart(:'disp_id'::uuid, '{"disp_no":"BAD","disp_date":"2027-03-31T20:00:00Z"}'::jsonb, NULL) AS edit_stamp \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'year_late'::jsonb->>'pattern' = 'D/27-28/####' AND :'year_early'::jsonb->>'pattern' = 'D/26-27/####',
  'the create names the year of the Kolkata day: 20:00 UTC on 31 March is already 1 April there: '||:'year_late'||' '||:'year_early');
SELECT pg_temp.nd_assert(:'edit_sent_day'::jsonb->>'pattern' = 'D/27-28/####' AND :'edit_stored_day'::jsonb->>'pattern' = 'D/26-27/####',
  'the edit names the year of the date sent, else of the stored date: '||:'edit_sent_day'||' '||:'edit_stored_day');
SELECT pg_temp.nd_assert(:'edit_stamp'::jsonb->>'pattern' = 'D/26-27/####',
  'the edit names the year of the date it stores: a full timestamp of 31 March is 31 March (26-27): '||:'edit_stamp');
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"sequence","prefix":"J","width":5}') AS _ \gset

-- 14. Two suggestions, one save: both phones are offered the same number, the first save keeps it, the second is refused by name
-- (nothing is reserved by a suggestion), and the next suggestion has moved on.
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters"}') AS _ \gset
DELETE FROM public.goodsreceived_trl WHERE gr_id IN (SELECT id FROM public.goodsreceived WHERE gr_no <> 'A0500');
DELETE FROM public.goodsreceived WHERE gr_no <> 'A0500';
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.suggest_document_number('grn')->>'number' AS phone_one, public.suggest_document_number('grn')->>'number' AS phone_two \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'phone_one' = 'A0501' AND :'phone_two' = 'A0501', 'two phones are offered the same number');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.nd_grn(:'phone_one') AS first_save, pg_temp.nd_grn(:'phone_two') AS second_save \gset
SELECT public.suggest_document_number('grn')->>'number' AS after_both \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'first_save'::jsonb->>'success' = 'true' AND :'second_save'::jsonb->>'success' = 'false' AND :'second_save'::jsonb->>'message' = 'GRN number already exists: A0501'
  AND :'after_both' = 'A0502', 'the first save keeps A0501, the second is refused by name, the next offer is A0502: '||:'first_save'||' '||:'second_save'||' '||:'after_both');
-- 14a. The check switch of a rule. Off: a number outside the rule is saved (FAS-shaped numbers at a facility whose rule is I####), a taken
-- number is still refused by name, a number over 20 characters is refused, and the rule still drives the suggestion. On again: the
-- numbers saved while it was off keep their numbers and are counted.
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters"}') AS _ \gset
SELECT pg_temp.nd_rule('dispatch', '{"scheme":"sequence","prefix":"I"}') AS _ \gset
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.set_document_numbering('dispatch', '{"scheme":"sequence","prefix":"I","check":false}') AS check_off,
       public.set_document_numbering('dispatch', '{"scheme":"sequence","prefix":"I","check":false}')->>'changed' AS check_off_again \gset
SELECT public.get_document_numbering() AS rules_off \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'check_off'::jsonb->>'changed' = 'true' AND :'check_off'::jsonb#>>'{rule,check}' = 'false' AND :'check_off'::jsonb#>>'{previous_rule,check}' = 'true'
  AND :'check_off_again' = 'false', 'the check is switched off, and off again changes nothing: '||:'check_off');
SELECT pg_temp.nd_assert((SELECT old_rule->>'check' = 'true' AND new_rule->>'check' = 'false' AND old_rule->>'prefix' = 'I' AND new_rule->>'prefix' = 'I'
      FROM warehouse_security.document_numbering_history WHERE document_type = 'dispatch' ORDER BY id DESC LIMIT 1),
  'the switch alone is a change, written to the history with the old and the new check');
SELECT pg_temp.nd_assert(:'rules_off'::jsonb#>>'{rules,1,check}' = 'false' AND :'rules_off'::jsonb#>>'{rules,0,check}' = 'true' AND :'rules_off'::jsonb#>>'{rules,2,check}' = 'true'
  AND :'rules_off'::jsonb#>>'{rules,1,not_following}' = '0', 'get_document_numbering shows each check and how many numbers do not follow: '||:'rules_off');
-- Dispatches saved with the check off: the create and the edit (I0777 is a number of the rule, so the suggestion follows it).
INSERT INTO public.dispatch(disp_no, customer_id) VALUES ('I0777', :'customer_id');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"G2674"}', ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'nd-off-1') AS off_g,
       public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"H0012A"}', ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'nd-off-2') AS off_h,
       public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"G2674"}', ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'nd-off-3') AS off_taken,
       public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"ABCDEFGHIJ0123456789X"}', ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'nd-off-4') AS off_long,
       public.update_dispatch_smart(:'disp_id'::uuid, '{"disp_no":"CLR0001"}'::jsonb, NULL) AS off_edit \gset
SELECT public.suggest_document_number('dispatch') AS off_suggest, public.get_next_dispatch_number() AS off_old_call \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'off_g'::jsonb->>'success' = 'true' AND :'off_h'::jsonb->>'success' = 'true' AND :'off_edit'::jsonb->>'success' = 'true'
  AND EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no = 'G2674') AND EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no = 'H0012A') AND EXISTS (SELECT 1 FROM public.dispatch WHERE disp_no = 'CLR0001'),
  'with the check off G2674, H0012A and an edit to CLR0001 are saved under the I rule: '||:'off_g'||' '||:'off_h'||' '||:'off_edit');
SELECT pg_temp.nd_assert(:'off_taken'::jsonb->>'success' = 'false' AND :'off_taken'::jsonb->>'reason' IS DISTINCT FROM 'NUMBER_FORMAT',
  'a taken number is still refused with the check off, by its own answer: '||:'off_taken');
SELECT pg_temp.nd_assert(:'off_long'::jsonb->>'reason' = 'NUMBER_FORMAT' AND :'off_long'::jsonb->>'message' = 'This number can have at most 20 characters' AND :'off_long'::jsonb->'pattern' = 'null'::jsonb
  AND NOT EXISTS (SELECT 1 FROM public.dispatch WHERE char_length(disp_no) > 20), 'a number over 20 characters is refused with the check off: '||:'off_long');
SELECT pg_temp.nd_assert(:'off_suggest'::jsonb->>'number' = 'I0778' AND :'off_suggest'::jsonb->>'hint' = 'I####' AND :'off_old_call' = 'I0778', 'the rule still drives the suggestion with the check off: '||:'off_suggest'||' '||:'off_old_call');
-- A GRN with the check off: the letter rule accepts anything under 20 characters too.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.set_document_numbering('grn', '{"scheme":"letters","check":false}')->'rule'->>'check' AS grn_off \gset
SELECT pg_temp.nd_grn('G1234A') AS grn_off_suffix, pg_temp.nd_grn('14/B/2027') AS grn_off_book, pg_temp.nd_grn('G1234A') AS grn_off_taken \gset
SELECT public.suggest_document_number('grn')->>'number' AS grn_off_suggest \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'grn_off' = 'false' AND :'grn_off_suffix'::jsonb->>'success' = 'true' AND :'grn_off_book'::jsonb->>'success' = 'true'
  AND :'grn_off_taken'::jsonb->>'message' = 'GRN number already exists: G1234A' AND :'grn_off_suggest' = 'A0502',
  'a GRN saves G1234A and 14/B/2027 with the check off; the second G1234A is refused by name; A0502 is still suggested: '||:'grn_off_suffix'||' '||:'grn_off_book');
-- The count of numbers that do not follow a rule, with examples (blank numbers are not counted).
SELECT pg_temp.nd_assert((SELECT warehouse_security.document_number_misfits(n) FROM warehouse_security.document_numbering n WHERE document_type = 'dispatch')
    = '{"count": 3, "examples": ["CLR0001", "G2674", "H0012A"]}'::jsonb, 'three dispatch numbers do not follow I####: '||(SELECT warehouse_security.document_number_misfits(n)::text FROM warehouse_security.document_numbering n WHERE document_type = 'dispatch'));
SELECT pg_temp.nd_assert((SELECT warehouse_security.document_number_misfits(n) FROM warehouse_security.document_numbering n WHERE document_type = 'invoice') = '{"count": 0, "examples": []}'::jsonb,
  'an invoice number is a whole number: nothing to count');
-- A blank number left from before the blank checks (they were added not validated) is not a number that fails a rule: it is not counted.
SAVEPOINT nd_blank;
ALTER TABLE public.dispatch DROP CONSTRAINT dispatch_disp_no_not_blank;
INSERT INTO public.dispatch(disp_no, customer_id) VALUES ('  ', :'customer_id');
SELECT pg_temp.nd_assert((SELECT warehouse_security.document_number_misfits(n)->>'count' = '3' FROM warehouse_security.document_numbering n WHERE document_type = 'dispatch'),
  'a blank dispatch number is not counted among the numbers that do not follow the rule');
ROLLBACK TO SAVEPOINT nd_blank;
-- Left out, the check stays as stored through a change of rule; on, it refuses again and counts what is kept.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.set_document_numbering('dispatch', '{"scheme":"sequence","prefix":"I","width":5}')->'rule'->>'check' AS check_kept,
       public.set_document_numbering('dispatch', '{"scheme":"sequence","prefix":"I","check":true}') AS check_on \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'check_kept' = 'false', 'a rule changed without the check keeps it off');
SELECT pg_temp.nd_assert(:'check_on'::jsonb->>'changed' = 'true' AND :'check_on'::jsonb#>>'{rule,check}' = 'true' AND :'check_on'::jsonb->>'not_following' = '3'
  AND :'check_on'::jsonb->>'existing_documents' = (SELECT count(*)::text FROM public.dispatch WHERE deleted_at IS NULL)
  AND (SELECT count(*) FROM public.dispatch WHERE disp_no IN ('G2674', 'H0012A', 'CLR0001')) = 3,
  'switching the check on where 3 numbers do not follow the rule is allowed; they keep their numbers: '||:'check_on');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(:'dispatch_data'::jsonb || '{"disp_no":"G9999"}', ARRAY[jsonb_build_object('gr_trl_id', :'lot_id', 'disp_qty', 1)], false, 0, 'nd-on-1') AS on_bad \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_document_numbering() AS rules_on \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'rules_on'::jsonb#>>'{rules,1,check}' = 'true' AND :'rules_on'::jsonb#>>'{rules,1,not_following}' = '3' AND :'rules_on'::jsonb#>>'{rules,0,check}' = 'false' AND :'rules_on'::jsonb#>>'{rules,0,not_following}' = '2',
  'get_document_numbering counts the dispatch numbers that do not follow the rule: '||:'rules_on');
SELECT pg_temp.nd_assert(:'on_bad'::jsonb->>'reason' = 'NUMBER_FORMAT' AND :'on_bad'::jsonb->>'pattern' = 'I####', 'with the check on again G9999 is refused: '||:'on_bad');
SELECT pg_temp.nd_assert((SELECT count(*) = 2 FROM warehouse_security.document_numbering_history WHERE document_type = 'dispatch' AND (old_rule->>'check')::boolean IS DISTINCT FROM (new_rule->>'check')::boolean),
  'the history holds both switches of the dispatch check');
-- Wrong values and a free rule: the switch is refused where it means nothing, and a free rule is checked (on) by definition.
SELECT pg_temp.nd_assert(NOT EXISTS (SELECT 1 FROM (VALUES
  ('grn', '{"scheme":"letters","check":"no"}', 'The check must be true (a number outside the rule is refused) or false (it is saved).'),
  ('grn', '{"scheme":"letters","check":1}', 'The check must be true (a number outside the rule is refused) or false (it is saved).'),
  ('grn', '{"scheme":"free","check":false}', 'check does not belong to a free rule for grn.'),
  ('invoice', '{"scheme":"year","check":false}', 'check does not belong to a year rule for invoice.')
  ) AS c(t, rule, expected)
  WHERE pg_temp.nd_call(format('SELECT warehouse_security.apply_document_numbering(%L, %L::jsonb, NULL)', c.t, c.rule))
        IS DISTINCT FROM jsonb_build_object('raised', c.expected, 'state', '22023')),
  'the check is refused where it means nothing, and when it is not true or false');
SELECT pg_temp.nd_rule('grn', '{"scheme":"free"}')->'rule'->>'check' AS free_check \gset
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters"}')->'rule'->>'check' AS back_check \gset
SELECT pg_temp.nd_assert(:'free_check' = 'true' AND :'back_check' = 'true', 'a free rule has its check on, and the next rule after it starts with it on');
SELECT pg_temp.nd_rule('grn', '{"scheme":"letters","check":true}') AS _ \gset

-- 15. The administrator check is in the body of set_document_numbering too: with an authorize_rpc that lets everyone through
-- (a database where its definition file has not been applied yet), a supervisor still cannot change a rule. Rolled back with the rest.
CREATE OR REPLACE FUNCTION warehouse_security.authorize_rpc(rpc text, args jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog'
  AS $$ BEGIN NULL; END $$;
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.nd_call($$SELECT public.set_document_numbering('grn', '{"scheme":"free"}')$$) AS body_supervisor,
       pg_temp.nd_call($$SELECT public.set_document_numbering('grn', '{"scheme":"year","prefix":"B/"}')::jsonb->>'changed'$$) AS body_supervisor_changed \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'body_supervisor'::jsonb = jsonb_build_object('raised', 'Administrator required', 'state', '42501') AND :'body_supervisor_changed'::jsonb->>'state' = '42501'
  AND (SELECT scheme FROM warehouse_security.document_numbering WHERE document_type = 'grn') = 'letters', 'the body refuses a supervisor even when authorize_rpc lets the call through: '||:'body_supervisor');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.nd_call($$SELECT public.set_document_numbering('grn', '{"scheme":"year","prefix":"B/"}')::jsonb->>'changed'$$) AS body_admin \gset
RESET ROLE;
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
SET LOCAL ROLE service_role;
SELECT pg_temp.nd_call($$SELECT public.set_document_numbering('grn', '{"scheme":"letters"}')::jsonb->>'changed'$$) AS body_service \gset
RESET ROLE;
SELECT pg_temp.nd_assert(:'body_admin'::jsonb->>'answer' = 'true' AND :'body_service'::jsonb->>'answer' = 'true', 'an administrator and the service role pass the body check: '||:'body_admin'||' '||:'body_service');
ROLLBACK;
\echo 'Document numbering: tables, grants, 20-character columns, every scheme, refusals, history, roles and a race passed.'
