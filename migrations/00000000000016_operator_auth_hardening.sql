-- A local demo can have issued real signed sessions before operator mode was
-- installed. The fixed demo numbers have no production SMS path, so revoke those
-- sessions at upgrade rather than allowing their old JWTs to remain usable.
DELETE FROM warehouse_security.refresh_sessions s
USING public.user_profiles p
WHERE s.user_id=p.auth_user_id AND p.mobile ~ '^91000000000[1-9]$';

-- A provider response arriving after challenge expiry cannot activate the OTP.
CREATE OR REPLACE FUNCTION public.operator_finish_otp(p_request_id uuid, p_delivered boolean, p_provider_id text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE row_otp public.otp_verifications;
BEGIN
  SELECT * INTO row_otp FROM public.otp_verifications WHERE id=p_request_id FOR UPDATE;
  IF row_otp.id IS NULL OR row_otp.delivery_status<>'sending' THEN
    RETURN jsonb_build_object('success',false,'code','invalid_request');
  END IF;
  IF row_otp.expires_at<=now() THEN
    UPDATE public.otp_verifications SET delivery_status='failed',verified=true,otp_code_hash=NULL
      WHERE id=p_request_id;
    RETURN jsonb_build_object('success',false,'code','invalid_request');
  END IF;
  UPDATE public.otp_verifications SET delivery_status=CASE WHEN p_delivered THEN 'accepted' ELSE 'failed' END,
    verified=NOT p_delivered, msg91_request_id=left(p_provider_id,255),
    otp_code_hash=CASE WHEN p_delivered THEN otp_code_hash ELSE NULL END WHERE id=p_request_id;
  RETURN jsonb_build_object('success',true);
END $$;
