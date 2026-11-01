-- Migration 137: row policies evaluate their helpers once, and customers no longer see deleted documents.
--
-- 1. Cost. A row policy that calls warehouse_security.active_role(), warehouse_security.owns_customer(...) or
--    public.get_current_user_profile_id() directly is evaluated for every row it is asked about. Each helper is a SECURITY DEFINER
--    function that reads user_profiles and refresh_sessions, so a customer's `select * from dispatch_trl` paid that lookup per
--    row. Every policy on the 12 app-readable tables (customers, dispatch, dispatch_images, dispatch_trl, feature_flags,
--    goodsreceived, goodsreceived_trl, grn_images, invoice, invoice_trl, items, user_profiles) is recreated with the same name,
--    command, roles and logic, and with each helper call wrapped as a scalar subquery, `(SELECT helper(...))`, which the planner
--    evaluates once per statement when the call does not depend on the row (the role checks); a call that does depend on the row
--    (owns_customer(customer_id)) stays a correlated subplan, evaluated once per row.
--    owns_customer() itself used to call active_role() three times; it now calls it once.
--
-- 2. Deleted documents (owner decision). The eight customer policies (`starter_customer` on goodsreceived, dispatch, invoice,
--    goodsreceived_trl, dispatch_trl, invoice_trl, grn_images and dispatch_images) now also require `deleted_at IS NULL` on the
--    document (the header table; inside the EXISTS for the line and image tables). A customer therefore no longer reads a deleted
--    receipt, dispatch or invoice, nor its lines or photos. Administrators, supervisors and staff are unchanged. A cancelled
--    invoice (cancelled_at) stays visible to its customer; only deletion hides a document.
--
-- The two user_profiles policies also read auth.uid() as a scalar subquery.
--
-- 3. The customer-callable RPCs that read the documents as SECURITY DEFINER (they bypass the policies above) follow the same rule for a
--    customer caller; administrators, supervisors and staff are unchanged. get_grn_details and get_dispatch_details answer "not found or
--    access denied" for a deleted receipt or dispatch, and leave deleted dispatches and invoices out of the receipt's summaries;
--    get_grn_item_dispatches answers ACCESS_DENIED for a line of a deleted receipt and leaves deleted dispatches out of its list and
--    totals; get_customer_dispatch_items and get_customer_stock_analysis_v2 leave out the lines of deleted receipts and dispatches.
--    Marker-count patches: each marker is found the expected number of times, and no before-text is contained in its after-text.

-- Each policy is dropped and created next to each other, small tables first, in this one transaction (readers never see a table
-- without its policies). scripts/configure-storage.sql wraps the same helpers in the storage.objects policies.

CREATE OR REPLACE FUNCTION warehouse_security.owns_customer(customer uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
  WITH me AS MATERIALIZED (SELECT warehouse_security.active_role() AS role)
  SELECT me.role IS NOT NULL AND (
    me.role IN ('admin','supervisor') OR EXISTS (
      SELECT 1 FROM public.users_customers_new a JOIN public.user_profiles p ON p.id=a.user_profile_id
      WHERE a.customer_id=customer AND a.active AND p.active AND p.auth_user_id=auth.uid()
    )
  )
  FROM me;
$$;

DROP POLICY IF EXISTS starter_public ON public.feature_flags;
CREATE POLICY starter_public ON public.feature_flags FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS starter_catalog ON public.items;
CREATE POLICY starter_catalog ON public.items FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) IS NOT NULL));
DROP POLICY IF EXISTS starter_staff ON public.items;
CREATE POLICY starter_staff ON public.items FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = ANY (ARRAY['admin'::text, 'supervisor'::text])));
DROP POLICY IF EXISTS starter_profile_read ON public.user_profiles;
CREATE POLICY starter_profile_read ON public.user_profiles FOR SELECT TO authenticated USING ((((SELECT warehouse_security.active_role()) = ANY (ARRAY['admin'::text, 'supervisor'::text])) OR ((auth_user_id = (SELECT auth.uid())) AND active)));
DROP POLICY IF EXISTS starter_profile_update ON public.user_profiles;
CREATE POLICY starter_profile_update ON public.user_profiles FOR UPDATE TO authenticated USING (((auth_user_id = (SELECT auth.uid())) AND active))
  WITH CHECK (((auth_user_id = (SELECT auth.uid())) AND active));
