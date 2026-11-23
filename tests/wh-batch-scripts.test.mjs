import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Small checks for the 2026-11 batch: WH-116 install-cosign.sh and upgrade.sh --unsigned, WH-119 setup options, WH-47 contract text.
const root = new URL('..', import.meta.url).pathname;
const read = path => readFileSync(join(root, path), 'utf8');

function installWorld(curl) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-install-cosign-'));
  const bin = join(scratch, 'bin');
  const state = join(scratch, 'state');
  mkdirSync(bin);
  mkdirSync(state);
  const shim = (name, body) => { writeFileSync(join(bin, name), `#!/bin/bash\n${body}\n`); chmodSync(join(bin, name), 0o755); };
  shim('curl', `echo "curl $*" >> "${scratch}/curl.log"\nout=''; while [ $# -gt 0 ]; do if [ "$1" = --output ]; then out="$2"; fi; shift; done\n${curl}`);
  shim('uname', 'echo "${FAKE_ARCH:-x86_64}"');
  const run = (args = [state], env = {}) => spawnSync('bash', [join(root, 'scripts/install-cosign.sh'), ...args], { encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: '', ...env } });
  return { scratch, state, run, curlLog: () => (existsSync(join(scratch, 'curl.log')) ? readFileSync(join(scratch, 'curl.log'), 'utf8') : ''), clean: () => rmSync(scratch, { recursive: true, force: true }) };
}

test('install-cosign.sh pins the version of release.yml and a SHA-256 for each architecture', () => {
  const script = read('scripts/install-cosign.sh');
  const version = /^VERSION=(v\d+\.\d+\.\d+)$/m.exec(script)?.[1];
  assert.ok(version);
  assert.match(script, /^SHA_AMD64=[0-9a-f]{64}$/m);
  assert.match(script, /^SHA_ARM64=[0-9a-f]{64}$/m);
  assert.notEqual(/^SHA_AMD64=(.*)$/m.exec(script)[1], /^SHA_ARM64=(.*)$/m.exec(script)[1]);
  assert.match(read('.github/workflows/release.yml'), new RegExp(`cosign-release: ${version.replaceAll('.', '\\.')}`), 'the workflow signs with the same cosign the facilities verify with');
  assert.match(script, /--proto '=https' --proto-redir '=https' --tlsv1\.2/, 'the download is https only');
});

test('install-cosign.sh refuses without an absolute state directory, and installs nothing when the download does not match the pinned SHA-256', () => {
  const w = installWorld('printf "not the real cosign" > "$out"');
  try {
    for (const args of [[], ['relative/state'], [join(w.scratch, 'missing')]]) {
      const r = w.run(args);
      assert.equal(r.status, 1, args.join(' '));
      assert.match(r.stderr, /give the absolute path of the operator state/);
    }
    assert.equal(w.curlLog(), '', 'nothing was downloaded');
    const r = w.run();
    assert.equal(r.status, 1, r.stdout + r.stderr);
    assert.match(r.stderr, /the downloaded cosign does not match the pinned SHA-256, so it is not installed/);
    assert.match(w.curlLog(), /https:\/\/github\.com\/sigstore\/cosign\/releases\/download\/v\d+\.\d+\.\d+\/cosign-linux-amd64/);
    assert.equal(existsSync(join(w.state, 'bin/cosign')), false, 'no binary');
    assert.deepEqual(readdirSync(join(w.state, 'bin')), [], 'and no temporary file is left');
  } finally { w.clean(); }
});

