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
const tail = backupKey.slice(-8);   // the end of the key: a copy that has only this right must not be accepted
const haveScript = spawnSync('script', ['--version'], { encoding: 'utf8' }).status === 0;
// REQUIRE_PTY=1 (a runner known to have `script`) turns the silent skip of the terminal tests below into a failure.
test('the script command, which gives the terminal tests a pseudo terminal, is there when REQUIRE_PTY=1', { skip: process.env.REQUIRE_PTY !== '1' && 'REQUIRE_PTY is not 1' }, () => {
  assert.ok(haveScript, 'REQUIRE_PTY=1, but the script command (util-linux) is missing: the terminal tests would be skipped');
});

test('the fingerprint is an HMAC of the key, 16 hexadecimal characters, that does not reveal the key', () => {
  const f = fixture();
  try {
    const result = spawnSync('bash', ['-c', 'set -euo pipefail; source "$1"; backup_key_fingerprint "$2"', 'sh', join(f.root, 'scripts/backup-key.sh'), backupKey], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), escrowFingerprint(), 'the shell implementation and Node\'s crypto agree');
    assert.match(result.stdout.trim(), /^[0-9a-f]{16}$/);
    assert.ok(!backupKey.includes(result.stdout.trim()) && !result.stdout.includes(tail));
    assert.notEqual(escrowFingerprint(), escrowFingerprint('d4'.repeat(32)));
  } finally { f.cleanup(); }
});