DROP POLICY IF EXISTS starter_customer ON public.customers;
CREATE POLICY starter_customer ON public.customers FOR SELECT TO authenticated USING ((SELECT warehouse_security.owns_customer(id)));
DROP POLICY IF EXISTS starter_grn_staff_read ON public.customers;
CREATE POLICY starter_grn_staff_read ON public.customers FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = 'staff'::text));
DROP POLICY IF EXISTS starter_staff ON public.customers;
CREATE POLICY starter_staff ON public.customers FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = ANY (ARRAY['admin'::text, 'supervisor'::text])));
DROP POLICY IF EXISTS starter_customer ON public.goodsreceived;
CREATE POLICY starter_customer ON public.goodsreceived FOR SELECT TO authenticated USING (((deleted_at IS NULL) AND (SELECT warehouse_security.owns_customer(customer_id))));
DROP POLICY IF EXISTS starter_grn_staff_read ON public.goodsreceived;
CREATE POLICY starter_grn_staff_read ON public.goodsreceived FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = 'staff'::text));
DROP POLICY IF EXISTS starter_staff ON public.goodsreceived;
CREATE POLICY starter_staff ON public.goodsreceived FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = ANY (ARRAY['admin'::text, 'supervisor'::text])));
DROP POLICY IF EXISTS starter_customer ON public.dispatch;
CREATE POLICY starter_customer ON public.dispatch FOR SELECT TO authenticated USING (((deleted_at IS NULL) AND (SELECT warehouse_security.owns_customer(customer_id))));
DROP POLICY IF EXISTS starter_document_staff_read ON public.dispatch;
CREATE POLICY starter_document_staff_read ON public.dispatch FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = 'staff'::text));
DROP POLICY IF EXISTS starter_staff ON public.dispatch;
CREATE POLICY starter_staff ON public.dispatch FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = ANY (ARRAY['admin'::text, 'supervisor'::text])));
DROP POLICY IF EXISTS starter_customer ON public.invoice;
CREATE POLICY starter_customer ON public.invoice FOR SELECT TO authenticated USING (((deleted_at IS NULL) AND (SELECT warehouse_security.owns_customer(customer_id))));
DROP POLICY IF EXISTS starter_document_staff_read ON public.invoice;
CREATE POLICY starter_document_staff_read ON public.invoice FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = 'staff'::text));
DROP POLICY IF EXISTS starter_staff ON public.invoice;
CREATE POLICY starter_staff ON public.invoice FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = ANY (ARRAY['admin'::text, 'supervisor'::text])));
DROP POLICY IF EXISTS starter_customer ON public.goodsreceived_trl;
CREATE POLICY starter_customer ON public.goodsreceived_trl FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.goodsreceived g
  WHERE ((g.deleted_at IS NULL) AND (g.id = goodsreceived_trl.gr_id) AND (SELECT warehouse_security.owns_customer(g.customer_id))))));
DROP POLICY IF EXISTS starter_grn_staff_read ON public.goodsreceived_trl;
CREATE POLICY starter_grn_staff_read ON public.goodsreceived_trl FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = 'staff'::text));
DROP POLICY IF EXISTS starter_staff ON public.goodsreceived_trl;
CREATE POLICY starter_staff ON public.goodsreceived_trl FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = ANY (ARRAY['admin'::text, 'supervisor'::text])));
DROP POLICY IF EXISTS starter_customer ON public.dispatch_trl;
CREATE POLICY starter_customer ON public.dispatch_trl FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.dispatch d
  WHERE ((d.deleted_at IS NULL) AND (d.id = dispatch_trl.disp_id) AND (SELECT warehouse_security.owns_customer(d.customer_id))))));
DROP POLICY IF EXISTS starter_document_staff_read ON public.dispatch_trl;
CREATE POLICY starter_document_staff_read ON public.dispatch_trl FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = 'staff'::text));
DROP POLICY IF EXISTS starter_staff ON public.dispatch_trl;
CREATE POLICY starter_staff ON public.dispatch_trl FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = ANY (ARRAY['admin'::text, 'supervisor'::text])));
DROP POLICY IF EXISTS starter_customer ON public.invoice_trl;
CREATE POLICY starter_customer ON public.invoice_trl FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.invoice i
  WHERE ((i.deleted_at IS NULL) AND (i.id = invoice_trl.invoice_id) AND (SELECT warehouse_security.owns_customer(i.customer_id))))));
DROP POLICY IF EXISTS starter_document_staff_read ON public.invoice_trl;
CREATE POLICY starter_document_staff_read ON public.invoice_trl FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = 'staff'::text));
DROP POLICY IF EXISTS starter_staff ON public.invoice_trl;
CREATE POLICY starter_staff ON public.invoice_trl FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = ANY (ARRAY['admin'::text, 'supervisor'::text])));
DROP POLICY IF EXISTS starter_customer ON public.grn_images;
CREATE POLICY starter_customer ON public.grn_images FOR SELECT TO authenticated USING ((((status)::text = 'confirmed'::text) AND (EXISTS ( SELECT 1
   FROM public.goodsreceived g
  WHERE ((g.deleted_at IS NULL) AND (g.id = grn_images.grn_id) AND (SELECT warehouse_security.owns_customer(g.customer_id)))))));
