import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const script = readFileSync(new URL('../scripts/data-fingerprint.sh', import.meta.url), 'utf8');

test('every sort in the data fingerprint uses the C collation, so it does not depend on the database collation', () => {
  // Under en_US, "a" sorts before "B"; under C, "B" sorts before "a" (tests/fingerprint_collation.sql proves
  // the two differ in the database). A fingerprint that sorted by the database default would change with a glibc
  // or major-version change and a restored copy would not compare equal.
  const orders = script.split('\n').filter(line => line.includes('ORDER BY'))
    .map(line => line.slice(line.indexOf('ORDER BY') + 8).split(/\), ''|"\)$/)[0].replace(/\\"/g, '"'));
  assert.equal(orders.length, 5, 'expected the --counts, table-name, row, storage objects and storage buckets sorts');
  for (const order of orders) {
    const keys = order.replace(/format\([^)]*\)/, 'name_expression').split(',').map(k => k.trim());
    for (const key of keys) assert.match(key, /COLLATE "C"$/, `sort key without COLLATE "C": ${key}`);
    assert.equal(keys.length, order.includes('bucket_id') ? 2 : 1);
  }
});

test('--all is accepted and anything else is refused', () => {
  assert.match(script, /--all\) all=true/);
  assert.match(script, /Usage: data-fingerprint\.sh \[--all \| --counts\]/);
  assert.match(script, /n\.nspname IN \('public', 'warehouse_security', 'warehouse_maintenance'\)/);
});

test('--counts sorts by the qualified name (a text expression, never an ORDER BY position) and is read-only', () => {
  assert.match(script, /--counts\) counts=true/);
  assert.match(script, /ORDER BY \(n\.nspname \|\| '\.' \|\| c\.relname\) COLLATE "C"/);
  assert.doesNotMatch(script, /ORDER BY 1\b/, 'ORDER BY 1 COLLATE "C" fails: collations are not supported by type integer');
  // The counts block exits before the hashing: it prints counts only, no stored files.
  assert.ok(script.indexOf('exit 0') < script.indexOf('names=()'));
});

test('--counts prints one "schema.table count" line per table, sorted in the C collation (fake docker)', () => {
  const dir = mkdtempSync(join(tmpdir(), 'fp-counts-'));
  try {
    writeFileSync(join(dir, 'docker'), `#!/bin/sh
printf '%s\\n' "$*" >> "${dir}/calls"
case "$*" in *"exec -T db psql"*) printf 'public.a 1\\n' ;; esac
`, { mode: 0o755 });
    mkdirSync(join(dir, 'config'), { mode: 0o700 });
    mkdirSync(join(dir, 'data/db'), { recursive: true });
    mkdirSync(join(dir, 'data/storage'));
    writeFileSync(join(dir, 'config/compose.env'), `WAREHOUSE_PROJECT_NAME=warehouse-fp-counts-test\nWAREHOUSE_DB_PATH=${dir}/data/db\nWAREHOUSE_STORAGE_PATH=${dir}/data/storage\n`, { mode: 0o600 });
    const r = spawnSync('bash', [new URL('../scripts/data-fingerprint.sh', import.meta.url).pathname, '--counts'],
      { env: { PATH: `${dir}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: dir }, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout, 'public.a 1\n');
    const calls = readFileSync(join(dir, 'calls'), 'utf8');
    assert.equal(calls.split('\n').filter(l => l.includes('exec -T db psql')).length, 1, 'one query');
    assert.doesNotMatch(calls, /storage sh -c/, 'no stored-file hashing in --counts');
    assert.match(calls, /ORDER BY \(n\.nspname \|\| '\.' \|\| c\.relname\) COLLATE "C"/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('an unknown argument exits 2 before touching anything', () => {
  const r = spawnSync('bash', [new URL('../scripts/data-fingerprint.sh', import.meta.url).pathname, '--bogus'],
    { env: { PATH: process.env.PATH, WAREHOUSE_STATE_DIR: '/nonexistent-state-dir' }, encoding: 'utf8' });
  assert.equal(r.status, 2);
  assert.match(r.stderr, /Usage: data-fingerprint\.sh \[--all \| --counts\]/);
});

test('the fingerprint pins the session settings that shape row text', () => {
  for (const setting of ["TimeZone='UTC'", "DateStyle='ISO, MDY'", 'extra_float_digits=1', "bytea_output='hex'", "IntervalStyle='postgres'"])
    assert.ok(script.includes(`SET ${setting}`), setting);
});

// The append-only records the owner asked for (discount, zero charge, item prices): a restore that loses them must not compare as identical.
test('the data fingerprint covers the three histories beside the business tables', () => {
  const list = script.match(/^tables=\(([^)]*)\)/m);
  assert.ok(list, 'data-fingerprint.sh has no tables=(...) list');
  const tables = list[1].split(/\s+/).filter(Boolean);
  for (const table of ['customers', 'users_customers_new', 'items', 'item_storage_prices', 'goodsreceived', 'goodsreceived_trl', 'grn_images',
    'dispatch', 'dispatch_trl', 'dispatch_images', 'invoice', 'invoice_trl', 'stock_movements', 'user_profiles',
    'invoice_discount_history', 'invoice_zero_charge_history', 'item_price_history',
    'standard_rate_tiers', 'grn_rates', 'payments', 'orders', 'order_items', 'order_revisions']) {
    assert.ok(tables.includes(table), `${table} is not fingerprinted`);
  }
  assert.equal(new Set(tables).size, tables.length);
});
