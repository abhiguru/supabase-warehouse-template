\set ON_ERROR_STOP on
-- Mints one key for the sensor bridge (migration 74, docs/SENSORS.md) and prints it ONCE, as the
-- single column sensor_ingest_key. Only its SHA-256 is stored, in
-- warehouse_security.sensor_ingest_keys; the key cannot be read back. Put it straight into the
-- bridge's private environment file (SENSOR_INGEST_KEY) and nowhere else.
--
--   bash scripts/compose.sh exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -v label=<name> < scripts/sensor-ingest-key.sql
--
-- (on standard input: the database container does not hold this file, so -f cannot name it).
--
-- label names the bridge (1 to 64 letters, digits, spaces, dots, underscores or hyphens,
-- starting with a letter or digit); it is required. Each run mints a new key; earlier keys stay
-- valid until revoked. To revoke every key of a bridge:
--
--   UPDATE warehouse_security.sensor_ingest_keys SET revoked_at = now()
--   WHERE label = '<name>' AND revoked_at IS NULL;
--
-- A revoked key is refused at once (the edge function answers 401). The keys, without the key
-- itself: SELECT label, created_at, revoked_at, last_used_at FROM warehouse_security.sensor_ingest_keys;
\if :{?label}
\else
  \set label ''
\endif
BEGIN;
SELECT :'label' ~ '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$' AS label_valid \gset
\if :label_valid
\else
  DO $$ BEGIN RAISE EXCEPTION 'label must be 1 to 64 letters, digits, spaces, dots, underscores or hyphens, starting with a letter or digit'; END $$;
\endif
WITH minted AS (
  SELECT encode(extensions.gen_random_bytes(32), 'hex') AS sensor_ingest_key
), stored AS (
  INSERT INTO warehouse_security.sensor_ingest_keys(key_hash, label)
  SELECT encode(extensions.digest(m.sensor_ingest_key, 'sha256'), 'hex'), :'label' FROM minted m
  RETURNING key_hash
)
SELECT m.sensor_ingest_key FROM minted m JOIN stored s ON s.key_hash = encode(extensions.digest(m.sensor_ingest_key, 'sha256'), 'hex');
COMMIT;
