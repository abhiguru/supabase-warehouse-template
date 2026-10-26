// scripts/watch.mjs, the installation's one monitoring check: every check at its boundary, the alert rules, the
// daily jobs and the state file, against fakes (no Docker, no network, no real clock, no Slack) and
// scripts/watch-timer.sh against shims (no systemd).
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, statSync, utimesSync, copyFileSync, chmodSync, cpSync, symlinkSync, readlinkSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { repo } from './backup-test-helpers.mjs';
import * as W from '../scripts/watch.mjs';

const HOUR = 3600 * 1000;
const WEBHOOK = 'https://hooks.slack.com/services/T0AAAA/B0BBBB/abcDEF123456';
const T0 = new Date(2026, 9, 19, 10, 0, 0).getTime();
// The default-profile services of the final compose; supavisor, cups and sensor-bridge are profile services.
const SERVICES = ['db', 'gateway', 'rest', 'storage', 'functions', 'pdf-renderer'];
const idOf = name => Buffer.from(name.padEnd(6, '_')).toString('hex').slice(0, 12).padEnd(12, '0');
const ok = (stdout = '') => ({ status: 0, stdout, stderr: '' });
const bad = (stderr = 'failed') => ({ status: 1, stdout: '', stderr });

// A scratch installation: state directory, fake /proc and cgroup trees, a clock and a recorder for posts.
function harness({ webhook = true, dailyAt = '02:30', heartbeatAt = '09:00' } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-watch-'));
  const state = join(scratch, 'acme');
  for (const dir of ['', 'config', 'public', 'backups']) mkdirSync(join(state, dir), { recursive: true, mode: 0o700 });
  writeFileSync(join(state, 'config/compose.env'), 'WAREHOUSE_PROJECT_NAME=warehouse-test\nGATEWAY_HTTP_PORT=18000\nPOSTGRES_PASSWORD=supersecretpassword123\n', { mode: 0o600 });
  writeFileSync(join(state, 'public/instance.json'), JSON.stringify({ schemaVersion: 1, instanceId: 'iid-1', companyName: 'Acme Cold', canonicalOrigin: 'https://acme.example.test' }));
  if (webhook) writeFileSync(join(state, 'config/slack-webhook-url'), `${WEBHOOK}\n`, { mode: 0o600 });
  const proc = join(scratch, 'proc'); mkdirSync(proc);
  const cgroup = join(scratch, 'cgroup'); mkdirSync(cgroup);
  const h = { scratch, state, proc, cgroup, clock: { t: T0 }, posts: [], calls: [], runs: {}, statfsTable: { '/': { bavail: 50, blocks: 100 } }, postFails: false, postStatuses: [], fetchTable: {},
    services: [...SERVICES], expected: [...SERVICES], fsApi: undefined };
  h.fakeRun = (command, args) => {
    const line = `${command} ${args.join(' ')}`;
    h.calls.push(line);
    for (const [pattern, reply] of Object.entries(h.runs)) if (line.includes(pattern)) return typeof reply === 'function' ? reply(line) : reply;
    if (line.includes('compose.sh config --services')) return ok(h.expected.join('\n') + '\n');
    if (line.includes("compose.sh --profile * ps -a -q")) return ok(h.services.map(idOf).join('\n') + '\n');
    if (command === 'docker' && args[0] === 'inspect') return ok(args.slice(3).map(id => { const name = h.services.find(s => idOf(s) === id); return `${id}|${name}|${h.stateOf?.[name] ?? `running|${['db', 'gateway'].includes(name) ? 'healthy' : ''}`}|0|false|2026-10-18T00:00:00Z|False`; }).join('\n'));
    if (command === 'docker' && args[0] === 'events') return ok('');
    if (line.includes('pg_isready')) return ok('accepting connections');
    if (line.includes('psql')) return ok('5|0|100000|100|50\n');
    if (line.includes('docker logs')) return ok('');
    if (line.includes('exec -T functions')) return ok();
    if (command === 'flock') return ok();
    return bad(`unexpected command: ${line}`);
  };
  h.deps = {
    state, root: repo, env: {}, now: () => h.clock.t, run: (c, a) => h.fakeRun(c, a),
    readText: path => { try { return readFileSync(path, 'utf8'); } catch { return null; } },
    statfs: path => { if (!h.statfsTable[path]) throw new Error(`no statfs for ${path}`); return { bsize: 4096, ...h.statfsTable[path] }; },
    fetch: async url => { const r = h.fetchTable[url]; if (!r) throw new Error('connect ECONNREFUSED'); return { ok: r.status < 400, status: r.status, json: async () => r.body }; },
    post: async (url, text) => {
      if (h.postFails) throw new Error('could not reach Slack');
      const status = h.postStatuses.length ? h.postStatuses.shift() : 200;
      h.attempts = (h.attempts ?? 0) + 1;
      if (status >= 200 && status < 300) h.posts.push({ url, text });
      return status;
    },
    proc, cgroup, usbEtc: join(scratch, 'etc'), dailyAt, heartbeatAt,
  };
  Object.defineProperty(h.deps, 'fsApi', { get: () => h.fsApi, enumerable: true });
  h.deps.runGroup = async (c, a) => h.fakeRun(c, a);
  h.ctx = () => W.makeContext(h.deps, W.loadState(state, h.clock.t, h.deps.readText));
  h.state_ = () => JSON.parse(readFileSync(join(state, 'config/watch-state.json'), 'utf8'));
  h.advance = ms => { h.clock.t += ms; };
  // A state file that is old enough for the daily jobs (a fresh state waits for the next window).
  h.seed = (patch = {}) => writeFileSync(join(state, 'config/watch-state.json'), JSON.stringify({ ...W.freshState(T0 - 30 * 24 * HOUR), ...patch }));
  h.holdLock = () => {
    const file = join(state, 'config/operator.lock');
    writeFileSync(file, '');
    writeFileSync(join(proc, 'locks'), `1: FLOCK  ADVISORY  WRITE 4242 08:01:${statSync(file).ino} 0 EOF\n`);
  };
  h.releaseLock = () => writeFileSync(join(proc, 'locks'), '');
  return h;
}
const clean = h => rmSync(h.scratch, { recursive: true, force: true });
const find = (results, id) => results.find(r => r.id === id);
const stub = (...rows) => [['stub', () => rows.map(r => ({ check: 'stub', ...r }))]];
const failing = (id = 'thing_bad', extra = {}) => ({ id, ok: false, summary: `${id} is bad`, detail: '', ...extra });
const NO_JOBS = { daily: null };
const HEALTHY = [['stub', () => [{ check: 'stub', id: 'postgres_down', ok: true, summary: 'PostgreSQL responds', detail: '' }]]];

// ---------------------------------------------------------------- host checks
test('CPU: average busy share since the previous run, failing above 80%', async () => {
  const h = harness();
  try {
    const stat = (user, idle) => writeFileSync(join(h.proc, 'stat'), `cpu  ${user} 0 0 ${idle} 0 0 0 0\ncpu0 1 1 1 1\n`);
    const ctx = h.ctx();
    stat(1000, 1000);
    assert.equal(W.checkCpu(ctx)[0].ok, true, 'first run has nothing to compare with');
    h.advance(5 * 60000); stat(1800, 1200);   // 800 busy, 200 idle: 80% exactly
    assert.equal(W.checkCpu(ctx)[0].ok, true);
    h.advance(5 * 60000); stat(2600, 1399);   // 800 busy, 199 idle: 80.08%
    const r = W.checkCpu(ctx)[0];
    assert.equal(r.ok, false); assert.match(r.summary, /CPU usage 80%/);
  } finally { clean(h); }
});

test('memory: failing above 85% used (MemAvailable)', () => {
  const h = harness();
  try {
    const mem = avail => writeFileSync(join(h.proc, 'meminfo'), `MemTotal:        1000 kB\nMemFree: 1 kB\nMemAvailable:   ${avail} kB\n`);
    mem(150); assert.equal(W.checkMemory(h.ctx())[0].ok, true);
    mem(149); assert.equal(W.checkMemory(h.ctx())[0].ok, false);
  } finally { clean(h); }
});

test('disk: / under 20% free fails; other ext4/xfs/btrfs mounts under 10%; bind mounts and other types are ignored', () => {
  const h = harness();
  try {
    writeFileSync(join(h.proc, 'mounts'), '/dev/sda1 / ext4 rw 0 0\n/dev/sda1 /etc/hosts ext4 rw 0 0\n/dev/sdb1 /mnt/data xfs rw 0 0\ntmpfs /run tmpfs rw 0 0\n/dev/sdc1 /var/lib/docker/overlay ext4 rw 0 0\n/dev/sdd1 /mnt/my\\040disk btrfs rw 0 0\n');
    h.statfsTable = { '/': { bavail: 20, blocks: 100 }, '/mnt/data': { bavail: 10, blocks: 100 }, '/mnt/my disk': { bavail: 9, blocks: 100 } };
    let r = W.checkDisks(h.ctx());
    assert.deepEqual(r.map(x => [x.id, x.ok]), [['disk_root_low', true], ['disk_low:/mnt/data', true], ['disk_low:/mnt/my disk', false]]);
    h.statfsTable['/'] = { bavail: 19, blocks: 100 };
    r = W.checkDisks(h.ctx());
    assert.equal(find(r, 'disk_root_low').ok, false);
    delete h.statfsTable['/mnt/data'];   // statfs throws for this mount: the others are still judged
    r = W.checkDisks(h.ctx());
    assert.deepEqual(r.map(x => x.id), ['disk_root_low', 'disk_low:/mnt/my disk']);
  } finally { clean(h); }
});

// ---------------------------------------------------------------- database
test('database: pg_isready, connections > 80, transaction > 300 s, cache < 90%, dead tuples > 100000', () => {
  const h = harness();
  try {
    const q = row => { h.runs.psql = ok(`${row}\n`); return W.checkDatabase(h.ctx()); };
    let r = q('80|300|9001|999|100000');
    assert.deepEqual(r.filter(x => !x.ok), []);
    assert.equal(find(q('81|0|100000|0|0'), 'db_connections_high').ok, false);
    assert.equal(find(q('0|301|100000|0|0'), 'db_long_transaction').ok, false);
    assert.equal(find(q('0|0|8900|1100|0'), 'db_cache_hit_low').ok, false);
    assert.equal(find(q('0|0|80|20|0'), 'db_cache_hit_low').ok, true, 'a tiny sample is not judged');
    assert.equal(find(q('0|0|100000|0|100001'), 'db_dead_tuples_high').ok, false);
    assert.ok(h.calls.some(c => c.includes("exec -T -e PGOPTIONS=-c statement_timeout=10000 db psql")), 'the query has a statement timeout');
    h.runs.pg_isready = bad();
    r = W.checkDatabase(h.ctx());
    assert.deepEqual(r.map(x => [x.id, x.ok]), [['postgres_down', false]]);
    h.runs.pg_isready = ok(); h.runs.psql = bad('boom');
    assert.throws(() => W.checkDatabase(h.ctx()), /database query failed/);
  } finally { clean(h); }
});

// ---------------------------------------------------------------- containers
function cgroupFor(h, service, { current, max, inactive = 0, oomKill = 0 }) {
  const dir = join(h.cgroup, 'system.slice', `docker-${idOf(service)}.scope`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'memory.current'), `${current}\n`);
  writeFileSync(join(dir, 'memory.max'), `${max}\n`);
  writeFileSync(join(dir, 'memory.stat'), `anon 1\ninactive_file ${inactive}\n`);
  writeFileSync(join(dir, 'memory.events'), `low 0\nhigh 0\nmax 0\noom 0\noom_kill ${oomKill}\n`);
}
const withRestarts = (h, counts) => {
  const base = h.fakeRun;
  h.fakeRun = (command, args) => {
    const r = base(command, args);
    if (command === 'docker' && args[0] === 'inspect') {
      return ok(r.stdout.split('\n').map(line => { const p = line.split('|'); if (counts[p[1]] !== undefined) p[4] = String(counts[p[1]]); return p.join('|'); }).join('\n'));
    }
    return r;
  };
};

test('containers: more than 3 restarts in an hour fails; the history ages out', () => {
  const h = harness();
  try {
    const data = W.freshState(h.clock.t);
    const run = () => { const ctx = W.makeContext(h.deps, data); return find(W.checkContainerRestarts(ctx), 'container_restarts:rest'); };
    assert.equal(run().ok, true);
    withRestarts(h, { rest: 3 }); h.advance(5 * 60000);
    assert.equal(run().ok, true, '3 restarts is the limit');
    withRestarts(h, { rest: 4 }); h.advance(5 * 60000);
    assert.equal(run().ok, false);
    h.advance(61 * 60000);
    assert.equal(run().ok, true, 'older than an hour');
  } finally { clean(h); }
});

test('containers: an OOM kill since the last run fires at once and is held for an hour', () => {
  const h = harness();
  try {
    const data = W.freshState(h.clock.t);
    const run = () => find(W.checkContainerOom(W.makeContext(h.deps, data)), 'container_oom:rest');
    cgroupFor(h, 'rest', { current: 1, max: 100, oomKill: 2 });
    assert.equal(run().ok, true, 'the first sight only sets the baseline');
    h.advance(5 * 60000); cgroupFor(h, 'rest', { current: 1, max: 100, oomKill: 3 });
    const r = run();
    assert.equal(r.ok, false); assert.equal(r.immediate, true);
    h.advance(30 * 60000); assert.equal(run().ok, false);
    h.advance(31 * 60000); assert.equal(run().ok, true);
  } finally { clean(h); }
});

test('containers: a restart or a recreate starts a new cgroup; its counter must not hide or fake an OOM', () => {
  const h = harness();
  try {
    const data = W.freshState(h.clock.t);
    const run = () => find(W.checkContainerOom(W.makeContext(h.deps, data)), 'container_oom:rest');
    const startedAt = stamp => { const base = h.fakeRun; h.fakeRun = (c, a) => { const r = base(c, a); return c === 'docker' && a[0] === 'inspect' ? ok(r.stdout.replace(/2026-10-18T00:00:00Z/g, stamp)) : r; }; };
    cgroupFor(h, 'rest', { current: 1, max: 100, oomKill: 5 });
    assert.equal(run().ok, true);
    // A restart: new StartedAt, the counter is back at 0. Not an OOM.
    startedAt('2026-10-19T01:00:00Z'); h.advance(5 * 60000); cgroupFor(h, 'rest', { current: 1, max: 100, oomKill: 0 });
    assert.equal(run().ok, true, 'a lower counter after a restart is not an OOM');
    // The first kill in the new cgroup (0 -> 1) is seen; before the fix the old baseline 5 hid it.
    h.advance(5 * 60000); cgroupFor(h, 'rest', { current: 1, max: 100, oomKill: 1 });
    assert.equal(run().ok, false, 'a kill after the restart');
    h.advance(61 * 60000);
    assert.equal(run().ok, true);
    // A recreate: the container id changes (the cgroup directory too), the counter starts at 2.
    const old = data.containers.rest.id;
    h.services = h.services.map(s => (s === 'rest' ? 'rest2' : s));
    const base = h.fakeRun;
    h.fakeRun = (c, a) => { const r = base(c, a); return c === 'docker' && a[0] === 'inspect' ? ok(r.stdout.replace(/\|rest2\|/g, '|rest|')) : r; };
    cgroupFor(h, 'rest2', { current: 1, max: 100, oomKill: 2 });
    const rest2 = idOf('rest2');
    const dirOld = join(h.cgroup, 'system.slice', `docker-${old}.scope`); rmSync(dirOld, { recursive: true, force: true });
    h.advance(5 * 60000);
    assert.equal(run().ok, true, 'a new container id sets a new baseline instead of alerting');
    assert.equal(data.containers.rest.id, rest2);
    h.advance(5 * 60000); cgroupFor(h, 'rest2', { current: 1, max: 100, oomKill: 3 });
    assert.equal(run().ok, false);
  } finally { clean(h); }
});

test('containers: OOM events from docker events count even when the cgroup counter cannot show them', () => {
  const h = harness();
  try {
    const data = W.freshState(h.clock.t); data.lastRunAt = h.clock.t - 5 * 60000;
    const run = () => find(W.checkContainerOom(W.makeContext(h.deps, data)), 'container_oom:rest');
    const event = time => JSON.stringify({ Type: 'container', Action: 'oom', Actor: { Attributes: { 'com.docker.compose.service': 'rest' } }, time });
    const firstTime = Math.floor(h.clock.t / 1000) - 60;
    h.runs['docker events'] = ok(`${event(firstTime)}\n`);
    const r = run();
    assert.equal(r.ok, false); assert.equal(r.immediate, true);
    const call = h.calls.find(c => c.startsWith('docker events'));
    assert.match(call, new RegExp(`--since ${Math.floor((h.clock.t - 5 * 60000) / 1000)} --until ${Math.floor(h.clock.t / 1000)} --filter event=oom --filter label=com.docker.compose.project=warehouse-test --format`));
    // The same event, seen again by the next run's overlapping window, does not extend the hold.
    h.advance(61 * 60000); data.lastRunAt = h.clock.t - 5 * 60000;
    h.runs['docker events'] = ok(`${event(firstTime)}\n`);
    assert.equal(run().ok, true, 'the same event again is not a new OOM');
    h.runs['docker events'] = ok(`${event(firstTime)}\n${event(Math.floor(h.clock.t / 1000) - 5)}\n`);
    assert.equal(run().ok, false, 'a newer event is');
  } finally { clean(h); }
});

test('containers: memory above 90% of the limit (working set) fails; no limit means no check', () => {
  const h = harness();
  try {
    cgroupFor(h, 'rest', { current: 900, max: 1000 });
    cgroupFor(h, 'db', { current: 1000, max: 'max' });
    cgroupFor(h, 'gateway', { current: 1000, max: 1000, inactive: 99 });
    let r = W.checkContainerMemory(h.ctx());
    assert.equal(find(r, 'container_memory:rest').ok, true);
    assert.equal(find(r, 'container_memory:gateway').ok, false);
    assert.equal(find(r, 'container_memory:db'), undefined);
    cgroupFor(h, 'rest', { current: 901, max: 1000 });
    assert.equal(find(W.checkContainerMemory(h.ctx()), 'container_memory:rest').ok, false);
    cgroupFor(h, 'gateway', { current: 1000, max: 1000, inactive: 100 });
    assert.equal(find(W.checkContainerMemory(h.ctx()), 'container_memory:gateway').ok, true);
  } finally { clean(h); }
});

test('services: a missing, stopped or unhealthy expected service fails; profile services that do not run are not missing', () => {
  const h = harness();
  try {
    assert.deepEqual(W.checkServices(h.ctx()).filter(x => !x.ok), []);
    assert.deepEqual(W.checkServices(h.ctx()).map(x => x.id), SERVICES.map(s => `service_down:${s}`), 'the list comes from compose config --services');
    const once = h.ctx(); W.checkServices(once); once.expectedServices();
    assert.equal(h.calls.filter(c => c.includes('compose.sh config --services')).length, 3, 'once per context (a run), however often it is asked');
    const base = h.fakeRun;
    h.fakeRun = (command, args) => {
      const r = base(command, args);
      if (command === 'docker' && args[0] === 'inspect') return ok(r.stdout.split('\n').filter(l => !l.includes('|pdf-renderer|')).map(l => l.replace('|gateway|running|healthy', '|gateway|running|unhealthy').replace('|rest|running|', '|rest|exited|')).join('\n'));
      return r;
    };
    const failed = W.checkServices(h.ctx()).filter(x => !x.ok).map(x => x.id).sort();
    assert.deepEqual(failed, ['service_down:gateway', 'service_down:pdf-renderer', 'service_down:rest']);
  } finally { clean(h); }
});

test('services: a running profile service is judged; one that is not running is not missing; one-off containers are ignored; ps lists profiles', () => {
  const h = harness();
  try {
    h.services = [...SERVICES, 'supavisor'];
    let r = W.checkServices(h.ctx());
    assert.equal(find(r, 'service_down:supavisor').ok, true);
    assert.ok(h.calls.some(c => c.includes("compose.sh --profile * ps -a -q")));
    h.services = [...SERVICES];
    r = W.checkServices(h.ctx());
    assert.equal(find(r, 'service_down:supavisor'), undefined, 'a profile service that is down is not an alert');
    h.services = [...SERVICES, 'backup-run'];
    const base = h.fakeRun;
    h.fakeRun = (command, args) => { const x = base(command, args); return command === 'docker' && args[0] === 'inspect' ? ok(x.stdout.replace(/\|backup-run\|(.*)\|False$/m, '|backup-run|$1|True')) : x; };
    const containers = h.ctx().containers();
    assert.equal(containers.some(c => c.service === 'backup-run'), false);
    h.expected = [...SERVICES, 'auth'];
    assert.equal(find(W.checkServices(h.ctx()), 'service_down:auth').ok, false, 'an expected default service that is absent is missing');
    h.runs['config --services'] = bad('no such file');
    assert.throws(() => W.checkServices(h.ctx()), /config --services failed/);
  } finally { clean(h); }
});

test('container memory: without cgroup files docker stats gives the share; with neither, one non-alerting result says so', () => {
  const h = harness();
  try {
    h.runs['docker stats'] = ok(`${idOf('rest').slice(0, 12)}|95.00%\n${idOf('db').slice(0, 12)}|10.5%\n`);
    let r = W.checkContainerMemory(h.ctx());
    assert.equal(find(r, 'container_memory:rest').ok, false);
    assert.equal(find(r, 'container_memory:db').ok, true);
    assert.match(h.calls.find(c => c.startsWith('docker stats')), /--no-stream --format \{\{\.ID\}\}\|\{\{\.MemPerc\}\}/);
    h.runs['docker stats'] = bad('cannot connect');
    const ctx = h.ctx();
    r = W.checkContainerMemory(ctx);
    assert.deepEqual(r.map(x => [x.id, x.ok]), [['container_memory_check', true]]);
    assert.match(r[0].summary, /unavailable/);
    assert.match(ctx.data.memoryNote, /unavailable/);
  } finally { clean(h); }
});

// ---------------------------------------------------------------- API
test('API: local gateway probe, public HTTPS probe', async () => {
  const h = harness();
  try {
    const local = 'http://127.0.0.1:18000/functions/v1/get-public-config';
    const pub = 'https://acme.example.test/functions/v1/get-public-config';
    assert.equal((await W.checkApiLocal(h.ctx()))[0].ok, false);
    h.fetchTable[local] = { status: 200, body: {} };
    assert.equal((await W.checkApiLocal(h.ctx()))[0].ok, true);
    h.fetchTable[local] = { status: 502, body: {} };
    assert.equal((await W.checkApiLocal(h.ctx()))[0].ok, false);
    assert.equal((await W.checkApiPublic(h.ctx()))[0].ok, false, 'no answer');
    h.fetchTable[pub] = { status: 200, body: { success: true, data: { instanceId: 'iid-1' } } };
    assert.equal((await W.checkApiPublic(h.ctx()))[0].ok, true);
    h.fetchTable[pub] = { status: 200, body: { success: true, data: { instanceId: 'other' } } };
    assert.equal((await W.checkApiPublic(h.ctx()))[0].ok, false, 'another installation answers');
  } finally { clean(h); }
});

// The line is built from the gateway's own log format in docker/nginx/nginx.conf, so a change there fails this test.
const nginxText = readFileSync(join(repo, 'docker/nginx/nginx.conf'), 'utf8');
const logFormat = (nginxText.match(/^\s+log_format warehouse_redacted '([^\n]*)';$/m) ?? [])[1];
assert.ok(logFormat, 'the warehouse_redacted log format is in docker/nginx/nginx.conf');
const gatewayLine = (status, seconds) => {
  const values = { remote_addr: '172.18.0.1', time_local: '19/Oct/2026:10:00:00 +0000', request_method: 'GET', uri: '/rest/v1/x', server_protocol: 'HTTP/1.1', status: String(status), body_bytes_sent: '123', request_time: seconds };
  return logFormat.replace(/\$([a-z_]+)/g, (_, name) => { if (!(name in values)) throw new Error(`unknown log variable ${name}`); return values[name]; });
};
test('the gateway test line is in the shape the nginx log format produces, and the checker reads it', () => {
  assert.equal(gatewayLine(200, '0.100'), '172.18.0.1 [19/Oct/2026:10:00:00 +0000] "GET /rest/v1/x HTTP/1.1" 200 123 0.100');
  assert.deepEqual(W.parseGatewayLog(gatewayLine(502, '1.500')), [{ status: 502, seconds: 1.5 }]);
  assert.deepEqual(W.parseGatewayLog(gatewayLine(429, '0.000')), [{ status: 429, seconds: 0 }]);
  // nginx's own error log lines (also on the container's output) are not request lines and are skipped.
  assert.equal(W.parseGatewayLog('2026/10/26 10:00:00 [error] 30#30: *3 no live upstreams while connecting to upstream, client: 10.0.0.3, server: _, request: "GET /rest/v1/x HTTP/1.1", upstream: "http://rest_up/x", host: "gateway:8000"').length, 0);
});
test('API logs: 5xx share above 5% and p95 latency above 2 s, from the last 5 minutes; small samples are not judged', () => {
  const h = harness();
  try {
    const logs = lines => { h.runs['docker logs'] = ok(lines.join('\n')); return W.checkApiLogs(h.ctx()); };
    const mix = (errors, slow, total = 20) => Array.from({ length: total }, (_, i) => gatewayLine(i < errors ? 500 : 200, i < slow ? '3.000' : '0.100'));
    let r = logs(mix(1, 1));
    assert.equal(find(r, 'api_error_rate_high').ok, true, '1 of 20 is 5%');
    assert.equal(find(r, 'api_latency_p95_high').ok, true, '1 slow of 20 leaves p95 fast');
    r = logs(mix(2, 2));
    assert.equal(find(r, 'api_error_rate_high').ok, false);
    assert.equal(find(r, 'api_latency_p95_high').ok, false);
    r = logs(Array.from({ length: 20 }, () => gatewayLine(200, '2.000')));
    assert.equal(find(r, 'api_latency_p95_high').ok, true, '2.000 s is the limit');
    r = logs(Array.from({ length: 20 }, () => gatewayLine(200, '2.010')));
    assert.equal(find(r, 'api_latency_p95_high').ok, false);
    r = logs(mix(5, 5, 5));
    assert.equal(r.every(x => x.ok), true, 'fewer than 10 requests');
    assert.ok(h.calls.some(c => c === `docker logs -t --tail 5000 ${idOf('gateway')}`), 'the last 5000 lines with their time stamps');
    assert.ok(!h.calls.some(c => c.includes('--since')), 'no --since: it returned nothing on a Dev host (Docker 29.9.1)');
  } finally { clean(h); }
});