test('install-cosign.sh: the arm64 asset on an arm64 host, and a failed download is refused', () => {
  const arm = installWorld('printf x > "$out"');
  try {
    arm.run([arm.state], { FAKE_ARCH: 'aarch64' });
    assert.match(arm.curlLog(), /cosign-linux-arm64/);
    const odd = arm.run([arm.state], { FAKE_ARCH: 'riscv64' });
    assert.equal(odd.status, 1);
    assert.match(odd.stderr, /no pinned checksum for this architecture/);
  } finally { arm.clean(); }
  const failing = installWorld('exit 22');
  try {
    const r = failing.run();
    assert.equal(r.status, 1);
    assert.match(r.stderr, /^Refusing: cosign v\d+\.\d+\.\d+ could not be downloaded: HTTP error from github\.com\. Without cosign the release images will NOT be signature-checked\. Run /m);
    assert.equal(existsSync(join(failing.state, 'bin/cosign')), false);
  } finally { failing.clean(); }
});

test('upgrade.sh --unsigned sets WAREHOUSE_UNSIGNED and says so; setup.sh installs cosign only for a tree with docker/images-signed', () => {
  const upgrade = read('upgrade.sh');
  assert.match(upgrade, /--unsigned\) export WAREHOUSE_UNSIGNED=yes; echo "Warning: --unsigned:/);
  assert.match(upgrade, /Usage: bash upgrade\.sh \[--dry-run\] \[--yes\] \[--unsigned\]/);
  const setup = read('setup.sh');
  assert.match(setup, /if \[\[ -f "\$ROOT\/docker\/images-signed" \]\] && ! command -v cosign >\/dev\/null && \[\[ ! -x "\$STATE\/bin\/cosign" \]\]; then/);
  assert.equal(existsSync(join(root, 'docker/images-signed')), true);
});

test('setup.sh: the SMS ceilings are options, validated before anything is written, and handed to configure-sms-ceiling.sql', () => {
  const setup = read('setup.sh');
  assert.match(setup, /--sms-hourly-ceiling\|--sms-daily-ceiling\)/);
  assert.match(setup, /\^\[1-9\]\[0-9\]\{0,5\}\$/, 'the hourly ceiling is 1 to 999999');
  assert.match(setup, /\^\[1-9\]\[0-9\]\{0,6\}\$/, 'the daily ceiling is 1 to 9999999');
  assert.match(setup, /-v sms_hourly="\$SMS_HOURLY" -v sms_daily="\$SMS_DAILY" < "\$ROOT\/scripts\/configure-sms-ceiling\.sql"/);
  assert.ok(setup.indexOf('The hourly SMS ceiling (--sms-hourly-ceiling) must be') < setup.lastIndexOf('configure-sms-ceiling.sql'), 'refused before the database is touched');
  assert.match(setup, /SMS sends this facility may make in one hour \(Enter for 60\)/);
  assert.match(setup, /SMS sends this facility may make in one day, 24 hours \(Enter for 300\)/);
  const sql = read('scripts/configure-sms-ceiling.sql');
  assert.match(sql, /'otp_global_hourly_cap','60'/);
  assert.match(sql, /'otp_daily_provider_attempt_cap','300'/);
});


test('API_CONTRACT says get_items is open to every signed-in role and that migration 114\'s comment is about get_item_usage (WH-47)', () => {
  const contract = read('docs/API_CONTRACT.md');
  assert.match(contract, /lets `get_items`, `get_item` and `search_items_autocomplete` through without a role check/);
  assert.match(contract, /belongs to `get_item_usage` below, not to `get_items`/);
});

