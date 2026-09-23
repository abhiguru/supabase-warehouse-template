import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const helper = fileURLToPath(new URL('../scripts/pooler-readiness.sh', import.meta.url));
for (const [name, behavior, expectedStatus, expectedAttempts] of [
  ['ready authenticated query', 'echo 1', 0, 1],
  ['listener startup race', 'if (( count < 3 )); then exit 2; fi; echo 1', 0, 3],
  ['permanent connection/auth failure', 'exit 2', 1, 12],
  ['wrong query result', 'echo 0', 1, 12],
  ['empty successful result', 'exit 0', 1, 12],
]) {
  test(`pooler readiness: ${name}`, () => {
    const dir = mkdtempSync(join(tmpdir(), 'warehouse-pooler-test-'));
    try {
      const counter = join(dir, 'attempts');
      const probe = join(dir, 'probe.sh');
      writeFileSync(counter, '0');
      writeFileSync(probe, `count=$(<"$1"); count=$((count + 1)); printf '%s' "$count" > "$1"\n${behavior}\n`);
      const result = spawnSync('bash', ['-c',
        'source "$1"; sleep() { :; }; wait_for_pooler_query 5432 bash "$2" "$3"',
        '_', helper, probe, counter], { encoding: 'utf8', timeout: 5000 });
      assert.equal(result.status, expectedStatus, result.stderr);
      assert.equal(Number(readFileSync(counter, 'utf8')), expectedAttempts);
      if (expectedStatus !== 0) assert.match(result.stderr, /after 12 attempts/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
}
