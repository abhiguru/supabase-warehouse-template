// Shared fixtures for the backup, verify-restore and in-place restore tests.
// Everything runs against a fake `docker` on PATH; no container is started.
import { mkdirSync, writeFileSync, copyFileSync, existsSync, readdirSync, readFileSync, mkdtempSync, rmSync, statSync, lstatSync } from 'node:fs';
import { createHmac, createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

export const repo = fileURLToPath(new URL('..', import.meta.url));
// The database image a backup of this release records (scripts/db-image.sh: the FROM line of docker/postgres/Dockerfile).
export const currentDatabaseImage = () => readFileSync(join(repo, 'docker/postgres/Dockerfile'), 'utf8').match(/^FROM (postgres:\S+@sha256:[0-9a-f]{64})$/m)[1];
export const instanceJson = '{"schemaVersion":1,"instanceId":"0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f"}\n';
// A fictional central key set (public keys only), as `setup.sh --central-jwks-file` copies it to public/central-jwks.json.
export const centralKeySet = JSON.stringify({ keys: [{ kty: 'EC', crv: 'P-256', kid: 'central-2026-10', use: 'sig', alg: 'ES256',
  x: 'f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU', y: 'x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0' }] }, null, 2) + '\n';
// Fictional letterhead images (only the signature and a few bytes matter): setup.sh --letterhead-file copies one to public/letterhead.jpg or .png.
export const pngLetterhead = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from('fictional png letterhead bytes')]);
export const jpegLetterhead = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.from('fictional jpeg letterhead bytes')]);
// Fixed fictional database passwords as a state of this release holds them
// (scripts/db-roles.mjs): the superuser's and one per service login. The pooler is off by default: no pooler login or secret.
export const dbRoleLines = `POSTGRES_PASSWORD=${'5'.repeat(64)}\nDB_PASSWORD_AUTHENTICATOR=${'1'.repeat(64)}\n` +
  `DB_PASSWORD_STORAGE=${'2'.repeat(64)}\nPOOLER_ENABLED=false\n`;
// A state that ran `bash scripts/pooler.sh on`: the switch, the pool user's password and the two pooler secrets.
export const poolerOnLines = `POOLER_ENABLED=true\nDB_PASSWORD_POOLER=${'4'.repeat(64)}\nSECRET_KEY_BASE=${'6'.repeat(128)}\nVAULT_ENC_KEY=${'7'.repeat(32)}\n`;
// A state or backup from before the pooler had a switch: the pooler secrets exist, POOLER_ENABLED does not.
export const legacyPoolerLines = `DB_PASSWORD_POOLER=${'4'.repeat(64)}\nSECRET_KEY_BASE=${'6'.repeat(128)}\nVAULT_ENC_KEY=${'7'.repeat(32)}\n`;
// A state of the previous release has the superuser password only.
export const previousReleaseDbLines = `POSTGRES_PASSWORD=${'5'.repeat(64)}\n`;
export const composeEnv = (state, extra = 'JWT_SECRET=current-secret\n', db = dbRoleLines) =>
  `WAREHOUSE_PROJECT_NAME=warehouse-backup-test\nWAREHOUSE_DB_PATH=${state}/data/db\n` +
  `WAREHOUSE_STORAGE_PATH=${state}/data/storage\nWAREHOUSE_MANIFEST_PATH=${state}/public/instance.json\n${extra}${db}`;

// A fixed fictional backup key; the state fixture holds it as config/backup.key.
export const backupKey = '5a'.repeat(16) + '0f'.repeat(16);
// Signs with Node's HMAC, independently of the shell implementation in scripts/backup-key.sh.
export const hmacHex = (key, label, data) => createHmac('sha256', Buffer.from(key, 'hex')).update(`${label}\n`).update(data).digest('hex');
export function signBackup(dir, key = backupKey) {
  writeFileSync(join(dir, 'SHA256SUMS.hmac'), `warehouse-backup-hmac-v1 ${hmacHex(key, 'warehouse-backup-manifest-v1', readFileSync(join(dir, 'SHA256SUMS')))}\n`, { mode: 0o600 });
  return dir;
}
export function writeKey(path, key = backupKey) { writeFileSync(path, `${key}\n`, { mode: 0o600 }); return path; }

