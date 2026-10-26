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
import { probeLanKeys } from '../scripts/lan-common.mjs';

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
const GATEWAY_LAN = `wg-test-${id}-lan`;
const GATEWAY_LAN_OUT = `wg-test-${id}-lan-out`;
const GATEWAY_LAN_OLD = `wg-test-${id}-lan-old`;
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
  for (const name of [GATEWAY, GATEWAY_MEMORY, GATEWAY_LAN, GATEWAY_LAN_OUT, GATEWAY_LAN_OLD, STUB]) docker(['rm', '-f', name]);
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
  assert.ok(inspected.Env.includes('NGINX_ENVSUBST_FILTER=^(CORS_ALLOWED_ORIGIN|ANON_KEY|SERVICE_ROLE_KEY|LAN_CIDR|LAN_BIND_IP|LAN_HTTP_PORT)$'));
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

// ---- the LAN fallback: the same image, reading the LAN template directory of that image, as the gateway-lan service does ----
// What Compose gives that container (docker/docker-compose.yml): the flags of HARDENING, the keys, and NGINX_ENVSUBST_TEMPLATE_DIR, GATEWAY_ROLE, LAN_CIDR,
// LAN_BIND_IP and LAN_HTTP_PORT. Nothing is mounted: the LAN server is in the image (docker/nginx/Dockerfile, templates-lan), so this is the image
// the gateway runs and not a second build. LAN_IP is a private address the lab pins as the container's Host (it is not bound anywhere here).
const LAN_IP = '192.168.77.20';
const LAN_PORT = '18080';
const LAN_HOST = `${LAN_IP}:${LAN_PORT}`;
const lanVars = (cidr, over = {}) => ({ NGINX_ENVSUBST_TEMPLATE_DIR: '/etc/nginx/templates-lan', GATEWAY_ROLE: 'lan', LAN_CIDR: cidr, LAN_BIND_IP: LAN_IP, LAN_HTTP_PORT: LAN_PORT, ...over });
const lanFlags = (cidr, over = {}) => Object.entries(lanVars(cidr, over)).filter(([, value]) => value !== undefined).flatMap(([name, value]) => ['-e', `${name}=${value}`]);

