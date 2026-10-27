// The collation check of `node scripts/doctor.mjs` (collationProblem in scripts/doctor-common.mjs): the version PostgreSQL recorded
// for the postgres database against what the database image's C library reports now. A fake psql answer stands in for the database.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { COLLATION_SQL, collationProblem } from '../scripts/doctor-common.mjs';

const answer = output => args => { answer.last = args; return { ok: true, output }; };
const MESSAGE = "collation version changed; REINDEX required before use — see docs/OPERATOR_INSTALL.md 'Collation changes'";

test('doctor collation: differing recorded and actual versions fail with the message that names the repair', () => {
  const problem = collationProblem(answer('2.36|2.41\n'));
  assert.ok(problem.startsWith(MESSAGE), problem);
  assert.match(problem, /recorded 2\.36, now 2\.41/);
  assert.match(collationProblem(answer('2.36|\n')), /now unknown/, 'a library that reports nothing is a change too');
});

test('doctor collation: equal versions, or none recorded (the C locale), pass', () => {
  assert.equal(collationProblem(answer('2.41|2.41\n')), null);
  assert.equal(collationProblem(answer('|\n')), null);
  assert.equal(collationProblem(answer('|2.41\n')), null, 'nothing recorded means nothing to compare');
});

test('doctor collation: asks the postgres database as supabase_admin, and an unreadable answer is an error, not a pass', () => {
  collationProblem(answer('2.41|2.41\n'));
  assert.deepEqual(answer.last.slice(0, 1), ['psql']);
  assert.ok(answer.last.includes('supabase_admin') && answer.last.includes('postgres') && answer.last.includes(COLLATION_SQL));
  assert.match(COLLATION_SQL, /pg_database_collation_actual_version\(oid\)/);
  assert.match(COLLATION_SQL, /datname = 'postgres'/);
  assert.throws(() => collationProblem(() => ({ ok: false, output: '' })), /Could not read the collation version/);
  assert.throws(() => collationProblem(answer('garbage\n')), /Could not read the collation version/);
  assert.throws(() => collationProblem(answer('')), /Could not read the collation version/);
});

test('doctor runs the collation check after the health check, and the guide it names has that section', () => {
  const doctor = readFileSync(new URL('../scripts/doctor.mjs', import.meta.url), 'utf8');
  const health = doctor.indexOf('const health = await runHealth');
  const check = doctor.indexOf('databaseCollationProblem();');
  assert.ok(health > 0 && check > health, 'called after the health check has shown the database is up');
  assert.match(doctor, /if \(collation\) throw new Error\(collation\)/, 'a mismatch fails the doctor');
  assert.match(readFileSync(new URL('../docs/OPERATOR_INSTALL.md', import.meta.url), 'utf8'), /^### Collation changes$/m);
});

test('doctor collation: an unreadable answer is tried three times, 2 s apart, then fails closed with what to run', () => {
  let calls = 0; const pauses = [];
  const flaky = failures => () => (++calls <= failures ? { ok: false, output: '' } : { ok: true, output: '2.41|2.41\n' });
  assert.equal(collationProblem(flaky(2), ms => pauses.push(ms)), null, 'the third try answers');
  assert.equal(calls, 3); assert.deepEqual(pauses, [2000, 2000]);
  calls = 0; pauses.length = 0;
  assert.throws(() => collationProblem(flaky(99), ms => pauses.push(ms)), error => /Could not read the collation version/.test(error.message)
    && /doctor\.mjs --local again/.test(error.message) && /Collation changes/.test(error.message));
  assert.equal(calls, 3, 'three tries and no more'); assert.deepEqual(pauses, [2000, 2000]);
  calls = 0; pauses.length = 0;
  collationProblem(() => { calls++; return { ok: true, output: '2.41|2.41\n' }; }, ms => pauses.push(ms));
  assert.equal(calls, 1); assert.deepEqual(pauses, [], 'an answer at once costs no wait');
});
