-- Review fixes 2026-10-20 (the order, dispatch, GRN and invoice reviews): server side of the verified findings and of
-- the owner decisions D20 and D22. Wave A contract items 1 to 6 and 12 to 14 are implemented here; the app halves are in
-- the app repository.
--
--  * Cached create answers (B1, H1): create_dispatch_with_stock_check and save_grn replay a saved answer only while the
--    dispatch / GRN it created still exists (and is not deleted), otherwise the key is dropped and the call creates
--    normally; delete_dispatch_with_order_cleanup and delete_grn_safe drop the keys that point at what they delete. The
--    save_grn key lives 24 hours like the dispatch key, and a new answer replaces an expired row of its key.
--  * Request codes and get_submission_result (D22, contract items 12 to 14): update_dispatch_smart reads
--    p_dispatch_data->>'request_key', the 3-argument save_invoice and update_invoice read p_invoice_data->>'request_key'.
--    With a code, this user's saved success answer for it is returned as it was, under lock 71040 and before any other
--    check, while the record it made still exists; after a successful write the answer is stored in idempotency_keys
--    (24 hours, an expired row of the code is replaced). get_submission_result(p_key) tells the caller, for its own
--    saved answers only, whether a lost save went through: {found:true, response} or {found:false}. It is granted to
--    authenticated and allowed for staff in authorize_rpc (administrators and supervisors pass the gate).
--  * Cancelled invoices keep their lines (D20): invoice_trl.disp_trl_id may be empty and its foreign key is
--    ON DELETE SET NULL, so removing a dispatch line or a dispatch no longer deletes the lines and amounts of a
--    cancelled (soft-deleted) invoice. The guards still count only live invoices.
--  * update_dispatch_smart: locks the dispatch row and answers "Dispatch not found" (A16); refuses an empty line list (B3);
--    movements of an edit reference the dispatch, the line id is in the notes (B13); a line without a lot is never removed
--    (B15); only live invoices count in the edit and delete guards (B16); keeps the stored names unless the customer or
--    supervisor changes, then takes the new person's name (A14, B12); NUMBER_TAKEN (M4); no new or raised line of a
--    deleted GRN (N3).
--  * create_dispatch_with_stock_check_internal: a lot deleted before the lock is refused (B9); order_lines_left, the
--    pending lines of the source order (A7); names from the master tables and a supervisor who may supervise (A14, B12);
--    the order number only from the source order; NUMBER_TAKEN (M4); no lot of a deleted GRN (N3). add_item_to_order: no
--    lot of a deleted GRN (N3).
--  * confirm_dispatch_image_upload and confirm_grn_image_upload: row lock, NOT_FOUND when the row went away (B14, G14).
--  * Invoices: delete_invoice locks the live invoice, re-checks payments, and clears goodsreceived.invoiced only when no
--    other live invoice holds the GRN, also in the trigger (I12); update_invoice keeps the stored notes and duration_mode
--    when the request has no such key (I2), checks the financial year only when the date or the year changes (I13), and
--    clears the old GRN's flag only when no other live invoice holds it; the 3-argument save_invoice no longer refuses on
--    the phone's estimated totals (J2); save_invoice(jsonb) takes the year of the invoice date and refuses another
--    year, save_invoice_internal refuses a financial year that is not the invoice date's (I13); NUMBER_TAKEN from both
--    save_invoice signatures and update_invoice (I4).
--  * apply_grn_rates: an optional seen_ids on a customer / everyone rate entry makes a stale sheet answer STALE_RATES (H5).
--  * authorize_rpc: a cart line that no longer exists is answered by the function, "Order item not found" (A12);
--    get_submission_result is allowed for staff.
--
-- Not here (owner decisions pending, or not safe without a database test): version checks on documents, what may change
-- after invoicing, edits that adjust the order, dispatch-from-order checks, numbering policy, B10 (lock order of the cart
-- rows).
--
-- Every function is the latest definition (migration 119, else the baseline) with only the changes above. Large baseline
-- functions (save_grn, delete_grn_safe, apply_grn_rates) are patched with the marker-count pattern of migration 111.

-- D20: invoice_trl.disp_trl_id may be empty; removing a dispatch line (or the dispatch) empties the link of a cancelled
-- invoice's line instead of deleting it. The guards count only live invoices, so only a cancelled invoice can have an
-- empty link.
ALTER TABLE public.invoice_trl ALTER COLUMN disp_trl_id DROP NOT NULL;
ALTER TABLE public.invoice_trl DROP CONSTRAINT invoice_trl_disp_trl_id_fkey;
ALTER TABLE ONLY public.invoice_trl
    ADD CONSTRAINT invoice_trl_disp_trl_id_fkey FOREIGN KEY (disp_trl_id) REFERENCES public.dispatch_trl(id) ON DELETE SET NULL;

-- J2: the phone's estimated total, labour and tax are not range-checked (the server recomputes them)
CREATE OR REPLACE FUNCTION public.validate_invoice_input(p_invoice_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_errors JSONB := '[]'::JSONB;
    v_result JSONB;
    v_customer_id TEXT;
    v_discount NUMERIC;
BEGIN
    -- Extract values
    v_customer_id := p_invoice_data->>'customer_id';
    v_discount := (p_invoice_data->>'discount')::NUMERIC;

    -- Validate customer_id (UUID)
    v_result := validate_uuid(v_customer_id, 'customer_id');
    IF NOT (v_result->>'valid')::BOOLEAN THEN
        v_errors := v_errors || v_result;
    END IF;

    -- The header's total, labour and tax amount are the phone's estimates. The server stores its own
    -- recomputed figures (recalculate_invoice_header), so an estimate is never a reason to refuse the
    -- invoice (migration 120); the stored columns still refuse a figure that does not fit. The discount is
    -- stored as sent and keeps its range.

    -- Validate discount (allow negative values for surcharges)
    -- Changed from min=0 to min=-99999999 on 2026-01-03
    v_result := validate_numeric_range(v_discount, 'discount', -99999999, 99999999, TRUE);
    IF NOT (v_result->>'valid')::BOOLEAN THEN
        v_errors := v_errors || v_result;
    END IF;

    -- Return result
    IF jsonb_array_length(v_errors) > 0 THEN
        RETURN jsonb_build_object(
            'valid', FALSE,
            'errors', v_errors
        );
    ELSE
        RETURN jsonb_build_object('valid', TRUE);
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'valid', FALSE,
            'errors', jsonb_build_array(jsonb_build_object(
                'field', 'invoice_data',
                'error', format('Invalid invoice data format: %s', SQLERRM)
            ))
        );
END;
$$;
-- B14, G14: the photo confirm locks the pending row and answers NOT_FOUND when the row went away
CREATE OR REPLACE FUNCTION public.confirm_dispatch_image_upload(p_image_id uuid, p_upload_token uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_user_id UUID;
    v_record RECORD;
BEGIN
  PERFORM warehouse_security.authorize_rpc('confirm_dispatch_image_upload',jsonb_build_object());
    -- 1. Authenticate user
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Authentication required',
            'code', 'AUTH_REQUIRED'
        );
    END IF;

    -- 2. Find the pending record with matching token
    -- The row is locked while it is confirmed: a cancel, a delete of the document or an edit that removes
    -- the photo waits, and a row that went away is answered below (migration 120).
    SELECT * INTO v_record
    FROM dispatch_images
    WHERE id = p_image_id
    AND upload_token = p_upload_token
    AND status = 'pending'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Upload not found, already confirmed, or invalid token',
            'code', 'NOT_FOUND'
        );
    END IF;

    IF warehouse_security.image_path_refusal('dispatch', v_record.dispatch_id, NULL, v_record.storage_path, v_record.id) IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', warehouse_security.image_path_refusal('dispatch', v_record.dispatch_id, NULL, v_record.storage_path, v_record.id),
            'code', 'IMAGE_NOT_VERIFIED'
        );
    END IF;

    -- 3. Update status to confirmed
    UPDATE dispatch_images
    SET status = 'confirmed',
        upload_token = NULL,  -- Clear token after use
        updated_at = NOW()
    WHERE id = p_image_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Upload not found, already confirmed, or invalid token',
            'code', 'NOT_FOUND'
        );
    END IF;

    -- 4. Return success
    RETURN jsonb_build_object(
        'success', true,
        'image_id', v_record.id,
        'storage_path', v_record.storage_path,
        'dispatch_id', v_record.dispatch_id,
        'status', 'confirmed'
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Unexpected error: ' || SQLERRM,
        'code', 'INTERNAL_ERROR'
    );
END;
$$;
CREATE OR REPLACE FUNCTION public.confirm_grn_image_upload(p_image_id uuid, p_upload_token uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_user_id uuid;
    v_record RECORD;
BEGIN
  PERFORM warehouse_security.authorize_rpc('confirm_grn_image_upload',jsonb_build_object());
    -- 1. Authenticate user
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Authentication required',
            'code', 'AUTH_REQUIRED'
        );
    END IF;

    -- 2. Find the pending record with matching token
    -- The row is locked while it is confirmed: a cancel, a delete of the document or an edit that removes
    -- the photo waits, and a row that went away is answered below (migration 120).
    SELECT * INTO v_record
    FROM grn_images
    WHERE id = p_image_id
    AND upload_token = p_upload_token
    AND status = 'pending'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Upload not found, already confirmed, or invalid token',
            'code', 'NOT_FOUND'
        );
    END IF;

    IF warehouse_security.image_path_refusal('grn', v_record.grn_id, v_record.image_type, v_record.storage_path, v_record.id) IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', warehouse_security.image_path_refusal('grn', v_record.grn_id, v_record.image_type, v_record.storage_path, v_record.id),
            'code', 'IMAGE_NOT_VERIFIED'
        );
    END IF;

    -- 3. Update status to confirmed
    UPDATE grn_images
    SET status = 'confirmed',
        upload_token = NULL,  -- Clear token after use
        updated_at = NOW()
    WHERE id = p_image_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Upload not found, already confirmed, or invalid token',
            'code', 'NOT_FOUND'
        );
    END IF;

    -- 4. Return success
    RETURN jsonb_build_object(
        'success', true,
        'image_id', v_record.id,
        'storage_path', v_record.storage_path,
        'grn_id', v_record.grn_id,
        'status', 'confirmed'
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Unexpected error: ' || SQLERRM,
        'code', 'INTERNAL_ERROR'
    );
END;
$$;
-- I12: delete_invoice locks the live invoice and clears the GRN flag only when no other live invoice holds the GRN
CREATE OR REPLACE FUNCTION public.delete_invoice(p_invoice_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_gr_id UUID;
BEGIN
  PERFORM warehouse_security.authorize_rpc('delete_invoice',jsonb_build_object('p_invoice_id',p_invoice_id));
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
    -- Get GR ID before deleting. The live invoice is locked: a payment being written for it holds a
    -- key-share lock on the row, so the check below waits for that payment and sees it. A deleted invoice
    -- is not found (migration 120).
    SELECT gr_id INTO v_gr_id FROM invoice WHERE id = p_invoice_id AND deleted_at IS NULL FOR UPDATE;

    IF v_gr_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invoice not found'
        );
    END IF;

    IF EXISTS (SELECT 1 FROM payments WHERE invoice_id = p_invoice_id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Cannot delete an invoice that has payments'
        );
    END IF;

    -- Delete invoice items (CASCADE should handle this, but explicit is safer)
    DELETE FROM invoice_trl WHERE invoice_id = p_invoice_id;

    -- Delete invoice
    DELETE FROM invoice WHERE id = p_invoice_id;

    -- Reset GRN invoiced flag, unless another live invoice still holds the GRN (migration 120)
    UPDATE goodsreceived SET invoiced = false
    WHERE id = v_gr_id
      AND NOT EXISTS (SELECT 1 FROM invoice i WHERE i.gr_id = v_gr_id AND i.deleted_at IS NULL);

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Invoice deleted successfully',
        'gr_id', v_gr_id
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM
    );
END;
$$;
CREATE OR REPLACE FUNCTION public.reset_grn_invoiced_flag() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
BEGIN
    -- Reset invoiced flag to false for the GRN that was associated with the deleted invoice, unless another
    -- live invoice still holds the GRN (migration 120)
    UPDATE goodsreceived
    SET invoiced = false
    WHERE id = OLD.gr_id
      AND NOT EXISTS (SELECT 1 FROM invoice i WHERE i.gr_id = OLD.gr_id AND i.deleted_at IS NULL AND i.id <> OLD.id);

    -- Log the deleted invoice (optional - for audit purposes)
    RAISE NOTICE 'Invoice deleted: %, GRN %', OLD.inv_no, OLD.gr_no;

    RETURN OLD;
END;
$$;
-- B1, H1: the save_grn answer is replayed only while its GRN exists, lives 24 hours, and replaces an expired row

DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$          IF v_cached_response IS NOT NULL THEN
              RETURN v_cached_response || jsonb_build_object('idempotent', true);
          END IF;
$m$,
    $m$              INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by)
              VALUES (p_idempotency_key, 'save_grn', v_result, v_user_profile_id)
              ON CONFLICT (idempotency_key) DO NOTHING;