test('the LAN container renders the LAN server only, refuses to start without a private range, address and port, and the public container has no LAN listener', { skip }, t => {
  if (unbuilt) return t.skip(unbuilt);
  const run = (flags, ...command) => docker(['run', '--rm', '-e', 'NGINX_ENTRYPOINT_QUIET_LOGS=1', ...HARDENING, ...environment(), ...flags, IMAGE, ...command]);
  const dump = run(lanFlags('192.168.1.0/24'), 'nginx', '-T');
  assert.equal(dump.status, 0, dump.stderr);
  assert.deepEqual(dump.stdout.match(/^\s*listen\s.*$/gm).map(line => line.trim()), ['listen 8080;'], 'one listener, plain http');
  assert.match(dump.stdout, /^\s*allow 192\.168\.1\.0\/24;$\n^\s*deny all;$/m);
  assert.match(dump.stdout, /^\s*set \$warehouse_path lan;$/m);
  // The Host pin, rendered with the address and the port of the lab.
  assert.match(dump.stdout, new RegExp(`^\\s*"${LAN_IP.replace(/\./g, '\\.')}"\\s+1;$\\n^\\s*"${LAN_IP.replace(/\./g, '\\.')}:${LAN_PORT}"\\s+1;$`, 'm'));
  assert.match(dump.stdout, /^\s*if \(\$lan_host_ok = 0\) \{ return 404; \}$/m);
  assert.doesNotMatch(dump.stdout, /set_real_ip_from|real_ip_header|listen 8000|\$\{|\bssl\b|http2/);
  assert.equal(run(lanFlags('192.168.1.0/24'), 'nginx', '-t').status, 0);
  // The public container (no role, the default template directory): listen 8000 only, the trust in the tunnel hop, and nothing of the LAN server.
  const publicDump = run([], 'nginx', '-T');
  assert.deepEqual(publicDump.stdout.match(/^\s*listen\s.*$/gm).map(line => line.trim()), ['listen 8000;']);
  assert.match(publicDump.stdout, /^\s*set \$warehouse_path public;$/m);
  assert.doesNotMatch(publicDump.stdout, /^\s*(?:allow|deny)\s|lan_host_ok/m);
  // The LAN server is part of the image, not mounted: the LAN template directory is there with its two templates, and a different tag of the same
  // build would carry both. Nothing in the container's file system is bind-mounted from the checkout.
  assert.equal(run([], 'ls', '/etc/nginx/templates-lan').stdout.split('\n').filter(Boolean).sort().join(' '), 'gateway-lan.conf.template http.conf.template');
  assert.equal(run([], 'ls', '/etc/nginx/templates').stdout.split('\n').filter(Boolean).sort().join(' '), 'gateway.conf.template http.conf.template');
  // The template directory is what makes it the LAN container: without the role it is held to the same rules, and the public container is not asked.
  const noRole = { GATEWAY_ROLE: undefined };
  assert.equal(run(lanFlags('192.168.1.0/24', noRole), 'nginx', '-t').status, 0);
  for (const cidr of ['all', '0.0.0.0/0']) {
    const result = run(lanFlags(cidr, noRole), 'nginx', '-t');
    assert.notEqual(result.status, 0, `started with the LAN directory and ${cidr}`);
    assert.match(result.stderr, /LAN_CIDR (?:has a character that is not allowed|must be one private IPv4 range)/);
  }
  // A LAN value given to the public container is ignored (no role, the default directory): it still starts.
  assert.equal(run(['-e', 'LAN_CIDR=not-a-range', '-e', 'LAN_BIND_IP=8.8.8.8', '-e', 'LAN_HTTP_PORT=80'], 'nginx', '-t').status, 0);
  // A template of the public directory that writes the allow list in a line that is not a comment is the LAN server by another route: the same rule.
  const mounted = join(scratch, 'allow-in-public.conf.template');
  writeFileSync(mounted, readFileSync(join(repo, 'docker/nginx/templates/gateway.conf.template'), 'utf8').replace('    server_name _;', '    server_name _;\n    allow ${LAN_CIDR};'));
  const hidden = run(['-v', `${mounted}:/etc/nginx/templates/gateway.conf.template:ro`, '-e', 'LAN_CIDR=all'], 'nginx', '-t');
  assert.notEqual(hidden.status, 0);
  assert.match(hidden.stderr, /LAN_CIDR must be one private IPv4 range/);
  // ...but a comment that names the variables does not stop the public gateway (L7 of the review): only the lines nginx reads count.
  const commented = join(scratch, 'comment-in-public.conf.template');
  writeFileSync(commented, `# The LAN server uses LAN_CIDR, LAN_BIND_IP and LAN_HTTP_PORT; \${LAN_CIDR} is not read here.\n${readFileSync(join(repo, 'docker/nginx/templates/gateway.conf.template'), 'utf8')}`);
  const fine = run(['-v', `${commented}:/etc/nginx/templates/gateway.conf.template:ro`], 'nginx', '-t');
  assert.equal(fine.status, 0, fine.stderr);
  // Accepted: a private block, or a part of one.
  for (const cidr of ['10.0.0.0/8', '10.20.30.0/24', '172.16.0.0/12', '172.31.5.0/24', '192.168.0.0/16', '192.168.1.0/24', '192.168.1.7/32']) {
    assert.equal(run(lanFlags(cidr), 'nginx', '-t').status, 0, cidr);
  }
  // Refused with a message, and no configuration is tested: nothing, a public or too wide range, another syntax, or something that would change the file.
  for (const cidr of [undefined, '', '0.0.0.0/0', '8.8.8.0/24', '100.64.0.0/10', '192.168.0.0/15', '172.15.0.0/16', '172.32.0.0/16', '11.0.0.0/8', '10.0.0.0/7', '192.168.1.0', 'all', '192.168.1.0/24;', '192.168.1.0/24 192.168.2.0/24', '192.168.1.0/24, 10.0.0.0/8', '192.168.1.0/33', '$remote_addr']) {
    const result = run(lanFlags(cidr), 'nginx', '-t');
    assert.notEqual(result.status, 0, `started with ${JSON.stringify(cidr)}`);
    assert.match(result.stderr, /LAN_CIDR (?:is not set|has a character that is not allowed|must be one private IPv4 range)/, JSON.stringify(cidr));
    assert.doesNotMatch(result.stderr, /test is successful/);
  }
  // The Host the server answers to: one private address, and a port from 1024.
  for (const ip of ['10.0.0.5', '172.16.9.9', '172.31.255.1', '192.168.1.20']) assert.equal(run(lanFlags('192.168.1.0/24', { LAN_BIND_IP: ip }), 'nginx', '-t').status, 0, ip);
  for (const ip of [undefined, '', '8.8.8.8', '127.0.0.1', '0.0.0.0', '100.64.0.1', '172.32.0.1', '192.168.1', '192.168.1.20;', '192.168.1.20 10.0.0.1', '*', '$host', 'example.test']) {
    const result = run(lanFlags('192.168.1.0/24', { LAN_BIND_IP: ip }), 'nginx', '-t');
    assert.notEqual(result.status, 0, `started with LAN_BIND_IP ${JSON.stringify(ip)}`);
    assert.match(result.stderr, /LAN_BIND_IP (?:is not set|has a character that is not allowed|must be one private IPv4 address)/, JSON.stringify(ip));
  }
  for (const value of ['1024', '8080', '65535']) assert.equal(run(lanFlags('192.168.1.0/24', { LAN_HTTP_PORT: value }), 'nginx', '-t').status, 0, value);
  for (const value of [undefined, '', '80', '1023', '65536', '0', '08080x', '8080;', '-1', 'http']) {
    const result = run(lanFlags('192.168.1.0/24', { LAN_HTTP_PORT: value }), 'nginx', '-t');
    assert.notEqual(result.status, 0, `started with LAN_HTTP_PORT ${JSON.stringify(value)}`);
    assert.match(result.stderr, /LAN_HTTP_PORT (?:is not set|has a character that is not allowed|must be a port from 1024 to 65535)/, JSON.stringify(value));
  }
});

let lanPort;
let lanOutPort;
let lanOldPort;
let labSubnet;
let labGateway;
let stubAddress;
// Starts a LAN container on the lab network, limited like the Compose service. The container is ready when its own health check answers (it comes
// from the Host 127.0.0.1:8080, which the pin lets through).
async function startLan(name, cidr, over = {}, keys = {}) {
  const run = docker(['run', '-d', '--name', name, '--network', NETWORK, '-p', '127.0.0.1::8080', '--memory', '128m', '--cpus', '0.5', ...HARDENING, ...environment(keys), ...lanFlags(cidr, over), IMAGE]);
  assert.equal(run.status, 0, run.stderr);
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (docker(['exec', name, 'wget', '-q', '-T', '2', '-O', '-', 'http://127.0.0.1:8080/health']).stdout === 'ok\n') return Number(/:(\d+)\s*$/m.exec(docker(['port', name, '8080/tcp']).stdout)[1]);
    await new Promise(done => setTimeout(done, 200));
  }
  return assert.fail(`the LAN gateway did not answer: ${docker(['logs', name]).stderr}`);
}
async function startLanLab() {
  if (lanPort) return;
  await startLab();
  const network = JSON.parse(docker(['network', 'inspect', NETWORK]).stdout)[0].IPAM.Config[0];
  labSubnet = network.Subnet;
  labGateway = network.Gateway;
  stubAddress = docker(['inspect', '--format', `{{(index .NetworkSettings.Networks "${NETWORK}").IPAddress}}`, STUB]).stdout.trim();
  // The allow list is a private range (the entrypoint insists): Docker's default pools are all private.
  assert.match(labSubnet, /^(?:10\.|172\.(?:1[6-9]|2\d|3[01])\.|192\.168\.)/, `the lab network ${labSubnet} is private`);
  lanPort = await startLan(GATEWAY_LAN, labSubnet);
  // A second one that allows another private range: the host and the stand-in are both outside it.
  lanOutPort = await startLan(GATEWAY_LAN_OUT, '10.255.255.0/24');
}
// A request to a LAN container from the host (the published port) with the Host a phone writes: the address and port of the LAN server.
const lanGet = (path, options = {}, target = lanPort) => request(path, { ...options, port: target, headers: { host: LAN_HOST, ...options.headers } });
// A request from the stand-in container, a second client of the LAN container with an address of its own. wget (busybox) prints the
// status line and headers on stderr with -S, and the body only for a 2xx answer. It writes the Host a phone writes, unless told otherwise.
function fromStub(path, headers = {}, target = GATEWAY_LAN) {
  const flags = Object.entries({ Host: LAN_HOST, ...headers }).flatMap(([name, value]) => ['--header', `${name}: ${value}`]);
  const result = docker(['exec', STUB, 'wget', '-q', '-S', '-T', '10', '-O', '-', ...flags, `http://${target}:8080${path}`]);
  const status = Number([...result.stderr.matchAll(/HTTP\/1\.\d (\d{3})/g)].at(-1)?.[1]);
  const header = name => new RegExp(`^\\s*${name}: (.*)$`, 'im').exec(result.stderr)?.[1]?.trim();
  return { status, header, text: result.stdout };
}

