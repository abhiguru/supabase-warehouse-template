// "A newer release exists" (scripts/release-check.mjs): with a fake git and a fake GitHub, no network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { addMonths, compareTags, fetchGithubJson, githubRepo, gitEnv, newestFinalTag, releaseLine, runningTag, supportNote } from '../scripts/release-check.mjs';

const sha = 'a'.repeat(40);
const lsRemote = (...tags) => tags.flatMap(t => [`${sha}\trefs/tags/${t}`, `${sha}\trefs/tags/${t}^{}`]).join('\n') + '\n';
const NOW = Date.parse('2026-11-01T00:00:00Z');

function fixture(backendRelease) {
  const state = mkdtempSync(join(tmpdir(), 'release-check-'));
  mkdirSync(join(state, 'public'));
  if (backendRelease !== null) writeFileSync(join(state, 'public/release.json'), JSON.stringify({ backendRelease }));
  return state;
}
// A fake git: ls-remote answers `remote`; `git log -1 --format=%cI refs/tags/<tag>` answers `dates[tag]` (absent = tag not held locally);
// `remote get-url origin` answers `origin`. The fake GitHub answers `releases` (a list of { tag_name, name, published_at }).
const ORIGIN = 'https://github.com/abhiguru/supabase-warehouse-template.git';
function fake({ remote = lsRemote('v0.7.0'), remoteStatus = 0, dates = {}, releases = [], titleFails = false, origin = ORIGIN } = {}) {
  const calls = [];
  const run = (command, args, options) => {
    calls.push({ command, args, options });
    if (args.includes('ls-remote')) return { status: remoteStatus, stdout: remote };
    if (args.includes('get-url')) return { status: 0, stdout: `${origin}\n` };
    if (args.includes('log')) { const tag = args.at(-1).replace('refs/tags/', ''); return dates[tag] ? { status: 0, stdout: `${dates[tag]}\n` } : { status: 128, stdout: '' }; }
    return { status: 1, stdout: '' };
  };
  const urls = [];
  const fetchJson = async (url, options) => { urls.push({ url, options }); if (titleFails) throw new Error('HTTP 404'); return releases; };
  return { run, fetchJson, calls, urls };
}
const rel = (tag, name = tag, published_at = '2026-01-01T00:00:00Z') => ({ tag_name: tag, name, published_at, draft: false, prerelease: false });
const line = async (release, f, state = fixture(release)) => { try { return await releaseLine({ root: '/checkout', state, run: f.run, fetchJson: f.fetchJson, now: () => NOW }); } finally { rmSync(state, { recursive: true, force: true }); } };

test('a newer final tag is announced with the running tag; an equal or older one is not', async () => {
  assert.equal(await line('v0.7.0', fake({ remote: lsRemote('v0.7.0', 'v0.8.0') })), 'v0.8.0 is available (this facility runs v0.7.0)');
  assert.equal(await line('v0.7.0', fake({ remote: lsRemote('v0.7.0') })), null, 'same tag');
  assert.equal(await line('v0.8.0', fake({ remote: lsRemote('v0.7.0') })), null, 'running is ahead');
});

test('release candidates and peeled entries are not releases', async () => {
  assert.equal(await line('v0.7.0', fake({ remote: lsRemote('v0.7.0', 'v0.8.0-rc1', 'v0.8.0-rc2') })), null);
  assert.equal(newestFinalTag(lsRemote('v0.7.0', 'v0.7.1-rc1')), 'v0.7.0');
  assert.equal(newestFinalTag(`${sha}\trefs/tags/v9.9.9^{}\n`), null, 'a peeled entry alone is no tag');
});

test('versions compare as numbers: 1.10.0 is newer than 1.9.9', async () => {
  assert.ok(compareTags('v1.10.0', 'v1.9.9') > 0);
  assert.equal(newestFinalTag(lsRemote('v1.9.9', 'v1.10.0', 'v1.2.0')), 'v1.10.0');
  assert.equal(await line('v1.9.9', fake({ remote: lsRemote('v1.9.9', 'v1.10.0') })), 'v1.10.0 is available (this facility runs v1.9.9)');
});

test('the running tag is the base of git describe output, dirty or not; unreadable releases give nothing', async () => {
  assert.equal(runningTag('v0.7.0-3-gabc1234'), 'v0.7.0');
  assert.equal(runningTag('v0.7.0-3-gabc1234-dirty'), 'v0.7.0');
  assert.equal(runningTag('v0.7.0-dirty'), 'v0.7.0');
  assert.equal(runningTag('v0.8.0-rc1'), null);
  assert.equal(runningTag('unknown'), null);
  assert.equal(runningTag('abc1234'), null);
  const f = fake({ remote: lsRemote('v0.7.0', 'v0.8.0') });
  assert.equal(await line('v0.7.0-3-gabc1234-dirty', f), 'v0.8.0 is available (this facility runs v0.7.0)');
  assert.equal(await line('unknown', fake({ remote: lsRemote('v0.8.0') })), null);
  assert.equal(await line(null, fake({ remote: lsRemote('v0.8.0') })), null, 'no release.json');
});

