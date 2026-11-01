-- Migration 134: an invoice is cancelled, not deleted; the invoice records are audited and the audit trail is kept 8 years (review finding H5).
--
--  1. invoice gets cancelled_at, cancelled_by and cancel_reason (all three together, the reason 3 to 500 characters). The app role reads
--     the three columns like deleted_at and deleted_by (column grant of migration 48), so a customer still sees a cancelled invoice.
--  2. cancel_invoice(p_invoice_id, p_reason, p_expected_updated_at): administrators and supervisors. The invoice keeps its number and its
--     lines. Refused: an unknown or deleted invoice, one already cancelled (INVOICE_CANCELLED), one that changed after the caller read it
--     (STALE_RECORD), one with payments (INVOICE_HAS_PAYMENTS). The GRN is invoiceable again unless another live invoice holds it.
--  3. delete_invoice refuses (INVOICE_CANCEL_ONLY) and deletes nothing; its authorize_rpc call stays first.
--  4. update_invoice and save_invoice_internal refuse a cancelled invoice (INVOICE_CANCELLED). The number stays taken:
--     unique_inv_no_per_year counts every row, and get_next_invoice_number (migration 127) reads MAX(inv_no) of every row.
--  5. A cancelled invoice is not "live" any more where a live invoice matters: its lines may go on a new invoice (claim_invoice_lines), the
--     GRN and the dispatch can be edited again (get_grn_edit_state, get_grn_item_rates, get_dispatch_details, delete_dispatch_with_order_cleanup;
--     update_grn and update_dispatch_smart in their definition files), and the GRN list shows the GRN as not invoiced.
--  6. Reads: get_invoices_list answers cancelled_at and cancel_reason; get_customer_invoice_summary and get_customer_activity_detail list a
--     cancelled invoice with the status 'cancelled' and leave it out of every sum and count (cancelled_count says how many there are);
--     get_all_customer_activity_summary leaves it out of its invoice amount. get_invoice_detail (definition file) answers the three fields.
--  7. Audit triggers on invoice, invoice_trl, payments and dispatch_trl, the two-trigger pattern of migration 121 (an UPDATE trigger with a
--     WHEN cannot also cover INSERT and DELETE): every insert and delete, and every update that changes more than updated_at.
--  8. audit_log keeps 2920 days (8 years; GST records are kept 72 months, with a margin) instead of 730.
--
-- Run twice, the patch blocks fail on their count check (each before-text is gone after the first run and no after-text contains its before-text).

-- 1. Columns
ALTER TABLE public.invoice
  ADD COLUMN cancelled_at timestamptz,
  ADD COLUMN cancelled_by uuid REFERENCES public.user_profiles(id),
  ADD COLUMN cancel_reason text,
  ADD CONSTRAINT invoice_cancel_record_check CHECK (
    cancelled_at IS NULL OR (cancelled_by IS NOT NULL AND length(btrim(cancel_reason)) BETWEEN 3 AND 500));
COMMENT ON COLUMN public.invoice.cancelled_at IS 'Migration 134: set by cancel_invoice. A cancelled invoice keeps its number and its lines, is not live (no sums, the GRN is invoiceable again) and can not be edited.';
GRANT SELECT (cancelled_at, cancelled_by, cancel_reason) ON TABLE public.invoice TO authenticated;

-- The one patch helper of this file. Every marker must occur exactly once in the function as it is stored, and no replacement may contain
-- the marker it replaces (a second run would otherwise patch again instead of failing).
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
  FOR i IN 1 .. array_length(p_old, 1) LOOP
    IF position(p_old[i] IN p_new[i]) > 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % contains the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- 2. cancel_invoice
CREATE FUNCTION public.cancel_invoice(p_invoice_id uuid, p_reason text, p_expected_updated_at timestamptz) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  v_reason text := btrim(p_reason);
  v_by uuid;
  v_gr_id uuid;
  v_inv_no integer;
  v_fin_year integer;
  v_stored_updated_at timestamptz;
  v_cancelled_at timestamptz;
  v_payments integer;
  v_new_updated_at timestamptz;
