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
const SERVICES = ['db', 'kong', 'rest', 'storage', 'functions', 'pdf-renderer'];
const idOf = name => Buffer.from(name.padEnd(6, '_')).toString('hex').slice(0, 12).padEnd(12, '0');
const ok = (stdout = '') => ({ status: 0, stdout, stderr: '' });
const bad = (stderr = 'failed') => ({ status: 1, stdout: '', stderr });

// A scratch installation: state directory, fake /proc and cgroup trees, a clock and a recorder for posts.
function harness({ webhook = true, dailyAt = '02:30', heartbeatAt = '09:00' } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-watch-'));
  const state = join(scratch, 'acme');
  for (const dir of ['', 'config', 'public', 'backups']) mkdirSync(join(state, dir), { recursive: true, mode: 0o700 });
  writeFileSync(join(state, 'config/compose.env'), 'WAREHOUSE_PROJECT_NAME=warehouse-test\nKONG_HTTP_PORT=18000\nPOSTGRES_PASSWORD=supersecretpassword123\n', { mode: 0o600 });
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
    if (command === 'docker' && args[0] === 'inspect') return ok(args.slice(3).map(id => { const name = h.services.find(s => idOf(s) === id); return `${id}|${name}|${h.stateOf?.[name] ?? `running|${['db', 'kong'].includes(name) ? 'healthy' : ''}`}|0|false|2026-10-18T00:00:00Z|False`; }).join('\n'));
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
    cgroupFor(h, 'kong', { current: 1000, max: 1000, inactive: 99 });
    let r = W.checkContainerMemory(h.ctx());
    assert.equal(find(r, 'container_memory:rest').ok, true);
    assert.equal(find(r, 'container_memory:kong').ok, false);
    assert.equal(find(r, 'container_memory:db'), undefined);
    cgroupFor(h, 'rest', { current: 901, max: 1000 });
    assert.equal(find(W.checkContainerMemory(h.ctx()), 'container_memory:rest').ok, false);
    cgroupFor(h, 'kong', { current: 1000, max: 1000, inactive: 100 });
    assert.equal(find(W.checkContainerMemory(h.ctx()), 'container_memory:kong').ok, true);
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
      if (command === 'docker' && args[0] === 'inspect') return ok(r.stdout.split('\n').filter(l => !l.includes('|pdf-renderer|')).map(l => l.replace('|kong|running|healthy', '|kong|running|unhealthy').replace('|rest|running|', '|rest|exited|')).join('\n'));
      return r;
    };
    const failed = W.checkServices(h.ctx()).filter(x => !x.ok).map(x => x.id).sort();
    assert.deepEqual(failed, ['service_down:kong', 'service_down:pdf-renderer', 'service_down:rest']);
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

