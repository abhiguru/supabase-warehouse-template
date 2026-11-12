-- Migration 190 (WH-180, part 2 of the import of past years): documents imported from the previous system are read-only. Written against
-- the tables and functions as migrations 175 (invoice number prefix), 184 and 189 (the Imported mark, import_batch_id) left them.
--
--  1. A table guard, so that every path is covered (an RPC, the server key, a function added later):
--     warehouse_security.refuse_imported_change(), trigger guard_imported_read_only, BEFORE INSERT OR UPDATE OR DELETE on goodsreceived,
--     goodsreceived_trl, dispatch, dispatch_trl, invoice, invoice_trl and payments, and BEFORE INSERT on grn_images and dispatch_images.
--     The name sorts before every other BEFORE trigger of these tables, so it sees the change the statement asked for.
--     - A document (GRN, dispatch, invoice, payment) with import_batch_id set is not deleted, and not updated, with one exception: a GRN
--       may change invoiced, out_of_stock, updated_at and updated_by (its stock flag and invoiced cache follow app dispatches and app
--       invoices made from it). A soft delete (deleted_at) or a cancel (cancelled_at) is an update, so it is refused too.
--     - A line (goodsreceived_trl, dispatch_trl, invoice_trl) of an imported document is not deleted, and not updated, with one exception:
--       a GRN line may change its stock (an app dispatch from it, or the edit or delete of such a dispatch). No line is added to an
--       imported document, and no line is moved into one. A photo is not added to an imported GRN or dispatch (the import adds none, so
--       no photo row of an imported document exists to change or delete).
--     - The mark itself: no INSERT with import_batch_id set, and no UPDATE that sets, changes or clears it, outside the import.
--     Allowed, because none of it changes an imported row beyond the exceptions: a dispatch made in the app from an imported GRN line with
--     stock (its new dispatch and lines are app rows; the GRN line's stock and the GRN's flags change), the edit or delete of that app
--     dispatch (stock goes back), an app invoice over imported dispatch lines (new app invoice lines point at them; the GRN's invoiced
--     flag changes), the cancel or delete of that app invoice, and a payment recorded in the app on an imported invoice (a new app payment;
--     no invoice row is written). An app payment on an imported invoice is an app row, so it can be edited and deleted like any other.
--     Refused with SQLSTATE WH423, message = the English sentence of the app's importedReadOnly ("This GRN was imported from the previous
--     system and can't be changed."), hint IMPORTED_READ_ONLY; a change of the mark: "Only the import sets or clears the Imported mark.".
--     Bypass: current_setting('warehouse.import', true) = 'on'. Only the import function of migration 192 sets it, transaction-local, for
--     its own writes. No app path can set a setting: PostgREST exposes the public RPCs only, and no RPC sets this one.
--     The retention and cleanup jobs (warehouse_maintenance.run_database_retention, delete_expired_pending_images) touch none of the
--     guarded rows: retention deletes no document, and pending photo rows never belong to an imported document.
--  2. A clean answer before anything is written, since many RPCs catch an exception into {success:false, error: SQLERRM}: the RPCs
--     that edit or delete a document answer {success:false, error_code:'WH409', reason:'IMPORTED_READ_ONLY', document:'grn' | 'dispatch'
--     | 'invoice' | 'payment', error and message: the sentence above} right after their authorize_rpc call (so a role the gate refuses is
--     still refused by the gate) when the document is imported:
--       update_grn, delete_grn_safe, apply_grn_rates (warehouse_security, reached from update_grn) and update_dispatch_smart in their
--       definition files; here, by marker count: get_grn_edit_state (answers the refusal instead of an edit state),
--       delete_dispatch_with_order_cleanup, update_invoice, cancel_invoice (an imported invoice is not cancelled: that is an edit),
--       delete_invoice, delete_invoice_pair, update_payment and delete_payment (an imported payment; before PAYMENT_NOT_EDITABLE),
--       delete_grn_image, delete_dispatch_image, register_grn_image_upload, register_dispatch_image_upload, upload_grn_image and
--       upload_dispatch_image (the last two write photo rows too: upload_grn_image is granted to authenticated, upload_dispatch_image to
--       service_role).
--     Not refused early (the table guard still holds): confirm_* and cancel_*_image_upload (they act on a pending photo row, which no
--     imported document has); the preview_* functions (they write nothing).
--  3. While the import runs (warehouse.import = 'on'), and only for its INSERTs, audit_trigger_func on the seven document tables,
--     sync_grn_invoiced_trigger and invoice_discount_audit return at once: the import records one audit row per batch and works out
--     the GRNs' invoiced flags in one statement. Every other write is audited and synced as before.
--  4. apply_document_numbering: the refusal of an invoice prefix change mid-year (NUMBERING_PREFIX_MID_YEAR, migration 175) counts only
--     invoices made in the app. An imported invoice keeps the prefix it was issued with and does not block a change. The scheme switch
--     refusal (migration 162) still counts every invoice, imported ones included, since they take part in the numbering.
--
-- Patched in place by marker count (these functions have no definition file); a second run fails on the count. No role is created,
-- altered or dropped.

