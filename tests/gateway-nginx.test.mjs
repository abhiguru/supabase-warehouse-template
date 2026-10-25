import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash, randomBytes } from 'node:crypto';
import { gunzipSync } from 'node:zlib';
import { spawnSync } from 'node:child_process';
import { signRoleKey } from '../scripts/keys.mjs';

// The real gateway image (docker/nginx), built from its recipe: `nginx -t` on the rendered configuration, the entrypoint's refusal of
// a value that could change the configuration, and every route against stand-in upstreams on a throwaway network. Nothing here
// touches an installation: the containers, the network and the image are named for this run and removed at the end.
// tests/gateway-config.test.mjs reads the same files as text; tests/gateway-smoke.mjs checks a running installation.
const repo = new URL('..', import.meta.url).pathname;
const docker = (args, options = {}) => spawnSync('docker', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 300000, ...options });
const skip = spawnSync('docker', ['version', '--format', '{{.Server.Version}}'], { encoding: 'utf8' }).status !== 0 && !process.env.CI ? 'docker is not available' : false;

const id = randomBytes(4).toString('hex');
const IMAGE = `warehouse-gateway-test:${id}`;
const NETWORK = `wg-test-${id}`;
const STUB = `wg-test-${id}-stub`;
const GATEWAY = `wg-test-${id}-gateway`;
const GATEWAY_MEMORY = `wg-test-${id}-memory`;
const ORIGIN = 'https://app.example.test';
// Fictional API keys, minted here from a throwaway secret so no token-shaped literal sits in the source
// (the secret scan treats any JWT literal as a leak, and the gateway only compares the strings).
const TEST_SECRET = createHash('sha384').update('warehouse gateway lab test').digest('hex');   // 96 hex characters, as scripts/keys.mjs requires; derived, so no key-shaped literal
const ANON = signRoleKey(TEST_SECRET, 'anon');
const SERVICE = signRoleKey(TEST_SECRET, 'service_role');
const environment = (overrides = {}) => Object.entries({ CORS_ALLOWED_ORIGIN: ORIGIN, ANON_KEY: ANON, SERVICE_ROLE_KEY: SERVICE, ...overrides })
  .filter(([, value]) => value !== undefined).flatMap(([name, value]) => ['-e', `${name}=${value}`]);
