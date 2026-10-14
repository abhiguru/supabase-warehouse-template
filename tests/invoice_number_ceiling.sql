-- Migration 73: invoice numbers run from 1 to 99999999 (INVOICE_NUMBER_MAX).
-- The three granted save paths refuse a number outside that range with WH422
-- "Invoice number must be between 1 and 99999999" before they write anything; an
-- edit may keep the invoice's own stored number. get_next_invoice_number
-- ignores numbers above the ceiling, so one such row no longer blocks its year,
-- and refuses the year with WH409 once 99999999 is taken. Fictional data; runs
-- only in migrations.sh's disposable, network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.inc_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'invoice number ceiling: %',label; END IF; END $$;
-- The answer of a call as jsonb, or what it raised.
CREATE FUNCTION pg_temp.inc_call(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer text;
BEGIN
  BEGIN EXECUTE statement INTO answer;
  EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('raised', SQLERRM, 'state', SQLSTATE); END;
  RETURN jsonb_build_object('answer', answer);
END $$;
CREATE FUNCTION pg_temp.inc_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.inc_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.inc_assert(l#>>'{data,action}'='login','login for '||phone);
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',r.id) INTO claims
   FROM public.user_profiles p JOIN warehouse_security.refresh_sessions r ON r.user_id=p.auth_user_id
   WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY r.created_at DESC LIMIT 1;
  RETURN claims;
 END $$;
INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST'
 WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888888851','Ceiling Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888852','Ceiling Staff','staff',true,'approved');
SELECT pg_temp.inc_login('9888888851') AS admin_claims \gset
SELECT pg_temp.inc_login('9888888852') AS staff_claims \gset

-- The helpers are internal: no app role may call them.
SELECT pg_temp.inc_assert(NOT has_function_privilege(r,'warehouse_security.check_invoice_number(text,uuid)','EXECUTE')
 AND NOT has_function_privilege(r,'warehouse_security.invoice_number_max()','EXECUTE'),'no '||r||' access to the helpers')
FROM unnest(ARRAY['anon','authenticated','service_role']) AS r;
SELECT pg_temp.inc_assert(warehouse_security.invoice_number_max()=99999999,'INVOICE_NUMBER_MAX is 99999999');

-- Fixture: receipt INCA of 10 bags, 4 dispatched on 2026-06-01. Financial
-- years 2097 to 2099 are far from today, so no other invoice is in them.
SELECT pg_temp.inc_assert((SELECT count(*)=0 FROM public.invoice WHERE inv_fin_year BETWEEN 2097 AND 2099),'the fixture years are empty');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.inc_assert(public.create_customer('Ceiling Customer','9888888853')->>'success'='true','customer');
SELECT pg_temp.inc_assert(public.create_item('Ceiling Onions','Bag')->>'success'='true','catalog item');
SELECT id AS customer_id FROM public.customers WHERE name='Ceiling Customer' \gset
SELECT id AS item_id FROM public.items WHERE name='Ceiling Onions' \gset
SELECT pg_temp.inc_assert(public.save_grn(p_gr_no=>'INCA',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'customer_id'::uuid,
 p_customer_name=>'Ceiling Customer',p_pricing_mode=>'MONTHLY',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Ceiling Onions','packaging','Bag','qty',10,'weight',5)))->>'success'='true','receipt INCA');
RESET ROLE;
SELECT id AS grn_id FROM public.goodsreceived WHERE gr_no='INCA' \gset
SELECT id AS grn_line FROM public.goodsreceived_trl WHERE gr_id=:'grn_id'::uuid \gset
SET LOCAL ROLE authenticated;
SELECT pg_temp.inc_assert(public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','INCD1','disp_date','2026-06-01T12:00:00Z',
 'customer_id',:'customer_id','customer_name','Ceiling Customer','supervisor_id',:'admin_profile','supervisor_name','Ceiling Administrator'),
 ARRAY[jsonb_build_object('gr_trl_id',:'grn_line','disp_qty',4)],0,'inc-dispatch')->>'success'='true','4 of 10 dispatched');
RESET ROLE;
SELECT id AS disp_line FROM public.dispatch_trl WHERE gr_trl_id=:'grn_line'::uuid \gset
-- The header and lines as the app sends them (three-argument save, update_invoice).
SELECT jsonb_build_object('inv_fin_year',2097,'customer_id',:'customer_id','customer_name','Ceiling Customer',
 'inv_date','2026-06-01','total',0,'tax_amount',0,'labour',0,'discount',0,'duration_mode','legacy',
 'gr_id',:'grn_id','gr_no','INCA') AS header \gset
SELECT jsonb_build_object('disp_trl_id',:'disp_line','grn_item_id',:'grn_line','duration',1,'charge',10,'tax',0,'labour_rate',2) AS line \gset
-- The one-argument save's body: the same fields with the lines inside.
SELECT (:'header'::jsonb || jsonb_build_object('items',jsonb_build_array(:'line'::jsonb))) AS single_body \gset

-- 1. Creating: a number outside 1..99999999 is refused, as staff (the role that
-- creates most invoices) and as administrator, before anything is written.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.inc_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT pg_temp.inc_assert(pg_temp.inc_call(format('SELECT public.save_invoice(NULL::uuid,%L::jsonb,ARRAY[%L::jsonb])',
   :'header'::jsonb || jsonb_build_object('inv_no',n.value),:'line'))
  =jsonb_build_object('raised','Invoice number must be between 1 and 99999999','state','WH422'),
 'three-argument save with inv_no '||n.value::text||' is refused with WH422: '
  ||pg_temp.inc_call(format('SELECT public.save_invoice(NULL::uuid,%L::jsonb,ARRAY[%L::jsonb])',
   :'header'::jsonb || jsonb_build_object('inv_no',n.value),:'line'))::text)
FROM (VALUES ('100000000'::jsonb),('2147483647'),('"9999999999"'),('0'),('-5')) AS n(value);
SELECT pg_temp.inc_call(format('SELECT public.save_invoice(%L::jsonb)',:'single_body'::jsonb || '{"inv_no":100000000}')) AS single_refused \gset
SELECT pg_temp.inc_assert((:'single_refused'::jsonb->>'answer')::jsonb->>'success'='false'
 AND (:'single_refused'::jsonb->>'answer')::jsonb->>'error'='Database error: Invoice number must be between 1 and 99999999 (SQLState: WH422)',
 'one-argument save with inv_no 100000000 is refused: '||:'single_refused');
-- The one-argument save also reads the number from header.invoice_number.
SELECT pg_temp.inc_call(format('SELECT public.save_invoice(%L::jsonb)',jsonb_build_object('header',
  jsonb_build_object('invoice_number','2097-100000000','financial_year','2097-98','grn_id',:'grn_id','grn_no','INCA',
   'customer_id',:'customer_id','customer_name','Ceiling Customer','invoice_date','2026-06-01','duration_mode','legacy'),
  'items',jsonb_build_array(:'line'::jsonb)))) AS header_refused \gset
SELECT pg_temp.inc_assert((:'header_refused'::jsonb->>'answer')::jsonb->>'error' LIKE '%Invoice number must be between 1 and 99999999 (SQLState: WH422)%',
 'one-argument save with header invoice number 2097-100000000 is refused: '||:'header_refused');
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SELECT pg_temp.inc_assert(warehouse_security.active_role()='admin','actual administrator role');
SELECT pg_temp.inc_assert(pg_temp.inc_call(format('SELECT public.save_invoice(NULL::uuid,%L::jsonb,ARRAY[%L::jsonb])',
   :'header'::jsonb || '{"inv_no":100000000}',:'line'))->>'state'='WH422','the administrator is refused too');
RESET ROLE;
SELECT pg_temp.inc_assert((SELECT count(*)=0 FROM public.invoice WHERE gr_id=:'grn_id'::uuid OR inv_fin_year=2097)
 AND (SELECT NOT invoiced FROM public.goodsreceived WHERE id=:'grn_id'::uuid),'no refused save wrote an invoice or marked the receipt');

-- 2. 99999999, the largest number, is saved.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.save_invoice(NULL::uuid,:'header'::jsonb || '{"inv_no":99999999}',ARRAY[:'line'::jsonb]) AS saved \gset
RESET ROLE;
SELECT pg_temp.inc_assert(:'saved'::jsonb->>'success'='true','inv_no 99999999 is saved: '||:'saved');
SELECT id AS invoice_id FROM public.invoice WHERE gr_id=:'grn_id'::uuid \gset
SELECT pg_temp.inc_assert((SELECT inv_no=99999999 AND inv_fin_year=2097 FROM public.invoice WHERE id=:'invoice_id'::uuid),'stored as 99999999 in 2097');

-- 3. Editing: a new number outside the range is refused and nothing changes;
-- the invoice's own number is kept; a number in the range is taken.
SET LOCAL ROLE authenticated;
SELECT public.update_invoice(:'invoice_id'::uuid,:'header'::jsonb || '{"inv_no":100000000,"notes":"must not stay"}',ARRAY[:'line'::jsonb]) AS edit_refused \gset
SELECT public.update_invoice(:'invoice_id'::uuid,:'header'::jsonb || '{"inv_no":99999999,"notes":"kept number"}',ARRAY[:'line'::jsonb]) AS edit_kept \gset
RESET ROLE;
SELECT pg_temp.inc_assert(:'edit_refused'::jsonb->>'success'='false'
 AND :'edit_refused'::jsonb->>'error'='Invoice number must be between 1 and 99999999'
 AND :'edit_refused'::jsonb->>'error_code'='WH422','an edit to 100000000 is refused: '||:'edit_refused');
SELECT pg_temp.inc_assert(:'edit_kept'::jsonb->>'success'='true','an edit that keeps 99999999 is saved: '||:'edit_kept');
SELECT pg_temp.inc_assert((SELECT inv_no=99999999 AND notes='kept number' FROM public.invoice WHERE id=:'invoice_id'::uuid),'the refused edit changed nothing');

-- 4. A year holding 99999999 has no number left: WH409, as before for 2147483647.
SET LOCAL ROLE authenticated;
SELECT pg_temp.inc_assert(pg_temp.inc_call('SELECT public.get_next_invoice_number(2097)')
 =jsonb_build_object('raised','No invoice number is left in financial year 2097','state','WH409'),
 'a year whose highest number is 99999999 is refused: '||pg_temp.inc_call('SELECT public.get_next_invoice_number(2097)')::text);
SELECT public.update_invoice(:'invoice_id'::uuid,:'header'::jsonb || '{"inv_no":20260929}',ARRAY[:'line'::jsonb]) AS edit_in_range \gset
RESET ROLE;
SELECT pg_temp.inc_assert(:'edit_in_range'::jsonb->>'success'='true' AND (SELECT inv_no=20260929 FROM public.invoice WHERE id=:'invoice_id'::uuid),
 'an edit to 20260929, a year-prefixed number, is saved: '||:'edit_in_range');

-- 5. Rows above the ceiling, as the dev stack had one (written by the database
-- owner, as earlier data or the service key could): they do not count.
--   2097  20260929 (the invoice above), 100000000 and 2147483647 live  -> 20260930
--   2098  2147483647 only                                             -> 1
--   2099  99999999 live, 2147483647 deleted                           -> refused (99999999 is the ceiling)
INSERT INTO public.invoice(inv_fin_year,inv_no,gr_id,gr_no,customer_id,customer_name,inv_date,labour,tax_amount,total,discount,deleted_at)
SELECT f.fin_year,f.number,gen_random_uuid(),'INCOLD',gen_random_uuid(),'Ceiling Legacy Customer',now(),0,0,0,0,
       CASE WHEN f.deleted THEN now() END
FROM (VALUES (2097,100000000,false),(2097,2147483647,false),(2098,2147483647,false),
             (2099,99999999,false),(2099,2147483647,true)) AS f(fin_year,number,deleted);
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.inc_assert(pg_temp.inc_call(c.statement)=jsonb_build_object('answer',c.expected),
  c.statement||' -> '||pg_temp.inc_call(c.statement)::text||', expected '||c.expected)
FROM (VALUES ('SELECT public.get_next_invoice_number(2097)','20260930'),
             ('SELECT public.get_next_invoice_number(p_fin_year => 2098)','1')) AS c(statement,expected);
SELECT pg_temp.inc_assert(pg_temp.inc_call('SELECT public.get_next_invoice_number(2099)')->>'state'='WH409','2099 is full at 99999999');
RESET ROLE;

-- 6. An invoice saved before migration 73 with a number above the ceiling can
-- still be edited while it keeps that number, but not given another such
-- number; a number in the range is taken.
UPDATE public.invoice SET inv_no=123456789 WHERE id=:'invoice_id'::uuid;
SET LOCAL ROLE authenticated;
SELECT public.update_invoice(:'invoice_id'::uuid,:'header'::jsonb || '{"inv_no":123456789,"notes":"legacy kept"}',ARRAY[:'line'::jsonb]) AS legacy_kept \gset
SELECT public.update_invoice(:'invoice_id'::uuid,:'header'::jsonb || '{"inv_no":987654321}',ARRAY[:'line'::jsonb]) AS legacy_moved \gset
RESET ROLE;
SELECT pg_temp.inc_assert(:'legacy_kept'::jsonb->>'success'='true'
 AND (SELECT inv_no=123456789 AND notes='legacy kept' FROM public.invoice WHERE id=:'invoice_id'::uuid),'a legacy number may be kept: '||:'legacy_kept');
SELECT pg_temp.inc_assert(:'legacy_moved'::jsonb->>'error_code'='WH422'
 AND (SELECT inv_no=123456789 FROM public.invoice WHERE id=:'invoice_id'::uuid),'but not moved to another number above the ceiling: '||:'legacy_moved');
SET LOCAL ROLE authenticated;
SELECT public.get_next_invoice_number(2097) AS suggested \gset
SELECT public.update_invoice(:'invoice_id'::uuid,:'header'::jsonb || jsonb_build_object('inv_no',:'suggested'::integer),ARRAY[:'line'::jsonb]) AS renumbered \gset
RESET ROLE;
SELECT pg_temp.inc_assert(:'suggested'='1' AND :'renumbered'::jsonb->>'success'='true'
 AND (SELECT inv_no=1 FROM public.invoice WHERE id=:'invoice_id'::uuid),
 'with 20260929 gone the suggestion is 1 and it can be saved: '||:'suggested'||' '||:'renumbered');

-- 6b. Whitespace the integer cast accepts (tab, newline, CR, VT, FF) is stripped by the check,
-- so a padded out-of-range number is refused like the plain one (migration 79).
SET LOCAL ROLE authenticated;
SELECT pg_temp.inc_assert(pg_temp.inc_call(format('SELECT public.save_invoice(NULL::uuid,%L::jsonb,ARRAY[%L::jsonb])',
   :'header'::jsonb || jsonb_build_object('inv_no',n.value),:'line'))
  =jsonb_build_object('raised','Invoice number must be between 1 and 99999999','state','WH422'),
 'padded inv_no '||to_jsonb(n.value)::text||' is refused with WH422: '
  ||pg_temp.inc_call(format('SELECT public.save_invoice(NULL::uuid,%L::jsonb,ARRAY[%L::jsonb])',
   :'header'::jsonb || jsonb_build_object('inv_no',n.value),:'line'))::text)
FROM (VALUES (E'\t100000000'),(E'\n0'),(E'\r-5'),(E'100000000\n'),(E'\v0'),(E'\f0\f')) AS n(value);
RESET ROLE;

-- 7. The check sits after the guard and before the first write (or the call
-- that writes) in each path.
SELECT pg_temp.inc_assert(position('warehouse_security.authorize_rpc' IN d) < position('warehouse_security.check_invoice_number' IN d)
 AND position('warehouse_security.check_invoice_number' IN d) < (SELECT min(position(w IN d)) FROM unnest(ARRAY['INSERT INTO','UPDATE ',
   'DELETE FROM','claim_invoice_lines','save_invoice_internal(']) AS w WHERE position(w IN d) > 0),
 'guard, then the number check, then the first write in '||f::text)
FROM (SELECT f, pg_get_functiondef(f) AS d FROM unnest(ARRAY['public.save_invoice(jsonb)','public.save_invoice(uuid,jsonb,jsonb[])',
  'public.update_invoice(uuid,jsonb,jsonb[])']::regprocedure[]) AS f) AS fns;
ROLLBACK;
\echo 'Invoice number ceiling: save refusals, edits, legacy numbers and next-number checks passed.'