$m$
  ];
  v_new constant text[] := ARRAY[
    $m$          -- The answer is replayed only while the GRN it created still exists and is not deleted. The answer of a
          -- deleted GRN is dropped (migration 120) and the call goes on as a new save: the same GRN can be entered
          -- again once its number is free again.
          IF v_cached_response IS NOT NULL THEN
              IF EXISTS (SELECT 1 FROM goodsreceived WHERE id = (v_cached_response #>> '{data,grn_id}')::uuid AND deleted_at IS NULL) THEN
                  RETURN v_cached_response || jsonb_build_object('idempotent', true);
              END IF;
              DELETE FROM idempotency_keys
              WHERE idempotency_key = p_idempotency_key
                AND rpc_function = 'save_grn'
                AND created_by = (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid());
          END IF;
$m$,
    $m$              -- Kept for the 24 hours a retry is answered from it (it was the column default, 1 hour), as
              -- update_grn and the dispatch create keep theirs. A key another function or user holds is left
              -- alone unless it has expired; an expired row of this key is replaced by the new answer
              -- (migration 120).
              INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
              VALUES (p_idempotency_key, 'save_grn', v_result, v_user_profile_id, now() + interval '24 hours')
              ON CONFLICT (idempotency_key) DO UPDATE SET
                  rpc_function = EXCLUDED.rpc_function,
                  response = EXCLUDED.response,
                  created_by = EXCLUDED.created_by,
                  created_at = now(),
                  expires_at = EXCLUDED.expires_at
              WHERE idempotency_keys.expires_at <= now()
                 OR (idempotency_keys.rpc_function = EXCLUDED.rpc_function
                     AND idempotency_keys.created_by IS NOT DISTINCT FROM EXCLUDED.created_by);
$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.save_grn(character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, text, character varying, jsonb)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'save_grn: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- B1, H1: deleting a GRN drops the saved answers that point at it

DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$          -- 6. Finally, delete the main GRN record
          DELETE FROM goodsreceived
          WHERE id = p_grn_id;
$m$
  ];
  v_new constant text[] := ARRAY[
    $m$          -- 6. Finally, delete the main GRN record
          DELETE FROM goodsreceived
          WHERE id = p_grn_id;

          -- 7. A saved create or edit answer that points at this GRN is not replayed any more: entering the
          -- same GRN again saves it (migration 120).
          DELETE FROM idempotency_keys
          WHERE (rpc_function = 'save_grn' AND response #>> '{data,grn_id}' = p_grn_id::text)
             OR (rpc_function = 'update_grn' AND response #>> '{grn,id}' = p_grn_id::text);
$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.delete_grn_safe(uuid)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'delete_grn_safe: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- H5: apply_grn_rates checks an optional seen_ids of each customer / everyone entry (STALE_RATES)

DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$  v_band constant text := 'Each band needs whole kilograms with the start at most the end';
$m$,
    $m$    v_to := NULL;
  END LOOP;
$m$,
    $m$  FOR v_e, v_ord IN SELECT e.value, (e.ord - 1)::integer FROM jsonb_array_elements(p_rates) WITH ORDINALITY e(value, ord)
      WHERE e.value->>'scope' IN ('customer','everyone') ORDER BY e.ord LOOP
$m$
  ];
  v_new constant text[] := ARRAY[
    $m$  v_band constant text := 'Each band needs whole kilograms with the start at most the end';
  v_unseen jsonb;
$m$,
    $m$    -- seen_ids (migration 120), when an entry carries it: the ids of the rate rows of the entry's scope that the
    -- sheet showed in force on the GRN day. A list of uuids, or absent (an older app).
    IF v_scope <> 'grn' AND jsonb_typeof(v_e->'seen_ids') IS NOT NULL AND jsonb_typeof(v_e->'seen_ids') <> 'null' THEN
      IF (CASE WHEN jsonb_typeof(v_e->'seen_ids') <> 'array' THEN true
               ELSE EXISTS (SELECT 1 FROM jsonb_array_elements(v_e->'seen_ids') s
                             WHERE jsonb_typeof(s) <> 'string'
                                OR (s #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') END) THEN
        RETURN warehouse_security.grn_rate_failure('INVALID_BANDS', 'seen_ids must be a list of rate ids',
          jsonb_build_object('index', v_ord, 'field', 'seen_ids'));
      END IF;
    END IF;
    v_to := NULL;
  END LOOP;
$m$,
    $m$  -- A sheet that is out of date (migration 120). An entry that lists seen_ids names the rows of its scope that the
  -- sheet showed in force on the GRN day. A row of the entry's scope and band that is in force on that day and is not
  -- listed was added or changed by someone else since, so nothing is written (STALE_RATES; data.ids is the unlisted
  -- ids, sorted). An entry without seen_ids is not checked. Every entry is read before the first write, because the
  -- writes below end and copy the rows of the other bands of the scope.
  FOR v_e, v_ord IN SELECT e.value, (e.ord - 1)::integer FROM jsonb_array_elements(p_rates) WITH ORDINALITY e(value, ord)
      WHERE e.value->>'scope' IN ('customer','everyone') AND jsonb_typeof(e.value->'seen_ids') = 'array' ORDER BY e.ord LOOP
    SELECT COALESCE(jsonb_agg(r.id ORDER BY r.id), '[]'::jsonb) INTO v_unseen
      FROM public.item_storage_prices r
     WHERE r.item_id = (v_e->>'item_id')::uuid
       AND r.customer_id IS NOT DISTINCT FROM CASE WHEN v_e->>'scope' = 'customer' THEN v_customer END
       AND r.price_type = v_type
       AND r.weight_min = (v_e->>'weight_min')::numeric::integer AND r.weight_max = (v_e->>'weight_max')::numeric::integer
       AND r.effective_from <= v_day AND COALESCE(r.effective_to, 'infinity'::date) >= v_day
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_e->'seen_ids') s WHERE lower(s) = r.id::text);
    IF v_unseen <> '[]'::jsonb THEN
      RETURN warehouse_security.grn_rate_failure('STALE_RATES', 'The rates were changed by someone else; reload and try again',
        jsonb_build_object('index', v_ord, 'ids', v_unseen)) || jsonb_build_object('reason', 'STALE_RATES');
    END IF;
  END LOOP;

  FOR v_e, v_ord IN SELECT e.value, (e.ord - 1)::integer FROM jsonb_array_elements(p_rates) WITH ORDINALITY e(value, ord)
      WHERE e.value->>'scope' IN ('customer','everyone') ORDER BY e.ord LOOP
$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('warehouse_security.apply_grn_rates(uuid, jsonb)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'apply_grn_rates: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- N3: a lot of a deleted GRN cannot be added to an order
CREATE OR REPLACE FUNCTION public.add_item_to_order(p_order_id uuid, p_grn_item_id uuid, p_quantity integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'warehouse_security', 'pg_temp'
    AS $$
DECLARE
  v_user_id uuid;
  v_order record;
  v_item record;
  v_new_item_id uuid;
  v_order_no text;
BEGIN
  PERFORM warehouse_security.authorize_rpc(
    'add_item_to_order',
    jsonb_build_object('p_order_id', p_order_id, 'p_grn_item_id', p_grn_item_id)
  );

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Quantity must be greater than zero');
  END IF;

  SELECT id INTO v_user_id
  FROM public.user_profiles
  WHERE auth_user_id = auth.uid() AND active;

  SELECT o.*, c.name AS current_customer_name
  INTO v_order
  FROM public.orders o
  JOIN public.customers c ON c.id = o.customer_id
  WHERE o.id = p_order_id AND o.deleted_at IS NULL;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Order not found');
  END IF;
  IF v_order.status <> 'OPEN' THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Cannot add items to ' || v_order.status || ' orders',
      'error', jsonb_build_object('code', 'ORDER_NOT_OPEN')
    );
  END IF;

  SELECT
    gt.*,
    g.gr_no,
    g.date AS gr_date,
    g.customer_id,
    g.customer_name,
    g.gr_image_url,
    g.deleted_at AS gr_deleted_at
  INTO v_item
  FROM public.goodsreceived_trl gt
  JOIN public.goodsreceived g ON g.id = gt.gr_id
  WHERE gt.id = p_grn_item_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'GRN item not found');
  END IF;
  -- The lots of a deleted receipt are not in any list and cannot be ordered (migration 120).
  IF v_item.gr_deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'message', 'GRN item not found');
  END IF;
  IF v_item.customer_id IS DISTINCT FROM v_order.customer_id THEN
    RAISE EXCEPTION 'Item belongs to another customer' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.order_items
    WHERE order_id = p_order_id AND grn_items_id = p_grn_item_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'message', 'Item already exists in order');
  END IF;
  IF v_item.stock < p_quantity THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', format('Insufficient stock. Available: %s, Requested: %s', v_item.stock, p_quantity)
    );
  END IF;

  v_order_no := NULLIF(v_order.order_no, '');
  IF v_order_no IS NULL THEN
    v_order_no := 'ORD-' || to_char(current_date, 'YYYYMMDD') || '-' || substring(p_order_id::text FROM 1 FOR 8);
    UPDATE public.orders SET order_no = v_order_no WHERE id = p_order_id;
  END IF;

  INSERT INTO public.order_items (
    order_id, order_no, requested_quantity,
    grn_items_id, grn_items_item_id, grn_items_item_name,
    grn_items_package_mark, grn_items_packaging, grn_items_rack,
    grn_items_weight, grn_items_image_url,
    grns_id, grns_gr_no, grns_date, grns_customer_id, grns_customer_name,
    available_stock_at_order, current_stock, item_status, sort_order
  ) VALUES (
    p_order_id, v_order_no, p_quantity,
    p_grn_item_id, v_item.item_id, v_item.item_name,
    COALESCE(v_item.package_mark, ''), COALESCE(v_item.packaging, ''), COALESCE(v_item.rack, ''),
    COALESCE(v_item.weight, 0), v_item.trl_img_url,
    v_item.gr_id, v_item.gr_no, v_item.gr_date, v_item.customer_id,
    COALESCE(v_item.customer_name, v_order.current_customer_name, ''),
    v_item.stock, v_item.stock, 'pending',
    COALESCE((SELECT max(sort_order) + 1 FROM public.order_items WHERE order_id = p_order_id), 1)
  ) RETURNING id INTO v_new_item_id;

  PERFORM warehouse_security.record_order_revision(p_order_id, v_user_id);
  UPDATE public.orders SET updated_at = now(), updated_by = v_user_id WHERE id = p_order_id;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Item added to order successfully',
    'data', jsonb_build_object(
      'order_item_id', v_new_item_id,
      'item_name', v_item.item_name,
      'quantity', p_quantity,
      'order_no', v_order_no
    )
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  -- A concurrent add of the same lot loses the race on the unique constraint.
  WHEN unique_violation THEN
    RETURN jsonb_build_object('success', false, 'message', 'Item already exists in order');
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error adding item: ' || SQLERRM);
END;
$$;
-- Dispatch delete: only live invoices count, the saved create answer goes with the dispatch (B1, B16)
CREATE OR REPLACE FUNCTION public.delete_dispatch_with_order_cleanup(p_dispatch_id uuid, p_user_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_user_profile_id UUID;
    v_dispatch_record dispatch%ROWTYPE;
    v_accessible_customers UUID[];
    v_linked_orders_count INTEGER;
    v_order_record RECORD;
    v_stock_updates jsonb := '[]'::jsonb;
    v_cart_restoration jsonb;
    v_item record;
    v_old_stock integer;
    v_new_stock integer;
    v_grn_items_restored INTEGER := 0;
    v_orders_updated INTEGER := 0;
    v_out_of_stock_reset INTEGER := 0;
    v_order_items_restored INTEGER := 0;
    v_order_items_recreated INTEGER := 0;
    v_debug_info jsonb := '[]'::jsonb;
    v_source_order_no TEXT;
    v_restored_items jsonb := '[]'::jsonb;
    v_cart_restoration_error TEXT := NULL;
    v_has_cart_items BOOLEAN := FALSE;
    v_invoice_count INTEGER := 0;  -- NEW: For invoice safeguard
    v_cart_line record;
    v_restore_cart_id uuid;
    v_cart_lines_not_restored integer := 0;
    v_cart_lines_no_open_cart integer := 0;
    v_cart_details jsonb := '[]'::jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('delete_dispatch_with_order_cleanup',jsonb_build_object('p_dispatch_id',p_dispatch_id));
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
    -- Get user profile ID
    SELECT id INTO v_user_profile_id
    FROM user_profiles
    WHERE auth_user_id = auth.uid();

    IF v_user_profile_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'User not found',
            'message', 'User not found'
        );
    END IF;

    -- Get dispatch details
    SELECT * INTO v_dispatch_record FROM dispatch WHERE id = p_dispatch_id;

    IF v_dispatch_record.id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Dispatch not found',
            'message', 'Dispatch not found'
        );
    END IF;

    -- Check access permissions
    IF NOT is_admin_or_supervisor_strict() THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only administrators and supervisors can delete dispatches',
            'message', 'Only administrators and supervisors can delete dispatches'
        );
    END IF;

    -- ⚠️ NEW: CRITICAL INVOICE SAFEGUARD
    -- Check if dispatch has any invoiced items. Only a live invoice counts, the rule get_dispatch_details
    -- shows (migration 120).
    SELECT COUNT(*) INTO v_invoice_count
    FROM invoice_trl it
    JOIN invoice inv ON inv.id = it.invoice_id AND inv.deleted_at IS NULL
    WHERE it.disp_trl_id IN (
        SELECT id FROM dispatch_trl WHERE disp_id = p_dispatch_id
    );

    IF v_invoice_count > 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('Cannot delete dispatch %s: %s invoice items exist',
                           v_dispatch_record.disp_no, v_invoice_count),
            'message', 'Delete invoices first before deleting this dispatch',
            'dispatch_no', v_dispatch_record.disp_no,
            'dispatch_id', p_dispatch_id,
            'invoice_items_count', v_invoice_count,
            'instructions', 'You must delete all related invoices before this dispatch can be deleted',
            'blocking_reason', 'invoices_exist'
        );
    END IF;
    -- END NEW SAFEGUARD

    -- Collect information about items being restored BEFORE deletion
    FOR v_item IN
        SELECT
            dt.disp_qty,
            gt.item_name,
            gt.package_mark,
            gr.gr_no
        FROM dispatch_trl dt
        JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        JOIN goodsreceived gr ON gr.id = gt.gr_id
        WHERE dt.disp_id = p_dispatch_id
    LOOP
        v_restored_items := v_restored_items || jsonb_build_object(
            'item_name', v_item.item_name,
            'package_mark', v_item.package_mark,
            'grn_no', v_item.gr_no,
            'quantity_restored', v_item.disp_qty
        );
    END LOOP;

    -- Get the source order number if we have a source order
    IF v_dispatch_record.source_order_id IS NOT NULL THEN
        -- Get order_no, or generate one if it's null/empty
        SELECT
            CASE
                WHEN order_no IS NULL OR order_no = '' THEN
                    'ORD-' || TO_CHAR(CURRENT_DATE, 'YYYYMMDD') || '-' || SUBSTRING(id::text FROM 1 FOR 8)
                ELSE
                    order_no
            END INTO v_source_order_no
        FROM orders
        WHERE id = v_dispatch_record.source_order_id;

        -- If we generated an order_no, update the order record
        UPDATE orders
        SET order_no = v_source_order_no
        WHERE id = v_dispatch_record.source_order_id
        AND (order_no IS NULL OR order_no = '');
    END IF;

    -- Cart quantities are given back below, from what each dispatch line
    -- recorded when it was saved (migration 67).

    -- Restore stock for each dispatch item
    FOR v_item IN
        SELECT
            dt.*,
            gt.item_name,
            gt.packaging,
            gt.weight,
            gt.gr_id
        FROM dispatch_trl dt
        LEFT JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
    LOOP
        -- Get current stock from goodsreceived_trl
        SELECT stock INTO v_old_stock
        FROM goodsreceived_trl
        WHERE id = v_item.gr_trl_id;

        v_new_stock := LEAST((SELECT qty FROM goodsreceived_trl WHERE id = v_item.gr_trl_id), COALESCE(v_old_stock, 0) + v_item.disp_qty);

        -- Update stock in goodsreceived_trl
        UPDATE goodsreceived_trl
        SET
            stock = v_new_stock
        WHERE id = v_item.gr_trl_id;

        -- The stock coming back is logged (migration 67).
        IF v_old_stock IS NOT NULL AND v_new_stock <> v_old_stock THEN
            INSERT INTO stock_movements (gr_trl_id, movement_type, quantity, reference_id, reference_type,
                                         balance_before, balance_after, created_by, notes)
            VALUES (v_item.gr_trl_id,
                    CASE WHEN v_new_stock > v_old_stock THEN 'return' ELSE 'adjustment' END,
                    v_new_stock - v_old_stock, p_dispatch_id, 'dispatch_delete',
                    v_old_stock, v_new_stock, v_user_profile_id, 'Dispatch deleted');
        END IF;

        v_grn_items_restored := v_grn_items_restored + 1;

        -- Record the update
        v_stock_updates := v_stock_updates || jsonb_build_object(
            'gr_trl_id', v_item.gr_trl_id,
            'gr_id', v_item.gr_id,
            'item_name', v_item.item_name,
            'packaging', v_item.packaging,
            'weight', v_item.weight,
            'quantity_restored', v_item.disp_qty,
            'old_stock', v_old_stock,
            'new_stock', v_new_stock
        );
    END LOOP;

    -- Reset out_of_stock flag for GRNs that now have stock
    WITH grn_stock_status AS (
        SELECT
            gr.id,
            gr.out_of_stock as current_status,
            COALESCE(SUM(grt.stock), 0) as total_stock
        FROM goodsreceived gr
        INNER JOIN goodsreceived_trl grt ON grt.gr_id = gr.id
        WHERE gr.id IN (
            SELECT DISTINCT gt.gr_id
            FROM dispatch_trl dt
            JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
            WHERE dt.disp_id = p_dispatch_id
        )
        GROUP BY gr.id, gr.out_of_stock
    )
    UPDATE goodsreceived
    SET out_of_stock = FALSE
    FROM grn_stock_status
    WHERE goodsreceived.id = grn_stock_status.id
    AND grn_stock_status.current_status = TRUE
    AND grn_stock_status.total_stock > 0;

    -- Get count of rows affected
    GET DIAGNOSTICS v_out_of_stock_reset = ROW_COUNT;

    -- Give back to the customer's cart what this dispatch took from it
    -- (migration 67). When a dispatch is saved, each line records the cart line
    -- it lowered (source_order_item_id) and by how much (cart_quantity_consumed).
    -- That quantity is added back to the cart's line for the lot, pending and
    -- with nothing fulfilled, or a pending line of that quantity is made again
    -- when the dispatch used the line up. The cart is the order the dispatch was
    -- made from; for a direct dispatch, the order of the recorded cart line, else
    -- the customer's OPEN cart (the rule the direct dispatch used to find it),
    -- else a new OPEN cart made as get_or_create_cart makes it. A customer has
    -- one order at most (one_cart_per_customer): when it exists but is not OPEN
    -- or is deleted, no cart can be made, the order is left as it is and the
    -- line is counted (cart_lines_without_open_cart).
    FOR v_cart_line IN
        SELECT
            dt.id,
            dt.gr_trl_id,
            dt.cart_quantity_consumed,
            dt.source_order_item_id,
            gt.item_name,
            gt.item_id,
            gt.package_mark,
            gt.packaging,
            gt.rack,
            gt.weight,
            gt.stock,
            gt.gr_id,
            gr.gr_no,
            gr.date as gr_date,
            gr.customer_id,
            gr.customer_name,
            gr.gr_image_url
        FROM dispatch_trl dt
        JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        JOIN goodsreceived gr ON gr.id = gt.gr_id
        WHERE dt.disp_id = p_dispatch_id
          AND COALESCE(dt.cart_quantity_consumed, 0) > 0
        ORDER BY uuid_extract_timestamp(dt.id), dt.id
    LOOP
        v_restore_cart_id := COALESCE(
            v_dispatch_record.source_order_id,
            (SELECT oi.order_id FROM order_items oi WHERE oi.id = v_cart_line.source_order_item_id),
            (SELECT o.id FROM orders o
             WHERE o.customer_id = v_dispatch_record.customer_id AND o.status = 'OPEN' AND o.deleted_at IS NULL
             ORDER BY o.created_at, o.id
             LIMIT 1));

        IF v_restore_cart_id IS NULL THEN
            -- No OPEN cart: make one, with get_or_create_cart's columns. The
            -- unique index lets this succeed only when the customer has no order.
            INSERT INTO orders (
                customer_id, customer_name, customer_email, customer_phone,
                order_date, requested_dispatch_date, status, priority,
                created_by, updated_by
            )
            SELECT c.id, c.name, c.email, c.mobile,
                   NOW(), NOW() + INTERVAL '7 days', 'OPEN', 'normal',
                   v_user_profile_id, v_user_profile_id
            FROM customers c
            WHERE c.id = v_dispatch_record.customer_id
            ON CONFLICT DO NOTHING
            RETURNING id INTO v_restore_cart_id;
        END IF;

        IF v_restore_cart_id IS NULL THEN
            v_cart_lines_no_open_cart := v_cart_lines_no_open_cart + 1;
            CONTINUE;
        END IF;

        UPDATE order_items
        SET
            requested_quantity = requested_quantity + v_cart_line.cart_quantity_consumed,
            fulfilled_quantity = 0,
            item_status = 'pending',
            current_stock = v_cart_line.stock,
            updated_at = now()
        WHERE order_id = v_restore_cart_id
          AND grn_items_id = v_cart_line.gr_trl_id;

        IF FOUND THEN
            v_order_items_restored := v_order_items_restored + 1;
        ELSE
            INSERT INTO order_items (
                order_id, order_no, requested_quantity, fulfilled_quantity,
                grn_items_id, grn_items_item_id, grn_items_item_name,
                grn_items_package_mark, grn_items_packaging, grn_items_rack,
                grn_items_weight, grn_items_image_url,
                grns_id, grns_gr_no, grns_date, grns_customer_id, grns_customer_name,
                available_stock_at_order, current_stock, item_status, sort_order
            ) VALUES (
                v_restore_cart_id,
                (SELECT o.order_no FROM orders o WHERE o.id = v_restore_cart_id),
                v_cart_line.cart_quantity_consumed,
                0,
                v_cart_line.gr_trl_id,
                v_cart_line.item_id,
                v_cart_line.item_name,
                COALESCE(v_cart_line.package_mark, ''),
                COALESCE(v_cart_line.packaging, ''),
                COALESCE(v_cart_line.rack, ''),
                COALESCE(v_cart_line.weight, 0),
                v_cart_line.gr_image_url,
                v_cart_line.gr_id,
                v_cart_line.gr_no,
                v_cart_line.gr_date,
                v_cart_line.customer_id,
                COALESCE(v_cart_line.customer_name, v_dispatch_record.customer_name, ''),
                v_cart_line.stock,
                v_cart_line.stock,
                'pending',
                COALESCE((SELECT max(oi.sort_order) + 1 FROM order_items oi WHERE oi.order_id = v_restore_cart_id), 1)
            );

            v_order_items_recreated := v_order_items_recreated + 1;
        END IF;

        v_cart_details := v_cart_details || jsonb_build_object(
            'order_id', v_restore_cart_id,
            'gr_trl_id', v_cart_line.gr_trl_id,
            'item_name', v_cart_line.item_name,
            'quantity_restored', v_cart_line.cart_quantity_consumed
        );
    END LOOP;

    -- A line of a dispatch from the cart saved before migration 67 has no record
    -- of what it took from the cart: nothing is given back for it, and the
    -- answer says how many such lines there were.
    IF v_dispatch_record.source_order_id IS NOT NULL THEN
        v_cart_lines_not_restored := v_cart_lines_not_restored + (
            SELECT count(*)::integer FROM dispatch_trl
            WHERE disp_id = p_dispatch_id AND source_type IS DISTINCT FROM 'cart'
        );
    END IF;

    v_has_cart_items := jsonb_array_length(v_cart_details) > 0;
    v_cart_restoration := jsonb_build_object(
        'success', true,
        'message', CASE WHEN v_has_cart_items THEN 'Cart quantities restored'
                        ELSE 'No cart quantities to restore' END,
        'updates_made', v_order_items_restored + v_order_items_recreated,
        'restoration_details', v_cart_details,
        'lines_not_restored', v_cart_lines_not_restored,
        'lines_without_open_cart', v_cart_lines_no_open_cart
    );

    -- Check if there are linked orders - now just check source_order_id
    v_linked_orders_count := 0;
    IF v_dispatch_record.source_order_id IS NOT NULL THEN
        v_linked_orders_count := 1;

        -- Cart lines were given back above (migration 67).

        -- Add dispatch deletion to orders.revisions
        INSERT INTO public.order_revisions (order_id, changed_at, changed_by, action, entry)
        SELECT id, clock_timestamp(), v_user_profile_id, 'dispatch_deleted', (
                jsonb_build_object(
                    'action', 'dispatch_deleted',
                    'timestamp', NOW(),
                    'by', v_user_profile_id,
                    'dispatch_id', v_dispatch_record.id,
                    'dispatch_no', v_dispatch_record.disp_no,
                    'restored_items', v_restored_items,
                    'total_quantity_restored', (
                        SELECT COALESCE(SUM(disp_qty), 0)
                        FROM dispatch_trl
                        WHERE disp_id = p_dispatch_id
                    ),
                    'cart_restoration_status', CASE
                        WHEN v_cart_restoration_error IS NOT NULL THEN 'failed'
                        WHEN NOT v_has_cart_items THEN 'not_applicable'
                        ELSE 'success'
                    END
                )
            )
        FROM public.orders WHERE id = v_dispatch_record.source_order_id;

        -- Update order status to OPEN and clear soft-delete
        UPDATE orders
        SET
            status = 'OPEN',
            deleted_at = NULL,
            deleted_by = NULL,
            updated_by = v_user_profile_id,
            updated_at = now()
        WHERE id = v_dispatch_record.source_order_id;

        v_orders_updated := 1;
    END IF;

    -- The lines of a cancelled invoice, which the guard above does not count, are kept with their amounts:
    -- their foreign key to the dispatch line empties the link (ON DELETE SET NULL, migration 120).
    -- Delete dispatch items
    DELETE FROM dispatch_trl WHERE disp_id = p_dispatch_id;

    -- Delete dispatch
    DELETE FROM dispatch WHERE id = p_dispatch_id;

    -- A saved create answer that points at this dispatch is not replayed any more: entering the same
    -- dispatch again creates it (migration 120).
    DELETE FROM idempotency_keys
    WHERE rpc_function = 'create_dispatch_with_stock_check'
      AND response->>'dispatch_id' = p_dispatch_id::text;

    -- Return comprehensive result
    RETURN jsonb_build_object(
        'success', true,
        'message', format('Dispatch %s deleted successfully. %s linked order(s) reset, %s order items restored/recreated, %s GRN items restored, %s out_of_stock flags reset.',
                         v_dispatch_record.disp_no,
                         v_linked_orders_count,
                         v_order_items_restored + v_order_items_recreated,
                         v_grn_items_restored,
                         v_out_of_stock_reset)
            || CASE WHEN v_cart_lines_not_restored > 0
                    THEN format(' %s cart line(s) were saved before cart quantities were recorded; their quantities were not returned to the order.',
                                v_cart_lines_not_restored)
                    ELSE '' END
            || CASE WHEN v_cart_lines_no_open_cart > 0
                    THEN format(' %s cart line(s) were not returned: the customer has no open cart and one could not be made.',
                                v_cart_lines_no_open_cart)
                    ELSE '' END,
        'dispatch_id', p_dispatch_id,
        'dispatch_no', v_dispatch_record.disp_no,
        'customer_id', v_dispatch_record.customer_id,
        'customer_name', v_dispatch_record.customer_name,
        'stock_updates', v_stock_updates,
        'cart_restoration', v_cart_restoration,
        'cart_lines_not_restored', v_cart_lines_not_restored,
        'cart_lines_without_open_cart', v_cart_lines_no_open_cart,
        'order_restoration', jsonb_build_object(
            'items_updated', v_order_items_restored,
            'items_recreated', v_order_items_recreated,
            'cart_items_restored', COALESCE((v_cart_restoration->>'updates_made')::integer, 0),
            'total_items_restored', v_order_items_restored + v_order_items_recreated
        ),
        'statistics', jsonb_build_object(
            'orders_updated', v_orders_updated,
            'grn_items_restored', v_grn_items_restored,
            'out_of_stock_flags_reset', v_out_of_stock_reset,
            'linked_orders_count', v_linked_orders_count,
            'order_items_restored', v_order_items_restored + v_order_items_recreated,
            'dispatch_had_cart_items', v_has_cart_items
        ),
        'timestamp', CURRENT_TIMESTAMP,
        'deleted_by', v_user_profile_id
    );

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM,
            'message', 'Database error occurred',
            'dispatch_id', p_dispatch_id,
            'debug_info', v_debug_info
        );