BEGIN
  PERFORM warehouse_security.authorize_rpc('cancel_invoice', jsonb_build_object('p_invoice_id', p_invoice_id));
  -- Administrators and supervisors (authorize_rpc lets them through and refuses staff and customers); the body does not depend on it.
  IF COALESCE(warehouse_security.active_role(), '') NOT IN ('admin', 'supervisor') AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  IF v_reason IS NULL OR char_length(v_reason) < 3 OR char_length(v_reason) > 500 THEN
    RETURN warehouse_security.refuse('CANCEL_REASON_INVALID', 'Give a reason of 3 to 500 characters.',
      jsonb_build_object('min', 3, 'max', 500));
  END IF;
  v_by := public.get_current_user_profile_id();
  IF v_by IS NULL THEN
    RETURN warehouse_security.refuse('USER_REQUIRED', 'An invoice is cancelled by a signed-in person.');
  END IF;
  -- The list-refresh lock comes before any row lock (migration 46).
  PERFORM pg_advisory_xact_lock(71040);
  -- The live invoice is locked: a payment being written for it holds a key-share lock on the row, so the payments check below waits
  -- for that payment and sees it.
  SELECT i.gr_id, i.inv_no, i.inv_fin_year, i.updated_at, i.cancelled_at
    INTO v_gr_id, v_inv_no, v_fin_year, v_stored_updated_at, v_cancelled_at
    FROM invoice i WHERE i.id = p_invoice_id AND i.deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invoice not found');
  END IF;
  IF v_cancelled_at IS NOT NULL THEN
    RETURN warehouse_security.refuse('INVOICE_CANCELLED', 'This invoice is already cancelled.',
      jsonb_build_object('invoice_id', p_invoice_id, 'cancelled_at', v_cancelled_at));
  END IF;
  IF p_expected_updated_at IS NOT NULL
     AND date_trunc('milliseconds', v_stored_updated_at) IS DISTINCT FROM date_trunc('milliseconds', p_expected_updated_at) THEN
    RETURN warehouse_security.refuse('STALE_RECORD', 'Someone else changed this invoice. Open it again.',
      jsonb_build_object('what', 'invoice', 'id', p_invoice_id,
                         'expected_updated_at', p_expected_updated_at, 'current_updated_at', v_stored_updated_at));
  END IF;
  SELECT count(*) INTO v_payments FROM payments p WHERE p.invoice_id = p_invoice_id;
  IF v_payments > 0 THEN
    RETURN warehouse_security.refuse('INVOICE_HAS_PAYMENTS', 'This invoice has payments and can not be cancelled.',
      jsonb_build_object('invoice_id', p_invoice_id, 'payments', v_payments));
  END IF;

  UPDATE invoice SET cancelled_at = now(), cancelled_by = v_by, cancel_reason = v_reason, updated_at = now()
  WHERE id = p_invoice_id
  RETURNING cancelled_at, updated_at INTO v_cancelled_at, v_new_updated_at;

  -- The GRN is invoiceable again, unless another live invoice still holds it (as delete_invoice did, migration 120).
  UPDATE goodsreceived SET invoiced = false
  WHERE id = v_gr_id
    AND invoiced IS DISTINCT FROM false
    AND NOT EXISTS (SELECT 1 FROM invoice i WHERE i.gr_id = v_gr_id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL AND i.id <> p_invoice_id);

  RETURN jsonb_build_object(
    'success', true,
    'invoice_id', p_invoice_id,
    'invoice_number', v_inv_no,
    'inv_fin_year', v_fin_year,
    'gr_id', v_gr_id,
    'cancelled_at', v_cancelled_at,
    'cancelled_by', v_by,
    'cancel_reason', v_reason,
    'updated_at', v_new_updated_at,
    'message', 'Invoice cancelled successfully');