-- ===== 1. the sentence, the refusal and the table guard =====
CREATE FUNCTION warehouse_security.imported_read_only_sentence(p_document text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT format('This %s was imported from the previous system and can''t be changed.',
                CASE p_document WHEN 'grn' THEN 'GRN' ELSE p_document END)
$$;
ALTER FUNCTION warehouse_security.imported_read_only_sentence(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.imported_read_only_sentence(text) FROM PUBLIC;

-- The early refusal of the RPCs (the shape of warehouse_security.refuse, migration 121).
CREATE FUNCTION warehouse_security.imported_read_only(p_document text) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT warehouse_security.refuse('IMPORTED_READ_ONLY', warehouse_security.imported_read_only_sentence(p_document),
                                   jsonb_build_object('document', p_document))
$$;
ALTER FUNCTION warehouse_security.imported_read_only(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.imported_read_only(text) FROM PUBLIC;

CREATE FUNCTION warehouse_security.refuse_imported_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_document text;
  v_old_parent uuid;
  v_new_parent uuid;
  v_old_imported boolean := false;
  v_new_imported boolean := false;
BEGIN
  -- The import itself (migration 192) writes imported documents.
  IF current_setting('warehouse.import', true) = 'on' THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
  END IF;

  -- A document.
  IF TG_TABLE_NAME IN ('goodsreceived', 'dispatch', 'invoice', 'payments') THEN
    v_document := CASE TG_TABLE_NAME WHEN 'goodsreceived' THEN 'grn' WHEN 'payments' THEN 'payment' ELSE TG_TABLE_NAME END;
    IF TG_OP = 'INSERT' THEN
      IF NEW.import_batch_id IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'WH423', MESSAGE = 'Only the import sets or clears the Imported mark.',
          HINT = 'IMPORTED_READ_ONLY';
      END IF;
      RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' THEN
      IF NEW.import_batch_id IS DISTINCT FROM OLD.import_batch_id THEN
        RAISE EXCEPTION USING ERRCODE = 'WH423', MESSAGE = 'Only the import sets or clears the Imported mark.',
          HINT = 'IMPORTED_READ_ONLY';
      END IF;
    END IF;
    IF OLD.import_batch_id IS NULL THEN
      IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
      RETURN NEW;
    END IF;
    -- An imported GRN keeps its live flags up to date.
    IF TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'goodsreceived'
       AND (to_jsonb(NEW) - ARRAY['invoiced', 'out_of_stock', 'updated_at', 'updated_by'])
           = (to_jsonb(OLD) - ARRAY['invoiced', 'out_of_stock', 'updated_at', 'updated_by']) THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'WH423', MESSAGE = warehouse_security.imported_read_only_sentence(v_document),
      HINT = 'IMPORTED_READ_ONLY';
  END IF;

  -- A line or a photo: the mark is its document's. (Each table's column is read in its own branch: a record has only its own fields.)
  IF TG_TABLE_NAME = 'goodsreceived_trl' THEN
    v_document := 'grn';
    IF TG_OP <> 'INSERT' THEN v_old_parent := OLD.gr_id; END IF;
    IF TG_OP <> 'DELETE' THEN v_new_parent := NEW.gr_id; END IF;
  ELSIF TG_TABLE_NAME = 'grn_images' THEN
    v_document := 'grn';
    IF TG_OP <> 'INSERT' THEN v_old_parent := OLD.grn_id; END IF;
    IF TG_OP <> 'DELETE' THEN v_new_parent := NEW.grn_id; END IF;
  ELSIF TG_TABLE_NAME = 'dispatch_trl' THEN
    v_document := 'dispatch';
    IF TG_OP <> 'INSERT' THEN v_old_parent := OLD.disp_id; END IF;
    IF TG_OP <> 'DELETE' THEN v_new_parent := NEW.disp_id; END IF;
  ELSIF TG_TABLE_NAME = 'dispatch_images' THEN
    v_document := 'dispatch';
    IF TG_OP <> 'INSERT' THEN v_old_parent := OLD.dispatch_id; END IF;
    IF TG_OP <> 'DELETE' THEN v_new_parent := NEW.dispatch_id; END IF;
  ELSIF TG_TABLE_NAME = 'invoice_trl' THEN
    v_document := 'invoice';
    IF TG_OP <> 'INSERT' THEN v_old_parent := OLD.invoice_id; END IF;
    IF TG_OP <> 'DELETE' THEN v_new_parent := NEW.invoice_id; END IF;
  ELSE
    RAISE EXCEPTION 'refuse_imported_change is not set up for table %', TG_TABLE_NAME;
  END IF;
  IF v_document = 'grn' THEN
    SELECT EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = v_old_parent AND g.import_batch_id IS NOT NULL),
           EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = v_new_parent AND g.import_batch_id IS NOT NULL)
      INTO v_old_imported, v_new_imported;
  ELSIF v_document = 'dispatch' THEN
    SELECT EXISTS (SELECT 1 FROM public.dispatch d WHERE d.id = v_old_parent AND d.import_batch_id IS NOT NULL),
           EXISTS (SELECT 1 FROM public.dispatch d WHERE d.id = v_new_parent AND d.import_batch_id IS NOT NULL)
      INTO v_old_imported, v_new_imported;
  ELSE
    SELECT EXISTS (SELECT 1 FROM public.invoice i WHERE i.id = v_old_parent AND i.import_batch_id IS NOT NULL),
           EXISTS (SELECT 1 FROM public.invoice i WHERE i.id = v_new_parent AND i.import_batch_id IS NOT NULL)
      INTO v_old_imported, v_new_imported;
  END IF;

  IF v_old_imported THEN
    -- An imported GRN line's stock follows app dispatches from it; nothing else of an imported line changes (its document included).
    IF NOT (TG_OP = 'UPDATE' AND TG_TABLE_NAME = 'goodsreceived_trl'
            AND (to_jsonb(NEW) - 'stock') = (to_jsonb(OLD) - 'stock')) THEN
      RAISE EXCEPTION USING ERRCODE = 'WH423', MESSAGE = warehouse_security.imported_read_only_sentence(v_document),
        HINT = 'IMPORTED_READ_ONLY';
    END IF;
  ELSIF v_new_imported THEN
    -- Added to, or moved into, an imported document.
    RAISE EXCEPTION USING ERRCODE = 'WH423', MESSAGE = warehouse_security.imported_read_only_sentence(v_document),
      HINT = 'IMPORTED_READ_ONLY';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;
