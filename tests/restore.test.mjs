import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeBackup, makeState, fakeDocker, scriptRoot, composeEnv, dbRoleLines, poolerOnLines, legacyPoolerLines, previousReleaseDbLines, instanceJson, signBackup, currentDatabaseImage, fixtureMigrations, ledgerText, defaultIntegrity as defaultIntegrityLines } from './backup-test-helpers.mjs';
import { scramVerifier } from '../scripts/db-roles.mjs';
import { readEnv } from '../scripts/doctor-common.mjs';

// Runs scripts/restore.sh from a private copy of the operator scripts against a
// fake docker; returns the result together with every docker invocation.
// `prepare` may change the private copy of the scripts before the run.
function restore(scratch, args, env = {}, prepare = () => {}) {
  const log = join(scratch, 'docker.log');
  writeFileSync(log, '');
  const root = scriptRoot(scratch);
  prepare(root);
  const result = spawnSync('bash', [join(root, 'scripts/restore.sh'), ...args], {
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

test('restore refuses a v4 backup, with or without --allow-unsigned', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-v4-', { format: 'warehouse-backup-v4' });
  try {
    for (const args of [['--yes', backup], ['--yes', '--allow-unsigned', backup]]) {
      const result = restore(scratch, args);
      assert.notEqual(result.status, 0, args.join(' '));
      assert.match(result.stderr, /backup format 'warehouse-backup-v4' is no longer supported; take a new backup with this version \(only warehouse-backup-v5 and -v6 are accepted\)\./);
      assert.doesNotMatch(result.calls, /run |up -d| cp /);
      assert.equal(result.calls, '', 'no container call at all');
      assert.equal(existsSync(join(state, 'config/operator.lock')), false, 'no lock was taken');
      untouched(state);
    }
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

// Identity, not bytes (scripts/instance-identity.mjs): what changed in the manifest since the backup (a capability switched on,
// the minimum app version that older releases kept there, the display name) does not stop a restore; another facility's does.
const manifest = (changes = {}) => JSON.stringify({ schemaVersion: 1, instanceId: '0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f', displayName: 'Acme', companyName: 'Acme Cold',
  canonicalOrigin: 'https://api.example.test', capabilities: { sensors: false, printing: false }, supportedApiVersions: ['1'], minimumClientVersion: '0.1.0', ...changes }, null, 2) + '\n';
function restoreWithManifests(prefix, backupManifest, stateManifest) {
  const { scratch, state, backup } = fixture(prefix, { instance: backupManifest });
  writeFileSync(join(state, 'public/instance.json'), stateManifest);
  try {
    const result = restore(scratch, ['--yes', backup]);
    if (result.status !== 0) untouched(state);
    return result;
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}
test('restore goes past the instance check when the manifests differ only outside the identity', () => {
  for (const [what, changes] of [['minimumClientVersion', { minimumClientVersion: '0.4.0' }], ['capabilities', { capabilities: { sensors: true, printing: false } }],
    ['supportedApiVersions and displayName', { supportedApiVersions: ['1', '2'], displayName: 'Acme Renamed' }]]) {
    const result = restoreWithManifests('warehouse-restore-identity-ok-', manifest(changes), manifest());
    assert.doesNotMatch(result.stderr, /instance\.json/, `${what}: not refused for the manifest`);
  }
});
test('restore refuses another instanceId, canonicalOrigin or companyName, naming the field, before moving anything', () => {
  for (const [field, changes] of [['instanceId', { instanceId: 'aaaaaaaa-0f0f-4f0f-8f0f-0f0f0f0f0f0f' }], ['canonicalOrigin', { canonicalOrigin: 'https://other.example.test' }], ['companyName', { companyName: 'Other Cold' }]]) {
    const result = restoreWithManifests('warehouse-restore-identity-bad-', manifest(changes), manifest());
    assert.notEqual(result.status, 0, field);
    assert.match(result.stderr, new RegExp(`instance\\.json differs from this state in its identity \\(${field}\\)`), field);
    assert.doesNotMatch(result.calls, /run |up -d| cp /, field);
  }
  // A manifest that is not JSON is refused too, not treated as equal.
  const result = restoreWithManifests('warehouse-restore-identity-junk-', manifest(), 'not json');
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /cannot be read as an instance manifest/);
});

// The way back from an upgrade is this command after the old release is checked out: a checkout whose migrations are fewer than the
// backup's, or differ from them, must be refused while nothing has been moved (the database is dropped well before migrate.sh would notice).
test('restore refuses, before moving anything, a backup that applied a migration this checkout lacks, or one this checkout has with other contents, or one that records no ledger', () => {
  const ledger = (count, fingerprint) => `fake integrity\nmigration_count=${count}\nmigration_fingerprint=${fingerprint}\n`;
  const cases = [
    ['a migration the checkout lacks', ledgerText({ ...fixtureMigrations, '0003_third.sql': 'select 3;\n' }), /Refusing: the backup has 3 migrations and this checkout only 2\. Check out a release at least as new as the backup \(metadata\.txt source_commit=/],
    ['a migration with other contents', ledgerText({ '0001_first.sql': 'select 1;\n', '0002_second.sql': 'select 22;\n' }), /Refusing: the migrations this backup applied differ from this checkout\. Check out the release the backup was made with/],
    ['a fingerprint that is not one', ledger(2, 'not-a-fingerprint'), /The backup integrity report records no migration ledger\./],
    ['no ledger at all', 'fake integrity\n', /The backup integrity report records no migration ledger\./],
  ];
  for (const [what, integrity, pattern] of cases) {
    const { scratch, state, backup } = fixture('warehouse-restore-ledger-', { integrity });
    try {
      const result = restore(scratch, ['--yes', backup]);
      assert.notEqual(result.status, 0, what);
      assert.match(result.stderr, pattern, what);
      assert.doesNotMatch(result.calls, /run |up -d| cp |createdb|pg_restore|DROP DATABASE/, `${what}: no restore was started`);
      untouched(state);
      assert.equal(readFileSync(join(state, 'config/compose.env'), 'utf8'), composeEnv(state), `${what}: the configuration is untouched`);
      assert.deepEqual(readdirSync(join(state, 'config')).filter(name => name.includes('pre-restore')), [], `${what}: nothing was set aside`);
    } finally { rmSync(scratch, { recursive: true, force: true }); }
  }
  // The same checkout with the matching ledger gets past this check (it stops later, at the instance, for a reason of its own).
  const { scratch, backup } = fixture('warehouse-restore-ledger-ok-', { instance: instanceJson.replace('0f0f0f0f-', 'aaaaaaaa-') });
  try {
    const result = restore(scratch, ['--yes', backup]);
    assert.match(result.stderr, /instance\.json differs/, 'a backup whose ledger matches goes on to the next check');
    assert.doesNotMatch(result.stderr, /migrations/);
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

test('restore verifies first, keeps the replaced data, replays the database in order and reports rollback on failure', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-flow-', { env: composeEnv(join(tmpdir(), 'x'), 'JWT_SECRET=old-secret\n').replace(join(tmpdir(), 'x'), '') });
  try {
    // Backup configuration names this state but carries pre-rotation keys.
    writeFileSync(join(backup, 'compose.env'), composeEnv(state, 'JWT_SECRET=old-secret\n'), { mode: 0o600 });
    const sums = spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: backup, encoding: 'utf8' });
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
      // A leading space: the verification container is warehouse-restore-<12 random hex digits>, whose name can end in "db".
      ' db:/tmp/database.dump',
      'DROP DATABASE postgres WITH (FORCE)',
      '-d postgres --no-acl --section=pre-data', '-d postgres --no-acl --section=data',
      '-d postgres --no-acl --section=post-data',
      '-d postgres -L /tmp/acl.list',
      'rm -f /tmp/database.dump /tmp/acl.list',
      // pg_dump 18 carries no planner statistics: every restored database is analyzed before the services start.
      'exec -T db vacuumdb -U supabase_admin --all --analyze-in-stages',
    ];
    for (let i = 1; i < order.length; i++) assert.ok(at(order[i - 1]) < at(order[i]), `${order[i - 1]} precedes ${order[i]}`);
    const source = readFileSync(new URL('../scripts/restore.sh', import.meta.url), 'utf8');
    assert.ok(source.indexOf('vacuumdb') > source.indexOf("phase='restore database'") && source.indexOf('vacuumdb') < source.indexOf("phase='start services'"), 'ANALYZE runs after the data restore and before the services start');
    assert.equal(calls.split('\n').filter(line => line.includes('vacuumdb')).length, 1);
    const sections = calls.split('\n').filter(line => line.includes('pg_restore') && line.includes('-d postgres') && line.includes('--section='));
    assert.equal(sections.length, 3);
    assert.ok(sections.every(line => line.includes('--exit-on-error') && !line.includes('--no-owner')), 'in-place replay keeps owners');
    const removed = calls.search(/^rm -f -v warehouse-restore-[0-9a-f]{12}$/m);
    assert.ok(removed >= 0 && removed < at('up -d --wait --wait-timeout 180 db'), 'verification container removed before initialization');
    assert.ok(calls.split('\n').filter(line => line.endsWith('up -d --wait --wait-timeout 180')).length <= 1);
    // The application database is recreated from template0 (connected to template1, as no _supabase database exists any more
    // before the pooler is turned on): a session on template1 right after start-up must not fail the restore.
    const recreated = calls.split('\n').filter(line => line.includes('CREATE DATABASE'));
    assert.equal(recreated.length, 1);
    assert.match(recreated[0], /CREATE DATABASE postgres OWNER supabase_admin TEMPLATE template0$/);
    assert.match(recreated[0], /-d template1 /);
    assert.equal(calls.includes('_supabase'), false, 'the pooler database is neither restored nor connected to');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

// restore.sh initialises the new cluster with the db image of this checkout: a stale image (the previous PostgreSQL major)
// is rebuilt before anything is moved, and the restore stops with the data untouched when it cannot be.
function staleDbImage(scratch) {
  const config = join(scratch, 'compose-config.json');
  writeFileSync(config, JSON.stringify({ name: 'warehouse-backup-test', services: { db: { build: { context: join(scratch, 'root/docker/postgres') } } } }));
  return { FAKE_COMPOSE_CONFIG: config, FAKE_BUILT_MARK: join(scratch, 'db-built.mark'), FAKE_FAIL_START: 'yes' };
}

test('restore rebuilds a stale db image before moving any data, then initialises the new cluster', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-stale-build-');
  try {
    const result = restore(scratch, ['--yes', backup], { ...staleDbImage(scratch), FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt') });
    assert.match(result.stdout, /db image does not match this checkout/);
    // The rebuild goes through --from-release (a restore at a release tag pulls the release's images as setup does); the fixture checkout is
    // at no tag, so build-images.sh says it builds here.
    assert.match(result.stdout, /Not pulling release images: this checkout is not at a release tag/);
    const calls = result.calls.split('\n');
    const build = calls.findIndex(line => / build /.test(line) && /\bdb$/.test(line));
    const init = calls.findIndex(line => line.endsWith('up -d --wait --wait-timeout 180 db'));
    assert.ok(build >= 0, `the db image was built: ${result.calls}`);
    assert.ok(init > build, 'the cluster is initialised after the build');
    assert.ok(readdirSync(join(state, 'data')).some(name => /^db\.pre-restore-/.test(name)), 'the data was moved only after the build');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore refuses with the data untouched when the stale db image cannot be rebuilt', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-stale-refuse-');
  try {
    const result = restore(scratch, ['--yes', backup], { ...staleDbImage(scratch), FAKE_BUILD_FAILS: 'yes', FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt') });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Refusing: the db image could not be rebuilt.*Nothing was moved/s);
    assert.doesNotMatch(result.calls, /up -d --wait --wait-timeout 180 db/, 'no cluster was initialised');
    untouched(state);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore refuses with the data untouched when the db image is still stale after a build that reported success', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-stale-after-');
  try {
    const result = restore(scratch, ['--yes', backup], { ...staleDbImage(scratch), FAKE_BUILD_NOOP: 'yes', FAKE_BUILD_CONTEXT: join(scratch, 'root/docker/postgres'), FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt') });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Refusing: the db image still does not match this checkout after the rebuild.*Nothing was moved/s);
    assert.doesNotMatch(result.calls, /up -d --wait --wait-timeout 180 db/);
    untouched(state);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore refuses with the data untouched when the db image check itself fails', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-plan-fails-');
  try {
    const broken = join(scratch, 'broken-config.json');
    writeFileSync(broken, 'not json');
    const result = restore(scratch, ['--yes', backup], { FAKE_COMPOSE_CONFIG: broken, FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt') });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Refusing: could not check whether the db image matches this checkout\. Nothing was moved\./);
    assert.doesNotMatch(result.calls, /up -d --wait --wait-timeout 180 db/);
    untouched(state);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('a restore that fails only at the release files says the data is restored and that setup.sh finishes it, before the rollback text', () => {
  const { scratch, backup } = fixture('warehouse-restore-release-files-');
  try {
    const stubs = root => {
      writeFileSync(join(root, 'scripts/migrate.sh'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o700 });
      writeFileSync(join(root, 'scripts/release-info.sh'), '#!/usr/bin/env bash\necho "fake: release.json could not be written" >&2\nexit 1\n', { mode: 0o700 });
    };
    const result = restore(scratch, ['--yes', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt') }, stubs);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Restore failed during: release files\nThe database and the stored files ARE restored; only public\/release\.json and public\/app-compat\.json were not written \(message above\)\. Rerunning\nbash setup\.sh writes them and finishes the restore;/);
    assert.ok(result.stderr.indexOf('Rerunning') < result.stderr.indexOf('Rollback: bash stop.sh'), 'before the rollback text, which stays');
    // Any other phase does not say so.
    const other = restore(scratch, ['--yes', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), FAKE_FAIL_START: 'yes' }, root => writeFileSync(join(root, 'scripts/migrate.sh'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o700 }));
    assert.doesNotMatch(other.stderr, /ARE restored/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('a restore whose services do not start names the unhealthy ones and shows their last log lines', () => {
  const { scratch, backup } = fixture('warehouse-restore-start-');
  try {
    // The migration step needs the whole checkout; here it is stood in for so the start is reached.
    const noMigrations = root => writeFileSync(join(root, 'scripts/migrate.sh'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o700 });
    const result = restore(scratch, ['--yes', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), FAKE_FAIL_START: 'yes' }, noMigrations);
    assert.notEqual(result.status, 0, 'the injected start failure propagates');
    assert.match(result.stderr, /Restore failed during: start services/);
    assert.match(result.stderr, /Service storage is running \(unhealthy\)\. Its last log lines:\nfake log of storage\n/);
    assert.match(result.stderr, /Service functions is exited\. Its last log lines:\nfake log of functions\n/);
    assert.doesNotMatch(result.stderr, /Service (db|rest) is/, 'healthy services and services without a health check are left out');
    assert.ok(result.stderr.indexOf('fake log of functions') < result.stderr.indexOf('Restore failed during'), 'the logs come before the rollback text');
    assert.match(result.stderr, /Rollback: bash stop\.sh/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore refuses a backup that is not signed with the key of this installation, before stopping or moving anything', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-signature-');
  try {
    // Edited and re-checksummed by someone without the key.
    writeFileSync(join(backup, 'database.dump'), 'planted dump\n');
    spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: backup });
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

// Review finding 5 (TW-BE-020): --restore-config brings back a compose.env that names a central key file the
// state no longer has (setup deleted it when central sign-in moved to an address). The restore completed, so
// the final doctor must only warn, and the rerun that puts the file back is printed.
test('restore --restore-config onto a state without the key file the restored configuration names finishes, with a rerun', () => {
  const run = (keyOnDisk, extraEnv) => {
    const { scratch, state, backup } = fixture('warehouse-restore-keyfile-');
    try {
      const env = composeEnv(state, `JWT_SECRET=old-secret\nCENTRAL_ISSUER=https://login.association.example.test\nCENTRAL_JWKS_URL=\nCENTRAL_JWKS_FILE=central-jwks.json\n`);
      writeFileSync(join(backup, 'compose.env'), env, { mode: 0o600 });
      spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: backup });
      signBackup(backup);
      if (keyOnDisk) writeFileSync(join(state, 'public/central-jwks.json'), '{"keys":[]}\n');
      const seen = join(scratch, 'doctor-saw.txt');
      const result = restore(scratch, ['--yes', '--restore-config', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), DOCTOR_SEEN: seen, ...extraEnv }, root => {
        writeFileSync(join(root, 'scripts/migrate.sh'), '#!/usr/bin/env bash\nexit 0\n');
        writeFileSync(join(root, 'scripts/doctor.mjs'), "import { appendFileSync } from 'node:fs';\nappendFileSync(process.env.DOCTOR_SEEN, `pending=${process.env.WAREHOUSE_CENTRAL_KEY_PENDING ?? ''}\\n`);\n");
      });
      return { result, state, saw: existsSync(seen) ? readFileSync(seen, 'utf8') : null };
    } finally { rmSync(scratch, { recursive: true, force: true }); }
  };
  const missing = run(false);
  assert.equal(missing.result.status, 0, missing.result.stderr);
  assert.equal(missing.saw, 'pending=yes\n', 'doctor --local is told the missing key file is to be put back');
  assert.doesNotMatch(missing.result.stderr, /Restore failed/);
  assert.ok(missing.result.stdout.includes(`bash setup.sh --operator --state-dir ${missing.state} --admin-phone 91XXXXXXXXXX --admin-name 'ADMIN NAME' \\\n`));
  assert.match(missing.result.stdout, /--central-issuer https:\/\/login\.association\.example\.test --central-jwks-file \/absolute\/path\/to\/association-jwks\.json/);
  // The file is there: nothing to warn about or rerun.
  const present = run(true);
  assert.equal(present.result.status, 0, present.result.stderr);
  assert.equal(present.saw, 'pending=\n');
  assert.doesNotMatch(present.result.stdout, /setup\.sh/);
});

// TW-BE-022. A v5 backup is always signed. With the signature file gone and the key in hand, the
// flag must not wave it through: it is only for a lost key.
test('restore refuses a v5 backup whose signature file was removed, even with --allow-unsigned, while the key is available', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-stripped-v5-', { key: null });
  try {
    assert.equal(existsSync(join(backup, 'SHA256SUMS.hmac')), false, 'the fixture is a v5 backup without its signature');
    assert.equal(existsSync(join(state, 'config/backup.key')), true, 'this installation still has its key');
    let result = restore(scratch, ['--yes', '--allow-unsigned', backup]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /a v5 or v6 backup must be signed; its signature file was removed/);
    assert.match(result.stderr, /--allow-unsigned is only for when the backup key is lost/);
    assert.doesNotMatch(result.stderr, /WARNING|WITHOUT proof/, 'no banner: nothing was accepted');
    // restore.sh asks Compose whether services run before it looks at the backup; no container is run, started or copied into.
    assert.doesNotMatch(result.calls, /run |up -d| cp /, 'no container is run or started');
    untouched(state);
    // Without the flag it is refused as well, and the message does not send the operator to the flag.
    result = restore(scratch, ['--yes', backup]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /carries no signature[\s\S]*a v5 or v6 backup must be signed/);
    assert.doesNotMatch(result.calls, /run |up -d| cp /);
    // The refusal does not wait for the checksums: a damaged file does not change the answer.
    writeFileSync(join(backup, 'database.dump'), 'damaged after the signature was removed\n');
    result = restore(scratch, ['--yes', '--allow-unsigned', backup]);
    assert.match(result.stderr, /a v5 or v6 backup must be signed/);
    assert.doesNotMatch(result.stderr, /does not match its SHA256SUMS/);
    untouched(state);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore takes the same v5 backup with --allow-unsigned and a loud warning once the key is lost', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-stripped-v5-lost-key-', { key: null });
  try {
    rmSync(join(state, 'config/backup.key'));
    const result = restore(scratch, ['--yes', '--allow-unsigned', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), FAKE_FAIL_START: 'yes' });
    assert.match(result.stderr, /WARNING: this backup carries no signature[\s\S]*WITHOUT proof/);
    assert.doesNotMatch(result.stderr, /a v5 or v6 backup must be signed/);
    assert.match(result.calls, /^run -d --pull missing/m, 'the verifier ran');
    assert.match(result.calls, /DROP DATABASE postgres WITH \(FORCE\)/, 'and the replay started');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

// After a rollback (an older checkout, then restore.sh) public/release.json and public/app-compat.json must describe that checkout, not the
// release rolled back from: restore.sh writes them again after its migrations and before the services start.
test('restore writes public/release.json and public/app-compat.json for its checkout after the migrations, before the services start', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-restore-release-'));
  try {
    const state = makeState(scratch);
    const backup = makeBackup(join(scratch, 'backup'), { env: composeEnv(state) });
    writeFileSync(join(state, 'public/release.json'), JSON.stringify({ backendRelease: 'v9.9.9', backendCommit: 'f'.repeat(40), schemaHead: '9999_newer.sql', writtenAt: '2026-01-01T00:00:00.000Z' }));
    writeFileSync(join(state, 'public/app-compat.json'), JSON.stringify({ minimumClientVersion: '9.9.9' }));
    const result = restore(scratch, ['--yes', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt') }, root => {
      standIns(root);
      writeFileSync(join(root, 'app-compat.json'), JSON.stringify({ minimumClientVersion: '0.0.7', note: 'restored checkout' }));
    });
    assert.equal(result.status, 0, result.stderr);
    const release = JSON.parse(readFileSync(join(state, 'public/release.json'), 'utf8'));
    assert.equal(release.schemaHead, '0002_second.sql', 'the newest migration of the restored database');
    assert.notEqual(release.backendRelease, 'v9.9.9');
    assert.equal(JSON.parse(readFileSync(join(state, 'public/app-compat.json'), 'utf8')).minimumClientVersion, '0.0.7', 'the minimum of the restored checkout');
    const lines = result.calls.split('\n');
    const migrated = lines.findIndex(line => line.startsWith('migrate.sh'));
    const ledger = lines.findIndex(line => line.includes('warehouse_migrations.applied'));
    const started = lines.findIndex(line => line.endsWith('up -d --wait --wait-timeout 180'));
    assert.ok(migrated >= 0 && migrated < ledger && ledger < started, `written after the migrations and before the services start (${migrated} ${ledger} ${started})`);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

// TW-BE-002 (docs/CONTAINER_SECURITY.md, "Database passwords"). The migration
// step and the local doctor need a whole checkout and a stack; they are stood in for.
const standIns = root => {
  writeFileSync(join(root, 'scripts/migrate.sh'), '#!/usr/bin/env bash\nprintf "%s\\n" "migrate.sh $*" >> "$FAKE_DOCKER_LOG"\n', { mode: 0o700 });
  writeFileSync(join(root, 'scripts/doctor.mjs'), "console.log('Local operator services and gateway are healthy.');\n");
};
// Each \set line of the prelude must be a verifier of the given password (its own salt reused).
function assertVerifiers(stdin, env) {
  const roles = { authenticator: 'DB_PASSWORD_AUTHENTICATOR', storage: 'DB_PASSWORD_STORAGE', ...(env.POOLER_ENABLED === 'true' ? { pooler: 'DB_PASSWORD_POOLER' } : {}) };
  const sets = Object.fromEntries([...stdin.matchAll(/^\\set ([a-z]+)_verifier '([^']+)'$/gm)].map(match => [match[1], match[2]]));
  assert.deepEqual(Object.keys(sets).sort(), Object.keys(roles).sort());
  for (const [variable, name] of Object.entries(roles)) {
    const salt = Buffer.from(sets[variable].split(':')[1].split('$')[0], 'base64');
    assert.equal(scramVerifier(env[name], salt), sets[variable], `${variable} is a verifier of ${name}`);
    assert.equal(stdin.includes(env[name]), false, `${name} itself is not sent`);
  }
}

test('restore of a backup taken before per-role passwords keeps this state\'s values and sets them after the migrations', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-restore-previous-'));
  try {
    const state = makeState(scratch);
    const backup = makeBackup(join(scratch, 'backup'), { env: composeEnv(state, undefined, previousReleaseDbLines) });
    const stdinLog = join(scratch, 'stdin.log');
    const result = restore(scratch, ['--yes', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), FAKE_STDIN_LOG: stdinLog }, standIns);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(join(state, 'config/compose.env'), 'utf8'), composeEnv(state), 'this state keeps its configuration and its values');
    const lines = result.calls.split('\n');
    const migrated = lines.findIndex(line => line.startsWith('migrate.sh'));
    const logins = lines.findIndex(line => line.includes(' exec -T db sh -c IFS= read -r pw;'));
    const started = lines.findIndex(line => line.endsWith('up -d --wait --wait-timeout 180'));
    assert.ok(migrated >= 0 && migrated < logins && logins < started, `logins are set after the migrations and before the services start (${migrated} ${logins} ${started})`);
    // The superuser password signs in on standard input; the verifiers are of this state's values.
    const stdin = readFileSync(stdinLog, 'utf8');
    assert.equal(stdin.split('\n')[0], '5'.repeat(64));
    assertVerifiers(stdin, readEnv(join(state, 'config/compose.env')));
    assert.match(stdin, /ALTER ROLE authenticator WITH LOGIN PASSWORD/, 'configure-db-roles.sql follows the prelude');
    assert.doesNotMatch(stdin, /^\\set pooler_verifier|CREATE DATABASE _supabase|CREATE ROLE pgbouncer/m, 'the pooler is off: no pooler object is created and no pooler password is given');
    assert.match(stdin, /DROP SCHEMA IF EXISTS pgbouncer;\nDROP ROLE IF EXISTS pgbouncer;/, 'the pooler is off: pooler objects a restore brought back are dropped');
    assert.doesNotMatch(stdin, /CASCADE|FORCE/);
    assert.match(result.stdout, /Note: the pooler was 'unset' when the backup was taken and is 'false' in this installation/);
    assert.doesNotMatch(stdin, /postgres_verifier|monitoring_verifier|DROP ROLE (?!IF EXISTS pgbouncer;)|supabase_auth_admin|supabase_functions_admin/, 'no verifier or statement for a role of the earlier image');
    for (const secret of ['5'.repeat(64), '1'.repeat(64)]) assert.equal(result.calls.includes(secret), false, 'no password in a docker argument');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore refuses a backup whose per-role password differs (rotated after it) unless --restore-config', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-restore-rotated-roles-'));
  try {
    const state = makeState(scratch);
    const backup = makeBackup(join(scratch, 'backup'), { env: composeEnv(state, undefined, dbRoleLines.replace('2'.repeat(64), '7'.repeat(64))) });
    const result = restore(scratch, ['--yes', backup]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /compose\.env differs from the backup copy.*--restore-config/);
    assert.doesNotMatch(result.calls, /run |up -d| cp /);
    untouched(state);
    assert.equal(readFileSync(join(state, 'config/compose.env'), 'utf8'), composeEnv(state));
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore --restore-config of a backup taken before per-role passwords gives the restored configuration new ones before the database starts', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-restore-config-previous-'));
  try {
    const state = makeState(scratch);
    const old = composeEnv(state, 'JWT_SECRET=old-secret\n', previousReleaseDbLines);
    const backup = makeBackup(join(scratch, 'backup'), { env: old });
    const stdinLog = join(scratch, 'stdin.log');
    const result = restore(scratch, ['--yes', '--restore-config', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), FAKE_STDIN_LOG: stdinLog }, standIns);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Added DB_PASSWORD_AUTHENTICATOR, DB_PASSWORD_STORAGE: the backup was taken before/);
    const restored = readFileSync(join(state, 'config/compose.env'), 'utf8');
    assert.ok(restored.startsWith(old), 'the backup configuration comes back line for line');
    const env = readEnv(join(state, 'config/compose.env'));
    for (const name of ['DB_PASSWORD_AUTHENTICATOR', 'DB_PASSWORD_STORAGE']) {
      assert.match(env[name], /^[0-9a-f]{64}$/, name);
      assert.equal(dbRoleLines.includes(env[name]), false, `${name} is new, not the replaced state's`);
    }
    assert.equal(statSync(join(state, 'config/compose.env')).mode & 0o777, 0o600);
    assertVerifiers(readFileSync(stdinLog, 'utf8'), env);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

// Backups of the earlier supabase/postgres image are refused (scripts/backup-image.sh); their data is reloaded
// through the release tagged migrations-pre-baseline (docs/OPERATOR_INSTALL.md, "Baseline reload").
const OLD_IMAGE = 'supabase/postgres:15.8.1.135@sha256:ee680a0afebe1a5e95614fdea671c01a264e58f52de6c429c17a394f46dec2c6';

test('restore refuses a backup made on the supabase/postgres image or with no image line, naming the tag and the reload, before any call', () => {
  for (const [label, databaseImage, reason] of [
    ['the earlier image', OLD_IMAGE, /made on the database image 'supabase\/postgres:15\.8\.1\.135@sha256:[0-9a-f]{64}'/],
    ['no image line', null, /records no database_image= line/],
    ['an empty image line', '', /records no database_image= line/],
    ['an unknown image', 'mariadb:11', /unknown database image 'mariadb:11'/],
  ]) {
    const scratch = mkdtempSync(join(tmpdir(), 'warehouse-restore-image-'));
    try {
      const state = makeState(scratch);
      const backup = makeBackup(join(scratch, 'backup'), { env: composeEnv(state), databaseImage });
      const result = restore(scratch, ['--yes', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt') }, standIns);
      assert.notEqual(result.status, 0, label);
      assert.match(result.stderr, reason, label);
      if (databaseImage !== 'mariadb:11') assert.match(result.stderr, /migrations-pre-baseline.*Baseline reload/s, label);
      assert.equal(result.calls, '', `${label}: nothing was started`);
      untouched(state);
    } finally { rmSync(scratch, { recursive: true, force: true }); }
  }
});

test('restore, verify-restore and restore-host share one image check, run before the signature check', () => {
  for (const script of ['restore.sh', 'verify-restore.sh', 'restore-host.sh']) {
    const text = readFileSync(new URL(`../scripts/${script}`, import.meta.url), 'utf8');
    const check = text.indexOf('backup_check_database_image "$backup"');
    assert.ok(check > 0, `${script} checks the database image`);
    assert.ok(check < text.indexOf('backup_authenticate "$backup"') || script === 'restore.sh', `${script}: the image check precedes the signature check`);
  }
  const restoreSh = readFileSync(new URL('../scripts/restore.sh', import.meta.url), 'utf8');
  assert.ok(restoreSh.indexOf('backup_check_database_image "$backup"') < restoreSh.indexOf('backup_authenticate "$backup" "$allow_unsigned"'), 'restore.sh: the image check precedes the signature check');
});

test('restore recreates the database owned by supabase_admin and carries no leftover of the earlier image', () => {
  const restoreSh = readFileSync(new URL('../scripts/restore.sh', import.meta.url), 'utf8');
  const verifySh = readFileSync(new URL('../scripts/verify-restore.sh', import.meta.url), 'utf8');
  assert.equal((restoreSh.match(/OWNER supabase_admin TEMPLATE template0/g) ?? []).length, 1);
  for (const [name, text] of [['restore.sh', restoreSh], ['verify-restore.sh', verifySh]]) {
    assert.doesNotMatch(text, /OWNER postgres|pg_net|pg_cron|graphql|retire_graphql|PGRST_DB_SCHEMAS|EVENT TRIGGER|triggers\.list|main\.list|full\.list|-U postgres/, name);
  }
  // The disposable database of the verifier is built like the migration test's: the new image, the bootstrap, supabase_admin.
  assert.match(verifySh, /-e POSTGRES_USER=supabase_admin -e POSTGRES_DB=postgres/);
  assert.match(verifySh, /00-bootstrap\.sql:\/docker-entrypoint-initdb\.d\/00-bootstrap\.sql/);
});

test('the _supabase database exists only while the pooler is on: made by pooler.sh, not dumped, not restored, owned by supabase_admin', () => {
  const read = file => readFileSync(new URL(`../${file}`, import.meta.url), 'utf8');
  const compose = read('docker/docker-compose.yml');
  assert.doesNotMatch(compose, /_supabase\.sql|pooler\.sql|initdb\.d\/3/);
  assert.match(read('scripts/configure-pooler.sql'), /CREATE DATABASE _supabase WITH OWNER supabase_admin/);
  assert.match(read('scripts/configure-pooler.sql'), /CREATE SCHEMA IF NOT EXISTS _supavisor AUTHORIZATION supabase_admin/);
  assert.match(compose, /DATABASE_URL: ecto:\/\/supabase_admin:\$\{POSTGRES_PASSWORD\}@\$\{POSTGRES_HOST\}:\$\{POSTGRES_PORT\}\/_supabase/);
  assert.doesNotMatch(read('scripts/backup.sh').replace(/^#.*$/gm, ''), /_supabase/);
  assert.doesNotMatch(read('scripts/restore.sh').replace(/^\s*#.*$/gm, ''), /DROP DATABASE _supabase|CREATE DATABASE _supabase|-d _supabase|compose cp .*_supabase/);
  assert.doesNotMatch(read('scripts/configure-pooler.sql'), /_analytics/);
});

test('restore of a backup that still holds _supabase.dump skips it with a note; a state without the pooler secrets still accepts the old configuration', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-restore-legacy-pooler-'));
  try {
    // The state is clean of the pooler (setup removed its secrets); the backup is from before and carries them, and _supabase.dump.
    const state = makeState(scratch);
    const backup = makeBackup(join(scratch, 'backup'), { legacyPooler: true, env: composeEnv(state, undefined, dbRoleLines.replace('POOLER_ENABLED=false\n', '') + legacyPoolerLines) });
    const result = restore(scratch, ['--yes', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt') }, standIns);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Note: the backup contains _supabase\.dump \(the pooler tenant\)\. It is skipped: the pooler recreates its tenant when it starts\./);
    assert.equal(result.calls.includes('_supabase'), false, 'it is not copied, dropped or replayed');
    assert.equal(readFileSync(join(state, 'config/compose.env'), 'utf8'), composeEnv(state), 'this state keeps its own configuration');
    // A backup of this release has no _supabase.dump and needs no note.
    const other = mkdtempSync(join(tmpdir(), 'warehouse-restore-new-pooler-'));
    try {
      const otherState = makeState(other);
      const plain = restore(other, ['--yes', makeBackup(join(other, 'plain'), { env: composeEnv(otherState) })], { FAKE_CATALOG_FILE: join(other, 'plain', 'storage_objects.txt') }, standIns);
      assert.equal(plain.status, 0, plain.stderr);
      assert.doesNotMatch(plain.stdout, /_supabase\.dump/);
    } finally { rmSync(other, { recursive: true, force: true }); }
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore while the pooler is on recreates its role, schema and _supabase database before setting its password, from this state\'s values', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-restore-pooler-on-'));
  try {
    const env = composeEnv(join(scratch, 'state'), undefined, dbRoleLines.replace('POOLER_ENABLED=false\n', '') + poolerOnLines);
    const state = makeState(scratch, { env });
    const backup = makeBackup(join(scratch, 'backup'), { env });
    const stdinLog = join(scratch, 'stdin.log');
    const result = restore(scratch, ['--yes', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), FAKE_STDIN_LOG: stdinLog }, standIns);
    assert.equal(result.status, 0, result.stderr);
    const stdin = readFileSync(stdinLog, 'utf8');
    assert.ok(stdin.indexOf('CREATE DATABASE _supabase') >= 0 && stdin.indexOf('CREATE DATABASE _supabase') < stdin.indexOf('ALTER ROLE pgbouncer WITH LOGIN PASSWORD'), 'objects first, then the password');
    assertVerifiers(stdin, readEnv(join(state, 'config/compose.env')));
    assert.equal(stdin.includes('4'.repeat(64)), false, 'the pool user password itself is not sent');
    // Without the pooler objects in the backup, nothing in the restore connects to _supabase.
    assert.equal(result.calls.includes('-d _supabase'), false);
    assert.doesNotMatch(stdin, /DROP ROLE IF EXISTS pgbouncer/, 'the pooler is on: nothing is dropped');
    assert.doesNotMatch(result.stdout, /Note: the pooler was/, 'same setting: no note');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('verify-restore refuses an old image backup with no container started', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-verify-image-'));
  try {
    const backup = makeBackup(join(scratch, 'backup'), { databaseImage: OLD_IMAGE });
    const bin = fakeDocker(join(scratch, 'bin'));
    const log = join(scratch, 'docker.log'); writeFileSync(log, '');
    const result = spawnSync('bash', [new URL('../scripts/verify-restore.sh', import.meta.url).pathname, backup], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, FAKE_DOCKER_LOG: log, WAREHOUSE_STATE_DIR: '' } });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /supabase\/postgres.*migrations-pre-baseline.*Baseline reload/s);
    assert.equal(readFileSync(log, 'utf8'), '');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

// The Storage service migrates its own catalog forward at start and cannot read a newer one: a backup whose catalog is on a newer
// Storage schema than this checkout's image (docker/storage/migrations-head.txt) is refused before anything moves; an older one,
// or one from before the head was recorded, is not.
const storageHead = Number(readFileSync(new URL('../docker/storage/migrations-head.txt', import.meta.url), 'utf8').match(/^id=(\d+)$/m)[1]);
test('restore refuses, before moving anything, a backup with a newer Storage schema than this checkout, and not an older, equal or unrecorded one', () => {
  const report = head => `${defaultIntegrityLines}${head === null ? '' : `storage_migrations_count=${head}\nstorage_migrations_head=${head}\n`}`;
  const newer = fixture('warehouse-restore-storage-newer-', { integrity: report(storageHead + 1) });
  try {
    const result = restore(newer.scratch, ['--yes', newer.backup], {}, root => writeFileSync(join(root, 'scripts/verify-restore.sh'), `touch '${join(newer.scratch, 'verify-ran')}'\nexit 0\n`));
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, new RegExp(`Refusing: the backup was taken with Storage schema version ${storageHead + 1} .*newer than version ${storageHead}, the newest that this checkout's Storage image [0-9.]+ migrates to\\. Check out a release at least as new as the backup.*Nothing was moved\\.`));
    assert.doesNotMatch(result.calls, /run |up -d| cp |createdb|pg_restore|DROP DATABASE/, 'no restore was started');
    // restore.sh's own refusal comes before the disposable verification (verify-restore.sh would refuse with the same text, later).
    assert.equal(existsSync(join(newer.scratch, 'verify-ran')), false, 'refused before verify-restore.sh was started');
    untouched(newer.state);
  } finally { rmSync(newer.scratch, { recursive: true, force: true }); }
  for (const [what, head] of [['an older head', storageHead - 1], ['an equal head', storageHead], ['no recorded head', null]]) {
    const { scratch, backup } = fixture('warehouse-restore-storage-ok-', { integrity: report(head) });
    try {
      const result = restore(scratch, ['--yes', backup]);
      assert.doesNotMatch(result.stderr, /Storage schema/, `${what}: not refused for the Storage schema`);
    } finally { rmSync(scratch, { recursive: true, force: true }); }
  }
});

// A backup made before the Storage head was recorded has none in its report, but the restored database reports one: the comparison
// drops those two lines (storage_integrity_align), so the restore gets past it, to the start of the services.
test('restore of a backup made before the Storage head was recorded passes the integrity comparison', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-storage-legacy-');
  try {
    const restored = `${defaultIntegrityLines}storage_migrations_count=${storageHead}\nstorage_migrations_head=${storageHead}\n`;
    const result = restore(scratch, ['--yes', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), FAKE_RESTORED_INTEGRITY: restored, FAKE_FAIL_START: 'yes' });
    assert.notEqual(result.status, 0, 'the injected start failure propagates');
    assert.match(result.stderr, /Restore failed during: (migrations|start services)/, result.stderr);
    assert.doesNotMatch(result.stderr, /Restore failed during: integrity comparison/);
    assert.ok(existsSync(state));
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('an explicit --help prints the usage on standard output and exits 0; a missing argument is still an error on standard error', () => {
  for (const script of ['restore.sh', 'restore-host.sh', 'verify-restore.sh']) {
    const path = new URL(`../scripts/${script}`, import.meta.url).pathname;
    for (const flag of ['--help', '-h']) {
      const help = spawnSync('bash', [path, flag], { encoding: 'utf8' });
      assert.equal(help.status, 0, `${script} ${flag}: ${help.stderr}`);
      assert.match(help.stdout, /^Usage: npm run db:/, script);
      assert.equal(help.stderr, '', script);
    }
    const none = spawnSync('bash', [path], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: '' } });
    assert.equal(none.status, 1, `${script} without arguments`);
    assert.match(none.stderr, /Usage: npm run db:/, script);
  }
});
