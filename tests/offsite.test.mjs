// scripts/offsite.sh (WH-145) against a stand-in S3 server (tests/offsite-fake-s3.mjs) and the real rclone: the optional encrypted
// off-site copy. Nothing here touches a real bucket, a real installation or the network beyond 127.0.0.1. The tests need the host program
// rclone (1.60 or newer, the one requirement of the feature); without it they skip, and the CI job installs it. A real S3 server in a container
// is tests/offsite-drill.sh (CI and by hand only).
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, statSync, utimesSync, lstatSync, cpSync, chmodSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { makeBackup, makeState, writeEscrow, scriptRoot, fakeDocker, filesUnder, repo, backupKey, writeKey } from './backup-test-helpers.mjs';
import { startFakeS3 } from './offsite-fake-s3.mjs';
import { offsiteStatus, usbBackupWarning, NO_OFFHOST_COPY } from '../scripts/usb-backup-status.mjs';

const rcloneOk = (() => {
  const r = spawnSync('rclone', ['version'], { encoding: 'utf8' });
  const m = /^rclone v(\d+)\.(\d+)/.exec(r.stdout ?? '');
  return r.status === 0 && m && (Number(m[1]) > 1 || Number(m[2]) >= 60);
})();
const skip = rcloneOk ? false : 'rclone 1.60 or newer is not installed';
const SECRET = 'FAKESecretKeyValue1234567890';
const KEYID = 'FAKEACCESSKEY01';
const BUCKET = 'warehouse-offsite-test';
const SCRIPT = join(repo, 'scripts/offsite.sh');

// Runs a command without blocking this process (the stand-in server lives in it).
const run = (args, { env = {}, cmd = 'bash', cwd } = {}) => new Promise(resolve => {
  const child = spawn(cmd, args, { cwd, env: { ...process.env, ...env } });
  let stdout = ''; let stderr = '';
  child.stdout.on('data', d => { stdout += d; }); child.stderr.on('data', d => { stderr += d; });
  child.on('close', status => resolve({ status, stdout, stderr, all: stdout + stderr }));
});

const day = (n) => `warehouse-202611${String(n).padStart(2, '0')}T010000Z`;
// A backup whose files all have one fixed time, as the hard-linked files of two nights of scripts/backup.sh have: the object of a file
// that did not change is then the same object.
function fixedTimes(dir) {
  const walk = path => {
    for (const entry of readdirSync(path, { withFileTypes: true })) {
      const full = join(path, entry.name);
      if (entry.isDirectory()) walk(full);
      utimesSync(full, 1700000000, 1700000000);
    }
  };
  walk(dir);
}
function night(state, name, extra = [], env) {
  const dir = makeBackup(join(state, 'backups', name), { format: 'warehouse-backup-v6', objects: ['documents/a.pdf/v1', 'photos/Rakesh Patel Cold Room/v2.jpg/v1', ...extra], ...(env ? { env } : {}) });
  fixedTimes(dir);
  return dir;
}
async function fixture({ credentialsMode = 0o600, accessKey = KEYID } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-offsite-'));
  const state = makeState(scratch); writeEscrow(state);
  mkdirSync(join(state, 'backups'), { mode: 0o700 });
  const s3 = await startFakeS3({ accessKey: KEYID, bucket: BUCKET });
  const cred = join(scratch, 'offsite-credentials');
  writeFileSync(cred, `access_key_id=${accessKey}\nsecret_access_key=${SECRET}\n`, { mode: credentialsMode });
  chmodSync(cred, credentialsMode);
  const env = { WAREHOUSE_STATE_DIR: state };
  const off = (args, extra = {}) => run([SCRIPT, ...args], { env: { ...env, ...extra } });
  const on = (extra = []) => off(['on', '--endpoint', s3.endpoint, '--bucket', BUCKET, '--credentials-file', cred, ...extra]);
  const hashBackups = () => spawnSync('bash', ['-c', 'cd "$1/backups" && find . -type f -exec sha256sum {} + | sort -k2 | sha256sum', 'sh', state], { encoding: 'utf8' }).stdout;
  const cleanup = async () => { await s3.close(); rmSync(scratch, { recursive: true, force: true }); };
  return { scratch, state, s3, cred, off, on, env, hashBackups, cleanup };
}
const configFiles = f => readdirSync(join(f.state, 'config')).sort();
const bucketKeys = f => [...f.s3.objects.keys()].sort();
const text = f => [...f.s3.objects.values()].map(o => o.body.toString('latin1')).join('\n');