test('API logs: a docker that ignores --since still gives the right window, cut by the -t time stamps; old lines and lines without a stamp', () => {
  const h = harness();
  try {
    // The fake behaves like the host where --since returned nothing: it ignores every window option and answers with the
    // tail it is asked for, each line stamped as `docker logs -t` does (RFC 3339 with nanoseconds, UTC).
    const stamp = (agoMs, line) => `${new Date(h.clock.t - agoMs).toISOString().replace(/Z$/, '456789Z')} ${line}`;
    const serve = lines => h.runs['docker logs'] = command => {
      assert.match(command, / -t --tail 5000 /); assert.doesNotMatch(command, /--since/);
      return ok(lines.join('\n') + '\n');
    };
    const old = Array.from({ length: 30 }, (_, i) => stamp(10 * 60000 + i, gatewayLine(500, '9.000')));   // 10 minutes ago: all errors, all slow
    const recent = Array.from({ length: 20 }, (_, i) => stamp(60000 + i * 1000, gatewayLine(i < 1 ? 500 : 200, '0.100')));   // 1 minute ago: 1 of 20 is 5xx
    serve([...old, ...recent]);
    let r = find(W.checkApiLogs(h.ctx()), 'api_error_rate_high');
    assert.equal(r.ok, true, JSON.stringify(r)); assert.match(r.summary, /API 5xx rate 5\.0% over 20 requests/, 'only the last 5 minutes count');
    assert.equal(find(W.checkApiLogs(h.ctx()), 'api_latency_p95_high').ok, true, 'the slow old lines are not in the window');
    // The window edge: 5 minutes exactly is in, 1 ms older is out.
    serve([stamp(5 * 60000 + 1, gatewayLine(500, '0.100')), ...Array.from({ length: 10 }, () => stamp(5 * 60000, gatewayLine(200, '0.100')))]);
    assert.match(find(W.checkApiLogs(h.ctx()), 'api_error_rate_high').summary, /API 5xx rate 0\.0% over 10 requests/);
    // Everything older than the window: too few requests to judge, not an error, and not the old numbers.
    serve(old);
    assert.match(find(W.checkApiLogs(h.ctx()), 'api_error_rate_high').summary, /Too few requests \(0\) to judge the error rate/);
    // 429s in the window count; 429s outside it do not.
    serve([...Array.from({ length: 40 }, () => stamp(20 * 60000, gatewayLine(429, '0.100'))), ...Array.from({ length: 60 }, (_, i) => stamp(30000, gatewayLine(i < 3 ? 429 : 200, '0.100')))]);
    const limited = find(W.checkApiLogs(h.ctx()), 'api_429_rate_high');
    assert.equal(limited.ok, false); assert.match(limited.summary, /429 \(too many requests\) to 3 of 60 requests, 5\.0%/);
    // A line the stamp of which cannot be read is kept (it cannot be placed); with the stamp it carries, a plain line parses as before.
    serve([...Array.from({ length: 10 }, () => gatewayLine(200, '0.100')), 'garbage T Z line']);
    assert.match(find(W.checkApiLogs(h.ctx()), 'api_error_rate_high').summary, /over 10 requests/);
    assert.equal(W.parseGatewayLog(`${stamp(1000, gatewayLine(200, '0.100'))}\n${stamp(900000, gatewayLine(200, '0.100'))}`).length, 2, 'without a window every line counts');
    assert.equal(W.parseGatewayLog(`${stamp(1000, gatewayLine(200, '0.100'))}\n${stamp(900000, gatewayLine(200, '0.100'))}`, { sinceMs: h.clock.t - 60000 }).length, 1);
  } finally { clean(h); }
});

test('PDF renderer probe runs in the functions container; the central key file is checked when configured', () => {
  const h = harness();
  try {
    assert.equal(W.checkPdfRenderer(h.ctx())[0].ok, true);
    h.runs['exec -T functions'] = bad();
    assert.equal(W.checkPdfRenderer(h.ctx())[0].ok, false);
    assert.ok(h.calls.some(c => c.includes('/dev/tcp/pdf-renderer/3000') && c.includes('read -t 10')));
    assert.equal(W.checkCentralKey(h.ctx())[0].ok, true, 'not configured');
    writeFileSync(join(h.state, 'config/compose.env'), 'WAREHOUSE_PROJECT_NAME=warehouse-test\nCENTRAL_JWKS_FILE=central-jwks.json\n', { mode: 0o600 });
    const r = W.checkCentralKey(h.ctx())[0];
    assert.equal(r.ok, false); assert.match(r.detail, /central-jwks\.json/);
  } finally { clean(h); }
});

test('API logs: 429 answers above 2% of 50 or more requests, or above 20 in the window, fail api_429_rate_high; fewer than 10 requests are not judged', () => {
  const h = harness();
  try {
    const logs = lines => { h.runs['docker logs'] = ok(lines.join('\n')); return find(W.checkApiLogs(h.ctx()), 'api_429_rate_high'); };
    const mix = (limited, total) => Array.from({ length: total }, (_, i) => gatewayLine(i < limited ? 429 : 200, '0.100'));
    assert.equal(logs(mix(1, 50)).ok, true, '1 of 50 is 2%, the limit');
    const two = logs(mix(2, 50));
    assert.equal(two.ok, false); assert.match(two.summary, /429 \(too many requests\) to 2 of 50 requests, 4\.0% \(limit 2% or 20 in 5 minutes\)/);
    assert.match(two.detail, /every phone on one Wi-Fi/);
    assert.equal(logs(mix(5, 49)).ok, true, 'under 50 requests the share is not judged');
    assert.equal(logs(mix(20, 2000)).ok, true, '20 of 2000: neither more than 20 nor over 2%');
    assert.equal(logs(mix(21, 2000)).ok, false, 'more than 20 in the window, though only 1%');
    assert.equal(logs(mix(0, 500)).ok, true);
    const few = logs(mix(5, 5));
    assert.equal(few.ok, true); assert.match(few.summary, /Too few requests/);
    // The other two results of the same check are unchanged by 429s (they are not 5xx).
    const all = (h.runs['docker logs'] = ok(mix(30, 100).join('\n')), W.checkApiLogs(h.ctx()));
    assert.equal(find(all, 'api_error_rate_high').ok, true);
    assert.deepEqual(all.map(r => r.id), ['api_error_rate_high', 'api_latency_p95_high', 'api_429_rate_high']);
  } finally { clean(h); }
});

// ---------------------------------------------------------------- SMS delivery, break-glass and the clock
// The query returns: not accepted in 24 h | requests in 24 h | not accepted in the last hour | requests in the last hour.
const smsRun = (h, row) => { h.runs.psql = ok(`${row}\n`); return W.checkSmsDelivery(h.ctx()); };
test('SMS delivery: more than 20% (from 10 requests) or more than 10 not accepted in 24 hours, or half of 5 or more in the last hour, fails at once', () => {
  const h = harness();
  try {
    assert.equal(smsRun(h, '4|20|0|0')[0].ok, true, '20% exactly');
    assert.equal(smsRun(h, '5|20|0|0')[0].ok, false, '25%');
    assert.equal(smsRun(h, '10|200|0|0')[0].ok, true, '10 of 200 is neither');
    assert.equal(smsRun(h, '11|200|0|0')[0].ok, false, 'more than 10 whatever the share');
    assert.equal(smsRun(h, '3|5|0|0')[0].ok, true, 'under 10 requests the share is not judged');
    assert.equal(smsRun(h, '0|0|0|0')[0].ok, true, 'a quiet day');
    // The last hour alone: 24 hours of normal traffic with a lapse that has just begun.
    assert.equal(smsRun(h, '2|200|2|5')[0].ok, true, '2 of 5 in the hour is under half');
    assert.equal(smsRun(h, '4|200|4|4')[0].ok, true, 'under 5 requests in the hour are not judged');
    const lapse = smsRun(h, '5|200|5|10')[0];
    assert.equal(lapse.ok, false, '5 of 10 in the hour is half');
    assert.match(lapse.summary, /5 of 10 sign-in code requests in the last hour were not accepted by the SMS provider \(limit 50% from 5 requests\)/);
    const r = smsRun(h, '12|40|0|0')[0];
    assert.equal(r.immediate, true);
    assert.match(r.summary, /12 of 40 sign-in code requests in the last 24 hours were not accepted by the SMS provider \(limit 20% or 10\)/);
    assert.match(r.detail, /MSG91 balance, DLT template and sender ID/);
    const sql = h.calls.find(c => c.includes('psql') && c.includes('otp_verifications'));
    assert.match(sql, /delivery_status IS DISTINCT FROM 'accepted'/); assert.match(sql, /created_at > now\(\) - interval '24 hours'/);
    assert.match(sql, /created_at > now\(\) - interval '1 hour'/);
    assert.match(sql, /NOT \(delivery_status = 'sending' AND created_at > now\(\) - interval '5 minutes'\)/, 'requests still in flight are left out');
    assert.match(sql, /statement_timeout=10000/);
    // Hourly: once checked, the check does not run again until 58 minutes have passed, and it says it did not run.
    const ctx = h.ctx();
    h.runs.psql = ok('0|10|0|0\n');
    assert.equal(W.checkSmsDelivery(ctx)[0].ok, true);
    assert.equal(ctx.data.lastSmsCheck, h.clock.t);
    const queries = () => h.calls.filter(c => c.includes('otp_verifications')).length;
    const before = queries();
    h.advance(5 * 60000); assert.equal(W.checkSmsDelivery(ctx), null); assert.equal(queries(), before);
    h.advance(52 * 60000); assert.equal(W.checkSmsDelivery(ctx), null, '57 minutes: not due');
    h.advance(60000); assert.equal(W.checkSmsDelivery(ctx)[0].ok, true, '58 minutes: due, at any hour of the day');
    assert.equal(queries(), before + 1);
    h.clock.t = new Date(2026, 9, 21, 3, 0).getTime(); ctx.data.lastSmsCheck = new Date(2026, 9, 21, 2, 0).getTime();
    assert.notEqual(W.checkSmsDelivery(ctx), null, 'not tied to the hour of the alive message: 03:00 is checked');
    ctx.data.lastSmsCheck = h.clock.t + 1000;
    assert.notEqual(W.checkSmsDelivery(ctx), null, 'a clock that went back is due');
    // A database that is down, or a query that fails.
    h.clock.t = new Date(2026, 9, 21, 10, 0).getTime();
    h.runs.pg_isready = bad();
    assert.equal(W.checkSmsDelivery(h.ctx()), null, 'postgres_down reports it');
    h.runs.pg_isready = ok(); h.runs.psql = bad('relation "public.otp_verifications" does not exist');
    assert.throws(() => W.checkSmsDelivery(h.ctx()), /SMS delivery query failed: relation/);
    h.runs.psql = ok('x|y|1|2\n');
    assert.throws(() => W.checkSmsDelivery(h.ctx()), /unexpected SMS delivery query output/);
    h.runs.psql = ok('1|2\n');
    assert.throws(() => W.checkSmsDelivery(h.ctx()), /unexpected SMS delivery query output/, 'the old two-number answer is not accepted');
    assert.equal(W.normalizeState({ lastSmsCheck: 'yesterday' }, 0, () => {}).lastSmsCheck, null);
  } finally { clean(h); }
});

test('SMS delivery through the run: fires at once, stays while the hourly check is not due, clears at the next hourly check', async () => {
  const h = harness();
  try {
    h.runs.psql = ok('12|40|0|0\n');
    const checks = [['sms_delivery', W.checkSmsDelivery]];
    h.seed();
    await W.runOnce(h.deps, { checks, heal: null });
    assert.equal(h.posts.filter(p => /^\[FIRING\]/.test(p.text) && /12 of 40 sign-in code requests/.test(p.text)).length, 1, 'one run is enough');
    h.runs.psql = ok('0|40|0|0\n');
    for (let i = 0; i < 3; i++) { h.advance(5 * 60000); await W.runOnce(h.deps, { checks, heal: null }); }
    assert.equal(h.posts.filter(p => /^\[CLEARED\]/.test(p.text)).length, 0, 'not recovered by runs that did not check');
    assert.ok(h.state_().alerts.sms_delivery.firingSince);
    h.advance(HOUR); await W.runOnce(h.deps, { checks, heal: null });
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks, heal: null });
    assert.equal(h.posts.filter(p => /^\[CLEARED\]/.test(p.text)).length, 1, 'cleared by the next hourly check, not a day later');
    assert.equal(h.state_().alerts.sms_delivery, undefined);
  } finally { clean(h); }
});

test('break-glass: any CODE_ISSUED or SIGN_IN audit row of the last 24 hours fires break_glass_used at once; no row, or a database without the migration, is fine', () => {
  const h = harness();
  try {
    const run = row => { h.runs.psql = ok(`${row}\n`); return W.checkBreakGlass(h.ctx())[0]; };
    let r = run('0||');
    assert.equal(r.ok, true); assert.equal(r.id, 'break_glass_used'); assert.match(r.summary, /No break-glass sign-in in the last 24 hours/);
    r = run('1|CODE_ISSUED|2026-10-19T09:30:05Z');
    assert.equal(r.ok, false); assert.equal(r.immediate, true);
    assert.match(r.summary, /break-glass administrator sign-in was used in the last 24 hours \(1 audit row: CODE_ISSUED; latest 2026-10-19T09:30:05Z\)/);
    assert.match(r.detail, /scripts\/break-glass-admin\.sh[^]*docs\/MONITORING\.md, "Break-glass sign-in"/);
    r = run('3|CODE_ISSUED,SIGN_IN|2026-10-19T09:41:00Z');
    assert.match(r.summary, /3 audit rows: CODE_ISSUED, SIGN_IN; latest/);
    const sql = h.calls.filter(c => c.includes('psql') && c.includes('audit_log')).at(-1);
    assert.match(sql, /table_name = 'break_glass' AND action IN \('CODE_ISSUED', 'SIGN_IN'\) AND created_at > now\(\) - interval '24 hours'/);
    assert.match(sql, /statement_timeout=10000/);
    assert.doesNotMatch(sql, /new_data|mobile/, 'the number in the row is not read');
    h.runs.pg_isready = bad();
    assert.equal(W.checkBreakGlass(h.ctx()), null, 'postgres_down says so');
    h.runs.pg_isready = ok(); h.runs.psql = bad('connection refused');
    assert.throws(() => W.checkBreakGlass(h.ctx()), /break-glass query failed/);
    h.runs.psql = ok('x||\n');
    assert.throws(() => W.checkBreakGlass(h.ctx()), /unexpected break-glass query output/);
    assert.ok(W.CHECKS.some(([name, fn]) => name === 'break_glass' && fn === W.checkBreakGlass));
    assert.ok(W.PASS_SAFE_CHECKS.includes('break_glass'));
  } finally { clean(h); }
});

test('break-glass through the run: fires at once, repeats like any alert, and clears when the rows leave the 24-hour window', async () => {
  const h = harness();
  try {
    const checks = [['break_glass', W.checkBreakGlass]];
    h.seed();
    h.runs.psql = ok('1|SIGN_IN|2026-10-19T09:30:05Z\n');
    await W.runOnce(h.deps, { checks, heal: null });
    const fired = h.posts.filter(p => /^\[FIRING\]/.test(p.text));
    assert.equal(fired.length, 1, 'the first run is enough');
    assert.match(fired[0].text, /break-glass administrator sign-in was used/);
    assert.ok(!/\d{10,}/.test(fired[0].text), 'no phone number');
    h.runs.psql = ok('0||\n');
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks, heal: null });
    assert.equal(h.posts.filter(p => /^\[CLEARED\]/.test(p.text)).length, 1);
  } finally { clean(h); }
});

test('clock: systemd NTPSynchronized=no, or more than 10 s from the clock of the public address\'s edge, fails clock_unsynced; an unreachable address is not judged', async () => {
  const h = harness();
  try {
    const origin = 'https://acme.example.test';
    const headers = skewMs => ({ get: name => (name === 'date' ? new Date(h.clock.t - skewMs).toUTCString() : null) });
    const trace = skewMs => `fl=2f\nvisit_scheme=https\nts=${((h.clock.t - skewMs) / 1000).toFixed(3)}\nip=203.0.113.9\n`;
    const asked = [];
    // Behind Cloudflare: /cdn-cgi/trace answers with its own ts= line.
    const edge = skewMs => { h.deps.fetch = async (url, options) => { asked.push({ url, options }); return { ok: true, status: 200, text: async () => trace(skewMs), headers: headers(0) }; }; };
    // Not behind Cloudflare: the trace page is a 404 of the origin, the function route answers with a Date header.
    const origin_ = skewMs => { h.deps.fetch = async (url, options) => { asked.push({ url, options });
      return url.endsWith('/cdn-cgi/trace') ? { ok: false, status: 404, text: async () => 'not found', headers: headers(0) } : { ok: true, status: 200, headers: headers(skewMs) }; }; };
    h.runs.timedatectl = ok('yes\n');
    edge(0);
    let r = (await W.checkClock(h.ctx()))[0];
    assert.equal(r.ok, true); assert.match(r.summary, /Host clock fine \(NTPSynchronized=yes, offset 0\.0 s\)/);
    assert.deepEqual(asked.map(a => [a.url, a.options.method, a.options.redirect]), [[`${origin}/cdn-cgi/trace`, undefined, 'error']], 'one GET to the edge, nothing through the gateway');
    assert.ok(asked[0].options.signal instanceof AbortSignal);
    assert.ok(h.calls.includes('timedatectl show -p NTPSynchronized --value'));
    edge(10000); assert.equal((await W.checkClock(h.ctx()))[0].ok, true, '10 s is the limit');
    edge(11000);
    r = (await W.checkClock(h.ctx()))[0];
    assert.equal(r.ok, false); assert.match(r.summary, /the host clock is 11 s ahead of the public address's clock/);
    assert.match(r.detail, /over 30 s off[^]*timedatectl set-ntp true/);
    edge(-45000);
    assert.match((await W.checkClock(h.ctx()))[0].summary, /45 s behind the public address's clock/);
    // The edge's ts= is what counts: a Date header that agrees with the host does not hide a wrong clock when the edge disagrees.
    h.deps.fetch = async () => ({ ok: true, status: 200, text: async () => trace(30000), headers: headers(0) });
    assert.match((await W.checkClock(h.ctx()))[0].summary, /30 s ahead/);
    // Not behind Cloudflare: the HEAD to the function route and its Date header, as before.
    asked.length = 0; origin_(0);
    r = (await W.checkClock(h.ctx()))[0];
    assert.equal(r.ok, true);
    assert.deepEqual(asked.map(a => [a.url, a.options.method]), [[`${origin}/cdn-cgi/trace`, undefined], [`${origin}/functions/v1/get-public-config`, 'HEAD']], 'trace first, then the fallback');
    assert.equal(asked[1].options.redirect, 'error');
    origin_(11000);
    assert.match((await W.checkClock(h.ctx()))[0].summary, /the host clock is 11 s ahead/);
    // A trace page without a usable ts= line falls back too.
    h.deps.fetch = async url => (url.endsWith('/cdn-cgi/trace') ? { ok: true, status: 200, text: async () => '<html>welcome</html>', headers: headers(0) } : { ok: true, status: 200, headers: headers(20000) });
    assert.match((await W.checkClock(h.ctx()))[0].summary, /20 s ahead/);
    edge(0); h.runs.timedatectl = ok('no\n');
    r = (await W.checkClock(h.ctx()))[0];
    assert.equal(r.ok, false); assert.match(r.summary, /not synchronised with a time server \(timedatectl: NTPSynchronized=no\)/);
    edge(20000);
    assert.match((await W.checkClock(h.ctx()))[0].summary, /not synchronised[^]*; the host clock is 20 s ahead/, 'both problems are named');
    // The address does not answer (tunnel down), or timedatectl is missing: the part that can be judged is.
    h.runs.timedatectl = ok('yes\n');
    h.deps.fetch = async () => { throw new Error('connect ECONNREFUSED'); };
    r = (await W.checkClock(h.ctx()))[0];
    assert.equal(r.ok, true); assert.match(r.summary, /no offset reading/);
    edge(0); h.runs.timedatectl = { status: 127, stdout: '', stderr: 'not found' };
    r = (await W.checkClock(h.ctx()))[0];
    assert.equal(r.ok, true); assert.match(r.summary, /NTP status unknown/);
    // A response without a usable Date header gives no offset.
    h.deps.fetch = async () => ({ ok: true, status: 200, headers: { get: () => 'not a date' } });
    assert.match((await W.checkClock(h.ctx()))[0].summary, /no offset reading/);
    assert.ok(W.CHECKS.some(([name, fn]) => name === 'clock' && fn === W.checkClock));
    assert.ok(W.CHECKS.some(([name, fn]) => name === 'sms_delivery' && fn === W.checkSmsDelivery));
  } finally { clean(h); }
});

// ---------------------------------------------------------------- health
const PROBE = 'exec -T storage node --input-type=module';
function healthy(h) { h.runs[PROBE] = ok('OK REST\nOK configuration\n'); }

test('health: the services, the database, the gateway probe and the renderer all pass', async () => {
  const h = harness();
  try {
    healthy(h);
    const inputs = [];
    const run = h.deps.run;
    h.deps.run = (command, args, options) => { if (options?.input !== undefined) inputs.push(options.input); return run(command, args, options); };
    const report = await W.runHealth(h.deps, { waitMs: 7000 });
    assert.equal(report.ok, true, JSON.stringify(report.lines));
    assert.deepEqual(report.lines.map(line => line.text), [
      ...SERVICES.map(name => `Service ${name} is running${['db', 'gateway'].includes(name) ? ' healthy' : ''}`),
      'PostgreSQL accepts connections', 'REST: answers through the gateway', 'configuration: answers through the gateway', 'PDF renderer reachable from functions',
    ]);
    // The probe runs in the storage container (a network shared with the gateway), waits as long as it was told, asks the RPC get_public_config with the
    // public key (the OpenAPI document at /rest/v1/ is off) and asks for the public configuration.
    assert.equal(inputs.length, 1);
    assert.match(inputs[0], /export async function waitForHttp/);
    assert.match(inputs[0], /const WAIT_MS = 7000;/);
    assert.match(inputs[0], /http:\/\/gateway:8000\/rest\/v1\/rpc\/get_public_config', \{ apikey: process\.env\.ANON_KEY, 'Content-Type': 'application\/json' \},\n    \{ method: 'POST', body: JSON\.stringify\(\{ p_environment: 'production' \}\) \}/);
    assert.match(inputs[0], /http:\/\/gateway:8000\/functions\/v1\/get-public-config/);
  } finally { clean(h); }
});

test('health: a missing service, a database that is down, a gateway that does not answer and an unreachable renderer each fail the check and are named', async () => {
  const h = harness();
  try {
    h.services = h.services.filter(name => name !== 'storage');
    h.runs.pg_isready = bad('no response');
    h.runs[PROBE] = ok('FAILED REST: readiness timed out (HTTP 503)\nOK configuration\n');
    h.runs['exec -T functions'] = bad();
    const report = await W.runHealth(h.deps, { waitMs: 0 });
    assert.equal(report.ok, false);
    assert.deepEqual(report.lines.filter(line => !line.ok).map(line => line.text), [
      'Service storage is missing', 'PostgreSQL is not accepting connections',
      'Gateway: REST: readiness timed out (HTTP 503)', 'PDF renderer is not reachable from functions (docker/docker-compose.yml, network renderer)',
    ]);
  } finally { clean(h); }
});

test('health: a probe that cannot run (no storage container) is a failure with the reason, not a pass', async () => {
  const h = harness();
  try {
    h.runs[PROBE] = bad('service "storage" is not running');
    const report = await W.runHealth(h.deps, { waitMs: 0 });
    assert.equal(report.ok, false);
    assert.deepEqual(report.lines.filter(line => !line.ok).map(line => line.text), ['Gateway probe could not run in the storage container (service "storage" is not running)']);
  } finally { clean(h); }
});

test('health: an exited, restarting or starting optional container is a warning, never a failure; an unhealthy default service fails', async () => {
  const h = harness();
  try {
    healthy(h);
    h.services = [...SERVICES, 'supavisor', 'cups', 'sensor-bridge'];
    h.stateOf = { supavisor: 'exited|', cups: 'restarting|', 'sensor-bridge': 'running|starting' };
    const report = await W.runHealth(h.deps, { waitMs: 0 });
    assert.equal(report.ok, true, JSON.stringify(report.lines));
    assert.deepEqual(report.lines.filter(line => line.warn).map(line => line.text), ['Service supavisor is exited', 'Service cups is restarting', 'Service sensor-bridge is running starting']);
    assert.equal(report.lines.some(line => !line.ok), false);
    const lines = [];
    assert.equal(await W.main(['health', '--wait', '0'], h.deps, text => lines.push(text)), 0);
    assert.equal(lines.filter(line => line.startsWith('warn   ')).length, 3);
    h.stateOf = { rest: 'running|unhealthy' };
    const bad_ = await W.runHealth(h.deps, { waitMs: 0 });
    assert.equal(bad_.ok, false);
    assert.deepEqual(bad_.lines.filter(line => !line.ok).map(line => line.text), ['Service rest is running unhealthy']);
  } finally { clean(h); }
});

test('health: the gateway probe passes only when both the REST and the configuration probe answered', async () => {
  const h = harness();
  try {
    h.runs[PROBE] = ok('OK REST\n');
    let report = await W.runHealth(h.deps, { waitMs: 0 });
    assert.equal(report.ok, false);
    assert.deepEqual(report.lines.filter(line => !line.ok).map(line => line.text), ['Gateway: configuration was not probed (the probe stopped early)']);
    h.runs[PROBE] = ok('OK configuration\n');
    report = await W.runHealth(h.deps, { waitMs: 0 });
    assert.deepEqual(report.lines.filter(line => !line.ok).map(line => line.text), ['Gateway: REST was not probed (the probe stopped early)']);
    h.runs[PROBE] = ok('FAILED REST: readiness timed out (HTTP 503)\nOK configuration\n');
    report = await W.runHealth(h.deps, { waitMs: 0 });
    assert.deepEqual(report.lines.filter(line => !line.ok).map(line => line.text), ['Gateway: REST: readiness timed out (HTTP 503)'], 'a named failure is not reported twice');
  } finally { clean(h); }
});

test('watch.mjs health prints one line per check and exits 1 on a fault; it refuses other arguments', async () => {
  const h = harness();
  try {
    healthy(h);
    const lines = [];
    assert.equal(await W.main(['health', '--wait', '0'], h.deps, text => lines.push(text)), 0);
    assert.ok(lines.every(line => line.startsWith('ok     ')), lines.join('\n'));
    h.runs[PROBE] = ok('OK REST\nFAILED configuration: readiness timed out (HTTP 502)\n');
    lines.length = 0;
    assert.equal(await W.main(['health', '--wait', '0'], h.deps, text => lines.push(text)), 1);
    assert.deepEqual(lines.filter(line => line.startsWith('FAILED ')), ['FAILED Gateway: configuration: readiness timed out (HTTP 502)']);
    lines.length = 0;
    assert.equal(await W.main(['health', '--fast'], h.deps, text => lines.push(text)), 1);
    assert.match(lines[0], /only --wait SECONDS/);
  } finally { clean(h); }
});

// ---------------------------------------------------------------- backups
test('backups: missing after 26 h, grace for a new install, failed, newest directory counts, retention failure', () => {
  const h = harness();
  try {
    const status = (job, fields) => writeFileSync(join(h.state, `config/watch-${job}.last`), Object.entries(fields).map(([k, v]) => `${k}=${v}`).join('\n') + '\n');
    const epoch = ms => Math.floor(ms / 1000);
    h.clock.t = T0;
    let r = W.checkBackups(h.ctx());
    assert.equal(find(r, 'backup_missing').ok, true, 'no backup yet, but the install is new');
    const data = W.loadState(h.state, T0); data.firstRun = T0 - 27 * HOUR;
    assert.equal(find(W.checkBackups(W.makeContext(h.deps, data)), 'backup_missing').ok, false, 'no backup in 27 h of life');
    status('backup', { result: 'ok', last_success_epoch: epoch(T0 - 26 * HOUR), finished_epoch: epoch(T0 - 26 * HOUR) });
    assert.equal(find(W.checkBackups(h.ctx()), 'backup_missing').ok, true, 'exactly 26 h');
    status('backup', { result: 'ok', last_success_epoch: epoch(T0 - 26 * HOUR - 1000), finished_epoch: 0 });
    assert.equal(find(W.checkBackups(h.ctx()), 'backup_missing').ok, false);
    const dir = join(h.state, 'backups/warehouse-20261019T010000Z'); mkdirSync(dir);
    writeFileSync(join(dir, 'metadata.txt'), 'format=warehouse-backup-v5\n');
    utimesSync(join(dir, 'metadata.txt'), new Date(T0 - HOUR), new Date(T0 - HOUR));
    assert.equal(find(W.checkBackups(h.ctx()), 'backup_missing').ok, true, 'a manual backup counts');
    status('backup', { result: 'failed', last_success_epoch: epoch(T0 - 3 * HOUR), finished_epoch: epoch(T0 - 1000), message: 'disk full' });
    utimesSync(join(dir, 'metadata.txt'), new Date(T0 - 3 * HOUR), new Date(T0 - 3 * HOUR));
    r = W.checkBackups(h.ctx());
    assert.equal(find(r, 'backup_failed').ok, false); assert.equal(find(r, 'backup_failed').detail, 'disk full');
    status('retention', { result: 'failed', message: 'locked' });
    assert.equal(find(W.checkBackups(h.ctx()), 'retention_failed').ok, false);
    assert.equal(find(r, 'usb_backup').ok, true);
  } finally { clean(h); }
});

test('USB backup: a failed last copy is reported', () => {
  const h = harness();
  try {
    writeFileSync(join(h.state, 'config/usb-backup.last'), 'result=failed\nfinished_utc=2026-10-18T00:00:00Z\nmessage=drive missing\n');
    const r = find(W.checkBackups(h.ctx()), 'usb_backup');
    assert.equal(r.ok, false); assert.match(r.summary, /drive missing/);
  } finally { clean(h); }
});

// ---------------------------------------------------------------- alerting
test('an alert fires only after 2 failing runs; posts at start, repeats after 4 h, and clears once', async () => {
  const h = harness();
  try {
    const checks = stub(failing());
    const pass = [['stub', () => [{ check: 'stub', id: 'thing_bad', ok: true, summary: 'fine', detail: '' }]]];
    await W.runOnce(h.deps, { checks, ...NO_JOBS });
    const alerts = () => h.posts.filter(p => !p.text.startsWith('Monitoring is alive'));
    assert.equal(alerts().length, 0, 'one failing run is not enough');
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(alerts().length, 1);
    assert.match(alerts()[0].text, /^\[FIRING\] Acme Cold \(warehouse-test\)\n- thing_bad is bad/);
    assert.equal(alerts()[0].url, WEBHOOK);
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks, ...NO_JOBS });
    h.advance(3 * HOUR); await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(alerts().length, 1, 'quiet before 4 h');
    h.advance(HOUR); await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(alerts().length, 2);
    assert.match(alerts()[1].text, /^\[STILL FIRING\]/);
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks: pass, ...NO_JOBS });
    assert.equal(alerts().length, 3);
    assert.match(alerts()[2].text, /^\[CLEARED\] Acme Cold \(warehouse-test\)\n- thing_bad is bad/);
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks: pass, ...NO_JOBS });
    assert.equal(alerts().length, 3, 'cleared once only');
    assert.deepEqual(h.state_().alerts, {});
  } finally { clean(h); }
});

