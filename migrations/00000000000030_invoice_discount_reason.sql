-- Invoice discounts carry a reason and an author (decision, 2026-10-09).
-- Migration 24 made labour, tax and total server-computed, but the discount
-- stayed a client input, so any role that may save an invoice could lower its
-- total to almost nothing with nothing but the discount on record. Staff may
-- still set any discount, but only with a reason; for every role the reason,
-- the profile that set the discount and the time are recorded whenever the
-- discount changes. Administrators and supervisors may leave the reason empty.
-- An unchanged discount keeps its recorded reason and author.

ALTER TABLE public.invoice
  ADD COLUMN discount_reason text,
  ADD COLUMN discount_set_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  ADD COLUMN discount_set_at timestamptz;
COMMENT ON COLUMN public.invoice.discount_reason IS 'Why the discount was given; required from staff (migration 30).';
COMMENT ON COLUMN public.invoice.discount_set_by IS 'Profile that last changed the discount.';

-- The save RPCs receive the reason in p_invoice_data and hand it to this trigger
-- through a transaction-local setting, so every write path (both save_invoice
-- signatures and update_invoice) is covered without repeating the rule.
CREATE FUNCTION warehouse_security.invoice_discount_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  reason text := NULLIF(btrim(COALESCE(current_setting('warehouse.discount_reason', true), '')), '');
  previous numeric(12,2) := CASE WHEN TG_OP = 'UPDATE' THEN COALESCE(OLD.discount, 0) ELSE 0 END;
BEGIN
  IF COALESCE(NEW.discount, 0) = previous THEN
    IF TG_OP = 'UPDATE' THEN
      NEW.discount_reason := OLD.discount_reason;
      NEW.discount_set_by := OLD.discount_set_by;
      NEW.discount_set_at := OLD.discount_set_at;
    ELSE
      NEW.discount_reason := NULL; NEW.discount_set_by := NULL; NEW.discount_set_at := NULL;
    END IF;
    RETURN NEW;
  END IF;
  IF warehouse_security.active_role() = 'staff' AND reason IS NULL THEN
    RAISE EXCEPTION 'A reason is required for an invoice discount' USING ERRCODE = '22023';
  END IF;
  NEW.discount_reason := left(reason, 500);
  NEW.discount_set_by := (SELECT id FROM public.user_profiles WHERE auth_user_id = auth.uid());
  NEW.discount_set_at := now();
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.invoice_discount_audit() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER invoice_discount_audit BEFORE INSERT OR UPDATE ON public.invoice
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.invoice_discount_audit();

-- Each save RPC records the request's reason right after its guard.
DO $patch$
DECLARE fn regprocedure; definition text; patched text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'public.save_invoice(jsonb)',
    'public.save_invoice(uuid,jsonb,jsonb[])',
    'public.update_invoice(uuid,jsonb,jsonb[])'
  ]::regprocedure[] LOOP
    definition := pg_get_functiondef(fn);
    IF regexp_count(definition, 'PERFORM warehouse_security\.authorize_rpc\([^;]*\);') <> 1 THEN
      RAISE EXCEPTION 'Expected one RPC guard in %', fn;
    END IF;
    patched := regexp_replace(definition,
      '(PERFORM warehouse_security\.authorize_rpc\([^;]*\);)',
      E'\\1\n  PERFORM set_config(''warehouse.discount_reason'', COALESCE(p_invoice_data->>''discount_reason'', ''''), true);');
    EXECUTE patched;
  END LOOP;
END $patch$;

NOTIFY pgrst, 'reload schema';
