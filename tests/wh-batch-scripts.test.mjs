import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
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
    assert.match(r.stderr, /could not be downloaded/);
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
