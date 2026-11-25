-- WH-297 (the server change log and its feed): the names the tests take from the feed, the shared setup and a phone stand-in.
-- tests/migrations.sh pipes this file in front of tests/sync_feed_changes.sql and tests/sync_feed_deletes_scope.sql, and
-- tests/sync_feed_concurrency.sh in front of each of its sessions, all in a database of their own: the feed delivers only
-- committed transactions, so these suites commit instead of rolling back. Fictional data only.
--
-- The phone stand-in (pg_temp.sf_*) does what the contract tells a phone to do and nothing more: first load (get_sync_start,
-- then get_sync_page per entity), then get_sync_changes from the stored position until "more" is false, applying upserts,
-- deletes with the contract's cascade, "reload" (entities reloaded in full) and "reload_all" (copy erased and loaded again).
-- Its oracle is a fresh first load of the same caller (contract 13, 1a) and, for the table entities, a direct read of the
-- table as the same caller (contract 13, 12a), so a feed that drops a change leaves the stand-in different from both.
\set ON_ERROR_STOP on

-- =================================================================================================================================
-- AGREE WITH DEVELOPMENT (WH-297). Every name of the feed the tests use is in this block and nowhere else (suites and the shell
-- script read them through pg_temp.sf(key)). Source: ~/ws/fresh/product/tech/server-change-log-feed.md (Development, 2026-11-25),
-- section numbers in brackets. Its questions Q1-Q6 were answered by Product on the WH-297 card as Development proposed (Q1 columns,
-- Q3 120 days are used here). Q4 as Product decided it later on the card: staff roles receive a soft-deleted row (customers,
-- dispatch, goodsreceived, invoice: the four tables with deleted_at) as an upsert with deleted_at set; a customer account as a delete.
-- =================================================================================================================================
CREATE TEMP TABLE sf_contract(k text PRIMARY KEY, v text NOT NULL);
INSERT INTO pg_temp.sf_contract(k, v) VALUES
  -- The four RPCs [3]; filled with format(): %L for text, %s for the limit.
  ('call_start',     'public.get_sync_start()'),
  ('call_page',      'public.get_sync_page(p_entity => %L, p_after => %L, p_limit => %s)'),
  ('call_changes',   'public.get_sync_changes(p_position => %L, p_copy => %L, p_limit => %s)'),
  ('call_checksums', 'public.get_sync_checksums(p_position => %L, p_copy => %L, p_entities => NULL)'),
  ('page_limit',     '2000'),                                         -- [6] rows per answer, also the clamp of p_limit
  -- Answer fields [3.1-3.4].
  ('f_success', 'success'), ('f_format', 'format'), ('f_copy', 'copy'), ('f_position', 'position'), ('f_as_of', 'as_of'),
  ('f_page_limit', 'page_limit'), ('f_entities', 'entities'), ('f_rows', 'rows'), ('f_next_after', 'next_after'),
  ('f_more', 'more'), ('f_reload_all', 'reload_all'), ('f_reason', 'reason'), ('f_reload', 'reload'), ('f_changes', 'changes'),
  ('f_e', 'e'), ('f_id', 'id'), ('f_op', 'op'), ('f_row', 'row'), ('f_v', 'v'),
  ('f_count', 'count'), ('f_sum', 'sum'), ('f_settled', 'settled'), ('f_refusal', 'reason'),
  -- Operations [3.3].
  ('op_upsert', 'upsert'), ('op_delete', 'delete'), ('op_stale', 'stale'),
  -- Entities [4]: the table entities are named after their tables; the derived ones have no table.
  ('table_entities', 'customers,items,goodsreceived,goodsreceived_trl,grn_images,dispatch,dispatch_trl,dispatch_images,invoice,invoice_trl,user_profiles,users_customers_new'),
  ('e_people', 'people'), ('e_grn_lock', 'grn_lock'), ('e_settings', 'settings'), ('e_money', 'money'),
  ('settings_charging_rule', 'charging_rule'),
  -- Delete cascade on the phone [3.3]: parent entity -> child entity -> the child row field holding the parent id ('id' = same id).
  ('cascade', '{"goodsreceived": {"goodsreceived_trl": "gr_id", "grn_images": "grn_id", "grn_lock": "id"},
                "dispatch": {"dispatch_trl": "disp_id", "dispatch_images": "dispatch_id"},
                "invoice": {"invoice_trl": "invoice_id"}}'),
  -- grn_lock row [4]: get_grn_edit_state's lines[] with id and dispatched_qty.
  ('lock_lines', 'lines'), ('lock_line_id', 'id'), ('lock_dispatched', 'dispatched_qty'),
  -- reload_all reasons [3.3] and refusals [10].
  ('r_access', 'ACCESS_CHANGED'), ('r_bulk', 'BULK_IMPORT'), ('r_restored', 'RESTORED'), ('r_format', 'FORMAT_CHANGED'),
  ('r_purged', 'LOG_PURGED'), ('r_ahead', 'POSITION_AHEAD'),
  ('err_position', 'SYNC_BAD_POSITION'), ('err_copy', 'SYNC_BAD_COPY'), ('err_entity', 'SYNC_UNKNOWN_ENTITY'),
  -- Server internals the tests drive as supabase_admin [1, 8, 9].
  ('rotate_log', 'SELECT warehouse_sync.rotate_log(%L)'),
  ('bump_format', 'UPDATE warehouse_sync.state SET format = format + 1'),
  ('retention_key', 'sync_change_log'),                               -- [8]
  ('retention_days', '120'),                                          -- [8], Q3
  ('floor_query', 'SELECT floor::text FROM warehouse_sync.state'),    -- [1, 8]
  ('feed_trigger', 'zz_change_feed'),
  ('logged_tables', 'public.goodsreceived,public.goodsreceived_trl,public.grn_images,public.dispatch,public.dispatch_trl,public.dispatch_images,public.invoice,public.invoice_trl,public.payments,public.customers,public.items,public.user_profiles,public.users_customers_new,public.order_items,public.orders,public.grn_rates,warehouse_security.imported_documents,warehouse_security.rack_presets,warehouse_security.document_numbering,warehouse_security.charging_rule'),
  -- Q1 [4, 14]: the columns a customer account never receives.
  ('soft_delete_tables', 'customers,dispatch,goodsreceived,invoice'),  -- Q4: the tables with deleted_at
  ('soft_delete_column', 'deleted_at'),
  ('q1_customer_hidden_columns', 'created_by,updated_by,deleted_by,supervisor_id,sender_id,import_batch_id,uploaded_by');
