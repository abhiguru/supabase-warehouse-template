-- Owner decisions on dispatch, GRN, invoice and order writes (2026-10-20, "wave B"): server side of D1 to D18 and D23, D24.
-- D19 (order line card) and D14 (invoice delete question) are in the app only; D7 changes nothing in code (documented); D20
-- and D22 are migration 120; D21 was dropped; D16 (corrected): a deactivated business may still order and be dispatched, only a
-- new GRN is refused, and that refusal exists since migrations 80 to 84, so nothing changes in code. No data is changed here: the new invoice column and the new
-- triggers apart, every rule below that would refuse existing rows only refuses an edit of them; a read-only count of the rows
-- each rule touches is run before the deploy and is not part of this file.
--
--  * One shape for every new refusal (warehouse_security.refuse): {success:false, error_code:'WH409', reason, error, message,
--    ...fields}. Before a function's first write it is returned; after a write (the rate and total checks) it is raised as
--    'rate_fail' with the refusal in DETAIL, which the handler of save_grn / update_grn / save_invoice_internal / update_invoice
--    answers after rolling the block back.
--  * D1 stale edits: the version token is updated_at (new invoice.updated_at with the usual trigger). update_dispatch_smart and
--    update_invoice read expected_updated_at in their data object; update_grn, update_order_item_quantity and
--    remove_item_from_order take a trailing p_expected_updated_at (old signatures dropped, no overload). Refusal STALE_RECORD
--    (what, id, expected_updated_at, current_updated_at), nothing written. Absent token: no check. Every check runs after the
--    saved-answer replay of a request code / idempotency key, so a resend of one's own lost save is never refused. Every
--    success answer carries the new token; get_invoice_detail and get_invoice_data return the invoice's; the new
--    get_grn_edit_state returns the GRN's with its lines' locks (D2, D3, D9, D11), read token first.
--  * D2 locks: update_grn LOT_INVOICED (item, packing, weight of an invoiced lot) and LOT_DISPATCHED (item, packing of a
--    dispatched lot; a dispatched lot keeps its stored name); update_dispatch_smart DISPATCH_INVOICED (date and number of a
--    dispatch with a line on a live invoice).
--  * D3 dates (IST days): dispatch create and edit DISPATCH_DATE_FUTURE and DISPATCH_BEFORE_GRN (an edit only when its day
--    changes, else only for added lines, so a legacy back-dated dispatch stays editable); update_grn GRN_DATE_AFTER_DISPATCH.
--    D23: GRN_DATE_LOCKED when the date of an invoiced GRN changes.
--  * D4 order in step: restore_to_order (the give-back loop of the dispatch delete, shared); delete gives back at most what
--    the line holds and writes the dispatch_deleted entry for every cart that got something back; an edit gives back on a
--    lowered or removed line and takes from the order on a raised or added one (answer: order_sync {given_back, taken}); what a
--    dispatch takes (create from an order, direct create, edit) is logged as auto_quantity_reduction; what an edit gives back
--    as one UPDATE entry per order.
--  * D5 dispatch create from an order: source_order_updated_at in p_dispatch_data, ORDER_CHANGED when the order moved.
--  * D6 GRN_NUMBER_LOCKED. D8 get_next_grn_number follows the highest letter. D9 GRN_HAS_STOCK on invoice save and edit and
--    GRN_INVOICED for a new line on an invoiced GRN. D10 RATES_NEED_MANAGER (staff) and D24 RATES_WOULD_DROP (administrators
--    and supervisors) when an edit drops a rate set for the GRN alone. D11 LINE_DISPATCHED_BEFORE and LINE_ON_ORDER.
--  * D12 audit triggers on goodsreceived and goodsreceived_trl. D13 registration_too_long (legacy GRN shape). D15 rack and
--    package mark stored with the digits 0-9 (warehouse_security.ascii_digits). D18 TOTAL_CHANGED from save_invoice (3 arguments)
--    and update_invoice.
--
-- Every function is the latest definition (migration 120, else 119, else the baseline) with only the changes above, as in
-- migration 120. save_grn and authorize_rpc and the two invoice reads are patched with the marker-count pattern of
-- migration 111; update_grn, update_order_item_quantity and remove_item_from_order are dropped and made again.

-- Section 2: the refusal helper and the invoice's version token
-- The one shape of a named refusal (migration 121): reason, English sentence, and the fields the app reads, all at the top
-- level. error and message carry the same sentence (the GRN and order callers read message).
CREATE OR REPLACE FUNCTION warehouse_security.refuse(p_reason text, p_error text, p_data jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT COALESCE(p_data, '{}'::jsonb)
         || jsonb_build_object('success', false, 'error_code', 'WH409', 'reason', p_reason, 'error', p_error, 'message', p_error)
$$;
ALTER FUNCTION warehouse_security.refuse(p_reason text, p_error text, p_data jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.refuse(p_reason text, p_error text, p_data jsonb) FROM PUBLIC;

-- D1: the version token of an invoice. The other three records have theirs (dispatch.updated_at, goodsreceived.updated_at,
-- order_items.updated_at). Existing rows get the migration time: one token for every existing invoice until each is
-- edited. The app role has no column grant on it (migration 48 lists the readable columns); it is read only through the RPCs.
ALTER TABLE public.invoice ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
CREATE TRIGGER trigger_invoice_updated_at BEFORE UPDATE ON public.invoice FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- Section 3: GRN edit state, the gate, the invoice reads, the GRN number suggestion
-- D1, D2, D3, D9, D11: what the GRN edit form needs before it opens: the version token (read first), the invoice of the GRN,
-- the first dispatch day, and per line what is dispatched, invoiced or ordered. Staff and above (customers get "Staff access
-- required" from the gate).
CREATE OR REPLACE FUNCTION public.get_grn_edit_state(p_grn_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_grn record;
    v_invoice jsonb;
    v_first_day text;
    v_lines jsonb;
BEGIN
    PERFORM warehouse_security.authorize_rpc('get_grn_edit_state', jsonb_build_object('p_grn_id', p_grn_id));

    -- The token is read before the lines: a change that lands in between shows in the lines but not in the token, so
    -- the next save is refused as stale, never accepted over it.
    SELECT g.id, g.gr_no, g.date, g.updated_at, g.customer_name
    INTO v_grn
    FROM goodsreceived g
    WHERE g.id = p_grn_id AND g.deleted_at IS NULL;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'GRN not found', 'message', 'GRN not found');
    END IF;

    SELECT jsonb_build_object('id', i.id, 'inv_no', i.inv_no, 'inv_fin_year', i.inv_fin_year)
    INTO v_invoice
    FROM invoice i
    WHERE i.gr_id = p_grn_id AND i.deleted_at IS NULL
    ORDER BY i.inv_fin_year, i.inv_no, i.id
    LIMIT 1;

    SELECT to_char(warehouse_security.business_date(d.disp_date), 'YYYY-MM-DD')
    INTO v_first_day
    FROM dispatch_trl dt
    JOIN dispatch d ON d.id = dt.disp_id AND d.deleted_at IS NULL
    WHERE dt.gr_id = p_grn_id AND d.disp_date IS NOT NULL
    ORDER BY warehouse_security.business_date(d.disp_date), d.disp_date
    LIMIT 1;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id', t.id,
               'dispatched_qty', COALESCE((SELECT SUM(dt.disp_qty) FROM dispatch_trl dt WHERE dt.gr_trl_id = t.id), 0),
               'has_history', EXISTS (SELECT 1 FROM dispatch_trl dt WHERE dt.gr_trl_id = t.id)
                              OR EXISTS (SELECT 1 FROM stock_movements m WHERE m.gr_trl_id = t.id),
               'on_invoice', inv.inv_no IS NOT NULL,
               'invoice_no', inv.inv_no,
               'inv_fin_year', inv.inv_fin_year,
               'on_order', EXISTS (SELECT 1 FROM order_items oi
                                   JOIN orders o ON o.id = oi.order_id AND o.deleted_at IS NULL
                                   WHERE oi.grn_items_id = t.id),
               'order_customer_name', v_grn.customer_name
           ) ORDER BY uuid_extract_timestamp(t.id), t.id), '[]'::jsonb)
    INTO v_lines
    FROM goodsreceived_trl t
    LEFT JOIN LATERAL (
        SELECT i.inv_no, i.inv_fin_year
        FROM invoice_trl it
        JOIN dispatch_trl dt ON dt.id = it.disp_trl_id
        JOIN invoice i ON i.id = it.invoice_id AND i.deleted_at IS NULL
        WHERE dt.gr_trl_id = t.id
        ORDER BY i.inv_fin_year, i.inv_no, i.id
        LIMIT 1
    ) inv ON true
    WHERE t.gr_id = p_grn_id;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'grn_id', v_grn.id,
            'gr_no', v_grn.gr_no,
            'date', v_grn.date,
            'updated_at', v_grn.updated_at,
            'invoice', v_invoice,
            'first_dispatch_date', v_first_day,
            'lines', v_lines
        )
    );
