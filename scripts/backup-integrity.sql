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
