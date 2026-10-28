// Maintenance mode on the host side: scripts/maintenance.sh (on, off, status) against a fake docker, and the marker config/maintenance that
// scripts/compose.sh turns into WAREHOUSE_MAINTENANCE=upgrading for every Compose command. What the gateway does with the word is tested in
// tests/gateway-config.test.mjs and, on the real image, tests/gateway-nginx.test.mjs; how upgrade.sh uses the script in tests/upgrade.test.mjs.
// No Docker, no network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, statSync, existsSync, symlinkSync, cpSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configure } from '../scripts/configure.mjs';

const repo = new URL('..', import.meta.url).pathname;

// Every docker call is logged with the WAREHOUSE_MAINTENANCE it saw ("unset" when the variable was not in its environment). Behaviours:
// FAKE_STOPPED=yes (the gateway does not run), FAKE_LAN=yes (gateway-lan runs until it is stopped), FAKE_LAN_STUCK=yes (it cannot be stopped),
// FAKE_FAIL_UP=gateway|gateway-lan (that service does not come up), FAKE_FAIL_RM=gateway (`rm -sf gateway` does nothing: the container stays),
// a `stop` of a gateway fails the test: maintenance.sh must remove, never merely stop,
// FAKE_GW_EXITED=yes / FAKE_LAN_EXITED=yes (a container exists but is not running: ps -aq lists it, ps -q does not), and removal is remembered:
// after `rm -sf <service>` no container is listed until an `up` of it creates one again.
// FAKE_GATEWAY_WORD / FAKE_LAN_WORD (the WAREHOUSE_MAINTENANCE a container was created with, for `status`).
const fakeDocker = `#!/bin/sh
printf '%s|%s\\n' "\${WAREHOUSE_MAINTENANCE-unset}" "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  ps) exit 0 ;;
  inspect)
    case "$*" in
      *'.Config.Env'*) case "$*" in *gwlan*) w="\${FAKE_LAN_WORD:-}" ;; *) w="\${FAKE_GATEWAY_WORD:-}" ;; esac
        printf 'PATH=/usr/bin\\n'; [ -z "$w" ] || printf 'WAREHOUSE_MAINTENANCE=%s\\n' "$w" ;;
      *) echo true ;;
    esac; exit 0 ;;
  compose)
    case "$*" in
      *' ps -q gateway-lan') if [ "\${FAKE_LAN:-}" = yes ] && { [ ! -e "$FAKE_DOCKER_LOG.lan-stopped" ] || [ "\${FAKE_LAN_STUCK:-}" = yes ]; }; then echo gwlan0000000; fi; exit 0 ;;
      *' ps -aq gateway-lan') if { [ "\${FAKE_LAN:-}" = yes ] || [ "\${FAKE_LAN_EXITED:-}" = yes ]; } && { [ ! -e "$FAKE_DOCKER_LOG.lan-stopped" ] || [ "\${FAKE_LAN_STUCK:-}" = yes ]; }; then echo gwlan0000000; fi; exit 0 ;;
      *' ps -q gateway') if [ "\${FAKE_STOPPED:-}" = yes ] || [ "\${FAKE_GW_EXITED:-}" = yes ] || [ -e "$FAKE_DOCKER_LOG.gw-removed" ]; then exit 0; fi; echo gateway00000; exit 0 ;;
      *' ps -aq gateway') if [ "\${FAKE_STOPPED:-}" = yes ] || [ -e "$FAKE_DOCKER_LOG.gw-removed" ]; then exit 0; fi; echo gateway00000; exit 0 ;;
      *' up -d --no-deps --no-build --force-recreate --wait --wait-timeout '*)
        for last; do :; done
        if [ "\${FAKE_FAIL_UP:-}" = "$last" ]; then echo "fake: $last did not become healthy" >&2; exit 1; fi
        [ "$last" != gateway ] || rm -f "$FAKE_DOCKER_LOG.gw-removed"
        exit 0 ;;
      *' rm -sf gateway-lan') : > "$FAKE_DOCKER_LOG.lan-stopped"; exit 0 ;;
      *' rm -sf gateway') [ "\${FAKE_FAIL_RM:-}" = gateway ] || : > "$FAKE_DOCKER_LOG.gw-removed"; exit 0 ;;
      *' stop '*) echo "fake: stop is not what maintenance.sh may do" >&2; exit 97 ;;
    esac
    exit 0 ;;
esac
`;

