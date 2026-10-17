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
  assert.ok(kong.match(/name: request-size-limiting/g).length >= 4);
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
  assert.equal((kong.match(/name: rate-limiting/g) || []).length, 5);
  assert.equal((kong.match(/^\s+limit_by: ip$/gm) || []).length, 5);
  // Every route that needs only the public key or no key at all is limited per
  // client address, except storage (see docs/CONTAINER_SECURITY.md).
  // The REST and socket routes have a per-minute limit only (null): see the next two tests.
  const limits = { 'rest-v1': [1800, null], 'graphql-v1': [300, 6000], 'realtime-v1-ws': [1800, null], 'realtime-v1-rest': [300, 6000], 'functions-v1': [100, 6000] };
  for (const [service, [minute, hour]] of Object.entries(limits)) {
    const rateLimit = serviceBlock(service).split('- name: rate-limiting')[1]?.split('      - name: ')[0];
    assert.ok(rateLimit, `${service} has no rate limit`);
    const hourLine = hour === null ? '' : `hour: ${hour}\\n\\s+`;
    assert.match(rateLimit, new RegExp(`minute: ${minute}\\n\\s+${hourLine}policy: local\\n\\s+fault_tolerant: true\\n[\\s\\S]*limit_by: ip\\n`), `${service} rate limit`);
  }
  assert.doesNotMatch(serviceBlock('storage-v1'), /rate-limiting/);
  for (const [service, megabytes] of Object.entries({ 'rest-v1': 10, 'graphql-v1': 2, 'realtime-v1-rest': 2, 'storage-v1': 50, 'functions-v1': 10 })) {
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
    'docs/CONTAINER_SECURITY.md, Realtime socket limit': section('- **The limit now.** 1800 attempts a minute', '- **What this does not cover.**'),
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

test('the Realtime socket limit cannot lock a facility out after a Realtime outage', () => {
  // Every phone on the facility network reaches the gateway from one public address, and Kong
  // counts each failed upgrade. The app opens one socket per live order screen (at most two at
  // once per phone) and realtime-js retries after 1, 2, 5 and 10 s, then every 10 s
  // (docs/CONTAINER_SECURITY.md, Realtime socket limit).
  const devices = 100, socketsPerDevice = 2;
  const retryDelays = [1, 2, 5, 10], steadyDelay = 10;
  let at = 0, firstMinute = 0;
  for (let attempt = 0; ; attempt += 1) { at += retryDelays[attempt] ?? steadyDelay; if (at > 60) break; firstMinute += 1; }
  assert.equal(firstMinute, 8);
  const rateLimit = serviceBlock('realtime-v1-ws').split('- name: rate-limiting')[1].split('      - name: ')[0];
  const minute = Number(rateLimit.match(/^\s+minute: (\d+)$/m)[1]);
  assert.ok(minute >= devices * socketsPerDevice * firstMinute, `a whole facility retrying (${devices * socketsPerDevice * firstMinute} a minute) stays under the limit of ${minute}`);
  // A window longer than a minute is what turned an outage into a lockout: the retries of the
  // outage would use it up, and reconnects would be refused until it rolled over.
  assert.doesNotMatch(rateLimit, /^\s+(hour|day|month|year):/m);
});

test('gateway exports the request metrics the alert rules query', () => {
  // Kong 3 exports per-request series only when the plugin is enabled and these switches are on.
  const global = kong.slice(kong.indexOf('\nplugins:\n'), kong.indexOf('\nservices:\n'));
  assert.match(global, /\n  - name: prometheus\n    config:\n      status_code_metrics: true\n      latency_metrics: true\n      per_consumer: false\n/);
  for (const file of ['docker-compose.yml', 'docker-compose.override.yml']) {
    assert.match(readFileSync(new URL(`../docker/${file}`, import.meta.url), 'utf8'), /KONG_PLUGINS: \S*\bprometheus\b/, `${file} does not load the plugin`);
  }
  const rules = readFileSync(new URL('../docker/alert-rules.yml', import.meta.url), 'utf8');
  const expressions = [...rules.matchAll(/^\s+expr: (.+)$/gm)].map(match => match[1]);
  assert.doesNotMatch(expressions.join('\n'), /kong_http_status|kong_latency_bucket/, 'Kong 2 metric names are not exported by Kong 3');
  const expression = alert => new RegExp(`- alert: ${alert}\\n(?:\\s+#.*\\n)*\\s+expr: (.+)\\n`).exec(rules)?.[1];
  assert.equal(expression('APIHighErrorRate'), 'sum(rate(kong_http_requests_total{code=~"5.."}[5m])) / sum(rate(kong_http_requests_total[5m])) > 0.05');
  assert.equal(expression('APIHighLatency'), 'histogram_quantile(0.95, sum(rate(kong_request_latency_ms_bucket[5m])) by (le, service)) > 2000');
  assert.equal(expression('ScrapeTargetDown'), 'up{job!="kong"} == 0');
  assert.equal(expression('APIDown'), 'up{job="kong"} == 0');
  // postgres-exporter splits pg_stat_activity_count by database, state, user, application and
  // backend type: no single series reaches 80 when the connections are spread, so the rule adds
  // the client connections of each exporter (background workers do not count toward max_connections
  // in the same way and are left out).
  assert.equal(expression('DatabaseConnectionsHigh'), 'sum by (instance, job) (pg_stat_activity_count{backend_type="client backend"}) > 80');
  // Every job Prometheus scrapes is covered by one of the two.
  const jobs = [...readFileSync(new URL('../docker/prometheus.yml', import.meta.url), 'utf8').matchAll(/job_name: '([a-z-]+)'/g)].map(match => match[1]);
  assert.deepEqual(jobs.sort(), ['cadvisor', 'kong', 'node', 'postgres', 'prometheus']);
  const monitoringCheck = readFileSync(new URL('../scripts/monitoring-check.sh', import.meta.url), 'utf8');
  assert.match(monitoringCheck, /kong_http_requests_total/, 'monitoring check does not require gateway request metrics');
  // The rule unit tests (docker/alert-rules.test.yml) run with the image's own promtool, and the
  // live exporter must still label its series with backend_type, or the rule matches nothing.
  assert.match(monitoringCheck, /--entrypoint promtool prometheus \\\n\s+test rules \/etc\/prometheus\/alert-rules\.test\.yml/, 'monitoring check does not run the alert rule tests');
  assert.match(monitoringCheck, /"\$ROOT\/docker\/alert-rules\.test\.yml:\/etc\/prometheus\/alert-rules\.test\.yml:ro"/);
  assert.ok(monitoringCheck.includes("query=sum(pg_stat_activity_count%7Bbackend_type%3D%22client%20backend%22%7D)"), 'monitoring check does not require client-backend connection series');
  const unit = readFileSync(new URL('../docker/alert-rules.test.yml', import.meta.url), 'utf8');
  assert.match(unit, /^rule_files:\n  - \/etc\/prometheus\/alert-rules\.yml\n/m);
  assert.match(unit, /alertname: DatabaseConnectionsHigh/);
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
  assert.match(compose, /\n\s+PGRST_APP_SETTINGS_JWT_EXP: \$\{JWT_EXPIRY\}\n/, 'the expiry setting is not part of this change');
  const jwtSql = withoutComments('docker/volumes/db/jwt.sql');
  assert.doesNotMatch(jwtSql, /jwt_secret|JWT_SECRET/i, 'jwt.sql must not set or read the secret');
  assert.match(jwtSql, /ALTER DATABASE postgres SET "app\.settings\.jwt_exp"/, 'jwt.sql still sets the expiry');
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
  assert.ok(services.rest.environment.PGRST_APP_SETTINGS_JWT_EXP, 'the expiry app setting must stay');
});

test('ingress is Cloudflare Tunnel only', () => {
  assert.ok(!existsSync(deploy('Caddyfile.example')), 'Caddy example must not ship');
  assert.ok(existsSync(deploy('cloudflared-config.example.yml')));
  assert.ok(existsSync(deploy('warehouse-tunnel.service.example')));
  const tunnel = readFileSync(deploy('cloudflared-config.example.yml'), 'utf8');
  assert.ok(tunnel.includes('service: http://127.0.0.1:18000'));
  assert.ok(tunnel.includes('noTLSVerify: false'));
  assert.ok(tunnel.includes('service: http_status:404'));
  const unit = readFileSync(deploy('warehouse-tunnel.service.example'), 'utf8');
  assert.match(unit, /^ExecStart=\/usr\/bin\/cloudflared --no-autoupdate --config \S+ tunnel run$/m);
  assert.doesNotMatch(unit, /--token(?:\s|=)/, 'tunnel tokens must never appear on the unit command line');
});

test('publisher images are pinned by digest and the notices name the versions in use', () => {
  const override = readFileSync(new URL('../docker/docker-compose.override.yml', import.meta.url), 'utf8');
  const images = [...`${compose}\n${override}`.matchAll(/^\s+image: (\S+)$/gm)].map(match => match[1]).filter(image => !image.endsWith(':local'));
  assert.ok(images.some(image => /^kong:3\.9\.3-ubuntu@sha256:[0-9a-f]{64}$/.test(image)), 'Kong is not pinned by digest');
  // PostgREST v16.4 still has no digest: the image was not available to read one
  // from when Kong was pinned (docs/CONTAINER_SECURITY.md, "Image pins").
  assert.deepEqual(images.filter(image => !/@sha256:[0-9a-f]{64}$/.test(image)), ['postgrest/postgrest:v16.4']);

  const notices = readFileSync(new URL('../THIRD_PARTY_NOTICES.md', import.meta.url), 'utf8');
  const review = readFileSync(new URL('../docs/ATTRIBUTION_REVIEW.md', import.meta.url), 'utf8');
  const base = (recipe, image) => new RegExp(`^FROM ${image}:([^@\\s]+)@sha256:`, 'm').exec(readFileSync(new URL(`../docker/${recipe}/Dockerfile`, import.meta.url), 'utf8'))?.[1];
  const versions = {
    Kong: /image: kong:([0-9.]+)-ubuntu/.exec(compose)[1],
    PostgREST: /image: postgrest\/postgrest:(v[0-9.]+)/.exec(compose)[1],
    Realtime: base('realtime', 'supabase/realtime'),
    Supavisor: base('supavisor', 'supabase/supavisor'),
    'edge-runtime': base('edge-runtime', 'supabase/edge-runtime'),
    Studio: base('studio', 'supabase/studio'),
    Gotenberg: base('gotenberg', 'gotenberg/gotenberg'),
    Grafana: base('grafana', 'grafana/grafana'),
    // The sensor bridge (GPL-3.0-or-later): its base image and the GPL library it installs.
    Python: base('sensor-bridge', 'python'),
    'python-kasa': /^python-kasa==([0-9][0-9.]*)\b/m.exec(readFileSync(new URL('../docker/sensor-bridge/requirements.txt', import.meta.url), 'utf8'))?.[1],
  };
  for (const [name, version] of Object.entries(versions)) {
    assert.ok(version, `${name} version was not read`);
    const row = notices.split('\n').find(line => line.startsWith('|') && line.includes(name) && line.includes(version));
    assert.ok(row, `THIRD_PARTY_NOTICES.md does not name ${name} ${version}`);
    const short = name === 'Studio' ? version.split('-sha-')[0] : version;
    assert.ok(new RegExp(`${name} ${short.replaceAll('.', '\\.')}[,) ]`).test(review), `docs/ATTRIBUTION_REVIEW.md does not name ${name} ${short}`);
  }
  assert.doesNotMatch(`${notices}\n${review}`, /v1\.76\.2|postgrest:v14\.17|PostgREST v14\.17/);
});
