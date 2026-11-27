-- public.save_grn: the definition setup applies after the numbered migrations whenever this file's checksum changes
-- (scripts/migration-plan.mjs, table warehouse_migrations.definitions). Edit the function here, never in a new migration.
-- Starts as the function migrations 000 to 126 leave (the numbered files that patched it stay as they are, never edited).
CREATE OR REPLACE FUNCTION public.save_grn(p_gr_no character varying, p_date timestamp with time zone, p_customer_id uuid, p_customer_name character varying, p_sender_id uuid DEFAULT NULL::uuid, p_sender_name character varying DEFAULT NULL::character varying, p_supervisor_id uuid DEFAULT NULL::uuid, p_supervisor_name character varying DEFAULT NULL::character varying, p_registration character varying DEFAULT NULL::character varying, p_note character varying DEFAULT NULL::character varying, p_leon boolean DEFAULT false, p_pricing_mode character varying DEFAULT NULL::character varying, p_items jsonb DEFAULT '[]'::jsonb, p_images jsonb DEFAULT '[]'::jsonb, p_idempotency_key text DEFAULT NULL::text, p_duration_mode character varying DEFAULT 'legacy'::character varying, p_rates jsonb DEFAULT NULL::jsonb, p_warn_duplicate boolean DEFAULT false, p_issue_number boolean DEFAULT false, p_recorded_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions', 'utils', 'pg_temp'
 SET jit TO 'off'
AS $function$
  DECLARE
      v_user_id uuid;
      v_user_profile_id uuid;
      v_user_role text;
      v_grn_id uuid;
      v_item_id uuid;
      v_item jsonb;
      v_image jsonb;
      v_image_id uuid;
      v_item_ids uuid[] := '{}';
      v_image_ids uuid[] := '{}';
      v_items_created int := 0;
      v_images_saved int := 0;
      v_item_index int;
      v_item_mapping jsonb := '[]'::jsonb;
      v_cached_response jsonb;
      v_result jsonb;
      v_rate_failure jsonb;
      v_detail text;
      v_duplicate jsonb;
      v_number_failure jsonb;
      v_offline boolean;
      v_digest text;
      v_repeat jsonb;
      v_numbered jsonb;
      v_pre_ids uuid[];
      v_pre_mapping jsonb;
      v_accepter uuid;
BEGIN
  PERFORM warehouse_security.authorize_rpc('save_grn',jsonb_build_object('p_customer_id',p_customer_id));
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
  -- Migration 130: surrounding white space (spaces, tabs, line breaks, non-breaking spaces) is not stored, runs of white space inside collapse to one space, a blank one is NULL; the length is checked on the trimmed value.
  p_registration := NULLIF(regexp_replace(regexp_replace(p_registration, '^[\s\u00a0]+|[\s\u00a0]+$', '', 'g'), '[\s\u00a0]+', ' ', 'g'), '');
  IF p_registration IS NOT NULL AND char_length(p_registration) > 20 THEN
    RETURN warehouse_security.grn_rate_failure('registration_too_long',
      'Registration can have at most 20 characters', jsonb_build_object('limit', 20));
  END IF;
  -- WH-237: the sender name and the supervisor name are stored without white space at either end (white space inside is kept), and
  -- one that is empty or only white space is stored as NULL. warehouse_security.trimmed_reason trims exactly the characters
  -- warehouse_security.is_blank_text treats as blank, so the WH-231 checks below answer as they did. update_grn.sql stores a name
  -- that an edit sends the same way. The customer's name that WH-248 stores as fas-sync's missing sender (below) is trimmed the same way.
  p_sender_name := warehouse_security.trimmed_reason(p_sender_name);
  p_supervisor_name := warehouse_security.trimmed_reason(p_supervisor_name);
    -- The list-refresh lock comes before any row lock (migration 46).
    PERFORM pg_advisory_xact_lock(71040);
      -- WH-161 (offline sends): a save that carries the recorded time or asks the server for its number is an offline send. It must
      -- carry a request key, which is kept on the GRN itself (request_key, request_digest), so a repeat is answered with the first
      -- answer however late it comes, and the key of another request or person is refused (warehouse_security.offline_repeat).
      -- The saved answers below (7 days) are used by saves that are not offline sends, exactly as before.
      v_offline := COALESCE(p_issue_number, false) OR p_recorded_at IS NOT NULL;
      IF v_offline THEN
          IF warehouse_security.is_blank_text(p_idempotency_key) THEN
              RETURN warehouse_security.refuse('REQUEST_KEY_REQUIRED', 'A save made offline needs a request key.', '{}'::jsonb);
          END IF;
          -- WH-304: an item accepted from the holding list is saved for the person who recorded it (the request key's owner is theirs).
          v_user_profile_id := COALESCE(warehouse_security.acting_profile(), (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid()));
          IF v_user_profile_id IS NOT NULL THEN
              v_digest := warehouse_security.request_digest(jsonb_build_object(
                  'gr_no', p_gr_no, 'date', extract(epoch FROM p_date), 'customer_id', p_customer_id, 'customer_name', p_customer_name,
                  'sender_id', p_sender_id, 'sender_name', p_sender_name, 'supervisor_id', p_supervisor_id, 'supervisor_name', p_supervisor_name,
                  'registration', p_registration, 'note', p_note, 'leon', p_leon, 'pricing_mode', p_pricing_mode, 'items', p_items,
                  'images', p_images, 'duration_mode', p_duration_mode, 'rates', p_rates, 'issue_number', COALESCE(p_issue_number, false)));
              v_repeat := warehouse_security.offline_repeat('save_grn', p_idempotency_key, v_user_profile_id, v_digest);
              IF v_repeat IS NOT NULL THEN
                  RETURN v_repeat;
              END IF;
          END IF;
      END IF;

      -- IDEMPOTENCY CHECK: Return cached response if key exists
      IF p_idempotency_key IS NOT NULL AND NOT v_offline THEN
          SELECT response INTO v_cached_response
          FROM idempotency_keys
          WHERE idempotency_key = p_idempotency_key
            AND rpc_function = 'save_grn'
            AND created_by = (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid())
            AND expires_at > now();

          -- The answer is replayed only while the GRN it created still exists and is not deleted. The answer of a
          -- deleted GRN is dropped (migration 120) and the call goes on as a new save: the same GRN can be entered
          -- again once its number is free again.
          IF v_cached_response IS NOT NULL THEN
              IF EXISTS (SELECT 1 FROM goodsreceived WHERE id = (v_cached_response #>> '{data,grn_id}')::uuid AND deleted_at IS NULL) THEN
                  RETURN v_cached_response || jsonb_build_object('idempotent', true);
              END IF;
              DELETE FROM idempotency_keys
              WHERE idempotency_key = p_idempotency_key
                AND rpc_function = 'save_grn'
                AND created_by = (SELECT id FROM user_profiles WHERE auth_user_id = auth.uid());
          END IF;
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
              'message', 'Insufficient permissions. Only admin and supervisor can create GRNs'
          );
      END IF;

      -- WH-304 (topic "save on behalf of the recorder"): when a supervisor or administrator accepts a held item, the role checks above
      -- are the accepting person's; the GRN is the recorder's (creator, request key owner, photos) and notes who accepted it.
      v_accepter := NULL;
      IF warehouse_security.acting_profile() IS NOT NULL THEN
          v_accepter := v_user_profile_id;
          v_user_profile_id := warehouse_security.acting_profile();
      END IF;

      PERFORM warehouse_security.require_person_supervisor(p_supervisor_id::text);

      -- WH-161: a deleted or deactivated customer is answered with a code, as every other refusal an offline send can meet, instead of
      -- raising; the words are today's. The check is before any write, so nothing is written either way.
      IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND deleted_at IS NOT NULL) THEN
          RETURN warehouse_security.refuse('CUSTOMER_INACTIVE', 'Business is not active', jsonb_build_object('customer_id', p_customer_id));
      END IF;

      IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND active = false) THEN
          RETURN warehouse_security.refuse('CUSTOMER_INACTIVE',
              'This business is deactivated. Activate it in Customers to receive new goods.', jsonb_build_object('customer_id', p_customer_id));
      END IF;

      -- WH-161: the recorded time is the phone's clock; one more than 5 minutes ahead of the server is refused (clock drift is allowed).
      IF p_recorded_at IS NOT NULL AND p_recorded_at > now() + interval '5 minutes' THEN
          RETURN warehouse_security.refuse('RECORDED_TIME_FUTURE', 'The time this was recorded is ahead of the server''s clock.',
              jsonb_build_object('recorded_at', p_recorded_at, 'server_time', now()));
      END IF;

      -- WH-161: the number is given at save (p_issue_number): the one the owner's numbering suggests for the day of the GRN, worked out
      -- here inside the lock (71040), so a burst of sends gets consecutive numbers in the order it arrives. Nothing is reserved: a save
      -- that is refused or rolled back uses none. A number sent beside the flag is refused; a store that types its numbers cannot be
      -- given one; a series with no number left is refused.
      IF COALESCE(p_issue_number, false) AND p_date IS NOT NULL AND p_customer_id IS NOT NULL THEN
          IF NOT warehouse_security.is_blank_text(p_gr_no) THEN
              RETURN warehouse_security.refuse('NUMBER_NOT_EXPECTED', 'This GRN already has a number, so the server does not give one.',
                  jsonb_build_object('number', p_gr_no));
          END IF;
          v_numbered := warehouse_security.document_number_suggestion('grn', warehouse_security.business_date(p_date));
          IF v_numbered->>'number' IS NULL THEN
              IF v_numbered->>'reason' = 'SERIES_FULL' THEN
                  RETURN warehouse_security.refuse('SERIES_FULL', COALESCE(v_numbered->>'message', 'No GRN number is left.'),
                      jsonb_build_object('scheme', v_numbered->>'scheme'));
              END IF;
              RETURN warehouse_security.refuse('NUMBER_REQUIRED', 'This store types its GRN numbers, so the server cannot give one.',
                  jsonb_build_object('scheme', v_numbered->>'scheme'));
          END IF;
          p_gr_no := v_numbered->>'number';
      END IF;

      IF warehouse_security.is_blank_text(p_gr_no) OR p_date IS NULL OR p_customer_id IS NULL THEN
          RETURN jsonb_build_object(
              'success', false,
              'message', 'Missing required parameters: gr_no, date, and customer_id are required'
          );
      END IF;

      -- Migration 130: a new GRN number has no space, tab or other whitespace in it. (update_grn cannot change a number, so
      -- stored numbers that have a space are left as they are.)
      IF p_gr_no ~ '[[:space:]]|\u00a0' THEN
          RETURN warehouse_security.refuse('GRN_NUMBER_SPACES', 'A GRN number can''t contain spaces.',
              jsonb_build_object('gr_no', p_gr_no));
      END IF;

      -- Migration 127: the number follows this facility's numbering (warehouse_security.document_numbering).
      v_number_failure := warehouse_security.document_number_failure('grn', p_gr_no, warehouse_security.business_date(p_date));
      IF v_number_failure IS NOT NULL THEN
          RETURN v_number_failure;
      END IF;

      -- Migration 130 (D10): a GRN is not dated in the future (today in India, the same day rule as a dispatch).
      IF warehouse_security.business_date(p_date) > warehouse_security.business_date(now()) THEN
          RETURN warehouse_security.refuse('GRN_DATE_FUTURE',
              format('A GRN can''t be dated in the future. Today is %s.', to_char(warehouse_security.business_date(now()), 'YYYY-MM-DD')),
              jsonb_build_object('date', to_char(warehouse_security.business_date(p_date), 'YYYY-MM-DD'),
                                 'today', to_char(warehouse_security.business_date(now()), 'YYYY-MM-DD')));
      END IF;

      IF EXISTS (SELECT 1 FROM goodsreceived WHERE gr_no = p_gr_no) THEN
          -- WH-161: the code and the number beside today's message.
          RETURN warehouse_security.refuse('NUMBER_TAKEN', 'GRN number already exists: ' || p_gr_no,
              jsonb_build_object('number', p_gr_no));
      END IF;

      -- WH-231: a new GRN has a sender name and a supervisor, as the app's form requires. Empty is NULL, or blank after trimming
      -- white space (spaces, tabs, line breaks, non-breaking spaces). The history import (WH-180) writes the tables itself and never
      -- calls this function; an edit (update_grn) has its own rule (WH-248). Nothing is written or numbered before this.
      -- WH-248 (it replaces WH-231's "fas-sync saves the sender empty"): a GRN that fas-sync creates from FAS with no sender is saved
      -- with the sender name set to the customer's name, the name stored as the GRN's customer below (one business per GRN: the sender
      -- is the customer). The sender id stays as sent. The supervisor check below has no exemption.
      -- fas-sync is recognised by two things together, and both are needed:
      --   1. session_user is supabase_admin: the login of the connection (SET ROLE and SECURITY DEFINER do not change it). fas-sync
      --      writes with psql on a direct installer connection; the API logs in as authenticator, and nothing a client sends through
      --      it can change the login, so the default cannot be claimed through the API.
      --   2. fas.session is set and not blank: fas-sync sets it for the transaction of each push before it acts as its profile. It
      --      tells fas-sync apart from an installer's own psql call on the same login, which stays refused. A setting local to a
      --      transaction reads as '' once that transaction ends, so blank counts as not set.
      -- update_grn.sql recognises fas-sync's updates the same way.
      IF warehouse_security.is_blank_text(p_sender_name)
         AND session_user = 'supabase_admin'
         AND NOT warehouse_security.is_blank_text(current_setting('fas.session', true)) THEN
          p_sender_name := warehouse_security.trimmed_reason(COALESCE((SELECT c.name FROM customers c WHERE c.id = p_customer_id), p_customer_name));
      END IF;
      IF warehouse_security.is_blank_text(p_sender_name) THEN
          RETURN warehouse_security.refuse('SENDER_REQUIRED', 'Sender name is required', '{}'::jsonb);
      END IF;
      IF p_supervisor_id IS NULL OR warehouse_security.is_blank_text(p_supervisor_name) THEN
          RETURN warehouse_security.refuse('SUPERVISOR_REQUIRED', 'Supervisor is required', '{}'::jsonb);
      END IF;

      IF jsonb_array_length(p_items) = 0 THEN
          RETURN jsonb_build_object(
              'success', false,
              'message', 'At least one item is required'
          );
      END IF;

      -- WH-161: an offline send fixes the ids of its lines before the GRN is written, so the answer to a repeat can name them in the same
      -- order (request_item_mapping): the id of line n is v_pre_ids[n + 1].
      IF v_offline THEN
          v_pre_ids := ARRAY(SELECT uuid_generate_v1() FROM generate_series(1, jsonb_array_length(p_items)));
          SELECT COALESCE(jsonb_agg(jsonb_build_object('index', t.ord - 1, 'item_id', v_pre_ids[t.ord::integer], 'item_name', t.e->>'item_name')
                                    ORDER BY t.ord), '[]'::jsonb)
            INTO v_pre_mapping
            FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, ord);
      END IF;

      BEGIN
          INSERT INTO goodsreceived (
              gr_no,
              date,
              customer_id,
              customer_name,
              sender_id,
              sender_name,
              supervisor_id,
              supervisor_name,
              registration,
              note,
              leon,
              pricing_mode,
              duration_mode,
              out_of_stock,
              invoiced,
              created_by,
              updated_by,
              recorded_at,
              request_key,
              request_digest,
              request_item_mapping,
              accepted_by
          ) VALUES (
              p_gr_no,
              p_date,
              p_customer_id,
              COALESCE((SELECT name FROM customers WHERE id = p_customer_id), p_customer_name),
              p_sender_id,
              p_sender_name,
              p_supervisor_id,
              p_supervisor_name,
              p_registration,
              p_note,
              COALESCE(p_leon, false),
              p_pricing_mode,
              COALESCE(p_duration_mode, 'legacy'),
              false,
              false,
              v_user_profile_id,
              v_user_profile_id,
              p_recorded_at,
              CASE WHEN v_offline THEN p_idempotency_key END,
              CASE WHEN v_offline THEN v_digest END,
              CASE WHEN v_offline THEN v_pre_mapping END,
              v_accepter
          ) RETURNING id INTO v_grn_id;

          v_item_index := 0;
          FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
          LOOP
              IF v_item->>'item_name' IS NULL OR (v_item->>'qty')::int IS NULL THEN
                  RAISE EXCEPTION 'Invalid item data: item_name and qty are required for item at index %', v_item_index;
              END IF;
              IF (v_item->>'qty')::int <= 0 THEN
                  RAISE EXCEPTION 'Quantity must be greater than 0 for item at index %', v_item_index;
              END IF;
              IF (v_item->>'weight')::int < 0 THEN
                  RAISE EXCEPTION 'Weight cannot be negative for item at index %', v_item_index;
              END IF;
              -- WH-56: a weight is at most 9999 kg (a new line has no stored weight to keep).
              IF (v_item->>'weight')::int > 9999 THEN
                  RAISE EXCEPTION 'Weight must be at most 9999 for item at index %', v_item_index;
              END IF;

              INSERT INTO goodsreceived_trl (
                  id,
                  gr_id,
                  item_id,
                  item_name,
                  packaging,
                  qty,
                  stock,
                  weight,
                  rack,
                  package_mark
              ) VALUES (
                  COALESCE(v_pre_ids[v_item_index + 1], uuid_generate_v1()),
                  v_grn_id,
                  (v_item->>'item_id')::uuid,
                  v_item->>'item_name',
                  v_item->>'packaging',
                  (v_item->>'qty')::int,
                  (v_item->>'qty')::int,
                  COALESCE((v_item->>'weight')::int, 0),
                  -- Migration 121 (D15): rack and package mark are stored with the digits 0-9.
                  warehouse_security.ascii_digits(v_item->>'rack'),
                  warehouse_security.ascii_digits(v_item->>'package_mark')
              ) RETURNING id INTO v_item_id;

              v_item_ids := array_append(v_item_ids, v_item_id);
              v_items_created := v_items_created + 1;

              v_item_mapping := v_item_mapping || jsonb_build_object(
                  'index', v_item_index,
                  'item_id', v_item_id,
                  'item_name', v_item->>'item_name'
              );

              v_item_index := v_item_index + 1;
          END LOOP;

          IF jsonb_array_length(p_images) > 0 THEN
              FOR v_image IN SELECT * FROM jsonb_array_elements(p_images)
              LOOP
                  IF v_image->>'storage_path' IS NULL OR v_image->>'image_type' IS NULL THEN
                      RAISE EXCEPTION 'Invalid image data: storage_path and image_type are required';
                  END IF;

                  v_image_id := gen_random_uuid();

                  PERFORM warehouse_security.require_image_path('grn', v_grn_id, v_image->>'image_type', v_image->>'storage_path');

                  IF v_image->>'image_type' = 'item' THEN
                      IF v_image->>'item_index' IS NOT NULL THEN
                          IF (v_image->>'item_index')::int < 0 OR
                             (v_image->>'item_index')::int >= jsonb_array_length(p_items) THEN
                              RAISE EXCEPTION 'Invalid item_index % for image. Must be between 0 and %',
                                  v_image->>'item_index', jsonb_array_length(p_items) - 1;
                          END IF;

                          v_item_id := v_item_ids[(v_image->>'item_index')::int + 1];

                          INSERT INTO grn_images (
                              id, grn_id, grn_item_id, image_type, storage_path,
                              original_filename, file_size, mime_type, uploaded_by, status
                          ) VALUES (
                              v_image_id, v_grn_id, v_item_id, v_image->>'image_type',
                              v_image->>'storage_path',
                              COALESCE(v_image->>'original_filename', 'unknown'),
                              COALESCE((v_image->>'file_size')::int, 0),
                              COALESCE(v_image->>'mime_type', 'image/jpeg'),
                              v_user_profile_id, 'confirmed'
                          );
                      ELSIF v_image->>'grn_item_id' IS NOT NULL THEN
                          IF NOT EXISTS (SELECT 1 FROM goodsreceived_trl
                              WHERE id = (v_image->>'grn_item_id')::uuid AND gr_id = v_grn_id) THEN
                              RAISE EXCEPTION 'Image line does not belong to this GRN';
                          END IF;
                          INSERT INTO grn_images (
                              id, grn_id, grn_item_id, image_type, storage_path,
                              original_filename, file_size, mime_type, uploaded_by, status
                          ) VALUES (
                              v_image_id, v_grn_id, (v_image->>'grn_item_id')::uuid,
                              v_image->>'image_type', v_image->>'storage_path',
                              COALESCE(v_image->>'original_filename', 'unknown'),
                              COALESCE((v_image->>'file_size')::int, 0),
                              COALESCE(v_image->>'mime_type', 'image/jpeg'),
                              v_user_profile_id, 'confirmed'
                          );
                      ELSE
                          RAISE EXCEPTION 'Item images must have either item_index or grn_item_id';
                      END IF;
                  ELSE
                      INSERT INTO grn_images (
                          id, grn_id, grn_item_id, image_type, storage_path,
                          original_filename, file_size, mime_type, uploaded_by, status
                      ) VALUES (
                          v_image_id, v_grn_id, NULL, v_image->>'image_type',
                          v_image->>'storage_path',
                          COALESCE(v_image->>'original_filename', 'unknown'),
                          COALESCE((v_image->>'file_size')::int, 0),
                          COALESCE(v_image->>'mime_type', 'image/jpeg'),
                          v_user_profile_id, 'confirmed'
                      );
                  END IF;

                  v_image_ids := array_append(v_image_ids, v_image_id);
                  v_images_saved := v_images_saved + 1;
              END LOOP;
          END IF;

          -- Rates typed on the GRN sheet (migration 86). A failure undoes the GRN with it: the
          -- raise leaves this block, whose writes are rolled back, and the handler answers it.
          IF p_rates IS NOT NULL THEN
              v_rate_failure := warehouse_security.apply_grn_rates(v_grn_id, p_rates);
              IF v_rate_failure IS NOT NULL THEN
                  RAISE EXCEPTION 'rate_fail' USING ERRCODE = 'P0001', DETAIL = v_rate_failure::text;
              END IF;
          END IF;

          -- Migration 124 (opt-in): when the caller asks (p_warn_duplicate) and sends a request key, the same customer, GRN day and
          -- set of items as another live GRN made in the last 30 minutes (by anyone) is a possible duplicate. This is the last step
          -- of the block, after every write and every refusal above: the answer is raised as 'dup_warn' (the handler returns the
          -- DETAIL), the block is rolled back, and the answer is never stored under the key.
          IF COALESCE(p_warn_duplicate, false) AND p_idempotency_key IS NOT NULL THEN
              v_duplicate := warehouse_security.possible_duplicate_grn(p_customer_id, p_date, p_items, v_grn_id, p_recorded_at);
              IF v_duplicate IS NOT NULL THEN
                  RAISE EXCEPTION 'dup_warn' USING ERRCODE = 'P0001', DETAIL = v_duplicate::text;
              END IF;
          END IF;

          v_result := jsonb_build_object(
              'success', true,
              'message', 'GRN created successfully',
              'data', jsonb_build_object(
                  'grn_id', v_grn_id,
                  'gr_no', p_gr_no,
                  'items_created', v_items_created,
                  'images_saved', v_images_saved,
                  'item_ids', v_item_ids,
                  'image_ids', v_image_ids,
                  'item_mapping', v_item_mapping
              )
          );

          IF p_idempotency_key IS NOT NULL THEN
              -- Kept for the 7 days a retry is answered from it (it was the column default, 1 hour), as
              -- update_grn and the dispatch create keep theirs. A key another function or user holds is left
              -- alone unless it has expired; an expired row of this key is replaced by the new answer
              -- (migration 120).
              INSERT INTO idempotency_keys (idempotency_key, rpc_function, response, created_by, expires_at)
              VALUES (p_idempotency_key, 'save_grn', v_result, v_user_profile_id, now() + interval '7 days')
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
          WHEN foreign_key_violation THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'message', 'Invalid reference: ' || SQLERRM
              );
          WHEN unique_violation THEN
              RETURN jsonb_build_object(
                  'success', false,
                  'message', 'Duplicate value: ' || SQLERRM
              );
          WHEN OTHERS THEN
              IF SQLERRM IN ('rate_fail', 'dup_warn') THEN
                  GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
                  RETURN v_detail::jsonb;
              END IF;
              RETURN jsonb_build_object(
                  'success', false,
                  'message', 'Error creating GRN: ' || SQLERRM
              );
      END;
  END;
  $function$;

REVOKE ALL ON FUNCTION public.save_grn(character varying,timestamp with time zone,uuid,character varying,uuid,character varying,uuid,character varying,character varying,character varying,boolean,character varying,jsonb,jsonb,text,character varying,jsonb,boolean,boolean,timestamp with time zone) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.save_grn(character varying,timestamp with time zone,uuid,character varying,uuid,character varying,uuid,character varying,character varying,character varying,boolean,character varying,jsonb,jsonb,text,character varying,jsonb,boolean,boolean,timestamp with time zone) TO service_role, authenticated;