// The flags of the Compose service (docker/docker-compose.yml): read-only root, no capability, the two tmpfs.
const HARDENING = ['--read-only', '--tmpfs', '/tmp:size=4m', '--tmpfs', '/etc/nginx/conf.d:uid=101,gid=101,mode=0755,size=1m', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true'];

let scratch;
let port;
// A contributor machine with Docker but no network cannot pull the pinned base image: the tests skip, visibly. CI always builds.
let unbuilt = null;

before(() => {
  if (skip) return;
  scratch = mkdtempSync(join(tmpdir(), 'warehouse-gateway-test-'));
  // The build pulls the pinned base image from Docker Hub. In CI a pull that fails (a rate limit, a short outage) is tried twice more
  // before the job fails; a contributor's machine without a network skips instead.
  let build;
  for (let attempt = 1; attempt <= (process.env.CI ? 3 : 1); attempt += 1) {
    build = docker(['build', '--quiet', '-t', IMAGE, join(repo, 'docker/nginx')]);
    if (build.status === 0) return;
    if (!/pull|resolve|connect|network|timeout|registry|lookup|rate limit|toomanyrequests|50\d /i.test(build.stderr)) break;
    if (attempt < 3 && process.env.CI) spawnSync('sleep', [String(10 * attempt)]);
  }
  if (process.env.CI || !/pull|resolve|connect|network|timeout|registry|lookup/i.test(build.stderr)) assert.fail(`the image does not build: ${build.stderr}`);
  unbuilt = 'the gateway image cannot be built here (no network for the pinned base image)';
});

after(() => {
  if (skip) return;
  for (const name of [GATEWAY, GATEWAY_MEMORY, STUB]) docker(['rm', '-f', name]);
  docker(['network', 'rm', NETWORK]);
  docker(['rmi', '-f', IMAGE]);
  if (scratch) rmSync(scratch, { recursive: true, force: true });
});

test('nginx -t passes on the rendered configuration, in the image, with the flags of the Compose service', { skip }, t => {
  if (unbuilt) return t.skip(unbuilt);
  const run = (...command) => docker(['run', '--rm', '-e', 'NGINX_ENTRYPOINT_QUIET_LOGS=1', ...HARDENING, ...environment(), IMAGE, ...command]);
  const test_ = run('nginx', '-t');
  assert.equal(test_.status, 0, test_.stderr);
  assert.match(test_.stderr, /configuration file \/etc\/nginx\/nginx\.conf test is successful/);
  assert.doesNotMatch(test_.stderr, /\[(?:warn|emerg|alert)\]/, 'not even a warning');
  // The rendered configuration: the three values are in, nothing else was replaced, nothing is left unreplaced.
  const dump = run('nginx', '-T');
  assert.equal(dump.status, 0, dump.stderr);
  assert.match(dump.stdout, new RegExp(`default "${ORIGIN.replace(/\./g, '\\.')}";`));
  assert.match(dump.stdout, new RegExp(`"${ANON.replace(/\./g, '\\.')}"\\s+"";`));
  assert.match(dump.stdout, new RegExp(`"${SERVICE.replace(/\./g, '\\.')}"\\s+"";`));
  assert.doesNotMatch(dump.stdout, /\$\{/);
  assert.match(dump.stdout, /limit_req_zone \$binary_remote_addr zone=rest:10m rate=30r\/s;/);
  assert.match(dump.stdout, /log_format warehouse_redacted '\$remote_addr \[\$time_local\] "\$request_method \$uri \$server_protocol" \$status \$body_bytes_sent \$request_time';/);
  assert.equal((dump.stdout.match(/^\s*listen\s/gm) || []).length, 1);
  // The entrypoint's envsubst puts a value in for the bare form of a name too (a comment or a line that wrote `$ANON_KEY` would get the
  // key), and leaves other variables alone: tests/gateway-config.test.mjs forbids both forms outside the places meant for them.
  const forms = run('sh', '-c', `printf '%s' 'a $ANON_KEY b \${ANON_KEY} c $remote_addr d \${NOT_LISTED}' | envsubst '\${ANON_KEY}'`);
  assert.equal(forms.status, 0, forms.stderr);
  assert.equal(forms.stdout, `a ${ANON} b ${ANON} c $remote_addr d \${NOT_LISTED}`);
  // The user and the filter of the image.
  const inspected = JSON.parse(docker(['image', 'inspect', IMAGE]).stdout)[0].Config;
  assert.equal(inspected.User, '101:101');
  assert.ok(inspected.Env.includes('NGINX_ENVSUBST_FILTER=^(CORS_ALLOWED_ORIGIN|ANON_KEY|SERVICE_ROLE_KEY)$'));
});

test('the container refuses to start on a missing value or one that could change the configuration', { skip }, t => {
  if (unbuilt) return t.skip(unbuilt);
  const refused = [
    [{ ANON_KEY: undefined }, /ANON_KEY is not set/],
    [{ SERVICE_ROLE_KEY: '' }, /SERVICE_ROLE_KEY is not set/],
    [{ CORS_ALLOWED_ORIGIN: undefined }, /CORS_ALLOWED_ORIGIN is not set/],
    [{ CORS_ALLOWED_ORIGIN: 'app.example.test' }, /one origin, http\(s\):\/\/host/],
    [{ CORS_ALLOWED_ORIGIN: '*' }, /character that is not allowed/],
    [{ CORS_ALLOWED_ORIGIN: 'https://a.test; return 200' }, /character that is not allowed/],
    [{ ANON_KEY: 'a" 1; } location / { return 200 "x' }, /character that is not allowed/],
    [{ SERVICE_ROLE_KEY: 'a$b' }, /character that is not allowed/],
    [{ SERVICE_ROLE_KEY: 'a\nb' }, /character that is not allowed/],
  ];
  for (const [overrides, message] of refused) {
    const result = docker(['run', '--rm', ...HARDENING, ...environment(overrides), IMAGE, 'nginx', '-t']);
    assert.notEqual(result.status, 0, `started with ${JSON.stringify(overrides)}`);
    assert.match(result.stderr, message, JSON.stringify(overrides));
    assert.doesNotMatch(result.stderr, /test is successful/);
  }
});

// ---- the routes, against stand-ins for the three upstreams on a throwaway network -----------------------------------------------
// One stand-in answers on 3000, 5000 and 9000 (the names rest, storage and functions) and tells the request back as it saw it.
const STUB_CONF = `server {
  listen 3000; listen 5000; listen 9000;
  client_max_body_size 100m;
  # Large answers for the buffer tests (mounted from the scratch directory): /files/preview.json is 2.2 MB, /files/big.json is 10 MB.
  location /files/ {
    alias /srv/files/;
    add_header Cache-Control "no-store" always;
  }
  location / {
    add_header Access-Control-Allow-Origin "*" always;
    add_header Access-Control-Expose-Headers "X-Stub" always;
    add_header X-Content-Type-Options "nosniff" always;
    default_type text/plain;
    return 200 "line=$request|host=$http_host|apikey=$http_apikey|cfip=$http_cf_connecting_ip|xri=$http_x_real_ip|xff=$http_x_forwarded_for|auth=$http_authorization";
  }
}
`;
const agent = new http.Agent({ keepAlive: true, maxSockets: 100 });
function request(path, { method = 'GET', headers = {}, body, port: target = port } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port: target, path, method, headers, agent }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => {
        const raw = res.rawHeaders;
        const all = name => raw.flatMap((value, i) => (i % 2 === 0 && value.toLowerCase() === name ? [raw[i + 1]] : []));
        const body = Buffer.concat(chunks);
        resolve({ status: res.statusCode, headers: res.headers, all, text: body.toString('utf8'), body });
      });
    });
    req.setTimeout(30000, () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.end(body);
  });
}
const echoed = text => Object.fromEntries(text.split('|').map(part => [part.slice(0, part.indexOf('=')), part.slice(part.indexOf('=') + 1)]));
const address = () => `2001:db8:5eed::${randomBytes(2).toString('hex')}`;

