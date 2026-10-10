import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { composeAvailable, renderedCompose } from './compose-render.mjs';

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
  for (const service of ['kong', 'functions', 'gotenberg', 'imgproxy', 'cups', 'prometheus', 'alertmanager', 'node-exporter', 'cadvisor']) {
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

test('the pooler registers only a database role that exists', () => {
  const pooler = read('docker/volumes/pooler/pooler.exs');
  assert.deepEqual([...pooler.matchAll(/"db_user" => "([a-z_]+)"/g)].map(match => match[1]), ['pgbouncer']);
  assert.match(read('docker/volumes/db/roles.sql'), /ALTER USER pgbouncer WITH PASSWORD/);
});