function fixture() {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-maintenance-'));
  const state = join(scratch, 'state');
  const bin = join(scratch, 'bin');
  const root = join(scratch, 'checkout');
  mkdirSync(bin);
  writeFileSync(join(scratch, 'provider.env'), 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=isolated-no-delivery-key\nMSG91_TEMPLATE_ID=000000000000000000000001\nMSG91_PE_ID=1\nMSG91_SENDER_ID=CHECK\n', { mode: 0o600 });
  configure(repo, { stateDir: state, apiUrl: 'https://api.example.test', company: 'Acme', providerEnv: join(scratch, 'provider.env') });
  // A checkout of its own, so that the pieces maintenance.sh calls by path can be stand-ins: the lan.sh start step and the health check.
  mkdirSync(join(root, 'docker'), { recursive: true });
  cpSync(join(repo, 'scripts'), join(root, 'scripts'), { recursive: true });
  writeFileSync(join(root, 'scripts/lan.sh'), '#!/usr/bin/env bash\necho "lan.sh $*" >> "$FAKE_STEPS"\n');
  writeFileSync(join(root, 'scripts/watch.mjs'), `import { appendFileSync } from 'node:fs';
appendFileSync(process.env.FAKE_STEPS, 'watch ' + process.argv.slice(2).join(' ') + ' marker=' + (await import('node:fs')).existsSync(process.env.WAREHOUSE_STATE_DIR + '/config/maintenance') + '\\n');
if (process.env.FAKE_HEALTH === 'fail') { console.log('FAILED Gateway: fake'); process.exit(1); }
console.log('ok     fake');
`);
  writeFileSync(join(root, 'scripts/service-diagnostics.mjs'), `import { appendFileSync } from 'node:fs';
appendFileSync(process.env.FAKE_STEPS, 'diagnostics ' + process.argv.slice(2).join(' ') + '\\n');
`);
  writeFileSync(join(bin, 'docker'), fakeDocker, { mode: 0o700 });
  const log = join(scratch, 'docker.log');
  const steps = join(scratch, 'steps.log');
  writeFileSync(log, ''); writeFileSync(steps, '');
  const base = { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log, FAKE_STEPS: steps };
  delete base.COMPOSE_PROFILES;
  delete base.WAREHOUSE_MAINTENANCE;
  const marker = join(state, 'config/maintenance');
  const script = (name, args, extra = {}, options = {}) => spawnSync('bash', [join(root, 'scripts', name), ...args], { encoding: 'utf8', env: { ...base, ...extra }, timeout: 60000, ...options });
  return {
    scratch, state, marker, root,
    maintenance: (args, extra) => script('maintenance.sh', args, extra),
    compose: (args, extra) => script('compose.sh', args, extra),
    calls: () => readFileSync(log, 'utf8').split('\n').filter(Boolean),
    // The compose calls only, as "<WAREHOUSE_MAINTENANCE as seen>|<arguments after the project options>".
    composeCalls: () => readFileSync(log, 'utf8').split('\n').filter(line => /\|compose /.test(line)).map(line => line.replace(/\|compose --project-directory \S+ --project-name \S+ --env-file \S+ -f \S+ /, '|')),
    steps: () => readFileSync(steps, 'utf8').split('\n').filter(Boolean),
    clear: () => { writeFileSync(log, ''); writeFileSync(steps, ''); rmSync(`${log}.lan-stopped`, { force: true }); rmSync(`${log}.gw-removed`, { force: true }); },
    base,
  };
}
const done = f => rmSync(f.scratch, { recursive: true, force: true });
const UP = 'up -d --no-deps --no-build --force-recreate --wait --wait-timeout';

test('on: writes the marker (private) and recreates the gateway with the word; the state of everything else is untouched; safe to repeat', () => {
  const f = fixture();
  try {
    const r = f.maintenance(['on']);
    assert.equal(r.status, 0, r.stderr + r.stdout);
    assert.equal(readFileSync(f.marker, 'utf8'), 'upgrading\n');
    assert.equal(statSync(f.marker).mode & 0o777, 0o600);
    assert.deepEqual(readdirNames(join(f.state, 'config')).filter(name => name.startsWith('.maintenance')), [], 'no temporary file is left');
    // The gateway is recreated (not just restarted), and the command that does it already sees the word: compose.sh read the marker.
    assert.deepEqual(f.composeCalls().filter(call => call.endsWith(' gateway')), [`upgrading|ps -q gateway`, `upgrading|${UP} 120 gateway`]);
    // gateway-lan does not run: it is only asked about; nothing else is started, stopped or recreated.
    assert.deepEqual(f.composeCalls().filter(call => /\|(--profile lan )?(up|stop|restart|rm|down|kill) /.test(call)), [`upgrading|${UP} 120 gateway`]);
    assert.match(r.stdout, /Maintenance mode is on: the API answers 503 "upgrading" \(marker .*\/config\/maintenance\)\. Turn it off with: bash scripts\/maintenance\.sh off/);
    // Again: the same, no second marker, no error.
    assert.equal(f.maintenance(['on']).status, 0);
    assert.equal(readFileSync(f.marker, 'utf8'), 'upgrading\n');
  } finally { done(f); }
});

const readdirNames = dir => spawnSync('ls', ['-A', dir], { encoding: 'utf8' }).stdout.split('\n').filter(Boolean);

test('on with the LAN fallback running: gateway-lan is recreated with the word too, after the gateway', () => {
  const f = fixture();
  try {
    const r = f.maintenance(['on'], { FAKE_LAN: 'yes' });
    assert.equal(r.status, 0, r.stderr);
    const calls = f.composeCalls().filter(call => call.includes(UP));
    assert.deepEqual(calls, [`upgrading|${UP} 120 gateway`, `upgrading|--profile lan ${UP} 60 gateway-lan`]);
  } finally { done(f); }
});

test('on with a stopped stack: only the marker, and the gateway starts closed', () => {
  const f = fixture();
  try {
    const r = f.maintenance(['on'], { FAKE_STOPPED: 'yes' });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(existsSync(f.marker), true);
    assert.equal(f.composeCalls().some(call => call.includes(UP)), false, 'nothing is started');
    assert.match(r.stdout, /The gateway is not running: it starts in maintenance mode\./);
    // Whatever then starts the stack goes through compose.sh, which hands Compose the word.
    f.clear();
    assert.equal(f.compose(['up', '-d']).status, 0);
    assert.deepEqual(f.composeCalls(), ['upgrading|up -d']);
  } finally { done(f); }
});

test('on: a gateway that does not come up is removed, so the API is closed or down and never open, and the marker stays', () => {
  const f = fixture();
  try {
    const r = f.maintenance(['on'], { FAKE_FAIL_UP: 'gateway' });
    assert.notEqual(r.status, 0);
    assert.equal(existsSync(f.marker), true, 'the marker stays');
    assert.ok(f.composeCalls().some(call => call.endsWith('|rm -sf gateway')), 'the old gateway, which may still run with the API open, is removed (a stopped container would keep its open environment)');
    assert.equal(f.composeCalls().some(call => call.endsWith('|stop gateway')), false, 'not merely stopped');
    assert.deepEqual(f.steps(), ['diagnostics gateway']);
    assert.match(r.stderr, /The gateway did not come up in maintenance mode \(message above\), so it was removed: the API is closed or down, never open\. .*\/config\/maintenance stays\. Fix the cause and run this again; 'bash scripts\/maintenance\.sh off' opens the API\./);
    assert.match(r.stderr, /fake: gateway did not become healthy/);
  } finally { done(f); }
});

test('on: a gateway that cannot be removed (after a failed recreate, or when it is not running) fails the command and says how to remove it', () => {
  const f = fixture();
  try {
    const failed = f.maintenance(['on'], { FAKE_FAIL_UP: 'gateway', FAKE_FAIL_RM: 'gateway' });
    assert.equal(failed.status, 1);
    assert.match(failed.stderr, /did not come up in maintenance mode \(message above\) and could not be removed, so it may still run, or start again, with the API open\. Remove it: bash scripts\/compose\.sh rm -sf gateway/);
    assert.doesNotMatch(failed.stderr, /so it was removed/);
    f.clear();
    const exited = f.maintenance(['on'], { FAKE_GW_EXITED: 'yes', FAKE_FAIL_RM: 'gateway' });
    assert.equal(exited.status, 1);
    assert.match(exited.stderr, /The gateway container is not running and could not be removed, so it could start again with the API open\. Remove it: bash scripts\/compose\.sh rm -sf gateway/);
    assert.doesNotMatch(exited.stdout, /its container was removed/);
  } finally { done(f); }
});

test('on: a gateway-lan that does not come up is removed (the LAN path is closed, a warning); one that cannot be removed fails the command', () => {
  const f = fixture();
  try {
    const r = f.maintenance(['on'], { FAKE_LAN: 'yes', FAKE_FAIL_UP: 'gateway-lan' });
    assert.equal(r.status, 0, r.stderr);
    assert.ok(f.composeCalls().some(call => call.endsWith('|--profile lan rm -sf gateway-lan')));
    assert.match(r.stderr, /Warning: the gateway-lan service did not come up in maintenance mode \(message above\), so it was removed; phones on the LAN path get no answer until 'bash scripts\/maintenance\.sh off' starts it again\. The internet path is closed as intended\./);
    assert.deepEqual(f.steps(), ['diagnostics gateway-lan']);
    f.clear();
    const stuck = f.maintenance(['on'], { FAKE_LAN: 'yes', FAKE_FAIL_UP: 'gateway-lan', FAKE_LAN_STUCK: 'yes' });
    assert.notEqual(stuck.status, 0);
    assert.match(stuck.stderr, /could not be removed, so the LAN path is still open\. Remove it: bash scripts\/compose\.sh --profile lan rm -sf gateway-lan/);
  } finally { done(f); }
});

test('off: removes the marker, recreates the gateway without the word, starts the LAN fallback apart, and ends with the health check', () => {
  const f = fixture();
  try {
    assert.equal(f.maintenance(['on']).status, 0);
    f.clear();
    const r = f.maintenance(['off']);
    assert.equal(r.status, 0, r.stderr + r.stdout);
    assert.equal(existsSync(f.marker), false);
    // The word is gone from the environment of the command that recreates it: compose.sh found no marker.
    assert.deepEqual(f.composeCalls().filter(call => call.includes(UP)), [`unset|${UP} 120 gateway`]);
    // The LAN fallback comes back through lan.sh start (a fault of it is a warning there), and the health check is the last step; it runs with the API open.
    assert.deepEqual(f.steps(), ['lan.sh start', 'watch health --wait 60 marker=false']);
    assert.match(r.stdout, /Maintenance mode is off: the API answers phones again\./);
    // Not on: says so, and still recreates (so that the gateways are as compose.env says).
    f.clear();
    const again = f.maintenance(['off']);
    assert.equal(again.status, 0, again.stderr);
    assert.match(again.stdout, /Maintenance mode was not on \(no .*\/config\/maintenance\); the gateways are recreated anyway\./);
  } finally { done(f); }
});

test('off: a gateway that did not come up and cannot be removed fails the command and says so, instead of claiming it is never half open', () => {
  const f = fixture();
  try {
    assert.equal(f.maintenance(['on']).status, 0);
    f.clear();
    const r = f.maintenance(['off'], { FAKE_FAIL_UP: 'gateway', FAKE_FAIL_RM: 'gateway' });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /The gateway did not come up \(message above\) and could not be removed, so it may still run, or start again, with the API open .*Remove it: bash scripts\/compose\.sh rm -sf gateway/);
    assert.doesNotMatch(r.stderr, /never half open/);
    assert.equal(readFileSync(f.marker, 'utf8'), 'upgrading\n', 'the marker is still put back');
  } finally { done(f); }
});

