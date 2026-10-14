-- The dispatch and invoice read figures (external review 2026-10-13, findings I6 to I11).
--
-- Worked example (the review's fixture, tests/dispatch_invoice_read_figures.sql): receipt lots A and
-- B of 10 bags, one dispatch of 10 + 10, invoice 90101 at duration 1.5, charge 10, tax 5 %, labour 2.
-- Per line the invoice code computes storage round(10 x 10 x 1.5) = 150 + labour 2 x 10 = 20, base
-- 170, tax 8.50, line 178.50; the stored header is 357.
--
--   I6  get_dispatch_details(uuid)
--       invoices_summary.total_amount summed invoice.total once per dispatch line on the invoice
--       (714); it now sums each invoice of the dispatch once (357; two invoices of 357 each give 714,
--       which a SUM(DISTINCT total) would not). statistics.total_invoice_amount was SUM(charge x
--       duration), no quantity, labour or tax (30); it is now the invoiced amount of THIS dispatch's
--       lines (an invoice is per receipt and may hold other dispatches' lines), each line as
--       get_invoice_items_detailed computes it (migration 41): base + round(base x tax / 100, 2) = 357.
--       It leaves out the header's whole-rupee rounding of the tax and the total, and the discount.
--   I7  get_all_dispatch_items: LIMIT/OFFSET applied to the one aggregated row, so the first page
--       held every match and later pages were empty. The rows are now numbered in the requested
--       order (ties broken by the dispatch line id), paged, and then aggregated in that order.
--   I8  get_all_dispatch_items: the rows were limited to admin/supervisor or the caller's customers
--       while the count and sums also let staff through, so staff got totals and no rows. The rows
--       now use the same three roles. (Customers are refused by authorize_rpc before either.)
--   I9  mv_invoice_list.total_qty was sum(DISTINCT grt.qty): two lots of 10 bags counted 10. It is
--       now sum(dt.disp_qty), the bags billed (20). A materialized view cannot be replaced, so it is
--       dropped and created again with the same columns, the same seven indexes (the unique one is
--       needed by REFRESH ... CONCURRENTLY in trigger_refresh_invoice_list_mv), the same owner and
--       the same grants (checked), then filled and its refresh-queue row cleared. The triggers are
--       on their tables and stay: only those on invoice and invoice_trl call
--       trigger_refresh_invoice_list_mv; the one on dispatch_trl (mark_invoice_mv_dirty) only marks
--       the view for refresh, so a change of a dispatched quantity reaches total_qty at the next
--       refresh.
--   I10 get_customer_invoice_summary, line_items of one customer's invoices: quantity was the
--       duration (1.5), rate charge / duration (6.67), labour_amount labour x duration (3),
--       tax_percent tax / charge x 100 (50), tax_amount the tax percent (5), line_total charge + tax
--       + labour x duration (18). They are now the bags dispatched (10), the charge (10), the labour
--       of the line (20; 0 for a ONE_TIME receipt), the tax percent (5), the line's tax (8.50) and
--       the line total (178.50), so the lines add up to the header. total_quantity is the bags
--       (20, was 3.0). The pricing mode is read from the receipt, as the invoice code does; a receipt's
--       mode cannot change once it is invoiced (migration 65). Keys, types and the rows are as before.
--   I11 Invoice numbers: LPAD(inv_no::text, 4, '0') cuts a longer number (90101 became 9010). It is
--       now LPAD(inv_no::text, GREATEST(4, LENGTH(inv_no::text)), '0'), as migration 9 pads dispatch
--       numbers: get_customer_invoice_summary and get_customer_activity_detail (2026-90101; 104 is
--       still 2026-0104), get_grn_invoices (dormant: granted to no app role, and it reads a table
--       that no migration creates; the text is corrected for consistency) and the two search
--       comparisons of get_invoices_list (the unpadded form was already compared as well).
--
-- Method: the current definitions (pg_get_functiondef, as migrations 61 and 62 leave them) are patched;
-- each replaced text must occur exactly as often as stated, or the migration fails and nothing is
-- applied. SECURITY DEFINER, the settings (search_path, jit) and the grants of every patched function
-- are checked to be unchanged.

CREATE FUNCTION pg_temp.replace_marker(fn text, definition text, marker text, replacement text, expected integer) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE occurrences integer := (length(definition) - length(replace(definition, marker, ''))) / length(marker);
BEGIN
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker, 80);
  END IF;
  RETURN replace(definition, marker, replacement);
END $$;

DO $migration$
DECLARE
  change record;
  current_fn text := '';
  definition text;
  before_state jsonb;
  after_state jsonb;
  -- The line amount of get_invoice_items_detailed (migration 41) and recalculate_invoice_header (48).
  line_base CONSTANT text := $base$CASE WHEN gr_line.pricing_mode = 'ONE_TIME'
                            THEN ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2)
                            ELSE ROUND(COALESCE(it.charge, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric * COALESCE(it.duration, 1)::numeric, 2)
                                 + ROUND(COALESCE(it.labour_rate, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2)
                            END$base$;
BEGIN
  SELECT jsonb_object_agg(p.oid::regprocedure::text, jsonb_build_array(p.prosecdef, p.proconfig, p.proacl::text[], p.proowner))
    INTO before_state
  FROM pg_proc p WHERE p.oid IN (
    'public.get_dispatch_details(uuid)'::regprocedure,
    'public.get_all_dispatch_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)'::regprocedure,
    'public.get_customer_invoice_summary(uuid,date,date,integer)'::regprocedure,
    'public.get_customer_activity_detail(uuid,date,date)'::regprocedure,
    'public.get_grn_invoices(uuid)'::regprocedure,
    'public.get_invoices_list(integer,integer,uuid,integer,text,text,text,text,integer,integer,text,timestamptz,timestamptz,uuid[])'::regprocedure);

  FOR change IN SELECT * FROM (VALUES
    -- I6: each invoice of the dispatch once ...
    (1, 'public.get_dispatch_details(uuid)',
     $b$                        FROM dispatch_trl dt
                        JOIN invoice_trl it ON dt.id = it.disp_trl_id
                        JOIN invoice inv ON it.invoice_id = inv.id
                        WHERE dt.disp_id = d.id$b$,
     $a$                        FROM invoice inv
                        WHERE inv.id IN (
                            SELECT it.invoice_id
                            FROM dispatch_trl dt
                            JOIN invoice_trl it ON dt.id = it.disp_trl_id
                            WHERE dt.disp_id = d.id
                        )$a$, 1),
    -- ... and the invoiced amount of this dispatch's lines, as the invoice computes each line.
    (2, 'public.get_dispatch_details(uuid)',
     $b$'total_invoice_amount', COALESCE(SUM(it.charge * it.duration), 0),$b$,
     $a$'total_invoice_amount', COALESCE(SUM(amount.base + ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2)) FILTER (WHERE it.id IS NOT NULL), 0),$a$, 1),
    (3, 'public.get_dispatch_details(uuid)',
     $b$                        FROM dispatch_trl dt
                        LEFT JOIN invoice_trl it ON dt.id = it.disp_trl_id
                        WHERE dt.disp_id = d.id$b$,
     $a$                        FROM dispatch_trl dt
                        LEFT JOIN invoice_trl it ON dt.id = it.disp_trl_id
                        LEFT JOIN goodsreceived gr_line ON gr_line.id = dt.gr_id
                        -- The line amount of get_invoice_items_detailed (no header rounding, no discount).
                        CROSS JOIN LATERAL (
                            SELECT @BASE@ AS base
                        ) AS amount
                        WHERE dt.disp_id = d.id$a$, 1),

    -- I7: number the matching rows in the requested order, page them, then aggregate the page.
    (10, 'public.get_all_dispatch_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)',
     $b$            SELECT jsonb_agg(
                jsonb_build_object(
                    ''id'', dt.id,$b$,
     $a$            SELECT jsonb_agg(page.item ORDER BY page.rn)
            FROM (
              SELECT jsonb_build_object(
                    ''id'', dt.id,$a$, 1),
    (11, 'public.get_all_dispatch_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)',
     $b$                    ''updated_at'', d.updated_at
                ) ORDER BY %s %s
            )
            FROM dispatch_trl dt$b$,
     $a$                    ''updated_at'', d.updated_at
                ) AS item,
                row_number() OVER (ORDER BY %s %s, dt.id) AS rn
              FROM dispatch_trl dt$a$, 1),
    -- I8: the rows let staff through, as the count and the sums do.
    (12, 'public.get_all_dispatch_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)',
     $b$WHERE ($1 IN (''admin'', ''supervisor'') OR d.customer_id = ANY($2))$b$,
     $a$WHERE ($1 IN (''admin'', ''supervisor'', ''staff'') OR d.customer_id = ANY($2))$a$, 1),
    (13, 'public.get_all_dispatch_items(timestamptz,timestamptz,jsonb,text,text,integer,integer)',
     $b$            LIMIT $6 OFFSET $7',$b$,
     $a$              ORDER BY rn
              LIMIT $6 OFFSET $7
            ) page',$a$, 1),

    -- I11 and I10: get_customer_invoice_summary.
    (20, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$LPAD(i.inv_no::text, 4, '0')$b$,
     $a$LPAD(i.inv_no::text, GREATEST(4, LENGTH(i.inv_no::text)), '0')$a$, 1),
    (21, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$SUM(it.duration) as total_quantity,$b$,
     $a$SUM(dt.disp_qty) as total_quantity,$a$, 1),
    (22, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$                        'quantity', it.duration,
                        'rate', CASE WHEN it.duration > 0 THEN ROUND(it.charge / it.duration, 2) ELSE 0 END,
                        'no_of_days', it.no_of_days,
                        'charge', it.charge,
                        'labour_rate', it.labour_rate,
                        'labour_amount', ROUND(it.labour_rate * it.duration, 2),
                        'tax_percent', CASE WHEN it.charge > 0 THEN ROUND((it.tax / it.charge) * 100, 0) ELSE 0 END,
                        'tax_amount', it.tax,
                        'line_total', COALESCE(it.charge, 0) + COALESCE(it.tax, 0) + ROUND(COALESCE(it.labour_rate, 0) * COALESCE(it.duration, 0), 2),$b$,
     $a$                        'quantity', dt.disp_qty,
                        'rate', it.charge,
                        'no_of_days', it.no_of_days,
                        'charge', it.charge,
                        'labour_rate', it.labour_rate,
                        'labour_amount', amount.labour,
                        'tax_percent', it.tax,
                        'tax_amount', ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2),
                        'line_total', amount.base + ROUND(amount.base * COALESCE(it.tax, 0)::numeric / 100, 2),$a$, 1),
    (23, 'public.get_customer_invoice_summary(uuid,date,date,integer)',
     $b$            JOIN goodsreceived gr ON grt.gr_id = gr.id
            GROUP BY it.invoice_id$b$,
     $a$            JOIN goodsreceived gr ON grt.gr_id = gr.id
            -- The line amount of get_invoice_items_detailed; labour is 0 for a ONE_TIME receipt.
            CROSS JOIN LATERAL (
                SELECT @BASE_GR@ AS base,
                       CASE WHEN gr.pricing_mode = 'ONE_TIME' THEN 0::numeric
                            ELSE ROUND(COALESCE(it.labour_rate, 0)::numeric * COALESCE(dt.disp_qty, 0)::numeric, 2) END AS labour
            ) AS amount
            GROUP BY it.invoice_id$a$, 1),

    -- I11: the other three.
    (30, 'public.get_customer_activity_detail(uuid,date,date)',
     $b$LPAD(i.inv_no::text, 4, '0')$b$,
     $a$LPAD(i.inv_no::text, GREATEST(4, LENGTH(i.inv_no::text)), '0')$a$, 1),
    (40, 'public.get_grn_invoices(uuid)',
     $b$LPAD(inv.inv_no::text, 4, '0')$b$,
     $a$LPAD(inv.inv_no::text, GREATEST(4, LENGTH(inv.inv_no::text)), '0')$a$, 1),
    (50, 'public.get_invoices_list(integer,integer,uuid,integer,text,text,text,text,integer,integer,text,timestamptz,timestamptz,uuid[])',
     $b$lpad(m.inv_no::text, 4, '0')$b$,
     $a$lpad(m.inv_no::text, GREATEST(4, LENGTH(m.inv_no::text)), '0')$a$, 2)
  ) AS changes(step, signature, before_text, after_text, times)
  ORDER BY step
  LOOP
    IF change.signature <> current_fn THEN
      IF current_fn <> '' THEN EXECUTE definition; END IF;
      current_fn := change.signature;
      definition := pg_get_functiondef(current_fn::regprocedure);
    END IF;
    definition := pg_temp.replace_marker(current_fn, definition, change.before_text,
      replace(replace(change.after_text, '@BASE@', line_base), '@BASE_GR@', replace(line_base, 'gr_line.', 'gr.')),
      change.times);
  END LOOP;
  EXECUTE definition;

  SELECT jsonb_object_agg(p.oid::regprocedure::text, jsonb_build_array(p.prosecdef, p.proconfig, p.proacl::text[], p.proowner))
    INTO after_state
  FROM pg_proc p WHERE p.oid IN (SELECT k::regprocedure FROM jsonb_object_keys(before_state) AS t(k));
  IF after_state IS DISTINCT FROM before_state OR jsonb_typeof(before_state) IS DISTINCT FROM 'object'
     OR (SELECT count(*) FROM jsonb_object_keys(before_state)) <> 6 THEN
    RAISE EXCEPTION 'A patched function changed its SECURITY DEFINER, settings, grants or owner: % became %', before_state, after_state;
  END IF;
END;
$migration$;

DROP FUNCTION pg_temp.replace_marker(text, text, text, text, integer);

-- I9: mv_invoice_list with the billed quantity. The writers of invoice and dispatch lines take lock
-- 71040 before they refresh the list views; this migration takes it first.
SELECT pg_advisory_xact_lock(71040);
CREATE TEMP TABLE mv_invoice_list_before ON COMMIT DROP AS
  SELECT c.relowner, c.relacl FROM pg_class c WHERE c.oid = 'public.mv_invoice_list'::regclass;
DO $check$
BEGIN
  IF (SELECT count(*) FROM mv_invoice_list_before) <> 1
     OR position('sum(DISTINCT grt.qty)' IN pg_get_viewdef('public.mv_invoice_list'::regclass)) = 0 THEN
    RAISE EXCEPTION 'mv_invoice_list is not the baseline view this migration replaces';
  END IF;
END $check$;

DROP MATERIALIZED VIEW public.mv_invoice_list;

CREATE MATERIALIZED VIEW public.mv_invoice_list AS
 WITH invoice_qty_agg AS (
         SELECT it.invoice_id,
            COALESCE(sum(dt.disp_qty), (0)::bigint) AS total_qty
           FROM ((public.invoice_trl it
             JOIN public.dispatch_trl dt ON ((dt.id = it.disp_trl_id)))
             JOIN public.goodsreceived_trl grt ON ((grt.id = dt.gr_trl_id)))
          GROUP BY it.invoice_id
        )
 SELECT i.id AS invoice_id,
    i.inv_no,
    i.inv_fin_year,
    i.inv_date,
    i.inv_name,
    i.pricing_mode,
    i.notes,
    i.is_auto_generated,
    i.total,
    i.discount,
    i.labour,
    i.tax_amount,
    i.one_time_charge,
    i.created_by,
    (COALESCE(iqa.total_qty, (0)::bigint))::numeric AS total_qty,
    c.id AS customer_id,
    c.name AS customer_name,
    c.city AS customer_city,
    c.address AS customer_address,
    c.mobile AS customer_phone,
    c.email AS customer_email,
    c.gst AS customer_gst,
    c.active AS customer_active,
    gr.id AS grn_id,
    gr.gr_no,
    gr.registration AS grn_registration,
    gr.date AS grn_date,
    gr.sender_id AS grn_sender_id,
    gr.sender_name AS grn_sender_name,
    gr.supervisor_id AS grn_supervisor_id,
    gr.supervisor_name AS grn_supervisor_name,
    gr.customer_id AS grn_customer_id,
    gr.customer_name AS grn_customer_name,
    ((i.inv_fin_year || '-'::text) || (i.inv_fin_year + 1)) AS financial_year_display
   FROM (((public.invoice i
     JOIN public.customers c ON ((c.id = i.customer_id)))
     JOIN public.goodsreceived gr ON ((gr.id = i.gr_id)))
     LEFT JOIN invoice_qty_agg iqa ON ((iqa.invoice_id = i.id)))
  WHERE (i.deleted_at IS NULL)
  WITH NO DATA;

CREATE INDEX idx_mv_invoice_list_customer ON public.mv_invoice_list USING btree (customer_id);
CREATE INDEX idx_mv_invoice_list_customer_date ON public.mv_invoice_list USING btree (customer_id, inv_date DESC NULLS LAST);
CREATE INDEX idx_mv_invoice_list_date_desc ON public.mv_invoice_list USING btree (inv_date DESC NULLS LAST);
CREATE INDEX idx_mv_invoice_list_fin_year ON public.mv_invoice_list USING btree (inv_fin_year);
CREATE INDEX idx_mv_invoice_list_gr_no ON public.mv_invoice_list USING btree (gr_no);
CREATE INDEX idx_mv_invoice_list_inv_no ON public.mv_invoice_list USING btree (inv_no);
CREATE UNIQUE INDEX idx_mv_invoice_list_pk ON public.mv_invoice_list USING btree (invoice_id);

-- Owner and grants as before: the default privileges of the new relation are revoked and the recorded
-- ones granted again, then compared.
DO $grants$
DECLARE before_owner oid; before_acl aclitem[]; after_acl aclitem[]; entry record;
BEGIN
  SELECT relowner, relacl INTO STRICT before_owner, before_acl FROM mv_invoice_list_before;
  EXECUTE format('ALTER MATERIALIZED VIEW public.mv_invoice_list OWNER TO %I', before_owner::regrole::text);
  REVOKE ALL ON public.mv_invoice_list FROM PUBLIC, anon, authenticated;
  FOR entry IN SELECT DISTINCT a.grantee FROM pg_class c, aclexplode(c.relacl) a
               WHERE c.oid = 'public.mv_invoice_list'::regclass AND a.grantee <> before_owner AND a.grantee <> 0 LOOP
    EXECUTE format('REVOKE ALL ON public.mv_invoice_list FROM %I', entry.grantee::regrole::text);
  END LOOP;
  FOR entry IN SELECT a.grantee, a.privilege_type, a.is_grantable FROM aclexplode(before_acl) a
               WHERE a.grantee <> before_owner LOOP
    EXECUTE format('GRANT %s ON public.mv_invoice_list TO %s%s', entry.privilege_type,
      CASE WHEN entry.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(entry.grantee::regrole::text) END,
      CASE WHEN entry.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END);
  END LOOP;
  SELECT relacl INTO STRICT after_acl FROM pg_class WHERE oid = 'public.mv_invoice_list'::regclass;
  IF ARRAY(SELECT x::text FROM unnest(after_acl) AS t(x) ORDER BY 1) IS DISTINCT FROM ARRAY(SELECT x::text FROM unnest(before_acl) AS t(x) ORDER BY 1)
     OR (SELECT relowner FROM pg_class WHERE oid = 'public.mv_invoice_list'::regclass) <> before_owner THEN
    RAISE EXCEPTION 'mv_invoice_list grants changed: % became %', before_acl, after_acl;
  END IF;
END $grants$;

REFRESH MATERIALIZED VIEW public.mv_invoice_list;
UPDATE public.mv_refresh_queue SET needs_refresh = false, last_refresh = now() WHERE mv_name = 'mv_invoice_list';
DROP TABLE mv_invoice_list_before;

NOTIFY pgrst, 'reload schema';
