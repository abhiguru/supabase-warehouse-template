import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, statSync, truncateSync } from 'node:fs';
import { makeBackup, fakeDocker, backupKey, signBackup, writeKey, hmacHex } from './backup-test-helpers.mjs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

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
    writeFileSync(join(backup, 'metadata.txt'), 'format=warehouse-backup-v2\n');
    const result = spawnSync('bash', [new URL('../scripts/verify-restore.sh', import.meta.url).pathname, backup], { encoding: 'utf8' });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Incomplete backup/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
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
    writeFileSync(join(bin, 'docker'), `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  ps) exit 0 ;;
  inspect)
    case "$3" in
      *State.Health.Status*) printf 'healthy\\n' ;;
      *State.Running*) printf 'true\\n' ;;
    esac ;;
  compose)
    case "$*" in
      *' ps -q db') printf 'bbbbbbbbbbbb\\n' ;;
      *' ps -q kong') printf 'aaaaaaaaaaaa\\n' ;;
      *' ps -q storage') printf 'cccccccccccc\\n' ;;
      *' ps -q '*) : ;;
      *'exec -T db pg_dump'*' -d _supabase '*) printf 'fake supabase dump\\n' ;;
      *'exec -T db pg_dump'*) if [ "$FAKE_DOCKER_FAIL" = yes ]; then exit 42; fi; printf 'fake database dump\\n' ;;
      *'exec -T db psql'*' -c SELECT rolname'*) printf 'postgres\\nsupabase_functions_admin\\n' ;;
      *'exec -T db psql'*'storage.objects'*) printf 'documents/a.pdf/v1\\n' ;;
      *'exec -T db psql'*) printf 'fake integrity\\n' ;;
    esac ;;
esac
`, { mode: 0o700 });
    const result = spawnSync('bash', [new URL('../scripts/backup.sh', import.meta.url).pathname, destination], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(join(destination, 'database.dump'), 'utf8'), 'fake database dump\n');
    assert.equal(readFileSync(join(destination, '_supabase.dump'), 'utf8'), 'fake supabase dump\n');
    assert.equal(readFileSync(join(destination, 'storage_objects.txt'), 'utf8'), 'documents/a.pdf/v1\n');
    assert.equal(readFileSync(join(destination, 'compose.env'), 'utf8').includes('WAREHOUSE_PROJECT_NAME='), true);
    assert.match(readFileSync(join(destination, 'metadata.txt'), 'utf8'), /format=warehouse-backup-v5/);
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
    assert.match(readFileSync(join(destination, 'roles.txt'), 'utf8'), /supabase_functions_admin/);
    const sums = readFileSync(join(destination, 'SHA256SUMS'), 'utf8');
    for (const file of ['database.dump', '_supabase.dump', 'storage.tar.gz', 'storage_objects.txt', 'integrity.txt', 'metadata.txt', 'compose.env', 'instance.json', 'roles.txt'])
      assert.match(sums, new RegExp(`^[0-9a-f]{64}  ${file.replace('.', '\\.')}$`, 'm'), `${file} is checksummed`);
    assert.equal(spawnSync('sha256sum', ['-c', '--quiet', 'SHA256SUMS'], { cwd: destination, encoding: 'utf8' }).status, 0, 'SHA256SUMS verifies');
    assert.match(result.stderr, /shares a filesystem with .*\/data/, 'same-filesystem destination warns');
    const calls = readFileSync(log, 'utf8');
    const mainDump = calls.split('\n').find(line => line.includes('pg_dump') && line.includes('-d postgres'));
    assert.ok(mainDump && !mainDump.includes('--no-owner'), 'main dump keeps owners for in-place restore');
    assert.ok(calls.split('\n').some(line => line.includes('pg_dump') && line.includes('-d _supabase') && line.includes('--format=custom')));
    assert.ok(calls.indexOf('stop kong') < calls.indexOf('-d _supabase'));
    assert.ok(calls.indexOf('-d _supabase') < calls.indexOf('up -d --no-recreate --wait --wait-timeout 180 kong'));
    assert.ok(calls.indexOf('stop kong') < calls.indexOf('pg_dump'));
    assert.ok(calls.indexOf('stop auth') < calls.indexOf('pg_dump'));
    assert.ok(calls.indexOf('stop supavisor') < calls.indexOf('pg_dump'));
    assert.ok(calls.indexOf('pg_dump') < calls.indexOf('up -d --no-recreate --wait --wait-timeout 180 kong'));
    assert.match(calls, /up -d --no-recreate --wait --wait-timeout 180 kong/);
    assert.equal(existsSync(join(destination, 'storage.tar.gz')), true);
    writeFileSync(log, '');
    const failed = spawnSync('bash', [new URL('../scripts/backup.sh', import.meta.url).pathname, join(scratch, 'failed-backup')], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log, FAKE_DOCKER_FAIL: 'yes' },
    });
    assert.notEqual(failed.status, 0);
    assert.equal(existsSync(join(scratch, 'failed-backup')), false);
    const failureCalls = readFileSync(log, 'utf8');
    assert.ok(failureCalls.indexOf('pg_dump') < failureCalls.indexOf('up -d --no-recreate --wait --wait-timeout 180 kong'));
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
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier requires the v4 catalog files before starting a container', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-backup-v4-'));
  try {
    const backup = makeBackup(join(scratch, 'backup'));
    rmSync(join(backup, '_supabase.dump'));
    // The signature is checked before the checksums, so the verifier needs the key to get as far as the file set.
    const result = verify(backup, scratch);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /not exactly the files its signed SHA256SUMS lists|_supabase\.dump/);
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

