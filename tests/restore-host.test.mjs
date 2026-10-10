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
import { join } from 'node:path';
import { makeBackup, makeState, fakeDocker, scriptRoot, composeEnv, instanceJson, repo, backupKey, signBackup, writeKey, hmacHex } from './backup-test-helpers.mjs';
import { composeAvailable, renderedCompose } from './compose-render.mjs';

const NAME = 'warehouse-20260101T000000Z';
const sha = text => createHash('sha256').update(text).digest('hex');
const migrations = { '0001_first.sql': 'select 1;\n', '0002_second.sql': 'select 2;\n' };
const ledger = (names = Object.keys(migrations)) =>
  `migration_count=${names.length}\nmigration_fingerprint=${sha(names.map(n => `${n}:${sha(migrations[n])}`).join('\n'))}\n`;

function fixture(prefix, { integrity = ledger(), env } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), prefix));
  const root = scriptRoot(scratch);
  mkdirSync(join(root, 'migrations'));
  for (const [name, body] of Object.entries(migrations)) writeFileSync(join(root, 'migrations', name), body);
  writeFileSync(join(root, 'scripts/doctor.mjs'), "console.log('Host prerequisites and state filesystem preflight passed.');\n");
  // A stand-in for restore.sh that records its call and sets data aside as the real one does.
  writeFileSync(join(root, 'scripts/restore.sh'), `#!/usr/bin/env bash
printf '%s\\n' "STATE=$WAREHOUSE_STATE_DIR ARGS=$*" >> "$RESTORE_LOG"
[[ "\${FAKE_RESTORE_FAIL:-}" != yes ]] || exit 3
mv "$WAREHOUSE_STATE_DIR/data/db" "$WAREHOUSE_STATE_DIR/data/db.pre-restore-20260101T000000Z"
mv "$WAREHOUSE_STATE_DIR/data/storage" "$WAREHOUSE_STATE_DIR/data/storage.pre-restore-20260101T000000Z"
mkdir -m 700 "$WAREHOUSE_STATE_DIR/data/db" "$WAREHOUSE_STATE_DIR/data/storage"
`);
  const original = '/srv/warehouse/lost-host';
  const backup = makeBackup(join(scratch, 'drive', NAME), {
    env: env ?? composeEnv(original, 'JWT_SECRET=kept-secret\nMSG91_AUTH_KEY=kept-key\n'), integrity });
  // Rewrites SHA256SUMS as the backup tool would; only `sign` adds a valid signature.
  const resum = ({ format = 'warehouse-backup-v5', sign = true, files = '' } = {}) => {
    writeFileSync(join(backup, 'metadata.txt'), `format=${format}\ncreated_at_utc=20260101T000000Z\nsource_commit=abc1234\n`);
    const sums = spawnSync('sh', ['-c', `sha256sum storage.tar.gz database.dump _supabase.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt ${files} > SHA256SUMS`], { cwd: backup });
    assert.equal(sums.status, 0);
    if (sign) signBackup(backup); else rmSync(join(backup, 'SHA256SUMS.hmac'), { force: true });
  };
  resum();
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
if [ "$1" = ps ] && [ "$FAKE_PROJECT_EXISTS" = yes ]; then printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"; echo 0123456789ab; exit 0; fi
if [ "$1" = volume ] && [ -n "$FAKE_VOLUMES" ]; then printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"; printf '%s\\n' $FAKE_VOLUMES; exit 0; fi
exec ${bin}/docker "$@"
`, { mode: 0o755 });
  // `key` is the file passed as --backup-key; null leaves the option out.
  const run = (args, extra = {}, { key = keyFile } = {}) => {
    const result = spawnSync('bash', [join(root, 'scripts/restore-host.sh'), ...(key ? ['--backup-key', key] : []), ...args], { encoding: 'utf8',
      env: { ...process.env, PATH: `${wrap}:${process.env.PATH}`, FAKE_DOCKER_LOG: dockerLog, RESTORE_LOG: log, ...extra } });
    return { ...result, restoreCalls: readFileSync(log, 'utf8') };
  };
  const signArchive = file => writeFileSync(`${file}.hmac`, `warehouse-backup-hmac-v1 ${hmacHex(backupKey, 'warehouse-backup-archive-v1', readFileSync(`${file}.sha256`))}\n`);
  const tarball = ({ sign = true } = {}) => {
    const tar = join(scratch, 'drive', `${NAME}.tar`);
    assert.equal(spawnSync('tar', ['-C', join(scratch, 'drive'), '-cf', tar, NAME]).status, 0);
    writeFileSync(`${tar}.sha256`, spawnSync('sha256sum', [`${NAME}.tar`], { cwd: join(scratch, 'drive'), encoding: 'utf8' }).stdout);
    if (sign) signArchive(tar);
    return tar;
  };
  // The encrypted form backup-usb.sh writes, produced with the script's own cipher.
  const encrypted = () => {
    const tar = tarball({ sign: false });
    const enc = spawnSync('bash', ['-c', 'set -euo pipefail; source "$1"; backup_key_load "$2"; backup_encrypt "$BACKUP_KEY" < "$3" > "$3.enc"', 'sh', join(root, 'scripts/backup-key.sh'), keyFile, tar], { encoding: 'utf8' });
    assert.equal(enc.status, 0, enc.stderr);
    rmSync(tar); rmSync(`${tar}.sha256`);
    writeFileSync(`${tar}.enc.sha256`, spawnSync('sha256sum', [`${NAME}.tar.enc`], { cwd: join(scratch, 'drive'), encoding: 'utf8' }).stdout);
    signArchive(`${tar}.enc`);
    return `${tar}.enc`;
  };
  return { scratch, root, backup, parent, run, tarball, encrypted, resum, keyFile, original, state: join(parent, 'acme') };
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
    assert.equal(readFileSync(join(f.state, 'config/backup.key'), 'utf8'), `${backupKey}\n`, 'the rebuilt installation keeps the backup key');
    assert.equal(statSync(join(f.state, 'config/backup.key')).mode & 0o777, 0o600);
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

test('restore-host takes an unsigned v4 backup only with --allow-unsigned, with a warning, and passes the flag on', () => {
  const f = fixture('warehouse-restore-host-v4-');
  try {
    f.resum({ format: 'warehouse-backup-v4', sign: false });
    let result = f.run(['--state-dir', f.state, '--yes', f.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /carries no signature[\s\S]*--allow-unsigned/); nothingCreated(f, result);
    result = f.run(['--state-dir', f.state, '--yes', '--allow-unsigned', f.backup], {}, { key: null });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stderr, /WARNING: this backup carries no signature[\s\S]*WITHOUT proof/);
    assert.equal(result.restoreCalls, `STATE=${f.state} ARGS=--yes --relocated --allow-unsigned ${join(f.state, 'backups', NAME)}\n`);
    assert.equal(existsSync(join(f.state, 'config/backup.key')), false, 'no key is invented; the first backup creates one');
  } finally { clean(f); }
  // A v5 label without a signature is not an old backup.
  const g = fixture('warehouse-restore-host-v5-unsigned-');
  try {
    g.resum({ sign: false });
    const result = g.run(['--state-dir', g.state, '--yes', g.backup]);
    assert.equal(result.status, 1); assert.match(result.stderr, /carries no signature/); nothingCreated(g, result);
  } finally { clean(g); }
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

// What a host that ran the monitoring and printing profiles keeps after `compose down`.
const OTHER_VOLUMES = ['prometheus_data', 'grafana_data', 'cups-spool'].map(name => `warehouse-backup-test_${name}`);

test('restore-host refuses a host that still has the database configuration volume, and names only that volume', () => {
  const f = fixture('warehouse-restore-host-volume-');
  try {
    const result = f.run(['--state-dir', f.state, '--yes', f.backup], { FAKE_VOLUMES: ['warehouse-backup-test_prometheus_data', 'warehouse-backup-test_db-config', 'warehouse-backup-test_cups-spool'].join(' ') });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Docker volume warehouse-backup-test_db-config of the previous database remains[\s\S]*docker volume rm warehouse-backup-test_db-config$/m);
    assert.doesNotMatch(result.stderr, /docker volume rm.*(prometheus_data|cups-spool)/, 'the operator is not told to delete monitoring history or the print spool');
    nothingCreated(f, result);
  } finally { clean(f); }
});

test('restore-host is not stopped by monitoring and printing volumes, which hold no restored state', () => {
  const f = fixture('warehouse-restore-host-other-volumes-');
  try {
    const result = f.run(['--state-dir', f.state, '--yes', f.backup], { FAKE_VOLUMES: OTHER_VOLUMES.join(' ') });
    assert.equal(result.status, 0, result.stderr + result.stdout);
    assert.match(result.stdout, new RegExp(`Kept the Docker volumes ${OTHER_VOLUMES.join(', ')}`));
    assert.equal(result.restoreCalls, `STATE=${f.state} ARGS=--yes --relocated ${join(f.state, 'backups', NAME)}\n`);
  } finally { clean(f); }
});

test('the volumes restore-host refuses are exactly the named volumes of the services whose data a restore replaces', { skip: !composeAvailable() && !process.env.CI ? 'docker compose is not installed' : false }, () => {
  const declared = readFileSync(join(repo, 'scripts/restore-host.sh'), 'utf8').match(/^STATE_VOLUMES=\(([^)]*)\)$/m);
  assert.ok(declared, 'restore-host.sh declares STATE_VOLUMES');
  // restore.sh replays the database (data/db) and the stored files (data/storage).
  const { services, volumes } = renderedCompose();
  const named = ['db', 'storage'].flatMap(service => (services[service].volumes ?? []).filter(mount => mount.type === 'volume').map(mount => mount.source));
  assert.deepEqual(declared[1].split(/\s+/).filter(Boolean).sort(), [...new Set(named)].sort());
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
