import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const a = 'a'.repeat(40);
const b = 'b'.repeat(40);

// scripts/check-min-apps.sh reads MOBILE_MIN_REF and refuses a bad list before it touches the network or the app repository.
function run(workflowLines, args = []) {
  const scratch = mkdtempSync(join(tmpdir(), 'min-apps-'));
  try {
    const workflow = join(scratch, 'ci.yml');
    writeFileSync(workflow, `env:\n${workflowLines.join('\n')}\n`);
    return spawnSync('bash', [join(root, 'scripts/check-min-apps.sh'), join(scratch, 'work'), ...args], {
      encoding: 'utf8', env: { ...process.env, MIN_REF_WORKFLOW: workflow, APP_REPO: join(scratch, 'no-such-repository') },
    });
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

test('check-min-apps.sh refuses anything but full commit SHAs, listed once, declared once', () => {
  assert.equal(run([], []).status, 1, 'no declaration');
  assert.equal(run(['  MOBILE_MIN_REF: ']).status, 1, 'an empty list');
  for (const bad of ['main', a.slice(0, 12), `${a} ${a.slice(0, 7)}`, `${a},${b}`, a.toUpperCase()]) {
    const result = run([`  MOBILE_MIN_REF: ${bad}`]);
    assert.equal(result.status, 1, bad);
    assert.match(result.stdout, /MOBILE_MIN_REF must list full 40-digit commit SHAs/, bad);
  }
  assert.match(run([`  MOBILE_MIN_REF: ${a} ${a}`]).stdout, /lists a commit twice/);
  assert.match(run([`  MOBILE_MIN_REF: ${a}`, `  MOBILE_MIN_REF: ${b}`]).stdout, /exactly once/);
  assert.equal(spawnSync('bash', [join(root, 'scripts/check-min-apps.sh')], { encoding: 'utf8' }).status, 2, 'usage');
});

test('check-min-apps.sh accepts a list and then fails on the repository it cannot clone (the list passed validation)', () => {
  const result = run([`  MOBILE_MIN_REF: ${a} ${b}`]);
  assert.equal(result.status, 128);
  assert.doesNotMatch(result.stdout, /MOBILE_MIN_REF/);
});

test('the real ci.yml list is read by the script (every entry a full SHA)', () => {
  const line = readFileSync(join(root, '.github/workflows/ci.yml'), 'utf8').split('\n').find(l => l.startsWith('  MOBILE_MIN_REF: '));
  assert.ok(line.slice('  MOBILE_MIN_REF: '.length).split(' ').every(ref => /^[0-9a-f]{40}$/.test(ref)));
});