test('off by default: nothing is set up, run does nothing and reaches no server, and the status says so', { skip }, async () => {
  const f = await fixture();
  try {
    night(f.state, day(12));
    let r = await f.off(['status']);
    assert.equal(r.status, 0); assert.match(r.stdout, /not set up \(off by default\)/);
    r = await f.off(['run']);
    assert.equal(r.status, 0); assert.match(r.stderr, /off-site copy is off/);
    assert.equal(f.s3.requests.length, 0);
    assert.equal(configFiles(f).some(n => n.startsWith('offsite')), false);
    assert.deepEqual(offsiteStatus(f.state), { enabled: false, fresh: false, problem: null });
    // watch-daily.sh runs it only when the settings file says ENABLED=yes (see the watch-daily test below).
    assert.equal(spawnSync('bash', ['-n', SCRIPT]).status, 0);
  } finally { await f.cleanup(); }
});

test('on refuses half-given or unusable settings, and a bucket or key that does not work, and stores nothing', { skip }, async () => {
  const f = await fixture();
  try {
    const usage = /Usage: bash scripts\/offsite\.sh on/;
    for (const args of [['--endpoint', f.s3.endpoint, '--bucket', BUCKET], ['--endpoint', f.s3.endpoint, '--credentials-file', f.cred], ['--bucket', BUCKET, '--credentials-file', f.cred], ['--endpoint', f.s3.endpoint]]) {
      const r = await f.off(['on', ...args]);
      assert.equal(r.status, 1, args.join(' ')); assert.match(r.stderr, usage);
    }
    let r = await f.off(['on', '--endpoint', f.s3.endpoint, '--bucket', BUCKET, '--credentials-file', f.cred, '--bogus', 'x']);
    assert.match(r.stderr, /Unknown option for on: --bogus/);
    r = await f.off(['on', '--endpoint', 'http://example.com', '--bucket', BUCKET, '--credentials-file', f.cred]);
    assert.match(r.stderr, /Check failed \(endpoint\).*https/);
    r = await f.off(['on', '--endpoint', f.s3.endpoint, '--bucket', 'Bad_Bucket', '--credentials-file', f.cred]);
    assert.match(r.stderr, /Check failed \(bucket\)/);
    r = await f.on(['--region', 'bad region']); assert.match(r.stderr, /Check failed \(region\)/);
    r = await f.on(['--max-rate', '0']); assert.match(r.stderr, /Check failed \(max rate\)/);
    assert.equal(f.s3.requests.length, 0, 'refused before any request');
    chmodSync(f.cred, 0o644);
    r = await f.on(); assert.equal(r.status, 1); assert.match(r.stderr, /must belong to this user with mode 0600/);
    assert.equal(f.s3.requests.length, 0);
    chmodSync(f.cred, 0o600);
    // A wrong access key: the bucket answers 403, and the message names the check that failed. The secret is never printed.
    writeFileSync(f.cred, `access_key_id=WRONGACCESSKEY1\nsecret_access_key=${SECRET}\n`, { mode: 0o600 });
    r = await f.on();
    assert.equal(r.status, 1); assert.match(r.stderr, /Check failed \(write\)/); assert.ok(!r.all.includes(SECRET));
    writeFileSync(f.cred, `access_key_id=${KEYID}\nsecret_access_key=${SECRET}\n`, { mode: 0o600 });
    // A bucket that does not exist, and one that refuses writes (quota).
    r = await f.off(['on', '--endpoint', f.s3.endpoint, '--bucket', 'nosuchbucket', '--credentials-file', f.cred]);
    assert.match(r.stderr, /Check failed \(write\)/);
    f.s3.behaviour.quotaFull = true;
    r = await f.on(); assert.match(r.stderr, /Check failed \(write\)/);
    // The file lacks a line.
    writeFileSync(f.cred, `access_key_id=${KEYID}\n`, { mode: 0o600 });
    f.s3.behaviour.quotaFull = false;
    r = await f.on(); assert.match(r.all, /needs both access_key_id= and secret_access_key=/);
    assert.equal(configFiles(f).some(n => n.startsWith('offsite')), false, 'nothing stored by a refused on');
    assert.equal(f.s3.objects.size, 0, 'the test object is not left behind');
  } finally { await f.cleanup(); }
});

