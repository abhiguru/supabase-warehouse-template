-- Every function the app, fas-sync and the edge functions call still exists after the removals of migration 123 (and later ones).
-- The lists are written out here; tests/rpc-callers.test.mjs keeps the edge list equal to what functions/ calls, and, when MOBILE_CHECKOUT
-- points at the app, the app list equal to what the app calls (scripts/contract-details.mjs logic). Names only for the app and the
-- edge functions; for fas-sync (~/fas-sync, fassync/push.py: ten calls) the argument names it passes too, because it calls by name.
-- Runs after all migrations in migrations.sh's disposable database; it writes nothing.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.rc_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'rpc callers: %', label; END IF; END $$;
-- The app (src/ and app/): 106 names, 5 of them reached through a variable (save_invoice, update_invoice, the three sensor calls).
SELECT pg_temp.rc_assert(count(*) = 0, 'the app calls a function that is gone: ' || string_agg(n, ', ' ORDER BY n))
FROM unnest(ARRAY[
  'add_item_to_order','assign_customer_to_user','cancel_dispatch_image_upload','cancel_grn_image_upload','check_dispatch_exists',
  'check_grn_exists','confirm_dispatch_image_upload','confirm_grn_image_upload','create_customer','create_dispatch_with_stock_check',
  'create_item','delete_dispatch_image','delete_dispatch_with_order_cleanup','delete_grn_image','delete_grn_safe',
  'delete_invoice','delete_item_safe','delete_user_account','generate_invoice_data_for_grn_with_pricing','get_all_customer_activity_summary',
  'get_all_dispatch_activity','get_all_dispatch_items','get_all_grn_activity','get_all_grn_items','get_all_stock_summary',
  'get_available_stock','get_customer_activity_detail','get_customer_dispatch_activity','get_customer_dispatch_items','get_customer_dispatch_list',
  'get_customer_grn_activity','get_customer_grn_items','get_customer_grns_with_stock_dispatch_sorted','get_customer_invoice_summary','get_customer_items_for_order_selection',
  'get_customer_stock_analysis_v2','get_customer_stock_summary','get_dispatch_autocomplete','get_dispatch_details','get_dispatch_list_with_items',
  'get_grn_details','get_grn_edit_state','get_grn_item_dispatches','get_grn_item_rates','get_grn_list',
  'get_grn_prefixes_with_stock','get_invoice_data','get_invoice_detail','get_invoice_items_detailed','get_invoiceable_grns',
  'get_invoices_list','get_item','get_item_price_history','get_item_storage_prices','get_item_usage',
  'get_item_wise_stock_list','get_items','get_my_access_status','get_my_language','get_next_dispatch_number',
  'get_next_grn_number','get_next_invoice_number','get_operations_dashboard','get_or_create_cart','get_order_change_log',
  'get_order_with_items','get_orders_list','get_recent_dispatched_orders','get_sensor_history','get_standard_rate',
  'get_stock_aging_report','get_submission_result','get_supervisors','get_user_details','get_users_list',
  'get_vehicle_suggestions','logout_session','operator_review_enrollment','refresh_jwt_token','register_dispatch_image_upload',
  'register_grn_image_upload','remove_customer_assignment','remove_item_from_order','replace_item_rates','review_enrollment_again',
  'save_grn','search_customer_items_for_order','search_customers','search_items_autocomplete','set_customer_active',
  'set_my_language','set_standard_rate','undo_rate_change','update_customer','update_dispatch_smart',
  'update_grn','update_item','update_order_item_quantity','update_user_role','update_user_status',
  'user_accessible_customers','save_invoice','update_invoice','get_sensor_polling_data','get_sensor_device',
  'update_sensor_device',
  -- functions/_shared/report-pdf.ts calls these by variable name (call.name of report-definitions.ts), with the caller's token.
  'get_customer_grn_activity','get_all_grn_activity','get_customer_dispatch_activity','get_all_dispatch_activity','get_customer_invoice_summary',
  'get_customer_stock_summary','get_all_stock_summary','get_stock_aging_report','get_customer_activity_detail',
  'get_all_customer_activity_summary']) AS n
WHERE NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = n
  AND has_function_privilege('authenticated', p.oid, 'EXECUTE'));
-- The edge functions: called with the service key (or, for get_public_config, the anon key).
SELECT pg_temp.rc_assert(count(*) = 0, 'an edge function calls a function that is gone: ' || string_agg(n, ', ' ORDER BY n))
FROM unnest(ARRAY[
  'operator_central_exchange','operator_enrollment_signout','operator_enrollment_status','operator_finish_otp','operator_prepare_otp',
  'operator_sms_config','operator_verify_otp','get_dispatch_range_for_print','get_grn_range_for_print','get_invoice_range_for_print',
  'get_public_config','record_sensor_batch']) AS n
WHERE NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = n
  AND has_function_privilege('service_role', p.oid, 'EXECUTE'));
-- fas-sync: a function of that name takes every argument name the sync passes.
SELECT pg_temp.rc_assert(count(*) = 0, 'fas-sync calls a function that is gone or has lost an argument: ' || string_agg(f.name, ', ' ORDER BY f.name))
FROM (VALUES
  ('delete_dispatch_with_order_cleanup','{p_dispatch_id,p_user_id}'),
  ('delete_grn_safe','{p_grn_id}'),
  ('create_customer','{p_name,p_mobile,p_address,p_city,p_state,p_pincode}'),
  ('create_item','{p_name,p_packaging,p_description,p_active}'),
  ('save_grn','{p_gr_no,p_date,p_customer_id,p_customer_name,p_sender_id,p_sender_name,p_supervisor_id,p_supervisor_name,p_registration,p_note,p_leon,p_pricing_mode,p_items,p_images,p_idempotency_key,p_duration_mode}'),
  ('create_dispatch_with_stock_check','{p_dispatch_data,p_dispatch_items,p_retry_count,p_idempotency_key}'),
  ('update_dispatch_smart','{p_dispatch_id,p_dispatch_data,p_dispatch_items}'),
  ('update_grn','{p_grn_id,p_date,p_registration,p_leon,p_items,p_images}'),
  ('get_next_grn_number','{}'),
  ('get_next_dispatch_number','{}')) AS f(name, arguments)
WHERE NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = f.name
  AND COALESCE(p.proargnames, '{}') @> f.arguments::text[]);
-- create_dispatch_with_stock_check: the four-argument form fas-sync calls (by name, without p_generate_invoice) is there.
SELECT pg_temp.rc_assert(to_regprocedure('public.create_dispatch_with_stock_check(jsonb,jsonb[],integer,text)') IS NOT NULL,
  'create_dispatch_with_stock_check(jsonb, jsonb[], integer, text) exists');
ROLLBACK;
