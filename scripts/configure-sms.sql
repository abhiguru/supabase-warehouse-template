\set ON_ERROR_STOP on
-- Values come from this operator instance's private Compose environment.
-- Keep this script quiet: the authentication key must not enter logs.
\getenv sms_provider SMS_PROVIDER
\getenv sms_production_mode SMS_PRODUCTION_MODE
\getenv sms_auth_key MSG91_AUTH_KEY
\getenv sms_flow_id MSG91_TEMPLATE_ID
\getenv sms_pe_id MSG91_PE_ID
\getenv sms_sender_id MSG91_SENDER_ID
SELECT :'sms_provider'='msg91' AND :'sms_production_mode'='true'
  AND length(:'sms_auth_key')>0 AND :'sms_auth_key' NOT LIKE 'your-%'
  AND :'sms_flow_id' ~ '^[0-9a-f]{24}$'
  AND :'sms_pe_id' ~ '^[0-9]+$'
  AND :'sms_sender_id' ~ '^[A-Z0-9]{6}$' AS valid_sms \gset
\if :valid_sms
\else
  DO $$ BEGIN RAISE EXCEPTION 'Production MSG91 configuration is invalid'; END $$;
\endif
BEGIN;
SELECT pg_advisory_xact_lock(71045);
INSERT INTO public.sms_config(provider,production_mode,msg91_auth_key,msg91_template_id,msg91_pe_id,msg91_sender_id)
SELECT 'msg91',true,:'sms_auth_key',:'sms_flow_id',:'sms_pe_id',:'sms_sender_id'
WHERE NOT EXISTS (SELECT 1 FROM public.sms_config);
UPDATE public.sms_config SET provider='msg91',production_mode=true,
  msg91_auth_key=:'sms_auth_key',msg91_template_id=:'sms_flow_id',
  msg91_pe_id=:'sms_pe_id',msg91_sender_id=:'sms_sender_id',updated_at=now()
WHERE id=(SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
COMMIT;
