-- Migration 183 (WH-152, backend part): get_print_jobs answers the server's time, so the app's "unconfirmed for 5 minutes" rule does not
-- depend on the phone's clock.
-- Before: {success, data:[{..., created_at, updated_at}], message}, with no age and no server time; the View jobs sheet compared the phone's
-- clock with updated_at.
--  1. The answer gains server_now (timestamptz, now(): the time of the read on the server). Every other key, the rows, their order, the
--     limit and the role rules are unchanged; the "User not authenticated" answer is unchanged.
-- Written against get_print_jobs as migration 123 left it. Marker-count patch: the before-text is found once.

-- Migration 182 drops its helper; this guards against an earlier file that left one behind.
DROP FUNCTION IF EXISTS pg_temp.patch_function(regprocedure, text[], text[]);
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
    IF position(p_old[i] IN p_new[i]) > 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % contains the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

SELECT pg_temp.patch_function('public.get_print_jobs(integer, text, text)'::regprocedure, ARRAY[
$m$'message', null
    ) INTO v_result$m$
], ARRAY[
$m$'message', null,
        'server_now', now()  -- Migration 183 (WH-152): the server's time of this read.
    ) INTO v_result$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

NOTIFY pgrst, 'reload schema';