test('off: a gateway that does not come up puts the marker back (it stays closed); a failing health check is said, with the API open', () => {
  const f = fixture();
  try {
    assert.equal(f.maintenance(['on']).status, 0);
    f.clear();
    const r = f.maintenance(['off'], { FAKE_FAIL_UP: 'gateway' });
    assert.notEqual(r.status, 0);
    assert.equal(readFileSync(f.marker, 'utf8'), 'upgrading\n', 'the marker is back');
    assert.match(r.stderr, /The gateway did not come up \(message above\)\. Maintenance mode is still on \(.*\/config\/maintenance was put back\): the API is closed or down, never half open\./);
    assert.deepEqual(f.steps(), ['diagnostics gateway'], 'no health check of a gateway that is not up');
    // The container that was created open and did not become healthy is removed too, so that no start without the word can bring it back open.
    assert.ok(f.composeCalls().some(call => call.endsWith('|rm -sf gateway')), 'the gateway that failed to come up is removed');
    f.clear();
    assert.equal(r.status, 1, 'closed or not done: 1');
    const sick = f.maintenance(['off'], { FAKE_HEALTH: 'fail' });
    assert.equal(sick.status, 2, 'opened but the health check failed: its own status, so that upgrade.sh can record that the API is open');
    assert.equal(existsSync(f.marker), false, 'the API is open');
    assert.match(sick.stderr, /Maintenance mode is off, but the health check failed \(above\): the API is open and something is wrong\. Close it while you look: bash scripts\/maintenance\.sh on/);
    assert.match(sick.stdout, /FAILED Gateway: fake/);
  } finally { done(f); }
});

