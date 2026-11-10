-- Migration 175 (WH-139): an optional invoice number prefix of up to 8 characters, off by default. Written against the functions as
-- migrations 164 (charging rule), 165 (invoice as goods leave), 172 (payments), 173 (GST documents) and 174 left them.
--
-- The invoice number stays a whole number (1 to 99999999, public.invoice.inv_no), so counting, the suggestion, the year and sequence
-- schemes, uniqueness per financial year and the reuse of deleted numbers work exactly as before. The prefix is not part of what is counted.
-- The full number is the prefix followed by the digits, no space (SRT/ + 12 = SRT/12): at most 8 + 8 = 16 characters, which is the longest
-- an invoice number may be under the GST rules. With no prefix every answer is the one it was, plus the two keys below.
--
--  1. The rule. warehouse_security.document_numbering for 'invoice' may now hold a prefix of up to 8 characters from A-Z, 0-9, / and -
--     (document_numbering_invoice_check; width stays 1). set_document_numbering('invoice', {scheme, start, prefix}) takes it: a lowercase
--     prefix is turned into capitals, anything else outside the set (or longer than 8) is refused with SQLSTATE 22023. A rule that leaves
--     'prefix' out keeps the stored prefix (an older app that sends only scheme and start does not clear it). A prefix change is refused
--     like the scheme switch of migration 162 while any invoice row (live, cancelled or soft-deleted) exists in the current financial year:
--     {success:false, error_code:'WH409', reason:'NUMBERING_PREFIX_MID_YEAR', error and message: "The prefix can't change during a financial
--     year that already has invoices. You can change it from 1 April."}; nothing changes. From 1 April until the first invoice of the year
--     it can change. The change is in document_numbering_history like every rule change.
--  2. Each invoice stores the prefix it was saved with: public.invoice.inv_prefix (varchar(8), NOT NULL, default ''; every existing row
--     keeps ''). A BEFORE INSERT trigger sets it (the save functions are not changed for this): the prefix of the invoices the financial year
--     of the new invoice already holds, else the rule's prefix. So all invoices of one financial year carry one prefix, also a back-dated
--     one, and both documents of a two-document save (migration 173: number n and n + 1). The trigger refuses a later change of the stored
--     prefix. unique_inv_label_per_year makes the full number unique per financial year, on top of unique_inv_no_per_year (it is the same set
--     while the prefix is the same in the year). The save and update functions, apply_invoice_gst's second number and the advisory lock
--     71040 are untouched, so no number is skipped or repeated by this change.
--  3. Reads gain two keys, existing keys and their types are unchanged: inv_prefix (text, '' when none) and invoice_label (text, the full
--     number). get_invoices_list (items; its search now matches the full number, so SRT/12 and 12 both find the invoice, in either case),
--     get_invoice_detail ('inv_prefix', 'invoice_label' next to 'inv_no'; linked_invoice) and get_invoice_data (header, next to
--     'invoice_number'; linked_invoice) in their definition files, save_invoice / update_invoice answers (via save_invoice_internal and
--     update_invoice; save_invoice's documents[] via invoice_documents_json), cancel_invoice and delete_invoice answers and refusals
--     (INVOICE_HAS_PAYMENTS, INVOICE_PAIR with its linked_invoice; delete_invoice_pair answers with delete_invoice's answers and refusals),
--     record_payment, update_payment and delete_payment (their invoice{} object and the INVOICE_CANCELLED refusal; "Payment of 50 recorded
--     on invoice SRT/12."), suggest_document_number for invoices ('prefix'), get_invoice_range_for_print (inv_prefix, invoice_label, and
--     skipped[].invoice_label). The "Invoice number %s is already used in financial year %s" refusals and the two-document NUMBER_TAKEN and
--     NUMBER_OUT_OF_RANGE refusals of apply_invoice_gst name the full number (the 'number' key stays the digits). The print range accepts
--     the full number or the digits: the trailing digits of what is sent are the number (SRT/12 and 12 are invoice 12; before, every digit
--     of the text was joined, which a prefix with digits would break).
--  4. Also carrying invoice_label beside the unchanged digits and formats: get_customer_invoice_summary, get_customer_activity_detail and
--     get_customer_grn_activity (invoice rows and invoice_status), get_grn_details (invoices_summary: 'invoice_labels' beside
--     invoice_numbers, the same live invoices; each of invoices[] gains inv_prefix and invoice_label), get_dispatch_details
--     ('invoice_labels' in invoices_summary; dispatch lines' invoice_details), get_grn_edit_state (lines, and data.invoice); the refusals of
--     update_grn and update_dispatch_smart ("... is on invoice SRT/12 ...", and 'invoice_label' in their details) in their definition files.
--     get_customer_invoices and get_grn_invoices no longer exist (migration 123).
--
-- Patched in place by marker count (these functions have no definition file); a second run fails on the count. Granting inv_prefix to
-- authenticated is the column grant of the invoice table (migration 48): the PDF function reads it with the caller's token.

-- 1. The stored prefix.
ALTER TABLE public.invoice
  ADD COLUMN inv_prefix character varying(8) NOT NULL DEFAULT '',
  ADD CONSTRAINT invoice_inv_prefix_check CHECK (inv_prefix::text ~ '^[A-Z0-9/-]{0,8}$');
GRANT SELECT (inv_prefix) ON TABLE public.invoice TO authenticated;
COMMENT ON COLUMN public.invoice.inv_prefix IS 'Migration 175 (WH-139): the invoice number prefix this invoice was saved with, '''' when none. The full number is inv_prefix || inv_no.';

CREATE UNIQUE INDEX unique_inv_label_per_year ON public.invoice (inv_fin_year, (inv_prefix::text || inv_no::text));

-- 2. Helpers.
CREATE FUNCTION warehouse_security.invoice_label(p_prefix text, p_no bigint) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT COALESCE(p_prefix, '') || p_no::text
$$;
ALTER FUNCTION warehouse_security.invoice_label(text, bigint) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.invoice_label(text, bigint) FROM PUBLIC;

-- The prefix a new invoice of the financial year gets: the one the year's invoices already hold (any row counts, as in migration 162),
-- else the rule's.
CREATE FUNCTION warehouse_security.invoice_prefix_for_year(p_fin_year integer) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT COALESCE(
    (SELECT i.inv_prefix FROM public.invoice i WHERE i.inv_fin_year = p_fin_year ORDER BY i.inv_no, i.id LIMIT 1),
    (SELECT n.prefix FROM warehouse_security.document_numbering n WHERE n.document_type = 'invoice'),
    '')
$$;
ALTER FUNCTION warehouse_security.invoice_prefix_for_year(integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.invoice_prefix_for_year(integer) FROM PUBLIC;

CREATE FUNCTION warehouse_security.invoice_assign_prefix() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.inv_prefix := warehouse_security.invoice_prefix_for_year(NEW.inv_fin_year);
  ELSIF NEW.inv_prefix IS DISTINCT FROM OLD.inv_prefix THEN
    RAISE EXCEPTION 'An invoice keeps the prefix it was saved with.' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
ALTER FUNCTION warehouse_security.invoice_assign_prefix() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.invoice_assign_prefix() FROM PUBLIC;
CREATE TRIGGER invoice_assign_prefix BEFORE INSERT OR UPDATE ON public.invoice
  FOR EACH ROW EXECUTE FUNCTION warehouse_security.invoice_assign_prefix();

-- 3. The rule may hold a prefix for invoices.
ALTER TABLE warehouse_security.document_numbering DROP CONSTRAINT document_numbering_invoice_check;
ALTER TABLE warehouse_security.document_numbering ADD CONSTRAINT document_numbering_invoice_check
  CHECK (document_type <> 'invoice' OR (scheme IN ('year', 'sequence') AND width = 1 AND prefix ~ '^[A-Z0-9/-]{0,8}$'));

-- 4. The patches.
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
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- 4a. set_document_numbering's worker: the invoice prefix, and the mid-year refusal.
SELECT pg_temp.patch_function('warehouse_security.apply_document_numbering(text, jsonb, uuid)'::regprocedure, ARRAY[
-- a prefix is allowed in an invoice rule; one left out stays as stored
$m$    v_allowed := ARRAY['scheme', 'start'];
    r_new.width := 1;$m$,
-- the prefix of an invoice: up to 8 characters, lowercase turned into capitals
$m$  IF p_rule ? 'prefix' THEN
    IF jsonb_typeof(p_rule->'prefix') <> 'string' OR (p_rule->>'prefix') !~ '^[A-Z0-9/-]{0,10}$' THEN$m$,
-- the prefix does not change while the current financial year has an invoice
$m$  -- Migration 162 (WH-131): no scheme switch for invoices while an invoice exists in the current financial year.$m$
], ARRAY[
$m$    v_allowed := ARRAY['scheme', 'start', 'prefix'];
    r_new.width := 1;
    r_new.prefix := r_old.prefix;$m$,
$m$  IF p_rule ? 'prefix' AND p_type = 'invoice' THEN
    -- Migration 175 (WH-139): at most 8 characters of A-Z, 0-9, / and -; lowercase letters are turned into capitals (checked before, so
    -- no character becomes two on the way up).
    IF jsonb_typeof(p_rule->'prefix') <> 'string' OR (p_rule->>'prefix') !~ '^[A-Za-z0-9/-]{0,8}$' THEN
      RAISE EXCEPTION 'The prefix can have up to 8 characters: capital letters, digits, / and -.' USING ERRCODE = '22023';
    END IF;
    r_new.prefix := upper(p_rule->>'prefix');
  ELSIF p_rule ? 'prefix' THEN
    IF jsonb_typeof(p_rule->'prefix') <> 'string' OR (p_rule->>'prefix') !~ '^[A-Z0-9/-]{0,10}$' THEN$m$,
$m$  -- Migration 175 (WH-139): no prefix change for invoices while an invoice exists in the current financial year (any row counts).
  IF p_type = 'invoice' AND r_new.prefix IS DISTINCT FROM r_old.prefix
     AND EXISTS (SELECT 1 FROM public.invoice i
                 WHERE i.inv_fin_year = warehouse_security.financial_year(warehouse_security.business_date(now()))) THEN
    RETURN warehouse_security.refuse('NUMBERING_PREFIX_MID_YEAR',
      'The prefix can''t change during a financial year that already has invoices. You can change it from 1 April.');
  END IF;

  -- Migration 162 (WH-131): no scheme switch for invoices while an invoice exists in the current financial year.$m$
]);

-- 4b. The invoice suggestion says which prefix goes in front (the digits are unchanged).
SELECT pg_temp.patch_function('warehouse_security.document_number_suggestion(text, date, integer)'::regprocedure, ARRAY[
$m$RETURN v_out || jsonb_build_object('number', greatest(r.start, COALESCE(v_n, 0) + 1)::text);$m$
], ARRAY[
$m$RETURN v_out || jsonb_build_object('number', greatest(r.start, COALESCE(v_n, 0) + 1)::text,
                                    'prefix', warehouse_security.invoice_prefix_for_year(v_fy));$m$
]);

-- 4c. The invoice list: the two keys, and a search that reads the full number.
SELECT pg_temp.patch_function('public.get_invoices_list(integer, integer, uuid, integer, text, text, text, text, integer, integer, text, timestamp with time zone, timestamp with time zone, uuid[], text, text)'::regprocedure, ARRAY[
$m$i.inv_no::text ILIKE '%' || $3 || '%'$m$,
$m$WHERE NOT (i.inv_no::text ILIKE term OR$m$,
$m$'invoice_number', i.inv_no,$m$
], ARRAY[
$m$(i.inv_prefix::text || i.inv_no::text) ILIKE '%' || $3 || '%'$m$,
$m$WHERE NOT ((i.inv_prefix::text || i.inv_no::text) ILIKE term OR$m$,
$m$'invoice_number', i.inv_no,
                       'inv_prefix', i.inv_prefix,
                       'invoice_label', warehouse_security.invoice_label(i.inv_prefix, i.inv_no),$m$
]);

-- 4d. Save and update: the refusal names the full number; the answer carries the prefix and the full number.
SELECT pg_temp.patch_function('public.save_invoice_internal(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$p_invoice_data->>'inv_no', p_invoice_data->>'inv_fin_year'),$m$,
$m$'invoice_number', v_invoice_number_for_resolution,$m$
], ARRAY[
$m$warehouse_security.invoice_label(warehouse_security.invoice_prefix_for_year((p_invoice_data->>'inv_fin_year')::integer),
                                                (p_invoice_data->>'inv_no')::bigint),
                            p_invoice_data->>'inv_fin_year'),$m$,
$m$'invoice_number', v_invoice_number_for_resolution,
        'inv_prefix', (SELECT x.inv_prefix FROM invoice x WHERE x.id = v_final_invoice_id),
        'invoice_label', (SELECT warehouse_security.invoice_label(x.inv_prefix, x.inv_no) FROM invoice x WHERE x.id = v_final_invoice_id),$m$
]);

SELECT pg_temp.patch_function('public.update_invoice(uuid, jsonb, jsonb[])'::regprocedure, ARRAY[
$m$p_invoice_data->>'inv_no', p_invoice_data->>'inv_fin_year')$m$,
$m$'invoice_number', v_invoice_no,$m$
], ARRAY[
$m$warehouse_security.invoice_label(warehouse_security.invoice_prefix_for_year((p_invoice_data->>'inv_fin_year')::integer),
                                                (p_invoice_data->>'inv_no')::bigint),
                            p_invoice_data->>'inv_fin_year')$m$,
$m$'invoice_number', v_invoice_no,
        'inv_prefix', (SELECT x.inv_prefix FROM invoice x WHERE x.id = p_invoice_id),
        'invoice_label', (SELECT warehouse_security.invoice_label(x.inv_prefix, x.inv_no) FROM invoice x WHERE x.id = p_invoice_id),$m$
]);

-- 4e. Cancel and delete answers. The deleted row is gone by the answer, so delete_invoice reads its prefix with the other fields.
SELECT pg_temp.patch_function('public.cancel_invoice(uuid, text, timestamp with time zone)'::regprocedure, ARRAY[
$m$'invoice_number', v_inv_no,$m$,
-- the INVOICE_HAS_PAYMENTS refusal (migration 172)
$m$'payments', v_payments, 'inv_no', v_inv_no, 'inv_fin_year', v_fin_year));$m$
], ARRAY[
$m$'invoice_number', v_inv_no,
    'inv_prefix', (SELECT x.inv_prefix FROM invoice x WHERE x.id = p_invoice_id),
    'invoice_label', (SELECT warehouse_security.invoice_label(x.inv_prefix, x.inv_no) FROM invoice x WHERE x.id = p_invoice_id),$m$,
$m$'payments', v_payments, 'inv_no', v_inv_no, 'inv_fin_year', v_fin_year,
                         'invoice_label', (SELECT warehouse_security.invoice_label(x.inv_prefix, x.inv_no) FROM invoice x WHERE x.id = p_invoice_id)));$m$
]);

SELECT pg_temp.patch_function('public.delete_invoice(uuid, timestamp with time zone)'::regprocedure, ARRAY[
$m$  v_inv_no integer;$m$,
$m$  SELECT i.gr_id, i.inv_no, i.inv_fin_year, i.updated_at
    INTO v_gr_id, v_inv_no, v_fin_year, v_stored_updated_at$m$,
$m$    'invoice_number', v_inv_no,$m$,
-- the INVOICE_HAS_PAYMENTS refusal (migration 172)
$m$'inv_no', v_inv_no, 'inv_fin_year', v_fin_year,
                         'payments', (SELECT count(*)$m$,
-- the INVOICE_PAIR refusal (migration 173), which delete_invoice_pair answers when the other document is the one refused
$m$'inv_no', v_inv_no, 'inv_fin_year', v_fin_year,
                         'linked_invoice', (SELECT jsonb_build_object('id', l.id, 'inv_no', l.inv_no, 'inv_fin_year', l.inv_fin_year, 'doc_type', l.doc_type)$m$
], ARRAY[
$m$  v_inv_no integer;
  v_inv_prefix text;$m$,
$m$  SELECT i.gr_id, i.inv_no, i.inv_fin_year, i.updated_at, i.inv_prefix
    INTO v_gr_id, v_inv_no, v_fin_year, v_stored_updated_at, v_inv_prefix$m$,
$m$    'invoice_number', v_inv_no,
    'inv_prefix', v_inv_prefix,
    'invoice_label', warehouse_security.invoice_label(v_inv_prefix, v_inv_no),$m$,
$m$'inv_no', v_inv_no, 'inv_fin_year', v_fin_year,
                         'invoice_label', warehouse_security.invoice_label(v_inv_prefix, v_inv_no),
                         'payments', (SELECT count(*)$m$,
$m$'inv_no', v_inv_no, 'inv_fin_year', v_fin_year,
                         'invoice_label', warehouse_security.invoice_label(v_inv_prefix, v_inv_no),
                         'linked_invoice', (SELECT jsonb_build_object('id', l.id, 'inv_no', l.inv_no, 'inv_fin_year', l.inv_fin_year, 'doc_type', l.doc_type,
                                                                      'inv_prefix', l.inv_prefix,
                                                                      'invoice_label', warehouse_security.invoice_label(l.inv_prefix, l.inv_no))$m$
]);

-- 4e'. The two documents of a GST save (migration 173): save_invoice's documents[] and the linked_invoice of the detail and data reads.
SELECT pg_temp.patch_function('warehouse_security.invoice_documents_json(uuid)'::regprocedure, ARRAY[
$m$'invoice_id', d.id, 'inv_no', d.inv_no, 'inv_fin_year', d.inv_fin_year,$m$
], ARRAY[
$m$'invoice_id', d.id, 'inv_no', d.inv_no, 'inv_fin_year', d.inv_fin_year,
                                               'inv_prefix', d.inv_prefix, 'invoice_label', warehouse_security.invoice_label(d.inv_prefix, d.inv_no),$m$
]);

SELECT pg_temp.patch_function('warehouse_security.invoice_gst_json(uuid)'::regprocedure, ARRAY[
$m$'linked_invoice', (SELECT jsonb_build_object('id', l.id, 'inv_no', l.inv_no, 'inv_fin_year', l.inv_fin_year, 'doc_type', l.doc_type,$m$
], ARRAY[
$m$'linked_invoice', (SELECT jsonb_build_object('id', l.id, 'inv_no', l.inv_no, 'inv_fin_year', l.inv_fin_year, 'doc_type', l.doc_type,
                                                 'inv_prefix', l.inv_prefix, 'invoice_label', warehouse_security.invoice_label(l.inv_prefix, l.inv_no),$m$
]);

-- The refusals of a two-document save name both full numbers (the second document is saved in the first one's financial year, so it gets
-- the same prefix; 'number' stays the digits). v_inv is the whole invoice row, inv_prefix included.
SELECT pg_temp.patch_function('warehouse_security.apply_invoice_gst(uuid, boolean)'::regprocedure, ARRAY[
$m$               v_inv.inv_no, v_second_no, warehouse_security.invoice_number_max()),$m$,
$m$               v_inv.inv_no, v_second_no, v_second_no, v_inv.inv_fin_year),$m$
], ARRAY[
$m$               warehouse_security.invoice_label(v_inv.inv_prefix, v_inv.inv_no),
               warehouse_security.invoice_label(v_inv.inv_prefix, v_second_no), warehouse_security.invoice_number_max()),$m$,
$m$               warehouse_security.invoice_label(v_inv.inv_prefix, v_inv.inv_no),
               warehouse_security.invoice_label(v_inv.inv_prefix, v_second_no),
               warehouse_security.invoice_label(v_inv.inv_prefix, v_second_no), v_inv.inv_fin_year),$m$
]);

-- 4e''. Payments (migration 172): the invoice{} object of each answer and the INVOICE_CANCELLED refusal carry the full number.
SELECT pg_temp.patch_function('public.record_payment(uuid, date, numeric, text, text, text)'::regprocedure, ARRAY[
$m$SELECT i.id, i.inv_no, i.inv_fin_year, i.inv_date, i.total, i.customer_id, i.cancelled_at,$m$,
$m$jsonb_build_object('invoice_id', p_invoice_id, 'inv_no', v_inv.inv_no, 'inv_fin_year', v_inv.inv_fin_year));$m$,
$m$'invoice', jsonb_build_object('invoice_id', p_invoice_id, 'inv_no', v_inv.inv_no, 'inv_fin_year', v_inv.inv_fin_year,$m$,
$m$format('Payment of %s recorded on invoice %s.', p_amount, v_inv.inv_no)$m$
], ARRAY[
$m$SELECT i.id, i.inv_no, i.inv_prefix, i.inv_fin_year, i.inv_date, i.total, i.customer_id, i.cancelled_at,$m$,
$m$jsonb_build_object('invoice_id', p_invoice_id, 'inv_no', v_inv.inv_no, 'inv_fin_year', v_inv.inv_fin_year,
                         'invoice_label', warehouse_security.invoice_label(v_inv.inv_prefix, v_inv.inv_no)));$m$,
$m$'invoice', jsonb_build_object('invoice_id', p_invoice_id, 'inv_no', v_inv.inv_no, 'inv_fin_year', v_inv.inv_fin_year,
                                  'inv_prefix', v_inv.inv_prefix,
                                  'invoice_label', warehouse_security.invoice_label(v_inv.inv_prefix, v_inv.inv_no),$m$,
$m$format('Payment of %s recorded on invoice %s.', p_amount, warehouse_security.invoice_label(v_inv.inv_prefix, v_inv.inv_no))$m$
]);

SELECT pg_temp.patch_function('public.update_payment(uuid, date, numeric, text, timestamp with time zone, text, text)'::regprocedure, ARRAY[
$m$SELECT i.id, i.inv_no, i.inv_fin_year, i.inv_date, i.total, i.cancelled_at, i.deleted_at INTO v_inv$m$,
$m$jsonb_build_object('invoice_id', v_invoice_id, 'inv_no', v_inv.inv_no, 'inv_fin_year', v_inv.inv_fin_year));$m$,
$m$'invoice', jsonb_build_object('invoice_id', v_invoice_id, 'inv_no', v_inv.inv_no, 'inv_fin_year', v_inv.inv_fin_year,$m$
], ARRAY[
$m$SELECT i.id, i.inv_no, i.inv_prefix, i.inv_fin_year, i.inv_date, i.total, i.cancelled_at, i.deleted_at INTO v_inv$m$,
$m$jsonb_build_object('invoice_id', v_invoice_id, 'inv_no', v_inv.inv_no, 'inv_fin_year', v_inv.inv_fin_year,
                         'invoice_label', warehouse_security.invoice_label(v_inv.inv_prefix, v_inv.inv_no)));$m$,
$m$'invoice', jsonb_build_object('invoice_id', v_invoice_id, 'inv_no', v_inv.inv_no, 'inv_fin_year', v_inv.inv_fin_year,
                                  'inv_prefix', v_inv.inv_prefix,
                                  'invoice_label', warehouse_security.invoice_label(v_inv.inv_prefix, v_inv.inv_no),$m$
]);

SELECT pg_temp.patch_function('public.delete_payment(uuid, timestamp with time zone, text)'::regprocedure, ARRAY[
$m$SELECT i.id, i.inv_no, i.inv_fin_year, i.total INTO v_inv$m$,
$m$'invoice', jsonb_build_object('invoice_id', v_invoice_id, 'inv_no', v_inv.inv_no, 'inv_fin_year', v_inv.inv_fin_year,$m$
], ARRAY[
$m$SELECT i.id, i.inv_no, i.inv_prefix, i.inv_fin_year, i.total INTO v_inv$m$,
$m$'invoice', jsonb_build_object('invoice_id', v_invoice_id, 'inv_no', v_inv.inv_no, 'inv_fin_year', v_inv.inv_fin_year,
                                  'inv_prefix', v_inv.inv_prefix,
                                  'invoice_label', warehouse_security.invoice_label(v_inv.inv_prefix, v_inv.inv_no),$m$
]);

-- 4f. The print range: the number may be sent as the full number or the digits, and the rows carry the full number.
SELECT pg_temp.patch_function('public.get_invoice_range_for_print(text, text, integer, integer)'::regprocedure, ARRAY[
$m$        ELSE REGEXP_REPLACE(start_inv_no_str, '[^0-9]', '', 'g')::integer$m$,
$m$        ELSE REGEXP_REPLACE(end_inv_no_str, '[^0-9]', '', 'g')::integer$m$,
$m$            'INV' || LPAD(i.inv_no::text, 3, '0') as inv_no_str,$m$,
$m$iwc.inv_no, iwc.inv_no_str, iwc.gr_id, iwc.gr_no,$m$,
$m$                'inv_no_str', iwi.inv_no_str,$m$,
$m$jsonb_build_object('inv_no', i.inv_no, 'inv_fin_year', i.inv_fin_year, 'invoice_id', i.id, 'reason', 'cancelled')$m$
], ARRAY[
$m$        ELSE COALESCE(substring(start_inv_no_str from '[0-9]+$'), REGEXP_REPLACE(start_inv_no_str, '[^0-9]', '', 'g'))::integer$m$,
$m$        ELSE COALESCE(substring(end_inv_no_str from '[0-9]+$'), REGEXP_REPLACE(end_inv_no_str, '[^0-9]', '', 'g'))::integer$m$,
$m$            i.inv_prefix,
            'INV' || LPAD(i.inv_no::text, 3, '0') as inv_no_str,$m$,
$m$iwc.inv_no, iwc.inv_prefix, iwc.inv_no_str, iwc.gr_id, iwc.gr_no,$m$,
$m$                'inv_no_str', iwi.inv_no_str,
                'inv_prefix', iwi.inv_prefix,
                'invoice_label', warehouse_security.invoice_label(iwi.inv_prefix, iwi.inv_no),$m$,
$m$jsonb_build_object('inv_no', i.inv_no, 'inv_fin_year', i.inv_fin_year, 'invoice_id', i.id, 'reason', 'cancelled',
                                                'invoice_label', warehouse_security.invoice_label(i.inv_prefix, i.inv_no))$m$
]);

-- 4g. The other reads that show an invoice get invoice_label beside the unchanged digits and formats (get_customer_invoices and
-- get_grn_invoices were dropped in migration 123).
SELECT pg_temp.patch_function('public.get_customer_invoice_summary(uuid, date, date, integer)'::regprocedure, ARRAY[
$m$as invoice_number,$m$,
$m$id.invoice_number,$m$,
$m$'invoice_number', invoice_number,$m$
], ARRAY[
$m$as invoice_number,
                warehouse_security.invoice_label(i.inv_prefix, i.inv_no) as invoice_label,
                i.inv_prefix,$m$,
$m$id.invoice_number,
                id.invoice_label,
                id.inv_prefix,$m$,
$m$'invoice_number', invoice_number,
                        'invoice_label', invoice_label,
                        'inv_prefix', inv_prefix,$m$
]);

SELECT pg_temp.patch_function('public.get_customer_activity_detail(uuid, date, date)'::regprocedure, ARRAY[
$m$as invoice_number,$m$,
$m$'invoice_number', invoice_number,$m$
], ARRAY[
$m$as invoice_number,
            warehouse_security.invoice_label(i.inv_prefix, i.inv_no) as invoice_label,
            i.inv_prefix,$m$,
$m$'invoice_number', invoice_number,
            'invoice_label', invoice_label,
            'inv_prefix', inv_prefix,$m$
]);

SELECT pg_temp.patch_function('public.get_customer_grn_activity(uuid, date, date)'::regprocedure, ARRAY[
$m$'invoice_number', i.inv_fin_year::text || '-' || i.inv_no::text,$m$,
$m$'invoice_id', null, 'invoice_number', null, 'invoice_count', 0$m$
], ARRAY[
$m$'invoice_number', i.inv_fin_year::text || '-' || i.inv_no::text,
                    'invoice_label', warehouse_security.invoice_label(i.inv_prefix, i.inv_no),
                    'inv_prefix', i.inv_prefix,$m$,
$m$'invoice_id', null, 'invoice_number', null, 'invoice_label', null, 'inv_prefix', null, 'invoice_count', 0$m$
]);

-- invoice_labels: the full numbers of the invoices invoice_numbers lists (the same filter), one per distinct number, in its order (by the
-- digits). Each of invoices[] (migration 165) carries its own.
SELECT pg_temp.patch_function('public.get_grn_details(uuid)'::regprocedure, ARRAY[
$m$'invoice_numbers', COALESCE($m$,
$m$'invoices', COALESCE(jsonb_agg(jsonb_build_object('id', inv.id, 'inv_no', inv.inv_no, 'inv_fin_year', inv.inv_fin_year,$m$
], ARRAY[
$m$'invoice_labels', COALESCE((SELECT jsonb_agg(l.e->1 ORDER BY l.o) FROM jsonb_array_elements(
                                jsonb_agg(DISTINCT jsonb_build_array(inv.inv_no, warehouse_security.invoice_label(inv.inv_prefix, inv.inv_no))
                                          ORDER BY jsonb_build_array(inv.inv_no, warehouse_security.invoice_label(inv.inv_prefix, inv.inv_no)))
                                    FILTER (WHERE inv.inv_no IS NOT NULL AND inv.cancelled_at IS NULL)) WITH ORDINALITY AS l(e, o)), '[]'::jsonb),
                            'invoice_numbers', COALESCE($m$,
$m$'invoices', COALESCE(jsonb_agg(jsonb_build_object('id', inv.id, 'inv_no', inv.inv_no, 'inv_fin_year', inv.inv_fin_year,
                                                                              'inv_prefix', inv.inv_prefix,
                                                                              'invoice_label', warehouse_security.invoice_label(inv.inv_prefix, inv.inv_no),$m$
]);

SELECT pg_temp.patch_function('public.get_dispatch_details(uuid)'::regprocedure, ARRAY[
$m$'invoice_numbers', COALESCE($m$,
$m$'invoice_no', inv.inv_no,$m$
], ARRAY[
$m$'invoice_labels', COALESCE((SELECT jsonb_agg(l.e->1 ORDER BY l.o) FROM jsonb_array_elements(
                                jsonb_agg(DISTINCT jsonb_build_array(inv.inv_no, warehouse_security.invoice_label(inv.inv_prefix, inv.inv_no))
                                          ORDER BY jsonb_build_array(inv.inv_no, warehouse_security.invoice_label(inv.inv_prefix, inv.inv_no)))
                                    FILTER (WHERE inv.inv_no IS NOT NULL)) WITH ORDINALITY AS l(e, o)), '[]'::jsonb),
                            'invoice_numbers', COALESCE($m$,
$m$'invoice_no', inv.inv_no,
                                            'invoice_label', warehouse_security.invoice_label(inv.inv_prefix, inv.inv_no),$m$
]);

SELECT pg_temp.patch_function('public.get_grn_edit_state(uuid)'::regprocedure, ARRAY[
-- the top-level invoice object (data.invoice), with an invoice or with only the invoiced flag
$m$jsonb_build_object('id', i.id, 'inv_no', i.inv_no, 'inv_fin_year', i.inv_fin_year)$m$,
$m$jsonb_build_object('id', NULL, 'inv_no', NULL, 'inv_fin_year', NULL)$m$,
$m$'invoice_no', inv.inv_no,$m$,
$m$SELECT i.inv_no, i.inv_fin_year
        FROM invoice_trl it$m$
], ARRAY[
$m$jsonb_build_object('id', i.id, 'inv_no', i.inv_no, 'inv_fin_year', i.inv_fin_year,
                          'inv_prefix', i.inv_prefix, 'invoice_label', warehouse_security.invoice_label(i.inv_prefix, i.inv_no))$m$,
$m$jsonb_build_object('id', NULL, 'inv_no', NULL, 'inv_fin_year', NULL, 'inv_prefix', NULL, 'invoice_label', NULL)$m$,
$m$'invoice_no', inv.inv_no,
               'invoice_label', warehouse_security.invoice_label(inv.inv_prefix, inv.inv_no),$m$,
$m$SELECT i.inv_no, i.inv_fin_year, i.inv_prefix
        FROM invoice_trl it$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
