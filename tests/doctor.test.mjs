import test from 'node:test';
import assert from 'node:assert/strict';
import { supportedNode } from '../scripts/doctor-common.mjs';
import { canonicalOrigin } from '../scripts/configure.mjs';

test('operator configuration requires canonical HTTPS origins and supported Node', () => {
  assert.equal(supportedNode('22.17.0'), false);
  assert.equal(supportedNode('22.18.0'), true);
  assert.equal(canonicalOrigin('https://api.example.com'), 'https://api.example.com');
  for (const value of ['http://api.example.com', 'https://api.example.com/path', 'https://user:pass@api.example.com', 'https://api.example.com:8443', 'https://api.example.com?q=1']) assert.throws(() => canonicalOrigin(value));
});

// testvm2 F1 / known issue 3: a pre-created state under a root-owned parent passed
// the preflight and then failed with EACCES when setup staged its files next to it.
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkStatePlacement } from '../scripts/doctor.mjs';

test('a fresh install refuses a state whose parent is not writable, naming the fix', { skip: process.getuid() === 0 && 'root can write anywhere' }, () => {
  const base = mkdtempSync(join(tmpdir(), 'state-parent-'));
  const parent = join(base, 'srv-warehouse');
  const state = join(parent, 'acme');
  try {
    mkdirSync(state, { recursive: true, mode: 0o700 });
    chmodSync(state, 0o700);
    chmodSync(parent, 0o555);
    assert.throws(() => checkStatePlacement(state), err => err.message.includes(`${parent} must be writable`) && err.message.includes('sudo chown'));
    chmodSync(parent, 0o755);
    assert.equal(checkStatePlacement(state), state);
  } finally { chmodSync(parent, 0o755); rmSync(base, { recursive: true, force: true }); }
});

test('a rerun of an installed state needs no write access to the parent', { skip: process.getuid() === 0 && 'root can write anywhere' }, () => {
  const base = mkdtempSync(join(tmpdir(), 'state-parent-'));
  const parent = join(base, 'srv-warehouse');
  const state = join(parent, 'acme');
  try {
    mkdirSync(join(state, 'config'), { recursive: true });
    chmodSync(state, 0o700);
    writeFileSync(join(state, 'config', 'compose.env'), 'AUTH_MODE=operator\n', { mode: 0o600 });
    chmodSync(parent, 0o555);
    assert.equal(checkStatePlacement(state), state);
  } finally { chmodSync(parent, 0o755); rmSync(base, { recursive: true, force: true }); }
});

test('a state that does not exist yet is checked against its parent', () => {
  const base = mkdtempSync(join(tmpdir(), 'state-parent-'));
  try {
    assert.equal(checkStatePlacement(join(base, 'acme')), base);
    assert.throws(() => checkStatePlacement('relative/path'), /absolute path outside this checkout/);
  } finally { rmSync(base, { recursive: true, force: true }); }
});
