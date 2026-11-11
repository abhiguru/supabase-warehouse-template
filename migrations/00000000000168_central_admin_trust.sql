-- Migration 168 (WH-148): the central-sign-in trust question for administrators.
--
-- operator_central_exchange (ten-argument form) asked for the facility's own SMS code only when auth_config key central_local_code is
-- 'on' (everyone). It now also asks when auth_config key central_admin_trust is 'no' and the profile's role is 'admin' (setup.sh
-- --central-admin-trust no). The code is asked every time, as central_local_code does, and linking waits for it (migration 154's rule:
-- a profile found by phone number is linked only after a correct code, pending profiles included). Other roles are unchanged,
-- central_local_code on still covers everyone and wins, and the key being absent or 'yes' is today's rule. Service accounts, the
-- refusals (rejected, disabled, deactivated), identity_conflict and the single-use token are untouched: the new test sits where the
-- central_local_code test already is, after them.
--
-- The function is patched as stored: each marker must occur exactly once, and a function that already carries the WH-148 tag is
-- refused, so a second run fails instead of patching again. CREATE OR REPLACE keeps owner, search_path and grants.

DROP FUNCTION IF EXISTS pg_temp.patch_function(regprocedure, text[], text[]);
CREATE FUNCTION pg_temp.patch_function(p_function regprocedure, p_old text[], p_new text[]) RETURNS void
    LANGUAGE plpgsql AS $$
DECLARE
  v_def text := pg_get_functiondef(p_function);
  v_count integer;
  i integer;
BEGIN
  IF array_length(p_old, 1) IS DISTINCT FROM array_length(p_new, 1) THEN
    RAISE EXCEPTION '%: the marker list and the replacement list differ in length', p_function;
  END IF;
  IF position('WH-148' IN v_def) > 0 THEN
    RAISE EXCEPTION '%: already patched by migration 168', p_function;
  END IF;
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

SELECT pg_temp.patch_function('public.operator_central_exchange(text,text,text,text,timestamptz,text,text,inet,text,text)'::regprocedure,
ARRAY[
-- 1. a profile found by phone number (not linked yet)
$m$  IF by_phone.id IS NOT NULL
     AND COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='central_local_code'),'off') = 'on' THEN$m$,
-- 2. a profile found by subject (already linked)
$m$  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='central_local_code'),'off') = 'on' THEN
    IF p_otp_code IS NULL THEN$m$
],
ARRAY[
$m$  -- WH-148 (migration 168): central_admin_trust='no' asks an administrator for the facility's code as central_local_code does for everyone.
  IF by_phone.id IS NOT NULL
     AND (COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='central_local_code'),'off') = 'on'
          OR (by_phone.role = 'admin'
              AND COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='central_admin_trust'),'yes') = 'no')) THEN$m$,
$m$  IF COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='central_local_code'),'off') = 'on'
     OR (profile.role = 'admin'
         AND COALESCE((SELECT value FROM warehouse_security.auth_config WHERE key='central_admin_trust'),'yes') = 'no') THEN
    IF p_otp_code IS NULL THEN$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);