test('a failing run that recovers before the second run never posts, and an immediate alert fires at once', async () => {
  const h = harness();
  try {
    await W.runOnce(h.deps, { checks: stub(failing()), ...NO_JOBS });
    h.advance(5 * 60000);
    await W.runOnce(h.deps, { checks: stub({ id: 'thing_bad', ok: true, summary: '', detail: '' }), ...NO_JOBS });
    h.advance(5 * 60000);
    await W.runOnce(h.deps, { checks: stub(failing()), ...NO_JOBS });
    assert.equal(h.posts.filter(p => /FIRING/.test(p.text)).length, 0, 'the count restarted');
    h.advance(5 * 60000);
    await W.runOnce(h.deps, { checks: stub(failing('oom_event', { immediate: true })), ...NO_JOBS });
    assert.equal(h.posts.filter(p => /oom_event/.test(p.text)).length, 1);
  } finally { clean(h); }
});

test('the state records failingRuns, firingSince and lastSent per alert', async () => {
  const h = harness();
  try {
    await W.runOnce(h.deps, { checks: stub(failing()), ...NO_JOBS });
    assert.equal(h.state_().alerts.thing_bad.failingRuns, 1);
    assert.equal(h.state_().alerts.thing_bad.firingSince, null);
    h.advance(5 * 60000);
    await W.runOnce(h.deps, { checks: stub(failing()), ...NO_JOBS });
    const a = h.state_().alerts.thing_bad;
    assert.deepEqual([a.failingRuns, a.firingSince, a.lastSent], [2, h.clock.t, h.clock.t]);
    const s = h.state_();
    for (const key of ['lastRunAt', 'lastHeartbeat', 'lastDailyRun', 'cpu', 'firstRun']) assert.ok(key in s, key);
    assert.ok(!('muteUntil' in s) && !('mutes' in s), 'mutes have their own file');
  } finally { clean(h); }
});

test('a failed post is retried at the next run (lastSent is only set after Slack accepts)', async () => {
  const h = harness();
  try {
    const checks = stub(failing());
    await W.runOnce(h.deps, { checks, ...NO_JOBS });
    h.advance(5 * 60000); h.postFails = true;
    await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(h.state_().alerts.thing_bad.lastSent, null);
    h.postFails = false; h.advance(5 * 60000);
    await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(h.posts.filter(p => /FIRING/.test(p.text)).length, 1);
  } finally { clean(h); }
});

test('one "monitoring is alive" message per local calendar day, after 09:00', async () => {
  const h = harness();
  try {
    const alive = () => h.posts.filter(p => /^Monitoring is alive - Acme Cold \(warehouse-test\)\nNo alerts firing\./.test(p.text)).length;
    const pass = async () => { await W.runOnce(h.deps, { checks: [], ...NO_JOBS }); };
    await pass();
    assert.equal(alive(), 1, 'the first run says it is alive');
    h.advance(5 * 60000); await pass();
    assert.equal(alive(), 1);
    h.clock.t = new Date(2026, 9, 20, 8, 55).getTime(); await pass();
    assert.equal(alive(), 1, 'a new day, but before 09:00');
    h.clock.t = new Date(2026, 9, 20, 9, 0).getTime(); await pass();
    assert.equal(alive(), 2, 'a calendar day after the last one, at 09:00 (not 24 h later)');
    h.clock.t = new Date(2026, 9, 20, 23, 59).getTime(); await pass();
    assert.equal(alive(), 2, 'once per day');
    // The clock steps back (a wrong clock corrected): the message is due again instead of waiting for the old time.
    h.clock.t = new Date(2026, 9, 19, 12, 0).getTime(); await pass();
    assert.equal(alive(), 3);
  } finally { clean(h); }
});

test('heartbeat and daily date follow the local calendar across a daylight-saving change', () => {
  const zone = process.env.TZ;
  process.env.TZ = 'America/New_York';
  try {
    // 2026-11-01 has 25 hours in New York (clocks go back at 02:00).
    const at = (d, hh, mm) => new Date(2026, 10, d, hh, mm).getTime();
    assert.equal(W.heartbeatDue(at(1, 9, 5), new Date(2026, 9, 31, 10, 0).getTime()), true, 'next calendar day, after 09:00');
    assert.equal(W.heartbeatDue(at(1, 8, 59), new Date(2026, 9, 31, 10, 0).getTime()), false, 'before 09:00');
    assert.equal(W.heartbeatDue(at(1, 23, 0), at(1, 9, 5)), false, 'same day, 14 h later');
    assert.equal(W.heartbeatDue(at(2, 9, 0), at(1, 9, 5)), true, '23 h 55 min later is still a new day');
    assert.equal(W.localDate(at(1, 0, 30)), '2026-11-01');
    // The 02:30 daily window on the 25-hour day starts once, on 11-01, and is closed 6 h after it.
    const w = W.dailyWindow(at(1, 4, 0), '02:30');
    assert.equal(w.date, '2026-11-01'); assert.equal(w.open, true);
    assert.equal(W.dailyWindow(at(1, 9, 0), '02:30').open, false);
    assert.equal(W.dailyWindow(at(1, 2, 0), '02:30').date, '2026-10-31', 'before the time: the previous day\'s window (closed)');
    // Spring forward: 02:30 does not exist on 2026-03-08; the window still has one date and one start.
    const spring = W.dailyWindow(new Date(2026, 2, 8, 4, 0).getTime(), '02:30');
    assert.equal(spring.date, '2026-03-08'); assert.equal(spring.open, true);
  } finally {
    if (zone === undefined) delete process.env.TZ; else process.env.TZ = zone;
  }
});

test('mute: all alerts or one alert id; the heartbeat still goes out; unmuted alerts post at once', async () => {
  const h = harness();
  try {
    const checks = stub(failing('a_bad'), failing('b_bad'));
    writeFileSync(join(h.state, 'config/watch-mutes.json'), JSON.stringify({ all: null, ids: { a_bad: h.clock.t + HOUR } }));
    await W.runOnce(h.deps, { checks, ...NO_JOBS });
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks, ...NO_JOBS });
    const firing = h.posts.filter(p => /FIRING/.test(p.text));
    assert.equal(firing.length, 1);
    assert.match(firing[0].text, /b_bad/); assert.doesNotMatch(firing[0].text, /a_bad/);
    // global mute through the command, then past its end
    const out = [];
    assert.equal(await W.main(['mute', '30'], h.deps, t => out.push(t)), 0);
    assert.match(out[0], /^Muted all alerts until /);
    const c = stub(failing('c_bad'));
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks: c, ...NO_JOBS });
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks: c, ...NO_JOBS });
    assert.equal(h.posts.filter(p => /c_bad/.test(p.text)).length, 0, 'muted');
    h.advance(31 * 60000); await W.runOnce(h.deps, { checks: c, ...NO_JOBS });
    assert.equal(h.posts.filter(p => /c_bad/.test(p.text)).length, 1, 'posted once the mute ended');
    assert.equal(await W.main(['mute', '0'], h.deps, t => out.push(t)), 1);
    assert.equal(await W.main(['mute', '10', 'c_bad'], h.deps, t => out.push(t)), 0);
    const mutes = () => JSON.parse(readFileSync(join(h.state, 'config/watch-mutes.json'), 'utf8'));
    assert.ok(mutes().ids.c_bad > h.clock.t);
    assert.equal(statSync(join(h.state, 'config/watch-mutes.json')).mode & 0o777, 0o600);
    assert.equal('mutes' in h.state_() || 'muteUntil' in h.state_(), false, 'mutes are not part of the run state');
    assert.equal(await W.main(['unmute'], h.deps, t => out.push(t)), 0);
    assert.deepEqual(mutes(), { all: null, ids: {} });
  } finally { clean(h); }
});

test('mute never covers backup_missing, backup_failed or daily_timer_legacy: they post while everything is muted, and the alive message says so', async () => {
  const h = harness();
  try {
    const out = [];
    assert.equal(await W.main(['mute', '600'], h.deps, t => out.push(t)), 0);
    assert.match(out[0], /^Muted all alerts until \S+\. backup_missing, backup_failed and daily_timer_legacy are not muted\.$/);
    assert.equal(await W.main(['mute', '600', 'backup_missing'], h.deps, t => out.push(t)), 1);
    assert.match(out[1], /^backup_missing cannot be muted: it says no backup exists\.$/);
    assert.equal(await W.main(['mute', '600', 'backup_failed'], h.deps, t => out.push(t)), 1);
    assert.equal(await W.main(['mute', '600', 'daily_timer_legacy'], h.deps, t => out.push(t)), 1);
    assert.match(out.at(-1), /^daily_timer_legacy cannot be muted: it says the daily backup is kept running by an out-of-date unit\.$/);
    // An older mute file that names them is ignored too.
    writeFileSync(join(h.state, 'config/watch-mutes.json'), JSON.stringify({ all: h.clock.t + 10 * HOUR, ids: { backup_failed: h.clock.t + 10 * HOUR, other_bad: h.clock.t + 10 * HOUR } }));
    const checks = stub(failing('backup_missing'), failing('backup_failed', { detail: 'disk full' }), failing('daily_timer_legacy'), failing('other_bad'), failing('service_down:rest'));
    await W.runOnce(h.deps, { checks, heal: null });
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks, heal: null });
    const fired = h.posts.filter(p => /^\[FIRING\]/.test(p.text));
    assert.equal(fired.length, 1);
    assert.match(fired[0].text, /backup_missing is bad/); assert.match(fired[0].text, /backup_failed is bad: disk full/); assert.match(fired[0].text, /daily_timer_legacy is bad/);
    assert.doesNotMatch(fired[0].text, /other_bad|service_down/, 'the others stay muted');
    // The daily "alive" message names the exception, for a global mute and for a mute of single alerts.
    h.advance(HOUR); h.clock.t = new Date(2026, 9, 20, 9, 5).getTime();
    writeFileSync(join(h.state, 'config/watch-mutes.json'), JSON.stringify({ all: h.clock.t + HOUR, ids: { other_bad: h.clock.t + HOUR } }));
    await W.runOnce(h.deps, { checks, heal: null });
    const alive = h.posts.filter(p => /^Monitoring is alive/.test(p.text)).pop();
    assert.match(alive.text, /Alerts are muted until \S+\. Muted: other_bad\. backup_missing, backup_failed and daily_timer_legacy are never muted: they are posted anyway\./);
    h.clock.t = new Date(2026, 9, 21, 9, 5).getTime();
    writeFileSync(join(h.state, 'config/watch-mutes.json'), JSON.stringify({ all: null, ids: {} }));
    await W.runOnce(h.deps, { checks, heal: null });
    assert.doesNotMatch(h.posts.filter(p => /^Monitoring is alive/.test(p.text)).pop().text, /muted/i, 'nothing muted: no note');
    // Clearing is posted too, even while a mute is active.
    writeFileSync(join(h.state, 'config/watch-mutes.json'), JSON.stringify({ all: h.clock.t + HOUR, ids: {} }));
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    const cleared = h.posts.filter(p => /^\[CLEARED\]/.test(p.text)).pop().text;
    assert.match(cleared, /backup_missing is bad/); assert.doesNotMatch(cleared, /other_bad/);
  } finally { clean(h); }
});

test('a run\'s new alerts go out as one message', async () => {
  const h = harness();
  try {
    const checks = stub(failing('a_bad'), failing('b_bad'), failing('c_bad'));
    await W.runOnce(h.deps, { checks, ...NO_JOBS });
    h.posts.length = 0;
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks, ...NO_JOBS });
    const alerts = h.posts.filter(p => /FIRING/.test(p.text));
    assert.equal(alerts.length, 1);
    assert.match(alerts[0].text, /a_bad[\s\S]*b_bad[\s\S]*c_bad/);
  } finally { clean(h); }
});

test('no secret reaches Slack or the state: passwords, JWTs, database URLs and the webhook are redacted', async () => {
  const h = harness();
  try {
    const jwt = 'eyJhbGciOi.eyJzdWIiOiIx.c2lnbmF0dXJl';
    const detail = `password=supersecretpassword123 token ${jwt} url postgres://admin:hunter2pw@db:5432/x hook ${WEBHOOK}`;
    const checks = stub(failing('leak_bad', { detail }));
    await W.runOnce(h.deps, { checks, ...NO_JOBS });
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks, ...NO_JOBS });
    const text = h.posts.map(p => p.text).join('\n');
    for (const secret of ['supersecretpassword123', jwt, 'hunter2pw', 'abcDEF123456']) assert.ok(!text.includes(secret), secret);
    assert.match(text, /REDACTED/);
    const throwing = [['boom', () => { throw new Error(`connect failed with supersecretpassword123 and ${WEBHOOK}`); }]];
    const r = await W.runChecks(h.ctx(), throwing);
    assert.ok(!JSON.stringify(r.results).includes('supersecretpassword123'));
    assert.ok(!JSON.stringify(r.results).includes('abcDEF123456'));
  } finally { clean(h); }
});

test('a check that throws counts as failing with its error text; the other checks still run; the run does not throw', async () => {
  const h = harness();
  try {
    const checks = [['boom', () => { throw new Error('socket hang up'); }], ['fine', () => [{ check: 'fine', id: 'fine_ok', ok: true, summary: '', detail: '' }]]];
    const r = await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(find(r.results, 'check_error:boom').ok, false);
    assert.equal(find(r.results, 'check_error:boom').detail, 'socket hang up');
    assert.equal(find(r.results, 'fine_ok').ok, true);
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks, ...NO_JOBS });
    const post = h.posts.find(p => /FIRING/.test(p.text));
    assert.match(post.text, /Check "boom" could not run: socket hang up/);
  } finally { clean(h); }
});

test('no webhook: checks run and the state records alerts, nothing is posted, and posts start once a webhook exists', async () => {
  const h = harness({ webhook: false });
  try {
    const checks = stub(failing());
    await W.runOnce(h.deps, { checks, ...NO_JOBS });
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(h.posts.filter(p => /FIRING/.test(p.text)).length, 0);
    assert.ok(h.state_().alerts.thing_bad.firingSince);
    assert.equal(h.state_().lastHeartbeat, null);
    const out = [];
    assert.equal(await W.main(['test-message'], h.deps, t => out.push(t)), 1);
    assert.match(out[0], /No Slack webhook/);
    writeFileSync(join(h.state, 'config/slack-webhook-url'), `${WEBHOOK}\n`, { mode: 0o600 });
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(h.posts.filter(p => /FIRING/.test(p.text)).length, 1);
    assert.equal(h.posts.filter(p => /^Monitoring is alive/.test(p.text)).length, 1);
  } finally { clean(h); }
});

test('while another operator command holds the lock nothing is judged, until it has lasted 2 hours; then operator_lock_stuck fires', async () => {
  const h = harness();
  try {
    h.holdLock();
    let ran = 0;
    const checks = [['stub', () => { ran += 1; return [{ check: 'stub', ...failing() }]; }]];
    let r = await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(r.skipped, 'operator lock is held'); assert.equal(ran, 0);
    const since = h.state_().busySince;
    assert.equal(since, h.clock.t);
    h.advance(2 * HOUR - 1000); r = await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(r.skipped, 'operator lock is held', 'just under 2 hours');
    assert.equal(h.state_().busySince, since, 'the start of the wait is kept');
    h.advance(1000); r = await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(ran, 1, 'at 2 hours the checks run again');
    assert.equal(find(r.results, 'operator_lock_stuck').ok, false);
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.match(h.posts.map(p => p.text).join('\n'), /held the lock for 2 h or more/);
    // Released: busySince resets and the alert clears.
    h.releaseLock(); h.advance(5 * 60000);
    r = await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(h.state_().busySince, null);
    assert.equal(find(r.results, 'operator_lock_stuck').ok, true);
    assert.match(h.posts.map(p => p.text).join('\n'), /\[CLEARED\][\s\S]*held the lock/);
    // A second wait starts counting afresh.
    h.holdLock(); h.advance(5 * 60000); await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(h.state_().busySince, h.clock.t);
  } finally { clean(h); }
});

// Holds a flock on FILE in a process group of its own. --close keeps the lock descriptor out of the command,
// so only the exec'd sleep holds it. `ready` resolves when the lock is taken (the command prints "held"), and
// stop() kills the whole group and resolves once the flock process has exited.
function holdFlock(file) {
  const child = spawn('flock', ['--nonblock', '--close', file, '-c', 'echo held; exec sleep 60'], { stdio: ['ignore', 'pipe', 'ignore'], detached: true });
  const exited = new Promise(done => child.on('exit', done));
  const ready = new Promise((resolve, reject) => {
    child.stdout.once('data', resolve);
    child.once('exit', () => reject(new Error('flock exited before it held the lock')));
  });
  ready.catch(() => {});
  return { ready, stop: async () => { try { process.kill(-child.pid, 'SIGKILL'); } catch { /* already gone */ } await exited; } };
}

test('the lock probe reads /proc/locks and never takes the lock: a real flock is seen, a released one is not', async () => {
  const h = harness();
  try {
    const file = join(h.state, 'config/operator.lock');
    writeFileSync(file, '');
    const ctx = { ...h.ctx(), proc: '/proc' };
    assert.equal(W.lockIsHeld(ctx), false, 'nobody holds it');
    const child = holdFlock(file);
    try {
      await child.ready;
      assert.equal(W.lockIsHeld(ctx), true, 'a running flock is seen');
      // The probe did not take the lock for an instant: the holder still has it, and there is no waiter entry.
      assert.equal(spawnSync('flock', ['-n', file, 'true']).status, 1);
    } finally { await child.stop(); }
    for (let i = 0; i < 50 && W.lockIsHeld(ctx); i++) await new Promise(r => setTimeout(r, 40));
    assert.equal(W.lockIsHeld(ctx), false, 'released');
    assert.ok(!h.calls.some(c => c.startsWith('flock')), 'the probe never runs flock');
  } finally { clean(h); }
});

// While the daily pass holds the lock the host and database checks go on, and the lock is called stuck only after the pass's own 4 hours.
test('while the daily pass holds the lock, run keeps the checks that need no stopped service going, leaves the service checks and self-healing off, and calls the lock stuck after 4 hours, not 2', async () => {
  const h = harness();
  try {
    h.holdLock();
    const seen = [];
    const names = ['cpu', 'memory', 'disk', 'database', 'backups', 'break_glass', 'services', 'api_local', 'pdf_renderer', 'sms_delivery', 'clock'];
    const checks = names.map(name => [name, () => { seen.push(name); return []; }]);
    let healed = 0;
    const heal = () => { healed += 1; return []; };
    h.seed({ dailyRunning: { job: 'daily', startedAt: h.clock.t } });
    let r = await W.runOnce(h.deps, { checks, heal });
    assert.equal(r.skipped, undefined, 'the checker did not stand aside');
    assert.deepEqual(seen, ['cpu', 'memory', 'disk', 'database', 'backups', 'break_glass'], 'only the checks that need none of the stopped services');
    assert.equal(healed, 0, 'no self-heal while a backup stops services on purpose');
    assert.equal(find(r.results, 'operator_lock_stuck').ok, true);
    // 2 h 30 min into the pass: the old 2-hour rule would have cried stuck here.
    seen.length = 0;
    h.advance(2.5 * HOUR); r = await W.runOnce(h.deps, { checks, heal });
    assert.equal(find(r.results, 'operator_lock_stuck').ok, true, 'an ordinary long backup is not a stuck lock');
    assert.equal(seen.includes('services'), false);
    assert.ok(h.state_().dailyRunning, 'the pass stays marked running');
    assert.equal(h.posts.filter(p => /held the lock/.test(p.text)).length, 0);
    h.advance(HOUR + 29 * 60000 + 59000); r = await W.runOnce(h.deps, { checks, heal });   // 3 h 59 min 59 s
    assert.equal(find(r.results, 'operator_lock_stuck').ok, true, 'just under the pass\'s own 4 hours');
    // 4 hours: the pass's own limit (the daily unit stops it) has passed and the lock is still held: stuck, every check runs, no heal.
    seen.length = 0;
    h.advance(1000); r = await W.runOnce(h.deps, { checks, heal });
    assert.equal(find(r.results, 'operator_lock_stuck').ok, false);
    assert.deepEqual(seen, names, 'all checks run once the lock is stuck');
    assert.equal(healed, 0);
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks, heal });
    assert.match(h.posts.map(p => p.text).join('\n'), /held the lock for 4 h or more/);
    // A mark of an old pass does not extend anything: 5 hours old, the lock counts as any other command's (2 hours).
    const g = harness();
    try {
      g.holdLock(); g.seed({ dailyRunning: { job: 'daily', startedAt: g.clock.t - 5 * HOUR } });
      let run = await W.runOnce(g.deps, { checks: HEALTHY, ...NO_JOBS });
      assert.equal(run.skipped, 'operator lock is held');
      g.advance(2 * HOUR); run = await W.runOnce(g.deps, { checks: HEALTHY, ...NO_JOBS });
      assert.equal(find(run.results, 'operator_lock_stuck').ok, false);
    } finally { clean(g); }
    // Another command's lock with no pass running: the checks stand aside, as before.
    const k = harness();
    try {
      k.holdLock(); k.seed();
      assert.equal((await W.runOnce(k.deps, { checks: HEALTHY, ...NO_JOBS })).skipped, 'operator lock is held');
    } finally { clean(k); }
  } finally { clean(h); }
});

test('run is independent of daily: a checker run in the middle of a daily pass runs its checks, and neither undoes the other', async () => {
  const h = harness();
  try {
    h.seed(); dailyFake(h); h.clock.t = at(19, 3, 0);
    let during;
    const seen = [];
    await W.runDailyCommand(h.deps, { checks: HEALTHY, daily: async ctx => {
      h.holdLock();   // watch-daily.sh holds the operator lock for the whole pass
      h.advance(20 * 60000);
      during = await W.runOnce(h.deps, { checks: [['cpu', () => { seen.push('cpu'); return [failing('cpu_high')]; }], ['services', () => { seen.push('services'); return []; }]], heal: null });
      assert.ok(h.state_().dailyRunning, 'the pass is still marked running');
      const result = await W.dailyRunner(ctx);
      h.releaseLock();
      return result;
    } });
    assert.equal(during.skipped, undefined);
    assert.deepEqual(seen, ['cpu'], 'the host check ran during the pass; the service check waited');
    assert.equal(find(during.results, 'cpu_high').ok, false);
    const state = h.state_();
    assert.equal(state.lastDailyRun.backup.result, 'ok', 'the pass finished and recorded its result');
    assert.equal(state.dailyRunning, null);
    assert.equal(state.alerts.cpu_high.failingRuns, 1, 'and kept what the checker wrote meanwhile');
    // The reverse: the checker alone (no daily command at all) never starts or needs a pass.
    assert.equal(h.dailyCalls, 1);
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.equal(h.dailyCalls, 1);
  } finally { clean(h); }
});