test('on, run: what lands in the bucket is encrypted (no dump, no file names, hex object names), the credentials stay private, and a second night sends only what changed', { skip }, async () => {
  const f = await fixture();
  try {
    const first = night(f.state, day(12));
    let r = await f.on();
    assert.equal(r.status, 0, r.all);
    for (const name of ['offsite.conf', 'offsite.credentials']) assert.equal(statSync(join(f.state, 'config', name)).mode & 0o777, 0o600, name);
    assert.equal(readFileSync(join(f.state, 'config/offsite.conf'), 'utf8').includes(SECRET), false, 'the settings file holds no secret');
    assert.equal(f.s3.objects.size, 0, 'the test object of on was removed');
    r = await f.off(['run']);
    assert.equal(r.status, 0, r.all);
    assert.match(r.stdout, /Off-site copy of warehouse-20261112T010000Z done: 12 files, 12 new/);
    const keys = bucketKeys(f);
    const prefix = keys[0].split('/').slice(0, 2).join('/');
    assert.match(prefix, /^warehouse-offsite\/k-[0-9a-f]{16}$/);
    for (const k of keys) assert.match(k.slice(prefix.length + 1), /^(objects\/[0-9a-f]{64}|backups\/warehouse-20261112T010000Z\.manifest)$/, 'only hex names and the backup name');
    const body = text(f);
    for (const plain of ['fake database dump', 'Rakesh Patel', 'bytes of stub', 'WAREHOUSE_PROJECT_NAME', 'documents', 'a.pdf', 'SHA256SUMS', 'database.dump', 'storage.manifest', 'warehouse-backup', 'ustar']) assert.ok(!body.includes(plain), `${plain} is not readable in the bucket`);
    for (const o of f.s3.objects.values()) assert.equal(o.body.subarray(0, 8).toString('latin1'), 'Salted__');
    // The secret is on no command line of the run, in no output, no file of the state, no backup, and on the wire only as a signature.
    assert.ok(!r.all.includes(SECRET));
    for (const req of f.s3.requests) assert.ok(!req.authorization.includes(SECRET) && !JSON.stringify(req.headers).includes(SECRET));
    assert.equal(spawnSync('grep', ['-rl', SECRET, join(f.state, 'backups'), join(f.state, 'config/offsite.conf'), join(f.state, 'config/offsite.last')], { encoding: 'utf8' }).stdout, '');
    assert.equal(filesUnder(first).some(n => /offsite/.test(n)), false, 'the credentials file is in no backup (WH-145 AC7)');
    assert.deepEqual(offsiteStatus(f.state), { enabled: true, fresh: true, problem: null });
    // Second night: one new photo, the rest is the same files; only the new photo and the changed lists travel.
    night(f.state, day(13), ['photos/new/n.jpg/v1']);
    r = await f.off(['run']);
    assert.equal(r.status, 0, r.all);
    const sent = Number(/files_sent=(\d+)/.exec(readFileSync(join(f.state, 'config/offsite.last'), 'utf8'))[1]);
    assert.ok(sent > 0 && sent < 13 / 2 + 1, `only what changed was sent (${sent} of 13)`);
    const names = (await f.off(['list'])).stdout.trim().split('\n');
    assert.deepEqual(names, [day(12), day(13)]);
    r = await f.off(['run']);   // the same night again sends nothing
    assert.match(r.stdout, /13 files, 0 new/);
    r = await f.off(['verify', '--deep']); assert.equal(r.status, 0, r.all); assert.match(r.stdout, /every object read back/);
    // off keeps the bucket; status never prints the secret.
    r = await f.off(['off']); assert.match(r.stdout, /untouched/);
    const before = f.s3.objects.size;
    r = await f.off(['run']); assert.match(r.stderr, /is off/); assert.equal(f.s3.objects.size, before);
    r = await f.off(['status']); assert.match(r.stdout, /Off-site copy: off/); assert.ok(!r.all.includes(SECRET));
    r = await f.off(['on']); assert.equal(r.status, 0, r.all);   // on again with no options: same bucket, same credentials
    assert.equal(offsiteStatus(f.state).enabled, true);
  } finally { await f.cleanup(); }
});