EXCEPTION WHEN insufficient_privilege THEN RAISE;
WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END $$;
ALTER FUNCTION public.cancel_invoice(uuid, text, timestamptz) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.cancel_invoice(uuid, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_invoice(uuid, text, timestamptz) TO authenticated, service_role;

-- 3. delete_invoice: an invoice is cancelled, never deleted. The text of the answer is the refusal's; nothing is read or written.
CREATE OR REPLACE FUNCTION public.delete_invoice(p_invoice_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
BEGIN
  PERFORM warehouse_security.authorize_rpc('delete_invoice',jsonb_build_object('p_invoice_id',p_invoice_id));
  RETURN warehouse_security.refuse('INVOICE_CANCEL_ONLY', 'An invoice is not deleted: cancel it instead. Its number stays in the books.',
    jsonb_build_object('invoice_id', p_invoice_id));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM
    );
END;
$$;

-- 4. update_invoice and save_invoice_internal refuse a cancelled invoice.
SELECT pg_temp.patch_function('public.update_invoice(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$FOR UPDATE;

    IF NOT FOUND THEN$m$
], ARRAY[
$m$FOR UPDATE;

    -- Migration 134: a cancelled invoice is not edited. The row is locked, so this and the stale check below see the same row.
    IF EXISTS (SELECT 1 FROM invoice c WHERE c.id = p_invoice_id AND c.deleted_at IS NULL AND c.cancelled_at IS NOT NULL) THEN
        RETURN warehouse_security.refuse('INVOICE_CANCELLED', 'This invoice is cancelled and can not be changed.',
            jsonb_build_object('invoice_id', p_invoice_id));
    END IF;

    IF NOT FOUND THEN$m$
]);

SELECT pg_temp.patch_function('public.save_invoice_internal(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$BEGIN
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();$m$
], ARRAY[
$m$BEGIN
    -- Migration 134: saving over the id of a cancelled invoice is refused by name (the primary key would refuse it too).
    IF p_invoice_id IS NOT NULL AND EXISTS (SELECT 1 FROM invoice c WHERE c.id = p_invoice_id AND c.cancelled_at IS NOT NULL) THEN
        RETURN warehouse_security.refuse('INVOICE_CANCELLED', 'This invoice is cancelled and can not be changed.',
            jsonb_build_object('invoice_id', p_invoice_id)) || jsonb_build_object('function_version', v_function_version);
    END IF;
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();$m$
]);

-- 5. A cancelled invoice is not live.
-- Its dispatch lines may go on a new invoice.
SELECT pg_temp.patch_function('warehouse_security.claim_invoice_lines(uuid, uuid, uuid[])'::regprocedure, ARRAY[
$m$AND holder.deleted_at IS NULL
      AND other.invoice_id IS DISTINCT FROM p_invoice_id$m$
], ARRAY[
$m$AND holder.deleted_at IS NULL
      AND holder.cancelled_at IS NULL
      AND other.invoice_id IS DISTINCT FROM p_invoice_id$m$
]);

SELECT pg_temp.patch_function('public.get_grn_edit_state(uuid)'::regprocedure, ARRAY[
$m$WHERE i.gr_id = p_grn_id AND i.deleted_at IS NULL
    ORDER BY$m$,
$m$JOIN invoice i ON i.id = it.invoice_id AND i.deleted_at IS NULL
        WHERE dt.gr_trl_id = t.id$m$
], ARRAY[
$m$WHERE i.gr_id = p_grn_id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL
    ORDER BY$m$,
$m$JOIN invoice i ON i.id = it.invoice_id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL
        WHERE dt.gr_trl_id = t.id$m$
]);

