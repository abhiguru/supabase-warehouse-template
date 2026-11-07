-- Migration 171: public.import_batch, the one call behind `bash scripts/import.sh` (WH-142, part 1: a CSV import of customers, items and rates for a
-- new facility). Operator tool only: granted to service_role, refused for every app account.
--
-- What it does, in one transaction (the caller's), in the order customers, items, rates:
--  * Every write goes through the RPCs the app uses (create_customer, create_item, replace_item_rates), so every server rule, lock and audit
--    row applies. The call runs as the "import" actor: a service account profile named "Import" (role admin, is_service_account) that this
--    function makes on its first use and keeps switched off between runs. Audit rows and price history therefore read "Import".
--  * It looks at what the facility already holds before it writes:
--      customer: the server's name rule (case and spaces ignored). Same fields = skipped; any field different = a conflict.
--      item:     name + packaging word (WH-41), as create_item matches. Same description = skipped; different = a conflict.
--      rate:     item + customer (or the item's default) + price type + start day + the weight bands. The same bands = skipped. A different rate
--                at that start day, or rates already held by that item and customer at another start day, = a conflict: the import only adds
--                rates to an item and customer that have none (an item the same run just made has only the standard rate it was given, which
--                the import's own default rate replaces). Nothing existing is ever updated.
--    A rate whose item or customer is itself a conflict is a conflict too (the file does not agree with the facility about who they are).
--  * A problem is {kind: error | conflict, file, line, column, reason}. The line numbers are the ones the caller sent.
--  * p_apply false = a dry run: everything above really runs (so the answer is exactly what an apply would meet) and is then rolled back.
--    p_apply true writes only when there is no error; with one it rolls everything back. Conflicts never stop an apply. Either way the
--    function returns a report and leaves no partial import.
-- Payload (p_payload jsonb): {"labels": {"customers": {field: column label}, "items": {...}, "rates": {...}},
--   "customers": [{"line", "name", "mobile", "email", "address", "city", "state", "pincode", "gst", "pan", "contact_person", "contact_mobile",
--                  "contact_email"}],
--   "items": [{"line", "name", "packaging", "description"}],
--   "rates": [{"line", "item_name", "packaging", "customer", "price_type": monthly|one_time, "start_on": "YYYY-MM-DD", "weight_min", "weight_max",
--              "rent", "labour", "tax"}]}  (empty text = null; the caller has already checked formats)
-- Report: {"success", "applied", "dry_run", "files": {name: {read, add, skip, conflicts, errors}}, "problems": [...], "rows": [{file, line, result}]}.

CREATE OR REPLACE FUNCTION public.import_batch(p_payload jsonb, p_apply boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
    AS $$
DECLARE
  c_sub constant uuid := '00000000-0000-4000-8000-696d706f7274';
  v_prev_claims text := current_setting('request.jwt.claims', true);
  v_prev_sub text := current_setting('request.jwt.claim.sub', true);
  v_prev_role text := current_setting('request.jwt.claim.role', true);
  v_labels jsonb := COALESCE(p_payload->'labels', '{}'::jsonb);
  v_problems jsonb := '[]'::jsonb;
  v_rows jsonb := '[]'::jsonb;
  v_files jsonb := jsonb_build_object(
    'customers', jsonb_build_object('read', 0, 'add', 0, 'skip', 0, 'conflicts', 0, 'errors', 0),
    'items',     jsonb_build_object('read', 0, 'add', 0, 'skip', 0, 'conflicts', 0, 'errors', 0),
    'rates',     jsonb_build_object('read', 0, 'add', 0, 'skip', 0, 'conflicts', 0, 'errors', 0));
  v_errors integer := 0;
  v_rec record;
  v_g record;
  v_cust public.customers;
  v_item public.items;
  v_res jsonb;
  v_diff text[];
  v_name text; v_word text; v_desc text;
  v_conflict_customers text[] := ARRAY[]::text[];
  v_conflict_items text[] := ARRAY[]::text[];
  v_new_items uuid[] := ARRAY[]::uuid[];
  v_touched text[] := ARRAY[]::text[];
  v_scope text;
  v_item_id uuid; v_cust_id uuid;
  v_existing jsonb; v_wanted jsonb;
  v_scope_rows integer; v_at_start integer;
  v_idx integer; v_line integer; v_column text; v_code text;
  v_n integer;
  v_profile uuid;
  v_applied boolean := false;
  v_state text;
BEGIN
  PERFORM warehouse_security.authorize_rpc('import_batch', jsonb_build_object());
  -- The operator command only: authorize_rpc lets administrators in, so the call must carry the service role (scripts/import.sh sets it).
  IF auth.jwt()->>'role' IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'The import runs from the operator command only' USING ERRCODE = '42501';
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'The import payload must be a JSON object' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('import_batch', 0));

  BEGIN  -- the work: rolled back as a whole when this block raises 'import_rollback'
    -- The import actor.
    SELECT id INTO v_profile FROM public.user_profiles WHERE auth_user_id = c_sub;
    IF v_profile IS NULL THEN
      INSERT INTO public.user_profiles (auth_user_id, name, display_name, role, active, mobile, mobile_verified, enrollment_status, is_service_account)
      VALUES (c_sub, 'Import', 'Import', 'admin', true, '0000000171', false, 'approved', true);
    ELSE
      UPDATE public.user_profiles SET active = true, role = 'admin', enrollment_status = 'approved', is_service_account = true, deleted_at = NULL
       WHERE id = v_profile;
    END IF;
    PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'service_role', 'sub', c_sub)::text, true);
    PERFORM set_config('request.jwt.claim.sub', c_sub::text, true);
    PERFORM set_config('request.jwt.claim.role', 'service_role', true);

    -- 1. Customers.
    FOR v_rec IN SELECT * FROM jsonb_to_recordset(COALESCE(p_payload->'customers', '[]'::jsonb))
        AS r(line integer, name text, mobile text, email text, address text, city text, state text, pincode text, gst text, pan text,
             contact_person text, contact_mobile text, contact_email text) ORDER BY line LOOP
      v_files := jsonb_set(v_files, '{customers,read}', to_jsonb((v_files#>>'{customers,read}')::integer + 1));
      BEGIN
        SELECT c.* INTO v_cust FROM public.customers c WHERE utils.customer_name_key(c.name) = utils.customer_name_key(v_rec.name) ORDER BY c.id LIMIT 1;
        IF FOUND THEN
          v_diff := ARRAY[]::text[];
          IF right(regexp_replace(COALESCE(v_cust.mobile, ''), '\D', '', 'g'), 10) IS DISTINCT FROM right(regexp_replace(COALESCE(v_rec.mobile, ''), '\D', '', 'g'), 10) THEN v_diff := v_diff || 'mobile'; END IF;
          IF COALESCE(v_cust.email, '') <> COALESCE(v_rec.email, '') THEN v_diff := v_diff || 'email'; END IF;
          IF COALESCE(v_cust.address, '') <> COALESCE(v_rec.address, '') THEN v_diff := v_diff || 'address'; END IF;
          IF COALESCE(v_cust.city, '') <> COALESCE(v_rec.city, '') THEN v_diff := v_diff || 'city'; END IF;
          IF COALESCE(v_cust.state, '') <> COALESCE(v_rec.state, '') THEN v_diff := v_diff || 'state'; END IF;
          IF COALESCE(v_cust.pincode, '') <> COALESCE(v_rec.pincode, '') THEN v_diff := v_diff || 'pincode'; END IF;
          IF upper(COALESCE(v_cust.gst, '')) <> upper(COALESCE(v_rec.gst, '')) THEN v_diff := v_diff || 'gst'; END IF;
          IF upper(COALESCE(v_cust.pan, '')) <> upper(COALESCE(v_rec.pan, '')) THEN v_diff := v_diff || 'pan'; END IF;
          IF COALESCE(v_cust.contact_person, '') <> COALESCE(v_rec.contact_person, '') THEN v_diff := v_diff || 'contact_person'; END IF;
          IF right(regexp_replace(COALESCE(v_cust.contact_mobile, ''), '\D', '', 'g'), 10) IS DISTINCT FROM right(regexp_replace(COALESCE(v_rec.contact_mobile, ''), '\D', '', 'g'), 10) THEN v_diff := v_diff || 'contact_mobile'; END IF;
          IF COALESCE(v_cust.contact_email, '') <> COALESCE(v_rec.contact_email, '') THEN v_diff := v_diff || 'contact_email'; END IF;
          IF cardinality(v_diff) = 0 THEN
            v_files := jsonb_set(v_files, '{customers,skip}', to_jsonb((v_files#>>'{customers,skip}')::integer + 1));
            v_rows := v_rows || jsonb_build_array(jsonb_build_object('file', 'customers', 'line', v_rec.line, 'result', 'skip'));
          ELSE
            v_conflict_customers := v_conflict_customers || utils.customer_name_key(v_rec.name);
            v_files := jsonb_set(v_files, '{customers,conflicts}', to_jsonb((v_files#>>'{customers,conflicts}')::integer + 1));
            v_rows := v_rows || jsonb_build_array(jsonb_build_object('file', 'customers', 'line', v_rec.line, 'result', 'conflict'));
            FOREACH v_column IN ARRAY v_diff LOOP
              v_problems := v_problems || jsonb_build_array(jsonb_build_object('kind', 'conflict', 'file', 'customers', 'line', v_rec.line,
                'column', COALESCE(v_labels#>>(('{customers,' || v_column || '}')::text[]), v_column),
                'reason', format('the customer "%s" already exists with different details; nothing was changed', v_cust.name)));
            END LOOP;
          END IF;
        ELSE
          v_res := public.create_customer(v_rec.name, v_rec.mobile, v_rec.email, v_rec.address, v_rec.city, v_rec.state, v_rec.pincode,
                                          v_rec.gst, v_rec.pan, v_rec.contact_person, v_rec.contact_mobile, v_rec.contact_email);
          IF COALESCE((v_res->>'success')::boolean, false) THEN
            v_files := jsonb_set(v_files, '{customers,add}', to_jsonb((v_files#>>'{customers,add}')::integer + 1));
            v_rows := v_rows || jsonb_build_array(jsonb_build_object('file', 'customers', 'line', v_rec.line, 'result', 'add'));
          ELSE
            v_errors := v_errors + 1;
            v_files := jsonb_set(v_files, '{customers,errors}', to_jsonb((v_files#>>'{customers,errors}')::integer + 1));
            v_column := CASE v_res#>>'{error,code}' WHEN 'DUPLICATE_MOBILE' THEN 'mobile' WHEN 'DUPLICATE_NAME' THEN 'name'
                          ELSE v_res#>>'{error,field}' END;
            v_problems := v_problems || jsonb_build_array(jsonb_build_object('kind', 'error', 'file', 'customers', 'line', v_rec.line,
              'column', COALESCE(v_labels#>>(('{customers,' || v_column || '}')::text[]), v_column),
              'reason', COALESCE(v_res->>'message', 'the customer could not be saved')));
          END IF;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_errors := v_errors + 1;
        v_files := jsonb_set(v_files, '{customers,errors}', to_jsonb((v_files#>>'{customers,errors}')::integer + 1));
        v_problems := v_problems || jsonb_build_array(jsonb_build_object('kind', 'error', 'file', 'customers', 'line', v_rec.line, 'column', NULL,
          'reason', 'the database refused this row: ' || SQLERRM));
      END;
    END LOOP;

    -- 2. Items.
    FOR v_rec IN SELECT * FROM jsonb_to_recordset(COALESCE(p_payload->'items', '[]'::jsonb))
        AS r(line integer, name text, packaging text, description text) ORDER BY line LOOP
      v_files := jsonb_set(v_files, '{items,read}', to_jsonb((v_files#>>'{items,read}')::integer + 1));
      BEGIN
        v_name := btrim(v_rec.name);
        v_word := warehouse_security.clean_packaging(v_rec.packaging);
        v_desc := NULLIF(btrim(COALESCE(v_rec.description, '')), '');
        SELECT i.* INTO v_item FROM public.items i
         WHERE lower(btrim(i.name)) = lower(v_name) AND warehouse_security.packaging_key(i.packaging) = warehouse_security.packaging_key(v_word)
         ORDER BY i.id LIMIT 1;
        IF FOUND THEN
          IF COALESCE(btrim(v_item.description), '') = COALESCE(v_desc, '') THEN
            v_files := jsonb_set(v_files, '{items,skip}', to_jsonb((v_files#>>'{items,skip}')::integer + 1));
            v_rows := v_rows || jsonb_build_array(jsonb_build_object('file', 'items', 'line', v_rec.line, 'result', 'skip'));
          ELSE
            v_conflict_items := v_conflict_items || (lower(v_name) || '|' || warehouse_security.packaging_key(v_word));
            v_files := jsonb_set(v_files, '{items,conflicts}', to_jsonb((v_files#>>'{items,conflicts}')::integer + 1));
            v_rows := v_rows || jsonb_build_array(jsonb_build_object('file', 'items', 'line', v_rec.line, 'result', 'conflict'));
            v_problems := v_problems || jsonb_build_array(jsonb_build_object('kind', 'conflict', 'file', 'items', 'line', v_rec.line,
              'column', COALESCE(v_labels#>>'{items,description}', 'description'),
              'reason', format('the item "%s" (%s) already exists with a different description; nothing was changed', v_item.name, COALESCE(v_item.packaging, 'Bag'))));
          END IF;
        ELSE
          v_res := public.create_item(v_name, v_word, v_desc, true, NULL);
          IF COALESCE((v_res->>'success')::boolean, false) THEN
            v_new_items := v_new_items || (v_res#>>'{data,id}')::uuid;
            v_files := jsonb_set(v_files, '{items,add}', to_jsonb((v_files#>>'{items,add}')::integer + 1));
            v_rows := v_rows || jsonb_build_array(jsonb_build_object('file', 'items', 'line', v_rec.line, 'result', 'add'));
          ELSE
            v_errors := v_errors + 1;
            v_files := jsonb_set(v_files, '{items,errors}', to_jsonb((v_files#>>'{items,errors}')::integer + 1));
            v_problems := v_problems || jsonb_build_array(jsonb_build_object('kind', 'error', 'file', 'items', 'line', v_rec.line,
              'column', CASE WHEN v_res->>'message' ILIKE '%packaging%' THEN v_labels#>>'{items,packaging}' ELSE v_labels#>>'{items,name}' END,
              'reason', COALESCE(v_res->>'message', 'the item could not be saved')));
          END IF;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_errors := v_errors + 1;
        v_files := jsonb_set(v_files, '{items,errors}', to_jsonb((v_files#>>'{items,errors}')::integer + 1));
        v_problems := v_problems || jsonb_build_array(jsonb_build_object('kind', 'error', 'file', 'items', 'line', v_rec.line, 'column', NULL,
          'reason', 'the database refused this row: ' || SQLERRM));
      END;
    END LOOP;

    -- 3. Rates: one group per item, customer (empty = the item's default), price type and start day; its rows are the weight bands.
    FOR v_g IN
      SELECT min(r.item_name) AS item_name, min(r.packaging) AS packaging, min(r.customer) AS customer, r.price_type, r.start_on,
             lower(btrim(r.item_name)) AS item_key, warehouse_security.packaging_key(r.packaging) AS word_key,
             CASE WHEN btrim(COALESCE(r.customer, '')) = '' THEN NULL ELSE utils.customer_name_key(r.customer) END AS customer_key,
             min(r.line) AS first_line, count(*) AS n_rows,
             jsonb_agg(jsonb_build_object('weight_min', r.weight_min, 'weight_max', r.weight_max, 'unit_price', r.rent, 'labour_rate', r.labour,
                                          'tax_percent', r.tax) ORDER BY r.weight_min, r.line) AS bands,
             array_agg(r.line ORDER BY r.weight_min, r.line) AS band_lines
        FROM jsonb_to_recordset(COALESCE(p_payload->'rates', '[]'::jsonb))
          AS r(line integer, item_name text, packaging text, customer text, price_type text, start_on date,
               weight_min numeric, weight_max numeric, rent numeric, labour numeric, tax numeric)
       GROUP BY lower(btrim(r.item_name)), warehouse_security.packaging_key(r.packaging),
                CASE WHEN btrim(COALESCE(r.customer, '')) = '' THEN NULL ELSE utils.customer_name_key(r.customer) END, r.price_type, r.start_on
       ORDER BY r.start_on, min(r.line)
    LOOP
      v_files := jsonb_set(v_files, '{rates,read}', to_jsonb((v_files#>>'{rates,read}')::integer + v_g.n_rows::integer));
      BEGIN
        v_item_id := NULL; v_cust_id := NULL;
        SELECT i.id INTO v_item_id FROM public.items i
         WHERE lower(btrim(i.name)) = v_g.item_key AND warehouse_security.packaging_key(i.packaging) = v_g.word_key ORDER BY i.id LIMIT 1;
        IF v_item_id IS NULL THEN
          v_errors := v_errors + 1;
          v_files := jsonb_set(v_files, '{rates,errors}', to_jsonb((v_files#>>'{rates,errors}')::integer + v_g.n_rows::integer));
          v_problems := v_problems || jsonb_build_array(jsonb_build_object('kind', 'error', 'file', 'rates', 'line', v_g.first_line,
            'column', v_labels#>>'{rates,item_name}',
            'reason', format('no item "%s" with the packaging "%s" (add it in the items file, or in the app, first)', btrim(v_g.item_name), COALESCE(NULLIF(btrim(v_g.packaging), ''), 'Bag'))));
          CONTINUE;
        END IF;
        IF v_g.customer_key IS NOT NULL THEN
          SELECT c.id INTO v_cust_id FROM public.customers c WHERE utils.customer_name_key(c.name) = v_g.customer_key AND c.deleted_at IS NULL ORDER BY c.id LIMIT 1;
          IF v_cust_id IS NULL THEN
            v_errors := v_errors + 1;
            v_files := jsonb_set(v_files, '{rates,errors}', to_jsonb((v_files#>>'{rates,errors}')::integer + v_g.n_rows::integer));
            v_problems := v_problems || jsonb_build_array(jsonb_build_object('kind', 'error', 'file', 'rates', 'line', v_g.first_line,
              'column', v_labels#>>'{rates,customer}',
              'reason', format('no customer named "%s" (add it in the customers file, or in the app, first)', btrim(v_g.customer))));
            CONTINUE;
          END IF;
        END IF;
        IF (v_g.item_key || '|' || v_g.word_key) = ANY (v_conflict_items) OR v_g.customer_key = ANY (v_conflict_customers) THEN
          v_files := jsonb_set(v_files, '{rates,conflicts}', to_jsonb((v_files#>>'{rates,conflicts}')::integer + v_g.n_rows::integer));
          v_rows := v_rows || (SELECT jsonb_agg(jsonb_build_object('file', 'rates', 'line', l, 'result', 'conflict')) FROM unnest(v_g.band_lines) l);
          v_problems := v_problems || jsonb_build_array(jsonb_build_object('kind', 'conflict', 'file', 'rates', 'line', v_g.first_line,
            'column', CASE WHEN v_g.customer_key = ANY (v_conflict_customers) THEN v_labels#>>'{rates,customer}' ELSE v_labels#>>'{rates,item_name}' END,
            'reason', 'skipped: the file disagrees with the facility about this item or customer (see the conflict above); nothing was changed'));
          CONTINUE;
        END IF;

        v_scope := v_item_id::text || ':' || COALESCE(v_cust_id::text, 'default') || ':' || v_g.price_type;
        SELECT count(*), count(*) FILTER (WHERE r.effective_from = v_g.start_on) INTO v_scope_rows, v_at_start
          FROM public.item_storage_prices r
         WHERE r.item_id = v_item_id AND r.customer_id IS NOT DISTINCT FROM v_cust_id AND r.price_type = v_g.price_type;

        IF v_at_start > 0 THEN
          -- A rate starts that day already: the same bands = skip, anything else = conflict.
          SELECT jsonb_agg(jsonb_build_object('a', r.weight_min, 'b', r.weight_max, 'c', r.unit_price,
                                              'd', CASE WHEN v_g.price_type = 'one_time' THEN 0 ELSE r.labour_rate END, 'e', r.tax_percent)
                           ORDER BY r.weight_min) INTO v_existing
            FROM public.item_storage_prices r
           WHERE r.item_id = v_item_id AND r.customer_id IS NOT DISTINCT FROM v_cust_id AND r.price_type = v_g.price_type AND r.effective_from = v_g.start_on;
          SELECT jsonb_agg(jsonb_build_object('a', (b->>'weight_min')::numeric, 'b', (b->>'weight_max')::numeric, 'c', (b->>'unit_price')::numeric,
                                              'd', CASE WHEN v_g.price_type = 'one_time' THEN 0 ELSE (b->>'labour_rate')::numeric END,
                                              'e', (b->>'tax_percent')::numeric)
                           ORDER BY (b->>'weight_min')::numeric) INTO v_wanted
            FROM jsonb_array_elements(v_g.bands) b;
          IF v_existing = v_wanted THEN
            v_files := jsonb_set(v_files, '{rates,skip}', to_jsonb((v_files#>>'{rates,skip}')::integer + v_g.n_rows::integer));
            v_rows := v_rows || (SELECT jsonb_agg(jsonb_build_object('file', 'rates', 'line', l, 'result', 'skip')) FROM unnest(v_g.band_lines) l);
          ELSE
            v_files := jsonb_set(v_files, '{rates,conflicts}', to_jsonb((v_files#>>'{rates,conflicts}')::integer + v_g.n_rows::integer));
            v_rows := v_rows || (SELECT jsonb_agg(jsonb_build_object('file', 'rates', 'line', l, 'result', 'conflict')) FROM unnest(v_g.band_lines) l);
            v_problems := v_problems || jsonb_build_array(jsonb_build_object('kind', 'conflict', 'file', 'rates', 'line', v_g.first_line,
              'column', v_labels#>>'{rates,start_on}',
              'reason', 'the facility already has a different rate for this item and customer starting that day; nothing was changed'));
          END IF;
          CONTINUE;
        END IF;

        IF v_scope_rows > 0 AND NOT (v_scope = ANY (v_touched)) AND NOT (v_cust_id IS NULL AND v_item_id = ANY (v_new_items)) THEN
          v_files := jsonb_set(v_files, '{rates,conflicts}', to_jsonb((v_files#>>'{rates,conflicts}')::integer + v_g.n_rows::integer));
          v_rows := v_rows || (SELECT jsonb_agg(jsonb_build_object('file', 'rates', 'line', l, 'result', 'conflict')) FROM unnest(v_g.band_lines) l);
          v_problems := v_problems || jsonb_build_array(jsonb_build_object('kind', 'conflict', 'file', 'rates', 'line', v_g.first_line,
            'column', v_labels#>>'{rates,start_on}',
            'reason', 'the facility already has rates for this item and customer; the import only adds rates where there are none, so nothing was changed'));
          CONTINUE;
        END IF;

        -- p_replace_later: only for the standard rate a new item of this run was given (the run's own record).
        v_res := public.replace_item_rates(v_item_id, v_cust_id, v_g.price_type, v_g.start_on, v_g.bands,
                                           (v_cust_id IS NULL AND v_item_id = ANY (v_new_items) AND NOT (v_scope = ANY (v_touched))), 'change');
        IF COALESCE((v_res->>'success')::boolean, false) THEN
          v_touched := v_touched || v_scope;
          v_files := jsonb_set(v_files, '{rates,add}', to_jsonb((v_files#>>'{rates,add}')::integer + v_g.n_rows::integer));
          v_rows := v_rows || (SELECT jsonb_agg(jsonb_build_object('file', 'rates', 'line', l, 'result', 'add')) FROM unnest(v_g.band_lines) l);
        ELSE
          v_errors := v_errors + 1;
          v_files := jsonb_set(v_files, '{rates,errors}', to_jsonb((v_files#>>'{rates,errors}')::integer + v_g.n_rows::integer));
          v_code := v_res->>'error_code';
          v_idx := NULLIF(v_res#>>'{data,index}', '')::integer;
          v_line := CASE WHEN v_idx IS NOT NULL AND v_idx BETWEEN 0 AND cardinality(v_g.band_lines) - 1 THEN v_g.band_lines[v_idx + 1] ELSE v_g.first_line END;
          v_column := CASE
            WHEN v_res#>>'{data,field}' = 'weight_min' THEN v_labels#>>'{rates,weight_min}'
            WHEN v_res#>>'{data,field}' = 'weight_max' THEN v_labels#>>'{rates,weight_max}'
            WHEN v_res#>>'{data,field}' = 'unit_price' THEN v_labels#>>'{rates,rent}'
            WHEN v_res#>>'{data,field}' = 'labour_rate' THEN v_labels#>>'{rates,labour}'
            WHEN v_res#>>'{data,field}' = 'tax_percent' THEN v_labels#>>'{rates,tax}'
            WHEN v_code = 'INVALID_DATE' THEN v_labels#>>'{rates,start_on}'
            WHEN v_code = 'BANDS_OVERLAP' THEN v_labels#>>'{rates,weight_max}'
            WHEN v_code = 'BANDS_GAP' THEN v_labels#>>'{rates,weight_min}'
            WHEN v_code = 'INVALID_PRICE_TYPE' THEN v_labels#>>'{rates,price_type}'
            WHEN v_code = 'ITEM_NOT_FOUND' THEN v_labels#>>'{rates,item_name}'
            WHEN v_code = 'CUSTOMER_NOT_FOUND' THEN v_labels#>>'{rates,customer}'
            ELSE NULL END;
          v_problems := v_problems || jsonb_build_array(jsonb_build_object('kind', 'error', 'file', 'rates', 'line', v_line, 'column', v_column,
            'reason', COALESCE(v_res->>'error', v_res->>'message', 'the rate could not be saved')));
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_errors := v_errors + 1;
        v_files := jsonb_set(v_files, '{rates,errors}', to_jsonb((v_files#>>'{rates,errors}')::integer + v_g.n_rows::integer));
        v_problems := v_problems || jsonb_build_array(jsonb_build_object('kind', 'error', 'file', 'rates', 'line', v_g.first_line, 'column', NULL,
          'reason', 'the database refused this rate: ' || SQLERRM));
      END;
    END LOOP;

    -- Leave the actor switched off (a kept service account never opens a session), then decide.
    UPDATE public.user_profiles SET active = false WHERE auth_user_id = c_sub;
    IF p_apply AND v_errors = 0 THEN
      v_applied := true;
    ELSE
      RAISE EXCEPTION 'import_rollback' USING ERRCODE = 'P0001';
    END IF;
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    GET STACKED DIAGNOSTICS v_state = MESSAGE_TEXT;
    IF v_state IS DISTINCT FROM 'import_rollback' THEN RAISE; END IF;
    v_applied := false;
  END;

  -- The caller's own claims again (they were set for this transaction only).
  PERFORM set_config('request.jwt.claims', COALESCE(v_prev_claims, ''), true);
  PERFORM set_config('request.jwt.claim.sub', COALESCE(v_prev_sub, ''), true);
  PERFORM set_config('request.jwt.claim.role', COALESCE(v_prev_role, ''), true);

  RETURN jsonb_build_object('success', v_errors = 0, 'applied', v_applied, 'dry_run', NOT COALESCE(p_apply, false),
    'files', v_files, 'problems', v_problems, 'rows', v_rows);
END;
$$;

ALTER FUNCTION public.import_batch(jsonb, boolean) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION public.import_batch(jsonb, boolean) FROM PUBLIC, anon, authenticated;
GRANT ALL ON FUNCTION public.import_batch(jsonb, boolean) TO service_role;

-- Service accounts (user_profiles.is_service_account), among them the "Import" actor, are not listed in Settings -> Users (product decision of
-- 2026-11-07). get_users_list leaves them out of the page and of the counts. The text is patched with a marker count, as earlier migrations do.
DO $patch$
DECLARE
  v_def text;
  v_old constant text := $m$AND (v_caller_role = 'admin' OR up.role != 'admin')$m$;
  v_count integer;
BEGIN
  v_def := pg_get_functiondef('public.get_users_list(text, public.user_role[], boolean, integer, integer)'::regprocedure);
  v_count := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'get_users_list: expected the marker twice, found % times', v_count;
  END IF;
  EXECUTE replace(v_def, v_old, v_old || ' AND NOT up.is_service_account');
END
$patch$;
