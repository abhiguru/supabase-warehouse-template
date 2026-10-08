import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { makeBackup, fakeDocker } from './backup-test-helpers.mjs';
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
    assert.match(readFileSync(join(destination, 'metadata.txt'), 'utf8'), /format=warehouse-backup-v4/);
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
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifier requires the v4 catalog files before starting a container', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-backup-v4-'));
  try {
    const backup = makeBackup(join(scratch, 'backup'));
    rmSync(join(backup, '_supabase.dump'));
    const result = spawnSync('bash', [new URL('../scripts/verify-restore.sh', import.meta.url).pathname, backup], { encoding: 'utf8' });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /sha256sum|_supabase\.dump/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

function verify(backup, scratch, env = {}) {
  const log = join(scratch, 'docker.log');
  writeFileSync(log, '');
  const result = spawnSync('bash', [new URL('../scripts/verify-restore.sh', import.meta.url).pathname, backup], {
    encoding: 'utf8', env: { ...process.env, PATH: `${fakeDocker(join(scratch, 'bin'))}:${process.env.PATH}`, FAKE_DOCKER_LOG: log,
      FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), ...env },
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
