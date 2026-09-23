import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, writeFileSync, rmSync, readdirSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

test('image scan fails closed on missing inventory and isolates each report run', () => {
  const root = mkdtempSync(join(tmpdir(), 'warehouse-scan-test-'));
  try {
    mkdirSync(join(root, 'scripts'));
    mkdirSync(join(root, 'bin'));
    copyFileSync(new URL('../scripts/scan-images.sh', import.meta.url), join(root, 'scripts/scan-images.sh'));
    copyFileSync(new URL('../scripts/validate-image-report.mjs', import.meta.url), join(root, 'scripts/validate-image-report.mjs'));
    const scanner = body => writeFileSync(join(root, 'bin/trivy'), `#!/bin/sh\n${body}\n`, { mode: 0o700 });
    scanner('exit 0');
    const reportDir = join(root, 'reports');
    const run = inventory => {
      writeFileSync(join(root, 'scripts/compose.sh'), `#!/bin/sh\ncase "$*" in\n  *build) exit 0;;\n  *) ${inventory};;\nesac\n`);
      return spawnSync('bash', [join(root, 'scripts/scan-images.sh')], {
        encoding: 'utf8', env: { ...process.env, PATH: `${join(root, 'bin')}:${process.env.PATH}`, WAREHOUSE_SCAN_REPORT_DIR: reportDir },
      });
    };
    assert.notEqual(run('exit 1').status, 0, 'enumeration failure must not pass');
    assert.notEqual(run('exit 0').status, 0, 'empty inventory must not pass');
    assert.notEqual(run('echo example.test/image:1').status, 0, 'missing scan report must not pass');
    const report = { SchemaVersion: 2, ArtifactName: 'example.test/image:1', ArtifactType: 'container_image', Results: [{ Target: 'test OS', Class: 'os-pkgs', Packages: [{ Name: 'example-package', Version: '1.0.0' }] }] };
    const emit = value => scanner(`while [ "$1" != "--output" ]; do shift; done\nshift\nprintf '%s' '${JSON.stringify(value)}' > "$1"`);
    emit({});
    assert.notEqual(run('echo example.test/image:1').status, 0, 'empty JSON must not pass');
    emit({ ...report, ArtifactName: 'wrong:image' });
    assert.notEqual(run('echo example.test/image:1').status, 0, 'wrong image must not pass');
    emit({ ...report, Results: [{ Target: 'test OS', Class: 'os-pkgs' }] });
    assert.notEqual(run('echo example.test/image:1').status, 0, 'result without package inventory must not pass');
    emit({ ...report, Results: [{ Target: 'test OS', Class: 'os-pkgs', Packages: [] }] });
    assert.notEqual(run('echo example.test/image:1').status, 0, 'empty package inventory must not pass');
    emit({ ...report, Results: [{ Target: 'test OS', Class: 'os-pkgs', Packages: [{ Name: 'unversioned' }] }] });
    assert.notEqual(run('echo example.test/image:1').status, 0, 'unversioned package inventory must not pass');
    emit({ ...report, Results: [...report.Results, { Target: 'unassessed binary', Class: 'lang-pkgs' }] });
    assert.notEqual(run('echo example.test/image:1').status, 0, 'an unassessed result must not hide behind a valid one');
    emit({ ...report, Results: [{ ...report.Results[0], Vulnerabilities: [{ Severity: 'HIGH' }] }] });
    assert.notEqual(run('echo example.test/image:1').status, 0, 'findings must fail even when scanner exits zero');
    emit(report);
    assert.equal(run('echo example.test/image:1').status, 0);
    assert.equal(run('echo example.test/image:1').status, 0);
    const runs = readdirSync(reportDir);
    assert.equal(runs.length, 12, 'each invocation needs a new directory');
    for (const directory of runs) assert.equal(statSync(join(reportDir, directory)).mode & 0o777, 0o700);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
