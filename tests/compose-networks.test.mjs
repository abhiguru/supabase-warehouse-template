import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
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

test('postgres-meta, Studio and the database are reachable only from the services that use them', { skip }, () => {
  const { networks, peers } = topology();
  assert.deepEqual(Object.keys(networks).sort(), ['admin', 'database', 'default']);
  assert.deepEqual(peers('meta'), ['db', 'studio']);
  assert.deepEqual(peers('studio'), ['db', 'meta']);
  assert.deepEqual(peers('db'), ['auth', 'grafana', 'meta', 'postgres-exporter', 'realtime', 'rest', 'storage', 'studio', 'supavisor']);
  // The gateway, the function runtime and the helpers that parse outside input
  // share no network with the database, postgres-meta or Studio.
  for (const service of ['kong', 'functions', 'gotenberg', 'imgproxy', 'cups', 'sensor-bridge', 'prometheus', 'alertmanager', 'node-exporter', 'cadvisor']) {
    const reachable = peers(service);
    for (const guarded of ['db', 'meta', 'studio']) assert.ok(!reachable.includes(guarded), `${service} can reach ${guarded}`);
  }
});

test('every service still shares a network with each host it is configured to call', { skip }, () => {
  const { services, names, reaches } = topology();
  const wanted = Object.fromEntries(Object.entries(services).map(([service, definition]) => [service, configuredHosts(definition, names)]));
  // Hosts that are named in mounted configuration or in code rather than in the environment.
  for (const match of read('docker/kong.yml').matchAll(/^\s+url: http:\/\/([a-z0-9-]+):\d+/gm)) wanted.kong.add(match[1]);
  for (const match of read('docker/prometheus.yml').matchAll(/'([a-z][a-z0-9-]*):\d+'/g)) if (match[1] !== 'localhost') wanted.prometheus.add(match[1]);
  for (const match of read('docker/volumes/grafana/provisioning/datasources/datasources.yml').matchAll(/url: (?:http:\/\/)?([a-z][a-z0-9-]*):\d+/g)) wanted.grafana.add(match[1]);
  assert.match(read('docker/volumes/pooler/pooler.exs'), /"db_host" => "db"/);
  wanted.supavisor.add('db');
  wanted.functions.add('cups'); // functions/_shared/ipp-client.ts default printer address
  // Studio is given the gateway address but is deliberately not attached to the
  // gateway's network: a container that can reach Studio can run SQL through it.
  assert.ok(wanted.studio.delete('kong'), 'Studio no longer names the gateway; drop this exception');
  assert.ok(!reaches('studio', 'kong'));

  assert.deepEqual([...wanted.kong].sort(), ['functions', 'realtime-dev', 'rest', 'storage']);
  assert.deepEqual([...wanted.storage].sort(), ['db', 'imgproxy', 'rest']);
  assert.deepEqual([...wanted.functions].sort(), ['cups', 'gotenberg', 'kong']);
  assert.deepEqual([...wanted.studio].sort(), ['meta']);
  assert.deepEqual([...wanted.prometheus].sort(), ['alertmanager', 'cadvisor', 'kong', 'node-exporter', 'postgres-exporter']);
  assert.deepEqual([...wanted.grafana].sort(), ['db', 'prometheus']);
  // The sensor bridge posts to the ingest function through the gateway and calls nothing else here.
  assert.deepEqual([...wanted['sensor-bridge']].sort(), ['kong']);
  for (const service of ['rest', 'realtime', 'meta', 'auth', 'supavisor', 'postgres-exporter']) assert.ok(wanted[service].has('db'), `${service} names the database`);
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
  // Studio answers only on the address of its container name, so it must stay on one network.
  assert.deepEqual(Object.keys(services.studio.networks), ['admin']);
  // The gateway DNS regression moves the functions container on the default network only.
  assert.deepEqual(Object.keys(services.functions.networks), ['default']);
  assert.deepEqual(Object.keys(services['sensor-bridge'].networks), ['default']);
});

