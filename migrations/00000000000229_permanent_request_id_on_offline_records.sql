-- Permanent request ID on offline records (WH-161, offline work step 5): topic "permanent request ID on offline records". Named by topic; its
-- number is taken when the work is assembled for main, after "recorded time on offline records". Contract:
-- product/tech/app-offline-new-records.md section 2.3, cases B5 to B8.
--
-- What it does:
--  1. An offline send (it carries the recorded time or asks for its number) must carry a request key. The key and a digest of the request
--     are stored on the document: request_key (unique where set) and request_digest on goodsreceived and dispatch. goodsreceived also keeps
--     request_item_mapping, the first answer's line mapping (index, item id, item name), so a repeat can name the lines in the same order.
--  2. A repeat of the key returns the first answer after any delay, with idempotent true, writes nothing, takes no second number and no
--     more stock: the saved answer in idempotency_keys if it is still there, else an answer rebuilt from the document
--     (warehouse_security.offline_repeat). The same key with other contents (digest), or from another person, is REQUEST_KEY_REUSED (the
--     name WH-302's save also uses; its answers stay in idempotency_keys with no expiry, which this topic does not change).
--  3. A document deleted meanwhile: warehouse_security.deleted_request_keys keeps its key, filled by a BEFORE DELETE trigger on both tables
--     (the delete functions hard-delete and are not changed), never purged. The same person with the same digest gets RECORD_DELETED, never
--     a new document; anyone else REQUEST_KEY_REUSED.
--  4. get_submission_result also finds an offline document by its key, without the 7 days of the saved answer, for the calling user only; a
--     deleted document is found: false (today's rule).
-- The save functions are in migrations/definitions (save_grn.sql, create_dispatch_with_stock_check_internal.sql).

ALTER TABLE public.goodsreceived ADD COLUMN request_key text, ADD COLUMN request_digest text, ADD COLUMN request_item_mapping jsonb;
ALTER TABLE public.dispatch ADD COLUMN request_key text, ADD COLUMN request_digest text;
CREATE UNIQUE INDEX goodsreceived_request_key_key ON public.goodsreceived (request_key) WHERE request_key IS NOT NULL;
CREATE UNIQUE INDEX dispatch_request_key_key ON public.dispatch (request_key) WHERE request_key IS NOT NULL;
COMMENT ON COLUMN public.goodsreceived.request_key IS 'WH-161: the request key of the offline send that made this GRN; NULL for a GRN saved online.';
COMMENT ON COLUMN public.goodsreceived.request_digest IS 'WH-161: sha256 of the offline request, to tell a repeat from another request under the same key.';
COMMENT ON COLUMN public.goodsreceived.request_item_mapping IS 'WH-161: the first answer''s item_mapping of an offline send, to answer a repeat.';
COMMENT ON COLUMN public.dispatch.request_key IS 'WH-161: the request key of the offline send that made this dispatch; NULL for a dispatch saved online.';
COMMENT ON COLUMN public.dispatch.request_digest IS 'WH-161: sha256 of the offline request, to tell a repeat from another request under the same key.';

-- The request keys of deleted documents. Never purged.
CREATE TABLE warehouse_security.deleted_request_keys (
  request_key    text PRIMARY KEY,
  rpc_function   text NOT NULL,
  record_id      uuid NOT NULL,
  created_by     uuid,
  request_digest text,
  deleted_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE warehouse_security.deleted_request_keys OWNER TO supabase_admin;
ALTER TABLE warehouse_security.deleted_request_keys ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE warehouse_security.deleted_request_keys FROM PUBLIC, anon, authenticated, service_role;
COMMENT ON TABLE warehouse_security.deleted_request_keys IS 'WH-161: the request key, creator and digest of every offline document that was deleted, so a late repeat is refused RECORD_DELETED instead of making a new document. Written by a BEFORE DELETE trigger; never purged; read only through the RPCs.';

CREATE FUNCTION warehouse_security.keep_deleted_request_key() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
BEGIN
  IF OLD.request_key IS NOT NULL THEN
    INSERT INTO warehouse_security.deleted_request_keys (request_key, rpc_function, record_id, created_by, request_digest)
    VALUES (OLD.request_key,
            CASE TG_TABLE_NAME WHEN 'goodsreceived' THEN 'save_grn' ELSE 'create_dispatch_with_stock_check' END,
            OLD.id, OLD.created_by, OLD.request_digest)
    ON CONFLICT (request_key) DO NOTHING;
  END IF;
  RETURN OLD;
END $$;
ALTER FUNCTION warehouse_security.keep_deleted_request_key() OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.keep_deleted_request_key() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER keep_deleted_request_key BEFORE DELETE ON public.goodsreceived FOR EACH ROW EXECUTE FUNCTION warehouse_security.keep_deleted_request_key();
CREATE TRIGGER keep_deleted_request_key BEFORE DELETE ON public.dispatch FOR EACH ROW EXECUTE FUNCTION warehouse_security.keep_deleted_request_key();

-- The digest of a request.
CREATE FUNCTION warehouse_security.request_digest(p_request jsonb) RETURNS text
  LANGUAGE sql IMMUTABLE SET search_path TO 'pg_catalog'
AS $$ SELECT encode(sha256(convert_to(p_request::text, 'UTF8')), 'hex') $$;
ALTER FUNCTION warehouse_security.request_digest(jsonb) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.request_digest(jsonb) FROM PUBLIC, anon, authenticated, service_role;

-- The first answer of a document made by an offline send: the saved answer while it is there, else one rebuilt from the document.
CREATE FUNCTION warehouse_security.offline_document_answer(p_function text, p_doc uuid, p_profile uuid) RETURNS jsonb
  LANGUAGE plpgsql STABLE SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
DECLARE
  v_answer jsonb;
BEGIN
  IF p_function = 'save_grn' THEN
    SELECT k.response INTO v_answer FROM idempotency_keys k
      JOIN goodsreceived g ON g.request_key = k.idempotency_key
     WHERE g.id = p_doc AND k.rpc_function = 'save_grn' AND k.created_by = p_profile AND k.response #>> '{data,grn_id}' = p_doc::text;
    IF v_answer IS NOT NULL THEN RETURN v_answer; END IF;
    SELECT jsonb_build_object('success', true, 'message', 'GRN created successfully', 'data', jsonb_build_object(
             'grn_id', g.id, 'gr_no', g.gr_no,
             'items_created', COALESCE(jsonb_array_length(g.request_item_mapping), 0),
             'images_saved', (SELECT count(*) FROM grn_images i WHERE i.grn_id = g.id),
             'item_ids', COALESCE((SELECT jsonb_agg(e->'item_id' ORDER BY ord) FROM jsonb_array_elements(g.request_item_mapping) WITH ORDINALITY AS t(e, ord)), '[]'::jsonb),
             'image_ids', COALESCE((SELECT jsonb_agg(i.id ORDER BY i.id) FROM grn_images i WHERE i.grn_id = g.id), '[]'::jsonb),
             'item_mapping', COALESCE(g.request_item_mapping, '[]'::jsonb)))
      INTO v_answer FROM goodsreceived g WHERE g.id = p_doc;
    RETURN v_answer;
  END IF;
  SELECT k.response INTO v_answer FROM idempotency_keys k
    JOIN dispatch d ON d.request_key = k.idempotency_key
   WHERE d.id = p_doc AND k.rpc_function = 'create_dispatch_with_stock_check' AND k.created_by = p_profile AND k.response->>'dispatch_id' = p_doc::text;
  IF v_answer IS NOT NULL THEN RETURN v_answer; END IF;
  SELECT jsonb_build_object('success', true, 'message', 'Dispatch created successfully', 'dispatch_id', d.id, 'disp_no', d.disp_no,
           'dispatch_items', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', dt.id, 'gr_id', dt.gr_id, 'gr_trl_id', dt.gr_trl_id,
                                                                            'disp_id', dt.disp_id, 'disp_qty', dt.disp_qty) ORDER BY dt.id)
                                       FROM dispatch_trl dt WHERE dt.disp_id = d.id), '[]'::jsonb),
           'invoice_data', '{}'::jsonb, 'source_order_cleared', d.source_order_id IS NOT NULL)
    INTO v_answer FROM dispatch d WHERE d.id = p_doc;
  RETURN v_answer;