test('setup.sh refuses a bad SMS ceiling before it creates the state', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-setup-ceiling-'));
  try {
    for (const [option, value, message] of [['--sms-hourly-ceiling', '0', /hourly SMS ceiling/], ['--sms-hourly-ceiling', 'abc', /hourly SMS ceiling/], ['--sms-hourly-ceiling', '1000000', /hourly SMS ceiling/],
      ['--sms-daily-ceiling', '10000000', /daily SMS ceiling/], ['--sms-daily-ceiling', '1.5', /daily SMS ceiling/]]) {
      const state = join(scratch, 'state');
      const r = spawnSync('bash', [join(root, 'setup.sh'), '--operator', '--state-dir', state, '--admin-phone', '919000000999', '--admin-name', 'Tester', option, value],
        { encoding: 'utf8', cwd: root, input: '', timeout: 60000 });
      assert.equal(r.status, 1, `${option} ${value}: ${r.stdout}${r.stderr}`);
      assert.match(r.stderr, message, `${option} ${value}`);
      assert.equal(existsSync(state), false, `${option} ${value}: the state was not created`);
    }
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

// WH-289: the cosign download gives up only on a stall and carries on from the byte where it stopped.
// The pinned SHA-256 is in the script, so a real cosign cannot be faked. The sha256sum shim swaps only the pinned amd64 value for the SHA-256 of
// a fixture; the real sha256sum still hashes the file, so a file with other content is still refused.
const FIXTURE = 'PART1PART2';
function cosignWorld(curlBody) {
  const w = installWorld(`sc="\${out%/state/bin/*}"; n=$(cat "$sc/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$sc/count"\n${curlBody}`);
  const pinned = /^SHA_AMD64=(.*)$/m.exec(read('scripts/install-cosign.sh'))[1];
  const shim = (name, body) => { writeFileSync(join(w.scratch, 'bin', name), `#!/bin/bash\n${body}\n`); chmodSync(join(w.scratch, 'bin', name), 0o755); };
  shim('sleep', 'exit 0');
  const real = spawnSync('which', ['sha256sum'], { encoding: 'utf8' }).stdout.trim();
  const good = spawnSync(real, [], { input: FIXTURE, encoding: 'utf8' }).stdout.split(' ')[0];
  shim('sha256sum', `if [ "$1" = -c ]; then sed "s/${pinned}/${good}/" | ${real} "$@"; else ${real} "$@" | sed "s/${good}/${pinned}/"; fi`);
  const count = () => Number(existsSync(join(w.scratch, 'count')) ? readFileSync(join(w.scratch, 'count'), 'utf8') : 0);
  const calls = () => w.curlLog().trim().split('\n').filter(Boolean);
  return { ...w, count, calls };
}

test('install-cosign.sh resumes a part-written download with --continue-at - into the same temporary file, and checks the finished file', () => {
  const w = cosignWorld('if [ $n = 1 ]; then printf PART1 > "$out"; exit 28; fi\nif [ $n = 2 ]; then [ "$(cat "$out")" = PART1 ] || exit 99; printf PART2 >> "$out"; exit 0; fi\nexit 98');
  try {
    const r = w.run();
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stdout, /^Installed cosign v\d+\.\d+\.\d+ /m);
    assert.equal(readFileSync(join(w.state, 'bin/cosign'), 'utf8'), FIXTURE);
    assert.equal(w.count(), 2);
    const outs = w.calls().map(l => / --output (\S+) /.exec(l)[1]);
    assert.equal(outs[0], outs[1], 'the same temporary file');
    assert.match(outs[0], /\/state\/bin\/\.cosign\.[A-Za-z0-9]{6}$/);
    for (const l of w.calls()) assert.match(l, / --continue-at - /);
    assert.deepEqual(readdirSync(join(w.state, 'bin')), ['cosign']);
  } finally { w.clean(); }
});

test('install-cosign.sh: exit 33 (the server ignores the range) empties the file and the next attempt starts from zero', () => {
  const w = cosignWorld('if [ $n = 1 ]; then printf JUNKJUNK > "$out"; exit 33; fi\nif [ $n = 2 ]; then [ ! -s "$out" ] || exit 99; printf PART1PART2 >> "$out"; exit 0; fi\nexit 98');
  try {
    const r = w.run();
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stderr, /the server does not resume a partial file; starting again from the beginning\./);
    assert.equal(readFileSync(join(w.state, 'bin/cosign'), 'utf8'), FIXTURE);
    assert.equal(w.count(), 2);
  } finally { w.clean(); }
});

