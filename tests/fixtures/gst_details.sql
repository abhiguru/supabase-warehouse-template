-- WH-205: a bill can only be made once the GST details are saved with a GSTIN. migrations.sh runs this file before each SQL suite, so a suite
-- that makes bills starts from a registered store (fictional GSTIN). Idempotent; suites that test the GST state set their own (they clear or
-- replace this row themselves).
INSERT INTO public.system_settings (key, value)
VALUES ('facility_legal', '{"gstRegistered":true,"gstin":"24AAAAA0000A1Z5","address":"1 Demo Road, Demo City","gstSavedAt":"2026-01-01T00:00:00Z"}')
ON CONFLICT (key) DO UPDATE SET value = ((public.system_settings.value::jsonb - 'gstin' - 'gstRegistered' - 'gstSavedAt')
  || '{"gstRegistered":true,"gstin":"24AAAAA0000A1Z5","gstSavedAt":"2026-01-01T00:00:00Z"}'::jsonb
  || jsonb_build_object('address', COALESCE(NULLIF(public.system_settings.value::jsonb->>'address', ''), '1 Demo Road, Demo City')))::text;