test('a failing or hanging ls-remote gives null and never throws; the lookup has a 10 s limit', async () => {
  assert.equal(await line('v0.7.0', fake({ remoteStatus: 128, remote: lsRemote('v0.8.0') })), null, 'ls-remote failed');
  assert.equal(await line('v0.7.0', fake({ remoteStatus: 127, remote: '' })), null, 'timed out or git missing');
  const f = fake({ remote: lsRemote('v0.8.0') });
  const throwing = { ...f, run: () => { throw new Error('spawn failed'); } };
  assert.equal(await line('v0.7.0', throwing), null);
  await line('v0.7.0', f);
  const listed = f.calls.find(c => c.args.includes('ls-remote'));
  assert.deepEqual(listed.args, ['-C', '/checkout', 'ls-remote', '--tags', 'origin', 'v*']);
  assert.equal(listed.options.timeoutMs, 10000);
  assert.equal(f.urls[0].options.timeoutMs, 10000);
});

test('the Security marker: any final release newer than the running one with "security" in its title, from one releases request', async () => {
  const remote = lsRemote('v0.7.0', 'v0.7.1', 'v0.7.2');
  const on = fake({ remote, releases: [rel('v0.7.2'), rel('v0.7.1', 'v0.7.1 Security: sign-in codes in logs'), rel('v0.7.0')] });
  assert.equal(await line('v0.7.0', on), 'v0.7.2 is available (this facility runs v0.7.0) \u2014 Security release', 'an older one in between counts');
  assert.equal(on.urls.length, 1, 'one request');
  assert.equal(on.urls[0].url, 'https://api.github.com/repos/abhiguru/supabase-warehouse-template/releases?per_page=100');
  assert.equal(on.urls[0].options.timeoutMs, 10000);
  assert.equal(await line('v0.7.0', fake({ remote, releases: [rel('v0.7.2'), rel('v0.7.1')] })), 'v0.7.2 is available (this facility runs v0.7.0)');
  assert.equal(await line('v0.7.1', fake({ remote, releases: [rel('v0.7.2'), rel('v0.7.1', 'v0.7.1 Security: x')] })), 'v0.7.2 is available (this facility runs v0.7.1)', 'a security release the facility already runs is not news');
  assert.equal(await line('v0.7.0', fake({ remote, releases: [{ ...rel('v0.7.2', 'Security fix'), draft: true }, { ...rel('v0.7.1', 'Security fix'), prerelease: true }, rel('v0.7.2-rc1', 'Security rc')] })), 'v0.7.2 is available (this facility runs v0.7.0)', 'drafts, prereleases and candidates are ignored');
  assert.equal(await line('v0.7.0', fake({ remote, releases: [rel('v0.7.2', 'Security')], titleFails: true })), 'v0.7.2 is available (this facility runs v0.7.0)', 'GitHub unreachable');
  assert.equal(await line('v0.7.0', fake({ remote, releases: [rel('v0.7.2', 'Security')], origin: 'https://git.example.test/team/repo.git' })), 'v0.7.2 is available (this facility runs v0.7.0)', 'not a github.com origin: no API call');
  const other = fake({ remote, releases: [], origin: 'git@github.com:someone/fork.git' });
  await line('v0.7.0', other);
  assert.equal(other.urls[0].url, 'https://api.github.com/repos/someone/fork/releases?per_page=100', 'owner and repository come from the origin');
  assert.equal(githubRepo('https://github.com/a/b'), 'a/b');
  assert.equal(githubRepo('ssh://git@github.com/a/b.git'), 'a/b');
  assert.equal(githubRepo('https://github.com.evil.test/a/b'), null);
  assert.equal(githubRepo('https://gitlab.com/a/b'), null);
});

test('a newer release of the running line is named first when it is not the newest', async () => {
  const remote = lsRemote('v0.6.2', 'v0.6.3', 'v0.7.0', 'v0.7.1');
  assert.equal(await line('v0.6.2', fake({ remote })), 'v0.6.3 is available for your line (this facility runs v0.6.2); newest is v0.7.1');
  assert.equal(await line('v0.6.3', fake({ remote })), 'v0.7.1 is available (this facility runs v0.6.3)', 'already on the line\'s newest');
  assert.equal(await line('v0.7.0', fake({ remote })), 'v0.7.1 is available (this facility runs v0.7.0)', 'the newest overall is the line\'s');
});

