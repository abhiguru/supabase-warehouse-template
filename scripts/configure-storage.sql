\set ON_ERROR_STOP on
BEGIN;
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES
  ('documents','documents',false,52428800,ARRAY['application/pdf']),
  ('grn-images','grn-images',false,10485760,ARRAY['image/jpeg','image/png','image/webp']),
  ('dispatch-images','dispatch-images',false,10485760,ARRAY['image/jpeg','image/png','image/webp']),
  ('customer-images','customer-images',false,10485760,ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT(id) DO NOTHING;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM storage.buckets WHERE id IN ('documents','grn-images','dispatch-images','customer-images') AND public) THEN
    RAISE EXCEPTION 'A starter bucket is public; review it before continuing';
  END IF;
END $$;
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS starter_staff_images ON storage.objects;
CREATE POLICY starter_staff_images ON storage.objects FOR ALL TO authenticated
USING (bucket_id IN ('grn-images','dispatch-images','customer-images') AND warehouse_security.active_role() IN ('admin','supervisor'))
WITH CHECK (bucket_id IN ('grn-images','dispatch-images','customer-images') AND warehouse_security.active_role() IN ('admin','supervisor'));
DROP POLICY IF EXISTS starter_customer_grn_images ON storage.objects;
CREATE POLICY starter_customer_grn_images ON storage.objects FOR SELECT TO authenticated USING (
  bucket_id='grn-images' AND EXISTS (SELECT 1 FROM public.grn_images i JOIN public.goodsreceived g ON g.id=i.grn_id
    WHERE i.storage_path=name AND i.status='confirmed' AND warehouse_security.owns_customer(g.customer_id))
);
DROP POLICY IF EXISTS starter_customer_dispatch_images ON storage.objects;
CREATE POLICY starter_customer_dispatch_images ON storage.objects FOR SELECT TO authenticated USING (
  bucket_id='dispatch-images' AND EXISTS (SELECT 1 FROM public.dispatch_images i JOIN public.dispatch d ON d.id=i.dispatch_id
    WHERE i.storage_path=name AND i.status='confirmed' AND warehouse_security.owns_customer(d.customer_id))
);
-- Staff can read GRN attachments and upload only their registered pending
-- objects. A file that an image row names cannot be deleted or overwritten by
-- staff, and unrelated buckets remain restricted.
DROP POLICY IF EXISTS starter_grn_staff_read ON storage.objects;
CREATE POLICY starter_grn_staff_read ON storage.objects FOR SELECT TO authenticated
USING (bucket_id='grn-images' AND warehouse_security.active_role()='staff' AND EXISTS (
  SELECT 1 FROM public.grn_images i WHERE i.storage_path=name
    AND (i.status='confirmed' OR i.uploaded_by=public.get_current_user_profile_id())
));
DROP POLICY IF EXISTS starter_grn_staff_insert ON storage.objects;
CREATE POLICY starter_grn_staff_insert ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id='grn-images' AND warehouse_security.active_role()='staff' AND EXISTS (
  SELECT 1 FROM public.grn_images i WHERE i.storage_path=name AND i.status='pending'
    AND i.uploaded_by=public.get_current_user_profile_id()
));
DROP POLICY IF EXISTS starter_grn_staff_update ON storage.objects;
CREATE POLICY starter_grn_staff_update ON storage.objects FOR UPDATE TO authenticated
USING (bucket_id='grn-images' AND warehouse_security.active_role()='staff' AND EXISTS (
  SELECT 1 FROM public.grn_images i WHERE i.storage_path=name AND i.status='pending'
    AND i.uploaded_by=public.get_current_user_profile_id()
))
WITH CHECK (bucket_id='grn-images' AND warehouse_security.active_role()='staff' AND EXISTS (
  SELECT 1 FROM public.grn_images i WHERE i.storage_path=name AND i.status='pending'
    AND i.uploaded_by=public.get_current_user_profile_id()
));
-- Staff dispatch attachments follow the same contract (migration 23): read
-- confirmed or own pending metadata, upload only registered pending objects.
DROP POLICY IF EXISTS starter_dispatch_staff_read ON storage.objects;
CREATE POLICY starter_dispatch_staff_read ON storage.objects FOR SELECT TO authenticated
USING (bucket_id='dispatch-images' AND warehouse_security.active_role()='staff' AND EXISTS (
  SELECT 1 FROM public.dispatch_images i WHERE i.storage_path=name
    AND (i.status='confirmed' OR i.uploaded_by=public.get_current_user_profile_id())
));
DROP POLICY IF EXISTS starter_dispatch_staff_insert ON storage.objects;
CREATE POLICY starter_dispatch_staff_insert ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id='dispatch-images' AND warehouse_security.active_role()='staff' AND EXISTS (
  SELECT 1 FROM public.dispatch_images i WHERE i.storage_path=name AND i.status='pending'
    AND i.uploaded_by=public.get_current_user_profile_id()
));
DROP POLICY IF EXISTS starter_dispatch_staff_update ON storage.objects;
CREATE POLICY starter_dispatch_staff_update ON storage.objects FOR UPDATE TO authenticated
USING (bucket_id='dispatch-images' AND warehouse_security.active_role()='staff' AND EXISTS (
  SELECT 1 FROM public.dispatch_images i WHERE i.storage_path=name AND i.status='pending'
    AND i.uploaded_by=public.get_current_user_profile_id()
))
WITH CHECK (bucket_id='dispatch-images' AND warehouse_security.active_role()='staff' AND EXISTS (
  SELECT 1 FROM public.dispatch_images i WHERE i.storage_path=name AND i.status='pending'
    AND i.uploaded_by=public.get_current_user_profile_id()
));
-- Photo removal by staff (migration 45): delete_grn_image / delete_dispatch_image
-- remove the image row, then the app removes the file. Staff may read and delete
-- a file in the two photo buckets only once no image row names it; a file that
-- a receipt or dispatch still shows cannot be deleted or overwritten by staff.
DROP POLICY IF EXISTS starter_staff_removed_image_read ON storage.objects;
CREATE POLICY starter_staff_removed_image_read ON storage.objects FOR SELECT TO authenticated
USING (bucket_id IN ('grn-images','dispatch-images') AND warehouse_security.active_role()='staff'
  AND warehouse_security.image_file_unreferenced(bucket_id,name));
DROP POLICY IF EXISTS starter_staff_removed_image_delete ON storage.objects;
CREATE POLICY starter_staff_removed_image_delete ON storage.objects FOR DELETE TO authenticated
USING (bucket_id IN ('grn-images','dispatch-images') AND warehouse_security.active_role()='staff'
  AND warehouse_security.image_file_unreferenced(bucket_id,name));
-- Generated PDFs have no direct client-read policy. Authorized Edge functions issue expiring links.
COMMIT;
