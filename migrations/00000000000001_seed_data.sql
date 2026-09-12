-- Repeatable configuration only. Demo business rows are a separate opt-in script.
INSERT INTO public.api_configurations(environment, app_version, maintenance_mode, is_active)
VALUES ('development', '0.2.0', false, true) ON CONFLICT DO NOTHING;
INSERT INTO public.sms_config(id, provider, production_mode)
VALUES (1, 'unconfigured', true) ON CONFLICT DO NOTHING;
INSERT INTO public.feature_flags(name, description, enabled, user_roles) VALUES
('otp_auth', 'Custom authentication', true, NULL),
('stock_management', 'Warehouse inventory', true, NULL),
('pdf_generation', 'PDF generation', true, NULL),
('printing', 'Optional printer integration', false, ARRAY['admin','supervisor']),
('sensor_monitoring', 'Optional sensor integration', false, ARRAY['admin','supervisor']),
('customer_portal', 'Customer portal', true, ARRAY['customer'])
ON CONFLICT DO NOTHING;
INSERT INTO public.system_settings(key, value) VALUES
('app_name', 'Warehouse Manager'), ('support_email', 'support@example.com'),
('support_phone', ''), ('otp_hourly_limit', '5'), ('otp_daily_limit', '20'),
('session_timeout', '3600'), ('refresh_token_expiry', '604800'),
('api_rate_limit_per_minute', '100'), ('api_rate_limit_per_hour', '1000'),
('max_file_size', '10485760'), ('region', 'local')
ON CONFLICT DO NOTHING;
-- Never seed signing keys, fixed production phones, or production SMS credentials.
