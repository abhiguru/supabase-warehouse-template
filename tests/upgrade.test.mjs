import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, copyFileSync, chmodSync, appendFileSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';

// upgrade.sh against a scratch "origin" with release tags and an installed checkout of it. The operator scripts that
// upgrade.sh calls (backup, verify-restore, compose, setup, doctor) are stubs that append what they were given, and
// whether the operator lock was held while they ran, to one log; upgrade.sh, scripts/operator-lock.sh,
// scripts/pg-major.sh, scripts/db-image.sh and scripts/checkout-permissions.sh are the real files.
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

const LOG_LOCK = '$(flock -n "$WAREHOUSE_STATE_DIR/config/operator.lock" true 9>&- && echo free || echo held)';
const stubs = {
  'scripts/backup.sh': `#!/usr/bin/env bash
set -euo pipefail
echo "backup lock=${LOG_LOCK} version=$(cat "$(dirname "$0")/../VERSION")" >> "$FAKE_LOG"
[[ "\${FAKE_FAIL:-}" != backup ]] || { echo 'backup failed (fake)' >&2; exit 1; }
d="$WAREHOUSE_STATE_DIR/backups/warehouse-20260101T000000Z"; mkdir -p "$d"
echo "Backup created at $d"
`,
  'scripts/verify-restore.sh': `#!/usr/bin/env bash
set -euo pipefail
echo "verify-restore $1 lock=${LOG_LOCK}" >> "$FAKE_LOG"
[[ "\${FAKE_FAIL:-}" != verify ]] || { echo 'verify failed (fake)' >&2; exit 1; }
`,
  'scripts/compose.sh': `#!/usr/bin/env bash
case "$*" in
  *warehouse_migrations.applied*) [[ "\${FAKE_FAIL:-}" != db ]] || { echo 'could not connect (fake)' >&2; exit 2; }; printf '%s' "$FAKE_LEDGER" ;;
  *user_profiles*) printf '%s\\n' "$FAKE_ADMIN" ;;
  *) echo "compose $*" >> "$FAKE_LOG"; [[ "\${FAKE_FAIL:-}" != functions || "$*" != *functions* ]] || exit 1 ;;
esac
`,
  'setup.sh': `#!/usr/bin/env bash
set -euo pipefail
echo "setup $* | lock=${LOG_LOCK} version=$(cat "$(dirname "$0")/VERSION")" >> "$FAKE_LOG"
[[ "\${FAKE_FAIL:-}" != setup ]] || { echo 'setup failed (fake)' >&2; exit 3; }
`,
  'scripts/doctor.mjs': `import { appendFileSync } from 'node:fs';
appendFileSync(process.env.FAKE_LOG, 'doctor ' + process.argv.slice(2).join(' ') + '\\n');
if (process.env.FAKE_FAIL === 'doctor') { console.error('doctor failed (fake)'); process.exit(1); }
`,
  'scripts/alert-webhook.mjs': `import { existsSync } from 'node:fs';
export const storedWebhook = state => existsSync(state + '/config/slack-webhook-url') ? 'stored' : null;
`,
};
const statModeOf = path => parseInt(spawnSync('stat', ['-c', '%a', path], { encoding: 'utf8' }).stdout.trim(), 8);
const dockerfile = major => `FROM postgres:${major}.6-trixie@sha256:${'ab'.repeat(32)}\n`;
const changelog = sections => `# Changelog\n\n## Unreleased\n\n### Operator actions\n\n1. Not released yet: UNRELEASED-ACTION\n\n${sections}\n## Older history\n\nGit has it.\n`;
const S010 = '## v0.1.0 (2026-01-01)\n\nThe first release.\n\n';
const S011 = '## v0.1.1 (2026-02-01)\n\nA fix with no subsections: PLAIN-SECTION-LINE.\n\n';
const S020 = '## v0.2.0 (2026-03-01)\n\n### Operator actions\n\n1. Do the thing: ACTION-TWO.\n\n### Changed\n\n- Something changed: HIDDEN-CHANGE.\n\n';

