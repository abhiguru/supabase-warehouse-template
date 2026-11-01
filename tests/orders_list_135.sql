-- Migration 135: get_orders_list reads the page first. Pins what the view-based list gave (ids, order, every key and value of
-- every order object, the count), and the new rules: the page size is clamped to 1..200 and the offset to 0 or more, and p_user_id
-- counts only for service_role. The reference is v_orders_list (unchanged) read with the old ORDER BY and the old object.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database. Every row rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.ol_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'orders list 135: %',label; END IF; END $$;
CREATE FUNCTION pg_temp.ol_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE challenge jsonb; login jsonb; claims jsonb;
BEGIN
  challenge := public.operator_prepare_otp(phone);
  PERFORM pg_temp.ol_assert(challenge->>'success'='true','ordinary challenge');
  PERFORM public.operator_finish_otp((challenge#>>'{data,request_id}')::uuid,true,'mock-provider-only');
  login := public.operator_verify_otp(phone,challenge#>>'{data,otp_code}');
  PERFORM pg_temp.ol_assert(login#>>'{data,action}'='login','ordinary login');
  SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)
    INTO claims FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id
    WHERE p.mobile=warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;
-- The ids of a list answer, in order.
CREATE FUNCTION pg_temp.ol_ids(answer jsonb) RETURNS uuid[] LANGUAGE sql IMMUTABLE AS $$
  SELECT COALESCE(array_agg((o->>'id')::uuid ORDER BY n),'{}') FROM jsonb_array_elements(answer#>'{data,orders}') WITH ORDINALITY AS t(o,n) $$;

INSERT INTO warehouse_security.auth_config(key,value) VALUES
 ('jwt_secret','isolated-test-secret-not-for-any-deployment-12345'),
 ('auth_mode','operator'),('demo_auth_enabled','false')
 ON CONFLICT(key) DO UPDATE SET value=excluded.value;
UPDATE public.sms_config SET provider='msg91',production_mode=true,msg91_auth_key='isolated-test-key',
 msg91_template_id='000000000000000000000001',msg91_pe_id='0000000000000000001',msg91_sender_id='CITEST';
SELECT warehouse_security.bootstrap_first_admin('9888888831','Orders List Administrator') AS admin_user \gset
SELECT id AS admin_profile FROM public.user_profiles WHERE auth_user_id=:'admin_user'::uuid \gset
INSERT INTO public.user_profiles(auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 (gen_random_uuid(),'919888888832','Orders List Staff','staff',true,'approved'),
 (gen_random_uuid(),'919888888833','Orders List Reader','customer',true,'approved');
SELECT pg_temp.ol_login('9888888831') AS admin_claims \gset
SELECT pg_temp.ol_login('9888888832') AS staff_claims \gset
SELECT pg_temp.ol_login('9888888833') AS reader_claims \gset

-- Fixture. One order per customer. Rows are written with the triggers off, so the times below are the times stored.
--   t1  pending lines, updated 1 h ago          t2  pending lines, updated 3 h ago (an item only this order has)
--   t3  only a fulfilled line, latest dispatch 2 h ago     t4  only a cancelled line, dispatches 5 h and 9 h ago
--   t5  only a fulfilled line, no dispatch (sorts last)    t6  only a fulfilled line, a dispatch of ANOTHER customer (ignored)
--   t7  pending line + a cancelled line with a word only that line has (a cancelled line is not searched)
--   t8  no line at all (not listed)             t9  deleted order      t10 order of a deleted customer
SET LOCAL session_replication_role = replica;
CREATE TEMP TABLE f135(tag text PRIMARY KEY, customer_id uuid, order_id uuid);
INSERT INTO public.customers(name,mobile,city)
 SELECT 'Ol135 Customer '||t, '98888889'||lpad(n::text,2,'0'),
        CASE t WHEN 't1' THEN 'Pune135' WHEN 't2' THEN 'Surat135' ELSE 'Anand135' END
 FROM unnest(ARRAY['t1','t2','t3','t4','t5','t6','t7','t8','t9','t10','x']) WITH ORDINALITY AS u(t,n);
UPDATE public.customers SET deleted_at=now() WHERE name='Ol135 Customer t10';
UPDATE public.customers SET active=false WHERE name='Ol135 Customer t5';
UPDATE public.customers SET city=NULL WHERE name='Ol135 Customer t6';
INSERT INTO f135(tag,customer_id,order_id)
 SELECT substr(name,length('Ol135 Customer ')+1), id, gen_random_uuid() FROM public.customers WHERE name LIKE 'Ol135 Customer %';
INSERT INTO public.orders(id,order_no,order_date,requested_dispatch_date,status,priority,customer_id,customer_name,created_at,updated_at,created_by,updated_by,deleted_at)
 SELECT f.order_id,'OL135-'||f.tag,now(),now(),'OPEN','normal',f.customer_id,'Ol135 Customer '||f.tag,
        now()-interval '1 day'-(CASE f.tag WHEN 't3' THEN interval '2 min' WHEN 't6' THEN interval '10 min' ELSE interval '0' END),
        now()-(CASE f.tag WHEN 't1' THEN interval '1 hour' WHEN 't2' THEN interval '3 hours' WHEN 't7' THEN interval '3 hours' ELSE interval '30 minutes' END),
        :'admin_profile'::uuid, CASE f.tag WHEN 't1' THEN :'admin_profile'::uuid END,
        CASE f.tag WHEN 't9' THEN now() END
 FROM f135 f;
-- t7 and t2 share an updated_at and a customer-created time on purpose: the tie falls to created_at, then to the id.
UPDATE public.orders SET created_at=(SELECT created_at FROM public.orders WHERE order_no='OL135-t2') WHERE order_no='OL135-t7';
INSERT INTO public.order_items(order_id,order_no,requested_quantity,fulfilled_quantity,grn_items_id,grn_items_item_id,grn_items_item_name,grn_items_package_mark,
   grn_items_packaging,grn_items_rack,grn_items_weight,grns_id,grns_gr_no,grns_date,grns_customer_id,grns_customer_name,item_status,sort_order,created_at,updated_at)
 SELECT f.order_id,'OL135-'||f.tag,s.qty,CASE WHEN s.st='fulfilled' THEN s.qty ELSE 0 END,gen_random_uuid(),gen_random_uuid(),s.nm,s.pm,'Bag','R1',10,gen_random_uuid(),s.gr,now(),f.customer_id,'Ol135 Customer '||f.tag,s.st,s.so,
        now()-interval '2 days'+make_interval(secs=>s.so),now()
 FROM f135 f JOIN (VALUES
   ('t1','Ol135 Onion','PM-Alpha','GRA135','pending',4,2),
   ('t1','Ol135 Garlic','PM-Beta','GRA135','pending',3,1),
   ('t1','Ol135 Beans','PM-Gamma','GRB135','fulfilled',2,3),
   ('t2','Ol135 Saffron Bulb','PM-Zebra','GRC135','pending',6,1),
   ('t3','Ol135 Rice','PM-Delta','GRD135','fulfilled',5,1),
   ('t4','Ol135 Wheat','PM-Eps','GRE135','cancelled',1,1),
   ('t5','Ol135 Millet','PM-Zeta','GRF135','fulfilled',2,1),
   ('t6','Ol135 Barley','PM-Eta','GRG135','fulfilled',2,1),
   ('t7','Ol135 Maize','PM-Theta','GRH135','pending',7,1),
   ('t7','Ol135 Cancelledword','PM-Iota','GRI135','cancelled',1,2),
   ('t9','Ol135 Deleted Order Item','PM-Kappa','GRJ135','pending',1,1),
   ('x','Tie135 Maize','PM-Tie','GRT135','fulfilled',1,1),
   ('t10','Ol135 Deleted Customer Item','PM-Lambda','GRK135','pending',1,1)
 ) AS s(tag,nm,pm,gr,st,qty,so) ON s.tag=f.tag;
INSERT INTO public.dispatch(disp_no,customer_id,customer_name,source_order_id,created_at)
 SELECT d.no, f.customer_id, 'Ol135 Customer '||f.tag, f.order_id, now()-d.ago
 FROM f135 f JOIN (VALUES ('t3','I9001',interval '2 hours'),('t4','I9002',interval '5 hours'),('t4','I9003',interval '9 hours'),
                          ('t1','I9004',interval '7 hours')) AS d(tag,no,ago) ON d.tag=f.tag;
-- Customer x has an order of its own (named Tie135, so the Ol135 filter leaves it out) with two dispatches of exactly the same time:
-- the lower id must always be the one shown (the old view picked either).
INSERT INTO public.dispatch(id,disp_no,customer_id,customer_name,source_order_id,created_at)
 SELECT v.id::uuid, v.no, f.customer_id, 'Tie135', f.order_id, now()-interval '4 hours' FROM f135 f,
  (VALUES ('ffffffff-ffff-ffff-ffff-ffffffffffff','I9007'),('00000000-0000-0000-0000-000000000001','I9006')) v(id,no) WHERE f.tag='x';
UPDATE public.customers SET name='Tie135 Customer x' WHERE name='Ol135 Customer x';
-- t6's only dispatch belongs to customer x (not the order's customer): the list ignores it.
INSERT INTO public.dispatch(disp_no,customer_id,customer_name,source_order_id,created_at)
 SELECT 'I9005', x.customer_id, 'Ol135 Customer x', t6.order_id, now()-interval '1 hour' FROM f135 x, f135 t6 WHERE x.tag='x' AND t6.tag='t6';
SET LOCAL session_replication_role = origin;
ANALYZE public.orders; ANALYZE public.order_items; ANALYZE public.dispatch;
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
 SELECT p.id,f.customer_id,true FROM public.user_profiles p, f135 f WHERE p.mobile='919888888833' AND f.tag IN ('t1','t3');
SELECT customer_id AS cust_t4 FROM f135 WHERE tag='t4' \gset
SELECT customer_id AS cust_t2 FROM f135 WHERE tag='t2' \gset

-- The reference: the old list, read from the view with the old filters, the old ORDER BY and the old object.
CREATE FUNCTION pg_temp.ol_reference(p_name text DEFAULT 'Ol135', p_has_items boolean DEFAULT NULL, p_search text DEFAULT NULL, p_customers uuid[] DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT COALESCE(jsonb_agg(obj ORDER BY ord),'[]') FROM (
    SELECT row_number() OVER (ORDER BY CASE WHEN m.total_items=0 THEN m.dispatch_created_at ELSE m.updated_at END DESC NULLS LAST, m.created_at DESC, m.order_id) AS ord,
      jsonb_build_object('id',m.order_id,'customer_id',m.customer_id,
        'customer',jsonb_build_object('id',m.customer_id,'name',m.customer_name_detail,'active',(SELECT c.active FROM public.customers c WHERE c.id=m.customer_id),'city',m.customer_city,'mobile',m.customer_mobile),
        'status',m.status,'updated_by',m.updated_by,'updated_by_name',COALESCE(m.updated_by_display_name,m.updated_by_name),
        'item_count',m.total_items,'quantity_sum',m.total_quantity,'items',m.items_jsonb,'created_at',m.created_at,'updated_at',m.updated_at,
        'dispatch_id',m.dispatch_id,'dispatch_no',m.dispatch_no,'dispatch_created_at',m.dispatch_created_at) AS obj
    FROM public.v_orders_list m
    WHERE m.customer_name_detail ILIKE '%'||p_name||'%'
      AND NOT EXISTS (SELECT 1 FROM public.customers dc WHERE dc.id=m.customer_id AND dc.deleted_at IS NOT NULL)
      AND (p_customers IS NULL OR m.customer_id=ANY(p_customers))
      AND jsonb_array_length(m.items_jsonb)>0
      AND (p_has_items IS NULL OR (p_has_items AND m.total_items>0) OR (NOT p_has_items AND m.total_items=0))
      AND NOT EXISTS (SELECT 1 FROM unnest(warehouse_security.search_terms(p_search)) AS term
        WHERE NOT (COALESCE(m.customer_name_detail,'') ILIKE term OR COALESCE(m.customer_city,'') ILIKE term
          OR EXISTS (SELECT 1 FROM jsonb_array_elements(m.items_jsonb) AS line
            WHERE line->>'item_status'='pending' AND (COALESCE(line->>'grn_items_item_name','') ILIKE term OR COALESCE(line->>'grn_items_package_mark','') ILIKE term OR COALESCE(line->>'grns_gr_no','') ILIKE term))))
  ) r $$;

-- 1. The fixture covers every sort branch, and the reference itself is what the comment above says.
SELECT pg_temp.ol_reference() AS ref_all \gset
SELECT pg_temp.ol_assert(jsonb_array_length(:'ref_all'::jsonb)=7,'reference lists 7 orders (t1 t2 t3 t4 t5 t6 t7): '||jsonb_array_length(:'ref_all'::jsonb));
SELECT pg_temp.ol_assert((SELECT array_agg(f.tag ORDER BY n) FROM jsonb_array_elements(:'ref_all'::jsonb) WITH ORDINALITY AS t(o,n) JOIN f135 f ON f.order_id=(o->>'id')::uuid)
  = ARRAY['t1','t3','t7','t2','t4','t5','t6']
  OR (SELECT array_agg(f.tag ORDER BY n) FROM jsonb_array_elements(:'ref_all'::jsonb) WITH ORDINALITY AS t(o,n) JOIN f135 f ON f.order_id=(o->>'id')::uuid)
  = ARRAY['t1','t3','t2','t7','t4','t5','t6'],'the fixture sorts as designed (pending orders by updated_at mixed with empty ones by dispatch time, none last, ties by created_at then id)');

-- 2. As the administrator: same ids, same order, same objects, same count, for every filter.
SELECT set_config('request.jwt.claims',:'admin_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_orders_list(p_customer_name=>'Ol135') AS a_all \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_has_items=>true) AS a_true \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_has_items=>false) AS a_false \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_search=>'saffron') AS a_item \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_search=>'PM-Theta') AS a_pm \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_search=>'grd135') AS a_gr \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_search=>'grc135') AS a_grpos \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_search=>'surat135') AS a_city \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_search=>'customer t3') AS a_name \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_search=>'saffron pune135') AS a_mix_none \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_search=>'saffron surat135') AS a_mix_both \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_search=>'cancelledword') AS a_cancelled \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_search=>'onion garlic beans') AS a_three \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_search=>'onion garlic') AS a_two \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_limit=>1) AS a_lim1 \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_limit=>3,p_offset=>2) AS a_page2 \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_limit=>3,p_offset=>6) AS a_last \gset
SELECT public.get_orders_list(p_customer_id=>:'cust_t4'::uuid) AS a_one \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_limit=>100000) AS a_big \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_limit=>0) AS a_zero \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_limit=>-5,p_offset=>-3) AS a_neg \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_offset=>2147483600) AS a_huge \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_offset=>7) AS a_past \gset
SELECT public.get_orders_list(p_customer_name=>'oL135 CUSTOMER T2') AS a_case \gset
SELECT public.get_orders_list(p_customer_name=>'Tie135') AS a_tie \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_search=>'anand135') AS a_nullcity \gset
SELECT public.get_orders_list(p_limit=>NULL,p_offset=>NULL,p_customer_name=>'Ol135') AS a_null \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_user_id=>gen_random_uuid()) AS a_foreign_user \gset
RESET ROLE;

