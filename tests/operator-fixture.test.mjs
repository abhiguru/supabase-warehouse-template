import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { operatorFixture } from './operator-fixture.mjs';

test('operator fixture refuses live paths, symlinks, origins and provider credentials before Docker access', () => {
  const parent = mkdtempSync(join(tmpdir(), 'operator-guard-'));
  const state = join(parent, 'core-backend-test-1');
  const previous = process.env.WAREHOUSE_STATE_DIR;
  try {
    mkdirSync(state, { mode: 0o700 });
    mkdirSync(join(state, 'config'), { mode: 0o700 });
    process.env.WAREHOUSE_STATE_DIR = join(parent, 'live-warehouse');
    assert.throws(() => operatorFixture());
    const linked = join(parent, 'core-backend-test-2');
    symlinkSync(state, linked);
    process.env.WAREHOUSE_STATE_DIR = linked;
    assert.throws(() => operatorFixture(), /symlinks/);
    process.env.WAREHOUSE_STATE_DIR = state;
    writeFileSync(join(state, 'config/compose.env'),
      'AUTH_MODE=operator\nBIND_ADDRESS=127.0.0.1\nSUPABASE_PUBLIC_URL=https://production.example.test\n', { mode: 0o600 });
    assert.throws(() => operatorFixture());
    writeFileSync(join(state, 'config/compose.env'),
      'AUTH_MODE=operator\nBIND_ADDRESS=127.0.0.1\nSUPABASE_PUBLIC_URL=https://backend-core.example.test\nMSG91_AUTH_KEY=not-the-approved-fictional-key\n', { mode: 0o600 });
    assert.throws(() => operatorFixture());
  } finally {
    if (previous === undefined) delete process.env.WAREHOUSE_STATE_DIR;
    else process.env.WAREHOUSE_STATE_DIR = previous;
    rmSync(parent, { recursive: true, force: true });
  }
});
