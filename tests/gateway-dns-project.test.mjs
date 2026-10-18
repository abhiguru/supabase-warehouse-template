import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test('gateway DNS check uses the owned instance project label', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-dns-project-'));
  const state = join(scratch, 'state');
  const bin = join(scratch, 'bin');
  const project = 'warehouse-instance123';
  try {
    for (const path of [state, join(state, 'config'), join(state, 'data'), join(state, 'data/db'), join(state, 'data/storage'), bin]) mkdirSync(path, { recursive: true, mode: 0o700 });
    writeFileSync(join(state, 'config/compose.env'), `WAREHOUSE_PROJECT_NAME=${project}\nWAREHOUSE_DB_PATH=${state}/data/db\nWAREHOUSE_STORAGE_PATH=${state}/data/storage\n`, { mode: 0o600 });
    writeFileSync(join(bin, 'docker'), `#!/bin/sh
case "$1" in
  ps) exit 0 ;;
  compose) printf 'aaaaaaaaaaaa\\n'; exit 0 ;;
  inspect)
    case "$3" in
      *com.docker.compose.project*) printf '${project}\\n' ;;
      # Functions is on two networks: the address must be read from \`<project>_default\` by name. A range over
      # all networks would join both addresses, which the fake answers with.
      *'index .NetworkSettings.Networks \\"${project}_default\\"'*) printf '172.18.0.2\\n' ;;
      *NetworkSettings.Networks*) printf '172.18.0.2172.19.0.2\\n' ;;
      *) exit 0 ;;
    esac ;;
esac
`, { mode: 0o700 });
    const result = spawnSync('bash', [new URL('../scripts/gateway-dns-check.sh', import.meta.url).pathname], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state },
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /DNS test holder already exists/);
    assert.doesNotMatch(result.stderr, /Unexpected service network/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});
