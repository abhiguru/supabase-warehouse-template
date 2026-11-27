-- Topic "sync held items" (WH-304; contract tech/app-offline-holding-list.md sections 2.7 and 11.7): the feed entity held_items, feed format 5.
-- Named by topic; its number is taken when the work is assembled for main. It needs the topic "held items store and hand-over" and "holding
-- list reads and decisions" (the row shape) and WH-303's "replaced entries list and feed" (feed format 4, the entity grn_replacements whose
-- patches of the feed functions this one continues) applied before it.
--  1. warehouse_sync.rows_held_items: the rows a caller holds, by role. Never a customer account's; never in a customer account's list of
--     entities. Administrators, supervisors and staff:
--       the recorder (own rows that are held, or decided and not yet seen): the list row plus body, accepted_body, lines, grn_id, dispatch_id
--         and seen_at (the phone shows its own work offline);
--       administrators and supervisors (another person's held row): exactly id, kind, state, needs_decision and lines (the strip's count and
--         "less held"); the Holding list and the Held item screen read the server;
--       staff (another person's held newDispatch row): exactly id, kind, state and lines.
--     No row carries can_accept (it depends on other rows and would go stale). A row that leaves a caller's set (decided, or seen) reaches that
--     phone as a delete, as the feed answers any row its builder no longer returns.
--  2. The change log: held_items is a logged table (customer = customer_id), logged as itself; entities(), entity_rows() and log_change()
--     are patched by text with marker counts.
--  3. Feed format 5 (a copy of format 4 has no held_items and reloads everything).
-- No role is created, altered or dropped; the pg_temp helper is dropped at the end.

-- ===== 1. the rows =====
CREATE FUNCTION warehouse_sync.rows_held_items(p_role text, p_profile uuid, p_ids text[], p_after text, p_limit integer)
 RETURNS TABLE(id text, body jsonb)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT h.id::text,
         CASE
           WHEN h.recorded_by = p_profile THEN warehouse_security.held_row(h) || jsonb_build_object(
             'body', h.body, 'accepted_body', h.accepted_body, 'lines', h.lines, 'grn_id', h.grn_id, 'dispatch_id', h.dispatch_id, 'seen_at', h.seen_at)
           WHEN p_role IN ('admin', 'supervisor') THEN jsonb_build_object(
             'id', h.id, 'kind', h.kind, 'state', h.state, 'needs_decision', h.needs_decision, 'lines', h.lines)
           ELSE jsonb_build_object('id', h.id, 'kind', h.kind, 'state', h.state, 'lines', h.lines)
         END
    FROM public.held_items h
   WHERE p_role IN ('admin', 'supervisor', 'staff')
     AND ((h.recorded_by = p_profile AND (h.state = 'held' OR h.seen_at IS NULL))
          OR (h.state = 'held' AND (p_role IN ('admin', 'supervisor') OR (p_role = 'staff' AND h.kind = 'newDispatch'))))
     AND (p_ids IS NULL OR h.id = ANY (p_ids::uuid[]))
     AND (p_after IS NULL OR h.id > p_after::uuid)
   ORDER BY h.id LIMIT p_limit
$$;
ALTER FUNCTION warehouse_sync.rows_held_items(text, uuid, text[], text, integer) OWNER TO supabase_admin;
REVOKE ALL ON FUNCTION warehouse_sync.rows_held_items(text, uuid, text[], text, integer) FROM PUBLIC, anon, authenticated, service_role;

-- ===== 2. the entity and the change log =====
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
    IF position(p_old[i] IN p_new[i]) = 0 THEN
      RAISE EXCEPTION '%: the replacement of marker % does not keep the marker', p_function, i;
    END IF;
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- Listed for administrators, supervisors and staff; never for a customer account.
SELECT pg_temp.patch_function('warehouse_sync.entities(text)'::regprocedure, ARRAY[
$m$'grn_lock', 'grn_replacements'$m$,
$m$WHEN 'customer' THEN e NOT IN ('grn_replacements', $m$
], ARRAY[
$m$'grn_lock', 'grn_replacements', 'held_items'$m$,
$m$WHEN 'customer' THEN e NOT IN ('grn_replacements', 'held_items', $m$
]);

SELECT pg_temp.patch_function('warehouse_sync.entity_rows(text, uuid, uuid[], text, text[], text, integer)'::regprocedure, ARRAY[
$m$ELSIF p_entity = 'grn_replacements' THEN$m$
], ARRAY[
$m$ELSIF p_entity = 'held_items' THEN
    RETURN QUERY SELECT r.id, r.body FROM warehouse_sync.rows_held_items(p_role, p_profile, p_ids, p_after, p_limit) r;
    RETURN;
  ELSIF p_entity = 'grn_replacements' THEN$m$
]);

-- A held item is logged as itself, with its customer.
SELECT pg_temp.patch_function('warehouse_sync.log_change()'::regprocedure, ARRAY[
$m$WHEN 'grn_replacements' THEN$m$
], ARRAY[
$m$WHEN 'held_items' THEN
    PERFORM warehouse_sync.log_entry(t, r->>'id', op, (o->>'customer_id')::uuid, (n->>'customer_id')::uuid, NULL, NULL);
  WHEN 'grn_replacements' THEN$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

CREATE TRIGGER zz_change_feed AFTER INSERT OR UPDATE OR DELETE ON public.held_items
  FOR EACH ROW EXECUTE FUNCTION warehouse_sync.log_change();
ALTER TABLE public.held_items ENABLE ALWAYS TRIGGER zz_change_feed;
CREATE TRIGGER zz_change_feed_truncate AFTER TRUNCATE ON public.held_items
  FOR EACH STATEMENT EXECUTE FUNCTION warehouse_sync.log_truncate();
ALTER TABLE public.held_items ENABLE ALWAYS TRIGGER zz_change_feed_truncate;

-- ===== 3. feed format 5 =====
ALTER TABLE warehouse_sync.state ALTER COLUMN format SET DEFAULT 5;
UPDATE warehouse_sync.state SET format = 5;

NOTIFY pgrst, 'reload schema';
