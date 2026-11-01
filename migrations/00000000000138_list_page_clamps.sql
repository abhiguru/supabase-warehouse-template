-- Migration 138: the two list RPCs clamp their page size.
--
-- get_dispatch_list_with_items and get_invoices_list took any p_limit, so one call with p_limit 100000 built the whole list in
-- one answer (and, with items, every line of every dispatch). The page size is now clamped inside the function: p_limit to
-- 1..200 (a missing value keeps the default, 10 for dispatches and 50 for invoices); p_page below 1 is page 1, p_offset below 0
-- is 0. The answer reports the page and limit actually used. get_invoices_list also adds offset and limit as bigint for
-- `has_more`, so a huge p_offset cannot overflow it.
--
-- Marker-count patches of the current text (get_dispatch_list_with_items as migrations 125, 131 and 133 left it): each
-- marker must be found exactly once, and no before-text is contained in its after-text, so running the file a second time
-- raises the count error instead of adding the clamp again.
DO $patch$
DECLARE
  v_def text;
  v_count integer;
  v_before text;
  v_after text;
BEGIN
  v_def := pg_get_functiondef('public.get_dispatch_list_with_items(uuid, jsonb, text, text, integer, integer, boolean)'::regprocedure);
  v_before := $m$jsonb_build_object('p_customer_id',p_customer_id));
    SELECT role INTO v_user_role FROM user_profiles WHERE auth_user_id = auth.uid();$m$;
  v_after := $m$jsonb_build_object('p_customer_id',p_customer_id));
    p_limit := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 200);
    p_page := GREATEST(COALESCE(p_page, 1), 1);
    SELECT role INTO v_user_role FROM user_profiles WHERE auth_user_id = auth.uid();$m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_dispatch_list_with_items: expected the clamp marker once, found % times', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.get_invoices_list(integer, integer, uuid, integer, text, text, text, text, integer, integer, text, timestamp with time zone, timestamp with time zone, uuid[])'::regprocedure);
  v_before := $m$jsonb_build_object('p_customer_id',p_customer_id));
    -- Which customers the caller may see$m$;
  v_after := $m$jsonb_build_object('p_customer_id',p_customer_id));
    p_limit := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
    p_offset := GREATEST(COALESCE(p_offset, 0), 0);
    -- Which customers the caller may see$m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_invoices_list: expected the clamp marker once, found % times', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  v_before := $m$'has_more', (p_offset + p_limit) < v_total_count$m$;
  v_after := $m$'has_more', (p_offset::bigint + p_limit) < v_total_count$m$;
  v_count := (length(v_def) - length(replace(v_def, v_before, ''))) / length(v_before);
  IF v_count <> 1 THEN RAISE EXCEPTION 'get_invoices_list: expected the has_more marker once, found % times', v_count; END IF;
  v_def := replace(v_def, v_before, v_after);
  EXECUTE v_def;
END
$patch$;

NOTIFY pgrst, 'reload schema';
