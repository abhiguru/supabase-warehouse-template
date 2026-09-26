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
    const childEnv = { ...process.env };
    delete childEnv.NODE_TEST_CONTEXT;
    const run = (script, args = []) => spawnSync(process.execPath, [join(alias, 'scripts', script), ...args], { encoding: 'utf8', env: childEnv });

    const stateDir = join(scratch, 'state');
    const providerEnv = join(scratch, 'provider.env');
    writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=key\nMSG91_TEMPLATE_ID=id\nMSG91_PE_ID=pe\nMSG91_SENDER_ID=WHOUSE\n', { mode: 0o600 });
    const options = ['--state-dir', stateDir, '--api-url', 'https://api.example.com', '--app-url', 'https://app.example.com', '--company', 'Acme', '--provider-env', providerEnv];
    const configured = run('configure.mjs', options);
    assert.equal(configured.status, 0, configured.stderr);
    const envPath = join(stateDir, 'config/compose.env');
    const before = readFileSync(envPath);
    assert.equal(run('configure.mjs', options).status, 0);
    assert.deepEqual(readFileSync(envPath), before);
    assert.equal(statSync(envPath).mode & 0o777, 0o600);

    const plan = run('migration-plan.mjs');
    assert.equal(plan.status, 0, plan.stderr);

    // Doctor must execute and fail when its tools are unavailable, rather than
    // silently exiting zero because argv retains the symlink.
    const doctor = spawnSync(process.execPath, [join(alias, 'scripts/doctor.mjs'), '--preflight'], {
      encoding: 'utf8', env: { ...childEnv, PATH: join(scratch, 'no-tools') },
    });
    assert.equal(doctor.status, 1);

    const imported = spawnSync(process.execPath, ['--input-type=module', '-e',
      "await import('./scripts/configure.mjs'); await import('./scripts/doctor.mjs'); await import('./scripts/migration-plan.mjs');"], {
      cwd: alias, encoding: 'utf8', env: childEnv,
    });
    assert.equal(imported.status, 0, imported.stderr);
    assert.equal(imported.stdout, '');
    assert.deepEqual(readFileSync(envPath), before);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
