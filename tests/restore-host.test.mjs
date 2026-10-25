// scripts/restore-host.sh against a fake docker and a private script root: the new
// state is built from the backup with only the three path lines rewritten, every
// refusal happens before anything is created, and restore.sh --relocated accepts
// exactly that difference.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, statSync, symlinkSync, copyFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { makeBackup, makeState, fakeDocker, scriptRoot, composeEnv, previousReleaseDbLines, instanceJson, repo, backupKey, signBackup, writeKey, hmacHex, centralKeySet, currentDatabaseImage, pngLetterhead, jpegLetterhead, xattrTool, xattrSkip } from './backup-test-helpers.mjs';
import { composeAvailable, renderedCompose } from './compose-render.mjs';

const NAME = 'warehouse-20260101T000000Z';
const sha = text => createHash('sha256').update(text).digest('hex');
const migrations = { '0001_first.sql': 'select 1;\n', '0002_second.sql': 'select 2;\n' };
const ledger = (names = Object.keys(migrations)) =>
  `migration_count=${names.length}\nmigration_fingerprint=${sha(names.map(n => `${n}:${sha(migrations[n])}`).join('\n'))}\n`;

function fixture(prefix, { integrity = ledger(), env, format = 'warehouse-backup-v5', xattrs = {} } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), prefix));
  const root = scriptRoot(scratch);
  mkdirSync(join(root, 'migrations'));
  for (const [name, body] of Object.entries(migrations)) writeFileSync(join(root, 'migrations', name), body);
  writeFileSync(join(root, 'scripts/doctor.mjs'), "console.log('Host prerequisites and state filesystem preflight passed.');\n");
  // A stand-in for restore.sh that records its call and sets data aside as the real one does.
  writeFileSync(join(root, 'scripts/restore.sh'), `#!/usr/bin/env bash
printf '%s\\n' "STATE=$WAREHOUSE_STATE_DIR ARGS=$*" >> "$RESTORE_LOG"
printf '%s' "\${WAREHOUSE_CENTRAL_KEY_PENDING:-}" > "$RESTORE_LOG.pending"
[[ "\${FAKE_RESTORE_FAIL:-}" != yes ]] || exit 3
mv "$WAREHOUSE_STATE_DIR/data/db" "$WAREHOUSE_STATE_DIR/data/db.pre-restore-20260101T000000Z"
mv "$WAREHOUSE_STATE_DIR/data/storage" "$WAREHOUSE_STATE_DIR/data/storage.pre-restore-20260101T000000Z"
mkdir -m 700 "$WAREHOUSE_STATE_DIR/data/db" "$WAREHOUSE_STATE_DIR/data/storage"
`);
  const original = '/srv/warehouse/lost-host';
  const backup = makeBackup(join(scratch, 'drive', NAME), {
    env: env ?? composeEnv(original, 'JWT_SECRET=kept-secret\nMSG91_AUTH_KEY=kept-key\n'), integrity, format, xattrs });
  // Rewrites SHA256SUMS as the backup tool would; only `sign` adds a valid signature.
  const resum = ({ format = 'warehouse-backup-v5', sign = true, files = '', databaseImage = currentDatabaseImage() } = {}) => {
    writeFileSync(join(backup, 'metadata.txt'), `format=${format}\ncreated_at_utc=20260101T000000Z\nsource_commit=abc1234\n${databaseImage === null ? "" : `database_image=${databaseImage}\n`}`);
    const sums = spawnSync('sh', ['-c', `sha256sum storage.tar.gz database.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt ${files} > SHA256SUMS`], { cwd: backup });
    assert.equal(sums.status, 0);
    if (sign) signBackup(backup); else rmSync(join(backup, 'SHA256SUMS.hmac'), { force: true });
  };
  if (format === 'warehouse-backup-v5') resum();
  // The operator's own copy of the lost installation's backup key.
  const keyFile = writeKey(join(scratch, 'operator-key-copy.txt'));
  const parent = join(scratch, 'srv'); mkdirSync(parent, { mode: 0o755 });
  const log = join(scratch, 'restore.log'); writeFileSync(log, '');
  const dockerLog = join(scratch, 'docker.log'); writeFileSync(dockerLog, '');
  const bin = fakeDocker(join(scratch, 'bin'));
  // Containers of the project exist only when FAKE_PROJECT_EXISTS=yes; FAKE_VOLUMES
  // lists the Docker volumes the host still has (space-separated, as `docker volume ls -q`).
  const wrap = join(scratch, 'wrap'); mkdirSync(wrap);
  writeFileSync(join(wrap, 'docker'), `#!/bin/sh
if [ "$1" = ps ] && [ -n "$FAKE_TAMPER_FILE" ]; then echo tampered >> "$FAKE_TAMPER_FILE"; fi
if [ "$1" = ps ] && [ "$FAKE_PROJECT_EXISTS" = yes ]; then printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"; echo 0123456789ab; exit 0; fi
if [ "$1" = volume ] && [ -n "$FAKE_VOLUMES" ]; then printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"; printf '%s\\n' $FAKE_VOLUMES; exit 0; fi
if [ "$1" = load ]; then
  printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
  case "$3" in *functions.tar) [ "$FAKE_LOAD_FAIL" = yes ] && { echo 'archive/tar: invalid tar header' >&2; exit 1; } ;; esac
  echo 'Loaded image: warehouse-test-image:latest'; exit 0
fi
if [ "$1" = image ] && [ -n "$FAKE_LOADED_IDS" ]; then case " $FAKE_LOADED_IDS " in *" $4 "*|*" $5 "*) printf '%s\\n' "$5"; exit 0 ;; esac; fi
exec ${bin}/docker "$@"
`, { mode: 0o755 });
  // `key` is the file passed as --backup-key; null leaves the option out.
  const run = (args, extra = {}, { key = keyFile } = {}) => {
    const result = spawnSync('bash', [join(root, 'scripts/restore-host.sh'), ...(key ? ['--backup-key', key] : []), ...args], { encoding: 'utf8',
      env: { ...process.env, PATH: `${wrap}:${process.env.PATH}`, FAKE_DOCKER_LOG: dockerLog, RESTORE_LOG: log, ...extra } });
    // What restore.sh (and so doctor --local) was told about a central key file that is still to be put back.
    return { ...result, restoreCalls: readFileSync(log, 'utf8'), keyPending: existsSync(`${log}.pending`) ? readFileSync(`${log}.pending`, 'utf8') : null };
  };
  const signArchive = file => writeFileSync(`${file}.hmac`, `warehouse-backup-hmac-v1 ${hmacHex(backupKey, 'warehouse-backup-archive-v1', readFileSync(`${file}.sha256`))}\n`);
  // `xattrs` packs the extended attributes of a v6 tree too, as an archive written for a USB drive does.
  const tarball = ({ sign = true, xattrs = false } = {}) => {
    const tar = join(scratch, 'drive', `${NAME}.tar`);
    assert.equal(spawnSync('tar', [...(xattrs ? ['--xattrs', "--xattrs-include=user.*", '--format=posix'] : []), '-C', join(scratch, 'drive'), '-cf', tar, NAME]).status, 0);
    writeFileSync(`${tar}.sha256`, spawnSync('sha256sum', [`${NAME}.tar`], { cwd: join(scratch, 'drive'), encoding: 'utf8' }).stdout);
    if (sign) signArchive(tar);
    return tar;
  };
  // The encrypted form backup-usb.sh writes, produced with the script's own cipher.
  const encrypted = ({ xattrs = false } = {}) => {
    const tar = tarball({ sign: false, xattrs });
    const enc = spawnSync('bash', ['-c', 'set -euo pipefail; source "$1"; backup_key_load "$2"; backup_encrypt "$BACKUP_KEY" < "$3" > "$3.enc"', 'sh', join(root, 'scripts/backup-key.sh'), keyFile, tar], { encoding: 'utf8' });
    assert.equal(enc.status, 0, enc.stderr);
    rmSync(tar); rmSync(`${tar}.sha256`);
    writeFileSync(`${tar}.enc.sha256`, spawnSync('sha256sum', [`${NAME}.tar.enc`], { cwd: join(scratch, 'drive'), encoding: 'utf8' }).stdout);
    signArchive(`${tar}.enc`);
    return `${tar}.enc`;
  };
  return { scratch, root, backup, parent, run, tarball, encrypted, signArchive, resum, keyFile, original, wrap, state: join(parent, 'acme') };
}
const clean = f => rmSync(f.scratch, { recursive: true, force: true });
const nothingCreated = (f, result) => {
  assert.deepEqual(readdirSync(f.parent), [], 'nothing created next to the state');
  assert.equal(result.restoreCalls, '', 'restore.sh never ran');
};

