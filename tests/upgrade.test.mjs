import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, copyFileSync, chmodSync, appendFileSync, readdirSync, truncateSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { readUpgradeRecord } from '../scripts/upgrade-record.mjs';

// upgrade.sh against a scratch "origin" with release tags and an installed checkout of it. The operator scripts that
// upgrade.sh calls (backup, verify-restore, compose, setup, checkout-permissions, pre-images, and watch.mjs for record-verified) are stubs that append what they were given, whether
// the operator lock was held while they ran and what the upgrade record said at that moment, to one log; upgrade.sh,
// scripts/operator-lock.sh, scripts/pg-major.sh, scripts/db-image.sh, scripts/ci-previous-tag.sh, scripts/alert-webhook.mjs,
// scripts/upgrade-lib.sh and scripts/upgrade-record.mjs are the real files.
const root = new URL('..', import.meta.url).pathname;
const gitEnv = {
  GIT_AUTHOR_NAME: 'Fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid', GIT_COMMITTER_NAME: 'Fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid',
  GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null', GIT_TERMINAL_PROMPT: '0',
};
const git = (cwd, ...args) => {
  const r = spawnSync('git', ['-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', '-C', cwd, ...args], { encoding: 'utf8', env: { ...process.env, ...gitEnv } });
  assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
};
const put = (dir, path, text, mode) => {
  mkdirSync(dirname(join(dir, path)), { recursive: true });
  writeFileSync(join(dir, path), text);
  if (mode) chmodSync(join(dir, path), mode);
};
const pause = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

const LOG_LOCK = '$(flock -n "$WAREHOUSE_STATE_DIR/config/operator.lock" true 9>&- && echo free || echo held)';
// What the upgrade record says at that moment: verified|step ("no|Backup" before the backup is proved).
const REC = `record=[$(rec verified)|$(rec step)]`;
const REC_FN = `rec() { sed -n "s/^$1=//p" "$WAREHOUSE_STATE_DIR/config/upgrade-in-progress" 2>/dev/null | head -n 1; }`;
const stubs = {
  'scripts/backup.sh': `#!/usr/bin/env bash
set -euo pipefail
${REC_FN}
echo "backup lock=${LOG_LOCK} version=$(cat "$(dirname "$0")/../VERSION") ${REC}" >> "$FAKE_LOG"
[[ "\${FAKE_FAIL:-}" != backup ]] || { echo 'backup failed (fake)' >&2; exit 1; }
n=$(find "$WAREHOUSE_STATE_DIR/backups" -mindepth 1 -maxdepth 1 | wc -l)
d="$WAREHOUSE_STATE_DIR/backups/warehouse-20260101T00000\${n}Z"; mkdir -p "$d"
echo "Backup created at $d"
`,
  'scripts/verify-restore.sh': `#!/usr/bin/env bash
set -euo pipefail
${REC_FN}
# The migration rehearsal of the target's preflight (scripts/upgrade-rehearse.sh) keeps a disposable database and removes it again; it is
# not the verification of the upgrade's own backup, so it is not logged here (tests/upgrade-preflight.test.mjs covers it).
if [[ "$1" == --rm ]]; then exit 0; fi
if [[ "$1" == --keep ]]; then echo 'Kept disposable database: warehouse-restore-0123456789ab (stub)'; exit 0; fi
echo "verify-restore $1 lock=${LOG_LOCK} version=$(cat "$(dirname "$0")/../VERSION") ${REC}" >> "$FAKE_LOG"
[[ "\${FAKE_FAIL:-}" != verify ]] || { echo 'verify failed (fake)' >&2; exit 1; }
`,
  'scripts/compose.sh': `#!/usr/bin/env bash
case "$*" in
  *warehouse_migrations.applied*)
    [[ "\${FAKE_FAIL:-}" != db ]] || { echo 'could not connect (fake)' >&2; exit 2; }
    [[ -z "\${FAKE_NOISE:-}" ]] || echo 'WARN[0000] a compose warning (fake)' >&2
    printf '%s' "$FAKE_LEDGER" ;;
  *pg_stat_activity*)
    # The check for sessions of psql from outside the stack: the query goes to the maintenance log (the test reads what it asks), the answer is
    # FAKE_SESSIONS (every time), or only the first time with FAKE_SESSIONS_ONCE=yes (a probe that was just finishing).
    echo "sessions-query $*" >> "$FAKE_LOG.maint"
    [[ "\${FAKE_FAIL:-}" != sessions ]] || { echo 'could not ask (fake)' >&2; exit 2; }
    if [[ "\${FAKE_SESSIONS_ONCE:-}" == yes && -e "$FAKE_LOG.sessions-asked" ]]; then exit 0; fi
    : > "$FAKE_LOG.sessions-asked"
    printf '%s' "\${FAKE_SESSIONS:-}" ;;
  *server_version_num*) printf '%s\\n' "\${FAKE_SERVER_NUM:-180006}" ;;
  *installer_admin_state*) printf '%s\\n' "\${FAKE_ADMIN_STATE:-match}" ;;
  *user_profiles*) printf '%s\\n' "$FAKE_ADMIN" ;;
  *) echo "compose $*" >> "$FAKE_LOG" ;;
esac
`,
  'setup.sh': `#!/usr/bin/env bash
set -euo pipefail
${REC_FN}
echo "setup $* | lock=${LOG_LOCK} version=$(cat "$(dirname "$0")/VERSION") running=\${WAREHOUSE_UPGRADE_RUNNING:-} ${REC}" >> "$FAKE_LOG"
echo "setup sees marker=$([[ -e "$WAREHOUSE_STATE_DIR/config/maintenance" ]] && echo yes || echo no)" >> "$FAKE_LOG.maint"
[[ "\${FAKE_HANG:-}" != setup ]] || sleep 30
[[ "\${FAKE_FAIL:-}" != setup ]] || { echo 'setup failed (fake)' >&2; exit 3; }
`,
  // Maintenance mode (scripts/maintenance.sh has its own test, tests/maintenance.test.mjs, with a fake docker): here a stand-in that keeps the marker the way
  // the real one does, and logs to a file of its own (FAKE_LOG.maint) how far the main log had got, who held the lock, whose copy it was and what
  // the record said, so that the order against the backup and the setup can be read without changing the main log. FAKE_MAINT=on|off makes that
  // command fail.
  'scripts/maintenance.sh': `#!/usr/bin/env bash
set -euo pipefail
${REC_FN}
marker="$WAREHOUSE_STATE_DIR/config/maintenance"
had=$([[ -e "$marker" ]] && echo yes || echo no)
echo "maintenance $1 mainlog=$(wc -l < "$FAKE_LOG" | tr -d ' ') marker-before=$had lock=${LOG_LOCK} version=$(cat "$(dirname "$0")/../VERSION") maintenance-in-record=$(rec maintenance) ${REC}" >> "$FAKE_LOG.maint"
[[ "\${FAKE_MAINT:-}" != "$1" ]] || { echo "maintenance $1 failed (fake)" >&2; exit 1; }
# FAKE_MAINT=off-open: the real script's exit status 2 for "the API is open, the health check failed" (it removes the marker first).
[[ "\${FAKE_MAINT:-}" != "$1-open" ]] || { rm -f "$marker"; echo "maintenance $1: health check failed (fake)" >&2; exit 2; }
case "$1" in
  on) echo upgrading > "$marker" ;;
  off) rm -f "$marker" ;;
esac
`,
  'scripts/checkout-permissions.sh': `#!/usr/bin/env bash
[[ "\${FAKE_FAIL:-}" != perms ]] || { echo 'checkout-permissions failed (fake)' >&2; exit 1; }
`,
  // The image helper is a stub here (the real one has its own test with a fake docker, tests/pre-images.test.mjs); what it was asked,
  // from which release's tree and under which record, goes to a log of its own so the order of the main log is not changed.
  'scripts/pre-images.sh': `#!/usr/bin/env bash
set -euo pipefail
${REC_FN}
case "$1" in
  name) printf 'pre-%s\\n' "$2"; exit 0 ;;
  tag) echo "pre-images tag $2 version=$(cat "$(dirname "$0")/../VERSION") ${REC} head=$(git -C "$(dirname "$0")/.." rev-parse HEAD)" >> "$FAKE_LOG.pre"
       case "\${FAKE_PRE:-}" in none) echo 'nothing to tag (fake)' >&2; exit 3 ;; fail) echo 'docker said no (fake)' >&2; exit 1 ;; esac ;;
  *) echo "pre-images $1 $2\${3:+ $3} version=$(cat "$(dirname "$0")/../VERSION")" >> "$FAKE_LOG.pre" ;;
esac
`,
  // The checker is a stand-in too (it has its own tests): upgrade.sh asks it to record the verified backup; FAKE_WATCH=fail makes it refuse.
  'scripts/watch.mjs': `import { appendFileSync } from 'node:fs';
appendFileSync(process.env.FAKE_LOG + '.pre', 'watch ' + process.argv.slice(2).join(' ') + '\\n');
if (process.env.FAKE_WATCH === 'fail') { console.error('watch could not record it (fake)'); process.exit(1); }
console.log('recorded');
`,
};
const statModeOf = path => parseInt(spawnSync('stat', ['-c', '%a', path], { encoding: 'utf8' }).stdout.trim(), 8);
const dockerfile = major => `FROM postgres:${major}.6-trixie@sha256:${'ab'.repeat(32)}\n`;
const changelog = sections => `# Changelog\n\n## Unreleased\n\n### Operator actions\n\n1. Not released yet: UNRELEASED-ACTION\n\n${sections}\n## Older history\n\nGit has it.\n`;
const S010 = '## v0.1.0 (2026-01-01)\n\nThe first release.\n\n';
const S011 = '## v0.1.1 (2026-02-01)\n\nA fix with no subsections: PLAIN-SECTION-LINE.\n\n';
const S020 = '## v0.2.0 (2026-03-01)\n\n### Operator actions\n\n1. Do the thing: ACTION-TWO.\n\n### Changed\n\n- Something changed: HIDDEN-CHANGE.\n\n';
const S009 = '## v0.0.9 (2026-01-15)\n\nA backport on its own line: BACKPORT-LINE.\n\n';
// An older release than the backport's, listed below v0.1.0 in a later CHANGELOG: the print stops at the first section that is not newer than
// the old release (v0.0.9, which has no section here), so this one must not appear.
const S005 = '## v0.0.5 (2025-12-01)\n\nAn older release: OLDER-THAN-BACKPORT-LINE.\n\n';
// A release whose section lists no operator actions.
const S0216 = '## v0.2.16 (2026-05-01)\n\n### Changed\n\n- A change that asks nothing of the operator: NOTHING-TO-DO-LINE.\n\n';

