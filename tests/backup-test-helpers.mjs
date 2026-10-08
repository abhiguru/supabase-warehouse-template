// Shared fixtures for the backup, verify-restore and in-place restore tests.
// Everything runs against a fake `docker` on PATH; no container is started.
import { mkdirSync, writeFileSync, copyFileSync, existsSync, readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const repo = fileURLToPath(new URL('..', import.meta.url));
export const instanceJson = '{"schemaVersion":1,"instanceId":"0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f"}\n';
export const composeEnv = (state, extra = 'JWT_SECRET=current-secret\n') =>
  `WAREHOUSE_PROJECT_NAME=warehouse-backup-test\nWAREHOUSE_DB_PATH=${state}/data/db\n` +
  `WAREHOUSE_STORAGE_PATH=${state}/data/storage\nWAREHOUSE_MANIFEST_PATH=${state}/public/instance.json\n${extra}`;

export function makeState(scratch, { env } = {}) {
  const state = join(scratch, 'state');
  mkdirSync(state, { mode: 0o700 });
  for (const path of ['config', 'public', 'data', 'data/db', 'data/storage']) mkdirSync(join(state, path), { mode: 0o700 });
  writeFileSync(join(state, 'config/compose.env'), env ?? composeEnv(state), { mode: 0o600 });
  writeFileSync(join(state, 'public/instance.json'), instanceJson);
  writeFileSync(join(state, 'data/db/PG_VERSION'), '15\n');
  writeFileSync(join(state, 'data/storage/current-object'), 'current object data');
  return state;
}

// A backup directory as scripts/backup.sh writes it. `objects` are catalog
// entries (<bucket>/<name>/<version>); `files` are archive paths relative to
// the storage root, defaulting to the tenant-prefixed layout of every object.
export function makeBackup(dir, { format = 'warehouse-backup-v4', instance = instanceJson, env = 'WAREHOUSE_PROJECT_NAME=warehouse-backup-test\n',
  objects = ['documents/a.pdf/v1'], files = objects.map(entry => `stub/stub/${entry}`), integrity = 'fake integrity\n' } = {}) {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tree = join(dir, '.tree');
  mkdirSync(tree, { mode: 0o700 });
  for (const file of files) {
    mkdirSync(join(tree, file, '..'), { recursive: true });
    writeFileSync(join(tree, file), `bytes of ${file}`);
  }
  const tar = spawnSync('tar', ['--sort=name', '--mtime=@0', '--owner=0', '--group=0', '--numeric-owner', '-C', tree, '-czf', join(dir, 'storage.tar.gz'), '.'], { encoding: 'utf8' });
  if (tar.status !== 0) throw new Error(tar.stderr);
  spawnSync('rm', ['-rf', tree]);
  const content = {
    'database.dump': 'fake database dump\n', 'integrity.txt': integrity,
    'metadata.txt': `format=${format}\ncreated_at_utc=20260101T000000Z\n`,
    'compose.env': env, 'instance.json': instance, 'roles.txt': 'postgres\nsupabase_admin\nsupabase_realtime_admin\n',
  };
  if (format === 'warehouse-backup-v4') {
    content['_supabase.dump'] = 'fake supabase dump\n';
    content['storage_objects.txt'] = objects.length ? objects.join('\n') + '\n' : '';
  }
  for (const [name, body] of Object.entries(content)) writeFileSync(join(dir, name), body, { mode: 0o600 });
  const listed = ['storage.tar.gz', ...Object.keys(content)];
  const sums = spawnSync('sha256sum', listed, { cwd: dir, encoding: 'utf8' });
  if (sums.status !== 0) throw new Error(sums.stderr);
  writeFileSync(join(dir, 'SHA256SUMS'), sums.stdout, { mode: 0o600 });
  return dir;
}

// Fake docker for restore flows. Plain `docker run/exec/cp` serve
// verify-restore.sh; `docker compose` serves compose.sh callers. The catalog
// query returns FAKE_CATALOG_FILE, psql reads of the restored databases return
// the fixed integrity text, and the final full `up` fails when FAKE_FAIL_START=yes.
export function fakeDocker(bin) {
  mkdirSync(bin, { recursive: true, mode: 0o700 });
  writeFileSync(join(bin, 'docker'), `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  ps) exit 0 ;;
  run) printf 'deadbeefcafe\\n' ;;
  cp|rm) exit 0 ;;
  inspect)
    case "$3" in
      *State.Health.Status*) printf 'healthy\\n' ;;
      *State.Running*) printf 'true\\n' ;;
    esac ;;
  exec)
    case "$*" in
      *' pg_isready '*) exit 0 ;;
      *'storage.objects'*) cat "$FAKE_CATALOG_FILE" ;;
      *' psql '*' -d warehouse_restore') printf 'fake integrity\\n' ;;
    esac ;;
  compose)
    case "$*" in
      *' ps -q') if [ "$FAKE_RUNNING" = yes ]; then printf 'abcdef123456\\n'; fi ;;
      *' up -d --wait --wait-timeout 180') if [ "$FAKE_FAIL_START" = yes ]; then exit 7; fi ;;
      *'exec -T db psql'*'storage.objects'*) cat "$FAKE_CATALOG_FILE" ;;
      *'exec -T db psql'*' -d postgres') printf 'fake integrity\\n' ;;
    esac ;;
esac
`, { mode: 0o700 });
  return bin;
}

// A private copy of the operator scripts so restore.sh can be exercised with a
// stand-in lock helper while scripts/operator-lock.sh is still landing.
export function scriptRoot(scratch) {
  const root = join(scratch, 'root');
  mkdirSync(join(root, 'scripts'), { recursive: true, mode: 0o700 });
  mkdirSync(join(root, 'docker/volumes/db'), { recursive: true, mode: 0o700 });
  for (const name of readdirSync(join(repo, 'scripts'))) {
    if (/\.(sh|sql)$/.test(name)) copyFileSync(join(repo, 'scripts', name), join(root, 'scripts', name));
  }
  copyFileSync(join(repo, 'docker/volumes/db/jwt.sql'), join(root, 'docker/volumes/db/jwt.sql'));
  if (!existsSync(join(root, 'scripts/operator-lock.sh'))) {
    writeFileSync(join(root, 'scripts/operator-lock.sh'), [
      '#!/usr/bin/env bash',
      '# Test-only stand-in for scripts/operator-lock.sh (plan item 1.1).',
      'operator_state() {',
      '  local state="${WAREHOUSE_STATE_DIR:-}"',
      '  [[ "$state" == /* && ! -L "$state" && -d "$state/config" ]] || { echo "Set WAREHOUSE_STATE_DIR to the absolute installed operator state path." >&2; return 1; }',
      '  printf "%s\\n" "$state"',
      '}',
      'operator_lock() {',
      '  local state="${1:-}"',
      '  [[ -n "$state" ]] || state="$(operator_state)" || return 1',
      '  exec 9>"$state/config/operator.lock"',
      '  flock -n 9 || { echo "Another operator command is running for this state." >&2; return 1; }',
      '}',
      '',
    ].join('\n'));
  }
  return root;
}
