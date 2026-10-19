import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const script = readFileSync(new URL('../scripts/data-fingerprint.sh', import.meta.url), 'utf8');

test('every sort in the data fingerprint uses the C collation, so it does not depend on the database collation', () => {
  // Under en_US, "a" sorts before "B"; under C, "B" sorts before "a" (tests/fingerprint_collation.sql proves
  // the two differ in the database). A fingerprint that sorted by the database default would change with a glibc
  // or major-version change and a restored copy would not compare equal.
  const orders = script.split('\n').filter(line => line.includes('ORDER BY'))
    .map(line => line.slice(line.indexOf('ORDER BY') + 8).split(/\), ''|"\)$/)[0].replace(/\\"/g, '"'));
  assert.equal(orders.length, 4, 'expected the table-name, row, storage objects and storage buckets sorts');
  for (const order of orders) {
    const keys = order.replace(/format\([^)]*\)/, 'name_expression').split(',').map(k => k.trim());
    for (const key of keys) assert.match(key, /COLLATE "C"$/, `sort key without COLLATE "C": ${key}`);
    assert.equal(keys.length, order.includes('bucket_id') ? 2 : 1);
  }
});

test('--all is accepted and anything else is refused', () => {
  assert.match(script, /--all\) all=true/);
  assert.match(script, /Usage: data-fingerprint\.sh \[--all\]/);
  assert.match(script, /n\.nspname IN \('public', 'warehouse_security', 'warehouse_maintenance'\)/);
});

test('an unknown argument exits 2 before touching anything', () => {
  const r = spawnSync('bash', [new URL('../scripts/data-fingerprint.sh', import.meta.url).pathname, '--bogus'],
    { env: { PATH: process.env.PATH, WAREHOUSE_STATE_DIR: '/nonexistent-state-dir' }, encoding: 'utf8' });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /Usage: data-fingerprint\.sh \[--all\]/);
});

test('the fingerprint pins the session settings that shape row text', () => {
  for (const setting of ["TimeZone='UTC'", "DateStyle='ISO, MDY'", 'extra_float_digits=1', "bytea_output='hex'", "IntervalStyle='postgres'"])
    assert.ok(script.includes(`SET ${setting}`), setting);
});
