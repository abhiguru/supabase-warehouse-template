import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// scripts/migrate.sh around the psql call: a plan that fails with 55P03 (a migration waited longer than its lock_timeout and rolled back)
// is run again, three attempts in all; any other error stops at once. The database is a fake `docker` that answers `exec -T db psql`
// from FAKE_PSQL_RESULTS (one outcome per call: ok, lock, sqlstate, notice or other) and counts the calls; lock is the English message
// alone (the fallback), sqlstate what psql prints with VERBOSITY=verbose in a language the script cannot read. tests/migrations.sh proves the same against
// a real database with a real lock.
const root = new URL('..', import.meta.url).pathname;

function world() {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-migrate-retry-'));
  const state = join(scratch, 'state');
  for (const path of [state, join(state, 'config'), join(state, 'public'), join(state, 'data'), join(state, 'data/db'), join(state, 'data/storage')]) mkdirSync(path, { recursive: true, mode: 0o700 });
  writeFileSync(join(state, 'config/compose.env'), `WAREHOUSE_PROJECT_NAME=warehouse-retry-test\nWAREHOUSE_DB_PATH=${state}/data/db\nWAREHOUSE_STORAGE_PATH=${state}/data/storage\n`, { mode: 0o600 });
  writeFileSync(join(state, 'public/instance.json'), '{"schemaVersion":1}\n');
  const bin = join(scratch, 'bin');
  mkdirSync(bin);
  const calls = join(scratch, 'calls');
  writeFileSync(join(bin, 'docker'), `#!/bin/sh
case "$*" in *'exec -T db psql'*) ;; *) exit 0 ;; esac
cat > /dev/null
echo x >> "${calls}"
echo "$*" >> "${calls}.args"
n=$(wc -l < "${calls}")
outcome=$(echo "$FAKE_PSQL_RESULTS" | cut -d, -f"$n")
case "$outcome" in
  lock) echo 'psql:<stdin>:40: ERROR:  canceling statement due to lock timeout' >&2; exit 3 ;;
  sqlstate) printf 'psql:<stdin>:40: ERROR:  55P03: la requete a ete annulee (verrou)\\nLOCATION:  ProcSleep, proc.c:1500\\n' >&2; exit 3 ;;
  notice) printf 'psql:<stdin>:12: NOTICE:  00000: note about SQLSTATE 55P03 and a lock timeout\\nLOCATION:  exec_stmt_raise, pl_exec.c:3921\\npsql:<stdin>:41: ERROR:  42601: syntax error at or near "BOOM"\\nLOCATION:  scanner_yyerror, scan.l:1188\\n' >&2; exit 3 ;;
  other) echo 'psql:<stdin>:41: ERROR:  syntax error at or near "BOOM"' >&2; exit 3 ;;
esac
exit 0
`, { mode: 0o700 });
  const run = (results, extra = {}) => {
    rmSync(calls, { force: true });
    rmSync(`${calls}.args`, { force: true });
    const r = spawnSync('bash', [join(root, 'scripts/migrate.sh'), '--operator'], { encoding: 'utf8',
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_PSQL_RESULTS: results, WAREHOUSE_MIGRATE_RETRY_SECONDS: '0', ...extra } });
    return { ...r, args: existsSync(`${calls}.args`) ? readFileSync(`${calls}.args`, 'utf8') : '', attempts: existsSync(calls) ? readFileSync(calls, 'utf8').split('\n').filter(Boolean).length : 0 };
  };
  return { run, cleanup: () => rmSync(scratch, { recursive: true, force: true }) };
}

test('a lock timeout (55P03) runs the plan again, up to three attempts, and the second attempt can finish the upgrade', () => {
  const w = world();
  try {
    const r = w.run('lock,ok');
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.attempts, 2);
    assert.match(r.stderr, /ERROR:  canceling statement due to lock timeout/, 'the database\'s message is shown');
    assert.match(r.stderr, /waited more than 10 s for a lock and was rolled back whole \(attempt 1 of 3\)\. Trying again in 0 s; the files already applied are skipped\./);
    const third = w.run('lock,lock,ok');
    assert.equal(third.status, 0, third.stderr);
    assert.equal(third.attempts, 3);
  } finally { w.cleanup(); }
});

test('the lock timeout is recognised by its SQLSTATE, whatever the language of the message; the operator sees the messages without the code and LOCATION lines', () => {
  const w = world();
  try {
    const r = w.run('sqlstate,sqlstate,ok');
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.attempts, 3, 'both timeouts were retried');
    assert.match(r.args, /-v VERBOSITY=verbose/, 'psql is asked to print the SQLSTATE');
    assert.match(r.stderr, /ERROR:  la requete a ete annulee \(verrou\)/, 'the database\'s message is shown');
    assert.doesNotMatch(r.stderr, /55P03:|LOCATION:/, 'without the code and the source location');
    assert.match(r.stderr, /attempt 2 of 3/);
  } finally { w.cleanup(); }
});

test('a NOTICE that mentions a lock timeout is not one, and a different SQLSTATE is not retried', () => {
  const w = world();
  try {
    const r = w.run('notice,ok');
    assert.equal(r.status, 3);
    assert.equal(r.attempts, 1);
    assert.doesNotMatch(r.stderr, /Trying again|could not get its lock/);
    assert.match(r.stderr, /NOTICE:  note about SQLSTATE 55P03 and a lock timeout/, 'notices stay readable');
    assert.match(r.stderr, /ERROR:  syntax error at or near "BOOM"/);
  } finally { w.cleanup(); }
});

test('three lock timeouts in a row stop with a message that says what to do; any other error stops at once', () => {
  const w = world();
  try {
    const locked = w.run('lock,lock,lock,ok');
    assert.equal(locked.status, 3, 'psql\'s own exit status is kept');
    assert.equal(locked.attempts, 3, 'never a fourth');
    assert.match(locked.stderr, /could not get its lock in three attempts[^]*Nothing of that file was applied\. Wait for that session to end/);
    const other = w.run('other,ok');
    assert.equal(other.status, 3);
    assert.equal(other.attempts, 1, 'an error that is not a lock timeout is not retried');
    assert.match(other.stderr, /syntax error at or near "BOOM"/);
    assert.doesNotMatch(other.stderr, /Trying again/);
  } finally { w.cleanup(); }
});

test('the pause between attempts must be a whole number of seconds', () => {
  const w = world();
  try {
    const r = w.run('ok', { WAREHOUSE_MIGRATE_RETRY_SECONDS: 'soon' });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /WAREHOUSE_MIGRATE_RETRY_SECONDS must be a whole number of seconds/);
    assert.equal(r.attempts, 0);
  } finally { w.cleanup(); }
});