// A JSON document of at least `bytes` bytes (compressible, as a PostgREST answer is): an array of rows.
const ROW = JSON.stringify({ id: 1, item: 'Basmati rice 25 kg', packs: 40, rate: '1250.00', note: 'x'.repeat(40) });
const jsonOfSize = bytes => `[${Array.from({ length: Math.ceil(bytes / (ROW.length + 1)) }, () => ROW).join(',')}]`;
const PREVIEW_BYTES = 2.2 * 1024 * 1024;
const BIG_BYTES = 10 * 1024 * 1024 - 1024;

// Starts a gateway container on the lab network, limited like the Compose service. `swap` false lets the kernel kill it at 128 MB
// instead of swapping, which is what a host without swap does, so an overrun shows as OOMKilled here too.
async function startGateway(name, { memory = false } = {}) {
  const run = docker(['run', '-d', '--name', name, '--network', NETWORK, '-p', '127.0.0.1::8000', '--memory', '128m', ...(memory ? ['--memory-swap', '128m'] : []), '--cpus', '0.5', ...HARDENING, ...environment(), IMAGE]);
  assert.equal(run.status, 0, run.stderr);
  const bound = Number(/:(\d+)\s*$/m.exec(docker(['port', name, '8000/tcp']).stdout)[1]);
  for (let attempt = 0; attempt < 50; attempt += 1) {
    // Storage has no key check and no rate limit; the stand-in answers 200. (/health answers the container's own check only.)
    try { if ((await request('/storage/v1/ready', { port: bound })).status === 200) return bound; } catch { /* not listening yet */ }
    await new Promise(done => setTimeout(done, 200));
  }
  return assert.fail(`the gateway did not answer: ${docker(['logs', name]).stderr}`);
}
async function startLab() {
  if (port) return;
  writeFileSync(join(scratch, 'stub.conf'), STUB_CONF);
  mkdirSync(join(scratch, 'files'), { recursive: true });
  writeFileSync(join(scratch, 'files/preview.json'), jsonOfSize(PREVIEW_BYTES));
  writeFileSync(join(scratch, 'files/big.json'), jsonOfSize(BIG_BYTES));
  assert.equal(docker(['network', 'create', NETWORK]).status, 0);
  const base = /^FROM (nginx:\S+@sha256:[0-9a-f]{64})$/m.exec(readFileSync(join(repo, 'docker/nginx/Dockerfile'), 'utf8'))[1];
  const stub = docker(['run', '-d', '--name', STUB, '--network', NETWORK, ...['rest', 'storage', 'functions'].flatMap(name => ['--network-alias', name]), '-v', `${join(scratch, 'stub.conf')}:/etc/nginx/conf.d/default.conf:ro`, '-v', `${join(scratch, 'files')}:/srv/files:ro`, base]);
  assert.equal(stub.status, 0, stub.stderr);
  port = await startGateway(GATEWAY);
}
const logLines = () => { const logs = docker(['logs', GATEWAY]); return `${logs.stdout}\n${logs.stderr}`; };