test('every git command runs without prompts: the environment reaches run, and stdin is not used', async () => {
  const f = fake({ remote: lsRemote('v0.6.2', 'v0.7.0'), dates: { 'v0.7.0': '2026-09-01T00:00:00Z' } });
  await line('v0.6.2', f);
  assert.ok(f.calls.length >= 3, 'ls-remote, get-url and a tag date');
  for (const call of f.calls) {
    assert.equal(call.command, 'git');
    assert.equal(call.options.env.GIT_TERMINAL_PROMPT, '0', call.args.join(' '));
    assert.equal(call.options.env.GIT_ASKPASS, '/bin/false');
    assert.equal(call.options.env.SSH_ASKPASS, '');
    assert.equal(call.options.env.GIT_SSH_COMMAND, 'ssh -o BatchMode=yes -o ConnectTimeout=5');
    assert.equal(call.options.timeoutMs, 10000);
  }
  assert.equal(gitEnv({ A: '1' }).A, '1', 'the rest of the environment is kept');
  const source = (await import('node:fs')).readFileSync(new URL('../scripts/release-check.mjs', import.meta.url), 'utf8');
  assert.match(source, /stdio: \['ignore', 'pipe', 'ignore'\], env \}/, 'the default runner has no stdin and uses the environment');
});

test('the support-end note follows SECURITY.md: GitHub publication dates first, local tag dates as the fallback', async () => {
  const remote = lsRemote('v0.6.2', 'v0.7.0');
  const releases = [rel('v0.7.0', 'v0.7.0', '2026-09-01T10:00:00Z')];
  assert.equal(await line('v0.6.2', fake({ remote, releases })), 'v0.7.0 is available (this facility runs v0.6.2); support for the v0.6 line ends 2027-03-01');
  // GitHub wins over a local date; the local date is used without GitHub.
  const both = fake({ remote, releases, dates: { 'v0.7.0': '2026-01-01T00:00:00Z' } });
  assert.equal(await line('v0.6.2', both), 'v0.7.0 is available (this facility runs v0.6.2); support for the v0.6 line ends 2027-03-01');
  const local = fake({ remote, dates: { 'v0.7.0': '2026-09-01T10:00:00+05:30' } });
  assert.equal(await line('v0.6.2', local), 'v0.7.0 is available (this facility runs v0.6.2); support for the v0.6 line ends 2027-03-01');
  assert.ok(local.calls.filter(c => c.args.includes('log')).every(c => c.args.join(' ').includes('--format=%cI') && c.args.at(-1).startsWith('refs/tags/')));
  assert.ok(!local.calls.some(c => c.args.includes('fetch')), 'no fetch');
  assert.equal(await line('v0.6.2', fake({ remote })), 'v0.7.0 is available (this facility runs v0.6.2)', 'no date anywhere');
  assert.equal(await line('v0.6.2', fake({ remote, releases: [rel('v0.7.0', 'v0.7.0', '2026-02-01T00:00:00Z')] })), 'v0.7.0 is available (this facility runs v0.6.2); support for the v0.6 line ended 2026-08-01');
  assert.equal(await line('v0.7.0', fake({ remote: lsRemote('v0.7.0', 'v0.7.1'), dates: { 'v0.8.0': '2026-09-01T00:00:00Z' } })), 'v0.7.1 is available (this facility runs v0.7.0)');
  const dates = { 'v0.6.0': new Date('2026-01-01T00:00:00Z'), 'v0.7.0': new Date('2026-03-01T00:00:00Z') };
  assert.equal(supportNote('v0.5.0', 'v0.7.0', tag => dates[tag] ?? null, NOW), '; support for the v0.5 line ended 2026-03-01');
  assert.equal(supportNote('v0.9.0', 'v1.0.0', () => new Date('2026-01-01T00:00:00Z'), NOW), '');
});

test('six months later clamps to the last day of the month', () => {
  assert.equal(addMonths(new Date('2026-08-31T00:00:00Z'), 6).toISOString(), '2027-02-28T00:00:00.000Z');
  assert.equal(addMonths(new Date('2027-08-31T00:00:00Z'), 6).toISOString(), '2028-02-29T00:00:00.000Z', 'leap year');
  assert.equal(addMonths(new Date('2026-09-01T10:00:00Z'), 6).toISOString(), '2027-03-01T10:00:00.000Z');
  assert.equal(addMonths(new Date('2026-12-15T00:00:00Z'), 6).toISOString(), '2027-06-15T00:00:00.000Z', 'across a year end');
});

test('the wiring: the daily status carries the line, a failure leaves it out', async () => {
  const { readFileSync } = await import('node:fs');
  const watch = readFileSync(new URL('../scripts/watch.mjs', import.meta.url), 'utf8');
  assert.match(watch, /await ctx\.releaseLine\(\)[^]*text \+= `\\nRelease: \$\{release\}`/);
});

test('the GitHub request refuses redirects and has a time limit (stubbed fetch)', async () => {
  let seen;
  const stub = async (url, options) => { seen = { url, options }; return { ok: true, json: async () => [] }; };
  assert.deepEqual(await fetchGithubJson('https://api.github.com/x', { fetchImpl: stub }), []);
  assert.equal(seen.options.redirect, 'error');
  assert.ok(seen.options.signal instanceof AbortSignal);
  await assert.rejects(fetchGithubJson('https://api.github.com/x', { fetchImpl: async () => ({ ok: false, status: 302 }) }), /HTTP 302/);
});
