// scripts/offsite.sh (WH-145) against a stand-in S3 server (tests/offsite-fake-s3.mjs) and the real rclone: the optional encrypted
// off-site copy. Nothing here touches a real bucket, a real installation or the network beyond 127.0.0.1. The tests need the host program
// rclone (1.60 or newer, the one requirement of the feature); without it they skip, and the CI job installs it. A real S3 server in a container
// is tests/offsite-drill.sh (CI and by hand only).
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, statSync, utimesSync, lstatSync, cpSync, chmodSync, symlinkSync } from 'node:fs';
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
  const s3 = await startFakeS3({ accessKey: KEYID, secretKey: SECRET, bucket: BUCKET });
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
    // The right key id with a wrong secret: the stand-in checks the SigV4 signature, so it answers 403 too.
    writeFileSync(f.cred, `access_key_id=${KEYID}\nsecret_access_key=WRONGsecretKeyValue123456\n`, { mode: 0o600 });
    r = await f.on();
    assert.equal(r.status, 1); assert.match(r.stderr, /Check failed \(write\)/); assert.ok(!r.all.includes('WRONGsecretKeyValue123456') && !r.all.includes(SECRET));
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

// ---------------------------------------------------------------- the Medium fixes of the review, and the Lows

// A signed manifest (and its one object) for a backup holding one file, made with the backup key outside offsite.sh, so that a test can
// store in the bucket what a hostile or broken writer holding the key could: an object whose tar member is not the manifest's path.
const FORGE = `set -euo pipefail
source "$1/scripts/backup-key.sh"; backup_key_load "$2"
sum="$(sha256sum < "$3" | cut -d' ' -f1)"; id="$(backup_hmac "$BACKUP_KEY" warehouse-offsite-object-v1 <<<"$sum")"
backup_encrypt "$BACKUP_KEY" < "$3" > "$4"; fp="$(backup_key_fingerprint "$BACKUP_KEY")"
printf 'warehouse-offsite-manifest-v1\\nbackup %s\\nkey %s\\nF 644 %s %s %s\\n' "$5" "$fp" "$(stat -c %s "$3")" "$id" "$6" > "$4.body"
{ cat "$4.body"; printf 'mac %s\\n' "$(backup_hmac "$BACKUP_KEY" warehouse-offsite-manifest-v1 < "$4.body")"; } | backup_encrypt "$BACKUP_KEY" > "$7"
printf '%s %s\\n' "$id" "$fp"`;

test('fetch gives back names in Gujarati, with a backslash, a tab and a leading dash byte for byte, under LC_ALL=C and C.UTF-8', { skip }, async () => {
  const f = await fixture();
  try {
    const odd = ['photos/ગ્રાહક ફોટો/v1.jpg/v1', 'photos/back\\slash.jpg/v1', 'photos/tab\tname.jpg/v1', 'photos/-dash.jpg/v1', 'photos/quote"and\'s.jpg/v1'];
    const original = night(f.state, day(12), odd);
    assert.equal((await f.on()).status, 0);
    const key = join(f.state, 'config/backup.key');
    for (const locale of ['C', 'C.UTF-8']) {
      const r = await f.off(['run', original], { LC_ALL: locale, LANG: locale });
      assert.equal(r.status, 0, `${locale}: ${r.all}`);
      const dest = join(f.scratch, `dest-${locale}`); mkdirSync(dest, { mode: 0o700 });
      const fetched = await f.off(['fetch', '--endpoint', f.s3.endpoint, '--bucket', BUCKET, '--credentials-file', f.cred, '--backup-key', key, '--dest', dest], { LC_ALL: locale, LANG: locale });
      assert.equal(fetched.status, 0, `${locale}: ${fetched.all}`);
      const got = join(dest, day(12));
      assert.deepEqual(filesUnder(got), filesUnder(original), `${locale}: the same names`);
      assert.equal(spawnSync('diff', ['-r', original, got], { env: { ...process.env, LC_ALL: 'C' } }).status, 0, `${locale}: identical content`);
      for (const name of odd) assert.equal(readFileSync(join(got, 'storage/stub/stub', name), 'utf8'), `bytes of stub/stub/${name}`, `${locale}: ${JSON.stringify(name)}`);
    }
  } finally { await f.cleanup(); }
});

