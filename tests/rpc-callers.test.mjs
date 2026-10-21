import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
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

// Set MOBILE_CHECKOUT to an app checkout to compare the app's literal RPC names too.
test('every RPC the app calls is in the list of rpc_callers_exist.sql', { skip: !process.env.MOBILE_CHECKOUT || !existsSync(process.env.MOBILE_CHECKOUT || '') }, async () => {
  const { details } = await import('../scripts/contract-details.mjs');
  const mobile = process.env.MOBILE_CHECKOUT;
  const files = ['src', 'app'].flatMap(dir => existsSync(join(mobile, dir)) ? sources2(join(mobile, dir)) : []);
  const inventory = details(mobile, files, root, false);
  const names = new Set(inventory.calls.map(call => call.name).filter(Boolean));
  assert.deepEqual([...names].filter(name => !appListed.has(name)), []);
});

function sources2(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name);
    if (entry.name === '__tests__' || /\.(test|spec)\./.test(entry.name)) return [];
    if (entry.isDirectory()) return sources2(path);
    return /\.tsx?$/.test(entry.name) ? [path] : [];
  });
}