test('REST: the prefix comes off, the path and query arrive as written, the key is not passed on, the client address is the trusted hop\'s', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLab();
  const answer = await request('/rest/v1/rpc/f%2Fg?select=a%2Cb&x=1%202', { headers: { apikey: ANON, Authorization: 'Bearer t', 'CF-Connecting-IP': '203.0.113.9', 'X-Forwarded-For': '1.1.1.1', Origin: ORIGIN } });
  assert.equal(answer.status, 200, answer.text);
  const seen = echoed(answer.text);
  assert.equal(seen.line, 'GET /rpc/f%2Fg?select=a%2Cb&x=1%202 HTTP/1.1');
  assert.equal(seen.host, 'rest:3000');
  assert.equal(seen.apikey, '', 'the apikey is checked here and not passed on');
  assert.equal(seen.auth, 'Bearer t', 'the user\'s own token is');
  assert.equal(seen.cfip, '203.0.113.9');
  assert.equal(seen.xff, '203.0.113.9', 'a forwarded-for chain from the client is replaced');
  // CORS: the configured origin only, once; the upstream\'s own header is dropped.
  assert.deepEqual(answer.all('access-control-allow-origin'), [ORIGIN]);
  assert.deepEqual(answer.all('access-control-allow-credentials'), ['true']);
  assert.deepEqual(answer.all('access-control-expose-headers'), ['Content-Range,X-Request-Id']);
  assert.deepEqual(answer.all('vary'), ['Origin']);
  assert.equal(answer.headers.server, 'nginx', 'no version in the Server header');
  assert.equal(answer.headers['x-content-type-options'], 'nosniff', 'the upstream\'s other headers pass');
  // Several slashes in front are accepted; nothing is redirected.
  assert.equal(echoed((await request('//rest/v1/x', { headers: { apikey: SERVICE } })).text).line, 'GET /x HTTP/1.1');
  assert.equal((await request('/rest/v1/', { headers: { apikey: ANON } })).status, 200);
});

test('the key check is on the REST route only, with the messages the app reads, and the preflight comes before it', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLab();
  const ip = { 'CF-Connecting-IP': address() };
  const missing = await request('/rest/v1/rpc/x', { headers: ip });
  assert.equal(missing.status, 401);
  assert.equal(missing.text, '{"message":"No API key found in request"}');
  assert.match(missing.headers['content-type'], /^application\/json/);
  assert.equal(missing.headers['www-authenticate'], 'Key');
  assert.deepEqual(missing.all('access-control-allow-origin'), [ORIGIN], 'a browser can read the refusal');
  const empty = await request('/rest/v1/rpc/x', { headers: { ...ip, apikey: '' } });
  assert.equal(empty.text, '{"message":"No API key found in request"}');
  const wrong = await request('/rest/v1/rpc/x', { headers: { ...ip, apikey: `${ANON}x` } });
  assert.equal(wrong.status, 401);
  assert.equal(wrong.text, '{"message":"Unauthorized"}');
  // The value of the other key, or a key in the query string, is not accepted.
  assert.equal((await request(`/rest/v1/rpc/x?apikey=${ANON}`, { headers: ip })).status, 401);
  assert.equal((await request('/rest/v1/rpc/x', { headers: { ...ip, apikey: SERVICE } })).status, 200, 'the service-role key passes');
  assert.equal((await request('/rest/v1/rpc/x', { headers: { ...ip, apikey: ANON } })).status, 200, 'the anon key passes');
  // nginx matches the keys of a map without regard to letter case (listed in CHANGELOG.md, templates/http.conf.template): the check is
  // not exact, and a key that differs in more than its case still fails.
  assert.equal((await request('/rest/v1/rpc/x', { headers: { ...ip, apikey: ANON.toUpperCase() } })).status, 200, 'letter case does not matter');
  assert.equal((await request('/rest/v1/rpc/x', { headers: { ...ip, apikey: `${ANON.slice(0, -1)}Z` } })).status, 401, 'another last letter does');
  // Storage and functions have no key check.
  assert.equal((await request('/storage/v1/object/x', { headers: ip })).status, 200);
  assert.equal((await request('/functions/v1/x', { headers: ip })).status, 200);
  // A request over the body limit is refused before the key is looked at, with the documented body.
  const big = await request('/rest/v1/rpc/x', { method: 'POST', headers: { ...ip, apikey: ANON, 'content-length': String(10 * 1024 * 1024 + 1) }, body: Buffer.alloc(10 * 1024 * 1024 + 1, 120) }).catch(error => ({ status: error.code, text: '' }));
  assert.ok(big.status === 413 || big.status === 'ECONNRESET' || big.status === 'EPIPE', `HTTP ${big.status}`);
});