test('restore-host builds the state from the backup, rewrites only the three paths and hands over to restore.sh --relocated', () => {
  const f = fixture('warehouse-restore-host-dir-');
  try {
    const result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    const env = readFileSync(join(f.state, 'config/compose.env'), 'utf8');
    assert.equal(env, readFileSync(join(f.backup, 'compose.env'), 'utf8').replaceAll(f.original, f.state));
    assert.match(env, new RegExp(`^WAREHOUSE_DB_PATH=${f.state}/data/db$`, 'm'));
    assert.match(env, /^JWT_SECRET=kept-secret$/m, 'keys come from the backup');
    assert.equal(readFileSync(join(f.state, 'public/instance.json'), 'utf8'), instanceJson, 'identity unchanged');
    for (const [path, mode] of [['', 0o700], ['config', 0o700], ['public', 0o700], ['data', 0o700], ['config/compose.env', 0o600], ['public/instance.json', 0o644]]) {
      assert.equal(statSync(join(f.state, path)).mode & 0o777, mode, path || 'state');
    }
    assert.equal(readFileSync(join(f.state, 'backups', NAME, 'compose.env'), 'utf8'), readFileSync(join(f.backup, 'compose.env'), 'utf8'), 'backup kept unmodified');
    assert.ok(existsSync(join(f.backup, 'SHA256SUMS')), 'source backup left in place');
    assert.equal(result.restoreCalls, `STATE=${f.state} ARGS=--yes --relocated ${join(f.state, 'backups', NAME)}\n`);
    assert.deepEqual(readdirSync(join(f.state, 'data')).sort(), ['db', 'storage'], 'empty pre-restore directories removed');
    assert.deepEqual(readdirSync(f.parent), ['acme'], 'no staging directory left');
    assert.match(result.stdout, /Keep the original host off/);
    // The monitoring files of the old stack are not rendered any more; the checker's timer is installed by the operator.
    assert.equal(existsSync(join(f.state, 'config/monitoring')), false);
    assert.equal(existsSync(join(f.state, 'config/slack-webhook-url')), false, 'the webhook address is not in a backup');
    assert.match(result.stdout, /Install the monitoring checker[^]*sudo bash scripts\/watch-timer\.sh install --state /);
    assert.doesNotMatch(result.stdout, /profile monitoring|prometheus/i);
    assert.match(result.stdout, /alerts are local only until you run setup\.sh --operator[^\n]*--alert-webhook-file/i);
    assert.equal(readFileSync(join(f.state, 'config/backup.key'), 'utf8'), `${backupKey}\n`, 'the rebuilt installation keeps the backup key');
    assert.equal(statSync(join(f.state, 'config/backup.key')).mode & 0o777, 0o600);
  } finally { clean(f); }
});

// The images build-images.sh saved on the lost host (<state>/images), copied beside the backups on the drive.
const ID = { db: `sha256:${'a'.repeat(64)}`, functions: `sha256:${'b'.repeat(64)}`, storage: `sha256:${'c'.repeat(64)}` };
// build-images.sh signs the folder like a backup: SHA256SUMS lists every file in it, SHA256SUMS.hmac is made with the backup key.
function signImages(dir, key = backupKey) {
  const names = readdirSync(dir).filter(name => !name.startsWith('SHA256SUMS')).sort();
  writeFileSync(join(dir, 'SHA256SUMS'), names.map(name => `${sha(readFileSync(join(dir, name)))}  ${name}\n`).join(''));
  signBackup(dir, key);
}
function savedImages(dir, { sign = true, key = backupKey } = {}) {
  mkdirSync(dir, { recursive: true });
  for (const name of ['db.tar', 'functions.tar', 'storage.tar', 'Bad Name.tar', 'UPPER.tar', '.hidden.tar']) writeFileSync(join(dir, name), `tar ${name}\n`);
  writeFileSync(join(dir, 'notes.txt'), 'not an image\n');
  writeFileSync(join(dir, 'image-recipes.sha256'), Object.entries(ID).map(([service, id], i) => `${String(i + 1).repeat(64)}  ${service}  ${id}\n`).join(''));
  if (sign) signImages(dir, key);
  return dir;
}
const dockerCalls = f => readFileSync(join(f.scratch, 'docker.log'), 'utf8').split('\n').filter(Boolean);

test('restore-host loads the images saved beside the backup, adopts their build record and does not load anything else', () => {
  const f = fixture('warehouse-restore-host-images-');
  try {
    const images = savedImages(join(f.scratch, 'drive', 'images'));
    const loaded = `${ID.db} ${ID.storage}`;   // functions.tar fails to load below, so its image ID does not exist
    const result = f.run(['--state-dir', f.state, '--yes', f.backup], { FAKE_LOADED_IDS: loaded, FAKE_LOAD_FAIL: 'yes' });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(dockerCalls(f).filter(c => c.startsWith('load ')), [`load --input ${images}/db.tar`, `load --input ${images}/functions.tar`, `load --input ${images}/storage.tar`],
      'only the <service>.tar files that the build record names, in its order; the odd names and the record itself are not loaded');
    assert.match(result.stdout, /Loaded the saved image db\.tar\./); assert.match(result.stdout, /Loaded the saved image storage\.tar\./);
    assert.match(result.stderr, new RegExp(`Warning: could not load ${images}/functions\\.tar; that image is built as usual\\.`));
    // The record: the lines whose image exists on this host (db, storage), not the one that failed to load (functions).
    const record = readFileSync(join(f.state, 'config/image-recipes.sha256'), 'utf8');
    assert.equal(record, `${'1'.repeat(64)}  db  ${ID.db}\n${'3'.repeat(64)}  storage  ${ID.storage}\n`);
    assert.equal(statSync(join(f.state, 'config/image-recipes.sha256')).mode & 0o777, 0o600);
    // It all happens before restore.sh (which builds what is missing) runs.
    assert.ok(result.restoreCalls.includes('--relocated'));
    const out = result.stdout;
    assert.ok(out.indexOf('Loaded the saved image db.tar') > out.indexOf('Created '), 'after the state exists');
  } finally { clean(f); }
});