END $$;
ALTER FUNCTION warehouse_security.offline_document_answer(text, uuid, uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.offline_document_answer(text, uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;

-- What a save made offline answers when its key was used before: NULL (no earlier request, go on), the first answer with idempotent true,
-- RECORD_DELETED, or REQUEST_KEY_REUSED. Called inside the document lock by save_grn and the dispatch create.
CREATE FUNCTION warehouse_security.offline_repeat(p_function text, p_key text, p_profile uuid, p_digest text) RETURNS jsonb
  LANGUAGE plpgsql STABLE SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
DECLARE
  v_doc record;
  v_tomb record;
  v_reused jsonb := warehouse_security.refuse('REQUEST_KEY_REUSED', 'This request key was already used for another request.', '{}'::jsonb);
BEGIN
  IF p_function = 'save_grn' THEN
    SELECT g.id, g.created_by, g.request_digest, g.deleted_at INTO v_doc FROM goodsreceived g WHERE g.request_key = p_key;
  ELSE
    SELECT d.id, d.created_by, d.request_digest, d.deleted_at INTO v_doc FROM dispatch d WHERE d.request_key = p_key;
  END IF;
  IF FOUND THEN
    IF v_doc.created_by IS DISTINCT FROM p_profile OR v_doc.request_digest IS DISTINCT FROM p_digest THEN
      RETURN v_reused;
    END IF;
    IF v_doc.deleted_at IS NOT NULL THEN
      RETURN warehouse_security.refuse('RECORD_DELETED', 'This record was deleted after it was sent.', '{}'::jsonb);
    END IF;
    RETURN warehouse_security.offline_document_answer(p_function, v_doc.id, p_profile) || jsonb_build_object('idempotent', true);
  END IF;
  SELECT t.rpc_function, t.created_by, t.request_digest INTO v_tomb FROM warehouse_security.deleted_request_keys t WHERE t.request_key = p_key;
  IF FOUND THEN
    IF v_tomb.rpc_function = p_function AND v_tomb.created_by IS NOT DISTINCT FROM p_profile AND v_tomb.request_digest IS NOT DISTINCT FROM p_digest THEN
      RETURN warehouse_security.refuse('RECORD_DELETED', 'This record was deleted after it was sent.', '{}'::jsonb);
    END IF;
    RETURN v_reused;
  END IF;
  -- A key another function or person holds in the saved answers (not expired) is not this request's.
  IF EXISTS (SELECT 1 FROM idempotency_keys k WHERE k.idempotency_key = p_key AND k.expires_at > now()
               AND (k.rpc_function <> p_function OR k.created_by IS DISTINCT FROM p_profile)) THEN
    RETURN v_reused;
  END IF;
  RETURN NULL;
END $$;
ALTER FUNCTION warehouse_security.offline_repeat(text, text, uuid, text) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.offline_repeat(text, text, uuid, text) FROM PUBLIC, anon, authenticated, service_role;

-- get_submission_result: the document of an offline send by its key, for the person who sent it.
CREATE FUNCTION warehouse_security.offline_submission(p_key text, p_profile uuid) RETURNS jsonb
  LANGUAGE plpgsql STABLE SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $$
DECLARE
  v_id uuid;
BEGIN
  SELECT g.id INTO v_id FROM goodsreceived g WHERE g.request_key = p_key AND g.created_by = p_profile AND g.deleted_at IS NULL;
  IF v_id IS NOT NULL THEN RETURN warehouse_security.offline_document_answer('save_grn', v_id, p_profile); END IF;
  SELECT d.id INTO v_id FROM dispatch d WHERE d.request_key = p_key AND d.created_by = p_profile AND d.deleted_at IS NULL;
  IF v_id IS NOT NULL THEN RETURN warehouse_security.offline_document_answer('create_dispatch_with_stock_check', v_id, p_profile); END IF;
  RETURN NULL;
END $$;
ALTER FUNCTION warehouse_security.offline_submission(text, uuid) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_security.offline_submission(text, uuid) FROM PUBLIC, anon, authenticated, service_role;

DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$    IF v_response IS NULL THEN$m$
  ];
  v_new constant text[] := ARRAY[
    $m$    -- WH-161: an offline document is found by its key whatever the age of the saved answer.
    v_response := COALESCE(v_response, warehouse_security.offline_submission(p_key, v_user_id));
    IF v_response IS NULL THEN$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.get_submission_result(text)'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'get_submission_result: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;

NOTIFY pgrst, 'reload schema';