SELECT pg_temp.patch_function('public.get_grn_item_rates(uuid)'::regprocedure, ARRAY[
$m$AND inv.deleted_at IS NULL AND COALESCE(inv.notes, '') NOT LIKE '%[CANCELLED:%'
     ORDER BY$m$,
$m$AND inv.deleted_at IS NULL AND COALESCE(inv.notes, '') NOT LIKE '%[CANCELLED:%';$m$
], ARRAY[
$m$AND inv.deleted_at IS NULL AND inv.cancelled_at IS NULL AND COALESCE(inv.notes, '') NOT LIKE '%[CANCELLED:%'
     ORDER BY$m$,
$m$AND inv.deleted_at IS NULL AND inv.cancelled_at IS NULL AND COALESCE(inv.notes, '') NOT LIKE '%[CANCELLED:%';$m$
]);

SELECT pg_temp.patch_function('public.get_dispatch_details(uuid)'::regprocedure, ARRAY[
$m$AND inv.deleted_at IS NULL)
                                   ON dt.id = it.disp_trl_id$m$,
$m$AND di.deleted_at IS NULL)$m$,
$m$WHERE inv.deleted_at IS NULL
                          AND inv.id IN ($m$
], ARRAY[
$m$AND inv.deleted_at IS NULL AND inv.cancelled_at IS NULL)
                                   ON dt.id = it.disp_trl_id$m$,
$m$AND di.deleted_at IS NULL AND di.cancelled_at IS NULL)$m$,
$m$WHERE inv.deleted_at IS NULL AND inv.cancelled_at IS NULL
                          AND inv.id IN ($m$
]);