test('restore-host --images names the folder, and nothing is loaded when there is none, when it is empty or when no tarball loads', () => {
  const f = fixture('warehouse-restore-host-images-opt-');
  try {
    let result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(dockerCalls(f).filter(c => c.startsWith('load ')), [], 'no images folder next to the backup: no docker load');
    assert.equal(existsSync(join(f.state, 'config/image-recipes.sha256')), false);
    rmSync(f.state, { recursive: true, force: true });
    const elsewhere = savedImages(join(f.scratch, 'copied-from-usb'));
    result = f.run(['--state-dir', f.state, '--yes', '--images', elsewhere, f.backup], { FAKE_LOADED_IDS: ID.db });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(dockerCalls(f).includes(`load --input ${elsewhere}/db.tar`));
    assert.match(readFileSync(join(f.state, 'config/image-recipes.sha256'), 'utf8'), new RegExp(`  db  ${ID.db}\\n$`));
    rmSync(f.state, { recursive: true, force: true });
    // Tarballs that all fail to load: said so, no record is adopted, the restore goes on.
    result = f.run(['--state-dir', f.state, '--yes', '--images', elsewhere, f.backup], { FAKE_LOADED_IDS: 'sha256:none' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(existsSync(join(f.state, 'config/image-recipes.sha256')) && readFileSync(join(f.state, 'config/image-recipes.sha256'), 'utf8') !== '', false, 'no ID exists on the host: nothing adopted');
    rmSync(f.state, { recursive: true, force: true });
    // A record with no tarball beside it (they were not copied).
    const empty = join(f.scratch, 'empty-images'); mkdirSync(empty);
    writeFileSync(join(empty, 'image-recipes.sha256'), `${'1'.repeat(64)}  db  ${ID.db}\n`);
    signImages(empty);
    result = f.run(['--state-dir', f.state, '--yes', '--images', empty, f.backup]);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /No saved image could be loaded from .*empty-images; the images are built as usual\./);
    rmSync(f.state, { recursive: true, force: true });
    // A path that is not a folder is refused before anything is created.
    result = f.run(['--state-dir', f.state, '--yes', '--images', join(f.scratch, 'nonexistent'), f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /--images must be a copy of the lost host's <state>\/images folder/);
    assert.equal(existsSync(f.state), false);
    // A folder of tarballs without the build record is not a saved-images folder: refused when named, ignored when found.
    const stranger = join(f.scratch, 'drive', 'images'); mkdirSync(stranger, { recursive: true });
    writeFileSync(join(stranger, 'db.tar'), 'some other tarball\n');
    result = f.run(['--state-dir', f.state, '--yes', '--images', stranger, f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /--images must be a copy of the lost host's/);
    const seen = dockerCalls(f).length;
    result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(dockerCalls(f).slice(seen).filter(c => c.startsWith('load ')), [], 'the unrecognised folder next to the backup was not loaded');
    rmSync(f.state, { recursive: true, force: true });
    result = f.run(['--state-dir', f.state, '--yes', '--images']);
    assert.equal(result.status, 1); assert.match(result.stderr, /Usage: npm run db:restore-host -- .*\[--images DIR\]/);
  } finally { clean(f); }
});

const loads = f => dockerCalls(f).filter(c => c.startsWith('load '));
test('restore-host uses saved images only when they authenticate with the backup key: refused when named, ignored when found next to the backup', () => {
  const f = fixture('warehouse-restore-host-images-signature-');
  try {
    const drive = join(f.scratch, 'drive', 'images');
    const elsewhere = join(f.scratch, 'copied-from-usb');
    const reset = () => { rmSync(f.state, { recursive: true, force: true }); rmSync(drive, { recursive: true, force: true }); rmSync(elsewhere, { recursive: true, force: true }); };
    // A tarball changed after the folder was signed.
    savedImages(elsewhere); writeFileSync(join(elsewhere, 'db.tar'), 'a changed image\n');
    let result = f.run(['--state-dir', f.state, '--yes', '--images', elsewhere, f.backup], { FAKE_LOADED_IDS: ID.db });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Refusing: the backup does not match its SHA256SUMS\./);
    assert.match(result.stderr, /Refusing: the saved images in .*copied-from-usb do not authenticate with the backup key/);
    nothingCreated(f, result);
    assert.deepEqual(loads(f), [], 'nothing was loaded');
    // The same folder found next to the backup is ignored, with the reason; the restore goes on and builds the images.
    reset(); savedImages(drive); writeFileSync(join(drive, 'db.tar'), 'a changed image\n');
    result = f.run(['--state-dir', f.state, '--yes', f.backup], { FAKE_LOADED_IDS: ID.db });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stderr, /Note: the saved images next to the backup \(.*drive\/images\) do not authenticate with the backup key \(message above\), so they are not used\. The images are built as usual\./);
    assert.deepEqual(loads(f), []);
    assert.ok(result.restoreCalls.includes('--relocated'));
    assert.equal(existsSync(join(f.state, 'config/image-recipes.sha256')), false, 'no record adopted');
    // A folder that was never signed (copied from an installation before signing), a file added after signing, another key.
    reset(); savedImages(elsewhere, { sign: false });
    result = f.run(['--state-dir', f.state, '--yes', '--images', elsewhere, f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /Incomplete backup: missing SHA256SUMS/);
    assert.match(result.stderr, /do not authenticate with the backup key/); assert.deepEqual(readdirSync(f.parent), [], 'nothing created');
    reset(); savedImages(elsewhere); writeFileSync(join(elsewhere, 'extra.tar'), 'added later\n');
    result = f.run(['--state-dir', f.state, '--yes', '--images', elsewhere, f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /the files in the backup are not exactly the files its signed SHA256SUMS lists/);
    reset(); savedImages(elsewhere, { key: 'ab'.repeat(32) });
    result = f.run(['--state-dir', f.state, '--yes', '--images', elsewhere, f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /the signature of this backup does not match the backup key/);
    reset(); savedImages(elsewhere); rmSync(join(elsewhere, 'SHA256SUMS.hmac'));
    result = f.run(['--state-dir', f.state, '--yes', '--images', elsewhere, f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /Refusing: this backup carries no signature/);
    assert.deepEqual(loads(f), [], 'none of them loaded anything');
    // A genuine folder still loads.
    reset(); savedImages(elsewhere);
    result = f.run(['--state-dir', f.state, '--yes', '--images', elsewhere, f.backup], { FAKE_LOADED_IDS: ID.db });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(loads(f).includes(`load --input ${elsewhere}/db.tar`));
    // Changed on the drive after the first check, before the load (docker ps, step 4, appends to the tarball): not loaded, the restore goes on.
    reset(); savedImages(elsewhere);
    const seen = loads(f).length;
    result = f.run(['--state-dir', f.state, '--yes', '--images', elsewhere, f.backup], { FAKE_LOADED_IDS: ID.db, FAKE_TAMPER_FILE: join(elsewhere, 'db.tar') });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stderr, /Warning: the saved images in .*copied-from-usb no longer authenticate \(message above\); they are not loaded and the images are built as usual\./);
    assert.equal(loads(f).length, seen, 'nothing loaded');
    assert.ok(result.restoreCalls.includes('--relocated'));
  } finally { clean(f); }
});

test('restore-host --allow-unsigned never uses saved images: nothing proves them genuine', () => {
  const f = fixture('warehouse-restore-host-images-unsigned-');
  try {
    f.resum({ sign: false });
    const drive = savedImages(join(f.scratch, 'drive', 'images'));   // even a folder that is signed
    let result = f.run(['--state-dir', f.state, '--yes', '--allow-unsigned', f.backup], { FAKE_LOADED_IDS: ID.db }, { key: null });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stderr, /Note: --allow-unsigned was given, so the saved images in .*drive\/images are not used: nothing proves them genuine, and a loaded image runs with every secret of the rebuilt host\. The images are built as usual\./);
    assert.deepEqual(loads(f), []);
    assert.equal(existsSync(join(f.state, 'config/image-recipes.sha256')), false);
    rmSync(f.state, { recursive: true, force: true });
    // Also when the folder is named.
    result = f.run(['--state-dir', f.state, '--yes', '--allow-unsigned', '--images', drive, f.backup], { FAKE_LOADED_IDS: ID.db }, { key: null });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stderr, /are not used: nothing proves them genuine/);
    assert.deepEqual(loads(f), []);
    // No images folder at all: no note.
    rmSync(f.state, { recursive: true, force: true }); rmSync(drive, { recursive: true });
    result = f.run(['--state-dir', f.state, '--yes', '--allow-unsigned', f.backup], {}, { key: null });
    assert.doesNotMatch(result.stderr, /saved images/);
  } finally { clean(f); }
});

test('restore-host refuses a backup it cannot prove genuine: no key, a re-checksummed edit, another key', () => {
  const f = fixture('warehouse-restore-host-signature-');
  try {
    let result = f.run(['--state-dir', f.state, '--yes', f.backup], {}, { key: null });
    assert.equal(result.status, 1); assert.match(result.stderr, /needs the backup key of the lost installation/); nothingCreated(f, result);
    // Someone with the drive edits the configuration and regenerates the checksums; the signature cannot be regenerated.
    const signature = readFileSync(join(f.backup, 'SHA256SUMS.hmac'), 'utf8');
    writeFileSync(join(f.backup, 'compose.env'), readFileSync(join(f.backup, 'compose.env'), 'utf8') + 'JWT_SECRET=planted\n');
    f.resum({ sign: false });
    writeFileSync(join(f.backup, 'SHA256SUMS.hmac'), signature);
    assert.equal(spawnSync('sha256sum', ['-c', '--quiet', 'SHA256SUMS'], { cwd: f.backup }).status, 0, 'the plain checksums accept the edit');
    result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /signature of this backup does not match the backup key/); nothingCreated(f, result);
    result = f.run(['--state-dir', f.state, '--yes', '--allow-unsigned', f.backup]);
    assert.equal(result.status, 1, 'a wrong signature is never waved through'); nothingCreated(f, result);
    // The signature removed altogether.
    rmSync(join(f.backup, 'SHA256SUMS.hmac'));
    result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /carries no signature/); nothingCreated(f, result);
    // A genuine backup, but the operator brought the key of another installation.
    f.resum();
    const other = writeKey(join(f.scratch, 'other.key'), 'c3'.repeat(32));
    result = f.run(['--state-dir', f.state, '--yes', f.backup], {}, { key: other });
    assert.equal(result.status, 1); assert.match(result.stderr, /does not match the backup key/); nothingCreated(f, result);
    writeFileSync(join(f.scratch, 'not-a-key'), 'hello\n');
    result = f.run(['--state-dir', f.state, '--yes', f.backup], {}, { key: join(f.scratch, 'not-a-key') });
    assert.equal(result.status, 1); assert.match(result.stderr, /does not hold a backup key/); nothingCreated(f, result);
    // An extra file that the signed list does not name.
    writeFileSync(join(f.backup, 'extra.sql'), 'select 1;\n');
    result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /not exactly the files its signed SHA256SUMS lists/); nothingCreated(f, result);
  } finally { clean(f); }
});

test('restore-host refuses a v4 backup, with --backup-key or with --allow-unsigned and no key', () => {
  const f = fixture('warehouse-restore-host-v4-');
  try {
    f.resum({ format: 'warehouse-backup-v4', sign: false });
    let result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /backup format 'warehouse-backup-v4' is no longer supported; take a new backup with this version \(only warehouse-backup-v5 and -v6 are accepted\)\./); nothingCreated(f, result);
    result = f.run(['--state-dir', f.state, '--yes', '--allow-unsigned', f.backup], {}, { key: null });
    assert.equal(result.status, 1); assert.match(result.stderr, /backup format 'warehouse-backup-v4' is no longer supported; take a new backup with this version \(only warehouse-backup-v5 and -v6 are accepted\)\./); nothingCreated(f, result);
    assert.equal(existsSync(join(f.state, 'config/backup.key')), false);
  } finally { clean(f); }
});

