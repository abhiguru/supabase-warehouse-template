import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';

const script = readFileSync(new URL('../health-check.sh', import.meta.url), 'utf8');
// The probe is `compose exec -T functions bash -c '<payload>'`; extract the payload to run it for real.
const match = /compose exec -T functions bash -c '([^']+)'/.exec(script);

function run(payload) {
  return new Promise(resolve => {
    const child = spawn('bash', ['-c', payload]);
    child.on('close', code => resolve(code));
  });
}

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

test('the renderer probe runs in the function runtime, the path PDFs take, and reports the same output line', () => {
  assert.ok(match, 'health-check.sh probes the renderer from functions with bash -c');
  assert.match(script, /^  echo 'PDF renderer: available'$/m);
  assert.match(script, /PDF renderer: not reachable from functions/);
  assert.match(match[1], /\/dev\/tcp\/pdf-renderer\/3000/);
});

test('the probe payload succeeds on a 200 /health, fails on a 503 and when nothing listens', async () => {
  const payload = port => match[1].replace('/dev/tcp/pdf-renderer/3000', `/dev/tcp/127.0.0.1/${port}`);
  const up = await serve(200);
  assert.equal(await run(payload(up.address().port)), 0);
  up.close();
  const down = await serve(503);
  assert.notEqual(await run(payload(down.address().port)), 0);
  const port = down.address().port;
  down.close();
  assert.notEqual(await run(payload(port)), 0, 'a closed port is a failure');
});

test('the container state template reads Health with index, which a docker CLI accepts for a container without a healthcheck', () => {
  const format = /docker inspect --format '([^']+)'/.exec(script);
  assert.ok(format, 'health-check.sh reads the container state with docker inspect --format');
  assert.doesNotMatch(format[1], /\.State\.Health/, 'a direct .State.Health fails with "map has no entry for key Health"');
  assert.match(format[1], /\{\{with index \.State "Health"\}\}\{\{index \. "Status"\}\}\{\{end\}\}/);
  // The output shape the checks below it expect stays "<status> <health>".
  assert.match(format[1], /^\{\{\.State\.Status\}\} /);
});
