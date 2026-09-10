import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, readFileSync, statSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHmac } from 'node:crypto';
import { configure } from '../scripts/configure.mjs';

test('fresh config uses valid matching JWTs and reruns preserve every byte', () => {
  const root = mkdtempSync(join(tmpdir(), 'warehouse-config-test-'));
  try {
    mkdirSync(join(root, 'docker'));
    copyFileSync(new URL('../.env.example', import.meta.url), join(root, '.env.example'));
    assert.equal(configure(root), true);
    const before = readFileSync(join(root, 'docker/.env'), 'utf8');
    assert.equal(configure(root), false);
    assert.equal(readFileSync(join(root, 'docker/.env'), 'utf8'), before);
    assert.equal(statSync(join(root, 'docker/.env')).mode & 0o777, 0o600);
    const env = Object.fromEntries(before.split('\n').filter(line => /^[A-Z_]+=/.test(line)).map(line => {
      const eq = line.indexOf('='); return [line.slice(0, eq), line.slice(eq + 1)];
    }));
    for (const [key, role] of [['ANON_KEY', 'anon'], ['SERVICE_ROLE_KEY', 'service_role']]) {
      const [header, payload, signature] = env[key].split('.');
      assert.equal(signature, createHmac('sha256', env.JWT_SECRET).update(`${header}.${payload}`).digest('base64url'));
      assert.equal(JSON.parse(Buffer.from(payload, 'base64url')).role, role);
    }
    assert.ok(!before.includes('changeme'));
  } finally { rmSync(root, { recursive: true }); }
});
