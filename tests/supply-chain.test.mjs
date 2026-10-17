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
  const docker = read('docker/storage/Dockerfile').replace(/\\\r?\n/g, ' ');
  assert.match(docker, /sha256sum package-lock\.json[\s\S]*npm install[\s\S]*sha256sum package-lock\.json[\s\S]*exit 1/);
  assert.match(docker, /npm ls --omit=dev --all/);
});
