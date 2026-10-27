import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, renameSync, rmSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// scripts/check-migration-order.mjs against small git repositories: the base is a commit holding three migrations, the change is made in
// the working tree.
const script = new URL('../scripts/check-migration-order.mjs', import.meta.url).pathname;
const git = (cwd, ...args) => {
  const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...args], { cwd, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout;
};

function repo() {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-order-'));
  git(dir, 'init', '-q', '-b', 'main');
  mkdirSync(join(dir, 'migrations'));
  for (const [name, body] of [['00000000000000_baseline.sql', 'SELECT 0;\n'], ['00000000000111_first.sql', 'SELECT 111;\n'], ['00000000000112_second.sql', 'SELECT 112;\n']]) writeFileSync(join(dir, 'migrations', name), body);
  git(dir, 'add', 'migrations');
  git(dir, 'commit', '-q', '-m', 'base');
  const check = (...extra) => spawnSync('node', [script, 'main', '--root', dir, ...extra], { cwd: dir, encoding: 'utf8' });
  return { dir, check, file: name => join(dir, 'migrations', name), cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

test('a correctly numbered new file passes, and so does no change at all', () => {
  const r = repo();
  try {
    const none = r.check();
    assert.equal(none.status, 0, none.stderr);
    assert.match(none.stdout, /Migration order holds: 3 files of main unchanged, 0 new\./);
    writeFileSync(r.file('00000000000113_third.sql'), 'SELECT 113;\n');
    writeFileSync(r.file('00000000000200_far_ahead.sql'), 'SELECT 200;\n');
    const added = r.check();
    assert.equal(added.status, 0, added.stderr);
    assert.match(added.stdout, /3 files of main unchanged, 2 new\./);
  } finally { r.cleanup(); }
});

test('a new file that sorts before the last file of the base is refused, and the message names both', () => {
  const r = repo();
  try {
    writeFileSync(r.file('00000000000111_a_late_comer.sql'), 'SELECT 1;\n');   // "111_a…" < "111_f…" < "112_…"
    const before = r.check();
    assert.equal(before.status, 1);
    assert.match(before.stderr, /00000000000111_a_late_comer\.sql: sorts before 00000000000112_second\.sql, the last migration of the base/);
    rmSync(r.file('00000000000111_a_late_comer.sql'));
    writeFileSync(r.file('00000000000050_between.sql'), 'SELECT 50;\n');
    const between = r.check();
    assert.equal(between.status, 1);
    assert.match(between.stderr, /00000000000050_between\.sql: sorts before 00000000000112_second\.sql/);
  } finally { r.cleanup(); }
});

test('a renamed or removed file of the base is refused', () => {
  const r = repo();
  try {
    renameSync(r.file('00000000000111_first.sql'), r.file('00000000000113_first.sql'));
    const renamed = r.check();
    assert.equal(renamed.status, 1);
    assert.match(renamed.stderr, /00000000000111_first\.sql: renamed to 00000000000113_first\.sql/);
    rmSync(r.file('00000000000113_first.sql'));
    const removed = r.check();
    assert.equal(removed.status, 1);
    assert.match(removed.stderr, /00000000000111_first\.sql: removed\./);
  } finally { r.cleanup(); }
});

test('a changed file of the base is refused', () => {
  const r = repo();
  try {
    writeFileSync(r.file('00000000000112_second.sql'), `${readFileSync(r.file('00000000000112_second.sql'), 'utf8')}-- edited\n`);
    const changed = r.check();
    assert.equal(changed.status, 1);
    assert.match(changed.stderr, /00000000000112_second\.sql: its content changed\./);
    assert.match(changed.stderr, /Rule: never remove, rename or edit a file in migrations\//);
  } finally { r.cleanup(); }
});

test('a base ref that cannot be read is exit 2, not a pass', () => {
  const r = repo();
  try {
    const missing = spawnSync('node', [script, 'origin/nowhere', '--root', r.dir], { encoding: 'utf8' });
    assert.equal(missing.status, 2);
    assert.match(missing.stderr, /Could not read migrations\/ at origin\/nowhere/);
    assert.equal(spawnSync('node', [script, 'a', 'b'], { encoding: 'utf8' }).status, 2);
  } finally { r.cleanup(); }
});

test('--root checks another checkout than the script\'s own', () => {
  const r = repo();
  try {
    writeFileSync(r.file('00000000000001_early.sql'), 'SELECT 1;\n');
    const elsewhere = spawnSync('node', [script, 'main', '--root', r.dir], { encoding: 'utf8' });
    assert.equal(elsewhere.status, 1);
    assert.match(elsewhere.stderr, /00000000000001_early\.sql: sorts before/);
  } finally { r.cleanup(); }
});