export function makeState(scratch, { env } = {}) {
  const state = join(scratch, 'state');
  mkdirSync(state, { mode: 0o700 });
  for (const path of ['config', 'public', 'data', 'data/db', 'data/storage']) mkdirSync(join(state, path), { mode: 0o700 });
  writeFileSync(join(state, 'config/compose.env'), env ?? composeEnv(state), { mode: 0o600 });
  writeFileSync(join(state, 'public/instance.json'), instanceJson);
  writeKey(join(state, 'config/backup.key'));
  writeFileSync(join(state, 'data/db/PG_VERSION'), '15\n');
  writeFileSync(join(state, 'data/storage/current-object'), 'current object data');
  return state;
}

// Extended attributes for the tests, with whatever the host has: setfattr/getfattr (package attr), else python3's os module.
// xattrTool() is null when neither works on the temporary directory's filesystem (some tmpfs and overlay mounts refuse
// user.* attributes): a test that needs attributes then skips itself.
function xattrTools() {
  const probe = mkdtempSync(join(tmpdir(), 'warehouse-xattr-probe-'));
  try {
    const file = join(probe, 'f');
    writeFileSync(file, 'x');
    const candidates = [
      {
        kind: 'attr',
        set: (path, name, value) => spawnSync('setfattr', ['-n', name, '-v', value, path], { encoding: 'utf8' }),
        get: (path, name) => spawnSync('getfattr', ['-n', name, '--only-values', path], { encoding: 'utf8' }),
        // The same operation as text for a shell (a test hands it to the fake docker as FAKE_ON_STOP).
        shell: (path, name, value) => `setfattr -n ${name} -v '${value}' '${path}'`,
      },
      {
        kind: 'python3',
        set: (path, name, value) => spawnSync('python3', ['-I', '-c', 'import os, sys; os.setxattr(sys.argv[1], sys.argv[2], sys.argv[3].encode())', path, name, value], { encoding: 'utf8' }),
        get: (path, name) => spawnSync('python3', ['-I', '-c', 'import os, sys; sys.stdout.write(os.getxattr(sys.argv[1], sys.argv[2]).decode())', path, name], { encoding: 'utf8' }),
        shell: (path, name, value) => `python3 -I -c 'import os, sys; os.setxattr(sys.argv[1], sys.argv[2], sys.argv[3].encode())' '${path}' '${name}' '${value}'`,
      },
    ];
    for (const tool of candidates) {
      const set = tool.set(file, 'user.supabase.probe', 'yes');
      if (set.error || set.status !== 0) continue;
      const got = tool.get(file, 'user.supabase.probe');
      if (!got.error && got.status === 0 && got.stdout === 'yes') {
        return {
          kind: tool.kind,
          set: (path, name, value) => { const r = tool.set(path, name, value); if (r.status !== 0) throw new Error(`setting ${name} on ${path}: ${r.stderr}`); },
          get: (path, name) => { const r = tool.get(path, name); return r.status === 0 ? r.stdout : null; },
          shell: tool.shell,
        };
      }
    }
    return null;
  } finally { rmSync(probe, { recursive: true, force: true }); }
}
let xattrToolCache;
export const xattrTool = () => (xattrToolCache === undefined ? (xattrToolCache = xattrTools()) : xattrToolCache);
// The reason to give node:test's `skip` option when extended attributes cannot be used here, else false.
export const xattrSkip = () => (xattrTool() ? false : 'no tool (setfattr, getfattr, python3) or no user.* extended attributes on the temporary directory');

// Every file under `root` as sorted relative paths.
export function filesUnder(root) {
  const found = [];
  const walk = dir => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) walk(path); else found.push(relative(root, path));
    }
  };
  walk(root);
  return found.sort();
}
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
// The manifest text scripts/backup.sh writes for a tree: "<sha256>  <path>" per file in byte order of the path.
export function manifestOf(root) {
  return filesUnder(root).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
    .map(path => `${sha256(readFileSync(join(root, path)))}  ${path}\n`).join('');
}

