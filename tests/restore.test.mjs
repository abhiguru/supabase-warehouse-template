import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeBackup, makeState, fakeDocker, scriptRoot, composeEnv, instanceJson, signBackup } from './backup-test-helpers.mjs';

// Runs scripts/restore.sh from a private copy of the operator scripts against a
// fake docker; returns the result together with every docker invocation.
function restore(scratch, args, env = {}) {
  const log = join(scratch, 'docker.log');
  writeFileSync(log, '');
  const result = spawnSync('bash', [join(scriptRoot(scratch), 'scripts/restore.sh'), ...args], {
    encoding: 'utf8', env: { ...process.env, PATH: `${fakeDocker(join(scratch, 'bin'))}:${process.env.PATH}`,
      WAREHOUSE_STATE_DIR: join(scratch, 'state'), FAKE_DOCKER_LOG: log, ...env },
  });
  return { ...result, calls: readFileSync(log, 'utf8') };
}
function untouched(state) {
  assert.deepEqual(readdirSync(join(state, 'data')).sort(), ['db', 'storage'], 'no data directory was moved');
  assert.equal(readFileSync(join(state, 'data/db/PG_VERSION'), 'utf8'), '15\n');
}
function fixture(prefix, backupOptions = {}) {
  const scratch = mkdtempSync(join(tmpdir(), prefix));
  const state = makeState(scratch);
  const backup = makeBackup(join(scratch, 'backup'), { env: composeEnv(state), ...backupOptions });
  return { scratch, state, backup };
}

