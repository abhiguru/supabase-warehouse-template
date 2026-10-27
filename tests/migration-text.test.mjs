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

test('every migration file runs under a 10 s lock_timeout and tells the API to reload its schema right after its COMMIT', async () => {
  const { migrationPlan } = await import('../scripts/migration-plan.mjs');
  const { mkdtempSync, mkdirSync, writeFileSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-plan-text-'));
  try {
    mkdirSync(join(dir, 'migrations'));
    for (const name of ['00000000000001_one.sql', '00000000000002_two.sql', '00000000000003_three.sql']) writeFileSync(join(dir, 'migrations', name), `SELECT '${name}';\n`);
    const plan = migrationPlan(dir);
    const blocks = plan.split('\\echo Applying: ').slice(1);
    assert.equal(blocks.length, 3);
    for (const block of blocks) {
      const name = block.split('\n')[0];
      assert.match(block, new RegExp(`^${name}\\n  BEGIN;\\n  SET LOCAL lock_timeout = '10s';\\nSELECT '${name}';\\n`), `${name}: the timeout is set inside the transaction, before the file's SQL`);
      assert.match(block, /  COMMIT;\n  NOTIFY pgrst, 'reload schema';\n\\endif/, `${name}: the schema reload follows the COMMIT`);
    }
    assert.ok(plan.trimEnd().endsWith("NOTIFY pgrst, 'reload schema';\nSELECT pg_advisory_unlock(71041);"), 'the final reload and the unlock stay at the end');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('the ordering rule: a new migration must sort after every migration of the base (scripts/check-migration-order.mjs)', async () => {
  const { migrationOrderProblems } = await import('../scripts/check-migration-order.mjs');
  const file = text => Buffer.from(text);
  const base = new Map([['00000000000000_baseline.sql', file('a')], ['00000000000126_last.sql', file('b')]]);
  const withNew = name => new Map([...base, [name, file('c')]]);
  assert.deepEqual(migrationOrderProblems(base, withNew('00000000000127_next.sql')), [], 'a file that sorts last is fine');
  assert.deepEqual(migrationOrderProblems(base, withNew('00000000000126_last_b.sql')), [], '... also one that shares the number but sorts after');
  assert.equal(migrationOrderProblems(base, withNew('00000000000125_early.sql')).length, 1, 'a file below the last one is a problem');
  assert.match(migrationOrderProblems(base, withNew('00000000000126_a.sql'))[0], /sorts before 00000000000126_last\.sql/, '... also one that shares the number but sorts before');
  assert.deepEqual(migrationOrderProblems(new Map(), withNew('00000000000001_first.sql')), [], 'an empty base accepts anything');
  // The repository itself: its own files, read as base and as current, satisfy the rule (a file in a wrong place would be named).
  const directory = new URL('../migrations/', import.meta.url);
  const own = new Map(readdirSync(directory).filter(name => name.endsWith('.sql')).map(name => [name, readFileSync(new URL(name, directory))]));
  assert.deepEqual(migrationOrderProblems(own, own), []);
});
