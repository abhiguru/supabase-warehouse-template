import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, copyFileSync, chmodSync, appendFileSync, readdirSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { readUpgradeRecord } from '../scripts/upgrade-record.mjs';

// upgrade.sh against a scratch "origin" with release tags and an installed checkout of it. The operator scripts that
// upgrade.sh calls (backup, verify-restore, compose, setup, checkout-permissions) are stubs that append what they were given, whether
// the operator lock was held while they ran and what the upgrade record said at that moment, to one log; upgrade.sh,
// scripts/operator-lock.sh, scripts/pg-major.sh, scripts/db-image.sh, scripts/ci-previous-tag.sh, scripts/alert-webhook.mjs and
// scripts/upgrade-record.mjs are the real files.
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
echo "verify-restore $1 lock=${LOG_LOCK} version=$(cat "$(dirname "$0")/../VERSION") ${REC}" >> "$FAKE_LOG"
[[ "\${FAKE_FAIL:-}" != verify ]] || { echo 'verify failed (fake)' >&2; exit 1; }
`,
  'scripts/compose.sh': `#!/usr/bin/env bash
case "$*" in
  *warehouse_migrations.applied*)
    [[ "\${FAKE_FAIL:-}" != db ]] || { echo 'could not connect (fake)' >&2; exit 2; }
    [[ -z "\${FAKE_NOISE:-}" ]] || echo 'WARN[0000] a compose warning (fake)' >&2
    printf '%s' "$FAKE_LEDGER" ;;
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
[[ "\${FAKE_HANG:-}" != setup ]] || sleep 30
[[ "\${FAKE_FAIL:-}" != setup ]] || { echo 'setup failed (fake)' >&2; exit 3; }
`,
  'scripts/checkout-permissions.sh': `#!/usr/bin/env bash
[[ "\${FAKE_FAIL:-}" != perms ]] || { echo 'checkout-permissions failed (fake)' >&2; exit 1; }
`,
};
const statModeOf = path => parseInt(spawnSync('stat', ['-c', '%a', path], { encoding: 'utf8' }).stdout.trim(), 8);
const dockerfile = major => `FROM postgres:${major}.6-trixie@sha256:${'ab'.repeat(32)}\n`;
const changelog = sections => `# Changelog\n\n## Unreleased\n\n### Operator actions\n\n1. Not released yet: UNRELEASED-ACTION\n\n${sections}\n## Older history\n\nGit has it.\n`;
const S010 = '## v0.1.0 (2026-01-01)\n\nThe first release.\n\n';
const S011 = '## v0.1.1 (2026-02-01)\n\nA fix with no subsections: PLAIN-SECTION-LINE.\n\n';
const S020 = '## v0.2.0 (2026-03-01)\n\n### Operator actions\n\n1. Do the thing: ACTION-TWO.\n\n### Changed\n\n- Something changed: HIDDEN-CHANGE.\n\n';
const S009 = '## v0.0.9 (2026-01-15)\n\nA backport on its own line: BACKPORT-LINE.\n\n';

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
    for (const path of ['scripts/operator-lock.sh', 'scripts/pg-major.sh', 'scripts/db-image.sh', 'scripts/ci-previous-tag.sh', 'scripts/alert-webhook.mjs', 'scripts/is-main.mjs', 'scripts/upgrade-record.mjs']) {
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
  // A backport on its own line: its CHANGELOG section lives on this branch, not on main.
  git(src, 'checkout', '-q', '-b', 'backport');
  base('v0.0.9', { upgrade: true, changelog: changelog(S009 + S010) });
  git(src, 'tag', 'v0.0.9');
  git(src, 'checkout', '-q', 'main');
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
  git(install, 'checkout', '-q', '--detach', at);
  for (const path of [state, join(state, 'config'), join(state, 'public'), join(state, 'backups')]) mkdirSync(path, { recursive: true, mode: 0o700 });
  const log = join(scratch, 'fake.log');
  writeFileSync(log, '');
  const env = (extra = {}) => ({ ...process.env, ...gitEnv, WAREHOUSE_STATE_DIR: state, FAKE_LOG: log, FAKE_LEDGER: '00000000000000_baseline.sql\n', FAKE_ADMIN: '919888888871|Fictional Administrator', ...extra });
  const run = (args, extra = {}) => {
    writeFileSync(log, '');
    const r = spawnSync('bash', [join(install, 'upgrade.sh'), ...args], { encoding: 'utf8', cwd: scratch, env: env(extra) });
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
  const fullStart = lines.indexOf('bash "$ROOT/scripts/compose.sh" up -d --remove-orphans --wait --wait-timeout 180');
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
