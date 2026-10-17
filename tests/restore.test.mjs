import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeBackup, makeState, fakeDocker, scriptRoot, composeEnv, dbRoleLines, previousReleaseDbLines, instanceJson, signBackup } from './backup-test-helpers.mjs';
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
      // A leading space: the verification container is warehouse-restore-<12 random hex digits>, whose name can end in "db".
      ' db:/tmp/database.dump', ' db:/tmp/_supabase.dump',
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

test('a restore whose services do not start names the unhealthy ones and shows their last log lines', () => {
  const { scratch, backup } = fixture('warehouse-restore-start-');
  try {
    // The migration step needs the whole checkout; here it is stood in for so the start is reached.
    const noMigrations = root => writeFileSync(join(root, 'scripts/migrate.sh'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o700 });
    const result = restore(scratch, ['--yes', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), FAKE_FAIL_START: 'yes' }, noMigrations);
    assert.notEqual(result.status, 0, 'the injected start failure propagates');
    assert.match(result.stderr, /Restore failed during: start services/);
    assert.match(result.stderr, /Service meta is running \(unhealthy\)\. Its last log lines:\nfake log of meta\n/);
    assert.match(result.stderr, /Service studio is exited\. Its last log lines:\nfake log of studio\n/);
    assert.doesNotMatch(result.stderr, /Service (db|rest) is/, 'healthy services and services without a health check are left out');
    assert.ok(result.stderr.indexOf('fake log of studio') < result.stderr.indexOf('Restore failed during'), 'the logs come before the rollback text');
    assert.match(result.stderr, /Rollback: bash stop\.sh/);
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

// Review finding 5 (TW-BE-020): --restore-config brings back a compose.env that names a central key file the
// state no longer has (setup deleted it when central sign-in moved to an address). The restore completed, so
// the final doctor must only warn, and the rerun that puts the file back is printed.
test('restore --restore-config onto a state without the key file the restored configuration names finishes, with a rerun', () => {
  const run = (keyOnDisk, extraEnv) => {
    const { scratch, state, backup } = fixture('warehouse-restore-keyfile-');
    try {
      const env = composeEnv(state, `JWT_SECRET=old-secret\nCENTRAL_ISSUER=https://login.association.example.test\nCENTRAL_JWKS_URL=\nCENTRAL_JWKS_FILE=central-jwks.json\n`);
      writeFileSync(join(backup, 'compose.env'), env, { mode: 0o600 });
      spawnSync('sh', ['-c', 'sha256sum storage.tar.gz database.dump _supabase.dump storage_objects.txt integrity.txt metadata.txt compose.env instance.json roles.txt > SHA256SUMS'], { cwd: backup });
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
// flag must not wave it through: it is for backups written before v5 and for a lost key.
test('restore refuses a v5 backup whose signature file was removed, even with --allow-unsigned, while the key is available', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-stripped-v5-', { key: null });
  try {
    assert.equal(existsSync(join(backup, 'SHA256SUMS.hmac')), false, 'the fixture is a v5 backup without its signature');
    assert.equal(existsSync(join(state, 'config/backup.key')), true, 'this installation still has its key');
    let result = restore(scratch, ['--yes', '--allow-unsigned', backup]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /a v5 backup must be signed; its signature file was removed/);
    assert.match(result.stderr, /--allow-unsigned is only for a backup written before format v5, or when the backup key is lost/);
    assert.doesNotMatch(result.stderr, /WARNING|WITHOUT proof/, 'no banner: nothing was accepted');
    // restore.sh asks Compose whether services run before it looks at the backup; no container is run, started or copied into.
    assert.doesNotMatch(result.calls, /run |up -d| cp /, 'no container is run or started');
    untouched(state);
    // Without the flag it is refused as well, and the message does not send the operator to the flag.
    result = restore(scratch, ['--yes', backup]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /carries no signature[\s\S]*a v5 backup must be signed/);
    assert.doesNotMatch(result.calls, /run |up -d| cp /);
    // The refusal does not wait for the checksums: a damaged file does not change the answer.
    writeFileSync(join(backup, 'database.dump'), 'damaged after the signature was removed\n');
    result = restore(scratch, ['--yes', '--allow-unsigned', backup]);
    assert.match(result.stderr, /a v5 backup must be signed/);
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
    assert.doesNotMatch(result.stderr, /a v5 backup must be signed/);
    assert.match(result.calls, /^run -d --pull missing/m, 'the verifier ran');
    assert.match(result.calls, /DROP DATABASE postgres WITH \(FORCE\)/, 'and the replay started');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('restore still takes an unsigned v4 backup with --allow-unsigned while the key is available (owner decision of 2026-10-17: a v5 backup relabelled v4 is the accepted residual)', () => {
  const { scratch, state, backup } = fixture('warehouse-restore-v4-with-key-', { format: 'warehouse-backup-v4' });
  try {
    assert.equal(existsSync(join(state, 'config/backup.key')), true);
    const result = restore(scratch, ['--yes', '--allow-unsigned', backup], { FAKE_CATALOG_FILE: join(backup, 'storage_objects.txt'), FAKE_FAIL_START: 'yes' });
    assert.match(result.stderr, /WARNING: this backup carries no signature[\s\S]*WITHOUT proof/);
    assert.doesNotMatch(result.stderr, /a v5 backup must be signed/);
    assert.match(result.calls, /DROP DATABASE postgres WITH \(FORCE\)/);
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
  const roles = { authenticator: 'DB_PASSWORD_AUTHENTICATOR', storage: 'DB_PASSWORD_STORAGE', auth: 'DB_PASSWORD_AUTH', pooler: 'DB_PASSWORD_POOLER', monitoring: 'DB_PASSWORD_MONITORING' };
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
    assert.match(stdin, /ALTER ROLE warehouse_monitoring WITH LOGIN PASSWORD/, 'configure-db-roles.sql follows the prelude');
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
    assert.match(result.stdout, /Added DB_PASSWORD_AUTHENTICATOR, DB_PASSWORD_STORAGE, DB_PASSWORD_AUTH, DB_PASSWORD_POOLER, DB_PASSWORD_MONITORING, REALTIME_DB_ENC_KEY: the backup was taken before/);
    const restored = readFileSync(join(state, 'config/compose.env'), 'utf8');
    assert.ok(restored.startsWith(old), 'the backup configuration comes back line for line');
    const env = readEnv(join(state, 'config/compose.env'));
    for (const name of ['DB_PASSWORD_AUTHENTICATOR', 'DB_PASSWORD_STORAGE', 'DB_PASSWORD_AUTH', 'DB_PASSWORD_POOLER', 'DB_PASSWORD_MONITORING']) {
      assert.match(env[name], /^[0-9a-f]{64}$/, name);
      assert.equal(dbRoleLines.includes(env[name]), false, `${name} is new, not the replaced state's`);
    }
    assert.match(env.REALTIME_DB_ENC_KEY, /^[A-Za-z0-9_-]{16}$/);
    assert.equal(statSync(join(state, 'config/compose.env')).mode & 0o777, 0o600);
    assertVerifiers(readFileSync(stdinLog, 'utf8'), env);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});