DROP POLICY IF EXISTS starter_grn_staff_read ON public.grn_images;
CREATE POLICY starter_grn_staff_read ON public.grn_images FOR SELECT TO authenticated USING ((((SELECT warehouse_security.active_role()) = 'staff'::text) AND (((status)::text = 'confirmed'::text) OR (uploaded_by = (SELECT public.get_current_user_profile_id())))));
DROP POLICY IF EXISTS starter_staff ON public.grn_images;
CREATE POLICY starter_staff ON public.grn_images FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = ANY (ARRAY['admin'::text, 'supervisor'::text])));
DROP POLICY IF EXISTS starter_customer ON public.dispatch_images;
CREATE POLICY starter_customer ON public.dispatch_images FOR SELECT TO authenticated USING ((((status)::text = 'confirmed'::text) AND (EXISTS ( SELECT 1
   FROM public.dispatch d
  WHERE ((d.deleted_at IS NULL) AND (d.id = dispatch_images.dispatch_id) AND (SELECT warehouse_security.owns_customer(d.customer_id)))))));
DROP POLICY IF EXISTS starter_document_staff_read ON public.dispatch_images;
CREATE POLICY starter_document_staff_read ON public.dispatch_images FOR SELECT TO authenticated USING ((((SELECT warehouse_security.active_role()) = 'staff'::text) AND (((status)::text = 'confirmed'::text) OR (uploaded_by = (SELECT public.get_current_user_profile_id())))));
DROP POLICY IF EXISTS starter_staff ON public.dispatch_images;
CREATE POLICY starter_staff ON public.dispatch_images FOR SELECT TO authenticated USING (((SELECT warehouse_security.active_role()) = ANY (ARRAY['admin'::text, 'supervisor'::text])));

DO $patch$
DECLARE
  v_def text;
  v_before text;
  v_after text;
  v_count integer;