test('LAN: the address is the connection\'s, whatever a client writes in a header, and the answer says it came by the LAN', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLanLab();
  // Only one listener in the container: 8080.
  const listening = docker(['exec', GATEWAY_LAN, 'netstat', '-ltn']).stdout;
  // (Docker's own resolver, 127.0.0.11, is in the list of every container on a user-defined network.)
  assert.deepEqual([...listening.matchAll(/^tcp\s+\d+\s+\d+\s+(\S+)\s/gm)].map(match => match[1]).filter(address => !address.startsWith('127.0.0.11:')), ['0.0.0.0:8080']);
  // Forged headers from a client that is not on the host's side: the stand-in's own address is what the upstream and the log see.
  const forged = { 'CF-Connecting-IP': '203.0.113.9', 'X-Forwarded-For': '1.2.3.4', 'X-Real-IP': '5.6.7.8' };
  for (const path of ['/functions/v1/get-public-config?a=1', '/rest/v1/rpc/x']) {
    const answer = fromStub(path, path.startsWith('/rest') ? { ...forged, apikey: ANON } : forged);
    assert.equal(answer.status, 200, path);
    const seen = echoed(answer.text);
    assert.equal(seen.cfip, stubAddress, `${path}: CF-Connecting-IP is the connection's address, not the forged one`);
    assert.equal(seen.xri, stubAddress);
    assert.equal(seen.xff, stubAddress);
    assert.equal(answer.header('x-warehouse-path'), 'lan');
  }
  // Storage is still not sent an address.
  assert.equal(echoed(fromStub('/storage/v1/object/x', forged).text).cfip, '');
  // The public container on the same network trusts the hop (the tunnel's) and takes the header: this is the difference between the two.
  const publicSeen = echoed((await request('/functions/v1/x', { headers: forged })).text);
  assert.equal(publicSeen.cfip, '203.0.113.9');
  assert.equal((await request('/functions/v1/x', { headers: forged })).headers['x-warehouse-path'], 'public');
  // The log line is the checker's format with the connection's address in front.
  const log = docker(['logs', GATEWAY_LAN]);
  assert.match(`${log.stdout}\n${log.stderr}`, new RegExp(`^${stubAddress.replace(/\./g, '\\.')} \\[[^\\]]+\\] "GET /functions/v1/get-public-config HTTP/1\\.1" 200 \\d+ [0-9.]+$`, 'm'));
  assert.doesNotMatch(`${log.stdout}\n${log.stderr}`, /203\.0\.113\.9|1\.2\.3\.4|\?a=1/);
});

