import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { composeAvailable, renderCompose, renderedCompose, renderedComposeEnv } from './compose-render.mjs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
// CI always has Docker Compose; a contributor machine without it skips, visibly.
const skip = !composeAvailable() && !process.env.CI ? 'docker compose is not installed' : false;

function topology() {
  const { services, networks } = renderedCompose();
  const members = {};      // network -> services
  const names = {};        // DNS name -> { service, network }[]
  for (const [service, definition] of Object.entries(services)) {
    for (const [network, options] of Object.entries(definition.networks ?? {})) {
      (members[network] ??= []).push(service);
      for (const name of [service, ...(options?.aliases ?? [])]) (names[name] ??= []).push({ service, network });
    }
  }
  const reaches = (from, name) => (names[name] ?? []).some(target => members[target.network].includes(from));
  const peers = service => [...new Set(Object.keys(services[service].networks).flatMap(network => members[network]))].filter(other => other !== service).sort();
  return { services, networks, members, names, reaches, peers };
}

// Host names a service is configured to connect to: URLs and DSNs in its
// environment, and variables whose whole value is a service name.
function configuredHosts(definition, names) {
  const hosts = new Set();
  for (const value of Object.values(definition.environment ?? {})) {
    const text = String(value ?? '');
    if (names[text]) hosts.add(text);
    for (const match of text.matchAll(/(?:\/\/|@)([a-z][a-z0-9-]*):\d+/g)) if (names[match[1]]) hosts.add(match[1]);
  }
  return hosts;
}

test('the database is reachable only from the services that use it', { skip }, () => {
  const { networks, members, peers } = topology();
  assert.deepEqual(Object.keys(networks).sort(), ['database', 'default', 'renderer']);
  // The renderer network has no route out: only the function runtime and the renderer are on it.
  assert.equal(networks.renderer.internal, true);
  assert.deepEqual(members.renderer.slice().sort(), ['functions', 'pdf-renderer']);
  assert.deepEqual(peers('pdf-renderer'), ['functions']);
  assert.deepEqual(peers('db'), ['rest', 'storage', 'supavisor']);
  // The gateway, the function runtime and the helpers that parse outside input
  // share no network with the database.
  for (const service of ['kong', 'functions', 'pdf-renderer', 'cups', 'sensor-bridge']) {
    const reachable = peers(service);
    for (const guarded of ['db']) assert.ok(!reachable.includes(guarded), `${service} can reach ${guarded}`);
  }
});