// A backup directory as scripts/backup.sh writes it. `objects` are catalog
// entries (<bucket>/<name>/<version>); `files` are archive paths relative to
// the storage root, defaulting to the tenant-prefixed layout of every object.
// v5 (the default) keeps them in storage.tar.gz; `format: 'warehouse-backup-v6'` keeps them as a storage/ tree with a
// storage.manifest in the list instead (`xattrs` maps a file path to { 'user.supabase.content-type': 'application/pdf' } and is
// applied when this host can set attributes; `storageBytes` overrides the size metadata.txt records).
// v5 and v6 backups are signed with `key`; pass `key: null` for one without a signature.
// `centralKey` adds the optional central-jwks.json (text), checksummed like the rest; `letterhead` ({ name, bytes }) adds letterhead.jpg or .png.
// `legacyPooler` adds _supabase.dump, which backups from before the pooler became optional carry (restores skip it).
export function makeBackup(dir, { format = 'warehouse-backup-v5', databaseImage = currentDatabaseImage(), key = backupKey, instance = instanceJson, env = 'WAREHOUSE_PROJECT_NAME=warehouse-backup-test\n', centralKey = null, letterhead = null, roles = 'anon\nauthenticated\nauthenticator\npgbouncer\nservice_role\nsupabase_admin\nsupabase_storage_admin\n', imageLines = 1,
  legacyPooler = false, objects = ['documents/a.pdf/v1'], files = objects.map(entry => `stub/stub/${entry}`), integrity = 'fake integrity\n', xattrs = {}, storageBytes = null } = {}) {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const v6 = format === 'warehouse-backup-v6';
  const tree = v6 ? join(dir, 'storage') : join(dir, '.tree');
  mkdirSync(tree, { mode: 0o755 });
  for (const file of files) {
    mkdirSync(join(tree, file, '..'), { recursive: true });
    writeFileSync(join(tree, file), `bytes of ${file}`);
  }
  if (v6) {
    const tool = xattrTool();
    for (const [file, attributes] of Object.entries(xattrs)) for (const [name, value] of Object.entries(attributes)) if (tool) tool.set(join(tree, file), name, value);
  } else {
    const tar = spawnSync('tar', ['--sort=name', '--mtime=@0', '--owner=0', '--group=0', '--numeric-owner', '-C', tree, '-czf', join(dir, 'storage.tar.gz'), '.'], { encoding: 'utf8' });
    if (tar.status !== 0) throw new Error(tar.stderr);
    spawnSync('rm', ['-rf', tree]);
  }
  const totalBytes = v6 ? files.reduce((sum, file) => sum + statSync(join(tree, file)).size, 0) : 0;
  const content = {
    'database.dump': 'fake database dump\n', 'integrity.txt': integrity,
    'metadata.txt': `format=${format}\ncreated_at_utc=20260101T000000Z\n${databaseImage === null ? '' : `database_image=${databaseImage}\n`.repeat(imageLines)}` +
      (v6 ? `link_base=none\nstorage_files=${files.length}\nstorage_bytes=${storageBytes ?? totalBytes}\nstorage_new_bytes=${totalBytes}\nstop_seconds=1\nduration_seconds=2\n` : ''),
    'compose.env': env, 'instance.json': instance, 'roles.txt': roles,
  };
  if (v6) content['storage.manifest'] = manifestOf(tree);
  if (format === 'warehouse-backup-v4' || format === 'warehouse-backup-v5' || v6) {
    // A backup made before the pooler became optional also holds the pooler's metadata database (legacyPooler: true).
    if (legacyPooler) content['_supabase.dump'] = 'fake supabase dump\n';
    content['storage_objects.txt'] = objects.length ? objects.join('\n') + '\n' : '';
  }
  if (centralKey !== null) content['central-jwks.json'] = centralKey;
  if (letterhead !== null) content[letterhead.name] = letterhead.bytes;
  for (const [name, body] of Object.entries(content)) writeFileSync(join(dir, name), body, { mode: 0o600 });
  const listed = [v6 ? 'storage.manifest' : 'storage.tar.gz', ...Object.keys(content).filter(name => name !== 'storage.manifest')];
  const sums = spawnSync('sha256sum', listed, { cwd: dir, encoding: 'utf8' });
  if (sums.status !== 0) throw new Error(sums.stderr);
  writeFileSync(join(dir, 'SHA256SUMS'), sums.stdout, { mode: 0o600 });
  if ((format === 'warehouse-backup-v5' || v6) && key) signBackup(dir, key);
  return dir;
}

