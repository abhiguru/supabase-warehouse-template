-- Topic "replaced entries" (WH-302, shared with WH-303; contract tech/app-offline-edit-grn.md section 5.4, quick change contract section 2.2):
-- the record of a value that a later-arriving change put over another person's value, and the one writer of it.
--  1. warehouse_security.grn_replacements: one entry per replaced value. People are profile ids (names are joined at read). Entries are
--     never deleted by the server and survive the deletion of their GRN (no foreign key to the GRN or the lot); the reading functions,
--     the check-off functions and the feed entity are WH-303's.
--  2. warehouse_security.record_grn_replacement(...): the one writer. The newer value's person and time are read from the field mark
--     (topic "GRN field marks"); NO entry (NULL) when that value was last set by the sender themselves (Product, WH-302 PQ4: their other
--     phone); a value with no mark counts as someone else's (newer_by and newer_at NULL). recorded_at is the phone time of the change
--     (NULL when none was sent; a time later than the server time is stored as sent_at, never corrected otherwise). Returns the entry
--     as the answers of set_lot_rack_and_mark and apply_grn_changes list it under `replaced`.
-- It must be called BEFORE the write that changes the field: that write moves the field mark. Only kind 'field' is written here;
-- WH-303 adds 'line_added' to the writer. No role is created, altered or dropped.

CREATE TABLE warehouse_security.grn_replacements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  grn_id uuid NOT NULL,
  lot_id uuid,
  customer_id uuid,
  kind text NOT NULL CHECK (kind IN ('field', 'line_added')),
  field text,
  newer_value jsonb,
  newer_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  newer_at timestamptz,
  sent_value jsonb,
  sent_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  sent_at timestamptz NOT NULL DEFAULT now(),
  recorded_at timestamptz,
  request_key text,
  checked_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  checked_at timestamptz
);
ALTER TABLE warehouse_security.grn_replacements OWNER TO supabase_admin;
CREATE INDEX grn_replacements_grn_idx ON warehouse_security.grn_replacements (grn_id);
CREATE INDEX grn_replacements_unchecked_idx ON warehouse_security.grn_replacements (sent_at DESC) WHERE checked_at IS NULL;
CREATE INDEX grn_replacements_newer_by_idx ON warehouse_security.grn_replacements (newer_by) WHERE newer_by IS NOT NULL;
CREATE INDEX grn_replacements_sent_by_idx ON warehouse_security.grn_replacements (sent_by) WHERE sent_by IS NOT NULL;
CREATE INDEX grn_replacements_checked_by_idx ON warehouse_security.grn_replacements (checked_by) WHERE checked_by IS NOT NULL;
ALTER TABLE warehouse_security.grn_replacements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.grn_replacements FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION warehouse_security.record_grn_replacement(
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
    'id', v_id, 'field', p_field, 'newer', p_newer_value, 'sent', p_sent_value,
    'newer_by', v_mark_by, 'newer_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = v_mark_by), 'newer_at', v_mark_at,
    'sent_by', p_sent_by, 'sent_by_name', (SELECT p.name FROM public.user_profiles p WHERE p.id = p_sent_by),
    'sent_at', v_sent_at, 'recorded_at', v_recorded);
END $$;
ALTER FUNCTION warehouse_security.record_grn_replacement(uuid, uuid, text, text, text, uuid, text, timestamptz) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.record_grn_replacement(uuid, uuid, text, text, text, uuid, text, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