ALTER FUNCTION warehouse_security.refuse_imported_change() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.refuse_imported_change() FROM PUBLIC;

CREATE TRIGGER guard_imported_read_only BEFORE INSERT OR UPDATE OR DELETE ON public.goodsreceived
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.refuse_imported_change();
CREATE TRIGGER guard_imported_read_only BEFORE INSERT OR UPDATE OR DELETE ON public.goodsreceived_trl
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.refuse_imported_change();
CREATE TRIGGER guard_imported_read_only BEFORE INSERT OR UPDATE OR DELETE ON public.dispatch
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.refuse_imported_change();
CREATE TRIGGER guard_imported_read_only BEFORE INSERT OR UPDATE OR DELETE ON public.dispatch_trl
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.refuse_imported_change();
CREATE TRIGGER guard_imported_read_only BEFORE INSERT OR UPDATE OR DELETE ON public.invoice
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.refuse_imported_change();
CREATE TRIGGER guard_imported_read_only BEFORE INSERT OR UPDATE OR DELETE ON public.invoice_trl
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.refuse_imported_change();
CREATE TRIGGER guard_imported_read_only BEFORE INSERT OR UPDATE OR DELETE ON public.payments
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.refuse_imported_change();
CREATE TRIGGER guard_imported_read_only BEFORE INSERT ON public.grn_images
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.refuse_imported_change();
CREATE TRIGGER guard_imported_read_only BEFORE INSERT ON public.dispatch_images
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.refuse_imported_change();

