-- Explicitly approved staff document reads, 5 October 2026.
-- Required by caller-RLS private PDF reads and native document subscriptions.
-- Approved active staff can read warehouse-wide dispatch/invoice documents.
-- No pricing table, customer-role, ownership helper, direct write or PDF-bucket grant.
DO $$ DECLARE table_name text; BEGIN
 FOREACH table_name IN ARRAY ARRAY['dispatch','dispatch_trl','invoice','invoice_trl'] LOOP
  EXECUTE format('CREATE POLICY starter_document_staff_read ON public.%I FOR SELECT TO authenticated USING (warehouse_security.active_role() = ''staff'')',table_name);
 END LOOP;
END $$;
CREATE POLICY starter_document_staff_read ON public.dispatch_images FOR SELECT TO authenticated
USING (warehouse_security.active_role()='staff' AND
 (status='confirmed' OR uploaded_by=public.get_current_user_profile_id()));
NOTIFY pgrst, 'reload schema';
