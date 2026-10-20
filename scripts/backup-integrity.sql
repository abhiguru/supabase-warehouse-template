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
-- By name, not signature: migration 77 added a fourth argument, and a backup from before it still verifies.
SELECT 'acl_authenticated_enrollment_review=' || COALESCE((SELECT bool_and(has_function_privilege('authenticated',p.oid,'EXECUTE'))
  FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname='operator_review_enrollment'),false);
DO $$ BEGIN
  IF NOT has_table_privilege('anon','public.feature_flags','SELECT')
    OR has_table_privilege('anon','public.orders','SELECT')
    OR NOT has_table_privilege('authenticated','public.orders','SELECT')
    OR NOT has_function_privilege('service_role','public.operator_prepare_otp(text,inet)','EXECUTE')
    OR has_function_privilege('anon','public.operator_prepare_otp(text,inet)','EXECUTE')
    OR has_function_privilege('anon','public.send_otp(varchar,varchar,text,inet,text)','EXECUTE')
    OR NOT COALESCE((SELECT bool_and(has_function_privilege('authenticated',p.oid,'EXECUTE'))
         FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname='operator_review_enrollment'),false)
  THEN RAISE EXCEPTION 'Representative operator access grants are missing or too broad';
  END IF;
END $$;
-- The append-only histories (discount: migration 41; zero charge and item
-- prices: migration 48) and the column-level grant on invoice (migration 48).
-- restore.sh and verify-restore.sh diff this file's output with the backup's
-- integrity.txt before any newer migration is applied, and a backup taken
-- before migration 48 has none of these lines (nor two of the tables), so they
-- are printed only when migration 48 is in the restored ledger. Lines for a
-- later migration need a block of their own, for the same reason. The baseline migration (the squash of migrations 0 to
-- 110) counts as all of them: a ledger that holds it has every table and grant below.
SELECT EXISTS (SELECT 1 FROM warehouse_migrations.applied WHERE name IN ('00000000000000_baseline.sql', '00000000000048_owner_decisions.sql')) AS histories_recorded \gset
\if :histories_recorded
SELECT 'invoice_discount_history_count=' || count(*) FROM public.invoice_discount_history;
SELECT 'invoice_zero_charge_history_count=' || count(*) FROM public.invoice_zero_charge_history;
SELECT 'item_price_history_count=' || count(*) FROM public.item_price_history;
SELECT 'acl_authenticated_invoice_internal_columns=' || count(*) FROM pg_attribute a
  WHERE a.attrelid = 'public.invoice'::regclass AND NOT a.attisdropped
    AND a.attname IN ('discount_reason','discount_set_by','discount_set_at','zero_charge_reason','zero_charge_set_by','zero_charge_set_at')
    AND has_column_privilege('authenticated', a.attrelid, a.attnum, 'SELECT');
SELECT 'acl_authenticated_invoice_total_select=' || has_column_privilege('authenticated','public.invoice','total','SELECT');
DO $$ BEGIN
  IF has_table_privilege('authenticated','public.invoice','SELECT')
    OR has_column_privilege('authenticated','public.invoice','discount_reason','SELECT')
    OR has_column_privilege('authenticated','public.invoice','zero_charge_reason','SELECT')
    OR NOT has_column_privilege('authenticated','public.invoice','total','SELECT')
    OR has_any_column_privilege('anon','public.invoice','SELECT')
  THEN RAISE EXCEPTION 'The column grants on invoice are missing or too broad';
  END IF;
END $$;
\endif
-- The standard rate tiers (migration 85) and the rates typed on a GRN (migration 86): counted only
-- when migration 86 is in the restored ledger (and, like the block above, only when 48 is, which
-- every database with 86 has; the restore drill removes 48 to imitate an earlier backup).
SELECT EXISTS (SELECT 1 FROM warehouse_migrations.applied WHERE name = '00000000000000_baseline.sql')
   OR (EXISTS (SELECT 1 FROM warehouse_migrations.applied WHERE name = '00000000000086_grn_rates.sql')
       AND EXISTS (SELECT 1 FROM warehouse_migrations.applied WHERE name = '00000000000048_owner_decisions.sql')) AS grn_rates_recorded \gset
\if :grn_rates_recorded
SELECT 'standard_rate_tiers_count=' || count(*) FROM public.standard_rate_tiers;
SELECT 'grn_rates_count=' || count(*) FROM public.grn_rates;
\endif
-- The payments, order lines and order revisions (TW-BE-011). Counted only when migration 95 is in
-- the restored ledger, because a backup taken before it has none of these lines and restore.sh
-- compares before it applies newer migrations. The gate is "a migration numbered 95 or later", so it
-- does not depend on the file's name. Like the block above it also needs migration 48 (every database
-- with 95 has it; the restore drill removes 48 to imitate an earlier backup). The orders themselves
-- are counted above (order_count).
SELECT EXISTS (SELECT 1 FROM warehouse_migrations.applied WHERE name = '00000000000000_baseline.sql')
   OR (EXISTS (SELECT 1 FROM warehouse_migrations.applied WHERE name >= '00000000000095' COLLATE "C")
       AND EXISTS (SELECT 1 FROM warehouse_migrations.applied WHERE name = '00000000000048_owner_decisions.sql')) AS order_detail_recorded \gset
\if :order_detail_recorded
SELECT 'payment_count=' || count(*) FROM public.payments;
SELECT 'order_item_count=' || count(*) FROM public.order_items;
SELECT 'order_revision_count=' || count(*) FROM public.order_revisions;
\endif
