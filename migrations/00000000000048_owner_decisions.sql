-- Owner decisions of 2026-10-11.
--
-- 2. The suggested next invoice number is per financial year: the highest
--    number of that year plus 1, starting at 1.
-- 3. An invoice line may have a storage charge of 0, with a reason: staff must
--    give one, administrators and supervisors may leave it empty; who and when
--    is recorded on the invoice and every change in an append-only history.
-- 5. Staff may create, change and delete item prices (migration 45). Every
--    insert, update and delete of a price is now recorded in an append-only
--    history that administrators and supervisors can read.
--
-- No existing row is validated or changed: an invoice that already has a
-- zero-charge line and no reason stays as it is and meets the rule when staff
-- next edit it.
--
-- (Decision 6, the request limit of the REST route, is docker/kong.yml.)

-- ---------------------------------------------------------------------------
-- 2. Next invoice number per financial year
-- ---------------------------------------------------------------------------
-- The financial year a calendar date falls in: 1 April to 31 March, named by
-- the calendar year it starts in, as invoice.inv_fin_year stores it.
CREATE FUNCTION warehouse_security.financial_year(day date) RETURNS integer
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT EXTRACT(YEAR FROM day)::integer - CASE WHEN EXTRACT(MONTH FROM day) >= 4 THEN 0 ELSE 1 END
$$;
REVOKE ALL ON FUNCTION warehouse_security.financial_year(date) FROM PUBLIC, anon, authenticated, service_role;

-- get_next_invoice_number() took the highest number over every invoice of
-- every year, so a new financial year continued the old year's numbers, and
-- one invoice numbered 2147483647 made it fail with "integer out of range"
-- for all of them. The no-argument function is dropped, not kept beside the
-- new one: two candidates would make a call without an argument ambiguous.
-- Guard name, security and grants are those of the function it replaces, so
-- the allowlists of warehouse_security.authorize_rpc need no change.
--
-- A soft-deleted invoice (deleted_at set; no granted RPC does that,
-- delete_invoice removes the row) is not counted, as decided, although the
-- unique constraint unique_inv_no_per_year still holds its number.
--
-- get_next_invoice_number_with_year() is left as it is: no app role may
-- execute it, and its own handler already turns the overflow into an error
-- answer. It still takes the year from the session's clock, not India's.
DROP FUNCTION public.get_next_invoice_number();
CREATE FUNCTION public.get_next_invoice_number(p_fin_year integer DEFAULT NULL) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, extensions, utils, pg_temp AS $$
DECLARE
    v_fin_year integer;
    v_max_no integer;
BEGIN
    PERFORM warehouse_security.authorize_rpc('get_next_invoice_number', jsonb_build_object());
    v_fin_year := COALESCE(p_fin_year, warehouse_security.financial_year(warehouse_security.business_date(now())));

    SELECT MAX(inv_no) INTO v_max_no
    FROM invoice
    WHERE inv_fin_year = v_fin_year AND deleted_at IS NULL AND inv_no >= 1;

    IF v_max_no = 2147483647 THEN
        RAISE EXCEPTION 'No invoice number is left in financial year %', v_fin_year USING ERRCODE = 'WH409';
    END IF;

    RETURN (COALESCE(v_max_no, 0) + 1)::TEXT;
