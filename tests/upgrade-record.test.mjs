import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { interruptedMessage, interruptedUpgradeWarning, readUpgradeRecord, rollbackLines } from '../scripts/upgrade-record.mjs';

// The record upgrade.sh leaves while an upgrade has not finished (tests/upgrade.test.mjs runs the writer; this file is the reader).
const root = new URL('..', import.meta.url).pathname;
const FROM = 'a'.repeat(40);
const TO = 'b'.repeat(40);
const record = (extra = {}) => Object.entries({
  format: 1, started: '2026-10-26T10:00:00Z', from_sha: FROM, from_label: 'v0.6.0', from_tag: 'v0.6.0', to_sha: TO, to_label: 'v0.7.0', command: "v0.7.0 -- --gateway-port 18001",
  admin_phone: '919888888871', admin_name: 'Fictional Administrator', webhook_off: 'no', verified: 'yes', backup: '/state/backups/warehouse-20261026T100000Z', step: 'Setup (the same inputs as the installation)', ...extra,
}).map(([key, value]) => `${key}=${value}\n`).join('');
function world(text) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-upgrade-record-'));
  const state = join(scratch, 'state');
  for (const dir of [state, join(state, 'config'), join(state, 'public')]) mkdirSync(dir, { recursive: true, mode: 0o700 });
  writeFileSync(join(state, 'config/compose.env'), 'WAREHOUSE_PROJECT_NAME=record-test\n', { mode: 0o600 });
  writeFileSync(join(state, 'public/instance.json'), '{}\n');
  if (text !== undefined) writeFileSync(join(state, 'config/upgrade-in-progress'), text, { mode: 0o600 });
  return { scratch, state, cleanup: () => rmSync(scratch, { recursive: true, force: true }) };
}

test('a record is read field by field; without one, or before the backup is proved, there is nothing to report', () => {
  const w = world(record());
  try {
    const r = readUpgradeRecord(w.state);
    assert.equal(r.verified, true);
    assert.equal(r.fromSha, FROM);
    assert.equal(r.toSha, TO);
    assert.equal(r.backup, '/state/backups/warehouse-20261026T100000Z');
    assert.equal(r.command, 'v0.7.0 -- --gateway-port 18001');
    assert.equal(r.adminPhone, '919888888871');
    assert.equal(r.webhookOff, false);
    const message = interruptedMessage(r);
    assert.match(message, /^An upgrade from v0\.6\.0 to v0\.7\.0 was interrupted at step "Setup \(the same inputs as the installation\)" \(started 2026-10-26T10:00:00Z; config\/upgrade-in-progress\)\./);
    assert.match(message, /If upgrade\.sh is still running in another terminal, wait for it\./);
    assert.match(message, /Continue: bash upgrade\.sh v0\.7\.0 -- --gateway-port 18001 /);
    assert.match(message, /node scripts\/upgrade-record\.mjs rollback/);
    assert.doesNotMatch(interruptedMessage(r, { own: true }), /wait for it/);
    // The first record is written before the backup exists: the facility is still on the old release, nothing to act on.
    writeFileSync(join(w.state, 'config/upgrade-in-progress'), record({ verified: 'no', backup: '', step: 'Backup' }));
    assert.equal(readUpgradeRecord(w.state).verified, false);
    assert.equal(interruptedMessage(readUpgradeRecord(w.state)), null);
    assert.equal(interruptedUpgradeWarning(w.state, {}), null);
  } finally { w.cleanup(); }
  const none = world();
  try {
    assert.equal(readUpgradeRecord(none.state), null);
    assert.equal(interruptedUpgradeWarning(none.state, {}), null);
  } finally { none.cleanup(); }
});

test('the warning is quiet while upgrade.sh itself runs, and a record that cannot be trusted is not reported as one', () => {
  const w = world(record());
  try {
    assert.match(interruptedUpgradeWarning(w.state, {}), /was interrupted at step/);
    assert.equal(interruptedUpgradeWarning(w.state, { WAREHOUSE_UPGRADE_RUNNING: '1' }), null, 'doctor inside setup inside upgrade.sh');
    for (const bad of ['garbage\n', record({ from_sha: 'abc' }), record({ to_sha: '' }), record({ backup: 'relative/dir' })]) {
      writeFileSync(join(w.state, 'config/upgrade-in-progress'), bad);
      assert.ok(readUpgradeRecord(w.state).invalid, bad);
      assert.equal(interruptedUpgradeWarning(w.state, {}), null);
    }
    rmSync(join(w.state, 'config/upgrade-in-progress'));
    symlinkSync('/etc/hostname', join(w.state, 'config/upgrade-in-progress'));
    assert.match(readUpgradeRecord(w.state).invalid, /not a regular file/);
  } finally { w.cleanup(); }
});