function world() {
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
    for (const path of ['scripts/operator-lock.sh', 'scripts/pg-major.sh', 'scripts/db-image.sh', 'scripts/checkout-permissions.sh', 'scripts/ci-previous-tag.sh']) {
      mkdirSync(dirname(join(src, path)), { recursive: true });
      copyFileSync(join(root, path), join(src, path));
    }
    put(src, 'docker/postgres/Dockerfile', extra.dockerfile ?? dockerfile(18));
    put(src, 'CHANGELOG.md', extra.changelog);
    for (const name of extra.migrations ?? ['00000000000000_baseline.sql']) put(src, `migrations/${name}`, `-- ${name}\n`);
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
  base('v0.1.1', { upgrade: true, changelog: changelog(S011 + S010) });
  git(src, 'tag', 'v0.1.1');                       // a lightweight tag
  base('v0.2.0', { upgrade: true, changelog: changelog(S020 + S011 + S010), migrations: ['00000000000000_baseline.sql', '00000000000001_more.sql'] });
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
  git(src, 'checkout', '-q', 'main');
  git(scratch, 'init', '-q', '--bare', '-b', 'main', origin);
  git(src, 'push', '-q', origin, '--all');
  git(src, 'push', '-q', origin, '--tags');
  git(scratch, 'clone', '-q', origin, install);
  git(install, 'checkout', '-q', '--detach', 'v0.1.0');
  for (const path of [state, join(state, 'config'), join(state, 'public'), join(state, 'backups')]) mkdirSync(path, { recursive: true, mode: 0o700 });
  const log = join(scratch, 'fake.log');
  writeFileSync(log, '');
  const run = (args, env = {}) => {
    writeFileSync(log, '');
    const r = spawnSync('bash', [join(install, 'upgrade.sh'), ...args], {
      encoding: 'utf8', cwd: scratch,
      env: { ...process.env, ...gitEnv, WAREHOUSE_STATE_DIR: state, FAKE_LOG: log, FAKE_LEDGER: '00000000000000_baseline.sql\n', FAKE_ADMIN: '919888888871|Fictional Administrator', ...env },
    });
    return { ...r, log: readFileSync(log, 'utf8').split('\n').filter(Boolean), head: git(install, 'rev-parse', 'HEAD') };
  };
  const upgradesLog = () => (existsSync(join(state, 'config/upgrades.log')) ? readFileSync(join(state, 'config/upgrades.log'), 'utf8') : '');
  return { scratch, src, origin, install, state, log, run, upgradesLog, tag: name => git(install, 'rev-parse', `${name}^{commit}`), cleanup: () => rmSync(scratch, { recursive: true, force: true }) };
}

test('refusals change nothing: no backup, no checkout, no log line', () => {
  const w = world();
  try {
    const before = w.tag('v0.1.0');
    const refused = (args, pattern, env) => {
      const r = w.run(args, env);
      assert.notEqual(r.status, 0, `${args.join(' ')} must be refused`);
      assert.match(r.stderr, pattern, `${args.join(' ')}: ${r.stderr}`);
      assert.deepEqual(r.log, [], `${args.join(' ')}: no operator command ran`);
      assert.equal(r.head, before, `${args.join(' ')}: the checkout did not move`);
      assert.equal(w.upgradesLog(), '', `${args.join(' ')}: nothing logged`);
    };
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
    // A modified tracked file.
    writeFileSync(join(w.install, 'VERSION'), 'edited by hand\n');
    refused(['v0.2.0'], /uncommitted changes[^]*M VERSION|M VERSION[^]*uncommitted changes/);
    git(w.install, 'checkout', '--', 'VERSION');
    // Another operator command holds the lock.
    const holder = spawn('flock', [join(w.state, 'config/operator.lock'), 'sleep', '30'], { stdio: 'ignore', detached: true });
    try {
      for (let i = 0; i < 100 && spawnSync('flock', ['-n', join(w.state, 'config/operator.lock'), 'true']).status === 0; i += 1) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
      refused(['v0.2.0'], /Another operator command/);
    } finally { try { process.kill(-holder.pid, 'SIGKILL'); } catch { /* gone */ } }
    // Not a git checkout is not tested here (the fixture is one); an unset state is:
    const bare = spawnSync('bash', [join(w.install, 'upgrade.sh'), 'v0.2.0'], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: '' } });
    assert.notEqual(bare.status, 0);
    assert.match(bare.stderr, /WAREHOUSE_STATE_DIR/);
  } finally { w.cleanup(); }
});

