-- Migration 127: a numbering rule per facility for GRN, dispatch and invoice numbers (WS-8).
--
--  * warehouse_security.document_numbering: one row per document type (grn, dispatch, invoice) with the rule: scheme (letters,
--    year, sequence, free), prefix, width (digits), start, first letter and numbers per letter. warehouse_security.
--    document_numbering_history keeps every change (old rule, new rule, who, when, how many live documents existed), append-only.
--    Neither table has a grant for an app role: the RPCs below are the only readers and writers.
--  * The rows start as today's behaviour: GRN letters from A (from W when the facility holds both W and X numbers, from X when it
--    holds X, Y or Z numbers: FAS's W, X, Y, Z, A, B ... order), 4 digits, 1000 per letter; dispatch `I` + 4 digits; invoice numbers
--    restart at 1 every financial year. Each rule has a switch, "check": on, a number outside the rule is refused when a document is
--    saved; off, only a number taken already is refused (and a number over 20 characters), and the rule still drives the suggestion.
--    A document type whose existing numbers do not all follow the rule it starts with (G1234A, H0012, CLR0001 beside I####) starts with the
--    check off, and this migration prints how many numbers do not follow it; every other row starts with the check on.
--  * public.suggest_document_number(p_document_type, p_date) answers {number, hint, scheme, reason}; get_document_numbering() reads
--    the rules (administrators and supervisors); set_document_numbering(p_document_type, p_rule) changes one (administrators).
--    get_next_grn_number, get_next_dispatch_number and get_next_invoice_number keep their signatures and answer with the same
--    suggestion (an older app and fas-sync keep working); where there is no number to suggest they raise the reason.
--  * The save RPCs refuse a number that does not follow the rule with reason NUMBER_FORMAT, naming the pattern. save_grn and
--    create_dispatch_with_stock_check_internal and update_dispatch_smart (a changed number only) do that in their definition files
--    (migrations/definitions/).
--    The invoice number stays a whole number (check_invoice_number), so its rule decides the suggestion only.
--  * goodsreceived.gr_no, invoice.gr_no and dispatch.disp_no grow from 8 to 20 characters (no rewrite). v_orders_list reads
--    dispatch.disp_no and is dropped and made again with the same text and grants.
-- The functions this migration creates have their bodies here; the changes to save_grn, create_dispatch_with_stock_check_internal and
-- update_dispatch_smart, and the staff list and the administrator list of authorize_rpc, are in their definition files
-- (tests/definitions-allowed-differences.txt names them).
-- Numbers are matched and suggested only with up to 7 digits after the prefix (the range of the earlier generators, whose index
-- predicates are idx_goodsreceived_gr_no_series and idx_dispatch_disp_no_num); a sequence ends at 9999999 as before.

-- Section 1: the tables
CREATE TABLE warehouse_security.document_numbering (
    document_type text NOT NULL,
    scheme text NOT NULL,
    prefix text DEFAULT '' NOT NULL,
    width smallint DEFAULT 4 NOT NULL,
    start integer DEFAULT 1 NOT NULL,
    fy_reset boolean NOT NULL,
    first_letter text,
    per_letter integer,
    "check" boolean NOT NULL,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT document_numbering_pkey PRIMARY KEY (document_type),
    CONSTRAINT document_numbering_type_check CHECK (document_type IN ('grn', 'dispatch', 'invoice')),
    CONSTRAINT document_numbering_scheme_check CHECK (scheme IN ('letters', 'year', 'sequence', 'free')),
    CONSTRAINT document_numbering_prefix_check CHECK (prefix ~ '^[A-Z0-9/-]{0,10}$'),
    CONSTRAINT document_numbering_width_check CHECK (width BETWEEN 1 AND 7),
    CONSTRAINT document_numbering_start_check CHECK (start BETWEEN 1 AND 9999999),
    CONSTRAINT document_numbering_letters_check CHECK ((scheme = 'letters') = (first_letter IS NOT NULL AND per_letter IS NOT NULL)
        AND (first_letter IS NULL OR first_letter ~ '^[A-Z]$') AND (per_letter IS NULL OR per_letter BETWEEN 1 AND 9999999)),
    CONSTRAINT document_numbering_prefix_scheme_check CHECK (scheme IN ('year', 'sequence') OR prefix = ''),
    CONSTRAINT document_numbering_fy_reset_check CHECK (fy_reset = (scheme = 'year')),
    -- Invoice numbers are whole numbers: restart every financial year (year) or keep counting (sequence), no prefix.
    CONSTRAINT document_numbering_invoice_check CHECK (document_type <> 'invoice' OR (scheme IN ('year', 'sequence') AND prefix = '' AND width = 1)),
    -- The first number of the rule fits the 20 characters of the column: prefix, "26-27/" for a year rule, and the digits.
    -- An invoice number is always a whole number (check_invoice_number): there is no format check to switch off.
    CONSTRAINT document_numbering_invoice_check_on CHECK (document_type <> 'invoice' OR "check"),
    CONSTRAINT document_numbering_fit_check CHECK (char_length(prefix) + CASE WHEN scheme = 'year' AND document_type <> 'invoice' THEN 6 ELSE 0 END + width <= 20)
);
ALTER TABLE warehouse_security.document_numbering OWNER TO supabase_admin;
ALTER TABLE warehouse_security.document_numbering ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.document_numbering FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE warehouse_security.document_numbering IS 'Migration 127: the numbering rule of each document type; read and written only through the RPCs.';

CREATE TABLE warehouse_security.document_numbering_history (
    id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    document_type text NOT NULL,
    old_rule jsonb NOT NULL,
    new_rule jsonb NOT NULL,
    changed_by uuid,
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    existing_documents bigint NOT NULL,
    CONSTRAINT document_numbering_history_pkey PRIMARY KEY (id)
);
ALTER TABLE warehouse_security.document_numbering_history OWNER TO supabase_admin;
ALTER TABLE warehouse_security.document_numbering_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.document_numbering_history FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE warehouse_security.document_numbering_history IS 'Migration 127: every change of a numbering rule (changed_by is NULL for the operator''s setup). Append-only, never pruned; existing_documents counts the live documents of the type that kept their numbers.';

CREATE FUNCTION warehouse_security.document_rule_json(r warehouse_security.document_numbering) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT jsonb_build_object('scheme', r.scheme, 'prefix', r.prefix, 'width', r.width, 'start', r.start,
                            'first_letter', r.first_letter, 'per_letter', r.per_letter, 'check', r."check")
$$;
ALTER FUNCTION warehouse_security.document_rule_json(warehouse_security.document_numbering) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.document_rule_json(warehouse_security.document_numbering) FROM PUBLIC;

-- The live documents of a type: what "N documents keep their numbers" counts.
CREATE FUNCTION warehouse_security.document_count(p_type text) RETURNS bigint
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
  SELECT CASE p_type
           WHEN 'grn' THEN (SELECT count(*) FROM public.goodsreceived WHERE deleted_at IS NULL)
           WHEN 'dispatch' THEN (SELECT count(*) FROM public.dispatch WHERE deleted_at IS NULL)
           WHEN 'invoice' THEN (SELECT count(*) FROM public.invoice WHERE deleted_at IS NULL)
         END
$$;
ALTER FUNCTION warehouse_security.document_count(text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.document_count(text) FROM PUBLIC;

-- A rule change is written to the history by the table itself, whoever makes it.
CREATE FUNCTION warehouse_security.log_document_numbering() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
BEGIN
  INSERT INTO warehouse_security.document_numbering_history(document_type, old_rule, new_rule, changed_by, existing_documents)
  VALUES (NEW.document_type, warehouse_security.document_rule_json(OLD), warehouse_security.document_rule_json(NEW), NEW.updated_by,
          warehouse_security.document_count(NEW.document_type));
  RETURN NEW;
END $$;
ALTER FUNCTION warehouse_security.log_document_numbering() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.log_document_numbering() FROM PUBLIC;

CREATE FUNCTION warehouse_security.keep_document_numbering() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog'
    AS $$
BEGIN
  RAISE EXCEPTION '% does not allow %', TG_TABLE_NAME, TG_OP USING ERRCODE = '42501';
END $$;
ALTER FUNCTION warehouse_security.keep_document_numbering() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.keep_document_numbering() FROM PUBLIC;

CREATE TRIGGER log_document_numbering AFTER UPDATE ON warehouse_security.document_numbering FOR EACH ROW
  WHEN (ROW(OLD.scheme, OLD.prefix, OLD.width, OLD.start, OLD.first_letter, OLD.per_letter, OLD."check")
        IS DISTINCT FROM ROW(NEW.scheme, NEW.prefix, NEW.width, NEW.start, NEW.first_letter, NEW.per_letter, NEW."check"))
  EXECUTE FUNCTION warehouse_security.log_document_numbering();
CREATE TRIGGER keep_document_numbering BEFORE DELETE ON warehouse_security.document_numbering FOR EACH ROW
  EXECUTE FUNCTION warehouse_security.keep_document_numbering();
CREATE TRIGGER keep_document_numbering_history BEFORE UPDATE OR DELETE ON warehouse_security.document_numbering_history FOR EACH ROW
  EXECUTE FUNCTION warehouse_security.keep_document_numbering();
CREATE TRIGGER keep_document_numbering_truncate BEFORE TRUNCATE ON warehouse_security.document_numbering FOR EACH STATEMENT
  EXECUTE FUNCTION warehouse_security.keep_document_numbering();
CREATE TRIGGER keep_document_numbering_history_truncate BEFORE TRUNCATE ON warehouse_security.document_numbering_history FOR EACH STATEMENT
  EXECUTE FUNCTION warehouse_security.keep_document_numbering();

-- Section 2: numbers up to 20 characters (the order list view reads dispatch.disp_no, so it is made again)
DROP VIEW public.v_orders_list;
ALTER TABLE public.goodsreceived ALTER COLUMN gr_no TYPE character varying(20);
ALTER TABLE public.invoice ALTER COLUMN gr_no TYPE character varying(20);
ALTER TABLE public.dispatch ALTER COLUMN disp_no TYPE character varying(20);
CREATE VIEW public.v_orders_list AS
 WITH order_items_data AS (
         SELECT oi.order_id,
            count(*) FILTER (WHERE (oi.item_status = 'pending'::text)) AS total_items,
            COALESCE(sum(oi.requested_quantity) FILTER (WHERE (oi.item_status = 'pending'::text)), (0)::bigint) AS total_quantity,
            jsonb_agg(jsonb_build_object('id', oi.id, 'order_id', oi.order_id, 'requested_quantity', oi.requested_quantity, 'fulfilled_quantity', oi.fulfilled_quantity, 'grn_items_id', oi.grn_items_id, 'grn_items_item_id', oi.grn_items_item_id, 'grn_items_item_name', oi.grn_items_item_name, 'grn_items_package_mark', oi.grn_items_package_mark, 'grn_items_packaging', oi.grn_items_packaging, 'grn_items_rack', oi.grn_items_rack, 'grn_items_weight', oi.grn_items_weight, 'grn_items_image_url', oi.grn_items_image_url, 'grns_id', oi.grns_id, 'grns_gr_no', oi.grns_gr_no, 'grns_date', oi.grns_date, 'grns_customer_id', oi.grns_customer_id, 'grns_customer_name', oi.grns_customer_name, 'available_stock_at_order', oi.available_stock_at_order, 'current_stock', oi.current_stock, 'item_status', oi.item_status, 'sort_order', oi.sort_order, 'created_at', oi.created_at, 'updated_at', oi.updated_at) ORDER BY oi.sort_order, oi.created_at) AS items_jsonb
           FROM public.order_items oi
          GROUP BY oi.order_id
        ), latest_dispatch AS (
         SELECT DISTINCT ON (dispatch.source_order_id) dispatch.source_order_id,
            dispatch.id AS dispatch_id,
            dispatch.disp_no AS dispatch_no,
            dispatch.created_at AS dispatch_created_at
           FROM (public.dispatch
             JOIN public.orders ord ON ((ord.id = dispatch.source_order_id)))
          WHERE ((dispatch.source_order_id IS NOT NULL) AND (dispatch.customer_id = ord.customer_id))
          ORDER BY dispatch.source_order_id, dispatch.created_at DESC
        )
 SELECT o.id AS order_id,
    o.order_no,
    o.status,
    o.priority,
    o.customer_id,
    o.customer_name,
    o.customer_email,
    o.customer_phone,
    o.is_ignored,
    o.ignored_at,
    o.ignored_by,
    o.ignored_reason,
    o.cancelled_at,
    o.cancelled_by,
    o.cancellation_reason,
    o.created_at,
    o.updated_at,
    o.created_by,
    o.updated_by,
    c.name AS customer_name_detail,
    c.city AS customer_city,
    c.mobile AS customer_mobile,
    c.address AS customer_address,
    up.name AS updated_by_name,
    up.display_name AS updated_by_display_name,
    (COALESCE(oid.total_items, (0)::bigint))::integer AS total_items,
    (COALESCE(oid.total_quantity, (0)::bigint))::numeric AS total_quantity,
    COALESCE(oid.items_jsonb, '[]'::jsonb) AS items_jsonb,
    ld.dispatch_id,
    ld.dispatch_no,
    ld.dispatch_created_at
   FROM ((((public.orders o
     JOIN public.customers c ON ((c.id = o.customer_id)))
     LEFT JOIN order_items_data oid ON ((oid.order_id = o.id)))
     LEFT JOIN public.user_profiles up ON ((up.id = o.updated_by)))
     LEFT JOIN latest_dispatch ld ON ((ld.source_order_id = o.id)))
  WHERE (o.deleted_at IS NULL);

ALTER TABLE public.v_orders_list OWNER TO supabase_admin;
COMMENT ON VIEW public.v_orders_list IS 'Live replacement for mv_orders_list, read only through get_orders_list.';
GRANT ALL ON TABLE public.v_orders_list TO service_role;

-- Section 3: the rule in use (internal; no API role can run these)

-- "26-27" for the financial year of a day.
CREATE FUNCTION warehouse_security.financial_year_label(p_day date) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT lpad(mod(warehouse_security.financial_year(p_day), 100)::text, 2, '0') || '-' || lpad(mod(warehouse_security.financial_year(p_day) + 1, 100)::text, 2, '0')
$$;
ALTER FUNCTION warehouse_security.financial_year_label(date) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.financial_year_label(date) FROM PUBLIC;

-- The digits of a number padded with zeros to the width; a longer number is not cut (lpad would cut it).
CREATE FUNCTION warehouse_security.pad_digits(p_value bigint, p_width integer) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT repeat('0', greatest(p_width - char_length(p_value::text), 0)) || p_value::text
$$;
ALTER FUNCTION warehouse_security.pad_digits(bigint, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.pad_digits(bigint, integer) FROM PUBLIC;

-- What a number looks like, for the placeholder and the refusal: A####, GRN/26-27/####, I####, #. NULL for free text.
CREATE FUNCTION warehouse_security.document_number_pattern(r warehouse_security.document_numbering, p_day date) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT CASE r.scheme
           WHEN 'letters' THEN r.first_letter || repeat('#', r.width)
           WHEN 'year' THEN r.prefix || CASE WHEN r.document_type = 'invoice' THEN '' ELSE warehouse_security.financial_year_label(p_day) || '/' END || repeat('#', r.width)
           WHEN 'sequence' THEN r.prefix || repeat('#', r.width)
         END
$$;
ALTER FUNCTION warehouse_security.document_number_pattern(warehouse_security.document_numbering, date) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.document_number_pattern(warehouse_security.document_numbering, date) FROM PUBLIC;

-- Whether a number has the form of the rule (the check switch is not looked at): the migration's seed and the counts of the numbers
-- that do not follow a rule use it as the save RPCs do. Letters: any letter and at least `width` digits, so FAS's X0001 ... Z1001 fit
-- the letter rule whatever its first letter; year: the prefix, two consecutive years and the digits; sequence: the prefix and the
-- digits; free: any text of the 20 characters of the column. The digits are at most 7, as in the suggestion.
CREATE FUNCTION warehouse_security.document_number_fits(r warehouse_security.document_numbering, p_number text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE
  v_ok boolean;
  v_year text;
BEGIN
  v_ok := char_length(p_number) <= 20 AND CASE r.scheme
    WHEN 'letters' THEN p_number ~ ('^[A-Z][0-9]{' || r.width || ',7}$')
    WHEN 'sequence' THEN p_number ~ ('^' || r.prefix || '[0-9]{' || r.width || ',7}$')
    WHEN 'year' THEN p_number ~ ('^' || r.prefix || '[0-9]{2}-[0-9]{2}/[0-9]{' || r.width || ',7}$')
    ELSE true END;
  IF v_ok AND r.scheme = 'year' THEN
    -- Two consecutive years (26-27, 99-00).
    v_year := substr(p_number, char_length(r.prefix) + 1, 5);
    v_ok := mod(substr(v_year, 1, 2)::integer + 1, 100) = substr(v_year, 4, 2)::integer;
  END IF;
  RETURN v_ok;
END $$;
ALTER FUNCTION warehouse_security.document_number_fits(warehouse_security.document_numbering, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.document_number_fits(warehouse_security.document_numbering, text) FROM PUBLIC;

-- How many numbers of the type (soft-deleted ones too: their numbers stay taken) do not follow a rule, and up to five of them:
-- {count, examples}. Invoices are whole numbers whatever the rule: none.
CREATE FUNCTION warehouse_security.document_number_misfits(r warehouse_security.document_numbering) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_count bigint := 0;
  v_examples text[] := ARRAY[]::text[];
  v_number text;
BEGIN
  IF r.document_type = 'invoice' THEN RETURN jsonb_build_object('count', 0, 'examples', '[]'::jsonb); END IF;
  FOR v_number IN EXECUTE format('SELECT %1$I FROM public.%2$I WHERE %1$I IS NOT NULL ORDER BY %1$I COLLATE "C"',
      CASE r.document_type WHEN 'grn' THEN 'gr_no' ELSE 'disp_no' END, CASE r.document_type WHEN 'grn' THEN 'goodsreceived' ELSE 'dispatch' END) LOOP
    -- A blank number is the business of the blank checks of the tables, not of the rule.
    IF NOT warehouse_security.is_blank_text(v_number) AND NOT warehouse_security.document_number_fits(r, v_number) THEN
      v_count := v_count + 1;
      IF cardinality(v_examples) < 5 THEN v_examples := array_append(v_examples, v_number); END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('count', v_count, 'examples', to_jsonb(v_examples));
END $$;
ALTER FUNCTION warehouse_security.document_number_misfits(warehouse_security.document_numbering) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.document_number_misfits(warehouse_security.document_numbering) FROM PUBLIC;

-- NULL when the typed number follows the rule (or is empty: each save RPC has its own answer for that), else the refusal
-- NUMBER_FORMAT with the pattern. With the rule's check off every number up to the 20 characters of the column passes (only the
-- duplicate check of the save RPC is left).
CREATE FUNCTION warehouse_security.document_number_failure(p_type text, p_number text, p_day date) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  r warehouse_security.document_numbering;
  v_pattern text;
  v_ok boolean;
BEGIN
  IF p_number IS NULL OR warehouse_security.is_blank_text(p_number) THEN RETURN NULL; END IF;
  SELECT * INTO r FROM warehouse_security.document_numbering WHERE document_type = p_type;
  IF NOT FOUND THEN RAISE EXCEPTION 'No numbering rule for %', p_type USING ERRCODE = '22023'; END IF;
  v_pattern := CASE WHEN r."check" THEN warehouse_security.document_number_pattern(r, COALESCE(p_day, warehouse_security.business_date(now()))) END;
  v_ok := CASE WHEN r."check" THEN warehouse_security.document_number_fits(r, p_number) ELSE char_length(p_number) <= 20 END;
  IF v_ok THEN RETURN NULL; END IF;
  RETURN warehouse_security.refuse('NUMBER_FORMAT',
    CASE WHEN v_pattern IS NULL THEN 'This number can have at most 20 characters'
         ELSE format('This number does not follow this facility''s numbering (%s)', v_pattern) END,
    jsonb_build_object('document_type', p_type, 'number', p_number, 'pattern', v_pattern));
END $$;
ALTER FUNCTION warehouse_security.document_number_failure(text, text, date) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.document_number_failure(text, text, date) FROM PUBLIC;

-- The letters of a letter rule: {start, highest, letter}. highest is the highest number of each of the 26 letters in use (A first, null
-- where the letter is unused: an index read of idx_goodsreceived_gr_no_series or the dispatch one each). The order of the letters starts
-- after the longest run of unused letters, counted around the alphabet (Z is followed by A), so the facility's real series is found
-- wherever the rule says it starts, and a stray letter far from it does not take the series over: GCS's books run W, X, Y, Z, A and
-- the order starts at W; one mistyped Q0001 makes Q the start of a one-letter run and the order Q ... P, whose highest letter is still A.
-- Of two runs of the same length the one whose following letter is nearer the rule's first letter wins; with no letter in use or all
-- 26 in use the order starts at the first letter. letter is the highest letter in the order (null with no number in use).
CREATE FUNCTION warehouse_security.letter_series(p_type text, p_first text) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  v_probe text;
  v_first integer := ascii(p_first) - 65;
  v_highest integer[] := ARRAY[]::integer[];
  v_n integer;
  v_idx integer;
  v_run integer;
  v_best integer := 0;
  v_start integer;
  v_try text;
  v_letter text;
BEGIN
  v_probe := format('SELECT CAST(SUBSTRING(%1$I FROM 2) AS INTEGER) FROM public.%2$I WHERE LEFT(%1$I, 1) COLLATE "C" = $1 AND %1$I ~ ''^[A-Z][0-9]{1,7}$'' ORDER BY CAST(SUBSTRING(%1$I FROM 2) AS INTEGER) DESC LIMIT 1',
    CASE p_type WHEN 'grn' THEN 'gr_no' ELSE 'disp_no' END, CASE p_type WHEN 'grn' THEN 'goodsreceived' ELSE 'dispatch' END);
  FOR i IN 0..25 LOOP
    EXECUTE v_probe INTO v_n USING chr(65 + i);
    v_highest := array_append(v_highest, v_n);
  END LOOP;
  FOR d IN 0..25 LOOP
    v_idx := (v_first + d) % 26;
    IF v_highest[v_idx + 1] IS NOT NULL THEN
      v_run := 0;
      WHILE v_run < 25 AND v_highest[((v_idx - v_run - 1 + 26) % 26) + 1] IS NULL LOOP
        v_run := v_run + 1;
      END LOOP;
      IF v_run > v_best THEN v_best := v_run; v_start := v_idx; END IF;
    END IF;
  END LOOP;
  v_start := COALESCE(v_start, v_first);
  FOR i IN REVERSE 25..0 LOOP
    v_try := chr(65 + (v_start + i) % 26);
    IF v_highest[ascii(v_try) - 64] IS NOT NULL THEN v_letter := v_try; EXIT; END IF;
  END LOOP;
  RETURN jsonb_build_object('start', v_start, 'highest', to_jsonb(v_highest), 'letter', v_letter);
END $$;
ALTER FUNCTION warehouse_security.letter_series(text, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.letter_series(text, text) FROM PUBLIC;

-- GRN letters in use outside the main run, for doctor: {series, strays: [{letter, numbers, example}], previous_not_full?}. The runs are the
-- letters in use that follow one another (Z is followed by A); the main run is the one that holds the most numbers (GCS: W, X, Y, Z, A),
-- and a letter in use in another run is a stray, which a typing slip such as Q0001 for A0001 leaves and which should be corrected,
-- because a stray beside the series can take the suggestion over. previous_not_full is there when the highest letter of the order
-- (the one the suggestion continues) follows a letter that is in use but below per_letter: {letter, previous, highest}, one such
-- letter can be the single stray that changes the suggestion (A0500 with B0001 gives B0002) and it joins the run, so it is not
-- a stray. Letter rules only; '{}' for any other rule or with no GRN.
CREATE FUNCTION warehouse_security.grn_stray_letters() RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  r warehouse_security.document_numbering;
  v_series jsonb;
  v_highest jsonb;
  v_counts bigint[] := array_fill(0::bigint, ARRAY[26]);
  v_row record;
  v_members integer[];
  v_best integer[];
  v_sum bigint;
  v_best_sum bigint := -1;
  v_idx integer;
  v_strays jsonb := '[]'::jsonb;
  v_example text;
  v_out jsonb;
  v_top integer;
  v_prev integer;
BEGIN
  SELECT * INTO r FROM warehouse_security.document_numbering WHERE document_type = 'grn';
  IF NOT FOUND OR r.scheme <> 'letters' THEN RETURN '{}'::jsonb; END IF;
  v_series := warehouse_security.letter_series('grn', r.first_letter);
  v_highest := v_series->'highest';
  IF NOT EXISTS (SELECT 1 FROM generate_series(0, 25) i WHERE v_highest->>i IS NOT NULL) THEN RETURN '{}'::jsonb; END IF;
  -- How many numbers each letter holds (one read of the table; doctor only).
  FOR v_row IN SELECT left(gr_no, 1) AS l, count(*) AS c FROM public.goodsreceived WHERE gr_no COLLATE "C" ~ '^[A-Z][0-9]{1,7}$' GROUP BY 1 LOOP
    v_counts[ascii(v_row.l) - 64] := v_row.c;
  END LOOP;
  FOR i IN 0..25 LOOP
    -- A run begins at a letter in use whose predecessor is not in use.
    IF v_highest->>i IS NOT NULL AND v_highest->>((i + 25) % 26) IS NULL THEN
      v_members := ARRAY[]::integer[];
      v_sum := 0;
      v_idx := i;
      WHILE v_highest->>v_idx IS NOT NULL LOOP
        v_members := array_append(v_members, v_idx);
        v_sum := v_sum + v_counts[v_idx + 1];
        v_idx := (v_idx + 1) % 26;
      END LOOP;
      IF v_sum > v_best_sum THEN v_best_sum := v_sum; v_best := v_members; END IF;
    END IF;
  END LOOP;
  -- Every letter in use: one run, no stray.
  IF v_best IS NULL THEN RETURN jsonb_build_object('series', 'A–Z', 'strays', v_strays); END IF;
  FOR i IN 0..25 LOOP
    IF v_highest->>i IS NOT NULL AND NOT i = ANY (v_best) THEN
      SELECT min(gr_no) INTO v_example FROM public.goodsreceived WHERE gr_no ~ ('^' || chr(65 + i) || '[0-9]{1,7}$');
      v_strays := v_strays || jsonb_build_object('letter', chr(65 + i), 'numbers', v_counts[i + 1], 'example', v_example);
    END IF;
  END LOOP;
  v_out := jsonb_build_object('series', chr(65 + v_best[1]) || '–' || chr(65 + v_best[cardinality(v_best)]), 'strays', v_strays);
  -- The highest letter of the order, when it is not the first of it, follows a letter in use that is not full.
  v_top := ascii(v_series->>'letter') - 65;
  IF v_series->>'letter' IS NOT NULL AND v_top <> (v_series->>'start')::integer THEN
    v_prev := (v_top + 25) % 26;
    IF v_highest->>v_prev IS NOT NULL AND (v_highest->>v_prev)::integer < r.per_letter THEN
      v_out := v_out || jsonb_build_object('previous_not_full', jsonb_build_object('letter', chr(65 + v_top), 'previous', chr(65 + v_prev), 'highest',
        chr(65 + v_prev) || warehouse_security.pad_digits((v_highest->>v_prev)::bigint, r.width)));
    END IF;
  END IF;
  RETURN v_out;
END $$;
ALTER FUNCTION warehouse_security.grn_stray_letters() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.grn_stray_letters() FROM PUBLIC;

-- Seed: today's behaviour. GRN letters start at W when the facility holds both W and X numbers, at X when it holds numbers in
-- FAS's X, Y, Z series (its order is W, X, Y, Z, A, B ...; GCS's books begin at W), otherwise at A. A document type whose existing
-- numbers do not all follow the rule it starts with starts with the check off (saves go through as before, duplicates are still
-- refused, numbers are still suggested; doctor warns until the operator or an administrator switches the check on): the notice says how
-- many numbers do not follow the rule, with up to five of them. New and conforming facilities start with the check on.
DO $seed$
DECLARE
  r warehouse_security.document_numbering;
  v_misfits jsonb;
BEGIN
  FOR r IN
    SELECT 'grn', 'letters', '', 4::smallint, 1, false,
           CASE WHEN EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no ~ '^W[0-9]{1,7}$')
                 AND EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no ~ '^X[0-9]{1,7}$') THEN 'W'
                WHEN EXISTS (SELECT 1 FROM public.goodsreceived WHERE gr_no ~ '^[XYZ][0-9]{1,7}$') THEN 'X'
                ELSE 'A' END, 1000, true, NULL::uuid, now()
    UNION ALL SELECT 'dispatch', 'sequence', 'I', 4::smallint, 1, false, NULL, NULL, true, NULL::uuid, now()
    UNION ALL SELECT 'invoice', 'year', '', 1::smallint, 1, true, NULL, NULL, true, NULL::uuid, now()
  LOOP
    v_misfits := warehouse_security.document_number_misfits(r);
    IF (v_misfits->>'count')::bigint > 0 THEN
      r."check" := false;
      RAISE NOTICE 'Migration 127: % % number(s) do not follow %, the rule this facility starts with (for example %). Their numbers are kept and saves are not checked against the rule yet; doctor says how to switch the check on.',
        v_misfits->>'count', r.document_type, warehouse_security.document_number_pattern(r, current_date), (SELECT string_agg(e, ', ') FROM jsonb_array_elements_text(v_misfits->'examples') e);
    END IF;
    INSERT INTO warehouse_security.document_numbering(document_type, scheme, prefix, width, start, fy_reset, first_letter, per_letter, "check")
    VALUES (r.document_type, r.scheme, r.prefix, r.width, r.start, r.fy_reset, r.first_letter, r.per_letter, r."check");
  END LOOP;
END $seed$;

-- The next number under the rule: {number, hint, scheme, reason, message, sqlstate}. number is NULL with reason TYPE_IT (free text)
-- or SERIES_FULL (no number is left); message and sqlstate are for the get_next_* wrappers, the RPC leaves them out.
--  * letters: the highest letter in use in the order of the letters, and its highest number; at per_letter (1000) the next letter
--    starts at 1 (a number above per_letter, such as FAS's Z1001, is a full letter, never a limit). The order always starts after the
--    longest run of unused letters, counted around the alphabet (Z is followed by A), whatever the rule's first letter says: GCS's
--    books run W, X, Y, Z, A and the rule may say W, X or A, the answer is the same, and one mistyped letter far from the series does
--    not take it over (letter_series). Only with no letter in use, or all 26, the first letter starts the order. After the last letter
--    of the order (the one before its start) the series is full. All 26 letters are looked up, each an index read
--    (idx_goodsreceived_gr_no_series).
--  * sequence and year: the highest number after the prefix (year: the prefix and "26-27/" of the day), plus 1, not below start,
--    padded to the width; it grows past the width and ends at 9999999 or when it no longer fits the 20 characters.
--  * invoice: whole numbers, per financial year (year) or across them (sequence); the ceiling is invoice_number_max().
-- Soft-deleted rows count, as before (their numbers stay taken).
CREATE FUNCTION warehouse_security.document_number_suggestion(p_type text, p_day date, p_fin_year integer DEFAULT NULL) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  r warehouse_security.document_numbering;
  v_day date;
  v_out jsonb;
  v_name text;
  v_table text;
  v_column text;
  v_last text;
  v_letter text;
  v_n integer;
  v_next bigint;
  v_prefix text;
  v_fy integer;
  v_number text;
  v_series jsonb;
BEGIN
  SELECT * INTO r FROM warehouse_security.document_numbering WHERE document_type = p_type;
  IF NOT FOUND THEN RAISE EXCEPTION 'No numbering rule for %', p_type USING ERRCODE = '22023'; END IF;
  v_day := COALESCE(p_day, warehouse_security.business_date(now()));
  v_out := jsonb_build_object('number', NULL, 'hint', warehouse_security.document_number_pattern(r, v_day), 'scheme', r.scheme, 'reason', NULL);
  v_name := CASE p_type WHEN 'grn' THEN 'GRN' WHEN 'dispatch' THEN 'Dispatch' ELSE 'Invoice' END;
  v_table := CASE p_type WHEN 'grn' THEN 'goodsreceived' WHEN 'dispatch' THEN 'dispatch' END;
  v_column := CASE p_type WHEN 'grn' THEN 'gr_no' WHEN 'dispatch' THEN 'disp_no' END;

  IF r.scheme = 'free' THEN
    RETURN v_out || jsonb_build_object('reason', 'TYPE_IT', 'message', format('Type the %s number.', CASE p_type WHEN 'grn' THEN 'GRN' ELSE lower(v_name) END), 'sqlstate', 'WH409');
  END IF;

  IF p_type = 'invoice' THEN
    v_fy := COALESCE(p_fin_year, warehouse_security.financial_year(v_day));
    -- Numbers above INVOICE_NUMBER_MAX (migration 73) do not count.
    SELECT MAX(inv_no) INTO v_n FROM public.invoice
      WHERE inv_no >= 1 AND inv_no <= warehouse_security.invoice_number_max() AND (r.scheme = 'sequence' OR inv_fin_year = v_fy);
    IF v_n >= warehouse_security.invoice_number_max() THEN
      RETURN v_out || jsonb_build_object('reason', 'SERIES_FULL', 'sqlstate', 'WH409',
        'message', CASE WHEN r.scheme = 'sequence' THEN 'No invoice number is left' ELSE format('No invoice number is left in financial year %s', v_fy) END);
    END IF;
    RETURN v_out || jsonb_build_object('number', greatest(r.start, COALESCE(v_n, 0) + 1)::text);
  END IF;

  IF r.scheme = 'letters' THEN
    v_series := warehouse_security.letter_series(p_type, r.first_letter);
    v_letter := v_series->>'letter';
    v_last := chr(65 + ((v_series->>'start')::integer + 25) % 26);
    IF v_letter IS NULL THEN
      RETURN v_out || jsonb_build_object('number', r.first_letter || warehouse_security.pad_digits(1, r.width));
    END IF;
    v_n := (v_series->'highest'->>(ascii(v_letter) - 65))::integer;
    IF v_n >= r.per_letter THEN
      IF v_letter = v_last THEN
        RETURN v_out || jsonb_build_object('reason', 'SERIES_FULL', 'sqlstate', 'WH409',
          'message', format('All %s numbers %s%s–%s%s are used', CASE p_type WHEN 'grn' THEN 'GRN' ELSE lower(v_name) END, r.first_letter, warehouse_security.pad_digits(1, r.width), v_last, r.per_letter));
      END IF;
      RETURN v_out || jsonb_build_object('number', chr(65 + (ascii(v_letter) - 65 + 1) % 26) || warehouse_security.pad_digits(1, r.width));
    END IF;
    RETURN v_out || jsonb_build_object('number', v_letter || warehouse_security.pad_digits(v_n + 1, r.width));
  END IF;

  v_prefix := r.prefix || CASE WHEN r.scheme = 'year' THEN warehouse_security.financial_year_label(v_day) || '/' ELSE '' END;
  EXECUTE format('SELECT max(CAST(substr(%1$I, $2) AS INTEGER)) FROM public.%2$I WHERE %1$I ~ $1', v_column, v_table)
    INTO v_n USING '^' || v_prefix || '[0-9]{1,7}$', char_length(v_prefix) + 1;
  v_next := greatest(r.start, COALESCE(v_n, 0) + 1);
  v_number := v_prefix || warehouse_security.pad_digits(v_next, r.width);
  IF v_n >= 9999999 OR char_length(v_number) > 20 THEN
    RETURN v_out || jsonb_build_object('reason', 'SERIES_FULL', 'message', format('%s number sequence exhausted at %s9999999', v_name, v_prefix), 'sqlstate', '22003');
  END IF;
  RETURN v_out || jsonb_build_object('number', v_number);
END $$;
ALTER FUNCTION warehouse_security.document_number_suggestion(text, date, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.document_number_suggestion(text, date, integer) FROM PUBLIC;

-- Changes the rule of one document type (the RPC below, and the operator's setup through psql). The saves take the same document
-- lock, so a save sees the old rule or the new one, never half of a change. Nothing is written when the rule is the one stored.
-- A rule is a JSON object; a field that does not belong to its scheme is refused, one that is left out takes its default:
--   letters   {scheme, first_letter (A), width (4, 1-7), per_letter (1000), check}
--   year      {scheme, prefix (''), width (4, 1-7), start (1), check}      GRN and dispatch numbers like GRN/26-27/0042
--   sequence  {scheme, prefix (''), width (4, 1-7), start (1), check}      I0042, or 1001 with no prefix
--   free      {scheme}
-- check (true or false) says whether a number outside the rule is refused on save; left out, it stays as it is stored (a free rule has
-- nothing to check, and its check is on). Switching it on where existing numbers do not follow the rule is allowed: they keep their
-- numbers, and the answer says how many they are (not_following).
-- Invoice numbers are whole numbers: {scheme: year | sequence, start (1)}; year restarts at 1 every financial year (as before),
-- sequence keeps counting across years.
CREATE FUNCTION warehouse_security.apply_document_numbering(p_type text, p_rule jsonb, p_by uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public'
    AS $$
DECLARE
  r_old warehouse_security.document_numbering;
  r_new warehouse_security.document_numbering;
  v_allowed text[];
  v_key text;
  v_rows integer;
  v_next jsonb;
BEGIN
  IF p_type IS NULL OR p_type NOT IN ('grn', 'dispatch', 'invoice') THEN
    RAISE EXCEPTION 'Unknown document type %. Use grn, dispatch or invoice.', COALESCE(p_type, 'NULL') USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_rule) IS DISTINCT FROM 'object' OR jsonb_typeof(p_rule->'scheme') IS DISTINCT FROM 'string' THEN
    RAISE EXCEPTION 'The rule must be an object with a scheme.' USING ERRCODE = '22023';
  END IF;
  -- The same lock as every document save (migration 87).
  PERFORM pg_advisory_xact_lock(71040);
  SELECT * INTO r_old FROM warehouse_security.document_numbering WHERE document_type = p_type FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No numbering rule for %', p_type USING ERRCODE = '22023'; END IF;

  r_new := r_old;
  r_new.scheme := p_rule->>'scheme';
  r_new.prefix := '';
  r_new.width := 4;
  r_new.start := 1;
  r_new.first_letter := NULL;
  r_new.per_letter := NULL;
  IF p_type = 'invoice' THEN
    IF r_new.scheme NOT IN ('year', 'sequence') THEN
      RAISE EXCEPTION 'An invoice number is a whole number: use year (starts again at 1 every financial year) or sequence (keeps counting).' USING ERRCODE = '22023';
    END IF;
    v_allowed := ARRAY['scheme', 'start'];
    r_new.width := 1;
  ELSIF r_new.scheme = 'letters' THEN
    v_allowed := ARRAY['scheme', 'first_letter', 'width', 'per_letter', 'check'];
    r_new.first_letter := 'A';
    r_new.per_letter := 1000;
  ELSIF r_new.scheme IN ('year', 'sequence') THEN
    v_allowed := ARRAY['scheme', 'prefix', 'width', 'start', 'check'];
  ELSIF r_new.scheme = 'free' THEN
    v_allowed := ARRAY['scheme'];
    r_new."check" := true;
  ELSE
    RAISE EXCEPTION 'Unknown scheme %. Use letters, year, sequence or free.', r_new.scheme USING ERRCODE = '22023';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_rule) LOOP
    IF NOT v_key = ANY (v_allowed) THEN
      RAISE EXCEPTION '% does not belong to a % rule for %.', v_key, r_new.scheme, p_type USING ERRCODE = '22023';
    END IF;
  END LOOP;

  IF p_rule ? 'check' THEN
    IF jsonb_typeof(p_rule->'check') <> 'boolean' THEN
      RAISE EXCEPTION 'The check must be true (a number outside the rule is refused) or false (it is saved).' USING ERRCODE = '22023';
    END IF;
    r_new."check" := (p_rule->>'check')::boolean;
  END IF;
  IF p_rule ? 'prefix' THEN
    IF jsonb_typeof(p_rule->'prefix') <> 'string' OR (p_rule->>'prefix') !~ '^[A-Z0-9/-]{0,10}$' THEN
      RAISE EXCEPTION 'The prefix can have up to 10 characters: capital letters, digits, / and -.' USING ERRCODE = '22023';
    END IF;
    r_new.prefix := p_rule->>'prefix';
  END IF;
  IF p_rule ? 'first_letter' THEN
    IF jsonb_typeof(p_rule->'first_letter') <> 'string' OR (p_rule->>'first_letter') !~ '^[A-Z]$' THEN
      RAISE EXCEPTION 'The first letter must be one capital letter.' USING ERRCODE = '22023';
    END IF;
    r_new.first_letter := p_rule->>'first_letter';
  END IF;
  IF p_rule ? 'width' THEN
    IF jsonb_typeof(p_rule->'width') <> 'number' OR (p_rule->>'width') !~ '^[1-7]$' THEN
      RAISE EXCEPTION 'The number of digits must be a whole number from 1 to 7.' USING ERRCODE = '22023';
    END IF;
    r_new.width := (p_rule->>'width')::smallint;
  END IF;
  IF p_rule ? 'start' THEN
    IF jsonb_typeof(p_rule->'start') <> 'number' OR (p_rule->>'start') !~ '^[1-9][0-9]{0,6}$' THEN
      RAISE EXCEPTION 'The first number must be a whole number from 1 to 9999999.' USING ERRCODE = '22023';
    END IF;
    r_new.start := (p_rule->>'start')::integer;
  END IF;
  IF p_rule ? 'per_letter' THEN
    IF jsonb_typeof(p_rule->'per_letter') <> 'number' OR (p_rule->>'per_letter') !~ '^[1-9][0-9]{0,6}$' THEN
      RAISE EXCEPTION 'The numbers per letter must be a whole number from 1 to 9999999.' USING ERRCODE = '22023';
    END IF;
    r_new.per_letter := (p_rule->>'per_letter')::integer;
  END IF;
  IF r_new.scheme = 'year' AND p_type <> 'invoice' AND char_length(r_new.prefix) + 6 + r_new.width > 20 THEN
    RAISE EXCEPTION 'A number with this prefix, the year (26-27/) and % digits is longer than 20 characters.', r_new.width USING ERRCODE = '22023';
  END IF;

  UPDATE warehouse_security.document_numbering
     SET scheme = r_new.scheme, prefix = r_new.prefix, width = r_new.width, start = r_new.start, fy_reset = (r_new.scheme = 'year'),
         first_letter = r_new.first_letter, per_letter = r_new.per_letter, "check" = r_new."check", updated_by = p_by, updated_at = now()
   WHERE document_type = p_type
     AND ROW(scheme, prefix, width, start, first_letter, per_letter, "check")
         IS DISTINCT FROM ROW(r_new.scheme, r_new.prefix, r_new.width, r_new.start, r_new.first_letter, r_new.per_letter, r_new."check");
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  SELECT * INTO r_new FROM warehouse_security.document_numbering WHERE document_type = p_type;
  v_next := warehouse_security.document_number_suggestion(p_type, NULL, NULL);
  RETURN jsonb_build_object('success', true, 'changed', v_rows > 0, 'document_type', p_type,
    'rule', warehouse_security.document_rule_json(r_new), 'previous_rule', warehouse_security.document_rule_json(r_old),
    'existing_documents', warehouse_security.document_count(p_type),
    'not_following', warehouse_security.document_number_misfits(r_new)->'count',
    'next_number', v_next->'number', 'hint', v_next->'hint', 'reason', v_next->'reason');
END $$;
ALTER FUNCTION warehouse_security.apply_document_numbering(text, jsonb, uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.apply_document_numbering(text, jsonb, uuid) FROM PUBLIC;

-- Section 4: the API
CREATE FUNCTION public.suggest_document_number(p_document_type text, p_date date DEFAULT NULL::date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
BEGIN
  PERFORM warehouse_security.authorize_rpc('suggest_document_number', jsonb_build_object('p_document_type', p_document_type, 'p_date', p_date));
  IF p_document_type IS NULL OR p_document_type NOT IN ('grn', 'dispatch', 'invoice') THEN
    RAISE EXCEPTION 'Unknown document type %. Use grn, dispatch or invoice.', COALESCE(p_document_type, 'NULL') USING ERRCODE = '22023';
  END IF;
  RETURN jsonb_build_object('success', true) || (warehouse_security.document_number_suggestion(p_document_type, p_date, NULL) - 'message' - 'sqlstate');
END $$;
ALTER FUNCTION public.suggest_document_number(text, date) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.suggest_document_number(text, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.suggest_document_number(text, date) TO authenticated, service_role;

CREATE FUNCTION public.get_document_numbering() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_document_numbering', jsonb_build_object());
  RETURN jsonb_build_object('success', true, 'rules', (
    SELECT jsonb_agg(warehouse_security.document_rule_json(n)
             || jsonb_build_object('document_type', n.document_type, 'fy_reset', n.fy_reset,
                  'hint', warehouse_security.document_number_pattern(n, warehouse_security.business_date(now())),
                  'existing_documents', warehouse_security.document_count(n.document_type),
                  'not_following', warehouse_security.document_number_misfits(n)->'count',
                  'updated_at', n.updated_at, 'updated_by', n.updated_by)
             ORDER BY CASE n.document_type WHEN 'grn' THEN 1 WHEN 'dispatch' THEN 2 ELSE 3 END)
    FROM warehouse_security.document_numbering n));
END $$;
ALTER FUNCTION public.get_document_numbering() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.get_document_numbering() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_document_numbering() TO authenticated, service_role;

CREATE FUNCTION public.set_document_numbering(p_document_type text, p_rule jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
BEGIN
  PERFORM warehouse_security.authorize_rpc('set_document_numbering', jsonb_build_object('p_document_type', p_document_type));
  -- authorize_rpc's administrator-only entry for this RPC is in a definition file, applied after the numbered migrations; the body
  -- does not depend on it (a database where that file has not been applied yet must not let a supervisor change a rule).
  IF warehouse_security.active_role() IS DISTINCT FROM 'admin' AND auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Administrator required' USING ERRCODE = '42501';
  END IF;
  RETURN warehouse_security.apply_document_numbering(p_document_type, p_rule, public.get_current_user_profile_id());
END $$;
ALTER FUNCTION public.set_document_numbering(text, jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.set_document_numbering(text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.set_document_numbering(text, jsonb) TO authenticated, service_role;

-- The three get_next_* functions keep their signatures, owners and grants and answer with the same suggestion. Where there is
-- none they raise the reason (the older app would otherwise fill in G0001 or D0001 itself).
CREATE OR REPLACE FUNCTION public.get_next_grn_number() RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_suggestion jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_next_grn_number',jsonb_build_object());
    v_suggestion := warehouse_security.document_number_suggestion('grn', NULL, NULL);
    IF v_suggestion->>'number' IS NULL THEN
        RAISE EXCEPTION '%', v_suggestion->>'message' USING ERRCODE = v_suggestion->>'sqlstate';
    END IF;
    RETURN v_suggestion->>'number';
END;
$$;

CREATE OR REPLACE FUNCTION public.get_next_dispatch_number() RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_suggestion jsonb;
BEGIN
  PERFORM warehouse_security.authorize_rpc('get_next_dispatch_number',jsonb_build_object());
    v_suggestion := warehouse_security.document_number_suggestion('dispatch', NULL, NULL);
    IF v_suggestion->>'number' IS NULL THEN
        RAISE EXCEPTION '%', v_suggestion->>'message' USING ERRCODE = v_suggestion->>'sqlstate';
    END IF;
    RETURN v_suggestion->>'number';
END;
$$;

CREATE OR REPLACE FUNCTION public.get_next_invoice_number(p_fin_year integer DEFAULT NULL::integer) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
    v_fin_year integer;
    v_suggestion jsonb;
BEGIN
    PERFORM warehouse_security.authorize_rpc('get_next_invoice_number', jsonb_build_object());
    v_fin_year := COALESCE(p_fin_year, warehouse_security.financial_year(warehouse_security.business_date(now())));
    v_suggestion := warehouse_security.document_number_suggestion('invoice', NULL, v_fin_year);
    IF v_suggestion->>'number' IS NULL THEN
        RAISE EXCEPTION '%', v_suggestion->>'message' USING ERRCODE = v_suggestion->>'sqlstate';
    END IF;
    RETURN v_suggestion->>'number';
END;
$$;

NOTIFY pgrst, 'reload schema';
