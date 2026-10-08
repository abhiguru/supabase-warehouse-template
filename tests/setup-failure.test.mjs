import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

test('current setup rejects historical demo mode before touching Docker or state', () => {
  const result = spawnSync('bash', [new URL('../setup.sh', import.meta.url).pathname, '--demo'], { encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Demo installation is no longer supported/);
});