test('on then a failed recreate then off: the removed gateway is created again (a refused upgrade does not leave the facility down)', () => {
  const f = fixture();
  try {
    const failed = f.maintenance(['on'], { FAKE_FAIL_UP: 'gateway' });
    assert.notEqual(failed.status, 0);
    // The removal was real: the fake lists no container now, which is the state `off` has to repair.
    assert.deepEqual(f.composeCalls().filter(call => /\|rm -sf gateway$/.test(call)), ['upgrading|rm -sf gateway']);
    const before = f.composeCalls().length;
    const r = f.maintenance(['off']);
    assert.equal(r.status, 0, r.stderr + r.stdout);
    assert.deepEqual(f.composeCalls().slice(before).filter(call => call.includes(UP)), [`unset|${UP} 120 gateway`], 'off creates the gateway that is not there');
    assert.match(r.stdout, /The gateway had no container \(it was removed, or the stack is stopped\): it is created and starts open\./);
    assert.equal(existsSync(f.marker), false);
    assert.deepEqual(f.steps().slice(-1), ['watch health --wait 60 marker=false']);
  } finally { done(f); }
});

test('off on a stack that stop.sh stopped (no gateway container, config/stopped-by-operator): only the maintenance marker goes, nothing is created; any other missing gateway is created', () => {
  const f = fixture();
  try {
    const hold = join(f.state, 'config/stopped-by-operator');
    writeFileSync(hold, 'stopped by stop.sh\n');
    writeFileSync(f.marker, 'upgrading\n');
    const r = f.maintenance(['off'], { FAKE_STOPPED: 'yes' });
    assert.equal(r.status, 0, r.stderr + r.stdout);
    assert.equal(existsSync(f.marker), false, 'the maintenance marker is removed');
    assert.equal(existsSync(hold), true, 'the stop is the operator\'s: only start.sh removes it');
    assert.equal(f.composeCalls().some(call => call.includes(UP)), false, 'no gateway is created');
    assert.deepEqual(f.steps(), [], 'no LAN start, no health check');
    assert.match(r.stdout, /the stack was stopped by stop\.sh \(config\/stopped-by-operator\) and is left stopped: no gateway was created\. Run: bash start\.sh/);
    // The same missing gateway without the stop marker (a refused upgrade) is created.
    rmSync(hold);
    f.clear();
    const repaired = f.maintenance(['off'], { FAKE_STOPPED: 'yes' });
    assert.equal(repaired.status, 0, repaired.stderr);
    assert.deepEqual(f.composeCalls().filter(call => call.includes(UP)), [`unset|${UP} 120 gateway`]);
    // The stop marker with a gateway container that exists: recreated as always.
    writeFileSync(hold, 'stopped by stop.sh\n');
    f.clear();
    assert.equal(f.maintenance(['off']).status, 0);
    assert.deepEqual(f.composeCalls().filter(call => call.includes(UP)), [`unset|${UP} 120 gateway`]);
  } finally { done(f); }
});

