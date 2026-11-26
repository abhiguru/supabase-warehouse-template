// WH-303, the parts of the "edit GRN by field changes" backend that need no database (contract ~/ws/fresh/product/tech/app-offline-edit-grn.md,
// 5.2, 5.4, 5.7). Written before the build: the "exists" cases fail until Development's migration lands, by design.
//   - Product PQ7 / case B11b: the server never deletes a replaced entry: no migration, definition or script deletes from, truncates or
//     drops grn_replacements (the table is the GRN's edit record), and the retention script does not name it.
//   - 5.4 / the repo rules: the table enables RLS and the app roles hold no grant on it; the three new functions call
//     warehouse_security.authorize_rpc first and set search_path; update_grn (5.7) refuses QTY_BELOW_DISPATCHED instead of skipping.
// The SQL behaviour is proved by tests/grn_edit_field_changes.sql, tests/grn_replacements_admin.sql, tests/sync_feed_grn_replacements.sql,
// tests/grn_edit_lines.sql and tests/grn_qty_invoiced_lock.sql in tests/migrations.sh.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const read = path => readFileSync(join(root, path), 'utf8');
const TABLE = 'grn_replacements';

function shippedFiles() {
  const files = [];
  const walk = dir => {
    for (const entry of readdirSync(join(root, dir), { withFileTypes: true })) {
      const path = `${dir}/${entry.name}`;
      if (entry.isDirectory()) { if (entry.name !== 'node_modules') walk(path); } else if (/\.(sql|sh|mjs|cjs|ts)$/.test(entry.name)) files.push(path);
    }
  };
  for (const dir of ['migrations', 'scripts', 'functions']) walk(dir);
  return files;
}
// Every shipped SQL text (migrations and definitions), comments dropped, with its path.
const sqlFiles = () => shippedFiles().filter(path => path.endsWith('.sql')).map(path => ({ path, text: read(path).replace(/^\s*--.*$/gm, '') }));

test('B11b: nothing shipped deletes, truncates or drops the replaced entries; the retention script does not name the table', () => {
  const files = shippedFiles();
  assert.ok(files.includes('scripts/retention.sh') && files.includes('migrations/definitions/update_grn.sql'), 'the walk reaches the scripts and the definitions');
  const removal = new RegExp(`\\b(?:DELETE\\s+FROM(?:\\s+ONLY)?|TRUNCATE(?:\\s+TABLE)?(?:\\s+ONLY)?|DROP\\s+TABLE(?:\\s+IF\\s+EXISTS)?)\\s+(?:public\\.)?${TABLE}\\b`, 'i');
  const offenders = files.filter(path => removal.test(read(path).replace(/^\s*(?:--|#).*$/gm, '')));
  assert.deepEqual(offenders, [], `${TABLE} is deleted from in: ${offenders.join(', ')}`);
  assert.equal(read('scripts/retention.sh').includes(TABLE), false, 'retention.sh names no table of replaced entries');
});

test('5.4: a migration creates grn_replacements with the contract columns, RLS on, and no grant to the app roles', () => {
  const create = sqlFiles().filter(({ text }) => new RegExp(`CREATE\\s+TABLE(?:\\s+IF\\s+NOT\\s+EXISTS)?\\s+public\\.${TABLE}\\b`, 'i').test(text));
  assert.equal(create.length, 1, `exactly one migration creates public.${TABLE}`);
  const { text } = create[0];
  for (const column of ['id', 'grn_id', 'lot_id', 'customer_id', 'kind', 'field', 'newer_value', 'newer_by', 'newer_at', 'sent_value', 'sent_by', 'sent_at',
    'recorded_at', 'request_key', 'checked_by', 'checked_at']) {
    assert.match(text, new RegExp(`^\\s*${column}\\s+[a-z]`, 'mi'), `column ${column}`);
  }
  assert.match(text, new RegExp(`ALTER\\s+TABLE\\s+(?:ONLY\\s+)?public\\.${TABLE}\\s+ENABLE\\s+ROW\\s+LEVEL\\s+SECURITY`, 'i'), 'RLS is enabled');
  assert.match(text, new RegExp(`REVOKE\\s+ALL\\s+ON\\s+(?:TABLE\\s+)?public\\.${TABLE}\\s+FROM\\s+(?:PUBLIC|anon|authenticated)`, 'i'), 'default grants are revoked');
  assert.doesNotMatch(text, new RegExp(`GRANT\\s+(?:ALL|SELECT|INSERT|UPDATE|DELETE)[^;]*ON\\s+(?:TABLE\\s+)?public\\.${TABLE}\\s+TO\\s+(?:anon|authenticated)`, 'i'), 'no direct grant to the app roles');
});

for (const name of ['apply_grn_changes', 'get_grn_replacements', 'mark_grn_replacements_checked']) {
  test(`5.2 / 5.4: public.${name} exists, calls authorize_rpc first, sets search_path and is granted explicitly`, () => {
    const defs = sqlFiles().filter(({ text }) => new RegExp(`CREATE\\s+(?:OR\\s+REPLACE\\s+)?FUNCTION\\s+public\\.${name}\\s*\\(`, 'i').test(text));
    assert.ok(defs.length >= 1, `a migration or definition creates public.${name}`);
    const { text } = defs[defs.length - 1];
    const start = text.search(new RegExp(`CREATE\\s+(?:OR\\s+REPLACE\\s+)?FUNCTION\\s+public\\.${name}\\s*\\(`, 'i'));
    const body = text.slice(start);
    assert.match(body, /SET\s+search_path/i, 'search_path is set');
    const guard = body.search(new RegExp(`warehouse_security\\.authorize_rpc\\(\\s*'${name}'`));
    assert.ok(guard > 0, `${name} calls warehouse_security.authorize_rpc('${name}', ...)`);
    assert.equal(body.slice(0, guard).includes('INSERT INTO') || body.slice(0, guard).includes('UPDATE '), false, 'nothing is written before the guard');
    assert.match(text, new RegExp(`GRANT\\s+EXECUTE\\s+ON\\s+FUNCTION\\s+public\\.${name}\\([^)]*\\)\\s+TO\\s+authenticated`, 'i'), 'granted to authenticated');
    assert.doesNotMatch(text, new RegExp(`GRANT\\s+EXECUTE\\s+ON\\s+FUNCTION\\s+public\\.${name}\\([^)]*\\)\\s+TO\\s+(?:anon|PUBLIC)`, 'i'), 'not granted to anon or PUBLIC');
  });
}

test('5.7 / PQ2: update_grn refuses a quantity below what has left with QTY_BELOW_DISPATCHED and no longer lists a skip', () => {
  const body = read('migrations/definitions/update_grn.sql').replace(/^\s*--.*$/gm, '');
  assert.match(body, /warehouse_security\.refuse\(\s*'QTY_BELOW_DISPATCHED'/, 'the refusal exists');
  assert.match(body, /to_jsonb\('qty'::text\)/, 'LOT_INVOICED also names qty among the locked fields');
  assert.doesNotMatch(body, /Cannot update qty\/stock - item has/, 'the silent-skip reason text is gone');
});
