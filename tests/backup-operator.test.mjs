import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, statSync, truncateSync, symlinkSync } from 'node:fs';
import { makeBackup, fakeDocker, fakeBackupDocker, backupKey, signBackup, writeKey, hmacHex, centralKeySet, currentDatabaseImage, pngLetterhead, jpegLetterhead } from './backup-test-helpers.mjs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';

// backup.sh refuses a backup that would leave less than a 2 GiB reserve free on the disk of the backup folder; these tests are about
// other things and run on whatever temporary filesystem the machine has, so they run with no reserve (every spawn below inherits it).
process.env.WAREHOUSE_BACKUP_RESERVE_MB ??= '0';

test('backup refuses an unspecified operator state before using Docker', () => {
  const result = spawnSync('bash', [new URL('../scripts/backup.sh', import.meta.url).pathname], {
    encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: '' },
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /WAREHOUSE_STATE_DIR/);
});

test('restore verifier rejects incomplete backup before starting a container', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-backup-test-'));
  try {
    const backup = join(scratch, 'backup');
    mkdirSync(backup);
    writeFileSync(join(backup, 'metadata.txt'), 'format=warehouse-backup-v5\n');
    const result = spawnSync('bash', [new URL('../scripts/verify-restore.sh', import.meta.url).pathname, backup], { encoding: 'utf8' });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Incomplete backup/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('backup restarts only the services it stopped: every up has --no-deps', () => {
  const script = readFileSync(new URL('../scripts/backup.sh', import.meta.url), 'utf8');
  const ups = script.split('\n').filter(line => /compose up\b/.test(line));
  assert.equal(ups.length, 2, 'the cleanup restart and the normal restart');
  for (const line of ups) assert.match(line, /up -d --no-recreate --no-deps --wait --wait-timeout 180 "\$\{restart\[@\]\}"/, line);
});

test('backup pauses owned writers, preserves credentials and resumes writers', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-backup-flow-'));
  const state = join(scratch, 'state');
  const bin = join(scratch, 'bin');
  const log = join(scratch, 'docker.log');
  const destination = join(scratch, 'backup');
  try {
    for (const path of [state, join(state, 'config'), join(state, 'public'), join(state, 'data'), join(state, 'data/db'), join(state, 'data/storage'), bin]) mkdirSync(path, { recursive: true, mode: 0o700 });
    writeFileSync(join(state, 'config/compose.env'), `WAREHOUSE_PROJECT_NAME=warehouse-backup-test\nWAREHOUSE_DB_PATH=${state}/data/db\nWAREHOUSE_STORAGE_PATH=${state}/data/storage\n`, { mode: 0o600 });
    writeFileSync(join(state, 'public/instance.json'), '{"schemaVersion":1}\n');
    writeFileSync(join(state, 'data/storage/object'), 'object data');
    fakeBackupDocker(bin);
    const result = spawnSync('bash', [new URL('../scripts/backup.sh', import.meta.url).pathname, destination], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(join(destination, 'database.dump'), 'utf8'), 'fake database dump\n');
    // The pooler's _supabase database is not backed up: the pooler writes its tenant again at every start.
    assert.equal(existsSync(join(destination, '_supabase.dump')), false);
    assert.equal(readFileSync(join(destination, 'storage_objects.txt'), 'utf8'), 'documents/a.pdf/v1\n');
    assert.equal(readFileSync(join(destination, 'compose.env'), 'utf8').includes('WAREHOUSE_PROJECT_NAME='), true);
    assert.match(readFileSync(join(destination, 'metadata.txt'), 'utf8'), /^format=warehouse-backup-v6$/m);
    assert.match(readFileSync(join(destination, 'metadata.txt'), 'utf8'), /^link_base=none$/m, 'the first backup is a full copy');
    assert.match(readFileSync(join(destination, 'metadata.txt'), 'utf8'), /^storage_files=1$/m);
    assert.match(readFileSync(join(destination, 'metadata.txt'), 'utf8'), /^storage_bytes=11$/m);
    assert.match(readFileSync(join(destination, 'metadata.txt'), 'utf8'), /^storage_new_bytes=11$/m, 'nothing to link to: every byte is new');
    assert.match(readFileSync(join(destination, 'metadata.txt'), 'utf8'), /^stop_seconds=\d+$/m);
    assert.match(readFileSync(join(destination, 'metadata.txt'), 'utf8'), /^duration_seconds=\d+$/m);
    assert.equal(readFileSync(join(destination, 'metadata.txt'), 'utf8').match(/^database_image=(.*)$/m)?.[1], currentDatabaseImage(), 'the image line is the Dockerfile pin');
    assert.match(readFileSync(join(destination, 'metadata.txt'), 'utf8'), /^database_image=postgres:18\.\S+@sha256:[0-9a-f]{64}$/m);
    assert.match(readFileSync(join(destination, 'metadata.txt'), 'utf8'), /^source_commit=([0-9a-f]{40}|unknown)$/m);
    // The installation had no backup key: the first backup creates it, private, and signs with it.
    const keyPath = join(state, 'config/backup.key');
    const key = readFileSync(keyPath, 'utf8').trim();
    assert.match(key, /^[0-9a-f]{64}$/);
    assert.equal(statSync(keyPath).mode & 0o777, 0o600);
    assert.match(result.stderr, /Created the backup key[\s\S]*away from this machine/);
    assert.equal(readFileSync(join(destination, 'SHA256SUMS.hmac'), 'utf8'),
      `warehouse-backup-hmac-v1 ${hmacHex(key, 'warehouse-backup-manifest-v1', readFileSync(join(destination, 'SHA256SUMS')))}\n`, 'signature is the HMAC of SHA256SUMS under the backup key');
    assert.ok(!readdirSync(destination).includes('backup.key') && !readFileSync(join(destination, 'SHA256SUMS'), 'utf8').includes('backup.key'), 'the key never enters the backup');
    for (const name of readdirSync(destination)) if (statSync(join(destination, name)).isFile()) assert.ok(!readFileSync(join(destination, name), 'latin1').includes(key), `${name} does not contain the key`);
    assert.match(readFileSync(join(destination, 'roles.txt'), 'utf8'), /supabase_admin/);
    const sums = readFileSync(join(destination, 'SHA256SUMS'), 'utf8');
    for (const file of ['database.dump', 'storage.manifest', 'storage_objects.txt', 'integrity.txt', 'metadata.txt', 'compose.env', 'instance.json', 'roles.txt'])
      assert.match(sums, new RegExp(`^[0-9a-f]{64}  ${file.replace('.', '\\.')}$`, 'm'), `${file} is checksummed`);
    assert.doesNotMatch(sums, /storage\.tar\.gz|storage\//, 'the tree is covered by the manifest, not listed file by file');
    assert.equal(readFileSync(join(destination, 'storage.manifest'), 'utf8'), `${createHash('sha256').update('object data').digest('hex')}  object\n`);
    assert.equal(readFileSync(join(destination, 'storage/object'), 'utf8'), 'object data');
    assert.equal(spawnSync('bash', ['-c', 'source "$1"; WAREHOUSE_BACKUP_KEY_FILE="$2" backup_authenticate "$3" false', 'x', new URL('../scripts/backup-key.sh', import.meta.url).pathname, join(state, 'config/backup.key'), destination], { encoding: 'utf8' }).status, 0, 'the tree authenticates against its manifest');
    assert.equal(spawnSync('sha256sum', ['-c', '--quiet', 'SHA256SUMS'], { cwd: destination, encoding: 'utf8' }).status, 0, 'SHA256SUMS verifies');
    assert.match(result.stderr, /shares a filesystem with .*\/data/, 'same-filesystem destination warns');
    const calls = readFileSync(log, 'utf8');
    const mainDump = calls.split('\n').find(line => line.includes('pg_dump') && line.includes('-d postgres'));
    assert.ok(mainDump && !mainDump.includes('--no-owner'), 'main dump keeps owners for in-place restore');
    assert.equal(calls.includes('_supabase'), false, 'no command touches the _supabase database');
    assert.equal(calls.split('\n').filter(line => line.includes('pg_dump')).length, 1, 'one dump: the application database');
    assert.ok(calls.indexOf('stop gateway') < calls.indexOf('pg_dump'));
    assert.ok(calls.indexOf('stop supavisor') < calls.indexOf('pg_dump'));
    assert.ok(calls.indexOf('pg_dump') < calls.indexOf('up -d --no-recreate --no-deps --wait --wait-timeout 180 gateway'));
    assert.match(calls, /up -d --no-recreate --no-deps --wait --wait-timeout 180 gateway/);
    assert.doesNotMatch(calls, /up -d --no-recreate --wait/, 'no restart without --no-deps');
    assert.equal(existsSync(join(destination, 'storage.tar.gz')), false, 'no tarball any more');
    writeFileSync(log, '');
    const failed = spawnSync('bash', [new URL('../scripts/backup.sh', import.meta.url).pathname, join(scratch, 'failed-backup')], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log, FAKE_DOCKER_FAIL: 'yes', FAKE_FAIL_UP: 'yes' },
    });
    assert.notEqual(failed.status, 0);
    assert.match(failed.stderr, /Service storage is running \(unhealthy\)\. Its last log lines:\nfake log of storage\n/);
    assert.equal(existsSync(join(scratch, 'failed-backup')), false);
    const failureCalls = readFileSync(log, 'utf8');
    assert.ok(failureCalls.indexOf('pg_dump') < failureCalls.indexOf('up -d --no-recreate --no-deps --wait --wait-timeout 180 gateway'));
    assert.equal(existsSync(join(destination, 'tunnel')), false, 'no tunnel directory without an adopted credential');

    // A tunnel credential adopted into the state (scripts/tunnel.sh) travels with every backup.
    mkdirSync(join(state, 'config/tunnel'), { mode: 0o700 });
    writeFileSync(join(state, 'config/tunnel/config.yml'), `tunnel: x\ncredentials-file: ${state}/config/tunnel/credentials.json\n`, { mode: 0o600 });
    writeFileSync(join(state, 'config/tunnel/credentials.json'), '{"TunnelSecret":"s"}', { mode: 0o600 });
    const withTunnel = join(scratch, 'backup-tunnel');
    const tunnelRun = spawnSync('bash', [new URL('../scripts/backup.sh', import.meta.url).pathname, withTunnel], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log },
    });
    assert.equal(tunnelRun.status, 0, tunnelRun.stderr);
    assert.equal(readFileSync(keyPath, 'utf8').trim(), key, 'later backups keep the same key');
    assert.doesNotMatch(tunnelRun.stderr, /Created the backup key/);
    assert.equal(readFileSync(join(withTunnel, 'tunnel/credentials.json'), 'utf8'), '{"TunnelSecret":"s"}');
    assert.equal(statSync(join(withTunnel, 'tunnel')).mode & 0o777, 0o700);
    assert.equal(statSync(join(withTunnel, 'tunnel/config.yml')).mode & 0o777, 0o600);
    assert.match(readFileSync(join(withTunnel, 'SHA256SUMS'), 'utf8'), /^[0-9a-f]{64} {2}tunnel\/credentials\.json$/m);
    assert.equal(spawnSync('sha256sum', ['-c', '--quiet', 'SHA256SUMS'], { cwd: withTunnel }).status, 0);

    // TW-BE-020: the central key file (public keys only) travels with the backup, because compose.env
    // keeps naming it. Neither earlier backup had one to carry, and says nothing about it.
    for (const earlier of [destination, withTunnel]) {
      assert.equal(existsSync(join(earlier, 'central-jwks.json')), false, 'no key file in a backup of a state without one');
      assert.doesNotMatch(readFileSync(join(earlier, 'SHA256SUMS'), 'utf8'), /central-jwks/);
    }
    writeFileSync(join(state, 'public/central-jwks.json'), centralKeySet, { mode: 0o644 });
    const withKeys = join(scratch, 'backup-keys');
    const keysRun = spawnSync('bash', [new URL('../scripts/backup.sh', import.meta.url).pathname, withKeys], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log },
    });
    assert.equal(keysRun.status, 0, keysRun.stderr);
    assert.equal(readFileSync(join(withKeys, 'central-jwks.json'), 'utf8'), centralKeySet, 'the key file is copied byte for byte');
    assert.equal(statSync(join(withKeys, 'central-jwks.json')).mode & 0o777, 0o600, 'private like every file of the backup');
    const keySums = readFileSync(join(withKeys, 'SHA256SUMS'), 'utf8');
    assert.match(keySums, /^[0-9a-f]{64} {2}central-jwks\.json$/m, 'listed in SHA256SUMS, which the signature covers');
    assert.equal(spawnSync('sha256sum', ['-c', '--quiet', 'SHA256SUMS'], { cwd: withKeys }).status, 0);
    assert.equal(readFileSync(join(withKeys, 'SHA256SUMS.hmac'), 'utf8'),
      `warehouse-backup-hmac-v1 ${hmacHex(key, 'warehouse-backup-manifest-v1', readFileSync(join(withKeys, 'SHA256SUMS')))}\n`);
    // Something that is not a plain file in its place is refused, and no backup is left behind.
    rmSync(join(state, 'public/central-jwks.json'));
    symlinkSync(join(state, 'public/instance.json'), join(state, 'public/central-jwks.json'));
    const linked = spawnSync('bash', [new URL('../scripts/backup.sh', import.meta.url).pathname, join(scratch, 'backup-linked')], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log },
    });
    assert.notEqual(linked.status, 0);
    assert.match(linked.stderr, /central-jwks\.json is not a regular file/);
    assert.equal(existsSync(join(scratch, 'backup-linked')), false);

    // The letterhead image of the document PDFs travels with the backup the same way (setup.sh --letterhead-file);
    // none of the earlier backups had one to carry.
    rmSync(join(state, 'public/central-jwks.json'));
    for (const earlier of [destination, withTunnel, withKeys]) {
      assert.deepEqual(readdirSync(earlier).filter(name => name.startsWith('letterhead')), [], 'no letterhead in a backup of a state without one');
      assert.doesNotMatch(readFileSync(join(earlier, 'SHA256SUMS'), 'utf8'), /letterhead/);
    }
    const backupWith = (name, bytes, target) => {
      writeFileSync(join(state, 'public', name), bytes, { mode: 0o644 });
      return [target, spawnSync('bash', [new URL('../scripts/backup.sh', import.meta.url).pathname, target], {
        encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log },
      })];
    };
    for (const [name, bytes] of [['letterhead.png', pngLetterhead], ['letterhead.jpg', jpegLetterhead]]) {
      const [target, run] = backupWith(name, bytes, join(scratch, `backup-${name}`));
      assert.equal(run.status, 0, run.stderr);
      assert.deepEqual(readFileSync(join(target, name)), bytes, 'the image is copied byte for byte');
      assert.equal(statSync(join(target, name)).mode & 0o777, 0o600, 'private like every file of the backup');
      assert.match(readFileSync(join(target, 'SHA256SUMS'), 'utf8'), new RegExp(`^[0-9a-f]{64} {2}${name.replace('.', '\\.')}$`, 'm'), 'listed in SHA256SUMS, which the signature covers');
      assert.equal(spawnSync('sha256sum', ['-c', '--quiet', 'SHA256SUMS'], { cwd: target }).status, 0);
      assert.equal(readFileSync(join(target, 'SHA256SUMS.hmac'), 'utf8'),
        `warehouse-backup-hmac-v1 ${hmacHex(key, 'warehouse-backup-manifest-v1', readFileSync(join(target, 'SHA256SUMS')))}\n`);
      rmSync(join(state, 'public', name));
    }
    // A link in its place is refused, and no backup is left behind.
    symlinkSync(join(state, 'public/instance.json'), join(state, 'public/letterhead.png'));
    const linkedImage = spawnSync('bash', [new URL('../scripts/backup.sh', import.meta.url).pathname, join(scratch, 'backup-linked-image')], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log },
    });
    assert.notEqual(linkedImage.status, 0);
    assert.match(linkedImage.stderr, /letterhead\.png is not a regular file/);
    assert.equal(existsSync(join(scratch, 'backup-linked-image')), false);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier requires the catalog files before starting a container', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-backup-v4-'));
  try {
    const backup = makeBackup(join(scratch, 'backup'));
    rmSync(join(backup, 'storage_objects.txt'));
    // The signature is checked before the checksums, so the verifier needs the key to get as far as the file set.
    const result = verify(backup, scratch);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /not exactly the files its signed SHA256SUMS lists|storage_objects\.txt/);
    assert.equal(result.calls, '', 'no container is started');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

