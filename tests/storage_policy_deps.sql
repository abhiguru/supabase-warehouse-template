\set ON_ERROR_STOP on
-- The policies of scripts/configure-storage.sql read public columns (a file may be deleted only while no row names it). setup.sh
-- migrates first and creates the policies after, so on a NEW install a migration may do what it likes with those columns; but on an
-- installed facility the policies already exist when the next release's migrations run: dropping or renaming a column a policy reads
-- either fails the migration ("cannot drop column ... because other objects depend on it") or, with CASCADE, silently removes the
-- policy until the next setup run. This test lists the pg_depend rows from the policies on storage.objects to public columns and
-- compares them with the set below, so a migration that changes one fails here with the name of the column.
-- Run after scripts/configure-storage.sql (tests/migrations.sh does). A change to configure-storage.sql that reads another column, or
-- stops reading one, changes the list below in the same commit.
DO $$
DECLARE
  expected text[] := ARRAY[
    'starter_customer_dispatch_images -> public.dispatch.customer_id',
    'starter_customer_dispatch_images -> public.dispatch.id',
    'starter_customer_dispatch_images -> public.dispatch_images.dispatch_id',
    'starter_customer_dispatch_images -> public.dispatch_images.status',
    'starter_customer_dispatch_images -> public.dispatch_images.storage_path',
    'starter_customer_grn_images -> public.goodsreceived.customer_id',
    'starter_customer_grn_images -> public.goodsreceived.id',
    'starter_customer_grn_images -> public.grn_images.grn_id',
    'starter_customer_grn_images -> public.grn_images.status',
    'starter_customer_grn_images -> public.grn_images.storage_path',
    'starter_dispatch_staff_insert -> public.dispatch_images.status',
    'starter_dispatch_staff_insert -> public.dispatch_images.storage_path',
    'starter_dispatch_staff_insert -> public.dispatch_images.uploaded_by',
    'starter_dispatch_staff_read -> public.dispatch_images.status',
    'starter_dispatch_staff_read -> public.dispatch_images.storage_path',
    'starter_dispatch_staff_read -> public.dispatch_images.uploaded_by',
    'starter_dispatch_staff_update -> public.dispatch_images.status',
    'starter_dispatch_staff_update -> public.dispatch_images.storage_path',
    'starter_dispatch_staff_update -> public.dispatch_images.uploaded_by',
    'starter_grn_staff_insert -> public.grn_images.status',
    'starter_grn_staff_insert -> public.grn_images.storage_path',
    'starter_grn_staff_insert -> public.grn_images.uploaded_by',
    'starter_grn_staff_read -> public.grn_images.status',
    'starter_grn_staff_read -> public.grn_images.storage_path',
    'starter_grn_staff_read -> public.grn_images.uploaded_by',
    'starter_grn_staff_update -> public.grn_images.status',
    'starter_grn_staff_update -> public.grn_images.storage_path',
    'starter_grn_staff_update -> public.grn_images.uploaded_by',
    'starter_manager_images_delete -> public.dispatch.disp_image_url',
    'starter_manager_images_delete -> public.dispatch_images.storage_path',
    'starter_manager_images_delete -> public.goodsreceived.gr_image_url',
    'starter_manager_images_delete -> public.grn_images.storage_path'
  ];
  actual text[];
  missing text[];
  unexpected text[];
BEGIN
  SELECT coalesce(array_agg(DISTINCT p.polname || ' -> public.' || c.relname || '.' || a.attname ORDER BY p.polname || ' -> public.' || c.relname || '.' || a.attname), '{}')
    INTO actual
    FROM pg_depend d
    JOIN pg_policy p ON d.classid = 'pg_policy'::regclass AND d.objid = p.oid
    JOIN pg_class t ON t.oid = p.polrelid AND t.relnamespace = 'storage'::regnamespace AND t.relname = 'objects'
    JOIN pg_class c ON d.refclassid = 'pg_class'::regclass AND d.refobjid = c.oid AND c.relnamespace = 'public'::regnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = d.refobjsubid
   WHERE d.refobjsubid > 0;
  SELECT array_agg(e ORDER BY e) INTO missing FROM unnest(expected) e WHERE e <> ALL (actual);
  SELECT array_agg(a ORDER BY a) INTO unexpected FROM unnest(actual) a WHERE a <> ALL (expected);
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'storage policy dependency lost: % no longer depend(s) on the public column(s) listed. A migration dropped or renamed a column that scripts/configure-storage.sql reads, or removed the policy. Change the policy first (and this list), and keep the column until every facility has run the new setup. Actual set: %', missing, actual;
  END IF;
  IF unexpected IS NOT NULL THEN
    RAISE EXCEPTION 'storage policy dependency added: % are not in the list of tests/storage_policy_deps.sql. A policy of scripts/configure-storage.sql now reads another public column: add it to the list so that a later migration cannot drop it unnoticed.', unexpected;
  END IF;
END $$;
