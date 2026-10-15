-- Migration 84: update_grn no longer moves a GRN onto a deactivated business (owner decision, 2026-10-15).
--
--   Migration 83 made save_grn refuse a NEW GRN for a business with customers.active = false. update_grn
--   could still change an existing GRN's customer_id to such a business, which brings goods into a business
--   that takes none in. Now that move is refused with the same text, 'This business is deactivated. Activate
--   it in Customers to receive new goods.' (P0001, every caller). The check sits in the move branch after
--   the deleted-business check, so a deleted business keeps 'Business is not active', and before the
--   dispatch / invoice / order check. The inner block's handler re-raises, so the client gets the bare text.
--   Still allowed: editing a GRN that already belongs to a deactivated business without changing the
--   business, moving a GRN onto an active business, and everything in save_grn, the dispatch RPCs and orders.
--
-- Method as in migrations 80, 82 and 83: the current definition is patched; each replaced text must occur
-- exactly once, or the migration fails and applies nothing.

-- Migration 83 leaves its pg_temp helper behind when the migrations run in one session, so drop it first.
DROP FUNCTION IF EXISTS pg_temp.patch_rpc(regprocedure, text, text, integer);
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
  -- The deleted-business refusal is followed by END IF; the new check is added before that END IF.
  PERFORM pg_temp.patch_rpc('public.update_grn(uuid,character varying,timestamp with time zone,uuid,character varying,uuid,character varying,uuid,character varying,character varying,character varying,boolean,character varying,jsonb,jsonb,character varying,text)',
  $m$RAISE EXCEPTION 'Business is not active' USING ERRCODE = 'P0001';$m$,
  $r$RAISE EXCEPTION 'Business is not active' USING ERRCODE = 'P0001';
            END IF;
            IF EXISTS (SELECT 1 FROM customers WHERE id = p_customer_id AND active = false) THEN
                RAISE EXCEPTION 'This business is deactivated. Activate it in Customers to receive new goods.' USING ERRCODE = 'P0001';$r$);
END $patch$;

DROP FUNCTION pg_temp.patch_rpc(regprocedure, text, text, integer);
