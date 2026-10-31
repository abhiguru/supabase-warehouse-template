-- Migration 129: rate and invoice checks. The header below is completed as the sections are added; each section says what it does.

-- Section 1: replace_item_rates, change mode: a rate that starts after the start day is a later rate whether it has begun or is only
-- planned, so it is refused with LATER_RATES_EXIST unless p_replace_later is true. (Before, only a planned one was; a begun later rate
-- was deleted without a word.) A rate that starts ON the start day stays as before: one already in force is the rate being changed, a
-- planned one is a later rate. Each entry of data.later also says whether it has begun. No signature change.
DO $patch$
DECLARE
  v_def text;
  v_old constant text[] := ARRAY[
    $m$           AND r.effective_from >= p_starts_on AND r.effective_from > v_today
$m$,
    $m$'unit_price', r.unit_price)
                 ORDER BY r.effective_from, r.weight_min) INTO v_planned$m$
  ];
  v_new constant text[] := ARRAY[
    $m$           AND (r.effective_from > p_starts_on OR (r.effective_from = p_starts_on AND r.effective_from > v_today))
$m$,
    $m$'unit_price', r.unit_price, 'begun', r.effective_from <= v_today)
                 ORDER BY r.effective_from, r.weight_min) INTO v_planned$m$
  ];
  v_count integer;
  i integer;
BEGIN
  v_def := pg_get_functiondef('public.replace_item_rates(uuid, uuid, text, date, jsonb, boolean, text, date, uuid[])'::regprocedure);
  FOR i IN 1 .. array_length(v_old, 1) LOOP
    v_count := (length(v_def) - length(replace(v_def, v_old[i], ''))) / length(v_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'replace_item_rates: expected marker % once, found % times', i, v_count;
    END IF;
    v_def := replace(v_def, v_old[i], v_new[i]);
  END LOOP;
  EXECUTE v_def;
END
$patch$;