test('LAN: the Host header must be the host\'s own LAN address (with or without the port); any other Host is a 404 that names the path and reaches nothing', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLanLab();
  const marker = randomBytes(6).toString('hex');
  const okMarker = randomBytes(6).toString('hex');
  // A phone writes the address and the port, as the app addresses the server by its IP address. The bare address is accepted too.
  for (const host of [LAN_HOST, LAN_IP]) {
    // (The storage route: it has no rate limit, so the buckets the rate-limit test below counts are untouched.)
    const ok = await lanGet(`/storage/v1/object/pin-ok-${okMarker}`, { headers: { host } });
    assert.equal(ok.status, 200, host);
    assert.equal(ok.headers['x-warehouse-path'], 'lan');
  }
  assert.equal((await lanGet('/rest/v1/rpc/x', { headers: { apikey: ANON } })).status, 200);
  // A web page reaching this address through DNS rebinding carries the page's own name: the name, the name with the port, another address, the
  // right address with another port, localhost, an IPv6 literal, a missing Host (HTTP/1.0).
  const before = docker(['logs', STUB]);
  for (const host of ['rebind.attacker.example', `rebind.attacker.example:${LAN_PORT}`, '192.168.77.21', `192.168.77.21:${LAN_PORT}`, `${LAN_IP}:9999`, `${LAN_IP}:`, 'localhost', `localhost:${LAN_PORT}`, '127.0.0.1', '127.0.0.1:9999', '[::1]:8080', `${LAN_IP}.evil.example`, `x${LAN_IP}`]) {
    for (const path of [`/functions/v1/pin-denied-${marker}`, `/rest/v1/rpc/pin-denied-${marker}`, `/storage/v1/object/pin-denied-${marker}`, `/pin-denied-${marker}`]) {
      const answer = await lanGet(path, { headers: { host, apikey: ANON } });
      assert.equal(answer.status, 404, `${host} ${path}`);
      assert.equal(answer.text, '{"message":"no Route matched with those values"}', `${host} ${path}: the answer of any unknown path, nothing of the API`);
      assert.equal(answer.headers['x-warehouse-path'], 'lan', `${host}: the answer names its path`);
      assert.doesNotMatch(answer.text, new RegExp(marker));
    }
  }
  // Also from a second client on the network (the stand-in), and an OPTIONS preflight, which the routes answer before anything else.
  assert.equal(fromStub(`/functions/v1/pin-denied-${marker}`, { Host: 'rebind.attacker.example' }).status, 404);
  const preflight = await lanGet('/rest/v1/rpc/x', { method: 'OPTIONS', headers: { host: 'rebind.attacker.example', Origin: ORIGIN, 'Access-Control-Request-Method': 'POST' } });
  assert.equal(preflight.status, 404, 'a preflight with a wrong Host is not answered 204 either');
  // No Host at all (an HTTP/1.0 request): the pin refuses it.
  const bare = docker(['exec', STUB, 'sh', '-c', `printf 'GET /functions/v1/pin-denied-${marker} HTTP/1.0\\r\\n\\r\\n' | nc -w 5 ${GATEWAY_LAN} 8080`]);
  assert.match(bare.stdout, /^HTTP\/1\.1 404 /, bare.stdout + bare.stderr);
  // None of them reached an upstream, and none used a rate-limit bucket (the pin comes before both).
  const after = docker(['logs', STUB]);
  assert.doesNotMatch(`${after.stdout}\n${after.stderr}`, new RegExp(`pin-denied-${marker}`), 'a refused request never reached an upstream');
  assert.equal(`${before.stdout}${before.stderr}`.includes(marker), false);
  // The pin is in front of the allow list: a wrong Host on the container that does not allow this client is a 404, not the 403.
  assert.equal((await lanGet('/functions/v1/x', { headers: { host: 'rebind.attacker.example' } }, lanOutPort)).status, 404);
  // The container's own health check (Host 127.0.0.1:8080) still works, and a client that writes it gets the 404 of any path (only the container may ask).
  assert.equal(docker(['exec', GATEWAY_LAN, 'wget', '-q', '-T', '5', '-O', '-', 'http://127.0.0.1:8080/health']).stdout, 'ok\n');
  assert.equal((await lanGet('/health')).status, 404);
});

