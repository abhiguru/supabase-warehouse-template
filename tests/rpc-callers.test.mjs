import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// tests/rpc_callers_exist.sql lists the functions that the edge functions and the app call and proves, on the migrated database, that
// none was dropped. This keeps those lists equal to the code.
const root = fileURLToPath(new URL('..', import.meta.url));
const sql = readFileSync(join(root, 'tests/rpc_callers_exist.sql'), 'utf8');
const listed = (heading) => {
  const start = sql.indexOf(heading);
  const block = sql.slice(start, sql.indexOf(']) AS n', start));
  return new Set([...block.matchAll(/'([a-z_0-9]+)'/g)].map(m => m[1]));
};
const edgeListed = listed('-- The edge functions');
const appListed = listed('-- The app (src/ and app/)');

function sources(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === 'vendor' ? [] : sources(path);
    return /\.ts$/.test(entry.name) && !/\.test\./.test(entry.name) ? [path] : [];
  });
}

test('every RPC an edge function calls is in the list of rpc_callers_exist.sql', () => {
  const called = new Set();
  for (const file of sources(join(root, 'functions'))) {
    const text = readFileSync(file, 'utf8');
    for (const m of text.matchAll(/\brpc\((?:deps,\s*)?'([a-z_0-9]+)'/g)) called.add(m[1]);
    for (const m of text.matchAll(/\/rest\/v1\/rpc\/([a-z_0-9]+)/g)) called.add(m[1]);
  }
  assert.ok(called.size >= 10, 'the edge calls were found: ' + [...called]);
  assert.deepEqual([...called].filter(name => !edgeListed.has(name)), []);
});

// Set MOBILE_CHECKOUT to an app checkout (with its node_modules: the scanner uses the app's TypeScript) to compare the app's literal
// RPC names too. The contract job of ci.yml sets it.
test('every RPC the app calls is in the list of rpc_callers_exist.sql', { skip: !process.env.MOBILE_CHECKOUT || !existsSync(process.env.MOBILE_CHECKOUT || '') }, () => {
  const scratch = mkdtempSync(join(tmpdir(), 'rpc-callers-'));
  try {
    const report = join(scratch, 'report.json');
    // The scanner exits 1 when a name is missing from the migrations; the report is written either way.
    const run = spawnSync(process.execPath, [join(root, 'scripts/check-mobile-contract.mjs'), process.env.MOBILE_CHECKOUT, '--output', report], { encoding: 'utf8' });
    assert.ok(existsSync(report), `the contract scanner wrote no report: ${run.stderr}`);
    const names = new Set(JSON.parse(readFileSync(report, 'utf8')).calls.map(call => call.name).filter(Boolean));
    assert.ok(names.size > 50, 'the scanner found the app\'s calls');
    assert.deepEqual([...names].filter(name => !appListed.has(name)), []);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});
