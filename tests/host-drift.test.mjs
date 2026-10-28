// The weekly host warnings of scripts/watch.mjs: cloudflared_old, host_node_eol and root_copy_stale. Fake commands and a scratch tree;
// no systemd, no network, no real clock.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync, copyFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { repo } from './backup-test-helpers.mjs';
import { fixture } from './usb-test-helpers.mjs';
import * as W from '../scripts/watch.mjs';

const DAY = 24 * 3600 * 1000;
const at = (y, m, d, h = 12) => Date.UTC(y, m - 1, d, h);
const ok = (stdout = '') => ({ status: 0, stdout, stderr: '' });
const bad = (stderr = 'failed') => ({ status: 1, stdout: '', stderr });
const sha = text => createHash('sha256').update(text).digest('hex');

// A context over a scratch state directory named "acme" (the tunnel unit is warehouse-acme-tunnel.service).
function scratch({ now = at(2026, 10, 19), runs = {}, extra = {} } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-drift-'));
  const state = join(dir, 'acme');
  mkdirSync(join(state, 'config'), { recursive: true });
  writeFileSync(join(state, 'config/compose.env'), 'WAREHOUSE_PROJECT_NAME=warehouse-acme\n', { mode: 0o600 });
  const calls = [];
  const deps = {
    state, root: repo, env: {}, now: () => now, proc: join(dir, 'proc'),
    run: (command, args) => {
      const line = `${command} ${args.join(' ')}`;
      calls.push(line);
      for (const [pattern, reply] of Object.entries(runs)) if (line.includes(pattern)) return typeof reply === 'function' ? reply(line) : reply;
      return bad(`unexpected command: ${line}`);
    },
    readText: path => { try { return readFileSync(path, 'utf8'); } catch { return null; } },
    usbEtc: join(dir, 'etc'), usbLibexec: join(dir, 'libexec'), unitDir: join(dir, 'units'), nodeVersion: 'v22.20.0',
    ...extra,
  };
  return { dir, state, calls, deps, ctx: () => W.makeContext(deps, W.freshState(now)), clean: () => rmSync(dir, { recursive: true, force: true }) };
}
const version = built => `cloudflared version 2026.1.0 (built ${built}-1412 UTC)\n`;
const tunnel = ({ started = at(2026, 10, 1) / 1000, pid = 4242, active = 'active' } = {}) =>
  ok(`ActiveState=${active}\nActiveEnterTimestamp=@${started}\nMainPID=${pid}\n`);

test('cloudflared_old: fires at 11 months after the release date, not at 10 months or one day short of 11', () => {
  const now = at(2026, 10, 19);
  const run = built => scratch({ now, runs: { 'cloudflared --version': ok(version(built)) } });
  for (const [built, fires] of [['2025-12-19', false], ['2025-11-20', false], ['2025-11-19', true], ['2024-01-05', true]]) {
    const s = run(built);
    try {
      const [r] = W.checkCloudflared(s.ctx());
      assert.equal(r.id, 'cloudflared_old');
      assert.equal(r.ok, !fires, `${built}: ${r.summary}`);
      if (fires) assert.match(r.summary, new RegExp(`released on ${built}`));
      assert.equal(r.repeatHours, 168, 'weekly, not every 4 hours');
    } finally { s.clean(); }
  }
  // Only the year and month in the version number, no build date.
  const s = scratch({ now, runs: { 'cloudflared --version': ok('cloudflared version 2025.11.1\n') } });
  try { assert.equal(W.checkCloudflared(s.ctx())[0].ok, false, 'the 1st of the version month stands in for the date'); } finally { s.clean(); }
});

test('cloudflared_old: a host without cloudflared is not judged; output it does not know is a weekly warning, not a pass and not a 4-hourly check_error', () => {
  let s = scratch({ runs: { 'cloudflared --version': bad('not found') } });
  try { assert.equal(W.checkCloudflared(s.ctx())[0].ok, true); } finally { s.clean(); }
  s = scratch({ runs: { 'cloudflared --version': ok('something else\n') } });
  try {
    const [r] = W.checkCloudflared(s.ctx());
    assert.equal(r.ok, false); assert.equal(r.id, 'cloudflared_old'); assert.match(r.summary, /does not know: something else/);
    assert.equal(r.repeatHours, 168, 'weekly');
  } finally { s.clean(); }
});

