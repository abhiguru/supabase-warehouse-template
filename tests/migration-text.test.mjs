import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';

// The migrations directory holds ONE file, the baseline: an exact squash of migrations 0 to 110 (the old files are in the git
// tag migrations-pre-baseline). The assertions that used to read single old migration files read the baseline text instead.
const BASELINE = '00000000000000_baseline.sql';
const baseline = readFileSync(new URL(`../migrations/${BASELINE}`, import.meta.url), 'utf8');
const escaped = text => text.replace(/[^\x00-\x7F]/g, character => `\\u${character.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}`);
const functionBody = name => {
  const start = baseline.indexOf(`CREATE FUNCTION ${name}(`);
  assert.ok(start > 0, `${name} is not in the baseline`);
  return baseline.slice(start, baseline.indexOf('\n$_$;', start) + 5);
};

test('the migrations directory holds the baseline, pinned by its hash', () => {
  // A new migration is a new file with a number above 110; this one is never edited (the ledger refuses a changed checksum).
  assert.deepEqual(readdirSync(new URL('../migrations/', import.meta.url)).filter(name => name !== BASELINE && !/^\d{14}_[a-z0-9_]+\.sql$/.test(name)), []);
  // Numbers up to 110 belong to the baseline (and to the files in the tag): a new file may not reuse one.
  for (const name of readdirSync(new URL('../migrations/', import.meta.url)).filter(name => name !== BASELINE)) {
    assert.ok(Number(name.slice(0, 14)) > 110, `${name}: a new migration number must be above 110`);
  }
  assert.equal(createHash('sha256').update(baseline).digest('hex'), 'fcd627d11323af7ef35f101dd0827dff55adee3970cb420355e33a6b007b6ed8');
});

test('the zero-charge reason trim (migration 48) holds no invisible or non-ASCII character', () => {
  // warehouse_security.trimmed_reason writes its trim class with escapes. A literal no-break space or zero-width space would
  // look like nothing in an editor and in a diff, and could be changed or lost without anyone seeing it.
  const lines = functionBody('warehouse_security.trimmed_reason').split('\n');
  const found = lines.flatMap((line, index) => /[^\x20-\x7E]/.test(line) ? [`line ${index + 1}: ${escaped(line.replace(/[\x00-\x1F\x7F]/g, '?'))}`] : []);
  assert.deepEqual(found, []);
});

test('the zero-charge reason is trimmed of the characters the discount reason is trimmed of (migration 41)', () => {
  // The discount-reason function (migration 41) holds the class as literal characters. The zero-charge reason must name the same
  // code points, as \uXXXX escapes of the regular expression, at both ends of the reason.
  // tests/zero_charge_reason.sql compares the two rules in the database.
  const literal = baseline.match(/blank constant text := '(\[[^']+\]\+)';/);
  assert.ok(literal, 'the discount trim class was not found in the baseline');
  assert.match(literal[1], /[^\x00-\x7F]/, 'the discount function is expected to hold the characters themselves');
  const written = escaped(literal[1]);
  assert.equal(written, '[\\s\\u0085\\u00A0\\u00AD\\u1680\\u180E\\u2000-\\u200F\\u2028-\\u202F\\u205F-\\u2064\\u3000\\uFEFF]+');
  assert.ok(functionBody('warehouse_security.trimmed_reason').includes(`'^${written}|${written}$'`),
    `trimmed_reason does not trim with ${written} at both ends`);
});

test('invisible characters appear only in the two trim classes that are meant to hold them', () => {
  const invisible = new RegExp('[\\u00A0\\u00AD\\u180E\\u200B-\\u200F\\u2028-\\u202F\\u205F-\\u2064\\u3000\\uFEFF]');
  const classes = [/\[\^?\\s\\u0085[^\]]*\]/, /\[\\u0080-\\u009F[^\]]*\]/];
  const stray = baseline.split('\n').flatMap((line, index) => invisible.test(line) && !classes.some(pattern => pattern.test(line)) ? [`line ${index + 1}: ${escaped(line).slice(0, 160)}`] : []);
  assert.deepEqual(stray, []);
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