test('on with a gateway container that exists but is not running: it is removed, not left to start again with the API open', () => {
  const f = fixture();
  try {
    const r = f.maintenance(['on'], { FAKE_GW_EXITED: 'yes' });
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(f.composeCalls().filter(call => /\|rm -sf /.test(call)), ['upgrading|rm -sf gateway']);
    assert.equal(f.composeCalls().some(call => call.includes(UP)), false, 'nothing is recreated or started');
    assert.match(r.stdout, /The gateway was not running: its container was removed, so that it cannot start again with the API open\. It starts in maintenance mode\./);
    assert.equal(readFileSync(f.marker, 'utf8'), 'upgrading\n');
    // No container is left: what lists containers now finds none, so only a Compose command (which reads the marker) can start one.
    assert.equal(f.compose(['ps', '-aq', 'gateway']).stdout, '');
    // And off recreates one that exists but is not running (it does not claim there was no container).
    f.clear();
    const off = f.maintenance(['off'], { FAKE_GW_EXITED: 'yes' });
    assert.equal(off.status, 0, off.stderr);
    assert.deepEqual(f.composeCalls().filter(call => call.includes(UP)), [`unset|${UP} 120 gateway`]);
    assert.doesNotMatch(off.stdout, /had no container/);
  } finally { done(f); }
});