-- ===== the patch helper =====
-- As migration 184's: each marker is found once, and a replacement may not contain its marker (so a second run fails on the count).
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

-- ===== 2. early refusals =====
-- Each marker is the function's authorize_rpc line and the line after it; the refusal goes between them.

SELECT pg_temp.patch_function('public.get_grn_edit_state(uuid)'::regprocedure, ARRAY[
$m$    PERFORM warehouse_security.authorize_rpc('get_grn_edit_state', jsonb_build_object('p_grn_id', p_grn_id));

    -- The token is read before the lines$m$
], ARRAY[
$m$    PERFORM warehouse_security.authorize_rpc('get_grn_edit_state', jsonb_build_object('p_grn_id', p_grn_id));
    -- Migration 190 (WH-180): an imported GRN has no edit state; the answer is the refusal of an edit.
    IF EXISTS (SELECT 1 FROM goodsreceived g WHERE g.id = p_grn_id AND g.import_batch_id IS NOT NULL) THEN
        RETURN warehouse_security.imported_read_only('grn');
    END IF;

    -- The token is read before the lines$m$
]);

SELECT pg_temp.patch_function('public.delete_dispatch_with_order_cleanup(uuid, uuid)'::regprocedure, ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('delete_dispatch_with_order_cleanup',jsonb_build_object('p_dispatch_id',p_dispatch_id));
    -- The list-refresh lock comes before any row lock (migration 46).$m$
], ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('delete_dispatch_with_order_cleanup',jsonb_build_object('p_dispatch_id',p_dispatch_id));
    -- Migration 190 (WH-180): an imported dispatch is read-only; nothing is written.
    IF EXISTS (SELECT 1 FROM dispatch d WHERE d.id = p_dispatch_id AND d.import_batch_id IS NOT NULL) THEN
        RETURN warehouse_security.imported_read_only('dispatch');
    END IF;
    -- The list-refresh lock comes before any row lock (migration 46).$m$
]);

SELECT pg_temp.patch_function('public.update_invoice(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('update_invoice',jsonb_build_object('p_invoice_id',p_invoice_id));
    -- The list-refresh lock comes before any row lock (migration 46).$m$
], ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('update_invoice',jsonb_build_object('p_invoice_id',p_invoice_id));
    -- Migration 190 (WH-180): an imported invoice is read-only; nothing is written.
    IF EXISTS (SELECT 1 FROM invoice i WHERE i.id = p_invoice_id AND i.import_batch_id IS NOT NULL) THEN
        RETURN warehouse_security.imported_read_only('invoice');
    END IF;
    -- The list-refresh lock comes before any row lock (migration 46).$m$
]);

