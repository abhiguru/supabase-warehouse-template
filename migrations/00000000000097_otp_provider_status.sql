-- Migration 97: what the SMS provider's answer is recorded as, and a ceiling on provider requests
-- (owner decisions D14 and D15 of 2026-10-17; review findings TW-CFG-003 and TW-CFG-005).
--
-- 1. A success without a provider request ID (D14). operator_finish_otp(.., true, NULL) stored the
--    same msg91_status 'success' as a send with an ID. It now stores 'success_no_id'. The code is
--    still treated as sent (delivery_status 'accepted', the hash is kept): MSG91 accepted the request,
--    so voiding the code would hurt a user whose SMS is probably on its way, and a second SMS would
--    be billed. The status makes such sends countable (see 3).
-- 2. provider_ambiguous (D15). A timeout or an abort can happen after MSG91 accepted and billed a
--    request. The edge function now reports it as the code provider_ambiguous. Every other failure
--    gives the phone and the warehouse their allowance back (migration 44, 47); provider_ambiguous,
--    like provider_validation, does not, and its send stays in warehouse_security.otp_send_log.
-- 3. A provider-attempt counter and a daily ceiling (D15). warehouse_security.otp_provider_attempts has
--    one row per code request: the HTTP requests made to the provider for it (a retry makes two),
--    whatever the outcome, never refunded. operator_prepare_otp reserves one attempt when it issues
--    a code, and operator_finish_otp replaces the reservation by the real number (the new optional
--    argument p_attempts; NULL counts one). With the auth_config key otp_daily_provider_attempt_cap
--    set to a whole number, operator_prepare_otp answers rate_limited, and nothing is sent or
--    counted anywhere else, once the attempts of the last 24 hours reach it. The key is absent until
--    the operator sets it, and an absent or malformed value means no ceiling. Text '0' blocks every
--    send, as the other caps do: that is the documented no-send switch.
--
-- get_otp_stats (the reader of msg91_status = 'success', service key only) counts success_no_id too.
-- operator_prepare_otp is patched in place and operator_finish_otp is replaced by the same body with
-- a fourth, optional argument (the old three-argument signature is dropped, so a call with three
-- arguments still resolves to the new function). Owner, SECURITY DEFINER, search_path and grants are
-- kept and checked below. Like the other operator_* functions they are for the service key only.

-- Replaces one marker in a function definition text, failing unless it occurs exactly `expected`
-- times. Returns the new text. Dropped at the end of this migration.
CREATE FUNCTION pg_temp.patch_text(definition text, fn regprocedure, marker text, replacement text, expected integer DEFAULT 1) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE occurrences integer;
BEGIN
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker,80);
  END IF;
  RETURN replace(definition,marker,replacement);
END $$;