END;
$$;
ALTER FUNCTION public.get_grn_edit_state(p_grn_id uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_grn_edit_state(p_grn_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_grn_edit_state(p_grn_id uuid) TO service_role;
GRANT ALL ON FUNCTION public.get_grn_edit_state(p_grn_id uuid) TO authenticated;

-- D2: authorize_rpc lets staff call get_grn_edit_state

DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$    'get_all_grn_items','get_grn_list','get_grn_details','get_grn_item_dispatches',
$m$
  ];
  v_new constant text[] := ARRAY[
    $m$    'get_all_grn_items','get_grn_list','get_grn_details',
    -- The GRN edit form's version and locks (migration 121); customers stay refused by the final ELSE.
    'get_grn_edit_state','get_grn_item_dispatches',
$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('warehouse_security.authorize_rpc(text, jsonb)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'authorize_rpc: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- D1: get_invoice_detail returns the invoice's version token

DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$        'notes', i.notes, 'created_by', i.created_by,
        'grn_pricing_mode',$m$
  ];
  v_new constant text[] := ARRAY[
    $m$        'notes', i.notes, 'created_by', i.created_by,
        'updated_at', i.updated_at,
        'grn_pricing_mode',$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.get_invoice_detail(uuid)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'get_invoice_detail: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- D1: get_invoice_data returns the invoice's version token in its header

DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$            i.notes,
            i.created_by,

            c.address as customer_address,$m$,
    $m$                    'created_by', v_invoice_header.created_by,

                    'customer', jsonb_build_object($m$
  ];
  v_new constant text[] := ARRAY[
    $m$            i.notes,
            i.created_by,
            i.updated_at as invoice_updated_at,

            c.address as customer_address,$m$,
    $m$                    'created_by', v_invoice_header.created_by,
                    'updated_at', v_invoice_header.invoice_updated_at,

                    'customer', jsonb_build_object($m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.get_invoice_data(uuid)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'get_invoice_data: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

-- D8: the GRN number suggested is the next one of the highest letter in use
CREATE OR REPLACE FUNCTION public.get_next_grn_number() RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $_$
DECLARE
    v_prefix CHAR(1);
    v_num INTEGER;
    v_next_prefix CHAR(1);
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_next_grn_number',jsonb_build_object());
    -- The letter is the highest one in use (migration 121), not the letter of the GRN entered last: a GRN entered under
    -- an older letter later does not send the suggestion back to that series.
    SELECT max(LEFT(gr_no, 1) COLLATE "C") INTO v_prefix
    FROM goodsreceived
    WHERE gr_no ~ '^[A-Z][0-9]{1,7}$';

    IF v_prefix IS NULL THEN
        RETURN 'A0001';
    END IF;

    -- Find the actual max number within the current prefix series
    SELECT COALESCE(MAX(CAST(SUBSTRING(gr_no FROM 2) AS INTEGER)), 0)
    INTO v_num
    FROM goodsreceived
    WHERE LEFT(gr_no, 1) = v_prefix AND gr_no ~ '^[A-Z][0-9]{1,7}$';

    IF v_num >= 1000 THEN
        -- Advance to next letter: A→B→...→Z→A
        IF v_prefix = 'Z' THEN
            v_next_prefix := 'A';
        ELSE
            v_next_prefix := CHR(ASCII(v_prefix) + 1);
        END IF;
        RETURN v_next_prefix || '0001';
    ELSE
        RETURN v_prefix || LPAD((v_num + 1)::TEXT, 4, '0');
    END IF;
END;
$_$;
-- Section 4: GRN history
-- D12: GRN history. The audit function of customers, dispatches and orders now also keeps every insert and delete of a GRN
-- and of its lines, and every edit that changes more than the derived flags (out_of_stock, invoiced, updated_*) of a GRN or
-- more than the stock of a line (every dispatch moves the stock; stock_movements already records it). Two triggers per
-- table: an UPDATE trigger with a WHEN cannot also cover INSERT and DELETE. delete_grn_safe still hard-deletes; the
-- DELETE triggers keep a copy of the GRN and of each line. update_grn disables only trg_mark_stock_mvs_dirty_grn
-- (safe_disable_grn_trl_triggers), so these stay on. History starts at the deploy.
CREATE TRIGGER audit_goodsreceived AFTER INSERT OR DELETE ON public.goodsreceived FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER audit_goodsreceived_update AFTER UPDATE ON public.goodsreceived FOR EACH ROW
  WHEN ((to_jsonb(OLD) - ARRAY['updated_at','updated_by','out_of_stock','invoiced']) IS DISTINCT FROM (to_jsonb(NEW) - ARRAY['updated_at','updated_by','out_of_stock','invoiced']))
  EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER audit_goodsreceived_trl AFTER INSERT OR DELETE ON public.goodsreceived_trl FOR EACH ROW EXECUTE FUNCTION public.audit_trigger_func();
CREATE TRIGGER audit_goodsreceived_trl_update AFTER UPDATE ON public.goodsreceived_trl FOR EACH ROW
  WHEN ((to_jsonb(OLD) - 'stock') IS DISTINCT FROM (to_jsonb(NEW) - 'stock'))
  EXECUTE FUNCTION public.audit_trigger_func();

-- Section 5: order lines
-- D1: add_item_to_order returns the new line's version token
CREATE OR REPLACE FUNCTION public.add_item_to_order(p_order_id uuid, p_grn_item_id uuid, p_quantity integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'warehouse_security', 'pg_temp'
    AS $$
DECLARE
  v_user_id uuid;
  v_order record;
  v_item record;
  v_new_item_id uuid;
  v_new_item_updated_at timestamptz;
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
  ) RETURNING id, updated_at INTO v_new_item_id, v_new_item_updated_at;

  PERFORM warehouse_security.record_order_revision(p_order_id, v_user_id);
  UPDATE public.orders SET updated_at = now(), updated_by = v_user_id WHERE id = p_order_id;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Item added to order successfully',
    'data', jsonb_build_object(
      'order_item_id', v_new_item_id,
      'item_name', v_item.item_name,
      'quantity', p_quantity,
      'order_no', v_order_no,
      'updated_at', v_new_item_updated_at
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
-- D1: update_order_item_quantity takes the version token of the line (p_expected_updated_at). A new trailing parameter needs
-- the old signature dropped (an overload would make the call ambiguous).
DROP FUNCTION public.update_order_item_quantity(uuid, integer);
CREATE FUNCTION public.update_order_item_quantity(p_order_item_id uuid, p_new_quantity integer, p_expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'warehouse_security', 'pg_temp'
    AS $$
DECLARE
  v_user_id uuid;
  v_item record;
  v_stock integer;
  v_new_updated_at timestamptz;
BEGIN
  PERFORM warehouse_security.authorize_rpc(
    'update_order_item_quantity',
    jsonb_build_object('p_order_item_id', p_order_item_id)
  );

  IF p_new_quantity IS NULL OR p_new_quantity <= 0 THEN
    RETURN jsonb_build_object('success', false, 'message', 'Quantity must be greater than zero');
  END IF;

  SELECT id INTO v_user_id
  FROM public.user_profiles
  WHERE auth_user_id = auth.uid() AND active;

  SELECT oi.id, oi.order_id, oi.requested_quantity, oi.fulfilled_quantity,
         oi.grn_items_id, oi.grn_items_item_name, o.status, o.deleted_at,
         oi.updated_at AS line_updated_at
  INTO v_item
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE oi.id = p_order_item_id
  FOR UPDATE OF oi;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Order item not found');
  END IF;
  -- D1 (migration 121): a line that changed after the caller read it is not saved over. Absent token: no check
  -- (an older app).
  IF p_expected_updated_at IS NOT NULL
     AND date_trunc('milliseconds', v_item.line_updated_at) IS DISTINCT FROM date_trunc('milliseconds', p_expected_updated_at) THEN
    RETURN warehouse_security.refuse('STALE_RECORD', 'Someone else changed this order line. Open it again.',
      jsonb_build_object('what', 'order_line', 'id', p_order_item_id,
                         'expected_updated_at', p_expected_updated_at, 'current_updated_at', v_item.line_updated_at));
  END IF;
  IF v_item.status <> 'OPEN' OR v_item.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Cannot change items on ' || COALESCE(v_item.status, 'closed') || ' orders',
      'error', jsonb_build_object('code', 'ORDER_NOT_OPEN')
    );
  END IF;
  IF p_new_quantity < v_item.fulfilled_quantity THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', format('Quantity cannot be below the %s already dispatched', v_item.fulfilled_quantity)
    );
  END IF;

  SELECT stock INTO v_stock FROM public.goodsreceived_trl WHERE id = v_item.grn_items_id;
  IF COALESCE(v_stock, 0) < p_new_quantity THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', format('Insufficient stock. Available: %s, Requested: %s', COALESCE(v_stock, 0), p_new_quantity)
    );
  END IF;

  UPDATE public.order_items
  SET requested_quantity = p_new_quantity,
      current_stock = v_stock,
      updated_at = now()
  WHERE id = p_order_item_id
  RETURNING updated_at INTO v_new_updated_at;

  PERFORM warehouse_security.record_order_revision(v_item.order_id, v_user_id);
  UPDATE public.orders SET updated_at = now(), updated_by = v_user_id WHERE id = v_item.order_id;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Quantity updated successfully',
    'data', jsonb_build_object(
      'order_item_id', p_order_item_id,
      'old_quantity', v_item.requested_quantity,
      'new_quantity', p_new_quantity,
      'item_name', v_item.grn_items_item_name,
      'updated_at', v_new_updated_at
    )
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error updating quantity: ' || SQLERRM);
END;
$$;
ALTER FUNCTION public.update_order_item_quantity(p_order_item_id uuid, p_new_quantity integer, p_expected_updated_at timestamp with time zone) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.update_order_item_quantity(p_order_item_id uuid, p_new_quantity integer, p_expected_updated_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_order_item_quantity(p_order_item_id uuid, p_new_quantity integer, p_expected_updated_at timestamp with time zone) TO service_role;
GRANT ALL ON FUNCTION public.update_order_item_quantity(p_order_item_id uuid, p_new_quantity integer, p_expected_updated_at timestamp with time zone) TO authenticated;

-- D1: remove_item_from_order takes the version token of the line (p_expected_updated_at).
DROP FUNCTION public.remove_item_from_order(uuid);
CREATE FUNCTION public.remove_item_from_order(p_order_item_id uuid, p_expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'warehouse_security', 'pg_temp'
    AS $$
DECLARE
  v_user_id uuid;
  v_item record;
BEGIN
  PERFORM warehouse_security.authorize_rpc(
    'remove_item_from_order',
    jsonb_build_object('p_order_item_id', p_order_item_id)
  );

  SELECT id INTO v_user_id
  FROM public.user_profiles
  WHERE auth_user_id = auth.uid() AND active;

  SELECT oi.*, o.status AS order_status, o.deleted_at AS order_deleted_at
  INTO v_item
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE oi.id = p_order_item_id
  FOR UPDATE OF oi;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'Order item not found');
  END IF;
  -- D1 (migration 121): a line that changed after the caller read it is not saved over. Absent token: no check
  -- (an older app).
  IF p_expected_updated_at IS NOT NULL
     AND date_trunc('milliseconds', v_item.updated_at) IS DISTINCT FROM date_trunc('milliseconds', p_expected_updated_at) THEN
    RETURN warehouse_security.refuse('STALE_RECORD', 'Someone else changed this order line. Open it again.',
      jsonb_build_object('what', 'order_line', 'id', p_order_item_id,
                         'expected_updated_at', p_expected_updated_at, 'current_updated_at', v_item.updated_at));
  END IF;
  IF v_item.order_status <> 'OPEN' OR v_item.order_deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Cannot remove items from ' || COALESCE(v_item.order_status, 'closed') || ' orders',
      'error', jsonb_build_object('code', 'ORDER_NOT_OPEN')
    );
  END IF;

  DELETE FROM public.order_items WHERE id = p_order_item_id;

  -- The removed lot is recorded at quantity 0 so the change log reports a removal.
  PERFORM warehouse_security.record_order_revision(
    v_item.order_id, v_user_id, 'UPDATE',
    jsonb_build_object('removed_item', jsonb_build_object(
      'item_id', v_item.grn_items_item_id,
      'item_name', v_item.grn_items_item_name,
      'grn_no', v_item.grns_gr_no,
      'package_mark', v_item.grn_items_package_mark,
      'requested_quantity', v_item.requested_quantity,
      'fulfilled_quantity', v_item.fulfilled_quantity)),
    jsonb_build_array(jsonb_build_object(
      'item_id', v_item.grn_items_item_id,
      'item_name', v_item.grn_items_item_name,
      'quantity', 0,
      'grn_no', v_item.grns_gr_no,
      'package_mark', v_item.grn_items_package_mark))
  );
  UPDATE public.orders SET updated_at = now(), updated_by = v_user_id WHERE id = v_item.order_id;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Item removed from order successfully',
    'data', jsonb_build_object(
      'order_item_id', p_order_item_id,
      'removed_item', v_item.grn_items_item_name,
      'removed_quantity', v_item.requested_quantity
    )
  );
EXCEPTION
  WHEN insufficient_privilege THEN RAISE;
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'message', 'Error removing item: ' || SQLERRM);
END;
$$;
ALTER FUNCTION public.remove_item_from_order(p_order_item_id uuid, p_expected_updated_at timestamp with time zone) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.remove_item_from_order(p_order_item_id uuid, p_expected_updated_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.remove_item_from_order(p_order_item_id uuid, p_expected_updated_at timestamp with time zone) TO service_role;
GRANT ALL ON FUNCTION public.remove_item_from_order(p_order_item_id uuid, p_expected_updated_at timestamp with time zone) TO authenticated;

-- Section 6: the dispatch delete and the shared give-back
-- D4: the give-back of a dispatch's quantity to the customer's order, one lot at a time. It is the body of the give-back loop of
-- delete_dispatch_with_order_cleanup (migration 67), moved here unchanged so that a dispatch delete and a dispatch edit give
-- back the same way. The cart is the order the dispatch was made from; else the order of the recorded cart line; else the
-- customer's OPEN order; else a new OPEN order as get_or_create_cart makes it (one_cart_per_customer lets that succeed only
-- when the customer has no order). The lot's line in the cart gets the quantity back, pending and with nothing fulfilled, or
-- a pending line is made again when the dispatch had used it up. Returns the cart's id, NULL when no cart could be used (the
-- customer has an order that is not OPEN or is deleted, so no new one can be made) or when there is nothing to give.
CREATE OR REPLACE FUNCTION warehouse_security.restore_to_order(p_dispatch_id uuid, p_source_order_id uuid, p_source_item_id uuid, p_customer_id uuid, p_lot uuid, p_quantity integer, p_user uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
    v_cart_line record;
    v_restore_cart_id uuid;
    v_dispatch_customer_name text;
BEGIN
    IF COALESCE(p_quantity, 0) <= 0 THEN
        RETURN NULL;
    END IF;

    SELECT
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
    INTO v_cart_line
    FROM goodsreceived_trl gt
    JOIN goodsreceived gr ON gr.id = gt.gr_id
    WHERE gt.id = p_lot;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT d.customer_name INTO v_dispatch_customer_name FROM dispatch d WHERE d.id = p_dispatch_id;

    v_restore_cart_id := COALESCE(
        p_source_order_id,
        (SELECT oi.order_id FROM order_items oi WHERE oi.id = p_source_item_id),
        (SELECT o.id FROM orders o
         WHERE o.customer_id = p_customer_id AND o.status = 'OPEN' AND o.deleted_at IS NULL
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
               p_user, p_user
        FROM customers c
        WHERE c.id = p_customer_id
        ON CONFLICT DO NOTHING
        RETURNING id INTO v_restore_cart_id;
    END IF;

    IF v_restore_cart_id IS NULL THEN
        RETURN NULL;
    END IF;

    UPDATE order_items
    SET
        requested_quantity = requested_quantity + p_quantity,
        fulfilled_quantity = 0,
        item_status = 'pending',
        current_stock = v_cart_line.stock,
        updated_at = now()
    WHERE order_id = v_restore_cart_id
      AND grn_items_id = p_lot;

    IF NOT FOUND THEN
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
            p_quantity,
            0,
            p_lot,
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
            COALESCE(v_cart_line.customer_name, v_dispatch_customer_name, ''),
            v_cart_line.stock,
            v_cart_line.stock,
            'pending',
            COALESCE((SELECT max(oi.sort_order) + 1 FROM order_items oi WHERE oi.order_id = v_restore_cart_id), 1)
        );
    END IF;

    RETURN v_restore_cart_id;
END;
$$;
ALTER FUNCTION warehouse_security.restore_to_order(p_dispatch_id uuid, p_source_order_id uuid, p_source_item_id uuid, p_customer_id uuid, p_lot uuid, p_quantity integer, p_user uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.restore_to_order(p_dispatch_id uuid, p_source_order_id uuid, p_source_item_id uuid, p_customer_id uuid, p_lot uuid, p_quantity integer, p_user uuid) FROM PUBLIC;

-- D4: deleting a dispatch gives back only what its lines still hold, through the shared helper, and logs every cart that got
-- something back
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
    v_rev_cart uuid;
    v_lines_before integer;
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

    -- v_restored_items collects the cart lines actually given back, below (migration 121).

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
    -- At most what the line still holds is given back (migration 121: LEAST of
    -- cart_quantity_consumed and disp_qty; an edit that lowered the line has
    -- already given its share back). warehouse_security.restore_to_order does it,
    -- the same give-back a dispatch edit makes: that quantity is added back to the
    -- cart's line for the lot, pending and with nothing fulfilled, or a pending
    -- line of that quantity is made again when the dispatch used the line up. The
    -- cart is the order the dispatch was made from; for a direct dispatch, the
    -- order of the recorded cart line, else the customer's OPEN cart (the rule the
    -- direct dispatch used to find it), else a new OPEN cart made as
    -- get_or_create_cart makes it. A customer has one order at most
    -- (one_cart_per_customer): when it exists but is not OPEN or is deleted, no
    -- cart can be made, the order is left as it is and the line is counted
    -- (cart_lines_without_open_cart). What is given back, and to which cart, is
    -- collected in v_restored_items for the order's change log below.
    FOR v_cart_line IN
        SELECT
            dt.id,
            dt.gr_trl_id,
            LEAST(COALESCE(dt.cart_quantity_consumed, 0), COALESCE(dt.disp_qty, 0)) AS give_back,
            dt.source_order_item_id,
            gt.item_name,
            gt.package_mark,
            gr.gr_no
        FROM dispatch_trl dt
        JOIN goodsreceived_trl gt ON gt.id = dt.gr_trl_id
        JOIN goodsreceived gr ON gr.id = gt.gr_id
        WHERE dt.disp_id = p_dispatch_id
          AND LEAST(COALESCE(dt.cart_quantity_consumed, 0), COALESCE(dt.disp_qty, 0)) > 0
        ORDER BY uuid_extract_timestamp(dt.id), dt.id
    LOOP
        -- A lot has one line in the customer's one order: when the count of its lines goes up, the give-back made one.
        SELECT count(*) INTO v_lines_before FROM order_items oi WHERE oi.grn_items_id = v_cart_line.gr_trl_id;

        v_restore_cart_id := warehouse_security.restore_to_order(
            p_dispatch_id, v_dispatch_record.source_order_id, v_cart_line.source_order_item_id,
            v_dispatch_record.customer_id, v_cart_line.gr_trl_id, v_cart_line.give_back, v_user_profile_id);

        IF v_restore_cart_id IS NULL THEN
            v_cart_lines_no_open_cart := v_cart_lines_no_open_cart + 1;
            CONTINUE;
        END IF;

        IF (SELECT count(*) FROM order_items oi WHERE oi.grn_items_id = v_cart_line.gr_trl_id) > v_lines_before THEN
            v_order_items_recreated := v_order_items_recreated + 1;
        ELSE
            v_order_items_restored := v_order_items_restored + 1;
        END IF;

        v_restored_items := v_restored_items || jsonb_build_object(
            'cart_id', v_restore_cart_id,
            'item_name', v_cart_line.item_name,
            'package_mark', v_cart_line.package_mark,
            'grn_no', v_cart_line.gr_no,
            'quantity_restored', v_cart_line.give_back
        );

        v_cart_details := v_cart_details || jsonb_build_object(
            'order_id', v_restore_cart_id,
            'gr_trl_id', v_cart_line.gr_trl_id,
            'item_name', v_cart_line.item_name,
            'quantity_restored', v_cart_line.give_back
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

    -- The order's change log (migration 121): one dispatch_deleted entry for every cart that got something back, listing the
    -- lines actually given back to it (not every line of the dispatch). The source order keeps its entry even when nothing
    -- went back to it (its restored_items is then empty).
    FOR v_rev_cart IN
        SELECT c.id FROM (
            SELECT (x.e->>'cart_id')::uuid AS id FROM jsonb_array_elements(v_restored_items) AS x(e)
            UNION
            SELECT v_dispatch_record.source_order_id WHERE v_dispatch_record.source_order_id IS NOT NULL
        ) AS c
        ORDER BY c.id
    LOOP
        INSERT INTO public.order_revisions (order_id, changed_at, changed_by, action, entry)
        SELECT o.id, clock_timestamp(), v_user_profile_id, 'dispatch_deleted', (
                jsonb_build_object(
                    'action', 'dispatch_deleted',
                    'timestamp', NOW(),
                    'by', v_user_profile_id,
                    'dispatch_id', v_dispatch_record.id,
                    'dispatch_no', v_dispatch_record.disp_no,
                    'restored_items', COALESCE((
                        SELECT jsonb_agg(jsonb_build_object(
                                   'item_name', r.e->>'item_name',
                                   'package_mark', r.e->>'package_mark',
                                   'grn_no', r.e->>'grn_no',
                                   'quantity_restored', (r.e->>'quantity_restored')::integer
                               ) ORDER BY r.n)
                        FROM jsonb_array_elements(v_restored_items) WITH ORDINALITY AS r(e, n)
                        WHERE (r.e->>'cart_id')::uuid = o.id
                    ), '[]'::jsonb),
                    'total_quantity_restored', COALESCE((
                        SELECT SUM((r.e->>'quantity_restored')::integer)
                        FROM jsonb_array_elements(v_restored_items) AS r(e)
                        WHERE (r.e->>'cart_id')::uuid = o.id
                    ), 0),
                    'cart_restoration_status', CASE
                        WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(v_restored_items) AS r(e)
                                     WHERE (r.e->>'cart_id')::uuid = o.id) THEN 'success'
                        ELSE 'not_applicable'
                    END
                )
            )
        FROM public.orders o WHERE o.id = v_rev_cart;
    END LOOP;

    -- Check if there are linked orders - now just check source_order_id
    v_linked_orders_count := 0;
    IF v_dispatch_record.source_order_id IS NOT NULL THEN
        v_linked_orders_count := 1;

        -- Cart lines were given back above (migration 67).

        -- The dispatch deletion entries of the carts were written above (migration 121).

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
-- Section 7: dispatch create and edit
-- D3, D4, D5: dispatch create refuses a future date or a date before a lot's GRN, refuses a stale order, and logs what it takes
-- from an order line
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
    v_order_updated_at timestamptz;
    v_expected_order_at timestamptz;
    v_disp_day date;
    v_today date;
    v_late_gr_no text;
    v_late_grn_day date;
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
        SELECT customer_id, updated_at INTO v_order_customer_id, v_order_updated_at
        FROM orders
        WHERE id = v_source_order_id AND deleted_at IS NULL;
        IF v_order_customer_id IS NULL
           OR v_order_customer_id IS DISTINCT FROM (p_dispatch_data->>'customer_id')::uuid THEN
            RAISE EXCEPTION 'The order belongs to another customer' USING ERRCODE = 'WH409';
        END IF;

        -- D5 (migration 121): the form was made from the order as it was at source_order_updated_at. An order that changed
        -- since (a line added, changed or removed, or taken by another dispatch) is not dispatched from a stale form. The
        -- order is read without a lock. No key (an older app, a direct dispatch): no check. A retry of this user's own
        -- committed create was answered from the saved answer above, so it is not refused for what its first try changed.
        IF NULLIF(p_dispatch_data->>'source_order_updated_at', '') IS NOT NULL THEN
            v_expected_order_at := (p_dispatch_data->>'source_order_updated_at')::timestamptz;
            IF date_trunc('milliseconds', v_order_updated_at) IS DISTINCT FROM date_trunc('milliseconds', v_expected_order_at) THEN
                RETURN warehouse_security.refuse('ORDER_CHANGED', 'This order changed after you opened it.',
                    jsonb_build_object('source_order_id', v_source_order_id,
                                       'expected_updated_at', v_expected_order_at,
                                       'current_updated_at', v_order_updated_at));
            END IF;
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

    -- D3 (migration 121, IST days): a dispatch is not dated in the future, and not before the GRN day of any of its lots.
    -- The day is the one the insert below stores (the same cast). The GRN named is the latest one among the lots.
    v_disp_day := (p_dispatch_data->>'disp_date')::date;
    IF v_disp_day IS NOT NULL THEN
        v_today := warehouse_security.business_date(now());
        IF v_disp_day > v_today THEN
            RETURN warehouse_security.refuse('DISPATCH_DATE_FUTURE',
                format('A dispatch can''t be dated in the future. Today is %s.', to_char(v_today, 'YYYY-MM-DD')),
                jsonb_build_object('date', to_char(v_disp_day, 'YYYY-MM-DD'), 'today', to_char(v_today, 'YYYY-MM-DD')));
        END IF;

        SELECT gr.gr_no, warehouse_security.business_date(gr.date)
        INTO v_late_gr_no, v_late_grn_day
        FROM unnest(p_dispatch_items) AS item
        JOIN goodsreceived_trl gt ON gt.id = (item->>'gr_trl_id')::uuid
        JOIN goodsreceived gr ON gr.id = gt.gr_id
        WHERE warehouse_security.business_date(gr.date) > v_disp_day
        ORDER BY warehouse_security.business_date(gr.date) DESC, gr.gr_no DESC
        LIMIT 1;

        IF v_late_gr_no IS NOT NULL THEN
            RETURN warehouse_security.refuse('DISPATCH_BEFORE_GRN',
                format('The dispatch date %s is before GRN %s (%s).', to_char(v_disp_day, 'YYYY-MM-DD'), v_late_gr_no,
                       to_char(v_late_grn_day, 'YYYY-MM-DD')),
                jsonb_build_object('date', to_char(v_disp_day, 'YYYY-MM-DD'), 'gr_no', v_late_gr_no,
                                   'grn_date', to_char(v_late_grn_day, 'YYYY-MM-DD')));
        END IF;
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
                -- D4 (migration 121): what the dispatch took from the order line goes into the order's change log.
                INSERT INTO order_revisions (order_id, changed_at, changed_by, action, entry)
                VALUES (v_source_order_id, clock_timestamp(), v_user_id, 'auto_quantity_reduction', jsonb_build_object(
                    'action', 'auto_quantity_reduction',
                    'timestamp', NOW(),
                    'by', v_user_id,
                    'dispatch_id', v_dispatch_id,
                    'dispatch_no', p_dispatch_data->>'disp_no',
                    'grn_item_id', v_gr_trl_id,
                    'previous_quantity', v_cart_current_qty,
                    'new_quantity', v_cart_new_qty));
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
                        -- D4 (migration 121): what the dispatch took from the order line goes into the order's change log.
                        INSERT INTO order_revisions (order_id, changed_at, changed_by, action, entry)
                        VALUES (v_cart_id, clock_timestamp(), v_user_id, 'auto_quantity_reduction', jsonb_build_object(
                            'action', 'auto_quantity_reduction',
                            'timestamp', NOW(),
                            'by', v_user_id,
                            'dispatch_id', v_dispatch_id,
                            'dispatch_no', p_dispatch_data->>'disp_no',
                            'grn_item_id', v_gr_trl_id,
                            'previous_quantity', v_cart_current_qty,
                            'new_quantity', v_cart_new_qty));
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
        -- Kept for the 7 days a retry is answered from it. A key another
        -- function or user holds is left alone unless it has expired.
        INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
        VALUES (p_idempotency_key, 'create_dispatch_with_stock_check', v_cached_response, v_user_id, NOW() + INTERVAL '7 days')
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
-- D1, D2, D3, D4: dispatch edit checks the version token, keeps the date and number of an invoiced dispatch, applies the date
-- rules, and keeps the order in step with the edited lines
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
    v_stored_updated_at timestamptz;
    v_expected_at timestamptz;
    v_stored_disp_no text;
    v_stored_disp_date timestamptz;
    v_sent_day date;
    v_day_changed boolean := false;
    v_no_changed boolean := false;
    v_inv_no integer;
    v_inv_year integer;
    v_changed_fields jsonb;
    v_late_gr_no text;
    v_late_grn_day date;
    v_old_lines jsonb;
    v_cust_id uuid;
    v_src_order_id uuid;
    v_disp_no_now text;
    v_sync record;
    v_back integer;
    v_take integer;
    v_given_back integer := 0;
    v_taken integer := 0;
    v_cart uuid;
    v_given_carts uuid[] := ARRAY[]::uuid[];
    v_line_id uuid;
    v_line_qty integer;
    v_line_fulfilled integer;
    v_new_line_qty integer;
    v_new_updated_at timestamptz;
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
    SELECT d.id, d.updated_at, d.disp_no, d.disp_date
    INTO v_locked_dispatch, v_stored_updated_at, v_stored_disp_no, v_stored_disp_date
    FROM dispatch d
    WHERE d.id = p_dispatch_id AND d.deleted_at IS NULL
    FOR UPDATE;

    IF v_locked_dispatch IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Dispatch not found');
    END IF;

    -- D1 (migration 121): a dispatch that changed after the caller read it is not saved over; nothing is written. The
    -- token is the dispatch's updated_at, sent as expected_updated_at in p_dispatch_data. This runs after the saved-answer
    -- replay above, so a resend of this user's own lost save is never refused for what its first try changed. No token (an
    -- older app, fas-sync): no check.
    IF NULLIF(p_dispatch_data->>'expected_updated_at', '') IS NOT NULL THEN
        v_expected_at := (p_dispatch_data->>'expected_updated_at')::timestamptz;
        IF date_trunc('milliseconds', v_stored_updated_at) IS DISTINCT FROM date_trunc('milliseconds', v_expected_at) THEN
            RETURN warehouse_security.refuse('STALE_RECORD', 'Someone else changed this dispatch. Open it again.',
                jsonb_build_object('what', 'dispatch', 'id', p_dispatch_id,
                                   'expected_updated_at', v_expected_at, 'current_updated_at', v_stored_updated_at));
        END IF;
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

    -- D2, D3 (migration 121, IST days). The date sent is "changed" when its day differs from both the UTC day and the IST day
    -- of the stored date, so a legacy row with an odd time of day is not changed by the app sending its own day back. The
    -- number is changed when it differs from the stored text. Nothing is written before these checks.
    v_sent_day := (p_dispatch_data->>'disp_date')::date;
    IF v_sent_day IS NOT NULL THEN
        v_day_changed := v_sent_day IS DISTINCT FROM (v_stored_disp_date AT TIME ZONE 'UTC')::date
                         AND v_sent_day IS DISTINCT FROM warehouse_security.business_date(v_stored_disp_date);
    END IF;
    v_no_changed := p_dispatch_data->>'disp_no' IS NOT NULL AND (p_dispatch_data->>'disp_no') IS DISTINCT FROM v_stored_disp_no;

    -- D2: a dispatch with a line on a live invoice keeps its date and number (the invoice's days are counted from them).
    IF v_day_changed OR v_no_changed THEN
        SELECT i.inv_no, i.inv_fin_year INTO v_inv_no, v_inv_year
        FROM invoice_trl it
        JOIN invoice i ON i.id = it.invoice_id AND i.deleted_at IS NULL
        JOIN dispatch_trl dt ON dt.id = it.disp_trl_id
        WHERE dt.disp_id = p_dispatch_id
        ORDER BY i.inv_fin_year, i.inv_no, i.id
        LIMIT 1;

        IF v_inv_no IS NOT NULL THEN
            v_changed_fields := '[]'::jsonb;
            IF v_day_changed THEN v_changed_fields := v_changed_fields || to_jsonb('disp_date'::text); END IF;
            IF v_no_changed THEN v_changed_fields := v_changed_fields || to_jsonb('disp_no'::text); END IF;
            RETURN warehouse_security.refuse('DISPATCH_INVOICED',
                format('Dispatch %s is on invoice %s. Its date and number can''t be changed. Delete or edit the invoice first.',
                       v_stored_disp_no, v_inv_no),
                jsonb_build_object('dispatch_no', v_stored_disp_no, 'invoice_no', v_inv_no,
                                   'inv_fin_year', v_inv_year, 'fields', v_changed_fields));
        END IF;
    END IF;

    -- D3: the same two date rules as a create. A changed day is checked against every line after the edit; an unchanged
    -- day only against the lines this edit adds, so a legacy back-dated dispatch stays editable. A request without a
    -- date is not checked.
    IF v_sent_day IS NOT NULL THEN
        IF v_day_changed AND v_sent_day > warehouse_security.business_date(now()) THEN
            RETURN warehouse_security.refuse('DISPATCH_DATE_FUTURE',
                format('A dispatch can''t be dated in the future. Today is %s.', to_char(warehouse_security.business_date(now()), 'YYYY-MM-DD')),
                jsonb_build_object('date', to_char(v_sent_day, 'YYYY-MM-DD'),
                                   'today', to_char(warehouse_security.business_date(now()), 'YYYY-MM-DD')));
        END IF;

        SELECT gr.gr_no, warehouse_security.business_date(gr.date)
        INTO v_late_gr_no, v_late_grn_day
        FROM goodsreceived gr
        JOIN goodsreceived_trl gt ON gt.gr_id = gr.id
        WHERE gt.id IN (
            SELECT (ni->>'gr_trl_id')::uuid
            FROM unnest(p_dispatch_items) AS ni
            WHERE v_day_changed
               OR NOT EXISTS (SELECT 1 FROM dispatch_trl dt
                              WHERE dt.disp_id = p_dispatch_id AND dt.gr_trl_id = (ni->>'gr_trl_id')::uuid)
            UNION
            SELECT dt.gr_trl_id FROM dispatch_trl dt
            WHERE dt.disp_id = p_dispatch_id AND p_dispatch_items IS NULL AND v_day_changed
        )
          AND warehouse_security.business_date(gr.date) > v_sent_day
        ORDER BY warehouse_security.business_date(gr.date) DESC, gr.gr_no DESC
        LIMIT 1;

        IF v_late_gr_no IS NOT NULL THEN
            RETURN warehouse_security.refuse('DISPATCH_BEFORE_GRN',
                format('The dispatch date %s is before GRN %s (%s).', to_char(v_sent_day, 'YYYY-MM-DD'), v_late_gr_no,
                       to_char(v_late_grn_day, 'YYYY-MM-DD')),
                jsonb_build_object('date', to_char(v_sent_day, 'YYYY-MM-DD'), 'gr_no', v_late_gr_no,
                                   'grn_date', to_char(v_late_grn_day, 'YYYY-MM-DD')));
        END IF;
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

        -- ========== D4: the lines as they were before this edit (migration 121) ==========
        -- What each line took from an order (cart_quantity_consumed) is lost when the line is removed below, so it is read
        -- here, with the lots already locked (step 2). A line without a lot is never touched by an edit.
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'lot', dt.gr_trl_id, 'qty', dt.disp_qty,
                   'consumed', COALESCE(dt.cart_quantity_consumed, 0), 'item', dt.source_order_item_id)), '[]'::jsonb)
        INTO v_old_lines
        FROM dispatch_trl dt
        WHERE dt.disp_id = p_dispatch_id AND dt.gr_trl_id IS NOT NULL;

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

        -- ========== D4: keep the order in step with the edited lines (migration 121) ==========
        -- A line lowered or removed gives back what it had taken from the order, at most the quantity it gives up. A line
        -- raised or added takes the extra from the order's line for that lot (the dispatch's source order, else the
        -- customer's OPEN order), at most what that line still asks for; the stock is taken in full either way. The cart's
        -- lines are locked, the order itself is not (the lock order stays dispatch, lots, order lines, order). A source
        -- order that is not OPEN is not taken from. Both are done by the dispatch whatever the state of the business (a
        -- deactivated business is dispatched too). What was taken goes into the order's change log as a dispatch reduction; what was given back as a
        -- quantity change, one entry per order after all give-backs.
        SELECT d.customer_id, d.source_order_id, d.disp_no
        INTO v_cust_id, v_src_order_id, v_disp_no_now
        FROM dispatch d
        WHERE d.id = p_dispatch_id;

        FOR v_sync IN
            SELECT COALESCE(o.lot, n.lot) AS lot,
                   COALESCE(o.qty, 0) AS old_qty,
                   COALESCE(n.qty, 0) AS new_qty,
                   COALESCE(o.consumed, 0) AS consumed,
                   o.item AS old_item
            FROM (SELECT (x.e->>'lot')::uuid AS lot, (x.e->>'qty')::integer AS qty,
                         (x.e->>'consumed')::integer AS consumed, NULLIF(x.e->>'item', '')::uuid AS item
                  FROM jsonb_array_elements(v_old_lines) AS x(e)) AS o
            FULL JOIN (SELECT (ni->>'gr_trl_id')::uuid AS lot, (ni->>'disp_qty')::integer AS qty
                       FROM unnest(p_dispatch_items) AS ni) AS n ON n.lot = o.lot
            WHERE COALESCE(o.qty, 0) <> COALESCE(n.qty, 0)
            ORDER BY COALESCE(o.lot, n.lot)
        LOOP
            IF v_sync.new_qty < v_sync.old_qty THEN
                -- Lowered or removed: give back what the line took, at most the quantity it gives up.
                v_back := LEAST(v_sync.consumed, v_sync.old_qty - v_sync.new_qty);
                IF v_back > 0 THEN
                    v_cart := warehouse_security.restore_to_order(
                        p_dispatch_id, v_src_order_id, v_sync.old_item, v_cust_id, v_sync.lot, v_back, v_user_id);
                    IF v_cart IS NOT NULL THEN
                        v_given_back := v_given_back + v_back;
                        IF NOT (v_cart = ANY (v_given_carts)) THEN
                            v_given_carts := v_given_carts || v_cart;
                        END IF;
                    END IF;
                END IF;
                -- A line that stays holds no more than its new quantity (cart_quantity_consumed <= disp_qty).
                IF v_sync.new_qty > 0 AND (v_back > 0 OR v_sync.consumed > v_sync.new_qty) THEN
                    UPDATE dispatch_trl
                    SET cart_quantity_consumed = LEAST(v_sync.consumed - v_back, v_sync.new_qty)
                    WHERE disp_id = p_dispatch_id AND gr_trl_id = v_sync.lot;
                END IF;
            ELSE
                -- Raised or added: take the extra from the order's line for the lot, if there is one.
                v_take := 0;
                v_cart := NULL;
                v_line_id := NULL;
                IF v_src_order_id IS NOT NULL THEN
                    SELECT o.id INTO v_cart
                    FROM orders o
                    WHERE o.id = v_src_order_id AND o.status = 'OPEN' AND o.deleted_at IS NULL;
                ELSE
                    SELECT o.id INTO v_cart
                    FROM orders o
                    WHERE o.customer_id = v_cust_id AND o.status = 'OPEN' AND o.deleted_at IS NULL
                    ORDER BY o.created_at, o.id
                    LIMIT 1;
                END IF;

                IF v_cart IS NOT NULL THEN
                    SELECT oi.id, oi.requested_quantity, oi.fulfilled_quantity
                    INTO v_line_id, v_line_qty, v_line_fulfilled
                    FROM order_items oi
                    WHERE oi.order_id = v_cart AND oi.grn_items_id = v_sync.lot
                    LIMIT 1
                    FOR UPDATE;
                END IF;

                IF v_line_id IS NOT NULL THEN
                    v_take := LEAST(v_line_qty, v_sync.new_qty - v_sync.old_qty);
                    v_new_line_qty := v_line_qty - v_take;
                    IF v_new_line_qty = 0 THEN
                        DELETE FROM order_items WHERE id = v_line_id;
                    ELSIF v_src_order_id IS NOT NULL THEN
                        UPDATE order_items
                        SET requested_quantity = v_new_line_qty,
                            fulfilled_quantity = 0,
                            item_status = 'pending',
                            updated_at = NOW()
                        WHERE id = v_line_id;
                    ELSE
                        UPDATE order_items
                        SET requested_quantity = v_new_line_qty,
                            fulfilled_quantity = GREATEST(0, COALESCE(v_line_fulfilled, 0) - v_take)
                        WHERE id = v_line_id;
                    END IF;

                    INSERT INTO order_revisions (order_id, changed_at, changed_by, action, entry)
                    VALUES (v_cart, clock_timestamp(), v_user_id, 'auto_quantity_reduction', jsonb_build_object(
                        'action', 'auto_quantity_reduction',
                        'timestamp', NOW(),
                        'by', v_user_id,
                        'dispatch_id', p_dispatch_id,
                        'dispatch_no', v_disp_no_now,
                        'grn_item_id', v_sync.lot,
                        'previous_quantity', v_line_qty,
                        'new_quantity', v_new_line_qty));

                    UPDATE dispatch_trl
                    SET cart_quantity_consumed = COALESCE(cart_quantity_consumed, 0) + v_take,
                        source_order_item_id = COALESCE(source_order_item_id, v_line_id)
                    WHERE disp_id = p_dispatch_id AND gr_trl_id = v_sync.lot;

                    v_taken := v_taken + v_take;
                END IF;
            END IF;
        END LOOP;

        FOREACH v_cart IN ARRAY v_given_carts
        LOOP
            PERFORM warehouse_security.record_order_revision(v_cart, v_user_id, 'UPDATE',
                jsonb_build_object('dispatch_id', p_dispatch_id, 'dispatch_no', v_disp_no_now, 'source', 'dispatch_edit'));
        END LOOP;

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

    SELECT d.updated_at INTO v_new_updated_at FROM dispatch d WHERE d.id = p_dispatch_id;

    v_result := jsonb_build_object(
        'success', true,
        'dispatch_id', p_dispatch_id,
        'dispatch_items', v_dispatch_items_result,
        'updated_at', v_new_updated_at,
        'order_sync', jsonb_build_object('given_back', v_given_back, 'taken', v_taken)
    );

    -- The answer is kept for the 7 days a resend is answered from it, as the dispatch create answer is (migration
    -- 120). A code that another function or user holds is left alone unless it has expired.
    IF v_request_key IS NOT NULL THEN
        INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
        VALUES (v_request_key, 'update_dispatch_smart', v_result, v_user_id, now() + interval '7 days')
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
-- Section 8: GRN save and edit
-- D15: rack and package mark are stored with the digits 0-9 (the same sets as the app's normalizeDigits): Gujarati U+0AE6-0AEF,
-- Devanagari U+0966-096F, Arabic-Indic U+0660-0669 and extended Arabic-Indic U+06F0-06F9. NULL stays NULL. Existing rows
-- are not converted here.
CREATE OR REPLACE FUNCTION warehouse_security.ascii_digits(p_text text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT translate(p_text,
    U&'\0AE6\0AE7\0AE8\0AE9\0AEA\0AEB\0AEC\0AED\0AEE\0AEF\0966\0967\0968\0969\096A\096B\096C\096D\096E\096F\0660\0661\0662\0663\0664\0665\0666\0667\0668\0669\06F0\06F1\06F2\06F3\06F4\06F5\06F6\06F7\06F8\06F9',
    '0123456789012345678901234567890123456789')
$$;
ALTER FUNCTION warehouse_security.ascii_digits(p_text text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.ascii_digits(p_text text) FROM PUBLIC;

-- D13, D15: save_grn refuses a registration over 20 characters and stores rack and package mark with the digits 0-9

DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
      -- IDEMPOTENCY CHECK: Return cached response if key exists
$m$,
    $m$                  v_item->>'rack',
                  v_item->>'package_mark'
              ) RETURNING id INTO v_item_id;$m$
  ];
  v_new constant text[] := ARRAY[
    $m$  -- Migration 121 (D13): the registration fits the column (20 characters), as the item name and packaging fit theirs.
  IF p_registration IS NOT NULL AND char_length(p_registration) > 20 THEN
    RETURN warehouse_security.grn_rate_failure('registration_too_long',
      'Registration can have at most 20 characters', jsonb_build_object('limit', 20));
  END IF;
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
      -- IDEMPOTENCY CHECK: Return cached response if key exists
$m$,
    $m$                  -- Migration 121 (D15): rack and package mark are stored with the digits 0-9.
                  warehouse_security.ascii_digits(v_item->>'rack'),
                  warehouse_security.ascii_digits(v_item->>'package_mark')
              ) RETURNING id INTO v_item_id;$m$
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

-- D1, D2, D3, D6, D9, D10, D11, D13, D15, D23, D24: update_grn. A new trailing parameter (p_expected_updated_at) needs the old
-- 18-argument signature dropped (an overload would make the call ambiguous). The body is the baseline body with migration 120's
-- 7-day answer patch, plus the changes of this migration.
DROP FUNCTION public.update_grn(uuid, character varying, timestamp with time zone, uuid, character varying, uuid, character varying, uuid, character varying, character varying, character varying, boolean, character varying, jsonb, jsonb, character varying, text, jsonb);
CREATE FUNCTION public.update_grn(p_grn_id uuid, p_gr_no character varying DEFAULT NULL::character varying, p_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_customer_id uuid DEFAULT NULL::uuid, p_customer_name character varying DEFAULT NULL::character varying, p_sender_id uuid DEFAULT NULL::uuid, p_sender_name character varying DEFAULT NULL::character varying, p_supervisor_id uuid DEFAULT NULL::uuid, p_supervisor_name character varying DEFAULT NULL::character varying, p_registration character varying DEFAULT NULL::character varying, p_note character varying DEFAULT NULL::character varying, p_leon boolean DEFAULT NULL::boolean, p_pricing_mode character varying DEFAULT NULL::character varying, p_items jsonb DEFAULT '[]'::jsonb, p_images jsonb DEFAULT '[]'::jsonb, p_duration_mode character varying DEFAULT NULL::character varying, p_idempotency_key text DEFAULT NULL::text, p_rates jsonb DEFAULT NULL::jsonb, p_expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    SET jit TO 'off'
    AS $$
DECLARE
    v_user_id uuid;
    v_user_profile_id uuid;
    v_user_role text;
    v_item jsonb;
    v_image jsonb;
    v_grn_trl_item_id uuid;
    v_image_id uuid;
    v_current_qty int;
    v_current_stock int;
    v_item_name_from_db varchar;
    v_dispatched_qty int;
    v_items_updated int := 0;
    v_items_added int := 0;
    v_items_deleted int := 0;
    v_images_updated int := 0;
    v_images_added int := 0;
    v_images_deleted int := 0;
    v_items_skipped_stock jsonb := '[]'::jsonb;
    v_existing_grn_item_ids uuid[];
    v_provided_grn_item_ids uuid[];
    v_items_to_delete uuid[];
    v_item_index int;
    v_item_mapping jsonb := '[]'::jsonb;
    v_resolved_item_id uuid;
    v_existing_image_ids uuid[];
    v_kept_image_ids uuid[];
    v_final_grn_data jsonb;
    v_grn_items jsonb := '[]'::jsonb;
    v_grn_images jsonb;
    v_temp_item jsonb;
    v_grn_header jsonb;
    v_item_master_id uuid;
    v_item_name varchar;
    v_cached_response jsonb;
    v_result jsonb;
    v_line_rows integer;
    v_bad_line text;
    v_rate_failure jsonb;
    v_detail text;
    v_stored_updated_at timestamptz;
    v_stored_gr_no text;
    v_stored_date timestamptz;
    v_stored_invoiced boolean;
    v_stored_customer_name text;
    v_is_invoiced boolean;
    v_inv_no integer;
    v_inv_year integer;
    v_inv_no2 integer;
    v_inv_year2 integer;
    v_first_day date;
    v_first_disp_no text;
    v_chk record;
    v_changed_fields jsonb;
    v_lines_before jsonb;
    v_type_before text;
    v_type_after text;
    v_dropped_count integer := 0;
    v_dropped_items text[] := ARRAY[]::text[];
    v_dropped_rows jsonb := '[]'::jsonb;
    v_would_drop_count integer := 0;
    v_would_drop_items text[] := ARRAY[]::text[];
BEGIN
  PERFORM warehouse_security.authorize_rpc('update_grn',jsonb_build_object('p_grn_id',p_grn_id,'p_customer_id',p_customer_id));
  -- Migration 90: rates typed on the GRN sheet are an administrator's or a supervisor's.
  IF p_rates IS NOT NULL AND warehouse_security.active_role() = 'staff' THEN
    RETURN warehouse_security.rate_failure('RATES_MANAGER_ONLY', 'Only administrators and supervisors can set rates on a GRN');
  END IF;
  -- Migration 95: a line's name and packaging fit the receipt columns (80 and 40 characters, as the catalog).
  IF jsonb_typeof(p_items) = 'array' THEN
    v_item_index := 0;
    FOR v_item IN SELECT e FROM jsonb_array_elements(p_items) AS e LOOP
      IF jsonb_typeof(v_item->'item_name') = 'string' AND char_length(v_item->>'item_name') > 80 THEN
        RETURN warehouse_security.grn_rate_failure('item_name_too_long',
          'An item name can have at most 80 characters', jsonb_build_object('limit', 80, 'index', v_item_index));
      END IF;
      IF jsonb_typeof(v_item->'packaging') = 'string' AND char_length(v_item->>'packaging') > 40 THEN
        RETURN warehouse_security.grn_rate_failure('packaging_too_long',
          'Packaging can have at most 40 characters', jsonb_build_object('limit', 40, 'index', v_item_index));
      END IF;
      v_item_index := v_item_index + 1;
    END LOOP;
  END IF;
    -- Migration 121 (D13): the registration fits the column (20 characters), as the item name and packaging fit theirs.
    IF p_registration IS NOT NULL AND char_length(p_registration) > 20 THEN
        RETURN warehouse_security.grn_rate_failure('registration_too_long',
          'Registration can have at most 20 characters', jsonb_build_object('limit', 20));
    END IF;

    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Authentication required'
        );
    END IF;

    SELECT id, role INTO v_user_profile_id, v_user_role
    FROM user_profiles
    WHERE auth_user_id = v_user_id;

    IF v_user_profile_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'User profile not found'
        );
    END IF;

    IF v_user_role NOT IN ('admin', 'supervisor', 'staff') THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Insufficient permissions. Only admin and supervisor can update GRNs'
        );
    END IF;

    -- IDEMPOTENCY CHECK: a repeated save answers with the stored result (migration 47)
    IF p_idempotency_key IS NOT NULL THEN
        PERFORM pg_advisory_xact_lock(71040);

        SELECT response INTO v_cached_response
        FROM idempotency_keys
        WHERE idempotency_key = p_idempotency_key
          AND rpc_function = 'update_grn'
          AND created_by = v_user_profile_id
          AND response #>> '{grn,id}' = p_grn_id::text
          AND expires_at > now();

        IF v_cached_response IS NOT NULL THEN
            RETURN v_cached_response || jsonb_build_object('idempotent', true);
        END IF;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM goodsreceived WHERE id = p_grn_id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'GRN not found'
        );
    END IF;

    PERFORM warehouse_security.require_person_supervisor(p_supervisor_id::text,
      (SELECT supervisor_id FROM goodsreceived WHERE id = p_grn_id));

    IF p_gr_no IS NOT NULL AND warehouse_security.is_blank_text(p_gr_no) THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'GRN number is required'
        );
    END IF;

    -- Migration 121 (D6): the number of a GRN cannot be changed (to correct a wrong number, delete the GRN and enter it again).
    -- The stored number sent back, or no number, is fine.
    IF p_gr_no IS NOT NULL AND p_gr_no IS DISTINCT FROM (SELECT g.gr_no FROM goodsreceived g WHERE g.id = p_grn_id) THEN
        RETURN warehouse_security.refuse('GRN_NUMBER_LOCKED',
            'The GRN number can''t be changed. Delete the GRN and enter it again.',
            jsonb_build_object('gr_no', (SELECT g.gr_no FROM goodsreceived g WHERE g.id = p_grn_id), 'requested', p_gr_no));
    END IF;

    IF p_gr_no IS NOT NULL AND EXISTS (
        SELECT 1 FROM goodsreceived
        WHERE gr_no = p_gr_no AND id != p_grn_id
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'GRN number already exists: ' || p_gr_no
        );
    END IF;

    BEGIN
        PERFORM pg_advisory_xact_lock(71040);

        -- The GRN row is locked and its version token compared (migration 121, D1): a GRN that changed after the caller read it
        -- is not saved over; nothing is written. This is after the saved-answer lookup above, so a retry of this user's own
        -- committed save is answered from it and never refused for what its first try changed. No token (an older app,
        -- fas-sync): no check.
        SELECT g.updated_at, g.gr_no, g.date, COALESCE(g.invoiced, false), g.customer_name
        INTO v_stored_updated_at, v_stored_gr_no, v_stored_date, v_stored_invoiced, v_stored_customer_name
        FROM goodsreceived g
        WHERE g.id = p_grn_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RETURN jsonb_build_object(
                'success', false,
                'message', 'GRN not found'
            );
        END IF;

        IF p_expected_updated_at IS NOT NULL
           AND date_trunc('milliseconds', v_stored_updated_at) IS DISTINCT FROM date_trunc('milliseconds', p_expected_updated_at) THEN
            RETURN warehouse_security.refuse('STALE_RECORD', 'Someone else changed this GRN. Open it again.',
                jsonb_build_object('what', 'grn', 'id', p_grn_id,
                                   'expected_updated_at', p_expected_updated_at, 'current_updated_at', v_stored_updated_at));
        END IF;

        IF p_customer_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM goodsreceived
            WHERE id = p_grn_id AND customer_id IS DISTINCT FROM p_customer_id
        ) THEN
            IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND deleted_at IS NOT NULL) THEN
                RAISE EXCEPTION 'Business is not active' USING ERRCODE = 'P0001';
            END IF;
            IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND active = false) THEN
                RAISE EXCEPTION 'This business is deactivated. Activate it in Customers to receive new goods.' USING ERRCODE = 'P0001';
            END IF;
            PERFORM 1 FROM goodsreceived WHERE id = p_grn_id FOR UPDATE;

            IF EXISTS (SELECT 1 FROM dispatch_trl WHERE gr_id = p_grn_id)
               OR EXISTS (SELECT 1 FROM invoice WHERE gr_id = p_grn_id)
               OR EXISTS (
                   SELECT 1 FROM order_items oi
                   JOIN orders o ON o.id = oi.order_id
                   JOIN goodsreceived_trl gt ON gt.id = oi.grn_items_id
                   WHERE gt.gr_id = p_grn_id AND o.deleted_at IS NULL
               ) THEN
                RAISE EXCEPTION 'Cannot change the customer of a GRN that has dispatches, invoices or order items';
            END IF;
        END IF;
        IF p_pricing_mode IS NOT NULL AND EXISTS (
            SELECT 1 FROM goodsreceived
            WHERE id = p_grn_id AND COALESCE(pricing_mode, 'MONTHLY') IS DISTINCT FROM p_pricing_mode
        ) THEN
            PERFORM 1 FROM goodsreceived WHERE id = p_grn_id FOR UPDATE;

            IF EXISTS (SELECT 1 FROM invoice WHERE gr_id = p_grn_id AND deleted_at IS NULL)
               OR EXISTS (
                   SELECT 1 FROM invoice_trl it
                   JOIN dispatch_trl dt ON dt.id = it.disp_trl_id
                   JOIN invoice inv ON inv.id = it.invoice_id
                   WHERE dt.gr_id = p_grn_id AND inv.deleted_at IS NULL
               ) THEN
                RAISE EXCEPTION 'Cannot change the pricing mode of a GRN that has invoices: delete invoices first, then change the pricing mode and invoice again';
            END IF;
        END IF;

        SELECT (e->>'id')::uuid::text INTO v_bad_line
        FROM jsonb_array_elements(p_items) AS e
        WHERE e->>'id' IS NOT NULL
        GROUP BY (e->>'id')::uuid
        HAVING count(*) > 1
        LIMIT 1;
        IF v_bad_line IS NOT NULL THEN
            RAISE EXCEPTION 'A GRN line is sent more than once in this edit; reload the GRN and edit again';
        END IF;

        SELECT x.e->>'id' INTO v_bad_line
        FROM jsonb_array_elements(p_items) WITH ORDINALITY AS x(e, n)
        WHERE x.e->>'id' IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM goodsreceived_trl t
              WHERE t.id = (x.e->>'id')::uuid AND t.gr_id = p_grn_id
          )
        ORDER BY x.n
        LIMIT 1;
        IF v_bad_line IS NOT NULL THEN
            RAISE EXCEPTION 'GRN line % is not a line of this GRN; reload the GRN and edit again', v_bad_line;
        END IF;

        -- ---- Migration 121 refusals. Each answers before the first write; nothing here changes a row. ----
        -- An invoiced GRN is one with a live invoice, or whose invoiced flag is set.
        SELECT i.inv_no, i.inv_fin_year INTO v_inv_no, v_inv_year
        FROM invoice i
        WHERE i.gr_id = p_grn_id AND i.deleted_at IS NULL
        ORDER BY i.inv_fin_year, i.inv_no, i.id
        LIMIT 1;
        v_is_invoiced := v_inv_no IS NOT NULL OR v_stored_invoiced;

        -- D23: the date of an invoiced GRN is locked (the invoice's days are counted from it). The same day sent back, at any
        -- time of day, is not a change.
        IF p_date IS NOT NULL AND v_is_invoiced
           AND warehouse_security.business_date(p_date) IS DISTINCT FROM warehouse_security.business_date(v_stored_date) THEN
            RETURN warehouse_security.refuse('GRN_DATE_LOCKED', 'This GRN is invoiced. Delete or edit the invoice first.',
                jsonb_build_object('gr_no', v_stored_gr_no, 'date', to_char(warehouse_security.business_date(p_date), 'YYYY-MM-DD'),
                                   'invoice_no', v_inv_no, 'inv_fin_year', v_inv_year));
        END IF;

        -- D3 (IST days): a GRN date that changes may not move after the first dispatch from the GRN.
        IF p_date IS NOT NULL
           AND warehouse_security.business_date(p_date) IS DISTINCT FROM warehouse_security.business_date(v_stored_date) THEN
            SELECT warehouse_security.business_date(d.disp_date), d.disp_no INTO v_first_day, v_first_disp_no
            FROM dispatch_trl dt
            JOIN dispatch d ON d.id = dt.disp_id AND d.deleted_at IS NULL
            WHERE dt.gr_id = p_grn_id AND d.disp_date IS NOT NULL
            ORDER BY warehouse_security.business_date(d.disp_date), d.disp_date, d.disp_no
            LIMIT 1;

            IF v_first_day IS NOT NULL AND warehouse_security.business_date(p_date) > v_first_day THEN
                RETURN warehouse_security.refuse('GRN_DATE_AFTER_DISPATCH',
                    format('GRN %s can''t be dated %s: dispatch %s took goods from it on %s.', v_stored_gr_no,
                           to_char(warehouse_security.business_date(p_date), 'YYYY-MM-DD'), v_first_disp_no,
                           to_char(v_first_day, 'YYYY-MM-DD')),
                    jsonb_build_object('gr_no', v_stored_gr_no, 'date', to_char(warehouse_security.business_date(p_date), 'YYYY-MM-DD'),
                                       'first_dispatch_date', to_char(v_first_day, 'YYYY-MM-DD'), 'dispatch_no', v_first_disp_no));
            END IF;
        END IF;

        -- D9: a line without an id is a new lot; an invoiced GRN takes none.
        IF v_is_invoiced AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) AS x(e) WHERE x.e->>'id' IS NULL) THEN
            RETURN warehouse_security.refuse('GRN_INVOICED',
                CASE WHEN v_inv_no IS NULL
                     THEN format('GRN %s is invoiced. A line can''t be added. Delete the invoice first.', v_stored_gr_no)
                     ELSE format('GRN %s is on invoice %s. A line can''t be added. Delete the invoice first.', v_stored_gr_no, v_inv_no)
                END,
                jsonb_build_object('gr_no', v_stored_gr_no, 'invoice_no', v_inv_no, 'inv_fin_year', v_inv_year));
        END IF;

        -- D2: per listed line, only where a value really differs from the stored one. An invoiced lot keeps its item, packing
        -- and weight; a dispatched lot keeps its item and packing (its weight and the GRN date stay editable). The first
        -- offending line, in the order sent, is named.
        FOR v_chk IN
            SELECT x.n,
                   t.id AS line_id,
                   t.item_name AS stored_name,
                   (t.item_id IS DISTINCT FROM NULLIF(x.e->>'item_id', '')::uuid) AS item_changed,
                   (COALESCE(t.packaging, '') IS DISTINCT FROM COALESCE(x.e->>'packaging', '')) AS packaging_changed,
                   (COALESCE(t.weight, 0) IS DISTINCT FROM COALESCE((x.e->>'weight')::int, 0)) AS weight_changed,
                   EXISTS (SELECT 1 FROM dispatch_trl dt WHERE dt.gr_trl_id = t.id) AS dispatched
            FROM jsonb_array_elements(p_items) WITH ORDINALITY AS x(e, n)
            JOIN goodsreceived_trl t ON t.id = (x.e->>'id')::uuid AND t.gr_id = p_grn_id
            WHERE x.e->>'id' IS NOT NULL
            ORDER BY x.n
        LOOP
            IF v_chk.item_changed OR v_chk.packaging_changed OR v_chk.weight_changed THEN
                SELECT i.inv_no, i.inv_fin_year INTO v_inv_no2, v_inv_year2
                FROM invoice_trl it
                JOIN dispatch_trl dt ON dt.id = it.disp_trl_id
                JOIN invoice i ON i.id = it.invoice_id AND i.deleted_at IS NULL
                WHERE dt.gr_trl_id = v_chk.line_id
                ORDER BY i.inv_fin_year, i.inv_no, i.id
                LIMIT 1;

                IF v_inv_no2 IS NOT NULL THEN
                    v_changed_fields := '[]'::jsonb;
                    IF v_chk.item_changed THEN v_changed_fields := v_changed_fields || to_jsonb('item'::text); END IF;
                    IF v_chk.packaging_changed THEN v_changed_fields := v_changed_fields || to_jsonb('packaging'::text); END IF;
                    IF v_chk.weight_changed THEN v_changed_fields := v_changed_fields || to_jsonb('weight'::text); END IF;
                    RETURN warehouse_security.refuse('LOT_INVOICED',
                        format('%s is on invoice %s. Item, packing and weight can''t be changed. Delete or edit the invoice first.',
                               v_chk.stored_name, v_inv_no2),
                        jsonb_build_object('line_id', v_chk.line_id, 'item_name', v_chk.stored_name,
                                           'invoice_no', v_inv_no2, 'inv_fin_year', v_inv_year2, 'fields', v_changed_fields));
                END IF;

                IF v_chk.dispatched AND (v_chk.item_changed OR v_chk.packaging_changed) THEN
                    v_changed_fields := '[]'::jsonb;
                    IF v_chk.item_changed THEN v_changed_fields := v_changed_fields || to_jsonb('item'::text); END IF;
                    IF v_chk.packaging_changed THEN v_changed_fields := v_changed_fields || to_jsonb('packaging'::text); END IF;
                    RETURN warehouse_security.refuse('LOT_DISPATCHED',
                        format('%s has been dispatched. Its item and packing can''t be changed.', v_chk.stored_name),
                        jsonb_build_object('line_id', v_chk.line_id, 'item_name', v_chk.stored_name, 'fields', v_changed_fields));
                END IF;
            END IF;
        END LOOP;

        -- D11: a stored line that is missing from the list is a removal. One with dispatch or stock history, or on an order,
        -- is refused by name and reason (it used to fail on a foreign key). The in-loop 'Cannot delete item' below stays as
        -- a backstop.
        FOR v_chk IN
            SELECT t.id AS line_id,
                   t.item_name AS stored_name,
                   (EXISTS (SELECT 1 FROM dispatch_trl dt WHERE dt.gr_trl_id = t.id)
                    OR EXISTS (SELECT 1 FROM stock_movements m WHERE m.gr_trl_id = t.id)) AS had_history,
                   EXISTS (SELECT 1 FROM order_items oi
                           JOIN orders o ON o.id = oi.order_id AND o.deleted_at IS NULL
                           WHERE oi.grn_items_id = t.id) AS on_order
            FROM goodsreceived_trl t
            WHERE t.gr_id = p_grn_id
              AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) AS x(e)
                              WHERE x.e->>'id' IS NOT NULL AND (x.e->>'id')::uuid = t.id)
            ORDER BY uuid_extract_timestamp(t.id), t.id
        LOOP
            IF v_chk.had_history THEN
                RETURN warehouse_security.refuse('LINE_DISPATCHED_BEFORE',
                    format('%s was dispatched before, so this line can''t be removed.', v_chk.stored_name),
                    jsonb_build_object('line_id', v_chk.line_id, 'item_name', v_chk.stored_name));
            ELSIF v_chk.on_order THEN
                RETURN warehouse_security.refuse('LINE_ON_ORDER',
                    format('%s is on %s''s order. Remove it from the order first.', v_chk.stored_name, v_stored_customer_name),
                    jsonb_build_object('line_id', v_chk.line_id, 'item_name', v_chk.stored_name, 'customer_name', v_stored_customer_name));
            END IF;
        END LOOP;

        -- D10, D24: the lines and the pricing kind as they are before this edit, to tell afterwards which line lost its own
        -- rate because its weight or the pricing mode changed.
        SELECT COALESCE(jsonb_agg(jsonb_build_object('id', t.id, 'item_id', t.item_id, 'weight', COALESCE(t.weight, 0))), '[]'::jsonb)
        INTO v_lines_before
        FROM goodsreceived_trl t
        WHERE t.gr_id = p_grn_id;
        SELECT CASE WHEN upper(COALESCE(g.pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END
        INTO v_type_before
        FROM goodsreceived g
        WHERE g.id = p_grn_id;

        PERFORM safe_disable_grn_trl_triggers();

        UPDATE goodsreceived SET
            gr_no = COALESCE(p_gr_no, gr_no),
            date = COALESCE(p_date, date),
            customer_id = COALESCE(p_customer_id, customer_id),
            customer_name = CASE
                WHEN p_customer_id IS NOT NULL AND p_customer_id IS DISTINCT FROM customer_id
                THEN COALESCE((SELECT c.name FROM customers c WHERE c.id = p_customer_id), customer_name)
                ELSE customer_name END,
            sender_id = COALESCE(p_sender_id, sender_id),
            sender_name = COALESCE(p_sender_name, sender_name),
            supervisor_id = COALESCE(p_supervisor_id, supervisor_id),
            supervisor_name = COALESCE(p_supervisor_name, supervisor_name),
            registration = COALESCE(p_registration, registration),
            note = COALESCE(p_note, note),
            leon = COALESCE(p_leon, leon),
            pricing_mode = COALESCE(p_pricing_mode, pricing_mode),
            duration_mode = COALESCE(p_duration_mode, duration_mode),
            updated_by = v_user_profile_id,
            updated_at = now()
        WHERE id = p_grn_id;

        SELECT array_agg(id) INTO v_existing_grn_item_ids
        FROM goodsreceived_trl
        WHERE gr_id = p_grn_id;

        v_provided_grn_item_ids := ARRAY[]::uuid[];

        v_item_index := 0;
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
        LOOP
            v_item_master_id := (v_item->>'item_id')::uuid;
            v_item_name := v_item->>'item_name';

            IF v_item_master_id IS NULL THEN
                RAISE EXCEPTION 'itemId is required for all items';
            END IF;
            IF v_item_name IS NULL OR v_item_name = '' THEN
                RAISE EXCEPTION 'itemName is required for all items';
            END IF;
            IF (v_item->>'qty')::int <= 0 THEN
                RAISE EXCEPTION 'Quantity must be greater than 0 for item "%"', v_item_name;
            END IF;
            IF (v_item->>'weight')::int < 0 THEN
                RAISE EXCEPTION 'Weight cannot be negative for item "%"', v_item_name;
            END IF;

            IF v_item->>'id' IS NOT NULL THEN
                SELECT qty, stock, item_name
                INTO v_current_qty, v_current_stock, v_item_name_from_db
                FROM goodsreceived_trl
                WHERE id = (v_item->>'id')::uuid AND gr_id = p_grn_id
                FOR UPDATE;

                IF NOT FOUND THEN
                    RAISE EXCEPTION 'GRN line % is not a line of this GRN; reload the GRN and edit again', v_item->>'id';
                END IF;

                SELECT COALESCE(SUM(disp_qty), 0)
                INTO v_dispatched_qty
                FROM dispatch_trl
                WHERE gr_trl_id = (v_item->>'id')::uuid;

                IF v_dispatched_qty = 0 THEN
                    UPDATE goodsreceived_trl SET
                        item_id = v_item_master_id,
                        item_name = v_item_name,
                        packaging = v_item->>'packaging',
                        qty = (v_item->>'qty')::int,
                        stock = (v_item->>'qty')::int,
                        weight = COALESCE((v_item->>'weight')::int, 0),
                        rack = warehouse_security.ascii_digits(v_item->>'rack'),
                        package_mark = warehouse_security.ascii_digits(v_item->>'package_mark')
                    WHERE id = (v_item->>'id')::uuid AND gr_id = p_grn_id;

                    GET DIAGNOSTICS v_line_rows = ROW_COUNT;
                    IF v_line_rows <> 1 THEN
                        RAISE EXCEPTION 'GRN line % is not a line of this GRN; reload the GRN and edit again', v_item->>'id';
                    END IF;

                    v_items_updated := v_items_updated + 1;
                ELSE
                    UPDATE goodsreceived_trl SET
                        item_id = v_item_master_id,
                        packaging = v_item->>'packaging',
                        weight = COALESCE((v_item->>'weight')::int, 0),
                        rack = warehouse_security.ascii_digits(v_item->>'rack'),
                        package_mark = warehouse_security.ascii_digits(v_item->>'package_mark')
                    WHERE id = (v_item->>'id')::uuid AND gr_id = p_grn_id;

                    GET DIAGNOSTICS v_line_rows = ROW_COUNT;
                    IF v_line_rows <> 1 THEN
                        RAISE EXCEPTION 'GRN line % is not a line of this GRN; reload the GRN and edit again', v_item->>'id';
                    END IF;

                    v_items_updated := v_items_updated + 1;

                    v_items_skipped_stock := v_items_skipped_stock || jsonb_build_object(
                        'grn_trl_item_id', v_item->>'id',
                        'item_name', v_item_name_from_db,
                        'reason', format('Cannot update qty/stock - item has %s units dispatched', v_dispatched_qty),
                        'current_qty', v_current_qty,
                        'current_stock', v_current_stock,
                        'dispatched_qty', v_dispatched_qty
                    );
                END IF;

                v_provided_grn_item_ids := array_append(v_provided_grn_item_ids, (v_item->>'id')::uuid);
            ELSE
                INSERT INTO goodsreceived_trl (
                    gr_id, item_id, item_name, packaging, qty, stock, weight, rack, package_mark
                ) VALUES (
                    p_grn_id, v_item_master_id, v_item_name, v_item->>'packaging',
                    (v_item->>'qty')::int, (v_item->>'qty')::int,
                    COALESCE((v_item->>'weight')::int, 0), warehouse_security.ascii_digits(v_item->>'rack'),
                    warehouse_security.ascii_digits(v_item->>'package_mark')
                ) RETURNING id INTO v_grn_trl_item_id;

                v_items_added := v_items_added + 1;

                v_item_mapping := v_item_mapping || jsonb_build_object(
                    'index', v_item_index,
                    'grn_trl_item_id', v_grn_trl_item_id,
                    'item_name', v_item_name
                );
            END IF;

            v_item_index := v_item_index + 1;
        END LOOP;

        IF v_existing_grn_item_ids IS NOT NULL THEN
            v_items_to_delete := ARRAY(
                SELECT unnest(v_existing_grn_item_ids)
                EXCEPT
                SELECT unnest(v_provided_grn_item_ids)
            );

            IF v_items_to_delete IS NOT NULL THEN
                FOR v_grn_trl_item_id IN SELECT unnest(v_items_to_delete)
                LOOP
                    SELECT COUNT(*) INTO v_dispatched_qty
                    FROM dispatch_trl
                    WHERE gr_trl_id = v_grn_trl_item_id;

                    IF v_dispatched_qty > 0 THEN
                        SELECT item_name INTO v_item_name_from_db
                        FROM goodsreceived_trl
                        WHERE id = v_grn_trl_item_id;

                        RAISE EXCEPTION 'Cannot delete item "%" - has % existing dispatches',
                            v_item_name_from_db, v_dispatched_qty;
                    END IF;

                    DELETE FROM goodsreceived_trl WHERE id = v_grn_trl_item_id;
                    v_items_deleted := v_items_deleted + 1;
                END LOOP;
            END IF;
        END IF;

        IF jsonb_array_length(p_images) > 0 THEN
            v_kept_image_ids := ARRAY[]::uuid[];

            FOR v_image IN SELECT * FROM jsonb_array_elements(p_images)
            LOOP
                IF v_image->>'storage_path' IS NULL OR v_image->>'image_type' IS NULL THEN
                    RAISE EXCEPTION 'Invalid image data: storage_path and image_type are required';
                END IF;

                v_resolved_item_id := NULL;
                IF v_image->>'image_type' = 'item' THEN
                    IF v_image->>'grn_item_id' IS NOT NULL THEN
                        v_resolved_item_id := (v_image->>'grn_item_id')::uuid;
                    ELSIF v_image->>'item_index' IS NOT NULL THEN
                        SELECT (mapping->>'grn_trl_item_id')::uuid INTO v_resolved_item_id
                        FROM jsonb_array_elements(v_item_mapping) mapping
                        WHERE (mapping->>'index')::int = (v_image->>'item_index')::int;

                        IF v_resolved_item_id IS NULL THEN
                            RAISE EXCEPTION 'Invalid item_index % for image', v_image->>'item_index';
                        END IF;
                    ELSE
                        RAISE EXCEPTION 'Item images must have either grn_item_id or item_index';
                    END IF;
                END IF;

                IF v_resolved_item_id IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM goodsreceived_trl WHERE id = v_resolved_item_id AND gr_id = p_grn_id) THEN
                    RAISE EXCEPTION 'Image line does not belong to this GRN';
                END IF;

                v_image_id := NULL;
                IF v_image->>'id' IS NOT NULL AND NOT (v_image->>'id' LIKE 'temp_%') THEN
                    SELECT id INTO v_image_id FROM grn_images
                    WHERE id = (v_image->>'id')::uuid AND grn_id = p_grn_id;
                END IF;
                IF v_image_id IS NULL THEN
                    SELECT id INTO v_image_id FROM grn_images
                    WHERE grn_id = p_grn_id AND storage_path = v_image->>'storage_path'
                    ORDER BY created_at, id LIMIT 1;
                END IF;

                IF v_image_id IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM grn_images seen
                    WHERE seen.id = v_image_id
                    AND warehouse_security.grn_image_visible(seen.status, seen.uploaded_by)) THEN
                    -- Migration 69: another person's pending photo, named in the list, stays as it is.
                    v_kept_image_ids := array_append(v_kept_image_ids, v_image_id);
                ELSIF v_image_id IS NOT NULL THEN
                    UPDATE grn_images SET
                        grn_item_id = v_resolved_item_id,
                        updated_at = now()
                    WHERE id = v_image_id AND grn_id = p_grn_id;

                    v_images_updated := v_images_updated + 1;
                    v_kept_image_ids := array_append(v_kept_image_ids, v_image_id);
                ELSE
                    PERFORM warehouse_security.require_image_path('grn', p_grn_id, v_image->>'image_type', v_image->>'storage_path');

                    v_image_id := gen_random_uuid();

                    INSERT INTO grn_images (
                        id, grn_id, grn_item_id, image_type, storage_path,
                        original_filename, file_size, mime_type, uploaded_by, status
                    ) VALUES (
                        v_image_id, p_grn_id, v_resolved_item_id, v_image->>'image_type',
                        v_image->>'storage_path', COALESCE(v_image->>'original_filename', 'unknown'),
                        COALESCE((v_image->>'file_size')::int, 0),
                        COALESCE(v_image->>'mime_type', 'image/jpeg'), v_user_profile_id, 'confirmed'
                    );

                    v_images_added := v_images_added + 1;
                    v_kept_image_ids := array_append(v_kept_image_ids, v_image_id);
                END IF;
            END LOOP;

            DELETE FROM grn_images
            WHERE grn_id = p_grn_id
            AND id NOT IN (SELECT unnest(v_kept_image_ids))
            AND warehouse_security.grn_image_visible(grn_images.status, grn_images.uploaded_by);

            GET DIAGNOSTICS v_images_deleted = ROW_COUNT;
        ELSE
            v_images_deleted := 0;
        END IF;

        -- The GRN's own rates follow its lines, whether or not p_rates came: a rate of another pricing
        -- kind, or one whose band holds no weight of its item's lines any more, goes. An invoiced
        -- GRN keeps its (archived) rates.
        -- (Migration 121: the rates that go are collected, to refuse the edit below when it would drop a rate it may not.)
        WITH gone AS (
            DELETE FROM public.grn_rates gr WHERE gr.gr_id = p_grn_id
              AND NOT EXISTS (SELECT 1 FROM public.goodsreceived g WHERE g.id = p_grn_id AND g.invoiced IS TRUE)
              AND (gr.price_type <> (SELECT CASE WHEN upper(COALESCE(g.pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END
                                       FROM public.goodsreceived g WHERE g.id = p_grn_id)
                   OR NOT EXISTS (SELECT 1 FROM public.goodsreceived_trl t WHERE t.gr_id = p_grn_id AND t.item_id = gr.item_id
                                    AND COALESCE(t.weight, 0) BETWEEN gr.weight_min AND gr.weight_max))
            RETURNING gr.item_id, gr.weight_min, gr.weight_max
        )
        SELECT count(*)::integer,
               COALESCE(array_agg(DISTINCT i.name ORDER BY i.name) FILTER (WHERE i.name IS NOT NULL), ARRAY[]::text[]),
               COALESCE(jsonb_agg(jsonb_build_object('item_id', gone.item_id, 'weight_min', gone.weight_min, 'weight_max', gone.weight_max)), '[]'::jsonb)
        INTO v_dropped_count, v_dropped_items, v_dropped_rows
        FROM gone
        LEFT JOIN public.items i ON i.id = gone.item_id;

        -- Rates typed on the GRN sheet (migration 86), after the lines are written. A failure
        -- raises out of this block, which undoes the update, and the handler answers it.
        IF p_rates IS NOT NULL THEN
            v_rate_failure := warehouse_security.apply_grn_rates(p_grn_id, p_rates);
            IF v_rate_failure IS NOT NULL THEN
                RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = v_rate_failure::text;
            END IF;
        END IF;

        -- D10, D24 (migration 121): a rate set for this GRN alone is not dropped by an edit that did not mean to.
        -- Staff: any rate the edit removes is refused (they cannot send rates; a manager makes the change).
        -- Administrators and supervisors: refused when a line whose weight, or the GRN's pricing mode, was changed by this save
        -- loses its GRN-only rate and is not priced again by this save (a rate of any scope for that item and weight in
        -- p_rates, or a GRN-only rate it still has). A rate they remove on purpose in the Rates step is not this case. The
        -- raise rolls the whole edit back and the handler answers it.
        IF v_dropped_count > 0 THEN
            IF warehouse_security.active_role() = 'staff' THEN
                RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('RATES_NEED_MANAGER',
                    'Ask a manager to make this change: it would remove a rate that was set for this GRN.',
                    jsonb_build_object('gr_no', v_stored_gr_no, 'rates', v_dropped_count, 'items', to_jsonb(v_dropped_items)))::text;
            ELSIF warehouse_security.active_role() IN ('admin', 'supervisor') THEN
                SELECT CASE WHEN upper(COALESCE(g.pricing_mode, '')) = 'ONE_TIME' THEN 'one_time' ELSE 'monthly' END
                INTO v_type_after
                FROM goodsreceived g
                WHERE g.id = p_grn_id;

                SELECT count(DISTINCT (d.item_id, d.weight_min, d.weight_max))::integer,
                       COALESCE(array_agg(DISTINCT i.name ORDER BY i.name) FILTER (WHERE i.name IS NOT NULL), ARRAY[]::text[])
                INTO v_would_drop_count, v_would_drop_items
                FROM jsonb_to_recordset(v_dropped_rows) AS d(item_id uuid, weight_min integer, weight_max integer)
                JOIN jsonb_to_recordset(v_lines_before) AS b(id uuid, item_id uuid, weight integer)
                  ON b.item_id = d.item_id AND b.weight BETWEEN d.weight_min AND d.weight_max
                JOIN goodsreceived_trl t ON t.id = b.id AND t.gr_id = p_grn_id AND t.item_id = b.item_id
                LEFT JOIN items i ON i.id = d.item_id
                WHERE (COALESCE(t.weight, 0) <> b.weight OR v_type_after <> v_type_before)
                  AND NOT EXISTS (SELECT 1 FROM grn_rates g
                                  WHERE g.gr_id = p_grn_id AND g.item_id = t.item_id AND g.price_type = v_type_after
                                    AND COALESCE(t.weight, 0) BETWEEN g.weight_min AND g.weight_max)
                  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(p_rates, '[]'::jsonb)) AS x(e)
                                  WHERE lower(x.e->>'item_id') = t.item_id::text
                                    AND (x.e->>'weight_min')::numeric <= COALESCE(t.weight, 0)
                                    AND COALESCE(t.weight, 0) <= (x.e->>'weight_max')::numeric);

                IF v_would_drop_count > 0 THEN
                    RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('RATES_WOULD_DROP',
                        'This change removes the rate set for this GRN. Set a new rate in Rates.',
                        jsonb_build_object('gr_no', v_stored_gr_no, 'rates', v_would_drop_count, 'items', to_jsonb(v_would_drop_items)))::text;
                END IF;
            END IF;
        END IF;

        PERFORM safe_enable_grn_trl_triggers();

        PERFORM pg_advisory_xact_lock(71040);

        SELECT jsonb_agg(
            jsonb_build_object(
                'id', t.id,
                'item_id', t.item_id,
                'item_name', t.item_name,
                'packaging', t.packaging,
                'qty', t.qty,
                'stock', t.stock,
                'weight', t.weight,
                'rack', t.rack,
                'package_mark', t.package_mark
            )
        ) INTO v_grn_items
        FROM goodsreceived_trl t
        WHERE t.gr_id = p_grn_id;

        SELECT jsonb_agg(
            jsonb_build_object(
                'id', i.id,
                'image_type', i.image_type,
                'storage_path', i.storage_path,
                'grn_item_id', i.grn_item_id,
                'original_filename', i.original_filename
            )
        ) INTO v_grn_images
        FROM grn_images i
        WHERE i.grn_id = p_grn_id
        AND warehouse_security.grn_image_visible(i.status, i.uploaded_by);

        SELECT jsonb_build_object(
            'id', g.id,
            'gr_no', g.gr_no,
            'date', g.date,
            'customer_id', g.customer_id,
            'customer_name', g.customer_name,
            'sender_id', g.sender_id,
            'sender_name', g.sender_name,
            'supervisor_id', g.supervisor_id,
            'supervisor_name', g.supervisor_name,
            'registration', g.registration,
            'note', g.note,
            'leon', g.leon,
            'pricing_mode', g.pricing_mode,
            'duration_mode', g.duration_mode,
            'updated_at', g.updated_at
        ) INTO v_grn_header
        FROM goodsreceived g
        WHERE g.id = p_grn_id;

        v_final_grn_data := v_grn_header || jsonb_build_object(
            'items', COALESCE(v_grn_items, '[]'::jsonb),
            'images', COALESCE(v_grn_images, '[]'::jsonb)
        );

        v_result := jsonb_build_object(
            'success', true,
            'message', 'GRN updated successfully',
            'grn', v_final_grn_data,
            'stats', jsonb_build_object(
                'items_updated', v_items_updated,
                'items_added', v_items_added,
                'items_deleted', v_items_deleted,
                'images_updated', v_images_updated,
                'images_added', v_images_added,
                'images_deleted', v_images_deleted,
                'items_skipped_stock', v_items_skipped_stock
            ),
            'item_mapping', v_item_mapping
        );

        -- Kept for the 7 days a retry is answered from it (migration 120). A key another
        -- function or user holds is left alone unless it has expired.
        IF p_idempotency_key IS NOT NULL THEN
            INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
            VALUES (p_idempotency_key, 'update_grn', v_result, v_user_profile_id, now() + interval '7 days')
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

    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'rate_fail' THEN
            GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
            PERFORM safe_enable_grn_trl_triggers();
            RETURN v_detail::jsonb;
        END IF;
        PERFORM safe_enable_grn_trl_triggers();
        RAISE;
    END;