test('restore refuses without --yes before locking, touching data or calling docker', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-yes-');
  try {
    const result = restore(scratch, [backup]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Pass --yes/);
    assert.equal(result.calls, '', 'docker is never invoked');
    assert.equal(existsSync(join(state, 'config/operator.lock')), false);
    untouched(state);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore refuses while operator services are running', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-running-');
  try {
    const result = restore(scratch, ['--yes', backup], { FAKE_RUNNING: 'yes' });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /services are running.*stop\.sh/);
    assert.doesNotMatch(result.calls, /run |up -d| cp /, 'nothing is started, copied or restored');
    untouched(state);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore refuses a v3 backup', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-v3-', { format: 'warehouse-backup-v3' });
  try {
    let result = restore(scratch, ['--yes', backup]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /carries no signature/);
    assert.doesNotMatch(result.calls, /run |up -d| cp /);
    result = restore(scratch, ['--yes', '--allow-unsigned', backup]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /requires format=warehouse-backup-v5.*warehouse-backup-v3/);
    assert.doesNotMatch(result.calls, /run |up -d| cp /);
    untouched(state);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore refuses a backup of another instance', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-instance-', { instance: instanceJson.replace('0f0f0f0f-', 'aaaaaaaa-') });
  try {
    const result = restore(scratch, ['--yes', backup]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /instance\.json differs/);
    assert.doesNotMatch(result.calls, /run |up -d| cp /);
    untouched(state);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore refuses a changed configuration unless --restore-config names the same paths', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-config-', { env: composeEnv(join(tmpdir(), 'state'), 'JWT_SECRET=old-secret\n') });
  try {
    const rotated = makeBackup(join(scratch, 'rotated'), { env: composeEnv(state, 'JWT_SECRET=old-secret\n') });
    const refused = restore(scratch, ['--yes', rotated]);
    assert.notEqual(refused.status, 0);
    assert.match(refused.stderr, /compose\.env differs.*--restore-config/);
    const moved = restore(scratch, ['--yes', '--restore-config', backup]);
    assert.notEqual(moved.status, 0);
    assert.match(moved.stderr, /WAREHOUSE_DB_PATH in the backup configuration differs/);
    assert.doesNotMatch(refused.calls + moved.calls, /run |up -d| cp /);
    untouched(state);
    assert.equal(readFileSync(join(state, 'config/compose.env'), 'utf8'), composeEnv(state));
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore verifies first, keeps the replaced data, replays both databases in order and reports rollback on failure', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-flow-', { env: composeEnv(join(tmpdir(), 'x'), 'JWT_SECRET=old-secret\n').replace(join(tmpdir(), 'x'), '') });
  try {
    // Backup configuration names this state but carries pre-rotation keys.
    writeFileSync(join(backup, 'compose.env'), composeEnv(state, 'JWT_SECRET=old-secret\n'), { mode: 0o600 });
    const sums = spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump _supabase.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: backup, encoding: 'utf8' });
    assert.equal(sums.status, 0, sums.stderr);
    signBackup(backup);
    const result = restore(scratch, ['--yes', '--restore-config', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), FAKE_FAIL_START: 'yes' });
    assert.notEqual(result.status, 0, 'the injected start failure propagates');
    assert.match(result.stderr, /Restore failed during: (migrations|start services)/);
    assert.match(result.stderr, /Rollback: bash stop\.sh/);
    const entries = readdirSync(join(state, 'data')).sort();
    const keptDb = entries.find(name => /^db\.pre-restore-\d{8}T\d{6}Z$/.test(name));
    const keptStorage = entries.find(name => /^storage\.pre-restore-\d{8}T\d{6}Z$/.test(name));
    assert.ok(keptDb && keptStorage, `pre-restore directories kept: ${entries}`);
    assert.ok(result.stderr.includes(join(state, 'data', keptDb)) && result.stderr.includes(join(state, 'data', keptStorage)));
    assert.equal(readFileSync(join(state, 'data', keptDb, 'PG_VERSION'), 'utf8'), '15\n');
    assert.equal(readFileSync(join(state, 'data', keptStorage, 'current-object'), 'utf8'), 'current object data');
    assert.deepEqual(readdirSync(join(state, 'data/db')), [], 'fresh database directory for initialization');
    assert.equal((statSync(join(state, 'data/db')).mode & 0o777), 0o700);
    assert.equal(readFileSync(join(state, 'data/storage/stub/stub/documents/a.pdf/v1'), 'utf8'), 'bytes of stub/stub/documents/a.pdf/v1');
    assert.equal(readFileSync(join(state, 'config/compose.env'), 'utf8'), composeEnv(state, 'JWT_SECRET=old-secret\n'), 'backup configuration restored');
    const keptConfig = readdirSync(join(state, 'config')).find(name => /^compose\.env\.pre-restore-/.test(name));
    assert.ok(keptConfig && (statSync(join(state, 'config', keptConfig)).mode & 0o777) === 0o600);
    assert.equal(readFileSync(join(state, 'config', keptConfig), 'utf8'), composeEnv(state));
    const calls = result.calls;
    const at = needle => { const index = calls.indexOf(needle); assert.ok(index >= 0, `docker call missing: ${needle}`); return index; };
    const order = [
      'run -d --pull missing', // disposable verification first
      'up -d --wait --wait-timeout 180 db',
      'db:/tmp/database.dump', 'db:/tmp/_supabase.dump',
      'DROP DATABASE postgres WITH (FORCE)',
      '-d postgres --no-acl --section=pre-data -L /tmp/main.list', '-d postgres --no-acl --section=data -L /tmp/main.list',
      '-d postgres --no-acl --section=post-data -L /tmp/main.list',
      '-d postgres --no-owner --no-acl -L /tmp/triggers.list', // event triggers owned by the restoring superuser
      '-d postgres -L /tmp/acl.list',
      'DROP DATABASE _supabase WITH (FORCE)', '-d _supabase /tmp/_supabase.dump',
      'rm -f /tmp/database.dump /tmp/_supabase.dump /tmp/acl.list /tmp/full.list /tmp/main.list /tmp/triggers.list',
    ];
    for (let i = 1; i < order.length; i++) assert.ok(at(order[i - 1]) < at(order[i]), `${order[i - 1]} precedes ${order[i]}`);
    const sections = calls.split('\n').filter(line => line.includes('pg_restore') && line.includes('-d postgres') && line.includes('--section='));
    assert.equal(sections.length, 3);
    assert.ok(sections.every(line => line.includes('--exit-on-error') && !line.includes('--no-owner')), 'in-place replay keeps owners');
    const removed = calls.search(/^rm -f warehouse-restore-[0-9a-f]{12}$/m);
    assert.ok(removed >= 0 && removed < at('up -d --wait --wait-timeout 180 db'), 'verification container removed before initialization');
    assert.ok(calls.split('\n').filter(line => line.endsWith('up -d --wait --wait-timeout 180')).length <= 1);
    // Both databases are recreated from template0: a session on template1 right after start-up must not fail the restore.
    const recreated = calls.split('\n').filter(line => line.includes('CREATE DATABASE'));
    assert.equal(recreated.length, 2);
    for (const line of recreated) assert.match(line, /CREATE DATABASE (postgres|_supabase) OWNER postgres TEMPLATE template0$/, line);
    assert.doesNotMatch(calls, /template1/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore refuses a backup that is not signed with the key of this installation, before stopping or moving anything', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-signature-');
  try {
    // Edited and re-checksummed by someone without the key.
    writeFileSync(join(backup, 'database.dump'), 'planted dump\n');
    spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump _supabase.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: backup });
    let result = restore(scratch, ['--yes', backup]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /signature of this backup does not match the backup key/);
    assert.doesNotMatch(result.calls, /run |up -d| cp /);
    result = restore(scratch, ['--yes', '--allow-unsigned', backup]);
    assert.notEqual(result.status, 0, 'a wrong signature is refused even with --allow-unsigned');
    untouched(state);
    // Signed by another installation's key.
    const foreign = makeBackup(join(scratch, 'foreign'), { env: composeEnv(state), key: '77'.repeat(32) });
    result = restore(scratch, ['--yes', foreign]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /does not match the backup key/);
    // The state lost its key: a signed backup cannot be checked, so it is refused.
    signBackup(backup);
    rmSync(join(state, 'config/backup.key'));
    result = restore(scratch, ['--yes', backup]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /no backup key is available/);
    assert.doesNotMatch(result.calls, /run |up -d| cp /);
    untouched(state);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore takes an unsigned v4 backup only with --allow-unsigned and tells the verifier', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-v4-', { format: 'warehouse-backup-v4' });
  try {
    let result = restore(scratch, ['--yes', backup]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /carries no signature[\s\S]*--allow-unsigned/);
    assert.doesNotMatch(result.calls, /run |up -d| cp /);
    untouched(state);
    result = restore(scratch, ['--yes', '--allow-unsigned', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), FAKE_FAIL_START: 'yes' });
    assert.match(result.stderr, /WARNING: this backup carries no signature/);
    assert.match(result.calls, /^run -d --pull missing/m, 'the verifier ran');
    assert.match(result.calls, /DROP DATABASE postgres WITH \(FORCE\)/, 'and the replay started');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});