// Runs the verifier against the fake docker with the fixture backup key and no installed state.
function verify(backup, scratch, env = {}, args = []) {
  const log = join(scratch, 'docker.log');
  writeFileSync(log, '');
  const result = spawnSync('bash', [new URL('../scripts/verify-restore.sh', import.meta.url).pathname, ...args, backup], {
    encoding: 'utf8', env: { ...process.env, PATH: `${fakeDocker(join(scratch, 'bin'))}:${process.env.PATH}`, FAKE_DOCKER_LOG: log,
      FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), WAREHOUSE_STATE_DIR: '', WAREHOUSE_VERIFY_SCRATCH_DIR: '',
      WAREHOUSE_BACKUP_KEY_FILE: writeKey(join(scratch, 'backup.key')), WAREHOUSE_DIAGNOSTICS_DIR: join(scratch, 'diagnostics'), ...env },
  });
  return { ...result, calls: readFileSync(log, 'utf8') };
}

test('restore verifier replays the database in isolation and matches the object catalog', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-v4-'));
  try {
    const backup = makeBackup(join(scratch, 'backup'), { objects: ['documents/a.pdf/v1', 'dispatch-images/c1/photo.jpg/v7'] });
    const result = verify(backup, scratch);
    assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(result.stderr, /Warning/);
    const lines = result.calls.split('\n');
    const run = lines.find(line => line.startsWith('run '));
    assert.ok(run.includes('--network none') && run.includes('--tmpfs /var/lib/postgresql/data'), 'disposable container stays isolated');
    const main = lines.filter(line => line.includes('pg_restore') && line.includes('-d warehouse_restore'));
    assert.equal(main.length, 4, 'three sections plus the ACL replay');
    assert.ok(main.every(line => line.includes('--no-owner') && line.includes('--exit-on-error')));
    assert.equal(result.calls.includes('_supabase'), false, 'the pooler database is not part of a backup any more');
    assert.doesNotMatch(result.stdout, /_supabase\.dump/);
    assert.ok(lines.some(line => line.includes('-d warehouse_restore') && line.includes('storage.objects')), 'restored catalog is read back');
    assert.match(result.stdout, /integrity comparison passed/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier mounts a world-readable copy of the bootstrap file whatever the umask of the tree and of the caller', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-umask-'));
  try {
    // A tree as `git archive | tar -x` leaves it under umask 077: every file 0600. The postgres user of the container reads the mounted file.
    const tree = join(scratch, 'tree');
    for (const dir of ['scripts', 'docker/postgres', 'docker/volumes/db']) mkdirSync(join(tree, dir), { recursive: true });
    const here = new URL('..', import.meta.url).pathname;
    for (const file of readdirSync(join(here, 'scripts')).filter(f => /\.(sh|mjs|cjs|sql)$/.test(f))) writeFileSync(join(tree, 'scripts', file), readFileSync(join(here, 'scripts', file)), { mode: 0o600 });
    writeFileSync(join(tree, 'docker/postgres/Dockerfile'), readFileSync(join(here, 'docker/postgres/Dockerfile')), { mode: 0o600 });
    writeFileSync(join(tree, 'docker/volumes/db/00-bootstrap.sql'), 'SELECT 1;\n', { mode: 0o600 });
    const backup = makeBackup(join(scratch, 'backup'));
    const real = fakeDocker(join(scratch, 'bin'));
    const bin = join(scratch, 'wrap'); mkdirSync(bin);
    const modes = join(scratch, 'modes.log');
    writeFileSync(join(bin, 'docker'), `#!/bin/sh
if [ "$1" = run ]; then
  for a; do case "$a" in *:/docker-entrypoint-initdb.d/00-bootstrap.sql:ro) src="\${a%%:*}"; echo "$(stat -c %a "$src") $src" >> "${modes}" ;; esac; done
fi
exec "${real}/docker" "$@"
`, { mode: 0o700 });
    const log = join(scratch, 'docker.log'); writeFileSync(log, '');
    const result = spawnSync('bash', ['-c', 'umask 077; exec bash "$0" "$@"', join(tree, 'scripts/verify-restore.sh'), backup], { encoding: 'utf8',
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, FAKE_DOCKER_LOG: log, FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), WAREHOUSE_STATE_DIR: '', WAREHOUSE_VERIFY_SCRATCH_DIR: '',
        WAREHOUSE_BACKUP_KEY_FILE: writeKey(join(scratch, 'backup.key')), WAREHOUSE_DIAGNOSTICS_DIR: join(scratch, 'diagnostics') } });
    assert.equal(result.status, 0, result.stderr);
    const [mode, src] = readFileSync(modes, 'utf8').trim().split(' ');
    assert.equal(Number.parseInt(mode, 8) & 0o044, 0o044, `the mounted bootstrap file must be readable by the container's postgres user (mode ${mode})`);
    assert.notEqual(src, join(tree, 'docker/volumes/db/00-bootstrap.sql'), 'a copy is mounted, not the tree\'s own file');
    assert.equal(statSync(join(tree, 'docker/volumes/db/00-bootstrap.sql')).mode & 0o777, 0o600, 'the tree is left as it was');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier with --restore-only restores and stops: no integrity or catalog comparison, and says so', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-restore-only-'));
  try {
    const backup = makeBackup(join(scratch, 'backup'), { objects: ['documents/a.pdf/v1'] });
    // A restored catalog and an integrity report that differ from the backup's fail the full verification, and not this mode.
    writeFileSync(join(scratch, 'other-catalog.txt'), 'documents/a.pdf/v1\ndocuments/b.pdf/v1\n');
    const env = { FAKE_CATALOG_FILE: join(scratch, 'other-catalog.txt') };
    assert.notEqual(verify(backup, scratch, env).status, 0, 'the full verification sees the difference');
    const only = verify(backup, scratch, env, ['--restore-only']);
    assert.equal(only.status, 0, only.stderr);
    assert.match(only.stdout, /database restore \(the integrity comparison was not asked for\) passed/);
    assert.equal(only.calls.split('\n').filter(line => line.includes('pg_restore') && line.includes('-d warehouse_restore')).length, 4, 'the restore itself is complete');
    assert.doesNotMatch(only.calls, /storage\.objects|backup-integrity/, 'nothing is read back for comparison');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier fails when a catalogued object is missing from the archive and warns on extra files', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-catalog-'));
  try {
    const missing = makeBackup(join(scratch, 'missing'), { objects: ['documents/a.pdf/v1', 'documents/lost.pdf/v2'], files: ['stub/stub/documents/a.pdf/v1'] });
    const failed = verify(missing, scratch);
    assert.notEqual(failed.status, 0);
    assert.match(failed.stderr, /missing from storage\.tar\.gz[\s\S]*documents\/lost\.pdf\/v2/);
    assert.doesNotMatch(failed.calls, /^run /m, 'no container is started for an inconsistent archive');
    const extra = makeBackup(join(scratch, 'extra'), { objects: ['documents/a.pdf/v1'], files: ['stub/stub/documents/a.pdf/v1', 'stub/stub/documents/orphan.pdf/v9'] });
    const warned = verify(extra, scratch);
    assert.equal(warned.status, 0, warned.stderr);
    assert.match(warned.stderr, /Warning: 1 archived storage file\(s\) have no catalog entry[\s\S]*orphan\.pdf/);
    const drifted = makeBackup(join(scratch, 'drifted'), { objects: ['documents/a.pdf/v1'] });
    writeFileSync(join(scratch, 'other-catalog.txt'), 'documents/a.pdf/v1\ndocuments/b.pdf/v1\n');
    const diffed = verify(drifted, scratch, { FAKE_CATALOG_FILE: join(scratch, 'other-catalog.txt') });
    assert.notEqual(diffed.status, 0, 'restored catalog must equal the archived catalog');
    assert.match(diffed.stdout + diffed.stderr, /\+documents\/b\.pdf\/v1/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier accepts a checksummed tunnel credential and refuses anything else in tunnel/', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-tunnel-'));
  const resum = backup => { spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt tunnel/* > SHA256SUMS'], { cwd: backup }); signBackup(backup); };
  try {
    const good = makeBackup(join(scratch, 'good'));
    mkdirSync(join(good, 'tunnel'), { mode: 0o700 });
    writeFileSync(join(good, 'tunnel/config.yml'), 'tunnel: x\n');
    writeFileSync(join(good, 'tunnel/credentials.json'), '{}');
    resum(good);
    const passed = verify(good, scratch, { FAKE_CATALOG_FILE: join(good, 'storage_objects.txt') });
    assert.equal(passed.status, 0, passed.stderr);

    const unlisted = makeBackup(join(scratch, 'unlisted'));
    mkdirSync(join(unlisted, 'tunnel'));
    writeFileSync(join(unlisted, 'tunnel/token'), 'abc\n');
    const missingSum = verify(unlisted, scratch);
    assert.notEqual(missingSum.status, 0);
    assert.match(missingSum.stderr, /not exactly the files its signed SHA256SUMS lists/);
    // With the key lost, --allow-unsigned has no signed list; the verifier itself insists on a checksum for the file.
    const unlistedUnsigned = makeBackup(join(scratch, 'unlisted-unsigned'), { key: null });
    mkdirSync(join(unlistedUnsigned, 'tunnel'));
    writeFileSync(join(unlistedUnsigned, 'tunnel/token'), 'abc\n');
    const missingSumUnsigned = verify(unlistedUnsigned, scratch, { WAREHOUSE_BACKUP_KEY_FILE: join(scratch, 'absent.key') }, ['--allow-unsigned']);
    assert.notEqual(missingSumUnsigned.status, 0);
    assert.match(missingSumUnsigned.stderr, /checksum missing for tunnel\/token/);

    const extra = makeBackup(join(scratch, 'extra'));
    mkdirSync(join(extra, 'tunnel'));
    writeFileSync(join(extra, 'tunnel/cert.pem'), 'x');
    resum(extra);
    const unexpected = verify(extra, scratch);
    assert.notEqual(unexpected.status, 0);
    assert.match(unexpected.stderr, /Unexpected entry in the backup tunnel directory: tunnel\/cert\.pem/);
    assert.doesNotMatch(unexpected.calls, /^run /m, 'no container is started');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier accepts a checksummed central key file and refuses it unlisted, altered or not a plain file', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-central-key-'));
  const resum = backup => { spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: backup }); signBackup(backup); };
  try {
    const good = makeBackup(join(scratch, 'good'), { centralKey: centralKeySet });
    const passed = verify(good, scratch, { FAKE_CATALOG_FILE: join(good, 'storage_objects.txt') });
    assert.equal(passed.status, 0, passed.stderr);
    assert.match(passed.stdout, /signature, checksums/);

    // Present but not named in the signed list: refused before any container.
    const unlisted = makeBackup(join(scratch, 'unlisted'));
    writeFileSync(join(unlisted, 'central-jwks.json'), centralKeySet);
    const missingSum = verify(unlisted, scratch);
    assert.notEqual(missingSum.status, 0);
    assert.match(missingSum.stderr, /not exactly the files its signed SHA256SUMS lists/);
    // With the key lost, --allow-unsigned has no signed list; the verifier itself insists on a checksum for the file.
    const unlistedUnsigned = makeBackup(join(scratch, 'unlisted-unsigned'), { key: null });
    writeFileSync(join(unlistedUnsigned, 'central-jwks.json'), centralKeySet);
    const missingSumUnsigned = verify(unlistedUnsigned, scratch, { WAREHOUSE_BACKUP_KEY_FILE: join(scratch, 'absent.key') }, ['--allow-unsigned']);
    assert.notEqual(missingSumUnsigned.status, 0);
    assert.match(missingSumUnsigned.stderr, /Backup checksum missing for central-jwks\.json/);

    // Changed after the backup was written: the checksum, which the signature covers, no longer matches.
    const altered = makeBackup(join(scratch, 'altered'), { centralKey: centralKeySet });
    writeFileSync(join(altered, 'central-jwks.json'), centralKeySet.replace('central-2026-10', 'planted-key'));
    const changed = verify(altered, scratch);
    assert.notEqual(changed.status, 0);
    assert.match(changed.stderr, /does not match its SHA256SUMS/);

    // A directory of that name (nothing for the signed list to name) is not a key file.
    const directory = makeBackup(join(scratch, 'directory'));
    mkdirSync(join(directory, 'central-jwks.json'));
    resum(directory);
    const notPlain = verify(directory, scratch);
    assert.notEqual(notPlain.status, 0);
    assert.match(notPlain.stderr, /Backup entry central-jwks\.json is not a regular file/);
    assert.equal(notPlain.calls, '', 'no container is started');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier accepts a checksummed letterhead image, a backup without one, and refuses it unlisted, altered or not a plain file', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-letterhead-'));
  const resum = backup => { spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: backup }); signBackup(backup); };
  try {
    for (const [name, bytes] of [['letterhead.png', pngLetterhead], ['letterhead.jpg', jpegLetterhead]]) {
      const good = makeBackup(join(scratch, `good-${name}`), { letterhead: { name, bytes } });
      const passed = verify(good, scratch, { FAKE_CATALOG_FILE: join(good, 'storage_objects.txt') });
      assert.equal(passed.status, 0, passed.stderr);
      assert.match(passed.stdout, /signature, checksums/);
      assert.match(readFileSync(join(good, 'SHA256SUMS'), 'utf8'), new RegExp(name.replace('.', '\\.')));
    }
    // An older backup has none: treated as no letterhead.
    const older = makeBackup(join(scratch, 'older'));
    assert.equal(verify(older, scratch, { FAKE_CATALOG_FILE: join(older, 'storage_objects.txt') }).status, 0);

    const unlisted = makeBackup(join(scratch, 'unlisted'));
    writeFileSync(join(unlisted, 'letterhead.png'), pngLetterhead);
    const missingSum = verify(unlisted, scratch);
    assert.notEqual(missingSum.status, 0);
    assert.match(missingSum.stderr, /not exactly the files its signed SHA256SUMS lists/);
    const unlistedUnsigned = makeBackup(join(scratch, 'unlisted-unsigned'), { key: null });
    writeFileSync(join(unlistedUnsigned, 'letterhead.jpg'), jpegLetterhead);
    const missingSumUnsigned = verify(unlistedUnsigned, scratch, { WAREHOUSE_BACKUP_KEY_FILE: join(scratch, 'absent.key') }, ['--allow-unsigned']);
    assert.notEqual(missingSumUnsigned.status, 0);
    assert.match(missingSumUnsigned.stderr, /Backup checksum missing for letterhead\.jpg/);

    const altered = makeBackup(join(scratch, 'altered'), { letterhead: { name: 'letterhead.png', bytes: pngLetterhead } });
    writeFileSync(join(altered, 'letterhead.png'), Buffer.concat([pngLetterhead, Buffer.from('planted')]));
    const changed = verify(altered, scratch);
    assert.notEqual(changed.status, 0);
    assert.match(changed.stderr, /does not match its SHA256SUMS/);

    const directory = makeBackup(join(scratch, 'directory'));
    mkdirSync(join(directory, 'letterhead.png'));
    resum(directory);
    const notPlain = verify(directory, scratch);
    assert.notEqual(notPlain.status, 0);
    assert.match(notPlain.stderr, /Backup entry letterhead\.png is not a regular file/);
    assert.equal(notPlain.calls, '', 'no container is started');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier accepts a backup from before the pooler became optional and skips its _supabase.dump with a note', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-legacy-pooler-'));
  try {
    const backup = makeBackup(join(scratch, 'backup'), { legacyPooler: true });
    assert.equal(existsSync(join(backup, '_supabase.dump')), true, 'the fixture is an old backup');
    const result = verify(backup, scratch);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Note: the backup contains _supabase\.dump \(the pooler tenant\)\. It is skipped: the pooler recreates its tenant when it starts\./);
    assert.equal(result.calls.includes('_supabase'), false, 'it is neither copied into the container nor replayed');
    assert.match(result.stdout, /integrity comparison passed/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier creates one disposable database from template0, never template1', () => {
  // CI run fe19442: createdb -T template1 failed with "source database template1 is being accessed by other users".
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-template-'));
  try {
    const result = verify(makeBackup(join(scratch, 'backup')), scratch);
    assert.equal(result.status, 0, result.stderr);
    const created = result.calls.split('\n').filter(line => / createdb /.test(line));
    assert.equal(created.length, 1, 'warehouse_restore only');
    for (const line of created) assert.match(line, / -T template0 warehouse_restore$/, line);
    assert.doesNotMatch(result.calls, /template1/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('a failed verification saves the container log and database sessions before the container is removed', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-diagnostics-'));
  try {
    const result = verify(makeBackup(join(scratch, 'backup')), scratch, { FAKE_FAIL_CREATEDB: 'yes' });
    assert.notEqual(result.status, 0);
    const [dir] = readdirSync(join(scratch, 'diagnostics'));
    assert.match(dir, /^verify-restore-\d{8}T\d{6}Z-[0-9a-f]{12}$/);
    assert.equal(readFileSync(join(scratch, 'diagnostics', dir, 'container.log'), 'utf8'), 'fake container log line\nPostgreSQL init process complete; ready for start up.\n');
    assert.match(readFileSync(join(scratch, 'diagnostics', dir, 'pg_stat_activity.txt'), 'utf8'), /client backend\|template1/);
    assert.equal(statSync(join(scratch, 'diagnostics', dir)).mode & 0o777, 0o700);
    assert.match(result.stderr, new RegExp(`were saved in ${join(scratch, 'diagnostics', dir)}`));
    assert.match(result.stderr, /41\|client backend\|template1\|idle/, 'the session list is printed for a CI log');
    const lines = result.calls.split('\n');
    const removed = lines.findIndex(line => /^rm -f -v warehouse-restore-/.test(line));
    assert.ok(lines.findIndex(line => line.startsWith('logs ')) < removed && lines.findIndex(line => line.includes('pg_stat_activity')) < removed, 'evidence is collected first');
    assert.ok(removed >= 0, 'the container is still removed');
    assert.doesNotMatch(result.stderr, /ran out of space/);
    const full = verify(makeBackup(join(scratch, 'full')), scratch, { FAKE_FAIL_CREATEDB: 'yes', FAKE_LOG_NO_SPACE: 'yes', WAREHOUSE_VERIFY_STORAGE: 'tmpfs' });
    assert.match(full.stderr, /ran out of space: its data directory was 768 MiB .* on tmpfs\. This says nothing about the backup\. Repeat with a larger WAREHOUSE_VERIFY_DATA_MB/);
    const passed = verify(makeBackup(join(scratch, 'good')), scratch, { WAREHOUSE_DIAGNOSTICS_DIR: join(scratch, 'none') });
    assert.equal(passed.status, 0, passed.stderr);
    assert.equal(existsSync(join(scratch, 'none')), false, 'a passing run writes no diagnostics');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier refuses a backup whose signature is missing, wrong or unverifiable, before any container', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-signature-'));
  const noContainer = result => assert.equal(result.calls, '', 'docker is never invoked');
  try {
    // Edited after the fact, checksums regenerated: only the key holder could re-sign.
    const edited = makeBackup(join(scratch, 'edited'));
    writeFileSync(join(edited, 'database.dump'), 'planted dump\n');
    spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: edited });
    assert.equal(spawnSync('sha256sum', ['-c', '--quiet', 'SHA256SUMS'], { cwd: edited }).status, 0);
    let result = verify(edited, scratch);
    assert.notEqual(result.status, 0); assert.match(result.stderr, /signature of this backup does not match the backup key/); noContainer(result);
    result = verify(edited, scratch, {}, ['--allow-unsigned']);
    assert.notEqual(result.status, 0, '--allow-unsigned does not accept a wrong signature'); noContainer(result);

    const otherKey = makeBackup(join(scratch, 'other-key'), { key: 'e1'.repeat(32) });
    result = verify(otherKey, scratch);
    assert.notEqual(result.status, 0); assert.match(result.stderr, /does not match the backup key/); noContainer(result);

    const stripped = makeBackup(join(scratch, 'stripped'), { key: null });
    result = verify(stripped, scratch);
    assert.notEqual(result.status, 0); assert.match(result.stderr, /carries no signature/); noContainer(result);

    const good = makeBackup(join(scratch, 'good'));
    result = verify(good, scratch, { WAREHOUSE_BACKUP_KEY_FILE: '' });
    assert.notEqual(result.status, 0); assert.match(result.stderr, /no backup key is available/); noContainer(result);
    result = verify(good, scratch, { WAREHOUSE_BACKUP_KEY_FILE: join(scratch, 'absent.key') });
    assert.notEqual(result.status, 0); assert.match(result.stderr, /no backup key is available/); noContainer(result);
    // The key of the installed state is the default.
    mkdirSync(join(scratch, 'state/config'), { recursive: true });
    writeKey(join(scratch, 'state/config/backup.key'));
    result = verify(good, scratch, { WAREHOUSE_BACKUP_KEY_FILE: '', WAREHOUSE_STATE_DIR: join(scratch, 'state') });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Backup signature, checksums/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

// TW-BE-022: the verifier gives the same answers as restore and restore-host.
test('restore verifier refuses a v5 backup whose signature file was removed, even with --allow-unsigned, while the key is available', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-stripped-v5-'));
  try {
    const stripped = makeBackup(join(scratch, 'stripped'), { key: null });
    assert.equal(existsSync(join(stripped, 'SHA256SUMS.hmac')), false);
    // verify() points WAREHOUSE_BACKUP_KEY_FILE at a key file by default.
    let result = verify(stripped, scratch, {}, ['--allow-unsigned']);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /a v5 or v6 backup must be signed; its signature file was removed/);
    assert.match(result.stderr, /--allow-unsigned is only for when the backup key is lost/);
    assert.doesNotMatch(result.stderr, /WARNING|WITHOUT proof/);
    assert.equal(result.calls, '', 'docker is never invoked');
    // Without the flag too, and before the checksums are run.
    writeFileSync(join(stripped, 'database.dump'), 'damaged after the signature was removed\n');
    result = verify(stripped, scratch);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /carries no signature[\s\S]*a v5 or v6 backup must be signed/);
    assert.doesNotMatch(result.stderr, /does not match its SHA256SUMS/);
    assert.equal(result.calls, '');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier takes the same v5 backup with --allow-unsigned once the key is lost', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-stripped-v5-lost-key-'));
  try {
    const stripped = makeBackup(join(scratch, 'stripped'), { key: null });
    let result = verify(stripped, scratch, { WAREHOUSE_BACKUP_KEY_FILE: join(scratch, 'absent.key') }, ['--allow-unsigned']);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stderr, /WARNING: this backup carries no signature[\s\S]*WITHOUT proof/);
    assert.doesNotMatch(result.stderr, /a v5 or v6 backup must be signed/);
    assert.match(result.stdout, /UNSIGNED/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier refuses a v4 backup, with or without --allow-unsigned, and starts no container', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-v4-refused-'));
  try {
    const backup = makeBackup(join(scratch, 'backup'), { format: 'warehouse-backup-v4' });
    for (const args of [[], ['--allow-unsigned']]) {
      const refused = verify(backup, scratch, {}, args);
      assert.notEqual(refused.status, 0, args.join(' '));
      assert.match(refused.stderr, /backup format 'warehouse-backup-v4' is no longer supported; take a new backup with this version \(only warehouse-backup-v5 and -v6 are accepted\)\./);
      assert.equal(refused.calls, '');
    }
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier refuses format labels that are not exactly warehouse-backup-v5 or -v6, with no calls', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-label-'));
  try {
    const backup = makeBackup(join(scratch, 'backup'));
    const cases = {
      'carriage return': 'format=warehouse-backup-v5\r\ncreated_at_utc=20260101T000000Z\n',
      'v50': 'format=warehouse-backup-v50\ncreated_at_utc=20260101T000000Z\n',
      'two format lines': 'format=warehouse-backup-v5\nformat=warehouse-backup-v5\n',
      'v60': 'format=warehouse-backup-v60\ncreated_at_utc=20260101T000000Z\n',
      'v5 then v6': 'format=warehouse-backup-v5\nformat=warehouse-backup-v6\n',
      'no format line': 'created_at_utc=20260101T000000Z\n',
    };
    for (const [name, body] of Object.entries(cases)) {
      writeFileSync(join(backup, 'metadata.txt'), body);
      const refused = verify(backup, scratch);
      assert.notEqual(refused.status, 0, name);
      assert.match(refused.stderr, /Refusing: backup format '.*' is no longer supported; take a new backup with this version \(only warehouse-backup-v5 and -v6 are accepted\)\./, name);
      assert.equal(refused.calls, '', name);
    }
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier sizes the disposable database from the dumps and can be overridden', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-size-'));
  const runLine = result => result.calls.split('\n').find(line => line.startsWith('run -d'));
  try {
    // A small backup keeps the earlier limits.
    const small = makeBackup(join(scratch, 'small'));
    let result = verify(small, scratch, { WAREHOUSE_VERIFY_STORAGE: 'tmpfs' });
    assert.equal(result.status, 0, result.stderr);
    assert.match(runLine(result), /--memory 1024m .*--tmpfs \/var\/lib\/postgresql\/data:rw,size=768m /);
    assert.ok(runLine(result).endsWith(readFileSync(new URL('../docker/postgres/Dockerfile', import.meta.url), 'utf8').match(/^FROM (postgres:\S+@sha256:[0-9a-f]{64})$/m)[1]), 'the image is the Dockerfile pin, by digest');
    // 1 MiB of dumps x 300 = 300 MiB of data, as much again for WAL, 256 MiB for the cluster.
    result = verify(small, scratch, { WAREHOUSE_VERIFY_STORAGE: 'tmpfs', WAREHOUSE_VERIFY_SIZE_FACTOR: '300' });
    assert.equal(result.status, 0, result.stderr);
    assert.match(runLine(result), /--memory 1112m .*size=856m /);
    assert.match(result.stdout, /disposable database of 856 MiB \(dumps of 1 MiB x 300/);
    result = verify(small, scratch, { WAREHOUSE_VERIFY_STORAGE: 'tmpfs', WAREHOUSE_VERIFY_DATA_MB: '900', WAREHOUSE_VERIFY_MEMORY_MB: '1500' });
    assert.equal(result.status, 0, result.stderr);
    assert.match(runLine(result), /--memory 1500m .*size=900m /);
    // A real size: 200 MiB of dumps need 2000 + 1024 + 256 MiB.
    const large = makeBackup(join(scratch, 'large'));
    truncateSync(join(large, 'database.dump'), 200 * 1024 * 1024 - 19);
    spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: large });
    signBackup(large);
    mkdirSync(join(scratch, 'disk'));
    result = verify(large, scratch, { WAREHOUSE_VERIFY_STORAGE: 'disk', WAREHOUSE_VERIFY_SCRATCH_DIR: join(scratch, 'disk'), FAKE_CATALOG_FILE: join(large, 'storage_objects.txt') });
    // Stated either as the plan or, on a machine without that much free space, as the refusal.
    assert.match(result.stdout + result.stderr, /3280 MiB (for the disposable database )?\(dumps of 200 MiB x 10, plus WAL and the empty cluster\)/);
    for (const value of ['0', 'abc', '-5']) {
      result = verify(small, scratch, { WAREHOUSE_VERIFY_DATA_MB: value });
      assert.notEqual(result.status, 0); assert.match(result.stderr, /WAREHOUSE_VERIFY_DATA_MB must be a positive whole number/); assert.equal(result.calls, '');
    }
    result = verify(small, scratch, { WAREHOUSE_VERIFY_STORAGE: 'nfs' });
    assert.notEqual(result.status, 0); assert.match(result.stderr, /must be auto, tmpfs or disk/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier falls back to a disk-backed data directory and removes it afterwards', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-disk-'));
  try {
    const backup = makeBackup(join(scratch, 'backup'));
    const parent = join(scratch, 'state'); mkdirSync(parent);
    const result = verify(backup, scratch, { WAREHOUSE_VERIFY_STORAGE: 'disk', WAREHOUSE_VERIFY_SCRATCH_DIR: parent });
    assert.equal(result.status, 0, result.stderr);
    const lines = result.calls.split('\n');
    const run = lines.find(line => line.startsWith('run -d'));
    assert.ok(!run.includes('--tmpfs'), run);
    const mount = run.match(/ -v (\S+)\/data:\/var\/lib\/postgresql\/data /);
    assert.ok(mount && mount[1].startsWith(`${parent}/.verify-restore.`), run);
    assert.match(run, /--network none --memory 1024m /);
    const removed = lines.findIndex(line => /^rm -f -v warehouse-restore-/.test(line));
    const emptied = lines.findIndex(line => line.startsWith(`run --rm --network none --user 0:0 --entrypoint /bin/rm -v ${mount[1]}:/scratch `) && line.endsWith(' -rf /scratch/data'));
    assert.ok(removed >= 0 && emptied > removed, 'the image removes the files its postgres user owns, after the container is gone');
    assert.deepEqual(readdirSync(parent), [], 'nothing is left in the scratch directory');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier names the numbers when the disposable database does not fit', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-nofit-'));
  try {
    const backup = makeBackup(join(scratch, 'backup'));
    const parent = join(scratch, 'state'); mkdirSync(parent);
    // 1 MiB x 100000000 cannot fit in memory anywhere, so auto goes to disk, where it cannot fit either.
    const huge = { WAREHOUSE_VERIFY_SIZE_FACTOR: '100000000' };
    let result = verify(backup, scratch, { ...huge, WAREHOUSE_VERIFY_SCRATCH_DIR: parent });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, new RegExp(`needs 100001280 MiB for the disposable database \\(dumps of 1 MiB x 100000000, plus WAL and the empty cluster\\) but only \\d+ MiB are free in ${parent}`));
    assert.equal(result.calls, '', 'no container is started');
    assert.deepEqual(readdirSync(parent), []);
    result = verify(backup, scratch, { ...huge, WAREHOUSE_VERIFY_STORAGE: 'tmpfs' });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /needs a 100001280 MiB in-memory database .* and 100001536 MiB of memory, but only \d+ MiB are available/);
    result = verify(backup, scratch, huge);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /no directory is set for a disk-backed run\. Set WAREHOUSE_STATE_DIR or WAREHOUSE_VERIFY_SCRATCH_DIR/);
    // The installed state is the default place for the disk-backed run.
    mkdirSync(join(parent, 'config')); writeKey(join(parent, 'config/backup.key'));
    result = verify(backup, scratch, { ...huge, WAREHOUSE_STATE_DIR: parent });
    assert.match(result.stderr, new RegExp(`MiB are free in ${parent}`));
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('a backup is authenticated before its SHA256SUMS is used: an unsigned or forged list cannot name files outside the backup', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-order-'));
  const sums = 'sha256sum storage.tar.gz database.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt';
  try {
    writeFileSync(join(scratch, 'outside.txt'), 'not part of any backup\n');
    // A signed backup whose list was rewritten to point outside: the signature fails first and the file is never opened.
    const forged = makeBackup(join(scratch, 'forged'));
    assert.equal(spawnSync('sh', ['-c', `{ ${sums}; printf '%s  ../absent-outside.txt\\n' "$(printf x | sha256sum | cut -d' ' -f1)"; } > SHA256SUMS`], { cwd: forged }).status, 0);
    let result = verify(forged, scratch);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /signature of this backup does not match the backup key/);
    assert.doesNotMatch(result.stderr, /absent-outside|does not match its SHA256SUMS/, 'sha256sum never ran on the unauthenticated list');
    assert.equal(result.calls, '');
    // A backup accepted with --allow-unsigned (key lost): the list may still name only files inside the backup.
    for (const [label, path] of [['parent', '../outside.txt'], ['absolute', join(scratch, 'outside.txt')]]) {
      const unsigned = makeBackup(join(scratch, `unsigned-${label}`), { key: null });
      assert.equal(spawnSync('sh', ['-c', `{ ${sums}; sha256sum "$1"; } > SHA256SUMS`, 'sh', path], { cwd: unsigned }).status, 0);
      assert.equal(spawnSync('sha256sum', ['-c', '--quiet', 'SHA256SUMS'], { cwd: unsigned }).status, 0, 'the plain checksums accept the outside file');
      result = verify(unsigned, scratch, { WAREHOUSE_BACKUP_KEY_FILE: join(scratch, 'absent.key') }, ['--allow-unsigned']);
      assert.notEqual(result.status, 0, label);
      assert.match(result.stderr, /SHA256SUMS names a path outside the backup/, label);
      assert.equal(result.calls, '', label);
    }
    // A damaged signed backup is still caught by its checksums, after the signature.
    const damaged = makeBackup(join(scratch, 'damaged'));
    writeFileSync(join(damaged, 'database.dump'), 'bit rot\n');
    result = verify(damaged, scratch);
    assert.notEqual(result.status, 0); assert.match(result.stderr, /does not match its SHA256SUMS/); assert.equal(result.calls, '');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

// Replaces the storage archive of a fixture backup with `tar ARGS` run in a tree of `count`
// long-named files, so that its listing is far larger than a pipe buffer, and signs it again.
function bigArchive(backup, scratch, count, prepare, tarArgs) {
  const tree = join(scratch, `tree-${count}-${readdirSync(scratch).length}`);
  mkdirSync(tree);
  const made = spawnSync('bash', ['-c', `set -e; cd "$1"; seq -f 'object-%06g-${'x'.repeat(60)}' 1 ${count} | xargs touch`, 'sh', tree], { encoding: 'utf8' });
  assert.equal(made.status, 0, made.stderr);
  prepare(tree);
  const tar = spawnSync('tar', ['--sort=name', '-C', tree, '-czf', join(backup, 'storage.tar.gz'), ...tarArgs, '.'], { encoding: 'utf8' });
  assert.equal(tar.status, 0, tar.stderr);
  assert.equal(spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: backup }).status, 0);
  signBackup(backup);
}

test('restore verifier finds a link or an escaping path that comes early in a long archive listing', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-early-'));
  try {
    // The link sorts first, followed by about 1.5 MB of listing: a check that stops reading
    // at the first match must not let the interrupted lister turn the answer into "safe".
    const linked = makeBackup(join(scratch, 'linked'));
    bigArchive(linked, scratch, 20000, tree => symlinkSync('/etc/passwd', join(tree, '000-link')), []);
    let result = verify(linked, scratch);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Storage archive contains a link/);
    assert.equal(result.calls, '', 'no container is started');
    const escaping = makeBackup(join(scratch, 'escaping'));
    bigArchive(escaping, scratch, 20000, tree => writeFileSync(join(tree, '000-first'), 'x'), ['-P', '--transform', 's,^\\./000-first$,../escape,']);
    assert.match(spawnSync('tar', ['-tzf', join(escaping, 'storage.tar.gz')], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }).stdout, /^\.\.\/escape$/m, 'the fixture archive holds the escaping path');
    result = verify(escaping, scratch);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Unsafe path in storage archive/);
    assert.equal(result.calls, '');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier lists the storage archive and never unpacks it', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-nounpack-'));
  try {
    const backup = makeBackup(join(scratch, 'backup'), { objects: ['documents/a.pdf/v1', 'dispatch-images/c1/photo.jpg/v7'] });
    const temp = join(scratch, 'tmp'); mkdirSync(temp);
    // A docker stand-in that records every file under TMPDIR at the moment the container starts.
    const real = fakeDocker(join(scratch, 'bin'));
    const wrap = join(scratch, 'wrap'); mkdirSync(wrap);
    writeFileSync(join(wrap, 'docker'), `#!/bin/sh\nif [ "$1" = run ]; then find "$TMPDIR" -type f > "$TMP_LISTING"; fi\nexec ${real}/docker "$@"\n`, { mode: 0o755 });
    const listing = join(scratch, 'tmp-listing.txt');
    const result = verify(backup, scratch, { PATH: `${wrap}:${process.env.PATH}`, TMPDIR: temp, TMP_LISTING: listing });
    assert.equal(result.status, 0, result.stderr);
    const files = readFileSync(listing, 'utf8');
    assert.match(files, /archive_files\.txt/, 'the listing was taken while the verifier was at work');
    assert.doesNotMatch(files, /a\.pdf|photo\.jpg/, 'no stored object was written to the temporary directory');
    assert.deepEqual(readdirSync(temp), [], 'the temporary directory is removed');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('backup refuses a database that is not this release\'s (an earlier major version or a role postgres), before any service is stopped', () => {
  for (const [label, server, reason] of [
    ['PostgreSQL 15', '15|true', /reports '15\|true'.*migrations-pre-baseline.*Baseline reload/s],
    ['PostgreSQL 17, this release runs 18', '17|true', /reports '17\|true'.*Major PostgreSQL upgrade/s],
    ['a role postgres', '18|false', /reports '18\|false'/],
  ]) {
    const scratch = mkdtempSync(join(tmpdir(), 'warehouse-backup-server-'));
    const state = join(scratch, 'state');
    const bin = join(scratch, 'bin');
    const log = join(scratch, 'docker.log');
    try {
      for (const path of [state, join(state, 'config'), join(state, 'public'), join(state, 'data'), join(state, 'data/db'), join(state, 'data/storage'), bin]) mkdirSync(path, { recursive: true, mode: 0o700 });
      writeFileSync(join(state, 'config/compose.env'), `WAREHOUSE_PROJECT_NAME=warehouse-backup-test\nWAREHOUSE_DB_PATH=${state}/data/db\nWAREHOUSE_STORAGE_PATH=${state}/data/storage\n`, { mode: 0o600 });
      writeFileSync(join(state, 'public/instance.json'), '{"schemaVersion":1}\n');
      writeFileSync(join(bin, 'docker'), `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  inspect) case "$3" in *State.Health.Status*) printf 'healthy\\n' ;; *State.Running*) printf 'true\\n' ;; esac ;;
  compose) case "$*" in
      *' ps -q db') printf 'bbbbbbbbbbbb\\n' ;;
      *' ps -q gateway') printf 'aaaaaaaaaaaa\\n' ;;
      *'exec -T db psql'*server_version_num*) printf '%s\\n' "$FAKE_SERVER" ;;
    esac ;;
esac
`, { mode: 0o700 });
      const destination = join(scratch, 'backup');
      const result = spawnSync('bash', [new URL('../scripts/backup.sh', import.meta.url).pathname, destination], {
        encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log, FAKE_SERVER: server },
      });
      assert.notEqual(result.status, 0, label);
      assert.match(result.stderr, reason, label);
      const calls = readFileSync(log, 'utf8');
      assert.doesNotMatch(calls, / stop | pg_dump /, `${label}: nothing was stopped or dumped`);
      assert.equal(existsSync(destination), false, label);
    } finally { rmSync(scratch, { recursive: true, force: true }); }
  }
});

const imageCheck = backup => spawnSync('bash', ['-c', 'source "$1"; backup_check_database_image "$2"', 'x', new URL('../scripts/backup-image.sh', import.meta.url).pathname, backup], { encoding: 'utf8' });

test('the image check: a repeated image line is damaged metadata, an older pin and a backup of the previous major are accepted, a newer major is refused, a listed earlier-image role refuses', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-backup-imagecheck-'));
  try {
    const twice = imageCheck(makeBackup(join(scratch, 'twice'), { imageLines: 2 }));
    assert.equal(twice.status, 1);
    assert.match(twice.stderr, /records 2 database_image= lines instead of one; the backup metadata is damaged/);
    assert.doesNotMatch(twice.stderr, /before the move to PostgreSQL 17/);
    const older = imageCheck(makeBackup(join(scratch, 'older'), { databaseImage: `postgres:18.1-trixie@sha256:${'a'.repeat(64)}` }));
    assert.equal(older.status, 0, 'a Dependabot bump of the pin does not strand earlier PostgreSQL 18 backups');
    for (const role of ['postgres', 'supabase_auth_admin', 'dashboard_user']) {
      const named = imageCheck(makeBackup(join(scratch, role), { roles: `anon\n${role}\nsupabase_admin\n` }));
      assert.equal(named.status, 1, role);
      assert.match(named.stderr, new RegExp(`lists the role '${role}'.*migrations-pre-baseline.*Baseline reload`, 's'), role);
    }
    assert.equal(imageCheck(makeBackup(join(scratch, 'plain'))).status, 0);
    // The pin is PostgreSQL 18: a backup of 17 (the previous major) restores, one of a newer major is refused by the upper bound.
    const previous = imageCheck(makeBackup(join(scratch, 'previous'), { databaseImage: `postgres:17.11-trixie@sha256:${'b'.repeat(64)}` }));
    assert.equal(previous.status, 0, previous.stderr);
    const odd = imageCheck(makeBackup(join(scratch, 'odd'), { databaseImage: `postgres:12345-trixie@sha256:${'d'.repeat(64)}` }));
    assert.equal(odd.status, 1);
    assert.match(odd.stderr, /whose PostgreSQL major version cannot be read/);
    const newer = imageCheck(makeBackup(join(scratch, 'newer'), { databaseImage: `postgres:19.1-trixie@sha256:${'c'.repeat(64)}` }));
    assert.equal(newer.status, 1);
    assert.match(newer.stderr, /Refusing: the backup was made on 'postgres:19\.1-trixie@sha256:[0-9a-f]{64}', a newer PostgreSQL major than the 18 this checkout runs/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('the ACL filter keeps ACL and DEFAULT ACL entries of a real table of contents and nothing else', () => {
  const restoreSh = readFileSync(new URL('../scripts/restore.sh', import.meta.url), 'utf8');
  const verifySh = readFileSync(new URL('../scripts/verify-restore.sh', import.meta.url), 'utf8');
  const program = restoreSh.match(/^acl_awk='(.*)'$/m)?.[1];
  assert.ok(program, 'restore.sh holds the filter');
  assert.equal(verifySh.match(/^acl_awk='(.*)'$/m)?.[1], program, 'verify-restore.sh uses the same filter');
  const listing = [
    ';',
    '; Archive created at 2026-10-20 10:00:00 UTC',
    ';     Dumped from database version: 18.6 (Debian 18.6-1.pgdg13+2)',
    ';',
    '3411; 1259 16400 TABLE public items supabase_admin',
    '3412; 1259 16410 TABLE public ACL supabase_admin',
    '4001; 0 0 ACL public items supabase_admin',
    '4002; 0 0 ACL public FUNCTION check_session() supabase_admin',
    '4003; 0 0 DEFAULT ACL public DEFAULT PRIVILEGES FOR TABLES supabase_admin',
    '4004; 0 0 ACL public COLUMN items.name supabase_admin',
    '4005; 0 0 COMMENT - EXTENSION pg_trgm',
    '4006; 0 0 ACL - SCHEMA public',
    '4007; 0 0 COMMENT public TABLE ACL supabase_admin',
  ].join('\n') + '\n';
  const kept = spawnSync('awk', [program], { input: listing, encoding: 'utf8' });
  assert.equal(kept.status, 0, kept.stderr);
  assert.deepEqual(kept.stdout.trim().split('\n').map(line => line.split(';')[0]), ['4001', '4002', '4003', '4004', '4006']);
});

test('restore verifier refuses a dump made by a server older than PostgreSQL 17 or newer than the pin, and an archive without privileges', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-dumped-from-'));
  try {
    const backup = makeBackup(join(scratch, 'backup'));
    const old = verify(backup, scratch, { FAKE_DUMP_VERSION: '15.8' });
    assert.notEqual(old.status, 0);
    assert.match(old.stderr, /made by PostgreSQL '15\.8', before PostgreSQL 17.*migrations-pre-baseline.*Baseline reload/s);
    assert.doesNotMatch(old.calls, /--section=pre-data/, 'nothing was restored');
    assert.equal(verify(backup, scratch, { FAKE_DUMP_VERSION: '17.11' }).status, 0, 'a dump of the previous major restores');
    assert.equal(verify(backup, scratch, { FAKE_DUMP_VERSION: '18.6' }).status, 0);
    const newer = verify(backup, scratch, { FAKE_DUMP_VERSION: '19.1' });
    assert.notEqual(newer.status, 0);
    assert.match(newer.stderr, /made by PostgreSQL '19\.1', a newer major than the 18 this checkout runs/);
    assert.doesNotMatch(newer.calls, /--section=pre-data/, 'nothing was restored');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

// The LAN fallback (gateway-lan) is the other way in to the API: the backup stops it with the gateway and starts it again apart (scripts/lan.sh start,
// where a fault of the fallback is a warning), and a gateway that is in maintenance mode (config/maintenance, scripts/maintenance.sh) is never recreated.
function lanBackupWorld() {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-backup-lan-'));
  const state = join(scratch, 'state');
  const bin = join(scratch, 'bin');
  const wrapper = join(scratch, 'wrapper');
  const log = join(scratch, 'docker.log');
  const envLog = join(scratch, 'env.log');
  for (const path of [state, join(state, 'config'), join(state, 'public'), join(state, 'data'), join(state, 'data/db'), join(state, 'data/storage'), bin, wrapper]) mkdirSync(path, { recursive: true, mode: 0o700 });
  writeFileSync(join(state, 'config/compose.env'), [`WAREHOUSE_PROJECT_NAME=warehouse-backup-test`, `WAREHOUSE_DB_PATH=${state}/data/db`, `WAREHOUSE_STORAGE_PATH=${state}/data/storage`,
    'LAN_ENABLED=true', 'LAN_BIND_IP=192.168.77.5', 'LAN_HTTP_PORT=8080', 'LAN_CIDR=192.168.77.0/24', 'COMPOSE_PROFILES=lan', ''].join('\n'), { mode: 0o600 });
  writeFileSync(join(state, 'public/instance.json'), '{"schemaVersion":1}\n');
  writeFileSync(join(state, 'data/storage/object'), 'object data');
  fakeBackupDocker(bin);
  // In front of the shared fake docker: gateway-lan is a running container of this project, and every call is logged with the WAREHOUSE_MAINTENANCE it saw.
  writeFileSync(join(wrapper, 'docker'), `#!/bin/sh
printf '%s|%s\\n' "\${WAREHOUSE_MAINTENANCE-unset}" "$*" >> "${envLog}"
case "$*" in
  *' ps -q gateway-lan') printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"; echo dddddddddddd; exit 0 ;;
  # Where the backup had got when the LAN fallback was started again: the manifest of the stored files is made after the services are back, and
  # the finished backup is moved into place last.
  *' up -d --no-deps --wait --wait-timeout 60 gateway-lan') m=before-manifest; ls "$FAKE_STAGE_PARENT"/.warehouse-backup-staging.*/storage.manifest >/dev/null 2>&1 && m=after-manifest; [ -e "$FAKE_DEST/metadata.txt" ] && m=backup-finished; printf 'LAN-UP %s\\n' "$m" >> "$FAKE_DOCKER_LOG" ;;
esac
exec "${join(bin, 'docker')}" "$@"
`, { mode: 0o700 });
  const env = { ...process.env, PATH: `${wrapper}:${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log, FAKE_STAGE_PARENT: scratch,
    WAREHOUSE_LAN_INTERFACES: JSON.stringify([{ name: 'ens33', address: '192.168.77.5', prefix: 24, defaultRoute: true }]) };
  delete env.COMPOSE_PROFILES; delete env.WAREHOUSE_MAINTENANCE;
  const run = (extra = {}, destination = join(scratch, 'backup')) => {
    writeFileSync(log, ''); writeFileSync(envLog, '');
    return spawnSync('bash', [new URL('../scripts/backup.sh', import.meta.url).pathname, destination], { encoding: 'utf8', env: { ...env, FAKE_DEST: destination, ...extra } });
  };
  const lines = () => readFileSync(log, 'utf8').split('\n').filter(Boolean);
  const at = pattern => lines().findIndex(line => pattern.test(line));
  return { scratch, state, run, lines, at, envCalls: () => readFileSync(envLog, 'utf8').split('\n').filter(Boolean), done: () => rmSync(scratch, { recursive: true, force: true }) };
}

