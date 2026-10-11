-- Invoice line rules (review, 2026-10-10).
--
-- 1. Line rates have a range. charge and labour_rate must lie between 0 and
--    999999 and tax between 0 and 100 on every save path. Zero stays allowed
--    (rates remain inputs), and a negative discount stays a surcharge. Before,
--    a negative labour rate or tax could bring an invoice to nothing without
--    touching the discount that migration 30 guards.
-- 2. A dispatch line is invoiced once. A save refuses a receipt that is already
--    marked invoiced and a line that is on another invoice; before, the second
--    of two saves for one receipt succeeded under a new invoice number.
-- 3. Billable days are counted between calendar dates in India
--    (Asia/Kolkata), not in the database session's time zone. The preview and
--    all three save paths use the same dates.
-- 4. Every discount change is appended to invoice_discount_history; the three
--    migration-30 columns on the invoice keep the last change. A reason made
--    only of white space (tab, no-break space, zero-width space ...) is empty.
-- 5. get_invoice_detail returns the discount reason, author and time to the
--    warehouse roles. get_invoice_items_detailed computes line amounts as the
--    header does. delete_invoice refuses an invoice that has payments.
--
-- The rules are enforced when an invoice is written. No existing row is
-- validated or changed; the block at the end only reports dispatch lines that
-- are already on more than one invoice.

-- 3. One place that says which calendar date a stored moment falls on. There
-- is no facility time-zone setting; when one is added, only this function
-- changes.
CREATE FUNCTION warehouse_security.business_date(moment timestamptz) RETURNS date
LANGUAGE sql STABLE SET search_path = pg_catalog AS $$
  SELECT (moment AT TIME ZONE 'Asia/Kolkata')::date
$$;
REVOKE ALL ON FUNCTION warehouse_security.business_date(timestamptz) FROM PUBLIC, anon, authenticated, service_role;

