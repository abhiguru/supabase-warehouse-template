-- Migration 146: "Delete invoice" comes back beside "Cancel invoice" (WH-43; owner decision of 2026-11-02, replacing the cancel-only rule of migration 134).
--
-- delete_invoice works again, as migration 120 had it, with three changes:
--   * it deletes a live or a cancelled invoice (administrators and supervisors; authorize_rpc refuses staff and customers, and the body checks the
--     role as cancel_invoice does);
--   * it takes the version token the screen read (p_expected_updated_at, as cancel_invoice does) and refuses a changed invoice with STALE_RECORD;
--   * the GRN's invoiced flag is reset unless another invoice that is neither deleted nor cancelled holds the GRN.
-- It still refuses an invoice that payments refer to, and an unknown invoice ("Invoice not found").
-- The invoice and its lines are removed for good. The audit triggers of migration 134 (audit_invoice, audit_invoice_trl) keep the deleted rows,
-- the lines with their kept_* copies of migration 143, for 8 years.
-- The number is free once the row is gone: unique_inv_no_per_year, the "already used" check of save_invoice_internal and get_next_invoice_number
-- (migration 127, MAX(inv_no)) all read the remaining rows of public.invoice. A row soft-deleted earlier (deleted_at set) stays in the table and
-- keeps its number reserved. A cancelled invoice keeps its number until it is deleted.
-- The trigger trigger_reset_grn_invoiced_on_invoice_delete needs no change: reset_grn_invoiced_flag already skips cancelled invoices (migration 134).
-- delete_grn_safe's text and authorize_rpc's comment are definition files (migrations/definitions/), changed there.
--
-- The one-argument function is replaced by a two-argument one with a default, so a call with p_invoice_id alone still works and no overload remains.

DROP FUNCTION public.delete_invoice(uuid);

CREATE FUNCTION public.delete_invoice(p_invoice_id uuid, p_expected_updated_at timestamptz DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_gr_id uuid;
  v_inv_no integer;
  v_fin_year integer;
  v_stored_updated_at timestamptz;
BEGIN
  PERFORM warehouse_security.authorize_rpc('delete_invoice', jsonb_build_object('p_invoice_id', p_invoice_id));
  -- Administrators and supervisors (authorize_rpc lets them through and refuses staff and customers); the body does not depend on it.
  IF COALESCE(warehouse_security.active_role(), '') NOT IN ('admin', 'supervisor') AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  -- The list-refresh lock comes before any row lock (migration 46).
  PERFORM pg_advisory_xact_lock(71040);
  -- The invoice (live or cancelled) is locked: a payment being written for it holds a key-share lock on the row, so the check below waits for
  -- that payment and sees it. A row soft-deleted earlier is not found.
  SELECT i.gr_id, i.inv_no, i.inv_fin_year, i.updated_at
    INTO v_gr_id, v_inv_no, v_fin_year, v_stored_updated_at
    FROM invoice i WHERE i.id = p_invoice_id AND i.deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invoice not found');
  END IF;
  IF p_expected_updated_at IS NOT NULL
     AND date_trunc('milliseconds', v_stored_updated_at) IS DISTINCT FROM date_trunc('milliseconds', p_expected_updated_at) THEN
    RETURN warehouse_security.refuse('STALE_RECORD', 'Someone else changed this invoice. Open it again.',
      jsonb_build_object('what', 'invoice', 'id', p_invoice_id,
                         'expected_updated_at', p_expected_updated_at, 'current_updated_at', v_stored_updated_at));
  END IF;
  IF EXISTS (SELECT 1 FROM payments WHERE invoice_id = p_invoice_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cannot delete an invoice that has payments');
  END IF;

  -- The lines first (invoice_trl.invoice_id is ON DELETE RESTRICT, migration 139). Both deletes are audited with the whole row.
  DELETE FROM invoice_trl WHERE invoice_id = p_invoice_id;
  DELETE FROM invoice WHERE id = p_invoice_id;

  -- The GRN is invoiceable again, unless another invoice that is neither deleted nor cancelled still holds it (the trigger does the same).
  UPDATE goodsreceived SET invoiced = false
  WHERE id = v_gr_id
    AND invoiced IS DISTINCT FROM false
    AND NOT EXISTS (SELECT 1 FROM invoice i WHERE i.gr_id = v_gr_id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL);

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Invoice deleted successfully',
    'invoice_id', p_invoice_id,
    'invoice_number', v_inv_no,
    'inv_fin_year', v_fin_year,
    'gr_id', v_gr_id);
EXCEPTION WHEN insufficient_privilege THEN RAISE;
WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END $$;
ALTER FUNCTION public.delete_invoice(uuid, timestamptz) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.delete_invoice(uuid, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_invoice(uuid, timestamptz) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