test('fetch refuses an object whose tar holds a path with .., an absolute path, another name than the manifest says, or two members, and writes nothing outside the folder', { skip }, async () => {
  const f = await fixture();
  try {
    night(f.state, day(12));
    assert.equal((await f.on()).status, 0);
    assert.equal((await f.off(['run'])).status, 0);
    const key = join(f.state, 'config/backup.key');
    const keyed = [...f.s3.objects.keys()];
    const prefix = keyed.find(k => k.includes('/backups/')).split('/').slice(0, 2).join('/');
    const work = join(f.scratch, 'forge'); mkdirSync(work);
    writeFileSync(join(work, 'evil.txt'), 'evil'); writeFileSync(join(work, 'other.txt'), 'other'); writeFileSync(join(work, 'second.txt'), 'second');
    const outside = join(f.scratch, 'evil.txt'); const absolute = '/tmp/warehouse-offsite-abs-evil';
    const cases = {
      'a path with ..': ['--transform', 's,^,../,', 'evil.txt'],
      'an absolute path': ['-P', '--transform', `s,^,${absolute}/,`, 'evil.txt'],
      'another name than the manifest says': ['other.txt'],
      'two members': ['evil.txt', 'second.txt'],
    };
    for (const [label, args] of Object.entries(cases)) {
      const tar = join(work, 'x.tar');
      const made = spawnSync('tar', [...args.filter(a => a !== 'evil.txt' && a !== 'other.txt' && a !== 'second.txt'), '-cf', tar, '-C', work, ...args.filter(a => /\.txt$/.test(a))], { encoding: 'utf8' });
      assert.equal(made.status, 0, made.stderr);
      const forged = spawnSync('bash', ['-c', FORGE, 'sh', repo, key, tar, join(work, 'obj.enc'), day(14), 'docs/a.txt', join(work, 'm.enc')], { encoding: 'utf8' });
      assert.equal(forged.status, 0, forged.stderr);
      const [id] = forged.stdout.trim().split(' ');
      f.s3.objects.set(`${prefix}/objects/${id}`, { body: readFileSync(join(work, 'obj.enc')), modified: new Date() });
      f.s3.objects.set(`${prefix}/backups/${day(14)}.manifest`, { body: readFileSync(join(work, 'm.enc')), modified: new Date() });
      const dest = join(f.scratch, `dest-${label.replace(/\W+/g, '-')}`); mkdirSync(dest, { mode: 0o700 });
      const r = await f.off(['fetch', '--endpoint', f.s3.endpoint, '--bucket', BUCKET, '--credentials-file', f.cred, '--backup-key', key, '--dest', dest, '--backup', day(14)]);
      assert.equal(r.status, 1, `${label}: refused`);
      assert.match(r.stderr, /holds a different path|stopped at/, label);
      assert.equal(existsSync(outside), false, `${label}: nothing written beside the folder`);
      assert.equal(existsSync(join(absolute, 'evil.txt')), false, `${label}: nothing written at the absolute path`);
      assert.equal(existsSync(join(dest, day(14), 'docs/a.txt')), false, `${label}: the file was not unpacked`);
    }
  } finally { await f.cleanup(); rmSync('/tmp/warehouse-offsite-abs-evil', { recursive: true, force: true }); }
});

