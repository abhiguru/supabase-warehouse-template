import test from 'node:test';
import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test('CLI entry points run through a symlinked checkout without import side effects', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-cli-symlink-'));
  const root = join(scratch, 'checkout');
  const alias = join(scratch, 'alias');
  try {
    mkdirSync(root);
    mkdirSync(join(root, 'docker'));
    mkdirSync(join(root, 'migrations'));
    for (const file of ['scripts', '.env.example']) {
      cpSync(new URL(`../${file}`, import.meta.url), join(root, file), { recursive: true });
    }
    writeFileSync(join(root, 'migrations/0001_example.sql'), 'SELECT 1;\n');
    symlinkSync(root, alias, 'dir');
    const run = (script, args = []) => spawnSync(process.execPath, [join(alias, 'scripts', script), ...args], { encoding: 'utf8' });

    const configured = run('configure.mjs', ['--demo']);
    assert.equal(configured.status, 0, configured.stderr);
    assert.match(configured.stdout, /Created fresh/);
    const envPath = join(root, 'docker/.env');
    const before = readFileSync(envPath);
    assert.equal(run('configure.mjs', ['--demo']).status, 0);
    assert.deepEqual(readFileSync(envPath), before);
    assert.equal(statSync(envPath).mode & 0o777, 0o600);

    const plan = run('migration-plan.mjs');
    assert.equal(plan.status, 0, plan.stderr);
    assert.match(plan.stdout, /Applying: 0001_example.sql/);
    assert.match(plan.stdout, /SELECT 1;/);

    // Doctor must execute and fail when its tools are unavailable, rather than
    // silently exiting zero because argv retains the symlink.
    const doctor = spawnSync(process.execPath, [join(alias, 'scripts/doctor.mjs'), '--preflight'], {
      encoding: 'utf8', env: { ...process.env, PATH: join(scratch, 'no-tools') },
    });
    assert.equal(doctor.status, 1);
    assert.match(doctor.stderr, /Missing or unavailable prerequisite: npm/);

    const imported = spawnSync(process.execPath, ['--input-type=module', '-e',
      "await import('./scripts/configure.mjs'); await import('./scripts/doctor.mjs'); await import('./scripts/migration-plan.mjs');"], {
      cwd: alias, encoding: 'utf8',
    });
    assert.equal(imported.status, 0, imported.stderr);
    assert.equal(imported.stdout, '');
    assert.deepEqual(readFileSync(envPath), before);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