BEGIN
  v_def := pg_get_functiondef('public.get_grn_details(uuid)'::regprocedure);
  v_before := $m$        WHERE gr.id = p_grn_id
        AND (
            v_role IN ('admin', 'supervisor', 'staff') OR$m$;
  v_after := $m$        WHERE gr.id = p_grn_id
        AND (gr.deleted_at IS NULL OR v_role IN ('admin', 'supervisor', 'staff'))
        AND (
            v_role IN ('admin', 'supervisor', 'staff') OR$m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_grn_details: expected marker 1 1 time(s), found %', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  v_before := $m$                                    FROM dispatch_trl dt
                                    WHERE dt.gr_trl_id IN ($m$;
  v_after := $m$                                    FROM dispatch_trl dt
                                    WHERE EXISTS (SELECT 1 FROM dispatch dd WHERE dd.id = dt.disp_id AND (dd.deleted_at IS NULL OR v_role IN ('admin', 'supervisor', 'staff')))
                                    AND dt.gr_trl_id IN ($m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_grn_details: expected marker 2 1 time(s), found %', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  -- (The invoice count in the summary needs no marker here: migration 134 already counts live invoices only, for every role.)
  v_before := $m$                        FROM dispatch d
                        WHERE EXISTS ($m$;
  v_after := $m$                        FROM dispatch d
                        WHERE (d.deleted_at IS NULL OR v_role IN ('admin', 'supervisor', 'staff'))
                        AND EXISTS ($m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_grn_details: expected marker 3 1 time(s), found %', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  EXECUTE v_def;
END
$patch$;

DO $patch$
DECLARE
  v_def text;
  v_before text;
  v_after text;
  v_count integer;
BEGIN
  v_def := pg_get_functiondef('public.get_dispatch_details(uuid)'::regprocedure);
  v_before := $m$        WHERE d.id = p_dispatch_id
        AND (
            v_role IN ('admin', 'supervisor', 'staff') OR$m$;
  v_after := $m$        WHERE d.id = p_dispatch_id
        AND (d.deleted_at IS NULL OR v_role IN ('admin', 'supervisor', 'staff'))
        AND (
            v_role IN ('admin', 'supervisor', 'staff') OR$m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_dispatch_details: expected marker 1 1 time(s), found %', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  EXECUTE v_def;
END
$patch$;

DO $patch$
DECLARE
  v_def text;
  v_before text;
  v_after text;
  v_count integer;
BEGIN
  v_def := pg_get_functiondef('public.get_grn_item_dispatches(uuid)'::regprocedure);
  v_before := $m$    SELECT 1 FROM public.goodsreceived_trl WHERE id = p_grn_item_id
$m$;
  v_after := $m$    SELECT 1 FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id
    WHERE t.id = p_grn_item_id AND (g.deleted_at IS NULL OR warehouse_security.active_role() IN ('admin', 'supervisor', 'staff'))
$m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_grn_item_dispatches: expected marker 1 1 time(s), found %', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  v_before := $m$  JOIN public.dispatch d ON d.id = dt.disp_id
  WHERE dt.gr_trl_id = p_grn_item_id;$m$;
  v_after := $m$  JOIN public.dispatch d ON d.id = dt.disp_id
  WHERE dt.gr_trl_id = p_grn_item_id AND (d.deleted_at IS NULL OR warehouse_security.active_role() IN ('admin', 'supervisor', 'staff'));$m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_grn_item_dispatches: expected marker 2 1 time(s), found %', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  v_before := $m$  LEFT JOIN public.dispatch_trl dt ON dt.gr_trl_id = item.id
  WHERE item.id = p_grn_item_id$m$;
  v_after := $m$  LEFT JOIN public.dispatch_trl dt ON dt.gr_trl_id = item.id
    AND EXISTS (SELECT 1 FROM public.dispatch dd WHERE dd.id = dt.disp_id AND (dd.deleted_at IS NULL OR warehouse_security.active_role() IN ('admin', 'supervisor', 'staff')))
  WHERE item.id = p_grn_item_id$m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_grn_item_dispatches: expected marker 3 1 time(s), found %', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  EXECUTE v_def;
END
$patch$;

DO $patch$
DECLARE
  v_def text;
  v_before text;
  v_after text;
  v_count integer;
BEGIN
  v_def := pg_get_functiondef('public.get_customer_dispatch_items(uuid, timestamp with time zone, timestamp with time zone, jsonb, text, text, integer, integer)'::regprocedure);
  v_before := $m$    WHERE gr.customer_id = p_customer_id
    AND (p_date_from IS NULL$m$;
  v_after := $m$    WHERE gr.customer_id = p_customer_id
    AND (gr.deleted_at IS NULL OR v_user_role IN ('admin', 'supervisor', 'staff'))
    AND (d.deleted_at IS NULL OR v_user_role IN ('admin', 'supervisor', 'staff'))
    AND (p_date_from IS NULL$m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 2 THEN RAISE EXCEPTION 'get_customer_dispatch_items: expected marker 1 2 time(s), found %', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  v_before := $m$        WHERE gr.customer_id = p_customer_id
        AND (p_date_from IS NULL$m$;
  v_after := $m$        WHERE gr.customer_id = p_customer_id
        AND (gr.deleted_at IS NULL OR v_user_role IN ('admin', 'supervisor', 'staff'))
        AND (d.deleted_at IS NULL OR v_user_role IN ('admin', 'supervisor', 'staff'))
        AND (p_date_from IS NULL$m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_customer_dispatch_items: expected marker 2 1 time(s), found %', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  EXECUTE v_def;
END
$patch$;

DO $patch$
DECLARE
  v_def text;
  v_before text;
  v_after text;
  v_count integer;
BEGIN
  v_def := pg_get_functiondef('public.get_customer_stock_analysis_v2(uuid, timestamp with time zone, jsonb, boolean)'::regprocedure);
  v_before := $m$        WHERE gr.customer_id = p_customer_id
        AND (p_date_filter IS NULL OR gr.date <= p_date_filter)$m$;
  v_after := $m$        WHERE gr.customer_id = p_customer_id
        AND (gr.deleted_at IS NULL OR v_user_role IN ('admin', 'supervisor', 'staff'))
        AND (p_date_filter IS NULL OR gr.date <= p_date_filter)$m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_customer_stock_analysis_v2: expected marker 1 1 time(s), found %', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  v_before := $m$        JOIN dispatch d ON dt.disp_id = d.id
        WHERE (p_date_filter IS NULL$m$;
  v_after := $m$        JOIN dispatch d ON dt.disp_id = d.id
        WHERE (d.deleted_at IS NULL OR v_user_role IN ('admin', 'supervisor', 'staff'))
        AND (p_date_filter IS NULL$m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_customer_stock_analysis_v2: expected marker 2 1 time(s), found %', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  EXECUTE v_def;
END
$patch$;

NOTIFY pgrst, 'reload schema';