END;
$$;
-- Dispatch create: B1, B9, B12, A14, A7, M4, N3
CREATE OR REPLACE FUNCTION public.create_dispatch_with_stock_check_internal(p_dispatch_data jsonb, p_dispatch_items jsonb[], p_generate_invoice boolean DEFAULT false, p_idempotency_key text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_dispatch_id uuid;
    v_user_id uuid;
    v_affected_gr_ids uuid[];
    v_all_gr_ids uuid[];
    v_insufficient_stock text;
    v_foreign_lots text;
    v_dispatch_items_result jsonb[];
    v_invoice_data jsonb;
    v_gr_id uuid;
    v_grn_customer_id uuid;
    v_is_invoiceable boolean;
    v_single_invoice_data jsonb;
    v_source_order_id uuid;
    v_source_order_no text;  -- Added for auto-lookup
    v_item jsonb;
    v_gr_trl_id uuid;
    v_dispatched_qty integer;
    v_cart_id uuid;
    v_cart_item_id uuid;
    v_cart_current_qty integer;
    v_cart_fulfilled_qty integer;
    v_cart_new_qty integer;
    v_cached_response jsonb;
    v_order_customer_id uuid;
    v_locked_lots integer;
    v_deleted_lots text;
    v_customer_name text;
    v_supervisor_name text;
    v_order_lines_left integer;
BEGIN
    -- The document lock comes before the idempotency lookup, as in save_grn (migration 87):
    -- an overlapping retry waits here and then finds the first call's cached answer.
    PERFORM pg_advisory_xact_lock(71040);

    -- Check idempotency key first
    IF p_idempotency_key IS NOT NULL THEN
        SELECT response INTO v_cached_response
        FROM idempotency_keys
        WHERE idempotency_key = p_idempotency_key
          AND rpc_function = 'create_dispatch_with_stock_check'
          AND created_by = (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid())
          AND expires_at > NOW();

        -- The answer is replayed only while the dispatch it created still exists. The answer of a deleted
        -- dispatch is dropped (migration 120) and the call goes on as a new create: the same body can be
        -- entered again once its number is free again.
        IF v_cached_response IS NOT NULL THEN
            IF EXISTS (
                SELECT 1 FROM dispatch d
                WHERE d.id = (v_cached_response->>'dispatch_id')::uuid AND d.deleted_at IS NULL
            ) THEN
                RETURN v_cached_response || jsonb_build_object('from_cache', true);
            END IF;
            DELETE FROM idempotency_keys
            WHERE idempotency_key = p_idempotency_key
              AND rpc_function = 'create_dispatch_with_stock_check'
              AND created_by = (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid());
            v_cached_response := NULL;
        END IF;
    END IF;

    -- Check if user is admin or supervisor
    IF NOT warehouse_security.active_role() IN ('admin','supervisor','staff') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only administrators and supervisors can create dispatches'
        );
    END IF;

    -- Get current user
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();

    -- Extract source_order_id if provided
    v_source_order_id := (p_dispatch_data->>'source_order_id')::uuid;

    -- Auto-lookup source_order_no from orders table if not provided
    IF v_source_order_id IS NOT NULL THEN
        -- The cart must be the dispatch customer's (a plain read: the cart writers lock the cart first).
        SELECT customer_id INTO v_order_customer_id
        FROM orders
        WHERE id = v_source_order_id AND deleted_at IS NULL;
        IF v_order_customer_id IS NULL
           OR v_order_customer_id IS DISTINCT FROM (p_dispatch_data->>'customer_id')::uuid THEN
            RAISE EXCEPTION 'The order belongs to another customer' USING ERRCODE = 'WH409';
        END IF;

        -- The order number is the order's own, never the client's (migration 120); a dispatch without a source
        -- order has none.
        v_source_order_no := (SELECT order_no FROM orders WHERE id = v_source_order_id);
    ELSE
        v_source_order_no := NULL;
    END IF;

    -- A lot appears once in the dispatch lines (migration 87).
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS d
        GROUP BY (d->>'gr_trl_id')::uuid HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'The same lot appears twice in the dispatch lines' USING ERRCODE = 'WH409';
    END IF;

    -- A number another dispatch holds is refused by name, under the lock and before anything is written
    -- (migration 120). dispatch_disp_no_key covers every row, so the check does too.
    IF EXISTS (SELECT 1 FROM dispatch d WHERE d.disp_no = p_dispatch_data->>'disp_no') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'WH409',
            'reason', 'NUMBER_TAKEN',
            'number', p_dispatch_data->>'disp_no',
            'error', format('Dispatch number %s is already used', p_dispatch_data->>'disp_no')
        );
    END IF;

    -- The stored names are the master tables' names, whatever the client sent, and the supervisor is a
    -- person who may supervise (migration 120).
    IF p_dispatch_data->>'supervisor_id' IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM user_profiles p
        WHERE p.id = (p_dispatch_data->>'supervisor_id')::uuid
          AND p.role IN ('admin', 'supervisor', 'staff')
    ) THEN
        RAISE EXCEPTION 'The supervisor must be an administrator, supervisor or staff member' USING ERRCODE = 'WH409';
    END IF;
    v_customer_name := (SELECT c.name FROM customers c WHERE c.id = (p_dispatch_data->>'customer_id')::uuid);
    v_supervisor_name := (SELECT COALESCE(p.name, p.display_name) FROM user_profiles p WHERE p.id = (p_dispatch_data->>'supervisor_id')::uuid);

    -- STEP 1: Lock all relevant GRN items first (no aggregation)
    SELECT count(*) INTO v_locked_lots
    FROM (
        SELECT gt.id
        FROM unnest(p_dispatch_items) AS item
        JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
        FOR UPDATE OF gt
    ) AS locked;

    -- A lot that was deleted after the wrapper checked the list is refused, not dropped (migration 120).
    -- A lot appears once (checked above), so the lines sent are the distinct lots sent.
    IF v_locked_lots <> cardinality(p_dispatch_items) THEN
        RAISE EXCEPTION 'A lot of this dispatch was removed meanwhile; reload and try again' USING ERRCODE = 'WH409';
    END IF;

    -- A dispatch carries only its own customer's lots. The receipts are
    -- key-share locked so update_grn cannot move one to another customer meanwhile.
    PERFORM gr.id
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    FOR KEY SHARE OF gr;

    SELECT string_agg(gt.item_name || ' (' || gr.gr_no || ')', ', ')
    INTO v_foreign_lots
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    WHERE gr.customer_id IS DISTINCT FROM (p_dispatch_data->>'customer_id')::uuid;

    IF v_foreign_lots IS NOT NULL THEN
        RAISE EXCEPTION 'Item belongs to another customer: %', v_foreign_lots USING ERRCODE = 'WH409';
    END IF;

    -- The lots of a deleted receipt are not dispatched (migration 120).
    SELECT string_agg(gt.item_name || ' (' || gr.gr_no || ')', ', ')
    INTO v_deleted_lots
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    WHERE gr.deleted_at IS NOT NULL;

    IF v_deleted_lots IS NOT NULL THEN
        RAISE EXCEPTION 'Item belongs to a deleted GRN: %', v_deleted_lots USING ERRCODE = 'WH409';
    END IF;

    -- STEP 2: Check stock availability (separate query, no FOR UPDATE)
    SELECT string_agg(
        gt.item_name || ' (Available: ' || gt.stock || ', Requested: ' || (item->>'disp_qty')::integer || ')',
        ', '
    )
    INTO v_insufficient_stock
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    WHERE gt.stock < (item->>'disp_qty')::integer;

    IF v_insufficient_stock IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Insufficient stock: ' || v_insufficient_stock
        );
    END IF;

    -- CREATE DISPATCH RECORD
    INSERT INTO dispatch (
        disp_no, disp_date, registration, customer_id,
        customer_name, supervisor_id, supervisor_name, note,
        created_by, source_order_id, source_order_no
    ) VALUES (
        p_dispatch_data->>'disp_no',
        (p_dispatch_data->>'disp_date')::date::timestamptz,
        p_dispatch_data->>'registration',
        (p_dispatch_data->>'customer_id')::uuid,
        v_customer_name,
        (p_dispatch_data->>'supervisor_id')::uuid,
        v_supervisor_name,
        p_dispatch_data->>'note',
        v_user_id,
        v_source_order_id,
        v_source_order_no  -- Now uses auto-looked-up value
    ) RETURNING id INTO v_dispatch_id;

    -- BULK UPDATE STOCK
    UPDATE goodsreceived_trl gt
    SET stock = gt.stock - (item->>'disp_qty')::integer
    FROM unnest(p_dispatch_items) AS item
    WHERE gt.id = (item->>'gr_trl_id')::uuid;

    -- BULK INSERT DISPATCH ITEMS
    INSERT INTO dispatch_trl (gr_id, gr_trl_id, disp_id, disp_qty)
    SELECT
        gt.gr_id,
        (item->>'gr_trl_id')::uuid,
        v_dispatch_id,
        (item->>'disp_qty')::integer
    FROM unnest(p_dispatch_items) WITH ORDINALITY AS t(item, ord)
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    ORDER BY t.ord;

    -- GET UNIQUE GR_IDS
    SELECT ARRAY(
        SELECT DISTINCT gt.gr_id
        FROM unnest(p_dispatch_items) AS item
        JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
    ) INTO v_affected_gr_ids;

    -- BULK INSERT STOCK MOVEMENTS
    INSERT INTO stock_movements (
        gr_trl_id, movement_type, quantity,
        reference_id, reference_type,
        balance_before, balance_after, created_by
    )
    SELECT
        (item->>'gr_trl_id')::uuid,
        'dispatch',
        -(item->>'disp_qty')::integer,
        v_dispatch_id,
        'dispatch',
        gt.stock + (item->>'disp_qty')::integer,
        gt.stock,
        v_user_id
    FROM unnest(p_dispatch_items) AS item
    JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid;

    -- BULK UPDATE OUT_OF_STOCK STATUS
    UPDATE goodsreceived gr
    SET out_of_stock = NOT EXISTS (
        SELECT 1 FROM goodsreceived_trl grt
        WHERE grt.gr_id = gr.id AND grt.stock > 0
    )
    WHERE gr.id = ANY(v_affected_gr_ids);

    -- BUILD DISPATCH ITEMS RESPONSE
    SELECT ARRAY(
        SELECT jsonb_build_object(
            'id', dt.id,
            'gr_id', dt.gr_id,
            'gr_trl_id', dt.gr_trl_id,
            'disp_id', dt.disp_id,
            'disp_qty', dt.disp_qty,
            'item_name', COALESCE(i.name, grt.item_name),
            'packaging', grt.packaging,
            'rack', grt.rack,
            'package_mark', grt.package_mark,
            'weight', grt.weight,
            'remaining_stock', grt.stock
        )
        FROM dispatch_trl dt
        JOIN goodsreceived_trl grt ON grt.id = dt.gr_trl_id
        LEFT JOIN items i ON i.id = grt.item_id
        WHERE dt.disp_id = v_dispatch_id
    ) INTO v_dispatch_items_result;

    -- INVOICE GENERATION (if requested)
    IF p_generate_invoice THEN
        v_invoice_data := '{}'::jsonb;
        v_all_gr_ids := v_affected_gr_ids;

        FOREACH v_gr_id IN ARRAY v_all_gr_ids
        LOOP
            SELECT gr.customer_id, c.auto_invoice_generation
            INTO v_grn_customer_id, v_is_invoiceable
            FROM goodsreceived gr
            JOIN customers c ON c.id = gr.customer_id
            WHERE gr.id = v_gr_id;

            IF v_is_invoiceable THEN
                v_single_invoice_data := generate_invoice_data_for_grn_with_pricing(v_gr_id);
                IF (v_single_invoice_data->>'success')::boolean = true THEN
                    v_invoice_data := v_invoice_data || jsonb_build_object(v_gr_id::text, v_single_invoice_data);
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- ORDER/CART HANDLING (PERSISTENT CART MODEL)
    IF v_source_order_id IS NOT NULL THEN
        -- FROM ORDER dispatch: Delete or reduce cart items, keep order OPEN
        FOREACH v_item IN ARRAY p_dispatch_items
        LOOP
            v_gr_trl_id := (v_item->>'gr_trl_id')::uuid;
            v_dispatched_qty := (v_item->>'disp_qty')::integer;

            SELECT id, requested_quantity
            INTO v_cart_item_id, v_cart_current_qty
            FROM order_items
            WHERE order_id = v_source_order_id AND grn_items_id = v_gr_trl_id
            LIMIT 1
            FOR UPDATE;

            -- Record on the dispatch line what it takes from the cart line (migration 67).
            UPDATE dispatch_trl
            SET source_type = 'cart',
                source_order_item_id = v_cart_item_id,
                cart_quantity_consumed = CASE WHEN v_cart_item_id IS NULL THEN 0
                                              ELSE LEAST(v_cart_current_qty, v_dispatched_qty) END
            WHERE disp_id = v_dispatch_id AND gr_trl_id = v_gr_trl_id;

            IF v_cart_item_id IS NOT NULL THEN
                v_cart_new_qty := GREATEST(0, v_cart_current_qty - v_dispatched_qty);
                IF v_cart_new_qty = 0 THEN
                    DELETE FROM order_items WHERE id = v_cart_item_id;
                ELSE
                    UPDATE order_items
                    SET requested_quantity = v_cart_new_qty,
                        fulfilled_quantity = 0,
                        item_status = 'pending',
                        updated_at = NOW()
                    WHERE id = v_cart_item_id;
                END IF;
            END IF;
        END LOOP;

        UPDATE orders
        SET status = 'OPEN',
            updated_at = NOW(),
            updated_by = v_user_id
        WHERE id = v_source_order_id;
    ELSE
        -- DIRECT DISPATCH: Reduce cart quantities
        FOREACH v_item IN ARRAY p_dispatch_items
        LOOP
            v_gr_trl_id := (v_item->>'gr_trl_id')::uuid;
            v_dispatched_qty := (v_item->>'disp_qty')::integer;

            SELECT gr.customer_id INTO v_grn_customer_id
            FROM goodsreceived_trl grt
            JOIN goodsreceived gr ON gr.id = grt.gr_id
            WHERE grt.id = v_gr_trl_id;

            IF v_grn_customer_id IS NOT NULL THEN
                SELECT id INTO v_cart_id
                FROM orders
                WHERE customer_id = v_grn_customer_id AND status = 'OPEN' AND deleted_at IS NULL
                ORDER BY created_at, id
                LIMIT 1;

                IF v_cart_id IS NOT NULL THEN
                    SELECT id, requested_quantity, fulfilled_quantity
                    INTO v_cart_item_id, v_cart_current_qty, v_cart_fulfilled_qty
                    FROM order_items
                    WHERE order_id = v_cart_id AND grn_items_id = v_gr_trl_id
                    LIMIT 1
                    FOR UPDATE;

                    -- Record on the dispatch line what it takes from the cart line (migration 67).
                    UPDATE dispatch_trl
                    SET source_order_item_id = v_cart_item_id,
                        cart_quantity_consumed = CASE WHEN v_cart_item_id IS NULL THEN 0
                                                      ELSE LEAST(v_cart_current_qty, v_dispatched_qty) END
                    WHERE disp_id = v_dispatch_id AND gr_trl_id = v_gr_trl_id;

                    IF v_cart_item_id IS NOT NULL THEN
                        v_cart_new_qty := GREATEST(0, v_cart_current_qty - v_dispatched_qty);
                        IF v_cart_new_qty = 0 THEN
                            DELETE FROM order_items WHERE id = v_cart_item_id;
                        ELSE
                            UPDATE order_items
                            SET requested_quantity = v_cart_new_qty,
                                fulfilled_quantity = GREATEST(0, COALESCE(v_cart_fulfilled_qty, 0) - v_dispatched_qty)
                            WHERE id = v_cart_item_id;
                        END IF;
                    END IF;
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- The lines of the source order still open after this dispatch (migration 120): the pending ones, the rule of
    -- the order queue (v_orders_list counts total_items the same way); NULL for a dispatch that has no source order.
    IF v_source_order_id IS NOT NULL THEN
        SELECT count(*)::integer INTO v_order_lines_left
        FROM order_items
        WHERE order_id = v_source_order_id
          AND item_status = 'pending';
    END IF;

    -- Build result
    v_cached_response := jsonb_build_object(
        'success', true,
        'dispatch_id', v_dispatch_id,
        'dispatch_items', to_jsonb(v_dispatch_items_result),
        'invoice_data', COALESCE(v_invoice_data, '{}'::jsonb),
        'message', 'Dispatch created successfully',
        'source_order_cleared', v_source_order_id IS NOT NULL,
        'order_lines_left', v_order_lines_left
    );

    -- Cache the response if idempotency key provided
    IF p_idempotency_key IS NOT NULL THEN
        -- Kept for the 24 hours a retry is answered from it. A key another
        -- function or user holds is left alone unless it has expired.
        INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
        VALUES (p_idempotency_key, 'create_dispatch_with_stock_check', v_cached_response, v_user_id, NOW() + INTERVAL '24 hours')
        ON CONFLICT (idempotency_key) DO UPDATE SET
            rpc_function = EXCLUDED.rpc_function,
            response = EXCLUDED.response,
            created_by = EXCLUDED.created_by,
            created_at = NOW(),
            expires_at = EXCLUDED.expires_at
        WHERE idempotency_keys.expires_at <= NOW()
           OR (idempotency_keys.rpc_function = EXCLUDED.rpc_function
               AND idempotency_keys.created_by IS NOT DISTINCT FROM EXCLUDED.created_by);
    END IF;

    RETURN v_cached_response;

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM,
            'error_code', SQLSTATE
        );