test('LAN: the key check, the body limit and the rate limit are the public path\'s, and every kind of answer names its path', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLanLab();
  // From the host (the published port): any address inside the lab network, the bridge's own among them, is allowed.
  const get = lanGet;
  const missing = await get('/rest/v1/rpc/x');
  assert.equal(missing.status, 401);
  assert.equal(missing.text, '{"message":"No API key found in request"}');
  assert.equal(missing.headers['www-authenticate'], 'Key');
  assert.equal((await get('/rest/v1/rpc/x', { headers: { apikey: `${ANON}x` } })).text, '{"message":"Unauthorized"}');
  assert.equal((await get('/rest/v1/rpc/x', { headers: { apikey: ANON } })).status, 200);
  const preflight = await get('/rest/v1/rpc/x', { method: 'OPTIONS', headers: { Origin: 'https://evil.example.test', 'Access-Control-Request-Method': 'POST' } });
  assert.equal(preflight.status, 204);
  const unknown = await get('/nothing', { headers: { apikey: ANON } });
  assert.equal(unknown.status, 404);
  assert.equal(unknown.text, '{"message":"no Route matched with those values"}');
  const big = await get('/functions/v1/x', { method: 'POST', headers: { 'content-length': String(10 * 1024 * 1024 + 1) }, body: Buffer.alloc(10 * 1024 * 1024 + 1, 120) }).catch(error => ({ status: error.code, headers: {}, text: '' }));
  assert.ok(big.status === 413 || big.status === 'ECONNRESET' || big.status === 'EPIPE', `HTTP ${big.status}`);
  if (big.status === 413) assert.equal(big.text, '{"message":"Request size limit exceeded"}');
  // The path header is on every kind of answer the routes make: success, 401, 404, the preflight and (below) 429.
  for (const answer of [missing, unknown, preflight, await get('/functions/v1/x'), await get('/storage/v1/object/x')]) assert.equal(answer.headers['x-warehouse-path'], 'lan');
  assert.deepEqual(missing.all('x-warehouse-path'), ['lan'], 'once');
  // /health answers the container itself only; a client gets the 404 of any unknown path (not the allow-list's 403: `return` is first).
  assert.equal(docker(['exec', GATEWAY_LAN, 'wget', '-q', '-T', '5', '-O', '-', 'http://127.0.0.1:8080/health']).stdout, 'ok\n');
  assert.equal((await get('/health')).status, 404);
  // The limit is per connection address, not per header: 100 pass, then 429, and a new forged address does not get a bucket of its own.
  let passed = 0;
  let refused;
  for (let i = 0; !refused && i < 200; i += 1) {
    const answer = await get('/functions/v1/x', { headers: { 'CF-Connecting-IP': address() } });
    if (answer.status === 429) refused = answer; else { assert.equal(answer.status, 200); passed += 1; }
  }
  assert.ok(refused, `no 429 after ${passed} requests`);
  assert.ok(passed >= 95 && passed <= 110, `${passed} requests passed`);
  assert.equal(refused.text, '{"message":"API rate limit exceeded"}');
  assert.equal(refused.headers['x-warehouse-path'], 'lan');
  assert.equal((await get('/functions/v1/x', { headers: { 'CF-Connecting-IP': address() } })).status, 429, 'a forged address is no way round the limit');
  // Another client of the LAN (the stand-in, another address) has a bucket of its own: per phone, not per facility.
  assert.equal(fromStub('/functions/v1/x').status, 200);
});

