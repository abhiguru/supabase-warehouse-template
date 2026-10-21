import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';

// The migrations directory holds the baseline, an exact squash of migrations 0 to 110 (the old files are in the git tag
// migrations-pre-baseline), and the migrations written after it. The baseline is never edited, so no test reads its text beyond the hash.
const BASELINE = '00000000000000_baseline.sql';
const baseline = readFileSync(new URL(`../migrations/${BASELINE}`, import.meta.url), 'utf8');

test('the migrations directory holds the baseline, pinned by its hash', () => {
  // A new migration is a new file with a number above 110; this one is never edited (the ledger refuses a changed checksum).
  assert.deepEqual(readdirSync(new URL('../migrations/', import.meta.url)).filter(name => name !== BASELINE && !/^\d{14}_[a-z0-9_]+\.sql$/.test(name)), []);
  // Numbers up to 110 belong to the baseline (and to the files in the tag): a new file may not reuse one.
  for (const name of readdirSync(new URL('../migrations/', import.meta.url)).filter(name => name !== BASELINE)) {
    assert.ok(Number(name.slice(0, 14)) > 110, `${name}: a new migration number must be above 110`);
  }
  assert.equal(createHash('sha256').update(baseline).digest('hex'), 'fcd627d11323af7ef35f101dd0827dff55adee3970cb420355e33a6b007b6ed8');
});

test('the migration run takes the migration lock once, runs the baseline, and has no list-refresh lock any more', async () => {
  const { migrationPlan } = await import('../scripts/migration-plan.mjs');
  const plan = migrationPlan(new URL('..', import.meta.url).pathname);
  assert.equal(plan.split('pg_advisory_lock(71041)').length - 1, 1, 'taken once');
  assert.ok(plan.lastIndexOf('pg_advisory_unlock(71041)') > plan.lastIndexOf('COMMIT;'), 'released after the last migration');
  assert.doesNotMatch(plan, /71046/, 'the list refresh lock is gone with pg_cron');
  assert.ok(plan.indexOf('pg_advisory_lock(71041)') < plan.indexOf(`Applying: ${BASELINE}`));
});

test('the ledger refuses a database that recorded a migration this release does not contain', async () => {
  const { migrationPlan } = await import('../scripts/migration-plan.mjs');
  const plan = migrationPlan(new URL('..', import.meta.url).pathname);
  const guard = plan.indexOf('warehouse_migrations.applied\n   WHERE name <> ALL (');
  assert.ok(guard > 0, 'the guard is in the plan');
  assert.ok(guard > plan.indexOf('CREATE TABLE IF NOT EXISTS warehouse_migrations.applied'), 'after the ledger table exists');
  assert.ok(guard < plan.indexOf(`Applying: ${BASELINE}`), 'before any migration runs');
  assert.ok(/WHERE name <> ALL \(ARRAY\[[^\]]*\]::text\[\]\)/.test(plan) && plan.includes(`'${BASELINE}'`), 'the baseline is in the list of this directory');
  assert.ok(plan.includes('docs/OPERATOR_INSTALL.md, "Baseline reload"'), 'the message points at the section by its exact title');
});

test('every tests/*.sql is registered exactly once in the test_files list of tests/migrations.sh', () => {
  // An unregistered file would silently never run. Every SQL suite rolls back, so the order does not matter.
  const harness = readFileSync(new URL('./migrations.sh', import.meta.url), 'utf8');
  const list = harness.match(/^test_files=\(\n([^)]*)\n\)/m);
  assert.ok(list, 'test_files=( ... ) was found');
  const registered = [...list[1].matchAll(/"\$ROOT\/tests\/([a-z0-9_]+\.sql)"/g)].map(match => match[1]);
  const files = readdirSync(new URL('./', import.meta.url)).filter(name => name.endsWith('.sql')).sort();
  assert.deepEqual([...registered].sort(), files);
});