test('restore-host refuses a v5 backup without a signature when --backup-key is given', () => {
  const g = fixture('warehouse-restore-host-v5-unsigned-');
  try {
    g.resum({ sign: false });
    const result = g.run(['--state-dir', g.state, '--yes', g.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /carries no signature/); nothingCreated(g, result);
  } finally { clean(g); }
});

// TW-BE-022: the same three cases as tests/restore.test.mjs, through restore-host (the key is the one given with --backup-key).
test('restore-host refuses a v5 backup whose signature file was removed, even with --allow-unsigned, while --backup-key is given', () => {
  const f = fixture('warehouse-restore-host-stripped-v5-');
  try {
    f.resum({ sign: false });
    assert.equal(existsSync(join(f.backup, 'SHA256SUMS.hmac')), false);
    let result = f.run(['--state-dir', f.state, '--yes', '--allow-unsigned', f.backup]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /a v5 or v6 backup must be signed; its signature file was removed/);
    assert.match(result.stderr, /--allow-unsigned is only for when the backup key is lost/);
    assert.doesNotMatch(result.stderr, /WARNING|WITHOUT proof/);
    nothingCreated(f, result);
    assert.equal(readFileSync(join(f.scratch, 'docker.log'), 'utf8'), '', 'docker is never invoked');
    // The refusal comes before the checksums.
    writeFileSync(join(f.backup, 'database.dump'), 'damaged after the signature was removed\n');
    result = f.run(['--state-dir', f.state, '--yes', '--allow-unsigned', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /a v5 or v6 backup must be signed/); assert.doesNotMatch(result.stderr, /does not match its SHA256SUMS/);
    nothingCreated(f, result);
  } finally { clean(f); }
});

test('restore-host takes the same v5 backup with --allow-unsigned and no --backup-key (key lost), with the warning', () => {
  const f = fixture('warehouse-restore-host-stripped-v5-lost-key-');
  try {
    f.resum({ sign: false });
    const result = f.run(['--state-dir', f.state, '--yes', '--allow-unsigned', f.backup], {}, { key: null });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stderr, /WARNING: this backup carries no signature[\s\S]*WITHOUT proof/);
    assert.doesNotMatch(result.stderr, /a v5 or v6 backup must be signed/);
    assert.match(result.stderr, /the backup key was missing/, 'the banner says why no signature was required');
    assert.equal(result.restoreCalls, `STATE=${f.state} ARGS=--yes --relocated --allow-unsigned ${join(f.state, 'backups', NAME)}\n`);
  } finally { clean(f); }
});

test('restore-host usage and key message say what --allow-unsigned is for', () => {
  const f = fixture('warehouse-restore-host-wording-');
  try {
    const usage = f.run(['--help'], {}, { key: null });
    assert.match(usage.stderr, /--allow-unsigned instead of --backup-key: only for when the backup key is lost/);
    f.resum({ sign: false });
    const result = f.run(['--state-dir', f.state, '--yes', f.backup], {}, { key: null });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /--allow-unsigned is only for when the backup key is lost/);
  } finally { clean(f); }
});

test('restore-host opens an encrypted archive with the backup key and refuses it when its signature is wrong or missing', () => {
  const f = fixture('warehouse-restore-host-enc-');
  try {
    const enc = f.encrypted();
    assert.doesNotMatch(readFileSync(enc, 'latin1'), /JWT_SECRET|kept-secret|database\.dump/, 'the archive on the drive is not readable');
    let result = f.run(['--state-dir', f.state, '--yes', '--allow-unsigned', enc], {}, { key: null });
    assert.equal(result.status, 1); assert.match(result.stderr, /cannot be opened without --backup-key/); nothingCreated(f, result);
    const signature = readFileSync(`${enc}.hmac`, 'utf8');
    writeFileSync(`${enc}.hmac`, `warehouse-backup-hmac-v1 ${'0'.repeat(64)}\n`);
    result = f.run(['--state-dir', f.state, '--yes', enc]);
    assert.equal(result.status, 1); assert.match(result.stderr, /signature of .*\.tar\.enc does not match the backup key/); nothingCreated(f, result);
    rmSync(`${enc}.hmac`);
    result = f.run(['--state-dir', f.state, '--yes', '--allow-unsigned', enc]);
    assert.equal(result.status, 1); assert.match(result.stderr, /has no signature file/); nothingCreated(f, result);
    // A plain archive copied by hand has no .hmac; the signed backup inside is what gets checked.
    writeFileSync(`${enc}.hmac`, signature);
    result = f.run(['--state-dir', f.state, '--yes', enc]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.equal(readFileSync(join(f.state, 'backups', NAME, 'compose.env'), 'utf8'), readFileSync(join(f.backup, 'compose.env'), 'utf8'));
    assert.match(readFileSync(join(f.state, 'config/compose.env'), 'utf8'), /^JWT_SECRET=kept-secret$/m);
    assert.deepEqual(readdirSync(f.parent), ['acme'], 'no decrypted archive is left behind');
  } finally { clean(f); }
});

// What a host that ran the printing and sensor profiles keeps after `compose down`.
const OTHER_VOLUMES = ['sensor-bridge-data', 'cups-spool'].map(name => `warehouse-backup-test_${name}`);

test('restore-host is not stopped by printing and sensor volumes, which hold no restored state', () => {
  const f = fixture('warehouse-restore-host-other-volumes-');
  try {
    const result = f.run(['--state-dir', f.state, '--yes', f.backup], { FAKE_VOLUMES: OTHER_VOLUMES.join(' ') });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, new RegExp(`Kept the Docker volumes ${OTHER_VOLUMES.join(', ')}`));
    assert.equal(result.restoreCalls, `STATE=${f.state} ARGS=--yes --relocated ${join(f.state, 'backups', NAME)}\n`);
  } finally { clean(f); }
});

test('the database and storage services mount no named volume, so no Docker volume carries state a restore replaces', { skip: !composeAvailable() && !process.env.CI ? 'docker compose is not installed' : false }, () => {
  // restore.sh replays the database (data/db) and the stored files (data/storage): both are host paths.
  const { services, volumes } = renderedCompose();
  const named = ['db', 'storage'].flatMap(service => (services[service].volumes ?? []).filter(mount => mount.type === 'volume').map(mount => mount.source));
  assert.deepEqual(named, []);
  assert.ok(!('db-config' in volumes), 'the db-config volume is gone');
  // The realistic left-overs used above are real volumes of this Compose project.
  for (const name of OTHER_VOLUMES) assert.ok(name.replace('warehouse-backup-test_', '') in volumes, name);
});