// `at` is the release the installed checkout sits on.
function world({ at = 'v0.1.0' } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-upgrade-'));
  const src = join(scratch, 'src');
  const origin = join(scratch, 'origin.git');
  const install = join(scratch, 'install');
  const state = join(scratch, 'state');
  mkdirSync(src);
  git(src, 'init', '-q', '-b', 'main');
  const base = (version, extra = {}) => {
    put(src, 'VERSION', `${version}\n`);
    for (const [path, text] of Object.entries(stubs)) put(src, path, text, path.endsWith('.sh') ? 0o755 : 0o644);
    for (const path of ['scripts/operator-lock.sh', 'scripts/pg-major.sh', 'scripts/db-image.sh', 'scripts/ci-previous-tag.sh', 'scripts/alert-webhook.mjs', 'scripts/is-main.mjs', 'scripts/upgrade-record.mjs', 'scripts/upgrade-lib.sh']) {
      mkdirSync(dirname(join(src, path)), { recursive: true });
      copyFileSync(join(root, path), join(src, path));
    }
    put(src, 'docker/postgres/Dockerfile', extra.dockerfile ?? dockerfile(18));
    put(src, 'CHANGELOG.md', extra.changelog);
    for (const name of extra.migrations ?? ['00000000000000_baseline.sql']) put(src, `migrations/${name}`, `-- ${name}\n`);
    // Files of a release that has a preflight: its own text, and real files of this repository (the preflight and the library it sources).
    for (const [path, text] of Object.entries(extra.files ?? {})) put(src, path, text);
    for (const path of extra.copy ?? []) { mkdirSync(dirname(join(src, path)), { recursive: true }); copyFileSync(join(root, path), join(src, path)); }
    if (extra.upgrade) {
      // Each release's upgrade.sh differs from the one before, so the running script's file is replaced by the checkout.
      copyFileSync(join(root, 'upgrade.sh'), join(src, 'upgrade.sh'));
      appendFileSync(join(src, 'upgrade.sh'), `\n# ${version}\n`);
    }
    git(src, 'add', '-A');
    git(src, 'commit', '-q', '-m', version);
  };
  base('v0.0.1', { changelog: changelog('') });
  git(src, 'tag', 'v0.0.1');
  base('v0.1.0', { upgrade: true, changelog: changelog(S010) });
  git(src, 'tag', '-a', '-m', 'release 0.1.0', 'v0.1.0');
  // A backport on its own line: its CHANGELOG section lives on this branch, not on main.
  git(src, 'checkout', '-q', '-b', 'backport');
  base('v0.0.9', { upgrade: true, changelog: changelog(S009 + S010) });
  git(src, 'tag', 'v0.0.9');
  git(src, 'checkout', '-q', 'main');
  base('v0.1.1', { upgrade: true, changelog: changelog(S011 + S010) });
  git(src, 'tag', 'v0.1.1');                       // a lightweight tag
  base('v0.2.0', { upgrade: true, changelog: changelog(S020 + S011 + S010 + S005), migrations: ['00000000000000_baseline.sql', '00000000000001_more.sql'] });
  git(src, 'tag', '-a', '-m', 'release 0.2.0', 'v0.2.0');
  git(src, 'branch', 'squash');
  // A release on a new PostgreSQL major.
  base('v0.3.0', { upgrade: true, changelog: changelog(S020 + S011 + S010), dockerfile: dockerfile(19), migrations: ['00000000000000_baseline.sql', '00000000000001_more.sql'] });
  git(src, 'tag', '-a', '-m', 'release 0.3.0', 'v0.3.0');
  // A release whose migrations replaced the old ones by a new baseline.
  git(src, 'checkout', '-q', 'squash');
  git(src, 'rm', '-q', '-r', 'migrations');
  base('v0.4.0', { upgrade: true, changelog: changelog(S020 + S011 + S010), migrations: ['00000000000100_new_baseline.sql'] });
  git(src, 'tag', '-a', '-m', 'release 0.4.0', 'v0.4.0');
  // Releases that carry scripts/upgrade-preflight.sh, each on a branch of its own from v0.2.0 (the installed checkout's tags stay as they were):
  //   v0.2.11 a preflight that refuses; v0.2.12 the real preflight with no floor, a stand-in doctor.mjs and a CHANGELOG section with a "before" action
  //   v0.2.13 the same with the floor at v0.2.0; v0.2.14 a preflight that names a file the release does not contain; v0.2.15 one that names a path
  //   outside its tree; v0.2.16 the real preflight and a CHANGELOG section with no operator actions.
  const S0212 = '## v0.2.12 (2026-04-01)\n\n### Operator actions\n\n1. Before the upgrade, do this: BEFORE-ACTION-TWO-TWO.\n\n### Changed\n\n- HIDDEN-CHANGE-TWO-TWO.\n\n';
  const realPreflight = (floor, sections = S0212) => ({ upgrade: true, changelog: changelog(sections + S020 + S011 + S010), migrations: ['00000000000000_baseline.sql', '00000000000001_more.sql'],
    copy: ['scripts/upgrade-preflight.sh', 'scripts/upgrade-lib.sh', 'scripts/upgrade-rehearse.sh', 'scripts/migration-plan.mjs'],
    // The real preflight's `# needs:` line also names docker/ (the rehearsal reads the database image from it); these facilities have no verified backup, so nothing is rehearsed.
    files: { 'docker/.keep': '', 'scripts/upgrade-floor.txt': `# fixture\n${floor}`, 'scripts/doctor.mjs': `import { appendFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
appendFileSync(process.env.FAKE_LOG + '.pre', 'doctor ' + process.argv.slice(2).join(' ') + ' from=' + dirname(fileURLToPath(import.meta.url)) + '\\n');
if (process.env.FAKE_DOCTOR_FAIL) { console.error('Doctor: this host is too old (fake).'); process.exit(1); }
console.log('Host prerequisites and state filesystem preflight passed.');
` } });
  git(src, 'checkout', '-q', '-b', 'pf-refuse', 'v0.2.0');
  base('v0.2.11', { upgrade: true, changelog: changelog(S020 + S011 + S010), migrations: ['00000000000000_baseline.sql', '00000000000001_more.sql'],
    files: { 'scripts/upgrade-preflight.sh': '#!/usr/bin/env bash\n# needs:\necho "PREFLIGHT-SAYS-NO: fixture refusal" >&2\nexit 1\n' } });
  git(src, 'tag', 'v0.2.11');
  git(src, 'checkout', '-q', '-b', 'pf-real', 'v0.2.0');
  base('v0.2.12', realPreflight('from_floor=\nstepping_stone=\n'));
  git(src, 'tag', 'v0.2.12');
  git(src, 'checkout', '-q', '-b', 'pf-floor', 'v0.2.0');
  base('v0.2.13', realPreflight('from_floor=v0.2.0\nstepping_stone=v0.2.0\n'));
  git(src, 'tag', 'v0.2.13');
  git(src, 'checkout', '-q', '-b', 'pf-needs', 'v0.2.0');
  base('v0.2.14', { upgrade: true, changelog: changelog(S020 + S011 + S010), migrations: ['00000000000000_baseline.sql', '00000000000001_more.sql'],
    files: { 'scripts/upgrade-preflight.sh': '#!/usr/bin/env bash\n# needs: scripts/not-in-this-release.txt\nexit 0\n' } });
  git(src, 'tag', 'v0.2.14');
  git(src, 'checkout', '-q', '-b', 'pf-quiet', 'v0.2.0');
  base('v0.2.16', realPreflight('from_floor=\nstepping_stone=\n', S0216));
  git(src, 'tag', 'v0.2.16');
  git(src, 'checkout', '-q', '-b', 'pf-climb', 'v0.2.0');
  base('v0.2.15', { upgrade: true, changelog: changelog(S020 + S011 + S010), migrations: ['00000000000000_baseline.sql', '00000000000001_more.sql'],
    files: { 'scripts/upgrade-preflight.sh': '#!/usr/bin/env bash\n# needs: scripts ../outside-the-tree.txt\nexit 0\n' } });
  git(src, 'tag', 'v0.2.15');
  git(src, 'checkout', '-q', 'main');
  git(scratch, 'init', '-q', '--bare', '-b', 'main', origin);
  git(src, 'push', '-q', origin, '--all');
  git(src, 'push', '-q', origin, '--tags');
  git(scratch, 'clone', '-q', origin, install);
  git(install, 'checkout', '-q', '--detach', at);
  for (const path of [state, join(state, 'config'), join(state, 'public'), join(state, 'backups')]) mkdirSync(path, { recursive: true, mode: 0o700 });
  const log = join(scratch, 'fake.log');
  writeFileSync(log, '');
  const env = (extra = {}) => ({ ...process.env, ...gitEnv, WAREHOUSE_STATE_DIR: state, FAKE_LOG: log, FAKE_LEDGER: '00000000000000_baseline.sql\n', FAKE_ADMIN: '919888888871|Fictional Administrator', ...extra });
  // `input` is what standard input holds (the child sees a pipe, never a terminal; none: it is empty and closed).
  const run = (args, extra = {}, input = undefined) => {
    writeFileSync(log, '');
    const r = spawnSync('bash', [join(install, 'upgrade.sh'), ...args], { encoding: 'utf8', cwd: scratch, env: env(extra), input });
    return { ...r, log: readFileSync(log, 'utf8').split('\n').filter(Boolean), head: git(install, 'rev-parse', 'HEAD') };
  };
  const upgradesLog = () => (existsSync(join(state, 'config/upgrades.log')) ? readFileSync(join(state, 'config/upgrades.log'), 'utf8') : '');
  const recordPath = join(state, 'config/upgrade-in-progress');
  return { scratch, src, origin, install, state, log, run, env, upgradesLog, recordPath, record: () => readUpgradeRecord(state), tag: name => git(install, 'rev-parse', `${name}^{commit}`), cleanup: () => rmSync(scratch, { recursive: true, force: true }) };
}

// A refusal helper for one world: the operator commands did not run, the checkout did not move, nothing was logged or recorded.
function refusing(w) {
  const before = git(w.install, 'rev-parse', 'HEAD');
  return (args, pattern, env) => {
    const r = w.run(args, env);
    assert.notEqual(r.status, 0, `${args.join(' ')} must be refused`);
    assert.match(r.stderr, pattern, `${args.join(' ')}: ${r.stderr}`);
    assert.deepEqual(r.log, [], `${args.join(' ')}: no operator command ran`);
    assert.equal(r.head, before, `${args.join(' ')}: the checkout did not move`);
    assert.equal(w.upgradesLog(), '', `${args.join(' ')}: nothing logged`);
    assert.equal(existsSync(w.recordPath), false, `${args.join(' ')}: nothing recorded`);
  };
}

test('refusals change nothing: no backup, no checkout, no log line, no record', () => {
  const w = world();
  try {
    const before = w.tag('v0.1.0');
    const refused = refusing(w);
    refused([], /Give a release tag/);
    refused(['main'], /not a release tag/);
    refused([before], /not a release tag/);
    refused(['v0.2.0', 'v0.1.1'], /Give one release tag/);
    refused(['v0.2.0', '--ref', 'main'], /not both/);
    refused(['v9.9.9'], /origin has no tag v9\.9\.9/);
    refused(['v0.2.0', '--', '--state-dir', '/x'], /set by upgrade\.sh/);
    refused(['v0.2.0', '--admin-phone', '123'], /go together/);
    // A tag made only in this checkout is not a release.
    git(w.install, 'tag', 'v0.2.5', 'v0.2.0');
    refused(['v0.2.5'], /not on origin/);
    // The release has no upgrade.sh.
    refused(['v0.0.1'], /does not contain upgrade\.sh/);
    // PostgreSQL major change: the separate procedure.
    refused(['v0.3.0'], /PostgreSQL 19 and this checkout runs PostgreSQL 18[\s\S]*Major PostgreSQL upgrade/);
    // A new baseline: the ledger names migrations the release does not contain.
    refused(['v0.4.0'], /recorded migrations that v0\.4\.0 does not contain[^]*00000000000000_baseline\.sql[^]*Baseline reload/);
    // The ledger holds a migration newer than the release (a downgrade).
    refused(['v0.1.1'], /recorded migrations that v0\.1\.1 does not contain[^]*00000000000001_more\.sql/, { FAKE_LEDGER: '00000000000000_baseline.sql\n00000000000001_more.sql\n' });
    // No database: the backup could not run either.
    refused(['v0.2.0'], /database is not answering[^]*could not connect/, { FAKE_FAIL: 'db' });
    refused(['v0.2.0'], /could not read the administrator/, { FAKE_ADMIN: '' });
    // The data directory is another PostgreSQL major than the checkout says (moved by hand without setup).
    refused(['v0.2.0'], /database server runs PostgreSQL 17 but the checkout[^]*Major PostgreSQL upgrade/, { FAKE_SERVER_NUM: '170005' });
    // --admin-phone of someone who is not the facility's administrator: setup would stop after the checkout.
    refused(['--admin-phone', '919000000001', '--admin-name', 'Someone Else', 'v0.2.0'], /another phone number than --admin-phone/, { FAKE_ADMIN_STATE: 'different' });
    // A modified tracked file.
    writeFileSync(join(w.install, 'VERSION'), 'edited by hand\n');
    refused(['v0.2.0'], /uncommitted changes[^]*M VERSION|M VERSION[^]*uncommitted changes/);
    git(w.install, 'checkout', '--', 'VERSION');
    // An untracked file where the release has a file of its own: the checkout would stop half way, after the backup.
    mkdirSync(join(w.install, 'migrations'), { recursive: true });
    writeFileSync(join(w.install, 'migrations/00000000000001_more.sql'), '-- mine\n');
    refused(['v0.2.0'], /not track[^]*migrations\/00000000000001_more\.sql[^]*stop half way/);
    rmSync(join(w.install, 'migrations/00000000000001_more.sql'));
    // A Slack webhook file that setup would not accept as one: it would ask (or, without a terminal, stop) after the checkout.
    writeFileSync(join(w.state, 'config/slack-webhook-url'), 'not a webhook url\n', { mode: 0o600 });
    refused(['v0.2.0'], /does not hold a Slack incoming-webhook URL[^]*alert-webhook-file/);
    rmSync(join(w.state, 'config/slack-webhook-url'));
    // Another operator command holds the lock.
    const holder = spawn('flock', [join(w.state, 'config/operator.lock'), 'sleep', '30'], { stdio: 'ignore', detached: true });
    try {
      for (let i = 0; i < 100 && spawnSync('flock', ['-n', join(w.state, 'config/operator.lock'), 'true']).status === 0; i += 1) pause(50);
      refused(['v0.2.0'], /Another operator command/);
    } finally { try { process.kill(-holder.pid, 'SIGKILL'); } catch { /* gone */ } }
    // Not a git checkout is not tested here (the fixture is one); an unset state is:
    const bare = spawnSync('bash', [join(w.install, 'upgrade.sh'), 'v0.2.0'], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: '' } });
    assert.notEqual(bare.status, 0);
    assert.match(bare.stderr, /WAREHOUSE_STATE_DIR/);
  } finally { w.cleanup(); }
});

