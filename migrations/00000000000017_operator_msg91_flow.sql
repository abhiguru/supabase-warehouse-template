-- Keep MSG91 credentials in the database and expose them only to the service
-- role's server-side OTP worker. Never expose this function to mobile clients.
DROP POLICY IF EXISTS "Admins read SMS config" ON public.sms_config;
REVOKE SELECT ON public.sms_config FROM anon, authenticated;

CREATE FUNCTION public.operator_sms_config() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE config public.sms_config;
BEGIN
  SELECT * INTO config FROM public.sms_config ORDER BY id DESC LIMIT 1;
  IF config.id IS NULL OR config.provider <> 'msg91' OR config.production_mode IS DISTINCT FROM true
    OR nullif(config.msg91_auth_key,'') IS NULL
    OR nullif(config.msg91_template_id,'') IS NULL
    OR nullif(config.msg91_pe_id,'') IS NULL
    OR nullif(config.msg91_sender_id,'') IS NULL THEN
    RETURN jsonb_build_object('success',false,'code','unavailable');
  END IF;
  RETURN jsonb_build_object('success',true,'data',jsonb_build_object(
    'auth_key',config.msg91_auth_key,'flow_id',config.msg91_template_id,
    'pe_id',config.msg91_pe_id,'sender_id',config.msg91_sender_id));
END $$;
REVOKE EXECUTE ON FUNCTION public.operator_sms_config() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.operator_sms_config() TO service_role;

-- p_provider_id is the MSG91 request ID on acceptance. On failure it carries
-- only one of the fixed safe codes below, never the provider response body.
CREATE OR REPLACE FUNCTION public.operator_finish_otp(p_request_id uuid, p_delivered boolean, p_provider_id text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE row_otp public.otp_verifications; safe_code text;
BEGIN
  SELECT * INTO row_otp FROM public.otp_verifications WHERE id=p_request_id FOR UPDATE;
  IF row_otp.id IS NULL OR row_otp.delivery_status<>'sending' THEN
    RETURN jsonb_build_object('success',false,'code','invalid_request');
  END IF;
  IF row_otp.expires_at<=now() THEN
    UPDATE public.otp_verifications SET delivery_status='failed',verified=true,
      otp_code_hash=NULL,msg91_status='expired' WHERE id=p_request_id;
    RETURN jsonb_build_object('success',false,'code','invalid_request');
  END IF;
  safe_code := CASE WHEN p_provider_id IN ('provider_configuration','provider_auth',
    'provider_validation','provider_rate_limited','provider_rejected',
    'provider_invalid_response','provider_unavailable') THEN p_provider_id
    ELSE 'provider_unavailable' END;
  UPDATE public.otp_verifications SET
    delivery_status=CASE WHEN p_delivered THEN 'accepted' ELSE 'failed' END,
    verified=NOT p_delivered,
    msg91_request_id=CASE WHEN p_delivered THEN left(p_provider_id,255) ELSE NULL END,
    msg91_status=CASE WHEN p_delivered THEN 'success' ELSE safe_code END,
    otp_code_hash=CASE WHEN p_delivered THEN otp_code_hash ELSE NULL END
    WHERE id=p_request_id;
  RETURN jsonb_build_object('success',true);
END $$;
NOTIFY pgrst,'reload schema';
