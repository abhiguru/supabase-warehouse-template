// scripts/rotate-db-passwords.sh (npm run db:rotate-passwords) against a fake
// docker: the database side first, then the file, then the services; a service
// that does not come back puts the previous values back everywhere.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, statSync, existsSync, rmSync, copyFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configure } from '../scripts/configure.mjs';
import { readEnv } from '../scripts/doctor-common.mjs';
import { validateOperatorEnv } from '../scripts/doctor.mjs';
import { DB_ROLE_LOGINS, scramVerifier } from '../scripts/db-roles.mjs';

const root = new URL('..', import.meta.url).pathname;
const script = join(root, 'scripts/rotate-db-passwords.sh');
const roleNames = DB_ROLE_LOGINS.map(({ env }) => env);

// Records every invocation and answers the doctor's probes (the list refresh status
// of migration 91 included, once that lands). The "database" is a file, FAKE_DB_STATE:
// the compose.env whose values it has. A successful `apply` of scripts/db-roles.sh
// gives it the values of the file being applied (the staged file for the rotation,
// the previous one for the reversal); `matches` compares a file's superuser and
// authenticator values with it. The `apply` and `check` streams go to
// FAKE_APPLY_INPUT and FAKE_CHECK_INPUT, separated by a line of =. FAKE_FAIL names a
// step that fails: apply (before the commit), lost (the connection, after the
// commit), killed (a signal to the whole command, after the commit), up (the first
// recreation only), check, doctor. FAKE_FAIL_REVERSAL=yes fails the reversal too.
const fakeDocker = `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
config="$WAREHOUSE_STATE_DIR/config"
case "$1" in
  ps) exit 0 ;;
  run) printf '18\\n' ;;   # the version preflight reads PG_VERSION of the data directory
  info) printf '28.0.0\\n' ;;
  inspect)
    case "$3" in
      # The health check of scripts/watch.mjs (INSPECT_FORMAT): one line per container id given.
      *com.docker.compose.service*) shift 3
        for id in "$@"; do
          case "$id" in a00000000001) n=db ;; a00000000002) n=gateway ;; a00000000003) n=rest ;; a00000000004) n=storage ;; a00000000005) n=functions ;; *) n=pdf-renderer ;; esac
          printf '%s|%s|running|healthy|0|false|2026-10-18T00:00:00Z|False\\n' "$id" "$n"
        done ;;
      *State.Status*) printf 'running healthy\\n' ;;
      *State.Health.Status*) printf 'healthy\\n' ;;
      *State.Running*) printf 'true\\n' ;;
    esac ;;
  compose)
    case "$*" in
      'compose version') printf 'Docker Compose version v2.39.0\\n' ;;
      'compose up --help') printf '      --wait-timeout int   Maximum duration in seconds to wait\\n' ;;
      *' config --services') printf 'db\\ngateway\\nrest\\nstorage\\nfunctions\\npdf-renderer\\n' ;;
      *' ps -a -q') printf 'a00000000001\\na00000000002\\na00000000003\\na00000000004\\na00000000005\\na00000000006\\n' ;;
      *' exec -T storage node '*) cat >/dev/null; printf 'OK REST\\nOK configuration\\n' ;;
      *' ps -q supavisor') : ;;
      *' ps -q '*) printf 'cccccccccccc\\n' ;;
      *' exec -T db sh -c IFS= read -r pw;'*)
        # The removal of the pooler objects (the pooler is off) comes first and is not an apply of the logins.
        cat > "$FAKE_APPLY_INPUT.part"
        if grep -q 'DROP ROLE IF EXISTS pgbouncer' "$FAKE_APPLY_INPUT.part"; then exit 0; fi
        cat "$FAKE_APPLY_INPUT.part" >> "$FAKE_APPLY_INPUT"; echo ===== >> "$FAKE_APPLY_INPUT"
        n=$(( $(cat "$FAKE_APPLY_INPUT.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_APPLY_INPUT.count"
        if [ "$FAKE_FAIL" = apply ]; then exit 3; fi
        if [ "$n" -ge 2 ] && [ "\${FAKE_FAIL_REVERSAL:-}" = yes ]; then exit 3; fi
        if [ -e "$config/compose.env.before-db-rotation" ]; then cp "$config/compose.env.before-db-rotation" "$FAKE_DB_STATE"
        elif [ -e "$config/compose.env.rotating-db" ]; then cp "$config/compose.env.rotating-db" "$FAKE_DB_STATE"; fi
        if [ "$FAKE_FAIL" = lost ]; then exit 2; fi
        if [ "$FAKE_FAIL" = killed ]; then kill -TERM 0; sleep 5; fi ;;
      *' exec -T db sh -c '*'verdict()'*)
        IFS= read -r su; IFS= read -r au
        if [ ! -f "$FAKE_DB_STATE" ]; then echo unknown; exit 0; fi
        dsu=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$FAKE_DB_STATE"); dau=$(sed -n 's/^DB_PASSWORD_AUTHENTICATOR=//p' "$FAKE_DB_STATE")
        if [ "$su" = "$dsu" ] && [ "$au" = "$dau" ]; then echo match; else echo 'no match'; fi ;;
      *' exec -T db sh -c '*'superuser_password'*) cat >> "$FAKE_CHECK_INPUT"; if [ "$FAKE_FAIL" = check ]; then exit 1; fi ;;
      *' up -d --force-recreate '*) if [ "$FAKE_FAIL" = up ] && [ ! -e "$FAKE_DOCKER_LOG.failed" ]; then : > "$FAKE_DOCKER_LOG.failed"; exit 1; fi ;;
      *'exec -T db pg_isready'*) if [ "$FAKE_FAIL" = doctor ]; then exit 1; fi ;;
      *'exec -T '*) cat >/dev/null ;;
    esac ;;
esac
`;