// ---------------------------------------------------------------- state file
test('state is written atomically with mode 600 and a failed rename leaves the old file intact', async () => {
  const h = harness();
  try {
    await W.runOnce(h.deps, { checks: [], ...NO_JOBS });
    const path = join(h.state, 'config/watch-state.json');
    assert.equal(statSync(path).mode & 0o777, 0o600);
    assert.deepEqual(readdirSync(join(h.state, 'config')).filter(n => n.includes('.tmp')), []);
    const before = readFileSync(path, 'utf8');
    const api = { openSync: (await import('node:fs')).openSync, writeSync: (await import('node:fs')).writeSync, fsyncSync: (await import('node:fs')).fsyncSync, closeSync: (await import('node:fs')).closeSync,
      unlinkSync: (await import('node:fs')).unlinkSync, renameSync: () => { throw new Error('disk gone'); } };
    assert.throws(() => W.writeFileAtomic(path, '{"half":', api), /disk gone/);
    assert.equal(readFileSync(path, 'utf8'), before);
    assert.deepEqual(readdirSync(join(h.state, 'config')).filter(n => n.includes('.tmp')), [], 'temporary file removed');
    assert.throws(() => W.saveState(h.state, W.freshState(h.clock.t), api), /disk gone/, 'a run cannot continue silently without its state');
  } finally { clean(h); }
});

test('the state file is read, merged and renamed under config/watch-state.lock, which is always released', async () => {
  const h = harness();
  try {
    const lock = join(h.state, 'config/watch-state.lock');
    const during = [];
    const readText = path => { during.push(existsSync(lock) ? readFileSync(lock, 'utf8').trim() : null); return h.deps.readText(path); };
    W.saveState(h.state, W.freshState(h.clock.t), undefined, { readText });
    assert.deepEqual(during, [String(process.pid)], 'the lock names its holder while the file is read');
    assert.equal(existsSync(lock), false, 'released after the rename');
    assert.equal(statSync(join(h.state, 'config/watch-state.json')).mode & 0o777, 0o600);
    // Released after a failure too.
    const api = { openSync: fs.openSync, writeSync: fs.writeSync, fsyncSync: fs.fsyncSync, closeSync: fs.closeSync, unlinkSync: fs.unlinkSync, renameSync: () => { throw new Error('disk gone'); } };
    assert.throws(() => W.saveState(h.state, W.freshState(h.clock.t), api), /disk gone/);
    assert.equal(existsSync(lock), false);
    // The merge still keeps the other process's keys.
    const daily = W.freshState(h.clock.t); daily.dailyAttempt = { date: '2026-10-19', count: 2, lastAt: 5, done: false };
    W.saveState(h.state, daily, undefined, { daily: true });
    const checker = W.freshState(h.clock.t); checker.lastRunAt = 77;
    W.saveState(h.state, checker);
    const merged = h.state_();
    assert.equal(merged.dailyAttempt.count, 2); assert.equal(merged.lastRunAt, 77);
  } finally { clean(h); }
});

test('state lock: a lock left by a process that is gone, or an hour old, is taken over; a live holder is waited for, then the save goes ahead', async () => {
  const h = harness();
  try {
    const lock = join(h.state, 'config/watch-state.lock');
    const dead = spawnSync('true').pid;   // a pid that has just exited
    writeFileSync(lock, `${dead}\n`);
    W.saveState(h.state, W.freshState(h.clock.t));
    assert.equal(existsSync(lock), false, 'a crashed holder\'s lock does not block');
    assert.equal(h.state_().version, 1);
    // A lock older than the stale limit with a pid that is alive (a recycled pid): taken over by age.
    writeFileSync(lock, `${process.pid}\n`);
    const old = new Date(Date.now() - 2 * 60000); utimesSync(lock, old, old);
    W.saveState(h.state, W.freshState(h.clock.t));
    assert.equal(existsSync(lock), false);
    // A live holder that lets go after 300 ms: the save waits for it and then holds the lock itself.
    const holder = spawn('sh', ['-c', `sleep 0.3; rm -f '${lock}'`], { stdio: 'ignore' });
    writeFileSync(lock, `${holder.pid}\n`);
    const started = Date.now();
    const during = [];
    W.saveState(h.state, W.freshState(h.clock.t), undefined, { readText: path => { during.push(readFileSync(lock, 'utf8').trim()); return h.deps.readText(path); } });
    assert.ok(Date.now() - started >= 200, `waited for the holder (${Date.now() - started} ms)`);
    assert.deepEqual(during, [String(process.pid)], 'then took the lock');
    assert.equal(existsSync(lock), false);
    await new Promise(done => holder.on('exit', done));
    // A live holder that never lets go: the save waits its limit and goes ahead without the lock, and leaves the holder's file alone.
    const sleeper = spawn('sleep', ['5'], { stdio: 'ignore' });
    try {
      writeFileSync(lock, `${sleeper.pid}\n`);
      const t0 = Date.now();
      W.saveState(h.state, W.freshState(h.clock.t), undefined, { lock: { waitMs: 150 } });
      assert.ok(Date.now() - t0 >= 100 && Date.now() - t0 < 3000);
      assert.equal(readFileSync(lock, 'utf8').trim(), String(sleeper.pid), 'not removed by a save that did not take it');
      assert.equal(h.state_().version, 1, 'monitoring does not stop because of a lock file');
    } finally { sleeper.kill(); }
    // No lock file can be made (no config directory to hold it): the lock is skipped, the write fails on its own.
    const none = join(h.scratch, 'nowhere'); mkdirSync(none);
    assert.throws(() => W.saveState(none, W.freshState(h.clock.t)), /ENOENT/);
  } finally { clean(h); }
});

test('an unreadable state file starts fresh instead of stopping monitoring', async () => {
  const h = harness();
  try {
    writeFileSync(join(h.state, 'config/watch-state.json'), '{not json');
    await W.runOnce(h.deps, { checks: [], ...NO_JOBS });
    assert.equal(h.state_().version, 1);
  } finally { clean(h); }
});


test('state validation: valid JSON with wrong types resets each bad field and says so', async () => {
  const h = harness();
  try {
    const bad_ = { firstRun: 'x', lastHeartbeat: 'yesterday', cpu: [1], lastDailyRun: 5, busySince: '1', dailyRunning: { job: 'daily' },
      alerts: { a_bad: { summary: 5, failingRuns: 'two', firingSince: 'now' }, b_bad: 'string', c_bad: { firingSince: null } },
      containers: { rest: { restartCount: '3' }, db: { restartCount: 1, startedAt: 'x', events: [1, 2] } } };
    writeFileSync(join(h.state, 'config/watch-state.json'), JSON.stringify(bad_));
    const log = [];
    const data = W.loadState(h.state, h.clock.t, h.deps.readText, m => log.push(m));
    assert.equal(data.firstRun, h.clock.t);
    assert.deepEqual([data.lastHeartbeat, data.cpu, data.busySince, data.dailyRunning], [null, null, null, null]);
    assert.deepEqual(data.lastDailyRun, {});
    assert.deepEqual(Object.keys(data.containers), ['db']);
    assert.equal(data.alerts.a_bad.failingRuns, 0); assert.equal(data.alerts.a_bad.summary, ''); assert.equal(data.alerts.a_bad.firingSince, null);
    assert.equal(data.alerts.b_bad.failingRuns, 0);
    assert.equal(data.alerts.c_bad.failingRuns, 0, 'an alert with no failingRuns gets 0');
    for (const word of ['firstRun', 'lastHeartbeat', 'cpu', 'lastDailyRun', 'busySince', 'dailyRunning', '"a_bad"', '"b_bad"', 'container "rest"']) {
      assert.ok(log.some(m => m.includes(word)), `a log line names ${word}`);
    }
    // A run on such a file counts correctly (no NaN) and writes a clean state.
    const checks = stub(failing('c_bad'));
    h.deps.log = () => {};
    await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(h.state_().alerts.c_bad.failingRuns, 1);
    assert.equal(h.state_().firstRun, h.clock.t);
  } finally { clean(h); }
});

// ---------------------------------------------------------------- Slack delivery
test('Slack answers 500 then 200: nothing is marked sent after the 500, the error is shown, and the next run delivers', async () => {
  const h = harness();
  try {
    const checks = stub(failing());
    await W.runOnce(h.deps, { checks, ...NO_JOBS });
    h.advance(5 * 60000); h.postStatuses = [500];   // the alert post of this run fails
    await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(h.state_().alerts.thing_bad.lastSent, null, 'a 500 is not delivery');
    assert.match(h.state_().lastPostError.message, /Slack answered HTTP 500/);
    const out = [];
    await W.main(['status'], h.deps, t => out.push(t));
    assert.match(out[0], /Last Slack post failed at .*HTTP 500/);
    assert.equal(h.posts.filter(p => /FIRING/.test(p.text)).length, 0);
    h.advance(5 * 60000);
    await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(h.posts.filter(p => /^\[FIRING\]/.test(p.text)).length, 1);
    assert.equal(h.state_().alerts.thing_bad.lastSent, h.clock.t);
    assert.equal(h.state_().lastPostError, null);
  } finally { clean(h); }
});

test('the state is saved before the message is posted (and undone when the post fails)', async () => {
  const h = harness();
  try {
    const seen = [];
    const post = h.deps.post;
    h.deps.post = async (url, text) => { seen.push({ text, saved: h.state_() }); return post(url, text); };
    const checks = stub(failing());
    await W.runOnce(h.deps, { checks, ...NO_JOBS });
    h.advance(5 * 60000);
    await W.runOnce(h.deps, { checks, ...NO_JOBS });
    const alert = seen.find(x => /^\[FIRING\]/.test(x.text));
    assert.equal(alert.saved.alerts.thing_bad.lastSent, h.clock.t, 'lastSent was already on disk when Slack was called');
    const beat = seen.find(x => /^Monitoring is alive/.test(x.text));
    assert.ok(beat.saved.lastHeartbeat !== null);
  } finally { clean(h); }
});

test('a state that cannot be saved is announced at most once an hour, by the minute of the run, and the run fails', async () => {
  const h = harness();
  try {
    h.fsApi = { openSync: fs.openSync, writeSync: fs.writeSync, fsyncSync: fs.fsyncSync, closeSync: fs.closeSync, unlinkSync: fs.unlinkSync, renameSync: () => { throw new Error('read-only file system'); } };
    h.clock.t = new Date(2026, 9, 19, 10, 0).getTime();
    await assert.rejects(W.runOnce(h.deps, { checks: [], ...NO_JOBS }), /read-only file system/);
    assert.equal(h.posts.length, 1);
    assert.match(h.posts[0].text, /^\[WATCH\] cannot save its state: read-only file system/);
    h.clock.t = new Date(2026, 9, 19, 10, 5).getTime();
    await assert.rejects(W.runOnce(h.deps, { checks: [], ...NO_JOBS }), /read-only/);
    h.clock.t = new Date(2026, 9, 19, 10, 35).getTime();
    await assert.rejects(W.runOnce(h.deps, { checks: [], ...NO_JOBS }), /read-only/);
    assert.equal(h.posts.length, 1, 'quiet for the rest of the hour');
    h.clock.t = new Date(2026, 9, 19, 11, 0).getTime();
    await assert.rejects(W.runOnce(h.deps, { checks: [], ...NO_JOBS }), /read-only/);
    assert.equal(h.posts.length, 2);
  } finally { clean(h); }
});

// ---------------------------------------------------------------- daily jobs
const stampOf = ms => `warehouse-${new Date(ms).toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z')}`;
function addBackup(h, name, instanceId = 'iid-1') {
  const dir = join(h.state, 'backups', name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'metadata.txt'), 'format=warehouse-backup-v5\n');
  writeFileSync(join(dir, 'instance.json'), JSON.stringify({ schemaVersion: 1, instanceId }));
  return dir;
}
// Stands for scripts/watch-daily.sh: writes the key=value result file named by its last argument.
function dailyFake(h, spec = {}) {
  h.dailyCalls = 0;
  h.runs['scripts/watch-daily.sh'] = line => {
    h.dailyCalls += 1;
    const s = typeof spec === 'function' ? spec(h.dailyCalls) : spec;
    const file = line.split(' ').pop();
    const backup = s.backup ?? 'ok';
    const fields = { lock: 'acquired', backup, verify: backup === 'ok' ? 'ok' : 'skipped', prune: 'ok', pruned: 0, retention: 'ok', done: '1', ...s };
    if (backup === 'ok' && !('backup_dir' in s)) fields.backup_dir = addBackup(h, stampOf(h.clock.t));
    // As scripts/watch-daily.sh: pruning and retention run after a failed backup or verify too; only the skipped backup
    // (database not healthy) ends the pass before them.
    if (backup === 'skipped') { fields.prune = 'skipped'; fields.retention = 'skipped'; }
    writeFileSync(file, Object.entries(fields).map(([k, v]) => `${k}=${v}`).join('\n') + '\n');
    return { status: s.exit ?? 0, stdout: '', stderr: s.stderr ?? '' };
  };
}
const dailyCalls = h => h.calls.filter(c => /scripts\/watch-daily\.sh/.test(c));
const at = (day, hh, mm = 0) => new Date(2026, 9, day, hh, mm).getTime();
// The daily pass is its own command (the 5-minute checker does not run it): the gate checks are replaced by fakes.
const daily = h => W.runDailyCommand(h.deps, { checks: HEALTHY });

test('daily: nothing before the time or after the 6-hour window; one pass a day inside it', async () => {
  const h = harness({ dailyAt: '02:30' });
  try {
    h.seed(); dailyFake(h);
    h.clock.t = at(19, 2, 29); await daily(h);
    assert.equal(dailyCalls(h).length, 0, 'before 02:30');
    h.clock.t = at(19, 2, 31); await daily(h);
    assert.equal(dailyCalls(h).length, 1);
    assert.match(dailyCalls(h)[0], new RegExp(`bash ${repo.replace(/\/$/, '')}/scripts/watch-daily\\.sh ${h.state}/config/watch-daily\\.result$`));
    h.advance(10 * 60000); await daily(h); h.advance(5 * HOUR); await daily(h);
    assert.equal(dailyCalls(h).length, 1, 'not again the same day');
    const s = h.state_();
    assert.equal(s.lastDailyRun.backup.result, 'ok'); assert.equal(s.lastDailyRun.retention.result, 'ok');
    assert.equal(s.dailyAttempt.done, true); assert.equal(s.dailyRunning, null);
    const status = readFileSync(join(h.state, 'config/watch-backup.last'), 'utf8');
    assert.match(status, /^result=ok$/m); assert.match(status, new RegExp(`^last_success_epoch=${Math.floor(at(19, 2, 31) / 1000)}$`, 'm'));
    assert.equal(h.posts.filter(p => /FAILED/.test(p.text)).length, 0);
    // Next day: a boot at 08:29 is still inside the window (02:30 + 6 h = 08:30); 08:31 is not.
    h.clock.t = at(20, 8, 31); await daily(h);
    assert.equal(dailyCalls(h).length, 1, 'outside the window: wait for tomorrow');
    h.clock.t = at(20, 8, 29); await daily(h);
    assert.equal(dailyCalls(h).length, 2, 'caught up inside the window');
    // A window that ends after midnight belongs to the day it started.
    const late = harness({ dailyAt: '22:00' });
    try {
      late.seed(); dailyFake(late);
      late.clock.t = at(20, 1, 0); await W.runDailyCommand(late.deps, { checks: HEALTHY });
      assert.equal(dailyCalls(late).length, 1);
      assert.equal(late.state_().dailyAttempt.date, '2026-10-19');
    } finally { clean(late); }
  } finally { clean(h); }
});

test('daily: a new state waits for the next window instead of backing up at once', async () => {
  const h = harness();
  try {
    dailyFake(h);
    h.clock.t = at(19, 3, 0); await daily(h);
    assert.equal(dailyCalls(h).length, 0, 'inside a window, but the state was created after it opened');
    h.clock.t = at(20, 2, 35); await daily(h);
    assert.equal(dailyCalls(h).length, 1);
  } finally { clean(h); }
});

test('daily: runs only when the database and every service of this run are up', async () => {
  const h = harness();
  try {
    h.seed(); dailyFake(h);
    h.clock.t = at(19, 3, 0);
    const run = rows => W.runDailyCommand(h.deps, { checks: stub(...rows) });
    await run([{ id: 'postgres_down', ok: false, summary: 'db down', detail: '' }]);
    await run([{ id: 'postgres_down', ok: true, summary: '', detail: '' }, { id: 'service_down:rest', ok: false, summary: 'rest down', detail: '' }]);
    await W.runDailyCommand(h.deps, { checks: [] });
    await W.runDailyCommand(h.deps, { checks: [['services', () => { throw new Error('compose failed'); }], HEALTHY[0]] });
    assert.equal(dailyCalls(h).length, 0);
    assert.equal(h.state_().dailyAttempt?.count ?? 0, 0, 'a skipped pass is not an attempt');
    assert.match(h.state_().dailySkipped.reason, /not up/);
    h.advance(5 * 60000);
    await run([{ id: 'postgres_down', ok: true, summary: '', detail: '' }, { id: 'service_down:rest', ok: true, summary: '', detail: '' }]);
    assert.equal(dailyCalls(h).length, 1);
  } finally { clean(h); }
});

test('daily: a backup that finds the database not healthy, or the lock held, is skipped, not failed, and tried again at the next run', async () => {
  const h = harness();
  try {
    h.seed();
    h.clock.t = at(19, 3, 0);
    dailyFake(h, { backup: 'skipped', backup_message: 'Database service is not healthy.' });
    await daily(h);
    assert.equal(h.dailyCalls, 1);
    let s = h.state_();
    assert.equal(s.dailyAttempt === null || s.dailyAttempt.count === 0, true);
    assert.deepEqual(s.lastDailyRun, {});
    assert.match(s.dailySkipped.reason, /not healthy/);
    assert.equal(existsSync(join(h.state, 'config/watch-backup.last')), false, 'no failure is recorded');
    h.advance(5 * 60000);
    dailyFake(h, { lock: 'held', exit: 75 });
    await daily(h);
    s = h.state_();
    assert.match(s.dailySkipped.reason, /lock is held/);
    assert.deepEqual(s.lastDailyRun, {});
    h.advance(5 * 60000); dailyFake(h);
    await daily(h);
    assert.equal(h.state_().lastDailyRun.backup.result, 'ok', 'the next run backs up');
    assert.equal(h.state_().dailyAttempt.count, 1);
  } finally { clean(h); }
});

test('daily: a failed pass is retried after an hour, at most 3 times a day; the failure is reported only by the backup_failed alert', async () => {
  const h = harness();
  try {
    h.seed(); dailyFake(h, { backup: 'failed', backup_message: 'pg_dump: error: connection refused password=supersecretpassword123' });
    const checks = [HEALTHY[0], ['backups', W.checkBackups]];
    // One trigger of the daily timer, then one run of the checker (which alone reports the failure).
    const pass = async () => { await W.runDailyCommand(h.deps, { checks: HEALTHY }); await W.runOnce(h.deps, { checks, heal: null }); };
    h.clock.t = at(19, 2, 31); await pass();
    assert.equal(h.dailyCalls, 1);
    h.advance(30 * 60000); await pass();
    assert.equal(h.dailyCalls, 1, 'not within an hour');
    h.advance(31 * 60000); await pass();
    assert.equal(h.dailyCalls, 2);
    h.advance(61 * 60000); await pass();
    assert.equal(h.dailyCalls, 3);
    h.advance(61 * 60000); await pass();
    assert.equal(h.dailyCalls, 3, 'no fourth attempt');
    const s = h.state_();
    assert.equal(s.lastDailyRun.backup.result, 'failed');
    assert.match(s.lastDailyRun.backup.message, /attempt 3 of 3/);
    assert.ok(!JSON.stringify(s).includes('supersecretpassword123'));
    // Retention and pruning run after a backup that failed, so a disk that is full of old backups is cleared even then.
    assert.equal(s.lastDailyRun.retention.result, 'ok');
    assert.equal(s.lastDailyRun.retention.message, 'retention applied');
    assert.match(readFileSync(join(h.state, 'config/watch-retention.last'), 'utf8'), /^result=ok$/m, 'retention ran and records its result');
    assert.equal(h.posts.filter(p => /^\[FAILED\]/.test(p.text)).length, 0, 'no separate [FAILED] message');
    const fired = h.posts.filter(p => /^\[FIRING\]/.test(p.text) && /The last backup failed/.test(p.text));
    assert.equal(fired.length, 1, 'the alert path reports it once');
    assert.match(fired[0].text, /The last backup failed: .*pg_dump: error/);
    assert.ok(!fired[0].text.includes('supersecretpassword123'));
    // The next day it tries again.
    dailyFake(h); h.clock.t = at(20, 2, 40); await pass();
    assert.equal(h.state_().lastDailyRun.backup.result, 'ok');
    h.advance(5 * 60000); await pass();
    assert.ok(h.posts.some(p => /^\[CLEARED\]/.test(p.text)));
  } finally { clean(h); }
});

test('daily: a retry that succeeds ends the day', async () => {
  const h = harness();
  try {
    h.seed(); dailyFake(h, n => (n === 1 ? { backup: 'failed', backup_message: 'disk full' } : {}));
    h.clock.t = at(19, 2, 31); await daily(h);
    h.advance(61 * 60000); await daily(h);
    h.advance(61 * 60000); await daily(h);
    assert.equal(h.dailyCalls, 2);
    assert.equal(h.state_().lastDailyRun.backup.result, 'ok');
    assert.match(readFileSync(join(h.state, 'config/watch-backup.last'), 'utf8'), /^result=ok$/m);
  } finally { clean(h); }
});

test('daily: a backup that fails verification is a failure, but pruning and retention still ran; the message names the verified backup that is kept', async () => {
  const h = harness();
  try {
    h.seed(); dailyFake(h, { verify: 'failed', verify_message: 'Backup signature mismatch', pruned: 2, verified_kept: 'warehouse-20261015T020000Z' });
    h.clock.t = at(19, 3, 0); await daily(h);
    const run = h.state_().lastDailyRun;
    assert.equal(run.backup.result, 'failed');
    assert.match(run.backup.message, /^backup warehouse-\d{8}T\d{6}Z was made but verification failed \(the newest verified backup, warehouse-20261015T020000Z, is kept\): Backup signature mismatch \(attempt 1 of 3\)$/);
    // The retention line shows what ran, not "skipped": pruning removed 2 and retention was applied.
    assert.equal(run.retention.result, 'ok');
    assert.equal(run.retention.message, 'retention applied; removed 2 old backups (the newest verified backup, warehouse-20261015T020000Z, is kept)');
    assert.match(readFileSync(join(h.state, 'config/watch-retention.last'), 'utf8'), /^result=ok$/m);
    const out = [];
    await W.main(['status'], h.deps, t => out.push(t));
    assert.match(out[0], /Daily backup: failed on .* - backup \S+ was made but verification failed/);
    assert.match(out[0], /Daily retention: ok on .* - retention applied; removed 2 old backups \(the newest verified backup, warehouse-20261015T020000Z, is kept\)/);
    // No backup has ever been verified: the message says so instead of naming one. One old backup removed reads as singular.
    const none = harness();
    try {
      none.seed(); dailyFake(none, { verify: 'failed', verify_message: 'bad', pruned: 1, verified_kept: '' });
      none.clock.t = at(19, 3, 0); await daily(none);
      assert.match(none.state_().lastDailyRun.backup.message, /verification failed \(no backup is on record as verified yet\): bad \(attempt 1 of 3\)$/);
      assert.equal(none.state_().lastDailyRun.retention.message, 'retention applied; removed 1 old backup (no backup is on record as verified yet)');
    } finally { clean(none); }
    // A long reason from the verify is what the 400-character cut takes, not the note about the kept backup or the attempt counter.
    const long = harness();
    try {
      long.seed(); dailyFake(long, { verify: 'failed', verify_message: 'x'.repeat(400), pruned: 1, verified_kept: 'warehouse-20261015T020000Z' });
      long.clock.t = at(19, 3, 0); await daily(long);
      const text = long.state_().lastDailyRun.backup.message;
      assert.match(text, /^backup warehouse-\d{8}T\d{6}Z was made but verification failed \(the newest verified backup, warehouse-20261015T020000Z, is kept\): x+/);
      assert.match(readFileSync(join(long.state, 'config/watch-backup.last'), 'utf8'), /^message=backup warehouse-\d{8}T\d{6}Z was made but verification failed \(the newest verified backup, warehouse-20261015T020000Z, is kept\): x+/m);
    } finally { clean(long); }
    // What pruning has to say (the backup of an interrupted upgrade that it kept, say) is on the retention line when the backup failed.
    const note = harness();
    try {
      note.seed(); dailyFake(note, { backup: 'failed', backup_message: 'Refusing: not enough free space in /x: ...', pruned: 0, prune_message: 'kept warehouse-20261001T020000Z, the backup of the interrupted upgrade (config/upgrade-in-progress)' });
      note.clock.t = at(19, 3, 0); await daily(note);
      assert.equal(note.state_().lastDailyRun.retention.message, 'retention applied; kept warehouse-20261001T020000Z, the backup of the interrupted upgrade (config/upgrade-in-progress)');
    } finally { clean(note); }
    // Pruning that fails after a failed verify is still reported as a retention failure.
    const broke = harness();
    try {
      broke.seed(); dailyFake(broke, { verify: 'failed', verify_message: 'bad', prune: 'failed', prune_message: 'permission denied' });
      broke.clock.t = at(19, 3, 0); await daily(broke);
      assert.equal(broke.state_().lastDailyRun.retention.result, 'failed');
      assert.match(broke.state_().lastDailyRun.retention.message, /removing old backups failed: permission denied/);
    } finally { clean(broke); }
  } finally { clean(h); }
});

test('daily: retention and pruning failures are retention failures; the backup still counts as done', async () => {
  const h = harness();
  try {
    h.seed(); dailyFake(h, { retention: 'failed', retention_message: 'retention broke' });
    h.clock.t = at(19, 3, 0); await daily(h);
    assert.equal(h.state_().lastDailyRun.backup.result, 'ok');
    assert.equal(h.state_().dailyAttempt.done, true);
    assert.equal(find(W.checkBackups(h.ctx()), 'retention_failed').ok, false);
    assert.match(find(W.checkBackups(h.ctx()), 'retention_failed').detail, /retention broke/);
    h.dailyCalls = 0;
    const h2 = harness();
    try {
      h2.seed(); dailyFake(h2, { prune: 'failed', prune_message: 'permission denied' });
      h2.clock.t = at(19, 3, 0); await daily(h2);
      assert.match(h2.state_().lastDailyRun.retention.message, /removing old backups failed: permission denied/);
      assert.equal(find(W.checkBackups(h2.ctx()), 'retention_failed').ok, false);
    } finally { clean(h2); }
  } finally { clean(h); }
});