-- ---------------------------------------------------------------------------
-- The counter
-- ---------------------------------------------------------------------------
CREATE TABLE warehouse_security.otp_provider_attempts (
  request_id uuid PRIMARY KEY,
  attempts integer NOT NULL CHECK (attempts BETWEEN 0 AND 5),
  status text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX otp_provider_attempts_created ON warehouse_security.otp_provider_attempts(created_at);
ALTER TABLE warehouse_security.otp_provider_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON warehouse_security.otp_provider_attempts FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE warehouse_security.otp_provider_attempts IS
  'Migration 97: provider HTTP requests per code request (never refunded), kept two days; status is the msg91_status of the send (success, success_no_id or a provider_* code).';

DO $patch$
DECLARE
  prepare_fn regprocedure := 'public.operator_prepare_otp(text,inet)'::regprocedure;
  old_finish regprocedure := 'public.operator_finish_otp(uuid,boolean,text)'::regprocedure;
  new_finish regprocedure;
  definition text;
  prepare_owner oid; prepare_secdef boolean; prepare_acl aclitem[]; prepare_config text[];
  finish_owner oid; finish_secdef boolean; finish_acl aclitem[]; finish_config text[];
  stats_fn regprocedure; stats_owner oid; stats_secdef boolean; stats_acl aclitem[]; stats_config text[];
  after_owner oid; after_secdef boolean; after_acl aclitem[]; after_config text[];
BEGIN
  -- 1. operator_prepare_otp: the ceiling and the reservation.
  SELECT proowner, prosecdef, proacl, proconfig INTO STRICT prepare_owner, prepare_secdef, prepare_acl, prepare_config
    FROM pg_proc WHERE oid = prepare_fn;
  definition := pg_get_functiondef(prepare_fn);
  definition := pg_temp.patch_text(definition, prepare_fn,
$m$  phone_cap integer; trusted_reserve integer; day_total integer; day_open integer;
$m$, $r$  phone_cap integer; trusted_reserve integer; day_total integer; day_open integer;
  provider_cap integer; provider_used integer;
$r$);
  definition := pg_temp.patch_text(definition, prepare_fn,
$m$  IF global_count >= global_cap OR (NOT known AND unknown_used >= unknown_cap) THEN
    RETURN jsonb_build_object('success',false,'code','rate_limited');
  END IF;
$m$, $r$  IF global_count >= global_cap OR (NOT known AND unknown_used >= unknown_cap) THEN
    RETURN jsonb_build_object('success',false,'code','rate_limited');
  END IF;
  -- Migration 97: the operator's ceiling on provider requests in any 24 hours. Checked here, with
  -- the warehouse row locked, and before any counter is charged, so a refusal sends and counts nothing.
  SELECT value INTO cap_text FROM warehouse_security.auth_config WHERE key='otp_daily_provider_attempt_cap';
  provider_cap := CASE WHEN cap_text ~ '^[0-9]{1,7}$' THEN cap_text::integer END;
  IF provider_cap IS NOT NULL THEN
    SELECT COALESCE(sum(a.attempts),0) INTO provider_used FROM warehouse_security.otp_provider_attempts a
      WHERE a.created_at>now()-interval '24 hours';
    IF provider_used >= provider_cap THEN RETURN jsonb_build_object('success',false,'code','rate_limited'); END IF;
  END IF;
$r$);
  definition := pg_temp.patch_text(definition, prepare_fn,
$m$  INSERT INTO warehouse_security.otp_send_log(request_id,phone_number,lane,ip_address) VALUES (request_id,phone,lane,p_ip_address);
$m$, $r$  INSERT INTO warehouse_security.otp_send_log(request_id,phone_number,lane,ip_address) VALUES (request_id,phone,lane,p_ip_address);
  -- Migration 97: one provider attempt is reserved now; operator_finish_otp records the real number.
  DELETE FROM warehouse_security.otp_provider_attempts WHERE created_at<now()-interval '2 days';
  INSERT INTO warehouse_security.otp_provider_attempts(request_id,attempts) VALUES (request_id,1);
$r$);
  EXECUTE definition;
  SELECT proowner, prosecdef, proacl, proconfig INTO STRICT after_owner, after_secdef, after_acl, after_config
    FROM pg_proc WHERE oid = prepare_fn;
  IF after_owner IS DISTINCT FROM prepare_owner OR NOT after_secdef OR after_secdef IS DISTINCT FROM prepare_secdef
     OR after_acl IS DISTINCT FROM prepare_acl OR after_config IS DISTINCT FROM prepare_config THEN
    RAISE EXCEPTION 'operator_prepare_otp changed owner, SECURITY DEFINER, grants or settings';
  END IF;

  -- 2. operator_finish_otp: the new status, the new code, the record of attempts. The signature gains
  -- p_attempts, so the old function is dropped and the patched text creates the new one.
  SELECT proowner, prosecdef, proacl, proconfig INTO STRICT finish_owner, finish_secdef, finish_acl, finish_config
    FROM pg_proc WHERE oid = old_finish;
  definition := pg_get_functiondef(old_finish);
  definition := pg_temp.patch_text(definition, old_finish,
$m$p_provider_id text DEFAULT NULL::text)$m$, $r$p_provider_id text DEFAULT NULL::text, p_attempts integer DEFAULT NULL::integer)$r$);
  definition := pg_temp.patch_text(definition, old_finish,
$m$    'provider_invalid_response','provider_unavailable') THEN p_provider_id
$m$, $r$    'provider_invalid_response','provider_unavailable','provider_ambiguous') THEN p_provider_id
$r$);
  definition := pg_temp.patch_text(definition, old_finish,
$m$    msg91_request_id=CASE WHEN p_delivered THEN left(p_provider_id,255) ELSE NULL END,
$m$, $r$    msg91_request_id=CASE WHEN p_delivered THEN left(NULLIF(p_provider_id,''),255) ELSE NULL END,
$r$);
  definition := pg_temp.patch_text(definition, old_finish,
$m$    msg91_status=CASE WHEN p_delivered THEN 'success' ELSE safe_code END,
$m$, $r$    msg91_status=CASE WHEN p_delivered AND NULLIF(p_provider_id,'') IS NULL THEN 'success_no_id'
      WHEN p_delivered THEN 'success' ELSE safe_code END,
$r$);
  definition := pg_temp.patch_text(definition, old_finish,
$m$    WHERE id=p_request_id;
  IF NOT p_delivered AND safe_code <> 'provider_validation' AND row_otp.quota_lane IS NOT NULL THEN
$m$, $r$    WHERE id=p_request_id;
  -- Migration 97: the provider requests made for this code, never refunded (NULL counts one).
  INSERT INTO warehouse_security.otp_provider_attempts(request_id,attempts,status)
  VALUES (p_request_id,least(greatest(COALESCE(p_attempts,1),0),5),
    (SELECT v.msg91_status FROM public.otp_verifications v WHERE v.id=p_request_id))
  ON CONFLICT (request_id) DO UPDATE SET attempts=EXCLUDED.attempts, status=EXCLUDED.status;
  -- A timeout may follow an accepted request: provider_ambiguous is not given back (migration 97).
  IF NOT p_delivered AND safe_code NOT IN ('provider_validation','provider_ambiguous') AND row_otp.quota_lane IS NOT NULL THEN
$r$);
  DROP FUNCTION public.operator_finish_otp(uuid,boolean,text);
  EXECUTE definition;
  new_finish := 'public.operator_finish_otp(uuid,boolean,text,integer)'::regprocedure;
  REVOKE EXECUTE ON FUNCTION public.operator_finish_otp(uuid,boolean,text,integer) FROM PUBLIC, anon, authenticated;
  GRANT EXECUTE ON FUNCTION public.operator_finish_otp(uuid,boolean,text,integer) TO service_role;
  SELECT proowner, prosecdef, proacl, proconfig INTO STRICT after_owner, after_secdef, after_acl, after_config
    FROM pg_proc WHERE oid = new_finish;
  IF after_owner IS DISTINCT FROM finish_owner OR NOT after_secdef OR after_secdef IS DISTINCT FROM finish_secdef
     OR after_acl IS DISTINCT FROM finish_acl OR after_config IS DISTINCT FROM finish_config THEN
    RAISE EXCEPTION 'operator_finish_otp changed owner, SECURITY DEFINER, grants or settings: % became %', finish_acl, after_acl;
  END IF;

  -- 3. The one reader of msg91_status = 'success' (get_otp_stats, service key only) counts a send without
  -- an ID as sent too.
  stats_fn := 'public.get_otp_stats(character varying)'::regprocedure;
  SELECT proowner, prosecdef, proacl, proconfig INTO STRICT stats_owner, stats_secdef, stats_acl, stats_config
    FROM pg_proc WHERE oid = stats_fn;
  EXECUTE pg_temp.patch_text(pg_get_functiondef(stats_fn), stats_fn,
$m$COUNT(*) FILTER (WHERE msg91_status = 'success') as successful_sent,$m$,
$r$COUNT(*) FILTER (WHERE msg91_status IN ('success','success_no_id')) as successful_sent,$r$);
  SELECT proowner, prosecdef, proacl, proconfig INTO STRICT after_owner, after_secdef, after_acl, after_config
    FROM pg_proc WHERE oid = stats_fn;
  IF after_owner IS DISTINCT FROM stats_owner OR after_secdef IS DISTINCT FROM stats_secdef
     OR after_acl IS DISTINCT FROM stats_acl OR after_config IS DISTINCT FROM stats_config THEN
    RAISE EXCEPTION 'get_otp_stats changed owner, SECURITY DEFINER, grants or settings';
  END IF;
END $patch$;

NOTIFY pgrst, 'reload schema';
