// scripts/checkout-permissions.sh in a scratch git repository: an update made under
// umask 0002 or 077 ends with the modes of a umask 022 clone (F3, testvm2 run).
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, copyFileSync, chmodSync, statSync, symlinkSync, readFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SCRIPT = join(ROOT, 'scripts', 'checkout-permissions.sh');
const mode = path => (statSync(path).mode & 0o777).toString(8);
const run = (cwd, ...args) => spawnSync('bash', [join(cwd, 'scripts', 'checkout-permissions.sh'), ...args], { encoding: 'utf8' });
const git = (cwd, ...args) => {
  const r = spawnSync('git', ['-c', 'user.email=t@example.invalid', '-c', 'user.name=t', ...args], { cwd, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
};

function scratchCheckout() {
  const dir = mkdtempSync(join(tmpdir(), 'checkout-perms-'));
  mkdirSync(join(dir, 'scripts'));
  mkdirSync(join(dir, 'migrations'));
  copyFileSync(SCRIPT, join(dir, 'scripts', 'checkout-permissions.sh'));
  writeFileSync(join(dir, 'scripts', 'helper.sh'), '#!/bin/sh\n');
  writeFileSync(join(dir, 'migrations', '01.sql'), 'SELECT 1;\n');
  writeFileSync(join(dir, '.gitignore'), 'docker/.env\n');
  symlinkSync('docker/.env', join(dir, 'env-link'));
  git(dir, 'init', '-q');
  git(dir, 'add', '-A');
  git(dir, 'commit', '-qm', 'fixture');
  // What a pull under umask 0002 (and one file under 077) leaves behind.
  chmodSync(join(dir, 'scripts', 'helper.sh'), 0o775);
  chmodSync(join(dir, 'scripts'), 0o775);
  chmodSync(join(dir, 'migrations', '01.sql'), 0o600);
  // An ignored private runtime file must keep its mode.
  mkdirSync(join(dir, 'docker'), { mode: 0o700 });
  writeFileSync(join(dir, 'docker', '.env'), 'SECRET=1\n', { mode: 0o600 });
  return dir;
}

test('restores umask 022 modes on tracked files and directories only', () => {
  const dir = scratchCheckout();
  try {
    const r = run(dir);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /normalized [1-9][0-9]* path\(s\)/);
    assert.equal(mode(join(dir, 'scripts', 'helper.sh')), '755');
    assert.equal(mode(join(dir, 'scripts')), '755');
    assert.equal(mode(join(dir, 'migrations', '01.sql')), '644');
    assert.equal(mode(join(dir, 'docker', '.env')), '600', 'ignored file untouched');
    assert.equal(mode(join(dir, 'docker')), '700', 'untracked directory untouched');
    assert.equal(readFileSync(join(dir, 'docker', '.env'), 'utf8'), 'SECRET=1\n');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('is silent and changes nothing when the modes are already right', () => {
  const dir = scratchCheckout();
  try {
    assert.equal(run(dir).status, 0);
    const again = run(dir, '--quiet');
    assert.equal(again.status, 0, again.stderr);
    assert.equal(again.stdout, '');
    assert.match(run(dir).stdout, /normalized 0 path\(s\)/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('leaves a directory that is not a git checkout alone', () => {
  const dir = mkdtempSync(join(tmpdir(), 'checkout-perms-plain-'));
  try {
    mkdirSync(join(dir, 'scripts'));
    copyFileSync(SCRIPT, join(dir, 'scripts', 'checkout-permissions.sh'));
    writeFileSync(join(dir, 'scripts', 'helper.sh'), '#!/bin/sh\n');
    chmodSync(join(dir, 'scripts', 'helper.sh'), 0o775);
    const r = run(dir, '--quiet');
    assert.equal(r.status, 0, r.stderr);
    assert.equal(mode(join(dir, 'scripts', 'helper.sh')), '775');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('setup.sh normalizes the checkout before anything else runs', () => {
  const setup = readFileSync(join(ROOT, 'setup.sh'), 'utf8');
  const normalize = setup.indexOf('scripts/checkout-permissions.sh');
  assert.ok(normalize > 0, 'setup.sh calls checkout-permissions.sh');
  assert.ok(normalize < setup.indexOf('scripts/check-readiness.sh'), 'before the readiness check');
});