test('confirm --key-file records the confirmation only when the whole file is the key, whatever the case or spacing', () => {
  const f = fixture();
  const copy = (name, text) => { const path = join(f.scratch, name); writeFileSync(path, text); return path; };
  try {
    // A copy that has the right end but one wrong character elsewhere, the end alone, a short copy and a file that is no key.
    const first = backupKey[0] === 'a' ? 'b' : 'a';
    const bad = {
      'one wrong character at the start': `${first}${backupKey.slice(1)}\n`,
      'one wrong character in the middle': `${backupKey.slice(0, 30)}${backupKey[30] === 'a' ? 'b' : 'a'}${backupKey.slice(31)}\n`,
      'only the end of the key': `${tail}\n`,
      'the key with a character missing': `${backupKey.slice(0, -1)}\n`,
      'another key': `${'d4'.repeat(32)}\n`,
      'an empty file': '',
      'not hexadecimal': `${'z'.repeat(64)}\n`,
    };
    for (const [what, text] of Object.entries(bad)) {
      const refused = f.run(['confirm', '--key-file', copy('copy.txt', text)]);
      assert.equal(refused.status, 1, what);
      assert.match(refused.stderr, /nothing was recorded/, what);
      assert.ok(!refused.stderr.includes(backupKey) && !refused.stdout.includes(backupKey), `${what}: the key is not echoed`);
      assert.equal(existsSync(f.record), false, `${what}: nothing recorded`);
    }
    assert.match(f.run(['confirm', '--key-file', copy('copy.txt', `${first}${backupKey.slice(1)}\n`)]).stderr, /not this installation's backup key \(at least one character differs\)/);
    assert.match(f.run(['confirm', '--key-file', join(f.scratch, 'absent.txt')]).stderr, /is not a readable file/);
    for (const args of [['confirm'], ['confirm', '--key-file'], ['confirm', '--last8', tail], ['confirm', '--key-file', 'a', 'b']]) {
      const refused = f.run(args);
      assert.equal(refused.status, 1, args.join(' '));
      assert.equal(existsSync(f.record), false);
    }
    assert.match(f.run(['confirm']).stderr, /confirm needs --key-file FILE/);
    assert.match(f.run(['confirm', '--last8', tail]).stderr, /Usage: bash scripts\/backup-key-escrow\.sh show \| check \[FILE\] \| confirm --key-file FILE/);
    // The host's own key file is no copy: it is lost with the host.
    const own = f.run(['confirm', '--key-file', join(f.state, 'config/backup.key')]);
    assert.equal(own.status, 1);
    assert.match(own.stderr, /this installation's own key file/);
    assert.equal(existsSync(f.record), false);
    // The whole key: upper case, spaces, a trailing newline or line ending and a second line are forgiven.
    const result = f.run(['confirm', '--key-file', copy('copy.txt', `  ${backupKey.toUpperCase().replace(/(.{8})/g, '$1 ')}\r\n`)]);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Confirmed: every character matches\. Recorded in .*backup-key\.escrow/);
    const lines = readFileSync(f.record, 'utf8').split('\n');
    assert.equal(lines[0], 'warehouse-backup-key-escrow-v1');
    assert.equal(lines[1], `key_fingerprint=${escrowFingerprint()}`);
    assert.match(lines[2], /^confirmed_utc=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    assert.match(lines[3], /^confirmed_by=\S+$/);
    assert.equal(statSync(f.record).mode & 0o777, 0o600);
    assert.ok(!readFileSync(f.record, 'utf8').includes(backupKey) && !readFileSync(f.record, 'utf8').includes(tail), 'the record does not hold the key');
    assert.deepEqual(readdirSync(join(f.state, 'config')).filter(n => n.startsWith('.backup-key.escrow')), [], 'no temporary file left');
  } finally { f.cleanup(); }
});

test('confirm never creates a backup key: on an installation that has none it refuses and points at show', () => {
  const f = fixture();
  try {
    rmSync(join(f.state, 'config/backup.key'));
    const copy = join(f.scratch, 'copy.txt'); writeFileSync(copy, `${backupKey}\n`);
    const result = f.run(['confirm', '--key-file', copy]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /has no backup key yet[\s\S]*backup-key-escrow\.sh show/);
    assert.equal(existsSync(join(f.state, 'config/backup.key')), false, 'no key was minted that nobody has seen');
    assert.equal(existsSync(f.record), false);
    assert.doesNotMatch(result.stderr, /Created the backup key/);
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
    assert.match(f.run(['frobnicate']).stderr, /Usage: bash scripts\/backup-key-escrow\.sh show \| check \[FILE\] \| confirm --key-file FILE/);
  } finally { f.cleanup(); }
});

test('show needs a terminal and prints no key to a pipe or a file', () => {
  const f = fixture();
  try {
    const result = f.run(['show'], {}, { input: `${backupKey}\n` });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /needs a terminal/);
    assert.ok(!result.stdout.includes(backupKey) && !result.stderr.includes(backupKey), 'the key was not printed');
    assert.equal(existsSync(f.record), false);
    const toFile = spawnSync('bash', ['-c', 'bash "$1" show > "$2"', 'sh', join(f.root, 'scripts/backup-key-escrow.sh'), join(f.scratch, 'out.txt')], { encoding: 'utf8', env: f.env() });
    assert.equal(toFile.status, 1);
    assert.ok(!readFileSync(join(f.scratch, 'out.txt'), 'utf8').includes(backupKey));
  } finally { f.cleanup(); }
});

test('show prints the key once, asks for the whole key back, retries twice, and records the confirmation only on a full match', { skip: !haveScript && 'the script command (util-linux) is not installed' }, () => {
  const f = fixture();
  // `script` gives the command a pseudo terminal; what is typed is fed from the pipe.
  const show = typed => spawnSync('script', ['-qec', `bash ${join(f.root, 'scripts/backup-key-escrow.sh')} show`, '/dev/null'], { encoding: 'utf8', env: f.env(), input: typed });
  // The answers are fed one at a time, after each prompt: a terminal echoes what arrives before the program has switched echo off.
  const showSlowly = lines => spawnSync('bash', ['-c', '{ for l in "$@"; do sleep 0.5; printf "%s\\n" "$l"; done; } | script -qec "bash $0 show" /dev/null', join(f.root, 'scripts/backup-key-escrow.sh'), ...lines], { encoding: 'utf8', env: f.env() });
  const wrongInMiddle = `${backupKey.slice(0, 20)}${backupKey[20] === 'a' ? 'b' : 'a'}${backupKey.slice(21)}`;
  try {
    // Three wrong copies: the end of the key alone, a copy with the right end and one wrong character in the middle (what the
    // old last-8 check let through), and a short one.
    let result = showSlowly([tail, wrongInMiddle, backupKey.slice(0, 40)]);
    assert.equal(result.status, 1, result.stdout);
    assert.equal(result.stdout.split(backupKey).length - 1, 1, 'the key is printed once');
    assert.ok(!result.stdout.includes(wrongInMiddle), 'what is typed is not shown back');
    assert.match(result.stdout, /away from the facility/);
    assert.match(result.stdout, /attempt 1 of 3\): you gave 8 characters[\s\S]*attempt 2 of 3\): you gave 64 characters, but at least one is not the same[\s\S]*attempt 3 of 3\): you gave 40 characters/);
    assert.match(result.stdout, /Nothing was recorded\./);
    assert.match(result.stdout, /still on this terminal[\s\S]*clear/);
    assert.equal(existsSync(f.record), false, 'a copy with the right end and a mistake elsewhere is not a confirmation');
    // A mismatch first, then the whole key (upper case and spaces are forgiven, so is a paste in groups).
    result = show(`${wrongInMiddle}\n${backupKey.toUpperCase().replace(/(.{8})/g, '$1 ')} \n`);
    assert.equal(result.status, 0, result.stdout);
    assert.match(result.stdout, /attempt 1 of 3[\s\S]*Confirmed: every character matches\. Recorded in/);
    assert.match(result.stdout, /still on this terminal[\s\S]*clear/);
    assert.equal(readFileSync(f.record, 'utf8').split('\n')[1], `key_fingerprint=${escrowFingerprint()}`);
    // Asked again once confirmed: it says so and still lets the operator confirm.
    result = show(`${backupKey}\n`);
    assert.equal(result.status, 0, result.stdout);
    assert.match(result.stdout, /A copy of this key was already confirmed \(\d{4}-\d\d-\d\dT[\d:]+Z\)\. You can confirm again\./);
  } finally { f.cleanup(); }
});

test('show creates the key on an installation that has none yet, so the copy can be taken before the first backup', { skip: !haveScript && 'the script command (util-linux) is not installed' }, () => {
  const f = fixture();
  try {
    rmSync(join(f.state, 'config/backup.key'));
    const result = spawnSync('script', ['-qec', `bash ${join(f.root, 'scripts/backup-key-escrow.sh')} show`, '/dev/null'], { encoding: 'utf8', env: f.env(), input: 'x\nx\nx\n' });
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
