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
  // The names of this directory as a SQL array; every name matched ^\d+_[a-z0-9_]+\.sql$ above, so no quote can occur.
  const namesLiteral = `ARRAY[${files.map(name => `'${name}'`).join(', ')}]::text[]`;
  // 71041 serializes migration runs. Session level: released at the end, or when psql stops on an error.
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
END $$;
-- A migration the ledger recorded but this release does not contain (a database built by the chain that the baseline
-- replaced, or a file that was deleted) is an error: nothing is changed, and the message says what to do.
DO $$
DECLARE unknown text;
BEGIN
  SELECT string_agg(name, ', ' ORDER BY name) INTO unknown FROM warehouse_migrations.applied
   WHERE name <> ALL (${namesLiteral});
  IF unknown IS NOT NULL THEN
    RAISE EXCEPTION 'This database recorded migrations that are not in this release (%). Either it was built by an earlier migration chain and cannot be migrated in place (reload it: docs/OPERATOR_INSTALL.md, "Baseline reload"), or it is newer than this checkout (check out the release that recorded those migrations).', left(unknown, 200);
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

if (isMain(import.meta.url)) {
  process.stdout.write(migrationPlan(fileURLToPath(new URL('..', import.meta.url))));
}