END;
$$;
ALTER FUNCTION public.update_grn(p_grn_id uuid, p_gr_no character varying, p_date timestamp with time zone, p_customer_id uuid, p_customer_name character varying, p_sender_id uuid, p_sender_name character varying, p_supervisor_id uuid, p_supervisor_name character varying, p_registration character varying, p_note character varying, p_leon boolean, p_pricing_mode character varying, p_items jsonb, p_images jsonb, p_duration_mode character varying, p_idempotency_key text, p_rates jsonb, p_expected_updated_at timestamp with time zone) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.update_grn(p_grn_id uuid, p_gr_no character varying, p_date timestamp with time zone, p_customer_id uuid, p_customer_name character varying, p_sender_id uuid, p_sender_name character varying, p_supervisor_id uuid, p_supervisor_name character varying, p_registration character varying, p_note character varying, p_leon boolean, p_pricing_mode character varying, p_items jsonb, p_images jsonb, p_duration_mode character varying, p_idempotency_key text, p_rates jsonb, p_expected_updated_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_grn(p_grn_id uuid, p_gr_no character varying, p_date timestamp with time zone, p_customer_id uuid, p_customer_name character varying, p_sender_id uuid, p_sender_name character varying, p_supervisor_id uuid, p_supervisor_name character varying, p_registration character varying, p_note character varying, p_leon boolean, p_pricing_mode character varying, p_items jsonb, p_images jsonb, p_duration_mode character varying, p_idempotency_key text, p_rates jsonb, p_expected_updated_at timestamp with time zone) TO service_role;
GRANT ALL ON FUNCTION public.update_grn(p_grn_id uuid, p_gr_no character varying, p_date timestamp with time zone, p_customer_id uuid, p_customer_name character varying, p_sender_id uuid, p_sender_name character varying, p_supervisor_id uuid, p_supervisor_name character varying, p_registration character varying, p_note character varying, p_leon boolean, p_pricing_mode character varying, p_items jsonb, p_images jsonb, p_duration_mode character varying, p_idempotency_key text, p_rates jsonb, p_expected_updated_at timestamp with time zone) TO authenticated;

-- Section 9: invoice save and edit
-- D9: save_invoice(jsonb) refuses a GRN that still has stock
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
    v_stock_left bigint;
    v_lots_left integer;
    v_stock_gr_no text;
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

    -- D9 (migration 121): an invoice is made when the GRN's goods are out. A GRN with stock in any lot is refused, before
    -- anything is written; the stock is dispatched first. (An invoice that already exists on a GRN that now holds stock is
    -- refused on its next edit too.)
    SELECT COALESCE(SUM(t.stock), 0), count(*) FILTER (WHERE t.stock > 0),
           (SELECT g.gr_no FROM goodsreceived g WHERE g.id = COALESCE(v_invoice_header->>'grn_id', p_invoice_data->>'gr_id')::uuid)
    INTO v_stock_left, v_lots_left, v_stock_gr_no
    FROM goodsreceived_trl t
    WHERE t.gr_id = COALESCE(v_invoice_header->>'grn_id', p_invoice_data->>'gr_id')::uuid;
    IF v_stock_left > 0 THEN
        RETURN warehouse_security.refuse('GRN_HAS_STOCK',
            format('GRN %s still has %s in stock. Dispatch it first, then make the invoice.', v_stock_gr_no, v_stock_left),
            jsonb_build_object('gr_no', v_stock_gr_no, 'stock', v_stock_left, 'lots', v_lots_left));
    END IF;

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
-- D9, D18: the three-argument save_invoice (through save_invoice_internal) refuses a GRN that still has stock and checks the total
-- the user confirmed
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
    v_stock_left bigint;
    v_lots_left integer;
    v_stock_gr_no text;
    v_total_now numeric;
    v_lines jsonb;
    v_detail text;
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

    -- D9 (migration 121): an invoice is made when the GRN's goods are out. A GRN with stock in any lot is refused, before
    -- anything is written; the stock is dispatched first. (An invoice that already exists on a GRN that now holds stock is
    -- refused on its next edit too.)
    SELECT COALESCE(SUM(t.stock), 0), count(*) FILTER (WHERE t.stock > 0),
           (SELECT g.gr_no FROM goodsreceived g WHERE g.id = v_new_gr_id)
    INTO v_stock_left, v_lots_left, v_stock_gr_no
    FROM goodsreceived_trl t
    WHERE t.gr_id = v_new_gr_id;
    IF v_stock_left > 0 THEN
        RETURN warehouse_security.refuse('GRN_HAS_STOCK',
            format('GRN %s still has %s in stock. Dispatch it first, then make the invoice.', v_stock_gr_no, v_stock_left),
            jsonb_build_object('gr_no', v_stock_gr_no, 'stock', v_stock_left, 'lots', v_lots_left)) || jsonb_build_object('function_version', v_function_version);
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

    -- D18 (migration 121): the total the phone showed and the user confirmed is checked against the total the server has just
    -- worked out from the dates. A difference of more than 1.00 rolls the whole save back (the raise leaves the block, whose
    -- writes are undone, and the handler answers it) and names the days the server used, so the form can show the figures
    -- again. No expected_total (an older app): no check; the old total key stays an estimate.
    IF jsonb_typeof(p_invoice_data->'expected_total') = 'number' THEN
        SELECT i.total INTO v_total_now FROM invoice i WHERE i.id = v_final_invoice_id;
        IF abs(COALESCE(v_total_now, 0) - (p_invoice_data->>'expected_total')::numeric) > 1.00 THEN
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'disp_trl_id', it.disp_trl_id, 'duration', it.duration, 'no_of_days', it.no_of_days
                   ) ORDER BY uuid_extract_timestamp(it.id), it.id), '[]'::jsonb)
            INTO v_lines
            FROM invoice_trl it
            WHERE it.invoice_id = v_final_invoice_id;
            RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('TOTAL_CHANGED',
                format('The total is now %s, not %s. Review the figures and save again.',
                       COALESCE(v_total_now, 0), (p_invoice_data->>'expected_total')::numeric),
                jsonb_build_object('current_total', COALESCE(v_total_now, 0),
                                   'expected_total', p_invoice_data->'expected_total',
                                   'lines', v_lines))::text;
        END IF;
    END IF;

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
    -- A refusal raised after the write (the total check): the block is rolled back and the refusal is the answer.
    IF SQLERRM = 'rate_fail' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        RETURN v_detail::jsonb || jsonb_build_object('function_version', v_function_version);
    END IF;
    RETURN jsonb_build_object(
        'success', false,
        'error', SQLERRM,
        'error_code', SQLSTATE,
        'function_version', v_function_version
    );