test('restore verifier replays both databases in isolation and matches the object catalog', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-v4-'));
  try {
    const backup = makeBackup(join(scratch, 'backup'), { objects: ['documents/a.pdf/v1', 'customer-images/c1/photo.jpg/v7'] });
    const result = verify(backup, scratch);
    assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(result.stderr, /Warning/);
    const lines = result.calls.split('\n');
    const run = lines.find(line => line.startsWith('run '));
    assert.ok(run.includes('--network none') && run.includes('--tmpfs /var/lib/postgresql/data'), 'disposable container stays isolated');
    const main = lines.filter(line => line.includes('pg_restore') && line.includes('-d warehouse_restore'));
    assert.equal(main.length, 4, 'three sections plus the ACL replay');
    assert.ok(main.every(line => line.includes('--no-owner') && line.includes('--exit-on-error')));
    const supabase = lines.find(line => line.includes('pg_restore') && line.includes('-d _supabase_restore'));
    assert.ok(supabase && supabase.includes('--exit-on-error') && supabase.includes('/tmp/_supabase.dump'));
    assert.ok(lines.some(line => line.includes('createdb') && line.includes('_supabase_restore')));
    assert.ok(lines.some(line => line.includes('-d warehouse_restore') && line.includes('storage.objects')), 'restored catalog is read back');
    assert.match(result.stdout, /integrity comparison passed/);
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
  const resum = backup => { spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump _supabase.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt tunnel/* > SHA256SUMS'], { cwd: backup }); signBackup(backup); };
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
    const unlistedV4 = makeBackup(join(scratch, 'unlisted-v4'), { format: 'warehouse-backup-v4' });
    mkdirSync(join(unlistedV4, 'tunnel'));
    writeFileSync(join(unlistedV4, 'tunnel/token'), 'abc\n');
    const missingSumV4 = verify(unlistedV4, scratch, {}, ['--allow-unsigned']);
    assert.notEqual(missingSumV4.status, 0);
    assert.match(missingSumV4.stderr, /checksum missing for tunnel\/token/);

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

test('restore verifier creates both disposable databases from template0, never template1', () => {
  // CI run fe19442: createdb -T template1 failed with "source database template1 is being accessed by other users".
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-template-'));
  try {
    const result = verify(makeBackup(join(scratch, 'backup')), scratch);
    assert.equal(result.status, 0, result.stderr);
    const created = result.calls.split('\n').filter(line => / createdb /.test(line));
    assert.equal(created.length, 2, 'warehouse_restore and _supabase_restore');
    for (const line of created) assert.match(line, / -T template0 (warehouse_restore|_supabase_restore)$/, line);
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
    assert.equal(readFileSync(join(scratch, 'diagnostics', dir, 'container.log'), 'utf8'), 'fake container log line\n');
    assert.match(readFileSync(join(scratch, 'diagnostics', dir, 'pg_stat_activity.txt'), 'utf8'), /client backend\|template1/);
    assert.equal(statSync(join(scratch, 'diagnostics', dir)).mode & 0o777, 0o700);
    assert.match(result.stderr, new RegExp(`were saved in ${join(scratch, 'diagnostics', dir)}`));
    assert.match(result.stderr, /41\|client backend\|template1\|idle/, 'the session list is printed for a CI log');
    const lines = result.calls.split('\n');
    const removed = lines.findIndex(line => /^rm -f warehouse-restore-/.test(line));
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
    spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump _supabase.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: edited });
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

test('restore verifier takes an unsigned v4 backup only with --allow-unsigned and says so loudly', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-v4-unsigned-'));
  try {
    const backup = makeBackup(join(scratch, 'backup'), { format: 'warehouse-backup-v4' });
    const refused = verify(backup, scratch);
    assert.notEqual(refused.status, 0);
    assert.match(refused.stderr, /carries no signature[\s\S]*--allow-unsigned/);
    assert.equal(refused.calls, '');
    const allowed = verify(backup, scratch, {}, ['--allow-unsigned']);
    assert.equal(allowed.status, 0, allowed.stderr);
    assert.match(allowed.stderr, /WARNING: this backup carries no signature[\s\S]*WITHOUT proof/);
    assert.match(allowed.stdout, /UNSIGNED/);
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
    assert.match(runLine(result), /supabase\/postgres:15\.8\.1\.060@sha256:[0-9a-f]{64}$/, 'the image is pinned by digest');
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
    spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump _supabase.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: large });
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
    const removed = lines.findIndex(line => /^rm -f warehouse-restore-/.test(line));
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
  const sums = 'sha256sum storage.tar.gz database.dump _supabase.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt';
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
    // An unsigned backup accepted with --allow-unsigned: the list may still name only files inside the backup.
    for (const [label, path] of [['parent', '../outside.txt'], ['absolute', join(scratch, 'outside.txt')]]) {
      const unsigned = makeBackup(join(scratch, `unsigned-${label}`), { format: 'warehouse-backup-v4' });
      assert.equal(spawnSync('sh', ['-c', `{ ${sums}; sha256sum "$1"; } > SHA256SUMS`, 'sh', path], { cwd: unsigned }).status, 0);
      assert.equal(spawnSync('sha256sum', ['-c', '--quiet', 'SHA256SUMS'], { cwd: unsigned }).status, 0, 'the plain checksums accept the outside file');
      result = verify(unsigned, scratch, {}, ['--allow-unsigned']);
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
