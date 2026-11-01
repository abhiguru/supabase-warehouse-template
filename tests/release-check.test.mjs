// "A newer release exists" (scripts/release-check.mjs): with a fake git and a fake GitHub, no network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { compareTags, newestFinalTag, releaseLine, runningTag, supportNote } from '../scripts/release-check.mjs';

const sha = 'a'.repeat(40);
const lsRemote = (...tags) => tags.flatMap(t => [`${sha}\trefs/tags/${t}`, `${sha}\trefs/tags/${t}^{}`]).join('\n') + '\n';
const NOW = Date.parse('2026-11-01T00:00:00Z');

function fixture(backendRelease) {
  const state = mkdtempSync(join(tmpdir(), 'release-check-'));
  mkdirSync(join(state, 'public'));
  if (backendRelease !== null) writeFileSync(join(state, 'public/release.json'), JSON.stringify({ backendRelease }));
  return state;
}
// A fake git: ls-remote answers `remote`; `git log -1 --format=%cI refs/tags/<tag>` answers `dates[tag]` (absent = tag not held locally).
function fake({ remote = lsRemote('v0.7.0'), remoteStatus = 0, dates = {}, title, titleFails = false } = {}) {
  const calls = [];
  const run = (command, args, options) => {
    calls.push({ command, args, options });
    if (args.includes('ls-remote')) return { status: remoteStatus, stdout: remote };
    if (args.includes('log')) { const tag = args.at(-1).replace('refs/tags/', ''); return dates[tag] ? { status: 0, stdout: `${dates[tag]}\n` } : { status: 128, stdout: '' }; }
    return { status: 1, stdout: '' };
  };
  const urls = [];
  const fetchJson = async (url, options) => { urls.push({ url, options }); if (titleFails) throw new Error('HTTP 404'); return { name: title ?? 'v0.8.0' }; };
  return { run, fetchJson, calls, urls };
}
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

test('the Security marker follows the GitHub release title, and a failed lookup leaves it out silently', async () => {
  const remote = lsRemote('v0.7.0', 'v0.7.1');
  const on = fake({ remote, title: 'v0.7.1 Security: sign-in codes in logs' });
  assert.equal(await line('v0.7.0', on), 'v0.7.1 is available (this facility runs v0.7.0) — Security release');
  assert.equal(on.urls[0].url, 'https://api.github.com/repos/abhiguru/supabase-warehouse-template/releases/tags/v0.7.1');
  assert.equal(await line('v0.7.0', fake({ remote, title: 'v0.7.1' })), 'v0.7.1 is available (this facility runs v0.7.0)');
  assert.equal(await line('v0.7.0', fake({ remote, titleFails: true })), 'v0.7.1 is available (this facility runs v0.7.0)', 'GitHub unreachable');
});

test('the support-end note follows SECURITY.md from local tag dates only', async () => {
  const remote = lsRemote('v0.6.2', 'v0.7.0');
  // Running 0.6.x, 0.7.0 came out 2026-09-01: the 0.6 line is fixed until 2027-03-01.
  const f = fake({ remote, dates: { 'v0.7.0': '2026-09-01T10:00:00+05:30' } });
  assert.equal(await line('v0.6.2', f), 'v0.7.0 is available (this facility runs v0.6.2); support for the v0.6 line ends 2027-03-01');
  assert.ok(f.calls.filter(c => c.args.includes('log')).every(c => c.args.join(' ').includes('--format=%cI') && c.args.at(-1).startsWith('refs/tags/')), 'dates come from local tags');
  assert.ok(!f.calls.some(c => c.args.includes('fetch')), 'no fetch');
  // The tag is not held locally: no date.
  assert.equal(await line('v0.6.2', fake({ remote })), 'v0.7.0 is available (this facility runs v0.6.2)');
  // A date in the past says "ended".
  assert.equal(await line('v0.6.2', fake({ remote, dates: { 'v0.7.0': '2026-02-01T00:00:00Z' } })), 'v0.7.0 is available (this facility runs v0.6.2); support for the v0.6 line ended 2026-08-01');
  // A patch of the running line: the line is current, no date.
  assert.equal(await line('v0.7.0', fake({ remote: lsRemote('v0.7.0', 'v0.7.1'), dates: { 'v0.8.0': '2026-09-01T00:00:00Z' } })), 'v0.7.1 is available (this facility runs v0.7.0)');
  // Two lines behind: the line ended when the line after next came out, if that is earlier than six months.
  assert.equal(supportNote('v0.5.0', 'v0.7.0', tag => ({ 'v0.6.0': new Date('2026-01-01T00:00:00Z'), 'v0.7.0': new Date('2026-03-01T00:00:00Z') })[tag] ?? null, NOW), '; support for the v0.5 line ended 2026-03-01');
  // Another major version: no rule to apply.
  assert.equal(supportNote('v0.9.0', 'v1.0.0', () => new Date('2026-01-01T00:00:00Z'), NOW), '');
});

test('the wiring: the daily status carries the line, a failure leaves it out', async () => {
  const { readFileSync } = await import('node:fs');
  const watch = readFileSync(new URL('../scripts/watch.mjs', import.meta.url), 'utf8');
  assert.match(watch, /release = await ctx\.releaseLine\(\);[^]*text \+= `\\nRelease: \$\{release\}`/);
});

test('the GitHub lookup refuses redirects, in the default fetcher and in the checker\'s', async () => {
  const { readFileSync } = await import('node:fs');
  for (const file of ['release-check.mjs', 'watch.mjs']) {
    const source = readFileSync(new URL(`../scripts/${file}`, import.meta.url), 'utf8');
    assert.match(source, /signal: AbortSignal\.timeout\(timeoutMs\), redirect: 'error'/, file);
  }
});