test('LAN: a client outside LAN_CIDR is refused 403 (naming the LAN path) on every route that reaches the allow list, and nothing reaches an upstream', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLanLab();
  const marker = randomBytes(6).toString('hex');
  const upstreamBefore = docker(['logs', STUB]);
  for (const path of [`/functions/v1/denied-${marker}`, `/storage/v1/object/denied-${marker}`, `/rest/v1/rpc/denied-${marker}`]) {
    const answer = await lanGet(path, { headers: { apikey: ANON, 'CF-Connecting-IP': '10.255.255.7' } }, lanOutPort);
    assert.equal(answer.status, 403, path);
    assert.equal(answer.headers['x-warehouse-path'], 'lan', `${path}: the 403 names the LAN path (the app tells it from a Cloudflare answer by this header)`);
    assert.doesNotMatch(answer.text, new RegExp(marker));
    // A header that names an address inside the range changes nothing: the connection's address decides.
    assert.equal(fromStub(path, { 'CF-Connecting-IP': '10.255.255.7', apikey: ANON }, GATEWAY_LAN_OUT).status, 403, `${path} from the stand-in`);
  }
  const after = docker(['logs', STUB]);
  assert.doesNotMatch(`${after.stdout}\n${after.stderr}`, new RegExp(`denied-${marker}`), 'a refused request never reached an upstream');
  assert.equal(`${upstreamBefore.stdout}${upstreamBefore.stderr}`.includes(marker), false);
  // The same kind of request through the container that allows the lab network is answered (from the stand-in: the host's own
  // bucket on that container was used up by the rate-limit test above).
  assert.equal(fromStub(`/functions/v1/allowed-${marker}`).status, 200);
});

