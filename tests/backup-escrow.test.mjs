// scripts/backup-key-escrow.sh: the confirmation that a copy of the backup key exists away from the machine and the drive,
// and the helpers in scripts/backup-key.sh that the USB commands, doctor and the checker use to read it.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync, statSync, readdirSync, renameSync, symlinkSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeState, scriptRoot, backupKey, hmacHex, writeKey, writeEscrow, escrowFingerprint } from './backup-test-helpers.mjs';

function fixture() {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-escrow-'));
  const state = makeState(scratch);
  const root = scriptRoot(scratch);
  const env = (extra = {}) => ({ ...process.env, WAREHOUSE_STATE_DIR: state, ...extra });
  const run = (args, extra = {}, options = {}) => spawnSync('bash', [join(root, 'scripts/backup-key-escrow.sh'), ...args], { encoding: 'utf8', env: env(extra), ...options });
  const record = join(state, 'config/backup-key.escrow');
  return { scratch, state, root, run, record, env, cleanup: () => rmSync(scratch, { recursive: true, force: true }) };
}
const last8 = backupKey.slice(-8);
const haveScript = spawnSync('script', ['--version'], { encoding: 'utf8' }).status === 0;

test('the fingerprint is an HMAC of the key, 16 hexadecimal characters, that does not reveal the key', () => {
  const f = fixture();
  try {
    const result = spawnSync('bash', ['-c', 'set -euo pipefail; source "$1"; backup_key_fingerprint "$2"', 'sh', join(f.root, 'scripts/backup-key.sh'), backupKey], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), escrowFingerprint(), 'the shell implementation and Node\'s crypto agree');
    assert.match(result.stdout.trim(), /^[0-9a-f]{16}$/);
    assert.ok(!backupKey.includes(result.stdout.trim()) && !result.stdout.includes(last8));
    assert.notEqual(escrowFingerprint(), escrowFingerprint('d4'.repeat(32)));
  } finally { f.cleanup(); }
});

test('confirm --last8 records the confirmation only when the characters are the end of the key', () => {
  const f = fixture();
  try {
    for (const bad of ['', 'abcd', '12345678', last8.toUpperCase().replace(/[A-F]/g, 'Z')]) {
      const refused = f.run(['confirm', '--last8', bad]);
      assert.equal(refused.status, 1, bad);
      assert.equal(existsSync(f.record), false, 'nothing recorded');
    }
    assert.equal(f.run(['confirm']).status, 1);
    assert.match(f.run(['confirm', '--last8', '12345678']).stderr, /not the end of this installation's backup key; nothing was recorded/);
    const result = f.run(['confirm', '--last8', last8]);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Confirmed\. Recorded in .*backup-key\.escrow/);
    const lines = readFileSync(f.record, 'utf8').split('\n');
    assert.equal(lines[0], 'warehouse-backup-key-escrow-v1');
    assert.equal(lines[1], `key_fingerprint=${escrowFingerprint()}`);
    assert.match(lines[2], /^confirmed_utc=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    assert.match(lines[3], /^confirmed_by=\S+$/);
    assert.equal(statSync(f.record).mode & 0o777, 0o600);
    assert.ok(!readFileSync(f.record, 'utf8').includes(backupKey) && !readFileSync(f.record, 'utf8').includes(last8), 'the record does not hold the key');
    assert.deepEqual(readdirSync(join(f.state, 'config')).filter(n => n.startsWith('.backup-key.escrow')), [], 'no temporary file left');
  } finally { f.cleanup(); }
});

test('check says whether the record matches the key in use, for the default record or a given file', () => {
  const f = fixture();
  try {
    let result = f.run(['check']);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Not confirmed: there is no key escrow record\. Run: bash scripts\/backup-key-escrow\.sh show/);
    writeEscrow(f.state);
    result = f.run(['check']);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Key copy confirmed: 2026-10-26T00:00:00Z by tester\./);
    // A given file is checked against the key in use.
    const other = join(f.scratch, 'other.escrow');
    writeFileSync(other, readFileSync(f.record, 'utf8').replace(/key_fingerprint=.*/, `key_fingerprint=${escrowFingerprint('d4'.repeat(32))}`));
    result = f.run(['check', other]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /the key escrow record is for another backup key/);
    assert.equal(f.run(['check', f.record]).status, 0);
    // The key is replaced: the old confirmation no longer counts.
    writeKey(join(f.state, 'config/backup.key'), 'c3'.repeat(32));
    assert.match(f.run(['check']).stderr, /for another backup key/);
    // A damaged record, or a file that is not one.
    writeFileSync(f.record, 'warehouse-backup-key-escrow-v1\n');
    assert.match(f.run(['check']).stderr, /the key escrow record has no key fingerprint/);
    writeFileSync(f.record, 'hello\n');
    assert.match(f.run(['check']).stderr, /the key escrow record is not valid/);
    assert.equal(f.run(['check', 'a', 'b']).status, 1);
    assert.match(f.run(['frobnicate']).stderr, /Usage: bash scripts\/backup-key-escrow\.sh show \| check \[FILE\] \| confirm --last8 XXXXXXXX/);
  } finally { f.cleanup(); }
});