SELECT pg_temp.ol_assert(:'a_all'::jsonb#>'{data,orders}'=:'ref_all'::jsonb,'every order object equals the old object, in the old order');
SELECT pg_temp.ol_assert(:'a_all'::jsonb->>'success'='true' AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(:'a_all'::jsonb) k)=ARRAY['data','success']
  AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(:'a_all'::jsonb->'data') k)=ARRAY['orders','pagination']
  AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(:'a_all'::jsonb#>'{data,pagination}') k)=ARRAY['has_more','limit','offset','total_count'],'answer shape');
SELECT pg_temp.ol_assert((SELECT bool_and((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(o) k)=
  ARRAY['created_at','customer','customer_id','dispatch_created_at','dispatch_id','dispatch_no','id','item_count','items','quantity_sum','status','updated_at','updated_by','updated_by_name'])
  FROM jsonb_array_elements(:'a_all'::jsonb#>'{data,orders}') o),'every order object has the same keys');
SELECT pg_temp.ol_assert((:'a_all'::jsonb#>>'{data,pagination,total_count}')::int=7 AND NOT (:'a_all'::jsonb#>>'{data,pagination,has_more}')::boolean
  AND (:'a_all'::jsonb#>>'{data,pagination,limit}')::int=50 AND (:'a_all'::jsonb#>>'{data,pagination,offset}')::int=0,'default pagination');
SELECT pg_temp.ol_assert(:'a_true'::jsonb#>'{data,orders}'=pg_temp.ol_reference(p_has_items=>true) AND jsonb_array_length(:'a_true'::jsonb#>'{data,orders}')=3,'p_has_items true: t1 t2 t7');
SELECT pg_temp.ol_assert(:'a_false'::jsonb#>'{data,orders}'=pg_temp.ol_reference(p_has_items=>false) AND jsonb_array_length(:'a_false'::jsonb#>'{data,orders}')=4,'p_has_items false: the 4 orders without a pending line');
SELECT pg_temp.ol_assert((:'a_false'::jsonb#>>'{data,orders,0,dispatch_no}')='I9001'
  AND (:'a_false'::jsonb#>>'{data,orders,1,dispatch_no}')='I9002','empty-branch orders sort by their latest dispatch (I9001 2 h before I9002 5 h; the older I9003 is not the one shown)');
SELECT pg_temp.ol_assert((:'a_false'::jsonb#>>'{data,orders,3,dispatch_no}') IS NULL AND (:'a_false'::jsonb#>>'{data,orders,2,dispatch_no}') IS NULL,'orders with no (own) dispatch sort last and show none');
SELECT pg_temp.ol_assert((SELECT ids=ARRAY[(SELECT order_id FROM f135 WHERE tag='t2')] FROM (SELECT pg_temp.ol_ids(:'a_item'::jsonb) AS ids) q) AND :'a_item'::jsonb#>'{data,orders}'=pg_temp.ol_reference(p_search=>'saffron'),'search finds a word only an item has');
SELECT pg_temp.ol_assert(pg_temp.ol_ids(:'a_pm'::jsonb)=ARRAY[(SELECT order_id FROM f135 WHERE tag='t7')] AND :'a_pm'::jsonb#>'{data,orders}'=pg_temp.ol_reference(p_search=>'PM-Theta'),'search finds a package mark');
SELECT pg_temp.ol_assert(pg_temp.ol_ids(:'a_grpos'::jsonb)=ARRAY[(SELECT order_id FROM f135 WHERE tag='t2')] AND :'a_grpos'::jsonb#>'{data,orders}'=pg_temp.ol_reference(p_search=>'grc135'),'search finds a receipt number of a pending line');
SELECT pg_temp.ol_assert(jsonb_array_length(:'a_gr'::jsonb#>'{data,orders}')=0
  AND :'a_gr'::jsonb#>'{data,orders}'=pg_temp.ol_reference(p_search=>'grd135'),'a gr_no on a line that is not pending is not searched (as before)');
SELECT pg_temp.ol_assert(pg_temp.ol_ids(:'a_city'::jsonb)=ARRAY[(SELECT order_id FROM f135 WHERE tag='t2')] AND :'a_city'::jsonb#>'{data,orders}'=pg_temp.ol_reference(p_search=>'surat135'),'search finds a word only the customer has (city)');
SELECT pg_temp.ol_assert(pg_temp.ol_ids(:'a_name'::jsonb)=ARRAY[(SELECT order_id FROM f135 WHERE tag='t3')]
  AND :'a_name'::jsonb#>'{data,orders}'=pg_temp.ol_reference(p_search=>'customer t3'),'search finds the customer name');
SELECT pg_temp.ol_assert(jsonb_array_length(:'a_mix_none'::jsonb#>'{data,orders}')=0 AND :'a_mix_none'::jsonb#>'{data,orders}'=pg_temp.ol_reference(p_search=>'saffron pune135'),'every word must match: an item word and another customer''s city find nothing');
SELECT pg_temp.ol_assert(pg_temp.ol_ids(:'a_mix_both'::jsonb)=ARRAY[(SELECT order_id FROM f135 WHERE tag='t2')],'every word must match: an item word and its own customer''s city find the order');
SELECT pg_temp.ol_assert(jsonb_array_length(:'a_cancelled'::jsonb#>'{data,orders}')=0 AND :'a_cancelled'::jsonb#>'{data,orders}'=pg_temp.ol_reference(p_search=>'cancelledword'),'a cancelled line is not searched');
SELECT pg_temp.ol_assert(pg_temp.ol_ids(:'a_two'::jsonb)=ARRAY[(SELECT order_id FROM f135 WHERE tag='t1')] AND :'a_two'::jsonb#>'{data,orders}'=pg_temp.ol_reference(p_search=>'onion garlic'),'two words over two pending lines of one order');
SELECT pg_temp.ol_assert(jsonb_array_length(:'a_three'::jsonb#>'{data,orders}')=0 AND :'a_three'::jsonb#>'{data,orders}'=pg_temp.ol_reference(p_search=>'onion garlic beans'),'a third word that only a fulfilled line has finds nothing');
SELECT pg_temp.ol_assert(jsonb_array_length(:'a_lim1'::jsonb#>'{data,orders}')=1 AND (:'a_lim1'::jsonb#>>'{data,pagination,has_more}')::boolean
  AND (:'a_lim1'::jsonb#>>'{data,pagination,total_count}')::int=7 AND pg_temp.ol_ids(:'a_lim1'::jsonb)=(pg_temp.ol_ids(:'a_all'::jsonb))[1:1],'limit 1: first order, has_more, total 7');
SELECT pg_temp.ol_assert(pg_temp.ol_ids(:'a_page2'::jsonb)=(pg_temp.ol_ids(:'a_all'::jsonb))[3:5] AND (:'a_page2'::jsonb#>>'{data,pagination,has_more}')::boolean
  AND (:'a_page2'::jsonb#>>'{data,pagination,offset}')::int=2,'limit 3 offset 2: orders 3 to 5, has_more');
SELECT pg_temp.ol_assert(pg_temp.ol_ids(:'a_last'::jsonb)=(pg_temp.ol_ids(:'a_all'::jsonb))[7:7] AND NOT (:'a_last'::jsonb#>>'{data,pagination,has_more}')::boolean,'last page: the 7th order, no has_more');
SELECT pg_temp.ol_assert(pg_temp.ol_ids(:'a_one'::jsonb)=ARRAY[(SELECT order_id FROM f135 WHERE tag='t4')],'p_customer_id narrows to one order');
SELECT pg_temp.ol_assert((:'a_big'::jsonb#>>'{data,pagination,limit}')::int=200 AND jsonb_array_length(:'a_big'::jsonb#>'{data,orders}')=7,'limit 100000 is 200');
SELECT pg_temp.ol_assert((:'a_zero'::jsonb#>>'{data,pagination,limit}')::int=1 AND jsonb_array_length(:'a_zero'::jsonb#>'{data,orders}')=1,'limit 0 is 1');
SELECT pg_temp.ol_assert((:'a_neg'::jsonb#>>'{data,pagination,limit}')::int=1 AND (:'a_neg'::jsonb#>>'{data,pagination,offset}')::int=0
  AND pg_temp.ol_ids(:'a_neg'::jsonb)=(pg_temp.ol_ids(:'a_all'::jsonb))[1:1],'negative limit is 1 and negative offset is 0 (first order)');
SELECT pg_temp.ol_assert((:'a_null'::jsonb#>>'{data,pagination,limit}')::int=50 AND (:'a_null'::jsonb#>>'{data,pagination,offset}')::int=0,'null limit and offset are the defaults');
SELECT pg_temp.ol_assert(:'a_foreign_user'::jsonb->>'success'='true' AND :'a_foreign_user'::jsonb#>'{data,orders}'=:'ref_all'::jsonb,'an authenticated caller''s p_user_id is ignored (an unknown id does not fail the call)');
SELECT pg_temp.ol_assert(NOT (:'a_all'::jsonb::text ~ ('"'||(SELECT order_id FROM f135 WHERE tag IN ('t8'))||'"')),'t8 (no line) is not listed');
SELECT pg_temp.ol_assert(NOT (:'a_all'::jsonb::text ~ ((SELECT order_id FROM f135 WHERE tag='t9')::text)),'t9 (deleted order) is not listed');
SELECT pg_temp.ol_assert(NOT (:'a_all'::jsonb::text ~ ((SELECT order_id FROM f135 WHERE tag='t10')::text)),'t10 (deleted customer) is not listed');
SELECT pg_temp.ol_assert((SELECT bool_and(o->>'dispatch_no' IS NULL) FROM jsonb_array_elements(:'a_all'::jsonb#>'{data,orders}') o WHERE o->>'id'=(SELECT order_id::text FROM f135 WHERE tag='t6')),'a dispatch of another customer is not the order''s dispatch');

SELECT pg_temp.ol_assert(:'a_huge'::jsonb->>'success'='true' AND jsonb_array_length(:'a_huge'::jsonb#>'{data,orders}')=0
  AND NOT (:'a_huge'::jsonb#>>'{data,pagination,has_more}')::boolean AND (:'a_huge'::jsonb#>>'{data,pagination,total_count}')::int=7,'an offset of 2147483600 gives an empty page, no overflow');
SELECT pg_temp.ol_assert(jsonb_array_length(:'a_past'::jsonb#>'{data,orders}')=0 AND NOT (:'a_past'::jsonb#>>'{data,pagination,has_more}')::boolean
  AND (:'a_past'::jsonb#>>'{data,pagination,total_count}')::int=7,'an offset past the end: empty page, count kept');
SELECT pg_temp.ol_assert(pg_temp.ol_ids(:'a_case'::jsonb)=ARRAY[(SELECT order_id FROM f135 WHERE tag='t2')],'p_customer_name ignores case');
SELECT pg_temp.ol_assert(:'a_nullcity'::jsonb#>'{data,orders}'=pg_temp.ol_reference(p_search=>'anand135') AND jsonb_array_length(:'a_nullcity'::jsonb#>'{data,orders}')>0
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(:'a_nullcity'::jsonb#>'{data,orders}') o WHERE o->>'id'=(SELECT order_id::text FROM f135 WHERE tag='t6')),'a customer with a NULL city is listed without a city match, and is not found by a city word');
SELECT pg_temp.ol_assert((SELECT o#>'{customer}' FROM jsonb_array_elements(:'a_all'::jsonb#>'{data,orders}') o WHERE o->>'id'=(SELECT order_id::text FROM f135 WHERE tag='t5'))->>'active'='false'
  AND (SELECT o#>'{customer}' FROM jsonb_array_elements(:'a_all'::jsonb#>'{data,orders}') o WHERE o->>'id'=(SELECT order_id::text FROM f135 WHERE tag='t6')) ->'city'='null'::jsonb,'an inactive customer''s order is listed with active:false; a NULL city shows as null');
SELECT pg_temp.ol_assert(:'a_tie'::jsonb#>>'{data,orders,0,dispatch_id}'='00000000-0000-0000-0000-000000000001' AND :'a_tie'::jsonb#>>'{data,orders,0,dispatch_no}'='I9006','two dispatches with the same time: the lower id is the order''s dispatch');

-- 3. Staff read the whole queue (full order access, decision 2026-10-09); a customer account reads only its assigned customers.
SELECT set_config('request.jwt.claims',:'staff_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_orders_list(p_customer_name=>'Ol135') AS s_all \gset
RESET ROLE;
SELECT set_config('request.jwt.claims',:'reader_claims',true);
SET LOCAL ROLE authenticated;
SELECT public.get_orders_list(p_customer_name=>'Ol135') AS r_all \gset
SELECT public.get_orders_list(p_customer_name=>'Ol135',p_user_id=>:'admin_user'::uuid) AS r_admin_id \gset
SELECT public.get_orders_list(p_customer_id=>:'cust_t2'::uuid) AS r_foreign \gset
RESET ROLE;
SELECT pg_temp.ol_assert(:'s_all'::jsonb#>'{data,orders}'=:'ref_all'::jsonb AND EXISTS (SELECT 1 FROM jsonb_array_elements(:'s_all'::jsonb#>'{data,orders}') o WHERE o#>>'{customer,active}'='false'),'staff list equals the whole old list, the inactive customer''s order included');
SELECT pg_temp.ol_assert(:'r_all'::jsonb#>'{data,orders}'=pg_temp.ol_reference(p_customers=>ARRAY(SELECT customer_id FROM f135 WHERE tag IN ('t1','t3')))
  AND jsonb_array_length(:'r_all'::jsonb#>'{data,orders}')=2 AND (:'r_all'::jsonb#>>'{data,pagination,total_count}')::int=2,'a customer account sees only its two assigned customers, as the old list did');
SELECT pg_temp.ol_assert(:'r_admin_id'::jsonb#>'{data,orders}'=:'r_all'::jsonb#>'{data,orders}','a customer account passing the administrator''s p_user_id still sees only its own');
SELECT pg_temp.ol_assert(jsonb_array_length(:'r_foreign'::jsonb#>'{data,orders}')=0,'a customer account asking for a customer it is not assigned to gets nothing');

-- 4. service_role: p_user_id names the profile that must exist; without it the call needs a session user.
SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
SET LOCAL ROLE service_role;
SELECT public.get_orders_list(p_user_id=>:'admin_user'::uuid) AS sr_ok \gset
RESET ROLE;
SELECT pg_temp.ol_assert(:'sr_ok'::jsonb->>'success'='true','service_role with the id of an existing profile succeeds');
DO $$
DECLARE msg text;
BEGIN
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  SET LOCAL ROLE service_role;
  BEGIN PERFORM public.get_orders_list(p_user_id=>gen_random_uuid()); msg := 'no error';
  EXCEPTION WHEN OTHERS THEN msg := SQLERRM; END;
  RESET ROLE;
  PERFORM pg_temp.ol_assert(msg='User profile not found','service_role is checked against p_user_id: '||msg);
  PERFORM set_config('request.jwt.claims','{"role":"service_role"}',true);
  SET LOCAL ROLE service_role;
  BEGIN PERFORM public.get_orders_list(); msg := 'no error';
  EXCEPTION WHEN OTHERS THEN msg := SQLERRM; END;
  RESET ROLE;
  PERFORM pg_temp.ol_assert(msg='Authentication required','service_role without p_user_id and without a session user: '||msg);
END $$;

-- 5. The probe index exists and serves the latest-dispatch lookup.
SELECT pg_temp.ol_assert((SELECT count(*)=1 FROM pg_indexes WHERE schemaname='public' AND indexname='idx_dispatch_source_order_latest'),'the dispatch probe index exists');
ROLLBACK;