SELECT pg_temp.patch_function('public.cancel_invoice(uuid, text, timestamp with time zone)'::regprocedure, ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('cancel_invoice', jsonb_build_object('p_invoice_id', p_invoice_id));
  -- Administrators and supervisors$m$
], ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('cancel_invoice', jsonb_build_object('p_invoice_id', p_invoice_id));
  -- Migration 190 (WH-180): an imported invoice is not cancelled (a cancel is an edit); nothing is written.
  IF EXISTS (SELECT 1 FROM invoice i WHERE i.id = p_invoice_id AND i.import_batch_id IS NOT NULL) THEN
    RETURN warehouse_security.imported_read_only('invoice');
  END IF;
  -- Administrators and supervisors$m$
]);

SELECT pg_temp.patch_function('public.delete_invoice(uuid, timestamp with time zone)'::regprocedure, ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('delete_invoice', jsonb_build_object('p_invoice_id', p_invoice_id));
  -- Administrators and supervisors$m$
], ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('delete_invoice', jsonb_build_object('p_invoice_id', p_invoice_id));
  -- Migration 190 (WH-180): an imported invoice is read-only; nothing is written.
  IF EXISTS (SELECT 1 FROM invoice i WHERE i.id = p_invoice_id AND i.import_batch_id IS NOT NULL) THEN
    RETURN warehouse_security.imported_read_only('invoice');
  END IF;
  -- Administrators and supervisors$m$
]);

SELECT pg_temp.patch_function('public.delete_invoice_pair(uuid, timestamp with time zone, timestamp with time zone)'::regprocedure, ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('delete_invoice_pair', jsonb_build_object('p_invoice_id', p_invoice_id));
  IF COALESCE$m$
], ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('delete_invoice_pair', jsonb_build_object('p_invoice_id', p_invoice_id));
  -- Migration 190 (WH-180): an imported invoice is read-only (and never one of a pair); nothing is written.
  IF EXISTS (SELECT 1 FROM invoice i WHERE i.id = p_invoice_id AND i.import_batch_id IS NOT NULL) THEN
    RETURN warehouse_security.imported_read_only('invoice') || jsonb_build_object('deleted', 0);
  END IF;
  IF COALESCE$m$
]);

SELECT pg_temp.patch_function('public.update_payment(uuid, date, numeric, text, timestamp with time zone, text, text)'::regprocedure, ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('update_payment', jsonb_build_object('p_id', p_id));
  IF COALESCE$m$
], ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('update_payment', jsonb_build_object('p_id', p_id));
  -- Migration 190 (WH-180): an imported payment is read-only; nothing is written. An app payment on an imported invoice is not imported.
  IF EXISTS (SELECT 1 FROM public.payments p WHERE p.id = p_id AND p.import_batch_id IS NOT NULL) THEN
    RETURN warehouse_security.imported_read_only('payment');
  END IF;
  IF COALESCE$m$
]);

SELECT pg_temp.patch_function('public.delete_payment(uuid, timestamp with time zone, text)'::regprocedure, ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('delete_payment', jsonb_build_object('p_id', p_id));
  IF COALESCE$m$
], ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('delete_payment', jsonb_build_object('p_id', p_id));
  -- Migration 190 (WH-180): an imported payment is read-only (answered before PAYMENT_NOT_EDITABLE); nothing is written. An app payment
  -- on an imported invoice is not imported.
  IF EXISTS (SELECT 1 FROM public.payments p WHERE p.id = p_id AND p.import_batch_id IS NOT NULL) THEN
    RETURN warehouse_security.imported_read_only('payment');
  END IF;
  IF COALESCE$m$
]);

