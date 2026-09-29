\set ON_ERROR_STOP on
UPDATE public.system_settings SET value = :'company', updated_at = now()
WHERE key = 'app_name' AND value = 'Warehouse Manager';
UPDATE public.system_settings SET value = '', updated_at = now()
WHERE key = 'support_email' AND value = 'support@example.com';