test('CORS preflights: 204 with the origin, credentials, the route\'s lists and a day of cache; any other OPTIONS goes upstream', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLab();
  const expected = {
    '/rest/v1/rpc/x': ['GET,POST,PUT,PATCH,DELETE,OPTIONS', 'Authorization,Content-Type,X-Client-Info,apikey,Prefer,Range'],
    '/storage/v1/object/x': ['GET,POST,PUT,DELETE,OPTIONS', 'Authorization,Content-Type,X-Client-Info,apikey,Cache-Control,X-Upsert'],
    '/functions/v1/get-public-config': ['GET,POST,PUT,DELETE,OPTIONS', 'Authorization,Content-Type,X-Client-Info,apikey'],
  };
  for (const [path, [methods, headers]] of Object.entries(expected)) {
    // Without a key and from an origin that is not the configured one: the answer is the same, and names the configured origin.
    const answer = await request(path, { method: 'OPTIONS', headers: { Origin: 'https://evil.example.test', 'Access-Control-Request-Method': 'POST', 'CF-Connecting-IP': address() } });
    assert.equal(answer.status, 204, path);
    assert.equal(answer.text, '');
    assert.deepEqual(answer.all('access-control-allow-origin'), [ORIGIN], path);
    assert.deepEqual(answer.all('access-control-allow-credentials'), ['true']);
    assert.deepEqual(answer.all('access-control-allow-methods'), [methods], path);
    assert.deepEqual(answer.all('access-control-allow-headers'), [headers], path);
    assert.deepEqual(answer.all('access-control-max-age'), ['86400']);
    assert.deepEqual(answer.all('vary'), ['Origin']);
  }
  // An OPTIONS request without the preflight headers is an ordinary request: the key check applies, and the upstream answers.
  assert.equal((await request('/rest/v1/rpc/x', { method: 'OPTIONS', headers: { 'CF-Connecting-IP': address() } })).status, 401);
  const plain = await request('/functions/v1/x', { method: 'OPTIONS', headers: { 'CF-Connecting-IP': address() } });
  assert.equal(plain.status, 200);
  assert.match(plain.text, /^line=OPTIONS \/x HTTP\/1\.1\|/);
});

test('storage: no client address reaches it, the signed-link query is passed on, and there is no rate limit', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLab();
  const ip = address();
  const answer = await request('/storage/v1/object/sign/documents/a%2Fb%20c.pdf?token=t0k&x=%2F', { headers: { 'CF-Connecting-IP': ip, 'X-Real-IP': '9.9.9.9', 'X-Forwarded-For': '8.8.8.8', apikey: 'client-key' } });
  assert.equal(answer.status, 200);
  const seen = echoed(answer.text);
  assert.equal(seen.line, 'GET /object/sign/documents/a%2Fb%20c.pdf?token=t0k&x=%2F HTTP/1.1');
  assert.equal(seen.host, 'storage:5000');
  assert.equal(seen.cfip, '');
  assert.equal(seen.xri, '');
  assert.equal(seen.xff, '');
  assert.equal(seen.apikey, 'client-key', 'Storage gets the header as sent (it has no key check here)');
  assert.deepEqual(answer.all('access-control-expose-headers'), ['Content-Range,X-Request-Id']);
  // 300 requests at once from one address are all answered (the other routes would refuse some at 100).
  const many = await Promise.all(Array.from({ length: 300 }, () => request('/storage/v1/object/x', { headers: { 'CF-Connecting-IP': ip } })));
  assert.deepEqual([...new Set(many.map(item => item.status))], [200]);
});