END;
$$;
REVOKE ALL ON FUNCTION public.get_next_invoice_number(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_next_invoice_number(integer) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Zero charge with a reason
-- ---------------------------------------------------------------------------
-- A reason without the white space and invisible characters around it, NULL
-- when nothing is left. The character class is the one migration 41 gave the
-- discount reason, written with escapes so that this file holds no invisible
-- character.
CREATE FUNCTION warehouse_security.trimmed_reason(reason text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT NULLIF(regexp_replace(COALESCE(reason, ''),
    '^[\s\u0085 ­ ᠎ -‏ -  -⁤　﻿]+|[\s\u0085 ­ ᠎ -‏ -  -⁤　﻿]+$',
    '', 'g'), '')
$$;
REVOKE ALL ON FUNCTION warehouse_security.trimmed_reason(text) FROM PUBLIC, anon, authenticated, service_role;

-- Trigger function for the append-only history tables of this migration: no
-- row is changed or removed afterwards, by anyone.
CREATE FUNCTION warehouse_security.history_append_only() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog AS $$
BEGIN
  RAISE EXCEPTION 'History table % cannot be changed', TG_TABLE_NAME USING ERRCODE = '42501';
END $$;
REVOKE ALL ON FUNCTION warehouse_security.history_append_only() FROM PUBLIC, anon, authenticated, service_role;

ALTER TABLE public.invoice
  ADD COLUMN zero_charge_reason text,
  ADD COLUMN zero_charge_set_by uuid REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  ADD COLUMN zero_charge_set_at timestamptz;
COMMENT ON COLUMN public.invoice.zero_charge_reason IS 'Why a line has a storage charge of 0; required from staff, NULL when no line has a zero charge (migration 48).';
COMMENT ON COLUMN public.invoice.zero_charge_set_by IS 'Profile that last changed the reason or the set of zero-charge lines.';
COMMENT ON COLUMN public.invoice.zero_charge_set_at IS 'When zero_charge_set_by did so.';

-- One row per change of the reason or of the set of zero-charge lines, kept
-- when the invoice is edited again or deleted. Shaped like
-- invoice_discount_history (migration 41), which is left as it is: no foreign
-- keys, written only by recalculate_invoice_header below, read by
-- administrators and supervisors like the invoice table itself.
CREATE TABLE public.invoice_zero_charge_history (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  invoice_id uuid NOT NULL,
  inv_fin_year integer,
  inv_no integer,
  customer_id uuid,
  old_reason text,
  new_reason text,
  old_lines uuid[] NOT NULL,
  new_lines uuid[] NOT NULL,
  changed_by uuid,
  changed_by_role text,
  changed_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.invoice_zero_charge_history IS
  'Append-only record of every change to an invoice''s zero-charge reason or zero-charge lines (migration 48). invoice.zero_charge_reason / zero_charge_set_by / zero_charge_set_at keep the last change.';
COMMENT ON COLUMN public.invoice_zero_charge_history.old_lines IS 'dispatch_trl.id of the lines that had a zero charge before the change.';
COMMENT ON COLUMN public.invoice_zero_charge_history.new_lines IS 'dispatch_trl.id of the lines that have a zero charge after it.';
COMMENT ON COLUMN public.invoice_zero_charge_history.changed_by IS 'user_profiles.id of the account that made the change.';
CREATE INDEX invoice_zero_charge_history_invoice_idx ON public.invoice_zero_charge_history (invoice_id, id);
ALTER TABLE public.invoice_zero_charge_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.invoice_zero_charge_history FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.invoice_zero_charge_history TO authenticated, service_role;
CREATE POLICY starter_staff ON public.invoice_zero_charge_history FOR SELECT TO authenticated
  USING (warehouse_security.active_role() IN ('admin','supervisor'));
CREATE TRIGGER invoice_zero_charge_history_append_only BEFORE UPDATE OR DELETE ON public.invoice_zero_charge_history
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.history_append_only();
CREATE TRIGGER invoice_zero_charge_history_no_truncate BEFORE TRUNCATE ON public.invoice_zero_charge_history
  FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.history_append_only();

-- Called by each save RPC right after its guard, before it writes: keeps for
-- the rest of the transaction the reason the request sent and, for an edit,
-- the lines that have a zero charge now. update_invoice deletes and rewrites
-- the lines, so afterwards the earlier set could not be told. The reason is
-- read where the header fields are: in p_invoice_data itself (both
-- three-argument paths, and the one-argument path as the app's fields are
-- sent) or in its "header" object (one-argument path).
CREATE FUNCTION warehouse_security.note_zero_charge_request(p_invoice_id uuid, p_invoice_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  PERFORM set_config('warehouse.zero_charge_request', jsonb_build_object(
    'invoice_id', p_invoice_id,
    'reason', COALESCE(p_invoice_data->>'zero_charge_reason', p_invoice_data#>>'{header,zero_charge_reason}',
                       p_invoice_data#>>'{data,header,zero_charge_reason}'),
    'lines_before', COALESCE((SELECT jsonb_agg(it.disp_trl_id) FROM public.invoice_trl it
                              WHERE it.invoice_id = p_invoice_id AND COALESCE(it.charge, 0) = 0), '[]'::jsonb))::text, true);
END $$;
REVOKE ALL ON FUNCTION warehouse_security.note_zero_charge_request(uuid, jsonb) FROM PUBLIC, anon, authenticated, service_role;

DO $patch$
DECLARE target record; definition text; occurrences integer;
  marker constant text := $m$PERFORM set_config('warehouse.discount_reason', COALESCE(p_invoice_data->>'discount_reason', ''), true);$m$;
BEGIN
  FOR target IN SELECT * FROM (VALUES
    ('public.save_invoice(jsonb)'::regprocedure, 'NULL'),
    ('public.save_invoice(uuid,jsonb,jsonb[])'::regprocedure, 'p_invoice_id'),
    ('public.update_invoice(uuid,jsonb,jsonb[])'::regprocedure, 'p_invoice_id')) AS t(fn, invoice) LOOP
    definition := pg_get_functiondef(target.fn);
    occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
    IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one discount-reason line in %, found %', target.fn, occurrences; END IF;
    EXECUTE replace(definition, marker, marker || E'\n  PERFORM warehouse_security.note_zero_charge_request('
      || target.invoice || ', p_invoice_data);');
  END LOOP;
END $patch$;

-- The rule lives where all three save paths meet after the lines are saved
-- (migration 41 put the rate ranges here for the same reason); a trigger on
-- the header could not see the lines. The body is the migration-41 text with
-- the block marked "Zero charge" and the three columns in the final UPDATE.
--
-- A line without a charge is billed as 0 (COALESCE below), so it counts as a
-- zero charge. The rate ranges come first: a charge below 0 or above 999999 is
-- still refused with its own message.
CREATE OR REPLACE FUNCTION warehouse_security.recalculate_invoice_header(p_invoice_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE line_count integer; subtotal numeric(12,2); labour_total numeric(12,2); tax_basis numeric;
  tax_total numeric(12,2); grand numeric(12,2); discount_value numeric(12,2);
  bad_charge integer; bad_labour integer; bad_tax integer;
  request jsonb := NULLIF(current_setting('warehouse.zero_charge_request', true), '')::jsonb;
  caller_role text := warehouse_security.active_role();
  zero_before uuid[] := '{}'; zero_now uuid[]; reason_before text; reason_now text; zero_changed boolean;
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
  SELECT COALESCE(discount,0), zero_charge_reason INTO discount_value, reason_before FROM public.invoice WHERE id=p_invoice_id;
  tax_total := ceil(tax_basis);
  grand := ceil(subtotal + tax_total - discount_value);
  IF grand < 0 THEN RAISE EXCEPTION 'Discount exceeds the invoice amount'; END IF;

  -- Zero charge. The lines that have one now; those that had one before this
  -- edit (none for a new invoice); and the reason, which is kept only while a
  -- line has a zero charge.
  zero_now := ARRAY(SELECT it.disp_trl_id FROM public.invoice_trl it
                    WHERE it.invoice_id=p_invoice_id AND COALESCE(it.charge,0)=0 ORDER BY it.disp_trl_id);
  IF request->>'invoice_id' = p_invoice_id::text THEN
    zero_before := ARRAY(SELECT line::uuid FROM jsonb_array_elements_text(request->'lines_before') AS line ORDER BY line::uuid);
  END IF;
  IF cardinality(zero_now) > 0 THEN
    reason_now := left(warehouse_security.trimmed_reason(request->>'reason'), 500);
    IF reason_now IS NULL AND caller_role = 'staff' THEN
      RAISE EXCEPTION 'Enter a reason for the zero charge' USING ERRCODE = '22023';
    END IF;
  END IF;
  zero_changed := zero_now IS DISTINCT FROM zero_before OR reason_now IS DISTINCT FROM reason_before;

  UPDATE public.invoice SET labour=labour_total, tax_amount=tax_total, total=grand,
    zero_charge_reason = reason_now,
    zero_charge_set_by = CASE WHEN zero_changed THEN (SELECT p.id FROM public.user_profiles p WHERE p.auth_user_id = auth.uid())
                              ELSE zero_charge_set_by END,
    zero_charge_set_at = CASE WHEN zero_changed THEN now() ELSE zero_charge_set_at END
  WHERE id=p_invoice_id;
  IF zero_changed THEN
    INSERT INTO public.invoice_zero_charge_history
      (invoice_id, inv_fin_year, inv_no, customer_id, old_reason, new_reason, old_lines, new_lines, changed_by, changed_by_role, changed_at)
    SELECT i.id, i.inv_fin_year, i.inv_no, i.customer_id, reason_before, reason_now, zero_before, zero_now,
           i.zero_charge_set_by, caller_role, i.zero_charge_set_at
    FROM public.invoice i WHERE i.id=p_invoice_id;
  END IF;
  RETURN jsonb_build_object('subtotal',subtotal,'labour',labour_total,'tax',tax_total,'total_tax',tax_total,
    'discount',discount_value,'grand_total',grand,'total',grand,'total_rows',line_count);
END $$;
REVOKE ALL ON FUNCTION warehouse_security.recalculate_invoice_header(uuid) FROM PUBLIC,anon,authenticated,service_role;

-- The invoice the app opens for editing carries the zero-charge record beside
-- the discount record: to the warehouse roles, not to a customer account.
DO $patch$
DECLARE fn regprocedure := 'public.get_invoice_detail(uuid)'::regprocedure;
  definition text; marker text; replacement text; occurrences integer;
BEGIN
  definition := pg_get_functiondef(fn);
  marker := $m$            'discount_set_at', i.discount_set_at)
        ELSE '{}'::jsonb END$m$;
  replacement := $r$            'discount_set_at', i.discount_set_at,
            'zero_charge_reason', i.zero_charge_reason,
            'zero_charge_set_by', i.zero_charge_set_by,
            'zero_charge_set_by_name', (SELECT p.name FROM user_profiles p WHERE p.id = i.zero_charge_set_by),
            'zero_charge_set_at', i.zero_charge_set_at)
        ELSE '{}'::jsonb END$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one discount record in get_invoice_detail, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;

-- ---------------------------------------------------------------------------
-- 5. Price history
-- ---------------------------------------------------------------------------
-- One row per insert, update and delete of item_storage_prices. Like the two
-- invoice histories it has no foreign key, so a price, an item, a customer or
-- a profile can still be deleted and the record stays; the names are stored
-- with the row for that reason. old_values / new_values are the price row as
-- it was and as it is, without its three ids (which are columns here) and
-- without created_at / created_by (which no write changes).
CREATE TABLE public.item_price_history (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  price_id uuid NOT NULL,
  item_id uuid,
  item_name text,
  customer_id uuid,
  customer_name text,
  action text NOT NULL CHECK (action IN ('insert','update','delete')),
  old_values jsonb,
  new_values jsonb,
  changed_by uuid,
  changed_by_role text,
  changed_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.item_price_history IS
  'Append-only record of every insert, update and delete of item_storage_prices (migration 48). Read it with get_item_price_history.';
COMMENT ON COLUMN public.item_price_history.price_id IS 'item_storage_prices.id of the price; the row may be gone.';
COMMENT ON COLUMN public.item_price_history.customer_id IS 'NULL for a default price, which applies to every customer.';
COMMENT ON COLUMN public.item_price_history.old_values IS 'The price before the change; NULL for an insert.';
COMMENT ON COLUMN public.item_price_history.new_values IS 'The price after the change; NULL for a delete.';
COMMENT ON COLUMN public.item_price_history.changed_by IS 'user_profiles.id of the session that made the change; NULL for a write with the service key or by the database owner.';
CREATE INDEX item_price_history_customer_idx ON public.item_price_history (customer_id, id);
CREATE INDEX item_price_history_item_idx ON public.item_price_history (item_id, id);
ALTER TABLE public.item_price_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.item_price_history FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.item_price_history TO authenticated, service_role;
CREATE POLICY starter_staff ON public.item_price_history FOR SELECT TO authenticated
  USING (warehouse_security.active_role() IN ('admin','supervisor'));
CREATE TRIGGER item_price_history_append_only BEFORE UPDATE OR DELETE ON public.item_price_history
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.history_append_only();
CREATE TRIGGER item_price_history_no_truncate BEFORE TRUNCATE ON public.item_price_history
  FOR EACH STATEMENT EXECUTE FUNCTION warehouse_security.history_append_only();

-- A row trigger on the table covers every path at once: the five guarded
-- price RPCs (both create and both update signatures, delete, find-or-create)
-- and a write with the service key or by the database owner. The author is the
-- session's profile, never a value the client sends.
CREATE FUNCTION warehouse_security.record_item_price_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  kept_out constant text[] := ARRAY['id','item_id','customer_id','created_at','created_by'];
  price public.item_storage_prices;
  before_change jsonb; after_change jsonb;
BEGIN
  IF TG_OP = 'DELETE' THEN price := OLD; ELSE price := NEW; END IF;
  IF TG_OP <> 'INSERT' THEN before_change := to_jsonb(OLD) - kept_out; END IF;
  IF TG_OP <> 'DELETE' THEN after_change := to_jsonb(NEW) - kept_out; END IF;
  INSERT INTO public.item_price_history
    (price_id, item_id, item_name, customer_id, customer_name, action, old_values, new_values, changed_by, changed_by_role)
  VALUES (price.id, price.item_id, (SELECT i.name FROM public.items i WHERE i.id = price.item_id),
    price.customer_id, (SELECT c.name FROM public.customers c WHERE c.id = price.customer_id),
    lower(TG_OP), before_change, after_change,
    (SELECT p.id FROM public.user_profiles p WHERE p.auth_user_id = auth.uid()), warehouse_security.active_role());
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION warehouse_security.record_item_price_change() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER item_price_history_record AFTER INSERT OR UPDATE OR DELETE ON public.item_storage_prices
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.record_item_price_change();

-- The history, newest first, for administrators and supervisors. The guard
-- admits those two roles to every RPC and refuses staff and customer accounts
-- any name that is not on their lists, so this one needs no entry there.
-- Without a customer or an item the history is not filtered; a page is 1 to
-- 200 rows.
CREATE FUNCTION public.get_item_price_history(p_customer_id uuid DEFAULT NULL, p_item_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 50, p_offset integer DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, extensions, utils, pg_temp AS $$
DECLARE
    v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
    v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
    v_total integer;
    v_data jsonb;
BEGIN
    PERFORM warehouse_security.authorize_rpc('get_item_price_history', jsonb_build_object('p_customer_id', p_customer_id));

    SELECT count(*) INTO v_total
    FROM item_price_history h
    WHERE (p_customer_id IS NULL OR h.customer_id = p_customer_id)
      AND (p_item_id IS NULL OR h.item_id = p_item_id);

    SELECT COALESCE(jsonb_agg(page.row_data ORDER BY page.id DESC), '[]'::jsonb) INTO v_data
    FROM (
        SELECT h.id, jsonb_build_object(
            'id', h.id,
            'changed_at', h.changed_at,
            'action', h.action,
            'price_id', h.price_id,
            'item_id', h.item_id,
            'item_name', h.item_name,
            'customer_id', h.customer_id,
            'customer_name', h.customer_name,
            'old_values', h.old_values,
            'new_values', h.new_values,
            'changed_by', h.changed_by,
            'changed_by_name', (SELECT p.name FROM user_profiles p WHERE p.id = h.changed_by),
            'changed_by_role', h.changed_by_role
        ) AS row_data
        FROM item_price_history h
        WHERE (p_customer_id IS NULL OR h.customer_id = p_customer_id)
          AND (p_item_id IS NULL OR h.item_id = p_item_id)
        ORDER BY h.id DESC
        LIMIT v_limit OFFSET v_offset
    ) page;

    RETURN jsonb_build_object(
        'success', true,
        'data', v_data,
        'pagination', jsonb_build_object(
            'total', v_total,
            'limit', v_limit,
            'offset', v_offset,
            'has_more', (v_offset + v_limit) < v_total
        )
    );
END;
$$;
REVOKE ALL ON FUNCTION public.get_item_price_history(uuid, uuid, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_item_price_history(uuid, uuid, integer, integer) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
