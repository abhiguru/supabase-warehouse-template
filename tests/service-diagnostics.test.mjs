import test from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { mkdtempSync, mkdirSync, symlinkSync, readdirSync, readFileSync, statSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { SAVE_TAIL_LINES, cutSince, diagnoseService, redactServiceLog, saveLogs, showUnhealthyServices } from '../scripts/service-diagnostics.mjs';

test('service diagnostics redact literal, URL and JSON encoded credentials', () => {
  const secret = 'fictional p@ss"\\word';
  const variants = [secret, encodeURIComponent(secret), JSON.stringify(secret).slice(1, -1)];
  const result = redactServiceLog(variants.join('\n'), { POSTGRES_PASSWORD: secret });
  for (const value of variants) assert.ok(!result.includes(value));
  assert.match(result, /REDACTED/);
});

test('service diagnostics hide derived JWTs and database URL passwords', () => {
  const part = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const token = [part({ alg: 'HS256' }), part({ sub: 'fictional' }), 'test_signature'].join('.');
  const text = `${token} ecto://admin:fictional-derived-secret@db/postgres`;
  const result = redactServiceLog(text, {});
  assert.ok(!result.includes('test_signature'));
  assert.ok(!result.includes('fictional-derived-secret'));
  assert.match(result, /@db\/postgres/);
});

test('service diagnostics preserve useful errors and handle empty values', () => {
  assert.equal(redactServiceLog('connection refused at db:5432', { JWT_SECRET: '', POSTGRES_HOST: 'db' }), 'connection refused at db:5432');
});

test('diagnostics refuse unknown services and failed ownership before reading logs', () => {
  const calls = [];
  const report = [];
  const options = { run: (...args) => { calls.push(args); return { status: 1 }; }, report: line => report.push(line) };
  diagnoseService('unrelated', options);
  assert.equal(calls.length, 0);
  diagnoseService('functions', options);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], 'bash');
  assert.ok(report.every(line => line.includes('unavailable')));
});

test('owned gateway diagnostics expose only selected state and redacted bounded logs', () => {
  const calls = [];
  const output = [];
  diagnoseService('functions', {
    run: (command, args) => {
      calls.push([command, args]);
      if (command === 'bash') return { status: 0, stdout: 'a'.repeat(64) };
      if (args[0] === 'inspect') return { status: 0, stdout: JSON.stringify({ Status: 'running', ExitCode: 0, OOMKilled: false, Health: { Status: 'healthy', Log: ['private'] } }) };
      return { status: 0, stdout: 'worker unavailable fictional-secret' };
    },
    env: () => ({ JWT_SECRET: 'fictional-secret' }),
    report: line => output.push(line),
  });
  assert.deepEqual(calls[0][1].slice(-4), ['ps', '-a', '-q', 'functions']);
  assert.deepEqual(calls[2][1].slice(0, 3), ['logs', '--tail', '60']);
  assert.ok(output.join('\n').includes('worker unavailable [REDACTED]'));
  assert.ok(!output.join('\n').includes('private'));
});

test('the unhealthy-service listing skips healthy services and redacts the last 30 log lines of the rest', () => {
  const calls = [];
  const output = [];
  showUnhealthyServices({
    run: (command, args) => {
      calls.push(args);
      if (args.includes('ps')) return { status: 0, stdout: 'db running healthy\nrest running\ngateway exited \nfunctions running unhealthy\n' };
      return { status: 0, stdout: `log of ${args.at(-1)} fictional-secret` };
    },
    env: () => ({ JWT_SECRET: 'fictional-secret' }),
    report: line => output.push(line),
  });
  assert.deepEqual(output.filter(line => line.startsWith('Service')), ['Service gateway is exited. Its last log lines:', 'Service functions is running (unhealthy). Its last log lines:']);
  assert.ok(output.every(line => !line.includes('fictional-secret')));
  assert.ok(calls.filter(args => args.includes('logs')).every(args => args.includes('--tail') && args.includes('30')));
  assert.equal(calls.filter(args => args.includes('logs')).length, 2);
  const quiet = [];
  showUnhealthyServices({ run: () => ({ status: 1 }), env: () => ({}), report: line => quiet.push(line) });
  assert.deepEqual(quiet, []);
});

// ---- saveLogs: the logs kept before a recreate ----
const SECRET = 'fictional-save-secret-value';
const freshState = () => mkdtempSync(join(tmpdir(), 'save-logs-'));
const modeOf = path => statSync(path).mode & 0o777;
const okRun = calls => (command, args) => { calls.push(args); return { status: 0, stdout: `2026-11-01T10:00:00Z ${args.at(-1)} line ${SECRET}\n`, stderr: '' }; };