function fixture(prefix) {
  const scratch = mkdtempSync(join(tmpdir(), prefix));
  const state = join(scratch, 'state');
  const bin = join(scratch, 'bin');
  const providerEnv = join(scratch, 'provider.env');
  mkdirSync(bin);
  // Setup refuses a your- placeholder as unconfigured; nothing here can send: Docker is a fake.
  writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=isolated-no-delivery-key\nMSG91_TEMPLATE_ID=000000000000000000000001\nMSG91_PE_ID=1\nMSG91_SENDER_ID=ROTATE\n', { mode: 0o600 });
  configure(root, { stateDir: state, apiUrl: 'https://api.example.test', company: 'Acme', providerEnv });
  writeFileSync(join(state, 'public/app-compat.json'), readFileSync(join(root, 'app-compat.json'))); // setup.sh writes it; doctor checks it
  const envPath = join(state, 'config/compose.env');
  writeFileSync(join(bin, 'docker'), fakeDocker, { mode: 0o700 });
  const log = join(scratch, 'docker.log');
  // The database starts with the values of compose.env, as setup leaves it.
  const database = join(scratch, 'database.env');
  copyFileSync(envPath, database);
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log,
    FAKE_APPLY_INPUT: join(scratch, 'apply.txt'), FAKE_CHECK_INPUT: join(scratch, 'check.txt'), FAKE_DB_STATE: database };
  delete env.NODE_TEST_CONTEXT;
  // In its own session, so a fake signal to the process group reaches the command and nothing else.
  const run = (args, extra = {}) => spawnSync('setsid', ['bash', script, ...args], { encoding: 'utf8', env: { ...env, ...extra }, timeout: 120000 });
  const applies = () => (existsSync(env.FAKE_APPLY_INPUT) ? readFileSync(env.FAKE_APPLY_INPUT, 'utf8') : '').split('=====\n').filter(Boolean);
  const config = () => readdirSync(join(state, 'config')).sort();
  return { scratch, state, envPath, database, log, env, run, applies, config };
}
const changedLines = (before, after) => before.split('\n').filter((line, index) => line !== after.split('\n')[index]).map(line => line.split('=')[0]).sort();
// Every \set line of one apply stream is a verifier of the value in `env`; the first line signs in.
function assertApply(stream, env, signIn, extra = []) {
  const lines = stream.split('\n');
  assert.equal(lines[0], signIn, 'the sign-in password is the first line');
  const sets = Object.fromEntries([...stream.matchAll(/^\\set ([a-z_]+) '([^']+)'$/gm)].map(match => [match[1], match[2]]));
  const expected = [...DB_ROLE_LOGINS.map(({ env: name, variable }) => [variable, env[name]]), ...extra];
  assert.deepEqual(Object.keys(sets).sort(), expected.map(([variable]) => variable).sort());
  for (const [variable, password] of expected) {
    const salt = Buffer.from(sets[variable].split(':')[1].split('$')[0], 'base64');
    assert.equal(scramVerifier(password, salt), sets[variable], variable);
    assert.equal(stream.includes(password) && password !== signIn, false, `${variable}: no password beside the sign-in line`);
  }
  assert.ok(stream.includes(readFileSync(join(root, 'scripts/configure-db-roles.sql'), 'utf8')), 'configure-db-roles.sql follows the prelude');
}

test('rotation refuses without --yes and touches neither Docker nor the configuration', () => {
  const f = fixture('warehouse-rotate-db-refuse-');
  try {
    const before = readFileSync(f.envPath);
    for (const args of [[], ['--help'], ['--superuser'], ['--yes', 'extra']]) {
      const result = f.run(args);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /Rerun with --yes/);
    }
    assert.deepEqual(readFileSync(f.envPath), before);
    assert.equal(existsSync(f.log), false, 'no docker invocation without confirmation');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('rotation sets new verifiers first, then swaps compose.env, recreates the running consumers and checks every login', () => {
  const f = fixture('warehouse-rotate-db-flow-');
  try {
    const beforeText = readFileSync(f.envPath, 'utf8');
    const before = readEnv(f.envPath);
    const result = f.run(['--yes']);
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /every service login has a new password\.\nTake a new backup now/);
    const afterText = readFileSync(f.envPath, 'utf8');
    const after = readEnv(f.envPath);
    assert.deepEqual(changedLines(beforeText, afterText), [...roleNames].sort());
    for (const name of roleNames) assert.match(after[name], /^[0-9a-f]{64}$/);
    assert.equal(after.POSTGRES_PASSWORD, before.POSTGRES_PASSWORD);
    assert.equal(validateOperatorEnv(after, f.state).origin, 'https://api.example.test');
    assert.equal(statSync(f.envPath).mode & 0o777, 0o600);
    assert.deepEqual(readdirSync(join(f.state, 'config')).sort(), ['backup.key', 'compose.env', 'operator.lock'], 'no staged or previous file is left');
    const [apply] = f.applies();
    assertApply(apply, after, before.POSTGRES_PASSWORD);
    assert.equal(readFileSync(f.env.FAKE_CHECK_INPUT, 'utf8').split('\n')[0], after.POSTGRES_PASSWORD, 'the check uses the new values');
    const calls = readFileSync(f.log, 'utf8');
    for (const value of [...roleNames.flatMap(name => [before[name], after[name]]), before.POSTGRES_PASSWORD]) assert.equal(calls.includes(value), false, 'no password in a docker argument');
    const at = needle => { const index = calls.indexOf(needle); assert.ok(index >= 0, needle); return index; };
    assert.ok(at('exec -T db sh -c IFS= read -r pw;') < at('--force-recreate'), 'the database is changed before anything is recreated');
    assert.match(calls, /--profile \* up -d --force-recreate --wait --wait-timeout 180 db rest storage\n/, 'running consumers only');
    assert.ok(at('--force-recreate') < at('superuser_password') && at('superuser_password') < at('pg_isready'), 'then the login check, then the doctor');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('--superuser also replaces POSTGRES_PASSWORD, signing in with the old superuser password', () => {
  const f = fixture('warehouse-rotate-db-superuser-');
  try {
    const beforeText = readFileSync(f.envPath, 'utf8');
    const before = readEnv(f.envPath);
    const result = f.run(['--yes', '--superuser']);
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    const after = readEnv(f.envPath);
    assert.deepEqual(changedLines(beforeText, readFileSync(f.envPath, 'utf8')), ['POSTGRES_PASSWORD', ...roleNames].sort());
    assert.notEqual(after.POSTGRES_PASSWORD, before.POSTGRES_PASSWORD);
    const [apply] = f.applies();
    assertApply(apply, after, before.POSTGRES_PASSWORD, [['supabase_admin_verifier', after.POSTGRES_PASSWORD]]);
    assert.equal(apply.includes(after.POSTGRES_PASSWORD), false, 'the new superuser password travels only as its verifiers');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('a failing database step changes nothing and recreates nothing', () => {
  const f = fixture('warehouse-rotate-db-fail-');
  try {
    const before = readFileSync(f.envPath);
    const result = f.run(['--yes'], { FAKE_FAIL: 'apply' });
    assert.notEqual(result.status, 0);
    assert.deepEqual(readFileSync(f.envPath), before);
    assert.deepEqual(readdirSync(join(f.state, 'config')).sort(), ['backup.key', 'compose.env', 'operator.lock']);
    assert.equal(readFileSync(f.log, 'utf8').includes('--force-recreate'), false);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

for (const [step, superuser] of [['up', false], ['check', false], ['up', true]]) {
  test(`a ${step === 'up' ? 'service that does not come back' : 'login check that fails'} puts the previous values back${superuser ? ' (--superuser)' : ''}`, () => {
    const f = fixture(`warehouse-rotate-db-rollback-${step}-`);
    try {
      const beforeText = readFileSync(f.envPath, 'utf8');
      const before = readEnv(f.envPath);
      const result = f.run(['--yes', ...(superuser ? ['--superuser'] : [])], { FAKE_FAIL: step });
      assert.equal(result.status, 1, result.stdout + result.stderr);
      assert.match(result.stderr, /putting the previous ones back[\s\S]*The previous database passwords are back in place/);
      assert.equal(readFileSync(f.envPath, 'utf8'), beforeText, 'compose.env holds the previous values again');
      assert.deepEqual(readdirSync(join(f.state, 'config')).sort(), ['backup.key', 'compose.env', 'operator.lock']);
      const [forward, back] = f.applies();
      assert.ok(forward && back, 'two database steps: the rotation and its reversal');
      const rotated = Object.fromEntries([...forward.matchAll(/^\\set ([a-z_]+) /gm)].map(match => [match[1], true]));
      assert.ok(Object.keys(rotated).length >= DB_ROLE_LOGINS.length);
      // The reversal sets the previous values, signed in with what the database holds now.
      const signIn = back.split('\n')[0];
      if (superuser) assert.notEqual(signIn, before.POSTGRES_PASSWORD, 'the new superuser password signs in for the reversal');
      else assert.equal(signIn, before.POSTGRES_PASSWORD);
      assertApply(back, before, signIn, superuser ? [['supabase_admin_verifier', before.POSTGRES_PASSWORD]] : []);
      const recreations = readFileSync(f.log, 'utf8').split('\n').filter(line => line.includes('--force-recreate'));
      assert.equal(recreations.length, 2, 'the services are recreated again with the previous values');
    } finally { rmSync(f.scratch, { recursive: true, force: true }); }
  });
}

const STAGED = 'compose.env.rotating-db';
const PREVIOUS = 'compose.env.before-db-rotation';
const NEXT = /Nothing was rotated\. Run bash start\.sh so every service uses these values, check with npm run test:db-roles, then run npm run db:rotate-passwords -- --yes again if you still want new ones\./;
// A leftover file as a stopped rotation leaves it: compose.env with new values for the logins (and the superuser).
function leftover(f, name, { superuser = false } = {}) {
  const fresh = (length = 64) => [...Array(length)].map(() => '0123456789abcdef'[Math.floor(Math.random() * 16)]).join('');
  let text = readFileSync(f.envPath, 'utf8');
  for (const role of roleNames) text = text.replace(new RegExp(`^${role}=.*$`, 'm'), `${role}=${fresh()}`);
  if (superuser) text = text.replace(/^POSTGRES_PASSWORD=.*$/m, `POSTGRES_PASSWORD=${fresh()}`);
  writeFileSync(join(f.state, 'config', name), text, { mode: 0o600 });
  return text;
}

test('a rotation that stopped after its database step leaves the staged file and a message, and the next run puts that file in place', () => {
  for (const [how, extra] of [['a lost connection', { FAKE_FAIL: 'lost' }], ['a signal', { FAKE_FAIL: 'killed' }]]) {
    const f = fixture('warehouse-rotate-db-stopped-');
    try {
      const before = readFileSync(f.envPath, 'utf8');
      const stopped = f.run(['--yes', '--superuser'], extra);
      assert.notEqual(stopped.status, 0, how);
      assert.match(stopped.stderr, new RegExp(`Stopped during or after the database step\\. ${join(f.state, 'config', STAGED).replaceAll('.', '\\.')} is kept: the database may have its values now\\. Run npm run db:rotate-passwords -- --yes again: it finds out which values the database has`), how);
      assert.equal(readFileSync(f.envPath, 'utf8'), before, `${how}: compose.env is not changed`);
      const staged = readFileSync(join(f.state, 'config', STAGED), 'utf8');
      assert.equal(readFileSync(f.database, 'utf8'), staged, `${how}: the database took the staged values`);
      // The next run follows the message: the database decides, and nothing is rotated.
      const next = f.run(['--yes']);
      assert.equal(next.status, 1, next.stdout + next.stderr);
      assert.match(next.stdout, /The database has the values of compose\.env\.rotating-db: it is compose\.env now\./);
      assert.match(next.stdout, NEXT);
      assert.equal(readFileSync(f.envPath, 'utf8'), staged, 'the new superuser password is kept, in compose.env');
      assert.deepEqual(f.config(), ['backup.key', 'compose.env', 'operator.lock']);
      assert.equal(f.applies().length, 1, 'the recovery sets no password');
    } finally { rmSync(f.scratch, { recursive: true, force: true }); }
  }
});

test('recovery keeps whichever file the database matches and removes only the ones it does not', () => {
  const cases = [
    // [leftovers, which one the database has, expected compose.env afterwards, message]
    [[STAGED], 'live', 'live', /The database has the values of compose\.env\.\nRemoved compose\.env\.rotating-db: the database does not have its values\./],
    [[PREVIOUS], 'live', 'live', /Removed compose\.env\.before-db-rotation: the database does not have its values\./],
    [[PREVIOUS], PREVIOUS, PREVIOUS, /The database has the values of compose\.env\.before-db-rotation: it is compose\.env now\./],
    [[STAGED, PREVIOUS], STAGED, STAGED, /it is compose\.env now\.\nRemoved compose\.env\.before-db-rotation/],
  ];
  for (const [names, has, after, message] of cases) {
    const f = fixture('warehouse-rotate-db-recover-');
    try {
      const texts = { live: readFileSync(f.envPath, 'utf8') };
      for (const name of names) texts[name] = leftover(f, name, { superuser: name === STAGED });
      writeFileSync(f.database, texts[has]);
      const result = f.run(['--yes']);
      assert.equal(result.status, 1, `${names} / ${has}: ${result.stdout}${result.stderr}`);
      assert.match(result.stdout, message, `${names} / ${has}`);
      assert.match(result.stdout, NEXT);
      assert.equal(readFileSync(f.envPath, 'utf8'), texts[after], `${names} / ${has}: compose.env`);
      assert.deepEqual(f.config(), ['backup.key', 'compose.env', 'operator.lock'], `${names} / ${has}: leftovers`);
      assert.equal(f.applies().length, 0, 'no password is set');
      assert.equal(readFileSync(f.log, 'utf8').includes('--force-recreate'), false, 'nothing is recreated');
    } finally { rmSync(f.scratch, { recursive: true, force: true }); }
  }
});

test('recovery changes nothing when the database takes none of the files or gives no answer', () => {
  for (const [what, database, message] of [
    ['none of the files', 'unrelated', /Refusing: the database takes the values of none of compose\.env and compose\.env\.rotating-db compose\.env\.before-db-rotation\. Nothing was changed\./],
    ['no answer', null, /Refusing: the database gave no clear answer for compose\.env\. Nothing was changed/],
  ]) {
    const f = fixture('warehouse-rotate-db-unclear-');
    try {
      const live = readFileSync(f.envPath, 'utf8');
      const staged = leftover(f, STAGED, { superuser: true });
      const previous = leftover(f, PREVIOUS);
      if (database) writeFileSync(f.database, live.replace(/^DB_PASSWORD_AUTHENTICATOR=.*$/m, `DB_PASSWORD_AUTHENTICATOR=${'f'.repeat(64)}`));
      else rmSync(f.database);
      const result = f.run(['--yes']);
      assert.equal(result.status, 1, what);
      assert.match(result.stderr, message, what);
      assert.equal(readFileSync(f.envPath, 'utf8'), live, `${what}: compose.env kept`);
      assert.equal(readFileSync(join(f.state, 'config', STAGED), 'utf8'), staged, `${what}: staged file kept`);
      assert.equal(readFileSync(join(f.state, 'config', PREVIOUS), 'utf8'), previous, `${what}: previous file kept`);
      assert.equal(f.applies().length, 0);
    } finally { rmSync(f.scratch, { recursive: true, force: true }); }
  }
});

test('a reversal that fails too leaves compose.env with the values the database has, and the next run cleans up', () => {
  const f = fixture('warehouse-rotate-db-reversal-');
  try {
    const before = readFileSync(f.envPath, 'utf8');
    const result = f.run(['--yes', '--superuser'], { FAKE_FAIL: 'up', FAKE_FAIL_REVERSAL: 'yes' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /putting the previous ones back[\s\S]*Could not put the previous passwords back\. compose\.env holds the new values and .*compose\.env\.before-db-rotation the previous ones; which ones the database has is checked by the next run\. Fix the cause above, then run npm run db:rotate-passwords -- --yes again/);
    const after = readFileSync(f.envPath, 'utf8');
    assert.notEqual(after, before, 'compose.env holds the new values');
    assert.equal(readFileSync(f.database, 'utf8'), after, 'and the database has them');
    assert.equal(readFileSync(join(f.state, 'config', PREVIOUS), 'utf8'), before, 'the previous values are kept');
    assert.equal(f.applies().length, 2, 'the rotation and the failed reversal');
    const next = f.run(['--yes']);
    assert.equal(next.status, 1);
    assert.match(next.stdout, /The database has the values of compose\.env\.\nRemoved compose\.env\.before-db-rotation: the database does not have its values\./);
    assert.match(next.stdout, NEXT);
    assert.equal(readFileSync(f.envPath, 'utf8'), after);
    assert.deepEqual(f.config(), ['backup.key', 'compose.env', 'operator.lock']);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('a doctor that fails after the rotation puts the previous values back', () => {
  const f = fixture('warehouse-rotate-db-doctor-');
  try {
    const before = readFileSync(f.envPath, 'utf8');
    const result = f.run(['--yes'], { FAKE_FAIL: 'doctor' });
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.match(result.stderr, /Local service health check failed[\s\S]*putting the previous ones back[\s\S]*The previous database passwords are back in place/);
    assert.equal(readFileSync(f.envPath, 'utf8'), before);
    assert.equal(readFileSync(f.database, 'utf8'), before, 'the database has the previous values again');
    assert.deepEqual(f.config(), ['backup.key', 'compose.env', 'operator.lock']);
    const calls = readFileSync(f.log, 'utf8');
    assert.ok(calls.indexOf('superuser_password') < calls.indexOf('exec -T db pg_isready'), 'the login check passed before the doctor ran');
    assert.equal(calls.split('\n').filter(line => line.includes('--force-recreate')).length, 2);
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});

test('a failing database step that the database confirms changed nothing removes the staged file', () => {
  const f = fixture('warehouse-rotate-db-confirmed-');
  try {
    const result = f.run(['--yes', '--superuser'], { FAKE_FAIL: 'apply' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /The database step failed and changed nothing \(the database still has the values of compose\.env\)\./);
    assert.deepEqual(f.config(), ['backup.key', 'compose.env', 'operator.lock']);
    assert.match(readFileSync(f.log, 'utf8'), /verdict\(\)/, 'the database was asked');
  } finally { rmSync(f.scratch, { recursive: true, force: true }); }
});
