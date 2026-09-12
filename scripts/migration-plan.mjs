import { readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export function migrationPlan(root) {
  const directory = resolve(root, 'migrations');
  const files = readdirSync(directory).filter(name => name.endsWith('.sql')).sort();
  if (!files.length) throw new Error('No migrations found');
  const migrations = files.map(name => {
    if (!/^\d+_[a-z0-9_]+\.sql$/.test(name)) throw new Error('Invalid migration filename');
    const sql = readFileSync(resolve(directory, name), 'utf8');
    return { name, sql, checksum: createHash('sha256').update(sql).digest('hex') };
  });
  const result = [String.raw`\set ON_ERROR_STOP on
SELECT pg_advisory_lock(71041);
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
  result.push("NOTIFY pgrst, 'reload schema';\nSELECT pg_advisory_unlock(71041);\n");
  return result.join('\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.stdout.write(migrationPlan(fileURLToPath(new URL('..', import.meta.url))));
}