// Fake docker for restore flows. Plain `docker run/exec/cp` serve
// verify-restore.sh; `docker compose` serves compose.sh callers. The catalog
// query returns FAKE_CATALOG_FILE, psql reads of the restored databases return
// the fixed integrity text, and the final full `up` fails when FAKE_FAIL_START=yes;
// the storage container's script (scripts/retag-storage-metadata.cjs) is called as `node -e SCRIPT probe|all`: each call logs
// "RETAG-CALL <mode>"; the probe answers FAKE_PROBE_RC (10, "some file has no content type", by default; 0 means none lacks one)
// and keeps the catalog it was fed in FAKE_PROBE_STDIN, the full run in FAKE_RETAG_STDIN;
// `compose ps --all` then lists one unhealthy service, whose log has one line.
// FAKE_FAIL_CREATEDB=yes makes the disposable createdb fail the way a busy template does.
// What scripts/db-roles.sh sends to the database container on standard input is
// appended to FAKE_STDIN_LOG when that is set.
export function fakeDocker(bin) {
  mkdirSync(bin, { recursive: true, mode: 0o700 });
  writeFileSync(join(bin, 'docker'), `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  ps) exit 0 ;;
  run) printf 'deadbeefcafe\\n' ;;
  cp|rm|volume) exit 0 ;;
  image) if [ -n "$FAKE_BUILT_MARK" ] && [ -f "$FAKE_BUILT_MARK" ]; then printf 'sha256:%064d\\n' 7; else exit 1; fi ;;
  logs) printf 'fake container log line\\nPostgreSQL init process complete; ready for start up.\\n'; if [ "$FAKE_LOG_NO_SPACE" = yes ]; then printf 'ERROR:  could not extend file "base/1/2": No space left on device\\n'; fi ;;
  inspect)
    case "$3" in
      *State.Health.Status*) printf 'healthy\\n' ;;
      *State.Running*) printf 'true\\n' ;;
    esac ;;
  exec)
    case "$*" in
      *' pg_isready '*) exit 0 ;;
      *'Dumped from database version'*) printf '%s\\n' "\${FAKE_DUMP_VERSION:-18.6}" ;;
      *pg_stat_activity*) printf '41|client backend|template1|idle\\n' ;;
      *' createdb '*) if [ "$FAKE_FAIL_CREATEDB" = yes ]; then echo 'createdb: error: database creation failed: ERROR:  source database is being accessed by other users' >&2; exit 1; fi ;;
      *'storage.objects'*) cat "$FAKE_CATALOG_FILE" ;;
      *' psql '*' -d warehouse_restore') printf 'fake integrity\\n' ;;
    esac ;;
  compose)
    case "$*" in
      *' config --format json') if [ -n "$FAKE_COMPOSE_CONFIG" ]; then cat "$FAKE_COMPOSE_CONFIG"; else printf '{"name":"warehouse-backup-test","services":{}}\\n'; fi ;;
      *' build '*) if [ -n "$FAKE_BUILT_MARK" ] && [ "$FAKE_BUILD_FAILS" != yes ]; then : > "$FAKE_BUILT_MARK"; if [ "$FAKE_BUILD_NOOP" = yes ]; then echo drift >> "$FAKE_BUILD_CONTEXT/drift"; fi; fi; [ "$FAKE_BUILD_FAILS" != yes ] ;;
      *' exec -T db sh -c IFS= read -r pw;'*) cat >> "\${FAKE_STDIN_LOG:-/dev/null}" ;;
      *' ps -q') if [ "$FAKE_RUNNING" = yes ]; then printf 'abcdef123456\\n'; fi ;;
      *' ps --all --format '*) printf 'db running healthy\\nrest running \\nstorage running unhealthy\\nfunctions exited \\n' ;;
      *' logs --no-color --tail 30 '*) printf 'fake log of %s\\n' "$(printf '%s' "$*" | sed 's/.* //')" ;;
      *' up -d --wait --wait-timeout 180') if [ "$FAKE_FAIL_START" = yes ]; then exit 7; fi ;;
      *'exec -T storage node'*)
        for last; do :; done
        printf 'RETAG-CALL %s\\n' "$last" >> "$FAKE_DOCKER_LOG"
        if [ "$last" = probe ]; then cat >> "\${FAKE_PROBE_STDIN:-/dev/null}"; exit "\${FAKE_PROBE_RC:-10}"; fi
        cat >> "\${FAKE_RETAG_STDIN:-/dev/null}" ;;
      *'exec -T db psql'*jsonb_build_object*) cat "\${FAKE_RETAG_CATALOG:-/dev/null}" ;;
      *'exec -T db psql'*'storage.objects'*) cat "$FAKE_CATALOG_FILE" ;;
      *'exec -T db psql'*' -d postgres') printf 'fake integrity\\n' ;;
    esac ;;
esac
`, { mode: 0o700 });
  return bin;
}

