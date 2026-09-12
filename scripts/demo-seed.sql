\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN
  IF NOT COALESCE((SELECT value='true' FROM warehouse_security.auth_config WHERE key='demo_auth_enabled'),false) THEN
    RAISE EXCEPTION 'Demo seed requires explicitly enabled demo authentication';
  END IF;
END $$;
-- Impossible subscriber numbers, not copied customer or employee details.
INSERT INTO public.user_profiles(id,auth_user_id,name,display_name,mobile,role,active,mobile_verified) VALUES
  ('11111111-0000-4000-8000-000000000001','11111111-0000-4000-8000-000000000011','Demo Admin','Demo Admin','910000000001','admin',true,true),
  ('11111111-0000-4000-8000-000000000002','11111111-0000-4000-8000-000000000012','Demo Customer','Demo Customer','910000000002','customer',true,true)
ON CONFLICT DO NOTHING;
INSERT INTO public.customers(id,name,city,active) VALUES
  ('22222222-0000-4000-8000-000000000001','Example Customer A','Example City',true),
  ('22222222-0000-4000-8000-000000000002','Example Customer B','Example City',true)
ON CONFLICT DO NOTHING;
INSERT INTO public.users_customers_new(user_profile_id,customer_id,active)
SELECT '11111111-0000-4000-8000-000000000002','22222222-0000-4000-8000-000000000001',true
WHERE NOT EXISTS (SELECT 1 FROM public.users_customers_new WHERE user_profile_id='11111111-0000-4000-8000-000000000002' AND customer_id='22222222-0000-4000-8000-000000000001');
INSERT INTO public.items(id,name,packaging,description,active)
VALUES ('33333333-0000-4000-8000-000000000001','Example Potatoes','Bag','Demo inventory item',true) ON CONFLICT DO NOTHING;
COMMIT;