END;
$$;
-- D1, D9, D18: update_invoice checks the version token, refuses a GRN that still has stock, checks the confirmed total, and
-- returns the new token
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
    v_stored_updated_at timestamptz;
    v_expected_at timestamptz;
    v_stock_left bigint;
    v_lots_left integer;
    v_stock_gr_no text;
    v_total_now numeric;
    v_lines jsonb;
    v_detail text;
    v_new_updated_at timestamptz;
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

    SELECT gr_id, duration_mode, inv_date, inv_fin_year, updated_at
    INTO v_old_gr_id, v_stored_duration_mode, v_stored_inv_date, v_stored_fin_year, v_stored_updated_at
    FROM invoice WHERE id = p_invoice_id AND deleted_at IS NULL
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invoice not found');
    END IF;

    -- D1 (migration 121): an invoice that changed after the caller read it is not saved over; nothing is written. The token is
    -- the invoice's updated_at, sent as expected_updated_at in p_invoice_data. This runs after the saved-answer replay above,
    -- so a resend of this user's own lost save is never refused for what its first try changed. No token: no check.
    IF NULLIF(p_invoice_data->>'expected_updated_at', '') IS NOT NULL THEN
        v_expected_at := (p_invoice_data->>'expected_updated_at')::timestamptz;
        IF date_trunc('milliseconds', v_stored_updated_at) IS DISTINCT FROM date_trunc('milliseconds', v_expected_at) THEN
            RETURN warehouse_security.refuse('STALE_RECORD', 'Someone else changed this invoice. Open it again.',
                jsonb_build_object('what', 'invoice', 'id', p_invoice_id,
                                   'expected_updated_at', v_expected_at, 'current_updated_at', v_stored_updated_at));
        END IF;
    END IF;

    -- D9 (migration 121): an invoice is made when the GRN's goods are out. A GRN with stock in any lot is refused, before
    -- anything is written; the stock is dispatched first. (An invoice that already exists on a GRN that now holds stock is
    -- refused on its next edit too.)
    SELECT COALESCE(SUM(t.stock), 0), count(*) FILTER (WHERE t.stock > 0),
           (SELECT g.gr_no FROM goodsreceived g WHERE g.id = v_new_gr_id)
    INTO v_stock_left, v_lots_left, v_stock_gr_no
    FROM goodsreceived_trl t
    WHERE t.gr_id = v_new_gr_id;
    IF v_stock_left > 0 THEN
        RETURN warehouse_security.refuse('GRN_HAS_STOCK',
            format('GRN %s still has %s in stock. Dispatch it first, then make the invoice.', v_stock_gr_no, v_stock_left),
            jsonb_build_object('gr_no', v_stock_gr_no, 'stock', v_stock_left, 'lots', v_lots_left));
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

    -- D18 (migration 121): the total the phone showed and the user confirmed is checked against the total the server has just
    -- worked out from the dates. A difference of more than 1.00 rolls the whole save back (the raise leaves the block, whose
    -- writes are undone, and the handler answers it) and names the days the server used, so the form can show the figures
    -- again. No expected_total (an older app): no check; the old total key stays an estimate.
    IF jsonb_typeof(p_invoice_data->'expected_total') = 'number' THEN
        SELECT i.total INTO v_total_now FROM invoice i WHERE i.id = p_invoice_id;
        IF abs(COALESCE(v_total_now, 0) - (p_invoice_data->>'expected_total')::numeric) > 1.00 THEN
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'disp_trl_id', it.disp_trl_id, 'duration', it.duration, 'no_of_days', it.no_of_days
                   ) ORDER BY uuid_extract_timestamp(it.id), it.id), '[]'::jsonb)
            INTO v_lines
            FROM invoice_trl it
            WHERE it.invoice_id = p_invoice_id;
            RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = warehouse_security.refuse('TOTAL_CHANGED',
                format('The total is now %s, not %s. Review the figures and save again.',
                       COALESCE(v_total_now, 0), (p_invoice_data->>'expected_total')::numeric),
                jsonb_build_object('current_total', COALESCE(v_total_now, 0),
                                   'expected_total', p_invoice_data->'expected_total',
                                   'lines', v_lines))::text;
        END IF;
    END IF;

    SELECT i.updated_at INTO v_new_updated_at FROM invoice i WHERE i.id = p_invoice_id;

    v_result := jsonb_build_object(
        'success', true,
        'invoice_id', p_invoice_id,
        'invoice_no', v_invoice_no,
        'invoice_number', v_invoice_no,
        'items_count', v_items_count,
        'duration_mode', v_duration_mode,
        'updated_at', v_new_updated_at,
        'message', 'Invoice updated successfully'
    );

    -- The answer is kept for the 7 days a resend is answered from it, as the dispatch create answer is (migration
    -- 120). A code that another function or user holds is left alone unless it has expired.
    IF v_request_key IS NOT NULL THEN
        INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
        VALUES (v_request_key, 'update_invoice', v_result, v_user_id, now() + interval '7 days')
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
    -- A refusal raised after the write (the total check): the block is rolled back and the refusal is the answer.
    IF SQLERRM = 'rate_fail' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        RETURN v_detail::jsonb;
    END IF;
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END;
$$;