test('--dry-run runs the checks, prints the plan and changes nothing', () => {
  const w = world();
  try {
    const before = w.tag('v0.1.0');
    const r = w.run(['--dry-run', 'v0.2.0']);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /Plan: v0\.1\.0 -> v0\.2\.0 \(PostgreSQL 18 stays\)/);
    assert.match(r.stdout, /git checkout --detach/);
    assert.match(r.stdout, /--admin-phone 91\*{6}8871 /, 'the number is masked');
    assert.doesNotMatch(r.stdout + r.stderr, /919888888871/);
    assert.match(r.stdout, /--alert-webhook-file off/, 'no webhook stored: off is passed again');
    assert.match(r.stdout, /Dry run: nothing was changed/);
    assert.deepEqual(r.log, []);
    assert.equal(r.head, before);
    assert.equal(w.upgradesLog(), '');
    // The same checks refuse in a dry run.
    const refused = w.run(['--dry-run', 'v0.3.0']);
    assert.notEqual(refused.status, 0);
    assert.match(refused.stderr, /Major PostgreSQL upgrade/);
  } finally { w.cleanup(); }
});

test('the upgrade runs every step in order under the lock, on the new release, and logs it', () => {
  const w = world();
  try {
    const from = w.tag('v0.1.0');
    const r = w.run(['v0.2.0']);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.equal(r.head, w.tag('v0.2.0'), 'the checkout is on the tag');
    const [backup, verify, setup, compose, doctor, ...rest] = r.log;
    assert.deepEqual(rest, []);
    assert.equal(backup, 'backup lock=held version=v0.1.0', 'backup runs on the OLD release, under the lock');
    assert.equal(verify, `verify-restore ${w.state}/backups/warehouse-20260101T000000Z lock=held`, 'verify-restore gets the directory the backup reported');
    assert.equal(setup, `setup --operator --state-dir ${w.state} --admin-phone 919888888871 --admin-name Fictional Administrator --alert-webhook-file off | lock=held version=v0.2.0`,
      'setup is the NEW release\'s, with the administrator from the database, under the same lock');
    assert.match(compose, /^compose up -d --force-recreate --no-deps --wait --wait-timeout 180 functions$/);
    assert.equal(doctor, 'doctor --local');
    // What the release asks of the operator: the new sections' operator actions; not the old release, not Unreleased.
    assert.match(r.stdout, /== v0\.2\.0 \(2026-03-01\)[^]*ACTION-TWO/);
    assert.match(r.stdout, /Also in this release: Changed/);
    assert.doesNotMatch(r.stdout, /HIDDEN-CHANGE/);
    assert.match(r.stdout, /== v0\.1\.1 \(2026-02-01\)[^]*PLAIN-SECTION-LINE/, 'a section without subsections is printed whole');
    assert.doesNotMatch(r.stdout, /UNRELEASED-ACTION|The first release/);
    assert.match(r.stdout, /Upgraded v0\.1\.0 -> v0\.2\.0/);
    assert.match(w.upgradesLog(), /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ v0\.1\.0 -> v0\.2\.0 ok\n$/);
    assert.equal(statModeOf(join(w.state, 'config/upgrades.log')) & 0o077, 0, 'the log is private');
    assert.notEqual(from, r.head);
    // Repeating it at the release: no checkout, the rest runs again.
    const again = w.run(['v0.2.0']);
    assert.equal(again.status, 0, again.stderr);
    assert.match(again.stdout, /already at the release/);
    assert.equal(again.log.length, 5);
    assert.match(w.upgradesLog().trim().split('\n').at(-1), /v0\.2\.0 -> v0\.2\.0 ok$/);
  } finally { w.cleanup(); }
});