test('saveLogs writes each allowed service log, redacted, in a private pre-<label>-<utc> directory under the state', () => {
  const state = freshState();
  const calls = [], said = [];
  try {
    saveLogs({ label: 'upgrade', stateDir: state, run: okRun(calls), env: () => ({ JWT_SECRET: SECRET }), now: () => new Date('2026-11-01T10:20:30.123Z'), report: line => said.push(line) });
    const dir = join(state, 'diagnostics', 'pre-upgrade-20261101T102030Z');
    assert.deepEqual(readdirSync(dir).sort(), ['functions.log', 'gateway-lan.log', 'gateway.log', 'lan-signer.log', 'rest.log', 'supavisor.log']);
    assert.equal(modeOf(join(state, 'diagnostics')), 0o700);
    assert.equal(modeOf(dir), 0o700);
    for (const name of readdirSync(dir)) {
      assert.equal(modeOf(join(dir, name)), 0o600, name);
      const text = readFileSync(join(dir, name), 'utf8');
      assert.ok(!text.includes(SECRET), `${name} is redacted`);
      assert.match(text, /\[REDACTED\]/);
    }
    // No --since (some Docker versions return nothing for it): a bounded tail, cut by the time stamps below.
    for (const args of calls) assert.deepEqual(args.slice(args.indexOf('logs')).slice(0, 5), ['logs', '--timestamps', '--no-color', '--tail', String(SAVE_TAIL_LINES)]);
    assert.ok(calls.every(args => !args.includes('--since')));
    assert.ok(calls.some(args => args.includes('--profile') && args.includes('pooler')) && calls.some(args => args.includes('lan')), 'profile services are asked with their profile');
    assert.equal(said.length, 1);
  } finally { rmSync(state, { recursive: true, force: true }); }
});

test('saveLogs keeps the newest 5 pre-* directories and leaves other entries alone', () => {
  const state = freshState();
  try {
    const base = join(state, 'diagnostics');
    mkdirSync(base, { recursive: true });
    for (let day = 1; day <= 6; day += 1) mkdirSync(join(base, `pre-rotate-keys-2026100${day}T010000Z`));
    mkdirSync(join(base, 'notes'));
    saveLogs({ label: 'upgrade', stateDir: state, run: okRun([]), env: () => ({}), now: () => new Date('2026-11-01T10:00:00Z'), report: () => {} });
    const left = readdirSync(base).sort();
    // The newest pre-upgrade-* directory is outside the count (it is the one just written here), so five others stay beside it.
    assert.deepEqual(left, ['notes', 'pre-rotate-keys-20261002T010000Z', 'pre-rotate-keys-20261003T010000Z', 'pre-rotate-keys-20261004T010000Z', 'pre-rotate-keys-20261005T010000Z', 'pre-rotate-keys-20261006T010000Z', 'pre-upgrade-20261101T100000Z']);
  } finally { rmSync(state, { recursive: true, force: true }); }
});

test('saveLogs is best effort: a failing compose, a bad label or a bad state print one line, leave nothing behind and do not throw', () => {
  const state = freshState();
  try {
    const said = [];
    saveLogs({ label: 'upgrade', stateDir: state, run: () => ({ status: 1, stdout: '', stderr: 'no such service' }), env: () => ({}), report: line => said.push(line) });
    assert.equal(said.length, 1);
    assert.deepEqual(readdirSync(join(state, 'diagnostics')), [], 'an empty attempt is not kept');
    saveLogs({ label: '../x', stateDir: state, run: okRun([]), env: () => ({}), report: line => said.push(line) });
    saveLogs({ label: 'ok', stateDir: 'relative/path', run: okRun([]), env: () => ({}), report: line => said.push(line) });
    saveLogs({ label: 'ok', stateDir: state, run: () => { throw new Error('docker missing'); }, env: () => ({}), report: line => said.push(line) });
    saveLogs({ label: 'ok', stateDir: state, run: okRun([]), env: () => { throw new Error('no env'); }, report: line => said.push(line) });
    assert.equal(said.length, 5);
    assert.ok(said.every(line => !line.includes('\n')));
    assert.deepEqual(readdirSync(join(state, 'diagnostics')), []);
  } finally { rmSync(state, { recursive: true, force: true }); }
});

test('the save command exits 0 even when it can save nothing', () => {
  const state = freshState();
  try {
    const result = spawnSync(process.execPath, [fileURLToPath(new URL('../scripts/service-diagnostics.mjs', import.meta.url)), 'save', 'upgrade'], { encoding: 'utf8', env: { PATH: '/nonexistent', WAREHOUSE_STATE_DIR: state }, timeout: 60000 });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr.trim().split('\n').length, 1);
    assert.equal(existsSync(join(state, 'diagnostics')) ? readdirSync(join(state, 'diagnostics')).length : 0, 0);
  } finally { rmSync(state, { recursive: true, force: true }); }
});

