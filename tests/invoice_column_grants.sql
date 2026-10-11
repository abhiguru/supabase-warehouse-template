-- Migration 48: the discount record (discount_reason, discount_set_by,
-- discount_set_at; migration 30) and the zero-charge record
-- (zero_charge_reason, zero_charge_set_by, zero_charge_set_at) are internal to
-- the warehouse. All app roles share the database role `authenticated`, and
-- the row policy lets a customer account read its own invoices, so the six
-- columns are kept out of the column-level SELECT that replaces the table-wide
-- one. No app role reads them from the table; administrators, supervisors and
-- staff get them from get_invoice_detail. Every other column is still read
-- directly, by name. Fictional data; runs only in migrations.sh's disposable,
-- network-disabled database.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.col_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'invoice column grants: %',label; END IF; END $$;
-- What a statement raised as [SQLSTATE, message], or NULL when it ran.
CREATE FUNCTION pg_temp.col_refusal(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement; EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_array(SQLSTATE, SQLERRM); END;
  RETURN NULL;
END $$;
-- The rows a statement returns, as a JSON array.
CREATE FUNCTION pg_temp.col_rows(statement text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE answer jsonb;
BEGIN
  EXECUTE format('SELECT COALESCE(jsonb_agg(to_jsonb(r)),''[]''::jsonb) FROM (%s) r', statement) INTO answer;
  RETURN answer;
END $$;
-- What every warehouse role sees: the six columns closed on the table, the
-- others open, and both records in get_invoice_detail.
CREATE FUNCTION pg_temp.col_warehouse_role(expected_role text, open_columns text, invoice uuid, author text, internal text[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE denied constant jsonb := jsonb_build_array('42501','permission denied for table invoice'); detail jsonb; c text;
BEGIN
  PERFORM pg_temp.col_assert(warehouse_security.active_role()=expected_role,'actual '||expected_role||' role');
  FOREACH c IN ARRAY internal LOOP
    PERFORM pg_temp.col_assert(pg_temp.col_refusal(format('SELECT %I FROM public.invoice',c))=denied,expected_role||' do not read '||c||' from the table');
  END LOOP;
  PERFORM pg_temp.col_assert(pg_temp.col_refusal('SELECT * FROM public.invoice')=denied,expected_role||' cannot select the whole row');
  PERFORM pg_temp.col_assert(pg_temp.col_rows(format('SELECT %s FROM public.invoice WHERE id=%L',open_columns,invoice))#>>'{0,gr_no}'='ICN1',
    expected_role||' read every other column directly');
  detail := public.get_invoice_detail(invoice)->'invoice';
  PERFORM pg_temp.col_assert(detail @> jsonb_build_object(
      'discount_reason','Handling surcharge agreed','discount_set_by',author,'discount_set_by_name','Internal Column Staff',
      'zero_charge_reason','Sample lot','zero_charge_set_by',author,'zero_charge_set_by_name','Internal Column Staff')
    AND (detail->>'discount_set_at')::timestamptz=now() AND (detail->>'zero_charge_set_at')::timestamptz=now(),
    expected_role||' get both records from get_invoice_detail: '||detail::text);
END $$;
CREATE FUNCTION pg_temp.col_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
 DECLARE c jsonb; l jsonb; claims jsonb;
 BEGIN
  c:=public.operator_prepare_otp(phone);
  PERFORM pg_temp.col_assert(c->>'success'='true','challenge prepared for '||phone);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  l:=public.operator_verify_otp(phone,c#>>'{data,otp_code}');
  PERFORM pg_temp.col_assert(l#>>'{data,action}'='login','login for '||phone);
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
SELECT warehouse_security.bootstrap_first_admin('9888888831','Internal Column Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888832','Internal Column Supervisor','supervisor',true,'approved'),
 (gen_random_uuid(),'919888888833','Internal Column Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888834','Internal Column Reader','customer',true,'approved'),
 (gen_random_uuid(),'919888888835','Internal Column Other Reader','customer',true,'approved');
SELECT id AS staff_profile FROM public.user_profiles WHERE mobile='919888888833' \gset
SELECT pg_temp.col_login('9888888831') AS admin_claims \gset
SELECT pg_temp.col_login('9888888832') AS supervisor_claims \gset
SELECT pg_temp.col_login('9888888833') AS staff_claims \gset
SELECT pg_temp.col_login('9888888834') AS customer_claims \gset
SELECT pg_temp.col_login('9888888835') AS other_claims \gset

-- The six internal columns, and every other column of the table by name (what
-- a direct read has to send now that `*` is refused).
SELECT ARRAY['discount_reason','discount_set_by','discount_set_at','zero_charge_reason','zero_charge_set_by','zero_charge_set_at'] AS internal \gset
SELECT string_agg(quote_ident(attname), ',' ORDER BY attnum) AS open_columns, count(*) AS open_count
 FROM pg_attribute WHERE attrelid='public.invoice'::regclass AND attnum>0 AND NOT attisdropped AND attname <> ALL(:'internal'::name[]) \gset
SELECT pg_temp.col_assert((SELECT count(*)=6 FROM pg_attribute WHERE attrelid='public.invoice'::regclass AND attname=ANY(:'internal'::name[]) AND NOT attisdropped)
 AND :open_count>=21,'the table has the six internal columns and the others');

-- Fixture, as the administrator: two customers, each with one login; one
-- one-time receipt of 20 bags for the first, dispatched in full. Staff invoice
-- it at a charge of 0 with a surcharge of 10, giving both reasons.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.col_assert(public.create_customer('Internal Column North','9888888836')->>'success'='true'
 AND public.create_customer('Internal Column South','9888888837')->>'success'='true','customers');
SELECT pg_temp.col_assert(public.create_item('Internal Column Garlic','Bag')->>'success'='true','catalog item');
SELECT id AS north FROM public.customers WHERE name='Internal Column North' \gset
SELECT id AS south FROM public.customers WHERE name='Internal Column South' \gset
SELECT id AS item_id FROM public.items WHERE name='Internal Column Garlic' \gset
SELECT pg_temp.col_assert(public.assign_customer_to_user('919888888834',:'north'::uuid,'Internal column fixture')
 AND public.assign_customer_to_user('919888888835',:'south'::uuid,'Internal column fixture'),'customer logins assigned');
SELECT pg_temp.col_assert(public.create_item_storage_price(p_item_id=>:'item_id'::uuid,p_price_type=>'monthly',p_unit_price=>5,
 p_weight_min=>0,p_weight_max=>100,p_labour_rate=>2,p_effective_from=>'2026-01-01',
 p_customer_id=>:'north'::uuid,p_tax_percent=>5)->>'success'='true','price');
SELECT pg_temp.col_assert(public.save_grn(p_gr_no=>'ICN1',p_date=>'2026-04-01T12:00:00Z',p_customer_id=>:'north'::uuid,
 p_customer_name=>'Internal Column North',p_pricing_mode=>'ONE_TIME',p_idempotency_key=>'internal-column-grn',
 p_items=>jsonb_build_array(jsonb_build_object('item_id',:'item_id','item_name','Internal Column Garlic',
 'packaging','Bag','qty',20,'weight',10,'rack','RIC')))->>'success'='true','receipt');
SELECT id AS grn_id FROM public.goodsreceived WHERE gr_no='ICN1' \gset
SELECT pg_temp.col_assert(public.create_dispatch_with_stock_check(jsonb_build_object('customer_id',:'north','customer_name','Internal Column North',
 'supervisor_id',:'admin_profile','supervisor_name','Internal Column Administrator','disp_date','2026-05-02','disp_no','ICN1'),
 ARRAY[jsonb_build_object('gr_trl_id',(SELECT t.id FROM public.goodsreceived_trl t WHERE t.gr_id=:'grn_id'::uuid),'disp_qty',20)],
 0,'internal-column-dispatch')->>'success'='true','dispatch');
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SELECT pg_temp.col_assert(warehouse_security.active_role()='staff','actual staff role');
SELECT public.save_invoice(NULL::uuid,
 jsonb_build_object('inv_fin_year',2026,'inv_no',20261201,'customer_id',:'north','customer_name','Internal Column North',
  'inv_date','2026-05-02T12:00:00Z','total',0,'tax_amount',0,'labour',0,'discount',-10,'duration_mode','legacy',
  'gr_id',:'grn_id','gr_no','ICN1','discount_reason','Handling surcharge agreed','zero_charge_reason','Sample lot'),
 ARRAY(SELECT jsonb_build_object('disp_trl_id',t.id,'grn_item_id',t.gr_trl_id,'duration',1,'charge',0,'tax',5,'labour_rate',2)
       FROM public.dispatch_trl t WHERE t.gr_id=:'grn_id'::uuid)) AS saved \gset
SELECT pg_temp.col_assert(:'saved'::jsonb->>'success'='true','staff save the invoice: '||:'saved');
SELECT (:'saved'::jsonb->>'invoice_id') AS invoice_id \gset
RESET ROLE;
SELECT pg_temp.col_assert((SELECT total=10 AND discount=-10 AND discount_reason='Handling surcharge agreed' AND discount_set_by=:'staff_profile'::uuid
   AND discount_set_at IS NOT NULL AND zero_charge_reason='Sample lot' AND zero_charge_set_by=:'staff_profile'::uuid AND zero_charge_set_at IS NOT NULL
  FROM public.invoice WHERE id=:'invoice_id'::uuid),'the invoice holds both records');

-- ---------------------------------------------------------------------------
-- 1. Catalog
-- ---------------------------------------------------------------------------
SELECT pg_temp.col_assert(NOT has_table_privilege('authenticated','public.invoice','SELECT')
 AND NOT has_any_column_privilege('authenticated','public.invoice','INSERT,UPDATE,REFERENCES')
 AND NOT has_table_privilege('authenticated','public.invoice','DELETE,TRUNCATE')
 AND NOT has_any_column_privilege('anon','public.invoice','SELECT,INSERT,UPDATE,REFERENCES')
 AND NOT has_any_column_privilege('public','public.invoice','SELECT,INSERT,UPDATE,REFERENCES'),
 'the app role has no table-wide SELECT and no write on invoice; anonymous callers have nothing');
SELECT pg_temp.col_assert((SELECT bool_and(has_column_privilege('authenticated','public.invoice',a.attname,'SELECT') = (a.attname <> ALL(:'internal'::name[])))
  FROM pg_attribute a WHERE a.attrelid='public.invoice'::regclass AND a.attnum>0 AND NOT a.attisdropped),
 'the app role may select every column except the six internal ones, and none of those');
SELECT pg_temp.col_assert(has_table_privilege('service_role','public.invoice','SELECT,INSERT,UPDATE,DELETE'),'the service role is unchanged');
SELECT pg_temp.col_assert((SELECT relrowsecurity FROM pg_class WHERE oid='public.invoice'::regclass)
 AND (SELECT count(*)=3 AND bool_and(cmd='SELECT') FROM pg_policies WHERE schemaname='public' AND tablename='invoice'),
 'the three row policies are unchanged');

-- ---------------------------------------------------------------------------
-- 2. A customer account, assigned to the invoice's customer
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'customer_claims',true);
SET LOCAL ROLE authenticated;
SELECT pg_temp.col_assert(warehouse_security.active_role()='customer' AND warehouse_security.owns_customer(:'north'::uuid),'actual customer role, assigned to North');
-- Not one of the six, in the select list, a filter or an ordering.
SELECT pg_temp.col_assert(pg_temp.col_refusal(statement)=jsonb_build_array('42501','permission denied for table invoice'),
 'a customer account is refused: '||statement||' -> '||COALESCE(pg_temp.col_refusal(statement)::text,'answered'))
FROM (SELECT format(shape,quote_ident(internal_column)) AS statement
      FROM unnest(:'internal'::text[]) AS internal_column,
           (VALUES ('SELECT %s FROM public.invoice'),('SELECT id FROM public.invoice WHERE %s IS NOT NULL'),
                   ('SELECT id FROM public.invoice ORDER BY %s'),('SELECT count(%s) FROM public.invoice')) AS shapes(shape)) AS s;
-- Nor the whole row, which holds them.
SELECT pg_temp.col_assert(pg_temp.col_refusal(statement)=jsonb_build_array('42501','permission denied for table invoice'),
 'a customer account is refused: '||statement||' -> '||COALESCE(pg_temp.col_refusal(statement)::text,'answered'))
FROM (VALUES ('SELECT * FROM public.invoice'),('SELECT i FROM public.invoice i'),('SELECT to_jsonb(i) FROM public.invoice i'),
  ('SELECT i.* FROM public.invoice_trl t JOIN public.invoice i ON i.id=t.invoice_id')) AS s(statement);
-- Every other column, by name: its own invoice, as before.
SELECT pg_temp.col_rows(format('SELECT %s FROM public.invoice',:'open_columns')) AS customer_rows \gset
SELECT pg_temp.col_assert(jsonb_array_length(:'customer_rows'::jsonb)=1 AND :'customer_rows'::jsonb#>>'{0,id}'=:'invoice_id'
 AND (:'customer_rows'::jsonb#>>'{0,total}')::numeric=10 AND (:'customer_rows'::jsonb#>>'{0,discount}')::numeric=-10
 AND :'customer_rows'::jsonb#>>'{0,inv_no}'='20261201' AND :'customer_rows'::jsonb#>>'{0,customer_id}'=:'north'
 AND (SELECT count(*)=:open_count FROM jsonb_object_keys(:'customer_rows'::jsonb->0))
 AND NOT (:'customer_rows'::jsonb->0 ?| :'internal'::text[]),
 'a customer account reads every other column of its own invoice: '||:'customer_rows');
-- The columns the invoice PDF function reads (functions/_shared/document-columns.ts).
SELECT pg_temp.col_assert(pg_temp.col_rows('SELECT id,customer_name,inv_date,inv_fin_year,labour,tax_amount,discount,total FROM public.invoice WHERE inv_no=20261201 AND inv_fin_year=2026 AND deleted_at IS NULL')
  #>>'{0,customer_name}'='Internal Column North','the invoice PDF header query is answered');
SELECT pg_temp.col_assert((SELECT count(*)=1 FROM public.invoice) AND (SELECT count(*)=1 FROM public.invoice WHERE id=:'invoice_id'::uuid),
 'counting its invoices still works');
-- The lines, whose row policy looks the invoice up, are still read.
SELECT pg_temp.col_assert((SELECT count(*)=1 AND bool_and(t.charge=0) FROM public.invoice_trl t WHERE t.invoice_id=:'invoice_id'::uuid)
 AND (SELECT count(*)=1 FROM public.invoice_trl t JOIN public.invoice i ON i.id=t.invoice_id WHERE i.total=10),'a customer account still reads its invoice lines');
-- The RPC: the invoice without either record, as since migration 41.
SELECT public.get_invoice_detail(:'invoice_id'::uuid) AS detail_customer \gset
SELECT pg_temp.col_assert(:'detail_customer'::jsonb->>'success'='true' AND (:'detail_customer'::jsonb#>>'{invoice,total}')::numeric=10
 AND NOT (:'detail_customer'::jsonb->'invoice' ?| ARRAY['discount_reason','discount_set_by','discount_set_by_name','discount_set_at',
   'zero_charge_reason','zero_charge_set_by','zero_charge_set_by_name','zero_charge_set_at']),
 'get_invoice_detail gives a customer account neither record: '||(:'detail_customer'::jsonb->'invoice')::text);
-- Still no write.
SELECT pg_temp.col_assert(pg_temp.col_refusal('UPDATE public.invoice SET notes=''changed''')->>0='42501'
 AND pg_temp.col_refusal('DELETE FROM public.invoice')->>0='42501','a customer account still cannot write the table');
-- A login of another customer reads no row, whatever the columns.
SELECT set_config('request.jwt.claims',:'other_claims',true);
SELECT pg_temp.col_assert(warehouse_security.active_role()='customer' AND NOT warehouse_security.owns_customer(:'north'::uuid),'actual customer role, assigned to South');
SELECT pg_temp.col_assert(pg_temp.col_rows(format('SELECT %s FROM public.invoice',:'open_columns'))='[]'::jsonb
 AND pg_temp.col_refusal('SELECT discount_reason FROM public.invoice')=jsonb_build_array('42501','permission denied for table invoice'),
 'another customer''s login reads no invoice row and none of the six columns');

-- ---------------------------------------------------------------------------
-- 3. Staff, supervisor, administrator: the same table grant, and the RPC
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SELECT pg_temp.col_warehouse_role('staff',:'open_columns',:'invoice_id'::uuid,:'staff_profile',:'internal'::text[]);
SELECT set_config('request.jwt.claims',:'supervisor_claims',true);
SELECT pg_temp.col_warehouse_role('supervisor',:'open_columns',:'invoice_id'::uuid,:'staff_profile',:'internal'::text[]);
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SELECT pg_temp.col_warehouse_role('admin',:'open_columns',:'invoice_id'::uuid,:'staff_profile',:'internal'::text[]);
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 4. The service role (Edge functions with the service key) reads the row
-- ---------------------------------------------------------------------------
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
SET LOCAL ROLE service_role;
SELECT pg_temp.col_assert((SELECT discount_reason='Handling surcharge agreed' AND zero_charge_reason='Sample lot' FROM public.invoice WHERE id=:'invoice_id'::uuid)
 AND (SELECT count(*)=1 FROM (SELECT * FROM public.invoice WHERE id=:'invoice_id'::uuid) whole),'the service role reads the whole row');
RESET ROLE;
ROLLBACK;
\echo 'Invoice column grants: the six internal columns are closed to every app role''s direct read, the rest and get_invoice_detail are unchanged.'
