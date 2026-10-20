import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { composeAvailable, renderedCompose } from './compose-render.mjs';

const kong = readFileSync(new URL('../docker/kong.yml', import.meta.url), 'utf8');
const compose = readFileSync(new URL('../docker/docker-compose.yml', import.meta.url), 'utf8');
const deploy = name => new URL(`../deploy/${name}`, import.meta.url);
// One service's entry in kong.yml, up to the next service.
const serviceBlock = name => {
  const start = kong.indexOf(`\n  - name: ${name}\n`);
  assert.ok(start > 0, `${name} is not a gateway service`);
  const next = kong.slice(start + 1).search(/\n  (?:- name: |## )/);
  return kong.slice(start, next < 0 ? undefined : start + 1 + next);
};

test('gateway uses an exact configured browser origin and payload limits', () => {
  assert.ok(kong.includes('origins: [${CORS_ALLOWED_ORIGIN}]'));
  assert.ok(!kong.includes('origins: [*]'));
  assert.ok(kong.match(/name: request-size-limiting/g).length >= 3);
  assert.ok(compose.includes('request-size-limiting'));
  assert.ok(compose.includes('CORS_ALLOWED_ORIGIN:'));
});

test('gateway refreshes replaced Compose upstream addresses within readiness budget', () => {
  assert.ok(compose.includes('KONG_DNS_VALID_TTL: "5"'));
  assert.ok(compose.includes('KONG_DNS_STALE_TTL: "1"'));
  assert.ok(compose.includes('KONG_DNS_NOT_FOUND_TTL: "1"'));
});

test('operator gateway cannot route Studio or postgres-meta', () => {
  assert.doesNotMatch(kong, /url: http:\/\/(?:studio|meta):/);
  assert.equal((compose.match(/^\s+ports:/gm) || []).length, 1);
});

test('gateway takes the client address from the tunnel hop only and limits per client IP', () => {
  assert.ok(compose.includes('KONG_REAL_IP_HEADER: CF-Connecting-IP'));
  assert.ok(compose.includes('KONG_REAL_IP_RECURSIVE: "off"'));
  assert.ok(compose.includes('KONG_TRUSTED_IPS: "127.0.0.1/32,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"'));
  assert.equal((kong.match(/name: rate-limiting/g) || []).length, 2);
  assert.equal((kong.match(/^\s+limit_by: ip$/gm) || []).length, 2);
  // Every route that needs only the public key or no key at all is limited per
  // client address, except storage (see docs/CONTAINER_SECURITY.md).
  // The REST route has a per-minute limit only (null): see the next two tests.
  const limits = { 'rest-v1': [1800, null], 'functions-v1': [100, 6000] };
  for (const [service, [minute, hour]] of Object.entries(limits)) {
    const rateLimit = serviceBlock(service).split('- name: rate-limiting')[1]?.split('      - name: ')[0];
    assert.ok(rateLimit, `${service} has no rate limit`);
    const hourLine = hour === null ? '' : `hour: ${hour}\\n\\s+`;
    assert.match(rateLimit, new RegExp(`minute: ${minute}\\n\\s+${hourLine}policy: local\\n\\s+fault_tolerant: true\\n[\\s\\S]*limit_by: ip\\n`), `${service} rate limit`);
  }
  assert.doesNotMatch(serviceBlock('storage-v1'), /rate-limiting/);
  for (const [service, megabytes] of Object.entries({ 'rest-v1': 10, 'storage-v1': 50, 'functions-v1': 10 })) {
    assert.match(serviceBlock(service), new RegExp(`- name: request-size-limiting\\n\\s+config:\\n\\s+allowed_payload_size: ${megabytes}\\n`), `${service} payload limit`);
  }
});

test('the REST limit leaves a whole facility room to work and cannot lock it out for an hour', () => {
  // Every phone on the facility network reaches the gateway from one public address, so the
  // facility shares one counter (docs/CONTAINER_SECURITY.md, REST request limit; owner decision
  // of 2026-10-11). The old limit of 300 a minute and 6000 an hour gave 100 phones 3 requests a
  // minute each and 60 an hour each, and once the hour was used up every phone was refused
  // until it ended.
  const devices = 100;
  const rateLimit = serviceBlock('rest-v1').split('- name: rate-limiting')[1].split('      - name: ')[0];
  const minute = Number(rateLimit.match(/^\s+minute: (\d+)$/m)[1]);
  assert.equal(minute, 1800);
  assert.equal(minute / devices, 18, 'requests a minute for each of 100 phones working at once');
  // The only window is the minute. Nothing longer: a refused request can be sent again when the
  // next minute starts. Nothing shorter either: there is no per-second brake (next test).
  assert.doesNotMatch(rateLimit, /^\s+(second|hour|day|month|year):/m);
  assert.match(rateLimit, /^\s+limit_by: ip$/m);
});

test('the per-minute limits are described as a budget per fixed minute, not as a ceiling per second', () => {
  // Kong's rate-limiting plugin counts in fixed windows. 1800 a minute is about 30 a second on
  // average, but one address may send all 1800 in the first second of a minute and 1800 more
  // when the next minute starts. Wording such as "stops more than 30 requests a second" promises
  // a brake the gateway does not have.
  const docs = readFileSync(new URL('../docs/CONTAINER_SECURITY.md', import.meta.url), 'utf8');
  const section = (from, to) => { const start = docs.indexOf(from); assert.ok(start > 0, from); return docs.slice(start, docs.indexOf(to, start + from.length)); };
  const restComment = serviceBlock('rest-v1').split('- name: rate-limiting')[1].split('minute: 1800')[0];
  const texts = {
    'docker/kong.yml, rest-v1': restComment,
    'docs/CONTAINER_SECURITY.md, REST request limit': section('### REST request limit', '\n## '),
  };
  for (const [where, text] of Object.entries(texts)) {
    const plain = text.replace(/^\s*#\s?/gm, '').replace(/\s+/g, ' ');
    assert.match(plain, /fixed minute/, `${where} does not say the window is a fixed minute`);
    assert.match(plain, /about 30 a second on average/, `${where} does not call 30 a second an average`);
    assert.match(plain, /no per-second brake/, `${where} does not say there is no per-second brake`);
    assert.doesNotMatch(plain, /(more than|faster than) 30 (requests )?a second/, `${where} promises a per-second ceiling`);
    assert.doesNotMatch(plain, /(sent|starts) again within the minute/, `${where} says a refused request can be repeated within the same minute`);
  }
  // No route has a per-second window; if one is added, the wording above has to change with it.
  assert.doesNotMatch(kong, /^\s+second: \d+$/m);
});

test('gateway has no metrics plugin, status listener or metrics port: the monitoring checker reads Docker and the HTTP answers, not Kong metrics', () => {
  assert.doesNotMatch(kong, /prometheus|status_code_metrics|latency_metrics/);
  assert.doesNotMatch(kong, /\nplugins:\n/, 'kong.yml has no global plugin');
  assert.doesNotMatch(compose, /KONG_STATUS_LISTEN|prometheus/);
  assert.doesNotMatch(readFileSync(new URL('../docker/docker-compose.override.yml', import.meta.url), 'utf8'), /KONG_STATUS_LISTEN|8100/);
});

test('gateway configuration survives the entrypoint that fills in its variables', () => {
  // The entrypoint evaluates the file as a double-quoted shell string
  // (docker-compose.yml), so a double quote, backtick, backslash or a dollar
  // sign outside ${NAME} in kong.yml, even in a comment, changes the result.
  const values = { SUPABASE_ANON_KEY: 'unit.anon.key', SUPABASE_SERVICE_KEY: 'unit.service.key', CORS_ALLOWED_ORIGIN: 'https://app.example.test' };
  assert.ok(compose.includes(String.raw`entrypoint: bash -c 'eval "echo \"$$(cat /tmp/temp.yml)\"" > /tmp/kong.yml && `), 'entrypoint changed; revisit this test');
  const rendered = spawnSync('bash', ['-c', 'eval "echo \\"$(cat "$1")\\""', 'render', new URL('../docker/kong.yml', import.meta.url).pathname], { encoding: 'utf8', env: { PATH: process.env.PATH, ...values } });
  assert.equal(rendered.status, 0, rendered.stderr);
  assert.equal(rendered.stdout, kong.replace(/\$\{([A-Z_]+)\}/g, (_, name) => values[name]).replace(/\n*$/, '\n'));
  assert.deepEqual([...new Set([...kong.matchAll(/\$\{([A-Z_]+)\}/g)].map(match => match[1]))].sort(), Object.keys(values).sort());
});

// The Kong environment as the container sees it. Compose writes a literal dollar sign as `$$`
// in the file, and `docker compose config` prints it that way again; the container gets one.
const dollars = text => String(text).replaceAll('$$', '$');
const FORBIDDEN_IN_ACCESS_LOG = [
  // The request line and anything that carries the query string.
  /\$request(?![_a-z])/, /\$request_uri/, /\$args/, /\$is_args/, /\$query_string/, /\$arg_/, /\$upstream_uri/, /\$upstream_x_forwarded_path/,
  // Fields that can carry a credential or a person.
  /\$http_/, /\$remote_user/, /\$cookie_/,
];
function assertRedactedAccessLog(environment, where) {
  const format = dollars(environment.KONG_NGINX_HTTP_LOG_FORMAT);
  assert.match(format, /^warehouse_redacted '[^']+'$/, `${where}: the format is defined under the name warehouse_redacted`);
  assert.ok(format.includes('$uri'), `${where}: the path is logged as $uri (no query string)`);
  assert.ok(format.includes('$remote_addr'), `${where}: the client address stays in the log (owner decision of 2026-10-17)`);
  for (const pattern of FORBIDDEN_IN_ACCESS_LOG) assert.doesNotMatch(format, pattern, `${where}: the format must not contain ${pattern}`);
  assert.equal(environment.KONG_PROXY_ACCESS_LOG, '/dev/stdout warehouse_redacted', `${where}: the proxy access log uses the redacted format`);
}

test('the gateway access log has no query string, so a signed link or an apikey in a URL is not kept', () => {
  // Kong's default format logs `$request`, the whole request line with ?token= and ?apikey=.
  const text = compose.match(/^\s+KONG_NGINX_HTTP_LOG_FORMAT: (".*")$/m);
  assert.ok(text, 'docker-compose.yml sets KONG_NGINX_HTTP_LOG_FORMAT');
  const [, access] = compose.match(/^\s+KONG_PROXY_ACCESS_LOG: "([^"]+)"$/m) ?? [];
  assert.equal(access, '/dev/stdout warehouse_redacted');
  // YAML double-quoted: \" is a quote. Compose then turns $$ into $.
  const environment = { KONG_NGINX_HTTP_LOG_FORMAT: JSON.parse(text[1]), KONG_PROXY_ACCESS_LOG: access };
  assertRedactedAccessLog(environment, 'docker-compose.yml');
  // Written with $$ in the file: a single $ would be read by Compose as a variable (and warned about).
  assert.ok(!/\$[a-z_]+/.test(environment.KONG_NGINX_HTTP_LOG_FORMAT.replaceAll('$$', '')), 'every dollar sign in the format is doubled for Compose');
  // The override file adds resources and logging only; it must not put the default format back.
  const override = readFileSync(new URL('../docker/docker-compose.override.yml', import.meta.url), 'utf8');
  assert.doesNotMatch(override, /KONG_PROXY_ACCESS_LOG|KONG_NGINX_HTTP_LOG_FORMAT/);
  // kong.yml is evaluated by the entrypoint: no log format may be defined there.
  assert.doesNotMatch(kong, /log_format|access_log/);
});

test('the rendered Kong environment selects the redacted access log', { skip: !composeAvailable() && !process.env.CI ? 'docker compose is not installed' : false }, () => {
  assertRedactedAccessLog(renderedCompose().services.kong.environment, 'docker compose config');
});

test('storage is not sent the CF-Connecting-IP header, and the log contract says what it cannot remove', () => {
  const storage = serviceBlock('storage-v1');
  assert.match(storage, /- name: request-transformer\n\s+config:\n\s+remove:\n\s+headers:\n\s+- CF-Connecting-IP\n/);
  // Kong adds X-Real-IP and X-Forwarded-For itself after the plugins ran, so listing them would promise too much.
  assert.doesNotMatch(storage, /^\s+- (?:X-Real-IP|X-Forwarded-For)$/im);
  const docs = readFileSync(new URL('../docs/CONTAINER_SECURITY.md', import.meta.url), 'utf8');
  const start = docs.indexOf('\n## Logs\n');
  assert.ok(start > 0, 'docs/CONTAINER_SECURITY.md has the Logs section');
  const section = docs.slice(start + 1, docs.indexOf('\n## ', start + 1)).replace(/\s+/g, ' ');
  for (const needed of ['warehouse_redacted', 'no log line holds a token, a key, an OTP', 'X-Real-IP', 'X-Forwarded-For', 'error log', '3 x 10 MB']) {
    assert.ok(section.toLowerCase().includes(needed.toLowerCase()), `the Logs section does not mention ${needed}`);
  }
});

test('every REST request passes the session check before its function runs', () => {
  // public.check_session refuses an ended session and a profile that is disabled or
  // not approved. Functions that resolve the caller themselves (own_profile_id in
  // migration 38 checks active only) rely on it for the enrollment state; see
  // tests/preferred_language.sql.
  assert.match(compose, /\n\s+PGRST_DB_PRE_REQUEST: public\.check_session\n/);
});

const withoutComments = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8').split('\n').filter(line => !line.trim().startsWith('--')).join('\n');

test('the JWT signing secret is not published as a database or PostgREST setting', () => {
  // TW-BE-003: "app.settings.jwt_secret" is readable by every database role through current_setting().
  // The database code reads warehouse_security.auth_config; PostgREST takes the secret from PGRST_JWT_SECRET.
  assert.doesNotMatch(compose, /APP_SETTINGS_JWT_SECRET/, 'PostgREST must not set the secret as an app setting');
  assert.match(compose, /\n\s+PGRST_JWT_SECRET: \$\{JWT_SECRET\}\n/, 'PostgREST still verifies tokens');
  // Nothing reads app.settings.jwt_exp (the database code takes the lifetime from warehouse_security.auth_config), so no
  // database setting and no PostgREST app setting carries it either.
  assert.doesNotMatch(compose, /APP_SETTINGS_JWT_EXP/, 'PostgREST must not set the expiry as an app setting');
  assert.ok(!existsSync(new URL('../docker/volumes/db/jwt.sql', import.meta.url)), 'jwt.sql is gone: nothing sets app.settings.jwt_exp');
  assert.doesNotMatch(withoutComments('scripts/rotate-auth.sql'), /app\.settings\.jwt_secret/, 'rotation must not set the secret as a database setting');
  // Every run of the auth configuration removes it again, at database level and for roles.
  const configure = withoutComments('scripts/configure-auth.sql');
  assert.match(configure, /ALTER DATABASE %I RESET "app\.settings\.jwt_secret"/);
  assert.match(configure, /ALTER ROLE %I IN DATABASE %I RESET "app\.settings\.jwt_secret"/);
  assert.match(configure, /ALTER ROLE %I RESET "app\.settings\.jwt_secret"/);
  assert.doesNotMatch(configure, /(?<![A-Z])SET "app\.settings\.jwt_secret"/, 'configure-auth.sql must only reset the setting');
});

test('the rendered Compose project has no app setting that carries the JWT signing secret', { skip: !composeAvailable() && !process.env.CI ? 'docker compose is not installed' : false }, () => {
  const { services } = renderedCompose();
  assert.ok(services.rest.environment.PGRST_JWT_SECRET, 'PostgREST has no secret to verify tokens with');
  for (const [name, definition] of Object.entries(services)) {
    const settings = Object.keys(definition.environment ?? {}).filter(key => /APP_SETTINGS_JWT_SECRET/.test(key));
    assert.deepEqual(settings, [], `${name} publishes the signing secret as an app setting`);
  }
  assert.equal(services.rest.environment.PGRST_APP_SETTINGS_JWT_EXP, undefined, 'the expiry app setting is not set');
});

test('ingress is Cloudflare Tunnel only', () => {
  assert.ok(!existsSync(deploy('Caddyfile.example')), 'Caddy example must not ship');
  assert.ok(existsSync(deploy('cloudflared-config.example.yml')));
  const tunnel = readFileSync(deploy('cloudflared-config.example.yml'), 'utf8');
  assert.ok(tunnel.includes('service: http://127.0.0.1:18000'));
  assert.ok(tunnel.includes('noTLSVerify: false'));
  assert.ok(tunnel.includes('service: http_status:404'));
});

test('publisher images are pinned by digest and the notices name the versions in use', () => {
  const override = readFileSync(new URL('../docker/docker-compose.override.yml', import.meta.url), 'utf8');
  const images = [...`${compose}\n${override}`.matchAll(/^\s+image: (\S+)$/gm)].map(match => match[1]).filter(image => !image.endsWith(':local'));
  assert.ok(images.some(image => /^kong:3\.9\.3-ubuntu@sha256:[0-9a-f]{64}$/.test(image)), 'Kong is not pinned by digest');
  assert.ok(images.some(image => /^postgrest\/postgrest:v[0-9.]+@sha256:[0-9a-f]{64}$/.test(image)), 'PostgREST is not pinned by digest');
  assert.deepEqual(images.filter(image => !/@sha256:[0-9a-f]{64}$/.test(image)), [], 'every pulled image is pinned by digest');

  const notices = readFileSync(new URL('../THIRD_PARTY_NOTICES.md', import.meta.url), 'utf8');
  const review = readFileSync(new URL('../docs/ATTRIBUTION_REVIEW.md', import.meta.url), 'utf8');
  const base = (recipe, image) => new RegExp(`^FROM ${image}:([^@\\s]+)@sha256:`, 'm').exec(readFileSync(new URL(`../docker/${recipe}/Dockerfile`, import.meta.url), 'utf8'))?.[1];
  const versions = {
    Kong: /image: kong:([0-9.]+)-ubuntu/.exec(compose)[1],
    PostgREST: /image: postgrest\/postgrest:(v[0-9.]+)/.exec(compose)[1],
    Supavisor: base('supavisor', 'supabase/supavisor'),
    'edge-runtime': base('edge-runtime', 'supabase/edge-runtime'),
    // The PDF renderer's pins: the chrome-headless-shell build and puppeteer-core (docker/pdf-renderer).
    'Chrome for Testing': /^ARG CHS_VERSION=(\S+)$/m.exec(readFileSync(new URL('../docker/pdf-renderer/Dockerfile', import.meta.url), 'utf8'))?.[1],
    'puppeteer-core': JSON.parse(readFileSync(new URL('../docker/pdf-renderer/package.json', import.meta.url), 'utf8')).dependencies?.['puppeteer-core'],
    // The sensor bridge (GPL-3.0-or-later): its base image and the GPL library it installs.
    Python: base('sensor-bridge', 'python'),
    'python-kasa': /^python-kasa==([0-9][0-9.]*)\b/m.exec(readFileSync(new URL('../docker/sensor-bridge/requirements.txt', import.meta.url), 'utf8'))?.[1],
  };
  for (const [name, version] of Object.entries(versions)) {
    assert.ok(version, `${name} version was not read`);
    const row = notices.split('\n').find(line => line.startsWith('|') && line.includes(name) && line.includes(version));
    assert.ok(row, `THIRD_PARTY_NOTICES.md does not name ${name} ${version}`);
    assert.ok(new RegExp(`${name} ${version.replaceAll('.', '\\.')}[,) ]`).test(review), `docs/ATTRIBUTION_REVIEW.md does not name ${name} ${version}`);
  }
  assert.doesNotMatch(`${notices}\n${review}`, /v1\.76\.2|postgrest:v14\.17|PostgREST v14\.17/);
});

test('the gateway compresses JSON and text answers only, so a large invoice-form preview is sent gzipped', () => {
  const value = name => compose.match(new RegExp(`^\\s+${name}: "?([^"\\n]+)"?$`, 'm'))?.[1];
  assert.equal(value('KONG_NGINX_PROXY_GZIP'), 'on');
  assert.equal(value('KONG_NGINX_PROXY_GZIP_PROXIED'), 'any', 'answers that came through the tunnel proxy are compressed too');
  assert.equal(Number(value('KONG_NGINX_PROXY_GZIP_MIN_LENGTH')), 1024);
  assert.equal(value('KONG_NGINX_PROXY_GZIP_VARY'), 'on');
  const types = (value('KONG_NGINX_PROXY_GZIP_TYPES') ?? '').split(/\s+/);
  for (const type of ['application/json', 'application/vnd.pgrst.object+json', 'application/vnd.pgrst.array+json', 'text/plain', 'text/csv']) {
    assert.ok(types.includes(type), `${type} is compressed`);
  }
  // Images, PDFs and other downloads stay as stored; the websocket upgrade is not an answer type.
  assert.ok(!types.some(type => /^(image|video|audio)\//.test(type) || /pdf|octet-stream|zip/.test(type)), 'no binary type is listed');
});

const FIVE_PLUGINS = ['cors', 'key-auth', 'rate-limiting', 'request-size-limiting', 'request-transformer'];
const withoutYamlComments = text => text.replace(/^\s*#.*$/gm, '');

test('gateway runs one worker, loads only the plugins its routes use, and has no ACL or unused route', () => {
  const live = withoutYamlComments(compose);
  assert.ok(live.includes('KONG_NGINX_WORKER_PROCESSES: "1"'));
  const plugins = live.match(/KONG_PLUGINS: (\S+)/)[1].split(',');
  assert.deepEqual([...plugins].sort(), FIVE_PLUGINS);
  // The plugin list lives in the base file only; the override must not carry a second copy.
  const override = withoutYamlComments(readFileSync(new URL('../docker/docker-compose.override.yml', import.meta.url), 'utf8'));
  assert.doesNotMatch(override, /KONG_PLUGINS|KONG_NGINX_WORKER_PROCESSES/);
  assert.doesNotMatch(compose, /DASHBOARD_(?:USERNAME|PASSWORD)/);
  // Every plugin kong.yml really uses (per route) is loaded, and nothing else is.
  const liveKong = withoutYamlComments(kong);
  const used = [...new Set([...liveKong.matchAll(/^\s*- name: ([a-z-]+)\n\s+config:/gm)].map(match => match[1]))].sort();
  assert.deepEqual(used, [...plugins].sort());
  assert.doesNotMatch(liveKong, /\bacls?:|name: acl\b/);
  assert.doesNotMatch(liveKong, /graphql/);
  assert.doesNotMatch(kong, /realtime/i, 'the Realtime route is removed');
});

test('the rendered Kong environment has one worker and the five-plugin list', { skip: !composeAvailable() && !process.env.CI ? 'docker compose is not installed' : false }, () => {
  const environment = renderedCompose().services.kong.environment;
  assert.equal(environment.KONG_NGINX_WORKER_PROCESSES, '1');
  assert.deepEqual(environment.KONG_PLUGINS.split(',').sort(), FIVE_PLUGINS);
});
