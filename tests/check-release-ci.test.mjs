import { test } from 'node:test';
import assert from 'node:assert/strict';
import { REQUIRED_CHECKS, run } from '../scripts/check-release-ci.mjs';

const SHA = 'a'.repeat(40);
const env = { GITHUB_REPOSITORY: 'owner/repo', GITHUB_SHA: SHA, GH_TOKEN: 'tok' };
const [INSTALL, UPGRADE] = REQUIRED_CHECKS;
const ok = (name, extra = {}) => ({ name, status: 'completed', conclusion: 'success', completed_at: '2026-11-01T10:00:00Z', ...extra });

const reply = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => body });
const page = (runs, total = runs.length) => reply(200, { total_count: total, check_runs: runs });

// A fake fetch: `handler(url, init, n)` answers; every call is recorded.
function harness(handler) {
  const calls = [];
  const fetchImpl = async (url, init) => { calls.push({ url, auth: init.headers.Authorization, signal: init.signal }); return handler(url, init, calls.length); };
  const lines = [];
  const go = (e = env, argv = []) => run({ env: e, argv, fetchImpl, log: line => lines.push(line) });
  return { calls, lines, go };
}

test('both required jobs green on the commit passes, and the request names the commit', async () => {
  const h = harness(() => page([ok(INSTALL), ok(UPGRADE), ok('Other')]));
  assert.equal(await h.go(), 0);
  assert.equal(h.calls.length, 1);
  assert.match(h.calls[0].url, new RegExp(`^https://api\\.github\\.com/repos/owner/repo/commits/${SHA}/check-runs\\?per_page=100&page=1$`));
  assert.equal(h.calls[0].auth, 'Bearer tok');
  assert.ok(h.calls[0].signal instanceof AbortSignal, 'a timeout is set');
});

test('a missing job fails and names it', async () => {
  const h = harness(() => page([ok(INSTALL)]));
  assert.equal(await h.go(), 1);
  assert.match(h.lines.join('\n'), /^::error title=Release gate: CI::.*Upgrade from the previous release: no run on this commit/);
});

test('a failed, cancelled, skipped or unfinished job fails and names its state', async () => {
  for (const bad of [{ conclusion: 'failure' }, { conclusion: 'cancelled' }, { conclusion: 'skipped' }, { status: 'in_progress', conclusion: null }, { status: 'queued', conclusion: null }]) {
    const h = harness(() => page([ok(INSTALL), ok(UPGRADE, bad)]));
    assert.equal(await h.go(), 1, JSON.stringify(bad));
    assert.ok(h.lines.join('\n').includes(`${UPGRADE}: ${bad.conclusion ?? bad.status}`), h.lines.join('\n'));
  }
});

test('only the newest run of a name counts: a later success passes an earlier failure, a later failure fails an earlier success', async () => {
  const old = '2026-11-01T08:00:00Z';
  const later = '2026-11-01T11:00:00Z';
  const rerun = harness(() => page([ok(INSTALL), ok(UPGRADE, { conclusion: 'failure', completed_at: old }), ok(UPGRADE, { completed_at: later })]));
  assert.equal(await rerun.go(), 0);
  const regress = harness(() => page([ok(INSTALL), ok(UPGRADE, { completed_at: old }), ok(UPGRADE, { conclusion: 'failure', completed_at: later })]));
  assert.equal(await regress.go(), 1);
});

test('a name that only starts with the required one does not count', async () => {
  const h = harness(() => page([ok(INSTALL), ok(`${UPGRADE} (extra)`)]));
  assert.equal(await h.go(), 1);
});

test('the required run on page 2 is found; the pages are requested in order', async () => {
  const filler = Array.from({ length: 100 }, (_, i) => ok(`filler ${i}`));
  const h = harness(url => (url.endsWith('page=1') ? page(filler, 102) : page([ok(INSTALL), ok(UPGRADE)], 102)));
  assert.equal(await h.go(), 0);
  assert.equal(h.calls.length, 2);
  assert.match(h.calls[1].url, /page=2$/);
});

test('403 with the token is retried once without it, and the answer counts', async () => {
  const h = harness((url, init) => (init.headers.Authorization ? reply(403, {}) : page([ok(INSTALL), ok(UPGRADE)])));
  assert.equal(await h.go(), 0);
  assert.deepEqual(h.calls.map(call => call.auth), ['Bearer tok', undefined]);
});

test('403 both ways fails closed', async () => {
  const h = harness(() => reply(403, {}));
  assert.equal(await h.go(), 1);
  assert.match(h.lines.join('\n'), /answered 403/);
});

test('without a token there is one anonymous request', async () => {
  const h = harness(() => page([ok(INSTALL), ok(UPGRADE)]));
  assert.equal(await h.go({ GITHUB_REPOSITORY: 'owner/repo', GITHUB_SHA: SHA }), 0);
  assert.equal(h.calls[0].auth, undefined);
});

test('a network error, a server error and a body that is not a check-run list all fail', async () => {
  assert.equal(await harness(() => { throw new TypeError('fetch failed'); }).go(), 1);
  assert.equal(await harness(() => reply(500, {})).go(), 1);
  assert.equal(await harness(() => reply(200, { message: 'x' })).go(), 1);
  const timeout = harness(() => { throw Object.assign(new Error('t'), { name: 'TimeoutError' }); });
  assert.equal(await timeout.go(), 1);
  assert.match(timeout.lines.join('\n'), /timed out after 10 s/);
});

test('names can be given as arguments, and a bad environment fails', async () => {
  const h = harness(() => page([ok('Migration ordering rule')]));
  assert.equal(await h.go(env, ['Migration ordering rule']), 0);
  assert.equal(await harness(() => page([])).go({ GITHUB_REPOSITORY: 'owner/repo', GITHUB_SHA: 'abc' }), 1);
});