test('show needs a terminal and prints no key to a pipe or a file', () => {
  const f = fixture();
  try {
    const result = f.run(['show'], {}, { input: `${last8}\n` });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /needs a terminal/);
    assert.ok(!result.stdout.includes(backupKey) && !result.stderr.includes(backupKey), 'the key was not printed');
    assert.equal(existsSync(f.record), false);
    const toFile = spawnSync('bash', ['-c', 'bash "$1" show > "$2"', 'sh', join(f.root, 'scripts/backup-key-escrow.sh'), join(f.scratch, 'out.txt')], { encoding: 'utf8', env: f.env() });
    assert.equal(toFile.status, 1);
    assert.ok(!readFileSync(join(f.scratch, 'out.txt'), 'utf8').includes(backupKey));
  } finally { f.cleanup(); }
});

test('show prints the key once, asks for its last 8 characters, retries twice, and records the confirmation on a match', { skip: !haveScript && 'the script command (util-linux) is not installed' }, () => {
  const f = fixture();
  // `script` gives the command a pseudo terminal; what is typed is fed from the pipe.
  const show = typed => spawnSync('script', ['-qec', `bash ${join(f.root, 'scripts/backup-key-escrow.sh')} show`, '/dev/null'], { encoding: 'utf8', env: f.env(), input: typed });
  try {
    let result = show('11111111\n22222222\n33333333\n');
    assert.equal(result.status, 1, result.stdout);
    assert.equal(result.stdout.split(backupKey).length - 1, 1, 'the key is printed once');
    assert.match(result.stdout, /away from the facility/);
    assert.match(result.stdout, /attempt 1 of 3[\s\S]*attempt 2 of 3[\s\S]*attempt 3 of 3/);
    assert.match(result.stdout, /Nothing was recorded\./);
    assert.equal(existsSync(f.record), false);
    // A mismatch first, then the right characters (upper case and spaces are forgiven).
    result = show(`11111111\n${last8.toUpperCase()} \n`);
    assert.equal(result.status, 0, result.stdout);
    assert.match(result.stdout, /attempt 1 of 3[\s\S]*Confirmed\. Recorded in/);
    assert.equal(readFileSync(f.record, 'utf8').split('\n')[1], `key_fingerprint=${escrowFingerprint()}`);
    // Asked again once confirmed: it says so and still lets the operator confirm.
    result = show(`${last8}\n`);
    assert.equal(result.status, 0, result.stdout);
    assert.match(result.stdout, /A copy of this key was already confirmed \(\d{4}-\d\d-\d\dT[\d:]+Z\)\. You can confirm again\./);
  } finally { f.cleanup(); }
});

test('show creates the key on an installation that has none yet, so the copy can be taken before the first backup', { skip: !haveScript && 'the script command (util-linux) is not installed' }, () => {
  const f = fixture();
  try {
    rmSync(join(f.state, 'config/backup.key'));
    const result = spawnSync('script', ['-qec', `bash ${join(f.root, 'scripts/backup-key-escrow.sh')} show`, '/dev/null'], { encoding: 'utf8', env: f.env(), input: '00000000\n00000000\n00000000\n' });
    assert.equal(result.status, 1);
    assert.match(result.stdout, /Created the backup key /);
    const key = readFileSync(join(f.state, 'config/backup.key'), 'utf8').trim();
    assert.match(key, /^[0-9a-f]{64}$/);
    assert.ok(result.stdout.includes(key), 'and printed it');
    assert.equal(statSync(join(f.state, 'config/backup.key')).mode & 0o777, 0o600);
  } finally { f.cleanup(); }
});

test('backup_escrow_ok: the record must exist, be well formed and match the key in the state', () => {
  const f = fixture();
  const ok = () => spawnSync('bash', ['-c', 'set -euo pipefail; source "$1"; backup_escrow_ok "$2" && echo yes || { echo "no: $BACKUP_ESCROW_PROBLEM"; exit 3; }', 'sh', join(f.root, 'scripts/backup-key.sh'), f.state], { encoding: 'utf8' });
  try {
    assert.match(ok().stdout, /^no: there is no key escrow record\n$/);
    writeEscrow(f.state);
    assert.equal(ok().stdout.trim(), 'yes');
    writeFileSync(f.record, readFileSync(f.record, 'utf8').replace(/^warehouse-backup-key-escrow-v1/, 'warehouse-backup-key-escrow-v2'));
    assert.match(ok().stdout, /not valid/);
    writeEscrow(f.state, 'd4'.repeat(32));
    assert.match(ok().stdout, /for another backup key/);
    writeEscrow(f.state);
    rmSync(join(f.state, 'config/backup.key'));
    assert.match(ok().stdout, /does not exist/);
    // A record that is a link to somewhere else is not trusted.
    writeKey(join(f.state, 'config/backup.key'));
    const elsewhere = writeEscrow(f.state);
    renameSync(elsewhere, join(f.scratch, 'elsewhere.escrow'));
    symlinkSync(join(f.scratch, 'elsewhere.escrow'), f.record);
    assert.match(ok().stdout, /there is no key escrow record/);
  } finally { f.cleanup(); }
});