test('a stored Slack webhook is left to setup; options after -- go to setup and replace the defaults; --admin-* are used as given', () => {
  const w = world();
  try {
    writeFileSync(join(w.state, 'config/slack-webhook-url'), 'https://hooks.slack.com/services/T0/B0/x\n', { mode: 0o600 });
    const r = w.run(['--admin-phone', '919000000001', '--admin-name', 'Given Name', 'v0.2.0', '--', '--gateway-port', '18001', '--letterhead-file', 'off']);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.log[2], `setup --operator --state-dir ${w.state} --admin-phone 919000000001 --admin-name Given Name --gateway-port 18001 --letterhead-file off | lock=held version=v0.2.0`);
    // Nothing is asked of the database for the administrator, and no webhook option appears.
    assert.doesNotMatch(r.log[2], /alert-webhook/);
    const own = w.run(['v0.2.0', '--', '--alert-webhook-file', '/secure/slack.txt']);
    assert.equal(own.status, 0, own.stderr);
    assert.match(own.log[2], /--alert-webhook-file \/secure\/slack\.txt \|/);
    assert.equal((own.log[2].match(/--alert-webhook-file/g) ?? []).length, 1);
  } finally { w.cleanup(); }
});

test('a failing step stops the rest, is logged, and says how to go back', () => {
  for (const [fail, last, stoppedAt, moved] of [
    ['backup', 'backup', /Backup/, false],
    ['verify', 'verify-restore', /Verify the backup restores/, false],
    ['setup', 'setup', /Setup/, true],
    ['functions', 'compose', /Recreate the functions container/, true],
    ['doctor', 'doctor', /Local doctor/, true],
  ]) {
    const w = world();
    try {
      const from = w.tag('v0.1.0');
      const r = w.run(['v0.2.0'], { FAKE_FAIL: fail });
      assert.notEqual(r.status, 0, fail);
      assert.equal(r.log.at(-1).split(' ')[0], last, `${fail}: nothing after the failed step`);
      assert.match(r.stderr, new RegExp(`The upgrade stopped at: ${stoppedAt.source}`), fail);
      assert.match(w.upgradesLog(), new RegExp(`v0\\.1\\.0 -> v0\\.2\\.0 failed at: ${stoppedAt.source}`), fail);
      if (moved) {
        assert.equal(r.head, w.tag('v0.2.0'));
        assert.match(r.stderr, new RegExp(`git checkout --detach ${from}`));
        assert.match(r.stderr, /run the same command again: it is safe to repeat/);
      } else {
        assert.equal(r.head, from, `${fail}: the checkout did not move`);
        assert.match(r.stderr, /checkout was not changed/);
      }
      if (fail !== 'backup') assert.match(r.stderr, /backups\/warehouse-20260101T000000Z/);
    } finally { w.cleanup(); }
  }
});

