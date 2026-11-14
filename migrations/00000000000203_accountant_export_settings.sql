-- Migration 203 (WH-158): the ledger names of the accountant export.
--
-- The accountant pack's Tally files (migration 204 and the generate-accountant-pack function) name the accountant's own ledgers for rent,
-- exempt rent, labour, the three tax heads, discount, round-off and the receipt ledgers of each payment mode. A facility sets them once,
-- under Settings > Warehouse tools > Accountant export. They are the keys of ONE settings row, public.system_settings key
-- 'accountant_export', a JSON object; a key that is missing means "the default". The 13 keys and their defaults, in this order (also the
-- order of the screen and of every check below):
--   storage_taxable "Cold Storage Rent", storage_exempt "Cold Storage Rent (Exempt)", labour "Labour Charges", cgst "CGST", sgst "SGST",
--   igst "IGST", discount "Discount Allowed", round_off "Round Off", receipt_cash "Cash", receipt_upi "Bank", receipt_bank_transfer "Bank",
--   receipt_cheque "Bank", receipt_other "Bank".
--  * warehouse_security.accountant_ledger_defaults() and warehouse_security.accountant_ledgers(): the defaults, and the 13 names in force
--    (stored value, else the default). No grants.
--  * public.get_accountant_ledgers(): {success, data: {ledgers, defaults, saved}}; saved = the row holds names.
--  * public.set_accountant_ledgers(p_ledgers jsonb): exactly the 13 keys, each a name trimmed of spaces, 1 to 60 characters, no control
--    characters. Refusals (warehouse_security.refuse, with "field" for a name): LEDGER_KEYS first, then for each key in the order above
--    LEDGER_NAME_REQUIRED, LEDGER_NAME_TOO_LONG, LEDGER_NAME_INVALID; the first refusal is answered and nothing is stored. A change writes
--    one audit_log row (table_name 'accountant_export', old and new names); the same names again write nothing. Answer as get, plus
--    data.changed.
-- Both are for administrators only: migrations/definitions/00_authorize_rpc.sql names them in its administrators-only list, and each body
-- also refuses anyone else (42501 "Administrator required"), so a body does not depend on the definition file having been applied yet.
-- service_role passes.
--
-- No role is created, altered or dropped. No table or column change; no pg_temp helper.

INSERT INTO public.system_settings (key, value, description) VALUES
  ('accountant_export', '{}', 'The ledger names of the accountant export (JSON; migration 203)')
ON CONFLICT (key) DO NOTHING;

CREATE FUNCTION warehouse_security.accountant_ledger_defaults() RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT jsonb_build_object(
    'storage_taxable', 'Cold Storage Rent',
    'storage_exempt', 'Cold Storage Rent (Exempt)',
    'labour', 'Labour Charges',
    'cgst', 'CGST',
    'sgst', 'SGST',
    'igst', 'IGST',
    'discount', 'Discount Allowed',
    'round_off', 'Round Off',
    'receipt_cash', 'Cash',
    'receipt_upi', 'Bank',
    'receipt_bank_transfer', 'Bank',
    'receipt_cheque', 'Bank',
    'receipt_other', 'Bank')
$$;
ALTER FUNCTION warehouse_security.accountant_ledger_defaults() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.accountant_ledger_defaults() FROM PUBLIC, anon, authenticated, service_role;