END;
$$;
-- Dispatch edit: A16, B3, B13, B15, B16, B12, A14, M4, N3
CREATE OR REPLACE FUNCTION public.update_dispatch_smart(p_dispatch_id uuid, p_dispatch_data jsonb, p_dispatch_items jsonb[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_user_id uuid;
    v_invoiced_items text;
    v_insufficient_stock text;
    v_foreign_lots text;
    v_affected_gr_ids uuid[];
    v_dispatch_items_result jsonb[];
    v_locked_dispatch uuid;
    v_deleted_lots text;
    v_request_key text;
    v_cached_response jsonb;
    v_result jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_dispatch_smart',jsonb_build_object('p_dispatch_id',p_dispatch_id));
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);

    -- A request code (migration 120, owner decision D22): when the request carries one, this user's saved answer for
    -- it is returned as it was, before any other check, while the dispatch it saved still exists. A resend of a
    -- save whose answer was lost is therefore never refused for what its own first try changed, and
    -- get_submission_result gives the same answer.
    v_request_key := NULLIF(p_dispatch_data->>'request_key', '');
    IF v_request_key IS NOT NULL THEN
        SELECT k.response INTO v_cached_response
        FROM idempotency_keys k
        WHERE k.idempotency_key = v_request_key
          AND k.rpc_function = 'update_dispatch_smart'
          AND k.created_by = (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid())
          AND k.response->>'dispatch_id' = p_dispatch_id::text
          AND k.expires_at > now();

        IF v_cached_response IS NOT NULL
           AND EXISTS (SELECT 1 FROM dispatch r WHERE r.id = p_dispatch_id AND r.deleted_at IS NULL) THEN
            RETURN v_cached_response;
        END IF;
    END IF;

  PERFORM warehouse_security.require_person_supervisor(p_dispatch_data->>'supervisor_id',
    (SELECT supervisor_id FROM dispatch WHERE id = p_dispatch_id));
    -- Check if user is admin or supervisor
    IF NOT warehouse_security.active_role() IN ('admin','supervisor','staff') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Only administrators and supervisors can update dispatches'
        );
    END IF;

    -- Get current user
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();

    -- The dispatch row is locked, and a dispatch that is not there (deleted meanwhile) is not saved to
    -- (migration 120). Before this every sent line counted as new, the stock was taken, and the insert of
    -- the lines then failed on the foreign key.
    SELECT d.id INTO v_locked_dispatch
    FROM dispatch d
    WHERE d.id = p_dispatch_id AND d.deleted_at IS NULL
    FOR UPDATE;

    IF v_locked_dispatch IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Dispatch not found');
    END IF;

    IF p_dispatch_data->>'disp_no' IS NOT NULL AND warehouse_security.is_blank_text(p_dispatch_data->>'disp_no') THEN
        RAISE EXCEPTION 'disp_no is required' USING ERRCODE = 'WH409';
    END IF;

    -- A list that is sent is never empty: an edit cannot leave a dispatch without lines (migration 120).
    IF p_dispatch_items IS NOT NULL AND cardinality(p_dispatch_items) = 0 THEN
        RAISE EXCEPTION 'A dispatch needs at least one line' USING ERRCODE = 'WH409';
    END IF;

    -- A number another dispatch holds is refused by name, under the lock and before anything is written
    -- (migration 120). dispatch_disp_no_key covers every row, so the check does too.
    IF p_dispatch_data->>'disp_no' IS NOT NULL AND EXISTS (
        SELECT 1 FROM dispatch d
        WHERE d.disp_no = p_dispatch_data->>'disp_no' AND d.id <> p_dispatch_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'WH409',
            'reason', 'NUMBER_TAKEN',
            'number', p_dispatch_data->>'disp_no',
            'error', format('Dispatch number %s is already used', p_dispatch_data->>'disp_no')
        );
    END IF;

    -- Every line names a lot that exists and a whole quantity above zero.
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS new_item
        WHERE NOT EXISTS (
            SELECT 1 FROM goodsreceived_trl gt WHERE gt.id = (new_item->>'gr_trl_id')::uuid
        )
    ) THEN
        RAISE EXCEPTION 'Dispatch item does not exist in inventory' USING ERRCODE = 'WH409';
    END IF;
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS new_item
        WHERE new_item->>'disp_qty' IS NULL
           OR (new_item->>'disp_qty')::numeric <= 0
           OR (new_item->>'disp_qty')::numeric <> floor((new_item->>'disp_qty')::numeric)
    ) THEN
        RAISE EXCEPTION 'Dispatch quantity must be a whole number greater than 0' USING ERRCODE = 'WH409';
    END IF;

    -- A lot appears once in the dispatch lines (migration 87).
    IF EXISTS (
        SELECT 1 FROM unnest(p_dispatch_items) AS d
        GROUP BY (d->>'gr_trl_id')::uuid HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'The same lot appears twice in the dispatch lines' USING ERRCODE = 'WH409';
    END IF;

    -- A dispatch carries only its own customer's lots: a line this edit adds
    -- must belong to the dispatch customer, and the customer may change only
    -- when every line the edit leaves belongs to the new one. The receipts are
    -- key-share locked so update_grn cannot move one to another customer meanwhile.
    PERFORM gr.id
    FROM goodsreceived gr
    WHERE gr.id IN (
        SELECT gt.gr_id
        FROM unnest(p_dispatch_items) AS new_item
        JOIN goodsreceived_trl gt ON gt.id = (new_item->>'gr_trl_id')::uuid
        UNION
        SELECT dt.gr_id FROM dispatch_trl dt WHERE dt.disp_id = p_dispatch_id
    )
    FOR KEY SHARE OF gr;

    SELECT string_agg(gt.item_name || ' (' || gr.gr_no || ')', ', ')
    INTO v_foreign_lots
    FROM dispatch d
    JOIN LATERAL (
        -- Lines the edit leaves: the new list, or the present lines when no list is sent
        SELECT (new_item->>'gr_trl_id')::uuid AS gr_trl_id
        FROM unnest(p_dispatch_items) AS new_item
        UNION
        SELECT dt.gr_trl_id FROM dispatch_trl dt
        WHERE dt.disp_id = d.id AND p_dispatch_items IS NULL
    ) AS kept ON true
    JOIN goodsreceived_trl gt ON gt.id = kept.gr_trl_id
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    WHERE d.id = p_dispatch_id
    AND gr.customer_id IS DISTINCT FROM COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id)
    AND (
        -- The header customer is changing
        d.customer_id IS DISTINCT FROM COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id)
        OR
        -- The line is being added
        NOT EXISTS (
            SELECT 1 FROM dispatch_trl dt
            WHERE dt.disp_id = d.id AND dt.gr_trl_id = kept.gr_trl_id
        )
    );

    IF v_foreign_lots IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM dispatch d
            WHERE d.id = p_dispatch_id
            AND d.customer_id IS DISTINCT FROM COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id)
        ) THEN
            RAISE EXCEPTION 'Cannot change the dispatch customer: items belong to another customer: %', v_foreign_lots USING ERRCODE = 'WH409';
        END IF;
        RAISE EXCEPTION 'Item belongs to another customer: %', v_foreign_lots USING ERRCODE = 'WH409';
    END IF;

    -- A dispatch made from a cart stays with the cart's customer (migration 87).
    IF EXISTS (
        SELECT 1 FROM dispatch d
        WHERE d.id = p_dispatch_id
        AND d.source_order_id IS NOT NULL
        AND COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id) IS DISTINCT FROM d.customer_id
        AND COALESCE((p_dispatch_data->>'customer_id')::uuid, d.customer_id)
            IS DISTINCT FROM (SELECT o.customer_id FROM orders o WHERE o.id = d.source_order_id)
    ) THEN
        RAISE EXCEPTION 'The order belongs to another customer' USING ERRCODE = 'WH409';
    END IF;

    -- A supervisor that is changed to another person must be someone who may supervise; one that stays
    -- is not asked again (migration 120).
    IF p_dispatch_data->>'supervisor_id' IS NOT NULL
       AND (p_dispatch_data->>'supervisor_id')::uuid IS DISTINCT FROM (SELECT d.supervisor_id FROM dispatch d WHERE d.id = p_dispatch_id)
       AND NOT EXISTS (
           SELECT 1 FROM user_profiles p
           WHERE p.id = (p_dispatch_data->>'supervisor_id')::uuid
             AND p.role IN ('admin', 'supervisor', 'staff')
       ) THEN
        RAISE EXCEPTION 'The supervisor must be an administrator, supervisor or staff member' USING ERRCODE = 'WH409';
    END IF;

    -- Update dispatch header if data provided (single statement - OK)
    IF p_dispatch_data IS NOT NULL THEN
        UPDATE dispatch SET
            disp_no = COALESCE(p_dispatch_data->>'disp_no', disp_no),
            disp_date = COALESCE((p_dispatch_data->>'disp_date')::date::timestamptz, disp_date),
            registration = COALESCE(p_dispatch_data->>'registration', registration),
            customer_id = COALESCE((p_dispatch_data->>'customer_id')::uuid, customer_id),
            -- The stored names stay unless the customer or the supervisor changes; then they are the master
            -- tables' names, never the client's and never the old person's (migration 120). The old values are
            -- read here.
            customer_name = CASE
                WHEN p_dispatch_data->>'customer_id' IS NOT NULL
                     AND (p_dispatch_data->>'customer_id')::uuid IS DISTINCT FROM customer_id
                THEN COALESCE((SELECT c.name FROM customers c WHERE c.id = (p_dispatch_data->>'customer_id')::uuid), customer_name)
                ELSE customer_name
            END,
            supervisor_id = COALESCE((p_dispatch_data->>'supervisor_id')::uuid, supervisor_id),
            supervisor_name = CASE
                WHEN p_dispatch_data->>'supervisor_id' IS NOT NULL
                     AND (p_dispatch_data->>'supervisor_id')::uuid IS DISTINCT FROM supervisor_id
                THEN (SELECT COALESCE(p.name, p.display_name) FROM user_profiles p WHERE p.id = (p_dispatch_data->>'supervisor_id')::uuid)
                ELSE supervisor_name
            END,
            note = COALESCE(p_dispatch_data->>'note', note),
            updated_by = v_user_id,
            updated_at = NOW()
        WHERE id = p_dispatch_id;
    END IF;

    -- Handle items if provided
    IF p_dispatch_items IS NOT NULL THEN
        -- ========== STEP 1: VALIDATION - Check invoiced items ==========
        -- Check if any items being modified or deleted are invoiced
        SELECT string_agg(gt.item_name, ', ')
        INTO v_invoiced_items
        FROM dispatch_trl dt
        JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
        AND EXISTS (
            -- Only a live invoice counts, the rule get_dispatch_details shows (migration 120).
            SELECT 1 FROM invoice_trl it
            JOIN invoice inv ON inv.id = it.invoice_id AND inv.deleted_at IS NULL
            WHERE it.disp_trl_id = dt.id
        )
        AND (
            -- Item is being deleted (not in new list)
            NOT EXISTS (
                SELECT 1 FROM unnest(p_dispatch_items) AS new_item
                WHERE (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
            )
            OR
            -- Item qty is being changed
            EXISTS (
                SELECT 1 FROM unnest(p_dispatch_items) AS new_item
                WHERE (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
                AND (new_item->>'disp_qty')::integer != dt.disp_qty
            )
        );

        IF v_invoiced_items IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot modify invoiced items: %', v_invoiced_items USING ERRCODE = 'WH409';
        END IF;

        -- ========== STEP 2: LOCK all affected GRN items ==========
        PERFORM gt.id
        FROM goodsreceived_trl gt
        WHERE gt.id IN (
            -- Existing items in dispatch
            SELECT dt.gr_trl_id FROM dispatch_trl dt WHERE dt.disp_id = p_dispatch_id
            UNION
            -- New items being added
            SELECT (new_item->>'gr_trl_id')::uuid FROM unnest(p_dispatch_items) AS new_item
        )
        FOR UPDATE OF gt;

        -- The lots of a deleted receipt are not taken from: a line this edit adds or raises is refused
        -- (migration 120). A line it leaves as it is stays.
        SELECT string_agg(gt.item_name || ' (' || gr.gr_no || ')', ', ')
        INTO v_deleted_lots
        FROM unnest(p_dispatch_items) AS new_item
        JOIN goodsreceived_trl gt ON gt.id = (new_item->>'gr_trl_id')::uuid
        JOIN goodsreceived gr ON gr.id = gt.gr_id
        LEFT JOIN dispatch_trl dt ON dt.disp_id = p_dispatch_id AND dt.gr_trl_id = gt.id
        WHERE gr.deleted_at IS NOT NULL
          AND (dt.id IS NULL OR (new_item->>'disp_qty')::integer > dt.disp_qty);

        IF v_deleted_lots IS NOT NULL THEN
            RAISE EXCEPTION 'Item belongs to a deleted GRN: %', v_deleted_lots USING ERRCODE = 'WH409';
        END IF;

        -- ========== STEP 3: VALIDATE stock for increases and new items ==========
        SELECT string_agg(
            gt.item_name || ' (Available: ' || gt.stock || ', Need: ' || needed.additional || ')',
            ', '
        )
        INTO v_insufficient_stock
        FROM (
            -- New items need full qty
            SELECT (new_item->>'gr_trl_id')::uuid AS gr_trl_id,
                   (new_item->>'disp_qty')::integer AS additional
            FROM unnest(p_dispatch_items) AS new_item
            WHERE NOT EXISTS (
                SELECT 1 FROM dispatch_trl dt
                WHERE dt.disp_id = p_dispatch_id
                AND dt.gr_trl_id = (new_item->>'gr_trl_id')::uuid
            )
            UNION ALL
            -- Existing items with qty increase need the difference
            SELECT dt.gr_trl_id,
                   (new_item->>'disp_qty')::integer - dt.disp_qty AS additional
            FROM dispatch_trl dt
            JOIN unnest(p_dispatch_items) AS new_item ON (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
            WHERE dt.disp_id = p_dispatch_id
            AND (new_item->>'disp_qty')::integer > dt.disp_qty
        ) AS needed
        JOIN goodsreceived_trl gt ON gt.id = needed.gr_trl_id
        WHERE gt.stock < needed.additional;

        IF v_insufficient_stock IS NOT NULL THEN
            RAISE EXCEPTION 'Insufficient stock: %', v_insufficient_stock USING ERRCODE = 'WH409';
        END IF;

        -- ========== STEP 4: Collect affected GR_IDs for out_of_stock update ==========
        SELECT ARRAY(
            SELECT DISTINCT gr_id FROM (
                SELECT dt.gr_id FROM dispatch_trl dt WHERE dt.disp_id = p_dispatch_id
                UNION
                SELECT gt.gr_id FROM unnest(p_dispatch_items) AS new_item
                JOIN goodsreceived_trl gt ON gt.id = (new_item->>'gr_trl_id')::uuid
            ) AS all_gr_ids
        ) INTO v_affected_gr_ids;

        -- ========== STEP 5: BULK restore stock for DELETED items ==========
        UPDATE goodsreceived_trl gt
        SET stock = gt.stock + dt.disp_qty
        FROM dispatch_trl dt
        WHERE dt.disp_id = p_dispatch_id
        AND gt.id = dt.gr_trl_id
        AND NOT EXISTS (
            SELECT 1 FROM unnest(p_dispatch_items) AS new_item
            WHERE (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
        );

        -- ========== STEP 6: BULK log movements for DELETED items ==========
        INSERT INTO stock_movements (gr_trl_id, movement_type, quantity, reference_id, reference_type, balance_before, balance_after, created_by, notes)
        SELECT
            dt.gr_trl_id,
            'return',
            dt.disp_qty,
            p_dispatch_id,
            'dispatch_item_delete',
            gt.stock - dt.disp_qty,  -- balance_before (stock was already restored)
            gt.stock,                 -- balance_after
            v_user_id,
            'Item removed from dispatch (line ' || dt.id::text || ')'
        FROM dispatch_trl dt
        JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
        AND NOT EXISTS (
            SELECT 1 FROM unnest(p_dispatch_items) AS new_item
            WHERE (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
        );

        -- ========== STEP 7: BULK delete removed items ==========
        -- A line without a lot (old data) is not in the list the app sends and is never removed by an edit
        -- (migration 120). The lines of a cancelled invoice, which the guard above does not count, are kept with
        -- their amounts when the dispatch line goes: invoice_trl.disp_trl_id is emptied by its foreign key
        -- (ON DELETE SET NULL, migration 120).
        DELETE FROM dispatch_trl dt
        WHERE dt.disp_id = p_dispatch_id
        AND dt.gr_trl_id IS NOT NULL
        AND NOT EXISTS (
            SELECT 1 FROM unnest(p_dispatch_items) AS new_item
            WHERE (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
        );

        -- ========== STEP 8: BULK update stock for QTY CHANGES ==========
        UPDATE goodsreceived_trl gt
        SET stock = gt.stock - ((new_item->>'disp_qty')::integer - dt.disp_qty)
        FROM dispatch_trl dt
        JOIN unnest(p_dispatch_items) AS new_item ON (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
        AND gt.id = dt.gr_trl_id
        AND (new_item->>'disp_qty')::integer != dt.disp_qty;

        -- ========== STEP 9: BULK log movements for QTY CHANGES ==========
        INSERT INTO stock_movements (gr_trl_id, movement_type, quantity, reference_id, reference_type, balance_before, balance_after, created_by, notes)
        SELECT
            dt.gr_trl_id,
            CASE WHEN (new_item->>'disp_qty')::integer > dt.disp_qty THEN 'dispatch' ELSE 'return' END,
            -((new_item->>'disp_qty')::integer - dt.disp_qty),
            p_dispatch_id,
            'dispatch_update',
            gt.stock + ((new_item->>'disp_qty')::integer - dt.disp_qty),  -- balance_before
            gt.stock,  -- balance_after (already updated)
            v_user_id,
            format('Qty changed from %s to %s (line %s)', dt.disp_qty, (new_item->>'disp_qty')::integer, dt.id)
        FROM dispatch_trl dt
        JOIN unnest(p_dispatch_items) AS new_item ON (new_item->>'gr_trl_id')::uuid = dt.gr_trl_id
        JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
        AND (new_item->>'disp_qty')::integer != dt.disp_qty;

        -- ========== STEP 10: BULK update dispatch_trl quantities ==========
        UPDATE dispatch_trl dt
        SET disp_qty = (new_item->>'disp_qty')::integer
        FROM unnest(p_dispatch_items) AS new_item
        WHERE dt.disp_id = p_dispatch_id
        AND dt.gr_trl_id = (new_item->>'gr_trl_id')::uuid
        AND dt.disp_qty != (new_item->>'disp_qty')::integer;

        -- ========== STEP 11: BULK deduct stock for NEW items ==========
        UPDATE goodsreceived_trl gt
        SET stock = gt.stock - (new_item->>'disp_qty')::integer
        FROM unnest(p_dispatch_items) AS new_item
        WHERE gt.id = (new_item->>'gr_trl_id')::uuid
        AND NOT EXISTS (
            SELECT 1 FROM dispatch_trl dt
            WHERE dt.disp_id = p_dispatch_id
            AND dt.gr_trl_id = (new_item->>'gr_trl_id')::uuid
        );

        -- ========== STEP 12: BULK insert NEW dispatch items, and log a
        -- movement for exactly the rows inserted (migration 67) ==========
        -- A line added to a dispatch from the cart is marked 'cart' (it takes
        -- nothing from the cart, so nothing is given back for it on deletion).
        WITH inserted AS (
            INSERT INTO dispatch_trl (disp_id, gr_trl_id, gr_id, disp_qty, source_type)
            SELECT
                p_dispatch_id,
                (new_item->>'gr_trl_id')::uuid,
                gt.gr_id,
                (new_item->>'disp_qty')::integer,
                CASE WHEN EXISTS (SELECT 1 FROM dispatch d WHERE d.id = p_dispatch_id AND d.source_order_id IS NOT NULL)
                     THEN 'cart' ELSE 'direct' END
            FROM unnest(p_dispatch_items) WITH ORDINALITY AS t(new_item, ord)
            JOIN goodsreceived_trl gt ON gt.id = (new_item->>'gr_trl_id')::uuid
            WHERE NOT EXISTS (
                SELECT 1 FROM dispatch_trl dt
                WHERE dt.disp_id = p_dispatch_id
                AND dt.gr_trl_id = (new_item->>'gr_trl_id')::uuid
            )
            ORDER BY t.ord
            RETURNING gr_trl_id, disp_qty
        )
        INSERT INTO stock_movements (gr_trl_id, movement_type, quantity, reference_id, reference_type, balance_before, balance_after, created_by)
        SELECT
            ins.gr_trl_id,
            'dispatch',
            -ins.disp_qty,
            p_dispatch_id,
            'dispatch',
            gt.stock + ins.disp_qty,  -- balance_before
            gt.stock,  -- balance_after (already updated in step 11)
            v_user_id
        FROM inserted ins
        JOIN goodsreceived_trl gt ON gt.id = ins.gr_trl_id;

        -- ========== STEP 14: BULK update out_of_stock status ==========
        UPDATE goodsreceived gr
        SET out_of_stock = NOT EXISTS (
            SELECT 1 FROM goodsreceived_trl grt
            WHERE grt.gr_id = gr.id AND grt.stock > 0
        )
        WHERE gr.id = ANY(v_affected_gr_ids);

    END IF;

    -- ========== Build response (single query) ==========
    SELECT ARRAY(
        SELECT jsonb_build_object(
            'id', dt.id,
            'gr_trl_id', dt.gr_trl_id,
            'gr_id', dt.gr_id,
            'disp_qty', dt.disp_qty,
            'item_id', grt.item_id,
            'item_name', grt.item_name,
            'packaging', grt.packaging,
            'weight', grt.weight,
            'rack', grt.rack
        )
        FROM dispatch_trl dt
        JOIN goodsreceived_trl grt ON grt.id = dt.gr_trl_id
        WHERE dt.disp_id = p_dispatch_id
    ) INTO v_dispatch_items_result;

    v_result := jsonb_build_object(
        'success', true,
        'dispatch_id', p_dispatch_id,
        'dispatch_items', v_dispatch_items_result
    );

    -- The answer is kept for the 24 hours a resend is answered from it, as the dispatch create answer is (migration
    -- 120). A code that another function or user holds is left alone unless it has expired.
    IF v_request_key IS NOT NULL THEN
        INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
        VALUES (v_request_key, 'update_dispatch_smart', v_result, v_user_id, now() + interval '24 hours')
        ON CONFLICT (idempotency_key) DO UPDATE SET
            rpc_function = EXCLUDED.rpc_function,
            response = EXCLUDED.response,
            created_by = EXCLUDED.created_by,
            created_at = now(),
            expires_at = EXCLUDED.expires_at
        WHERE idempotency_keys.expires_at <= now()
           OR (idempotency_keys.rpc_function = EXCLUDED.rpc_function
               AND idempotency_keys.created_by IS NOT DISTINCT FROM EXCLUDED.created_by);
    END IF;

    RETURN v_result;

EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', SQLERRM
        );
END;
$$;
-- Invoice save and edit: M4 / I4 (NUMBER_TAKEN), I13 (financial year), I2 (notes and duration_mode kept), I14 (old GRN flag), D22 (request codes)
CREATE OR REPLACE FUNCTION public.save_invoice(p_invoice_data jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $_$
DECLARE
    v_invoice_id UUID;
    v_invoice_header JSONB;
    v_invoice_items JSONB;
    v_totals JSONB;
    v_user_id UUID;
    v_created_at TIMESTAMPTZ := NOW();
    v_is_auto_generated BOOLEAN;
    v_items_count INTEGER;
    v_duration_mode text;
    v_invoice_number_text text;
    v_invoice_number_int integer;
    v_fin_year integer;
    v_invoice_date TIMESTAMPTZ;
BEGIN
    PERFORM warehouse_security.authorize_rpc('save_invoice', '{}'::jsonb);
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
  PERFORM set_config('warehouse.discount_reason', COALESCE(p_invoice_data->>'discount_reason', ''), true);
  PERFORM warehouse_security.note_zero_charge_request(NULL, p_invoice_data);
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();

    v_invoice_header := COALESCE(p_invoice_data->'data'->'header', p_invoice_data->'header', '{}'::jsonb);
    v_invoice_items := COALESCE(p_invoice_data->'data'->'items', p_invoice_data->'data'->'rows', p_invoice_data->'items', p_invoice_data->'rows', '[]'::jsonb);
    v_duration_mode := public.validate_invoice_duration_mode(COALESCE(p_invoice_data->>'duration_mode', v_invoice_header->>'duration_mode'));

    v_invoice_number_text := COALESCE(v_invoice_header->>'invoice_number', p_invoice_data->>'inv_no');
    PERFORM warehouse_security.check_invoice_number(COALESCE(NULLIF(p_invoice_data->>'inv_no', ''),
        NULLIF(REGEXP_REPLACE(COALESCE(v_invoice_number_text, ''), '^.*-([0-9]+)$', '\1'), '')), NULL);
    v_invoice_number_int := COALESCE(
        NULLIF(p_invoice_data->>'inv_no', '')::integer,
        NULLIF(REGEXP_REPLACE(COALESCE(v_invoice_number_text, ''), '^.*-([0-9]+)$', '\1'), '')::integer
    );
    v_invoice_date := COALESCE((v_invoice_header->>'invoice_date')::TIMESTAMPTZ, (p_invoice_data->>'inv_date')::TIMESTAMPTZ, v_created_at);
    -- An invoice that names no financial year gets the one of its invoice date, not of today (migration 120), and
    -- a year that is named must be that one.
    v_fin_year := COALESCE(
        NULLIF(p_invoice_data->>'inv_fin_year', '')::integer,
        NULLIF(SPLIT_PART(COALESCE(v_invoice_header->>'financial_year', ''), '-', 1), '')::integer,
        warehouse_security.financial_year(warehouse_security.business_date(v_invoice_date))
    );
    IF v_fin_year <> warehouse_security.financial_year(warehouse_security.business_date(v_invoice_date)) THEN
        RAISE EXCEPTION 'The invoice date belongs to financial year %, not %',
            warehouse_security.financial_year(warehouse_security.business_date(v_invoice_date)), v_fin_year
            USING ERRCODE = 'WH422';
    END IF;

    v_is_auto_generated := COALESCE(
        (p_invoice_data->>'is_auto_generated')::boolean,
        (v_invoice_header->>'is_auto_generated')::boolean,
        false
    );

    IF jsonb_typeof(v_invoice_items) <> 'array' OR jsonb_array_length(v_invoice_items) = 0 THEN
        RAISE EXCEPTION 'Invoice requires at least one dispatch line';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM goodsreceived g
        WHERE g.id = COALESCE(v_invoice_header->>'grn_id', p_invoice_data->>'gr_id')::uuid
          AND g.customer_id = COALESCE(v_invoice_header->>'customer_id', p_invoice_data->>'customer_id')::uuid
          AND g.deleted_at IS NULL
    ) THEN RAISE EXCEPTION 'Invoice customer and GRN must match'; END IF;
    IF (SELECT count(DISTINCT dt.id)
        FROM jsonb_array_elements(v_invoice_items) item
        JOIN dispatch_trl dt ON dt.id = COALESCE(item->>'disp_trl_id', item->>'dispatches_items_id', item->>'dispatch_item_id')::uuid
        JOIN dispatch d ON d.id = dt.disp_id
        WHERE dt.gr_id = COALESCE(v_invoice_header->>'grn_id', p_invoice_data->>'gr_id')::uuid
          AND d.customer_id = COALESCE(v_invoice_header->>'customer_id', p_invoice_data->>'customer_id')::uuid
          AND d.deleted_at IS NULL) <> jsonb_array_length(v_invoice_items)
    THEN RAISE EXCEPTION 'Invoice contains a missing, duplicate or unrelated dispatch line'; END IF;

    -- A number the financial year already holds is refused by name, under the lock and before anything is
    -- written (migration 120). unique_inv_no_per_year covers every row, so the check does too.
    IF EXISTS (
        SELECT 1 FROM invoice i
        WHERE i.inv_fin_year = v_fin_year AND i.inv_no = v_invoice_number_int
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'WH409',
            'reason', 'NUMBER_TAKEN',
            'number', v_invoice_number_int::text,
            'error', format('Invoice number %s is already used in financial year %s', v_invoice_number_int, v_fin_year)
        );
    END IF;

    PERFORM warehouse_security.claim_invoice_lines(NULL,
        COALESCE(v_invoice_header->>'grn_id', p_invoice_data->>'gr_id')::uuid,
        ARRAY(SELECT COALESCE(item->>'disp_trl_id', item->>'dispatches_items_id', item->>'dispatch_item_id')::uuid
              FROM jsonb_array_elements(v_invoice_items) AS item));

    -- Header money columns are placeholders until the lines are saved below.
    INSERT INTO invoice (
        inv_fin_year, inv_no, gr_id, gr_no,
        customer_id, customer_name, inv_date,
        labour, tax_amount, total, discount,
        one_time_charge, notes, created_by, is_auto_generated, duration_mode
    ) VALUES (
        v_fin_year,
        v_invoice_number_int,
        COALESCE(v_invoice_header->>'grn_id', p_invoice_data->>'gr_id')::UUID,
        COALESCE(v_invoice_header->>'grn_no', p_invoice_data->>'gr_no'),
        COALESCE(v_invoice_header->>'customer_id', p_invoice_data->>'customer_id')::UUID,
        COALESCE(v_invoice_header->>'customer_name', p_invoice_data->>'customer_name'),
        v_invoice_date,
        0::NUMERIC(12,2),
        0::NUMERIC(12,2),
        0::NUMERIC(12,2),
        COALESCE(NULLIF(p_invoice_data->>'discount', '')::NUMERIC(12,2), 0),
        COALESCE((p_invoice_data->>'one_time_charge')::boolean, false),
        CASE WHEN v_is_auto_generated THEN 'Auto-generated invoice' ELSE COALESCE(p_invoice_data->>'notes', 'Manual invoice') END,
        v_user_id,
        v_is_auto_generated,
        v_duration_mode
    ) RETURNING id INTO v_invoice_id;

    INSERT INTO invoice_trl (invoice_id, disp_trl_id, duration, no_of_days, charge, tax, labour_rate)
    SELECT
        v_invoice_id,
        COALESCE(item->>'disp_trl_id', item->>'dispatches_items_id', item->>'dispatch_item_id')::UUID,
        d.duration,
        d.no_of_days,
        COALESCE(NULLIF(item->>'charge', '')::NUMERIC(12,2), NULLIF(item->>'unit_price', '')::NUMERIC(12,2)),
        COALESCE(NULLIF(item->>'tax', '')::NUMERIC(12,2), NULLIF(item->>'tax_percent', '')::NUMERIC(12,2)),
        (item->>'labour_rate')::NUMERIC
    FROM jsonb_array_elements(v_invoice_items) WITH ORDINALITY AS t(item, ord)
    JOIN dispatch_trl dt ON dt.id = COALESCE(item->>'disp_trl_id', item->>'dispatches_items_id', item->>'dispatch_item_id')::UUID
    JOIN dispatch disp ON disp.id = dt.disp_id
    JOIN goodsreceived gr ON gr.id = dt.gr_id
    CROSS JOIN LATERAL public.calculate_invoice_duration(warehouse_security.business_date(gr.date), warehouse_security.business_date(disp.disp_date), v_duration_mode) d
    ORDER BY t.ord;

    GET DIAGNOSTICS v_items_count = ROW_COUNT;
    v_totals := warehouse_security.recalculate_invoice_header(v_invoice_id);

    UPDATE goodsreceived
    SET invoiced = true
    WHERE id = COALESCE(v_invoice_header->>'grn_id', p_invoice_data->>'gr_id')::UUID;

    RETURN jsonb_build_object(
        'success', true,
        'invoice_id', v_invoice_id,
        'invoice_no', v_invoice_number_text,
        'duration_mode', v_duration_mode,
        'is_auto_generated', v_is_auto_generated,
        'items_count', v_items_count,
        'totals', v_totals,
        'message', 'Invoice saved successfully'
    );
EXCEPTION
    WHEN insufficient_privilege THEN RAISE;
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Database error: ' || SQLERRM || ' (SQLState: ' || SQLSTATE || ')'
        );
END;
$_$;
CREATE OR REPLACE FUNCTION public.save_invoice_internal(p_invoice_id uuid, p_invoice_data jsonb, p_invoice_items jsonb[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_user_id UUID;
    v_new_gr_id UUID;
    v_invoice_number_for_resolution VARCHAR(20);
    v_invoice_creation_time TIMESTAMPTZ;
    v_invoice_date TIMESTAMPTZ;
    v_resolved_errors_count INTEGER := 0;
    v_new_items_count INTEGER := 0;
    v_final_invoice_id UUID;
    v_is_auto_generated BOOLEAN;
    v_duration_mode text;
    v_discount NUMERIC(12,2) := COALESCE(NULLIF(p_invoice_data->>'discount', '')::NUMERIC(12,2), 0::NUMERIC(12,2));
    v_function_version TEXT := 'save_invoice_v20260503_duration_mode';
BEGIN
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();
    v_new_gr_id := (p_invoice_data->>'gr_id')::uuid;
    v_invoice_creation_time := NOW();
    v_invoice_date := COALESCE((p_invoice_data->>'inv_date')::TIMESTAMPTZ, NOW());
    v_invoice_number_for_resolution := (p_invoice_data->>'inv_no');
    v_is_auto_generated := COALESCE((p_invoice_data->>'is_auto_generated')::boolean, false);
    v_duration_mode := public.validate_invoice_duration_mode(p_invoice_data->>'duration_mode');
    -- The financial year is the one of the invoice date (migration 120).
    IF p_invoice_data->>'inv_fin_year' IS NOT NULL
       AND (p_invoice_data->>'inv_fin_year')::integer
           <> warehouse_security.financial_year(warehouse_security.business_date(v_invoice_date)) THEN
        RAISE EXCEPTION 'The invoice date belongs to financial year %, not %',
            warehouse_security.financial_year(warehouse_security.business_date(v_invoice_date)),
            (p_invoice_data->>'inv_fin_year')::integer
            USING ERRCODE = 'WH422';
    END IF;

    -- A number the financial year already holds is refused by name, under the lock and before anything is
    -- written (migration 120). unique_inv_no_per_year covers every row, so the check does too.
    IF EXISTS (
        SELECT 1 FROM invoice i
        WHERE i.inv_fin_year = (p_invoice_data->>'inv_fin_year')::integer
          AND i.inv_no = (p_invoice_data->>'inv_no')::integer
          AND i.id IS DISTINCT FROM p_invoice_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'WH409',
            'reason', 'NUMBER_TAKEN',
            'number', p_invoice_data->>'inv_no',
            'error', format('Invoice number %s is already used in financial year %s',
                            p_invoice_data->>'inv_no', p_invoice_data->>'inv_fin_year'),
            'function_version', v_function_version
        );
    END IF;

    PERFORM warehouse_security.claim_invoice_lines(NULL, v_new_gr_id,
        ARRAY(SELECT (item->>'disp_trl_id')::uuid FROM unnest(p_invoice_items) AS item));

    IF p_invoice_id IS NOT NULL THEN
        INSERT INTO invoice (
            id, inv_fin_year, inv_no, gr_id, gr_no,
            customer_id, customer_name, inv_date,
            labour, tax_amount, total, discount,
            one_time_charge, notes, created_by, is_auto_generated, duration_mode
        ) VALUES (
            p_invoice_id,
            (p_invoice_data->>'inv_fin_year')::integer,
            (p_invoice_data->>'inv_no')::integer,
            v_new_gr_id,
            p_invoice_data->>'gr_no',
            (p_invoice_data->>'customer_id')::uuid,
            p_invoice_data->>'customer_name',
            v_invoice_date,
            0::NUMERIC(12,2),
            0::NUMERIC(12,2),
            0::NUMERIC(12,2),
            v_discount,
            COALESCE((p_invoice_data->>'one_time_charge')::boolean, false),
            p_invoice_data->>'notes',
            v_user_id,
            v_is_auto_generated,
            v_duration_mode
        );
        v_final_invoice_id := p_invoice_id;
    ELSE
        INSERT INTO invoice (
            inv_fin_year, inv_no, gr_id, gr_no,
            customer_id, customer_name, inv_date,
            labour, tax_amount, total, discount,
            one_time_charge, notes, created_by, is_auto_generated, duration_mode
        ) VALUES (
            (p_invoice_data->>'inv_fin_year')::integer,
            (p_invoice_data->>'inv_no')::integer,
            v_new_gr_id,
            p_invoice_data->>'gr_no',
            (p_invoice_data->>'customer_id')::uuid,
            p_invoice_data->>'customer_name',
            v_invoice_date,
            0::NUMERIC(12,2),
            0::NUMERIC(12,2),
            0::NUMERIC(12,2),
            v_discount,
            COALESCE((p_invoice_data->>'one_time_charge')::boolean, false),
            p_invoice_data->>'notes',
            v_user_id,
            v_is_auto_generated,
            v_duration_mode
        ) RETURNING id INTO v_final_invoice_id;
    END IF;

    INSERT INTO invoice_trl (invoice_id, disp_trl_id, duration, no_of_days, charge, tax, labour_rate)
    SELECT
        v_final_invoice_id,
        (item->>'disp_trl_id')::uuid,
        d.duration,
        d.no_of_days,
        COALESCE(NULLIF(item->>'charge', '')::NUMERIC(12,2), NULLIF(item->>'unit_price', '')::NUMERIC(12,2)),
        COALESCE(NULLIF(item->>'tax', '')::NUMERIC(12,2), NULLIF(item->>'tax_percent', '')::NUMERIC(12,2)),
        (item->>'labour_rate')::numeric
    FROM unnest(p_invoice_items) WITH ORDINALITY AS t(item, ord)
    JOIN dispatch_trl dt ON dt.id = (item->>'disp_trl_id')::uuid
    JOIN dispatch disp ON disp.id = dt.disp_id
    JOIN goodsreceived gr ON gr.id = dt.gr_id
    CROSS JOIN LATERAL public.calculate_invoice_duration(warehouse_security.business_date(gr.date), warehouse_security.business_date(disp.disp_date), v_duration_mode) d
    ORDER BY t.ord;

    GET DIAGNOSTICS v_new_items_count = ROW_COUNT;
    PERFORM warehouse_security.assert_invoice_lines(v_final_invoice_id, v_new_gr_id,
        (p_invoice_data->>'customer_id')::uuid, COALESCE(array_length(p_invoice_items, 1), 0));
    PERFORM warehouse_security.recalculate_invoice_header(v_final_invoice_id);

    UPDATE goodsreceived SET invoiced = true WHERE id = v_new_gr_id;

    UPDATE auto_invoice_errors
    SET
        resolved_at = v_invoice_creation_time,
        resolved_invoice_id = v_final_invoice_id,
        error_details = COALESCE(error_details, '{}')::jsonb ||
                       jsonb_build_object(
                           'resolution_type', 'manual_invoice_created',
                           'resolution_notes', 'Invoice created manually through save_invoice',
                           'invoice_id', v_final_invoice_id,
                           'invoice_number', v_invoice_number_for_resolution,
                           'invoice_date', v_invoice_date,
                           'gr_id', v_new_gr_id
                       )
    WHERE gr_id = v_new_gr_id
    AND resolved_at IS NULL;

    GET DIAGNOSTICS v_resolved_errors_count = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'invoice_id', v_final_invoice_id,
        'invoice_number', v_invoice_number_for_resolution,
        'items_count', v_new_items_count,
        'resolved_errors_count', v_resolved_errors_count,
        'is_auto_generated', v_is_auto_generated,
        'duration_mode', v_duration_mode,
        'function_version', v_function_version
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'error_code', SQLSTATE,
        'function_version', v_function_version
    );
END;
$$;
CREATE OR REPLACE FUNCTION public.update_invoice(p_invoice_id uuid, p_invoice_data jsonb, p_invoice_items jsonb[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_user_id UUID;
    v_new_gr_id UUID;
    v_old_gr_id UUID;
    v_discount NUMERIC(12,2);
    v_items_count INTEGER;
    v_duration_mode text;
    v_stored_duration_mode text;
    v_stored_inv_date timestamptz;
    v_stored_fin_year integer;
    v_invoice_no integer;
    v_request_key text;
    v_cached_response jsonb;
    v_result jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_invoice',jsonb_build_object('p_invoice_id',p_invoice_id));
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);

    -- A request code (migration 120, owner decision D22): when the request carries one, this user's saved answer for
    -- it is returned as it was, before any other check, while the invoice it saved still exists. A resend of a
    -- save whose answer was lost is therefore never refused for what its own first try changed, and
    -- get_submission_result gives the same answer.
    v_request_key := NULLIF(p_invoice_data->>'request_key', '');
    IF v_request_key IS NOT NULL THEN
        SELECT k.response INTO v_cached_response
        FROM idempotency_keys k
        WHERE k.idempotency_key = v_request_key
          AND k.rpc_function = 'update_invoice'
          AND k.created_by = (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid())
          AND k.response->>'invoice_id' = p_invoice_id::text
          AND k.expires_at > now();

        IF v_cached_response IS NOT NULL
           AND EXISTS (SELECT 1 FROM invoice r WHERE r.id = p_invoice_id AND r.deleted_at IS NULL) THEN
            RETURN v_cached_response;
        END IF;
    END IF;

  PERFORM set_config('warehouse.discount_reason', COALESCE(p_invoice_data->>'discount_reason', ''), true);
  PERFORM warehouse_security.note_zero_charge_request(p_invoice_id, p_invoice_data);
  PERFORM warehouse_security.check_invoice_number(p_invoice_data->>'inv_no', p_invoice_id);
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();
    v_discount := COALESCE(NULLIF(p_invoice_data->>'discount', '')::NUMERIC(12,2), 0::NUMERIC(12,2));
    v_new_gr_id := (p_invoice_data->>'gr_id')::uuid;

    SELECT gr_id, duration_mode, inv_date, inv_fin_year
    INTO v_old_gr_id, v_stored_duration_mode, v_stored_inv_date, v_stored_fin_year
    FROM invoice WHERE id = p_invoice_id AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invoice not found');
    END IF;

    -- The duration rule and the notes stay as stored when the request does not carry them, as the zero-charge
    -- reason does (migration 120). The app sends neither.
    v_duration_mode := CASE WHEN p_invoice_data ? 'duration_mode'
                            THEN public.validate_invoice_duration_mode(p_invoice_data->>'duration_mode')
                            ELSE COALESCE(v_stored_duration_mode, 'legacy') END;

    -- The financial year is the one of the invoice date (migration 120). It is checked when the edit changes the
    -- invoice date or the year; an edit that leaves both as stored is not refused for an old invoice's year.
    IF p_invoice_data->>'inv_fin_year' IS NOT NULL
       AND ((p_invoice_data->>'inv_date')::TIMESTAMPTZ IS DISTINCT FROM v_stored_inv_date
            OR (p_invoice_data->>'inv_fin_year')::integer IS DISTINCT FROM v_stored_fin_year)
       AND (p_invoice_data->>'inv_fin_year')::integer
           <> warehouse_security.financial_year(warehouse_security.business_date((p_invoice_data->>'inv_date')::TIMESTAMPTZ)) THEN
        RAISE EXCEPTION 'The invoice date belongs to financial year %, not %',
            warehouse_security.financial_year(warehouse_security.business_date((p_invoice_data->>'inv_date')::TIMESTAMPTZ)),
            (p_invoice_data->>'inv_fin_year')::integer
            USING ERRCODE = 'WH422';
    END IF;

    -- A number the financial year already holds is refused by name, under the lock and before anything is
    -- written (migration 120). unique_inv_no_per_year covers every row, so the check does too.
    IF EXISTS (
        SELECT 1 FROM invoice i
        WHERE i.inv_fin_year = (p_invoice_data->>'inv_fin_year')::integer
          AND i.inv_no = (p_invoice_data->>'inv_no')::integer
          AND i.id IS DISTINCT FROM p_invoice_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error_code', 'WH409',
            'reason', 'NUMBER_TAKEN',
            'number', p_invoice_data->>'inv_no',
            'error', format('Invoice number %s is already used in financial year %s',
                            p_invoice_data->>'inv_no', p_invoice_data->>'inv_fin_year')
        );
    END IF;

    PERFORM warehouse_security.claim_invoice_lines(p_invoice_id, v_new_gr_id,
        ARRAY(SELECT (item->>'disp_trl_id')::uuid FROM unnest(p_invoice_items) AS item));

    IF v_old_gr_id IS DISTINCT FROM v_new_gr_id THEN
        IF v_old_gr_id IS NOT NULL THEN
            -- Another live invoice may still hold the old GRN: then it stays invoiced (migration 120).
            UPDATE goodsreceived SET invoiced = false
            WHERE id = v_old_gr_id
              AND NOT EXISTS (SELECT 1 FROM invoice i WHERE i.gr_id = v_old_gr_id AND i.deleted_at IS NULL AND i.id <> p_invoice_id);
        END IF;

        IF v_new_gr_id IS NOT NULL THEN
            UPDATE goodsreceived SET invoiced = true WHERE id = v_new_gr_id;
        END IF;
    END IF;

    UPDATE invoice SET
        inv_fin_year = (p_invoice_data->>'inv_fin_year')::integer,
        inv_no = (p_invoice_data->>'inv_no')::integer,
        gr_id = v_new_gr_id,
        gr_no = p_invoice_data->>'gr_no',
        customer_id = (p_invoice_data->>'customer_id')::uuid,
        customer_name = p_invoice_data->>'customer_name',
        inv_date = (p_invoice_data->>'inv_date')::TIMESTAMPTZ,
        labour = 0,
        tax_amount = 0,
        total = 0,
        discount = v_discount,
        one_time_charge = COALESCE((p_invoice_data->>'one_time_charge')::boolean, false),
        notes = CASE WHEN p_invoice_data ? 'notes' THEN p_invoice_data->>'notes' ELSE notes END,
        duration_mode = v_duration_mode
    WHERE id = p_invoice_id
    RETURNING inv_no INTO v_invoice_no;

    DELETE FROM invoice_trl WHERE invoice_id = p_invoice_id;

    INSERT INTO invoice_trl (invoice_id, disp_trl_id, duration, no_of_days, charge, tax, labour_rate)
    SELECT
        p_invoice_id,
        (item->>'disp_trl_id')::uuid,
        d.duration,
        d.no_of_days,
        COALESCE(NULLIF(item->>'charge', '')::NUMERIC(12,2), NULLIF(item->>'unit_price', '')::NUMERIC(12,2)),
        COALESCE(NULLIF(item->>'tax', '')::NUMERIC(12,2), NULLIF(item->>'tax_percent', '')::NUMERIC(12,2)),
        (item->>'labour_rate')::numeric
    FROM unnest(p_invoice_items) WITH ORDINALITY AS t(item, ord)
    JOIN dispatch_trl dt ON dt.id = (item->>'disp_trl_id')::uuid
    JOIN dispatch disp ON disp.id = dt.disp_id
    JOIN goodsreceived gr ON gr.id = dt.gr_id
    CROSS JOIN LATERAL public.calculate_invoice_duration(warehouse_security.business_date(gr.date), warehouse_security.business_date(disp.disp_date), v_duration_mode) d
    ORDER BY t.ord;

    GET DIAGNOSTICS v_items_count = ROW_COUNT;
    PERFORM warehouse_security.assert_invoice_lines(p_invoice_id, v_new_gr_id,
        (p_invoice_data->>'customer_id')::uuid, COALESCE(array_length(p_invoice_items, 1), 0));
    PERFORM warehouse_security.recalculate_invoice_header(p_invoice_id);

    v_result := jsonb_build_object(
        'success', true,
        'invoice_id', p_invoice_id,
        'invoice_no', v_invoice_no,
        'invoice_number', v_invoice_no,
        'items_count', v_items_count,
        'duration_mode', v_duration_mode,
        'message', 'Invoice updated successfully'
    );

    -- The answer is kept for the 24 hours a resend is answered from it, as the dispatch create answer is (migration
    -- 120). A code that another function or user holds is left alone unless it has expired.
    IF v_request_key IS NOT NULL THEN
        INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
        VALUES (v_request_key, 'update_invoice', v_result, v_user_id, now() + interval '24 hours')
        ON CONFLICT (idempotency_key) DO UPDATE SET
            rpc_function = EXCLUDED.rpc_function,
            response = EXCLUDED.response,
            created_by = EXCLUDED.created_by,
            created_at = now(),
            expires_at = EXCLUDED.expires_at
        WHERE idempotency_keys.expires_at <= now()
           OR (idempotency_keys.rpc_function = EXCLUDED.rpc_function
               AND idempotency_keys.created_by IS NOT DISTINCT FROM EXCLUDED.created_by);
    END IF;

    RETURN v_result;
EXCEPTION WHEN insufficient_privilege THEN RAISE;
WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END;
$$;
-- D22: the three-argument save_invoice (the one the app calls) keeps its answer under a request code
CREATE OR REPLACE FUNCTION public.save_invoice(p_invoice_id uuid, p_invoice_data jsonb, p_invoice_items jsonb[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_validation_result JSONB;
    v_request_key text;
    v_cached_response jsonb;
    v_result jsonb;
    v_user_id uuid;
BEGIN
  PERFORM warehouse_security.authorize_rpc('save_invoice',jsonb_build_object('p_invoice_id',p_invoice_id));
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);

    -- A request code (migration 120, owner decision D22): when the request carries one, this user's saved answer for
    -- it is returned as it was, before any other check, while the invoice it saved is still live. A resend of a
    -- save whose answer was lost thus does not save twice, and get_submission_result gives the same answer.
    v_request_key := NULLIF(p_invoice_data->>'request_key', '');
    IF v_request_key IS NOT NULL THEN
        SELECT k.response INTO v_cached_response
        FROM idempotency_keys k
        WHERE k.idempotency_key = v_request_key
          AND k.rpc_function = 'save_invoice'
          AND k.created_by = (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid())
          AND k.expires_at > now();

        IF v_cached_response IS NOT NULL
           AND EXISTS (SELECT 1 FROM invoice i WHERE i.id::text = v_cached_response->>'invoice_id' AND i.deleted_at IS NULL) THEN
            RETURN v_cached_response;
        END IF;
    END IF;
    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();

  PERFORM set_config('warehouse.discount_reason', COALESCE(p_invoice_data->>'discount_reason', ''), true);
  PERFORM warehouse_security.note_zero_charge_request(p_invoice_id, p_invoice_data);
  PERFORM warehouse_security.check_invoice_number(p_invoice_data->>'inv_no', NULL);
    -- Step 1: Validate invoice data
    v_validation_result := validate_invoice_input(p_invoice_data);
    IF NOT (v_validation_result->>'valid')::BOOLEAN THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'error', 'Invalid invoice data',
            'validation_errors', v_validation_result->'errors'
        );
    END IF;

    -- Step 2: Validate invoice items
    v_validation_result := validate_invoice_items(p_invoice_items);
    IF NOT (v_validation_result->>'valid')::BOOLEAN THEN
        RETURN jsonb_build_object(
            'success', FALSE,
            'error', 'Invalid invoice items',
            'validation_errors', v_validation_result->'errors'
        );
    END IF;

    -- Step 3: Call original function (now named _internal)
    v_result := save_invoice_internal(p_invoice_id, p_invoice_data, p_invoice_items);

    -- The answer is kept for the 24 hours a resend is answered from it, as the dispatch create answer is (migration
    -- 120). A code that another function or user holds is left alone unless it has expired.
    IF v_request_key IS NOT NULL AND COALESCE((v_result->>'success')::boolean, false) THEN
        INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
        VALUES (v_request_key, 'save_invoice', v_result, v_user_id, now() + interval '24 hours')
        ON CONFLICT (idempotency_key) DO UPDATE SET
            rpc_function = EXCLUDED.rpc_function,
            response = EXCLUDED.response,
            created_by = EXCLUDED.created_by,
            created_at = now(),
            expires_at = EXCLUDED.expires_at
        WHERE idempotency_keys.expires_at <= now()
           OR (idempotency_keys.rpc_function = EXCLUDED.rpc_function
               AND idempotency_keys.created_by IS NOT DISTINCT FROM EXCLUDED.created_by);
    END IF;

    RETURN v_result;
END;
$$;
-- D22: get_submission_result, what became of a save whose answer was lost (this user's own saved answers only)
CREATE OR REPLACE FUNCTION public.get_submission_result(p_key text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_user_id uuid;
    v_response jsonb;
BEGIN
    PERFORM warehouse_security.authorize_rpc('get_submission_result', jsonb_build_object('p_key', p_key));

    SELECT id INTO v_user_id FROM user_profiles WHERE auth_user_id = auth.uid();

    IF p_key IS NULL OR p_key = '' OR v_user_id IS NULL THEN
        RETURN jsonb_build_object('found', false);
    END IF;

    -- Only the calling user's own saved answer, still valid, a success, and only while the record it made is still
    -- there: a dispatch or invoice that is not deleted, a GRN that is not deleted. A failure is never stored, and a
    -- database error is not turned into "not found": the caller would then send the save again.
    SELECT k.response INTO v_response
    FROM idempotency_keys k
    WHERE k.idempotency_key = p_key
      AND k.created_by = v_user_id
      AND k.expires_at > now()
      AND k.response->>'success' = 'true'
      AND CASE k.rpc_function
            WHEN 'create_dispatch_with_stock_check' THEN EXISTS (
                SELECT 1 FROM dispatch d WHERE d.id::text = k.response->>'dispatch_id' AND d.deleted_at IS NULL)
            WHEN 'update_dispatch_smart' THEN EXISTS (
                SELECT 1 FROM dispatch d WHERE d.id::text = k.response->>'dispatch_id' AND d.deleted_at IS NULL)
            WHEN 'save_grn' THEN EXISTS (
                SELECT 1 FROM goodsreceived g WHERE g.id::text = k.response #>> '{data,grn_id}' AND g.deleted_at IS NULL)
            WHEN 'update_grn' THEN EXISTS (
                SELECT 1 FROM goodsreceived g WHERE g.id::text = k.response #>> '{grn,id}' AND g.deleted_at IS NULL)
            WHEN 'save_invoice' THEN EXISTS (
                SELECT 1 FROM invoice i WHERE i.id::text = k.response->>'invoice_id' AND i.deleted_at IS NULL)
            WHEN 'update_invoice' THEN EXISTS (
                SELECT 1 FROM invoice i WHERE i.id::text = k.response->>'invoice_id' AND i.deleted_at IS NULL)
            ELSE false
          END;

    IF v_response IS NULL THEN
        RETURN jsonb_build_object('found', false);
    END IF;
    RETURN jsonb_build_object('found', true, 'response', v_response);
END;
$$;
ALTER FUNCTION public.get_submission_result(p_key text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_submission_result(p_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_submission_result(p_key text) TO service_role;
GRANT ALL ON FUNCTION public.get_submission_result(p_key text) TO authenticated;
-- A12, D22: authorize_rpc lets a cart line that no longer exists through to the function that answers it, and lets staff ask get_submission_result
CREATE OR REPLACE FUNCTION warehouse_security.authorize_rpc(rpc text, args jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE role_name text := warehouse_security.active_role(); customer uuid; other_customer uuid; document uuid;
  removable boolean;
BEGIN
  IF auth.jwt()->>'role' = 'service_role' THEN RETURN; END IF;
  IF role_name IS NULL THEN RAISE EXCEPTION 'Active account required' USING ERRCODE = '42501'; END IF;
  -- User management: administrators, and supervisors for other people who are
  -- not administrators. The four bodies refuse a supervisor who targets an
  -- administrator or the own profile, or who grants the administrator role.
  IF rpc IN ('update_user_role','update_user_status','assign_customer_to_user','remove_customer_assignment') THEN
    IF role_name NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501'; END IF;
    RETURN;
  END IF;
  -- Central identity (migration 49), sensor settings (migration 74) and service accounts
  -- (migration 78): administrators only.
  IF rpc IN ('clear_user_central_identity','update_sensor_device','set_service_account') THEN
    IF role_name <> 'admin' THEN RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501'; END IF;
    RETURN;
  END IF;
  IF role_name IN ('admin','supervisor') THEN RETURN; END IF;
  -- Approved document RPCs only; no shared ownership or table-policy change.
  IF role_name = 'staff' AND rpc IN (
    'save_grn','update_grn','check_grn_exists','get_next_grn_number',
    'get_all_grn_items','get_grn_list','get_grn_details','get_grn_item_dispatches',
    'get_grn_prefixes_with_stock','get_all_grn_activity',
    'get_customer_grn_activity','get_customer_grn_items',
    'get_customer_grns_with_stock_dispatch_sorted',
    'search_customers','get_supervisors','get_vehicle_suggestions',
    'register_grn_image_upload','confirm_grn_image_upload',
    'cancel_grn_image_upload','upload_grn_image',
    'register_dispatch_image_upload','confirm_dispatch_image_upload',
    'cancel_dispatch_image_upload',
    'create_dispatch_with_stock_check','update_dispatch_smart',
    'check_dispatch_exists','get_next_dispatch_number','get_dispatch_autocomplete',
    'get_dispatch_details','get_dispatch_list_with_items',
    'get_all_dispatch_items','get_all_dispatch_activity','get_customer_dispatch_list',
    'get_customer_dispatch_items','get_recent_dispatched_orders',
    -- What became of a save whose answer was lost (migration 120).
    'get_submission_result',
    'save_invoice','update_invoice','get_next_invoice_number',
    'get_invoiceable_grns','get_invoices_list','get_invoice_data','get_invoice_detail',
    'get_invoice_items_detailed','get_customer_invoice_summary',
    'generate_invoice_data_for_grn_with_pricing',
    -- Orders and queue (user decision, 2026-10-09).
    'get_orders_list','get_order_with_items','get_or_create_cart',
    'add_item_to_order','update_order_item_quantity','remove_item_from_order',
    'get_cart_dispatches','search_customer_items_for_order',
    'get_customer_items_for_order_selection','get_order_change_log',
    -- Reports the app shows to staff (owner decision, 2026-10-11).
    'get_all_stock_summary','get_customer_stock_summary',
    'get_all_customer_activity_summary','get_customer_activity_detail',
    'get_customer_dispatch_activity','get_stock_aging_report','get_item_wise_stock_list',
    -- Item pricing is for administrators and supervisors (migration 90); staff keep
    -- only the rates a GRN is invoiced at (migration 88, below).
    -- The rate of each line of a GRN (migration 88).
    'get_grn_item_rates',
    -- Sensors (owner decision, 2026-10-11).
    'get_sensor_polling_data','get_sensor_history',
    -- One sensor (migration 74).
    'get_sensor_device'
  ) THEN RETURN; END IF;
  -- Photo removal in the edit forms (owner decision, 2026-10-11): a photo of a
  -- receipt or dispatch that staff can open for editing, and that is confirmed
  -- or was registered by the caller. Another person's pending upload stays
  -- with that person, as for cancel_*_image_upload (migration 23).
  IF role_name = 'staff' AND rpc IN ('delete_grn_image','delete_dispatch_image') THEN
    IF rpc = 'delete_grn_image' THEN
      SELECT COALESCE(g.deleted_at IS NULL AND (i.status = 'confirmed' OR i.uploaded_by = public.get_current_user_profile_id()), false)
        INTO removable FROM public.grn_images i JOIN public.goodsreceived g ON g.id = i.grn_id
        WHERE i.id = (args->>'p_image_id')::uuid;
    ELSE
      SELECT COALESCE(d.deleted_at IS NULL AND (i.status = 'confirmed' OR i.uploaded_by = public.get_current_user_profile_id()), false)
        INTO removable FROM public.dispatch_images i JOIN public.dispatch d ON d.id = i.dispatch_id
        WHERE i.id = (args->>'p_image_id')::uuid;
    END IF;
    -- An unknown id is answered by the function itself ("not found").
    IF removable IS FALSE THEN RAISE EXCEPTION 'Staff access required' USING ERRCODE = '42501'; END IF;
    RETURN;
  END IF;

  IF rpc IN ('get_items','get_item','search_items_autocomplete','get_orders_list','delete_user_account') THEN RETURN; END IF;
  -- get_stock_aging_report and get_item_wise_stock_list: with a customer id
  -- they are that customer's report; without one they are the all-customers
  -- report, which no customer account may run.
  IF rpc LIKE 'get_customer_%' OR rpc IN ('search_customer_items_for_order','get_or_create_cart',
      'get_stock_aging_report','get_item_wise_stock_list') THEN
    customer := COALESCE(args->>'p_customer_id', args->>'p_customer_uuid')::uuid;
  ELSIF rpc IN ('get_grn_details','get_grn_item_dispatches','get_grn_item_rates') THEN
    IF args ? 'p_grn_item_id' THEN
      SELECT g.customer_id INTO customer FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE t.id=(args->>'p_grn_item_id')::uuid;
    ELSE SELECT customer_id INTO customer FROM public.goodsreceived WHERE id=(args->>'p_grn_id')::uuid; END IF;
  ELSIF rpc = 'get_dispatch_details' THEN
    SELECT customer_id INTO customer FROM public.dispatch WHERE id=(args->>'p_dispatch_id')::uuid;
  ELSIF rpc IN ('get_invoice_data','get_invoice_detail','get_invoice_items_detailed') THEN
    SELECT customer_id INTO customer FROM public.invoice WHERE id=(args->>'p_invoice_id')::uuid;
  ELSIF rpc IN ('get_order_with_items','get_cart_dispatches','add_item_to_order',
                'update_order_item_quantity','remove_item_from_order','get_order_change_log') THEN
    document := COALESCE(args->>'p_order_id', args->>'p_cart_id')::uuid;
    IF rpc IN ('update_order_item_quantity','remove_item_from_order') THEN
      SELECT order_id INTO document FROM public.order_items WHERE id=(args->>'p_order_item_id')::uuid;
      -- A line that no longer exists (used up by a dispatch, removed on another phone) acts on nothing: the
      -- function answers "Order item not found" instead of "Customer access denied" (migration 120). A line
      -- that exists is still checked against its customer below.
      IF NOT FOUND THEN RETURN; END IF;
    END IF;
    SELECT customer_id INTO customer FROM public.orders WHERE id=document;
    -- History may be requested for one customer instead of one order.
    IF rpc = 'get_order_change_log' AND document IS NULL THEN
      customer := (args->>'p_customer_id')::uuid;
    END IF;
    IF rpc = 'add_item_to_order' THEN
      SELECT g.customer_id INTO other_customer FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id=t.gr_id WHERE t.id=(args->>'p_grn_item_id')::uuid;
      IF other_customer IS DISTINCT FROM customer THEN RAISE EXCEPTION 'Item belongs to another customer' USING ERRCODE = '42501'; END IF;
    END IF;
  ELSE
    RAISE EXCEPTION 'Staff access required' USING ERRCODE = '42501';
  END IF;
  IF customer IS NULL OR NOT warehouse_security.owns_customer(customer) THEN
    RAISE EXCEPTION 'Customer access denied' USING ERRCODE = '42501';
  END IF;
END $$;
