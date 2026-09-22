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
    writeFileSync(join(root, 'bin/trivy'), '#!/bin/sh\nexit 0\n', { mode: 0o700 });
    const reportDir = join(root, 'reports');
    const run = inventory => {
      writeFileSync(join(root, 'scripts/compose.sh'), `#!/bin/sh\ncase "$*" in\n  *build) exit 0;;\n  *) ${inventory};;\nesac\n`);
      return spawnSync('bash', [join(root, 'scripts/scan-images.sh')], {
        encoding: 'utf8', env: { ...process.env, PATH: `${join(root, 'bin')}:${process.env.PATH}`, WAREHOUSE_SCAN_REPORT_DIR: reportDir },
      });
    };
    assert.notEqual(run('exit 1').status, 0, 'enumeration failure must not pass');
    assert.notEqual(run('exit 0').status, 0, 'empty inventory must not pass');
    assert.equal(run('echo example.test/image:1').status, 0);
    assert.equal(run('echo example.test/image:1').status, 0);
    const runs = readdirSync(reportDir);
    assert.equal(runs.length, 4, 'each invocation needs a new directory');
    for (const directory of runs) assert.equal(statSync(join(reportDir, directory)).mode & 0o777, 0o700);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