test('the LAN fallback: a stopped gateway-lan container is removed by on, and recreated by off', () => {
  const f = fixture();
  try {
    const on = f.maintenance(['on'], { FAKE_LAN_EXITED: 'yes' });
    assert.equal(on.status, 0, on.stderr);
    assert.deepEqual(f.composeCalls().filter(call => /\|--profile lan rm -sf /.test(call)), ['upgrading|--profile lan rm -sf gateway-lan']);
    f.clear();
    const off = f.maintenance(['off'], { FAKE_LAN_EXITED: 'yes' });
    assert.equal(off.status, 0, off.stderr);
    assert.deepEqual(f.composeCalls().filter(call => call.includes(UP)), [`unset|${UP} 120 gateway`, `unset|--profile lan ${UP} 60 gateway-lan`]);
    // One that cannot be removed fails `on`: it could start again with the LAN path open.
    f.clear();
    const stuck = f.maintenance(['on'], { FAKE_LAN_EXITED: 'yes', FAKE_LAN_STUCK: 'yes' });
    assert.equal(stuck.status, 1);
    assert.match(stuck.stderr, /The gateway-lan container is not running and could not be removed, so it could start again with the LAN path open\./);
  } finally { done(f); }
});

test('status: says whether the marker is there and what each running gateway was created with, and works while another command holds the lock', async () => {
  const f = fixture();
  try {
    assert.equal(f.maintenance(['status']).stdout, 'Maintenance mode: off\n');
    assert.equal(f.maintenance(['on']).status, 0);
    const holder = spawn('flock', [join(f.state, 'config/operator.lock'), 'sleep', '30'], { stdio: 'ignore', detached: true });
    try {
      for (let i = 0; i < 100 && spawnSync('flock', ['-n', join(f.state, 'config/operator.lock'), 'true']).status === 0; i += 1) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
      const status = f.maintenance(['status'], { FAKE_GATEWAY_WORD: 'upgrading', FAKE_LAN: 'yes', FAKE_LAN_WORD: 'off' });
      assert.equal(status.status, 0, status.stderr);
      assert.equal(status.stdout, `Maintenance mode: on (${f.marker} exists). Every API request answers 503 "upgrading" until: bash scripts/maintenance.sh off\n  gateway: started with WAREHOUSE_MAINTENANCE=upgrading\n  gateway-lan: started with WAREHOUSE_MAINTENANCE=off\n`);
      // on and off take the lock and refuse while another command holds it (nothing is changed).
      f.clear();
      for (const command of ['on', 'off']) {
        const refused = f.maintenance([command]);
        assert.notEqual(refused.status, 0, command);
        assert.match(refused.stderr, /Another operator command/);
      }
      assert.deepEqual(f.composeCalls(), [], 'no Compose command ran');
      assert.equal(existsSync(f.marker), true);
    } finally { try { process.kill(-holder.pid, 'SIGKILL'); } catch { /* gone */ } }
    assert.equal(f.maintenance(['bogus']).status, 1);
    assert.equal(f.maintenance([]).status, 1);
  } finally { done(f); }
});