test('saveLogs cuts each log by its time stamps: lines older than the window go, a line without a stamp follows the one before it', () => {
  const text = ['gateway-1  | 2026-10-29T10:00:00.000000000Z old', 'continuation of old', 'gateway-1  | 2026-10-31T11:00:00.5Z new', 'continuation of new', '2026-11-01T01:00:00Z bare'].join('\n');
  assert.equal(cutSince(text, Date.parse('2026-10-30T10:00:00Z')), ['gateway-1  | 2026-10-31T11:00:00.5Z new', 'continuation of new', '2026-11-01T01:00:00Z bare'].join('\n'));
  const state = freshState();
  try {
    saveLogs({ label: 'cut', stateDir: state, run: () => ({ status: 0, stdout: text, stderr: '' }), env: () => ({}), now: () => new Date('2026-11-01T10:00:00Z'), report: () => {} });
    const file = join(state, 'diagnostics', 'pre-cut-20261101T100000Z', 'rest.log');
    assert.ok(!readFileSync(file, 'utf8').includes('old'));
  } finally { rmSync(state, { recursive: true, force: true }); }
});

test('saveLogs keeps what it could read when one service fails, and leaves a symlinked diagnostics folder alone', () => {
  const state = freshState();
  try {
    const said = [];
    saveLogs({ label: 'partial', stateDir: state, run: (command, args) => (args.includes('functions') ? { status: 1, stdout: '', stderr: 'boom' } : { status: 0, stdout: '2026-11-01T09:00:00Z ok\n', stderr: '' }),
      env: () => ({}), now: () => new Date('2026-11-01T10:00:00Z'), report: line => said.push(line) });
    assert.deepEqual(readdirSync(join(state, 'diagnostics', 'pre-partial-20261101T100000Z')).sort(), ['gateway-lan.log', 'gateway.log', 'lan-signer.log', 'rest.log', 'supavisor.log']);
    const elsewhere = freshState(), linked = freshState();
    symlinkSync(elsewhere, join(linked, 'diagnostics'));
    saveLogs({ label: 'link', stateDir: linked, run: okRun([]), env: () => ({}), report: line => said.push(line) });
    assert.deepEqual(readdirSync(elsewhere), [], 'nothing was written through the link');
    assert.match(said.at(-1), /not saved/);
    rmSync(elsewhere, { recursive: true, force: true }); rmSync(linked, { recursive: true, force: true });
  } finally { rmSync(state, { recursive: true, force: true }); }
});

test('saveLogs never removes the newest pre-upgrade directory, whatever the count; five others stay', () => {
  const state = freshState();
  try {
    const base = join(state, 'diagnostics');
    mkdirSync(base, { recursive: true });
    mkdirSync(join(base, 'pre-upgrade-20260901T010000Z'));
    for (let day = 1; day <= 6; day += 1) mkdirSync(join(base, `pre-rotate-keys-2026100${day}T010000Z`));
    saveLogs({ label: 'setup', stateDir: state, run: okRun([]), env: () => ({}), now: () => new Date('2026-11-01T10:00:00Z'), report: () => {} });
    const left = readdirSync(base).sort();
    assert.ok(left.includes('pre-upgrade-20260901T010000Z'), 'the oldest by date, but the only upgrade one, stays');
    assert.equal(left.length, 6, 'the upgrade one and five others');
    assert.ok(left.includes('pre-setup-20261101T100000Z') && !left.includes('pre-rotate-keys-20261001T010000Z'));
  } finally { rmSync(state, { recursive: true, force: true }); }
});

test('redaction removes a query string from a quoted request line, and the referer and user agent PostgREST appends', () => {
  const nginx = '2026/11/01 10:00:00 [error] 30#30: *3 upstream timed out (110: Operation timed out), client: 10.0.0.3, server: _, request: "GET /storage/v1/object/sign/docs/a.pdf?token=eyJsecretvalue&x=1 HTTP/1.1", upstream: "http://storage_up/object/sign/docs/a.pdf?token=eyJsecretvalue", host: "gateway:8000", referrer: "https://app.example.test/?q=1"';
  const cleaned = redactServiceLog(nginx, {});
  assert.ok(!cleaned.includes('secretvalue') && !cleaned.includes('x=1') && !cleaned.includes('referrer'), cleaned);
  assert.match(cleaned, /request: "GET \/storage\/v1\/object\/sign\/docs\/a\.pdf\?\[REDACTED\] HTTP\/1\.1"/);
  assert.match(cleaned, /client: 10\.0\.0\.3/, 'the rest of the line stays');
  const rest = '172.18.0.5 - authenticated [01/Nov/2026:10:00:00 +0000] "GET /customers?select=name&mobile=eq.919888888871 HTTP/1.1" 500 - "https://app.example.test/x" "Mozilla/5.0 (Phone)"';
  const cleanedRest = redactServiceLog(rest, {});
  assert.equal(cleanedRest, '172.18.0.5 - authenticated [01/Nov/2026:10:00:00 +0000] "GET /customers?[REDACTED] HTTP/1.1" 500 -');
  assert.equal(redactServiceLog('"GET /rest/v1/x HTTP/1.1" 200 12 0.01 0123456789abcdef0123456789abcdef', {}), '"GET /rest/v1/x HTTP/1.1" 200 12 0.01 0123456789abcdef0123456789abcdef', 'a gateway line is untouched');
});
