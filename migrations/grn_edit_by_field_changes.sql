-- Topic "edit GRN by field changes" (WH-303; contract tech/app-offline-edit-grn.md sections 5.1, 5.2, 5.3, 5.4 and 5.8), with WH-303's part of
-- the topics "GRN field marks" and "replaced entries". Named by topic; its number is taken when the work is assembled for main. It needs
-- the topics "GRN field marks", "replaced entries" and "lot rack and mark change" (WH-302) applied before it.
--  1. Field marks for every field an offline edit sends: the GRN's date, customer_id, sender, supervisor, registration, note, leon and
--     pricing_mode (lot_id NULL), and a lot's item, packaging, qty and weight beside line, rack and package_mark. Row triggers, so every
--     write path is covered (save_grn, update_grn, the quick change, this function).
--  2. warehouse_security.record_grn_replacement: the field entry it returns gains kind and lot_id (additive), and a second signature
--     records a "Lines added" entry (kind line_added: the line's {item_name, qty, packaging}, who added it and when; newer_* NULL).
--  3. public.apply_grn_changes(p_grn_id, p_changes, p_request_key): a GRN edit sent as field changes {from, to}, lines added and lines
--     removed, never the whole GRN. Order: gate -> shape (GRN_CHANGE_INVALID) -> request-key replay -> the GRN locked -> checks -> writes
--     -> the answer kept under the key with no expiry. Last sent wins (no STALE_RECORD). All or nothing (Product PQ1): one refused change
--     refuses the whole item; the answer is the first refused change's refusal (in the order header, lots, linesAdded, linesRemoved) with
--     refused: [{path, code}] listing every refused change. The checks and the write are update_grn's own (definitions/update_grn.sql):
--     the function sends update_grn the stored GRN with the changes on top, so every refusal of the online save applies unchanged; each
--     change is also tried alone, rolled back, to list every refusal. Checked here: GRN_NOT_FOUND, IMPORTED_READ_ONLY, LOT_NOT_FOUND, and
--     GRN_CUSTOMER_LOCKED and GRN_PRICING_MODE_LOCKED (update_grn's plain raises for them, same conditions). A change whose `to` equals the
--     stored value is applied and writes nothing; a call that writes nothing does not move the GRN's updated_at.
--  4. get_submission_result finds this function's answers while the GRN exists and is not deleted.
-- No role is created, altered or dropped; no pg_temp helper is left behind.

-- ===== 1. field marks =====
CREATE OR REPLACE FUNCTION warehouse_security.record_lot_field_marks() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_by uuid;
  v_field text;
BEGIN
  -- Who: the signed-in person's profile. The import and a session with no profile leave it NULL (not known).
  IF current_setting('warehouse.import', true) IS DISTINCT FROM 'on' THEN
    SELECT p.id INTO v_by FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();
  END IF;
  FOR v_field IN
    SELECT f FROM (VALUES
      ('line', TG_OP = 'INSERT'),
      ('item', TG_OP = 'UPDATE' AND NEW.item_id IS DISTINCT FROM OLD.item_id),
      ('packaging', TG_OP = 'UPDATE' AND NEW.packaging IS DISTINCT FROM OLD.packaging),
      ('qty', TG_OP = 'UPDATE' AND NEW.qty IS DISTINCT FROM OLD.qty),
      ('weight', TG_OP = 'UPDATE' AND NEW.weight IS DISTINCT FROM OLD.weight),
      ('rack', TG_OP = 'UPDATE' AND NEW.rack IS DISTINCT FROM OLD.rack),
      ('package_mark', TG_OP = 'UPDATE' AND NEW.package_mark IS DISTINCT FROM OLD.package_mark)
    ) AS t(f, marked) WHERE marked
  LOOP
    INSERT INTO warehouse_security.grn_field_marks (grn_id, lot_id, field, set_by, set_at)
    VALUES (NEW.gr_id, NEW.id, v_field, v_by, now())
    ON CONFLICT (grn_id, (COALESCE(lot_id, '00000000-0000-0000-0000-000000000000'::uuid)), field)
    DO UPDATE SET set_by = EXCLUDED.set_by, set_at = EXCLUDED.set_at;
  END LOOP;
  RETURN NULL;
END $$;

DROP TRIGGER record_lot_field_marks ON public.goodsreceived_trl;
CREATE TRIGGER record_lot_field_marks AFTER INSERT OR UPDATE OF item_id, packaging, qty, weight, rack, package_mark ON public.goodsreceived_trl
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.record_lot_field_marks();

CREATE FUNCTION warehouse_security.record_grn_field_marks() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_by uuid;
  v_field text;
BEGIN
  IF current_setting('warehouse.import', true) IS DISTINCT FROM 'on' THEN
    SELECT p.id INTO v_by FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();
  END IF;
  -- The field names of the offline edit's body (contract 3.2): sender and supervisor are each one field (id and name).
  FOR v_field IN
    SELECT f FROM (VALUES
      ('date', NEW.date IS DISTINCT FROM OLD.date),
      ('customer_id', NEW.customer_id IS DISTINCT FROM OLD.customer_id),
      ('sender', NEW.sender_id IS DISTINCT FROM OLD.sender_id OR NEW.sender_name IS DISTINCT FROM OLD.sender_name),
      ('supervisor', NEW.supervisor_id IS DISTINCT FROM OLD.supervisor_id OR NEW.supervisor_name IS DISTINCT FROM OLD.supervisor_name),
      ('registration', NEW.registration IS DISTINCT FROM OLD.registration),
      ('note', NEW.note IS DISTINCT FROM OLD.note),
      ('leon', NEW.leon IS DISTINCT FROM OLD.leon),
      ('pricing_mode', NEW.pricing_mode IS DISTINCT FROM OLD.pricing_mode)
    ) AS t(f, marked) WHERE marked
  LOOP
    INSERT INTO warehouse_security.grn_field_marks (grn_id, lot_id, field, set_by, set_at)
    VALUES (NEW.id, NULL, v_field, v_by, now())
    ON CONFLICT (grn_id, (COALESCE(lot_id, '00000000-0000-0000-0000-000000000000'::uuid)), field)
    DO UPDATE SET set_by = EXCLUDED.set_by, set_at = EXCLUDED.set_at;
  END LOOP;
  RETURN NULL;
END $$;
ALTER FUNCTION warehouse_security.record_grn_field_marks() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.record_grn_field_marks() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER record_grn_field_marks AFTER UPDATE OF date, customer_id, sender_id, sender_name, supervisor_id, supervisor_name,
    registration, note, leon, pricing_mode ON public.goodsreceived
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.record_grn_field_marks();

-- ===== 2. the writer of replaced entries =====
-- The field entry, as topic "replaced entries" wrote it, now also returning kind and lot_id (apply_grn_changes lists entries of
-- several lots). A recorded_at of NULL stays NULL; a later one than the server time is stored as the server time.
CREATE OR REPLACE FUNCTION warehouse_security.record_grn_replacement(
    p_grn_id uuid, p_lot_id uuid, p_field text, p_newer_value text, p_sent_value text,
    p_sent_by uuid, p_request_key text, p_recorded_at timestamptz DEFAULT NULL)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_mark_by uuid;
  v_mark_at timestamptz;
  v_marked boolean;
  v_sent_at timestamptz := now();
  v_recorded timestamptz;
  v_id uuid;
BEGIN
  SELECT m.set_by, m.set_at, true INTO v_mark_by, v_mark_at, v_marked
    FROM warehouse_security.grn_field_marks m
    WHERE m.grn_id = p_grn_id AND m.lot_id IS NOT DISTINCT FROM p_lot_id AND m.field = p_field;
  -- The sender's own earlier value (their other phone): written by the caller, but no entry.
  IF COALESCE(v_marked, false) AND v_mark_by IS NOT NULL AND v_mark_by = p_sent_by THEN
    RETURN NULL;
  END IF;
  -- NULL stays NULL (no phone time sent); LEAST alone would ignore the NULL and store sent_at.
  v_recorded := CASE WHEN p_recorded_at IS NULL THEN NULL ELSE LEAST(p_recorded_at, v_sent_at) END;
  INSERT INTO warehouse_security.grn_replacements
    (grn_id, lot_id, customer_id, kind, field, newer_value, newer_by, newer_at, sent_value, sent_by, sent_at, recorded_at, request_key)
  VALUES (p_grn_id, p_lot_id, (SELECT g.customer_id FROM public.goodsreceived g WHERE g.id = p_grn_id), 'field', p_field,
          to_jsonb(p_newer_value), v_mark_by, v_mark_at, to_jsonb(p_sent_value), p_sent_by, v_sent_at, v_recorded, p_request_key)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object(
    'id', v_id, 'kind', 'field', 'lot_id', p_lot_id, 'field', p_field, 'newer', p_newer_value, 'sent', p_sent_value,
    'newer_by', v_mark_by, 'newer_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = v_mark_by), 'newer_at', v_mark_at,
    'sent_by', p_sent_by, 'sent_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = p_sent_by),
    'sent_at', v_sent_at, 'recorded_at', v_recorded);
END $$;

-- A "Lines added" entry (Product PQ6): one line, its adder and when the server wrote it; recorded_at is the phone time of this send's
-- line (NULL for another person's line: a field mark holds no phone time), never later than sent_at.
CREATE FUNCTION warehouse_security.record_grn_replacement(
    p_grn_id uuid, p_lot_id uuid, p_sent_value jsonb, p_sent_by uuid, p_sent_at timestamptz, p_request_key text, p_recorded_at timestamptz)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_sent_at timestamptz := COALESCE(p_sent_at, now());
  v_recorded timestamptz := CASE WHEN p_recorded_at IS NULL THEN NULL ELSE LEAST(p_recorded_at, COALESCE(p_sent_at, now())) END;
  v_id uuid;
BEGIN
  INSERT INTO warehouse_security.grn_replacements
    (grn_id, lot_id, customer_id, kind, field, newer_value, newer_by, newer_at, sent_value, sent_by, sent_at, recorded_at, request_key)
  VALUES (p_grn_id, p_lot_id, (SELECT g.customer_id FROM public.goodsreceived g WHERE g.id = p_grn_id), 'line_added', NULL,
          NULL, NULL, NULL, p_sent_value, p_sent_by, v_sent_at, v_recorded, p_request_key)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object(
    'id', v_id, 'kind', 'line_added', 'lot_id', p_lot_id, 'field', NULL, 'newer', NULL, 'sent', p_sent_value,
    'newer_by', NULL, 'newer_by_name', NULL, 'newer_at', NULL,
    'sent_by', p_sent_by, 'sent_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = p_sent_by),
    'sent_at', v_sent_at, 'recorded_at', v_recorded);
END $$;
ALTER FUNCTION warehouse_security.record_grn_replacement(uuid, uuid, jsonb, uuid, timestamptz, text, timestamptz) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.record_grn_replacement(uuid, uuid, jsonb, uuid, timestamptz, text, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;

-- ===== 3. apply_grn_changes and its helpers =====
-- One field value as compared: the stored value, `from` and `to` alike (blank text is NULL; rack and mark with the digits 0-9; a
-- paired value by its id, sender and supervisor by id and trimmed name; the date by its India day; leon NULL is false; pricing NULL
-- is MONTHLY, as update_grn reads them).
CREATE FUNCTION warehouse_security.grn_change_key(p_field text, p_value jsonb) RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT CASE
    WHEN p_field = 'leon' THEN COALESCE((CASE WHEN jsonb_typeof(p_value) = 'boolean' THEN p_value #>> '{}' END)::boolean, false)::text
    WHEN p_field = 'pricing_mode' THEN upper(COALESCE(NULLIF(btrim(CASE WHEN jsonb_typeof(p_value) = 'string' THEN p_value #>> '{}' END), ''), 'MONTHLY'))
    WHEN p_value IS NULL OR jsonb_typeof(p_value) = 'null' THEN NULL
    WHEN p_field IN ('customer_id', 'item') THEN lower(p_value ->> 'id')
    WHEN p_field IN ('sender', 'supervisor') THEN
      concat_ws('|', COALESCE(lower(p_value ->> 'id'), ''), COALESCE(warehouse_security.trimmed_reason(p_value ->> 'name'), ''))
    WHEN p_field = 'date' THEN warehouse_security.business_date((p_value #>> '{}')::timestamptz)::text
    WHEN p_field IN ('qty', 'weight') THEN ((p_value #>> '{}')::numeric)::bigint::text
    WHEN p_field IN ('rack', 'package_mark') THEN NULLIF(btrim(warehouse_security.ascii_digits(p_value #>> '{}')), '')
    WHEN p_field = 'registration' THEN
      NULLIF(regexp_replace(regexp_replace(p_value #>> '{}', '^[\s ]+|[\s ]+$', '', 'g'), '[\s ]+', ' ', 'g'), '')
    ELSE NULLIF(btrim(p_value #>> '{}'), '')
  END
$$;
ALTER FUNCTION warehouse_security.grn_change_key(text, jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_change_key(text, jsonb) FROM PUBLIC, anon, authenticated, service_role;

-- One field value as a replaced entry shows it: a paired value by its name, the others as compared.
CREATE FUNCTION warehouse_security.grn_change_text(p_field text, p_value jsonb) RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT CASE WHEN p_field IN ('customer_id', 'item', 'sender', 'supervisor')
              THEN CASE WHEN jsonb_typeof(p_value) = 'object' THEN NULLIF(btrim(p_value ->> 'name'), '') END
              ELSE warehouse_security.grn_change_key(p_field, p_value) END
$$;
ALTER FUNCTION warehouse_security.grn_change_text(text, jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_change_text(text, jsonb) FROM PUBLIC, anon, authenticated, service_role;

-- Whether one value of a field is understood. `to` must be set except for a text field (cleared); `from` may always be null.
CREATE FUNCTION warehouse_security.grn_change_value_valid(p_field text, p_value jsonb, p_is_to boolean) RETURNS boolean
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_type text := COALESCE(jsonb_typeof(p_value), 'null');
  v_num numeric;
BEGIN
  IF v_type = 'null' THEN
    RETURN NOT p_is_to OR p_field IN ('registration', 'note', 'packaging', 'rack', 'package_mark');
  END IF;
  IF p_field IN ('customer_id', 'item', 'sender', 'supervisor') THEN
    IF v_type <> 'object'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_value) AS k WHERE k NOT IN ('id', 'name'))
       OR COALESCE(jsonb_typeof(p_value -> 'id'), 'null') NOT IN ('string', 'null')
       OR COALESCE(jsonb_typeof(p_value -> 'name'), 'null') NOT IN ('string', 'null') THEN
      RETURN false;
    END IF;
    IF p_value ->> 'id' IS NOT NULL THEN
      PERFORM (p_value ->> 'id')::uuid;
    END IF;
    IF p_is_to AND p_field IN ('customer_id', 'item') AND p_value ->> 'id' IS NULL THEN RETURN false; END IF;
    IF p_is_to AND p_field = 'item' AND warehouse_security.is_blank_text(p_value ->> 'name') THEN RETURN false; END IF;
    RETURN true;
  ELSIF p_field = 'date' THEN
    RETURN v_type = 'string' AND (p_value #>> '{}')::timestamptz IS NOT NULL;
  ELSIF p_field IN ('qty', 'weight') THEN
    IF v_type <> 'number' THEN RETURN false; END IF;
    v_num := (p_value #>> '{}')::numeric;
    IF v_num <> trunc(v_num) THEN RETURN false; END IF;
    IF p_is_to THEN
      RETURN CASE p_field WHEN 'qty' THEN v_num BETWEEN 1 AND 2147483647 ELSE v_num BETWEEN 0 AND 9999 END;
    END IF;
    RETURN abs(v_num) <= 2147483647;
  ELSIF p_field = 'leon' THEN
    RETURN v_type = 'boolean';
  ELSIF p_field = 'pricing_mode' THEN
    RETURN v_type = 'string' AND upper(btrim(p_value #>> '{}')) IN ('MONTHLY', 'ONE_TIME');
  ELSE
    RETURN v_type = 'string';
  END IF;
EXCEPTION WHEN others THEN
  RETURN false;
END $$;
ALTER FUNCTION warehouse_security.grn_change_value_valid(text, jsonb, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_change_value_valid(text, jsonb, boolean) FROM PUBLIC, anon, authenticated, service_role;

-- One line added, as the body of contract 3.2 has it, normalised for update_grn; NULL when it is not understood.
CREATE FUNCTION warehouse_security.grn_change_line(p_line jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
BEGIN
  IF jsonb_typeof(p_line) IS DISTINCT FROM 'object'
     OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_line) AS k
                WHERE k NOT IN ('clientLineId', 'item_id', 'item_name', 'packaging', 'qty', 'weight', 'rack', 'package_mark'))
     OR jsonb_typeof(p_line -> 'clientLineId') IS DISTINCT FROM 'string' OR warehouse_security.is_blank_text(p_line ->> 'clientLineId')
     OR char_length(btrim(p_line ->> 'clientLineId')) > 100
     OR jsonb_typeof(p_line -> 'item_id') IS DISTINCT FROM 'string'
     OR jsonb_typeof(p_line -> 'item_name') IS DISTINCT FROM 'string' OR warehouse_security.is_blank_text(p_line ->> 'item_name')
     OR NOT warehouse_security.grn_change_value_valid('packaging', COALESCE(p_line -> 'packaging', 'null'::jsonb), false)
     OR NOT warehouse_security.grn_change_value_valid('qty', p_line -> 'qty', true)
     OR NOT warehouse_security.grn_change_value_valid('weight', COALESCE(p_line -> 'weight', '0'::jsonb), true)
     OR NOT warehouse_security.grn_change_value_valid('rack', COALESCE(p_line -> 'rack', 'null'::jsonb), false)
     OR NOT warehouse_security.grn_change_value_valid('package_mark', COALESCE(p_line -> 'package_mark', 'null'::jsonb), false) THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object(
    'clientLineId', btrim(p_line ->> 'clientLineId'),
    'item_id', (p_line ->> 'item_id')::uuid,
    'item_name', btrim(p_line ->> 'item_name'),
    'packaging', warehouse_security.grn_change_key('packaging', p_line -> 'packaging'),
    'qty', (p_line ->> 'qty')::numeric::integer,
    'weight', COALESCE((p_line ->> 'weight')::numeric::integer, 0),
    'rack', warehouse_security.grn_change_key('rack', p_line -> 'rack'),
    'package_mark', warehouse_security.grn_change_key('package_mark', p_line -> 'package_mark'));
EXCEPTION WHEN others THEN
  RETURN NULL;
END $$;
ALTER FUNCTION warehouse_security.grn_change_line(jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_change_line(jsonb) FROM PUBLIC, anon, authenticated, service_role;

-- update_grn called with the stored GRN and the given changes on top (p_changes: apply_grn_changes' change list, each
-- {scope header|lot|add|remove, field, lot_id, to, line}). Every stored line is sent, so nothing is removed but the lines removed
-- here; no photo list is sent, so no photo changes. Answers {answer: update_grn's answer, kept: the number of stored lines sent}
-- (the lines added follow them, so update_grn's item_mapping index kept + i is the i-th line added).
CREATE FUNCTION warehouse_security.grn_changes_call(p_grn_id uuid, p_changes jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_change jsonb;
  v_t record;
  v_line jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_kept integer := 0;
  v_date timestamptz;
  v_customer uuid;
  v_sender_id uuid;
  v_sender_name text;
  v_supervisor_id uuid;
  v_supervisor_name text;
  v_registration text;
  v_note text;
  v_leon boolean;
  v_pricing text;
BEGIN
  FOR v_change IN SELECT c FROM jsonb_array_elements(p_changes) AS c WHERE c ->> 'scope' = 'header' LOOP
    CASE v_change ->> 'field'
      WHEN 'date' THEN v_date := (v_change ->> 'to')::timestamptz;
      WHEN 'customer_id' THEN v_customer := (v_change -> 'to' ->> 'id')::uuid;
      WHEN 'sender' THEN
        v_sender_id := (v_change -> 'to' ->> 'id')::uuid;
        v_sender_name := COALESCE(v_change -> 'to' ->> 'name', '');
      WHEN 'supervisor' THEN
        v_supervisor_id := (v_change -> 'to' ->> 'id')::uuid;
        v_supervisor_name := COALESCE(v_change -> 'to' ->> 'name', '');
      -- A blank that is sent clears the registration; update_grn trims it.
      WHEN 'registration' THEN v_registration := COALESCE(v_change ->> 'to', '');
      -- update_grn keeps the note when it is sent NULL: a cleared note is sent (and stored) as ''.
      WHEN 'note' THEN v_note := COALESCE(btrim(v_change ->> 'to'), '');
      WHEN 'leon' THEN v_leon := (v_change ->> 'to')::boolean;
      WHEN 'pricing_mode' THEN v_pricing := upper(btrim(v_change ->> 'to'));
      ELSE NULL;
    END CASE;
  END LOOP;

  FOR v_t IN
    SELECT t.id, t.item_id, t.item_name, t.packaging, t.qty, t.weight, t.rack, t.package_mark
    FROM public.goodsreceived_trl t WHERE t.gr_id = p_grn_id
    ORDER BY uuid_extract_timestamp(t.id), t.id
  LOOP
    CONTINUE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(p_changes) AS c
                          WHERE c ->> 'scope' = 'remove' AND c ->> 'lot_id' = v_t.id::text);
    -- The stored values as they are, so update_grn sees no change on them.
    v_line := jsonb_build_object('id', v_t.id, 'item_id', v_t.item_id, 'item_name', v_t.item_name, 'packaging', v_t.packaging,
                                 'qty', v_t.qty, 'weight', COALESCE(v_t.weight, 0), 'rack', v_t.rack, 'package_mark', v_t.package_mark);
    FOR v_change IN SELECT c FROM jsonb_array_elements(p_changes) AS c
                    WHERE c ->> 'scope' = 'lot' AND c ->> 'lot_id' = v_t.id::text LOOP
      v_line := v_line || CASE v_change ->> 'field'
        WHEN 'item' THEN jsonb_build_object('item_id', v_change -> 'to' ->> 'id', 'item_name', btrim(v_change -> 'to' ->> 'name'))
        WHEN 'packaging' THEN jsonb_build_object('packaging', warehouse_security.grn_change_key('packaging', v_change -> 'to'))
        WHEN 'qty' THEN jsonb_build_object('qty', (v_change ->> 'to')::numeric::integer)
        WHEN 'weight' THEN jsonb_build_object('weight', (v_change ->> 'to')::numeric::integer)
        WHEN 'rack' THEN jsonb_build_object('rack', warehouse_security.grn_change_key('rack', v_change -> 'to'))
        WHEN 'package_mark' THEN jsonb_build_object('package_mark', warehouse_security.grn_change_key('package_mark', v_change -> 'to'))
        ELSE '{}'::jsonb END;
    END LOOP;
    v_lines := v_lines || jsonb_build_array(v_line);
    v_kept := v_kept + 1;
  END LOOP;

  FOR v_change IN SELECT c FROM jsonb_array_elements(p_changes) WITH ORDINALITY AS x(c, n)
                  WHERE c ->> 'scope' = 'add' ORDER BY x.n LOOP
    v_lines := v_lines || jsonb_build_array((v_change -> 'line') - 'clientLineId');
  END LOOP;

  RETURN jsonb_build_object('kept', v_kept, 'answer', public.update_grn(
    p_grn_id => p_grn_id, p_date => v_date, p_customer_id => v_customer,
    p_sender_id => v_sender_id, p_sender_name => v_sender_name::varchar,
    p_supervisor_id => v_supervisor_id, p_supervisor_name => v_supervisor_name::varchar,
    p_registration => v_registration::varchar, p_note => v_note::varchar, p_leon => v_leon,
    p_pricing_mode => v_pricing::varchar, p_items => v_lines));
END $$;
ALTER FUNCTION warehouse_security.grn_changes_call(uuid, jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_changes_call(uuid, jsonb) FROM PUBLIC, anon, authenticated, service_role;

-- Each change alone through update_grn, rolled back: the refusals of a refused item, one per change ({n, path, code, answer}).
CREATE FUNCTION warehouse_security.grn_changes_probe(p_grn_id uuid, p_changes jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_change jsonb;
  v_answer jsonb;
  v_detail text;
  v_out jsonb := '[]'::jsonb;
BEGIN
  FOR v_change IN SELECT c FROM jsonb_array_elements(p_changes) AS c LOOP
    BEGIN
      v_answer := warehouse_security.grn_changes_call(p_grn_id, jsonb_build_array(v_change)) -> 'answer';
      -- Raised only to roll the try back.
      RAISE EXCEPTION 'apply_grn_changes: trial' USING ERRCODE = 'WH303', DETAIL = v_answer::text;
    EXCEPTION WHEN SQLSTATE 'WH303' THEN
      GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
      v_answer := v_detail::jsonb;
    END;
    IF v_answer ->> 'success' IS DISTINCT FROM 'true' THEN
      v_out := v_out || jsonb_build_array(jsonb_build_object('n', (v_change ->> 'n')::integer, 'path', v_change ->> 'path',
        'code', COALESCE(v_answer ->> 'reason', 'GRN_CHANGE_REFUSED'), 'answer', v_answer));
    END IF;
  END LOOP;
  RETURN v_out;
END $$;
ALTER FUNCTION warehouse_security.grn_changes_probe(uuid, jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_changes_probe(uuid, jsonb) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.apply_grn_changes(p_grn_id uuid, p_changes jsonb, p_request_key text)
    RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
DECLARE
  v_profile uuid;
  v_key text := btrim(p_request_key);
  v_header_fields constant text[] := ARRAY['date', 'customer_id', 'sender', 'supervisor', 'registration', 'note', 'leon', 'pricing_mode'];
  v_lot_fields constant text[] := ARRAY['item', 'packaging', 'qty', 'weight', 'rack', 'package_mark'];
  v_loaded timestamptz;
  v_recorded timestamptz;
  v_list jsonb := '[]'::jsonb;
  v_n integer := 0;
  v_field text;
  v_part jsonb;
  v_lot text;
  v_fields jsonb;
  v_line jsonb;
  v_norm jsonb;
  v_client_ids text[] := ARRAY[]::text[];
  v_removed_ids text[] := ARRAY[]::text[];
  v_kept record;
  v_g public.goodsreceived%ROWTYPE;
  v_t record;
  v_change jsonb;
  v_stored jsonb;
  v_effective jsonb := '[]'::jsonb;
  v_refused jsonb := '[]'::jsonb;
  v_first jsonb;
  v_call jsonb;
  v_refusal jsonb;
  v_detail text;
  v_entry jsonb;
  v_replaced jsonb := '[]'::jsonb;
  v_applied_header jsonb := '[]'::jsonb;
  v_applied_lots jsonb := '{}'::jsonb;
  v_lines_added jsonb := '[]'::jsonb;
  v_lines_removed jsonb := '[]'::jsonb;
  v_new_ids uuid[] := ARRAY[]::uuid[];
  v_new_id uuid;
  v_i integer;
  v_other record;
  v_order_effects jsonb := '[]'::jsonb;
  v_answer jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('apply_grn_changes', jsonb_build_object('p_grn_id', p_grn_id));
  SELECT p.id INTO v_profile FROM public.user_profiles p WHERE p.auth_user_id = auth.uid();
  IF v_profile IS NULL THEN
    RAISE EXCEPTION 'Active account required' USING ERRCODE = '42501';
  END IF;

  -- ---- The shape of the body (contract 3.2) and the key. ----
  IF p_grn_id IS NULL OR p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' OR v_key IS NULL OR v_key = ''
     OR EXISTS (SELECT 1 FROM jsonb_object_keys(p_changes) AS k
                WHERE k NOT IN ('v', 'grnId', 'loadedAt', 'recordedAt', 'header', 'lots', 'linesAdded', 'linesRemoved'))
     OR COALESCE(jsonb_typeof(p_changes -> 'header'), 'object') NOT IN ('object', 'null')
     OR COALESCE(jsonb_typeof(p_changes -> 'lots'), 'object') NOT IN ('object', 'null')
     OR COALESCE(jsonb_typeof(p_changes -> 'linesAdded'), 'array') NOT IN ('array', 'null')
     OR COALESCE(jsonb_typeof(p_changes -> 'linesRemoved'), 'array') NOT IN ('array', 'null')
     OR COALESCE(jsonb_typeof(p_changes -> 'loadedAt'), 'null') NOT IN ('string', 'null')
     OR COALESCE(jsonb_typeof(p_changes -> 'recordedAt'), 'null') NOT IN ('string', 'null')
     OR (p_changes ? 'v' AND p_changes -> 'v' <> '1'::jsonb) THEN
    RETURN warehouse_security.refuse('GRN_CHANGE_INVALID', 'The change is not understood.');
  END IF;
  BEGIN
    v_loaded := (p_changes ->> 'loadedAt')::timestamptz;
    v_recorded := (p_changes ->> 'recordedAt')::timestamptz;
  EXCEPTION WHEN others THEN
    RETURN warehouse_security.refuse('GRN_CHANGE_INVALID', 'The time of the change is not understood.');
  END;

  -- The changes in path order: header, lots, linesAdded, linesRemoved (the order of `refused` and of the first refusal).
  IF jsonb_typeof(p_changes -> 'header') = 'object' THEN
    IF EXISTS (SELECT 1 FROM jsonb_object_keys(p_changes -> 'header') AS k WHERE NOT k = ANY (v_header_fields)) THEN
      RETURN warehouse_security.refuse('GRN_CHANGE_INVALID', 'The change is not understood.');
    END IF;
    FOREACH v_field IN ARRAY v_header_fields LOOP
      CONTINUE WHEN NOT (p_changes -> 'header') ? v_field;
      v_part := p_changes -> 'header' -> v_field;
      IF jsonb_typeof(v_part) IS DISTINCT FROM 'object' OR NOT v_part ? 'to'
         OR EXISTS (SELECT 1 FROM jsonb_object_keys(v_part) AS k WHERE k NOT IN ('from', 'to'))
         OR NOT warehouse_security.grn_change_value_valid(v_field, v_part -> 'to', true)
         OR NOT warehouse_security.grn_change_value_valid(v_field, COALESCE(v_part -> 'from', 'null'::jsonb), false) THEN
        RETURN warehouse_security.refuse('GRN_CHANGE_INVALID', 'The change is not understood.', jsonb_build_object('path', 'header.' || v_field));
      END IF;
      v_n := v_n + 1;
      v_list := v_list || jsonb_build_array(jsonb_build_object('n', v_n, 'path', 'header.' || v_field, 'scope', 'header',
        'field', v_field, 'from', COALESCE(v_part -> 'from', 'null'::jsonb), 'to', v_part -> 'to'));
    END LOOP;
  END IF;
  IF jsonb_typeof(p_changes -> 'lots') = 'object' THEN
    FOR v_lot, v_fields IN SELECT e.key, e.value FROM jsonb_each(p_changes -> 'lots') AS e ORDER BY e.key LOOP
      IF v_lot !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' OR jsonb_typeof(v_fields) IS DISTINCT FROM 'object'
         OR NOT EXISTS (SELECT 1 FROM jsonb_object_keys(v_fields))
         OR EXISTS (SELECT 1 FROM jsonb_object_keys(v_fields) AS k WHERE NOT k = ANY (v_lot_fields)) THEN
        RETURN warehouse_security.refuse('GRN_CHANGE_INVALID', 'The change is not understood.', jsonb_build_object('path', 'lots.' || v_lot));
      END IF;
      FOREACH v_field IN ARRAY v_lot_fields LOOP
        CONTINUE WHEN NOT v_fields ? v_field;
        v_part := v_fields -> v_field;
        IF jsonb_typeof(v_part) IS DISTINCT FROM 'object' OR NOT v_part ? 'to'
           OR EXISTS (SELECT 1 FROM jsonb_object_keys(v_part) AS k WHERE k NOT IN ('from', 'to'))
           OR NOT warehouse_security.grn_change_value_valid(v_field, v_part -> 'to', true)
           OR NOT warehouse_security.grn_change_value_valid(v_field, COALESCE(v_part -> 'from', 'null'::jsonb), false) THEN
          RETURN warehouse_security.refuse('GRN_CHANGE_INVALID', 'The change is not understood.',
            jsonb_build_object('path', 'lots.' || v_lot || '.' || v_field));
        END IF;
        v_n := v_n + 1;
        v_list := v_list || jsonb_build_array(jsonb_build_object('n', v_n, 'path', 'lots.' || v_lot || '.' || v_field, 'scope', 'lot',
          'field', v_field, 'lot_id', lower(v_lot), 'from', COALESCE(v_part -> 'from', 'null'::jsonb), 'to', v_part -> 'to'));
      END LOOP;
    END LOOP;
  END IF;
  IF jsonb_typeof(p_changes -> 'linesAdded') = 'array' THEN
    FOR v_line IN SELECT x.e FROM jsonb_array_elements(p_changes -> 'linesAdded') WITH ORDINALITY AS x(e, i) ORDER BY x.i LOOP
      v_norm := warehouse_security.grn_change_line(v_line);
      IF v_norm IS NULL OR (v_norm ->> 'clientLineId') = ANY (v_client_ids) THEN
        RETURN warehouse_security.refuse('GRN_CHANGE_INVALID', 'A line added is not understood.');
      END IF;
      v_client_ids := v_client_ids || (v_norm ->> 'clientLineId');
      v_n := v_n + 1;
      v_list := v_list || jsonb_build_array(jsonb_build_object('n', v_n, 'path', 'linesAdded.' || (v_norm ->> 'clientLineId'),
        'scope', 'add', 'line', v_norm));
    END LOOP;
  END IF;
  IF jsonb_typeof(p_changes -> 'linesRemoved') = 'array' THEN
    FOR v_line IN SELECT x.e FROM jsonb_array_elements(p_changes -> 'linesRemoved') WITH ORDINALITY AS x(e, i) ORDER BY x.i LOOP
      IF jsonb_typeof(v_line) IS DISTINCT FROM 'object' OR jsonb_typeof(v_line -> 'lotId') IS DISTINCT FROM 'string'
         OR (v_line ->> 'lotId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         OR EXISTS (SELECT 1 FROM jsonb_object_keys(v_line) AS k WHERE k NOT IN ('lotId', 'item_name', 'qty'))
         OR lower(v_line ->> 'lotId') = ANY (v_removed_ids) THEN
        RETURN warehouse_security.refuse('GRN_CHANGE_INVALID', 'A line removed is not understood.');
      END IF;
      v_removed_ids := v_removed_ids || lower(v_line ->> 'lotId');
      v_n := v_n + 1;
      v_list := v_list || jsonb_build_array(jsonb_build_object('n', v_n, 'path', 'linesRemoved.' || (v_line ->> 'lotId'),
        'scope', 'remove', 'lot_id', lower(v_line ->> 'lotId')));
    END LOOP;
  END IF;
  IF v_n = 0 THEN
    RETURN warehouse_security.refuse('GRN_CHANGE_INVALID', 'There is nothing to change.');
  END IF;

  -- ---- A repeated send gets the first answer, after any delay. Two sends of one key at once are taken one after the other. ----
  PERFORM pg_advisory_xact_lock(hashtextextended('apply_grn_changes:' || v_key, 0));
  SELECT k.rpc_function, k.created_by, k.expires_at, k.response INTO v_kept
    FROM public.idempotency_keys k WHERE k.idempotency_key = v_key;
  IF FOUND THEN
    IF v_kept.rpc_function = 'apply_grn_changes' AND v_kept.created_by IS NOT DISTINCT FROM v_profile
       AND v_kept.response ->> 'grn_id' = p_grn_id::text THEN
      RETURN v_kept.response || jsonb_build_object('idempotent', true);
    ELSIF v_kept.expires_at IS NULL OR v_kept.expires_at > now() THEN
      RETURN warehouse_security.refuse('REQUEST_KEY_REUSED', 'This request key was already used for another change.');
    END IF;
  END IF;

  -- ---- The GRN, locked as update_grn locks it. ----
  PERFORM pg_advisory_xact_lock(71040);
  SELECT g.* INTO v_g FROM public.goodsreceived g WHERE g.id = p_grn_id FOR UPDATE;
  IF NOT FOUND OR v_g.deleted_at IS NOT NULL THEN
    RETURN warehouse_security.refuse('GRN_NOT_FOUND', 'This GRN is no longer there.', jsonb_build_object('grn_id', p_grn_id))
      || jsonb_build_object('refused', (SELECT jsonb_agg(jsonb_build_object('path', c ->> 'path', 'code', 'GRN_NOT_FOUND') ORDER BY (c ->> 'n')::integer)
                                        FROM jsonb_array_elements(v_list) AS c));
  END IF;
  IF v_g.import_batch_id IS NOT NULL THEN
    RETURN warehouse_security.imported_read_only('grn')
      || jsonb_build_object('refused', (SELECT jsonb_agg(jsonb_build_object('path', c ->> 'path', 'code', 'IMPORTED_READ_ONLY') ORDER BY (c ->> 'n')::integer)
                                        FROM jsonb_array_elements(v_list) AS c));
  END IF;

  -- ---- Each change against what is stored: the lot is there, the change is a real one, and the two locks update_grn raises for. ----
  FOR v_change IN SELECT c FROM jsonb_array_elements(v_list) AS c ORDER BY (c ->> 'n')::integer LOOP
    IF v_change ->> 'scope' = 'header' THEN
      v_stored := CASE v_change ->> 'field'
        WHEN 'date' THEN to_jsonb(v_g.date)
        WHEN 'customer_id' THEN jsonb_build_object('id', v_g.customer_id, 'name', v_g.customer_name)
        WHEN 'sender' THEN jsonb_build_object('id', v_g.sender_id, 'name', v_g.sender_name)
        WHEN 'supervisor' THEN jsonb_build_object('id', v_g.supervisor_id, 'name', v_g.supervisor_name)
        WHEN 'registration' THEN to_jsonb(v_g.registration)
        WHEN 'note' THEN to_jsonb(v_g.note)
        WHEN 'leon' THEN to_jsonb(v_g.leon)
        WHEN 'pricing_mode' THEN to_jsonb(v_g.pricing_mode) END;
      v_applied_header := v_applied_header || to_jsonb(v_change ->> 'field');
    ELSIF v_change ->> 'scope' = 'lot' THEN
      -- A lot this item also removes takes no field change.
      CONTINUE WHEN (v_change ->> 'lot_id') = ANY (v_removed_ids);
      SELECT t.item_id, t.item_name, t.packaging, t.qty, t.weight, t.rack, t.package_mark INTO v_t
        FROM public.goodsreceived_trl t WHERE t.id = (v_change ->> 'lot_id')::uuid AND t.gr_id = p_grn_id;
      IF NOT FOUND THEN
        v_refused := v_refused || jsonb_build_array(jsonb_build_object('n', (v_change ->> 'n')::integer, 'path', v_change ->> 'path',
          'code', 'LOT_NOT_FOUND', 'answer', warehouse_security.refuse('LOT_NOT_FOUND', 'This lot is no longer there.',
            jsonb_build_object('lot_id', v_change ->> 'lot_id'))));
        CONTINUE;
      END IF;
      v_stored := CASE v_change ->> 'field'
        WHEN 'item' THEN jsonb_build_object('id', v_t.item_id, 'name', v_t.item_name)
        WHEN 'packaging' THEN to_jsonb(v_t.packaging)
        WHEN 'qty' THEN to_jsonb(v_t.qty)
        WHEN 'weight' THEN to_jsonb(COALESCE(v_t.weight, 0))
        WHEN 'rack' THEN to_jsonb(v_t.rack)
        WHEN 'package_mark' THEN to_jsonb(v_t.package_mark) END;
      v_applied_lots := jsonb_set(v_applied_lots, ARRAY[v_change ->> 'lot_id'],
        COALESCE(v_applied_lots -> (v_change ->> 'lot_id'), '[]'::jsonb) || to_jsonb(v_change ->> 'field'));
    ELSIF v_change ->> 'scope' = 'remove' THEN
      IF NOT EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.id = (v_change ->> 'lot_id')::uuid AND t.gr_id = p_grn_id) THEN
        v_refused := v_refused || jsonb_build_array(jsonb_build_object('n', (v_change ->> 'n')::integer, 'path', v_change ->> 'path',
          'code', 'LOT_NOT_FOUND', 'answer', warehouse_security.refuse('LOT_NOT_FOUND', 'This lot is no longer there.',
            jsonb_build_object('lot_id', v_change ->> 'lot_id'))));
        CONTINUE;
      END IF;
      v_effective := v_effective || jsonb_build_array(v_change);
      CONTINUE;
    ELSE
      v_effective := v_effective || jsonb_build_array(v_change);
      CONTINUE;
    END IF;

    -- A field change: a `to` equal to what is stored is applied and writes nothing.
    CONTINUE WHEN warehouse_security.grn_change_key(v_change ->> 'field', v_stored)
                  IS NOT DISTINCT FROM warehouse_security.grn_change_key(v_change ->> 'field', v_change -> 'to');
    v_change := v_change || jsonb_build_object('stored', COALESCE(v_stored, 'null'::jsonb));
    -- update_grn raises (no code) for these two; the same conditions, refused by code before any write.
    IF v_change ->> 'field' = 'customer_id'
       AND (EXISTS (SELECT 1 FROM public.dispatch_trl dt WHERE dt.gr_id = p_grn_id)
            OR EXISTS (SELECT 1 FROM public.invoice i WHERE i.gr_id = p_grn_id)
            OR EXISTS (SELECT 1 FROM public.order_items oi
                       JOIN public.orders o ON o.id = oi.order_id
                       JOIN public.goodsreceived_trl gt ON gt.id = oi.grn_items_id
                       WHERE gt.gr_id = p_grn_id AND o.deleted_at IS NULL)) THEN
      v_refused := v_refused || jsonb_build_array(jsonb_build_object('n', (v_change ->> 'n')::integer, 'path', v_change ->> 'path',
        'code', 'GRN_CUSTOMER_LOCKED', 'answer', warehouse_security.refuse('GRN_CUSTOMER_LOCKED',
          'The customer of a GRN with dispatches, invoices or order lines can''t be changed.', jsonb_build_object('gr_no', v_g.gr_no))));
      CONTINUE;
    END IF;
    IF v_change ->> 'field' = 'pricing_mode'
       AND (EXISTS (SELECT 1 FROM public.invoice i WHERE i.gr_id = p_grn_id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL)
            OR EXISTS (SELECT 1 FROM public.invoice_trl it
                       JOIN public.dispatch_trl dt ON dt.id = it.disp_trl_id
                       JOIN public.invoice inv ON inv.id = it.invoice_id
                       WHERE dt.gr_id = p_grn_id AND inv.deleted_at IS NULL AND inv.cancelled_at IS NULL)) THEN
      v_refused := v_refused || jsonb_build_array(jsonb_build_object('n', (v_change ->> 'n')::integer, 'path', v_change ->> 'path',
        'code', 'GRN_PRICING_MODE_LOCKED', 'answer', warehouse_security.refuse('GRN_PRICING_MODE_LOCKED',
          'This GRN has invoices. Delete the invoices first, then change the pricing mode and invoice again.',
          jsonb_build_object('gr_no', v_g.gr_no))));
      CONTINUE;
    END IF;
    v_effective := v_effective || jsonb_build_array(v_change);
  END LOOP;

  IF jsonb_array_length(v_refused) = 0 AND jsonb_array_length(v_effective) > 0 THEN
    -- ---- The write: the replaced entries first (the write moves the field marks they read), then update_grn. A refusal rolls both back. ----
    BEGIN
      FOR v_change IN SELECT c FROM jsonb_array_elements(v_effective) AS c WHERE c ->> 'scope' IN ('header', 'lot') LOOP
        -- Last sent wins; the stored value is someone's when it differs from the value the phone says it replaced.
        CONTINUE WHEN warehouse_security.grn_change_key(v_change ->> 'field', v_change -> 'stored')
                      IS NOT DISTINCT FROM warehouse_security.grn_change_key(v_change ->> 'field', v_change -> 'from');
        v_entry := warehouse_security.record_grn_replacement(p_grn_id, (v_change ->> 'lot_id')::uuid, v_change ->> 'field',
          warehouse_security.grn_change_text(v_change ->> 'field', v_change -> 'stored'),
          warehouse_security.grn_change_text(v_change ->> 'field', v_change -> 'to'), v_profile, v_key, v_recorded);
        IF v_entry IS NOT NULL THEN v_replaced := v_replaced || jsonb_build_array(v_entry); END IF;
      END LOOP;

      v_call := warehouse_security.grn_changes_call(p_grn_id, v_effective);
      IF v_call -> 'answer' ->> 'success' IS DISTINCT FROM 'true' THEN
        RAISE EXCEPTION 'apply_grn_changes: refused' USING ERRCODE = 'WH303', DETAIL = (v_call -> 'answer')::text;
      END IF;
      v_order_effects := COALESCE(v_call -> 'answer' -> 'order_effects', '[]'::jsonb);

      -- The lines added, by their place after the stored lines in update_grn's item_mapping.
      v_i := 0;
      FOR v_change IN SELECT c FROM jsonb_array_elements(v_effective) WITH ORDINALITY AS x(c, n) WHERE c ->> 'scope' = 'add' ORDER BY x.n LOOP
        SELECT (m ->> 'grn_trl_item_id')::uuid INTO v_new_id
          FROM jsonb_array_elements(v_call -> 'answer' -> 'item_mapping') AS m
          WHERE (m ->> 'index')::integer = (v_call ->> 'kept')::integer + v_i;
        v_new_ids := v_new_ids || v_new_id;
        v_lines_added := v_lines_added || jsonb_build_array(jsonb_build_object('client_line_id', v_change -> 'line' ->> 'clientLineId', 'id', v_new_id));
        v_i := v_i + 1;
      END LOOP;
      SELECT COALESCE(jsonb_agg(c ->> 'lot_id' ORDER BY (c ->> 'n')::integer), '[]'::jsonb) INTO v_lines_removed
        FROM jsonb_array_elements(v_effective) AS c WHERE c ->> 'scope' = 'remove';

      -- "Lines added" entries (Product PQ6): only when someone else also added a line after this person loaded the GRN; then one entry
      -- per such line and per line of this send.
      IF cardinality(v_new_ids) > 0 AND v_loaded IS NOT NULL AND EXISTS (
          SELECT 1 FROM warehouse_security.grn_field_marks m
          WHERE m.grn_id = p_grn_id AND m.field = 'line' AND m.set_at > v_loaded AND m.set_by IS DISTINCT FROM v_profile
            AND NOT m.lot_id = ANY (v_new_ids)) THEN
        FOR v_other IN
          SELECT t.id, t.item_name, t.qty, t.packaging, m.set_by, m.set_at
          FROM warehouse_security.grn_field_marks m JOIN public.goodsreceived_trl t ON t.id = m.lot_id
          WHERE m.grn_id = p_grn_id AND m.field = 'line' AND m.set_at > v_loaded AND m.set_by IS DISTINCT FROM v_profile
            AND NOT m.lot_id = ANY (v_new_ids)
          ORDER BY m.set_at, t.id
        LOOP
          v_replaced := v_replaced || jsonb_build_array(warehouse_security.record_grn_replacement(p_grn_id, v_other.id,
            jsonb_build_object('item_name', v_other.item_name, 'qty', v_other.qty, 'packaging', v_other.packaging),
            v_other.set_by, v_other.set_at, v_key, NULL::timestamptz));
        END LOOP;
        FOR v_other IN
          SELECT t.id, t.item_name, t.qty, t.packaging FROM unnest(v_new_ids) WITH ORDINALITY AS x(id, n)
          JOIN public.goodsreceived_trl t ON t.id = x.id ORDER BY x.n
        LOOP
          v_replaced := v_replaced || jsonb_build_array(warehouse_security.record_grn_replacement(p_grn_id, v_other.id,
            jsonb_build_object('item_name', v_other.item_name, 'qty', v_other.qty, 'packaging', v_other.packaging),
            v_profile, now(), v_key, v_recorded));
        END LOOP;
      END IF;
    EXCEPTION WHEN SQLSTATE 'WH303' THEN
      GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
      v_refusal := v_detail::jsonb;
    END;

    IF v_refusal IS NOT NULL THEN
      -- Which changes are refused: each alone. A refusal only the changes together meet is listed against every one of them.
      v_refused := warehouse_security.grn_changes_probe(p_grn_id, v_effective);
      IF jsonb_array_length(v_refused) = 0 THEN
        SELECT jsonb_agg(jsonb_build_object('n', (c ->> 'n')::integer, 'path', c ->> 'path',
                 'code', COALESCE(v_refusal ->> 'reason', 'GRN_CHANGE_REFUSED'), 'answer', v_refusal))
          INTO v_refused FROM jsonb_array_elements(v_effective) AS c;
      END IF;
    END IF;
  ELSIF jsonb_array_length(v_refused) > 0 THEN
    -- Refused here before any write: the other changes are tried too, so that every refusal is listed.
    v_refused := v_refused || warehouse_security.grn_changes_probe(p_grn_id, v_effective);
  END IF;

  IF jsonb_array_length(v_refused) > 0 THEN
    SELECT r -> 'answer' INTO v_first FROM jsonb_array_elements(v_refused) AS r ORDER BY (r ->> 'n')::integer LIMIT 1;
    RETURN v_first || jsonb_build_object('refused',
      (SELECT jsonb_agg(jsonb_build_object('path', r ->> 'path', 'code', r ->> 'code') ORDER BY (r ->> 'n')::integer)
         FROM jsonb_array_elements(v_refused) AS r));
  END IF;

  -- Design DQ11: each entry names its lot by the lot's item, mark and rack as they are after this write.
  SELECT COALESCE(jsonb_agg(e.v || jsonb_build_object('lot_item_name', t.item_name, 'lot_package_mark', t.package_mark, 'lot_rack', t.rack)
                            ORDER BY e.n), '[]'::jsonb)
    INTO v_replaced
    FROM jsonb_array_elements(v_replaced) WITH ORDINALITY AS e(v, n)
    LEFT JOIN public.goodsreceived_trl t ON t.id = (e.v ->> 'lot_id')::uuid;

  SELECT jsonb_build_object(
      'success', true,
      'grn_id', g.id,
      'gr_no', g.gr_no,
      'updated_at', g.updated_at,
      'applied', jsonb_build_object('header', v_applied_header, 'lots', v_applied_lots),
      'lines_added', v_lines_added,
      'lines_removed', v_lines_removed,
      'replaced', v_replaced,
      'order_effects', v_order_effects)
    INTO v_answer
    FROM public.goodsreceived g WHERE g.id = p_grn_id;

  -- Kept with no expiry (infinity), so the repeat of an old key is still answered. Only an expired key of another function is taken over.
  INSERT INTO public.idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
  VALUES (v_key, 'apply_grn_changes', v_answer, v_profile, 'infinity')
  ON CONFLICT (idempotency_key) DO UPDATE SET
    rpc_function = EXCLUDED.rpc_function, response = EXCLUDED.response, created_by = EXCLUDED.created_by,
    created_at = now(), expires_at = EXCLUDED.expires_at
  WHERE idempotency_keys.expires_at <= now();
  RETURN v_answer;
END $$;
ALTER FUNCTION public.apply_grn_changes(uuid, jsonb, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.apply_grn_changes(uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_grn_changes(uuid, jsonb, text) TO authenticated, service_role;
COMMENT ON FUNCTION public.apply_grn_changes(uuid, jsonb, text) IS
  'WH-303: a GRN edit sent as field changes {from, to}, lines added and lines removed; last sent wins, all or nothing, replaced entries recorded.';

-- ===== 4. get_submission_result finds the answer while the GRN exists =====
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$            WHEN 'set_lot_rack_and_mark' THEN EXISTS (SELECT 1 FROM goodsreceived_trl t WHERE t.id::text = k.response #>> '{lot,id}')
$m$
  ];
  v_new constant text[] := ARRAY[
    $m$            WHEN 'set_lot_rack_and_mark' THEN EXISTS (SELECT 1 FROM goodsreceived_trl t WHERE t.id::text = k.response #>> '{lot,id}')
            WHEN 'apply_grn_changes' THEN EXISTS (SELECT 1 FROM goodsreceived g WHERE g.id::text = k.response ->> 'grn_id' AND g.deleted_at IS NULL)
$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.get_submission_result(text)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'get_submission_result: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

NOTIFY pgrst, 'reload schema';