test('every service still shares a network with each host it is configured to call', { skip }, () => {
  const { services, names, reaches } = topology();
  const wanted = Object.fromEntries(Object.entries(services).map(([service, definition]) => [service, configuredHosts(definition, names)]));
  // Hosts that are named in mounted configuration or in code rather than in the environment.
  for (const match of read('docker/kong.yml').matchAll(/^\s+url: http:\/\/([a-z0-9-]+):\d+/gm)) wanted.kong.add(match[1]);
  assert.match(read('docker/volumes/pooler/pooler.exs'), /"db_host" => "db"/);
  wanted.supavisor.add('db');
  wanted.functions.add('cups'); // functions/_shared/ipp-client.ts default printer address

  assert.deepEqual([...wanted.kong].sort(), ['functions', 'rest', 'storage']);
  // Storage does not use PostgREST (no POSTGREST_URL, no depends_on rest); the function runtime calls PostgREST and Storage
  // directly (SUPABASE_REST_URL, SUPABASE_STORAGE_URL, functions/_shared/supabase-rest.ts) and keeps SUPABASE_URL for the gateway.
  assert.deepEqual([...wanted.storage].sort(), ['db']);
  assert.equal(services.storage.environment.POSTGREST_URL, undefined);
  assert.deepEqual(Object.keys(services.storage.depends_on ?? {}), ['db']);
  assert.deepEqual([...wanted.functions].sort(), ['cups', 'kong', 'pdf-renderer', 'rest', 'storage']);
  assert.equal(services.functions.environment.SUPABASE_REST_URL, 'http://rest:3000');
  assert.equal(services.functions.environment.SUPABASE_STORAGE_URL, 'http://storage:5000');
  // The sensor bridge posts to the ingest function through the gateway and calls nothing else here.
  assert.deepEqual([...wanted['sensor-bridge']].sort(), ['kong']);
  for (const service of ['rest', 'supavisor']) assert.ok(wanted[service].has('db'), `${service} names the database`);
  for (const [service, hosts] of Object.entries(wanted)) {
    for (const host of hosts) assert.ok(reaches(service, host), `${service} cannot resolve ${host}`);
  }
  // depends_on only orders start-up, but a healthcheck that calls the service's
  // own name must find it on every network the service is attached to.
  for (const [service, definition] of Object.entries(services)) {
    const probe = JSON.stringify(definition.healthcheck?.test ?? '');
    for (const match of probe.matchAll(/http:\/\/([a-z][a-z0-9-]*):\d+/g)) {
      if (!['localhost'].includes(match[1])) assert.equal(match[1], service, `${service} healthcheck calls ${match[1]}`);
    }
  }
  // Studio and postgres-meta were removed (they ran SQL without a login), and with them the `admin` network.
  assert.equal('studio' in services, false);
  assert.equal('meta' in services, false);
  assert.equal('admin' in renderedCompose().networks, false);
  // The network table in docs/ARCHITECTURE.md names exactly the rendered networks and their members.
  const rows = [...read('docs/ARCHITECTURE.md').matchAll(/^\| `([a-z]+)` \| ([^|]+)\|/gm)];
  assert.deepEqual(rows.map(match => match[1]).sort(), Object.keys(renderedCompose().networks).sort());
  for (const [, network, list] of rows) {
    const documentedMembers = list.split(',').map(name => name.replace(/\s*\([^)]*\)/g, '').trim()).filter(Boolean).sort();
    assert.deepEqual(documentedMembers, topology().members[network].slice().sort(), `ARCHITECTURE.md members of ${network}`);
  }
  // The renderer answers inside its own healthcheck, on localhost, and has no other network.
  assert.match(JSON.stringify(services['pdf-renderer'].healthcheck.test), /http:\/\/localhost:3000\/health/);
  assert.deepEqual(Object.keys(services['pdf-renderer'].networks), ['renderer']);
  // The gateway DNS regression moves the functions container on `default`; `renderer` is the internal PDF network.
  assert.deepEqual(Object.keys(services.functions.networks).sort(), ['default', 'renderer']);
  // The function runtime never waits for the renderer: a renderer restart must not block or restart it.
  assert.deepEqual(Object.keys(services.functions.depends_on), ['db']);
  assert.equal(services.functions.environment.PDF_RENDERER_URL, 'http://pdf-renderer:3000');
  assert.equal('GOTENBERG_URL' in services.functions.environment, false);
  assert.deepEqual(Object.keys(services['sensor-bridge'].networks), ['default']);
});

test('the Compose files define no studio, meta or admin', () => {
  assert.doesNotMatch(read('docker/docker-compose.yml'), /^  (?:studio|meta|admin):/m, 'docker-compose.yml defines studio, meta or admin');
  assert.equal(existsSync(new URL('../docker/docker-compose.override.yml', import.meta.url)), false, 'the override file is merged into docker-compose.yml');
});