SELECT pg_temp.patch_function('public.delete_grn_image(uuid)'::regprocedure, ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('delete_grn_image',jsonb_build_object('p_image_id',p_image_id));
    v_user_id := auth.uid();$m$
], ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('delete_grn_image',jsonb_build_object('p_image_id',p_image_id));
    -- Migration 190 (WH-180): the photos of an imported GRN are read-only; nothing is written.
    IF EXISTS (SELECT 1 FROM grn_images gi JOIN goodsreceived g ON g.id = gi.grn_id
               WHERE gi.id = p_image_id AND g.import_batch_id IS NOT NULL) THEN
        RETURN warehouse_security.imported_read_only('grn');
    END IF;
    v_user_id := auth.uid();$m$
]);

SELECT pg_temp.patch_function('public.delete_dispatch_image(uuid)'::regprocedure, ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('delete_dispatch_image',jsonb_build_object('p_image_id',p_image_id));
    v_user_id := auth.uid();$m$
], ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('delete_dispatch_image',jsonb_build_object('p_image_id',p_image_id));
    -- Migration 190 (WH-180): the photos of an imported dispatch are read-only; nothing is written.
    IF EXISTS (SELECT 1 FROM dispatch_images di JOIN dispatch d ON d.id = di.dispatch_id
               WHERE di.id = p_image_id AND d.import_batch_id IS NOT NULL) THEN
        RETURN warehouse_security.imported_read_only('dispatch');
    END IF;
    v_user_id := auth.uid();$m$
]);

SELECT pg_temp.patch_function('public.register_grn_image_upload(uuid, text, text, integer, text, uuid)'::regprocedure, ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('register_grn_image_upload',jsonb_build_object('p_grn_id',p_grn_id,'p_grn_item_id',p_grn_item_id));
    -- 1. Authenticate user$m$
], ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('register_grn_image_upload',jsonb_build_object('p_grn_id',p_grn_id,'p_grn_item_id',p_grn_item_id));
    -- Migration 190 (WH-180): no photo is added to an imported GRN; nothing is written.
    IF EXISTS (SELECT 1 FROM goodsreceived g WHERE g.id = p_grn_id AND g.import_batch_id IS NOT NULL) THEN
        RETURN warehouse_security.imported_read_only('grn');
    END IF;
    -- 1. Authenticate user$m$
]);

SELECT pg_temp.patch_function('public.register_dispatch_image_upload(uuid, text, integer, text)'::regprocedure, ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('register_dispatch_image_upload',jsonb_build_object('p_dispatch_id',p_dispatch_id));
    -- 1. Authenticate user$m$
], ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('register_dispatch_image_upload',jsonb_build_object('p_dispatch_id',p_dispatch_id));
    -- Migration 190 (WH-180): no photo is added to an imported dispatch; nothing is written.
    IF EXISTS (SELECT 1 FROM dispatch d WHERE d.id = p_dispatch_id AND d.import_batch_id IS NOT NULL) THEN
        RETURN warehouse_security.imported_read_only('dispatch');
    END IF;
    -- 1. Authenticate user$m$
]);

SELECT pg_temp.patch_function('public.upload_grn_image(uuid, character varying, text, text, integer, character varying, uuid, uuid)'::regprocedure, ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('upload_grn_image',jsonb_build_object('p_grn_id',p_grn_id,'p_grn_item_id',p_grn_item_id));
    v_user_id := auth.uid();$m$
], ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('upload_grn_image',jsonb_build_object('p_grn_id',p_grn_id,'p_grn_item_id',p_grn_item_id));
    -- Migration 190 (WH-180): no photo is added to an imported GRN; nothing is written.
    IF EXISTS (SELECT 1 FROM goodsreceived g WHERE g.id = p_grn_id AND g.import_batch_id IS NOT NULL) THEN
        RETURN warehouse_security.imported_read_only('grn');
    END IF;
    v_user_id := auth.uid();$m$
]);