test('install-cosign.sh gives up after 4 attempts that add no bytes, leaves nothing in the state, and says the images will NOT be signature-checked', () => {
  const w = cosignWorld('exit 28');
  try {
    const r = w.run();
    assert.equal(r.status, 1, r.stdout + r.stderr);
    assert.equal(w.count(), 4);
    assert.match(r.stderr, /^Refusing: cosign v\d+\.\d+\.\d+ could not be downloaded: the connection stalled, timed out or was refused \(curl 28: no message\)\. Without cosign the release images will NOT be signature-checked\. Run bash scripts\/install-cosign\.sh "[^"\n]+" \(from a checkout of the release\) once the connection is better\.$/m);
    assert.ok(r.stderr.includes(`Run bash scripts/install-cosign.sh "${w.state}" (from a checkout of the release) once the connection is better.`));
    assert.deepEqual(readdirSync(join(w.state, 'bin')), []);
  } finally { w.clean(); }
});

test('install-cosign.sh: an attempt that adds bytes resets the stall count, and the overall cap is 30 attempts', () => {
  const w = cosignWorld('printf x >> "$out"; exit 56');
  try {
    const r = w.run();
    assert.equal(r.status, 1, r.stdout + r.stderr);
    assert.equal(w.count(), 30);
    assert.match(r.stderr, /could not be downloaded: the connection stalled, timed out or was refused \(curl 56: no message\)\. Without cosign/);
    assert.deepEqual(readdirSync(join(w.state, 'bin')), []);
  } finally { w.clean(); }
  // progress, then 3 empty attempts, then progress again (attempt 5): the count restarted, so attempts 6 to 9 end it
  const p = cosignWorld('if [ $n = 1 ] || [ $n = 5 ]; then printf x >> "$out"; fi\nexit 28');
  try {
    const r = p.run();
    assert.equal(r.status, 1);
    assert.equal(p.count(), 9);
  } finally { p.clean(); }
});

test('install-cosign.sh: a non-transient curl exit (22, an HTTP error) gives up at once with one call', () => {
  const w = cosignWorld('exit 22');
  try {
    const r = w.run();
    assert.equal(r.status, 1);
    assert.equal(w.count(), 1);
    assert.match(r.stderr, /could not be downloaded: HTTP error from github\.com\. Without cosign/);
    assert.deepEqual(readdirSync(join(w.state, 'bin')), []);
  } finally { w.clean(); }
});

test('install-cosign.sh: a completed download whose SHA-256 differs is deleted and refused', () => {
  const w = cosignWorld('printf WRONGDATA > "$out"; exit 0');
  try {
    const r = w.run();
    assert.equal(r.status, 1);
    assert.match(r.stderr, /the downloaded cosign does not match the pinned SHA-256, so it is not installed/);
    assert.equal(w.count(), 1);
    assert.deepEqual(readdirSync(join(w.state, 'bin')), []);
  } finally { w.clean(); }
});

test('install-cosign.sh downloads with a speed floor (50 KB/s for 60 s), a per-attempt ceiling of 3600 s, resume, and no fixed 300 s limit', () => {
  const w = cosignWorld('exit 22');
  try {
    w.run();
    const line = w.calls()[0];
    assert.match(line, / --speed-limit 50000 --speed-time 60 /);
    assert.match(line, / --max-time 3600 /);
    assert.match(line, / --continue-at - /);
    assert.doesNotMatch(line, /--max-time 300( |$)/);
  } finally { w.clean(); }
});

test('setup.sh warns that the release images will NOT be signature-checked when cosign cannot be installed, and names the retry command', () => {
  const setup = read('setup.sh');
  assert.match(setup, /Warning: cosign could not be installed \(message above\), so the release images will NOT be signature-checked\./);
  assert.ok(setup.includes('To check them later, once the cause above is fixed: bash scripts/install-cosign.sh \\"$STATE\\" (from the checkout you ran setup.sh in), then run setup.sh again with the same options (it checks every release image before using it); or check one image with bash scripts/verify-image-signature.sh <repository>@sha256:<digest>.'));
  assert.ok(setup.includes('bash scripts/verify-image-signature.sh <repository>@sha256:<digest>'));
});

