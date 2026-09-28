\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL ROLE anon;
DO $$ BEGIN
  IF has_table_privilege(current_user, 'public.sms_config', 'SELECT')
     OR has_table_privilege(current_user, 'public.orders', 'SELECT')
     OR has_function_privilege(current_user, 'public.operator_prepare_otp(text,inet)', 'EXECUTE')
  THEN RAISE EXCEPTION 'Anonymous access boundary failed'; END IF;
END $$;
ROLLBACK;

BEGIN READ ONLY;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
  '{"role":"authenticated","sub":"00000000-0000-4000-8000-000000000001","session_id":"00000000-0000-4000-8000-000000000002"}', true);
DO $$ BEGIN
  IF warehouse_security.active_role() IS NOT NULL
     OR EXISTS (SELECT 1 FROM public.customers)
     OR EXISTS (SELECT 1 FROM public.orders)
     OR EXISTS (SELECT 1 FROM storage.objects)
  THEN RAISE EXCEPTION 'Missing-session row access boundary failed'; END IF;
END $$;
ROLLBACK;