test('a refused upload, wrong stored credentials or a changed object fail the run, raise the alert and leave every local backup untouched', { skip }, async () => {
  const f = await fixture();
  try {
    night(f.state, day(12));
    assert.equal((await f.on()).status, 0);
    const local = f.hashBackups();
    // Stored credentials that the bucket does not know.
    const stored = join(f.state, 'config/offsite.credentials');
    const good = readFileSync(stored, 'utf8');
    writeFileSync(stored, good.replace(KEYID, 'WRONGACCESSKEY1'), { mode: 0o600 });
    let r = await f.off(['run']);
    assert.equal(r.status, 1); assert.match(r.stderr, /Off-site copy failed/); assert.ok(!r.all.includes(SECRET));
    let s = offsiteStatus(f.state);
    assert.equal(s.fresh, false); assert.match(s.problem, /off-site copy of the backups failed/);
    assert.equal(f.hashBackups(), local, 'local backups intact');
    // The bucket refuses the upload (quota).
    writeFileSync(stored, good, { mode: 0o600 });
    f.s3.behaviour.quotaFull = true;
    r = await f.off(['run']);
    assert.equal(r.status, 1); assert.match(r.stderr, /the bucket refused the upload/);
    assert.equal(f.hashBackups(), local);
    f.s3.behaviour.quotaFull = false;
    // A good night clears it.
    r = await f.off(['run']); assert.equal(r.status, 0, r.all);
    assert.equal(offsiteStatus(f.state).problem, null);
    // One changed byte in the bucket: the deep check names it, and no manifest or object of the copy passes as good.
    for (const [k, o] of f.s3.objects) if (k.includes('/objects/')) { o.body[o.body.length - 1] ^= 1; break; }
    r = await f.off(['verify', '--deep']);
    assert.equal(r.status, 1); assert.match(r.stderr, /not what its name says/);
    // A restore from a changed manifest is refused too.
    for (const [k, o] of f.s3.objects) if (k.endsWith('.manifest')) o.body[o.body.length - 1] ^= 1;
    r = await f.off(['verify']); assert.equal(r.status, 1); assert.match(r.stderr, /does not decrypt|does not match the backup key|is not valid/);
    assert.equal(f.hashBackups(), local);
  } finally { await f.cleanup(); }
});

test('the key copy gate: on and run are refused until the backup key copy is confirmed', { skip }, async () => {
  const f = await fixture();
  try {
    night(f.state, day(12));
    rmSync(join(f.state, 'config/backup-key.escrow'));
    let r = await f.on();
    assert.equal(r.status, 1); assert.match(r.stderr, /Check failed \(backup key copy\)/);
    writeEscrow(f.state);
    assert.equal((await f.on()).status, 0);
    rmSync(join(f.state, 'config/backup-key.escrow'));
    r = await f.off(['run']);
    assert.equal(r.status, 1); assert.match(r.stderr, /backup key copy is not confirmed/);
    assert.equal(f.s3.objects.size, 0);
  } finally { await f.cleanup(); }
});