test('operator probes run in a container that shares a network with their target', { skip }, () => {
  const { reaches } = topology();
  for (const path of ['health-check.sh', 'scripts/gateway-dns-check.sh', 'scripts/studio-check.sh', 'scripts/pooler-check.sh']) {
    const source = read(path);
    // Split the script at each probe container; every host named up to the next one belongs to it.
    const parts = source.split(/(?:probe_from |exec -T )([a-z][a-z-]*)\b/);
    let checked = 0;
    for (let index = 1; index < parts.length; index += 2) {
      const from = parts[index];
      const body = path === 'scripts/gateway-dns-check.sh' ? source : parts[index + 1];
      for (const match of body.matchAll(/http:\/\/([a-z][a-z0-9-]*):\d+|-h ([a-z][a-z0-9-]*) /g)) {
        const host = match[1] ?? match[2];
        assert.ok(reaches(from, host) || host === from, `${path}: ${from} cannot reach ${host}`);
        checked += 1;
      }
    }
    assert.ok(checked > 0, `${path}: no probe was read`);
  }
  // The gateway probes read the public key under the name the storage container has for it.
  assert.doesNotMatch(read('health-check.sh'), /SUPABASE_ANON_KEY/);
  assert.equal(renderedCompose().services.storage.environment.ANON_KEY.length > 20, true);
});

test('every service has bounded logs, and imgproxy cannot write to stored files', { skip }, () => {
  const { services } = renderedCompose();
  for (const [service, definition] of Object.entries(services)) {
    assert.deepEqual(definition.logging, { driver: 'json-file', options: { 'max-file': '3', 'max-size': '10m' } }, `${service} logs are unbounded`);
  }
  const mount = service => services[service].volumes.find(volume => volume.target === '/var/lib/storage');
  assert.equal(mount('imgproxy').read_only, true);
  assert.notEqual(mount('storage').read_only, true);
  assert.equal(mount('imgproxy').source, mount('storage').source);
});

test('imgproxy runs as the owner of the private storage directory', () => {
  // The directory is mode 0700 and owned by the installing user. As the image's
  // own user (999) imgproxy could not enter it, and every transformation failed.
  assert.match(read('docker/docker-compose.yml'), /\n  imgproxy:\n(?:    .*\n|\n)*?    user: "\$\{WAREHOUSE_HOST_UID:-999\}:\$\{WAREHOUSE_HOST_GID:-999\}"\n/);
  assert.match(read('scripts/compose.sh'), /^exec env "\$\{unset_args\[@\]\}" WAREHOUSE_HOST_UID="\$\(id -u\)" WAREHOUSE_HOST_GID="\$\(id -g\)" WAREHOUSE_PUBLIC_PATH="\$STATE\/public" docker compose /m);
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
test('the superuser password reaches only db, meta, realtime, supavisor and studio; each login password only its service', { skip }, () => {
  const { services } = renderedCompose();
  const env = renderedComposeEnv();
  const holders = value => {
    assert.ok(value && value.length >= 16, 'the value was generated');
    return Object.entries(services).filter(([, definition]) => JSON.stringify(definition).includes(value)).map(([service]) => service).sort();
  };
  assert.deepEqual(holders(env.POSTGRES_PASSWORD), ['db', 'meta', 'realtime', 'studio', 'supavisor']);
  // db carries the four that exist before the migrations, for its first-start init script.
  assert.deepEqual(holders(env.DB_PASSWORD_AUTHENTICATOR), ['db', 'rest']);
  assert.deepEqual(holders(env.DB_PASSWORD_STORAGE), ['db', 'storage']);
  assert.deepEqual(holders(env.DB_PASSWORD_AUTH), ['auth', 'db']);
  assert.deepEqual(holders(env.DB_PASSWORD_POOLER), ['db', 'supavisor']);
  assert.deepEqual(holders(env.DB_PASSWORD_MONITORING), ['grafana', 'postgres-exporter']);
  assert.deepEqual(holders(env.REALTIME_DB_ENC_KEY), ['realtime']);
  assert.equal(services.realtime.environment.DB_ENC_KEY, env.REALTIME_DB_ENC_KEY);
  assert.match(services['postgres-exporter'].environment.DATA_SOURCE_NAME, /^postgresql:\/\/warehouse_monitoring:/);
  assert.equal('POSTGRES_PASSWORD' in services.grafana.environment, false);
  assert.equal('POSTGRES_PASSWORD' in services.supavisor.environment, false);
});

test('a state without a per-role value fails at compose config with a message, not at the first login', { skip }, () => {
  for (const name of ['DB_PASSWORD_AUTHENTICATOR', 'DB_PASSWORD_MONITORING', 'REALTIME_DB_ENC_KEY']) {
    const result = renderCompose(text => text.replace(new RegExp(`^${name}=.*\n`, 'm'), ''));
    assert.notEqual(result.status, 0, `${name} missing still renders`);
    assert.match(result.stderr, /Run setup\.sh to generate the (?:per-role database passwords|Realtime encryption key)/);
  }
});