test('LAN: the probe of the key check passes with the keys the container was started with, and fails with the gateway\'s own 401 when the container holds old ones', { skip }, async t => {
  if (unbuilt) return t.skip(unbuilt);
  await startLanLab();
  // What probeLanKeys (scripts/lan-common.mjs, used by doctor and by the checker) sends: GET /rest/v1/ with the anon key. It reaches the lab container
  // by its published port, with the Host the pin wants (a stand-in for fetch that changes only where the connection goes).
  const lan = { ip: LAN_IP, port: LAN_PORT };
  // (fetch cannot write the Host header, so the stand-in uses the lab's own request helper and returns what probeLanKeys reads.)
  const via = target => async (url, init) => {
    assert.equal(String(url), `http://${LAN_HOST}/rest/v1/`, 'the probe asks the LAN address for the REST root, with the anon key');
    assert.equal(init.headers.apikey, ANON);
    const answer = await request('/rest/v1/', { port: target, headers: { ...init.headers, host: LAN_HOST } });
    return { status: answer.status, ok: answer.status < 400, json: async () => JSON.parse(answer.text) };
  };
  assert.deepEqual(await probeLanKeys(lan, ANON, via(lanPort)), { ok: true });
  // A key rotation changes the keys of compose.env; a container that was not recreated still has the old ones. Started here with other keys.
  const oldSecret = createHash('sha384').update('warehouse gateway lab test, before the rotation').digest('hex');
  lanOldPort = await startLan(GATEWAY_LAN_OLD, labSubnet, {}, { ANON_KEY: signRoleKey(oldSecret, 'anon'), SERVICE_ROLE_KEY: signRoleKey(oldSecret, 'service_role') });
  const stale = await probeLanKeys(lan, ANON, via(lanOldPort));
  assert.equal(stale.ok, false);
  assert.match(stale.text, /refuses the anon key of this installation \(HTTP 401 from the gateway\).*before a key rotation/);
  assert.match(stale.text, /--force-recreate --no-deps gateway-lan/);
  // The probe that does not need a key still passes against that container: this is the blind spot the key probe closes.
  assert.equal((await lanGet('/functions/v1/get-public-config', {}, lanOldPort)).status, 200);
  // The REST route answers the anon key of the lab's own container with the stand-in's 200; the same request without the key is the gateway's 401.
  assert.equal((await lanGet('/rest/v1/', { headers: { apikey: ANON } }, lanOldPort)).status, 401);
  assert.equal((await lanGet('/rest/v1/', { headers: { apikey: ANON } }, lanPort)).status, 200);
});
