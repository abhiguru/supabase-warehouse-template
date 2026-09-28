import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
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

test('v4 restore verifier requires captured cluster globals before starting Docker', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-globals-test-'));
  try {
    writeFileSync(join(scratch, 'metadata.txt'), 'format=warehouse-backup-v4\n', { mode: 0o600 });
    const names = ['database.dump', 'storage.tar.gz', 'compose.env', 'instance.json', 'roles.txt', 'integrity.txt'];
    for (const name of names) {
      writeFileSync(join(scratch, name), 'fixture\n', { mode: 0o600 });
    }
    writeFileSync(join(scratch, 'SHA256SUMS'), [...names, 'metadata.txt'].map((name) =>
      `${createHash('sha256').update(readFileSync(join(scratch, name))).digest('hex')}  ${name}`).join('\n') + '\n', { mode: 0o600 });
    const result = spawnSync('bash', [new URL('../scripts/verify-restore.sh', import.meta.url).pathname, scratch], { encoding: 'utf8' });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /missing globals.sql/);
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
      *'up -d --no-recreate --wait --wait-timeout 180'*)
        if [ "$FAKE_RESTART_FAIL_ONCE" = yes ] && [ ! -e "$FAKE_RESTART_MARK" ]; then
          : > "$FAKE_RESTART_MARK"
          exit 42
        fi ;;
      *' ps -q db') printf 'bbbbbbbbbbbb\\n' ;;
      *' ps -q kong') printf 'aaaaaaaaaaaa\\n' ;;
      *' ps -q storage') printf 'cccccccccccc\\n' ;;
      *' ps -q '*) : ;;
      *'exec -T db pg_dumpall'*) if [ "$FAKE_GLOBALS_FAIL" = yes ]; then exit 43; fi; printf '%s\\n' '-- cluster globals' 'CREATE ROLE supabase_functions_admin;' ;;
      *'exec -T db pg_dump'*) if [ "$FAKE_DOCKER_FAIL" = yes ]; then exit 42; fi; printf 'fake database dump\\n' ;;
      *'exec -T db psql'*' -c SELECT rolname'*) printf 'postgres\\nsupabase_functions_admin\\n' ;;
      *'exec -T db psql'*) printf 'fake integrity\\n' ;;
    esac ;;
esac
`, { mode: 0o700 });
    const result = spawnSync('bash', [new URL('../scripts/backup.sh', import.meta.url).pathname, destination], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(join(destination, 'database.dump'), 'utf8'), 'fake database dump\n');
    assert.equal(readFileSync(join(destination, 'compose.env'), 'utf8').includes('WAREHOUSE_PROJECT_NAME='), true);
    assert.match(readFileSync(join(destination, 'metadata.txt'), 'utf8'), /format=warehouse-backup-v4/);
    assert.match(readFileSync(join(destination, 'roles.txt'), 'utf8'), /supabase_functions_admin/);
    assert.match(readFileSync(join(destination, 'globals.sql'), 'utf8'), /CREATE ROLE supabase_functions_admin/);
    assert.match(readFileSync(join(destination, 'SHA256SUMS'), 'utf8'), /globals\.sql/);
    const calls = readFileSync(log, 'utf8');
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
    writeFileSync(log, '');
    const globalsFailure = spawnSync('bash', [new URL('../scripts/backup.sh', import.meta.url).pathname, join(scratch, 'failed-globals')], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log, FAKE_GLOBALS_FAIL: 'yes' },
    });
    assert.notEqual(globalsFailure.status, 0);
    assert.equal(existsSync(join(scratch, 'failed-globals')), false);
    assert.match(readFileSync(log, 'utf8'), /up -d --no-recreate --wait --wait-timeout 180 kong/);
    writeFileSync(log, '');
    const retry = spawnSync('bash', [new URL('../scripts/backup.sh', import.meta.url).pathname, join(scratch, 'retry-backup')], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state,
        FAKE_DOCKER_LOG: log, FAKE_RESTART_FAIL_ONCE: 'yes', FAKE_RESTART_MARK: join(scratch, 'restart-failed-once') },
    });
    assert.equal(retry.status, 0, retry.stderr);
    assert.equal((readFileSync(log, 'utf8').match(/up -d --no-recreate --wait --wait-timeout 180 kong/g) ?? []).length, 2);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});
