\pset tuples_only on
\pset format unaligned
SELECT 'migration_count=' || count(*) FROM warehouse_migrations.applied;
SELECT 'migration_fingerprint=' || encode(digest(string_agg(name || ':' || checksum, E'\n' ORDER BY name), 'sha256'), 'hex')
  FROM warehouse_migrations.applied;
SELECT 'public_table_count=' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relkind IN ('r','p');
SELECT 'public_function_count=' || count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public';
SELECT 'customer_count=' || count(*) FROM public.customers;
SELECT 'user_profile_count=' || count(*) FROM public.user_profiles;
SELECT 'grn_count=' || count(*) FROM public.goodsreceived;
SELECT 'dispatch_count=' || count(*) FROM public.dispatch;
SELECT 'invoice_count=' || count(*) FROM public.invoice;
SELECT 'order_count=' || count(*) FROM public.orders;
SELECT 'storage_object_count=' || count(*) FROM storage.objects;
SELECT 'acl_anon_feature_flags_select=' || has_table_privilege('anon','public.feature_flags','SELECT');
SELECT 'acl_anon_orders_select=' || has_table_privilege('anon','public.orders','SELECT');
SELECT 'acl_authenticated_orders_select=' || has_table_privilege('authenticated','public.orders','SELECT');
SELECT 'acl_service_operator_prepare=' || has_function_privilege('service_role','public.operator_prepare_otp(text,inet)','EXECUTE');
SELECT 'acl_anon_operator_prepare=' || has_function_privilege('anon','public.operator_prepare_otp(text,inet)','EXECUTE');
SELECT 'acl_anon_legacy_send_otp=' || has_function_privilege('anon','public.send_otp(varchar,varchar,text,inet,text)','EXECUTE');
SELECT 'acl_authenticated_enrollment_review=' || has_function_privilege('authenticated','public.operator_review_enrollment(uuid,text,uuid[])','EXECUTE');
DO $$ BEGIN
  IF NOT has_table_privilege('anon','public.feature_flags','SELECT')
    OR has_table_privilege('anon','public.orders','SELECT')
    OR NOT has_table_privilege('authenticated','public.orders','SELECT')
    OR NOT has_function_privilege('service_role','public.operator_prepare_otp(text,inet)','EXECUTE')
    OR has_function_privilege('anon','public.operator_prepare_otp(text,inet)','EXECUTE')
    OR has_function_privilege('anon','public.send_otp(varchar,varchar,text,inet,text)','EXECUTE')
    OR NOT has_function_privilege('authenticated','public.operator_review_enrollment(uuid,text,uuid[])','EXECUTE')
  THEN RAISE EXCEPTION 'Representative operator access grants are missing or too broad';
  END IF;
END $$;
