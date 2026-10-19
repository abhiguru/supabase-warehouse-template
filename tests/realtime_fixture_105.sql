-- What the Realtime service leaves in a database (schemas, a table that is in a publication, a tenant row), so that
-- migration 105 is run against something to remove. Applied by migrations.sh before the migrations up to 105; the
-- publication supabase_realtime itself comes from migrations 14 and 74. The database image already creates the schema realtime.
CREATE SCHEMA IF NOT EXISTS realtime;
CREATE SCHEMA IF NOT EXISTS _realtime;
CREATE TABLE _realtime.tenants (external_id text PRIMARY KEY);
INSERT INTO _realtime.tenants VALUES ('realtime-dev');
CREATE TABLE realtime.messages (id bigint, topic text) PARTITION BY RANGE (id);
CREATE TABLE realtime.messages_p1 PARTITION OF realtime.messages FOR VALUES FROM (0) TO (100);
CREATE FUNCTION realtime.apply_rls(x text) RETURNS text LANGUAGE sql AS $$ SELECT x $$;
CREATE PUBLICATION supabase_realtime_messages_publication FOR TABLE realtime.messages_p1;