-- The stored object of the row ('{}' when the row is missing or does not hold an object).
CREATE FUNCTION warehouse_security.accountant_ledgers_stored() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  SELECT COALESCE((SELECT CASE WHEN value ~ '^\s*\{' THEN value::jsonb END FROM public.system_settings WHERE key = 'accountant_export'), '{}'::jsonb)
$$;
ALTER FUNCTION warehouse_security.accountant_ledgers_stored() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.accountant_ledgers_stored() FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION warehouse_security.accountant_ledgers() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  SELECT jsonb_object_agg(d.key,
           CASE WHEN jsonb_typeof(s.j -> d.key) = 'string' AND btrim(s.j ->> d.key) <> '' THEN s.j ->> d.key ELSE d.value #>> '{}' END)
    FROM jsonb_each(warehouse_security.accountant_ledger_defaults()) d
   CROSS JOIN (SELECT warehouse_security.accountant_ledgers_stored() AS j) s
$$;
ALTER FUNCTION warehouse_security.accountant_ledgers() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.accountant_ledgers() FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION warehouse_security.accountant_ledgers_answer() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  SELECT jsonb_build_object(
    'ledgers', warehouse_security.accountant_ledgers(),
    'defaults', warehouse_security.accountant_ledger_defaults(),
    'saved', warehouse_security.accountant_ledgers_stored() <> '{}'::jsonb)
$$;
ALTER FUNCTION warehouse_security.accountant_ledgers_answer() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.accountant_ledgers_answer() FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.get_accountant_ledgers() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_accountant_ledgers', jsonb_build_object());
  IF warehouse_security.active_role() IS DISTINCT FROM 'admin' AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  RETURN jsonb_build_object('success', true, 'data', warehouse_security.accountant_ledgers_answer());
END $$;
ALTER FUNCTION public.get_accountant_ledgers() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_accountant_ledgers() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_accountant_ledgers() TO authenticated, service_role;

CREATE FUNCTION public.set_accountant_ledgers(p_ledgers jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  -- The keys in the order of the checks (and of the screen).
  v_keys constant text[] := ARRAY['storage_taxable', 'storage_exempt', 'labour', 'cgst', 'sgst', 'igst', 'discount', 'round_off',
                                  'receipt_cash', 'receipt_upi', 'receipt_bank_transfer', 'receipt_cheque', 'receipt_other'];
  v_key text;
  v_value text;
  v_new jsonb := '{}'::jsonb;
  v_stored jsonb;
  v_old jsonb;
  v_changed boolean := false;
BEGIN
  PERFORM warehouse_security.authorize_rpc('set_accountant_ledgers', jsonb_build_object());
  IF warehouse_security.active_role() IS DISTINCT FROM 'admin' AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  IF p_ledgers IS NULL OR jsonb_typeof(p_ledgers) <> 'object'
     OR (SELECT count(*) FROM jsonb_object_keys(p_ledgers)) <> cardinality(v_keys)
     OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_ledgers) k WHERE k <> ALL (v_keys)) THEN
    RETURN warehouse_security.refuse('LEDGER_KEYS', 'Send all 13 ledger names and nothing else.');
  END IF;
  FOREACH v_key IN ARRAY v_keys LOOP
    v_value := CASE WHEN jsonb_typeof(p_ledgers -> v_key) = 'string' THEN btrim(p_ledgers ->> v_key, ' ') END;
    IF v_value IS NULL OR v_value = '' THEN
      RETURN warehouse_security.refuse('LEDGER_NAME_REQUIRED', 'Enter a ledger name.', jsonb_build_object('field', v_key));
    END IF;
    IF char_length(v_value) > 60 THEN
      RETURN warehouse_security.refuse('LEDGER_NAME_TOO_LONG', 'A ledger name has at most 60 characters.', jsonb_build_object('field', v_key));
    END IF;
    IF v_value ~ '[\x01-\x1f\x7f-\x9f  ]' THEN
      RETURN warehouse_security.refuse('LEDGER_NAME_INVALID', 'A ledger name can''t hold control characters.', jsonb_build_object('field', v_key));
    END IF;
    v_new := v_new || jsonb_build_object(v_key, v_value);
  END LOOP;

  SELECT COALESCE((SELECT CASE WHEN value ~ '^\s*\{' THEN value::jsonb END FROM public.system_settings
                    WHERE key = 'accountant_export' FOR UPDATE), '{}'::jsonb) INTO v_stored;
  IF v_new IS DISTINCT FROM v_stored THEN
    v_old := warehouse_security.accountant_ledgers();
    INSERT INTO public.system_settings (key, value, description)
    VALUES ('accountant_export', v_new::text, 'The ledger names of the accountant export (JSON; migration 203)')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    INSERT INTO public.audit_log (table_name, action, user_id, old_data, new_data)
    VALUES ('accountant_export', 'UPDATED', public.get_current_user_profile_id(), v_old, warehouse_security.accountant_ledgers());
    v_changed := true;
  END IF;
  RETURN jsonb_build_object('success', true,
    'data', warehouse_security.accountant_ledgers_answer() || jsonb_build_object('changed', v_changed));
END $$;
ALTER FUNCTION public.set_accountant_ledgers(jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.set_accountant_ledgers(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_accountant_ledgers(jsonb) TO authenticated, service_role;
