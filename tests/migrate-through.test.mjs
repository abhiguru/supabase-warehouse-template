import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { migrationPlan } from '../scripts/migration-plan.mjs';

const root = new URL('..', import.meta.url).pathname;
const BASELINE = '00000000000000_baseline.sql';
const appliedNames = plan => [...plan.matchAll(/^\s+\\echo Applying: (\S+)$/gm)].map(match => match[1]);

test('--through stops the plan after the named file and the default plan is unchanged', () => {
  const all = readdirSync(`${root}migrations`).filter(name => name.endsWith('.sql')).sort();
  assert.ok(all.length > 2);
  assert.deepEqual(appliedNames(migrationPlan(root)), all);
  assert.deepEqual(appliedNames(migrationPlan(root, { through: BASELINE })), [BASELINE]);
  assert.deepEqual(appliedNames(migrationPlan(root, { through: all[1] })), all.slice(0, 2));
  // The ledger guard still lists every name of the release, so a later run is not told that 111 onward are unknown.
  assert.ok(migrationPlan(root, { through: BASELINE }).includes(`'${all.at(-1)}'`));
});

test('--through refuses an unknown name, in the plan, its command line and migrate.sh', () => {
  assert.throws(() => migrationPlan(root, { through: 'nope.sql' }), /Unknown migration/);
  const cli = spawnSync('node', [`${root}scripts/migration-plan.mjs`, '--through', 'nope.sql'], { encoding: 'utf8' });
  assert.equal(cli.status, 1);
  assert.match(cli.stderr, /Unknown migration for --through: nope\.sql/);
  assert.equal(cli.stdout, '');
  const ok = spawnSync('node', [`${root}scripts/migration-plan.mjs`, '--through', BASELINE], { encoding: 'utf8', maxBuffer: 1 << 28 });
  assert.equal(ok.status, 0);
  assert.deepEqual(appliedNames(ok.stdout), [BASELINE]);
  for (const args of [['--operator', '--through'], ['--operator', '--bogus', 'x'], ['--operator', '--through', '']]) {
    const run = spawnSync('bash', [`${root}scripts/migrate.sh`, ...args], { encoding: 'utf8' });
    assert.equal(run.status, 1, args.join(' '));
    assert.match(run.stderr, /Usage: scripts\/migrate\.sh --operator \[--through/);
  }
});