test('restore-host takes a USB archive after checking it, and accepts an existing empty state directory', () => {
  const f = fixture('warehouse-restore-host-tar-');
  try {
    const tar = f.tarball();
    writeFileSync(`${tar}.hmac`, `warehouse-backup-hmac-v1 ${'0'.repeat(64)}\n`);
    const forged = f.run(['--yes', '--state-dir', f.state, tar]);
    assert.equal(forged.status, 1); assert.match(forged.stderr, /signature of .*\.tar does not match the backup key/); nothingCreated(f, forged);
    // Without its .hmac file the archive cannot be checked before it is unpacked, so it is not unpacked.
    rmSync(`${tar}.hmac`);
    const unsigned = f.run(['--yes', '--state-dir', f.state, tar]);
    assert.equal(unsigned.status, 1); assert.match(unsigned.stderr, /has no signature file \(.*\.tar\.hmac\)[\s\S]*--allow-unsigned/); nothingCreated(f, unsigned);
    // An archive packed by hand is taken with --allow-unsigned; the signed backup inside it is still checked.
    mkdirSync(f.state, { mode: 0o700 });
    const result = f.run(['--yes', '--allow-unsigned', '--state-dir', f.state, tar]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.equal(readFileSync(join(f.state, 'public/instance.json'), 'utf8'), instanceJson);
    assert.ok(existsSync(join(f.state, 'backups', NAME, 'database.dump')));
    assert.deepEqual(readdirSync(f.parent), ['acme'], 'the unpacked archive was moved, not left behind');
  } finally { clean(f); }
});

test('restore-host binds the checksum record to the selected archive', () => {
  const f = fixture('warehouse-restore-host-bind-');
  try {
    const drive = join(f.scratch, 'drive');
    const other = `${NAME.replace('000000Z', '000001Z')}`;
    const tar = f.tarball();
    // A second, different archive B next to A.
    const b = join(drive, `${other}.tar`);
    writeFileSync(b, Buffer.concat([readFileSync(tar), Buffer.alloc(1024)]));
    writeFileSync(`${b}.sha256`, spawnSync('sha256sum', [`${other}.tar`], { cwd: drive, encoding: 'utf8' }).stdout);
    // B's own record is bound to B, so the copy of A's record is the only thing wrong below.
    const run = (file) => f.run(['--yes', '--state-dir', f.state, file]);
    copyFileSync(`${tar}.sha256`, `${b}.sha256`); copyFileSync(`${tar}.hmac`, `${b}.hmac`);
    let result = run(b);
    assert.equal(result.status, 1); assert.match(result.stderr, /names a different archive/); nothingCreated(f, result);
    // Two records.
    const own = spawnSync('sha256sum', [`${other}.tar`], { cwd: drive, encoding: 'utf8' }).stdout;
    writeFileSync(`${b}.sha256`, own + readFileSync(`${tar}.sha256`, 'utf8')); f.signArchive(b);
    result = run(b);
    assert.equal(result.status, 1); assert.match(result.stderr, /must hold one record/); nothingCreated(f, result);
    // The right name with a wrong hash.
    writeFileSync(`${b}.sha256`, `${'a'.repeat(64)}  ${other}.tar\n`); f.signArchive(b);
    result = run(b);
    assert.equal(result.status, 1); assert.match(result.stderr, /does not match/); nothingCreated(f, result);
    // The record is correct and signed: B is taken from its own files.
    writeFileSync(`${b}.sha256`, own); f.signArchive(b);
    // Same record, wrong signature: the signature stage runs and refuses.
    writeFileSync(`${b}.hmac`, `warehouse-backup-hmac-v1 ${'0'.repeat(64)}\n`);
    result = run(b);
    assert.equal(result.status, 1); assert.match(result.stderr, /signature of .* does not match the backup key/); nothingCreated(f, result);
    // A companion written with CRLF line endings is refused with a message that names CRLF.
    writeFileSync(`${b}.sha256`, own.replace(/\n$/, '\r\n')); f.signArchive(b);
    result = run(b);
    assert.equal(result.status, 1); assert.match(result.stderr, /CRLF line endings/); nothingCreated(f, result);
    // Correct and signed: the checksum and the signature both pass, so B is stopped only later, on its tar entries.
    writeFileSync(`${b}.sha256`, own); f.signArchive(b);
    result = run(b);
    assert.doesNotMatch(result.stderr, /different archive|one record|does not match \S+\.sha256|signature of|CRLF/);
    assert.match(result.stderr, /unexpected entries/);
  } finally { clean(f); }
});

test('restore-host refuses an encrypted archive with the record of another archive', () => {
  const f = fixture('warehouse-restore-host-bind-enc-');
  try {
    const drive = join(f.scratch, 'drive');
    const enc = f.encrypted();
    const other = NAME.replace('000000Z', '000001Z');
    const b = join(drive, `${other}.tar.enc`);
    writeFileSync(b, Buffer.concat([readFileSync(enc), Buffer.alloc(16)]));
    copyFileSync(`${enc}.sha256`, `${b}.sha256`); copyFileSync(`${enc}.hmac`, `${b}.hmac`);
    const result = f.run(['--yes', '--state-dir', f.state, b]);
    assert.equal(result.status, 1); assert.match(result.stderr, /names a different archive/); nothingCreated(f, result);
    // The untouched original still restores.
    mkdirSync(f.state, { mode: 0o700 });
    const ok = f.run(['--yes', '--state-dir', f.state, enc]);
    assert.equal(ok.status, 0, ok.stderr + ok.stdout);
  } finally { clean(f); }
});

test('restore-host refuses without --yes, as root-like misuse, for a non-empty or badly placed state, before creating anything', () => {
  const f = fixture('warehouse-restore-host-refuse-');
  try {
    let result = f.run(['--state-dir', f.state, f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /permanently off, then pass --yes/); nothingCreated(f, result);
    result = f.run(['--state-dir', 'relative/acme', '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /absolute path/); nothingCreated(f, result);
    result = f.run(['--state-dir', join(f.root, 'state'), '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /outside this checkout/);
    result = f.run(['--state-dir', join(f.scratch, 'missing-parent', 'acme'), '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /must exist and belong to you/);
    symlinkSync(f.parent, join(f.scratch, 'link'));
    result = f.run(['--state-dir', join(f.scratch, 'link', 'acme'), '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /without symlinks/); nothingCreated(f, result);
    mkdirSync(f.state); writeFileSync(join(f.state, 'something'), 'x');
    result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /already exists and is not empty.*db:restore/);
    assert.deepEqual(readdirSync(f.state), ['something'], 'an existing installation is never touched');
  } finally { clean(f); }
});

test('restore-host refuses a newer or different migration history, a damaged backup and a host that already has the project', () => {
  for (const [label, options, extra, pattern] of [
    ['newer', { integrity: 'migration_count=3\nmigration_fingerprint=' + 'a'.repeat(64) + '\n' }, {},/backup has 3 migrations and this checkout only 2.*source_commit=abc1234/],
    ['different', { integrity: 'migration_count=2\nmigration_fingerprint=' + '0'.repeat(64) + '\n' }, {}, /migrations this backup applied differ/],
    ['project', {}, { FAKE_PROJECT_EXISTS: 'yes' }, /containers of warehouse-backup-test already exist/],
  ]) {
    const f = fixture(`warehouse-restore-host-${label}-`, options);
    try {
      const result = f.run(['--state-dir', f.state, '--yes', f.backup], extra);
      assert.equal(result.status, 1, label);
      assert.match(result.stderr, pattern, label);
      nothingCreated(f, result);
    } finally { clean(f); }
  }
  const f = fixture('warehouse-restore-host-damaged-');
  try {
    writeFileSync(join(f.backup, 'database.dump'), 'tampered\n');
    let result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /does not match its SHA256SUMS/); nothingCreated(f, result);
    const tar = f.tarball();
    writeFileSync(`${tar}.sha256`, `${'0'.repeat(64)}  ${NAME}.tar\n`);
    result = f.run(['--state-dir', f.state, '--yes', tar]);
    assert.equal(result.status, 1); assert.match(result.stderr, /does not match .*\.tar\.sha256/); nothingCreated(f, result);
    rmSync(`${tar}.sha256`);
    result = f.run(['--state-dir', f.state, '--yes', tar]);
    assert.equal(result.status, 1); assert.match(result.stderr, /Missing checksum file/); nothingCreated(f, result);
  } finally { clean(f); }
});

test('restore-host refuses an archive with a link or a path outside the backup folder', () => {
  const f = fixture('warehouse-restore-host-links-');
  try {
    symlinkSync('/etc/passwd', join(f.backup, 'evil'));
    const tar = f.tarball();
    const result = f.run(['--state-dir', f.state, '--yes', tar]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /unexpected entries/);
    nothingCreated(f, result);
  } finally { clean(f); }
});

test('restore-host from a backup taken before per-role passwords adds them to the new state before the replay, and restore.sh --relocated accepts that', () => {
  const f = fixture('warehouse-restore-host-previous-', { env: composeEnv('/srv/warehouse/lost-host', 'JWT_SECRET=kept-secret\n', previousReleaseDbLines) });
  try {
    const result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    const fromBackup = readFileSync(join(f.backup, 'compose.env'), 'utf8').replaceAll(f.original, f.state);
    const env = readFileSync(join(f.state, 'config/compose.env'), 'utf8');
    assert.ok(env.startsWith(fromBackup), 'the backup configuration, with only the three paths rewritten');
    assert.deepEqual(env.slice(fromBackup.length).trimEnd().split('\n').map(line => line.split('=')[0]),
      ['DB_PASSWORD_AUTHENTICATOR', 'DB_PASSWORD_STORAGE']);
    assert.equal(statSync(join(f.state, 'config/compose.env')).mode & 0o777, 0o600);
    assert.match(result.stdout, /Added DB_PASSWORD_AUTHENTICATOR, DB_PASSWORD_STORAGE: the backup was taken before/);
    assert.equal(result.restoreCalls, `STATE=${f.state} ARGS=--yes --relocated ${join(f.state, 'backups', NAME)}\n`);
    assert.equal(readFileSync(join(f.state, 'backups', NAME, 'compose.env'), 'utf8'), readFileSync(join(f.backup, 'compose.env'), 'utf8'), 'the kept backup is unmodified');
  } finally { clean(f); }
  // The real restore.sh --relocated: the added lines are the only other difference it lets through.
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-restore-relocated-previous-'));
  try {
    const state = makeState(scratch);
    const log = join(scratch, 'docker.log'); writeFileSync(log, '');
    const root = scriptRoot(scratch);
    const backup = makeBackup(join(scratch, 'moved'), { env: composeEnv('/srv/warehouse/elsewhere', undefined, previousReleaseDbLines) });
    const result = spawnSync('bash', [join(root, 'scripts/restore.sh'), '--yes', '--relocated', backup], { encoding: 'utf8',
      env: { ...process.env, PATH: `${fakeDocker(join(scratch, 'bin'))}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state,
        FAKE_DOCKER_LOG: log, FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt') } });
    assert.match(result.stderr + result.stdout, /Restoring .* into /, 'past the configuration check');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore-host reports how to start over when the replay fails, leaving only the new state', () => {
  const f = fixture('warehouse-restore-host-fail-');
  try {
    const result = f.run(['--state-dir', f.state, '--yes', f.backup], { FAKE_RESTORE_FAIL: 'yes' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`failed after creating ${f.state}[\\s\\S]*sudo rm -rf ${f.state}`));
    assert.deepEqual(readdirSync(f.parent), ['acme']);
  } finally { clean(f); }
});

test('restore.sh --relocated accepts only a difference in the three state paths', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-restore-relocated-'));
  try {
    const state = makeState(scratch);
    const log = join(scratch, 'docker.log'); writeFileSync(log, '');
    const root = scriptRoot(scratch);
    const run = (backup, args) => spawnSync('bash', [join(root, 'scripts/restore.sh'), ...args, backup], { encoding: 'utf8',
      env: { ...process.env, PATH: `${fakeDocker(join(scratch, 'bin'))}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state,
        FAKE_DOCKER_LOG: log, FAKE_CATALOG_FILE: join(scratch, 'moved', 'storage_objects.txt') } });
    const moved = makeBackup(join(scratch, 'moved'), { env: composeEnv('/srv/warehouse/elsewhere') });
    let result = run(moved, ['--yes']);
    assert.equal(result.status, 1); assert.match(result.stderr, /compose\.env differs from the backup copy/);
    result = run(moved, ['--yes', '--relocated']);
    assert.match(result.stderr + result.stdout, /Restoring .* into /, 'past the configuration check');
    const changed = makeBackup(join(scratch, 'changed'), { env: composeEnv('/srv/warehouse/elsewhere', 'JWT_SECRET=other\n') });
    result = run(changed, ['--yes', '--relocated']);
    assert.equal(result.status, 1); assert.match(result.stderr, /in more than the state paths/);
    result = run(moved, ['--yes', '--relocated', '--restore-config']);
    assert.equal(result.status, 1); assert.match(result.stderr, /Usage/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore-host brings back a tunnel credential carried by the backup, pointed at the new state', () => {
  const f = fixture('warehouse-restore-host-tunnel-');
  try {
    mkdirSync(join(f.backup, 'tunnel'), { mode: 0o700 });
    writeFileSync(join(f.backup, 'tunnel/config.yml'), `tunnel: 0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d\ncredentials-file: ${f.original}/config/tunnel/credentials.json\ningress:\n  - service: http_status:404\n`, { mode: 0o600 });
    writeFileSync(join(f.backup, 'tunnel/credentials.json'), '{"TunnelSecret":"kept"}', { mode: 0o600 });
    f.resum({ files: 'tunnel/*' });
    const result = f.run(['--state-dir', f.state, '--yes', f.tarball()]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    const dest = join(f.state, 'config/tunnel');
    assert.equal(statSync(dest).mode & 0o777, 0o700);
    assert.equal(readFileSync(join(dest, 'credentials.json'), 'utf8'), '{"TunnelSecret":"kept"}');
    assert.equal(statSync(join(dest, 'credentials.json')).mode & 0o777, 0o600);
    const config = readFileSync(join(dest, 'config.yml'), 'utf8');
    assert.match(config, new RegExp(`^credentials-file: ${dest}/credentials\\.json$`, 'm'));
    assert.match(config, /^tunnel: 0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d$/m);
    assert.match(result.stdout, new RegExp(`sudo bash scripts/tunnel\\.sh install-service --state ${f.state}`));
  } finally { clean(f); }
});

test('restore-host without a tunnel in the backup points to the manual connector setup', () => {
  const f = fixture('warehouse-restore-host-notunnel-');
  try {
    const result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(existsSync(join(f.state, 'config/tunnel')), false);
    assert.match(result.stdout, /carries no tunnel credential/);
  } finally { clean(f); }
});

// TW-BE-020. The key file of central sign-in (public keys only) is not in compose.env, which a backup
// keeps; without it every central exchange fails while get-public-config still offers central sign-in.
const ISSUER = 'https://login.association.example.test';
const centralEnv = (file = 'central-jwks.json') =>
  composeEnv('/srv/warehouse/lost-host', `JWT_SECRET=kept-secret\nCENTRAL_ISSUER=${ISSUER}\nCENTRAL_JWKS_URL=\nCENTRAL_JWKS_FILE=${file}\n`);

// The alert webhook step (B9) always names setup.sh; the central key file tests are about a rerun for the key file.
const withoutAlertStep = out => out.replace(/ *\d+\. Alerts are local only[^]*?watch-timer\.sh install --state [^\n]*\n/, '');

test('restore-host puts the central key file back byte for byte with mode 0644, and leaves central sign-in nothing to redo', () => {
  const f = fixture('warehouse-restore-host-central-key-', { env: centralEnv() });
  try {
    writeFileSync(join(f.backup, 'central-jwks.json'), centralKeySet, { mode: 0o600 });
    f.resum({ files: 'central-jwks.json' });
    const result = f.run(['--state-dir', f.state, '--yes', f.tarball()]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    const path = join(f.state, 'public/central-jwks.json');
    assert.equal(readFileSync(path, 'utf8'), centralKeySet);
    assert.equal(statSync(path).mode & 0o777, 0o644, 'readable by the functions container, like the copy setup makes');
    assert.deepEqual(readdirSync(join(f.state, 'public')).sort(), ['central-jwks.json', 'instance.json']);
    assert.equal(readFileSync(join(f.state, 'config/compose.env'), 'utf8').match(/^CENTRAL_JWKS_FILE=(.*)$/m)[1], 'central-jwks.json');
    assert.match(result.stdout, /Restored the central sign-in key file public\/central-jwks\.json/);
    assert.doesNotMatch(withoutAlertStep(result.stdout), /setup\.sh/, 'nothing to rerun');
    assert.doesNotMatch(result.stdout, /one rerun and not two/, 'no key file step, so nothing to combine with');
    assert.equal(result.keyPending, '', 'doctor --local is not told to expect a missing key file');
  } finally { clean(f); }
});

test('restore-host refuses a backup whose central key file was changed, with or without new checksums', () => {
  const f = fixture('warehouse-restore-host-central-key-edit-', { env: centralEnv() });
  try {
    writeFileSync(join(f.backup, 'central-jwks.json'), centralKeySet, { mode: 0o600 });
    f.resum({ files: 'central-jwks.json' });
    // A key set of the attacker's choosing, checksums left as they were.
    writeFileSync(join(f.backup, 'central-jwks.json'), centralKeySet.replace('central-2026-10', 'planted-key'));
    let result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /does not match its SHA256SUMS/); nothingCreated(f, result);
    // Checksums regenerated, signature not (the signing key is not on the drive).
    const signature = readFileSync(join(f.backup, 'SHA256SUMS.hmac'), 'utf8');
    f.resum({ files: 'central-jwks.json', sign: false });
    writeFileSync(join(f.backup, 'SHA256SUMS.hmac'), signature);
    result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /signature of this backup does not match the backup key/); nothingCreated(f, result);
    assert.equal(existsSync(join(f.state, 'public')), false);
  } finally { clean(f); }
});

test('restore-host prints the exact setup rerun when central sign-in names a key file the older backup does not carry', () => {
  const f = fixture('warehouse-restore-host-central-key-older-', { env: centralEnv() });
  try {
    const result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.equal(existsSync(join(f.state, 'public/central-jwks.json')), false, 'no key file is invented');
    assert.equal(result.keyPending, 'yes', 'restore.sh runs doctor --local with the missing file reported as a warning, not a failure');
    assert.match(result.stdout, /carries no central sign-in key file/);
    assert.ok(result.stdout.includes(`bash setup.sh --operator --state-dir ${f.state} --admin-phone 91XXXXXXXXXX --admin-name 'ADMIN NAME' \\\n`), 'setup rerun with the state');
    assert.ok(result.stdout.includes(`--central-issuer ${ISSUER} --central-jwks-file /absolute/path/to/association-jwks.json`), 'with the issuer the backup names');
    assert.doesNotMatch(result.stdout, /Restored the central sign-in key file/);
    assert.match(result.stdout, /add --alert-webhook-file \/absolute\/path\/to\/webhook-url-file\s+to that same command, so it is one rerun and not two/);
    // The numbered steps stay in order whether or not this step is there.
    assert.deepEqual([...result.stdout.matchAll(/^ {2}(\d+)\. /gm)].map(m => Number(m[1])), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
  } finally { clean(f); }
});

// The letterhead image of the document PDFs (setup.sh --letterhead-file) is in the backup next to the key file.
const letterheadEnv = (name = 'letterhead.png') => composeEnv('/srv/warehouse/lost-host', `JWT_SECRET=kept-secret\nLETTERHEAD_FILE=${name}\n`);

test('restore-host puts the letterhead image back byte for byte with mode 0644 and nothing is left to redo', () => {
  for (const [name, bytes] of [['letterhead.png', pngLetterhead], ['letterhead.jpg', jpegLetterhead]]) {
    const f = fixture('warehouse-restore-host-letterhead-', { env: letterheadEnv(name) });
    try {
      writeFileSync(join(f.backup, name), bytes, { mode: 0o600 });
      f.resum({ files: name });
      const result = f.run(['--state-dir', f.state, '--yes', f.tarball()]);
      assert.equal(result.status, 0, name + result.stderr + result.stdout);
      const path = join(f.state, 'public', name);
      assert.deepEqual(readFileSync(path), bytes);
      assert.equal(statSync(path).mode & 0o777, 0o644, 'readable by the functions container, like the copy setup makes');
      assert.deepEqual(readdirSync(join(f.state, 'public')).sort(), ['instance.json', name]);
      assert.equal(readFileSync(join(f.state, 'config/compose.env'), 'utf8').match(/^LETTERHEAD_FILE=(.*)$/m)[1], name);
      assert.ok(result.stdout.includes(`Restored the letterhead image public/${name} from the backup.`));
      assert.doesNotMatch(withoutAlertStep(result.stdout), /setup\.sh|letterhead image back/, 'nothing to rerun');
      assert.equal(result.keyPending, '');
    } finally { clean(f); }
  }
});

test('restore-host refuses a backup whose letterhead image was changed after it was signed', () => {
  const f = fixture('warehouse-restore-host-letterhead-edit-', { env: letterheadEnv() });
  try {
    writeFileSync(join(f.backup, 'letterhead.png'), pngLetterhead, { mode: 0o600 });
    f.resum({ files: 'letterhead.png' });
    writeFileSync(join(f.backup, 'letterhead.png'), Buffer.concat([pngLetterhead, Buffer.from('planted')]));
    const result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /does not match its SHA256SUMS/); nothingCreated(f, result);
  } finally { clean(f); }
});

test('restore-host from an older backup (no letterhead) works: plain PDFs, and a rerun is named only when the configuration names an image', () => {
  const none = fixture('warehouse-restore-host-lh-none-');
  try {
    const result = none.run(['--state-dir', none.state, '--yes', none.backup]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.deepEqual(readdirSync(join(none.state, 'public')), ['instance.json']);
    assert.doesNotMatch(result.stdout, /letterhead/i);
  } finally { clean(none); }
  const named = fixture('warehouse-restore-host-letterhead-named-', { env: letterheadEnv() });
  try {
    const result = named.run(['--state-dir', named.state, '--yes', named.backup]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.equal(existsSync(join(named.state, 'public/letterhead.png')), false, 'no image is invented');
    assert.equal(result.keyPending, '', 'a missing letterhead is not a key-file allowance');
    assert.match(result.stdout, /Put the letterhead image back \(optional\)\. This backup carries no letterhead image although its configuration\s+names one/);
    assert.ok(result.stdout.includes(`bash setup.sh --operator --state-dir ${named.state} --admin-phone 91XXXXXXXXXX --admin-name 'ADMIN NAME' \\\n`));
    assert.ok(result.stdout.includes('--letterhead-file /absolute/path/to/letterhead.png'));
    const numbers = [...result.stdout.matchAll(/^ {2}(\d+)\. /gm)].map(m => Number(m[1]));
    assert.deepEqual(numbers, numbers.map((_, i) => i + 1), 'the numbered steps stay in order');
  } finally { clean(named); }
});

test('restore-host says nothing about a key file when central sign-in uses an address or is off', () => {
  for (const [label, extra] of [['address', 'CENTRAL_ISSUER=https://login.association.example.test\nCENTRAL_JWKS_URL=https://login.association.example.test/jwks.json\nCENTRAL_JWKS_FILE=\n'],
    ['off', 'CENTRAL_ISSUER=\nCENTRAL_JWKS_URL=\nCENTRAL_JWKS_FILE=\n'], ['never set', '']]) {
    const f = fixture(`warehouse-restore-host-nokey-`, { env: composeEnv('/srv/warehouse/lost-host', `JWT_SECRET=kept-secret\n${extra}`) });
    try {
      const result = f.run(['--state-dir', f.state, '--yes', f.backup]);
      assert.equal(result.status, 0, label + result.stderr + result.stdout);
      assert.doesNotMatch(withoutAlertStep(result.stdout), /central|setup\.sh/i, label);
      assert.equal(result.keyPending, '', label);
      assert.equal(existsSync(join(f.state, 'public/central-jwks.json')), false, label);
      assert.deepEqual([...result.stdout.matchAll(/^ {2}(\d+)\. /gm)].map(m => Number(m[1])), [1, 2, 3, 4, 5, 6, 7, 8], label);
    } finally { clean(f); }
  }
});

test('restore-host refuses a backup made on the supabase/postgres image, or with no image line, naming the tag and the reload, before creating anything', () => {
  const oldImage = 'supabase/postgres:15.8.1.135@sha256:ee680a0afebe1a5e95614fdea671c01a264e58f52de6c429c17a394f46dec2c6';
  for (const [label, databaseImage, reason] of [
    ['the earlier image', oldImage, /made on the database image 'supabase\/postgres:15\.8\.1\.135@sha256:[0-9a-f]{64}'/],
    ['no image line', null, /records no database_image= line/],
  ]) {
    const f = fixture('warehouse-restore-host-image-');
    try {
      f.resum({ databaseImage });
      let result = f.run(['--state-dir', f.state, '--yes', f.backup]);
      assert.equal(result.status, 1, label); assert.match(result.stderr, reason, label);
      assert.match(result.stderr, /migrations-pre-baseline.*Baseline reload/s, label); nothingCreated(f, result);
      result = f.run(['--state-dir', f.state, '--yes', '--allow-unsigned', f.backup], {}, { key: null });
      assert.equal(result.status, 1, label); assert.match(result.stderr, /migrations-pre-baseline/, label); nothingCreated(f, result);
    } finally { clean(f); }
  }
});

// ---- format v6: the object storage as a tree --------------------------------------------------------------------------

const OBJECT = 'stub/stub/documents/a.pdf/v1';

test('restore-host rebuilds from a v6 backup directory and keeps its tree under backups/ for restore.sh to copy', () => {
  const f = fixture('warehouse-restore-host-v6-dir-', { format: 'warehouse-backup-v6' });
  try {
    const result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.equal(readFileSync(join(f.state, 'backups', NAME, 'storage', OBJECT), 'utf8'), `bytes of ${OBJECT}`);
    assert.ok(existsSync(join(f.state, 'backups', NAME, 'storage.manifest')));
    assert.equal(result.restoreCalls, `STATE=${f.state} ARGS=--yes --relocated ${join(f.state, 'backups', NAME)}\n`);
    assert.equal(readFileSync(join(f.state, 'config/backup.key'), 'utf8'), `${backupKey}\n`);
  } finally { clean(f); }
});

test('restore-host refuses a v6 backup whose tree was changed, and one whose label and signed list disagree, before creating anything', () => {
  const f = fixture('warehouse-restore-host-v6-refuse-', { format: 'warehouse-backup-v6' });
  try {
    writeFileSync(join(f.backup, 'storage', OBJECT), 'planted bytes');
    let result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /a file of the backup storage\/ tree does not match storage\.manifest/); nothingCreated(f, result);
    writeFileSync(join(f.backup, 'storage', OBJECT), `bytes of ${OBJECT}`);
    // Labelled v5 but listed as v6, signed by the key holder: refused after authentication.
    writeFileSync(join(f.backup, 'metadata.txt'), readFileSync(join(f.backup, 'metadata.txt'), 'utf8').replace('warehouse-backup-v6', 'warehouse-backup-v5'));
    writeFileSync(join(f.backup, 'storage.tar.gz'), 'not a tarball');
    spawnSync('sh', ['-c', 'sha256sum database.dump storage.tar.gz storage.manifest storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: f.backup });
    signBackup(f.backup);
    result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /labelled warehouse-backup-v5, but its signed file list does not describe that layout|not exactly the files/); nothingCreated(f, result);
  } finally { clean(f); }
});

test('restore-host unpacks a v6 archive, plain or encrypted, with the stored files\' attributes', { skip: xattrSkip() }, () => {
  const xattrs = { [OBJECT]: { 'user.supabase.content-type': 'application/pdf', 'user.supabase.cache-control': 'max-age=3600' } };
  for (const kind of ['tar', 'enc']) {
    const f = fixture(`warehouse-restore-host-v6-${kind}-`, { format: 'warehouse-backup-v6', xattrs });
    try {
      assert.equal(xattrTool().get(join(f.backup, 'storage', OBJECT), 'user.supabase.content-type'), 'application/pdf', 'the fixture carries the attribute');
      const modeOf = path => statSync(path).mode & 0o777;
      const fileMode = modeOf(join(f.backup, 'storage', OBJECT)), folderMode = modeOf(dirname(join(f.backup, 'storage', OBJECT)));
      assert.ok(fileMode !== 0o600 && folderMode !== 0o700, 'the fixture has modes that an unpacking under umask 077 would not give');
      const archive = kind === 'tar' ? f.tarball({ xattrs: true }) : f.encrypted({ xattrs: true });
      const result = f.run(['--state-dir', f.state, '--yes', archive]);
      assert.equal(result.status, 0, result.stderr + result.stdout);
      const unpacked = join(f.state, 'backups', NAME, 'storage', OBJECT);
      assert.equal(readFileSync(unpacked, 'utf8'), `bytes of ${OBJECT}`);
      assert.equal(xattrTool().get(unpacked, 'user.supabase.content-type'), 'application/pdf', `${kind}: the content type came through the archive`);
      assert.equal(xattrTool().get(unpacked, 'user.supabase.cache-control'), 'max-age=3600');
      // The script runs under umask 077; the stored file and its folders keep the modes they had in the backup (restore.sh
      // copies them on), not 0600 and 0700.
      assert.equal(modeOf(unpacked), fileMode, `${kind}: the mode of the stored file`);
      assert.equal(modeOf(dirname(unpacked)), folderMode, `${kind}: and of its folder`);
      assert.deepEqual(readdirSync(f.parent), ['acme'], 'no scratch directory is left');
    } finally { clean(f); }
  }
});

test('restore-host checks the room for an archive before it writes anything: twice the archive plus 1 GiB', () => {
  const f = fixture('warehouse-restore-host-space-', { format: 'warehouse-backup-v6' });
  try {
    const archive = f.tarball();
    const shim = join(f.scratch, 'shim'); mkdirSync(shim);
    writeFileSync(join(shim, 'df'), '#!/bin/sh\nprintf "Avail\\n%s\\n" "${FAKE_AVAIL:-4096}"\n', { mode: 0o755 });
    const env = { PATH: `${shim}:${f.wrap}:${process.env.PATH}` };
    const result = f.run(['--state-dir', f.state, '--yes', archive], env);
    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`Refusing: unpacking ${NAME}\\.tar and restoring from it needs about \\d+ MiB in ${f.parent} \\(twice the archive plus 1 GiB\\), but only 0 MiB are free\\. .*Nothing was created\\.`));
    nothingCreated(f, result);
    // With room, the same archive is taken.
    const enough = f.run(['--state-dir', f.state, '--yes', archive], { ...env, FAKE_AVAIL: String(50 * 1024 ** 3) });
    assert.equal(enough.status, 0, enough.stderr + enough.stdout);
  } finally { clean(f); }
});

test('restore-host checks the room for a backup folder before it copies it: twice its size plus 1 GiB', () => {
  const f = fixture('warehouse-restore-host-dirspace-', { format: 'warehouse-backup-v6' });
  try {
    const shim = join(f.scratch, 'shim'); mkdirSync(shim);
    writeFileSync(join(shim, 'df'), '#!/bin/sh\nprintf "Avail\\n%s\\n" "${FAKE_AVAIL:-4096}"\n', { mode: 0o755 });
    const env = { PATH: `${shim}:${f.wrap}:${process.env.PATH}` };
    const result = f.run(['--state-dir', f.state, '--yes', f.backup], env);
    assert.equal(result.status, 1);
    assert.match(result.stderr, new RegExp(`Refusing: copying ${NAME} into the new state and restoring from it needs about \\d+ MiB in ${f.parent} \\(twice the backup plus 1 GiB\\), but only 0 MiB are free\\. .*Nothing was created\\.`));
    nothingCreated(f, result);
    const enough = f.run(['--state-dir', f.state, '--yes', f.backup], { ...env, FAKE_AVAIL: String(50 * 1024 ** 3) });
    assert.equal(enough.status, 0, enough.stderr + enough.stdout);
  } finally { clean(f); }
});
