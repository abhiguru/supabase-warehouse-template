-- Migration 83: a NEW GRN is refused for a deactivated business (owner decision, 2026-10-15).
--
--   1. save_grn (new GRNs only) refuses a business with customers.active = false, next to migration 82's
--      deleted-business check, with 'This business is deactivated. Activate it in Customers to receive new
--      goods.' (P0001), for every caller. It is raised outside save_grn's inner
--      EXCEPTION block, so the client gets the bare text. update_grn, the dispatch RPCs and orders are unchanged: editing
--      an existing GRN of a deactivated business, and dispatching or ordering its goods, stay allowed.
--   2. update_customer: p_active = true also clears deleted_at / deleted_by, so a business is never active
--      and deleted at once (as set_customer_active(true) and restore_customer). p_active = false and NULL
--      change nothing else.
--
-- Method as in migrations 80 and 82: the current definitions are patched; each replaced text must occur
-- exactly once, or the migration fails and applies nothing.

CREATE FUNCTION pg_temp.patch_rpc(fn regprocedure, marker text, replacement text, expected integer DEFAULT 1) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE definition text := pg_get_functiondef(fn); occurrences integer;
BEGIN
  occurrences := (length(definition)-length(replace(definition,marker,'')))/length(marker);
  IF occurrences <> expected THEN
    RAISE EXCEPTION 'Expected % occurrence(s) of the marker in %, found %: %', expected, fn, occurrences, left(marker,80);
  END IF;
  EXECUTE replace(definition,marker,replacement);
END $$;

DO $patch$ BEGIN
  -- 1. The deleted-business refusal is followed by END IF; the new check is added before that END IF.
  PERFORM pg_temp.patch_rpc('public.save_grn(character varying,timestamp with time zone,uuid,character varying,uuid,character varying,uuid,character varying,character varying,character varying,boolean,character varying,jsonb,jsonb,text,character varying)',
  $m$RAISE EXCEPTION 'Business is not active' USING ERRCODE = 'P0001';$m$,
  $r$RAISE EXCEPTION 'Business is not active' USING ERRCODE = 'P0001';
      END IF;

      IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND active = false) THEN
          RAISE EXCEPTION 'This business is deactivated. Activate it in Customers to receive new goods.' USING ERRCODE = 'P0001';$r$);

  -- 2. Activating a business also brings back a soft-deleted one.
  PERFORM pg_temp.patch_rpc('public.update_customer(uuid,character varying,character varying,character varying,text,character varying,character varying,character varying,character varying,character varying,boolean,character varying,character varying,character varying,text[])',
  $m$active = COALESCE(p_active, active),$m$,
  $r$active = COALESCE(p_active, active),
        deleted_at = CASE WHEN p_active IS TRUE THEN NULL ELSE deleted_at END,
        deleted_by = CASE WHEN p_active IS TRUE THEN NULL ELSE deleted_by END,$r$);
END $patch$;