test('upgrade.sh only moves forward: a release the checkout contains, or a lower version number, is refused', () => {
  const w = world({ at: 'v0.2.0' });
  try {
    const refused = refusing(w);
    // v0.1.1 is an ancestor of this checkout.
    refused(['v0.1.1'], /already past v0\.1\.1: it contains it[^]*wait for the next release/);
    // v0.0.9 is on another line (a backport branch): not an ancestor, but a lower version than the release this checkout sits on.
    refused(['v0.0.9'], /at the release v0\.2\.0, which is newer than v0\.0\.9[^]*wait for the next release/);
    // The same release again is not a move backward (it repeats setup).
    const same = w.run(['--dry-run', 'v0.2.0']);
    assert.equal(same.status, 0, same.stderr);
  } finally { w.cleanup(); }
});

test('--dry-run runs the checks, prints the plan and changes nothing', () => {
  const w = world();
  try {
    const before = w.tag('v0.1.0');
    const r = w.run(['--dry-run', 'v0.2.0']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /Plan: v0\.1\.0 -> v0\.2\.0 \(PostgreSQL 18 stays\)/);
    assert.match(r.stdout, /1\. backup, then verify the backup/);
    assert.match(r.stdout, /git checkout --detach/);
    assert.match(r.stdout, /--admin-phone 91\*{6}8871 /, 'the number is masked');
    assert.doesNotMatch(r.stdout + r.stderr, /919888888871/);
    assert.match(r.stdout, /--alert-webhook-file off/, 'no webhook stored: off is passed again');
    assert.match(r.stdout, /also recreates the functions container and ends with node scripts\/doctor\.mjs --local/);
    assert.match(r.stdout, /remove [^\n]*config\/upgrade-in-progress/);
    assert.match(r.stdout, /Dry run: nothing was changed/);
    assert.deepEqual(r.log, []);
    assert.equal(r.head, before);
    assert.equal(w.upgradesLog(), '');
    assert.equal(existsSync(w.recordPath), false);
    // The same checks refuse in a dry run.
    const refused = w.run(['--dry-run', 'v0.3.0']);
    assert.notEqual(refused.status, 0);
    assert.match(refused.stderr, /Major PostgreSQL upgrade/);
  } finally { w.cleanup(); }
});

test('the upgrade writes its record before the first change, runs every step in order under the lock, and logs it', () => {
  const w = world();
  try {
    const from = w.tag('v0.1.0');
    // A compose warning on stderr is not a migration name.
    const r = w.run(['v0.2.0'], { FAKE_NOISE: '1' });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.equal(r.head, w.tag('v0.2.0'), 'the checkout is on the tag');
    assert.doesNotMatch(r.stderr, /Slack webhook:|Usage: alert-webhook/, 'the webhook probe imports the module quietly');
    const [backup, verify, setup, ...rest] = r.log;
    assert.deepEqual(rest, [], 'after setup (which recreates functions and runs the doctor) only the changelog print is left');
    const dir = `${w.state}/backups/warehouse-20260101T000000Z`;
    assert.equal(backup, 'backup lock=held version=v0.1.0 record=[no|Backup]', 'backup runs on the OLD release, under the lock, with the record already written');
    assert.equal(verify, `verify-restore ${dir} lock=held version=v0.1.0 record=[no|Verify the backup restores]`, 'verify-restore gets the directory the backup reported, on the old release');
    assert.equal(setup, `setup --operator --state-dir ${w.state} --admin-phone 919888888871 --admin-name Fictional Administrator --alert-webhook-file off | lock=held version=v0.2.0 running=1 record=[yes|Setup (the same inputs as the installation)]`,
      'setup is the NEW release\'s, with the administrator from the database, under the same lock, after the backup was proved');
    // What the release asks of the operator: the new sections' operator actions; not the old release, not Unreleased.
    assert.match(r.stdout, /== v0\.2\.0 \(2026-03-01\)[^]*ACTION-TWO/);
    assert.match(r.stdout, /Also in this release: Changed/);
    assert.doesNotMatch(r.stdout, /HIDDEN-CHANGE/);
    assert.match(r.stdout, /== v0\.1\.1 \(2026-02-01\)[^]*PLAIN-SECTION-LINE/, 'a section without subsections is printed whole');
    assert.doesNotMatch(r.stdout, /UNRELEASED-ACTION|The first release/);
    assert.match(r.stdout, new RegExp(`Upgraded v0\\.1\\.0 -> v0\\.2\\.0\\. The backup taken before the upgrade: ${dir}`));
    // Success leaves no record, and the log line holds the old commit and the backup.
    assert.equal(existsSync(w.recordPath), false);
    assert.match(w.upgradesLog(), new RegExp(`^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\dZ v0\\.1\\.0 -> v0\\.2\\.0 \\(from ${from.slice(0, 12)}, backup ${dir}\\) ok\\n$`));
    assert.equal(statModeOf(join(w.state, 'config/upgrades.log')) & 0o077, 0, 'the log is private');
    assert.notEqual(from, r.head);
    // Repeating it at the release: no checkout, the rest runs again (with a fresh backup: no upgrade was interrupted).
    const again = w.run(['v0.2.0']);
    assert.equal(again.status, 0, again.stderr);
    assert.match(again.stdout, /already at v0\.2\.0/);
    assert.equal(again.log.length, 3);
    assert.match(w.upgradesLog().trim().split('\n').at(-1), /v0\.2\.0 -> v0\.2\.0 \(from [0-9a-f]{12}, backup [^)]*\) ok$/);
  } finally { w.cleanup(); }
});

test('a stored Slack webhook is left to setup; options after -- go to setup and replace the defaults; --admin-* are used as given', () => {
  const w = world();
  try {
    writeFileSync(join(w.state, 'config/slack-webhook-url'), 'https://hooks.slack.com/services/T0000000/B0000000/fictionalfictional\n', { mode: 0o600 });
    const r = w.run(['--admin-phone', '919000000001', '--admin-name', 'Given Name', 'v0.2.0', '--', '--gateway-port', '18001', '--letterhead-file', 'off']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.log[2], new RegExp(`^setup --operator --state-dir ${w.state} --admin-phone 919000000001 --admin-name Given Name --gateway-port 18001 --letterhead-file off \\| lock=held version=v0\\.2\\.0`));
    // Nothing is asked of the database for the administrator, and no webhook option appears.
    assert.doesNotMatch(r.log[2], /alert-webhook/);
    const own = w.run(['v0.2.0'], {});
    rmSync(join(w.state, 'config/slack-webhook-url'));
    const given = w.run(['v0.2.0', '--', '--alert-webhook-file', '/secure/slack.txt']);
    assert.equal(given.status, 0, given.stderr);
    assert.match(given.log[2], /--alert-webhook-file \/secure\/slack\.txt \|/);
    assert.equal((given.log[2].match(/--alert-webhook-file/g) ?? []).length, 1);
    // A malformed file does not stop a run that names the webhook itself.
    writeFileSync(join(w.state, 'config/slack-webhook-url'), 'garbage\n', { mode: 0o600 });
    const off = w.run(['v0.2.0', '--', '--alert-webhook-file', 'off']);
    assert.equal(off.status, 0, off.stderr);
    assert.equal(own.status, 0, own.stderr);
  } finally { w.cleanup(); }
});

test('a failing step stops the rest, is logged, and says how to go back', () => {
  for (const [fail, last, stoppedAt, moved] of [
    ['backup', 'backup', /Backup/, false],
    ['verify', 'verify-restore', /Verify the backup restores/, false],
    ['setup', 'setup', /Setup/, true],
  ]) {
    const w = world();
    try {
      const from = w.tag('v0.1.0');
      const r = w.run(['v0.2.0'], { FAKE_FAIL: fail });
      assert.notEqual(r.status, 0, fail);
      assert.equal(r.log.at(-1).split(' ')[0], last, `${fail}: nothing after the failed step`);
      assert.match(r.stderr, new RegExp(`The upgrade stopped at: ${stoppedAt.source}`), fail);
      assert.match(w.upgradesLog(), new RegExp(`v0\\.1\\.0 -> v0\\.2\\.0 \\(from ${from.slice(0, 12)}[^)]*\\) failed at: ${stoppedAt.source}`), fail);
      const dir = `${w.state}/backups/warehouse-20260101T000000Z`;
      if (moved) {
        assert.equal(r.head, w.tag('v0.2.0'));
        assert.match(r.stderr, new RegExp(`This checkout is now at v0\\.2\\.0; it was at v0\\.1\\.0 \\(${from}\\)`));
        // The record stays: the old commit, the target and the verified backup.
        const record = w.record();
        assert.equal(record.verified, true);
        assert.equal(record.fromSha, from);
        assert.equal(record.toSha, w.tag('v0.2.0'));
        assert.equal(record.backup, dir);
        assert.match(record.step, /^Setup/);
        assert.equal(statModeOf(w.recordPath) & 0o077, 0, 'the record is private');
        // The way forward and the complete way back, in this order.
        assert.match(r.stderr, /Continue: bash upgrade\.sh v0\.2\.0 /);
        const order = [`(umask 022; git checkout --detach ${from})`, 'bash stop.sh', `npm run db:restore -- --yes --restore-config '${dir}'`, `bash setup.sh --operator --state-dir '${w.state}' --admin-phone 91XXXXXXXXXX --admin-name NAME --alert-webhook-file off`,
          'bash scripts/compose.sh up -d --force-recreate --no-deps --wait --wait-timeout 180 functions', 'node scripts/doctor.mjs --local', `rm -f '${w.state}/config/upgrade-in-progress'`];
        let at = -1;
        for (const line of order) {
          const found = r.stderr.indexOf(line, at + 1);
          assert.ok(found > at, `the way back names, in order: ${line}\n${r.stderr}`);
          at = found;
        }
      } else {
        assert.equal(r.head, from, `${fail}: the checkout did not move`);
        assert.match(r.stderr, /checkout was not changed/);
        assert.equal(existsSync(w.recordPath), false, `${fail}: nothing changed, so nothing is recorded as interrupted`);
      }
      if (fail === 'verify') assert.match(r.stderr, new RegExp(`The backup taken first: ${dir}`));
    } finally { w.cleanup(); }
  }
});

test('a failure right after the checkout says the checkout moved (checkout-permissions.sh fails)', () => {
  const w = world();
  try {
    const r = w.run(['v0.2.0'], { FAKE_FAIL: 'perms' });
    assert.notEqual(r.status, 0);
    assert.equal(r.head, w.tag('v0.2.0'), 'git checkout had already moved HEAD');
    assert.deepEqual(r.log.map(line => line.split(' ')[0]), ['backup', 'verify-restore']);
    assert.match(r.stderr, /The upgrade stopped at: Checkout: v0\.2\.0/);
    assert.match(r.stderr, /This checkout is now at v0\.2\.0; it was at v0\.1\.0/);
    assert.doesNotMatch(r.stderr, /checkout was not changed/);
    assert.equal(w.record().verified, true);
  } finally { w.cleanup(); }
});