test('cloudflared_old: a binary on disk newer than the tunnel process start, or a replaced one still running, asks for a restart', () => {
  const started = at(2026, 10, 1) / 1000;
  const base = { 'cloudflared --version': ok(version('2026-09-01')), 'systemctl show warehouse-acme-tunnel.service': tunnel({ started }) };
  // Older binary than the start: fine.
  let s = scratch({ runs: { ...base, 'readlink': ok('/usr/bin/cloudflared\n'), 'stat -L -c %Y': ok(`${started - 3600}\n`) } });
  try {
    const [r] = W.checkCloudflared(s.ctx());
    assert.equal(r.ok, true, r.summary);
    assert.ok(s.calls.some(c => c.startsWith('readlink ') && c.endsWith('/4242/exe')), 'the process of the unit was looked at');
    assert.ok(!s.calls.some(c => /^(curl|wget)|https?:/.test(c)), 'no network');
  } finally { s.clean(); }
  // Newer binary than the start.
  s = scratch({ runs: { ...base, 'readlink': ok('/usr/bin/cloudflared\n'), 'stat -L -c %Y': ok(`${started + 3600}\n`) } });
  try {
    const [r] = W.checkCloudflared(s.ctx());
    assert.equal(r.ok, false);
    assert.match(r.summary, /warehouse-acme-tunnel\.service started before the cloudflared on disk was installed: restart it/);
  } finally { s.clean(); }
  // The file was replaced (package upgrade): the running process still holds the deleted one, whatever the mtimes say.
  s = scratch({ runs: { ...base, 'readlink': ok('/usr/bin/cloudflared (deleted)\n'), 'stat -L -c %Y': ok(`${started - 3600}\n`) } });
  try { assert.match(W.checkCloudflared(s.ctx())[0].summary, /still runs the cloudflared that was replaced on disk/); } finally { s.clean(); }
  // A unit that is not running, or not installed, is the tunnel checks' business.
  s = scratch({ runs: { ...base, 'systemctl show warehouse-acme-tunnel.service': tunnel({ active: 'failed' }), 'stat -L -c %Y': ok(`${started + 3600}\n`) } });
  try { assert.equal(W.checkCloudflared(s.ctx())[0].ok, true); } finally { s.clean(); }
  s = scratch({ runs: { 'cloudflared --version': ok(version('2026-09-01')) } });
  try { assert.equal(W.checkCloudflared(s.ctx())[0].ok, true); } finally { s.clean(); }
});

test('cloudflared_old: Dev runs the stock cloudflared.service, which is judged when the warehouse-named unit is not running', () => {
  const started = at(2026, 10, 1) / 1000;
  const base = { 'cloudflared --version': ok(version('2026-09-01')), 'systemctl show warehouse-acme-tunnel.service': tunnel({ active: 'inactive', pid: 0 }), 'readlink': ok('/usr/bin/cloudflared\n') };
  let s = scratch({ runs: { ...base, 'systemctl show cloudflared.service': tunnel({ started, pid: 777 }), 'stat -L -c %Y': ok(`${started + 3600}\n`) } });
  try {
    const [r] = W.checkCloudflared(s.ctx());
    assert.equal(r.ok, false);
    assert.match(r.summary, /cloudflared\.service started before the cloudflared on disk was installed: restart it/);
    assert.ok(s.calls.some(c => c.startsWith('readlink ') && c.endsWith('/777/exe')));
  } finally { s.clean(); }
  // The named unit wins when it runs: the stock unit is not even asked.
  s = scratch({ runs: { ...base, 'systemctl show warehouse-acme-tunnel.service': tunnel({ started }), 'stat -L -c %Y': ok(`${started - 3600}\n`) } });
  try {
    assert.equal(W.checkCloudflared(s.ctx())[0].ok, true);
    assert.ok(!s.calls.some(c => c.includes('systemctl show cloudflared.service')));
  } finally { s.clean(); }
  // Neither runs: nothing to judge.
  s = scratch({ runs: { ...base, 'systemctl show cloudflared.service': tunnel({ active: 'inactive', pid: 0 }) } });
  try { assert.equal(W.checkCloudflared(s.ctx())[0].ok, true); } finally { s.clean(); }
});

