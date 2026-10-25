import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// scripts/break-glass-admin.sh with a stand-in docker: what it asks the database, what it prints, and when it refuses.
// The real function is proved in tests/break_glass.sql against a real database. The script prints the code to a terminal only; these
// tests read a pipe, so they pass --to-stdout (the tty tests below run it on a pseudo-terminal with script(1) instead).
const root = new URL('..', import.meta.url).pathname;

function run(args, { answer = '', fail = '', env = {}, toStdout = true, wrap = null } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-break-glass-test-'));
  try {
    const state = join(scratch, 'state');
    for (const path of [state, join(state, 'config'), join(state, 'data'), join(state, 'data/db'), join(state, 'data/storage')]) mkdirSync(path, { recursive: true, mode: 0o700 });
    writeFileSync(join(state, 'config/compose.env'), `WAREHOUSE_PROJECT_NAME=warehouse-glass-test\nWAREHOUSE_DB_PATH=${state}/data/db\nWAREHOUSE_STORAGE_PATH=${state}/data/storage\n`, { mode: 0o600 });
    const bin = join(scratch, 'bin');
    mkdirSync(bin);
    const log = join(scratch, 'docker.log');
    const sent = join(scratch, 'sql-stdin');
    writeFileSync(join(bin, 'docker'), `#!/bin/sh
case "$*" in
  *'exec -T db psql'*)
    printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
    cat > "$FAKE_STDIN"
    if [ -n "$FAKE_FAIL" ]; then printf '%s\\n' "$FAKE_FAIL" >&2; exit 3; fi
    printf '%s' "$FAKE_ANSWER" ;;
esac
`, { mode: 0o700 });
    const scriptArgs = [join(root, 'scripts/break-glass-admin.sh'), ...(toStdout ? ['--to-stdout'] : []), ...args];
    const [command, commandArgs] = wrap ? wrap(scriptArgs) : ['bash', scriptArgs];
    const result = spawnSync(command, commandArgs, {
      encoding: 'utf8',
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: log, FAKE_STDIN: sent, FAKE_ANSWER: answer, FAKE_FAIL: fail, ...env },
    });
    const read = path => (existsSync(path) ? readFileSync(path, 'utf8') : '');
    return { ...result, docker: read(log), sql: read(sent) };
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

test('prints the code once with the warning, and asks the database for exactly that administrator', () => {
  const result = run(['9888888911'], { answer: '482910\tBreak Glass Administrator\n' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.split('482910').length - 1, 1, 'the code is printed once');
  assert.match(result.stdout, /This code signs in the admin Break Glass Administrator on any phone within 10 minutes; use it only when SMS is down\./);
  assert.equal(result.stderr, '');
  assert.match(result.docker, /-v phone=9888888911/);
  assert.match(result.docker, /-U supabase_admin/);
  assert.match(result.sql, /warehouse_security\.break_glass_code\(:'phone'\)/, 'the number goes in as a psql variable, quoted by psql');
  assert.doesNotMatch(result.sql + result.docker, /482910/, 'the code is never sent to the database or put on a command line');
});

test('accepts the number in the forms people type, and sends the 10 digits', () => {
  for (const typed of ['+91 98888 88911', '919888888911', '98888-88911']) {
    const result = run([typed], { answer: '000123\tAsha Patel\n' });
    assert.equal(result.status, 0, `${typed}: ${result.stderr}`);
    assert.match(result.docker, /-v phone=9888888911(\s|$)/, typed);
  }
});

test('refuses a number that is not an active administrator, and prints no code', () => {
  const result = run(['9888888914'], { fail: 'ERROR:  No active, approved administrator has this phone number\nCONTEXT:  PL/pgSQL function warehouse_security.break_glass_code(text) line 14 at RAISE' });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /^Refused: No active, approved administrator has this phone number\.$/m);
});

test('says so when the database does not answer, and shows no code', () => {
  const result = run(['9888888911'], { fail: 'psql: error: connection to server on socket failed' });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /The database did not answer; no code was made/);
  assert.match(result.stderr, /connection to server/);
});

test('shows nothing when the answer is not a six-digit code', () => {
  for (const answer of ['', 'abc\tName\n', '12345\tName\n', '1234567\tName\n']) {
    const result = run(['9888888911'], { answer });
    assert.equal(result.status, 1, JSON.stringify(answer));
    assert.doesNotMatch(result.stdout, /\d{5,}/, JSON.stringify(answer));
    assert.match(result.stderr, /unexpected/);
  }
});

test('refuses a missing or malformed number before it touches the database', () => {
  for (const args of [[], ['abc'], ['98888'], ['9888888911', 'extra'], ['12345678901234']]) {
    const result = run(args, { answer: '482910\tX\n' });
    assert.equal(result.status, 2, JSON.stringify(args));
    assert.equal(result.docker, '', `no database call for ${JSON.stringify(args)}`);
    assert.equal(result.stdout, '');
  }
});

test('refuses to print the code when standard output is not a terminal, and does not touch the database', () => {
  const result = run(['9888888911'], { answer: '482910\tBreak Glass Administrator\n', toStdout: false });
  assert.equal(result.status, 2);
  assert.equal(result.stdout, '');
  assert.doesNotMatch(result.stderr, /482910/);
  assert.match(result.stderr, /standard output is not a terminal/);
  assert.match(result.stderr, /--to-stdout/);
  assert.equal(result.docker, '', 'no database call, so no code was made');
});

const hasScript = spawnSync('script', ['--version'], { encoding: 'utf8' }).status === 0;
test('prints the code on a terminal without any flag', { skip: !hasScript && 'script(1) is not installed' }, () => {
  // script(1) runs the command on a pseudo-terminal and copies what it writes to its own stdout (with CR LF line ends).
  const result = run(['9888888911'], {
    answer: '482910\tBreak Glass Administrator\n', toStdout: false,
    wrap: scriptArgs => ['script', ['-qec', ['bash', ...scriptArgs].map(a => `'${a}'`).join(' '), '/dev/null']],
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(result.stdout.split('482910').length - 1, 1, 'the code is printed once');
  assert.match(result.stdout, /use it only when SMS is down\./);
});

test('the code screen advice names mobile data for an address at its limit', () => {
  const result = run(['9888888911'], { answer: '482910\tBreak Glass Administrator\n' });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Too many OTP requests.*switch the phone from the facility Wi-Fi to mobile data/s);
});