SELECT pg_temp.patch_function('public.upload_dispatch_image(uuid, text, text, integer, character varying, uuid)'::regprocedure, ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('upload_dispatch_image',jsonb_build_object('p_dispatch_id',p_dispatch_id));
    v_user_id := auth.uid();$m$
], ARRAY[
$m$  PERFORM warehouse_security.authorize_rpc('upload_dispatch_image',jsonb_build_object('p_dispatch_id',p_dispatch_id));
    -- Migration 190 (WH-180): no photo is added to an imported dispatch; nothing is written.
    IF EXISTS (SELECT 1 FROM dispatch d WHERE d.id = p_dispatch_id AND d.import_batch_id IS NOT NULL) THEN
        RETURN warehouse_security.imported_read_only('dispatch');
    END IF;
    v_user_id := auth.uid();$m$
]);

-- ===== 3. the import's own inserts skip per-row audit, invoiced sync and discount audit =====
SELECT pg_temp.patch_function('public.audit_trigger_func()'::regprocedure, ARRAY[
$m$BEGIN
    INSERT INTO public.audit_log (table_name, action, user_id, old_data, new_data)$m$
], ARRAY[
$m$BEGIN
    -- Migration 190 (WH-180): the import of past years records one audit row per batch, not one per imported row.
    IF TG_OP = 'INSERT' AND current_setting('warehouse.import', true) = 'on'
       AND TG_TABLE_NAME IN ('goodsreceived', 'goodsreceived_trl', 'dispatch', 'dispatch_trl', 'invoice', 'invoice_trl', 'payments') THEN
        RETURN NEW;
    END IF;
    INSERT INTO public.audit_log (table_name, action, user_id, old_data, new_data)$m$
]);

SELECT pg_temp.patch_function('warehouse_security.sync_grn_invoiced_trigger()'::regprocedure, ARRAY[
$m$BEGIN
  IF NOT warehouse_security.invoice_as_goods_leave() THEN$m$
], ARRAY[
$m$BEGIN
  -- Migration 190 (WH-180): the import of past years works out the invoiced flags of the GRNs it touches in one statement.
  IF TG_OP = 'INSERT' AND current_setting('warehouse.import', true) = 'on' THEN
    RETURN NULL;
  END IF;
  IF NOT warehouse_security.invoice_as_goods_leave() THEN$m$
]);

SELECT pg_temp.patch_function('warehouse_security.invoice_discount_audit()'::regprocedure, ARRAY[
$m$BEGIN
  IF COALESCE(NEW.discount, 0) = previous THEN$m$
], ARRAY[
$m$BEGIN
  -- Migration 190 (WH-180): an imported invoice's discount is as issued; the import writes no discount history.
  IF TG_OP = 'INSERT' AND current_setting('warehouse.import', true) = 'on' THEN
    RETURN NEW;
  END IF;
  IF COALESCE(NEW.discount, 0) = previous THEN$m$
]);

-- ===== 4. the invoice prefix may change mid-year over imported invoices =====
SELECT pg_temp.patch_function('warehouse_security.apply_document_numbering(text, jsonb, uuid)'::regprocedure, ARRAY[
$m$                 WHERE i.inv_fin_year = warehouse_security.financial_year(warehouse_security.business_date(now()))) THEN
    RETURN warehouse_security.refuse('NUMBERING_PREFIX_MID_YEAR',$m$
], ARRAY[
$m$                 WHERE i.inv_fin_year = warehouse_security.financial_year(warehouse_security.business_date(now()))
                   -- Migration 190 (WH-180): an imported invoice keeps the prefix it was issued with and does not count here.
                   AND i.import_batch_id IS NULL) THEN
    RETURN warehouse_security.refuse('NUMBERING_PREFIX_MID_YEAR',$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
