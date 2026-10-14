-- Migration 75: sensor readings are kept 90 days (2026-10-13, owner's choice).
--
-- Migration 74 added the retention policy 'sensor_readings' with 400 days. The sensor bridge now
-- samples every sensor every 5 minutes by default (SENSOR_BRIDGE_POLL_SECONDS and
-- SENSOR_BRIDGE_HEARTBEAT_SECONDS both 300), about 288 rows per sensor a day, and the owner wants
-- three months of history. This sets the policy to 90 days.
--
-- Only the policy row changes: warehouse_maintenance.run_database_retention (migration 74) already
-- reads the days of 'sensor_readings' from the table, so nothing is deleted here. Readings older
-- than 90 days are counted by the next retention preview and deleted by the next retention apply.
-- Exactly one row must be updated; a database without the policy row (migration 74 not applied, or
-- the row removed by hand) stops this migration instead of passing silently.
--
-- tests/sensor_ingest.sql checks the 90 days and that retention deletes a reading of 91 days and
-- keeps one of 89 days.

DO $retention$
DECLARE
  updated integer;
BEGIN
  UPDATE warehouse_maintenance.retention_policy
     SET days = 90,
         description = 'Sensor readings (temperature and humidity history, sampled every 5 minutes)'
   WHERE key = 'sensor_readings';
  GET DIAGNOSTICS updated = ROW_COUNT;
  IF updated <> 1 THEN
    RAISE EXCEPTION 'migration 75: expected one retention_policy row with key sensor_readings, updated %', updated;
  END IF;
END $retention$;

NOTIFY pgrst, 'reload schema';
