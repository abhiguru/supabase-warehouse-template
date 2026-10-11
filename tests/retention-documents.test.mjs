import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Expired generated PDFs: the database names them, the Storage API deletes them.
// The removal script is run exactly as scripts/retention.sh runs it inside the
// storage container (`node -e <file>`), here against a stand-in Storage API.
const root = new URL('..', import.meta.url).pathname;
const removalScript = readFileSync(join(root, 'scripts/remove-expired-documents.cjs'), 'utf8');
const names = Array.from({ length: 250 }, (_, index) =>
  `grn/00000000-0000-4000-8000-${String(index).padStart(12, '0')}/11111111-1111-4111-8111-111111111111.pdf`);

function storageApi(status = 200) {
  const requests = [];
  const server = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', chunk => chunks.push(chunk));
    request.on('end', () => {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
      requests.push({ method: request.method, url: request.url, authorization: request.headers.authorization, body });
      response.writeHead(status, { 'Content-Type': 'application/json' });
      response.end(status === 200 ? JSON.stringify((body.prefixes || []).map(name => ({ name }))) : '{"error":"unavailable"}');
    });
  });
  return new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve({ server, requests, url: `http://127.0.0.1:${server.address().port}` })));
}

function runRemoval(env, input) {
  return new Promise(resolve => {
    const child = spawn(process.execPath, ['-e', removalScript], { env: { PATH: process.env.PATH, ...env } });
    let stdout = ''; let stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('close', status => resolve({ status, stdout, stderr }));
    child.stdin.end(input);
  });
}

test('expired documents are deleted through the Storage API in batches with the service key', async () => {
  const api = await storageApi();
  try {
    const result = await runRemoval({ STORAGE_API_URL: api.url, SERVICE_KEY: 'fictional-service-key' }, names.join('\n') + '\n');
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /removed from storage: 250 of 250/);
    assert.deepEqual(api.requests.map(request => [request.method, request.url, request.body.prefixes.length]),
      [['DELETE', '/object/documents', 100], ['DELETE', '/object/documents', 100], ['DELETE', '/object/documents', 50]]);
    assert.ok(api.requests.every(request => request.authorization === 'Bearer fictional-service-key'));
    assert.deepEqual(api.requests.flatMap(request => request.body.prefixes), names, 'every name is sent once, in order');
  } finally { api.server.close(); }
});

test('a Storage API refusal or a missing key fails the removal', async () => {
  const api = await storageApi(500);
  try {
    const refused = await runRemoval({ STORAGE_API_URL: api.url, SERVICE_KEY: 'fictional-service-key' }, names.slice(0, 3).join('\n'));
    assert.equal(refused.status, 1);
    assert.match(refused.stderr, /Document removal failed: Storage API answered HTTP 500/);
    const keyless = await runRemoval({ STORAGE_API_URL: api.url }, names[0]);
    assert.equal(keyless.status, 1);
    assert.match(keyless.stderr, /SERVICE_KEY is not set/);
    assert.equal(api.requests.length, 1, 'no request without a key');
  } finally { api.server.close(); }
});

// scripts/retention.sh with a stand-in docker: which commands it runs in each mode.
function retention(mode, { expired, remaining = '0' }) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-retention-test-'));
  try {
    const state = join(scratch, 'state');
    for (const path of [state, join(state, 'config'), join(state, 'data'), join(state, 'data/db'), join(state, 'data/storage')]) mkdirSync(path, { recursive: true, mode: 0o700 });
    writeFileSync(join(state, 'config/compose.env'), `WAREHOUSE_PROJECT_NAME=warehouse-retention-test\nWAREHOUSE_DB_PATH=${state}/data/db\nWAREHOUSE_STORAGE_PATH=${state}/data/storage\n`, { mode: 0o600 });
    const bin = join(scratch, 'bin');
    mkdirSync(bin);
    const log = join(scratch, 'docker.log');
    const received = join(scratch, 'storage-stdin');
    writeFileSync(join(scratch, 'expired'), expired.length ? expired.join('\n') + '\n' : '');
    writeFileSync(join(bin, 'docker'), `#!/bin/sh
case "$*" in
  *'exec -T storage node -e'*) printf 'storage-delete\\n' >> "$FAKE_DOCKER_LOG"; cat > "$FAKE_STORAGE_STDIN" ;;
  *'SELECT count(*) FROM warehouse_maintenance.expired_generated_documents'*) printf 'remaining-count\\n' >> "$FAKE_DOCKER_LOG"; printf '%s\\n' "$FAKE_REMAINING" ;;
  *'SELECT name FROM warehouse_maintenance.expired_generated_documents'*) printf 'list-expired\\n' >> "$FAKE_DOCKER_LOG"; cat "$FAKE_EXPIRED" ;;
  *"retention_policy WHERE key='generated_documents'"*) printf '7\\n' ;;
  *'run_database_retention(now(), true)'*) printf 'database-apply\\n' >> "$FAKE_DOCKER_LOG" ;;
  *'run_database_retention(now(), false)'*) printf 'database-preview\\n' >> "$FAKE_DOCKER_LOG" ;;
esac
`, { mode: 0o700 });
    const result = spawnSync('bash', [join(root, 'scripts/retention.sh'), mode], { encoding: 'utf8', env: {
      ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log,
      FAKE_STORAGE_STDIN: received, FAKE_EXPIRED: join(scratch, 'expired'), FAKE_REMAINING: remaining,
    } });
    const read = path => { try { return readFileSync(path, 'utf8'); } catch { return ''; } };
    return { ...result, calls: read(log).trim().split('\n').filter(Boolean), sent: read(received) };
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

test('retention preview counts expired documents and deletes nothing', () => {
  const result = retention('preview', { expired: names.slice(0, 3) });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.calls, ['database-preview', 'list-expired']);
  assert.match(result.stdout, /Generated documents older than 7 days: 3/);
  assert.match(result.stdout, /Preview only; no data changed\./);
});

test('retention apply sends the expired names to the storage container and checks none remain', () => {
  const result = retention('apply', { expired: names.slice(0, 3) });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.calls, ['database-apply', 'list-expired', 'storage-delete', 'remaining-count']);
  assert.equal(result.sent, names.slice(0, 3).join('\n') + '\n');
  assert.match(result.stdout, /expired generated documents removed/);
});

test('retention apply with nothing expired does not call the storage container', () => {
  const result = retention('apply', { expired: [] });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.calls, ['database-apply', 'list-expired']);
  assert.match(result.stdout, /Generated documents older than 7 days: 0/);
});

test('retention apply fails when expired documents are still stored afterwards', () => {
  const result = retention('apply', { expired: names.slice(0, 3), remaining: '2' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /2 generated documents older than 7 days are still stored/);
});