SELECT pg_temp.patch_function('public.delete_dispatch_with_order_cleanup(uuid, uuid)'::regprocedure, ARRAY[
$m$JOIN invoice inv ON inv.id = it.invoice_id AND inv.deleted_at IS NULL
    WHERE it.disp_trl_id IN ($m$
], ARRAY[
$m$JOIN invoice inv ON inv.id = it.invoice_id AND inv.deleted_at IS NULL AND inv.cancelled_at IS NULL
    WHERE it.disp_trl_id IN ($m$
]);

-- The figures of a cancelled invoice do not win over the rates when its id is passed (it is not edited any more).
SELECT pg_temp.patch_function('public.build_invoice_recalculation_rows(uuid, text, uuid)'::regprocedure, ARRAY[
$m$LEFT JOIN invoice_trl it ON it.disp_trl_id = dt.id AND it.invoice_id = p_invoice_id
        WHERE grt.gr_id = p_gr_id$m$
], ARRAY[
$m$LEFT JOIN invoice_trl it ON it.disp_trl_id = dt.id AND it.invoice_id = p_invoice_id
          AND NOT EXISTS (SELECT 1 FROM invoice ci WHERE ci.id = it.invoice_id AND ci.cancelled_at IS NOT NULL)
        WHERE grt.gr_id = p_gr_id$m$
]);

SELECT pg_temp.patch_function('public.get_customer_grn_activity(uuid, date, date)'::regprocedure, ARRAY[
$m$FROM invoice i
            WHERE i.deleted_at IS NULL
            ORDER BY i.gr_id$m$
], ARRAY[
$m$FROM invoice i
            WHERE i.deleted_at IS NULL AND i.cancelled_at IS NULL
            ORDER BY i.gr_id$m$
]);

-- 6. Reads
SELECT pg_temp.patch_function('public.get_invoices_list(integer, integer, uuid, integer, text, text, text, text, integer, integer, text, timestamp with time zone, timestamp with time zone, uuid[])'::regprocedure, ARRAY[
$m$'created_by', i.created_by,
                       'total_qty', q.total_qty,$m$
], ARRAY[
$m$'created_by', i.created_by,
                       'cancelled_at', i.cancelled_at,
                       'cancel_reason', i.cancel_reason,
                       'total_qty', q.total_qty,$m$
]);

SELECT pg_temp.patch_function('public.get_customer_invoice_summary(uuid, date, date, integer)'::regprocedure, ARRAY[
-- 1 the empty answer of a login without customers
$m$'total_amount', 0,
                        'net_amount', 0$m$,
-- 2 one customer: the invoice rows carry the cancellation
$m$COALESCE(i.total, 0) as net_total,
                i.notes
            FROM invoice i
            LEFT JOIN goodsreceived gr$m$,
$m$id.notes,
                jsonb_set($m$,
-- 4 a cancelled invoice is neither paid nor pending and owes nothing (so the paid and pending counts, which read the status word, skip it)
$m$CASE WHEN bal.balance <= 0.50 THEN to_jsonb('paid'::text) ELSE to_jsonb('pending'::text) END$m$,
$m$CROSS JOIN LATERAL (SELECT COALESCE(id.total, 0) - rcv.received AS balance) bal$m$,
-- 6 the month breakdown and the summary leave cancelled invoices out
$m$FROM invoices_full
            GROUP BY TO_CHAR(warehouse_security.business_date(invoice_date), 'YYYY-MM')$m$,
$m$'total_invoices', (SELECT COUNT(*) FROM invoices_full),
                'total_amount', COALESCE((SELECT SUM(total) FROM invoices_full), 0),
                'total_labour', COALESCE((SELECT SUM(labour) FROM invoices_full), 0),
                'total_tax', COALESCE((SELECT SUM(tax_amount) FROM invoices_full), 0),
                'total_discount', COALESCE((SELECT SUM(discount) FROM invoices_full), 0),
                'net_amount', COALESCE((SELECT SUM(net_total) FROM invoices_full), 0),
                'paid_count', (SELECT COUNT(*) FROM invoices_full WHERE (payment_status->>'status') = 'paid'),
                'pending_count', (SELECT COUNT(*) FROM invoices_full WHERE (payment_status->>'status') = 'pending'),
                'paid_amount', COALESCE((SELECT SUM(received_amount) FROM invoices_full), 0),
                'pending_amount', COALESCE((SELECT SUM(balance_amount) FROM invoices_full), 0)$m$,
$m$'notes', notes,
                        'payment_status', payment_status,$m$,
-- 9 all customers
$m$COALESCE(i.total, 0) as net_total
            FROM invoice i
            JOIN customers c ON i.customer_id = c.id$m$,
$m$FROM invoice_data
            GROUP BY customer_id, customer_name$m$,
$m$FROM invoice_data
            GROUP BY TO_CHAR(warehouse_security.business_date(inv_date), 'YYYY-MM')$m$,
$m$'total_invoices', (SELECT COUNT(*) FROM invoice_data),
                'total_customers', (SELECT COUNT(DISTINCT customer_id) FROM invoice_data),
                'total_amount', COALESCE((SELECT SUM(total) FROM invoice_data), 0),
                'total_tax', COALESCE((SELECT SUM(tax_amount) FROM invoice_data), 0),
                'net_amount', COALESCE((SELECT SUM(net_total) FROM invoice_data), 0)$m$
], ARRAY[
$m$'total_amount', 0,
                        'cancelled_count', 0,
                        'net_amount', 0$m$,
$m$COALESCE(i.total, 0) as net_total,
                i.notes,
                i.cancelled_at,
                i.cancel_reason
            FROM invoice i
            LEFT JOIN goodsreceived gr$m$,
$m$id.notes,
                id.cancelled_at,
                id.cancel_reason,
                jsonb_set($m$,
$m$CASE WHEN id.cancelled_at IS NOT NULL THEN to_jsonb('cancelled'::text) WHEN bal.balance <= 0.50 THEN to_jsonb('paid'::text) ELSE to_jsonb('pending'::text) END$m$,
$m$CROSS JOIN LATERAL (SELECT CASE WHEN id.cancelled_at IS NOT NULL THEN 0 ELSE COALESCE(id.total, 0) - rcv.received END AS balance) bal$m$,
$m$FROM invoices_full
            WHERE cancelled_at IS NULL
            GROUP BY TO_CHAR(warehouse_security.business_date(invoice_date), 'YYYY-MM')$m$,
$m$'total_invoices', (SELECT COUNT(*) FROM invoices_full WHERE cancelled_at IS NULL),
                'cancelled_count', (SELECT COUNT(*) FROM invoices_full WHERE cancelled_at IS NOT NULL),
                'total_amount', COALESCE((SELECT SUM(total) FROM invoices_full WHERE cancelled_at IS NULL), 0),
                'total_labour', COALESCE((SELECT SUM(labour) FROM invoices_full WHERE cancelled_at IS NULL), 0),
                'total_tax', COALESCE((SELECT SUM(tax_amount) FROM invoices_full WHERE cancelled_at IS NULL), 0),
                'total_discount', COALESCE((SELECT SUM(discount) FROM invoices_full WHERE cancelled_at IS NULL), 0),
                'net_amount', COALESCE((SELECT SUM(net_total) FROM invoices_full WHERE cancelled_at IS NULL), 0),
                'paid_count', (SELECT COUNT(*) FROM invoices_full WHERE (payment_status->>'status') = 'paid'),
                'pending_count', (SELECT COUNT(*) FROM invoices_full WHERE (payment_status->>'status') = 'pending'),
                'paid_amount', COALESCE((SELECT SUM(received_amount) FROM invoices_full WHERE cancelled_at IS NULL), 0),
                'pending_amount', COALESCE((SELECT SUM(balance_amount) FROM invoices_full WHERE cancelled_at IS NULL), 0)$m$,
$m$'notes', notes,
                        'cancelled_at', cancelled_at,
                        'cancel_reason', cancel_reason,
                        'payment_status', payment_status,$m$,
$m$COALESCE(i.total, 0) as net_total,
                i.cancelled_at
            FROM invoice i
            JOIN customers c ON i.customer_id = c.id$m$,
$m$FROM invoice_data
            WHERE cancelled_at IS NULL
            GROUP BY customer_id, customer_name$m$,
$m$FROM invoice_data
            WHERE cancelled_at IS NULL
            GROUP BY TO_CHAR(warehouse_security.business_date(inv_date), 'YYYY-MM')$m$,
$m$'total_invoices', (SELECT COUNT(*) FROM invoice_data WHERE cancelled_at IS NULL),
                'cancelled_count', (SELECT COUNT(*) FROM invoice_data WHERE cancelled_at IS NOT NULL),
                'total_customers', (SELECT COUNT(DISTINCT customer_id) FROM invoice_data WHERE cancelled_at IS NULL),
                'total_amount', COALESCE((SELECT SUM(total) FROM invoice_data WHERE cancelled_at IS NULL), 0),
                'total_tax', COALESCE((SELECT SUM(tax_amount) FROM invoice_data WHERE cancelled_at IS NULL), 0),
                'net_amount', COALESCE((SELECT SUM(net_total) FROM invoice_data WHERE cancelled_at IS NULL), 0)$m$
]);

SELECT pg_temp.patch_function('public.get_customer_activity_detail(uuid, date, date)'::regprocedure, ARRAY[
$m$as total_pending_amount
        FROM invoice
        WHERE customer_id = p_customer_uuid
            AND deleted_at IS NULL
$m$,
$m$COALESCE(id.total_pending_amount, 0),
        'average_stock_age_days'$m$,
$m$as invoice_amount
        FROM invoice
        WHERE customer_id = p_customer_uuid
            AND deleted_at IS NULL
            AND inv_date$m$,
$m$EXISTS (SELECT 1 FROM invoice i WHERE i.gr_id = gr.id AND i.deleted_at IS NULL) as is_invoiced$m$,
$m$CASE WHEN COALESCE(i.total, 0) - GREATEST(0, LEAST(COALESCE((SELECT SUM(p.amount) FROM payments p WHERE p.invoice_id = i.id), 0), COALESCE(i.total, 0))) <= 0.50 THEN 'paid' ELSE 'pending' END as status$m$
], ARRAY[
$m$as total_pending_amount,
            (SELECT COUNT(*) FROM invoice c
              WHERE c.customer_id = p_customer_uuid AND c.deleted_at IS NULL AND c.cancelled_at IS NOT NULL
                AND c.inv_date >= warehouse_security.business_day_start(p_from_date) AND c.inv_date < warehouse_security.business_day_start(p_to_date + 1)) as cancelled_count
        FROM invoice
        WHERE customer_id = p_customer_uuid
            AND deleted_at IS NULL
            AND cancelled_at IS NULL
$m$,
$m$COALESCE(id.total_pending_amount, 0),
        'cancelled_count', COALESCE(id.cancelled_count, 0),
        'average_stock_age_days'$m$,
$m$as invoice_amount
        FROM invoice
        WHERE customer_id = p_customer_uuid
            AND deleted_at IS NULL
            AND cancelled_at IS NULL
            AND inv_date$m$,
$m$EXISTS (SELECT 1 FROM invoice i WHERE i.gr_id = gr.id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL) as is_invoiced$m$,
$m$CASE WHEN i.cancelled_at IS NOT NULL THEN 'cancelled' WHEN COALESCE(i.total, 0) - GREATEST(0, LEAST(COALESCE((SELECT SUM(p.amount) FROM payments p WHERE p.invoice_id = i.id), 0), COALESCE(i.total, 0))) <= 0.50 THEN 'paid' ELSE 'pending' END as status$m$
]);

SELECT pg_temp.patch_function('public.get_all_customer_activity_summary(date, date)'::regprocedure, ARRAY[
$m$FROM invoice
        WHERE deleted_at IS NULL
            AND inv_date$m$
], ARRAY[
$m$FROM invoice
        WHERE deleted_at IS NULL AND cancelled_at IS NULL
            AND inv_date$m$
]);

-- 7. Audit triggers (public.audit_trigger_func, the pattern of migration 121). The UPDATE triggers fire only when more than updated_at changed.
CREATE TRIGGER audit_invoice AFTER INSERT OR DELETE ON public.invoice FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER audit_invoice_update AFTER UPDATE ON public.invoice FOR EACH ROW
  WHEN ((to_jsonb(OLD) - 'updated_at') IS DISTINCT FROM (to_jsonb(NEW) - 'updated_at'))
  EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER audit_invoice_trl AFTER INSERT OR DELETE ON public.invoice_trl FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER audit_invoice_trl_update AFTER UPDATE ON public.invoice_trl FOR EACH ROW
  WHEN ((to_jsonb(OLD) - 'updated_at') IS DISTINCT FROM (to_jsonb(NEW) - 'updated_at'))
  EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER audit_payments AFTER INSERT OR DELETE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER audit_payments_update AFTER UPDATE ON public.payments FOR EACH ROW
  WHEN ((to_jsonb(OLD) - 'updated_at') IS DISTINCT FROM (to_jsonb(NEW) - 'updated_at'))
  EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER audit_dispatch_trl AFTER INSERT OR DELETE ON public.dispatch_trl FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER audit_dispatch_trl_update AFTER UPDATE ON public.dispatch_trl FOR EACH ROW
  WHEN ((to_jsonb(OLD) - 'updated_at') IS DISTINCT FROM (to_jsonb(NEW) - 'updated_at'))
  EXECUTE FUNCTION public.audit_trigger_func();

-- 8. Retention: GST records are kept 72 months; 2920 days (8 years) leaves a margin. Whole monthly partitions are dropped once they ended
-- more than that ago (migration 123, run_database_retention).
UPDATE warehouse_maintenance.retention_policy
   SET days = 2920,
       description = 'Audit trail (audit_log): whole monthly partitions that ended more than 8 years (2920 days) ago are dropped; new partitions are made 3 months ahead'
 WHERE key = 'audit_log';

NOTIFY pgrst, 'reload schema';
