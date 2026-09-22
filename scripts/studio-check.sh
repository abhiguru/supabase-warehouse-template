#!/usr/bin/env bash
# Read-only acceptance of this checkout's Studio and postgres-meta pair.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node "$ROOT/scripts/check-demo-config.mjs"
bash "$ROOT/scripts/compose.sh" exec -T studio node --input-type=module <<'NODE'
import assert from 'node:assert/strict';
const request = (url, options = {}) => fetch(url, { ...options, signal: AbortSignal.timeout(30000) });
const page = await request('http://studio:3000/project/default');
assert.equal(page.status, 200, 'Studio project page');
const html = await page.text();
const asset = html.match(/src="([^" ]*\/_next\/static\/[^" ]+\.js)"/);
assert.ok(asset, 'Studio page references a JavaScript asset');
assert.equal((await request(new URL(asset[1], 'http://studio:3000'))).status, 200, 'Studio JavaScript asset');
assert.equal((await request('http://studio:3000/api/platform/profile')).status, 200, 'Studio profile');
const projects = await request('http://studio:3000/api/platform/projects');
assert.equal(projects.status, 200, 'Studio project inventory');
assert.ok((await projects.json()).some(project => project.ref === 'default'), 'Default local project present');
const tables = await request('http://meta:8080/tables?included_schemas=public');
assert.equal(tables.status, 200, 'Metadata table inventory');
assert.ok((await tables.json()).some(table => table.name === 'orders'), 'Warehouse orders table visible');
const query = await request('http://meta:8080/query', {
  method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: 'SELECT 1 AS warehouse_probe' })
});
assert.equal(query.status, 200, 'Metadata read-only query');
assert.equal((await query.json())[0].warehouse_probe, 1, 'Metadata query result');
console.log('Studio page/asset/profile/project and metadata table/query checks passed.');
NODE