test('--ref opts out of the tag rule with a warning; a branch of origin works', () => {
  const w = world();
  try {
    const sha = w.tag('v0.2.0');
    const r = w.run(['--ref', sha]);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stderr, /Warning: --ref [0-9a-f]{40} is not a release tag\. Only tagged releases are supported/);
    assert.equal(r.head, sha);
    assert.match(w.upgradesLog(), /v0\.1\.0 -> [0-9a-f]{7} \(--ref [0-9a-f]{40}\) ok/);
    // The release has no section named by a tag here: Unreleased is what a branch can hold.
    assert.match(r.stdout, /== Unreleased[^]*UNRELEASED-ACTION/);
    const nope = w.run(['--ref', 'no-such-branch']);
    assert.notEqual(nope.status, 0);
    assert.match(nope.stderr, /neither a commit nor a branch/);
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

test('setup.sh accepts the lock upgrade.sh holds, and pg-major.sh reads the pin of this tree and of a ref', () => {
  const setup = readFileSync(join(root, 'setup.sh'), 'utf8');
  assert.doesNotMatch(setup, /^\s*operator_lock "\$STATE"/m, 'setup.sh never takes the lock afresh: upgrade.sh already holds it');
  assert.equal((setup.match(/operator_lock_or_inherited "\$STATE"/g) ?? []).length, 2);
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

test('the CI drill installs the newest release before the change, and skips with a reason when upgrade.sh could not move from it', () => {
  const w = world();
  try {
    const clone = name => {
      const dir = join(w.scratch, name);
      git(w.scratch, 'clone', '-q', w.origin, dir);
      return dir;
    };
    const commit = (dir, path, text) => { put(dir, path, text); git(dir, 'add', '-A'); git(dir, 'commit', '-q', '-m', `edit ${path}`); };
    const pick = dir => {
      const r = spawnSync('bash', [join(dir, 'scripts/ci-previous-tag.sh')], { encoding: 'utf8', env: { ...process.env, ...gitEnv } });
      assert.equal(r.status, 0, 'it skips; it does not fail: ' + r.stderr);
      return r.stdout;
    };
    // A change on top of v0.2.0 (origin/main is further on, at v0.3.0 on PostgreSQL 19): the merge base is v0.2.0.
    const a = clone('a');
    git(a, 'checkout', '-q', '--detach', 'v0.2.0');
    commit(a, 'notes.txt', 'a change\n');
    assert.equal(pick(a), 'skip=false\ntag=v0.2.0\n');
    // The change itself moves the PostgreSQL major: upgrade.sh would refuse the move, so there is nothing to drill.
    commit(a, 'docker/postgres/Dockerfile', dockerfile(19));
    assert.match(pick(a), /^skip=true\nreason=v0\.2\.0 runs PostgreSQL 18 and this commit runs PostgreSQL 19: .*Major PostgreSQL upgrade/);
    // HEAD is the release.
    const b = clone('b');
    git(b, 'checkout', '-q', '--detach', 'v0.2.0');
    assert.equal(pick(b), 'skip=true\nreason=HEAD is the release v0.2.0 itself\n');
    // No release tag at all.
    const c = clone('c');
    for (const tag of git(c, 'tag', '--list').split('\n')) git(c, 'tag', '-d', tag);
    assert.match(pick(c), /^skip=true\nreason=no release tag/);
    // A prerelease tag is used only when there is no stable one; versions sort as numbers (v0.10.0 after v0.9.0).
    const d = clone('d');
    git(d, 'checkout', '-q', '--detach', 'v0.2.0');
    git(d, 'tag', 'v0.2.1-rc.1');
    git(d, 'tag', 'v0.10.0');
    git(d, 'tag', 'v0.9.0');
    commit(d, 'notes.txt', 'again\n');
    git(d, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
    commit(d, 'notes.txt', 'once more\n');
    assert.equal(pick(d), 'skip=false\ntag=v0.10.0\n');
    // A release whose operator-lock.sh has no inherited lock cannot run under the lock upgrade.sh holds.
    const e = clone('e');
    git(e, 'checkout', '-q', '--detach', 'v0.2.0');
    commit(e, 'scripts/operator-lock.sh', readFileSync(join(e, 'scripts/operator-lock.sh'), 'utf8').replace('operator_lock_or_inherited()', 'operator_lock_other()'));
    git(e, 'tag', '-a', '-m', 'old lock', 'v0.2.2');
    git(e, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
    commit(e, 'notes.txt', 'after\n');
    assert.match(pick(e), /^skip=true\nreason=v0\.2\.2 predates the inherited operator lock/);
  } finally { w.cleanup(); }
});
