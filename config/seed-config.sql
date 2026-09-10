-- ============================================================
-- Seed Configuration Data
-- ============================================================
-- Run after initial_schema.sql to populate config tables.

-- API Configuration (development)
INSERT INTO public.api_configurations (environment, app_version, maintenance_mode, is_active)
VALUES ('development', '1.0.0', false, true)
ON CONFLICT DO NOTHING;

-- SMS Configuration (test mode by default)
INSERT INTO public.sms_config (provider, production_mode)
VALUES ('twilio', false)
ON CONFLICT DO NOTHING;

-- Feature Flags
INSERT INTO public.feature_flags (name, description, enabled, user_roles)
VALUES
  ('otp_auth', 'Phone OTP authentication', true, NULL),
  ('pdf_generation', 'PDF generation via Gotenberg', true, NULL),
  ('printing', 'CUPS printing integration', true, '{"admin","supervisor"}'),
  ('stock_management', 'Stock tracking and movements', true, NULL),
  ('customer_portal', 'Customer self-service portal', false, '{"customer"}')
ON CONFLICT DO NOTHING;

-- System Settings
INSERT INTO public.system_settings (key, value)
VALUES
  ('app_name', 'My Warehouse'),
  ('support_email', 'support@example.com'),
  ('support_phone', '+1234567890'),
  ('otp_hourly_limit', '40'),
  ('otp_daily_limit', '20'),
  ('session_timeout', '3600'),
  ('refresh_token_expiry', '604800'),
  ('api_rate_limit_per_minute', '100'),
  ('api_rate_limit_per_hour', '1000'),
  ('max_file_size', '52428800'),
  ('allowed_image_types', 'image/jpeg,image/png,image/webp'),
  ('allowed_document_types', 'application/pdf'),
  ('region', 'local'),
  ('test_otp_code', '123456'),
  ('test_phone_number', '1234567890')
ON CONFLICT DO NOTHING;

-- JWT Configuration
INSERT INTO public.jwt_config (key, value)
VALUES
  ('issuer', 'supabase'),
  ('expiry_seconds', '3600'),
  ('algorithm', 'HS256')
ON CONFLICT DO NOTHING;

-- Default Items (warehouse storage categories)
INSERT INTO public.items (name, description, category, unit, active)
VALUES
  ('General Storage', 'Standard cold storage space', 'storage', 'bag', true),
  ('Deep Freeze Storage', 'Sub-zero temperature storage', 'storage', 'bag', true),
  ('Loading/Unloading', 'Loading and unloading charges', 'service', 'bag', true),
  ('Insurance', 'Storage insurance premium', 'service', 'lot', true),
  ('Fumigation', 'Pest control treatment', 'service', 'lot', true)
ON CONFLICT DO NOTHING;
