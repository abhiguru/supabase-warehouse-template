-- Migration 137: row policies evaluate their helpers once, and customers no longer see deleted documents.
--
-- 1. Cost. A row policy that calls warehouse_security.active_role(), warehouse_security.owns_customer(...) or
--    public.get_current_user_profile_id() directly is evaluated for every row it is asked about. Each helper is a SECURITY DEFINER
--    function that reads user_profiles and refresh_sessions, so a customer's `select * from dispatch_trl` paid that lookup per
--    row. Every policy on the 12 app-readable tables (customers, dispatch, dispatch_images, dispatch_trl, feature_flags,
--    goodsreceived, goodsreceived_trl, grn_images, invoice, invoice_trl, items, user_profiles) is recreated with the same name,
--    command, roles and logic, and with each helper call wrapped as a scalar subquery, `(SELECT helper(...))`, which the planner
--    evaluates once per statement when the call does not depend on the row (the role checks), and as a single subplan otherwise.
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

NOTIFY pgrst, 'reload schema';
