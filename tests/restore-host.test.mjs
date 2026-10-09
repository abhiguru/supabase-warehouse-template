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
import { makeBackup, makeState, fakeDocker, scriptRoot, composeEnv, instanceJson, repo } from './backup-test-helpers.mjs';

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
  writeFileSync(join(backup, 'metadata.txt'), `format=warehouse-backup-v4\ncreated_at_utc=20260101T000000Z\nsource_commit=abc1234\n`);
  const sums = spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump _supabase.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: backup });
  assert.equal(sums.status, 0);
  const parent = join(scratch, 'srv'); mkdirSync(parent, { mode: 0o755 });
  const log = join(scratch, 'restore.log'); writeFileSync(log, '');
  const dockerLog = join(scratch, 'docker.log'); writeFileSync(dockerLog, '');
  const bin = fakeDocker(join(scratch, 'bin'));
  // Containers of the project exist only when FAKE_PROJECT_EXISTS=yes.
  const wrap = join(scratch, 'wrap'); mkdirSync(wrap);
  writeFileSync(join(wrap, 'docker'), `#!/bin/sh
if [ "$1" = ps ] && [ "$FAKE_PROJECT_EXISTS" = yes ]; then printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"; echo 0123456789ab; exit 0; fi
exec ${bin}/docker "$@"
`, { mode: 0o755 });
  const run = (args, extra = {}) => {
    const result = spawnSync('bash', [join(root, 'scripts/restore-host.sh'), ...args], { encoding: 'utf8',
      env: { ...process.env, PATH: `${wrap}:${process.env.PATH}`, FAKE_DOCKER_LOG: dockerLog, RESTORE_LOG: log, ...extra } });
    return { ...result, restoreCalls: readFileSync(log, 'utf8') };
  };
  const tarball = () => {
    const tar = join(scratch, 'drive', `${NAME}.tar`);
    assert.equal(spawnSync('tar', ['-C', join(scratch, 'drive'), '-cf', tar, NAME]).status, 0);
    writeFileSync(`${tar}.sha256`, spawnSync('sha256sum', [`${NAME}.tar`], { cwd: join(scratch, 'drive'), encoding: 'utf8' }).stdout);
    return tar;
  };
  return { scratch, root, backup, parent, run, tarball, original, state: join(parent, 'acme') };
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
  } finally { clean(f); }
});

test('restore-host takes a USB archive after checking it, and accepts an existing empty state directory', () => {
  const f = fixture('warehouse-restore-host-tar-');
  try {
    const tar = f.tarball();
    mkdirSync(f.state, { mode: 0o700 });
    const result = f.run(['--yes', '--state-dir', f.state, tar]);
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
    assert.equal(spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump _supabase.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt tunnel/* > SHA256SUMS'], { cwd: f.backup }).status, 0);
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