-- ================================================= END OF THE AGREED NAMES ======================================================

CREATE FUNCTION pg_temp.sf(key text) RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE r text;
BEGIN
  SELECT c.v INTO r FROM pg_temp.sf_contract c WHERE c.k = key;
  IF r IS NULL THEN RAISE EXCEPTION 'sync feed contract: no name %', key; END IF;
  RETURN r;
END $$;
CREATE FUNCTION pg_temp.sf_list(key text) RETURNS text[] LANGUAGE sql STABLE AS $$ SELECT string_to_array(pg_temp.sf(key), ',') $$;
CREATE FUNCTION pg_temp.sf_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'sync feed: %', label; END IF; END $$;

-- One statement as a signed-in caller (role authenticated, these claims); the role and claims end with the call.
CREATE FUNCTION pg_temp.sf_as(claims jsonb, stmt text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', claims::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE stmt INTO r;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN r;
END $$;
-- The same, as any role and caught: {"answer": ...} or {"sqlstate": ..., "message": ...}.
CREATE FUNCTION pg_temp.sf_try(who text, claims jsonb, stmt text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb; st text; msg text;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', COALESCE(claims::text, ''), true);
    EXECUTE format('SET LOCAL ROLE %I', who);
    EXECUTE stmt INTO r;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN jsonb_build_object('answer', r);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS st = RETURNED_SQLSTATE, msg = MESSAGE_TEXT;
    RETURN jsonb_build_object('sqlstate', st, 'message', msg);
  END;
END $$;

-- Claims of a signed-in session of this phone number: a live session is reused (the OTP limits), else one sign-in.
CREATE FUNCTION pg_temp.sf_login(phone text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c jsonb; l jsonb; claims jsonb;
BEGIN
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id) INTO claims
    FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) AND s.expires_at > now() + interval '30 minutes'
    ORDER BY s.created_at DESC LIMIT 1;
  IF claims IS NOT NULL THEN RETURN claims; END IF;
  c := public.operator_prepare_otp(phone);
  PERFORM pg_temp.sf_assert(c->>'success' = 'true', 'challenge prepared for ' || phone || ': ' || c);
  PERFORM public.operator_finish_otp((c#>>'{data,request_id}')::uuid, true, 'mock-provider-only');
  l := public.operator_verify_otp(phone, c#>>'{data,otp_code}');
  PERFORM pg_temp.sf_assert(l#>>'{data,action}' = 'login', 'login for ' || phone || ': ' || l);
  SELECT jsonb_build_object('role', 'authenticated', 'sub', p.auth_user_id, 'session_id', s.id) INTO claims
    FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id = p.auth_user_id
    WHERE p.mobile = warehouse_security.normalize_phone(phone) ORDER BY s.created_at DESC LIMIT 1;
  RETURN claims;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------------------
-- The phone stand-in. sf_device: one row per phone. sf_copy: the rows a phone (or a fresh comparison load, slot 'fresh:<phone>')
-- holds. sf_answer, sf_entry, sf_event: every answer, every change entry and every reload/stale the phone met, for the assertions.
-- ---------------------------------------------------------------------------------------------------------------------------------
CREATE TEMP TABLE sf_device(phone text PRIMARY KEY, claims jsonb NOT NULL, position text, copy text, entities text[], as_of text,
  pulls int NOT NULL DEFAULT 0);
CREATE TEMP TABLE sf_copy(slot text, e text, id text, v text, row jsonb, PRIMARY KEY (slot, e, id));
CREATE TEMP TABLE sf_answer(seq bigserial PRIMARY KEY, phone text, pull int, page int, kind text, answer jsonb);
CREATE TEMP TABLE sf_entry(seq bigserial PRIMARY KEY, phone text, pull int, page int, e text, id text, op text, entry jsonb);
CREATE TEMP TABLE sf_event(seq bigserial PRIMARY KEY, phone text, pull int, kind text, detail text);

CREATE FUNCTION pg_temp.sf_phone(phone text, claims jsonb) RETURNS void LANGUAGE sql AS $$
  INSERT INTO pg_temp.sf_device(phone, claims) VALUES (phone, claims)
  ON CONFLICT (phone) DO UPDATE SET claims = excluded.claims $$;

-- One RPC call of a phone; the answer is kept and must be a success.
CREATE FUNCTION pg_temp.sf_rpc(p text, kind text, stmt text, pull int DEFAULT NULL, page int DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE d record; ans jsonb;
BEGIN
  SELECT * INTO d FROM pg_temp.sf_device WHERE phone = p;
  PERFORM pg_temp.sf_assert(d.phone IS NOT NULL, 'no phone ' || p);
  ans := pg_temp.sf_as(d.claims, stmt);
  INSERT INTO pg_temp.sf_answer(phone, pull, page, kind, answer) VALUES (p, pull, page, kind, ans);
  PERFORM pg_temp.sf_assert(ans->>pg_temp.sf('f_success') = 'true', p || ' ' || kind || ' answered: ' || left(COALESCE(ans::text, 'NULL'), 400));
  RETURN ans;
END $$;

-- Loads one entity in full into a slot with get_sync_page (keyset, page_limit rows); the copy key must stay the same throughout.
CREATE FUNCTION pg_temp.sf_load(p text, slot text, ent text, copy_key text) RETURNS int LANGUAGE plpgsql AS $$
DECLARE after text; ans jsonb; page_rows jsonb; pages int := 0; total int := 0; lim int := pg_temp.sf('page_limit')::int;
BEGIN
  DELETE FROM pg_temp.sf_copy WHERE sf_copy.slot = sf_load.slot AND e = ent;
  LOOP
    pages := pages + 1;
    PERFORM pg_temp.sf_assert(pages <= 1000, 'more than 1000 pages of ' || ent);
    ans := pg_temp.sf_rpc(p, 'page', format(pg_temp.sf('call_page'), ent, after, lim));
    page_rows := COALESCE(ans->pg_temp.sf('f_rows'), '[]'::jsonb);
    PERFORM pg_temp.sf_assert(jsonb_array_length(page_rows) <= lim,
      format('criterion 13: a page of %s holds %s rows, above %s', ent, jsonb_array_length(page_rows), lim));
    PERFORM pg_temp.sf_assert(ans->>pg_temp.sf('f_copy') = copy_key, format('the copy key changed while %s loaded %s', p, ent));
    INSERT INTO pg_temp.sf_copy(slot, e, id, v, row)
      SELECT slot, ent, x->>pg_temp.sf('f_id'), x->>pg_temp.sf('f_v'), x->pg_temp.sf('f_row') FROM jsonb_array_elements(page_rows) x
      ON CONFLICT ON CONSTRAINT sf_copy_pkey DO UPDATE SET v = excluded.v, row = excluded.row;
    total := total + jsonb_array_length(page_rows);
    after := ans->>pg_temp.sf('f_next_after');
    EXIT WHEN after IS NULL;
  END LOOP;
  RETURN total;
END $$;

-- First load: the start fixes the position before page one; every entity the start lists is loaded. Slot = the phone itself
-- (the phone's copy is erased first and its position stored) or 'fresh:<phone>' (a comparison load; the phone is untouched).
CREATE FUNCTION pg_temp.sf_first_load(p text, fresh boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE ans jsonb; target text := CASE WHEN fresh THEN 'fresh:' || p ELSE p END; ent text;
BEGIN
  ans := pg_temp.sf_rpc(p, 'start', pg_temp.sf('call_start'));
  PERFORM pg_temp.sf_assert(ans->>pg_temp.sf('f_position') ~ '^[0-9]{1,20}$', 'the start position is a decimal string: ' || ans);
  PERFORM pg_temp.sf_assert(ans->>pg_temp.sf('f_copy') IS NOT NULL AND (ans->>pg_temp.sf('f_page_limit'))::int = pg_temp.sf('page_limit')::int,
    'the start gives a copy key and the page limit: ' || ans);
  DELETE FROM pg_temp.sf_copy c WHERE c.slot = target;
  IF NOT fresh THEN
    UPDATE pg_temp.sf_device SET position = ans->>pg_temp.sf('f_position'), copy = ans->>pg_temp.sf('f_copy'),
      as_of = ans->>pg_temp.sf('f_as_of'), entities = ARRAY(SELECT jsonb_array_elements_text(ans->pg_temp.sf('f_entities')))
      WHERE phone = p;
  END IF;
  FOR ent IN SELECT jsonb_array_elements_text(ans->pg_temp.sf('f_entities')) LOOP
    PERFORM pg_temp.sf_load(p, target, ent, ans->>pg_temp.sf('f_copy'));
  END LOOP;
  RETURN ans;
END $$;

-- Removes one row from a phone's copy, with the contract's cascade.
CREATE FUNCTION pg_temp.sf_remove(slot text, ent text, rid text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE child record;
BEGIN
  DELETE FROM pg_temp.sf_copy c WHERE c.slot = sf_remove.slot AND c.e = ent AND c.id = rid;
  FOR child IN SELECT key AS e, value AS field FROM jsonb_each_text(COALESCE(pg_temp.sf('cascade')::jsonb->ent, '{}'::jsonb)) LOOP
    DELETE FROM pg_temp.sf_copy c WHERE c.slot = sf_remove.slot AND c.e = child.e
      AND (CASE WHEN child.field = 'id' THEN c.id ELSE c.row->>child.field END) = rid;
  END LOOP;
END $$;

-- Pulls changes until "more" is false. Every page: at most page_limit entries, one entry per (entity, id), a decimal position.
-- Returns {"pages": n, "entries": n, "reload_all": [reasons], "reload": [entities]} for this pull.
CREATE FUNCTION pg_temp.sf_pull(p text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE d record; ans jsonb; changes jsonb; x jsonb; pull int; page int := 0; lim int := pg_temp.sf('page_limit')::int;
  op text; ent text; reasons jsonb := '[]'; reloads jsonb := '[]'; entries int := 0; restarts int := 0; dup text;
BEGIN
  UPDATE pg_temp.sf_device SET pulls = pulls + 1 WHERE phone = p RETURNING pulls INTO pull;
  PERFORM pg_temp.sf_assert(pull IS NOT NULL, 'no phone ' || p);
  LOOP
    page := page + 1;
    PERFORM pg_temp.sf_assert(page <= 500, p || ': more than 500 pages in one pull');
    SELECT * INTO d FROM pg_temp.sf_device WHERE phone = p;
    ans := pg_temp.sf_rpc(p, 'changes', format(pg_temp.sf('call_changes'), d.position, d.copy, lim), pull, page);
    changes := COALESCE(ans->pg_temp.sf('f_changes'), '[]'::jsonb);
    PERFORM pg_temp.sf_assert(jsonb_typeof(changes) = 'array', p || ': changes is not a list: ' || left(ans::text, 300));
    PERFORM pg_temp.sf_assert(jsonb_array_length(changes) <= lim,
      format('criterion 13: %s got a page of %s entries, above %s', p, jsonb_array_length(changes), lim));
    SELECT string_agg(k, ', ') INTO dup FROM (SELECT (c->>pg_temp.sf('f_e')) || ':' || (c->>pg_temp.sf('f_id')) AS k
      FROM jsonb_array_elements(changes) c GROUP BY 1 HAVING count(*) > 1) t;
    PERFORM pg_temp.sf_assert(dup IS NULL, p || ': one entry per entity and id per page, but repeated: ' || COALESCE(dup, ''));
    INSERT INTO pg_temp.sf_entry(phone, pull, page, e, id, op, entry)
      SELECT p, pull, page, c->>pg_temp.sf('f_e'), c->>pg_temp.sf('f_id'), c->>pg_temp.sf('f_op'), c FROM jsonb_array_elements(changes) c;
    entries := entries + jsonb_array_length(changes);

    IF jsonb_typeof(ans->pg_temp.sf('f_reload_all')) = 'object' THEN
      reasons := reasons || to_jsonb(ans#>>ARRAY[pg_temp.sf('f_reload_all'), pg_temp.sf('f_reason')]);
      INSERT INTO pg_temp.sf_event(phone, pull, kind, detail) VALUES (p, pull, 'reload_all', ans#>>ARRAY[pg_temp.sf('f_reload_all'), pg_temp.sf('f_reason')]);
      restarts := restarts + 1;
      PERFORM pg_temp.sf_assert(restarts <= 2, p || ': reload_all answered again right after a reload: ' || left(ans::text, 300));
      PERFORM pg_temp.sf_first_load(p);   -- the position of a reload_all answer is not stored; catch up from the new start
      CONTINUE;
    END IF;

    FOR x IN SELECT c FROM jsonb_array_elements(changes) c LOOP
      op := x->>pg_temp.sf('f_op'); ent := x->>pg_temp.sf('f_e');
      IF op = pg_temp.sf('op_upsert') THEN
        PERFORM pg_temp.sf_assert(jsonb_typeof(x->pg_temp.sf('f_row')) = 'object' AND x->>pg_temp.sf('f_v') ~ '^[0-9a-f]{16}$',
          p || ': an upsert carries its row and v: ' || left(x::text, 300));
        INSERT INTO pg_temp.sf_copy(slot, e, id, v, row) VALUES (p, ent, x->>pg_temp.sf('f_id'), x->>pg_temp.sf('f_v'), x->pg_temp.sf('f_row'))
          ON CONFLICT ON CONSTRAINT sf_copy_pkey DO UPDATE SET v = excluded.v, row = excluded.row;
      ELSIF op = pg_temp.sf('op_delete') THEN
        PERFORM pg_temp.sf_remove(p, ent, x->>pg_temp.sf('f_id'));
      ELSIF op = pg_temp.sf('op_stale') AND ent = pg_temp.sf('e_money') THEN
        INSERT INTO pg_temp.sf_event(phone, pull, kind, detail) VALUES (p, pull, 'stale', x->>pg_temp.sf('f_id'));
      ELSE
        RAISE EXCEPTION 'sync feed: % got an unknown entry %', p, x;
      END IF;
    END LOOP;
    FOR ent IN SELECT jsonb_array_elements_text(COALESCE(ans->pg_temp.sf('f_reload'), '[]'::jsonb)) LOOP
      reloads := reloads || to_jsonb(ent);
      INSERT INTO pg_temp.sf_event(phone, pull, kind, detail) VALUES (p, pull, 'reload', ent);
      PERFORM pg_temp.sf_load(p, p, ent, d.copy);
    END LOOP;

    PERFORM pg_temp.sf_assert(ans->>pg_temp.sf('f_position') ~ '^[0-9]{1,20}$', p || ': the position is a decimal string: ' || left(ans::text, 300));
    PERFORM pg_temp.sf_assert(NOT ((ans->>pg_temp.sf('f_more'))::boolean AND ans->>pg_temp.sf('f_position') = d.position),
      p || ': "more" without moving the position');
    UPDATE pg_temp.sf_device SET position = ans->>pg_temp.sf('f_position'), as_of = ans->>pg_temp.sf('f_as_of') WHERE phone = p;
    EXIT WHEN NOT COALESCE((ans->>pg_temp.sf('f_more'))::boolean, false);
  END LOOP;
  RETURN jsonb_build_object('pages', page, 'entries', entries, 'reload_all', reasons, 'reload', reloads);
END $$;

-- The difference between a phone's copy and a fresh first load of the same caller now, by entity, id and v; '' when equal.
CREATE FUNCTION pg_temp.sf_diff(p text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  PERFORM pg_temp.sf_first_load(p, true);
  SELECT string_agg(what, '; ') INTO r FROM (
    SELECT what FROM (
      SELECT 'missing ' || f.e || ' ' || f.id AS what FROM pg_temp.sf_copy f
        WHERE f.slot = 'fresh:' || p AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy c WHERE c.slot = p AND c.e = f.e AND c.id = f.id)
      UNION ALL
      SELECT 'extra ' || c.e || ' ' || c.id FROM pg_temp.sf_copy c
        WHERE c.slot = p AND NOT EXISTS (SELECT 1 FROM pg_temp.sf_copy f WHERE f.slot = 'fresh:' || p AND f.e = c.e AND f.id = c.id)
      UNION ALL
      SELECT 'stale ' || c.e || ' ' || c.id FROM pg_temp.sf_copy c JOIN pg_temp.sf_copy f ON f.slot = 'fresh:' || p AND f.e = c.e AND f.id = c.id
        WHERE c.slot = p AND f.v IS DISTINCT FROM c.v) t
    ORDER BY what LIMIT 12) s;
  DELETE FROM pg_temp.sf_copy WHERE slot = 'fresh:' || p;
  RETURN COALESCE(r, '');
END $$;

-- The columns of a public table that the authenticated role may read (invoice: its granted columns), sorted.
CREATE FUNCTION pg_temp.sf_columns(tbl text) RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT COALESCE(array_agg(column_name::text ORDER BY column_name::text), '{}') FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = tbl AND has_column_privilege('authenticated', format('public.%I', tbl), column_name, 'SELECT') $$;

-- Criterion 12a: for every table entity of the phone that the caller can read directly, the copy holds exactly the ids of a direct
-- read as the same caller, and every row carries exactly the readable columns less `hidden`. Q4 (Product): administrators,
-- supervisors and staff hold soft-deleted rows with deleted_at set, as they read them today; a customer account (live_only) holds
-- none. '' when it holds.
CREATE FUNCTION pg_temp.sf_check_direct(p text, hidden text[] DEFAULT '{}', live_only boolean DEFAULT false) RETURNS text LANGUAGE plpgsql AS $$
DECLARE d record; ent text; cols text[]; direct jsonb; held jsonb; bad text; problems text[] := '{}'; live text;
BEGIN
  SELECT * INTO d FROM pg_temp.sf_device WHERE phone = p;
  FOREACH ent IN ARRAY d.entities LOOP
    CONTINUE WHEN NOT ent = ANY (pg_temp.sf_list('table_entities'));
    CONTINUE WHEN NOT has_table_privilege('authenticated', format('public.%I', ent), 'SELECT');
    cols := pg_temp.sf_columns(ent);
    live := CASE WHEN live_only AND 'deleted_at' = ANY (cols) THEN 't.deleted_at IS NULL' ELSE 'true' END;
    direct := pg_temp.sf_as(d.claims, format('SELECT COALESCE(jsonb_agg(t.id::text ORDER BY t.id::text), ''[]'') FROM public.%I t WHERE %s', ent, live));
    SELECT COALESCE(jsonb_agg(c.id ORDER BY c.id), '[]') INTO held FROM pg_temp.sf_copy c WHERE c.slot = p AND c.e = ent;
    IF direct IS DISTINCT FROM held THEN
      problems := problems || format('%s ids: copy %s, direct read %s', ent, jsonb_array_length(held), jsonb_array_length(direct));
    END IF;
    SELECT string_agg(DISTINCT array_to_string(ARRAY(SELECT k FROM jsonb_object_keys(c.row) k ORDER BY k), ','), ' | ') INTO bad
      FROM pg_temp.sf_copy c WHERE c.slot = p AND c.e = ent
      AND ARRAY(SELECT k FROM jsonb_object_keys(c.row) k ORDER BY k) IS DISTINCT FROM ARRAY(SELECT x FROM unnest(cols) x WHERE x <> ALL (hidden) ORDER BY x);
    IF bad IS NOT NULL THEN problems := problems || format('%s columns %s, expected %s', ent, bad, array_to_string(ARRAY(SELECT x FROM unnest(cols) x WHERE x <> ALL (hidden) ORDER BY x), ',')); END IF;
  END LOOP;
  RETURN array_to_string(problems, '; ');
END $$;

-- The ids of one entity a phone holds.
CREATE FUNCTION pg_temp.sf_held(p text, ent text) RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT COALESCE(array_agg(id ORDER BY id), '{}') FROM pg_temp.sf_copy WHERE slot = p AND e = ent $$;
-- The operations a phone received for one id in one pull (all pulls when pull is NULL), in order.
CREATE FUNCTION pg_temp.sf_ops(p text, ent text, rid text, in_pull int DEFAULT NULL) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT COALESCE(string_agg(op, ',' ORDER BY seq), '') FROM pg_temp.sf_entry
  WHERE phone = p AND e = ent AND id = rid AND (in_pull IS NULL OR pull = in_pull) $$;
CREATE FUNCTION pg_temp.sf_last_pull(p text) RETURNS int LANGUAGE sql STABLE AS $$ SELECT pulls FROM pg_temp.sf_device WHERE phone = p $$;

-- Runs one statement as supabase_admin (the server-side steps the tests drive: rotate_log, format, replica-role loads).
CREATE FUNCTION pg_temp.sf_exec(stmt text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN EXECUTE stmt; END $$;
-- One get_sync_changes call of a phone from its stored position and copy key (or the ones given), without applying it.
CREATE FUNCTION pg_temp.sf_changes_once(p text, at_position text DEFAULT NULL, with_copy text DEFAULT NULL, lim int DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE d record;
BEGIN
  SELECT * INTO d FROM pg_temp.sf_device WHERE phone = p;
  RETURN pg_temp.sf_as(d.claims, format(pg_temp.sf('call_changes'), COALESCE(at_position, d.position), COALESCE(with_copy, d.copy),
    COALESCE(lim, pg_temp.sf('page_limit')::int)));
END $$;

-- Fixtures through today's RPCs (not part of the feed contract). n lines of one item: package marks <prefix>1..n, rack R1.
CREATE FUNCTION pg_temp.sf_lines(item uuid, n int, prefix text, qty int DEFAULT 10) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_agg(jsonb_build_object('item_id', item, 'item_name', i.name, 'packaging', 'Bag', 'qty', qty, 'weight', 5, 'rack', 'R1',
    'package_mark', prefix || g) ORDER BY g)
  FROM generate_series(1, n) g CROSS JOIN public.items i WHERE i.id = item $$;
-- save_grn as a caller; returns the new GRN's id.
CREATE FUNCTION pg_temp.sf_save_grn(claims jsonb, grn_no text, customer uuid, lines jsonb) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r jsonb; cname text; sup uuid; gid uuid;
BEGIN
  SELECT name INTO cname FROM public.customers WHERE id = customer;
  SELECT id INTO sup FROM public.user_profiles WHERE mobile = '919888897001';
  r := pg_temp.sf_as(claims, format('SELECT public.save_grn(p_sender_name => %L, p_supervisor_id => %L::uuid, p_supervisor_name => %L, p_gr_no => %L,'
    ' p_date => %L::timestamptz, p_customer_id => %L::uuid, p_customer_name => %L, p_pricing_mode => %L, p_items => %L::jsonb, p_idempotency_key => %L)',
    'Fixture Sender', sup, 'Fixture Supervisor', grn_no, '2026-04-01T12:00:00Z', customer, cname, 'MONTHLY', lines, 'sync-feed-' || grn_no));
  PERFORM pg_temp.sf_assert(r->>'success' = 'true', 'fixture: save_grn ' || grn_no || ': ' || left(r::text, 300));
  SELECT id INTO gid FROM public.goodsreceived WHERE gr_no = grn_no;
  RETURN gid;
END $$;
-- update_grn as a caller with the whole line list (WH-111); returns the answer, which must be a success.
CREATE FUNCTION pg_temp.sf_update_grn(claims jsonb, grn uuid, lines jsonb, customer uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r jsonb;
BEGIN
  r := pg_temp.sf_as(claims, format('SELECT public.update_grn(p_grn_id => %L::uuid, p_customer_id => %L::uuid, p_customer_name => %L, p_items => %L::jsonb)',
    grn, customer, (SELECT name FROM public.customers WHERE id = customer), lines));
  PERFORM pg_temp.sf_assert(r->>'success' = 'true', 'fixture: update_grn: ' || left(r::text, 300));
  RETURN r;
END $$;
-- The current line list of a GRN as update_grn takes it.
CREATE FUNCTION pg_temp.sf_current_lines(grn uuid) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_agg(jsonb_build_object('id', t.id, 'item_id', t.item_id, 'item_name', t.item_name, 'packaging', t.packaging, 'qty', t.qty,
    'weight', t.weight, 'rack', t.rack, 'package_mark', t.package_mark) ORDER BY t.package_mark)
  FROM public.goodsreceived_trl t WHERE t.gr_id = grn $$;
-- create_dispatch_with_stock_check as a caller, one lot; returns the dispatch id.
CREATE FUNCTION pg_temp.sf_dispatch(claims jsonb, disp_no text, lot uuid, qty int) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r jsonb; cust uuid; cname text; did uuid;
BEGIN
  SELECT g.customer_id, g.customer_name INTO cust, cname FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE t.id = lot;
  r := pg_temp.sf_as(claims, format('SELECT public.create_dispatch_with_stock_check(%L::jsonb, ARRAY[%L::jsonb], 0, %L)',
    jsonb_build_object('disp_no', disp_no, 'disp_date', '2026-06-01', 'customer_id', cust, 'customer_name', cname,
      'supervisor_id', (SELECT id FROM public.user_profiles WHERE mobile = '919888897001'), 'supervisor_name', 'Sync Feed Administrator'),
    jsonb_build_object('gr_trl_id', lot, 'disp_qty', qty), 'sync-feed-' || disp_no));
  PERFORM pg_temp.sf_assert(r->>'success' = 'true', 'fixture: dispatch ' || disp_no || ': ' || left(r::text, 300));
  SELECT id INTO did FROM public.dispatch WHERE dispatch.disp_no = sf_dispatch.disp_no;
  RETURN did;
END $$;

-- ---------------------------------------------------------------------------------------------------------------------------------
-- Setup of the database (skipped by a session that passes -v sf_no_setup=1): sign-in configuration, the first administrator,
-- free-text document numbers for the fixtures, the charging rule the older suites use, and Storage deletes allowed (photos).
-- ---------------------------------------------------------------------------------------------------------------------------------
\if :{?sf_no_setup}
\else
SELECT set_config('storage.allow_delete_query', 'true', false);
INSERT INTO warehouse_security.auth_config(key, value) VALUES
 ('jwt_secret', 'isolated-test-secret-not-for-any-deployment-12345'), ('auth_mode', 'operator'), ('demo_auth_enabled', 'false')
 ON CONFLICT(key) DO UPDATE SET value = excluded.value;
UPDATE public.sms_config SET provider = 'msg91', production_mode = true, msg91_auth_key = 'isolated-test-key',
 msg91_template_id = '000000000000000000000001', msg91_pe_id = '0000000000000000001', msg91_sender_id = 'CITEST'
 WHERE id = (SELECT id FROM public.sms_config ORDER BY id DESC LIMIT 1);
SELECT warehouse_security.bootstrap_first_admin('9888897001', 'Sync Feed Administrator')
 WHERE NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE role = 'admin' AND active AND enrollment_status = 'approved');
SELECT warehouse_security.apply_document_numbering('grn', '{"scheme":"free"}', NULL), warehouse_security.apply_document_numbering('dispatch', '{"scheme":"free"}', NULL)
 WHERE EXISTS (SELECT 1 FROM warehouse_security.document_numbering WHERE scheme <> 'free');
UPDATE warehouse_security.charging_rule SET invoice_as_goods_leave = false WHERE id AND invoice_as_goods_leave;
\endif
SELECT set_config('storage.allow_delete_query', 'true', false);
SELECT pg_temp.sf_login('9888897001') AS sf_admin_claims \gset
SELECT id AS sf_admin_profile FROM public.user_profiles WHERE mobile = '919888897001' \gset