// The USB rules with an off-site copy that is fresh: USB set up here keeps its own checks; with no USB, the fresh copy is the off-host copy.
test('a fresh off-site copy does not hide a failed, stale or image-less USB copy, and it satisfies the off-host rule only where USB is not set up', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-offsite-usb-'));
  try {
    const state = makeState(scratch); writeEscrow(state);
    const etc = join(scratch, 'etc'); mkdirSync(etc);
    const now = Date.UTC(2026, 10, 14, 12);
    const sec = ms => Math.floor(ms / 1000);
    const fresh = { fresh: true };
    const warn = (offsiteFresh = true) => usbBackupWarning(state, { now, etc, offsiteFresh, graceOver: true });
    // No USB: the fresh upload is the off-host copy; without it the rule says no copy exists.
    assert.equal(warn(true), null); assert.equal(warn(false), NO_OFFHOST_COPY);
    // USB set up (encrypted archives, key copy confirmed).
    writeFileSync(join(etc, 'warehouse-usb-backup.conf'), `STATE=${state}\nENCRYPT=yes\nENCRYPT_SET=typed\n`);
    const last = fields => writeFileSync(join(state, 'config/usb-backup.last'), Object.entries({ result: 'ok', finished_utc: '2026-11-14T01:00:00Z', last_success_epoch: sec(now - 86400000), ...fields }).map(([k, v]) => `${k}=${v}`).join('\n') + '\n', { mode: 0o600 });
    last({});
    assert.equal(warn(true), null, 'a good USB copy and a fresh off-site copy: quiet');
    last({ result: 'failed', message: 'the drive was full' });
    assert.match(warn(true), /The last USB backup failed at 2026-11-14T01:00:00Z: the drive was full/);
    last({ last_success_epoch: sec(now - 10 * 86400000) });
    assert.match(warn(true), /The last successful USB backup is 10 days old/);
    last({ images_problem: 'the images folder could not be copied' });
    assert.match(warn(true), /copied the archive but not the saved images: the images folder could not be copied/);
    rmSync(join(state, 'config/usb-backup.last'));
    assert.match(warn(true), /USB backup is set up but no copy has been made yet/);
    // The same texts with no off-site copy (the rule is unchanged by the feature).
    last({ result: 'failed', message: 'the drive was full' });
    assert.equal(warn(true), warn(false));
    // The key copy rule is said beside a USB problem, not instead of it.
    writeFileSync(join(etc, 'warehouse-usb-backup.conf'), `STATE=${state}\nENCRYPT=no\nENCRYPT_SET=typed\n`);
    rmSync(join(state, 'config/backup-key.escrow'));
    const both = warn(true);
    assert.match(both, /The last USB backup failed/); assert.match(both, /off-site copy is encrypted with the backup key and cannot be opened without it/);
    // The doctor sees the same text (doctor.mjs passes offsiteStatus(state).fresh).
    assert.match(readFileSync(join(repo, 'scripts/doctor.mjs'), 'utf8'), /usbBackupWarning\(state, \{ offsiteFresh: offsiteStatus\(state\)\.fresh \}\)/);
    void fresh;
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('on --region alone keeps the stored settings and takes the new region; off leaves the credentials file and says so; a stale staging folder is removed and a linked decoy is not', { skip }, async () => {
  const f = await fixture();
  try {
    night(f.state, day(12));
    assert.equal((await f.on()).status, 0);
    const conf = join(f.state, 'config/offsite.conf');
    let r = await f.off(['off']);
    assert.match(r.stdout, /credentials stay in .*offsite\.credentials/);
    assert.ok(existsSync(join(f.state, 'config/offsite.credentials')), 'the credentials file stays');
    r = await f.off(['on', '--region', 'eu-test-1']);
    assert.equal(r.status, 0, r.all);
    const text = readFileSync(conf, 'utf8');
    assert.match(text, /^ENABLED=yes$/m); assert.match(text, /^REGION=eu-test-1$/m); assert.match(text, new RegExp(`^ENDPOINT=${f.s3.endpoint}$`, 'm')); assert.match(text, new RegExp(`^BUCKET=${BUCKET}$`, 'm'));
    // A run killed earlier left a staging folder; a link of that name to a folder elsewhere is a decoy and stays.
    const stale = join(f.state, 'backups/.offsite-work.AbC123'); mkdirSync(stale); writeFileSync(join(stale, 'file.tar'), 'left behind');
    const decoy = join(f.scratch, 'decoy'); mkdirSync(decoy); writeFileSync(join(decoy, 'keep.txt'), 'mine');
    symlinkSync(decoy, join(f.state, 'backups/.offsite-work.ZzZ999'));
    r = await f.off(['run']);
    assert.equal(r.status, 0, r.all);
    assert.equal(existsSync(stale), false, 'the stale staging folder is gone');
    assert.equal(readFileSync(join(decoy, 'keep.txt'), 'utf8'), 'mine', 'the decoy was not followed');
    assert.ok(lstatSync(join(f.state, 'backups/.offsite-work.ZzZ999')).isSymbolicLink());
    assert.deepEqual(readdirSync(join(f.state, 'backups')).filter(n => n.startsWith('.offsite-work.')), ['.offsite-work.ZzZ999'], 'the run leaves no staging of its own');
  } finally { await f.cleanup(); }
});

test('the room checks refuse before anything is sent or downloaded, fetch --reserve-copies counts the copies the restore makes, and a bucket error keeps rclone\'s words', { skip }, async () => {
  const f = await fixture();
  try {
    const original = night(f.state, day(12));
    writeFileSync(join(original, 'storage/stub/stub/documents/a.pdf/v1'), Buffer.alloc(8 * 1048576, 7));   // one 8 MiB stored file
    assert.equal((await f.on()).status, 0);
    // df as the kernel would report a full disk: the free bytes are FAKE_AVAIL for every question (backup-storage.test.mjs does the same).
    const bin = join(f.scratch, 'dfbin'); mkdirSync(bin);
    writeFileSync(join(bin, 'df'), '#!/bin/sh\nprintf "Avail\\n%s\\n" "$FAKE_AVAIL"\n', { mode: 0o755 });
    const env = avail => ({ PATH: `${bin}:${process.env.PATH}`, FAKE_AVAIL: String(avail) });
    const MiB = 1048576;
    // run: twice the largest file plus 64 MiB = 80 MiB.
    let r = await f.off(['run'], env(50 * MiB));
    assert.equal(r.status, 1); assert.match(r.stderr, /not enough free space in .*backups to prepare the upload: about 80 MiB are needed \(twice the largest file of warehouse-20261112T010000Z plus 64 MiB\), 50 MiB are free/);
    assert.equal(f.s3.objects.size, 0, 'nothing was sent');
    r = await f.off(['run'], env(500 * MiB)); assert.equal(r.status, 0, r.all);
    // fetch: the backup (8 MiB and a few bytes) + the largest object twice + 1 GiB; with --reserve-copies 9 the backup nine more times.
    const key = join(f.state, 'config/backup.key');
    const dest = join(f.scratch, 'dest'); mkdirSync(dest, { mode: 0o700 });
    const args = ['fetch', '--endpoint', f.s3.endpoint, '--bucket', BUCKET, '--credentials-file', f.cred, '--backup-key', key, '--dest', dest];
    const before = f.s3.requests.filter(q => q.path.includes('/objects/')).length;
    r = await f.off([...args, '--reserve-copies', '9'], env(1060 * MiB));
    assert.equal(r.status, 1); assert.match(r.stderr, /Refusing: rebuilding warehouse-20261112T010000Z and restoring from it needs about 1\d\d\d MiB in .*dest, but only 1060 MiB are free\. .*Nothing was downloaded\./);
    assert.equal(f.s3.requests.filter(q => q.path.includes('/objects/')).length, before, 'no object was downloaded');
    assert.deepEqual(readdirSync(dest), [], 'nothing created');
    r = await f.off([...args, '--reserve-copies', '10'], env(5000 * MiB)); assert.equal(r.status, 1); assert.match(r.stderr, /--reserve-copies must be a whole number from 0 to 9/);
    r = await f.off(args, env(1060 * MiB)); assert.equal(r.status, 0, r.all);   // the same free space is enough without copies
    // rclone's own words reach the message when the bucket refuses a request (a list failure under rclone 1.71 prints nothing at all, so the
    // text is pinned on an upload).
    night(f.state, day(13), ['photos/new/n.jpg/v1']);
    f.s3.behaviour.quotaFull = true;
    r = await f.off(['run']);
    assert.equal(r.status, 1); assert.match(r.stderr, /the bucket refused the upload of a file: .*(403|QuotaExceeded|Forbidden)/); assert.doesNotMatch(r.stderr, /no detail/);
  } finally { await f.cleanup(); }
});

test('on gives up on an endpoint nobody listens on within seconds', { skip }, async () => {
  const f = await fixture();
  try {
    night(f.state, day(12));
    const started = Date.now();
    const r = await f.off(['on', '--endpoint', 'http://127.0.0.1:1', '--bucket', BUCKET, '--credentials-file', f.cred]);
    assert.equal(r.status, 1); assert.match(r.stderr, /Check failed \(write\)/);
    assert.ok(Date.now() - started < 40000, `took ${Date.now() - started} ms`);
  } finally { await f.cleanup(); }
});
