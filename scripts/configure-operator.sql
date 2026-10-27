\set ON_ERROR_STOP on
UPDATE public.system_settings SET value = :'company', updated_at = now()
WHERE key = 'app_name' AND value = 'Warehouse Manager' AND value IS DISTINCT FROM :'company';
UPDATE public.system_settings SET value = '', updated_at = now()
WHERE key = 'support_email' AND value = 'support@example.com';
-- Document numbers (migration 127). setup.sh --grn-numbering, --dispatch-numbering and --invoice-numbering pass the checked rule as the
-- psql variable grn_numbering, dispatch_numbering or invoice_numbering; a rerun without the option leaves the stored rule alone, and
-- the same rule again changes and prints nothing. A change prints the next number and how many documents keep their numbers, and
-- says when the check is off, or how many existing numbers do not follow a rule whose check is on (they keep their numbers).
\if :{?grn_numbering}
  SELECT r->>'changed' = 'true' AS numbering_changed,
         format('Next GRN: %s; %s', COALESCE(r->>'next_number', CASE r->>'reason' WHEN 'TYPE_IT' THEN 'typed by hand' ELSE 'none left' END),
                CASE WHEN (r->>'existing_documents')::bigint = 1 THEN '1 GRN keeps its number.' ELSE (r->>'existing_documents') || ' GRNs keep their numbers.' END)
         || CASE WHEN r->'rule'->>'scheme' = 'free' THEN ''
                 WHEN r->'rule'->>'check' = 'false' THEN ' Numbers are not checked against the rule.'
                 WHEN (r->>'not_following')::bigint > 0 THEN format(' %s existing numbers do not follow the rule and keep their numbers.', r->>'not_following')
                 ELSE '' END AS numbering_message
    FROM (SELECT warehouse_security.apply_document_numbering('grn', :'grn_numbering'::jsonb, NULL) AS r) AS x \gset
  \if :numbering_changed
    \echo :numbering_message
  \endif
\endif
\if :{?dispatch_numbering}
  SELECT r->>'changed' = 'true' AS numbering_changed,
         format('Next dispatch: %s; %s', COALESCE(r->>'next_number', CASE r->>'reason' WHEN 'TYPE_IT' THEN 'typed by hand' ELSE 'none left' END),
                CASE WHEN (r->>'existing_documents')::bigint = 1 THEN '1 dispatch keeps its number.' ELSE (r->>'existing_documents') || ' dispatches keep their numbers.' END)
         || CASE WHEN r->'rule'->>'scheme' = 'free' THEN ''
                 WHEN r->'rule'->>'check' = 'false' THEN ' Numbers are not checked against the rule.'
                 WHEN (r->>'not_following')::bigint > 0 THEN format(' %s existing numbers do not follow the rule and keep their numbers.', r->>'not_following')
                 ELSE '' END AS numbering_message
    FROM (SELECT warehouse_security.apply_document_numbering('dispatch', :'dispatch_numbering'::jsonb, NULL) AS r) AS x \gset
  \if :numbering_changed
    \echo :numbering_message
  \endif
\endif
\if :{?invoice_numbering}
  SELECT r->>'changed' = 'true' AS numbering_changed,
         format('Next invoice: %s; %s', COALESCE(r->>'next_number', CASE r->>'reason' WHEN 'TYPE_IT' THEN 'typed by hand' ELSE 'none left' END),
                CASE WHEN (r->>'existing_documents')::bigint = 1 THEN '1 invoice keeps its number.' ELSE (r->>'existing_documents') || ' invoices keep their numbers.' END)
         || CASE WHEN r->'rule'->>'scheme' = 'free' THEN ''
                 WHEN r->'rule'->>'check' = 'false' THEN ' Numbers are not checked against the rule.'
                 WHEN (r->>'not_following')::bigint > 0 THEN format(' %s existing numbers do not follow the rule and keep their numbers.', r->>'not_following')
                 ELSE '' END AS numbering_message
    FROM (SELECT warehouse_security.apply_document_numbering('invoice', :'invoice_numbering'::jsonb, NULL) AS r) AS x \gset
  \if :numbering_changed
    \echo :numbering_message
  \endif
\endif
