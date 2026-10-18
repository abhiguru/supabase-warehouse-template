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
    // setup renders the monitoring files from the templates next to the scripts (scripts/monitoring-config.mjs).
    for (const file of ['prometheus.yml', 'alertmanager.yml', 'alertmanager.webhook.yml']) cpSync(new URL(`../docker/${file}`, import.meta.url), join(root, 'docker', file));
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

test('the image scan and its validator run through a symlinked checkout and still refuse a fixable CRITICAL row', () => {
  // The validator's main guard must not depend on argv naming the physical
  // path: through a symlink it would otherwise exit zero without checking
  // anything, and scan-images.sh, which reads only exit codes, would pass.
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-scan-symlink-'));
  const root = join(scratch, 'checkout');
  const alias = join(scratch, 'alias');
  try {
    mkdirSync(join(root, 'docker'), { recursive: true });
    mkdirSync(join(root, 'bin'));
    cpSync(new URL('../scripts', import.meta.url), join(root, 'scripts'), { recursive: true });
    writeFileSync(join(root, 'docker/image-exceptions.json'), JSON.stringify({ schemaVersion: 1, exceptions: [] }));
    const image = 'example.test/app:1@sha256:' + 'c'.repeat(64);
    const report = { SchemaVersion: 2, ArtifactName: image, ArtifactType: 'container_image', Results: [{ Target: 'test OS', Class: 'os-pkgs', Packages: [{ Name: 'libexample', Version: '1.0' }],
      Vulnerabilities: [{ VulnerabilityID: 'CVE-2026-0009', PkgName: 'libexample', InstalledVersion: '1.0', FixedVersion: '1.1', Status: 'fixed', Severity: 'CRITICAL' }] }] };
    writeFileSync(join(root, 'report.json'), JSON.stringify(report));
    writeFileSync(join(root, 'scripts/compose.sh'), `#!/bin/sh\ncase "$*" in\n  *" ps "*) exit 0;;\n  *build*) exit 0;;\n  *) echo '${JSON.stringify({ name: 'warehouse-symlink-test', services: { app: { image } } })}';;\nesac\n`);
    writeFileSync(join(root, 'bin/trivy'), `#!/bin/sh\nwhile [ "$1" != "--output" ]; do shift; done\ncp '${join(root, 'report.json')}' "$2"\n`, { mode: 0o700 });
    symlinkSync(root, alias, 'dir');
    const env = { ...process.env, PATH: `${join(alias, 'bin')}:${process.env.PATH}`, WAREHOUSE_SCAN_REPORT_DIR: join(scratch, 'reports') };
    delete env.NODE_TEST_CONTEXT;

    const validator = spawnSync(process.execPath, [join(alias, 'scripts/validate-image-report.mjs'), join(alias, 'report.json'), image,
      '--exceptions', join(alias, 'docker/image-exceptions.json'), '--recipe', image], { encoding: 'utf8', env });
    assert.equal(validator.status, 1, `validator through the symlink: ${validator.stdout}${validator.stderr}`);
    assert.match(validator.stderr, /HIGH\/CRITICAL vulnerabilities remain: 1 row/);

    const scan = spawnSync('bash', [join(alias, 'scripts/scan-images.sh')], { encoding: 'utf8', env });
    assert.equal(scan.status, 1, `scan through the symlink: ${scan.stdout}${scan.stderr}`);
    assert.doesNotMatch(scan.stdout, /Container image scan passed/);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