test('daily: a backup that re-copied files from a damaged earlier copy stays ok, and the warning is in the daily state and the status line', async () => {
  const h = harness();
  try {
    h.seed();
    const warning = '2 files re-copied: backup warehouse-20261018T022000Z has a damaged copy';
    dailyFake(h, { backup_warning: warning });
    h.clock.t = at(19, 3, 0); await daily(h);
    const last = h.state_().lastDailyRun.backup;
    assert.equal(last.result, 'ok', 'the daily pass is ok');
    assert.match(last.message, /^backup warehouse-\d{8}T\d{6}Z verified; 2 files re-copied: backup warehouse-20261018T022000Z has a damaged copy$/);
    assert.equal(h.state_().dailyAttempt.done, true);
    assert.match(readFileSync(join(h.state, 'config/watch-backup.last'), 'utf8'), /^result=ok$/m);
    assert.match(readFileSync(join(h.state, 'config/watch-backup.last'), 'utf8'), /^message=backup .* verified; 2 files re-copied: backup warehouse-20261018T022000Z has a damaged copy$/m);
    const out = [];
    await W.main(['status'], h.deps, t => out.push(t));
    assert.match(out[0], /Daily backup: ok on .* - backup warehouse-\d{8}T\d{6}Z verified; 2 files re-copied: backup warehouse-20261018T022000Z has a damaged copy/);
    assert.equal(h.posts.filter(p => /FAILED|FIRING/.test(p.text)).length, 0, 'no failure alert');
    // Without a warning the message is as before.
    const quiet = harness();
    try {
      quiet.seed(); dailyFake(quiet);
      quiet.clock.t = at(19, 3, 0); await daily(quiet);
      assert.match(quiet.state_().lastDailyRun.backup.message, /^backup warehouse-\d{8}T\d{6}Z verified$/);
    } finally { clean(quiet); }
    // And the warning is not shown for a backup that failed verification (the message is about the failure then).
    const failed = harness();
    try {
      failed.seed(); dailyFake(failed, { backup_warning: warning, verify: 'failed', verify_message: 'bad' });
      failed.clock.t = at(19, 3, 0); await daily(failed);
      assert.doesNotMatch(failed.state_().lastDailyRun.backup.message, /re-copied/);
      assert.equal(failed.state_().lastDailyRun.backup.result, 'failed');
    } finally { clean(failed); }
  } finally { clean(h); }
});

test('daily: the backup location guard, a cut-short pass and a timeout', async () => {
  const h = harness();
  try {
    const ctx = h.ctx();
    const ran = { status: 0, stdout: '', stderr: '' };
    const good = join(h.state, 'backups/warehouse-20261019T020000Z');
    assert.equal(W.interpretDaily(ctx, ran, { done: '1', backup: 'ok', backup_dir: good, verify: 'ok' }).backup.result, 'ok');
    for (const dir of [join(h.scratch, 'elsewhere/warehouse-20261019T020000Z'), join(h.state, 'backups/manual-copy'), join(h.state, 'backups/sub/warehouse-20261019T020000Z'), '', undefined]) {
      const r = W.interpretDaily(ctx, ran, { done: '1', backup: 'ok', backup_dir: dir, verify: 'ok' });
      assert.equal(r.backup.result, 'failed', String(dir));
      assert.match(r.backup.message, /location could not be read/);
    }
    const cut = W.interpretDaily(ctx, { status: 143, stdout: '', stderr: 'Terminated' }, { lock: 'acquired', backup: 'ok' });
    assert.equal(cut.backup.result, 'failed'); assert.match(cut.backup.message, /did not finish: Terminated/);
    assert.deepEqual(cut.retention, { result: 'skipped', message: 'retention not run: the daily run did not finish' }, 'cut short before retention: no claim about the backup');
    // Cut short after retention ran: what the file says is kept.
    assert.deepEqual(W.interpretDaily(ctx, { status: 143, stdout: '', stderr: '' }, { lock: 'acquired', backup: 'ok', retention: 'ok' }).retention, { result: 'ok', message: '' });
    // A failed backup and a failed verify keep their pruning and retention results; the verified backup that is kept is passed on.
    const failedBackup = W.interpretDaily(ctx, ran, { done: '1', backup: 'failed', backup_message: 'Refusing: not enough free space', verify: 'skipped', prune: 'ok', pruned: '3', verified_kept: 'warehouse-20261015T020000Z', retention: 'ok' });
    assert.deepEqual([failedBackup.backup.result, failedBackup.prune.result, failedBackup.prune.pruned, failedBackup.prune.verifiedKept, failedBackup.retention.result], ['failed', 'ok', 3, 'warehouse-20261015T020000Z', 'ok']);
    assert.equal(W.interpretDaily(ctx, ran, { done: '1', backup: 'ok', backup_dir: good, verify: 'failed', prune: 'ok', retention: 'ok' }).prune.verifiedKept, '', 'none on record');
    const timed = W.interpretDaily(ctx, { status: 143, stdout: '', stderr: '', timedOut: true }, {});
    assert.match(timed.backup.message, /timed out/);
    assert.equal(W.interpretDaily(ctx, { status: 75, stdout: '', stderr: '' }, { lock: 'held', done: '1' }).skipped, 'operator lock is held');
    // And through a whole run: a crash of the runner is a failure, and dailyRunning is cleared.
    h.seed(); h.clock.t = at(19, 3, 0);
    await W.runDailyCommand(h.deps, { checks: HEALTHY, daily: async () => { throw new Error('spawn exploded'); } });
    assert.match(h.state_().lastDailyRun.backup.message, /the daily run crashed: spawn exploded/);
    assert.equal(h.state_().lastDailyRun.retention.message, 'retention not run: the daily run crashed');
    assert.equal(h.state_().dailyRunning, null);
  } finally { clean(h); }
});

test('daily: a pass marked running while nothing holds the lock was cut off and is cleared at once; while the lock is held a young mark blocks, and a mark of 4 hours or more is stale', async () => {
  const h = harness();
  try {
    h.clock.t = at(19, 6, 0);
    dailyFake(h);
    // A power cut at 02:35 killed the pass; the host is back and the lock is free: the next trigger makes the backup, not 4 hours later.
    h.seed({ dailyRunning: { job: 'daily', startedAt: at(19, 6, 0) - 5 * 60000 } });
    await daily(h);
    assert.equal(h.dailyCalls, 1, 'cut off: cleared and run');
    assert.equal(h.state_().dailyRunning, null);
    // The lock is held (something is really running): a mark younger than 4 hours blocks.
    h.dailyCalls = 0; h.holdLock();
    h.seed({ dailyRunning: { job: 'daily', startedAt: at(19, 6, 0) - (4 * HOUR - 1000) } });
    await daily(h);
    assert.equal(h.dailyCalls, 0, 'still inside 4 hours and the lock is held: assumed running');
    assert.ok(h.state_().dailyRunning, 'the mark is kept');
    h.seed({ dailyRunning: { job: 'daily', startedAt: at(19, 6, 0) - 4 * HOUR } });
    await daily(h);
    assert.equal(h.dailyCalls, 1, '4 hours or more: stale, cleared, run');
    assert.equal(h.state_().dailyRunning, null);
    h.seed({ dailyRunning: { job: 'daily', startedAt: at(19, 6, 0) + 3 * HOUR } });
    h.clock.t = at(19, 6, 30); await W.runDailyCommand(h.deps, { checks: HEALTHY });
    assert.equal(h.state_().dailyRunning, null, 'a start time in the future is stale');
    // Status says what it is.
    h.releaseLock();
    h.seed({ dailyRunning: { job: 'daily', startedAt: h.clock.t - 90 * 60000 } });
    const out = []; await W.main(['status'], h.deps, t => out.push(t));
    assert.match(out[0], /Daily pass: running since \S+ \(it may take up to 4 hours; systemctl is-active <project>-daily\.service/);
    h.seed({ dailyRunning: { job: 'daily', startedAt: h.clock.t - 5 * HOUR } });
    out.length = 0; await W.main(['status'], h.deps, t => out.push(t));
    assert.match(out[0], /Daily pass: marked running since \S+ but cut short/);
  } finally { clean(h); }
});

test('daily: the 5-minute run never starts the backup; the daily command does, behind the real gate checks', async () => {
  const h = harness();
  try {
    h.seed(); dailyFake(h);
    h.clock.t = at(19, 3, 0);
    await W.runOnce(h.deps, { checks: HEALTHY });
    await W.main(['run'], h.deps);
    assert.equal(dailyCalls(h).length, 0, 'in the window, healthy, and still no backup from run');
    // The command goes through the same database and service checks as the checker.
    h.stateOf = { storage: 'exited|' };
    assert.equal(await W.main(['daily'], h.deps), 0);
    assert.equal(dailyCalls(h).length, 0, 'a service the backup stops is down: skipped');
    assert.match(h.state_().dailySkipped.reason, /not up/);
    assert.ok(h.calls.some(c => c.includes('pg_isready')) && h.calls.some(c => c.includes('compose.sh config --services')));
    h.stateOf = {}; h.advance(60 * 1000);
    assert.equal(await W.main(['daily'], h.deps), 0);
    assert.equal(dailyCalls(h).length, 1);
    assert.equal(h.state_().lastDailyRun.backup.result, 'ok');
    assert.equal(await W.main(['daily'], h.deps), 0);
    assert.equal(dailyCalls(h).length, 1, 'a trigger after a finished day does nothing');
    const out = [];
    await W.main(['--help'], { now: () => 0 }, t => out.push(t));
    assert.match(out[0], /^Usage: node scripts\/watch\.mjs run \| daily \|/);
    assert.match(out[0], /daily {9}the daily backup, verification, pruning and retention/);
  } finally { clean(h); }
});

// An installation updated from before the daily timer has a checker unit that sets WAREHOUSE_WATCH_DAILY_AT: its run must go on making the backup.
const OLD_UNIT_ENV = { WAREHOUSE_WATCH_DAILY_AT: '02:30' };
test('an old checker unit (WAREHOUSE_WATCH_DAILY_AT in its environment) still makes the daily backup inside run and raises daily_timer_legacy at once, naming the command; a unit without it does neither', async () => {
  const h = harness();
  try {
    h.seed(); dailyFake(h); h.clock.t = at(19, 3, 0);
    const command = `sudo bash ${repo.replace(/\/$/, '')}/scripts/watch-timer.sh install --state ${h.state}`;
    // The unit written now: no variable, no backup from run.
    await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.equal(dailyCalls(h).length, 0, 'a run without the variable never makes a backup');
    assert.equal(h.state_().alerts.daily_timer_legacy, undefined);
    assert.equal(h.posts.filter(p => /FIRING/.test(p.text)).length, 0);
    // The old unit.
    h.deps.env = OLD_UNIT_ENV;
    h.advance(5 * 60000);
    const r = await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.equal(dailyCalls(h).length, 1, 'the backup is made inside run, as that unit always did');
    assert.equal(h.state_().lastDailyRun.backup.result, 'ok'); assert.equal(h.state_().dailyAttempt.done, true);
    assert.equal(h.state_().dailyRunning, null);
    assert.ok(statSync(join(h.state, 'backups', readdirSync(join(h.state, 'backups'))[0], 'metadata.txt')).isFile());
    const legacy = find(r.results, 'daily_timer_legacy');
    assert.equal(legacy.ok, false); assert.equal(legacy.immediate, true);
    const fired = h.posts.filter(p => /^\[FIRING\]/.test(p.text));
    assert.equal(fired.length, 1, 'told in the first run, not after two or after 26 hours');
    assert.ok(fired[0].text.includes('The daily backup still runs from the old checker unit'));
    assert.ok(fired[0].text.includes(`Run: ${command}`), `the exact command is in the message: ${fired[0].text}`);
    // The checks come first and the alert and the state are saved before the pass: the pass runs after the post.
    assert.ok(h.state_().alerts.daily_timer_legacy.lastSent, 'the alert was posted and recorded');
    // The next run in the window does not repeat the pass (done today), and the alert is not repeated within 4 hours.
    h.advance(5 * 60000); await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.equal(dailyCalls(h).length, 1);
    assert.equal(h.posts.filter(p => /daily_timer_legacy|old checker unit/.test(p.text)).length, 1);
    // status says the same, from the state.
    const out = []; await W.main(['status'], h.deps, t => out.push(t));
    assert.ok(out[0].includes(`Daily backup: still run by the old checker unit, inside the 5-minute check. Run: ${command}`));
    assert.match(out[0], /Firing: daily_timer_legacy/);
    // A mute of everything does not hide it: a facility that cannot run sudo is told until it is fixed.
    await W.main(['mute', '600'], h.deps, () => {});
    h.advance(4 * HOUR + 60000); await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.equal(h.posts.filter(p => /^\[STILL FIRING\]/.test(p.text) && /old checker unit/.test(p.text)).length, 1, 'repeated while muted');
    // Reinstalled: the variable is gone, the alert clears, and the pass is no longer run from here.
    h.deps.env = {};
    h.advance(24 * HOUR); dailyFake(h);
    await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.equal(h.dailyCalls, 0, 'the next day, inside the window, run makes no backup any more');
    assert.equal(h.state_().alerts.daily_timer_legacy, undefined);
    assert.ok(h.posts.some(p => /^\[CLEARED\]/.test(p.text) && /old checker unit/.test(p.text)));
  } finally { clean(h); }
});

test('an old checker unit: a failed backup inside run is retried like any, the gate still applies, and the lock held by something else skips the pass', async () => {
  const h = harness();
  try {
    h.deps.env = OLD_UNIT_ENV;
    h.seed(); dailyFake(h, n => (n === 1 ? { backup: 'failed', backup_message: 'disk full' } : {})); h.clock.t = at(19, 2, 31);
    const gated = [{ check: 'stub', id: 'postgres_down', ok: false, summary: 'down', detail: '' }];
    await W.runOnce(h.deps, { checks: [['stub', () => gated]], heal: null });
    assert.equal(dailyCalls(h).length, 0, 'the database is down: no pass');
    await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.equal(dailyCalls(h).length, 1);
    h.advance(61 * 60000); await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.equal(dailyCalls(h).length, 2);
    assert.equal(h.state_().lastDailyRun.backup.result, 'ok');
    assert.equal(h.state_().dailyAttempt.count, 2);
  } finally { clean(h); }
});

test('daily: the checker and the daily pass write different keys of the state file, so neither undoes the other', async () => {
  const h = harness();
  try {
    h.seed(); dailyFake(h); h.clock.t = at(19, 3, 0);
    // A checker run happens while the daily pass is in progress: its alert and its time must survive the pass's last save.
    await W.runDailyCommand(h.deps, { checks: HEALTHY, daily: async ctx => {
      assert.ok(h.state_().dailyRunning, 'the start of the pass is on disk');
      h.advance(60 * 1000);
      await W.runOnce(h.deps, { checks: stub(failing('during_backup')), heal: null });
      const mid = h.state_();
      assert.ok(mid.dailyRunning, 'the checker keeps the pass marked as running');
      assert.equal(mid.alerts.during_backup.failingRuns, 1);
      return W.dailyRunner(ctx);
    } });
    let state = h.state_();
    assert.equal(state.lastDailyRun.backup.result, 'ok');
    assert.equal(state.dailyRunning, null);
    assert.equal(state.alerts.during_backup.failingRuns, 1, 'the checker\'s alert is still there');
    assert.equal(state.lastRunAt, at(19, 3, 1));
    // The other way round: a daily pass records its result while a checker run is between its load and its saves.
    h.clock.t = at(20, 3, 0);
    const slow = ['slow', async () => { await W.runDailyCommand(h.deps, { checks: HEALTHY, daily: async () => ({ skipped: 'the lock is held' }) }); return []; }];
    await W.runOnce(h.deps, { checks: [slow], heal: null });
    state = h.state_();
    assert.match(state.dailySkipped.reason, /lock is held/, 'the checker\'s final save keeps the daily keys it finds on disk');
    assert.equal(state.lastDailyRun.backup.result, 'ok', 'and yesterday\'s result');
    assert.equal(state.lastRunAt, at(20, 3, 0));
  } finally { clean(h); }
});

test('daily gate: the database and the four services the backup stops; not the renderer, not optional services', async () => {
  const row = (id, ok = true) => ({ id, ok, summary: '', detail: '' });
  const pg = row('postgres_down');
  assert.equal(W.dailyHealthy([pg, row('service_down:gateway'), row('service_down:pdf-renderer', false)]), true, 'an unhealthy renderer does not stop the backup');
  for (const optional of ['supavisor', 'cups', 'sensor-bridge']) assert.equal(W.dailyHealthy([pg, row(`service_down:${optional}`, false)]), true, `${optional} stopped (not running) does not stop the backup`);
  // The pooler is stopped and restarted (with --wait) by the backup while it runs: one that runs but is unhealthy would make the backup fail.
  assert.equal(W.dailyHealthy([pg, { ...row('service_down:supavisor', false), running: true }]), false, 'a running, unhealthy pooler holds the pass back');
  assert.equal(W.dailyHealthy([pg, { ...row('service_down:supavisor', true), running: true }]), true);
  for (const optional of ['cups', 'sensor-bridge']) assert.equal(W.dailyHealthy([pg, { ...row(`service_down:${optional}`, false), running: true }]), true, `${optional} never matters`);
  assert.deepEqual(W.BACKUP_OPTIONAL_SERVICES, ['supavisor']);
  assert.deepEqual(W.BACKUP_SERVICES, ['gateway', 'functions', 'rest', 'storage']);
  for (const name of W.BACKUP_SERVICES) assert.equal(W.dailyHealthy([pg, row(`service_down:${name}`, false)]), false, name);
  assert.equal(W.dailyHealthy([pg, row('service_down:db', false)]), true, 'db is judged through postgres_down');
  assert.equal(W.dailyHealthy([row('postgres_down', false)]), false);
  assert.equal(W.dailyHealthy([]), false, 'no database result: not healthy');
  assert.equal(W.dailyHealthy([pg, row('check_error:services', false)]), false, 'a services check that could not run');
  assert.equal(W.dailyHealthy([pg, row('check_error:database', false)]), false);
  assert.equal(W.dailyHealthy([pg, row('check_error:pdf_renderer', false)]), true);
  // Through the real checks: an unhealthy renderer and a stopped optional service do not hold the pass back; a stopped storage does.
  const h = harness();
  try {
    h.seed(); dailyFake(h); h.clock.t = at(19, 3, 0);
    h.services = [...SERVICES, 'cups'];
    h.stateOf = { 'pdf-renderer': 'running|unhealthy', cups: 'exited|' };
    await W.main(['daily'], h.deps);
    assert.equal(dailyCalls(h).length, 1, 'the backup ran');
    assert.equal(h.state_().lastDailyRun.backup.result, 'ok');
    const g = harness();
    try {
      g.seed(); dailyFake(g); g.clock.t = at(19, 3, 0);
      g.stateOf = { storage: 'running|unhealthy' };
      await W.main(['daily'], g.deps);
      assert.equal(dailyCalls(g).length, 0);
      assert.match(g.state_().dailySkipped.reason, /not up/);
    } finally { clean(g); }
    // The pooler: stopped on purpose (exited) is left alone by the backup, so the pass runs; running and unhealthy is not.
    const p = harness();
    try {
      p.seed(); dailyFake(p); p.clock.t = at(19, 3, 0);
      p.services = [...SERVICES, 'supavisor']; p.stateOf = { supavisor: 'exited|' };
      await W.main(['daily'], p.deps);
      assert.equal(dailyCalls(p).length, 1, 'a pooler that was stopped on purpose does not hold the backup back');
      const q = harness();
      try {
        q.seed(); dailyFake(q); q.clock.t = at(19, 3, 0);
        q.services = [...SERVICES, 'supavisor']; q.stateOf = { supavisor: 'running|unhealthy' };
        await W.main(['daily'], q.deps);
        assert.equal(dailyCalls(q).length, 0, 'an unhealthy running pooler would make the backup fail when it restarts it');
        assert.match(q.state_().dailySkipped.reason, /not up/);
      } finally { clean(q); }
    } finally { clean(p); }
  } finally { clean(h); }
});

test('daily: a start a few seconds early on the hourly trigger still counts as an hour after the last attempt', async () => {
  const h = harness();
  try {
    h.seed(); dailyFake(h, n => (n === 1 ? { backup: 'failed', backup_message: 'disk full' } : {}));
    h.clock.t = at(19, 2, 30); await daily(h);
    h.clock.t = at(19, 3, 29) + 59 * 1000 + 800; await daily(h);   // 59 min 59.8 s later
    assert.equal(h.dailyCalls, 2, 'the next hourly trigger retries');
    assert.equal(h.state_().lastDailyRun.backup.result, 'ok');
    const early = harness();
    try {
      early.seed(); dailyFake(early, { backup: 'failed', backup_message: 'disk full' });
      early.clock.t = at(19, 2, 30); await daily(early);
      early.clock.t = at(19, 3, 20); await daily(early);
      assert.equal(early.dailyCalls, 1, '50 minutes is too early');
    } finally { clean(early); }
  } finally { clean(h); }
});

// ---------------------------------------------------------------- external heartbeat
const HB_URL = 'https://hc-ping.example.test/3f1c2d4e-0000-4000-8000-123456789abc';
function heartbeatFile(h, text = `${HB_URL}\n`, mode = 0o600) {
  const file = join(h.state, 'config/heartbeat-url');
  writeFileSync(file, text, { mode }); chmodSync(file, mode);
}
function heartbeatSpy(h, answer = { ok: true, status: 200 }) {
  const seen = []; h.logs = [];
  h.deps.log = m => h.logs.push(m);
  h.deps.fetch = async (url, options) => { seen.push({ url, options }); if (answer instanceof Error) throw answer; return typeof answer === 'function' ? answer(options) : answer; };
  return seen;
}
test('external heartbeat: a GET with a 5 s limit at the end of each successful run, only when config/heartbeat-url exists', async () => {
  const h = harness();
  try {
    const seen = heartbeatSpy(h);
    await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.equal(seen.length, 0, 'no file, no ping');
    heartbeatFile(h);
    await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.equal(seen.length, 1);
    assert.equal(seen[0].url, HB_URL);
    assert.equal(seen[0].options.method, undefined, 'a GET');
    assert.ok(seen[0].options.signal instanceof AbortSignal && seen[0].options.signal.aborted === false);
    assert.equal(W.HEARTBEAT_TIMEOUT_MS, 5000);
    // It is the last thing a run does: the state is saved first, and the Slack posts are made.
    let order = '';
    h.deps.fetch = async () => { order = existsSync(join(h.state, 'config/watch-state.json')) ? 'state-first' : 'ping-first'; return { ok: true, status: 200 }; };
    await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.equal(order, 'state-first');
    // While another operator command holds the lock the checker is still alive: it pings.
    const again = heartbeatSpy(h);
    h.holdLock();
    await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.equal(again.length, 1);
    h.releaseLock();
    // The daily command and the other commands do not ping.
    await W.main(['daily'], h.deps); await W.main(['status'], h.deps, () => {});
    assert.equal(again.length, 1);
    const out = []; await W.main(['status'], h.deps, t => out.push(t));
    assert.match(out[0], /External heartbeat: configured/); assert.ok(!out[0].includes('hc-ping'));
  } finally { clean(h); }
});

test('external heartbeat: a failed, refused or hung ping is logged without the URL, never alerted, and does not fail the run', async () => {
  const h = harness();
  try {
    heartbeatFile(h);
    heartbeatSpy(h, new Error(`connect ECONNREFUSED ${HB_URL}`));
    const result = await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.ok(result.results);
    assert.match(h.logs.join('\n'), /external heartbeat ping failed: connect ECONNREFUSED \[REDACTED\]/);
    assert.ok(!h.logs.join('\n').includes('3f1c2d4e'));
    heartbeatSpy(h, { ok: false, status: 502 });
    await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.match(h.logs.join('\n'), /ping failed: HTTP 502/);
    // A hung server: the 5 s limit (shortened here) ends the wait.
    // (AbortSignal.timeout does not keep the process alive; a real socket does. The test keeps it alive itself.)
    heartbeatSpy(h, options => new Promise((_, reject) => {
      const keep = setTimeout(() => {}, 5000);
      options.signal.addEventListener('abort', () => { clearTimeout(keep); reject(new Error('The operation was aborted due to timeout')); });
    }));
    h.deps.heartbeatTimeoutMs = 40;
    const started = Date.now();
    await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.ok(Date.now() - started < 3000);
    assert.match(h.logs.join('\n'), /ping failed: The operation was aborted due to timeout/);
    // Nothing reached Slack or the state: the dead-man switch is what tells the operator.
    assert.deepEqual(h.posts.filter(p => /heartbeat|ping/i.test(p.text) && !/alive/.test(p.text)), []);
    assert.ok(!JSON.stringify(h.state_()).includes('hc-ping'));
    assert.deepEqual(Object.keys(h.state_().alerts), []);
  } finally { clean(h); }
});

test('external heartbeat: the file must be a private https URL; a run that cannot save its state does not ping', async () => {
  const h = harness();
  try {
    const seen = heartbeatSpy(h);
    heartbeatFile(h, `${HB_URL}\n`, 0o644);
    await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.match(h.logs.join('\n'), /external heartbeat not sent: config\/heartbeat-url must be a regular file owned by the installation user with mode 0600/);
    heartbeatFile(h, 'http://insecure.example.test/ping\n');
    await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.match(h.logs.join('\n'), /must hold one https URL/);
    heartbeatFile(h, '\n');
    await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.equal(seen.length, 0);
    const out = []; await W.main(['status'], h.deps, t => out.push(t));
    assert.match(out[0], /External heartbeat: not sent \(config\/heartbeat-url must hold one https URL\)/);
    heartbeatFile(h, `\n# the dead-man switch\n${HB_URL}\n`);
    h.fsApi = { openSync: () => { throw new Error('read-only file system'); }, writeSync() {}, fsyncSync() {}, closeSync() {}, renameSync() {}, unlinkSync() {} };
    await assert.rejects(W.runOnce(h.deps, { checks: HEALTHY, heal: null }), /read-only/);
    assert.equal(seen.length, 0, 'the run failed: no ping, so the dead-man switch fires');
    h.fsApi = undefined;
    await W.runOnce(h.deps, { checks: HEALTHY, heal: null });
    assert.equal(seen.length, 1);
    assert.equal(seen[0].url, HB_URL, 'blank lines and # comments are skipped');
  } finally { clean(h); }
});

test('runGroup ends the whole process group on a timeout', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-watch-group-'));
  try {
    const pidFile = join(dir, 'child.pid');
    const started = Date.now();
    const r = await W.runGroup('bash', ['-c', `sleep 30 & echo $! > "${pidFile}"; wait`], { timeoutMs: 300, killGraceMs: 500 });
    assert.equal(r.timedOut, true);
    assert.ok(Date.now() - started < 10000);
    const pid = Number(readFileSync(pidFile, 'utf8'));
    let alive = true;
    for (let i = 0; i < 40 && alive; i++) { try { process.kill(pid, 0); await new Promise(res => setTimeout(res, 50)); } catch { alive = false; } }
    assert.equal(alive, false, 'the grandchild is gone too');
    const quick = await W.runGroup('bash', ['-c', 'echo out; echo err >&2; exit 3'], { timeoutMs: 5000 });
    assert.deepEqual([quick.status, quick.stdout.trim(), quick.stderr.trim(), quick.timedOut], [3, 'out', 'err', false]);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

// ---------------------------------------------------------------- scripts/watch-daily.sh
function dailyScriptFixture() {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-watch-daily-'));
  const root = join(scratch, 'checkout');
  cpSync(join(repo, 'scripts'), join(root, 'scripts'), { recursive: true });
  const state = join(scratch, 'state');
  for (const dir of ['config', 'public', 'backups']) mkdirSync(join(state, dir), { recursive: true });
  writeFileSync(join(state, 'config/compose.env'), 'WAREHOUSE_PROJECT_NAME=warehouse-test\n', { mode: 0o600 });
  writeFileSync(join(state, 'public/instance.json'), JSON.stringify({ instanceId: 'iid-1' }));
  const log = join(scratch, 'order.log'); writeFileSync(log, '');
  const stubs = {
    'backup.sh': `echo "backup $*" >> "$LOG"
lock="$WAREHOUSE_STATE_DIR/config/operator.lock"
[[ /proc/$$/fd/9 -ef "$lock" ]] && echo "backup-inherits-lock" >> "$LOG"
flock -n "$lock" true && echo "backup-LOCK-FREE" >> "$LOG"
case "\${FAKE_BACKUP:-ok}" in
  ok) d="$WAREHOUSE_STATE_DIR/backups/warehouse-20261019T020000Z"; mkdir -p "$d"; echo x > "$d/metadata.txt"; cp "$WAREHOUSE_STATE_DIR/public/instance.json" "$d/"; echo "Backup created at $d" ;;
  unhealthy) echo 'Database service is not healthy.' >&2; exit 1 ;;
  fail) echo 'pg_dump: error: boom' >&2; exit 1 ;;
  warn|warn1|other-warning|space-warn|both-warn)
    d="$WAREHOUSE_STATE_DIR/backups/warehouse-20261019T020000Z"; mkdir -p "$d"; echo x > "$d/metadata.txt"; cp "$WAREHOUSE_STATE_DIR/public/instance.json" "$d/"; echo "Backup created at $d"
    case "$FAKE_BACKUP" in
      warn) echo 'WARNING: 2 files re-copied: backup warehouse-20261018T020000Z has a damaged copy. This backup holds good copies.' >&2 ;;
      warn1) echo 'WARNING: 1 file re-copied: backup warehouse-20261018T020000Z has a damaged copy. This backup holds good copies.' >&2 ;;
      other-warning) echo 'WARNING: something else entirely' >&2; echo 'WARNING: 3 files re-copied: backup not-a-backup has a damaged copy.' >&2 ;;
      space-warn) echo 'WARNING: df gave no free space for /srv/state/backups, so stat -f was used for the free-space check; find out why df fails there (docs/TROUBLESHOOTING.md, "backup refused: not enough free space").' >&2 ;;
      both-warn) echo 'WARNING: df gave no free space for /srv/state/backups, so stat -f was used for the free-space check; find out why df fails there (docs/TROUBLESHOOTING.md, "backup refused: not enough free space").' >&2
        echo 'WARNING: 2 files re-copied: backup warehouse-20261018T020000Z has a damaged copy. This backup holds good copies.' >&2 ;;
    esac ;;
  hang) sleep 30 ;;
esac`,
    'verify-restore.sh': `echo "verify $1" >> "$LOG"
lock="$WAREHOUSE_STATE_DIR/config/operator.lock"
flock -n "$lock" true && echo "verify-LOCK-FREE" >> "$LOG"
[[ "\${FAKE_VERIFY:-ok}" == ok ]] || { echo 'Backup signature mismatch' >&2; exit 1; }`,
    'retention.sh': `echo "retention $*" >> "$LOG"
[[ /proc/$$/fd/9 -ef "$WAREHOUSE_STATE_DIR/config/operator.lock" ]] && echo "retention-inherits-lock" >> "$LOG"
[[ "\${FAKE_RETENTION:-ok}" == ok ]] || { echo 'retention broke' >&2; exit 1; }`,
  };
  for (const [name, body] of Object.entries(stubs)) { writeFileSync(join(root, 'scripts', name), `#!/usr/bin/env bash\nset -uo pipefail\n${body}\n`, { mode: 0o755 }); }
  const result = join(scratch, 'result.txt');
  const run = (extra = {}) => {
    const r = spawnSync('bash', [join(root, 'scripts/watch-daily.sh'), result], { encoding: 'utf8', timeout: 60000,
      env: { ...process.env, WAREHOUSE_STATE_DIR: state, LOG: log, WAREHOUSE_WATCH_NODE: process.execPath, ...extra } });
    return { ...r, fields: Object.fromEntries(readFileSync(result, 'utf8').split('\n').filter(l => l.includes('=')).map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)])), log: readFileSync(log, 'utf8').trim().split('\n').filter(Boolean) };
  };
  return { scratch, state, root, run, result };
}