test('backup stops gateway-lan before the other services and starts it again apart, after they are back; a failed backup starts it again too', () => {
  const w = lanBackupWorld();
  try {
    const result = w.run();
    assert.equal(result.status, 0, result.stderr);
    const lanStop = w.at(/--profile lan stop gateway-lan$/);
    const gatewayStop = w.at(/ stop gateway$/);
    const dump = w.at(/pg_dump/);
    const back = w.at(/up -d --no-recreate --no-deps --wait --wait-timeout 180 gateway/);
    const lanStart = w.at(/--profile lan up -d --no-deps --wait --wait-timeout 60 gateway-lan$/);
    assert.ok(lanStop >= 0 && gatewayStop >= 0 && dump >= 0 && back >= 0 && lanStart >= 0, w.lines().join('\n'));
    assert.ok(lanStop < gatewayStop, 'the LAN ingress is stopped first, with the gateway');
    assert.ok(gatewayStop < dump, 'both are stopped before the dump');
    assert.ok(dump < back && back < lanStart, 'the services come back, then the LAN fallback apart');
    assert.equal(w.lines().filter(line => /--profile lan stop gateway-lan$/.test(line)).length, 1);
    assert.equal(w.lines().filter(line => /--profile lan up -d .* gateway-lan$/.test(line)).length, 1, 'started once');
    assert.deepEqual(w.lines().filter(line => line.startsWith('LAN-UP')), ['LAN-UP before-manifest'], 'started as soon as the other services are back, not when the backup is finished');
    // The dump fails: the cleanup brings everything back, the LAN fallback too.
    const failed = w.run({ FAKE_DOCKER_FAIL: 'yes' }, join(w.scratch, 'failed-backup'));
    assert.notEqual(failed.status, 0);
    assert.ok(w.at(/--profile lan stop gateway-lan$/) < w.at(/pg_dump/));
    assert.ok(w.at(/up -d --no-recreate --no-deps --wait --wait-timeout 180 gateway/) < w.at(/--profile lan up -d --no-deps --wait --wait-timeout 60 gateway-lan$/), 'started again after a failure');
    assert.deepEqual(w.lines().filter(line => line.startsWith('LAN-UP')), ['LAN-UP before-manifest']);
  } finally { w.done(); }
});

