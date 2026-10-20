\set ON_ERROR_STOP on
BEGIN;
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES
  ('documents','documents',false,52428800,ARRAY['application/pdf']),
  ('grn-images','grn-images',false,10485760,ARRAY['image/jpeg','image/png','image/webp']),
  ('dispatch-images','dispatch-images',false,10485760,ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT(id) DO NOTHING;
-- Earlier versions also created the bucket customer-images. Nothing uses it (GRN and dispatch
-- photos live in grn-images and dispatch-images). An existing install loses it here, but only
-- while it is empty: a file in it is never deleted by this script.
DO $$ DECLARE has_uploads boolean := false; BEGIN
  IF EXISTS (SELECT 1 FROM storage.buckets WHERE id='customer-images') THEN
    IF EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id='customer-images') THEN
      RAISE EXCEPTION 'The bucket customer-images still holds files; move or delete them, then run setup again';
    END IF;
    IF to_regclass('storage.s3_multipart_uploads') IS NOT NULL THEN
      EXECUTE 'SELECT EXISTS (SELECT 1 FROM storage.s3_multipart_uploads WHERE bucket_id = $1)' INTO has_uploads USING 'customer-images';
      IF has_uploads THEN
        RAISE EXCEPTION 'The bucket customer-images still holds unfinished uploads; finish or delete them, then run setup again';
      END IF;
    END IF;
    -- Storage guards storage.buckets with a statement trigger (protect_buckets_delete) that refuses
    -- every DELETE unless this setting is on. It is on for this transaction only, for this one delete.
    PERFORM set_config('storage.allow_delete_query','true',true);
    DELETE FROM storage.buckets WHERE id='customer-images';
    PERFORM set_config('storage.allow_delete_query','false',true);
  END IF;
END $$;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM storage.buckets WHERE id IN ('documents','grn-images','dispatch-images') AND public) THEN
    RAISE EXCEPTION 'A starter bucket is public; review it before continuing';
  END IF;
END $$;
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
-- Administrators and supervisors read, upload and replace image objects freely,
-- but delete only an object that nothing references any more: no grn_images or
-- dispatch_images row and no document header column names it. (The staff helper
-- warehouse_security.staff_may_remove_image_file is staff-only and also needs a
-- live document, so the manager rule is written out here; it covers the files of
-- deleted documents too.)
DROP POLICY IF EXISTS starter_staff_images ON storage.objects;
DROP POLICY IF EXISTS starter_manager_images_select ON storage.objects;
CREATE POLICY starter_manager_images_select ON storage.objects FOR SELECT TO authenticated
USING (bucket_id IN ('grn-images','dispatch-images') AND warehouse_security.active_role() IN ('admin','supervisor'));
DROP POLICY IF EXISTS starter_manager_images_insert ON storage.objects;
CREATE POLICY starter_manager_images_insert ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id IN ('grn-images','dispatch-images') AND warehouse_security.active_role() IN ('admin','supervisor'));
DROP POLICY IF EXISTS starter_manager_images_update ON storage.objects;
CREATE POLICY starter_manager_images_update ON storage.objects FOR UPDATE TO authenticated
USING (bucket_id IN ('grn-images','dispatch-images') AND warehouse_security.active_role() IN ('admin','supervisor'))
WITH CHECK (bucket_id IN ('grn-images','dispatch-images') AND warehouse_security.active_role() IN ('admin','supervisor'));
DROP POLICY IF EXISTS starter_manager_images_delete ON storage.objects;
CREATE POLICY starter_manager_images_delete ON storage.objects FOR DELETE TO authenticated
USING (bucket_id IN ('grn-images','dispatch-images') AND warehouse_security.active_role() IN ('admin','supervisor')
  AND NOT EXISTS (SELECT 1 FROM public.grn_images i WHERE i.storage_path=name)
  AND NOT EXISTS (SELECT 1 FROM public.dispatch_images i WHERE i.storage_path=name)
  AND NOT EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.gr_image_url IS NOT NULL AND position(name IN g.gr_image_url) > 0)
  AND NOT EXISTS (SELECT 1 FROM public.dispatch d WHERE d.disp_image_url IS NOT NULL AND position(name IN d.disp_image_url) > 0));
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
-- Photo removal by staff (migrations 45 and 47): delete_grn_image /
-- delete_dispatch_image remove the image row, then the app removes the file.
-- Staff may read and delete a file in the two photo buckets only when it lies
-- in the folder of a receipt or dispatch that is not deleted and no image row
-- names it. A file that a document still shows, and every file of a deleted
-- document, cannot be read, deleted or overwritten by staff through these.
-- The read policy is there because the Storage API looks the object up before
-- it deletes it; this was not checked against a running Storage API.
DROP POLICY IF EXISTS starter_staff_removed_image_read ON storage.objects;
CREATE POLICY starter_staff_removed_image_read ON storage.objects FOR SELECT TO authenticated
USING (bucket_id IN ('grn-images','dispatch-images') AND warehouse_security.active_role()='staff'
  AND warehouse_security.staff_may_remove_image_file(bucket_id,name));
DROP POLICY IF EXISTS starter_staff_removed_image_delete ON storage.objects;
CREATE POLICY starter_staff_removed_image_delete ON storage.objects FOR DELETE TO authenticated
USING (bucket_id IN ('grn-images','dispatch-images') AND warehouse_security.active_role()='staff'
  AND warehouse_security.staff_may_remove_image_file(bucket_id,name));
-- Generated PDFs have no direct client-read policy. Authorized Edge functions issue expiring links.
COMMIT;