test('functions: the client address is the trusted hop\'s, or the connection\'s when none is given', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLab();
  const given = echoed((await request('/functions/v1/get-public-config?a=1', { headers: { 'CF-Connecting-IP': '203.0.113.5', 'X-Forwarded-For': '1.2.3.4', 'X-Real-IP': '5.6.7.8' } })).text);
  assert.equal(given.line, 'GET /get-public-config?a=1 HTTP/1.1');
  assert.equal(given.host, 'functions:9000');
  assert.equal(given.cfip, '203.0.113.5');
  assert.equal(given.xri, '203.0.113.5');
  assert.equal(given.xff, '203.0.113.5');
  const none = echoed((await request('/functions/v1/hello', { headers: { 'X-Forwarded-For': '1.2.3.4' } })).text);
  assert.match(none.cfip, /^[0-9a-f:.]+$/, 'the connection\'s own address');
  assert.notEqual(none.cfip, '1.2.3.4');
  // A header that is not an address is not taken for one.
  const odd = echoed((await request('/functions/v1/hello', { headers: { 'CF-Connecting-IP': 'not-an-address' } })).text);
  assert.notEqual(odd.cfip, 'not-an-address');
});

test('paths that match no route, or match one only after clean-up, are answered 404 in JSON', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLab();
  for (const path of ['/nothing', '/rest/v1', '/storage/v1', '/functions/v1', '/rest/v1/../storage/v1/x', '/rest/v1/%2e%2e/storage/v1/x', '/rest%2Fv1/x', '/REST/v1/x', '/health/x']) {
    const answer = await request(path, { headers: { apikey: ANON } });
    assert.equal(answer.status, 404, path);
    assert.equal(answer.text, '{"message":"no Route matched with those values"}', path);
    assert.match(answer.headers['content-type'], /^application\/json/, path);
  }
});

test('/health answers the container\'s own check and nobody who comes through the tunnel; the Compose health check passes', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLab();
  // The check of docker-compose.yml, run inside the container: it comes from 127.0.0.1 (the container's own address).
  const inside = docker(['exec', GATEWAY, 'wget', '-q', '-T', '5', '-O', '-', 'http://127.0.0.1:8000/health']);
  assert.equal(inside.status, 0, inside.stderr);
  assert.equal(inside.stdout, 'ok\n');
  // A request from outside carries a client address (here the one the tunnel hop names, or the connection's own): no answer, like any
  // path that has no route.
  for (const headers of [{}, { 'CF-Connecting-IP': '203.0.113.7' }]) {
    const outside = await request('/health', { headers });
    assert.equal(outside.status, 404, JSON.stringify(headers));
    assert.equal(outside.text, '{"message":"no Route matched with those values"}');
    assert.match(outside.headers['content-type'], /^application\/json/);
  }
});

test('raw dot segments are refused on every route, as are their encoded forms; names and queries that merely hold dots pass', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLab();
  const ip = { 'CF-Connecting-IP': address() };
  const refused = [
    '/storage/v1/object/b/a/../x', '/storage/v1/object/b/a/./x', '/storage/v1/object/b/a/%2e%2e/x', '/storage/v1/object/b/a/%2E%2e/x',
    '/storage/v1/object/b/a%2F..%2Fx', '/storage/v1/object/b/a%2f%2e%2e%2fx', '/storage/v1/object/b/a/..', '/storage/v1/object/b/a/..?x=1',
    '/storage/v1/object/b/./a', '/storage/v1/../x', '/rest/v1/rpc/../x', '/rest/v1/./rpc/x', '/rest/v1/rpc/f/%2e', '/functions/v1/get-public-config/../x',
    '/functions/v1/a%2F..', '//storage/v1/object/b/a/../x',
  ];
  for (const path of refused) {
    const answer = await request(path, { headers: { ...ip, apikey: ANON } });
    assert.equal(answer.status, 404, path);
    assert.equal(answer.text, '{"message":"no Route matched with those values"}', path);
  }
  const allowed = [
    '/storage/v1/object/b/a..b/x', '/storage/v1/object/b/..hidden/x', '/storage/v1/object/b/a../x', '/storage/v1/object/b/...', '/storage/v1/object/b/a.b/c.d.pdf',
    '/storage/v1/object/b/a/...x/y', '/storage/v1/object/sign/b/a.pdf?token=../x', '/storage/v1/object/b/a?path=%2e%2e%2f', '/rest/v1/rpc/f?x=/../a',
    '/storage/v1/object/b/%2e%2ex/y', '/functions/v1/get-public-config?a=..',
  ];
  for (const path of allowed) {
    const answer = await request(path, { headers: { ...ip, apikey: ANON } });
    assert.equal(answer.status, 200, path);
    assert.equal(echoed(answer.text).line.split(' ')[1], path.replace(/^\/(?:storage|rest|functions)\/v1/, ''), `${path} reaches the upstream as written`);
  }
});