// Fake docker for scripts/backup.sh: the commands it runs against the database and the services, answered with fixed text.
// Every `stop`, `pg_dump` and `up` is logged to FAKE_DOCKER_LOG together with a snapshot of the staging directory that
// backup.sh is filling under FAKE_STAGE_PARENT ("SNAPSHOT <call> tree=<pass1|final> files=<files in that tree> manifest=<yes|no> dump=<yes|no>"),
// which is how a test sees what had been done at that moment. FAKE_ON_STOP is a shell snippet run when the first service is
// stopped (the Storage service finishing a last upload before it stops). FAKE_DOCKER_FAIL=yes fails the dump,
// FAKE_FAIL_UP=yes fails the restart, FAKE_SERVER sets the server version answer.
export function fakeBackupDocker(bin) {
  mkdirSync(bin, { recursive: true, mode: 0o700 });
  writeFileSync(join(bin, 'docker'), `#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_DOCKER_LOG"
snap() {
  stage=$(ls -d "$FAKE_STAGE_PARENT"/.warehouse-backup-staging.* 2>/dev/null | head -n 1)
  if [ -n "$stage" ]; then
    # tree=pass1: the first pass's copy is all there is (storage-pass1/); tree=final: the last pass has made storage/.
    if [ -d "$stage/storage" ]; then tree=final; dir="$stage/storage"; else tree=pass1; dir="$stage/storage-pass1"; fi
    printf 'SNAPSHOT %s tree=%s files=%s manifest=%s dump=%s\\n' "$1" "$tree" "$(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ')" "$([ -e "$stage/storage.manifest" ] && echo yes || echo no)" "$([ -s "$stage/database.dump" ] && echo yes || echo no)" >> "$FAKE_DOCKER_LOG"
  fi
}
case "$1" in
  ps) exit 0 ;;
  inspect)
    case "$3" in
      *State.Health.Status*) printf 'healthy\\n' ;;
      *State.Running*) printf 'true\\n' ;;
    esac ;;
  compose)
    case "$*" in
      *' up -d --no-recreate'*) snap up; if [ "$FAKE_FAIL_UP" = yes ]; then exit 1; fi ;;
      *' stop '*) snap stop; if [ -n "$FAKE_ON_STOP" ] && [ ! -e "$FAKE_DOCKER_LOG.on-stop-ran" ]; then : > "$FAKE_DOCKER_LOG.on-stop-ran"; sh -c "$FAKE_ON_STOP"; fi ;;
      *'ps --all --format'*) if [ "$FAKE_FAIL_UP" = yes ]; then printf 'storage running unhealthy\\n'; fi ;;
      *' logs '*) printf 'fake log of %s\\n' "$(printf '%s' "$*" | awk '{print $NF}')" ;;
      *' ps -q db') printf 'bbbbbbbbbbbb\\n' ;;
      *' ps -q gateway') printf 'aaaaaaaaaaaa\\n' ;;
      *' ps -q storage') printf 'cccccccccccc\\n' ;;
      *' ps -q '*) : ;;
      *'exec -T db pg_dump'*) snap pg_dump; if [ "$FAKE_DOCKER_FAIL" = yes ]; then exit 42; fi; printf 'fake database dump\\n' ;;
      *'exec -T db psql'*server_version_num*) printf '%s\\n' "\${FAKE_SERVER:-18|true}" ;;
      *'exec -T db psql'*' -c SELECT rolname'*) printf 'authenticator\\nsupabase_admin\\n' ;;
      *'exec -T db psql'*'storage.objects'*) printf 'documents/a.pdf/v1\\n' ;;
      *'exec -T db psql'*) printf 'fake integrity\\n' ;;
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
    if (/\.(sh|sql|mjs|cjs)$/.test(name)) copyFileSync(join(repo, 'scripts', name), join(root, 'scripts', name));
  }
  copyFileSync(join(repo, 'docker/volumes/db/00-bootstrap.sql'), join(root, 'docker/volumes/db/00-bootstrap.sql'));
  mkdirSync(join(root, 'docker/postgres'), { recursive: true, mode: 0o700 });
  copyFileSync(join(repo, 'docker/postgres/Dockerfile'), join(root, 'docker/postgres/Dockerfile'));
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
