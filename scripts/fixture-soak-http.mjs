// Optional read-only observation. Raw Kong lines may contain query credentials;
// they remain in memory. Ordinary startup never invokes this fixture helper.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { resolve, isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';
import { validateSince, summarizeRpcAccess } from './fixture-soak-observation.mjs';
const checkout = process.env.WAREHOUSE_FIXTURE_CHECKOUT;
assert.ok(checkout && isAbsolute(checkout), 'Explicit owning fixture checkout required');
const { operatorFixture } = await import(pathToFileURL(resolve(checkout, 'tests/operator-fixture.mjs')).href);
const { env } = operatorFixture();
const since = process.argv[2];
validateSince(since);
const r = spawnSync('docker', ['logs', '--since', since, `${env.WAREHOUSE_PROJECT_NAME}-kong-1`],
  { encoding: 'utf8', timeout: 20000, maxBuffer: 8 * 1024 * 1024 });
assert.equal(r.status, 0, 'Owned Kong observation failed; raw logs suppressed');
const d = summarizeRpcAccess(r.stdout + '\n' + r.stderr);
assert.ok(d.successfulOrdersRequests > 0, 'No actual Orders RPC200 after forced refresh');
assert.ok(!d.failedObservedRequests.some(x => x.status >= 500), 'Actual observed native RPC5xx');
console.log(JSON.stringify({ status: 'PASS', ...d }));