test('REST: the preview-sized answer (2.2 MB of JSON) arrives whole, compressed for a client that accepts gzip', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLab();
  const expected = readFileSync(join(scratch, 'files/preview.json'));
  assert.ok(expected.length > 2 * 1024 * 1024, 'a preview that is larger than the answer buffers');
  const plain = await request('/rest/v1/files/preview.json', { headers: { apikey: ANON } });
  assert.equal(plain.status, 200);
  assert.deepEqual(plain.body, expected);
  const packed = await request('/rest/v1/files/preview.json', { headers: { apikey: ANON, 'Accept-Encoding': 'gzip' } });
  assert.equal(packed.status, 200);
  assert.equal(packed.headers['content-encoding'], 'gzip');
  assert.ok(packed.body.length < expected.length / 10, `${packed.body.length} bytes on the wire`);
  assert.deepEqual(gunzipSync(packed.body), expected);
});

test('twenty readers that stop reading a 10 MB answer do not use up the 128 MB of the gateway, and each gets the whole answer', { skip, timeout: 240000 }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLab();
  // A container of its own, with swap off, so an overrun is a kill here as on a host without swap.
  const memoryPort = await startGateway(GATEWAY_MEMORY, { memory: true });
  const expected = readFileSync(join(scratch, 'files/big.json'));
  const digest = createHash('sha256').update(expected).digest('hex');
  assert.ok(expected.length > 10 * 1024 * 1024 - 4096, 'the largest answer a route sends');
  const readers = Array.from({ length: 20 }, () => new Promise((resolve, reject) => {
    const req = http.get({ host: '127.0.0.1', port: memoryPort, path: '/rest/v1/files/big.json', headers: { apikey: ANON }, agent: false }, res => {
      // Headers have arrived; the body is not read until the test says so (a phone on a slow uplink).
      res.pause();
      const hash = createHash('sha256');
      let bytes = 0;
      const finished = new Promise((done, fail) => {
        res.on('data', chunk => { hash.update(chunk); bytes += chunk.length; });
        res.on('end', () => done({ status: res.statusCode, bytes, digest: hash.digest('hex') }));
        res.on('error', fail);
      });
      resolve({ res, finished });
    });
    req.setTimeout(120000, () => req.destroy(new Error('timeout')));
    req.on('error', reject);
  }));
  const open = await Promise.all(readers);
  await new Promise(done => setTimeout(done, 4000));
  const state = () => JSON.parse(docker(['inspect', '--format', '{"oom":{{.State.OOMKilled}},"running":{{.State.Running}},"restarts":{{.RestartCount}}}', GATEWAY_MEMORY]).stdout);
  const peak = () => Number(docker(['exec', GATEWAY_MEMORY, 'cat', '/sys/fs/cgroup/memory.peak']).stdout) || null;
  const midway = state();
  const peakMidway = peak();
  assert.deepEqual(midway, { oom: false, running: true, restarts: 0 }, `while 20 readers hold their answers: peak ${peakMidway} bytes\n${docker(['logs', '--tail', '20', GATEWAY_MEMORY]).stderr}`);
  for (const { res } of open) res.resume();
  const results = await Promise.all(open.map(({ finished }) => finished));
  assert.deepEqual([...new Set(results.map(result => `${result.status} ${result.bytes} ${result.digest === digest}`))], [`200 ${expected.length} true`]);
  const end = state();
  assert.deepEqual(end, { oom: false, running: true, restarts: 0 }, `after the answers: peak ${peak()} bytes`);
  if (peakMidway !== null) t.diagnostic(`memory peak with 20 readers holding 10 MB answers: ${(peakMidway / 1024 / 1024).toFixed(1)} MiB of 128`);
});