test('backup with the LAN fallback off or its container not running does not touch gateway-lan, and a LAN fallback that will not start is a warning, not a failed backup', () => {
  const w = lanBackupWorld();
  try {
    // Off: nothing runs, so nothing is stopped or started (the same fake, without the container).
    writeFileSync(join(w.scratch, 'wrapper/docker'), `#!/bin/sh\nexec "${join(w.scratch, 'bin/docker')}" "$@"\n`, { mode: 0o700 });
    const off = w.run();
    assert.equal(off.status, 0, off.stderr);
    assert.equal(w.lines().some(line => /gateway-lan$/.test(line) && /\b(stop|up)\b/.test(line)), false, w.lines().join('\n'));
    // Running, and the host has lost the address (the router gave it another): lan.sh start says why and the backup is fine.
    writeFileSync(join(w.scratch, 'wrapper/docker'), `#!/bin/sh\ncase "$*" in *' ps -q gateway-lan') echo dddddddddddd; exit 0 ;; esac\nexec "${join(w.scratch, 'bin/docker')}" "$@"\n`, { mode: 0o700 });
    const moved = w.run({ WAREHOUSE_LAN_INTERFACES: JSON.stringify([{ name: 'ens33', address: '192.168.77.9', prefix: 24, defaultRoute: true }]) }, join(w.scratch, 'moved'));
    assert.equal(moved.status, 0, moved.stderr);
    assert.match(moved.stderr, /LAN fallback: this host no longer has 192\.168\.77\.5/);
    assert.equal(readFileSync(join(w.scratch, 'moved/database.dump'), 'utf8'), 'fake database dump\n');
  } finally { w.done(); }
});

test('backup never lifts maintenance mode: with the marker every Compose command it runs carries the word and none recreates a container; without it none does', () => {
  const w = lanBackupWorld();
  try {
    writeFileSync(join(w.state, 'config/maintenance'), 'upgrading\n', { mode: 0o600 });
    const closed = w.run();
    assert.equal(closed.status, 0, closed.stderr);
    const compose = w.envCalls().filter(line => /\|compose /.test(line) && / (up|stop) /.test(line));
    assert.ok(compose.length >= 4, `${compose.length} start/stop commands`);
    assert.deepEqual([...new Set(compose.map(line => line.split('|')[0]))], ['upgrading'], 'every one of them hands Compose the word');
    assert.equal(w.envCalls().some(line => /--force-recreate/.test(line)), false, 'nothing is recreated');
    rmSync(join(w.state, 'config/maintenance'));
    const open = w.run({}, join(w.scratch, 'open'));
    assert.equal(open.status, 0, open.stderr);
    assert.deepEqual([...new Set(w.envCalls().filter(line => /\|compose /.test(line)).map(line => line.split('|')[0]))], ['unset']);
  } finally { w.done(); }
});