test('a rerun after a failure reuses the verified backup and the old commit, even with the database down', () => {
  const w = world();
  try {
    const from = w.tag('v0.1.0');
    const dir = `${w.state}/backups/warehouse-20260101T000000Z`;
    const first = w.run(['v0.2.0', '--', '--gateway-port', '18001'], { FAKE_FAIL: 'setup' });
    assert.notEqual(first.status, 0);
    assert.deepEqual(first.log.map(line => line.split(' ')[0]), ['backup', 'verify-restore', 'setup']);
    // The record keeps the command that was typed: doctor and start.sh tell the operator to run it again.
    assert.match(w.record().command, /^v0\.2\.0 -- --gateway-port 18001$/);

    // A second failure: no new backup of the half-upgraded database; the way back still names the FIRST run's commit and backup.
    const second = w.run(['v0.2.0', '--', '--gateway-port', '18001'], { FAKE_FAIL: 'setup' });
    assert.notEqual(second.status, 0);
    assert.deepEqual(second.log.map(line => line.split(' ')[0]), ['setup'], 'no backup, no verify');
    assert.match(second.stdout, /Resuming: {5}the upgrade from v0\.1\.0 to v0\.2\.0 stopped at step "Setup/);
    assert.match(second.stdout, /no new backup: the one taken and verified before this upgrade began is reused/);
    assert.match(second.stderr, new RegExp(`git checkout --detach ${from}\\)`));
    assert.match(second.stderr, new RegExp(`--restore-config '${dir}'`));
    assert.equal(readdirSync(join(w.state, 'backups')).length, 1, 'one backup in all');
    assert.equal(w.record().fromSha, from);
    assert.match(w.upgradesLog().trim().split('\n').at(-1), new RegExp(`\\(from ${from.slice(0, 12)}, backup ${dir}, resumed\\) failed at: Setup`));

    // The third run finds the database down and the administrator unreadable: both come from the record. It finishes the upgrade.
    const third = w.run(['v0.2.0', '--', '--gateway-port', '18001'], { FAKE_FAIL: 'db', FAKE_ADMIN: '' });
    assert.equal(third.status, 0, third.stdout + third.stderr);
    assert.match(third.stderr, /database is not answering[^]*Going on because an interrupted upgrade is recorded/);
    assert.deepEqual(third.log.map(line => line.split(' ')[0]), ['setup']);
    assert.equal(third.log[0], `setup --operator --state-dir ${w.state} --admin-phone 919888888871 --admin-name Fictional Administrator --alert-webhook-file off --gateway-port 18001 | lock=held version=v0.2.0 running=1 record=[yes|Setup (the same inputs as the installation)]`);
    assert.match(third.stdout, /already at the release \(the interrupted upgrade got that far\)/);
    assert.equal(existsSync(w.recordPath), false, 'success deletes the record');
    assert.match(w.upgradesLog().trim().split('\n').at(-1), new RegExp(`v0\\.1\\.0 -> v0\\.2\\.0 \\(from ${from.slice(0, 12)}, backup ${dir}, resumed\\) ok$`));
    assert.match(third.stdout, /== v0\.2\.0 \(2026-03-01\)[^]*ACTION-TWO/, 'the changelog is printed from the recorded old release');
    assert.equal(readdirSync(join(w.state, 'backups')).length, 1, 'still the one backup');
  } finally { w.cleanup(); }
});

test('while an upgrade is recorded as interrupted another target is refused with the way back, and a dry run shows the resume', () => {
  const w = world();
  try {
    const first = w.run(['v0.2.0'], { FAKE_FAIL: 'setup' });
    assert.notEqual(first.status, 0);
    const head = w.tag('v0.2.0');
    const other = w.run(['v0.1.1']);
    assert.notEqual(other.status, 0);
    assert.match(other.stderr, /an upgrade from v0\.1\.0 to v0\.2\.0 stopped at step "Setup[^"]*" \(started [^)]*\) and is not finished, so a move to v0\.1\.1 is refused/);
    assert.match(other.stderr, /git checkout --detach [0-9a-f]{40}\)/, 'the way back follows the refusal');
    assert.deepEqual(other.log, []);
    assert.equal(other.head, head);
    const dry = w.run(['--dry-run', 'v0.2.0']);
    assert.equal(dry.status, 0, dry.stderr);
    assert.match(dry.stdout, /Resuming: {5}the upgrade from v0\.1\.0 to v0\.2\.0/);
    assert.match(dry.stdout, /1\. no new backup/);
    assert.deepEqual(dry.log, []);
    assert.equal(w.record().verified, true, 'a dry run leaves the record alone');
    // A record that is not a record is not ignored.
    writeFileSync(w.recordPath, 'garbage\n');
    const bad = w.run(['v0.2.0']);
    assert.notEqual(bad.status, 0);
    assert.match(bad.stderr, /not a readable upgrade record/);
    assert.deepEqual(bad.log, []);
    // The backup the record names is gone: refuse, and say how to go on without it.
    writeFileSync(w.recordPath, readFileSync(w.recordPath, 'utf8') && `format=1\nstarted=2026-01-01T00:00:00Z\nfrom_sha=${w.tag('v0.1.0')}\nto_sha=${head}\nverified=yes\nbackup=${w.state}/backups/gone\nstep=Setup\ncommand=v0.2.0\n`);
    const gone = w.run(['v0.2.0']);
    assert.notEqual(gone.status, 0);
    assert.match(gone.stderr, /the backup recorded for this upgrade is gone[^]*remove [^\n]*upgrade-in-progress/);
    assert.deepEqual(gone.log, []);
  } finally { w.cleanup(); }
});

test('a run killed without a trap (power cut, lost SSH) leaves the record, doctor and start.sh say so, and the rerun finishes it', () => {
  const w = world();
  try {
    writeFileSync(w.log, '');
    const child = spawn('bash', [join(w.install, 'upgrade.sh'), 'v0.2.0'], { cwd: w.scratch, detached: true, stdio: 'ignore', env: w.env({ FAKE_HANG: 'setup' }) });
    for (let i = 0; i < 200 && !readFileSync(w.log, 'utf8').includes('setup '); i += 1) pause(50);
    assert.match(readFileSync(w.log, 'utf8'), /setup /, 'the run reached setup');
    process.kill(-child.pid, 'SIGKILL');
    for (let i = 0; i < 100 && spawnSync('flock', ['-n', join(w.state, 'config/operator.lock'), 'true']).status !== 0; i += 1) pause(50);
    const record = w.record();
    assert.equal(record.verified, true);
    assert.match(record.step, /^Setup/);
    // The one-paragraph report that doctor, start.sh and the status commands print.
    const message = spawnSync('node', [join(w.install, 'scripts/upgrade-record.mjs'), 'message'], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: w.state } });
    assert.equal(message.status, 0, message.stderr);
    assert.match(message.stdout, /^An upgrade from v0\.1\.0 to v0\.2\.0 was interrupted at step "Setup \(the same inputs as the installation\)"/);
    assert.match(message.stdout, /Continue: bash upgrade\.sh v0\.2\.0 /);
    // Not while upgrade.sh itself is running (doctor runs inside setup).
    const quiet = spawnSync('node', [join(w.install, 'scripts/upgrade-record.mjs'), 'message'], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: w.state, WAREHOUSE_UPGRADE_RUNNING: '1' } });
    assert.equal(quiet.stdout, '');
    // The way back, on demand, for an operator whose scrollback is gone.
    const back = spawnSync('node', [join(w.install, 'scripts/upgrade-record.mjs'), 'rollback'], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: w.state } });
    assert.match(back.stdout, /npm run db:restore -- --yes --restore-config /);
    assert.match(back.stdout, new RegExp(`git checkout --detach ${w.tag('v0.1.0')}`));
    const finished = w.run(['v0.2.0']);
    assert.equal(finished.status, 0, finished.stderr);
    assert.deepEqual(finished.log.map(line => line.split(' ')[0]), ['setup']);
    assert.equal(existsSync(w.recordPath), false);
    assert.equal(spawnSync('node', [join(w.install, 'scripts/upgrade-record.mjs'), 'message'], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: w.state } }).stdout, '');
  } finally { w.cleanup(); }
});

test('the changelog print keeps the releases in between when the old release has no section in the new CHANGELOG (a backport tag)', () => {
  const w = world({ at: 'v0.0.9' });
  try {
    const r = w.run(['v0.2.0']);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    // v0.0.9's section is on its own branch; every section down to the first one that is not newer than it is printed.
    assert.match(r.stdout, /== v0\.2\.0 \(2026-03-01\)[^]*ACTION-TWO/);
    assert.match(r.stdout, /== v0\.1\.1 \(2026-02-01\)[^]*PLAIN-SECTION-LINE/);
    assert.match(r.stdout, /== v0\.1\.0 \(2026-01-01\)[^]*The first release/);
    assert.doesNotMatch(r.stdout, /UNRELEASED-ACTION|Git has it/);
    // v0.0.5 is older than the backport's v0.0.9 (which has no section here): the print stops before it, by version order. A print that went on to
    // "Older history" instead would show it.
    assert.doesNotMatch(r.stdout, /OLDER-THAN-BACKPORT-LINE|v0\.0\.5/);
  } finally { w.cleanup(); }
});

test('--ref opts out of the tag rule with a warning; a branch of origin works, and origin\'s branch wins over a stale local one', () => {
  const w = world();
  try {
    const sha = w.tag('v0.2.0');
    const r = w.run(['--ref', sha]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stderr, /Warning: --ref [0-9a-f]{40} is not a release tag\. Only tagged releases are supported/);
    assert.equal(r.head, sha);
    assert.match(w.upgradesLog(), /v0\.1\.0 -> [0-9a-f]{7} \(--ref [0-9a-f]{40}\) \(from [0-9a-f]{12}, backup [^)]*\) ok/);
    // The release has no section named by a tag here: Unreleased is what a branch can hold.
    assert.match(r.stdout, /== Unreleased[^]*UNRELEASED-ACTION/);
    const nope = w.run(['--ref', 'no-such-branch']);
    assert.notEqual(nope.status, 0);
    assert.match(nope.stderr, /neither a commit nor a branch/);
    // origin's branch moved on after this checkout made its own branch of that name: --ref dev is origin's dev, not the stale local one.
    git(w.install, 'branch', 'dev', 'v0.2.0');
    git(w.src, 'checkout', '-q', '-b', 'dev', 'v0.2.0');
    put(w.src, 'VERSION', 'v0.2.1-dev\n');
    git(w.src, 'commit', '-qam', 'dev');
    git(w.src, 'push', '-q', w.origin, 'dev');
    const newer = git(w.src, 'rev-parse', 'HEAD');
    git(w.src, 'checkout', '-q', 'main');
    const branch = w.run(['--ref', 'dev']);
    assert.equal(branch.status, 0, branch.stdout + branch.stderr);
    assert.equal(branch.head, newer);
    // Without a reachable origin a commit that is already here still works (CI, offline), a tag does not.
    git(w.install, 'remote', 'set-url', 'origin', join(w.scratch, 'gone.git'));
    const offline = w.run(['--ref', newer]);
    assert.equal(offline.status, 0, offline.stdout + offline.stderr);
    assert.match(offline.stderr, /could not fetch from origin; going on with the local/);
    const noTag = w.run(['v0.2.0']);
    assert.notEqual(noTag.status, 0);
    assert.match(noTag.stderr, /could not fetch from origin/);
  } finally { w.cleanup(); }
});

test('a tag moved on origin is not followed', () => {
  const w = world();
  try {
    const first = w.run(['--dry-run', 'v0.1.1']);
    assert.equal(first.status, 0, first.stderr);
    git(w.origin, 'tag', '-f', 'v0.1.1', w.tag('v0.2.0'));
    const moved = w.run(['--dry-run', 'v0.1.1']);
    assert.notEqual(moved.status, 0);
    assert.match(moved.stderr, /could not fetch from origin[^]*would clobber|could not fetch from origin[^]*tag was moved|the local tag v0\.1\.1 points to/);
    assert.equal(moved.log.length, 0);
  } finally { w.cleanup(); }
});

