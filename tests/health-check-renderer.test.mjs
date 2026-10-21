import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { checkPdfRenderer } from '../scripts/watch.mjs';

const watch = readFileSync(new URL('../scripts/watch.mjs', import.meta.url), 'utf8');
const wrapper = readFileSync(new URL('../health-check.sh', import.meta.url), 'utf8');

// The probe is `compose exec -T functions bash -c '<PDF_PROBE>'` (checkPdfRenderer in scripts/watch.mjs). The payload is read from
// the source and run for real against a local server standing in for pdf-renderer:3000.
const probe = /const PDF_PROBE = '([^']+)'/.exec(watch)[1].replace(/\\\\/g, '\\');
const run = port => new Promise(resolve => spawn('bash', ['-c', probe.replace('/dev/tcp/pdf-renderer/3000', `/dev/tcp/127.0.0.1/${port}`)]).on('close', resolve));

function serve(status) {
  return new Promise(resolve => {
    const server = http.createServer((request, response) => {
      assert.equal(request.url, '/health');
      assert.equal(request.headers.host, 'pdf-renderer');
      response.writeHead(status, { 'content-type': 'application/json' });
      response.end('{"status":"up"}');
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

test('the renderer probe runs in the function runtime, the path PDFs take', () => {
  assert.match(probe, /\/dev\/tcp\/pdf-renderer\/3000/);
  assert.match(watch, /ctx\.compose\(\['exec', '-T', 'functions', 'bash', '-c', PDF_PROBE\]\)/);
});

test('the probe succeeds on a 200 /health, fails on a 503 and when nothing listens', async () => {
  const up = await serve(200);
  assert.equal(await run(up.address().port), 0);
  up.close();
  const down = await serve(503);
  assert.notEqual(await run(down.address().port), 0);
  const port = down.address().port;
  down.close();
  assert.notEqual(await run(port), 0, 'a closed port is a failure');
});

test('the check function reports the probe result with its wording and the place to look', () => {
  const failed = checkPdfRenderer({ compose: () => ({ status: 1 }) })[0];
  assert.equal(failed.ok, false);
  assert.equal(failed.summary, 'PDF renderer is not reachable from functions');
  assert.match(failed.detail, /network renderer/);
  assert.equal(checkPdfRenderer({ compose: () => ({ status: 0 }) })[0].ok, true);
});

test('the container state template reads Health with index, which a docker CLI accepts for a container without a healthcheck', () => {
  const format = /const INSPECT_FORMAT = \[([^\]]+)\]/.exec(watch);
  assert.ok(format, 'watch.mjs reads the container state with docker inspect --format');
  assert.doesNotMatch(format[1], /\.State\.Health/, 'a direct .State.Health fails with "map has no entry for key Health"');
  assert.match(format[1], /\{\{with index \.State "Health"\}\}\{\{index \. "Status"\}\}\{\{end\}\}/);
});

test('health-check.sh is a thin wrapper: the checks live in watch.mjs, and a failure adds the service diagnostics', () => {
  assert.match(wrapper, /node "\$ROOT\/scripts\/watch\.mjs" health "\$@"/);
  assert.match(wrapper, /scripts\/service-diagnostics\.mjs" kong functions rest/);
  assert.ok(wrapper.split('\n').filter(line => line.trim() && !line.startsWith('#')).length <= 10, 'no check logic is left in the wrapper');
});