test('operator probes run in a container that shares a network with their target', { skip }, () => {
  const { reaches } = topology();
  for (const path of ['tests/gateway-dns-check.sh', 'tests/pooler-check.sh']) {
    const source = read(path);
    // Split the script at each probe container; every host named up to the next one belongs to it.
    const parts = source.split(/(?:probe_from |exec -T )([a-z][a-z-]*)\b/);
    let checked = 0;
    for (let index = 1; index < parts.length; index += 2) {
      const from = parts[index];
      const body = path === 'tests/gateway-dns-check.sh' ? source : parts[index + 1];
      for (const match of body.matchAll(/http:\/\/([a-z][a-z0-9-]*):\d+|-h ([a-z][a-z0-9-]*) /g)) {
        const host = match[1] ?? match[2];
        assert.ok(reaches(from, host) || host === from, `${path}: ${from} cannot reach ${host}`);
        checked += 1;
      }
    }
    assert.ok(checked > 0, `${path}: no probe was read`);
  }
  // The renderer is probed from the function runtime (the path PDFs take), which must be on its network.
  assert.ok(reaches('functions', 'pdf-renderer'), 'functions cannot resolve pdf-renderer');
  assert.match(read('scripts/watch.mjs'), /const PDF_PROBE = '[^']*\/dev\/tcp\/pdf-renderer\/3000/);
  assert.match(read('scripts/watch.mjs'), /ctx\.compose\(\['exec', '-T', 'functions', 'bash', '-c', PDF_PROBE\]\)/);
  // The health check (scripts/watch.mjs, run by health-check.sh) probes the gateway from the storage container, which shares the
  // default network with Kong, and reads the public key under the name that container has for it.
  assert.ok(reaches('storage', 'kong'), 'storage cannot resolve kong');
  assert.match(read('scripts/watch.mjs'), /ctx\.compose\(\['exec', '-T', 'storage', 'node', '--input-type=module'\]/);
  assert.match(read('scripts/watch.mjs'), /'http:\/\/kong:8000\/rest\/v1\/rpc\/get_public_config'/);
  assert.doesNotMatch(read('scripts/watch.mjs'), /SUPABASE_ANON_KEY/);
  assert.equal(renderedCompose().services.storage.environment.ANON_KEY.length > 20, true);
});

test('storage names its database superuser and does not install roles (its migrator reads both)', { skip }, () => {
  const { environment } = renderedCompose().services.storage;
  assert.equal(environment.DB_SUPER_USER, 'supabase_storage_admin');
  assert.equal(environment.DB_INSTALL_ROLES, 'false');
});

test('every service has bounded logs', { skip }, () => {
  const { services } = renderedCompose();
  for (const [service, definition] of Object.entries(services)) {
    assert.deepEqual(definition.logging, { driver: 'json-file', options: { 'max-file': '3', 'max-size': '10m' } }, `${service} logs are unbounded`);
  }
});

test('the sensor bridge needs no variable to render, so installations that never set one keep working', () => {
  // `${X:?}` here would make every `compose --profile '*'` command (build-images,
  // stop.sh, rotate-keys) fail on an installation without the SENSOR lines.
  const compose = read('docker/docker-compose.yml');
  const rest = compose.slice(compose.indexOf('\n  sensor-bridge:\n') + 1);
  const block = rest.slice(0, rest.search(/\n  \S/));
  const variables = [...block.matchAll(/\$\{([A-Z_]+)([^}]*)\}/g)];
  assert.ok(variables.length >= 5, 'the bridge variables were read');
  for (const [, name, modifier] of variables) assert.match(modifier, /^:-/, `${name} must have a default`);
  assert.match(block, /\n      SENSOR_INGEST_URL: http:\/\/kong:8000\/functions\/v1\/ingest-sensor-readings\n/);
  assert.match(block, /\n    profiles: \["sensors"\]\n/);
  assert.doesNotMatch(block, /\n    (?:networks|ports|privileged):/);
});

test('the pooler registers only a database role that exists', () => {
  const pooler = read('docker/volumes/pooler/pooler.exs');
  assert.deepEqual([...pooler.matchAll(/"db_user" => "([a-z_]+)"/g)].map(match => match[1]), ['pgbouncer']);
  assert.match(read('docker/volumes/db/roles.sql'), /ALTER USER pgbouncer WITH PASSWORD :'pooler_password'/);
});

