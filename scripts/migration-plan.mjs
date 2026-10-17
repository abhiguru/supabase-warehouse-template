import { readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMain } from './is-main.mjs';

export function migrationPlan(root) {
  const directory = resolve(root, 'migrations');
  const files = readdirSync(directory).filter(name => name.endsWith('.sql')).sort();
  if (!files.length) throw new Error('No migrations found');
  const migrations = files.map(name => {
    if (!/^\d+_[a-z0-9_]+\.sql$/.test(name)) throw new Error('Invalid migration filename');
    const sql = readFileSync(resolve(directory, name), 'utf8');
    return { name, sql, checksum: createHash('sha256').update(sql).digest('hex') };
  });
  // 71041 serializes migration runs. 71046 is the list refresh's lock (migration 91): held for the whole
  // run, so no refresh overlaps a migration. A migration that locks a table a list reads and then
  // refreshes or drops that list would otherwise deadlock with a refresh holding the view's lock. A refresh
  // in progress (seconds) finishes first; pg_cron runs started meanwhile return at once. Session level:
  // released at the end, or when psql stops on an error.
  const result = [String.raw`\set ON_ERROR_STOP on
SELECT pg_advisory_lock(71041);
DO $$
DECLARE holder text;
BEGIN
  PERFORM set_config('lock_timeout', '120s', true);
  PERFORM pg_advisory_lock(71046);
EXCEPTION WHEN lock_not_available THEN
  SELECT string_agg(format('pid %s (user %s, application %s)', a.pid, a.usename, a.application_name), ', ') INTO holder
    FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
   WHERE l.locktype = 'advisory' AND l.classid = 0 AND l.objid = 71046 AND l.objsubid = 1 AND l.granted;
  RAISE EXCEPTION 'The list refresh lock 71046 has been held by % for more than 120 s; migrations do not run beside a list refresh.',
    COALESCE(holder, 'another session')
    USING HINT = 'Let that refresh finish or end that session (a CALL of the worker left open in psql keeps the lock), then run setup again.';
END $$;
CREATE SCHEMA IF NOT EXISTS warehouse_migrations;
REVOKE ALL ON SCHEMA warehouse_migrations FROM PUBLIC,anon,authenticated;
CREATE TABLE IF NOT EXISTS warehouse_migrations.applied (
  name text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  IF to_regclass('public.user_profiles') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM warehouse_migrations.applied) THEN
    RAISE EXCEPTION 'Refusing to initialize an existing, untracked warehouse database';
  END IF;
END $$;`];
  for (const { name, sql, checksum } of migrations) {
    result.push(String.raw`
SELECT EXISTS (SELECT 1 FROM warehouse_migrations.applied WHERE name='${name}') AS applied \gset
\if :applied
  SELECT checksum='${checksum}' AS unchanged FROM warehouse_migrations.applied WHERE name='${name}' \gset
  \if :unchanged
    \echo Already applied: ${name}
  \else
    DO $$ BEGIN RAISE EXCEPTION 'Applied migration changed: ${name}. Restore it; add a new migration instead.'; END $$;
  \endif
\else
  \echo Applying: ${name}
  BEGIN;
${sql}
  INSERT INTO warehouse_migrations.applied(name,checksum) VALUES ('${name}','${checksum}');
  COMMIT;
\endif`);
  }
  result.push("NOTIFY pgrst, 'reload schema';\nSELECT pg_advisory_unlock(71046);\nSELECT pg_advisory_unlock(71041);\n");
  return result.join('\n');
}

if (isMain(import.meta.url)) {
  process.stdout.write(migrationPlan(fileURLToPath(new URL('..', import.meta.url))));
}