-- 1. The range check lives where all three save paths already meet, after the
-- lines are saved. The remainder of the body is the migration-24 text.
CREATE OR REPLACE FUNCTION warehouse_security.recalculate_invoice_header(p_invoice_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE line_count integer; subtotal numeric(12,2); labour_total numeric(12,2); tax_basis numeric;
  tax_total numeric(12,2); grand numeric(12,2); discount_value numeric(12,2);
  bad_charge integer; bad_labour integer; bad_tax integer;
BEGIN
  SELECT count(*) FILTER (WHERE it.charge < 0 OR it.charge > 999999),
         count(*) FILTER (WHERE it.labour_rate < 0 OR it.labour_rate > 999999),
         count(*) FILTER (WHERE it.tax < 0 OR it.tax > 100)
    INTO bad_charge, bad_labour, bad_tax
  FROM public.invoice_trl it WHERE it.invoice_id=p_invoice_id;
  IF bad_charge > 0 THEN RAISE EXCEPTION 'Invoice line charge must be between 0 and 999999' USING ERRCODE = '22023'; END IF;
  IF bad_labour > 0 THEN RAISE EXCEPTION 'Invoice line labour rate must be between 0 and 999999' USING ERRCODE = '22023'; END IF;
  IF bad_tax > 0 THEN RAISE EXCEPTION 'Invoice line tax must be between 0 and 100' USING ERRCODE = '22023'; END IF;
  SELECT count(*), COALESCE(sum(l.base),0), COALESCE(sum(l.labour),0), COALESCE(sum(l.base*l.tax_percent/100.0),0)
    INTO line_count, subtotal, labour_total, tax_basis
  FROM (
    SELECT
      CASE WHEN gr.pricing_mode='ONE_TIME'
        THEN round(COALESCE(it.charge,0)*dt.disp_qty,2)
        ELSE round(COALESCE(it.charge,0)*dt.disp_qty*COALESCE(it.duration,1),2)
             + round(COALESCE(it.labour_rate,0)*dt.disp_qty,2) END AS base,
      CASE WHEN gr.pricing_mode='ONE_TIME' THEN 0::numeric
        ELSE round(COALESCE(it.labour_rate,0)*dt.disp_qty,2) END AS labour,
      COALESCE(it.tax,0) AS tax_percent
    FROM public.invoice_trl it
    JOIN public.dispatch_trl dt ON dt.id=it.disp_trl_id
    JOIN public.goodsreceived gr ON gr.id=dt.gr_id
    WHERE it.invoice_id=p_invoice_id) l;
  IF line_count=0 THEN RAISE EXCEPTION 'Invoice requires at least one dispatch line'; END IF;
  SELECT COALESCE(discount,0) INTO discount_value FROM public.invoice WHERE id=p_invoice_id;
  tax_total := ceil(tax_basis);
  grand := ceil(subtotal + tax_total - discount_value);
  IF grand < 0 THEN RAISE EXCEPTION 'Discount exceeds the invoice amount'; END IF;
  UPDATE public.invoice SET labour=labour_total, tax_amount=tax_total, total=grand WHERE id=p_invoice_id;
  RETURN jsonb_build_object('subtotal',subtotal,'labour',labour_total,'tax',tax_total,'total_tax',tax_total,
    'discount',discount_value,'grand_total',grand,'total',grand,'total_rows',line_count);
END $$;
REVOKE ALL ON FUNCTION warehouse_security.recalculate_invoice_header(uuid) FROM PUBLIC,anon,authenticated,service_role;

-- 2. Called by every save path before it writes. The receipt row is locked
-- (as the UPDATE that marks it invoiced would lock it, so dispatch saves
-- holding a key-share lock are not held up): two saves for one receipt run one
-- after the other and the second sees the first. p_invoice_id is NULL for a new invoice. For an edit, the invoice's own
-- receipt and the lines it already holds are not counted against it, so an
-- invoice saved before this rule can still be edited as it stands.
CREATE FUNCTION warehouse_security.claim_invoice_lines(p_invoice_id uuid, p_gr_id uuid, p_lines uuid[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE receipt_invoiced boolean; own_receipt uuid;
BEGIN
  SELECT g.invoiced INTO receipt_invoiced FROM public.goodsreceived g WHERE g.id=p_gr_id FOR NO KEY UPDATE;
  SELECT i.gr_id INTO own_receipt FROM public.invoice i WHERE i.id=p_invoice_id;
  IF receipt_invoiced IS TRUE AND own_receipt IS DISTINCT FROM p_gr_id THEN
    RAISE EXCEPTION 'GRN is already invoiced' USING ERRCODE = 'WH409';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.invoice_trl other
    JOIN public.invoice holder ON holder.id=other.invoice_id
    WHERE other.disp_trl_id = ANY(p_lines)
      AND holder.deleted_at IS NULL
      AND other.invoice_id IS DISTINCT FROM p_invoice_id
      AND NOT EXISTS (SELECT 1 FROM public.invoice_trl mine
                      WHERE mine.invoice_id=p_invoice_id AND mine.disp_trl_id=other.disp_trl_id)
  ) THEN
    RAISE EXCEPTION 'A dispatch line is already on another invoice' USING ERRCODE = 'WH409';
  END IF;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.claim_invoice_lines(uuid,uuid,uuid[]) FROM PUBLIC,anon,authenticated,service_role;

-- 2 and 3 in the three save paths. Each raise reaches the function's own
-- handler, which returns the text after rolling everything back.
DO $patch$
DECLARE fn regprocedure; definition text; marker text; replacement text; occurrences integer;
  duration_marker constant text := $m$public.calculate_invoice_duration(gr.date::date, disp.disp_date::date, v_duration_mode)$m$;
  duration_replacement constant text := $r$public.calculate_invoice_duration(warehouse_security.business_date(gr.date), warehouse_security.business_date(disp.disp_date), v_duration_mode)$r$;
BEGIN
  fn := 'public.save_invoice(jsonb)'::regprocedure;
  definition := pg_get_functiondef(fn);
  occurrences := (length(definition)-length(replace(definition,duration_marker,'')))/length(duration_marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one duration call in %, found %', fn, occurrences; END IF;
  definition := replace(definition,duration_marker,duration_replacement);
  marker := $m$    -- Header money columns are placeholders until the lines are saved below.$m$;
  replacement := $r$    PERFORM warehouse_security.claim_invoice_lines(NULL,
        COALESCE(v_invoice_header->>'grn_id', p_invoice_data->>'gr_id')::uuid,
        ARRAY(SELECT COALESCE(item->>'disp_trl_id', item->>'dispatches_items_id', item->>'dispatch_item_id')::uuid
              FROM jsonb_array_elements(v_invoice_items) AS item));

    -- Header money columns are placeholders until the lines are saved below.$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one header-insert marker in %, found %', fn, occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);

  fn := 'public.save_invoice_internal(uuid,jsonb,jsonb[])'::regprocedure;
  definition := pg_get_functiondef(fn);
  occurrences := (length(definition)-length(replace(definition,duration_marker,'')))/length(duration_marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one duration call in %, found %', fn, occurrences; END IF;
  definition := replace(definition,duration_marker,duration_replacement);
  marker := $m$    v_duration_mode := public.validate_invoice_duration_mode(p_invoice_data->>'duration_mode');
$m$;
  replacement := $r$    v_duration_mode := public.validate_invoice_duration_mode(p_invoice_data->>'duration_mode');
    PERFORM warehouse_security.claim_invoice_lines(NULL, v_new_gr_id,
        ARRAY(SELECT (item->>'disp_trl_id')::uuid FROM unnest(p_invoice_items) AS item));
$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one duration-mode marker in %, found %', fn, occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);

  fn := 'public.update_invoice(uuid,jsonb,jsonb[])'::regprocedure;
  definition := pg_get_functiondef(fn);
  occurrences := (length(definition)-length(replace(definition,duration_marker,'')))/length(duration_marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one duration call in %, found %', fn, occurrences; END IF;
  definition := replace(definition,duration_marker,duration_replacement);
  marker := $m$    IF v_old_gr_id IS DISTINCT FROM v_new_gr_id THEN$m$;
  replacement := $r$    PERFORM warehouse_security.claim_invoice_lines(p_invoice_id, v_new_gr_id,
        ARRAY(SELECT (item->>'disp_trl_id')::uuid FROM unnest(p_invoice_items) AS item));

    IF v_old_gr_id IS DISTINCT FROM v_new_gr_id THEN$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one receipt-change marker in %, found %', fn, occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);

  -- 3. The preview reads the receipt date into a date variable and casts each
  -- dispatch date; both now go through business_date.
  fn := 'public.build_invoice_recalculation_rows(uuid,text,uuid)'::regprocedure;
  definition := pg_get_functiondef(fn);
  marker := $m$    SELECT date, customer_id, pricing_mode
    INTO v_grn_date, v_grn_customer_id, v_grn_pricing_mode$m$;
  replacement := $r$    SELECT warehouse_security.business_date(date), customer_id, pricing_mode
    INTO v_grn_date, v_grn_customer_id, v_grn_pricing_mode$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one receipt-date read in %, found %', fn, occurrences; END IF;
  definition := replace(definition,marker,replacement);
  marker := $m$v_dispatch_record.dispatches_date::date$m$;
  replacement := $r$warehouse_security.business_date(v_dispatch_record.dispatches_date)$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 2 THEN RAISE EXCEPTION 'Expected two dispatch-date casts in %, found %', fn, occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- 4. One row per discount change, kept when the invoice is edited again or
-- deleted (no foreign keys: delete_invoice removes the invoice row, and a
-- deleted account must not take the record with it). Written only by the
-- trigger below; nobody is granted a write, and a row cannot be changed or
-- removed afterwards. Administrators and supervisors read it, like the invoice
-- table itself.
CREATE TABLE public.invoice_discount_history (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  invoice_id uuid NOT NULL,
  inv_fin_year integer,
  inv_no integer,
  customer_id uuid,
  old_discount numeric(12,2) NOT NULL,
  new_discount numeric(12,2) NOT NULL,
  reason text,
  changed_by uuid,
  changed_by_role text,
  changed_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.invoice_discount_history IS
  'Append-only record of every invoice discount change (migration 41). invoice.discount_reason / discount_set_by / discount_set_at keep the last change.';
COMMENT ON COLUMN public.invoice_discount_history.changed_by IS 'user_profiles.id of the account that changed the discount.';
CREATE INDEX invoice_discount_history_invoice_idx ON public.invoice_discount_history (invoice_id, id);
ALTER TABLE public.invoice_discount_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.invoice_discount_history FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.invoice_discount_history TO authenticated, service_role;
CREATE POLICY starter_staff ON public.invoice_discount_history FOR SELECT TO authenticated
  USING (warehouse_security.active_role() IN ('admin','supervisor'));

CREATE FUNCTION warehouse_security.invoice_discount_history_append_only() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  RAISE EXCEPTION 'Invoice discount history cannot be changed' USING ERRCODE = '42501';
END $$;
REVOKE ALL ON FUNCTION warehouse_security.invoice_discount_history_append_only() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER invoice_discount_history_append_only BEFORE UPDATE OR DELETE ON public.invoice_discount_history
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.invoice_discount_history_append_only();
CREATE TRIGGER invoice_discount_history_no_truncate BEFORE TRUNCATE ON public.invoice_discount_history
  FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.invoice_discount_history_append_only();

-- The migration-30 trigger function with two changes: the reason is trimmed of
-- every kind of white space and invisible character, not only U+0020, and each
-- change is appended to the history.
CREATE OR REPLACE FUNCTION warehouse_security.invoice_discount_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  blank constant text := '[\s\u0085 ­ ᠎ -‏ -  -⁤　﻿]+';
  reason text := NULLIF(regexp_replace(COALESCE(current_setting('warehouse.discount_reason', true), ''),
    '^' || blank || '|' || blank || '$', '', 'g'), '');
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
  INSERT INTO public.invoice_discount_history
    (invoice_id, inv_fin_year, inv_no, customer_id, old_discount, new_discount, reason, changed_by, changed_by_role, changed_at)
  VALUES (NEW.id, NEW.inv_fin_year, NEW.inv_no, NEW.customer_id, previous, COALESCE(NEW.discount, 0),
    NEW.discount_reason, NEW.discount_set_by, warehouse_security.active_role(), NEW.discount_set_at);
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.invoice_discount_audit() FROM PUBLIC, anon, authenticated, service_role;

-- 5. The invoice the app opens for editing carries the discount record. A
-- customer account reads its own invoices through the same RPC and does not
-- get the internal reason or the author.
DO $patch$
DECLARE fn regprocedure := 'public.get_invoice_detail(uuid)'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$        'notes', i.notes, 'created_by', i.created_by
    ) INTO v_invoice_header FROM invoice i WHERE i.id = p_invoice_id;$m$;
  replacement := $r$        'notes', i.notes, 'created_by', i.created_by
    ) || CASE WHEN auth.jwt()->>'role' = 'service_role'
                OR warehouse_security.active_role() IN ('admin','supervisor','staff')
        THEN jsonb_build_object(
            'discount_reason', i.discount_reason,
            'discount_set_by', i.discount_set_by,
            'discount_set_by_name', (SELECT p.name FROM user_profiles p WHERE p.id = i.discount_set_by),
            'discount_set_at', i.discount_set_at)
        ELSE '{}'::jsonb END
    INTO v_invoice_header FROM invoice i WHERE i.id = p_invoice_id;$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one header object in get_invoice_detail, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- 5. Line amounts as the header computes them: ONE_TIME storage is quantity x
-- charge with no duration and no labour; monthly storage and labour are rounded
-- separately; line tax is the rounded tax on that base.
DO $patch$
DECLARE fn regprocedure := 'public.get_invoice_items_detailed(uuid)'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$      ROUND(
        COALESCE(dt.disp_qty, 0)::numeric
        * (
          COALESCE(it.charge, 0)::numeric * COALESCE(it.duration, 1)::numeric
          + COALESCE(it.labour_rate, 0)::numeric
        )
        * COALESCE(it.tax, 0)::numeric / 100,
        2
      ) AS tax_amount,
      ROUND(
        COALESCE(dt.disp_qty, 0)::numeric
        * (
          COALESCE(it.charge, 0)::numeric * COALESCE(it.duration, 1)::numeric
          + COALESCE(it.labour_rate, 0)::numeric
        )
        * (1 + COALESCE(it.tax, 0)::numeric / 100),
        2
      ) AS total_amount,$m$;
  replacement := $r$      ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2) AS tax_amount,
      amount.base + ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2) AS total_amount,$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one line-amount block in get_invoice_items_detailed, found %', occurrences; END IF;
  definition := replace(definition,marker,replacement);
  marker := $m$    JOIN public.items catalog ON catalog.id = grt.item_id
    WHERE it.invoice_id = p_invoice_id$m$;
  replacement := $r$    JOIN public.items catalog ON catalog.id = grt.item_id
    CROSS JOIN LATERAL (
      SELECT CASE WHEN gr.pricing_mode = 'ONE_TIME'
        THEN ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2)
        ELSE ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric * COALESCE(it.duration, 1)::numeric, 2)
             + ROUND(COALESCE(it.labour_rate, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2)
        END AS base
    ) AS amount
    WHERE it.invoice_id = p_invoice_id$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one line source in get_invoice_items_detailed, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- 5. Payments point at the invoice they paid with ON DELETE SET NULL, so
-- deleting a paid invoice left the money unallocated with no record of what it
-- paid. The payment has to be removed or moved first.
DO $patch$
DECLARE fn regprocedure := 'public.delete_invoice(uuid)'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$    -- Delete invoice items (CASCADE should handle this, but explicit is safer)$m$;
  replacement := $r$    IF EXISTS (SELECT 1 FROM payments WHERE invoice_id = p_invoice_id) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Cannot delete an invoice that has payments'
        );
    END IF;

    -- Delete invoice items (CASCADE should handle this, but explicit is safer)$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one line-delete marker in delete_invoice, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- Report, do not repair: which of two invoices for the same dispatch line is
-- the right one is an operator's decision.
DO $report$
DECLARE doubled_lines integer; invoices integer;
BEGIN
  SELECT count(DISTINCT d.disp_trl_id), count(DISTINCT d.invoice_id) INTO doubled_lines, invoices
  FROM (
    SELECT it.disp_trl_id, it.invoice_id, count(*) OVER (PARTITION BY it.disp_trl_id) AS holders
    FROM public.invoice_trl it JOIN public.invoice i ON i.id=it.invoice_id
    WHERE i.deleted_at IS NULL) d
  WHERE d.holders > 1;
  IF doubled_lines > 0 THEN
    RAISE WARNING 'Migration 41: % existing dispatch line(s) are on more than one invoice (% invoices involved). They are left as they are; review them.', doubled_lines, invoices;
  END IF;
END $report$;
NOTIFY pgrst, 'reload schema';
