// Every tracked shell script must parse, including the ones that run inside images
// (docker/cups/entrypoint.sh). CI runs this test through npm test.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const tracked = spawnSync('git', ['-C', root, 'ls-files', '*.sh'], { encoding: 'utf8' });

test('every tracked shell script passes a syntax check with its own interpreter', { skip: tracked.status !== 0 && !process.env.CI && 'not a git checkout' }, () => {
  const scripts = tracked.stdout.split('\n').filter(Boolean);
  for (const expected of ['setup.sh', 'scripts/verify-restore.sh', 'scripts/backup-key.sh', 'tests/verify-restore-drill.sh', 'docker/cups/entrypoint.sh']) assert.ok(scripts.includes(expected), expected);
  for (const script of scripts) {
    const shell = readFileSync(join(root, script), 'utf8').startsWith('#!/bin/sh') ? 'sh' : 'bash';
    const result = spawnSync(shell, ['-n', join(root, script)], { encoding: 'utf8' });
    assert.equal(result.status, 0, `${script}: ${result.stderr}`);
  }
});

test('the disposable databases use the image digest the production database is built from', () => {
  const pinned = readFileSync(join(root, 'docker/postgres/Dockerfile'), 'utf8').match(/^FROM (postgres:17\.\d+-trixie@sha256:[0-9a-f]{64})$/m)[1];
  const printed = spawnSync('bash', [join(root, 'scripts/db-image.sh')], { encoding: 'utf8' });
  assert.equal(printed.status, 0, printed.stderr);
  assert.equal(printed.stdout.trim(), pinned, 'scripts/db-image.sh prints the Dockerfile pin');
  // The scripts take the pin from scripts/db-image.sh; none names an image of its own.
  for (const script of ['scripts/verify-restore.sh', 'tests/migrations.sh', 'scripts/backup.sh', 'tests/backup-operator.test.mjs']) {
    const text = readFileSync(join(root, script), 'utf8');
    assert.doesNotMatch(text, /(?:supabase\/)?postgres:[0-9][^\s'"]*@sha256:[0-9a-f]{64}/, `${script} does not pin a database image itself`);
    if (script.endsWith('.sh')) assert.match(text, /db-image\.sh/, `${script} reads the shared pin`);
  }
  assert.doesNotMatch(readFileSync(join(root, 'docker/docker-compose.yml'), 'utf8'), /^\s+image:\s*(?:supabase\/)?postgres:/m, 'the db service is built from the Dockerfile');
});
