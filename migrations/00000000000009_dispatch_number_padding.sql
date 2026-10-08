-- Zero-pad only the reviewed dispatch suggestion output. pg_get_functiondef
-- preserves the injected authorization guard, SECURITY DEFINER and search_path;
-- CREATE OR REPLACE preserves existing EXECUTE grants.
-- dispatch.disp_no is varchar(8), so I9999999 is the largest storable numeric
-- identifier. Fail before returning an unstorable or repeated suggestion.
DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_get_functiondef('public.get_next_dispatch_number()'::regprocedure);

  IF (length(definition) - length(replace(definition, $before$RETURN 'I1';$before$, '')))
     <> length($before$RETURN 'I1';$before$) THEN
    RAISE EXCEPTION 'Unexpected dispatch-number initial expression';
  END IF;

  IF (length(definition) - length(replace(definition, $before$v_next_no := 'I' || v_num::TEXT;$before$, '')))
     <> length($before$v_next_no := 'I' || v_num::TEXT;$before$) THEN
    RAISE EXCEPTION 'Unexpected dispatch-number formatting expression';
  END IF;

  IF (length(definition) - length(replace(definition, $before$v_num := CAST(SUBSTRING(v_max_no FROM 2) AS INTEGER) + 1;$before$, '')))
     <> length($before$v_num := CAST(SUBSTRING(v_max_no FROM 2) AS INTEGER) + 1;$before$) THEN
    RAISE EXCEPTION 'Unexpected dispatch-number increment expression';
  END IF;

  EXECUTE replace(
    replace(
      replace(
        definition,
        $before$RETURN 'I1';$before$,
        $after$RETURN 'I0001';$after$
      ),
      $before$v_num := CAST(SUBSTRING(v_max_no FROM 2) AS INTEGER) + 1;$before$,
      $after$IF CAST(SUBSTRING(v_max_no FROM 2) AS INTEGER) >= 9999999 THEN
        RAISE EXCEPTION 'Dispatch number sequence exhausted at I9999999'
          USING ERRCODE = '22003';
    END IF;
    v_num := CAST(SUBSTRING(v_max_no FROM 2) AS INTEGER) + 1;$after$
    ),
    $before$v_next_no := 'I' || v_num::TEXT;$before$,
    $after$v_next_no := 'I' || LPAD(v_num::TEXT, GREATEST(4, LENGTH(v_num::TEXT)), '0');$after$
  );
END;
$migration$;