test('install-cosign.sh removes only .cosign.* temporary files older than 60 minutes: a fresh one, its own temporary file and other files survive', () => {
  const w = cosignWorld('ls -A "$(dirname "$out")" > "$sc/during"; exit 22');
  try {
    const dir = join(w.state, 'bin');
    mkdirSync(dir, { recursive: true });
    const old = join(dir, '.cosign.OLD123'), fresh = join(dir, '.cosign.NEW123'), other = join(dir, 'keep-me');
    for (const f of [old, fresh, other]) writeFileSync(f, 'x');
    const longAgo = new Date(Date.now() - 61 * 60 * 1000), recent = new Date(Date.now() - 30 * 60 * 1000);
    utimesSync(old, longAgo, longAgo); utimesSync(other, longAgo, longAgo); utimesSync(fresh, recent, recent);
    w.run();
    const own = /--output \S+\/(\.cosign\.\w{6}) /.exec(w.curlLog())[1];
    assert.deepEqual(readFileSync(join(w.scratch, 'during'), 'utf8').trim().split('\n').sort(), ['.cosign.NEW123', own, `${own}.err`, 'keep-me'].sort(), 'during the run only the old file is gone');
    assert.deepEqual(readdirSync(dir).sort(), ['.cosign.NEW123', 'keep-me']);
  } finally { w.clean(); }
});

// WH-289 rework 1: the HTTP code is read from --write-out '%{http_code}' on stdout (the shim prints it as curl does); exit 22 is retried only for 408, 429 and 5xx.
const http = (code, rc = 22) => `printf ${code}; exit ${rc}`;
test('install-cosign.sh retries HTTP 503, 429 and 408 and curl exits 92 and 16, then installs', () => {
  for (const [first, label] of [[http(503), '503'], [http(429), '429'], [http(408), '408'], ['exit 92', '92'], ['exit 16', '16']]) {
    const w = cosignWorld(`if [ $n = 1 ]; then ${first}; fi\nprintf PART1PART2 >> "$out"; exit 0`);
    try {
      const r = w.run();
      assert.equal(r.status, 0, `${label}: ${r.stdout}${r.stderr}`);
      assert.equal(w.count(), 2, label);
      assert.equal(readFileSync(join(w.state, 'bin/cosign'), 'utf8'), FIXTURE, label);
      assert.deepEqual(readdirSync(join(w.state, 'bin')), ['cosign'], label);
    } finally { w.clean(); }
  }
});

test('install-cosign.sh gives up at once on HTTP 404 and 403 (one curl call, nothing left in the state)', () => {
  for (const code of [404, 403]) {
    const w = cosignWorld(http(code));
    try {
      const r = w.run();
      assert.equal(r.status, 1, String(code));
      assert.equal(w.count(), 1, String(code));
      assert.match(r.stderr, new RegExp(`could not be downloaded: HTTP ${code} from github\\.com\\. Without cosign the release images will NOT be signature-checked\\. Run bash scripts/install-cosign\\.sh "[^"\\n]+" \\(from a checkout of the release\\) once that is fixed\\.$`, 'm'), String(code));
      assert.doesNotMatch(r.stderr, /connection/);
      assert.deepEqual(readdirSync(join(w.state, 'bin')), [], String(code));
    } finally { w.clean(); }
  }
});

test('install-cosign.sh names a local curl error (exit 23, a write failure) and does not blame the connection', () => {
  const w = cosignWorld('echo "curl: (23) Failure writing output to destination" >&2; exit 23');
  try {
    const r = w.run();
    assert.equal(r.status, 1);
    assert.equal(w.count(), 1);
    assert.match(r.stderr, /could not be downloaded: cosign could not be written to \S+\/state\/bin \(curl 23: Failure writing output to destination\); check the free disk space and that the folder is writable\. Without cosign the release images will NOT be signature-checked\. Run bash scripts\/install-cosign\.sh "[^"\n]+" \(from a checkout of the release\) once that is fixed\.$/m);
    assert.doesNotMatch(r.stderr.split('\n').filter(l => l.startsWith('Refusing')).join(''), /connection/);
    assert.deepEqual(readdirSync(join(w.state, 'bin')), [], 'the .err file is removed too');
  } finally { w.clean(); }
});

