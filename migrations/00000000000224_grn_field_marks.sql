-- Topic "GRN field marks" (WH-302, shared with WH-303; contract tech/app-offline-edit-grn.md section 5.1): who last set each tracked GRN
-- field and when, kept by row triggers so that every write path (save_grn, update_grn, the quick change, imports) is covered with no code
-- of its own. A field with no mark (set before this topic) answers "not known" for who and when.
--
-- What this topic marks: a lot's INSERT writes the field `line`; a lot's UPDATE writes `rack` and `package_mark` when the value changes.
-- WH-303's edit-by-field-changes adds its other fields (header fields with lot_id NULL, the rest of the lot fields) to the same
-- function and table; nothing here has to change for them.
--
-- Written against: public.goodsreceived and public.goodsreceived_trl as migration 212 leaves them. No app role reads the table; the
-- trigger function is SECURITY DEFINER with a fixed search_path. A row of a deleted GRN or lot goes with it (foreign keys, ON DELETE
-- CASCADE). The importer (warehouse.import = 'on') and a caller with no profile leave set_by NULL. No role is created, altered or dropped.

CREATE TABLE warehouse_security.grn_field_marks (
  grn_id uuid NOT NULL REFERENCES public.goodsreceived(id) ON DELETE CASCADE,
  lot_id uuid REFERENCES public.goodsreceived_trl(id) ON DELETE CASCADE,
  field text NOT NULL,
  set_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  set_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE warehouse_security.grn_field_marks OWNER TO supabase_admin;
-- One mark per GRN field (lot_id NULL) or lot field.
CREATE UNIQUE INDEX grn_field_marks_field_key ON warehouse_security.grn_field_marks
  (grn_id, (COALESCE(lot_id, '00000000-0000-0000-0000-000000000000'::uuid)), field);
CREATE INDEX grn_field_marks_lot_idx ON warehouse_security.grn_field_marks (lot_id) WHERE lot_id IS NOT NULL;
CREATE INDEX grn_field_marks_set_by_idx ON warehouse_security.grn_field_marks (set_by) WHERE set_by IS NOT NULL;
ALTER TABLE warehouse_security.grn_field_marks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.grn_field_marks FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION warehouse_security.record_lot_field_marks() RETURNS trigger
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
ALTER FUNCTION warehouse_security.record_lot_field_marks() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.record_lot_field_marks() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER record_lot_field_marks AFTER INSERT OR UPDATE OF rack, package_mark ON public.goodsreceived_trl
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.record_lot_field_marks();