// The line is built from the gateway's own log format in docker/docker-compose.yml, so a change there fails this test.
const composeText = readFileSync(join(repo, 'docker/docker-compose.yml'), 'utf8');
const logFormat = (composeText.match(/KONG_NGINX_HTTP_LOG_FORMAT: "warehouse_redacted '([^\n]*)'"/) ?? [])[1];
assert.ok(logFormat, 'KONG_NGINX_HTTP_LOG_FORMAT is in the compose file');
const kongLine = (status, seconds) => {
  const values = { remote_addr: '172.18.0.1', time_local: '19/Oct/2026:10:00:00 +0000', request_method: 'GET', uri: '/rest/v1/x', server_protocol: 'HTTP/1.1', status: String(status), body_bytes_sent: '123', request_time: seconds };
  return logFormat.replace(/\\"/g, '"').replace(/\$\$([a-z_]+)/g, (_, name) => { if (!(name in values)) throw new Error(`unknown log variable ${name}`); return values[name]; });
};
test('the Kong test line is in the shape the compose log format produces', () => {
  assert.equal(kongLine(200, '0.100'), '172.18.0.1 [19/Oct/2026:10:00:00 +0000] "GET /rest/v1/x HTTP/1.1" 200 123 0.100');
  assert.equal(W.parseKongLog(kongLine(502, '1.500')).length, 1);
});
test('API logs: 5xx share above 5% and p95 latency above 2 s, from the last 5 minutes; small samples are not judged', () => {
  const h = harness();
  try {
    const logs = lines => { h.runs['docker logs'] = ok(lines.join('\n')); return W.checkApiLogs(h.ctx()); };
    const mix = (errors, slow, total = 20) => Array.from({ length: total }, (_, i) => kongLine(i < errors ? 500 : 200, i < slow ? '3.000' : '0.100'));
    let r = logs(mix(1, 1));
    assert.equal(find(r, 'api_error_rate_high').ok, true, '1 of 20 is 5%');
    assert.equal(find(r, 'api_latency_p95_high').ok, true, '1 slow of 20 leaves p95 fast');
    r = logs(mix(2, 2));
    assert.equal(find(r, 'api_error_rate_high').ok, false);
    assert.equal(find(r, 'api_latency_p95_high').ok, false);
    r = logs(Array.from({ length: 20 }, () => kongLine(200, '2.000')));
    assert.equal(find(r, 'api_latency_p95_high').ok, true, '2.000 s is the limit');
    r = logs(Array.from({ length: 20 }, () => kongLine(200, '2.010')));
    assert.equal(find(r, 'api_latency_p95_high').ok, false);
    r = logs(mix(5, 5, 5));
    assert.equal(r.every(x => x.ok), true, 'fewer than 10 requests');
    assert.ok(h.calls.some(c => c.includes('docker logs --since 5m ' + idOf('kong'))));
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
      ...SERVICES.map(name => `Service ${name} is running${['db', 'kong'].includes(name) ? ' healthy' : ''}`),
      'PostgreSQL accepts connections', 'REST: answers through the gateway', 'configuration: answers through the gateway', 'PDF renderer reachable from functions',
    ]);
    // The probe runs in the storage container (a network shared with Kong), waits as long as it was told, asks the RPC get_public_config with the
    // public key (the OpenAPI document at /rest/v1/ is off) and asks for the public configuration.
    assert.equal(inputs.length, 1);
    assert.match(inputs[0], /export async function waitForHttp/);
    assert.match(inputs[0], /const WAIT_MS = 7000;/);
    assert.match(inputs[0], /http:\/\/kong:8000\/rest\/v1\/rpc\/get_public_config', \{ apikey: process\.env\.ANON_KEY, 'Content-Type': 'application\/json' \},\n    \{ method: 'POST', body: JSON\.stringify\(\{ p_environment: 'production' \}\) \}/);
    assert.match(inputs[0], /http:\/\/kong:8000\/functions\/v1\/get-public-config/);
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
    assert.equal(h.posts.length, 0);
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
    if (s.verify && s.verify !== 'ok' || backup !== 'ok') { fields.prune = 'skipped'; fields.retention = 'skipped'; }
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
    assert.equal(s.lastDailyRun.retention.result, 'skipped');
    assert.match(s.lastDailyRun.retention.message, /today's backup failed/);
    assert.equal(existsSync(join(h.state, 'config/watch-retention.last')), false, 'retention was not run and records no result');
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

test('daily: a backup that fails verification is a failure; nothing is pruned and retention is skipped', async () => {
  const h = harness();
  try {
    h.seed(); dailyFake(h, { verify: 'failed', verify_message: 'Backup signature mismatch' });
    h.clock.t = at(19, 3, 0); await daily(h);
    const run = h.state_().lastDailyRun;
    assert.equal(run.backup.result, 'failed');
    assert.match(run.backup.message, /was made but verification failed: Backup signature mismatch/);
    assert.equal(run.retention.result, 'skipped');
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
    const timed = W.interpretDaily(ctx, { status: 143, stdout: '', stderr: '', timedOut: true }, {});
    assert.match(timed.backup.message, /timed out/);
    assert.equal(W.interpretDaily(ctx, { status: 75, stdout: '', stderr: '' }, { lock: 'held', done: '1' }).skipped, 'operator lock is held');
    // And through a whole run: a crash of the runner is a failure, and dailyRunning is cleared.
    h.seed(); h.clock.t = at(19, 3, 0);
    await W.runDailyCommand(h.deps, { checks: HEALTHY, daily: async () => { throw new Error('spawn exploded'); } });
    assert.match(h.state_().lastDailyRun.backup.message, /the daily run crashed: spawn exploded/);
    assert.equal(h.state_().dailyRunning, null);
  } finally { clean(h); }
});

test('daily: an interrupted pass (dailyRunning left in the state) blocks for less than 4 hours, then is stale; a clock step back clears it', async () => {
  const h = harness();
  try {
    h.clock.t = at(19, 6, 0);
    dailyFake(h);
    h.seed({ dailyRunning: { job: 'daily', startedAt: at(19, 6, 0) - (4 * HOUR - 1000) } });
    await daily(h);
    assert.equal(h.dailyCalls, 0, 'still inside 4 hours: assumed running');
    h.seed({ dailyRunning: { job: 'daily', startedAt: at(19, 6, 0) - 4 * HOUR } });
    await daily(h);
    assert.equal(h.dailyCalls, 1, '4 hours or more: stale, cleared, run');
    assert.equal(h.state_().dailyRunning, null);
    h.seed({ dailyRunning: { job: 'daily', startedAt: at(19, 6, 0) + 3 * HOUR } });
    h.clock.t = at(19, 6, 30); await W.runDailyCommand(h.deps, { checks: HEALTHY });
    assert.equal(h.state_().dailyRunning, null, 'a start time in the future is stale');
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
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('watch-daily.sh: an unhealthy database is skipped; a failed backup skips retention; a failed verify skips prune and retention', () => {
  const f = dailyScriptFixture();
  try {
    let r = f.run({ FAKE_BACKUP: 'unhealthy' });
    assert.equal(r.status, 0);
    assert.deepEqual([r.fields.backup, r.fields.verify, r.fields.retention, r.fields.done], ['skipped', 'skipped', 'skipped', '1']);
    assert.match(r.fields.backup_message, /not healthy/);
    assert.deepEqual(r.log.filter(l => /verify|retention/.test(l)), []);
    writeFileSync(join(f.root, 'order.reset'), ''); fs.writeFileSync(join(f.scratch, 'order.log'), '');
    r = f.run({ FAKE_BACKUP: 'fail' });
    assert.deepEqual([r.fields.backup, r.fields.verify, r.fields.retention], ['failed', 'skipped', 'skipped']);
    assert.match(r.fields.backup_message, /pg_dump: error: boom/);
    assert.match(r.fields.retention_message, /today's backup failed/);
    fs.writeFileSync(join(f.scratch, 'order.log'), '');
    r = f.run({ FAKE_VERIFY: 'bad' });
    assert.deepEqual([r.fields.backup, r.fields.verify, r.fields.prune, r.fields.retention], ['ok', 'failed', 'skipped', 'skipped']);
    assert.match(r.fields.verify_message, /signature mismatch/);
    assert.equal(r.log.some(l => l.startsWith('retention')), false);
    fs.writeFileSync(join(f.scratch, 'order.log'), '');
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
    assert.equal(r.fields.retention, 'skipped');
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

test('prune-backups command prints removed= and note= and protects the path it is given', async () => {
  const h = harness();
  try {
    const names = Array.from({ length: 8 }, (_, i) => `warehouse-202610${String(10 + i).padStart(2, '0')}T020000Z`);
    for (const n of names) addBackup(h, n);
    const out = [];
    assert.equal(await W.main(['prune-backups', join(h.state, 'backups', names[7])], h.deps, t => out.push(t)), 0);
    assert.equal(out[0], `removed=1\nnote=`);
    assert.equal(await W.main(['prune-backups'], h.deps, t => out.push(t)), 1);
  } finally { clean(h); }
});

// ---------------------------------------------------------------- self-healing
const healCalls = h => h.calls.filter(c => /compose\.sh (up|restart) /.test(c)).map(c => c.replace(/^bash \S+\/scripts\//, ''));
const healRun = h => W.runOnce(h.deps, { checks: HEALTHY, ...NO_JOBS });
test('self-heal: an exited service is started again (no recreate), at most once an hour, and the action is an alert that fires at once', async () => {
  const h = harness();
  try {
    h.seed(); h.stateOf = { rest: 'exited|' };
    h.runs['compose.sh up -d --no-recreate rest'] = ok();
    await healRun(h);
    assert.deepEqual(healCalls(h), ['compose.sh up -d --no-recreate rest']);
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
      d.seed(); d.stateOf = { db: 'exited|' }; d.runs['compose.sh up -d --no-recreate db'] = ok();
      await healRun(d);
      assert.deepEqual(healCalls(d), ['compose.sh up -d --no-recreate db']);
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
    h.runs['compose.sh up -d --no-recreate storage'] = bad('no such image password=supersecretpassword123');
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
    assert.match(service, /^After=network-online\.target docker\.service$/m);
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

test('watch-timer.sh also writes a boot unit that runs compose up after docker.service; status, hint and uninstall know it', () => {
  const f = timerFixture();
  try {
    const node = join(f.nodeDir, 'node');
    const r = f.asRoot(['install', '--node', node]);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /warehouse-acme-stack\.service is enabled: the services start at boot/);
    const stack = readFileSync(join(f.units, 'warehouse-acme-stack.service'), 'utf8');
    assert.match(stack, /^Requires=docker\.service$/m); assert.match(stack, /^After=docker\.service$/m);
    assert.match(stack, /^Type=oneshot$/m); assert.match(stack, /^RemainAfterExit=yes$/m);
    assert.match(stack, /^User=installer$/m); assert.match(stack, /^Group=installer$/m);
    assert.match(stack, new RegExp(`^Environment=WAREHOUSE_STATE_DIR=${f.state}$`, 'm'));
    assert.match(stack, new RegExp(`^WorkingDirectory=${repo.replace(/\/$/, '')}$`, 'm'));
    assert.match(stack, new RegExp(`^ExecStart=/bin/bash ${repo.replace(/\/$/, '')}/scripts/compose\\.sh up -d --no-build$`, 'm'));
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