test('install-cosign.sh run piped as git show | bash -s names the printed command, not the upgrade, and a stall still names the connection', () => {
  const w = cosignWorld('echo "curl: (28) Operation too slow" >&2; exit 28');
  try {
    const bin = join(w.scratch, 'bin');
    const r = spawnSync('bash', ['-s', '--', w.state], { input: read('scripts/install-cosign.sh'), encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: '' } });
    assert.equal(r.status, 1, r.stdout + r.stderr);
    assert.match(r.stderr, /could not be downloaded: the connection stalled, timed out or was refused \(curl 28: Operation too slow\)\. Without cosign the release images will NOT be signature-checked\. Run the same command again \(git show <release>:scripts\/install-cosign\.sh \| bash -s -- "[^"\n]+", as the upgrade printed it\) once the connection is better\.$/m);
    assert.doesNotMatch(r.stderr, /upgrade\.sh|run the upgrade|Run bash scripts/i);
  } finally { w.clean(); }
});


// Checked against real curl 8.5.0 and a local server that answers 416 to a range past the end (WH-290): `curl --fail --continue-at -` on a complete file
// exits 0 with %{http_code} 416 and leaves the file as it is; on a file longer than the remote it does the same. So the script's SHA-256 check decides,
// and the script's own `22` + 416 branch is never reached. The shim does what real curl does.
test('install-cosign.sh: curl exit 0 with HTTP 416 on a complete file installs after the SHA check, and on a file that is not the release is refused', () => {
  const whole = cosignWorld(`printf PART1PART2 > "$out"; printf 416; exit 0`);
  try {
    const r = whole.run();
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.equal(whole.count(), 1);
    assert.equal(readFileSync(join(whole.state, 'bin/cosign'), 'utf8'), FIXTURE);
  } finally { whole.clean(); }
  const wrong = cosignWorld(`printf PART1PART2EXTRA > "$out"; printf 416; exit 0`);
  try {
    const r = wrong.run();
    assert.equal(r.status, 1);
    assert.equal(wrong.count(), 1);
    assert.match(r.stderr, /the downloaded cosign does not match the pinned SHA-256, so it is not installed/);
    assert.deepEqual(readdirSync(join(wrong.state, 'bin')), []);
  } finally { wrong.clean(); }
});

test('install-cosign.sh stops after a 2-hour deadline, and cuts --max-time to the time left', () => {
  // BASH_ENV gives the script a sleep that moves SECONDS on by 4000, so no real time passes
  const scratchEnv = join(tmpdir(), `cosign-bashenv-${process.pid}`);
  writeFileSync(scratchEnv, 'sleep() { SECONDS=$((SECONDS + 4000)); }\n');
  const w = cosignWorld('exit 28');
  try {
    const r = w.run([w.state], { BASH_ENV: scratchEnv });
    assert.equal(r.status, 1, r.stdout + r.stderr);
    assert.equal(w.count(), 2, 'the third attempt is not started');
    const max = w.calls().map(l => /--max-time (\d+)/.exec(l)[1]);
    assert.equal(max[0], '3600');
    assert.ok(Number(max[1]) >= 3199 && Number(max[1]) <= 3200, `the second ceiling is the time left, got ${max[1]}`);
    assert.match(r.stderr, /could not be downloaded: the 2-hour deadline for the download was reached \(last attempt: curl 28, no message\)\. Without cosign the release images will NOT be signature-checked\./);
    assert.deepEqual(readdirSync(join(w.state, 'bin')), []);
  } finally { w.clean(); rmSync(scratchEnv, { force: true }); }
});
