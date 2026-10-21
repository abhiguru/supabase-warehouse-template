import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// scripts/compose.sh refuses an existing db container whose data does not sit where this checkout expects it:
// another bind source, or an Env without PGDATA=/var/lib/postgresql/data (the official 18 image defaults elsewhere).
function run(env) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-compose-pgdata-'));
  try {
    const state = join(scratch, 'state');
    const bin = join(scratch, 'bin');
    for (const path of [state, join(state, 'config'), join(state, 'data/db'), join(state, 'data/storage'), bin]) mkdirSync(path, { recursive: true, mode: 0o700 });
    writeFileSync(join(state, 'config/compose.env'), `WAREHOUSE_PROJECT_NAME=warehouse-pgdata-test\nWAREHOUSE_DB_PATH=${state}/data/db\nWAREHOUSE_STORAGE_PATH=${state}/data/storage\n`, { mode: 0o600 });
    const root = new URL('..', import.meta.url).pathname.replace(/\/$/, '');
    writeFileSync(join(bin, 'docker'), `#!/bin/sh
case "$1" in
  ps) printf 'dbdbdbdbdbdb\n' ;;
  inspect)
    case "$*" in
      *working_dir*) printf '%s\n' "$FAKE_ROOT/docker" ;;
      *compose.service*) printf 'db\n' ;;
      *Mounts*) printf '%s\n' "$FAKE_SOURCE" ;;
      *Config.Env*) printf '%s' "$FAKE_ENV" ;;
    esac ;;
  compose) printf 'compose-reached\n' ;;
esac
`, { mode: 0o700 });
    return spawnSync('bash', [join(root, 'scripts/compose.sh'), 'ps'], { encoding: 'utf8',
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_ROOT: root, FAKE_SOURCE: `${state}/data/db`, ...env(state) } });
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

test('an existing db container with PGDATA at the mount is accepted', () => {
  const r = run(() => ({ FAKE_ENV: 'PATH=/bin\nPGDATA=/var/lib/postgresql/data\n' }));
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /compose-reached/);
});

test('an existing db container without that PGDATA, or with another one, is refused', () => {
  for (const envText of ['PATH=/bin\n', 'PGDATA=/var/lib/postgresql/18/docker\n']) {
    const r = run(() => ({ FAKE_ENV: envText }));
    assert.equal(r.status, 1, envText);
    assert.match(r.stderr, /Refusing: existing db container does not use PGDATA=\/var\/lib\/postgresql\/data\./);
    assert.doesNotMatch(r.stdout, /compose-reached/);
  }
});

test('the db service sets PGDATA and a tmpfs under the image volume, so no anonymous volume is left at stop', async () => {
  const { readFileSync } = await import('node:fs');
  const compose = readFileSync(new URL('../docker/docker-compose.yml', import.meta.url), 'utf8');
  assert.match(compose, /tmpfs:\n(?:\s+#.*\n)+\s+- \/var\/lib\/postgresql:size=16m/);
});
