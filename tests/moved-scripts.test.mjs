// The CI-only drivers moved from scripts/ to tests/. Each one must still find the repository's files from its new folder
// (the gateway smoke called ./compose.sh next to itself and failed only in CI's operator-install job), and the scripts that
// run `node` first must check that node exists.
import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const MOVED = ['gateway-smoke.mjs', 'gateway-dns-check.sh', 'load-smoke.mjs', 'recovery-check.sh', 'cups-check.sh', 'sensor-bridge-check.sh', 'pooler-check.sh'];
const body = name => readFileSync(join(root, 'tests', name), 'utf8').split('\n').filter(line => !/^\s*(#|\/\/)/.test(line)).join('\n');

test('every moved driver resolves the files it uses from the repository root', () => {
  for (const name of MOVED) {
    const text = body(name);
    if (name.endsWith('.sh')) {
      assert.match(text, /ROOT="\$\(cd "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)\/\.\." && pwd\)"/, `${name}: ROOT is the repository root (one level above tests/)`);
      assert.doesNotMatch(text, /(^|[\s"'(])\.\/[\w-]+\.(sh|mjs)/m, `${name}: no path next to the script itself`);
      for (const [, path] of text.matchAll(/\$ROOT\/([\w./-]+)/g)) assert.ok(existsSync(join(root, path)), `${name}: $ROOT/${path} exists`);
      const syntax = spawnSync('bash', ['-n', join(root, 'tests', name)], { encoding: 'utf8' });
      assert.equal(syntax.status, 0, `${name}: ${syntax.stderr}`);
    } else {
      for (const [, path] of text.matchAll(/new URL\('([^']+)', import\.meta\.url\)/g)) assert.ok(existsSync(resolve(root, 'tests', path)), `${name}: ${path} exists from tests/`);
      for (const [, path] of text.matchAll(/from '(\.[^']+)'/g)) assert.ok(existsSync(resolve(root, 'tests', path)), `${name}: import ${path} exists from tests/`);
      assert.doesNotMatch(text, /new URL\([^)]*import\.meta\.url\)\.pathname/, `${name}: fileURLToPath, not .pathname (percent-encoding)`);
    }
  }
});

test('the drivers that call the compose wrapper name scripts/compose.sh', () => {
  for (const name of ['gateway-smoke.mjs', 'load-smoke.mjs']) assert.match(body(name), /new URL\('\.\.\/scripts\/compose\.sh', import\.meta\.url\)/, name);
});

test('setup.sh and restore-host.sh check that node exists before their first node call', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-no-node-'));
  try {
    const run = spawnSync('/bin/bash', ['-c', `. ${JSON.stringify(join(root, 'scripts/require-node.sh'))}; echo reached`], { encoding: 'utf8', env: { PATH: scratch } });
    assert.equal(run.status, 1);
    assert.equal(run.stderr.trim(), 'Missing prerequisite: node');
    assert.doesNotMatch(run.stdout, /reached/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
  for (const file of ['setup.sh', 'scripts/restore-host.sh']) {
    const text = readFileSync(join(root, file), 'utf8');
    const check = text.indexOf('scripts/require-node.sh"');
    const firstNode = text.search(/^[^#\n]*\bnode\b(?! the| is)[^\n]*"\$ROOT\/scripts\//m);
    assert.ok(check > 0 && firstNode > check, `${file}: require-node.sh is sourced before the first node call`);
  }
});

test('the migration harness builds the storage recipe under no fixed tag, so two runs on one host cannot share an image', () => {
  const text = readFileSync(join(root, 'tests/migrations.sh'), 'utf8');
  assert.match(text, /storage_recipe=\$\(docker build -q "\$ROOT\/docker\/storage"\)/);
  assert.doesNotMatch(text, /docker build[^\n]* -t /);
});
