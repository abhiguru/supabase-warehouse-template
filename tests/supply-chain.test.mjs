import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');

// Joins `\` continuations, drops comments and blank lines.
const requirementLines = text => text.replace(/\\\r?\n/g, ' ').split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#'));

test('every package in the sensor bridge requirements has sha256 hashes', () => {
  const lines = requirementLines(read('docker/sensor-bridge/requirements.txt'));
  assert.ok(lines.length >= 10, 'expected the bridge packages');
  for (const line of lines) {
    assert.match(line, /^[A-Za-z0-9_.-]+==[0-9][^\s]*( +--hash=sha256:[0-9a-f]{64})+$/, `unhashed or unpinned line: ${line.slice(0, 60)}`);
  }
});

test('the sensor bridge Dockerfile and CI install with --require-hashes', () => {
  const docker = read('docker/sensor-bridge/Dockerfile').replace(/\\\r?\n/g, ' ');
  const install = docker.split('\n').find(l => /pip install/.test(l));
  assert.ok(install && /--require-hashes/.test(install), 'Dockerfile pip install lacks --require-hashes');
  const ci = read('.github/workflows/ci.yml');
  const ciInstall = ci.split('\n').filter(l => /pip install .*sensor-bridge\/requirements\.txt/.test(l));
  assert.ok(ciInstall.length >= 1);
  for (const l of ciInstall) assert.match(l, /--require-hashes/);
});

test('the storage image fails the build if npm install changes package-lock.json', () => {
  const docker = read('docker/storage/Dockerfile').replace(/\\\r?\n/g, ' ').split('\n').filter(l => !l.startsWith('#')).join('\n');
  assert.match(docker, /before="\$\(sha256sum package-lock\.json[^)]*\)"\s+&& npm install [^&]*&& after="\$\(sha256sum package-lock\.json[^)]*\)"\s+&& if \[ "\$before" != "\$after" \]; then echo [^\n]*; exit 1; fi/);
  const install = /npm install [^&]*/.exec(docker)[0];
  for (const flag of ['--no-package-lock', '--package-lock=false', '--no-save', '--package-lock-only']) {
    assert.ok(!install.includes(flag), `npm install must not use ${flag}`);
  }
  assert.ok(!/--no-package-lock|--package-lock=false/.test(docker), 'no flag may skip the lockfile');
  assert.match(docker, /&& npm ls --omit=dev --all > \/dev\/null\s*\n/, 'npm ls must be fatal (no ||)');
  assert.match(docker, /npm@11\.12\.1/, 'the failure message names how to regenerate');
});

test('the storage image runs on a clean, digest-pinned Node image and carries only the patched /app from the publisher stage', () => {
  const docker = read('docker/storage/Dockerfile');
  const froms = docker.split('\n').filter(l => /^FROM /.test(l));
  assert.equal(froms.length, 2);
  assert.match(froms[0], /^FROM supabase\/storage-api:v[0-9.]+@sha256:[0-9a-f]{64} AS patched$/);
  assert.match(froms[1], /^FROM node:[0-9.]+-alpine[0-9.]+@sha256:[0-9a-f]{64}$/);
  const final = docker.slice(docker.indexOf(froms[1]));
  assert.match(final, /^COPY --from=patched \/app \/app$/m);
  assert.doesNotMatch(final, /apk add|npm install|npm ci|USER /, 'the final stage adds no packages and installs nothing');
  // The publisher's tag and the version the image reports are the same.
  assert.equal(/ENV VERSION=(\S+)/.exec(final)[1], /storage-api:v([0-9.]+)@/.exec(froms[0])[1]);
});
