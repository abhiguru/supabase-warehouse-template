-- A receipt or dispatch number must contain something other than spaces.
--
-- save_grn refused a missing number but accepted an empty one, and a number made only of
-- spaces passed both save_grn and the dispatch validation. Such a record cannot be told
-- apart, searched for or printed by number.
--   * save_grn answers with its existing "required" message for a blank number;
--   * both tables refuse a blank number on any insert or update. The checks are NOT VALID so
--     an installation that already holds a blank number still migrates; that record must be
--     given a number the next time it is edited.
DO $migration$
DECLARE
  signature constant text := 'public.save_grn(varchar,timestamptz,uuid,varchar,uuid,varchar,uuid,varchar,varchar,varchar,boolean,varchar,jsonb,jsonb,text,varchar)';
  definition text := pg_get_functiondef(signature::regprocedure);
  before_text constant text := 'IF p_gr_no IS NULL OR p_date IS NULL OR p_customer_id IS NULL THEN';
  after_text constant text := 'IF NULLIF(btrim(p_gr_no), '''') IS NULL OR p_date IS NULL OR p_customer_id IS NULL THEN';
BEGIN
  IF (length(definition) - length(replace(definition, before_text, ''))) <> length(before_text) THEN
    RAISE EXCEPTION 'Unexpected required-parameter check in save_grn';
  END IF;
  EXECUTE replace(definition, before_text, after_text);
END;
$migration$;
ALTER TABLE public.goodsreceived ADD CONSTRAINT goodsreceived_gr_no_not_blank CHECK (btrim(gr_no) <> '') NOT VALID;
ALTER TABLE public.dispatch ADD CONSTRAINT dispatch_disp_no_not_blank CHECK (btrim(disp_no) <> '') NOT VALID;