test('watch-daily.sh: backup, verify, prune and retention in that order, all under the one operator lock', () => {
  const f = dailyScriptFixture();
  try {
    for (let day = 10; day <= 17; day++) addBackup({ state: f.state }, `warehouse-202610${day}T020000Z`);
    addBackup({ state: f.state }, 'warehouse-20261001T020000Z', 'someone-else');
    const r = f.run();
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(r.log, [`backup `, 'backup-inherits-lock', `verify ${f.state}/backups/warehouse-20261019T020000Z`, 'retention apply', 'retention-inherits-lock']);
    assert.equal(r.log.some(l => /LOCK-FREE/.test(l)), false, 'the lock was held during every step');
    assert.deepEqual([r.fields.lock, r.fields.backup, r.fields.verify, r.fields.prune, r.fields.retention, r.fields.done], ['acquired', 'ok', 'ok', 'ok', 'ok', '1']);
    assert.equal(r.fields.backup_dir, `${f.state}/backups/warehouse-20261019T020000Z`);
    assert.equal(r.fields.pruned, '2', 'the 9 of this installation (8 + the new one) are cut to 7');
    assert.ok(existsSync(join(f.state, 'backups/warehouse-20261001T020000Z')), 'another installation\'s directory is untouched');
    assert.ok(!existsSync(join(f.state, 'backups/warehouse-20261010T020000Z')));
    // The backup whose verify passed is on the verified list (private), and it is the one pruning reports as kept.
    const list = join(f.state, 'config/backups-verified.list');
    assert.match(readFileSync(list, 'utf8'), /^warehouse-20261019T020000Z \d{10}\n$/);
    assert.equal(statSync(list).mode & 0o777, 0o600);
    assert.equal(r.fields.verified_kept, 'warehouse-20261019T020000Z');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-daily.sh: the sentence backup.sh prints when it re-copied files from a damaged earlier backup is passed on as backup_warning, and the pass stays ok', () => {
  const f = dailyScriptFixture();
  try {
    let r = f.run({ FAKE_BACKUP: 'warn' });
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual([r.fields.backup, r.fields.verify, r.fields.retention, r.fields.done], ['ok', 'ok', 'ok', '1']);
    assert.equal(r.fields.backup_warning, '2 files re-copied: backup warehouse-20261018T020000Z has a damaged copy');
    assert.match(r.stderr, /WARNING: 2 files re-copied/, 'and still on standard error for the journal');
    // One file: the singular form. A warning of another shape, or none, is not passed on.
    fs.writeFileSync(join(f.scratch, 'order.log'), '');
    r = f.run({ FAKE_BACKUP: 'warn1' });
    assert.equal(r.fields.backup_warning, '1 file re-copied: backup warehouse-20261018T020000Z has a damaged copy');
    r = f.run({ FAKE_BACKUP: 'other-warning' });
    assert.equal(r.fields.backup, 'ok');
    assert.equal('backup_warning' in r.fields, false);
    r = f.run();
    assert.equal('backup_warning' in r.fields, false);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-daily.sh: the WARNING backup.sh prints when df gave no free space and stat -f stood in is passed on as backup_warning too (joined with the other one, when both are there)', () => {
  const f = dailyScriptFixture();
  try {
    // The line is the one scripts/backup.sh prints (tests/backup-storage.test.mjs pins its text from that side).
    const space = 'df gave no free space for /srv/state/backups, so stat -f was used for the free-space check';
    let r = f.run({ FAKE_BACKUP: 'space-warn' });
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual([r.fields.backup, r.fields.verify, r.fields.retention, r.fields.done], ['ok', 'ok', 'ok', '1']);
    assert.equal(r.fields.backup_warning, space);
    assert.match(r.stderr, /WARNING: df gave no free space/, 'and still on standard error for the journal');
    r = f.run({ FAKE_BACKUP: 'both-warn' });
    assert.equal(r.fields.backup_warning, `2 files re-copied: backup warehouse-20261018T020000Z has a damaged copy; ${space}`);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-daily.sh: only an unhealthy database ends the pass before pruning and retention; a failed backup or a failed verify still prunes, keeps the verified backup and applies retention', () => {
  const f = dailyScriptFixture();
  try {
    const day = n => `warehouse-202610${n}T020000Z`;
    for (let n = 10; n <= 18; n++) addBackup({ state: f.state }, day(n));
    const list = join(f.state, 'config/backups-verified.list');
    const reset = () => fs.writeFileSync(join(f.scratch, 'order.log'), '');
    const remaining = () => readdirSync(join(f.state, 'backups')).sort();
    // The database is not healthy: nothing runs after the backup, nothing is pruned, nothing is recorded.
    let r = f.run({ FAKE_BACKUP: 'unhealthy' });
    assert.equal(r.status, 0);
    assert.deepEqual([r.fields.backup, r.fields.verify, r.fields.prune, r.fields.retention, r.fields.done], ['skipped', 'skipped', 'skipped', 'skipped', '1']);
    assert.match(r.fields.backup_message, /not healthy/);
    assert.deepEqual(r.log.filter(l => /verify|retention/.test(l)), []);
    assert.equal(remaining().length, 9, 'nothing was pruned');
    assert.equal(existsSync(list), false);
    // The oldest backup was verified long ago; every later one was not.
    fs.writeFileSync(list, `${day(10)} 1790000000\n`, { mode: 0o600 });
    // The backup fails (a refusal for lack of space is the example): the pass still prunes and applies retention. The 9
    // are cut to the newest 7 and the verified one: only day 11 goes.
    reset();
    r = f.run({ FAKE_BACKUP: 'fail' });
    assert.deepEqual([r.fields.backup, r.fields.verify, r.fields.prune, r.fields.retention, r.fields.done], ['failed', 'skipped', 'ok', 'ok', '1']);
    assert.match(r.fields.backup_message, /pg_dump: error: boom/);
    assert.equal(r.fields.pruned, '1');
    assert.equal(r.fields.verified_kept, day(10));
    assert.equal('retention_message' in r.fields, false);
    assert.ok(r.log.includes('retention apply'), 'retention ran after the failed backup');
    assert.deepEqual(remaining(), [day(10), ...[12, 13, 14, 15, 16, 17, 18].map(day)]);
    // The backup is made and fails its verify: it is kept (just made) but not recorded; the pass prunes (day 12 goes: the
    // newest 7 are now days 13 to 18 and the new one) and applies retention; the verified backup is still there.
    reset();
    r = f.run({ FAKE_VERIFY: 'bad' });
    assert.deepEqual([r.fields.backup, r.fields.verify, r.fields.prune, r.fields.retention], ['ok', 'failed', 'ok', 'ok']);
    assert.match(r.fields.verify_message, /signature mismatch/);
    assert.equal(r.fields.pruned, '1');
    assert.equal(r.fields.verified_kept, day(10), 'the verified backup is named, not the unverified new one');
    assert.ok(r.log.includes('retention apply'));
    assert.equal(readFileSync(list, 'utf8'), `${day(10)} 1790000000\n`, 'the list is unchanged: a backup that failed its verify is not recorded');
    assert.deepEqual(remaining(), [day(10), ...[13, 14, 15, 16, 17, 18, 19].map(day)]);
    // The next night verifies: the new backup joins the list, the old verified one is no longer protected and leaves it.
    reset();
    r = f.run();
    assert.deepEqual([r.fields.backup, r.fields.verify, r.fields.prune, r.fields.retention], ['ok', 'ok', 'ok', 'ok']);
    assert.equal(r.fields.pruned, '1');
    assert.equal(r.fields.verified_kept, day(19));
    assert.match(readFileSync(list, 'utf8'), /^warehouse-20261019T020000Z \d{10}\n$/, 'the old line was trimmed with its backup');
    assert.deepEqual(remaining(), [13, 14, 15, 16, 17, 18, 19].map(day));
    reset();
    r = f.run({ FAKE_RETENTION: 'bad' });
    assert.deepEqual([r.fields.backup, r.fields.retention], ['ok', 'failed']);
    assert.match(r.fields.retention_message, /retention broke/);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-daily.sh: another operator command holding the lock ends the pass with lock=held; a hung step is killed at its limit', async () => {
  const f = dailyScriptFixture();
  try {
    const holder = holdFlock(join(f.state, 'config/operator.lock'));
    try {
      await holder.ready;
      const r = f.run();
      assert.equal(r.status, 75);
      assert.deepEqual([r.fields.lock, r.fields.done], ['held', '1']);
      assert.deepEqual(r.log, [], 'no step ran');
    } finally { await holder.stop(); }
    const started = Date.now();
    const r = f.run({ FAKE_BACKUP: 'hang', WAREHOUSE_WATCH_BACKUP_SECS: '1', WAREHOUSE_WATCH_KILL_AFTER: '1s' });
    assert.ok(Date.now() - started < 15000);
    assert.equal(r.fields.backup, 'failed'); assert.match(r.fields.backup_message, /timed out/);
    assert.deepEqual([r.fields.prune, r.fields.retention], ['ok', 'ok'], 'a backup that timed out does not stop pruning and retention');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('backup.sh and retention.sh take the operator lock themselves, or use the one they inherit', () => {
  for (const name of ['backup.sh', 'retention.sh']) {
    const text = readFileSync(join(repo, 'scripts', name), 'utf8');
    assert.match(text, /operator_lock_or_inherited "\$state"/, name);
    assert.doesNotMatch(text, /^operator_lock "\$state"/m, name);
  }
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-watch-lock-'));
  try {
    mkdirSync(join(scratch, 'config'));
    const probe = `. "${repo}scripts/operator-lock.sh"; operator_lock_or_inherited "$S" && echo got`.replace('//', '/');
    const env = { ...process.env, S: scratch };
    // Alone: it takes the lock. Inside a parent that holds it: inherited. Held by someone else: refused.
    assert.equal(spawnSync('bash', ['-c', probe], { encoding: 'utf8', env }).stdout.trim(), 'got');
    const inherited = spawnSync('bash', ['-c', `. "${repo}scripts/operator-lock.sh"; operator_lock "$S" && bash -c '${probe.replace(/'/g, "'\\''")}'`], { encoding: 'utf8', env });
    assert.equal(inherited.stdout.trim(), 'got');
    const refused = spawnSync('bash', ['-c', `exec 8>"$S/config/operator.lock"; flock -n 8; bash -c '${probe.replace(/'/g, "'\\''")}'`], { encoding: 'utf8', env });
    assert.notEqual(refused.stdout.trim(), 'got'); assert.match(refused.stderr, /Another operator command/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

// ---------------------------------------------------------------- pruning
test('prune keeps the newest 7 of this installation (manual backups count) and never touches anything else', () => {
  const h = harness();
  try {
    const backups = join(h.state, 'backups');
    const names = Array.from({ length: 9 }, (_, i) => `warehouse-202610${String(10 + i).padStart(2, '0')}T020000Z`);
    for (const n of names) addBackup(h, n);
    mkdirSync(join(backups, 'warehouse-20260101T020000Z'));                      // matches the name, no metadata.txt: not ours
    mkdirSync(join(backups, 'warehouse-keep-me')); mkdirSync(join(backups, 'manual-backup'));
    addBackup(h, 'warehouse-20260301T020000Z', 'another-installation');           // another installation's: not counted, not removed
    mkdirSync(join(backups, 'warehouse-20261001T020000')); writeFileSync(join(backups, 'warehouse-20261001T020000', 'metadata.txt'), 'x'); // wrong suffix
    writeFileSync(join(backups, 'warehouse-20260102T020000Z.tar'), 'x');
    symlinkSync(join(backups, names[8]), join(backups, 'warehouse-20260201T020000Z'));
    const { removed, note } = W.pruneBackups(h.state, { now: at(19, 12) });
    assert.deepEqual(removed, [names[1], names[0]]); assert.equal(note, '');
    assert.deepEqual(readdirSync(backups).sort(), ['manual-backup', 'warehouse-20260101T020000Z', 'warehouse-20260102T020000Z.tar', 'warehouse-20260201T020000Z', 'warehouse-20260301T020000Z', 'warehouse-20261001T020000', 'warehouse-keep-me', ...names.slice(2)].sort());
    assert.deepEqual(W.pruneBackups(h.state, { now: at(19, 12) }).removed, [], 'nothing more to remove');
  } finally { clean(h); }
});

test('prune never removes the backup just made, even when it sorts oldest', () => {
  const h = harness();
  try {
    const names = Array.from({ length: 8 }, (_, i) => `warehouse-202610${String(10 + i).padStart(2, '0')}T020000Z`);
    for (const n of names) addBackup(h, n);
    const mine = join(h.state, 'backups', names[0]);
    const { removed } = W.pruneBackups(h.state, { protect: mine, now: at(19, 12) });
    assert.deepEqual(removed, [], 'the 8th is the protected one');
    assert.ok(existsSync(mine));
    addBackup(h, 'warehouse-20261018T020000Z');
    assert.deepEqual(W.pruneBackups(h.state, { protect: mine, now: at(19, 12) }).removed, [names[1]]);
    assert.ok(existsSync(mine));
  } finally { clean(h); }
});

test('prune removes nothing, and says so, when a backup is dated more than an hour in the future; the state path must be absolute', () => {
  const h = harness();
  try {
    const names = Array.from({ length: 9 }, (_, i) => `warehouse-202610${String(10 + i).padStart(2, '0')}T020000Z`);
    for (const n of names) addBackup(h, n);
    const now = at(19, 12);
    const future = 'warehouse-20271231T235959Z';
    addBackup(h, future);
    const r = W.pruneBackups(h.state, { now });
    assert.deepEqual(r.removed, []); assert.match(r.note, new RegExp(`${future} is dated in the future`));
    assert.equal(readdirSync(join(h.state, 'backups')).length, 10);
    rmSync(join(h.state, 'backups', future), { recursive: true });
    // Within the hour of tolerance a name is not "future".
    const near = stampOf(now + 30 * 60000); addBackup(h, near);
    assert.equal(W.pruneBackups(h.state, { now }).removed.length, 3);
    assert.throws(() => W.pruneBackups('relative/state'), /must be absolute/);
    assert.throws(() => W.pruneBackups(''), /must be absolute/);
  } finally { clean(h); }
});

test('prune-backups command prints removed=, note= and verified_kept= and protects the path it is given; a backup that failed has no path', async () => {
  const h = harness();
  try {
    const names = Array.from({ length: 8 }, (_, i) => `warehouse-202610${String(10 + i).padStart(2, '0')}T020000Z`);
    for (const n of names) addBackup(h, n);
    const out = [];
    assert.equal(await W.main(['prune-backups', join(h.state, 'backups', names[7])], h.deps, t => out.push(t)), 0);
    assert.equal(out[0], `removed=1\nnote=\nverified_kept=`);
    // No path: the daily backup failed, so there is no backup just made; pruning still runs.
    addBackup(h, 'warehouse-20261018T020000Z');
    assert.equal(await W.main(['prune-backups'], h.deps, t => out.push(t)), 0);
    assert.equal(out[1], `removed=1\nnote=\nverified_kept=`);
    assert.ok(!existsSync(join(h.state, 'backups', names[1])));
    // Arguments that make no sense are refused before anything is touched, on standard error (watch-daily.sh reads the reason there).
    for (const bad of [['--verified'], ['--bogus'], ['a', 'b'], ['--verified', names[7], '--verified', names[7]]]) {
      const before = readdirSync(join(h.state, 'backups')).length;
      const shown = []; const printed = [];
      assert.equal(await W.main(['prune-backups', ...bad], h.deps, t => printed.push(t), t => shown.push(t)), 1, bad.join(' '));
      assert.deepEqual(shown, ['Usage: prune-backups [PATH_OF_THE_BACKUP_JUST_MADE] [--verified NAME]'], bad.join(' '));
      assert.deepEqual(printed, [], 'nothing on standard output');
      assert.equal(readdirSync(join(h.state, 'backups')).length, before, 'nothing removed');
    }
    assert.equal(existsSync(join(h.state, 'config/backups-verified.list')), false, 'nothing recorded');
    // A --verified name that is not a backup of this installation is a note: pruning goes on, nothing is recorded.
    addBackup(h, 'warehouse-20261019T020000Z');
    for (const bad of ['not-a-backup', 'warehouse-20200101T000000Z']) {
      const shown = []; const printed = [];
      assert.equal(await W.main(['prune-backups', '--verified', bad], h.deps, t => printed.push(t), t => shown.push(t)), 0, bad);
      assert.deepEqual(shown, []);
      assert.match(printed[0], new RegExp(`^removed=\\d+\nnote=--verified needs the name of a backup directory in ${join(h.state, 'backups')} \\(it was '${bad}'\\); nothing was recorded as verified\nverified_kept=$`));
    }
    assert.equal(readdirSync(join(h.state, 'backups')).length, 7, 'the newest 7 are what is left: pruning ran');
    assert.equal(existsSync(join(h.state, 'config/backups-verified.list')), false, 'nothing recorded');
  } finally { clean(h); }
});

test('prune-backups --verified records the backup in config/backups-verified.list (private, one line per name, trimmed to the backups that still exist) and then prunes', async () => {
  const h = harness();
  try {
    const list = join(h.state, 'config/backups-verified.list');
    const nm = n => `warehouse-202610${String(n).padStart(2, '0')}T020000Z`;
    for (let n = 10; n <= 14; n++) addBackup(h, nm(n));
    const run = async (...args) => { const out = []; assert.equal(await W.main(['prune-backups', ...args], h.deps, t => out.push(t)), 0); return out[0]; };
    h.clock.t = at(16, 3, 0);
    // The first call creates the file with mode 0600; the path or the bare name both do.
    assert.equal(await run(join(h.state, 'backups', nm(10)), '--verified', join(h.state, 'backups', nm(10))), `removed=0\nnote=\nverified_kept=${nm(10)}`);
    assert.equal(readFileSync(list, 'utf8'), `${nm(10)} ${Math.floor(at(16, 3, 0) / 1000)}\n`);
    assert.equal(statSync(list).mode & 0o777, 0o600);
    // Later nights append: one line per name, the newest last.
    h.clock.t = at(16, 3, 30); await run(nm(11), '--verified', nm(11));
    h.clock.t = at(16, 4, 0); await run(nm(12), '--verified', nm(12));
    assert.equal(readFileSync(list, 'utf8'), `${nm(10)} ${Math.floor(at(16, 3, 0) / 1000)}\n${nm(11)} ${Math.floor(at(16, 3, 30) / 1000)}\n${nm(12)} ${Math.floor(at(16, 4, 0) / 1000)}\n`);
    // Verified again (a re-check of the same backup): the old line is replaced, not repeated, and moves last.
    h.clock.t = at(16, 5, 0); await run('--verified', nm(10));
    const epoch = (hh, mm) => Math.floor(at(16, hh, mm) / 1000);
    assert.deepEqual(readFileSync(list, 'utf8').trim().split('\n'), [`${nm(11)} ${epoch(3, 30)}`, `${nm(12)} ${epoch(4, 0)}`, `${nm(10)} ${epoch(5, 0)}`]);
    // A backup that is gone from the disk (removed by hand) leaves the list at the next record. Junk lines and links are never trusted.
    rmSync(join(h.state, 'backups', nm(11)), { recursive: true });
    addBackup(h, nm(13));
    h.clock.t = at(16, 6, 0); await run(nm(13), '--verified', nm(13));
    assert.deepEqual(readFileSync(list, 'utf8').trim().split('\n').map(l => l.split(' ')[0]), [nm(12), nm(10), nm(13)], 'the removed backup left the list');
    assert.deepEqual(W.readVerifiedList(h.state).map(e => e.name), [nm(12), nm(10), nm(13)]);
    writeFileSync(list, `garbage\n../../etc/passwd 1\n${nm(12)} 5\n\n${nm(12)} 9\n${nm(13)}\n`);
    assert.deepEqual(W.readVerifiedList(h.state), [{ name: nm(12), epoch: 9 }, { name: nm(13), epoch: 0 }], 'a name seen twice counts once, as its last line says');
    rmSync(list); symlinkSync(join(h.scratch, 'elsewhere'), list); writeFileSync(join(h.scratch, 'elsewhere'), `${nm(13)} 1\n`);
    assert.deepEqual(W.readVerifiedList(h.state), [], 'a link in its place is ignored');
    h.clock.t = at(16, 7, 0); await run(nm(13), '--verified', nm(13));
    assert.equal(fs.lstatSync(list).isSymbolicLink(), false, 'and replaced by a plain private file');
    assert.equal(readFileSync(join(h.scratch, 'elsewhere'), 'utf8'), `${nm(13)} 1\n`, 'the link target was not written through');
    assert.equal(statSync(list).mode & 0o777, 0o600);
    // Names that pruning removes leave the list with them.
    for (let n = 15; n <= 20; n++) addBackup(h, nm(n));
    fs.writeFileSync(list, `${nm(10)} 1\n${nm(12)} 2\n`, { mode: 0o600 });
    h.clock.t = at(22, 3, 0);
    const result = await run(nm(20));
    assert.match(result, /^removed=\d+\nnote=\nverified_kept=warehouse-20261012T020000Z$/);
    assert.equal(readFileSync(list, 'utf8'), `${nm(12)} 2\n`, 'day 10 was removed (older than the newest verified, outside the newest 7)');
  } finally { clean(h); }
});

test('prune keeps the newest verified backup beyond the newest 7, through any number of nights whose verify fails; unverified backups older than it go first', async () => {
  const h = harness();
  try {
    const nm = n => `warehouse-202610${String(n).padStart(2, '0')}T020000Z`;
    const backups = join(h.state, 'backups');
    const out = [];
    const run = async (...args) => { out.length = 0; assert.equal(await W.main(['prune-backups', ...args], h.deps, t => out.push(t)), 0); return out[0]; };
    // Day 1 is verified; from day 2 on every night's verify fails (the backup is made, the verify is not passed): no --verified.
    addBackup(h, nm(1));
    h.clock.t = at(2, 12); await run(nm(1), '--verified', nm(1));
    for (let day = 2; day <= 12; day++) {
      addBackup(h, nm(day));
      h.clock.t = at(day + 1, 12);
      await run(nm(day));
      const kept = readdirSync(backups).sort();
      assert.ok(kept.includes(nm(1)), `night ${day}: the verified backup is still there`);
      assert.equal(kept.length, Math.min(day, 7) + (day > 7 ? 1 : 0), `night ${day}: the newest 7 and the verified one`);
    }
    assert.deepEqual(readdirSync(backups).sort(), [nm(1), ...[6, 7, 8, 9, 10, 11, 12].map(nm)]);
    assert.equal(readFileSync(join(h.state, 'config/backups-verified.list'), 'utf8').trim().split('\n').length, 1, 'only the verified one is on the list');
    // Nothing on the list for lack of any verify: the newest 7, as before.
    const bare = harness();
    try {
      for (let n = 10; n <= 19; n++) addBackup(bare, nm(n));
      const r = W.pruneBackups(bare.state, { now: at(21, 12) });
      assert.deepEqual(r.removed, [nm(12), nm(11), nm(10)]); assert.equal(r.verifiedKept, '');
    } finally { clean(bare); }
    // Removal order when the pass is cut short: never-verified backups older than the newest verified one first (newest first),
    // then the rest. Days 3 and 5 are verified, day 5 the newest: 1, 2, 4 are older and never verified; 3 is older but verified.
    const order = harness();
    try {
      for (let n = 1; n <= 12; n++) addBackup(order, nm(n));
      writeFileSync(join(order.state, 'config/backups-verified.list'), `${nm(3)} 1\n${nm(5)} 2\n`);
      const r = W.pruneBackups(order.state, { now: at(21, 12) });
      assert.deepEqual(r.removed, [nm(4), nm(2), nm(1), nm(3)], 'unverified older ones first, then the older verified backup');
      assert.equal(r.verifiedKept, nm(5));
      assert.deepEqual(readdirSync(join(order.state, 'backups')).sort(), [nm(5), ...[6, 7, 8, 9, 10, 11, 12].map(nm)]);
      assert.equal(readFileSync(join(order.state, 'config/backups-verified.list'), 'utf8'), `${nm(5)} 2\n`, 'removed names left the list');
    } finally { clean(order); }
    // The backup just made and the newest verified one are both kept even when both are outside the newest 7.
    const both = harness();
    try {
      for (let n = 1; n <= 10; n++) addBackup(both, nm(n));
      writeFileSync(join(both.state, 'config/backups-verified.list'), `${nm(2)} 1\n`);
      const r = W.pruneBackups(both.state, { protect: join(both.state, 'backups', nm(1)), now: at(21, 12) });
      assert.deepEqual(r.removed, [nm(3)]);
      assert.deepEqual(readdirSync(join(both.state, 'backups')).sort(), [nm(1), nm(2), ...[4, 5, 6, 7, 8, 9, 10].map(nm)]);
    } finally { clean(both); }
    // A listed backup that is another installation's, not a backup directory of this one, or gone is not "the newest verified".
    const foreign = harness();
    try {
      for (let n = 1; n <= 10; n++) addBackup(foreign, nm(n));
      addBackup(foreign, nm(11), 'another-installation');
      writeFileSync(join(foreign.state, 'config/backups-verified.list'), `${nm(11)} 1\nwarehouse-20261020T020000Z 1\n${nm(2)} 1\n`);
      const r = W.pruneBackups(foreign.state, { now: at(21, 12) });
      assert.equal(r.verifiedKept, nm(2), 'the foreign and the missing entries are passed over');
      assert.ok(existsSync(join(foreign.state, 'backups', nm(2))) && existsSync(join(foreign.state, 'backups', nm(11))));
      assert.deepEqual(r.removed, [nm(1), nm(3)]);
    } finally { clean(foreign); }
    // The clock guard still wins: nothing is removed, and the verified backup is still reported.
    const future = harness();
    try {
      for (let n = 1; n <= 10; n++) addBackup(future, nm(n));
      addBackup(future, 'warehouse-20271231T235959Z');
      writeFileSync(join(future.state, 'config/backups-verified.list'), `${nm(4)} 1\n`);
      const r = W.pruneBackups(future.state, { now: at(21, 12) });
      assert.deepEqual(r.removed, []); assert.match(r.note, /dated in the future/); assert.equal(r.verifiedKept, nm(4));
    } finally { clean(future); }
  } finally { clean(h); }
});

test('prune: a backups folder that does not exist yet has nothing to prune (a first night can fail before the folder is made)', async () => {
  const h = harness();
  try {
    rmSync(join(h.state, 'backups'), { recursive: true, force: true });
    assert.deepEqual(W.pruneBackups(h.state, { now: at(19, 12) }), { removed: [], note: '', verifiedKept: '' });
    const out = [];
    assert.equal(await W.main(['prune-backups'], h.deps, t => out.push(t)), 0);
    assert.equal(out[0], 'removed=0\nnote=\nverified_kept=');
    // Anything else that stops the folder being read is still an error, not a quiet pass.
    writeFileSync(join(h.state, 'backups'), 'a file where the folder should be');
    assert.throws(() => W.pruneBackups(h.state, { now: at(19, 12) }), /ENOTDIR/);
  } finally { clean(h); }
});

// The record upgrade.sh writes before its first change (scripts/upgrade-record.mjs reads it).
function upgradeRecord(h, backup, extra = {}) {
  const fields = { format: 1, from_sha: 'a'.repeat(40), to_sha: 'b'.repeat(40), verified: 'yes', backup, step: 'setup', ...extra };
  writeFileSync(join(h.state, 'config/upgrade-in-progress'), `${Object.entries(fields).map(([k, v]) => `${k}=${v}`).join('\n')}\n`, { mode: 0o600 });
}

test('prune keeps the backup that an interrupted upgrade recorded as its way back, however old, and says so; a record that names no backup protects nothing', async () => {
  const h = harness();
  try {
    const nm = n => `warehouse-202610${String(n).padStart(2, '0')}T020000Z`;
    const backups = join(h.state, 'backups');
    for (let n = 1; n <= 10; n++) addBackup(h, nm(n));
    upgradeRecord(h, join(backups, nm(1)));
    const out = [];
    assert.equal(await W.main(['prune-backups', join(backups, nm(10))], h.deps, t => out.push(t)), 0);
    assert.equal(out[0], `removed=2\nnote=kept ${nm(1)}, the backup of the interrupted upgrade (config/upgrade-in-progress)\nverified_kept=`);
    assert.deepEqual(readdirSync(backups).sort(), [nm(1), ...[4, 5, 6, 7, 8, 9, 10].map(nm)], 'days 2 and 3 went, day 1 stayed');
    // Night after night, with failing verifies, it stays: it is the one backup the upgrade can go back to.
    for (let n = 11; n <= 20; n++) { addBackup(h, nm(n)); assert.ok(W.pruneBackups(h.state, { now: at(25, 12) }).removed.every(name => name !== nm(1))); }
    assert.ok(existsSync(join(backups, nm(1))));
    // A backup that the record names but that is among the newest 7 needs no note.
    upgradeRecord(h, join(backups, nm(20)));
    assert.equal(W.pruneBackups(h.state, { now: at(25, 12) }).note, '');
    // It protects whatever the record says about verification, and the path may come from another folder: only the name counts.
    upgradeRecord(h, join(backups, nm(1)), { verified: 'no' });
    assert.equal(W.pruneBackups(h.state, { now: at(25, 12) }).removed.includes(nm(1)), false);
    upgradeRecord(h, join('/somewhere/else', nm(1)));
    assert.equal(W.pruneBackups(h.state, { now: at(25, 12) }).removed.includes(nm(1)), false);
    // No record that names a backup: no protection and no error. (An invalid record, one with no backup, a name that is no backup, no file, a folder in its place.)
    for (const record of [() => upgradeRecord(h, join(backups, nm(1)), { from_sha: 'short' }), () => upgradeRecord(h, '', { verified: 'no' }), () => upgradeRecord(h, join(backups, 'manual-backup')),
      () => {}, () => mkdirSync(join(h.state, 'config/upgrade-in-progress'))]) {
      rmSync(join(h.state, 'config/upgrade-in-progress'), { recursive: true, force: true });
      addBackup(h, nm(1));
      record();
      const r = W.pruneBackups(h.state, { now: at(25, 12) });
      assert.equal(r.removed.includes(nm(1)), true, 'not protected');
      assert.equal(r.note, '');
    }
  } finally { clean(h); }
});

test('prune removes a backup by renaming it first, finishes a removal that was cut short (a leftover is not a backup), and empties a tree that has a read-only folder', () => {
  const h = harness();
  try {
    const nm = n => `warehouse-202610${String(n).padStart(2, '0')}T020000Z`;
    const backups = join(h.state, 'backups');
    for (let n = 1; n <= 9; n++) addBackup(h, nm(n));
    // Day 1 holds a v6-style tree with a folder that rsync kept read-only; a removal that was cut short left half of day 0 behind.
    for (const root of [join(backups, nm(1)), join(backups, `.warehouse-backup-removing.${nm(0)}`)]) {
      mkdirSync(join(root, 'storage/a/b'), { recursive: true });
      writeFileSync(join(root, 'storage/a/b/file'), 'photo');
      chmodSync(join(root, 'storage/a/b'), 0o500);
      chmodSync(join(root, 'storage/a'), 0o500);
    }
    const r = W.pruneBackups(h.state, { now: at(19, 12) });
    assert.deepEqual(r.removed, [nm(2), nm(1)], 'the leftover is not counted: two of the nine are over');
    assert.deepEqual(readdirSync(backups).sort(), [3, 4, 5, 6, 7, 8, 9].map(nm), 'the backups, the leftover and the tree are all gone');
    // While the clock is wrong nothing is removed, the leftover included.
    addBackup(h, 'warehouse-20271231T235959Z');
    const left = join(backups, `.warehouse-backup-removing.${nm(0)}`);
    mkdirSync(left);
    assert.match(W.pruneBackups(h.state, { now: at(19, 12) }).note, /dated in the future/);
    assert.ok(existsSync(left));
  } finally { clean(h); }
});

test('prune names the verified backup of THIS installation also when it skips pruning (the clock, a missing instanceId): a listed backup of another installation is not it', () => {
  const h = harness();
  try {
    const nm = n => `warehouse-202610${String(n).padStart(2, '0')}T020000Z`;
    for (let n = 1; n <= 9; n++) addBackup(h, nm(n));
    addBackup(h, nm(15), 'another-installation');
    addBackup(h, 'warehouse-20271231T235959Z');
    writeFileSync(join(h.state, 'config/backups-verified.list'), `${nm(15)} 3\nwarehouse-20261020T020000Z 3\n${nm(4)} 2\n`);
    const r = W.pruneBackups(h.state, { now: at(25, 12) });
    assert.match(r.note, /dated in the future/);
    assert.equal(r.verifiedKept, nm(4), 'the other installation\'s backup and the missing one are passed over');
    rmSync(join(h.state, 'backups/warehouse-20271231T235959Z'), { recursive: true });
    writeFileSync(join(h.state, 'public/instance.json'), '{}');
    const none = W.pruneBackups(h.state, { now: at(25, 12) });
    assert.match(none.note, /has no instanceId/);
    assert.equal(none.verifiedKept, '', 'none can be said to be ours');
  } finally { clean(h); }
});

test('prune-backups --verified that cannot be recorded (the list cannot be written) is a note, and pruning still runs', async () => {
  const h = harness();
  try {
    const nm = n => `warehouse-202610${String(n).padStart(2, '0')}T020000Z`;
    for (let n = 1; n <= 9; n++) addBackup(h, nm(n));
    mkdirSync(join(h.state, 'config/backups-verified.list'));            // a folder where the file belongs
    const out = [];
    assert.equal(await W.main(['prune-backups', join(h.state, 'backups', nm(9)), '--verified', nm(9)], h.deps, t => out.push(t)), 0);
    assert.match(out[0], new RegExp(`^removed=2\nnote=could not record ${nm(9)} as verified: .+\nverified_kept=$`));
    assert.deepEqual(readdirSync(join(h.state, 'backups')).sort(), [3, 4, 5, 6, 7, 8, 9].map(nm), 'the pass pruned all the same');
    assert.deepEqual(readdirSync(join(h.state, 'config')).filter(name => name.includes('backups-verified')), ['backups-verified.list'], 'and left no temporary file behind');
  } finally { clean(h); }
});

// ---------------------------------------------------------------- self-healing
const healCalls = h => h.calls.filter(c => /compose\.sh (up|restart) /.test(c)).map(c => c.replace(/^bash \S+\/scripts\//, ''));
const healRun = h => W.runOnce(h.deps, { checks: HEALTHY, ...NO_JOBS });
test('self-heal: an exited service is started again (no recreate, no build, no pull, no dependencies), at most once an hour, and the action is an alert that fires at once', async () => {
  const h = harness();
  try {
    h.seed(); h.stateOf = { rest: 'exited|' };
    h.runs['compose.sh up -d --no-build --no-recreate --no-deps --pull never rest'] = ok();
    await healRun(h);
    assert.deepEqual(healCalls(h), ['compose.sh up -d --no-build --no-recreate --no-deps --pull never rest']);
    const fired = h.posts.filter(p => /^\[FIRING\]/.test(p.text));
    assert.equal(fired.length, 1, 'fires at the first run, not after two');
    assert.match(fired[0].text, /Service rest was exited; the checker started it again/);
    assert.equal(h.state_().heal.rest.lastAt, h.clock.t);
    h.advance(5 * 60000); await healRun(h);
    h.advance(50 * 60000); await healRun(h);
    assert.equal(healCalls(h).length, 1, 'not again within an hour');
    assert.equal(h.posts.filter(p => /service_healed|started it again/.test(p.text)).length, 1, 'no repeat post within 4 hours');
    h.advance(10 * 60000); await healRun(h);
    assert.equal(healCalls(h).length, 2, 'an hour later it is tried again');
    // The service is back: the held alert clears an hour after the last action.
    h.stateOf = {};
    h.advance(61 * 60000); await healRun(h);
    h.advance(5 * 60000); await healRun(h);
    assert.ok(h.posts.some(p => /^\[CLEARED\]/.test(p.text) && /Service rest/.test(p.text)));
  } finally { clean(h); }
});

test('self-heal: a service unhealthy for 3 runs in a row is restarted; the database never is for that, but is started when exited', async () => {
  const h = harness();
  try {
    h.seed(); h.stateOf = { rest: 'running|unhealthy', db: 'running|unhealthy' };
    h.runs['compose.sh restart rest'] = ok();
    for (let i = 0; i < 2; i++) { await healRun(h); h.advance(5 * 60000); }
    assert.deepEqual(healCalls(h), [], '2 runs are not enough');
    await healRun(h);
    assert.deepEqual(healCalls(h), ['compose.sh restart rest'], '3 runs: rest is restarted, db is left alone');
    assert.match(h.posts.map(p => p.text).join('\n'), /Service rest was unhealthy for 3 runs; the checker restarted it/);
    // A healthy run resets the count: unhealthy, healthy, unhealthy, unhealthy does not restart.
    const g = harness();
    try {
      g.seed(); g.runs['compose.sh restart rest'] = ok();
      for (const state of ['running|unhealthy', 'running|unhealthy', 'running|', 'running|unhealthy', 'running|unhealthy']) {
        g.stateOf = { rest: state }; await healRun(g); g.advance(5 * 60000);
      }
      assert.deepEqual(healCalls(g), []);
    } finally { clean(g); }
    const d = harness();
    try {
      d.seed(); d.stateOf = { db: 'exited|' }; d.runs['compose.sh up -d --no-build --no-recreate --no-deps --pull never db'] = ok();
      await healRun(d);
      assert.deepEqual(healCalls(d), ['compose.sh up -d --no-build --no-recreate --no-deps --pull never db']);
    } finally { clean(d); }
  } finally { clean(h); }
});

test('self-heal: nothing while an operator command holds the lock, while the service alert is muted, or for an optional service', async () => {
  const h = harness();
  try {
    h.seed(); h.stateOf = { rest: 'exited|' };
    h.holdLock(); await healRun(h);
    h.releaseLock();
    await W.main(['mute', '30', 'service_down:rest'], h.deps, () => {});
    await healRun(h);
    assert.deepEqual(healCalls(h), [], 'locked, then muted');
    await W.main(['unmute', 'service_down:rest'], h.deps, () => {});
    await W.main(['mute', '30'], h.deps, () => {});
    await healRun(h);
    assert.deepEqual(healCalls(h), [], 'all alerts muted');
    h.services = [...SERVICES, 'supavisor', 'cups'];
    h.stateOf = { supavisor: 'exited|', cups: 'exited|' };
    await W.main(['unmute'], h.deps, () => {});
    await healRun(h);
    assert.deepEqual(healCalls(h), [], 'profile services are not started by the checker');
  } finally { clean(h); }
});

test('self-heal: a failing start is reported with its reason and is not retried within the hour; bad heal state is reset', async () => {
  const h = harness();
  try {
    h.seed(); h.stateOf = { storage: 'exited|' };
    h.runs['compose.sh up -d --no-build --no-recreate --no-deps --pull never storage'] = bad('no such image password=supersecretpassword123');
    await healRun(h);
    const text = h.posts.map(p => p.text).join('\n');
    assert.match(text, /Service storage was exited; the checker could not do it: no such image/);
    assert.ok(!text.includes('supersecretpassword123'));
    h.advance(5 * 60000); await healRun(h);
    assert.equal(healCalls(h).length, 1);
    const logs = [];
    const fixed = W.normalizeState({ heal: { rest: { unhealthyRuns: 'x' } } }, 0, m => logs.push(m));
    assert.deepEqual(fixed.heal, {});
    assert.match(logs[0], /"heal" had the wrong type/);
  } finally { clean(h); }
});

const UP = 'compose.sh up -d --no-build --no-recreate --no-deps --pull never';
test('self-heal: a created container (a power cut during up) is started too; the start can neither build, pull, recreate nor touch dependencies', async () => {
  const h = harness();
  try {
    h.seed(); h.stateOf = { rest: 'created|', storage: 'dead|' };
    h.runs[`${UP} rest`] = ok();
    await healRun(h);
    assert.deepEqual(healCalls(h), [`${UP} rest`], 'created is started; a status the checker does not know (dead) is left to a person');
    const line = h.calls.find(c => /compose\.sh up /.test(c));
    for (const flag of ['--no-build', '--no-recreate', '--no-deps', '--pull never']) assert.ok(line.includes(flag), flag);
    assert.match(h.posts.map(p => p.text).join('\n'), /Service rest was created; the checker started it again/);
  } finally { clean(h); }
});

test('self-heal: at most 6 actions per service in 24 hours; after that it only alerts and says so, until the oldest action is a day old', async () => {
  const h = harness();
  try {
    h.seed(); h.stateOf = { rest: 'exited|' };
    h.runs[`${UP} rest`] = ok();
    for (let i = 0; i < 6; i++) { await healRun(h); h.advance(61 * 60000); }
    assert.equal(healCalls(h).length, 6, 'one an hour for six hours');
    let r = await healRun(h);
    assert.equal(healCalls(h).length, 6, 'the seventh is not made');
    const capped = find(r.results, 'service_healed:rest');
    assert.equal(capped.ok, false); assert.equal(capped.immediate, true);
    assert.match(capped.summary, /Service rest was exited; the checker has already tried 6 times in the last 24 hours and stops here: it needs a person \(docs\/MONITORING\.md, "Self-healing"\)/);
    // More than an hour later the alert is still there (it does not lapse with the hour) and nothing is tried.
    for (let i = 0; i < 4; i++) { h.advance(2 * HOUR); r = await healRun(h); assert.equal(find(r.results, 'service_healed:rest')?.ok, false); }
    assert.equal(healCalls(h).length, 6);
    assert.ok(h.state_().heal.rest.actions.length === 6);
    assert.ok(h.posts.some(p => /^\[STILL FIRING\]/.test(p.text) && /stops here/.test(p.text)), 'told again every 4 hours');
    // service_down fires as for any stopped service, and the service coming back clears the self-heal alert.
    assert.ok(h.state_().alerts['service_healed:rest']);
    // 24 hours after the first action it may try again (once).
    h.clock.t = h.state_().heal.rest.actions[0] + 24 * HOUR + 1000;
    await healRun(h);
    assert.equal(healCalls(h).length, 7, 'the oldest action has aged out');
    // Another service has its own count.
    h.stateOf = { rest: 'exited|', storage: 'exited|' }; h.runs[`${UP} storage`] = ok();
    await healRun(h);
    assert.ok(healCalls(h).includes(`${UP} storage`));
    // The record in the state file is validated.
    const logs = [];
    assert.deepEqual(W.normalizeState({ heal: { rest: { unhealthyRuns: 0, lastAt: null, lastAction: '', actions: [1, 2] } } }, 0, m => logs.push(m)).heal.rest.actions, [1, 2]);
    assert.deepEqual(W.normalizeState({ heal: { rest: { unhealthyRuns: 0, lastAt: null, lastAction: '', actions: ['x'] } } }, 0, m => logs.push(m)).heal, {});
    assert.deepEqual(W.normalizeState({ heal: { rest: { unhealthyRuns: 0, lastAt: null, lastAction: '' } } }, 0, m => logs.push(m)).heal.rest.actions ?? [], [], 'an older state file without actions');
  } finally { clean(h); }
});

test('self-heal: nothing while config/stopped-by-operator exists (stop.sh wrote it); status says so; start.sh removing it lets the checker act again', async () => {
  const h = harness();
  try {
    h.seed(); h.stateOf = { rest: 'exited|' };
    h.runs[`${UP} rest`] = ok();
    const hold = join(h.state, 'config/stopped-by-operator');
    writeFileSync(hold, 'stopped by stop.sh at 2026-10-19T09:00:00Z\n');
    await healRun(h); h.advance(2 * HOUR); await healRun(h);
    assert.deepEqual(healCalls(h), [], 'the operator stopped the stack: not restarted');
    assert.equal(W.stoppedByOperator(h.state), true);
    const out = []; await W.main(['status'], h.deps, t => out.push(t));
    assert.match(out[0], /Stack: stopped by the operator \(config\/stopped-by-operator\); nothing restarts it at boot or by self-healing\. Run start\.sh to bring it back\./);
    rmSync(hold);
    assert.equal(W.stoppedByOperator(h.state), false);
    await healRun(h);
    assert.deepEqual(healCalls(h), [`${UP} rest`]);
    out.length = 0; await W.main(['status'], h.deps, t => out.push(t));
    assert.doesNotMatch(out[0], /stopped by the operator/);
  } finally { clean(h); }
});

// ---------------------------------------------------------------- command line
test('the usage text is printed for --help and an unknown command, with the mute-before-stop note and quoted ids', async () => {
  const out = [];
  assert.equal(await W.main(['--help'], { now: () => 0 }, t => out.push(t)), 0);
  assert.match(out[0], /^Usage: node scripts\/watch\.mjs run/);
  assert.match(out[0], /mute MINUTES \["ALERT ID"\]/);
  assert.match(out[0], /Mute before a deliberate stop\.sh/);
  assert.match(out[0], /backups made by hand there count towards the 7/);
  const run = spawnSync('node', [join(repo, 'scripts/watch.mjs'), '--help'], { encoding: 'utf8' });
  assert.equal(run.status, 0); assert.match(run.stdout, /test-message/);
  const none = spawnSync('node', [join(repo, 'scripts/watch.mjs')], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: '' } });
  assert.equal(none.status, 1); assert.match(none.stdout, /Usage/);
});

test('an invalid or relative --state / WAREHOUSE_STATE_DIR is refused', () => {
  const r = spawnSync('node', [join(repo, 'scripts/watch.mjs'), 'status'], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: 'relative/dir' } });
  assert.equal(r.status, 1); assert.match(r.stderr, /absolute installed operator state/);
  assert.throws(() => W.defaultDeps({ WAREHOUSE_STATE_DIR: '' }), /absolute/);
});

test('test-message posts the test text; status lists alerts, the time zone and mutes with spaces in their id', async () => {
  const h = harness();
  try {
    const out = [];
    assert.equal(await W.main(['test-message'], h.deps, t => out.push(t)), 0);
    assert.match(h.posts[0].text, /^Test message from the Acme Cold \(warehouse-test\) warehouse server/);
    const checks = stub(failing('a_bad'));
    await W.runOnce(h.deps, { checks, ...NO_JOBS }); h.advance(5 * 60000); await W.runOnce(h.deps, { checks, ...NO_JOBS });
    assert.equal(await W.main(['mute', '15', 'disk_low:/mnt/my disk'], h.deps, t => out.push(t)), 0);
    assert.equal(await W.main(['mute', '15', 'not an id'], h.deps, t => out.push(t)), 1);
    out.length = 0;
    await W.main(['status'], h.deps, t => out.push(t));
    assert.match(out[0], /Firing: a_bad/); assert.match(out[0], /Slack webhook: configured/);
    assert.match(out[0], /Time zone: \S+ \(daily jobs start at 02:30/);
    assert.match(out[0], /Muted until .*: disk_low:\/mnt\/my disk/);
    assert.ok(!out[0].includes('abcDEF123456'));
  } finally { clean(h); }
});

// ---------------------------------------------------------------- timer installer
const TIMER = join(repo, 'scripts/watch-timer.sh');
function timerFixture() {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-watch-timer-'));
  const state = join(scratch, 'acme');
  for (const dir of ['', 'config', 'public']) mkdirSync(join(state, dir), { mode: 0o700 });
  writeFileSync(join(state, 'config/compose.env'), 'WAREHOUSE_PROJECT_NAME=warehouse-acme\n', { mode: 0o600 });
  writeFileSync(join(state, 'public/instance.json'), '{}\n');
  const units = join(scratch, 'units');
  const bin = join(scratch, 'bin'); mkdirSync(bin);
  const nodeDir = join(scratch, 'home/.local/opt/node-v22/bin'); mkdirSync(nodeDir, { recursive: true });
  writeFileSync(join(nodeDir, 'node'), '#!/bin/sh\necho "v${FAKE_NODE_VERSION:-22.18.0}"\n', { mode: 0o755 });
  const log = join(scratch, 'calls.log'); writeFileSync(log, '');
  writeFileSync(join(bin, 'systemctl'), '#!/bin/sh\necho "systemctl $*" >> "$FAKE_LOG"\nif [ "$1" = is-active ]; then [ "${FAKE_ACTIVE:-0}" = 1 ] && exit 0; exit 3; fi\nif [ "$1" = is-enabled ]; then echo enabled; exit 0; fi\nexit 0\n', { mode: 0o755 });
  writeFileSync(join(bin, 'id'), '#!/bin/sh\nif [ "$1" = -u ]; then echo "${FAKE_UID:-$(/usr/bin/id -u)}"; exit 0; fi\nexec /usr/bin/id "$@"\n', { mode: 0o755 });
  writeFileSync(join(bin, 'getent'), '#!/bin/sh\ncase "$1" in passwd) echo "installer:x:$2:$2::${FAKE_HOME:-/home/installer}:/bin/sh" ;; group) echo "installer:x:$2:" ;; esac\n', { mode: 0o755 });
  writeFileSync(join(bin, 'runuser'), '#!/bin/sh\nshift 3\nexec "$@"\n', { mode: 0o755 });
  writeFileSync(join(bin, 'docker'), '#!/bin/sh\nexit "${FAKE_DOCKER_EXIT:-0}"\n', { mode: 0o755 });
  const run = (args, extra = {}) => spawnSync('bash', [TIMER, ...args], { encoding: 'utf8',
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, WAREHOUSE_WATCH_UNIT_DIR: units, FAKE_LOG: log, FAKE_HOME: join(scratch, 'home'),
      SUDO_UID: String(process.getuid()), SUDO_GID: String(process.getgid()), ...extra } });
  // The units name the link ~/.local/opt/node-current (install makes it), not the versioned directory.
  const link = join(scratch, 'home/.local/opt/node-current');
  return { scratch, state, units, nodeDir, link, bin, run, asRoot: (args, extra) => run(args, { FAKE_UID: '0', ...extra }), calls: () => readFileSync(log, 'utf8') };
}

test('watch-timer.sh install writes a service and a 5-minute persistent timer for the installation user', () => {
  const f = timerFixture();
  try {
    const node = join(f.nodeDir, 'node');
    let r = f.run(['install', '--node', node]);
    assert.equal(r.status, 1); assert.match(r.stderr, /needs.*sudo|run it with sudo/);
    r = f.asRoot(['install', '--node', node], { SUDO_UID: '' });
    assert.equal(r.status, 1); assert.match(r.stderr, /SUDO_UID/);
    r = f.asRoot(['install', '--node', node, '--daily-at', '25:00']);
    assert.equal(r.status, 1); assert.match(r.stderr, /HH:MM/);
    r = f.asRoot(['install', '--node', '/nonexistent/node']);
    assert.equal(r.status, 1); assert.match(r.stderr, /Node\.js/);
    r = f.asRoot(['install', '--node', node], { FAKE_NODE_VERSION: '22.17.9' });
    assert.equal(r.status, 1); assert.match(r.stderr, /22\.18 or newer.*v22\.17\.9/);
    r = f.asRoot(['install', '--node', node], { FAKE_DOCKER_EXIT: '1' });
    assert.equal(r.status, 1); assert.match(r.stderr, /Docker does not answer for user installer/);
    assert.equal(existsSync(f.units), false, 'nothing written by the refusals');
    r = f.asRoot(['install', '--node', node, '--daily-at', '03:15']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /warehouse-acme-watch\.timer is enabled: checks every 5 minutes as installer \(it never runs a backup\)/);
    assert.match(r.stdout, /warehouse-acme-daily\.timer is enabled: the daily backup, verification and retention run at 03:15/);
    assert.match(r.stdout, /Time zone: \S+/);
    assert.match(r.stdout, new RegExp(`Node\\.js link: ${f.link} -> ${f.nodeDir.replace(/\/bin$/, '')} \\(v22\\.18\\.0\\)`));
    const service = readFileSync(join(f.units, 'warehouse-acme-watch.service'), 'utf8');
    const timer = readFileSync(join(f.units, 'warehouse-acme-watch.timer'), 'utf8');
    assert.match(service, /^Type=oneshot$/m);
    assert.match(service, /^User=installer$/m); assert.match(service, /^Group=installer$/m);
    assert.match(service, new RegExp(`^Environment=WAREHOUSE_STATE_DIR=${f.state}$`, 'm'));
    assert.doesNotMatch(service, /WAREHOUSE_WATCH_DAILY_AT/, 'the checker has no daily time: it never runs the backup');
    assert.match(service, new RegExp(`^Environment=PATH=${f.link}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin$`, 'm'));
    assert.match(service, new RegExp(`^ExecStart=${f.link}/bin/node ${repo.replace(/\/$/, '')}/scripts/watch\\.mjs run$`, 'm'));
    assert.doesNotMatch(service, /node-v22/, 'no versioned Node path in the unit');
    assert.match(service, /^After=network-online\.target docker\.service warehouse-acme-stack\.service$/m, 'ordered after the boot unit, so a boot-time run does not heal against its start');
    assert.match(service, /^TimeoutStartSec=30min$/m); assert.match(service, /^TimeoutStopSec=5min$/m);
    assert.match(timer, /^OnCalendar=\*:0\/5$/m); assert.match(timer, /^Persistent=true$/m);
    assert.match(timer, /^Unit=warehouse-acme-watch\.service$/m); assert.match(timer, /^WantedBy=timers\.target$/m);
    assert.equal(statSync(join(f.units, 'warehouse-acme-watch.timer')).mode & 0o777, 0o644);
    assert.match(f.calls(), /systemctl daemon-reload\nsystemctl enable --now warehouse-acme-watch\.timer\nsystemctl enable --now warehouse-acme-daily\.timer/);
    // The daily pass has its own service and timer: the chosen time and the 5 hours after it, persistent, 4 h limit.
    const dailyService = readFileSync(join(f.units, 'warehouse-acme-daily.service'), 'utf8');
    const dailyTimer = readFileSync(join(f.units, 'warehouse-acme-daily.timer'), 'utf8');
    assert.match(dailyService, /^Type=oneshot$/m); assert.match(dailyService, /^User=installer$/m);
    assert.match(dailyService, new RegExp(`^Environment=WAREHOUSE_STATE_DIR=${f.state}$`, 'm'));
    assert.match(dailyService, /^Environment=WAREHOUSE_WATCH_DAILY_AT=03:15$/m);
    assert.match(dailyService, new RegExp(`^Environment=PATH=${f.link}/bin:`, 'm'));
    assert.match(dailyService, new RegExp(`^ExecStart=${f.link}/bin/node ${repo.replace(/\/$/, '')}/scripts/watch\\.mjs daily$`, 'm'));
    assert.match(dailyService, /^TimeoutStartSec=4h$/m);
    assert.match(dailyService, /^After=network-online\.target docker\.service warehouse-acme-stack\.service$/m, 'a catch-up backup waits for the boot unit');
    assert.doesNotMatch(dailyService, / watch\.mjs run$/m, 'the daily unit runs daily, never run: only an old checker unit carries the time into run');
    assert.match(dailyTimer, /^OnCalendar=\*-\*-\* 03,04,05,06,07,08:15:00$/m);
    assert.match(dailyTimer, /^Persistent=true$/m); assert.match(dailyTimer, /^Unit=warehouse-acme-daily\.service$/m);
    assert.match(dailyTimer, /^WantedBy=timers\.target$/m);
    // A rerun without --daily-at keeps the installed time; with it, changes it. A midnight-crossing window wraps the hours.
    assert.equal(f.asRoot(['install', '--node', node]).status, 0);
    assert.match(readFileSync(join(f.units, 'warehouse-acme-daily.service'), 'utf8'), /^Environment=WAREHOUSE_WATCH_DAILY_AT=03:15$/m);
    assert.equal(f.asRoot(['install', '--node', node, '--daily-at', '04:00']).status, 0);
    assert.match(readFileSync(join(f.units, 'warehouse-acme-daily.service'), 'utf8'), /^Environment=WAREHOUSE_WATCH_DAILY_AT=04:00$/m);
    assert.equal(f.asRoot(['install', '--node', node, '--daily-at', '22:30']).status, 0);
    assert.match(readFileSync(join(f.units, 'warehouse-acme-daily.timer'), 'utf8'), /^OnCalendar=\*-\*-\* 22,23,00,01,02,03:30:00$/m);
    // An install from before the daily unit kept the time in the checker's service: a rerun still finds it.
    rmSync(join(f.units, 'warehouse-acme-daily.service'));
    writeFileSync(join(f.units, 'warehouse-acme-watch.service'), readFileSync(join(f.units, 'warehouse-acme-watch.service'), 'utf8').replace('Environment=PATH', 'Environment=WAREHOUSE_WATCH_DAILY_AT=05:45\nEnvironment=PATH'));
    assert.equal(f.asRoot(['install', '--node', node]).status, 0);
    assert.match(readFileSync(join(f.units, 'warehouse-acme-daily.service'), 'utf8'), /^Environment=WAREHOUSE_WATCH_DAILY_AT=05:45$/m);
    // An installed unit that names another state (same project name) is refused.
    const other = join(f.scratch, 'elsewhere/acme');
    for (const dir of ['', 'config', 'public']) mkdirSync(join(f.scratch, 'elsewhere', dir ? `acme/${dir}` : 'acme'), { recursive: true, mode: 0o700 });
    writeFileSync(join(other, 'config/compose.env'), 'WAREHOUSE_PROJECT_NAME=warehouse-acme\n', { mode: 0o600 }); writeFileSync(join(other, 'public/instance.json'), '{}\n');
    r = f.asRoot(['install', '--node', node, '--state', other]);
    assert.equal(r.status, 1); assert.match(r.stderr, /already belongs to another state/);
    assert.match(readFileSync(join(f.units, 'warehouse-acme-watch.service'), 'utf8'), new RegExp(`STATE_DIR=${f.state}$`, 'm'));
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-timer.sh also writes a boot unit that starts stopped containers after docker.service, never recreates or builds; status, hint and uninstall know it', () => {
  const f = timerFixture();
  try {
    const node = join(f.nodeDir, 'node');
    const r = f.asRoot(['install', '--node', node]);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /warehouse-acme-stack\.service is enabled: the services start at boot/);
    const stack = readFileSync(join(f.units, 'warehouse-acme-stack.service'), 'utf8');
    assert.match(stack, /^Wants=docker\.service$/m); assert.match(stack, /^After=docker\.service$/m);
    assert.doesNotMatch(stack, /^Requires=/m, 'a restart of Docker must not run the unit again');
    assert.match(stack, new RegExp(`^ConditionPathExists=!${f.state}/config/stopped-by-operator$`, 'm'), 'a stop the operator asked for survives a reboot');
    assert.match(stack, /^Type=oneshot$/m); assert.match(stack, /^RemainAfterExit=yes$/m);
    assert.match(stack, /^User=installer$/m); assert.match(stack, /^Group=installer$/m);
    assert.match(stack, new RegExp(`^Environment=WAREHOUSE_STATE_DIR=${f.state}$`, 'm'));
    assert.match(stack, new RegExp(`^WorkingDirectory=${repo.replace(/\/$/, '')}$`, 'm'));
    assert.match(stack, new RegExp(`^ExecStart=/bin/bash ${repo.replace(/\/$/, '')}/scripts/compose\\.sh up -d --no-build --no-recreate$`, 'm'));
    assert.match(stack, /^WantedBy=multi-user\.target$/m);
    assert.doesNotMatch(stack, /--profile|--remove-orphans/, 'the default profile only');
    assert.equal(statSync(join(f.units, 'warehouse-acme-stack.service')).mode & 0o777, 0o644);
    assert.match(f.calls(), /systemctl enable warehouse-acme-stack\.service\n/);
    assert.doesNotMatch(f.calls(), /enable --now warehouse-acme-stack/, 'install does not start the stack');
    assert.match(f.run(['status']).stdout, /Boot unit: warehouse-acme-stack\.service is installed \(enabled\)/);
    assert.equal(f.run(['hint']).stdout, '', 'complete: silent');
    // An install from before the boot unit existed: hint asks for a refresh and says what is missing.
    rmSync(join(f.units, 'warehouse-acme-stack.service'));
    const old = f.run(['hint']).stdout;
    assert.match(old, /these are missing: the unit that starts the services at boot[^]*power cut[^]*install --state /);
    assert.doesNotMatch(old, /daily backup timer/, 'only what is missing is named');
    assert.match(f.run(['status']).stdout, /Boot unit: warehouse-acme-stack\.service is not installed/);
    f.asRoot(['install', '--node', node]);
    const gone = f.asRoot(['uninstall']);
    assert.equal(gone.status, 0, gone.stderr);
    assert.match(gone.stdout, /Removed warehouse-acme-watch\.timer, warehouse-acme-watch\.service, warehouse-acme-daily\.timer, warehouse-acme-daily\.service and warehouse-acme-stack\.service/);
    assert.deepEqual(readdirSync(f.units), []);
    assert.match(f.calls(), /systemctl disable warehouse-acme-stack\.service/);
    assert.match(f.calls(), /systemctl disable --now warehouse-acme-watch\.timer warehouse-acme-daily\.timer/);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-timer.sh: the units name a Node.js link that install moves, so a Node upgrade needs no new unit; hint and status say when the Node.js is gone', () => {
  const f = timerFixture();
  try {
    const v22 = join(f.nodeDir, 'node');
    assert.equal(f.asRoot(['install', '--node', v22]).status, 0);
    assert.equal(readlinkSync(f.link), f.nodeDir.replace(/\/bin$/, ''));
    const before = readFileSync(join(f.units, 'warehouse-acme-watch.service'), 'utf8');
    // Node.js 24 is unpacked next to it and install is run with it: only the link moves, the units are byte for byte the same.
    const v24dir = join(f.scratch, 'home/.local/opt/node-v24/bin'); mkdirSync(v24dir, { recursive: true });
    writeFileSync(join(v24dir, 'node'), '#!/bin/sh\necho v24.1.0\n', { mode: 0o755 });
    const up = f.asRoot(['install', '--node', join(v24dir, 'node')]);
    assert.equal(up.status, 0, up.stderr);
    assert.equal(readlinkSync(f.link), join(f.scratch, 'home/.local/opt/node-v24'));
    assert.match(up.stdout, /\(v24\.1\.0\)/);
    assert.equal(readFileSync(join(f.units, 'warehouse-acme-watch.service'), 'utf8'), before);
    // Naming the link itself (as an operator who knows it might) gives the same link, not a loop.
    assert.equal(f.asRoot(['install', '--node', join(f.link, 'bin/node')]).status, 0);
    assert.equal(readlinkSync(f.link), join(f.scratch, 'home/.local/opt/node-v24'));
    assert.match(f.run(['status']).stdout, new RegExp(`Node\\.js: ${f.link}/bin/node \\(v24\\.1\\.0\\)`));
    assert.equal(f.run(['hint']).stdout, '', 'link and target are fine: silent');
    // The old Node.js directory is tidied away, and then the new one too: the link points nowhere.
    rmSync(join(f.scratch, 'home/.local/opt/node-v22'), { recursive: true });
    assert.equal(f.run(['hint']).stdout, '', 'the link does not point at the removed directory');
    rmSync(join(f.scratch, 'home/.local/opt/node-v24'), { recursive: true });
    const gone = f.run(['hint']).stdout;
    assert.match(gone, new RegExp(`the Node\\.js it runs is gone \\(${f.link}/bin/node - the link ${f.link} points at ${join(f.scratch, 'home/.local/opt/node-v24')}, which is not there\\)`));
    assert.match(gone, /No check, Slack alert, daily backup or retention runs[^]*install --state \S+ --node \/absolute\/path\/to\/node/);
    assert.match(f.run(['status']).stdout, /Node\.js: \S+\/bin\/node is MISSING - the link/);
    // A link path that is a real directory is never replaced; a node outside a bin/ directory is named as it is.
    const dir = join(f.scratch, 'home/.local/opt/node-current'); rmSync(dir); mkdirSync(dir);
    const v26dir = join(f.scratch, 'home/.local/opt/node-v26/bin'); mkdirSync(v26dir, { recursive: true });
    writeFileSync(join(v26dir, 'node'), '#!/bin/sh\necho v26.0.0\n', { mode: 0o755 });
    let r = f.asRoot(['install', '--node', join(v26dir, 'node')]);
    assert.equal(r.status, 1); assert.match(r.stderr, /exists and is not a link/);
    rmSync(dir, { recursive: true });
    const flat = join(f.scratch, 'flat'); mkdirSync(flat);
    writeFileSync(join(flat, 'node'), '#!/bin/sh\necho v22.18.0\n', { mode: 0o755 });
    r = f.asRoot(['install', '--node', join(flat, 'node')]);
    assert.equal(r.status, 0, r.stderr); assert.match(r.stderr, /not in a bin\/ directory/);
    assert.match(readFileSync(join(f.units, 'warehouse-acme-watch.service'), 'utf8'), new RegExp(`^ExecStart=${join(flat, 'node')} `, 'm'));
    assert.equal(existsSync(f.link), false);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-timer.sh: the Node.js link is moved only after the new prefix is shown to give a usable Node.js; a refusal leaves the link and the units as they were', () => {
  const f = timerFixture();
  try {
    const v22 = join(f.nodeDir, 'node');
    assert.equal(f.asRoot(['install', '--node', v22]).status, 0);
    const before = readFileSync(join(f.units, 'warehouse-acme-watch.service'), 'utf8');
    // A node whose file is not called node: its prefix has no bin/node, so the link would point at a prefix that gives nothing.
    const odd = join(f.scratch, 'home/.local/opt/node-odd/bin'); mkdirSync(odd, { recursive: true });
    writeFileSync(join(odd, 'node22'), '#!/bin/sh\necho v22.18.0\n', { mode: 0o755 });
    const r = f.asRoot(['install', '--node', join(odd, 'node22')]);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /node-odd\/bin\/node does not give Node\.js 22\.18 or newer \(nothing\); the Node\.js link .* was not changed\./);
    assert.equal(readlinkSync(f.link), f.nodeDir.replace(/\/bin$/, ''), 'the link still points at the Node.js that works');
    assert.equal(readFileSync(join(f.units, 'warehouse-acme-watch.service'), 'utf8'), before, 'the units are untouched');
    assert.equal(f.run(['hint']).stdout, '', 'the installation is still fine');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-timer.sh: a checker unit from before the split (it carries the daily time) is said to still make the backup, with the command to refresh it; install warns while it runs', () => {
  const f = timerFixture();
  try {
    const node = join(f.nodeDir, 'node');
    assert.equal(f.asRoot(['install', '--node', node]).status, 0);
    // What an installation from before the split has: the checker unit with the daily time, no daily unit, no boot unit.
    for (const unit of ['warehouse-acme-daily.timer', 'warehouse-acme-daily.service', 'warehouse-acme-stack.service']) rmSync(join(f.units, unit));
    const svc = join(f.units, 'warehouse-acme-watch.service');
    writeFileSync(svc, readFileSync(svc, 'utf8').replace('Environment=PATH', 'Environment=WAREHOUSE_WATCH_DAILY_AT=02:30\nEnvironment=PATH'));
    const command = `sudo bash ${repo.replace(/\/$/, '')}/scripts/watch-timer.sh install --state ${f.state}`;
    const hint = f.run(['hint']).stdout;
    assert.match(hint, /is from before the daily backup got its own timer\. The backup still runs from it, so backups continue, but a long backup holds the 5-minute checks off/);
    assert.ok(hint.includes(`  ${command}`), hint);
    assert.doesNotMatch(hint, /none is made|no backup/, 'it does not say the backup stopped: it did not');
    const status = f.run(['status']).stdout;
    assert.match(status, /Daily backup: still made by the old checker unit, inside its 5-minute run \(at 02:30\); backups continue, but a long one holds the checks off\. Run: sudo bash \S+\/watch-timer\.sh install --state /);
    assert.match(status, /Daily timer: warehouse-acme-daily\.timer is not installed; the backup runs from the old checker unit until: sudo bash /);
    assert.doesNotMatch(status, /no backup runs/);
    // The install: a warning only while the old unit is running (it may be in the middle of the backup); the time is kept.
    let r = f.asRoot(['install', '--node', node]);
    assert.equal(r.status, 0, r.stderr);
    assert.doesNotMatch(r.stderr, /is running now/);
    assert.match(readFileSync(join(f.units, 'warehouse-acme-daily.service'), 'utf8'), /^Environment=WAREHOUSE_WATCH_DAILY_AT=02:30$/m);
    assert.doesNotMatch(readFileSync(svc, 'utf8'), /WAREHOUSE_WATCH_DAILY_AT/, 'the new checker unit does not carry the daily time: run makes no backup');
    assert.equal(f.run(['hint']).stdout, '', 'reinstalled: silent');
    writeFileSync(svc, readFileSync(svc, 'utf8').replace('Environment=PATH', 'Environment=WAREHOUSE_WATCH_DAILY_AT=02:30\nEnvironment=PATH'));
    r = f.asRoot(['install', '--node', node], { FAKE_ACTIVE: '1' });
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stderr, /Warning: warehouse-acme-watch\.service is running now, and this old unit makes the daily backup inside its run\. Installing now can cut that backup short\./);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-timer.sh: while config/stopped-by-operator exists, hint and status say the stack was stopped by the operator and name start.sh', () => {
  const f = timerFixture();
  try {
    assert.equal(f.asRoot(['install', '--node', join(f.nodeDir, 'node')]).status, 0);
    assert.equal(f.run(['hint']).stdout, '');
    writeFileSync(join(f.state, 'config/stopped-by-operator'), 'stopped by stop.sh\n');
    assert.match(f.run(['hint']).stdout, /^The stack was stopped by the operator \(config\/stopped-by-operator\): nothing restarts it, not even a reboot, until you run start\.sh\.\n$/);
    assert.match(f.run(['status']).stdout, /Stack: stopped by the operator \(config\/stopped-by-operator\); the boot unit does nothing until start\.sh removes that file\. Run: bash start\.sh/);
    rmSync(join(f.state, 'config/stopped-by-operator'));
    assert.equal(f.run(['hint']).stdout, '');
    assert.doesNotMatch(f.run(['status']).stdout, /stopped by the operator/);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-timer.sh hint: an install from before the daily timer asks for a refresh, because the checker no longer makes the backup', () => {
  const f = timerFixture();
  try {
    f.asRoot(['install', '--node', join(f.nodeDir, 'node')]);
    rmSync(join(f.units, 'warehouse-acme-daily.timer')); rmSync(join(f.units, 'warehouse-acme-daily.service'));
    const out = f.run(['hint']).stdout;
    assert.match(out, /these are missing: the daily backup timer \(the checker no longer makes the backup, so none is made without it\)\. Refresh it/);
    assert.doesNotMatch(out, /boot/, 'the boot unit is there');
    assert.match(f.run(['status']).stdout, /Daily timer: warehouse-acme-daily\.timer is not installed: no backup runs/);
    rmSync(join(f.units, 'warehouse-acme-stack.service'));
    assert.match(f.run(['hint']).stdout, /daily backup timer[^]*; the unit that starts the services at boot/);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-timer.sh refuses an unsafe checkout path and unsafe state paths', () => {
  const f = timerFixture();
  try {
    const odd = join(f.scratch, 'my checkout');
    mkdirSync(join(odd, 'scripts'), { recursive: true });
    copyFileSync(TIMER, join(odd, 'scripts/watch-timer.sh'));
    const node = join(f.nodeDir, 'node');
    const env = { ...process.env, PATH: `${f.bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: f.state, WAREHOUSE_WATCH_UNIT_DIR: f.units, FAKE_LOG: join(f.scratch, 'calls.log'), FAKE_UID: '0',
      SUDO_UID: String(process.getuid()), SUDO_GID: String(process.getgid()) };
    let r = spawnSync('bash', [join(odd, 'scripts/watch-timer.sh'), 'install', '--node', node], { encoding: 'utf8', env });
    assert.equal(r.status, 1); assert.match(r.stderr, /checkout path must be an absolute path/);
    for (const state of ['relative/acme', `${f.state} x`, `${f.state}$(id)`]) {
      r = f.asRoot(['install', '--node', node, '--state', state]);
      assert.equal(r.status, 1, state); assert.match(r.stderr, /state path must be an absolute path|Set WAREHOUSE_STATE_DIR/);
    }
    assert.equal(existsSync(f.units), false);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-timer.sh prints its usage including the install line', () => {
  const f = timerFixture();
  try {
    for (const args of [[], ['bogus'], ['install', '--wrong']]) {
      const r = f.asRoot(args);
      assert.equal(r.status, 1);
      assert.match(r.stderr, /watch-timer\.sh install \[--state DIR\] \[--node PATH\] \[--daily-at HH:MM\]/);
      assert.match(r.stderr, /watch-timer\.sh uninstall/); assert.match(r.stderr, /watch-timer\.sh status/);
    }
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-timer.sh status and uninstall', () => {
  const f = timerFixture();
  try {
    assert.match(f.run(['status']).stdout, /warehouse-acme-watch\.timer is not installed/);
    f.asRoot(['install', '--node', join(f.nodeDir, 'node')]);
    const status = f.run(['status']).stdout;
    assert.match(status, /is installed for .*acme/); assert.match(status, /Time zone: \S+/);
    let r = f.run(['uninstall']); assert.equal(r.status, 1); assert.match(r.stderr, /sudo/);
    r = f.asRoot(['uninstall'], { FAKE_ACTIVE: '1' });
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(readdirSync(f.units), []);
    assert.match(f.calls(), /systemctl disable --now warehouse-acme-watch\.timer/);
    assert.match(f.calls(), /systemctl is-active --quiet warehouse-acme-watch\.service\nsystemctl stop warehouse-acme-watch\.service/);
    assert.match(f.calls(), /systemctl reset-failed warehouse-acme-watch\.service warehouse-acme-watch\.timer/);
    assert.equal(f.run(['bogus']).status, 1);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-timer.sh hint prints the install command until the timer is installed for this state, and then says nothing', () => {
  const f = timerFixture();
  try {
    const before = f.run(['hint']);
    assert.equal(before.status, 0);
    assert.match(before.stdout, /timer is not installed for .*acme/);
    assert.match(before.stdout, new RegExp(`sudo bash \\S+/scripts/watch-timer\\.sh install --state ${f.state.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`));
    assert.equal(before.stdout.includes('sudo'), true);
    f.asRoot(['install', '--node', join(f.nodeDir, 'node')]);
    const after = f.run(['hint']);
    assert.equal(after.status, 0);
    assert.equal(after.stdout, '', 'installed: silent');
    assert.equal(f.run(['hint', 'extra']).status, 1);
    // A unit that runs another checkout (moved or replaced): hint says to refresh it, once.
    const svc = join(f.units, 'warehouse-acme-watch.service');
    writeFileSync(svc, readFileSync(svc, 'utf8').replace(/^WorkingDirectory=.*$/m, 'WorkingDirectory=/old/checkout'));
    const moved = f.run(['hint']);
    assert.equal(moved.status, 0);
    assert.match(moved.stdout, /installed for .*acme.* but runs another checkout[^]*Refresh it[^]*install --state /);
    // The unit does not depend on the directory name: another install that also ends in /acme gets its own unit.
    const other = join(f.scratch, 'elsewhere/acme');
    for (const dir of ['', '/config', '/public']) mkdirSync(other + dir, { recursive: true, mode: 0o700 });
    writeFileSync(join(other, 'config/compose.env'), 'WAREHOUSE_PROJECT_NAME=warehouse-bravo\n');
    assert.match(f.run(['hint'], { WAREHOUSE_STATE_DIR: other }).stdout, /not installed for .*elsewhere\/acme/);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-timer.sh uninstall accepts the state path by its shape, even when the state directory is gone', () => {
  const f = timerFixture();
  try {
    f.asRoot(['install', '--node', join(f.nodeDir, 'node')]);
    const gone = f.state; rmSync(f.state, { recursive: true, force: true });
    delete process.env.WAREHOUSE_STATE_DIR;
    let r = f.asRoot(['uninstall', '--state', 'relative/acme']);
    assert.equal(r.status, 1); assert.match(r.stderr, /state path must be an absolute path/);
    r = f.asRoot(['uninstall', '--state', gone]);
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(readdirSync(f.units), []);
    assert.doesNotMatch(f.calls(), /systemctl stop/, 'not active: not stopped');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('containers: an id gone between ps and inspect is skipped; any other inspect error names its cause', () => {
  const h = harness();
  const [first, second] = h.services.map(idOf);
  h.runs['docker inspect'] = () => ({ status: 1, stdout: `${first}|${h.services[0]}|running||0|false|2026-10-18T00:00:00Z|False\n`,
    stderr: `Error: No such object: ${second}\n` });
  const list = h.ctx().containers();
  assert.deepEqual(list.map(c => c.id), [first]);
  const h2 = harness();
  h2.runs['docker inspect'] = () => bad('permission denied while trying to connect to the docker API');
  assert.throws(() => h2.ctx().containers(), /docker inspect failed: permission denied/);
});