test('fetch rebuilds the backup byte for byte from the bucket, and refuses another backup key, wrong credentials and an unusable destination', { skip }, async () => {
  const f = await fixture();
  try {
    const original = night(f.state, day(12));
    night(f.state, day(13), ['photos/new/n.jpg/v1']);
    assert.equal((await f.on()).status, 0);
    assert.equal((await f.off(['run', join(f.state, 'backups', day(12))])).status, 0);
    assert.equal((await f.off(['run'])).status, 0);
    const dest = join(f.scratch, 'dest'); mkdirSync(dest, { mode: 0o700 });
    const key = join(f.state, 'config/backup.key');
    const fetchArgs = ['fetch', '--endpoint', f.s3.endpoint, '--bucket', BUCKET, '--credentials-file', f.cred, '--backup-key', key, '--dest', dest];
    let r = await f.off([...fetchArgs, '--backup', day(12)]);
    assert.equal(r.status, 0, r.all); assert.equal(r.stdout.trim(), join(dest, day(12)));
    assert.deepEqual(filesUnder(join(dest, day(12))), filesUnder(original));
    assert.equal(spawnSync('diff', ['-r', original, join(dest, day(12))]).status, 0, 'identical content');
    assert.equal(statSync(join(dest, day(12))).mode & 0o777, 0o700);
    r = await f.off(fetchArgs);   // newest by default
    assert.equal(r.stdout.trim(), join(dest, day(13)));
    // Another backup key holds nothing here; the files are not opened.
    const other = writeKey(join(f.scratch, 'other.key'), '11'.repeat(32));
    r = await f.off(fetchArgs.map(a => (a === key ? other : a)).concat([]));
    assert.equal(r.status, 1); assert.match(r.stderr, /holds no backup made with this backup key/);
    r = await f.off([...fetchArgs, '--backup', 'warehouse-20200101T000000Z']);
    assert.equal(r.status, 1); assert.match(r.stderr, /already exists|No backup/);
    chmodSync(f.cred, 0o644);
    r = await f.off(fetchArgs); assert.equal(r.status, 1); assert.match(r.stderr, /mode 0600/);
    chmodSync(f.cred, 0o600);
    r = await f.off(['fetch', '--endpoint', f.s3.endpoint]); assert.match(r.stderr, /fetch needs/);
    // The same restore with a changed object in the bucket is refused before anything is accepted.
    for (const [k, o] of f.s3.objects) if (k.includes('/objects/')) { o.body[o.body.length - 1] ^= 1; break; }
    const dest2 = join(f.scratch, 'dest2'); mkdirSync(dest2, { mode: 0o700 });
    r = await f.off(fetchArgs.map(a => (a === dest ? dest2 : a)).concat(['--backup', day(12)]));
    assert.equal(r.status, 1, 'a damaged object stops the restore');
  } finally { await f.cleanup(); }
});

test('retention keeps the last 14 backups and the first of each of the last 12 months over 400 nights', () => {
  const names = [];
  for (let i = 0; i < 400; i++) { const d = new Date(Date.UTC(2025, 9, 1) + i * 86400000); names.push(`warehouse-${d.toISOString().slice(0, 10).replaceAll('-', '')}T010000Z`); }
  const r = spawnSync('bash', [SCRIPT, 'keep-list'], { input: names.join('\n') + '\n', encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: '/nonexistent' } });
  assert.equal(r.status, 0, r.stderr);
  const kept = r.stdout.trim().split('\n');
  assert.deepEqual(kept.slice(-14), names.slice(-14), 'the last 14 nights');
  const months = new Set(kept.map(n => n.slice(10, 16)));
  assert.equal(months.size, 12 + 0, 'one backup in each of the last 12 months');
  for (const m of months) assert.equal(kept.filter(n => n.slice(10, 16) === m)[0], names.find(n => n.slice(10, 16) === m) ?? kept[0], `the first backup of ${m}`);
  assert.ok(kept.length >= 14 && kept.length <= 26, `kept ${kept.length}`);
  assert.ok(!kept.includes(names[100]), 'a night from 8 months ago that is not the first of its month is gone');
});