test('the way back is the complete recipe, in order, with the recorded values', () => {
  const w = world(record({ webhook_off: 'yes' }));
  try {
    const lines = rollbackLines(readUpgradeRecord(w.state));
    const text = lines.join('\n');
    const order = [`(umask 022; git checkout --detach ${FROM})`, 'bash stop.sh', "npm run db:restore -- --yes --restore-config '/state/backups/warehouse-20261026T100000Z'",
      `bash setup.sh --operator --state-dir '${w.state}' --admin-phone 91XXXXXXXXXX --admin-name NAME --alert-webhook-file off`, 'the number is 91******8871',
      'bash scripts/compose.sh up -d --force-recreate --no-deps --wait --wait-timeout 180 functions', 'node scripts/doctor.mjs --local', `rm -f '${join(w.state, 'config/upgrade-in-progress')}'`];
    let at = -1;
    for (const part of order) {
      const found = text.indexOf(part, at + 1);
      assert.ok(found > at, `${part}\n${text}`);
      at = found;
    }
    assert.doesNotMatch(text, /919888888871/, 'the administrator\'s number is masked');
  } finally { w.cleanup(); }
});

test('the command line: message is quiet and exits 0 without a record, report and rollback say so and exit 1', () => {
  const none = world();
  const some = world(record());
  const run = (state, ...args) => spawnSync('node', [join(root, 'scripts/upgrade-record.mjs'), ...args], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: state } });
  try {
    const quiet = run(none.state, 'message');
    assert.equal(quiet.status, 0);
    assert.equal(quiet.stdout, '');
    assert.equal(run(none.state, 'report').status, 1);
    assert.match(run(none.state, 'rollback').stderr, /No upgrade is recorded as interrupted/);
    const message = run(some.state, 'message');
    assert.equal(message.status, 0);
    assert.match(message.stdout, /was interrupted at step/);
    const report = run(some.state, 'report');
    assert.equal(report.status, 0);
    assert.match(report.stdout, /^An upgrade from v0\.6\.0 to v0\.7\.0 was interrupted[^\n]*half upgraded\.\s+Continue:/);
    assert.doesNotMatch(report.stdout, /wait for it/);
    assert.match(report.stdout, /To go back to v0\.6\.0 \(a{40}\) instead/);
    assert.equal(run(some.state, 'nonsense').status, 2);
    assert.equal(spawnSync('node', [join(root, 'scripts/upgrade-record.mjs'), 'message'], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: '' } }).status, 2);
    // upgrade.sh sets this for the doctor that setup runs.
    const running = spawnSync('node', [join(root, 'scripts/upgrade-record.mjs'), 'message'], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: some.state, WAREHOUSE_UPGRADE_RUNNING: '1' } });
    assert.equal(running.stdout, '');
  } finally { none.cleanup(); some.cleanup(); }
});

test('the timer helper\'s hint and status name an interrupted upgrade', () => {
  const w = world(record());
  const quiet = world();
  const units = join(w.scratch, 'units');
  mkdirSync(units);
  const run = (state, command) => spawnSync('bash', [join(root, 'scripts/watch-timer.sh'), command], {
    encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: state, WAREHOUSE_WATCH_UNIT_DIR: units },
  });
  try {
    for (const command of ['hint', 'status']) {
      const said = run(w.state, command);
      assert.equal(said.status, 0, `${command}: ${said.stderr}`);
      assert.match(said.stdout, /An upgrade from v0\.6\.0 to v0\.7\.0 was interrupted at step "Setup/, command);
      assert.doesNotMatch(run(quiet.state, command).stdout, /was interrupted/, command);
    }
  } finally { w.cleanup(); quiet.cleanup(); }
});