test('on and off work under the lock of the command that runs them (upgrade.sh holds it): the inherited lock is used, not taken a second time', () => {
  const f = fixture();
  try {
    const lock = join(f.state, 'config/operator.lock');
    const run = command => spawnSync('bash', ['-c', `exec 9>"${lock}"; flock -n 9 || exit 9; bash "${join(f.root, 'scripts/maintenance.sh')}" ${command}`], { encoding: 'utf8', env: f.base, timeout: 60000 });
    assert.equal(run('on').status, 0);
    assert.equal(existsSync(f.marker), true);
    assert.equal(run('off').status, 0);
    assert.equal(existsSync(f.marker), false);
  } finally { done(f); }
});

test('compose.sh: while the marker exists every command gets WAREHOUSE_MAINTENANCE=upgrading; without it the word is never passed on, whatever the caller\'s environment says', () => {
  const f = fixture();
  try {
    // No marker: the variable is not in Compose's environment even when the caller has it (only the marker decides).
    for (const caller of [undefined, 'upgrading', 'off']) {
      f.clear();
      assert.equal(f.compose(['ps', '-q'], caller === undefined ? {} : { WAREHOUSE_MAINTENANCE: caller }).status, 0);
      assert.deepEqual(f.composeCalls(), ['unset|ps -q'], `caller ${caller}`);
    }
    // The marker, whatever it holds (a marker nobody can read still closes the API), even as a link.
    for (const content of ['upgrading\n', '', 'garbage', 'off\n']) {
      writeFileSync(f.marker, content);
      f.clear();
      assert.equal(f.compose(['up', '-d', '--wait']).status, 0);
      assert.deepEqual(f.composeCalls(), ['upgrading|up -d --wait'], JSON.stringify(content));
    }
    rmSync(f.marker);
    symlinkSync('/nonexistent', f.marker);
    f.clear();
    f.compose(['ps', '-q']);
    assert.deepEqual(f.composeCalls(), ['upgrading|ps -q']);
    // compose.env is not where it lives: the file of settings has no such line, and the marker is not one of its variables.
    assert.doesNotMatch(readFileSync(join(f.state, 'config/compose.env'), 'utf8'), /MAINTENANCE/);
  } finally { done(f); }
});