test('setup.sh accepts the lock upgrade.sh holds and recreates the functions container; pg-major.sh reads the pin of this tree and of a ref', () => {
  const setup = readFileSync(join(root, 'setup.sh'), 'utf8');
  assert.doesNotMatch(setup, /^\s*operator_lock "\$STATE"/m, 'setup.sh never takes the lock afresh: upgrade.sh already holds it');
  assert.equal((setup.match(/operator_lock_or_inherited "\$STATE"/g) ?? []).length, 2);
  // The functions container is recreated by setup, after the full start and before the last doctor: the release being moved to decides
  // how it is moved into, so upgrade.sh (the old release's script, still running from memory) no longer does it.
  const lines = setup.split('\n');
  const recreate = lines.indexOf('bash "$ROOT/scripts/compose.sh" up -d --force-recreate --no-deps --wait --wait-timeout 180 functions');
  // (The full start leaves the LAN fallback out, so that a fault of it never stops a setup or an upgrade; lan.sh start brings it up next, as a warning.)
  const fullStart = lines.indexOf('WAREHOUSE_COMPOSE_WITHOUT_LAN=1 bash "$ROOT/scripts/compose.sh" up -d --remove-orphans --wait --wait-timeout 180');
  const doctor = lines.indexOf('node "$ROOT/scripts/doctor.mjs" --local');
  assert.ok(fullStart > 0 && recreate > fullStart && doctor > recreate, 'full start, then the functions recreate, then the local doctor');
  assert.match(setup, /bind-mounted into the functions container and the edge\n# runtime keeps the modules it has loaded/);
  const upgrade = readFileSync(join(root, 'upgrade.sh'), 'utf8');
  assert.doesNotMatch(upgrade, /force-recreate/, 'upgrade.sh leaves the recreate to the setup.sh of the release it moves to');
  assert.doesNotMatch(upgrade, /doctor\.mjs" --local/, 'setup.sh ends with the local doctor');
  const here = spawnSync('bash', [join(root, 'scripts/pg-major.sh')], { encoding: 'utf8' });
  assert.equal(here.status, 0, here.stderr);
  const pinned = readFileSync(join(root, 'docker/postgres/Dockerfile'), 'utf8').match(/^FROM postgres:(\d+)\./m)[1];
  assert.equal(here.stdout.trim(), pinned);
  const ref = spawnSync('bash', [join(root, 'scripts/pg-major.sh'), 'HEAD'], { encoding: 'utf8', cwd: root });
  assert.equal(ref.status, 0, ref.stderr);
  const none = spawnSync('bash', [join(root, 'scripts/pg-major.sh'), 'v0.5.0'], { encoding: 'utf8', cwd: root });
  if (spawnSync('git', ['-C', root, 'rev-parse', '-q', '--verify', 'v0.5.0^{commit}']).status === 0) {
    assert.notEqual(none.status, 0, 'a release from before scripts/db-image.sh has no readable major');
    assert.match(none.stderr, /Cannot read the PostgreSQL version of v0\.5\.0/);
  }
});

test('upgrade.sh parses the line the real backup.sh prints, and the record format is the one upgrade-record.mjs reads', () => {
  const backup = readFileSync(join(root, 'scripts/backup.sh'), 'utf8');
  assert.match(backup, /^echo "Backup created at \$destination"$/m, 'upgrade.sh reads this line (WS-B and others: change both together)');
  const upgrade = readFileSync(join(root, 'upgrade.sh'), 'utf8');
  assert.ok(upgrade.includes(String.raw`sed -n 's/^Backup created at \(\/.*\)$/\1/p'`));
  const sample = spawnSync('bash', ['-c', String.raw`printf 'noise\nBackup created at /state/backups/warehouse-1\n' | sed -n 's/^Backup created at \(\/.*\)$/\1/p' | tail -n 1`], { encoding: 'utf8' });
  assert.equal(sample.stdout.trim(), '/state/backups/warehouse-1');
  // Every field the reader needs is written by upgrade.sh.
  assert.ok(upgrade.includes("printf 'format=1\\n'"));
  for (const key of ['started', 'from_sha', 'from_label', 'from_tag', 'to_sha', 'to_label', 'command', 'admin_phone', 'admin_name', 'webhook_off', 'verified', 'backup', 'step']) {
    assert.match(upgrade, new RegExp(`printf '${key}=%s\\\\n'`), key);
  }
});

test('doctor, watch status, the timer status and hint, and start.sh report an interrupted upgrade', () => {
  const read = name => readFileSync(join(root, name), 'utf8');
  assert.match(read('scripts/doctor.mjs'), /import \{ interruptedUpgradeWarning \} from '\.\/upgrade-record\.mjs';/);
  assert.match(read('scripts/doctor.mjs'), /const note = \[upgradeWarning, usb, \.\.\.checker\]/);
  assert.match(read('scripts/doctor.mjs'), /health check failed[^\n]*upgradeWarning/);
  assert.match(read('scripts/watch.mjs'), /lines\.push\(`Upgrade: \$\{interruptedUpgrade\}`\)/);
  assert.equal((read('scripts/watch-timer.sh').match(/^\s+upgrade_interrupted "\$state"$/gm) ?? []).length, 2, 'status and hint');
  assert.match(read('start.sh'), /node "\$ROOT\/scripts\/upgrade-record\.mjs" message \|\| true/);
});

test('the CI drill installs the newest release before the change, falls back to the merge base, and skips with a reason when upgrade.sh could not move from either', () => {
  const w = world();
  try {
    const clone = name => {
      const dir = join(w.scratch, name);
      git(w.scratch, 'clone', '-q', w.origin, dir);
      return dir;
    };
    const commit = (dir, path, text) => { put(dir, path, text); git(dir, 'add', '-A'); git(dir, 'commit', '-q', '-m', `edit ${path}`); };
    const pick = (dir, ...args) => {
      const r = spawnSync('bash', [join(dir, 'scripts/ci-previous-tag.sh'), ...args], { encoding: 'utf8', env: { ...process.env, ...gitEnv } });
      assert.equal(r.status, 0, 'it skips; it does not fail: ' + r.stderr);
      return r.stdout;
    };
    const dropTags = dir => { for (const tag of git(dir, 'tag', '--list').split('\n')) git(dir, 'tag', '-d', tag); };
    const v020 = w.tag('v0.2.0');
    // A change on top of v0.2.0 (origin/main is further on, at v0.3.0 on PostgreSQL 19): the merge base is v0.2.0.
    const a = clone('a');
    git(a, 'checkout', '-q', '--detach', 'v0.2.0');
    commit(a, 'notes.txt', 'a change\n');
    assert.equal(pick(a), 'skip=false\nkind=tag\nref=v0.2.0\n');
    // The same change aimed at a release branch whose tip is v0.2.0.
    git(a, 'update-ref', 'refs/remotes/origin/release/0.2', v020);
    assert.equal(pick(a, 'release/0.2'), 'skip=false\nkind=tag\nref=v0.2.0\n');
    // The change itself moves the PostgreSQL major: upgrade.sh would refuse the move from the tag and from the merge base alike.
    commit(a, 'docker/postgres/Dockerfile', dockerfile(19));
    assert.match(pick(a), /^skip=true\nreason=v0\.2\.0 runs PostgreSQL 18 and this commit runs PostgreSQL 19: .*Major PostgreSQL upgrade.*; the merge base with origin\/main \([0-9a-f]+\) runs PostgreSQL 18/);
    // HEAD is the release.
    const b = clone('b');
    git(b, 'checkout', '-q', '--detach', 'v0.2.0');
    assert.equal(pick(b), 'skip=true\nreason=HEAD is the release v0.2.0 itself\n');
    // No release tag at all, a change on top of v0.2.0: the drill starts from the merge base with main.
    const c = clone('c');
    git(c, 'checkout', '-q', '--detach', 'v0.2.0');
    commit(c, 'notes.txt', 'a change\n');
    dropTags(c);
    const fromBase = pick(c);
    assert.match(fromBase, new RegExp(`^skip=false\\nkind=merge-base\\nref=${v020}\\nnote=no release tag can start the drill \\(no release tag \\(v\\*\\) is reachable[^\\n]*so it starts from the merge base with origin/main \\(${v020.slice(0, 7)}\\)`));
    // A push to main: HEAD is the tip of origin/main, so the drill starts from its parent.
    const d0 = clone('d0');
    git(d0, 'checkout', '-q', '--detach', 'v0.2.0');
    commit(d0, 'notes.txt', 'the push\n');
    dropTags(d0);
    git(d0, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
    assert.match(pick(d0), new RegExp(`^skip=false\\nkind=merge-base\\nref=${v020}\\n`));
    // No tag and the commit before is on another PostgreSQL major: nothing to drill.
    const c2 = clone('c2');
    dropTags(c2);
    assert.match(pick(c2), /^skip=true\nreason=no release tag \(v\*\) is reachable[^\n]*; the merge base with origin\/main \([0-9a-f]+\) runs PostgreSQL 18 and this commit runs PostgreSQL 19/);
    // A prerelease tag is used only when there is no stable one; versions sort as numbers (v0.10.0 after v0.9.0).
    const d = clone('d');
    git(d, 'checkout', '-q', '--detach', 'v0.2.0');
    git(d, 'tag', 'v0.2.1-rc.1');
    git(d, 'tag', 'v0.10.0');
    git(d, 'tag', 'v0.9.0');
    commit(d, 'notes.txt', 'again\n');
    git(d, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
    commit(d, 'notes.txt', 'once more\n');
    assert.equal(pick(d), 'skip=false\nkind=tag\nref=v0.10.0\n');
    // A release whose operator-lock.sh has no inherited lock cannot run under the lock upgrade.sh holds; nor can the merge base.
    const e = clone('e');
    git(e, 'checkout', '-q', '--detach', 'v0.2.0');
    commit(e, 'scripts/operator-lock.sh', readFileSync(join(e, 'scripts/operator-lock.sh'), 'utf8').replace('operator_lock_or_inherited()', 'operator_lock_other()'));
    git(e, 'tag', '-a', '-m', 'old lock', 'v0.2.2');
    git(e, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
    commit(e, 'notes.txt', 'after\n');
    assert.match(pick(e), /^skip=true\nreason=v0\.2\.2 predates the inherited operator lock[^\n]*; the merge base with origin\/main \([0-9a-f]+\) predates the inherited operator lock/);
  } finally { w.cleanup(); }
});

// --- the release's own preflight, the floor, the room for the way back, and the images of the old release ------------------------------
const GIB = 1024 ** 3;
const preLog = w => (existsSync(`${w.log}.pre`) ? readFileSync(`${w.log}.pre`, 'utf8').split('\n').filter(Boolean) : []);
const recordText = w => readFileSync(w.recordPath, 'utf8');
// A run with a TMPDIR of its own, to see that nothing is left behind in it.
const withTmp = (w, extra = {}) => {
  const tmp = join(w.scratch, 'tmp');
  mkdirSync(tmp, { recursive: true });
  return { tmp, env: { TMPDIR: tmp, ...extra } };
};
// A verified backup of `bytes` stored files (and a database dump of `dump` bytes), and a `df` that reports `avail` bytes free (PATH shim), for the
// free-space rule.
function roomFor(w, bytes, avail, dump = 0) {
  const name = 'warehouse-20251231T000000Z';
  mkdirSync(join(w.state, 'backups', name), { recursive: true });
  writeFileSync(join(w.state, 'backups', name, 'metadata.txt'), `format=warehouse-backup-v6\nstorage_bytes=${bytes}\n`);
  if (dump) { writeFileSync(join(w.state, 'backups', name, 'database.dump'), ''); truncateSync(join(w.state, 'backups', name, 'database.dump'), dump); }   // sparse: only its size counts
  writeFileSync(join(w.state, 'config/backups-verified.list'), `${name} 1\n`);
  const bin = join(w.scratch, 'bin');
  mkdirSync(bin, { recursive: true });
  writeFileSync(join(bin, 'df'), '#!/bin/sh\nprintf "Avail\\n%s\\n" "$FAKE_DF_AVAIL"\n', { mode: 0o755 });
  // The rehearsal of the target's migrations (a backup with a dump is rehearsed) sends its plan to `docker exec ... psql`: accepted and ignored here.
  writeFileSync(join(bin, 'docker'), '#!/bin/sh\ncat > /dev/null\n', { mode: 0o755 });
  return { PATH: `${bin}:${process.env.PATH}`, FAKE_DF_AVAIL: String(avail) };
}

test('a preflight of the target that refuses stops the upgrade before the backup: nothing changed, no record, no line logged, a dry run refuses too', () => {
  const w = world();
  try {
    const before = w.tag('v0.1.0');
    const { tmp, env } = withTmp(w);
    for (const args of [['v0.2.11'], ['--dry-run', 'v0.2.11']]) {
      const r = w.run(args, env);
      assert.notEqual(r.status, 0, args.join(' '));
      assert.match(r.stderr, /PREFLIGHT-SAYS-NO: fixture refusal/, 'the preflight\'s own message is shown');
      assert.match(r.stderr, /Refusing: the preflight of v0\.2\.11 stopped this upgrade \(exit 1; its message is above\)\. Nothing was changed\./);
      assert.deepEqual(r.log, [], `${args.join(' ')}: no backup, no verify, no setup`);
      assert.equal(r.head, before, 'the checkout did not move');
      assert.equal(existsSync(w.recordPath), false, 'no record: nothing was started');
      assert.equal(w.upgradesLog(), '');
      assert.deepEqual(readdirSync(join(w.state, 'backups')), [], 'no backup was taken');
      assert.deepEqual(preLog(w), [], 'no images were tagged');
      assert.deepEqual(readdirSync(tmp), [], 'the extracted copy of the preflight is removed');
    }
  } finally { w.cleanup(); }
});

test('a release without a preflight says so, goes the old way, and the record says preflight=absent', () => {
  const w = world();
  try {
    const r = w.run(['v0.2.0'], { FAKE_FAIL: 'setup' });
    assert.match(r.stdout, /Preflight: {4}v0\.2\.0 has no scripts\/upgrade-preflight\.sh \(it is from before the release preflight\), so only the checks above were made\./);
    assert.deepEqual(r.log.map(line => line.split(' ')[0]), ['backup', 'verify-restore', 'setup'], 'the old path');
    assert.match(recordText(w), /^preflight=absent$/m);
    assert.match(recordText(w), /^format=1$/m, 'the format only gained fields');
  } finally { w.cleanup(); }
});

test('the target\'s preflight runs from a temporary copy of the target, prints the target\'s own "before" actions first, and the record says preflight=ok', () => {
  const w = world();
  try {
    const { tmp, env } = withTmp(w);
    const r = w.run(['v0.2.12'], { FAKE_FAIL: 'setup', ...env });
    assert.notEqual(r.status, 0);
    // The installed v0.1.0 has no such text: it can only come out of the target's CHANGELOG, read before the backup.
    const marker = r.stdout.indexOf('BEFORE-ACTION-TWO-TWO');
    assert.ok(marker > 0, r.stdout);
    assert.ok(marker < r.stdout.indexOf('==> Backup'), 'printed before the backup starts');
    assert.match(r.stdout, /Preflight of v0\.2\.12 passed\./);
    assert.doesNotMatch(r.stdout, /HIDDEN-CHANGE-TWO-TWO|UNRELEASED-ACTION/);
    const doctor = preLog(w).find(line => line.startsWith('doctor '));
    assert.match(doctor, /^doctor --host-preflight from=/, 'the target\'s doctor was asked for the host minimums');
    assert.ok(doctor.includes(`from=${tmp}/warehouse-preflight.`) && doctor.endsWith('/scripts'), `it ran from a temporary copy: ${doctor}`);
    assert.ok(!doctor.includes(w.install), 'not from the installed checkout');
    assert.deepEqual(readdirSync(tmp), [], 'the copy is removed again');
    assert.match(recordText(w), /^preflight=ok$/m);
    assert.deepEqual(r.log.map(line => line.split(' ')[0]), ['backup', 'verify-restore', 'setup']);
  } finally { w.cleanup(); }
});

test('--dry-run prints the span\'s before-actions from the TARGET\'s CHANGELOG, then the plan, and changes nothing', () => {
  const w = world();
  try {
    const before = w.tag('v0.1.0');
    const r = w.run(['--dry-run', 'v0.2.12']);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const marker = r.stdout.indexOf('BEFORE-ACTION-TWO-TWO');
    assert.ok(marker > 0 && marker < r.stdout.indexOf('Plan: v0.1.0 -> v0.2.12'), r.stdout);
    assert.match(r.stdout, /== v0\.2\.12 \(2026-04-01\)[^]*== v0\.2\.0 \(2026-03-01\)[^]*ACTION-TWO[^]*== v0\.1\.1/, 'the whole span, newest first');
    assert.match(r.stdout, /Preflight of v0\.2\.12 passed \(dry run\)\./);
    assert.match(r.stdout, /2\. tag the running images <project>-<service>:pre-v0\.1\.0 \(the way back uses them\), then git checkout --detach/);
    assert.deepEqual(r.log, []);
    assert.equal(r.head, before);
    assert.equal(existsSync(w.recordPath), false);
    assert.equal(w.upgradesLog(), '');
    assert.deepEqual(readdirSync(join(w.state, 'backups')), []);
    // The same dry run is refused when the target's host check refuses.
    const refused = w.run(['--dry-run', 'v0.2.12'], { FAKE_DOCTOR_FAIL: '1' });
    assert.notEqual(refused.status, 0);
    assert.match(refused.stderr, /Doctor: this host is too old \(fake\)[^]*Refusing: this host does not meet what v0\.2\.12 needs[^]*Nothing was changed\./);
  } finally { w.cleanup(); }
});

test('the floor: an installation older than the target\'s from_floor is refused before the backup and told the stepping stone; one at it passes', () => {
  const w = world();
  try {
    const before = w.tag('v0.1.0');
    const r = w.run(['v0.2.13']);
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /Refusing: v0\.2\.13 accepts an upgrade only from v0\.2\.0 or newer, and this checkout is at v0\.1\.0\. Upgrade to v0\.2\.0 first \(bash upgrade\.sh v0\.2\.0\)[^]*Nothing was changed\./);
    assert.deepEqual(r.log, []);
    assert.equal(r.head, before);
    assert.equal(existsSync(w.recordPath), false);
    assert.deepEqual(readdirSync(join(w.state, 'backups')), []);
  } finally { w.cleanup(); }
  const at = world({ at: 'v0.2.0' });
  try {
    const r = at.run(['--dry-run', 'v0.2.13']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /Preflight of v0\.2\.13 passed/);
  } finally { at.cleanup(); }
});

test('the room for the way back is checked before the backup: below the newest verified backup\'s stored files, its database dump and 1 GiB the upgrade is refused', () => {
  const w = world();
  try {
    const before = w.tag('v0.1.0');
    const short = w.run(['v0.2.12'], roomFor(w, 5 * GIB, 6 * GIB - 1));
    assert.notEqual(short.status, 0);
    assert.match(short.stderr, /Refusing: the way back from this upgrade is an in-place restore[^]*needs at least 6144 MiB free in [^\n]*\/data \(5120 MiB of stored files of warehouse-20251231T000000Z, 0 MiB of its database dump, and 1 GiB to spare\)[^]*and only 6143 MiB are free[^]*Nothing was changed\./);
    assert.deepEqual(short.log, [], 'refused before the backup');
    assert.equal(short.head, before);
    assert.equal(existsSync(w.recordPath), false);
    assert.deepEqual(readdirSync(join(w.state, 'backups')).filter(name => name !== 'warehouse-20251231T000000Z'), [], 'no backup was taken');
    const enough = w.run(['v0.2.12'], roomFor(w, 5 * GIB, 6 * GIB));
    assert.equal(enough.status, 0, enough.stderr);
    assert.match(enough.stdout, /Room for the way back: 6144 MiB free, 6144 MiB needed \(the stored files of warehouse-20251231T000000Z, its database dump and 1 GiB; a minimum, since the photos added since, the new backup's dump and new images come on top\)/);
    // The dump counts too: 6 GiB free was enough for 5 GiB of stored files, it is not for the same files and a 512 MiB dump.
    const withDump = w.run(['v0.2.12'], roomFor(w, 5 * GIB, 6 * GIB, 512 * 1024 * 1024));
    assert.notEqual(withDump.status, 0);
    assert.match(withDump.stderr, /needs at least 6656 MiB free[^]*\(5120 MiB of stored files of warehouse-20251231T000000Z, 512 MiB of its database dump, and 1 GiB to spare\)[^]*only 6144 MiB are free/);
    const exact = w.run(['v0.2.12'], roomFor(w, 5 * GIB, 6 * GIB + 512 * 1024 * 1024, 512 * 1024 * 1024));
    assert.equal(exact.status, 0, 'exactly the three parts is enough');
    // A backup with a dump is restored for the rehearsal of the target's migrations, which the target's preflight runs through upgrade.sh.
    assert.match(exact.stdout, /Rehearsal of the migrations: passed \(\d+ to apply, \d+ already applied\) on a copy of warehouse-20251231T000000Z; applying them took \d+ s\./);
  } finally { w.cleanup(); }
});

test('the running images are tagged after the backup is proved and before the checkout, from the old release; the older tags go once setup has succeeded', () => {
  const w = world();
  try {
    const from = w.tag('v0.1.0');
    const r = w.run(['v0.2.0']);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const [watch, tag, prune, ...rest] = preLog(w);
    assert.deepEqual(rest, []);
    // The verified backup is put on the list of verified backups by the OLD release's checker, between the proof and the tags.
    assert.match(watch, new RegExp(`^watch record-verified ${w.state}/backups/warehouse-20260101T000000Z \\d+$`));
    assert.equal(tag, `pre-images tag v0.1.0 version=v0.1.0 record=[yes|Checkout: v0.2.0] head=${from}`,
      'tagged by the OLD release\'s script, with the backup already verified and the checkout not yet made');
    assert.equal(prune, 'pre-images prune v0.1.0 pre-v0.1.0 version=v0.2.0', 'pruned by the new release\'s script, keeping the set of the release moved away from, named by the tag recorded when it was made');
    assert.equal(existsSync(w.recordPath), false);
    assert.match(r.stdout, /remove [^\n]*upgrade-in-progress[^\n]*pre-\* image tags/);
  } finally { w.cleanup(); }
});

test('the record names the saved images and the way back puts them back before the restore; when none could be saved the way back is the old one', () => {
  const w = world();
  try {
    const r = w.run(['v0.2.0'], { FAKE_FAIL: 'setup' });
    assert.notEqual(r.status, 0);
    assert.match(recordText(w), /^pre_images=pre-v0\.1\.0$/m);
    assert.equal(preLog(w).filter(line => line.startsWith('pre-images prune')).length, 0, 'nothing is pruned when setup failed');
    const order = ['bash stop.sh', "bash scripts/pre-images.sh restore 'v0.1.0'", 'npm run db:restore -- --yes --restore-config', 'bash setup.sh --operator', 'bash scripts/build-images.sh --save',
      'bash scripts/compose.sh up -d --force-recreate --no-deps --wait --wait-timeout 180 functions'];
    let at = -1;
    for (const line of order) {
      const found = r.stderr.indexOf(line, at + 1);
      assert.ok(found > at, `the way back names, in order: ${line}\n${r.stderr}`);
      at = found;
    }
  } finally { w.cleanup(); }
  for (const [mode, pattern] of [['none', null], ['fail', /could not tag the running images as pre-v0\.1\.0 \(message above\)\. The upgrade goes on;[^]*builds its images again/]]) {
    const n = world();
    try {
      const r = n.run(['v0.2.0'], { FAKE_FAIL: 'setup', FAKE_PRE: mode });
      assert.notEqual(r.status, 0);
      assert.deepEqual(r.log.map(line => line.split(' ')[0]), ['backup', 'verify-restore', 'setup'], `${mode}: the upgrade went on to setup`);
      assert.match(recordText(n), /^pre_images=none$/m);
      assert.doesNotMatch(r.stderr, /pre-images\.sh restore/, `${mode}: no restore line in a way back with no saved images`);
      assert.match(r.stderr, /npm run db:restore -- --yes --restore-config/);
      if (pattern) assert.match(r.stderr, pattern);
    } finally { n.cleanup(); }
  }
});

test('a rerun of an interrupted upgrade does not run the preflight or tag again, keeps what the record says, and prunes against the recorded old release', () => {
  const w = world();
  try {
    const first = w.run(['v0.2.12'], { FAKE_FAIL: 'setup' });
    assert.notEqual(first.status, 0);
    assert.equal(preLog(w).filter(line => line.startsWith('doctor ')).length, 1, 'the first run made the preflight');
    rmSync(`${w.log}.pre`);
    const second = w.run(['v0.2.12'], { FAKE_DOCTOR_FAIL: '1' });
    assert.equal(second.status, 0, second.stdout + second.stderr);
    assert.match(second.stdout, /Preflight: {4}not run again: the first run of this upgrade ran the release preflight \(record: preflight=ok\)/);
    assert.deepEqual(preLog(w), ['pre-images prune v0.1.0 pre-v0.1.0 version=v0.2.12'], 'no doctor, no tag, nothing recorded as verified again; the prune keeps the set of the old release from the record');
  } finally { w.cleanup(); }
});

test('a target whose preflight names a file it does not contain is refused before anything changes, and the half-made copy is removed by the EXIT trap', () => {
  const w = world();
  try {
    const { tmp, env } = withTmp(w);
    const r = w.run(['v0.2.14'], env);
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /Refusing: the preflight of v0\.2\.14 names a file that release does not contain \(message above\)\. Nothing was changed\./);
    assert.match(r.stderr, /not-in-this-release\.txt/, 'git says which');
    assert.deepEqual(r.log, []);
    assert.equal(existsSync(w.recordPath), false);
    assert.deepEqual(readdirSync(tmp), [], 'the directory made for the copy was removed: nothing but the trap does that on this path');
  } finally { w.cleanup(); }
});

test('a preflight may name only files inside its release: a path that climbs out of the tree is refused before anything is extracted', () => {
  const w = world();
  try {
    const { tmp, env } = withTmp(w);
    const r = w.run(['v0.2.15'], env);
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /Refusing: the preflight of v0\.2\.15 names a file this script will not read from it \('\.\.\/outside-the-tree\.txt'\)\. Nothing was changed\./);
    assert.deepEqual(r.log, []);
    assert.deepEqual(readdirSync(tmp), [], 'nothing was extracted');
  } finally { w.cleanup(); }
});

test('the CI drill, which adds this change\'s upgrade.sh to a tree that has none of its own, adds the two helpers upgrade.sh sources and calls', () => {
  const ci = readFileSync(join(root, '.github/workflows/ci.yml'), 'utf8');
  const copy = ci.split('\n').find(line => line.includes('cp backend/scripts/pg-major.sh'));
  assert.ok(copy, 'the drill copies the scripts of the change');
  const add = ci.split('\n').find(line => line.includes('add upgrade.sh scripts/pg-major.sh'));
  for (const helper of ['scripts/upgrade-lib.sh', 'scripts/pre-images.sh']) {
    assert.ok(copy.includes(`backend/${helper}`), `${helper} is copied`);
    assert.ok(add.includes(helper), `${helper} is added to the commit`);
    assert.match(readFileSync(join(root, 'upgrade.sh'), 'utf8'), new RegExp(helper.replace(/[.]/g, '\\.')), `upgrade.sh still uses ${helper}`);
  }
});

// A `tty` that says standard input is a terminal (a PATH shim): the preflight asks `tty -s`. Nothing here opens a pseudo-terminal; without the
// shim the child's standard input is a pipe, which is what CI, `ssh host command` and `</dev/null` give it.
function asTerminal(w) {
  const bin = join(w.scratch, 'bin-tty');
  mkdirSync(bin, { recursive: true });
  writeFileSync(join(bin, 'tty'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  return { PATH: `${bin}:${process.env.PATH}` };
}

test('the operator actions are followed by a pause only at a terminal, in a real run, when there are some, and unless --yes: Enter goes on, no answer stops before the backup', () => {
  const w = world({ at: 'v0.2.0' });
  try {
    const before = w.tag('v0.2.0');
    const prompt = 'Press Enter to continue, Ctrl-C to stop';
    // No terminal (pipe, CI, </dev/null): never a pause, and the text says the run goes on.
    const piped = w.run(['v0.2.12'], { FAKE_FAIL: 'setup' });
    assert.notEqual(piped.status, 0, 'setup is made to fail');
    assert.deepEqual(piped.log.map(line => line.split(' ')[0]), ['backup', 'verify-restore', 'setup'], 'it went on to the backup');
    assert.ok(!piped.stdout.includes(prompt), 'no prompt without a terminal');
    assert.match(piped.stdout, /This run goes on after the list without stopping, so an action that says "before" should be done already \(--dry-run prints this list without changing anything\):/);
    assert.ok(piped.stdout.includes('BEFORE-ACTION-TWO-TWO'));
    // A terminal (stand-in) and Enter: the prompt comes after the actions and before the backup, then the run goes on.
    git(w.install, 'checkout', '-q', '--detach', before);
    rmSync(w.recordPath, { force: true });
    const entered = w.run(['v0.2.12'], { FAKE_FAIL: 'setup', ...asTerminal(w) }, '\n');
    assert.deepEqual(entered.log.map(line => line.split(' ')[0]), ['backup', 'verify-restore', 'setup']);
    const text = entered.stdout;
    assert.match(text, /Do every action that says "before" now; nothing has been changed yet:/);
    assert.ok(text.indexOf('BEFORE-ACTION-TWO-TWO') > 0 && text.indexOf('BEFORE-ACTION-TWO-TWO') < text.indexOf(prompt) && text.indexOf(prompt) < text.indexOf('==> Backup'), 'actions, then the pause, then the backup');
    assert.ok(text.includes(`${prompt} (--yes skips this pause): `));
  } finally { w.cleanup(); }
  // A terminal and no answer (the input ended): the upgrade stops before anything changes.
  const stop = world({ at: 'v0.2.0' });
  try {
    const { tmp, env } = withTmp(stop);
    const r = stop.run(['v0.2.12'], { ...asTerminal(stop), ...env });
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /Refusing: no answer was read, so the upgrade did not go on\. Do the actions listed above, then run this command again\. Nothing was changed\./);
    assert.ok(r.stdout.includes('Press Enter to continue, Ctrl-C to stop'));
    assert.deepEqual(r.log, [], 'no backup');
    assert.equal(r.head, stop.tag('v0.2.0'));
    assert.equal(existsSync(stop.recordPath), false);
    assert.deepEqual(readdirSync(join(stop.state, 'backups')), []);
    assert.deepEqual(readdirSync(tmp), [], 'the copy of the preflight is removed');
  } finally { stop.cleanup(); }
  // ASSUME_YES=yes in the operator's environment is not --yes: only the option skips the pause.
  const envYes = world({ at: 'v0.2.0' });
  try {
    const r = envYes.run(['v0.2.12'], { ...asTerminal(envYes), ASSUME_YES: 'yes' });
    assert.notEqual(r.status, 0);
    assert.ok(r.stdout.includes('Press Enter to continue, Ctrl-C to stop'), 'the pause is still made');
    assert.match(r.stderr, /Refusing: no answer was read/);
    assert.deepEqual(r.log, [], 'no backup');
  } finally { envYes.cleanup(); }
  // --yes: no pause, though standard input is a terminal and says nothing. --dry-run: no pause either (nothing would change).
  const skip = world({ at: 'v0.2.0' });
  try {
    const yes = skip.run(['--yes', 'v0.2.12'], { FAKE_FAIL: 'setup', ...asTerminal(skip) });
    assert.deepEqual(yes.log.map(line => line.split(' ')[0]), ['backup', 'verify-restore', 'setup'], yes.stderr);
    assert.ok(!yes.stdout.includes('Press Enter'));
    assert.match(skip.record().command, /^--yes v0\.2\.12$/, 'the command a rerun is told to repeat keeps --yes');
  } finally { skip.cleanup(); }
  const dryWorld = world({ at: 'v0.2.0' });
  try {
    const dry = dryWorld.run(['--dry-run', 'v0.2.12'], asTerminal(dryWorld));
    assert.equal(dry.status, 0, dry.stderr);
    assert.ok(!dry.stdout.includes('Press Enter'));
    assert.match(dry.stdout, /Do every action that says "before" before you run the upgrade for real; this dry run changes nothing:/);
  } finally { dryWorld.cleanup(); }
  // No operator actions in the span: nothing to stop for, whatever the terminal says.
  const quiet = world({ at: 'v0.2.0' });
  try {
    const r = quiet.run(['v0.2.16'], { FAKE_FAIL: 'setup', ...asTerminal(quiet) });
    assert.deepEqual(r.log.map(line => line.split(' ')[0]), ['backup', 'verify-restore', 'setup'], r.stderr);
    assert.ok(r.stdout.includes('NOTHING-TO-DO-LINE') === false && r.stdout.includes('(no operator actions listed)'));
    assert.ok(!r.stdout.includes('Press Enter'));
  } finally { quiet.cleanup(); }
});

test('a rerun after a partial way back (the old commit checked out again) tags no image again and keeps the recorded set, even when tagging would find nothing', () => {
  const w = world();
  try {
    const from = w.tag('v0.1.0');
    const first = w.run(['v0.2.0'], { FAKE_FAIL: 'setup' });
    assert.notEqual(first.status, 0);
    assert.match(recordText(w), /^pre_images=pre-v0\.1\.0$/m);
    // The operator began the printed way back: the old commit is checked out again, and whatever runs may be the new release's images.
    git(w.install, 'checkout', '-q', '--detach', from);
    rmSync(`${w.log}.pre`, { force: true });
    const second = w.run(['v0.2.0'], { FAKE_FAIL: 'setup', FAKE_PRE: 'none' });
    assert.notEqual(second.status, 0);
    assert.equal(second.head, w.tag('v0.2.0'), 'the checkout was made again');
    assert.deepEqual(preLog(w).filter(line => line.startsWith('pre-images')), [], 'nothing was tagged (a tag call here would also have recorded none)');
    assert.match(second.stdout, /Images: {7}not tagged again: the first run of this upgrade did that \(record: pre_images=pre-v0\.1\.0\)/);
    assert.match(second.stdout, /2\. git checkout --detach [0-9a-f]{12} \(no image is tagged again: the first run did that, record pre_images=pre-v0\.1\.0\)/, 'the plan says so too');
    assert.match(recordText(w), /^pre_images=pre-v0\.1\.0$/m, 'the record still names the good set');
    assert.match(second.stderr, /bash scripts\/pre-images\.sh restore 'v0\.1\.0'/, 'and the way back still puts it back');
    // Finished, the prune keeps that recorded set.
    rmSync(`${w.log}.pre`, { force: true });
    const third = w.run(['v0.2.0']);
    assert.equal(third.status, 0, third.stdout + third.stderr);
    assert.deepEqual(preLog(w), ['pre-images prune v0.1.0 pre-v0.1.0 version=v0.2.0']);
  } finally { w.cleanup(); }
});

test('the resume line tells a record from a release without a preflight (preflight=absent) from one written before the preflight existed (no preflight= line)', () => {
  const w = world();
  try {
    const first = w.run(['v0.2.0'], { FAKE_FAIL: 'setup' });
    assert.notEqual(first.status, 0);
    assert.match(recordText(w), /^preflight=absent$/m, 'written by this script: the release had no preflight');
    const absent = w.run(['v0.2.0'], { FAKE_FAIL: 'setup' });
    assert.match(absent.stdout, /Preflight: {4}not run again: v0\.2\.0 had no scripts\/upgrade-preflight\.sh when this upgrade began \(record: preflight=absent\)/);
    assert.doesNotMatch(absent.stdout, /before the release preflight/);
    // A record of an upgrade.sh that knew nothing of either field: not a statement that the release had no preflight.
    writeFileSync(w.recordPath, recordText(w).split('\n').filter(line => !/^(preflight|pre_images)=/.test(line)).join('\n'));
    assert.doesNotMatch(recordText(w), /preflight/);
    const old = w.run(['v0.2.0'], { FAKE_FAIL: 'setup' });
    assert.match(old.stdout, /Preflight: {4}none: this upgrade was begun by an upgrade\.sh from before the release preflight \(the record has no preflight= line\); setup makes the host checks/);
    assert.doesNotMatch(old.stdout, /preflight=absent/);
    assert.match(recordText(w), /^preflight=$/m, 'the record is not turned into a statement it never made');
  } finally { w.cleanup(); }
});

test('the verified backup is put on the list of verified backups after its proof; when the checker cannot, that is a warning and the upgrade goes on', () => {
  const w = world();
  try {
    const dir = `${w.state}/backups/warehouse-20260101T000000Z`;
    const r = w.run(['v0.2.0'], { FAKE_WATCH: 'fail' });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stderr, new RegExp(`Warning: could not put ${dir} on config/backups-verified\\.list \\(message above\\), so the nightly pruning does not know it passed its verify; the upgrade goes on`));
    assert.match(r.stderr, /watch could not record it \(fake\)/, 'the checker\'s own message is shown');
    assert.deepEqual(preLog(w)[0], `watch record-verified ${dir} 0`.replace(/ 0$/, ` ${preLog(w)[0].split(' ').at(-1)}`));
    assert.match(preLog(w)[0], /^watch record-verified \S+ \d+$/);
    // A failed proof records nothing.
    const bad = world();
    try {
      const f = bad.run(['v0.2.0'], { FAKE_FAIL: 'verify' });
      assert.notEqual(f.status, 0);
      assert.deepEqual(preLog(bad), [], 'the checker was not asked: the backup did not prove itself');
    } finally { bad.cleanup(); }
  } finally { w.cleanup(); }
});

// --- the write freeze: maintenance mode around the backup, and fas-sync -----------------------------------------------------------------
// The stand-in scripts/maintenance.sh and the session query log to FAKE_LOG.maint (see the stubs above); the real script is tested in tests/maintenance.test.mjs.
const maintLog = w => (existsSync(`${w.log}.maint`) ? readFileSync(`${w.log}.maint`, 'utf8').split('\n').filter(Boolean) : []);
const forgetMaint = w => { rmSync(`${w.log}.maint`, { force: true }); rmSync(`${w.log}.sessions-asked`, { force: true }); };
const marker = w => join(w.state, 'config/maintenance');

test('the API is closed before the backup, stays closed through the checkout and the setup of the new release, and is opened after it; the record says so', () => {
  const w = world();
  try {
    const r = w.run(['v0.2.0']);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    const [session, on, sees, off] = maintLog(w);
    assert.match(session, /^sessions-query /, 'the first thing asked is who else is on the database');
    // Before the backup: the main log (backup, verify, setup) had no line yet; the old release's script, under the lock, with the record already
    // saying that the API is (about to be) closed.
    assert.equal(on, 'maintenance on mainlog=0 marker-before=no lock=held version=v0.1.0 maintenance-in-record=on record=[no|Close the API to phones (maintenance mode)]');
    // The setup of the NEW release ran with the marker there: its compose calls close the gateways it recreates.
    assert.equal(sees, 'setup sees marker=yes');
    // After the setup (three lines in the main log), by the new release's script, under the lock, with the marker still there.
    assert.match(off, /^maintenance off mainlog=3 marker-before=yes lock=held version=v0\.2\.0 maintenance-in-record=on record=\[yes\|Open the API to phones again/);
    assert.equal(maintLog(w).length, 4);
    assert.equal(existsSync(marker(w)), false, 'success leaves the API open');
    assert.equal(existsSync(w.recordPath), false);
    assert.match(r.stdout, /==> Close the API to phones \(maintenance mode\)[^]*==> Backup[^]*==> Verify the backup restores[^]*==> Checkout: v0\.2\.0[^]*==> Setup[^]*==> Open the API to phones again[^]*==> What v0\.2\.0 asks of the operator/);
    assert.match(r.stdout, /The facility is closed to phones from the backup to the end of setup \(maintenance mode: they are told the server is being updated\)/);
  } finally { w.cleanup(); }
});

test('a step that fails after the backup was proved leaves the API closed, and the way forward and the way back say how to open it', () => {
  const w = world();
  try {
    const r = w.run(['v0.2.0'], { FAKE_FAIL: 'setup' });
    assert.notEqual(r.status, 0);
    assert.deepEqual(maintLog(w).filter(line => /^maintenance/.test(line)).map(line => line.split(' ').slice(0, 2).join(' ')), ['maintenance on'], 'never opened');
    assert.equal(existsSync(marker(w)), true, 'the marker is still there: every Compose command of every script keeps the gateways closed');
    assert.match(recordText(w), /^maintenance=on$/m);
    assert.equal(w.record().maintenance, true);
    // The way forward, and the way back with the line that opens it between the old release's setup and its check.
    assert.match(r.stderr, /The API stays closed to phones \(maintenance mode: they are told the server is being updated\) until the upgrade has finished or you run: bash scripts\/maintenance\.sh off\./);
    assert.match(r.stderr, /The API has been closed to phones since before the backup, so phones recorded nothing after it; what reached the database another way \(fas-sync, if it was not paused, or a psql session\) is lost:/);
    assert.doesNotMatch(r.stderr, /Everything the facility recorded after the backup was taken is lost/);
    const order = ['bash scripts/compose.sh up -d --force-recreate --no-deps --wait --wait-timeout 180 functions', 'bash scripts/maintenance.sh off', 'node scripts/doctor.mjs --local', `rm -f '${w.state}/config/upgrade-in-progress'`];
    let at = -1;
    for (const line of order) {
      const found = r.stderr.indexOf(line, at + 1);
      assert.ok(found > at, `the way back names, in order: ${line}\n${r.stderr}`);
      at = found;
    }
    // The rerun closes it again (whatever happened in between), goes on without a new backup, and the rerun that succeeds opens it once.
    forgetMaint(w);
    const second = w.run(['v0.2.0'], { FAKE_FAIL: 'setup' });
    assert.notEqual(second.status, 0);
    assert.deepEqual(maintLog(w).filter(line => /^maintenance/.test(line)).map(line => line.split(' ').slice(0, 2).join(' ')), ['maintenance on']);
    assert.match(maintLog(w).find(line => line.startsWith('maintenance on')), /marker-before=yes/, 'it was closed already; closing again is safe');
    forgetMaint(w);
    const third = w.run(['v0.2.0']);
    assert.equal(third.status, 0, third.stdout + third.stderr);
    assert.deepEqual(maintLog(w).filter(line => /^maintenance/.test(line)).map(line => line.split(' ').slice(0, 2).join(' ')), ['maintenance on', 'maintenance off']);
    assert.equal(existsSync(marker(w)), false);
  } finally { w.cleanup(); }
});

test('when nothing was changed yet (a failed backup or proof) the API this run closed is opened again; a failure to open it is said, with the command', () => {
  for (const fail of ['backup', 'verify']) {
    const w = world();
    try {
      const r = w.run(['v0.2.0'], { FAKE_FAIL: fail });
      assert.notEqual(r.status, 0, fail);
      assert.deepEqual(maintLog(w).filter(line => /^maintenance/.test(line)).map(line => line.split(' ').slice(0, 2).join(' ')), ['maintenance on', 'maintenance off'], fail);
      assert.equal(existsSync(marker(w)), false, `${fail}: the facility is as it was, so it is open`);
      assert.match(r.stderr, /The API was opened again \(maintenance mode off\): nothing of the facility was changed\./, fail);
      assert.equal(existsSync(w.recordPath), false);
    } finally { w.cleanup(); }
  }
  // It cannot be opened: the operator is told, and the marker stays.
  const w = world();
  try {
    const r = w.run(['v0.2.0'], { FAKE_FAIL: 'backup', FAKE_MAINT: 'off' });
    assert.notEqual(r.status, 0);
    assert.equal(existsSync(marker(w)), true);
    assert.match(r.stderr, /Could not open the API again \(message above\)\. It is closed to phones until you run: bash scripts\/maintenance\.sh off/);
    // The record stays while the API does: it is what makes the checker say so (upgrade_interrupted), and the rerun starts afresh from it.
    assert.equal(existsSync(w.recordPath), true);
    assert.equal(w.record().maintenance, true);
    assert.equal(w.record().verified, false);
    assert.doesNotMatch(r.stderr, /The API was opened again/);
    assert.match(r.stderr, /The API is still closed to phones \(maintenance mode\): the same command goes on with it closed, and this opens it: bash scripts\/maintenance\.sh off/);
  } finally { w.cleanup(); }
  // Closing it fails: nothing else is done (no backup), and the run is a failure at that step.
  const v = world();
  try {
    const r = v.run(['v0.2.0'], { FAKE_MAINT: 'on' });
    assert.notEqual(r.status, 0);
    assert.deepEqual(r.log, [], 'no backup, no verify, no setup');
    assert.match(r.stderr, /maintenance on failed \(fake\)/);
    assert.match(r.stderr, /The upgrade stopped at: Close the API to phones \(maintenance mode\)/);
    assert.equal(r.head, v.tag('v0.1.0'), 'the checkout did not move');
  } finally { v.cleanup(); }
});

test('a resumed upgrade that is stopped before the checkout does not open the API: the database may be half upgraded already', () => {
  const w = world();
  try {
    const first = w.run(['v0.2.0'], { FAKE_FAIL: 'setup' });
    assert.notEqual(first.status, 0);
    // The operator puts the checkout back on the old commit by hand (the first line of the way back) and runs the command again.
    git(w.install, 'checkout', '-q', '--detach', w.tag('v0.1.0'));
    forgetMaint(w);
    const r = w.run(['v0.2.0'], { FAKE_MAINT: 'on' });
    assert.notEqual(r.status, 0);
    assert.match(r.stdout, /Resuming: /);
    assert.deepEqual(maintLog(w).filter(line => /^maintenance/.test(line)).map(line => line.split(' ').slice(0, 2).join(' ')), ['maintenance on'], 'it tried to close it, and did not open it');
    assert.equal(existsSync(marker(w)), true, 'still closed');
    assert.doesNotMatch(r.stderr, /The API was opened again/);
    assert.equal(existsSync(w.recordPath), true, 'the record stays: the API is closed by an upgrade nobody has finished');
  } finally { w.cleanup(); }
});

test('a failed OPENING after setup keeps the record: the upgrade is done but not finished, and the rerun finishes it', () => {
  const w = world();
  try {
    const r = w.run(['v0.2.0'], { FAKE_MAINT: 'off' });
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /The upgrade stopped at: Open the API to phones again/);
    assert.equal(existsSync(w.recordPath), true);
    assert.equal(existsSync(marker(w)), true, 'still closed');
    assert.match(r.stderr, /Continue: bash upgrade\.sh v0\.2\.0/);
    forgetMaint(w);
    const again = w.run(['v0.2.0']);
    assert.equal(again.status, 0, again.stdout + again.stderr);
    assert.equal(existsSync(marker(w)), false);
    assert.equal(existsSync(w.recordPath), false);
  } finally { w.cleanup(); }
});

test('an opening that ends with a failed health check (status 2) is recorded as OPEN: the record, the report and the failure text must not say the API is closed', () => {
  const w = world();
  try {
    const r = w.run(['v0.2.0'], { FAKE_MAINT: 'off-open' });
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /The upgrade stopped at: Open the API to phones again/);
    assert.equal(existsSync(marker(w)), false, 'the API is open');
    assert.match(recordText(w), /^maintenance=opened$/m);
    assert.equal(w.record().maintenance, false);
    assert.equal(w.record().apiOpen, true);
    assert.match(r.stderr, /The API is open to phones again \(maintenance mode is off\); the health check that follows failed, so look at it: node scripts\/watch\.mjs health\./);
    assert.doesNotMatch(r.stderr, /stays closed|is closed to phones|has been closed to phones/);
    // Any other failure of the opening (status 1) leaves it closed, as the record says.
    const w2 = world();
    try {
      const r2 = w2.run(['v0.2.0'], { FAKE_MAINT: 'off' });
      assert.notEqual(r2.status, 0);
      assert.match(recordText(w2), /^maintenance=on$/m);
      assert.equal(existsSync(marker(w2)), true);
    } finally { w2.cleanup(); }
  } finally { w.cleanup(); }
});

test('a run stopped before anything was changed whose reopening ends with a failed health check (status 2): the API is open, the record goes, and it says so', () => {
  const w = world();
  try {
    const r = w.run(['v0.2.0'], { FAKE_FAIL: 'backup', FAKE_MAINT: 'off-open' });
    assert.notEqual(r.status, 0);
    assert.equal(existsSync(marker(w)), false);
    assert.equal(existsSync(w.recordPath), false, 'the facility is as it was and the API is open: nothing to report');
    assert.match(r.stderr, /The API was opened again \(maintenance mode off\) and nothing of the facility was changed, but the health check failed \(message above\)/);
    assert.doesNotMatch(r.stderr, /still closed|Could not open the API again/);
  } finally { w.cleanup(); }
});

test('fas-sync: the plan says to pause it, and a psql session from outside the stack on the database refuses the run before anything is changed; a dry run only warns', () => {
  const w = world();
  try {
    const dry = w.run(['--dry-run', 'v0.2.0']);
    assert.equal(dry.status, 0, dry.stderr);
    assert.match(dry.stdout, /The facility is closed for the backup, its verification and the migrations: before step 1 both gateways are put in maintenance mode/);
    assert.match(dry.stdout, /fas-sync \(it writes straight to the database\) has to be paused before the real run: nothing may write meanwhile, or the way back would lose it\. The real run checks for a psql session and refuses to start while one is open\./);
    assert.doesNotMatch(dry.stderr, /psql session/, 'none is open');
    // What is asked: sessions of psql (the way fas-sync reaches the database) other than the one asking, among client backends.
    const query = maintLog(w).find(line => line.startsWith('sessions-query'));
    assert.match(query, /FROM pg_stat_activity WHERE backend_type = 'client backend' AND application_name = 'psql' AND pid <> pg_backend_pid\(\)/);
    // A dry run with one open: a warning that names it, exit 0.
    const warned = w.run(['--dry-run', 'v0.2.0'], { FAKE_SESSIONS: 'supabase_admin active 12s' });
    assert.equal(warned.status, 0, warned.stderr);
    assert.match(warned.stderr, /Warning: a psql session is open on the database, and the real run refuses to start while it is:\n {2}supabase_admin active 12s\nThat is a psql session on the database from outside the stack\. fas-sync writes to the database that way/);
    // The real run refuses, before the backup, the record, the maintenance mode and the log.
    forgetMaint(w);
    const before = w.run(['--dry-run', 'v0.2.0']).head;
    forgetMaint(w);
    const refused = w.run(['v0.2.0'], { FAKE_SESSIONS: 'supabase_admin active 12s\nsupabase_admin idle in transaction 300s' });
    assert.notEqual(refused.status, 0);
    assert.match(refused.stderr, /supabase_admin active 12s\n {2}supabase_admin idle in transaction 300s\nThat is a psql session on the database from outside the stack\. fas-sync writes to the database that way \(pause it: let its run finish and do not start another\)/);
    assert.match(refused.stderr, /Refusing: pause fas-sync \(or close the session\) and run this command again\. Nothing was changed\./);
    assert.deepEqual(refused.log, [], 'no backup');
    assert.equal(refused.head, before);
    assert.equal(maintLog(w).some(line => /^maintenance/.test(line)), false, 'the API was not closed');
    assert.equal(existsSync(marker(w)), false);
    assert.equal(existsSync(w.recordPath), false);
    assert.equal(w.upgradesLog(), '');
    // A session that was just finishing (gone at the second look, three seconds later) is not fas-sync: the run goes on.
    forgetMaint(w);
    const passing = w.run(['v0.2.0'], { FAKE_SESSIONS: 'supabase_admin active 1s', FAKE_SESSIONS_ONCE: 'yes' });
    assert.equal(passing.status, 0, passing.stdout + passing.stderr);
    assert.equal(maintLog(w).filter(line => line.startsWith('sessions-query')).length, 2, 'asked twice');
  } finally { w.cleanup(); }
  // The database cannot be asked: refused, the real run needs the answer.
  const v = world();
  try {
    const r = v.run(['v0.2.0'], { FAKE_FAIL: 'sessions' });
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /Refusing: could not ask the database which sessions are open \(.*could not ask \(fake\).*\)\. Nothing was changed\./);
    assert.deepEqual(r.log, []);
    assert.equal(existsSync(v.recordPath), false);
  } finally { v.cleanup(); }
});
