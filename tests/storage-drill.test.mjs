import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// tests/storage-drill.sh against a fake docker that records every call. The fake answers just enough for the drill to get through step 1 and 2
// (or, with STOP_AT=1, to fail step 1 because the Storage container is not running), so the cleanup that follows can be read from the calls:
// which images it removes, how, and which it leaves. Nothing here touches a real Docker.
const SCRIPT = new URL('../tests/storage-drill.sh', import.meta.url).pathname;
const id = c => `sha256:${c.repeat(64)}`;
const BUILT = id('b');
const NEXT = id('e');
const OTHER = id('0');

// snapshot: image ids on the fake host before the drill; build: the id `docker build -q` prints; next: the id of the pulled next image.
function drill({ snapshot = [], build = BUILT, next = NEXT, env = {} } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-storage-drill-test-'));
  const bin = join(scratch, 'bin');
  mkdirSync(bin);
  const calls = join(scratch, 'calls');
  writeFileSync(join(scratch, 'snapshot'), snapshot.map(i => `${i}\n`).join(''));
  // exec: the drill's psql and in-container shell calls are told apart by the text of the query/script they carry.
  writeFileSync(join(bin, 'docker'), `#!/bin/bash
printf '%s\\n' "$*" >> "${calls}"
all="$*"
case "$1" in
  build) echo "$FAKE_BUILD_ID" ;;
  pull) ;;
  image)
    case "$2" in
      # The listing is only the host's full list with -a (untagged and intermediate images included), and it can fail.
      ls) [ "$FAKE_LS_FAILS" = 1 ] && exit 1; case "$all" in *-aq*) cat "${scratch}/snapshot" ;; esac ;;
      inspect) case "$all" in *"{{.Id}}"*) echo "$FAKE_NEXT_ID" ;; *) exit 1 ;; esac ;;
      rm) ;;
      prune) echo 'image prune must never be called' >&2; exit 99 ;;
    esac ;;
  rmi) ;;
  inspect) echo false ;;
  logs)
    echo 'PostgreSQL init process complete; ready for start up'
    case "$all" in *drill-frozen*) ;; *) [ "$STOP_AT" = 1 ] || echo 'Started Successfully' ;; esac ;;
  run) case "$all" in *"--entrypoint sh"*) echo '0074-next-migration.sql' ;; esac ;;
  exec)
    cat > /dev/null
    case "$all" in
      *'max(id)'*) echo 73 ;;
      *'FROM storage.migrations WHERE id = 73'*) echo revoke-grants-to-unused-operations ;;
      *'count(*) FROM storage.migrations'*) echo 5 ;;
      *'count(*) FROM storage.objects'*) echo 2 ;;
      *md5*) echo catalogmd5 ;;
      *'read=$n bad=$bad'*) echo 'read=2 bad=0' ;;
      *'signed=$ok/$n'*) echo 'signed=25/25' ;;
      *'SELECT name FROM storage.objects'*) echo 'lot-1/doc-1.txt' ;;
    esac ;;
esac
exit 0
`, { mode: 0o755 });
  const r = spawnSync('bash', [SCRIPT], { encoding: 'utf8', timeout: 120000, env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, TMPDIR: scratch,
    FAKE_BUILD_ID: build, FAKE_NEXT_ID: next, STORAGE_DRILL_OBJECTS: '1', ...env } });
  const lines = existsSync(calls) ? readFileSync(calls, 'utf8').split('\n').filter(Boolean) : [];
  rmSync(scratch, { recursive: true, force: true });
  return { ...r, lines, removals: lines.filter(l => /^(image rm|rmi)( |$)/.test(l)) };
}

test('an image id that was on the host before the build is never removed', () => {
  const r = drill({ snapshot: [OTHER, BUILT], env: { STOP_AT: '1' } });
  assert.notEqual(r.status, 0, 'step 1 fails in this world');
  assert.match(r.stderr, /the current image did not start/);
  assert.ok(r.lines.some(l => l.startsWith('build -q ')), 'the image was built');
  assert.deepEqual(r.removals, [], r.lines.join('\n'));
});

test('an image id the build made new is removed once, by exact id', () => {
  const r = drill({ snapshot: [OTHER], env: { STOP_AT: '1' } });
  assert.notEqual(r.status, 0);
  assert.deepEqual(r.removals, [`image rm ${BUILT}`]);
});

test('the build is untagged and the listing comes first; removal never uses rmi, -f/--force or prune', () => {
  const r = drill({ snapshot: [OTHER], env: { STOP_AT: '1' } });
  const build = r.lines.find(l => l.startsWith('build '));
  assert.match(build, /^build -q [^ ]+$/, 'no -t: the id is the only name');
  assert.ok(r.lines.indexOf('image ls -aq --no-trunc') >= 0 && r.lines.indexOf('image ls -aq --no-trunc') < r.lines.indexOf(build), 'snapshot before the build');
  assert.ok(!r.lines.some(l => /^rmi( |$)/.test(l)), 'no rmi');
  assert.ok(!r.lines.some(l => /^image prune/.test(l)), 'no prune');
  for (const l of r.removals) assert.doesNotMatch(l, /(^| )(-f|--force)( |$)/, l);
});

test('a build that prints no image id fails the drill and removes nothing', () => {
  const r = drill({ build: 'not-an-id' });
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /did not print an image id/);
  assert.deepEqual(r.removals, []);
});

const NEXT_ENV = { STORAGE_NEXT_TAG: 'v1.99.0' };
test('the pulled next image: removed by id when the pull made it, left when its id was already on the host', () => {
  // Step 3 fails here (the frozen container never reports "Started Successfully"), which ends the drill 0 with a warning and runs the cleanup.
  const mine = drill({ snapshot: [OTHER, BUILT], env: NEXT_ENV });
  assert.ok(mine.lines.some(l => l === 'pull -q supabase/storage-api:v1.99.0'), mine.lines.join('\n'));
  assert.deepEqual(mine.removals, [`image rm ${NEXT}`]);
  const theirs = drill({ snapshot: [OTHER, BUILT, NEXT], env: NEXT_ENV });
  assert.ok(theirs.lines.some(l => l === 'pull -q supabase/storage-api:v1.99.0'), 'the tag was absent, so it was pulled');
  assert.deepEqual(theirs.removals, [], theirs.lines.join('\n'));
});

test('built and pulled images that are both new are removed by id, one each', () => {
  const r = drill({ snapshot: [OTHER], env: NEXT_ENV });
  assert.deepEqual(r.removals.sort(), [`image rm ${BUILT}`, `image rm ${NEXT}`].sort());
});

test('when the image listing fails the drill stops before building anything, and removes nothing', () => {
  const r = drill({ snapshot: [OTHER], env: { FAKE_LS_FAILS: '1' } });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /Storage drill FAILED: cannot list the images of the host/);
  assert.ok(!r.lines.some(l => /^(build|pull) /.test(l)), r.lines.join('\n'));
  assert.deepEqual(r.removals, []);
});

test('the listing includes untagged and intermediate images (-a): an id that only a full listing shows is never removed', () => {
  const r = drill({ snapshot: [BUILT], env: { STOP_AT: '1' } });   // the fake shows the snapshot only for a listing made with -a
  assert.ok(r.lines.some(l => /^image ls -\w*a\w* /.test(l)), r.lines.join('\n'));
  assert.deepEqual(r.removals, [], r.lines.join('\n'));
});
