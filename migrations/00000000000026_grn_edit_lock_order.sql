-- GRN edits take the list-refresh lock before the item-table lock (review,
-- 2026-10-08). Every other writer acquires advisory lock 71040 in its first
-- statement trigger and only then writes goodsreceived_trl; update_grn took a
-- ShareRowExclusive lock on goodsreceived_trl (ALTER TABLE ... DISABLE TRIGGER)
-- first and waited for 71040 afterwards, an A/B cycle that PostgreSQL resolves
-- by aborting one transaction. Acquiring 71040 up front makes the order
-- consistent; the later acquisitions inside the same transaction are reentrant.
DO $patch$
DECLARE fn regprocedure; definition text; marker text; replacement text; occurrences integer;
BEGIN
  SELECT p.oid::regprocedure INTO STRICT fn FROM pg_proc p
    WHERE p.pronamespace='public'::regnamespace AND p.proname='update_grn';
  definition := pg_get_functiondef(fn);
  marker := $m$    BEGIN
        PERFORM safe_disable_grn_trl_triggers();$m$;
  replacement := $r$    BEGIN
        PERFORM pg_advisory_xact_lock(71040);
        PERFORM safe_disable_grn_trl_triggers();$r$;
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> 1 THEN RAISE EXCEPTION 'Expected one trigger-disable marker in update_grn, found %', occurrences; END IF;
  EXECUTE replace(definition,marker,replacement);
END $patch$;
NOTIFY pgrst, 'reload schema';