test('rate limits per client address: 100 then a refusal on functions, 1800 then a refusal on REST, another address untouched', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLab();
  // Functions: one after the other, until the first 429.
  const functionsIp = address();
  let passed = 0;
  let refused;
  const started = Date.now();
  while (!refused && passed < 160) {
    const answer = await request('/functions/v1/x', { headers: { 'CF-Connecting-IP': functionsIp } });
    if (answer.status === 429) refused = answer; else { assert.equal(answer.status, 200); passed += 1; }
  }
  const seconds = (Date.now() - started) / 1000;
  assert.ok(refused, `no 429 after ${passed} requests`);
  assert.ok(passed >= 100 && passed <= 101 + Math.ceil(seconds * 100 / 60) + 2, `${passed} requests passed in ${seconds} s`);
  assert.equal(refused.text, '{"message":"API rate limit exceeded"}');
  assert.equal(refused.headers['retry-after'], '1');
  assert.match(refused.headers['content-type'], /^application\/json/);
  assert.deepEqual(refused.all('access-control-allow-origin'), [ORIGIN]);
  assert.equal((await request('/functions/v1/x', { headers: { 'CF-Connecting-IP': address() } })).status, 200, 'another address has a bucket of its own');
  // REST: 100 at a time until a 429; what was let in is the burst plus what drained meanwhile.
  const restIp = address();
  const restStarted = Date.now();
  let admitted = 0;
  let limited = 0;
  while (!limited && admitted + limited < 6000) {
    const batch = await Promise.all(Array.from({ length: 100 }, () => request('/rest/v1/', { headers: { apikey: ANON, 'CF-Connecting-IP': restIp } })));
    for (const answer of batch) { if (answer.status === 429) limited += 1; else { assert.equal(answer.status, 200); admitted += 1; } }
  }
  const restSeconds = (Date.now() - restStarted) / 1000;
  assert.ok(limited > 0, `no 429 after ${admitted} requests`);
  assert.ok(admitted >= 1800 && admitted <= 1801 + Math.ceil(restSeconds * 30) + 10, `${admitted} REST requests passed in ${restSeconds} s`);
  assert.equal((await request('/rest/v1/', { headers: { apikey: ANON, 'CF-Connecting-IP': address() } })).status, 200);
  // A request without a key is refused before the limit and uses none of it.
  const keyless = address();
  const refusedKeys = await Promise.all(Array.from({ length: 200 }, () => request('/rest/v1/', { headers: { 'CF-Connecting-IP': keyless } })));
  assert.deepEqual([...new Set(refusedKeys.map(item => item.status))], [401]);
  assert.equal((await request('/rest/v1/', { headers: { apikey: ANON, 'CF-Connecting-IP': keyless } })).status, 200);
});

test('the access log has the path and no query string, the line the checker reads, and a refusal writes no error line', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLab();
  const marker = randomBytes(6).toString('hex');
  await request(`/storage/v1/object/sign/documents/log-${marker}.pdf?token=secret-${marker}&apikey=key-${marker}`, { headers: { 'CF-Connecting-IP': '198.51.100.12' } });
  const log = logLines();
  assert.match(log, new RegExp(`^\\S+ \\[[^\\]]+\\] "GET /storage/v1/object/sign/documents/log-${marker}\\.pdf HTTP/1\\.1" 200 \\d+ [0-9.]+$`, 'm'));
  assert.doesNotMatch(log, new RegExp(`secret-${marker}|key-${marker}|token=`));
  // The 429s of the rate-limit test are access lines; none of them is in the error log (and so no request line with a query).
  assert.match(log, / 429 \d+ [0-9.]+$/m);
  assert.doesNotMatch(log, /limiting requests/);
  assert.doesNotMatch(log, /"GET \/health HTTP\/1\.1" 200 /, 'the container health check is not logged');
  assert.match(log, /"GET \/health HTTP\/1\.1" 404 /, 'an outside request for /health is refused, and that is logged like any 404');
  assert.doesNotMatch(log, /\[(?:emerg|alert|crit)\]/);
});