test('monitoring: a checked upload of the last 2 days is the off-host copy (quiet at 1 day, said at 3 days), a failed one raises offsite_upload_failed, and the key copy rule stays', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-offsite-alert-'));
  try {
    const state = makeState(scratch); writeEscrow(state);
    const etc = join(scratch, 'etc'); mkdirSync(etc);
    const now = Date.UTC(2026, 10, 14, 12);
    const day1 = Math.floor((now - 86400000) / 1000), day3 = Math.floor((now - 3 * 86400000) / 1000);
    const conf = since => writeFileSync(join(state, 'config/offsite.conf'), `ENABLED=yes\nENDPOINT=https://x.example.com\nBUCKET=b-test\nREGION=\nMAX_RATE=\nENABLED_EPOCH=${since}\n`, { mode: 0o600 });
    const last = (result, success) => writeFileSync(join(state, 'config/offsite.last'), `result=${result}\nfinished_utc=2026-11-14T01:00:00Z\nfinished_epoch=${success}\nlast_success_epoch=${success}\nmessage=${result === 'ok' ? 'uploaded' : 'the bucket refused'}\n`, { mode: 0o600 });
    const warn = status => usbBackupWarning(state, { now, etc, offsiteFresh: status.fresh, graceOver: true });
    assert.equal(warn(offsiteStatus(state, now)), NO_OFFHOST_COPY, 'off: today\'s rule');
    conf(day3 - 86400); last('ok', day1);
    let s = offsiteStatus(state, now);
    assert.deepEqual(s, { enabled: true, fresh: true, problem: null }); assert.equal(warn(s), null, '1-day-old upload satisfies offhost_copy_missing');
    last('ok', day3);
    s = offsiteStatus(state, now);
    assert.equal(s.fresh, false); assert.match(s.problem, /No off-site upload has been checked in the last 2 days/); assert.equal(warn(s), NO_OFFHOST_COPY, '3 days: said again');
    last('failed', day1);
    s = offsiteStatus(state, now); assert.match(s.problem, /failed at 2026-11-14T01:00:00Z: the bucket refused/); assert.equal(s.fresh, false);
    last('ok', day1);
    rmSync(join(state, 'config/backup-key.escrow'));
    assert.match(warn(offsiteStatus(state, now)), /off-site copy is encrypted with the backup key and cannot be opened without it/, 'the key copy rule still applies');
    writeEscrow(state);
    // Switched on a few hours ago and no upload yet: not an alert yet.
    rmSync(join(state, 'config/offsite.last'));
    conf(Math.floor(now / 1000) - 3600);
    assert.equal(offsiteStatus(state, now).problem, null);
    conf(day3 - 3600);
    assert.match(offsiteStatus(state, now).problem, /No off-site upload/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

// scripts/watch-daily.sh with stand-ins for the steps: the off-site step runs last, only when switched on and only for a verified backup, with
// its own time limit, and what it does or fails to do changes nothing above it.
function dailyFixture() {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-offsite-daily-'));
  const root = join(scratch, 'checkout');
  cpSync(join(repo, 'scripts'), join(root, 'scripts'), { recursive: true });
  const state = join(scratch, 'state');
  for (const d of ['config', 'public', 'backups']) mkdirSync(join(state, d), { recursive: true });
  writeFileSync(join(state, 'config/compose.env'), 'WAREHOUSE_PROJECT_NAME=warehouse-test\n', { mode: 0o600 });
  const log = join(scratch, 'order.log'); writeFileSync(log, '');
  const stubs = {
    'backup.sh': 'd="$WAREHOUSE_STATE_DIR/backups/warehouse-20261114T020000Z"; mkdir -p "$d"; echo x > "$d/metadata.txt"; echo "Backup created at $d"',
    'verify-restore.sh': 'echo "verify $1" >> "$LOG"; [[ "${FAKE_VERIFY:-ok}" == ok ]] || { echo "Backup signature mismatch" >&2; exit 1; }',
    'retention.sh': 'echo "retention $*" >> "$LOG"',
    'offsite.sh': 'echo "offsite $*" >> "$LOG"; case "${FAKE_OFFSITE:-ok}" in ok) exit 0 ;; fail) echo "Off-site copy failed: the bucket refused" >&2; exit 1 ;; hang) sleep 30 ;; esac',
  };
  for (const [name, body] of Object.entries(stubs)) writeFileSync(join(root, 'scripts', name), `#!/usr/bin/env bash\nset -uo pipefail\n${body}\n`, { mode: 0o755 });
  const result = join(scratch, 'result.txt');
  const go = (extra = {}) => {
    writeFileSync(log, '');
    const r = spawnSync('bash', [join(root, 'scripts/watch-daily.sh'), result], { encoding: 'utf8', timeout: 60000,
      env: { ...process.env, WAREHOUSE_STATE_DIR: state, LOG: log, WAREHOUSE_WATCH_NODE: process.execPath, WAREHOUSE_WATCH_KILL_AFTER: '1s', ...extra } });
    const fields = Object.fromEntries(readFileSync(result, 'utf8').split('\n').filter(l => l.includes('=')).map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]));
    return { ...r, fields, log: readFileSync(log, 'utf8').trim().split('\n').filter(Boolean) };
  };
  const enable = () => writeFileSync(join(state, 'config/offsite.conf'), 'ENABLED=yes\n', { mode: 0o600 });
  return { scratch, state, go, enable };
}

test('watch-daily.sh runs the off-site copy last, only when switched on and only for a verified backup, and its failure changes nothing above it', () => {
  const f = dailyFixture();
  try {
    let r = f.go();
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.log.some(l => l.startsWith('offsite')), false, 'off by default: not called');
    assert.equal(r.fields.offsite, undefined);
    f.enable();
    const dir = join(f.state, 'backups/warehouse-20261114T020000Z');
    r = f.go();
    assert.equal(r.fields.offsite, 'ok'); assert.deepEqual(r.log.slice(-2), ['retention apply', `offsite run ${dir}`]);
    assert.equal(r.fields.done, '1');
    r = f.go({ FAKE_VERIFY: 'bad' });
    assert.equal(r.fields.verify, 'failed'); assert.equal(r.fields.offsite, 'skipped'); assert.match(r.fields.offsite_message, /no verified backup/);
    assert.equal(r.log.some(l => l.startsWith('offsite run')), false);
    r = f.go({ FAKE_OFFSITE: 'fail' });
    assert.equal(r.status, 0); assert.equal(r.fields.offsite, 'failed'); assert.match(r.fields.offsite_message, /bucket refused/);
    assert.deepEqual([r.fields.backup, r.fields.verify, r.fields.prune, r.fields.retention, r.fields.done], ['ok', 'ok', 'ok', 'ok', '1']);
    // A run that hits its time limit is stopped and recorded (mark-failed), and the pass still ends.
    r = f.go({ FAKE_OFFSITE: 'hang', WAREHOUSE_WATCH_OFFSITE_SECS: '1' });
    assert.equal(r.status, 0); assert.equal(r.fields.offsite, 'failed'); assert.match(r.fields.offsite_message, /timed out/);
    assert.ok(r.log.some(l => l.startsWith('offsite mark-failed the upload did not finish within its time limit')));
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('restore-host --from-offsite rebuilds the backup from the bucket and restores it as a folder given by hand; it needs the backup key and refuses mixed options', { skip }, async () => {
  const f = await fixture();
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-offsite-rh-'));
  try {
    night(f.state, day(12), [], 'WAREHOUSE_PROJECT_NAME=warehouse-lost\nWAREHOUSE_DB_PATH=/srv/warehouse/lost/data/db\nWAREHOUSE_STORAGE_PATH=/srv/warehouse/lost/data/storage\nWAREHOUSE_MANIFEST_PATH=/srv/warehouse/lost/public/instance.json\nJWT_SECRET=kept\n');
    assert.equal((await f.on()).status, 0);
    assert.equal((await f.off(['run'])).status, 0);
    // The lost host is gone: only the operator's copy of the key and of the bucket settings remain.
    const keyCopy = writeKey(join(scratch, 'key-copy.txt'));
    const root = scriptRoot(scratch);
    writeFileSync(join(root, 'scripts/doctor.mjs'), "console.log('Host prerequisites and state filesystem preflight passed.');\n");
    writeFileSync(join(root, 'scripts/restore.sh'), '#!/usr/bin/env bash\nprintf "%s\\n" "STATE=$WAREHOUSE_STATE_DIR ARGS=$*" >> "$RESTORE_LOG"\nmkdir -p "$WAREHOUSE_STATE_DIR/data/db" "$WAREHOUSE_STATE_DIR/data/storage"\n', { mode: 0o755 });
    const bin = fakeDocker(join(scratch, 'bin'));
    const parent = join(scratch, 'srv'); mkdirSync(parent, { mode: 0o755 });
    const log = join(scratch, 'restore.log'); writeFileSync(log, ''); const dlog = join(scratch, 'docker.log'); writeFileSync(dlog, '');
    const rh = (args, extra = {}) => run([join(root, 'scripts/restore-host.sh'), ...args], { env: { PATH: `${bin}:${process.env.PATH}`, FAKE_DOCKER_LOG: dlog, RESTORE_LOG: log, WAREHOUSE_STATE_DIR: '', ...extra } });
    const state2 = join(parent, 'acme');
    const offArgs = ['--from-offsite', '--offsite-endpoint', f.s3.endpoint, '--offsite-bucket', BUCKET, '--offsite-credentials', f.cred];
    let r = await rh(['--state-dir', state2, '--yes', ...offArgs]);
    assert.equal(r.status, 1); assert.match(r.stderr, /needs --backup-key/);
    r = await rh(['--state-dir', state2, '--yes', '--allow-unsigned', ...offArgs]);
    assert.equal(r.status, 1); assert.match(r.stderr, /cannot be used with --allow-unsigned/);
    r = await rh(['--state-dir', state2, '--backup-key', keyCopy, '--yes', ...offArgs, join(scratch, 'x')]);
    assert.equal(r.status, 1, 'a backup folder and --from-offsite together are refused');
    r = await rh(['--state-dir', state2, '--backup-key', keyCopy, '--yes', '--offsite-bucket', BUCKET, join(scratch, 'x')]);
    assert.equal(r.status, 1, '--offsite-* without --from-offsite is refused');
    assert.deepEqual(readdirSync(parent), [], 'refusals create nothing');
    r = await rh(['--state-dir', state2, '--backup-key', keyCopy, '--yes', ...offArgs]);
    assert.equal(r.status, 0, r.all);
    assert.equal(readFileSync(log, 'utf8'), `STATE=${state2} ARGS=--yes --relocated ${join(state2, 'backups', day(12))}\n`);
    assert.equal(spawnSync('diff', ['-r', join(f.state, 'backups', day(12)), join(state2, 'backups', day(12))]).status, 0, 'the restored backup is the one that was uploaded');
    assert.deepEqual(readdirSync(parent), ['acme'], 'no staging folder left');
    // A changed object in the bucket stops it before anything is created.
    for (const [k, o] of f.s3.objects) if (k.includes('/objects/')) { o.body[o.body.length - 1] ^= 1; break; }
    const state3 = join(parent, 'acme2');
    r = await rh(['--state-dir', state3, '--backup-key', keyCopy, '--yes', ...offArgs]);
    assert.equal(r.status, 1); assert.match(r.all, /Could not rebuild the backup from the bucket/); assert.equal(existsSync(state3), false);
    assert.deepEqual(readdirSync(parent), ['acme']);
  } finally { await f.cleanup(); rmSync(scratch, { recursive: true, force: true }); }
});
