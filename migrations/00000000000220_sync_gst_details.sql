-- Sync feed, GST details and bills allowed (WH-348, offline work step 6): topic "sync GST details". Named by topic; its number is taken when
-- the work is assembled for main. THE LAST MIGRATION OF FEED FORMAT 3: it sets the payload format to 3 for the whole set ("sync orders",
-- "sync payments", "sync order dispatch names", "stable order reads", "sync GRN rates", "sync item rates", "sync invoice amounts" and this
-- one). Contract: product/tech/app-offline-read-more.md sections 4 (topic 4), 7 and 14.1.
--
--  1. Two more rows of the 'settings' entity:
--       gst_details    administrators only: {"data": <what get_gst_details answers in data>} (the answer without success);
--       bills_allowed  administrators, supervisors and staff: {"allowed": warehouse_security.bills_allowed()} (can_make_bills' data).
--  2. They change with the facility's legal settings: log_change() logs both when public.system_settings changes the key facility_legal
--     (the GST details) or app_name (the legal name falls back to it). A user_profiles entry re-sends gst_details (saved_by_name is a
--     profile's name). Only administrators ever receive gst_details: the others' feed answer drops it, as it drops charging_rule.
--  3. The payload format becomes 3: every phone's copy of format 2 answers reload_all FORMAT_CHANGED.
--
-- Patched by text with marker counts; no role, table, column, grant, owner, search_path or volatility changes. The row trigger and the
-- TRUNCATE trigger of system_settings are ENABLE ALWAYS, as the other tables of the feed.

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
    v_count := (length(v_def) - length(replace(v_def, p_old[i], ''))) / length(p_old[i]);
    IF v_count <> 1 THEN
      RAISE EXCEPTION '%: expected marker % once, found % times', p_function, i, v_count;
    END IF;
    v_def := replace(v_def, p_old[i], p_new[i]);
  END LOOP;
  EXECUTE v_def;
END $$;

-- ===== 1. the two settings rows =====
SELECT pg_temp.patch_function('warehouse_sync.settings_rows(text)'::regprocedure, ARRAY[
$m$  SELECT 'rack_presets', warehouse_security.rack_presets_json() WHERE p_role IN ('admin', 'supervisor', 'staff')$m$
], ARRAY[
$m$  SELECT 'rack_presets', warehouse_security.rack_presets_json() WHERE p_role IN ('admin', 'supervisor', 'staff')
  UNION ALL
  SELECT 'gst_details', jsonb_build_object('data', warehouse_security.gst_settings()
           || jsonb_build_object('saved_by_name', (SELECT p.name FROM public.user_profiles p
                                                    WHERE p.id::text = warehouse_security.gst_settings()->>'saved_by'),
                                 'states', (SELECT jsonb_agg(jsonb_build_object('code', s.code, 'name', s.name) ORDER BY s.name)
                                              FROM warehouse_security.gst_state_list() s)))
    WHERE p_role = 'admin'
  UNION ALL
  SELECT 'bills_allowed', jsonb_build_object('allowed', warehouse_security.bills_allowed()) WHERE p_role IN ('admin', 'supervisor', 'staff')$m$
]);

-- ===== 2. what logs them =====
SELECT pg_temp.patch_function('warehouse_sync.log_change()'::regprocedure, ARRAY[
$m$WHEN 'rack_presets', 'rack_preset_state' THEN$m$
], ARRAY[
$m$WHEN 'system_settings' THEN
    -- The keys behind get_gst_details and can_make_bills; every other setting is nobody's copy.
    IF COALESCE(o->>'key', n->>'key') IN ('facility_legal', 'app_name') THEN
      PERFORM warehouse_sync.log_entry('settings', 'gst_details', 'U', NULL, NULL, NULL, NULL);
      PERFORM warehouse_sync.log_entry('settings', 'bills_allowed', 'U', NULL, NULL, NULL, NULL);
    END IF;
  WHEN 'rack_presets', 'rack_preset_state' THEN$m$
]);

-- gst_details is for administrators alone, as charging_rule is (get_gst_details is refused to everyone else).
SELECT pg_temp.patch_function('warehouse_sync.expand(text, warehouse_sync.change_log[])'::regprocedure, ARRAY[
$m$ELSE l.tbl END AS e, l.row_key AS id FROM l$m$,
$m$AND NOT (k.e = 'settings' AND k.id = 'charging_rule' AND p_role <> 'admin')$m$
], ARRAY[
$m$ELSE l.tbl END AS e, l.row_key AS id FROM l
    UNION ALL SELECT l.xid, 'settings', 'gst_details' FROM l WHERE l.tbl = 'user_profiles'$m$,
$m$AND NOT (k.e = 'settings' AND k.id IN ('charging_rule', 'gst_details') AND p_role <> 'admin')$m$
]);

SELECT pg_temp.patch_function('warehouse_sync.affected(text)'::regprocedure, ARRAY[
$m$ARRAY['user_profiles', 'people', 'orders', 'dispatch']$m$
], ARRAY[
$m$ARRAY['user_profiles', 'people', 'orders', 'dispatch', 'settings']$m$
]);

DROP FUNCTION pg_temp.patch_function(regprocedure, text[], text[]);

CREATE TRIGGER zz_change_feed AFTER INSERT OR UPDATE OR DELETE ON public.system_settings
  FOR EACH ROW EXECUTE FUNCTION warehouse_sync.log_change();
ALTER TABLE public.system_settings ENABLE ALWAYS TRIGGER zz_change_feed;
CREATE TRIGGER zz_change_feed_truncate AFTER TRUNCATE ON public.system_settings
  FOR EACH STATEMENT EXECUTE FUNCTION warehouse_sync.log_truncate();
ALTER TABLE public.system_settings ENABLE ALWAYS TRIGGER zz_change_feed_truncate;

-- ===== 3. format 3 =====
ALTER TABLE warehouse_sync.state ALTER COLUMN format SET DEFAULT 3;
UPDATE warehouse_sync.state SET format = 3;