test('host_node_eol: fires within 60 days of the end date and after it, not at 61 days; a major outside the table is a warning, never a quiet pass', () => {
  const end = Date.parse('2027-04-30T00:00:00Z');
  const judge = (nodeVersion, now) => { const s = scratch({ now, extra: { nodeVersion } }); try { return W.checkHostNode(s.ctx())[0]; } finally { s.clean(); } };
  let r = judge('v22.20.0', end - 61 * DAY);
  assert.equal(r.ok, true, r.summary);
  r = judge('v22.20.0', end - 60 * DAY);
  assert.equal(r.ok, false); assert.equal(r.id, 'host_node_eol'); assert.match(r.summary, /Node\.js 22 .* 2027-04-30 \(60 days\)/);
  assert.equal(r.repeatHours, 168);
  r = judge('v22.20.0', end + 5 * DAY);
  assert.equal(r.ok, false); assert.match(r.summary, /reached its end of life on 2027-04-30/);
  assert.equal(judge('v24.1.0', end - 30 * DAY).ok, true, 'Node 24 ends a year later');
  assert.equal(judge('v24.1.0', Date.parse('2028-04-30T00:00:00Z') - 60 * DAY).ok, false);
  assert.equal(judge('v26.0.0', Date.parse('2029-04-30T00:00:00Z') - 60 * DAY).ok, false);
  r = judge('v25.1.0', at(2026, 10, 28));
  assert.equal(r.ok, false, 'Node 25 ended 2026-06-01'); assert.match(r.summary, /Node\.js 25 .*odd-numbered release without long-term support/); assert.equal(r.repeatHours, 168);
  assert.equal(judge('v23.0.0', end).ok, false, 'an odd major is never long-term support');
  assert.match(judge('v20.0.0', end).summary, /older than every major this check knows/);
  assert.match(judge('v28.0.0', end).summary, /no end date for it \(add it to NODE_END_OF_LIFE/, 'a major newer than the table asks for the table to be updated');
  assert.deepEqual(W.NODE_END_OF_LIFE, { 22: '2027-04-30', 24: '2028-04-30', 26: '2029-04-30' });
});

// The USB helper and the units, as the real setup scripts write them, against this checkout's scripts.
test('root_copy_stale: copies written by this checkout pass; a changed recipe, a missing marker or a changed helper is named', () => {
  const f = fixture('warehouse-drift-usb-');
  const t = scratch();
  try {
    const setup = f.asRoot(['setup', '--state', f.state]);
    assert.equal(setup.status, 0, setup.stderr);
    const deps = { ...t.deps, state: f.state, root: f.root, usbEtc: f.etc, usbLibexec: f.libexec, unitDir: join(t.dir, 'no-units') };
    const judge = () => W.checkRootCopies(W.makeContext(deps, W.freshState(Date.now())))[0];
    let r = judge();
    assert.equal(r.ok, true, r.summary + r.detail);
    const unit = join(f.etc, 'systemd/system/warehouse-usb-backup@.service');
    const rule = join(f.etc, 'udev/rules.d/90-warehouse-usb-backup.rules');
    const helper = join(f.libexec, 'warehouse-usb-backup');
    assert.match(readFileSync(unit, 'utf8'), /^# Recipe: sha256:[0-9a-f]{64}$/m);
    assert.match(readFileSync(rule, 'utf8'), /^# Recipe: sha256:[0-9a-f]{64}$/m);
    // The unit was written by a script with another hash.
    const original = readFileSync(unit, 'utf8');
    writeFileSync(unit, original.replace(/sha256:[0-9a-f]{64}/, `sha256:${'0'.repeat(64)}`));
    r = judge();
    assert.equal(r.ok, false); assert.equal(r.id, 'root_copy_stale'); assert.equal(r.repeatHours, 168);
    assert.ok(r.summary.includes(unit) && !r.summary.includes(rule) && !r.summary.includes(helper), r.summary);
    assert.match(r.detail, new RegExp(`sudo bash ${f.root.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/scripts/backup-usb\\.sh setup --state ${f.state.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`));
    // A file from before the marker existed.
    writeFileSync(unit, original.replace(/^# Recipe:.*\n/m, ''));
    assert.equal(judge().ok, false, 'no recipe line: written by an earlier release');
    writeFileSync(unit, original);
    assert.equal(judge().ok, true);
    // The root helper is a byte copy of the script.
    writeFileSync(helper, `${readFileSync(helper, 'utf8')}# older\n`);
    r = judge();
    assert.equal(r.ok, false); assert.ok(r.summary.includes(helper));
    copyFileSync(join(f.root, 'scripts/backup-usb.sh'), helper);
    assert.equal(judge().ok, true);
    // backup-usb.sh status says the same thing the alert does, for the rule and the unit.
    assert.doesNotMatch(f.asRoot(['status']).stdout, /earlier release of this script/);
    for (const file of [rule, unit]) {
      const text = readFileSync(file, 'utf8');
      for (const changed of [text.replace(/sha256:[0-9a-f]{64}/, `sha256:${'0'.repeat(64)}`), text.replace(/^# Recipe:.*\n/m, '')]) {
        writeFileSync(file, changed);
        const status = f.asRoot(['status']).stdout;
        assert.ok(status.includes(`WARNING: ${file} was written by an earlier release of this script; run setup again.`), status);
        assert.equal(status.split('earlier release of this script').length, 2, 'only the changed file is named');
      }
      writeFileSync(file, text);
    }
    // Another installation's USB setup is not this state's business.
    writeFileSync(join(f.etc, 'warehouse-usb-backup.conf'), readFileSync(join(f.etc, 'warehouse-usb-backup.conf'), 'utf8').replace(/^STATE=.*$/m, 'STATE=/srv/other'));
    writeFileSync(helper, 'old');
    assert.equal(judge().ok, true);
  } finally { f.cleanup(); t.clean(); }
});

test('root_copy_stale: the monitoring units are judged against scripts/watch-timer.sh, and only for this state', () => {
  const t = scratch();
  try {
    const timer = readFileSync(join(repo, 'scripts/watch-timer.sh'), 'utf8');
    mkdirSync(t.deps.unitDir, { recursive: true });
    const recipe = sha(timer);
    const unit = (name, extra = '') => writeFileSync(join(t.deps.unitDir, `warehouse-acme-${name}.service`), `# Managed by scripts/watch-timer.sh\n${extra}[Service]\nEnvironment=WAREHOUSE_STATE_DIR=${t.state}\n`);
    for (const name of ['watch', 'daily', 'stack']) unit(name, `# Recipe: sha256:${recipe}\n`);
    assert.equal(W.checkRootCopies(t.ctx())[0].ok, true);
    unit('daily', `# Recipe: sha256:${sha('older')}\n`);
    let r = W.checkRootCopies(t.ctx())[0];
    assert.equal(r.ok, false);
    assert.ok(r.summary.includes('warehouse-acme-daily.service') && !r.summary.includes('warehouse-acme-watch.service'));
    assert.match(r.detail, /watch-timer\.sh install --state /);
    unit('daily', `# Recipe: sha256:${recipe}\n`);
    unit('stack');
    assert.equal(W.checkRootCopies(t.ctx())[0].ok, false, 'a unit without the line was written by an earlier release');
    // A checker unit for another state means these units are not this installation's.
    writeFileSync(join(t.deps.unitDir, 'warehouse-acme-watch.service'), '[Service]\nEnvironment=WAREHOUSE_STATE_DIR=/srv/other\n');
    assert.equal(W.checkRootCopies(t.ctx())[0].ok, true);
  } finally { t.clean(); }
});

test('watch-timer.sh writes the recipe line the check reads into every unit, from its own hash', () => {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-drift-timer-'));
  try {
    const state = join(dir, 'acme');
    for (const sub of ['config', 'public']) mkdirSync(join(state, sub), { recursive: true, mode: 0o700 });
    writeFileSync(join(state, 'config/compose.env'), 'WAREHOUSE_PROJECT_NAME=warehouse-acme\n', { mode: 0o600 });
    writeFileSync(join(state, 'public/instance.json'), '{}\n');
    const bin = join(dir, 'bin'); mkdirSync(bin);
    const node = join(dir, 'home/.local/opt/node-v22/bin'); mkdirSync(node, { recursive: true });
    writeFileSync(join(node, 'node'), '#!/bin/sh\necho v22.18.0\n', { mode: 0o755 });
    writeFileSync(join(bin, 'systemctl'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    writeFileSync(join(bin, 'id'), '#!/bin/sh\nif [ "$1" = -u ]; then echo 0; exit 0; fi\nexec /usr/bin/id "$@"\n', { mode: 0o755 });
    writeFileSync(join(bin, 'getent'), `#!/bin/sh\ncase "$1" in passwd) echo "installer:x:$2:$2::${join(dir, 'home')}:/bin/sh" ;; group) echo "installer:x:$2:" ;; esac\n`, { mode: 0o755 });
    writeFileSync(join(bin, 'runuser'), '#!/bin/sh\nshift 3\nexec "$@"\n', { mode: 0o755 });
    writeFileSync(join(bin, 'docker'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    const units = join(dir, 'units');
    const r = spawnSync('bash', [join(repo, 'scripts/watch-timer.sh'), 'install', '--node', join(node, 'node')], { encoding: 'utf8',
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, WAREHOUSE_WATCH_UNIT_DIR: units, SUDO_UID: String(process.getuid()), SUDO_GID: String(process.getgid()) } });
    assert.equal(r.status, 0, r.stderr);
    const recipe = sha(readFileSync(join(repo, 'scripts/watch-timer.sh'), 'utf8'));
    for (const name of ['watch', 'daily', 'stack']) {
      assert.match(readFileSync(join(units, `warehouse-acme-${name}.service`), 'utf8'), new RegExp(`^# Recipe: sha256:${recipe}$`, 'm'), name);
    }
    // And the check, run on those very files, finds them current.
    const s = scratch({ extra: { unitDir: units } });
    try {
      const deps = { ...s.deps, state };
      assert.equal(W.checkRootCopies(W.makeContext(deps, W.freshState(0)))[0].ok, true);
    } finally { s.clean(); }
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('the three checks are in the checker, muted and repeated like other warnings', () => {
  for (const [name, fn] of [['cloudflared', W.checkCloudflared], ['host_node', W.checkHostNode], ['root_copies', W.checkRootCopies]]) {
    assert.ok(W.CHECKS.some(([n, f]) => n === name && f === fn), name);
  }
  const data = { muteUntil: null, mutes: { cloudflared_old: 2000, host_node_eol: 2000, root_copy_stale: 2000 } };
  for (const id of ['cloudflared_old', 'host_node_eol', 'root_copy_stale']) {
    assert.equal(W.isMuted(data, id, 1000), true, `${id} can be muted`);
    assert.equal(W.isMuted(data, id, 3000), false);
  }
  // A failing weekly result repeats after 7 days, not after 4 hours.
  const data2 = W.freshState(0);
  const failing = [{ check: 'cloudflared', id: 'cloudflared_old', ok: false, summary: 's', detail: 'd', repeatHours: 168 }];
  const ran = new Set(['cloudflared']);
  W.evaluate(data2, failing, ran, 1000); const first = W.evaluate(data2, failing, ran, 2000);
  assert.equal(first.start.length, 1);
  data2.alerts.cloudflared_old.lastSent = 2000;
  assert.equal(W.evaluate(data2, failing, ran, 2000 + 5 * 3600 * 1000).repeat.length, 0, 'not after 5 hours');
  assert.equal(W.evaluate(data2, failing, ran, 2000 + 168 * 3600 * 1000).repeat.length, 1, 'after 7 days');
});