// TW-BE-002 (docs/CONTAINER_SECURITY.md, "Database passwords"): every value is
// searched for in the whole rendered definition of each service, environment,
// commands and health checks alike.
test('the superuser password reaches only db and supavisor; each login password only its service', { skip }, () => {
  const { services } = renderedCompose();
  const env = renderedComposeEnv();
  const holders = value => {
    assert.ok(value && value.length >= 16, 'the value was generated');
    return Object.entries(services).filter(([, definition]) => JSON.stringify(definition).includes(value)).map(([service]) => service).sort();
  };
  assert.deepEqual(holders(env.POSTGRES_PASSWORD), ['db', 'supavisor']);
  // db carries the three that exist before the migrations, for its first-start init script.
  assert.deepEqual(holders(env.DB_PASSWORD_AUTHENTICATOR), ['db', 'rest']);
  assert.deepEqual(holders(env.DB_PASSWORD_STORAGE), ['db', 'storage']);
  assert.deepEqual(holders(env.DB_PASSWORD_POOLER), ['db', 'supavisor']);
  assert.equal('DB_PASSWORD_MONITORING' in env, false, 'the monitoring login has no password (migration 107)');
  assert.equal('POSTGRES_PASSWORD' in services.supavisor.environment, false);
});

test('a state without a per-role value fails at compose config with a message, not at the first login', { skip }, () => {
  for (const name of ['DB_PASSWORD_AUTHENTICATOR', 'DB_PASSWORD_STORAGE', 'DB_PASSWORD_POOLER']) {
    const result = renderCompose(text => text.replace(new RegExp(`^${name}=.*\n`, 'm'), ''));
    assert.notEqual(result.status, 0, `${name} missing still renders`);
    assert.match(result.stderr, /Run setup\.sh to generate the per-role database passwords/);
  }
});

test('kong resolves Compose names at the DNS root, so a host search domain cannot delay a lookup', { skip }, () => {
  // TW-BE-015: a lookup through the host's search domain took about 8 s.
  const { services } = topology();
  assert.deepEqual(services.kong.dns_search, ['.']);
  assert.equal('realtime' in services, false, 'the Realtime service is removed');
});

test('the renderer runs read-only with no capabilities, no ports and bounded memory', { skip }, () => {
  const { services } = renderedCompose();
  const renderer = services['pdf-renderer'];
  assert.equal(renderer.read_only, true);
  assert.deepEqual(renderer.cap_drop, ['ALL']);
  assert.deepEqual(renderer.security_opt, ['no-new-privileges:true']);
  assert.equal(renderer.ports, undefined);
  assert.equal(renderer.pids_limit, 512);
  assert.equal(renderer.mem_limit, renderer.memswap_limit, 'no swap beyond the memory limit');
  assert.equal(String(renderer.mem_limit), String(1536 * 1024 ** 2));
  assert.equal(renderer.stop_grace_period, '30s');
  assert.equal(renderer.restart, 'unless-stopped');
  assert.ok(renderer.build, 'the image is built locally, as every other service');
  assert.equal(renderer.tmpfs.some(entry => /^\/tmp(?::|$)/.test(entry) && /size=256m/.test(entry)), true);
  assert.equal(services.gotenberg, undefined, 'the old PDF service is gone');
});

test('WAREHOUSE_COMPOSE_EXTRA merges one more Compose file (CI pins the default network subnet this way) and refuses a bad path', { skip }, () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-compose-extra-'));
  const previous = process.env.WAREHOUSE_COMPOSE_EXTRA;
  try {
    const extra = join(scratch, 'subnet.yml');
    writeFileSync(extra, 'networks:\n  default:\n    ipam:\n      config:\n        - subnet: 10.233.245.0/24\n');
    process.env.WAREHOUSE_COMPOSE_EXTRA = extra;
    const merged = renderCompose();
    assert.equal(merged.status, 0, merged.stderr);
    assert.equal(JSON.parse(merged.stdout).networks.default.ipam.config[0].subnet, '10.233.245.0/24');
    process.env.WAREHOUSE_COMPOSE_EXTRA = 'relative.yml';
    const refused = renderCompose();
    assert.notEqual(refused.status, 0);
    assert.match(refused.stderr, /WAREHOUSE_COMPOSE_EXTRA must be the absolute path/);
  } finally {
    if (previous === undefined) delete process.env.WAREHOUSE_COMPOSE_EXTRA; else process.env.WAREHOUSE_COMPOSE_EXTRA = previous;
    rmSync(scratch, { recursive: true, force: true });
  }
});
